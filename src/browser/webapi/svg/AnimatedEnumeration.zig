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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");

const AnimatedEnumeration = @This();

_element: *Element,
_attr_name: lp.String,
_entries: []const Entry,
_default_value: u16,

pub const Entry = struct {
    keyword: []const u8,
    value: u16,
};

const unit_entries = [_]Entry{
    .{ .keyword = "userSpaceOnUse", .value = 1 },
    .{ .keyword = "objectBoundingBox", .value = 2 },
};
const marker_unit_entries = [_]Entry{
    .{ .keyword = "userSpaceOnUse", .value = 1 },
    .{ .keyword = "strokeWidth", .value = 2 },
};
const spread_entries = [_]Entry{
    .{ .keyword = "pad", .value = 1 },
    .{ .keyword = "reflect", .value = 2 },
    .{ .keyword = "repeat", .value = 3 },
};
const length_adjust_entries = [_]Entry{
    .{ .keyword = "spacing", .value = 1 },
    .{ .keyword = "spacingAndGlyphs", .value = 2 },
};
const text_path_method_entries = [_]Entry{
    .{ .keyword = "align", .value = 1 },
    .{ .keyword = "stretch", .value = 2 },
};
const text_path_spacing_entries = [_]Entry{
    .{ .keyword = "auto", .value = 1 },
    .{ .keyword = "exact", .value = 2 },
};
// The filter primitive enumerations. Values are SVGFE*Element's own
// SVG_* constants, measured on Chrome 150.
const blend_mode_entries = [_]Entry{
    .{ .keyword = "normal", .value = 1 },
    .{ .keyword = "multiply", .value = 2 },
    .{ .keyword = "screen", .value = 3 },
    .{ .keyword = "darken", .value = 4 },
    .{ .keyword = "lighten", .value = 5 },
    .{ .keyword = "overlay", .value = 6 },
    .{ .keyword = "color-dodge", .value = 7 },
    .{ .keyword = "color-burn", .value = 8 },
    .{ .keyword = "hard-light", .value = 9 },
    .{ .keyword = "soft-light", .value = 10 },
    .{ .keyword = "difference", .value = 11 },
    .{ .keyword = "exclusion", .value = 12 },
    .{ .keyword = "hue", .value = 13 },
    .{ .keyword = "saturation", .value = 14 },
    .{ .keyword = "color", .value = 15 },
    .{ .keyword = "luminosity", .value = 16 },
};
const composite_operator_entries = [_]Entry{
    .{ .keyword = "over", .value = 1 },
    .{ .keyword = "in", .value = 2 },
    .{ .keyword = "out", .value = 3 },
    .{ .keyword = "atop", .value = 4 },
    .{ .keyword = "xor", .value = 5 },
    .{ .keyword = "arithmetic", .value = 6 },
};
const morphology_operator_entries = [_]Entry{
    .{ .keyword = "erode", .value = 1 },
    .{ .keyword = "dilate", .value = 2 },
};
const transfer_function_entries = [_]Entry{
    .{ .keyword = "identity", .value = 1 },
    .{ .keyword = "table", .value = 2 },
    .{ .keyword = "discrete", .value = 3 },
    .{ .keyword = "linear", .value = 4 },
    .{ .keyword = "gamma", .value = 5 },
};
const color_matrix_entries = [_]Entry{
    .{ .keyword = "matrix", .value = 1 },
    .{ .keyword = "saturate", .value = 2 },
    .{ .keyword = "hueRotate", .value = 3 },
    .{ .keyword = "luminanceToAlpha", .value = 4 },
};
const edge_mode_entries = [_]Entry{
    .{ .keyword = "duplicate", .value = 1 },
    .{ .keyword = "wrap", .value = 2 },
    .{ .keyword = "none", .value = 3 },
};
const turbulence_type_entries = [_]Entry{
    .{ .keyword = "fractalNoise", .value = 1 },
    .{ .keyword = "turbulence", .value = 2 },
};
const stitch_entries = [_]Entry{
    .{ .keyword = "stitch", .value = 1 },
    .{ .keyword = "noStitch", .value = 2 },
};
// A marker's orient. Measured on Chrome 150: "auto" is AUTO(1),
// "auto-start-reverse" reports UNKNOWN(0) because the IDL has no value for
// it, and everything else — including a malformed value — is ANGLE(2).
const marker_orient_entries = [_]Entry{
    .{ .keyword = "auto", .value = 1 },
    .{ .keyword = "auto-start-reverse", .value = 0 },
};
const channel_entries = [_]Entry{
    .{ .keyword = "R", .value = 1 },
    .{ .keyword = "G", .value = 2 },
    .{ .keyword = "B", .value = 3 },
    .{ .keyword = "A", .value = 4 },
};

pub const Kind = enum {
    clip_path_units,
    gradient_units,
    spread_method,
    marker_units,
    mask_units,
    mask_content_units,
    pattern_units,
    pattern_content_units,
    length_adjust,
    text_path_method,
    text_path_spacing,
    filter_units,
    primitive_units,
    blend_mode,
    composite_operator,
    morphology_operator,
    displacement_x_channel,
    displacement_y_channel,
    transfer_function_type,
    color_matrix_type,
    convolve_edge_mode,
    turbulence_type,
    turbulence_stitch_tiles,
    marker_orient,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .clip_path_units => .wrap("clipPathUnits"),
            .gradient_units => .wrap("gradientUnits"),
            .spread_method => .wrap("spreadMethod"),
            .marker_units => .wrap("markerUnits"),
            .mask_units => .wrap("maskUnits"),
            .mask_content_units => .wrap("maskContentUnits"),
            .pattern_units => .wrap("patternUnits"),
            .pattern_content_units => .wrap("patternContentUnits"),
            .length_adjust => .wrap("lengthAdjust"),
            .text_path_method => .wrap("method"),
            .text_path_spacing => .wrap("spacing"),
            .filter_units => .wrap("filterUnits"),
            .primitive_units => .wrap("primitiveUnits"),
            .blend_mode => .wrap("mode"),
            .composite_operator, .morphology_operator => .wrap("operator"),
            .displacement_x_channel => .wrap("xChannelSelector"),
            .displacement_y_channel => .wrap("yChannelSelector"),
            .transfer_function_type, .color_matrix_type, .turbulence_type => .wrap("type"),
            .convolve_edge_mode => .wrap("edgeMode"),
            .marker_orient => .wrap("orient"),
            .turbulence_stitch_tiles => .wrap("stitchTiles"),
        };
    }

    fn entries(self: Kind) []const Entry {
        return switch (self) {
            .marker_units => &marker_unit_entries,
            .spread_method => &spread_entries,
            .length_adjust => &length_adjust_entries,
            .text_path_method => &text_path_method_entries,
            .text_path_spacing => &text_path_spacing_entries,
            .blend_mode => &blend_mode_entries,
            .composite_operator => &composite_operator_entries,
            .morphology_operator => &morphology_operator_entries,
            .displacement_x_channel, .displacement_y_channel => &channel_entries,
            .transfer_function_type => &transfer_function_entries,
            .color_matrix_type => &color_matrix_entries,
            .convolve_edge_mode => &edge_mode_entries,
            .turbulence_type => &turbulence_type_entries,
            .turbulence_stitch_tiles => &stitch_entries,
            .marker_orient => &marker_orient_entries,
            else => &unit_entries,
        };
    }

    fn defaultValue(self: Kind) u16 {
        return switch (self) {
            .clip_path_units,
            .mask_content_units,
            .pattern_content_units,
            .spread_method,
            .length_adjust,
            .text_path_method,
            .primitive_units,
            .blend_mode,
            .composite_operator,
            .morphology_operator,
            .transfer_function_type,
            .color_matrix_type,
            .convolve_edge_mode,
            => 1,
            .displacement_x_channel, .displacement_y_channel => 4,
            else => 2,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedEnumeration);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedEnumeration {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_enumerations.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_enumerations.remove(key);
        gop.value_ptr.* = try create(
            element,
            kind.attributeName(),
            kind.entries(),
            kind.defaultValue(),
            frame,
        );
    }
    return gop.value_ptr.*;
}

fn create(
    element: *Element,
    attr_name: lp.String,
    entries: []const Entry,
    default_value: u16,
    frame: *Frame,
) !*AnimatedEnumeration {
    return frame._factory.create(AnimatedEnumeration{
        ._element = element,
        ._attr_name = attr_name,
        ._entries = entries,
        ._default_value = default_value,
    });
}

pub fn getBaseVal(self: *const AnimatedEnumeration) u16 {
    // Keywords match exactly — Chrome and Firefox reject even whitespace-padded
    // values, and both answer an unrecognized value with the initial value.
    const raw = self._element.getAttributeSafe(self._attr_name) orelse return self._default_value;
    for (self._entries) |entry| {
        if (std.mem.eql(u8, raw, entry.keyword)) return entry.value;
    }
    return self._default_value;
}

pub fn setBaseVal(self: *AnimatedEnumeration, value: u16, frame: *Frame) !void {
    for (self._entries) |entry| {
        if (entry.value == value) {
            try self._element.setAttributeSafe(self._attr_name, .wrap(entry.keyword), frame);
            return;
        }
    }
    return error.TypeError;
}

pub fn getAnimVal(self: *const AnimatedEnumeration) u16 {
    return self.getBaseVal();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedEnumeration);

    pub const Meta = struct {
        pub const name = "SVGAnimatedEnumeration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedEnumeration.getBaseVal, AnimatedEnumeration.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedEnumeration.getAnimVal, null, .{});
};
