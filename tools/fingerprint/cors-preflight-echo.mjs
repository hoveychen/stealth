// Which cross-origin requests get an OPTIONS preflight, and what each engine
// does with the preflight's answer.
//
// `cors-preflight-nonsimple` P1. B53 caught the headline case on x-hyatt: the same
// `POST application/json` to a third-party origin gets an OPTIONS from Chrome
// and none from this engine. That is a spec-level bug (Fetch: a cross-origin
// request whose Content-Type is not one of the three CORS-safelisted values must
// be preflighted), so it is measurable on a loopback pair of origins and needs
// no station.
//
// Two servers: the page origin, and an API origin on another port — a different
// port is a different origin, which is all CORS cares about. Every case has its
// own path so the request log is unambiguous, and each case reports both halves:
// what the server saw (did an OPTIONS arrive first, carrying what) and what the
// page saw (did the promise resolve, could it read the body, what did it throw).
//
// Header *casing and order* are not what this measures — node:http normalises
// both. `header-echo.mjs` is the tool for that question.
//
// usage: node tools/fingerprint/cors-preflight-echo.mjs <chrome|lightpanda>
//            [--headed] [--port P] [--out FILE]
//        node tools/fingerprint/cors-preflight-echo.mjs --diff A.json B.json
//
// Env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

if (process.argv[2] === '--diff') {
    const [a, b] = await Promise.all([process.argv[3], process.argv[4]].map(async (f) =>
        JSON.parse(await fs.readFile(f, 'utf8'))));
    const names = [...new Set([...a.cases.map((c) => c.name), ...b.cases.map((c) => c.name)])];
    let differ = 0;
    for (const name of names) {
        const ca = a.cases.find((c) => c.name === name) ?? {};
        const cb = b.cases.find((c) => c.name === name) ?? {};
        const key = (c) => JSON.stringify({ methods: c.methods, outcome: c.outcome, acrm: c.acrm, acrh: c.acrh });
        if (key(ca) === key(cb)) continue;
        differ++;
        console.log(`\n${name}`);
        console.log(`  ${a.engine.padEnd(10)} ${JSON.stringify({ methods: ca.methods, outcome: ca.outcome, acrm: ca.acrm, acrh: ca.acrh })}`);
        console.log(`  ${b.engine.padEnd(10)} ${JSON.stringify({ methods: cb.methods, outcome: cb.outcome, acrm: cb.acrm, acrh: cb.acrh })}`);
    }
    console.log(`\n${differ}/${names.length} cases differ`);
    process.exit(0);
}

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: cors-preflight-echo.mjs <chrome|lightpanda> [--headed] [--port P] [--out FILE]');
    process.exit(2);
}
const arg = (name, dflt) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? dflt : process.argv[i + 1];
};
const headed = process.argv.includes('--headed');
const PORT = Number(arg('--port', 0)) || (engine === 'chrome' ? 17250 : 17251);
const OUT = arg('--out', null);
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LIGHTPANDA = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');

// Each case is one request the page makes to the API origin, plus how the API
// origin answers the preflight it may or may not receive. `expect` is what the
// Fetch spec requires, written down so a reading can be checked against the
// standard rather than against the other engine.
const CASES = [
    { name: 'get-simple', expect: 'no preflight', js: `fetch(U, {})` },
    { name: 'post-text-plain', expect: 'no preflight', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: 'x' })` },
    { name: 'post-form-urlencoded', expect: 'no preflight', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'a=1' })` },
    { name: 'post-json', expect: 'preflight', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })` },
    { name: 'post-json-charset', expect: 'preflight', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json;charset=UTF-8' }, body: '{}' })` },
    { name: 'get-custom-header', expect: 'preflight', js: `fetch(U, { headers: { 'X-Probe': '1' } })` },
    // Two unsafe headers, deliberately not in alphabetical order: how the engine
    // serializes Access-Control-Request-Headers (sorted? what separator?) is only
    // visible with more than one name in it.
    { name: 'two-custom-headers', expect: 'preflight, both names listed', js: `fetch(U, { headers: { 'X-Zeta': '1', 'X-Alpha': '2' } })` },
    // A CORS-safelisted Content-Type alongside an unsafe header: the preflight is
    // caused by the header, and content-type must *not* join the ACRH list.
    { name: 'custom-header-text-plain', expect: 'preflight, content-type not listed', js: `fetch(U, { method: 'POST', headers: { 'X-Probe': '1', 'Content-Type': 'text/plain' }, body: 'x' })` },
    { name: 'put', expect: 'preflight', js: `fetch(U, { method: 'PUT', body: 'x' })` },
    { name: 'delete', expect: 'preflight', js: `fetch(U, { method: 'DELETE' })` },
    { name: 'patch', expect: 'preflight', js: `fetch(U, { method: 'PATCH', body: 'x' })` },
    { name: 'xhr-post-json', expect: 'preflight', js: `xhr('POST', U, { 'Content-Type': 'application/json' }, '{}')` },
    { name: 'credentials-include', expect: 'preflight', js: `fetch(U, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: '{}' })` },
    // Enforcement: the preflight is answered in a way that must stop the request.
    // POST is a CORS-safelisted method, so leaving it out of Allow-Methods does
    // *not* block it — the check only bites for methods outside GET/HEAD/POST.
    // Chrome sends the POST here and it succeeds; the `-put` case is the one
    // that must be refused.
    { name: 'unlisted-post', expect: 'preflight, request allowed (POST is safelisted)', policy: 'deny-method', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })` },
    { name: 'unlisted-put', expect: 'preflight, request blocked', policy: 'deny-method', js: `fetch(U, { method: 'PUT', body: 'x' })` },
    { name: 'deny-header', expect: 'preflight, request blocked', policy: 'deny-header', js: `fetch(U, { headers: { 'X-Probe': '1' } })` },
    { name: 'deny-origin', expect: 'preflight, request blocked', policy: 'deny-origin', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })` },
    { name: 'no-acao-simple', expect: 'no preflight, read blocked', policy: 'no-acao', js: `fetch(U, {})` },
    { name: 'no-acao-after-preflight', expect: 'preflight, read blocked', policy: 'no-acao-actual', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })` },
    // Max-Age: two identical requests. A cache that works sends one preflight.
    { name: 'max-age-twice', expect: 'one preflight for two requests', policy: 'max-age', js: `fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }).then(() => fetch(U, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }))` },

    // --- The response half. `cors-response-check` P1. ------------------------
    //
    // The two no-acao cases above are the whole reason this plan exists: Chrome
    // throws on them and we resolve with a readable 200. Refusing a response is
    // a bigger hammer than refusing a preflight, though, so the shapes that must
    // KEEP working are measured here beside the ones that must start failing.
    //
    // A no-cors fetch does not get refused, it gets an opaque response: the
    // request goes out, the body is unreadable, and the promise still resolves.
    { name: 'no-cors-mode', expect: 'resolves opaque, status 0, body unreadable', policy: 'no-acao', js: `fetch(U, { mode: 'no-cors' })` },
    // Same refusal through XHR, where it surfaces as an error event rather than
    // a rejected promise. Which of status / responseText survive is the part an
    // implementation has to get right.
    { name: 'xhr-no-acao', expect: 'error event, status 0', policy: 'no-acao', js: `xhr('GET', U, {}, null)` },
    // A wildcard Allow-Origin is fine uncredentialed and invalid credentialed --
    // the pair is the whole point of Allow-Credentials.
    { name: 'wildcard-plain', expect: 'allowed', policy: 'wildcard', js: `fetch(U, {})` },
    { name: 'wildcard-with-credentials', expect: 'blocked: * is invalid with credentials', policy: 'wildcard', js: `fetch(U, { credentials: 'include' })` },
    // Allow-Origin naming someone else, with no preflight in the way: the simple
    // GET reaches the server and the read is still refused.
    { name: 'wrong-origin-simple', expect: 'no preflight, read blocked', policy: 'deny-origin-actual', js: `fetch(U, {})` },
    // Expose-Headers. An allowed CORS response only shows the safelisted
    // response headers unless it names more. This is a SEPARATE gap from the one
    // this plan fixes -- measured here so the decision is informed, not so it
    // gets bundled in.
    { name: 'expose-headers-default', expect: 'x-custom not readable', policy: 'expose-none', js: `fetch(U, {}).then(function (r) { return { status: r.status, text: 'x-custom=' + r.headers.get('x-custom') }; })` },
    { name: 'expose-headers-named', expect: 'x-custom readable', policy: 'expose-named', js: `fetch(U, {}).then(function (r) { return { status: r.status, text: 'x-custom=' + r.headers.get('x-custom') }; })` },
    // The two regression guards. A parser-pulled subresource is no-cors, so no
    // Allow-Origin is needed and none of this may stop it loading. If refusing
    // responses ever breaks these, it has broken page loading itself.
    { name: 'img-no-acao', expect: 'loads anyway (no-cors)', policy: 'no-acao', js: `new Promise(function (res) { var i = new Image(); i.onload = function () { res({ status: 200, text: 'loaded w=' + i.naturalWidth }); }; i.onerror = function () { res({ status: 0, text: 'errored' }); }; i.src = U; })` },
    { name: 'script-no-acao', expect: 'executes anyway (no-cors)', policy: 'no-acao', js: `new Promise(function (res) { var s = document.createElement('script'); s.onload = function () { res({ status: 200, text: 'ran=' + String(window.__scriptRan) }); }; s.onerror = function () { res({ status: 0, text: 'errored' }); }; s.src = U; document.head.appendChild(s); })` },
];

const log = [];   // every request the API origin saw, in order

const api = http.createServer((req, res) => {
    const name = (req.url || '').replace(/^\/case\//, '').split('?')[0];
    log.push({
        name,
        method: req.method,
        origin: req.headers.origin ?? null,
        acrm: req.headers['access-control-request-method'] ?? null,
        acrh: req.headers['access-control-request-headers'] ?? null,
        contentType: req.headers['content-type'] ?? null,
        cookie: req.headers.cookie ?? null,
        probe: req.headers['x-probe'] ?? null,
        // Every header the request actually carried, in wire order. The
        // preflight's whole shape is a fingerprint of its own: an OPTIONS that
        // arrives carrying the wrong set is no better than no OPTIONS at all.
        rawHeaders: req.rawHeaders.slice(),
    });
    const policy = (CASES.find((c) => c.name === name) || {}).policy || null;
    const h = { 'content-type': 'application/json' };
    const allowOrigin = policy === 'deny-origin' || policy === 'deny-origin-actual'
        ? 'https://example.invalid'
        : policy === 'wildcard' ? '*' : PAGE_ORIGIN;

    if (req.method === 'OPTIONS') {
        if (policy !== 'no-acao') h['access-control-allow-origin'] = allowOrigin;
        h['access-control-allow-methods'] = policy === 'deny-method' ? 'GET' : 'GET, POST, PUT, DELETE, PATCH';
        if (policy !== 'deny-header') h['access-control-allow-headers'] = 'content-type, x-probe, x-alpha, x-zeta';
        h['access-control-allow-credentials'] = 'true';
        if (policy === 'max-age') h['access-control-max-age'] = '600';
        res.writeHead(204, h);
        res.end();
        return;
    }
    if (policy !== 'no-acao' && policy !== 'no-acao-actual') {
        h['access-control-allow-origin'] = allowOrigin;
        // Not for the wildcard cases: `*` plus Allow-Credentials is exactly the
        // combination that must be refused, and sending both would let a lenient
        // engine look correct.
        if (policy !== 'wildcard') h['access-control-allow-credentials'] = 'true';
    }
    // A response header outside the CORS-safelisted set, so "can the page read
    // it" is a question with a visible answer.
    if (policy === 'expose-none' || policy === 'expose-named') {
        h['x-custom'] = '1';
        if (policy === 'expose-named') h['access-control-expose-headers'] = 'x-custom';
    }
    // The two no-cors guards need real subresource bodies rather than JSON.
    if (name.startsWith('img-')) {
        res.writeHead(200, { ...h, 'content-type': 'image/png' });
        res.end(PIXEL);
        return;
    }
    if (name.startsWith('script-')) {
        res.writeHead(200, { ...h, 'content-type': 'application/javascript' });
        res.end('window.__scriptRan = 1;');
        return;
    }
    res.writeHead(200, h);
    res.end(JSON.stringify({ ok: true, name }));
});

const PIXEL = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
    'base64',
);
await new Promise((r) => api.listen(0, '127.0.0.1', r));
const API_ORIGIN = `http://127.0.0.1:${api.address().port}`;

// The page origin. `localhost` and `127.0.0.1` are both loopback and both
// trustworthy, and they are *different origins*, so the same host can serve both
// halves without either engine treating the request as same-origin.
const PAGE_HOST = 'localhost';
let PAGE_ORIGIN = '';

const pageHtml = () => `<!DOCTYPE html><html><body><div id=out></div><script>
var API = ${JSON.stringify(API_ORIGIN)};
var out = [];
function xhr(method, url, headers, body) {
  return new Promise(function (resolve, reject) {
    var x = new XMLHttpRequest();
    x.open(method, url, true);
    for (var k in headers) x.setRequestHeader(k, headers[k]);
    x.onload = function () { resolve({ status: x.status, text: x.responseText }); };
    x.onerror = function () { reject(new Error('xhr error status=' + x.status)); };
    x.send(body);
  });
}
async function run(name, fn) {
  var U = API + '/case/' + name;
  try {
    var r = await fn(U);
    var text = r && typeof r.text === 'function' ? await r.text() : (r && r.text) || '';
    out.push({ name: name, outcome: 'ok', status: r && r.status, type: (r && r.type) || null, body: String(text).slice(0, 60) });
  } catch (e) {
    out.push({ name: name, outcome: 'threw', error: String((e && e.message) || e).slice(0, 120) });
  }
}
(async function () {
${CASES.map((c) => `  await run(${JSON.stringify(c.name)}, function (U) { return ${c.js}; });`).join('\n')}
  document.getElementById('out').textContent = '@@' + JSON.stringify(out) + '@@';
})();
setInterval(function () {}, 50);
</script></body></html>`;

const pageServer = http.createServer((_, res) => {
    res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
    res.end(pageHtml());
});
await new Promise((r) => pageServer.listen(0, '127.0.0.1', r));
const PAGE_URL = `http://${PAGE_HOST}:${pageServer.address().port}/`;
PAGE_ORIGIN = `http://${PAGE_HOST}:${pageServer.address().port}`;

const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));
try {
    const stale = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
    console.error(`port ${PORT} already serves CDP (${stale['Browser'] ?? '?'}) -- refusing to measure someone else's browser`);
    process.exit(2);
} catch (e) {
    if (e instanceof SyntaxError) throw e;
}

let proc, prof;
if (engine === 'chrome') {
    prof = await fs.mkdtemp(path.join(os.tmpdir(), 'cors-echo-'));
    const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`, '--no-first-run', '--no-default-browser-check', '--window-size=1920,1080'];
    if (!headed) args.push('--headless=new');
    proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
const engineLog = [];
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));
for (let i = 0; i < 300; i++) {
    try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(100); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
await cdp.send('Page.enable', {}, sessionId).catch(() => {});
await cdp.send('Page.navigate', { url: PAGE_URL }, sessionId);

let text = '';
const deadline = Date.now() + 45000;
while (Date.now() < deadline) {
    await sleep(250);
    try {
        const r = await cdp.send('Runtime.evaluate', {
            expression: "(document.getElementById('out')||{}).textContent||''",
            returnByValue: true,
        }, sessionId);
        text = r.result?.value || '';
        if (text.startsWith('@@')) break;
    } catch { /* context not up yet */ }
}
const page = text.startsWith('@@') ? JSON.parse(text.slice(2, -2)) : [];

const report = {
    engine,
    headed,
    pageOrigin: PAGE_ORIGIN,
    apiOrigin: API_ORIGIN,
    cases: CASES.map((c) => {
        const hits = log.filter((l) => l.name === c.name);
        const seen = page.find((p) => p.name === c.name) || { outcome: 'never-ran' };
        const preflight = hits.find((h) => h.method === 'OPTIONS');
        return {
            name: c.name,
            expect: c.expect,
            methods: hits.map((h) => h.method),
            acrm: preflight?.acrm ?? null,
            acrh: preflight?.acrh ?? null,
            origin: hits[0]?.origin ?? null,
            outcome: seen.outcome,
            status: seen.status ?? null,
            // `type` separates a refusal from an opaque response: both have an
            // unreadable body, only one of them rejected.
            type: seen.type ?? null,
            body: seen.body ?? null,
            error: seen.error ?? null,
        };
    }),
    requestLog: log,
};

const json = JSON.stringify(report, null, 1);
if (OUT) await fs.writeFile(OUT, json);
console.log(json);

cdp.close();
proc.kill('SIGKILL');
api.close();
pageServer.close();
if (prof) await fs.rm(prof, { recursive: true, force: true });
process.exit(0);
