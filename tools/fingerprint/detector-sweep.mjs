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
import { Cdp, newPage, goto, evaluate, sleep } from './cdp.mjs';
import { DETECTORS, VERDICT_WORDS, extractReach } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: detector-sweep.mjs <lightpanda|chrome> [--out results/x.json] [--proxy socks5h://host:port]');
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
const PORT = engine === 'chrome' ? 9334 : 9224;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

let proc, profile;
if (engine === 'chrome') {
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-sweep-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--headless=new',
        ...(proxy ? [`--proxy-server=${proxy}`] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(path.join(repo, 'zig-out/bin/lightpanda'), [
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
proc.stdout.on('data', keep);
proc.stderr.on('data', keep);

const snapshot = { engine, version: null, sites: [] };

try {
    for (let i = 0; i < 120; i++) {
        try {
            snapshot.version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!snapshot.version) throw new Error(`${engine} CDP never came up`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
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
                : `nodes=${String(site.nodes).padStart(5)} text=${String(site.textLength).padStart(6)} verdictWords=${site.verdictWords}${site.navigated ? '' : ' NAVIGATION-DID-NOT-HAPPEN'}`),
        );
    }
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    snapshot.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-40);
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`wrote ${path.relative(repo, outPath)}`);
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    process.exit(0);
}
