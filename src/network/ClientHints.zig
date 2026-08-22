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
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// The per-origin client-hint negotiation: which high-entropy `Sec-CH-UA-*`
// hints an origin has asked for via `Accept-CH`, remembered for as long as the
// browser lives.
//
// Three of the nine UA hints -- `sec-ch-ua`, `sec-ch-ua-mobile` and
// `sec-ch-ua-platform` -- are low-entropy and go out unasked, which is why they
// live in Client.baselineHeaders and not here. The other six are only sent to an
// origin that asked, and sending one unsolicited is itself a tell.
//
// This matters beyond politeness. Cloudflare's managed challenge answers its 403
// interstitial with an `Accept-CH` naming all nine, and every request a real
// Chrome makes to that origin afterwards carries all nine while an engine that
// ignores the header keeps sending three -- measured, the E2 section of
// tools/fingerprint/results/cfsc-oracle-diff.md.

const std = @import("std");

const URL = @import("../browser/URL.zig");

const Allocator = std.mem.Allocator;

const ClientHints = @This();

/// The high-entropy UA hints this engine can answer. Ordered as Chrome emits
/// them on a navigation, minus the three low-entropy ones it interleaves.
pub const Hint = enum {
    full_version,
    arch,
    platform_version,
    model,
    bitness,
    full_version_list,

    /// The wire name. Lowercase, because that is how Chromium spells the client
    /// hints on HTTP/1.1 while Title-Casing every other field name -- the same
    /// rule the three baseline hints already follow.
    pub fn header(self: Hint) []const u8 {
        return switch (self) {
            .full_version => "sec-ch-ua-full-version",
            .arch => "sec-ch-ua-arch",
            .platform_version => "sec-ch-ua-platform-version",
            .model => "sec-ch-ua-model",
            .bitness => "sec-ch-ua-bitness",
            .full_version_list => "sec-ch-ua-full-version-list",
        };
    }

    /// An `Accept-CH` token, or null for one we don't answer -- the three
    /// low-entropy hints (already unconditional), the non-UA hints
    /// (`Device-Memory`, `DPR`, `Sec-CH-Prefers-*`, ...) this engine has no
    /// value for, and the pre-standard `UA-*` spellings Cloudflare still asks
    /// for and Chrome answers with silence (measured: not one of them appears
    /// in results/acceptch-chrome.json).
    fn fromToken(token: []const u8) ?Hint {
        inline for (comptime std.enums.values(Hint)) |hint| {
            if (std.ascii.eqlIgnoreCase(token, hint.header())) return hint;
        }
        return null;
    }
};

pub const Set = std.EnumSet(Hint);

// origin ("https://host[:port]") -> the hints that origin last asked for. Keys
// are owned by the allocator passed to negotiate.
origins: std.StringHashMapUnmanaged(Set) = .empty,

pub fn deinit(self: *ClientHints, allocator: Allocator) void {
    var it = self.origins.keyIterator();
    while (it.next()) |key| {
        allocator.free(key.*);
    }
    self.origins.deinit(allocator);
}

/// Record what `accept_ch` asks for as the hint set of `url`'s origin,
/// replacing whatever that origin asked for before -- an `Accept-CH` is the
/// origin's whole preference, not an addition to it. A response *without* the
/// header leaves the stored set alone, so callers must only reach here when the
/// header was present.
pub fn negotiate(self: *ClientHints, allocator: Allocator, url: [:0]const u8, accept_ch: []const u8) !void {
    var buf: [max_origin_len]u8 = undefined;
    const origin = originKey(url, &buf) orelse return;

    const gop = try self.origins.getOrPut(allocator, origin);
    errdefer if (gop.found_existing == false) {
        _ = self.origins.remove(origin);
    };
    if (gop.found_existing == false) {
        // `origin` points into `buf` or into `url`, neither of which outlives
        // this call.
        gop.key_ptr.* = try allocator.dupe(u8, origin);
    }
    gop.value_ptr.* = parse(accept_ch);
}

/// The hints `url`'s origin has asked for. Empty for an origin that never did,
/// which is every origin until it says otherwise.
pub fn acceptedFor(self: *const ClientHints, url: [:0]const u8) Set {
    if (self.origins.count() == 0) {
        // The common case, and the one worth keeping free: most pages never
        // meet an origin that asks.
        return .initEmpty();
    }
    var buf: [max_origin_len]u8 = undefined;
    const origin = originKey(url, &buf) orelse return .initEmpty();
    return self.origins.get(origin) orelse .initEmpty();
}

/// Parses the `Accept-CH` list syntax: comma-separated hint names, spaces
/// optional, names case-insensitive. A name we don't answer is skipped rather
/// than fatal -- an origin naming twenty hints and getting six is the normal
/// case, not an error.
pub fn parse(accept_ch: []const u8) Set {
    var set: Set = .initEmpty();
    var it = std.mem.splitScalar(u8, accept_ch, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (Hint.fromToken(token)) |hint| {
            set.insert(hint);
        }
    }
    return set;
}

// The origin serialization used as the map key, written into `buf`. Null when
// the URL has no origin worth keying on: a non-HTTP scheme, or -- the reason
// this is a gate and not just a parse -- an origin that is not potentially
// trustworthy. Chrome refuses to remember hints for those, so a plain-http site
// asking for nine hints gets three from Chrome and must get three from us.
fn originKey(url: [:0]const u8, buf: []u8) ?[]const u8 {
    if (URL.isPotentiallyTrustworthy(url) == false) return null;
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return URL.getOrigin(fba.allocator(), url) catch null;
}

// An origin serialization is a scheme, a host and maybe a port; 512 bytes is
// past anything a real one reaches (a hostname caps at 253) and the overflow
// path just means no hints, not a failure.
const max_origin_len = 512;

const testing = @import("../testing.zig");

test "ClientHints: parse takes the six high-entropy UA hints" {
    // Cloudflare's list, verbatim off the cf-mitigated=challenge response
    // (tools/fingerprint/results/cfsc-fo-oracle.json).
    const set = parse("Sec-CH-UA-Bitness, Sec-CH-UA-Arch, Sec-CH-UA-Full-Version, " ++
        "Sec-CH-UA-Mobile, Sec-CH-UA-Model, Sec-CH-UA-Platform-Version, " ++
        "Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform, Sec-CH-UA, " ++
        "UA-Bitness, UA-Arch, UA-Full-Version, UA-Mobile, UA-Model, " ++
        "UA-Platform-Version, UA-Platform, UA");

    // All six, and only six: the three low-entropy hints in that list are
    // already unconditional, and Chrome answers none of the pre-standard `UA-*`
    // spellings.
    try testing.expectEqual(6, set.count());
    for (comptime std.enums.values(Hint)) |hint| {
        try testing.expect(set.contains(hint));
    }
}

test "ClientHints: parse skips hints this engine has no value for" {
    const set = parse("Sec-CH-UA-Arch, Device-Memory, DPR, Sec-CH-Prefers-Color-Scheme, Width");
    try testing.expectEqual(1, set.count());
    try testing.expect(set.contains(.arch));
}

test "ClientHints: parse tolerates the syntax's slack" {
    // No spaces, extra spaces, a trailing comma and an empty element.
    const set = parse("sec-ch-ua-arch,,   SEC-CH-UA-BITNESS ,");
    try testing.expectEqual(2, set.count());
    try testing.expect(set.contains(.arch));
    try testing.expect(set.contains(.bitness));
    try testing.expectEqual(0, parse("").count());
}

test "ClientHints: an origin gets what it asked for, and no other origin does" {
    var hints: ClientHints = .{};
    defer hints.deinit(testing.allocator);

    try hints.negotiate(testing.allocator, "https://example.com/challenge?a=1", "Sec-CH-UA-Arch, Sec-CH-UA-Model");

    // Any path on the origin, and the default port spelled out, are the same
    // origin.
    try testing.expectEqual(2, hints.acceptedFor("https://example.com/other").count());
    try testing.expectEqual(2, hints.acceptedFor("https://example.com:443/other").count());
    try testing.expect(hints.acceptedFor("https://example.com/").contains(.arch));
    try testing.expect(hints.acceptedFor("https://example.com/").contains(.model));

    // A sibling host, a sibling port and the other scheme are each a different
    // origin, and none of them asked.
    try testing.expectEqual(0, hints.acceptedFor("https://cdn.example.com/x").count());
    try testing.expectEqual(0, hints.acceptedFor("https://example.com:8443/x").count());
    try testing.expectEqual(0, hints.acceptedFor("http://example.com/x").count());
}

test "ClientHints: a second Accept-CH replaces the origin's set" {
    var hints: ClientHints = .{};
    defer hints.deinit(testing.allocator);

    try hints.negotiate(testing.allocator, "https://example.com/", "Sec-CH-UA-Arch, Sec-CH-UA-Model");
    try hints.negotiate(testing.allocator, "https://example.com/two", "Sec-CH-UA-Bitness");

    const set = hints.acceptedFor("https://example.com/");
    try testing.expectEqual(1, set.count());
    try testing.expect(set.contains(.bitness));

    // Replaced, not accumulated: one key for the one origin.
    try testing.expectEqual(1, hints.origins.count());
}

test "ClientHints: an origin that is not potentially trustworthy is not remembered" {
    var hints: ClientHints = .{};
    defer hints.deinit(testing.allocator);

    // Chrome persists hints only for a potentially-trustworthy origin, so an
    // http site asking for them gets the low-entropy three and nothing else.
    try hints.negotiate(testing.allocator, "http://example.com/", "Sec-CH-UA-Arch");
    try testing.expectEqual(0, hints.acceptedFor("http://example.com/").count());
    try testing.expectEqual(0, hints.origins.count());

    // Loopback is trustworthy without TLS, which is what makes
    // tools/fingerprint/accept-ch-echo.mjs a valid stand-in for a real origin.
    try hints.negotiate(testing.allocator, "http://127.0.0.1:9586/accept-ch", "Sec-CH-UA-Arch");
    try testing.expectEqual(1, hints.acceptedFor("http://127.0.0.1:9586/sub/x").count());
}
