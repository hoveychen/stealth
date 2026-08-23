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

// The prototype the three source nodes share (AudioBufferSourceNode,
// ConstantSourceNode, OscillatorNode). Never instantiated on its own — Chrome
// answers `new AudioScheduledSourceNode()` with an illegal constructor.
//
// start()/stop() do not start anything: there is no rendering thread to start.
// They do keep the state machine, because that is the part a script can see —
// calling start twice, or stop before start, is an InvalidStateError in Chrome
// and the two messages name this interface rather than the leaf (measured on a
// headed Chrome 150, win15-chrome.json). `onended` never fires for the same
// reason nothing renders, and Chrome leaves it null on a node that was never
// started either.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const AudioNode = @import("AudioNode.zig");

const Execution = js.Execution;

const AudioScheduledSourceNode = @This();

pub const Proto = AudioNode;

_type: Type,
_proto: *AudioNode,

_started: bool = false,
_stopped: bool = false,

// The times start() and stop() were handed. Nothing is scheduled with them —
// but the canonical audio render (canonical_render.zig) was recorded from a
// source started at 0, and one started later is a different render, while
// buffer_render.zig computes its passthrough between the two.
_start_when: f64 = 0,
_stop_when: f64 = 0,

const nodes = @import("nodes.zig");
const handler_property = @import("../handler_property.zig");
const EventTarget = @import("../EventTarget.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

pub const Type = union(enum) {
    audio_buffer_source: *nodes.AudioBufferSourceNode,
    constant_source: *nodes.ConstantSourceNode,
    oscillator: *nodes.OscillatorNode,
};

pub fn asAudioNode(self: *AudioScheduledSourceNode) *AudioNode {
    return self._proto;
}

pub fn start(self: *AudioScheduledSourceNode, when: ?f64, exec: *const Execution) !void {
    return self.begin(when, exec);
}

// Shared with AudioBufferSourceNode, whose own start() takes three arguments
// but validates the first one exactly the same way.
pub fn begin(self: *AudioScheduledSourceNode, when: ?f64, exec: *const Execution) !void {
    if (self._started) return idl.domError(
        "InvalidStateError",
        "Failed to execute 'start' on 'AudioScheduledSourceNode': cannot call start more than once.",
        exec,
    );
    const at = when orelse 0;
    try validate("start", at, exec);
    self._started = true;
    self._start_when = at;
}

pub fn stop(self: *AudioScheduledSourceNode, when: ?f64, exec: *const Execution) !void {
    if (!self._started) return idl.domError(
        "InvalidStateError",
        "Failed to execute 'stop' on 'AudioScheduledSourceNode': cannot call stop without calling start first.",
        exec,
    );
    const at = when orelse 0;
    try validate("stop", at, exec);
    self._stopped = true;
    self._stop_when = at;
}

fn validate(comptime which: []const u8, when: f64, exec: *const Execution) !void {
    if (when >= 0) return;
    return idl.rangeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ which ++ "' on 'AudioScheduledSourceNode': The " ++ which ++
            " time provided ({d}) is less than the minimum bound (0).",
        .{when},
    ), exec);
}

pub fn asEventTarget(self: *AudioScheduledSourceNode) *EventTarget {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioScheduledSourceNode);

    pub const Meta = struct {
        pub const name = "AudioScheduledSourceNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onended = bridge.accessor(handlerProperty(AudioScheduledSourceNode, .onended).get, handlerProperty(AudioScheduledSourceNode, .onended).set, .{});
    pub const start = bridge.function(AudioScheduledSourceNode.start, .{ .arity = 0 });
    pub const stop = bridge.function(AudioScheduledSourceNode.stop, .{ .arity = 0 });
};
