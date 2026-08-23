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

//! The fifteen audio nodes a BaseAudioContext hands out.
//!
//! None of them process a sample: this engine has no audio thread. What they
//! do carry is everything a script can read without one — the AudioParam
//! defaults and their (per-parameter, often narrow) bounds, the channel
//! counts, the enum attributes, and each constructor's refusals. Every number
//! and every message in this file came off a headed Chrome 150 over
//! http://localhost (win15-chrome.json for the defaults, win16-chrome.json for
//! the edge cases); none of it was read out of the spec.
//!
//! The one real computation here is getFrequencyResponse, which is pure
//! arithmetic over the filter coefficients and needs no audio device. Blink's
//! biquad coefficients are the RBJ cookbook's with one twist that matters: for
//! lowpass and highpass the `Q` parameter is in *decibels*, so the magnitude at
//! the cutoff is 10^(Q/20). Both were checked against Chrome's own output
//! before this shipped (see the module test).

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const PeriodicWave = @import("PeriodicWave.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");
const handler_property = @import("../handler_property.zig");
const EventTarget = @import("../EventTarget.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const Execution = js.Execution;
const Float32Array = js.ArrayBufferRef(.float32);

const FLT_MAX = AudioParam.MAX_VALUE;
const FLT_MIN = AudioParam.MIN_VALUE;

pub fn registerTypes() []const type {
    return &.{
        GainNode,
        DelayNode,
        BiquadFilterNode,
        StereoPannerNode,
        ConstantSourceNode,
        OscillatorNode,
        AudioBufferSourceNode,
        ChannelMergerNode,
        ChannelSplitterNode,
        ConvolverNode,
        DynamicsCompressorNode,
        IIRFilterNode,
        PannerNode,
        WaveShaperNode,
        ScriptProcessorNode,
    };
}

// ---------------------------------------------------------------------------
// Shared construction
// ---------------------------------------------------------------------------

fn param(default_value: f64, min: f64, max: f64, rate: AudioParam.AutomationRate, exec: *Execution) !*AudioParam {
    return exec._factory.create(AudioParam.bounded(default_value, min, max, rate));
}

// The three AudioNodeOptions members every node dictionary inherits. Applied
// straight to the fields rather than through the setters: the setters exist to
// police a *later* assignment, and a merger built with an explicit
// channelCount would otherwise trip its own pin.
fn applyNodeOptions(base: *AudioNode, dict: ?js.Object) !void {
    if (try idl.optionalU32(dict, "channelCount")) |count| {
        base._channel_count = count;
    }
    if (dict) |obj| {
        const mode = try obj.get("channelCountMode");
        if (!mode.isUndefined()) {
            idl.assignEnum(AudioNode.ChannelCountMode, &base._channel_count_mode, try mode.toStringSlice());
        }
        const interpretation = try obj.get("channelInterpretation");
        if (!interpretation.isUndefined()) {
            idl.assignEnum(AudioNode.ChannelInterpretation, &base._channel_interpretation, try interpretation.toStringSlice());
        }
    }
}

// {EventTarget, AudioNode, Leaf}
fn plain(comptime T: type, leaf: T, context: *BaseAudioContext, dict: ?js.Object, exec: *Execution) !*T {
    const node = try exec._factory.audioNode(leaf);
    const base = node._proto;
    try context.register(base, exec);
    try applyNodeOptions(base, dict);
    return node;
}

// {EventTarget, AudioNode, AudioScheduledSourceNode, Leaf}: a source has no
// input, which is the only thing that separates it from `plain` here.
fn source(comptime T: type, leaf: T, context: *BaseAudioContext, dict: ?js.Object, exec: *Execution) !*T {
    const node = try exec._factory.audioNode(leaf);
    const base = node._proto._proto;
    try context.register(base, exec);
    base._number_of_inputs = 0;
    try applyNodeOptions(base, dict);
    return node;
}

// ---------------------------------------------------------------------------
// GainNode
// ---------------------------------------------------------------------------

pub const GainNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _gain: *AudioParam,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*GainNode {
        const ctx = try idl.context("GainNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("GainNode", "GainOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);
        if (try idl.optionalF64(dict, "gain")) |value| {
            node._gain._value = value;
        }
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*GainNode {
        return plain(GainNode, .{
            ._proto = undefined,
            ._gain = try param(1, FLT_MIN, FLT_MAX, .@"a-rate", exec),
        }, ctx, null, exec);
    }

    pub fn asAudioNode(self: *GainNode) *AudioNode {
        return self._proto;
    }

    pub fn getGain(self: *GainNode) *AudioParam {
        return self._gain;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GainNode);
        pub const Meta = struct {
            pub const name = "GainNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(GainNode.constructor, .{ .arity = 1 });
        pub const gain = bridge.accessor(GainNode.getGain, null, .{});
    };
};

// ---------------------------------------------------------------------------
// DelayNode
// ---------------------------------------------------------------------------

pub const DelayNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _delay_time: *AudioParam,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*DelayNode {
        const ctx = try idl.context("DelayNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("DelayNode", "DelayOptions", options, exec);
        const max_delay = try idl.optionalF64(dict, "maxDelayTime") orelse 1;
        try checkMaxDelay("Failed to construct 'DelayNode'", max_delay, exec);

        const node = try create(ctx, max_delay, exec);
        try applyNodeOptions(node._proto, dict);
        if (try idl.optionalF64(dict, "delayTime")) |value| {
            node._delay_time._value = std.math.clamp(value, 0, max_delay);
        }
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, max_delay: f64, exec: *Execution) !*DelayNode {
        return plain(DelayNode, .{
            ._proto = undefined,
            ._delay_time = try param(0, 0, max_delay, .@"a-rate", exec),
        }, ctx, null, exec);
    }

    // Shared with BaseAudioContext.createDelay, which blames itself.
    pub fn checkMaxDelay(comptime where: []const u8, max_delay: f64, exec: *const Execution) !void {
        if (max_delay > 0 and max_delay < 180) return;
        return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            where ++ ": The max delay time provided ({d}) is outside the range (0, 180).",
            .{max_delay},
        ), exec);
    }

    pub fn asAudioNode(self: *DelayNode) *AudioNode {
        return self._proto;
    }

    pub fn getDelayTime(self: *DelayNode) *AudioParam {
        return self._delay_time;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DelayNode);
        pub const Meta = struct {
            pub const name = "DelayNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(DelayNode.constructor, .{ .arity = 1 });
        pub const delayTime = bridge.accessor(DelayNode.getDelayTime, null, .{});
    };
};

// ---------------------------------------------------------------------------
// BiquadFilterNode
// ---------------------------------------------------------------------------

pub const BiquadFilterType = enum {
    lowpass,
    highpass,
    bandpass,
    lowshelf,
    highshelf,
    peaking,
    notch,
    allpass,
};

pub const BiquadFilterNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _type: BiquadFilterType = .lowpass,
    _frequency: *AudioParam,
    _detune: *AudioParam,
    _q: *AudioParam,
    _gain: *AudioParam,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*BiquadFilterNode {
        const ctx = try idl.context("BiquadFilterNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("BiquadFilterNode", "BiquadFilterOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);

        if (try idl.optionalEnum(
            BiquadFilterType,
            "BiquadFilterNode",
            "BiquadFilterOptions",
            "BiquadFilterType",
            dict,
            "type",
            exec,
        )) |kind| {
            node._type = kind;
        }
        if (try idl.optionalF64(dict, "Q")) |value| node._q._value = value;
        if (try idl.optionalF64(dict, "detune")) |value| node._detune._value = value;
        if (try idl.optionalF64(dict, "frequency")) |value| node._frequency._value = value;
        if (try idl.optionalF64(dict, "gain")) |value| node._gain._value = value;
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*BiquadFilterNode {
        const nyquist = ctx._sample_rate / 2;
        return plain(BiquadFilterNode, .{
            ._proto = undefined,
            // gain's ceiling is 40 * log10(FLT_MAX) in dB, which Chrome reports
            // as 1541.273681640625 (measured).
            ._gain = try param(0, FLT_MIN, 1541.273681640625, .@"a-rate", exec),
            ._frequency = try param(350, 0, nyquist, .@"a-rate", exec),
            ._detune = try param(0, -153600, 153600, .@"a-rate", exec),
            ._q = try param(1, FLT_MIN, FLT_MAX, .@"a-rate", exec),
        }, ctx, null, exec);
    }

    pub fn asAudioNode(self: *BiquadFilterNode) *AudioNode {
        return self._proto;
    }

    pub fn getType(self: *const BiquadFilterNode) []const u8 {
        return @tagName(self._type);
    }

    pub fn setType(self: *BiquadFilterNode, kind: []const u8) void {
        idl.assignEnum(BiquadFilterType, &self._type, kind);
    }

    pub fn getFrequency(self: *BiquadFilterNode) *AudioParam {
        return self._frequency;
    }

    pub fn getDetune(self: *BiquadFilterNode) *AudioParam {
        return self._detune;
    }

    pub fn getQ(self: *BiquadFilterNode) *AudioParam {
        return self._q;
    }

    pub fn getGain(self: *BiquadFilterNode) *AudioParam {
        return self._gain;
    }

    pub fn getFrequencyResponse(
        self: *BiquadFilterNode,
        frequencies: ?js.Value,
        magnitudes: ?js.Value,
        phases: ?js.Value,
        exec: *const Execution,
    ) !void {
        const sample_rate = self._proto._context.?._sample_rate;
        const cutoff = (self._frequency._value * std.math.pow(f64, 2, self._detune._value / 1200)) /
            (sample_rate / 2);
        const coefficients = biquad(self._type, cutoff, self._q._value, self._gain._value);
        return respond("BiquadFilterNode", coefficients, sample_rate, frequencies, magnitudes, phases, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BiquadFilterNode);
        pub const Meta = struct {
            pub const name = "BiquadFilterNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(BiquadFilterNode.constructor, .{ .arity = 1 });
        pub const @"type" = bridge.accessor(BiquadFilterNode.getType, BiquadFilterNode.setType, .{});
        pub const frequency = bridge.accessor(BiquadFilterNode.getFrequency, null, .{});
        pub const detune = bridge.accessor(BiquadFilterNode.getDetune, null, .{});
        pub const Q = bridge.accessor(BiquadFilterNode.getQ, null, .{});
        pub const gain = bridge.accessor(BiquadFilterNode.getGain, null, .{});
        pub const getFrequencyResponse = bridge.function(BiquadFilterNode.getFrequencyResponse, .{ .arity = 3 });
    };
};

// ---------------------------------------------------------------------------
// StereoPannerNode
// ---------------------------------------------------------------------------

pub const StereoPannerNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _pan: *AudioParam,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*StereoPannerNode {
        const ctx = try idl.context("StereoPannerNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("StereoPannerNode", "StereoPannerOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);
        if (try idl.optionalF64(dict, "pan")) |value| {
            node._pan._value = std.math.clamp(value, -1, 1);
        }
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*StereoPannerNode {
        const node = try plain(StereoPannerNode, .{
            ._proto = undefined,
            ._pan = try param(0, -1, 1, .@"a-rate", exec),
        }, ctx, null, exec);
        node._proto._channel_count_mode = .@"clamped-max";
        return node;
    }

    pub fn asAudioNode(self: *StereoPannerNode) *AudioNode {
        return self._proto;
    }

    pub fn getPan(self: *StereoPannerNode) *AudioParam {
        return self._pan;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StereoPannerNode);
        pub const Meta = struct {
            pub const name = "StereoPannerNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(StereoPannerNode.constructor, .{ .arity = 1 });
        pub const pan = bridge.accessor(StereoPannerNode.getPan, null, .{});
    };
};

// ---------------------------------------------------------------------------
// ConstantSourceNode
// ---------------------------------------------------------------------------

pub const ConstantSourceNode = struct {
    pub const Proto = AudioScheduledSourceNode;

    _proto: *AudioScheduledSourceNode,
    _offset: *AudioParam,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*ConstantSourceNode {
        const ctx = try idl.context("ConstantSourceNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("ConstantSourceNode", "ConstantSourceOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto._proto, dict);
        if (try idl.optionalF64(dict, "offset")) |value| {
            node._offset._value = value;
        }
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*ConstantSourceNode {
        return source(ConstantSourceNode, .{
            ._proto = undefined,
            ._offset = try param(1, FLT_MIN, FLT_MAX, .@"a-rate", exec),
        }, ctx, null, exec);
    }

    pub fn asAudioScheduledSourceNode(self: *ConstantSourceNode) *AudioScheduledSourceNode {
        return self._proto;
    }

    pub fn getOffset(self: *ConstantSourceNode) *AudioParam {
        return self._offset;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ConstantSourceNode);
        pub const Meta = struct {
            pub const name = "ConstantSourceNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(ConstantSourceNode.constructor, .{ .arity = 1 });
        pub const offset = bridge.accessor(ConstantSourceNode.getOffset, null, .{});
    };
};

// ---------------------------------------------------------------------------
// OscillatorNode
// ---------------------------------------------------------------------------

pub const OscillatorType = enum {
    sine,
    square,
    sawtooth,
    triangle,
    custom,
};

pub const OscillatorNode = struct {
    pub const Proto = AudioScheduledSourceNode;

    _proto: *AudioScheduledSourceNode,
    _type: OscillatorType = .sine,
    _frequency: *AudioParam,
    _detune: *AudioParam,
    _wave: ?*PeriodicWave = null,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*OscillatorNode {
        const ctx = try idl.context("OscillatorNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("OscillatorNode", "OscillatorOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto._proto, dict);

        const wave: ?*PeriodicWave = blk: {
            const value = if (dict) |obj| try obj.get("periodicWave") else break :blk null;
            if (value.isNullOrUndefined()) break :blk null;
            break :blk value.toZig(*PeriodicWave) catch return idl.typeError(
                "Failed to construct 'OscillatorNode': Failed to read the 'periodicWave' property " ++
                    "from 'OscillatorOptions': Failed to convert value to 'PeriodicWave'.",
                exec,
            );
        };

        if (try idl.optionalEnum(
            OscillatorType,
            "OscillatorNode",
            "OscillatorOptions",
            "OscillatorType",
            dict,
            "type",
            exec,
        )) |kind| {
            if (kind == .custom and wave == null) return idl.domError(
                "InvalidStateError",
                "Failed to construct 'OscillatorNode': A PeriodicWave must be specified if the type " ++
                    "is set to \"custom\"",
                exec,
            );
            node._type = kind;
        }
        if (wave) |w| {
            node._wave = w;
            node._type = .custom;
        }
        if (try idl.optionalF64(dict, "frequency")) |value| node._frequency._value = value;
        if (try idl.optionalF64(dict, "detune")) |value| node._detune._value = value;
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*OscillatorNode {
        const nyquist = ctx._sample_rate / 2;
        return source(OscillatorNode, .{
            ._proto = undefined,
            ._frequency = try param(440, -nyquist, nyquist, .@"a-rate", exec),
            ._detune = try param(0, -153600, 153600, .@"a-rate", exec),
        }, ctx, null, exec);
    }

    pub fn asAudioScheduledSourceNode(self: *OscillatorNode) *AudioScheduledSourceNode {
        return self._proto;
    }

    pub fn getType(self: *const OscillatorNode) []const u8 {
        return @tagName(self._type);
    }

    // "custom" is the one value the attribute refuses: it is reachable only
    // through setPeriodicWave (measured).
    pub fn setType(self: *OscillatorNode, kind: []const u8, exec: *const Execution) !void {
        if (std.mem.eql(u8, kind, "custom")) return idl.domError(
            "InvalidStateError",
            "Failed to set the 'type' property on 'OscillatorNode': 'type' cannot be set directly " ++
                "to 'custom'.  Use setPeriodicWave() to create a custom Oscillator type.",
            exec,
        );
        idl.assignEnum(OscillatorType, &self._type, kind);
    }

    pub fn getFrequency(self: *OscillatorNode) *AudioParam {
        return self._frequency;
    }

    pub fn getDetune(self: *OscillatorNode) *AudioParam {
        return self._detune;
    }

    pub fn setPeriodicWave(self: *OscillatorNode, wave: ?js.Value, exec: *const Execution) !void {
        const given = wave orelse return idl.typeError(
            "Failed to execute 'setPeriodicWave' on 'OscillatorNode': 1 argument required, but only 0 present.",
            exec,
        );
        self._wave = given.toZig(*PeriodicWave) catch return idl.typeError(
            "Failed to execute 'setPeriodicWave' on 'OscillatorNode': parameter 1 is not of type 'PeriodicWave'.",
            exec,
        );
        self._type = .custom;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OscillatorNode);
        pub const Meta = struct {
            pub const name = "OscillatorNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(OscillatorNode.constructor, .{ .arity = 1 });
        pub const @"type" = bridge.accessor(OscillatorNode.getType, OscillatorNode.setType, .{});
        pub const frequency = bridge.accessor(OscillatorNode.getFrequency, null, .{});
        pub const detune = bridge.accessor(OscillatorNode.getDetune, null, .{});
        pub const setPeriodicWave = bridge.function(OscillatorNode.setPeriodicWave, .{ .arity = 1 });
    };
};

// ---------------------------------------------------------------------------
// AudioBufferSourceNode
// ---------------------------------------------------------------------------

pub const AudioBufferSourceNode = struct {
    pub const Proto = AudioScheduledSourceNode;

    _proto: *AudioScheduledSourceNode,
    _buffer: ?*AudioBuffer = null,
    _playback_rate: *AudioParam,
    _detune: *AudioParam,
    _loop: bool = false,
    _loop_start: f64 = 0,
    _loop_end: f64 = 0,

    // What start() was handed beyond `when`; see start() below.
    _start_offset: f64 = 0,
    _start_duration: ?f64 = null,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*AudioBufferSourceNode {
        const ctx = try idl.context("AudioBufferSourceNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("AudioBufferSourceNode", "AudioBufferSourceOptions", options, exec);

        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto._proto, dict);

        if (dict) |obj| {
            const buffer = try obj.get("buffer");
            if (!buffer.isNullOrUndefined()) {
                node._buffer = buffer.toZig(*AudioBuffer) catch return idl.typeError(
                    "Failed to construct 'AudioBufferSourceNode': Failed to read the 'buffer' property " ++
                        "from 'AudioBufferSourceOptions': Failed to convert value to 'AudioBuffer'.",
                    exec,
                );
            }
        }
        if (try idl.optionalBool(dict, "loop")) |value| node._loop = value;
        if (try idl.optionalF64(dict, "loopStart")) |value| node._loop_start = value;
        if (try idl.optionalF64(dict, "loopEnd")) |value| node._loop_end = value;
        if (try idl.optionalF64(dict, "playbackRate")) |value| node._playback_rate._value = value;
        if (try idl.optionalF64(dict, "detune")) |value| node._detune._value = value;
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*AudioBufferSourceNode {
        const playback_rate = try param(1, FLT_MIN, FLT_MAX, .@"k-rate", exec);
        playback_rate._fixed_rate_label = "AudioBufferSource.playbackRate";
        const detune = try param(0, FLT_MIN, FLT_MAX, .@"k-rate", exec);
        detune._fixed_rate_label = "AudioBufferSource.detune";

        return source(AudioBufferSourceNode, .{
            ._proto = undefined,
            ._playback_rate = playback_rate,
            ._detune = detune,
        }, ctx, null, exec);
    }

    pub fn asAudioScheduledSourceNode(self: *AudioBufferSourceNode) *AudioScheduledSourceNode {
        return self._proto;
    }

    pub fn getBuffer(self: *const AudioBufferSourceNode) ?*AudioBuffer {
        return self._buffer;
    }

    // A buffer can be installed once. Setting it back to null is fine; setting
    // a second non-null one is an InvalidStateError (measured).
    pub fn setBuffer(self: *AudioBufferSourceNode, buffer: ?js.Value, exec: *const Execution) !void {
        const given = buffer orelse {
            self._buffer = null;
            return;
        };
        if (given.isNullOrUndefined()) {
            self._buffer = null;
            return;
        }
        const value = given.toZig(*AudioBuffer) catch return idl.typeError(
            "Failed to set the 'buffer' property on 'AudioBufferSourceNode': Failed to convert value " ++
                "to 'AudioBuffer'.",
            exec,
        );
        if (self._buffer != null) return idl.domError(
            "InvalidStateError",
            "Failed to set the 'buffer' property on 'AudioBufferSourceNode': Cannot set buffer to " ++
                "non-null after it has been already been set to a non-null buffer",
            exec,
        );
        self._buffer = value;
    }

    pub fn getPlaybackRate(self: *AudioBufferSourceNode) *AudioParam {
        return self._playback_rate;
    }

    pub fn getDetune(self: *AudioBufferSourceNode) *AudioParam {
        return self._detune;
    }

    pub fn getLoop(self: *const AudioBufferSourceNode) bool {
        return self._loop;
    }

    pub fn setLoop(self: *AudioBufferSourceNode, value: bool) void {
        self._loop = value;
    }

    pub fn getLoopStart(self: *const AudioBufferSourceNode) f64 {
        return self._loop_start;
    }

    pub fn setLoopStart(self: *AudioBufferSourceNode, value: f64) void {
        self._loop_start = value;
    }

    pub fn getLoopEnd(self: *const AudioBufferSourceNode) f64 {
        return self._loop_end;
    }

    pub fn setLoopEnd(self: *AudioBufferSourceNode, value: f64) void {
        self._loop_end = value;
    }

    // Its own start(), taking offset and duration on top of `when`, but with
    // the same length of 0 and the same validation as the base one. Both extra
    // arguments are kept rather than dropped: they decide which frames of the
    // buffer reach the destination, which is what buffer_render.zig computes.
    // `duration` is optional in a way `offset` is not -- omitting it plays to
    // the end of the buffer, which no number stands for.
    pub fn start(
        self: *AudioBufferSourceNode,
        when: ?f64,
        offset: ?f64,
        duration: ?f64,
        exec: *const Execution,
    ) !void {
        try self._proto.begin(when, exec);
        self._start_offset = offset orelse 0;
        self._start_duration = duration;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioBufferSourceNode);
        pub const Meta = struct {
            pub const name = "AudioBufferSourceNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(AudioBufferSourceNode.constructor, .{ .arity = 1 });
        pub const buffer = bridge.accessor(AudioBufferSourceNode.getBuffer, AudioBufferSourceNode.setBuffer, .{});
        pub const playbackRate = bridge.accessor(AudioBufferSourceNode.getPlaybackRate, null, .{});
        pub const detune = bridge.accessor(AudioBufferSourceNode.getDetune, null, .{});
        pub const loop = bridge.accessor(AudioBufferSourceNode.getLoop, AudioBufferSourceNode.setLoop, .{});
        pub const loopStart = bridge.accessor(AudioBufferSourceNode.getLoopStart, AudioBufferSourceNode.setLoopStart, .{});
        pub const loopEnd = bridge.accessor(AudioBufferSourceNode.getLoopEnd, AudioBufferSourceNode.setLoopEnd, .{});
        pub const start = bridge.function(AudioBufferSourceNode.start, .{ .arity = 0 });
    };
};

// ---------------------------------------------------------------------------
// ChannelMergerNode / ChannelSplitterNode
// ---------------------------------------------------------------------------

pub const ChannelMergerNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*ChannelMergerNode {
        const ctx = try idl.context("ChannelMergerNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("ChannelMergerNode", "ChannelMergerOptions", options, exec);
        const inputs = try idl.optionalU32(dict, "numberOfInputs") orelse 6;
        try checkChannels("Failed to construct 'ChannelMergerNode'", "inputs", inputs, exec);
        return create(ctx, inputs, dict, exec);
    }

    pub fn create(ctx: *BaseAudioContext, inputs: u32, dict: ?js.Object, exec: *Execution) !*ChannelMergerNode {
        const node = try plain(ChannelMergerNode, .{ ._proto = undefined }, ctx, dict, exec);
        const base = node._proto;
        base._number_of_inputs = inputs;
        base._number_of_outputs = 1;
        base._channel_count = 1;
        base._channel_count_mode = .explicit;
        base._pinned = .channel_merger;
        return node;
    }

    pub fn asAudioNode(self: *ChannelMergerNode) *AudioNode {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChannelMergerNode);
        pub const Meta = struct {
            pub const name = "ChannelMergerNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(ChannelMergerNode.constructor, .{ .arity = 1 });
    };
};

pub const ChannelSplitterNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*ChannelSplitterNode {
        const ctx = try idl.context("ChannelSplitterNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("ChannelSplitterNode", "ChannelSplitterOptions", options, exec);
        const outputs = try idl.optionalU32(dict, "numberOfOutputs") orelse 6;
        try checkChannels("Failed to construct 'ChannelSplitterNode'", "outputs", outputs, exec);
        return create(ctx, outputs, dict, exec);
    }

    pub fn create(ctx: *BaseAudioContext, outputs: u32, dict: ?js.Object, exec: *Execution) !*ChannelSplitterNode {
        const node = try plain(ChannelSplitterNode, .{ ._proto = undefined }, ctx, dict, exec);
        const base = node._proto;
        base._number_of_inputs = 1;
        base._number_of_outputs = outputs;
        base._channel_count = outputs;
        base._channel_count_mode = .explicit;
        base._channel_interpretation = .discrete;
        base._pinned = .channel_splitter;
        return node;
    }

    pub fn asAudioNode(self: *ChannelSplitterNode) *AudioNode {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChannelSplitterNode);
        pub const Meta = struct {
            pub const name = "ChannelSplitterNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(ChannelSplitterNode.constructor, .{ .arity = 1 });
    };
};

pub fn checkChannels(comptime where: []const u8, comptime which: []const u8, count: u32, exec: *const Execution) !void {
    if (count >= 1 and count <= 32) return;
    return idl.domError("IndexSizeError", try std.fmt.allocPrint(
        exec.call_arena,
        where ++ ": The number of " ++ which ++ " provided ({d}) is outside the range [1, 32].",
        .{count},
    ), exec);
}

// ---------------------------------------------------------------------------
// ConvolverNode
// ---------------------------------------------------------------------------

pub const ConvolverNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _buffer: ?*AudioBuffer = null,
    _normalize: bool = true,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*ConvolverNode {
        const ctx = try idl.context("ConvolverNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("ConvolverNode", "ConvolverOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);

        if (dict) |obj| {
            const buffer = try obj.get("buffer");
            if (!buffer.isNullOrUndefined()) {
                node._buffer = buffer.toZig(*AudioBuffer) catch return idl.typeError(
                    "Failed to construct 'ConvolverNode': Failed to read the 'buffer' property from " ++
                        "'ConvolverOptions': Failed to convert value to 'AudioBuffer'.",
                    exec,
                );
            }
        }
        if (try idl.optionalBool(dict, "disableNormalization")) |disabled| {
            node._normalize = !disabled;
        }
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*ConvolverNode {
        const node = try plain(ConvolverNode, .{ ._proto = undefined }, ctx, null, exec);
        node._proto._channel_count_mode = .@"clamped-max";
        return node;
    }

    pub fn asAudioNode(self: *ConvolverNode) *AudioNode {
        return self._proto;
    }

    pub fn getBuffer(self: *const ConvolverNode) ?*AudioBuffer {
        return self._buffer;
    }

    pub fn setBuffer(self: *ConvolverNode, buffer: ?*AudioBuffer) void {
        self._buffer = buffer;
    }

    pub fn getNormalize(self: *const ConvolverNode) bool {
        return self._normalize;
    }

    pub fn setNormalize(self: *ConvolverNode, value: bool) void {
        self._normalize = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ConvolverNode);
        pub const Meta = struct {
            pub const name = "ConvolverNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(ConvolverNode.constructor, .{ .arity = 1 });
        pub const buffer = bridge.accessor(ConvolverNode.getBuffer, ConvolverNode.setBuffer, .{});
        pub const normalize = bridge.accessor(ConvolverNode.getNormalize, ConvolverNode.setNormalize, .{});
    };
};

// ---------------------------------------------------------------------------
// DynamicsCompressorNode
// ---------------------------------------------------------------------------

pub const DynamicsCompressorNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _threshold: *AudioParam,
    _knee: *AudioParam,
    _ratio: *AudioParam,
    _attack: *AudioParam,
    _release: *AudioParam,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*DynamicsCompressorNode {
        const ctx = try idl.context("DynamicsCompressorNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("DynamicsCompressorNode", "DynamicsCompressorOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);

        if (try idl.optionalF64(dict, "threshold")) |value| node._threshold._value = value;
        if (try idl.optionalF64(dict, "knee")) |value| node._knee._value = value;
        if (try idl.optionalF64(dict, "ratio")) |value| node._ratio._value = value;
        if (try idl.optionalF64(dict, "attack")) |value| node._attack._value = value;
        if (try idl.optionalF64(dict, "release")) |value| node._release._value = value;
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*DynamicsCompressorNode {
        const node = try plain(DynamicsCompressorNode, .{
            ._proto = undefined,
            ._threshold = try param(-24, -100, 0, .@"k-rate", exec),
            ._knee = try param(30, 0, 40, .@"k-rate", exec),
            ._ratio = try param(12, 1, 20, .@"k-rate", exec),
            // Chrome's default attack is 0.003 rounded through a float, which
            // reads back as 0.003000000026077032 (measured).
            ._attack = try param(@as(f64, @floatCast(@as(f32, 0.003))), 0, 1, .@"k-rate", exec),
            ._release = try param(0.25, 0, 1, .@"k-rate", exec),
        }, ctx, null, exec);
        node._proto._channel_count_mode = .@"clamped-max";
        return node;
    }

    pub fn asAudioNode(self: *DynamicsCompressorNode) *AudioNode {
        return self._proto;
    }

    pub fn getThreshold(self: *DynamicsCompressorNode) *AudioParam {
        return self._threshold;
    }

    pub fn getKnee(self: *DynamicsCompressorNode) *AudioParam {
        return self._knee;
    }

    pub fn getRatio(self: *DynamicsCompressorNode) *AudioParam {
        return self._ratio;
    }

    // Nothing is being compressed, so there is nothing to reduce by. Chrome
    // reports 0 for an idle compressor too (measured).
    pub fn getReduction(_: *const DynamicsCompressorNode) f64 {
        return 0;
    }

    pub fn getAttack(self: *DynamicsCompressorNode) *AudioParam {
        return self._attack;
    }

    pub fn getRelease(self: *DynamicsCompressorNode) *AudioParam {
        return self._release;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DynamicsCompressorNode);
        pub const Meta = struct {
            pub const name = "DynamicsCompressorNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(DynamicsCompressorNode.constructor, .{ .arity = 1 });
        pub const threshold = bridge.accessor(DynamicsCompressorNode.getThreshold, null, .{});
        pub const knee = bridge.accessor(DynamicsCompressorNode.getKnee, null, .{});
        pub const ratio = bridge.accessor(DynamicsCompressorNode.getRatio, null, .{});
        pub const reduction = bridge.accessor(DynamicsCompressorNode.getReduction, null, .{});
        pub const attack = bridge.accessor(DynamicsCompressorNode.getAttack, null, .{});
        pub const release = bridge.accessor(DynamicsCompressorNode.getRelease, null, .{});
    };
};

// ---------------------------------------------------------------------------
// IIRFilterNode
// ---------------------------------------------------------------------------

pub const IIRFilterNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _feedforward: []const f32,
    _feedback: []const f32,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*IIRFilterNode {
        const ctx = try idl.context("IIRFilterNode", 2, &.{ context, options }, exec);
        const dict = try idl.options("IIRFilterNode", "IIRFilterOptions", options, exec);
        const feedforward_value = try idl.requiredMember("IIRFilterNode", "IIRFilterOptions", "feedforward", dict, exec);
        const feedback_value = try idl.requiredMember("IIRFilterNode", "IIRFilterOptions", "feedback", dict, exec);
        const feedforward = try idl.floatSequence(feedforward_value, exec);
        const feedback = try idl.floatSequence(feedback_value, exec);
        try check("Failed to construct 'IIRFilterNode'", feedforward, feedback, exec);

        const node = try create(ctx, feedforward, feedback, exec);
        try applyNodeOptions(node._proto, dict);
        return node;
    }

    pub fn create(
        ctx: *BaseAudioContext,
        feedforward: []const f32,
        feedback: []const f32,
        exec: *Execution,
    ) !*IIRFilterNode {
        return plain(IIRFilterNode, .{
            ._proto = undefined,
            ._feedforward = feedforward,
            ._feedback = feedback,
        }, ctx, null, exec);
    }

    // Shared with BaseAudioContext.createIIRFilter, which blames itself.
    pub fn check(
        comptime where: []const u8,
        feedforward: []const f32,
        feedback: []const f32,
        exec: *const Execution,
    ) !void {
        if (feedback.len < 1 or feedback.len > 20) return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            where ++ ": The number of feedback coefficients provided ({d}) is outside the range [1, 20].",
            .{feedback.len},
        ), exec);
        if (feedforward.len < 1 or feedforward.len > 20) return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            where ++ ": The number of feedforward coefficients provided ({d}) is outside the range [1, 20].",
            .{feedforward.len},
        ), exec);
        if (feedback[0] == 0) return idl.domError(
            "InvalidStateError",
            where ++ ": First feedback coefficient cannot be zero.",
            exec,
        );
    }

    pub fn asAudioNode(self: *IIRFilterNode) *AudioNode {
        return self._proto;
    }

    pub fn getFrequencyResponse(
        self: *IIRFilterNode,
        frequencies: ?js.Value,
        magnitudes: ?js.Value,
        phases: ?js.Value,
        exec: *const Execution,
    ) !void {
        const sample_rate = self._proto._context.?._sample_rate;
        const forward = try widen(self._feedforward, exec);
        const back = try widen(self._feedback, exec);
        return respondN("IIRFilterNode", forward, back, sample_rate, frequencies, magnitudes, phases, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IIRFilterNode);
        pub const Meta = struct {
            pub const name = "IIRFilterNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(IIRFilterNode.constructor, .{ .arity = 2 });
        pub const getFrequencyResponse = bridge.function(IIRFilterNode.getFrequencyResponse, .{ .arity = 3 });
    };
};

// ---------------------------------------------------------------------------
// PannerNode
// ---------------------------------------------------------------------------

pub const PanningModelType = enum {
    equalpower,
    HRTF,
};

pub const DistanceModelType = enum {
    linear,
    inverse,
    exponential,
};

pub const PannerNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _panning_model: PanningModelType = .equalpower,
    _distance_model: DistanceModelType = .inverse,
    _position_x: *AudioParam,
    _position_y: *AudioParam,
    _position_z: *AudioParam,
    _orientation_x: *AudioParam,
    _orientation_y: *AudioParam,
    _orientation_z: *AudioParam,
    _ref_distance: f64 = 1,
    _max_distance: f64 = 10000,
    _rolloff_factor: f64 = 1,
    _cone_inner_angle: f64 = 360,
    _cone_outer_angle: f64 = 360,
    _cone_outer_gain: f64 = 0,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*PannerNode {
        const ctx = try idl.context("PannerNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("PannerNode", "PannerOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);

        if (try idl.optionalEnum(PanningModelType, "PannerNode", "PannerOptions", "PanningModelType", dict, "panningModel", exec)) |model| {
            node._panning_model = model;
        }
        if (try idl.optionalEnum(DistanceModelType, "PannerNode", "PannerOptions", "DistanceModelType", dict, "distanceModel", exec)) |model| {
            node._distance_model = model;
        }
        if (try idl.optionalF64(dict, "positionX")) |value| node._position_x._value = value;
        if (try idl.optionalF64(dict, "positionY")) |value| node._position_y._value = value;
        if (try idl.optionalF64(dict, "positionZ")) |value| node._position_z._value = value;
        if (try idl.optionalF64(dict, "orientationX")) |value| node._orientation_x._value = value;
        if (try idl.optionalF64(dict, "orientationY")) |value| node._orientation_y._value = value;
        if (try idl.optionalF64(dict, "orientationZ")) |value| node._orientation_z._value = value;
        if (try idl.optionalF64(dict, "refDistance")) |value| node._ref_distance = value;
        if (try idl.optionalF64(dict, "maxDistance")) |value| node._max_distance = value;
        if (try idl.optionalF64(dict, "rolloffFactor")) |value| node._rolloff_factor = value;
        if (try idl.optionalF64(dict, "coneInnerAngle")) |value| node._cone_inner_angle = value;
        if (try idl.optionalF64(dict, "coneOuterAngle")) |value| node._cone_outer_angle = value;
        if (try idl.optionalF64(dict, "coneOuterGain")) |value| node._cone_outer_gain = value;
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*PannerNode {
        const node = try plain(PannerNode, .{
            ._proto = undefined,
            ._position_x = try param(0, FLT_MIN, FLT_MAX, .@"a-rate", exec),
            ._position_y = try param(0, FLT_MIN, FLT_MAX, .@"a-rate", exec),
            ._position_z = try param(0, FLT_MIN, FLT_MAX, .@"a-rate", exec),
            ._orientation_x = try param(1, FLT_MIN, FLT_MAX, .@"a-rate", exec),
            ._orientation_y = try param(0, FLT_MIN, FLT_MAX, .@"a-rate", exec),
            ._orientation_z = try param(0, FLT_MIN, FLT_MAX, .@"a-rate", exec),
        }, ctx, null, exec);
        node._proto._channel_count_mode = .@"clamped-max";
        return node;
    }

    pub fn asAudioNode(self: *PannerNode) *AudioNode {
        return self._proto;
    }

    pub fn getPanningModel(self: *const PannerNode) []const u8 {
        return @tagName(self._panning_model);
    }

    pub fn setPanningModel(self: *PannerNode, model: []const u8) void {
        idl.assignEnum(PanningModelType, &self._panning_model, model);
    }

    pub fn getPositionX(self: *PannerNode) *AudioParam {
        return self._position_x;
    }

    pub fn getPositionY(self: *PannerNode) *AudioParam {
        return self._position_y;
    }

    pub fn getPositionZ(self: *PannerNode) *AudioParam {
        return self._position_z;
    }

    pub fn getOrientationX(self: *PannerNode) *AudioParam {
        return self._orientation_x;
    }

    pub fn getOrientationY(self: *PannerNode) *AudioParam {
        return self._orientation_y;
    }

    pub fn getOrientationZ(self: *PannerNode) *AudioParam {
        return self._orientation_z;
    }

    pub fn getDistanceModel(self: *const PannerNode) []const u8 {
        return @tagName(self._distance_model);
    }

    pub fn setDistanceModel(self: *PannerNode, model: []const u8) void {
        idl.assignEnum(DistanceModelType, &self._distance_model, model);
    }

    pub fn getRefDistance(self: *const PannerNode) f64 {
        return self._ref_distance;
    }

    // The one bound measured on this node: a negative refDistance is a
    // RangeError that names the property.
    pub fn setRefDistance(self: *PannerNode, value: f64, exec: *const Execution) !void {
        if (value < 0) return idl.rangeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to set the 'refDistance' property on 'PannerNode': The refDistance provided ({d}) " ++
                "is less than the minimum bound (0).",
            .{value},
        ), exec);
        self._ref_distance = value;
    }

    pub fn getMaxDistance(self: *const PannerNode) f64 {
        return self._max_distance;
    }

    pub fn setMaxDistance(self: *PannerNode, value: f64) void {
        self._max_distance = value;
    }

    pub fn getRolloffFactor(self: *const PannerNode) f64 {
        return self._rolloff_factor;
    }

    pub fn setRolloffFactor(self: *PannerNode, value: f64) void {
        self._rolloff_factor = value;
    }

    pub fn getConeInnerAngle(self: *const PannerNode) f64 {
        return self._cone_inner_angle;
    }

    pub fn setConeInnerAngle(self: *PannerNode, value: f64) void {
        self._cone_inner_angle = value;
    }

    pub fn getConeOuterAngle(self: *const PannerNode) f64 {
        return self._cone_outer_angle;
    }

    pub fn setConeOuterAngle(self: *PannerNode, value: f64) void {
        self._cone_outer_angle = value;
    }

    pub fn getConeOuterGain(self: *const PannerNode) f64 {
        return self._cone_outer_gain;
    }

    pub fn setConeOuterGain(self: *PannerNode, value: f64) void {
        self._cone_outer_gain = value;
    }

    pub fn setOrientation(self: *PannerNode, x: f64, y: f64, z: f64) void {
        self._orientation_x._value = x;
        self._orientation_y._value = y;
        self._orientation_z._value = z;
    }

    pub fn setPosition(self: *PannerNode, x: f64, y: f64, z: f64) void {
        self._position_x._value = x;
        self._position_y._value = y;
        self._position_z._value = z;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PannerNode);
        pub const Meta = struct {
            pub const name = "PannerNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(PannerNode.constructor, .{ .arity = 1 });
        pub const panningModel = bridge.accessor(PannerNode.getPanningModel, PannerNode.setPanningModel, .{});
        pub const positionX = bridge.accessor(PannerNode.getPositionX, null, .{});
        pub const positionY = bridge.accessor(PannerNode.getPositionY, null, .{});
        pub const positionZ = bridge.accessor(PannerNode.getPositionZ, null, .{});
        pub const orientationX = bridge.accessor(PannerNode.getOrientationX, null, .{});
        pub const orientationY = bridge.accessor(PannerNode.getOrientationY, null, .{});
        pub const orientationZ = bridge.accessor(PannerNode.getOrientationZ, null, .{});
        pub const distanceModel = bridge.accessor(PannerNode.getDistanceModel, PannerNode.setDistanceModel, .{});
        pub const refDistance = bridge.accessor(PannerNode.getRefDistance, PannerNode.setRefDistance, .{});
        pub const maxDistance = bridge.accessor(PannerNode.getMaxDistance, PannerNode.setMaxDistance, .{});
        pub const rolloffFactor = bridge.accessor(PannerNode.getRolloffFactor, PannerNode.setRolloffFactor, .{});
        pub const coneInnerAngle = bridge.accessor(PannerNode.getConeInnerAngle, PannerNode.setConeInnerAngle, .{});
        pub const coneOuterAngle = bridge.accessor(PannerNode.getConeOuterAngle, PannerNode.setConeOuterAngle, .{});
        pub const coneOuterGain = bridge.accessor(PannerNode.getConeOuterGain, PannerNode.setConeOuterGain, .{});
        pub const setOrientation = bridge.function(PannerNode.setOrientation, .{ .arity = 3 });
        pub const setPosition = bridge.function(PannerNode.setPosition, .{ .arity = 3 });
    };
};

// ---------------------------------------------------------------------------
// WaveShaperNode
// ---------------------------------------------------------------------------

pub const OverSampleType = enum {
    none,
    @"2x",
    @"4x",
};

pub const WaveShaperNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _curve: ?Float32Array.Global = null,
    _oversample: OverSampleType = .none,

    pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*WaveShaperNode {
        const ctx = try idl.context("WaveShaperNode", 1, &.{ context, options }, exec);
        const dict = try idl.options("WaveShaperNode", "WaveShaperOptions", options, exec);
        const node = try create(ctx, exec);
        try applyNodeOptions(node._proto, dict);

        if (try idl.optionalFloatSequence(dict, "curve", exec)) |curve| {
            try checkCurve("Failed to construct 'WaveShaperNode'", curve.len, exec);
            node._curve = try store(curve, exec);
        }
        if (try idl.optionalEnum(OverSampleType, "WaveShaperNode", "WaveShaperOptions", "OverSampleType", dict, "oversample", exec)) |kind| {
            node._oversample = kind;
        }
        return node;
    }

    pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*WaveShaperNode {
        return plain(WaveShaperNode, .{ ._proto = undefined }, ctx, null, exec);
    }

    fn checkCurve(comptime where: []const u8, len: usize, exec: *const Execution) !void {
        if (len >= 2) return;
        return idl.domError("InvalidAccessError", try std.fmt.allocPrint(
            exec.call_arena,
            where ++ ": The curve length provided ({d}) is less than the minimum bound (2).",
            .{len},
        ), exec);
    }

    fn store(curve: []const f32, exec: *const Execution) !Float32Array.Global {
        const array = exec.js.local.?.createTypedArray(.float32, curve.len);
        @memcpy(array.slice(), curve);
        return array.persist();
    }

    pub fn asAudioNode(self: *WaveShaperNode) *AudioNode {
        return self._proto;
    }

    pub fn getCurve(self: *const WaveShaperNode) ?Float32Array.Global {
        return self._curve;
    }

    pub fn setCurve(self: *WaveShaperNode, curve: ?js.Value, exec: *const Execution) !void {
        const given = curve orelse {
            self._curve = null;
            return;
        };
        if (given.isNullOrUndefined()) {
            self._curve = null;
            return;
        }
        const values = try idl.floatSequence(given, exec);
        try checkCurve("Failed to set the 'curve' property on 'WaveShaperNode'", values.len, exec);
        self._curve = try store(values, exec);
    }

    pub fn getOversample(self: *const WaveShaperNode) []const u8 {
        return @tagName(self._oversample);
    }

    pub fn setOversample(self: *WaveShaperNode, kind: []const u8) void {
        idl.assignEnum(OverSampleType, &self._oversample, kind);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WaveShaperNode);
        pub const Meta = struct {
            pub const name = "WaveShaperNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(WaveShaperNode.constructor, .{ .arity = 1 });
        pub const curve = bridge.accessor(WaveShaperNode.getCurve, WaveShaperNode.setCurve, .{});
        pub const oversample = bridge.accessor(WaveShaperNode.getOversample, WaveShaperNode.setOversample, .{});
    };
};

// ---------------------------------------------------------------------------
// ScriptProcessorNode
// ---------------------------------------------------------------------------

pub const ScriptProcessorNode = struct {
    pub const Proto = AudioNode;

    _proto: *AudioNode,
    _buffer_size: u32,

    // Reachable only through createScriptProcessor: Chrome answers
    // `new ScriptProcessorNode(ctx)` with an illegal constructor (measured).
    pub fn create(ctx: *BaseAudioContext, buffer_size: u32, exec: *Execution) !*ScriptProcessorNode {
        const node = try plain(ScriptProcessorNode, .{
            ._proto = undefined,
            ._buffer_size = buffer_size,
        }, ctx, null, exec);
        node._proto._channel_count_mode = .explicit;
        return node;
    }

    pub fn asAudioNode(self: *ScriptProcessorNode) *AudioNode {
        return self._proto;
    }

    pub fn getBufferSize(self: *const ScriptProcessorNode) u32 {
        return self._buffer_size;
    }

    pub fn asEventTarget(self: *ScriptProcessorNode) *EventTarget {
        return self._proto.asEventTarget();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ScriptProcessorNode);
        pub const Meta = struct {
            pub const name = "ScriptProcessorNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const onaudioprocess = bridge.accessor(handlerProperty(ScriptProcessorNode, .onaudioprocess).get, handlerProperty(ScriptProcessorNode, .onaudioprocess).set, .{});
        pub const bufferSize = bridge.accessor(ScriptProcessorNode.getBufferSize, null, .{});
    };
};

// ---------------------------------------------------------------------------
// Filter response
// ---------------------------------------------------------------------------

// The transfer function's numerator and denominator, already normalised so
// a0 == 1: H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2).
const Coefficients = struct {
    b: [3]f64,
    a: [2]f64,
};

// Blink's biquad coefficients. Lowpass and highpass take their `Q` in decibels
// (so |H| at the cutoff is 10^(Q/20)); every other type takes it as a plain
// quality factor. Both branches were checked against Chrome's own
// getFrequencyResponse output before this shipped.
fn biquad(kind: BiquadFilterType, normalized_cutoff: f64, q: f64, db_gain: f64) Coefficients {
    const cutoff = std.math.clamp(normalized_cutoff, 0, 1);

    switch (kind) {
        .lowpass, .highpass => {
            const high = kind == .highpass;
            if (cutoff >= 1) return if (high) zeroed() else passthrough();
            if (cutoff <= 0) return if (high) passthrough() else zeroed();
            // Not clamped at zero: a negative Q is a negative *decibel* figure
            // and puts 10^(Q/20) < 1 at the cutoff, which is what Chrome
            // reports (measured: Q = -6 dB gives 0.5011873 there).
            const resonance = std.math.pow(f64, 10, 0.05 * q);
            const theta = std.math.pi * cutoff;
            const alpha = @sin(theta) / (2 * resonance);
            const k = @cos(theta);
            const beta = if (high) (1 + k) / 2 else (1 - k) / 2;
            const a0 = 1 + alpha;
            return .{
                .b = .{ beta / a0, (if (high) -2 * beta else 2 * beta) / a0, beta / a0 },
                .a = .{ -2 * k / a0, (1 - alpha) / a0 },
            };
        },
        .bandpass, .notch, .allpass => {
            if (cutoff <= 0 or cutoff >= 1) return if (kind == .bandpass) zeroed() else passthrough();
            if (q <= 0) return if (kind == .bandpass) passthrough() else zeroed();
            const theta = std.math.pi * cutoff;
            const alpha = @sin(theta) / (2 * q);
            const k = @cos(theta);
            const a0 = 1 + alpha;
            const b: [3]f64 = switch (kind) {
                .bandpass => .{ alpha, 0, -alpha },
                .notch => .{ 1, -2 * k, 1 },
                else => .{ 1 - alpha, -2 * k, 1 + alpha },
            };
            return .{
                .b = .{ b[0] / a0, b[1] / a0, b[2] / a0 },
                .a = .{ -2 * k / a0, (1 - alpha) / a0 },
            };
        },
        // The two shelves are RBJ's cookbook entries with the shelf slope S
        // fixed at 1, so alpha collapses to sin(w)/sqrt(2). They are written out
        // per branch rather than folded behind a sign, because the b1/a1 terms
        // do not mirror each other the way b0/b2 and a0/a2 do: the low shelf's
        // b1 pairs with (A-1) - (A+1)cos while its a1 pairs with the sum, and
        // the high shelf swaps *and* negates both. An earlier revision folded
        // them and was wrong by three orders of magnitude at DC, which went
        // unnoticed because only lowpass and highpass had been measured.
        .lowshelf, .highshelf => {
            const high = kind == .highshelf;
            const amp = std.math.pow(f64, 10, db_gain / 40);
            if (cutoff >= 1) return if (high) passthrough() else gained(amp * amp);
            if (cutoff <= 0) return if (high) gained(amp * amp) else passthrough();
            const theta = std.math.pi * cutoff;
            const k = @cos(theta);
            const k2 = 2 * @sqrt(amp) * @sin(theta) * @sqrt(@as(f64, 2)) / 2;
            const plus = amp + 1;
            const minus = amp - 1;
            if (high) {
                const a0 = plus - minus * k + k2;
                return .{
                    .b = .{
                        amp * (plus + minus * k + k2) / a0,
                        -2 * amp * (minus + plus * k) / a0,
                        amp * (plus + minus * k - k2) / a0,
                    },
                    .a = .{
                        2 * (minus - plus * k) / a0,
                        (plus - minus * k - k2) / a0,
                    },
                };
            }
            const a0 = plus + minus * k + k2;
            return .{
                .b = .{
                    amp * (plus - minus * k + k2) / a0,
                    2 * amp * (minus - plus * k) / a0,
                    amp * (plus - minus * k - k2) / a0,
                },
                .a = .{
                    -2 * (minus + plus * k) / a0,
                    (plus + minus * k - k2) / a0,
                },
            };
        },
        .peaking => {
            const amp = std.math.pow(f64, 10, db_gain / 40);
            if (cutoff <= 0 or cutoff >= 1) return passthrough();
            if (q <= 0) return gained(amp * amp);
            const theta = std.math.pi * cutoff;
            const alpha = @sin(theta) / (2 * q);
            const k = @cos(theta);
            const a0 = 1 + alpha / amp;
            return .{
                .b = .{ (1 + alpha * amp) / a0, -2 * k / a0, (1 - alpha * amp) / a0 },
                .a = .{ -2 * k / a0, (1 - alpha / amp) / a0 },
            };
        },
    }
}

// The IIR node keeps its coefficients as the floats WebIDL handed it; the
// evaluator works in double, the way Blink's does.
fn widen(values: []const f32, exec: *const Execution) ![]f64 {
    const out = try exec.call_arena.alloc(f64, values.len);
    for (out, values) |*slot, value| {
        slot.* = value;
    }
    return out;
}

fn passthrough() Coefficients {
    return .{ .b = .{ 1, 0, 0 }, .a = .{ 0, 0 } };
}

fn zeroed() Coefficients {
    return .{ .b = .{ 0, 0, 0 }, .a = .{ 0, 0 } };
}

fn gained(value: f64) Coefficients {
    return .{ .b = .{ value, 0, 0 }, .a = .{ 0, 0 } };
}

fn respond(
    comptime interface: []const u8,
    coefficients: Coefficients,
    sample_rate: f64,
    frequencies: ?js.Value,
    magnitudes: ?js.Value,
    phases: ?js.Value,
    exec: *const Execution,
) !void {
    return respondN(
        interface,
        &coefficients.b,
        &[_]f64{ 1, coefficients.a[0], coefficients.a[1] },
        sample_rate,
        frequencies,
        magnitudes,
        phases,
        exec,
    );
}

// The general form, over arbitrary-length feedforward/feedback arrays, so the
// IIR node and the biquad node share one evaluator.
fn respondN(
    comptime interface: []const u8,
    feedforward: []const f64,
    feedback: []const f64,
    sample_rate: f64,
    frequencies: ?js.Value,
    magnitudes: ?js.Value,
    phases: ?js.Value,
    exec: *const Execution,
) !void {
    const given = [_]?js.Value{ frequencies, magnitudes, phases };
    const count = idl.present(&given);
    if (count < 3) return idl.typeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute 'getFrequencyResponse' on '" ++ interface ++
            "': 3 arguments required, but only {d} present.",
        .{count},
    ), exec);

    const local = exec.js.local.?;
    const freq = try floats(interface, 1, frequencies.?, local, exec);
    const mag = try floats(interface, 2, magnitudes.?, local, exec);
    const phase = try floats(interface, 3, phases.?, local, exec);

    if (mag.len != freq.len) return lengthError(interface, "magResponse", mag.len, freq.len, exec);
    if (phase.len != freq.len) return lengthError(interface, "phaseResponse", phase.len, freq.len, exec);

    const nyquist = sample_rate / 2;
    for (freq, mag, phase) |f, *m, *p| {
        // Blink stores the normalised frequency in a float32 array before it
        // evaluates anything, so the rounding of that narrowing is part of the
        // answer. It is not a detail: at a notch's own centre frequency the
        // numerator would otherwise cancel to exactly zero and report phase 0,
        // where Chrome reports pi/2 off the float32 residue (measured, and
        // reproduced bit for bit once the narrowing was in).
        const normalized: f32 = @floatCast(@as(f64, f) / nyquist);
        const w = -std.math.pi * @as(f64, normalized);
        const z_real = @cos(w);
        const z_imaginary = @sin(w);

        const numerator = evaluate(feedforward, z_real, z_imaginary);
        const denominator = evaluate(feedback, z_real, z_imaginary);

        const magnitude_squared = denominator.real * denominator.real + denominator.imaginary * denominator.imaginary;
        const real = (numerator.real * denominator.real + numerator.imaginary * denominator.imaginary) / magnitude_squared;
        const imaginary = (numerator.imaginary * denominator.real - numerator.real * denominator.imaginary) / magnitude_squared;
        m.* = @floatCast(@sqrt(real * real + imaginary * imaginary));
        p.* = @floatCast(std.math.atan2(imaginary, real));
    }
}

const Complex = struct { real: f64, imaginary: f64 };

// Horner from the top coefficient down, which is how Blink evaluates both the
// biquad's three-term numerator and the IIR node's arbitrary-length one. The
// nesting matters for the same reason the float32 narrowing above does: a
// straight sum of b[i] * z^i rounds differently and loses the residue that
// decides the phase at a filter's own centre frequency.
fn evaluate(coefficients: []const f64, z_real: f64, z_imaginary: f64) Complex {
    var real: f64 = 0;
    var imaginary: f64 = 0;
    var i = coefficients.len;
    while (i > 0) {
        i -= 1;
        const next_real = real * z_real - imaginary * z_imaginary + coefficients[i];
        imaginary = real * z_imaginary + imaginary * z_real;
        real = next_real;
    }
    return .{ .real = real, .imaginary = imaginary };
}

fn floats(
    comptime interface: []const u8,
    comptime position: usize,
    value: js.Value,
    local: *const js.Local,
    exec: *const Execution,
) ![]f32 {
    _ = local;
    if (!value.isFloat32Array()) return idl.typeError(std.fmt.comptimePrint(
        "Failed to execute 'getFrequencyResponse' on '" ++ interface ++
            "': parameter {d} is not of type 'Float32Array'.",
        .{position},
    ), exec);
    const array = try value.toZig(js.TypedArray(f32));
    return @constCast(array.values);
}

fn lengthError(
    comptime interface: []const u8,
    comptime which: []const u8,
    got: usize,
    want: usize,
    exec: *const Execution,
) anyerror {
    return idl.domError("InvalidAccessError", try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute 'getFrequencyResponse' on '" ++ interface ++ "': The " ++ which ++
            " length provided ({d}) is outside the range [{d}, {d}].",
        .{ got, want, want },
    ), exec);
}
