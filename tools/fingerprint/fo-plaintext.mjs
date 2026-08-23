// What does the widget's first `fo/` POST actually say, before it is encrypted?
//
// E1 put the first divergence at the widget's *first* telemetry POST: 4 716
// bytes on an arm that clears, 4 855/4 866 here, and non-deterministic where the
// reference is fixed (README, "Round 3 is not where the payload first differs").
// The body on the wire is one ciphertext under a per-session key, so the diff
// has to happen upstream of the encryption.
//
// Two routes were tried first and are worth recording as closed:
//
//   - Splitting the ciphertext on `$` and comparing field counts. `$` is a
//     character in the encoding alphabet, not a separator; the counts are noise.
//   - Replaying the captured widget document offline under `vm-trace`. Served
//     framed from a second origin the document loads, installs nothing, and
//     never attempts its first POST -- the parent hands it its challenge
//     parameters over `postMessage` and the replay's host page does not, so the
//     assembly this wants to watch never starts. (`--kick runProgram` cannot
//     substitute: round 1 is assembled by the document's own code, and
//     `runProgram` is for the *program* that arrives in round 1's reply.)
//
// So instrument the funnels the plaintext must pass through on its way out, live
// on the real station, in the widget's own realm:
//
//   crypto.subtle.encrypt / digest   the data argument is the plaintext
//   TextEncoder.prototype.encode     the usual step just before it
//   JSON.stringify                   how a collected object becomes a string
//   btoa                            the usual step just after it
//
// Every wrapper forwards to the original and returns its value unchanged, and
// each one's `toString` is made to answer with the native source text, so a
// program that checks is told what it would have been told anyway. Whether the
// instrument is honest is not an argument to have -- it is a measurement: run
// the oracle arm with the wrappers in and check it still clears. If it does, the
// wrappers did not change what the page decided.
//
// The widget lives in a cross-origin child realm a main-frame evaluate cannot
// reach, so records come back over the console (same reason vm-trace does it)
// and are collected from every session, not just the page's.
//
// usage:
//   node tools/fingerprint/fo-plaintext.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
//        [--min n] [--max-records n]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const has = (n) => process.argv.includes(n);

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: fo-plaintext.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9262' : '9263'));
const OUT = arg('--out', null);
// Below this the record is a length only. charCodeAt-sized traffic would bury
// the payload, and the payload is thousands of bytes.
const MIN = Number(arg('--min', '400'));
const MAX_RECORDS = Number(arg('--max-records', '400'));
const headedUa = has('--headed-ua');
const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// The recorder. Runs before the document's own code in every realm it is
// installed in. `MARK` prefixes each console line so the collector can tell its
// own records from the page's chatter.
const MARK = '@@FOPT@@';
const RECORDER = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var MIN = ${MIN};
  var n = 0;
  var log = console.log.bind(console);
  var origToString = Function.prototype.toString;

  function emit(rec) {
    if (n++ > ${MAX_RECORDS}) return;
    try { log(MARK + JSON.stringify(rec)); } catch (e) { /* unserialisable */ }
  }

  // A wrapper that answers toString() with the native text is a wrapper the
  // page cannot tell from the function it replaced by reading it.
  function disguise(wrapper, original) {
    var native_ = 'function ' + (original.name || '') + '() { [native code] }';
    try {
      Object.defineProperty(wrapper, 'name', { value: original.name, configurable: true });
      Object.defineProperty(wrapper, 'length', { value: original.length, configurable: true });
      wrapper.toString = function () { return native_; };
      wrapper.toString.toString = function () { return 'function toString() { [native code] }'; };
    } catch (e) { /* frozen */ }
    return wrapper;
  }

  function describe(v) {
    try {
      if (typeof v === 'string') return { t: 'str', n: v.length, v: v.length >= MIN ? v : undefined };
      if (v instanceof ArrayBuffer) return { t: 'ab', n: v.byteLength,
        v: v.byteLength >= MIN ? String.fromCharCode.apply(null, new Uint8Array(v)) : undefined };
      if (v && v.buffer instanceof ArrayBuffer) {
        var u = new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength);
        var s;
        if (u.length >= MIN) { s = ''; for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); }
        return { t: 'view', n: u.length, v: s };
      }
      if (v && typeof v === 'object') {
        var j = JSON.stringify(v);
        return { t: 'obj', n: j ? j.length : -1, v: j && j.length >= MIN ? j : undefined };
      }
      return { t: typeof v, n: -1 };
    } catch (e) { return { t: 'unreadable', n: -1 }; }
  }

  function wrapMethod(owner, key, label, argIndex) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        try { emit({ k: label, a: describe(arguments[argIndex]) }); } catch (e) { /* keep going */ }
        // A bare call to a *global* function (btoa, fetch) passes this ===
        // undefined, and forwarding that to the original raises "Illegal
        // invocation" -- which in a worker means the telemetry POST never goes
        // out and the challenge stalls at round 1. Measured, not guessed.
        return original.apply(this === undefined ? globalThis : this, arguments);
      }, original);
    } catch (e) { /* non-writable */ }
  }

  // The plaintext is the third argument to encrypt/sign and the second to
  // digest; everything else here is a funnel it may pass through on the way.
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'encrypt', 'subtle.encrypt', 2); } catch (e) {}
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'sign', 'subtle.sign', 2); } catch (e) {}
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'digest', 'subtle.digest', 1); } catch (e) {}
  try { wrapMethod(globalThis.TextEncoder && globalThis.TextEncoder.prototype, 'encode', 'TextEncoder.encode', 0); } catch (e) {}
  try { wrapMethod(globalThis.JSON, 'stringify', 'JSON.stringify', 0); } catch (e) {}
  try { wrapMethod(globalThis, 'btoa', 'btoa', 0); } catch (e) {}

  // What the body ends up being, whichever transport carries it -- the anchor
  // that says which of the records above is the one that became the POST.
  try {
    wrapMethod(globalThis.XMLHttpRequest && globalThis.XMLHttpRequest.prototype, 'send', 'xhr.send', 0);
  } catch (e) {}
  try {
    var origFetch = globalThis.fetch;
    if (typeof origFetch === 'function') {
      globalThis.fetch = disguise(function (input, init) {
        try {
          emit({ k: 'fetch', url: String((input && input.url) || input || '').slice(0, 200),
                 a: describe(init && init.body) });
        } catch (e) { /* keep going */ }
        return origFetch.apply(this === undefined ? globalThis : this, arguments);
      }, origFetch);
    }
  } catch (e) {}

  emit({ k: 'installed', href: String(location.href).slice(0, 200) });
})();`;

async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ua-'));
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${PORT + 1}`,
        `--user-data-dir=${dir}`,
        '--no-first-run', '--no-default-browser-check', '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${PORT + 1}/json/version`)).json();
                if (ua) return ua.replace('HeadlessChrome', 'Chrome');
            } catch { /* not up yet */ }
            await sleep(200);
        }
        throw new Error('could not read the browser user agent for --headed-ua');
    } finally {
        probe.kill('SIGKILL');
        await fs.rm(dir, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

const state = {
    engine, url: URL_, headedUa, settleMs: SETTLE, min: MIN,
    userAgentOverride: null,
    records: [],     // one per instrumented call, in arrival order
    realms: [],      // which sessions got the recorder, and whether it installed
    posts: [],       // the fo/ POSTs on the wire, to key the records against
    console: [],
    exceptions: [],
};

if (headedUa) {
    if (engine !== 'chrome') {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
    state.userAgentOverride = await headedUserAgent();
    console.log(`--headed-ua: ${state.userAgentOverride}`);
}

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-pt-'))}`,
        '--no-first-run', '--no-default-browser-check', '--window-size=1920,1080',
        '--headless=new',
        ...(state.userAgentOverride ? [`--user-agent=${state.userAgentOverride}`] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info')], { stdio: ['ignore', 'pipe', 'pipe'] });

const engineLog = [];
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));

let cdp = null;
try {
    for (let i = 0; i < 100; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) { state.version = await r.json(); break; }
        } catch { /* not up */ }
        await sleep(250);
    }

    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId: pageSession } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // A child target must be armed before its document runs, and the only hook
    // that is early enough is addScriptToEvaluateOnNewDocument on the child's
    // own session -- which does not exist until the child is attached. Pausing
    // new targets on start is what buys the window in between.
    async function arm(sid, why) {
        const rec = { session: sid ?? 'page', why, installed: false, resumed: false };
        state.realms.push(rec);
        await cdp.send('Runtime.enable', undefined, sid).catch(() => { });
        await cdp.send('Page.enable', undefined, sid).catch(() => { });
        try {
            await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: RECORDER }, sid);
            rec.installed = true;
        } catch (err) { rec.err = String(err.message ?? err); }
        // Workers have no Page domain, and a worker is where this station
        // assembles its telemetry: with the document realm fully armed the
        // funnels saw no fetch, no btoa, no WebCrypto and nothing over 172
        // bytes through JSON.stringify, while the POSTs went out regardless.
        // Auto-attach pauses a new target before its first statement, so the
        // window to evaluate the recorder into it is right here, ahead of
        // runIfWaitingForDebugger below.
        //
        // Do NOT await this. A target paused on start has its script thread
        // blocked by the debugger, so the evaluate cannot run until the resume
        // below -- awaiting it deadlocks the arm() call, the resume never
        // happens, and the whole challenge stalls at round 1 (measured: one POST
        // instead of four, and the final evaluate times out). Fire it and let it
        // land the moment the worker is released, which is still seconds ahead of
        // the telemetry POST.
        if (!rec.installed) {
            rec.via = 'evaluate';
            cdp.send('Runtime.evaluate', { expression: RECORDER, awaitPromise: false }, sid)
                .then((r) => {
                    rec.installed = !r.exceptionDetails;
                    if (r.exceptionDetails) rec.evalErr = r.exceptionDetails.text?.slice(0, 160);
                })
                .catch((err) => { rec.evalErr = String(err.message ?? err); });
        }
        await cdp.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid).catch(() => { });
        await cdp.send('Network.enable', { maxPostDataSize: 1048576 }, sid).catch(() => { });
        // Whether or not the pause took, releasing is harmless.
        await cdp.send('Runtime.runIfWaitingForDebugger', undefined, sid)
            .then(() => { rec.resumed = true; }).catch(() => { });
    }

    cdp.on((msg) => {
        const p = msg.params ?? {};
        if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
            arm(p.sessionId, p.targetInfo?.url ?? '?').catch(() => { });
            return;
        }
        if (msg.method === 'Runtime.consoleAPICalled') {
            const text = (p.args ?? []).map((a) => a.value ?? a.description ?? '').join(' ');
            if (text.startsWith(MARK)) {
                try {
                    state.records.push({ session: msg.sessionId ?? 'page', ...JSON.parse(text.slice(MARK.length)) });
                } catch { state.records.push({ session: msg.sessionId ?? 'page', unparsed: text.length }); }
            } else if (state.console.length < 200) {
                state.console.push(`${p.type}: ${text.slice(0, 200)}`);
            }
            return;
        }
        if (msg.method === 'Runtime.exceptionThrown' && state.exceptions.length < 60) {
            state.exceptions.push((p.exceptionDetails?.exception?.description
                ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 200));
            return;
        }
        if (msg.method === 'Network.requestWillBeSent' && /\/fo\//.test(String(p.request?.url ?? ''))) {
            state.posts.push({
                url: String(p.request.url).slice(0, 120),
                postLen: p.request.postData?.length ?? (p.request.hasPostData ? -1 : 0),
            });
        }
        if (msg.method === 'Network.responseReceived' && /\/fo\//.test(String(p.response?.url ?? ''))) {
            const hdrs = p.response.headers ?? {};
            const verdict = Object.keys(hdrs).filter((k) => /^cf-chl/i.test(k)).sort();
            const last = state.posts[state.posts.length - 1];
            if (last && !last.verdict) last.verdict = verdict.join('+');
        }
    });

    await arm(pageSession, 'page');
    await cdp.send('Page.navigate', { url: URL_ }, pageSession);
    await sleep(SETTLE);

    try {
        state.final = await cdp.send('Runtime.evaluate', {
            expression: `JSON.stringify({
                title: document.title,
                text: (document.body ? document.body.innerText : '').slice(0, 200),
            })`,
            returnByValue: true,
        }, pageSession).then((r) => JSON.parse(r.result?.value ?? 'null'));
    } catch (err) { state.final = { err: String(err.message ?? err) }; }
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}
state.engineLog = engineLog.join('').slice(-4000);

// --- report ---------------------------------------------------------------
console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
console.log(`realms armed: ${state.realms.filter((r) => r.installed).length}/${state.realms.length}`);
const tally = new Map();
for (const r of state.records) tally.set(r.k, (tally.get(r.k) ?? 0) + 1);
console.log(`records: ${state.records.length}  ${[...tally].map(([k, v]) => `${k}=${v}`).join(' ')}`);
for (const r of state.records.filter((r) => (r.a?.v ?? '').length >= MIN).slice(0, 12)) {
    console.log(`  ${String(r.k).padEnd(18)} ${String(r.a.t).padEnd(5)} n=${String(r.a.n).padStart(7)}`
        + `  ${JSON.stringify((r.a.v ?? '').slice(0, 60))}`);
}
for (const p of state.posts) console.log(`  POST ${String(p.postLen).padStart(7)} ${p.verdict ?? '?'}  ${p.url.slice(-40)}`);
console.log(`FINAL ${JSON.stringify(state.final)}`);
if (state.error) console.log(`ERROR ${state.error}`);

if (OUT) {
    const out = path.resolve(REPO, OUT.startsWith('tools/') ? OUT : path.join('tools/fingerprint', OUT));
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.writeFile(out, JSON.stringify(state, null, 1));
    console.log(`wrote ${out}`);
}
