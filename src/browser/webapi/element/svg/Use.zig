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

const Graphics = @import("Graphics.zig");

const Use = @This();

pub const Proto = Graphics;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *Graphics else void = undefined,

pub fn asElement(self: *Use) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Use) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Use);

    pub const Meta = struct {
        pub const name = "SVGUseElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order puts the placement before the reference.
    pub const x = bridge.accessor(_x, null, .{});
    pub const y = bridge.accessor(_y, null, .{});
    pub const width = bridge.accessor(_width, null, .{});
    pub const height = bridge.accessor(_height, null, .{});

    pub const href = bridge.accessor(_href, null, .{});

    // `<use>` takes x/y/width/height as plain lengths defaulting to 0, not to
    // the percentages a viewport-establishing element gets: a bare `<use>` in
    // Chrome answers 0 with unitType 1 (number) on all four.
    fn _x(self: *Use, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .x, frame);
    }
    fn _y(self: *Use, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .y, frame);
    }
    fn _width(self: *Use, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .width, frame);
    }
    fn _height(self: *Use, frame: *Frame) !*AnimatedLength {
        return AnimatedLength.getOrCreate(self.asElement(), .height, frame);
    }

    fn _href(self: *Use, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .href, frame);
    }
};
