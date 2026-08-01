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

// The one place that answers "can this browser handle this media type?".
//
// Three APIs ask it — HTMLMediaElement.canPlayType(), MediaSource.isTypeSupported()
// and MediaRecorder.isTypeSupported() — and fingerprinting scripts read all
// three and compare them. CreepJS renders the whole grid for twelve types. They
// have to come from one table or they will contradict each other, which is a
// louder signal than any single wrong answer.
//
// The table is Chrome's, measured by tools/fingerprint/dump-media-mimes.mjs.
// The rule it encodes, which that generator verifies against types it was not
// fitted to: no codecs parameter means the container's bare answer, and a
// codecs parameter means every codec listed must be one the container accepts
// for that API.

const std = @import("std");

const chrome_mimes = @import("chrome_mimes.zig");

pub const PlayResponse = chrome_mimes.PlayResponse;

pub const Api = enum { play, media_source, media_recorder };

// A parsed `type/subtype; codecs="a, b"`. The codecs are left as a slice of the
// input so nothing needs allocating.
const Parsed = struct {
    container: []const u8,
    codecs: []const u8,
    has_codecs: bool,
};

fn parse(mime_type: []const u8) Parsed {
    const trimmed = std.mem.trim(u8, mime_type, &std.ascii.whitespace);
    const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse {
        return .{ .container = trimmed, .codecs = "", .has_codecs = false };
    };

    const container = std.mem.trim(u8, trimmed[0..semi], &std.ascii.whitespace);
    var rest = std.mem.trim(u8, trimmed[semi + 1 ..], &std.ascii.whitespace);

    // `codecs` is the only parameter any of the three APIs reads.
    if (rest.len < "codecs=".len or !std.ascii.eqlIgnoreCase(rest[0.."codecs".len], "codecs")) {
        return .{ .container = container, .codecs = "", .has_codecs = false };
    }
    rest = std.mem.trimStart(u8, rest["codecs".len..], &std.ascii.whitespace);
    if (rest.len == 0 or rest[0] != '=') {
        return .{ .container = container, .codecs = "", .has_codecs = false };
    }
    rest = std.mem.trim(u8, rest[1..], &std.ascii.whitespace);
    // The quotes are optional: `codecs=vp8` and `codecs="vp8"` are both read.
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') {
        rest = rest[1 .. rest.len - 1];
    }

    // An empty codecs parameter is treated as if it were absent (measured:
    // `video/mp4; codecs=""` answers "maybe", the bare answer, not "").
    const codecs = std.mem.trim(u8, rest, &std.ascii.whitespace);
    return .{ .container = container, .codecs = codecs, .has_codecs = codecs.len > 0 };
}

fn find(container: []const u8) ?*const chrome_mimes.Container {
    for (&chrome_mimes.containers) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, container)) {
            return entry;
        }
    }
    return null;
}

fn accepts(list: []const []const u8, codec: []const u8) bool {
    for (list) |known| {
        if (std.mem.eql(u8, known, codec)) {
            return true;
        }
    }
    return false;
}

fn everyCodecAccepted(codecs: []const u8, list: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, codecs, ',');
    while (it.next()) |raw| {
        const codec = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (codec.len == 0) {
            continue;
        }
        if (!accepts(list, codec)) {
            return false;
        }
    }
    return true;
}

// HTMLMediaElement.canPlayType(). Chrome answers the same on an <audio> and a
// <video> element — the generator asserts that rather than assuming it — so
// there is one implementation.
pub fn canPlayType(mime_type: []const u8) PlayResponse {
    const parsed = parse(mime_type);
    const entry = find(parsed.container) orelse return .no;
    if (!parsed.has_codecs) {
        return entry.bare_play;
    }
    return if (everyCodecAccepted(parsed.codecs, entry.play_codecs)) .probably else .no;
}

pub fn isTypeSupported(api: Api, mime_type: []const u8) bool {
    std.debug.assert(api != .play);

    const parsed = parse(mime_type);
    if (parsed.container.len == 0) {
        // MediaRecorder reads the empty string as "pick a default" and answers
        // true; MediaSource answers false.
        return switch (api) {
            .media_source => chrome_mimes.empty_type_mse,
            .media_recorder => chrome_mimes.empty_type_mr,
            .play => unreachable,
        };
    }

    const entry = find(parsed.container) orelse return false;
    if (!parsed.has_codecs) {
        return switch (api) {
            .media_source => entry.bare_mse,
            .media_recorder => entry.bare_mr,
            .play => unreachable,
        };
    }
    return everyCodecAccepted(parsed.codecs, switch (api) {
        .media_source => entry.mse_codecs,
        .media_recorder => entry.mr_codecs,
        .play => unreachable,
    });
}

const testing = std.testing;

test "media mime: bare containers answer the container's own answer" {
    try testing.expectEqual(PlayResponse.probably, canPlayType("audio/mpeg"));
    try testing.expectEqual(PlayResponse.maybe, canPlayType("video/mp4"));
    try testing.expectEqual(PlayResponse.maybe, canPlayType("audio/ogg"));
    try testing.expectEqual(PlayResponse.no, canPlayType("video/quicktime"));
    try testing.expectEqual(PlayResponse.no, canPlayType("bogus/type"));
}

test "media mime: a codecs parameter has to be satisfied in full" {
    try testing.expectEqual(PlayResponse.probably, canPlayType("video/mp4; codecs=\"avc1.42E01E\""));
    try testing.expectEqual(PlayResponse.probably, canPlayType("video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\""));
    // One unsupported codec in the list is enough to make the whole type no.
    try testing.expectEqual(PlayResponse.no, canPlayType("video/mp4; codecs=\"avc1.42E01E, bogus\""));
    try testing.expectEqual(PlayResponse.no, canPlayType("video/mp4; codecs=\"bogus\""));
    // Chrome 150 does not decode Theora.
    try testing.expectEqual(PlayResponse.no, canPlayType("video/ogg; codecs=\"theora\""));
}

test "media mime: an empty codecs parameter reads as absent" {
    try testing.expectEqual(PlayResponse.maybe, canPlayType("video/mp4; codecs=\"\""));
    try testing.expectEqual(PlayResponse.maybe, canPlayType("video/mp4"));
}

test "media mime: quoting and spacing around the parameter are optional" {
    try testing.expectEqual(PlayResponse.probably, canPlayType("video/mp4;codecs=avc1.42E01E"));
    try testing.expectEqual(PlayResponse.probably, canPlayType("video/mp4 ; codecs=\"avc1.42E01E\""));
    try testing.expectEqual(PlayResponse.probably, canPlayType("video/mp4; CODECS=\"avc1.42E01E\""));
    try testing.expectEqual(PlayResponse.probably, canPlayType("VIDEO/MP4; codecs=\"avc1.42E01E\""));
}

test "media mime: the three APIs disagree, and that is the point" {
    // audio/mpeg plays and demuxes but cannot be recorded.
    try testing.expectEqual(PlayResponse.probably, canPlayType("audio/mpeg"));
    try testing.expect(isTypeSupported(.media_source, "audio/mpeg"));
    try testing.expect(!isTypeSupported(.media_recorder, "audio/mpeg"));

    // video/webm records bare but MediaSource needs a codec named.
    try testing.expect(!isTypeSupported(.media_source, "video/webm"));
    try testing.expect(isTypeSupported(.media_recorder, "video/webm"));
    try testing.expect(isTypeSupported(.media_source, "video/webm; codecs=\"vp8\""));

    // MediaRecorder takes opus in webm where MediaSource also takes vorbis.
    try testing.expect(isTypeSupported(.media_recorder, "audio/webm; codecs=\"opus\""));
    try testing.expect(!isTypeSupported(.media_recorder, "audio/webm; codecs=\"vorbis\""));
    try testing.expect(isTypeSupported(.media_source, "audio/webm; codecs=\"vorbis\""));
}

test "media mime: the empty string splits the two isTypeSupported answers" {
    try testing.expect(!isTypeSupported(.media_source, ""));
    try testing.expect(isTypeSupported(.media_recorder, ""));
}
