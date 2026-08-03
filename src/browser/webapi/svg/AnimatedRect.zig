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

// The viewBox attribute of <svg>, <marker>, <pattern>, <symbol> and <view>.
// Measured on Chrome 150: baseVal and animVal are distinct SVGRect objects
// over the same attribute and writing animVal throws
// NoModificationAllowedError.

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const Rect = @import("Rect.zig");

const AnimatedRect = @This();

_base_val: *Rect,
_anim_val: *Rect,

pub const Lookup = std.AutoHashMapUnmanaged(*Element, *AnimatedRect);

pub fn getOrCreate(element: *Element, frame: *Frame) !*AnimatedRect {
    const gop = try frame._svg_animated_rects.getOrPut(frame.arena, element);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_rects.remove(element);
        gop.value_ptr.* = try frame._factory.create(AnimatedRect{
            ._base_val = try Rect.reflected(element, .wrap("viewBox"), false, frame._factory),
            ._anim_val = try Rect.reflected(element, .wrap("viewBox"), true, frame._factory),
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *AnimatedRect) *Rect {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedRect) *Rect {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedRect);

    pub const Meta = struct {
        pub const name = "SVGAnimatedRect";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedRect.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedRect.getAnimVal, null, .{});
};
