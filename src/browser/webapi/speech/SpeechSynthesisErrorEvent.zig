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

// Fired at an utterance whose synthesis failed. It inherits from
// SpeechSynthesisEvent in Chrome (measured chain: SpeechSynthesisErrorEvent ->
// SpeechSynthesisEvent -> Event) and adds only `error`, so the type exists
// mostly to keep that chain and that one member visible to a script that walks
// the prototypes.

const lp = @import("lightpanda");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const SpeechSynthesisEvent = @import("SpeechSynthesisEvent.zig");

const String = lp.String;

const SpeechSynthesisErrorEvent = @This();

pub const Proto = SpeechSynthesisEvent;

_proto: *SpeechSynthesisEvent,
_error: []const u8 = "canceled",

pub const SpeechSynthesisErrorEventOptions = struct {
    @"error": []const u8 = "canceled",
};

const Options = Event.inheritOptions(SpeechSynthesisErrorEvent, SpeechSynthesisErrorEventOptions);

pub fn init(typ: []const u8, opts: Options, page: *Page) !*SpeechSynthesisErrorEvent {
    const arena = try page.getArena(.tiny, "SpeechSynthesisErrorEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts, false, page);
}

pub fn initTrusted(typ: String, opts: Options, page: *Page) !*SpeechSynthesisErrorEvent {
    const arena = try page.getArena(.tiny, "SpeechSynthesisErrorEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts: Options, trusted: bool, page: *Page) !*SpeechSynthesisErrorEvent {
    const event = try page.factory.speechSynthesisEvent(
        arena,
        typ,
        SpeechSynthesisEvent{
            ._type = undefined,
            ._proto = undefined,
            ._utterance = opts.utterance,
            ._char_index = opts.charIndex,
            ._char_length = opts.charLength,
            ._elapsed_time = opts.elapsedTime,
            ._name = if (opts.name.len > 0) try arena.dupe(u8, opts.name) else "",
        },
        SpeechSynthesisErrorEvent{
            ._proto = undefined,
            ._error = try arena.dupe(u8, opts.@"error"),
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asSpeechSynthesisEvent(self: *SpeechSynthesisErrorEvent) *SpeechSynthesisEvent {
    return self._proto;
}

pub fn getError(self: *const SpeechSynthesisErrorEvent) []const u8 {
    return self._error;
}

pub const JsApi = struct {
    const js = @import("../../js/js.zig");
    pub const bridge = js.Bridge(SpeechSynthesisErrorEvent);

    pub const Meta = struct {
        pub const name = "SpeechSynthesisErrorEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(SpeechSynthesisErrorEvent.init, .{});
    pub const @"error" = bridge.accessor(SpeechSynthesisErrorEvent.getError, null, .{});
};
