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

// A marker's orientAngle. Measured on Chrome 150: baseVal and animVal are
// distinct SVGAngle objects over the same attribute, and writing animVal
// throws NoModificationAllowedError.

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const Angle = @import("Angle.zig");

const AnimatedAngle = @This();

_base_val: *Angle,
_anim_val: *Angle,

pub const Lookup = std.AutoHashMapUnmanaged(*Element, *AnimatedAngle);

pub fn getOrCreate(element: *Element, frame: *Frame) !*AnimatedAngle {
    const gop = try frame._svg_animated_angles.getOrPut(frame.arena, element);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_angles.remove(element);
        const base = try Angle.reflected(element, .wrap("orient"), false, frame);
        base.acquireRef();
        errdefer base.releaseRef(frame._page);
        const anim = try Angle.reflected(element, .wrap("orient"), true, frame);
        anim.acquireRef();
        errdefer anim.releaseRef(frame._page);
        gop.value_ptr.* = try frame._factory.create(AnimatedAngle{
            ._base_val = base,
            ._anim_val = anim,
        });
    }
    return gop.value_ptr.*;
}

// The two angles are arena-backed and held only by this pair, so the frame
// releases them when it tears the identity map down.
pub fn deinit(self: *AnimatedAngle, page: *Page) void {
    self._base_val.releaseRef(page);
    self._anim_val.releaseRef(page);
}

pub fn getBaseVal(self: *AnimatedAngle) *Angle {
    return self._base_val;
}

pub fn getAnimVal(self: *AnimatedAngle) *Angle {
    return self._anim_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedAngle);

    pub const Meta = struct {
        pub const name = "SVGAnimatedAngle";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedAngle.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(AnimatedAngle.getAnimVal, null, .{});
};
