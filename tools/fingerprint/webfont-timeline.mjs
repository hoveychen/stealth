// When does a downloaded face actually become the face the page measures with?
//
//   node tools/fingerprint/webfont-timeline.mjs lightpanda --url https://iphey.com/
//   node tools/fingerprint/webfont-timeline.mjs chrome --url https://iphey.com/ --headed --headed-ua
//
// iphey builds its `SVG Computed Style` axis out of `getComputedTextLength()`
// on a 16px `<text>`, and takes the reading on a timer: whichever face is in
// force at that instant is the one it scores. So "the advances are right" is
// only half of it -- they have to be right BEFORE the detector looks. Measured
// on iphey, this engine's webfont became measurable ~430ms after Chrome's, and
// the detector read 15ms too early.
//
// Five stamps, all on `performance.now()` so they share the navigation's own
// origin, plus what `document.fonts` claims at each of them:
//
//   discovered  the engine has seen the `@font-face` and decided to fetch it,
//               which is the first `PerformanceResourceTiming` for the file
//               (`startTime`); this engine scans at DOMContentLoaded rather
//               than at parse time, so `dcl` sitting right on top of it is the
//               shape that says the scan, not the network, is the cost
//   sent        the same entry's `requestStart`
//   received    its `responseEnd` -- bytes are in, nothing is decoded yet
//   usable      the first instant a probe span laid out in the face stops
//               measuring as the fallback did: decompression plus building
//               the advance tables, and the only stamp with no wire in it
//   check       the first instant `document.fonts.check()` answers true
//   ready       when `document.fonts.ready` resolves
//
// `check` and `ready` are the two the page can see, and a browser is supposed
// to flip them AT `usable`. Reporting either one early is its own tell: a page
// that waits for `ready` and then measures gets the fallback's numbers.
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

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, sleep, personaScaleFlags } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: webfont-timeline.mjs <lightpanda|chrome> [--url U] [--family F] [--settle MS] [--headed] [--headed-ua]');
    process.exit(1);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const targetUrl = arg('--url', 'https://iphey.com/');
// Which family to watch. Left unset the recorder takes the first `@font-face`
// with a url out of `document.fonts`, which is what a page downloads.
const family = arg('--family', '');
const settleMs = Number(arg('--settle', 12000));
const headed = process.argv.includes('--headed');
const headedUa = process.argv.includes('--headed-ua');

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9346 : 9347);

// The recorder. Installed at document-start so it is running before the
// stylesheet that names the face has been parsed, which is the whole point --
// a stamp taken after `load` cannot tell a slow scan from a slow server.
//
// Everything here is driven by a page timer rather than by an awaited
// `Runtime.evaluate`: a `setTimeout` inside one of those never fires in this
// engine, so a probe written that way hangs instead of measuring.
const recorder = (watched) => `
(() => {
  const out = globalThis.__wft = {
    url: location.href, family: null,
    discovered: null, sent: null, received: null,
    usable: null, check: null, ready: null, dcl: null, load: null, fontUrl: null,
    fallbackWidth: null, faceWidth: null, samples: [],
  };
  const now = () => Math.round(performance.now() * 10) / 10;
  const watched = ${JSON.stringify(watched)};

  // Every face the page declares with a url, in declaration order, once the
  // set has any. Before that there is nothing to watch.
  const pick = () => {
    if (watched) return watched;
    try {
      for (const f of document.fonts) {
        // A \`local(...)\`-only face has no file, so no timeline.
        if (f.status === 'loaded' || f.status === 'loading') return f.family;
      }
      for (const f of document.fonts) return f.family;
    } catch {}
    return null;
  };

  let probe = null;
  const makeProbe = (fam) => {
    const el = document.createElement('span');
    el.textContent = 'mmmmmmmmmmHello, SVG World!';
    el.style.cssText = 'position:absolute;left:-9999px;top:0;visibility:hidden;' +
      'white-space:pre;font-size:16px;font-family:' + JSON.stringify(fam);
    (document.body || document.documentElement).appendChild(el);
    return el;
  };

  // The fallback's width, taken from a twin that never names the family: it
  // is what the probe measures until the face is in force, and taking it from
  // a twin rather than from the probe's own first sample means a face that
  // was ready before the first tick is still seen to have arrived.
  let twin = null;
  out.ticks = 0;

  const tick = () => {
    const t = now();
    out.ticks++;
    out.lastTick = t;
    if (!out.family) {
      const fam = pick();
      if (!fam) return;
      out.family = fam;
      probe = makeProbe(fam);
      twin = makeProbe('__no_such_family__, monospace');
      out.fallbackWidth = twin.getBoundingClientRect().width;
      return; // let layout happen before the first comparison
    }
    if (out.check === null) {
      try {
        out.lastCheck = document.fonts.check('16px ' + JSON.stringify(out.family));
        if (out.lastCheck) out.check = t;
        out.faceStates = [...document.fonts].map((f) => f.family + '|' + f.status).slice(0, 8);
      } catch (e) { out.checkError = String(e); }
    }
    if (out.usable === null) {
      const w = probe.getBoundingClientRect().width;
      out.samples.push([t, w]);
      if (out.samples.length > 400) out.samples.shift();
      if (w !== out.fallbackWidth && w > 0) {
        out.usable = t;
        out.faceWidth = w;
      }
    }
    if (out.discovered === null) {
      // The resource entry is the engine's own record of asking. Matching on
      // the extension rather than on the face's src keeps this working for a
      // page whose url is built at runtime.
      try {
        for (const e of performance.getEntriesByType('resource')) {
          if (!/\\.(woff2?|ttf|otf)(\\?|$)/i.test(e.name)) continue;
          out.fontUrl = e.name;
          out.discovered = Math.round(e.startTime * 10) / 10;
          out.sent = Math.round(e.requestStart * 10) / 10;
          out.received = Math.round(e.responseEnd * 10) / 10;
          break;
        }
      } catch {}
    }
  };

  document.addEventListener('DOMContentLoaded', () => { out.dcl = now(); });
  addEventListener('load', () => { out.load = now(); });
  try { document.fonts.ready.then(() => { out.ready = now(); }); } catch {}
  setInterval(tick, 10);
  tick();
})();
`;

async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'wft-ua-'));
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
let profile = null;
if (engine === 'chrome') {
    const userAgentOverride = headedUa ? await headedUserAgent() : null;
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'wft-chrome-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        ...(headed ? [] : ['--headless=new']),
        '--window-size=1920,1080',
        ...(userAgentOverride ? [`--user-agent=${userAgentOverride}`] : []),
        ...personaScaleFlags([]),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], {
        stdio: ['ignore', 'pipe', 'pipe'],
    });
}
const log = [];
proc.stdout.on('data', (d) => log.push(String(d)));
proc.stderr.on('data', (d) => log.push(String(d)));

try {
    let up = false;
    for (let i = 0; i < 150; i++) {
        try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); up = true; break; }
        catch { await sleep(200); }
    }
    if (!up) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        const { browserContextId } = await cdp.send('Target.createBrowserContext');
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    }

    // Both arms open the same domains, in the same order: Chrome silently
    // ignores `addScriptToEvaluateOnNewDocument` until `Page.enable`, and a
    // domain opened on one arm only is its own difference.
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: recorder(family) }, sessionId);
    await cdp.send('Page.navigate', { url: targetUrl }, sessionId);
    await sleep(settleMs);

    const res = await cdp.send('Runtime.evaluate', {
        expression: 'JSON.stringify(globalThis.__wft || null)',
        returnByValue: true,
    }, sessionId);
    const raw = res.result?.value;
    const t = raw ? JSON.parse(raw) : null;
    if (!t) throw new Error(`no recorder state\n${log.join('')}`);

    // The samples are for reading a stamp that never arrived: a flat run of
    // identical widths says the face never took, not that it took instantly.
    const { samples, ...stamps } = t;
    const span = (a, b) => (a === null || a === undefined || b === null || b === undefined ? null : Math.round((b - a) * 10) / 10);
    console.log(JSON.stringify({
        engine,
        ...stamps,
        // Where the time goes, in the order it is spent.
        segments: {
            'nav->discovered': span(0, t.discovered),
            'discovered->sent': span(t.discovered, t.sent),
            'sent->received': span(t.received === null ? null : t.sent, t.received),
            'received->usable': span(t.received, t.usable),
        },
        // What a page watching `document.fonts` is told, against when the
        // measurement actually changes. Negative means the engine promised
        // early, which is the failure a detector reads.
        promisedEarlyBy: {
            check: span(t.check, t.usable),
            ready: span(t.ready, t.usable),
        },
        sampleCount: samples?.length ?? 0,
    }, null, 2));
} finally {
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}
