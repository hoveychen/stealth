const std = @import("std");
const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Event = @import("../../Event.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");

const Dialog = @This();

pub const Proto = HtmlElement;

// Whether the dialog was opened with showModal(). It is not derivable from the
// `open` attribute, and `closedBy` needs it: with no `closedby` attribute a
// modal dialog reports "closerequest" and every other state reports "none"
// (measured on Chrome 151, probes/expr-html-family-semantics.js).
_modal: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Dialog) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Dialog) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Dialog) *Node {
    return self.asElement().asNode();
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-show
/// If the open attribute is set, return; otherwise set it to the empty string.
/// Focus / inert / top-layer steps are no-ops here — no rendering pipeline.
pub fn show(self: *Dialog, frame: *Frame) !void {
    if (self.getOpen()) return;
    try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-showmodal
/// Throws InvalidStateError if [open] is already set. Sets [open] otherwise.
/// Focus trap, backdrop, and top-layer placement are no-ops — Lightpanda has
/// no layout/compositor; [open] reflecting through to selectors is what
/// downstream consumers rely on.
pub fn showModal(self: *Dialog, frame: *Frame) !void {
    if (self.getOpen()) return error.InvalidStateError;
    self._modal = true;
    try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
}

/// https://html.spec.whatwg.org/multipage/interactive-elements.html#dom-dialog-close
/// If [open] is unset, return. Otherwise remove [open], optionally update
/// returnValue, and fire a `close` event (non-bubbling, non-cancelable).
pub fn close(self: *Dialog, return_value: ?[]const u8, frame: *Frame) !void {
    if (!self.getOpen()) return;
    self._modal = false;
    try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    if (return_value) |v| {
        try self.asElement().setAttributeSafe(comptime .wrap("returnvalue"), .wrap(v), frame);
    }
    const event = try Event.init("close", .{ .bubbles = false, .cancelable = false }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub fn getOpen(self: *const Dialog) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

/// The `closedby` keywords, with the twist that the missing-value default is
/// not one fixed string: a modal dialog defaults to "closerequest" and
/// everything else to "none". An unrecognised keyword is "none" in both.
pub fn getClosedBy(self: *Dialog) []const u8 {
    const keywords = [_][]const u8{ "any", "closerequest", "none" };
    const raw = self.asElement().getAttributeSafe(comptime .wrap("closedby")) orelse {
        return if (self._modal and self.getOpen()) "closerequest" else "none";
    };
    return reflection.enumeratedValue(raw, &keywords, "none", "none") orelse "none";
}

pub fn setClosedBy(self: *Dialog, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("closedby"), .wrap(value), frame);
}

/// The polite half of close(): a `cancel` event goes first, and a listener
/// that calls preventDefault() keeps the dialog open. With no listener it
/// closes exactly as close() does, return value and all.
pub fn requestClose(self: *Dialog, return_value: ?[]const u8, frame: *Frame) !void {
    if (!self.getOpen()) return;
    const cancel = try Event.init("cancel", .{ .bubbles = false, .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), cancel);
    if (cancel.getDefaultPrevented()) return;
    return self.close(return_value, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Dialog);

    pub const Meta = struct {
        pub const name = "HTMLDialogElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Dialog);

    // Chrome's order: the attributes, then the operations alphabetically.
    pub const open = reflect.boolean("open");
    pub const returnValue = reflect.string("returnvalue");
    pub const closedBy = bridge.accessor(Dialog.getClosedBy, Dialog.setClosedBy, .{ .ce_reactions = true });

    pub const close = bridge.function(Dialog.close, .{});
    pub const requestClose = bridge.function(Dialog.requestClose, .{});
    pub const show = bridge.function(Dialog.show, .{});
    pub const showModal = bridge.function(Dialog.showModal, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Dialog" {
    try testing.htmlRunner("element/html/dialog.html", .{});
}
