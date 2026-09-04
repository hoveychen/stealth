// Reports exactly which features CreepJS renders as `.unsupport` for an engine.
//
//   node tools/fingerprint/dump-creep-features.mjs lightpanda
//   node tools/fingerprint/dump-creep-features.mjs chrome --headed
//   node tools/fingerprint/dump-creep-features.mjs both        # writes the diff report
//
// CreepJS decides which browser version it is looking at from three key lists
// and prints every key it expected but did not find. Those printed keys are the
// `.unsupport` spans, and their count is what pushes its verdict from
// "Features: 113-115+" (real Chrome) down to "93+" (this engine before the work).
//
// Two things produce an `.unsupport` span, and the report separates them:
//
//   diffRemoved       a key present in the Chrome 115 baseline hard-coded in
//                     creep.js but absent from this engine. This is the bulk of
//                     it and the actionable part.
//   modalUnsupported  an entry in creep.js's per-version feature map that the
//                     engine does not have. Some of these are unreachable by
//                     design: entries starting with `!` mean "removed in this
//                     version", so they render as unsupported in real Chrome too.
//
// Both baselines are read out of the live creep.js rather than restated here, so
// the report cannot drift from what the site actually tests. Chrome scores 128
// spans against its own baseline; that is the floor, not zero.
//
// The three collectors below are transcribed verbatim from creep.js
// (getWindowFeatures, getJSCoreFeatures, and getCSS's computeStyle) so the
// numbers here are the numbers the site computes, not an approximation of them.
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');
const CREEP_JS = 'https://abrahamjuliot.github.io/creepjs/creep.js';
const resultsDir = path.join(here, 'results');

// A secure origin is required: several APIs are gated on it and would otherwise
// read as missing for reasons that have nothing to do with the engine. Chrome
// treats localhost as secure, so a plain local server is enough and no tunnel
// is needed.
const SITE = process.env.SITE || 'http://localhost:8731/';

// Transcribed from creep.js. Returns the three key lists the site compares
// against its baselines.
const COLLECTOR = `(() => {
  const out = { location: location.href, userAgent: navigator.userAgent };
  try {
    out.windowKeys = Object.getOwnPropertyNames(window).filter((key) => !/_|\\d{3,}/.test(key));
  } catch (e) { out.windowErr = String(e); }
  try {
    const globalObjects = ['Object','Function','Boolean','Symbol','Error','Number','BigInt','Math','Date','String','RegExp','Array','Map','Set','WeakMap','WeakSet','Atomics','JSON','Promise','Reflect','Proxy','Intl','WebAssembly','Document','Element'];
    const ignore = ['name','length','constructor','prototype','arguments','caller'];
    out.jsKeys = globalObjects.reduce((acc, name) => {
      const own = Object.keys(Object.getOwnPropertyDescriptors(window[name] || {}));
      const proto = Object.keys(Object.getOwnPropertyDescriptors((window[name] || {}).prototype || {}));
      const uniques = [...new Set([...own, ...proto].filter((k) => !ignore.includes(k)))];
      return [...acc, ...uniques.map((k) => name + '.' + k)];
    }, []);
  } catch (e) { out.jsErr = String(e); }
  try {
    const decl = getComputedStyle(document.body);
    const proto = Object.getPrototypeOf(decl);
    const prototypeProperties = Object.getOwnPropertyNames(proto);
    const ownEnumerable = [];
    const cssVar = /^--.*$/;
    Object.keys(decl).forEach((key) => {
      const numericKey = !isNaN(+key);
      const value = decl[key];
      if (numericKey && !cssVar.test(value)) return ownEnumerable.push(value);
      if (!numericKey && !cssVar.test(key)) return ownEnumerable.push(key);
    });
    const inChain = {};
    const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
    const uncap = (s) => s.charAt(0).toLowerCase() + s.slice(1);
    const caps = /[A-Z]/g;
    ownEnumerable.forEach((raw) => {
      if (inChain[raw]) return;
      const isNamed = raw.indexOf('-') > -1;
      const isAlias = caps.test(raw);
      const first = raw.charAt(0);
      let key = isNamed && first === '-' ? raw.slice(1) : isAlias && first === first.toUpperCase() ? uncap(raw) : raw;
      if (isNamed) {
        const alias = key.split('-').map((w, i) => (i === 0 ? w : cap(w))).join('');
        if (alias in decl) inChain[alias] = true;
        else if (cap(alias) in decl) inChain[cap(alias)] = true;
      } else if (isAlias) {
        const named = key.replace(caps, (c) => '-' + c.toLowerCase());
        if (named in decl) inChain[named] = true;
        else if (('-' + named) in decl) inChain['-' + named] = true;
      }
    });
    out.cssKeys = [...new Set([...prototypeProperties, ...ownEnumerable, ...Object.keys(inChain)])];
    out.cssInterfaceName = ('' + proto).match(/\\[object (.+)\\]/)[1];
  } catch (e) { out.cssErr = String(e); }
  return JSON.stringify(out);
})()`;

// Pull creep.js and lift the two baselines out of it by evaluating just the two
// functions that hold them, so a change on the site shows up here as a changed
// report rather than as silently stale expectations.
async function loadBaselines() {
    const res = await fetch(CREEP_JS);
    if (!res.ok) throw new Error(`GET ${CREEP_JS} -> ${res.status}`);
    const src = await res.text();
    const lift = (startRe, endRe, name) => {
        const lines = src.split('\n');
        const start = lines.findIndex((l) => startRe.test(l));
        if (start < 0) throw new Error(`${name}: start not found in creep.js`);
        let end = -1;
        for (let i = start + 1; i < lines.length; i++) {
            if (endRe.test(lines[i])) { end = i; break; }
        }
        if (end < 0) throw new Error(`${name}: end not found in creep.js`);
        const body = lines.slice(start, end + 1).join('\n').replace(/^\s*const \w+ =/, 'globalThis.__lifted =');
        // eslint-disable-next-line no-eval
        eval(body);
        return globalThis.__lifted;
    };
    const stable = lift(/^\s*const getStableFeatures = \(\) => \(\{/, /^\s*\}\);\s*$/, 'getStableFeatures')();
    const maps = lift(/^\s*const getEngineMaps = \(browser\) => \{/, /^\s{4}\};\s*$/, 'getEngineMaps')('Chrome');
    const chrome = stable.Chrome;
    return {
        baselineVersion: chrome.version,
        windowKeys: chrome.windowKeys.split(', '),
        cssKeys: chrome.cssKeys.split(', '),
        jsKeys: chrome.jsKeys.split(', '),
        maps,
    };
}

async function collect(engine) {
    const port = Number(process.env.LP_PORT ?? (engine === 'chrome' ? 9471 : 9472));
    let proc;
    if (engine === 'chrome') {
        const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'creepfeat-'));
        proc = spawn(CHROME, [
            ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
            `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`,
            '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
        ], { stdio: ['ignore', 'pipe', 'pipe'] });
    } else {
        proc = spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] });
    }
    // The engine is single threaded: a full 64KB pipe would block it forever.
    const logFile = createWriteStream(path.join(os.tmpdir(), `creepfeat-${engine}.log`));
    proc.stdout.pipe(logFile);
    proc.stderr.pipe(logFile);
    await sleep(engine === 'chrome' ? 1600 : 2500);
    try {
        const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
        const { sessionId } = await newPage(cdp);
        await cdp.send('Page.navigate', { url: SITE }, sessionId);
        await sleep(Number(process.env.SETTLE ?? 3000));
        const raw = await evaluate(cdp, sessionId, COLLECTOR);
        cdp.close();
        const out = JSON.parse(raw);
        // Chrome fails navigation silently onto chrome-error://chromewebdata/.
        if (!out.location.startsWith(SITE.replace(/\/$/, ''))) {
            throw new Error(`navigation landed on ${out.location}, not ${SITE}`);
        }
        return out;
    } finally {
        proc.kill('SIGKILL');
    }
}

// creep.js's own getListDiff.
function getListDiff({ oldList, newList, removeCamelCase = false }) {
    const oldSet = new Set(oldList);
    const newSet = new Set(newList);
    newList.forEach((x) => oldSet.delete(x));
    oldList.forEach((x) => newSet.delete(x));
    const camelCase = /[a-z][A-Z]/;
    return {
        removed: !removeCamelCase ? [...oldSet] : [...oldSet].filter((k) => !camelCase.test(k)),
        added: !removeCamelCase ? [...newSet] : [...newSet].filter((k) => !camelCase.test(k)),
    };
}

// creep.js's getFeatures, reduced to the question "which map entries stay unlit".
function modalUnsupported(mapObj, allKeys) {
    const have = new Set(allKeys);
    const lit = new Set();
    const entries = Object.values(mapObj).flat();
    for (const prop of entries) {
        if (prop.charAt(0) === '!') {
            if (!have.has(prop.slice(1))) lit.add(prop);
        } else if (have.has(prop)) lit.add(prop);
    }
    return entries.filter((p) => !lit.has(p));
}

function analyse(baselines, surface) {
    const report = {};
    const blocks = [
        ['window', baselines.windowKeys, surface.windowKeys ?? [], false, baselines.maps.win],
        ['js', baselines.jsKeys, surface.jsKeys ?? [], false, baselines.maps.js],
        ['css', baselines.cssKeys, surface.cssKeys ?? [], true, baselines.maps.css],
    ];
    for (const [id, oldList, newList, removeCamelCase, mapObj] of blocks) {
        const diff = getListDiff({ oldList, newList, removeCamelCase });
        const modal = modalUnsupported(mapObj, newList);
        report[id] = {
            chromeBaselineKeys: oldList.length,
            engineKeys: newList.length,
            unsupportSpans: diff.removed.length + modal.length,
            diffRemoved: diff.removed,
            diffAdded: diff.added,
            modalUnsupported: modal,
        };
    }
    // The js block is `Interface.member`; grouping by interface is how the work
    // gets split, so carry the grouping rather than re-deriving it downstream.
    const jsByInterface = {};
    for (const key of report.js.diffRemoved) {
        const iface = key.split('.')[0];
        (jsByInterface[iface] ??= []).push(key);
    }
    return {
        location: surface.location,
        userAgent: surface.userAgent,
        cssInterfaceName: surface.cssInterfaceName,
        totalUnsupportSpans: Object.values(report).reduce((a, r) => a + r.unsupportSpans, 0),
        report,
        jsByInterface,
    };
}

function summarise(label, analysis) {
    console.log(`\n== ${label} ==`);
    console.log(`   ${analysis.userAgent}`);
    console.log(`   getComputedStyle prototype: ${analysis.cssInterfaceName}`);
    for (const [id, r] of Object.entries(analysis.report)) {
        console.log(
            `   ${id.padEnd(7)} baseline=${String(r.chromeBaselineKeys).padStart(5)}` +
            ` engine=${String(r.engineKeys).padStart(5)}` +
            ` missing=${String(r.diffRemoved.length).padStart(4)}` +
            ` extra=${String(r.diffAdded.length).padStart(4)}` +
            ` mapUnlit=${String(r.modalUnsupported.length).padStart(3)}` +
            ` -> ${r.unsupportSpans} spans`,
        );
    }
    console.log(`   TOTAL .unsupport spans: ${analysis.totalUnsupportSpans}`);
    const byIface = Object.entries(analysis.jsByInterface).sort((a, b) => b[1].length - a[1].length);
    if (byIface.length) {
        console.log(`   js missing by interface: ${byIface.map(([k, v]) => `${k}=${v.length}`).join(' ')}`);
    }
}

const which = process.argv[2] ?? 'lightpanda';
const baselines = await loadBaselines();
console.log(`creep.js baseline: Chrome ${baselines.baselineVersion}` +
    ` (window ${baselines.windowKeys.length}, css ${baselines.cssKeys.length}, js ${baselines.jsKeys.length} keys)`);

await fs.mkdir(resultsDir, { recursive: true });
const engines = which === 'both' ? ['chrome', 'lightpanda'] : [which];
const out = { baselineVersion: baselines.baselineVersion, site: SITE, engines: {} };
for (const engine of engines) {
    const analysis = analyse(baselines, await collect(engine));
    summarise(engine, analysis);
    out.engines[engine] = analysis;
}
const outPath = path.join(resultsDir, 'creep-features-missing.json');
await fs.writeFile(outPath, JSON.stringify(out, null, 1));
console.log(`\nwrote ${path.relative(repo, outPath)}`);
