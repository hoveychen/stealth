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
// All eighteen of Chrome's `create*` factories are here, plus decodeAudioData.
// An earlier revision carried only createAnalyser, on the theory that a node
// which cannot process anything is worse than a missing one. Measuring what a
// detector actually reads settled it the other way: nothing here is asked to
// render, but every one of these classes is asked to *exist*, and a
// BaseAudioContext with eight prototype members where Chrome has twenty-seven
// is the louder signal by far.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const nodes = @import("nodes.zig");
const AudioNode = @import("AudioNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const AnalyserNode = @import("AnalyserNode.zig");
const AudioListener = @import("AudioListener.zig");
const PeriodicWave = @import("PeriodicWave.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");
const worklet = @import("worklet.zig");
const DOMException = @import("../DOMException.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

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

// Zero on a real-time context, which never starts; an offline one lands on
// length/sampleRate once it has rendered (measured).
_current_time: f64 = 0,

// Built on first read and kept, because Chrome hands back the same object every
// time (measured: ctx.audioWorklet === ctx.audioWorklet).
_audio_worklet: ?*worklet.AudioWorklet = null,

// Every node built for this context, its destination included, in creation
// order. Nothing renders from it -- there is no audio thread. What needs it is
// the canonical-render match (canonical_render.zig), which has to know what
// feeds the destination: `AudioNode._outputs` records only forward edges, so
// walking back from the destination is impossible without this list.
_nodes: std.ArrayListUnmanaged(*AudioNode) = .empty,

// How many times something in this context was connected to an AudioParam.
// Those edges are deliberately not recorded (connect() answers undefined and
// keeps nothing), so the count is all there is -- and a graph that modulates a
// parameter renders differently, which is why canonical_render.zig refuses to
// claim a recorded render once this is nonzero.
_param_edges: u32 = 0,

pub const Type = union(enum) {
    audio_context: *@import("AudioContext.zig"),
    offline_audio_context: *@import("OfflineAudioContext.zig"),
};

pub const State = enum {
    suspended,
    running,
    closed,
};

pub fn asEventTarget(self: *BaseAudioContext) *EventTarget {
    return self._proto;
}

/// Attaches a freshly allocated node to this context. Every node kind goes
/// through here — it is the only place `_context` is assigned — so `_nodes`
/// cannot quietly miss one and leave the canonical-render match reading a
/// graph that is smaller than the real one.
pub fn register(self: *BaseAudioContext, node: *AudioNode, exec: *const Execution) !void {
    node._context = self;
    try self._nodes.append(exec.arena, node);
}

/// The single node with an edge into `target`, or null when nothing feeds it or
/// more than one thing does. A node connected to the same target twice still
/// counts once, because a repeated connect() is a no-op in Chrome.
///
/// Both render paths ask this and nothing else about the shape of the graph:
/// what a destination renders depends on what reaches it, not on what else the
/// context happens to hold.
pub fn soleSource(self: *BaseAudioContext, target: *AudioNode) ?*AudioNode {
    var found: ?*AudioNode = null;
    for (self._nodes.items) |node| {
        if (node == target) continue;
        for (node._outputs.items) |output| {
            if (output != target) continue;
            if (found != null and found != node) return null;
            found = node;
            break;
        }
    }
    return found;
}

/// Every distinct node with an edge into `target`, written into `out` and
/// counted. A node connected twice counts once, for the same reason
/// `soleSource` collapses it: Chrome treats a repeated connect() as a no-op and
/// renders one copy of the signal (measured — `doubleConnect` in
/// tools/fingerprint/probes/expr-b153-fanin.js renders the single-path sum).
///
/// Returns null when there are more sources than `out` can hold, which reads
/// the same as "a graph nothing here has a recording for".
pub fn sources(self: *BaseAudioContext, target: *AudioNode, out: []*AudioNode) ?[]*AudioNode {
    var count: usize = 0;
    for (self._nodes.items) |node| {
        if (node == target) continue;
        for (node._outputs.items) |output| {
            if (output != target) continue;
            if (count == out.len) return null;
            out[count] = node;
            count += 1;
            break;
        }
    }
    return out[0..count];
}

pub fn getSampleRate(self: *const BaseAudioContext) f64 {
    return self._sample_rate;
}

pub fn getState(self: *const BaseAudioContext) []const u8 {
    return @tagName(self._state);
}

// Zero on a real-time context, which never starts — measured on a headed window
// as well as a headless one, because the reason is the autoplay policy and not
// the absence of an audio device. An OfflineAudioContext does move it: rendering
// puts it at length/sampleRate in one step, which is where Chrome leaves it too.
pub fn getCurrentTime(self: *const BaseAudioContext) f64 {
    return self._current_time;
}

pub fn getDestination(self: *const BaseAudioContext) *AudioDestinationNode {
    return self._destination.?;
}

pub fn getListener(self: *const BaseAudioContext) *AudioListener {
    return self._listener.?;
}

pub fn getAudioWorklet(self: *BaseAudioContext, exec: *Execution) !*worklet.AudioWorklet {
    if (self._audio_worklet) |existing| {
        return existing;
    }
    const created = try exec._factory.audioWorklet(worklet.AudioWorklet{ ._proto = undefined });
    self._audio_worklet = created;
    return created;
}

// Deliberately no closed-state check on any factory: Chrome still hands back a
// node after close() (measured — createAnalyser on a closed context returns
// normally).
//
// Each one below is the constructor's argument list flattened into positional
// parameters, which is how the two forms differ in Chrome: `createDelay(5)`
// and `new DelayNode(ctx, {maxDelayTime: 5})` build the same node but word
// their refusals differently, so the shared checks take the caller's prefix.

pub fn createAnalyser(self: *BaseAudioContext, exec: *Execution) !*AnalyserNode {
    return AnalyserNode.create(self, exec);
}

pub fn createBiquadFilter(self: *BaseAudioContext, exec: *Execution) !*nodes.BiquadFilterNode {
    return nodes.BiquadFilterNode.create(self, exec);
}

pub fn createBuffer(
    self: *BaseAudioContext,
    channels: u32,
    length: u32,
    sample_rate: f64,
    exec: *Execution,
) !*AudioBuffer {
    _ = self;
    return AudioBuffer.create("Failed to execute 'createBuffer' on 'BaseAudioContext'", channels, length, sample_rate, exec);
}

pub fn createBufferSource(self: *BaseAudioContext, exec: *Execution) !*nodes.AudioBufferSourceNode {
    return nodes.AudioBufferSourceNode.create(self, exec);
}

pub fn createChannelMerger(self: *BaseAudioContext, inputs: ?u32, exec: *Execution) !*nodes.ChannelMergerNode {
    const count = inputs orelse 6;
    try nodes.checkChannels("Failed to execute 'createChannelMerger' on 'BaseAudioContext'", "inputs", count, exec);
    return nodes.ChannelMergerNode.create(self, count, null, exec);
}

pub fn createChannelSplitter(self: *BaseAudioContext, outputs: ?u32, exec: *Execution) !*nodes.ChannelSplitterNode {
    const count = outputs orelse 6;
    try nodes.checkChannels("Failed to execute 'createChannelSplitter' on 'BaseAudioContext'", "outputs", count, exec);
    return nodes.ChannelSplitterNode.create(self, count, null, exec);
}

pub fn createConstantSource(self: *BaseAudioContext, exec: *Execution) !*nodes.ConstantSourceNode {
    return nodes.ConstantSourceNode.create(self, exec);
}

pub fn createConvolver(self: *BaseAudioContext, exec: *Execution) !*nodes.ConvolverNode {
    return nodes.ConvolverNode.create(self, exec);
}

pub fn createDelay(self: *BaseAudioContext, max_delay_time: ?f64, exec: *Execution) !*nodes.DelayNode {
    const max_delay = max_delay_time orelse 1;
    try nodes.DelayNode.checkMaxDelay("Failed to execute 'createDelay' on 'BaseAudioContext'", max_delay, exec);
    return nodes.DelayNode.create(self, max_delay, exec);
}

pub fn createDynamicsCompressor(self: *BaseAudioContext, exec: *Execution) !*nodes.DynamicsCompressorNode {
    return nodes.DynamicsCompressorNode.create(self, exec);
}

pub fn createGain(self: *BaseAudioContext, exec: *Execution) !*nodes.GainNode {
    return nodes.GainNode.create(self, exec);
}

pub fn createIIRFilter(
    self: *BaseAudioContext,
    feedforward: ?js.Value,
    feedback: ?js.Value,
    exec: *Execution,
) !*nodes.IIRFilterNode {
    const where = "Failed to execute 'createIIRFilter' on 'BaseAudioContext'";
    const given = [_]?js.Value{ feedforward, feedback };
    const count = idl.present(&given);
    if (count < 2) return idl.typeError(try std.fmt.allocPrint(
        exec.call_arena,
        where ++ ": 2 arguments required, but only {d} present.",
        .{count},
    ), exec);
    const forward = try idl.floatSequence(feedforward.?, exec);
    const back = try idl.floatSequence(feedback.?, exec);
    try nodes.IIRFilterNode.check(where, forward, back, exec);
    return nodes.IIRFilterNode.create(self, forward, back, exec);
}

pub fn createOscillator(self: *BaseAudioContext, exec: *Execution) !*nodes.OscillatorNode {
    return nodes.OscillatorNode.create(self, exec);
}

pub fn createPanner(self: *BaseAudioContext, exec: *Execution) !*nodes.PannerNode {
    return nodes.PannerNode.create(self, exec);
}

pub fn createPeriodicWave(
    self: *BaseAudioContext,
    real: ?js.Value,
    imag: ?js.Value,
    exec: *Execution,
) !*PeriodicWave {
    _ = self;
    const where = "Failed to execute 'createPeriodicWave' on 'BaseAudioContext'";
    const given = [_]?js.Value{ real, imag };
    const count = idl.present(&given);
    if (count < 2) return idl.typeError(try std.fmt.allocPrint(
        exec.call_arena,
        where ++ ": 2 arguments required, but only {d} present.",
        .{count},
    ), exec);
    return PeriodicWave.create(where, try idl.floatSequence(real.?, exec), try idl.floatSequence(imag.?, exec), exec);
}

pub fn createScriptProcessor(self: *BaseAudioContext, buffer_size: ?u32, exec: *Execution) !*nodes.ScriptProcessorNode {
    // 0 means "let the implementation choose", and Chrome chooses 1024 here
    // (measured); anything else must be a power of two in [256, 16384].
    const requested = buffer_size orelse 0;
    const size = if (requested == 0) 1024 else requested;
    if (size < 256 or size > 16384 or !std.math.isPowerOfTwo(size)) {
        return idl.domError("IndexSizeError", try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute 'createScriptProcessor' on 'BaseAudioContext': buffer size ({d}) must " ++
                "be 0 or a power of two between 256 and 16384.",
            .{requested},
        ), exec);
    }
    return nodes.ScriptProcessorNode.create(self, size, exec);
}

pub fn createStereoPanner(self: *BaseAudioContext, exec: *Execution) !*nodes.StereoPannerNode {
    return nodes.StereoPannerNode.create(self, exec);
}

pub fn createWaveShaper(self: *BaseAudioContext, exec: *Execution) !*nodes.WaveShaperNode {
    return nodes.WaveShaperNode.create(self, exec);
}

// There is no decoder behind this, but Chrome always settles: an AudioBuffer
// for bytes it can decode, an EncodingError for bytes it cannot. Taking the
// second branch is the honest answer here, and -- unlike the pending promise
// this used to return -- one the caller can carry on from. macys' Akamai
// sensor awaits `decodeAudioData(new ArrayBuffer(4))` inside a Promise.all;
// while that await hung, the sensor never sent its second round and the
// interstitial never cleared (38th baton, offline replay).
//
// Chrome also detaches the buffer it is handed. This does not, for want of a
// binding for `ArrayBuffer::Detach`, so the DataCloneError a detached buffer
// gets there has no path to happen here.
pub fn decodeAudioData(
    self: *BaseAudioContext,
    data_: ?js.Value,
    _: ?js.Function,
    error_callback: ?js.Function,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    var resolver = local.createPromiseResolver();

    // Both arms go through rejectValue rather than reject/rejectError: those
    // drain the microtask queue, and draining it here -- with the calling
    // script still on the stack, before it has had a line to attach its catch
    // -- reports an unhandled rejection Chrome never reports (measured: Chrome
    // retracts the report when the handler arrives in the same turn).
    const is_buffer = if (data_) |data| data.isArrayBuffer() else false;
    if (!is_buffer) {
        // Chrome reports the IDL mismatch through the promise rather than
        // throwing, and an ArrayBufferView is as wrong as a null (measured).
        const message = local.isolate.createTypeError(
            "Failed to execute 'decodeAudioData' on 'BaseAudioContext': " ++
                "parameter 1 is not of type 'ArrayBuffer'.",
        );
        try resolver.rejectValue(.{ .handle = message, .local = local });
        return resolver.promise();
    }

    try resolver.rejectValue(try local.zigValueToJs(DOMException.init(
        "Unable to decode audio data",
        "EncodingError",
    ), .{}));
    const promise = resolver.promise();

    // The legacy callback pair predates the promise and Chrome still honours
    // it: the error callback gets the same exception, ahead of whatever the
    // caller attached. Hanging it off the promise is what puts it in that
    // order. The success half is unreachable while every decode fails, so the
    // fulfilled slot only has to be something callable.
    if (error_callback) |callback| {
        const chained = try promise.thenAndCatch(local.newCallback(unusedFulfilled, self), callback);
        chained.markAsHandled();
    }
    return promise;
}

fn unusedFulfilled(_: *BaseAudioContext) void {}

// Moves the state and fires statechange. Called by AudioContext's
// suspend/close; `running` is unreachable — see resume() there.
pub fn transition(self: *BaseAudioContext, to: State, exec: *const Execution) !void {
    if (self._state == to) {
        return;
    }
    self._state = to;

    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "statechange", null)) {
        return;
    }
    const event = try Event.initTrusted(comptime .wrap("statechange"), .{}, exec.page);
    return exec.dispatch(target, event, null, .{ .context = "audio statechange" });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BaseAudioContext);

    pub const Meta = struct {
        pub const name = "BaseAudioContext";
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "decodeAudioData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order exactly: the six attributes, then the factories
    // alphabetically, then decodeAudioData. (`audioWorklet` sits *after*
    // `constructor` in Chrome, which V8 cannot reproduce here — the same
    // limitation the rest of this batch runs into.)
    pub const destination = bridge.accessor(BaseAudioContext.getDestination, null, .{});
    pub const sampleRate = bridge.accessor(BaseAudioContext.getSampleRate, null, .{});
    pub const currentTime = bridge.accessor(BaseAudioContext.getCurrentTime, null, .{});
    pub const listener = bridge.accessor(BaseAudioContext.getListener, null, .{});
    pub const state = bridge.accessor(BaseAudioContext.getState, null, .{});
    pub const onstatechange = bridge.accessor(handlerProperty(BaseAudioContext, .onstatechange).get, handlerProperty(BaseAudioContext, .onstatechange).set, .{});

    pub const createAnalyser = bridge.function(BaseAudioContext.createAnalyser, .{ .arity = 0 });
    pub const createBiquadFilter = bridge.function(BaseAudioContext.createBiquadFilter, .{ .arity = 0 });
    pub const createBuffer = bridge.function(BaseAudioContext.createBuffer, .{ .arity = 3 });
    pub const createBufferSource = bridge.function(BaseAudioContext.createBufferSource, .{ .arity = 0 });
    pub const createChannelMerger = bridge.function(BaseAudioContext.createChannelMerger, .{ .arity = 0 });
    pub const createChannelSplitter = bridge.function(BaseAudioContext.createChannelSplitter, .{ .arity = 0 });
    pub const createConstantSource = bridge.function(BaseAudioContext.createConstantSource, .{ .arity = 0 });
    pub const createConvolver = bridge.function(BaseAudioContext.createConvolver, .{ .arity = 0 });
    pub const createDelay = bridge.function(BaseAudioContext.createDelay, .{ .arity = 0 });
    pub const createDynamicsCompressor = bridge.function(BaseAudioContext.createDynamicsCompressor, .{ .arity = 0 });
    pub const createGain = bridge.function(BaseAudioContext.createGain, .{ .arity = 0 });
    pub const createIIRFilter = bridge.function(BaseAudioContext.createIIRFilter, .{ .arity = 2 });
    pub const createOscillator = bridge.function(BaseAudioContext.createOscillator, .{ .arity = 0 });
    pub const createPanner = bridge.function(BaseAudioContext.createPanner, .{ .arity = 0 });
    pub const createPeriodicWave = bridge.function(BaseAudioContext.createPeriodicWave, .{ .arity = 2 });
    pub const createScriptProcessor = bridge.function(BaseAudioContext.createScriptProcessor, .{ .arity = 0 });
    pub const createStereoPanner = bridge.function(BaseAudioContext.createStereoPanner, .{ .arity = 0 });
    pub const createWaveShaper = bridge.function(BaseAudioContext.createWaveShaper, .{ .arity = 0 });
    pub const decodeAudioData = bridge.function(BaseAudioContext.decodeAudioData, .{ .arity = 1 });

    // Chrome puts this after `constructor`, which V8 cannot reproduce here.
    pub const audioWorklet = bridge.accessor(BaseAudioContext.getAudioWorklet, null, .{});
};
