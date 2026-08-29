// A page whose subresources finish in the reverse of the order they start in,
// so `performance.getEntriesByType('resource')` can be asked which of the two
// it is sorted by. Every resource here is an <img>, so initiatorType is held
// constant and only the timing varies -- a mixed-initiator page cannot tell a
// completion-ordered buffer from one that happens to group by kind.
//
//   node tools/fingerprint/probes/b87-order-fixture.mjs 8721
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-order.js \
//        --url http://127.0.0.1:8721/page.html
//
// The names carry the intended start rank (a, b, c) and the server delays them
// 600 / 300 / 0 ms, so a buffer keyed on responseEnd reads c,b,a and one keyed
// on request order reads a,b,c. `?d=` is on the path only for the delay; the
// fixture is node's http, not the Zig test server, so a query string is fine.
import http from 'node:http';

const port = Number(process.argv[2] || 8721);

const PAGE = `<!DOCTYPE html>
<title>order</title>
<script>
// Registered before the images, because the question this answers is the order
// entries ARRIVE in, and an observer added after the loads have finished sees
// nothing at all (with buffered:false) or the buffer's own order (with
// buffered:true). Neither is arrival order. The expression run afterwards can
// only read this list, never rebuild it.
window.__arrivals = [];
try {
  new PerformanceObserver((list) => {
    for (const e of list.getEntries()) window.__arrivals.push(e.name);
  }).observe({ type: 'resource', buffered: false });
} catch (e) { window.__arrivals.push('(observer threw: ' + e.name + ')'); }
</script>
<body>
<img src="/a.gif?d=600">
<img src="/b.gif?d=300">
<img src="/c.gif?d=0">
<script>
// Long enough for the slowest image to have landed before anything is read.
window.__done = new Promise((r) => setTimeout(() => r(true), 1600));
</script>
</body>`;

// Two heads with the same two elements in opposite source order, to ask whether
// the engine issues them in the order it reads them or always puts one kind
// first. The mixed fixture shows this engine starting `head.js` ~1.6ms before a
// `sheet.css` that precedes it in the document; that is either "scripts jump the
// queue" or "the stylesheet's clock starts late", and only swapping the two
// tells them apart.
const pair = (first, second) => `<!DOCTYPE html>
<title>pair</title>
${first}
${second}
<body>
<script>window.__done = new Promise((r) => setTimeout(() => r(true), 300));</script>
</body>`;
// The stylesheet is deliberately slow on `?d=`: this engine fetches an external
// sheet synchronously, so if the <link> really is dispatched at its own position
// in the document, a slow sheet must hold the <script>'s request back behind it.
// If the script goes out first anyway, the <link> was not dispatched there.
const LINK = '<link rel="stylesheet" href="/sheet.css?d=250">';
const SCRIPT = '<script src="/head.js"></' + 'script>';

// A page whose only JS-initiated load is deliberately slow, to ask whether
// `/favicon.ico` is ordered by a RULE ("after every other subresource") or by a
// RACE (whatever is still in flight when the load event fires). On the mixed
// fixture this engine asks for the favicon before an in-flight fetch and Chrome
// asks for it after, which reads like an ordering bug; if Chrome also asks
// early once the chain is slow enough, both arms are running the same rule and
// only the engine's speed differs.
const SLOW_CHAIN = `<!DOCTYPE html>
<title>slow chain</title>
<body>
<script>
window.__done = (async () => {
  await new Promise((r) => { const x = new XMLHttpRequest(); x.open('GET', '/data.txt?d=500'); x.onloadend = r; x.send(); });
  await new Promise((r) => setTimeout(r, 400));
  return true;
})();
</script>
</body>`;

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

// Arrival order on the wire, printed per navigation. A buffer whose ORDER is
// wrong and a buffer whose TIMESTAMPS are wrong look identical from inside the
// page; the server sees which request actually went out first, so it can say
// which of the two it is.
let last = 0;
http.createServer((req, res) => {
    const [url, query] = req.url.split('?');
    if (url.endsWith('.html') && !url.startsWith('/frame')) last = Date.now();
    if (last) console.log(`  wire +${String(Date.now() - last).padStart(4)}ms  ${req.url}`);
    const delay = Number(new URLSearchParams(query || '').get('d') || 0);
    const send = (type, body) => {
        res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
        res.end(body);
    };
    if (url === '/page.html') return send('text/html', PAGE);
    if (url === '/link-first.html') return send('text/html', pair(LINK, SCRIPT));
    if (url === '/script-first.html') return send('text/html', pair(SCRIPT, LINK));
    if (url === '/sheet.css') return setTimeout(() => send('text/css', 'body { color: #111 }'), delay);
    if (url === '/head.js') return send('application/javascript', '/* head */');
    if (url === '/slow-chain.html') return send('text/html', SLOW_CHAIN);
    if (url === '/data.txt') return setTimeout(() => send('text/plain', 'x'.repeat(64)), delay);
    if (url.endsWith('.gif')) return setTimeout(() => send('image/gif', GIF), delay);
    res.writeHead(404);
    res.end();
}).listen(port, () => console.log(`order fixture on ${port}`));
