// HTTP front for a pool of CDP connections to one `lightpanda serve`.
// See README.md for the API and the environment variables.

import http from 'node:http';
import { Pool } from './lib/pool.mjs';
import { crawl, normalizeRequest, RequestError } from './lib/crawl.mjs';

const env = (name, fallback) => process.env[name] ?? fallback;
const int = (name, fallback) => {
    const v = Number(env(name, fallback));
    if (!Number.isInteger(v) || v <= 0) throw new Error(`${name} must be a positive integer, got ${process.env[name]}`);
    return v;
};

const config = {
    host: env('HOST', '0.0.0.0'),
    port: int('PORT', 8080),
    cdpUrl: env('LP_CDP_URL', 'ws://127.0.0.1:9222/').replace(/^http/, 'ws'),
    poolSize: int('POOL_SIZE', 4),
    queueMax: int('QUEUE_MAX', 100),
    defaultTimeoutMs: int('DEFAULT_TIMEOUT_MS', 30000),
    maxTimeoutMs: int('MAX_TIMEOUT_MS', 120000),
    maxBodyBytes: int('MAX_BODY_BYTES', 1 << 20),
};

const pool = new Pool({ cdpUrl: config.cdpUrl, size: config.poolSize, queueMax: config.queueMax });

const STATUS = {
    queue_full: 503,
    engine_unavailable: 503,
    engine_disconnected: 502,
    navigation_failed: 502,
    cdp_error: 502,
    timeout: 504,
};

function reply(res, status, body) {
    const text = JSON.stringify(body);
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
    res.end(text);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > config.maxBodyBytes) {
                reject(new RequestError(`body larger than ${config.maxBodyBytes} bytes`));
                req.destroy();
                return;
            }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

async function handleCrawl(req, res) {
    let params;
    try {
        const raw = await readBody(req);
        let body;
        try {
            body = JSON.parse(raw);
        } catch {
            throw new RequestError('body is not valid JSON');
        }
        params = normalizeRequest(body, config);
    } catch (e) {
        if (e instanceof RequestError) return reply(res, 400, { error: { code: 'bad_request', message: e.message } });
        throw e;
    }
    const t0 = Date.now();
    try {
        const out = await crawl(pool, params);
        reply(res, 200, { url: params.url, ...out });
        log({ url: params.url, status: 200, ms: Date.now() - t0 });
    } catch (e) {
        const code = e.code in STATUS ? e.code : 'internal';
        const status = STATUS[code] ?? 500;
        reply(res, status, { error: { code, message: e.message } });
        log({ url: params.url, status, code, ms: Date.now() - t0, message: e.message });
    }
}

function log(fields) {
    console.log(JSON.stringify({ time: new Date().toISOString(), ...fields }));
}

const server = http.createServer((req, res) => {
    const path = req.url.split('?')[0];
    if (req.method === 'POST' && path === '/crawl') {
        handleCrawl(req, res).catch((e) => {
            if (!res.headersSent) reply(res, 500, { error: { code: 'internal', message: e.message } });
        });
        return;
    }
    if (req.method === 'GET' && path === '/health') return reply(res, 200, { ok: true, pool: pool.stats() });
    reply(res, 404, { error: { code: 'not_found', message: `${req.method} ${path}` } });
});

// Requests may legitimately hold for MAX_TIMEOUT_MS plus queueing.
server.requestTimeout = 0;
server.listen(config.port, config.host, 1024, () => {
    log({ msg: 'listening', host: config.host, port: config.port, cdpUrl: config.cdpUrl, poolSize: config.poolSize });
});

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        server.close();
        pool.close();
        process.exit(0);
    });
}
