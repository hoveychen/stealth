// HTTP front for a pool of CDP connections to one `lightpanda serve`.
// See README.md for the API and the environment variables.

import fs from 'node:fs';
import http from 'node:http';
import { Pool } from './lib/pool.mjs';
import { crawl, normalizeRequest, RequestError } from './lib/crawl.mjs';
import { normalizeProxyUrl, parseHostPort, parseProxyList, ProxyPool } from './lib/proxies.mjs';
import { SESSION_ID, SessionStore } from './lib/sessions.mjs';

const env = (name, fallback) => process.env[name] ?? fallback;
const int = (name, fallback) => {
    const v = Number(env(name, fallback));
    if (!Number.isInteger(v) || v <= 0) throw new Error(`${name} must be a positive integer, got ${process.env[name]}`);
    return v;
};
const nonNegInt = (name, fallback) => {
    const v = Number(env(name, fallback));
    if (!Number.isInteger(v) || v < 0) throw new Error(`${name} must be a non-negative integer, got ${process.env[name]}`);
    return v;
};
const bool = (name, fallback) => {
    const v = String(env(name, fallback)).toLowerCase();
    if (['1', 'true', 'yes'].includes(v)) return true;
    if (['0', 'false', 'no', ''].includes(v)) return false;
    throw new Error(`${name} must be true or false, got ${process.env[name]}`);
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
    partialGraceMs: nonNegInt('PARTIAL_GRACE_MS', 2000),
    proxyPoolDefault: bool('PROXY_POOL_DEFAULT', 'false'),
    sessionDir: env('SESSION_DIR', '') || null,
    // Idle time after which a session's cookie jar is dropped (0: never).
    // A week: long enough for a job that comes back daily or weekly to find
    // its login, short enough that one-off session ids don't pile up on disk.
    sessionTtlMs: nonNegInt('SESSION_TTL_MS', 7 * 24 * 3600 * 1000),
    sessionSweepMs: int('SESSION_SWEEP_MS', 10 * 60 * 1000),
    proxyRetries: nonNegInt('PROXY_POOL_RETRIES', 2),
    proxyProbe: null,
};
if (env('PROXY_PROBE', '')) {
    try {
        config.proxyProbe = parseHostPort(process.env.PROXY_PROBE);
    } catch (e) {
        throw new Error(`PROXY_PROBE: ${e.message}`);
    }
}

// Proxy pool: PROXY_POOL and the lines of PROXY_POOL_FILE, together.
const proxyUrls = parseProxyList(env('PROXY_POOL', ''));
if (env('PROXY_POOL_FILE', '')) proxyUrls.push(...parseProxyList(fs.readFileSync(process.env.PROXY_POOL_FILE, 'utf8')));
const proxies = proxyUrls.length
    ? new ProxyPool(
          proxyUrls.map((u) => {
              try {
                  return normalizeProxyUrl(u);
              } catch (e) {
                  throw new Error(`proxy pool: ${e.message}`);
              }
          }),
          { maxFails: int('PROXY_MAX_FAILS', 3), retryAfterMs: int('PROXY_RETRY_AFTER_MS', 60000) },
      )
    : null;
config.proxyPool = proxies;

const sessions = new SessionStore({ dir: config.sessionDir, ttlMs: config.sessionTtlMs });
await sessions.init();
const sweepSessions = () =>
    sessions.sweep().then(
        (n) => n && log({ msg: 'sessions expired', count: n, ttlMs: config.sessionTtlMs }),
        (e) => console.error(`session sweep failed: ${e.message}`),
    );
await sweepSessions();
if (config.sessionTtlMs) setInterval(sweepSessions, config.sessionSweepMs).unref();

const pool = new Pool({ cdpUrl: config.cdpUrl, size: config.poolSize, queueMax: config.queueMax });

const STATUS = {
    queue_full: 503,
    engine_unavailable: 503,
    no_proxy_available: 503,
    engine_disconnected: 502,
    navigation_failed: 502,
    proxy_failed: 502,
    proxy_auth_failed: 502,
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
        const out = await crawl(pool, params, { proxies, sessions, partialGraceMs: config.partialGraceMs, proxyRetries: config.proxyRetries, proxyProbe: config.proxyProbe });
        reply(res, 200, { url: params.url, ...out });
        log({ url: params.url, status: 200, ms: Date.now() - t0 });
    } catch (e) {
        const code = e.code in STATUS ? e.code : 'internal';
        const status = STATUS[code] ?? 500;
        reply(res, status, { error: { code, message: e.message }, ...(e.partial ? { partial: e.partial } : {}) });
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
    if (req.method === 'DELETE' && path.startsWith('/sessions/')) {
        let id = path.slice('/sessions/'.length);
        try {
            id = decodeURIComponent(id);
        } catch {}
        if (!SESSION_ID.test(id)) return reply(res, 400, { error: { code: 'bad_request', message: 'session_id must be 1-128 characters of A-Z a-z 0-9 . _ -' } });
        sessions.delete(id).then(
            (had) => {
                if (had) reply(res, 200, { deleted: id });
                else reply(res, 404, { error: { code: 'not_found', message: `no session ${id}` } });
                log({ msg: 'session delete', id, found: had });
            },
            (e) => reply(res, 500, { error: { code: 'internal', message: e.message } }),
        );
        return;
    }
    if (req.method === 'GET' && path === '/health') {
        return reply(res, 200, { ok: true, pool: pool.stats(), proxies: proxies?.stats() ?? null, sessions: sessions.stats() });
    }
    reply(res, 404, { error: { code: 'not_found', message: `${req.method} ${path}` } });
});

// Requests may legitimately hold for MAX_TIMEOUT_MS plus queueing.
server.requestTimeout = 0;
server.listen(config.port, config.host, 1024, () => {
    log({ msg: 'listening', host: config.host, port: config.port, cdpUrl: config.cdpUrl, poolSize: config.poolSize, proxies: proxies?.size ?? 0, proxyPoolDefault: config.proxyPoolDefault, proxyRetries: config.proxyRetries, proxyProbe: config.proxyProbe, sessionDir: config.sessionDir, sessionTtlMs: config.sessionTtlMs });
});

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        server.close();
        pool.close();
        process.exit(0);
    });
}
