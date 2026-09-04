// What does an engine do when an origin asks for high-entropy client hints?
//
// Cloudflare's managed challenge answers the 403 interstitial with *both*
// `Accept-CH` and `Critical-CH` naming nine hints, and E2 found that every
// subsequent Chrome request to that origin then carries all nine while this
// engine keeps sending the low-entropy three. `Critical-CH` is the stronger of
// the two: it tells the client to throw the response away and retry the request
// immediately with the hints attached, so a missing implementation costs both
// the headers *and* the retry.
//
// This serves Cloudflare's exact hint list off localhost (a trustworthy origin,
// so hints are allowed) and records the byte-exact request head of every hit.
// Two pages, because the two halves of the mechanism are separable:
//
//   /accept-ch    Accept-CH only    -> hints appear on the *next* request
//   /critical-ch  Accept-CH + Critical-CH -> the same request is retried at once
//
// The raw-socket server is header-echo.mjs's, for the same reason: node:http
// reorders headers and order is part of what is being measured.
//
// usage: node tools/fingerprint/accept-ch-echo.mjs <lightpanda|chrome> [--headed-ua] [--hints list] [--out p]
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
    console.error('usage: accept-ch-echo.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const HTTP_PORT = Number(arg('--http-port', '9586'));
const CDP_PORT = Number(arg('--port', engine === 'chrome' ? '9254' : '9255'));
const OUT = arg('--out', null);
const headedUa = has('--headed-ua');
const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Cloudflare's list, copied verbatim off the cf-mitigated=challenge response
// (results/cfsc-fo-oracle.json). The UA-* spellings without the Sec- prefix are
// the pre-standard names Cloudflare still asks for; kept so the ask is the same
// ask an engine would meet in the field.
// --hints overrides it, which is how another guard's ask gets measured: pass
// DataDome's list to see what an engine answers *that* origin. Two lists worth
// keeping to hand:
//
//   cloudflare  (the default below)
//   datadome    Sec-CH-UA,Sec-CH-UA-Mobile,Sec-CH-UA-Platform,Sec-CH-UA-Arch,
//               Sec-CH-UA-Full-Version-List,Sec-CH-UA-Model,Sec-CH-Device-Memory
const HINTS = arg('--hints', 'Sec-CH-UA-Bitness, Sec-CH-UA-Arch, Sec-CH-UA-Full-Version, '
    + 'Sec-CH-UA-Mobile, Sec-CH-UA-Model, Sec-CH-UA-Platform-Version, '
    + 'Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform, Sec-CH-UA, '
    + 'UA-Bitness, UA-Arch, UA-Full-Version, UA-Mobile, UA-Model, '
    + 'UA-Platform-Version, UA-Platform, UA');

const PAGE = (label) => `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${label}</title></head>
<body>${label}
<script>
// A same-origin subresource and an XHR, so "the hints arrive on the next
// request" can be seen without depending on a second navigation.
fetch('/sub/fetch-' + ${JSON.stringify(label)}).then(function (r) { return r.text(); });
var x = new XMLHttpRequest(); x.open('POST', '/sub/xhr-' + ${JSON.stringify(label)}, true);
x.setRequestHeader('content-type', 'text/plain;charset=UTF-8'); x.send('probe');
</script>
</body></html>`;

const hits = [];

const server = net.createServer((sock) => {
    let buf = Buffer.alloc(0);
    sock.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = buf.subarray(0, end).toString('latin1');
        buf = buf.subarray(end + 4);
        const lines = head.split('\r\n');
        const [method, target] = lines[0].split(' ');
        hits.push({
            n: hits.length,
            method,
            target,
            // Order preserved and names left exactly as they arrived: casing and
            // position are both part of what is being compared.
            headers: lines.slice(1).map((l) => {
                const i = l.indexOf(':');
                return [l.slice(0, i), l.slice(i + 1).trim()];
            }),
        });

        const isCritical = target.startsWith('/critical-ch');
        const isPage = target.startsWith('/accept-ch') || isCritical;
        const body = Buffer.from(isPage ? PAGE(isCritical ? 'critical-ch' : 'accept-ch') : 'ok');
        const extra = isPage
            ? `Accept-CH: ${HINTS}\r\n` + (isCritical ? `Critical-CH: ${HINTS}\r\nVary: ${HINTS}\r\n` : '')
            : '';
        sock.write(`HTTP/1.1 200 OK\r\n`
            + `Content-Type: ${isPage ? 'text/html; charset=utf-8' : 'text/plain'}\r\n`
            + `Content-Length: ${body.length}\r\n`
            + extra
            + `Connection: keep-alive\r\n\r\n`);
        sock.write(body);
    });
    sock.on('error', () => { });
});
await new Promise((r) => server.listen(HTTP_PORT, '127.0.0.1', r));

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

const state = { engine, headedUa, userAgentOverride: null, hits };
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

    for (const p of ['/critical-ch', '/accept-ch']) {
        hits.push({ mark: p });
        await cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP_PORT}${p}` }, sessionId);
        await sleep(2500);
    }
    // A second visit to the same origin: whatever hint state the engine kept
    // from the first two pages shows up on this navigation.
    hits.push({ mark: '/revisit' });
    await cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP_PORT}/revisit` }, sessionId);
    await sleep(2000);
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    server.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
for (const h of hits) {
    if (h.mark) { console.log(`--- navigate ${h.mark}`); continue; }
    const ch = h.headers.filter(([k]) => /^(sec-ch|ua-)/i.test(k));
    console.log(`  ${h.method} ${h.target}  hints=${ch.length}`);
    for (const [k, v] of ch) console.log(`      ${k}: ${v}`);
}
if (state.error) console.log(`ERROR ${state.error}`);

if (OUT) {
    const out = path.resolve(REPO, OUT.startsWith('tools/') ? OUT : path.join('tools/fingerprint', OUT));
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.writeFile(out, JSON.stringify(state, null, 1));
    console.log(`wrote ${out}`);
}
