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

// Kerning is per FACE, not per family: bold 'Campfire Commerce' came out 143.5
// against Chrome's 142.9375 once the bold advances were right, and italic
// 132.8828125 against 131.6953125 -- the regular pairs applied to variant
// advances. So all four faces are measured, and a face whose pairs are the
// regular ones gets no table of its own.
const FACES = [
    ['regular', ''],
    ['bold', 'bold '],
    ['italic', 'italic '],
    ['bold_italic', 'italic bold '],
];

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

// One round trip per family: for each of the four faces, 224 advances then all
// 50 176 pairs, in the page.
const probe = (quoted) => `(() => {
  const ctx = document.createElement('canvas').getContext('2d');
  const chr = (c) => String.fromCharCode(c);
  const face = (prefix) => {
    ctx.font = prefix + '100px ${quoted}';
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
    return { adv: adv.slice(0, 8), pairs };
  };
  return JSON.stringify({
${FACES.map(([k, p]) => `    ${k}: face('${p}'),`).join('\n')}
  });
})()`;

const out = [];
let skipped = 0;
let identical = 0;
for (const family of families) {
    const name = nameFor.get(family);
    const quoted = /^(serif|sans-serif|monospace|cursive|fantasy|system-ui|ui-[a-z]+|math|emoji|fangsong)$/.test(name)
        ? name : `\\"${name}\\"`;
    const res = await cdp.send('Runtime.evaluate',
        { expression: probe(quoted), returnByValue: true }, sessionId);
    const got = JSON.parse(res.result.value);
    const want = advancesFor.get(family);
    const same = want.every((w, i) => Math.abs(w - got.regular.adv[i]) < 1e-9);
    if (!same) {
        process.stderr.write(`skip ${family} (${name}): advances differ from the table -- not resolving here\n`);
        skipped++;
        continue;
    }
    const undrawable = undrawableFor.get(family) ?? new Set();
    const keep = (face) => face.pairs.filter(([a, b]) => !undrawable.has(a) && !undrawable.has(b));
    const regular = keep(got.regular);
    const key = (list) => list.map((p) => p.join(':')).join(',');
    const regular_key = key(regular);
    const faces = [['regular', regular]];
    for (const [face] of FACES.slice(1)) {
        const pairs = keep(got[face]);
        // A face that kerns the way the regular one does needs no table: the
        // lookup falls back to regular, and writing an identical copy would
        // cost 6MB per face to say nothing.
        if (key(pairs) !== regular_key) faces.push([face, pairs]);
        else identical++;
    }
    out.push({ family, name, faces });
    process.stderr.write(`${family}: ${faces.map(([f, p]) => `${f}=${p.length}`).join(' ')}\n`);
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
const font_variants = @import("font_variants.zig");

pub const Pair = struct { first: u8, second: u8, kern: f64 };

/// One family's pairs, sorted by (first, second), plus a bitmap of the
/// characters that start one.
///
/// A lookup happens once per character of every string this engine measures, so
/// both halves earn their place. The bitmap answers most characters in a shift
/// and an AND -- 28 of the 224 start a pair in the average family. But the ones
/// that do are the common ones: every capital, and 'o', 'r', 'v', 'w', 'y'. So
/// ordinary prose reaches the pairs on most of its letters, which is why they
/// are bisected and not scanned.
pub const Table = struct {
    pairs: []const Pair = &.{},
    starts: [4]u64 = .{ 0, 0, 0, 0 },
};

`;
for (const t of out) {
    for (const [face, pairs] of t.faces) {
        const sorted = pairs.slice().sort((x, y) => x[0] - y[0] || x[1] - y[1]);
        const starts = [0n, 0n, 0n, 0n];
        for (const [a] of sorted) starts[a >> 6] |= 1n << BigInt(a & 63);
        zig += `const kerns_${face}_${t.family} = [_]Pair{`;
        zig += sorted.map(([a, b, k]) => `.{ .first = ${a}, .second = ${b}, .kern = ${k} }`).join(', ');
        zig += `};\n`;
        zig += `const starts_${face}_${t.family} = [4]u64{ ${starts.map((x) => x.toString()).join(', ')} };\n`;
    }
}
zig += `
/// The pairs for a family in a variant, matched on the identity of its regular
/// advance table: a \`Family\` is a value, and its \`glyphs\` slice is the one
/// thing unique to it. Looked up once per string rather than once per character.
///
/// A variant with no row here kerns the way the regular face does, which is a
/// measurement and not a default -- most families' italic pairs ARE their
/// regular pairs, and a copy would cost 6MB per face to say so.
pub fn tableFor(family: font_metrics.Family, variant: font_variants.Variant) Table {
    const rows = [_]struct { []const font_metrics.Glyph, font_variants.Variant, []const Pair, *const [4]u64 }{
${out.flatMap((t) => t.faces.map(([f]) => `        .{ font_metrics.${t.family}.glyphs, .${f}, &kerns_${f}_${t.family}, &starts_${f}_${t.family} },`)).join('\n')}
    };
    var fallback: Table = .{};
    for (rows) |row| {
        if (row[0].ptr != family.glyphs.ptr) {
            continue;
        }
        if (row[1] == variant) {
            return .{ .pairs = row[2], .starts = row[3].* };
        }
        if (row[1] == .regular) {
            fallback = .{ .pairs = row[2], .starts = row[3].* };
        }
    }
    return fallback;
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
    // Scanning here instead cost 2.75x on the whole of text layout -- 16ms to
    // 44ms measuring 4000 spans of prose, deterministic across four rounds
    // (scratch/b99/kerncost). The tables run to 6458 pairs, and the family a
    // page is most likely to ask for, system-ui, has 3791.
    const want = (@as(u16, byte) << 8) | @as(u16, @intCast(b));
    var lo: usize = 0;
    var hi: usize = table.pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const pair = table.pairs[mid];
        const key = (@as(u16, pair.first) << 8) | @as(u16, pair.second);
        if (key == want) {
            return pair.kern;
        }
        if (key < want) {
            lo = mid + 1;
        } else {
            hi = mid;
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
const tables = out.reduce((n, t) => n + t.faces.length, 0);
process.stderr.write(
    `wrote src/browser/font_kerning.zig: ${tables} tables over ${out.length} families, ` +
    `${identical} variants kern like regular, ${skipped} families skipped\n`);
