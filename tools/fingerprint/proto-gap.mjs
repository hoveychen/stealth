// The member-set and member-order gap between two `expr-constructor-slot.js`
// readings (or `expr-worker-proto-table.js`, which has the same shape).
//
//   node tools/fingerprint/proto-gap.mjs <chrome.json> <lightpanda.json>
//   node tools/fingerprint/proto-gap.mjs <chrome.json> <lp.json> --interface HTMLIFrameElement
//
// `expr-diff.mjs` compares field by field and prints every difference, which
// for a 923-interface table is a wall. This answers the three questions that
// table is actually asked: how many prototypes are byte-identical, which
// interfaces are short and by which names, and -- the one a names-only report
// hides -- which of them would *still* be wrong after the names were added,
// because the order of the names they already share does not match.
//
// That last column is why this exists. A report that says "HTMLIFrameElement
// is missing 11 members" reads like an eleven-name job; the same interface is
// also mis-ordered on the members it has, so adding the names in IDL order
// leaves the tell in place. 27 of the 43 differing window prototypes were in
// that state when this was written.
import fs from 'node:fs';

const load = (p) => { let v = JSON.parse(fs.readFileSync(p, 'utf8')); if (typeof v === 'string') v = JSON.parse(v); return v; };
const [chPath, lpPath] = [process.argv[2], process.argv[3]];
if (!chPath || !lpPath) {
    console.error('usage: proto-gap.mjs <reference.json> <candidate.json> [--interface NAME]');
    process.exit(2);
}
const [ch, lp] = [load(chPath), load(lpPath)];
const only = process.argv.includes('--interface') ? process.argv[process.argv.indexOf('--interface') + 1] : null;

const shared = Object.keys(ch).filter((k) => k in lp).sort();
let identical = 0, missingTotal = 0, extraTotal = 0, orderOnly = 0;
const rows = [];
for (const k of shared) {
    const c = ch[k].split(','), l = lp[k].split(',');
    if (ch[k] === lp[k]) { identical++; continue; }
    const cs = new Set(c), ls = new Set(l);
    const missing = c.filter((n) => !ls.has(n));
    const extra = l.filter((n) => !cs.has(n));
    missingTotal += missing.length; extraTotal += extra.length;
    if (!missing.length && !extra.length) orderOnly++;
    // Order is compared over the names both sides have, so a short member set
    // does not hide an ordering bug until the day the names are added.
    const cShared = c.filter((n) => ls.has(n)).join(',');
    const lShared = l.filter((n) => cs.has(n)).join(',');
    rows.push({ k, missing, extra, orderOnly: !missing.length && !extra.length, misordered: cShared !== lShared, chrome: ch[k], lp: lp[k] });
}

if (only) {
    const r = rows.find((x) => x.k === only);
    console.log(only, r ? '' : '(byte-identical, or absent from one side)');
    if (r) {
        console.log('reference:', r.chrome);
        console.log('candidate:', r.lp);
        console.log('missing:  ', r.missing.join(','));
        console.log('extra:    ', r.extra.join(','));
    }
    process.exit(0);
}

rows.sort((a, b) => b.missing.length - a.missing.length);
console.log(`shared interfaces: ${shared.length}  byte-identical: ${identical}  differing: ${rows.length}`);
console.log(`missing members: ${missingTotal}  extra members: ${extraTotal}  order-only interfaces: ${orderOnly}  mis-ordered on shared names: ${rows.filter((r) => r.misordered).length}`);
console.log(`reference-only interfaces: ${Object.keys(ch).filter((k) => !(k in lp)).length}  candidate-only: ${Object.keys(lp).filter((k) => !(k in ch)).length}`);
console.log('---');
for (const r of rows) {
    const tag = r.orderOnly ? ' [order only]' : (r.misordered ? ' [ALSO MIS-ORDERED]' : '');
    console.log(`${r.k}  -${r.missing.length} +${r.extra.length}${tag}`);
    if (r.missing.length) console.log(`   missing: ${r.missing.join(', ')}`);
    if (r.extra.length) console.log(`   extra:   ${r.extra.join(', ')}`);
}
