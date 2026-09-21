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
// that blocks UDP shows. Gathering still ENDS either way: a page that waits for
// the null candidate, or for iceGatheringState to reach "complete", must be let
// go, and a Chrome whose STUN servers are unreachable finishes gathering with
// only the host candidate rather than waiting forever.

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
const rtp = @import("rtp.zig");
const RTCRtpTransceiver = rtp.RTCRtpTransceiver;
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

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
// The cname every `a=ssrc:` line repeats, drawn once per connection.
_cname: [16]u8,

_config: Config,

// Which m= sections the next offer carries. These only ever turn on: a
// transceiver Chrome has created for an earlier offer is still there for the
// next one.
_want_application: bool = false,
// The transceivers addTransceiver() made, in the order they were made. The
// legacy `offerToReceive*` options land here too: measured on Chrome 151,
// asking for audio beside an audio transceiver adds no second section, and
// asking for video adds a recvonly video transceiver -- which is the recvonly
// section the CreepJS shape has always carried.
_transceivers: std.ArrayList(*RTCRtpTransceiver) = .empty,

_signaling_state: SignalingState = .stable,
_ice_gathering_state: IceGatheringState = .new,
_closed: bool = false,

_local_description: ?*RTCSessionDescription = null,
_gathering_started: bool = false,

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
    // Alphabetical: a dictionary's members are read in that order.
    credential: ?lp.String.Global = null,
    // `urls` is a string or a sequence of strings, so it arrives untyped.
    urls: ?js.Value = null,
    username: ?lp.String.Global = null,
};

// `config` is optional so the reported arity is 0, matching Chrome's
// RTCPeerConnection.length (measured).
pub fn constructor(config: ?ConfigInit, exec: *Execution) !*RTCPeerConnection {
    const allocator = exec._factory._arena;

    var self = RTCPeerConnection{
        ._proto = undefined,
        ._session_id = randomSessionId(),
        ._ice_ufrag = randomIceString(4),
        ._cname = randomCname(),
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
    // Alphabetical: a dictionary's members are read in that order.
    iceRestart: ?js.Value = null,
    offerToReceiveAudio: ?js.Value = null,
    offerToReceiveVideo: ?js.Value = null,
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
        if (truthy(opts.offerToReceiveAudio)) try self.wantToReceive(.audio, exec);
        if (truthy(opts.offerToReceiveVideo)) try self.wantToReceive(.video, exec);
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
    // no sections at all. A section per transceiver, in the order they were
    // added, and then the data channel's.
    const sections = self._transceivers.items.len + @intFromBool(self._want_application);
    if (sections != 0) {
        try w.writeAll("a=group:BUNDLE");
        for (0..sections) |mid| {
            try w.print(" {d}", .{mid});
        }
        try w.writeAll("\r\n");
    }
    try w.writeAll(chrome_sdp.preamble_tail);

    var mid: u8 = 0;
    for (self._transceivers.items) |transceiver| {
        try self.writeMediaSection(w, transceiver, mid, if (mid == 0) candidate else null);
        mid += 1;
    }
    if (self._want_application) {
        try self.writeSection(
            w,
            chrome_sdp.application_head,
            chrome_sdp.application_tail,
            mid,
            if (mid == 0) candidate else null,
        );
    }

    return out.written();
}

/// A legacy `offerToReceive*` option. Measured on Chrome 151: it adds a
/// recvonly transceiver when there is no transceiver of that kind, and does
/// nothing at all when there is -- `addTransceiver('audio')` plus
/// `offerToReceiveAudio: 1` is one sendrecv audio section, not two.
fn wantToReceive(self: *RTCPeerConnection, kind: rtp.Kind, exec: *Execution) !void {
    if (self.transceiverOfKind(kind) != null) {
        return;
    }
    _ = try self.newTransceiver(kind, .recvonly, exec);
}

/// One transceiver's m= section. The canned halves differ by kind and by
/// whether the direction sends: a sending video section offers the sender's
/// shorter codec list, and carries the track and source blocks a receiving one
/// leaves out entirely.
fn writeMediaSection(
    self: *const RTCPeerConnection,
    w: *std.Io.Writer,
    transceiver: *const RTCRtpTransceiver,
    mid: u8,
    candidate: ?[]const u8,
) !void {
    const sends = transceiver._direction.sends();
    const audio = transceiver._kind == .audio;
    const head = if (audio)
        (if (sends) chrome_sdp.audio_tx_head else chrome_sdp.audio_head)
    else
        (if (sends) chrome_sdp.video_tx_head else chrome_sdp.video_head);
    const tail_head = if (audio)
        (if (sends) chrome_sdp.audio_tx_tail_head else chrome_sdp.audio_tail_head)
    else
        (if (sends) chrome_sdp.video_tx_tail_head else chrome_sdp.video_tail_head);
    const tail_body = if (audio)
        (if (sends) chrome_sdp.audio_tx_tail_body else chrome_sdp.audio_tail_body)
    else
        (if (sends) chrome_sdp.video_tx_tail_body else chrome_sdp.video_tail_body);

    try w.writeAll(head);
    if (candidate) |line| {
        try w.print("a={s}\r\n", .{line});
    }
    try w.print("a=ice-ufrag:{s}\r\na=ice-pwd:{s}\r\na=ice-options:trickle\r\n", .{ &self._ice_ufrag, &self._ice_pwd });
    try w.print("a=fingerprint:sha-256 {s}\r\na=setup:actpass\r\na=mid:{d}\r\n", .{ &self._fingerprint, mid });
    try w.writeAll(tail_head);
    try w.print("a={s}\r\n", .{transceiver._direction.text()});
    if (sends) {
        try w.print("a=msid:- {s}\r\n", .{&transceiver._track_id});
    }
    try w.writeAll(tail_body);
    if (!sends) {
        return;
    }

    const count: usize = if (audio) chrome_sdp.audio_tx_ssrcs else chrome_sdp.video_tx_ssrcs;
    const group = if (audio) chrome_sdp.audio_tx_fid_group else chrome_sdp.video_tx_fid_group;
    if (group and count == 2) {
        try w.print("a=ssrc-group:FID {d} {d}\r\n", .{ transceiver._ssrcs[0], transceiver._ssrcs[1] });
    }
    for (transceiver._ssrcs[0..count]) |ssrc| {
        try w.print("a=ssrc:{d} cname:{s}\r\n", .{ ssrc, &self._cname });
        try w.print("a=ssrc:{d} msid:- {s}\r\n", .{ ssrc, &transceiver._track_id });
    }
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
        // candidate to wait for, and it never comes -- no STUN binding request
        // is ever sent. Gathering still has to END: a page that waits for the
        // null candidate (or for gatheringState to reach "complete") otherwise
        // waits forever, which is both a hang and a tell. Chrome answers a
        // configured-but-unreachable STUN server the same way, by finishing
        // gathering with only the host candidate in hand.
        //
        // The order on completion is measured: the state reaches "complete"
        // *before* the null-candidate event, not after.
        try connection.setGatheringState(.complete, exec);
        try connection.dispatchIceCandidate(null, exec);
        return null;
    }
};

fn dispatchIceCandidate(self: *RTCPeerConnection, candidate: ?*RTCIceCandidate, exec: *Execution) !void {
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "icecandidate", null)) {
        return;
    }
    const event = try RTCPeerConnectionIceEvent.initTrusted(
        comptime .wrap("icecandidate"),
        .{ .candidate = candidate },
        exec.page,
    );
    return exec.dispatch(target, event.asEvent(), null, .{ .context = "RTCPeerConnection.icecandidate" });
}

fn setGatheringState(self: *RTCPeerConnection, state: IceGatheringState, exec: *Execution) !void {
    if (self._ice_gathering_state == state) {
        return;
    }
    self._ice_gathering_state = state;

    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "icegatheringstatechange", null)) {
        return;
    }
    const event = try Event.initTrusted(.wrap("icegatheringstatechange"), .{}, exec.page);
    return exec.dispatch(target, event, null, .{ .context = "RTCPeerConnection.icegatheringstatechange" });
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

/// Measured on Chrome 151: the default direction is `sendrecv`, `mid` and
/// `currentDirection` are null until an answer lands, the sender and receiver
/// are real RTCRtpSender/RTCRtpReceiver objects, and a second transceiver of a
/// kind gets a second m= section rather than being folded into the first.
pub fn addTransceiver(self: *RTCPeerConnection, args: []js.Value, exec: *Execution) !*RTCRtpTransceiver {
    if (args.len == 0) {
        return throwType(
            "Failed to execute 'addTransceiver' on 'RTCPeerConnection': 1 argument required, but only 0 present.",
            exec,
        );
    }
    const kind: rtp.Kind = blk: {
        if (args[0].isString()) |name| {
            var buf: [8]u8 = undefined;
            const text = name.toSliceWithBuf(&buf);
            if (std.mem.eql(u8, text, "audio")) break :blk .audio;
            if (std.mem.eql(u8, text, "video")) break :blk .video;
        }
        return throwType(
            "Failed to execute 'addTransceiver' on 'RTCPeerConnection': The argument provided as " ++
                "parameter 1 is not a valid MediaStreamTrack kind ('audio' or 'video').",
            exec,
        );
    };

    const transceiver = try self.newTransceiver(kind, .sendrecv, exec);
    if (args.len > 1 and args[1].isObject()) {
        const value = try args[1].toObject().get("direction");
        if (value.isString()) |direction| {
            var buf: [16]u8 = undefined;
            transceiver.setDirection(direction.toSliceWithBuf(&buf));
        }
    }
    return transceiver;
}

fn throwType(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.local.?.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn newTransceiver(
    self: *RTCPeerConnection,
    kind: rtp.Kind,
    direction: RTCRtpTransceiver.Direction,
    exec: *Execution,
) !*RTCRtpTransceiver {
    const transceiver = try exec._factory.create(RTCRtpTransceiver{
        ._kind = kind,
        ._direction = direction,
        ._sender = try exec._factory.create(rtp.RTCRtpSender{ ._kind = kind }),
        ._receiver = try exec._factory.create(rtp.RTCRtpReceiver{ ._kind = kind }),
        ._track_id = randomTrackId(),
        ._ssrcs = .{ randomSsrc(), randomSsrc() },
    });
    try self._transceivers.append(exec._factory._arena, transceiver);
    return transceiver;
}

/// The first transceiver of `kind`, which is what the legacy `offerToReceive*`
/// options look for before adding one.
fn transceiverOfKind(self: *const RTCPeerConnection, kind: rtp.Kind) ?*RTCRtpTransceiver {
    for (self._transceivers.items) |transceiver| {
        if (transceiver._kind == kind) return transceiver;
    }
    return null;
}

/// One per transceiver, and the same objects the transceivers hand out
/// (measured on Chrome 151: `getSenders()[0] === getTransceivers()[0].sender`).
pub fn getSenders(self: *const RTCPeerConnection, exec: *Execution) ![]const *rtp.RTCRtpSender {
    const out = try exec.call_arena.alloc(*rtp.RTCRtpSender, self._transceivers.items.len);
    for (self._transceivers.items, out) |transceiver, *slot| {
        slot.* = transceiver._sender;
    }
    return out;
}

pub fn getReceivers(self: *const RTCPeerConnection, exec: *Execution) ![]const *rtp.RTCRtpReceiver {
    const out = try exec.call_arena.alloc(*rtp.RTCRtpReceiver, self._transceivers.items.len);
    for (self._transceivers.items, out) |transceiver, *slot| {
        slot.* = transceiver._receiver;
    }
    return out;
}

pub fn getTransceivers(self: *const RTCPeerConnection) []const *RTCRtpTransceiver {
    return self._transceivers.items;
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

// The `cname` every ssrc line carries: 16 characters of the same alphabet as
// the ICE credentials, drawn once per connection.
fn randomCname() [16]u8 {
    return randomIceString(16);
}

// A synchronisation source is a non-zero 32-bit number.
fn randomSsrc() u32 {
    var bytes: [4]u8 = undefined;
    lp.io.random(&bytes);
    return std.mem.readInt(u32, &bytes, .big) | 1;
}

// The UUID an `a=msid:` line names the sender's track by, in the canonical
// 8-4-4-4-12 lower-case hex form. Version 4, variant 1, as Chrome's are.
fn randomTrackId() [36]u8 {
    var bytes: [16]u8 = undefined;
    lp.io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var at: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[at] = '-';
            at += 1;
        }
        out[at] = hex[byte >> 4];
        out[at + 1] = hex[byte & 0x0f];
        at += 2;
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
    pub const onnegotiationneeded = bridge.accessor(handlerProperty(RTCPeerConnection, .onnegotiationneeded).get, handlerProperty(RTCPeerConnection, .onnegotiationneeded).set, .{});
    pub const onicecandidate = bridge.accessor(handlerProperty(RTCPeerConnection, .onicecandidate).get, handlerProperty(RTCPeerConnection, .onicecandidate).set, .{});
    pub const onsignalingstatechange = bridge.accessor(handlerProperty(RTCPeerConnection, .onsignalingstatechange).get, handlerProperty(RTCPeerConnection, .onsignalingstatechange).set, .{});
    pub const oniceconnectionstatechange = bridge.accessor(handlerProperty(RTCPeerConnection, .oniceconnectionstatechange).get, handlerProperty(RTCPeerConnection, .oniceconnectionstatechange).set, .{});
    pub const onconnectionstatechange = bridge.accessor(handlerProperty(RTCPeerConnection, .onconnectionstatechange).get, handlerProperty(RTCPeerConnection, .onconnectionstatechange).set, .{});
    pub const onicegatheringstatechange = bridge.accessor(handlerProperty(RTCPeerConnection, .onicegatheringstatechange).get, handlerProperty(RTCPeerConnection, .onicegatheringstatechange).set, .{});
    pub const onicecandidateerror = bridge.accessor(handlerProperty(RTCPeerConnection, .onicecandidateerror).get, handlerProperty(RTCPeerConnection, .onicecandidateerror).set, .{});
    pub const ontrack = bridge.accessor(handlerProperty(RTCPeerConnection, .ontrack).get, handlerProperty(RTCPeerConnection, .ontrack).set, .{});
    pub const sctp = bridge.accessor(RTCPeerConnection.getSctp, null, .{});
    pub const ondatachannel = bridge.accessor(handlerProperty(RTCPeerConnection, .ondatachannel).get, handlerProperty(RTCPeerConnection, .ondatachannel).set, .{});
    pub const onaddstream = bridge.accessor(handlerProperty(RTCPeerConnection, .onaddstream).get, handlerProperty(RTCPeerConnection, .onaddstream).set, .{});
    pub const onremovestream = bridge.accessor(handlerProperty(RTCPeerConnection, .onremovestream).get, handlerProperty(RTCPeerConnection, .onremovestream).set, .{});
    pub const addIceCandidate = bridge.function(RTCPeerConnection.addIceCandidate, .{});
    pub const addStream = bridge.function(RTCPeerConnection.addStream, .{ .arity = 1 });
    pub const addTrack = bridge.function(RTCPeerConnection.addTrack, .{ .arity = 1 });
    pub const addTransceiver = bridge.function(RTCPeerConnection.addTransceiver, .{ .arity = 1 });
    pub const close = bridge.function(RTCPeerConnection.close, .{});
    pub const createAnswer = bridge.function(RTCPeerConnection.createAnswer, .{});
    pub const createDTMFSender = bridge.function(RTCPeerConnection.createDTMFSender, .{ .arity = 1 });
    pub const createDataChannel = bridge.function(RTCPeerConnection.createDataChannel, .{});
    pub const createOffer = bridge.function(RTCPeerConnection.createOffer, .{});
    pub const getConfiguration = bridge.function(RTCPeerConnection.getConfiguration, .{});
    pub const getLocalStreams = bridge.function(RTCPeerConnection.getStreams, .{});
    pub const getReceivers = bridge.function(RTCPeerConnection.getReceivers, .{});
    pub const getRemoteStreams = bridge.function(RTCPeerConnection.getStreams, .{});
    pub const getSenders = bridge.function(RTCPeerConnection.getSenders, .{});
    pub const getStats = bridge.function(RTCPeerConnection.getStats, .{});
    pub const getTransceivers = bridge.function(RTCPeerConnection.getTransceivers, .{});
    pub const removeStream = bridge.function(RTCPeerConnection.removeStream, .{ .arity = 1 });
    pub const removeTrack = bridge.function(RTCPeerConnection.removeTrack, .{ .arity = 1 });
    pub const restartIce = bridge.function(RTCPeerConnection.restartIce, .{});
    pub const setConfiguration = bridge.function(RTCPeerConnection.setConfiguration, .{});
    pub const setLocalDescription = bridge.function(RTCPeerConnection.setLocalDescription, .{});
    pub const setRemoteDescription = bridge.function(RTCPeerConnection.setRemoteDescription, .{ .arity = 1 });
};

const testing = @import("../../../testing.zig");
test "WebApi: RTCPeerConnection" {
    try testing.htmlRunner("webrtc.html", .{});
}
