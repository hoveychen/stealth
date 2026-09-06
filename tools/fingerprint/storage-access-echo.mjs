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
// `--scenario fetch-site` asks the third question the same rig can reach: what
// does `Sec-Fetch-Site` call each *kind* of not-same-origin? The fetch-mode
// capture already showed one cell of it -- two ports of one host, which Chrome
// calls `same-site` and this engine calls `cross-site` -- but two ports is only
// one of the three ways a URL can be same-site, and the other two (two
// subdomains of one registrable domain, and two schemes of one host) are the
// ones a real page actually hits. `localhost` cannot express a subdomain, so
// this scenario moves the top page onto `*.127-0-0-1.nip.io`, a wildcard DNS
// name that resolves every label to 127.0.0.1. Whether `nip.io` is a public
// suffix does not matter here: `www.127-0-0-1.nip.io` and `cdn.127-0-0-1.nip.io`
// share `127-0-0-1.nip.io`, which is one label above `nip.io` either way, so
// they are same-site under both readings.
//
// The https row needs a TLS listener, so this scenario generates a throwaway
// self-signed cert and runs Chrome with `--ignore-certificate-errors`. This
// engine has no such flag, so its https row is expected to be a cert failure
// rather than a header reading -- that half of the axis is a unit-test
// question, not a wire one.
//
// usage: node tools/fingerprint/storage-access-echo.mjs <chrome|lightpanda> [--headed-ua]
//          [--scenario storage-access|fetch-mode|fetch-site|blob-origin]
//          [--port n] [--http-port n] [--xsite-port n] [--out p]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
import tls from 'node:tls';
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
const SCENARIOS = ['storage-access', 'fetch-mode', 'fetch-site', 'blob-origin'];
if (!SCENARIOS.includes(SCENARIO)) {
    console.error(`unknown --scenario ${SCENARIO}`);
    process.exit(2);
}

// The fetch-site scenario needs a host with subdomains, which `localhost` has
// none of; everything under *.nip.io resolves to 127.0.0.1.
const SITE_HOST = 'www.127-0-0-1.nip.io';
const SITE_SIBLING = 'cdn.127-0-0-1.nip.io';
const SITE_PARENT = '127-0-0-1.nip.io';
const TLS_PORT = Number(arg('--tls-port', String(TOP_PORT + 3)));
// Chrome attaches Sec-Fetch-* only when the *request* URL's origin is
// potentially trustworthy, and a DNS name that happens to resolve to loopback
// is not one -- measured: over plain http every nip.io row came back with no
// Sec-Fetch-Site at all while the https and 127.0.0.1 rows carried one. So the
// site axis is measured over https by default, and `--top-scheme http` is kept
// for the scheme row, where the target is https and does carry the header.
const TOP_SCHEME = SCENARIO === 'fetch-site' ? arg('--top-scheme', 'https') : 'http';
const OTHER_SCHEME = TOP_SCHEME === 'https' ? 'http' : 'https';

const TOP = SCENARIO === 'fetch-site'
    ? `${TOP_SCHEME}://${SITE_HOST}:${TOP_PORT}`
    // 127.0.0.1 rather than `localhost` for blob-origin, because that scenario
    // reads which headers Chrome attaches and Chrome attaches none of them to a
    // URL that is not potentially trustworthy. Both loopback forms qualify;
    // the literal is the one this rig can bind on one family only.
    : SCENARIO === 'blob-origin'
        ? `http://127.0.0.1:${TOP_PORT}`
        : `http://localhost:${TOP_PORT}`;
const XSITE = SCENARIO === 'fetch-site'
    ? `${TOP_SCHEME}://127.0.0.1:${XSITE_PORT}`
    : `http://127.0.0.1:${XSITE_PORT}`;
// A third origin for the fetch-mode scenario only: same host as TOP, another
// port. Cross-ORIGIN but SAME-site, which is the one axis TOP/XSITE cannot
// separate -- and the two candidate rules for Origin (cross-origin, as the
// Fetch spec writes it, or cross-site, as Sec-Fetch-Site reports it) disagree
// exactly here.
const XORIGIN_PORT = Number(arg('--xorigin-port', String(TOP_PORT + 2)));
const XORIGIN = SCENARIO === 'fetch-site'
    ? `${TOP_SCHEME}://${SITE_HOST}:${XORIGIN_PORT}`
    : `http://localhost:${XORIGIN_PORT}`;

// One row per way of not being same-origin. Every one of these but the last is
// same-site with TOP by the spec's definition (schemefully same site =
// registrable domain plus scheme); `same` and `xsite` are the two controls that
// pin the ends of the scale.
const FETCH_SITE_CASES = [
    { label: 'same-origin', url: `${TOP}/s/same-origin` },
    { label: 'other-port', url: `${XORIGIN}/s/other-port` },
    { label: 'sibling-subdomain', url: `${TOP_SCHEME}://${SITE_SIBLING}:${TOP_PORT}/s/sibling-subdomain` },
    { label: 'parent-domain', url: `${TOP_SCHEME}://${SITE_PARENT}:${TOP_PORT}/s/parent-domain` },
    { label: 'other-scheme', url: `${OTHER_SCHEME}://${SITE_HOST}:${TLS_PORT}/s/other-scheme` },
    { label: 'cross-site', url: `${XSITE}/s/cross-site` },
];

const FETCH_SITE_PAGE = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>fetch-site</title></head>
<body>fetch-site
<script>
var CASES = ${JSON.stringify(FETCH_SITE_CASES)};
CASES.forEach(function (c) {
    // no-cors, because nothing here answers with CORS headers and the request
    // that goes out is the whole point.
    try { fetch(c.url, { mode: 'no-cors' }).catch(function () { }); } catch (e) { }
});
</script>
</body></html>`;


// Where a request's client sits, crossed against how that client was made.
// The live cf-scrapingcourse capture has exactly one request Chrome sends with
// no `sec-ch-ua*` at all, no `Referer`, and a `cache-control: max-age=0` no
// other request carries -- and it is the one whose document is a
// `blob:https://challenges.cloudflare.com/<uuid>`. Three candidate rules fit
// that one row (it is a blob-URL client; it is a worker; the fetch passed
// options), and one row cannot separate them, so this page runs all of them.
const BLOB_CASES = [
    'top-plain',            // the control: an ordinary fetch from the top document
    'top-reload',           // ... with each RequestInit `cache` value, which is
    'top-no-cache',         //     the third candidate for the cache-control the
    'top-no-store',         //     live capture carried
    'top-force-cache',
    'top-no-referrer',      // ... with referrerPolicy:'no-referrer'
    'blob-iframe',          // a document loaded from a blob: URL
    'blob-worker',          // a dedicated worker whose script is a blob: URL
    'url-worker',           // ... and the same worker from an http: URL
];

// The worker body, served both ways: from a blob: URL the page mints, and from
// this path, so that "is a worker" and "was made from a blob" are two axes
// rather than one.
const workerBody = (label) => `fetch(TOP_URL + '/b/${label}').then(function (r) { return r.text(); });`
    .replace('TOP_URL', JSON.stringify(TOP));

const BLOB_PAGE = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>blob-origin</title></head>
<body>blob-origin
<script>
var TOP = ${JSON.stringify(TOP)};
function go(label, init) {
    try { fetch(TOP + '/b/' + label, init).catch(function () { }); } catch (e) { }
}
go('top-plain');
go('top-reload', { cache: 'reload' });
go('top-no-cache', { cache: 'no-cache' });
go('top-no-store', { cache: 'no-store' });
go('top-force-cache', { cache: 'force-cache' });
go('top-no-referrer', { referrerPolicy: 'no-referrer' });

// A document whose URL is a blob:. Its fetch is same-origin with TOP, because a
// blob URL keeps the origin it was minted from.
try {
    var frameHtml = '<!DOCTYPE html><html><body><scr' + 'ipt>'
        + 'fetch(' + JSON.stringify(TOP + '/b/blob-iframe') + ').catch(function(){});'
        + '</scr' + 'ipt></body></html>';
    var f = document.createElement('iframe');
    f.src = URL.createObjectURL(new Blob([frameHtml], { type: 'text/html' }));
    document.body.appendChild(f);
} catch (e) { }

try {
    var src = URL.createObjectURL(new Blob([${JSON.stringify(workerBody('blob-worker'))}],
        { type: 'text/javascript' }));
    new Worker(src);
} catch (e) { }
try { new Worker(TOP + '/w/url-worker.js'); } catch (e) { }
<\/script>
</body></html>`;

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
        if (SCENARIO === 'fetch-mode') return FETCH_MODE_PAGE;
        if (SCENARIO === 'fetch-site') return FETCH_SITE_PAGE;
        if (SCENARIO === 'blob-origin') return BLOB_PAGE;
        return TOP_PAGE;
    }
    if (who === 'top' && target.startsWith('/samesiteframe')) return framePage('same-origin-frame');
    if (who === 'top' && target.startsWith('/w/')) return null;
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
    // A worker script has to arrive as JavaScript or the browser refuses it.
    const script = target.startsWith('/w/') ? workerBody('url-worker') : null;
    const body = Buffer.from(html ?? script ?? 'ok');
    const type = html ? 'text/html; charset=utf-8'
        : script ? 'text/javascript; charset=utf-8'
            : 'text/plain';
    sock.write(`HTTP/1.1 200 OK\r\n`
        + `Content-Type: ${type}\r\n`
        + `Content-Length: ${body.length}\r\n`
        + `Connection: keep-alive\r\n\r\n`);
    sock.write(body);
}

/// One listener. TOP needs two of them -- one per loopback family -- because
/// `localhost` resolves to both and the browser picks.
function wire(who, sock) {
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
}

function listen(who, port, host) {
    const server = net.createServer((sock) => wire(who, sock));
    return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => resolve(server));
    });
}

/// The https half of the scheme axis. A throwaway self-signed cert is enough:
/// the browser arm runs with --ignore-certificate-errors, and what is being
/// read is the request header, not the handshake.
let certPromise = null;
function selfSignedCert() {
    certPromise ??= (async () => {
        const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-tls-'));
        await new Promise((resolve, reject) => {
            const p = spawn('openssl', [
                'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-keyout', path.join(dir, 'k.pem'), '-out', path.join(dir, 'c.pem'),
                '-subj', `/CN=${SITE_HOST}`,
                '-addext', `subjectAltName=DNS:${SITE_HOST},DNS:${SITE_SIBLING},`
                    + `DNS:${SITE_PARENT},IP:127.0.0.1`,
            ], { stdio: 'ignore' });
            p.on('error', reject);
            p.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`openssl exited ${code}`))));
        });
        return {
            key: await fs.readFile(path.join(dir, 'k.pem')),
            cert: await fs.readFile(path.join(dir, 'c.pem')),
        };
    })();
    return certPromise;
}

async function listenTls(who, port, host) {
    const server = tls.createServer(await selfSignedCert(), (sock) => wire(who, sock));
    return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => resolve(server));
    });
}

// The site axis runs over https (see TOP_SCHEME), so its listeners are TLS ones
// -- all but the odd-scheme port, which is by construction the other kind.
const main = TOP_SCHEME === 'https' ? listenTls : listen;
const other = OTHER_SCHEME === 'https' ? listenTls : listen;
const servers = [
    await main('top', TOP_PORT, '127.0.0.1'),
    await main('top', TOP_PORT, '::1').catch(() => null),
    await main('xsite', XSITE_PORT, '127.0.0.1'),
    ...(SCENARIO === 'fetch-mode' || SCENARIO === 'fetch-site' ? [
        await main('xorig', XORIGIN_PORT, '127.0.0.1'),
        await main('xorig', XORIGIN_PORT, '::1').catch(() => null),
    ] : []),
    ...(SCENARIO === 'fetch-site' ? [await other('other', TLS_PORT, '127.0.0.1')] : []),
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

const state = {
    engine, headedUa, scenario: SCENARIO, userAgentOverride: null,
    top: TOP, xsite: XSITE, topScheme: TOP_SCHEME, hits,
    ...(SCENARIO === 'fetch-site' ? { cases: FETCH_SITE_CASES } : {}),
};
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
        // Only the scheme axis needs it, and only because the https listener is
        // self-signed; keep it off every other run.
        ...(SCENARIO === 'fetch-site' ? ['--ignore-certificate-errors'] : []),
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
if (SCENARIO === 'blob-origin') {
    const seen = new Map();
    for (const h of hits) {
        if (h.mark || !h.target.startsWith('/b/')) continue;
        seen.set(h.target.slice('/b/'.length), h);
    }
    for (const label of BLOB_CASES) {
        const h = seen.get(label);
        if (!h) { console.log(`  ${label.padEnd(16)} (never reached the wire)`); continue; }
        const g = (n) => get(h.headers, n);
        const hints = h.headers.map(([k]) => k.toLowerCase()).filter((k) => k.startsWith('sec-ch-'));
        console.log(`  ${label.padEnd(16)}`
            + ` site=${String(g('sec-fetch-site')).padEnd(11)}`
            + ` dest=${String(g('sec-fetch-dest')).padEnd(7)}`
            + ` hints=${String(hints.length).padEnd(3)}`
            + ` cache-control=${(g('cache-control') ?? '(absent)').padEnd(11)}`
            + ` referer=${g('referer') ?? '(absent)'}`);
    }
} else if (SCENARIO === 'fetch-site') {
    const byPath = new Map();
    for (const h of hits) {
        if (h.mark || !h.target.startsWith('/s/')) continue;
        byPath.set(h.target, h);
    }
    for (const c of FETCH_SITE_CASES) {
        const h = byPath.get(new URL(c.url).pathname);
        const origin = h && get(h.headers, 'origin');
        console.log(`  ${c.label.padEnd(20)}`
            + (h
                ? ` site=${String(get(h.headers, 'sec-fetch-site')).padEnd(12)}`
                    + ` host=${String(get(h.headers, 'host')).padEnd(28)}`
                    + ` origin=${origin === undefined ? '(absent)' : origin}`
                : ' (never reached the wire)'));
    }
} else if (SCENARIO === 'fetch-mode') {
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
