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

// window.OfflineAudioContext. An earlier revision left this out on purpose, on
// the grounds that rendering it would mean fabricating a constant audio hash
// that matches no real machine. Measuring what Chrome actually renders changed
// the shape of that argument rather than settling it:
//
//   `new OfflineAudioContext(2, 256, 44100).startRendering()` resolves with an
//   AudioBuffer whose samples are *all zero* -- because nothing was connected to
//   the destination. State goes running then closed, currentTime advances to
//   length/sampleRate, and `oncomplete` fires with a trusted, bubbling
//   OfflineAudioCompletionEvent carrying that buffer. All measured on a headed
//   Chrome 150 (win18/win19-chrome.json).
//
// So for the graph this engine can actually render -- an empty one -- silence is
// not a fabrication, it is Chrome's own answer.
//
// A graph with a source in it cannot be computed at all (G10: the wavetable
// comes from 36 inverse FFTs backed by a different library per platform, and the
// compressor calls the platform's libm per sample). One such graph is worth
// answering anyway, because every fingerprintjs clone builds the same one, so
// G21 replays a render recorded off real Chrome for exactly it and leaves every
// other graph silent -- canonical_render.zig has the match and the gaps it
// leaves.
//
// The rest is measured shape: no `baseLatency` and no `close` (both absent
// here), the three createMedia* factories absent because they are AudioContext's,
// a destination whose maxChannelCount is the context's own numberOfChannels, and
// a `suspend()` that never settles because the render never reaches the frame it
// was asked to stop at.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const Event = @import("../Event.zig");
const events = @import("events.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const AudioListener = @import("AudioListener.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");
const canonical_render = @import("canonical_render.zig");
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

const OfflineAudioContext = @This();

pub const Proto = BaseAudioContext;

const MIN_SAMPLE_RATE: f64 = 3000;
const MAX_SAMPLE_RATE: f64 = 768000;
const MAX_CHANNELS: u32 = 32;

_proto: *BaseAudioContext,
_length: u32,

// Set the moment startRendering() is called: a second call is refused for being
// in a "stopped state" even while the first is still in flight (measured).
_started: bool = false,

// Two overloads. `(numberOfChannels, length, sampleRate)` and
// `(OfflineAudioContextOptions)`; anything else is refused by count, by type or
// by Chrome's blanket overload message, each of which reads differently
// (measured: one argument names the dictionary, two are "Overload resolution
// failed.", none is an argument count).
pub fn constructor(first: ?js.Value, second: ?js.Value, third: ?js.Value, exec: *Execution) !*OfflineAudioContext {
    const given = [_]?js.Value{ first, second, third };
    const count = idl.present(&given);

    if (count == 0) return idl.argCount("OfflineAudioContext", 1, 0, exec);
    if (count == 2) return idl.typeError(
        "Failed to construct 'OfflineAudioContext': Overload resolution failed.",
        exec,
    );

    if (count == 1) {
        const dict = first.?;
        if (!dict.isObject()) return idl.typeError(
            "Failed to construct 'OfflineAudioContext': The provided value is not of type " ++
                "'OfflineAudioContextOptions'.",
            exec,
        );
        const object = dict.toObject();
        const length = try idl.requiredMember(
            "OfflineAudioContext",
            "OfflineAudioContextOptions",
            "length",
            object,
            exec,
        );
        const sample_rate = try idl.requiredMember(
            "OfflineAudioContext",
            "OfflineAudioContextOptions",
            "sampleRate",
            object,
            exec,
        );
        return create(
            try idl.optionalU32(object, "numberOfChannels") orelse 1,
            try length.toU32(),
            try sample_rate.toF64(),
            exec,
        );
    }

    return create(try first.?.toU32(), try second.?.toU32(), try third.?.toF64(), exec);
}

// Validated in Chrome's order: channels, then length, then sample rate
// (measured — a call that is wrong on two of them names the first).
fn create(channels: u32, length: u32, sample_rate: f64, exec: *Execution) !*OfflineAudioContext {
    if (channels == 0 or channels > MAX_CHANNELS) {
        return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'OfflineAudioContext': The number of channels provided ({d}) is " ++
                "outside the range [1, 32].",
            .{channels},
        ), exec);
    }
    if (length == 0) {
        return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'OfflineAudioContext': The number of frames provided ({d}) is less " ++
                "than the minimum bound (1).",
            .{length},
        ), exec);
    }
    if (sample_rate < MIN_SAMPLE_RATE or sample_rate > MAX_SAMPLE_RATE) {
        return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'OfflineAudioContext': The sampleRate provided ({d}) is outside the " ++
                "range [3000, 768000].",
            .{sample_rate},
        ), exec);
    }

    const self = try exec._factory.audioContext(OfflineAudioContext{
        ._proto = undefined,
        ._length = length,
    });
    const base = self._proto;
    base._sample_rate = sample_rate;

    // The destination carries the context's channel count as both its count and
    // its ceiling. Unlike a real-time destination it is *not* pinned: Chrome
    // takes `destination.channelCount = 3` on a two-channel offline context
    // (measured), so the ordinary [1, 32] rule applies.
    const destination = try exec._factory.audioNode(AudioDestinationNode{
        ._proto = undefined,
        ._max_channel_count = channels,
    });
    try base.register(destination._proto, exec);
    destination._proto._channel_count = channels;
    destination._proto._number_of_outputs = 0;
    destination._proto._channel_count_mode = .explicit;
    base._destination = destination;
    base._listener = try AudioListener.init(exec);

    return self;
}

pub fn asBaseAudioContext(self: *OfflineAudioContext) *BaseAudioContext {
    return self._proto;
}

pub fn getLength(self: *const OfflineAudioContext) u32 {
    return self._length;
}

// The render quantum. Chrome renders whole quanta, so a context asked for 100
// frames still advances its clock by 128 -- measured across 1/100/128/129/5000
// frames at 44100 and 256/300 at 48000, which all land on
// ceil(length / 128) * 128 / sampleRate.
const RENDER_QUANTUM: u32 = 128;

// Renders the graph. The graph is empty, so the buffer is silent — see the
// header. The rest is Chrome's shape, and the *timing* is the part that matters:
// the call returns with the state still "running" and everything else — the
// clock, the transition to "closed", the `complete` event, and finally the
// promise — happens in a later task.
//
// Doing it inline instead looks equivalent and is not. Every real caller
// attaches its handler on the line *after* startRendering(), so an event
// dispatched inside the call reaches nobody: CreepJS's hasFakeAudio() awaits a
// promise resolved only from `oncomplete`, with no timeout and no reject path,
// and the whole fingerprint stops at "FP ID: Computing..." forever.
pub fn startRendering(self: *OfflineAudioContext, exec: *Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self._started) {
        var resolver = local.createPromiseResolver();
        resolver.reject("OfflineAudioContext.startRendering", @import("../DOMException.zig").init(
            "Failed to execute 'startRendering' on 'OfflineAudioContext': cannot call startRendering " ++
                "on an OfflineAudioContext in a stopped state.",
            "InvalidStateError",
        ));
        return resolver.promise();
    }
    self._started = true;

    const base = self._proto;
    const buffer = try AudioBuffer.create(
        "Failed to execute 'startRendering' on 'OfflineAudioContext'",
        base._destination.?._proto._channel_count,
        self._length,
        base._sample_rate,
        exec,
    );
    // Silent unless the graph is the canonical one, in which case the recorded
    // render goes in here — where Chrome captures the graph too, rather than in
    // the completion task below, so a graph edited after startRendering() has no
    // effect on what was rendered.
    canonical_render.apply(base, buffer, exec);

    try base.transition(.running, exec);

    const resolver = local.createPromiseResolver();
    const promise = resolver.promise();
    const completion = try exec._factory.create(Completion{
        .exec = exec,
        .context = self,
        .buffer = buffer,
        .resolver = try resolver.persist(),
    });
    try exec._scheduler.add(completion, Completion.run, 0, .{
        .name = "audio.offlineRenderComplete",
        .finalizer = Completion.cancelled,
    });

    return promise;
}

// The tail of a render, run as a task rather than inline; see startRendering.
const Completion = struct {
    exec: *Execution,
    context: *OfflineAudioContext,
    buffer: *AudioBuffer,
    resolver: js.PromiseResolver.Global,

    // The scheduler dropped us before we ran (the page went away). The promise
    // stays pending, which is what a torn-down render gives anyway.
    fn cancelled(ctx: *anyopaque) void {
        const self: *Completion = @ptrCast(@alignCast(ctx));
        self.resolver.release();
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *Completion = @ptrCast(@alignCast(ctx));
        const exec = self.exec;
        defer {
            self.resolver.release();
            exec._factory.destroy(self);
        }

        const offline = self.context;
        const base = offline._proto;
        const quanta = (offline._length + RENDER_QUANTUM - 1) / RENDER_QUANTUM;
        base._current_time = @as(f64, @floatFromInt(quanta * RENDER_QUANTUM)) / base._sample_rate;
        try base.transition(.closed, exec);

        const target = base.asEventTarget();
        if (exec.hasDirectListeners(target, "complete", null)) {
            const event = try events.OfflineAudioCompletionEvent.initTrusted(self.buffer, exec);
            try exec.dispatch(target, event.asEvent(), null, .{ .context = "audio complete" });
        }

        // Settles after the event, matching Chrome: a `complete` handler sees
        // the buffer before anything awaiting startRendering() does.
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer {
            ls.local.runMicrotasks();
            ls.deinit();
        }
        self.resolver.local(&ls.local).resolve("OfflineAudioContext.startRendering", self.buffer);
        return null;
    }
};

// Rejects rather than hanging: an offline context that has not started has
// nothing to resume (measured, and the message says exactly that).
pub fn @"resume"(self: *OfflineAudioContext, exec: *const Execution) !js.Promise {
    _ = self;
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("OfflineAudioContext.resume", @import("../DOMException.zig").init(
        "Failed to execute 'resume' on 'OfflineAudioContext': cannot resume an offline context that " ++
            "has not started",
        "InvalidStateError",
    ));
    return resolver.promise();
}

// A negative time and a time at or past the end are both refused; anything in
// range returns a promise that never settles, because the render never stops
// where it was asked to (all three measured).
pub fn @"suspend"(self: *OfflineAudioContext, when: ?f64, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    // `suspend()` with no argument is *not* refused, even though the arity is 1:
    // the missing value converts to NaN, which is neither negative nor past the
    // end, so both checks below fall through to the never-settling promise
    // (measured — Chrome hands back a pending promise rather than throwing).
    const at = when orelse std.math.nan(f64);

    if (at < 0) {
        return reject(try std.fmt.allocPrint(
            exec.arena,
            "Failed to execute 'suspend' on 'OfflineAudioContext': negative suspend time ({d}) is not " ++
                "allowed",
            .{at},
        ), exec);
    }

    // Chrome computes the total duration in single precision, which is visible in
    // the message: 256 frames at 8000 Hz reads 0.03200000151991844, not 0.032.
    const duration: f64 = @as(f32, @floatCast(@as(f64, @floatFromInt(self._length)) / self._proto._sample_rate));
    if (at >= duration) {
        return reject(try std.fmt.allocPrint(
            exec.arena,
            "Failed to execute 'suspend' on 'OfflineAudioContext': cannot schedule a suspend at {d} " ++
                "seconds because it is greater than or equal to the total render duration of {d} " ++
                "frames ({d} seconds)",
            .{ at, self._length, duration },
        ), exec);
    }

    return local.createPromiseResolver().promise();
}

// The message has to outlive this call: a DOMException keeps the slice it was
// handed rather than copying it, and the rejection is delivered on a later
// microtask, by which time `call_arena` has been reused. Hence `exec.arena` for
// the two messages above, unlike the synchronous throws elsewhere in this batch.
fn reject(message: []const u8, exec: *const Execution) !js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("OfflineAudioContext.suspend", @import("../DOMException.zig").init(message, "InvalidStateError"));
    return resolver.promise();
}

pub fn asEventTarget(self: *OfflineAudioContext) *EventTarget {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OfflineAudioContext);

    pub const Meta = struct {
        pub const name = "OfflineAudioContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OfflineAudioContext.constructor, .{ .arity = 1 });

    // Chrome's order.
    pub const oncomplete = bridge.accessor(handlerProperty(OfflineAudioContext, .oncomplete).get, handlerProperty(OfflineAudioContext, .oncomplete).set, .{});
    pub const length = bridge.accessor(OfflineAudioContext.getLength, null, .{});
    pub const @"resume" = bridge.function(OfflineAudioContext.@"resume", .{ .arity = 0 });
    pub const startRendering = bridge.function(OfflineAudioContext.startRendering, .{ .arity = 0 });
    pub const @"suspend" = bridge.function(OfflineAudioContext.@"suspend", .{ .arity = 1 });
};

// The recorded renders are the whole substance of the replay, so they are
// checked against the tail sums Chrome itself reported for the very same
// buffers -- a decode, ordering or endianness slip would show up here long
// before a page could see it. The sums are what `probe-g21` read out of
// Chrome; summing the stored samples has to reproduce them exactly, because
// one ULP anywhere in the tail changes the string a detector hashes.
test "WebApi: recorded canonical audio renders" {
    const chrome_audio = @import("chrome_audio.zig");

    const tail = struct {
        fn sum(graph: chrome_audio.Graph, platform: chrome_audio.Platform) f64 {
            var total: f64 = 0;
            for (chrome_audio.samples(graph, platform)[4500..5000]) |sample| {
                total += @abs(@as(f64, sample));
            }
            return total;
        }
    };

    try std.testing.expectEqual(@as(f64, 124.04347624466754), tail.sum(.fingerprintjs, .macos));
    try std.testing.expectEqual(@as(f64, 124.04347527516074), tail.sum(.fingerprintjs, .linux));
    try std.testing.expectEqual(@as(f64, 112.4458671315806), tail.sum(.turnstile, .macos));
    try std.testing.expectEqual(@as(f64, 112.46367831656244), tail.sum(.turnstile, .linux));

    // The compressor's 6 ms pre-delay, measured identical on both platforms and
    // for both graphs -- they share a sample rate, and that is all it depends
    // on.
    for (std.enums.values(chrome_audio.Graph)) |graph| {
        for (chrome_audio.samples(graph, .macos)[0..265]) |sample| {
            try std.testing.expectEqual(@as(f32, 0), sample);
        }
        try std.testing.expect(chrome_audio.samples(graph, .macos)[265] != 0);
    }

    // And the two are not each other: a stored table per graph is only worth
    // having if the graphs render differently.
    try std.testing.expect(!std.mem.eql(
        f32,
        chrome_audio.samples(.fingerprintjs, .macos),
        chrome_audio.samples(.turnstile, .macos),
    ));
}
