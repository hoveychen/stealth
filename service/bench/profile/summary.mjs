// run1.sh / bench.mjs JSON lines on stdin -> one line per run, sorted by label.
import fs from 'node:fs';
const rows = fs.readFileSync(0, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
rows.sort((a, b) => a.label.localeCompare(b.label));
for (const r of rows) {
    console.log(`${r.label.padEnd(30)} pages/s=${String(r.pagesPerSec).padEnd(8)} MB=${String(r.peakContainerMB).padEnd(5)} ` +
        `p50=${r.p50} p95=${r.p95} errors=${r.errors} engineCores=${r.engineCores} load=${r.loadStart}-${r.loadEnd}`);
}
