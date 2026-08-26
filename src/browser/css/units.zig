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

//! Shared lexing and conversion for CSS/SVG dimension values: one suffix
//! table and one set of absolute-length factors. Consumers (svg/Length,
//! svg/Angle, webapi/CSS, StyleManager's font-size resolution) map the
//! result onto their own domain, rejecting units that don't apply.
//!
//! css/MediaQuery keeps its own parser on purpose: MQ4 is fail-closed and
//! deliberately more restrictive than this lenient attribute-value lexer.

const std = @import("std");

pub const Unit = enum {
    none, // bare number, no suffix
    percentage,
    em,
    rem,
    ex,
    ch,
    px,
    cm,
    mm,
    in,
    pt,
    pc,
    vh,
    vw,
    vmin,
    vmax,
    q,
    deg,
    rad,
    grad,
    turn,
};

pub const Parsed = struct {
    value: f64,
    unit: Unit,
};

const WHITESPACE = " \t\r\n\x0c";

// A suffix that ends with another one has to come first, or the shorter entry
// swallows it: "5grad" must not match "rad", "2rem" must not match "em", and
// "10vmin" must not match "in".
const suffixes = [_]struct { []const u8, Unit }{
    .{ "turn", .turn },
    .{ "grad", .grad },
    .{ "vmin", .vmin },
    .{ "vmax", .vmax },
    .{ "rem", .rem },
    .{ "deg", .deg },
    .{ "rad", .rad },
    .{ "%", .percentage },
    .{ "em", .em },
    .{ "ex", .ex },
    .{ "ch", .ch },
    .{ "px", .px },
    .{ "cm", .cm },
    .{ "mm", .mm },
    .{ "in", .in },
    .{ "pt", .pt },
    .{ "pc", .pc },
    .{ "vh", .vh },
    .{ "vw", .vw },
    .{ "q", .q },
};

pub fn parse(input: []const u8) error{SyntaxError}!Parsed {
    const value = std.mem.trim(u8, input, WHITESPACE);
    if (value.len == 0) {
        return error.SyntaxError;
    }

    for (suffixes) |entry| {
        const sfx, const unit = entry;
        if (value.len <= sfx.len) {
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(value[value.len - sfx.len ..], sfx)) {
            continue;
        }
        const number = std.mem.trim(u8, value[0 .. value.len - sfx.len], WHITESPACE);
        return .{ .value = try parseNumber(number), .unit = unit };
    }
    return .{ .value = try parseNumber(value), .unit = .none };
}

fn parseNumber(value: []const u8) !f64 {
    const number = std.fmt.parseFloat(f64, value) catch return error.SyntaxError;
    if (!std.math.isFinite(number)) {
        return error.SyntaxError;
    }
    return number;
}

/// CSS pixels per unit for the absolute length units (CSS Values §6.2,
/// 96px per inch). Null for relative and angle units, which need context.
pub fn absoluteLengthFactor(unit: Unit) ?f64 {
    return switch (unit) {
        .none, .px => 1,
        .cm => 96.0 / 2.54,
        .mm => 96.0 / 25.4,
        .in => 96,
        .pt => 96.0 / 72.0,
        .pc => 16,
        // A quarter-millimetre. Chrome prints 0.944882px for 1Q, which is
        // 96/2.54/40 -- measured, scratch/expr-abs-viewport-units.js.
        .q => 96.0 / 2.54 / 40.0,
        else => null,
    };
}

pub fn suffix(unit: Unit) []const u8 {
    return switch (unit) {
        .none => "",
        .percentage => "%",
        else => @tagName(unit),
    };
}

const testing = @import("../../testing.zig");

// ---------------------------------------------------------------------------
// Number serialisation
// ---------------------------------------------------------------------------

/// `writeNumber` fails only on a number too long to format, which no finite
/// double is; spelled out so the callers that need an explicit error set (the
/// mutually-recursive Typed OM serialisers, the media query one) can name it.
pub const NumberError = error{ StringTooLarge, WriteFailed };

/// A CSS number as printf `%g` writes it: six significant digits,
/// trailing zeros dropped, scientific notation once the exponent leaves
/// [-4, 6), exponent padded to at least two digits. Measured — `1/3` prints
/// `0.333333` while `.value` still reads back the full double, and `999999.9`
/// rounds up into `1e+06`.
pub fn writeNumber(writer: *std.Io.Writer, v: f64) NumberError!void {
    if (std.math.isNan(v)) return writer.writeAll("NaN");
    if (std.math.isInf(v)) return writer.writeAll(if (v > 0) "Infinity" else "-Infinity");
    if (v == 0) return writer.writeAll("0");

    var buf: [64]u8 = undefined;
    // Rounding to five decimals in scientific form first means the exponent we
    // branch on is the post-rounding one, exactly as %g does.
    const formatted = std.fmt.bufPrint(&buf, "{e:.5}", .{v}) catch return error.StringTooLarge;

    var rest = formatted;
    const negative = rest[0] == '-';
    if (negative) rest = rest[1..];

    const e_at = std.mem.indexOfScalar(u8, rest, 'e') orelse return error.StringTooLarge;
    var digits: [6]u8 = undefined;
    var count: usize = 0;
    for (rest[0..e_at]) |c| {
        if (c == '.') continue;
        if (count == digits.len) break;
        digits[count] = c;
        count += 1;
    }
    const exponent = std.fmt.parseInt(i32, rest[e_at + 1 ..], 10) catch return error.StringTooLarge;

    if (negative) try writer.writeAll("-");

    if (exponent < -4 or exponent >= 6) {
        const mantissa = stripTrailingZeros(digits[0..count]);
        try writer.writeAll(mantissa[0..1]);
        if (mantissa.len > 1) {
            try writer.writeAll(".");
            try writer.writeAll(mantissa[1..]);
        }
        const sign: u8 = if (exponent < 0) '-' else '+';
        try writer.print("e{c}{d:0>2}", .{ sign, @abs(exponent) });
        return;
    }

    if (exponent >= 0) {
        const int_len: usize = @intCast(exponent + 1);
        if (int_len >= count) {
            try writer.writeAll(digits[0..count]);
            for (0..int_len - count) |_| try writer.writeAll("0");
            return;
        }
        try writer.writeAll(digits[0..int_len]);
        const fraction = stripFraction(digits[int_len..count]);
        if (fraction.len != 0) {
            try writer.writeAll(".");
            try writer.writeAll(fraction);
        }
        return;
    }

    try writer.writeAll("0.");
    for (0..@intCast(-exponent - 1)) |_| try writer.writeAll("0");
    try writer.writeAll(stripTrailingZeros(digits[0..count]));
}

fn stripTrailingZeros(digits: []const u8) []const u8 {
    var end = digits.len;
    while (end > 1 and digits[end - 1] == '0') end -= 1;
    return digits[0..end];
}

/// Unlike a mantissa, a fraction may strip away entirely: `5px`, not `5.0px`.
fn stripFraction(digits: []const u8) []const u8 {
    var end = digits.len;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    return digits[0..end];
}

test "css units: parse" {
    try testing.expectEqual(Parsed{ .value = 12, .unit = .none }, try parse("12"));
    try testing.expectEqual(Parsed{ .value = -3.5, .unit = .px }, try parse("-3.5px"));
    try testing.expectEqual(Parsed{ .value = 50, .unit = .percentage }, try parse("50%"));
    try testing.expectEqual(Parsed{ .value = 2.54, .unit = .cm }, try parse("2.54cm"));
    try testing.expectEqual(Parsed{ .value = 1.5, .unit = .em }, try parse("1.5EM"));
    try testing.expectEqual(Parsed{ .value = 90, .unit = .deg }, try parse("90deg"));
    try testing.expectEqual(Parsed{ .value = 100, .unit = .grad }, try parse("100grad"));
    try testing.expectEqual(Parsed{ .value = 0.5, .unit = .turn }, try parse("0.5turn"));
    try testing.expectEqual(Parsed{ .value = 50, .unit = .vh }, try parse("50vh"));

    // surrounding whitespace, and the historical leniency between number
    // and suffix, are both accepted
    try testing.expectEqual(Parsed{ .value = 10, .unit = .px }, try parse("  10px "));
    try testing.expectEqual(Parsed{ .value = 10, .unit = .px }, try parse("10 px"));

    try testing.expectError(error.SyntaxError, parse(""));
    try testing.expectError(error.SyntaxError, parse("  "));
    try testing.expectError(error.SyntaxError, parse("px"));
    try testing.expectError(error.SyntaxError, parse("abc"));
    try testing.expectError(error.SyntaxError, parse("10furlong"));
    try testing.expectError(error.SyntaxError, parse("inf"));
    try testing.expectError(error.SyntaxError, parse("nan"));
    try testing.expectError(error.SyntaxError, parse("infpx"));
}

test "css units: absoluteLengthFactor" {
    try testing.expectEqual(1, absoluteLengthFactor(.none).?);
    try testing.expectEqual(1, absoluteLengthFactor(.px).?);
    try testing.expectEqual(96, absoluteLengthFactor(.in).?);
    try testing.expectEqual(16, absoluteLengthFactor(.pc).?);
    try testing.expectEqual(null, absoluteLengthFactor(.percentage));
    try testing.expectEqual(null, absoluteLengthFactor(.em));
    try testing.expectEqual(null, absoluteLengthFactor(.vh));
    try testing.expectEqual(null, absoluteLengthFactor(.deg));
}

test "css units: suffix" {
    try testing.expectEqual("", suffix(.none));
    try testing.expectEqual("%", suffix(.percentage));
    try testing.expectEqual("px", suffix(.px));
    try testing.expectEqual("turn", suffix(.turn));
}
