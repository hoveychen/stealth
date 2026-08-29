// Two origins on one machine, so the cross-origin resource-timing rules can be
// checked without visiting a station.
//
// Resource Timing says an entry for a cross-origin resource is *opaque* unless
// the response carries `Timing-Allow-Origin`: sizes read 0, the connection walk
// collapses onto fetchStart, and nextHopProtocol is the empty string. B66
// measured this engine handing the parent page the widget document's exact byte
// count (101104) and its full connection walk on cf-scrapingcourse where Chrome
// hands over zeros -- but also measured a cross-origin script that BOTH arms
// report in full, which the plain TAO rule does not explain. This fixture
// separates the two claims on ground we control.
//
//   node tools/fingerprint/probes/b87-crossorigin-fixture.mjs 8730 8731
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-crossorigin.js \
//        --url http://127.0.0.1:8730/page.html
//
// 8730 is the page's own origin; 8731 is "the other site". 127.0.0.1 and
// localhost would also be different origins, but two ports is the clearer
// spelling and needs no hosts file.
import http from 'node:http';

const [selfPort, otherPort] = [Number(process.argv[2] || 8730), Number(process.argv[3] || 8731)];
const OTHER = `http://127.0.0.1:${otherPort}`;

// Four cross-origin loads, crossed on the two axes that could matter: what kind
// of thing it is (a framed document vs a plain subresource), and whether the
// response opts into being timed. Plus one same-origin control.
const PAGE = `<!DOCTYPE html>
<title>cross origin</title>
<body>
<img src="/same-origin.gif">
<img src="${OTHER}/plain.gif">
<img src="${OTHER}/tao.gif">
<iframe src="${OTHER}/plain-frame.html"></iframe>
<iframe src="${OTHER}/tao-frame.html"></iframe>
<script>window.__done = new Promise((r) => setTimeout(() => r(true), 700));</script>
</body>`;

const FRAME = '<!DOCTYPE html><title>frame</title><body>frame</body>';
const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');
// Padded so a leaked body size is unmistakable rather than a plausible zero.
const PAD = 'x'.repeat(4096);

const serve = (port, isOther) => http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    const send = (type, body, tao) => {
        const headers = { 'content-type': type, 'cache-control': 'no-store' };
        // Cross-origin reads of the bytes themselves still need CORS; TAO only
        // governs whether the TIMING is visible, and the point here is to vary
        // the two independently.
        if (isOther) headers['access-control-allow-origin'] = '*';
        if (tao) headers['timing-allow-origin'] = '*';
        res.writeHead(200, headers);
        res.end(body);
    };
    if (url === '/page.html') return send('text/html', PAGE);
    if (url === '/same-origin.gif') return send('image/gif', Buffer.concat([GIF, Buffer.from(PAD)]));
    if (url === '/plain.gif') return send('image/gif', Buffer.concat([GIF, Buffer.from(PAD)]));
    if (url === '/tao.gif') return send('image/gif', Buffer.concat([GIF, Buffer.from(PAD)]), true);
    if (url === '/plain-frame.html') return send('text/html', FRAME + `<!--${PAD}-->`);
    if (url === '/tao-frame.html') return send('text/html', FRAME + `<!--${PAD}-->`, true);
    res.writeHead(404);
    res.end();
}).listen(port, () => console.log(`${isOther ? 'other' : 'page'} origin on ${port}`));

serve(selfPort, false);
serve(otherPort, true);
