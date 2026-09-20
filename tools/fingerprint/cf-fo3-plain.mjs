// The third `fo/` post in plaintext, read before Cloudflare encrypts it.
//
//   node tools/fingerprint/cf-fo3-plain.mjs <lightpanda|chrome>[:headed-ua]
//        [--arms a,b] [--pairs n] [--url u] [--settle ms] [--port n] [--out p]
//        [--no-hook]
// env: LP_BIN, CHROME
//
// `cf-branch.mjs` put the fork on the THIRD `fo/` post: both arms send about
// 89 KB there and Cloudflare answers one with a clearance form and the other
// with another round. So the bytes of that post are the input to the decision
// -- and they are useless as captured, because the two arms' bodies share no
// common prefix or suffix at all. It is a session-keyed ciphertext; a byte diff
// of two of them says only that encryption works.
//
// The plaintext should still be in the realm before it is encrypted, and on
// DataDome hooking `JSON.stringify` was enough to read it
// (`hook-json-stringify-to-read-encrypted-payloads`). That is what this tool
// was built to do here.
//
// **It does not work on Cloudflare, and the measurement is the point.** With
// every realm armed -- page, widget, and the sandboxed ones, confirmed by each
// copy reporting its own `location.origin` -- and with `JSON.stringify`,
// `TextEncoder.encode`, `TextEncoder.encodeInto`, `btoa` and
// `crypto.subtle.encrypt` all hooked, the largest plaintext seen anywhere in a
// run is 31 KB, and it is the CSS property-name list
// (`guards-read-whole-computed-style`). Nothing of the third post's ~89 KB ever
// exists as one contiguous plaintext at any of those sinks; `subtle.encrypt` is
// never called at all. The collection is assembled and enciphered incrementally
// inside the obfuscated program.
//
// So this tool is kept as the record of a closed door rather than as a way in.
// Two things it is still good for: the realm-arming it does (per execution
// context, because this engine keeps the cross-origin widget inside the page
// target where `addScriptToEvaluateOnNewDocument` never reaches it) is reusable,
// and its `--no-hook` control plus `branch=` column make it a ready-made way to
// ask whether some other instrument changes the verdict.
//
// What to try instead: the engine-side `prop_read` log
// (`prop-read-log-is-the-invisible-probe`) sits upstream of assembly and needs
// nothing in the realm at all.
//
// **The instrument is the risk here.** An earlier tool reported 12,343 records
// through `console.log` and pushed Chrome's own round-3 body from 90 KB to
// 215 KB -- text left in the realm is collected along with everything else and
// opened the station by itself (`instruments-that-leave-text-open-cf`). So this
// reports at most `--max-reports` records (default 40), emits a digest rather
// than the string for anything under `--min-len`, and truncates every sample.
// `--no-hook` runs the identical harness with the hook not installed, which is
// the control the hook has to be checked against: if `branch=` moves between
// `--no-hook` and a hooked run, the reading is the instrument's and not the
// guard's.
import path from 'node:path';
import fs from 'node:fs/promises';
import { arg, has, runTrace, writeRun } from './fo-harness.mjs';

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const BASE_PORT = Number(arg('--port', '9352'));
const PAIRS = Number(arg('--pairs', '1'));
const OUT = arg('--out', null);
const NO_HOOK = has('--no-hook');
const MAX_REPORTS = Number(arg('--max-reports', '40'));
const MIN_LEN = Number(arg('--min-len', '2000'));

const ARMS = (arg('--arms', null) ?? process.argv[2] ?? '').split(',').filter(Boolean);
if (!ARMS.length || ARMS.some((a) => !/^(lightpanda|chrome)(:headed-ua)?$/.test(a))) {
    console.error('usage: cf-fo3-plain.mjs <lightpanda|chrome>[:headed-ua] [--no-hook] [--out p]');
    process.exit(2);
}

const MARK = '__fo3__';
const FO = /\/cdn-cgi\/challenge-platform\/[^?]*\/fo\//;
const sideOf = (url) => (/challenges\.cloudflare\.com/.test(url) ? 'WIDGET' : 'PAGE');

// Installed into every realm before its document runs. Kept deliberately small
// and allocation-light: it runs inside the program being measured, so anything
// it leaves behind is part of what the guard collects.
const recorder = `(() => {
  const MARK = ${JSON.stringify(MARK)};
  const MAX = ${MAX_REPORTS}, MIN = ${MIN_LEN};
  let sent = 0, calls = 0, skipped = 0;
  const real = JSON.stringify;
  // The real stringify, not the hook: a report serialised through the hook is
  // a 2.8 KB string that trips the hook's own size test, and the first run
  // spent two of its forty slots re-reporting its own reports.
  const say = (o) => { if (sent++ < MAX) { try { console.log(MARK + real(o)); } catch (e) {} } };
  // A cheap order-insensitive digest, so two arms' payloads can be compared
  // without shipping either one of them out of the realm.
  const digest = (s) => { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; return h; };
  // Which realm this copy actually landed in. Arming is per execution context
  // and an engine that ignores contextId would silently run every copy in the
  // main one -- eleven contexts armed, one realm hooked, and nothing in the
  // report to say so.
  var where = 'unknown';
  try { where = location.origin + (globalThis.__fo3Seen ? ' REPEAT' : ''); globalThis.__fo3Seen = 1; } catch (e) {}
  say({ k: 'install', where: where });
  try {
    JSON.stringify = function (v, r, sp) {
      const out = real.apply(this, arguments);
      calls++;
      if (typeof out === 'string' && out.length >= MIN) {
        // Top-level keys are the thing worth comparing between arms: they name
        // what was collected, where the values move run to run.
        let keys = null;
        try { if (v && typeof v === 'object' && !Array.isArray(v)) keys = Object.keys(v).slice(0, 400); } catch (e) {}
        say({ k: 'str', n: out.length, d: digest(out), keys, head: out.slice(0, 400) });
      } else { skipped++; }
      return out;
    };
    Object.defineProperty(JSON.stringify, 'name', { value: 'stringify' });
    JSON.stringify.toString = function () { return 'function stringify() { [native code] }'; };
  } catch (e) { say({ k: 'installErr', at: 'stringify', e: String(e) }); }

  // The widget realm makes zero stringify calls, so the payload is assembled
  // some other way and these are the sinks it has to pass through on the way
  // to the wire. TextEncoder is the one that matters: a browser that is about
  // to encrypt a string encodes it first, so the last plaintext of any size is
  // usually the argument to encode().
  const sink = (label, n, sample) => {
    if (n >= MIN) say({ k: 'sink', via: label, n: n, d: digest(sample), head: sample.slice(0, 400) });
    else skipped++;
  };
  try {
    const te = TextEncoder.prototype.encode;
    TextEncoder.prototype.encode = function (s) { calls++; try { sink('TextEncoder', String(s).length, String(s)); } catch (e) {} return te.apply(this, arguments); };
    TextEncoder.prototype.encode.toString = function () { return 'function encode() { [native code] }'; };
  } catch (e) { say({ k: 'installErr', at: 'TextEncoder', e: String(e) }); }
  try {
    const b = globalThis.btoa;
    globalThis.btoa = function (s) { calls++; try { sink('btoa', String(s).length, String(s)); } catch (e) {} return b.apply(this, arguments); };
    globalThis.btoa.toString = function () { return 'function btoa() { [native code] }'; };
  } catch (e) { say({ k: 'installErr', at: 'btoa', e: String(e) }); }

  // Nothing payload-sized passes through stringify, encode or btoa, so the
  // collection is assembled incrementally and never exists as one plaintext
  // string at those points. WebCrypto is where it has to become contiguous
  // again: whatever is encrypted is the plaintext, by definition.
  const asText = (b) => {
    try {
      const v = b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer ?? b, b.byteOffset ?? 0, b.byteLength ?? b.length);
      return { n: v.length, s: new TextDecoder('latin1').decode(v.subarray(0, 600)) };
    } catch (e) { return { n: -1, s: String(e) }; }
  };
  try {
    const enc = crypto.subtle.encrypt;
    crypto.subtle.encrypt = function (alg, key, data) {
      calls++;
      try { const t = asText(data); sink('subtle.encrypt/' + (alg && (alg.name || alg)), t.n, t.s); } catch (e) {}
      return enc.apply(this, arguments);
    };
  } catch (e) { say({ k: 'installErr', at: 'subtle.encrypt', e: String(e) }); }
  try {
    const ei = TextEncoder.prototype.encodeInto;
    TextEncoder.prototype.encodeInto = function (s) { calls++; try { sink('encodeInto', String(s).length, String(s)); } catch (e) {} return ei.apply(this, arguments); };
  } catch (e) { say({ k: 'installErr', at: 'encodeInto', e: String(e) }); }
  addEventListener('pagehide', () => say({ k: 'tally', calls, sent, skipped }));
  // The tally matters even when the page is never hidden, so also emit it late.
  setTimeout(() => say({ k: 'tally', calls, sent, skipped }), 30000);
})();`;

/// The same reading cf-branch.mjs takes, recomputed here so a run of this tool
/// is self-contained: html on the third post is the clearance form.
function readBranch(posts) {
    if (posts.length < 3) return 'none';
    return /html/.test(String(posts[2].mime ?? '')) ? 'clear' : 'retry';
}

async function runOnce(armSpec, port) {
    const engine = armSpec.split(':')[0];
    const headedUa = armSpec.endsWith(':headed-ua');
    const state = { arm: armSpec, hooked: !NO_HOOK, posts: [] };
    const byId = new Map();
    const key = (sid, id) => `${sid ?? 'page'}|${id}`;

    let userAgentOverride = null;
    if (headedUa) {
        const { headedUserAgent } = await import('./fo-harness.mjs');
        userAgentOverride = await headedUserAgent(port + 1);
    }

    await runTrace({
        engine, url: URL_, settleMs: SETTLE, port, mark: MARK, state,
        userAgentOverride,
        // The control arm runs the whole harness -- same domains, same target
        // arming, same injected-script call -- with a script that does nothing.
        recorder: NO_HOOK ? '(() => {})();' : recorder,
        onMessage(msg, _st, cdp) {
            const p = msg.params ?? {};
            const sid = msg.sessionId;
            // The widget is a cross-origin child. Chrome isolates it into a
            // target of its own, which runTrace arms on attach -- but this
            // engine keeps it inside the page target, where
            // addScriptToEvaluateOnNewDocument never reached it: the first run
            // armed exactly one realm and saw 12 stringify calls, all of them
            // the page's. Arming each execution context as it is announced
            // reaches the child realm on both arms. It races the context's
            // first statements, so it is a floor on what the guard did, not a
            // complete record.
            if (msg.method === 'Runtime.executionContextCreated' && !NO_HOOK) {
                const id = p.context?.id;
                if (id === undefined) return;
                state.armedContexts ??= [];
                state.armedContexts.push({ session: sid ?? 'page', id, origin: p.context?.origin, name: p.context?.name });
                cdp.send('Runtime.evaluate',
                    { expression: recorder, contextId: id, returnByValue: true }, sid)
                    .catch((err) => { state.armedContexts.at(-1).err = String(err.message ?? err); });
                return;
            }
            if (msg.method === 'Network.requestWillBeSent') {
                const url = String(p.request?.url ?? '');
                if (!FO.test(url)) return;
                const e = {
                    seq: state.posts.length, side: sideOf(url),
                    postLen: p.request?.postData?.length ?? (p.request?.hasPostData ? -1 : 0),
                };
                byId.set(key(sid, p.requestId), e);
                state.posts.push(e);
            } else if (msg.method === 'Network.responseReceived') {
                const e = byId.get(key(sid, p.requestId));
                if (e) { e.status = p.response?.status; e.mime = p.response?.mimeType; }
            } else if (msg.method === 'Network.loadingFinished') {
                const e = byId.get(key(sid, p.requestId));
                if (e) e.encoded = p.encodedDataLength ?? 0;
            }
        },
    });

    state.served = /bypassed/i.test(String(state.final?.text ?? ''));
    state.branch = readBranch(state.posts);
    state.seq = state.posts.map((e) => e.side).join(' -> ');
    // Only the records this tool asked for; runTrace collects others too.
    state.strings = state.records.filter((r) => r.k === 'str' || r.k === 'sink');
    state.tallies = state.records.filter((r) => r.k === 'tally');
    return state;
}

const runs = [];
for (let pair = 0; pair < PAIRS; pair++) {
    for (const armSpec of ARMS) {
        const port = BASE_PORT + runs.length * 4;
        const st = await runOnce(armSpec, port);
        runs.push(st);
        const big = st.strings.length;
        const calls = st.tallies.length ? Math.max(...st.tallies.map((t) => t.calls)) : 0;
        console.log(`[${pair + 1}/${PAIRS}] ${armSpec.padEnd(20)}`
            + ` ${st.hooked ? 'hooked ' : 'no-hook'}`
            + ` branch=${st.branch.padEnd(6)} served=${String(st.served).padEnd(5)}`
            + ` stringify calls=${String(calls).padStart(5)} big=${String(big).padStart(3)}`
            + `  ${st.seq}`);
        for (const s of st.strings) {
            console.log(`      n=${String(s.n).padStart(7)} d=${s.d}`
                + ` keys=${s.keys ? s.keys.length : '-'} ${JSON.stringify(String(s.head).slice(0, 90))}`);
        }
        if (st.error) console.log(`      error: ${st.error}`);
        if (OUT) {
            // writeRun resolves a bare path under tools/fingerprint itself, so
            // handing it an absolute one buries the run under a copy of the
            // whole path inside the repo. Pass what was asked for, unresolved.
            await writeRun(OUT.replace(/\.json$/, '')
                + `-${armSpec.replace(/:/g, '-')}-${st.hooked ? 'hook' : 'ctl'}-${pair + 1}.json`, st);
        }
    }
}

console.log('');
for (const armSpec of ARMS) {
    const mine = runs.filter((r) => r.arm === armSpec);
    console.log(`${armSpec.padEnd(20)} ${NO_HOOK ? 'no-hook' : 'hooked '}`
        + ` clear ${mine.filter((r) => r.branch === 'clear').length}/${mine.length}`
        + ` served ${mine.filter((r) => r.served).length}/${mine.length}`
        + ` bigStrings ${[...new Set(mine.map((r) => r.strings.length))].join('/')}`);
}
