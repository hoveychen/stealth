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

const std = @import("std");

const font_metrics = @import("font_metrics.zig");
const emoji_metrics = @import("emoji_metrics.zig");
const emoji_properties = @import("emoji_properties.zig");

// Two measurement paths live here, both reading tables transcribed from
// Chrome: per-glyph advances in font_metrics.zig, per-cluster emoji advances
// in emoji_metrics.zig, and the two Unicode properties that say which of the
// two a character belongs to in emoji_properties.zig.
//
// `measure` is the canvas one: it reproduces what `measureText` answers,
// exactly, for printable ASCII in the families we measured, and from the
// `emoji_sizes` table below for a colour emoji.
//
// `svgWidth` and friends below are the SVG one. It differs in two ways that
// are Chrome's, not ours: SVG text measures whole shaped clusters, so a ZWJ
// emoji sequence has one advance rather than the sum of its parts, and it
// addresses characters by UTF-16 code unit because that is what the DOM
// counts. Both paths walk clusters now; only the price of one differs.
//
// Neither is linear in the font size where a colour emoji is concerned —
// Chrome hands back the bitmap strike it picked — but only the canvas path
// models that. The SVG table was measured at 100px and 200px, where the
// strike is the em box and scaling is off by under a hundredth of a pixel;
// what it answers at 16px has never been measured, and is the em box rather
// than the 1.25 em `measureText` reports.
//
// Neither path shapes scripts or applies kerning; a real shaping backend can
// replace this module without changing SVGTextContentElement.

/// Everything a `TextMetrics` reports, in CSS pixels.
pub const Metrics = struct {
    width: f64 = 0,
    actualBoundingBoxLeft: f64 = 0,
    actualBoundingBoxRight: f64 = 0,
    fontBoundingBoxAscent: f64 = 0,
    fontBoundingBoxDescent: f64 = 0,
    actualBoundingBoxAscent: f64 = 0,
    actualBoundingBoxDescent: f64 = 0,
    hangingBaseline: f64 = 0,
    alphabeticBaseline: f64 = 0,
    ideographicBaseline: f64 = 0,
};

/// Measures `text` in `family` at `size`, from Chrome's own numbers.
///
/// Exact for printable ASCII, because advances are linear in size and a
/// string's width is the sum of its glyphs'. Text is walked one shaped
/// cluster at a time so a colour emoji — which is neither a text glyph nor
/// necessarily one codepoint — can be priced from `emoji_sizes` instead.
/// Three known departures, all measured rather than assumed:
///
///   * no kerning. Chrome makes 'AV' 12.6025390625 at 10px sans-serif where
///     the sum of the two advances is 13.33984375. Only pairs the font kerns
///     differ, which for the strings fingerprinters actually use — 'mmmmmmm-
///     mmlli', 'Cwm fjordbank glyphs vext quiz' — is none of them.
///   * outside U+0020..U+007E and the colour emoji we have no table, so each
///     glyph is charged the family's mean ASCII advance and contributes no
///     ink. That is a guess, not a measurement — and a visible one: Chrome
///     makes a bare U+2600 16 at 16px sans-serif, where we say 8.431.
///   * every colour emoji is charged what U+1F600 measures. All ten the
///     Turnstile widget asks about agree with it to the last decimal, but
///     ten is the whole of the evidence.
pub fn measure(family: font_metrics.Family, text: []const u8, size: f64) Metrics {
    const box = font_metrics.boundingBox(family, size);
    var metrics = Metrics{
        .fontBoundingBoxAscent = box.ascent,
        .fontBoundingBoxDescent = box.descent,
        // Both derived from the box, exactly as Chrome reports them: the
        // hanging baseline sits at 80% of the ascent and the ideographic one
        // at the descent. Chrome computes the former in single precision —
        // it answers 10.399999618530273, not 10.4, for an ascent of 13 — so
        // the round-trip through f32 is deliberate.
        .hangingBaseline = @as(f32, @floatCast(box.ascent * 0.8)),
        .alphabeticBaseline = 0,
        .ideographicBaseline = -box.descent,
    };
    if (size <= 0 or !std.math.isFinite(size)) {
        return metrics;
    }

    // The pen is carried in two pieces. Tabulated advances stay at the
    // table's 100px basis, where every value is a dyadic rational, so the sum
    // is exact in f64 and `total * size / basis` lands on Chrome's answer bit
    // for bit; scaling each glyph first instead drifts by an ulp or two over
    // a long string. Emoji advances are already in pixels and cannot be moved
    // to the basis and back without picking up that same error — 20px at
    // 15px font-size comes back as 20.000000000000004 — so they are kept
    // apart. A string of printable ASCII never touches the second piece.
    var pen_basis: f64 = 0;
    var pen_pixels: f64 = 0;
    var ink_min: f64 = 0;
    var ink_max: f64 = 0;
    var ascent: f64 = 0;
    var descent: f64 = 0;
    var any_ink = false;

    var offset: usize = 0;
    while (offset < text.len) {
        // Only the boundary is taken from the cluster; what it costs is a
        // question canvas answers for itself, from a different table than the
        // SVG advance `nextCluster` computes.
        const cluster = nextCluster(family, text[offset..]);
        if (cluster.bytes == 0) break;
        const shaped = text[offset..][0..cluster.bytes];
        offset += cluster.bytes;

        if (isColourEmoji(shaped)) {
            const glyph = emojiBox(size);
            const pen = toPixels(pen_basis, size) + pen_pixels;
            foldInk(&ink_min, &ink_max, &any_ink, pen - glyph.left, pen + glyph.right);
            ascent = @max(ascent, glyph.ascent);
            descent = @max(descent, glyph.descent);
            pen_pixels += glyph.advance;
            continue;
        }

        var codepoints = std.unicode.Utf8Iterator{ .bytes = shaped, .i = 0 };
        while (codepoints.nextCodepoint()) |codepoint| {
            const glyph = font_metrics.glyph(family, codepoint) orelse {
                // A joiner, a variation selector or a combining mark rides on
                // the glyph before it: Chrome makes 'a' and 'a' U+0301 both
                // 8.898 at 16px sans-serif, and a lone U+FE0F zero.
                if (!isZeroWidth(codepoint)) pen_basis += meanAdvance(family);
                continue;
            };

            // A blank glyph (the space) has no ink box to fold in.
            const blank = glyph.left == 0 and glyph.right == 0 and glyph.ascent == 0 and glyph.descent == 0;
            if (!blank) {
                foldInk(
                    &ink_min,
                    &ink_max,
                    &any_ink,
                    toPixels(pen_basis - glyph.left, size) + pen_pixels,
                    toPixels(pen_basis + glyph.right, size) + pen_pixels,
                );
                ascent = @max(ascent, toPixels(glyph.ascent, size));
                descent = @max(descent, toPixels(glyph.descent, size));
            }

            pen_basis += glyph.advance;
        }
    }

    metrics.width = toPixels(pen_basis, size) + pen_pixels;
    metrics.actualBoundingBoxAscent = ascent;
    metrics.actualBoundingBoxDescent = descent;
    if (any_ink) {
        metrics.actualBoundingBoxLeft = -ink_min;
        metrics.actualBoundingBoxRight = ink_max;
    }
    return metrics;
}

/// Widens the ink box to hold one more glyph's edges, in pixels.
fn foldInk(ink_min: *f64, ink_max: *f64, any_ink: *bool, left_edge: f64, right_edge: f64) void {
    if (!any_ink.*) {
        ink_min.* = left_edge;
        ink_max.* = right_edge;
        any_ink.* = true;
        return;
    }
    ink_min.* = @min(ink_min.*, left_edge);
    ink_max.* = @max(ink_max.*, right_edge);
}

/// One colour emoji's advance and ink box, in CSS pixels at a given size.
const EmojiBox = struct {
    advance: f64,
    left: f64,
    right: f64,
    ascent: f64,
    descent: f64,
};

/// What headed Chrome answers for U+1F600 at sixteen sizes — the `sizes`
/// block of tools/fingerprint/results/probes/expr-emoji-text-metrics.chrome.json,
/// produced by
///
///   node tools/fingerprint/run-expr.mjs chrome \
///        tools/fingerprint/probes/expr-emoji-text-metrics.js --headed
///
/// A colour emoji is not linear in font-size the way a text glyph is. Apple
/// Color Emoji is a set of bitmap strikes rather than outlines, and Chrome
/// reports the strike it picked: below 24px the advance is wider than the em
/// box — 20 at 16px, where the em is 16 — and from 24px up it is the em
/// exactly. Run the probe headed or none of this holds; a headless Chrome
/// resolves the emoji font somewhere else and answers ten different widths
/// for these ten emoji instead of one.
///
/// The ink box is the same shape of measurement and equally unexplained: the
/// left edge sits one pixel before the pen at every size, not a fraction of
/// one, and the box is very nearly square.
const emoji_sizes = [_]struct {
    size: f64,
    advance: f64,
    ascent: f64,
    descent: f64,
    left: f64,
    right: f64,
}{
    .{ .size = 8, .advance = 10, .ascent = 9, .descent = 3, .left = 1, .right = 11 },
    .{ .size = 10, .advance = 13, .ascent = 11, .descent = 4, .left = 1, .right = 14 },
    .{ .size = 11, .advance = 14, .ascent = 12, .descent = 4, .left = 1, .right = 15 },
    .{ .size = 12, .advance = 15, .ascent = 13, .descent = 4, .left = 1, .right = 16 },
    .{ .size = 13, .advance = 16, .ascent = 14, .descent = 5, .left = 1, .right = 18 },
    .{ .size = 14, .advance = 18, .ascent = 15, .descent = 5, .left = 1, .right = 19 },
    .{ .size = 16, .advance = 20, .ascent = 17, .descent = 5, .left = 1, .right = 21 },
    .{ .size = 18, .advance = 21, .ascent = 19, .descent = 5, .left = 1, .right = 22 },
    .{ .size = 20, .advance = 22, .ascent = 20, .descent = 5, .left = 1, .right = 23 },
    .{ .size = 24, .advance = 24, .ascent = 23, .descent = 4, .left = 1, .right = 26 },
    .{ .size = 32, .advance = 32, .ascent = 30, .descent = 5, .left = 1, .right = 34 },
    .{ .size = 40, .advance = 40, .ascent = 37, .descent = 6, .left = 1, .right = 42 },
    .{ .size = 48, .advance = 48, .ascent = 44, .descent = 7, .left = 1, .right = 50 },
    .{ .size = 64, .advance = 64, .ascent = 58, .descent = 9, .left = 1, .right = 66 },
    .{ .size = 96, .advance = 96, .ascent = 86, .descent = 13, .left = 1, .right = 98 },
    .{ .size = 128, .advance = 128, .ascent = 114, .descent = 18, .left = 1, .right = 130 },
};

/// The emoji box at `size`: the measurement itself at a size we measured,
/// a straight line between the two nearest at a size in between, and the
/// nearest end scaled at a size outside the range. Only the first of those
/// three is Chrome's answer; the other two are what a table can offer.
fn emojiBox(size: f64) EmojiBox {
    const first = emoji_sizes[0];
    if (size <= first.size) return scaleBox(first, size / first.size);

    const last = emoji_sizes[emoji_sizes.len - 1];
    if (size >= last.size) return scaleBox(last, size / last.size);

    for (emoji_sizes[1..], 0..) |high, i| {
        if (size > high.size) continue;
        const low = emoji_sizes[i];
        const t = (size - low.size) / (high.size - low.size);
        return .{
            .advance = low.advance + (high.advance - low.advance) * t,
            .left = low.left + (high.left - low.left) * t,
            .right = low.right + (high.right - low.right) * t,
            .ascent = low.ascent + (high.ascent - low.ascent) * t,
            .descent = low.descent + (high.descent - low.descent) * t,
        };
    }
    unreachable;
}

fn scaleBox(row: @TypeOf(emoji_sizes[0]), factor: f64) EmojiBox {
    return .{
        .advance = row.advance * factor,
        .left = row.left * factor,
        .right = row.right * factor,
        .ascent = row.ascent * factor,
        .descent = row.descent * factor,
    };
}

/// Whether the shaped cluster `text` is drawn from a colour emoji font, which
/// is what decides whether it is measured from `emoji_sizes` or from the text
/// font. The rule is UTS #51's: an Emoji character carries its own default,
/// a variation selector overrides that default either way, and a joiner or a
/// skin tone modifier only ever appears in a sequence that is one.
///
/// The base has to be Emoji for any of it to apply, which is what keeps a
/// lone U+FE0F — Chrome measures it zero — from being charged an emoji, and
/// what keeps 'a' U+FE0F from turning into one.
fn isColourEmoji(text: []const u8) bool {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    const base = iterator.nextCodepoint() orelse return false;
    if (!emoji_properties.isEmoji(base)) return false;

    var colour = emoji_properties.isDefaultPresentation(base);
    while (iterator.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            VARIATION_SELECTOR_16, ZERO_WIDTH_JOINER => colour = true,
            VARIATION_SELECTOR_15 => colour = false,
            SKIN_TONE_FIRST...SKIN_TONE_LAST => colour = true,
            else => {},
        }
    }
    return colour;
}

/// What an unmeasured glyph is charged. Not a Chrome number.
fn meanAdvance(family: font_metrics.Family) f64 {
    var total: f64 = 0;
    for (family.glyphs) |glyph| total += glyph.advance;
    return total / @as(f64, @floatFromInt(family.glyphs.len));
}

test "text_measure: reproduces Chrome's measureText" {
    // Straight from sections.text of the graphics dump.
    const sample = measure(font_metrics.sans_serif, "mmmmmmmmmmlli", 10);
    try std.testing.expectEqual(@as(f64, 89.9658203125), sample.width);
    try std.testing.expectEqual(@as(f64, -0.64453125), sample.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 89.2822265625), sample.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 10), sample.fontBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2), sample.fontBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 7.1728515625), sample.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 0), sample.actualBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 8), sample.hangingBaseline);
    try std.testing.expectEqual(@as(f64, 0), sample.alphabeticBaseline);
    try std.testing.expectEqual(@as(f64, -2), sample.ideographicBaseline);

    const pangram = measure(font_metrics.arial, "Cwm fjordbank glyphs vext quiz", 14);
    try std.testing.expectEqual(@as(f64, 196.861328125), pangram.width);
    try std.testing.expectEqual(@as(f64, -0.697265625), pangram.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 196.560546875), pangram.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 13), pangram.fontBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 3), pangram.fontBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 10.1923828125), pangram.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2.9462890625), pangram.actualBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 10.399999618530273), pangram.hangingBaseline);
    try std.testing.expectEqual(@as(f64, -3), pangram.ideographicBaseline);

    const empty = measure(font_metrics.sans_serif, "", 10);
    try std.testing.expectEqual(@as(f64, 0), empty.width);
    try std.testing.expectEqual(@as(f64, 0), empty.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 0), empty.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 10), empty.fontBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 8), empty.hangingBaseline);

    // Exactly linear in size, which is why one table is enough.
    try std.testing.expectEqual(@as(f64, 8.330078125), measure(font_metrics.sans_serif, "m", 10).width);
    try std.testing.expectEqual(@as(f64, 83.30078125), measure(font_metrics.sans_serif, "m", 100).width);
    try std.testing.expectEqual(@as(f64, 899.658203125), measure(font_metrics.sans_serif, "mmmmmmmmmmlli", 100).width);

    // Sums of advances, all of which Chrome agrees with.
    try std.testing.expectEqual(@as(f64, 55.01953125), measure(font_metrics.sans_serif, "Hello, world!", 10).width);
    try std.testing.expectEqual(@as(f64, 140.615234375), measure(font_metrics.sans_serif, "Cwm fjordbank glyphs vext quiz", 10).width);
    try std.testing.expectEqual(@as(f64, 28.3154296875), measure(font_metrics.sans_serif, "WWW", 10).width);
    try std.testing.expectEqual(@as(f64, 6.6650390625), measure(font_metrics.sans_serif, "iii", 10).width);

    // The kerned pairs, where we knowingly differ: Chrome says 12.6025390625
    // and 10.5615234375 because it kerns; we report the plain sums.
    try std.testing.expectEqual(@as(f64, 13.33984375), measure(font_metrics.sans_serif, "AV", 10).width);
    try std.testing.expectEqual(@as(f64, 11.669921875), measure(font_metrics.sans_serif, "To", 10).width);
}

test "text_measure: a colour emoji measures the strike Chrome picked" {
    // Every number here is headed Chrome's, from the `emoji` and `clusters`
    // blocks of results/probes/expr-emoji-text-metrics.chrome.json. The
    // Turnstile widget measures its ten at exactly this font.
    const sans = font_metrics.sans_serif;
    for ([_][]const u8{ "😀", "🤣", "😱", "👍", "🔥", "🚀", "🧠", "🐶", "🏠", "☀️" }) |emoji| {
        const metrics = measure(sans, emoji, 16);
        try std.testing.expectEqual(@as(f64, 20), metrics.width);
        try std.testing.expectEqual(@as(f64, 1), metrics.actualBoundingBoxLeft);
        try std.testing.expectEqual(@as(f64, 21), metrics.actualBoundingBoxRight);
        try std.testing.expectEqual(@as(f64, 17), metrics.actualBoundingBoxAscent);
        try std.testing.expectEqual(@as(f64, 5), metrics.actualBoundingBoxDescent);
        // The font box and the baselines come from the family, not the emoji,
        // and already agreed with Chrome before any of this.
        try std.testing.expectEqual(@as(f64, 14), metrics.fontBoundingBoxAscent);
        try std.testing.expectEqual(@as(f64, 4), metrics.fontBoundingBoxDescent);
    }

    // A whole cluster is one emoji, whatever it is made of: a flag is two
    // regional indicators, a profession is a ZWJ sequence, a thumb is a base
    // and a skin tone. Chrome charges each of them once.
    try std.testing.expectEqual(@as(f64, 20), measure(sans, "🇺🇸", 16).width);
    try std.testing.expectEqual(@as(f64, 20), measure(sans, "👨‍💻", 16).width);
    try std.testing.expectEqual(@as(f64, 20), measure(sans, "👍🏽", 16).width);

    // And a selector on its own is not an emoji, it is nothing: Chrome
    // measures a bare U+FE0F zero, and a combining mark rides on the letter
    // before it rather than being charged again.
    try std.testing.expectEqual(@as(f64, 0), measure(sans, "\u{fe0f}", 16).width);
    try std.testing.expectEqual(
        measure(sans, "a", 16).width,
        measure(sans, "a\u{0301}", 16).width,
    );

    // Two emoji are two advances, and the ink box spans both.
    const pair = measure(sans, "😀😀", 16);
    try std.testing.expectEqual(@as(f64, 40), pair.width);
    try std.testing.expectEqual(@as(f64, 1), pair.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 41), pair.actualBoundingBoxRight);

    // Mixed with text, the pen keeps both kinds of advance. 'x' is 8 at 16px
    // in both engines, so the emoji starts there and its ink ends at 29.
    const mixed = measure(sans, "x😀", 16);
    try std.testing.expectEqual(@as(f64, 28), mixed.width);
    try std.testing.expectEqual(@as(f64, 29), mixed.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 17), mixed.actualBoundingBoxAscent);

    // Printable ASCII is untouched by any of it — same string, same bits.
    try std.testing.expectEqual(@as(f64, 89.9658203125), measure(sans, "mmmmmmmmmmlli", 10).width);
    try std.testing.expectEqual(@as(f64, -0.64453125), measure(sans, "mmmmmmmmmmlli", 10).actualBoundingBoxLeft);
}

test "text_measure: the emoji strike is a table, not a ratio" {
    // Exact at a measured size, both ends of the table included.
    try std.testing.expectEqual(@as(f64, 20), emojiBox(16).advance);
    try std.testing.expectEqual(@as(f64, 17), emojiBox(16).ascent);
    try std.testing.expectEqual(@as(f64, 10), emojiBox(8).advance);
    try std.testing.expectEqual(@as(f64, 128), emojiBox(128).advance);
    try std.testing.expectEqual(@as(f64, 114), emojiBox(128).ascent);

    // The point of the table: 16px is not 1.25 em everywhere and 24px is not
    // 1.25 em at all. Below 24 the strike is wider than the em box, from 24
    // up it is the em exactly.
    try std.testing.expectEqual(@as(f64, 24), emojiBox(24).advance);
    try std.testing.expectEqual(@as(f64, 48), emojiBox(48).advance);

    // Between two measurements, a straight line; outside them, the nearest
    // end scaled. Neither is Chrome's answer, and neither pretends to be.
    try std.testing.expectEqual(@as(f64, 23), emojiBox(22).advance);
    try std.testing.expectEqual(@as(f64, 256), emojiBox(256).advance);
    try std.testing.expectEqual(@as(f64, 5), emojiBox(4).advance);

    // Non-finite and non-positive sizes never reach the table.
    try std.testing.expectEqual(@as(f64, 0), measure(font_metrics.sans_serif, "😀", 0).width);
    try std.testing.expectEqual(@as(f64, 0), measure(font_metrics.sans_serif, "😀", -3).width);
}

test "text_measure: a variation selector decides which font a glyph comes from" {
    // The gap between Emoji and Emoji_Presentation, which is the whole reason
    // emoji_properties.zig carries both tables.
    try std.testing.expect(isColourEmoji("😀"));
    try std.testing.expect(!isColourEmoji("☀")); // Emoji, text presentation
    try std.testing.expect(isColourEmoji("☀\u{fe0f}")); // asked for colour
    try std.testing.expect(!isColourEmoji("😀\u{fe0e}")); // asked for text
    try std.testing.expect(isColourEmoji("🇺🇸"));
    try std.testing.expect(isColourEmoji("👨‍💻"));
    try std.testing.expect(isColourEmoji("👍🏽"));

    // A selector needs an Emoji character in front of it to mean anything.
    try std.testing.expect(!isColourEmoji("\u{fe0f}"));
    try std.testing.expect(!isColourEmoji("a\u{fe0f}"));
    try std.testing.expect(!isColourEmoji("a"));
    try std.testing.expect(!isColourEmoji(""));

    // Chrome makes a bare U+2600 16 at 16px sans-serif — one em, from the
    // text font. We answer the mean-advance guess instead; the selector form
    // above is the one the widget asks about, and that one is right.
    try std.testing.expectEqual(
        measure(font_metrics.sans_serif, "\u{2600}", 16).width,
        meanAdvance(font_metrics.sans_serif) * 16 / font_metrics.basis,
    );
}

// Character counts and indices are UTF-16 code units, to match DOM string
// semantics: an astral codepoint is two addressable characters in browsers.
pub fn utf16Length(text: []const u8) u32 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var result: u32 = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        result += unitLength(codepoint);
    }
    return result;
}

fn unitLength(codepoint: u21) u32 {
    return if (codepoint >= 0x10000) 2 else 1;
}

/// Total advance of `text` at `font_size`, cluster by cluster.
pub fn svgWidth(family: font_metrics.Family, text: []const u8, font_size: f64) f64 {
    var offset: usize = 0;
    var total: f64 = 0;
    while (offset < text.len) {
        const cluster = nextCluster(family, text[offset..]);
        total += cluster.advance;
        offset += cluster.bytes;
    }
    return toPixels(total, font_size);
}

/// The advance of the `nchars` characters starting at `charnum`, counted in
/// UTF-16 code units like every DOM string index.
pub fn svgSubstringWidth(family: font_metrics.Family, text: []const u8, charnum: u32, nchars: u32, font_size: f64) !f64 {
    const range = try clusterRange(family, text, charnum, nchars);
    return toPixels(range.advance, font_size);
}

/// Where the cluster addressed by `charnum` starts, and how wide it is. Both
/// in user units at `font_size`, and both measured from the start of `text`.
pub fn svgCharExtent(family: font_metrics.Family, text: []const u8, charnum: u32, font_size: f64) !struct { offset: f64, advance: f64 } {
    const range = try clusterRange(family, text, charnum, 1);
    return .{
        .offset = toPixels(range.before, font_size),
        .advance = toPixels(range.advance, font_size),
    };
}

/// Accumulates at the tables' 100px basis and converts once, so a sum of
/// dyadic rationals stays exact until the last step.
fn toPixels(value: f64, font_size: f64) f64 {
    if (font_size <= 0 or !std.math.isFinite(font_size)) {
        return 0;
    }
    return value * font_size / font_metrics.basis;
}

/// A cluster is measured whenever its unit range intersects the request, so
/// addressing either half of a surrogate pair — or any code unit inside a ZWJ
/// sequence — yields the whole glyph, like Chrome does.
fn clusterRange(family: font_metrics.Family, text: []const u8, charnum: u32, nchars: u32) !struct { before: f64, advance: f64 } {
    if (charnum >= utf16Length(text)) {
        return error.IndexSizeError;
    }
    const end = charnum +| nchars;

    var offset: usize = 0;
    var unit: u32 = 0;
    var before: f64 = 0;
    var inside: f64 = 0;
    while (offset < text.len) {
        const cluster = nextCluster(family, text[offset..]);
        if (unit >= end) break;
        if (unit + cluster.units > charnum) {
            inside += cluster.advance;
        } else {
            before += cluster.advance;
        }
        unit += cluster.units;
        offset += cluster.bytes;
    }
    return .{ .before = before, .advance = inside };
}

const Cluster = struct {
    /// Bytes of UTF-8 the cluster spans.
    bytes: usize,
    /// UTF-16 code units the cluster spans.
    units: u32,
    /// Advance at the 100px basis.
    advance: f64,
};

/// The shaped cluster at the front of `text`. A measured emoji sequence wins
/// outright; otherwise a base character absorbs the joiners, variation
/// selectors, skin-tone modifiers and combining marks that follow it, which
/// is what makes a ZWJ sequence one glyph wide instead of several.
fn nextCluster(family: font_metrics.Family, text: []const u8) Cluster {
    if (emoji_metrics.match(text)) |measured| {
        return .{
            .bytes = measured.text.len,
            .units = measured.units,
            .advance = measured.advance,
        };
    }

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    const base = iterator.nextCodepoint() orelse return .{ .bytes = text.len, .units = 0, .advance = 0 };
    var cluster = Cluster{
        .bytes = iterator.i,
        .units = unitLength(base),
        .advance = advance(family, base),
    };

    // A flag is a pair of regional indicators and one glyph.
    if (isRegionalIndicator(base)) {
        const save = iterator.i;
        if (iterator.nextCodepoint()) |next| {
            if (isRegionalIndicator(next)) {
                cluster.bytes = iterator.i;
                cluster.units += unitLength(next);
                return cluster;
            }
        }
        iterator.i = save;
    }

    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == ZERO_WIDTH_JOINER) {
            // The joined half is part of the same glyph and carries no
            // advance of its own.
            const joined = iterator.nextCodepoint() orelse break;
            cluster.units += unitLength(codepoint) + unitLength(joined);
            cluster.bytes = iterator.i;
            continue;
        }
        if (!isClusterExtender(codepoint)) {
            break;
        }
        cluster.units += unitLength(codepoint);
        cluster.bytes = iterator.i;
    }
    return cluster;
}

const ZERO_WIDTH_JOINER = 0x200d;
const VARIATION_SELECTOR_15 = 0xfe0e; // asks for the text glyph
const VARIATION_SELECTOR_16 = 0xfe0f; // asks for the colour emoji one
const SKIN_TONE_FIRST = 0x1f3fb;
const SKIN_TONE_LAST = 0x1f3ff;

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

fn isClusterExtender(codepoint: u21) bool {
    return isZeroWidth(codepoint) or
        codepoint == 0x20e3 or // combining enclosing keycap
        (codepoint >= SKIN_TONE_FIRST and codepoint <= SKIN_TONE_LAST);
}

/// One character's advance at the 100px basis. Tabulated for the ASCII we
/// measured; a guess, and marked as one, outside it.
fn advance(family: font_metrics.Family, codepoint: u21) f64 {
    if (font_metrics.glyph(family, codepoint)) |g| {
        return g.advance;
    }
    if (isZeroWidth(codepoint)) return 0;
    if (codepoint == '\n' or codepoint == '\r') return 0;
    if (codepoint == '\t') return font_metrics.basis * 1.32;
    if (std.ascii.isWhitespace(@intCast(@min(codepoint, 0x7f)))) return font_metrics.basis * 0.33;
    if (isWide(codepoint)) return font_metrics.basis;
    return font_metrics.basis * 0.6;
}

fn isZeroWidth(codepoint: u21) bool {
    return codepoint == 0x200c or codepoint == 0x200d or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        codepoint == 0x2329 or codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f000 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

test "svg metrics measure whole clusters, addressed by utf-16 unit" {
    const serif = font_metrics.fallback;
    try std.testing.expectEqual(@as(u32, 3), utf16Length("Aé界"));
    try std.testing.expectEqual(@as(u32, 2), utf16Length("🌍"));

    // 'A' from the table, the combining acute absorbed into it, and an
    // untabulated wide glyph charged one em.
    try std.testing.expectApproxEqAbs(@as(f64, 7.2216796875 + 10), svgWidth(serif, "A\u{0301}界", 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try svgSubstringWidth(serif, "A界", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try svgSubstringWidth(serif, "🌍", 0, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try svgSubstringWidth(serif, "🌍", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try svgSubstringWidth(serif, "A界", 1, 0, 10), 0.0001);
    try std.testing.expectError(error.IndexSizeError, svgSubstringWidth(serif, "A", 2, 1, 10));
    try std.testing.expectError(error.IndexSizeError, svgSubstringWidth(serif, "A", 1, 0, 10));
    try std.testing.expectError(error.IndexSizeError, svgSubstringWidth(serif, "", 0, 0, 10));

    // Straight from the emoji table: Chrome makes these 73.6875 and 60.2109375
    // at 100px, not one em each.
    try std.testing.expectEqual(@as(f64, 73.6875), svgWidth(serif, "☺", 100));
    try std.testing.expectEqual(@as(f64, 60.2109375), svgWidth(serif, "☠", 100));

    // A ZWJ sequence is five code units and a single glyph, so summing its
    // parts (which would charge the ♂ separately) is wrong.
    try std.testing.expectEqual(@as(u32, 5), utf16Length("🤵‍♂️"));
    try std.testing.expectEqual(@as(f64, 100), svgWidth(serif, "🤵‍♂️", 100));
    try std.testing.expectEqual(@as(f64, 100), try svgSubstringWidth(serif, "🤵‍♂️", 3, 1, 100));

    // An unmeasured ZWJ sequence still collapses to one cluster.
    try std.testing.expectEqual(@as(f64, 100), svgWidth(serif, "🧑\u{200d}🚀", 100));
    // As does a flag, which is a pair of regional indicators.
    try std.testing.expectEqual(@as(f64, 100), svgWidth(serif, "🇫🇷", 100));

    // Chrome's own answer for the SVG default font.
    try std.testing.expectEqual(@as(f64, 444.3359375), svgWidth(serif, "Hello", 200));
    const extent = try svgCharExtent(serif, "Hello", 4, 20);
    try std.testing.expectEqual(@as(f64, 34.43359375), extent.offset);
    try std.testing.expectEqual(@as(f64, 10), extent.advance);
}
