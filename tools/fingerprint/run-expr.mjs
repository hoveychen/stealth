// Evaluates one expression file against real Chrome or against this engine and
// prints the result as JSON, so a claim about a DOM reading can be checked
// against both in one command.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-g4-p67.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-g4-p67.js
//   node tools/fingerprint/run-expr.mjs chrome     probes/expr-x.js --headed
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
    console.error('usage: run-expr.mjs <lightpanda|chrome> <expression-file> [--url U] [--headed] [--headed-ua] [--window-size W,H]');
    process.exit(1);
}
if (!exprPath) {
    console.error('usage: run-expr.mjs <lightpanda|chrome> <expression-file> [--url U] [--headed] [--headed-ua] [--window-size W,H]');
    process.exit(1);
}
const expr = await fs.readFile(exprPath, 'utf8');

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9344 : 9345);

// Headless is the default because it leaves no window behind, and for most
// readings the two agree. Text metrics are the exception this flag was added
// for: which fonts are installed and which one a family name resolves to is
// answered by the platform, and a headless Chrome is not obliged to answer it
// the same way. Pass --headed when the reading is about fonts, rasterised
// glyphs, or anything else the window system has a say in.
const headed = process.argv.includes('--headed');

// `about:blank` is an opaque origin, which is a fine place to read most things
// and the wrong place to read a surface that a real page would have. It is not
// a secure context, so Chrome hides `crypto.subtle`, `navigator.usb` and two
// dozen others there; it has no viewport worth the name, so `innerWidth` is
// whatever headless defaults to; and headless announces itself in the user
// agent. Comparing our answers on a real page against Chrome's answers on
// about:blank produces seventy differences, of which the great majority are
// the harness disagreeing with itself. --url puts both arms on the same page.
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const targetUrl = arg('--url', 'about:blank');
const windowSize = arg('--window-size', null);
// Extra Chrome switches, repeatable, the way antibot-sweep.mjs takes them. One
// launch flag at a time against one expression is how a reading gets attributed
// to the flag rather than to the browser: `--chrome-arg
// --force-device-scale-factor=2` twice over the same probe says exactly which
// values follow from devicePixelRatio and which only looked like they did.
// Chrome only; ignored for the lightpanda arm.
const chromeArgs = process.argv.reduce((acc, a, i) => (
    a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
// Same reason the sweep has it: the product token is a one-word tell, and a
// reading taken with it is a reading of the harness.
const headedUa = process.argv.includes('--headed-ua');

// The headed user agent, read off the browser rather than written down --
// --user-agent is a launch switch, so it has to be known before the arm we
// care about starts. Same shape as antibot-sweep's.
async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'run-expr-ua-'));
    const port = PORT + 40;
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${port}`,
        `--user-data-dir=${dir}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
                if (ua) return ua.replace('HeadlessChrome', 'Chrome');
            } catch { /* not up yet */ }
            await sleep(200);
        }
        throw new Error('could not read the browser user agent for --headed-ua');
    } finally {
        probe.kill('SIGKILL');
        await fs.rm(dir, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

let proc;
if (engine === 'chrome') {
    if (headedUa === false && targetUrl !== 'about:blank') {
        console.error('note: reading a real page without --headed-ua leaves HeadlessChrome in the user agent');
    }
    const userAgentOverride = headedUa ? await headedUserAgent() : null;
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'run-expr-chrome-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        ...(headed ? [] : ['--headless=new']),
        `--window-size=${windowSize ?? '1920,1080'}`,
        ...(userAgentOverride ? [`--user-agent=${userAgentOverride}`] : []),
        ...chromeArgs,
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    if (headedUa) {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
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
        const { targetId } = await cdp.send('Target.createTarget', { url: targetUrl });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        const { browserContextId } = await cdp.send('Target.createBrowserContext');
        const { targetId } = await cdp.send('Target.createTarget', { url: targetUrl, browserContextId });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    }

    // A reading taken off a document that is still `loading` is a reading of
    // the race, not the engine: `document.body` comes back null and every
    // timing field comes back zero, on whichever arm lost.
    if (targetUrl !== 'about:blank') {
        const deadline = Date.now() + 30000;
        while (Date.now() < deadline) {
            const r = await cdp.send('Runtime.evaluate',
                { expression: 'document.readyState', returnByValue: true }, sessionId).catch(() => null);
            if (r?.result?.value === 'complete') break;
            await sleep(250);
        }
        await sleep(2000);
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
