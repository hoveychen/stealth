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
    console.error('usage: detector-sweep.mjs <lightpanda|chrome> [--out results/x.json] [--proxy socks5h://host:port] [--headed] [--window-size 1920,1080]');
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
const PORT = engine === 'chrome' ? 9334 : 9224;
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
proc?.stdout.on('data', keep);
proc?.stderr.on('data', keep);

const snapshot = { headed: ENDPOINT ? 'remote' : headed, engine, endpoint: ENDPOINT, windowSize, version: null, sites: [] };

try {
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

    for (const { name, url, settleMs } of DETECTORS) {
        const site = { name, url };
        const started = Date.now();
        try {
            await goto(cdp, sessionId, url, { settleMs });
            Object.assign(site, await evaluate(cdp, sessionId, extractReach));
            site.verdictWords = (site.text.match(VERDICT_WORDS) || []).length;
            site.snippet = site.text.replace(/\s+/g, ' ').slice(0, 220);
            delete site.text;
            // A site that answers on the previous URL never navigated at all.
            site.navigated = site.href === url || site.href.startsWith(url);
        } catch (e) {
            site.error = String((e && e.message) || e).slice(0, 160);
        }
        site.ms = Date.now() - started;
        snapshot.sites.push(site);
        console.log(
            `${String(site.ms).padStart(6)}ms ${name.padEnd(17)} ` +
            (site.error
                ? `ERR ${site.error}`
                : `nodes=${String(site.nodes).padStart(5)} text=${String(site.textLength).padStart(6)} verdictWords=${site.verdictWords} w=${site.innerWidth}${site.navigated ? '' : ' NAVIGATION-DID-NOT-HAPPEN'}`),
        );
    }
    cdp.close();
} finally {
    proc?.kill('SIGKILL');
    snapshot.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-40);
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`wrote ${path.relative(repo, outPath)}`);
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    process.exit(0);
}
