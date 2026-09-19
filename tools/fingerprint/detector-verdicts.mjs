// What each detector CONCLUDES, and the axes it read to get there.
//
//   node tools/fingerprint/detector-verdicts.mjs <lightpanda|chrome>
//        [--out results/x.json] [--only iphey] [--settle 15000] [--port 9370]
//        [--headed] [--headed-ua] [--proxy socks5h://host:port]
//
// detector-sweep.mjs answers "did the page finish": a node count, a text
// length, and `verdictWords`, which is only how many judgement-shaped WORDS
// appear in the page text. That is not a verdict, and it throws away the thing
// these pages are actually for -- they say what they think, and they name the
// axes they read. Measured on this engine, iphey's own report is:
//
//   hero status   Unreliable            (class hero-status--bad)
//   MX Score      70
//   browser       Detected an inconsistent browser fingerprint
//   + about thirty labelled axes: User Agent, OS, Languages, Timezone,
//     Client Rects, Audio, WebGL, GPU, Architecture, Device Memory, ...
//
// and rebrowser publishes a per-test table (dummyFn, sourceUrlLeak,
// mainWorldExecution, runtimeEnableLeak, exposeFunctionLeak,
// navigatorWebdriver, viewport, pwInitScripts, bypassCsp, useragent) with a
// status per row. Both of those are graded signals -- partial credit -- where
// the station sweeps only ever give a pass or a refusal.
//
// The extractors are per detector and written from a DOM recon rather than
// guessed (scratch/dvad/recon-structure.mjs). Every detector also gets the
// generic pass, so a page whose markup changes still yields its sentences
// instead of silently yielding nothing.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
    Cdp, newPage, goto, evaluate, sleep,
    personaScaleFlags, PERSONA_DEVICE_SCALE_FACTOR, pinPersonaMedia,
} from './cdp.mjs';
import { DETECTORS } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const arg = (k, d) => { const i = process.argv.indexOf(k); return i === -1 ? d : process.argv[i + 1]; };

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: detector-verdicts.mjs <lightpanda|chrome> [--out results/x.json] [--only iphey] [--settle 15000] [--port 9370] [--headed] [--headed-ua] [--proxy socks5h://host:port]');
    process.exit(2);
}
const outPath = path.resolve(repo, arg('--out', `tools/fingerprint/results/verdicts-${engine}.json`));
const only = arg('--only', null);
const settleOverride = arg('--settle', null) && Number(arg('--settle'));
const PORT = Number(arg('--port', engine === 'chrome' ? 9371 : 9370));
const headed = process.argv.includes('--headed');
const headedUa = process.argv.includes('--headed-ua');
const proxy = arg('--proxy', null);
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const detectors = DETECTORS.filter((d) => !only || d.name.includes(only));
if (detectors.length === 0) {
    console.error(`--only ${only} matched no detector`);
    process.exit(2);
}

// ---------------------------------------------------------------------------
// Page-side extraction. One expression, because it has to survive being run
// through Runtime.evaluate on both engines.
//
// `axes` is a flat name -> value map and NOT a list: the whole point is to diff
// two arms by axis name, and a list would make that positional.
const EXTRACT = `(() => {
  const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim();
  const out = { verdicts: [], score: null, axes: {}, tests: {}, extractor: [] };

  const setAxis = (k, v) => {
    const key = clean(k), val = clean(v);
    if (!key || !val || key.length > 80 || val.length > 300) return;
    out.axes[key] = val;
  };

  // --- iphey: a status class, a score, and .detail-entry rows -------------
  const hero = document.querySelector('[class*="hero-status--" i]');
  if (hero) {
    out.verdicts.push({ source: 'iphey.hero-status', text: clean(hero.textContent),
                        cls: (hero.className || '').toString() });
    out.extractor.push('iphey.hero');
  }
  const score = document.querySelector('.score-value');
  if (score && /^[0-9.]+$/.test(clean(score.textContent))) {
    out.score = Number(clean(score.textContent));
    out.extractor.push('iphey.score');
  }
  const entries = document.querySelectorAll('.detail-entry');
  if (entries.length) {
    for (const e of entries) {
      const v = e.querySelector('.detail-value');
      if (!v) continue;
      // The label is whatever comes before the value in the row.
      const label = v.previousElementSibling ?? e.firstElementChild;
      if (label && label !== v) setAxis(label.textContent, v.textContent);
    }
    out.extractor.push('iphey.detail-entry');
  }

  // --- rebrowser: one row per named test, with a status glyph ------------
  for (const tr of document.querySelectorAll('tr')) {
    const cells = Array.from(tr.querySelectorAll('td, th')).map((c) => clean(c.textContent));
    if (cells.length < 2) continue;
    // "🟢 navigatorWebdriver" -> status "🟢", test "navigatorWebdriver". The
    // glyph is the verdict; the second cell is a duration, which is not
    // comparable across arms and is kept only as context.
    const m = cells[0].match(/^(\\S+)\\s+([A-Za-z][A-Za-z0-9_]+)$/u);
    // The status has to be a glyph, not a word: without this the header row
    // ("Test name") comes through as a test called \`name\` with status
    // \`Test\`, which then differs between arms for no reason at all.
    if (!m || /[A-Za-z0-9]/.test(m[1])) continue;
    out.tests[m[2]] = { status: m[1], detail: cells.slice(1).join(' | ').slice(0, 80) };
    out.extractor.push('rebrowser.table');
  }

  // --- generic tables: sannysoft, browserleaks and amiunique all publish
  // their readings as two-cell rows, and sannysoft's rows ARE its per-test
  // results ("WebDriver (New) / missing (passed)"). Taken as axes rather than
  // as tests because the status is prose here, not a glyph, so the arms are
  // compared by value and not by a symbol this would have to interpret.
  for (const tr of document.querySelectorAll('tr')) {
    const cells = Array.from(tr.querySelectorAll('td, th')).map((c) => clean(c.textContent));
    if (cells.length !== 2) continue;
    if (cells[0].length > 60) continue;
    setAxis(cells[0], cells[1]);
    out.extractor.push('generic.table');
  }
  for (const dt of document.querySelectorAll('dt')) {
    const dd = dt.nextElementSibling;
    if (dd && dd.tagName === 'DD') { setAxis(dt.textContent, dd.textContent); out.extractor.push('generic.dl'); }
  }

  // --- generic: the smallest elements whose whole text reads as a judgement
  const VERDICT = /\\b(bot|automat|headless|inconsisten|trustworth|unreliable|reliable|suspicious|genuine|human|spoof|masked)\\b/i;
  const seen = new Set();
  for (const el of document.querySelectorAll('body *')) {
    if (el.children.length > 1) continue;
    const t = clean(el.textContent);
    if (t.length < 4 || t.length > 90 || seen.has(t) || !VERDICT.test(t)) continue;
    seen.add(t);
    out.verdicts.push({ source: 'generic', text: t, cls: (el.className || '').toString().slice(0, 40) });
  }

  out.title = document.title;
  out.textLength = (document.body.innerText || '').length;
  out.axisCount = Object.keys(out.axes).length;
  out.testCount = Object.keys(out.tests).length;
  out.extractor = Array.from(new Set(out.extractor));
  return out;
})()`;

// ---------------------------------------------------------------------------
let proc, profile;
if (engine === 'chrome') {
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'dv-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run', '--no-default-browser-check',
        ...personaScaleFlags(),
        '--window-size=1920,1080',
        ...(headed ? [] : ['--headless=new']),
        ...(proxy ? [`--proxy-server=${proxy}`] : []),
        // Zero-point controls: knock one capability out of the reference arm and
        // watch whether iphey's score follows. Repeatable: --chrome-arg X --chrome-arg Y
        ...process.argv.reduce((acc, a, i) => (a === '--chrome-arg' ? [...acc, process.argv[i + 1]] : acc), []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    // LP_BIN so a run can be pinned to one build while a peer session rebuilds
    // zig-out underneath it.
    proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
        ...(proxy ? ['--http-proxy', proxy] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
}
const engineLog = [];
const keep = (d) => { engineLog.push(String(d)); if (engineLog.length > 4000) engineLog.splice(0, 2000); };
proc.stdout.on('data', keep);
proc.stderr.on('data', keep);

const snapshot = { engine, headed, headedUa, only, settleOverride, version: null, detectors: {} };
try {
    for (let i = 0; i < 120; i++) {
        try { snapshot.version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(200); }
    }
    if (!snapshot.version) throw new Error(`${engine} CDP never came up`);

    for (const d of detectors) {
        // A page per detector, and on Chrome a fresh context too: these reports
        // are cumulative in places, and a second detector inheriting the first
        // one's storage is a different reading.
        const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
        const { sessionId } = await newPage(cdp);
        const row = { url: d.url };
        const started = Date.now();
        try {
            if (headedUa) {
                if (engine !== 'chrome') throw new Error('--headed-ua only makes sense with chrome');
                await cdp.send('Emulation.setUserAgentOverride', {
                    userAgent: (await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json())['User-Agent']
                        .replace('HeadlessChrome', 'Chrome'),
                }, sessionId);
            }
            await cdp.send('Emulation.setDeviceMetricsOverride', {
                width: 1920, height: 1080,
                deviceScaleFactor: engine === 'chrome' ? PERSONA_DEVICE_SCALE_FACTOR : 1,
                mobile: false,
            }, sessionId);
            await pinPersonaMedia(cdp, sessionId);
            await goto(cdp, sessionId, d.url, { settleMs: settleOverride ?? d.settleMs });
            // The domain the detectors are read through. It is detectable, and
            // that is a known cost paid on both arms equally -- rebrowser even
            // has a test for it (runtimeEnableLeak), which is itself a reading.
            await cdp.send('Runtime.enable', {}, sessionId);
            Object.assign(row, await evaluate(cdp, sessionId, EXTRACT));
        } catch (e) {
            row.error = String(e.message ?? e).slice(0, 160);
        }
        row.ms = Date.now() - started;
        snapshot.detectors[d.name] = row;
        cdp.close();
        console.log(
            `${String(row.ms).padStart(6)}ms ${d.name.padEnd(17)} ` +
            (row.error ? `ERR ${row.error}` : `axes=${String(row.axisCount).padStart(3)} tests=${String(row.testCount).padStart(2)} score=${row.score ?? '-'} ` +
                `verdict="${(row.verdicts?.[0]?.text ?? '').slice(0, 48)}"`),
        );
    }
} finally {
    proc?.kill('SIGKILL');
    snapshot.engineLogTail = engineLog.join('').split('\n').filter(Boolean).slice(-40);
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`wrote ${path.relative(repo, outPath)}`);
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    process.exit(0);
}
