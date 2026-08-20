// Collects a fingerprint snapshot from this repo's lightpanda build.
//
//   node tools/fingerprint/collect-lightpanda.mjs [--out results/<name>.json]
//
// Spawns `zig-out/bin/lightpanda serve` itself, drives it over raw CDP, and
// writes one structured JSON snapshot. Deliberately never uses screenshots:
// Page.captureScreenshot in this engine returns a fixed @embedFile placeholder
// PNG (src/cdp/domains/page.zig), so image output proves nothing.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep } from './cdp.mjs';
import { startEchoServer } from './header-echo.mjs';
import { extractSannysoft, extractCreepJs, SANNYSOFT_URL, CREEPJS_URL } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const outArg = process.argv.indexOf('--out');
const outPath = path.resolve(
    repo,
    outArg !== -1 ? process.argv[outArg + 1] : 'tools/fingerprint/results/before-lightpanda.json',
);
const PORT = 9223;

const probeSrc = await fs.readFile(path.join(here, 'probe.js'), 'utf8');

// LP_BIN so a worktree can collect with the main checkout's build instead of
// duplicating a 215MB link, the same knob detector-sweep.mjs and run-expr.mjs
// take. Without it a worktree run dies on a spawn ENOENT for its own empty
// zig-out.
const bin = process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda');
const serverLog = [];
const proc = spawn(bin, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', (d) => serverLog.push(String(d)));
proc.stderr.on('data', (d) => serverLog.push(String(d)));

const snapshot = {
    engine: 'lightpanda',
    version: null,
    steps: {},
};

const fail = (step, e) => {
    snapshot.steps[step] = { __err: String((e && e.stack) || e) };
    console.error(`  ! ${step}: ${(e && e.message) || e}`);
};

try {
    // Wait for the CDP port to answer.
    for (let i = 0; i < 50; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            snapshot.version = await r.json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!snapshot.version) throw new Error('lightpanda CDP never came up');

    const echo = await startEchoServer(0);
    const echoBase = `http://127.0.0.1:${echo.port}`;
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);

    // lightpanda rejects a second concurrent browser context ("Cannot have more
    // than one browser context at a time"), so every step reuses one page.
    const { sessionId } = await newPage(cdp);

    // --- 1. request headers on a local origin -------------------------------
    console.log('· local header capture');
    try {
        await goto(cdp, sessionId, `${echoBase}/`, { settleMs: 2500 });
        // Same-origin navigation, to see whether Sec-Fetch-Site changes.
        await goto(cdp, sessionId, `${echoBase}/nav`, { settleMs: 1500 });
        snapshot.steps.localHeaders = { requests: echo.records };
    } catch (e) {
        fail('localHeaders', e);
        snapshot.steps.localHeaders = { requests: echo.records, note: 'partial' };
    }

    // --- 2. JS fingerprint surface ------------------------------------------
    console.log('· js probe');
    try {
        await goto(cdp, sessionId, `${echoBase}/frame.html`, { settleMs: 500 });
        snapshot.steps.probe = await evaluate(cdp, sessionId, probeSrc, { awaitPromise: true });
    } catch (e) {
        fail('probe', e);
    }

    // --- 3. bot.sannysoft.com -----------------------------------------------
    console.log('· bot.sannysoft.com');
    try {
        await goto(cdp, sessionId, SANNYSOFT_URL, { settleMs: 6000 });
        snapshot.steps.sannysoft = await evaluate(cdp, sessionId, extractSannysoft);
    } catch (e) {
        fail('sannysoft', e);
    }

    // --- 4. CreepJS ---------------------------------------------------------
    console.log('· creepjs');
    try {
        await goto(cdp, sessionId, CREEPJS_URL, { settleMs: 15000 });
        snapshot.steps.creepjs = await evaluate(cdp, sessionId, extractCreepJs);
    } catch (e) {
        fail('creepjs', e);
    }

    await echo.close();
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    snapshot.serverLog = serverLog.join('').split('\n').filter(Boolean).slice(-40);
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`wrote ${path.relative(repo, outPath)}`);
    // Don't linger on stray sockets/timers — the snapshot is already on disk.
    process.exit(0);
}
