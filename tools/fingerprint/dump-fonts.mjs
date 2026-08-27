// Measures every font family the reference host has, out of the real Chrome, and
// regenerates src/browser/font_metrics.zig from it.
//
//   node tools/fingerprint/dump-fonts.mjs --survey   # what resolves, and how many
//   node tools/fingerprint/dump-fonts.mjs [--headed] # measure + write the table
//   node tools/fingerprint/dump-fonts.mjs --chrome-arg --force-device-scale-factor=2
//
// Font enumeration is the one fingerprint surface that is pure arithmetic: a
// probe sets `font = '100px "Candidate", monospace'`, measures a string, and
// compares against `monospace` alone. Different width means the candidate
// resolved, which means it is installed. So "which fonts does this machine have"
// is answered entirely by which families we hold advance tables for, and the
// only way to answer it the way the claimed platform would is to measure that
// platform's whole collection.
//
// The candidate list comes from the host, not from a hardcoded probe list:
//   system_profiler -json SPFontsDataType  ->  every installed family.
// A family is kept only if Chrome resolves it to something other than the
// fallback face, which is the same test a fingerprinting script applies.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9463;
const headed = process.argv.includes('--headed');
const surveyOnly = process.argv.includes('--survey');
// Extra Chrome switches, repeatable, the way run-expr.mjs takes them. The one
// this exists for is `--force-device-scale-factor`: the line box a font builds
// is measured at the device scale, and this engine's persona is a dpr-2 screen.
const chromeArgs = process.argv.reduce((acc, a, i) => (
    a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
const outPath = path.join(repo, 'src/browser/font_metrics.zig');
const jsonPath = path.join(repo, 'tools/fingerprint/results/reference-chrome-fonts.json');

// The three CSS generic families come first and keep their generic names; the
// rest are real families, measured under the name a stylesheet would use.
const GENERICS = ['sans-serif', 'serif', 'monospace'];
const SWEPT_SIZES = 120;

// The tabulated range. It used to stop at U+007E; the Turnstile widget measures
// the UTF-8 bytes of an emoji read back as Latin-1, so U+0080..U+00FF is a
// fingerprint surface too and every code point up to U+00FF is measured now.
//
// The three tests below that decide *which families are in the table at all* --
// resolves, fullCoverage, and the alias key -- stay on the ASCII prefix. That
// is deliberate: the font list is what a probe enumerates, it was settled
// against the 65-name fingerprintjs list on the ASCII range, and widening the
// comparison would silently move it. ASCII decides who is in; the whole range
// is what they report.
const FIRST = 32;
const LAST = 255;
const ASCII_LAST = 126;
const ASCII_COUNT = ASCII_LAST - FIRST + 1;

// Names a stylesheet or a probe can resolve that are not installed *families*:
// the remaining CSS generics, the ui-* keywords, the two system-font aliases
// every framework ships, and the legacy PostScript-era names Chrome still maps.
// They go through the same filter as everything else -- one that resolves to the
// fallback face is dropped and stays absent -- so listing a name here is a
// question, not an assertion.
const EXTRA_NAMES = [
    'cursive',
    'fantasy',
    'system-ui',
    'ui-serif',
    'ui-sans-serif',
    'ui-monospace',
    'ui-rounded',
    '-apple-system',
    'BlinkMacSystemFont',
    'Times',
    'Courier',
    'Lucida Grande',
];

/// Every family installed on this host, as CSS would name it. The dot-prefixed
/// ones are Apple's internal faces (".SF NS", ".Helvetica Neue DeskInterface"):
/// a stylesheet cannot resolve them, and Chrome does not, so they are dropped.
async function installedFamilies() {
    const out = await new Promise((resolve, reject) => {
        const p = spawn('system_profiler', ['-json', 'SPFontsDataType'], { stdio: ['ignore', 'pipe', 'ignore'] });
        let buf = '';
        p.stdout.on('data', (d) => (buf += d));
        p.on('error', reject);
        p.on('close', () => resolve(buf));
    });
    const families = new Set();
    for (const file of JSON.parse(out).SPFontsDataType ?? []) {
        for (const face of file.typefaces ?? []) {
            if (face.family && !face.family.startsWith('.')) families.add(face.family);
        }
    }
    return [...families].sort();
}

// One family's whole table. Runs in the page so the 224 advances, their ink
// boxes and the 120-size sweep are one round trip rather than 464.
const measure = (family, quoted) => `(() => {
  const ctx = document.createElement('canvas').getContext('2d');
  const EM = 100;
  const chr = (c) => String.fromCharCode(c);
  const advances = (font) => {
    ctx.font = font;
    const out = [];
    for (let c = ${FIRST}; c <= ${LAST}; c++) {
      const m = ctx.measureText(chr(c));
      out.push([m.width, m.actualBoundingBoxLeft, m.actualBoundingBoxRight, m.actualBoundingBoxAscent, m.actualBoundingBoxDescent]);
    }
    return out;
  };
  ctx.font = '100px ${quoted}';
  const resolved = ctx.font;
  const glyphs = advances('100px ${quoted}');
  // The resolution test a real probe applies. It has to run against all three
  // generic bases, because each one has a blind spot: a name that resolves to the
  // default serif ('Times' on macOS) measures identically to 'serif', and one
  // that resolves to the default monospace ('Menlo') measures identically to
  // 'monospace'. Installed means at least one base moves -- which is exactly what
  // fingerprintjs-shaped probes do, and why they use three bases.
  const probed = {
    monospace: advances('100px ${quoted}, monospace'),
    'sans-serif': advances('100px ${quoted}, sans-serif'),
    serif: advances('100px ${quoted}, serif'),
  };
  // Blink chooses one fallback font per run, seeded by the first character the
  // primary font cannot draw, and keeps it for the whole run. A character no
  // font on the host draws at all seeds the last resort font, which then
  // covers every later fallback-drawn character at a flat em apiece -- so a
  // code point's advance is not always the one it has alone. At 16px
  // sans-serif U+0098 U+0080 is 32 where U+0080 alone is 8.898, and that 7.102
  // is what made three of the Turnstile widget's ten strings wider than the
  // sum of their parts.
  //
  // Two passes, both measurements. The leader is bootstrapped by shape --
  // within this range only a glyph-less C1 control is an em wide with no ink,
  // where U+00C6 is an em wide but has ink -- and everything after that is
  // read off the canvas.
  ctx.font = '100px ${quoted}';
  const blank = (g) => Math.abs(g[0] - EM) < 1e-6 && !g[1] && !g[2] && !g[3] && !g[4];
  let leader = -1;
  for (let c = 0x80; c <= 0x9f; c++) if (blank(glyphs[c - ${FIRST}])) { leader = c; break; }

  // Pass one: what every code point costs behind that leader, which is to say
  // once the run is already on the last resort font.
  let behind = null, seeds = null, witness = -1;
  if (leader >= 0) {
    const lead = chr(leader);
    const leadWidth = ctx.measureText(lead).width;
    behind = [];
    for (let c = ${FIRST}; c <= ${LAST}; c++) {
      const m = ctx.measureText(lead + chr(c));
      // Advance is the pair less the leader; the ink box is shifted back over
      // the leader's advance so it means the same thing as a lone glyph's.
      behind.push([
        m.width - leadWidth,
        m.actualBoundingBoxLeft + leadWidth,
        m.actualBoundingBoxRight - leadWidth,
        m.actualBoundingBoxAscent,
        m.actualBoundingBoxDescent,
      ]);
    }
    // Pass two: which code points seed the last resort. The witness is any
    // code point that just proved its advance moves behind the leader, so
    // asking "does putting c in front of the witness cost the witness its
    // glyph" measures the property directly instead of inferring it.
    witness = behind.findIndex((b, i) => Math.abs(b[0] - glyphs[i][0]) > 1e-6);
    if (witness >= 0) {
      const mark = chr(witness + ${FIRST});
      const markAlone = glyphs[witness][0];
      seeds = [];
      for (let c = ${FIRST}; c <= ${LAST}; c++) {
        const own = ctx.measureText(chr(c)).width;
        const pair = ctx.measureText(chr(c) + mark).width;
        seeds.push(Math.abs(pair - own - markAlone) > 1e-6);
      }
    }
  }

  const ascents = [], descents = [];
  for (let size = 1; size <= ${SWEPT_SIZES}; size++) {
    ctx.font = size + 'px ${quoted}';
    const m = ctx.measureText('');
    ascents.push(m.fontBoundingBoxAscent);
    descents.push(m.fontBoundingBoxDescent);
  }
  // The ascent and descent LAYOUT uses, which are not the two the canvas
  // reports. They are the same numbers at devicePixelRatio 1 -- and every other
  // table on this page is the same at 1 and 2, 182 faces byte for byte -- but at
  // the 2 this engine claims they part company: 16px serif lays out on 14.5 and
  // 4 where the canvas says 14 and 4, and 10px serif on 9 and 2.5 where the
  // canvas says 10 and 3. Both halves move, in half pixels, and neither is
  // derivable from the canvas pair.
  //
  // The whole box is the height of a one-line block, and the split is where its
  // baseline sits: a zero-height \`display:inline-block\` puts its bottom edge on
  // the baseline, so the distance from the block's top to that edge is the
  // ascent and the rest is the descent. The mark costs nothing -- a box 0 tall
  // cannot raise the line -- and that is checked here rather than assumed, by
  // measuring a plain block beside the marked one at every size.
  //
  // An SVG <text> would show the split in one reading, and it is the wrong
  // reading: getBBox is the union of the font box and the INK, so Arial at 16px
  // answers a descent of 3.3671875, which is the tail of the 'g' and not a font
  // metric.
  //
  // getBoundingClientRect and not offsetHeight: the half pixel is real and
  // offsetHeight rounds it away (19 for a box that is 18.5 tall).
  const marked = document.createElement('div');
  marked.style.cssText = 'position:absolute;left:0;top:0;width:1000px;line-height:normal;font-family:${quoted}';
  marked.innerHTML = '<span data-b style="display:inline-block;width:0;height:0"></span>Hxg';
  document.body.appendChild(marked);
  const strut = document.createElement('div');
  strut.style.cssText = 'position:absolute;left:0;top:0;width:1000px;line-height:normal;font-family:${quoted}';
  strut.textContent = 'Hxg';
  document.body.appendChild(strut);
  const mark = marked.querySelector('[data-b]');
  // The third box, and the last one: what an SVG <text> stands on. It is the
  // line box less the font's leading, so for a face with no line gap the two are
  // the same and for one with a gap they are not -- Arial at 16px lays a line
  // out 18 tall and draws its <text> box 17.
  //
  // Read with a NO-BREAK SPACE, because getBBox is the union of the font box and
  // the glyph INK and U+00A0 is the one character with an advance and no ink at
  // all. 'Hxg' in Arial answers a descent of 3.3671875, which is the tail of the
  // 'g'; a full stop is clean for 181 of the 182 faces and not for Webdings,
  // whose '.' is a symbol that reaches 3.203125 past a descent of 3. A plain
  // space is not usable -- it collapses, and getBBox comes back empty.
  const svgNs = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(svgNs, 'svg');
  svg.setAttribute('width', '900');
  svg.setAttribute('height', '600');
  const svgText = document.createElementNS(svgNs, 'text');
  svgText.setAttribute('x', '10');
  svgText.setAttribute('y', '400');
  svgText.style.fontFamily = '${quoted}';
  svgText.textContent = '\\u00A0';
  svg.appendChild(svgText);
  document.body.appendChild(svg);
  const layoutAscents = [], layoutDescents = [], svgAscents = [], svgDescents = [], lineBoxMismatch = [];
  for (let size = 1; size <= ${SWEPT_SIZES}; size++) {
    marked.style.fontSize = size + 'px';
    strut.style.fontSize = size + 'px';
    svgText.style.fontSize = size + 'px';
    const line = strut.getBoundingClientRect().height;
    const markedBox = marked.getBoundingClientRect();
    const ascent = mark.getBoundingClientRect().bottom - markedBox.top;
    layoutAscents.push(ascent);
    layoutDescents.push(line - ascent);
    const b = svgText.getBBox();
    svgAscents.push(400 - b.y);
    svgDescents.push(b.y + b.height - 400);
    if (markedBox.height !== line) lineBoxMismatch.push([size, markedBox.height, line]);
  }
  svg.remove();
  strut.remove();
  marked.remove();
  // The two constants a text control's box is built from. Chrome sizes an
  // <input> as \`size * avgCharWidth + (maxCharWidth - avgCharWidth)\`, so two
  // inputs of different \`size\` at the same font size solve for both: the slope
  // over \`size\` is avgCharWidth and the remainder is maxCharWidth. Read off
  // the offset box less the UA's constant 8px of padding and border, because
  // the computed width follows the page's own box-sizing.
  const charBox = (n) => {
    const el = document.createElement('input');
    el.setAttribute('size', String(n));
    el.style.cssText = 'font-size:100px;font-family:${quoted}';
    document.body.appendChild(el);
    const w = el.offsetWidth - 8;
    el.remove();
    return w;
  };
  const cw10 = charBox(10), cw20 = charBox(20);
  const avgCharWidth = (cw20 - cw10) / 10;
  const maxCharWidth = cw10 - 10 * avgCharWidth + avgCharWidth;
  return JSON.stringify({ family: ${JSON.stringify(family)}, resolved, glyphs, probed, ascents, descents, layoutAscents, layoutDescents, svgAscents, svgDescents, lineBoxMismatch, avgCharWidth, maxCharWidth, dpr: devicePixelRatio, leader, witness, behind, seeds });
})()`;

// A CSS family name needs quoting unless it is a keyword. Quoting a keyword
// turns it into a family name Chrome will not resolve, which would silently
// answer "absent" for every generic.
const KEYWORDS = new Set([...GENERICS, 'cursive', 'fantasy', 'system-ui', 'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded', '-apple-system']);
const quote = (family) => (KEYWORDS.has(family) ? family : `\\"${family}\\"`);

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'dump-fonts-'));
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check'];
if (!headed) flags.push('--headless=new');
// The device scale is part of what is being measured, so it is pinned here
// rather than left to whichever display the run happens to land on. Two is what
// this engine's persona claims (Viewport.default, and window.devicePixelRatio
// with it), and a headed Chrome with no switch answers whatever monitor it
// opened on -- which is how a reading gets attributed to "headed" when it was
// really the scale. Everything else this file writes is identical at 1 and 2,
// verified by regenerating at both; `line_boxes_*` is not, so a run at the
// wrong scale would rewrite that one table and nothing else.
if (!chromeArgs.some((a) => a.startsWith('--force-device-scale-factor'))) {
    flags.push('--force-device-scale-factor=2');
}
flags.push(...chromeArgs);
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;
// No pipe we do not read -- see dump-graphics.mjs.
const proc = ENDPOINT ? null : spawn(CHROME, flags, { stdio: 'ignore' });

let tables = [];
try {
    for (let i = 0; i < 100; i++) {
        try {
            if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) break;
        } catch {}
        await sleep(100);
    }
    const cdp = await Cdp.connect(ENDPOINT ?? `http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // Deduped: a name in EXTRA_NAMES that also turns up as an installed family
    // would otherwise be measured twice and land in the table twice, once as a
    // face and once as an alias of itself.
    const candidates = [...new Set([...GENERICS, ...EXTRA_NAMES, ...(await installedFamilies())])];
    process.stderr.write(`${candidates.length} candidate families\n`);
    for (const family of candidates) {
        const r = await cdp.send(
            'Runtime.evaluate',
            { expression: measure(family, quote(family)), returnByValue: true },
            sessionId,
        );
        if (r.exceptionDetails) {
            process.stderr.write(`  skip ${family}: ${r.exceptionDetails.text}\n`);
            continue;
        }
        const table = JSON.parse(r.result.value);
        // The scale the line boxes were measured at, read back off the page
        // rather than assumed from the switch. A `--force-device-scale-factor`
        // Chrome declined to honour would rewrite `line_boxes_*` alone and
        // leave every other table byte-identical, which is exactly the shape of
        // a regression nobody notices.
        if (table.dpr !== 2) {
            throw new Error(`devicePixelRatio is ${table.dpr}, not 2 — the layout box would be measured at the wrong scale`);
        }
        // The baseline mark is supposed to be free. A size where the marked
        // block is taller than the plain one means it was not, and the split
        // taken there is a split of the wrong box.
        if (table.lineBoxMismatch.length) {
            throw new Error(
                `${family}: the baseline mark changed the line box at ${table.lineBoxMismatch.length} sizes, ` +
                    `first ${JSON.stringify(table.lineBoxMismatch[0])}`,
            );
        }
        tables.push(table);
    }
    cdp.close();
} finally {
    if (proc) proc.kill('SIGKILL');
    await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
}

const serif = tables.find((t) => t.family === 'serif');
const mono = tables.find((t) => t.family === 'monospace');
if (!serif || !mono) throw new Error('serif/monospace never measured; refusing to write a table without them');
if (!tables.find((t) => t.family === 'sans-serif')) throw new Error('sans-serif never measured');
// A face is identified by everything a probe can read off it, not just the
// advances: two families can share a Latin subset and still report different
// fontBoundingBox sweeps, and that difference is measurable.
// Deliberately the whole range, unlike `widths` below: two families that share
// a Latin subset can still differ over Latin-1, and a probe that measures there
// reads two faces rather than one. Aliasing is about what a name reports, not
// about whether it is installed, so widening this cannot move the font list.
const key = (t) => JSON.stringify([t.glyphs, t.ascents, t.descents, t.behind, t.seeds]);
// Installed iff listing the name ahead of a generic moves that generic's own
// measurement, for at least one of the three.
const sans = tables.find((t) => t.family === 'sans-serif');
//
// Widths only, not ink boxes. A font with no Latin coverage -- Arial Hebrew, and
// most of the CJK and Indic families -- makes Chrome fall back per glyph, so
// Latin text measures exactly as wide as the base while the reported ink box can
// still differ. A probe reads the width, so the width is the test: comparing ink
// boxes as well made the engine detect one font (Arial Hebrew) that the real
// Chrome does not, on the same 65-name list.
// ASCII only, per the note on FIRST/LAST: this is the comparison that decides
// membership of the font list, and it was settled on that range.
const widths = (glyphs) => JSON.stringify(glyphs.slice(0, ASCII_COUNT).map((g) => g[0]));
const baseWidths = {
    monospace: widths(mono.glyphs),
    'sans-serif': widths(sans.glyphs),
    serif: widths(serif.glyphs),
};
const resolves = (t) =>
    Object.keys(baseWidths).some((base) => widths(t.probed[base]) !== baseWidths[base]);

// Chrome falls back *per glyph*, and this engine picks one family for the whole
// string, so a family that covers only part of the tabulated range cannot be
// reproduced -- measured, not assumed: '100px "Arial Hebrew"' answers serif's
// width for 'm' and its own for '$', and '"Arial Hebrew", monospace' answers
// monospace's 'm' and the same '$'. 58 of the 95 characters move with the base.
//
// A family whose measurement does not depend on what follows it in the list has
// full coverage, and is the only kind this model can serve: keeping a partial one
// makes the engine detect a font the real Chrome does not (that was Arial Hebrew,
// the single disagreement on the 65-name fingerprintjs list).
const fullCoverage = (t) => {
    const alone = widths(t.glyphs);
    return Object.keys(baseWidths).every((base) => widths(t.probed[base]) === alone);
};

// The two sparse tables the run rule needs, both read straight off the
// measurement rather than classified by hand.
//
//   after_fallback -- code points some fallback font draws, whose advance
//                     therefore moves once the run is on the last resort.
//   seeds          -- code points no font draws, which is what puts a run
//                     there in the first place.
const afterFallbackOf = (t) => {
    if (!t.behind) return [];
    const out = [];
    for (let i = 0; i < t.glyphs.length; i++) {
        if (Math.abs(t.behind[i][0] - t.glyphs[i][0]) < 1e-9) continue;
        const [advance, left, right, ascent, descent] = t.behind[i];
        // Ink and bearings only mean anything if there is ink; the last resort
        // draws nothing, and every family measured so far reports exactly that.
        const inked = ascent !== 0 || descent !== 0;
        out.push([i + FIRST, advance, inked ? left : 0, inked ? right : 0, ascent, descent]);
    }
    return out;
};
const seedsOf = (t) => (t.seeds ? t.seeds.map((s, i) => (s ? i + FIRST : -1)).filter((c) => c >= 0) : []);

// Two families that resolve to the same face are one reading to a probe, but
// both names have to answer, so the duplicates become aliases of the first.
const kept = [];
const aliases = [];
const unresolved = [];
const partial = [];
const byFace = new Map();
for (const t of tables) {
    if (GENERICS.includes(t.family)) {
        kept.push(t);
        byFace.set(key(t), t.family);
        continue;
    }
    if (!resolves(t)) {
        // Chrome did not resolve it: leave it unmeasured, so a probe reads it as
        // not installed -- which is what it is.
        unresolved.push(t.family);
        continue;
    }
    if (!fullCoverage(t)) {
        partial.push(t.family);
        continue;
    }
    const seen = byFace.get(key(t));
    if (seen) {
        aliases.push([t.family, seen]);
        continue;
    }
    byFace.set(key(t), t.family);
    kept.push(t);
}

process.stderr.write(
    `${tables.length} measured -> ${kept.length} distinct faces, ${aliases.length} aliases, ` +
        `${tables.length - kept.length - aliases.length} unresolved\n`,
);
// The run rule, per generic, so a run that finds no fallback at all says so
// rather than quietly emitting empty tables.
const fallbackSummary = (t) =>
    `${t.family}: leader ${t.leader < 0 ? 'none' : `U+${t.leader.toString(16).toUpperCase().padStart(4, '0')}`}` +
    `, ${seedsOf(t).length} seed the last resort, ${afterFallbackOf(t).length} move behind it`;
for (const generic of GENERICS) {
    const t = tables.find((x) => x.family === generic);
    if (t) process.stderr.write(`  ${fallbackSummary(t)}\n`);
}

if (surveyOnly) {
    await fs.writeFile(
        jsonPath,
        JSON.stringify(
            {
                kept: kept.map((t) => t.family),
                aliases,
                unresolved,
                partial,
                fallback: tables.filter((t) => GENERICS.includes(t.family)).map(fallbackSummary),
            },
            null,
            1,
        ),
    );
    process.stderr.write(`wrote ${path.relative(repo, jsonPath)}\n`);
    process.exit(0);
}

// ---------------------------------------------------------------------------
// Emit the Zig.

const ident = (family) =>
    'glyphs_' +
    family
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '_')
        .replace(/^_|_$/g, '');
const num = (v) => {
    // Zig wants a decimal point on a float literal, and the values are exact
    // binary fractions -- JS prints them round-trippably, so no rounding here.
    const s = String(v);
    return s.includes('.') || s.includes('e') ? s : `${s}.0`;
};
// Only printable ASCII names itself in a comment. A C1 control written out
// would put a raw control byte in the source, and a Latin-1 letter would make
// the file's encoding load-bearing, so both are spelled as code points.
// Ten to a line, floats through `num` and code points as plain integers.
const inRows = (vals, render) => {
    const out = [];
    for (let i = 0; i < vals.length; i += 10) out.push('    ' + vals.slice(i, i + 10).map(render).join(', ') + ',');
    return out.join('\n');
};
const intRows = (vals) => inRows(vals, String);

const CHAR_NAMES = { 32: 'space', 127: 'U+007F' };
const label = (c) =>
    CHAR_NAMES[c] ?? (c > 32 && c < 127 ? String.fromCharCode(c) : `U+${c.toString(16).toUpperCase().padStart(4, '0')}`);


const parts = [];
parts.push(`// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// GENERATED by tools/fingerprint/dump-fonts.mjs — do not hand-edit.
//
// Measured from ${serif.userAgent ?? 'the reference host\'s Google Chrome'} on macOS,
// which is the platform src/claimed_platform.zig claims.
//
// ${kept.length} distinct faces and ${aliases.length} aliases, out of ${tables.length} names
// measured. ${unresolved.length} did not resolve at all, and ${partial.length} cover only part of
// U+0020..U+007E — Chrome falls back per glyph for those and this engine cannot,
// so keeping them would make it detect fonts the real Chrome does not. Both
// groups are deliberately absent: font enumeration is the comparison a probe makes between
// '"Candidate", monospace' and 'monospace', so a name with no table of its own
// measures identically to its base and reads as not installed — which is what it
// is. That makes this file the engine's font list, and its size the number a
// detector reports.
//
// Two facts from the measurement make one table enough per family:
//
//   * advances are exactly linear in font size ('m' is 8.330078125 at 10px
//     and 83.30078125 at 100px), so a 100px table scales;
//   * a string's width is the plain sum of its glyphs' advances, except
//     across a kerning pair. 'mmmmmmmmmmlli', 'Hello, world!' and
//     'Cwm fjordbank glyphs vext quiz' all sum exactly; 'AV' and 'To' do
//     not, and we do not model kerning, so those come out a little wide.
//
// fontBoundingBox is the exception: CoreText quantises it per size (16px
// sans-serif reports an ascent of 14 where scaling 100px's 92 would say 15),
// so it is stored as a swept table for 1..${SWEPT_SIZES}px and extrapolated above that.
//
// U+0020..U+00FF is tabulated. Anything above that falls back to the family's
// mean ASCII advance, which is a guess and marked as one at the call site.
//
// Latin-1 is here because the Turnstile widget measures it: it hands
// measureText the UTF-8 bytes of an emoji read back as Latin-1, so U+00F0
// U+009F U+0098 U+0080 rather than U+1F600. Which is also why the C1 controls
// are tabulated, and why they need the run rule \`after_fallback\` and
// \`seeds_last_resort\` carry — see the comment on those fields.
//
// Membership of this table is still decided on U+0020..U+007E alone. The font
// list is what a probe enumerates, it was settled against the 65-name
// fingerprintjs list on the ASCII range, and widening the comparison would
// silently move it: ASCII decides who is in, the whole range is what they
// report.

const std = @import("std");

/// One glyph, at a 100px font size. \`left\` and \`right\` are the ink bearings
/// TextMetrics reports as actualBoundingBoxLeft / Right: positive \`left\`
/// means the ink starts to the *left* of the pen, matching the web API's sign.
pub const Glyph = struct {
    advance: f64,
    left: f64,
    right: f64,
    ascent: f64,
    descent: f64,
};

/// What a code point costs once the run has fallen back to the last resort
/// font, for the code points where that differs from what it costs alone.
pub const Override = struct {
    codepoint: u21,
    glyph: Glyph,
};

pub const first_codepoint = ${FIRST};
pub const last_codepoint = ${LAST};
/// The end of the ASCII prefix: the range membership of this table is decided
/// on, and the range \`meanAdvance\` averages over.
pub const last_ascii_codepoint = ${ASCII_LAST};
/// The size every table below is measured at.
pub const basis = 100.0;

/// The swept range of \`ascents_*\` / \`descents_*\` / \`line_boxes_*\`. Larger
/// sizes scale from the last entry, which is close but not exact — CoreText's
/// quantisation is not a ratio.
pub const swept_sizes = ${SWEPT_SIZES};

/// The device pixel ratio every \`layout_ascents_*\` / \`layout_descents_*\` below
/// was measured at, which is the one this engine's persona claims. Nothing else
/// in this file depends on it: regenerating the whole table at scale 1 and at
/// scale 2 produced two byte-identical files apart from those arrays.
pub const layout_device_pixel_ratio = 2.0;

pub const Family = struct {
    glyphs: []const Glyph,
    ascents: []const f64,
    descents: []const f64,
    /// The ascent and descent LAYOUT stands text on, per size, which are not
    /// \`ascents\` and \`descents\` — those are what the canvas reports. The two
    /// pairs are the same numbers at device pixel ratio 1 and different at the 2
    /// this engine claims: 16px serif lays out on 14.5 and 4 where the canvas
    /// says 14 and 4, and 10px serif on 9 and 2.5 where the canvas says 10 and
    /// 3. Both halves move, in half pixels, and neither is derivable from the
    /// canvas pair — so they are measured, off an SVG \`<text>\`, which is the
    /// one box that shows the split rather than the sum.
    ///
    /// Their sum is the \`line-height: normal\` line box, checked against a
    /// laid-out block at every size of every family while measuring.
    layout_ascents: []const f64,
    layout_descents: []const f64,
    /// The ascent and descent an SVG \`<text>\` stands on, which is the layout
    /// pair less the face's leading: a face with no line gap answers the same
    /// two numbers, and Arial at 16px lays a line out 18 tall while drawing its
    /// \`<text>\` box 17. Chrome unions this with the glyph ink, which we do not
    /// model — measured with a full stop precisely so the ink is not in the way.
    svg_ascents: []const f64,
    svg_descents: []const f64,
    /// Blink chooses one fallback font per run, seeded by the first character
    /// the primary font cannot draw, and keeps it for the whole run. These two
    /// fields are what that costs, both measured rather than reasoned about.
    ///
    /// A character no font on the host draws at all lands on the last resort
    /// font — those are \`seeds_last_resort\` — and the last resort then covers
    /// every later fallback-drawn character in the run at a flat em apiece,
    /// with no ink. \`after_fallback\` is what those characters cost there,
    /// listed only where it differs from what they cost alone.
    ///
    /// At 16px sans-serif that makes U+0098 U+0080 32 where U+0080 alone is
    /// 8.898 — and it is why three of the ten strings the Turnstile widget
    /// measures come out wider than the sum of their code points.
    /// The two font constants an \`<input>\`'s box is built from, at the 100px
    /// basis: OS/2's \`xAvgCharWidth\` and hhea's \`advanceWidthMax\`. Chrome sizes
    /// a text control as \`size * avgCharWidth + (maxCharWidth - avgCharWidth)\`,
    /// so neither is derivable from \`glyphs\` -- Arial's mean ASCII advance is
    /// 52.695 and the widest ASCII glyph 101.514, against the 50 and 91 Chrome
    /// builds the box from.
    avg_char_width: f64,
    max_char_width: f64,
    seeds_last_resort: []const u21,
    after_fallback: []const Override,
};
`);

const names = new Map();
for (const t of kept) {
    let base = ident(t.family);
    let name = base;
    for (let n = 2; names.has(name); n++) name = `${base}_${n}`;
    names.set(name, t);
    parts.push(`
/// 100px ${t.family} — Chrome resolves it to \`${t.resolved}\`.
const ${name} = [_]Glyph{`);
    t.glyphs.forEach(([advance, left, right, ascent, descent], i) => {
        parts.push(
            // Stored verbatim: actualBoundingBoxLeft already arrives negative
            // when the ink starts right of the pen, and the table keeps the web
            // API's sign so text_measure does no conversion.
            `    .{ .advance = ${num(advance)}, .left = ${num(left)}, .right = ${num(right)}, ` +
                `.ascent = ${num(ascent)}, .descent = ${num(descent)} }, // ${label(i + 32)}`,
        );
    });
    parts.push('};');
    const rows = (vals) => inRows(vals, num);
    const bare = name.replace(/^glyphs_/, '');
    parts.push(`const ascents_${bare} = [_]f64{
${rows(t.ascents)}
};
const descents_${bare} = [_]f64{
${rows(t.descents)}
};
const layout_ascents_${bare} = [_]f64{
${rows(t.layoutAscents)}
};
const layout_descents_${bare} = [_]f64{
${rows(t.layoutDescents)}
};
const svg_ascents_${bare} = [_]f64{
${rows(t.svgAscents)}
};
const svg_descents_${bare} = [_]f64{
${rows(t.svgDescents)}
};`);
    const seeds = seedsOf(t);
    parts.push(
        `const seeds_${bare} = [_]u21{${seeds.length ? '\n' + intRows(seeds) + '\n' : ''}};`,
    );
    const overrides = afterFallbackOf(t);
    parts.push(`const after_${bare} = [_]Override{`);
    for (const [codepoint, advance, left, right, ascent, descent] of overrides) {
        parts.push(
            `    .{ .codepoint = ${codepoint}, .glyph = .{ .advance = ${num(advance)}, .left = ${num(left)}, ` +
                `.right = ${num(right)}, .ascent = ${num(ascent)}, .descent = ${num(descent)} } }, // ${label(codepoint)}`,
        );
    }
    parts.push('};');
}

parts.push('');
for (const [name, t] of names) {
    const bare = name.replace(/^glyphs_/, '');
    parts.push(
        `pub const ${bare}: Family = .{ .glyphs = &${name}, .ascents = &ascents_${bare}, ` +
            `.descents = &descents_${bare}, .layout_ascents = &layout_ascents_${bare}, ` +
            `.layout_descents = &layout_descents_${bare}, .svg_ascents = &svg_ascents_${bare}, ` +
            `.svg_descents = &svg_descents_${bare}, ` +
            `.avg_char_width = ${num(t.avgCharWidth)}, ` +
            `.max_char_width = ${num(t.maxCharWidth)}, ` +
            `.seeds_last_resort = &seeds_${bare}, .after_fallback = &after_${bare} };`,
    );
}

parts.push(`
/// Chrome falls back to the standard font for a family it cannot resolve:
/// '100px NoSuchFamily12345' measures exactly like '100px serif'.
pub const fallback = serif;

/// Maps a CSS family name to one of the measured families, ASCII
/// case-insensitively. Null when we have no table for it, which the caller
/// resolves by moving on to the next name in the list.
pub fn find(name: []const u8) ?Family {
    const table = [_]struct { []const u8, Family }{`);
for (const [name, t] of names) {
    parts.push(`        .{ "${t.family}", ${name.replace(/^glyphs_/, '')} },`);
}
if (aliases.length) {
    parts.push('        // Names Chrome resolves to a face already listed above.');
    for (const [alias, target] of aliases) {
        const bare = [...names].find(([, t]) => t.family === target)?.[0].replace(/^glyphs_/, '');
        parts.push(`        .{ "${alias}", ${bare} },`);
    }
}
parts.push(`    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) {
            return entry[1];
        }
    }
    return null;
}

/// The table for the first name in a comma-separated CSS family list we have
/// measurements for, falling back the way Chrome does when none resolves.
///
/// This is the whole of font enumeration. A probe asks for \`"Some Font",
/// monospace\` and compares the result against \`monospace\` alone: skipping the
/// names we have no table for is what makes a font we do have measure
/// differently, and a font we do not measure identically to its base.
pub fn findInList(list: []const u8) Family {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const unquoted = if (name.len >= 2 and (name[0] == '"' or name[0] == '\\'') and name[name.len - 1] == name[0])
            name[1 .. name.len - 1]
        else
            name;
        if (find(unquoted)) |family| {
            return family;
        }
    }
    return fallback;
}

/// The glyph for a codepoint at the table's 100px basis. Above U+00FF we have
/// no measurement, so this returns null and the caller charges the family's
/// mean ASCII advance instead.
pub fn glyph(family: Family, codepoint: u21) ?Glyph {
    if (codepoint < first_codepoint or codepoint > last_codepoint) {
        return null;
    }
    return family.glyphs[codepoint - first_codepoint];
}

/// Whether this codepoint is one no font on the host draws, which is what puts
/// a run on the last resort font for the rest of its length.
pub fn seedsLastResort(family: Family, codepoint: u21) bool {
    for (family.seeds_last_resort) |seed| {
        if (seed == codepoint) return true;
    }
    return false;
}

/// What this codepoint costs once the run is on the last resort font, for the
/// codepoints where that is not what it costs alone. Null means the codepoint
/// does not care what came before it.
pub fn afterFallback(family: Family, codepoint: u21) ?Glyph {
    for (family.after_fallback) |entry| {
        if (entry.codepoint == codepoint) return entry.glyph;
    }
    return null;
}

/// \`fontBoundingBoxAscent\` / \`Descent\` at a size, from the swept table where
/// there is one and scaled from its last entry above that.
pub fn boundingBox(family: Family, size: f64) struct { ascent: f64, descent: f64 } {
    const rounded = @round(size);
    if (rounded >= 1 and rounded <= @as(f64, @floatFromInt(family.ascents.len)) and rounded == size) {
        const index: usize = @intFromFloat(rounded - 1);
        return .{ .ascent = family.ascents[index], .descent = family.descents[index] };
    }
    const last: f64 = @floatFromInt(family.ascents.len);
    const scale = size / last;
    return .{
        .ascent = family.ascents[family.ascents.len - 1] * scale,
        .descent = family.descents[family.descents.len - 1] * scale,
    };
}

/// The ascent and descent LAYOUT stands this family's text on at this size, from
/// the swept table where there is one and scaled from its last entry above that.
/// See \`Family.layout_ascents\`: this is a separate measurement from
/// \`boundingBox\`, because at the device pixel ratio this engine claims the two
/// pairs disagree for most sizes.
pub fn layoutBox(family: Family, size: f64) struct { ascent: f64, descent: f64 } {
    const rounded = @round(size);
    if (rounded >= 1 and rounded <= @as(f64, @floatFromInt(family.layout_ascents.len)) and rounded == size) {
        const index: usize = @intFromFloat(rounded - 1);
        return .{ .ascent = family.layout_ascents[index], .descent = family.layout_descents[index] };
    }
    // Multiplied before it is divided, the way text_measure carries the pen:
    // scaling by \`size / last\` first costs an ulp, and the ulp is visible --
    // a 200px sans-serif SVG box comes out 230.00000000000003 that way and
    // exactly 230 this way, against Chrome's 230.
    const last: f64 = @floatFromInt(family.layout_ascents.len);
    return .{
        .ascent = family.layout_ascents[family.layout_ascents.len - 1] * size / last,
        .descent = family.layout_descents[family.layout_descents.len - 1] * size / last,
    };
}

/// The height of one \`line-height: normal\` line: the layout box, top to bottom.
pub fn lineBox(family: Family, size: f64) f64 {
    const box = layoutBox(family, size);
    return box.ascent + box.descent;
}

/// The ascent and descent an SVG \`<text>\` stands on. See \`Family.svg_ascents\`:
/// the layout box less the face's leading, and a third measurement again from
/// \`boundingBox\`.
pub fn svgBox(family: Family, size: f64) struct { ascent: f64, descent: f64 } {
    const rounded = @round(size);
    if (rounded >= 1 and rounded <= @as(f64, @floatFromInt(family.svg_ascents.len)) and rounded == size) {
        const index: usize = @intFromFloat(rounded - 1);
        return .{ .ascent = family.svg_ascents[index], .descent = family.svg_descents[index] };
    }
    const last: f64 = @floatFromInt(family.svg_ascents.len);
    return .{
        .ascent = family.svg_ascents[family.svg_ascents.len - 1] * size / last,
        .descent = family.svg_descents[family.svg_descents.len - 1] * size / last,
    };
}`);

await fs.writeFile(outPath, parts.join('\n') + '\n');
// `zig build` depends on a fmt check, so an unformatted table fails the build
// rather than the review. Emitting the columns pre-aligned is not something a
// template can do — zig fmt aligns the numeric rows itself — so run it.
await new Promise((resolve, reject) => {
    const p = spawn('zig', ['fmt', outPath], { stdio: ['ignore', 'ignore', 'inherit'] });
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`zig fmt exited ${code}`))));
});
await fs.writeFile(
    jsonPath,
    JSON.stringify(
        {
            note: 'Survey of what dump-fonts.mjs kept. The metrics themselves live in the generated Zig.',
            kept: kept.map((t) => ({ family: t.family, resolved: t.resolved })),
            aliases,
            unresolved,
            partial,
        },
        null,
        1,
    ),
);
process.stderr.write(`wrote ${path.relative(repo, outPath)} — ${kept.length} faces, ${aliases.length} aliases\n`);
process.exit(0);
