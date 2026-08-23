// Measures how far this engine's CSS serialisation still is from Chrome's, on
// the real Cloudflare challenge page's `@keyframes` payload, without needing a
// station sitting.
//
//   node tools/fingerprint/keyframes-roundtrip.mjs [--verbose]
//
// The trick is that both arms of the a3 sitting recorded the *same* collection:
// `results/a3-oracle.json` records[67] is Chrome's `cssText` for the page's 183
// rules joined with `|`, and `results/a3-lp.json` records[26] is ours. Feeding
// our own text back through a fresh CSSStyleSheet and re-reading it re-runs the
// whole serialiser over real-world CSS, so the gap against the oracle's text is
// a direct read of what is left to close. No network, no challenge, ~3 seconds.
//
// Env:
//   LP_BIN  path to the lightpanda binary (default: <repo>/zig-out/bin/lightpanda)
//   PORT    CDP port, so two runs can go at once
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const verbose = process.argv.includes('--verbose');

const read = async (file, index) => {
    const json = JSON.parse(await fs.readFile(path.join(here, 'results', file), 'utf8'));
    return json.records[index].a.v;
};

// The collector glues a bare `0` onto the last rule and, on our side, appends a
// stray `|2`; neither is CSS, so both come off before the comparison.
const rules = (payload) => payload.split('|').slice(0, 183)
    .map((rule, i, all) => (i === all.length - 1 ? rule.replace(/}0$/, '}') : rule));

const oracleRules = rules(await read('a3-oracle.json', 67));
const ourRules = rules(await read('a3-lp.json', 26));

const probe = `(() => {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(${JSON.stringify(ourRules.join('\n'))});
    return [...sheet.cssRules].map((r) => r.cssText).join("|");
})()`;

const probeFile = path.join(await fs.mkdtemp(path.join(os.tmpdir(), 'kf-')), 'probe.js');
await fs.writeFile(probeFile, probe);

const runExpr = path.join(here, 'run-expr.mjs');
const out = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [runExpr, 'lightpanda', probeFile], {
        cwd: repo,
        stdio: ['ignore', 'pipe', 'inherit'],
        env: process.env,
    });
    let buf = '';
    child.stdout.on('data', (d) => { buf += d; });
    child.on('error', reject);
    child.on('close', (code) => (code === 0 ? resolve(buf) : reject(new Error(`run-expr exited ${code}`))));
});

const ours = JSON.parse(out.trim());
const oracle = oracleRules.join('|');
const after = ours.split('|');

let identical = 0;
const differing = [];
for (let i = 0; i < oracleRules.length; i++) {
    if (oracleRules[i] === after[i]) identical++;
    else differing.push(i);
}

console.log(`oracle    ${oracle.length} chars, ${oracleRules.length} rules`);
console.log(`ours      ${ours.length} chars`);
console.log(`gap       ${oracle.length - ours.length} chars`);
console.log(`identical ${identical}/${oracleRules.length} rules`);

if (verbose) {
    for (const i of differing) {
        console.log(`\n### rule ${i}  delta ${oracleRules[i].length - (after[i] ?? '').length}`);
        console.log(`  oracle: ${oracleRules[i].slice(0, 400)}`);
        console.log(`  ours  : ${(after[i] ?? '').slice(0, 400)}`);
    }
}
