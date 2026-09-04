// Collects the *reference* fingerprint snapshot from the real Google Chrome
// installed on this machine, using the same probe and the same local echo
// server as collect-lightpanda.mjs. This is the target column: "align with real
// Chrome" needs measured ground truth, not remembered values.
//
//   node tools/fingerprint/collect-chrome.mjs [--headed] [--out results/x.json]
//                                             [--chrome-arg SWITCH]...
//
// `--chrome-arg` is repeatable and goes straight to the browser. The reason it
// exists: `--headless=new` fails the scrapingcourse challenge over one token in
// the user agent, so a reference taken headless was a reference taken from a
// client the guard rejects. `--chrome-arg --user-agent=<the headed string>`
// makes the headless arm pass (3/3, results/e4/), which turns it back into a
// legitimate target column that also runs unattended.
//
// Driven over raw CDP rather than Playwright so both engines go through one
// client and any difference in the snapshot comes from the engine, not the
// driver.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, goto, evaluate, sleep, personaScaleFlags } from './cdp.mjs';
import { startEchoServer } from './header-echo.mjs';
import { extractSannysoft, extractCreepJs, SANNYSOFT_URL, CREEPJS_URL } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const headed = process.argv.includes('--headed');
const chromeArgs = process.argv.reduce(
    (acc, a, i) => (a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc),
    [],
);
const outArg = process.argv.indexOf('--out');
const outPath = path.resolve(
    repo,
    outArg !== -1
        ? process.argv[outArg + 1]
        : `tools/fingerprint/results/reference-chrome-${headed ? 'headed' : 'headless'}.json`,
);
const PORT = 9333;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const probeSrc = await fs.readFile(path.join(here, 'probe.js'), 'utf8');
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-chrome-'));

// Kept deliberately minimal: every extra flag moves the reference away from a
// normal user's Chrome, which is the thing we are trying to look like.
const flags = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check', ...personaScaleFlags(),
];
if (!headed) flags.push('--headless=new');
flags.push(...chromeArgs);

const proc = spawn(CHROME, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
const chromeLog = [];
proc.stdout.on('data', (d) => chromeLog.push(String(d)));
proc.stderr.on('data', (d) => chromeLog.push(String(d)));

const engine =
    (headed ? 'chrome-headed' : 'chrome-headless') +
    (chromeArgs.some((a) => a.startsWith('--user-agent=')) ? '-ua' : '');
const snapshot = { engine, flags, version: null, steps: {} };
const fail = (step, e) => {
    snapshot.steps[step] = { __err: String((e && e.stack) || e) };
    console.error(`  ! ${step}: ${(e && e.message) || e}`);
};

try {
    for (let i = 0; i < 100; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            snapshot.version = await r.json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!snapshot.version) throw new Error('Chrome CDP never came up');

    const echo = await startEchoServer(0);
    const echoBase = `http://127.0.0.1:${echo.port}`;
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);

    // No createBrowserContext here: an incognito context is not what a normal
    // profile looks like, and unlike lightpanda, Chrome doesn't need one.
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    console.log('· local header capture');
    try {
        await goto(cdp, sessionId, `${echoBase}/`, { settleMs: 2500 });
        await goto(cdp, sessionId, `${echoBase}/nav`, { settleMs: 1500 });
        snapshot.steps.localHeaders = { requests: echo.records };
    } catch (e) {
        fail('localHeaders', e);
        snapshot.steps.localHeaders = { requests: echo.records, note: 'partial' };
    }

    console.log('· js probe');
    try {
        await goto(cdp, sessionId, `${echoBase}/frame.html`, { settleMs: 500 });
        snapshot.steps.probe = await evaluate(cdp, sessionId, probeSrc, { awaitPromise: true });
    } catch (e) {
        fail('probe', e);
    }

    console.log('· bot.sannysoft.com');
    try {
        await goto(cdp, sessionId, SANNYSOFT_URL, { settleMs: 6000 });
        snapshot.steps.sannysoft = await evaluate(cdp, sessionId, extractSannysoft);
    } catch (e) {
        fail('sannysoft', e);
    }

    console.log('· creepjs');
    try {
        await goto(cdp, sessionId, CREEPJS_URL, { settleMs: 20000 });
        snapshot.steps.creepjs = await evaluate(cdp, sessionId, extractCreepJs);
    } catch (e) {
        fail('creepjs', e);
    }

    await echo.close();
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    snapshot.chromeLog = chromeLog.join('').split('\n').filter(Boolean).slice(-20);
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
    console.log(`wrote ${path.relative(repo, outPath)}`);
    process.exit(0);
}
