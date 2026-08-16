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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// https://w3c.github.io/edit-context/
//
// EditContext exists here because HTMLElement.prototype.editContext does: the
// setter has to type-check against it, and a prototype slot whose type is not
// a global is a shape no browser has. There is no IME, no composition and no
// caret behind it -- what it models is the plain text buffer plus the
// selection, which is what a page can observe without one.
//
// Measured on a headed Chrome 150 (probe-g20e/g20h/g20j):
//
//   * The prototype is EventTarget's, and the five on* attributes are real
//     event handler attributes: `ec.dispatchEvent(new Event('textupdate'))`
//     fires ontextupdate.
//   * attachedElements() and characterBounds() are *methods*, not getters, and
//     each call hands back a fresh array (a === b is false).
//   * EditContextInit's selectionStart/selectionEnd are plain `unsigned long`
//     -- ToUint32 rather than [EnforceRange], so -1 wraps to 4294967295 and
//     NaN/Infinity/{}/null become 0 -- and are then clamped to the text length.
//     The offsets count UTF-16 code units, so '\u{1F600}ab' is length 4.
//   * updateText normalises its range (updateText(4, 2, 'X') and
//     updateText(2, 4, 'X') do the same thing) but does not touch the
//     selection, which can be left pointing past the end of the new text.
//   * updateCharacterBounds is inert outside a composition: after
//     `updateCharacterBounds(0, [new DOMRect(0, 0, 1, 1)])`, characterBounds()
//     is still empty and characterBoundsRangeStart is still 0.

const std = @import("std");
const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const DOMRect = @import("DOMRect.zig");
const Element = @import("Element.zig");
const EventTarget = @import("EventTarget.zig");
const dictionary = @import("dictionary.zig");
const global_event_handlers = @import("global_event_handlers.zig");

const Execution = js.Execution;
const GlobalEventHandler = global_event_handlers.Handler;

const EditContext = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_text: []const u8 = "",
/// Offsets are UTF-16 code units, matching what a page sees on `.text.length`.
_selection_start: u32 = 0,
_selection_end: u32 = 0,
_character_bounds_range_start: u32 = 0,
/// The element this context is attached to, if any. One at a time: attaching a
/// context that already has a host is a NotSupportedError.
_host: ?*Element = null,

const Init = dictionary.Reader("EditContext", "EditContextInit");

pub fn constructor(options: ?js.Value, exec: *const Execution) !*EditContext {
    const frame = exec.js.global.frame;
    const reader = try Init.read(options, exec);

    const text = try reader.string("text", "", frame.arena);
    const length = utf16Len(text);
    const self = try frame._factory.eventTarget(EditContext{
        ._proto = undefined,
        ._text = text,
        ._selection_start = @min(try uint32Member(reader, "selectionStart"), length),
        ._selection_end = @min(try uint32Member(reader, "selectionEnd"), length),
    });
    self._proto._type = .{ .edit_context = self };
    return self;
}

/// `unsigned long` without [EnforceRange]: ToUint32, so out-of-range and
/// non-finite values wrap or become zero rather than throwing.
fn uint32Member(reader: Init, comptime name: []const u8) !u32 {
    const member = (try reader.present(name)) orelse return 0;
    const number = member.toF64() catch return 0;
    if (!std.math.isFinite(number)) {
        return 0;
    }
    const truncated = @trunc(number);
    const wrapped = @mod(truncated, 4294967296);
    return @intFromFloat(if (wrapped < 0) wrapped + 4294967296 else wrapped);
}

pub fn asEventTarget(self: *EditContext) *EventTarget {
    return self._proto;
}

pub fn getText(self: *const EditContext) []const u8 {
    return self._text;
}

pub fn getSelectionStart(self: *const EditContext) u32 {
    return self._selection_start;
}

pub fn getSelectionEnd(self: *const EditContext) u32 {
    return self._selection_end;
}

pub fn getCharacterBoundsRangeStart(self: *const EditContext) u32 {
    return self._character_bounds_range_start;
}

/// A fresh array each call, as in Chrome.
pub fn attachedElements(self: *EditContext, frame: *Frame) ![]const *Element {
    const host = self._host orelse return &.{};
    const elements = try frame.local_arena.alloc(*Element, 1);
    elements[0] = host;
    return elements;
}

/// Always empty: character bounds only exist during a composition, and there
/// is no IME here to start one.
pub fn characterBounds(_: *EditContext) []const *DOMRect {
    return &.{};
}

pub fn updateText(self: *EditContext, args: []js.Value, exec: *const Execution) !void {
    try requireArgs("updateText", 3, args, exec);
    const a = try toUint32(args[0]);
    const b = try toUint32(args[1]);
    const replacement = try args[2].toStringSliceWithAlloc(exec.js.global.frame.arena);

    const length = utf16Len(self._text);
    const start = @min(@min(a, b), length);
    const end = @min(@max(a, b), length);

    const frame = exec.js.global.frame;
    var buf = std.Io.Writer.Allocating.init(frame.arena);
    try buf.writer.writeAll(self._text[0..utf8Offset(self._text, start)]);
    try buf.writer.writeAll(replacement);
    try buf.writer.writeAll(self._text[utf8Offset(self._text, end)..]);
    self._text = buf.written();
}

/// Each offset is clamped to the text length independently: Chrome does not
/// order them, so updateSelection(4, 2) reads back as 4 and 2.
pub fn updateSelection(self: *EditContext, args: []js.Value, exec: *const Execution) !void {
    try requireArgs("updateSelection", 2, args, exec);
    const length = utf16Len(self._text);
    self._selection_start = @min(try toUint32(args[0]), length);
    self._selection_end = @min(try toUint32(args[1]), length);
}

/// The bounds are what a UA would place an IME window against. Nothing here
/// renders, so they are validated and dropped.
pub fn updateControlBounds(self: *EditContext, args: []js.Value, exec: *const Execution) !void {
    return self.takeRect("updateControlBounds", args, exec);
}

pub fn updateSelectionBounds(self: *EditContext, args: []js.Value, exec: *const Execution) !void {
    return self.takeRect("updateSelectionBounds", args, exec);
}

fn takeRect(_: *EditContext, comptime member: []const u8, args: []js.Value, exec: *const Execution) !void {
    try requireArgs(member, 1, args, exec);
    _ = args[0].toZig(*DOMRect) catch return dictionary.throwTypeError(
        "Failed to execute '" ++ member ++ "' on 'EditContext': parameter 1 is not of type 'DOMRect'.",
        exec,
    );
}

pub fn updateCharacterBounds(_: *EditContext, args: []js.Value, exec: *const Execution) !void {
    try requireArgs("updateCharacterBounds", 2, args, exec);
    _ = try toUint32(args[0]);
    if (!args[1].isArray()) {
        return dictionary.throwTypeError(
            "Failed to execute 'updateCharacterBounds' on 'EditContext': The provided value cannot be converted to a sequence.",
            exec,
        );
    }
}

fn requireArgs(comptime member: []const u8, comptime required: usize, args: []js.Value, exec: *const Execution) !void {
    if (args.len >= required) {
        return;
    }
    return dictionary.throwTypeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ member ++ "' on 'EditContext': {d} argument{s} required, but only {d} present.",
        .{ required, if (required == 1) "" else "s", args.len },
    ), exec);
}

fn toUint32(value: js.Value) !u32 {
    const number = value.toF64() catch return 0;
    if (!std.math.isFinite(number)) {
        return 0;
    }
    const wrapped = @mod(@trunc(number), 4294967296);
    return @intFromFloat(if (wrapped < 0) wrapped + 4294967296 else wrapped);
}

/// Length of a UTF-8 string in UTF-16 code units. Invalid bytes count as one
/// unit each, matching the replacement character a lossy decode would produce.
fn utf16Len(text: []const u8) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            units += 1;
            continue;
        };
        if (i + size > text.len) break;
        units += if (size == 4) 2 else 1;
        i += size;
    }
    return units;
}

/// Byte offset of the given UTF-16 code unit index. An index that lands inside
/// a surrogate pair rounds down to the start of that pair, which is what
/// splitting a JS string there would effectively do.
fn utf8Offset(text: []const u8, index: u32) usize {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (units >= index) return i;
        const size = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            units += 1;
            continue;
        };
        if (i + size > text.len) break;
        units += if (size == 4) 2 else 1;
        i += size;
    }
    return text.len;
}

// --- element attachment -----------------------------------------------------

/// Chrome refuses a host outside this set with "This element does not support
/// EditContext" -- measured over 120 tags. Any element whose local name is a
/// valid custom element name (it contains a hyphen) is accepted whether or not
/// a definition has been registered, while a hyphen-less unknown element is
/// not.
pub fn isValidHost(element: *Element) bool {
    if (element._namespace != .html) {
        return false;
    }
    const name = element.getLocalName();
    if (std.mem.indexOfScalar(u8, name, '-') != null) {
        return true;
    }
    const hosts = [_][]const u8{
        "article", "aside", "blockquote", "body",    "canvas", "div", "footer",
        "h1",      "h2",    "h3",         "h4",      "h5",     "h6",  "header",
        "main",    "nav",   "p",          "section", "span",
    };
    for (hosts) |host| {
        if (std.mem.eql(u8, name, host)) return true;
    }
    return false;
}

pub fn attach(self: *EditContext, element: *Element) !void {
    if (self._host) |host| {
        if (host == element) {
            return;
        }
        return error.EditContextInUse;
    }
    self._host = element;
}

pub fn detach(self: *EditContext) void {
    self._host = null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EditContext);

    pub const Meta = struct {
        pub const name = "EditContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn handler(comptime which: GlobalEventHandler) type {
        return struct {
            fn get(self: *EditContext, frame: *Frame) ?js.Function.Global {
                return frame._event_target_attr_listeners.get(.{ .target = self.asEventTarget(), .handler = which });
            }
            fn set(self: *EditContext, callback: ?js.Function.Global, frame: *Frame) !void {
                return frame.setEventHandler(self.asEventTarget(), which, callback);
            }
        };
    }

    pub const text = bridge.accessor(EditContext.getText, null, .{});
    pub const selectionStart = bridge.accessor(EditContext.getSelectionStart, null, .{});
    pub const selectionEnd = bridge.accessor(EditContext.getSelectionEnd, null, .{});
    pub const characterBoundsRangeStart = bridge.accessor(EditContext.getCharacterBoundsRangeStart, null, .{});
    pub const ontextupdate = bridge.accessor(handler(.ontextupdate).get, handler(.ontextupdate).set, .{});
    pub const ontextformatupdate = bridge.accessor(handler(.ontextformatupdate).get, handler(.ontextformatupdate).set, .{});
    pub const oncharacterboundsupdate = bridge.accessor(handler(.oncharacterboundsupdate).get, handler(.oncharacterboundsupdate).set, .{});
    pub const oncompositionstart = bridge.accessor(handler(.oncompositionstart).get, handler(.oncompositionstart).set, .{});
    pub const oncompositionend = bridge.accessor(handler(.oncompositionend).get, handler(.oncompositionend).set, .{});
    pub const attachedElements = bridge.function(EditContext.attachedElements, .{ .arity = 0 });
    pub const characterBounds = bridge.function(EditContext.characterBounds, .{ .arity = 0 });
    pub const updateCharacterBounds = bridge.function(EditContext.updateCharacterBounds, .{ .arity = 2 });
    pub const updateControlBounds = bridge.function(EditContext.updateControlBounds, .{ .arity = 1 });
    pub const updateSelection = bridge.function(EditContext.updateSelection, .{ .arity = 2 });
    pub const updateSelectionBounds = bridge.function(EditContext.updateSelectionBounds, .{ .arity = 1 });
    pub const updateText = bridge.function(EditContext.updateText, .{ .arity = 3 });
    pub const constructor = bridge.constructor(EditContext.constructor, .{ .arity = 0 });
};

const testing = @import("../../testing.zig");
test "WebApi: EditContext" {
    try testing.htmlRunner("edit_context.html", .{});
}
