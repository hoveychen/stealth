// Unit checks for the proxy pool, telling a dead proxy from a dead target,
// and the session store (cookie merge, TTL, delete); no engine.
//
//   node service/test/unit.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { diagnoseProxyFailure, normalizeProxyUrl, parseHostPort, parseProxyList, ProxyPool, redact } from '../lib/proxies.mjs';
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

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
