// Unit checks for the proxy pool, telling a dead proxy from a dead target,
// the session store (cookie merge, TTL, delete) and the request history
// (daily files, retention, queries) and the MCP gateway (against fake engine
// MCP servers); no engine.
//
//   node service/test/unit.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { diagnoseProxyFailure, normalizeProxyUrl, parseHostPort, parseProxyList, ProxyPool, redact } from '../lib/proxies.mjs';
import http from 'node:http';
import { History } from '../lib/history.mjs';
import { Backend, HIDDEN_TOOLS, McpGateway } from '../lib/mcp.mjs';
import { McpClient } from './mcp-client.mjs';
import { SessionStore } from '../lib/sessions.mjs';
import { startHttpProxy, startSocksProxy } from './proxy-server.mjs';

let failures = 0;
async function check(name, fn) {
    try {
        await fn();
        console.log(`PASS  ${name}`);
    } catch (e) {
        failures++;
        console.log(`FAIL  ${name}  -- ${e.message}`);
    }
}

await check('parseProxyList: commas, whitespace, newlines and comments', () => {
    assert.deepEqual(parseProxyList('http://a:1, http://b:2\n# off: http://x:9\nsocks5://c:3  # trailing\n\n'), ['http://a:1', 'http://b:2', 'socks5://c:3']);
});

await check('normalizeProxyUrl: accepts the verified schemes, rejects the rest', () => {
    for (const u of ['http://h:1', 'https://h:1', 'socks5://u:p@h:1', 'socks5h://h:1']) assert.equal(normalizeProxyUrl(u), u);
    for (const u of ['ftp://h:1', 'socks4://h:1', 'http://h', 'http://h:1/path', 'h:1', '']) assert.throws(() => normalizeProxyUrl(u));
    assert.throws(() => normalizeProxyUrl('ftp://u:hunter2@h:1'), (e) => !e.message.includes('hunter2'));
});

await check('redact: hides the password only', () => {
    assert.equal(redact('http://user:p%40ss@h:1'), 'http://user:***@h:1');
    assert.equal(redact('socks5://h:1'), 'socks5://h:1');
});

await check('ProxyPool: round robin, ejection after maxFails, retry after the period', () => {
    let now = 1000;
    const pool = new ProxyPool(['http://a:1', 'http://b:2', 'http://c:3'], { maxFails: 2, retryAfterMs: 500, now: () => now });
    assert.deepEqual([1, 2, 3, 4].map(() => pool.pick().url), ['http://a:1', 'http://b:2', 'http://c:3', 'http://a:1']);
    const b = pool.entries[1];
    pool.failed(b, 'x');
    assert.equal(pool.stats().active, 3);
    pool.failed(b, 'y');
    assert.equal(pool.stats().proxies[1].state, 'ejected');
    assert.deepEqual([1, 2, 3].map(() => pool.pick().url), ['http://c:3', 'http://a:1', 'http://c:3']);
    now += 500;
    assert.equal(pool.stats().proxies[1].state, 'active');
    pool.failed(b, 'z');
    assert.equal(pool.stats().proxies[1].state, 'ejected', 'one failure after the retry ejects again');
    now += 500;
    pool.succeeded(b);
    assert.equal(b.consecutiveFails, 0);
});

await check('ProxyPool: pick() is null when every proxy is ejected', () => {
    const pool = new ProxyPool(['http://a:1'], { maxFails: 1, retryAfterMs: 60000 });
    pool.failed(pool.pick(), 'down');
    assert.equal(pool.pick(), null);
});

await check('ProxyPool: pick(exclude) skips the proxies a request already tried', () => {
    const pool = new ProxyPool(['http://a:1', 'http://b:2', 'http://c:3']);
    const tried = new Set([pool.pick()]);
    tried.add(pool.pick(tried));
    assert.equal(pool.pick(tried).url, 'http://c:3');
    tried.add(pool.entries[2]);
    assert.equal(pool.pick(tried), null);
});

await check('parseHostPort: host:port and URLs', () => {
    assert.deepEqual(parseHostPort('example.com:443'), { host: 'example.com', port: 443 });
    assert.deepEqual(parseHostPort('https://example.com/x'), { host: 'example.com', port: 443 });
    assert.deepEqual(parseHostPort('http://10.0.0.1:8080'), { host: '10.0.0.1', port: 8080 });
    assert.deepEqual(parseHostPort('[::1]:80'), { host: '::1', port: 80 });
    assert.throws(() => parseHostPort('example.com'));
});

// Real proxies on loopback: a good one, one with a password, a SOCKS5 one,
// one that answers 502 to everything (a live port with a dead upstream), a
// closed port (a dead proxy), a closed port as the dead target, and a
// listening port as the probe.
{
    const closedPort = () => new Promise((r) => { const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => r(port)); }); });
    const H = '127.0.0.1';
    const good = await startHttpProxy({ host: H });
    const authed = await startHttpProxy({ host: H, auth: 'u:p' });
    const socks = await startSocksProxy({ host: H, auth: 'u:p' });
    const broken = await startHttpProxy({ host: H, broken: true });
    const probeSrv = await new Promise((r) => { const s = net.createServer((c) => c.destroy()).listen(0, H, () => r(s)); });
    const probe = { host: H, port: probeSrv.address().port };
    const deadProxy = await closedPort();
    const downTarget = `https://${H}:${await closedPort()}/`;
    const upTarget = `https://${H}:${probe.port}/`;
    const d = (proxy, target, withProbe = true) => diagnoseProxyFailure(proxy, target, { probe: withProbe ? probe : null, timeoutMs: 1500 });
    await check('diagnoseProxyFailure: dead proxy -> proxy_down', async () => assert.equal(await d(`http://${H}:${deadProxy}`, downTarget), 'proxy_down'));
    await check('diagnoseProxyFailure: good proxy, dead target, probe reachable -> target_down', async () => assert.equal(await d(`http://${H}:${good.port}`, downTarget), 'target_down'));
    await check('diagnoseProxyFailure: good proxy, dead target, no probe -> unknown (not charged)', async () => assert.equal(await d(`http://${H}:${good.port}`, downTarget, false), 'unknown'));
    await check('diagnoseProxyFailure: good proxy, target that answers now -> unknown', async () => assert.equal(await d(`http://${H}:${good.port}`, upTarget), 'unknown'));
    await check('diagnoseProxyFailure: proxy that refuses every tunnel (probe too) -> proxy_down', async () => assert.equal(await d(`http://${H}:${broken.port}`, downTarget), 'proxy_down'));
    await check('diagnoseProxyFailure: wrong or missing password -> auth', async () => {
        assert.equal(await d(`http://u:wrong@${H}:${authed.port}`, downTarget), 'auth');
        assert.equal(await d(`http://${H}:${authed.port}`, downTarget), 'auth');
        assert.equal(await d(`http://u:p@${H}:${authed.port}`, downTarget), 'target_down');
    });
    await check('diagnoseProxyFailure: SOCKS5 the same way', async () => {
        assert.equal(await d(`socks5://u:p@${H}:${socks.port}`, downTarget), 'target_down');
        assert.equal(await d(`socks5://u:wrong@${H}:${socks.port}`, downTarget), 'auth');
        assert.equal(await d(`socks5://${H}:${socks.port}`, downTarget), 'auth');
        assert.equal(await d(`socks5://u:p@${H}:${deadProxy}`, downTarget), 'proxy_down');
    });
    for (const p of [good, authed, socks, broken]) p.server.close();
    probeSrv.close();
}

const c = (name, value, extra = {}) => ({ name, value, domain: 'h', path: '/', httpOnly: false, secure: false, ...extra });
const names = async (store, id) => (await store.load(id)).map((x) => `${x.name}=${x.value}`).sort().join(' ');

await check('SessionStore: per-cookie three-way merge of concurrent crawls', async () => {
    const s = new SessionStore();
    await s.save('s', [], [c('a', '1'), c('d', '1')]);
    const base1 = await s.load('s');
    const base2 = await s.load('s');
    await s.save('s', base1, [c('a', '1'), c('d', '1'), c('b', '2')]); // adds b
    await s.save('s', base2, [c('a', '9'), c('c', '3')]); // changes a, adds c, deletes d
    assert.equal(await names(s, 's'), 'a=9 b=2 c=3');
});

await check('SessionStore: a delete does not undo a concurrent change', async () => {
    const s = new SessionStore();
    await s.save('s', [], [c('a', '1')]);
    const base1 = await s.load('s');
    const base2 = await s.load('s');
    await s.save('s', base1, [c('a', '2')]);
    await s.save('s', base2, []);
    assert.equal(await names(s, 's'), 'a=2');
});

await check('SessionStore: expired cookies are dropped; jars persist and reload', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-sessions-'));
    const s = new SessionStore({ dir });
    await s.init();
    await s.save('x', [], [c('keep', '1', { expires: Date.now() / 1000 + 3600, size: 5, session: false }), c('old', '1', { expires: 1 }), c('sess', '1', { expires: -1, session: true })]);
    const again = new SessionStore({ dir });
    assert.equal(await names(again, 'x'), 'keep=1 sess=1');
    const stored = (await again.load('x')).find((x) => x.name === 'sess');
    assert.ok(!('expires' in stored) && !('size' in stored) && !('session' in stored));
    fs.rmSync(dir, { recursive: true });
});

await check('SessionStore: an idle jar expires after ttlMs (memory), a used one does not', async () => {
    let now = 1_000_000;
    const s = new SessionStore({ ttlMs: 1000, now: () => now });
    await s.save('a', await s.load('a'), [c('x', '1')]);
    await s.save('b', await s.load('b'), [c('y', '1')]);
    now += 600;
    await s.load('b'); // using it resets its clock
    now += 600;
    assert.equal(await s.sweep(), 1);
    assert.equal(s.jars.has('a'), false);
    assert.equal(await names(s, 'b'), 'y=1');
    now += 1000;
    assert.equal(await names(s, 'b'), '', 'a load past the TTL starts empty even before a sweep');
    assert.equal(s.stats().expired, 2);
});

await check('SessionStore: sweep deletes expired files, at startup too, and stale tmp files', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-sessions-'));
    let now = Date.now();
    const s = new SessionStore({ dir, ttlMs: 60_000, now: () => now });
    await s.init();
    await s.save('old', [], [c('a', '1')]);
    await s.save('new', [], [c('b', '1')]);
    const past = new Date(Date.now() - 120_000);
    fs.utimesSync(path.join(dir, 'old.json'), past, past);
    fs.writeFileSync(path.join(dir, 'crash.json.1.tmp'), '{');
    fs.utimesSync(path.join(dir, 'crash.json.1.tmp'), past, past);
    // A fresh store, as after a restart: only the file times say what is idle.
    const restarted = new SessionStore({ dir, ttlMs: 60_000 });
    await restarted.init();
    assert.equal(restarted.stats().stored, 2);
    assert.equal(await restarted.sweep(), 1);
    assert.deepEqual(fs.readdirSync(dir).sort(), ['new.json']);
    assert.equal(restarted.stats().stored, 1);
    assert.equal(await names(restarted, 'new'), 'b=1');
    // In memory, the original store's jar for "new" is still recent; move its clock.
    now += 61_000;
    assert.equal(await s.sweep(), 2); // "old" in memory and "new" both idle now
    assert.deepEqual(fs.readdirSync(dir), []);
    fs.rmSync(dir, { recursive: true });
});

await check('SessionStore: delete removes the jar and its file; a crawl that loaded before does not bring it back', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-sessions-'));
    const s = new SessionStore({ dir });
    await s.init();
    await s.save('x', [], [c('a', '1')]);
    const inflight = await s.load('x');
    assert.equal(await s.delete('x'), true);
    assert.equal(fs.existsSync(path.join(dir, 'x.json')), false);
    await s.save('x', inflight, [c('a', '1'), c('b', '2')]);
    assert.equal(fs.existsSync(path.join(dir, 'x.json')), false);
    assert.equal(await names(s, 'x'), '');
    assert.equal(await s.delete('nothing'), false);
    const fresh = await s.load('x');
    await s.save('x', fresh, [c('c', '3')]);
    assert.equal(await names(s, 'x'), 'c=3', 'a crawl that starts after the delete saves normally');
    assert.equal(s.stats().deleted, 1);
    fs.rmSync(dir, { recursive: true });
});

const DAY = 24 * 3600 * 1000;
const hEntry = (time, fields = {}) => ({ time: new Date(time).toISOString(), url: 'https://a.example/', finalUrl: null, status: 200, code: null, session_id: null, ...fields });

await check('History: one file per UTC day and replica, appended in batches, nothing written before the flush', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-history-'));
    const t = Date.parse('2026-10-20T23:59:59.500Z');
    const h = new History({ dir, replica: 'r1', flushMs: 60_000, now: () => t });
    await h.init();
    h.record(hEntry(t, { url: 'https://a.example/1' }));
    h.record(hEntry(t + 1000, { url: 'https://a.example/2' }));
    assert.deepEqual(fs.readdirSync(dir), [], 'queued, not yet written');
    await h.flush();
    assert.deepEqual(fs.readdirSync(dir).sort(), ['crawl-2026-10-20.r1.jsonl', 'crawl-2026-10-21.r1.jsonl']);
    const other = new History({ dir, replica: 'r/2', now: () => t });
    other.record(hEntry(t + 2000, { url: 'https://b.example/' }));
    await other.flush();
    assert.ok(fs.existsSync(path.join(dir, 'crawl-2026-10-21.r_2.jsonl')), 'replica name is made file-safe');
    const lines = fs.readFileSync(path.join(dir, 'crawl-2026-10-21.r1.jsonl'), 'utf8').split('\n');
    assert.equal(lines.length, 2);
    assert.equal(JSON.parse(lines[0]).url, 'https://a.example/2');
    assert.equal(h.stats().written, 2);
    // Both replicas' files are read by a query from either.
    const r = await h.query({ days: 3 });
    assert.deepEqual(r.entries.map((e) => e.url), ['https://b.example/', 'https://a.example/2', 'https://a.example/1']);
    fs.rmSync(dir, { recursive: true });
});

await check('History: a write that fails is counted and reported, and later writes still land', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-history-'));
    const t = Date.parse('2026-10-21T10:00:00Z');
    const h = new History({ dir, replica: 'x', now: () => t });
    await h.init();
    fs.mkdirSync(path.join(dir, 'crawl-2026-10-21.x.jsonl')); // appendFile on a directory fails
    const errors = [];
    const orig = console.error;
    console.error = (m) => errors.push(m);
    try {
        h.record(hEntry(t));
        await h.flush();
    } finally {
        console.error = orig;
    }
    assert.equal(h.stats().writeErrors, 1);
    assert.equal(errors.length, 1);
    fs.rmdirSync(path.join(dir, 'crawl-2026-10-21.x.jsonl'));
    h.record(hEntry(t));
    await h.flush();
    assert.equal(h.stats().written, 1);
    fs.rmSync(dir, { recursive: true });
});

await check('History: sweep keeps the last retentionDays days (today included) of every replica and nothing else', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-history-'));
    for (const name of ['crawl-2026-10-13.a.jsonl', 'crawl-2026-10-14.b.jsonl', 'crawl-2026-10-15.b.jsonl', 'crawl-2026-10-21.a.jsonl', 'notes.txt']) fs.writeFileSync(path.join(dir, name), '');
    const h = new History({ dir, retentionDays: 7, now: () => Date.parse('2026-10-21T08:00:00Z') });
    assert.equal(await h.sweep(), 2);
    assert.deepEqual(fs.readdirSync(dir).sort(), ['crawl-2026-10-15.b.jsonl', 'crawl-2026-10-21.a.jsonl', 'notes.txt'], '10-15 .. 10-21 is seven days');
    const keepAll = new History({ dir, retentionDays: 0, now: () => Date.parse('2030-01-01T00:00:00Z') });
    assert.equal(await keepAll.sweep(), 0);
    fs.rmSync(dir, { recursive: true });
});

await check('History: query filters (url substring, status, code incl. ok, session_id, since/until), newest first, limit, days', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-history-'));
    const now = Date.parse('2026-10-21T12:00:00Z');
    const h = new History({ dir, replica: 'q', now: () => now });
    await h.init();
    h.record(hEntry(now - 5 * DAY, { url: 'https://old.example/' }));
    h.record(hEntry(now - DAY, { url: 'https://shop.example/a', session_id: 's1' }));
    h.record(hEntry(now - 3000, { url: 'https://shop.example/b', status: 504, code: 'timeout' }));
    h.record(hEntry(now - 2000, { url: 'https://x.example/', finalUrl: 'https://shop.example/landing', session_id: 's1' }));
    h.record(hEntry(now - 1000, { url: 'https://y.example/', status: 502, code: 'navigation_failed' }));
    await h.flush();
    fs.appendFileSync(path.join(dir, 'crawl-2026-10-21.q.jsonl'), '{"half a line'); // read while being written
    const urls = async (f) => (await h.query(f)).entries.map((e) => e.url);
    assert.deepEqual(await urls({}), ['https://y.example/', 'https://x.example/', 'https://shop.example/b', 'https://shop.example/a'], 'default: last 3 days, newest first');
    assert.deepEqual(await urls({ days: 10 }), ['https://y.example/', 'https://x.example/', 'https://shop.example/b', 'https://shop.example/a', 'https://old.example/']);
    assert.deepEqual(await urls({ url: 'SHOP.example' }), ['https://x.example/', 'https://shop.example/b', 'https://shop.example/a'], 'url matches url or finalUrl, case-insensitively');
    assert.deepEqual(await urls({ status: [502, 504] }), ['https://y.example/', 'https://shop.example/b']);
    assert.deepEqual(await urls({ code: ['ok'] }), ['https://x.example/', 'https://shop.example/a']);
    assert.deepEqual(await urls({ code: ['timeout'] }), ['https://shop.example/b']);
    assert.deepEqual(await urls({ session_id: 's1' }), ['https://x.example/', 'https://shop.example/a']);
    assert.deepEqual(await urls({ since: now - 2500 }), ['https://y.example/', 'https://x.example/']);
    assert.deepEqual(await urls({ since: now - 10 * DAY, until: now - 2 * DAY }), ['https://old.example/']);
    assert.deepEqual(await urls({ limit: 2 }), ['https://y.example/', 'https://x.example/']);
    const r = await h.query({});
    assert.equal(r.scanned.unreadable, 1);
    fs.rmSync(dir, { recursive: true });
});

await check('History: limit keeps the newest matches of a file longer than the limit', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-history-'));
    const now = Date.parse('2026-10-21T12:00:00Z');
    const h = new History({ dir, replica: 'l', now: () => now });
    for (let i = 0; i < 25; i++) h.record(hEntry(now - 25_000 + i * 1000, { url: `https://a.example/${i}` }));
    await h.flush();
    assert.deepEqual((await h.query({ limit: 3 })).entries.map((e) => e.url), ['https://a.example/24', 'https://a.example/23', 'https://a.example/22']);
    fs.rmSync(dir, { recursive: true });
});

await check('History: disabled without a directory', async () => {
    const h = new History({});
    h.record(hEntry(Date.now()));
    assert.equal(h.enabled, false);
    assert.equal(h.stats().queued, 0);
    assert.equal(await h.sweep(), 0);
});

await check('History: kind filter (lines without kind are crawls) and session_id matches mcp_session', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-history-'));
    const now = Date.parse('2026-10-21T12:00:00Z');
    const h = new History({ dir, replica: 'k', now: () => now });
    h.record(hEntry(now - 3000, { url: 'https://old-line.example/' }));
    h.record(hEntry(now - 2000, { url: 'https://crawl.example/', kind: 'crawl' }));
    h.record(hEntry(now - 1000, { url: 'https://agent.example/', kind: 'mcp', tool: 'goto', mcp_session: 'mcp-abc' }));
    await h.flush();
    const urls = async (f) => (await h.query(f)).entries.map((e) => e.url);
    assert.deepEqual(await urls({ kind: 'mcp' }), ['https://agent.example/']);
    assert.deepEqual(await urls({ kind: 'crawl' }), ['https://crawl.example/', 'https://old-line.example/']);
    assert.deepEqual(await urls({ session_id: 'mcp-abc' }), ['https://agent.example/']);
    fs.rmSync(dir, { recursive: true });
});

// A stand-in for `lightpanda mcp --port`: sessions by Mcp-Session-Id, a page
// URL per session, and the tools the gateway treats specially.
function fakeEngine() {
    const sessions = new Map();
    const seen = [];
    const server = http.createServer((req, res) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => {
            const sid = req.headers['mcp-session-id'] || 'default';
            seen.push({ method: req.method, sid, host: req.headers.host, origin: req.headers.origin ?? null, body: Buffer.concat(chunks).toString() });
            if (req.method === 'DELETE') {
                sessions.delete(sid);
                res.writeHead(202);
                return res.end();
            }
            const msg = JSON.parse(Buffer.concat(chunks).toString());
            if (!sessions.has(sid)) sessions.set(sid, { url: null });
            const s = sessions.get(sid);
            const ok = (result) => {
                res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': sid });
                res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
            };
            const text = (t, isError = false) => ok({ content: [{ type: 'text', text: t }], isError });
            if (msg.id === undefined) {
                res.writeHead(202);
                return res.end();
            }
            if (msg.method === 'initialize') return ok({ protocolVersion: '2025-06-18', serverInfo: { name: 'fake' } });
            if (msg.method === 'tools/list') return ok({ tools: ['goto', 'click', 'getUrl', ...HIDDEN_TOOLS].map((name) => ({ name })) });
            const { name, arguments: args = {} } = msg.params;
            if (name === 'goto') {
                s.url = args.url;
                return setTimeout(() => text('Navigated successfully.'), args.delay ?? 0);
            }
            if (name === 'click') {
                if (args.selector === '#missing') return text('no element matches #missing', true);
                s.url = `${s.url}?clicked`;
                return text('Clicked.');
            }
            if (name === 'getUrl') return text(s.url ?? '', !s.url);
            return text(`ran ${name} (should not have been forwarded)`);
        });
    });
    return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, sessions, seen, url: `http://127.0.0.1:${server.address().port}/mcp` })));
}

async function gatewayFixture(opts = {}) {
    const engines = [await fakeEngine(), await fakeEngine()];
    const backends = engines.map((e, i) => new Backend(e.url, { name: `mcp${i}` }));
    const records = [];
    let now = 1_000_000;
    const gw = new McpGateway({ backends, record: (e) => records.push(e), now: () => now, ...opts });
    const front = http.createServer((req, res) => {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => gw.handle(req, res, Buffer.concat(chunks).toString()));
    });
    await new Promise((r) => front.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${front.address().port}/mcp`;
    return {
        engines, backends, gw, records, url,
        advance: (ms) => (now += ms),
        close() {
            front.close();
            for (const e of engines) e.server.close();
            for (const b of backends) b.close();
        },
    };
}

await check('MCP gateway: initialize mints distinct unguessable ids, spread over the engine processes', async () => {
    const f = await gatewayFixture();
    try {
        const a = new McpClient(f.url), b = new McpClient(f.url);
        await a.initialize();
        await b.initialize();
        assert.match(a.sessionId, /^mcp-[0-9a-f]{24}$/);
        assert.notEqual(a.sessionId, b.sessionId);
        assert.ok(f.engines[0].sessions.has(a.sessionId) !== f.engines[1].sessions.has(a.sessionId));
        assert.notEqual(f.gw.sessions.get(a.sessionId).backend, f.gw.sessions.get(b.sessionId).backend, 'two sessions, two processes');
        // The engine sees an IP Host and no Origin (it refuses anything else).
        const seen = f.engines.flatMap((e) => e.seen);
        assert.ok(seen.every((r) => /^127\.0\.0\.1:\d+$/.test(r.host) && r.origin === null));
        assert.deepEqual(f.records.map((r) => r.tool), ['session_start', 'session_start']);
    } finally {
        f.close();
    }
});

await check('MCP gateway: no session header -> 400, unknown session -> 404, never the engine default session', async () => {
    const f = await gatewayFixture();
    try {
        const anon = new McpClient(f.url);
        await assert.rejects(anon.request('tools/list'), /HTTP 400/);
        const stale = new McpClient(f.url, { sessionId: 'mcp-doesnotexist' });
        await assert.rejects(stale.tool('goto', { url: 'http://x/' }), /HTTP 404/);
        assert.equal(f.engines.flatMap((e) => e.seen).length, 0);
    } finally {
        f.close();
    }
});

await check('MCP gateway: session tools and save are hidden from tools/list and refused', async () => {
    const f = await gatewayFixture();
    try {
        const c = new McpClient(f.url);
        await c.initialize();
        const names = (await c.request('tools/list')).tools.map((t) => t.name);
        assert.deepEqual(names, ['goto', 'click', 'getUrl']);
        for (const t of HIDDEN_TOOLS) await assert.rejects(c.tool(t, { id: 'default' }), /not available on this server/);
        assert.ok(!f.engines.flatMap((e) => e.seen).some((r) => r.body.includes('session_list')));
    } finally {
        f.close();
    }
});

await check('MCP gateway: tool calls go to the history with url, final url, result and session', async () => {
    const f = await gatewayFixture();
    try {
        const c = new McpClient(f.url);
        await c.initialize();
        assert.equal(await c.tool('goto', { url: 'http://site.example/list/1' }), 'Navigated successfully.');
        await c.tool('click', { selector: 'a.next' });
        await assert.rejects(c.tool('click', { selector: '#missing' }), /no element matches/);
        await new Promise((r) => setTimeout(r, 50)); // the getUrl after a navigating tool
        const calls = f.records.filter((r) => r.tool !== 'session_start');
        assert.deepEqual(calls.map((r) => [r.tool, r.code, r.url, r.finalUrl]), [
            ['goto', null, 'http://site.example/list/1', 'http://site.example/list/1'],
            ['click', null, 'http://site.example/list/1', 'http://site.example/list/1?clicked'],
            ['click', 'tool_error', 'http://site.example/list/1?clicked', 'http://site.example/list/1?clicked'],
        ]);
        assert.ok(calls.every((r) => r.kind === 'mcp' && r.mcp_session === c.sessionId && r.status === 200 && typeof r.ms === 'number'));
        assert.deepEqual(calls[1].args, { selector: 'a.next' });
        assert.equal(calls[2].message, 'no element matches #missing');
        assert.deepEqual(f.gw.list().map((s) => [s.id, s.calls, s.url]), [[c.sessionId, 3, 'http://site.example/list/1?clicked']]);
    } finally {
        f.close();
    }
});

await check('MCP gateway: DELETE closes the engine session; idle sessions are swept; a dead engine loses its sessions', async () => {
    const f = await gatewayFixture({ idleMs: 60_000 });
    try {
        const a = new McpClient(f.url), b = new McpClient(f.url), c = new McpClient(f.url);
        await a.initialize();
        await b.initialize();
        await c.initialize();
        assert.equal(await a.close(), 204);
        assert.ok(!f.engines.some((e) => e.sessions.has(a.sessionId)), 'engine session closed');
        await assert.rejects(a.tool('goto', { url: 'http://x/' }), /HTTP 404/);

        f.advance(30_000);
        await c.tool('goto', { url: 'http://x/' });
        f.advance(40_000);
        assert.equal(await f.gw.sweep(), 1, 'b idle 70 s, c only 40 s');
        await assert.rejects(b.tool('goto', { url: 'http://x/' }), /HTTP 404/);
        assert.ok(!f.engines.some((e) => e.sessions.has(b.sessionId)));

        f.gw.backendRestarted(f.gw.sessions.get(c.sessionId).backend);
        await assert.rejects(c.tool('goto', { url: 'http://x/' }), /HTTP 404/);
        assert.deepEqual(f.records.filter((r) => r.tool.startsWith('session_')).map((r) => [r.tool, r.code]), [
            ['session_start', null], ['session_start', null], ['session_start', null],
            ['session_end', null], ['session_end', null], ['session_lost', 'engine_restarted'],
        ]);
    } finally {
        f.close();
    }
});

await check('MCP gateway: initialize moves on from a dead process; MCP_MAX_SESSIONS is enforced', async () => {
    const f = await gatewayFixture({ maxSessions: 2 });
    try {
        f.engines[0].server.close(); // refuses connections, but still marked up
        f.engines[0].server.closeAllConnections();
        const a = new McpClient(f.url), b = new McpClient(f.url), c = new McpClient(f.url);
        await a.initialize();
        assert.equal(f.gw.sessions.get(a.sessionId).backend.name, 'mcp1');
        await b.initialize();
        await assert.rejects(c.initialize(), /HTTP 503.*MCP_MAX_SESSIONS/);
    } finally {
        f.close();
    }
});

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
