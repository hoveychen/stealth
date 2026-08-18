// Sweeps every detector past the headed Linux Chrome in the container, which is
// the reference column this repo needs now that the engine claims Linux.
//
//   node tools/fingerprint/sweep-linux-baseline.mjs [--out results/x.json]
//
// Why not the Chrome on this machine: it is macOS, and as of G21 the engine
// claims Linux. Every platform-specific row then reads as a gap against a
// browser we are deliberately not imitating. The G21 re-sweep's largest single
// finding was exactly that artefact -- browserleaks-js at -176 nodes, all of it
// 199 macOS voices against 19 Linux ones.
//
// What this reference still is NOT (measured in the `## G21` P4 table, not
// assumed): a machine with a GPU or a speech daemon. WebGL comes back as
// SwiftShader and there are no local voices, so those rows compare like-for-like
// with the engine only because the engine took the container's values too. A
// Linux desktop would answer differently for both, and neither this baseline nor
// the engine can stand in for one.
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { withLinuxChrome } from './linux-chrome.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');

const outArg = process.argv.indexOf('--out');
const out = outArg !== -1
    ? process.argv[outArg + 1]
    : 'tools/fingerprint/results/detectors-linux-chrome-headed.json';

await withLinuxChrome(async (endpoint, version) => {
    console.log(`reference: ${version['Browser']} — ${version['User-Agent']}`);
    if (/Headless/.test(version['User-Agent'])) {
        // Not a warning: a headless reference swaps the platform confound for a
        // headed/headless one, which is the whole reason for the Xvfb image.
        throw new Error('reference Chrome is headless; the baseline would measure two things at once');
    }
    await new Promise((resolve, reject) => {
        const p = spawn('node', ['tools/fingerprint/detector-sweep.mjs', 'chrome', '--out', out], {
            cwd: repo,
            stdio: 'inherit',
            env: { ...process.env, CDP_ENDPOINT: endpoint },
        });
        p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`detector-sweep exited ${code}`))));
    });
}, { hostPort: 9367 });
