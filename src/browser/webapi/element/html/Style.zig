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

const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const StyleSheetList = @import("../../css/StyleSheetList.zig");

const Style = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_sheet: ?*CSSStyleSheet = null,
/// The list `_sheet` was registered in. Kept because deregistration happens
/// after the element has already left the tree, so by then the walk that chose
/// this list -- document's, or a shadow root's -- no longer reaches the same
/// answer.
_sheet_list: ?*StyleSheetList = null,

pub fn asElement(self: *Style) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Style) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Style) *Node {
    return self.asElement().asNode();
}

// Attribute-backed properties

const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");
pub fn getSheet(self: *Style, frame: *Frame) !?*CSSStyleSheet {
    // Per spec, sheet is null for disconnected elements or non-CSS types.
    // Valid types: absent (defaults to "text/css"), empty string, or
    // case-insensitive match for "text/css".
    if (!self.asNode().isConnected()) {
        self._sheet = null;
        return null;
    }
    const t = self.getType();
    if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) {
        self._sheet = null;
        return null;
    }

    if (self._sheet) |sheet| return sheet;
    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), frame);
    self._sheet = sheet;

    const owner = self.asNode().ownerDocument(frame) orelse frame.document;
    const sheets = try owner.getStyleSheets(frame);
    try sheets.add(sheet, frame);

    // A sheet in a shadow tree is also that root's, which is where Chrome
    // keeps it -- and *only* there. Here it stays in the document's list as
    // well, because the cascade is built from that one list
    // (StyleManager.rebuild); dropping it would leave shadow content
    // unstyled. So `document.styleSheets` still over-reports a shadow sheet.
    // Teaching the cascade to walk shadow roots is what would close that, and
    // it wants the scoping work to go with it.
    if (self.asNode().containingShadowRoot()) |root| {
        const shadow_sheets = try root.getStyleSheets(frame);
        try shadow_sheets.add(sheet, frame);
        self._sheet_list = shadow_sheets;
    }

    return sheet;
}

/// The element's text changed, so the rules parsed from it are stale. Re-parses
/// in place, which also marks the StyleManager dirty. Nothing to do while no
/// sheet has been handed out or nothing has read its rules yet: that parse is
/// lazy, so it will read the text as it stands when it first runs -- which is
/// why this only ever went wrong after something had read the cascade.
///
/// Chrome hands out a *new* CSSStyleSheet here and leaves the old object holding
/// the old rules. We keep the object and swap its rules instead, because
/// document.styleSheets is insertion-ordered: re-registering the sheet would move
/// it to the end of the cascade, past sheets that come after it in the document.
pub fn textContentChanged(self: *Style, frame: *Frame) void {
    const sheet = self._sheet orelse return;
    if (sheet._css_rules != null) {
        // Once the CSSOM view exists, StyleManager.parseSheet reads the rules from
        // it rather than from this element's text, so it is the copy that has to be
        // re-parsed. replaceSync marks the manager dirty itself. On failure the
        // sheet keeps the rules it had -- stale is the status quo this fixes, and
        // there is no caller to hand an error to.
        const text = self.asNode().getTextContentAlloc(frame.local_arena) catch return;
        sheet.replaceSync(text, frame) catch return;
        return;
    }
    // No CSSOM view yet: the manager re-reads this element's text on its next
    // rebuild, so all it needs is to be told the rules changed.
    frame._style_manager.sheetModified();
}

pub fn styleAddedCallback(self: *Style, frame: *Frame) !void {
    // Force stylesheet initialization so rules are parsed immediately
    if (self.getSheet(frame) catch null) |_| {
        // Notify StyleManager about the new stylesheet
        frame._style_manager.sheetModified();
    }

    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    try frame.queueLoad(Factory.protoOf(self));
}

pub fn getType(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Style);

    pub const Meta = struct {
        pub const name = "HTMLStyleElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Style);
    pub const nonce = reflect.string("nonce");

    pub const blocking = reflect.string("blocking");
    pub const media = reflect.string("media");
    pub const @"type" = reflect.string("type");
    pub const disabled = reflect.boolean("disabled");
    pub const sheet = bridge.accessor(Style.getSheet, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Style" {
    try testing.htmlRunner("element/html/style.html", .{});
}

test "WebApi: Style text mutation re-cascades" {
    try testing.htmlRunner("css/style_text_mutation.html", .{});
}
