// Run a probe file (an async IIFE that returns a plain object) on one engine and
// print the result as JSON.
// usage: node tools/fingerprint/run-probe.mjs <chrome|lightpanda> <probe.js> [url]
//                                             [--headed] [--window-size 1920,1080]
//
// The WebCodecs codec classes are [SecureContext], so about:blank is not enough
// for them -- pass an https url to measure those.
//
// Since the [SecureContext] gate landed, the *url* decides how much of the
// global surface either engine shows: an untrustworthy origin hides 234 names
// here and 252 in Chrome. http://127.0.0.1 and http://localhost are loopback
// and therefore trustworthy; a LAN address or 0.0.0.0 is not. A reading taken
// on the bare about:blank target is ungated in this engine and gated in Chrome,
// so it is the one url not to compare across engines.
//
// This engine does not run scheduled tasks while an awaitPromise evaluate is
// outstanding, so a probe that awaits a setTimeout hangs here -- use
// `run-page-probe.mjs` for those. Chrome handles both.
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, newPage, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
const probePath = process.argv[3];
const headed = process.argv.includes('--headed');
// Pin the window for a headed-vs-headless comparison. Without it the two arms
// differ in a flag neither run chose: `--headless=new` defaults to 800x600 and a
// headed window does not, so `screen`/`window` read as a headlessness tell when
// they are only a launch default. antibot-sweep.mjs pins 1920,1080 on both arms,
// and a probe meant to explain that sweep has to pin the same thing.
const windowSize = (() => {
  const i = process.argv.indexOf('--window-size');
  return i < 0 ? null : process.argv[i + 1];
})();
const url = (() => {
  const rest = process.argv.slice(4);
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--window-size') { i++; continue; }   // skip the flag's value
    if (!rest[i].startsWith('--')) return rest[i];
  }
  return undefined;
})();
// PORT overrides, because the default is not always free -- see the abort below.
const PORT = Number(process.env.PORT) || Number(process.env.PROBE_PORT) ||
    (engine === 'chrome' ? 9361 : 9301);
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// Which lightpanda binary to drive. Point LP_BIN at a worktree's
// zig-out/bin/lightpanda to diff a branch against Chrome.
const LIGHTPANDA = process.env.LP_BIN || process.env.LIGHTPANDA ||
    path.join(REPO, 'zig-out/bin/lightpanda');

const source = await fs.readFile(probePath, 'utf8');

// Abort rather than measure the wrong browser. A leftover engine from an earlier
// session keeps listening on the default port, and the wait loop below cannot
// tell it from the one we are about to spawn -- it just connects to whatever
// answers first. That cost a G21 measurement: two "macOS Chrome 151" runs came
// back byte-identical because both were served by a stale headless Chrome 150,
// which would have made a version difference read as a platform difference.
try {
  const stale = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
  console.error(
    `port ${PORT} is already serving CDP (${stale['Browser'] ?? '?'}). Refusing to run: the result\n` +
    `would come from that process, not a fresh ${engine}. Kill it, or set PROBE_PORT to a free port.`,
  );
  process.exit(2);
} catch (e) {
  if (e instanceof SyntaxError) throw e; // answered, but not with JSON
}

let proc, prof;
if (engine === 'chrome') {
  prof = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-probe-'));
  const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`, '--no-first-run', '--no-default-browser-check', ...personaScaleFlags()];
  if (windowSize) args.push(`--window-size=${windowSize}`);
  if (!headed) args.push('--headless=new');
  proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
  proc = spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 200; i++) {
  try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(200); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
let sessionId;
if (engine === 'chrome') {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
} else {
  ({ sessionId } = await newPage(cdp));
}

if (url) {
  await cdp.send('Page.enable', {}, sessionId).catch(() => {});
  await cdp.send('Page.navigate', { url }, sessionId);
  await sleep(4000);
}

const res = await cdp.send('Runtime.evaluate', {
  expression: `(async () => JSON.stringify(await (${source.trim().replace(/;\s*$/, '')}), null, 1))()`,
  awaitPromise: true,
  returnByValue: true,
}, sessionId);

if (res.exceptionDetails) {
  console.error('THREW: ' + (res.exceptionDetails.exception?.description ?? res.exceptionDetails.text));
  process.exitCode = 1;
} else {
  console.log(res.result.value);
}

cdp.close();
proc.kill('SIGKILL');
if (prof) await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
process.exit(process.exitCode ?? 0);
