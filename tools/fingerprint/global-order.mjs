// How close is this engine's `window` own-property ORDER to Chrome's?
//
// DataDome's device-check serialises `Object.getOwnPropertyNames(window)` --
// order included -- straight into the payload it uploads, so the sequence is a
// measured surface rather than an implementation detail. The reference is a
// capture off a real Chrome 152 (results/chrome-global-order.json), which makes
// this the same kind of ground truth proto-gap.mjs uses for prototypes.
//
//   LP_BIN=.pinned/lp-stallfix node tools/fingerprint/global-order.mjs
//   node tools/fingerprint/global-order.mjs --engine chrome     # sanity: 100%
//   node tools/fingerprint/global-order.mjs --json
//
// Read on a page that actually loads over https. On an insecure origin the
// engine deletes ~239 secure-context gated names and Chrome hides its own, so
// an about:blank reading scores a gap that is not there; and a URL that fails
// to load leaves Chrome on its network error page, whose own globals (`Runner`,
// `loadTimeDataRaw`, ...) land in the list. The page's own globals are reported
// separately as `page` rather than counted as extras, because every real page
// has some.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const arg = (flag, fallback) => {
    const i = process.argv.indexOf(flag);
    return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};

const engine = arg('--engine', 'lightpanda');
const url = arg('--url', 'https://www.iana.org/help/example-domains');
const reference = JSON.parse(fs.readFileSync(path.resolve(HERE, arg('--ref', 'results/chrome-global-order.json')), 'utf8'));
const chrome = reference.names ?? reference;

const ours = await new Promise((resolve, reject) => {
    const args = [path.join(HERE, 'run-expr.mjs'), engine, path.join(HERE, 'probes/expr-global-order.js'), '--url', url];
    if (engine === 'chrome') args.push('--headed-ua');
    const p = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'inherit'] });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.on('exit', (code) => (code === 0 ? resolve(JSON.parse(out)) : reject(new Error(`run-expr exited ${code}`))));
});

const chromeRank = new Map(chrome.map((n, i) => [n, i]));
const known = ours.filter((n) => chromeRank.has(n));
const missing = chrome.filter((n) => !ours.includes(n));
// A name Chrome has nowhere is either a page global or a bot marker; the caller
// has to look at them, so they are listed rather than scored.
const unknown = ours.filter((n) => !chromeRank.has(n));

// Longest increasing subsequence over Chrome's ranks: the largest set of our
// names already in Chrome's relative order. Everything outside it has to move.
const ranks = known.map((n) => chromeRank.get(n));
const tails = [];
for (const r of ranks) {
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (tails[mid] < r) lo = mid + 1; else hi = mid;
    }
    tails[lo] = r;
}
const inOrder = tails.length;

// Where the first name sits that Chrome puts somewhere else -- the number that
// moves when a whole block is relocated, and the one to quote in a commit.
let firstWrong = -1;
for (let i = 1; i < ranks.length; i++) {
    if (ranks[i] < ranks[i - 1]) { firstWrong = i; break; }
}

const report = {
    engine,
    url,
    ours: ours.length,
    chrome: chrome.length,
    shared: known.length,
    inOrder,
    misplaced: known.length - inOrder,
    orderScore: known.length ? +(inOrder / known.length * 100).toFixed(1) : 0,
    firstDivergence: firstWrong < 0 ? null : { index: firstWrong, name: known[firstWrong], chromeIndex: ranks[firstWrong] },
    missing,
    page: unknown,
};

if (process.argv.includes('--json')) {
    console.log(JSON.stringify(report, null, 2));
} else {
    console.log(`${engine} on ${url}`);
    console.log(`  own properties: ours ${report.ours}, chrome ${report.chrome}, shared ${report.shared}`);
    console.log(`  order: ${inOrder}/${report.shared} in Chrome's relative order (${report.orderScore}%), ${report.misplaced} misplaced`);
    console.log(`  first divergence: ${report.firstDivergence
        ? `our #${report.firstDivergence.index} ${report.firstDivergence.name} (Chrome puts it at #${report.firstDivergence.chromeIndex})`
        : 'none'}`);
    console.log(`  missing (${missing.length}): ${missing.join(' ') || '-'}`);
    console.log(`  page/unknown (${unknown.length}): ${unknown.join(' ') || '-'}`);
}
