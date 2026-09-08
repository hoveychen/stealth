// Diff two detector-verdicts.mjs snapshots by axis name.
//
//   node tools/fingerprint/verdict-diff.mjs <ours.json> <theirs.json> [--all]
//
// The point of the axis map is this comparison: the detectors say what they
// think AND name what they read, so when one of them calls this engine
// unreliable while calling the reference trustworthy, the axes where the two
// arms actually disagree are a ranked candidate list rather than a guess.
//
// Some axes cannot differ meaningfully and are dropped, with the reason kept in
// the output rather than in a comment here: a fingerprint hash summarising a
// surface says nothing about WHICH part of it moved, a timing is not a
// property of the engine, and the IP-derived rows are the route's.
import fs from 'node:fs';

const [oursPath, theirsPath] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
if (!oursPath || !theirsPath) {
    console.error('usage: verdict-diff.mjs <ours.json> <theirs.json> [--all]');
    process.exit(2);
}
const showAll = process.argv.includes('--all');
const ours = JSON.parse(fs.readFileSync(oursPath, 'utf8'));
const theirs = JSON.parse(fs.readFileSync(theirsPath, 'utf8'));

// Rows whose difference is not about this engine. Kept small and explicit:
// anything dropped here is a reading nobody will look at again.
const NOISE = [
    [/^(ms|time|elapsed|duration)/i, 'a timing'],
    [/(^| )ip( |$)|ip address|city|region|country|coordinates|isp|asn|proxy|vpn|hostname/i, 'the route, not the engine'],
    [/session|token|cookie|uuid|^id$/i, 'per-run'],
];
const noiseReason = (name) => NOISE.find(([re]) => re.test(name))?.[1] ?? null;

let sameCount = 0;
const report = [];
for (const name of new Set([...Object.keys(ours.detectors), ...Object.keys(theirs.detectors)])) {
    const a = ours.detectors[name] ?? {};
    const b = theirs.detectors[name] ?? {};
    const lines = [];

    const av = a.verdicts?.[0]?.text, bv = b.verdicts?.[0]?.text;
    if (a.score != null || b.score != null || av !== bv) {
        lines.push(`  VERDICT ours="${av ?? '-'}" score=${a.score ?? '-'} | theirs="${bv ?? '-'}" score=${b.score ?? '-'}`);
    }

    for (const test of new Set([...Object.keys(a.tests ?? {}), ...Object.keys(b.tests ?? {})])) {
        const x = a.tests?.[test]?.status, y = b.tests?.[test]?.status;
        if (x === y) { sameCount++; continue; }
        lines.push(`  TEST  ${test}: ours=${x ?? 'absent'} theirs=${y ?? 'absent'}`);
    }

    for (const axis of new Set([...Object.keys(a.axes ?? {}), ...Object.keys(b.axes ?? {})])) {
        const x = a.axes?.[axis], y = b.axes?.[axis];
        if (x === y) { sameCount++; continue; }
        const why = noiseReason(axis);
        if (why && !showAll) continue;
        lines.push(`  AXIS  ${axis}${why ? ` [${why}]` : ''}\n          ours:   ${String(x ?? 'absent').slice(0, 150)}\n          theirs: ${String(y ?? 'absent').slice(0, 150)}`);
    }

    if (lines.length) report.push(`\n=== ${name} ===\n${lines.join('\n')}`);
}

console.log(report.join('\n'));
console.log(`\n${sameCount} readings identical across the arms.`);
console.log(`ours=${oursPath} (${ours.engine}) theirs=${theirsPath} (${theirs.engine}${theirs.headedUa ? ' --headed-ua' : ''})`);
if (!showAll) console.log('(--all also prints the rows dropped as timings, route-derived or per-run)');
