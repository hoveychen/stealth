// The abstract base of the stylesheet hierarchy. Chrome splits the interface
// in two — StyleSheet carries everything that is not rule-related, and
// CSSStyleSheet adds the rules on top — so a detector walking the prototype
// chain of a `<style>`'s sheet sees two levels, not one.
//
// Member names, their order and their descriptor shapes are Chrome 150's own
// `Object.getOwnPropertyNames(StyleSheet.prototype)`, measured over
// http://localhost.

const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Element = @import("../Element.zig");
const MediaList = @import("MediaList.zig");

const StyleSheet = @This();

_href: ?[]const u8 = null,
_title: ?[]const u8 = null,
_disabled: bool = false,
_owner_node: ?*Element = null,
_media: ?*MediaList = null,

// Every sheet we can produce is a CSS one; Chrome answers "text/css" even for
// a sheet built with `new CSSStyleSheet()`.
pub fn getType(_: *const StyleSheet) []const u8 {
    return "text/css";
}

pub fn getHref(self: *const StyleSheet) ?[]const u8 {
    return self._href;
}

pub fn getOwnerNode(self: *const StyleSheet) ?*Element {
    return self._owner_node;
}

// Only an @import-ed sheet has a parent, and we never fetch those.
pub fn getParentStyleSheet(_: *const StyleSheet) ?*StyleSheet {
    return null;
}

// Measured: a `<style>` with no title attribute answers null, not "".
pub fn getTitle(self: *const StyleSheet) ?[]const u8 {
    return self._title;
}

pub fn getMedia(self: *StyleSheet, frame: *Frame) !*MediaList {
    if (self._media) |media| return media;
    const media = try MediaList.init(frame);
    if (self._owner_node) |owner| {
        if (owner.getAttributeSafe(.wrap("media"))) |text| {
            try media.setMediaText(text, frame);
        }
    }
    self._media = media;
    return media;
}

// Chrome's setter takes a string and routes it through the MediaList.
pub fn setMedia(self: *StyleSheet, text: []const u8, frame: *Frame) !void {
    const media = try self.getMedia(frame);
    try media.setMediaText(text, frame);
}

pub fn getDisabled(self: *const StyleSheet) bool {
    return self._disabled;
}

pub fn setDisabled(self: *StyleSheet, disabled: bool) void {
    self._disabled = disabled;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StyleSheet);

    pub const Meta = struct {
        pub const name = "StyleSheet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(StyleSheet.getType, null, .{});
    pub const href = bridge.accessor(StyleSheet.getHref, null, .{});
    pub const ownerNode = bridge.accessor(StyleSheet.getOwnerNode, null, .{});
    pub const parentStyleSheet = bridge.accessor(StyleSheet.getParentStyleSheet, null, .{});
    pub const title = bridge.accessor(StyleSheet.getTitle, null, .{});
    pub const media = bridge.accessor(StyleSheet.getMedia, StyleSheet.setMedia, .{});
    pub const disabled = bridge.accessor(StyleSheet.getDisabled, StyleSheet.setDisabled, .{});
};
