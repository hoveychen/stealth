// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// A channel handed back by pc.createDataChannel(). Nothing is ever transported
// over it, and it never opens — which is not a shortcut: a channel on a
// connection that has no answer stays in "connecting" in Chrome too (measured,
// along with `id` null and `binaryType` "arraybuffer"). Scripts create one
// purely to make createOffer() emit the m=application section, and that is the
// use this supports.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const Execution = js.Execution;

const RTCDataChannel = @This();

pub const Proto = EventTarget;

pub const ReadyState = enum {
    connecting,
    open,
    closing,
    closed,

    pub fn toString(self: ReadyState) []const u8 {
        return @tagName(self);
    }
};

_proto: *EventTarget,
_label: []const u8 = "",
_protocol: []const u8 = "",
_ordered: bool = true,
_max_packet_life_time: ?u32 = null,
_max_retransmits: ?u32 = null,
_negotiated: bool = false,
_id: ?u32 = null,
_ready_state: ReadyState = .connecting,
_buffered_amount_low_threshold: u32 = 0,
_binary_type: []const u8 = "arraybuffer",

pub const Options = struct {
    // Alphabetical: a dictionary's members are read in that order.
    id: ?u32 = null,
    maxPacketLifeTime: ?u32 = null,
    maxRetransmits: ?u32 = null,
    negotiated: bool = false,
    ordered: bool = true,
    protocol: ?lp.String.Global = null,
};

pub fn init(exec: *Execution, label: []const u8, opts: ?Options) !*RTCDataChannel {
    const o = opts orelse Options{};
    const allocator = exec._factory._arena;
    return exec._factory.eventTarget(RTCDataChannel{
        ._proto = undefined,
        ._label = try allocator.dupe(u8, label),
        ._protocol = if (o.protocol) |p| try allocator.dupe(u8, p.str.str()) else "",
        ._ordered = o.ordered,
        ._max_packet_life_time = o.maxPacketLifeTime,
        ._max_retransmits = o.maxRetransmits,
        ._negotiated = o.negotiated,
        // Chrome leaves `id` null until the channel is negotiated, unless the
        // page picked one itself.
        ._id = if (o.negotiated) o.id else null,
    });
}

pub fn asEventTarget(self: *RTCDataChannel) *EventTarget {
    return self._proto;
}

pub fn getLabel(self: *const RTCDataChannel) []const u8 {
    return self._label;
}

pub fn getOrdered(self: *const RTCDataChannel) bool {
    return self._ordered;
}

pub fn getMaxPacketLifeTime(self: *const RTCDataChannel) ?u32 {
    return self._max_packet_life_time;
}

pub fn getMaxRetransmits(self: *const RTCDataChannel) ?u32 {
    return self._max_retransmits;
}

pub fn getProtocol(self: *const RTCDataChannel) []const u8 {
    return self._protocol;
}

pub fn getNegotiated(self: *const RTCDataChannel) bool {
    return self._negotiated;
}

pub fn getId(self: *const RTCDataChannel) ?u32 {
    return self._id;
}

pub fn getReadyState(self: *const RTCDataChannel) []const u8 {
    return self._ready_state.toString();
}

// Nothing is ever queued, because send() never succeeds.
pub fn getBufferedAmount(_: *const RTCDataChannel) u32 {
    return 0;
}

pub fn getBufferedAmountLowThreshold(self: *const RTCDataChannel) u32 {
    return self._buffered_amount_low_threshold;
}

pub fn setBufferedAmountLowThreshold(self: *RTCDataChannel, value: u32) void {
    self._buffered_amount_low_threshold = value;
}

pub fn getBinaryType(self: *const RTCDataChannel) []const u8 {
    return self._binary_type;
}

pub fn setBinaryType(self: *RTCDataChannel, value: []const u8) !void {
    if (std.mem.eql(u8, value, "blob")) {
        self._binary_type = "blob";
    } else if (std.mem.eql(u8, value, "arraybuffer")) {
        self._binary_type = "arraybuffer";
    } else {
        return error.TypeError;
    }
}

// The pre-spec alias Chrome still carries: true unless the channel asked for
// partial reliability.
pub fn getReliable(self: *const RTCDataChannel) bool {
    return self._max_packet_life_time == null and self._max_retransmits == null;
}

// A channel that never opened cannot send, and that is the error Chrome gives.
pub fn send(self: *RTCDataChannel, _: js.Value) !void {
    if (self._ready_state != .open) {
        return error.InvalidStateError;
    }
}

pub fn close(self: *RTCDataChannel, exec: *Execution) !void {
    if (self._ready_state == .closing or self._ready_state == .closed) {
        return;
    }
    self._ready_state = .closing;

    const task = try exec._factory.create(CloseTask{ .channel = self, .exec = exec });
    try exec.js.scheduler.add(task, CloseTask.run, 0, .{
        .name = "RTCDataChannel.close",
        .finalizer = CloseTask.cancelled,
    });
}

// Chrome flips "closing" to "closed" and fires `close` from a later task
// rather than inside close().
const CloseTask = struct {
    channel: *RTCDataChannel,
    exec: *Execution,

    fn cancelled(ctx: *anyopaque) void {
        const self: *CloseTask = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *CloseTask = @ptrCast(@alignCast(ctx));
        defer self.exec._factory.destroy(self);

        const channel = self.channel;
        channel._ready_state = .closed;

        const target = channel.asEventTarget();
        if (!self.exec.hasDirectListeners(target, "close", null)) {
            return null;
        }
        const event = try Event.initTrusted(comptime .wrap("close"), .{}, self.exec.page);
        try self.exec.dispatch(target, event, null, .{ .context = "RTCDataChannel.close" });
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCDataChannel);

    pub const Meta = struct {
        pub const name = "RTCDataChannel";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is what Object.getOwnPropertyNames() reports; this is Chrome's (measured).
    pub const label = bridge.accessor(RTCDataChannel.getLabel, null, .{});
    pub const ordered = bridge.accessor(RTCDataChannel.getOrdered, null, .{});
    pub const maxPacketLifeTime = bridge.accessor(RTCDataChannel.getMaxPacketLifeTime, null, .{});
    pub const maxRetransmits = bridge.accessor(RTCDataChannel.getMaxRetransmits, null, .{});
    pub const protocol = bridge.accessor(RTCDataChannel.getProtocol, null, .{});
    pub const negotiated = bridge.accessor(RTCDataChannel.getNegotiated, null, .{});
    pub const id = bridge.accessor(RTCDataChannel.getId, null, .{});
    pub const readyState = bridge.accessor(RTCDataChannel.getReadyState, null, .{});
    pub const bufferedAmount = bridge.accessor(RTCDataChannel.getBufferedAmount, null, .{});
    pub const bufferedAmountLowThreshold = bridge.accessor(RTCDataChannel.getBufferedAmountLowThreshold, RTCDataChannel.setBufferedAmountLowThreshold, .{});
    pub const onopen = bridge.accessor(handlerProperty(RTCDataChannel, .onopen).get, handlerProperty(RTCDataChannel, .onopen).set, .{});
    pub const onbufferedamountlow = bridge.accessor(handlerProperty(RTCDataChannel, .onbufferedamountlow).get, handlerProperty(RTCDataChannel, .onbufferedamountlow).set, .{});
    pub const onerror = bridge.accessor(handlerProperty(RTCDataChannel, .onerror).get, handlerProperty(RTCDataChannel, .onerror).set, .{});
    pub const onclosing = bridge.accessor(handlerProperty(RTCDataChannel, .onclosing).get, handlerProperty(RTCDataChannel, .onclosing).set, .{});
    pub const onclose = bridge.accessor(handlerProperty(RTCDataChannel, .onclose).get, handlerProperty(RTCDataChannel, .onclose).set, .{});
    pub const onmessage = bridge.accessor(handlerProperty(RTCDataChannel, .onmessage).get, handlerProperty(RTCDataChannel, .onmessage).set, .{});
    pub const binaryType = bridge.accessor(RTCDataChannel.getBinaryType, RTCDataChannel.setBinaryType, .{});
    pub const reliable = bridge.accessor(RTCDataChannel.getReliable, null, .{});
    pub const close = bridge.function(RTCDataChannel.close, .{});
    pub const send = bridge.function(RTCDataChannel.send, .{});
};
