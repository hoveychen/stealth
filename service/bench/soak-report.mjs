// Summarises soak.mjs output: a thinned table per file and, per load phase,
// a least-squares slope of memory against requests done (MB per 1,000
// requests) over the second half of the phase, when start-up growth is over.
//
//   node soak-report.mjs mixed.jsonl hn.jsonl ... [--every 10]

import fs from 'node:fs';

const args = process.argv.slice(2);
const every = args.includes('--every') ? +args[args.indexOf('--every') + 1] : 10;
const files = args.filter((a, i) => a.endsWith('.jsonl'));

const mb = (kb) => (kb == null ? null : kb / 1024);
function fit(xs, ys) {
    const n = xs.length;
    if (n < 3) return null;
    const mx = xs.reduce((a, b) => a + b) / n, my = ys.reduce((a, b) => a + b) / n;
    let sxy = 0, sxx = 0;
    for (let i = 0; i < n; i++) {
        sxy += (xs[i] - mx) * (ys[i] - my);
        sxx += (xs[i] - mx) ** 2;
    }
    return sxx ? sxy / sxx : null;
}
const f1 = (v) => (v == null || Number.isNaN(v) ? '–' : v.toFixed(1));
const f3 = (v) => (v == null || Number.isNaN(v) ? '–' : v.toFixed(3));
const f0 = (v) => (v == null || Number.isNaN(v) ? '–' : v.toFixed(0));

for (const file of files) {
    const rows = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    console.log(`\n## ${rows[0]?.label ?? file}\n`);
    console.log('| t min | phase | requests | cgroup MB | engine RSS MB | engine anon MB | threads | fds | node RSS MB | reconnects | load |');
    console.log('|---|---|---|---|---|---|---|---|---|---|---|');
    rows.forEach((r, i) => {
        if (i % every && i !== rows.length - 1 && rows[i + 1]?.phase === r.phase) return;
        console.log(`| ${(r.t / 60).toFixed(1)} | ${r.phase} | ${r.done} | ${f0(r.cg.currentMB)} | ${f0(mb(r.engine?.rssKB))} | ${f0(mb(r.engine?.anonKB))} | ${r.engine?.threads ?? '–'} | ${r.engine?.fds ?? '–'} | ${f1(mb(r.node?.rssKB))} | ${r.reconnects ?? '–'} | ${f0(r.load)} |`);
    });
    const pids = new Set(rows.map((r) => r.engine?.pid).filter(Boolean));
    if (pids.size > 1) console.log(`\n**engine restarted**: pids ${[...pids].join(', ')}`);
    const last = rows[rows.length - 1];
    console.log(`\nfinal counts: ${JSON.stringify(last.counts)}`);
    for (const phase of [...new Set(rows.map((r) => r.phase))].filter((p) => p.includes('load'))) {
        const ph = rows.filter((r) => r.phase === phase && r.engine);
        const half = ph.slice(Math.floor(ph.length / 2));
        const x = half.map((r) => r.done / 1000);
        const s = (pick) => fit(x, half.map(pick));
        console.log(`slope ${phase} (2nd half, ${half[0] ? (half[0].t / 60).toFixed(0) : '?'}–${half.at(-1) ? (half.at(-1).t / 60).toFixed(0) : '?'} min, ${half.length ? half.at(-1).done - half[0].done : 0} requests): ` +
            `engine RSS ${f3(s((r) => mb(r.engine.rssKB)))} MB/1k (${f0(s((r) => r.engine.rssKB * 1.024))} B/request), engine anon ${f3(s((r) => mb(r.engine.anonKB)))} MB/1k, cgroup ${f3(s((r) => r.cg.currentMB))} MB/1k, node ${f3(s((r) => mb(r.node?.rssKB)))} MB/1k`);
    }
}
