// What a page asks the server for, counted at the server, for both arms.
//
//   node tools/fingerprint/wire-census.mjs                 # both arms, one table
//   node tools/fingerprint/wire-census.mjs --only chrome   # one arm
//   node tools/fingerprint/wire-census.mjs --json /tmp/census.json
//
// Every other instrument in this directory reads the page: a property, a
// computed style, a payload the guard assembled. This one reads the *server*,
// which is the one vantage point a guard has that no amount of JS-surface
// fidelity can reach. A duplicate `<img>` request was invisible to every probe
// in the harness and plain in an access log; absence is the other half of it --
// a request a real browser makes and this engine does not.
//
// So the page below names a subresource in every way a page can name one, the
// server counts each path it is asked for, and the table is the diff. A row
// where the two arms disagree is a wire difference, and unlike a property
// reading it is one the origin sees directly.
//
// The count matters as much as the presence: `1 vs 2` on the same path is the
// duplicate-fetch bug, `0 vs 1` is an absent request.
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const only = arg('--only', null);
const jsonOut = arg('--json', null);
const sitePort = Number(arg('--site-port', 38682));
const cdpPort = Number(arg('--port', 9352));
const settle = Number(arg('--settle', 3000));

const PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    'base64');

// One page, every way a document can name a subresource. `never-used` and
// `unused-bg` are the controls: a selector that matches nothing must not be
// fetched, so a row that appears on an arm is over-fetching, not fidelity.
const PAGE = `<!doctype html><meta charset=utf-8><title>wire census</title>
<link rel="stylesheet" href="/s/sheet.css">
<link rel="preload" as="image" href="/s/preload-image.png">
<link rel="prefetch" href="/s/prefetch.png">
<link rel="dns-prefetch" href="//127.0.0.1">
<link rel="icon" href="/s/favicon.png">
<link rel="manifest" href="/s/app.webmanifest">
<body>
<div class="bg">bg</div>
<div class="listy"><ul><li>item</li></ul></div>
<div class="bordered">bordered</div>
<div class="cursorly">cursor</div>
<div class="masked">masked</div>
<span class="fonted">fonted text</span>

<img id="plain" src="/s/plain.png">
<img id="srcset" src="/s/srcset-fallback.png" srcset="/s/srcset-1x.png 1x, /s/srcset-2x.png 2x">
<img id="sizes" src="/s/sizes-fallback.png" srcset="/s/sizes-400.png 400w, /s/sizes-800.png 800w" sizes="100vw">
<img id="lazy" src="/s/lazy.png" loading="lazy">
<picture>
  <source srcset="/s/picture-webp.png" type="image/png">
  <img src="/s/picture-fallback.png">
</picture>
<video poster="/s/poster.png" preload="none"><source src="/s/movie.mp4" type="video/mp4"></video>
<audio preload="metadata" src="/s/sound.mp3"></audio>
<object data="/s/object.png" type="image/png"></object>
<embed src="/s/embed.png" type="image/png">
<input type="image" src="/s/input-image.png">
<iframe src="/s/frame.html" width=10 height=10></iframe>
<svg width="10" height="10"><image href="/s/svg-image.png" width="10" height="10"></image></svg>
<video><track kind="captions" src="/s/captions.vtt" default></video>

<script src="/s/tail.js"></script>
</body>`;

const CSS = `
@import url("/s/imported.css");
@font-face { font-family: Censused; src: url("/s/font.woff2") format("woff2"); }
.fonted { font-family: Censused, serif; }
.bg { background-image: url("/s/bg.png"); width: 20px; height: 20px; }
.listy ul { list-style-image: url("/s/list.png"); }
.bordered { border-image-source: url("/s/border.png"); border-width: 4px; border-style: solid; }
.cursorly { cursor: url("/s/cursor.png"), auto; }
.masked { -webkit-mask-image: url("/s/mask.png"); width: 10px; height: 10px; }
.never-used { background-image: url("/s/unused-bg.png"); }
`;

let hits = new Map();

const server = http.createServer((req, res) => {
    const p = new URL(req.url, 'http://x').pathname;
    if (p === '/page.html') {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
        return res.end(PAGE);
    }
    if (!p.startsWith('/s/')) { res.writeHead(404).end(); return; }
    const name = p.slice(3);
    hits.set(name, (hits.get(name) || 0) + 1);
    if (name === 'sheet.css' || name === 'imported.css') {
        res.writeHead(200, { 'content-type': 'text/css' });
        return res.end(name === 'sheet.css' ? CSS : '.imported { color: rgb(9,9,9); }');
    }
    if (name === 'tail.js') {
        res.writeHead(200, { 'content-type': 'text/javascript' });
        return res.end('window.__tail = 1;');
    }
    if (name === 'frame.html') {
        res.writeHead(200, { 'content-type': 'text/html' });
        return res.end('<!doctype html><title>f</title><img src="/s/in-frame.png">');
    }
    if (name === 'app.webmanifest') {
        res.writeHead(200, { 'content-type': 'application/manifest+json' });
        return res.end('{"name":"census"}');
    }
    if (name === 'captions.vtt') {
        res.writeHead(200, { 'content-type': 'text/vtt' });
        return res.end('WEBVTT\n');
    }
    if (name.endsWith('.png')) {
        res.writeHead(200, { 'content-type': 'image/png', 'content-length': String(PNG.length) });
        return res.end(PNG);
    }
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.end('x');
});
await new Promise((r) => server.listen(sitePort, '127.0.0.1', r));

async function census(engine) {
    hits = new Map();
    const port = engine === 'chrome' ? cdpPort : cdpPort + 1;
    let proc;
    let profile = null;
    if (engine === 'chrome') {
        profile = await fs.mkdtemp(path.join(os.tmpdir(), 'wire-census-'));
        proc = spawn(CHROME, [
            `--remote-debugging-port=${port}`,
            `--user-data-dir=${profile}`,
            '--no-first-run',
            '--no-default-browser-check',
            '--headless=new',
            // This engine's persona is a 1920x1080 CSS viewport at
            // devicePixelRatio 2 (Window.getDevicePixelRatio). srcset picks by
            // DPR, so a Chrome arm left at 1 answers `1x` where this engine
            // answers `2x` and the row reads as a bug that is really the
            // harness disagreeing with itself -- the same trap
            // `chrome-arm-needs-persona-dpr` records for layout readings.
            '--force-device-scale-factor=2',
            '--window-size=3840,2160',
        ], { stdio: ['ignore', 'pipe', 'pipe'] });
    } else {
        proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(port)], {
            stdio: ['ignore', 'pipe', 'pipe'],
        });
    }
    const log = [];
    proc.stdout.on('data', (d) => log.push(String(d)));
    proc.stderr.on('data', (d) => log.push(String(d)));
    try {
        let up = false;
        for (let i = 0; i < 100 && !up; i++) {
            try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); up = true; }
            catch { await sleep(200); }
        }
        if (!up) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

        const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
        const url = `http://127.0.0.1:${sitePort}/page.html`;
        const opts = { url };
        if (engine === 'lightpanda') {
            const { browserContextId } = await cdp.send('Target.createBrowserContext');
            opts.browserContextId = browserContextId;
        }
        const { targetId } = await cdp.send('Target.createTarget', opts);
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

        const deadline = Date.now() + 30000;
        while (Date.now() < deadline) {
            const r = await cdp.send('Runtime.evaluate',
                { expression: 'document.readyState', returnByValue: true }, sessionId).catch(() => null);
            if (r?.result?.value === 'complete') break;
            await sleep(250);
        }
        // Lazy images, prefetch and the font a first layout asks for all land
        // after `complete`; a census taken at readyState is a census of the
        // race.
        await sleep(settle);
        return Object.fromEntries([...hits].sort());
    } finally {
        proc.kill('SIGKILL');
        if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

const arms = only ? [only] : ['chrome', 'lightpanda'];
const out = {};
for (const a of arms) out[a] = await census(a);
server.close();

if (jsonOut) await fs.writeFile(jsonOut, JSON.stringify(out, null, 2));

if (arms.length === 2) {
    const names = [...new Set([...Object.keys(out.chrome), ...Object.keys(out.lightpanda)])].sort();
    const w = Math.max(...names.map((n) => n.length));
    console.log(`${'path'.padEnd(w)}  chrome  lightpanda`);
    let same = 0;
    for (const n of names) {
        const c = out.chrome[n] || 0;
        const l = out.lightpanda[n] || 0;
        if (c === l) same++;
        console.log(`${n.padEnd(w)}  ${String(c).padStart(6)}  ${String(l).padStart(10)}${c === l ? '' : '   <-- differs'}`);
    }
    console.log(`\n${same}/${names.length} paths agree; chrome asked for ${Object.keys(out.chrome).length}, lightpanda for ${Object.keys(out.lightpanda).length}`);
} else {
    console.log(JSON.stringify(out[arms[0]], null, 2));
}
