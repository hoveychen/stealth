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
// Many strings, one layout. The pair sweep below asks for 50 176 widths at a
// time and \`__raw\` forces a reflow for every one of them; a box per string in
// one throwaway host costs a single layout for the lot.
window.__batch = (font, strings) => {
  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;left:-9999px;top:0;visibility:hidden';
  host.style.font = font;
  const frag = document.createDocumentFragment();
  const cells = strings.map((s) => {
    const d = document.createElement('div');
    d.style.cssText = 'width:max-content;white-space:pre';
    d.textContent = s;
    frag.appendChild(d);
    return d;
  });
  host.appendChild(frag);
  document.body.appendChild(host);
  const out = cells.map((c) => c.getBoundingClientRect().width);
  host.remove();
  return out;
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

// --- the kern pairs at the TEXT master -------------------------------------
// The pairs in `font_kerning.zig` were read at 100px and are the DISPLAY
// master's. Chrome's move with the optical size the same way the advances do,
// and by as much: 1612 pairs of SF kern at 17px and not at 100, 1044 the other
// way round, and twelve characters start a pair only at the TEXT end.
//
// Read through layout like everything else here, with a SEPARATOR that kerns
// with nothing between the copies, so that n copies of "|ab" carry n clean
// (a, b) junctions and no others and the box quantisation divides by n:
//
//     adv(s)  = W(s^n) / n
//     adv(c)  = W((s c)^n) / n - adv(s)
//     k(a, b) = W((s a b)^n) / n - adv(s) - adv(a) - adv(b)
//
// Three passes, because the separator is itself one of the things to be
// measured: a coarse sweep of all 50 176 pairs finds both the pairs and the
// characters that are in none of them, one of those becomes the separator, and
// then the pairs are read again properly.
const KERN_SCAN_REPEAT = 4;
const KERN_REPEAT = 64;
// Kerns land on exact multiples of 1/2048 em -- SF's units per em. The engine's
// existing 100px table lands on them with a residual of exactly zero, so the
// reading is snapped to them and the assertion below is what says the snapping
// is recognising a grid rather than imposing one.
const KERN_UPEM = 2048;

// Every nonzero pair of one face at one size, in em, exact to 1/KERN_UPEM.
async function kernMaster(css, prefix, size) {
    const FONT = JSON.stringify(`${prefix}${size}px ${css}`);
    const CHARS = `const chars = []; for (let c = ${FIRST}; c <= ${LAST}; c++) chars.push(String.fromCharCode(c));`;

    // Pass 1, no separator: which pairs kern at all, and which characters are in
    // none of them. A single width is quantised to 1/256px, so this difference
    // of three carries 0.006px and the threshold sits well above it -- it only
    // has to be tight enough that the separator candidates are really untouched.
    const scan = await evaluate(`(() => { ${PRELUDE} ${CHARS}
        const font = ${FONT};
        const solo = __batch(font, chars);
        const strings = [];
        for (const a of chars) for (const b of chars) strings.push(a + b);
        const w = __batch(font, strings);
        const touched = new Set();
        let i = 0;
        for (let a = 0; a < chars.length; a++) for (let b = 0; b < chars.length; b++, i++) {
          if (Math.abs(w[i] - solo[a] - solo[b]) > 0.02) { touched.add(a); touched.add(b); }
        }
        // Never the space: the layout surface treats it apart from every other
        // character, and its own pairs are in a table of their own.
        const free = [];
        for (let c = 1; c < chars.length; c++) if (!touched.has(c)) free.push(c + ${FIRST});
        return JSON.stringify({ free, kerning: touched.size });
    })()`);
    if (scan.free.length < 3) {
        throw new Error(`no separator candidates: every character kerns with something`);
    }

    // Is a candidate really neutral? For candidate s and character x,
    //     W((s x)^n) - W(s^n) - W(x^n)
    //        = n k(s,x) + (n-1) k(x,s) - (n-1) k(s,s) - (n-1) k(x,x)
    // which for a neutral s is -(n-1) k(x,x) -- the same row whichever neutral
    // candidate is used. Candidates that all produce the SAME row are all
    // neutral, short of every one of them kerning identically with all 224
    // characters, and a candidate that differs is rejected.
    const cands = scan.free.slice(0, 6);
    const rows = await evaluate(`(() => { ${PRELUDE} ${CHARS}
        const font = ${FONT}, n = 32;
        const solo = __batch(font, chars.map((c) => c.repeat(n)));
        const out = {};
        for (const cand of ${JSON.stringify(cands)}) {
          const s = String.fromCharCode(cand);
          const w = __batch(font, chars.map((x) => (s + x).repeat(n)));
          out[cand] = w.map((v, i) => +(v - solo[cand - ${FIRST}] - solo[i]).toFixed(6));
        }
        return JSON.stringify(out);
    })()`);
    const first = rows[cands[0]];
    for (const c of cands.slice(1)) {
        // Three undivided 1/256px reads go into a row, so the floor is 0.012px;
        // a candidate that really kerns would be off by n times a kern, which
        // at this size is whole pixels.
        const bad = rows[c].findIndex((v, i) => Math.abs(v - first[i]) > 0.05);
        if (bad >= 0) {
            throw new Error(`separator candidates disagree at U+${(bad + FIRST).toString(16)}: ` +
                `${cands[0]} says ${first[bad]}, ${c} says ${rows[c][bad]}`);
        }
    }
    const SEP = String.fromCharCode(cands[0]);

    // Pass 2, with the separator and few copies: the pair set, at eight times
    // the precision of pass 1. Pass 3 then reads that set properly.
    const sweep = (n, listing) => `(() => { ${PRELUDE} ${CHARS}
        const font = ${FONT}, sep = ${JSON.stringify(SEP)}, n = ${n};
        const s = __batch(font, [sep.repeat(n)])[0] / n;
        const adv = __batch(font, chars.map((c) => (sep + c).repeat(n))).map((v) => v / n - s);
        ${listing}
        const w = __batch(font, list.map(([a, b]) =>
            (sep + String.fromCharCode(a) + String.fromCharCode(b)).repeat(n)));
        return JSON.stringify(list.map(([a, b], i) =>
            [a, b, w[i] / n - s - adv[a - ${FIRST}] - adv[b - ${FIRST}]]));
    })()`;
    const coarse = await evaluate(sweep(KERN_SCAN_REPEAT, `
        const list = [];
        for (const a of chars) for (const b of chars) list.push([a.charCodeAt(0), b.charCodeAt(0)]);`));
    const wanted = coarse.filter(([, , k]) => Math.abs(k) > 0.005).map(([a, b]) => [a, b]);
    const fine = await evaluate(sweep(KERN_REPEAT, `const list = ${JSON.stringify(wanted)};`));

    // Snap. The residual is the claim that these values ARE font units; it runs
    // at 0.06 of one, against a read noise of 0.02.
    let worst = 0;
    const pairs = [];
    for (const [a, b, k] of fine) {
        const units = (k / size) * KERN_UPEM;
        worst = Math.max(worst, Math.abs(units - Math.round(units)));
        if (Math.round(units) !== 0) pairs.push([a, b, (Math.round(units) / KERN_UPEM) * 100]);
    }
    if (worst > 0.25) {
        throw new Error(`kerns are not multiples of 1/${KERN_UPEM} em: worst residual ${worst.toFixed(3)} units`);
    }
    return { pairs, worst, sep: cands[0], scanned: wanted.length };
}

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
        // The pairs, at both masters and at all three weights -- they move with
        // the weight the way the advances do, and by more: 'Ya' at the TEXT
        // master is -0.0635 em at weight 1 and -0.1074 at 1000, and 'Fo' kerns
        // at the DISPLAY master at every weight and at the TEXT master at none.
        //
        // The DISPLAY set at the middle master is the one reading NOT taken:
        // that is the table the caller already looked the family up in, held
        // the way `display[MID] = held` is above, so a page at `font-weight:
        // 400` charges the pairs `font_kerning.zig` has always charged, bit for
        // bit. The TEXT one at 400 is read, because there is nothing to hold.
        //
        // Split the way the engine's two display tables are: `font_kerning.zig`
        // has no pair with a space on either side and `font_space_kerning.zig`
        // has nothing else, because the canvas surface applies the first and
        // not the second.
        const spacey = ([a, b]) => a === 0x20 || b === 0x20;
        const textKerns = [], displayKerns = [];
        for (let w = 0; w < WEIGHTS.length; w++) {
            const prefix = `${style}${WEIGHTS[w]} `;
            const t = await kernMaster(css, prefix, TEXT_SIZE);
            const d = w === MID ? null : await kernMaster(css, prefix, 100);
            textKerns.push(t.pairs);
            displayKerns.push(d && d.pairs);
            process.stderr.write(
                `  ${family}/${roman}@${WEIGHTS[w]}: ${t.pairs.length} TEXT pairs ` +
                `(${t.pairs.filter(spacey).length} with a space)` +
                (d ? `, ${d.pairs.length} DISPLAY pairs (${d.pairs.filter(spacey).length} with a space)` : `, DISPLAY held`) +
                `, separator U+${t.sep.toString(16)}, worst snap ${t.worst.toFixed(3)} of a font unit\n`);
        }

        tables.push({
            family,
            roman,
            display: display.map((row) => row.map((v) => v * 100)),
            text: text.map((row) => row.map((v) => v * 100)),
            textKerns: textKerns.map((p) => p.filter((x) => !spacey(x))),
            textSpaceKerns: textKerns.map((p) => p.filter(spacey)),
            displayKerns: displayKerns.map((p) => p && p.filter((x) => !spacey(x))),
            displaySpaceKerns: displayKerns.map((p) => p && p.filter(spacey)),
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
// **The kerning pairs are optical too**, and \`text_kerns\` below is their TEXT
// master. \`font_kerning.zig\` was read at 100px and is the DISPLAY one: 'AV' is
// -0.15503 em there and -0.12596 at ${TEXT_SIZE}px and below. It is not a scaling --
// 1612 pairs of SF kern at ${TEXT_SIZE}px and not at 100, 1044 the other way round, and
// twelve characters start a pair only at the TEXT end -- so it is a table, and
// it crosses on the same \`w\` ladder: 48 pairs read at every whole size from 15
// to 32 each solve for the same w to 5e-4, which is the ladder the advances
// solved for to 6.6e-3.
//
// And the pairs ride the WEIGHT axis as well, by more than the advances do:
// 'Ya' at the TEXT master is -0.0635 em at weight 1 and -0.1074 at 1000, and
// 'DZ' at the DISPLAY master kerns at both ends of the axis and not at its
// middle. So each master carries a set per weight, interpolated the same way
// and clamped the same way -- except that the DISPLAY set at weight 400 is not
// tabulated at all: that one is \`font_kerning.zig\`, handed in by the caller.
//
// The values are exact multiples of 1/${KERN_UPEM} em and are snapped to them. So is
// every value in \`font_kerning.zig\`, to a residual of zero, which is what says
// the grid is the font's and not the reading's.
const font_metrics = @import("font_metrics.zig");
const font_variants = @import("font_variants.zig");
const font_kerning = @import("font_kerning.zig");

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
    /// The kerning pairs at the TEXT master, at the three weights, in the shape
    /// \`font_kerning.zig\` holds the DISPLAY ones in and at the same basis. A
    /// pair that kerns at one master or one weight and not another is simply
    /// absent from that one's table, which is the zero the lookup already
    /// answers with.
    text_kerns: [weight_masters.len]font_kerning.Table = .{ .{}, .{}, .{} },
    /// The same for the pairs with a space on one side, which live in
    /// \`font_space_kerning.zig\` because the canvas surface does not apply them.
    text_space_kerns: [weight_masters.len]font_kerning.Table = .{ .{}, .{}, .{} },
    /// The pairs at the DISPLAY master, at the same three weights, with the
    /// MIDDLE one left empty on purpose: that is the table the caller already
    /// looked the family up in and hands to \`kern\`, held rather than tabulated
    /// again so that \`font-weight: 400\` charges what \`font_kerning.zig\` has
    /// always charged, bit for bit.
    display_kerns: [weight_masters.len]font_kerning.Table = .{ .{}, .{}, .{} },
    /// The same for the space pairs, whose held middle master is the caller's
    /// \`font_space_kerning.zig\` row.
    display_space_kerns: [weight_masters.len]font_kerning.Table = .{ .{}, .{}, .{} },

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

    /// What the pair (a, b) adds at \`size\` and \`weight\`, at the basis, given the
    /// DISPLAY pairs at weight 400 the caller already looked the family up in.
    /// Answers \`held\` itself for a face with no table and for every size from
    /// 28px up, so the pairs a page at a heading size asks for are untouched.
    pub fn kern(self: Table, held: font_kerning.Table, a: u21, b: u21, size: f64, weight: u16) f64 {
        return self.mix(self.display_kerns, held, self.text_kerns, a, b, size, weight);
    }

    /// The same for a pair with a space on one side, whose held DISPLAY values
    /// are in \`font_space_kerning.zig\` and which only the layout surface
    /// applies.
    pub fn spaceKern(self: Table, held: font_kerning.Table, a: u21, b: u21, size: f64, weight: u16) f64 {
        return self.mix(self.display_space_kerns, held, self.text_space_kerns, a, b, size, weight);
    }

    fn mix(
        self: Table,
        display: [weight_masters.len]font_kerning.Table,
        held: font_kerning.Table,
        text: [weight_masters.len]font_kerning.Table,
        a: u21,
        b: u21,
        size: f64,
        weight: u16,
    ) f64 {
        // Before the weight blend and not after it: a family with no table here
        // has three empty DISPLAY rows, and blending the caller's row towards
        // one of those would halve the pairs of every bold face in the engine.
        if (self.text[0].len == 0) return font_kerning.kern(held, a, b);
        const d = kernAtWeight(display, held, a, b, weight);
        const w = at(self.text_weight, size);
        if (w == 0) return d;
        return d + w * (kernAtWeight(text, text[mid_master], a, b, weight) - d);
    }
};

/// The master the caller holds: \`display_kerns[mid_master]\` is empty and
/// \`kernAtWeight\` reads the caller's table in its place.
const mid_master = 1;

/// One pair's value at one weight, linear between the tabulated weights and
/// clamped outside them, with \`held\` standing in at the middle master.
///
/// A weight that IS a master comes back bit for bit, the way \`atWeight\` does:
/// the two ends are returned whole rather than blended with a zero coefficient.
fn kernAtWeight(
    tables: [weight_masters.len]font_kerning.Table,
    held: font_kerning.Table,
    a: u21,
    b: u21,
    weight: u16,
) f64 {
    const w: f64 = @floatFromInt(weight);
    if (w <= weight_masters[0]) return font_kerning.kern(tables[0], a, b);
    if (w >= weight_masters[weight_masters.len - 1]) {
        return font_kerning.kern(tables[weight_masters.len - 1], a, b);
    }
    var hi: usize = 1;
    while (w > weight_masters[hi]) hi += 1;
    const lo = hi - 1;
    const f = (w - weight_masters[lo]) / (weight_masters[hi] - weight_masters[lo]);
    const lo_t = if (lo == mid_master) held else tables[lo];
    const hi_t = if (hi == mid_master) held else tables[hi];
    if (f == 0) return font_kerning.kern(lo_t, a, b);
    if (f == 1) return font_kerning.kern(hi_t, a, b);
    return font_kerning.kern(lo_t, a, b) * (1 - f) + font_kerning.kern(hi_t, a, b) * f;
}

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
// A pair table in the shape `font_kerning.zig` writes them: sorted so the
// lookup can bisect, with the bitmap of the characters that start one.
const pairArr = (name, pairs) => {
    const sorted = pairs.slice().sort((x, y) => x[0] - y[0] || x[1] - y[1]);
    const starts = [0n, 0n, 0n, 0n];
    for (const [a] of sorted) starts[a >> 6] |= 1n << BigInt(a & 63);
    return `const ${name} = [_]font_kerning.Pair{` +
        sorted.map(([a, b, k]) => `.{ .first = ${a}, .second = ${b}, .kern = ${k} }`).join(', ') +
        `};\nconst ${name}_starts = [4]u64{ ${starts.map((x) => x.toString()).join(', ')} };\n`;
};
const pairTable = (name) => `.{ .pairs = &${name}, .starts = ${name}_starts }`;
// The four pair sets a roman carries, each at the three weights. A null row is
// the master the caller holds: no array is written for it and the literal below
// leaves the slot empty.
const PAIR_SETS = ['textkerns', 'textspacekerns', 'displaykerns', 'displayspacekerns'];
const pairKey = { textkerns: 'textKerns', textspacekerns: 'textSpaceKerns', displaykerns: 'displayKerns', displayspacekerns: 'displaySpaceKerns' };
const pairSlot = (t, set, w) => `${set}${WEIGHTS[w]}_${t.roman}_${t.family}`;
const pairSlotTable = (t, set, w) =>
    t[pairKey[set]][w] === null ? '.{}' : pairTable(pairSlot(t, set, w));
for (const t of tables) {
    const l = ladders.find((x) => x.family === t.family && x.roman === t.roman);
    for (let w = 0; w < WEIGHTS.length; w++) {
        zig += arr(slot(t, 'display', w), t.display[w]);
        zig += arr(slot(t, 'text', w), t.text[w]);
    }
    zig += ladderArr(`weight_${t.roman}_${t.family}`, l.weight);
    zig += ladderArr(`tracking_${t.roman}_${t.family}`, l.tracking);
    for (const set of PAIR_SETS) {
        for (let w = 0; w < WEIGHTS.length; w++) {
            const pairs = t[pairKey[set]][w];
            if (pairs !== null) zig += pairArr(pairSlot(t, set, w), pairs);
        }
    }
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
${tables.map((t) => `        .{ font_metrics.${t.family}.glyphs, ${t.roman === 'italic'}, .{ .display = .{ ${WEIGHTS.map((_, w) => `&${slot(t, 'display', w)}`).join(', ')} }, .text = .{ ${WEIGHTS.map((_, w) => `&${slot(t, 'text', w)}`).join(', ')} }, .text_weight = &weight_${t.roman}_${t.family}, .tracking = &tracking_${t.roman}_${t.family}, ${PAIR_SETS.map((set) => `.${{ textkerns: 'text_kerns', textspacekerns: 'text_space_kerns', displaykerns: 'display_kerns', displayspacekerns: 'display_space_kerns' }[set]} = .{ ${WEIGHTS.map((_, w) => pairSlotTable(t, set, w)).join(', ')} }`).join(', ')} } },`).join('\n')}
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
