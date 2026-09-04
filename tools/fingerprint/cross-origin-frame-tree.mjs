// What a cross-origin WindowProxy answers about the frame tree.
//
// A script that wants to know how deep it is walks up until a window is its own
// parent: `while (w !== w.parent) w = w.parent`. Every hop after the first reads
// `parent` off a *cross-origin* WindowProxy, which is a different object with a
// different accessor set, so the walk only terminates if that object answers the
// way a browser's does. Cloudflare's widget does this walk.
//
// The nesting below is four deep on purpose:
//
//   top (origin A) -> a (A) -> b (A) -> c (B)
//
// so `c` sees a proxy (`b`) whose `parent` and `top` are *different* windows --
// the only shape that tells `top` apart from `parent`. A two-deep tree cannot:
// there, the parent of the parent is the top, and a `top` that wrongly returns
// the parent looks right.
//
// `c` reports both proxies it can reach: `window.parent` (a proxy with a parent)
// and `window.top` (a proxy that is its own parent). Between them they cover the
// whole cross-origin safelist this engine implements -- parent, top, window,
// self, frames, length, opener, closed.
//
// usage: node cross-origin-frame-tree.mjs <chrome|lightpanda> [--port 9101]
//   (each run needs three free ports: PORT for CDP, PORT+1 and PORT+2 for the
//    two origins)
// env: CHROME, LP_BIN
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const engine = process.argv[2];
const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const PORT = Number(arg('--port', '9101'));
const A = PORT + 1;
const B = PORT + 2;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || '/Users/hoveychen/workspace/stealth/zig-out/bin/lightpanda';

const nest = (src) => `<!DOCTYPE html><html><body><script>
var f = document.createElement('iframe');
f.src = ${JSON.stringify(src)};
document.body.appendChild(f);
</script></body></html>`;

// The innermost frame, cross-origin to the three above it.
const leaf = `<!DOCTYPE html><html><body><script>
(function () {
  var out = {};
  function read(name, fn) { try { out[name] = String(fn()); } catch (e) { out[name] = 'threw: ' + e.name; } }

  read('depth', function () {
    var w = window, d = 0;
    while (w !== w.parent && d < 20) { w = w.parent; d++; }
    return d;
  });
  read('parentIsSelf', function () { return window.parent === window; });
  read('topIsParent', function () { return window.top === window.parent; });

  // p is the proxy for b, two frames down from the top: its parent (a) and its
  // top are different windows.
  var p = window.parent, t = window.top;
  read('p_type', function () { return typeof p; });
  read('p_tag', function () { return Object.prototype.toString.call(p); });
  read('p_topIsTop', function () { return p.top === t; });
  read('p_parentIsTop', function () { return p.parent === t; });
  read('p_parentIsSelf', function () { return p.parent === p; });
  read('p_windowIsSelf', function () { return p.window === p; });
  read('p_selfIsSelf', function () { return p.self === p; });
  read('p_framesIsSelf', function () { return p.frames === p; });
  read('p_length', function () { return p.length; });
  read('p_closed', function () { return p.closed; });
  read('p_openerType', function () { return typeof p.opener; });
  read('p_opener', function () { return p.opener; });

  // t is the proxy for the top frame: its parent and its top are both itself.
  read('t_parentIsSelf', function () { return t.parent === t; });
  read('t_topIsSelf', function () { return t.top === t; });
  read('t_grandparentIsSelf', function () { return t.parent.parent === t; });
  read('t_windowIsSelf', function () { return t.window === t; });
  read('t_framesIsSelf', function () { return t.frames === t; });
  read('t_length', function () { return t.length; });
  read('t_closed', function () { return t.closed; });
  read('t_openerType', function () { return typeof t.opener; });

  console.log('@@R@@' + JSON.stringify(out) + '@@END@@');
})();
</script></body></html>`;

const routes = {
    [A]: {
        '/top.html': nest(`http://127.0.0.1:${A}/a.html`),
        '/a.html': nest(`http://127.0.0.1:${A}/b.html`),
        '/b.html': nest(`http://127.0.0.1:${B}/c.html`),
    },
    [B]: { '/c.html': leaf },
};

const servers = [];
for (const port of [A, B]) {
    servers.push(await new Promise((r) => {
        const s = http.createServer((req, res) => {
            const body = routes[port][req.url.split('?')[0]];
            res.writeHead(body ? 200 : 404, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
            res.end(body ?? 'no');
        });
        s.listen(port, '127.0.0.1', () => r(s));
    }));
}

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'coft-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new'], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', () => { });
proc.stderr.on('data', () => { });

let reading = null;
let cdp;
try {
    for (let i = 0; i < 80; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) break;
        } catch { /* not up yet */ }
        await sleep(250);
    }
    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    cdp.on((msg) => {
        const p = msg.params ?? {};
        // Chrome puts the cross-origin leaf in its own target, so the reading
        // only arrives if every auto-attached child session is enabled too.
        if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
            const child = p.sessionId;
            (async () => {
                for (const d of ['Runtime', 'Page']) await cdp.send(`${d}.enable`, undefined, child).catch(() => { });
                await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, child).catch(() => { });
                await cdp.send('Runtime.runIfWaitingForDebugger', undefined, child).catch(() => { });
            })();
        }
        if (msg.method === 'Runtime.consoleAPICalled') {
            const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
            const m = /@@R@@([\s\S]*)@@END@@/.exec(text);
            if (m) reading = JSON.parse(m[1]);
        }
    });
    for (const d of ['Runtime', 'Page']) await cdp.send(`${d}.enable`, undefined, sessionId).catch(() => { });
    await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId).catch(() => { });
    await cdp.send('Page.navigate', { url: `http://127.0.0.1:${A}/top.html` }, sessionId);
    await sleep(5000);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    for (const s of servers) s.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

console.log(JSON.stringify({ engine, reading }, null, 1));
