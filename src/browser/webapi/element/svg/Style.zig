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

//! <style> in the SVG namespace. Measured on a headed Chrome 150: unlike
//! HTMLStyleElement, the getters supply defaults of their own — `type` reads
//! "text/css" and `media` reads "all" when the attribute is absent — and
//! `disabled` is not an attribute at all, it rides the sheet, so it stays
//! false on an element that has none.
//!
//! Chrome fires a load event once the sheet is parsed; this engine's queue is
//! typed to HTMLElement, so that event is not reproduced here.

const std = @import("std");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");
const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");

const Svg = @import("../Svg.zig");

const Style = @This();

pub const Proto = Svg;
_proto: *Svg,
_sheet: ?*CSSStyleSheet = null,

pub fn asElement(self: *Style) *Element {
    return self._proto.asElement();
}
pub fn asConstElement(self: *const Style) *const Element {
    return Factory.protoOf(self._proto);
}
pub fn asNode(self: *Style) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "text/css";
}

pub fn setType(self: *Style, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), frame);
}

pub fn getMedia(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("media")) orelse "all";
}

pub fn setMedia(self: *Style, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
}

pub fn getTitle(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("title")) orelse "";
}

pub fn setTitle(self: *Style, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("title"), .wrap(value), frame);
}

pub fn getSheet(self: *Style, frame: *Frame) !?*CSSStyleSheet {
    if (!self.asNode().isConnected()) {
        self._sheet = null;
        return null;
    }
    // Same rule as HTMLStyleElement: absent, empty or text/css only. The
    // absent case reads back as text/css here, so it needs no special case.
    const declared = self.getType();
    if (declared.len != 0 and !std.ascii.eqlIgnoreCase(declared, "text/css")) {
        self._sheet = null;
        return null;
    }

    if (self._sheet) |sheet| {
        return sheet;
    }
    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), frame);
    self._sheet = sheet;

    const owner = self.asNode().ownerDocument(frame) orelse frame.document;
    try (try owner.cascadeStyleSheets(frame)).add(sheet, frame);
    // Same scoping as HTMLStyleElement: a sheet inside a shadow tree is that
    // root's and stays out of `document.styleSheets`. See Element.Html.Style.
    if (self.asNode().containingShadowRoot()) |root| {
        try (try root.getStyleSheets(frame)).add(sheet, frame);
    } else {
        try (try owner.getStyleSheets(frame)).add(sheet, frame);
    }

    return sheet;
}

pub fn getDisabled(self: *Style, frame: *Frame) !bool {
    const sheet = (try self.getSheet(frame)) orelse return false;
    return sheet.getDisabled();
}

pub fn setDisabled(self: *Style, disabled: bool, frame: *Frame) !void {
    const sheet = (try self.getSheet(frame)) orelse return;
    sheet.setDisabled(disabled);
}

/// Same as HTMLStyleElement's: the rules were parsed from this element's text and
/// cached, so a text mutation has to re-parse them in place. See the comment on
/// Element.Html.Style.textContentChanged for why the sheet object is kept.
pub fn textContentChanged(self: *Style, frame: *Frame) void {
    const sheet = self._sheet orelse return;
    if (sheet._css_rules != null) {
        const text = self.asNode().getTextContentAlloc(frame.local_arena) catch return;
        sheet.replaceSync(text, frame) catch return;
        return;
    }
    frame._style_manager.sheetModified();
}

pub fn styleAddedCallback(self: *Style, frame: *Frame) !void {
    if (self.getSheet(frame) catch null) |_| {
        frame._style_manager.sheetModified();
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Style);

    pub const Meta = struct {
        pub const name = "SVGStyleElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(Style.getType, Style.setType, .{});
    pub const media = bridge.accessor(Style.getMedia, Style.setMedia, .{});
    pub const title = bridge.accessor(Style.getTitle, Style.setTitle, .{});
    pub const sheet = bridge.accessor(Style.getSheet, null, .{});
    pub const disabled = bridge.accessor(Style.getDisabled, Style.setDisabled, .{});
};
