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

// Two measurement paths live here, both reading the per-glyph tables
// transcribed from Chrome (font_metrics.zig, emoji_metrics.zig).
//
// `measure` is the canvas one: it reproduces what `measureText` answers,
// exactly, for printable ASCII in the families we measured.
//
// `svgWidth` and friends below are the SVG one. It differs in two ways that
// are Chrome's, not ours: SVG text measures whole shaped clusters, so a ZWJ
// emoji sequence has one advance rather than the sum of its parts, and it
// addresses characters by UTF-16 code unit because that is what the DOM
// counts. Chrome also quantises SVG advances per size where the canvas ones
// scale exactly; we scale, and are off by well under a tenth of a pixel.
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
/// string's width is the sum of its glyphs'. Two known departures, both
/// measured rather than assumed:
///
///   * no kerning. Chrome makes 'AV' 12.6025390625 at 10px sans-serif where
///     the sum of the two advances is 13.33984375. Only pairs the font kerns
///     differ, which for the strings fingerprinters actually use — 'mmmmmmm-
///     mmlli', 'Cwm fjordbank glyphs vext quiz' — is none of them.
///   * outside U+0020..U+007E we have no table, so each glyph is charged the
///     family's mean ASCII advance and contributes no ink. That is a guess,
///     not a measurement.
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

    // Accumulate at the table's 100px basis and scale once at the end. Every
    // tabulated value is a dyadic rational, so the sums are exact in f64 and
    // `total * size / basis` lands on Chrome's answer bit for bit; scaling
    // each glyph first instead drifts by an ulp or two over a long string.
    var pen: f64 = 0;
    var ink_min: f64 = 0;
    var ink_max: f64 = 0;
    var ascent: f64 = 0;
    var descent: f64 = 0;
    var any_ink = false;

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const glyph = font_metrics.glyph(family, codepoint) orelse {
            pen += meanAdvance(family);
            continue;
        };

        // A blank glyph (the space) has no ink box to fold in.
        const blank = glyph.left == 0 and glyph.right == 0 and glyph.ascent == 0 and glyph.descent == 0;
        if (!blank) {
            const left_edge = pen - glyph.left;
            const right_edge = pen + glyph.right;
            if (!any_ink) {
                ink_min = left_edge;
                ink_max = right_edge;
                any_ink = true;
            } else {
                ink_min = @min(ink_min, left_edge);
                ink_max = @max(ink_max, right_edge);
            }
            ascent = @max(ascent, glyph.ascent);
            descent = @max(descent, glyph.descent);
        }

        pen += glyph.advance;
    }

    metrics.width = toPixels(pen, size);
    metrics.actualBoundingBoxAscent = toPixels(ascent, size);
    metrics.actualBoundingBoxDescent = toPixels(descent, size);
    if (any_ink) {
        metrics.actualBoundingBoxLeft = toPixels(-ink_min, size);
        metrics.actualBoundingBoxRight = toPixels(ink_max, size);
    }
    return metrics;
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

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

fn isClusterExtender(codepoint: u21) bool {
    return isZeroWidth(codepoint) or
        codepoint == 0x20e3 or // combining enclosing keycap
        (codepoint >= 0x1f3fb and codepoint <= 0x1f3ff); // skin tone modifiers
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
