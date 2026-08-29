// A page with a realistic head, to size the whole "what order do requests leave
// in" channel rather than the one case that opened the plan.
//
// This is the channel a site sees WITHOUT running any JavaScript: the order and
// grouping of the GETs its own server logs. Every fidelity defect chased on
// this codebase so far has been a JS-readable surface; request sequence is a
// different class, so it is worth knowing whether the known `script before
// link` inversion is the only one or the tip of it.
//
// Every resource answers instantly. The question is dispatch order, and a
// per-resource delay would only measure the server.
//
//   node tools/fingerprint/probes/b87-wire-order-fixture.mjs 8722
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-wire-order.js \
//        --url http://127.0.0.1:8722/page.html
//
// The server prints arrival order itself; the expression is only there to hold
// the page open long enough for the late loads to happen.
import http from 'node:http';

const port = Number(process.argv[2] || 8722);

// Ordered to separate several rules at once, and deliberately NOT sorted by
// kind: a preload scanner that walks the document reproduces this order, one
// that groups by kind does not.
const PAGE = `<!DOCTYPE html>
<title>wire order</title>
<link rel="stylesheet" href="/1-first.css">
<script src="/2-blocking.js"></script>
<link rel="stylesheet" href="/3-second.css">
<script defer src="/4-deferred.js"></script>
<script async src="/5-async.js"></script>
<link rel="preload" as="image" href="/6-preloaded.gif">
<script type="module" src="/7-module.js"></script>
<body>
<img src="/8-body.gif">
<link rel="stylesheet" href="/9-in-body.css">
<img src="/a-late.gif">
<script>
window.__done = new Promise((r) => setTimeout(() => r(true), 800));
</script>
</body>`;

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

let n = 0;
let start = 0;
http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/page.html') {
        n = 0;
        start = Date.now();
        console.log('--- navigation ---');
    } else {
        console.log(`  ${String(++n).padStart(2)}. +${String(Date.now() - start).padStart(4)}ms  ${url}`);
    }
    const send = (type, body) => {
        res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
        res.end(body);
    };
    if (url === '/page.html') return send('text/html', PAGE);
    if (url.endsWith('.css')) return send('text/css', 'body { color: #111 }');
    if (url.endsWith('.js')) return send('application/javascript', 'void 0;');
    if (url.endsWith('.gif')) return send('image/gif', GIF);
    if (url === '/favicon.ico') return send('image/gif', GIF);
    res.writeHead(404);
    res.end();
}).listen(port, () => console.log(`wire order fixture on ${port}`));
