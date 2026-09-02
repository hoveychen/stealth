// The kerning pairs each family in `font_metrics.zig` has, measured out of real
// Chrome, written to `src/browser/font_kerning.zig`.
//
//   node tools/fingerprint/dump-kerning.mjs [--headed] [--chrome-arg ...]
//
// `font_metrics.zig`'s header has carried the gap for a long time: "a string's
// width is the plain sum of its glyphs' advances, except across a kerning pair
// ... 'AV' and 'To' do not, and we do not model kerning, so those come out a
// little wide". Measured, that is `AV` at 23.109375 here against Chrome's
// 21.046875 -- a difference one `measureText` sees.
//
// **Additive on purpose.** `dump-fonts.mjs` rewrites all 59 585 lines of
// `font_metrics.zig` from whatever fonts this host has today, and that file's own
// header says its size is the number a detector reports. Regenerating it to add
// one field would put the whole font list in the diff. So the pairs go in a file
// of their own, keyed by each family's `glyphs` slice, and `font_metrics.zig` is
// not touched.
//
// The data is small: 234 of Latin-1's 50 176 pairs kern in serif, 228 in
// sans-serif, 140 in monospace -- half a percent
// (scratch/b99/expr-kern-census.js).
//
// A family that no longer resolves on this host would measure as the fallback
// and be written down with the fallback's pairs. So each family's own advances
// are checked against the table first, and one that disagrees is SKIPPED rather
// than guessed at.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT || 9466);
const FIRST = 0x20;
const LAST = 0xff;

const headed = process.argv.includes('--headed');
const chromeArgs = [];
for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === '--chrome-arg') chromeArgs.push(process.argv[i + 1]);
}

// Which families exist, and one CSS name that reaches each. 204 names map onto
// 182 tables; aliases resolve to the same face, so one name per table is enough.
const metrics = await fs.readFile(path.join(repo, 'src/browser/font_metrics.zig'), 'utf8');
const nameFor = new Map();
for (const m of metrics.matchAll(/^\s*\.\{ "([^"]+)", ([a-z0-9_]+) \},$/gm)) {
    if (!nameFor.has(m[2])) nameFor.set(m[2], m[1]);
}

// The first few advances of each family's table, to check the face still
// resolves the way it did when the advances were written.
const advancesFor = new Map();
for (const m of metrics.matchAll(/^const glyphs_([a-z0-9_]+) = \[_\]Glyph\{\n?([\s\S]{0,400})/gm)) {
    const nums = [...m[2].matchAll(/\.advance = ([0-9.eE+-]+)/g)].slice(0, 8).map((x) => Number(x[1]));
    if (nums.length) advancesFor.set(m[1], nums);
}

// The codepoints each family cannot draw. Chrome falls back per glyph for those,
// and the difference a PAIR of them shows is the fallback's doing, not kerning
// -- 'U+0098 U+0080' measures 32 where the two alone sum to 39.1, which
// text_measure.zig's own comment already pins as a fallback reading. Recording
// that as a kern broke three of its tests, so both members of a pair have to be
// glyphs the family owns.
const undrawableFor = new Map();
for (const m of metrics.matchAll(/^const seeds_([a-z0-9_]+) = \[_\]u21\{([\s\S]*?)\};$/gm)) {
    const set = undrawableFor.get(m[1]) ?? new Set();
    for (const n of m[2].matchAll(/(\d+)/g)) set.add(Number(n[1]));
    undrawableFor.set(m[1], set);
}
for (const m of metrics.matchAll(/^const after_([a-z0-9_]+) = \[_\]Override\{([\s\S]*?)^\};$/gm)) {
    const set = undrawableFor.get(m[1]) ?? new Set();
    for (const n of m[2].matchAll(/\.codepoint = (\d+)/g)) set.add(Number(n[1]));
    undrawableFor.set(m[1], set);
}

const families = [...nameFor.keys()].filter((f) => advancesFor.has(f)).sort();
process.stderr.write(`${families.length} families to measure\n`);

const chrome = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`,
    '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=' + (await fs.mkdtemp('/tmp/kern-')),
    ...(headed ? [] : ['--headless=new']),
    ...chromeArgs,
    'about:blank',
], { stdio: 'ignore' });
await sleep(2500);
const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetInfos } = await cdp.send('Target.getTargets');
const page = targetInfos.find((t) => t.type === 'page');
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });

// One round trip per family: 224 advances then 50 176 pairs, all in the page.
const probe = (quoted) => `(() => {
  const ctx = document.createElement('canvas').getContext('2d');
  ctx.font = '100px ${quoted}';
  const chr = (c) => String.fromCharCode(c);
  const adv = [];
  for (let c = ${FIRST}; c <= ${LAST}; c++) adv.push(ctx.measureText(chr(c)).width);
  const pairs = [];
  for (let a = ${FIRST}; a <= ${LAST}; a++) {
    const A = chr(a);
    for (let b = ${FIRST}; b <= ${LAST}; b++) {
      const k = ctx.measureText(A + chr(b)).width - adv[a - ${FIRST}] - adv[b - ${FIRST}];
      if (k !== 0) pairs.push([a, b, k]);
    }
  }
  return JSON.stringify({ adv: adv.slice(0, 8), pairs });
})()`;

const out = [];
let skipped = 0;
for (const family of families) {
    const name = nameFor.get(family);
    const quoted = /^(serif|sans-serif|monospace|cursive|fantasy|system-ui|ui-[a-z]+|math|emoji|fangsong)$/.test(name)
        ? name : `\\"${name}\\"`;
    const res = await cdp.send('Runtime.evaluate',
        { expression: probe(quoted), returnByValue: true }, sessionId);
    const got = JSON.parse(res.result.value);
    const want = advancesFor.get(family);
    const same = want.every((w, i) => Math.abs(w - got.adv[i]) < 1e-9);
    if (!same) {
        process.stderr.write(`skip ${family} (${name}): advances differ from the table -- not resolving here\n`);
        skipped++;
        continue;
    }
    const undrawable = undrawableFor.get(family) ?? new Set();
    const pairs = got.pairs.filter(([a, b]) => !undrawable.has(a) && !undrawable.has(b));
    out.push({ family, name, pairs });
    process.stderr.write(`${family}: ${pairs.length} pairs (${got.pairs.length - pairs.length} dropped as fallback)\n`);
}
cdp.ws.close();
chrome.kill();

// Emit. Pairs are sorted by (first, second) so the lookup can bisect, and the
// values stay at the table's 100px basis like every advance beside them.
let zig = `// Generated by tools/fingerprint/dump-kerning.mjs -- do not edit.
//
// The kerning pairs Chrome applies, per family, at the 100px basis every advance
// in \`font_metrics.zig\` is stored at. A string's width is the sum of its
// glyphs' advances PLUS these, and without them 'AV' comes out 23.109375 where
// Chrome says 21.046875.
//
// Latin-1 only, matching the advance tables, and sparse: about 0.5% of the
// 50 176 pairs kern. Deliberately a file of its own -- \`font_metrics.zig\` is
// the engine's font list and regenerating it to add a field would put all 182
// families in the diff.
const std = @import("std");
const font_metrics = @import("font_metrics.zig");

pub const Pair = struct { first: u8, second: u8, kern: f64 };

/// One family's pairs, plus a bitmap of the characters that start one.
///
/// The bitmap is what keeps this affordable. A pair lookup happens once per
/// character of every string this engine measures, and only about forty distinct
/// characters start a kerning pair at all -- so the common case is one shift and
/// one AND, and the scan below runs on the few that survive it.
pub const Table = struct {
    pairs: []const Pair = &.{},
    starts: [4]u64 = .{ 0, 0, 0, 0 },
};

`;
for (const t of out) {
    const sorted = t.pairs.slice().sort((x, y) => x[0] - y[0] || x[1] - y[1]);
    const starts = [0n, 0n, 0n, 0n];
    for (const [a] of sorted) starts[a >> 6] |= 1n << BigInt(a & 63);
    zig += `const kerns_${t.family} = [_]Pair{`;
    zig += sorted.map(([a, b, k]) => `.{ .first = ${a}, .second = ${b}, .kern = ${k} }`).join(', ');
    zig += `};\n`;
    zig += `const starts_${t.family} = [4]u64{ ${starts.map((x) => x.toString()).join(', ')} };\n`;
}
zig += `
/// The pairs for a family, matched on the identity of its advance table: a
/// \`Family\` is a value, and its \`glyphs\` slice is the one thing unique to it.
/// Looked up once per string rather than once per character.
pub fn tableFor(family: font_metrics.Family) Table {
    const rows = [_]struct { []const font_metrics.Glyph, []const Pair, *const [4]u64 }{
${out.map((t) => `        .{ font_metrics.${t.family}.glyphs, &kerns_${t.family}, &starts_${t.family} },`).join('\n')}
    };
    for (rows) |row| {
        if (row[0].ptr == family.glyphs.ptr) {
            return .{ .pairs = row[1], .starts = row[2].* };
        }
    }
    return .{};
}

/// What the pair (a, b) adds, at the 100px basis, and 0 for the 99.5% of pairs
/// that do not kern.
pub fn kern(table: Table, a: u21, b: u21) f64 {
    if (a > 0xff or b > 0xff) {
        return 0;
    }
    const byte: u8 = @intCast(a);
    if (table.starts[byte >> 6] & (@as(u64, 1) << @intCast(byte & 63)) == 0) {
        return 0;
    }
    for (table.pairs) |pair| {
        if (pair.first == byte and pair.second == b) {
            return pair.kern;
        }
    }
    return 0;
}
`;
await fs.writeFile(path.join(repo, 'src/browser/font_kerning.zig'), zig);
// `zig build` depends on the fmt step, so an unformatted table fails the build
// rather than the file -- run it here so a regeneration lands buildable.
await new Promise((done) => {
    spawn('zig', ['fmt', 'src/browser/font_kerning.zig'], { cwd: repo, stdio: 'ignore' }).on('exit', done);
});
process.stderr.write(`wrote src/browser/font_kerning.zig: ${out.length} families, ${skipped} skipped\n`);
