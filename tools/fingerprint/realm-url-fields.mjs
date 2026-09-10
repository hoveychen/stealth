// What URL does each realm on a live page think it is on? One report per realm
// every 3 s over the console (a main-frame evaluate cannot reach a cross-origin
// realm in this engine), naming the whole URL surface plus the frame's depth,
// title and body, so a realm that answers with *another* frame's URL is visible
// without having to guess which frame it borrowed from.
//
// Written for the top-realm URL deviation on the Cloudflare interstitial
// (README, "A frame's URL is its own"): the tell is one realm contradicting
// itself, location.origin against window.origin, which needs both read in the
// same report. frame-url-history.mjs is the offline bisect of the same thing;
// this is the live reading.
//
// usage: node realm-url-fields.mjs <chrome|lightpanda> [--port 9760] [--settle 30000] [--url ...]
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';
import { headedUserAgent } from './fo-harness.mjs';

const engine = process.argv[2];
const arg = (n, d) => { const i = process.argv.indexOf(n); return i < 0 ? d : process.argv[i + 1]; };
const PORT = Number(arg('--port', '9760'));
const SETTLE = Number(arg('--settle', '30000'));
const URL_ = arg('--url', 'https://www.scrapingcourse.com/antibot-challenge');
// Ask the browser for its user agent instead of writing the version down. This
// was a hardcoded `Chrome/151.0.0.0`; Chrome moved to 152 and the guards began
// refusing the mismatch (see cf-verdict.mjs for the full account -- it read
// `served=false` on both arms, control included, on a station that was passing).
// Only the Chrome arm sends it, so the probe is skipped entirely otherwise.
const UA = engine === 'chrome' ? await headedUserAgent(PORT + 900) : null;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || '/Users/hoveychen/workspace/stealth/zig-out/bin/lightpanda';

const SRC = String.raw`
(function () {
  if (globalThis.__PEEK) return;
  globalThis.__PEEK = 1;
  var origLog = console.log.bind(console);
  function rect(el) {
    try { var r = el.getBoundingClientRect(); return [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)]; } catch (e) { return 'threw'; }
  }
  function describe(el) {
    var out = { tag: el.tagName, rect: rect(el) };
    try { out.type = el.getAttribute('type'); } catch (e) { }
    try { out.id = el.id; } catch (e) { }
    try { out.cls = String(el.className).slice(0, 60); } catch (e) { }
    try { out.txt = String(el.textContent || '').trim().slice(0, 60); } catch (e) { }
    try { out.vis = typeof el.checkVisibility === 'function' ? el.checkVisibility() : 'n/a'; } catch (e) { out.vis = 'threw'; }
    return out;
  }
  function report() {
    var o = { realm: '?', bodyLen: -1, title: '?', els: [], iframes: [] };
    try { var d = 0, w = window; while (w !== w.parent && d < 20) { w = w.parent; d++; } o.depth = d; } catch (e) { o.depth = -1; }
    try { o.rid = (globalThis.__PEEKRID = globalThis.__PEEKRID || Math.random().toString(36).slice(2, 8)); } catch (e) { }
    try { o.realm = location.href; } catch (e) { }
    try { o.title = document.title; } catch (e) { }
    var f = {};
    var probes = {
      'location.href': function () { return location.href; },
      'location.origin': function () { return location.origin; },
      'location.pathname': function () { return location.pathname; },
      'document.URL': function () { return document.URL; },
      'document.baseURI': function () { return document.baseURI; },
      'document.documentURI': function () { return document.documentURI; },
      'document.referrer': function () { return document.referrer; },
      'window.origin': function () { return window.origin; },
      'document.domain': function () { return document.domain; },
      'window===top': function () { return String(window === top); },
      'frames.length': function () { return String(frames.length); },
      // How deep a script thinks it is, and what the proxy it walked through
      // answers about the rest of the tree. A cross-origin realm reads these off
      // a WindowProxy, not a Window, so they are a different set of accessors --
      // see cross-origin-frame-tree.mjs for the offline reading of the same
      // names. '-' where the realm is the top and has no proxy to ask.
      'depth': function () { return String(o.depth); },
      'parent.parent===parent': function () { return window === top ? '-' : String(parent.parent === parent); },
      'parent.top===top': function () { return window === top ? '-' : String(parent.top === top); },
      'parent.length': function () { return window === top ? '-' : String(parent.length); },
      'parent.closed': function () { return window === top ? '-' : String(parent.closed); },
      'typeof parent.opener': function () { return window === top ? '-' : typeof parent.opener; },
      'toString(parent)': function () { return window === top ? '-' : Object.prototype.toString.call(parent); },
      'base.href': function () { var b = document.querySelector('base'); return b ? b.href : '(no base)'; },
    };
    for (var k in probes) { try { f[k] = String(probes[k]()); } catch (e) { f[k] = 'threw: ' + e.message; } }
    o.fields = f;
    try { o.bodyLen = document.body ? document.body.innerHTML.length : -1; } catch (e) { }
    try { o.bodyText = (document.body ? String(document.body.innerText || document.body.textContent || '') : '').trim().slice(0, 200); } catch (e) { }
    try {
      var sel = document.querySelectorAll('input, label, button, [role=checkbox], [role=button], a[href]');
      for (var i = 0; i < sel.length && i < 25; i++) o.els.push(describe(sel[i]));
    } catch (e) { o.els.push('threw'); }
    try {
      var fr = document.getElementsByTagName('iframe');
      for (var j = 0; j < fr.length && j < 10; j++) o.iframes.push({ src: String(fr[j].getAttribute('src') || '').slice(0, 90), rect: rect(fr[j]) });
    } catch (e) { }
    try { origLog('@@PEEK@@' + JSON.stringify(o) + '@@END@@'); } catch (e) { }
  }
  try { setInterval(report, 3000); } catch (e) { }
})();
`;

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'peek-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new',
        '--window-size=1920,1080', `--user-agent=${UA}`,
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', () => { });
proc.stderr.on('data', () => { });

const perRealm = new Map();
let cdp;
try {
    for (let i = 0; i < 80; i++) {
        try { const r = await fetch(`http://127.0.0.1:${PORT}/json/version`); if (r.ok) break; } catch { }
        await sleep(250);
    }
    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    cdp.on((msg) => {
        const p = msg.params ?? {};
        if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
            const child = p.sessionId;
            (async () => {
                for (const d of ['Runtime', 'Page']) await cdp.send(`${d}.enable`, undefined, child).catch(() => { });
                await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: SRC }, child).catch(() => { });
                // Chrome puts a cross-origin frame in its own target and attaches
                // *after* its document exists, so the on-new-document hook alone
                // never runs there. The source guards on __PEEK, so evaluating it
                // as well is idempotent.
                await cdp.send('Runtime.evaluate', { expression: SRC }, child).catch(() => { });
                await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, child).catch(() => { });
                await cdp.send('Runtime.runIfWaitingForDebugger', undefined, child).catch(() => { });
            })();
        }
        if (msg.method === 'Runtime.consoleAPICalled') {
            const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
            const m = /^@@PEEK@@([\s\S]*)@@END@@$/.exec(text);
            if (m) {
                try { const o = JSON.parse(m[1]); perRealm.set(`d${o.depth}/${o.rid} ${o.realm}`, o); } catch { }
            }
        }
    });
    for (const d of ['Runtime', 'Page']) await cdp.send(`${d}.enable`, undefined, sessionId).catch(() => { });
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: SRC }, sessionId);
    await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId).catch(() => { });
    await cdp.send('Page.navigate', { url: URL_ }, sessionId);
    await sleep(SETTLE);
} catch (e) {
    console.log('DRIVER ERROR', e.message ?? e);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

console.log(`--- ${engine} ---`);
for (const [realm, o] of perRealm) {
    console.log(`\nrealm ${realm.slice(0, 110)}`);
    console.log(`  title=${JSON.stringify(o.title)} bodyLen=${o.bodyLen}`);
    console.log(`  text=${JSON.stringify(String(o.bodyText || '').slice(0, 160))}`);
    for (const f of o.iframes) console.log(`  iframe ${JSON.stringify(f.rect)} ${f.src}`);
    for (const k in (o.fields ?? {})) console.log(`  ${k.padEnd(22)} ${o.fields[k]}`);
}
process.exit(0);
