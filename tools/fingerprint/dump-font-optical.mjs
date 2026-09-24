// The families whose advances are NOT linear in font size, written to
// `src/browser/font_optical.zig`.
//
//   node tools/fingerprint/dump-font-optical.mjs [--headed] [--chrome-arg ...]
//   node tools/fingerprint/dump-font-optical.mjs --survey   # which families, no write
//
// `font_metrics.zig` holds one table per face at a 100px basis and its header
// says one table is enough because "advances are exactly linear in font size".
// That is true of 203 of the 205 names it measures and false of the two that
// name the macOS system face -- `system-ui` and `BlinkMacSystemFont` resolve to
// SF, which is a variable font whose `opsz` axis Chrome pins to the font size.
// A paragraph of the Cloudflare challenge page comes to 895.48px of max-content
// here and 986.45 in Chrome because of it.
//
// What the sweep measures, rather than what a font file would suggest:
//
//   advance(glyph, size) / size = mix(DISPLAY, TEXT, w(size)) + t(size)
//
// TEXT is one master over 1..17px (224 code points agree to 8e-6 em across
// 6, 10, 13 and 17), DISPLAY is one master over 28..120px and IS the existing
// 100px table, and `w` crosses between them over 18..27. `t` is a tracking in
// em added to EVERY glyph's advance -- a single glyph's advance already carries
// it, so a run of n costs n*(a+t*size) and not n*a+(n-1)*t*size.
//
// Both ladders came out the same for regular, bold, italic and bold-italic to
// five decimals, so they are measured per face and written once, with the
// spread across faces reported.
//
// **Measured through LAYOUT, not `measureText`.** For this face alone the canvas
// picks a wrong optical instance for a whole font size at a time -- 24, 32, 40
// and 48px have each read ~10% wide in one pass and correctly in the next,
// stable across three reads inside a pass, and unmoved by a fresh context, a
// different family read first, or a `32.001px` size. Layout has never been
// caught doing it. The price is that a box width is quantised to 1/256px, so
// every advance here is n copies of the glyph over n.
//
// Additive on purpose, like `font_kerning.zig` and `font_variants.zig`:
// regenerating `font_metrics.zig` rewrites all 59 585 of its lines from
// whatever fonts this host has today, and its header says its size is the
// number a detector reports. This file adds no NAMES.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT || 9471);
const FIRST = 0x20;
const LAST = 0xff;
const COUNT = LAST - FIRST + 1;
// The swept range of the two ladders, matching `font_metrics.swept_sizes`.
const SIZES = 120;
// The size the TEXT master is read at: the largest one still entirely on it, so
// the 1/256px box quantisation buys the most precision. The tracking there is
// folded out by construction -- see `NORMAL_SIZE` in the emitted comment.
const TEXT_SIZE = 17;
// Repeat counts. A box rounds once, so n copies over n divides the quantisation
// by n: 256 copies at 17px puts the error at 9e-7 em.
const TEXT_REPEAT = 512;
const LADDER_REPEAT = 128;
// The screening pass only has to tell a real optical face from the 1/256px
// noise floor, so it is cheaper and the threshold below is well above it.
const SCREEN_REPEAT = 128;
// The glyphs the two unknowns are solved from at each size. They need a spread
// in how far TEXT sits from DISPLAY -- '.' moves 0.122 em and '0' 0.063 -- or
// `w` and `t` are not separable. And none of them may pair with ITSELF, because
// a run of one glyph carries that pair and correcting for it down here costs
// more precision than it buys: the correction is one 1/256px read over the font
// size, which at 1px is 0.012 em. The check below is what holds that.
const LADDER = ['.', '0', 'x', 'M', ' ', 'W'];

const headed = process.argv.includes('--headed');
const surveyOnly = process.argv.includes('--survey');
const chromeArgs = [];
for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === '--chrome-arg') chromeArgs.push(process.argv[i + 1]);
}

// The families to consider, and the advances that say each one still resolves
// here the way it did when `font_metrics.zig` was written. Same guard, and same
// `\.advance` care, as dump-font-variants.mjs: a pattern that lets the leading
// dot into the number turns every advance into NaN and silently skips
// everything.
const metrics = await fs.readFile(path.join(repo, 'src/browser/font_metrics.zig'), 'utf8');
const nameFor = new Map();
for (const m of metrics.matchAll(/^\s*\.\{ "([^"]+)", ([a-z0-9_]+) \},$/gm)) {
    if (!nameFor.has(m[2])) nameFor.set(m[2], m[1]);
}
const displayFor = new Map();
for (const m of metrics.matchAll(/^const glyphs_([a-z0-9_]+) = \[_\]Glyph\{([\s\S]*?)\n\};/gm)) {
    const nums = [...m[2].matchAll(/\.advance = ([0-9.eE+-]+)/g)].map((x) => Number(x[1]));
    if (nums.length === COUNT) displayFor.set(m[1], nums);
}
// The same, for the three variant tables, which live in their own generated
// file and are what the engine answers for a bold or italic face. A variant
// with no table there falls back to the regular one, exactly as
// `font_variants.tableFor` does.
const variants = await fs.readFile(path.join(repo, 'src/browser/font_variants.zig'), 'utf8');
const variantDisplay = new Map();
for (const m of variants.matchAll(/^const (bold|italic|bold_italic)_([a-z0-9_]+) = \[_\]font_metrics\.Glyph\{([\s\S]*?)\n?\};/gm)) {
    const nums = [...m[3].matchAll(/\.advance = ([0-9.eE+-]+)/g)].map((x) => Number(x[1]));
    if (nums.length === COUNT) variantDisplay.set(`${m[1]}_${m[2]}`, nums.map((a) => a / 100));
}
const variantDisplayFor = (family, variant) =>
    (variant === 'regular' ? null : variantDisplay.get(`${variant}_${family}`) ?? null);

const families = [...nameFor.keys()].filter((f) => displayFor.has(f)).sort();
process.stderr.write(`${families.length} families to screen for optical sizing\n`);

// An optical face is measured per ROMAN, not per variant: SF's `wght` is a
// continuous axis, so `bold` is not a face but the point 700 on it. At 100px
// every multiple of 25 from 1 to 1000 measures differently, in two straight
// lines meeting at 400.
const ROMANS = [
    ['roman', ''],
    ['italic', 'italic '],
];
// The masters those two lines meet at, and the ends they run to. Interpolating
// between them reproduces a held-out weight to 2.4e-4 em at the median and at
// the 95th percentile alike; the two code points that miss are U+7F and U+80,
// whose notdef box does not move with the weight at all.
const WEIGHTS = [1, 400, 1000];
// Which of those the engine already holds a table for, so the generated one is
// that table's own values rather than a fresh reading of it -- `font-weight:
// 400` and `bold` have to keep answering exactly what they answer today.
const MID = 1;

const chrome = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
    '--user-data-dir=' + (await fs.mkdtemp('/tmp/optical-')),
    ...(headed ? [] : ['--headless=new']),
    ...chromeArgs,
    'about:blank',
], { stdio: 'ignore' });
await sleep(2500);
const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetInfos } = await cdp.send('Target.getTargets');
const page = targetInfos.find((t) => t.type === 'page');
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });

async function evaluate(expression) {
    const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
    if (res.exceptionDetails) throw new Error(JSON.stringify(res.exceptionDetails));
    return JSON.parse(res.result.value);
}

// The measuring element lives for the whole run. `white-space: pre` so a run of
// spaces is a run of spaces, and `width: max-content` so the box is the run.
const PRELUDE = `
window.__el = window.__el || (() => {
  const el = document.createElement('div');
  el.style.cssText = 'position:absolute;left:-9999px;top:0;width:max-content;white-space:pre';
  document.body.appendChild(el);
  return el;
})();
window.__raw = (font, s) => {
  __el.style.font = font;
  __el.textContent = s;
  return __el.getBoundingClientRect().width;
};
// One glyph's advance: n copies over n, which divides the 1/256px box
// quantisation by n. n copies cost n*a + (n-1)*k where k is whatever a pair of
// the SAME glyph costs beyond the two advances -- a self-kern, or a ligature --
// so this is a + k*(n-1)/n and n has to be large enough that a k too small for
// __selfPair to see is also too small to matter here.
//
// Solving for k instead of bounding it is what the first draft did, and it is
// wrong: k = w(2n) - 2*w(n) carries the quantisation of two reads UNDIVIDED, so
// subtracting it multiplies a 1/256px error back into the advance and made 105
// of 182 families read as optically sized.
window.__adv = (font, ch, n) => __raw(font, ch.repeat(n)) / n;
// What a pair of the same glyph costs beyond the two advances, in pixels. Two
// reads and no division, so a real pair shows at a 1/256px noise floor.
window.__selfPair = (font, ch) => {
  let sum = 0;
  for (const n of [4, 8, 16, 32]) sum += __raw(font, ch.repeat(2 * n)) - 2 * __raw(font, ch.repeat(n));
  return sum / 4;
};
`;
await evaluate(`(() => { ${PRELUDE} return JSON.stringify(true); })()`);

const quote = (name) =>
    /^(serif|sans-serif|monospace|cursive|fantasy|system-ui|ui-[a-z-]+|math|emoji|fangsong)$/.test(name)
        ? name : `"${name}"`;

// --- screening -------------------------------------------------------------
// One family is optical if its per-em advances at a TEXT size are not its
// per-em advances at the basis. Four glyphs, because a face could hold one of
// them still; 1e-5 em, because the box quantisation at 64 copies is 1e-6.
const optical = [];
for (const family of families) {
    const css = quote(nameFor.get(family));
    const got = await evaluate(`(() => { ${PRELUDE}
        const css = ${JSON.stringify(css)};
        const out = {};
        for (const size of [${TEXT_SIZE}, 100]) {
          out[size] = ${JSON.stringify(LADDER.slice(0, 4))}.map(
            (g) => __adv(size + 'px ' + css, g, ${SCREEN_REPEAT}) / size);
        }
        return JSON.stringify(out);
    })()`);
    // The face has to still resolve here, or "differs" means "is the fallback".
    const basis = displayFor.get(family);
    const want = LADDER.slice(0, 4).map((g) => basis[g.charCodeAt(0) - FIRST] / 100);
    if (!want.every((w, i) => Math.abs(w - got[100][i]) < 1e-4)) {
        process.stderr.write(`skip ${family} (${nameFor.get(family)}): 100px advances differ from the table\n`);
        continue;
    }
    const gap = Math.max(...got[TEXT_SIZE].map((v, i) => Math.abs(v - got[100][i])));
    if (gap > 1e-4) {
        optical.push(family);
        process.stderr.write(`optical: ${family} (${nameFor.get(family)}) -- ${gap.toFixed(5)} em at ${TEXT_SIZE}px\n`);
    }
}
process.stderr.write(`${optical.length} optical families\n`);
if (surveyOnly) { cdp.ws.close(); chrome.kill(); process.exit(0); }

// --- measuring -------------------------------------------------------------
// One face's per-em advances at one size, self-pair corrected. The run carries
// (n-1) copies of whatever a pair of this glyph with itself costs, so that has
// to come back out: four glyphs of SF pair with themselves by as much as 0.04
// em, which at TEXT_SIZE is 0.67px and would go straight into the table. Gated
// on a threshold well above the 1/256px read noise, because the correction is
// worth 0.04 em on the handful of glyphs that do pair and would ADD 3e-4 em of
// noise to the 218 that do not.
const tableAt = (FONT, size) => `(() => { ${PRELUDE} ${FONT}
    const out = [], pairs = [];
    for (let c = ${FIRST}; c <= ${LAST}; c++) {
      const ch = String.fromCharCode(c);
      const raw = __selfPair(font(${size}), ch);
      const k = Math.abs(raw) > 0.05 ? raw : 0;
      const n = ${TEXT_REPEAT};
      out.push((__adv(font(${size}), ch, n) - k * (n - 1) / n) / ${size});
      if (k) pairs.push([c, k / ${size}]);
    }
    return JSON.stringify({ advances: out, selfPairs: pairs });
})()`;

const tables = [];   // { family, roman, display: [3][], text: [3][] }  at the 100px basis
const ladders = [];  // { family, roman, weight[], tracking[] }
for (const family of optical) {
    const css = quote(nameFor.get(family));
    for (const [roman, style] of ROMANS) {
        // What this engine already answers at weight 400: the regular table for
        // the roman, the italic variant table for the italic. The generated
        // table is those values rather than a fresh reading of them, so
        // `font-weight: 400` keeps measuring exactly what it measures today and
        // the weight axis is additive at its own middle master.
        const held = (roman === 'italic'
            ? variantDisplayFor(family, 'italic')
            : null) ?? displayFor.get(family).map((a) => a / 100);

        const display = [], text = [];
        for (const w of WEIGHTS) {
            const prefix = `${style}${w} `;
            const FONT = `const font = (size) => ${JSON.stringify(prefix)} + size + 'px ' + ${JSON.stringify(css)};`;
            const measuredText = await evaluate(tableAt(FONT, TEXT_SIZE));
            const measuredDisplay = await evaluate(tableAt(FONT, 100));
            text.push(measuredText.advances);
            display.push(measuredDisplay.advances);
            if (measuredText.selfPairs.length) {
                process.stderr.write(`  ${family}/${roman}@${w}: pairs with itself: ` +
                    measuredText.selfPairs.map(([c, k]) => `U+${c.toString(16).padStart(4, '0')} ${k.toFixed(5)}em`).join(', ') + `\n`);
            }
        }
        // How far the measured middle master is from the one the engine holds.
        // Reported rather than assumed: if the two disagree by more than the
        // read noise, the face has stopped resolving the way `font_metrics.zig`
        // was written against and the whole table is against a different font.
        const drift = Math.max(...display[MID].map((v, i) => Math.abs(v - held[i])));
        if (drift > 1e-3) {
            throw new Error(`${family}/${roman}: measured weight-400 DISPLAY is ${drift.toExponential(2)} em from the engine's table`);
        }
        // Take the engine's values at the middle master, and leave TEXT alone.
        // The model is `D + w*(T-D) + t`, so at 100px it answers D and at
        // TEXT_SIZE it answers T: substituting one does not move the other, and
        // shifting TEXT by the difference would only write the read noise the
        // difference IS into the table it is subtracted from.
        display[MID] = held;

        const prefix400 = `${style}400 `;
        const FONT400 = `const font = (size) => ${JSON.stringify(prefix400)} + size + 'px ' + ${JSON.stringify(css)};`;
        const selfPaired = await evaluate(`(() => { ${PRELUDE} ${FONT400}
            return JSON.stringify(${JSON.stringify(LADDER)}
              .filter((g) => Math.abs(__selfPair(font(${TEXT_SIZE}), g)) > 0.05));
        })()`);
        if (selfPaired.length) {
            throw new Error(`ladder glyphs pair with themselves in ${family}/${roman}: ${selfPaired.join(' ')}`);
        }
        const ladder = await evaluate(`(() => { ${PRELUDE} ${FONT400}
            const out = [];
            for (let size = 1; size <= ${SIZES}; size++) {
              out.push(${JSON.stringify(LADDER)}.map((g) => __adv(font(size), g, ${LADDER_REPEAT}) / size));
            }
            return JSON.stringify(out);
        })()`);

        // Solve w and t at every size, least squares over the ladder glyphs:
        //   v(g) - D(g) = w * (T(g) - D(g)) + t
        //
        // At the middle master only. The six (weight, roman) combinations each
        // solve to the same pair of ladders to 1.2e-2 in w and 3.4e-4 in t --
        // the same spread the four VARIANTS showed before the axis was known --
        // so the optical axis and the weight axis separate and one ladder per
        // roman covers the whole weight range.
        const idx = LADDER.map((g) => g.charCodeAt(0) - FIRST);
        const T = idx.map((i) => text[MID][i]);
        const D = idx.map((i) => display[MID][i]);
        // TEXT is read at TEXT_SIZE, where the tracking is not zero, so `text`
        // is (master + t(TEXT_SIZE)). Normalising t to zero there is what makes
        // the two tables and the two ladders one consistent set -- w == 1 and
        // t == 0 at TEXT_SIZE reproduces the reading exactly.
        const gapv = T.map((v, i) => v - D[i]);
        const gm = gapv.reduce((a, b) => a + b, 0) / gapv.length;
        const gc = gapv.map((v) => v - gm);
        const den = gc.reduce((a, b) => a + b * b, 0);
        const weight = [], tracking = [];
        let worst = 0;
        for (let s = 1; s <= SIZES; s++) {
            const dl = ladder[s - 1].map((v, i) => v - D[i]);
            const dm = dl.reduce((a, b) => a + b, 0) / dl.length;
            const w = dl.reduce((a, v, i) => a + (v - dm) * gc[i], 0) / den;
            const t = dm - w * gm;
            worst = Math.max(worst, ...dl.map((v, i) => Math.abs(v - dm - w * gc[i])));
            weight.push(w);
            tracking.push(t);
        }
        tables.push({
            family,
            roman,
            display: display.map((row) => row.map((v) => v * 100)),
            text: text.map((row) => row.map((v) => v * 100)),
        });
        ladders.push({ family, roman, weight, tracking });
        process.stderr.write(
            `${family}/${roman}: w ${weight[0].toFixed(4)}..${weight[SIZES - 1].toFixed(4)}, ` +
            `worst residual ${worst.toExponential(2)} em, middle-master drift ${drift.toExponential(2)} em\n`);
    }
}
cdp.ws.close();
chrome.kill();

// The two ladders came out face-independent; report the spread rather than
// assume it, and write the regular face's.
let spreadW = 0, spreadT = 0;
for (const family of optical) {
    const rows = ladders.filter((l) => l.family === family);
    for (let s = 0; s < SIZES; s++) {
        const ws = rows.map((r) => r.weight[s]), ts = rows.map((r) => r.tracking[s]);
        spreadW = Math.max(spreadW, Math.max(...ws) - Math.min(...ws));
        spreadT = Math.max(spreadT, Math.max(...ts) - Math.min(...ts));
    }
}
process.stderr.write(`ladder spread across the romans: w ${spreadW.toExponential(2)}, t ${spreadT.toExponential(2)}\n`);

// --- writing ---------------------------------------------------------------
const num = (v) => (Number.isInteger(v) ? `${v}.0` : String(v));
let zig = `// Generated by tools/fingerprint/dump-font-optical.mjs -- do not edit.
//
// The families whose advances are NOT linear in font size, which on this
// platform is the macOS system face and nothing else: \`system-ui\` and
// \`BlinkMacSystemFont\` resolve to SF, a variable font whose \`opsz\` axis Chrome
// pins to the font size. \`font_metrics.zig\` holds one table per face at a 100px
// basis and says one is enough because advances scale; that holds for 203 of
// the 205 names it measures and not for these.
//
// The sweep behind the model, all of it through LAYOUT (see the generator: for
// this face the canvas reports a wrong optical instance for a whole size at a
// time, at random):
//
//     advance(glyph, size, weight) / size
//         = mix(DISPLAY(weight), TEXT(weight), w(size)) + t(size)
//
//   * TEXT is one master over 1..${TEXT_SIZE}px -- 224 code points agree to 8e-6 em
//     across 6, 10, 13 and ${TEXT_SIZE}px -- and is \`text_*\` below.
//   * DISPLAY is one master over 28..120px and is \`display_*\` below. At weight
//     400 it IS the existing 100px table in \`font_metrics.zig\` /
//     \`font_variants.zig\`, copied rather than re-read, so that weight keeps
//     answering exactly what it answered before this axis existed.
//   * \`w\` is 1 at or below 17px, 0 at or above 28px, and crosses between.
//   * \`t\` is a tracking in em added to EVERY glyph's advance. A single glyph's
//     advance already carries it, so a run of n costs n*(a + t*size) -- checked
//     against 1, 2, 4 ... 128 copies at five sizes.
//
// **Both masters move with \`font-weight\`, which is an AXIS and not two faces.**
// SF's \`wght\` is continuous: at 100px every multiple of 25 from 1 to 1000
// measures differently, in two straight lines meeting at 400. So \`bold\` is not
// a face, it is the point 700 on that axis, and mapping everything >= 600 onto
// one bold table made \`font-weight: 600 system-ui\` 1.24% too wide at every size
// -- which is what the h1 of the Cloudflare challenge page asks for.
//
// Each master is therefore three tables, at ${WEIGHTS.join(', ')}, with the value between
// them linear. Interpolating reproduces a held-out 600 and 700 to 2.4e-4 em at
// the median AND the 95th percentile; the only code points that miss are U+7F
// and U+80, whose notdef box does not move with the weight at all.
//
// Both ladders are normalised so that w == 1 and t == 0 at ${TEXT_SIZE}px, which is
// where \`text_*\` was read: the tables and the ladders are one set, and at
// ${TEXT_SIZE}px the model reproduces the reading exactly.
//
// The ladders do NOT move with the weight: the six (weight, roman) pairs each
// solve to the same two ladders to ${spreadW.toExponential(0)} in w and ${spreadT.toExponential(0)} in t, so the two axes
// separate and one ladder per roman covers the whole weight range. They are
// still written per roman rather than shared: 1.2e-2 of w across the crossing
// band is 0.03px a glyph at 24px, and a line of prose is thirty of them.
//
// Additive, like \`font_kerning.zig\` and \`font_variants.zig\`: this adds no
// NAMES, so the font enumeration a probe performs cannot see it.
//
// NOT modelled here: kerning. The pairs in \`font_kerning.zig\` are the DISPLAY
// master's and Chrome's move with the optical size too -- 'AV' is -0.15503 em
// at 28px and above and -0.12596 at 17px and below, on the same \`w\` crossing.
// Advances are the larger term by an order of magnitude and are what a
// max-content box is mostly made of; the pairs are a plan of their own.
const font_metrics = @import("font_metrics.zig");
const font_variants = @import("font_variants.zig");

/// The size \`text_*\` was measured at, and the size the two ladders are
/// normalised at.
pub const text_size = ${num(TEXT_SIZE)};

/// The weights the two masters are tabulated at. Between them the advance is
/// linear, and outside them it is clamped -- \`font-weight\` is already 1..1000
/// by the time it reaches here.
pub const weight_masters = [_]f64{ ${WEIGHTS.map(num).join(', ')} };

/// The swept range of the ladders. Above it \`w\` and \`t\` are both zero -- the
/// tracking reaches zero at 80px -- so a larger size is the DISPLAY master
/// exactly, which is what \`font_metrics.zig\` already answers.
pub const swept_sizes = ${SIZES};

/// One roman's two masters, each at the three weights in \`weight_masters\`, at
/// the same 100px basis \`font_metrics.zig\` uses and indexed the same way: code
/// point minus \`font_metrics.first_codepoint\`.
///
/// Advances only. The ink bearings a glyph also carries are read off the canvas
/// and the canvas cannot be trusted for this face, so an optical face keeps the
/// DISPLAY master's bearings -- they move the ink box, not the pen, and no
/// reading this engine is measured against has shown the difference. The
/// bearings do not move with the weight here either, for the same reason.
pub const Table = struct {
    display: [weight_masters.len][]const f64 = .{ &.{}, &.{}, &.{} },
    text: [weight_masters.len][]const f64 = .{ &.{}, &.{}, &.{} },
    /// The TEXT master's weight, per whole pixel of font size from 1 to
    /// \`swept_sizes\`. Empty alongside the tables.
    ///
    /// Per roman rather than one shared ladder: the two solve to the same one
    /// to 1.2e-2 in the crossing band, which is small but not nothing --
    /// 0.03px a glyph at 24px, and a line of prose is thirty of them.
    text_weight: []const f64 = &.{},
    /// The tracking in em, on the same ladder.
    tracking: []const f64 = &.{},

    pub fn empty(self: Table) bool {
        return self.text[0].len == 0;
    }

    /// The advance this face charges for \`codepoint\` at \`size\` and \`weight\`, at
    /// the basis. Falls back to \`display\` -- what \`font_metrics\` /
    /// \`font_variants\` answer -- for an empty table or a code point outside the
    /// tabulated range.
    pub fn advance(self: Table, codepoint: u21, display: f64, size: f64, weight: u16) f64 {
        if (self.text[0].len == 0) return display;
        if (codepoint < font_metrics.first_codepoint or codepoint > font_metrics.last_codepoint) {
            return display;
        }
        const i = codepoint - font_metrics.first_codepoint;
        const d = atWeight(self.display, i, weight);
        const t = atWeight(self.text, i, weight);
        return d + at(self.text_weight, size) * (t - d) + at(self.tracking, size) * font_metrics.basis;
    }
};

/// One master's value for one glyph at one weight, linear between the tabulated
/// weights and clamped outside them.
///
/// A weight that IS a master comes back bit for bit: the blend below is
/// \`lo*(1-f) + hi*f\` with f exactly 0 or 1, so nothing is added to it. That is
/// what keeps \`font-weight: 400\` -- and every unstyled paragraph on the web --
/// measuring exactly what it measured before this axis existed.
fn atWeight(tables: [weight_masters.len][]const f64, i: usize, weight: u16) f64 {
    const w: f64 = @floatFromInt(weight);
    if (w <= weight_masters[0]) return tables[0][i];
    if (w >= weight_masters[weight_masters.len - 1]) return tables[weight_masters.len - 1][i];
    var hi: usize = 1;
    while (w > weight_masters[hi]) hi += 1;
    const lo = hi - 1;
    const f = (w - weight_masters[lo]) / (weight_masters[hi] - weight_masters[lo]);
    return tables[lo][i] * (1 - f) + tables[hi][i] * f;
}

/// Linear interpolation into a ladder, clamped at both ends. Chrome's own
/// answer between two whole sizes is linear in the PER-EM advance -- 15.5px
/// reads 7.85596 where the two neighbours say 7.63184 and 8.07813, and a
/// straight line between the two widths would say 7.85499 -- which is what
/// interpolating the ladder rather than the width gives.
fn at(ladder: []const f64, size: f64) f64 {
    if (!(size > 1)) return ladder[0];
    if (size >= @as(f64, @floatFromInt(ladder.len))) return ladder[ladder.len - 1];
    const lower: usize = @intFromFloat(@floor(size));
    const frac = size - @floor(size);
    return ladder[lower - 1] * (1 - frac) + ladder[lower] * frac;
}

`;

// The ladders are solved by least squares, so an exact 0 or 1 arrives as
// 0.9999999999999998 and a true zero as -1.18e-15. Nine decimals is four orders
// finer than the 1e-4 em the fit's own residual reaches, and it keeps the file
// readable.
const clean = (v) => (Math.abs(v) < 1e-9 ? 0 : Number(v.toFixed(9)));
const arr = (name, values) => `const ${name} = [_]f64{ ${values.map(num).join(', ')} };\n`;
const ladderArr = (name, values) => arr(name, values.map(clean));
const slot = (t, master, w) => `${master}${WEIGHTS[w]}_${t.roman}_${t.family}`;
for (const t of tables) {
    const l = ladders.find((x) => x.family === t.family && x.roman === t.roman);
    for (let w = 0; w < WEIGHTS.length; w++) {
        zig += arr(slot(t, 'display', w), t.display[w]);
        zig += arr(slot(t, 'text', w), t.text[w]);
    }
    zig += ladderArr(`weight_${t.roman}_${t.family}`, l.weight);
    zig += ladderArr(`tracking_${t.roman}_${t.family}`, l.tracking);
}
zig += `
/// The table for a family in a roman, matched on the identity of its regular
/// advance table the way \`font_variants.tableFor\` is: a \`Family\` is a value and
/// its \`glyphs\` slice is the one thing unique to it.
///
/// Keyed on the ROMAN and not the variant, because the bold of an optical face
/// is a weight and not a face: \`.bold\` and \`.regular\` want the same table and
/// differ only in the weight they then ask it for.
pub fn tableFor(family: font_metrics.Family, variant: font_variants.Variant) Table {
    const italic = variant == .italic or variant == .bold_italic;
    const rows = [_]struct { []const font_metrics.Glyph, bool, Table }{
${tables.map((t) => `        .{ font_metrics.${t.family}.glyphs, ${t.roman === 'italic'}, .{ .display = .{ ${WEIGHTS.map((_, w) => `&${slot(t, 'display', w)}`).join(', ')} }, .text = .{ ${WEIGHTS.map((_, w) => `&${slot(t, 'text', w)}`).join(', ')} }, .text_weight = &weight_${t.roman}_${t.family}, .tracking = &tracking_${t.roman}_${t.family} } },`).join('\n')}
    };
    for (rows) |row| {
        if (row[0].ptr == family.glyphs.ptr and row[1] == italic) {
            return row[2];
        }
    }
    return .{};
}
`;
await fs.writeFile(path.join(repo, 'src/browser/font_optical.zig'), zig);
await new Promise((done) => {
    spawn('zig', ['fmt', 'src/browser/font_optical.zig'], { cwd: repo, stdio: 'ignore' }).on('exit', done);
});
process.stderr.write(`wrote src/browser/font_optical.zig: ${tables.length * WEIGHTS.length * 2} master tables ` +
    `over ${tables.length} romans of ${optical.length} families\n`);
