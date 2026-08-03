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

//! The two Web Audio events, both of which carry AudioBuffers.
//!
//! One of them is fired for real: `complete`, when an OfflineAudioContext
//! finishes rendering. The other, `audioprocess`, belongs to
//! ScriptProcessorNode's render callback, and nothing here renders on a script
//! thread — but it is constructible, so its refusals are what a script sees.
//!
//! Every member of both is required, which is unusual enough to be worth
//! naming: `new AudioProcessingEvent('audioprocess', {})` complains about
//! `playbackTime` and not about the two buffers, because Chrome reads the
//! dictionary in IDL order (measured, one omission at a time).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const Event = @import("../Event.zig");
const AudioBuffer = @import("AudioBuffer.zig");

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        OfflineAudioCompletionEvent,
        AudioProcessingEvent,
    };
}

// Both events take exactly two arguments, and neither treats a missing second
// one as an empty dictionary: every member is required, so there is nothing to
// default to.
fn twoArguments(
    comptime interface: []const u8,
    type_: ?js.Value,
    options: ?js.Value,
    exec: *const Execution,
) !struct { []const u8, js.Value } {
    if (type_ == null) return idl.typeError(
        "Failed to construct '" ++ interface ++ "': 2 arguments required, but only 0 present.",
        exec,
    );
    const dict = options orelse return idl.typeError(
        "Failed to construct '" ++ interface ++ "': 2 arguments required, but only 1 present.",
        exec,
    );
    return .{ try type_.?.toStringSlice(), dict };
}

// A required `AudioBuffer` dictionary member: absent and unconvertible read
// differently, and both name the property before the type.
fn requiredBuffer(
    comptime interface: []const u8,
    comptime dictionary: []const u8,
    comptime key: []const u8,
    dict: js.Value,
    exec: *const Execution,
) !*AudioBuffer {
    const member = if (dict.isObject()) try dict.toObject().get(key) else null;
    const value = member orelse return idl.typeError(
        "Failed to construct '" ++ interface ++ "': Failed to read the '" ++ key ++
            "' property from '" ++ dictionary ++ "': Required member is undefined.",
        exec,
    );
    if (value.isUndefined()) return idl.typeError(
        "Failed to construct '" ++ interface ++ "': Failed to read the '" ++ key ++
            "' property from '" ++ dictionary ++ "': Required member is undefined.",
        exec,
    );
    return value.toZig(*AudioBuffer) catch idl.typeError(
        "Failed to construct '" ++ interface ++ "': Failed to read the '" ++ key ++
            "' property from '" ++ dictionary ++ "': Failed to convert value to 'AudioBuffer'.",
        exec,
    );
}

// ---------------------------------------------------------------------------
// OfflineAudioCompletionEvent
// ---------------------------------------------------------------------------

/// `complete`, the one event an OfflineAudioContext fires. Constructed by a page
/// it is untrusted and does not bubble; the one the context fires does both
/// (measured: bubbles true, isTrusted true).
pub const OfflineAudioCompletionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _rendered_buffer: *AudioBuffer,

    pub fn constructor(type_: ?js.Value, options: ?js.Value, exec: *const Execution) !*OfflineAudioCompletionEvent {
        const typ, const dict = try twoArguments("OfflineAudioCompletionEvent", type_, options, exec);
        const buffer = try requiredBuffer(
            "OfflineAudioCompletionEvent",
            "OfflineAudioCompletionEventInit",
            "renderedBuffer",
            dict,
            exec,
        );
        return build(typ, buffer, try Event.optionsFromJs(dict), false, exec);
    }

    /// What an OfflineAudioContext dispatches when it finishes: trusted, and it
    /// bubbles, which the constructible form does not.
    pub fn initTrusted(buffer: *AudioBuffer, exec: *const Execution) !*OfflineAudioCompletionEvent {
        return build("complete", buffer, .{ .bubbles = true }, true, exec);
    }

    fn build(
        typ: []const u8,
        buffer: *AudioBuffer,
        options: Event.Options,
        trusted: bool,
        exec: *const Execution,
    ) !*OfflineAudioCompletionEvent {
        const arena = try exec.getArena(.tiny, "OfflineAudioCompletionEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            OfflineAudioCompletionEvent{ ._proto = undefined, ._rendered_buffer = buffer },
        );
        Event.populatePrototypes(event, options, trusted);
        return event;
    }

    pub fn asEvent(self: *OfflineAudioCompletionEvent) *Event {
        return self._proto;
    }

    pub fn getRenderedBuffer(self: *const OfflineAudioCompletionEvent) *AudioBuffer {
        return self._rendered_buffer;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OfflineAudioCompletionEvent);

        pub const Meta = struct {
            pub const name = "OfflineAudioCompletionEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(OfflineAudioCompletionEvent.constructor, .{ .arity = 2 });
        pub const renderedBuffer = bridge.accessor(OfflineAudioCompletionEvent.getRenderedBuffer, null, .{});
    };
};

// ---------------------------------------------------------------------------
// AudioProcessingEvent
// ---------------------------------------------------------------------------

/// `audioprocess`, ScriptProcessorNode's render callback. Nothing here ever
/// fires one -- there is no render thread to call back from -- but Chrome lets a
/// page construct one, and all three of its members are required.
pub const AudioProcessingEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _playback_time: f64,
    _input_buffer: *AudioBuffer,
    _output_buffer: *AudioBuffer,

    pub fn constructor(type_: ?js.Value, options: ?js.Value, exec: *const Execution) !*AudioProcessingEvent {
        const typ, const dict = try twoArguments("AudioProcessingEvent", type_, options, exec);

        // IDL order: a dictionary missing all three is blamed on playbackTime.
        const time = try idl.requiredMember(
            "AudioProcessingEvent",
            "AudioProcessingEventInit",
            "playbackTime",
            if (dict.isObject()) dict.toObject() else null,
            exec,
        );
        const input = try requiredBuffer(
            "AudioProcessingEvent",
            "AudioProcessingEventInit",
            "inputBuffer",
            dict,
            exec,
        );
        const output = try requiredBuffer(
            "AudioProcessingEvent",
            "AudioProcessingEventInit",
            "outputBuffer",
            dict,
            exec,
        );

        const arena = try exec.getArena(.tiny, "AudioProcessingEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            AudioProcessingEvent{
                ._proto = undefined,
                ._playback_time = try time.toF64(),
                ._input_buffer = input,
                ._output_buffer = output,
            },
        );
        Event.populatePrototypes(event, try Event.optionsFromJs(dict), false);
        return event;
    }

    pub fn asEvent(self: *AudioProcessingEvent) *Event {
        return self._proto;
    }

    pub fn getPlaybackTime(self: *const AudioProcessingEvent) f64 {
        return self._playback_time;
    }

    pub fn getInputBuffer(self: *const AudioProcessingEvent) *AudioBuffer {
        return self._input_buffer;
    }

    pub fn getOutputBuffer(self: *const AudioProcessingEvent) *AudioBuffer {
        return self._output_buffer;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioProcessingEvent);

        pub const Meta = struct {
            pub const name = "AudioProcessingEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(AudioProcessingEvent.constructor, .{ .arity = 2 });
        pub const playbackTime = bridge.accessor(AudioProcessingEvent.getPlaybackTime, null, .{});
        pub const inputBuffer = bridge.accessor(AudioProcessingEvent.getInputBuffer, null, .{});
        pub const outputBuffer = bridge.accessor(AudioProcessingEvent.getOutputBuffer, null, .{});
    };
};
