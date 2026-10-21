// Local pages for the end-to-end test. Node rather than python's http.server:
// that one listens with a backlog of 5 and stalls concurrent loads for 30s.

import http from 'node:http';

const INDEX = `<!doctype html>
<html><head><title>Fixture Home</title></head>
<body>
<h1>Fixture Home</h1>
<p>Static paragraph.</p>
<ul><li>one</li><li>two</li><li>three</li></ul>
<script>
document.body.insertAdjacentHTML('beforeend', '<p id="dyn">rendered by script</p>');
window.answer = 6 * 7;
</script>
</body></html>`;

const NOT_FOUND = `<!doctype html><html><head><title>Missing</title></head><body><h1>Not Found</h1><p>No such page.</p></body></html>`;

// host is the address to listen on; urlHost is the one put in the page URLs,
// for when the crawler reaches this machine by another name (a container).
export function startFixtureServer(host = '127.0.0.1', urlHost = host) {
    const stats = { inflight: 0, maxInflight: 0 };
    const server = http.createServer((req, res) => {
        const url = new URL(req.url, 'http://x');
        const html = (status, body, headers = {}) => {
            res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', ...headers });
            res.end(body);
        };
        switch (url.pathname) {
            case '/index.html':
                return html(200, INDEX, { 'x-fixture': 'index', 'set-cookie': 'fixture_session=abc123; Path=/' });
            case '/redirect':
                res.writeHead(302, { location: '/index.html' });
                return res.end();
            case '/delay': {
                // Holds the response for ?ms= so concurrent crawls overlap;
                // ?i= is echoed back so each caller can check it got its page.
                stats.inflight++;
                stats.maxInflight = Math.max(stats.maxInflight, stats.inflight);
                const i = url.searchParams.get('i');
                setTimeout(() => {
                    stats.inflight--;
                    html(200, `<!doctype html><html><head><title>delay ${i}</title></head><body><h1>Delay page ${i}</h1></body></html>`);
                }, Number(url.searchParams.get('ms') || 300));
                return;
            }
            case '/hang':
                return; // never answers
            case '/favicon.ico':
                res.writeHead(204);
                return res.end();
            default:
                return html(404, NOT_FOUND);
        }
    });
    return new Promise((resolve) => {
        server.listen(0, host, 1024, () => resolve({ server, stats, base: `http://${urlHost}:${server.address().port}` }));
    });
}
