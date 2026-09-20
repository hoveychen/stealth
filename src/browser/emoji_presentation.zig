// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
// takes whichever `bare_is_emoji` records.
//
// Both halves matter because Kasada reads both. It sizes an
// `<input type=button>` at `font-size: 100px` around one such codepoint and
// reads clientWidth x clientHeight, twice per codepoint -- once with each
// selector -- so the advance decides the width and the line box decides the
// height. Answering one pair for all ten is the tell.
//
// The colour presentation is Apple Color Emoji for every codepoint, so it is
// the three constants below rather than a column. The text presentation is not:
// Arial draws some of these, and the rest fall back to a font whose line box is
// its own -- which is why `above` and `below` are tabulated and not derived
// from the requesting family.
//
// Measured under `font: 100px Arial`, the family Kasada's button computes to.
// emoji_metrics.zig measures the same characters under `sans-serif` for a
// different question; the two tables are not interchangeable.

/// One codepoint's text presentation, in CSS pixels at the 100px basis.
/// `above` and `below` are the line box split at the baseline.
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
pub const colour_advance = 100;
pub const colour_above = 100;
pub const colour_below = 31.5;

/// Ordered by codepoint so `find` can binary-search.
pub const glyphs = [_]Glyph{
    .{ .codepoint = 0xa9, .advance = 73.6875, .above = 92, .below = 23, .bare_is_emoji = false }, // ©
    .{ .codepoint = 0xae, .advance = 73.6875, .above = 92, .below = 23, .bare_is_emoji = false }, // ®
    .{ .codepoint = 0x203c, .advance = 50, .above = 92, .below = 23, .bare_is_emoji = false }, // ‼
    .{ .codepoint = 0x2049, .advance = 83.3984375, .above = 92, .below = 23, .bare_is_emoji = false }, // ⁉
    .{ .codepoint = 0x2122, .advance = 100, .above = 92, .below = 23, .bare_is_emoji = false }, // ™
    .{ .codepoint = 0x2139, .advance = 66.015625, .above = 92, .below = 29.5, .bare_is_emoji = false }, // ℹ
    .{ .codepoint = 0x2197, .advance = 100, .above = 106, .below = 34, .bare_is_emoji = false }, // ↗
    .{ .codepoint = 0x21aa, .advance = 98.78125, .above = 96.5, .below = 23, .bare_is_emoji = false }, // ↪
    .{ .codepoint = 0x2328, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⌨
    .{ .codepoint = 0x23cf, .advance = 85.6953125, .above = 96.5, .below = 23, .bare_is_emoji = false }, // ⏏
    .{ .codepoint = 0x23ed, .advance = 100.3046875, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⏭
    .{ .codepoint = 0x23ef, .advance = 87.1015625, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⏯
    .{ .codepoint = 0x23f1, .advance = 78.1015625, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⏱
    .{ .codepoint = 0x25aa, .advance = 35.453125, .above = 92, .below = 23, .bare_is_emoji = false }, // ▪
    .{ .codepoint = 0x25b6, .advance = 87.9921875, .above = 96.5, .below = 23, .bare_is_emoji = false }, // ▶
    .{ .codepoint = 0x25fc, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ◼
    .{ .codepoint = 0x2602, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ☂
    .{ .codepoint = 0x2603, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ☃
    .{ .codepoint = 0x2604, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☄
    .{ .codepoint = 0x2611, .advance = 83.0078125, .above = 92, .below = 29.5, .bare_is_emoji = false }, // ☑
    .{ .codepoint = 0x2618, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☘
    .{ .codepoint = 0x261d, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = true }, // ☝
    .{ .codepoint = 0x2620, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☠
    .{ .codepoint = 0x2622, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☢
    .{ .codepoint = 0x2623, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☣
    .{ .codepoint = 0x2626, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☦
    .{ .codepoint = 0x262a, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☪
    .{ .codepoint = 0x262e, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☮
    .{ .codepoint = 0x262f, .advance = 86.5, .above = 92, .below = 30, .bare_is_emoji = false }, // ☯
    .{ .codepoint = 0x2638, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ☸
    .{ .codepoint = 0x2639, .advance = 73.6875, .above = 92, .below = 23, .bare_is_emoji = false }, // ☹
    .{ .codepoint = 0x263a, .advance = 102.1015625, .above = 92, .below = 23, .bare_is_emoji = false }, // ☺
    .{ .codepoint = 0x2640, .advance = 75, .above = 92, .below = 23, .bare_is_emoji = false }, // ♀
    .{ .codepoint = 0x2642, .advance = 75, .above = 92, .below = 23, .bare_is_emoji = false }, // ♂
    .{ .codepoint = 0x265f, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ♟
    .{ .codepoint = 0x2668, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ♨
    .{ .codepoint = 0x2692, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚒
    .{ .codepoint = 0x2694, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚔
    .{ .codepoint = 0x2695, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚕
    .{ .codepoint = 0x2696, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚖
    .{ .codepoint = 0x2697, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚗
    .{ .codepoint = 0x2699, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚙
    .{ .codepoint = 0x269b, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚛
    .{ .codepoint = 0x269c, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚜
    .{ .codepoint = 0x26a0, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ⚠
    .{ .codepoint = 0x26a7, .advance = 92.3359375, .above = 92, .below = 29.5, .bare_is_emoji = false }, // ⚧
    .{ .codepoint = 0x26aa, .advance = 68.8515625, .above = 92, .below = 29.5, .bare_is_emoji = true }, // ⚪
    .{ .codepoint = 0x26b0, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚰
    .{ .codepoint = 0x26b1, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ⚱
    .{ .codepoint = 0x26c8, .advance = 78.8046875, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛈
    .{ .codepoint = 0x26cf, .advance = 75.3046875, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛏
    .{ .codepoint = 0x26d1, .advance = 80.3046875, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛑
    .{ .codepoint = 0x26d3, .advance = 74.6015625, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛓
    .{ .codepoint = 0x26e9, .advance = 83.703125, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛩
    .{ .codepoint = 0x26f0, .advance = 92.703125, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛰
    .{ .codepoint = 0x26f1, .advance = 89.90625, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛱
    .{ .codepoint = 0x26f4, .advance = 111.5, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛴
    .{ .codepoint = 0x26f7, .advance = 77.8046875, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛷
    .{ .codepoint = 0x26f8, .advance = 72.90625, .above = 92, .below = 36.5, .bare_is_emoji = false }, // ⛸
    .{ .codepoint = 0x2702, .advance = 96.09375, .above = 92, .below = 23, .bare_is_emoji = false }, // ✂
    .{ .codepoint = 0x2708, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ✈
    .{ .codepoint = 0x2709, .advance = 60.2109375, .above = 93, .below = 23.5, .bare_is_emoji = false }, // ✉
    .{ .codepoint = 0x270c, .advance = 54.8828125, .above = 92, .below = 23, .bare_is_emoji = true }, // ✌
    .{ .codepoint = 0x270d, .advance = 85.5, .above = 92, .below = 23, .bare_is_emoji = true }, // ✍
    .{ .codepoint = 0x270f, .advance = 93.3125, .above = 92, .below = 23, .bare_is_emoji = false }, // ✏
    .{ .codepoint = 0x2712, .advance = 97.4140625, .above = 92, .below = 23, .bare_is_emoji = false }, // ✒
    .{ .codepoint = 0x2714, .advance = 84.625, .above = 92, .below = 23, .bare_is_emoji = false }, // ✔
    .{ .codepoint = 0x2716, .advance = 76.125, .above = 92, .below = 23, .bare_is_emoji = false }, // ✖
    .{ .codepoint = 0x271d, .advance = 49.4140625, .above = 92, .below = 23, .bare_is_emoji = false }, // ✝
    .{ .codepoint = 0x2721, .advance = 69.1953125, .above = 92, .below = 23, .bare_is_emoji = false }, // ✡
    .{ .codepoint = 0x2733, .advance = 74.90625, .above = 92, .below = 23, .bare_is_emoji = false }, // ✳
    .{ .codepoint = 0x2734, .advance = 79.0078125, .above = 92, .below = 23, .bare_is_emoji = false }, // ✴
    .{ .codepoint = 0x2744, .advance = 68.703125, .above = 92, .below = 23, .bare_is_emoji = false }, // ❄
    .{ .codepoint = 0x2747, .advance = 78.6171875, .above = 92, .below = 23, .bare_is_emoji = false }, // ❇
    .{ .codepoint = 0x2763, .advance = 54.3984375, .above = 92, .below = 23, .bare_is_emoji = false }, // ❣
    .{ .codepoint = 0x2764, .advance = 91.015625, .above = 92, .below = 23, .bare_is_emoji = false }, // ❤
    .{ .codepoint = 0x27a1, .advance = 82.8125, .above = 92, .below = 23, .bare_is_emoji = false }, // ➡
    .{ .codepoint = 0x2b05, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ⬅
    .{ .codepoint = 0x2b06, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // ⬆
    .{ .codepoint = 0x3030, .advance = 100, .above = 113, .below = 37, .bare_is_emoji = false }, // 〰
    .{ .codepoint = 0x1f600, .advance = 100, .above = 100, .below = 31.5, .bare_is_emoji = true }, // 😀
};

/// The row for `codepoint`, or null for one we have no measurement for.
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
