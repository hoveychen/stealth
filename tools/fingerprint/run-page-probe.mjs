// Run a probe against lightpanda as a *page load* rather than through
// CDP Runtime.evaluate, and print the result as JSON.
// usage: node tools/fingerprint/run-page-probe.mjs <probe.js>
//
// Why this exists: lightpanda does not run scheduled tasks while a CDP
// `Runtime.evaluate` with awaitPromise is outstanding, so any probe that
// awaits a setTimeout hangs there. Loaded as a page, the same probe runs fine.
// Chrome handles both, so `run-probe.mjs` stays the tool for Chrome.
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const probePath = process.argv[2];
const LIGHTPANDA = process.env.LP_BIN || process.env.LIGHTPANDA ||
    path.join(REPO, 'zig-out/bin/lightpanda');
const source = (await fs.readFile(probePath, 'utf8')).trim().replace(/;\s*$/, '');

// The payload goes out base64'd through the DOM dump rather than through
// console.log: the log formatter wraps and pads long strings, which corrupts
// JSON, and base64 survives HTML serialisation untouched.
const html = `<!DOCTYPE html><html><body><div id=out></div><script type=module>
// A pending timer keeps the load alive: without one, \`fetch --dump\` can decide
// the page is done before a probe's later awaits have been scheduled.
const keepalive = setInterval(() => {}, 50);
const result = await (${source});
clearInterval(keepalive);
const json = JSON.stringify(result, null, 1);
document.getElementById('out').textContent = '@@PROBE@@' + btoa(unescape(encodeURIComponent(json))) + '@@END@@';
</script></body></html>`;

const server = http.createServer((_, res) => {
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end(html);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lp-page-probe-'));
const proc = spawn(LIGHTPANDA, ['fetch', '--dump', `http://127.0.0.1:${port}/`], {
  stdio: ['ignore', 'pipe', 'pipe'],
  cwd: dir,
});
let out = '';
proc.stdout.on('data', (d) => { out += d; });
proc.stderr.on('data', (d) => { out += d; });
await new Promise((r) => proc.on('exit', r));
server.close();
await fs.rm(dir, { recursive: true, force: true }).catch(() => {});

const start = out.indexOf('@@PROBE@@');
const end = out.indexOf('@@END@@');
if (start < 0 || end < 0) {
  console.error(out.slice(-4000));
  process.exit(1);
}
// A long payload comes back wrapped across lines by the dump, and base64
// carries no whitespace, so stripping it is lossless.
const payload = out.slice(start + '@@PROBE@@'.length, end).replace(/\s+/g, '');
console.log(Buffer.from(payload, 'base64').toString('utf8'));
