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

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DocumentFragment = @import("../../DocumentFragment.zig");
const ShadowRoot = @import("../../ShadowRoot.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Template = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_content: *DocumentFragment,
// Whether _content has been handed to its inert document yet (see getContent).
_content_owned: bool = false,

pub fn asElement(self: *Template) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asConstElement(self: *const Template) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Template) *Node {
    return self.asElement().asNode();
}

// The content belongs to the inert document of the template's own document,
// not to that document (see Document.templateContentsOwner). The owner is only
// known once the template has one -- createElement on another document and the
// parser both give it after the element is built -- so it is settled here, on
// the first look, and every way into the content comes through here.
pub fn getContent(self: *Template, frame: *Frame) !*DocumentFragment {
    if (self._content_owned == false) {
        self._content_owned = true;
        // A declarative shadow root took the content's place; it belongs to
        // its host's document.
        if (self._content.is(ShadowRoot) == null) {
            const document = self.asNode().ownerDocument(frame) orelse frame.document;
            try frame.setNodeOwnerDocument(self._content.asNode(), try document.templateContentsOwner(frame));
        }
    }
    return self._content;
}

pub fn setInnerHTML(self: *Template, html: []const u8, frame: *Frame) !void {
    const content = try self.getContent(frame);
    return content.asNode().setHTML(html, .{ .context = self.asElement() }, frame);
}

// A template moved to another document takes its content along, into that
// document's inert document (Frame.adoptNodeTree). Content nobody has looked
// at yet stays put: getContent will find the new owner.
pub fn ownedContent(self: *Template) ?*Node {
    if (self._content_owned == false or self._content.is(ShadowRoot) != null) {
        return null;
    }
    return self._content.asNode();
}

pub fn getShadowRootMode(self: *const Template) []const u8 {
    const value = self.asConstElement().getAttributeSafe(.wrap("shadowrootmode")) orelse return "";

    if (std.ascii.eqlIgnoreCase(value, "open")) {
        return "open";
    }

    if (std.ascii.eqlIgnoreCase(value, "closed")) {
        return "closed";
    }

    return "";
}

pub fn setShadowRootMode(self: *Template, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("shadowrootmode"), .wrap(value), frame);
}

fn getBoolAttribute(self: *const Template, name: String) bool {
    return self.asConstElement().getAttributeSafe(name) != null;
}

fn setBoolAttribute(self: *Template, name: String, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(name, .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(name, frame);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Template);

    pub const Meta = struct {
        pub const name = "HTMLTemplateElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Template);

    pub const content = bridge.accessor(Template.getContent, null, .{});

    // innerHTML and outerHTML are both inherited. Chrome's
    // HTMLTemplateElement.prototype owns neither (measured); Element's
    // innerHTML redirects to the content fragment, and dump serializes that
    // fragment wherever the template appears.

    pub const shadowRootMode = bridge.accessor(Template.getShadowRootMode, Template.setShadowRootMode, .{ .ce_reactions = true });

    pub const shadowRootDelegatesFocus = bridge.accessor(_getShadowRootDelegatesFocus, _setShadowRootDelegatesFocus, .{ .ce_reactions = true });
    fn _getShadowRootDelegatesFocus(self: *const Template) bool {
        return self.getBoolAttribute(.wrap("shadowrootdelegatesfocus"));
    }
    fn _setShadowRootDelegatesFocus(self: *Template, value: bool, frame: *Frame) !void {
        try self.setBoolAttribute(.wrap("shadowrootdelegatesfocus"), value, frame);
    }

    pub const shadowRootClonable = bridge.accessor(_getShadowRootClonable, _setShadowRootClonable, .{ .ce_reactions = true });
    fn _getShadowRootClonable(self: *const Template) bool {
        return self.getBoolAttribute(.wrap("shadowrootclonable"));
    }
    fn _setShadowRootClonable(self: *Template, value: bool, frame: *Frame) !void {
        try self.setBoolAttribute(.wrap("shadowrootclonable"), value, frame);
    }

    pub const shadowRootSerializable = bridge.accessor(_getShadowRootSerializable, _setShadowRootSerializable, .{ .ce_reactions = true });
    fn _getShadowRootSerializable(self: *const Template) bool {
        return self.getBoolAttribute(.wrap("shadowrootserializable"));
    }
    fn _setShadowRootSerializable(self: *Template, value: bool, frame: *Frame) !void {
        try self.setBoolAttribute(.wrap("shadowrootserializable"), value, frame);
    }

    // Both are plain string reflections in Chrome, not the token list or the
    // registry object their names suggest: setting `htmlFor` writes the `for`
    // content attribute back verbatim and reading it returns a String
    // (measured).
    pub const shadowRootCustomElementRegistry = reflect.string("shadowrootcustomelementregistry");
    pub const htmlFor = reflect.string("for");
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Template);
        // Create the template content DocumentFragment
        self._content = try DocumentFragment.init(frame);
    }

    // Per the HTML spec's cloning steps for <template>, a deep clone must
    // also copy the content fragment (the element itself has no childNodes,
    // so the generic deep-clone loop won't do it).
    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, frame: *Frame) !void {
        if (!deep) {
            return;
        }
        const source = source_element.as(Template);
        const clone = cloned_element.as(Template);
        // The clone's content is left for getContent to own: the clone's
        // document is only recorded once cloning returns.
        const clone_content = clone._content.asNode();
        var child_it = (try source.getContent(frame)).asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                try frame.appendNode(clone_content, cloned_child, .{});
            }
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Template" {
    try testing.htmlRunner("element/html/template.html", .{});
}

test "WebApi: Template content's inert document" {
    try testing.htmlRunner("element/html/template_inert_document.html", .{});
}
