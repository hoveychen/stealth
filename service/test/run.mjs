// End-to-end test: local fixture pages + a real `lightpanda serve` + this
// service, all on free local ports. Exits non-zero if any check fails.
//
//   LP_BIN=/path/to/lightpanda node service/test/run.mjs
//
// Use a ReleaseFast build; the Debug one in zig-out is ~3.5x slower.

import { spawn } from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { startFixtureServer } from './fixture-server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const LP_BIN = process.env.LP_BIN || path.resolve(here, '../../zig-out/bin/lightpanda');
if (!fs.existsSync(LP_BIN)) {
    console.error(`engine binary not found: ${LP_BIN} (set LP_BIN)`);
    process.exit(2);
}
const POOL_SIZE = 3;

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
    engine = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(lpPort), '--log-level', 'fatal'], { stdio: 'ignore' });
    children.push(engine);
}
async function waitHttp(url) {
    for (let i = 0; i < 100; i++) {
        try {
            await fetch(url);
            return;
        } catch {
            await sleep(100);
        }
    }
    throw new Error(`${url} never came up`);
}

const fixture = await startFixtureServer();
startEngine();
await waitHttp(`http://127.0.0.1:${lpPort}/json/version`);

const svcPort = await freePort();
const svc = spawn(process.execPath, [path.resolve(here, '../server.mjs')], {
    env: { ...process.env, PORT: String(svcPort), HOST: '127.0.0.1', LP_CDP_URL: `ws://127.0.0.1:${lpPort}/`, POOL_SIZE: String(POOL_SIZE) },
    stdio: ['ignore', 'ignore', 'inherit'],
});
children.push(svc);
const SVC = `http://127.0.0.1:${svcPort}`;
await waitHttp(`${SVC}/health`);

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

// 9. Engine killed mid-request, stays down, then comes back.
{
    const inflight = crawl({ url: `${F}/delay?ms=3000&i=k`, timeout: 20000 });
    await sleep(500);
    engine.kill('SIGKILL');
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

fixture.server.closeAllConnections();
fixture.server.close();
cleanup();
console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
