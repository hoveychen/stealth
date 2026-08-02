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

// baseVal and animVal are two distinct SVGLengthList objects over the same
// attribute — measured on Chrome 150, `text.x.baseVal === text.x.animVal` is
// false and mutating animVal throws NoModificationAllowedError.

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const LengthList = @import("LengthList.zig");

const AnimatedLengthList = @This();

_base_val: *LengthList,
_anim_val: *LengthList,

pub const Key = struct {
    element: *Element,
    kind: LengthList.Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedLengthList);

pub fn getOrCreate(element: *Element, kind: LengthList.Kind, frame: *Frame) !*AnimatedLengthList {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_length_lists.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_length_lists.remove(key);
        gop.value_ptr.* = try frame._factory.create(AnimatedLengthList{
            ._base_val = try LengthList.getOrCreate(element, kind, false, frame),
            ._anim_val = try LengthList.getOrCreate(element, kind, true, frame),
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *AnimatedLengthList) *LengthList {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedLengthList) *LengthList {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedLengthList);

    pub const Meta = struct {
        pub const name = "SVGAnimatedLengthList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedLengthList.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedLengthList.getAnimVal, null, .{});
};
