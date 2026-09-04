// What number does a browser put in `Network.loadingFinished.encodedDataLength`,
// and in the `encodedDataLength` of the response object that
// `Network.responseReceived` carries?
//
// This engine answers the Content-Length *header* in both places, so a
// response that never sends that header -- an h2 stream, a chunked h1 reply,
// anything Cloudflare serves -- is reported as zero bytes long over CDP while
// the same transfer's Resource Timing entry reports its real weight. A client
// reading the trace sees a page whose every script finished having transferred
// nothing.
//
// The point of this probe is to pin down the *definition* rather than guess it:
// the server writes each response byte-for-byte over a raw socket, so the
// header bytes and the body bytes are separately known, and the two CDP numbers
// can be checked against `headerBytes`, `bodyBytes` and their sum.
//
//   node tools/fingerprint/cdp-encoded-data-length.mjs chrome
//   node tools/fingerprint/cdp-encoded-data-length.mjs lightpanda
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
//   WAIT_MS  how long to let the page settle before reading (default: 2500)
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
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
    console.error('usage: cdp-encoded-data-length.mjs <lightpanda|chrome>');
    process.exit(1);
}

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9358 : 9359);
const WAIT_MS = Number(process.env.WAIT_MS) || 2500;

// Long enough that compressing it actually shrinks it, so the encoded and
// decoded sizes cannot coincide by accident.
const BODY = `window.__loaded = (window.__loaded || 0) + 1;\n${'// padding padding padding padding\n'.repeat(200)}`;
const BR = zlib.brotliCompressSync(Buffer.from(BODY));
const GZIP = zlib.gzipSync(Buffer.from(BODY));

// Each route names how its response is framed on the wire, because the framing
// is exactly what decides whether a Content-Length header exists to be read.
const ROUTES = {
    // Content-Length present, body identity-coded: the one case the old code
    // could get right.
    '/plain.js': { body: Buffer.from(BODY), type: 'text/javascript', framing: 'content-length' },
    // Content-Length present, body compressed: the header counts the *encoded*
    // bytes, so this one distinguishes encoded from decoded but not header from
    // body.
    '/br.js': { body: BR, type: 'text/javascript', framing: 'content-length', encoding: 'br' },
    '/gzip.js': { body: GZIP, type: 'text/javascript', framing: 'content-length', encoding: 'gzip' },
    // No Content-Length at all -- chunked, the h1 shape of what Cloudflare does
    // over h2. Reading the header here yields zero.
    '/chunked.js': { body: Buffer.from(BODY), type: 'text/javascript', framing: 'chunked' },
    '/chunked-gzip.js': { body: GZIP, type: 'text/javascript', framing: 'chunked', encoding: 'gzip' },
    // An empty 204: the floor case, where the only bytes on the wire are the
    // headers.
    '/empty': { body: Buffer.alloc(0), type: null, framing: 'content-length', status: 204 },
    // A redirect, because curl accumulates its header-byte counter across a
    // chain it follows itself. This engine follows redirects by hand, so the
    // reading should be per-response -- but that is a claim worth measuring
    // rather than asserting, and the row for /redirected.js is where it shows.
    '/redirect.js': { body: Buffer.alloc(0), type: null, framing: 'content-length', status: 302, location: '/redirected.js' },
    '/redirected.js': { body: Buffer.from(BODY), type: 'text/javascript', framing: 'content-length' },
};

const PAGE = `<!DOCTYPE html><html><head><title>encodedDataLength</title></head><body>
${Object.keys(ROUTES).filter((p) => p.endsWith('.js') && p !== '/redirected.js').map((p) => `<script src="${p}"></script>`).join('\n')}
<script>fetch('/empty');</script>
</body></html>`;

// ---------------------------------------------------------------- raw server

// Written byte-for-byte over a socket rather than through node's http server:
// the probe needs to know how many bytes each response weighed, split into
// header bytes and body bytes, and an http server will not tell you that.
const written = new Map(); // path -> { headerBytes, bodyBytes }

function buildResponse(p, route) {
    const status = route.status ?? 200;
    const reason = { 204: 'No Content', 302: 'Found' }[status] ?? 'OK';
    const lines = [`HTTP/1.1 ${status} ${reason}`];
    if (route.location) lines.push(`location: ${route.location}`);
    if (route.type) lines.push(`content-type: ${route.type}`);
    if (route.encoding) lines.push(`content-encoding: ${route.encoding}`);
    // Chrome hides the response fields of a cross-origin load; everything here
    // is same-origin, but the header keeps the sweep honest if that changes.
    lines.push('cache-control: no-store');
    lines.push('access-control-allow-origin: *');

    let framed;
    if (route.framing === 'chunked') {
        lines.push('transfer-encoding: chunked');
        const b = route.body;
        framed = b.length === 0
            ? Buffer.from('0\r\n\r\n')
            : Buffer.concat([
                Buffer.from(`${b.length.toString(16)}\r\n`),
                b,
                Buffer.from('\r\n0\r\n\r\n'),
            ]);
    } else {
        lines.push(`content-length: ${route.body.length}`);
        framed = route.body;
    }

    const head = Buffer.from(`${lines.join('\r\n')}\r\n\r\n`);
    return { head, framed };
}

function serveHtml() {
    const body = Buffer.from(PAGE);
    const head = Buffer.from([
        'HTTP/1.1 200 OK',
        'content-type: text/html; charset=utf-8',
        'cache-control: no-store',
        `content-length: ${body.length}`,
        '', '',
    ].join('\r\n'));
    return { head, framed: body };
}

const server = net.createServer((sock) => {
    let buf = Buffer.alloc(0);
    sock.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        // Requests here are all header-only GETs, so a blank line ends one.
        let idx;
        while ((idx = buf.indexOf('\r\n\r\n')) !== -1) {
            const raw = buf.subarray(0, idx).toString('latin1');
            buf = buf.subarray(idx + 4);
            const target = raw.split('\r\n')[0].split(' ')[1] ?? '/';
            const p = target.split('?')[0];

            let out;
            if (p === '/' || p === '/index.html') {
                out = serveHtml();
            } else if (ROUTES[p]) {
                out = buildResponse(p, ROUTES[p]);
                written.set(p, { headerBytes: out.head.length, bodyBytes: out.framed.length });
            } else {
                const b = Buffer.from('not found');
                out = {
                    head: Buffer.from(`HTTP/1.1 404 Not Found\r\ncontent-length: ${b.length}\r\n\r\n`),
                    framed: b,
                };
            }
            sock.write(out.head);
            if (out.framed.length) sock.write(out.framed);
        }
    });
    sock.on('error', () => { /* client hung up */ });
});

const ORIGIN = await new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`));
});

// ---------------------------------------------------------------- the engine

let proc;
let profileDir;
if (engine === 'chrome') {
    profileDir = await fs.mkdtemp(path.join(os.tmpdir(), 'edl-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profileDir}`,
        '--headless=new',
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        '--disable-features=Translate,OptimizationHints',
        'about:blank',
    ], { stdio: 'ignore' });
} else {
    proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: 'ignore' });
}

async function waitForCdp() {
    for (let i = 0; i < 100; i++) {
        try {
            const res = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (res.ok) return;
        } catch { /* not up yet */ }
        await sleep(100);
    }
    throw new Error('CDP never came up');
}
await waitForCdp();

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

// requestId -> what the trace said about it
const seen = new Map();
function slot(requestId) {
    let s = seen.get(requestId);
    if (!s) {
        s = {
            url: null,
            responseReceived: null,
            loadingFinished: null,
            dataChunks: 0,
            dataBytes: 0,
            // A redirect keeps the same request id, so its bytes are reported
            // on the hop that carries `redirectResponse` and would otherwise
            // be overwritten by the hop that follows.
            redirectBytes: 0,
        };
        seen.set(requestId, s);
    }
    return s;
}

cdp.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    const p = msg.params;
    switch (msg.method) {
        case 'Network.requestWillBeSent': {
            const s = slot(p.requestId);
            s.url = p.request.url;
            if (p.redirectResponse) s.redirectBytes += p.redirectResponse.encodedDataLength ?? 0;
            break;
        }
        case 'Network.responseReceived': {
            const s = slot(p.requestId);
            s.url = s.url ?? p.response.url;
            s.responseReceived = p.response.encodedDataLength;
            break;
        }
        case 'Network.dataReceived': {
            const s = slot(p.requestId);
            s.dataChunks += 1;
            s.dataBytes += p.encodedDataLength ?? 0;
            break;
        }
        case 'Network.loadingFinished':
            slot(p.requestId).loadingFinished = p.encodedDataLength;
            break;
    }
});

await cdp.send('Network.enable', {}, sessionId);
await cdp.send('Page.enable', {}, sessionId);
await cdp.send('Runtime.enable', {}, sessionId);
await cdp.send('Page.navigate', { url: `${ORIGIN}/` }, sessionId);
await sleep(WAIT_MS);

// Resource Timing's own numbers, so the two views of the same transfer can be
// compared in one table.
const rt = await cdp.send('Runtime.evaluate', {
    expression: `JSON.stringify(performance.getEntriesByType('resource').map(e => ({
        name: e.name, encodedBodySize: e.encodedBodySize,
        decodedBodySize: e.decodedBodySize, transferSize: e.transferSize,
    })))`,
    returnByValue: true,
}, sessionId);
const timing = new Map(
    JSON.parse(rt.result?.value ?? '[]').map((e) => [new URL(e.name).pathname, e]),
);

const rows = [];
for (const [, s] of seen) {
    if (!s.url) continue;
    let p;
    try {
        p = new URL(s.url).pathname;
    } catch {
        continue;
    }
    const w = written.get(p);
    const t = timing.get(p);
    rows.push({
        path: p,
        framing: ROUTES[p]?.framing ?? (p === '/' ? 'content-length' : '?'),
        encoding: ROUTES[p]?.encoding ?? null,
        wireHeaderBytes: w?.headerBytes ?? null,
        wireBodyBytes: w?.bodyBytes ?? null,
        wireTotalBytes: w ? w.headerBytes + w.bodyBytes : null,
        cdpRedirectBytes: s.redirectBytes,
        cdpResponseReceived: s.responseReceived,
        cdpDataReceivedSum: s.dataBytes,
        cdpDataReceivedChunks: s.dataChunks,
        cdpLoadingFinished: s.loadingFinished,
        rtEncodedBodySize: t?.encodedBodySize ?? null,
        rtDecodedBodySize: t?.decodedBodySize ?? null,
        rtTransferSize: t?.transferSize ?? null,
    });
}
rows.sort((a, b) => a.path.localeCompare(b.path));

const out = { engine, origin: ORIGIN, rows };
console.log(JSON.stringify(out, null, 2));

const pad = (v, n) => String(v ?? '-').padEnd(n);
console.error('');
console.error(`${pad('path', 18)}${pad('framing', 16)}${pad('hdr', 6)}${pad('body', 8)}${pad('sum', 8)}${pad('redir', 7)}${pad('rcvd', 8)}${pad('data', 8)}${pad('finished', 10)}${pad('rtEnc', 8)}${pad('rtXfer', 8)}`);
for (const r of rows) {
    console.error(
        pad(r.path, 18) + pad(r.framing, 16) + pad(r.wireHeaderBytes, 6) +
        pad(r.wireBodyBytes, 8) + pad(r.wireTotalBytes, 8) + pad(r.cdpRedirectBytes, 7) +
        pad(r.cdpResponseReceived, 8) +
        pad(r.cdpDataReceivedSum, 8) + pad(r.cdpLoadingFinished, 10) +
        pad(r.rtEncodedBodySize, 8) + pad(r.rtTransferSize, 8),
    );
}

cdp.close();
proc.kill();
server.close();
if (profileDir) await fs.rm(profileDir, { recursive: true, force: true });
process.exit(0);
