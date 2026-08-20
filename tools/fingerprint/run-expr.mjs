// Evaluates one expression file against real Chrome or against this engine and
// prints the result as JSON, so a claim about a DOM reading can be checked
// against both in one command.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-g4-p67.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-g4-p67.js
//
// The collectors walk a fixed property list; this runs whatever expression you
// hand it, which is what a one-off "what does Chrome say about X" needs. Diff
// the two outputs and the answer is the diff.
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
//
// Uses the repo's zero-dep CDP client, so both engines go through one driver.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
const exprPath = process.argv[3];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: run-expr.mjs <lightpanda|chrome> <expression-file>');
    process.exit(1);
}
if (!exprPath) {
    console.error('usage: run-expr.mjs <lightpanda|chrome> <expression-file>');
    process.exit(1);
}
const expr = await fs.readFile(exprPath, 'utf8');

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9344 : 9345);

let proc;
if (engine === 'chrome') {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'run-expr-chrome-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--headless=new',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], {
        stdio: ['ignore', 'pipe', 'pipe'],
    });
}
const log = [];
proc.stdout.on('data', (d) => log.push(String(d)));
proc.stderr.on('data', (d) => log.push(String(d)));

try {
    let version = null;
    for (let i = 0; i < 100; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            version = await r.json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!version) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        const { browserContextId } = await cdp.send('Target.createBrowserContext');
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    }

    const res = await cdp.send('Runtime.evaluate', {
        expression: expr,
        returnByValue: true,
        awaitPromise: true,
    }, sessionId);
    if (res.exceptionDetails) {
        console.error(JSON.stringify(res.exceptionDetails, null, 2));
        process.exitCode = 1;
    } else {
        console.log(JSON.stringify(res.result.value, null, 2));
    }
} finally {
    proc.kill('SIGKILL');
}
