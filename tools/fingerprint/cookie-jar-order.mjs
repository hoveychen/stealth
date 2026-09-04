// In what order does the jar list its cookies, and what moves one of them.
//
//   node tools/fingerprint/cookie-jar-order.mjs chrome      [--case B] [--out results/x.json]
//   node tools/fingerprint/cookie-jar-order.mjs lightpanda  [--case B] [--out results/x.json]
//   node tools/fingerprint/cookie-jar-order.mjs --diff a.json b.json
//
// h2-cookie-order.mjs answers where the `cookie` field sits in the header block
// and how many fields carry it. This answers the third question underneath
// those two: given a jar with several cookies, which order does a request list
// them in, and what changes it.
//
// It exists because one observation there did not fit any rule. Plant four
// cookies in one response, re-set two of them later, and Chrome moves the two
// that were re-set to the back -- which looks exactly like "an overwrite
// refreshes the creation time", so that RFC 6265's sort (path length
// descending, then creation time ascending) puts them last. But re-set all
// four and nothing moves at all, which that rule cannot produce. So the
// difference is not "was it overwritten"; it is something about *which*
// cookies these are, or about how the overwrite arrived.
//
// Hence a matrix rather than a single page: every case plants three cookies and
// overwrites exactly one, varying one property at a time. Each case gets its
// own engine process and its own profile, because a jar carries state across
// requests and a shared one would let case B read case A's leftovers.
//
// Both engines meet a self-signed https origin -- Chrome via
// --ignore-certificate-errors, lightpanda via --ca-cert -- so that `Secure` and
// `SameSite=None` mean what they mean on a real site. Neither switch touches
// cookie handling.
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

// Each case plants p1/p2/p3 in that order on the first response, then
// overwrites p1 -- by default through a subresource response, so the variable
// under test is the only thing that moves between cases.
//
// `plant` is the attribute tail each cookie carries; `replant` overrides the
// tail of the overwrite when the case is about the overwrite differing from
// the plant. `via` picks who does the overwriting.
const PERSISTENT = 'Max-Age=86400; Path=/';
const SESSION = 'Path=/';
const CASES = {
    // The control every other case is read against: three interchangeable
    // session cookies, one of them overwritten by a subresource.
    A: { why: 'baseline: three plain session cookies, p1 re-set by a subresource', plant: [SESSION, SESSION, SESSION], via: 'subresource' },
    B: { why: 'all three persistent', plant: [PERSISTENT, PERSISTENT, PERSISTENT], via: 'subresource' },
    C: { why: 'only the overwritten one is persistent', plant: [PERSISTENT, SESSION, SESSION], via: 'subresource' },
    D: { why: 'only the untouched ones are persistent', plant: [SESSION, PERSISTENT, PERSISTENT], via: 'subresource' },
    E: { why: 'the overwritten one is HttpOnly', plant: [`${SESSION}; HttpOnly`, SESSION, SESSION], via: 'subresource' },
    F: { why: 'the overwritten one is Secure; SameSite=None', plant: [`${SESSION}; Secure; SameSite=None`, SESSION, SESSION], via: 'subresource' },
    G: { why: 'the overwrite arrives on a navigation, not a subresource', plant: [SESSION, SESSION, SESSION], via: 'navigation' },
    H: { why: 'the overwrite comes from document.cookie', plant: [SESSION, SESSION, SESSION], via: 'script' },
    I: { why: 'the overwrite re-sets the same value', plant: [SESSION, SESSION, SESSION], via: 'subresource', sameValue: true },
    // No overwrite at all: reads the path-length half of RFC 6265's sort, which
    // every other case holds flat on purpose.
    J: { why: 'no overwrite; p2 sits on a longer path', plant: [SESSION, 'Path=/deep', SESSION], via: 'none', probe: '/deep/probe' },
};

if (process.argv.includes('--diff')) {
    const i = process.argv.indexOf('--diff');
    const load = async (p) => JSON.parse(await fs.readFile(path.resolve(repo, p), 'utf8'));
    const [a, b] = [await load(process.argv[i + 1]), await load(process.argv[i + 2])];
    const key = (r) => `${r.case} ${r.stage}`;
    const m = (j) => new Map(j.readings.map((r) => [key(r), r]));
    const [ma, mb] = [m(a), m(b)];
    let differences = 0;
    for (const k of [...new Set([...ma.keys(), ...mb.keys()])]) {
        const [ra, rb] = [ma.get(k), mb.get(k)];
        if (!ra || !rb) { console.log(`### ${k}\n  absent on the ${ra ? 'right' : 'left'}`); differences++; continue; }
        if (ra.order.join('|') === rb.order.join('|')) { console.log(`### ${k}\n  same: ${ra.order.join(' ')}`); continue; }
        differences++;
        console.log(`### ${k}\n  left : ${ra.order.join(' ')}\n  right: ${rb.order.join(' ')}`);
    }
    console.log(`\n${differences} difference(s)`);
    process.exit(differences === 0 ? 0 : 1);
}

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: cookie-jar-order.mjs <chrome|lightpanda> [--case B] [--out results/x.json]');
    console.error('       cookie-jar-order.mjs --diff <left.json> <right.json>');
    process.exit(2);
}
const only = arg('--case', null);
const basePort = Number(arg('--port', engine === 'chrome' ? 15700 : 15750));
const outPath = path.resolve(repo, arg('--out', `tools/fingerprint/results/cookie-jar-${engine}.json`));
const bin = process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda');
const cert = await selfSignedCert();

const page = (spec) => `<!doctype html><meta charset=utf-8><title>jar</title>
<script>
(async () => {
  ${spec.via === 'script' ? `document.cookie = 'p1=2; ${spec.plant[0]}';` : ''}
  ${spec.via === 'subresource' ? `await fetch('/refresh');` : ''}
  await fetch('${spec.probe ?? '/probe'}');
  ${spec.via === 'navigation' ? `location.href = '/renav';` : 'window.__done = 1;'}
})();
</script>`;
// After a navigation-borne overwrite the page has to ask again, so the reading
// is taken from a request that went out *after* the jar changed.
const renavPage = `<!doctype html><meta charset=utf-8><title>jar</title>
<script>fetch('/probe').then(() => { window.__done = 1; });</script>`;

async function runCase(name, index) {
    const spec = CASES[name];
    const readings = [];
    const server = http2.createSecureServer({
        key: await fs.readFile(cert.key), cert: await fs.readFile(cert.cert), allowHTTP1: true,
    });
    const value = spec.sameValue ? '1' : '2';
    const answer = (reqPath, respond) => {
        const cookie = [];
        let body = '';
        let type = 'application/json';
        if (reqPath === '/') {
            spec.plant.forEach((tail, i) => cookie.push(`p${i + 1}=1; ${tail}`));
            [body, type] = [page(spec), 'text/html; charset=utf-8'];
        } else if (reqPath === '/refresh' && spec.via === 'subresource') {
            cookie.push(`p1=${value}; ${spec.plant[0]}`);
        } else if (reqPath === '/renav') {
            cookie.push(`p1=${value}; ${spec.plant[0]}`);
            [body, type] = [renavPage, 'text/html; charset=utf-8'];
        }
        respond(type, cookie, body || '{}');
    };
    const record = (reqPath, header) => {
        if (!/probe/.test(reqPath)) return;
        const names = (header ?? '').split(';').map((c) => c.trim().split('=')[0]).filter(Boolean);
        readings.push({ case: name, why: spec.why, stage: readings.length === 0 ? 'after' : `after+${readings.length}`, order: names, raw: header ?? null });
    };
    server.on('stream', (stream, headers, flags, rawHeaders) => {
        const joined = [];
        for (let i = 0; i < rawHeaders.length; i += 2) if (rawHeaders[i].toLowerCase() === 'cookie') joined.push(rawHeaders[i + 1]);
        record(headers[':path'], joined.length ? joined.join('; ') : null);
        answer(headers[':path'].replace(/^\/deep/, '') === '/probe' ? '/probe' : headers[':path'], (type, cookie, body) => {
            stream.respond({ ':status': 200, 'content-type': type, 'set-cookie': cookie });
            stream.end(body);
        });
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const base = `https://localhost:${server.address().port}`;
    const PORT = basePort + index * 2;

    let proc, profile;
    if (engine === 'chrome') {
        profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-jar-'));
        proc = spawn(CHROME, [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
            '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new', '--ignore-certificate-errors'],
        { stdio: ['ignore', 'pipe', 'pipe'] });
    } else {
        proc = spawn(bin, ['serve', '--host', '127.0.0.1', '--port', String(PORT), '--ca-cert', cert.cert],
            { stdio: ['ignore', 'pipe', 'pipe'] });
    }
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
        await goto(cdp, sessionId, `${base}/`, { settleMs: 3000 });
        cdp.close();
    } finally {
        proc.kill('SIGKILL');
        server.close();
        if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    }
    return readings;
}

const names = only ? [only] : Object.keys(CASES);
const readings = [];
for (const [i, name] of names.entries()) {
    const got = await runCase(name, i);
    readings.push(...got);
    for (const r of got) console.log(`  ${r.case} ${r.stage.padEnd(8)} ${r.order.join(' ') || '(none)'}   ${r.why}`);
    if (!got.length) console.log(`  ${name} -- no probe request arrived`);
}
await cert.rm();
await fs.mkdir(path.dirname(outPath), { recursive: true });
await fs.writeFile(outPath, JSON.stringify({
    engine: engine === 'chrome' ? 'chrome-headless' : 'lightpanda', readings,
}, null, 2) + '\n');
console.log(`wrote ${path.relative(repo, outPath)}`);
