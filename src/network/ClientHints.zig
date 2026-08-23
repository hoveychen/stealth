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
//
// An origin is answered in full or not at all -- see `parse`. Chrome answers
// every hint it is asked for, so a partial answer is a shape no browser has,
// and an origin asking for one hint we don't carry is left seeing the same
// three it saw before this file existed.

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

    /// The hint an `Accept-CH` token names, or null if it names none of these
    /// six. Null does not mean "skip it": see `parse`, which decides whether the
    /// token is one nothing needs to be done about or one that costs the origin
    /// its whole ask.
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
    gop.value_ptr.* = parse(accept_ch) orelse .initEmpty();
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
/// optional, names case-insensitive.
///
/// Null means the ask names something this engine cannot answer and Chrome can
/// -- decline the whole thing rather than answer part of it. That rule is the
/// difference between two failures with very different costs. Cloudflare asks
/// for the nine UA hints, all of which are here, so we answer it exactly as
/// Chrome does. DataDome asks for six of those plus `Sec-CH-Device-Memory`
/// (measured, tools/fingerprint/results/acceptch-dd-chrome.json, where Chrome
/// answers all seven); answering six would put a hint set on the wire that no
/// browser produces, which is a louder signal than the three hints an engine
/// that ignores `Accept-CH` sends. Declining leaves those origins seeing exactly
/// what they saw before any of this existed.
///
/// It also fails safe forward: a guard that adds a hint we have never heard of
/// drops us back to the low-entropy three instead of into a new hybrid.
pub fn parse(accept_ch: []const u8) ?Set {
    var set: Set = .initEmpty();
    var it = std.mem.splitScalar(u8, accept_ch, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len == 0) {
            continue;
        }
        if (Hint.fromToken(token)) |hint| {
            set.insert(hint);
            continue;
        }
        if (isAlreadyAnswered(token)) {
            continue;
        }
        return null;
    }
    return set;
}

// Tokens that need nothing from the negotiation. Either the hint goes out on
// every request already, or Chrome ignores the ask too -- and matching Chrome's
// silence is not a gap.
fn isAlreadyAnswered(token: []const u8) bool {
    // The low-entropy three, unconditional since before any of this.
    for ([_][]const u8{ "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform" }) |name| {
        if (std.ascii.eqlIgnoreCase(token, name)) return true;
    }

    // The pre-standard spellings, from before the hints took the Sec- prefix.
    // Cloudflare still asks for all of them and Chrome answers not one --
    // measured, no `ua-*` field appears in
    // tools/fingerprint/results/acceptch-chrome.json. Matched by prefix so the
    // whole family counts, including ones no guard has asked us for yet.
    if (std.ascii.eqlIgnoreCase(token, "ua")) return true;
    if (token.len > 3 and std.ascii.eqlIgnoreCase(token[0..3], "ua-")) return true;

    return false;
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

test "ClientHints: an ask naming a hint we can't answer is declined whole" {
    // DataDome's list, verbatim off the 403 its four stations serve. Six of the
    // seven are hints this engine has; Sec-CH-Device-Memory is not, and a real
    // Chrome answers all seven -- measured,
    // tools/fingerprint/results/acceptch-dd-chrome.json.
    //
    // So answering six is a shape no browser has, which is worse than the three
    // an engine that ignores Accept-CH sends: that at least reads as a client
    // without client hints. All or nothing.
    try testing.expectEqual(null, parse("Sec-CH-UA,Sec-CH-UA-Mobile,Sec-CH-UA-Platform," ++
        "Sec-CH-UA-Arch,Sec-CH-UA-Full-Version-List,Sec-CH-UA-Model,Sec-CH-Device-Memory"));

    // Every non-UA hint Chrome answers does the same, so a guard that adds one
    // tomorrow drops us back to the three rather than into a new hybrid.
    try testing.expectEqual(null, parse("Sec-CH-UA-Arch, DPR"));
    try testing.expectEqual(null, parse("Sec-CH-UA-Arch, Sec-CH-Prefers-Color-Scheme"));
    try testing.expectEqual(null, parse("Sec-CH-UA-Arch, Sec-CH-UA-Form-Factors"));
}

test "ClientHints: an unsatisfiable ask clears what the origin asked for before" {
    var hints: ClientHints = .{};
    defer hints.deinit(testing.allocator);

    try hints.negotiate(testing.allocator, "https://example.com/", "Sec-CH-UA-Arch");
    try testing.expectEqual(1, hints.acceptedFor("https://example.com/").count());

    // The origin now wants something we don't have. Keeping the old six would
    // answer an ask nobody made; drop back to the low-entropy three.
    try hints.negotiate(testing.allocator, "https://example.com/", "Sec-CH-UA-Arch, DPR");
    try testing.expectEqual(0, hints.acceptedFor("https://example.com/").count());
}

test "ClientHints: parse takes the six high-entropy UA hints" {
    // Cloudflare's list, verbatim off the cf-mitigated=challenge response
    // (tools/fingerprint/results/cfsc-fo-oracle.json).
    const set = parse("Sec-CH-UA-Bitness, Sec-CH-UA-Arch, Sec-CH-UA-Full-Version, " ++
        "Sec-CH-UA-Mobile, Sec-CH-UA-Model, Sec-CH-UA-Platform-Version, " ++
        "Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform, Sec-CH-UA, " ++
        "UA-Bitness, UA-Arch, UA-Full-Version, UA-Mobile, UA-Model, " ++
        "UA-Platform-Version, UA-Platform, UA").?;

    // All six, and only six: the three low-entropy hints in that list are
    // already unconditional, and Chrome answers none of the pre-standard `UA-*`
    // spellings.
    try testing.expectEqual(6, set.count());
    for (comptime std.enums.values(Hint)) |hint| {
        try testing.expect(set.contains(hint));
    }
}

test "ClientHints: the names Chrome ignores don't make an ask unsatisfiable" {
    // Chrome answers not one of the pre-standard UA-* spellings, so ignoring
    // them is the browser-shaped thing to do, not a gap in our coverage --
    // which is exactly why Cloudflare's list, half of which is those, is
    // satisfiable.
    const set = parse("Sec-CH-UA-Arch, UA-Arch, UA-Platform, UA").?;
    try testing.expectEqual(1, set.count());
    try testing.expect(set.contains(.arch));

    // The three low-entropy hints go out unasked, so an ask for them is
    // already answered.
    try testing.expectEqual(0, parse("Sec-CH-UA, Sec-CH-UA-Mobile, Sec-CH-UA-Platform").?.count());
}

test "ClientHints: parse tolerates the syntax's slack" {
    // No spaces, extra spaces, a trailing comma and an empty element.
    const set = parse("sec-ch-ua-arch,,   SEC-CH-UA-BITNESS ,").?;
    try testing.expectEqual(2, set.count());
    try testing.expect(set.contains(.arch));
    try testing.expect(set.contains(.bitness));
    try testing.expectEqual(0, parse("").?.count());
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
