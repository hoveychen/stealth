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

// A STUN Binding transaction (RFC 5389), just enough of one to learn the
// address a page's `iceServers` sees us at.
//
// A page that configures a STUN server and then reads the candidate list is
// reading a fingerprint: Chrome answers with a host candidate *and* a
// server-reflexive one, and an engine that only ever produces the host
// candidate is one candidate short on every such page. The reflexive address
// cannot be invented -- it is whatever the NAT in front of this process rewrote
// the source address to -- so it has to be asked for.
//
// The exchange runs on a detached thread. Resolution goes through getaddrinfo
// and the reply is waited for with a receive timeout, both of which block for
// as long as the network feels like; doing either on the scheduler thread would
// stall every other task on the page behind a third party's DNS. The caller
// polls `finished()` from a scheduler task instead.
//
// The socket is handed over, not opened here: the host candidate has to carry
// the port the binding request goes out from (Chrome's two candidates carry the
// same port), so the caller binds it first and reads the port back off it.

const std = @import("std");
const lp = @import("lightpanda");

const net = @import("../../../sys/net.zig");

const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// RFC 5389 §6.
const MAGIC_COOKIE: u32 = 0x2112A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const FAMILY_IP4: u8 = 0x01;

// The default port for a `stun:` URI with none of its own (RFC 7064).
const DEFAULT_PORT: u16 = 3478;

// RFC 5389's retransmission schedule starts at RTO and doubles; Chrome keeps
// retrying for about nine seconds. Nothing here can afford that: the page is
// waiting on end-of-gathering, so a server that never answers has to be given
// up on inside a budget a page would not notice. Three attempts of 300ms is
// 900ms worst case, against a reachable server answering in well under one.
const ATTEMPTS = 3;
const ATTEMPT_TIMEOUT_MS = 300;

/// The address a STUN server saw the binding request come from.
pub const Reflexive = struct {
    bytes: [4]u8,
    port: u16,

    pub fn format(self: Reflexive, w: *std.Io.Writer) !void {
        return w.print("{d}.{d}.{d}.{d}", .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] });
    }
};

/// One in-flight binding transaction. Shared between the caller and the worker
/// thread; whichever releases last frees it, so the caller can walk away from a
/// transaction that has not come back yet.
pub const Probe = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,
    socket: net.socket_t,
    // Drawn on the caller's thread: the process-wide random source is not the
    // worker's to reach for.
    transaction: [12]u8,

    refs: std.atomic.Value(u8),
    // Set last, with release ordering: `reflexive` is only read once this is
    // true, so publishing it publishes the result too.
    complete: std.atomic.Value(bool),
    reflexive: ?Reflexive = null,

    /// Starts a transaction against the first `stun:` URL in `urls`, taking
    /// ownership of `socket`. Returns null when none of the URLs names a STUN
    /// server this can talk to, in which case the socket is left alone.
    pub fn start(urls: []const []const u8, socket: net.socket_t) ?*Probe {
        const target = for (urls) |url| {
            if (parseUrl(url)) |t| break t;
        } else return null;

        const allocator = std.heap.smp_allocator;
        const self = allocator.create(Probe) catch return null;
        const host = allocator.dupe(u8, target.host) catch {
            allocator.destroy(self);
            return null;
        };
        self.* = .{
            .allocator = allocator,
            .host = host,
            .port = target.port,
            .socket = socket,
            .transaction = undefined,
            .refs = .init(2),
            .complete = .init(false),
        };
        lp.io.random(&self.transaction);

        const thread = std.Thread.spawn(.{}, work, .{self}) catch {
            // Nobody else holds it yet, so one release is the whole of it.
            self.refs.store(1, .monotonic);
            self.release();
            return null;
        };
        thread.detach();
        return self;
    }

    /// Has the transaction come back, one way or the other?
    pub fn finished(self: *const Probe) bool {
        return self.complete.load(.acquire);
    }

    /// The reflexive address, or null when the server never answered. Only
    /// meaningful once `finished()`.
    pub fn result(self: *const Probe) ?Reflexive {
        return self.reflexive;
    }

    pub fn release(self: *Probe) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) {
            return;
        }
        const allocator = self.allocator;
        allocator.free(self.host);
        allocator.destroy(self);
    }

    fn work(self: *Probe) void {
        // Nothing is logged from here: the logger is the scheduler thread's.
        self.reflexive = self.exchange() catch null;
        net.close(self.socket);
        self.complete.store(true, .release);
        self.release();
    }

    fn exchange(self: *Probe) !Reflexive {
        const address = try resolve(self.host, self.port);
        const sa = net.sockaddrFromAddress(&address);

        // Connecting a datagram socket both fixes the destination and asks for
        // the ICMP errors an unconnected one is never told about, so a server
        // that is refusing on this host comes back at once instead of sitting
        // out the whole retransmission budget.
        if (c.connect(self.socket, sa.ptr(), sa.len) != 0) {
            return error.ConnectFailed;
        }

        var request: [20]u8 = undefined;
        std.mem.writeInt(u16, request[0..2], BINDING_REQUEST, .big);
        std.mem.writeInt(u16, request[2..4], 0, .big); // no attributes
        std.mem.writeInt(u32, request[4..8], MAGIC_COOKIE, .big);
        request[8..20].* = self.transaction;

        try setReceiveTimeout(self.socket, ATTEMPT_TIMEOUT_MS);

        var reply: [512]u8 = undefined;
        for (0..ATTEMPTS) |_| {
            if (c.sendto(self.socket, &request, request.len, 0, null, 0) < 0) {
                return error.SendFailed;
            }
            const n = c.recvfrom(self.socket, &reply, reply.len, 0, null, null);
            if (n < 0) {
                continue; // timed out, or the last datagram bounced
            }
            if (parseResponse(reply[0..@intCast(n)], request[8..20])) |reflexive| {
                return reflexive;
            }
        }
        return error.NoReply;
    }
};

const Target = struct {
    host: []const u8,
    port: u16,
};

/// `stun:host`, `stun:host:port`, `stun:[v6]:port`, either with a
/// `?transport=` query. `stuns:` is TURN-over-TLS's sibling and is not a
/// datagram exchange, so it is not one of these.
fn parseUrl(url: []const u8) ?Target {
    const rest = if (std.mem.startsWith(u8, url, "stun:")) url["stun:".len..] else return null;
    const authority = rest[0 .. std.mem.indexOfScalar(u8, rest, '?') orelse rest.len];
    if (authority.len == 0) {
        return null;
    }

    // An IPv6 literal brings colons of its own, so the port separator is the
    // one after the brackets.
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        return .{
            .host = authority[1..close],
            .port = parsePort(authority[close + 1 ..]) orelse return null,
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse {
        return .{ .host = authority, .port = DEFAULT_PORT };
    };
    return .{
        .host = authority[0..colon],
        .port = parsePort(authority[colon..]) orelse return null,
    };
}

// `text` is what followed the host: empty, or ":" and digits.
fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0) {
        return DEFAULT_PORT;
    }
    if (text[0] != ':') {
        return null;
    }
    return std.fmt.parseInt(u16, text[1..], 10) catch null;
}

// The socket is AF_INET, so an IPv6-only server is one this cannot reach; let
// resolution fail rather than binding a second socket the candidate lines have
// no room for.
fn resolve(host: []const u8, port: u16) !net.IpAddress {
    if (net.IpAddress.parse(host, port)) |address| {
        return switch (address) {
            .ip4 => address,
            .ip6 => error.UnsupportedAddressFamily,
        };
    } else |_| {}

    var name: [256]u8 = undefined;
    if (host.len >= name.len) {
        return error.NameTooLong;
    }
    @memcpy(name[0..host.len], host);
    name[host.len] = 0;

    var service: [8]u8 = undefined;
    const service_z = try std.fmt.bufPrintZ(&service, "{d}", .{port});

    const hints: c.addrinfo = .{
        .flags = .{},
        .family = posix.AF.INET,
        .socktype = posix.SOCK.DGRAM,
        .protocol = posix.IPPROTO.UDP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };
    var list: ?*c.addrinfo = null;
    switch (c.getaddrinfo(name[0..host.len :0], service_z, &hints, &list)) {
        @as(c.EAI, @enumFromInt(0)) => {},
        else => return error.NameResolutionFailed,
    }
    const head = list orelse return error.NameResolutionFailed;
    defer c.freeaddrinfo(head);

    var entry: ?*c.addrinfo = head;
    while (entry) |e| : (entry = e.next) {
        const addr = e.addr orelse continue;
        if (addr.family != posix.AF.INET) {
            continue;
        }
        return net.addressFromSockaddr(@alignCast(addr));
    }
    return error.NameResolutionFailed;
}

fn setReceiveTimeout(socket: net.socket_t, ms: u32) !void {
    const timeout = posix.timeval{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    const rc = c.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout, @sizeOf(posix.timeval));
    if (rc != 0) {
        return error.SetTimeoutFailed;
    }
}

/// Pulls the reflexive address out of a Binding Success Response. A reply whose
/// transaction id is not the one that was sent belongs to someone else.
fn parseResponse(reply: []const u8, transaction: *const [12]u8) ?Reflexive {
    if (reply.len < 20) {
        return null;
    }
    if (std.mem.readInt(u16, reply[0..2], .big) != BINDING_SUCCESS) {
        return null;
    }
    if (std.mem.readInt(u32, reply[4..8], .big) != MAGIC_COOKIE) {
        return null;
    }
    if (!std.mem.eql(u8, reply[8..20], transaction)) {
        return null;
    }

    const length = std.mem.readInt(u16, reply[2..4], .big);
    const body = reply[20..@min(reply.len, 20 + @as(usize, length))];

    // Attributes are TLV, each padded out to a multiple of four bytes. Both
    // spellings of the address appear in the wild; the XOR one is what RFC 5389
    // servers send and what a middlebox is least likely to have rewritten, so
    // it wins when both are present.
    var mapped: ?Reflexive = null;
    var pos: usize = 0;
    while (pos + 4 <= body.len) {
        const kind = std.mem.readInt(u16, body[pos..][0..2], .big);
        const size = std.mem.readInt(u16, body[pos + 2 ..][0..2], .big);
        const start = pos + 4;
        const end = start + size;
        if (end > body.len) {
            break;
        }
        const value = body[start..end];
        switch (kind) {
            ATTR_XOR_MAPPED_ADDRESS => if (decodeAddress(value, true)) |found| return found,
            ATTR_MAPPED_ADDRESS => if (decodeAddress(value, false)) |found| {
                mapped = found;
            },
            else => {},
        }
        pos = end + ((4 - (size % 4)) % 4);
    }
    return mapped;
}

// A MAPPED-ADDRESS value: a reserved byte, the family, the port, the address.
// The XOR flavour masks the port with the top half of the magic cookie and the
// address with the whole of it.
fn decodeAddress(value: []const u8, xor: bool) ?Reflexive {
    if (value.len < 8 or value[1] != FAMILY_IP4) {
        return null;
    }
    var port = std.mem.readInt(u16, value[2..4], .big);
    var bytes: [4]u8 = value[4..8].*;
    if (xor) {
        port ^= @truncate(MAGIC_COOKIE >> 16);
        const cookie = std.mem.toBytes(std.mem.nativeToBig(u32, MAGIC_COOKIE));
        for (&bytes, cookie) |*b, mask| {
            b.* ^= mask;
        }
    }
    return .{ .bytes = bytes, .port = port };
}

const testing = @import("../../../testing.zig");

test "stun: parseUrl" {
    try testing.expectEqual(null, parseUrl("turn:example.com:3478"));
    try testing.expectEqual(null, parseUrl("stuns:example.com"));
    try testing.expectEqual(null, parseUrl("stun:"));
    try testing.expectEqual(null, parseUrl("stun:example.com:notaport"));

    {
        const target = parseUrl("stun:stun.l.google.com:19302").?;
        try testing.expectEqual("stun.l.google.com", target.host);
        try testing.expectEqual(19302, target.port);
    }
    {
        const target = parseUrl("stun:example.com").?;
        try testing.expectEqual("example.com", target.host);
        try testing.expectEqual(DEFAULT_PORT, target.port);
    }
    {
        const target = parseUrl("stun:example.com:19302?transport=udp").?;
        try testing.expectEqual("example.com", target.host);
        try testing.expectEqual(19302, target.port);
    }
    {
        const target = parseUrl("stun:[2001:db8::1]:19302").?;
        try testing.expectEqual("2001:db8::1", target.host);
        try testing.expectEqual(19302, target.port);
    }
}

test "stun: parseResponse" {
    const transaction: [12]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

    // A success response carrying XOR-MAPPED-ADDRESS 192.0.2.10:32853. The
    // masked bytes are the address XOR'd with the magic cookie, which is how
    // the attribute travels.
    var reply: [32]u8 = undefined;
    std.mem.writeInt(u16, reply[0..2], BINDING_SUCCESS, .big);
    std.mem.writeInt(u16, reply[2..4], 12, .big);
    std.mem.writeInt(u32, reply[4..8], MAGIC_COOKIE, .big);
    @memcpy(reply[8..20], &transaction);
    std.mem.writeInt(u16, reply[20..22], ATTR_XOR_MAPPED_ADDRESS, .big);
    std.mem.writeInt(u16, reply[22..24], 8, .big);
    reply[24] = 0;
    reply[25] = FAMILY_IP4;
    std.mem.writeInt(u16, reply[26..28], 32853 ^ @as(u16, 0x2112), .big);
    reply[28..32].* = .{ 192 ^ 0x21, 0 ^ 0x12, 2 ^ 0xA4, 10 ^ 0x42 };

    const found = parseResponse(&reply, &transaction).?;
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 10 }, &found.bytes);
    try testing.expectEqual(32853, found.port);

    // Someone else's transaction, and a request rather than a response.
    const other: [12]u8 = .{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 };
    try testing.expectEqual(null, parseResponse(&reply, &other));
    std.mem.writeInt(u16, reply[0..2], BINDING_REQUEST, .big);
    try testing.expectEqual(null, parseResponse(&reply, &transaction));
}
