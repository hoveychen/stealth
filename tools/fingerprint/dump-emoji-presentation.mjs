// What headed Chrome on macOS lays out for a single emoji-capable codepoint in
// each of its two presentations, and writes it as src/browser/emoji_presentation.zig.
//
// usage: node tools/fingerprint/dump-emoji-presentation.mjs [--zig] [--headed]
//
// Why this table exists separately from emoji_metrics.zig: that one answers
// "how wide is this cluster in colour", measured under `sans-serif`, and it
// says nothing about the TEXT presentation or about the line box either
// presentation opens. Kasada measures both. It builds
// `<input type=button value="<cp><VS>" style="font-size:100px">` for five
// codepoints, twice each -- once with U+FE0E and once with U+FE0F -- and reads
// clientWidth x clientHeight, so a run that answers one advance and one line
// height for all ten is one expression away from being told apart from Chrome.
//
// Three numbers per codepoint in the text presentation: the advance, and the
// line box split at the baseline. The split is what the height needs -- a
// codepoint Arial cannot draw falls back to some other font, and the line box
// the run opens is that font's, not Arial's. The colour presentation is one
// constant for every codepoint (Apple Color Emoji), so it is not tabulated.
//
// Measured under `font: 100px Arial`, which is the family Kasada's button
// computes to. emoji_metrics.zig makes the opposite choice for its own reason;
// the two tables are not interchangeable.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

// Every single-codepoint base emoji_metrics.zig carries, plus U+203C and
// U+26AA -- the two of Kasada's five that table never had -- and U+1F600 as
// the colour-presentation control.
const BASES = [
  0x00a9, 0x00ae, 0x203c, 0x2049, 0x2122, 0x2139, 0x2197, 0x21aa, 0x2328,
  0x23cf, 0x23ed, 0x23ef, 0x23f1, 0x25aa, 0x25b6, 0x25fc, 0x2602, 0x2603,
  0x2604, 0x2611, 0x2618, 0x261d, 0x2620, 0x2622, 0x2623, 0x2626, 0x262a,
  0x262e, 0x262f, 0x2638, 0x2639, 0x263a, 0x2640, 0x2642, 0x265f, 0x2668,
  0x2692, 0x2694, 0x2695, 0x2696, 0x2697, 0x2699, 0x269b, 0x269c, 0x26a0,
  0x26a7, 0x26aa, 0x26b0, 0x26b1, 0x26c8, 0x26cf, 0x26d1, 0x26d3, 0x26e9,
  0x26f0, 0x26f1, 0x26f4, 0x26f7, 0x26f8, 0x2702, 0x2708, 0x2709, 0x270c,
  0x270d, 0x270f, 0x2712, 0x2714, 0x2716, 0x271d, 0x2721, 0x2733, 0x2734,
  0x2744, 0x2747, 0x2763, 0x2764, 0x27a1, 0x2b05, 0x2b06, 0x3030, 0x1f600,
];

const probe = `(async () => {
  const BASES = ${JSON.stringify(BASES)};
  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;top:0;left:0;font:100px Arial;white-space:pre';
  document.body.appendChild(host);
  // The baseline is read off a zero-sized inline-block sitting on it, which is
  // the only handle a page has on where the baseline of a line box landed.
  const measure = (text) => {
    const ib = document.createElement('div');
    ib.style.cssText = 'display:inline-block;font:100px Arial;white-space:pre';
    const anchor = document.createElement('span');
    anchor.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
    ib.appendChild(anchor);
    ib.appendChild(document.createTextNode(text));
    host.appendChild(ib);
    const box = ib.getBoundingClientRect();
    const base = anchor.getBoundingClientRect();
    const r = document.createRange();
    r.setStart(ib, 1);
    r.setEnd(ib, 2);
    const advance = r.getBoundingClientRect().width;
    const res = { advance, above: base.bottom - box.top, below: box.bottom - base.bottom };
    ib.remove();
    return res;
  };
  const out = { ref: measure('x'), rows: [] };
  for (const cp of BASES) {
    const c = String.fromCodePoint(cp);
    out.rows.push({
      cp,
      text: measure(c + '\\ufe0e'),
      emoji: measure(c + '\\ufe0f'),
      bare: measure(c),
    });
  }
  host.remove();
  return out;
})()`;

const server = http.createServer((_, res) => {
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end('<!DOCTYPE html><html><body><p>emoji</p></body></html>');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const exprPath = path.join(os.tmpdir(), `emoji-presentation-${process.pid}.js`);
await fs.writeFile(exprPath, probe);
const args = ['tools/fingerprint/run-expr.mjs', 'chrome', exprPath, '--url', url];
if (process.argv.includes('--headed')) args.push('--headed');
const child = spawn(process.execPath, args, { cwd: REPO, stdio: ['ignore', 'pipe', 'inherit'] });
let stdout = '';
for await (const chunk of child.stdout) stdout += chunk;
await new Promise((r) => child.on('close', r));
server.close();
await fs.rm(exprPath, { force: true });

const data = JSON.parse(stdout);
if (!process.argv.includes('--zig')) {
  console.log(JSON.stringify(data, null, 1));
  process.exit(0);
}

// The colour presentation is one font for every codepoint, so it is checked to
// be constant rather than tabulated per codepoint.
const colour = data.rows[0].emoji;
for (const row of data.rows) {
  for (const key of ['advance', 'above', 'below']) {
    if (row.emoji[key] !== colour[key]) {
      throw new Error(`U+${row.cp.toString(16)} colour ${key} is ${row.emoji[key]}, not ${colour[key]}`);
    }
  }
}

const num = (v) => (Number.isInteger(v) ? String(v) : String(v));
const lines = data.rows.map((row) => {
  const bare_is_emoji = row.bare.advance === row.emoji.advance &&
    row.bare.above === row.emoji.above && row.bare.below === row.emoji.below;
  return `    .{ .codepoint = 0x${row.cp.toString(16)}, .advance = ${num(row.text.advance)}, ` +
    `.above = ${num(row.text.above)}, .below = ${num(row.text.below)}, ` +
    `.bare_is_emoji = ${bare_is_emoji} }, // ${String.fromCodePoint(row.cp)}`;
});

process.stdout.write(`// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// GENERATED -- do not hand-edit. Produced by
//   node tools/fingerprint/dump-emoji-presentation.mjs --headed --zig
//
// What headed Chrome on macOS lays out for one emoji-capable codepoint in each
// of its two presentations. A variation selector picks between them: U+FE0E
// asks for the text glyph, U+FE0F for the colour one, and a bare codepoint
// takes whichever \`bare_is_emoji\` records.
//
// Both halves matter because Kasada reads both. It sizes an
// \`<input type=button>\` at \`font-size: 100px\` around one such codepoint and
// reads clientWidth x clientHeight, twice per codepoint -- once with each
// selector -- so the advance decides the width and the line box decides the
// height. Answering one pair for all ten is the tell.
//
// The colour presentation is Apple Color Emoji for every codepoint, so it is
// the three constants below rather than a column. The text presentation is not:
// Arial draws some of these, and the rest fall back to a font whose line box is
// its own -- which is why \`above\` and \`below\` are tabulated and not derived
// from the requesting family.
//
// Measured under \`font: 100px Arial\`, the family Kasada's button computes to.
// emoji_metrics.zig measures the same characters under \`sans-serif\` for a
// different question; the two tables are not interchangeable.

/// One codepoint's text presentation, in CSS pixels at the 100px basis.
/// \`above\` and \`below\` are the line box split at the baseline.
pub const Glyph = struct {
    codepoint: u21,
    advance: f64,
    above: f64,
    below: f64,
    /// Whether the codepoint with no variation selector renders in colour.
    bare_is_emoji: bool,
};

pub const basis = 100.0;

/// Apple Color Emoji at the basis: the same three numbers for every codepoint
/// in the table, checked by the generator rather than assumed.
pub const colour_advance = ${num(colour.advance)};
pub const colour_above = ${num(colour.above)};
pub const colour_below = ${num(colour.below)};

/// Ordered by codepoint so \`find\` can binary-search.
pub const glyphs = [_]Glyph{
${lines.join('\n')}
};

/// The row for \`codepoint\`, or null for one we have no measurement for.
///
/// Called at most once per cluster of every string the engine measures, behind
/// the same kind of lead-byte gate emoji_metrics.match uses -- see
/// text_measure.zig for why a table walk per character is not affordable.
pub fn find(codepoint: u21) ?Glyph {
    var low: usize = 0;
    var high: usize = glyphs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const row = glyphs[mid];
        if (row.codepoint == codepoint) return row;
        if (row.codepoint < codepoint) low = mid + 1 else high = mid;
    }
    return null;
}

/// The lowest and highest codepoint in the table, so a caller can reject the
/// overwhelming majority of characters with two comparisons.
pub const first_codepoint = glyphs[0].codepoint;
pub const last_codepoint = glyphs[glyphs.len - 1].codepoint;

const std = @import("std");

test "emoji_presentation: the table is sorted and findable" {
    for (glyphs, 0..) |row, i| {
        if (i > 0) try std.testing.expect(glyphs[i - 1].codepoint < row.codepoint);
        try std.testing.expectEqual(row, find(row.codepoint).?);
    }
    try std.testing.expectEqual(@as(?Glyph, null), find('a'));
    try std.testing.expectEqual(@as(?Glyph, null), find(0x2b07));
}
`);
