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
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Selection = @import("../../Selection.zig");
const Event = @import("../../Event.zig");
const ValidityState = @import("ValidityState.zig");
const handler_property = @import("../../handler_property.zig");
const reflection = @import("../reflection.zig");
const text_entry = @import("../text_entry.zig");
const InputEvent = @import("../../event/InputEvent.zig");
const text_selection = @import("text_selection.zig");
const collections = @import("../../collections.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const TextArea = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_value: ?[]const u8 = null,
// Only user edits count for tooLong/tooShort; script and attribute values don't.
_user_edited: bool = false,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,

_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,

fn dispatchSelectionChangeEvent(self: *TextArea, frame: *Frame) !void {
    const event = try Event.init("selectionchange", .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

fn dispatchInputEvent(self: *TextArea, data: ?[]const u8, input_type: []const u8, frame: *Frame) !void {
    const event = try InputEvent.initTrusted(comptime .wrap("input"), .{ .data = data, .inputType = input_type }, frame);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event.asEvent());
}

pub fn asEventTarget(self: *TextArea) *EventTarget {
    return self.asElement().asEventTarget();
}

pub fn asElement(self: *TextArea) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const TextArea) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TextArea) *Node {
    return self.asElement().asNode();
}
pub fn asConstNode(self: *const TextArea) *const Node {
    return self.asConstElement().asConstNode();
}

pub fn getValue(self: *const TextArea) []const u8 {
    return self._value orelse self.getDefaultValue();
}

pub fn setValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    const changed = std.mem.eql(u8, self.getValue(), value) == false;
    if (changed == false and self._value != null) {
        // _value itself isn't changing (not to be mixed up with setValue
        // being called with the same as the default value, which would need
        // to dupe)
        self._user_edited = false;
        return;
    }
    const owned = try frame.arena.dupe(u8, value);
    self._value = owned;
    self._user_edited = false;

    // move the text entry cursor position to the end of the text control
    if (changed) {
        self._selection_start = @intCast(owned.len);
        self._selection_end = @intCast(owned.len);
        self._selection_direction = .none;
    }
}

pub fn setUserValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    try self.setValue(value, frame);
    self._user_edited = true;
}

/// The form-reset half: the API value goes away and the child text takes over
/// again. https://html.spec.whatwg.org/multipage/form-elements.html#the-textarea-element:concept-form-reset-control
pub fn reset(self: *TextArea) void {
    self._value = null;
}

pub fn getDefaultValue(self: *const TextArea) []const u8 {
    const node = self.asConstNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            return txt.ownData();
        }
    }
    return "";
}

pub fn setDefaultValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    const node = self.asNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            txt.asCData()._data = try frame.dupeSSO(value);
            return;
        }
    }

    // No text child exists, create one
    const text_node = try Frame.node_factory.createTextNode(frame, value);
    _ = try node.appendChild(text_node, frame);
}

pub fn getMaxLength(self: *const TextArea) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("maxlength"));
}

pub fn getMinLength(self: *const TextArea) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("minlength"));
}

const entry = text_entry.TextEntry(TextArea);

pub const select = entry.select;
pub const innerInsert = entry.innerInsert;
pub const innerDelete = entry.innerDelete;
pub const moveCaret = entry.moveCaret;
pub const CaretMove = entry.CaretMove;
pub const getSelectionDirection = entry.getSelectionDirection;
pub const setSelectionStart = entry.setSelectionStart;

// <textarea> always supports selection; <input> only does for some types.
pub fn selectionAvailable(_: *const TextArea) bool {
    return true;
}

// Non-null unlike input
pub fn getSelectionStart(self: *const TextArea) u32 {
    return self._selection_start;
}

pub fn getSelectionEnd(self: *const TextArea) u32 {
    return self._selection_end;
}

pub fn setSelectionEnd(self: *TextArea, value: u32, frame: *Frame) !void {
    self._selection_end = value;
    try self.dispatchSelectionChangeEvent(frame);
}

/// `textLength` is the value's length in code units. Chrome answers 5 for a
/// textarea whose value is "hello" (measured).
pub fn getTextLength(self: *const TextArea) u32 {
    return @intCast(self.getValue().len);
}

/// The `type` IDL attribute is the constant "textarea" (measured).
pub fn getType(_: *const TextArea) []const u8 {
    return "textarea";
}

/// Replaces [start, end) with `replacement` and leaves the selection where the
/// mode says. Chrome's arity is 1 -- the range and the mode are optional, and
/// with only a replacement the *current* selection is what gets replaced
/// (measured: value "abcdef" with the selection at [2, 4) and
/// `setRangeText('ZZ')` gives "abZZef" with the selection still [2, 4)).
pub fn setRangeText(
    self: *TextArea,
    replacement: []const u8,
    start_: ?u32,
    end_: ?u32,
    mode_: ?[]const u8,
    frame: *Frame,
) !void {
    const result = try text_selection.setRangeText(.{
        .value = self.getValue(),
        .selection_start = self._selection_start,
        .selection_end = self._selection_end,
        .replacement = replacement,
        .start = start_,
        .end = end_,
        .mode = mode_,
    }, "HTMLTextAreaElement", frame);

    self._value = result.value;
    self._selection_start = result.selection_start;
    self._selection_end = result.selection_end;
}

pub fn setSelectionRange(
    self: *TextArea,
    selection_start: u32,
    selection_end: u32,
    selection_dir: ?[]const u8,
    frame: *Frame,
) !void {
    const direction = blk: {
        if (selection_dir) |sd| {
            break :blk std.meta.stringToEnum(Selection.SelectionDirection, sd) orelse .none;
        } else break :blk .none;
    };

    // The API value, not `_value`: a `<textarea>abcdef</textarea>` takes its
    // raw value from the child text node and `_value` is null until something
    // assigns to it, and the offsets clamp against what the control actually
    // holds (https://html.spec.whatwg.org/#dom-textarea-value).
    const value = self.getValue();

    const len_u32: u32 = @intCast(value.len);
    var start: u32 = if (selection_start > len_u32) len_u32 else selection_start;
    const end: u32 = if (selection_end > len_u32) len_u32 else selection_end;

    // If end is less than start, both are equal to end.
    if (end < start) {
        start = end;
    }

    self._selection_direction = direction;
    self._selection_start = start;
    self._selection_end = end;

    try self.dispatchSelectionChangeEvent(frame);
}

pub fn getForm(self: *TextArea, frame: *Frame) ?*Form {
    return Form.ownerOf(self.asElement(), frame);
}

pub fn getLabels(self: *TextArea, frame: *Frame) !*collections.NodeList {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getWillValidate(self: *const TextArea) bool {
    return !self.asConstElement().isDisabled();
}

pub fn getValidity(self: *TextArea, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

pub fn getValidationMessage(self: *const TextArea) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing()) return "Please fill out this field.";
    if (self.suffersTooLong()) return "Please shorten this text.";
    if (self.suffersTooShort()) return "Please lengthen this text.";
    return "";
}

pub fn checkValidity(self: *TextArea, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    const v = ValidityState{ ._owner = self.asElement() };
    if (v.getValid(frame)) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *TextArea, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *TextArea, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const TextArea) bool {
    return self._custom_validity != null;
}

pub fn suffersValueMissing(self: *const TextArea) bool {
    if (!self.getWillValidate()) return false;
    if (!self.getRequired()) return false;
    return self.getValue().len == 0;
}

pub fn suffersTooLong(self: *const TextArea) bool {
    if (!self._user_edited) return false;
    const value = self._value orelse return false;
    const max = self.getMaxLength();
    if (max < 0) return false;
    const count = std.unicode.utf8CountCodepoints(value) catch value.len;
    return count > @as(usize, @intCast(max));
}

pub fn suffersTooShort(self: *const TextArea) bool {
    if (!self._user_edited) return false;
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    const min = self.getMinLength();
    if (min < 0) return false;
    const count = std.unicode.utf8CountCodepoints(value) catch value.len;
    return count < @as(usize, @intCast(min));
}

pub fn getDisabled(self: *const TextArea) bool {
    return self.asConstElement().getAttributeInterned("disabled") != null;
}

pub fn getRequired(self: *const TextArea) bool {
    return self.asConstElement().getAttributeInterned("required") != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextArea);

    pub const Meta = struct {
        pub const name = "HTMLTextAreaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TextArea);

    // Chrome's order. No `onselectionchange`: it belongs to
    // GlobalEventHandlers, so Chrome carries it on HTMLElement.prototype and
    // not here (measured).
    pub const autocomplete = reflect.string("autocomplete");
    pub const cols = reflect.unsignedLong("cols", .{ .default = 20, .positive = true, .fallback = true });
    pub const dirName = reflect.string("dirname");
    pub const disabled = reflect.boolean("disabled");
    pub const form = bridge.accessor(TextArea.getForm, null, .{});
    pub const maxLength = reflect.limitedLong("maxlength", "maxLength");
    pub const minLength = reflect.limitedLong("minlength", "minLength");
    pub const name = reflect.string("name");
    pub const placeholder = reflect.string("placeholder");
    pub const readOnly = reflect.boolean("readonly");
    pub const required = reflect.boolean("required");
    pub const rows = reflect.unsignedLong("rows", .{ .default = 2, .positive = true, .fallback = true });
    pub const wrap = reflect.string("wrap");
    pub const @"type" = bridge.accessor(TextArea.getType, null, .{});
    pub const defaultValue = bridge.accessor(TextArea.getDefaultValue, TextArea.setDefaultValue, .{ .ce_reactions = true });
    pub const value = bridge.accessor(TextArea.getValue, TextArea.setValue, .{});
    pub const textLength = bridge.accessor(TextArea.getTextLength, null, .{});
    pub const willValidate = bridge.accessor(TextArea.getWillValidate, null, .{});
    pub const validity = bridge.accessor(TextArea.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(TextArea.getValidationMessage, null, .{});
    pub const labels = bridge.accessor(TextArea.getLabels, null, .{});
    pub const selectionStart = bridge.accessor(TextArea.getSelectionStart, TextArea.setSelectionStart, .{});
    pub const selectionEnd = bridge.accessor(TextArea.getSelectionEnd, TextArea.setSelectionEnd, .{});
    pub const selectionDirection = bridge.accessor(TextArea.getSelectionDirection, null, .{});
    pub const checkValidity = bridge.function(TextArea.checkValidity, .{});
    pub const reportValidity = bridge.function(TextArea.reportValidity, .{});
    pub const select = bridge.function(TextArea.select, .{});
    pub const setCustomValidity = bridge.function(TextArea.setCustomValidity, .{});
    pub const setRangeText = bridge.function(TextArea.setRangeText, .{ .arity = 1 });
    pub const setSelectionRange = bridge.function(TextArea.setSelectionRange, .{});
};

pub const Build = struct {
    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, _: *Frame) !void {
        _ = deep;
        const source = source_element.as(TextArea);
        const clone = cloned_element.as(TextArea);
        clone._value = source._value;
    }
};

const testing = @import("../../../../testing.zig");
const EventTarget = @import("../../EventTarget.zig");
test "WebApi: HTML.TextArea" {
    try testing.htmlRunner("element/html/textarea.html", .{});
    try testing.htmlRunner("element/html/textarea-validity.html", .{});
}
