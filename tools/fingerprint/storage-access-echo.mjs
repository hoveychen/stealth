// When does Chrome send `Sec-Fetch-Storage-Access`, and what does it say?
//
// Measured on the live cf-scrapingcourse challenge, a bare headless Chrome puts
// `sec-fetch-storage-access: active` on the cross-site Turnstile frame's
// navigation and on the three requests that frame then makes, and this engine
// sends the header nowhere at all -- a whole field name Chrome has and we do
// not. That capture only ever saw one shape, though, so it cannot say whether
// the header follows cross-*site*ness, or frame-ness, or something else, nor
// whether `active` is the only value.
//
// So this stands up the axes side by side on two loopback origins that are
// genuinely cross-site:
//
//   TOP    http://localhost:<port>
//   XSITE  http://127.0.0.1:<xsite-port>
//
// A different *host*, not just a different port -- `127.0.0.1` and `localhost`
// are different sites, where two ports on one host are merely different origins.
// `localhost` resolves to both ::1 and 127.0.0.1 here, and Chrome may pick
// either, so TOP listens on both.
//
// The top page then exercises, in one load:
//
//   nav        the top-level navigation itself
//   frame      a cross-site subframe, and its own same-origin subresource
//   samesite   a same-origin subframe, and its own subresource
//   sub        a same-origin fetch, a cross-site no-cors fetch, a cross-site img
//
// The raw-socket server is header-echo.mjs's, for its reason: node:http reorders
// headers, and order is part of what these captures are for.
//
// `--scenario fetch-mode` reuses the same two-origin rig for a different
// question, the way accept-ch-echo.mjs grew `--scenario frame`: what do
// `Sec-Fetch-Mode` and `Origin` follow? The storage-access page already showed
// that `fetch(u, {mode:'no-cors'})` reads `cors` here and `no-cors` in Chrome,
// which also grows an `Origin` Chrome does not send -- but that page varies mode
// and cross-siteness together and never varies the method at all, so it cannot
// say which of the three each field follows. This one crosses all three.
//
// usage: node tools/fingerprint/storage-access-echo.mjs <chrome|lightpanda> [--headed-ua]
//          [--scenario storage-access|fetch-mode]
//          [--port n] [--http-port n] [--xsite-port n] [--out p]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const has = (n) => process.argv.includes(n);

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: storage-access-echo.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const TOP_PORT = Number(arg('--http-port', '9590'));
const XSITE_PORT = Number(arg('--xsite-port', '9591'));
const CDP_PORT = Number(arg('--port', engine === 'chrome' ? '9264' : '9265'));
const OUT = arg('--out', null);
const headedUa = has('--headed-ua');
const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const SCENARIO = arg('--scenario', 'storage-access');
if (SCENARIO !== 'storage-access' && SCENARIO !== 'fetch-mode') {
    console.error(`unknown --scenario ${SCENARIO}`);
    process.exit(2);
}

const TOP = `http://localhost:${TOP_PORT}`;
const XSITE = `http://127.0.0.1:${XSITE_PORT}`;
// A third origin for the fetch-mode scenario only: same host as TOP, another
// port. Cross-ORIGIN but SAME-site, which is the one axis TOP/XSITE cannot
// separate -- and the two candidate rules for Origin (cross-origin, as the
// Fetch spec writes it, or cross-site, as Sec-Fetch-Site reports it) disagree
// exactly here.
const XORIGIN_PORT = Number(arg('--xorigin-port', String(TOP_PORT + 2)));
const XORIGIN = `http://localhost:${XORIGIN_PORT}`;

// Three axes, crossed, one fetch each. The label is the path, so the request log
// reads as the case name.
//
//   mode    the RequestInit member, plus `default` for not passing one at all
//   site    same-origin (TOP) or cross-site (XSITE)
//   method  GET, and a POST whose Content-Type is CORS-safelisted -- Origin is
//           specified to follow the method as well as the mode, and a page that
//           only ever GETs cannot see that half
//
// `mode:'same-origin'` is in here because this engine's Request.Mode has only
// navigate/no-cors/cors: if Chrome reports a fourth value there is nowhere to
// put it today. The cross-site cell of that row is a network error by
// construction -- what matters is whether the request reaches the wire at all.
const MODES = ['default', 'cors', 'no-cors', 'same-origin'];
const METHODS = ['GET', 'POST'];
const FETCH_MODE_CASES = [];
for (const mode of MODES) {
    for (const [site, base] of [['same', TOP], ['xorigin', XORIGIN], ['cross', XSITE]]) {
        for (const method of METHODS) {
            FETCH_MODE_CASES.push({
                path: `/m/${mode}-${site}-${method.toLowerCase()}`,
                url: `${base}/m/${mode}-${site}-${method.toLowerCase()}`,
                mode, site, method,
            });
        }
    }
}

const FETCH_MODE_PAGE = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>fetch-mode</title></head>
<body>fetch-mode
<script>
var CASES = ${JSON.stringify(FETCH_MODE_CASES)};
CASES.forEach(function (c) {
    var init = { method: c.method };
    if (c.mode !== 'default') init.mode = c.mode;
    // A CORS-safelisted content type, so the POST is a simple request and no
    // preflight comes first to confuse the log.
    if (c.method === 'POST') {
        init.body = 'x';
        init.headers = { 'Content-Type': 'text/plain' };
    }
    try {
        fetch(c.url, init).catch(function () { });
    } catch (e) { /* mode:'same-origin' cross-site throws for some engines */ }
});
</script>
</body></html>`;

const TOP_PAGE = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>top</title></head>
<body>top
<iframe src="${XSITE}/frame"></iframe>
<iframe src="${TOP}/samesiteframe"></iframe>
<img src="${XSITE}/img/cross-site" alt="">
<img src="${TOP}/img/same-origin" alt="">
<script>
fetch('${TOP}/sub/same-origin').then(function (r) { return r.text(); });
// no-cors, because nothing here answers with CORS headers and the point is the
// request that goes out, not the response that comes back.
//
// Three cross-site fetches that differ only in credentials. fetch defaults to
// same-origin, which cross-site means "send none" -- so if the header follows
// credentials rather than cross-siteness, only the include one carries it,
// and the img above (credentialed by default) does too.
fetch('${XSITE}/sub/cross-site-default', { mode: 'no-cors' });
fetch('${XSITE}/sub/cross-site-include', { mode: 'no-cors', credentials: 'include' });
fetch('${XSITE}/sub/cross-site-omit', { mode: 'no-cors', credentials: 'omit' });
</script>
</body></html>`;

const framePage = (label) => `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${label}</title></head>
<body>${label}
<script>
fetch('/sub/from-' + ${JSON.stringify(label)}).then(function (r) { return r.text(); });
// The frame reaching BACK to the top page's own site, credentialed. This is
// the row that says which of two rules the header follows: "the request's URL
// is cross-site with the top-level document" -- in which case this one is
// same-site with the top and carries nothing -- or "this request's client is
// in a third-party partition", in which case the cross-site frame carries it
// even when the target is the top's own site. Nothing in the P1 capture told
// these apart, because every credentialed request there had both properties
// or neither.
fetch('${TOP}/sub/back-to-top-from-' + ${JSON.stringify(label)},
      { mode: 'no-cors', credentials: 'include' });
</script>
</body></html>`;

const hits = [];

function pageFor(who, target) {
    if (who === 'top' && target.startsWith('/top')) {
        return SCENARIO === 'fetch-mode' ? FETCH_MODE_PAGE : TOP_PAGE;
    }
    if (who === 'top' && target.startsWith('/samesiteframe')) return framePage('same-origin-frame');
    if (who === 'xsite' && target.startsWith('/frame')) return framePage('cross-site-frame');
    return null;
}

function serve(who, sock, head) {
    const lines = head.split('\r\n');
    const [method, target] = lines[0].split(' ');
    hits.push({
        n: hits.length,
        who,
        method,
        target,
        headers: lines.slice(1).map((l) => {
            const i = l.indexOf(':');
            return [l.slice(0, i), l.slice(i + 1).trim()];
        }),
    });

    const html = pageFor(who, target);
    const body = Buffer.from(html ?? 'ok');
    sock.write(`HTTP/1.1 200 OK\r\n`
        + `Content-Type: ${html ? 'text/html; charset=utf-8' : 'text/plain'}\r\n`
        + `Content-Length: ${body.length}\r\n`
        + `Connection: keep-alive\r\n\r\n`);
    sock.write(body);
}

/// One listener. TOP needs two of them -- one per loopback family -- because
/// `localhost` resolves to both and the browser picks.
function listen(who, port, host) {
    const server = net.createServer((sock) => {
        let buf = Buffer.alloc(0);
        sock.on('data', (chunk) => {
            buf = Buffer.concat([buf, chunk]);
            let end;
            while ((end = buf.indexOf('\r\n\r\n')) !== -1) {
                const head = buf.subarray(0, end).toString('latin1');
                buf = buf.subarray(end + 4);
                serve(who, sock, head);
            }
        });
        sock.on('error', () => sock.destroy());
    });
    return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => resolve(server));
    });
}

const servers = [
    await listen('top', TOP_PORT, '127.0.0.1'),
    await listen('top', TOP_PORT, '::1').catch(() => null),
    await listen('xsite', XSITE_PORT, '127.0.0.1'),
    ...(SCENARIO === 'fetch-mode' ? [
        await listen('xorig', XORIGIN_PORT, '127.0.0.1'),
        await listen('xorig', XORIGIN_PORT, '::1').catch(() => null),
    ] : []),
].filter(Boolean);

async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ua-'));
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${CDP_PORT + 1}`, `--user-data-dir=${dir}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${CDP_PORT + 1}/json/version`)).json();
                if (ua) return ua.replace('HeadlessChrome', 'Chrome');
            } catch { /* not up yet */ }
            await sleep(200);
        }
        throw new Error('could not read the browser user agent');
    } finally {
        probe.kill('SIGKILL');
        await fs.rm(dir, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

const state = { engine, headedUa, scenario: SCENARIO, userAgentOverride: null, top: TOP, xsite: XSITE, hits };
if (headedUa) {
    if (engine !== 'chrome') { console.error('--headed-ua is a chrome arm'); process.exit(2); }
    state.userAgentOverride = await headedUserAgent();
}

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${CDP_PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ch-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new',
        ...(state.userAgentOverride ? [`--user-agent=${state.userAgentOverride}`] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(CDP_PORT)],
        { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', () => { });
proc.stderr.on('data', () => { });

let cdp = null;
try {
    for (let i = 0; i < 100; i++) {
        try {
            if ((await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).ok) break;
        } catch { /* not up */ }
        await sleep(250);
    }
    cdp = await Cdp.connect(`http://127.0.0.1:${CDP_PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Page.navigate', { url: `${TOP}/top` }, sessionId);
    await sleep(4000);

    // A cross-site page visited top-level, for the one axis the embed cannot
    // reach: is the header about being cross-site, or about being a subframe?
    // Only the storage-access page has that question; the fetch-mode one is
    // done once its fetches have gone out.
    if (SCENARIO === 'storage-access') {
        hits.push({ mark: 'XSITE visited top-level' });
        await cdp.send('Page.navigate', { url: `${XSITE}/frame` }, sessionId);
        await sleep(2500);
    }
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    for (const s of servers) s.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

const get = (h, name) => (h.find(([k]) => k.toLowerCase() === name) ?? [])[1];

console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''} ${SCENARIO} ===`);
console.log(`    TOP=${TOP}  XSITE=${XSITE}`);
if (SCENARIO === 'fetch-mode') {
    // By case rather than by arrival, so a case that never reached the wire is
    // a visible row rather than a missing one.
    const byPath = new Map();
    for (const h of hits) {
        if (h.mark || !h.target.startsWith('/m/')) continue;
        byPath.set(h.target, h);
    }
    for (const c of FETCH_MODE_CASES) {
        const h = byPath.get(c.path);
        const origin = h && get(h.headers, 'origin');
        console.log(`  ${`${c.mode}/${c.site}/${c.method}`.padEnd(28)}`
            + (h
                ? ` mode=${String(get(h.headers, 'sec-fetch-mode')).padEnd(12)}`
                    + ` site=${String(get(h.headers, 'sec-fetch-site')).padEnd(12)}`
                    + ` origin=${origin === undefined ? '(absent)' : origin}`
                : ' (never reached the wire)'));
    }
} else {
    for (const h of hits) {
        if (h.mark) { console.log(`--- ${h.mark}`); continue; }
        const sa = get(h.headers, 'sec-fetch-storage-access');
        console.log(`  [${h.who.padEnd(5)}] ${h.method.padEnd(4)} ${h.target.padEnd(28)}`
            + ` site=${String(get(h.headers, 'sec-fetch-site')).padEnd(11)}`
            + ` dest=${String(get(h.headers, 'sec-fetch-dest')).padEnd(9)}`
            + ` storage-access=${sa === undefined ? '(absent)' : sa}`);
    }
}
if (state.error) console.log(`ERROR ${state.error}`);

if (OUT) {
    const out = path.resolve(REPO, OUT.startsWith('tools/') ? OUT : path.join('tools/fingerprint', OUT));
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.writeFile(out, JSON.stringify(state, null, 1));
    console.log(`wrote ${out}`);
}
