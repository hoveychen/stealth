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

// Four of the codecs a `codecs=` parameter can name are not names at all.
// `avc1.42c00d`, `hvc1.1.6.L186.B0`, `av01.0.19M.08` and `vp09.00.51.08` each
// pack a profile, a level, and sometimes a tier and a bit depth into one
// string, and Chrome parses those fields rather than looking the whole string
// up. So a table that measured `avc1.42E01E` has, without knowing it, also
// measured every other level of the same profile — which is what Kasada asked
// for on hyatt.com and got a wrong answer to, because the measured table only
// held the handful of spellings the generator happened to try.
//
// This reduces such a codec to a family-and-profile key. Two codec strings that
// reduce to the same key answer alike in every container, which is the rule the
// generator verifies before it writes the table.
//
// Measured (macOS Chrome, tools/fingerprint/probes/media-codec-family-sweep.js):
// the profile is what moves the answer and the level does not. In video/mp4,
// avc1 profiles 42/4D/58/64 record while 6E does not and 7A/F4 are only
// "maybe"; hvc1 profile 1 records where profile 2 does not; av01 profile 0
// records where 1 and 2 do not. Every level of a given profile agrees.
//
// Two divergences this leaves, both measured and both the answer the engine
// already gave before any of this:
//
//   * A recognised profile at an unparsable level — `avc1.42E0FF` — is read
//     here as unsupported, where Chrome says "maybe" to canPlayType and true to
//     MediaSource. Chrome's parser keeps the codec and drops the level; ours
//     rejects it, so the answer stays the "" it was.
//   * An HEVC profile number the table never measured — `hvc1.9.6.L186.B0` —
//     is unsupported here and "probably" in Chrome, which appears to fold every
//     unknown profile onto its Main one.

const std = @import("std");

/// Enough for the longest key any family produces (`vp09.` plus a profile).
pub const key_len_max = 16;

pub const Match = union(enum) {
    /// Not one of the parametrised families. Match the string as written.
    literal,
    /// One of them, but the parameters are not ones Chrome's parser accepts,
    /// which it reads as an unsupported codec rather than an absent one.
    invalid,
    /// The family-and-profile key, written into the caller's buffer.
    key: []const u8,
};

// The profile_idc bytes Chrome's ParseAVCCodecId knows. Measured: 0x42, 0x4D,
// 0x53, 0x56, 0x58, 0x64, 0x6E, 0x76, 0x7A, 0x80 and 0xF4 all parse, and their
// immediate neighbours — 0x2C, 0x63, 0x65, 0x6D, 0x79, 0xF3, 0x00, 0xFF — do
// not, so this is the whole set rather than a range.
const avc_profiles = [_]u8{ 0x42, 0x4D, 0x53, 0x56, 0x58, 0x64, 0x6E, 0x76, 0x7A, 0x80, 0xF4 };

// level_idc as ten times the level number, so 1.3 is 13 and 6.2 is 62, plus 9
// for the level Annex A spells "1b".
const avc_levels = [_]u8{ 9, 10, 11, 12, 13, 20, 21, 22, 30, 31, 32, 40, 41, 42, 50, 51, 52, 60, 61, 62 };

const vp9_levels = [_]u8{ 10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 52, 60, 61, 62 };

fn known(set: []const u8, value: u8) bool {
    return std.mem.indexOfScalar(u8, set, value) != null;
}

/// Reduces a codec to the key it shares with every other member of its family
/// and profile.
pub fn classify(codec: []const u8, buf: *[key_len_max]u8) Match {
    // The four-character code is matched as written: Chrome takes `avc1.42E01E`
    // and not `AVC1.42E01E`, and the generator measures that.
    if (std.mem.startsWith(u8, codec, "avc1.") or std.mem.startsWith(u8, codec, "avc3.")) {
        return avc(codec["avc1.".len..], buf);
    }
    if (std.mem.startsWith(u8, codec, "hvc1.") or std.mem.startsWith(u8, codec, "hev1.")) {
        return hevc(codec["hvc1.".len..], buf);
    }
    if (std.mem.startsWith(u8, codec, "av01.")) {
        return av1(codec["av01.".len..], buf);
    }
    if (std.mem.startsWith(u8, codec, "vp09.")) {
        return vp9(codec["vp09.".len..], buf);
    }
    return .literal;
}

// `avc1.PPCCLL` — profile, constraint flags and level as three hex bytes. The
// constraint byte only picks between baseline and constrained baseline, which
// no API here answers differently, so it does not reach the key.
fn avc(rest: []const u8, buf: *[key_len_max]u8) Match {
    if (rest.len != 6) {
        return .invalid;
    }
    for (rest) |c| {
        if (!std.ascii.isHex(c)) {
            return .invalid;
        }
    }
    const packed_id = std.fmt.parseUnsigned(u24, rest, 16) catch return .invalid;
    const profile: u8 = @intCast(packed_id >> 16);
    const level: u8 = @truncate(packed_id);
    if (!known(&avc_profiles, profile) or !known(&avc_levels, level)) {
        return .invalid;
    }
    return .{ .key = std.fmt.bufPrint(buf, "avc.{x:0>2}", .{profile}) catch unreachable };
}

// `hvc1.<profile>.<compatibility>.<tier><level>[.<constraints>…]`. Chrome wants
// the first three fields and ignores what follows; measured, `hvc1.1.6.L186`
// answers and `hvc1.1.6` does not.
fn hevc(rest: []const u8, buf: *[key_len_max]u8) Match {
    var it = std.mem.splitScalar(u8, rest, '.');
    const profile = it.next() orelse return .invalid;
    if (profile.len == 0 or profile.len > 3) {
        return .invalid;
    }
    // The compatibility flags and the tier-and-level field both have to be
    // there; anything after them is constraint bytes Chrome tolerates.
    const compatibility = it.next() orelse return .invalid;
    const tier_level = it.next() orelse return .invalid;
    if (compatibility.len == 0 or tier_level.len < 2) {
        return .invalid;
    }
    if (tier_level[0] != 'L' and tier_level[0] != 'H') {
        return .invalid;
    }
    return .{ .key = std.fmt.bufPrint(buf, "hevc.{s}", .{profile}) catch return .invalid };
}

// `av01.<profile>.<level><tier>.<depth>[…]`. The profile is one digit, the
// level two, the tier M or H, the depth 08, 10 or 12.
fn av1(rest: []const u8, buf: *[key_len_max]u8) Match {
    var it = std.mem.splitScalar(u8, rest, '.');
    const profile = it.next() orelse return .invalid;
    const level_tier = it.next() orelse return .invalid;
    const depth = it.next() orelse return .invalid;

    if (profile.len != 1 or profile[0] < '0' or profile[0] > '2') {
        return .invalid;
    }
    if (level_tier.len != 3 or (level_tier[2] != 'M' and level_tier[2] != 'H')) {
        return .invalid;
    }
    const level = twoDigits(level_tier[0..2]) orelse return .invalid;
    if (level > 31) {
        return .invalid;
    }
    if (!std.mem.eql(u8, depth, "08") and !std.mem.eql(u8, depth, "10") and !std.mem.eql(u8, depth, "12")) {
        return .invalid;
    }
    return .{ .key = std.fmt.bufPrint(buf, "av1.{s}", .{profile}) catch unreachable };
}

// `vp09.<profile>.<level>.<depth>[…]`, every field two digits.
fn vp9(rest: []const u8, buf: *[key_len_max]u8) Match {
    var it = std.mem.splitScalar(u8, rest, '.');
    const profile_field = it.next() orelse return .invalid;
    const level_field = it.next() orelse return .invalid;
    const depth_field = it.next() orelse return .invalid;

    if (profile_field.len != 2) {
        return .invalid;
    }
    const profile = twoDigits(profile_field) orelse return .invalid;
    if (profile > 3) {
        return .invalid;
    }
    const level = twoDigits(level_field) orelse return .invalid;
    if (!known(&vp9_levels, level)) {
        return .invalid;
    }
    const depth = twoDigits(depth_field) orelse return .invalid;
    if (depth != 8 and depth != 10 and depth != 12) {
        return .invalid;
    }
    return .{ .key = std.fmt.bufPrint(buf, "vp09.{s}", .{profile_field}) catch unreachable };
}

fn twoDigits(field: []const u8) ?u8 {
    if (field.len != 2 or !std.ascii.isDigit(field[0]) or !std.ascii.isDigit(field[1])) {
        return null;
    }
    return (field[0] - '0') * 10 + (field[1] - '0');
}

const testing = std.testing;

fn expectKey(expected: []const u8, codec: []const u8) !void {
    var buf: [key_len_max]u8 = undefined;
    switch (classify(codec, &buf)) {
        .key => |k| try testing.expectEqualStrings(expected, k),
        else => return error.NotAKey,
    }
}

fn expectInvalid(codec: []const u8) !void {
    var buf: [key_len_max]u8 = undefined;
    try testing.expectEqual(Match.invalid, classify(codec, &buf));
}

fn expectLiteral(codec: []const u8) !void {
    var buf: [key_len_max]u8 = undefined;
    try testing.expectEqual(Match.literal, classify(codec, &buf));
}

test "codec: every level of an AVC profile shares one key" {
    try expectKey("avc.42", "avc1.42E01E");
    try expectKey("avc.42", "avc1.42c00d");
    try expectKey("avc.42", "avc1.42C00D");
    try expectKey("avc.64", "avc1.64003E");
    try expectKey("avc.64", "avc1.64001E");
    try expectKey("avc.4d", "avc1.4d001f");
    // avc3 is the same codec in a different sample entry, and answers alike.
    try expectKey("avc.64", "avc3.64003E");
    try expectKey("avc.42", "avc3.42E01E");
}

test "codec: an AVC profile or level Chrome's parser rejects is unsupported" {
    // 0x2C, 0x63, 0x65, 0x6D, 0x79 and 0xF3 all sit next to a profile that
    // parses, and none of them do.
    try expectInvalid("avc1.2C001E");
    try expectInvalid("avc1.63001E");
    try expectInvalid("avc1.6D001E");
    try expectInvalid("avc1.F3001E");
    try expectInvalid("avc1.00001E");
    try expectInvalid("avc1.FF001E");
    // Six hex digits exactly.
    try expectInvalid("avc1.42E01");
    try expectInvalid("avc1.42E01EE");
    try expectInvalid("avc1.42E01G");
    try expectInvalid("avc1.");
    try expectInvalid("avc1.42");
    // Levels are Annex A's, so 0xFF and 0x00 are not levels.
    try expectInvalid("avc1.42E0FF");
    try expectInvalid("avc1.42E000");
}

test "codec: HEVC keys on the profile and needs three fields" {
    try expectKey("hevc.1", "hvc1.1.6.L93.B0");
    try expectKey("hevc.1", "hvc1.1.6.L186.B0");
    try expectKey("hevc.1", "hev1.1.6.L186.B0");
    try expectKey("hevc.1", "hvc1.1.6.H186.B0");
    try expectKey("hevc.1", "hvc1.1.6.L186");
    try expectKey("hevc.2", "hvc1.2.4.L120.B0");
    try expectInvalid("hvc1.1.6");
    try expectInvalid("hvc1.1");
    try expectInvalid("hvc1.1.6.X186.B0");
}

test "codec: AV1 keys on the profile and validates the tier and depth" {
    try expectKey("av1.0", "av01.0.05M.08");
    try expectKey("av1.0", "av01.0.19M.08");
    try expectKey("av1.0", "av01.0.19H.08");
    try expectKey("av1.0", "av01.0.19M.12");
    try expectKey("av1.1", "av01.1.19M.08");
    try expectKey("av1.2", "av01.2.19M.10");
    // Profile 3 does not exist, 09 is not a bit depth, 32 is past the last
    // level, and the tier is M or H.
    try expectInvalid("av01.3.19M.08");
    try expectInvalid("av01.0.19M.09");
    try expectInvalid("av01.0.32M.08");
    try expectInvalid("av01.0.19X.08");
    try expectInvalid("av01.0.19M");
}

test "codec: VP9's new-style string keys on the profile" {
    try expectKey("vp09.00", "vp09.00.10.08");
    try expectKey("vp09.00", "vp09.00.51.08");
    try expectKey("vp09.02", "vp09.02.10.10");
    try expectKey("vp09.03", "vp09.03.10.10");
    try expectInvalid("vp09.04.10.08");
    try expectInvalid("vp09.00.99.08");
    try expectInvalid("vp09.00.10.09");
    try expectInvalid("vp09.00.10");
}

test "codec: a codec with no parameters is matched as written" {
    // MediaRecorder's short names, which mean "whatever you would pick".
    try expectLiteral("avc1");
    try expectLiteral("avc3");
    try expectLiteral("av01");
    try expectLiteral("vp09");
    try expectLiteral("vp8");
    try expectLiteral("vp9");
    try expectLiteral("opus");
    // mp4a's object type indication is not a profile in this sense: mp4a.40.2
    // records where mp4a.40.5 does not, so the two must not share a key.
    try expectLiteral("mp4a.40.2");
    try expectLiteral("mp4a.40.5");
    try expectLiteral("mp4a.69");
    try expectLiteral("dvh1.05.07");
}
