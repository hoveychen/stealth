// Which line of somebody else's minified bundle threw, and what the source
// around it looks like -- for a throw the page *catches*, so nothing about it
// reaches `Runtime.exceptionThrown`.
//
// The Cloudflare interstitial logs
//   [Cloudflare Turnstile] Unhandled error: TypeError: Cannot read properties
//   of undefined (reading 'call')
// and then gives up. `api.js` has 13 bare `X.call(` sites on obfuscated locals,
// so the message names no source position and the console line is the whole
// evidence. Guessing which of the 13 it is has already cost two sessions
// (README, "the door behind that door"); this reads it off the frame instead.
//
// TWO MECHANISMS, because the engines do not offer the same one:
//
//   Debugger domain -- `Debugger.setPauseOnExceptions('all')` stops on caught
//     throws too, and the pause carries `callFrames` with a `scopeChain`, which
//     is the only way to see what the undefined variable was *bound to*.
//     Chrome only: this engine implements no Debugger domain at all (there is
//     no `src/cdp/domains/debugger.zig`; the sole `Debugger` hit under
//     `src/cdp/` is `Target.setAutoAttach`'s `waitForDebuggerOnStart`). Asked
//     for it anyway and reported as unsupported rather than skipped, so a run
//     says which mechanism produced its frames.
//
//   V8 stack frames -- `Error.prepareStackTrace` hands back structured frames
//     (`getFileName` / `getLineNumber` / `getColumnNumber`) instead of a string,
//     and this engine supports it in full. It only fires when something reads
//     `.stack`, so the injected bootstrap forces that read from every path a
//     catcher can report through: `Error.prototype.toString` (which `'' + e`
//     and `String(e)` go through), the `console` methods, `onerror`,
//     `unhandledrejection`, and `Promise.prototype.then/catch` rejection
//     handlers. Works on both engines, and is what makes the two comparable.
//
// Frames name a url:line:column. Minified bundles are one enormous line, so a
// column of 41823 is not something to eyeball -- the report slices the source
// around the column and prints it, resolving the body from (in order) the
// Debugger's own copy, `Network.getResponseBody`, then a plain refetch.
//
// usage: node tools/fingerprint/exception-frames.mjs <lightpanda|chrome> <url>
//          [--settle 30000] [--context 240] [--frames 6]
//          [--out results/x.json] [--sources dir]
//          [--headed] [--log-level debug]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? fallback : process.argv[i + 1];
};
const has = (name) => process.argv.includes(name);

const engine = process.argv[2];
const url = process.argv[3];
if ((engine !== 'lightpanda' && engine !== 'chrome') || !url || url.startsWith('--')) {
    console.error('usage: exception-frames.mjs <lightpanda|chrome> <url> [--settle ms] [--context chars] [--frames n] [--out path] [--sources dir] [--headed]');
    process.exit(2);
}

const SETTLE = Number(arg('--settle', '30000'));
const CONTEXT = Number(arg('--context', '240'));
const MAX_FRAMES = Number(arg('--frames', '6'));
const PORT = engine === 'chrome' ? 9236 : 9237;
const LIGHTPANDA = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Injected before any page script, in every realm the engine gives it to.
// Everything here is defensive: this runs inside a page that is about to be
// handed to a hostile bundle, and a throw from the bootstrap would be a
// *different* exception than the one being hunted.
const BOOTSTRAP = String.raw`
(function () {
  if (globalThis.__EXC) return;
  var recs = globalThis.__EXC = [];
  var origLog = console.log.bind(console);
  var frames = new WeakMap();
  var seen = new WeakSet();
  var depth = 0;

  Error.stackTraceLimit = 50;
  // V8 calls this the first time anything reads err.stack, and whatever it
  // returns *becomes* err.stack -- so the string it builds has to stay the one
  // the page would have seen, or a bundle that parses its own stack changes
  // behaviour under the probe.
  Error.prepareStackTrace = function (err, structured) {
    try {
      frames.set(err, structured.map(function (f) {
        return {
          fn: f.getFunctionName() || null,
          file: f.getFileName() || null,
          line: f.getLineNumber(),
          col: f.getColumnNumber(),
          isEval: f.isEval(),
          isNative: f.isNative(),
        };
      }));
    } catch (e) { /* a frame accessor threw; the string still has to come out */ }
    var head = (err && err.name ? String(err.name) : 'Error');
    if (err && err.message) head += ': ' + String(err.message);
    var body = '';
    for (var i = 0; i < structured.length; i++) {
      try { body += '\n    at ' + structured[i].toString(); } catch (e) { body += '\n    at ?'; }
    }
    return head + body;
  };

  function record(why, e) {
    if (depth) return;
    depth++;
    try {
      if (!e || (typeof e !== 'object' && typeof e !== 'function')) return;
      if (seen.has(e)) return;
      seen.add(e);
      void e.stack;                       // forces prepareStackTrace
      var rec = {
        why: why,
        name: String((e && e.name) || ''),
        // Read the own field, not toString(): toString() is hooked below.
        message: String((e && e.message) || ''),
        frames: frames.get(e) || null,
        realm: (function () { try { return location.href; } catch (x) { return null; } })(),
      };
      recs.push(rec);
      // Also out through the console: a record on a window that later
      // navigates -- or on a frame nobody can reach -- is a record nobody
      // reads, and the CDP console stream survives both.
      try { origLog('@@EXC@@' + JSON.stringify(rec) + '@@END@@'); } catch (x) { }
    } catch (x) {
      try { origLog('@@EXC@@' + JSON.stringify({ why: why, hookError: String(x) }) + '@@END@@'); } catch (y) { }
    } finally {
      depth--;
    }
  }
  globalThis.__EXC_record = record;

  // Both "[prefix] " + e and String(e) land here, which is how a catcher that
  // only ever logs a *string* still gives up its frames.
  var origToString = Error.prototype.toString;
  Error.prototype.toString = function () {
    record('Error.toString', this);
    return origToString.call(this);
  };

  // A catcher that passes the error object itself.
  ['error', 'warn', 'log', 'info', 'debug', 'trace'].forEach(function (k) {
    var orig = console[k];
    if (typeof orig !== 'function') return;
    console[k] = function () {
      for (var i = 0; i < arguments.length; i++) {
        var a = arguments[i];
        if (a && typeof a === 'object' && typeof a.stack === 'string') record('console.' + k, a);
      }
      return orig.apply(console, arguments);
    };
  });

  // Uncaught, for completeness: this is the one path CDP already reports, and
  // having it here too keeps one record shape for the whole run.
  try {
    addEventListener('error', function (ev) { record('onerror', ev && ev.error); }, true);
    addEventListener('unhandledrejection', function (ev) { record('unhandledrejection', ev && ev.reason); }, true);
  } catch (x) { }

  // Transpiled async/await becomes promise chains, so a throw inside one is
  // delivered to a rejection handler and never touches the two above.
  ['then', 'catch'].forEach(function (k) {
    var orig = Promise.prototype[k];
    if (typeof orig !== 'function') return;
    Promise.prototype[k] = function () {
      var args = Array.prototype.slice.call(arguments);
      var at = k === 'catch' ? 0 : 1;
      var h = args[at];
      if (typeof h === 'function') {
        args[at] = function (reason) {
          record('promise.' + k, reason);
          return h.apply(this, arguments);
        };
      }
      return orig.apply(this, args);
    };
  });
})();
`;

const state = {
    engine,
    url,
    settleMs: SETTLE,
    debugger: { requested: true, supported: null, pauses: 0 },
    records: [],
    pauses: [],
    console: [],
    cdpExceptions: [],
    wire: [],
};

// scriptId -> { url, source } from Debugger.scriptParsed / getScriptSource.
const scripts = new Map();
// url -> requestId, for Network.getResponseBody.
const bodies = new Map();
// url -> resolved source text, however it was obtained.
const sourceCache = new Map();

const engineLog = [];
let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-exc-'))}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--window-size=1920,1080',
        ...(has('--headed') ? [] : ['--headless=new']),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info'),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));
let exit = null;
proc.on('exit', (code, signal) => { exit = { code, signal }; });

let cdp;
try {
    for (let i = 0; i < 80; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) {
                state.version = await r.json();
                break;
            }
        } catch { /* not up yet */ }
        await sleep(250);
    }

    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // A pause has to be resumed or the page stops dead, so the handler runs off
    // the event stream rather than being awaited from the main flow.
    const onPause = async (params) => {
        state.debugger.pauses++;
        const top = (params.callFrames ?? [])[0];
        // Chrome's description is the error *plus* its formatted stack, and the
        // frames come through structured right below it.
        const desc = params.data?.description ?? params.data?.value ?? null;
        const rec = {
            reason: params.reason,
            description: desc === null ? null : String(desc).split('\n')[0],
            frames: (params.callFrames ?? []).slice(0, MAX_FRAMES).map((f) => ({
                fn: f.functionName || null,
                scriptId: f.location?.scriptId ?? null,
                url: f.url || scripts.get(f.location?.scriptId)?.url || null,
                line: (f.location?.lineNumber ?? 0) + 1,
                col: (f.location?.columnNumber ?? 0) + 1,
            })),
            scopes: [],
        };
        // The scope chain is the whole reason to use the Debugger domain: it
        // says which binding held the undefined the throw tried to read from.
        // `global` is skipped: it is ~900 properties of window, none of them the
        // answer, and it buries the local scope that is.
        for (const scope of (top?.scopeChain ?? []).slice(0, 5)) {
            if (!scope.object?.objectId || scope.type === 'global') continue;
            try {
                const { result } = await cdp.send('Runtime.getProperties', {
                    objectId: scope.object.objectId,
                    ownProperties: true,
                    generatePreview: false,
                }, sessionId);
                rec.scopes.push({
                    type: scope.type,
                    props: result.filter((p) => p.value).map((p) => ({
                        name: p.name,
                        type: p.value.type,
                        value: p.value.type === 'undefined' ? 'undefined'
                            : (p.value.description ?? String(p.value.value ?? '')).slice(0, 120),
                    })),
                });
            } catch (err) {
                rec.scopes.push({ type: scope.type, error: String(err.message ?? err) });
            }
        }
        state.pauses.push(rec);
        try {
            await cdp.send('Debugger.resume', undefined, sessionId);
        } catch { /* already resumed or gone */ }
    };

    cdp.on((msg) => {
        const p = msg.params ?? {};
        switch (msg.method) {
            case 'Debugger.scriptParsed':
                scripts.set(p.scriptId, { url: p.url, source: null });
                break;
            case 'Debugger.paused':
                onPause(p).catch(() => { });
                break;
            case 'Runtime.consoleAPICalled': {
                const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
                const m = /@@EXC@@([\s\S]*?)@@END@@/.exec(text);
                if (m) {
                    try {
                        state.records.push(JSON.parse(m[1]));
                    } catch (err) {
                        state.records.push({ parseError: String(err.message ?? err), raw: m[1].slice(0, 400) });
                    }
                } else {
                    state.console.push(`${p.type}: ${text.slice(0, 400)}`);
                }
                break;
            }
            case 'Log.entryAdded':
                state.console.push(`log.${p.entry.level}: ${String(p.entry.text ?? '').slice(0, 400)}`);
                break;
            case 'Runtime.exceptionThrown':
                state.cdpExceptions.push({
                    text: (p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? '').slice(0, 400),
                    url: p.exceptionDetails?.url ?? null,
                    line: (p.exceptionDetails?.lineNumber ?? -1) + 1,
                    col: (p.exceptionDetails?.columnNumber ?? -1) + 1,
                    // turnstile-probe.mjs kept only a truncated description and
                    // dropped this, which is the half that names a position.
                    stack: (p.exceptionDetails?.stackTrace?.callFrames ?? []).slice(0, MAX_FRAMES).map((f) => ({
                        fn: f.functionName || null,
                        url: f.url || null,
                        line: f.lineNumber + 1,
                        col: f.columnNumber + 1,
                    })),
                });
                break;
            case 'Network.requestWillBeSent':
                state.wire.push({ ev: 'req', url: String(p.request?.url ?? '').slice(0, 160), type: p.type });
                break;
            case 'Network.responseReceived':
                state.wire.push({ ev: 'res', status: p.response?.status, url: String(p.response?.url ?? '').slice(0, 160), type: p.type });
                if (p.response?.url && p.requestId) bodies.set(p.response.url, p.requestId);
                break;
            case 'Network.loadingFailed':
                state.wire.push({ ev: 'fail', text: p.errorText, url: String(p.request?.url ?? '').slice(0, 160) });
                break;
        }
    });

    for (const domain of ['Runtime', 'Log', 'Network', 'Page']) {
        await cdp.send(`${domain}.enable`, undefined, sessionId).catch(() => { });
    }

    // Ask for the Debugger domain and record the answer either way, so the
    // report distinguishes "no pause happened" from "pauses are not a thing
    // here".
    try {
        await cdp.send('Debugger.enable', undefined, sessionId);
        await cdp.send('Debugger.setPauseOnExceptions', { state: 'all' }, sessionId);
        state.debugger.supported = true;
    } catch (err) {
        state.debugger.supported = false;
        state.debugger.error = String(err.message ?? err);
    }

    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: BOOTSTRAP }, sessionId)
        .catch((err) => { state.bootstrapError = String(err.message ?? err); });

    await cdp.send('Page.navigate', { url }, sessionId);
    await sleep(SETTLE);

    // The console stream is the primary channel, but a record made in a realm
    // whose console never reached us is still on that realm's window.
    try {
        const res = await cdp.send('Runtime.evaluate', {
            expression: 'JSON.stringify(globalThis.__EXC || [])',
            returnByValue: true,
        }, sessionId);
        const extra = JSON.parse(res.result?.value ?? '[]');
        const known = new Set(state.records.map((r) => `${r.name}|${r.message}|${r.why}`));
        for (const r of extra) {
            if (!known.has(`${r.name}|${r.message}|${r.why}`)) state.records.push({ ...r, viaWindow: true });
        }
    } catch (err) {
        state.windowReadError = String(err.message ?? err);
    }

    // Every position any mechanism named, deduped, with its source context.
    const wanted = new Map();
    const want = (url, line, col, scriptId) => {
        if (!url || !line) return;
        const key = `${url}|${line}|${col}`;
        if (!wanted.has(key)) wanted.set(key, { url, line, col, scriptId: scriptId ?? null });
    };
    for (const r of state.records) for (const f of r.frames ?? []) want(f.file, f.line, f.col);
    for (const p of state.pauses) for (const f of p.frames) want(f.url, f.line, f.col, f.scriptId);
    for (const e of state.cdpExceptions) {
        want(e.url, e.line, e.col);
        for (const f of e.stack) want(f.url, f.line, f.col);
    }

    state.frames = [];
    for (const w of wanted.values()) {
        state.frames.push({ ...w, ...await context(cdp, sessionId, w) });
    }
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

// Resolve a script body and cut out the neighbourhood of one column. Three
// sources in falling order of fidelity: the debugger's own copy is exactly what
// ran; the network body is what arrived; a refetch is a guess that a static
// asset did not change, which is true for challenges.cloudflare.com bundles and
// false for anything session-bound.
async function context(cdp, sessionId, { url, line, col, scriptId }) {
    let source = sourceCache.get(url) ?? null;
    let via = source === null ? null : 'cache';
    if (source === null && scriptId) {
        try {
            const r = await cdp.send('Debugger.getScriptSource', { scriptId }, sessionId);
            if (r.scriptSource) { source = r.scriptSource; via = 'Debugger.getScriptSource'; }
        } catch { /* fall through */ }
    }
    if (source === null && bodies.has(url)) {
        try {
            const r = await cdp.send('Network.getResponseBody', { requestId: bodies.get(url) }, sessionId);
            if (typeof r.body === 'string') {
                source = r.base64Encoded ? Buffer.from(r.body, 'base64').toString('utf8') : r.body;
                via = 'Network.getResponseBody';
            }
        } catch { /* fall through */ }
    }
    if (source === null && /^https?:/.test(url)) {
        try {
            const r = await fetch(url);
            if (r.ok) { source = await r.text(); via = 'refetch'; }
        } catch { /* nothing left to try */ }
    }
    if (source === null) return { via: null, context: null };
    sourceCache.set(url, source);

    const lines = source.split('\n');
    const text = lines[line - 1];
    if (text === undefined) return { via, context: null, note: `source has ${lines.length} lines` };
    const from = Math.max(0, col - 1 - CONTEXT);
    const to = Math.min(text.length, col - 1 + CONTEXT);
    return {
        via,
        lineLength: text.length,
        before: text.slice(from, col - 1),
        at: text.slice(col - 1, Math.min(text.length, col - 1 + 60)),
        after: text.slice(Math.min(text.length, col - 1 + 60), to),
    };
}

state.console = state.console.slice(-60);
state.wire = state.wire.slice(-80);
state.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-40);
if (exit) state.engineExit = exit;

const sourcesDir = arg('--sources', null);
if (sourcesDir) {
    const dir = path.resolve(REPO, sourcesDir);
    await fs.mkdir(dir, { recursive: true });
    for (const [u, s] of sourceCache) {
        const name = u.replace(/^https?:\/\//, '').replace(/[^\w.-]+/g, '_').slice(-120);
        await fs.writeFile(path.join(dir, name), s);
    }
    console.log(`wrote ${sourceCache.size} source(s) to ${path.relative(REPO, dir)}`);
}

const out = arg('--out', null);
const json = JSON.stringify(state, null, 2);
if (out) {
    const p = path.resolve(REPO, out.startsWith('tools/') ? out : path.join('tools/fingerprint', out));
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, json + '\n');
    console.log(`wrote ${path.relative(REPO, p)}`);
}

// The report, not the JSON: a caught TypeError in a minified bundle is a
// position plus 500 characters of context, and that fits on a screen.
console.log(`\n${engine}  ${url}`);
console.log(`debugger: ${state.debugger.supported === true ? `supported, ${state.debugger.pauses} pause(s)` : `unsupported (${state.debugger.error ?? 'no error'})`}`);
console.log(`records: ${state.records.length}  cdp exceptions: ${state.cdpExceptions.length}  frames resolved: ${(state.frames ?? []).filter((f) => f.context !== null).length}/${(state.frames ?? []).length}`);
if (state.error) console.log(`ERROR: ${state.error}`);
if (state.bootstrapError) console.log(`bootstrap not installed: ${state.bootstrapError}`);

for (const r of state.records) {
    console.log(`\n--- ${r.name}: ${r.message}\n    via ${r.why} in ${r.realm ?? '?'}`);
    for (const f of (r.frames ?? []).slice(0, MAX_FRAMES)) {
        console.log(`    at ${f.fn ?? '(anon)'} ${f.file ?? '(no url)'}:${f.line}:${f.col}`);
    }
    if (!r.frames) console.log('    (no structured frames -- prepareStackTrace never fired)');
}
for (const p of state.pauses) {
    console.log(`\n=== pause (${p.reason}) ${p.description ?? ''}`);
    for (const f of p.frames) console.log(`    at ${f.fn ?? '(anon)'} ${f.url ?? '?'}:${f.line}:${f.col}`);
    for (const s of p.scopes) {
        console.log(`    scope ${s.type}: ${s.error ?? s.props.map((x) => `${x.name}=${x.value}`).join(', ').slice(0, 600)}`);
    }
}
for (const f of state.frames ?? []) {
    if (f.context === null) {
        console.log(`\n>>> ${f.url}:${f.line}:${f.col} -- no source (${f.note ?? 'unresolved'})`);
        continue;
    }
    console.log(`\n>>> ${f.url}:${f.line}:${f.col}  (line is ${f.lineLength} chars, via ${f.via})`);
    console.log(`${f.before}\n[[[${f.at}]]]\n${f.after}`);
}
process.exit(0);
