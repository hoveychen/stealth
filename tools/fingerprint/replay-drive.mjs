// Drive one engine at one URL and print what a page-side probe collected.
//
//   node tools/fingerprint/replay-drive.mjs --arm lp     --url http://127.0.0.1:10600/ --settle 4000
//   node tools/fingerprint/replay-drive.mjs --arm chrome --url http://127.0.0.1:10600/ --settle 1200
//
// The probe itself is injected by the replay server (`--inject probes/x.js`),
// not from here: it has to wrap primitives before the page's own code runs.
// This tool only navigates, waits, and reads `window.__probe` back out.
//
// Both arms get the *same* CDP domains -- which here is none beyond the
// implicit ones. `Runtime.enable` is measurable from the page and has changed
// an Akamai verdict before; `Debugger.enable` stops the guard dead after about
// 5900 statements in either engine. Do not add either to make a reading easier.
//
// COMPARE BY CYCLE, NOT BY WALL CLOCK. The interstitial reloads itself. One
// pass of it takes Chrome about 800ms and this engine about 2.5s, so a settle
// picked to catch our first pass catches Chrome's second, and totals read out
// of `window.__probe` then belong to different cycles. `--settle` is per arm
// for exactly that reason.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const arm = arg('--arm', 'lp');
const url = arg('--url', null);
const settle = Number(arg('--settle', 3000));
const port = Number(arg('--port', arm === 'lp' ? 10611 : 10612));
const expr = arg('--expr', 'JSON.stringify(self.__probe || null)');
const outPath = arg('--out', null);
if (!url) {
    console.error('usage: replay-drive.mjs --arm lp|chrome --url URL [--settle MS] [--port N] [--expr JS] [--out FILE]');
    process.exit(2);
}

const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// A fresh profile per run, always: a warm profile carries the HTTP cache and
// the cookie jar of the previous pass, and the counter under study is the one
// that only the *first* pass of a cold browser produces.
const profile = arm === 'chrome' ? await fs.mkdtemp(path.join(os.tmpdir(), 'fp-replay-')) : null;
const proc = arm === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${port}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        '--window-size=1920,1080',
        ...(process.argv.includes('--headless') ? ['--headless=new'] : []),
    ], { stdio: 'ignore' })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)],
        { stdio: ['ignore', 'ignore', 'inherit'] });

try {
    let version = null;
    for (let i = 0; i < 100; i++) {
        try {
            version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
            break;
        } catch { await sleep(200); }
    }
    if (!version) throw new Error(`${arm} CDP never came up on ${port}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Page.navigate', { url }, sessionId);
    await sleep(settle);

    const res = await cdp.send('Runtime.evaluate', {
        expression: expr, returnByValue: true, awaitPromise: false,
    }, sessionId);
    const text = res.result?.value ?? null;
    if (outPath) {
        await fs.writeFile(path.resolve(repo, outPath), text ?? 'null');
        console.error(`${arm}: wrote ${outPath}`);
    } else {
        console.log(text);
    }
    // Closing the target first keeps this engine's debug logs from being cut
    // off mid-flush, the same reason the prop-read probes do it.
    await cdp.send('Target.closeTarget', { targetId }).catch(() => {});
} finally {
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
}
