// Raw TCP HTTP server that records the byte-exact request head of every hit.
// node:http normalises and reorders headers, and header *order* is itself part
// of the fingerprint, so we parse the wire bytes ourselves.
import net from 'node:net';

const PIXEL = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
    'base64',
);

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
// Both carry a header the page set itself. Where an author header lands is a
// question neither the Sec-Fetch-* set nor the priority hint can answer: all
// this engine adds has a measured slot, and an author header currently falls
// to the trailing pass in emitHeaders, i.e. last. Chrome puts it inside the
// client-hint block -- measured over h1 in b57-cors-chrome.json -- and whether
// that survives HPACK is exactly what the h2 arm is for.
fetch('/api/fetch', {headers: {'X-Probe': '1'}}).then(r => r.text());
var x = new XMLHttpRequest(); x.open('GET', '/api/xhr', true);
x.setRequestHeader('X-Probe', '1'); x.send();
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
