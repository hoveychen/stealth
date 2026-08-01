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

// The prototype AudioContext inherits from — never instantiated on its own
// (Chrome: illegal constructor). It carries everything that is common to a
// real-time and an offline context: the sample rate, the graph clock, the
// destination node and the listener.
//
// Only `createAnalyser` of Chrome's twenty `create*` factories is here. The
// engine does no DSP by design, so a node that cannot process anything would
// be a lie in a way a *missing* node is not; the analyser is the exception
// because detectors read its (silent) values rather than its output. See the
// AnalyserNode header.

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const AudioNode = @import("AudioNode.zig");
const AnalyserNode = @import("AnalyserNode.zig");
const AudioListener = @import("AudioListener.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");

const Execution = js.Execution;

const BaseAudioContext = @This();

pub const Proto = EventTarget;

_type: Type,
_proto: *EventTarget,

// Everything below is filled in by AudioContext.init right after the prototype
// chain is allocated — the chain allocator can only set `_type` and `_proto`.
_sample_rate: f64 = 48000,
_state: State = .suspended,
_destination: ?*AudioDestinationNode = null,
_listener: ?*AudioListener = null,
_on_state_change: ?js.Function.Global = null,

pub const Type = union(enum) {
    audio_context: *@import("AudioContext.zig"),
};

pub const State = enum {
    suspended,
    running,
    closed,
};

pub fn asEventTarget(self: *BaseAudioContext) *EventTarget {
    return self._proto;
}

pub fn getSampleRate(self: *const BaseAudioContext) f64 {
    return self._sample_rate;
}

pub fn getState(self: *const BaseAudioContext) []const u8 {
    return @tagName(self._state);
}

// Always zero, which is what Chrome reports for a context that never started —
// measured on a headed window as well as a headless one, because the reason is
// the autoplay policy and not the absence of an audio device. The clock would
// advance in render-quantum steps once a context ran; nothing here can start one,
// so there is no clock to advance.
pub fn getCurrentTime(_: *const BaseAudioContext) f64 {
    return 0;
}

pub fn getDestination(self: *const BaseAudioContext) *AudioDestinationNode {
    return self._destination.?;
}

pub fn getListener(self: *const BaseAudioContext) *AudioListener {
    return self._listener.?;
}

pub fn getOnStateChange(self: *const BaseAudioContext) ?js.Function.Global {
    return self._on_state_change;
}

pub fn setOnStateChange(self: *BaseAudioContext, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_state_change = try listen.persistWithThis(self);
    } else {
        self._on_state_change = null;
    }
}

// Deliberately no closed-state check: Chrome still hands back a node after
// close() (measured — createAnalyser on a closed context returns normally).
pub fn createAnalyser(self: *BaseAudioContext, exec: *Execution) !*AnalyserNode {
    const analyser = try exec._factory.audioNode(AnalyserNode{ ._proto = undefined });
    analyser._proto._context = self._type.audio_context;
    return analyser;
}

// Moves the state and fires statechange. Called by AudioContext's
// suspend/close; `running` is unreachable — see resume() there.
pub fn transition(self: *BaseAudioContext, to: State, exec: *const Execution) !void {
    if (self._state == to) {
        return;
    }
    self._state = to;

    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "statechange", self._on_state_change)) {
        return;
    }
    const event = try Event.initTrusted(comptime .wrap("statechange"), .{}, exec.page);
    return exec.dispatch(target, event, self._on_state_change, .{ .context = "audio statechange" });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BaseAudioContext);

    pub const Meta = struct {
        pub const name = "BaseAudioContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const destination = bridge.accessor(BaseAudioContext.getDestination, null, .{});
    pub const sampleRate = bridge.accessor(BaseAudioContext.getSampleRate, null, .{});
    pub const currentTime = bridge.accessor(BaseAudioContext.getCurrentTime, null, .{});
    pub const listener = bridge.accessor(BaseAudioContext.getListener, null, .{});
    pub const state = bridge.accessor(BaseAudioContext.getState, null, .{});
    pub const onstatechange = bridge.accessor(BaseAudioContext.getOnStateChange, BaseAudioContext.setOnStateChange, .{});

    pub const createAnalyser = bridge.function(BaseAudioContext.createAnalyser, .{});
};
