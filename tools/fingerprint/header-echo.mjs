// Raw TCP HTTP server that records the byte-exact request head of every hit.
// node:http normalises and reorders headers, and header *order* is itself part
// of the fingerprint, so we parse the wire bytes ourselves.
import net from 'node:net';

const PIXEL = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
    'base64',
);

// Where an author header lands is a question neither the Sec-Fetch-* set nor the
// priority hint can answer, and two cross-origin reads in b57-cors-chrome.json
// disagreed about it: one header landed after User-Agent, two headers landed
// ahead of the whole client-hint block. No fixed slot expresses both, so this
// table varies one axis at a time instead of guessing:
//
//   * one-* -- same count, same (single) insertion, different name. A position
//     that moves here is name-driven.
//   * two-zeta-alpha vs two-alpha-zeta, and the xhr-two-* pair -- same names,
//     opposite insertion order, and two different APIs to set them through.
//   * three / four -- does the block keep sliding as the count grows.
//   * post-ct -- Content-Type is the other field emitHeaders lumps in with
//     author headers, and b57 caught it slotted mid-hint-block too.
//   * hold-* -- a held-out round: predictions from blink-header-order.mjs were
//     written down before these were ever measured. hold-five is the case that
//     pins the engine's own insertion order.
//   * f-* -- a second held-out round, written down after hold-five fixed that
//     order. The names real guards use are in here on purpose: those are the
//     sets that being right about actually buys something.
//
// Exported so blink-header-order.mjs can score a capture against the model
// without a second copy of the author names drifting out of step with the page.
export const AUTHOR_CASES = [
    { path: '/hdr/one-probe', api: 'fetch', headers: [['X-Probe', '1']] },
    { path: '/hdr/one-zulu', api: 'fetch', headers: [['X-Zulu', '1']] },
    { path: '/hdr/one-aaa', api: 'fetch', headers: [['A-Aaa', '1']] },
    { path: '/hdr/one-long', api: 'fetch', headers: [['X-Probe-Long-Name', '1']] },
    { path: '/hdr/two-zeta-alpha', api: 'fetch', headers: [['X-Zeta', '1'], ['X-Alpha', '2']] },
    { path: '/hdr/two-alpha-zeta', api: 'fetch', headers: [['X-Alpha', '2'], ['X-Zeta', '1']] },
    { path: '/hdr/three', api: 'fetch', headers: [['X-Zeta', '1'], ['X-Alpha', '2'], ['X-Mid', '3']] },
    { path: '/hdr/four', api: 'fetch', headers: [['X-Zeta', '1'], ['X-Alpha', '2'], ['X-Mid', '3'], ['X-Beta', '4']] },
    { path: '/hdr/xhr-two-zeta-alpha', api: 'xhr', headers: [['X-Zeta', '1'], ['X-Alpha', '2']] },
    { path: '/hdr/xhr-two-alpha-zeta', api: 'xhr', headers: [['X-Alpha', '2'], ['X-Zeta', '1']] },
    { path: '/hdr/post-ct', api: 'post', headers: [['Content-Type', 'text/plain'], ['X-Probe', '1']] },
    { path: '/hdr/hold-sigma', api: 'fetch', headers: [['X-Sigma', '1']] },
    { path: '/hdr/hold-q', api: 'fetch', headers: [['X-Q', '1']] },
    { path: '/hdr/hold-mixed', api: 'fetch', headers: [['X-MiXeD-CaSe', '1']] },
    { path: '/hdr/hold-kasada', api: 'fetch', headers: [['X-KpSdk-Ct', '1'], ['X-KpSdk-V', '2']] },
    { path: '/hdr/hold-five', api: 'fetch', headers: [['X-Aa', '1'], ['X-Bb', '2'], ['X-Cc', '3'], ['X-Dd', '4'], ['X-Ee', '5']] },
    { path: '/hdr/hold-six', api: 'fetch', headers: [['X-Aa', '1'], ['X-Bb', '2'], ['X-Cc', '3'], ['X-Dd', '4'], ['X-Ee', '5'], ['X-Ff', '6']] },
    { path: '/hdr/hold-auth', api: 'fetch', headers: [['Authorization', 'Bearer t'], ['X-Requested-With', 'XMLHttpRequest']] },
    { path: '/hdr/f-dd', api: 'fetch', headers: [['X-DataDome-ClientId', '1']] },
    { path: '/hdr/f-cf', api: 'fetch', headers: [['CF-Challenge', '1'], ['X-CF-Turnstile', '2']] },
    { path: '/hdr/f-seven', api: 'fetch', headers: [['X-P1', '1'], ['X-P2', '2'], ['X-P3', '3'], ['X-P4', '4'], ['X-P5', '5'], ['X-P6', '6'], ['X-P7', '7']] },
    { path: '/hdr/f-digits', api: 'fetch', headers: [['X-1', '1'], ['X-22', '2'], ['X-333', '3']] },
    { path: '/hdr/f-verylong', api: 'fetch', headers: [['X-A-Really-Quite-Long-Header-Name-Here', '1']] },
    { path: '/hdr/f-akamai', api: 'fetch', headers: [['X-Acf-Sensor-Data', '1']] },
    { path: '/hdr/f-three-b', api: 'fetch', headers: [['X-Bravo', '1'], ['X-Yankee', '2'], ['X-November', '3']] },
    { path: '/hdr/f-postct', api: 'xhr', headers: [['Content-Type', 'text/plain'], ['X-Sig', '1'], ['X-Ts', '2']] },
];

const caseScript = AUTHOR_CASES.map(({ path, api, headers }) => {
    const pairs = JSON.stringify(headers);
    if (api === 'fetch') return `f(${JSON.stringify(path)}, ${pairs});`;
    return `xh(${JSON.stringify(path)}, ${JSON.stringify(api === 'post' ? 'POST' : 'GET')}, ${pairs});`;
}).join('\n');

// A page that pulls one of every fetch destination, so we can compare the
// Sec-Fetch-* / Accept / Referer sets per request type against real Chrome.
const INDEX = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>hdr</title>
<link rel="stylesheet" href="/asset.css">
<script src="/asset.js"></script>
</head><body>
<img src="/asset.png" width="1" height="1">
<iframe src="/frame.html" width="1" height="1"></iframe>
<script>
// Both carry a header the page set itself, on the two destinations the rest of
// this page's comparison already covers.
fetch('/api/fetch', {headers: {'X-Probe': '1'}}).then(r => r.text());
var x = new XMLHttpRequest(); x.open('GET', '/api/xhr', true);
x.setRequestHeader('X-Probe', '1'); x.send();

// The author-header position matrix, generated from AUTHOR_CASES. Object-literal
// header bags would lose the page's setting order for the fetch cases, so both
// helpers take ordered pairs.
function f(p, pairs) {
    var h = new Headers();
    for (var i = 0; i < pairs.length; i++) h.append(pairs[i][0], pairs[i][1]);
    fetch(p, {headers: h}).then(function (r) { return r.text(); });
}
function xh(p, method, pairs) {
    var r = new XMLHttpRequest();
    r.open(method, p, true);
    for (var i = 0; i < pairs.length; i++) r.setRequestHeader(pairs[i][0], pairs[i][1]);
    r.send(method === 'POST' ? 'x' : undefined);
}
${caseScript}
</script>
</body></html>`;

// A page that declares its own icon, to tell the two favicon paths apart: the
// implicit /favicon.ico the INDEX page gets, and an explicit <link rel>. The
// "shortcut icon" spelling is the one legacy pages use.
const DECLARED_ICON = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>icon</title>
<link rel="shortcut icon" href="/brand.ico">
</head><body>i</body></html>`;

// Exported so h2-echo.mjs serves the byte-identical page set: the h1 and h2
// captures are only comparable if both arms pulled the same subresources.
export function body(path) {
    switch (path) {
        case '/':
        case '/nav':
            return ['text/html; charset=utf-8', Buffer.from(INDEX)];
        case '/declared-icon.html':
            return ['text/html; charset=utf-8', Buffer.from(DECLARED_ICON)];
        case '/brand.ico':
            return ['image/x-icon', PIXEL];
        case '/frame.html':
            return ['text/html; charset=utf-8', Buffer.from('<!DOCTYPE html><html><body>f</body></html>')];
        case '/asset.css':
            return ['text/css', Buffer.from('body{color:#333}')];
        case '/asset.js':
            return ['application/javascript', Buffer.from('window.__hdrJs = 1;')];
        case '/asset.png':
            return ['image/png', PIXEL];
        case '/api/fetch':
        case '/api/xhr':
            return ['application/json', Buffer.from('{"ok":true}')];
        default:
            return ['text/plain', Buffer.from('ok')];
    }
}

export function startEchoServer(port) {
    const records = [];
    const sockets = new Set();
    const server = net.createServer((sock) => {
        sockets.add(sock);
        sock.on('close', () => sockets.delete(sock));
        let buf = Buffer.alloc(0);
        sock.on('data', (chunk) => {
            buf = Buffer.concat([buf, chunk]);
            let idx;
            // Handle pipelined/keep-alive requests on one connection.
            while ((idx = buf.indexOf('\r\n\r\n')) !== -1) {
                const head = buf.subarray(0, idx).toString('latin1');
                buf = buf.subarray(idx + 4);
                const lines = head.split('\r\n');
                const [method, path] = lines[0].split(' ');
                records.push({
                    method,
                    path,
                    requestLine: lines[0],
                    headers: lines.slice(1).map((l) => {
                        const c = l.indexOf(':');
                        return [l.slice(0, c), l.slice(c + 1).trimStart()];
                    }),
                });
                const [ctype, payload] = body(path);
                sock.write(
                    `HTTP/1.1 200 OK\r\nContent-Type: ${ctype}\r\nContent-Length: ${payload.length}\r\n` +
                    `Cache-Control: no-store\r\nConnection: keep-alive\r\n\r\n`,
                );
                sock.write(payload);
            }
        });
        sock.on('error', () => sock.destroy());
    });
    return new Promise((resolve) => {
        server.listen(port, '127.0.0.1', () =>
            resolve({
                records,
                port: server.address().port,
                // Destroy live keep-alive sockets first: server.close() only
                // stops accepting, it waits forever on open connections.
                close: () => new Promise((r) => {
                    for (const s of sockets) s.destroy();
                    server.close(() => r());
                }),
            }));
    });
}
