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

// window.AudioContext. Its absence was the single most expensive gap in the
// fingerprint surface: deviceandbrowserinfo bails out of its whole collector
// with `if (typeof AudioContext != "function") return` and therefore never
// renders a verdict, and every other script that reads an audio fingerprint
// reads it from here.
//
// Deliberately *not* implemented: OfflineAudioContext. Rendering it would mean
// either real DSP (which this engine has no audio thread for) or a fabricated
// constant buffer — and a constant audio fingerprint is a stronger bot signal
// than a missing OfflineAudioContext, since every real Chrome on the same build
// and the same hardware family shares a handful of known-good hashes and a
// made-up one matches none of them.
//
// The values are Chrome 150's, measured (see tools/fingerprint/README.md):
// sampleRate 48000, baseLatency 256/48000, outputLatency 0, sinkId "", initial
// state "suspended".
//
// resume() returns a promise that never settles and leaves the state
// "suspended". That is not a stub: it is what Chrome does, measured on *both*
// a headless and a headed window (still pending after 2s, state "suspended",
// currentTime 0). The cause is the autoplay policy rather than a missing audio
// device — a context created by script with no user gesture behind it never
// starts — and a script running under a fingerprint collector is always in
// exactly that position. suspend() and close() do resolve, also measured.
//
// An earlier revision had resume() resolve and start a clock, on the theory that
// the never-settling promise was a headless artefact. Measuring a real headed
// window disproved that, so the invented behaviour is gone: a script that times
// out resume() would otherwise have seen something no Chrome produces.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioListener = @import("AudioListener.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");

const Execution = js.Execution;

const AudioContext = @This();

pub const Proto = BaseAudioContext;

// Chrome's output buffer is 256 frames on macOS, so baseLatency is 256 over the
// sample rate: 0.005333333333333333 at 48kHz, which is what it reports.
const OUTPUT_BUFFER_FRAMES: f64 = 256;

_proto: *BaseAudioContext,
_sink_id: lp.String = .empty,
_on_error: ?js.Function.Global = null,
_on_sink_change: ?js.Function.Global = null,

pub fn init(options: ?Options, exec: *Execution) !*AudioContext {
    const self = try exec._factory.audioContext(AudioContext{ ._proto = undefined });
    const base = self._proto;

    if (options) |opts| {
        if (opts.sampleRate) |sample_rate| {
            // Chrome's accepted range; outside it the constructor throws.
            if (sample_rate < 3000 or sample_rate > 768000) {
                return error.NotSupported;
            }
            base._sample_rate = sample_rate;
        }
    }

    // A stereo output: numberOfOutputs 0 and channelCountMode "explicit" are
    // what set the destination apart from every other node (measured).
    const destination = try exec._factory.audioNode(AudioDestinationNode{ ._proto = undefined });
    destination._proto._context = self;
    destination._proto._number_of_outputs = 0;
    destination._proto._channel_count_mode = .explicit;
    base._destination = destination;
    base._listener = try AudioListener.init(exec);

    return self;
}

pub const Options = struct {
    latencyHint: ?js.Value = null,
    sampleRate: ?f64 = null,
    sinkId: ?lp.String = null,
};

pub fn asBaseAudioContext(self: *AudioContext) *BaseAudioContext {
    return self._proto;
}

pub fn getBaseLatency(self: *const AudioContext) f64 {
    return OUTPUT_BUFFER_FRAMES / self._proto._sample_rate;
}

// Zero until the output actually starts, which is what Chrome reports for a
// context that has never rendered.
pub fn getOutputLatency(_: *const AudioContext) f64 {
    return 0;
}

pub fn getSinkId(self: *const AudioContext) lp.String {
    return self._sink_id;
}

pub fn setSinkId(self: *AudioContext, sink_id: lp.String.Global, exec: *const Execution) !js.Promise {
    self._sink_id = sink_id.str;
    return exec.js.local.?.resolvePromise({});
}

pub fn getOutputTimestamp(self: *const AudioContext, exec: *const Execution) OutputTimestamp {
    return .{
        .contextTime = self._proto.getCurrentTime(),
        .performanceTime = exec.performance().now(),
    };
}

pub const OutputTimestamp = struct {
    contextTime: f64,
    performanceTime: f64,
};

// Never settles, per the measurement in the header. The state does not move
// either, so there is nothing to transition.
pub fn @"resume"(self: *AudioContext, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self._proto._state == .closed) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }
    return local.createPromiseResolver().promise();
}

pub fn @"suspend"(self: *AudioContext, exec: *const Execution) !js.Promise {
    return self.settle(.suspended, exec);
}

pub fn close(self: *AudioContext, exec: *const Execution) !js.Promise {
    return self.settle(.closed, exec);
}

// Chrome rejects on an already-closed context, and resolves with undefined
// otherwise.
fn settle(self: *AudioContext, to: BaseAudioContext.State, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self._proto._state == .closed) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }
    try self._proto.transition(to, exec);
    return local.resolvePromise({});
}

pub fn getOnError(self: *const AudioContext) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *AudioContext, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_error = try listen.persistWithThis(self);
    } else {
        self._on_error = null;
    }
}

pub fn getOnSinkChange(self: *const AudioContext) ?js.Function.Global {
    return self._on_sink_change;
}

pub fn setOnSinkChange(self: *AudioContext, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_sink_change = try listen.persistWithThis(self);
    } else {
        self._on_sink_change = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioContext);

    pub const Meta = struct {
        pub const name = "AudioContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioContext.init, .{});

    pub const baseLatency = bridge.accessor(AudioContext.getBaseLatency, null, .{});
    pub const outputLatency = bridge.accessor(AudioContext.getOutputLatency, null, .{});
    pub const sinkId = bridge.accessor(AudioContext.getSinkId, null, .{});
    pub const onerror = bridge.accessor(AudioContext.getOnError, AudioContext.setOnError, .{});
    pub const onsinkchange = bridge.accessor(AudioContext.getOnSinkChange, AudioContext.setOnSinkChange, .{});

    pub const setSinkId = bridge.function(AudioContext.setSinkId, .{});
    pub const getOutputTimestamp = bridge.function(AudioContext.getOutputTimestamp, .{});
    pub const @"resume" = bridge.function(AudioContext.@"resume", .{});
    pub const @"suspend" = bridge.function(AudioContext.@"suspend", .{});
    pub const close = bridge.function(AudioContext.close, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: AudioContext" {
    try testing.htmlRunner("audio.html", .{});
}
