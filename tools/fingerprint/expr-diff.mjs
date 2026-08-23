// Diffs two run-expr readings case by case.
//
//   node tools/fingerprint/expr-diff.mjs <chrome.json> <lightpanda.json>
//
// `diff.mjs` renders the collectors' fixed property list as a markdown table.
// This is the other shape: a probe that returns an object keyed by case name,
// where each case is itself a record of fields. It prints one block per case
// where any field differs and a tally at the end, which is what a "did the
// engine-wide sweep get closer" question needs.
//
// A probe run through run-expr.mjs returns a JSON *string* (the expression ends
// in JSON.stringify so the reading survives CDP's own serialisation), so the
// file has to be parsed twice. Handled here rather than in each probe.
import fs from 'node:fs';

const [a, b] = [process.argv[2], process.argv[3]];
if (!a || !b) {
    console.error('usage: expr-diff.mjs <reference.json> <candidate.json>');
    process.exit(2);
}

const load = (p) => {
    let v = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (typeof v === 'string') v = JSON.parse(v);
    return v;
};
const [reference, candidate] = [load(a), load(b)];

let same = 0;
const diffs = [];
for (const key of Object.keys(reference)) {
    const r = reference[key];
    const c = candidate[key];
    if (c === undefined) {
        diffs.push([key, 'missing in candidate']);
        continue;
    }
    // A case may be a record of sub-readings (the ctor sweep's zero/bad/called)
    // or a single reading; comparing own keys covers both.
    const fields = new Set([...Object.keys(r), ...Object.keys(c)]);
    const bad = [...fields].filter((f) => JSON.stringify(r[f]) !== JSON.stringify(c[f]));
    if (bad.length === 0) {
        same++;
        continue;
    }
    diffs.push([key, bad.map((f) => `${f}: ${JSON.stringify(r[f])} != ${JSON.stringify(c[f])}`).join('\n      ')]);
}

for (const [key, detail] of diffs) console.log(`DIFF ${key}\n      ${detail}`);
console.log(`\n${same}/${Object.keys(reference).length} cases identical, ${diffs.length} differ`);
