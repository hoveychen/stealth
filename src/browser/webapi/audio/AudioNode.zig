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
// (Chrome: `new AudioNode()` is an illegal constructor), it exists so that the
// twenty leaf node classes inherit one `channelCount` / `channelCountMode` /
// `channelInterpretation` / `connect` / `disconnect` surface, the way they do
// in Chrome.
//
// There is no rendering graph behind connect(): the engine has no audio thread
// and deliberately does no DSP. The edges are still *recorded*, because two of
// Chrome's refusals depend on them — disconnect() names a destination that was
// never connected, and connect() returns the node it was handed so a script
// that chains `a.connect(b).connect(c)` sees what it expects.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const EventTarget = @import("../EventTarget.zig");
const AudioParam = @import("AudioParam.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

const AudioNode = @This();

pub const Proto = EventTarget;

_type: Type,
_proto: *EventTarget,

// Set by whoever creates the node, immediately after the prototype chain is
// allocated; the chain allocator can only fill in `_type` and `_proto`.
_context: ?*BaseAudioContext = null,

// Chrome's defaults for a node created off a stereo context (measured).
// The channel-count family is overridden per node kind by `applyDefaults`.
_channel_count: u32 = 2,
_channel_count_mode: ChannelCountMode = .max,
_channel_interpretation: ChannelInterpretation = .speakers,
_number_of_inputs: u32 = 1,
_number_of_outputs: u32 = 1,

// Which of the channel attributes this node kind refuses to have changed.
// ChannelMergerNode pins channelCount and channelCountMode, ChannelSplitterNode
// pins all three, and AudioDestinationNode caps channelCount at
// maxChannelCount instead of at 32. Everything measured (win16-chrome.json);
// no other node kind pins anything.
_pinned: Pinned = .none,

// The outgoing edges, in connect() order. Only disconnect() reads them.
_outputs: std.ArrayListUnmanaged(*AudioNode) = .empty,

pub const Pinned = enum {
    none,
    channel_merger,
    channel_splitter,
    destination,

    fn label(self: Pinned) []const u8 {
        return switch (self) {
            .channel_merger => "ChannelMerger",
            .channel_splitter => "ChannelSplitter",
            else => unreachable,
        };
    }
};

const nodes = @import("nodes.zig");

pub const Type = union(enum) {
    destination: *@import("AudioDestinationNode.zig"),
    analyser: *@import("AnalyserNode.zig"),
    scheduled_source: *@import("AudioScheduledSourceNode.zig"),
    biquad_filter: *nodes.BiquadFilterNode,
    channel_merger: *nodes.ChannelMergerNode,
    channel_splitter: *nodes.ChannelSplitterNode,
    convolver: *nodes.ConvolverNode,
    delay: *nodes.DelayNode,
    dynamics_compressor: *nodes.DynamicsCompressorNode,
    gain: *nodes.GainNode,
    iir_filter: *nodes.IIRFilterNode,
    panner: *nodes.PannerNode,
    script_processor: *nodes.ScriptProcessorNode,
    stereo_panner: *nodes.StereoPannerNode,
    wave_shaper: *nodes.WaveShaperNode,
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

pub fn getContext(self: *const AudioNode) *BaseAudioContext {
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

pub fn setChannelCount(self: *AudioNode, count: u32, exec: *const Execution) !void {
    switch (self._pinned) {
        .channel_merger, .channel_splitter => return pinned("channelCount", self._pinned, try std.fmt.allocPrint(
            exec.call_arena,
            "{d}",
            .{self._channel_count},
        ), exec),
        // The destination's ceiling is maxChannelCount, and it complains with an
        // IndexSizeError rather than the NotSupportedError every other node uses.
        .destination => {
            if (count == 0 or count > 2) return idl.domError("IndexSizeError", try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to set the 'channelCount' property on 'AudioNode': The channel count " ++
                    "provided ({d}) is outside the range [1, 2].",
                .{count},
            ), exec);
        },
        .none => {
            if (count == 0 or count > 32) return idl.domError("NotSupportedError", try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to set the 'channelCount' property on 'AudioNode': The channel count " ++
                    "provided ({d}) is outside the range [1, 32].",
                .{count},
            ), exec);
        },
    }
    self._channel_count = count;
}

fn pinned(comptime which: []const u8, kind: Pinned, current: []const u8, exec: *const Execution) anyerror {
    return idl.domError("InvalidStateError", try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to set the '" ++ which ++ "' property on 'AudioNode': {s}: " ++ which ++
            " cannot be changed from {s}",
        .{ kind.label(), current },
    ), exec);
}

pub fn getChannelCountMode(self: *const AudioNode) []const u8 {
    return @tagName(self._channel_count_mode);
}

// The WebIDL enums arrive as strings rather than as a Zig enum parameter: the
// bridge's enum-argument path does not compile on this Zig version. A value
// outside the enum is ignored rather than thrown, which is what Chrome does
// for an enumerated attribute (measured).
pub fn setChannelCountMode(self: *AudioNode, mode: []const u8, exec: *const Execution) !void {
    switch (self._pinned) {
        .channel_merger, .channel_splitter => return pinned("channelCountMode", self._pinned, try std.fmt.allocPrint(
            exec.call_arena,
            "'{s}'",
            .{@tagName(self._channel_count_mode)},
        ), exec),
        else => {},
    }
    idl.assignEnum(ChannelCountMode, &self._channel_count_mode, mode);
}

pub fn getChannelInterpretation(self: *const AudioNode) []const u8 {
    return @tagName(self._channel_interpretation);
}

// The splitter pins this one too; the merger does not (measured — a merger
// takes channelInterpretation = 'discrete' without complaint).
pub fn setChannelInterpretation(self: *AudioNode, interpretation: []const u8, exec: *const Execution) !void {
    if (self._pinned == .channel_splitter) {
        return pinned("channelInterpretation", self._pinned, try std.fmt.allocPrint(
            exec.call_arena,
            "'{s}'",
            .{@tagName(self._channel_interpretation)},
        ), exec);
    }
    idl.assignEnum(ChannelInterpretation, &self._channel_interpretation, interpretation);
}

// `connect` is overloaded on an AudioNode or an AudioParam destination. The
// node form answers with the destination so calls chain; the param form
// answers with undefined (measured). Anything else is Chrome's blanket
// "Overload resolution failed."
pub fn connect(
    self: *AudioNode,
    destination: ?js.Value,
    output: ?u32,
    input: ?u32,
    exec: *const Execution,
) !?*AudioNode {
    const target = destination orelse return idl.typeError(
        "Failed to execute 'connect' on 'AudioNode': 1 argument required, but only 0 present.",
        exec,
    );

    const out = output orelse 0;
    if (target.toZig(*AudioNode)) |node| {
        if (out >= self._number_of_outputs) return outOfRange("output", out, self._number_of_outputs, exec);
        const in = input orelse 0;
        if (in >= node._number_of_inputs) return outOfRange("input", in, node._number_of_inputs, exec);
        if (self._context != node._context) return idl.domError(
            "InvalidAccessError",
            "Failed to execute 'connect' on 'AudioNode': cannot connect to an AudioNode " ++
                "belonging to a different audio context.",
            exec,
        );
        try self._outputs.append(exec.arena, node);
        return node;
    } else |_| {}

    if (target.toZig(*AudioParam)) |_| {
        if (out >= self._number_of_outputs) return outOfRange("output", out, self._number_of_outputs, exec);
        return null;
    } else |_| {}

    return idl.typeError("Failed to execute 'connect' on 'AudioNode': Overload resolution failed.", exec);
}

fn outOfRange(comptime which: []const u8, given: u32, limit: u32, exec: *const Execution) anyerror {
    return idl.domError("IndexSizeError", try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute 'connect' on 'AudioNode': " ++ which ++ " index ({d}) exceeds number of " ++
            which ++ "s ({d}).",
        .{ given, limit },
    ), exec);
}

// No argument drops every edge. A node argument that was never connected is
// an InvalidAccessError, which is the one place the recorded edges matter.
pub fn disconnect(self: *AudioNode, destination: ?js.Value, exec: *const Execution) !void {
    const target = destination orelse {
        self._outputs.clearRetainingCapacity();
        return;
    };
    if (target.isNumber()) {
        self._outputs.clearRetainingCapacity();
        return;
    }
    if (target.toZig(*AudioNode)) |node| {
        for (self._outputs.items, 0..) |connected, i| {
            if (connected == node) {
                _ = self._outputs.orderedRemove(i);
                return;
            }
        }
        return idl.domError(
            "InvalidAccessError",
            "Failed to execute 'disconnect' on 'AudioNode': the given destination is not connected.",
            exec,
        );
    } else |_| {}
    // An AudioParam destination: nothing was ever recorded for one, and Chrome
    // does not complain about disconnecting a param that was never connected.
    if (target.toZig(*AudioParam)) |_| {
        return;
    } else |_| {}
    return idl.typeError("Failed to execute 'disconnect' on 'AudioNode': Overload resolution failed.", exec);
}

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

    pub const connect = bridge.function(AudioNode.connect, .{ .arity = 1, .null_as_undefined = true });
    pub const disconnect = bridge.function(AudioNode.disconnect, .{ .arity = 0 });
};
