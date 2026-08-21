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

// The nine Event subclasses a Chrome window carries that this engine did not.
// Nothing here ever fires one -- there is no invoker command, no interest
// target, no cross-document view transition, no IME composition and no scroll
// snap -- but eight of the nine are constructible from script, so their
// dictionaries, the refusals those produce and the defaults every getter answers
// are all surface a detector can read. Only SnapEvent is unreachable: it has no
// constructor decl, which is what produces Chrome's "Illegal constructor".
//
// Two of the nine are unlike anything else in this engine:
//
//   * ClipboardChangeEvent takes no type argument at all. Its arity is 0 and
//     its first argument is the *dictionary*, so `new ClipboardChangeEvent('x')`
//     complains the value is not a ClipboardChangeEventInit, and the type is
//     always 'clipboardchange'.
//   * its `changeId` is a WebIDL `bigint`, the only one in the engine -- so it
//     reads back as a BigInt rather than a Number, and a Number handed *in* is
//     refused (see dictionary.bigintMember).
//
// Every member list, default, coercion and refusal below is Chrome's own,
// measured on a headed Chrome 151 on http://localhost:8777 with
// tools/fingerprint/probes/probe-shapes.js and probe-s2-events.js; the readings
// are in results/probes/probe-shapes.chrome.json and
// probe-s2-events.chrome.json. All nine are window-only: a Chrome
// DedicatedWorkerGlobalScope has none of them (measured, probe-shapes-worker).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Event = @import("../Event.zig");
const Element = @import("../Element.zig");
const dictionary = @import("../dictionary.zig");
const TextFormat = @import("../TextFormat.zig");
const NavigationActivation = @import("../navigation/NavigationActivation.zig");

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        CharacterBoundsUpdateEvent,
        ClipboardChangeEvent,
        CommandEvent,
        InterestEvent,
        PageRevealEvent,
        PageSwapEvent,
        SnapEvent,
        TextFormatUpdateEvent,
        TextUpdateEvent,
    };
}

const Init = dictionary.Init;

/// Reads the type argument the same way misc_events does: the bridge has
/// already refused a call with too few arguments by the time this runs, so this
/// is the conversion, not the check (measured: a numeric type reads back "7",
/// an explicit undefined "undefined").
fn eventType(value_: ?js.Value, allocator: std.mem.Allocator) !String {
    const value = value_ orelse return String.init(allocator, "undefined", .{});
    const slice = try value.toStringSlice();
    return String.init(allocator, slice, .{});
}

/// A member typed as an interface this engine does not have. Null and absent are
/// the only values that get through; anything else is the conversion failure
/// naming the interface, which is all a page can observe of it.
fn nullOnlyMember(
    reader: anytype,
    comptime name: []const u8,
    comptime idl: []const u8,
    exec: *const Execution,
) !void {
    const member = (try reader.present(name)) orelse return;
    if (member.isNull()) {
        return;
    }
    return @TypeOf(reader).convertFailed(name, idl, exec);
}

// ---------------------------------------------------------------------------
// CommandEvent

/// `button.commandForElement`'s payload: which element carried the `command`
/// attribute and what it said. `source` is a nullable Element and keeps the very
/// object it was handed; a Window or a Text node is a conversion failure, same
/// as a number.
pub const CommandEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _source: ?*Element = null,
    _command: []const u8 = "",

    const Reader = Init("CommandEvent", "CommandEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*CommandEvent {
        const init = try Reader.read(options_, exec);
        const source = try init.nullableInterface("source", Element, "Element", exec);

        const arena = try exec.getArena(.tiny, "CommandEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, allocator),
            CommandEvent{
                ._proto = undefined,
                ._source = source,
                ._command = try init.string("command", "", allocator),
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *CommandEvent) *Event {
        return self._proto;
    }

    pub fn getSource(self: *const CommandEvent) ?*Element {
        return self._source;
    }

    pub fn getCommand(self: *const CommandEvent) []const u8 {
        return self._command;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CommandEvent);

        pub const Meta = struct {
            pub const name = "CommandEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CommandEvent.constructor, .{ .arity = 1 });
        pub const source = bridge.accessor(CommandEvent.getSource, null, .{});
        pub const command = bridge.accessor(CommandEvent.getCommand, null, .{});
    };
};

// ---------------------------------------------------------------------------
// InterestEvent

/// `interesttarget`'s payload. CommandEvent without the command: one nullable
/// Element.
pub const InterestEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _source: ?*Element = null,

    const Reader = Init("InterestEvent", "InterestEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*InterestEvent {
        const init = try Reader.read(options_, exec);
        const source = try init.nullableInterface("source", Element, "Element", exec);

        const arena = try exec.getArena(.tiny, "InterestEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            InterestEvent{ ._proto = undefined, ._source = source },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *InterestEvent) *Event {
        return self._proto;
    }

    pub fn getSource(self: *const InterestEvent) ?*Element {
        return self._source;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(InterestEvent);

        pub const Meta = struct {
            pub const name = "InterestEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(InterestEvent.constructor, .{ .arity = 1 });
        pub const source = bridge.accessor(InterestEvent.getSource, null, .{});
    };
};

// ---------------------------------------------------------------------------
// PageRevealEvent

/// The `pagereveal` a cross-document view transition fires. `viewTransition` is
/// a ViewTransition, an interface neither this engine nor the page can hold one
/// of, so the getter can only ever answer null -- and the dictionary member's
/// conversion failure is the only other half a page sees.
pub const PageRevealEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    const Reader = Init("PageRevealEvent", "PageRevealEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*PageRevealEvent {
        const init = try Reader.read(options_, exec);
        try nullOnlyMember(init, "viewTransition", "ViewTransition", exec);

        const arena = try exec.getArena(.tiny, "PageRevealEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            PageRevealEvent{ ._proto = undefined },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *PageRevealEvent) *Event {
        return self._proto;
    }

    pub fn getViewTransition(_: *const PageRevealEvent) ?js.Value {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PageRevealEvent);

        pub const Meta = struct {
            pub const name = "PageRevealEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(PageRevealEvent.constructor, .{ .arity = 1 });
        pub const viewTransition = bridge.accessor(PageRevealEvent.getViewTransition, null, .{});
    };
};

// ---------------------------------------------------------------------------
// PageSwapEvent

/// The `pageswap` fired at the outgoing document. Like PageRevealEvent plus an
/// `activation`, which *is* an interface this engine has -- so that member is
/// read for real, and an event built with one keeps it.
pub const PageSwapEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _activation: ?*NavigationActivation = null,

    const Reader = Init("PageSwapEvent", "PageSwapEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*PageSwapEvent {
        const init = try Reader.read(options_, exec);
        try nullOnlyMember(init, "viewTransition", "ViewTransition", exec);
        const activation = try init.nullableInterface(
            "activation",
            NavigationActivation,
            "NavigationActivation",
            exec,
        );

        const arena = try exec.getArena(.tiny, "PageSwapEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            PageSwapEvent{ ._proto = undefined, ._activation = activation },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *PageSwapEvent) *Event {
        return self._proto;
    }

    pub fn getViewTransition(_: *const PageSwapEvent) ?js.Value {
        return null;
    }

    pub fn getActivation(self: *const PageSwapEvent) ?*NavigationActivation {
        return self._activation;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PageSwapEvent);

        pub const Meta = struct {
            pub const name = "PageSwapEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(PageSwapEvent.constructor, .{ .arity = 1 });
        pub const viewTransition = bridge.accessor(PageSwapEvent.getViewTransition, null, .{});
        pub const activation = bridge.accessor(PageSwapEvent.getActivation, null, .{});
    };
};

// ---------------------------------------------------------------------------
// TextUpdateEvent

/// EditContext's `textupdate`: what the IME replaced and where the selection
/// landed. All four offsets are `unsigned long` with neither [EnforceRange] nor
/// [Clamp], so -1 wraps rather than throwing.
pub const TextUpdateEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _update_range_start: u32 = 0,
    _update_range_end: u32 = 0,
    _text: []const u8 = "",
    _selection_start: u32 = 0,
    _selection_end: u32 = 0,

    const Reader = Init("TextUpdateEvent", "TextUpdateEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*TextUpdateEvent {
        const init = try Reader.read(options_, exec);
        const update_range_start = try init.unsignedLong("updateRangeStart", 0);
        const update_range_end = try init.unsignedLong("updateRangeEnd", 0);
        const selection_start = try init.unsignedLong("selectionStart", 0);
        const selection_end = try init.unsignedLong("selectionEnd", 0);

        const arena = try exec.getArena(.tiny, "TextUpdateEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, allocator),
            TextUpdateEvent{
                ._proto = undefined,
                ._update_range_start = update_range_start,
                ._update_range_end = update_range_end,
                ._text = try init.string("text", "", allocator),
                ._selection_start = selection_start,
                ._selection_end = selection_end,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *TextUpdateEvent) *Event {
        return self._proto;
    }

    pub fn getUpdateRangeStart(self: *const TextUpdateEvent) u32 {
        return self._update_range_start;
    }

    pub fn getUpdateRangeEnd(self: *const TextUpdateEvent) u32 {
        return self._update_range_end;
    }

    pub fn getText(self: *const TextUpdateEvent) []const u8 {
        return self._text;
    }

    pub fn getSelectionStart(self: *const TextUpdateEvent) u32 {
        return self._selection_start;
    }

    pub fn getSelectionEnd(self: *const TextUpdateEvent) u32 {
        return self._selection_end;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TextUpdateEvent);

        pub const Meta = struct {
            pub const name = "TextUpdateEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const E = TextUpdateEvent;

        pub const constructor = bridge.constructor(E.constructor, .{ .arity = 1 });
        pub const updateRangeStart = bridge.accessor(E.getUpdateRangeStart, null, .{});
        pub const updateRangeEnd = bridge.accessor(E.getUpdateRangeEnd, null, .{});
        pub const text = bridge.accessor(E.getText, null, .{});
        pub const selectionStart = bridge.accessor(E.getSelectionStart, null, .{});
        pub const selectionEnd = bridge.accessor(E.getSelectionEnd, null, .{});
    };
};

// ---------------------------------------------------------------------------
// TextFormatUpdateEvent

/// EditContext's `textformatupdate`: the underlines and highlights the IME wants
/// drawn. The formats are a `sequence<TextFormat>`, so the sequence check is
/// observable (a non-array is refused as one) and every item has to convert --
/// which it now can, since TextFormat.zig landed. The event keeps the very
/// objects it was handed.
pub const TextFormatUpdateEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _formats: []const *TextFormat = &.{},

    const Reader = Init("TextFormatUpdateEvent", "TextFormatUpdateEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*TextFormatUpdateEvent {
        const init = try Reader.read(options_, exec);

        const arena = try exec.getArena(.tiny, "TextFormatUpdateEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        var formats: []const *TextFormat = &.{};
        if (try init.present("textFormats")) |member| {
            if (member.isArray() == false) {
                return Reader.notASequence("textFormats", exec);
            }
            const array = member.toArray();
            const items = try allocator.alloc(*TextFormat, @intCast(array.len()));
            for (items, 0..) |*item, i| {
                const entry = try array.get(@intCast(i));
                item.* = entry.toZig(*TextFormat) catch
                    return Reader.convertFailed("textFormats", "TextFormat", exec);
            }
            formats = items;
        }

        const event = try exec._factory.event(
            arena,
            try eventType(type_, allocator),
            TextFormatUpdateEvent{ ._proto = undefined, ._formats = formats },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *TextFormatUpdateEvent) *Event {
        return self._proto;
    }

    /// A fresh array every call, like Chrome's (measured: two reads are not the
    /// same object).
    pub fn getTextFormats(self: *TextFormatUpdateEvent) []const *TextFormat {
        return self._formats;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TextFormatUpdateEvent);

        pub const Meta = struct {
            pub const name = "TextFormatUpdateEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(TextFormatUpdateEvent.constructor, .{ .arity = 1 });
        pub const getTextFormats = bridge.function(TextFormatUpdateEvent.getTextFormats, .{});
    };
};

// ---------------------------------------------------------------------------
// CharacterBoundsUpdateEvent

/// EditContext's `characterboundsupdate`: the range whose glyph boxes the IME is
/// asking for. Two `unsigned long`s, same ToUint32 as TextUpdateEvent's.
pub const CharacterBoundsUpdateEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _range_start: u32 = 0,
    _range_end: u32 = 0,

    const Reader = Init("CharacterBoundsUpdateEvent", "CharacterBoundsUpdateEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*CharacterBoundsUpdateEvent {
        const init = try Reader.read(options_, exec);
        const range_start = try init.unsignedLong("rangeStart", 0);
        const range_end = try init.unsignedLong("rangeEnd", 0);

        const arena = try exec.getArena(.tiny, "CharacterBoundsUpdateEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            CharacterBoundsUpdateEvent{
                ._proto = undefined,
                ._range_start = range_start,
                ._range_end = range_end,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *CharacterBoundsUpdateEvent) *Event {
        return self._proto;
    }

    pub fn getRangeStart(self: *const CharacterBoundsUpdateEvent) u32 {
        return self._range_start;
    }

    pub fn getRangeEnd(self: *const CharacterBoundsUpdateEvent) u32 {
        return self._range_end;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CharacterBoundsUpdateEvent);

        pub const Meta = struct {
            pub const name = "CharacterBoundsUpdateEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const E = CharacterBoundsUpdateEvent;

        pub const constructor = bridge.constructor(E.constructor, .{ .arity = 1 });
        pub const rangeStart = bridge.accessor(E.getRangeStart, null, .{});
        pub const rangeEnd = bridge.accessor(E.getRangeEnd, null, .{});
    };
};

// ---------------------------------------------------------------------------
// ClipboardChangeEvent

/// `navigator.clipboard.onclipboardchange`. The one Event subclass with no type
/// argument: its arity is 0 and the first argument is the dictionary, so the
/// type is always 'clipboardchange' and a string there is refused as an init
/// (measured). `types` is a FrozenArray of MIME strings -- fresh on every read,
/// though not actually frozen here, which is the engine-wide FrozenArray gap --
/// and `changeId` is the engine's only WebIDL `bigint`.
pub const ClipboardChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _types: []const []const u8 = &.{},
    _change_id: i64 = 0,

    const Reader = Init("ClipboardChangeEvent", "ClipboardChangeEventInit");

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*ClipboardChangeEvent {
        const init = try Reader.read(options_, exec);
        const change_id = try init.bigintMember("changeId", 0, exec);

        const arena = try exec.getArena(.tiny, "ClipboardChangeEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        const event = try exec._factory.event(
            arena,
            try String.init(allocator, "clipboardchange", .{}),
            ClipboardChangeEvent{
                ._proto = undefined,
                ._types = try init.stringSequence("types", allocator, exec),
                ._change_id = change_id,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *ClipboardChangeEvent) *Event {
        return self._proto;
    }

    pub fn getTypes(self: *const ClipboardChangeEvent) []const []const u8 {
        return self._types;
    }

    /// A BigInt, not a Number: `typeof e.changeId` is 'bigint' in Chrome.
    pub fn getChangeId(self: *const ClipboardChangeEvent, exec: *const Execution) js.BigInt {
        return exec.js.isolate.initBigInt(self._change_id);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ClipboardChangeEvent);

        pub const Meta = struct {
            pub const name = "ClipboardChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(ClipboardChangeEvent.constructor, .{ .arity = 0 });
        pub const types = bridge.accessor(ClipboardChangeEvent.getTypes, null, .{});
        pub const changeId = bridge.accessor(ClipboardChangeEvent.getChangeId, null, .{});
    };
};

// ---------------------------------------------------------------------------
// SnapEvent

/// `snapchanged` / `snapchanging` on a scroll container with scroll snapping.
/// Not constructible: only the browser's own scroll pass produces one, and with
/// no layout here nothing ever does. Omitting `constructor` is what gives
/// Chrome's "Failed to construct 'SnapEvent': Illegal constructor", so the
/// prototype and its two getters are all a page can reach -- which is why they
/// are never instantiated and answer nothing.
pub const SnapEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    pub fn getSnapTarget(_: *const SnapEvent) ?*Element {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SnapEvent);

        pub const Meta = struct {
            pub const name = "SnapEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const snapTargetBlock = bridge.accessor(SnapEvent.getSnapTarget, null, .{});
        pub const snapTargetInline = bridge.accessor(SnapEvent.getSnapTarget, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: SurfaceEvents" {
    try testing.htmlRunner("event/surface_events.html", .{});
}
