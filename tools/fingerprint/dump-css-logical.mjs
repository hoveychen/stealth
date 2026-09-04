// Regenerates src/browser/webapi/css/chrome_logical.zig from the real Chrome on
// this machine: which pairs of longhands are the same underlying property under
// two spellings, one logical (`margin-block-start`) and one physical
// (`margin-top`).
//
//   node tools/fingerprint/dump-css-logical.mjs [--headed]
//
// The gap this closes was measured with tools/fingerprint/scratch/
// expr-computed-shorthands.js after the shorthand join landed: 35 of the 62
// remaining disagreements are logical names on an element whose declaration was
// physical. `margin:1px 2px 3px 4px` fills `margin-top`…`margin-left` and this
// engine's `margin-block-start` never hears about it, so `marginBlock` reads the
// initial `16px` where Chrome reads `1px 3px`.
//
// This is measured in the default writing mode only -- horizontal-tb, ltr --
// which is the one this engine lays out, and the same assumption `width` /
// `inline-size` already share in CSSStyleDeclaration. In another writing mode
// the pairing rotates and the table would be wrong; the generated header says
// so.
//
// The test is mutual co-movement, which no coincidence produces:
//
//   set A to a value that moves A off its initial
//   B is a candidate if B moved to that same value
//   set B to a *different* value that moves B
//   A and B are the same property only if A moved to that one too
//
// A one-way match would be a side effect: a property that resizes the box and
// drags a resolved value with it. Requiring the swap in both directions leaves
// only two names for one thing. A longhand that pairs with nothing is not in
// the table, and one that appears to pair with more than one is dropped and
// listed in the header rather than guessed at.
//
// One thing the mutual test does *not* rule out is a shorthand over a single
// longhand: `text-decoration` co-moves with `text-decoration-thickness` in both
// directions and is in Chrome's indexed list, so it came out as a pair on the
// first run. Shorthands are excluded, and which names those are is measured too
// -- set the name on an empty declaration and count the entries.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9479);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_logical.zig');
const headed = process.argv.includes('--headed');

const PAGE = 'data:text/html,' + encodeURIComponent(
    '<!doctype html><title>logical</title><meta name="color-scheme" content="light">' +
    '<body><div id=probe></div>');

// Two values per shape, because the second pass has to move the property to
// somewhere the first pass did not put it. Order matters only in that a value
// most properties accept should come early: the first one that moves the
// property off its initial wins.
const CANDIDATES = [
    ['17px', '23px'],
    ['rgb(1, 2, 3)', 'rgb(4, 5, 6)'],
    ['dotted', 'double'],
    ['auto', 'none'],
    ['scroll', 'hidden'],
    ['2', '3'],
    ['start', 'end'],
    ['50%', '25%'],
];

const PROBE = `(() => {
  const probe = document.getElementById('probe');
  const CANDIDATES = ${JSON.stringify(CANDIDATES)};

  // A border width is pinned to 0 while its style is \`none\`, so the widths
  // cannot move at all without this. It goes on for the whole run.
  probe.setAttribute('style', 'border-style:solid;border-block-style:solid;border-inline-style:solid');
  const BASE = probe.getAttribute('style');

  const cs = getComputedStyle(probe);
  const listed = [];
  for (let i = 0; i < cs.length; i++) listed.push(cs[i]);

  // Chrome's indexed list is not purely longhands -- \`text-decoration\` is in
  // it -- and a shorthand co-moves with its own longhand in both directions,
  // which would pass the mutual test and land in the table as a pair. Whether a
  // name is a shorthand is measured, not read off its spelling: set it on an
  // empty declaration and see whether more than one entry comes back.
  const probeDecl = document.createElement('div').style;
  const shorthands = new Set();
  for (const n of listed) {
    for (const pair of CANDIDATES) {
      probeDecl.cssText = '';
      probeDecl.setProperty(n, pair[0]);
      if (probeDecl.length > 1) shorthands.add(n);
      if (probeDecl.length > 0) break;
    }
  }
  probeDecl.cssText = '';
  const names = listed.filter((n) => !shorthands.has(n));

  const reset = () => probe.setAttribute('style', BASE);
  const snapshot = () => {
    const out = {};
    for (const n of names) out[n] = cs.getPropertyValue(n);
    return out;
  };
  reset();
  const initial = snapshot();

  // What moves when a name is set: the value it took, and every other longhand
  // that took the same value.
  const moves = (name, which) => {
    for (const pair of CANDIDATES) {
      reset();
      probe.style.setProperty(name, pair[which]);
      const got = cs.getPropertyValue(name);
      if (got === initial[name] || got === '') continue;
      const withIt = [];
      for (const other of names) {
        if (other === name) continue;
        if (cs.getPropertyValue(other) === got && initial[other] !== got) withIt.push(other);
      }
      reset();
      return { value: got, withIt };
    }
    reset();
    return null;
  };

  const pairs = [];
  const ambiguous = [];
  const unmoved = [];
  for (const name of names) {
    const first = moves(name, 0);
    if (!first) { unmoved.push(name); continue; }
    // Mutual: each candidate has to drag the first name along when it is the
    // one set, and to a value the first pass did not use.
    const mutual = first.withIt.filter((other) => {
      const back = moves(other, 1);
      return back && back.value !== first.value && back.withIt.includes(name);
    });
    if (mutual.length === 1) pairs.push([name, mutual[0]]);
    else if (mutual.length > 1) ambiguous.push(name + ' -> ' + mutual.join('/'));
  }
  probe.removeAttribute('style');

  return JSON.stringify({
    ua: navigator.userAgent,
    total: names.length,
    pairs, ambiguous, unmovedCount: unmoved.length,
    shorthandsSkipped: [...shorthands],
  });
})()`;

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'lp-logical-'));
const args = [
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--force-color-profile=srgb',
];
if (!headed) args.push('--headless=new');
const chrome = spawn(CHROME, args, { stdio: 'ignore' });

let out;
try {
    let cdp = null;
    for (let i = 0; i < 60; i++) {
        try { cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`); break; } catch { await sleep(250); }
    }
    if (!cdp) throw new Error('CDP never came up');
    const { sessionId } = await newPage(cdp);
    await goto(cdp, sessionId, PAGE);
    await sleep(400);
    out = JSON.parse(await evaluate(cdp, sessionId, PROBE));
    await cdp.close();
} finally {
    chrome.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true });
}

// Each unordered pair comes back twice, once from each side. Keep one row per
// pair and let the table answer in both directions.
const seen = new Set();
const rows = [];
for (const [a, b] of out.pairs) {
    const key = [a, b].sort().join(' ');
    if (seen.has(key)) continue;
    seen.add(key);
    rows.push([a, b].sort());
}
rows.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));

const zig = `// GENERATED by tools/fingerprint/dump-css-logical.mjs — do not hand-edit.
//
// Measured from ${out.ua}
// ${rows.length} pairs over ${out.total} longhands.
//
// Two spellings of one property: \`margin-block-start\` and \`margin-top\` are the
// same thing, so an element declaring either computes both. This engine stores
// what the page wrote and nothing else, which is why a physical \`margin\`
// declaration used to leave every \`margin-block-*\` reading its initial value.
//
// **Measured in the default writing mode only — horizontal-tb, ltr.** That is
// the one this engine lays out, and the same assumption \`width\` / \`inline-size\`
// already share in CSSStyleDeclaration. In \`writing-mode: vertical-rl\` the
// block axis is horizontal and this table's pairing is wrong; nothing here
// notices, because nothing here lays that out.
//
// The test was mutual co-movement, not the spelling: set one, see which others
// took the same value, then set each of those to a different value and keep only
// the ones that dragged the first back. A one-way match is a side effect.
//
// Excluded as shorthands, because a shorthand over one longhand passes that test
// too (\`text-decoration\` did): ${out.shorthandsSkipped.join(', ')}.
${out.ambiguous.length > 0 ? `//
// Dropped as ambiguous (more than one mutual partner), rather than guessed at:
${out.ambiguous.map((a) => '//   ' + a).join('\n')}
` : '//\n// Nothing came out ambiguous.\n'}
const std = @import("std");

/// The other spelling of \`name\`, or null when it has only one.
pub fn counterpart(name: []const u8) ?[]const u8 {
    return pairs.get(name);
}

const pairs = std.StaticStringMap([]const u8).initComptime(.{
${rows.map(([a, b]) => `    .{ "${a}", "${b}" },\n    .{ "${b}", "${a}" },`).join('\n')}
});
`;

await fs.writeFile(outPath, zig);
console.log(`${outPath}: ${rows.length} pairs, ${out.ambiguous.length} ambiguous, ` +
    `${out.shorthandsSkipped.length} shorthands skipped, ` +
    `${out.unmovedCount} longhands no candidate moved`);
