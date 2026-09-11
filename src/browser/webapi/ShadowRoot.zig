// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");

const dump = @import("../dump.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Document = @import("Document.zig");
const Selection = @import("Selection.zig");
const DocumentFragment = @import("DocumentFragment.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");
const Animation = @import("animation/Animation.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");

const ShadowRoot = @This();

pub const Proto = DocumentFragment;

pub const Mode = enum {
    open,
    closed,
};

pub const SlotAssignment = enum {
    named,
    manual,
};

pub const AttachOptions = struct {
    mode: Mode,
    delegates_focus: bool = false,
    slot_assignment: SlotAssignment = .named,
    clonable: bool = false,
    serializable: bool = false,
    declarative: bool = false,
};

_proto: *DocumentFragment,
_mode: Mode,
_host: *Element,
_delegates_focus: bool,
_slot_assignment: SlotAssignment,
_clonable: bool,
_serializable: bool,
_declarative: bool,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .{},
_removed_ids: std.StringHashMapUnmanaged(void) = .{},
_adopted_style_sheets: ?js.Object.Global = null,
/// The other half of DocumentOrShadowRoot. A <style> in a shadow tree belongs
/// to this list and not to the document's -- that separation is the point of
/// the tree, and a script can see it from either side.
_style_sheets: ?*StyleSheetList = null,

pub fn init(host: *Element, opts: AttachOptions, frame: *Frame) !*ShadowRoot {
    return frame._factory.documentFragment(ShadowRoot{
        ._proto = undefined,
        ._mode = opts.mode,
        ._host = host,
        ._delegates_focus = opts.delegates_focus,
        ._slot_assignment = opts.slot_assignment,
        ._clonable = opts.clonable,
        ._serializable = opts.serializable,
        ._declarative = opts.declarative,
    });
}

pub fn asDocumentFragment(self: *ShadowRoot) *DocumentFragment {
    return self._proto;
}

pub fn asNode(self: *ShadowRoot) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *ShadowRoot) *@import("EventTarget.zig") {
    return self.asNode().asEventTarget();
}

pub fn getMode(self: *const ShadowRoot) []const u8 {
    return @tagName(self._mode);
}

pub fn getHost(self: *const ShadowRoot) *Element {
    return self._host;
}

pub fn getDelegatesFocus(self: *const ShadowRoot) bool {
    return self._delegates_focus;
}

pub fn getSlotAssignment(self: *const ShadowRoot) []const u8 {
    return @tagName(self._slot_assignment);
}

pub fn getClonable(self: *const ShadowRoot) bool {
    return self._clonable;
}

pub fn getSerializable(self: *const ShadowRoot) bool {
    return self._serializable;
}

pub fn setHTMLUnsafe(self: *ShadowRoot, html: []const u8, frame: *Frame) !void {
    return self.asDocumentFragment().setHTMLUnsafe(html, frame);
}

pub fn getHTML(self: *ShadowRoot, opts: dump.Opts.Shadow.Declarative, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.getHTML(self.asNode(), opts, writer, frame);
}

pub fn getOnSlotChange(self: *ShadowRoot, frame: *Frame) ?js.Function.Global {
    return frame.getEventHandler(self.asEventTarget(), .onslotchange);
}

pub fn setOnSlotChange(self: *ShadowRoot, callback: ?js.Function.Global, frame: *Frame) !void {
    return frame.setEventHandler(self.asEventTarget(), .onslotchange, callback);
}

pub fn getActiveElement(self: *ShadowRoot, frame: *Frame) ?*Element {
    const root = self.asNode();
    const document = root.ownerDocument(frame) orelse frame.document;

    // This is answering two questions:
    // 1 - is the active element contained by me (if not, return null)
    // 2 - if it is, is there 1+ other shadowroot between us
    //     a - if there is, return the nearest (to self) shadowroot's host
    //     b - if there isn't, return the active element
    var candidate = document._active_element orelse return null;
    while (candidate.asNode().getRootNode(.{}) != root) {
        const shadow = candidate.asNode().containingShadowRoot() orelse return null;
        candidate = shadow._host;
    }
    return candidate;
}

pub fn getElementById(self: *ShadowRoot, id: []const u8, frame: *Frame) ?*Element {
    if (id.len == 0) {
        return null;
    }

    // Fast path: ID is in the map
    if (self._elements_by_id.get(id)) |element| {
        return element;
    }

    // Slow path: ID was removed but might have duplicates
    if (self._removed_ids.remove(id)) {
        // Do a tree walk to find another element with this ID
        var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
        while (tw.next()) |el| {
            const element_id = el.getId() orelse continue;
            if (std.mem.eql(u8, element_id, id)) {
                // we ignore this error to keep getElementById easy to call
                // if it really failed, then we're out of memory and nothing's
                // going to work like it should anyways.
                const owned_id = frame.dupeString(id) catch return null;
                self._elements_by_id.put(frame.arena, owned_id, el) catch return null;
                return el;
            }
        }
    }

    return null;
}

pub fn getAdoptedStyleSheets(self: *ShadowRoot, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

pub fn setAdoptedStyleSheets(self: *ShadowRoot, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

pub fn getStyleSheets(self: *ShadowRoot, frame: *Frame) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._style_sheets = sheets;
    return sheets;
}

// The rest of DocumentOrShadowRoot. Chrome puts all of it on
// ShadowRoot.prototype as well as on Document's -- ten names this side was
// missing outright (measured) -- and the answers a shadow root gives are the
// document's, not a second set of state.
fn ownerDocument(self: *ShadowRoot, frame: *Frame) *Document {
    return self.asNode().ownerDocument(frame) orelse frame.document;
}

pub fn getFullscreenElement(_: *ShadowRoot) ?*Element {
    return null;
}

/// `fullscreenElement` is `[LegacyLenientSetter]`: readonly, but with a setter
/// that exists and silently drops the assignment. `pointerLockElement` and
/// `pictureInPictureElement` have no setter at all (measured, both sides).
pub fn setLeniently(_: *ShadowRoot, _: js.Value) void {}

/// Chrome does not retarget the hit test into the shadow tree: a point over an
/// element outside this root still answers with that element (measured --
/// `shadow.elementFromPoint(1, 1)` on a fresh root gives the HTML element).
pub fn elementFromPoint(self: *ShadowRoot, x: f64, y: f64, frame: *Frame) !?*Element {
    return self.ownerDocument(frame).elementFromPoint(x, y, frame);
}

pub fn elementsFromPoint(self: *ShadowRoot, x: f64, y: f64, frame: *Frame) ![]const *Element {
    return self.ownerDocument(frame).elementsFromPoint(x, y, frame);
}

pub fn getAnimations(_: *ShadowRoot) []*Animation {
    return &.{};
}

pub fn getSelection(self: *ShadowRoot, frame: *Frame) *Selection {
    return self.ownerDocument(frame).getSelection();
}

/// We have no scoped registries, so a shadow root's is the document's -- which
/// is what Chrome answers for a root attached without one (measured:
/// `shadow.customElementRegistry === document.customElementRegistry`).
pub fn getCustomElementRegistry(self: *ShadowRoot, frame: *Frame) ?*CustomElementRegistry {
    return self.ownerDocument(frame).getCustomElementRegistry(frame);
}

pub fn setHTML(self: *ShadowRoot, html: []const u8, _: ?js.Object, frame: *Frame) !void {
    try self.setHTMLUnsafe(html, frame);
    Element.sanitizeTree(self.asNode(), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ShadowRoot);

    pub const Meta = struct {
        pub const name = "ShadowRoot";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order, which is the order a page reads back from
    // getOwnPropertyNames. No `getElementById`: that one is DocumentFragment's
    // and is inherited (it dispatches back to this root's id map).
    pub const mode = bridge.accessor(ShadowRoot.getMode, null, .{});
    pub const host = bridge.accessor(ShadowRoot.getHost, null, .{});
    pub const onslotchange = bridge.accessor(ShadowRoot.getOnSlotChange, ShadowRoot.setOnSlotChange, .{});

    pub const innerHTML = bridge.accessor(_getInnerHTML, _setInnerHTML, .{ .ce_reactions = true });
    fn _getInnerHTML(self: *ShadowRoot, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.asDocumentFragment().getInnerHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setInnerHTML(self: *ShadowRoot, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] DOMString`: a JS null becomes "", not "null".
        return self.asDocumentFragment().setInnerHTML(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }

    pub const delegatesFocus = bridge.accessor(ShadowRoot.getDelegatesFocus, null, .{});
    pub const slotAssignment = bridge.accessor(ShadowRoot.getSlotAssignment, null, .{});
    pub const serializable = bridge.accessor(ShadowRoot.getSerializable, null, .{});
    pub const clonable = bridge.accessor(ShadowRoot.getClonable, null, .{});
    pub const activeElement = bridge.accessor(ShadowRoot.getActiveElement, null, .{});
    pub const styleSheets = bridge.accessor(ShadowRoot.getStyleSheets, null, .{});
    pub const pointerLockElement = bridge.accessor(ShadowRoot.getFullscreenElement, null, .{});
    pub const fullscreenElement = bridge.accessor(ShadowRoot.getFullscreenElement, ShadowRoot.setLeniently, .{});
    pub const adoptedStyleSheets = bridge.accessor(ShadowRoot.getAdoptedStyleSheets, ShadowRoot.setAdoptedStyleSheets, .{});
    pub const pictureInPictureElement = bridge.accessor(ShadowRoot.getFullscreenElement, null, .{});
    pub const elementFromPoint = bridge.function(ShadowRoot.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(ShadowRoot.elementsFromPoint, .{});
    pub const getAnimations = bridge.function(ShadowRoot.getAnimations, .{});

    pub const getHTML = bridge.function(_getHTML, .{});
    const GetHTMLOpts = struct {
        serializableShadowRoots: bool = false,
        shadowRoots: []const *ShadowRoot = &.{},
    };
    fn _getHTML(self: *ShadowRoot, opts_: ?GetHTMLOpts, frame: *Frame) ![]const u8 {
        const opts = opts_ orelse GetHTMLOpts{};
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getHTML(.{
            .shadow_roots = opts.shadowRoots,
            .serializable_shadow_roots = opts.serializableShadowRoots,
        }, &buf.writer, frame);
        return buf.written();
    }

    pub const getSelection = bridge.function(ShadowRoot.getSelection, .{});
    pub const setHTMLUnsafe = bridge.function(ShadowRoot.setHTMLUnsafe, .{ .ce_reactions = true });
    pub const customElementRegistry = bridge.accessor(ShadowRoot.getCustomElementRegistry, null, .{});
    pub const setHTML = bridge.function(ShadowRoot.setHTML, .{ .ce_reactions = true });
};

const testing = @import("../../testing.zig");
test "WebApi: ShadowRoot" {
    try testing.htmlRunner("shadowroot", .{});
}
