// Read `fo-reads.mjs` runs side by side: what the widget asked, and what each
// arm answered, up to the POST the answers went into.
//
// Two questions, one report:
//
//   * `--same <a.json> <b.json>` -- two runs of the *same* arm. A key whose
//     answers differ between runs is a variable-length contribution, and the
//     payload's run-to-run wobble is made of those.
//   * default -- one run per arm. A key whose answer differs in length is a
//     candidate for the byte gap between the arms; a key one arm reads and the
//     other never does is a candidate for all of it.
//
// Only the widget realm counts unless `--realm <substr>` says otherwise: the
// page-level POST is assembled somewhere else and its own length agrees.
//
// usage:
//   node tools/fingerprint/fo-reads-diff.mjs <a.json> <b.json>
//        [--realm substr] [--all-realms] [--after-send] [--show n]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const has = (n) => process.argv.includes(n);

const files = process.argv.slice(2).filter((a) => a.endsWith('.json'));
if (files.length !== 2) {
    console.error('usage: fo-reads-diff.mjs <a.json> <b.json> [--realm substr] [--all-realms]');
    process.exit(2);
}

const REALM = arg('--realm', 'challenges.cloudflare.com');
const ALL = has('--all-realms');
const AFTER = has('--after-send');
const SHOW = Number(arg('--show', '3'));

function load(f) {
    const abs = path.resolve(REPO, f.startsWith('tools/') || path.isAbsolute(f) ? f : path.join('tools/fingerprint', f));
    const j = JSON.parse(fs.readFileSync(abs, 'utf8'));
    // Rebuild the realm grouping from the raw records rather than trusting the
    // run's own summary -- the summary drops the reads themselves.
    const realms = new Map();
    for (const rec of j.records ?? []) {
        let r = realms.get(rec.r);
        if (!r) realms.set(rec.r, r = { rid: rec.r, href: '?', reads: [], firstSend: Infinity, sends: [] });
        if (rec.k === '@installed') { r.href = rec.href ?? '?'; r.worker = rec.worker; continue; }
        if (rec.k === '@send') { r.sends.push(rec.n); r.firstSend = Math.min(r.firstSend, rec.i); continue; }
        r.reads.push(rec);
    }
    const keep = [...realms.values()].filter((r) => ALL || r.href.includes(REALM));
    const byKey = new Map();
    for (const r of keep) {
        for (const rec of r.reads) {
            if (!AFTER && rec.i >= r.firstSend) continue;
            let a = byKey.get(rec.k);
            if (!a) byKey.set(rec.k, a = []);
            a.push(rec.v === undefined ? `<${rec.t}${rec.n !== undefined ? ':' + rec.n : ''}>` : rec.v);
        }
    }
    return { file: f, engine: j.engine, headedUa: j.headedUa, realms: keep, byKey };
}

const A = load(files[0]);
const B = load(files[1]);

const label = (x) => `${x.engine}${x.headedUa ? '+ua' : ''}(${path.basename(x.file)})`;
console.log(`A = ${label(A)}   realms=${A.realms.length}  keys=${A.byKey.size}`);
console.log(`B = ${label(B)}   realms=${B.realms.length}  keys=${B.byKey.size}`);
for (const x of [A, B]) {
    for (const r of x.realms) {
        console.log(`   ${path.basename(x.file)} realm ${r.rid} reads=${r.reads.length}`
            + ` before-send=${r.reads.filter((k) => k.i < r.firstSend).length}`
            + ` sends=[${r.sends.join(',')}]`);
    }
}

const bytes = (vals) => vals.reduce((s, v) => s + String(v).length, 0);
const keys = [...new Set([...A.byKey.keys(), ...B.byKey.keys()])].sort();

const rows = [];
for (const k of keys) {
    const a = A.byKey.get(k) ?? null;
    const b = B.byKey.get(k) ?? null;
    const same = a && b && a.length === b.length && a.every((v, i) => v === b[i]);
    if (same) continue;
    rows.push({
        k,
        an: a ? a.length : 0, bn: b ? b.length : 0,
        ab: a ? bytes(a) : 0, bb: b ? bytes(b) : 0,
        a: a ? a.slice(0, SHOW) : null,
        b: b ? b.slice(0, SHOW) : null,
    });
}
// Biggest text difference first: that is the order the byte gap is spent in.
rows.sort((x, y) => Math.abs(y.ab - y.bb) - Math.abs(x.ab - x.bb));

console.log(`\n${rows.length} keys differ (of ${keys.length} read)`);
console.log(`total text A=${[...A.byKey.values()].reduce((s, v) => s + bytes(v), 0)}`
    + `  B=${[...B.byKey.values()].reduce((s, v) => s + bytes(v), 0)}`);
for (const r of rows) {
    const only = r.an === 0 ? '  [B only]' : r.bn === 0 ? '  [A only]' : '';
    console.log(`\n${r.k}  calls A=${r.an} B=${r.bn}  text A=${r.ab} B=${r.bb} (${r.bb - r.ab >= 0 ? '+' : ''}${r.bb - r.ab})${only}`);
    if (r.a) console.log(`   A: ${r.a.map((v) => JSON.stringify(String(v)).slice(0, 160)).join(' ')}`);
    if (r.b) console.log(`   B: ${r.b.map((v) => JSON.stringify(String(v)).slice(0, 160)).join(' ')}`);
}
