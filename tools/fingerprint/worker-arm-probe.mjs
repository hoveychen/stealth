// How do you get a script into a blob-URL worker before its own code runs?
//
// E2 found that this station assembles and sends its telemetry from blob-URL
// workers, and that reaching into one with the auto-attach pause stalled the
// challenge at round 1, three times. The reading recorded at the time was "the
// worker notices the instrument". The records say otherwise: in every stalled
// run the worker session produced *no* records at all -- not even the recorder's
// own `installed` line -- and its `Runtime.runIfWaitingForDebugger` came back
// `resumed: false`. Nothing was ever installed for the worker to notice. The
// worker was simply never released.
//
// That is a claim about Chrome's inspector plumbing, not about Cloudflare, so it
// is testable here: a local page, a local blob worker, the same `arm()`
// sequences, no real station involved.
//
// Each variant answers one question about a worker paused on start:
//
//   plain     autoAttach without waitForDebuggerOnStart. Does the worker run?
//   evaluate  the E2 shape: pause, fire a non-awaited evaluate, then resume.
//   resume    resume first, then evaluate. Does the ordering unblock it, and is
//             the evaluate still early enough to be there before worker code?
//   preload   no debugger at all: the document realm wraps `Blob` and prepends
//             the recorder to the worker's own source text.
//
// usage: node tools/fingerprint/worker-arm-probe.mjs [--variant name] [--port n]
// env: CHROME
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};

const PORT = Number(arg('--port', '9264'));
const HTTP_PORT = Number(arg('--http-port', '9265'));
const ONLY = arg('--variant', null);
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const MARK = '@@WAP@@';

// The recorder stands in for the real one: it announces itself and wraps the one
// funnel whose absence would be conclusive. Whether a *page* tolerates it is
// E2's question; whether it can be got in at all is this file's.
const RECORDER = `(function () {
  var log = console.log.bind(console);
  function emit(r) { try { log(${JSON.stringify(MARK)} + JSON.stringify(r)); } catch (e) {} }
  try {
    var origFetch = globalThis.fetch;
    if (typeof origFetch === 'function') {
      globalThis.fetch = function (input) {
        emit({ k: 'fetch', url: String((input && input.url) || input || '').slice(0, 120) });
        return origFetch.apply(this === undefined ? globalThis : this, arguments);
      };
    }
  } catch (e) {}
  emit({ k: 'installed', where: String((globalThis.location || {}).href || '?').slice(0, 120),
         worker: typeof globalThis.WorkerGlobalScope !== 'undefined' });
})();`;

// The page builds its worker the way the station does: a blob of source text,
// an object URL, `new Worker`. The worker fetches, so a run that produces no
// fetch record is a worker whose code never reached its own first statement.
const WORKER_SRC = `
  self.postMessage('worker-alive');
  fetch('/beacon?from=worker').then(function () { self.postMessage('worker-fetched'); });
`;
const PAGE = `<!doctype html><meta charset=utf-8><title>worker arm probe</title>
<script>
  var blob = new Blob([${JSON.stringify(WORKER_SRC)}], { type: 'text/javascript' });
  var url = URL.createObjectURL(blob);
  var w = new Worker(url);
  w.onmessage = function (e) { console.log('PAGE-SAW ' + e.data); };
</script>`;

const server = http.createServer((req, res) => {
    if (req.url.startsWith('/beacon')) {
        hits.push(req.url);
        res.writeHead(204).end();
        return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(PAGE);
});
let hits = [];
await new Promise((r) => server.listen(HTTP_PORT, '127.0.0.1', r));

async function runVariant(variant) {
    hits = [];
    const state = { variant, realms: [], records: [], pageConsole: [] };
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'wap-'));
    const proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new',
    ], { stdio: 'ignore' });
    let cdp = null;
    try {
        for (let i = 0; i < 100; i++) {
            try {
                if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) break;
            } catch { /* not up */ }
            await sleep(200);
        }
        cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId: pageSession } = await cdp.send('Target.attachToTarget',
            { targetId, flatten: true });

        // `preload` needs the document realm to rewrite the worker's source, so
        // its recorder is a different script from the one the others evaluate.
        const preload = variant === 'preload'
            ? `${RECORDER}\n(function () {
                 var OrigBlob = Blob;
                 globalThis.Blob = function (parts, opts) {
                   try {
                     if (parts && parts.length === 1 && typeof parts[0] === 'string'
                         && /postMessage|fetch|onmessage/.test(parts[0])) {
                       parts = [${JSON.stringify(RECORDER)} + '\\n' + parts[0]];
                       console.log(${JSON.stringify(MARK)} + JSON.stringify({ k: 'blob-rewritten', n: parts[0].length }));
                     }
                   } catch (e) {}
                   return new OrigBlob(parts, opts);
                 };
                 globalThis.Blob.prototype = OrigBlob.prototype;
               })();`
            : RECORDER;

        async function arm(sid, why) {
            const rec = { session: sid, why: String(why).slice(0, 60), installed: false, resumed: null };
            state.realms.push(rec);
            await cdp.send('Runtime.enable', undefined, sid).catch(() => { });
            await cdp.send('Page.enable', undefined, sid).catch(() => { });
            try {
                await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: preload }, sid);
                rec.installed = true;
            } catch (err) { rec.pageErr = String(err.message ?? err).slice(0, 60); }

            const isWorker = !rec.installed;
            const evaluateIn = () => cdp.send('Runtime.evaluate',
                { expression: RECORDER, awaitPromise: false }, sid)
                .then((r) => { rec.evalOk = !r.exceptionDetails; })
                .catch((err) => { rec.evalErr = String(err.message ?? err).slice(0, 60); });

            // The one line under test. `evaluate` sends before the resume, the
            // E2 shape; `resume` sends after it.
            if (isWorker && variant === 'evaluate') { rec.via = 'evaluate-then-resume'; evaluateIn(); }

            const pauseOnStart = variant !== 'plain' && variant !== 'preload';
            await cdp.send('Target.setAutoAttach',
                { autoAttach: true, waitForDebuggerOnStart: pauseOnStart, flatten: true }, sid)
                .catch(() => { });
            await cdp.send('Network.enable', undefined, sid).catch(() => { });
            const t0 = Date.now();
            await cdp.send('Runtime.runIfWaitingForDebugger', undefined, sid)
                .then(() => { rec.resumed = true; })
                .catch((err) => { rec.resumed = false; rec.resumeErr = String(err.message ?? err).slice(0, 40); });
            rec.resumeMs = Date.now() - t0;

            if (isWorker && variant === 'resume') { rec.via = 'resume-then-evaluate'; await evaluateIn(); }
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
                    } catch { /* malformed */ }
                } else if (state.pageConsole.length < 20) {
                    state.pageConsole.push(text.slice(0, 80));
                }
            }
        });

        await arm(pageSession, 'page');
        await cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP_PORT}/` }, pageSession);
        await sleep(4000);
    } catch (err) {
        state.error = String(err.message ?? err);
    } finally {
        cdp?.close();
        proc.kill('SIGKILL');
        await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
        await sleep(400);
    }
    state.beacons = [...hits];
    return state;
}

const VARIANTS = ['plain', 'evaluate', 'resume', 'preload'];
for (const v of (ONLY ? [ONLY] : VARIANTS)) {
    const s = await runVariant(v);
    const workers = s.realms.filter((r) => !r.installed);
    const inWorker = s.records.filter((r) => r.worker === true || r.k === 'fetch');
    console.log(`=== ${v}`);
    for (const r of s.realms) {
        console.log(`  realm ${r.installed ? 'doc ' : 'wrk '} resumed=${r.resumed} (${r.resumeMs}ms)`
            + ` via=${r.via ?? '-'} evalOk=${r.evalOk ?? '-'} evalErr=${r.evalErr ?? '-'}  ${r.why}`);
    }
    console.log(`  workers seen: ${workers.length}`
        + `  records: ${s.records.map((r) => r.k).join(',') || '(none)'}`);
    console.log(`  worker code ran: ${s.pageConsole.some((c) => /worker-alive/.test(c))}`
        + `   worker fetch reached the server: ${s.beacons.length > 0}`
        + `   recorder inside the worker: ${inWorker.length > 0}`);
    if (s.error) console.log(`  ERROR ${s.error}`);
}

server.close();
