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

// Two measurement paths live here.
//
// `measure` below is the real one: it reads the per-glyph table transcribed
// from Chrome (see font_metrics.zig) and reproduces what `measureText`
// answers, exactly, for printable ASCII in the families we measured. That is
// what the canvas uses.
//
// Everything after it is the older heuristic — 0.6em per character and a few
// buckets — which SVGTextContentElement still uses. It predates the table and
// should eventually be replaced by it; leaving it in place for now keeps the
// SVG geometry tests honest about what changed and when.

// Deterministic DOM fallback only. This intentionally does not claim to shape
// scripts, apply kerning, or select fonts; a real shaping backend can replace
// this module without changing SVGTextContentElement.

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

    const toPixels = struct {
        fn f(value: f64, font_size: f64) f64 {
            return value * font_size / font_metrics.basis;
        }
    }.f;

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

pub fn width(text: []const u8, font_size: f64) f64 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var result: f64 = 0;
    while (iterator.nextCodepoint()) |codepoint| result += advance(codepoint, font_size);
    return result;
}

pub fn substringWidth(text: []const u8, charnum: u32, nchars: u32, font_size: f64) !f64 {
    if (charnum >= utf16Length(text)) return error.IndexSizeError;
    const end = charnum +| nchars;

    // A glyph is measured whenever its unit range intersects the request, so
    // addressing either half of a surrogate pair yields the full glyph, like
    // Chrome does.
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var unit: u32 = 0;
    var result: f64 = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        const units = unitLength(codepoint);
        if (unit >= end) break;
        if (unit + units > charnum) result += advance(codepoint, font_size);
        unit += units;
    }
    return result;
}

fn advance(codepoint: u21, font_size: f64) f64 {
    if (isZeroWidth(codepoint)) return 0;
    if (codepoint == '\n' or codepoint == '\r') return 0;
    if (codepoint == '\t') return font_size * 1.32;
    if (std.ascii.isWhitespace(@intCast(@min(codepoint, 0x7f)))) return font_size * 0.33;
    if (isWide(codepoint)) return font_size;
    return font_size * 0.6;
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

test "fallback metrics count utf-16 units and ignore combining marks" {
    try std.testing.expectEqual(@as(u32, 3), utf16Length("Aé界"));
    try std.testing.expectEqual(@as(u32, 2), utf16Length("🌍"));
    try std.testing.expectApproxEqAbs(@as(f64, 16), width("A\u{0301}界", 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("A界", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("🌍", 0, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("🌍", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try substringWidth("A界", 1, 0, 10), 0.0001);
    try std.testing.expectError(error.IndexSizeError, substringWidth("A", 2, 1, 10));
    try std.testing.expectError(error.IndexSizeError, substringWidth("A", 1, 0, 10));
    try std.testing.expectError(error.IndexSizeError, substringWidth("", 0, 0, 10));
}
