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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedPreserveAspectRatio = @import("../../svg/AnimatedPreserveAspectRatio.zig");

const Graphics = @import("Graphics.zig");

const Image = @This();

pub const Proto = Graphics;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *Graphics else void = undefined,

pub fn asElement(self: *Image) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "SVGImageElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Image);

    pub const x = bridge.accessor(_x, null, .{});
    pub const y = bridge.accessor(_y, null, .{});
    pub const width = bridge.accessor(_width, null, .{});
    pub const height = bridge.accessor(_height, null, .{});
    pub const preserveAspectRatio = bridge.accessor(_preserveAspectRatio, null, .{});

    // The same two reflections HTMLImageElement carries, spelled the same way:
    // a missing `crossorigin` is null and an unrecognised one is "anonymous",
    // while a missing `decoding` is "auto" (measured on Chrome 151).
    pub const decoding = reflect.enumerated("decoding", &.{ "async", "sync", "auto" }, .{ .missing = "auto" });
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });

    pub const href = bridge.accessor(_href, null, .{});

    pub const decode = bridge.function(Image.decode, .{});

    fn _x(self: *Image, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .x, frame);
    }
    fn _y(self: *Image, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .y, frame);
    }
    fn _width(self: *Image, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .width, frame);
    }
    fn _height(self: *Image, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .height, frame);
    }
    fn _preserveAspectRatio(self: *Image, frame: *Frame) !*AnimatedPreserveAspectRatio {
        return AnimatedPreserveAspectRatio.getOrCreate(self.asElement(), frame);
    }

    fn _href(self: *Image, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .href, frame);
    }
};

/// Nothing is decoded here -- no image bytes are held -- so the promise is one
/// that is already resolved, which is what a page that awaits it before drawing
/// needs. The same shape HTMLImageElement's `decode` would take.
pub fn decode(_: *Image, frame: *Frame) !js.Promise {
    return frame.js.local.?.resolvePromise(js.Undefined{});
}
