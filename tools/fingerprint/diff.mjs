// Renders a markdown comparison of two snapshots produced by the collectors.
//
//   node tools/fingerprint/diff.mjs <candidate.json> <reference.json>
//                                   [--control <second-reference.json>] [--out x.md]
//
// The candidate is lightpanda (before or after); the reference is real Chrome.
// Same script drives P2's before table and P7's after table, so the two are
// directly comparable.
//
// `--control` takes a *second* Chrome snapshot from a differently-configured
// but equally acceptable browser — headed against headless+UA, say, both of
// which clear the scrapingcourse challenge 3/3. Where the two references
// disagree, no single value can be what a guard demands, so a candidate that
// differs there is off the hook: those rows are marked ➖ instead of ❌. What
// survives is the set where every accepted browser agrees and only this engine
// does not.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const positional = [];
for (let i = 2; i < process.argv.length; i++) {
    const a = process.argv[i];
    if (a === '--out' || a === '--control') i++;
    else if (!a.startsWith('--')) positional.push(a);
}
const [candPath, refPath] = positional;
if (!candPath || !refPath) {
    console.error('usage: diff.mjs <candidate.json> <reference.json> [--control ctl.json] [--out out.md]');
    process.exit(2);
}
const outArg = process.argv.indexOf('--out');
const outPath = outArg !== -1 ? path.resolve(repo, process.argv[outArg + 1]) : null;
const ctlArg = process.argv.indexOf('--control');

const read = async (p) => JSON.parse(await fs.readFile(path.resolve(repo, p), 'utf8'));
const cand = await read(candPath);
const ref = await read(refPath);
const ctl = ctlArg !== -1 ? await read(process.argv[ctlArg + 1]) : null;

const fmt = (v) => {
    if (v === undefined) return '*(absent)*';
    if (v === null) return '`null`';
    if (typeof v === 'object' && v.__err) return `❌ throws: ${v.__err}`;
    if (typeof v === 'object' && v.__undefined) return '⚠️ `undefined`';
    const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
    return '`' + (s.length > 110 ? s.slice(0, 110) + '…' : s).replace(/\|/g, '\\|') + '`';
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const build = (s) => s.version?.['Lightpanda-Version'] ?? s.version?.Browser ?? '?';

// With a control, a row is only the candidate's problem when the two references
// agree on it; where they disagree the value is demonstrably not load-bearing.
const cCol = ctl ? ` control |` : '';
const cSep = ctl ? `---|` : '';
const mark = (a, b, c) => (same(a, b) ? '✅' : ctl && !same(b, c) ? '➖' : '❌');

const L = [];
L.push(`# Fingerprint comparison`);
L.push('');
L.push(`| | candidate | reference |${cCol}`);
L.push(`|---|---|---|${cSep}`);
L.push(`| engine | \`${cand.engine}\` | \`${ref.engine}\` |${ctl ? ` \`${ctl.engine}\` |` : ''}`);
L.push(`| build | \`${build(cand)}\` | \`${build(ref)}\` |${ctl ? ` \`${build(ctl)}\` |` : ''}`);
L.push('');

// ---- 1. JS surface ---------------------------------------------------------
L.push(`## 1. JS fingerprint surface`);
L.push('');
const keys = [...new Set([...Object.keys(cand.steps.probe ?? {}), ...Object.keys(ref.steps.probe ?? {})])];
let matches = 0;
let excused = 0;
const own = [];
const rows = [];
for (const k of keys) {
    const a = cand.steps.probe?.[k];
    const b = ref.steps.probe?.[k];
    const c = ctl?.steps.probe?.[k];
    const m = mark(a, b, c);
    if (m === '✅') matches++;
    else if (m === '➖') excused++;
    else own.push(k);
    rows.push(`| ${m} | \`${k}\` | ${fmt(a)} | ${fmt(b)} |${ctl ? ` ${fmt(c)} |` : ''}`);
}
L.push(`${matches}/${keys.length} probe keys identical to the reference.`);
if (ctl) {
    L.push('');
    L.push(`Of the ${keys.length - matches} that are not, ${excused} land where the two`);
    L.push(`references disagree (➖ — not a requirement), leaving **${own.length}** where every`);
    L.push(`accepted browser agrees and this engine does not:`);
    L.push('');
    for (const k of own) L.push(`- \`${k}\``);
}
L.push('');
L.push(`| | key | candidate | reference (real Chrome) |${cCol}`);
L.push(`|---|---|---|---|${cSep}`);
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
const xp = ctl ? byPath(ctl) : new Map();
const paths = [...new Set([...rp.keys(), ...cp.keys()])].sort();
const order = (m, p) => m.get(p)?.headers.map(([k]) => k).join(', ') ?? '**never requested**';
L.push(`| path | candidate header order | reference header order |${cCol}`);
L.push(`|---|---|---|${cSep}`);
for (const p of paths) {
    L.push(`| \`${p}\` | ${order(cp, p)} | ${order(rp, p)} |${ctl ? ` ${order(xp, p)} |` : ''}`);
}
L.push('');
L.push(`### Header values on the document request`);
L.push('');
const docC = cp.get('/');
const docR = rp.get('/');
const docX = xp.get('/');
const hkeys = [...new Set([
    ...(docR?.headers ?? []).map(([k]) => k.toLowerCase()),
    ...(docC?.headers ?? []).map(([k]) => k.toLowerCase()),
])];
const hval = (rec, h) => rec?.headers.find(([k]) => k.toLowerCase() === h)?.[1];
L.push(`| | header | candidate | reference |${cCol}`);
L.push(`|---|---|---|---|${cSep}`);
for (const h of hkeys) {
    const a = hval(docC, h);
    const b = hval(docR, h);
    const c = hval(docX, h);
    L.push(`| ${mark(a, b, c)} | \`${h}\` | ${fmt(a)} | ${fmt(b)} |${ctl ? ` ${fmt(c)} |` : ''}`);
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
const xs = ctl ? ssRows(ctl) : new Map();
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
L.push(`| | test | candidate | reference |${cCol}`);
L.push(`|---|---|---|---|${cSep}`);
for (const n of names) {
    const a = cs.get(n);
    const b = rs.get(n);
    const x = xs.get(n);
    const va = verdict(a);
    const vb = verdict(b);
    const m = va === 'FAIL' ? '❌' : va === vb ? '✅' : '⚠️';
    L.push(
        `| ${m} | ${n} | ${va} · ${fmt(a?.value)} | ${vb} · ${fmt(b?.value)} |` +
            (ctl ? ` ${verdict(x)} · ${fmt(x?.value)} |` : ''),
    );
}
L.push('');

// ---- 4. CreepJS ------------------------------------------------------------
L.push(`## 4. CreepJS`);
L.push('');
const ck = ['computed', 'fpId', 'fuzzy', 'likeHeadless', 'headlessPct', 'stealthPct', 'textLength'];
L.push(`| | field | candidate | reference |${cCol}`);
L.push(`|---|---|---|---|${cSep}`);
for (const k of ck) {
    const a = cand.steps.creepjs?.[k];
    const b = ref.steps.creepjs?.[k];
    const c = ctl?.steps.creepjs?.[k];
    L.push(`| ${mark(a, b, c)} | \`${k}\` | ${fmt(a)} | ${fmt(b)} |${ctl ? ` ${fmt(c)} |` : ''}`);
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
