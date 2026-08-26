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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const color = @import("../../../color.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Selection = @import("../../Selection.zig");
const Event = @import("../../Event.zig");
const InputEvent = @import("../../event/InputEvent.zig");
const ValidityState = @import("ValidityState.zig");
const popover = @import("../popover.zig");
const File = @import("../../File.zig");
const FileList = @import("../../FileList.zig");
const filesystem = @import("../../filesystem.zig");
const handler_property = @import("../../handler_property.zig");
const reflection = @import("../reflection.zig");
const text_selection = @import("text_selection.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const String = lp.String;

const Input = @This();

pub const Proto = HtmlElement;

pub const Type = enum {
    text,
    password,
    checkbox,
    radio,
    submit,
    reset,
    button,
    hidden,
    image,
    file,
    email,
    url,
    tel,
    search,
    number,
    range,
    date,
    time,
    @"datetime-local",
    month,
    week,
    color,

    pub fn fromString(str: []const u8) Type {
        // Longest type name is "datetime-local" at 14 chars
        if (str.len > 32) {
            return .text;
        }

        var buf: [32]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, str);
        return std.meta.stringToEnum(Type, lower) orelse .text;
    }

    pub fn toString(self: Type) []const u8 {
        return @tagName(self);
    }

    // How the `value` IDL attribute relates to the `value` content attribute.
    // Only `.value` keeps its own state: in the other two the attribute *is*
    // the value, so assigning to .value writes the attribute and removing the
    // attribute drops the value. `.default_on` differs from `.default` only in
    // reading "on" instead of "" when the attribute is absent.
    pub const ValueMode = enum { value, default, default_on, filename };

    pub fn valueMode(self: Type) ValueMode {
        return switch (self) {
            .hidden, .submit, .reset, .button, .image => .default,
            .checkbox, .radio => .default_on,
            .file => .filename,
            else => .value,
        };
    }
};

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_default_value: ?[]const u8 = null,
_default_checked: bool = false,
_value: ?[]const u8 = null,
// The spec's dirty value flag. Only an assignment raises it; while it is down
// the `value` content attribute keeps seeding `_value` through the sanitizer.
// It is not "`_value` is non-null": a rejected assignment leaves `_value` empty
// and still dirty, which is what detaches `type=number` from a later
// `setAttribute("value", "12")`.
_value_dirty: bool = false,
_checked: bool = false,
_checked_dirty: bool = false,
_input_type: Type = .text,
_indeterminate: bool = false,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,
_popover_target: ?*Element = null,
_files: ?*FileList = null,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,

fn dispatchSelectionChangeEvent(self: *Input, frame: *Frame) !void {
    const event = try Event.init("selectionchange", .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

fn dispatchInputEvent(self: *Input, data: ?[]const u8, input_type: []const u8, frame: *Frame) !void {
    const event = try InputEvent.initTrusted(comptime .wrap("input"), .{ .data = data, .inputType = input_type }, frame);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event.asEvent());
}

pub fn asEventTarget(self: *Input) *EventTarget {
    return self.asElement().asEventTarget();
}

pub fn asElement(self: *Input) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Input) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Input) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Input) []const u8 {
    return self._input_type.toString();
}

pub fn setType(self: *Input, typ: []const u8, frame: *Frame) !void {
    // Reflected verbatim; attributeChange derives the state from it
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(typ), frame);
}

pub fn getValue(self: *const Input) []const u8 {
    return switch (self._input_type.valueMode()) {
        .filename => "",
        // The attribute is the value here, so a dirty _value cannot outlive it.
        .default => self._default_value orelse "",
        .default_on => self._default_value orelse "on",
        // `_value` is kept seeded from the attribute by `seedValue`, so there is
        // no falling back to `_default_value` here: that fallback would hand
        // back the raw attribute and skip the sanitizer.
        .value => self._value orelse "",
    };
}

/// Re-run the value sanitization algorithm over the `value` content attribute
/// and adopt the result, per the spec's "value sanitization algorithm ... when
/// the value content attribute is added, changed, or removed". A dirty value
/// outranks the attribute, and the other value modes read the attribute
/// directly, so both are left alone.
fn seedValue(self: *Input, frame: *Frame) !void {
    if (self._value_dirty) return;
    if (self._input_type.valueMode() != .value) return;
    // Sanitizing the empty string rather than short-circuiting on it is what
    // gives `type=color` its "#000000" and `type=range` its midpoint without an
    // attribute to seed from.
    self._value = try self.sanitizeValue(false, self._default_value orelse "", frame);
}

/// The form-reset half: back to what the attributes say, both flags down.
/// https://html.spec.whatwg.org/multipage/input.html#the-input-element:concept-form-reset-control
pub fn reset(self: *Input, frame: *Frame) !void {
    self._value_dirty = false;
    self._checked_dirty = false;
    self._checked = self._default_checked;
    self._value = null;
    try self.seedValue(frame);
}

/// Re-run the sanitizer after a bound moved. Only `range` cares: it is the one
/// type whose sanitizer reads min/max/step, and it clamps rather than rejects,
/// so `<input type=range>` materializing at 50 and then meeting `max=20` reads
/// 20 — not the 15 the midpoint of 10..20 would give. The dirty flag does not
/// gate this: an assigned 90 is pulled down by a later max just the same.
fn reclamp(self: *Input, frame: *Frame) !void {
    if (self._input_type != .range) return;
    self._value = try self.sanitizeValue(false, self._value orelse "", frame);
}

/// Adopt a new input type, moving the value across the value-mode boundary the
/// way the spec's "type attribute has changed" steps do. The sanitizer then
/// runs over whatever the value now *is*, rather than re-reading the attribute:
/// `type=number value=TOK` has already dropped the "TOK", so switching on to
/// `text` reads "" and not "TOK" back out of the attribute.
fn retype(self: *Input, new_type: Type, frame: *Frame) !void {
    const was = self._input_type.valueMode();
    self._input_type = new_type;
    const now = self._input_type.valueMode();

    if (was == .value and now != .value) {
        // Only a dirty value is banked into the attribute. A pristine one came
        // out of the attribute to begin with, so writing it back would clobber
        // the raw attribute with its sanitized form.
        if (self._value_dirty) {
            if (self._value) |dirty| {
                try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(dirty), frame);
            }
        }
        self._value = null;
        self._value_dirty = false;
    } else if (was != .value and now == .value) {
        self._value = self._default_value;
        self._value_dirty = false;
    }

    if (self._value) |current| {
        self._value = try self.sanitizeValue(false, current, frame);
    }
}

// Spec-compliant `getValue` exposes the raw password to JS, FormData, CSS
// `:invalid` checks, etc. — but LLM-facing dumps (semantic tree, form
// detection, accessibility tree) must not echo what the agent just typed.
pub fn getRedactedValue(self: *const Input) []const u8 {
    if (self._input_type == .password) return "*****";
    return self.getValue();
}

pub fn setValue(self: *Input, value: []const u8, frame: *Frame) !void {
    switch (self._input_type.valueMode()) {
        // File inputs: setting to empty string is a no-op, anything else throws
        .filename => {
            if (value.len == 0) return;
            return error.InvalidStateError;
        },
        // The attribute is the value, so write it there and keep no dirty copy.
        .default, .default_on => {
            try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), frame);
            self._value = null;
        },
        // This should _not_ call setAttribute. It updates the current state only
        .value => {
            self._value = try self.sanitizeValue(true, value, frame);
            self._value_dirty = true;
        },
    }
}

pub fn getDefaultValue(self: *const Input) []const u8 {
    return self._default_value orelse "";
}

pub fn setDefaultValue(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), frame);
}

pub fn getChecked(self: *const Input) bool {
    return self._checked;
}

pub fn setChecked(self: *Input, checked: bool, frame: *Frame) !void {
    // If checking a radio button, uncheck others in the group first
    if (checked and self._input_type == .radio) {
        self.uncheckRadioGroup(frame);
    }
    // This should _not_ call setAttribute. It updates the current state only
    self._checked = checked;
    self._checked_dirty = true;
}

pub fn getIndeterminate(self: *const Input) bool {
    return self._indeterminate;
}

pub fn setIndeterminate(self: *Input, value: bool) !void {
    self._indeterminate = value;
}

pub fn getDefaultChecked(self: *const Input) bool {
    return self._default_checked;
}

pub fn setDefaultChecked(self: *Input, checked: bool, frame: *Frame) !void {
    if (checked) {
        try self.asElement().setAttributeSafe(comptime .wrap("checked"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("checked"), frame);
    }
}

pub fn getWillValidate(self: *const Input) bool {
    // An input element is barred from constraint validation if:
    // - type is hidden, button, or reset
    // - element is disabled
    // - element has a datalist ancestor
    return switch (self._input_type) {
        .hidden, .button, .reset => false,
        else => !self.getDisabled() and !self.hasDatalistAncestor(),
    };
}

fn hasDatalistAncestor(self: *const Input) bool {
    var node = self.asConstElement().asConstNode().parentElement();
    while (node) |parent| {
        if (parent.is(HtmlElement.DataList) != null) return true;
        node = parent.asConstNode().parentElement();
    }
    return false;
}

// Constraint validation API
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getValidity(self: *Input, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

/// Lazily allocates this input's FileList and registers it with the frame so
/// the refcounted File objects it holds are released at frame teardown.
fn ensureFileList(self: *Input, frame: *Frame) !*FileList {
    if (self._files) |fl| {
        return fl;
    }

    const fl = try frame._factory.create(FileList{});
    try frame.trackFileList(fl);
    self._files = fl;
    return fl;
}

/// Returns the FileList for a `type="file"` input (lazily allocated, identity preserved).
/// Non-file inputs return null per HTMLInputElement IDL.
pub fn getFiles(self: *Input, frame: *Frame) !?*FileList {
    if (self._input_type != .file) {
        return null;
    }
    return try self.ensureFileList(frame);
}

/// The FileList holds a reference on each File (whose backing arena is reference
/// counted via its Blob proto), so we acquire on the incoming files and release
/// the outgoing ones; the frame releases whatever remains at teardown. Acquiring
/// before releasing is what makes `input.files = input.files` a no-op rather than
/// a double free.
fn replaceFiles(self: *Input, files: []const *File, frame: *Frame) !void {
    const fl = try self.ensureFileList(frame);
    const dupe = try frame.arena.dupe(*File, files);

    for (dupe) |file| {
        file._proto.acquireRef();
    }

    for (fl._files) |old| {
        old._proto.releaseRef(frame._page);
    }

    fl._files = dupe;
}

/// The `files` setter. Read-write is what makes the descriptor an accessor
/// rather than the getter-only one this engine had, and the kind is what a bot
/// check reads (see src/browser/tests/descriptor_kind.html).
///
/// Measured on headed Chrome 150 (probe-setter-semantics): `null` is ignored, an
/// input whose type is not `file` ignores the assignment entirely rather than
/// throwing (the IDL attribute simply does not apply), a value that is not a
/// FileList is the bridge's TypeError, and the assignment fires **no** events --
/// `input`/`change` belong to a user selection, not to this.
///
/// Chrome adopts the assigned FileList object itself, so `input.files === src`
/// afterwards; here the files are copied into this input's own list, because a
/// File's reference is owned by the frame-tracked FileList holding it and two
/// owners would release it once.
pub fn setFilesFromList(self: *Input, files: ?*FileList, frame: *Frame) !void {
    if (self._input_type != .file) {
        return;
    }
    const list = files orelse return;
    try self.replaceFiles(list._files, frame);
}

/// Replaces the selected file list and fires `input` + `change` events, the way
/// a user picking files in the dialog would. Used by CDP `DOM.setFileInputFiles`.
pub fn setFiles(self: *Input, files: []const *File, frame: *Frame) !void {
    if (self._input_type != .file) {
        return error.InvalidStateError;
    }

    try self.replaceFiles(files, frame);

    // A file input fires `input` then `change`, both as plain bubbling Events
    // (not InputEvents — `inputType`/`data` only apply to editable text inputs).
    const input_evt = try Event.initTrusted(comptime .wrap("input"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), input_evt);
    const change_evt = try Event.initTrusted(comptime .wrap("change"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), change_evt);
}

/// JS-binding wrapper for the `value` getter: for type=file, return the spec
/// "C:\\fakepath\\<name>" string; otherwise delegate to plain getValue().
/// `height` and `width` reflect the content attributes only for
/// `type=image`; every other type answers 0 whatever the attributes say
/// (measured: an <input> with height="7" width="9" reports 0/0 as `text` and
/// 7/9 as `image`).
pub fn getDimension(self: *const Input, comptime attr: []const u8) u32 {
    if (self._input_type != .image) {
        return 0;
    }
    const raw = self.asConstElement().getAttributeSafe(comptime .wrap(attr)) orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, &std.ascii.whitespace), 10) catch 0;
}

/// The value as a number, NaN whenever the type has no numeric interpretation
/// (measured: NaN on a fresh `type=text`, 42 on a `type=number` holding "42").
pub fn getValueAsNumber(self: *const Input) f64 {
    switch (self._input_type) {
        .number, .range => {},
        else => return std.math.nan(f64),
    }
    return std.fmt.parseFloat(f64, self.getValue()) catch std.math.nan(f64);
}

pub fn setValueAsNumber(self: *Input, value: f64, frame: *Frame) !void {
    if (std.math.isNan(value) or std.math.isInf(value)) {
        return frame.js.fail(error.TypeError, "Failed to set the 'valueAsNumber' property on 'HTMLInputElement': The value provided is infinite.");
    }
    var buf: [32]u8 = undefined;
    return self.setValue(try std.fmt.bufPrint(&buf, "{d}", .{value}), frame);
}

/// Always null here: the date-shaped types would each need their own parse back
/// to an epoch, and Chrome answers null for every non-date type anyway
/// (measured on `type=text` and on `type=number`).
pub fn getValueAsDate(_: *const Input) ?js.Value {
    return null;
}

pub fn setValueAsDate(_: *Input, _: ?js.Value) void {}

/// `stepUp`/`stepDown` move the value by n steps. Only the numeric types have
/// one; the rest refuse (measured: `type=number` holding "42" steps to "43"
/// and back).
pub fn stepBy(self: *Input, n_: ?i32, direction: f64, frame: *Frame) !void {
    switch (self._input_type) {
        .number, .range => {},
        else => return frame.js.fail(error.InvalidStateError, "Failed to execute 'stepUp' on 'HTMLInputElement': This form element is not steppable."),
    }
    const current = self.getValueAsNumber();
    const base = if (std.math.isNan(current)) 0 else current;
    const step = blk: {
        const raw = self.asConstElement().getAttributeSafe(comptime .wrap("step")) orelse break :blk 1;
        break :blk std.fmt.parseFloat(f64, std.mem.trim(u8, raw, &std.ascii.whitespace)) catch 1;
    };
    const n: f64 = @floatFromInt(n_ orelse 1);
    return self.setValueAsNumber(base + direction * n * step, frame);
}

pub fn stepUp(self: *Input, n: ?i32, frame: *Frame) !void {
    return self.stepBy(n, 1, frame);
}

pub fn stepDown(self: *Input, n: ?i32, frame: *Frame) !void {
    return self.stepBy(n, -1, frame);
}

/// Chrome refuses this outside a user gesture, and nothing here ever has one
/// (measured wording, on a plain `input.showPicker()` from a script).
pub fn showPicker(_: *Input, frame: *Frame) !void {
    return frame.js.fail(error.NotAllowedError, "Failed to execute 'showPicker' on 'HTMLInputElement': HTMLInputElement::showPicker() requires a user gesture.");
}

pub fn setRangeText(
    self: *Input,
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
    }, "HTMLInputElement", frame);

    try self.setValue(result.value, frame);
    self._selection_start = result.selection_start;
    self._selection_end = result.selection_end;
}

pub fn getValueForJS(self: *const Input, frame: *Frame) ![]const u8 {
    if (self._input_type != .file) {
        return self.getValue();
    }

    const fl = self._files orelse return "";
    if (fl._files.len == 0) {
        return "";
    }
    return try std.fmt.allocPrint(frame.local_arena, "C:\\fakepath\\{s}", .{fl._files[0]._name});
}

pub fn getValidationMessage(self: *Input, frame: *Frame) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing(frame)) return "Please fill out this field.";
    if (self.suffersTypeMismatch()) return switch (self._input_type) {
        .email => "Please enter an email address.",
        .url => "Please enter a URL.",
        else => "Please enter a valid value.",
    };
    if (self.suffersPatternMismatch(frame)) return "Please match the requested format.";
    if (self.suffersTooLong()) return "Please shorten this text.";
    if (self.suffersTooShort()) return "Please lengthen this text.";
    if (self.suffersRangeUnderflow()) return "Value is too small.";
    if (self.suffersRangeOverflow()) return "Value is too large.";
    return "";
}

pub fn checkValidity(self: *Input, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    const v = ValidityState{ ._owner = self.asElement() };
    if (v.getValid(frame)) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *Input, frame: *Frame) !bool {
    // Headless: no UI to draw, so reportValidity matches checkValidity exactly.
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *Input, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const Input) bool {
    return self._custom_validity != null;
}

pub fn suffersValueMissing(self: *Input, frame: *Frame) bool {
    if (!self.getWillValidate()) return false;
    if (!self.getRequired()) return false;
    return switch (self._input_type) {
        .checkbox => !self._checked,
        .radio => !self.radioGroupHasChecked(frame),
        .file => if (self._files) |fl| fl._files.len == 0 else true,
        // All value-mode types, so `_value` is already seeded from the
        // attribute — no falling back to the raw `_default_value`.
        .text, .password, .email, .url, .tel, .search, .number, .date, .time, .@"datetime-local", .month, .week, .color => blk: {
            const v: []const u8 = self._value orelse "";
            break :blk v.len == 0;
        },
        // submit/reset/button/hidden/image/range never participate in valueMissing.
        .submit, .reset, .button, .hidden, .image, .range => false,
    };
}

pub fn suffersTypeMismatch(self: *const Input) bool {
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    return switch (self._input_type) {
        .email => !isValidEmail(value),
        .url => !isValidAbsoluteURL(value),
        else => false,
    };
}

pub fn suffersPatternMismatch(self: *const Input, frame: *Frame) bool {
    if (!self.getWillValidate()) return false;
    // Per HTML §4.10.5.3.5, pattern only applies to text-like input types.
    switch (self._input_type) {
        .text, .search, .url, .tel, .email, .password => {},
        else => return false,
    }
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    const pattern = self.asConstElement().getAttributeSafe(comptime .wrap("pattern")) orelse return false;
    if (pattern.len == 0) return false;

    // Per HTML spec, anchor the pattern with ^(?:...)$ and compile under the
    // "v" (Unicode sets) flag. An invalid pattern is ignored — V8 throws and
    // we treat that as "no mismatch". TryCatch absorbs the exception so it
    // doesn't linger in the isolate.
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const wrapped = std.fmt.allocPrint(frame.call_arena, "^(?:{s})$", .{pattern}) catch return false;
    const re = js.RegExp.init(&ls.local, wrapped, js.RegExp.Flag.unicode_sets) catch return false;
    const matched = re.match(value) catch return false;

    return !matched;
}

pub fn suffersTooLong(self: *const Input) bool {
    // Per spec only a dirty value triggers tooLong / tooShort, so a value the
    // `value` content attribute seeded never does — `_value` is non-null for
    // those too, which is why this reads the flag and not the value.
    if (!self._value_dirty) return false;
    const value = self._value orelse return false;
    const max = self.getMaxLength();
    if (max < 0) return false;
    return codepointCount(value) > @as(usize, @intCast(max));
}

pub fn suffersTooShort(self: *const Input) bool {
    if (!self._value_dirty) return false;
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    const min = self.getMinLength();
    if (min < 0) return false;
    return codepointCount(value) < @as(usize, @intCast(min));
}

pub fn suffersRangeUnderflow(self: *const Input) bool {
    return numericRangeBreach(self, .underflow);
}

pub fn suffersRangeOverflow(self: *const Input) bool {
    return numericRangeBreach(self, .overflow);
}

fn numericRangeBreach(self: *const Input, comptime kind: enum { underflow, overflow }) bool {
    // Only number/range use floating-point comparison. date/time/month/week/
    // datetime-local also have range constraints per spec, but their values
    // require type-specific conversion (date → days since epoch, time → ms
    // since midnight, etc.) before comparison — not yet implemented.
    // TODO: implement range checks for date/time/month/week/datetime-local.
    switch (self._input_type) {
        .number, .range => {},
        else => return false,
    }

    const value = self._value orelse return false;
    if (value.len == 0) return false;
    if (!isValidFloatingPoint(value)) return false;
    const v = std.fmt.parseFloat(f64, value) catch return false;

    const attr = switch (kind) {
        .underflow => self.getMin(),
        .overflow => self.getMax(),
    };
    if (attr.len == 0) return false;
    if (!isValidFloatingPoint(attr)) return false;
    const bound = std.fmt.parseFloat(f64, attr) catch return false;

    return switch (kind) {
        .underflow => v < bound,
        .overflow => v > bound,
    };
}

fn radioGroupHasChecked(self: *Input, frame: *Frame) bool {
    if (self._checked) return true;
    var iter = self.radioGroupIterator() orelse return false;
    const my_form = self.getForm(frame);
    while (iter.next()) |other| {
        if (other == self) continue;
        if (!other._checked) continue;
        if (sameFormOwner(my_form, other, frame)) return true;
    }
    return false;
}

const TreeWalker = @import("../../TreeWalker.zig");

const RadioGroupIterator = struct {
    walker: TreeWalker.Full,
    name: []const u8,

    fn next(self: *@This()) ?*Input {
        while (self.walker.next()) |node| {
            const other_element = node.is(Element) orelse continue;
            const other_input = other_element.is(Input) orelse continue;
            if (other_input._input_type != .radio) continue;
            const other_name = other_element.getAttributeSafe(comptime .wrap("name")) orelse continue;
            if (!std.mem.eql(u8, self.name, other_name)) continue;
            return other_input;
        }
        return null;
    }
};

/// Walk same-named radio inputs in `self`'s tree. Returns null if the input
/// has no `name` (or empty `name`) — such radios don't participate in a
/// group. The `TreeWalker` only inspects nodes; the `@constCast` is safe
/// because nothing in the iteration mutates the tree.
fn radioGroupIterator(self: *const Input) ?RadioGroupIterator {
    const element = self.asConstElement();
    const name = element.getAttributeSafe(comptime .wrap("name")) orelse return null;
    if (name.len == 0) return null;
    const root = @constCast(element.asConstNode()).getRootNode(.{});
    return .{
        .walker = TreeWalker.Full.init(root, .{}),
        .name = name,
    };
}

fn sameFormOwner(self_form: ?*Form, other: *Input, frame: *Frame) bool {
    const other_form = other.getForm(frame);

    // Check if same form context
    if (self_form == null and other_form == null) {
        return true;
    }

    if (self_form) |mf| {
        if (other_form) |of| {
            if (mf == of) {
                return true;
            }
        }
    }

    return false;
}

/// Liberal email validation: ASCII local part + "@" + dotted ASCII host. Mirrors
/// the WHATWG "valid e-mail address" production loosely — sufficient for most
/// constraint-validation tests; HTML browsers themselves are permissive here.
fn isValidEmail(value: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (at == 0 or at == value.len - 1) return false;
    const local = value[0..at];
    const host = value[at + 1 ..];
    for (local) |c| if (!isEmailLocalChar(c)) return false;
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    for (host) |c| if (!isEmailHostChar(c)) return false;
    if (host[0] == '.' or host[host.len - 1] == '.') return false;
    return true;
}

fn isEmailLocalChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

fn isEmailHostChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
}

/// Absolute URL check per the WHATWG URL parser: must include a scheme followed
/// by "://" and a non-empty authority. Relative URLs are typeMismatches per spec.
fn isValidAbsoluteURL(value: []const u8) bool {
    const scheme_end = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (scheme_end == 0) return false;
    if (!std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..scheme_end]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    const rest = value[scheme_end + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return false;
    return rest.len > 2;
}

fn codepointCount(value: []const u8) usize {
    return std.unicode.utf8CountCodepoints(value) catch value.len;
}

pub fn getDisabled(self: *const Input) bool {
    // TODO: Also check for disabled fieldset ancestors
    // (but not if we're inside a <legend> of that fieldset)
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *Input, disabled: bool, frame: *Frame) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), frame);
    }
}

pub fn getMaxLength(self: *const Input) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("maxlength"));
}

pub fn getMinLength(self: *const Input) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("minlength"));
}

pub fn getSrc(self: *const Input, frame: *Frame) ![]const u8 {
    const src = self.asConstElement().getAttributeSafe(comptime .wrap("src")) orelse return "";
    return self.asConstElement().asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Input, src: []const u8, frame: *Frame) !void {
    const trimmed = std.mem.trim(u8, src, &std.ascii.whitespace);
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(trimmed), frame);
}

pub fn select(self: *Input, frame: *Frame) !void {
    const len = if (self._value) |v| @as(u32, @intCast(v.len)) else 0;
    try self.setSelectionRange(0, len, null, frame);
    const event = try Event.init("select", .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

// Blink's refusal for a selection member on an input whose type has no
// selection to speak of, quoting the type back. The property is a parameter
// because the lead-in names it and the three setters share everything after it.
// setSelectionRange and friends reach the same state, but they are operations
// and their lead-in reads "Failed to execute" -- a different sentence that
// nothing has measured yet, so they keep the stock DOMException text.
// Measured on Chrome 151 for selectionStart, selectionEnd and
// selectionDirection on type=number and type=checkbox.
fn noSelectionSupport(self: *const Input, comptime property: []const u8, frame: *Frame) anyerror {
    return frame.js.fail(error.InvalidStateError, std.fmt.allocPrint(
        frame.call_arena,
        "Failed to set the '" ++ property ++ "' property on 'HTMLInputElement': " ++
            "The input element's type ('{s}') does not support selection.",
        .{self._input_type.toString()},
    ) catch return error.InvalidStateError);
}

fn selectionAvailable(self: *const Input) bool {
    switch (self._input_type) {
        .text, .search, .url, .tel, .password => return true,
        else => return false,
    }
}

const HowSelected = union(enum) { partial: struct { u32, u32 }, full, none };

fn howSelected(self: *const Input) HowSelected {
    if (!self.selectionAvailable()) return .none;
    const value = self._value orelse return .none;

    if (self._selection_start == self._selection_end) return .none;
    if (self._selection_start == 0 and self._selection_end == value.len) return .full;
    return .{ .partial = .{ self._selection_start, self._selection_end } };
}

pub fn innerInsert(self: *Input, str: []const u8, frame: *Frame) !void {
    const arena = frame.arena;

    switch (self.howSelected()) {
        .full => {
            // if the input is fully selected, replace the content.
            const new_value = try arena.dupe(u8, str);
            try self.setValue(new_value, frame);
            self._selection_start = @intCast(new_value.len);
            self._selection_end = @intCast(new_value.len);
            self._selection_direction = .none;
            try self.dispatchSelectionChangeEvent(frame);
        },
        .partial => |range| {
            // if the input is partially selected, replace the selected content.
            const current_value = self.getValue();
            const before = current_value[0..range[0]];
            const remaining = current_value[range[1]..];

            const new_value = try std.mem.concat(
                arena,
                u8,
                &.{ before, str, remaining },
            );
            try self.setValue(new_value, frame);

            const new_pos = range[0] + str.len;
            self._selection_start = @intCast(new_pos);
            self._selection_end = @intCast(new_pos);
            self._selection_direction = .none;
            try self.dispatchSelectionChangeEvent(frame);
        },
        .none => {
            // if the input is not selected, just insert at cursor.
            const current_value = self.getValue();
            const new_value = try std.mem.concat(arena, u8, &.{ current_value, str });
            try self.setValue(new_value, frame);
        },
    }
    try self.dispatchInputEvent(str, "insertText", frame);
}

pub fn getSelectionDirection(self: *const Input) []const u8 {
    return @tagName(self._selection_direction);
}

/// `selectionDirection` is read-write, which is what makes its descriptor an
/// accessor rather than the getter-only one this engine had -- and the kind is
/// what a bot check reads (see src/browser/tests/descriptor_kind.html).
///
/// Measured on headed Chrome 150 (probe-setter-semantics): an input type that
/// does not support selection throws InvalidStateError, and anything that is not
/// one of the three keywords -- including `null` -- normalises to "none" without
/// throwing, the same rule `setSelectionRange` already applies to its third
/// argument.
pub fn setSelectionDirection(self: *Input, value: ?[]const u8, frame: *Frame) !void {
    if (!self.selectionAvailable()) return self.noSelectionSupport("selectionDirection", frame);
    self._selection_direction = if (value) |v|
        std.meta.stringToEnum(Selection.SelectionDirection, v) orelse .none
    else
        .none;
    try self.dispatchSelectionChangeEvent(frame);
}

pub fn getSelectionStart(self: *const Input) !?u32 {
    if (!self.selectionAvailable()) return null;
    return self._selection_start;
}

pub fn setSelectionStart(self: *Input, value: u32, frame: *Frame) !void {
    if (!self.selectionAvailable()) return self.noSelectionSupport("selectionStart", frame);
    self._selection_start = value;
    try self.dispatchSelectionChangeEvent(frame);
}

pub fn getSelectionEnd(self: *const Input) !?u32 {
    if (!self.selectionAvailable()) return null;
    return self._selection_end;
}

pub fn setSelectionEnd(self: *Input, value: u32, frame: *Frame) !void {
    if (!self.selectionAvailable()) return self.noSelectionSupport("selectionEnd", frame);
    self._selection_end = value;
    try self.dispatchSelectionChangeEvent(frame);
}

pub fn setSelectionRange(
    self: *Input,
    selection_start: u32,
    selection_end: u32,
    selection_dir: ?[]const u8,
    frame: *Frame,
) !void {
    if (!self.selectionAvailable()) return error.InvalidStateError;

    const direction = blk: {
        if (selection_dir) |sd| {
            break :blk std.meta.stringToEnum(Selection.SelectionDirection, sd) orelse .none;
        } else break :blk .none;
    };

    const value = self._value orelse {
        self._selection_start = 0;
        self._selection_end = 0;
        self._selection_direction = .none;
        return;
    };

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

pub fn getLabels(self: *Input, frame: *Frame) !js.Array {
    if (self._input_type == .hidden) {
        return frame.js.local.?.newArray(0);
    }
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub fn getList(self: *Input, frame: *Frame) ?*HtmlElement.DataList {
    switch (self._input_type) {
        .hidden, .password, .checkbox, .radio, .file, .submit, .image, .reset, .button => return null,
        else => {},
    }

    const element = self.asElement();
    const list_id = element.getAttributeSafe(comptime .wrap("list")) orelse return null;

    // list= resolves in the input's own tree (shadow root or document).
    const target = frame.getElementByIdFromNode(element.asNode(), list_id) orelse return null;
    return target.is(HtmlElement.DataList);
}

pub fn getForm(self: *Input, frame: *Frame) ?*Form {
    return Form.ownerOf(self.asElement(), frame);
}

// Form submission attribute overrides
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#form-submission-0
// Mirrors Button's overrides — same spec semantics.

pub fn getFormAction(self: *Input, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const owner_url = element.ownerFrame(frame).url;
    const action = element.getAttributeSafe(comptime .wrap("formaction")) orelse return owner_url;
    if (action.len == 0) {
        return owner_url;
    }
    return element.asNode().resolveURLReflect(action, frame, .{});
}

pub fn setFormAction(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formaction"), .wrap(value), frame);
}

pub fn getFormEnctype(self: *const Input) []const u8 {
    return Form.normalizeEnctype(self.asConstElement().getAttributeSafe(comptime .wrap("formenctype")), "");
}

pub fn setFormEnctype(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formenctype"), .wrap(value), frame);
}

pub fn getFormMethod(self: *const Input) []const u8 {
    return Form.normalizeMethod(self.asConstElement().getAttributeSafe(comptime .wrap("formmethod")), "");
}

pub fn setFormMethod(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formmethod"), .wrap(value), frame);
}

pub fn getFormNoValidate(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(.wrap("formnovalidate")) != null;
}

pub fn setFormNoValidate(self: *Input, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(.wrap("formnovalidate"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(.wrap("formnovalidate"), frame);
    }
}

/// What `type=color` accepts. The spec's sanitizer only takes the 7-character
/// lowercase hex "simple color", but Chrome runs the CSS color parser and
/// serializes back to that form, so the short and alpha hex forms, the named
/// colors and every color function come through -- including the wide-gamut
/// ones, converted into sRGB: measured, `lab(50% 40 30)` reads `#bb5846` and
/// `color(display-p3 1 0 0)` reads `#ff0000`.
///
/// Surrounding whitespace is tolerated around the hex and function forms but
/// *not* around a bare name — `"#aabbcc "` reads `#aabbcc` while `"red "` reads
/// `#000000`. That asymmetry is measured, not derived
/// (tools/fingerprint/probes/probe-input-color.js, the `padding` group).
fn parseColorValue(value: []const u8) ?color.RGBA {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '#') {
        return color.RGBA.parse(trimmed) catch null;
    }
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) {
        // Measured: the wide-gamut functions come through here too, converted
        // into sRGB -- `lab(50% 40 30)` reads `#bb5846`.
        return (color.parseStyle(trimmed) orelse return null).rgba;
    }

    // A name, which the trim must not have changed.
    if (trimmed.len != value.len) return null;
    var buf: [32]u8 = undefined;
    if (trimmed.len > buf.len) return null;
    return color.RGBA.find(std.ascii.lowerString(buf[0..trimmed.len], trimmed));
}

/// Sanitize the value according to the current input type
fn sanitizeValue(self: *Input, comptime dupe: bool, value: []const u8, frame: *Frame) ![]const u8 {
    switch (self._input_type) {
        .text, .search, .tel, .password, .url, .email => {
            const sanitized = blk: {
                const first = std.mem.indexOfAny(u8, value, "\r\n") orelse {
                    break :blk if (comptime dupe) try frame.dupeString(value) else value;
                };

                var result = try frame.arena.alloc(u8, value.len);
                @memcpy(result[0..first], value[0..first]);

                var i: usize = first;
                for (value[first + 1 ..]) |c| {
                    if (c != '\r' and c != '\n') {
                        result[i] = c;
                        i += 1;
                    }
                }
                break :blk result[0..i];
            };

            return switch (self._input_type) {
                .url, .email => std.mem.trim(u8, sanitized, &std.ascii.whitespace),
                else => sanitized,
            };
        },
        .date => return if (isValidDate(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .month => return if (isValidMonth(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .week => return if (isValidWeek(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .time => return if (isValidTime(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .@"datetime-local" => return try sanitizeDatetimeLocal(dupe, value, frame.arena),
        .number => return if (isValidFloatingPoint(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .range => {
            const value_attr = self.asConstElement().getAttributeSafe(comptime .wrap("value")) orelse "";
            return try sanitizeRange(dupe, value, self.getMin(), self.getMax(), self.getStep(), value_attr, frame);
        },
        .color => {
            const rgba = parseColorValue(value) orelse return "#000000";
            const hex = rgba.toHex();
            // Already in the canonical form, so keep the caller's slice.
            if (std.mem.eql(u8, value, &hex)) {
                return if (comptime dupe) try frame.dupeString(value) else value;
            }
            return try frame.arena.dupe(u8, &hex);
        },
        .file => return "", // File: always empty
        .checkbox, .radio, .submit, .image, .reset, .button, .hidden => return if (comptime dupe) try frame.dupeString(value) else value, // no sanitization
    }
}

/// WHATWG "valid floating-point number" grammar check + overflow detection.
/// Rejects "+1", "1.", "Infinity", "NaN", "2e308", leading whitespace, trailing junk.
fn isValidFloatingPoint(value: []const u8) bool {
    if (value.len == 0) return false;
    var pos: usize = 0;

    // Optional leading minus (no plus allowed)
    if (value[pos] == '-') {
        pos += 1;
        if (pos >= value.len) return false;
    }

    // Must have one or both of: digit-sequence, dot+digit-sequence
    var has_integer = false;
    var has_decimal = false;

    if (pos < value.len and std.ascii.isDigit(value[pos])) {
        has_integer = true;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
    }

    if (pos < value.len and value[pos] == '.') {
        pos += 1;
        if (pos < value.len and std.ascii.isDigit(value[pos])) {
            has_decimal = true;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
        } else {
            return false; // dot without trailing digits ("1.")
        }
    }

    if (!has_integer and !has_decimal) return false;

    // Optional exponent: (e|E) [+|-] digits
    if (pos < value.len and (value[pos] == 'e' or value[pos] == 'E')) {
        pos += 1;
        if (pos >= value.len) return false;
        if (value[pos] == '+' or value[pos] == '-') {
            pos += 1;
            if (pos >= value.len) return false;
        }
        if (!std.ascii.isDigit(value[pos])) return false;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
    }

    if (pos != value.len) return false; // trailing junk

    // Grammar is valid; now check the parsed value doesn't overflow
    const f = std.fmt.parseFloat(f64, value) catch return false;
    return !std.math.isInf(f) and !std.math.isNan(f);
}

/// Validate a WHATWG "valid date string": YYYY-MM-DD
fn isValidDate(value: []const u8) bool {
    // Minimum: 4-digit year + "-MM-DD" = 10 chars
    if (value.len < 10) return false;
    const year_len = value.len - 6; // "-MM-DD" is always 6 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-' or value[year_len + 3] != '-') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const month = parseAllDigits(value[year_len + 1 .. year_len + 3]) orelse return false;
    if (month < 1 or month > 12) return false;
    const day = parseAllDigits(value[year_len + 4 .. year_len + 6]) orelse return false;
    if (day < 1 or day > daysInMonth(@intCast(year), @intCast(month))) return false;
    return true;
}

/// Validate a WHATWG "valid month string": YYYY-MM
fn isValidMonth(value: []const u8) bool {
    if (value.len < 7) return false;
    const year_len = value.len - 3; // "-MM" is 3 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const month = parseAllDigits(value[year_len + 1 .. year_len + 3]) orelse return false;
    return month >= 1 and month <= 12;
}

/// Validate a WHATWG "valid week string": YYYY-Www
fn isValidWeek(value: []const u8) bool {
    if (value.len < 8) return false;
    const year_len = value.len - 4; // "-Www" is 4 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-' or value[year_len + 1] != 'W') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const week = parseAllDigits(value[year_len + 2 .. year_len + 4]) orelse return false;
    if (week < 1) return false;
    return week <= maxWeeksInYear(@intCast(year));
}

/// Validate a WHATWG "valid time string": HH:MM[:SS[.s{1,3}]]
fn isValidTime(value: []const u8) bool {
    if (value.len < 5) return false;
    if (value[2] != ':') return false;
    const hour = parseAllDigits(value[0..2]) orelse return false;
    if (hour > 23) return false;
    const minute = parseAllDigits(value[3..5]) orelse return false;
    if (minute > 59) return false;
    if (value.len == 5) return true;

    // Optional seconds
    if (value.len < 8 or value[5] != ':') return false;
    const second = parseAllDigits(value[6..8]) orelse return false;
    if (second > 59) return false;
    if (value.len == 8) return true;

    // Optional fractional seconds: 1-3 digits
    if (value[8] != '.') return false;
    const frac_len = value.len - 9;
    if (frac_len < 1 or frac_len > 3) return false;
    for (value[9..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Sanitize datetime-local: validate and normalize, or return "".
/// Spec: if valid, normalize to "YYYY-MM-DDThh:mm" (shortest time form);
/// otherwise set to "".
fn sanitizeDatetimeLocal(comptime dupe: bool, value: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (value.len < 16) {
        return "";
    }

    // Find separator (T or space) by scanning for it before a valid time start
    var sep_pos: ?usize = null;
    if (value.len >= 16) {
        for (0..value.len - 4) |i| {
            if ((value[i] == 'T' or value[i] == ' ') and
                i + 3 < value.len and
                std.ascii.isDigit(value[i + 1]) and
                std.ascii.isDigit(value[i + 2]) and
                value[i + 3] == ':')
            {
                sep_pos = i;
                break;
            }
        }
    }
    const sep = sep_pos orelse return "";

    const date_part = value[0..sep];
    const time_part = value[sep + 1 ..];
    if (!isValidDate(date_part) or !isValidTime(time_part)) {
        return "";
    }

    // Already normalized? (T separator and no trailing :00 or :00.000)
    if (value[sep] == 'T' and time_part.len == 5) {
        return if (comptime dupe) arena.dupe(u8, value) else value;
    }

    // Parse time components for normalization
    const second: u32 = if (time_part.len >= 8) (parseAllDigits(time_part[6..8]) orelse return "") else 0;
    var has_nonzero_frac = false;
    var frac_end: usize = 0;
    if (time_part.len > 9 and time_part[8] == '.') {
        for (time_part[9..], 0..) |c, fi| {
            if (c != '0') has_nonzero_frac = true;
            frac_end = fi + 1;
        }
        // Strip trailing zeros from fractional part
        while (frac_end > 0 and time_part[9 + frac_end - 1] == '0') : (frac_end -= 1) {}
    }

    // Build shortest time: HH:MM, or HH:MM:SS, or HH:MM:SS.fff
    const need_seconds = second != 0 or has_nonzero_frac;
    const time_len: usize = if (need_seconds) (if (frac_end > 0) 9 + frac_end else 8) else 5;
    const total_len = date_part.len + 1 + time_len;

    const result = try arena.alloc(u8, total_len);
    @memcpy(result[0..date_part.len], date_part);
    result[date_part.len] = 'T';
    @memcpy(result[date_part.len + 1 ..][0..5], time_part[0..5]);

    if (need_seconds) {
        @memcpy(result[date_part.len + 6 ..][0..3], time_part[5..8]);
        if (frac_end > 0) {
            result[date_part.len + 9] = '.';
            @memcpy(result[date_part.len + 10 ..][0..frac_end], time_part[9..][0..frac_end]);
        }
    }
    return result[0..total_len];
}

/// Sanitize value for `<input type=range>` per WHATWG HTML spec:
/// https://html.spec.whatwg.org/multipage/input.html#range-state-(type=range)
///   1. If value is not a valid floating-point number, set it to
///      `min + (max - min) / 2`.
///   2. If value < min, set it to min.
///   3. If value > max, set it to max.
///   4. If value is not on the step ladder (`step base + step * n` for integer
///      `n`), round to nearest valid value, ties up. The rounded value must
///      stay in `[min, max]`; if rounding up exceeds max, use the rounded-down
///      neighbor instead.
/// `min`/`max` default to 0 and 100 respectively when the attribute is missing
/// or fails to parse as a valid floating-point number. `step` defaults to 1;
/// `step="any"` (case-insensitive) disables step matching. The step base
/// (https://html.spec.whatwg.org/multipage/input.html#concept-input-min) falls
/// back through `min` content attr → `value` content attr → 0.
fn sanitizeRange(
    comptime dupe: bool,
    value: []const u8,
    min_attr: []const u8,
    max_attr: []const u8,
    step_attr: []const u8,
    value_attr: []const u8,
    frame: *Frame,
) ![]const u8 {
    _ = dupe; // range always re-serializes the number, so nothing is kept
    const min: f64 = if (isValidFloatingPoint(min_attr))
        std.fmt.parseFloat(f64, min_attr) catch 0
    else
        0;
    // A max below the min collapses the range onto the min rather than letting
    // the clamp read its bounds backwards.
    const max: f64 = @max(min, if (isValidFloatingPoint(max_attr))
        std.fmt.parseFloat(f64, max_attr) catch 100
    else
        100);
    const step_base: f64 = if (isValidFloatingPoint(min_attr))
        std.fmt.parseFloat(f64, min_attr) catch 0
    else if (isValidFloatingPoint(value_attr))
        std.fmt.parseFloat(f64, value_attr) catch 0
    else
        0;

    // Unlike every other numeric type, range has no empty state: an
    // unrepresentable value becomes the midpoint of the range.
    const v0 = if (isValidFloatingPoint(value))
        std.fmt.parseFloat(f64, value) catch unreachable // grammar already validated
    else
        min + (max - min) / 2;

    const clamped = std.math.clamp(v0, min, max);
    const snapped = snapToStep(clamped, min, max, step_base, step_attr);
    return try formatFloat(frame.arena, roundToLadderPrecision(snapped, step_base, step_attr));
}

/// Blink holds the range value in a decimal type, so a ladder of `0 + n * 0.1`
/// serializes as "0.3" where the same arithmetic in binary floating point gives
/// 0.30000000000000004. Rounding to the decimal places the ladder's own inputs
/// carry reproduces that without a decimal type, since a rung can never need
/// more places than its base and step do.
fn roundToLadderPrecision(value: f64, step_base: f64, step_attr: []const u8) f64 {
    if (std.ascii.eqlIgnoreCase(step_attr, "any")) return value;
    const places = @max(decimalPlaces(step_attr), decimalPlaces(formatFloatBuf(step_base)));
    if (places == 0) return value;
    const scale = std.math.pow(f64, 10, @floatFromInt(places));
    return @round(value * scale) / scale;
}

/// Digits after the decimal point, or 0 for a spelling this cannot answer for
/// (exponential notation, or no fraction at all).
fn decimalPlaces(text: []const u8) usize {
    if (std.mem.indexOfAny(u8, text, "eE") != null) return 0;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return 0;
    return text.len - dot - 1;
}

/// `decimalPlaces` needs the step base as text, and the base came from an f64.
threadlocal var float_buf: [32]u8 = undefined;
fn formatFloatBuf(value: f64) []const u8 {
    return std.fmt.bufPrint(&float_buf, "{d}", .{value}) catch "0";
}

/// Snap `value` (already clamped to `[min, max]`) to the nearest value on the
/// step ladder `step_base + step * n`. Ties round up; if the rounded-up
/// neighbor exceeds `max`, use the rounded-down neighbor. Returns `value`
/// unchanged for `step="any"` (case-insensitive) or when no ladder rung lands
/// in `[min, max]`.
fn snapToStep(value: f64, min: f64, max: f64, step_base: f64, step_attr: []const u8) f64 {
    if (std.ascii.eqlIgnoreCase(step_attr, "any")) return value;

    const step: f64 = blk: {
        if (isValidFloatingPoint(step_attr)) {
            const s = std.fmt.parseFloat(f64, step_attr) catch break :blk 1;
            if (s > 0) break :blk s;
        }
        break :blk 1;
    };

    const diff = (value - step_base) / step;
    const n_floor = @floor(diff);
    const n_ceil = @ceil(diff);
    const n: f64 = if (n_floor == n_ceil) n_floor else blk: {
        const dist_floor = diff - n_floor;
        const dist_ceil = n_ceil - diff;
        if (dist_ceil < dist_floor) break :blk n_ceil;
        if (dist_floor < dist_ceil) break :blk n_floor;
        break :blk n_ceil; // tie -> round up
    };

    var candidate = step_base + n * step;
    if (candidate > max) candidate = step_base + (n - 1) * step;
    if (candidate < min) return value; // no valid rung in range; leave clamped value
    return candidate;
}

/// Format an f64 to its shortest decimal representation, arena-allocated.
fn formatFloat(arena: std.mem.Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

/// Parse a slice that must be ALL ASCII digits into a u32. Returns null if any non-digit or empty.
fn parseAllDigits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var result: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        result = result *% 10 +% (c - '0');
    }
    return result;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else 28,
        else => 0,
    };
}

/// ISO 8601: a year has 53 weeks if Jan 1 is Thursday, or Jan 1 is Wednesday and leap year.
fn maxWeeksInYear(year: u32) u32 {
    // Gauss's algorithm for Jan 1 day-of-week
    // dow: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
    const y1 = year - 1;
    const dow = (1 + 5 * (y1 % 4) + 4 * (y1 % 100) + 6 * (y1 % 400)) % 7;
    if (dow == 4) return 53; // Jan 1 is Thursday
    if (dow == 3 and isLeapYear(year)) return 53; // Jan 1 is Wednesday + leap year
    return 52;
}

fn uncheckRadioGroup(self: *Input, frame: *Frame) void {
    var iter = self.radioGroupIterator() orelse return;
    const my_form = self.getForm(frame);
    while (iter.next()) |other| {
        if (other == self) continue;
        if (!sameFormOwner(my_form, other, frame)) continue;
        other._checked = false;
    }
}

pub fn getPopoverTargetElement(self: *Input, frame: *Frame) ?*Element {
    return popover.invokerTarget(self.asNode(), self._popover_target, frame);
}

pub fn setPopoverTargetElement(self: *Input, value: ?*Element, frame: *Frame) !void {
    self._popover_target = value;
    if (value == null) {
        try self.asElement().removeAttribute(.wrap("popovertarget"), frame);
    } else {
        try self.asElement().setAttribute(.wrap("popovertarget"), .wrap(""), frame);
    }
}

pub fn getPopoverTargetAction(self: *Input) []const u8 {
    return @tagName(popover.getInvokerAction(self.asElement()));
}

pub fn setPopoverTargetAction(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttribute(.wrap("popovertargetaction"), .wrap(value), frame);
}

pub fn getMax(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("max")) orelse "";
}

pub fn getMin(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("min")) orelse "";
}

pub fn getRequired(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn getStep(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("step")) orelse "";
}

/// The entries a directory drop left on the input. Nothing can drop one here,
/// so the list is always empty -- but Chrome answers an empty array rather
/// than nothing at all, whatever the input's type is, and the difference
/// between an empty array and `undefined` is what a guard reads.
///
/// A fresh frozen array on every read, which is Chrome's behaviour (measured:
/// two reads compare unequal, and each is frozen).
pub fn getWebkitEntries(_: *const Input) js.FrozenArray(*filesystem.Entry) {
    return .empty;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Input);

    pub const Meta = struct {
        pub const name = "HTMLInputElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Input);

    /// Handles [LegacyNullToEmptyString]: null → "" per HTML spec.
    fn setValueFromJS(self: *Input, js_value: js.Value, frame: *Frame) !void {
        if (js_value.isNull()) {
            return self.setValue("", frame);
        }
        return self.setValue(try js_value.toZig([]const u8), frame);
    }

    // Chrome's order. No `onselectionchange`: it belongs to
    // GlobalEventHandlers, so Chrome carries it on HTMLElement.prototype and
    // not here (measured).
    pub const accept = reflect.string("accept");
    pub const alt = reflect.string("alt");
    pub const autocomplete = reflect.string("autocomplete");
    pub const defaultChecked = bridge.accessor(Input.getDefaultChecked, Input.setDefaultChecked, .{ .ce_reactions = true });
    pub const checked = bridge.accessor(Input.getChecked, Input.setChecked, .{});
    pub const dirName = reflect.string("dirname");
    pub const disabled = bridge.accessor(Input.getDisabled, Input.setDisabled, .{ .ce_reactions = true });
    pub const form = bridge.accessor(Input.getForm, null, .{});
    pub const files = bridge.accessor(Input.getFiles, Input.setFilesFromList, .{});
    pub const formAction = bridge.accessor(Input.getFormAction, Input.setFormAction, .{});
    pub const formEnctype = bridge.accessor(Input.getFormEnctype, Input.setFormEnctype, .{});
    pub const formMethod = bridge.accessor(Input.getFormMethod, Input.setFormMethod, .{});
    pub const formNoValidate = bridge.accessor(Input.getFormNoValidate, Input.setFormNoValidate, .{});
    pub const formTarget = reflect.string("formtarget");

    pub const height = bridge.accessor(_height, _setHeight, .{ .ce_reactions = true });
    fn _height(self: *const Input) u32 {
        return self.getDimension("height");
    }
    fn _setHeight(self: *Input, value_: u32, frame: *Frame) !void {
        var buf: [16]u8 = undefined;
        return self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(try std.fmt.bufPrint(&buf, "{d}", .{value_})), frame);
    }

    pub const indeterminate = bridge.accessor(Input.getIndeterminate, Input.setIndeterminate, .{});
    pub const list = bridge.accessor(Input.getList, null, .{});
    pub const max = reflect.string("max");
    pub const maxLength = reflect.limitedLong("maxlength", "maxLength");
    pub const min = reflect.string("min");
    pub const minLength = reflect.limitedLong("minlength", "minLength");
    pub const multiple = reflect.boolean("multiple");
    pub const name = reflect.string("name");
    pub const pattern = reflect.string("pattern");
    pub const placeholder = reflect.string("placeholder");
    pub const readOnly = reflect.boolean("readonly");
    pub const required = reflect.boolean("required");
    pub const size = reflect.unsignedLong("size", .{ .default = 20, .positive = true });
    pub const src = bridge.accessor(Input.getSrc, Input.setSrc, .{ .ce_reactions = true });
    pub const step = reflect.string("step");
    pub const @"type" = bridge.accessor(Input.getType, Input.setType, .{ .ce_reactions = true });
    pub const defaultValue = bridge.accessor(Input.getDefaultValue, Input.setDefaultValue, .{ .ce_reactions = true });
    pub const value = bridge.accessor(Input.getValueForJS, setValueFromJS, .{ .ce_reactions = true });
    pub const valueAsDate = bridge.accessor(Input.getValueAsDate, Input.setValueAsDate, .{});
    pub const valueAsNumber = bridge.accessor(Input.getValueAsNumber, Input.setValueAsNumber, .{});

    pub const width = bridge.accessor(_width, _setWidth, .{ .ce_reactions = true });
    fn _width(self: *const Input) u32 {
        return self.getDimension("width");
    }
    fn _setWidth(self: *Input, value_: u32, frame: *Frame) !void {
        var buf: [16]u8 = undefined;
        return self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(try std.fmt.bufPrint(&buf, "{d}", .{value_})), frame);
    }

    pub const willValidate = bridge.accessor(Input.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Input.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Input.getValidationMessage, null, .{});
    pub const labels = bridge.accessor(Input.getLabels, null, .{});
    pub const selectionStart = bridge.accessor(Input.getSelectionStart, Input.setSelectionStart, .{});
    pub const selectionEnd = bridge.accessor(Input.getSelectionEnd, Input.setSelectionEnd, .{});
    pub const selectionDirection = bridge.accessor(Input.getSelectionDirection, Input.setSelectionDirection, .{});
    pub const @"align" = reflect.string("align");
    pub const useMap = reflect.string("usemap");
    pub const webkitdirectory = reflect.boolean("webkitdirectory");
    pub const incremental = reflect.boolean("incremental");
    pub const popoverTargetElement = bridge.accessor(Input.getPopoverTargetElement, Input.setPopoverTargetElement, .{ .ce_reactions = true });
    pub const popoverTargetAction = bridge.accessor(Input.getPopoverTargetAction, Input.setPopoverTargetAction, .{ .ce_reactions = true });
    pub const checkValidity = bridge.function(Input.checkValidity, .{});
    pub const reportValidity = bridge.function(Input.reportValidity, .{});
    pub const select = bridge.function(Input.select, .{});
    pub const setCustomValidity = bridge.function(Input.setCustomValidity, .{});
    pub const setRangeText = bridge.function(Input.setRangeText, .{ .arity = 1 });
    pub const setSelectionRange = bridge.function(Input.setSelectionRange, .{});
    pub const showPicker = bridge.function(Input.showPicker, .{});
    pub const stepDown = bridge.function(Input.stepDown, .{ .arity = 0 });
    pub const stepUp = bridge.function(Input.stepUp, .{ .arity = 0 });
    pub const webkitEntries = bridge.accessor(Input.getWebkitEntries, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        var self = node.as(Input);
        const element = self.asElement();

        // Store initial values from attributes
        self._default_value = element.getAttributeSafe(comptime .wrap("value"));
        self._default_checked = element.getAttributeSafe(comptime .wrap("checked")) != null;

        self._checked = self._default_checked;

        self._input_type = if (element.getAttributeSafe(comptime .wrap("type"))) |type_attr|
            Type.fromString(type_attr)
        else
            .text;

        // Sanitize initial value per input type (e.g. date rejects "invalid-date").
        try self.seedValue(frame);

        // If this is a checked radio button, uncheck others in its group
        if (self._checked and self._input_type == .radio) {
            self.uncheckRadioGroup(frame);
        }
    }

    pub fn attributeChange(element: *Element, name: String, value: String, frame: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked, min, max, step }, name.str()) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => try self.retype(Type.fromString(value.str()), frame),
            .value => {
                self._default_value = try frame.arena.dupe(u8, value.str());
                try self.seedValue(frame);
            },
            .min, .max, .step => try self.reclamp(frame),
            .checked => {
                self._default_checked = true;
                // Only update checked state if it hasn't been manually modified
                if (!self._checked_dirty) {
                    self._checked = true;
                    // If setting a radio button to checked, uncheck others in the group
                    if (self._input_type == .radio) {
                        self.uncheckRadioGroup(frame);
                    }
                }
            },
        }
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked, min, max, step }, name.str()) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => try self.retype(.text, frame),
            .value => {
                self._default_value = null;
                try self.seedValue(frame);
            },
            .min, .max, .step => try self.reclamp(frame),
            .checked => {
                self._default_checked = false;
                // Only update checked state if it hasn't been manually modified
                if (!self._checked_dirty) {
                    self._checked = false;
                }
            },
        }
    }

    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, _: *Frame) !void {
        _ = deep;
        const source = source_element.as(Input);
        const clone = cloned_element.as(Input);

        // Copy runtime state from source to clone
        clone._value = source._value;
        clone._value_dirty = source._value_dirty;
        clone._checked = source._checked;
        clone._checked_dirty = source._checked_dirty;
        clone._selection_direction = source._selection_direction;
        clone._selection_start = source._selection_start;
        clone._selection_end = source._selection_end;
        clone._indeterminate = source._indeterminate;
    }
};

const testing = @import("../../../../testing.zig");
const EventTarget = @import("../../EventTarget.zig");
test "WebApi: HTML.Input" {
    try testing.htmlRunner("element/html/input.html", .{});
    try testing.htmlRunner("element/html/input_click.html", .{});
    try testing.htmlRunner("element/html/input_image_submit.html", .{});
    try testing.htmlRunner("element/html/input_radio.html", .{});
    try testing.htmlRunner("element/html/input-attrs.html", .{});
    try testing.htmlRunner("element/html/input-validity.html", .{});
    try testing.htmlRunner("element/html/input_file.html", .{});
    try testing.htmlRunner("element/html/input_value_mode.html", .{});
    try testing.htmlRunner("element/html/input_value_sanitize.html", .{});
    try testing.htmlRunner("element/html/input_color_value.html", .{});
    try testing.htmlRunner("element/html/input_range_value.html", .{});
}

test "isValidFloatingPoint" {
    // Valid
    try testing.expect(isValidFloatingPoint("1"));
    try testing.expect(isValidFloatingPoint("0.5"));
    try testing.expect(isValidFloatingPoint("-1"));
    try testing.expect(isValidFloatingPoint("-0.5"));
    try testing.expect(isValidFloatingPoint("1e10"));
    try testing.expect(isValidFloatingPoint("1E10"));
    try testing.expect(isValidFloatingPoint("1e+10"));
    try testing.expect(isValidFloatingPoint("1e-10"));
    try testing.expect(isValidFloatingPoint("0.123"));
    try testing.expect(isValidFloatingPoint(".5"));
    // Invalid
    try testing.expect(!isValidFloatingPoint(""));
    try testing.expect(!isValidFloatingPoint("+1"));
    try testing.expect(!isValidFloatingPoint("1."));
    try testing.expect(!isValidFloatingPoint("Infinity"));
    try testing.expect(!isValidFloatingPoint("NaN"));
    try testing.expect(!isValidFloatingPoint(" 1"));
    try testing.expect(!isValidFloatingPoint("1 "));
    try testing.expect(!isValidFloatingPoint("1e"));
    try testing.expect(!isValidFloatingPoint("1e+"));
    try testing.expect(!isValidFloatingPoint("2e308")); // overflow
}

test "isValidDate" {
    try testing.expect(isValidDate("2024-01-01"));
    try testing.expect(isValidDate("2024-02-29")); // leap year
    try testing.expect(isValidDate("2024-12-31"));
    try testing.expect(isValidDate("10000-01-01")); // >4-digit year
    try testing.expect(!isValidDate("2024-02-30")); // invalid day
    try testing.expect(!isValidDate("2023-02-29")); // not leap year
    try testing.expect(!isValidDate("2024-13-01")); // invalid month
    try testing.expect(!isValidDate("2024-00-01")); // month 0
    try testing.expect(!isValidDate("0000-01-01")); // year 0
    try testing.expect(!isValidDate("2024-1-01")); // single-digit month
    try testing.expect(!isValidDate(""));
    try testing.expect(!isValidDate("not-a-date"));
}

test "isValidMonth" {
    try testing.expect(isValidMonth("2024-01"));
    try testing.expect(isValidMonth("2024-12"));
    try testing.expect(!isValidMonth("2024-00"));
    try testing.expect(!isValidMonth("2024-13"));
    try testing.expect(!isValidMonth("0000-01"));
    try testing.expect(!isValidMonth(""));
}

test "isValidWeek" {
    try testing.expect(isValidWeek("2024-W01"));
    try testing.expect(isValidWeek("2024-W52"));
    try testing.expect(isValidWeek("2020-W53")); // 2020 has 53 weeks
    try testing.expect(!isValidWeek("2024-W00"));
    try testing.expect(!isValidWeek("2024-W54"));
    try testing.expect(!isValidWeek("0000-W01"));
    try testing.expect(!isValidWeek(""));
}

test "isValidTime" {
    try testing.expect(isValidTime("00:00"));
    try testing.expect(isValidTime("23:59"));
    try testing.expect(isValidTime("12:30:45"));
    try testing.expect(isValidTime("12:30:45.1"));
    try testing.expect(isValidTime("12:30:45.12"));
    try testing.expect(isValidTime("12:30:45.123"));
    try testing.expect(!isValidTime("24:00"));
    try testing.expect(!isValidTime("12:60"));
    try testing.expect(!isValidTime("12:30:60"));
    try testing.expect(!isValidTime("12:30:45.1234")); // >3 frac digits
    try testing.expect(!isValidTime("12:30:45.")); // dot without digits
    try testing.expect(!isValidTime(""));
}

test "sanitizeDatetimeLocal" {
    const allocator = testing.allocator;
    // Already normalized — returns input slice, no allocation
    try testing.expectEqual("2024-01-01T12:30", try sanitizeDatetimeLocal(false, "2024-01-01T12:30", allocator));
    // Space separator → T (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01 12:30", allocator);
        try testing.expectEqual("2024-01-01T12:30", result);
        allocator.free(result);
    }
    // Strip trailing :00 (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:00", allocator);
        try testing.expectEqual("2024-01-01T12:30", result);
        allocator.free(result);
    }
    // Keep non-zero seconds (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:45", allocator);
        try testing.expectEqual("2024-01-01T12:30:45", result);
        allocator.free(result);
    }
    // Keep fractional seconds, strip trailing zeros (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:45.100", allocator);
        try testing.expectEqual("2024-01-01T12:30:45.1", result);
        allocator.free(result);
    }
    // Invalid → "" (no allocation)
    try testing.expectEqual("", try sanitizeDatetimeLocal(false, "not-a-datetime", allocator));
    try testing.expectEqual("", try sanitizeDatetimeLocal(false, "", allocator));
}

test "parseAllDigits" {
    try testing.expectEqual(@as(?u32, 0), parseAllDigits("0"));
    try testing.expectEqual(@as(?u32, 123), parseAllDigits("123"));
    try testing.expectEqual(@as(?u32, 2024), parseAllDigits("2024"));
    try testing.expectEqual(@as(?u32, null), parseAllDigits(""));
    try testing.expectEqual(@as(?u32, null), parseAllDigits("12a"));
    try testing.expectEqual(@as(?u32, null), parseAllDigits("abc"));
}

test "daysInMonth" {
    try testing.expectEqual(@as(u32, 31), daysInMonth(2024, 1));
    try testing.expectEqual(@as(u32, 29), daysInMonth(2024, 2)); // leap
    try testing.expectEqual(@as(u32, 28), daysInMonth(2023, 2)); // non-leap
    try testing.expectEqual(@as(u32, 30), daysInMonth(2024, 4));
    try testing.expectEqual(@as(u32, 29), daysInMonth(2000, 2)); // century leap
    try testing.expectEqual(@as(u32, 28), daysInMonth(1900, 2)); // century non-leap
}

test "maxWeeksInYear" {
    try testing.expectEqual(@as(u32, 52), maxWeeksInYear(2024));
    try testing.expectEqual(@as(u32, 53), maxWeeksInYear(2020)); // Jan 1 = Wed + leap
    try testing.expectEqual(@as(u32, 53), maxWeeksInYear(2015)); // Jan 1 = Thu
    try testing.expectEqual(@as(u32, 52), maxWeeksInYear(2023));
}
