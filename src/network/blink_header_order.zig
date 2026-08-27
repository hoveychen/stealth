//! The order Chrome puts request header fields on the wire, for the fields that
//! come out of the renderer.
//!
//! There is no slot. Blink keeps a request's headers in `HTTPHeaderMap`, which is
//! `HashMap<AtomicString, AtomicString, DeprecatedCaseFoldingHashTraits<AtomicString>>`,
//! and the order that reaches the network service -- and from there the wire, h1
//! and h2 alike -- is that hash table's bucket order. So the position of every
//! field is a function of the *whole set* of names present: one author header
//! more and `user-agent` moves.
//!
//! Two ingredients, both fixed constants in Chromium rather than per-process
//! randomised, which is why the order is stable across browser launches and
//! reproducible at all:
//!
//!   * the hash -- rapidhash (`third_party/rapidhash/rapidhash.h`) with
//!     `RAPID_SEED` and the default secret triplet, over the case-folded name
//!     expanded to UTF-16, masked to the low 24 bits (`StringHasher` reserves the
//!     top 8 for `StringImpl` flags);
//!   * the table -- `WTF::HashTable`: power-of-two size from 8, max load 1/2,
//!     doubling, `i = (i + ++probe) & mask` on collision, iterated from bucket 0.
//!
//! Measured against Chrome 151 over 26 shapes, h1 and h2 (results/b59-*.json),
//! and it reproduces every one. Fifteen of the 26 were written down as
//! predictions before they were measured. `tools/fingerprint/blink-header-order.mjs`
//! is the same model in JS, with a `--verify` mode that scores a capture.
//!
//! It does *not* describe a navigation: a top-level navigation is built browser
//! side in an ordered vector, and comes out in the canonical hint declaration
//! order instead. Which costs nothing here -- author headers only ever ride on
//! subresources.
const std = @import("std");

// third_party/rapidhash/rapidhash.h: RAPID_SEED and rapid_secret.
const seed_init: u64 = 0xbdd89aa982704029;
const secret = [3]u64{ 0x2d358dccaa6c78a5, 0x8bb84b93962eacc9, 0x4b33a62ed433d4a3 };

// A table this can simulate holds `max_names` comfortably: the doublings land at
// 4, 8, 16 and 32 keys, so 48 names never grow past 128 buckets.
pub const max_names = 48;
const max_table = 128;
const empty_bucket = std.math.maxInt(u8);

// CaseFoldingHashReader expands Latin1 to UTF-16 as it folds, so the byte stream
// rapidhash sees is the lowercased name with a zero after every character. Read
// it as a view rather than materialising it -- same bytes, no buffer, no length
// limit.
fn byteAt(name: []const u8, i: usize) u8 {
    if (i & 1 == 1) return 0;
    return std.ascii.toLower(name[i >> 1]);
}

fn read(name: []const u8, offset: usize, comptime n: usize) u64 {
    var v: u64 = 0;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        v = (v << 8) | byteAt(name, offset + i);
    }
    return v;
}

fn mix(a: u64, b: u64) u64 {
    const r = @as(u128, a) * @as(u128, b);
    return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
}

fn rapidhash(name: []const u8) u64 {
    const len = name.len * 2;
    const len64: u64 = @intCast(len);
    var seed = seed_init ^ mix(seed_init ^ secret[0], secret[1]) ^ len64;
    var a: u64 = 0;
    var b: u64 = 0;
    var p: usize = 0;

    if (len <= 16) {
        if (len >= 4) {
            // The first and last 32 bits, which may overlap.
            const plast = len - 4;
            a = (read(name, 0, 4) << 32) | read(name, plast, 4);
            const delta = (len & 24) >> @as(u6, @intCast(len >> 3));
            b = (read(name, delta, 4) << 32) | read(name, plast - delta, 4);
        } else if (len > 0) {
            a = (@as(u64, byteAt(name, 0)) << 56) |
                (@as(u64, byteAt(name, len >> 1)) << 32) |
                @as(u64, byteAt(name, len - 1));
        }
    } else {
        var i = len;
        if (i > 48) {
            var see1 = seed;
            var see2 = seed;
            while (true) {
                seed = mix(read(name, p, 8) ^ secret[0], read(name, p + 8, 8) ^ seed);
                see1 = mix(read(name, p + 16, 8) ^ secret[1], read(name, p + 24, 8) ^ see1);
                see2 = mix(read(name, p + 32, 8) ^ secret[2], read(name, p + 40, 8) ^ see2);
                p += 48;
                i -= 48;
                if (i < 48) break;
            }
            seed ^= see1 ^ see2;
        }
        if (i > 16) {
            seed = mix(read(name, p, 8) ^ secret[2], read(name, p + 8, 8) ^ seed ^ secret[1]);
            if (i > 32) {
                seed = mix(read(name, p + 16, 8) ^ secret[2], read(name, p + 24, 8) ^ seed);
            }
        }
        a = read(name, p + i - 16, 8);
        b = read(name, p + i - 8, 8);
    }

    a ^= secret[1];
    b ^= seed;
    const r = @as(u128, a) * @as(u128, b);
    return mix(@as(u64, @truncate(r)) ^ secret[0] ^ len64, @as(u64, @truncate(r >> 64)) ^ secret[1]);
}

/// `StringHasher::ComputeHashAndMaskTop8Bits` through `CaseFoldingHashReader`.
pub fn nameHash(name: []const u8) u32 {
    const masked: u32 = @intCast(rapidhash(name) & 0xffffff);
    // A zero hash is reserved, so it is nudged rather than stored.
    return if (masked == 0) 0x800000 else masked;
}

/// Writes into `order` the indices of `names`, permuted into the bucket order
/// Blink's map would iterate them. `names` must already be in the order the
/// renderer *inserts* them, which is only observable when two names collide.
///
/// Returns the number of indices written, or null when there are more names than
/// this can simulate -- in which case the caller should fall back to emitting
/// them in their own order rather than guess.
pub fn bucketOrder(names: []const []const u8, order: []u8) ?usize {
    if (names.len > max_names or names.len > order.len) return null;

    var table: [max_table]u8 = @splat(empty_bucket);
    var size: usize = 8;
    var count: usize = 0;

    for (names, 0..) |_, i| {
        place(&table, size, names, @intCast(i));
        count += 1;
        if (count * 2 >= size) {
            // Rehash: the old table is walked from bucket 0, so the reinsertion
            // order is the old bucket order, not the original insertion order.
            var old: [max_table]u8 = table;
            const old_size = size;
            size *= 2;
            table = @splat(empty_bucket);
            for (old[0..old_size]) |slot| {
                if (slot != empty_bucket) place(&table, size, names, slot);
            }
        }
    }

    var n: usize = 0;
    for (table[0..size]) |slot| {
        if (slot == empty_bucket) continue;
        order[n] = slot;
        n += 1;
    }
    return n;
}

fn place(table: *[max_table]u8, size: usize, names: []const []const u8, slot: u8) void {
    const mask = size - 1;
    var i = @as(usize, nameHash(names[slot])) & mask;
    var probe: usize = 0;
    while (table[i] != empty_bucket) {
        probe += 1;
        i = (i + probe) & mask;
    }
    table[i] = slot;
}

const testing = std.testing;

fn expectOrder(expected: []const []const u8, insertion: []const []const u8) !void {
    var order: [max_names]u8 = undefined;
    const n = bucketOrder(insertion, &order) orelse return error.TooManyNames;
    try testing.expectEqual(expected.len, n);
    for (expected, order[0..n]) |want, slot| {
        try testing.expectEqualStrings(want, insertion[slot]);
    }
}

test "blink header order: the shapes with no author header" {
    // The block of chrome_subresource_order, measured long before this model
    // existed: a subresource carrying the three baseline hints and a body.
    try expectOrder(
        &.{ "sec-ch-ua-platform", "user-agent", "sec-ch-ua", "content-type", "sec-ch-ua-mobile" },
        &.{ "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "user-agent", "content-type" },
    );

    // The block of chrome_subresource_hinted_order: the same request to an
    // origin that asked for all nine hints. Eleven names in an order that is
    // neither alphabetical nor declaration order, and the model lands it.
    try expectOrder(&.{
        "sec-ch-ua-full-version-list", "sec-ch-ua-platform",         "sec-ch-ua",
        "sec-ch-ua-bitness",           "sec-ch-ua-model",            "sec-ch-ua-mobile",
        "sec-ch-ua-arch",              "sec-ch-ua-full-version",     "user-agent",
        "content-type",                "sec-ch-ua-platform-version",
    }, &.{
        "sec-ch-ua",       "sec-ch-ua-mobile",   "sec-ch-ua-full-version",
        "sec-ch-ua-arch",  "sec-ch-ua-platform", "sec-ch-ua-platform-version",
        "sec-ch-ua-model", "sec-ch-ua-bitness",  "sec-ch-ua-full-version-list",
        "user-agent",      "content-type",
    });
}

test "blink header order: one author header moves by name, not by count" {
    const engine = [_][]const u8{ "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "user-agent" };

    // Same count, same insertion, four different names, four different
    // positions -- and x-probe-long-name pushes user-agent past sec-ch-ua.
    try expectOrder(
        &.{ "sec-ch-ua-platform", "user-agent", "x-probe", "sec-ch-ua", "sec-ch-ua-mobile" },
        &([_][]const u8{"x-probe"} ++ engine),
    );
    try expectOrder(
        &.{ "sec-ch-ua-platform", "user-agent", "sec-ch-ua", "x-zulu", "sec-ch-ua-mobile" },
        &([_][]const u8{"x-zulu"} ++ engine),
    );
    try expectOrder(
        &.{ "a-aaa", "sec-ch-ua-platform", "user-agent", "sec-ch-ua", "sec-ch-ua-mobile" },
        &([_][]const u8{"a-aaa"} ++ engine),
    );
    try expectOrder(
        &.{ "sec-ch-ua-platform", "x-probe-long-name", "sec-ch-ua", "user-agent", "sec-ch-ua-mobile" },
        &([_][]const u8{"x-probe-long-name"} ++ engine),
    );
}

test "blink header order: more author headers rehash the whole block" {
    const engine = [_][]const u8{ "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "user-agent" };

    try expectOrder(&.{
        "x-zeta", "x-mid", "x-alpha", "sec-ch-ua-platform", "user-agent", "sec-ch-ua", "sec-ch-ua-mobile",
    }, &([_][]const u8{ "x-zeta", "x-alpha", "x-mid" } ++ engine));

    // Eight names cross a doubling, and the engine's own fields scatter: this is
    // the shape that no fixed slot can express.
    try expectOrder(&.{
        "x-zeta",           "x-alpha", "sec-ch-ua-platform", "sec-ch-ua",
        "sec-ch-ua-mobile", "x-beta",  "x-mid",              "user-agent",
    }, &([_][]const u8{ "x-zeta", "x-alpha", "x-mid", "x-beta" } ++ engine));

    // Nine names, and one of the three cases that pin the engine's own insertion
    // order: move sec-ch-ua-platform behind sec-ch-ua-mobile here and
    // sec-ch-ua-platform leaves the front, which Chrome does not do.
    try expectOrder(&.{
        "sec-ch-ua-platform", "x-ee", "x-aa",       "sec-ch-ua", "sec-ch-ua-mobile",
        "x-bb",               "x-cc", "user-agent", "x-dd",
    }, &([_][]const u8{ "x-aa", "x-bb", "x-cc", "x-dd", "x-ee" } ++ engine));
}

test "blink header order: the header names real guards send" {
    const engine = [_][]const u8{ "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "user-agent" };

    try expectOrder(&.{
        "x-kpsdk-ct", "x-kpsdk-v", "sec-ch-ua-platform", "user-agent", "sec-ch-ua", "sec-ch-ua-mobile",
    }, &([_][]const u8{ "x-kpsdk-ct", "x-kpsdk-v" } ++ engine));

    try expectOrder(&.{
        "sec-ch-ua-platform", "user-agent", "sec-ch-ua", "x-datadome-clientid", "sec-ch-ua-mobile",
    }, &([_][]const u8{"x-datadome-clientid"} ++ engine));

    try expectOrder(&.{
        "sec-ch-ua-platform", "authorization", "x-requested-with", "user-agent", "sec-ch-ua", "sec-ch-ua-mobile",
    }, &([_][]const u8{ "authorization", "x-requested-with" } ++ engine));

    // Page-set Content-Type is just an author header, in the order the page set
    // it -- it is not the engine's own copy.
    try expectOrder(&.{
        "x-ts", "sec-ch-ua-platform", "x-sig", "user-agent", "sec-ch-ua", "content-type", "sec-ch-ua-mobile",
    }, &([_][]const u8{ "content-type", "x-sig", "x-ts" } ++ engine));
}

test "blink header order: case folding, and refusing to guess past the table" {
    const engine = [_][]const u8{ "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "user-agent" };

    // The wire keeps the page's casing; the hash does not see it.
    try testing.expectEqual(nameHash("x-mixed-case"), nameHash("X-MiXeD-CaSe"));
    try expectOrder(
        &.{ "sec-ch-ua-platform", "X-MiXeD-CaSe", "user-agent", "sec-ch-ua", "sec-ch-ua-mobile" },
        &([_][]const u8{"X-MiXeD-CaSe"} ++ engine),
    );

    var order: [max_names]u8 = undefined;
    const too_many: [max_names + 1][]const u8 = @splat("x-a");
    try testing.expectEqual(null, bucketOrder(&too_many, &order));
}
