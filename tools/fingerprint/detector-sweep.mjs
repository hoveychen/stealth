// Runs one engine past every public bot detector in sites.mjs and records, per
// site, whether the page ran at all and what verdict text it produced.
//
//   node tools/fingerprint/detector-sweep.mjs <lightpanda|chrome> [--out results/x.json]
//
// The collectors measure *values* against Chrome; this measures completion.
// "One of ten live detectors finishes" is a different and worse finding than
// "one property is off", so it gets its own run and its own baseline file.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep, personaScaleFlags, PERSONA_DEVICE_SCALE_FACTOR } from './cdp.mjs';
import { DETECTORS, VERDICT_WORDS, extractReach } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: detector-sweep.mjs <lightpanda|chrome> [--out results/x.json] [--proxy socks5h://host:port] [--headed] [--window-size 1920,1080] [--only creep] [--settle 3000] [--port 9224]');
    process.exit(2);
}
const outArg = process.argv.indexOf('--out');
const outPath = path.resolve(
    repo,
    outArg !== -1 ? process.argv[outArg + 1] : `tools/fingerprint/results/detectors-${engine}.json`,
);
// A machine whose default route is a fake-IP tunnel drops handshakes
// intermittently and blames the engine for it (see the TLS section of the
// README), so a sweep that has to be trusted runs through a plain proxy.
const proxyArg = process.argv.indexOf('--proxy');
const proxy = proxyArg !== -1 ? process.argv[proxyArg + 1] : null;
// Every detector in the list lays out responsively, so a node count only means
// something next to the width it was taken at. Left to itself a headed Chrome
// opens at whatever size the window manager feels like -- around 1200 wide
// here -- and the resulting baseline silently disagrees with any other run.
// Pin it, and record what the page actually saw (see extractReach).
const sizeArg = process.argv.indexOf('--window-size');
const windowSize = sizeArg !== -1 ? process.argv[sizeArg + 1] : '1920,1080';
if (!/^\d+,\d+$/.test(windowSize)) {
    console.error(`--window-size wants WIDTH,HEIGHT, got ${windowSize}`);
    process.exit(2);
}
// Headless Chrome is not a safe stand-in for the reference: some sites treat it
// differently, and some of its own APIs report differently (speechSynthesis
// fills its voice list too late for CreepJS to see it). --headed makes the
// reference column a real window.
const headed = process.argv.includes('--headed');
// One detector hanging costs every detector after it in the list: the engine
// under test is a single process serving the whole loop, so a stall in
// Runtime.enable or Runtime.evaluate leaves the rest of the pages reading as
// timeouts that have nothing to do with the pages themselves (see
// watchdog-stall-cascades-into-fake-failures). Three switches, all borrowed
// from antibot-sweep.mjs, are what it takes to read one page on its own:
// --only picks it, --settle says how long to leave it alone (the stalls are
// settle-dependent), and --port keeps the run off a port a peer session's
// engine already answers on.
const onlyArg = process.argv.indexOf('--only');
const only = onlyArg !== -1 ? process.argv[onlyArg + 1] : null;
const settleArg = process.argv.indexOf('--settle');
const settleOverride = settleArg !== -1 ? Number(process.argv[settleArg + 1]) : null;
if (settleOverride !== null && !Number.isFinite(settleOverride)) {
    console.error(`--settle wants milliseconds, got ${process.argv[settleArg + 1]}`);
    process.exit(2);
}
const detectors = DETECTORS.filter((d) => !only || d.name.includes(only));
if (detectors.length === 0) {
    console.error(`--only ${only} matched no detector`);
    process.exit(2);
}
const portArg = process.argv.indexOf('--port');
const PORT = portArg !== -1 ? Number(process.argv[portArg + 1]) : (engine === 'chrome' ? 9334 : 9224);
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// CDP_ENDPOINT drives a Chrome this script did not start -- in practice the
// headed Linux Chrome in the container (tools/fingerprint/linux-chrome.mjs, and
// sweep-linux-baseline.mjs which wires the two together).
//
// The reference column has to be that browser now. The engine claims Linux as of
// G21, so every platform-specific row measured against the macOS Chrome on this
// machine reads as a gap against a browser we deliberately no longer imitate --
// the G21 re-sweep spent its largest single finding, browserleaks-js at -176, on
// exactly that: 199 macOS voices against 19 Linux ones, one <br> apiece.
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;
if (ENDPOINT && engine !== 'chrome') {
    console.error('CDP_ENDPOINT only makes sense with the chrome engine');
    process.exit(2);
}

let proc, profile;

// Spawning is a function rather than a straight line because one detector can
// cost the engine: a 30-second tick in lightpanda ends with
// `cdp closing connection reason="pending terminate"` (Watchdog.zig ->
// requestTerminate -> CDP.tick), and after that every detector still on the
// list reads as a timeout of its own. Measured on the twelve-page suite:
// `deviceinfo` wedged and the SIX pages after it all came back as 30s
// timeouts. So the loop restarts the engine instead of carrying a dead socket.
async function launch() {
if (ENDPOINT) {
    // Nothing to spawn; the viewport is still pinned below, per site.
} else if (engine === 'chrome') {
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-sweep-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        `--window-size=${windowSize}`,
        ...(headed ? [] : ['--headless=new']),
        ...(proxy ? [`--proxy-server=${proxy}`] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    // lightpanda has no viewport flag; Viewport.default is already 1920x1080,
    // which is what --window-size defaults to. extractReach records the width
    // each page actually saw, so a mismatch shows up in the results instead of
    // hiding inside a node count.
    // LP_BIN so a worktree can sweep with the main checkout's build instead of
    // duplicating a 215MB link, the same knob verdicts-lightpanda.mjs takes.
    proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
        ...(proxy ? ['--http-proxy', proxy] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc?.stdout.on('data', keep);
proc?.stderr.on('data', keep);
}

async function teardown() {
    proc?.kill('SIGKILL');
    proc = undefined;
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    profile = undefined;
    // A killed browser leaves its port in TIME_WAIT for a moment; the version
    // poll in session() covers that, but give the pid a beat to actually go.
    await sleep(500);
}

// Drain both streams. lightpanda writes ~550KB of INFO-level log over a sweep
// this long; an unread pipe fills at 64KB and the engine's next write blocks
// forever, which from the client side looks exactly like the detector hanging
// the browser — Page.navigate stops returning and Runtime.evaluate times out.
// The first version of this sweep left them unread and blamed three sites for
// it. The collectors keep their tail for the snapshot, so do the same.
const engineLog = [];
const keep = (d) => {
    engineLog.push(String(d));
    if (engineLog.length > 4000) engineLog.splice(0, 2000);
};
const snapshot = { headed: ENDPOINT ? 'remote' : headed, engine, endpoint: ENDPOINT, windowSize, only, settleOverride, version: null, sites: [] };

// An engine, a page on it, and the viewport pinned. Called once, and again
// after a detector takes the engine down with it.
async function session() {
    await launch();
    for (let i = 0; i < 120; i++) {
        try {
            snapshot.version = await (await fetch(`${ENDPOINT ?? `http://127.0.0.1:${PORT}`}/json/version`)).json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!snapshot.version) throw new Error(`${engine} CDP never came up`);

    const cdp = await Cdp.connect(ENDPOINT ?? `http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        // One browser context, one page, reused for every site: lightpanda
        // rejects a second concurrent context.
        ({ sessionId } = await newPage(cdp));
        await cdp.send('Runtime.enable', {}, sessionId);
    }

    // --window-size alone is not enough: macOS clamps a real Chrome window to
    // the display, so asking for 1920 on a 1512-wide screen quietly gives
    // 1512 and the baseline disagrees with lightpanda's 1920 default all over
    // again. Both engines implement setDeviceMetricsOverride, so state the
    // viewport rather than inherit it.
    //
    // The scale has to agree with the launch switch or it undoes it. Only
    // Chrome is moved by this parameter: lightpanda ignores it outright
    // (src/cdp/domains/emulation.zig warns for anything but 0/1 and applies
    // none of them), so it keeps the 1 that costs it no warning while Chrome
    // gets the scale the engine claims to every page. Passing 1 to both -- the
    // shape this line had -- pinned only the reference arm, to the wrong scale.
    const [w, h] = windowSize.split(',').map(Number);
    await cdp.send('Emulation.setDeviceMetricsOverride', {
        width: w, height: h, deviceScaleFactor: engine === 'chrome' ? PERSONA_DEVICE_SCALE_FACTOR : 1, mobile: false,
    }, sessionId);
    return { cdp, sessionId };
}

/// Is this engine still there? `Target.getTargets` touches no page, and the
/// answer needs a deadline of its own: Cdp.send waits 30 seconds, which is
/// longer than the stall it is being asked about. A closed socket throws on the
/// way out, which is the fast no.
async function answersPing(live) {
    if (!live) return false;
    try {
        return await Promise.race([
            live.cdp.send('Target.getTargets').then(() => true),
            sleep(5000).then(() => false),
        ]);
    } catch {
        return false;
    }
}

try {
    let live = await session();

    for (const { name, url, settleMs } of detectors) {
        const site = { name, url };
        const started = Date.now();
        try {
            await goto(live.cdp, live.sessionId, url, { settleMs: settleOverride ?? settleMs });
            Object.assign(site, await evaluate(live.cdp, live.sessionId, extractReach));
            site.verdictWords = (site.text.match(VERDICT_WORDS) || []).length;
            site.snippet = site.text.replace(/\s+/g, ' ').slice(0, 220);
            delete site.text;
            // A site that answers on the previous URL never navigated at all.
            site.navigated = site.href === url || site.href.startsWith(url);
        } catch (e) {
            site.error = String((e && e.message) || e).slice(0, 160);
        }
        site.ms = Date.now() - started;
        // The engine may not have survived this page. Restart it rather than
        // carry a dead socket through the rest of the list, and mark the row:
        // a suite that restarted mid-run is not the same reading as one that
        // did not.
        if (site.error && !(await answersPing(live))) {
            site.engineRestarted = true;
            live?.cdp.close();
            live = null;
            await teardown();
            live = await session();
        }
        snapshot.sites.push(site);
        console.log(
            `${String(site.ms).padStart(6)}ms ${name.padEnd(17)} ` +
            (site.error
                ? `ERR ${site.error}`
                : `nodes=${String(site.nodes).padStart(5)} text=${String(site.textLength).padStart(6)} verdictWords=${site.verdictWords} w=${site.innerWidth}${site.navigated ? '' : ' NAVIGATION-DID-NOT-HAPPEN'}`) +
            (site.engineRestarted ? ' ENGINE-RESTARTED' : ''),
        );
    }
    live?.cdp.close();
} finally {
    proc?.kill('SIGKILL');
    snapshot.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-40);
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`wrote ${path.relative(repo, outPath)}`);
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    process.exit(0);
}
