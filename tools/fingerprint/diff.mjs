// Renders a markdown comparison of two snapshots produced by the collectors.
//
//   node tools/fingerprint/diff.mjs <candidate.json> <reference.json> [--out x.md]
//
// The candidate is lightpanda (before or after); the reference is real Chrome.
// Same script drives P2's before table and P7's after table, so the two are
// directly comparable.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const [candPath, refPath] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
if (!candPath || !refPath) {
    console.error('usage: diff.mjs <candidate.json> <reference.json> [--out out.md]');
    process.exit(2);
}
const outArg = process.argv.indexOf('--out');
const outPath = outArg !== -1 ? path.resolve(repo, process.argv[outArg + 1]) : null;

const read = async (p) => JSON.parse(await fs.readFile(path.resolve(repo, p), 'utf8'));
const cand = await read(candPath);
const ref = await read(refPath);

const fmt = (v) => {
    if (v === undefined) return '*(absent)*';
    if (v === null) return '`null`';
    if (typeof v === 'object' && v.__err) return `❌ throws: ${v.__err}`;
    if (typeof v === 'object' && v.__undefined) return '⚠️ `undefined`';
    const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
    return '`' + (s.length > 110 ? s.slice(0, 110) + '…' : s).replace(/\|/g, '\\|') + '`';
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const L = [];
L.push(`# Fingerprint comparison`);
L.push('');
L.push(`| | candidate | reference |`);
L.push(`|---|---|---|`);
L.push(`| engine | \`${cand.engine}\` | \`${ref.engine}\` |`);
L.push(`| build | \`${cand.version?.['Lightpanda-Version'] ?? cand.version?.Browser ?? '?'}\` | \`${ref.version?.Browser ?? '?'}\` |`);
L.push('');

// ---- 1. JS surface ---------------------------------------------------------
L.push(`## 1. JS fingerprint surface`);
L.push('');
const keys = [...new Set([...Object.keys(cand.steps.probe ?? {}), ...Object.keys(ref.steps.probe ?? {})])];
let matches = 0;
const rows = [];
for (const k of keys) {
    const a = cand.steps.probe?.[k];
    const b = ref.steps.probe?.[k];
    const ok = same(a, b);
    if (ok) matches++;
    rows.push(`| ${ok ? '✅' : '❌'} | \`${k}\` | ${fmt(a)} | ${fmt(b)} |`);
}
L.push(`${matches}/${keys.length} probe keys identical to the reference.`);
L.push('');
L.push(`| | key | candidate | reference (real Chrome) |`);
L.push(`|---|---|---|---|`);
L.push(...rows);
L.push('');

// ---- 2. HTTP headers -------------------------------------------------------
L.push(`## 2. HTTP request headers (local origin)`);
L.push('');
const byPath = (snap) => {
    const m = new Map();
    for (const r of snap.steps.localHeaders?.requests ?? []) if (!m.has(r.path)) m.set(r.path, r);
    return m;
};
const cp = byPath(cand);
const rp = byPath(ref);
const paths = [...new Set([...rp.keys(), ...cp.keys()])].sort();
L.push(`| path | candidate header order | reference header order |`);
L.push(`|---|---|---|`);
for (const p of paths) {
    const cn = cp.get(p)?.headers.map(([k]) => k).join(', ') ?? '**never requested**';
    const rn = rp.get(p)?.headers.map(([k]) => k).join(', ') ?? '**never requested**';
    L.push(`| \`${p}\` | ${cn} | ${rn} |`);
}
L.push('');
L.push(`### Header values on the document request`);
L.push('');
const docC = cp.get('/');
const docR = rp.get('/');
const hkeys = [...new Set([
    ...(docR?.headers ?? []).map(([k]) => k.toLowerCase()),
    ...(docC?.headers ?? []).map(([k]) => k.toLowerCase()),
])];
L.push(`| | header | candidate | reference |`);
L.push(`|---|---|---|---|`);
for (const h of hkeys) {
    const a = docC?.headers.find(([k]) => k.toLowerCase() === h)?.[1];
    const b = docR?.headers.find(([k]) => k.toLowerCase() === h)?.[1];
    L.push(`| ${a === b ? '✅' : '❌'} | \`${h}\` | ${fmt(a)} | ${fmt(b)} |`);
}
L.push('');

// ---- 3. bot.sannysoft.com --------------------------------------------------
L.push(`## 3. bot.sannysoft.com`);
L.push('');
const ssRows = (snap) => {
    const m = new Map();
    for (const r of snap.steps.sannysoft?.rows ?? []) if (r.name !== 'Test Name') m.set(r.name, r);
    return m;
};
const cs = ssRows(cand);
const rs = ssRows(ref);
const verdict = (r) => {
    if (!r) return '—';
    const s = (r.status || '').toLowerCase();
    if (s.includes('failed')) return 'FAIL';
    if (s.includes('passed')) return 'pass';
    if (/canvas failed|no webgl|^fail/i.test(r.value)) return 'FAIL';
    return 'info';
};
const names = [...new Set([...rs.keys(), ...cs.keys()])];
const fails = names.filter((n) => verdict(cs.get(n)) === 'FAIL');
L.push(`Candidate FAIL rows: **${fails.length}** — ${fails.map((f) => '`' + f + '`').join(', ') || 'none'}`);
L.push('');
L.push(`| | test | candidate | reference |`);
L.push(`|---|---|---|---|`);
for (const n of names) {
    const a = cs.get(n);
    const b = rs.get(n);
    const va = verdict(a);
    const vb = verdict(b);
    const mark = va === 'FAIL' ? '❌' : va === vb ? '✅' : '⚠️';
    L.push(`| ${mark} | ${n} | ${va} · ${fmt(a?.value)} | ${vb} · ${fmt(b?.value)} |`);
}
L.push('');

// ---- 4. CreepJS ------------------------------------------------------------
L.push(`## 4. CreepJS`);
L.push('');
const ck = ['computed', 'fpId', 'fuzzy', 'likeHeadless', 'headlessPct', 'stealthPct', 'textLength'];
L.push(`| | field | candidate | reference |`);
L.push(`|---|---|---|---|`);
for (const k of ck) {
    const a = cand.steps.creepjs?.[k];
    const b = ref.steps.creepjs?.[k];
    L.push(`| ${same(a, b) ? '✅' : '❌'} | \`${k}\` | ${fmt(a)} | ${fmt(b)} |`);
}
L.push('');

const md = L.join('\n') + '\n';
if (outPath) {
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, md);
    console.log(`wrote ${path.relative(repo, outPath)} (${matches}/${keys.length} probe keys match, ${fails.length} sannysoft FAILs)`);
} else {
    process.stdout.write(md);
}
