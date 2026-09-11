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

// The event fired at an utterance as it is spoken (start / end / boundary /
// mark). Its constructor takes two required arguments in Chrome — the type and
// a dictionary carrying the utterance — so `length` is 2 (measured), and
// `utterance` is required rather than optional.

const lp = @import("lightpanda");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const SpeechSynthesisUtterance = @import("SpeechSynthesisUtterance.zig");

const String = lp.String;

const SpeechSynthesisEvent = @This();

pub const Proto = Event;

_type: Type,
_proto: *Event,
_utterance: *SpeechSynthesisUtterance,
_char_index: u32 = 0,
_char_length: u32 = 0,
_elapsed_time: f64 = 0,
_name: []const u8 = "",

pub const Type = union(enum) {
    generic,
    error_event: *@import("SpeechSynthesisErrorEvent.zig"),
};

pub const SpeechSynthesisEventOptions = struct {
    // Alphabetical: a dictionary's members are read in that order.
    charIndex: u32 = 0,
    charLength: u32 = 0,
    elapsedTime: f64 = 0,
    name: []const u8 = "",
    utterance: *SpeechSynthesisUtterance,
};

pub const Options = Event.inheritOptions(SpeechSynthesisEvent, SpeechSynthesisEventOptions);

pub fn init(typ: []const u8, opts: Options, page: *Page) !*SpeechSynthesisEvent {
    const arena = try page.getArena(.tiny, "SpeechSynthesisEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts, false, page);
}

pub fn initTrusted(typ: String, opts: Options, page: *Page) !*SpeechSynthesisEvent {
    const arena = try page.getArena(.tiny, "SpeechSynthesisEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts: Options, trusted: bool, page: *Page) !*SpeechSynthesisEvent {
    const event = try page.factory.event(
        arena,
        typ,
        SpeechSynthesisEvent{
            ._type = .generic,
            ._proto = undefined,
            ._utterance = opts.utterance,
            ._char_index = opts.charIndex,
            ._char_length = opts.charLength,
            ._elapsed_time = opts.elapsedTime,
            ._name = if (opts.name.len > 0) try arena.dupe(u8, opts.name) else "",
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *SpeechSynthesisEvent) *Event {
    return self._proto;
}

pub fn is(self: *SpeechSynthesisEvent, comptime T: type) ?*T {
    return switch (self._type) {
        .generic => null,
        .error_event => |e| if (T == @import("SpeechSynthesisErrorEvent.zig")) e else null,
    };
}

pub fn getUtterance(self: *const SpeechSynthesisEvent) *SpeechSynthesisUtterance {
    return self._utterance;
}

pub fn getCharIndex(self: *const SpeechSynthesisEvent) u32 {
    return self._char_index;
}

pub fn getCharLength(self: *const SpeechSynthesisEvent) u32 {
    return self._char_length;
}

pub fn getElapsedTime(self: *const SpeechSynthesisEvent) f64 {
    return self._elapsed_time;
}

pub fn getName(self: *const SpeechSynthesisEvent) []const u8 {
    return self._name;
}

pub const JsApi = struct {
    const js = @import("../../js/js.zig");
    pub const bridge = js.Bridge(SpeechSynthesisEvent);

    pub const Meta = struct {
        pub const name = "SpeechSynthesisEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(SpeechSynthesisEvent.init, .{});

    pub const utterance = bridge.accessor(SpeechSynthesisEvent.getUtterance, null, .{});
    pub const charIndex = bridge.accessor(SpeechSynthesisEvent.getCharIndex, null, .{});
    pub const charLength = bridge.accessor(SpeechSynthesisEvent.getCharLength, null, .{});
    pub const elapsedTime = bridge.accessor(SpeechSynthesisEvent.getElapsedTime, null, .{});
    pub const name = bridge.accessor(SpeechSynthesisEvent.getName, null, .{});
};
