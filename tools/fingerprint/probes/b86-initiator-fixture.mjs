// One page with every subresource kind that leaves a resource entry, so the
// two arms can be compared on the whole set at once rather than one initiator
// at a time.
//
//   node tools/fingerprint/probes/b86-initiator-fixture.mjs 8720
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b86-initiator-set.js \
//        --url http://127.0.0.1:8720/page.html
//
// The iframe is same-origin and its document loads nothing of its own: a child
// that fetched anything would put entries in ITS OWN buffer, not the parent's,
// and the question here is what the PARENT records for the <iframe> element.
import http from 'node:http';

const port = Number(process.argv[2] || 8720);

const PAGE = `<!DOCTYPE html>
<title>initiators</title>
<link rel="stylesheet" href="/sheet.css">
<script src="/head.js"></script>
<body>
<img src="/pic.gif">
<iframe src="/frame.html"></iframe>
<script>
// XHR and fetch last, so the parser-driven ones are already in the buffer and
// the arrival order is not an accident of when this script ran.
window.__done = (async () => {
  await new Promise((r) => { const x = new XMLHttpRequest(); x.open('GET', '/data.txt'); x.onloadend = r; x.send(); });
  await fetch('/data2.txt').then((r) => r.text());
  await new Promise((r) => setTimeout(r, 400));
  return true;
})();
</script>
</body>`;

// Deliberately empty of subresources -- see the header comment.
const FRAME = '<!DOCTYPE html><title>frame</title><body>frame</body>';

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    const send = (type, body) => {
        res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
        res.end(body);
    };
    if (url === '/page.html') return send('text/html', PAGE);
    if (url === '/frame.html') return send('text/html', FRAME);
    if (url === '/sheet.css') return send('text/css', 'body { color: #111 }');
    if (url === '/head.js') return send('application/javascript', '/* head */');
    if (url === '/pic.gif') return send('image/gif', GIF);
    if (url === '/data.txt' || url === '/data2.txt') return send('text/plain', 'x'.repeat(64));
    res.writeHead(404);
    res.end();
}).listen(port, () => console.log(`initiator fixture on ${port}`));
