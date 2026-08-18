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

// context.createAnalyser(). The node deviceandbrowserinfo reads eleven values
// off (`analyser-*` in its audio fingerprint), which is why it is in the first
// slice of the audio API: without it that whole detector never renders.
//
// The four get*Data() calls report silence. That is not a fabricated constant:
// it is exactly what Chrome returns for an analyser with nothing connected
// (measured on Chrome 150 — byte frequency all 0, byte time-domain all 128,
// float frequency all -Infinity, float time-domain all 0), and with no audio
// thread and no DSP, silence is also the truth here.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const AudioNode = @import("AudioNode.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

const AnalyserNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,

// Chrome's defaults, measured.
_fft_size: u32 = 2048,
_min_decibels: f64 = -100,
_max_decibels: f64 = -30,
_smoothing_time_constant: f64 = 0.8,

// Constructible in Chrome, unlike the destination node (measured: `new
// AnalyserNode()` complains about the missing context, not about being an
// illegal constructor).
pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*AnalyserNode {
    const ctx = try idl.context("AnalyserNode", 1, &.{ context, options }, exec);
    const dict = try idl.options("AnalyserNode", "AnalyserOptions", options, exec);
    const node = try create(ctx, exec);

    if (try idl.optionalU32(dict, "fftSize")) |size| {
        try checkFftSize("Failed to construct 'AnalyserNode'", size, exec);
        node._fft_size = size;
    }
    const min = try idl.optionalF64(dict, "minDecibels") orelse node._min_decibels;
    const max = try idl.optionalF64(dict, "maxDecibels") orelse node._max_decibels;
    if (max <= min) return idl.domError("IndexSizeError", try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to construct 'AnalyserNode': maxDecibels ({d}) must be greater than or equal to minDecibels ({d}).",
        .{ max, min },
    ), exec);
    node._min_decibels = min;
    node._max_decibels = max;
    if (try idl.optionalF64(dict, "smoothingTimeConstant")) |value| {
        node._smoothing_time_constant = value;
    }
    return node;
}

// Shared with BaseAudioContext.createAnalyser.
pub fn create(ctx: *BaseAudioContext, exec: *Execution) !*AnalyserNode {
    const node = try exec._factory.audioNode(AnalyserNode{ ._proto = undefined });
    try ctx.register(node._proto, exec);
    return node;
}

fn checkFftSize(comptime where: []const u8, size: u32, exec: *const Execution) !void {
    // Chrome: a power of two in [32, 32768], anything else is an IndexSizeError
    // ("The value provided (500) is not a power of two." — measured).
    if (size >= 32 and size <= 32768 and std.math.isPowerOfTwo(size)) return;
    return idl.domError("IndexSizeError", try std.fmt.allocPrint(
        exec.call_arena,
        where ++ ": The value provided ({d}) is not a power of two.",
        .{size},
    ), exec);
}

pub fn asAudioNode(self: *AnalyserNode) *AudioNode {
    return self._proto;
}

pub fn getFftSize(self: *const AnalyserNode) u32 {
    return self._fft_size;
}

pub fn setFftSize(self: *AnalyserNode, size: u32, exec: *const Execution) !void {
    try checkFftSize("Failed to set the 'fftSize' property on 'AnalyserNode'", size, exec);
    self._fft_size = size;
}

pub fn getFrequencyBinCount(self: *const AnalyserNode) u32 {
    return self._fft_size / 2;
}

pub fn getMinDecibels(self: *const AnalyserNode) f64 {
    return self._min_decibels;
}

pub fn setMinDecibels(self: *AnalyserNode, value: f64) !void {
    if (value >= self._max_decibels) {
        return error.IndexSizeError;
    }
    self._min_decibels = value;
}

pub fn getMaxDecibels(self: *const AnalyserNode) f64 {
    return self._max_decibels;
}

pub fn setMaxDecibels(self: *AnalyserNode, value: f64) !void {
    if (value <= self._min_decibels) {
        return error.IndexSizeError;
    }
    self._max_decibels = value;
}

pub fn getSmoothingTimeConstant(self: *const AnalyserNode) f64 {
    return self._smoothing_time_constant;
}

pub fn setSmoothingTimeConstant(self: *AnalyserNode, value: f64) !void {
    if (value < 0 or value > 1) {
        return error.IndexSizeError;
    }
    self._smoothing_time_constant = value;
}

// The four readers below fill the caller's array in place; `values` points
// straight at the V8 backing store, so the const has to be cast off to write.
// Chrome writes min(array.length, binCount / fftSize) entries and leaves the
// rest of a longer array untouched.

pub fn getByteFrequencyData(self: *const AnalyserNode, array: js.TypedArray(u8)) void {
    const into = @constCast(array.values);
    @memset(into[0..@min(into.len, self.getFrequencyBinCount())], 0);
}

pub fn getByteTimeDomainData(self: *const AnalyserNode, array: js.TypedArray(u8)) void {
    const into = @constCast(array.values);
    // 128 is the unsigned-byte encoding of a zero sample.
    @memset(into[0..@min(into.len, self._fft_size)], 128);
}

pub fn getFloatFrequencyData(self: *const AnalyserNode, array: js.TypedArray(f32)) void {
    const into = @constCast(array.values);
    // Silence in dB is negative infinity, which is what Chrome reports.
    @memset(into[0..@min(into.len, self.getFrequencyBinCount())], -std.math.inf(f32));
}

pub fn getFloatTimeDomainData(self: *const AnalyserNode, array: js.TypedArray(f32)) void {
    const into = @constCast(array.values);
    @memset(into[0..@min(into.len, self._fft_size)], 0);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnalyserNode);

    pub const Meta = struct {
        pub const name = "AnalyserNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AnalyserNode.constructor, .{ .arity = 1 });

    pub const fftSize = bridge.accessor(AnalyserNode.getFftSize, AnalyserNode.setFftSize, .{});
    pub const frequencyBinCount = bridge.accessor(AnalyserNode.getFrequencyBinCount, null, .{});
    pub const minDecibels = bridge.accessor(AnalyserNode.getMinDecibels, AnalyserNode.setMinDecibels, .{});
    pub const maxDecibels = bridge.accessor(AnalyserNode.getMaxDecibels, AnalyserNode.setMaxDecibels, .{});
    pub const smoothingTimeConstant = bridge.accessor(AnalyserNode.getSmoothingTimeConstant, AnalyserNode.setSmoothingTimeConstant, .{});

    pub const getByteFrequencyData = bridge.function(AnalyserNode.getByteFrequencyData, .{});
    pub const getByteTimeDomainData = bridge.function(AnalyserNode.getByteTimeDomainData, .{});
    pub const getFloatFrequencyData = bridge.function(AnalyserNode.getFloatFrequencyData, .{});
    pub const getFloatTimeDomainData = bridge.function(AnalyserNode.getFloatTimeDomainData, .{});
};
