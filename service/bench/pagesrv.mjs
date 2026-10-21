// Static page server for the concurrency benchmark: serves ./site from memory.
//
//   node service/bench/pagesrv.mjs [host] [port] [workers]
//
// The listen backlog is large on purpose: Python's http.server (backlog 5)
// drops SYNs under a few dozen concurrent loads and the retransmit shows up as
// multi-second page loads that are the page server's, not the engine's.
// `workers` > 1 forks that many processes sharing the port. `/hang` never
// answers (soak.mjs uses it for timeouts).

import cluster from 'node:cluster';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';

const [host = '0.0.0.0', port = '9790', workers = '1'] = process.argv.slice(2);
const root = path.join(path.dirname(new URL(import.meta.url).pathname), 'site');
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'application/javascript', '.svg': 'image/svg+xml' };

if (cluster.isPrimary && +workers > 1) {
    for (let i = 0; i < +workers; i++) cluster.fork();
} else {
    const files = new Map();
    for (const name of fs.readdirSync(root)) files.set(`/${name}`, fs.readFileSync(path.join(root, name)));
    http.createServer((req, res) => {
        const p = req.url.split('?')[0];
        // Never answers: for timeouts (a script or a document that never arrives).
        if (p === '/hang') return;
        const body = files.get(p);
        if (!body) {
            res.writeHead(404, { 'content-length': 0 });
            res.end();
            return;
        }
        res.writeHead(200, { 'content-type': TYPES[path.extname(p)] ?? 'application/octet-stream', 'content-length': body.length });
        res.end(body);
    }).listen(+port, host, 4096, () => console.log(`pagesrv ${process.pid} on ${host}:${port}`));
}
