// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const Io = std.Io;

pub fn isHexColor(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }

    if (value[0] != '#') {
        return false;
    }

    const hex_part = value[1..];
    switch (hex_part.len) {
        3, 4, 6, 8 => for (hex_part) |c| if (!std.ascii.isHex(c)) return false,
        else => return false,
    }

    return true;
}

pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    /// Opaque by default.
    a: u8 = std.math.maxInt(u8),

    pub const Named = struct {
        // Basic colors (CSS Level 1)
        pub const black: RGBA = .init(0, 0, 0, 1);
        pub const silver: RGBA = .init(192, 192, 192, 1);
        pub const gray: RGBA = .init(128, 128, 128, 1);
        pub const white: RGBA = .init(255, 255, 255, 1);
        pub const maroon: RGBA = .init(128, 0, 0, 1);
        pub const red: RGBA = .init(255, 0, 0, 1);
        pub const purple: RGBA = .init(128, 0, 128, 1);
        pub const fuchsia: RGBA = .init(255, 0, 255, 1);
        pub const green: RGBA = .init(0, 128, 0, 1);
        pub const lime: RGBA = .init(0, 255, 0, 1);
        pub const olive: RGBA = .init(128, 128, 0, 1);
        pub const yellow: RGBA = .init(255, 255, 0, 1);
        pub const navy: RGBA = .init(0, 0, 128, 1);
        pub const blue: RGBA = .init(0, 0, 255, 1);
        pub const teal: RGBA = .init(0, 128, 128, 1);
        pub const aqua: RGBA = .init(0, 255, 255, 1);

        // Extended colors (CSS Level 2+)
        pub const aliceblue: RGBA = .init(240, 248, 255, 1);
        pub const antiquewhite: RGBA = .init(250, 235, 215, 1);
        pub const aquamarine: RGBA = .init(127, 255, 212, 1);
        pub const azure: RGBA = .init(240, 255, 255, 1);
        pub const beige: RGBA = .init(245, 245, 220, 1);
        pub const bisque: RGBA = .init(255, 228, 196, 1);
        pub const blanchedalmond: RGBA = .init(255, 235, 205, 1);
        pub const blueviolet: RGBA = .init(138, 43, 226, 1);
        pub const brown: RGBA = .init(165, 42, 42, 1);
        pub const burlywood: RGBA = .init(222, 184, 135, 1);
        pub const cadetblue: RGBA = .init(95, 158, 160, 1);
        pub const chartreuse: RGBA = .init(127, 255, 0, 1);
        pub const chocolate: RGBA = .init(210, 105, 30, 1);
        pub const coral: RGBA = .init(255, 127, 80, 1);
        pub const cornflowerblue: RGBA = .init(100, 149, 237, 1);
        pub const cornsilk: RGBA = .init(255, 248, 220, 1);
        pub const crimson: RGBA = .init(220, 20, 60, 1);
        pub const cyan: RGBA = .init(0, 255, 255, 1); // Synonym of aqua
        pub const darkblue: RGBA = .init(0, 0, 139, 1);
        pub const darkcyan: RGBA = .init(0, 139, 139, 1);
        pub const darkgoldenrod: RGBA = .init(184, 134, 11, 1);
        pub const darkgray: RGBA = .init(169, 169, 169, 1);
        pub const darkgreen: RGBA = .init(0, 100, 0, 1);
        pub const darkgrey: RGBA = .init(169, 169, 169, 1); // Synonym of darkgray
        pub const darkkhaki: RGBA = .init(189, 183, 107, 1);
        pub const darkmagenta: RGBA = .init(139, 0, 139, 1);
        pub const darkolivegreen: RGBA = .init(85, 107, 47, 1);
        pub const darkorange: RGBA = .init(255, 140, 0, 1);
        pub const darkorchid: RGBA = .init(153, 50, 204, 1);
        pub const darkred: RGBA = .init(139, 0, 0, 1);
        pub const darksalmon: RGBA = .init(233, 150, 122, 1);
        pub const darkseagreen: RGBA = .init(143, 188, 143, 1);
        pub const darkslateblue: RGBA = .init(72, 61, 139, 1);
        pub const darkslategray: RGBA = .init(47, 79, 79, 1);
        pub const darkslategrey: RGBA = .init(47, 79, 79, 1); // Synonym of darkslategray
        pub const darkturquoise: RGBA = .init(0, 206, 209, 1);
        pub const darkviolet: RGBA = .init(148, 0, 211, 1);
        pub const deeppink: RGBA = .init(255, 20, 147, 1);
        pub const deepskyblue: RGBA = .init(0, 191, 255, 1);
        pub const dimgray: RGBA = .init(105, 105, 105, 1);
        pub const dimgrey: RGBA = .init(105, 105, 105, 1); // Synonym of dimgray
        pub const dodgerblue: RGBA = .init(30, 144, 255, 1);
        pub const firebrick: RGBA = .init(178, 34, 34, 1);
        pub const floralwhite: RGBA = .init(255, 250, 240, 1);
        pub const forestgreen: RGBA = .init(34, 139, 34, 1);
        pub const gainsboro: RGBA = .init(220, 220, 220, 1);
        pub const ghostwhite: RGBA = .init(248, 248, 255, 1);
        pub const gold: RGBA = .init(255, 215, 0, 1);
        pub const goldenrod: RGBA = .init(218, 165, 32, 1);
        pub const greenyellow: RGBA = .init(173, 255, 47, 1);
        pub const grey: RGBA = .init(128, 128, 128, 1); // Synonym of gray
        pub const honeydew: RGBA = .init(240, 255, 240, 1);
        pub const hotpink: RGBA = .init(255, 105, 180, 1);
        pub const indianred: RGBA = .init(205, 92, 92, 1);
        pub const indigo: RGBA = .init(75, 0, 130, 1);
        pub const ivory: RGBA = .init(255, 255, 240, 1);
        pub const khaki: RGBA = .init(240, 230, 140, 1);
        pub const lavender: RGBA = .init(230, 230, 250, 1);
        pub const lavenderblush: RGBA = .init(255, 240, 245, 1);
        pub const lawngreen: RGBA = .init(124, 252, 0, 1);
        pub const lemonchiffon: RGBA = .init(255, 250, 205, 1);
        pub const lightblue: RGBA = .init(173, 216, 230, 1);
        pub const lightcoral: RGBA = .init(240, 128, 128, 1);
        pub const lightcyan: RGBA = .init(224, 255, 255, 1);
        pub const lightgoldenrodyellow: RGBA = .init(250, 250, 210, 1);
        pub const lightgray: RGBA = .init(211, 211, 211, 1);
        pub const lightgreen: RGBA = .init(144, 238, 144, 1);
        pub const lightgrey: RGBA = .init(211, 211, 211, 1); // Synonym of lightgray
        pub const lightpink: RGBA = .init(255, 182, 193, 1);
        pub const lightsalmon: RGBA = .init(255, 160, 122, 1);
        pub const lightseagreen: RGBA = .init(32, 178, 170, 1);
        pub const lightskyblue: RGBA = .init(135, 206, 250, 1);
        pub const lightslategray: RGBA = .init(119, 136, 153, 1);
        pub const lightslategrey: RGBA = .init(119, 136, 153, 1); // Synonym of lightslategray
        pub const lightsteelblue: RGBA = .init(176, 196, 222, 1);
        pub const lightyellow: RGBA = .init(255, 255, 224, 1);
        pub const limegreen: RGBA = .init(50, 205, 50, 1);
        pub const linen: RGBA = .init(250, 240, 230, 1);
        pub const magenta: RGBA = .init(255, 0, 255, 1); // Synonym of fuchsia
        pub const mediumaquamarine: RGBA = .init(102, 205, 170, 1);
        pub const mediumblue: RGBA = .init(0, 0, 205, 1);
        pub const mediumorchid: RGBA = .init(186, 85, 211, 1);
        pub const mediumpurple: RGBA = .init(147, 112, 219, 1);
        pub const mediumseagreen: RGBA = .init(60, 179, 113, 1);
        pub const mediumslateblue: RGBA = .init(123, 104, 238, 1);
        pub const mediumspringgreen: RGBA = .init(0, 250, 154, 1);
        pub const mediumturquoise: RGBA = .init(72, 209, 204, 1);
        pub const mediumvioletred: RGBA = .init(199, 21, 133, 1);
        pub const midnightblue: RGBA = .init(25, 25, 112, 1);
        pub const mintcream: RGBA = .init(245, 255, 250, 1);
        pub const mistyrose: RGBA = .init(255, 228, 225, 1);
        pub const moccasin: RGBA = .init(255, 228, 181, 1);
        pub const navajowhite: RGBA = .init(255, 222, 173, 1);
        pub const oldlace: RGBA = .init(253, 245, 230, 1);
        pub const olivedrab: RGBA = .init(107, 142, 35, 1);
        pub const orange: RGBA = .init(255, 165, 0, 1);
        pub const orangered: RGBA = .init(255, 69, 0, 1);
        pub const orchid: RGBA = .init(218, 112, 214, 1);
        pub const palegoldenrod: RGBA = .init(238, 232, 170, 1);
        pub const palegreen: RGBA = .init(152, 251, 152, 1);
        pub const paleturquoise: RGBA = .init(175, 238, 238, 1);
        pub const palevioletred: RGBA = .init(219, 112, 147, 1);
        pub const papayawhip: RGBA = .init(255, 239, 213, 1);
        pub const peachpuff: RGBA = .init(255, 218, 185, 1);
        pub const peru: RGBA = .init(205, 133, 63, 1);
        pub const pink: RGBA = .init(255, 192, 203, 1);
        pub const plum: RGBA = .init(221, 160, 221, 1);
        pub const powderblue: RGBA = .init(176, 224, 230, 1);
        pub const rebeccapurple: RGBA = .init(102, 51, 153, 1);
        pub const rosybrown: RGBA = .init(188, 143, 143, 1);
        pub const royalblue: RGBA = .init(65, 105, 225, 1);
        pub const saddlebrown: RGBA = .init(139, 69, 19, 1);
        pub const salmon: RGBA = .init(250, 128, 114, 1);
        pub const sandybrown: RGBA = .init(244, 164, 96, 1);
        pub const seagreen: RGBA = .init(46, 139, 87, 1);
        pub const seashell: RGBA = .init(255, 245, 238, 1);
        pub const sienna: RGBA = .init(160, 82, 45, 1);
        pub const skyblue: RGBA = .init(135, 206, 235, 1);
        pub const slateblue: RGBA = .init(106, 90, 205, 1);
        pub const slategray: RGBA = .init(112, 128, 144, 1);
        pub const slategrey: RGBA = .init(112, 128, 144, 1); // Synonym of slategray
        pub const snow: RGBA = .init(255, 250, 250, 1);
        pub const springgreen: RGBA = .init(0, 255, 127, 1);
        pub const steelblue: RGBA = .init(70, 130, 180, 1);
        pub const tan: RGBA = .init(210, 180, 140, 1);
        pub const thistle: RGBA = .init(216, 191, 216, 1);
        pub const tomato: RGBA = .init(255, 99, 71, 1);
        pub const transparent: RGBA = .init(0, 0, 0, 0);
        pub const turquoise: RGBA = .init(64, 224, 208, 1);
        pub const violet: RGBA = .init(238, 130, 238, 1);
        pub const wheat: RGBA = .init(245, 222, 179, 1);
        pub const whitesmoke: RGBA = .init(245, 245, 245, 1);
        pub const yellowgreen: RGBA = .init(154, 205, 50, 1);
    };

    pub fn init(r: u8, g: u8, b: u8, a: f32) RGBA {
        const clamped = std.math.clamp(a, 0, 1);
        return .{ .r = r, .g = g, .b = b, .a = @intFromFloat(clamped * 255) };
    }

    /// Finds a color by its name.
    pub fn find(name: []const u8) ?RGBA {
        const match = std.meta.stringToEnum(std.meta.DeclEnum(Named), name) orelse return null;

        return switch (match) {
            inline else => |comptime_enum| @field(Named, @tagName(comptime_enum)),
        };
    }

    /// Parses a hex color or a named color. The color *functions* live in
    /// `parseStyle`, which is the entry point for the whole grammar.
    pub fn parse(input: []const u8) !RGBA {
        if (!isHexColor(input)) {
            // Try named colors, which are ASCII case insensitive. The longest
            // one is `lightgoldenrodyellow`, so the buffer cannot be the thing
            // that rejects a real name.
            var lower: [32]u8 = undefined;
            if (input.len > lower.len) return error.Invalid;
            return find(std.ascii.lowerString(lower[0..input.len], input)) orelse
                return error.Invalid;
        }

        const slice = input[1..];
        switch (slice.len) {
            // This means the digit for a color is repeated.
            // Given HEX is #f0c, its interpreted the same as #FF00CC.
            3 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            4 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                const a = try std.fmt.parseInt(u8, &.{ slice[3], slice[3] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            // Regular HEX format.
            6 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            8 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                const a = try std.fmt.parseInt(u8, slice[6..8], 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            else => return error.Invalid,
        }
    }

    /// Parses the CSS colour functions that answer back as a hex string or an
    /// `rgba()`: `rgb()`, `rgba()`, `hsl()`, `hsla()` and `hwb()`. The first
    /// four take both the legacy comma syntax and the modern space-separated
    /// one; `hwb()` is modern-only. The functions that answer back as
    /// *themselves* are `Wide`'s, and `calc()` channels, which need an
    /// expression evaluator, are nobody's.
    ///
    /// Out-of-range channels clamp rather than reject, and halves round away
    /// from zero, both of which match what Chrome reads back.
    pub fn parseFunction(input: []const u8) ?RGBA {
        const open = std.mem.indexOfScalar(u8, input, '(') orelse return null;
        if (input.len == 0 or input[input.len - 1] != ')') return null;

        var name_buf: [8]u8 = undefined;
        const raw_name = input[0..open];
        if (raw_name.len > name_buf.len) return null;
        const name = std.ascii.lowerString(name_buf[0..raw_name.len], raw_name);
        const kind: enum { rgb, hsl, hwb } = if (std.mem.eql(u8, name, "rgb") or std.mem.eql(u8, name, "rgba"))
            .rgb
        else if (std.mem.eql(u8, name, "hsl") or std.mem.eql(u8, name, "hsla"))
            .hsl
        else if (std.mem.eql(u8, name, "hwb"))
            .hwb
        else
            return null;

        const args = input[open + 1 .. input.len - 1];
        // A nested function would need its own parser, and none of the ones we
        // accept take one.
        if (std.mem.indexOfScalar(u8, args, '(') != null) return null;

        // Legacy and modern syntax cannot be mixed, so the presence of a comma
        // picks the separator outright.
        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        if (std.mem.indexOfScalar(u8, args, ',') != null) {
            // `hwb()` postdates the comma form and never took it.
            if (kind == .hwb) return null;
            if (std.mem.indexOfScalar(u8, args, '/') != null) return null;
            var it = std.mem.splitScalar(u8, args, ',');
            while (it.next()) |part| {
                if (count == parts.len) return null;
                parts[count] = std.mem.trim(u8, part, &std.ascii.whitespace);
                count += 1;
            }
        } else {
            // The modern syntax separates the alpha with a slash, which may or
            // may not have whitespace around it.
            var it = std.mem.tokenizeAny(u8, args, " \t\r\n/");
            const slash = std.mem.indexOfScalar(u8, args, '/');
            while (it.next()) |part| {
                if (count == parts.len) return null;
                parts[count] = part;
                count += 1;
            }
            // A slash is only ever the 3-then-1 separator.
            if (slash != null and count != 4) return null;
            if (slash == null and count == 4) return null;
        }
        if (count != 3 and count != 4) return null;

        const alpha: u8 = if (count == 4)
            round255((parseAlpha(parts[3]) orelse return null) * 255)
        else
            255;

        var rgba = switch (kind) {
            .rgb => parseRgbChannels(parts[0..3]),
            .hsl => parseHslChannels(parts[0..3]),
            .hwb => parseHwbChannels(parts[0..3]),
        } orelse return null;
        rgba.a = alpha;
        return rgba;
    }

    fn parseRgbChannels(parts: []const []const u8) ?RGBA {
        // Percentages are all-or-nothing across the three channels, though
        // `none` sits outside that rule.
        var percents: usize = 0;
        var numbers: usize = 0;
        var channels: [3]u8 = undefined;
        for (parts, 0..) |part, i| {
            if (std.ascii.eqlIgnoreCase(part, "none")) {
                channels[i] = 0;
                continue;
            }
            if (std.mem.endsWith(u8, part, "%")) {
                percents += 1;
                const pct = parseNumber(part[0 .. part.len - 1]) orelse return null;
                channels[i] = round255(pct / 100 * 255);
            } else {
                numbers += 1;
                const n = parseNumber(part) orelse return null;
                channels[i] = round255(n);
            }
        }
        if (percents != 0 and numbers != 0) return null;
        return .{ .r = channels[0], .g = channels[1], .b = channels[2], .a = 255 };
    }

    fn parseHslChannels(parts: []const []const u8) ?RGBA {
        const hue = parseHue(parts[0]) orelse return null;
        const s = parsePercent(parts[1]) orelse return null;
        const l = parsePercent(parts[2]) orelse return null;
        return fromUnit(hslToRgb(hue, s, l));
    }

    fn parseHwbChannels(parts: []const []const u8) ?RGBA {
        const hue = parseHue(parts[0]) orelse return null;
        const w = parsePercent(parts[1]) orelse return null;
        const b = parsePercent(parts[2]) orelse return null;
        return fromUnit(hwbToRgb(hue, w, b));
    }

    /// Three channels on the 0..1 scale as an opaque colour.
    fn fromUnit(rgb: [3]f64) RGBA {
        return .{
            .r = round255(rgb[0] * 255),
            .g = round255(rgb[1] * 255),
            .b = round255(rgb[2] * 255),
            .a = 255,
        };
    }

    /// A hue is a bare number or an angle, and it is not clamped — it wraps.
    fn parseHue(part: []const u8) ?f64 {
        const units = [_]struct { []const u8, f64 }{
            .{ "deg", 1 },
            .{ "grad", 0.9 },
            .{ "rad", 180.0 / std.math.pi },
            .{ "turn", 360 },
        };
        for (units) |unit| {
            const suffix, const scale = unit;
            if (part.len > suffix.len and std.ascii.endsWithIgnoreCase(part, suffix)) {
                const n = parseNumber(part[0 .. part.len - suffix.len]) orelse return null;
                return n * scale;
            }
        }
        return parseNumber(part);
    }

    /// Saturation and lightness are percentages, clamped to [0, 1].
    fn parsePercent(part: []const u8) ?f64 {
        if (!std.mem.endsWith(u8, part, "%")) return null;
        const n = parseNumber(part[0 .. part.len - 1]) orelse return null;
        return std.math.clamp(n / 100, 0, 1);
    }

    fn parseAlpha(part: []const u8) ?f64 {
        if (std.ascii.eqlIgnoreCase(part, "none")) return 0;
        if (std.mem.endsWith(u8, part, "%")) {
            const n = parseNumber(part[0 .. part.len - 1]) orelse return null;
            return std.math.clamp(n / 100, 0, 1);
        }
        const n = parseNumber(part) orelse return null;
        return std.math.clamp(n, 0, 1);
    }

    fn parseNumber(part: []const u8) ?f64 {
        if (part.len == 0) return null;
        const n = std.fmt.parseFloat(f64, part) catch return null;
        if (std.math.isNan(n) or std.math.isInf(n)) return null;
        return n;
    }

    /// A channel already on the 0..255 scale as the byte a browser answers:
    /// rounded half away from zero, which is what makes `rgb(2.5)` a 3 and
    /// `50%` a 128.
    pub fn round255(value: f64) u8 {
        return @intFromFloat(std.math.clamp(@round(value), 0, 255));
    }

    /// The 7-character lowercase hex form, alpha discarded. This is what
    /// `<input type=color>` reads back, and it is not `format`'s job: that one
    /// switches to `rgba()` when the color is translucent.
    pub fn toHex(self: RGBA) [7]u8 {
        const digits = "0123456789abcdef";
        return .{
            '#',
            digits[self.r >> 4],
            digits[self.r & 15],
            digits[self.g >> 4],
            digits[self.g & 15],
            digits[self.b >> 4],
            digits[self.b & 15],
        };
    }

    /// By default, browsers prefer lowercase formatting.
    const format_upper = false;

    /// Formats the `Color` according to web expectations.
    /// If color is opaque, HEX is preferred; RGBA otherwise.
    pub fn format(self: *const RGBA, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.isOpaque()) {
            // Convert RGB to HEX.
            // https://gristle.tripod.com/hexconv.html
            // Hexadecimal characters up to 15.
            const char: []const u8 = "0123456789" ++ if (format_upper) "ABCDEF" else "abcdef";
            // This variant always prefers 6 digit format, +1 is for hash char.
            const buffer = [7]u8{
                '#',
                char[self.r >> 4],
                char[self.r & 15],
                char[self.g >> 4],
                char[self.g & 15],
                char[self.b >> 4],
                char[self.b & 15],
            };

            return writer.writeAll(&buffer);
        }

        // Prefer RGBA format for everything else.
        try writer.print("rgba({d}, {d}, {d}, ", .{ self.r, self.g, self.b });
        try writeAlpha(writer, self.a);
        return writer.writeByte(')');
    }

    /// Returns true if `Color` is opaque.
    pub inline fn isOpaque(self: *const RGBA) bool {
        return self.a == std.math.maxInt(u8);
    }

    /// Returns the normalized alpha value.
    pub inline fn normalizedAlpha(self: *const RGBA) f32 {
        return @as(f32, @floatFromInt(self.a)) / 255;
    }
};

/// A parsed color: the bytes to paint with, plus — when the notation is one of
/// the five functions a browser answers back as *itself* — enough of the source
/// to write it back. See `Wide`.
pub const Style = struct {
    rgba: RGBA,
    wide: ?Wide = null,
};

/// The whole grammar this engine reads: a hex form, a named color, or any of
/// the color functions. Surrounding whitespace is trimmed and a name matched
/// case insensitively, both measured on a canvas `fillStyle` where ` red `,
/// `RED` and ` rgb(1,2,3) ` all read. `currentColor` is *not* here: what it
/// resolves to depends on the caller, so the caller resolves it.
pub fn parseStyle(input: []const u8) ?Style {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) {
        if (RGBA.parseFunction(trimmed)) |rgba| return .{ .rgba = rgba };
        const wide = Wide.parse(trimmed) orelse return null;
        return .{ .rgba = wide.toRGBA(), .wide = wide };
    }
    return .{ .rgba = RGBA.parse(trimmed) catch return null };
}

/// The alpha a browser writes back is the shortest one, two or three decimal
/// number that rounds to the same alpha byte — measured over fifty alphas,
/// which is what makes 221/255 `0.867`, 158/255 `0.62`, 128/255 `0.5` and
/// anything under half a byte a plain `0`. Three decimals always round-trip
/// (their spacing is finer than a byte), so the loop always answers.
pub fn writeAlpha(writer: *Io.Writer, alpha: u8) Io.Writer.Error!void {
    if (alpha == 0) {
        return writer.writeByte('0');
    }
    const exact = @as(f64, @floatFromInt(alpha)) / 255.0;
    for ([_]f64{ 10, 100, 1000 }, 1..) |scale, places| {
        const rounded = @round(exact * scale);
        if (rounded >= scale) {
            // Would answer `1`, which no alpha under 255 can round back to.
            continue;
        }
        if (RGBA.round255(rounded / scale * 255.0) != alpha) {
            continue;
        }
        const digits: u32 = @intFromFloat(rounded);
        switch (places) {
            1 => try writer.print("0.{d}", .{digits}),
            2 => try writer.print("0.{d:0>2}", .{digits}),
            else => try writer.print("0.{d:0>3}", .{digits}),
        }
        return;
    }
    unreachable;
}

/// HSL to RGB, each channel on the 0..1 scale, with the hue wrapped into
/// [0, 360) first.
///
/// The chroma/match formulation, not CSS Color 4's `f(n)` one: the two agree to
/// within a ULP, and switching to the spec's does not buy a reading — measured,
/// it moves `hwb(200 10% 20%)`'s green from 144.49999999999997 to
/// 144.4999999999999, which rounds the same way and still is not Chrome's 145.
pub fn hslToRgb(hue: f64, saturation: f64, lightness: f64) [3]f64 {
    const h = @mod(hue, 360.0);
    const c = (1 - @abs(2 * lightness - 1)) * saturation;
    const segment = h / 60.0;
    const x = c * (1 - @abs(@mod(segment, 2.0) - 1));
    const m = lightness - c / 2;
    const triple: [3]f64 = switch (@as(u8, @intFromFloat(@min(5, @floor(segment))))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    return .{ triple[0] + m, triple[1] + m, triple[2] + m };
}

/// HWB to RGB. Measured: a whiteness and blackness summing past 100% is the
/// grey between them — `hwb(120 50% 60%)` answers `rgb(116, 116, 116)`.
pub fn hwbToRgb(hue: f64, whiteness: f64, blackness: f64) [3]f64 {
    if (whiteness + blackness >= 1) {
        const grey = whiteness / (whiteness + blackness);
        return .{ grey, grey, grey };
    }
    const base = hslToRgb(hue, 1, 0.5);
    var out: [3]f64 = undefined;
    for (base, 0..) |channel, at| {
        out[at] = channel * (1 - whiteness - blackness) + whiteness;
    }
    return out;
}

/// A colour written in one of the five functions a browser answers back as
/// *itself* rather than as a hex string or an `rgba()`: `lab()`, `lch()`,
/// `oklab()`, `oklch()` and `color()`. Measured on headed Chrome by
/// tools/fingerprint/probes/canvas-color-notation.js — every other notation
/// collapses, these five do not, so a caller that has to answer the style back
/// (a canvas `fillStyle`) keeps one of these next to the RGBA it paints with.
///
/// The struct is deliberately plain data with no slices in it: a canvas can
/// hold it by value and its save/restore stack can copy it, with no arena and
/// no lifetime to get wrong.
pub const Wide = struct {
    function: Function,
    /// Read only when `function` is `.color`.
    space: Space,
    channels: [3]Channel,
    /// Null when the notation carried no alpha at all, which is the form Chrome
    /// writes without the `/ a` part — as it also does for an alpha of one.
    alpha: ?Channel,

    pub const Function = enum { lab, lch, oklab, oklch, color };

    /// The colour spaces `color()` takes. `xyz` is a shorthand Chrome answers
    /// as `xyz-d65`, so it is not a member.
    pub const Space = enum {
        srgb,
        @"srgb-linear",
        @"display-p3",
        @"a98-rgb",
        @"prophoto-rgb",
        rec2020,
        @"xyz-d65",
        @"xyz-d50",
    };

    /// A channel as written. `none` is kept rather than folded to zero because
    /// Chrome writes it back as `none`.
    pub const Channel = union(enum) {
        none,
        number: f64,

        fn value(self: Channel) f64 {
            return switch (self) {
                .none => 0,
                .number => |n| n,
            };
        }
    };

    /// What a channel means, which is all that separates the five functions
    /// from each other at parse time.
    const Shape = struct {
        /// What a hundred percent is worth on this channel.
        percent: f64,
        /// Inclusive bounds, or null for a channel that is left as written —
        /// measured: `lab(150 40 30)` answers `lab(100 40 30)` while
        /// `color(srgb 1.5 -0.5 0.5)` is answered whole.
        min: ?f64 = null,
        max: ?f64 = null,
        /// A hue: takes an angle unit and wraps into [0, 360).
        hue: bool = false,
    };

    fn shapes(function: Function) [3]Shape {
        return switch (function) {
            .lab => .{
                .{ .percent = 100, .min = 0, .max = 100 },
                .{ .percent = 125 },
                .{ .percent = 125 },
            },
            .lch => .{
                .{ .percent = 100, .min = 0, .max = 100 },
                .{ .percent = 150, .min = 0 },
                .{ .percent = 100, .hue = true },
            },
            .oklab => .{
                .{ .percent = 1, .min = 0, .max = 1 },
                .{ .percent = 0.4 },
                .{ .percent = 0.4 },
            },
            .oklch => .{
                .{ .percent = 1, .min = 0, .max = 1 },
                .{ .percent = 0.4, .min = 0 },
                .{ .percent = 100, .hue = true },
            },
            .color => .{
                .{ .percent = 1 },
                .{ .percent = 1 },
                .{ .percent = 1 },
            },
        };
    }

    /// Parses one of the five. All of them take the space-separated grammar
    /// only: measured, `lab(50, 40, 30)` and `color(display-p3, 1, 0, 0)` are
    /// both rejected, and the alpha is always introduced by a slash.
    pub fn parse(input: []const u8) ?Wide {
        const open = std.mem.indexOfScalar(u8, input, '(') orelse return null;
        if (input[input.len - 1] != ')') return null;

        var name_buf: [8]u8 = undefined;
        if (open == 0 or open > name_buf.len) return null;
        const name = std.ascii.lowerString(name_buf[0..open], input[0..open]);
        const function = std.meta.stringToEnum(Function, name) orelse return null;

        const args = input[open + 1 .. input.len - 1];
        // A comma is the legacy grammar and a nested call needs its own parser.
        if (std.mem.indexOfAny(u8, args, ",(") != null) return null;

        // The alpha, if any, is everything past the one slash.
        const slash = std.mem.indexOfScalar(u8, args, '/');
        const head = if (slash) |at| args[0..at] else args;
        const tail = if (slash) |at| args[at + 1 ..] else null;
        if (tail) |t| if (std.mem.indexOfScalar(u8, t, '/') != null) return null;

        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, head, &std.ascii.whitespace);
        while (it.next()) |part| {
            if (count == parts.len) return null;
            parts[count] = part;
            count += 1;
        }

        var space: Space = .srgb;
        var first: usize = 0;
        if (function == .color) {
            if (count == 0) return null;
            var ident_buf: [16]u8 = undefined;
            const ident = parts[0];
            if (ident.len > ident_buf.len) return null;
            const lower = std.ascii.lowerString(ident_buf[0..ident.len], ident);
            space = if (std.mem.eql(u8, lower, "xyz"))
                .@"xyz-d65"
            else
                std.meta.stringToEnum(Space, lower) orelse return null;
            first = 1;
        }
        if (count != first + 3) return null;

        var wide: Wide = .{
            .function = function,
            .space = space,
            .channels = undefined,
            .alpha = null,
        };
        for (shapes(function), 0..) |shape, at| {
            wide.channels[at] = parseChannel(parts[first + at], shape) orelse return null;
        }
        if (tail) |t| {
            const trimmed = std.mem.trim(u8, t, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(trimmed, "none")) {
                wide.alpha = .none;
            } else {
                const a = RGBA.parseAlpha(trimmed) orelse return null;
                // An alpha of one is the same string as no alpha at all.
                wide.alpha = if (a == 1) null else .{ .number = a };
            }
        }
        return wide;
    }

    fn parseChannel(part: []const u8, shape: Shape) ?Channel {
        if (std.ascii.eqlIgnoreCase(part, "none")) return .none;
        var n = if (shape.hue)
            RGBA.parseHue(part) orelse return null
        else if (std.mem.endsWith(u8, part, "%"))
            (RGBA.parseNumber(part[0 .. part.len - 1]) orelse return null) * shape.percent / 100
        else
            RGBA.parseNumber(part) orelse return null;
        if (shape.hue) n = @mod(n, 360);
        if (shape.min) |min| n = @max(min, n);
        if (shape.max) |max| n = @min(max, n);
        return .{ .number = n };
    }

    /// The colour as sRGB bytes: through CIE XYZ for every family, gamma
    /// encoded, then clipped into gamut. Three of the results are measured
    /// against Chrome — `color(display-p3 1 0.25 0.5)` is `ff1b7f`,
    /// `lab(50% 40 30)` is `bb5846`, `oklch(0.7 0.1 20)` is `d68585`.
    pub fn toRGBA(self: Wide) RGBA {
        const c: [3]f64 = .{
            self.channels[0].value(),
            self.channels[1].value(),
            self.channels[2].value(),
        };
        const alpha: u8 = switch (self.alpha orelse Channel{ .number = 1 }) {
            .none => 0,
            .number => |a| RGBA.round255(a * 255),
        };

        // `color(srgb ...)` is already the encoded form, so it skips the round
        // trip through linear light that would only add rounding error.
        if (self.function == .color and self.space == .srgb) {
            return .{
                .r = RGBA.round255(c[0] * 255),
                .g = RGBA.round255(c[1] * 255),
                .b = RGBA.round255(c[2] * 255),
                .a = alpha,
            };
        }

        const linear: [3]f64 = switch (self.function) {
            .lab => labToSrgbLinear(c[0], c[1], c[2]),
            .lch => polar(labToSrgbLinear, c),
            .oklab => oklabToSrgbLinear(c[0], c[1], c[2]),
            .oklch => polar(oklabToSrgbLinear, c),
            .color => switch (self.space) {
                .srgb => unreachable, // handled above
                .@"srgb-linear" => c,
                .@"display-p3" => rgbSpaceToSrgbLinear(display_p3_to_xyz, srgbToLinear, c),
                .@"a98-rgb" => rgbSpaceToSrgbLinear(a98_rgb_to_xyz, a98ToLinear, c),
                .@"prophoto-rgb" => xyzD50ToSrgbLinear(matrixApply(prophoto_rgb_to_xyz_d50, .{
                    prophotoToLinear(c[0]),
                    prophotoToLinear(c[1]),
                    prophotoToLinear(c[2]),
                })),
                .rec2020 => rgbSpaceToSrgbLinear(rec2020_to_xyz, rec2020ToLinear, c),
                .@"xyz-d65" => matrixApply(xyz_to_srgb, c),
                .@"xyz-d50" => xyzD50ToSrgbLinear(c),
            },
        };
        return .{
            .r = RGBA.round255(srgbFromLinear(linear[0]) * 255),
            .g = RGBA.round255(srgbFromLinear(linear[1]) * 255),
            .b = RGBA.round255(srgbFromLinear(linear[2]) * 255),
            .a = alpha,
        };
    }

    /// Formats the colour the way Chrome answers it: the function lowercased,
    /// the channels re-serialised shortest, `none` kept, and the alpha written
    /// only when it is neither absent nor one.
    pub fn format(self: *const Wide, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(@tagName(self.function));
        try writer.writeByte('(');
        if (self.function == .color) {
            try writer.writeAll(@tagName(self.space));
            try writer.writeByte(' ');
        }
        for (self.channels, 0..) |channel, at| {
            if (at != 0) try writer.writeByte(' ');
            try writeChannel(writer, channel);
        }
        if (self.alpha) |alpha| {
            try writer.writeAll(" / ");
            try writeChannel(writer, alpha);
        }
        return writer.writeByte(')');
    }

    fn writeChannel(writer: *Io.Writer, channel: Channel) Io.Writer.Error!void {
        return switch (channel) {
            .none => writer.writeAll("none"),
            .number => |n| writer.print("{d}", .{n}),
        };
    }
};

// ---------------------------------------------------------------------------
// Colour space conversion
//
// Every wide-gamut notation CSS Color 4 defines is a path through CIE XYZ, so
// one matrix each way plus a transfer function covers the whole family. The
// numbers are that spec's; what makes them trustworthy here is that the
// readings they produce are measured against Chrome, one per colour space, in
// src/browser/tests/canvas/canvas_rendering_context_2d.html.
// ---------------------------------------------------------------------------

/// A 3x3 matrix, row major.
const Matrix = [9]f64;

fn matrixApply(m: Matrix, v: [3]f64) [3]f64 {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

const xyz_to_srgb: Matrix = .{
    3.2409699419045226,  -1.537383177570094,   -0.4986107602930034,
    -0.9692436362808796, 1.8759675015077202,   0.04155505740717559,
    0.05563007969699366, -0.20397695888897652, 1.0569715142428786,
};

const display_p3_to_xyz: Matrix = .{
    0.4865709486482162, 0.26566769316909306, 0.1982172852343625,
    0.2289745640697488, 0.6917385218365064,  0.079286914093745,
    0.0,                0.04511338185890264, 1.043944368900976,
};

const a98_rgb_to_xyz: Matrix = .{
    0.5766690429101305,  0.1855582379065463,  0.1882286462349947,
    0.29734497525053605, 0.6273635662554661,  0.07529145849399788,
    0.02703136138641234, 0.07068885253582723, 0.9913375368376388,
};

/// ProPhoto RGB is the one of the family defined against D50.
const prophoto_rgb_to_xyz_d50: Matrix = .{
    0.7977604896723027, 0.13518583717574031, 0.0313493495815248,
    0.2880711282292934, 0.7118432178101014,  0.00008565396060525902,
    0.0,                0.0,                 0.8251046025104601,
};

const rec2020_to_xyz: Matrix = .{
    0.6369580483012914, 0.14461690358620832,  0.16888097516417208,
    0.2627002120112671, 0.6779980715188708,   0.05930171646986196,
    0.0,                0.028072693049087428, 1.060985057710791,
};

/// Bradford adapted, which is the adaptation CSS Color 4 specifies.
const xyz_d50_to_d65: Matrix = .{
    0.9554734527042182,    -0.023098536874261423, 0.0632593086610217,
    -0.028369706963208136, 1.0099954580058226,    0.021041398966943008,
    0.012314001688319899,  -0.020507696433477912, 1.3303659366080753,
};

const oklab_to_lms: Matrix = .{
    1.0, 0.3963377773761749,  0.2158037573099136,
    1.0, -0.1055613458156586, -0.0638541728258133,
    1.0, -0.0894841775298119, -1.2914855480194092,
};

const lms_to_srgb_linear: Matrix = .{
    4.0767416360759583,  -3.3077115392580616, 0.2309699031821043,
    -1.2684380040921763, 2.6097574006633715,  -0.3413193963102197,
    -0.0041960761386756, -0.7034186179359362, 1.7076146940746117,
};

/// The D50 white point Lab and ProPhoto RGB are relative to.
const d50_white: [3]f64 = .{ 0.9642956764295677, 1.0, 0.8251046025104602 };

/// Every transfer function here is sign preserving, so a channel outside the
/// gamut keeps its side of zero right up to the clip in `round255`.
fn signOf(v: f64) f64 {
    return if (v < 0) -1 else 1;
}

fn srgbToLinear(v: f64) f64 {
    const a = @abs(v);
    if (a <= 0.04045) return v / 12.92;
    return signOf(v) * std.math.pow(f64, (a + 0.055) / 1.055, 2.4);
}

fn srgbFromLinear(v: f64) f64 {
    const a = @abs(v);
    if (a <= 0.0031308) return v * 12.92;
    return signOf(v) * (1.055 * std.math.pow(f64, a, 1.0 / 2.4) - 0.055);
}

/// A plain 2.2, *not* CSS Color 4's 563/256. Of the five a98 readings measured
/// for this, four cannot tell the two exponents apart; the one that can —
/// `color(a98-rgb 1 0.25 0.5)`, which Chrome answers `ff3d82` — puts the green
/// channel at 61.5017 under 563/256, a thousandth of a byte over the rounding
/// boundary, and at 61.4676 under 2.2. So 2.2 is the measured fit.
fn a98ToLinear(v: f64) f64 {
    return signOf(v) * std.math.pow(f64, @abs(v), 2.2);
}

fn prophotoToLinear(v: f64) f64 {
    const a = @abs(v);
    if (a <= 16.0 / 512.0) return v / 16.0;
    return signOf(v) * std.math.pow(f64, a, 1.8);
}

fn rec2020ToLinear(v: f64) f64 {
    const alpha = 1.09929682680944;
    const beta = 0.018053968510807;
    const a = @abs(v);
    if (a < beta * 4.5) return v / 4.5;
    return signOf(v) * std.math.pow(f64, (a + alpha - 1) / alpha, 1.0 / 0.45);
}

/// One of the gamma-encoded RGB spaces into linear sRGB, via its own primaries.
fn rgbSpaceToSrgbLinear(
    to_xyz: Matrix,
    comptime toLinear: fn (f64) f64,
    encoded: [3]f64,
) [3]f64 {
    return matrixApply(xyz_to_srgb, matrixApply(to_xyz, .{
        toLinear(encoded[0]),
        toLinear(encoded[1]),
        toLinear(encoded[2]),
    }));
}

fn xyzD50ToSrgbLinear(xyz_d50: [3]f64) [3]f64 {
    return matrixApply(xyz_to_srgb, matrixApply(xyz_d50_to_d65, xyz_d50));
}

fn labToSrgbLinear(l: f64, a: f64, b: f64) [3]f64 {
    const kappa = 24389.0 / 27.0;
    const epsilon = 216.0 / 24389.0;
    const fy = (l + 16) / 116;
    const fx = fy + a / 500;
    const fz = fy - b / 200;
    const fx3 = fx * fx * fx;
    const fz3 = fz * fz * fz;
    const xyz_d50: [3]f64 = .{
        (if (fx3 > epsilon) fx3 else (116 * fx - 16) / kappa) * d50_white[0],
        (if (l > 8) fy * fy * fy else l / kappa) * d50_white[1],
        (if (fz3 > epsilon) fz3 else (116 * fz - 16) / kappa) * d50_white[2],
    };
    return xyzD50ToSrgbLinear(xyz_d50);
}

fn oklabToSrgbLinear(l: f64, a: f64, b: f64) [3]f64 {
    var lms = matrixApply(oklab_to_lms, .{ l, a, b });
    for (&lms) |*channel| channel.* = channel.* * channel.* * channel.*;
    return matrixApply(lms_to_srgb_linear, lms);
}

/// The polar spelling of a Lab-shaped space: lightness, chroma, hue.
fn polar(comptime rectangular: fn (f64, f64, f64) [3]f64, lch: [3]f64) [3]f64 {
    const hue = std.math.degreesToRadians(lch[2]);
    return rectangular(lch[0], lch[1] * @cos(hue), lch[1] * @sin(hue));
}

// ---------------------------------------------------------------------------
// Canvas bitmaps
//
// A canvas bitmap and an ImageData each carry one of *two* colour spaces, not
// the whole PredefinedColorSpace family: srgb and display-p3. The conversion
// between them is a colour-space conversion like the ones above, but it runs
// over bytes rather than over a parsed notation — `getImageData` converts the
// pixels it hands back into the space the caller asked for.
// ---------------------------------------------------------------------------

/// The two a canvas bitmap or an ImageData can be in.
pub const CanvasSpace = enum {
    srgb,
    @"display-p3",
};

/// RGBA bytes moved from one canvas space to the other, in place, four at a
/// time. Alpha is not a colour and rides through untouched; the RGB bytes are
/// unpremultiplied on both sides, which is what the measurement says — an
/// `rgba(255, 0, 0, 0.5)` pixel reads back `ff000080` as srgb and `ea332380` as
/// display-p3, so the same conversion the opaque red gets (see the readings in
/// results/canvas-image-data-settings-2.chrome.json).
pub fn convertCanvasPixels(from: CanvasSpace, to: CanvasSpace, bytes: []u8) void {
    if (from == to) {
        return;
    }
    const matrix: Matrix = switch (from) {
        .srgb => srgb_linear_to_p3_linear,
        .@"display-p3" => p3_linear_to_srgb_linear,
    };
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) : (offset += 4) {
        const pixel = bytes[offset..][0..4];
        const linear = matrixApply(matrix, .{
            srgbToLinear(@as(f64, @floatFromInt(pixel[0])) / 255),
            srgbToLinear(@as(f64, @floatFromInt(pixel[1])) / 255),
            srgbToLinear(@as(f64, @floatFromInt(pixel[2])) / 255),
        });
        for (pixel[0..3], linear) |*channel, value| {
            channel.* = RGBA.round255(srgbFromLinear(value) * 255);
        }
    }
}

/// Both canvas spaces share sRGB's transfer function, so the conversion is one
/// matrix: `display_p3_to_xyz` into XYZ and `xyz_to_srgb` back out, composed.
const p3_linear_to_srgb_linear: Matrix = matrixMultiply(xyz_to_srgb, display_p3_to_xyz);

/// The other direction, which no matrix above spells: sRGB's own to-XYZ matrix
/// is not one of them, so this is the inverse of the composition rather than a
/// second composition.
const srgb_linear_to_p3_linear: Matrix = matrixInvert(p3_linear_to_srgb_linear);

fn matrixMultiply(a: Matrix, b: Matrix) Matrix {
    var out: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            out[row * 3 + column] =
                a[row * 3] * b[column] +
                a[row * 3 + 1] * b[3 + column] +
                a[row * 3 + 2] * b[6 + column];
        }
    }
    return out;
}

/// Cramer's rule. Every matrix here is a colour-space basis and so invertible.
fn matrixInvert(m: Matrix) Matrix {
    const cofactors: Matrix = .{
        m[4] * m[8] - m[5] * m[7], m[5] * m[6] - m[3] * m[8], m[3] * m[7] - m[4] * m[6],
        m[2] * m[7] - m[1] * m[8], m[0] * m[8] - m[2] * m[6], m[1] * m[6] - m[0] * m[7],
        m[1] * m[5] - m[2] * m[4], m[2] * m[3] - m[0] * m[5], m[0] * m[4] - m[1] * m[3],
    };
    const determinant = m[0] * cofactors[0] + m[1] * cofactors[1] + m[2] * cofactors[2];
    var out: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            // Transposed on the way out: the adjugate is the cofactor matrix's
            // transpose.
            out[row * 3 + column] = cofactors[column * 3 + row] / determinant;
        }
    }
    return out;
}

test "color: canvas space conversion matches Chrome's own readbacks" {
    // Every pair measured on a headed Chrome 150 by painting an srgb canvas and
    // reading it back in both spaces
    // (results/canvas-image-data-settings-2.chrome.json). The matrices are
    // derived rather than transcribed, so these are what pin them.
    const cases = [_]struct { srgb: [4]u8, p3: [4]u8 }{
        .{ .srgb = .{ 0xff, 0x00, 0x00, 0xff }, .p3 = .{ 0xea, 0x33, 0x23, 0xff } },
        .{ .srgb = .{ 0x00, 0xff, 0x00, 0xff }, .p3 = .{ 0x75, 0xfb, 0x4c, 0xff } },
        .{ .srgb = .{ 0x00, 0x00, 0xff, 0xff }, .p3 = .{ 0x00, 0x00, 0xf5, 0xff } },
        .{ .srgb = .{ 0x80, 0x80, 0x80, 0xff }, .p3 = .{ 0x80, 0x80, 0x80, 0xff } },
        .{ .srgb = .{ 0xff, 0x1b, 0x7f, 0xff }, .p3 = .{ 0xea, 0x3b, 0x7f, 0xff } },
        .{ .srgb = .{ 0xff, 0xff, 0xff, 0xff }, .p3 = .{ 0xff, 0xff, 0xff, 0xff } },
        .{ .srgb = .{ 0x00, 0x00, 0x00, 0xff }, .p3 = .{ 0x00, 0x00, 0x00, 0xff } },
        // Alpha is carried, not converted.
        .{ .srgb = .{ 0xff, 0x00, 0x00, 0x80 }, .p3 = .{ 0xea, 0x33, 0x23, 0x80 } },
        .{ .srgb = .{ 0x00, 0x00, 0x00, 0x00 }, .p3 = .{ 0x00, 0x00, 0x00, 0x00 } },
    };
    for (cases) |case| {
        var out = case.srgb;
        convertCanvasPixels(.srgb, .@"display-p3", &out);
        try std.testing.expectEqualSlices(u8, &case.p3, &out);
    }
    // The other direction, measured on a display-p3 canvas: `ff407f` there is
    // `ff1c7e` read back as srgb, and its own `ea3323` is srgb's pure red.
    var back: [4]u8 = .{ 0xff, 0x40, 0x7f, 0xff };
    convertCanvasPixels(.@"display-p3", .srgb, &back);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x1c, 0x7e, 0xff }, &back);
    back = .{ 0xea, 0x33, 0x23, 0xff };
    convertCanvasPixels(.@"display-p3", .srgb, &back);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x00, 0xff }, &back);
    // More than one pixel at a time, and a tail too short to be one.
    var pair: [8]u8 = .{ 0xff, 0x00, 0x00, 0xff, 0x00, 0x00, 0xff, 0xff };
    convertCanvasPixels(.srgb, .@"display-p3", &pair);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xea, 0x33, 0x23, 0xff, 0x00, 0x00, 0xf5, 0xff },
        &pair,
    );
}
