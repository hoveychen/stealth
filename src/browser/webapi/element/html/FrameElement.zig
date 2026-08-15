// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// <frame>, the pre-<iframe> spelling that still has an interface object on
// Chrome 150 -- one of G17's window keys. The engine already had HTMLFrameSet
// for <frameset>; the child element fell through to HTMLElement, so every
// <frame> in a document was branded one level too high and the global was
// missing.
//
// Ten prototype members, in Chrome's measured order (win63-chrome.json).
// Everything is plain attribute reflection except `src`, which resolves against
// the document base like every other URL attribute, and the two content members,
// which are getter-only. This engine does not load a <frame>, so those two stay
// null -- which is also what Chrome reports for a detached one.

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Window = @import("../../Window.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const HtmlElement = @import("../Html.zig");

const FrameElement = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *FrameElement) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FrameElement) *Node {
    return self.asElement().asNode();
}

/// The five plain string attributes. Chrome reflects each verbatim and answers
/// "" when the attribute is absent.
fn reflect(comptime attribute: []const u8) type {
    return struct {
        fn get(self: *FrameElement) []const u8 {
            return self.asElement().getAttributeSafe(comptime .wrap(attribute)) orelse "";
        }

        fn set(self: *FrameElement, value: []const u8, frame: *Frame) !void {
            try self.asElement().setAttributeSafe(comptime .wrap(attribute), .wrap(value), frame);
        }
    };
}

pub fn getSrc(self: *FrameElement, frame: *Frame) ![]const u8 {
    const src = self.asElement().getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) return "";
    return self.asNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *FrameElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getNoResize(self: *FrameElement) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("noresize")) != null;
}

pub fn setNoResize(self: *FrameElement, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("noresize"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("noresize"), frame);
    }
}

pub fn getContentDocument(_: *const FrameElement) ?*Document {
    return null;
}

pub fn getContentWindow(_: *const FrameElement, _: *Frame) ?Window.Access {
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FrameElement);

    pub const Meta = struct {
        pub const name = "HTMLFrameElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(reflect("name").get, reflect("name").set, .{ .ce_reactions = true });
    pub const scrolling = bridge.accessor(reflect("scrolling").get, reflect("scrolling").set, .{ .ce_reactions = true });
    pub const src = bridge.accessor(FrameElement.getSrc, FrameElement.setSrc, .{ .ce_reactions = true });
    pub const frameBorder = bridge.accessor(reflect("frameborder").get, reflect("frameborder").set, .{ .ce_reactions = true });
    pub const longDesc = bridge.accessor(reflect("longdesc").get, reflect("longdesc").set, .{ .ce_reactions = true });
    pub const noResize = bridge.accessor(FrameElement.getNoResize, FrameElement.setNoResize, .{ .ce_reactions = true });
    pub const contentDocument = bridge.accessor(FrameElement.getContentDocument, null, .{});
    pub const contentWindow = bridge.accessor(FrameElement.getContentWindow, null, .{});
    pub const marginHeight = bridge.accessor(reflect("marginheight").get, reflect("marginheight").set, .{ .ce_reactions = true });
    pub const marginWidth = bridge.accessor(reflect("marginwidth").get, reflect("marginwidth").set, .{ .ce_reactions = true });
};
