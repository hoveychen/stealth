// E1/E2/E3: read the round-robin trial snapshots written by antibot-sweep and
// answer three questions off one pile of runs.
//
// Why a tally rather than reading the runs by hand: a Cloudflare managed
// challenge is not a deterministic function of the client. The same engine at
// the same address answers differently minute to minute, so a single run is an
// anecdote and the only honest reading is a rate. The trials are interleaved
// (run-1-headed, run-1-headless, run-1-lightpanda, run-2-headed, …) so drift in
// how the edge treats this address over the sitting lands on all three columns
// instead of on whichever arm happened to run last.
//
//   PASS RATE   the verdict antibot-sweep already computed, per arm.
//   REQUESTS    the union of request paths per arm, so "headless never asks for
//               this" and "only lightpanda asks for this" are separate claims
//               rather than one impression from one run.
//
// usage: node tools/fingerprint/e1-tally.mjs [dir] [--requests] [--json out.json]
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const positional = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const DIR = path.resolve(REPO, positional[0] ?? 'tools/fingerprint/results/e1');
// Arm names come from the filenames, so a round can add an arm (an instrument
// under test, say `headed-attach`) without editing this file. Ordered as first
// seen, which is the round-robin order the trials ran in.
const ARMS = [];

// Collapse a URL to something comparable across runs: the per-request nonces in
// a challenge path are different every time, so the tail is what has to go.
function shape(url) {
    try {
        const u = new URL(url);
        const host = u.hostname;
        const segs = u.pathname.split('/').filter(Boolean);
        const kept = segs.map((s) => (
            // A challenge nonce is long and opaque; a route segment is short.
            s.length > 12 || /^[A-Za-z0-9_-]{12,}$/.test(s) ? '<n>' : s
        ));
        return `${host}/${kept.join('/')}`;
    } catch {
        return url.slice(0, 60);
    }
}

const runs = [];
for (const name of (await fs.readdir(DIR)).sort()) {
    if (!name.endsWith('.json')) continue;
    const m = /^run-(\d+)-([\w-]+)\.json$/.exec(name);
    if (!m) continue;
    if (!ARMS.includes(m[2])) ARMS.push(m[2]);
    const snap = JSON.parse(await fs.readFile(path.join(DIR, name), 'utf8'));
    const st = snap.stations?.[0];
    if (!st) continue;
    runs.push({
        trial: Number(m[1]), arm: m[2], file: name,
        verdict: st.verdict, first: st.first, last: st.last,
        title: st.title, ms: st.ms, ip: snap.ip?.ip ?? snap.ip?.loc ?? null,
        wire: st.wire ?? [],
    });
}

console.log(`=== E1 pass rate — ${runs.length} runs in ${path.relative(REPO, DIR)} ===\n`);
ARMS.sort();
const byArm = new Map(ARMS.map((a) => [a, []]));
for (const r of runs) byArm.get(r.arm)?.push(r);

for (const arm of ARMS) {
    const rs = byArm.get(arm) ?? [];
    if (!rs.length) continue;
    const pass = rs.filter((r) => r.verdict === 'pass').length;
    const tally = new Map();
    for (const r of rs) tally.set(r.verdict, (tally.get(r.verdict) ?? 0) + 1);
    console.log(`${arm.padEnd(11)} ${pass}/${rs.length} pass   ` +
        [...tally].map(([v, n]) => `${v}×${n}`).join(' '));
    for (const r of rs) {
        console.log(`   trial ${r.trial}  ${String(r.verdict).padEnd(14)} ` +
            `doc ${r.first}->${r.last}  ${String(r.title ?? '').slice(0, 52)}`);
    }
    console.log();
}

// --- request sets ---------------------------------------------------------
if (process.argv.includes('--requests')) {
    console.log('=== request paths, by arm (trials that carry a wire log) ===\n');
    const seen = new Map();   // shape -> { arm -> count of trials that had it }
    const trialsWithWire = new Map(ARMS.map((a) => [a, 0]));
    for (const r of runs) {
        if (!r.wire.length) continue;
        trialsWithWire.set(r.arm, (trialsWithWire.get(r.arm) ?? 0) + 1);
        const here = new Set();
        for (const w of r.wire) {
            if (w.ev !== 'req' || !w.url) continue;
            here.add(shape(w.url));
        }
        for (const s of here) {
            if (!seen.has(s)) seen.set(s, {});
            seen.get(s)[r.arm] = (seen.get(s)[r.arm] ?? 0) + 1;
        }
    }
    const width = Math.max(...[...seen.keys()].map((s) => s.length), 10);
    console.log(`${'path'.padEnd(width)}  ${ARMS.map((a) => a.slice(0, 9).padStart(10)).join('')}`);
    console.log(`${''.padEnd(width, '-')}  ${ARMS.map(() => '----------').join('')}`);
    const rows = [...seen].sort((a, b) => a[0].localeCompare(b[0]));
    for (const [s, counts] of rows) {
        const cells = ARMS.map((a) => `${counts[a] ?? 0}/${trialsWithWire.get(a) ?? 0}`.padStart(10)).join('');
        // A path only one arm ever asks for is the interesting kind.
        const arms = ARMS.filter((a) => counts[a]);
        console.log(`${s.padEnd(width)}  ${cells}${arms.length === 1 ? `   <- ${arms[0]} only` : ''}`);
    }
}

const JSON_OUT = arg('--json', null);
if (JSON_OUT) {
    const out = path.resolve(REPO, JSON_OUT);
    await fs.writeFile(out, JSON.stringify({ dir: path.relative(REPO, DIR), runs }, null, 1));
    console.log(`\nwrote ${path.relative(REPO, out)}`);
}
