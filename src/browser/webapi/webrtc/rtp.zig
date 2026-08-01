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

// RTCRtpSender and RTCRtpReceiver. Only the static getCapabilities() is
// reachable: nothing in this engine ever produces an instance, because that
// needs a track, and there is no media stack. The instance members are still
// declared so the prototypes enumerate the way Chrome's do — a missing
// prototype method is exactly the kind of thing a fingerprinting script
// compares against its own table.
//
// The capability tables are Chrome's, read from the same browser run that
// produced the SDP in chrome_sdp.zig. Sender and receiver report the same audio
// table but *different* video tables (the receiver decodes profiles the encoder
// won't emit), so both are carried rather than one being aliased to the other.

const std = @import("std");

const js = @import("../../js/js.zig");
const chrome_sdp = @import("chrome_sdp.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ RTCRtpSender, RTCRtpReceiver };
}

// Chrome answers null for anything that isn't "audio" or "video" (measured
// with "bogus"), rather than throwing.
fn capabilitiesFor(kind: []const u8, audio: chrome_sdp.Capabilities, video: chrome_sdp.Capabilities, exec: *const Execution) !?js.Object {
    const caps = if (std.mem.eql(u8, kind, "audio"))
        audio
    else if (std.mem.eql(u8, kind, "video"))
        video
    else
        return null;

    const local = exec.js.local.?;

    // Chrome's key order within a codec is alphabetical — channels, clockRate,
    // mimeType, sdpFmtpLine — and a key it has no value for is *absent*, not
    // null. `'sdpFmtpLine' in codec` tells the two apart, so the object is
    // assembled key by key instead of returned as a Zig struct.
    const codecs = local.newArray(@intCast(caps.codecs.len));
    for (caps.codecs, 0..) |codec, i| {
        const obj = local.newObject();
        if (codec.channels) |channels| {
            try set(obj, "channels", channels);
        }
        try set(obj, "clockRate", codec.clock_rate);
        try set(obj, "mimeType", codec.mime_type);
        if (codec.sdp_fmtp_line) |fmtp| {
            try set(obj, "sdpFmtpLine", fmtp);
        }
        if (try codecs.set(@intCast(i), obj, .{}) == false) {
            return error.CreateObjectFailure;
        }
    }

    const extensions = local.newArray(@intCast(caps.header_extensions.len));
    for (caps.header_extensions, 0..) |extension, i| {
        const obj = local.newObject();
        try set(obj, "direction", extension.direction);
        try set(obj, "uri", extension.uri);
        if (try extensions.set(@intCast(i), obj, .{}) == false) {
            return error.CreateObjectFailure;
        }
    }

    const result = local.newObject();
    try set(result, "codecs", codecs);
    try set(result, "headerExtensions", extensions);
    return result;
}

fn set(target: js.Object, comptime name: []const u8, value: anytype) !void {
    if (try target.set(name, value, .{}) == false) {
        return error.CreateObjectFailure;
    }
}

pub const RTCRtpSender = struct {
    pub fn getCapabilities(kind: []const u8, exec: *const Execution) !?js.Object {
        return capabilitiesFor(kind, chrome_sdp.sender_audio, chrome_sdp.sender_video, exec);
    }

    // Unreachable in practice — see the file header — but present so the
    // prototype matches.
    pub fn getTrack(_: *const RTCRtpSender) ?js.Value {
        return null;
    }

    pub fn getTransport(_: *const RTCRtpSender) ?js.Value {
        return null;
    }

    pub fn getRtcpTransport(_: *const RTCRtpSender) ?js.Value {
        return null;
    }

    pub fn getDtmf(_: *const RTCRtpSender) ?js.Value {
        return null;
    }

    pub fn getTransform(_: *const RTCRtpSender) ?js.Value {
        return null;
    }

    pub fn setTransform(_: *RTCRtpSender, _: ?js.Value) void {}

    pub fn createEncodedStreams(_: *RTCRtpSender) !void {
        return error.InvalidStateError;
    }

    pub fn getParameters(_: *const RTCRtpSender) Parameters {
        return .{};
    }

    pub fn getStats(_: *const RTCRtpSender, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    pub fn replaceTrack(_: *RTCRtpSender, _: ?js.Value, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    pub fn setParameters(_: *RTCRtpSender, _: ?js.Value, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    pub fn setStreams(_: *RTCRtpSender) void {}

    const Parameters = struct {
        transactionId: []const u8 = "",
    };

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCRtpSender);

        pub const Meta = struct {
            pub const name = "RTCRtpSender";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const getCapabilities = bridge.function(RTCRtpSender.getCapabilities, .{ .static = true });

        pub const track = bridge.accessor(RTCRtpSender.getTrack, null, .{});
        pub const transport = bridge.accessor(RTCRtpSender.getTransport, null, .{});
        pub const rtcpTransport = bridge.accessor(RTCRtpSender.getRtcpTransport, null, .{});
        pub const dtmf = bridge.accessor(RTCRtpSender.getDtmf, null, .{});
        pub const transform = bridge.accessor(RTCRtpSender.getTransform, RTCRtpSender.setTransform, .{});
        pub const createEncodedStreams = bridge.function(RTCRtpSender.createEncodedStreams, .{});
        pub const getParameters = bridge.function(RTCRtpSender.getParameters, .{});
        pub const getStats = bridge.function(RTCRtpSender.getStats, .{});
        pub const replaceTrack = bridge.function(RTCRtpSender.replaceTrack, .{});
        pub const setParameters = bridge.function(RTCRtpSender.setParameters, .{});
        pub const setStreams = bridge.function(RTCRtpSender.setStreams, .{});
    };
};

pub const RTCRtpReceiver = struct {
    pub fn getCapabilities(kind: []const u8, exec: *const Execution) !?js.Object {
        return capabilitiesFor(kind, chrome_sdp.receiver_audio, chrome_sdp.receiver_video, exec);
    }

    pub fn getTrack(_: *const RTCRtpReceiver) ?js.Value {
        return null;
    }

    pub fn getTransport(_: *const RTCRtpReceiver) ?js.Value {
        return null;
    }

    pub fn getRtcpTransport(_: *const RTCRtpReceiver) ?js.Value {
        return null;
    }

    pub fn getPlayoutDelayHint(_: *const RTCRtpReceiver) ?f64 {
        return null;
    }

    pub fn setPlayoutDelayHint(_: *RTCRtpReceiver, _: ?f64) void {}

    pub fn getJitterBufferTarget(_: *const RTCRtpReceiver) ?f64 {
        return null;
    }

    pub fn setJitterBufferTarget(_: *RTCRtpReceiver, _: ?f64) void {}

    pub fn getTransform(_: *const RTCRtpReceiver) ?js.Value {
        return null;
    }

    pub fn setTransform(_: *RTCRtpReceiver, _: ?js.Value) void {}

    pub fn createEncodedStreams(_: *RTCRtpReceiver) !void {
        return error.InvalidStateError;
    }

    pub fn getContributingSources(_: *const RTCRtpReceiver) []const js.Value {
        return &.{};
    }

    pub fn getSynchronizationSources(_: *const RTCRtpReceiver) []const js.Value {
        return &.{};
    }

    pub fn getParameters(_: *const RTCRtpReceiver) Parameters {
        return .{};
    }

    pub fn getStats(_: *const RTCRtpReceiver, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    const Parameters = struct {
        headerExtensions: []const js.Value = &.{},
    };

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCRtpReceiver);

        pub const Meta = struct {
            pub const name = "RTCRtpReceiver";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const getCapabilities = bridge.function(RTCRtpReceiver.getCapabilities, .{ .static = true });

        pub const track = bridge.accessor(RTCRtpReceiver.getTrack, null, .{});
        pub const transport = bridge.accessor(RTCRtpReceiver.getTransport, null, .{});
        pub const rtcpTransport = bridge.accessor(RTCRtpReceiver.getRtcpTransport, null, .{});
        pub const playoutDelayHint = bridge.accessor(RTCRtpReceiver.getPlayoutDelayHint, RTCRtpReceiver.setPlayoutDelayHint, .{});
        pub const jitterBufferTarget = bridge.accessor(RTCRtpReceiver.getJitterBufferTarget, RTCRtpReceiver.setJitterBufferTarget, .{});
        pub const transform = bridge.accessor(RTCRtpReceiver.getTransform, RTCRtpReceiver.setTransform, .{});
        pub const createEncodedStreams = bridge.function(RTCRtpReceiver.createEncodedStreams, .{});
        pub const getContributingSources = bridge.function(RTCRtpReceiver.getContributingSources, .{});
        pub const getSynchronizationSources = bridge.function(RTCRtpReceiver.getSynchronizationSources, .{});
        pub const getParameters = bridge.function(RTCRtpReceiver.getParameters, .{});
        pub const getStats = bridge.function(RTCRtpReceiver.getStats, .{});
    };
};
