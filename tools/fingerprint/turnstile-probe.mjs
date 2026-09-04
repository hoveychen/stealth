// What does a Turnstile widget need that this engine does not give it?
//
// The Cloudflare interstitial gets as far as loading `api.js` and then logs
// `Turnstile Widget seem to have hung` / `Cannot find Widget cf-chl-widget-…`:
// the script runs, builds its hidden response input, and never gets its widget
// container or iframe into the document (README, "Honouring the nonce, and the
// door behind that door"). That is 30s of sweep per reading, on a page nobody
// controls, behind a 403.
//
// This serves the same widget from a local page with Cloudflare's documented
// test sitekey, so the same question takes three seconds and answers the same
// way for Chrome, which is what turns "it does not work" into a diff.
//
// usage: node tools/fingerprint/turnstile-probe.mjs <lightpanda|chrome> [--settle 20000]
//                                                   [--sitekey KEY] [--render explicit]
//                                                   [--out results/x.json] [--headed]
//                                                   [--log-level debug] [--open-shadow]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? fallback : process.argv[i + 1];
};
const has = (name) => process.argv.includes(name);

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: turnstile-probe.mjs <lightpanda|chrome> [--settle ms] [--sitekey KEY] [--render explicit] [--out path] [--headed]');
    process.exit(2);
}

// Cloudflare's published test keys. 1x… is "visible, always passes"; it is
// accepted on any hostname, which is why this can be a localhost page.
const SITEKEY = arg('--sitekey', '1x00000000000000000000AA');
const SETTLE = Number(arg('--settle', '20000'));
const RENDER = arg('--render', 'implicit');
const PORT = engine === 'chrome' ? 9226 : 9227;
const LIGHTPANDA = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Implicit mode is what the interstitial itself uses: api.js finds `.cf-turnstile`
// on its own. Explicit mode says whether the automatic scan is the broken half.
const widget = RENDER === 'explicit'
    ? `<div id="box"></div>
<script>
  window.__cbFired = false;
  window.onloadTurnstileCallback = function () {
    window.__renderReturned = String(turnstile.render('#box', { sitekey: '${SITEKEY}' }));
  };
</script>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onloadTurnstileCallback" async defer></script>`
    : `<div class="cf-turnstile" data-sitekey="${SITEKEY}"></div>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>`;

// The widget puts its iframe in a `closed` shadow root, so nothing outside can
// read it — in either engine. Forcing every root open costs the widget nothing
// (it keeps its own handle) and is the only way to ask both engines the same
// question about the iframe they built.
const openShadow = `<script>
  (function () {
    const real = Element.prototype.attachShadow;
    Element.prototype.attachShadow = function (init) {
      return real.call(this, Object.assign({}, init, { mode: 'open' }));
    };
  })();
</script>`;

const html = `<!DOCTYPE html>
<html><head><title>turnstile probe</title>${has('--open-shadow') ? openShadow : ''}</head>
<body>
${widget}
</body></html>`;

const server = http.createServer((req, res) => {
    if (req.url === '/favicon.ico') {
        res.writeHead(404).end();
        return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(html);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const pageUrl = `http://127.0.0.1:${server.address().port}/`;

const engineLog = [];
let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-turnstile-'))}`,
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        '--window-size=1920,1080',
        ...(has('--headed') ? [] : ['--headless=new']),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info'),
    ], {
        stdio: ['ignore', 'pipe', 'pipe'],
    });
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));
let exit = null;
proc.on('exit', (code, signal) => { exit = { code, signal }; });

// What the widget is asked about, once per reading. Everything here is a plain
// DOM question: the point is which of them the two engines answer differently.
const READ = `(() => {
  const q = (s) => Array.from(document.querySelectorAll(s));
  const idsLike = (prefix) => q('[id]').map((e) => e.id).filter((id) => id.startsWith(prefix));
  const container = document.querySelector('.cf-turnstile') ?? document.getElementById('box');
  return {
    readyState: document.readyState,
    turnstile: typeof window.turnstile,
    turnstileKeys: window.turnstile ? Object.keys(window.turnstile).sort() : null,
    renderReturned: window.__renderReturned ?? null,
    apiScripts: q('script[src*="challenges.cloudflare.com"]').length,
    container: container
      ? { childElementCount: container.childElementCount, innerHTMLLength: container.innerHTML.length, id: container.id || null, innerHTML: container.innerHTML }
      : null,
    widgetIds: idsLike('cf-chl-widget'),
    iframes: q('iframe').map((f) => ({ src: f.src || null, id: f.id || null, parentId: f.parentElement?.id || null })),
    // With --open-shadow, whatever the widget hid from us.
    shadowIframes: q('*').flatMap((e) => e.shadowRoot
      ? Array.from(e.shadowRoot.querySelectorAll('iframe')).map((f) => ({
          hostTag: e.tagName.toLowerCase(),
          hostConnected: e.isConnected,
          id: f.id || null,
          srcAttr: f.getAttribute('src'),
          srcProp: f.src || null,
          sandbox: f.getAttribute('sandbox'),
          isConnected: f.isConnected,
          contentWindow: !!f.contentWindow,
          contentDocumentUrl: (() => { try { return f.contentDocument?.URL ?? null; } catch { return 'cross-origin'; } })(),
        }))
      : []),
    shadowHTMLLength: q('*').filter((e) => e.shadowRoot).map((e) => e.shadowRoot.innerHTML.length),
    inputs: q('input').map((i) => ({ name: i.name || null, type: i.type, valueLength: (i.value || '').length })),
    shadowRoots: q('*').filter((e) => e.shadowRoot).map((e) => e.tagName.toLowerCase()),
    bodyChildTags: Array.from(document.body.children).map((e) => e.tagName.toLowerCase()),
    docLength: document.documentElement.outerHTML.length,
  };
})()`;

const consoleLines = [];
const requests = [];
const result = { engine, pageUrl, sitekey: SITEKEY, render: RENDER, settleMs: SETTLE };

try {
    // The engine needs a moment before its CDP endpoint answers.
    for (let i = 0; i < 60; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) {
                result.version = await r.json();
                break;
            }
        } catch { /* not up yet */ }
        await sleep(250);
    }

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    cdp.on((msg) => {
        if (msg.method === 'Runtime.consoleAPICalled') {
            consoleLines.push(`${msg.params.type}: ${msg.params.args.map((a) => a.value ?? a.description ?? a.type).join(' ')}`);
        } else if (msg.method === 'Log.entryAdded') {
            consoleLines.push(`log.${msg.params.entry.level}: ${msg.params.entry.text}`);
        } else if (msg.method === 'Runtime.exceptionThrown') {
            // The widget's own failure path throws rather than logs, and an
            // uncaught throw shows up here and nowhere else.
            const d = msg.params.exceptionDetails ?? {};
            consoleLines.push(`exception: ${(d.exception?.description ?? d.text ?? '').slice(0, 400)}`);
        } else if (msg.method === 'Network.requestWillBeSent') {
            requests.push(`> ${msg.params.request.url.slice(0, 140)}`);
        } else if (msg.method === 'Network.loadingFailed') {
            requests.push(`! failed ${msg.params.requestId} ${msg.params.errorText}`);
        }
    });
    for (const domain of ['Runtime', 'Log', 'Network', 'Page']) {
        await cdp.send(`${domain}.enable`, undefined, sessionId).catch(() => { });
    }

    await cdp.send('Page.navigate', { url: pageUrl }, sessionId);

    // Read on a ladder rather than once: "hung at 20s" and "never started" are
    // different answers and a single sample cannot tell them apart.
    result.samples = [];
    for (const at of [1000, 3000, 6000, 12000, SETTLE].filter((ms, i, a) => ms <= SETTLE && a.indexOf(ms) === i)) {
        await sleep(at - (result.samples.at(-1)?.at ?? 0));
        try {
            result.samples.push({ at, ...(await evaluate(cdp, sessionId, READ)) });
        } catch (err) {
            result.samples.push({ at, error: String(err.message ?? err) });
        }
    }
    cdp.close();
} catch (err) {
    result.error = String(err.message ?? err);
} finally {
    proc.kill('SIGKILL');
    server.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

result.console = consoleLines.slice(-40);
result.requests = requests.slice(-40);
result.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-40);
if (exit) result.engineExit = exit;

const out = arg('--out', null);
const json = JSON.stringify(result, null, 2);
if (out) {
    const p = path.resolve(REPO, out.startsWith('tools/') ? out : path.join('tools/fingerprint', out));
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, json + '\n');
    console.log(`wrote ${path.relative(REPO, p)}`);
}
const last = result.samples?.at(-1);
console.log(json.length > 4000 && out ? JSON.stringify({ last, console: result.console.slice(-8) }, null, 2) : json);
process.exit(0);
