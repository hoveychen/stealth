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

// RTCRtpSender, RTCRtpReceiver and RTCRtpTransceiver. Only the static
// getCapabilities() is reachable: nothing in this engine ever produces an
// instance, because that needs a track, and there is no media stack. The
// instance members are still declared so the prototypes enumerate the way
// Chrome's do — a missing prototype method is exactly the kind of thing a
// fingerprinting script compares against its own table.
//
// The capability tables are Chrome's, read from the same browser run that
// produced the SDP in chrome_sdp.zig. Sender and receiver report the same audio
// table but *different* video tables (the receiver decodes profiles the encoder
// won't emit), so both are carried rather than one being aliased to the other.

const std = @import("std");

/// Which of the two media kinds a sender, receiver or transceiver carries.
pub const Kind = enum { audio, video };

const js = @import("../../js/js.zig");
const chrome_sdp = @import("chrome_sdp.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ RTCRtpSender, RTCRtpReceiver, RTCRtpTransceiver };
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
    // The kind of the transceiver that owns it. Not observable yet -- `track`
    // is still null here where Chrome hands back a MediaStreamTrack -- but it
    // is also what keeps two senders from collapsing onto one JS object: a
    // struct with no fields at all is zero-sized, so every instance shares an
    // address and the identity map hands the second one the first's object.
    _kind: Kind = .audio,

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
        };

        pub const getCapabilities = bridge.function(RTCRtpSender.getCapabilities, .{ .static = true });

        // Declaration order is what Object.getOwnPropertyNames() reports; this is Chrome's (measured).
        pub const track = bridge.accessor(RTCRtpSender.getTrack, null, .{});
        pub const transport = bridge.accessor(RTCRtpSender.getTransport, null, .{});
        pub const rtcpTransport = bridge.accessor(RTCRtpSender.getRtcpTransport, null, .{});
        pub const dtmf = bridge.accessor(RTCRtpSender.getDtmf, null, .{});
        pub const createEncodedStreams = bridge.function(RTCRtpSender.createEncodedStreams, .{});
        pub const getParameters = bridge.function(RTCRtpSender.getParameters, .{});
        pub const getStats = bridge.function(RTCRtpSender.getStats, .{});
        pub const replaceTrack = bridge.function(RTCRtpSender.replaceTrack, .{ .arity = 1 });
        pub const setParameters = bridge.function(RTCRtpSender.setParameters, .{ .arity = 1 });
        pub const setStreams = bridge.function(RTCRtpSender.setStreams, .{});
        pub const transform = bridge.accessor(RTCRtpSender.getTransform, RTCRtpSender.setTransform, .{});
    };
};

pub const RTCRtpReceiver = struct {
    // See RTCRtpSender._kind.
    _kind: Kind = .audio,

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
        };

        pub const getCapabilities = bridge.function(RTCRtpReceiver.getCapabilities, .{ .static = true });

        // Declaration order is what Object.getOwnPropertyNames() reports; this is Chrome's (measured).
        pub const track = bridge.accessor(RTCRtpReceiver.getTrack, null, .{});
        pub const transport = bridge.accessor(RTCRtpReceiver.getTransport, null, .{});
        pub const rtcpTransport = bridge.accessor(RTCRtpReceiver.getRtcpTransport, null, .{});
        pub const playoutDelayHint = bridge.accessor(RTCRtpReceiver.getPlayoutDelayHint, RTCRtpReceiver.setPlayoutDelayHint, .{});
        pub const createEncodedStreams = bridge.function(RTCRtpReceiver.createEncodedStreams, .{});
        pub const getContributingSources = bridge.function(RTCRtpReceiver.getContributingSources, .{});
        pub const getParameters = bridge.function(RTCRtpReceiver.getParameters, .{});
        pub const getStats = bridge.function(RTCRtpReceiver.getStats, .{});
        pub const getSynchronizationSources = bridge.function(RTCRtpReceiver.getSynchronizationSources, .{});
        pub const jitterBufferTarget = bridge.accessor(RTCRtpReceiver.getJitterBufferTarget, RTCRtpReceiver.setJitterBufferTarget, .{});
        pub const transform = bridge.accessor(RTCRtpReceiver.getTransform, RTCRtpReceiver.setTransform, .{});
    };
};

// Handed out by pc.addTransceiver() and pc.getTransceivers(). Chrome roots it
// at Object, not EventTarget, and `new RTCRtpTransceiver()` throws "Illegal
// constructor" — which is what omitting a `constructor` decl gets us (measured,
// /tmp/webrtc-protochain-chrome.json).
//
// The state here is what the offer is built from: the kind decides which canned
// section goes in, the direction decides its `a=` line and whether the section
// carries a sender's msid and ssrc block, and the track id and ssrcs are the
// per-connection values in that block.
pub const RTCRtpTransceiver = struct {
    pub const Direction = enum {
        sendrecv,
        sendonly,
        recvonly,
        inactive,

        pub fn text(self: Direction) []const u8 {
            return @tagName(self);
        }

        /// Whether the section names a track and synchronisation sources.
        /// Measured on Chrome 151 for the two ends: `sendrecv` carries an
        /// `a=msid:` and an `a=ssrc:` block, `recvonly` carries neither
        /// (expr-sdp-offer.js and the addTransceiver probe beside it). The two
        /// in between were not measured; they are read the way their names do.
        pub fn sends(self: Direction) bool {
            return self == .sendrecv or self == .sendonly;
        }
    };

    _kind: Kind,
    _direction: Direction = .sendrecv,
    _sender: *RTCRtpSender,
    _receiver: *RTCRtpReceiver,
    // The msid line names a track by UUID even when there is no track on the
    // sender: `a=msid:- <uuid>`.
    _track_id: [36]u8,
    // One source for audio, two for video (the second is the FID retransmission
    // stream). chrome_sdp.audio_tx_ssrcs / video_tx_ssrcs say how many are used.
    _ssrcs: [2]u32,

    pub fn getMid(_: *const RTCRtpTransceiver) ?[]const u8 {
        // Assigned by setLocalDescription, not by createOffer: measured null on
        // a transceiver whose offer has already been built.
        return null;
    }

    pub fn getSender(self: *const RTCRtpTransceiver) *RTCRtpSender {
        return self._sender;
    }

    pub fn getReceiver(self: *const RTCRtpTransceiver) *RTCRtpReceiver {
        return self._receiver;
    }

    pub fn getStopped(_: *const RTCRtpTransceiver) bool {
        return false;
    }

    pub fn getDirection(self: *const RTCRtpTransceiver) []const u8 {
        return self._direction.text();
    }

    pub fn setDirection(self: *RTCRtpTransceiver, value: []const u8) void {
        inline for (@typeInfo(Direction).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, value)) {
                self._direction = @enumFromInt(field.value);
                return;
            }
        }
    }

    pub fn getCurrentDirection(_: *const RTCRtpTransceiver) ?[]const u8 {
        // Null until an answer has been applied (measured after createOffer).
        return null;
    }

    pub fn getHeaderExtensionsToNegotiate(_: *const RTCRtpTransceiver) []const js.Value {
        return &.{};
    }

    pub fn getNegotiatedHeaderExtensions(_: *const RTCRtpTransceiver) []const js.Value {
        return &.{};
    }

    pub fn setCodecPreferences(_: *RTCRtpTransceiver, _: []const js.Value) void {}

    pub fn setHeaderExtensionsToNegotiate(_: *RTCRtpTransceiver, _: []const js.Value) void {}

    pub fn stop(_: *RTCRtpTransceiver) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCRtpTransceiver);

        pub const Meta = struct {
            pub const name = "RTCRtpTransceiver";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const mid = bridge.accessor(RTCRtpTransceiver.getMid, null, .{});
        pub const sender = bridge.accessor(RTCRtpTransceiver.getSender, null, .{});
        pub const receiver = bridge.accessor(RTCRtpTransceiver.getReceiver, null, .{});
        pub const stopped = bridge.accessor(RTCRtpTransceiver.getStopped, null, .{});
        pub const direction = bridge.accessor(RTCRtpTransceiver.getDirection, RTCRtpTransceiver.setDirection, .{});
        pub const currentDirection = bridge.accessor(RTCRtpTransceiver.getCurrentDirection, null, .{});
        pub const getHeaderExtensionsToNegotiate = bridge.function(RTCRtpTransceiver.getHeaderExtensionsToNegotiate, .{});
        pub const getNegotiatedHeaderExtensions = bridge.function(RTCRtpTransceiver.getNegotiatedHeaderExtensions, .{});
        pub const setCodecPreferences = bridge.function(RTCRtpTransceiver.setCodecPreferences, .{ .arity = 1 });
        pub const setHeaderExtensionsToNegotiate = bridge.function(RTCRtpTransceiver.setHeaderExtensionsToNegotiate, .{ .arity = 1 });
        pub const stop = bridge.function(RTCRtpTransceiver.stop, .{});
    };
};
