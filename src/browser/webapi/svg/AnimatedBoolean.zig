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

const AnimatedBoolean = @This();

_element: *Element,
_kind: Kind,

pub const Kind = enum {
    preserve_alpha,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .preserve_alpha => .wrap("preserveAlpha"),
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedBoolean);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedBoolean {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_booleans.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_booleans.remove(key);
        gop.value_ptr.* = try frame._factory.create(AnimatedBoolean{
            ._element = element,
            ._kind = kind,
        });
    }
    return gop.value_ptr.*;
}

// An SVG boolean attribute matches the keyword exactly: measured on Chrome,
// preserveAlpha="TRUE" reads back as false while "true" reads back as true.
pub fn getBaseVal(self: *const AnimatedBoolean) bool {
    const raw = self._element.getAttributeSafe(self._kind.attributeName()) orelse return false;
    return std.mem.eql(u8, raw, "true");
}

pub fn setBaseVal(self: *AnimatedBoolean, value: bool, frame: *Frame) !void {
    const serialized: lp.String = if (value) comptime .wrap("true") else comptime .wrap("false");
    try self._element.setAttributeSafe(self._kind.attributeName(), serialized, frame);
}

pub fn getAnimVal(self: *const AnimatedBoolean) bool {
    return self.getBaseVal();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedBoolean);

    pub const Meta = struct {
        pub const name = "SVGAnimatedBoolean";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedBoolean.getBaseVal, AnimatedBoolean.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedBoolean.getAnimVal, null, .{});
};
