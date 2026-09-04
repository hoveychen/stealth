// What `initiatorType` does a browser file each parser-driven subresource
// under, and which of them leave a `resource` entry at all?
//
// `expr-resource-timing.js` asked the question for one `fetch`. This asks it
// for the loads the parser starts on its own -- a `<script src>`, an `<img>`,
// a `<link rel=stylesheet>` and the sheet that stylesheet `@import`s -- because
// those are the ones the station actually reads: Cloudflare's api.js is a
// `<script>`, not a fetch, so the `apiJsResourceTiming` the page posts to the
// Turnstile widget comes from the parser path and from nowhere else.
//
// Serves its own origin so every URL is known ahead of time, then navigates
// both engines to it and reads the buffer back.
//
//   node tools/fingerprint/resource-timing-initiators.mjs chrome
//   node tools/fingerprint/resource-timing-initiators.mjs lightpanda
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
//   WAIT_MS  how long to let the page settle before reading (default: 2500)
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: resource-timing-initiators.mjs <lightpanda|chrome>');
    process.exit(1);
}

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9346 : 9347);
const WAIT_MS = Number(process.env.WAIT_MS) || 2500;

// A one-pixel PNG, so an <img> that arrives really is an image: this engine
// sniffs the body rather than trusting the content-type (Frame.ImageRequest).
const PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64',
);

const ROUTES = {
    '/page.html': ['text/html', `<!DOCTYPE html><html><head>
<link rel=stylesheet href="/outer.css">
<link rel=preload as=script href="/preloaded.js">
<script src="/classic.js"></script>
<script defer src="/deferred.js"></script>
<script async src="/asynced.js"></script>
<script type=module src="/entry.mjs"></script>
</head><body>
<img src="/pixel.png">
<script src="/preloaded.js"></script>
<script>
  // An XHR from the parser path, so the one initiatorType this engine already
  // files shows up in the same reading as the ones it does not.
  const x = new XMLHttpRequest();
  x.open('GET', '/xhr.json', true);
  x.send();
</script>
</body></html>`],
    // The imported sheet is a second network load with an initiatorType of its
    // own -- Chrome calls a stylesheet reached through @import "css", not
    // "link", which is the distinction this file exists to record.
    '/outer.css': ['text/css', '@import url("/inner.css");\nbody { color: rgb(1, 2, 3); }'],
    '/inner.css': ['text/css', 'p { color: rgb(4, 5, 6); }'],
    '/classic.js': ['text/javascript', 'window.__classic = 1;'],
    '/deferred.js': ['text/javascript', 'window.__deferred = 1;'],
    '/asynced.js': ['text/javascript', 'window.__asynced = 1;'],
    '/preloaded.js': ['text/javascript', 'window.__preloaded = 1;'],
    // A module entry point plus the module it statically imports, so the
    // import's own load is visible separately from the entry's.
    '/entry.mjs': ['text/javascript', 'import "/imported.mjs";\nwindow.__entry = 1;'],
    '/imported.mjs': ['text/javascript', 'window.__imported = 1;'],
    '/xhr.json': ['application/json', '{"ok":true}'],
    '/pixel.png': ['image/png', PNG],
};

// What the origin was actually asked for, so "no entry" can be told apart from
// "no request": a load this engine never makes cannot leave an entry behind,
// and the fix for that is a different one.
const requested = [];

const server = http.createServer((req, res) => {
    requested.push(req.url.split('?')[0]);
    const route = ROUTES[req.url.split('?')[0]];
    if (!route) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        return res.end('no');
    }
    const [type, body] = route;
    res.writeHead(200, { 'content-type': type });
    res.end(body);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;

const READ = `(() => {
    const entries = performance.getEntriesByType('resource');
    return {
        count: entries.length,
        entries: entries.map((e) => ({
            name: String(e.name).replace(/^https?:\\/\\/[^/]+/, ''),
            initiatorType: e.initiatorType,
            entryType: e.entryType,
            nextHopProtocol: e.nextHopProtocol,
            deliveryType: e.deliveryType,
            renderBlockingStatus: e.renderBlockingStatus,
            responseStatus: e.responseStatus,
            transferSize: e.transferSize,
            encodedBodySize: e.encodedBodySize,
            decodedBodySize: e.decodedBodySize,
            startTimePositive: e.startTime > 0,
            durationNonNegative: e.duration >= 0,
        })).sort((a, b) => a.name.localeCompare(b.name)),
    };
})()`;

let proc;
if (engine === 'chrome') {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'rt-initiators-chrome-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        '--headless=new',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], {
        stdio: ['ignore', 'pipe', 'pipe'],
    });
}
const log = [];
proc.stdout.on('data', (d) => log.push(String(d)));
proc.stderr.on('data', (d) => log.push(String(d)));

try {
    let version = null;
    for (let i = 0; i < 100; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            version = await r.json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!version) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        const { browserContextId } = await cdp.send('Target.createBrowserContext');
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    }

    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Page.navigate', { url: `${origin}/page.html` }, sessionId);
    await sleep(WAIT_MS);

    const res = await cdp.send('Runtime.evaluate', {
        expression: READ,
        returnByValue: true,
        awaitPromise: true,
    }, sessionId);
    if (res.exceptionDetails) {
        console.error(JSON.stringify(res.exceptionDetails, null, 2));
        process.exitCode = 1;
    } else {
        console.log(JSON.stringify({
            engine,
            version: version.Browser,
            requested: requested.slice().sort(),
            ...res.result.value,
        }, null, 2));
    }
} finally {
    proc.kill('SIGKILL');
    server.close();
}
