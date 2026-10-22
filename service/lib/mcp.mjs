// POST/DELETE /mcp: the engine's MCP server (`lightpanda mcp --port`), opened
// to agents through this service, with its calls in the request history.
//
// Why a gateway and not the engine's port directly:
//
// - One engine `mcp` process runs every one of its sessions on a single
//   thread, one tool call at a time: a goto that waits 4 s for a slow page
//   holds up every other agent's calls for those 4 s (measured, README). So
//   the service runs several engine processes (MCP_PROCS) and spreads the
//   sessions over them; an agent's session stays on its process.
// - Sessions are minted here, as unguessable ids, and only on `initialize`.
//   The engine itself would route a request without a session id to a shared
//   `default` session, and its session_new / session_list / session_close
//   tools would let one agent list, join or close another's sessions; those
//   tools are taken out of tools/list and refused, and `save` (writes a file
//   inside the container) with them.
// - Every tools/call becomes a history line (kind "mcp").
// - Idle sessions are closed after MCP_SESSION_IDLE_MS, so agents that never
//   send DELETE don't keep browsers alive forever.
//
// The engine processes are started here (not in entrypoint.sh) so that a
// process that dies is noticed at once: its sessions are gone with it, and
// their ids answer 404, which per the MCP spec tells the client to start a
// new session -- rather than silently landing on a fresh blank page.

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';

// Tools an agent of a shared service must not have (see above).
export const HIDDEN_TOOLS = new Set(['session_new', 'session_list', 'session_close', 'save']);
// Tools after which the page may be on another URL: the gateway asks the
// engine for it (getUrl, a few ms) so the history shows where clicks led.
const NAVIGATING_TOOLS = new Set(['goto', 'click', 'press']);
const MCP_SESSION_ID = /^[A-Za-z0-9._-]{1,128}$/;

const rpcError = (id, code, message) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });

// An HTTP client for one engine MCP endpoint. `up` is false while its
// process is (re)starting.
export class Backend {
    constructor(url, { name = url } = {}) {
        this.url = new URL(url);
        this.name = name;
        this.up = true;
        this.agent = new http.Agent({ keepAlive: true, maxSockets: 64 });
        this.calls = 0;
        this.inFlight = 0;
        this.restarts = 0;
        this.pid = null;
    }

    // -> { status, headers, body (string) }; rejects on a connection error or
    // after timeoutMs.
    request(method, headers, body, timeoutMs) {
        return new Promise((resolve, reject) => {
            this.inFlight++;
            const done = (fn, v) => {
                this.inFlight--;
                fn(v);
            };
            const req = http.request(
                {
                    host: this.url.hostname,
                    port: this.url.port,
                    path: this.url.pathname,
                    method,
                    agent: this.agent,
                    // The engine only takes an IP or localhost as Host (DNS
                    // rebinding guard) and refuses any Origin; neither is
                    // forwarded from the client.
                    headers: { host: `${this.url.hostname}:${this.url.port}`, ...headers, ...(body != null ? { 'content-length': Buffer.byteLength(body) } : {}) },
                    timeout: timeoutMs,
                },
                (res) => {
                    const chunks = [];
                    res.on('data', (c) => chunks.push(c));
                    res.on('end', () => done(resolve, { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
                    res.on('error', (e) => done(reject, e));
                },
            );
            req.on('timeout', () => req.destroy(Object.assign(new Error(`no answer from the engine within ${timeoutMs} ms`), { code: 'ETIMEDOUT' })));
            req.on('error', (e) => done(reject, e));
            req.end(body ?? undefined);
        });
    }

    close() {
        this.agent.destroy();
    }
}

// Starts `count` engine MCP processes on 127.0.0.1:basePort.. and restarts
// each when it exits; `onRestart(backend)` runs when one went away. Returns
// the Backends (and a stop()).
export function spawnBackends({ bin = '/bin/lightpanda', count, basePort, proxy = null, preload = '', logLevel = 'info', restartDelayMs = 1000, onRestart = () => {}, log = () => {} }) {
    const backends = [];
    const children = [];
    let stopping = false;
    for (let i = 0; i < count; i++) {
        const port = basePort + i;
        const backend = new Backend(`http://127.0.0.1:${port}/mcp`, { name: `mcp${i}` });
        backend.up = false;
        backends.push(backend);
        const cwd = `/tmp/lp-mcp-${i}`;
        fs.mkdirSync(cwd, { recursive: true });
        // --no-webmcp: pages must not see navigator.modelContext (AGENTS.md).
        // Never --obey-robots, --web-bot-auth-* or --webmcp.
        const args = ['mcp', '--host', '127.0.0.1', '--port', String(port), '--no-webmcp', '--log-level', logLevel, ...(proxy ? ['--http-proxy', proxy] : [])];
        // A clean environment: the engine's getEnv tool hands LP_* variables to
        // the agent, and the service's own (LP_CDP_URL, ...) are none of its
        // business.
        const childEnv = { PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: cwd, LIGHTPANDA_DISABLE_TELEMETRY: 'true' };
        if (preload) childEnv.LD_PRELOAD = preload;
        if (process.env.MALLOC_CONF) childEnv.MALLOC_CONF = process.env.MALLOC_CONF;
        const start = () => {
            if (stopping) return;
            const child = spawn(bin, args, { cwd, env: childEnv, stdio: ['ignore', 'inherit', 'pipe'] });
            children[i] = child;
            backend.pid = child.pid;
            let ready = false;
            let buf = '';
            child.stderr.on('data', (c) => {
                process.stderr.write(c);
                if (ready) return;
                buf += c;
                if (buf.includes('mcp http server running')) {
                    ready = true;
                    buf = '';
                    backend.up = true;
                    log({ msg: 'mcp engine up', backend: backend.name, port, pid: child.pid });
                }
            });
            child.on('exit', (code, signal) => {
                backend.up = false;
                if (stopping) return;
                backend.restarts++;
                log({ msg: 'mcp engine exited', backend: backend.name, code, signal, restartInMs: restartDelayMs });
                onRestart(backend);
                setTimeout(start, restartDelayMs);
            });
        };
        start();
    }
    return {
        backends,
        stop() {
            stopping = true;
            for (const c of children) c?.kill('SIGTERM');
            for (const b of backends) b.close();
        },
    };
}

export class McpGateway {
    // backends: [Backend]. record(entry): one history entry per tools/call
    // (and per session start/end). proxy: the redacted proxy the engines use,
    // or null.
    constructor({ backends, maxSessions = 32, idleMs = 30 * 60 * 1000, callTimeoutMs = 120000, proxy = null, record = () => {}, now = Date.now }) {
        this.backends = backends;
        this.maxSessions = maxSessions;
        this.idleMs = idleMs;
        this.callTimeoutMs = callTimeoutMs;
        this.proxy = proxy;
        this.record = record;
        this.now = now;
        this.sessions = new Map(); // id -> { id, backend, created, lastUsed, calls, url, busy }
        this.counts = { started: 0, closed: 0, expired: 0, lost: 0, calls: 0, toolErrors: 0, refused: 0 };
    }

    // The process behind `backend` went away, and its sessions with it.
    backendRestarted(backend) {
        for (const s of this.sessions.values()) {
            if (s.backend !== backend) continue;
            this.sessions.delete(s.id);
            this.counts.lost++;
            this.recordEvent(s, 'session_lost', 'engine_restarted', 'the engine process serving this session exited');
        }
    }

    // Closes sessions idle for idleMs; resolves to how many.
    async sweep() {
        if (!this.idleMs) return 0;
        const cutoff = this.now() - this.idleMs;
        const stale = [...this.sessions.values()].filter((s) => s.lastUsed < cutoff && !s.busy);
        for (const s of stale) {
            this.sessions.delete(s.id);
            this.counts.expired++;
            await s.backend.request('DELETE', { 'mcp-session-id': s.id }, null, 10000).catch(() => {});
            this.recordEvent(s, 'session_end', null, `idle for more than ${this.idleMs} ms`);
        }
        return stale.length;
    }

    stats() {
        const perBackend = new Map(this.backends.map((b) => [b, 0]));
        for (const s of this.sessions.values()) perBackend.set(s.backend, perBackend.get(s.backend) + 1);
        return {
            enabled: true,
            processes: this.backends.map((b) => ({ name: b.name, pid: b.pid, up: b.up, sessions: perBackend.get(b), inFlight: b.inFlight, calls: b.calls, restarts: b.restarts })),
            sessions: this.sessions.size,
            maxSessions: this.maxSessions,
            idleMs: this.idleMs,
            proxy: this.proxy,
            ...this.counts,
        };
    }

    // GET /mcp/sessions: the live sessions, most recently used first.
    list() {
        const now = this.now();
        return [...this.sessions.values()]
            .sort((a, b) => b.lastUsed - a.lastUsed)
            .map((s) => ({ id: s.id, process: s.backend.name, created: new Date(s.created).toISOString(), lastUsed: new Date(s.lastUsed).toISOString(), idleMs: now - s.lastUsed, calls: s.calls, url: s.url, busy: s.busy }));
    }

    // Handles one request to /mcp. `body` is the raw request body (POST).
    async handle(req, res, body) {
        const sid = req.headers['mcp-session-id'] || null;
        if (req.method === 'DELETE') return this.handleDelete(res, sid);
        if (req.method !== 'POST') {
            // No server-to-client stream: every answer comes back on its POST.
            res.writeHead(405, { allow: 'POST, DELETE', 'content-type': 'application/json' });
            return res.end(JSON.stringify(rpcError(null, -32000, 'only POST and DELETE: this server sends no event stream')));
        }
        let msg;
        try {
            msg = JSON.parse(body);
        } catch {
            return send(res, 400, rpcError(null, -32700, 'body is not valid JSON'));
        }
        if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return send(res, 400, rpcError(null, -32600, 'expected one JSON-RPC message (no batches)'));

        if (msg.method === 'initialize') return this.handleInitialize(res, msg, sid);
        if (!sid) return send(res, 400, rpcError(msg.id, -32000, 'Mcp-Session-Id header required: send initialize first and pass back the session id it returns'));
        const s = this.sessions.get(sid);
        if (!s) return send(res, 404, rpcError(msg.id, -32001, `no MCP session ${sid} (closed, idle for too long, or its engine restarted); initialize a new one`));

        if (msg.method === 'tools/call' && HIDDEN_TOOLS.has(msg.params?.name)) {
            this.counts.refused++;
            const text = `tool ${msg.params.name} is not available on this server; each MCP session is one browser, start another with initialize`;
            return send(res, 200, { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text }], isError: true } }, s.id);
        }

        // One call at a time per session, the follow-up getUrl included: the
        // engine runs them one at a time anyway, and the history needs each
        // call's starting URL to be the previous call's end.
        const run = () => this.dispatch(res, s, msg, body);
        const p = s.tail.then(run, run);
        s.tail = p.catch(() => {});
        return p;
    }

    async dispatch(res, s, msg, body) {
        s.lastUsed = this.now();
        if (msg.method !== 'tools/call') {
            const r = await this.forward(s, body);
            if (!r.ok) return send(res, r.status, rpcError(msg.id, -32603, r.message));
            let out = r.body;
            if (msg.method === 'tools/list' && r.status === 200) out = filterToolList(out);
            return sendRaw(res, r.status, out, s.id);
        }
        return this.handleToolCall(res, s, msg, body);
    }

    async handleInitialize(res, msg, requested) {
        if (requested && this.sessions.has(requested)) {
            // Re-initializing a live session: forward, keep it.
            const s = this.sessions.get(requested);
            s.lastUsed = this.now();
            const r = await this.forward(s, JSON.stringify(msg));
            if (!r.ok) return send(res, r.status, rpcError(msg.id, -32603, r.message));
            return sendRaw(res, r.status, r.body, s.id);
        }
        if (requested && !MCP_SESSION_ID.test(requested)) return send(res, 400, rpcError(msg.id, -32600, 'Mcp-Session-Id must be 1-128 characters of A-Z a-z 0-9 . _ -'));
        if (this.sessions.size >= this.maxSessions) return send(res, 503, rpcError(msg.id, -32000, `all ${this.maxSessions} MCP sessions are in use (MCP_MAX_SESSIONS); close one (DELETE /mcp) or try later`));
        // Try each live process once: one may have just died.
        const tried = new Set();
        let last = 'no MCP engine process is up';
        for (;;) {
            const backend = this.pickBackendExcept(tried);
            if (!backend) return send(res, 503, rpcError(msg.id, -32000, `cannot start an MCP session: ${last}`));
            tried.add(backend);
            const id = requested ?? `mcp-${crypto.randomBytes(12).toString('hex')}`;
            const s = { id, backend, created: this.now(), lastUsed: this.now(), calls: 0, url: null, busy: 0, tail: Promise.resolve() };
            const r = await this.forward(s, JSON.stringify(msg));
            if (!r.ok) {
                last = r.message;
                continue;
            }
            if (r.status === 200) {
                this.sessions.set(id, s);
                this.counts.started++;
                this.recordEvent(s, 'session_start', null, null);
            }
            return sendRaw(res, r.status, r.body, id);
        }
    }

    pickBackendExcept(tried) {
        const load = new Map(this.backends.map((b) => [b, 0]));
        for (const s of this.sessions.values()) load.set(s.backend, load.get(s.backend) + 1);
        const up = this.backends.filter((b) => b.up && !tried.has(b));
        return up.length ? up.reduce((best, b) => (load.get(b) < load.get(best) ? b : best)) : null;
    }

    async handleDelete(res, sid) {
        const s = sid && this.sessions.get(sid);
        if (!s) return send(res, 404, rpcError(null, -32001, `no MCP session ${sid ?? '(no Mcp-Session-Id header)'}`));
        this.sessions.delete(s.id);
        this.counts.closed++;
        await s.backend.request('DELETE', { 'mcp-session-id': s.id }, null, 10000).catch(() => {});
        this.recordEvent(s, 'session_end', null, 'closed by the client');
        res.writeHead(204);
        res.end();
    }

    async handleToolCall(res, s, msg, body) {
        const t0 = this.now();
        const tool = msg.params?.name ?? null;
        const args = msg.params?.arguments ?? {};
        const argUrl = typeof args.url === 'string' ? args.url : null;
        const urlBefore = s.url;
        s.calls++;
        s.busy++;
        this.counts.calls++;
        const r = await this.forward(s, body);
        let entry;
        if (!r.ok) {
            entry = { status: r.status, code: r.code, message: r.message };
            send(res, r.status, rpcError(msg.id, -32603, r.message));
        } else {
            sendRaw(res, r.status, r.body, s.id);
            entry = { status: r.status, code: null, message: null };
            let parsed = null;
            try {
                parsed = JSON.parse(r.body);
            } catch {}
            if (parsed?.error) {
                entry.code = 'rpc_error';
                entry.message = parsed.error.message ?? null;
            } else if (parsed?.result) {
                const text = (parsed.result.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
                entry.resultBytes = Buffer.byteLength(text);
                if (parsed.result.isError) {
                    entry.code = 'tool_error';
                    entry.message = text;
                    this.counts.toolErrors++;
                } else if (tool === 'goto' && /did not finish loading/.test(text)) {
                    entry.code = 'timeout';
                    entry.message = text;
                }
            }
        }
        const ms = this.now() - t0;
        // Where the page is now, for the history (after the answer went out,
        // so it costs the agent nothing but a few ms of this process's thread).
        if (r.ok && NAVIGATING_TOOLS.has(tool) && entry.code !== 'tool_error') {
            const u = await this.forward(s, JSON.stringify({ jsonrpc: '2.0', id: `gw-${s.calls}`, method: 'tools/call', params: { name: 'getUrl', arguments: {} } }));
            try {
                const p = JSON.parse(u.body);
                if (!p.result?.isError) s.url = p.result.content?.[0]?.text ?? s.url;
            } catch {}
        } else if (argUrl && entry.code == null) {
            s.url = argUrl;
        }
        s.busy--;
        s.lastUsed = this.now();
        this.recordCall(s, { tool, url: argUrl ?? urlBefore, finalUrl: s.url, ms, ...entry, args: summarizeArgs(tool, args) });
    }

    // -> { ok: true, status, body } or { ok: false, status, code, message }.
    async forward(s, body) {
        const headers = { 'content-type': 'application/json', accept: 'application/json', 'mcp-session-id': s.id };
        s.backend.calls++;
        try {
            const r = await s.backend.request('POST', headers, body, this.callTimeoutMs);
            return { ok: true, status: r.status === 202 ? 202 : r.status, body: r.body };
        } catch (e) {
            if (e.code === 'ETIMEDOUT') return { ok: false, status: 504, code: 'timeout', message: e.message };
            return { ok: false, status: 502, code: 'engine_error', message: `MCP engine ${s.backend.name}: ${e.code ?? e.message}` };
        }
    }

    recordCall(s, f) {
        this.record({
            kind: 'mcp',
            tool: f.tool,
            url: f.url,
            finalUrl: f.finalUrl,
            status: f.status,
            code: f.code,
            message: f.message,
            ms: f.ms,
            mcp_session: s.id,
            mcp_process: s.backend.name,
            args: f.args ?? null,
            resultBytes: f.resultBytes ?? null,
        });
    }

    recordEvent(s, tool, code, message) {
        this.record({ kind: 'mcp', tool, url: s.url, finalUrl: s.url, status: 200, code, message, ms: this.now() - s.created, mcp_session: s.id, mcp_process: s.backend.name, args: null, resultBytes: null });
    }
}

// What the history keeps of a call's arguments: the small, non-secret ones
// that say what the agent did (a selector, a key), never fill values or
// scripts in full.
function summarizeArgs(tool, args) {
    if (!args || typeof args !== 'object') return null;
    const out = {};
    for (const [k, v] of Object.entries(args)) {
        if (k === 'url') continue;
        if (tool === 'fill' && k === 'value') out[k] = `(${String(v).length} chars)`;
        else if (typeof v === 'string') out[k] = v.length > 200 ? `${v.slice(0, 200)}…` : v;
        else if (typeof v === 'number' || typeof v === 'boolean') out[k] = v;
    }
    return Object.keys(out).length ? out : null;
}

function filterToolList(body) {
    try {
        const p = JSON.parse(body);
        if (Array.isArray(p.result?.tools)) {
            p.result.tools = p.result.tools.filter((t) => !HIDDEN_TOOLS.has(t.name));
            return JSON.stringify(p);
        }
    } catch {}
    return body;
}

function send(res, status, obj, sid = null) {
    sendRaw(res, status, JSON.stringify(obj), sid);
}

function sendRaw(res, status, text, sid = null) {
    if (status === 202 || !text) {
        res.writeHead(202, sid ? { 'mcp-session-id': sid } : {});
        return res.end();
    }
    const buf = Buffer.from(text);
    const headers = { 'content-type': 'application/json', 'content-length': buf.length };
    if (sid) headers['mcp-session-id'] = sid;
    res.writeHead(status, headers);
    res.end(buf);
}
