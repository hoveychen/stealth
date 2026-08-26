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

/// Whether Chrome's CSS colour parser would accept `value` as a colour, and
/// nothing more — no conversion. `parseStyle` below answers the narrower
/// question "and what colour is it", and where the two disagree this one is
/// wider on purpose: a caller that *refuses* an unrecognised colour needs the
/// acceptance set, and refusing a value every browser takes is a worse lie than
/// the silence it replaces. Canvas' `addColorStop` throws a SyntaxError, which
/// is the caller this exists for.
///
/// Measured on Chrome 151 through `addColorStop`, which shares its parser with
/// `fillStyle`: of 40 notations tried, every one `addColorStop` accepted also
/// moved `fillStyle`, and every one it refused left `fillStyle` untouched.
/// Refused there and so refused here: `inherit` / `initial` / `unset` /
/// `revert`, `rgb(1,2)`, `rgb()`, `red red`, `#ff`, `#fffff`, `light-dark(red,
/// blue)` and `contrast-color(red)`.
pub fn isColor(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (parseStyle(trimmed) != null) return true;

    // The three Chrome takes that `parseStyle` does not. `currentColor` is
    // absent from it by design -- what it resolves to depends on the caller --
    // while the system colours and `color-mix()` are simply not read yet.
    // Answering true for a colour we cannot convert is the safe direction: the
    // stop stores no RGBA instead of throwing.
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(').?;
        var name_buf: [9]u8 = undefined;
        if (open > name_buf.len) return false;
        return std.mem.eql(u8, std.ascii.lowerString(name_buf[0..open], trimmed[0..open]), "color-mix");
    }

    // Long enough for `inactivecaptiontext`, the longest of them.
    var buf: [24]u8 = undefined;
    if (trimmed.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..trimmed.len], trimmed);
    if (std.mem.eql(u8, lower, "currentcolor")) return true;
    return systemColor(lower) != null;
}

/// The colour a CSS system keyword resolves to, or null if the name is not one.
/// `name` must already be lowercased.
///
/// Kasada asks for the whole table at x-hyatt — ninety-three
/// `getPropertyValue('color')` calls after setting `color` to each keyword in
/// turn — and a computed `color` that answers `buttonface` rather than
/// `rgb(239, 239, 239)` is one expression no browser produces. The palette is
/// Chrome 151 on macOS in light appearance, measured through that same
/// expression (tools/fingerprint/probes/expr-b55-system-colors.js). It is a
/// platform's palette rather than a constant, the way the voice list and the
/// WebGL renderer string are this machine's; a dark appearance moves all of it.
///
/// `isColor` above is the *acceptance* question and answers true for every name
/// here. Chrome takes `ButtonFace` through canvas' parser and refuses
/// `AccentColor` (measured), a distinction this does not draw: accepting one
/// Chrome refuses leaves today's silence in place, while refusing one Chrome
/// accepts would throw on a valid colour.
pub fn systemColor(name: []const u8) ?RGBA {
    const table = [_]struct { []const u8, RGBA }{
        .{ "accentcolor", .init(0, 117, 255, 1) },
        .{ "accentcolortext", .init(255, 255, 255, 1) },
        .{ "activeborder", .init(0, 0, 0, 1) },
        .{ "activecaption", .init(255, 255, 255, 1) },
        .{ "activetext", .init(255, 0, 0, 1) },
        .{ "appworkspace", .init(255, 255, 255, 1) },
        .{ "background", .init(255, 255, 255, 1) },
        .{ "buttonborder", .init(0, 0, 0, 1) },
        .{ "buttonface", .init(239, 239, 239, 1) },
        .{ "buttonhighlight", .init(239, 239, 239, 1) },
        .{ "buttonshadow", .init(239, 239, 239, 1) },
        .{ "buttontext", .init(0, 0, 0, 1) },
        .{ "canvas", .init(255, 255, 255, 1) },
        .{ "canvastext", .init(0, 0, 0, 1) },
        .{ "captiontext", .init(0, 0, 0, 1) },
        .{ "field", .init(255, 255, 255, 1) },
        .{ "fieldtext", .init(0, 0, 0, 1) },
        .{ "graytext", .init(128, 128, 128, 1) },
        // The one system colour that is not opaque.
        .{ "highlight", .init(128, 188, 254, 0.6) },
        .{ "highlighttext", .init(0, 0, 0, 1) },
        .{ "inactiveborder", .init(0, 0, 0, 1) },
        .{ "inactivecaption", .init(255, 255, 255, 1) },
        .{ "inactivecaptiontext", .init(128, 128, 128, 1) },
        .{ "infobackground", .init(255, 255, 255, 1) },
        .{ "infotext", .init(0, 0, 0, 1) },
        .{ "linktext", .init(0, 0, 238, 1) },
        .{ "mark", .init(255, 255, 0, 1) },
        .{ "marktext", .init(0, 0, 0, 1) },
        .{ "menu", .init(255, 255, 255, 1) },
        .{ "menutext", .init(0, 0, 0, 1) },
        .{ "scrollbar", .init(255, 255, 255, 1) },
        .{ "selecteditem", .init(179, 215, 255, 1) },
        .{ "selecteditemtext", .init(0, 0, 0, 1) },
        .{ "threeddarkshadow", .init(0, 0, 0, 1) },
        .{ "threedface", .init(239, 239, 239, 1) },
        .{ "threedhighlight", .init(0, 0, 0, 1) },
        .{ "threedlightshadow", .init(0, 0, 0, 1) },
        .{ "threedshadow", .init(0, 0, 0, 1) },
        .{ "visitedtext", .init(85, 26, 139, 1) },
        .{ "window", .init(255, 255, 255, 1) },
        .{ "windowframe", .init(0, 0, 0, 1) },
        .{ "windowtext", .init(0, 0, 0, 1) },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
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
    ///
    /// The answer is a `Style` rather than an `RGBA` because two of the five
    /// carry a colour the byte form cannot hold — see `Style.float`.
    pub fn parseFunction(input: []const u8) ?Style {
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

        const alpha: f64 = if (count == 4)
            parseAlpha(parts[3]) orelse return null
        else
            1;

        var style: Style = switch (kind) {
            // Legacy `rgb()` quantises in the parser, so its channels *are*
            // bytes and no float survives it -- measured, and it is what bounds
            // the two families below: on a display-p3 canvas Chrome converts
            // `rgb(50% 0% 0%)` as 128 rather than as 127.5.
            .rgb => .{ .rgba = parseRgbChannels(parts[0..3]) orelse return null },
            .hsl => .fromUnit(parseHslChannels(parts[0..3]) orelse return null),
            .hwb => .fromUnit(parseHwbChannels(parts[0..3]) orelse return null),
        };
        style.rgba.a = round255(alpha * 255);
        // `hwb()` is the one function here CSS Color 4 does not call legacy, so
        // its alpha is not quantised with the rest of it. See `Style.alpha`.
        if (kind == .hwb) {
            style.alpha = alpha;
        }
        return style;
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

    /// The two families answer the 0..1 triple rather than the byte one, because
    /// their channels are not byte-valued and a caller that converts them into
    /// another colour space needs the unrounded form. See `Style.float`.
    fn parseHslChannels(parts: []const []const u8) ?[3]f64 {
        const hue = parseHue(parts[0]) orelse return null;
        const s = parsePercent(parts[1]) orelse return null;
        const l = parsePercent(parts[2]) orelse return null;
        return hslToRgb(hue, s, l);
    }

    fn parseHwbChannels(parts: []const []const u8) ?[3]f64 {
        const hue = parseHue(parts[0]) orelse return null;
        const w = parsePercent(parts[1]) orelse return null;
        const b = parsePercent(parts[2]) orelse return null;
        return hwbToRgb(hue, w, b);
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
    pub fn round255(value: anytype) u8 {
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
    /// The sRGB channels on the 0..1 scale, unrounded, for the notations whose
    /// channels are not byte-valued: `hsl()`, `hsla()` and `hwb()`. Null
    /// everywhere else, where `rgba` already *is* the colour.
    ///
    /// It exists because a display-p3 canvas converts the colour before it
    /// quantises it, and the two orders do not agree: `hsl(30 60% 40%)` is
    /// (0.64, 0.4, 0.16), and converting that stores `9b6935` where converting
    /// the bytes it answers back -- (163, 102, 41) -- stores `9a6935`. Chrome
    /// stores the first (results/canvas-color-notation.chrome.json). Legacy
    /// `rgb()` is not in this set: its parser rounds first, so the byte is the
    /// source there and `rgb(50% 0% 0%)` converts 128 rather than 127.5.
    float: ?[3]f64 = null,

    /// The source alpha, unrounded, for the notations CSS Color 4 does *not*
    /// call legacy. Null for the ones it does, whose alpha is a byte by the
    /// time it is parsed and so already lives in `rgba`.
    ///
    /// Only `hwb()` is here: the other modern functions carry their own alpha
    /// in `wide`, and `rgb()`, `rgba()`, `hsl()`, `hsla()`, a hex and a name
    /// are the legacy set. A float16 bitmap keeps whatever alpha it is handed
    /// and says so on sight -- Chrome answers 0.501953125 for
    /// `rgba(255, 0, 0, 0.5)` and 0.5 for `hwb(200 10% 20% / 0.5)`
    /// (results/canvas-nonlegacy-alpha.chrome.json). It is observable on an
    /// eight-bit display-p3 bitmap too, where the colour is not quantised and
    /// the alpha is the only thing left to round: `hwb(45 15% 35% / 0.5)`
    /// stores a red of 80 against the byte alpha's 81.
    alpha: ?f64 = null,

    /// Three sRGB channels on the 0..1 scale, kept in both forms: the byte one
    /// for everything that reads a colour back, and the float one for the
    /// canvas that converts it first.
    fn fromUnit(rgb: [3]f64) Style {
        return .{ .rgba = .fromUnit(rgb), .float = rgb };
    }

    /// The colour a canvas bitmap of `space` and `channels` paints with, still
    /// unquantised — see `Paint`.
    ///
    /// A wide notation resolves from `wide` rather than from `rgba`, because
    /// `rgba` has already been clipped into sRGB's gamut and the clip does not
    /// come back out: on a display-p3 canvas Chrome stores `ff228d` for
    /// `color(rec2020 1 0.25 0.5)`, where converting the sRGB bytes it also
    /// reports would give `ea338b` (probes/canvas-own-color-space.js).
    ///
    /// `channels` is here for one combination: an eight-bit *sRGB* bitmap is
    /// the only one Blink can hand Skia as a plain eight-bit colour, and there
    /// the colour is quantised before the premultiply rather than after, so
    /// `float` never reaches it. Everywhere else — a display-p3 bitmap, a
    /// float16 one — the float goes through. Measured, fourteen pairs on each
    /// of the two spaces (results/canvas-legacy-premultiply.chrome.json):
    /// `hsl(30 60% 40%)`'s blue is 40.8, which premultiplies to 20 and reads
    /// back 40, where the 41 it rounds to premultiplies to 21 and reads back
    /// the 42 Chrome answers.
    pub fn paint(self: Style, space: CanvasSpace, channels: CanvasChannels) Paint {
        if (self.wide) |source| {
            return source.toPaint(space);
        }
        // A legacy alpha is a byte by the time it is parsed; a modern
        // notation's stays the float it was written as. See `Style.alpha`.
        const alpha = self.alpha orelse self.rgba.normalizedAlpha();
        const unit = self.float orelse {
            const bytes: Paint = .{
                .r = @floatFromInt(self.rgba.r),
                .g = @floatFromInt(self.rgba.g),
                .b = @floatFromInt(self.rgba.b),
                .a = alpha,
            };
            if (space == .srgb) {
                // Byte-valued and already in the bitmap's space, so there is
                // nothing to convert.
                return bytes;
            }
            return convertCanvasPaint(.srgb, space, bytes);
        };
        const rgb: [3]f32 = .{
            @floatCast(unit[0]),
            @floatCast(unit[1]),
            @floatCast(unit[2]),
        };
        if (space == .srgb and channels == .unorm8) {
            // The one bitmap that quantises first. Rounded at the width the
            // channel is carried at, which is the same f32 the conversion
            // below narrows to — see `Style.float`.
            return .{
                .r = @floatFromInt(RGBA.round255(rgb[0] * 255)),
                .g = @floatFromInt(RGBA.round255(rgb[1] * 255)),
                .b = @floatFromInt(RGBA.round255(rgb[2] * 255)),
                .a = alpha,
            };
        }
        const converted = convertCanvasUnit(.srgb, space, rgb);
        return .unclipped(
            converted[0] * 255,
            converted[1] * 255,
            converted[2] * 255,
            alpha,
        );
    }
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
        if (RGBA.parseFunction(trimmed)) |style| return style;
        const wide = Wide.parse(trimmed) orelse return null;
        return .{ .rgba = wide.toRGBA(.srgb), .wide = wide };
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
/// 144.4999999999999, and both round the same way.
///
/// What *did* buy that reading is the width the channel is carried at rather
/// than the formulation: 17/30 is a whisker under 144.5 in double and exactly
/// 144.5 in float, and Chrome's 145 is the float. So the caller narrows to f32
/// before it quantises — see `Style.float`.
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

    /// The encoded bytes, in `target`'s space: through CIE XYZ for every
    /// family, gamma encoded, then clipped into gamut. Three of the results are
    /// measured against Chrome — `color(display-p3 1 0.25 0.5)` is `ff1b7f`,
    /// `lab(50% 40 30)` is `bb5846`, `oklch(0.7 0.1 20)` is `d68585`.
    pub fn toRGBA(self: Wide, target: CanvasSpace) RGBA {
        return self.toPaint(target).toRGBA();
    }

    /// The same colour unquantised, which is the form a canvas paints with: the
    /// bitmap premultiplies before it rounds, and the two orders do not agree
    /// to the byte. See `Paint`.
    ///
    /// A canvas bitmap is in one of two spaces and the notation is converted
    /// into *that* one, which is not the same as converting the sRGB bytes
    /// afterwards: sRGB clips a channel out of its gamut, and the clip is
    /// visible. Measured on a display-p3 canvas
    /// (probes/canvas-own-color-space.js): `color(rec2020 1 0.25 0.5)` stores
    /// `ff228d`, where the srgb byte triple `ff008d` converted onwards would
    /// have given `ea338b`.
    ///
    /// The alpha a wide notation carries stays a float here — it is the one
    /// alpha in the whole pipeline that is not already a byte.
    ///
    /// The colour reaches the bitmap in two legs and they are not the same
    /// arithmetic. Blink resolves the notation into *extended* sRGB first
    /// (`toSrgbUnit`), and Skia then converts that into the bitmap's own space
    /// (`convertCanvasUnit`) — so a display-p3 notation on a display-p3 canvas
    /// goes p3 to sRGB and back rather than straight through, and the round
    /// trip is observable: `color(display-p3 1 0.25 0.5)` stores `ff407f`
    /// there, not the `ff4080` an exact `round(0.5 * 255)` would.
    pub fn toPaint(self: Wide, target: CanvasSpace) Paint {
        const alpha: f64 = switch (self.alpha orelse Channel{ .number = 1 }) {
            .none => 0,
            .number => |a| a,
        };
        const srgb = self.toSrgbUnit();
        const converted = convertCanvasUnit(.srgb, target, .{
            @floatCast(srgb[0]),
            @floatCast(srgb[1]),
            @floatCast(srgb[2]),
        });
        return .unclipped(
            converted[0] * 255,
            converted[1] * 255,
            converted[2] * 255,
            alpha,
        );
    }

    /// The notation as *extended* sRGB: encoded sRGB channels on the 0..1
    /// scale, unclipped, which is the form every CSS colour is resolved into
    /// before a bitmap's own space is reached. See `toPaint`.
    ///
    /// The display-p3 leg does not go through CIE XYZ the way the rest of the
    /// family does. Measured against Chrome's own float16 readings
    /// (results/canvas-float-source-channels.chrome.json), which answer the
    /// converted channel rather than a byte of it: `color(display-p3 1 0.25
    /// 0.5)` on an srgb canvas reads `1.0888671875 0.10601806640625
    /// 0.497314453125`, and only the exact transfer function over *Skia's*
    /// composed matrix lands on all three. The XYZ D50 route this used to take
    /// puts the green at 0.10587, which is two half-precision steps out — and
    /// visible as a whole byte once the fill is translucent.
    fn toSrgbUnit(self: Wide) [3]f64 {
        const c: [3]f64 = .{
            self.channels[0].value(),
            self.channels[1].value(),
            self.channels[2].value(),
        };
        if (self.function == .color) {
            switch (self.space) {
                // Already the encoded form: nothing to do, and the round trip
                // through linear light would only add rounding error.
                .srgb => return c,
                .@"display-p3" => {
                    const linear = matrixApplyFused(p3_linear_to_srgb_linear, .{
                        @floatCast(srgbToLinear64(c[0])),
                        @floatCast(srgbToLinear64(c[1])),
                        @floatCast(srgbToLinear64(c[2])),
                    });
                    return .{
                        srgbFromLinear(linear[0]),
                        srgbFromLinear(linear[1]),
                        srgbFromLinear(linear[2]),
                    };
                },
                else => {},
            }
        }

        const linear: [3]f64 = switch (self.function) {
            .lab => labToSrgbLinear(c[0], c[1], c[2]),
            .lch => polar(labToSrgbLinear, c),
            .oklab => oklabToSrgbLinear(c[0], c[1], c[2]),
            .oklch => polar(oklabToSrgbLinear, c),
            .color => switch (self.space) {
                // The two canvas spaces are answered above.
                .srgb, .@"display-p3" => unreachable,
                .@"srgb-linear" => c,
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
        // Linear sRGB is a way station and not a gamut, so the channels are
        // still unclipped here and the encode keeps them that way.
        return .{
            srgbFromLinear(linear[0]),
            srgbFromLinear(linear[1]),
            srgbFromLinear(linear[2]),
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

fn matrixApply(m: anytype, v: [3]Element(@TypeOf(m))) [3]Element(@TypeOf(m)) {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

/// The float a matrix is made of, so the helpers work over both widths — the
/// wide-notation conversions are f64 and the canvas leg is f32. See
/// `convertCanvasRGBA`.
fn Element(comptime M: type) type {
    return @typeInfo(M).array.child;
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
fn signOf(v: anytype) @TypeOf(v) {
    return if (v < 0) -1 else 1;
}

fn srgbToLinear(v: anytype) @TypeOf(v) {
    const F = @TypeOf(v);
    const a = @abs(v);
    if (a <= 0.04045) return v / 12.92;
    return signOf(v) * std.math.pow(F, (a + 0.055) / 1.055, 2.4);
}

/// The f64 spelling, for the one caller that passes it as a function value
/// rather than calling it: a generic function has no address.
fn srgbToLinear64(v: f64) f64 {
    return srgbToLinear(v);
}

fn srgbFromLinear(v: anytype) @TypeOf(v) {
    const F = @TypeOf(v);
    const a = @abs(v);
    if (a <= 0.0031308) return v * 12.92;
    return signOf(v) * (1.055 * std.math.pow(F, a, 1.0 / 2.4) - 0.055);
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

/// The way back into Oklab, which only the gradient ramp needs: a stop written
/// `color()`, `lab()`, `lch()`, `oklab()` or `oklch()` takes the whole gradient
/// there (measured -- probes/canvas-gradient-stop-space.js).
///
/// The two matrices are the inverses of the pair above and are written out
/// rather than derived, which is how Ottosson publishes them.
const srgb_linear_to_lms: Matrix = .{
    0.4122214708, 0.5363325363, 0.0514459929,
    0.2119034982, 0.6806995451, 0.1073969566,
    0.0883024619, 0.2817188376, 0.6299787005,
};

const lms_to_oklab: Matrix = .{
    0.2104542553, 0.7936177850,  -0.0040720468,
    1.9779984951, -2.4285922050, 0.4505937099,
    0.0259040371, 0.7827717662,  -0.8086757660,
};

/// Gamma-encoded sRGB on the 0..1 scale into Oklab. Out-of-gamut channels ride
/// through: `srgbToLinear` preserves their sign and `std.math.cbrt` takes a
/// negative, which is what a `color(display-p3 ...)` stop needs — its sRGB red
/// is 1.09 and its green is negative, and clipping either one is a byte or more
/// off Chrome across the whole ramp.
pub fn srgbToOklab(rgb: [3]f64) [3]f64 {
    var lms = matrixApply(srgb_linear_to_lms, .{
        srgbToLinear(rgb[0]),
        srgbToLinear(rgb[1]),
        srgbToLinear(rgb[2]),
    });
    for (&lms) |*channel| channel.* = std.math.cbrt(channel.*);
    return matrixApply(lms_to_oklab, lms);
}

/// And back out, to the same 0..1 gamma-encoded sRGB, equally unclipped.
pub fn oklabToSrgb(lab: [3]f64) [3]f64 {
    const linear = oklabToSrgbLinear(lab[0], lab[1], lab[2]);
    return .{
        srgbFromLinear(linear[0]),
        srgbFromLinear(linear[1]),
        srgbFromLinear(linear[2]),
    };
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

/// `colorType`: what one channel of a canvas bitmap *is*. This is not the axis
/// an ImageData's pixel format is on — that one is a finer *read* of whatever
/// the bitmap holds, so every channel it answers off an eight-bit bitmap is the
/// neighbour of some `n / 255`. This is the bitmap.
///
/// An eight-bit channel has room for `n / 255` and nothing else, so a colour
/// that is not byte-valued is gone the moment it is stored and one outside the
/// gamut is clipped there. A half float holds the paint as it came. Measured
/// (results/canvas-float-source-channels.chrome.json): `hsl(30 60% 40%)` reads
/// 0.64013671875 off a float16 bitmap, half precision's neighbour of 0.64,
/// where the same fill on an eight-bit one reads 0.63916015625 — the neighbour
/// of the 163/255 it had to round to.
pub const CanvasChannels = enum {
    unorm8,
    float16,
};

/// A colour on its way into a canvas bitmap, before it is quantised: RGB on the
/// 0..255 scale and alpha on 0..1, both as floats.
///
/// The bitmap is 8-bit, so the colour has to become bytes eventually — but not
/// before it has been premultiplied, because rounding twice is not rounding
/// once. Measured on an srgb canvas (probes/canvas-alpha-semantics.js):
/// `color(display-p3 1 0.25 0.5)` has a blue channel of 126.78, which stores
/// `0x7f` opaque; at half alpha Chrome stores `round(126.78 * 0.5) = 63` and
/// reads it back as `0x7e`, where quantising first would have premultiplied 127
/// into 64 and read back `0x80`.
///
/// Alpha is *not* the same story. A *legacy* colour's alpha is already a byte
/// by the time it is parsed — `rgba(255, 0, 0, 0.5)` is 128/255, not 0.5, and
/// two of those stacked read `ff0000c0` rather than the `ff0000bf` that an
/// exact half would give — and `globalAlpha` is rounded to one as well (see
/// `raster.opacity`). The notations CSS Color 4 does not call legacy keep a
/// float alpha, `hwb()` among them, which is why this field is one. See
/// `Style.alpha`.
pub const Paint = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1,

    pub fn fromRGBA(rgba: RGBA) Paint {
        return .{
            .r = @floatFromInt(rgba.r),
            .g = @floatFromInt(rgba.g),
            .b = @floatFromInt(rgba.b),
            .a = @as(f64, @floatFromInt(rgba.a)) / 255,
        };
    }

    /// The quantised form, for the callers that answer a colour rather than
    /// paint with it.
    pub fn toRGBA(self: Paint) RGBA {
        return .{
            .r = RGBA.round255(self.r),
            .g = RGBA.round255(self.g),
            .b = RGBA.round255(self.b),
            .a = RGBA.round255(self.a * 255),
        };
    }

    /// A converted colour as the bitmap will take it: the channels left where
    /// the conversion put them, alpha clamped.
    ///
    /// The channels are *not* clipped into the destination gamut, whatever the
    /// bitmap's channel type. An eight-bit bitmap does clip — but at the store,
    /// after the premultiply, and the difference is a whole byte. Measured
    /// (results/canvas-color-notation.chrome.json): `color(display-p3 1 0.25
    /// 0.5 / 0.5)` on an srgb canvas has a red of 277.6, which premultiplies to
    /// 139 and fits; clipping it to 255 first stores 128, and the two read back
    /// as `fe407e80` and `ea3b7e80` when the page asks for display-p3.
    fn unclipped(r: f64, g: f64, b: f64, a: f64) Paint {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .a = std.math.clamp(a, 0, 1),
        };
    }
};

/// A conversion between two of them, for the callers that carry the pair
/// around rather than converting on the spot.
pub const SpaceChange = struct {
    from: CanvasSpace,
    to: CanvasSpace,
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
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) : (offset += 4) {
        const pixel = bytes[offset..][0..4];
        const out = convertCanvasRGBA(from, to, .{
            .r = pixel[0],
            .g = pixel[1],
            .b = pixel[2],
            .a = pixel[3],
        });
        pixel[0] = out.r;
        pixel[1] = out.g;
        pixel[2] = out.b;
    }
}

/// One pixel of the same conversion, for the two callers that hold a colour
/// rather than a buffer: the paint state resolving into the bitmap's space, and
/// `drawImage` copying between two bitmaps that are in different ones.
pub fn convertCanvasRGBA(from: CanvasSpace, to: CanvasSpace, rgba: RGBA) RGBA {
    if (from == to) {
        return rgba;
    }
    return convertCanvasPaint(from, to, .fromRGBA(rgba)).toRGBA();
}

/// The same conversion left unquantised, for the callers that go on to
/// premultiply it into a bitmap rather than answer it as bytes. See `Paint`.
///
/// Nothing is clipped into the destination gamut here. A float pixel format has
/// room for a channel outside it and answers one -- measured
/// (results/canvas-image-data-construct.chrome.json), a display-p3 red read back
/// as srgb is `1.0930633544921875 -0.22672080993652344` through `rgba-float32`
/// where `rgba-unorm8` clamps to `255 0 0` -- and an eight-bit bitmap clips at
/// the store rather than here, which is a whole byte apart once the colour is
/// premultiplied first. See `Paint.unclipped`.
pub fn convertCanvasPaint(from: CanvasSpace, to: CanvasSpace, paint: Paint) Paint {
    if (from == to) {
        return paint;
    }
    // The whole leg is f32, narrowing on the way in rather than dividing in
    // f64 first: a byte-valued channel narrows exactly, so this is the same
    // arithmetic the byte entry point always did.
    const unit = convertCanvasUnit(from, to, .{
        @as(f32, @floatCast(paint.r)) / 255,
        @as(f32, @floatCast(paint.g)) / 255,
        @as(f32, @floatCast(paint.b)) / 255,
    });
    return .{
        .r = unit[0] * 255,
        .g = unit[1] * 255,
        .b = unit[2] * 255,
        .a = paint.a,
    };
}

/// The same conversion on channels that are already 0..1, which is the form a
/// float pixel format holds them in: it normalises before this and is not
/// clipped after, so routing it through `Paint`'s 0..255 convention would put a
/// multiply and a divide either side of the matrix that Chrome does not have.
pub fn convertCanvasUnit(from: CanvasSpace, to: CanvasSpace, rgb: [3]f32) [3]f32 {
    if (from == to) {
        return rgb;
    }
    const matrix: CanvasMatrix = switch (from) {
        .srgb => srgb_linear_to_p3_linear,
        .@"display-p3" => p3_linear_to_srgb_linear,
    };
    const linear = matrixApplyFused(matrix, .{
        canvasToLinear(rgb[0]),
        canvasToLinear(rgb[1]),
        canvasToLinear(rgb[2]),
    });
    return .{
        canvasFromLinear(linear[0]),
        canvasFromLinear(linear[1]),
        canvasFromLinear(linear[2]),
    };
}

/// A canvas matrix is f32, where every other matrix here is f64 — see
/// `convertCanvasRGBA` for the measurement that pins the width.
const CanvasMatrix = [9]f32;

fn narrow(m: Matrix) CanvasMatrix {
    var out: CanvasMatrix = undefined;
    for (&out, m) |*cell, value| cell.* = @floatCast(value);
    return out;
}

fn widen(m: CanvasMatrix) Matrix {
    var out: Matrix = undefined;
    for (&out, m) |*cell, value| cell.* = value;
    return out;
}

// ---------------------------------------------------------------------------
// The canvas leg does not go through the matrices above. Both canvas spaces
// share sRGB's transfer function, so the conversion is one matrix -- but *which*
// matrix is a measurement, not a derivation from CSS Color 4, because Chrome
// composes it out of Skia's own two gamuts and rounds twice on the way.
//
// `SkColorSpace::gamutTransformTo` is
// `skcms_Matrix3x3_concat(&invert(dst->toXYZD50), &src->toXYZD50)`, where the
// two `toXYZD50` matrices are `SkNamedGamut::kSRGB` and
// `SkNamedGamut::kDisplayP3` (include/core/SkColorSpace.h),
// `skcms_Matrix3x3_invert` does its arithmetic in double and *stores f32*, and
// the concat is f32 throughout (modules/skcms/skcms.cc). Those two roundings are
// the whole of why the answer is neither of the two published sRGB<->P3
// products: both of those were measured and ruled out through whole bytes
// (probes/canvas-space-matrix.js), and the composition below was then recovered
// cell by cell at float precision (probes/canvas-space-float-matrix.js). See
// `color: canvas space matrix matches Chrome cell for cell`.
//
// Two things follow from the D50 round trip that no exact D65 matrix has: the
// rows do not sum to one, so grey does not come back as grey, and the blue
// column's top two cells are not structural zeros, so an sRGB blue reads with a
// faint negative red.
// ---------------------------------------------------------------------------

/// `SkNamedGamut::kSRGB`, which is the ICC fixed-point (16.16) spelling and not
/// the exact primaries -- every cell is a whole multiple of 2^-16 and so exact
/// at f32.
const skcms_srgb_to_xyz_d50: CanvasMatrix = .{
    0x6FA2p-16, 0x6299p-16, 0x24A0p-16,
    0x38F5p-16, 0xB785p-16, 0x0F84p-16,
    0x0390p-16, 0x18DAp-16, 0xB6CFp-16,
};

/// `SkNamedGamut::kDisplayP3`, which is six significant digits of f32 literal
/// rather than a fixed-point grid.
const skcms_p3_to_xyz_d50: CanvasMatrix = .{
    0.515102,    0.291965,  0.157153,
    0.241182,    0.692236,  0.0665819,
    -0.00104941, 0.0418818, 0.784378,
};

/// `0.822547197 0.177678615 -0.000004828 / 0.033179868 0.966723800 -0.000010076
/// / 0.017070306 0.072381869 0.910398364`, measured to at most one ULP.
const srgb_linear_to_p3_linear: CanvasMatrix =
    matrixMultiply(narrow(matrixInvert(widen(skcms_p3_to_xyz_d50))), skcms_srgb_to_xyz_d50);

/// `1.224816442 -0.225114793 0.000004023 / -0.042038292 1.042147279 0.000011312
/// / -0.019623475 -0.078635663 1.098419309`. Not the inverse of the row above:
/// Chrome composes each direction from the two gamuts, and inverting the f32
/// product instead would round a third time.
const p3_linear_to_srgb_linear: CanvasMatrix =
    matrixMultiply(narrow(matrixInvert(widen(skcms_srgb_to_xyz_d50))), skcms_p3_to_xyz_d50);

/// The matrix leg spelled the way Skia's raster pipeline spells it: one chain of
/// fused multiply-adds per output channel, innermost first (`matrix_3x3` in
/// src/opts/SkRasterPipeline_opts.h, where `mad` is `vmlaq_f32` and so a single
/// rounding). At f32 the order is visible -- a plain left-to-right sum lands one
/// ULP off on one channel of every grey reading measured for this.
fn matrixApplyFused(m: CanvasMatrix, v: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (&out, 0..) |*channel, row| {
        channel.* = @mulAdd(f32, v[0], m[row * 3], @mulAdd(
            f32,
            v[1],
            m[row * 3 + 1],
            v[2] * m[row * 3 + 2],
        ));
    }
    return out;
}

// ---------------------------------------------------------------------------
// Nor is the canvas leg's transfer function `srgbToLinear`'s. Chrome runs this
// conversion through Skia's raster pipeline, whose `parametric` stage evaluates
// an `skcms_TransferFunction` as
//
//   v <= d  ?  mad(c, v, f)  :  approx_powf(mad(a, v, b), g) + e
//
// and whose `approx_powf` is a polynomial over the float's own exponent and
// mantissa bits, not a libm `powf` (src/opts/SkRasterPipeline_opts.h). At the
// f32 width a float read answers in, the difference is not academic: it is
// worth about 1.6e-4 of the result, a hundred times the last bit.
//
// Measured (probes/canvas-space-float-decode.js): all 256 byte values, both
// channels, both directions -- 512 readings -- land on `approx_powf` to the bit.
// skcms's *own* `powf_` (modules/skcms/skcms.cc) is close but not it, and 26 of
// those 512 say so: its `exp2f_` truncates the bit pattern where the pipeline's
// `approx_pow2` rounds it. So the arithmetic under measurement is the raster
// pipeline's, and this is the spelling that reproduces it.
// ---------------------------------------------------------------------------

/// `approx_log2`, whose whole trick is that a float's exponent field already
/// *is* a rough log2 and its mantissa refines the error.
fn approxLog2(x: f32) f32 {
    const raw: u32 = @bitCast(x);
    const e = @as(f32, @floatFromInt(raw)) * 0x1p-23;
    const m: f32 = @bitCast((raw & 0x007fffff) | 0x3f000000);
    // `nmad(m, k, a)` is `a - m * k` with one rounding, which is what a fused
    // multiply-add of the negated multiplicand is.
    return @mulAdd(f32, -m, 1.498030302, e - 124.225514990) -
        1.725879990 / (0.3520887068 + m);
}

/// `approx_pow2`, the same trick run backwards: build the exponent and mantissa
/// fields as one integer and reinterpret them.
fn approxPow2(x: f32) f32 {
    const fract = x - @floor(x);
    var approx = @mulAdd(f32, -fract, 1.490129070, x + 121.274057500);
    approx += 27.728023300 / (4.84252568 - fract);
    approx *= 0x1p23;
    // Guards against underflow and overflow, exactly as the stage does.
    approx = @min(@max(approx, 0), @as(f32, @bitCast(@as(u32, 0x7f800000))));
    // `round` is round-to-nearest here, but at this magnitude an f32 is already
    // a whole number -- the last representable step past 2^23 is at least one --
    // so nothing is being rounded and the tie rule cannot show.
    return @bitCast(@as(u32, @intFromFloat(@round(approx))));
}

fn approxPowf(x: f32, y: f32) f32 {
    if (x == 0 or x == 1) {
        return x;
    }
    return approxPow2(approxLog2(x) * y);
}

/// `SkNamedTransferFn::kSRGB`, which is kept "bitwise exactly the same as
/// skcms" and so holds the f32 *quotients* rather than the exact rationals.
const srgb_tf_g: f32 = 2.4;
const srgb_tf_a: f32 = 1.0 / 1.055;
const srgb_tf_b: f32 = 0.055 / 1.055;
const srgb_tf_c: f32 = 1.0 / 12.92;
const srgb_tf_d: f32 = 0.04045;

/// `skcms_TransferFunction_invert` of the row above. `d` is the curve's join
/// carried through the linear segment, `c` its reciprocal, and `b` is zero
/// because sRGB's `e` is.
const srgb_inv_g: f32 = 1.0 / srgb_tf_g;
const srgb_inv_c: f32 = 1.0 / srgb_tf_c;
const srgb_inv_d: f32 = srgb_tf_c * srgb_tf_d;

/// `powf_(a, -g)`, which is `1.055^2.4` -- but through skcms's *own* approximate
/// pow, so 1.1372833251953125 where the exact value is 1.1371191. Transcribed
/// rather than derived: that pow truncates where `approxPow2` rounds, and this
/// is the only place the difference would matter.
const srgb_inv_a: f32 = 1.1372833251953125;

/// Not `-0.055`. `skcms_TransferFunction_invert` ends by tweaking `e` so that
/// "the valuable invariant `inv(src(1.0f)) == 1.0f`" holds -- `inv.e = 1.0f -
/// powf_(inv.a * s + inv.b, inv.g)` where `s` is `src(1.0f)`, which sRGB
/// evaluates exactly. So the encode is *not* the decode's inverse: it is the
/// decode's inverse bent by 3.02e-5 to keep white white, and every reading in
/// the nonlinear segment is off by exactly that much without it. Measured
/// (probes/canvas-space-float-sweep.js): 1536 of 1536 channels.
const srgb_inv_e: f32 = 1.0 - approxPowf(srgb_inv_a, srgb_inv_g);

fn canvasToLinear(v: f32) f32 {
    const a = @abs(v);
    if (a <= srgb_tf_d) {
        return signOf(v) * (srgb_tf_c * a);
    }
    return signOf(v) * approxPowf(@mulAdd(f32, srgb_tf_a, a, srgb_tf_b), srgb_tf_g);
}

fn canvasFromLinear(v: f32) f32 {
    const a = @abs(v);
    if (a <= srgb_inv_d) {
        return signOf(v) * (srgb_inv_c * a);
    }
    return signOf(v) * (approxPowf(srgb_inv_a * a, srgb_inv_g) + srgb_inv_e);
}

fn matrixMultiply(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    var out: @TypeOf(a) = undefined;
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
fn matrixInvert(m: anytype) @TypeOf(m) {
    const cofactors: @TypeOf(m) = .{
        m[4] * m[8] - m[5] * m[7], m[5] * m[6] - m[3] * m[8], m[3] * m[7] - m[4] * m[6],
        m[2] * m[7] - m[1] * m[8], m[0] * m[8] - m[2] * m[6], m[1] * m[6] - m[0] * m[7],
        m[1] * m[5] - m[2] * m[4], m[2] * m[3] - m[0] * m[5], m[0] * m[4] - m[1] * m[3],
    };
    const determinant = m[0] * cofactors[0] + m[1] * cofactors[1] + m[2] * cofactors[2];
    var out: @TypeOf(m) = undefined;
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

test "color: hsl and hwb reach a canvas as floats, legacy rgb as bytes" {
    // Readings from results/canvas-color-notation.chrome.json: the notation
    // painted on a display-p3 canvas (`display-p3->display-p3`), and the same
    // bitmap read back as srgb (`display-p3->srgb`). The srgb column is the
    // control — an srgb canvas quantises on the way in either way, so the float
    // source must not move it.
    const cases = [_]struct {
        notation: []const u8,
        srgb: [3]u8,
        p3: [3]u8,
        back: [3]u8,
    }{
        // (163.2, 102, 40.8): converting the float stores 9b, converting the
        // byte stores 9a, and the round trip back to srgb doubles the gap.
        .{
            .notation = "hsl(30 60% 40%)",
            .srgb = .{ 0xa3, 0x66, 0x29 },
            .p3 = .{ 0x9b, 0x69, 0x35 },
            .back = .{ 0xa4, 0x66, 0x28 },
        },
        // (51, 178.5, 51), and the same story with the opposite sign.
        .{
            .notation = "hwb(120 20% 30%)",
            .srgb = .{ 0x33, 0xb3, 0x33 },
            .p3 = .{ 0x5c, 0xb0, 0x47 },
            .back = .{ 0x33, 0xb3, 0x33 },
        },
        // The bound: legacy `rgb()` rounds in the parser, so 127.5 is a 128 by
        // the time the conversion sees it and Chrome sides with the byte arm.
        .{
            .notation = "rgb(50% 0% 0%)",
            .srgb = .{ 0x80, 0x00, 0x00 },
            .p3 = .{ 0x75, 0x14, 0x0c },
            .back = .{ 0x80, 0x00, 0x00 },
        },
        // Byte-valued channels, so both arms agree and nothing should move.
        .{
            .notation = "hsl(0 100% 50%)",
            .srgb = .{ 0xff, 0x00, 0x00 },
            .p3 = .{ 0xea, 0x33, 0x23 },
            .back = .{ 0xff, 0x00, 0x00 },
        },
        // A whiteness and blackness past 100%, which is the grey between them:
        // 5/11 of a byte is 115.909, so the float rounds up to the same 116 the
        // byte arm already had.
        .{
            .notation = "hwb(120 50% 60%)",
            .srgb = .{ 0x74, 0x74, 0x74 },
            .p3 = .{ 0x74, 0x74, 0x74 },
            .back = .{ 0x74, 0x74, 0x74 },
        },
        // 17/30 of a byte: 144.49999999999997 in double, exactly 144.5 in
        // float. This row is the one that says the channel is narrowed to f32
        // before it is quantised, and the srgb column says it without any
        // colour space conversion being involved at all.
        .{
            .notation = "hwb(200 10% 20%)",
            .srgb = .{ 0x1a, 0x91, 0xcc },
            .p3 = .{ 0x44, 0x8e, 0xc7 },
            .back = .{ 0x19, 0x90, 0xcc },
        },
        // Nine more of the same shape, so no single knife edge is carrying the
        // claim on its own. Every channel here is a repeating fraction of a
        // byte (measured -- probes/canvas-float-source-channels.js).
        .{
            .notation = "hwb(200 10% 21%)",
            .srgb = .{ 0x1a, 0x8f, 0xc9 },
            .p3 = .{ 0x43, 0x8d, 0xc4 },
            .back = .{ 0x17, 0x8f, 0xc9 },
        },
        .{
            .notation = "hsl(280 70% 30%)",
            .srgb = .{ 0x5e, 0x17, 0x82 },
            .p3 = .{ 0x57, 0x1d, 0x7d },
            .back = .{ 0x5f, 0x17, 0x82 },
        },
        .{
            .notation = "hsl(90 33% 57%)",
            .srgb = .{ 0x91, 0xb6, 0x6d },
            .p3 = .{ 0x99, 0xb4, 0x75 },
            .back = .{ 0x92, 0xb5, 0x6d },
        },
        .{
            .notation = "hsl(210 25% 61%)",
            .srgb = .{ 0x83, 0x9c, 0xb4 },
            .p3 = .{ 0x88, 0x9b, 0xb2 },
            .back = .{ 0x83, 0x9c, 0xb4 },
        },
        .{
            .notation = "hwb(45 15% 35%)",
            .srgb = .{ 0xa6, 0x86, 0x26 },
            .p3 = .{ 0xa1, 0x87, 0x39 },
            .back = .{ 0xa6, 0x86, 0x25 },
        },
        .{
            .notation = "hsl(150 40% 45%)",
            .srgb = .{ 0x45, 0xa1, 0x73 },
            .p3 = .{ 0x5e, 0x9f, 0x76 },
            .back = .{ 0x45, 0xa1, 0x72 },
        },
        .{
            .notation = "hwb(300 5% 5%)",
            .srgb = .{ 0xf2, 0x0d, 0xf2 },
            .p3 = .{ 0xde, 0x33, 0xea },
            .back = .{ 0xf2, 0x0c, 0xf2 },
        },
        // Exactly half a byte, which rounds away from zero to 128 -- and grey
        // does not stay grey across the D50 round trip, so the p3 column is not
        // three equal channels.
        .{
            .notation = "hsl(0 0% 50%)",
            .srgb = .{ 0x80, 0x80, 0x80 },
            .p3 = .{ 0x80, 0x7f, 0x7f },
            .back = .{ 0x80, 0x7f, 0x7f },
        },
        // Two more `rgb()` bounds: a percentage that is not byte-valued, and
        // fractional numbers. Both are rounded by the parser, so the float
        // never reaches the conversion.
        .{
            .notation = "rgb(10% 20% 30%)",
            .srgb = .{ 0x1a, 0x33, 0x4d },
            .p3 = .{ 0x20, 0x32, 0x4b },
            .back = .{ 0x1a, 0x33, 0x4d },
        },
        .{
            .notation = "rgb(2.5 3.5 4.5)",
            .srgb = .{ 0x03, 0x04, 0x05 },
            .p3 = .{ 0x03, 0x04, 0x05 },
            .back = .{ 0x03, 0x04, 0x05 },
        },
    };
    for (cases) |case| {
        const style = parseStyle(case.notation) orelse return error.Unparseable;
        const srgb = style.paint(.srgb, .unorm8).toRGBA();
        try std.testing.expectEqualSlices(u8, &case.srgb, &.{ srgb.r, srgb.g, srgb.b });
        const p3 = style.paint(.@"display-p3", .unorm8).toRGBA();
        try std.testing.expectEqualSlices(u8, &case.p3, &.{ p3.r, p3.g, p3.b });
        var read: [4]u8 = .{ p3.r, p3.g, p3.b, p3.a };
        convertCanvasPixels(.@"display-p3", .srgb, &read);
        try std.testing.expectEqualSlices(u8, &case.back, read[0..3]);
    }
}

test "color: canvas space matrix matches Chrome cell for cell" {
    // A byte read can only pin a channel to 1/255, which is why the test above
    // cannot say *which* matrix Chrome composes. A `rgba-float32` read hands
    // back the encoded float itself, and the readings below
    // (probes/canvas-space-float-matrix.js, results/canvas-space-float-matrix
    // .chrome.json) were chosen so that no powf is under measurement:
    //
    //   gray n=1  the source byte decodes into the transfer function's *linear*
    //             segment and the result encodes back out of it, so the whole
    //             round trip is `v / 12.92`, a matrix row, and `* 12.92`. What
    //             it measures is each row's sum -- and Chrome's rows do not sum
    //             to one, because the composition goes through D50.
    //   blue      `decode(1.0)` is exactly 1.0 under any spelling of the curve,
    //             and the other two channels are zero, so the reading is the
    //             blue column scaled by 12.92. Its top two cells are not the
    //             structural zeros an exact D65 matrix gives.
    //
    // The blue column's third cell is left out: that one *does* leave the
    // linear segment, so it measures the encode as much as the matrix. It
    // belongs to `canvas-space-encode-approx`, not here.
    const u: f32 = 1.0 / 255.0;
    const grey_to_p3 = convertCanvasUnit(.srgb, .@"display-p3", .{ u, u, u });
    try testing.expectEqual(
        [3]f32{ 0.003922435455024242, 0.003921151161193848, 0.003920982591807842 },
        grey_to_p3,
    );
    const grey_to_srgb = convertCanvasUnit(.@"display-p3", .srgb, .{ u, u, u });
    try testing.expectEqual(
        [3]f32{ 0.003920414485037327, 0.003922040108591318, 0.003922197036445141 },
        grey_to_srgb,
    );

    const blue_to_p3 = convertCanvasUnit(.srgb, .@"display-p3", .{ 0, 0, 1 });
    try testing.expectEqual(-0.00006237745401449502, blue_to_p3[0]);
    try testing.expectEqual(-0.00013018165191169828, blue_to_p3[1]);
    const blue_to_srgb = convertCanvasUnit(.@"display-p3", .srgb, .{ 0, 0, 1 });
    try testing.expectEqual(0.00005198120925342664, blue_to_srgb[0]);
    try testing.expectEqual(0.00014614903193432838, blue_to_srgb[1]);

    // And the readings that *do* go through the curve, which pin the other two
    // layers: `approxPowf` on the way in and the normalised inverse on the way
    // out. An exact `powf` puts every one of these 1.6e-4 low, and the exact
    // inverse -- `-0.055` rather than `srgb_inv_e` -- another 3.02e-5 on top.
    try testing.expectEqual(
        [3]f32{ 0.9175682067871094, 0.2002735137939453, 0.13854026794433594 },
        convertCanvasUnit(.srgb, .@"display-p3", .{ 1, 0, 0 }),
    );
    try testing.expectEqual(
        [3]f32{ 1.0930633544921875, -0.22672080993652344, -0.15011119842529297 },
        convertCanvasUnit(.@"display-p3", .srgb, .{ 1, 0, 0 }),
    );
    // White does not come back white, which is the D50 round trip showing.
    try testing.expectEqual(
        [3]f32{ 1.0000991821289062, 0.9999618530273438, 0.9999465942382812 },
        convertCanvasUnit(.srgb, .@"display-p3", .{ 1, 1, 1 }),
    );
    // The mid grey a byte of 128 normalises to, which `straightUnit` reaches by
    // multiplying by 1/255 rather than dividing -- for this byte the two agree.
    const half: f32 = 128.0 / 255.0;
    try testing.expectEqual(
        [3]f32{ 0.5019874572753906, 0.5019111633300781, 0.5018959045410156 },
        convertCanvasUnit(.srgb, .@"display-p3", .{ half, half, half }),
    );
}

const testing = std.testing;

test "color: isColor accepts what Chrome accepts" {
    // Every case here is a Chrome 151 reading through `addColorStop`.
    const accepted = [_][]const u8{
        "#fff",                "#ffffff",                 "#ffffffff",
        "red",                 "rebeccapurple",           "transparent",
        "currentColor",        "rgb(1,2,3)",              "rgb(1 2 3)",
        "rgba(1,2,3,0.5)",     "rgb(1 2 3 / 50%)",        "hsl(120,50%,50%)",
        "hsl(120deg 50% 50%)", "hsla(120,50%,50%,0.5)",   "hwb(120 30% 40%)",
        "lab(50% 40 59.5)",    "lch(52.2% 72.2 50)",      "oklab(0.4 0.1 0.1)",
        "oklch(0.7 0.1 200)",  "color(display-p3 1 0 0)", "color-mix(in srgb, red, blue)",
        // Case and surrounding whitespace are both ignored.
        "RED",                 "  red  ",
        // Out-of-range channels clamp rather than refuse.
                        "rgb(300,0,0)",
        "rgb(-5,0,0)",
        // A system colour.
                "ButtonFace",
    };
    for (accepted) |value| {
        testing.expect(isColor(value)) catch |err| {
            std.debug.print("isColor({s}) should be true\n", .{value});
            return err;
        };
    }

    const refused = [_][]const u8{
        "",                      " ",                   "notacolour", "red red", "#ff",   "#fffff",
        "rgb(1,2)",              "rgb()",               "inherit",    "initial", "unset", "revert",
        "light-dark(red, blue)", "contrast-color(red)",
        // A stringified non-string, which is how a script's `null` or `42`
        // reaches the parser.
        "null",       "42",
    };
    for (refused) |value| {
        testing.expect(!isColor(value)) catch |err| {
            std.debug.print("isColor({s}) should be false\n", .{value});
            return err;
        };
    }
}

test "color: isColor is wider than parseStyle, on purpose" {
    // `parseStyle` covers most of the acceptance set now, so what this pins is
    // the gap: three notations Chrome takes that we cannot turn into a colour.
    // A caller that refuses on `isColor` must not refuse these.
    for ([_][]const u8{ "currentColor", "ButtonFace", "color-mix(in srgb, red, blue)" }) |wider| {
        try testing.expect(isColor(wider));
        try testing.expect(parseStyle(wider) == null);
    }
    // And where parseStyle does answer, isColor agrees rather than second-guessing.
    for ([_][]const u8{ "rgba(1,2,3,0.5)", "oklch(0.7 0.1 200)", "hwb(120 30% 40%)" }) |converted| {
        try testing.expect(isColor(converted));
        try testing.expect(parseStyle(converted) != null);
    }
}
