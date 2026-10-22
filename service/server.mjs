// HTTP front for a pool of CDP connections to one `lightpanda serve`.
// See README.md for the API and the environment variables.

import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import { Pool } from './lib/pool.mjs';
import { crawl, normalizeRequest, RequestError } from './lib/crawl.mjs';
import { History, MAX_LIMIT } from './lib/history.mjs';
import { McpGateway, spawnBackends } from './lib/mcp.mjs';
import { normalizeProxyUrl, parseHostPort, parseProxyList, ProxyPool, redact } from './lib/proxies.mjs';
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
    historyDir: env('HISTORY_DIR', '') || null,
    // Days of request history kept, today included (0: keep everything). A
    // week covers "what happened yesterday / last week" and bounds the disk:
    // a line is ~0.4 KB, so a container kept busy around the clock writes
    // ~20 GB a day (see README), and a week of that is already a lot.
    historyRetentionDays: nonNegInt('HISTORY_RETENTION_DAYS', 7),
    // Part of the file names, so replicas sharing a volume don't share files.
    // In a container the hostname is the container id.
    historyReplica: env('HISTORY_REPLICA', '') || os.hostname(),
    proxyProbe: null,
    // MCP (POST /mcp): engine `mcp` processes to spread agent sessions over;
    // 0 turns /mcp off. Each process runs its sessions' tool calls one at a
    // time, so this is how many agents can have a call in flight at once.
    mcpProcs: nonNegInt('MCP_PROCS', 0),
    mcpBasePort: int('MCP_BASE_PORT', 9300),
    mcpMaxSessions: int('MCP_MAX_SESSIONS', 32),
    // Sessions with no call for this long are closed (0: never). Half an hour
    // leaves room for an agent that thinks for minutes between calls.
    mcpIdleMs: nonNegInt('MCP_SESSION_IDLE_MS', 30 * 60 * 1000),
    mcpCallTimeoutMs: int('MCP_CALL_TIMEOUT_MS', 120000),
    // Time the MCP sessions get to write their cookies back when the service
    // stops; with the history's 2 s it stays inside docker stop's 10 s.
    shutdownSaveMs: int('SHUTDOWN_SAVE_MS', 5000),
    mcpProxy: null,
};
if (env('PROXY_PROBE', '')) {
    try {
        config.proxyProbe = parseHostPort(process.env.PROXY_PROBE);
    } catch (e) {
        throw new Error(`PROXY_PROBE: ${e.message}`);
    }
}

// One proxy for all MCP browsing (the engine's --http-proxy); the MCP tools
// have no per-call proxy.
if (env('MCP_PROXY', '')) {
    try {
        config.mcpProxy = normalizeProxyUrl(process.env.MCP_PROXY);
    } catch (e) {
        throw new Error(`MCP_PROXY: ${e.message}`);
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

const history = new History({ dir: config.historyDir, retentionDays: config.historyRetentionDays, replica: config.historyReplica });
await history.init();
const sweepHistory = () =>
    history.sweep().then(
        (n) => n && log({ msg: 'history files expired', count: n, retentionDays: config.historyRetentionDays }),
        (e) => console.error(`history sweep failed: ${e.message}`),
    );
await sweepHistory();
if (history.enabled && config.historyRetentionDays) setInterval(sweepHistory, 3600 * 1000).unref();

const pool = new Pool({ cdpUrl: config.cdpUrl, size: config.poolSize, queueMax: config.queueMax });

let mcp = null, mcpEngines = null;
if (config.mcpProcs) {
    mcpEngines = spawnBackends({
        bin: env('LP_BIN', '/bin/lightpanda'),
        count: config.mcpProcs,
        basePort: config.mcpBasePort,
        proxy: config.mcpProxy,
        preload: env('LP_ENGINE_PRELOAD', ''),
        logLevel: env('LP_LOG_LEVEL', 'info'),
        restartDelayMs: 1000 * Number(env('LP_RESTART_DELAY', 1)),
        onRestart: (b) => mcp?.backendRestarted(b),
        log,
    });
    mcp = new McpGateway({
        backends: mcpEngines.backends,
        maxSessions: config.mcpMaxSessions,
        idleMs: config.mcpIdleMs,
        callTimeoutMs: config.mcpCallTimeoutMs,
        proxy: config.mcpProxy && redact(config.mcpProxy),
        cookieJars: sessions,
        record: logMcp,
    });
    if (config.mcpIdleMs) {
        setInterval(() => mcp.sweep().then((n) => n && log({ msg: 'mcp sessions expired', count: n, idleMs: config.mcpIdleMs })), Math.min(60000, Math.max(1000, config.mcpIdleMs / 4))).unref();
    }
}

// The admin page: one static file, no external resources.
const ADMIN_PAGE = fs.readFileSync(new URL('./admin.html', import.meta.url));

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

// Encoded once: Buffer.byteLength and then res.end(text) would go over a
// large html response twice; on a 34 KB page with a character above U+00FF
// the second pass is ~25 us, which pays for the history's byte counts.
function reply(res, status, body) {
    const buf = Buffer.from(JSON.stringify(body));
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': buf.length });
    res.end(buf);
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
    const t0 = Date.now();
    let params, body;
    try {
        const raw = await readBody(req);
        try {
            body = JSON.parse(raw);
        } catch {
            throw new RequestError('body is not valid JSON');
        }
        params = normalizeRequest(body, config);
    } catch (e) {
        if (e instanceof RequestError) {
            reply(res, 400, { error: { code: 'bad_request', message: e.message } });
            const url = typeof body?.url === 'string' ? body.url : null;
            return logCrawl({ url, status: 400, code: 'bad_request', message: e.message, ms: Date.now() - t0 });
        }
        throw e;
    }
    const info = {};
    const request = { session_id: params.sessionId ?? null, formats: params.formats, proxyMode: params.proxy.mode };
    try {
        const out = await crawl(pool, params, { proxies, sessions, partialGraceMs: config.partialGraceMs, proxyRetries: config.proxyRetries, proxyProbe: config.proxyProbe }, info);
        reply(res, 200, { url: params.url, ...out });
        logCrawl({ url: params.url, status: 200, code: null, message: null, ms: Date.now() - t0, ...request, ...info, htmlBytes: bytes(out.html), markdownBytes: bytes(out.markdown), partial: null });
    } catch (e) {
        const code = e.code in STATUS ? e.code : 'internal';
        const status = STATUS[code] ?? 500;
        reply(res, status, { error: { code, message: e.message }, ...(e.partial ? { partial: e.partial } : {}) });
        const partial = e.partial ? { source: e.partial.source, htmlBytes: bytes(e.partial.html), markdownBytes: bytes(e.partial.markdown) } : null;
        logCrawl({ url: params.url, status, code, message: e.message, ms: Date.now() - t0, ...request, ...info, htmlBytes: null, markdownBytes: null, partial });
    }
}

const bytes = (s) => (typeof s === 'string' ? Buffer.byteLength(s) : null);
const clip = (s, n) => (typeof s === 'string' && s.length > n ? `${s.slice(0, n)}…` : s);

// One crawl's line, the same on stdout and in the history. Page content is
// never part of it, only its size.
function logCrawl(f) {
    const entry = {
        time: new Date().toISOString(),
        kind: 'crawl',
        url: f.url == null ? null : clip(redact(f.url), 2048),
        finalUrl: f.finalUrl == null ? null : clip(redact(f.finalUrl), 2048),
        status: f.status,
        code: f.code,
        message: clip(f.message, 1000),
        pageStatus: f.pageStatus ?? null,
        ms: f.ms,
        queueMs: f.queueMs ?? null,
        proxyMode: f.proxyMode ?? null,
        proxy: f.proxy ?? null,
        proxiesTried: f.proxiesTried ?? 0,
        session_id: f.session_id ?? null,
        formats: f.formats ?? null,
        htmlBytes: f.htmlBytes ?? null,
        markdownBytes: f.markdownBytes ?? null,
        partial: f.partial ?? null,
        replica: history.replica,
    };
    const line = JSON.stringify(entry);
    console.log(line);
    history.record(entry, line);
}

// One MCP tools/call (or session start/end), in the same shape as a crawl's
// line so /history and the admin page take both; kind "mcp", the tool, the
// MCP session and the engine process are its own. session_id is the /crawl
// session the MCP session is bound to, if any.
function logMcp(f) {
    const entry = {
        time: new Date().toISOString(),
        kind: 'mcp',
        tool: f.tool,
        url: f.url == null ? null : clip(redact(f.url), 2048),
        finalUrl: f.finalUrl == null ? null : clip(redact(f.finalUrl), 2048),
        status: f.status,
        code: f.code,
        message: clip(f.message, 1000),
        pageStatus: null,
        ms: f.ms,
        queueMs: null,
        proxyMode: config.mcpProxy ? 'url' : 'direct',
        proxy: config.mcpProxy && redact(config.mcpProxy),
        proxiesTried: 0,
        session_id: f.session_id ?? null,
        mcp_session: f.mcp_session,
        mcp_process: f.mcp_process,
        args: f.args,
        resultBytes: f.resultBytes,
        replica: history.replica,
    };
    const line = JSON.stringify(entry);
    console.log(line);
    history.record(entry, line);
}

function log(fields) {
    console.log(JSON.stringify({ time: new Date().toISOString(), ...fields }));
}

// GET /history query string -> History.query filter; throws RequestError.
function historyFilter(q) {
    const intParam = (name, min, max, fallback) => {
        if (!q.has(name)) return fallback;
        const v = Number(q.get(name));
        if (!Number.isInteger(v) || v < min || v > max) throw new RequestError(`${name} must be an integer from ${min} to ${max}`);
        return v;
    };
    const time = (name) => {
        if (!q.has(name)) return undefined;
        const raw = q.get(name);
        const v = /^\d+$/.test(raw) ? Number(raw) : Date.parse(raw);
        if (!Number.isFinite(v)) throw new RequestError(`${name} must be an ISO time or milliseconds since the epoch`);
        return v;
    };
    const list = (name) => (q.get(name) ? q.get(name).split(',').map((s) => s.trim()).filter(Boolean) : undefined);
    const status = list('status')?.map((s) => {
        if (!/^\d{3}$/.test(s)) throw new RequestError('status must be HTTP status codes, comma-separated');
        return Number(s);
    });
    const kind = q.get('kind') || undefined;
    if (kind && kind !== 'crawl' && kind !== 'mcp') throw new RequestError('kind must be crawl or mcp');
    return {
        url: q.get('url') || undefined,
        status,
        code: list('code'),
        session_id: q.get('session_id') || undefined,
        kind,
        since: time('since'),
        until: time('until'),
        limit: intParam('limit', 1, MAX_LIMIT, 100),
        days: intParam('days', 1, 3650, 3),
    };
}

function handleHistory(req, res) {
    if (!history.enabled) return reply(res, 200, { enabled: false, entries: [] });
    let filter;
    try {
        filter = historyFilter(new URL(req.url, 'http://x').searchParams);
    } catch (e) {
        return reply(res, 400, { error: { code: 'bad_request', message: e.message } });
    }
    history.query(filter).then(
        (r) => reply(res, 200, { enabled: true, ...r }),
        (e) => reply(res, 500, { error: { code: 'internal', message: e.message } }),
    );
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
    if (path === '/mcp') {
        if (!mcp) return reply(res, 404, { error: { code: 'not_found', message: 'MCP is off (MCP_PROCS=0)' } });
        readBody(req)
            .then((body) => mcp.handle(req, res, body))
            .catch((e) => {
                if (!res.headersSent) reply(res, e instanceof RequestError ? 400 : 500, { jsonrpc: '2.0', id: null, error: { code: -32603, message: e.message } });
            });
        return;
    }
    if (req.method === 'GET' && path === '/mcp/sessions') {
        if (!mcp) return reply(res, 404, { error: { code: 'not_found', message: 'MCP is off (MCP_PROCS=0)' } });
        return reply(res, 200, { total: mcp.sessions.size, sessions: mcp.list() });
    }
    if (req.method === 'GET' && path === '/health') {
        return reply(res, 200, { ok: true, pool: pool.stats(), proxies: proxies?.stats() ?? null, sessions: sessions.stats(), history: history.stats(), mcp: mcp?.stats() ?? { enabled: false } });
    }
    if (req.method === 'GET' && path === '/history') return handleHistory(req, res);
    if (req.method === 'GET' && path === '/sessions') {
        const limit = Number(new URL(req.url, 'http://x').searchParams.get('limit') ?? 200);
        if (!Number.isInteger(limit) || limit < 1 || limit > 10000) return reply(res, 400, { error: { code: 'bad_request', message: 'limit must be an integer from 1 to 10000' } });
        sessions.list(limit).then(
            (r) => reply(res, 200, r),
            (e) => reply(res, 500, { error: { code: 'internal', message: e.message } }),
        );
        return;
    }
    if (req.method === 'GET' && (path === '/' || path === '/index.html')) {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-length': ADMIN_PAGE.length, 'cache-control': 'no-cache' });
        return res.end(ADMIN_PAGE);
    }
    reply(res, 404, { error: { code: 'not_found', message: `${req.method} ${path}` } });
});

// Requests may legitimately hold for MAX_TIMEOUT_MS plus queueing.
server.requestTimeout = 0;
server.listen(config.port, config.host, 1024, () => {
    log({ msg: 'listening', host: config.host, port: config.port, cdpUrl: config.cdpUrl, poolSize: config.poolSize, proxies: proxies?.size ?? 0, proxyPoolDefault: config.proxyPoolDefault, proxyRetries: config.proxyRetries, proxyProbe: config.proxyProbe, sessionDir: config.sessionDir, sessionTtlMs: config.sessionTtlMs, historyDir: config.historyDir, historyRetentionDays: config.historyRetentionDays, historyReplica: history.replica, mcpProcs: config.mcpProcs, mcpProxy: config.mcpProxy && redact(config.mcpProxy) });
});

// `docker stop` gives 10 s before SIGKILL: up to SHUTDOWN_SAVE_MS for the
// MCP sessions' last cookie write-back, then up to 2 s for the history.
let stopping = false;
for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, async () => {
        if (stopping) return;
        stopping = true;
        server.close();
        pool.close();
        if (mcp) {
            const t0 = Date.now();
            const r = await mcp.shutdown(config.shutdownSaveMs);
            if (r.sessions) log({ msg: 'mcp cookies saved on shutdown', signal: sig, ...r, ms: Date.now() - t0 });
        }
        mcpEngines?.stop();
        // The last second of history is still queued; give it a moment.
        const exit = () => process.exit(0);
        setTimeout(exit, 2000).unref();
        history.close().then(exit, exit);
    });
}
