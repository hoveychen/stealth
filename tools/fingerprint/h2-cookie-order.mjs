// Where `cookie` sits in the h2 header block -- and in what order the cookies
// inside it are listed -- for the four request shapes a guard actually watches.
//
//   node tools/fingerprint/h2-cookie-order.mjs chrome     [--out results/x.json]
//   node tools/fingerprint/h2-cookie-order.mjs lightpanda [--out results/x.json]
//   node tools/fingerprint/h2-cookie-order.mjs --diff a.json b.json
//
// h2-arms.mjs already measures header order, and missed this one for a simple
// reason: its page set never sets a cookie, so the field it was blind to was
// the field no request carried. This serves a page that sets one and then
// re-visits, so the navigation, the subresource, an XHR POST and a fetch POST
// all go out with a `cookie` in them.
//
// The answer that came out of it (Chrome 151, headless, 4/4 shapes): `cookie`
// is the last real field, with only `priority` behind it. Before the fix this
// engine put it first, right behind the pseudo headers, because the field came
// from curl's CURLOPT_COOKIE slot rather than from the ordered table.
//
// It measured only the field's *position* at first, and with one cookie in the
// jar every ordering rule agrees, so the second question was invisible: given
// several cookies, in what order does the value list them? The page here now
// reproduces the shape x-hyatt hands out -- four cookies set at once on the
// first response, two of them re-set by a later one -- because that is where
// the two engines part. Chrome sends the two that were overwritten *last*;
// this engine leaves them where they were first seen.
//
// Both engines meet a self-signed origin, so both are told to accept it:
// Chrome via --ignore-certificate-errors, lightpanda via --ca-cert. Neither
// switch touches request headers.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http2 from 'node:http2';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, sleep, personaScaleFlags } from './cdp.mjs';
import { selfSignedCert } from './h2-echo.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const arg = (n, d) => { const i = process.argv.indexOf(n); return i === -1 ? d : process.argv[i + 1]; };

// Compares the header *name sequence* per request, which is the fingerprint;
// values move with the ephemeral port and the run.
if (process.argv.includes('--diff')) {
    const i = process.argv.indexOf('--diff');
    const load = async (p) => {
        const j = JSON.parse(await fs.readFile(path.resolve(repo, p), 'utf8'));
        const m = new Map();
        // Last occurrence wins: the first visit has no cookie to send yet, and
        // the shape being measured is the one that carries one.
        for (const r of j.requests) m.set(`${r.method} ${r.path}`, r);
        return { m, engine: j.engine };
    };
    const [a, b] = [await load(process.argv[i + 1]), await load(process.argv[i + 2])];
    let differences = 0;
    for (const k of [...new Set([...a.m.keys(), ...b.m.keys()])].sort()) {
        const [ra, rb] = [a.m.get(k), b.m.get(k)];
        if (!ra || !rb) { console.log(`### ${k}\n  absent on the ${ra ? 'right' : 'left'}`); differences++; continue; }
        const [na, nb] = [ra.headers.map(([n]) => n), rb.headers.map(([n]) => n)];
        // Two orderings live in one request and they fail independently: where
        // the `cookie` field sits among the header names, and how the cookies
        // are sequenced inside its value. Report both under the same heading.
        //
        // Every `cookie` field is read, not just the first. h2 lets a client
        // split the cookie list across several fields -- RFC 9113 8.2.3 spells
        // it out, so that HPACK's dynamic table can hold one entry per cookie
        // -- and Chrome always does, one field per cookie. Reading field [0]
        // would report Chrome as sending a single cookie.
        const fields = (r) => r.headers.filter(([n]) => n.toLowerCase() === 'cookie').map(([, v]) => v);
        const names = (r) => fields(r).join('; ').split(';').map((c) => c.trim().split('=')[0]).filter(Boolean);
        const [ca, cb] = [names(ra), names(rb)];
        const [fa, fb] = [fields(ra).length, fields(rb).length];
        const fieldsSame = na.join('|') === nb.join('|');
        const cookiesSame = ca.join('|') === cb.join('|');
        if (fieldsSame && cookiesSame) {
            console.log(`### ${k}\n  same order (${na.length} fields, ${ca.length} cookies in ${fa} cookie field(s))`);
            continue;
        }
        differences++;
        console.log(`### ${k}`);
        if (!fieldsSame) {
            console.log(`  fields  left : ${na.join(' ')}\n  fields  right: ${nb.join(' ')}`);
            if (fa !== fb) console.log(`  cookie fields carrying ${ca.length}/${cb.length} cookies: left ${fa}, right ${fb}`);
        }
        if (!cookiesSame) console.log(`  cookies left : ${ca.join(' ')}\n  cookies right: ${cb.join(' ')}`);
    }
    console.log(`\n${differences} difference(s)`);
    process.exit(differences === 0 ? 0 : 1);
}

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: h2-cookie-order.mjs <chrome|lightpanda> [--out results/x.json]');
    console.error('       h2-cookie-order.mjs --diff <left.json> <right.json>');
    process.exit(2);
}
const PORT = Number(arg('--port', engine === 'chrome' ? 9340 : 9230));
const outPath = path.resolve(repo, arg('--out', `tools/fingerprint/results/h2-cookie-${engine}.json`));
const bin = process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda');

const PAGE = `<!doctype html><meta charset=utf-8><title>h2 cookie order</title>
<script>
document.cookie = 'SENSOR-ID=abcdefghijklmnop; path=/';
const post = (url, body, type) => new Promise((r) => {
  const x = new XMLHttpRequest();
  x.open('POST', url, true);
  if (type) x.setRequestHeader('Content-Type', type);
  x.onreadystatechange = () => { if (x.readyState === 4) r(x.status); };
  x.send(body);
});
(async () => {
  await fetch('/refresh');                                    // re-sets two of the four
  await post('/sensor', 'x'.repeat(2000));                    // the sensor's own shape
  await post('/sensor-json', '{"a":1}', 'application/json');
  await fetch('/sensor-fetch', { method: 'POST', body: 'y'.repeat(64) });
  window.__done = 1;
})();
</script>`;

// The cookies the first response plants, in this order and with this attribute
// mix, which is the one hyatt.com serves on its 429. All four share Path=/, so
// nothing here can be explained by RFC 6265's path-length rule.
const PLANT = [
    'a-ssn=1; Max-Age=86400; Path=/; HttpOnly; Secure; SameSite=None',
    'a=1; Max-Age=86400; Path=/; HttpOnly',
    'source-country=US; path=/',
    'source-region=CA; path=/',
];
// /refresh re-sets the first two under the same names and attributes. Every
// request after it carries all four, and the only question left is their order.
const REPLANT = [
    'a-ssn=2; Max-Age=86400; Path=/; HttpOnly; Secure; SameSite=None',
    'a=2; Max-Age=86400; Path=/; HttpOnly',
];
const setCookiesFor = (p) => (p === '/' ? PLANT : p === '/refresh' ? REPLANT : []);

const cert = await selfSignedCert();
const records = [];
const server = http2.createSecureServer({
    key: await fs.readFile(cert.key), cert: await fs.readFile(cert.cert), allowHTTP1: true,
});
// node:http2 hands the block over as a flat array in wire order; the normalised
// `headers` object has already lost the ordering.
server.on('stream', (stream, headers, flags, rawHeaders) => {
    const pairs = [];
    for (let i = 0; i < rawHeaders.length; i += 2) pairs.push([rawHeaders[i], rawHeaders[i + 1]]);
    records.push({ alpn: 'h2', method: headers[':method'], path: headers[':path'], headers: pairs });
    const html = headers[':path'] === '/';
    stream.respond({
        ':status': 200,
        'content-type': html ? 'text/html; charset=utf-8' : 'application/json',
        'set-cookie': setCookiesFor(headers[':path']),
    });
    stream.end(html ? PAGE : '{"ok":true}');
});
server.on('request', (req, res) => {
    // node emits `request` for h2 streams too once a listener exists, and the
    // stream handler has already answered those. Labelled, so a client that
    // declined h2 is visible as such rather than reading as "no requests".
    if (req.httpVersionMajor !== 1) return;
    const html = req.url === '/';
    records.push({ alpn: 'http/1.1', method: req.method, path: req.url,
        headers: req.rawHeaders.filter((_, i) => i % 2 === 0).map((h, i) => [h, req.rawHeaders[i * 2 + 1]]) });
    res.writeHead(200, {
        'content-type': html ? 'text/html; charset=utf-8' : 'application/json',
        'set-cookie': setCookiesFor(req.url),
    });
    res.end(html ? PAGE : '{"ok":true}');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `https://localhost:${server.address().port}`;

let proc, profile;
if (engine === 'chrome') {
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-h2-cookie-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new',
        '--ignore-certificate-errors',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(bin, ['serve', '--host', '127.0.0.1', '--port', String(PORT), '--ca-cert', cert.cert],
        { stdio: ['ignore', 'pipe', 'pipe'] });
}
// Drain both pipes: an unread pipe fills at 64KB and blocks the engine's next
// write for good, which from here looks exactly like a hang.
const log = [];
proc.stdout.on('data', (d) => log.push(String(d)));
proc.stderr.on('data', (d) => log.push(String(d)));

try {
    let up = false;
    for (let i = 0; i < 100; i++) {
        try { if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) { up = true; break; } } catch { /* retry */ }
        await sleep(150);
    }
    if (!up) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        ({ sessionId } = await newPage(cdp));
    }
    // Twice: the first visit has no cookie to send yet, the second does.
    await goto(cdp, sessionId, `${base}/`, { settleMs: 2500 });
    await goto(cdp, sessionId, `${base}/`, { settleMs: 2500 });
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    server.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
    await cert.rm();
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify({
        engine: engine === 'chrome' ? 'chrome-headless' : 'lightpanda',
        requests: records,
        log: log.join('').split('\n').filter(Boolean).slice(-15),
    }, null, 2) + '\n');
    const withCookie = records.filter((r) => r.headers.some(([n]) => n.toLowerCase() === 'cookie'));
    console.log(`wrote ${path.relative(repo, outPath)}`);
    console.log(`  ${records.length} requests, alpn=${[...new Set(records.map((r) => r.alpn))].join(',')}, ${withCookie.length} carrying a cookie`);
    process.exit(0);
}
