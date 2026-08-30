// What `<link rel=preload>` actually fetches, per `as` value.
//
//   node tools/fingerprint/probes/b87-preload-as-fixture.mjs 8760
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-preload-as.js \
//        --url http://127.0.0.1:8760/page.html
//
// This engine's Link.linkAddedCallback handles `rel=preload` only for
// `as=script` and fires a synthetic load event for everything else without
// fetching anything -- so a page that preloads an image makes one fewer request
// than Chrome does, which the site's own server sees without running any JS.
//
// The server prints arrival order and the Sec-Fetch-Dest each request carried,
// because a preload's destination is the `as` value rather than the element's
// own kind, and that is a second thing to get right.
import http from 'node:http';

const port = Number(process.argv[2] || 8760);

const AS = ['image', 'style', 'script', 'font', 'fetch', 'document', 'audio', 'video'];
const ext = (a) => (a === 'image' ? 'gif' : a === 'style' ? 'css' : a === 'script' ? 'js' : 'bin');

const PAGE = `<!DOCTYPE html>
<title>preload as</title>
${AS.map((a) => `<link rel="preload" as="${a}" href="/p-${a}.${ext(a)}"${a === 'font' ? ' crossorigin' : ''}>`).join('\n')}
<body>
<script>window.__done = new Promise((r) => setTimeout(() => r(true), 900));</script>
</body>`;

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

let start = 0;
http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/page.html') {
        start = Date.now();
        console.log('--- navigation ---');
        res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
        return void res.end(PAGE);
    }
    console.log(`  +${String(Date.now() - start).padStart(4)}ms  ${url.padEnd(14)} dest=${req.headers['sec-fetch-dest'] ?? '(none)'} mode=${req.headers['sec-fetch-mode'] ?? '(none)'} origin=${req.headers.origin ?? "(none)"} accept=${(req.headers.accept ?? "(none)").slice(0, 28)} prio=${req.headers.priority ?? "(none)"}`);
    const type = url.endsWith('.gif') ? 'image/gif' : url.endsWith('.css') ? 'text/css' : url.endsWith('.js') ? 'application/javascript' : 'application/octet-stream';
    res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store', 'access-control-allow-origin': '*' });
    res.end(url.endsWith('.gif') ? GIF : 'x'.repeat(64));
}).listen(port, () => console.log(`preload-as fixture on ${port}`));
