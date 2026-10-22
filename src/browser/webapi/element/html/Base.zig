const std = @import("std");
const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const URL = @import("../../../URL.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const TreeWalker = @import("../../TreeWalker.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Base = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Base) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Base) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Base, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeInterned("href") orelse return "";
    if (href.len == 0) {
        return "";
    }
    const owner = element.asConstNode().ownerFrame(frame);
    return URL.resolve(frame.local_arena, owner.url, href, .{});
}

pub fn setHref(self: *Base, value: []const u8, frame: *Frame) !void {
    // The frame's base URL follows through Build.attributeChange.
    try self.asElement().setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);
}

/// The href of the first <base> in tree order under `root` that has one: the
/// element that sets a document's base URL (HTML §document base URL), wherever
/// in the document it is -- Chrome honours one appended to <body> just as it
/// does one in <head>. Shadow trees and <template> contents are not part of
/// the document's tree, and the walk does not enter them.
pub fn firstHref(root: *Node) ?[]const u8 {
    var tw = TreeWalker.Full.Elements.init(root, .{});
    while (tw.next()) |el| {
        if (el.is(Base) == null) continue;
        if (el.getAttributeInterned("href")) |href| return href;
    }
    return null;
}

/// Re-derives `frame`'s base URL from its document. Any <base> entering,
/// leaving or changing href in the frame's active document can move it: a
/// second <base> placed ahead of the first takes over, and removing the last
/// one puts the document URL back, as Chrome does.
pub fn refreshFrameBase(frame: *Frame) !void {
    const href = firstHref(frame.document.asNode()) orelse {
        frame.base_url = null;
        return;
    };
    if (href.len == 0) {
        frame.base_url = null;
        return;
    }
    // An href that doesn't parse leaves the fallback in place (HTML §frozen
    // base URL).
    frame.base_url = URL.resolve(frame.arena, frame.url, href, .{}) catch |err| switch (err) {
        error.TypeError => null,
        else => return err,
    };
}

/// The frame whose base URL `node` decides, if any: only a node in a frame's
/// active document does. A <base> in a DOMParser or createHTMLDocument
/// document, in a detached subtree, a <template> or a shadow tree leaves the
/// page's URL resolution alone.
pub fn activeDocumentFrame(node: *Node, frame: *Frame) ?*Frame {
    const owner = node.ownerFrame(frame);
    if (node.getRootNode(.{}) != owner.document.asNode()) {
        return null;
    }
    return owner;
}

/// The base URL of a document with no browsing context (DOMParser,
/// createHTMLDocument): its own first <base href>, resolved against its own
/// URL, or that URL alone. Such a document's <base> applies to its own nodes
/// and nothing else.
pub fn detachedDocumentBase(doc: *Document, allocator: std.mem.Allocator, frame: *const Frame) ![:0]const u8 {
    const url = doc.getURL(frame);
    const href = firstHref(doc.asNode()) orelse return url;
    if (href.len == 0) {
        return url;
    }
    return URL.resolve(allocator, url, href, .{}) catch |err| switch (err) {
        error.TypeError => url,
        else => err,
    };
}

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("href"))) {
            return;
        }
        const owner = activeDocumentFrame(element.asNode(), frame) orelse return;
        return refreshFrameBase(owner);
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("href"))) {
            return;
        }
        const owner = activeDocumentFrame(element.asNode(), frame) orelse return;
        return refreshFrameBase(owner);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Base);

    pub const Meta = struct {
        pub const name = "HTMLBaseElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Base);

    pub const href = bridge.accessor(Base.getHref, Base.setHref, .{ .ce_reactions = true });
    pub const target = reflect.string("target");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Base" {
    try testing.htmlRunner("element/html/base.html", .{});
    try testing.htmlRunner("element/html/base_detached.html", .{});
}
