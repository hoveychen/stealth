// Kasada's verdict on one visit, read off the `/tl` response instead of off
// whether the station served the page.
//
//   node tools/fingerprint/kasada-verdict.mjs <lightpanda|chrome> [--runs 3] [--port 9350]
//
// Why not just run antibot-sweep. A station's pass/refuse is the *end* of a
// chain -- guard verdict, then rate limit, then reload -- and the middle of that
// chain moves on its own: `antibot-stations-pass-in-windows` is a whole section
// of README.md about DataDome opening and closing for every binary in the same
// hour. So a single sweep reading proves nothing and the answer costs an
// alternating A/B.
//
// The `/tl` response is one step earlier and says more. Measured on x-hyatt in
// one sitting, same route, minutes apart:
//
//   Chrome          200  application/json  15 bytes  x-kpsdk-cr: true  x-kpsdk-r: 1-B1RFUHs
//   this engine     200  text/plain         0 bytes  x-kpsdk-cr: true  (no x-kpsdk-r)
//
// Both are cleared to hold a cookie; only one is handed a ticket. So
// `x-kpsdk-r` on the POST's response is the guard's own answer to "is this a
// browser", read directly, in about ten seconds, with no station window in the
// way.
//
// Nothing is injected into the page and Runtime.enable is never sent: Kasada
// withholds clearance from a client that has sent it (README, ks-canadagoose),
// so the reading is taken entirely off Network events.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';
import { headedUserAgent } from './fo-harness.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: kasada-verdict.mjs <lightpanda|chrome> [--runs N] [--port P] [--url U] [--settle MS]');
    process.exit(2);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const runs = Number(arg('--runs', 3));
const basePort = Number(arg('--port', 9350));
const target = arg('--url', 'https://www.hyatt.com/');
const settle = Number(arg('--settle', 11000));
// Chrome runs headed by default here, because that is the arm the station
// passes. --headless asks the other question: whether the ticket survives
// headless, which separates "this engine is missing something" from "anything
// without a window is missing it".
const headless = process.argv.includes('--headless');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');

// The same user agent on both arms, so the only thing that varies is the
// engine. Chrome headless announces itself otherwise, and that is a tell of its
// own rather than the one being measured.
// Ask the browser for its user agent instead of writing the version down.
//
// This was a hardcoded `Chrome/151.0.0.0`. Chrome moved to 152 and the guards
// began refusing the mismatch: on 2026-09-10 `cf-verdict.mjs` -- same constant,
// same use -- read `served=false` on BOTH arms including its control, on a
// station `antibot-sweep chrome --headed-ua` passed in the same minute. Nothing
// in the code had changed; the reference arm moved on its own. A criterion tool
// that silently reads false on a passing station invalidates every knob measured
// through it.
//
// Lazily, because only the Chrome arm sends it and probing costs a browser
// launch. The probe throws rather than falling back to a constant -- a silent
// fallback is how this failed in the first place.
let UA = null;
async function chromeUserAgent() {
    if (UA === null) UA = await headedUserAgent(basePort + 900);
    return UA;
}

async function once(port) {
    const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'kasada-verdict-'));
    const proc = engine === 'chrome'
        ? spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
            '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), `--user-agent=${await chromeUserAgent()}`,
            ...(headless ? ['--headless=new'] : [])],
        { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)],
            { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.stdout.resume();
    proc.stderr.resume();
    for (let i = 0; i < 200; i++) {
        try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
    }

    const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
    const out = { documents: [], tl: [] };
    try {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        cdp.on((m) => {
            if (m.method !== 'Network.responseReceived') return;
            const r = m.params.response;
            const url = String(r.url);
            if (m.params.type === 'Document') {
                out.documents.push({ url, status: r.status });
            }
            if (url.endsWith('/tl')) {
                const h = r.headers || {};
                out.tl.push({
                    status: r.status,
                    contentType: h['content-type'],
                    contentLength: h['content-length'],
                    cr: h['x-kpsdk-cr'],
                    // The ticket. Present on Chrome's, absent on ours.
                    r: h['x-kpsdk-r'],
                    st: h['x-kpsdk-st'],
                });
            }
        });
        await cdp.send('Page.enable', {}, sessionId);
        await cdp.send('Network.enable', {}, sessionId);
        await cdp.send('Page.navigate', { url: target }, sessionId);
        await sleep(settle);
    } finally {
        cdp.close();
        proc.kill('SIGKILL');
        await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
    }
    return out;
}

for (let i = 0; i < runs; i++) {
    const out = await once(basePort + i);
    const tl = out.tl[0];
    const docs = out.documents.map((d) => d.status).join('->') || '(none)';
    console.log(`${engine}${headless ? ' (headless)' : ''} run ${i + 1}: doc=${docs} ` +
        (tl
            ? `tl=${tl.status} ${tl.contentType} len=${tl.contentLength} cr=${tl.cr} r=${tl.r ?? '(absent)'}`
            : 'tl=(no POST)'));
}
