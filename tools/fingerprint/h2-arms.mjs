// Drives one engine at the local HTTP/2 echo and writes the wire header list.
//
//   node tools/fingerprint/h2-arms.mjs chrome [--chrome-arg SWITCH]...
//   node tools/fingerprint/h2-arms.mjs lightpanda [--h1]
//   node tools/fingerprint/h2-arms.mjs --diff a.json b.json
//
// This is the h2 counterpart of the localHeaders step in collect-chrome.mjs and
// collect-lightpanda.mjs. It exists separately because the thing it measures --
// header order and per-destination `priority` over a real HPACK block -- is
// invisible to the plaintext h1 echo those two use.
//
// `--h1` points the same driver at header-echo.mjs, the plaintext h1 echo, so
// an h1/h2 pair is one switch apart instead of a full collect-* run: the
// collectors reach live sites on their other steps, which is far more than a
// header question needs.
//
// Over h2 both engines are pointed at a self-signed origin, so both need to be
// told to accept it: Chrome via --ignore-certificate-errors, lightpanda via
// --ca-cert. Neither switch touches the request headers, which is what is being
// measured, and neither is passed in `--h1` mode.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, sleep } from './cdp.mjs';
import { startH2Echo, selfSignedCert } from './h2-echo.mjs';
import { startEchoServer } from './header-echo.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i === -1 ? fallback : process.argv[i + 1];
};

// A pure-diff mode, so a before/after pair can be compared without re-running
// either arm. Prints one block per request path.
if (process.argv.includes('--diff')) {
    const i = process.argv.indexOf('--diff');
    const [left, right] = [process.argv[i + 1], process.argv[i + 2]];
    const load = async (p) => {
        const j = JSON.parse(await fs.readFile(path.resolve(repo, p), 'utf8'));
        const m = new Map();
        // First occurrence wins: a repeated path (images get re-requested) would
        // otherwise make the diff depend on which one landed last.
        for (const r of j.requests) if (!m.has(`${r.method} ${r.path}`)) m.set(`${r.method} ${r.path}`, r);
        return { m, engine: j.engine };
    };
    const [a, b] = [await load(left), await load(right)];
    console.log(`left  ${left}  engine=${a.engine}`);
    console.log(`right ${right}  engine=${b.engine}\n`);
    let differences = 0;
    for (const k of [...new Set([...a.m.keys(), ...b.m.keys()])].sort()) {
        const [ra, rb] = [a.m.get(k), b.m.get(k)];
        console.log(`### ${k}`);
        if (!ra || !rb) {
            console.log(`  absent on the ${ra ? 'right' : 'left'}`);
            differences++;
            continue;
        }
        const [na, nb] = [ra.headers.map(([n]) => n), rb.headers.map(([n]) => n)];
        if (na.join('|') !== nb.join('|')) {
            console.log(`  order left : ${na.join(' | ')}`);
            console.log(`  order right: ${nb.join(' | ')}`);
            differences++;
        }
        for (const [n, v] of ra.headers) {
            // The ephemeral port moves every run; it is not a fingerprint.
            if (n === ':authority' || n === 'referer') continue;
            const bv = (rb.headers.find(([x]) => x === n) ?? [])[1];
            if (bv !== v) {
                console.log(`  ${n}\n    left : ${v}\n    right: ${bv}`);
                differences++;
            }
        }
    }
    console.log(`\n${differences} difference(s)`);
    process.exit(differences === 0 ? 0 : 1);
}

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: h2-arms.mjs <chrome|lightpanda> [--h1] [--chrome-arg SWITCH]... [--out results/x.json]');
    console.error('       h2-arms.mjs --diff <left.json> <right.json>');
    process.exit(2);
}
const h1 = process.argv.includes('--h1');
const chromeArgs = process.argv.reduce(
    (acc, a, i) => (a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc),
    [],
);
const PORT = Number(arg('--port', engine === 'chrome' ? 9338 : 9228));
const outPath = path.resolve(repo, arg('--out', `tools/fingerprint/results/${h1 ? 'h1' : 'h2'}-${engine}.json`));
// LP_BIN so a worktree can measure with a chosen build; without it a worktree
// run would silently measure whichever binary sits in its own zig-out.
const bin = process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda');

const cert = h1 ? null : await selfSignedCert();
const echo = h1 ? await startEchoServer(0) : await startH2Echo(0, cert);
const base = h1 ? `http://localhost:${echo.port}` : `https://localhost:${echo.port}`;

let proc, profile;
if (engine === 'chrome') {
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-h2-chrome-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--headless=new',
        ...(h1 ? [] : ['--ignore-certificate-errors']),
        ...chromeArgs,
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(bin, [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
        ...(h1 ? [] : ['--ca-cert', cert.cert]),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
}

// Drain both pipes: an unread pipe fills at 64KB and blocks the engine's next
// write for good, which from here looks exactly like a hang.
const log = [];
const keep = (d) => {
    log.push(String(d));
    if (log.length > 4000) log.splice(0, 2000);
};
proc.stdout.on('data', keep);
proc.stderr.on('data', keep);

try {
    let version = null;
    for (let i = 0; i < 100; i++) {
        try {
            version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!version) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        // No incognito context: it is not what a normal profile looks like, and
        // Chrome does not need one.
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        ({ sessionId } = await newPage(cdp));
        await cdp.send('Runtime.enable', {}, sessionId);
    }

    // Two navigations: the second one reaches a warm connection, which is where
    // a navigation's own priority hint is easiest to read without the
    // first-connection handshake in the way.
    await goto(cdp, sessionId, `${base}/`, { settleMs: 3000 });
    await goto(cdp, sessionId, `${base}/nav`, { settleMs: 1500 });
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    await echo.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
    if (cert) await cert.rm();
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify({
        engine: engine === 'chrome'
            ? `chrome-headless${chromeArgs.some((a) => a.startsWith('--user-agent=')) ? '-ua' : ''}`
            : 'lightpanda',
        chromeArgs,
        requests: echo.records,
        log: log.join('').split('\n').filter(Boolean).slice(-25),
    }, null, 2) + '\n');
    const alpns = [...new Set(echo.records.map((r) => r.alpn ?? 'http/1.1'))].join(',');
    const withPriority = echo.records.filter((r) => r.headers.some(([n]) => n === 'priority')).length;
    console.log(`wrote ${path.relative(repo, outPath)}`);
    console.log(`  ${echo.records.length} requests, alpn=${alpns}, priority on ${withPriority}/${echo.records.length}`);
    process.exit(0);
}
