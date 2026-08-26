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
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const Graphics = @import("Graphics.zig");

const A = @This();

pub const Proto = Graphics;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *Graphics else void = undefined,

pub fn asElement(self: *A) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *A) *Node {
    return self.asElement().asNode();
}

pub fn getRelList(self: *A, frame: *Frame) !*DOMTokenList {
    return self.asElement().getRelList(frame);
}

/// `[PutForwards=value]`: the setter assigns to the DOMTokenList's `value`, so
/// the `rel` content attribute moves and the list object stays the same one.
/// The point is the descriptor: with a setter it reads as an accessor, which is
/// what Chrome exposes and what a bot check reads. See
/// src/browser/tests/descriptor_kind.html.
pub fn setRelList(self: *A, value: lp.String, frame: *Frame) !void {
    const list = try self.getRelList(frame);
    try list.setValue(value, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(A);

    pub const Meta = struct {
        pub const name = "SVGAElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(A);

    // Chrome's order. `target` is an SVGAnimatedString and read-only, so an
    // `a.target = '_blank'` silently does nothing -- the descriptor has a
    // getter and no setter, which is what separates it from the HTML anchor's
    // plain string. Measured on Chrome 151.
    pub const target = bridge.accessor(_target, null, .{});

    // Six plain string reflections over lowercase content attributes. Note
    // `referrerPolicy` is *not* the limited-to-known-values reflection
    // HTMLAnchorElement uses: an SVG `<a referrerpolicy="bogus">` reads back
    // "bogus" in Chrome, where the HTML one reads "".
    pub const download = reflect.string("download");
    pub const ping = reflect.string("ping");
    pub const rel = reflect.string("rel");
    pub const relList = bridge.accessor(A.getRelList, A.setRelList, .{ .ce_reactions = true });
    pub const hreflang = reflect.string("hreflang");
    pub const @"type" = reflect.string("type");
    pub const referrerPolicy = reflect.string("referrerpolicy");

    pub const href = bridge.accessor(_href, null, .{});
    pub const interestForElement = reflect.elementReference(.interestfor);

    fn _target(self: *A, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .target, frame);
    }

    fn _href(self: *A, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .href, frame);
    }
};
