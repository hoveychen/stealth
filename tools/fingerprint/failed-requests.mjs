// Which request failed, on every target, while a challenge page loads.
//
// `exception-frames.mjs` caught a `TypeError: Failed to fetch` thrown inside
// Cloudflare's guard VM on this engine, where Chrome throws nothing at all. A
// rejected `fetch` means a whole branch of the guard never runs, and the guard
// has an `unhandledrejection` handler that reports the reason back -- so this is
// worth naming precisely rather than inferring.
//
// `Network.loadingFailed` carries the errorText and whether it was a CORS
// failure; `requestWillBeSent` gives the URL. Both engines, all targets,
// including the cross-origin widget frame (which is a separate target -- see
// `chrome-isolates-cross-origin-iframes`).
//
//   node tools/fingerprint/failed-requests.mjs lightpanda <url> [--settle 30000] [--port 9681]
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const arg = (n, d) => { const i = process.argv.indexOf(n); return i === -1 ? d : process.argv[i + 1]; };
const engine = process.argv[2];
const target = process.argv[3];
if (engine !== 'chrome' && engine !== 'lightpanda' || !target) {
    console.error('usage: failed-requests.mjs <lightpanda|chrome> <url> [--settle ms] [--port n]');
    process.exit(1);
}
const port = Number(arg('--port', '9681'));
const settle = Number(arg('--settle', '30000'));
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

let proc, tmp;
if (engine === 'chrome') {
    const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'failreq-'));
    proc = spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
        '--no-first-run', '--no-default-browser-check', `--user-agent=${UA}`,
        '--force-device-scale-factor=2', '--headless=new'], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    const bin = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
    // No --headed-ua here: it is not a `serve` flag, and this fork already
    // reports a Chrome user agent by default.
    proc = spawn(bin, ['serve', '--host', '127.0.0.1', '--port', String(port)],
        { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 200; i++) {
    try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
const urls = new Map();     // requestId -> url
const failed = [];
const finished = new Set();
try {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const install = async (sid) => {
        try { await cdp.send('Page.enable', {}, sid); } catch { /* not a page */ }
        try { await cdp.send('Network.enable', {}, sid); } catch { /* gone */ }
        try {
            await cdp.send('Target.setAutoAttach',
                { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid);
        } catch { /* does not nest */ }
        try { await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid); } catch { /* not paused */ }
    };
    cdp.on(async (m) => {
        if (m.method === 'Target.attachedToTarget') { install(m.params.sessionId); return; }
        if (m.method === 'Network.requestWillBeSent') {
            urls.set(m.params.requestId, { url: m.params.request?.url, type: m.params.type });
            return;
        }
        if (m.method === 'Network.loadingFinished') { finished.add(m.params.requestId); return; }
        if (m.method === 'Network.loadingFailed') {
            const row = urls.get(m.params.requestId) || {};
            failed.push({
                url: row.url, type: row.type ?? m.params.type,
                errorText: m.params.errorText, canceled: m.params.canceled,
                corsErrorStatus: m.params.corsErrorStatus,
                blockedReason: m.params.blockedReason,
            });
        }
    });
    await install(sessionId);
    await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
    await cdp.send('Page.navigate', { url: target }, sessionId);
    await sleep(settle);
} finally {
    try { cdp.close?.(); } catch { /* already closed */ }
    proc.kill('SIGKILL');
    if (tmp) await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
}

console.log(`${engine}  requests seen: ${urls.size}  finished: ${finished.size}  FAILED: ${failed.length}`);
for (const f of failed) {
    console.log(`  ${f.errorText}${f.canceled ? ' (canceled)' : ''}` +
        `${f.corsErrorStatus ? ' cors=' + JSON.stringify(f.corsErrorStatus) : ''}` +
        `${f.blockedReason ? ' blocked=' + f.blockedReason : ''}\n    ${f.type} ${f.url}`);
}
process.exit(0);
