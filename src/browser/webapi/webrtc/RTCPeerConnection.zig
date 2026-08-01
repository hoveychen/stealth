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

// window.RTCPeerConnection. There is no media stack behind it and there will
// not be one; what this reproduces is the *offer*, because the offer is what
// fingerprinting reads.
//
// CreepJS's "sdp capabilities" row is the clearest case. It builds a
// connection, adds a data channel, asks for an offer with audio and video, then
// parses the codecs, clock rates, fmtp lines and rtcp-fb lines back out of the
// SDP text and hashes them. Absent RTCPeerConnection that row reads "blocked",
// which is a headless tell; a hand-written approximation of the SDP would be
// worse, because it would hash to a value no Chrome has ever produced. So the
// section text is Chrome's own, captured by tools/fingerprint/dump-webrtc.mjs
// into chrome_sdp.zig, and reassembled here around the parts that genuinely
// vary per connection: the session id, the ICE ufrag and password, the DTLS
// fingerprint, and which sections were asked for.
//
// Which sections appear is not cosmetic — it is measured behaviour, and the
// three cases differ:
//
//   createOffer() with nothing added      -> preamble only, no m= line at all
//   createDataChannel() then createOffer() -> m=application, BUNDLE 0
//   the CreepJS shape                      -> m=audio, m=video, m=application
//
// ICE gathering. One host candidate is produced, carrying an mDNS `.local`
// name rather than an address. That is not an evasion, it is what Chrome does:
// it hides the local IP behind a per-session UUID by default, so a `.local`
// candidate is the ordinary observation and a *missing* candidate is the odd
// one. What this engine cannot do is reach a STUN server, so no server-reflexive
// candidate ever appears — which is the same thing a Chrome behind a firewall
// that blocks UDP shows. Gathering therefore completes only when the page
// configured no ICE servers; with servers configured it stays "gathering", as
// the measured Chrome does when they cannot be reached.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const RTCDataChannel = @import("RTCDataChannel.zig");
const RTCIceCandidate = @import("RTCIceCandidate.zig");
const RTCPeerConnectionIceEvent = @import("RTCPeerConnectionIceEvent.zig");
const RTCSessionDescription = @import("RTCSessionDescription.zig");
const RTCStatsReport = @import("RTCStatsReport.zig");
const chrome_sdp = @import("chrome_sdp.zig");

const Allocator = std.mem.Allocator;
const Execution = js.Execution;

const RTCPeerConnection = @This();

pub const Proto = EventTarget;

// The priority every Chrome host candidate over UDP carries; it is derived from
// fixed type/local preferences, so it is the same number on every machine.
const HOST_UDP_PRIORITY = 2113937151;

// Chrome starts gathering from a task after setLocalDescription rather than
// inside it — `iceGatheringState` still reads "new" on the next line (measured).
const GATHER_DELAY_MS: u32 = 10;

_proto: *EventTarget,

// Per-connection identity, drawn once so that every section of the offer
// agrees with every other one.
_session_id: u64,
_ice_ufrag: [4]u8,
_ice_pwd: [24]u8,
_fingerprint: [95]u8,

_config: Config,

// Which m= sections the next offer carries. These only ever turn on: a
// transceiver Chrome has created for an earlier offer is still there for the
// next one.
_want_audio: bool = false,
_want_video: bool = false,
_want_application: bool = false,

_signaling_state: SignalingState = .stable,
_ice_gathering_state: IceGatheringState = .new,
_closed: bool = false,

_local_description: ?*RTCSessionDescription = null,
_gathering_started: bool = false,

_on_negotiationneeded: ?js.Function.Global = null,
_on_icecandidate: ?js.Function.Global = null,
_on_signalingstatechange: ?js.Function.Global = null,
_on_iceconnectionstatechange: ?js.Function.Global = null,
_on_connectionstatechange: ?js.Function.Global = null,
_on_icegatheringstatechange: ?js.Function.Global = null,
_on_icecandidateerror: ?js.Function.Global = null,
_on_track: ?js.Function.Global = null,
_on_datachannel: ?js.Function.Global = null,
_on_addstream: ?js.Function.Global = null,
_on_removestream: ?js.Function.Global = null,

const SignalingState = enum {
    stable,
    have_local_offer,
    closed,

    fn toString(self: SignalingState) []const u8 {
        return switch (self) {
            .stable => "stable",
            .have_local_offer => "have-local-offer",
            .closed => "closed",
        };
    }
};

const IceGatheringState = enum {
    new,
    gathering,
    complete,

    fn toString(self: IceGatheringState) []const u8 {
        return @tagName(self);
    }
};

// getConfiguration() reports every key Chrome reports, in Chrome's order
// (alphabetical), whether or not the page set it.
const Config = struct {
    always_negotiate_data_channels: bool = false,
    bundle_policy: []const u8 = "balanced",
    encoded_insertable_streams: bool = false,
    ice_candidate_pool_size: u32 = 0,
    ice_servers: []const IceServer = &.{},
    ice_transport_policy: []const u8 = "all",
    rtcp_mux_policy: []const u8 = "require",
};

const IceServer = struct {
    credential: []const u8,
    urls: []const []const u8,
    username: []const u8,
};

pub const ConfigInit = struct {
    bundlePolicy: ?lp.String.Global = null,
    iceCandidatePoolSize: ?u32 = null,
    iceServers: ?[]const IceServerInit = null,
    iceTransportPolicy: ?lp.String.Global = null,
    rtcpMuxPolicy: ?lp.String.Global = null,
};

pub const IceServerInit = struct {
    // `urls` is a string or a sequence of strings, so it arrives untyped.
    urls: ?js.Value = null,
    username: ?lp.String.Global = null,
    credential: ?lp.String.Global = null,
};

// `config` is optional so the reported arity is 0, matching Chrome's
// RTCPeerConnection.length (measured).
pub fn constructor(config: ?ConfigInit, exec: *Execution) !*RTCPeerConnection {
    const allocator = exec._factory._arena;

    var self = RTCPeerConnection{
        ._proto = undefined,
        ._session_id = randomSessionId(),
        ._ice_ufrag = randomIceString(4),
        ._ice_pwd = randomIceString(24),
        ._fingerprint = randomFingerprint(),
        ._config = .{},
    };
    if (config) |c| {
        try self.applyConfig(allocator, c);
    }
    return exec._factory.eventTarget(self);
}

fn applyConfig(self: *RTCPeerConnection, allocator: Allocator, config: ConfigInit) !void {
    if (config.iceCandidatePoolSize) |size| {
        self._config.ice_candidate_pool_size = size;
    }
    if (config.bundlePolicy) |v| {
        self._config.bundle_policy = try allocator.dupe(u8, v.str.str());
    }
    if (config.iceTransportPolicy) |v| {
        self._config.ice_transport_policy = try allocator.dupe(u8, v.str.str());
    }
    if (config.rtcpMuxPolicy) |v| {
        self._config.rtcp_mux_policy = try allocator.dupe(u8, v.str.str());
    }

    const servers = config.iceServers orelse return;
    const parsed = try allocator.alloc(IceServer, servers.len);
    for (servers, parsed) |server, *slot| {
        slot.* = .{
            .credential = if (server.credential) |c| try allocator.dupe(u8, c.str.str()) else "",
            .urls = try urlList(allocator, server.urls),
            .username = if (server.username) |u| try allocator.dupe(u8, u.str.str()) else "",
        };
    }
    self._config.ice_servers = parsed;
}

// getConfiguration() always reports `urls` as an array, even when the page
// passed a bare string (measured).
fn urlList(allocator: Allocator, value: ?js.Value) ![]const []const u8 {
    const urls = value orelse return &.{};
    if (urls.isNullOrUndefined()) {
        return &.{};
    }

    if (urls.isArray()) {
        const array = urls.toArray();
        const len = array.len();
        const out = try allocator.alloc([]const u8, len);
        for (out, 0..) |*slot, i| {
            const item = try array.get(@intCast(i));
            slot.* = try allocator.dupe(u8, try item.toStringSmart());
        }
        return out;
    }

    const out = try allocator.alloc([]const u8, 1);
    out[0] = try allocator.dupe(u8, try urls.toStringSmart());
    return out;
}

pub fn asEventTarget(self: *RTCPeerConnection) *EventTarget {
    return self._proto;
}

// == the offer ==

pub const OfferOptions = struct {
    offerToReceiveAudio: ?js.Value = null,
    offerToReceiveVideo: ?js.Value = null,
    iceRestart: ?js.Value = null,
    voiceActivityDetection: ?js.Value = null,
};

// Chrome's key order here is sdp then type — the reverse of
// RTCSessionDescription's toJSON, and measured rather than assumed.
const SessionDescriptionInit = struct {
    sdp: []const u8,
    type: []const u8,
};

pub fn createOffer(self: *RTCPeerConnection, options: ?OfferOptions, exec: *Execution) !js.Promise {
    if (self._closed) {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    if (options) |opts| {
        if (truthy(opts.offerToReceiveAudio)) self._want_audio = true;
        if (truthy(opts.offerToReceiveVideo)) self._want_video = true;
    }

    const sdp = try self.buildSdp(exec._factory._arena, null);
    return exec.js.local.?.resolvePromise(SessionDescriptionInit{ .sdp = sdp, .type = "offer" });
}

fn truthy(value: ?js.Value) bool {
    const v = value orelse return false;
    return v.toBool();
}

// `description` is optional: calling it bare makes Chrome generate the offer
// implicitly (measured — localDescription.type comes back "offer").
pub fn setLocalDescription(self: *RTCPeerConnection, description: ?RTCSessionDescription.Init, exec: *Execution) !js.Promise {
    if (self._closed) {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    const allocator = exec._factory._arena;
    const sdp = blk: {
        if (description) |d| {
            if (d.sdp) |s| {
                if (s.str.str().len > 0) break :blk try allocator.dupe(u8, s.str.str());
            }
        }
        break :blk try self.buildSdp(allocator, null);
    };

    self._local_description = try exec._factory.create(RTCSessionDescription{
        ._type = .wrap("offer"),
        ._sdp = try lp.String.init(allocator, sdp, .{}),
    });
    self._signaling_state = .have_local_offer;

    if (self._gathering_started == false) {
        self._gathering_started = true;
        const task = try exec._factory.create(GatherTask{ .connection = self, .exec = exec });
        try exec.js.scheduler.add(task, GatherTask.run, GATHER_DELAY_MS, .{
            .name = "RTCPeerConnection.gather",
            .low_priority = false,
            .finalizer = GatherTask.cancelled,
        });
    }

    return exec.js.local.?.resolvePromise({});
}

// Assembles the offer. `candidate`, when given, is spliced into the first
// section right after its c=/a=rtcp: header, which is where Chrome puts the
// lines it learns while gathering (measured).
fn buildSdp(self: *const RTCPeerConnection, allocator: Allocator, candidate: ?[]const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    const w = &out.writer;

    try w.print("v=0\r\no=- {d} 2 IN IP4 127.0.0.1\r\n", .{self._session_id});
    try w.writeAll(chrome_sdp.preamble_head);

    // BUNDLE lists the mids in section order, and is left out when there are
    // no sections at all.
    const audio_mid: ?u8 = if (self._want_audio) 0 else null;
    const video_mid: ?u8 = if (self._want_video) (if (audio_mid) |m| m + 1 else 0) else null;
    const application_mid: ?u8 = if (self._want_application) blk: {
        if (video_mid) |m| break :blk m + 1;
        if (audio_mid) |m| break :blk m + 1;
        break :blk 0;
    } else null;

    if (audio_mid != null or video_mid != null or application_mid != null) {
        try w.writeAll("a=group:BUNDLE");
        for ([_]?u8{ audio_mid, video_mid, application_mid }) |mid| {
            if (mid) |m| try w.print(" {d}", .{m});
        }
        try w.writeAll("\r\n");
    }
    try w.writeAll(chrome_sdp.preamble_tail);

    var first = true;
    if (audio_mid) |mid| {
        try self.writeSection(w, chrome_sdp.audio_head, chrome_sdp.audio_tail, mid, if (first) candidate else null);
        first = false;
    }
    if (video_mid) |mid| {
        try self.writeSection(w, chrome_sdp.video_head, chrome_sdp.video_tail, mid, if (first) candidate else null);
        first = false;
    }
    if (application_mid) |mid| {
        try self.writeSection(w, chrome_sdp.application_head, chrome_sdp.application_tail, mid, if (first) candidate else null);
        first = false;
    }

    return out.written();
}

fn writeSection(
    self: *const RTCPeerConnection,
    w: *std.Io.Writer,
    head: []const u8,
    tail: []const u8,
    mid: u8,
    candidate: ?[]const u8,
) !void {
    try w.writeAll(head);
    if (candidate) |line| {
        try w.print("a={s}\r\n", .{line});
    }
    try w.print("a=ice-ufrag:{s}\r\na=ice-pwd:{s}\r\na=ice-options:trickle\r\n", .{ &self._ice_ufrag, &self._ice_pwd });
    try w.print("a=fingerprint:sha-256 {s}\r\na=setup:actpass\r\na=mid:{d}\r\n", .{ &self._fingerprint, mid });
    try w.writeAll(tail);
}

// == ICE gathering ==

// Produces the one host candidate, rewrites localDescription to include it, and
// then either completes gathering or stalls in "gathering" — see the file
// header for why the two cases differ.
const GatherTask = struct {
    connection: *RTCPeerConnection,
    exec: *Execution,

    fn cancelled(ctx: *anyopaque) void {
        const self: *GatherTask = @ptrCast(@alignCast(ctx));
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *GatherTask = @ptrCast(@alignCast(ctx));
        defer self.exec._factory.destroy(self);

        const connection = self.connection;
        if (connection._closed) {
            return null;
        }

        const exec = self.exec;
        const allocator = exec._factory._arena;

        try connection.setGatheringState(.gathering, exec);

        var mdns: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&mdns);

        // The event's line carries the ufrag; the copy spliced into the SDP does
        // not (measured — the two differ by exactly that token).
        const sdp_line = try std.fmt.allocPrint(
            allocator,
            "candidate:{d} 1 udp {d} {s}.local {d} typ host generation 0 network-cost 999",
            .{ randomFoundation(), HOST_UDP_PRIORITY, &mdns, randomPort() },
        );
        const event_line = try std.fmt.allocPrint(
            allocator,
            "{s} ufrag {s} network-cost 999",
            .{ sdp_line[0 .. sdp_line.len - " network-cost 999".len], &connection._ice_ufrag },
        );

        // Chrome's localDescription grows the candidate lines as they arrive.
        const sdp = try connection.buildSdp(allocator, sdp_line);
        if (connection._local_description) |description| {
            description._sdp = try lp.String.init(allocator, sdp, .{});
        }

        const candidate = try RTCIceCandidate.init(exec, event_line, "0", 0, &connection._ice_ufrag);
        try connection.dispatchIceCandidate(candidate, exec);

        // With ICE servers configured there would still be a server-reflexive
        // candidate to wait for, and it never comes.
        //
        // The order on completion is measured: the state reaches "complete"
        // *before* the null-candidate event, not after.
        if (connection._config.ice_servers.len == 0) {
            try connection.setGatheringState(.complete, exec);
            try connection.dispatchIceCandidate(null, exec);
        }
        return null;
    }
};

fn dispatchIceCandidate(self: *RTCPeerConnection, candidate: ?*RTCIceCandidate, exec: *Execution) !void {
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "icecandidate", self._on_icecandidate)) {
        return;
    }
    const event = try RTCPeerConnectionIceEvent.initTrusted(
        comptime .wrap("icecandidate"),
        .{ .candidate = candidate },
        exec.page,
    );
    return exec.dispatch(target, event.asEvent(), self._on_icecandidate, .{ .context = "RTCPeerConnection.icecandidate" });
}

fn setGatheringState(self: *RTCPeerConnection, state: IceGatheringState, exec: *Execution) !void {
    if (self._ice_gathering_state == state) {
        return;
    }
    self._ice_gathering_state = state;

    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "icegatheringstatechange", self._on_icegatheringstatechange)) {
        return;
    }
    const event = try Event.initTrusted(.wrap("icegatheringstatechange"), .{}, exec.page);
    return exec.dispatch(target, event, self._on_icegatheringstatechange, .{ .context = "RTCPeerConnection.icegatheringstatechange" });
}

// == data channels ==

pub fn createDataChannel(self: *RTCPeerConnection, label: []const u8, options: ?RTCDataChannel.Options, exec: *Execution) !*RTCDataChannel {
    if (self._closed) {
        return error.InvalidStateError;
    }
    self._want_application = true;
    return RTCDataChannel.init(exec, label, options);
}

// == state ==

pub fn getLocalDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._local_description;
}

pub fn getCurrentLocalDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._local_description;
}

pub fn getPendingLocalDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._local_description;
}

// No answer ever arrives, so every remote-side accessor stays null — which is
// also what Chrome reports for a connection that only ever made an offer.
pub fn getRemoteDescription(_: *const RTCPeerConnection) ?*RTCSessionDescription {
    return null;
}

pub fn getCurrentRemoteDescription(_: *const RTCPeerConnection) ?*RTCSessionDescription {
    return null;
}

pub fn getPendingRemoteDescription(_: *const RTCPeerConnection) ?*RTCSessionDescription {
    return null;
}

pub fn getSignalingState(self: *const RTCPeerConnection) []const u8 {
    return self._signaling_state.toString();
}

pub fn getIceGatheringState(self: *const RTCPeerConnection) []const u8 {
    return self._ice_gathering_state.toString();
}

pub fn getIceConnectionState(self: *const RTCPeerConnection) []const u8 {
    return if (self._closed) "closed" else "new";
}

pub fn getConnectionState(self: *const RTCPeerConnection) []const u8 {
    return if (self._closed) "closed" else "new";
}

// Null until a remote description says whether the other end can trickle.
pub fn getCanTrickleIceCandidates(_: *const RTCPeerConnection) ?bool {
    return null;
}

// Non-null only once the SCTP transport exists, which needs both a data
// channel and a local description.
pub fn getSctp(_: *const RTCPeerConnection) ?js.Value {
    return null;
}

pub fn getConfiguration(self: *const RTCPeerConnection, exec: *const Execution) !js.Object {
    const local = exec.js.local.?;

    const servers = local.newArray(@intCast(self._config.ice_servers.len));
    for (self._config.ice_servers, 0..) |server, i| {
        const obj = local.newObject();
        try set(obj, "credential", server.credential);
        const urls = local.newArray(@intCast(server.urls.len));
        for (server.urls, 0..) |url, j| {
            if (try urls.set(@intCast(j), url, .{}) == false) return error.CreateObjectFailure;
        }
        try set(obj, "urls", urls);
        try set(obj, "username", server.username);
        if (try servers.set(@intCast(i), obj, .{}) == false) return error.CreateObjectFailure;
    }

    // Chrome's own key order, which is alphabetical.
    const out = local.newObject();
    try set(out, "alwaysNegotiateDataChannels", self._config.always_negotiate_data_channels);
    try set(out, "bundlePolicy", self._config.bundle_policy);
    try set(out, "certificates", local.newArray(0));
    try set(out, "encodedInsertableStreams", self._config.encoded_insertable_streams);
    try set(out, "iceCandidatePoolSize", self._config.ice_candidate_pool_size);
    try set(out, "iceServers", servers);
    try set(out, "iceTransportPolicy", self._config.ice_transport_policy);
    try set(out, "rtcpMuxPolicy", self._config.rtcp_mux_policy);
    return out;
}

fn set(target: js.Object, comptime name: []const u8, value: anytype) !void {
    if (try target.set(name, value, .{}) == false) {
        return error.CreateObjectFailure;
    }
}

pub fn setConfiguration(self: *RTCPeerConnection, config: ?ConfigInit, exec: *Execution) !void {
    if (self._closed) {
        return error.InvalidStateError;
    }
    if (config) |c| {
        try self.applyConfig(exec._factory._arena, c);
    }
}

pub fn close(self: *RTCPeerConnection) void {
    self._closed = true;
    self._signaling_state = .closed;
}

// == the rest of the prototype ==
//
// Everything below needs a peer, a track, or a transport, none of which exist
// here. They are declared because their absence from the prototype is itself
// what a fingerprinting script looks for; each one fails the way Chrome fails
// when it is called on a connection in this state.

pub fn createAnswer(_: *RTCPeerConnection, _: ?js.Value, exec: *Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
}

pub fn setRemoteDescription(_: *RTCPeerConnection, _: ?js.Value, exec: *Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
}

pub fn addIceCandidate(_: *RTCPeerConnection, _: ?js.Value, exec: *Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
}

pub fn addTrack(_: *RTCPeerConnection, _: ?js.Value, _: ?js.Value) !void {
    return error.InvalidStateError;
}

pub fn removeTrack(_: *RTCPeerConnection, _: ?js.Value) !void {
    return error.InvalidStateError;
}

pub fn addTransceiver(_: *RTCPeerConnection, _: ?js.Value, _: ?js.Value) !void {
    return error.InvalidStateError;
}

pub fn getSenders(_: *const RTCPeerConnection) []const js.Value {
    return &.{};
}

pub fn getReceivers(_: *const RTCPeerConnection) []const js.Value {
    return &.{};
}

pub fn getTransceivers(_: *const RTCPeerConnection) []const js.Value {
    return &.{};
}

pub fn getStreams(_: *const RTCPeerConnection) []const js.Value {
    return &.{};
}

pub fn addStream(_: *RTCPeerConnection, _: ?js.Value) void {}

pub fn removeStream(_: *RTCPeerConnection, _: ?js.Value) void {}

pub fn createDTMFSender(_: *RTCPeerConnection, _: ?js.Value) !void {
    return error.InvalidStateError;
}

pub fn restartIce(_: *RTCPeerConnection) void {}

// getStats() resolves even on a closed connection (measured), so this does not
// check _closed.
pub fn getStats(_: *RTCPeerConnection, _: ?js.Value, exec: *Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(try RTCStatsReport.init(exec));
}

// == per-connection random values ==
//
// Chrome draws all of these per RTCPeerConnection. They are the only parts of
// the offer that differ between two connections in the same browser, so they
// are drawn the same way — the alphabets and widths are the ones visible in
// captured offers.

const ICE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn randomSessionId() u64 {
    var bytes: [8]u8 = undefined;
    lp.io.random(&bytes);
    // 63 bits: the o= line is always a positive 19-digit number.
    return (std.mem.readInt(u64, &bytes, .big) >> 1) | (1 << 62);
}

fn randomIceString(comptime len: usize) [len]u8 {
    var bytes: [len]u8 = undefined;
    lp.io.random(&bytes);
    var out: [len]u8 = undefined;
    for (bytes, &out) |byte, *slot| {
        slot.* = ICE_ALPHABET[byte & 0x3f];
    }
    return out;
}

// 32 bytes as upper-case hex pairs joined by colons: 95 characters.
fn randomFingerprint() [95]u8 {
    var bytes: [32]u8 = undefined;
    lp.io.random(&bytes);

    const hex = "0123456789ABCDEF";
    var out: [95]u8 = undefined;
    for (bytes, 0..) |byte, i| {
        const at = i * 3;
        out[at] = hex[byte >> 4];
        out[at + 1] = hex[byte & 0x0f];
        if (at + 2 < out.len) {
            out[at + 2] = ':';
        }
    }
    return out;
}

fn randomFoundation() u32 {
    var bytes: [4]u8 = undefined;
    lp.io.random(&bytes);
    return (std.mem.readInt(u32, &bytes, .big) >> 1) | 1;
}

// The ephemeral range host candidates are bound in.
fn randomPort() u16 {
    var bytes: [2]u8 = undefined;
    lp.io.random(&bytes);
    return 49152 + (std.mem.readInt(u16, &bytes, .big) % (65535 - 49152 + 1));
}

// == event handlers ==

fn Handler(comptime field: []const u8) type {
    return struct {
        fn get(self: *const RTCPeerConnection) ?js.Function.Global {
            return @field(self, field);
        }
        fn setter(self: *RTCPeerConnection, cb: ?js.Function) !void {
            @field(self, field) = if (cb) |c| try c.persistWithThis(self) else null;
        }
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCPeerConnection);

    pub const Meta = struct {
        pub const name = "RTCPeerConnection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // Chrome still ships the 2013-era prefixed name, and it is the *same*
        // function object: measured, webkitRTCPeerConnection === RTCPeerConnection
        // and webkitRTCPeerConnection.name === "RTCPeerConnection".
        pub const constructor_aliases = [_][]const u8{"webkitRTCPeerConnection"};
    };

    pub const constructor = bridge.constructor(RTCPeerConnection.constructor, .{});

    // Declaration order is what Object.getOwnPropertyNames() reports; this is Chrome's (measured).
    pub const localDescription = bridge.accessor(RTCPeerConnection.getLocalDescription, null, .{});
    pub const currentLocalDescription = bridge.accessor(RTCPeerConnection.getCurrentLocalDescription, null, .{});
    pub const pendingLocalDescription = bridge.accessor(RTCPeerConnection.getPendingLocalDescription, null, .{});
    pub const remoteDescription = bridge.accessor(RTCPeerConnection.getRemoteDescription, null, .{});
    pub const currentRemoteDescription = bridge.accessor(RTCPeerConnection.getCurrentRemoteDescription, null, .{});
    pub const pendingRemoteDescription = bridge.accessor(RTCPeerConnection.getPendingRemoteDescription, null, .{});
    pub const signalingState = bridge.accessor(RTCPeerConnection.getSignalingState, null, .{});
    pub const iceGatheringState = bridge.accessor(RTCPeerConnection.getIceGatheringState, null, .{});
    pub const iceConnectionState = bridge.accessor(RTCPeerConnection.getIceConnectionState, null, .{});
    pub const connectionState = bridge.accessor(RTCPeerConnection.getConnectionState, null, .{});
    pub const canTrickleIceCandidates = bridge.accessor(RTCPeerConnection.getCanTrickleIceCandidates, null, .{});
    pub const onnegotiationneeded = bridge.accessor(Handler("_on_negotiationneeded").get, Handler("_on_negotiationneeded").setter, .{});
    pub const onicecandidate = bridge.accessor(Handler("_on_icecandidate").get, Handler("_on_icecandidate").setter, .{});
    pub const onsignalingstatechange = bridge.accessor(Handler("_on_signalingstatechange").get, Handler("_on_signalingstatechange").setter, .{});
    pub const oniceconnectionstatechange = bridge.accessor(Handler("_on_iceconnectionstatechange").get, Handler("_on_iceconnectionstatechange").setter, .{});
    pub const onconnectionstatechange = bridge.accessor(Handler("_on_connectionstatechange").get, Handler("_on_connectionstatechange").setter, .{});
    pub const onicegatheringstatechange = bridge.accessor(Handler("_on_icegatheringstatechange").get, Handler("_on_icegatheringstatechange").setter, .{});
    pub const onicecandidateerror = bridge.accessor(Handler("_on_icecandidateerror").get, Handler("_on_icecandidateerror").setter, .{});
    pub const ontrack = bridge.accessor(Handler("_on_track").get, Handler("_on_track").setter, .{});
    pub const sctp = bridge.accessor(RTCPeerConnection.getSctp, null, .{});
    pub const ondatachannel = bridge.accessor(Handler("_on_datachannel").get, Handler("_on_datachannel").setter, .{});
    pub const onaddstream = bridge.accessor(Handler("_on_addstream").get, Handler("_on_addstream").setter, .{});
    pub const onremovestream = bridge.accessor(Handler("_on_removestream").get, Handler("_on_removestream").setter, .{});
    pub const addIceCandidate = bridge.function(RTCPeerConnection.addIceCandidate, .{});
    pub const addStream = bridge.function(RTCPeerConnection.addStream, .{});
    pub const addTrack = bridge.function(RTCPeerConnection.addTrack, .{});
    pub const addTransceiver = bridge.function(RTCPeerConnection.addTransceiver, .{});
    pub const close = bridge.function(RTCPeerConnection.close, .{});
    pub const createAnswer = bridge.function(RTCPeerConnection.createAnswer, .{});
    pub const createDTMFSender = bridge.function(RTCPeerConnection.createDTMFSender, .{});
    pub const createDataChannel = bridge.function(RTCPeerConnection.createDataChannel, .{});
    pub const createOffer = bridge.function(RTCPeerConnection.createOffer, .{});
    pub const getConfiguration = bridge.function(RTCPeerConnection.getConfiguration, .{});
    pub const getLocalStreams = bridge.function(RTCPeerConnection.getStreams, .{});
    pub const getReceivers = bridge.function(RTCPeerConnection.getReceivers, .{});
    pub const getRemoteStreams = bridge.function(RTCPeerConnection.getStreams, .{});
    pub const getSenders = bridge.function(RTCPeerConnection.getSenders, .{});
    pub const getStats = bridge.function(RTCPeerConnection.getStats, .{});
    pub const getTransceivers = bridge.function(RTCPeerConnection.getTransceivers, .{});
    pub const removeStream = bridge.function(RTCPeerConnection.removeStream, .{});
    pub const removeTrack = bridge.function(RTCPeerConnection.removeTrack, .{});
    pub const restartIce = bridge.function(RTCPeerConnection.restartIce, .{});
    pub const setConfiguration = bridge.function(RTCPeerConnection.setConfiguration, .{});
    pub const setLocalDescription = bridge.function(RTCPeerConnection.setLocalDescription, .{});
    pub const setRemoteDescription = bridge.function(RTCPeerConnection.setRemoteDescription, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: RTCPeerConnection" {
    try testing.htmlRunner("webrtc.html", .{});
}
