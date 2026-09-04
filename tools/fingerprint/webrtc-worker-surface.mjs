// Ground truth for the *worker* half of the RTC surface: which RTC* globals a
// DedicatedWorkerGlobalScope carries, and the full shape of each.
//
//   node tools/fingerprint/webrtc-worker-surface.mjs chrome --headed
//   node tools/fingerprint/webrtc-worker-surface.mjs lightpanda
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, newPage, evaluate, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2] ?? 'lightpanda';
const LP = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT) || Number(process.env.LP_PORT) || 9474;

let proc;
if (engine === 'chrome') {
    const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'webrtc-worker-'));
    const headed = process.argv.includes('--headed');
    proc = spawn(CHROME, [
        ...(headed ? [] : ['--headless=new']), `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${prof}`, '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
const logFile = createWriteStream('/tmp/webrtc-worker-engine.log');
proc.stdout.pipe(logFile);
proc.stderr.pipe(logFile);
await sleep(engine === 'chrome' ? 1500 : 2500);

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { sessionId } = await newPage(cdp);
await cdp.send('Page.navigate', { url: 'about:blank' }, sessionId);
await sleep(500);

// The body runs *inside* the worker and posts its findings back.
const WORKER_BODY = `
const NAMES = Object.getOwnPropertyNames(self).filter((k) => /^RTC/.test(k));
const out = { names: NAMES, classes: {}, chains: {}, ctorThrows: {} };
for (const n of NAMES) {
  const C = self[n];
  const r = { statics: [], proto: [], length: C.length, name: C.name };
  for (const k of Object.getOwnPropertyNames(C)) {
    if (['length','name','prototype'].includes(k)) continue;
    r.statics.push(k);
  }
  const p = C.prototype;
  if (p) {
    for (const k of Object.getOwnPropertyNames(p)) {
      const d = Object.getOwnPropertyDescriptor(p, k);
      r.proto.push(k + (d.get || d.set ? ':accessor' + (d.get ? '/get' : '') + (d.set ? '/set' : '')
                                       : typeof d.value === 'function' ? ':method/' + d.value.length
                                       : ':' + typeof d.value));
    }
  }
  out.classes[n] = r;
  const chain = [];
  let q = p ? Object.getPrototypeOf(p) : null;
  while (q) { chain.push(q.constructor ? q.constructor.name : '?'); q = Object.getPrototypeOf(q); }
  out.chains[n] = { protoChain: chain,
    classProto: typeof Object.getPrototypeOf(C) === 'function' ? Object.getPrototypeOf(C).name : String(Object.getPrototypeOf(C)),
    desc: (() => { const d = Object.getOwnPropertyDescriptor(self, n);
                   return d && { writable: d.writable, enumerable: d.enumerable, configurable: d.configurable }; })() };
  try { new C(); out.ctorThrows[n] = 'ok'; } catch (e) { out.ctorThrows[n] = String(e).slice(0, 110); }
}
self.postMessage(out);
`;

const src = `(async () => {
  const blob = new Blob([${JSON.stringify(WORKER_BODY)}], { type: 'text/javascript' });
  const w = new Worker(URL.createObjectURL(blob));
  return await new Promise((resolve) => {
    w.onmessage = (e) => { resolve(e.data); w.terminate(); };
    w.onerror = (e) => resolve({ error: String(e.message || e) });
    setTimeout(() => resolve({ error: 'timeout' }), 4000);
  });
})()`;

const out = await evaluate(cdp, sessionId, src, { awaitPromise: true });
await fs.writeFile(`/tmp/webrtc-worker-${engine}.json`, JSON.stringify(out, null, 1));
console.log(`wrote /tmp/webrtc-worker-${engine}.json`);
console.log('names:', JSON.stringify(out.names ?? out));

cdp.close();
proc.kill('SIGKILL');
