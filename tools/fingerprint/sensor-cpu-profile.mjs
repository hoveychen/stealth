// Where a guard's collection routine spends its time, taken off Chrome's own
// sampling profiler.
//
//   node tools/fingerprint/sensor-cpu-profile.mjs https://www.macys.com/ [--port 10370] [--ms 6000] [--out results/x.json]
//
// Why this exists. Akamai's macys interstitial writes a number in cleartext at
// the head of every `sensor_data` POST -- `3;0;1;2048;<n>;<sitekey>;A,B,...`,
// where A is 627-650 from headed Chrome and 16-20 from this engine, twice each
// on the real site. Both arms send the same three POSTs in the same order now,
// so that field is the one cleartext disagreement left, and the wire timestamps
// say it is not elapsed time since the sensor script loaded (Chrome POSTs 14ms
// after it arrives). It is work: Chrome runs ~630ms of *something* inside the
// challenge script that this engine finishes in ~16ms.
//
// Reading the 519KB obfuscated challenge script to find that something is the
// expensive way. A CPU profile names it directly -- and, because the profile
// carries `url:line:column` for every frame, the answer comes back as offsets
// into that script, which is how the earlier work on this station navigated it.
//
// Chrome only. lightpanda has no Profiler domain, and the question here is what
// the *reference* does, not what we do.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const url = process.argv[2];
if (!url || url.startsWith('--')) {
    console.error('usage: sensor-cpu-profile.mjs <url> [--port N] [--ms N] [--out path] [--headless]');
    process.exit(2);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const PORT = Number(arg('--port', 10370));
const budgetMs = Number(arg('--ms', 6000));
const outPath = path.resolve(repo, arg('--out', 'tools/fingerprint/results/sensor-profile.json'));
// Where to save every script the page loaded, taken off the wire with
// Network.getResponseBody. The profile answers "which function", in
// `url:line:column` -- and a column offset into a 500KB obfuscated bundle is
// only an answer if the bundle is on disk to read at that offset. Same run as
// the profile on purpose: these scripts are generated per session, so a second
// fetch of the same URL is a different program.
const bodyDir = arg('--body-dir', null);
// Headed by default, for the same reason the antibot sweep prefers it: the
// headed arm is the one that clears these stations, and a profile of a run that
// was refused describes a different code path.
const headless = process.argv.includes('--headless');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-profile-'));
const proc = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check', ...personaScaleFlags(),
    '--window-size=1920,1080',
    ...(headless ? ['--headless=new'] : []),
], { stdio: 'ignore' });

try {
    let version = null;
    for (let i = 0; i < 100; i++) {
        try {
            version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
            break;
        } catch { await sleep(200); }
    }
    if (!version) throw new Error('chrome CDP never came up');

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // The wire, so the profile can be cut at the POST rather than at a guessed
    // wall-clock offset: what is wanted is the work *before* the first payload
    // leaves, and that instant is only knowable from the request.
    const wire = [];
    const t0 = Date.now();
    let firstPost = null;
    const urls = new Map();
    const saves = [];
    let saved = 0;
    cdp.on((msg) => {
        const p = msg.params ?? {};
        if (bodyDir && msg.method === 'Network.loadingFinished') {
            const u = urls.get(p.requestId);
            if (u) {
                // Fire and forget, but keep the promise: the run must not end
                // before the writes do.
                saves.push(cdp.send('Network.getResponseBody', { requestId: p.requestId }, sessionId)
                    .then(async (r) => {
                        const name = `${String(saved++).padStart(2, '0')}-${u.replace(/^https?:\/\//, '').replace(/[^\w.=-]+/g, '_').slice(0, 90)}`;
                        await fs.writeFile(path.join(bodyDir, name),
                            r.base64Encoded ? Buffer.from(r.body, 'base64') : r.body);
                    })
                    .catch(() => { /* evicted, or a body the browser never kept */ }));
            }
        }
        if (msg.method === 'Network.requestWillBeSent') {
            urls.set(p.requestId, p.request?.url ?? '');
            const e = { ms: Date.now() - t0, method: p.request?.method, url: p.request?.url, postLen: p.request?.postData?.length };
            wire.push(e);
            if (e.method === 'POST' && firstPost === null) firstPost = e;
        } else if (msg.method === 'Network.responseReceived') {
            wire.push({ ms: Date.now() - t0, res: p.response?.status, url: p.response?.url });
        }
    });
    await cdp.send('Network.enable', { maxPostDataSize: 4096 }, sessionId);
    await cdp.send('Profiler.enable', undefined, sessionId);
    // 100us. The default 1ms would put the whole of a 16ms collection in a
    // dozen samples, and this instrument exists to compare a 16ms arm against a
    // 630ms one.
    await cdp.send('Profiler.setSamplingInterval', { interval: 100 }, sessionId);
    await cdp.send('Profiler.start', undefined, sessionId);

    if (bodyDir) await fs.mkdir(bodyDir, { recursive: true });
    await cdp.send('Page.navigate', { url }, sessionId);
    const deadline = Date.now() + budgetMs;
    // Stop shortly after the first payload goes out, not at the first sight of
    // it: the tail is where a collection that kept running would show.
    while (Date.now() < deadline && !(firstPost && Date.now() - t0 > firstPost.ms + 300)) await sleep(50);

    const { profile: cpu } = await cdp.send('Profiler.stop', undefined, sessionId);
    await Promise.all(saves);
    cdp.close();

    // Self time per node, in profile order, so the summary is readable without
    // a flame chart. `timeDeltas[i]` is the gap before `samples[i]`.
    const byId = new Map(cpu.nodes.map((n) => [n.id, n]));
    const self = new Map();
    let clock = cpu.startTime;
    for (let i = 0; i < cpu.samples.length; i++) {
        clock += cpu.timeDeltas[i] ?? 0;
        const id = cpu.samples[i];
        self.set(id, (self.get(id) ?? 0) + (cpu.timeDeltas[i] ?? 0));
    }
    const label = (n) => {
        const f = n.callFrame;
        const where = f.url ? `${f.url.split('/').slice(-1)[0]}:${f.lineNumber}:${f.columnNumber}` : '';
        return `${f.functionName || '(anonymous)'} @ ${where}`;
    };
    const top = [...self.entries()]
        .map(([id, us]) => ({ us: Math.round(us), ms: +(us / 1000).toFixed(1), node: label(byId.get(id)) }))
        .sort((a, b) => b.us - a.us)
        .slice(0, 40);

    // The caller chain for the heaviest frames, because an obfuscated name on
    // its own says nothing about which collection step it belongs to.
    const parent = new Map();
    for (const n of cpu.nodes) for (const c of n.children ?? []) parent.set(c, n.id);
    const chain = (id) => {
        const out = [];
        for (let cur = id; cur !== undefined && out.length < 8; cur = parent.get(cur)) out.push(label(byId.get(cur)));
        return out;
    };
    const heaviest = [...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8)
        .map(([id, us]) => ({ ms: +(us / 1000).toFixed(1), chain: chain(id) }));

    const out = {
        url,
        startedAt: new Date(t0).toISOString(),
        version,
        firstPost,
        totalSamples: cpu.samples.length,
        spanMs: +((cpu.endTime - cpu.startTime) / 1000).toFixed(1),
        top,
        heaviest,
        wire: wire.slice(0, 200),
        profile: cpu,
    };
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(out, null, 2) + '\n');
    console.log(`first POST at ${firstPost?.ms ?? '-'}ms, ${cpu.samples.length} samples over ${out.spanMs}ms`);
    for (const t of top.slice(0, 15)) console.log(`${String(t.ms).padStart(7)}ms  ${t.node}`);
    console.log(`wrote ${path.relative(repo, outPath)}`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}
