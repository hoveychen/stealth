// Which of a `resource` entry's fields come from the *response* rather than
// from the load's shape, and what does a browser put in them?
//
// `resource-timing-initiators.mjs` asked who started each load. This asks what
// the answer looks like once the bytes come back, because that is where the
// real-site reading still differs: Cloudflare's api.js entry names a
// contentType, a contentEncoding, an encodedBodySize smaller than the decoded
// one, and nine connection milestones, and this engine answered "" / "" /
// the decoded size / zero for all of them.
//
// Two origins, so the cross-origin rules are visible too: a browser hides most
// of these behind `Timing-Allow-Origin`, and filling them in unconditionally
// would leak more than Chrome does.
//
//   node tools/fingerprint/resource-timing-response-fields.mjs chrome
//   node tools/fingerprint/resource-timing-response-fields.mjs lightpanda
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
import zlib from 'node:zlib';
import { personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: resource-timing-response-fields.mjs <lightpanda|chrome>');
    process.exit(1);
}

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9348 : 9349);
const WAIT_MS = Number(process.env.WAIT_MS) || 2500;

// Long enough that compressing it actually shrinks it, so encodedBodySize and
// decodedBodySize cannot coincide by accident.
const BODY = `window.__loaded = (window.__loaded || 0) + 1;\n${'// padding padding padding padding\n'.repeat(200)}`;
const BR = zlib.brotliCompressSync(Buffer.from(BODY));
const GZIP = zlib.gzipSync(Buffer.from(BODY));

// [content-type, body, extra headers]
const SAME_ORIGIN = {
    '/plain.js': ['text/javascript', Buffer.from(BODY), {}],
    '/br.js': ['text/javascript', BR, { 'content-encoding': 'br' }],
    '/gzip.js': ['text/javascript', GZIP, { 'content-encoding': 'gzip' }],
    // A parameterised content-type, to see whether the entry keeps the
    // parameter or only the MIME essence.
    '/param.css': ['text/CSS; charset=UTF-8', Buffer.from('body { color: rgb(1, 2, 3); }'), {}],
    // The legacy JavaScript MIME type, which is what Cloudflare serves api.js
    // as while the oracle's entry reads `text/javascript` -- so something
    // between the header and the entry rewrites it, and this is where that gets
    // measured rather than assumed.
    '/legacy.js': ['application/javascript; charset=UTF-8', Buffer.from(BODY), {}],
    '/xjs.js': ['application/x-javascript', Buffer.from(BODY), {}],
    // Does a Server-Timing header reach the entry's serverTiming array?
    '/timed.js': ['text/javascript', Buffer.from(BODY), { 'server-timing': 'cfExtPri;dur=0, db;dur=53;desc="lookup"' }],
};

// The same script four ways on origin B, because two separate gates are in
// play: `Timing-Allow-Origin` says whether origin A may read the load's
// timings, and CORS says whether the response is opaque to it. Which gate each
// field sits behind is the whole question for a cross-origin resource, and the
// api.js this is chasing is exactly that.
const CROSS_ORIGIN = {
    '/tao.js': ['text/javascript', BR, { 'content-encoding': 'br', 'timing-allow-origin': '*' }],
    '/notao.js': ['text/javascript', BR, { 'content-encoding': 'br' }],
    // TAO plus CORS, fetched in CORS mode (`crossorigin` on the tag).
    '/cors.js': ['text/javascript', BR, {
        'content-encoding': 'br',
        'timing-allow-origin': '*',
        'access-control-allow-origin': '*',
    }],
    // TAO plus CORS headers, but fetched no-cors -- the response is still
    // opaque, so this separates "server allows CORS" from "request used it".
    '/acao.js': ['text/javascript', BR, {
        'content-encoding': 'br',
        'timing-allow-origin': '*',
        'access-control-allow-origin': '*',
    }],
};

function serve(routes) {
    return http.createServer((req, res) => {
        const route = routes[req.url.split('?')[0]];
        if (!route) {
            res.writeHead(404, { 'content-type': 'text/plain' });
            return res.end('no');
        }
        const [type, body, extra] = route;
        res.writeHead(200, {
            'content-type': type,
            'content-length': String(body.length),
            ...extra,
        });
        res.end(body);
    });
}

const cross = serve(CROSS_ORIGIN);
await new Promise((r) => cross.listen(0, '127.0.0.1', r));
const crossOrigin = `http://127.0.0.1:${cross.address().port}`;

const PAGE = `<!DOCTYPE html><html><head>
<link rel=stylesheet href="/param.css">
<script src="/plain.js"></script>
<script src="/br.js"></script>
<script src="/gzip.js"></script>
<script src="/legacy.js"></script>
<script src="/xjs.js"></script>
<script src="/timed.js"></script>
<script src="${crossOrigin}/tao.js"></script>
<script src="${crossOrigin}/notao.js"></script>
<script crossorigin src="${crossOrigin}/cors.js"></script>
<script src="${crossOrigin}/acao.js"></script>
</head><body>ok</body></html>`;

const main = serve({ ...SAME_ORIGIN, '/page.html': ['text/html', Buffer.from(PAGE), {}] });
await new Promise((r) => main.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${main.address().port}`;

// The sizes the origin actually put on the wire, so the reading has something
// to be right or wrong against rather than just being self-consistent.
const wire = {
    '/plain.js': { encoded: BODY.length, decoded: BODY.length },
    '/br.js': { encoded: BR.length, decoded: BODY.length },
    '/gzip.js': { encoded: GZIP.length, decoded: BODY.length },
    '/tao.js': { encoded: BR.length, decoded: BODY.length },
    '/notao.js': { encoded: BR.length, decoded: BODY.length },
    '/cors.js': { encoded: BR.length, decoded: BODY.length },
    '/acao.js': { encoded: BR.length, decoded: BODY.length },
};

const READ = `(() => {
    const milestones = [
        'domainLookupStart', 'domainLookupEnd', 'connectStart', 'connectEnd',
        'secureConnectionStart', 'requestStart', 'responseStart',
        'firstInterimResponseStart', 'finalResponseHeadersStart',
    ];
    return performance.getEntriesByType('resource').map((e) => {
        const out = {
            name: String(e.name).replace(/^https?:\\/\\/127\\.0\\.0\\.1:\\d+/, ''),
            crossOrigin: !String(e.name).startsWith(location.origin),
            initiatorType: e.initiatorType,
            contentType: e.contentType,
            contentEncoding: e.contentEncoding,
            responseStatus: e.responseStatus,
            transferSize: e.transferSize,
            encodedBodySize: e.encodedBodySize,
            decodedBodySize: e.decodedBodySize,
            serverTiming: (e.serverTiming || []).map((st) => st.toJSON()),
            hasNavigationId: 'navigationId' in e,
            navigationId: e.navigationId,
            keyCount: Object.keys(e.toJSON()).length,
        };
        // Milestones as "is it non-zero", since the actual times cannot match
        // across engines -- what matters is which ones a browser reports at all.
        out.milestonesNonZero = milestones.filter((m) => e[m] > 0);
        out.ordered = e.fetchStart <= e.responseEnd &&
            (e.requestStart === 0 || (e.requestStart >= e.fetchStart && e.requestStart <= e.responseEnd));
        return out;
    }).sort((a, b) => a.name.localeCompare(b.name));
})()`;

let proc;
if (engine === 'chrome') {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'rt-response-chrome-'));
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
            wire,
            entries: res.result.value,
        }, null, 2));
    }
} finally {
    proc.kill('SIGKILL');
    main.close();
    cross.close();
}
