// Turns bench.mjs / multi.sh JSON lines into markdown tables, one row per run,
// grouped by file.
//
//   node service/bench/report.mjs results/*.jsonl

import fs from 'node:fs';

const cols = [
    ['label', (d) => d.label],
    ['mode', (d) => d.mode],
    ['page', (d) => d.page.replace('.html', '')],
    ['c', (d) => (d.containers ? `${d.containers}×${d.c / d.containers}` : d.c)],
    ['pages/s', (d) => d.pagesPerSec],
    ['p50 ms', (d) => d.p50],
    ['p95 ms', (d) => d.p95],
    ['errors', (d) => d.errors],
    ['engine cores', (d) => d.engineCores],
    ['node cores', (d) => d.nodeCores ?? ''],
    ['peak MB', (d) => d.peakContainerMB],
    ['load', (d) => d.load.map(Math.round).join('→')],
];

for (const file of process.argv.slice(2)) {
    const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    console.log(`\n### ${file.split('/').pop()}\n`);
    console.log(`| ${cols.map(([h]) => h).join(' | ')} |`);
    console.log(`|${cols.map(() => '---').join('|')}|`);
    for (const d of rows) console.log(`| ${cols.map(([, f]) => f(d)).join(' | ')} |`);
}
