// G8: reproduce iphey's `i20: TypeError: Illegal invocation` and attribute it.
// Patches alert() to record a stack, and wraps the reflection entry points the
// README already suspects so a throw names the receiver.
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   PORT     CDP port to use, so two runs can go at once
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, newPage, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const LP_BIN = process.env.LP_BIN || process.env.LIGHTPANDA ||
    path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || 9302;
const proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.resume(); proc.stderr.resume();
for (let i = 0; i < 200; i++) {
  try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(200); }
}
const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { sessionId } = await newPage(cdp);

const init = `
(() => {
  globalThis.__g8 = { alerts: [], throws: [] };
  const rec = (kind, detail) => {
    let stack = '';
    try { stack = new Error().stack || ''; } catch {}
    globalThis.__g8[kind].push({ detail, stack: String(stack).split('\\n').slice(1, 8).join(' | ') });
  };
  const alert0 = globalThis.alert;
  globalThis.alert = function (msg) { rec('alerts', String(msg)); };
  const wrap = (obj, name, label) => {
    const orig = obj[name];
    if (typeof orig !== 'function') return;
    obj[name] = function (...args) {
      try { return orig.apply(this, args); }
      catch (e) {
        let who = '?';
        try { who = (args[0] && (args[0].name || Object.prototype.toString.call(args[0]))) || String(args[0]); } catch {}
        rec('throws', label + '(' + who + (args.length > 1 ? ', ' + String(args[1]) : '') + ') -> ' + e.name + ': ' + e.message);
        throw e;
      }
    };
  };
  // iphey's catch does String(err), which routes through Error.prototype
  // .toString -- the one place the thrown object's own stack is still reachable.
  const errToString = Error.prototype.toString;
  Error.prototype.toString = function () {
    try {
      globalThis.__g8.throws.push({
        detail: errToString.call(this),
        stack: String(this.stack || '').split('\\n').slice(0, 12).join(' | '),
      });
    } catch {}
    return errToString.call(this);
  };
  wrap(Object, 'getOwnPropertyDescriptor', 'gOPD');
  wrap(Object, 'getOwnPropertyDescriptors', 'gOPDs');
  wrap(Object, 'getOwnPropertyNames', 'gOPN');
  wrap(Object, 'keys', 'keys');
  wrap(Function.prototype, 'toString', 'fnToString');
  wrap(Object.prototype, 'toString', 'objToString');
  wrap(JSON, 'stringify', 'jsonStringify');
})();
`;
await cdp.send('Page.enable', {}, sessionId).catch(() => {});
await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: init }, sessionId);
await cdp.send('Page.navigate', { url: 'https://iphey.com/' }, sessionId);
await sleep(20000);
for (const expr of ['typeof globalThis.__g8', 'location.href', 'JSON.stringify(globalThis.__g8 || null, null, 1)']) {
  const res = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true }, sessionId);
  console.log('>>> ' + expr + ' = ' + JSON.stringify(res.result?.result?.value ?? res.result));
}
proc.kill();
process.exit(0);
