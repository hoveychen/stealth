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

const AnimatedNumber = @This();

_element: *Element,
_kind: Kind,
// setStdDeviation() moves the base value without writing the attribute —
// measured on Chrome 150, `el.setStdDeviation(2, 3)` leaves outerHTML at
// `<feGaussianBlur></feGaussianBlur>` while stdDeviationX reads 2. The value
// only becomes an attribute when someone assigns to baseVal afterwards.
_override: ?f32 = null,

// Which half of a "number-optional-number" attribute this object reads. A
// single value in the attribute fills both halves.
pub const Component = enum { single, first, second };

pub const Kind = enum {
    path_length,
    offset,
    // Filter primitives.
    composite_k1,
    composite_k2,
    composite_k3,
    composite_k4,
    surface_scale,
    diffuse_constant,
    specular_constant,
    specular_exponent,
    kernel_unit_length_x,
    kernel_unit_length_y,
    displacement_scale,
    light_azimuth,
    light_elevation,
    light_x,
    light_y,
    light_z,
    light_points_at_x,
    light_points_at_y,
    light_points_at_z,
    limiting_cone_angle,
    offset_dx,
    offset_dy,
    drop_shadow_dx,
    drop_shadow_dy,
    std_deviation_x,
    std_deviation_y,
    drop_shadow_std_x,
    drop_shadow_std_y,
    morphology_radius_x,
    morphology_radius_y,
    convolve_divisor,
    convolve_bias,
    base_frequency_x,
    base_frequency_y,
    turbulence_seed,
    func_slope,
    func_intercept,
    func_amplitude,
    func_exponent,
    func_offset,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .path_length => comptime .wrap("pathLength"),
            .offset => comptime .wrap("offset"),
            .composite_k1 => comptime .wrap("k1"),
            .composite_k2 => comptime .wrap("k2"),
            .composite_k3 => comptime .wrap("k3"),
            .composite_k4 => comptime .wrap("k4"),
            .surface_scale => comptime .wrap("surfaceScale"),
            // Past 12 bytes a String no longer fits the small-string
            // optimisation, so these cannot be comptime-wrapped.
            .diffuse_constant => .wrap("diffuseConstant"),
            .specular_constant => .wrap("specularConstant"),
            .specular_exponent => .wrap("specularExponent"),
            .kernel_unit_length_x, .kernel_unit_length_y => .wrap("kernelUnitLength"),
            .displacement_scale => comptime .wrap("scale"),
            .light_azimuth => comptime .wrap("azimuth"),
            .light_elevation => comptime .wrap("elevation"),
            .light_x => comptime .wrap("x"),
            .light_y => comptime .wrap("y"),
            .light_z => comptime .wrap("z"),
            .light_points_at_x => comptime .wrap("pointsAtX"),
            .light_points_at_y => comptime .wrap("pointsAtY"),
            .light_points_at_z => comptime .wrap("pointsAtZ"),
            .limiting_cone_angle => .wrap("limitingConeAngle"),
            .offset_dx, .drop_shadow_dx => comptime .wrap("dx"),
            .offset_dy, .drop_shadow_dy => comptime .wrap("dy"),
            .std_deviation_x,
            .std_deviation_y,
            .drop_shadow_std_x,
            .drop_shadow_std_y,
            => comptime .wrap("stdDeviation"),
            .morphology_radius_x, .morphology_radius_y => comptime .wrap("radius"),
            .convolve_divisor => comptime .wrap("divisor"),
            .convolve_bias => comptime .wrap("bias"),
            .base_frequency_x, .base_frequency_y => .wrap("baseFrequency"),
            .turbulence_seed => comptime .wrap("seed"),
            .func_slope => comptime .wrap("slope"),
            .func_intercept => comptime .wrap("intercept"),
            .func_amplitude => comptime .wrap("amplitude"),
            .func_exponent => comptime .wrap("exponent"),
            .func_offset => comptime .wrap("offset"),
        };
    }

    fn allowsPercentage(self: Kind) bool {
        return self == .offset;
    }

    fn component(self: Kind) Component {
        return switch (self) {
            .kernel_unit_length_x,
            .std_deviation_x,
            .drop_shadow_std_x,
            .morphology_radius_x,
            .base_frequency_x,
            => .first,
            .kernel_unit_length_y,
            .std_deviation_y,
            .drop_shadow_std_y,
            .morphology_radius_y,
            .base_frequency_y,
            => .second,
            else => .single,
        };
    }

    // The other half of a number-optional-number pair, so a write to one
    // component can serialize both.
    fn sibling(self: Kind) ?Kind {
        return switch (self) {
            .kernel_unit_length_x => .kernel_unit_length_y,
            .kernel_unit_length_y => .kernel_unit_length_x,
            .std_deviation_x => .std_deviation_y,
            .std_deviation_y => .std_deviation_x,
            .drop_shadow_std_x => .drop_shadow_std_y,
            .drop_shadow_std_y => .drop_shadow_std_x,
            .morphology_radius_x => .morphology_radius_y,
            .morphology_radius_y => .morphology_radius_x,
            .base_frequency_x => .base_frequency_y,
            .base_frequency_y => .base_frequency_x,
            else => null,
        };
    }

    fn defaultValue(self: Kind) f32 {
        return switch (self) {
            .surface_scale,
            .diffuse_constant,
            .specular_constant,
            .specular_exponent,
            .convolve_divisor,
            .func_slope,
            .func_amplitude,
            .func_exponent,
            => 1,
            .drop_shadow_dx,
            .drop_shadow_dy,
            .drop_shadow_std_x,
            .drop_shadow_std_y,
            => 2,
            else => 0,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedNumber);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedNumber {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_numbers.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_numbers.remove(key);
        gop.value_ptr.* = try frame._factory.create(AnimatedNumber{
            ._element = element,
            ._kind = kind,
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *const AnimatedNumber) f32 {
    return self.currentValue();
}

pub fn setBaseVal(self: *AnimatedNumber, value: f32, frame: *Frame) !void {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }

    const kind = self._kind;
    const serialized = if (kind.sibling()) |other| blk: {
        const sibling = try getOrCreate(self._element, other, frame);
        const mine = value;
        const theirs = sibling.currentValue();
        break :blk switch (kind.component()) {
            .first => try std.fmt.allocPrint(frame.local_arena, "{d} {d}", .{ mine, theirs }),
            else => try std.fmt.allocPrint(frame.local_arena, "{d} {d}", .{ theirs, mine }),
        };
    } else try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});

    try self._element.setAttributeSafe(kind.attributeName(), .wrap(serialized), frame);
    self._override = null;
}

pub fn getAnimVal(self: *const AnimatedNumber) f32 {
    return self.currentValue();
}

// The in-memory base value used by setStdDeviation(), which does not touch
// the attribute.
pub fn setOverride(self: *AnimatedNumber, value: f32) !void {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
    self._override = value;
}

fn currentValue(self: *const AnimatedNumber) f32 {
    const kind = self._kind;
    const raw = self._element.getAttributeSafe(kind.attributeName()) orelse
        return self._override orelse kind.defaultValue();

    const parsed = switch (kind.component()) {
        .single => parseOne(raw, kind.allowsPercentage()),
        .first => parsePair(raw).first,
        .second => parsePair(raw).second,
    };
    return parsed orelse self._override orelse kind.defaultValue();
}

fn parseOne(raw: []const u8, allow_percentage: bool) ?f32 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x0c");
    const value = if (allow_percentage and std.mem.endsWith(u8, trimmed, "%"))
        (std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) catch return null) / 100
    else
        std.fmt.parseFloat(f32, trimmed) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

// "number-optional-number": one or two numbers separated by whitespace and/or
// a comma. A lone number fills both halves; anything unparseable invalidates
// the whole attribute, which is how Chrome behaves.
const Pair = struct { first: ?f32, second: ?f32 };

fn parsePair(raw: []const u8) Pair {
    const none: Pair = .{ .first = null, .second = null };
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c,");
    const first_token = it.next() orelse return none;
    const first = parseOne(first_token, false) orelse return none;
    const second_token = it.next() orelse return .{ .first = first, .second = first };
    const second = parseOne(second_token, false) orelse return none;
    if (it.next() != null) return none;
    return .{ .first = first, .second = second };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedNumber);

    pub const Meta = struct {
        pub const name = "SVGAnimatedNumber";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedNumber.getBaseVal, AnimatedNumber.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedNumber.getAnimVal, null, .{});
};
