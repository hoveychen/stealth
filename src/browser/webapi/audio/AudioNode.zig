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

// The shared prototype under every audio node. Never instantiated on its own
// (Chrome: `new AudioNode()` is an illegal constructor), it exists so that
// AnalyserNode and AudioDestinationNode inherit one `channelCount` /
// `channelCountMode` / `channelInterpretation` / `connect` / `disconnect`
// surface, the way they do in Chrome.
//
// There is no rendering graph behind connect(): the engine has no audio thread
// and deliberately does no DSP, so a connection is recorded only well enough
// for connect() to return the node it was handed (which is what a script that
// chains `a.connect(b).connect(c)` observes).

const std = @import("std");

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const AudioContext = @import("AudioContext.zig");

const AudioNode = @This();

pub const Proto = EventTarget;

_type: Type,
_proto: *EventTarget,

// Set by whoever creates the node, immediately after the prototype chain is
// allocated; the chain allocator can only fill in `_type` and `_proto`.
_context: ?*AudioContext = null,

// Chrome's defaults for a node created off a stereo context (measured).
// AudioDestinationNode overrides `_number_of_outputs` to 0.
_channel_count: u32 = 2,
_channel_count_mode: ChannelCountMode = .max,
_channel_interpretation: ChannelInterpretation = .speakers,
_number_of_inputs: u32 = 1,
_number_of_outputs: u32 = 1,

pub const Type = union(enum) {
    destination: *@import("AudioDestinationNode.zig"),
    analyser: *@import("AnalyserNode.zig"),
};

pub const ChannelCountMode = enum {
    max,
    @"clamped-max",
    explicit,
};

pub const ChannelInterpretation = enum {
    speakers,
    discrete,
};

pub fn asEventTarget(self: *AudioNode) *EventTarget {
    return self._proto;
}

pub fn getContext(self: *const AudioNode) *AudioContext {
    return self._context.?;
}

pub fn getNumberOfInputs(self: *const AudioNode) u32 {
    return self._number_of_inputs;
}

pub fn getNumberOfOutputs(self: *const AudioNode) u32 {
    return self._number_of_outputs;
}

pub fn getChannelCount(self: *const AudioNode) u32 {
    return self._channel_count;
}

pub fn setChannelCount(self: *AudioNode, count: u32) !void {
    // Chrome's ceiling is 32 channels; 0 is a NotSupportedError.
    if (count == 0 or count > 32) {
        return error.NotSupported;
    }
    self._channel_count = count;
}

pub fn getChannelCountMode(self: *const AudioNode) []const u8 {
    return @tagName(self._channel_count_mode);
}

// The WebIDL enums arrive as strings rather than as a Zig enum parameter: the
// bridge's enum-argument path does not compile on this Zig version, and Chrome's
// own failure mode for an unknown value is a TypeError anyway.
pub fn setChannelCountMode(self: *AudioNode, mode: []const u8) !void {
    self._channel_count_mode = std.meta.stringToEnum(ChannelCountMode, mode) orelse return error.TypeError;
}

pub fn getChannelInterpretation(self: *const AudioNode) []const u8 {
    return @tagName(self._channel_interpretation);
}

pub fn setChannelInterpretation(self: *AudioNode, interpretation: []const u8) !void {
    self._channel_interpretation = std.meta.stringToEnum(ChannelInterpretation, interpretation) orelse return error.TypeError;
}

// `output` and `input` are optional so the reported arity is 1, matching
// Chrome's AudioNode.prototype.connect.length (measured).
pub fn connect(self: *AudioNode, destination: *AudioNode, output: ?u32, input: ?u32) !*AudioNode {
    if ((output orelse 0) >= self._number_of_outputs) {
        return error.IndexSizeError;
    }
    if ((input orelse 0) >= destination._number_of_inputs) {
        return error.IndexSizeError;
    }
    if (self._context != destination._context) {
        return error.InvalidAccessError;
    }
    return destination;
}

pub fn disconnect(_: *AudioNode) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioNode);

    pub const Meta = struct {
        pub const name = "AudioNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const context = bridge.accessor(AudioNode.getContext, null, .{});
    pub const numberOfInputs = bridge.accessor(AudioNode.getNumberOfInputs, null, .{});
    pub const numberOfOutputs = bridge.accessor(AudioNode.getNumberOfOutputs, null, .{});
    pub const channelCount = bridge.accessor(AudioNode.getChannelCount, AudioNode.setChannelCount, .{});
    pub const channelCountMode = bridge.accessor(AudioNode.getChannelCountMode, AudioNode.setChannelCountMode, .{});
    pub const channelInterpretation = bridge.accessor(AudioNode.getChannelInterpretation, AudioNode.setChannelInterpretation, .{});

    pub const connect = bridge.function(AudioNode.connect, .{});
    pub const disconnect = bridge.function(AudioNode.disconnect, .{});
};
