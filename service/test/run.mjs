// End-to-end test: local fixture pages + a real `lightpanda serve` + this
// service, all on free local ports. Exits non-zero if any check fails.
//
//   LP_BIN=/path/to/lightpanda node service/test/run.mjs
//
// Use a ReleaseFast build; the Debug one in zig-out is ~3.5x slower.
//
// Against a service that is already running (e.g. the container), the test
// starts only the fixture pages, on an address the service can reach:
//
//   LP_SERVICE_URL=http://127.0.0.1:8080 \
//   FIXTURE_HOST=0.0.0.0 FIXTURE_URL_HOST=172.17.0.1 \
//   LP_ENGINE_KILL="docker exec lp-crawl sh -c 'kill -9 \$(cat /tmp/lightpanda.pid)'" \
//   node service/test/run.mjs
//
// LP_ENGINE_KILL kills the engine; the container's entrypoint restarts it
// after LP_RESTART_DELAY seconds, which must be at least 4 so the "engine
// down" check sees it down. LP_SERVICE_RESTART restarts the service (the
// session check needs cookies to survive it).
//
// The proxy checks start their proxies on TEST_PROXY_HOST, ports
// TEST_PROXY_BASE .. TEST_PROXY_BASE+5, and expect the service's pool to be
// exactly the first three, with PROXY_MAX_FAILS=2 and PROXY_RETRY_AFTER_MS=5000:
//
//   PROXY_POOL=http://H:B,http://pool:secret@H:B+1,http://H:B+2
//
// B+2 is left closed, so it is the pool's dead proxy. service/test/docker-test.sh
// sets all of this up against a container.

import { exec, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import net from 'node:net';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { startFixtureServer } from './fixture-server.mjs';
import { startHttpProxy, startSocksProxy } from './proxy-server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const EXTERNAL = process.env.LP_SERVICE_URL;
const LP_BIN = process.env.LP_BIN || path.resolve(here, '../../zig-out/bin/lightpanda');
if (EXTERNAL) {
    for (const v of ['LP_ENGINE_KILL', 'LP_SERVICE_RESTART', 'TEST_PROXY_BASE']) {
        if (!process.env[v]) {
            console.error(`LP_SERVICE_URL needs ${v} (see the header of this file)`);
            process.exit(2);
        }
    }
} else if (!fs.existsSync(LP_BIN)) {
    console.error(`engine binary not found: ${LP_BIN} (set LP_BIN)`);
    process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () =>
    new Promise((resolve) => {
        const s = net.createServer().listen(0, '127.0.0.1', () => {
            const { port } = s.address();
            s.close(() => resolve(port));
        });
    });

let failures = 0;
function check(name, ok, detail = '') {
    if (!ok) failures++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  -- ${detail}` : ''}`);
}

const children = [];
function cleanup() {
    for (const c of children) if (c.exitCode === null) c.kill('SIGKILL');
}
process.on('exit', cleanup);

const lpPort = await freePort();
let engine;
function startEngine() {
    if (EXTERNAL) return; // the container restarts its own engine
    engine = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(lpPort), '--log-level', 'fatal'], { stdio: 'ignore' });
    children.push(engine);
}
async function waitHttp(url, tries = 100) {
    for (let i = 0; i < tries; i++) {
        try {
            await fetch(url);
            return;
        } catch {
            await sleep(100);
        }
    }
    throw new Error(`${url} never came up`);
}

async function killEngine() {
    if (EXTERNAL) await promisify(exec)(process.env.LP_ENGINE_KILL);
    else engine.kill('SIGKILL');
}

const fixture = await startFixtureServer(process.env.FIXTURE_HOST, process.env.FIXTURE_URL_HOST);

// Proxies. PH is both where they listen and how the service reaches them.
const PH = process.env.TEST_PROXY_HOST || process.env.FIXTURE_URL_HOST || '127.0.0.1';
const PB = Number(process.env.TEST_PROXY_BASE || 0);
const proxyPort = async (i) => (PB ? PB + i : freePort());
const PROXY_PASS = 'secret';
const px = {
    poolA: await startHttpProxy({ host: PH, port: await proxyPort(0) }),
    poolB: await startHttpProxy({ host: PH, port: await proxyPort(1), auth: 'pool:secret' }),
    deadPort: await proxyPort(2), // nothing listens here
    plain: await startHttpProxy({ host: PH, port: await proxyPort(3) }),
    auth: await startHttpProxy({ host: PH, port: await proxyPort(4), auth: `user:${PROXY_PASS}` }),
    socks: await startSocksProxy({ host: PH, port: await proxyPort(5), auth: `user:${PROXY_PASS}` }),
};
const proxyLogs = () => Object.values(px).flatMap((p) => p.log ?? []);
const POOL = [`http://${PH}:${px.poolA.port}`, `http://pool:secret@${PH}:${px.poolB.port}`, `http://${PH}:${px.deadPort}`];

let SVC, POOL_SIZE, restartService;
if (EXTERNAL) {
    SVC = EXTERNAL.replace(/\/$/, '');
    await waitHttp(`${SVC}/health`);
    POOL_SIZE = (await (await fetch(`${SVC}/health`)).json()).pool.size;
    console.log(`      external service ${SVC}, pool size ${POOL_SIZE}, fixtures at ${fixture.base}, proxies on ${PH}:${PB}..${PB + 5}`);
    restartService = async () => {
        await promisify(exec)(process.env.LP_SERVICE_RESTART);
        await waitHttp(`${SVC}/health`, 300);
    };
} else {
    POOL_SIZE = 3;
    startEngine();
    await waitHttp(`http://127.0.0.1:${lpPort}/json/version`);
    const svcPort = await freePort();
    const sessionDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-crawl-sessions-'));
    let svc;
    const startService = () => {
        svc = spawn(process.execPath, [path.resolve(here, '../server.mjs')], {
            env: {
                ...process.env,
                PORT: String(svcPort),
                HOST: '127.0.0.1',
                LP_CDP_URL: `ws://127.0.0.1:${lpPort}/`,
                POOL_SIZE: String(POOL_SIZE),
                PROXY_POOL: POOL.join(','),
                PROXY_MAX_FAILS: '2',
                PROXY_RETRY_AFTER_MS: '5000',
                SESSION_DIR: sessionDir,
            },
            stdio: ['ignore', 'ignore', 'inherit'],
        });
        children.push(svc);
    };
    startService();
    SVC = `http://127.0.0.1:${svcPort}`;
    await waitHttp(`${SVC}/health`);
    restartService = async () => {
        svc.kill('SIGKILL');
        await new Promise((r) => svc.once('exit', r));
        startService();
        await waitHttp(`${SVC}/health`);
    };
}
const health = async () => (await fetch(`${SVC}/health`)).json();

async function crawl(body) {
    const t0 = Date.now();
    const r = await fetch(`${SVC}/crawl`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    return { status: r.status, body: await r.json(), ms: Date.now() - t0 };
}
const F = fixture.base;

// 1. All four outputs on a page whose content is partly written by script.
{
    const js = `(async () => { await new Promise(r => setTimeout(r, 50)); return { title: document.title, items: document.querySelectorAll('li').length, answer: window.answer }; })()`;
    const { status, body } = await crawl({ url: `${F}/index.html`, formats: ['html', 'markdown', 'eval', 'meta'], js });
    check('index: 200', status === 200, `status ${status} ${body.error?.message ?? ''}`);
    check('html: contains static and script-rendered content', body.html?.includes('<h1>Fixture Home</h1>') && body.html?.includes('<p id="dyn">rendered by script</p>'));
    check('markdown: non-empty with heading', /^# Fixture Home$/m.test(body.markdown ?? ''), JSON.stringify(body.markdown?.slice(0, 80)));
    check('eval: async value returned', JSON.stringify(body.eval) === JSON.stringify({ value: { title: 'Fixture Home', items: 3, answer: 42 } }), JSON.stringify(body.eval));
    check('meta: status/url/header/cookie', body.meta?.status === 200 && body.meta?.url === `${F}/index.html` && body.meta?.headers?.['x-fixture'] === 'index' && body.meta?.cookies?.some((c) => c.name === 'fixture_session' && c.value === 'abc123'), JSON.stringify({ status: body.meta?.status, url: body.meta?.url, timing: body.meta?.timing }));
}

// 2. Redirect: final URL and status are the target's, the hop is listed.
{
    const { status, body } = await crawl({ url: `${F}/redirect`, formats: ['meta', 'markdown'] });
    check('redirect: final url + status 200 + hop recorded', status === 200 && body.meta?.url === `${F}/index.html` && body.meta?.status === 200 && body.meta?.redirects?.[0] === `${F}/redirect`, JSON.stringify({ url: body.meta?.url, status: body.meta?.status, redirects: body.meta?.redirects }));
}

// 3. 404 is a successful crawl of a page whose status is 404.
{
    const { status, body } = await crawl({ url: `${F}/missing`, formats: ['meta', 'markdown'] });
    check('404: crawl ok, meta.status 404, page rendered', status === 200 && body.meta?.status === 404 && body.meta?.url === `${F}/missing` && body.markdown?.includes('# Not Found'), JSON.stringify({ status: body.meta?.status, md: body.markdown?.slice(0, 40) }));
}

// 4. A script that throws is reported, not fatal.
{
    const { status, body } = await crawl({ url: `${F}/index.html`, js: 'null.x' });
    check('eval error: reported in eval.error', status === 200 && /TypeError/.test(body.eval?.error ?? ''), JSON.stringify(body.eval));
}

// 5. Bad input.
{
    const a = await crawl({ url: 'ftp://x' });
    const b = await crawl({ url: `${F}/index.html`, formats: ['pdf'] });
    check('bad request: 400', a.status === 400 && b.status === 400 && a.body.error.code === 'bad_request', `${a.status} ${b.status}`);
}

// 6. A page that never answers times out with 504, and the slot recovers.
{
    const { status, body, ms } = await crawl({ url: `${F}/hang`, timeout: 1500 });
    check('timeout: 504 near the deadline', status === 504 && body.error?.code === 'timeout' && ms < 3000, `${status} ${ms}ms ${body.error?.message}`);
    const after = await Promise.all(Array.from({ length: POOL_SIZE }, () => crawl({ url: `${F}/index.html`, formats: ['meta'] })));
    check('timeout: every slot serves again afterwards', after.every((r) => r.status === 200), after.map((r) => r.status).join(','));
}

// 7. Unreachable host fails with a navigation error, not a hang.
{
    const dead = await freePort();
    const { status, body, ms } = await crawl({ url: `http://127.0.0.1:${dead}/`, timeout: 10000 });
    check('unreachable: 502 navigation_failed', status === 502 && body.error?.code === 'navigation_failed', `${status} ${ms}ms ${body.error?.message}`);
}

// 8. More requests than slots: they queue and all succeed, each with its own page.
{
    const N = 12;
    fixture.stats.maxInflight = 0;
    const t0 = Date.now();
    const res = await Promise.all(Array.from({ length: N }, (_, i) => crawl({ url: `${F}/delay?ms=400&i=${i}`, formats: ['meta', 'markdown'] })));
    const wall = Date.now() - t0;
    const own = res.every((r, i) => r.status === 200 && r.body.meta.title === `delay ${i}` && r.body.markdown.includes(`Delay page ${i}`));
    const queued = res.filter((r) => r.body.meta?.timing.queueMs > 100).length;
    check(`concurrency: ${N} requests on ${POOL_SIZE} slots all 200 with their own page`, own, res.map((r) => r.status).join(','));
    check('concurrency: never more than POOL_SIZE pages in flight', fixture.stats.maxInflight <= POOL_SIZE && fixture.stats.maxInflight > 1, `max in flight ${fixture.stats.maxInflight}`);
    check('concurrency: later requests waited in the queue', queued >= N - POOL_SIZE - 1, `${queued} queued >100ms, wall ${wall}ms, queueMs=[${res.map((r) => r.body.meta?.timing.queueMs).join(',')}]`);
}

// 10. Per-request proxy: traffic goes through it, and only when asked.
{
    check('proxy: none of the crawls above went through any proxy', proxyLogs().length === 0, JSON.stringify(proxyLogs().slice(0, 3)));
    const viaUrl = `${F}/index.html?via=plain`;
    const a = await crawl({ url: viaUrl, formats: ['meta'], proxy: `http://${PH}:${px.plain.port}` });
    check('proxy: request with proxy succeeds and is in the proxy log', a.status === 200 && a.body.meta?.status === 200 && px.plain.log.some((l) => l.target === viaUrl), `${a.status} ${a.body.error?.message ?? ''} log=${JSON.stringify(px.plain.log.map((l) => l.target))}`);
    const before = proxyLogs().length;
    const b = await crawl({ url: `${F}/index.html?via=none`, formats: ['meta'] });
    const c = await crawl({ url: `${F}/index.html?via=direct`, formats: ['meta'], proxy: 'direct' });
    check('proxy: requests without proxy (omitted / "direct") leave no proxy log entry', b.status === 200 && c.status === 200 && proxyLogs().length === before, `${b.status} ${c.status} new entries ${proxyLogs().length - before}`);
}

// 11. Proxy credentials, in the URL.
{
    const ok = await crawl({ url: `${F}/index.html?via=auth`, formats: ['meta'], proxy: `http://user:${PROXY_PASS}@${PH}:${px.auth.port}` });
    check('proxy auth: right password, 200 and the proxy saw valid credentials', ok.status === 200 && px.auth.log.some((l) => l.target === `${F}/index.html?via=auth` && l.auth === 'ok'), `${ok.status} ${ok.body.error?.message ?? ''}`);
    const bad = await crawl({ url: `${F}/index.html?via=badauth`, formats: ['meta'], proxy: `http://user:wrong@${PH}:${px.auth.port}` });
    check('proxy auth: wrong password (http URL) -> 502 proxy_auth_failed, password not echoed', bad.status === 502 && bad.body.error?.code === 'proxy_auth_failed' && !JSON.stringify(bad.body).includes('wrong'), `${bad.status} ${JSON.stringify(bad.body.error)}`);
    // An https URL goes through CONNECT, which the proxy refuses before any TLS.
    const badTls = await crawl({ url: `${F.replace('http:', 'https:')}/index.html`, formats: ['meta'], proxy: `http://user:wrong@${PH}:${px.auth.port}` });
    check('proxy auth: wrong password (https URL, CONNECT) -> 502 proxy_auth_failed', badTls.status === 502 && badTls.body.error?.code === 'proxy_auth_failed', `${badTls.status} ${JSON.stringify(badTls.body.error)}`);
    const socks = await crawl({ url: `${F}/index.html?via=socks`, formats: ['meta'], proxy: `socks5://user:${PROXY_PASS}@${PH}:${px.socks.port}` });
    check('proxy socks5: with credentials, 200 and in the socks log', socks.status === 200 && px.socks.log.some((l) => l.auth === 'ok' && l.target), `${socks.status} ${socks.body.error?.message ?? ''} ${JSON.stringify(px.socks.log)}`);
    const socksBad = await crawl({ url: `${F}/index.html`, formats: ['meta'], proxy: `socks5://user:wrong@${PH}:${px.socks.port}` });
    check('proxy socks5: wrong password -> 502 proxy_auth_failed', socksBad.status === 502 && socksBad.body.error?.code === 'proxy_auth_failed', `${socksBad.status} ${JSON.stringify(socksBad.body.error)}`);
    const bogus = await crawl({ url: `${F}/index.html`, proxy: 'ftp://x:1' });
    check('proxy: unsupported scheme -> 400', bogus.status === 400, `${bogus.status} ${bogus.body.error?.message}`);
}

// 12. Proxy pool: round robin over all three, the dead one ejected after two
// failures, then offered again after PROXY_RETRY_AFTER_MS.
{
    const h0 = await health();
    const names = h0.proxies?.proxies.map((p) => p.proxy) ?? [];
    check('pool: /health lists the 3 configured proxies, password redacted', names.length === 3 && h0.proxies.active === 3 && names.some((n) => n.includes('pool:***@')) && !JSON.stringify(h0).includes('secret'), JSON.stringify(names));
    const a0 = px.poolA.log.length, b0 = px.poolB.log.length;
    const first = [];
    for (let i = 0; i < 6; i++) first.push(await crawl({ url: `${F}/index.html?pool=${i}`, formats: ['meta'], proxy: 'pool' }));
    const failed = first.filter((r) => r.status === 502 && r.body.error?.code === 'proxy_failed');
    check('pool: 6 requests reach every proxy (A and B serve, the dead one fails twice)', px.poolA.log.length - a0 >= 2 && px.poolB.log.length - b0 >= 2 && failed.length === 2 && first.filter((r) => r.status === 200).length === 4, `codes ${first.map((r) => r.body.error?.code ?? r.status).join(',')} A+${px.poolA.log.length - a0} B+${px.poolB.log.length - b0}`);
    check('pool: proxy B was sent its credentials', px.poolB.log.slice(b0).every((l) => l.auth === 'ok'), JSON.stringify(px.poolB.log.slice(b0).map((l) => l.auth)));
    const h1 = await health();
    const dead = h1.proxies.proxies.find((p) => p.proxy.endsWith(`:${px.deadPort}`));
    check('pool: dead proxy shows as ejected in /health', h1.proxies.active === 2 && dead?.state === 'ejected' && dead.consecutiveFails === 2 && /proxy_failed|CouldntConnect/.test(dead.lastError ?? ''), JSON.stringify(dead));
    const next = [];
    for (let i = 0; i < 4; i++) next.push(await crawl({ url: `${F}/index.html?pool=after${i}`, formats: ['meta'], proxy: 'pool' }));
    check('pool: while ejected, every request succeeds on the other two', next.every((r) => r.status === 200), next.map((r) => r.status).join(','));
    await sleep(5200);
    const h2 = await health();
    check('pool: dead proxy offered again after the retry period', h2.proxies.proxies.find((p) => p.proxy.endsWith(`:${px.deadPort}`))?.state === 'active', JSON.stringify(h2.proxies.proxies.map((p) => p.state)));
    const again = [];
    for (let i = 0; i < 3; i++) again.push(await crawl({ url: `${F}/index.html?pool=again${i}`, formats: ['meta'], proxy: 'pool' }));
    const h3 = await health();
    check('pool: one more failure ejects it again straight away', again.filter((r) => r.body.error?.code === 'proxy_failed').length === 1 && h3.proxies.proxies.find((p) => p.proxy.endsWith(`:${px.deadPort}`))?.state === 'ejected', again.map((r) => r.body.error?.code ?? r.status).join(','));
}

// 13. Sessions: cookies carry over between requests with the same session_id,
// concurrent requests merge per cookie, and the jar survives a restart.
{
    const sid = `t${Date.now()}`;
    const titleOf = async (body) => (await crawl({ url: `${F}/echo-cookies`, formats: ['meta'], ...body })).body.meta?.title ?? '(failed)';
    const set = await crawl({ url: `${F}/set-cookie?a=1`, formats: ['meta'], session_id: sid });
    const seen = await titleOf({ session_id: sid });
    const other = await titleOf({});
    check('session: cookie set in one request is sent by the next', set.status === 200 && seen === 'a=1' && other === '', `set ${set.status}, same session sends "${seen}", no session sends "${other}"`);
    // Both start from {a}; each adds its own cookie while the other is still open.
    const hold = 'new Promise((r) => setTimeout(r, 600))';
    const [x, y] = await Promise.all([
        crawl({ url: `${F}/set-cookie?b=2`, formats: ['meta'], js: hold, session_id: sid }),
        crawl({ url: `${F}/set-cookie?c=3&a=9`, formats: ['meta'], js: hold, session_id: sid }),
    ]);
    const merged = (await titleOf({ session_id: sid })).split('; ').sort().join('; ');
    check('session: two concurrent requests both keep their cookies', x.status === 200 && y.status === 200 && merged === 'a=9; b=2; c=3', `"${merged}"`);
    await crawl({ url: `${F}/set-cookie?del=b`, formats: ['meta'], session_id: sid });
    const afterDel = (await titleOf({ session_id: sid })).split('; ').sort().join('; ');
    check('session: a cookie the site deletes is gone next time', afterDel === 'a=9; c=3', `"${afterDel}"`);
    const t0 = Date.now();
    await restartService();
    const afterRestart = (await titleOf({ session_id: sid })).split('; ').sort().join('; ');
    check('session: cookies survive a service restart', afterRestart === 'a=9; c=3', `"${afterRestart}" (restart took ${Date.now() - t0}ms)`);
    const bad = await crawl({ url: `${F}/index.html`, session_id: '../etc/passwd' });
    check('session: unsafe session_id -> 400', bad.status === 400, `${bad.status}`);
}

// 14. Timeouts hand back what the page had. A page whose load event never
// comes (an async script that never arrives) has its html and markdown; a
// document whose body never finishes has nothing yet (the engine keeps the
// old about:blank until the body is in); a page that never answers likewise.
const GRACE = 2000;
{
    const { status, body, ms } = await crawl({ url: `${F}/slow-load`, formats: ['html', 'markdown', 'meta'], timeout: 1500 });
    check('partial: load never fires -> 504 with partial html and markdown', status === 504 && body.error?.code === 'timeout' && body.partial?.html?.includes('<h1>Loaded body</h1>') && /^# Loaded body$/m.test(body.partial?.markdown ?? ''), `${status} ${ms}ms partial=${JSON.stringify(body.partial)?.slice(0, 200)}`);
    check('partial: answered within timeout + grace', ms < 1500 + GRACE + 1000, `${ms}ms`);
    const stall = await crawl({ url: `${F}/stall`, formats: ['html', 'markdown'], timeout: 1500 });
    check('partial: body never finishes -> 504 with partial keys, within timeout + grace', stall.status === 504 && 'html' in (stall.body.partial ?? {}) && 'markdown' in stall.body.partial && stall.ms < 1500 + GRACE + 1000, `${stall.status} ${stall.ms}ms partial=${JSON.stringify(stall.body.partial)?.slice(0, 120)}`);
    const hang = await crawl({ url: `${F}/hang`, formats: ['html', 'eval'], js: '1', timeout: 1500 });
    check('partial: page that never answers -> 504 with partial.html present, no markdown key', hang.status === 504 && 'html' in (hang.body.partial ?? {}) && !('markdown' in hang.body.partial) && hang.ms < 1500 + GRACE + 1000, `${hang.status} ${hang.ms}ms partial=${JSON.stringify(hang.body.partial)?.slice(0, 120)}`);
    const meta = await crawl({ url: `${F}/hang`, formats: ['meta'], timeout: 1000 });
    check('partial: no partial key when neither html nor markdown was asked for', meta.status === 504 && !('partial' in meta.body), JSON.stringify(meta.body));
}

// 9. Engine killed mid-request, stays down, then comes back.
{
    const inflight = crawl({ url: `${F}/delay?ms=3000&i=k`, timeout: 20000 });
    await sleep(500);
    await killEngine();
    const killed = await inflight;
    check('engine killed: in-flight request fails fast', killed.status === 502 && killed.body.error?.code === 'engine_disconnected' && killed.ms < 2000, `${killed.status} ${killed.ms}ms ${killed.body.error?.code}`);

    const down = await crawl({ url: `${F}/index.html`, timeout: 2000 });
    check('engine down: 503 engine_unavailable at the deadline', down.status === 503 && down.body.error?.code === 'engine_unavailable', `${down.status} ${down.ms}ms ${down.body.error?.message}`);

    // A request sent while the engine is down rides out the restart.
    const waiting = crawl({ url: `${F}/index.html`, formats: ['meta'], timeout: 15000 });
    await sleep(800);
    startEngine();
    const w = await waiting;
    check('engine restarted: request sent while down succeeds', w.status === 200 && w.body.meta?.status === 200, `${w.status} ${w.ms}ms`);
    const after = await Promise.all(Array.from({ length: POOL_SIZE * 2 }, (_, i) => crawl({ url: `${F}/delay?ms=100&i=${i}`, formats: ['meta'] })));
    check('engine restarted: all slots reconnect', after.every((r) => r.status === 200), after.map((r) => r.status).join(','));
    const health = await (await fetch(`${SVC}/health`)).json();
    console.log(`      health after restart: ${JSON.stringify(health.pool)}`);
}

// 15. A page stuck in script: the engine may not answer CDP at all, so the
// partial snapshot can come back empty, but the request still ends at
// timeout + grace and the pool serves again afterwards.
for (const [name, page] of [['after load', 'spin'], ['while parsing', 'spin-sync']]) {
    const { status, body, ms } = await crawl({ url: `${F}/${page}`, formats: ['html', 'markdown'], timeout: 2000 });
    check(`spin (${name}): 504 within timeout + grace`, status === 504 && body.error?.code === 'timeout' && ms < 2000 + GRACE + 1500, `${status} ${ms}ms partial=${JSON.stringify(body.partial)?.slice(0, 160)}`);
    const after = await Promise.all(Array.from({ length: POOL_SIZE * 2 }, (_, i) => crawl({ url: `${F}/index.html?after-${page}=${i}`, formats: ['meta'], timeout: 15000 })));
    check(`spin (${name}): every slot serves again afterwards`, after.every((r) => r.status === 200), after.map((r) => `${r.status}/${r.ms}ms`).join(','));
}
{
    const h = await health();
    console.log(`      health at the end: ${JSON.stringify(h.pool)} sessions=${JSON.stringify(h.sessions)}`);
}

fixture.server.closeAllConnections();
fixture.server.close();
for (const p of Object.values(px)) p.server?.close();
cleanup();
console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
