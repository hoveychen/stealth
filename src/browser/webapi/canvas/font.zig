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

// The `font` attribute of a 2D canvas context: a CSS font shorthand that the
// context parses, resolves and hands back in a normalised form. Scripts read
// it back — `ctx.font = x; ctx.font === y` is itself a fingerprint — so the
// normalisation matters as much as the parse.
//
// Every rule here was measured against Chrome on macOS; see
// `sections.text.fontShorthandFromNonDefault` in the graphics dump. The
// notable ones, because they are not what the CSS spec alone would suggest:
//
//   * relative sizes resolve against the canvas *default* font, not the
//     current one: from `33px monospace`, `1em sans-serif` is `10px`;
//   * but `rem` is the document root's 16px, so `2rem` is `32px`;
//   * the serialisation order is style, weight, variant — not CSS's
//     style, variant, weight: `italic small-caps bold 16px serif` comes back
//     as `italic bold small-caps 16px serif`;
//   * `oblique` normalises to `italic`, but `oblique 30deg` is rejected;
//   * font-stretch is rejected outright: `condensed 16px serif` does nothing;
//   * a rejected value leaves the previous one in place — it does not reset
//     to the default.
//
// Deliberately not supported, all of which Chrome accepts and we reject
// (leaving the old value, which a probe can see): `ex` / `ch` / `q` and the
// viewport units, and the system font keywords (`caption`, `menu`, ...).
// Sizes in those units would need numbers we have not measured, and inventing
// them would be worse than not having them.

const std = @import("std");

const font_metrics = @import("../../font_metrics.zig");

const Allocator = std.mem.Allocator;

/// The canvas default, which is also what relative sizes resolve against.
pub const default_css = "10px sans-serif";
pub const default_size = 10.0;
/// `rem` is the document root's size, which we report as Chrome's default.
const root_size = 16.0;

const Font = @This();

/// The normalised shorthand, as `ctx.font` hands it back.
css: []const u8,
/// Computed size in CSS pixels.
size: f64,
/// The measured family the first resolvable name in the list maps to.
family: font_metrics.Family,
/// The computed weight, and whether the style is italic. Both are parsed out
/// of the shorthand anyway; they are kept because the family alone does not say
/// which of its four tables a measurement wants, and without them `bold 16px
/// serif` measures a string at exactly the width `16px serif` does.
weight: u16,
italic: bool,

pub const default: Font = .{
    .css = default_css,
    .size = default_size,
    .family = font_metrics.sans_serif,
    .weight = 400,
    .italic = false,
};

const Style = enum { normal, italic };
const Variant = enum { normal, small_caps };

/// Parses a CSS font shorthand. Returns null when Chrome would reject it, in
/// which case the caller keeps whatever it had.
pub fn parse(arena: Allocator, input: []const u8, loaded: ?font_metrics.Loaded) ?Font {
    var style: Style = .normal;
    var variant: Variant = .normal;
    var weight: u16 = 400;
    var seen_style = false;
    var seen_variant = false;
    var seen_weight = false;

    var rest = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (rest.len == 0) {
        return null;
    }

    // The prefix: any of style / variant / weight, in any order, at most one
    // each. `normal` is allowed once per unfilled slot, so `normal normal
    // normal 16px serif` parses.
    var normals: u8 = 0;
    const size_token = while (true) {
        const token = nextToken(rest) orelse return null;

        if (std.ascii.eqlIgnoreCase(token, "normal")) {
            normals += 1;
            if (normals > 3) return null;
            rest = advance(rest, token);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "italic") or std.ascii.eqlIgnoreCase(token, "oblique")) {
            if (seen_style) return null;
            seen_style = true;
            style = .italic;
            rest = advance(rest, token);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "small-caps")) {
            if (seen_variant) return null;
            seen_variant = true;
            variant = .small_caps;
            rest = advance(rest, token);
            continue;
        }
        if (parseWeight(token)) |parsed| {
            if (seen_weight) return null;
            seen_weight = true;
            weight = parsed;
            rest = advance(rest, token);
            continue;
        }

        // Not a prefix keyword, so it has to be the size.
        break token;
    };

    // `16px/1.5` — the line height parses but is dropped, as Chrome drops it.
    const slash = std.mem.indexOfScalar(u8, size_token, '/');
    const size_part = if (slash) |at| size_token[0..at] else size_token;
    if (slash) |at| {
        if (size_token[at + 1 ..].len == 0) return null;
    }

    const size = parseSize(size_part) orelse return null;
    if (!std.math.isFinite(size) or size < 0) {
        return null;
    }

    const families = std.mem.trim(u8, advance(rest, size_token), &std.ascii.whitespace);
    if (families.len == 0) {
        return null;
    }

    var serialised: std.Io.Writer.Allocating = .init(arena);
    if (style == .italic) serialised.writer.writeAll("italic ") catch return null;
    switch (weight) {
        400 => {},
        700 => serialised.writer.writeAll("bold ") catch return null,
        else => serialised.writer.print("{d} ", .{weight}) catch return null,
    }
    if (variant == .small_caps) serialised.writer.writeAll("small-caps ") catch return null;
    serialised.writer.print("{d}px ", .{significant(size, 6)}) catch return null;

    // The size goes in because a variable face has one set of advances per
    // optical size: canvas has no `font-optical-sizing` property, so the
    // initial `auto` stands and the axis follows the size the shorthand named.
    const family = (serialiseFamilies(&serialised.writer, families, loaded, size) catch return null) orelse return null;

    return .{
        .css = serialised.written(),
        .size = size,
        .family = family,
        .weight = weight,
        .italic = style == .italic,
    };
}

/// The first whitespace-delimited token of `input`, which must already be
/// left-trimmed. Null when there is nothing left.
fn nextToken(input: []const u8) ?[]const u8 {
    const start = std.mem.indexOfNone(u8, input, &std.ascii.whitespace) orelse return null;
    const end = std.mem.indexOfAny(u8, input[start..], &std.ascii.whitespace) orelse input.len - start;
    return input[start..][0..end];
}

/// The remainder of `input` after `token`, which must be a slice of it.
fn advance(input: []const u8, token: []const u8) []const u8 {
    const consumed = (@intFromPtr(token.ptr) - @intFromPtr(input.ptr)) + token.len;
    return input[consumed..];
}

/// `bolder` and `lighter` are relative to the parent, and a canvas context has
/// none, so they resolve against normal: 400 -> 700 and 400 -> 100.
fn parseWeight(token: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(token, "bold")) return 700;
    if (std.ascii.eqlIgnoreCase(token, "bolder")) return 700;
    if (std.ascii.eqlIgnoreCase(token, "lighter")) return 100;

    const value = std.fmt.parseFloat(f64, token) catch return null;
    if (!std.math.isFinite(value) or value < 1 or value > 1000) {
        return null;
    }
    return @intFromFloat(@round(value));
}

fn parseSize(token: []const u8) ?f64 {
    const absolute = [_]struct { []const u8, f64 }{
        .{ "xx-small", 9 },
        .{ "x-small", 10 },
        .{ "small", 13 },
        .{ "medium", 16 },
        .{ "large", 18 },
        .{ "x-large", 24 },
        .{ "xx-large", 32 },
        .{ "xxx-large", 48 },
        // Relative to the canvas default, which has no parent to inherit from.
        .{ "larger", default_size * 1.2 },
        .{ "smaller", default_size / 1.2 },
    };
    for (absolute) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], token)) {
            return entry[1];
        }
    }

    const units = [_]struct { []const u8, f64 }{
        .{ "px", 1 },
        .{ "pt", 96.0 / 72.0 },
        .{ "pc", 16 },
        .{ "in", 96 },
        .{ "cm", 96.0 / 2.54 },
        .{ "mm", 96.0 / 25.4 },
        .{ "rem", root_size },
        .{ "em", default_size },
        .{ "%", default_size / 100.0 },
    };
    for (units) |entry| {
        const unit = entry[0];
        if (token.len <= unit.len) continue;
        if (!std.ascii.endsWithIgnoreCase(token, unit)) continue;
        const number = std.fmt.parseFloat(f64, token[0 .. token.len - unit.len]) catch continue;
        return number * entry[1];
    }
    return null;
}

/// Writes the comma-separated family list in Chrome's normalised form and
/// returns the table for the first name we have measurements for. Null when
/// the list is malformed; an unresolvable list still parses, and falls back
/// the way Chrome's does.
fn serialiseFamilies(writer: *std.Io.Writer, list: []const u8, loaded: ?font_metrics.Loaded, optical_size: f64) !?font_metrics.Family {
    var resolved: ?font_metrics.Family = null;
    var wrote_one = false;

    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (name.len == 0) {
            return null;
        }

        const unquoted = if (name.len >= 2 and (name[0] == '"' or name[0] == '\'') and name[name.len - 1] == name[0])
            name[1 .. name.len - 1]
        else
            name;
        if (unquoted.len == 0) {
            return null;
        }

        if (resolved == null) {
            // `name`, not `unquoted`: a quoted generic is an ordinary family
            // name and must not resolve to the keyword's face. The serialised
            // form below still comes from `unquoted`, which is a separate rule.
            resolved = font_metrics.findEntry(name, loaded, optical_size);
        }

        if (wrote_one) try writer.writeAll(", ");
        wrote_one = true;

        // A single identifier serialises bare; anything with a space comes
        // back double-quoted, however it was written.
        if (std.mem.indexOfAny(u8, unquoted, " \t\n\r\"'") == null) {
            try writer.writeAll(unquoted);
        } else {
            try writer.writeByte('"');
            try writer.writeAll(unquoted);
            try writer.writeByte('"');
        }
    }

    if (!wrote_one) {
        return null;
    }
    return resolved orelse font_metrics.fallback;
}

/// Rounds to `digits` significant digits, which is how Chrome prints a
/// computed size: `1cm` comes back as `37.7953px`, not the full expansion.
fn significant(value: f64, digits: u8) f64 {
    if (value == 0 or !std.math.isFinite(value)) {
        return value;
    }
    const magnitude = @floor(@log10(@abs(value)));
    const shift = @as(f64, @floatFromInt(digits - 1)) - magnitude;
    if (shift > 300 or shift < -300) {
        return value;
    }
    const factor = std.math.pow(f64, 10, shift);
    return @round(value * factor) / factor;
}

const testing = std.testing;

fn expectParse(input: []const u8, expected_css: []const u8, expected_size: f64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = parse(arena.allocator(), input, null) orelse {
        std.debug.print("rejected: {s}\n", .{input});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(expected_css, parsed.css);
    try testing.expectApproxEqAbs(expected_size, parsed.size, 0.0001);
}

test "font: normalises the way Chrome does" {
    // Every expectation here is a measured Chrome answer, from
    // sections.text.fontShorthand* of the graphics dump.
    try expectParse("10px sans-serif", "10px sans-serif", 10);
    try expectParse("14px Arial", "14px Arial", 14);
    try expectParse("bold 12px serif", "bold 12px serif", 12);
    try expectParse(
        "italic 700 16px/1.5 \"Times New Roman\", serif",
        "italic bold 16px \"Times New Roman\", serif",
        16,
    );
    try expectParse("small-caps 20px monospace", "small-caps 20px monospace", 20);
    try expectParse("1em sans-serif", "10px sans-serif", 10);
    try expectParse("12pt serif", "16px serif", 16);
    try expectParse("xx-large serif", "32px serif", 32);
    try expectParse("16px Arial, sans-serif", "16px Arial, sans-serif", 16);
    try expectParse("900 16px serif", "900 16px serif", 16);
    try expectParse("lighter 16px serif", "100 16px serif", 16);
    try expectParse("bolder 16px serif", "bold 16px serif", 16);
    try expectParse("oblique 16px serif", "italic 16px serif", 16);
    try expectParse("normal normal normal 16px serif", "16px serif", 16);
    try expectParse("16px \"Foo Bar\"", "16px \"Foo Bar\"", 16);
    try expectParse("16px 'Single'", "16px Single", 16);
    try expectParse("16px Foo Bar", "16px \"Foo Bar\"", 16);
    try expectParse("2rem serif", "32px serif", 32);
    try expectParse("150% serif", "15px serif", 15);
    try expectParse("larger serif", "12px serif", 12);
    try expectParse("smaller serif", "8.33333px serif", 8.3333333);
    try expectParse("1in serif", "96px serif", 96);
    try expectParse("1cm serif", "37.7953px serif", 37.795275);
    try expectParse("1pc serif", "16px serif", 16);
    try expectParse("16.5px serif", "16.5px serif", 16.5);
    try expectParse("italic small-caps bold 16px serif", "italic bold small-caps 16px serif", 16);
    try expectParse("  16px   serif  ", "16px serif", 16);
}

test "font: rejects what Chrome rejects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Chrome leaves the previous value in place for each of these.
    for ([_][]const u8{
        "not-a-font",
        "",
        "16px",
        "bold serif",
        "oblique 30deg 16px serif",
        "condensed 16px serif",
        "inherit",
        "16px ,serif",
    }) |input| {
        if (parse(arena.allocator(), input, null) != null) {
            std.debug.print("accepted: {s}\n", .{input});
            return error.TestUnexpectedResult;
        }
    }
}

test "font: resolves the family table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // An unresolvable first name moves on to the next.
    const chained = parse(arena.allocator(), "16px NoSuchFamily, monospace", null).?;
    try testing.expectEqual(font_metrics.monospace.glyphs.ptr, chained.family.glyphs.ptr);

    // A list we know nothing about lands on Chrome's standard font, which
    // measurement shows is the serif face.
    const unknown = parse(arena.allocator(), "16px NoSuchFamily12345", null).?;
    try testing.expectEqual(font_metrics.serif.glyphs.ptr, unknown.family.glyphs.ptr);
}
