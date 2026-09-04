// Which frame shape makes the top document answer with a child frame's URL?
//
// Live on the Cloudflare interstitial, three lightpanda runs out of three, the
// top realm -- window === top, DOM plainly the interstitial -- reports the
// *widget iframe's* URL from location.href, location.origin, document.URL and
// baseURI, while window.origin and document.domain stay correct (README, "the
// top frame's URL reads as the widget iframe's"). This is the bisect that found
// the smallest page that does it.
//
// One shape per run; the top realm reports its own URL fields every 500 ms and
// the run prints whether they ever stop being the top's. Measured, lightpanda
// dev.788 against Chrome 151:
//
//   S1  cross-origin child, parent sets src                        clean
//   S2  child one level down, inside a srcdoc frame                clean
//   S3  child one level down, inside a blob: frame                 clean
//   S4  child creates a blob: frame of its own                     clean
//   S5  child creates about:blank and document.writes into it      clean
//   S6  child creates a srcdoc frame of its own                    clean
//   T1  child replaceState, top never touches history              clean
//   T2  child sets location.hash                                   clean
//   T3  nested cross-origin grandchild, hash-navigated             clean
//   T6  top replaceState, then child sets location.hash            clean
//   T7  child replaceState then its own hash, top untouched        clean
//   T5  top replaceState, then child replaceState                  **LEAK**
//   T4  T5 plus a following child hash change                      **LEAK**
//   T8  child replaceState first, top replaceState second          **LEAK**
//   T9  T5 with the child on the *same* origin                     **LEAK**
//
// All fifteen read clean since History and Navigation became per-frame objects
// (src/browser/Frame.zig `_history` / `_navigation`, over the session-wide entry
// list in Navigation.State), and T9 now reports `sameHistory=false
// sameNavigation=false` the way Chrome does. The regression test is
// src/browser/tests/frames/frame_own_url.html.
//
// T8's verdict came from a broken predicate and was wrong in both directions;
// see the `okTop` comment near the bottom. Its real leak is the mirror of T5's:
// the *child* ended up on the top's path (`localhost:PORT/host.html?child_first=1`)
// because its replaceState resolved against the top's URL.
//
// So it needs two frames both using the history API, and it does not need
// cross-origin: T9 leaks with a same-origin child, which is what makes it
// writable as an ordinary test. Chrome is clean on T4, T5 and T9. In the leaking
// runs the top's URL becomes the *child's* path and query resolved against the
// *top's* origin -- the shape of `URL.resolve(topFrame.url, <the string the
// child passed>)` -- and the child's own URL does not move at all.
//
// The same-origin shape can ask the obvious next question directly, and does:
// from inside the child, `history === parent.history` is **true** in this engine
// and false in Chrome, and so is `navigation === parent.navigation`
// (`location === parent.location` is false in both, correctly). One History
// object for the whole session is what `Window.getHistory` returns
// (`&frame._session.history`), and the `frame: *Frame` its methods receive comes
// from the *context* the wrapper belongs to, not from the caller -- so a child's
// `replaceState` acts on whichever frame's realm owns that one shared wrapper.
//
// usage: node frame-url-history.mjs <chrome|lightpanda> --shape <S1..S6|T1..T9> [--port 9800]
//   (each run needs three free ports: PORT, PORT+1 for the top, PORT+2 for the child)
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const engine = process.argv[2];
const arg = (n, d) => { const i = process.argv.indexOf(n); return i < 0 ? d : process.argv[i + 1]; };
const PORT = Number(arg('--port', '9800'));
const SHAPE = arg('--shape', 'S1');
const TOP = PORT + 1;
const KID = PORT + 2;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || '/Users/hoveychen/workspace/stealth/zig-out/bin/lightpanda';

const REPORT = (who) => `
<script>
(function () {
  var log = console.log.bind(console);
  var n = 0;
  function tick() {
    var f = {};
    var p = {
      href: function () { return location.href; },
      lorigin: function () { return location.origin; },
      docURL: function () { return document.URL; },
      baseURI: function () { return document.baseURI; },
      worigin: function () { return window.origin; },
      isTop: function () { return String(window === top); },
      kids: function () { return String(frames.length); },
      sameHistory: function () { return window === top ? '-' : String(history === parent.history); },
      sameNavigation: function () { return window === top ? '-' : String(navigation === parent.navigation); },
      sameLocation: function () { return window === top ? '-' : String(location === parent.location); }
    };
    for (var k in p) { try { f[k] = String(p[k]()); } catch (e) { f[k] = 'threw'; } }
    f.who = '${who}';
    f.tick = n++;
    log('@@F@@' + JSON.stringify(f) + '@@END@@');
  }
  setInterval(tick, 500);
  tick();
})();
</script>`;

// The child page, which builds whatever nesting the shape asks for once it is
// itself cross-origin from the top.
const kidBody = (shape) => `<!DOCTYPE html><html><head><title>KID</title></head><body>kid${REPORT('kid')}
<script>
var S = ${JSON.stringify(shape)};
function add(src) { var f = document.createElement('iframe'); if (src) f.src = src; document.body.appendChild(f); return f; }
setTimeout(function () {
  try {
    if (S === 'T1') {
      history.replaceState(null, '', location.pathname + '?child_tok=abc');
    } else if (S === 'T2') {
      location.hash = 'child-frag';
    } else if (S === 'T3') {
      var f3 = document.createElement('iframe');
      f3.src = 'http://localhost:' + location.port + '/deep.html';
      document.body.appendChild(f3);
      setTimeout(function () { f3.contentWindow.location.hash = 'deep'; }, 600);
    } else if (S === 'T4' || S === 'T7') {
      history.replaceState(null, '', location.pathname + '?child_tok=xyz');
      setTimeout(function () { location.hash = 'child-frag2'; }, 400);
    } else if (S === 'T8') {
      history.replaceState(null, '', location.pathname + '?child_first=1');
    } else if (S === 'T9') {
      history.replaceState(null, '', location.pathname + '?same_origin_child=1');
    } else if (S === 'T5') {
      history.replaceState(null, '', location.pathname + '?child_tok=only');
    } else if (S === 'T6') {
      location.hash = 'child-frag-only';
    } else if (S === 'S4') {
      var b = new Blob(['<!DOCTYPE html><html><body>blob-kid<' + '/body></html>'], { type: 'text/html' });
      add(URL.createObjectURL(b));
    } else if (S === 'S5') {
      var f = add('');
      var d = f.contentDocument;
      d.open(); d.write('<!DOCTYPE html><html><body>written<' + '/body></html>'); d.close();
    } else if (S === 'S6') {
      var f2 = document.createElement('iframe');
      f2.srcdoc = '<!DOCTYPE html><html><body>srcdoc-kid<' + '/body></html>';
      document.body.appendChild(f2);
    }
  } catch (e) { console.log('kid-shape-failed:' + e); }
}, 1200);
</script></body></html>`;

// The top page. S1 is the control; S2/S3 put the cross-origin child one level
// down, inside a srcdoc or blob: frame owned by the top.
const topBody = (shape) => `<!DOCTYPE html><html><head><title>TOP</title></head><body>
<div id=host></div>${REPORT('top')}
<script>
var S = ${JSON.stringify(shape)};
var KID = (S === 'T9' ? 'http://127.0.0.1:${TOP}/kid.html' : 'http://localhost:${KID}/kid.html');
function add(parentEl, src, srcdoc) {
  var f = document.createElement('iframe');
  f.width = 300; f.height = 65;
  if (srcdoc !== undefined) f.srcdoc = srcdoc; else if (src) f.src = src;
  parentEl.appendChild(f);
  return f;
}
if (S === 'T8') { setTimeout(function () { try { history.replaceState(null, '', location.pathname + '?top_second=1'); } catch (e) {} }, 1500); }
if (S === 'T4' || S === 'T5' || S === 'T6' || S === 'T9') { try { history.replaceState(null, '', location.pathname + '?__cf_chl_rt_tk=TOPTOKEN'); } catch (e) { console.log('top-replace-failed:' + e); } }
setTimeout(function () {
  try {
    var host = document.getElementById('host');
    if (S === 'S2') {
      add(host, null, '<!DOCTYPE html><html><body>srcdoc<iframe src="' + KID + '"><' + '/iframe><' + '/body><' + '/html>');
    } else if (S === 'S3') {
      var b = new Blob(['<!DOCTYPE html><html><body>blob<iframe src="' + KID + '"><' + '/iframe><' + '/body><' + '/html>'], { type: 'text/html' });
      add(host, URL.createObjectURL(b));
    } else {
      add(host, KID);
    }
  } catch (e) { console.log('top-shape-failed:' + e); }
}, 500);
</script></body></html>`;

const servers = [];
for (const [port, body] of [[TOP, topBody(SHAPE)], [KID, kidBody(SHAPE)]]) {
    servers.push(await new Promise((r) => {
        const s = http.createServer((req, res) => {
            res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
            // /kid.html on the top's own origin, so the same-origin variant does
            // not need a third server.
            res.end(req.url.startsWith('/kid.html') ? kidBody(SHAPE) : body);
        });
        s.listen(port, '127.0.0.1', () => r(s));
    }));
}

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fus-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new'], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', () => { });
proc.stderr.on('data', () => { });

const rows = [];
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
                await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, child).catch(() => { });
                await cdp.send('Runtime.runIfWaitingForDebugger', undefined, child).catch(() => { });
            })();
        }
        if (msg.method === 'Runtime.consoleAPICalled') {
            const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
            const m = /^@@F@@([\s\S]*)@@END@@$/.exec(text);
            if (m) rows.push(JSON.parse(m[1]));
            else if (text.includes('failed')) rows.push({ who: 'err', href: text });
        }
    });
    for (const d of ['Runtime', 'Page']) await cdp.send(`${d}.enable`, undefined, sessionId).catch(() => { });
    await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId).catch(() => { });
    await cdp.send('Page.navigate', { url: `http://127.0.0.1:${TOP}/host.html` }, sessionId);
    await sleep(5000);
} catch (e) {
    rows.push({ who: 'driver', href: String(e.message ?? e) });
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    for (const s of servers) s.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

// Shapes where the top moves *itself* and is supposed to: those end on the
// URL its own replaceState asked for, not on host.html. T8 was missing here,
// which made the predicate lie in both directions -- it called the pre-fix
// engine clean (the top never moved, because its replaceState had been routed
// to the child) and called a correct engine a leak. Chrome 151 measured on T8
// reports exactly `host.html?top_second=1`.
// Every URL the top is allowed to be reporting. More than one when the top
// moves *itself* partway through the run: the ticks before its own
// replaceState still legitimately read the URL it loaded on.
const okTop = [`http://127.0.0.1:${TOP}/host.html`];
if (SHAPE === 'T4' || SHAPE === 'T5' || SHAPE === 'T6' || SHAPE === 'T9') {
    okTop.length = 0;
    okTop.push(`http://127.0.0.1:${TOP}/host.html?__cf_chl_rt_tk=TOPTOKEN`);
} else if (SHAPE === 'T8') {
    // T8 was missing here, which made the predicate lie in both directions: it
    // called the pre-fix engine clean (the top never moved, because its own
    // replaceState had been routed to the child) and called a correct engine a
    // leak. Chrome 151 on T8 reports exactly `host.html?top_second=1`.
    okTop.push(`http://127.0.0.1:${TOP}/host.html?top_second=1`);
}
const tops = rows.filter((r) => r.who === 'top' && r.tick > 0);
const isOk = (u) => okTop.includes(u.split('#')[0]);
const bad = tops.filter((r) => !isOk(r.href) || !isOk(r.docURL) || !isOk(r.baseURI)
    || r.lorigin !== `http://127.0.0.1:${TOP}`);
// A top that moves itself must actually arrive. Without this, a shape whose
// starting URL is also an allowed one (T8) reads as clean on an engine that
// routed the top's own replaceState to the child and left it where it began.
const endTop = okTop[okTop.length - 1];
const lastTop = tops[tops.length - 1];
if (bad.length === 0 && (!lastTop || lastTop.href.split('#')[0] !== endTop)) {
    bad.push(lastTop ?? { tick: -1, href: `no top reports; expected to end on ${endTop}`, docURL: '', baseURI: '', lorigin: '', worigin: '' });
}
const kidRows = rows.filter((r) => r.who === 'kid');
console.log(`--- ${engine} ${SHAPE} --- top reports: ${tops.length}, wrong: ${bad.length}`);
for (const r of (bad.length ? bad : tops).slice(0, 6)) {
    console.log(`  tick=${r.tick} isTop=${r.isTop} kids=${r.kids} href=${r.href} lorigin=${r.lorigin} docURL=${r.docURL} baseURI=${r.baseURI} worigin=${r.worigin}`);
}
const k = kidRows[kidRows.length - 1];
console.log(`  kid reports: ${kidRows.length}${k ? `, last href=${k.href} sameHistory=${k.sameHistory} sameNavigation=${k.sameNavigation} sameLocation=${k.sameLocation}` : ''}`);
for (const r of rows.filter((r) => r.who === 'err' || r.who === 'driver')) console.log(`  NOTE ${r.href}`);
console.log(bad.length ? 'LEAK' : 'clean');
process.exit(0);
