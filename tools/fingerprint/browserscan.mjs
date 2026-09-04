// browserscan.net, read two ways in one pass.
//
// `detector-sweep.mjs` scores this site by node count, and on browserscan that
// number is mostly advertising: the engine blocks none of it and renders none
// of it, so the sweep's headline gap moves with whatever the ad server felt
// like serving. This reads the page the way the site presents itself instead --
// the trust score, the warning list that explains the deductions, and every
// label/value row -- and keeps the structural dump alongside so the two
// accounts can be checked against each other.
//
// Both engines go through it. Give CDP_ENDPOINT to drive a Chrome this script
// did not spawn (see linux-chrome.mjs); with no endpoint it spawns lightpanda.
//
//   node tools/fingerprint/browserscan.mjs > results/browserscan-lightpanda.json
//   node tools/fingerprint/browserscan-linux.mjs > results/browserscan-chrome.json
//   node tools/fingerprint/browserscan.mjs --diff a.json b.json
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { Cdp, newPage, sleep, PERSONA_DEVICE_SCALE_FACTOR } from './cdp.mjs';

const PORT = 9487;
const LIGHTPANDA = 'zig-out/bin/lightpanda';
// The hardware card arrives well after load; under 20s it is still blank, and
// a blank card reads as a difference that is not there. How long "after load"
// is depends on the engine: a bigger font table makes the site's own enumeration
// loop slower, and at 25s the card came back empty with 45 loading skeletons
// still on the page -- which reads as a hardware card that broke rather than one
// that had not arrived. BROWSERSCAN_SETTLE_MS raises it; `skeletons` in the
// output is how you know whether you waited long enough.
const SETTLE_MS = Number(process.env.BROWSERSCAN_SETTLE_MS ?? 25000);

// The class names are content hashes of browserscan's CSS modules, so they are
// stable across loads and identical for both engines; the ids are randomised
// per load and deliberately unused. `_1deohst` is the class the site puts on a
// value it considers anomalous -- the machine-readable form of the deduction.
const PROBE = `(() => {
  const txt = (el) => (el ? (el.textContent || '').replace(/\\s+/g, ' ').trim() : null);
  const main = document.querySelector('main');
  if (!main) return JSON.stringify({ error: 'no main element' });

  const scoreBox = [...main.querySelectorAll('._5tuium span')].pop();

  const warnings = [...main.querySelectorAll('ul._16rztjr > li')].map(txt);

  const rows = [...main.querySelectorAll('._11xj7yu')].map((row) => {
    const valBox = row.querySelector('._1pu5vjm');
    const first = valBox && valBox.firstElementChild;
    const cls = first && typeof first.className === 'string' ? first.className : '';
    return {
      label: txt(row.querySelector('._to28ap')),
      val: (txt(valBox) || '').slice(0, 90),
      flagged: cls.includes('_1deohst'),
    };
  });

  // Structural dump keyed by the ancestor chain of tag+class, so the two
  // engines' trees line up path by path and a missing card shows as one row.
  const sig = (el) => {
    const cls = (typeof el.className === 'string' && el.className.trim())
      ? '.' + el.className.trim().split(/\\s+/).sort().join('.')
      : '';
    return el.tagName + cls;
  };
  const blocks = [];
  const walk = (el, path, depth) => {
    const seen = new Map();
    for (const child of el.children) {
      const s = sig(child);
      const n = seen.get(s) ?? 0;
      seen.set(s, n + 1);
      const p = path + '/' + s + (n ? '[' + n + ']' : '');
      blocks.push({ path: p, count: child.querySelectorAll('*').length });
      if (depth < 9) walk(child, p, depth + 1);
    }
  };
  walk(document.body, '', 0);

  return JSON.stringify({
    score: txt(scoreBox),
    warnings,
    rows,
    blocks,
    mainTotal: main.querySelectorAll('*').length,
    docTotal: document.querySelectorAll('*').length,
    // A placeholder left behind is a card that never resolved; both engines
    // read 0 since the RSA work landed, and a regression here is worth knowing.
    skeletons: document.querySelectorAll('[class*=skeleton]').length,
  });
})()`;

if (process.argv[2] === '--diff') {
  diff(load(process.argv[3]), load(process.argv[4]));
  process.exit(0);
}

const endpoint = process.env.CDP_ENDPOINT ?? null;
let proc = null;
if (!endpoint) {
  proc = spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  proc.stdout.resume();
  proc.stderr.resume();
  for (let i = 0; i < 300; i++) {
    try {
      await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
      break;
    } catch {
      await sleep(200);
    }
  }
}

const cdp = await Cdp.connect(endpoint ?? `http://127.0.0.1:${PORT}`);
let sessionId;
if (endpoint) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
} else {
  ({ sessionId } = await newPage(cdp));
}

const problems = [];
await cdp.send('Runtime.enable', {}, sessionId).catch(() => {});
await cdp.send('Log.enable', {}, sessionId).catch(() => {});
cdp.on((m) => {
  if (m.method === 'Runtime.exceptionThrown') {
    const d = m.params?.exceptionDetails;
    problems.push('EX: ' + String(d?.exception?.description ?? d?.text).slice(0, 240));
  } else if (m.method === 'Log.entryAdded' && m.params?.entry?.level === 'error') {
    problems.push('LOG: ' + String(m.params.entry.text).slice(0, 240));
  }
});

// Both engines at one viewport: the page is responsive, and a different
// breakpoint renders a different number of nodes for no fingerprint reason.
await cdp.send('Emulation.setDeviceMetricsOverride', {
  width: 1920, height: 1080, deviceScaleFactor: PERSONA_DEVICE_SCALE_FACTOR, mobile: false,
}, sessionId).catch(() => {});
await cdp.send('Page.enable', {}, sessionId).catch(() => {});
await cdp.send('Page.navigate', { url: 'https://www.browserscan.net/' }, sessionId);
await sleep(SETTLE_MS);

const res = await cdp.send('Runtime.evaluate', { expression: PROBE, returnByValue: true }, sessionId);
console.log(JSON.stringify({ problems, ...JSON.parse(res.result.value) }, null, 1));
cdp.close();
proc?.kill('SIGKILL');
process.exit(0);

function load(p) {
  if (!p) {
    console.error('usage: browserscan.mjs --diff <a.json> <b.json>');
    process.exit(2);
  }
  return JSON.parse(readFileSync(p, 'utf8'));
}

function diff(a, b) {
  console.log(`score       a=${a.score}  b=${b.score}`);
  console.log(`main nodes  a=${a.mainTotal}  b=${b.mainTotal}  (delta ${a.mainTotal - b.mainTotal})`);
  console.log(`doc nodes   a=${a.docTotal}  b=${b.docTotal}  (delta ${a.docTotal - b.docTotal})`);
  console.log(`\nwarnings a (${a.warnings.length}):`);
  for (const w of a.warnings) console.log('  - ' + w);
  console.log(`warnings b (${b.warnings.length}):`);
  for (const w of b.warnings) console.log('  - ' + w);

  // Rows keyed by label. A blank value on one side only is worth more attention
  // than a differing one: it means the card never computed.
  const key = (rows) => {
    const m = new Map();
    for (const r of rows) {
      const k = r.label || '(unlabelled)';
      if (!m.has(k)) m.set(k, []);
      m.get(k).push(r);
    }
    return m;
  };
  const A = key(a.rows), B = key(b.rows);
  console.log('\nrows that differ:');
  for (const k of new Set([...A.keys(), ...B.keys()])) {
    const xs = A.get(k) ?? [], ys = B.get(k) ?? [];
    for (let i = 0; i < Math.max(xs.length, ys.length); i++) {
      const x = xs[i], y = ys[i];
      const xv = x ? x.val : '(row absent)', yv = y ? y.val : '(row absent)';
      const xc = x ? x.flagged : false, yc = y ? y.flagged : false;
      if (xv === yv && xc === yc) continue;
      console.log(`  [${k}]`);
      console.log(`      a: "${xv}"${xc ? '  FLAGGED' : ''}`);
      console.log(`      b: "${yv}"${yc ? '  FLAGGED' : ''}`);
    }
  }

  // Structural blocks, so the advertising can be told apart from the content.
  const bm = new Map(b.blocks.map((n) => [n.path, n]));
  console.log('\nblocks in b that a does not render:');
  const seen = new Set(b.blocks.filter((n) => !a.blocks.some((m) => m.path === n.path)).map((n) => n.path));
  let sum = 0;
  for (const n of b.blocks.filter((n) => seen.has(n.path))) {
    const parent = n.path.slice(0, n.path.lastIndexOf('/'));
    if (seen.has(parent)) continue; // report the root of a missing subtree once
    sum += n.count + 1;
    console.log(`  ${String(n.count + 1).padStart(4)} nodes  ${n.path}`);
  }
  console.log(`  subtotal ${sum} nodes`);
  void bm;
}
