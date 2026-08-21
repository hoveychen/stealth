// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! `TextFormat`: one underline an IME wants drawn over a stretch of an
//! EditContext's text. Constructible, and the only reachable half of
//! TextFormatUpdateEvent's `textFormats` sequence -- which until this existed
//! had to refuse every non-empty array, because nothing could convert.
//!
//! Four readonly members: two `unsigned long` offsets with neither
//! [EnforceRange] nor [Clamp], so nothing handed in is ever an error (-1 wraps
//! to 4294967295, a fraction truncates, past 32 bits and NaN both read 0), and
//! two enums that do refuse an unknown name.
//!
//! Member order, defaults, coercions and refusals measured on a headed Chrome
//! 151 with tools/fingerprint/probes/probe-shapes.js and probe-s7-misc.js; the
//! dictionary's member list came off a Proxy rather than a spec draft.

const js = @import("../js/js.zig");
const dictionary = @import("dictionary.zig");

const Execution = js.Execution;

const TextFormat = @This();

_range_start: u32 = 0,
_range_end: u32 = 0,
_underline_style: []const u8 = "none",
_underline_thickness: []const u8 = "none",

const Reader = dictionary.Reader("TextFormat", "TextFormatInit");

const underline_styles = [_][]const u8{ "none", "solid", "dotted", "dashed", "wavy" };
const underline_thicknesses = [_][]const u8{ "none", "thin", "thick" };

pub fn constructor(options_: ?js.Value, exec: *const Execution) !*TextFormat {
    const init = try Reader.read(options_, exec);
    const style = try init.enumMember("underlineStyle", "UnderlineStyle", &underline_styles, "none", exec);
    const thickness = try init.enumMember(
        "underlineThickness",
        "UnderlineThickness",
        &underline_thicknesses,
        "none",
        exec,
    );
    return exec._factory.create(TextFormat{
        ._range_start = try init.unsignedLong("rangeStart", 0),
        ._range_end = try init.unsignedLong("rangeEnd", 0),
        ._underline_style = style.?,
        ._underline_thickness = thickness.?,
    });
}

pub fn getRangeStart(self: *const TextFormat) u32 {
    return self._range_start;
}

pub fn getRangeEnd(self: *const TextFormat) u32 {
    return self._range_end;
}

pub fn getUnderlineStyle(self: *const TextFormat) []const u8 {
    return self._underline_style;
}

pub fn getUnderlineThickness(self: *const TextFormat) []const u8 {
    return self._underline_thickness;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextFormat);

    pub const Meta = struct {
        pub const name = "TextFormat";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // One optional dictionary, so Chrome reports TextFormat.length === 0.
    pub const constructor = bridge.constructor(TextFormat.constructor, .{ .arity = 0 });
    pub const rangeStart = bridge.accessor(TextFormat.getRangeStart, null, .{});
    pub const rangeEnd = bridge.accessor(TextFormat.getRangeEnd, null, .{});
    pub const underlineStyle = bridge.accessor(TextFormat.getUnderlineStyle, null, .{});
    pub const underlineThickness = bridge.accessor(TextFormat.getUnderlineThickness, null, .{});
};
