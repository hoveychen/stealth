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

//! <script> in the SVG namespace. This is the interface only: the frame's
//! script pipeline is typed to HTMLScriptElement, so an SVG script still does
//! not execute here. The three members and their reflection were read off a
//! headed Chrome 150 — `type` defaults to the empty string (unlike
//! SVGStyleElement's, which defaults to text/css) and `async` is a plain
//! boolean attribute.

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");

const Svg = @import("../Svg.zig");

const Script = @This();

pub const Proto = Svg;
_proto: *Svg,

pub fn asElement(self: *Script) *Element {
    return self._proto.asElement();
}
pub fn asConstElement(self: *const Script) *const Element {
    return Factory.protoOf(self._proto);
}
pub fn asNode(self: *Script) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Script) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "";
}

pub fn setType(self: *Script, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), frame);
}

pub fn getHref(self: *Script, frame: *Frame) !*AnimatedString {
    return AnimatedString.getOrCreate(self.asElement(), .href, frame);
}

pub fn getAsync(self: *const Script) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("async")) != null;
}

pub fn setAsync(self: *Script, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("async"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("async"), frame);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Script);

    pub const Meta = struct {
        pub const name = "SVGScriptElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(Script.getType, Script.setType, .{});
    pub const href = bridge.accessor(Script.getHref, null, .{});
    pub const async = bridge.accessor(Script.getAsync, Script.setAsync, .{});
};
