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
//   LP_ENGINE_CMDLINE="docker exec lp-crawl sh -c 'cat /proc/\$(cat /tmp/lightpanda.pid)/cmdline'" \
//   LP_SESSION_FILES="docker exec lp-crawl ls /data/sessions" \
//   LP_HISTORY_SH="docker exec -w /data/history lp-crawl sh -c" \
//   node service/test/run.mjs
//
// LP_ENGINE_KILL kills the engine; the container's entrypoint restarts it
// after LP_RESTART_DELAY seconds, which must be at least 4 so the "engine
// down" check sees it down. LP_SERVICE_RESTART restarts the service (the
// session check needs cookies to survive it). LP_ENGINE_CMDLINE prints the
// engine's command line, LP_SESSION_FILES the names in SESSION_DIR, and
// LP_HISTORY_SH runs a shell snippet (its one argument) in HISTORY_DIR. The
// session checks expect SESSION_TTL_MS=6000 and SESSION_SWEEP_MS=1000; the
// history checks a HISTORY_RETENTION_DAYS of at least 1.
//
// The proxy checks start their proxies on TEST_PROXY_HOST, ports
// TEST_PROXY_BASE .. TEST_PROXY_BASE+5, and expect the service's pool to be
// exactly the first three, with PROXY_MAX_FAILS=2, PROXY_RETRY_AFTER_MS=5000,
// PROXY_POOL_RETRIES=2 and the probe address at B+3:
//
//   PROXY_POOL=http://H:B,http://pool:secret@H:B+1,http://H:B+2 PROXY_PROBE=H:B+3
//
// B+2 is left closed, so it is the pool's dead proxy. service/test/docker-test.sh
// sets all of this up against a container.
//
// The MCP checks expect MCP_PROCS=2 and MCP_PROXY=http://user:secret@H:B+4 (the
// test proxy with credentials); LP_MCP_SH runs a shell snippet where the
// engine processes are (`docker exec NAME sh -c`), to read their command lines
// and kill one. LP_SERVICE_STOP stops the service the way `docker stop` does
// (SIGTERM, then SIGKILL after 10 s) and starts it again on the same data,
// printing `stop_ms=<how long the stop took>` and the service's log lines.

import { exec, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import net from 'node:net';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { startFixtureServer } from './fixture-server.mjs';
import { startHttpProxy, startSocksProxy } from './proxy-server.mjs';
import { expectedIds, startPagingServer } from './paging-server.mjs';
import { McpClient } from './mcp-client.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const EXTERNAL = process.env.LP_SERVICE_URL;
const LP_BIN = process.env.LP_BIN || path.resolve(here, '../../zig-out/bin/lightpanda');
if (EXTERNAL) {
    for (const v of ['LP_ENGINE_KILL', 'LP_SERVICE_RESTART', 'TEST_PROXY_BASE', 'LP_ENGINE_CMDLINE', 'LP_SESSION_FILES', 'LP_HISTORY_SH', 'LP_MCP_SH', 'LP_SERVICE_STOP']) {
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

let SVC, POOL_SIZE, restartService, stopService, sessionFiles, historySh, mcpSh;
const shQuote = (s) => `'${s.replace(/'/g, `'\\''`)}'`;
if (EXTERNAL) {
    SVC = EXTERNAL.replace(/\/$/, '');
    await waitHttp(`${SVC}/health`);
    POOL_SIZE = (await (await fetch(`${SVC}/health`)).json()).pool.size;
    console.log(`      external service ${SVC}, pool size ${POOL_SIZE}, fixtures at ${fixture.base}, proxies on ${PH}:${PB}..${PB + 5}`);
    restartService = async () => {
        await promisify(exec)(process.env.LP_SERVICE_RESTART);
        await waitHttp(`${SVC}/health`, 300);
    };
    // -> { ms, log }: how long the stop took, and what the service logged.
    stopService = async () => {
        const out = (await promisify(exec)(process.env.LP_SERVICE_STOP, { maxBuffer: 64 << 20 })).stdout;
        await waitHttp(`${SVC}/health`, 300);
        return { ms: Number(/stop_ms=(\d+)/.exec(out)?.[1] ?? NaN), log: out };
    };
    sessionFiles = async () => (await promisify(exec)(process.env.LP_SESSION_FILES)).stdout.split('\n').filter(Boolean);
    historySh = async (snippet) => (await promisify(exec)(`${process.env.LP_HISTORY_SH} ${shQuote(snippet)}`)).stdout;
    mcpSh = async (snippet) => (await promisify(exec)(`${process.env.LP_MCP_SH} ${shQuote(snippet)}`)).stdout;
} else {
    mcpSh = async (snippet) => (await promisify(exec)(snippet)).stdout;
    POOL_SIZE = 3;
    startEngine();
    await waitHttp(`http://127.0.0.1:${lpPort}/json/version`);
    const svcPort = await freePort();
    const sessionDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-crawl-sessions-'));
    const historyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-crawl-history-'));
    historySh = async (snippet) => (await promisify(exec)(snippet, { cwd: historyDir })).stdout;
    let svc;
    const mcpBasePort = await freePort(); // and the next one
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
                PROXY_POOL_RETRIES: '2',
                PROXY_PROBE: `${PH}:${px.plain.port}`,
                SESSION_DIR: sessionDir,
                SESSION_TTL_MS: '6000',
                SESSION_SWEEP_MS: '1000',
                HISTORY_DIR: historyDir,
                MCP_PROCS: '2',
                MCP_BASE_PORT: String(mcpBasePort),
                MCP_PROXY: `http://user:${PROXY_PASS}@${PH}:${px.auth.port}`,
                LP_BIN,
            },
            stdio: ['ignore', 'pipe', 'inherit'],
        });
        svc.log = '';
        svc.stdout.on('data', (c) => (svc.log += c));
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
    stopService = async () => {
        const t0 = Date.now();
        svc.kill('SIGTERM');
        const killer = setTimeout(() => svc.kill('SIGKILL'), 10000);
        await new Promise((r) => svc.once('exit', r));
        clearTimeout(killer);
        const ms = Date.now() - t0;
        const log = svc.log;
        startService();
        await waitHttp(`${SVC}/health`);
        return { ms, log };
    };
    sessionFiles = async () => fs.readdirSync(sessionDir);
}
const health = async () => (await fetch(`${SVC}/health`)).json();

async function crawl(body) {
    const t0 = Date.now();
    const r = await fetch(`${SVC}/crawl`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    return { status: r.status, body: await r.json(), ms: Date.now() - t0 };
}
const F = fixture.base;

// 0. The engine runs with a raised shared HTTP connection pool (the image's
// entrypoint passes it; the local run starts the engine itself).
if (EXTERNAL) {
    const cmdline = (await promisify(exec)(process.env.LP_ENGINE_CMDLINE)).stdout.replace(/\0/g, ' ').trim();
    check('engine: started with --http-max-concurrent 255', /(^| )--http-max-concurrent 255( |$)/.test(cmdline), cmdline);
}

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

// 12. Proxy pool: round robin over all three; a request that lands on the
// dead one moves on to the next proxy and still succeeds, and the dead one is
// ejected after two failures, then offered again after PROXY_RETRY_AFTER_MS.
{
    const h0 = await health();
    const names = h0.proxies?.proxies.map((p) => p.proxy) ?? [];
    check('pool: /health lists the 3 configured proxies, password redacted', names.length === 3 && h0.proxies.active === 3 && names.some((n) => n.includes('pool:***@')) && !JSON.stringify(h0).includes('secret'), JSON.stringify(names));
    const deadEntry = (h) => h.proxies.proxies.find((p) => p.proxy.endsWith(`:${px.deadPort}`));
    const a0 = px.poolA.log.length, b0 = px.poolB.log.length;
    const first = [];
    for (let i = 0; i < 6; i++) first.push(await crawl({ url: `${F}/index.html?pool=${i}`, formats: ['meta'], proxy: 'pool' }));
    const h1 = await health();
    const dead = deadEntry(h1);
    check('pool: 6 requests reach every proxy, all 200 (A and B serve, the dead one is tried twice)', px.poolA.log.length - a0 >= 2 && px.poolB.log.length - b0 >= 2 && first.every((r) => r.status === 200) && dead?.uses === 2 && dead.failed === 2, `codes ${first.map((r) => r.body.error?.code ?? r.status).join(',')} A+${px.poolA.log.length - a0} B+${px.poolB.log.length - b0} dead=${JSON.stringify(dead)}`);
    // Round robin from the start: A, B, dead -> retried on A, B, dead -> retried on A.
    const movedOn = [2, 4].every((i) => first[i].status === 200 && px.poolA.log.slice(a0).some((l) => l.target === `${F}/index.html?pool=${i}`));
    check('pool retry: requests that picked the dead proxy were retried on the next one and returned 200', movedOn, `A saw ${JSON.stringify(px.poolA.log.slice(a0).map((l) => l.target))}`);
    check('pool: proxy B was sent its credentials', px.poolB.log.slice(b0).every((l) => l.auth === 'ok'), JSON.stringify(px.poolB.log.slice(b0).map((l) => l.auth)));
    check('pool: dead proxy shows as ejected in /health', h1.proxies.active === 2 && dead?.state === 'ejected' && dead.consecutiveFails === 2 && /proxy_failed|CouldntConnect/.test(dead.lastError ?? ''), JSON.stringify(dead));
    const next = [];
    for (let i = 0; i < 4; i++) next.push(await crawl({ url: `${F}/index.html?pool=after${i}`, formats: ['meta'], proxy: 'pool' }));
    check('pool: while ejected, every request succeeds on the other two', next.every((r) => r.status === 200) && deadEntry(await health()).uses === 2, next.map((r) => r.status).join(','));
    await sleep(5200);
    const h2 = await health();
    check('pool: dead proxy offered again after the retry period', deadEntry(h2)?.state === 'active', JSON.stringify(h2.proxies.proxies.map((p) => p.state)));
    const again = [];
    for (let i = 0; i < 3; i++) again.push(await crawl({ url: `${F}/index.html?pool=again${i}`, formats: ['meta'], proxy: 'pool' }));
    const h3 = await health();
    check('pool: one more failure ejects it again straight away (and that request is retried)', again.every((r) => r.status === 200) && deadEntry(h3)?.failed === 3 && deadEntry(h3)?.state === 'ejected', `${again.map((r) => r.body.error?.code ?? r.status).join(',')} ${JSON.stringify(deadEntry(h3))}`);
}

// 12b. An https site that is down, behind a good proxy: the engine sees the
// proxy refuse the CONNECT, the service asks the proxy for the probe address,
// and the site is blamed, not the proxy. (The dead pool proxy is still ejected.)
{
    const downPort = await freePort();
    const h0 = await health();
    const goodOf = (h) => h.proxies.proxies.filter((p) => !p.proxy.endsWith(`:${px.deadPort}`));
    const a0 = px.poolA.log.length, b0 = px.poolB.log.length;
    const res = [];
    for (let i = 0; i < 3; i++) res.push(await crawl({ url: `https://${PH}:${downPort}/?down=${i}`, formats: ['meta'], proxy: 'pool', timeout: 10000 }));
    const h1 = await health();
    const viaProxy = [...px.poolA.log.slice(a0), ...px.poolB.log.slice(b0)].filter((l) => l.method === 'CONNECT' && l.target === `${PH}:${downPort}`).length;
    check('pool: a site that is down -> 502 navigation_failed, blamed on the site', res.every((r) => r.status === 502 && r.body.error?.code === 'navigation_failed' && /reaches the probe/.test(r.body.error.message)) && viaProxy >= 3, `CONNECTs ${viaProxy} ${res.map((r) => `${r.status} ${r.body.error?.code}: ${r.body.error?.message}`).join(' | ')}`);
    const before = goodOf(h0), after = goodOf(h1);
    check('pool: ... and neither good proxy is charged or ejected', after.every((p, i) => p.state === 'active' && p.failed === before[i].failed && p.consecutiveFails === 0), JSON.stringify(after));
    const direct = await crawl({ url: `https://${PH}:${downPort}/`, formats: ['meta'], proxy: `http://${PH}:${px.plain.port}`, timeout: 10000 });
    check('proxy: the same with a per-request proxy -> navigation_failed, not proxy_failed', direct.status === 502 && direct.body.error?.code === 'navigation_failed', `${direct.status} ${JSON.stringify(direct.body.error)}`);
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

// 13b. Deleting a session, and sessions expiring after SESSION_TTL_MS idle.
{
    const titleOf = async (sid) => (await crawl({ url: `${F}/echo-cookies`, formats: ['meta'], session_id: sid })).body.meta?.title ?? '(failed)';
    const del = (sid) => fetch(`${SVC}/sessions/${sid}`, { method: 'DELETE' }).then(async (r) => ({ status: r.status, body: await r.json() }));
    const sid = `d${Date.now()}`;
    await crawl({ url: `${F}/set-cookie?x=1`, formats: ['meta'], session_id: sid });
    const had = (await sessionFiles()).includes(`${sid}.json`);
    const r1 = await del(sid);
    const gone = !(await sessionFiles()).includes(`${sid}.json`);
    const r2 = await del(sid);
    const sent = await titleOf(sid);
    check('session delete: DELETE /sessions/:id -> 200, file removed, cookies gone, second DELETE 404', had && r1.status === 200 && r1.body.deleted === sid && gone && r2.status === 404 && sent === '', `file before ${had}, ${r1.status} ${JSON.stringify(r1.body)}, file after ${!gone}, again ${r2.status}, next crawl sends "${sent}"`);
    const badDel = await del('..%2Fetc');
    check('session delete: unsafe id -> 400', badDel.status === 400, `${badDel.status}`);
    // A crawl still running when its session is deleted doesn't bring it back.
    const sid2 = `dl${Date.now()}`;
    await crawl({ url: `${F}/set-cookie?y=1`, formats: ['meta'], session_id: sid2 });
    const running = crawl({ url: `${F}/set-cookie?z=1`, formats: ['meta'], js: 'new Promise((r) => setTimeout(r, 800))', session_id: sid2 });
    await sleep(300);
    const r3 = await del(sid2);
    await running;
    const after = await titleOf(sid2);
    check('session delete: a crawl in flight during DELETE does not resurrect the session', r3.status === 200 && after === '', `${r3.status}, next crawl sends "${after}"`);

    const h0 = await health();
    const ttl = h0.sessions.ttlMs;
    const sid3 = `e${Date.now()}`;
    await crawl({ url: `${F}/set-cookie?t=1`, formats: ['meta'], session_id: sid3 });
    const kept = await titleOf(sid3);
    const before = (await sessionFiles()).includes(`${sid3}.json`);
    await sleep(ttl + 2500);
    const h1 = await health();
    const removed = !(await sessionFiles()).includes(`${sid3}.json`);
    const sentAfter = await titleOf(sid3);
    check(`session ttl: idle past SESSION_TTL_MS (${ttl}ms) -> file swept, cookies gone`, ttl > 0 && ttl <= 20000 && kept === 't=1' && before && removed && sentAfter === '' && h1.sessions.expired > h0.sessions.expired, `kept "${kept}", file before ${before}, removed ${removed}, sends "${sentAfter}", expired ${h0.sessions.expired}->${h1.sessions.expired}, stored ${h0.sessions.stored}->${h1.sessions.stored}`);
}

// 14. Timeouts hand back what the page had. A page whose load event never
// comes (an async script that never arrives) has its html and markdown; a
// document whose body never finishes is not parsed yet, so it has the source
// that arrived, without anything in it being fetched; a page that never
// answers has nothing.
const GRACE = 2000;
{
    const { status, body, ms } = await crawl({ url: `${F}/slow-load`, formats: ['html', 'markdown', 'meta'], timeout: 1500 });
    check('partial: load never fires -> 504 with partial html and markdown', status === 504 && body.error?.code === 'timeout' && body.partial?.html?.includes('<h1>Loaded body</h1>') && /^# Loaded body$/m.test(body.partial?.markdown ?? '') && body.partial?.source === 'dom', `${status} ${ms}ms partial=${JSON.stringify(body.partial)?.slice(0, 200)}`);
    check('partial: answered within timeout + grace', ms < 1500 + GRACE + 1000, `${ms}ms`);
    const stall = await crawl({ url: `${F}/stall`, formats: ['html', 'markdown'], timeout: 1500 });
    check('partial: body never finishes -> 504 within timeout + grace', stall.status === 504 && stall.ms < 1500 + GRACE + 1000, `${stall.status} ${stall.ms}ms`);
    check('partial: body never finishes -> the arrived source and its markdown, marked raw-body', stall.body.partial?.source === 'raw-body' && stall.body.partial.html?.startsWith('<!doctype html><html><head><title>Stalled</title>') && stall.body.partial.html.includes('<h1>Partial content</h1>') && /^# Partial content$/m.test(stall.body.partial.markdown ?? '') && /more is coming/.test(stall.body.partial.markdown ?? ''), `partial=${JSON.stringify(stall.body.partial)?.slice(0, 300)}`);
    const stallHtml = await crawl({ url: `${F}/stall?html-only`, formats: ['html'], timeout: 1500 });
    check('partial: nothing the unparsed source names is fetched', fixture.stats.stallAssetHits === 0, `${fixture.stats.stallAssetHits} requests for /stall-asset.gif`);
    check('partial: body never finishes, html only -> raw-body html, no markdown key', stallHtml.status === 504 && stallHtml.body.partial?.source === 'raw-body' && stallHtml.body.partial.html?.includes('<h1>Partial content</h1>') && !('markdown' in stallHtml.body.partial), `${stallHtml.status} partial=${JSON.stringify(stallHtml.body.partial)?.slice(0, 200)}`);
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
// 16. Request history: every crawl above is on disk with its outcome and
// sizes but not its content, proxy passwords redacted; GET /history filters
// it; files past the retention period go at startup; it survives a restart.
{
    const q = async (qs) => {
        const r = await fetch(`${SVC}/history?${qs}`);
        return { status: r.status, body: await r.json() };
    };
    const all = (await q('limit=1000&days=1')).body;
    const es = all.entries ?? [];
    check('history: enabled, entries newest first', all.enabled === true && es.length >= 50 && es.every((e, i) => i === 0 || es[i - 1].time >= e.time), `enabled ${all.enabled}, ${es.length} entries, scanned ${JSON.stringify(all.scanned)}`);
    const full = es.find((e) => e.url === `${F}/index.html` && e.formats?.length === 4);
    check('history: a full crawl has final url, page status, timing, formats and sizes, no content', full && full.status === 200 && full.code === null && full.finalUrl === `${F}/index.html` && full.pageStatus === 200 && full.ms > 0 && full.queueMs >= 0 && full.htmlBytes > 100 && full.markdownBytes > 10 && full.partial === null && full.proxyMode === 'direct' && full.proxy === null && !('html' in full) && !('markdown' in full), JSON.stringify(full));
    const redirect = es.find((e) => e.url === `${F}/redirect`);
    check('history: redirect -> finalUrl is the target', redirect?.finalUrl === `${F}/index.html`, JSON.stringify(redirect));
    const partial = es.find((e) => e.url === `${F}/slow-load`);
    check('history: a timeout records the code, the document it had, and the partial result it carried', partial?.status === 504 && partial.code === 'timeout' && partial.finalUrl === `${F}/slow-load` && partial.pageStatus === 200 && partial.partial?.source === 'dom' && partial.partial.htmlBytes > 0 && partial.partial.markdownBytes > 0 && /timeout/.test(partial.message), JSON.stringify(partial));
    const raw = es.find((e) => e.url === `${F}/stall`);
    check('history: raw-body partial recorded as such', raw?.partial?.source === 'raw-body', JSON.stringify(raw?.partial));
    const pooled = es.filter((e) => e.proxyMode === 'pool' && e.proxy?.includes('pool:***@'));
    const retried = es.find((e) => e.proxyMode === 'pool' && e.status === 200 && e.proxiesTried === 2);
    const fileText = await historySh('cat crawl-*.jsonl');
    check('history: pool proxy recorded with the password redacted, nowhere in the files', pooled.length > 0 && retried && !fileText.includes(':secret@') && !fileText.includes(':wrong@') && fileText.includes('user:***@'), `pooled ${pooled.length}, retried ${JSON.stringify(retried)}, ':secret@' in files ${fileText.includes(':secret@')}`);
    const bad = es.find((e) => e.url === 'ftp://x');
    check('history: a bad request is recorded with bad_request', bad?.status === 400 && bad.code === 'bad_request', JSON.stringify(bad));
    const sessionIds = [...new Set(es.map((e) => e.session_id).filter(Boolean))];
    const sid = sessionIds[0];
    const bySid = (await q(`session_id=${sid}&limit=1000&days=1`)).body.entries;
    check('history filter: session_id', sid && bySid.length === es.filter((e) => e.session_id === sid).length && bySid.every((e) => e.session_id === sid), `${sid}: ${bySid?.length}`);
    const s504 = (await q('status=504&limit=1000&days=1')).body.entries;
    const okOnly = (await q('code=ok&limit=1000&days=1')).body.entries;
    const errs = (await q('code=proxy_auth_failed,navigation_failed&limit=1000&days=1')).body.entries;
    check('history filter: status and code (ok, and a comma list)', s504.length > 0 && s504.every((e) => e.status === 504) && okOnly.length > 0 && okOnly.every((e) => e.status === 200) && errs.length > 0 && errs.every((e) => ['proxy_auth_failed', 'navigation_failed'].includes(e.code)) && new Set(errs.map((e) => e.code)).size === 2, `504 ${s504.length}, ok ${okOnly.length}, errs ${errs.length}`);
    const byUrl = (await q(`url=${encodeURIComponent('/SLOW-load')}&days=1`)).body.entries;
    const two = (await q('limit=2&days=1')).body.entries;
    const mid = es[Math.floor(es.length / 2)].time;
    const since = (await q(`since=${encodeURIComponent(mid)}&limit=1000`)).body.entries;
    const until = (await q(`since=0&until=${Date.parse(mid)}&limit=1000`)).body.entries;
    check('history filter: url substring, limit, since/until', byUrl.length >= 1 && byUrl.every((e) => e.url.includes('/slow-load')) && two.length === 2 && two[0].time === es[0].time && since.every((e) => e.time >= mid) && until.every((e) => e.time <= mid) && since.length + until.length >= es.length, `url ${byUrl.length}, limit ${two.length}, since ${since.length} until ${until.length} of ${es.length}`);
    const badQ = await Promise.all(['limit=0', 'limit=abc', 'status=20x', 'since=yesterday'].map(q));
    check('history: bad query -> 400', badQ.every((r) => r.status === 400 && r.body.error?.code === 'bad_request'), badQ.map((r) => r.status).join(','));
    const h0 = await health();
    check('history: /health reports it, no write errors', h0.history?.enabled === true && h0.history.writeErrors === 0 && h0.history.dropped === 0 && h0.history.written > 0 && h0.history.queued === 0, JSON.stringify(h0.history));

    await historySh('echo "{}" > crawl-2000-01-01.planted.jsonl');
    const planted = (await historySh('ls')).includes('crawl-2000-01-01.planted.jsonl');
    await restartService();
    const files = (await historySh('ls')).split('\n').filter(Boolean);
    const after = (await q('limit=1000&days=1')).body.entries;
    check('history: files past HISTORY_RETENTION_DAYS are removed at startup, the rest kept', planted && !files.includes('crawl-2000-01-01.planted.jsonl') && files.length >= 1 && after.length >= es.length, `planted ${planted}, files now ${JSON.stringify(files)}, entries ${es.length} -> ${after.length}`);
}
// 17. The admin page and the session list it shows.
{
    const r = await fetch(`${SVC}/`);
    const page = await r.text();
    const external = page.match(/(?:src|href)\s*=\s*["']?(?:https?:)?\/\/|@import|url\(\s*["']?(?:https?:)?\/\//gi) ?? [];
    check('admin page: GET / serves the page, no external resources', r.status === 200 && /^text\/html/.test(r.headers.get('content-type')) && page.includes('爬虫服务管理') && page.includes('/history') && external.length === 0, `${r.status} ${r.headers.get('content-type')} ${page.length} bytes, external ${JSON.stringify(external)}`);
    const sid = `ls${Date.now()}`;
    await crawl({ url: `${F}/set-cookie?listme=hidden-value`, formats: ['meta'], session_id: sid });
    const list = await (await fetch(`${SVC}/sessions`)).json();
    const mine = list.sessions?.find((x) => x.id === sid);
    check('sessions list: GET /sessions has the session, cookie count and domain, no cookie values', list.total >= 1 && mine?.cookies >= 1 && mine.domains.includes(new URL(F).hostname) && mine.expiresAt && !JSON.stringify(list).includes('hidden-value'), JSON.stringify(mine));
    const bad = await fetch(`${SVC}/sessions?limit=0`);
    check('sessions list: bad limit -> 400', bad.status === 400, `${bad.status}`);
}
// 18. MCP: agents drive pages through POST /mcp (engine `mcp` processes
// behind the service), with the calls in the history.
{
    const paging = await startPagingServer(process.env.FIXTURE_HOST, process.env.FIXTURE_URL_HOST);
    const P = paging.base;
    const MCP = `${SVC}/mcp`;
    const h = await health();
    check('mcp: /health shows 2 engine processes up', h.mcp?.enabled === true && h.mcp.processes.length === 2 && h.mcp.processes.every((p) => p.up && p.pid), JSON.stringify(h.mcp));
    const cmdlines = (await mcpSh(`for f in /proc/[0-9]*/cmdline; do tr '\\0' ' ' < "$f"; echo; done | grep '^[^ ]*lightpanda mcp '`)).split('\n').filter(Boolean);
    check('mcp: engines run with --no-webmcp and the MCP proxy, none of the bot flags', cmdlines.length === 2 && cmdlines.every((c) => / --no-webmcp( |$)/.test(c) && / --http-proxy http:\/\/user:/.test(c) && !/--webmcp |--obey-robots|--web-bot-auth/.test(c)), JSON.stringify(cmdlines.map((c) => c.replace(/user:[^@]*@/, 'user:***@'))));

    const a = new McpClient(MCP), b = new McpClient(MCP);
    const init = await a.initialize();
    await b.initialize();
    const tools = (await a.request('tools/list')).tools.map((t) => t.name);
    check('mcp: initialize gives a session id; tools/list has the browser tools, not the session tools or save', /^mcp-[0-9a-f]{24}$/.test(a.sessionId) && a.sessionId !== b.sessionId && init.serverInfo?.name === 'lightpanda' && ['goto', 'click', 'evaluate', 'markdown', 'interactiveElements', 'waitForSelector'].every((t) => tools.includes(t)) && !tools.some((t) => /^session_|^save$/.test(t)), `${a.sessionId} ${tools.join(',')}`);

    await a.tool('goto', { url: `${P}/whoami?tag=mc` });
    const surface = await a.tool('evaluate', { script: `[typeof navigator.modelContext, typeof ModelContext, typeof ModelContextClient, 'modelContext' in navigator, Object.getOwnPropertyNames(Navigator.prototype).includes('modelContext')].join(',')` });
    check('mcp: pages carry no WebMCP surface (navigator.modelContext, ModelContext, ModelContextClient)', surface === 'undefined,undefined,undefined,false,false', surface);

    // Link pagination: each page its own URL; follow "下一页" until it is gone.
    const collect = `JSON.stringify([...document.querySelectorAll('li.item')].map(li => li.dataset.id))`;
    const got = [];
    let pages = 0;
    await a.tool('goto', { url: `${P}/links/1` });
    for (;;) {
        pages++;
        got.push(...JSON.parse(await a.tool('evaluate', { script: collect })));
        if ((await a.tool('evaluate', { script: `!!document.querySelector('a.next')` })) !== 'true' || pages > 20) break;
        await a.tool('click', { selector: 'a.next' });
        await a.tool('waitForSelector', { selector: 'li.item' });
    }
    const linkUrl = await a.tool('getUrl');
    check('mcp: link pagination clicked through to the last page', JSON.stringify(got) === JSON.stringify(expectedIds('L')) && linkUrl === `${P}/links/5`, `${pages} pages, ${got.length} items, at ${linkUrl}`);

    // Ajax pagination: one URL, the button swaps the list in place.
    const ajax = [];
    let apages = 0;
    await a.tool('goto', { url: `${P}/ajax` });
    for (;;) {
        apages++;
        ajax.push(...JSON.parse(await a.tool('evaluate', { script: collect })));
        if ((await a.tool('evaluate', { script: `!!document.querySelector('#next')` })) !== 'true' || apages > 20) break;
        await a.tool('click', { selector: '#next' });
        await a.tool('waitForScript', { script: `document.getElementById('status').textContent === '第 ${apages + 1} 页'` });
    }
    check('mcp: ajax pagination clicked through to the last page on one URL', JSON.stringify(ajax) === JSON.stringify(expectedIds('A')) && (await a.tool('getUrl')) === `${P}/ajax`, `${apages} pages, ${ajax.length} items`);

    // Two sessions at once: separate processes, so one's slow page does not
    // hold the other, and neither sees the other's page or cookies.
    const t0 = Date.now();
    const slow = a.tool('goto', { url: `${P}/slow?ms=3000` }).then(() => Date.now() - t0);
    await sleep(200);
    const t1 = Date.now();
    await b.tool('goto', { url: `${P}/whoami?tag=bee` });
    const fastMs = Date.now() - t1;
    const slowMs = await slow;
    const [ua, ub] = [await a.tool('getUrl'), await b.tool('getUrl')];
    const [ta, tb] = [await a.tool('evaluate', { script: 'document.title' }), await b.tool('evaluate', { script: 'document.title' })];
    check('mcp: two concurrent sessions do not wait on each other or share a page', fastMs < 1500 && slowMs >= 3000 && ua === `${P}/slow?ms=3000` && ub === `${P}/whoami?tag=bee` && ta === 'slow 3000' && tb === 'whoami bee', `fast ${fastMs} ms, slow ${slowMs} ms, ${ua} / ${ub}, ${ta} / ${tb}`);
    await a.tool('goto', { url: `${F}/set-cookie?mcpcookie=1` });
    const ca = await a.tool('getCookies');
    const cb = await b.tool('getCookies');
    check('mcp: cookies stay in their session', ca.includes('mcpcookie') && !cb.includes('mcpcookie'), `${ca.slice(0, 120)} | ${cb.slice(0, 120)}`);
    check('mcp: page loads went through MCP_PROXY with its credentials', px.auth.log.some((l) => l.target === `${P}/links/3` && l.auth === 'ok'), `${px.auth.log.filter((l) => l.target?.startsWith(P)).length} paging requests via the proxy`);

    const refused = await a.tool('session_list').then(() => 'allowed', (e) => e.message);
    const anon = await fetch(MCP, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
    const unknown = await fetch(MCP, { method: 'POST', headers: { 'content-type': 'application/json', 'mcp-session-id': 'mcp-nope' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
    const get = await fetch(MCP);
    check('mcp: session tools refused; no session header 400, unknown session 404, GET 405', /not available/.test(refused) && anon.status === 400 && unknown.status === 404 && get.status === 405, `${refused} / ${anon.status} ${unknown.status} ${get.status}`);

    const listed = await (await fetch(`${SVC}/mcp/sessions`)).json();
    const mine = listed.sessions?.find((x) => x.id === a.sessionId);
    check('mcp: GET /mcp/sessions lists the session with its page and call count', listed.total >= 2 && mine?.calls > 10 && mine.url === `${F}/set-cookie?mcpcookie=1`, JSON.stringify(mine));

    await sleep(1200); // the history flushes every second
    const hist = (await (await fetch(`${SVC}/history?kind=mcp&session_id=${a.sessionId}&limit=1000`)).json()).entries;
    const gotos = hist.filter((e) => e.tool === 'goto');
    const nextClick = hist.find((e) => e.tool === 'click' && e.url === `${P}/links/1`);
    check('mcp: history has every call: goto url and ms, click from page 1 to page 2, the session', hist.length >= 30 && gotos.some((e) => e.url === `${P}/links/1` && e.status === 200 && e.code === null && e.ms >= 0) && nextClick?.finalUrl === `${P}/links/2` && hist.every((e) => e.kind === 'mcp' && e.mcp_session === a.sessionId) && hist.some((e) => e.tool === 'session_start') && hist.every((e) => !e.proxy || e.proxy.includes('***')), `${hist.length} entries, click ${JSON.stringify(nextClick)}`);
    const onlyCrawl = (await (await fetch(`${SVC}/history?kind=crawl&limit=1000`)).json()).entries;
    check('mcp: history kind=crawl leaves the MCP lines out', onlyCrawl.length > 0 && onlyCrawl.every((e) => e.kind === 'crawl'), `${onlyCrawl.length}`);

    // An engine process dies: its sessions answer 404 and a new one works.
    const pa = (await health()).mcp.processes.find((p) => p.name === listed.sessions.find((x) => x.id === a.sessionId).process);
    await mcpSh(`kill -9 ${pa.pid}`);
    await sleep(300);
    const lost = await a.tool('getUrl').then(() => 'still there', (e) => e.message);
    let reborn = null;
    for (let i = 0; i < 50 && !reborn; i++) {
        await sleep(200);
        const c = new McpClient(MCP);
        reborn = await c.initialize().then(() => c, () => null);
    }
    const bStill = await b.tool('getUrl').catch((e) => e.message);
    let after = (await health()).mcp;
    for (let i = 0; i < 100 && !after.processes.every((p) => p.up); i++) {
        await sleep(200); // LP_RESTART_DELAY
        after = (await health()).mcp;
    }
    check('mcp: a killed engine process loses its sessions (404), is restarted, new sessions work', /HTTP 404/.test(lost) && reborn && (await reborn.tool('goto', { url: `${P}/whoami?tag=again` })) === 'Navigated successfully.' && after.processes.every((p) => p.up) && after.lost >= 1, `${lost} / b: ${bStill} / ${JSON.stringify(after.processes)}`);

    check('mcp: DELETE ends the session', (await b.close()) === 204 && (await b.tool('getUrl').then(() => 'alive', (e) => e.message)).includes('HTTP 404'));
    await reborn?.close();

    // session_id: a /crawl login carried into an MCP browser, an MCP login
    // carried out to /crawl (while the MCP session is still open), each
    // bound session on its own jar, and an unbound one on none.
    const tag = Date.now().toString(36);
    const [jc, jm] = [`mcpck-c-${tag}`, `mcpck-m-${tag}`];
    const title = async (c) => c.tool('evaluate', { script: 'document.title' });
    const crawled = await crawl({ url: `${F}/login?user=crawler`, session_id: jc });
    const c1 = new McpClient(`${MCP}?session_id=${jc}`);
    await c1.initialize();
    await c1.tool('goto', { url: `${F}/account` });
    const [tc1, js1] = [await title(c1), await c1.tool('evaluate', { script: 'document.cookie' })];
    check('mcp session_id: a /crawl login (HttpOnly cookie) is signed in in the MCP browser', crawled.status === 200 && tc1 === 'account: crawler' && !js1.includes('auth='), `${crawled.status} / ${tc1} / document.cookie ${JSON.stringify(js1)}`);

    const c2 = new McpClient(`${MCP}?session_id=${jm}`);
    await c2.initialize();
    await c2.tool('goto', { url: `${F}/login-form` });
    await c2.tool('fill', { selector: '#user', value: 'agent' });
    await c2.tool('click', { selector: '#go' });
    const afterClick = await crawl({ url: `${F}/account`, session_id: jm, formats: ['meta'] });
    await c2.tool('waitForScript', { script: `document.title === 'logged in'` });
    const afterWait = await crawl({ url: `${F}/account`, session_id: jm, formats: ['meta'] });
    check('mcp session_id: an MCP login reaches /crawl while the MCP session is open', afterWait.body?.meta?.title === 'account: agent', `right after click: ${afterClick.body?.meta?.title}; after waitForScript: ${afterWait.body?.meta?.title}`);

    const c3 = new McpClient(MCP);
    await c3.initialize();
    await c3.tool('goto', { url: `${F}/account` });
    await c1.tool('goto', { url: `${F}/account` });
    await c2.tool('goto', { url: `${F}/account` });
    const titles = [await title(c3), await title(c1), await title(c2)];
    const bound = (await (await fetch(`${SVC}/mcp/sessions`)).json()).sessions;
    const byId = (c) => bound.find((x) => x.id === c.sessionId)?.session_id;
    check('mcp session_id: bound sessions keep to their own jar, an unbound one has none; /mcp/sessions shows the binding', JSON.stringify(titles) === JSON.stringify(['account: guest', 'account: crawler', 'account: agent']) && byId(c1) === jc && byId(c2) === jm && byId(c3) === null, `${titles.join(' | ')} / ${byId(c1)} ${byId(c2)} ${byId(c3)}`);

    // A cookie a page script sets after the last call reaches the jar when
    // the session is closed.
    await c2.tool('evaluate', { script: `setTimeout(() => { document.cookie = 'late=${tag}; path=/'; }, 300); 'ok'` });
    await sleep(800);
    await c2.close();
    const echoed = await crawl({ url: `${F}/echo-cookies`, session_id: jm, formats: ['meta'] });
    check('mcp session_id: DELETE writes back the cookies set since the last call', (echoed.body?.meta?.title ?? '').includes(`late=${tag}`), echoed.body?.meta?.title);

    await sleep(1200); // the history flushes every second
    const jHist = (await (await fetch(`${SVC}/history?session_id=${jm}&limit=1000`)).json()).entries;
    check('mcp session_id: history by session_id has both the /crawl and the MCP lines', jHist.some((e) => e.kind === 'crawl') && jHist.some((e) => e.kind === 'mcp' && e.tool === 'click' && e.mcp_session === c2.sessionId) && jHist.some((e) => e.tool === 'session_start' && /1 cookie|0 cookie/.test(e.message ?? '')), `${jHist.length} lines: ${jHist.map((e) => e.kind === 'mcp' ? e.tool : 'crawl').join(',')}`);
    const badBind = await fetch(`${MCP}?session_id=bad%2Fid`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }) });
    check('mcp session_id: an invalid session_id is refused (400)', badBind.status === 400, `${badBind.status}`);
    await c1.close();
    await c3.close();

    // The other way: what /crawl writes into the jar while an MCP session is
    // open reaches that browser at its next call -- a login, and the site
    // deleting the cookie again.
    const jl = `mcpsync-l-${tag}`;
    const s1 = new McpClient(`${MCP}?session_id=${jl}`);
    await s1.initialize();
    await s1.tool('goto', { url: `${F}/account` });
    const before = await title(s1);
    await crawl({ url: `${F}/login?user=crawler2`, session_id: jl, formats: ['meta'] });
    await s1.tool('goto', { url: `${F}/account` });
    const loggedIn = await title(s1);
    const hidden = await s1.tool('evaluate', { script: 'document.cookie' });
    check('mcp session_id: a /crawl login made while the MCP session is open is signed in at its next call', before === 'account: guest' && loggedIn === 'account: crawler2' && !hidden.includes('auth='), `${before} -> ${loggedIn} / document.cookie ${JSON.stringify(hidden)}`);
    await crawl({ url: `${F}/logout`, session_id: jl, formats: ['meta'] });
    await s1.tool('goto', { url: `${F}/account` });
    const loggedOut = await title(s1);
    const jarAfter = await crawl({ url: `${F}/echo-cookies`, session_id: jl, formats: ['meta'] });
    check('mcp session_id: a cookie /crawl has the site delete is gone from the open MCP browser too', loggedOut === 'account: guest' && !(jarAfter.body?.meta?.title ?? '').includes('auth='), `${loggedOut} / jar: ${jarAfter.body?.meta?.title}`);
    await s1.close();

    // Two MCP sessions on one jar: one logs in, the other's next page is
    // signed in; one logs out, the other's next page is not.
    const jt = `mcpsync-t-${tag}`;
    const m1 = new McpClient(`${MCP}?session_id=${jt}`), m2 = new McpClient(`${MCP}?session_id=${jt}`);
    await m1.initialize();
    await m2.initialize();
    await m2.tool('goto', { url: `${F}/account` });
    const m2Before = await title(m2);
    await m1.tool('goto', { url: `${F}/login?user=one` });
    await m2.tool('goto', { url: `${F}/account` });
    const m2In = await title(m2);
    await m1.tool('goto', { url: `${F}/logout` });
    await m2.tool('goto', { url: `${F}/account` });
    const m2Out = await title(m2);
    check('mcp session_id: two MCP sessions on one session_id see each other\'s login and logout at their next call', m2Before === 'account: guest' && m2In === 'account: one' && m2Out === 'account: guest', `${m2Before} -> ${m2In} -> ${m2Out}`);
    const sync = (await health()).mcp;
    check('mcp session_id: /health counts the pulls, with no errors', sync.cookiePulls >= 4 && sync.cookiePullErrors === 0 && sync.cookieSaveErrors === 0, `pulls ${sync.cookiePulls}, pull errors ${sync.cookiePullErrors}, save errors ${sync.cookieSaveErrors}`);
    await m1.close();
    await m2.close();

    // Stopping the service (docker stop: SIGTERM) writes back what a page
    // script set after the session's last call, within docker stop's 10 s.
    const js = `mcpsync-s-${tag}`;
    const st = new McpClient(`${MCP}?session_id=${js}`);
    await st.initialize();
    await st.tool('goto', { url: `${F}/account` });
    await st.tool('evaluate', { script: `setTimeout(() => { document.cookie = 'bye=${tag}; path=/; max-age=3600'; }, 300); 'ok'` });
    await sleep(800);
    const stopped = await stopService();
    const kept = await crawl({ url: `${F}/echo-cookies`, session_id: js, formats: ['meta'] });
    const savedLine = /"msg":"mcp cookies saved on shutdown"[^\n]*/.exec(stopped.log)?.[0] ?? '(no shutdown line)';
    check('mcp session_id: stopping the service writes back the cookies set since the last call, inside docker stop\'s 10 s', (kept.body?.meta?.title ?? '').includes(`bye=${tag}`) && stopped.ms < 10000 && /"saved":[1-9]/.test(savedLine) && /"timedOut":false/.test(savedLine), `stop took ${stopped.ms} ms / ${savedLine} / jar: ${kept.body?.meta?.title}`);
    paging.server.closeAllConnections();
    paging.server.close();
}
// 19. Paging with /crawl alone, the two recipes in README.zh-CN.md
// ("翻页"): ajax paging in one request's js; link paging as a caller loop,
// each js returning the next page's link, on one session_id.
{
    const paging = await startPagingServer(process.env.FIXTURE_HOST, process.env.FIXTURE_URL_HOST);
    const P = paging.base;
    const ajaxJs = `(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const pages = [];
  for (let n = 1; n <= 50; n++) {
    pages.push([...document.querySelectorAll('li.item')].map((li) => ({ id: li.dataset.id, title: li.querySelector('.title').textContent })));
    const next = document.querySelector('#next');
    if (!next) break;
    const before = document.querySelector('#list').innerHTML;
    next.click();
    for (let i = 0; i < 100 && document.querySelector('#list').innerHTML === before; i++) await sleep(100);
  }
  return pages;
})()`;
    const r = await crawl({ url: `${P}/ajax`, js: ajaxJs, formats: ['eval', 'meta'], timeout: 30000 });
    const ids = (r.body.eval?.value ?? []).flat().map((x) => x.id);
    check('paging recipe: ajax pages clicked through in one request\'s js', r.status === 200 && JSON.stringify(ids) === JSON.stringify(expectedIds('A')) && r.body.eval.value.length === 4, `${r.status} ${r.ms} ms, ${r.body.eval?.value?.length} pages ${ids.length} items ${JSON.stringify(r.body.eval?.error ?? r.body.error ?? '')}`);

    const linkJs = `(() => ({
  items: [...document.querySelectorAll('li.item')].map((li) => ({ id: li.dataset.id, title: li.querySelector('.title').textContent })),
  next: document.querySelector('a.next')?.href ?? null,
}))()`;
    const sid = `paging-${Date.now()}`;
    const linkIds = [];
    let url = `${P}/links/1`, n = 0, statuses = [];
    const t0 = Date.now();
    while (url && n < 50) {
        const page = await crawl({ url, js: linkJs, formats: ['eval'], session_id: sid });
        statuses.push(page.status);
        if (page.status !== 200) break;
        linkIds.push(...page.body.eval.value.items.map((x) => x.id));
        url = page.body.eval.value.next;
        n++;
    }
    check('paging recipe: link pages followed by the caller, one session_id', JSON.stringify(linkIds) === JSON.stringify(expectedIds('L')) && n === 5 && url === null, `${n} requests in ${Date.now() - t0} ms, statuses ${statuses.join(',')}, ${linkIds.length} items`);
    paging.server.closeAllConnections();
    paging.server.close();
}
{
    const h = await health();
    console.log(`      health at the end: ${JSON.stringify(h.pool)} sessions=${JSON.stringify(h.sessions)} history=${JSON.stringify(h.history)}`);
}

fixture.server.closeAllConnections();
fixture.server.close();
for (const p of Object.values(px)) p.server?.close();
cleanup();
console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
