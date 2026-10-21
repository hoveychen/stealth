// Unit checks for the proxy pool and the session cookie merge; no engine.
//
//   node service/test/unit.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { normalizeProxyUrl, parseProxyList, ProxyPool, redact } from '../lib/proxies.mjs';
import { SessionStore } from '../lib/sessions.mjs';

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

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
