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

// A block of silence a script can write into. Unlike most of this batch there
// is nothing to fake here: an AudioBuffer *is* just memory plus a sample rate,
// and every operation on it is defined without reference to an audio device.
// Chrome hands back all-zero channels for a fresh buffer and so do we; the
// channel arrays are the same Float32Array objects on every getChannelData
// (measured: b.getChannelData(0) === b.getChannelData(0)).
//
// The refusals are Chrome 150's, measured (win15/win16-chrome.json). Note that
// createBuffer() and `new AudioBuffer()` word the same failure differently —
// one names 'createBuffer' on 'BaseAudioContext', the other 'AudioBuffer' —
// so every message here takes the caller's own prefix.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");

const Execution = js.Execution;
const Float32Array = js.ArrayBufferRef(.float32);

const AudioBuffer = @This();

const MIN_SAMPLE_RATE: f64 = 3000;
const MAX_SAMPLE_RATE: f64 = 768000;
const MAX_CHANNELS: u32 = 32;

_length: u32,
_sample_rate: f64,
_channels: []Float32Array.Global,

// `new AudioBuffer(options)` — no context involved, unlike every node.
pub fn constructor(options: ?js.Value, exec: *Execution) !*AudioBuffer {
    if (options == null) return idl.argCount("AudioBuffer", 1, 0, exec);
    const dict = try idl.options("AudioBuffer", "AudioBufferOptions", options, exec);
    if (dict == null) return idl.typeError(
        "Failed to construct 'AudioBuffer': The provided value is not of type 'AudioBufferOptions'.",
        exec,
    );

    const length_value = try idl.requiredMember("AudioBuffer", "AudioBufferOptions", "length", dict, exec);
    const rate_value = try idl.requiredMember("AudioBuffer", "AudioBufferOptions", "sampleRate", dict, exec);
    const channels = try idl.optionalU32(dict, "numberOfChannels") orelse 1;

    return create("AudioBuffer", channels, try length_value.toU32(), try rate_value.toF64(), exec);
}

// Shared with BaseAudioContext.createBuffer, which validates in the same order
// but blames itself in the message.
pub fn create(
    comptime where: []const u8,
    channels: u32,
    length: u32,
    sample_rate: f64,
    exec: *Execution,
) !*AudioBuffer {
    if (channels == 0 or channels > MAX_CHANNELS) return idl.domError("NotSupportedError", try std.fmt.allocPrint(
        exec.call_arena,
        where ++ ": The number of channels provided ({d}) is outside the range [1, 32].",
        .{channels},
    ), exec);
    if (length == 0) return idl.domError("NotSupportedError", try std.fmt.allocPrint(
        exec.call_arena,
        where ++ ": The number of frames provided ({d}) is less than or equal to the minimum bound (0).",
        .{length},
    ), exec);
    if (sample_rate < MIN_SAMPLE_RATE or sample_rate > MAX_SAMPLE_RATE) {
        return idl.domError("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            where ++ ": The sample rate provided ({d}) is outside the range [3000, 768000].",
            .{sample_rate},
        ), exec);
    }

    const local = exec.js.local.?;
    const arrays = try exec.arena.alloc(Float32Array.Global, channels);
    for (arrays) |*slot| {
        const array = local.createTypedArray(.float32, length);
        @memset(array.slice(), 0);
        slot.* = try array.persist();
    }

    return exec._factory.create(AudioBuffer{
        ._length = length,
        ._sample_rate = sample_rate,
        ._channels = arrays,
    });
}

pub fn getLength(self: *const AudioBuffer) u32 {
    return self._length;
}

pub fn getDuration(self: *const AudioBuffer) f64 {
    return @as(f64, @floatFromInt(self._length)) / self._sample_rate;
}

pub fn getSampleRate(self: *const AudioBuffer) f64 {
    return self._sample_rate;
}

pub fn getNumberOfChannels(self: *const AudioBuffer) u32 {
    return @intCast(self._channels.len);
}

pub fn getChannelData(self: *const AudioBuffer, channel: ?u32, exec: *const Execution) !Float32Array.Global {
    const index = channel orelse return idl.typeError(
        "Failed to execute 'getChannelData' on 'AudioBuffer': 1 argument required, but only 0 present.",
        exec,
    );
    if (index >= self._channels.len) return idl.domError("IndexSizeError", try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute 'getChannelData' on 'AudioBuffer': channel index ({d}) exceeds number of channels ({d})",
        .{ index, self._channels.len },
    ), exec);
    return self._channels[index];
}

pub fn copyFromChannel(
    self: *const AudioBuffer,
    destination: ?js.TypedArray(f32),
    channel: ?u32,
    start: ?u32,
    exec: *const Execution,
) !void {
    const into = destination orelse return copyArgCount("copyFromChannel", 0, exec);
    const index = channel orelse return copyArgCount("copyFromChannel", 1, exec);
    const source = try self.channelSlice("copyFromChannel", index, exec);

    const offset = @min(start orelse 0, self._length);
    const available = source[offset..];
    const out = @constCast(into.values);
    const count = @min(out.len, available.len);
    @memcpy(out[0..count], available[0..count]);
}

pub fn copyToChannel(
    self: *AudioBuffer,
    source: ?js.TypedArray(f32),
    channel: ?u32,
    start: ?u32,
    exec: *const Execution,
) !void {
    const from = source orelse return copyArgCount("copyToChannel", 0, exec);
    const index = channel orelse return copyArgCount("copyToChannel", 1, exec);
    const into = try self.channelSlice("copyToChannel", index, exec);

    const offset = @min(start orelse 0, self._length);
    const room = into[offset..];
    const count = @min(room.len, from.values.len);
    @memcpy(room[0..count], from.values[0..count]);
}

fn copyArgCount(comptime which: []const u8, got: usize, exec: *const Execution) anyerror {
    return idl.typeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ which ++ "' on 'AudioBuffer': 2 arguments required, but only {d} present.",
        .{got},
    ), exec);
}

fn channelSlice(self: *const AudioBuffer, comptime which: []const u8, index: u32, exec: *const Execution) ![]f32 {
    if (index >= self._channels.len) return idl.domError("IndexSizeError", try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ which ++ "' on 'AudioBuffer': The channelNumber provided ({d}) is " ++
            "outside the range [0, {d}].",
        .{ index, self._channels.len - 1 },
    ), exec);
    return self._channels[index].local(exec.js.local.?).slice();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioBuffer);

    pub const Meta = struct {
        pub const name = "AudioBuffer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioBuffer.constructor, .{ .arity = 1 });

    pub const length = bridge.accessor(AudioBuffer.getLength, null, .{});
    pub const duration = bridge.accessor(AudioBuffer.getDuration, null, .{});
    pub const sampleRate = bridge.accessor(AudioBuffer.getSampleRate, null, .{});
    pub const numberOfChannels = bridge.accessor(AudioBuffer.getNumberOfChannels, null, .{});

    pub const copyFromChannel = bridge.function(AudioBuffer.copyFromChannel, .{ .arity = 2 });
    pub const copyToChannel = bridge.function(AudioBuffer.copyToChannel, .{ .arity = 2 });
    pub const getChannelData = bridge.function(AudioBuffer.getChannelData, .{ .arity = 1 });
};
