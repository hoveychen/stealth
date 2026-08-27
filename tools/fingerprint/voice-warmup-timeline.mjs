// When does the voice list arrive, and what starts its clock?
//
// `speech-voice-warmup-race` P1 asks which end to change: shorten the 665ms this
// engine models, or move the moment the clock starts. Both only make sense once
// Chrome's own answer to two questions is on the table:
//
//   1. Does the first getVoices() *trigger* the load?  Ask late (--delay 3000) in
//      a browser where nothing has touched speechSynthesis. A list that is already
//      there means the load was never the page's to start.
//   2. Is the list per page or per browser?  Ask on a second navigation
//      (--navs 2) in the same process, or in a child document (--iframe) of a
//      window that has already been handed the list.
//
// Every arm answers from a page load, not from Runtime.evaluate: this engine does
// not run scheduled tasks while an awaitPromise evaluate is outstanding, and the
// whole measurement is scheduled tasks. The driver polls a sync evaluate instead.
//
// usage: node tools/fingerprint/voice-warmup-timeline.mjs <chrome|lightpanda>
//            [--headed] [--delay MS] [--navs N] [--listen] [--port P]
//
// Env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: voice-warmup-timeline.mjs <chrome|lightpanda> [--headed] [--delay MS] [--navs N] [--listen]');
    process.exit(2);
}
const arg = (name, dflt) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? dflt : process.argv[i + 1];
};
const headed = process.argv.includes('--headed');
const listen = process.argv.includes('--listen');
const iframe = process.argv.includes('--iframe');
const delay = Number(arg('--delay', 0));
const navs = Number(arg('--navs', 1));
const PORT = Number(arg('--port', 0)) || Number(process.env.PORT) || (engine === 'chrome' ? 17210 : 17211);
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LIGHTPANDA = process.env.LP_BIN || process.env.LIGHTPANDA || path.join(REPO, 'zig-out/bin/lightpanda');

// The measurement page. Nothing here touches `speechSynthesis` before the delay
// elapses -- not even to attach a listener -- so the --delay arm really is a
// browser in which the page has never asked.
const page = (d, withListener, withIframe) => `<!DOCTYPE html><html><head><script>
var t0 = performance.now();
var res = { delay: ${d}, timeOriginMs: Math.round(performance.timeOrigin), first: null, filledAt: null, voiceschangedAt: null, samples: [] };
var wantSub = ${withIframe ? 'true' : 'false'};
function finish() {
  if (window.parent !== window) { window.parent.postMessage({ voiceSub: res }, '*'); return; }
  if (wantSub && !res.sub) { addSub(); return; }
  var out = document.getElementById('out');
  if (out) out.textContent = '@@' + JSON.stringify(res) + '@@';
  else document.addEventListener('DOMContentLoaded', finish);
}
// A same-origin child document in an already-warm browser: the browser process
// has the list, but this window's SpeechSynthesis has never asked for it.
function addSub() {
  window.addEventListener('message', function (e) {
    if (!e.data || !e.data.voiceSub) return;
    res.sub = e.data.voiceSub;
    res.sub.createdAt = Math.round(subAt);
    finish();
  });
  var subAt = performance.now() - t0;
  var f = document.createElement('iframe');
  f.src = '?delay=0&sub=1';
  (document.body || document.documentElement).appendChild(f);
}
${withListener ? `speechSynthesis.addEventListener('voiceschanged', function () { res.voiceschangedAt = Math.round(performance.now() - t0); });` : ''}
setTimeout(function () {
  var at = performance.now() - t0;
  var len = speechSynthesis.getVoices().length;
  res.first = { at: Math.round(at), len: len };
  if (len > 0) { res.filledAt = Math.round(at); finish(); return; }
  var started = performance.now();
  var iv = setInterval(function () {
    var t = performance.now();
    var l = speechSynthesis.getVoices().length;
    res.samples.push([Math.round(t - t0), l]);
    if (l > 0) { res.filledAt = Math.round(t - t0); clearInterval(iv); finish(); }
    else if (t - started > 3000) { clearInterval(iv); finish(); }
  }, 25);
}, ${d});
// A pending timer keeps this engine from declaring the load done before the
// answer lands.
setInterval(function () {}, 50);
</script></head><body><div id=out></div></body></html>`;

const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://127.0.0.1');
    res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
    res.end(page(
        Number(u.searchParams.get('delay') || 0),
        u.searchParams.get('listen') === '1',
        u.searchParams.get('iframe') === '1',
    ));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const pagePort = server.address().port;

try {
    const stale = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
    console.error(`port ${PORT} already serves CDP (${stale['Browser'] ?? '?'}) -- refusing to measure someone else's browser`);
    process.exit(2);
} catch (e) {
    if (e instanceof SyntaxError) throw e;
}

let proc, prof;
const spawnedAt = Date.now();
if (engine === 'chrome') {
    prof = await fs.mkdtemp(path.join(os.tmpdir(), 'voice-warm-'));
    const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`, '--no-first-run', '--no-default-browser-check', '--window-size=1920,1080'];
    if (!headed) args.push('--headless=new');
    proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 200; i++) {
    try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(100); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
// Both arms get the same domains enabled: Chrome needs Page for navigation
// lifecycle and this engine must not be driven with a different set.
await cdp.send('Page.enable', {}, sessionId).catch(() => {});

const out = [];
for (let n = 0; n < navs; n++) {
    const url = `http://127.0.0.1:${pagePort}/?delay=${delay}&listen=${listen ? 1 : 0}&iframe=${iframe ? 1 : 0}&n=${n}`;
    const browserAgeMs = Date.now() - spawnedAt;
    await cdp.send('Page.navigate', { url }, sessionId);
    let text = '';
    const deadline = Date.now() + Math.max(20000, delay + 12000);
    while (Date.now() < deadline) {
        await sleep(200);
        try {
            const r = await cdp.send('Runtime.evaluate', {
                expression: "(document.getElementById('out')||{}).textContent||''",
                returnByValue: true,
            }, sessionId);
            text = r.result?.value || '';
            if (text.startsWith('@@')) break;
        } catch { /* context swapping during navigation */ }
    }
    if (!text.startsWith('@@')) {
        out.push({ nav: n, browserAgeMs, error: 'no answer before deadline' });
        continue;
    }
    out.push({ nav: n, browserAgeMs, ...JSON.parse(text.slice(2, -2)) });
}

console.log(JSON.stringify({ engine, headed, delay, navs, listen, iframe, runs: out }, null, 1));

cdp.close();
proc.kill('SIGKILL');
server.close();
if (prof) await fs.rm(prof, { recursive: true, force: true });
process.exit(0);
