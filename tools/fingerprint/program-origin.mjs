// E1: is the Turnstile `runProgram` program fetched over the network, or is it
// derived in the page?
//
// vm-trace --reach already showed the two engines hand runProgram wildly
// different first arguments (widget realm: lightpanda str(6944), Chrome
// str(617404)), and that the two strings share an 18-character prefix. A shared
// prefix rules out "each engine downloaded a different blob", but not "the
// program is a fetched constant that one engine then extends". This settles it
// by measuring both ends at once:
//
//   NETWORK  every response's byte count (Network.dataReceived accumulates the
//            real transfer size; loadingFinished carries the total). If Chrome
//            downloads ~600KB more than lightpanda, the program came off the
//            wire.
//   PAGE     every string >= MIN_BIG handed to a page-installed global, to a
//            Blob, or produced by fetch/XHR, recorded as {len, head, tail}.
//            Cross-referencing a program's head against the recorded response
//            bodies says directly whether it was ever transmitted.
//
// The page instrument is deliberately the same shape as vm-trace's REACH_SRC
// (wrap globals that appear after the bootstrap, keep first-call arguments) so
// the two runs stay comparable; it only records more about big strings.
//
// usage:
//   node tools/fingerprint/program-origin.mjs <lightpanda|chrome>
//        [--url u] [--settle ms] [--out path] [--same-process] [--headed]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const has = (n) => process.argv.includes(n);

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: program-origin.mjs <lightpanda|chrome> [--url u] [--settle ms] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '30000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9242' : '9243'));
const OUT = arg('--out', null);
const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Strings shorter than this are noise -- the interesting ones are kilobytes.
const MIN_BIG = 2000;

const PROBE = String.raw`
(function () {
  var MIN_BIG = __MIN_BIG__;
  var realm = (function () {
    try { return location.href; } catch (e) { return '?'; }
  })();
  var big = [];      // every big string we saw, with provenance
  var blobs = [];    // Blob constructions
  var posts = [];    // request bodies, chiefly the fo/ telemetry POST
  var seenBig = {};  // dedupe by len+head so a replayed string is one entry

  function shape(s) {
    // A char-class census distinguishes "base64 payload" from "JS source" from
    // "whitespace-padded" without shipping a megabyte over the console.
    var sp = 0, ws = 0, az = 0, dig = 0, sym = 0, ctl = 0;
    var step = s.length > 200000 ? 37 : 1;   // sample huge strings
    var n = 0;
    for (var i = 0; i < s.length; i += step) {
      var c = s.charCodeAt(i); n++;
      if (c === 32) sp++;
      else if (c < 32) { if (c === 9 || c === 10 || c === 13) ws++; else ctl++; }
      else if ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) az++;
      else if (c >= 48 && c <= 57) dig++;
      else sym++;
    }
    var pct = function (v) { return Math.round((v / n) * 1000) / 10; };
    return { sampled: n, space: pct(sp), ws: pct(ws), alpha: pct(az), digit: pct(dig), sym: pct(sym), ctl: pct(ctl) };
  }

  function record(where, s) {
    if (typeof s !== 'string' || s.length < MIN_BIG) return;
    var key = s.length + '|' + s.slice(0, 24);
    if (seenBig[key]) { seenBig[key].hits++; return; }
    var e = {
      where: where, len: s.length, hits: 1,
      head: s.slice(0, 160),
      mid: s.slice(Math.floor(s.length / 2), Math.floor(s.length / 2) + 80),
      tail: s.slice(-80),
      shape: shape(s),
    };
    seenBig[key] = e;
    big.push(e);
  }

  // --- Blob / object URL -------------------------------------------------
  try {
    var OrigBlob = window.Blob;
    window.Blob = function (parts, opts) {
      try {
        var total = 0;
        for (var i = 0; parts && i < parts.length; i++) {
          var p = parts[i];
          if (typeof p === 'string') { total += p.length; record('Blob[' + i + ']', p); }
          else if (p && typeof p.byteLength === 'number') total += p.byteLength;
          else if (p && typeof p.size === 'number') total += p.size;
        }
        blobs.push({ parts: parts ? parts.length : 0, total: total, type: (opts && opts.type) || '' });
      } catch (e) { /* never break the page */ }
      return new OrigBlob(parts, opts);
    };
    window.Blob.prototype = OrigBlob.prototype;
    for (var bk in OrigBlob) { try { window.Blob[bk] = OrigBlob[bk]; } catch (e) { } }
  } catch (e) { }

  // --- fetch / XHR response text ----------------------------------------
  try {
    var of = window.fetch;
    window.fetch = function () {
      var u = String(arguments[0] && arguments[0].url ? arguments[0].url : arguments[0]);
      return of.apply(this, arguments).then(function (res) {
        try {
          var c = res.clone();
          c.text().then(function (t) { record('fetch:' + u.slice(0, 90), t); }, function () { });
        } catch (e) { }
        return res;
      });
    };
  } catch (e) { }
  try {
    var OX = window.XMLHttpRequest.prototype;
    var oOpen = OX.open, oSend = OX.send;
    OX.open = function (m, u) { this.__u = String(u); return oOpen.apply(this, arguments); };
    OX.send = function (body) {
      var self = this;
      // The request body is the whole point for fo/: the program that comes
      // back is chosen by what was posted, so its shape is what to compare.
      try {
        if (typeof body === 'string') {
          posts.push({ url: String(self.__u).slice(0, 110), len: body.length, head: body.slice(0, 300), shape: shape(body) });
          record('xhrPOST:' + String(self.__u).slice(0, 90), body);
        } else if (body) {
          posts.push({ url: String(self.__u).slice(0, 110), nonString: Object.prototype.toString.call(body), len: body.byteLength ?? body.size ?? -1 });
        }
      } catch (e) { }
      this.addEventListener('load', function () {
        try { record('xhr:' + String(self.__u).slice(0, 90), self.responseText); } catch (e) { }
      });
      return oSend.apply(this, arguments);
    };
  } catch (e) { }

  // --- postMessage --------------------------------------------------------
  try {
    window.addEventListener('message', function (ev) {
      try {
        if (typeof ev.data === 'string') record('postMessage', ev.data);
        else if (ev.data && typeof ev.data === 'object') {
          for (var k in ev.data) {
            if (typeof ev.data[k] === 'string') record('postMessage.' + k, ev.data[k]);
          }
        }
      } catch (e) { }
    }, true);
  } catch (e) { }

  // --- globals the page installs (same wrap as vm-trace REACH_SRC) --------
  var base = {};
  var names0 = Object.getOwnPropertyNames(globalThis);
  for (var i0 = 0; i0 < names0.length; i0++) base[names0[i0]] = 1;
  var seen = {}, calls = {};

  function scan() {
    var n = Object.getOwnPropertyNames(globalThis);
    for (var i = 0; i < n.length; i++) {
      var k = n[i];
      if (base[k] || seen[k]) continue;
      seen[k] = 1;
      var v;
      try { v = globalThis[k]; } catch (e) { continue; }
      if (typeof v !== 'function') continue;
      calls[k] = 0;
      try {
        (function (key, fn) {
          globalThis[key] = function () {
            calls[key]++;
            try {
              for (var q = 0; q < arguments.length; q++) {
                record('global ' + key + '#' + calls[key] + ' arg' + q, arguments[q]);
              }
            } catch (e) { }
            var r = fn.apply(this, arguments);
            try { record('global ' + key + '#' + calls[key] + ' ->', r); } catch (e) { }
            return r;
          };
          try {
            for (var pk in fn) { try { globalThis[key][pk] = fn[pk]; } catch (e) { } }
          } catch (e) { }
        })(k, v);
      } catch (e) { }
    }
  }

  var t = 0;
  var iv = setInterval(function () {
    scan();
    if (++t % 5 === 0) {
      try {
        console.log('@@PO@@' + JSON.stringify({
          realm: realm, big: big, blobs: blobs, calls: calls, posts: posts,
        }) + '@@END@@');
      } catch (e) { }
    }
  }, 200);
  scan();
})();
`.replace('__MIN_BIG__', String(MIN_BIG));

const state = {
    engine, url: URL_, settleMs: SETTLE,
    wire: [],          // per-request: url, type, status, bytes
    totals: {},
    perRealm: {},
    console: [],
    exceptions: [],
    bodies: [],        // fetched via Network.getResponseBody where supported
};

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-po-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--window-size=1920,1080',
        ...(has('--same-process')
            ? ['--disable-features=IsolateOrigins,site-per-process', '--disable-site-isolation-trials']
            : []),
        ...(has('--headed') ? [] : ['--headless=new']),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info')], { stdio: ['ignore', 'pipe', 'pipe'] });

const engineLog = [];
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));

let cdp;
try {
    for (let i = 0; i < 80; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) { state.version = await r.json(); break; }
        } catch { /* not up */ }
        await sleep(250);
    }

    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    const byId = new Map();
    const finished = [];
    cdp.on((msg) => {
        const p = msg.params ?? {};
        switch (msg.method) {
            case 'Runtime.consoleAPICalled': {
                const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
                const m = /^@@PO@@([\s\S]*)@@END@@$/.exec(text);
                if (m) {
                    try {
                        const r = JSON.parse(m[1]);
                        state.perRealm[r.realm] = { big: r.big, blobs: r.blobs, calls: r.calls, posts: r.posts };
                    } catch { /* keep previous */ }
                } else if (state.console.length < 200) {
                    state.console.push(`${p.type}: ${text.slice(0, 200)}`);
                }
                break;
            }
            case 'Runtime.exceptionThrown':
                if (state.exceptions.length < 60) {
                    state.exceptions.push((p.exceptionDetails?.exception?.description
                        ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 200));
                }
                break;
            case 'Network.requestWillBeSent':
                byId.set(p.requestId, { url: String(p.request?.url ?? ''), type: p.type, bytes: 0 });
                break;
            case 'Network.responseReceived': {
                const e = byId.get(p.requestId);
                if (e) { e.status = p.response?.status; e.mime = p.response?.mimeType; }
                break;
            }
            case 'Network.dataReceived': {
                const e = byId.get(p.requestId);
                if (e) e.bytes += p.dataLength ?? 0;
                break;
            }
            case 'Network.loadingFinished': {
                const e = byId.get(p.requestId);
                if (e) { e.encoded = p.encodedDataLength ?? 0; finished.push(p.requestId); }
                break;
            }
            case 'Network.loadingFailed': {
                const e = byId.get(p.requestId);
                if (e) e.failed = p.errorText;
                break;
            }
        }
    });

    for (const d of ['Runtime', 'Log', 'Network', 'Page']) {
        await cdp.send(`${d}.enable`, undefined, sessionId).catch(() => { });
    }
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: PROBE }, sessionId)
        .catch((err) => { state.probeError = String(err.message ?? err); });

    await cdp.send('Page.navigate', { url: URL_ }, sessionId);
    await sleep(SETTLE);
    await sleep(500);

    // Did the interstitial actually clear? The program sizes matching is only
    // interesting if the outcome still differs, so record the verdict too.
    try {
        state.final = await cdp.send('Runtime.evaluate', {
            expression: `JSON.stringify({
                href: location.href,
                title: document.title,
                status: (document.body ? document.body.innerText : '').slice(0, 200),
                cookie: document.cookie.split(';').map(s => s.trim().split('=')[0]).join(','),
                clearance: /cf_clearance/.test(document.cookie),
            })`,
            returnByValue: true,
        }, sessionId).then((r) => JSON.parse(r.result?.value ?? 'null'));
    } catch (err) { state.final = { err: String(err.message ?? err) }; }

    // Response bodies, so a program head can be searched for on the wire.
    for (const id of finished.slice(0, 60)) {
        const e = byId.get(id);
        if (!e) continue;
        try {
            const r = await cdp.send('Network.getResponseBody', { requestId: id }, sessionId);
            const b = r.base64Encoded ? Buffer.from(r.body, 'base64').toString('latin1') : r.body;
            state.bodies.push({ url: e.url.slice(0, 140), len: b.length, body: b });
        } catch (err) {
            state.bodies.push({ url: e.url.slice(0, 140), err: String(err.message ?? err) });
        }
    }

    let total = 0, totalEnc = 0;
    for (const e of byId.values()) {
        state.wire.push({
            url: e.url.slice(0, 150), type: e.type, status: e.status,
            bytes: e.bytes, encoded: e.encoded ?? 0, failed: e.failed,
        });
        total += e.bytes; totalEnc += e.encoded ?? 0;
    }
    state.totals = { requests: byId.size, dataReceived: total, encoded: totalEnc };
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}
state.engineLog = engineLog.join('').slice(-4000);

// --- report ---------------------------------------------------------------
const out = OUT ? path.resolve(REPO, OUT.startsWith('tools/') ? OUT : path.join('tools/fingerprint', OUT)) : null;

console.log(`=== ${engine} ===`);
console.log(`requests=${state.totals.requests} dataReceived=${state.totals.dataReceived} encoded=${state.totals.encoded}`);
for (const w of state.wire) {
    console.log(`  ${String(w.bytes).padStart(9)}  ${String(w.type ?? '').padEnd(9)} ${w.status ?? w.failed ?? ''} ${w.url.replace(/https:\/\/www\.scrapingcourse\.com/, '{sc}').replace(/https:\/\/challenges\.cloudflare\.com/, '{cf}').slice(0, 100)}`);
}
for (const [realm, r] of Object.entries(state.perRealm)) {
    console.log(`--- realm ${realm.slice(0, 110)}`);
    console.log(`    blobs: ${JSON.stringify(r.blobs)}`);
    for (const p of (r.posts ?? [])) {
        console.log(`    POST ${String(p.len).padStart(8)} ${p.url.replace(/^https?:\/\/[^/]+/, '')}`);
        if (p.shape) console.log(`             shape ${JSON.stringify(p.shape)}`);
        if (p.head) console.log(`             head ${JSON.stringify(p.head.slice(0, 200))}`);
    }
    for (const b of (r.big ?? []).sort((a, c) => c.len - a.len).slice(0, 14)) {
        console.log(`    ${String(b.len).padStart(8)} x${b.hits} ${b.where.slice(0, 60)}`);
        console.log(`             shape ${JSON.stringify(b.shape)}`);
        console.log(`             head ${JSON.stringify(b.head.slice(0, 110))}`);
        console.log(`             tail ${JSON.stringify(b.tail.slice(0, 60))}`);
        // Was this exact string ever on the wire?
        const probe = b.head.slice(0, 48);
        const hit = state.bodies.find((x) => x.body && x.body.includes(probe));
        console.log(`             onWire: ${hit ? hit.url : 'NO'}`);
    }
}
console.log(`FINAL ${JSON.stringify(state.final)}`);
if (state.exceptions.length) console.log(`exceptions(${state.exceptions.length}): ${state.exceptions.slice(0, 6).join(' | ')}`);
if (state.error) console.log(`ERROR ${state.error}`);
if (state.probeError) console.log(`PROBE ERROR ${state.probeError}`);

if (out) {
    // Bodies are the bulk; keep only lengths plus a head, the full text is
    // only needed for the on-wire search above.
    const slim = { ...state, bodies: state.bodies.map((b) => ({ url: b.url, len: b.len, err: b.err, head: b.body?.slice(0, 400) })) };
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.writeFile(out, JSON.stringify(slim, null, 1));
    console.log(`wrote ${out}`);
}
