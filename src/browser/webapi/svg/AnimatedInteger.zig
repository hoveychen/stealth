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

const AnimatedInteger = @This();

_element: *Element,
_kind: Kind,

pub const Kind = enum {
    // feConvolveMatrix order="<x> <y>" — one value fills both.
    convolve_order_x,
    convolve_order_y,
    convolve_target_x,
    convolve_target_y,
    turbulence_num_octaves,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .convolve_order_x, .convolve_order_y => comptime .wrap("order"),
            .convolve_target_x => comptime .wrap("targetX"),
            .convolve_target_y => comptime .wrap("targetY"),
            .turbulence_num_octaves => comptime .wrap("numOctaves"),
        };
    }

    fn component(self: Kind) enum { single, first, second } {
        return switch (self) {
            .convolve_order_x => .first,
            .convolve_order_y => .second,
            else => .single,
        };
    }

    fn sibling(self: Kind) ?Kind {
        return switch (self) {
            .convolve_order_x => .convolve_order_y,
            .convolve_order_y => .convolve_order_x,
            else => null,
        };
    }

    fn defaultValue(self: Kind) i32 {
        return switch (self) {
            .convolve_order_x, .convolve_order_y => 3,
            .turbulence_num_octaves => 1,
            .convolve_target_x, .convolve_target_y => 0,
        };
    }

    // order must be positive; Chrome falls back to the initial value for
    // order="0" (measured), so the check lives with the kind.
    fn requiresPositive(self: Kind) bool {
        return self == .convolve_order_x or self == .convolve_order_y;
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedInteger);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedInteger {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_integers.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_integers.remove(key);
        gop.value_ptr.* = try frame._factory.create(AnimatedInteger{
            ._element = element,
            ._kind = kind,
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *const AnimatedInteger) i32 {
    return self.currentValue();
}

pub fn setBaseVal(self: *AnimatedInteger, value: i32, frame: *Frame) !void {
    const kind = self._kind;
    const serialized = if (kind.sibling()) |other| blk: {
        const sibling = try getOrCreate(self._element, other, frame);
        const theirs = sibling.currentValue();
        break :blk switch (kind.component()) {
            .first => try std.fmt.allocPrint(frame.local_arena, "{d} {d}", .{ value, theirs }),
            else => try std.fmt.allocPrint(frame.local_arena, "{d} {d}", .{ theirs, value }),
        };
    } else try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});

    try self._element.setAttributeSafe(kind.attributeName(), .wrap(serialized), frame);
}

pub fn getAnimVal(self: *const AnimatedInteger) i32 {
    return self.currentValue();
}

fn currentValue(self: *const AnimatedInteger) i32 {
    const kind = self._kind;
    const raw = self._element.getAttributeSafe(kind.attributeName()) orelse return kind.defaultValue();

    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c,");
    const first_token = it.next() orelse return kind.defaultValue();
    const first = parseOne(first_token, kind) orelse return kind.defaultValue();
    if (kind.component() == .single) {
        if (it.next() != null) return kind.defaultValue();
        return first;
    }

    const second_token = it.next() orelse return first;
    const second = parseOne(second_token, kind) orelse return kind.defaultValue();
    if (it.next() != null) return kind.defaultValue();
    return if (kind.component() == .first) first else second;
}

fn parseOne(token: []const u8, kind: Kind) ?i32 {
    // SVG integers accept a decimal point; Chrome truncates toward zero.
    const value = std.fmt.parseFloat(f64, token) catch return null;
    if (!std.math.isFinite(value)) return null;
    if (kind.requiresPositive() and value <= 0) return null;
    if (value > std.math.maxInt(i32) or value < std.math.minInt(i32)) return null;
    return @intFromFloat(std.math.trunc(value));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedInteger);

    pub const Meta = struct {
        pub const name = "SVGAnimatedInteger";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedInteger.getBaseVal, AnimatedInteger.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedInteger.getAnimVal, null, .{});
};
