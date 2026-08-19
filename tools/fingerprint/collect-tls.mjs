// Records the *transport* fingerprint — the ClientHello and the HTTP/2 preface
// — for one engine, by asking a third-party reflector what it saw on the wire.
//
//   node tools/fingerprint/collect-tls.mjs --engine chrome [--headed]
//   node tools/fingerprint/collect-tls.mjs --engine lightpanda
//   node tools/fingerprint/collect-tls.mjs --engine curl        (the raw dep, no browser)
//
// Nothing above the socket can see this layer, so unlike the rest of the
// harness the measurement has to come from the far end. tls.peet.ws/api/all
// echoes the parsed ClientHello (JA3, JA4, cipher and extension order, the
// supported-groups and signature-algorithm lists) plus the HTTP/2 SETTINGS
// frame, WINDOW_UPDATE, and pseudo-header order.
//
// Both browser engines reach it through an in-page `fetch`, not a navigation:
// the response is JSON, and the two engines disagree about how to render JSON
// into a DOM. `fetch` puts the same code path — the engine's own network stack
// — on both sides of the comparison.
//
// Repeats the request N times (--repeats, default 3). Chrome permutes its
// ClientHello extensions per connection, so a single JA3 sample says nothing
// about whether two engines agree; the set of distinct JA3s across repeats is
// the actual signal.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');

const arg = (name, fallback) => {
    const i = process.argv.indexOf(`--${name}`);
    return i === -1 ? fallback : process.argv[i + 1];
};
const engine = arg('engine', 'lightpanda');
const headed = process.argv.includes('--headed');
const repeats = Number(arg('repeats', '3'));
const url = arg('url', 'https://tls.peet.ws/api/all');
const label = engine === 'chrome' ? `chrome-${headed ? 'headed' : 'headless'}` : engine;
const outPath = path.resolve(repo, arg('out', `tools/fingerprint/results/tls-${label}.json`));

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = engine === 'chrome' ? 9334 : 9224;

// The fields worth diffing. tls.peet.ws returns a lot more (timestamps, the
// peer's IP, the full raw hex); keeping the shape narrow makes the diff
// readable and keeps run-to-run noise out of it.
function distill(all) {
    const tls = all.tls ?? {};
    const h2 = all.http2 ?? {};
    const frames = h2.sent_frames ?? [];
    const settings = frames.find((f) => f.frame_type === 'SETTINGS');
    const windowUpdate = frames.find((f) => f.frame_type === 'WINDOW_UPDATE');
    const headers = frames.find((f) => f.frame_type === 'HEADERS');
    return {
        http_version: all.http_version ?? null,
        ja3: tls.ja3 ?? null,
        ja3_hash: tls.ja3_hash ?? null,
        ja4: tls.ja4 ?? null,
        ja4_r: tls.ja4_r ?? null,
        peetprint: tls.peetprint ?? null,
        peetprint_hash: tls.peetprint_hash ?? null,
        tls_version_negotiated: tls.tls_version_negotiated ?? null,
        ciphers: tls.ciphers ?? null,
        extensions: (tls.extensions ?? []).map((e) => e.name),
        // The two lists a JA4 puts in its second half, kept unhashed so a diff
        // can point at *which* group or algorithm is off.
        supported_groups: (tls.extensions ?? []).find((e) => (e.name ?? '').startsWith('supported_groups'))
            ?.supported_groups ?? null,
        signature_algorithms: (tls.extensions ?? []).find((e) =>
            (e.name ?? '').startsWith('signature_algorithms'),
        )?.signature_algorithms ?? null,
        alpn: (tls.extensions ?? []).find((e) => (e.name ?? '').startsWith('application_layer_protocol'))
            ?.protocols ?? null,
        supported_versions: (tls.extensions ?? []).find((e) => (e.name ?? '').startsWith('supported_versions'))
            ?.versions ?? null,
        akamai_fingerprint: h2.akamai_fingerprint ?? null,
        akamai_fingerprint_hash: h2.akamai_fingerprint_hash ?? null,
        h2_settings: settings?.settings ?? null,
        h2_window_update: windowUpdate?.increment ?? null,
        h2_pseudo_header_order: headers?.headers
            ? headers.headers.filter((h) => h.startsWith(':')).map((h) => h.split(':')[1])
            : null,
        user_agent: all.user_agent ?? null,
    };
}

// Same expression for both engines. The page is first navigated to the
// reflector's own origin, because the reflector serves no CORS headers and a
// cross-origin fetch from about:blank is rejected before it reaches the socket.
// Returns a string so a JSON value that the engine's CDP layer can't
// round-trip (BigInt, functions) can't break the run.
const fetchExpr = (u) => `
(async () => {
  const r = await fetch(${JSON.stringify(u)}, { cache: 'no-store' });
  return JSON.stringify(await r.json());
})()`;

async function viaBrowser(bin, flags, isChrome) {
    const proc = spawn(bin, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
    const log = [];
    proc.stdout.on('data', (d) => log.push(String(d)));
    proc.stderr.on('data', (d) => log.push(String(d)));

    let version = null;
    try {
        for (let i = 0; i < 100; i++) {
            try {
                version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
                break;
            } catch {
                await sleep(200);
            }
        }
        if (!version) throw new Error(`${engine} CDP never came up`);

        const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
        let sessionId;
        if (isChrome) {
            // A fresh incognito context is not what a normal profile looks
            // like; Chrome doesn't need one, so don't add the difference.
            const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
            ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
        } else {
            // lightpanda allows exactly one browser context, so this page is
            // reused across every repeat.
            ({ sessionId } = await newPage(cdp));
            await cdp.send('Runtime.enable', {}, sessionId);
        }

        await goto(cdp, sessionId, new URL(url).origin + '/', { settleMs: 1000 });

        // Retried because lightpanda currently fails roughly every other
        // cross-request `fetch` to the same HTTPS origin with a bare
        // "TypeError: fetch error" (reproducible; see the transport section of
        // README.md). That is an engine bug in its own right, but it is not a
        // fingerprint difference, so the measurement works around it.
        const samples = [];
        for (let i = 0; i < repeats; i++) {
            let raw = null;
            let lastErr = null;
            for (let attempt = 0; attempt < 5 && raw === null; attempt++) {
                try {
                    raw = await evaluate(cdp, sessionId, fetchExpr(url), { awaitPromise: true });
                } catch (e) {
                    lastErr = e;
                    await sleep(700);
                }
            }
            if (raw === null) throw lastErr;
            samples.push(distill(JSON.parse(raw)));
            await sleep(500);
        }
        cdp.close();
        return { samples, version, log: log.join('').split('\n').filter(Boolean).slice(-20) };
    } finally {
        proc.kill('SIGKILL');
    }
}

// The raw dependency, with no lightpanda code in the path at all. Isolates
// "what does curl+BoringSSL look like by default" from "what did we change".
async function viaCurl() {
    const samples = [];
    for (let i = 0; i < repeats; i++) {
        const out = await new Promise((resolve, reject) => {
            const p = spawn('curl', ['-s', '--max-time', '30', url], { stdio: ['ignore', 'pipe', 'ignore'] });
            let buf = '';
            p.stdout.on('data', (d) => (buf += d));
            p.on('close', (code) => (code === 0 ? resolve(buf) : reject(new Error(`curl exit ${code}`))));
        });
        samples.push(distill(JSON.parse(out)));
        await sleep(300);
    }
    return { samples, version: { product: 'system curl' }, log: [] };
}

let result;
if (engine === 'chrome') {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-tls-chrome-'));
    const flags = [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
    ];
    if (!headed) flags.push('--headless=new');
    try {
        result = await viaBrowser(CHROME, flags, true);
    } finally {
        await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
    }
} else if (engine === 'curl') {
    result = await viaCurl();
} else {
    result = await viaBrowser(
        path.join(repo, 'zig-out/bin/lightpanda'),
        ['serve', '--host', '127.0.0.1', '--port', String(PORT)],
        false,
    );
}

// Which of the distilled fields actually moved between repeats. Chrome's
// extension permutation should show up here as ja3/ja3_hash varying while ja4
// (which sorts extensions) holds still.
const varying = [];
for (const key of Object.keys(result.samples[0])) {
    const seen = new Set(result.samples.map((s) => JSON.stringify(s[key])));
    if (seen.size > 1) varying.push({ field: key, distinct: seen.size });
}

const snapshot = { engine: label, url, repeats, varying, samples: result.samples, version: result.version, log: result.log };
await fs.mkdir(path.dirname(outPath), { recursive: true });
await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');

console.log(`${label}: ja4=${result.samples[0].ja4}`);
console.log(`${label}: ja3_hash=${result.samples[0].ja3_hash} (${varying.some((v) => v.field === 'ja3_hash') ? 'varies' : 'stable'} across ${repeats})`);
console.log(`${label}: akamai=${result.samples[0].akamai_fingerprint}`);
console.log(`wrote ${path.relative(repo, outPath)}`);
process.exit(0);
