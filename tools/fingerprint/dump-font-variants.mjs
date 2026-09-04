// What each family in `font_metrics.zig` measures at bold, at italic, and at
// both, written to `src/browser/font_variants.zig`.
//
//   node tools/fingerprint/dump-font-variants.mjs [--headed] [--chrome-arg ...]
//
// `font_metrics.zig` holds one table per family and this engine uses it whatever
// the weight or style is, so `bold 16px serif` measures 'Campfire Commerce' at
// exactly the width `16px serif` does -- 133.7421875 against Chrome's 142.9375,
// to the last decimal place. Two lines of script separate the engines on that.
//
// **Additive on purpose**, for the same reason `font_kerning.zig` is: regenerating
// `font_metrics.zig` rewrites all 59 585 of its lines from whatever fonts this
// host has today, and its header says its size is the number a detector reports.
// This file is keyed on each family's `glyphs` slice and adds no NAMES -- font
// enumeration is a comparison between '"Candidate", monospace' and 'monospace',
// so a variant is invisible to it. A new family name would not be.
//
// Only families whose variant actually differs get a table. That is not a size
// optimisation, it is the measurement: Helvetica's italic advances are its
// regular advances, so `italic 16px sans-serif` and `16px sans-serif` really do
// both measure 147.5859375 in Chrome, and writing a table there would be
// inventing a difference.
//
// The guard from dump-kerning.mjs is kept, because it earned its place there: a
// family that no longer resolves on this host measures as the fallback, so each
// family's own advances are checked against the ones in the table first and a
// disagreeing family is SKIPPED rather than written down wrong.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT || 9468);
const FIRST = 0x20;
const LAST = 0xff;

// `bold` is not a case beside the numbers: 500 measures as regular and 600, 700
// and 900 all measure as bold, so the engine's threshold is >= 600 and these
// three prefixes are the whole space.
const VARIANTS = [
    ['bold', 'bold '],
    ['italic', 'italic '],
    ['bold_italic', 'italic bold '],
];

const headed = process.argv.includes('--headed');
const chromeArgs = [];
for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === '--chrome-arg') chromeArgs.push(process.argv[i + 1]);
}

const metrics = await fs.readFile(path.join(repo, 'src/browser/font_metrics.zig'), 'utf8');
const nameFor = new Map();
for (const m of metrics.matchAll(/^\s*\.\{ "([^"]+)", ([a-z0-9_]+) \},$/gm)) {
    if (!nameFor.has(m[2])) nameFor.set(m[2], m[1]);
}
// The first advances of each family, to check the face still resolves the way it
// did when they were written. Note the `\.advance` -- the data reads
// `.{ .advance = 25.0, ... }`, and a pattern that lets the leading dot into the
// number captures '.' and turns every advance into NaN, which skips all 182
// families and looks exactly like a host with no fonts on it.
const advancesFor = new Map();
for (const m of metrics.matchAll(/^const glyphs_([a-z0-9_]+) = \[_\]Glyph\{\n?([\s\S]{0,400})/gm)) {
    const nums = [...m[2].matchAll(/\.advance = ([0-9.eE+-]+)/g)].slice(0, 8).map((x) => Number(x[1]));
    if (nums.length) advancesFor.set(m[1], nums);
}

const families = [...nameFor.keys()].filter((f) => advancesFor.has(f)).sort();
process.stderr.write(`${families.length} families to measure, ${VARIANTS.length} variants each\n`);

const chrome = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
    '--user-data-dir=' + (await fs.mkdtemp('/tmp/variants-')),
    ...(headed ? [] : ['--headless=new']),
    ...chromeArgs,
    'about:blank',
], { stdio: 'ignore' });
await sleep(2500);
const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetInfos } = await cdp.send('Target.getTargets');
const page = targetInfos.find((t) => t.type === 'page');
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });

// One round trip per family: the regular table and all three variants, measured
// the same way dump-fonts.mjs measures the regular one so the five numbers mean
// the same thing in both files.
const probe = (quoted) => `(() => {
  const ctx = document.createElement('canvas').getContext('2d');
  const chr = (c) => String.fromCharCode(c);
  const table = (font) => {
    ctx.font = font;
    const out = [];
    for (let c = ${FIRST}; c <= ${LAST}; c++) {
      const m = ctx.measureText(chr(c));
      out.push([m.width, m.actualBoundingBoxLeft, m.actualBoundingBoxRight,
                m.actualBoundingBoxAscent, m.actualBoundingBoxDescent]);
    }
    return out;
  };
  return JSON.stringify({
    regular: table('100px ${quoted}'),
${VARIANTS.map(([k, p]) => `    ${k}: table('${p}100px ${quoted}'),`).join('\n')}
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
    if (!want.every((w, i) => Math.abs(w - got.regular[i][0]) < 1e-9)) {
        process.stderr.write(`skip ${family} (${name}): advances differ from the table -- not resolving here\n`);
        skipped++;
        continue;
    }

    const kept = [];
    for (const [key] of VARIANTS) {
        const differs = got[key].some((g, i) => g.some((v, j) => v !== got.regular[i][j]));
        if (differs) kept.push([key, got[key]]);
        else identical++;
    }
    if (kept.length) out.push({ family, name, variants: kept });
    process.stderr.write(`${family}: ${kept.length ? kept.map(([k]) => k).join(',') : 'no variant differs'}\n`);
}
cdp.ws.close();
chrome.kill();

const num = (v) => (Number.isInteger(v) ? `${v}.0` : String(v));
const glyph = (g) =>
    `.{ .advance = ${num(g[0])}, .left = ${num(g[1])}, .right = ${num(g[2])}, .ascent = ${num(g[3])}, .descent = ${num(g[4])} }`;

let zig = `// Generated by tools/fingerprint/dump-font-variants.mjs -- do not edit.
//
// What each family measures at bold, at italic, and at both, at the same 100px
// basis \`font_metrics.zig\` holds the regular tables at. Without these, this
// engine answers the regular advances whatever the weight and style are, and
// \`bold 16px serif\` measures a string at exactly the width \`16px serif\' does.
//
// The weight threshold is >= 600, measured rather than assumed: at 16px serif
// 'M' is 14.2265625 at 500 and 15.1015625 at 600, 700 and 900 alike. And
// bold-italic is a fourth table, not the two effects composed -- 'Campfire
// Commerce' is 136.4375 there against bold's 142.9375 and italic's 131.6953125.
//
// A family only appears here if its variant actually measures differently.
// Helvetica's italic advances ARE its regular advances, so \`italic 16px
// sans-serif\` and \`16px sans-serif\` both answer 147.5859375 in Chrome and a
// table for it would be an invented difference.
//
// A file of its own, keyed on each family's \`glyphs\` slice, because
// \`font_metrics.zig\` is the engine's font list and its size is the number a
// detector reports. Variants add no names, so they are invisible to the
// enumeration a probe actually performs.
const font_metrics = @import("font_metrics.zig");

pub const Variant = enum { regular, bold, italic, bold_italic };

/// One family's glyphs in one variant, indexed the same way \`font_metrics\`
/// indexes its own: code point minus \`first_codepoint\`.
pub const Table = struct {
    glyphs: []const font_metrics.Glyph = &.{},

    pub fn get(self: Table, codepoint: u21) ?font_metrics.Glyph {
        if (self.glyphs.len == 0 or codepoint < font_metrics.first_codepoint or codepoint > font_metrics.last_codepoint) {
            return null;
        }
        return self.glyphs[codepoint - font_metrics.first_codepoint];
    }
};

`;
for (const t of out) {
    for (const [key, table] of t.variants) {
        zig += `const ${key}_${t.family} = [_]font_metrics.Glyph{`;
        zig += table.map(glyph).join(', ');
        zig += `};\n`;
    }
}
zig += `
/// The table for a family in a variant, matched on the identity of its regular
/// advance table -- a \`Family\` is a value, and its \`glyphs\` slice is the one
/// thing unique to it. Looked up once per string rather than once per glyph.
pub fn tableFor(family: font_metrics.Family, variant: Variant) Table {
    if (variant == .regular) {
        return .{};
    }
    const rows = [_]struct { []const font_metrics.Glyph, Variant, []const font_metrics.Glyph }{
${out.flatMap((t) => t.variants.map(([k]) => `        .{ font_metrics.${t.family}.glyphs, .${k}, &${k}_${t.family} },`)).join('\n')}
    };
    for (rows) |row| {
        if (row[0].ptr == family.glyphs.ptr and row[1] == variant) {
            return .{ .glyphs = row[2] };
        }
    }
    return .{};
}

/// Which table a resolved font wants. The threshold is the measurement: 500 is
/// regular and 600 is bold, so \`bold\` the keyword is just 700 arriving here.
pub fn variantFor(weight: u16, italic: bool) Variant {
    if (weight >= 600) {
        return if (italic) .bold_italic else .bold;
    }
    return if (italic) .italic else .regular;
}
`;
await fs.writeFile(path.join(repo, 'src/browser/font_variants.zig'), zig);
// `zig build` depends on the fmt step, so an unformatted table fails the build
// rather than the file -- run it here so a regeneration lands buildable.
await new Promise((done) => {
    spawn('zig', ['fmt', 'src/browser/font_variants.zig'], { cwd: repo, stdio: 'ignore' }).on('exit', done);
});
const tables = out.reduce((n, t) => n + t.variants.length, 0);
process.stderr.write(
    `wrote src/browser/font_variants.zig: ${tables} tables over ${out.length} families, ` +
    `${identical} variants identical to regular, ${skipped} families skipped\n`);
