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

// One ICE candidate. Chrome derives the individual accessors by parsing the
// candidate line, so the same parse happens here rather than requiring callers
// to fill sixteen fields.
//
// Two details are measured rather than assumed, because both are cheap for a
// script to check and neither follows from the spec text:
//
//   * `component` reports "rtp" / "rtcp", not the numeric 1 / 2 in the line.
//   * `usernameFragment` is *not* parsed out of the `ufrag` token in the
//     candidate string. A candidate built by hand from a string that contains
//     `ufrag 3Ade` still reports null. Only the init dictionary sets it — and
//     candidates the engine gathers itself set it directly.
//
// toJSON carries four keys, not sixteen, and reports usernameFragment as ""
// where the accessor reports null (also measured).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Execution = js.Execution;

const RTCIceCandidate = @This();

_candidate: []const u8 = "",
_sdp_mid: ?[]const u8 = null,
_sdp_m_line_index: ?u32 = null,
_username_fragment: ?[]const u8 = null,

// Everything below is derived from _candidate by parse().
_foundation: ?[]const u8 = null,
_component: ?[]const u8 = null,
_priority: ?u32 = null,
_address: ?[]const u8 = null,
_protocol: ?[]const u8 = null,
_port: ?u32 = null,
_type: ?[]const u8 = null,
_tcp_type: ?[]const u8 = null,
_related_address: ?[]const u8 = null,
_related_port: ?u32 = null,

pub const Init = struct {
    pub const js_idl_name = "RTCIceCandidateInit";

    // Alphabetical: a dictionary's members are read in that order.
    candidate: ?lp.String.Global = null,
    sdpMLineIndex: ?u32 = null,
    sdpMid: ?lp.String.Global = null,
    usernameFragment: ?lp.String.Global = null,
};

// Chrome rejects an init that pins the candidate to neither a mid nor an
// m-line index: "Failed to construct 'RTCIceCandidate': sdpMid and
// sdpMLineIndex are both null." (measured on Chrome 151 with {}, undefined and
// a candidate-only init -- a TypeError rather than a DOMException). The
// sentence used to be missing entirely, leaving an empty message.
pub fn constructor(options: ?Init, exec: *Execution) !*RTCIceCandidate {
    const i = options orelse Init{};
    if (i.sdpMid == null and i.sdpMLineIndex == null) {
        return exec.js.fail(
            error.TypeError,
            "Failed to construct 'RTCIceCandidate': sdpMid and sdpMLineIndex are both null.",
        );
    }

    const allocator = exec._factory._arena;
    const candidate = if (i.candidate) |c| try allocator.dupe(u8, c.str.str()) else "";

    var self = RTCIceCandidate{
        ._candidate = candidate,
        ._sdp_mid = if (i.sdpMid) |m| try allocator.dupe(u8, m.str.str()) else null,
        ._sdp_m_line_index = i.sdpMLineIndex,
        ._username_fragment = if (i.usernameFragment) |u| try allocator.dupe(u8, u.str.str()) else null,
    };
    self.parse();
    return exec._factory.create(self);
}

// Builds one from a line the engine generated itself, where every field is
// already known and the string is arena-owned.
pub fn init(exec: *Execution, candidate: []const u8, sdp_mid: []const u8, sdp_m_line_index: u32, ufrag: []const u8) !*RTCIceCandidate {
    var self = RTCIceCandidate{
        ._candidate = candidate,
        ._sdp_mid = sdp_mid,
        ._sdp_m_line_index = sdp_m_line_index,
        ._username_fragment = ufrag,
    };
    self.parse();
    return exec._factory.create(self);
}

// candidate:<foundation> <component> <transport> <priority> <address> <port>
//   typ <type> [raddr <ip> rport <port>] [tcptype <t>] [generation N]
//   [ufrag X] [network-cost N]
//
// Anything that doesn't match leaves the derived fields null, which is what
// Chrome does with an unparseable line.
fn parse(self: *RTCIceCandidate) void {
    const line = self._candidate;
    const body = if (std.mem.startsWith(u8, line, "candidate:")) line["candidate:".len..] else return;

    var it = std.mem.tokenizeScalar(u8, body, ' ');
    const foundation = it.next() orelse return;
    const component = it.next() orelse return;
    const protocol = it.next() orelse return;
    const priority = it.next() orelse return;
    const address = it.next() orelse return;
    const port = it.next() orelse return;

    self._foundation = foundation;
    self._component = if (std.mem.eql(u8, component, "1"))
        "rtp"
    else if (std.mem.eql(u8, component, "2")) "rtcp" else null;
    self._protocol = protocol;
    self._priority = std.fmt.parseInt(u32, priority, 10) catch null;
    self._address = address;
    self._port = std.fmt.parseInt(u32, port, 10) catch null;

    // The remainder is a stream of name/value pairs, `typ` among them.
    while (it.next()) |key| {
        const value = it.next() orelse break;
        if (std.mem.eql(u8, key, "typ")) {
            self._type = value;
        } else if (std.mem.eql(u8, key, "raddr")) {
            self._related_address = value;
        } else if (std.mem.eql(u8, key, "rport")) {
            self._related_port = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "tcptype")) {
            self._tcp_type = value;
        }
    }
}

pub fn getCandidate(self: *const RTCIceCandidate) []const u8 {
    return self._candidate;
}

pub fn getSdpMid(self: *const RTCIceCandidate) ?[]const u8 {
    return self._sdp_mid;
}

pub fn getSdpMLineIndex(self: *const RTCIceCandidate) ?u32 {
    return self._sdp_m_line_index;
}

pub fn getFoundation(self: *const RTCIceCandidate) ?[]const u8 {
    return self._foundation;
}

pub fn getComponent(self: *const RTCIceCandidate) ?[]const u8 {
    return self._component;
}

pub fn getPriority(self: *const RTCIceCandidate) ?u32 {
    return self._priority;
}

pub fn getAddress(self: *const RTCIceCandidate) ?[]const u8 {
    return self._address;
}

pub fn getProtocol(self: *const RTCIceCandidate) ?[]const u8 {
    return self._protocol;
}

pub fn getPort(self: *const RTCIceCandidate) ?u32 {
    return self._port;
}

pub fn getType(self: *const RTCIceCandidate) ?[]const u8 {
    return self._type;
}

pub fn getTcpType(self: *const RTCIceCandidate) ?[]const u8 {
    return self._tcp_type;
}

pub fn getRelatedAddress(self: *const RTCIceCandidate) ?[]const u8 {
    return self._related_address;
}

pub fn getRelatedPort(self: *const RTCIceCandidate) ?u32 {
    return self._related_port;
}

pub fn getUsernameFragment(self: *const RTCIceCandidate) ?[]const u8 {
    return self._username_fragment;
}

// Both are null for every candidate this engine produces: relayProtocol only
// has a value for TURN candidates, and `url` only for ones a STUN/TURN server
// answered. Neither happens without a media backend.
pub fn getRelayProtocol(_: *const RTCIceCandidate) ?[]const u8 {
    return null;
}

pub fn getUrl(_: *const RTCIceCandidate) ?[]const u8 {
    return null;
}

pub fn toJSON(self: *const RTCIceCandidate) struct {
    candidate: []const u8,
    sdpMid: ?[]const u8,
    sdpMLineIndex: ?u32,
    usernameFragment: []const u8,
} {
    return .{
        .candidate = self._candidate,
        .sdpMid = self._sdp_mid,
        .sdpMLineIndex = self._sdp_m_line_index,
        .usernameFragment = self._username_fragment orelse "",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCIceCandidate);

    pub const Meta = struct {
        pub const name = "RTCIceCandidate";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCIceCandidate.constructor, .{});

    pub const candidate = bridge.accessor(RTCIceCandidate.getCandidate, null, .{});
    pub const sdpMid = bridge.accessor(RTCIceCandidate.getSdpMid, null, .{});
    pub const sdpMLineIndex = bridge.accessor(RTCIceCandidate.getSdpMLineIndex, null, .{});
    pub const foundation = bridge.accessor(RTCIceCandidate.getFoundation, null, .{});
    pub const component = bridge.accessor(RTCIceCandidate.getComponent, null, .{});
    pub const priority = bridge.accessor(RTCIceCandidate.getPriority, null, .{});
    pub const address = bridge.accessor(RTCIceCandidate.getAddress, null, .{});
    pub const protocol = bridge.accessor(RTCIceCandidate.getProtocol, null, .{});
    pub const port = bridge.accessor(RTCIceCandidate.getPort, null, .{});
    pub const @"type" = bridge.accessor(RTCIceCandidate.getType, null, .{});
    pub const tcpType = bridge.accessor(RTCIceCandidate.getTcpType, null, .{});
    pub const relatedAddress = bridge.accessor(RTCIceCandidate.getRelatedAddress, null, .{});
    pub const relatedPort = bridge.accessor(RTCIceCandidate.getRelatedPort, null, .{});
    pub const usernameFragment = bridge.accessor(RTCIceCandidate.getUsernameFragment, null, .{});
    pub const relayProtocol = bridge.accessor(RTCIceCandidate.getRelayProtocol, null, .{});
    pub const url = bridge.accessor(RTCIceCandidate.getUrl, null, .{});
    pub const toJSON = bridge.function(RTCIceCandidate.toJSON, .{});
};
