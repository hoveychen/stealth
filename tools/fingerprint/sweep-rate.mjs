// Pass *rates* over a set of antibot-sweep snapshots, per station and per arm.
//
//   node tools/fingerprint/sweep-rate.mjs control=results/a-1.json,results/a-2.json \
//                                        treatment=results/b-1.json,results/b-2.json
//
// A single sweep answers "did this station open just now", which is not the
// question. These guards open and close on their own clock -- B50 measured one
// binary passing 1 of 4 sittings on a station it later passed 25 of 25 -- so a
// change is only visible as a rate over interleaved runs, and a station that
// moved for both arms moved on its own.
import fs from 'node:fs';

const arms = [];
for (const spec of process.argv.slice(2)) {
    const at = spec.indexOf('=');
    if (at < 0) {
        console.error('usage: sweep-rate.mjs <arm>=<file,file,...> [<arm>=...]');
        process.exit(2);
    }
    arms.push({ name: spec.slice(0, at), files: spec.slice(at + 1).split(',').filter(Boolean) });
}
if (arms.length === 0) {
    console.error('usage: sweep-rate.mjs <arm>=<file,file,...> [<arm>=...]');
    process.exit(2);
}

const load = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const stations = new Map(); // name -> arm -> {pass, runs, verdicts:Map}

for (const arm of arms) {
    for (const file of arm.files) {
        const snapshot = load(file);
        for (const row of snapshot.stations ?? snapshot.results ?? []) {
            if (!stations.has(row.name)) stations.set(row.name, new Map());
            const per = stations.get(row.name);
            if (!per.has(arm.name)) per.set(arm.name, { pass: 0, runs: 0, verdicts: new Map() });
            const tally = per.get(arm.name);
            tally.runs += 1;
            if (row.verdict === 'pass') tally.pass += 1;
            tally.verdicts.set(row.verdict, (tally.verdicts.get(row.verdict) ?? 0) + 1);
        }
    }
}

const rate = (t) => (t ? `${t.pass}/${t.runs}` : '-');
const width = Math.max(...[...stations.keys()].map((s) => s.length), 8);
console.log(`${'station'.padEnd(width)}  ${arms.map((a) => a.name.padEnd(9)).join(' ')} verdicts`);
const totals = new Map(arms.map((a) => [a.name, { pass: 0, runs: 0 }]));
const moved = [];
for (const [name, per] of [...stations].sort()) {
    const cells = arms.map((a) => rate(per.get(a.name)).padEnd(9)).join(' ');
    const verdicts = arms
        .map((a) => {
            const t = per.get(a.name);
            if (!t) return `${a.name}:-`;
            return `${a.name}:${[...t.verdicts].map(([v, n]) => `${v}x${n}`).join(',')}`;
        })
        .join('  ');
    console.log(`${name.padEnd(width)}  ${cells} ${verdicts}`);
    for (const a of arms) {
        const t = per.get(a.name);
        if (!t) continue;
        totals.get(a.name).pass += t.pass;
        totals.get(a.name).runs += t.runs;
    }
    // A station worth looking at is one where the two arms' rates differ.
    if (arms.length === 2) {
        const [x, y] = arms.map((a) => per.get(a.name));
        if (x && y && x.pass / x.runs !== y.pass / y.runs) moved.push(name);
    }
}
console.log('---');
for (const a of arms) {
    const t = totals.get(a.name);
    console.log(`${a.name}: ${t.pass}/${t.runs} station-runs passed (${((100 * t.pass) / t.runs).toFixed(1)}%)`);
}
if (moved.length) console.log(`rates differ at: ${moved.join(', ')}`);
else if (arms.length === 2) console.log('rates identical at every station');
