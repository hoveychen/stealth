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

//! `navigator.mediaSession.metadata` and what goes in it.
//!
//! This is one of the few objects in the batch a page really builds and reads
//! back -- what a media site puts here is what the OS shows on the lock screen
//! -- so it behaves rather than just existing. The artwork is normalised the
//! way Chrome normalises it: every MediaImage becomes {sizes, src, type} with
//! empty-string defaults and its `src` resolved against the document base, and
//! a fresh array comes back on every read.
//!
//! `ChapterInformation` is here because Chrome 150 has it on window and we did
//! not. It is not on CreepJS's Chrome 115 key list, which is exactly why the
//! list is a floor and not the scope.
//!
//! Known gap, shared with every other FrozenArray in this engine: Chrome
//! freezes the arrays these getters return and the vendored V8 C API has no
//! `SetIntegrityLevel` binding, so `Object.isFrozen(m.artwork)` is false here
//! and true there. Same limitation as navigator/usb.zig and webxr/session.zig.
//!
//! Measured on a headed Chrome 150 over http://localhost (p64, p65).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const URL = @import("../URL.zig");
const dictionary = @import("../dictionary.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ MediaMetadata, ChapterInformation };
}

/// A normalised MediaImage. Field order is Chrome's serialisation order:
/// alphabetical, not the order the page wrote them.
pub const MediaImage = struct {
    sizes: []const u8,
    src: []const u8,
    type: []const u8,
};

/// Reads `sequence<MediaImage>`. The two wordings differ by more than a prefix:
/// from the constructor Chrome names the enclosing MediaMetadataInit, from the
/// setter it does not (measured), so the caller hands in the reader that
/// produces its own chain rather than one being derived here.
fn readArtwork(
    comptime Image: type,
    comptime not_a_sequence: []const u8,
    comptime not_iterable: []const u8,
    value_: ?js.Value,
    exec: *const Execution,
) ![]const MediaImage {
    const value = value_ orelse return &.{};
    if (value.isNullOrUndefined()) {
        return &.{};
    }
    if (!value.isObject()) {
        return dictionary.throwTypeError(not_a_sequence, exec);
    }
    if (!value.isArray()) {
        return dictionary.throwTypeError(not_iterable, exec);
    }

    const array = value.toArray();
    const out = try exec.arena.alloc(MediaImage, array.len());
    for (out, 0..) |*slot, i| {
        const image = try Image.read(try array.get(@intCast(i)), exec);
        const src = try (try image.required("src", exec)).toStringSliceWithAlloc(exec.call_arena);
        slot.* = .{
            .sizes = try image.string("sizes", "", exec.arena),
            // The *executing* global's base, so an iframe resolves against its own
            // document rather than the top one.
            .src = try URL.resolve(exec.arena, exec.js.global.base(), src, .{}),
            .type = try image.string("type", "", exec.arena),
        };
    }
    return out;
}

pub const MediaMetadata = struct {
    _title: []const u8 = "",
    _artist: []const u8 = "",
    _album: []const u8 = "",
    _artwork: []const MediaImage = &.{},
    _chapters: []const *ChapterInformation = &.{},

    const Init = dictionary.Reader("MediaMetadata", "MediaMetadataInit");
    const CtorImage = dictionary.Nested(Init, "artwork", "MediaImage");
    const ctor_not_a_sequence = Init.message_prefix ++ "Failed to read the 'artwork' property from " ++
        "'MediaMetadataInit': The provided value cannot be converted to a sequence.";
    const ctor_not_iterable = Init.message_prefix ++ "Failed to read the 'artwork' property from " ++
        "'MediaMetadataInit': The object must have a callable @@iterator property.";

    /// The setter's chain starts at the property, with no init dictionary in
    /// between (measured on the missing-`src` case). The two sequence-shape
    /// messages below are the same wording one level up; those two were not
    /// measured separately.
    const SetterImage = dictionary.SetterReader("MediaMetadata", "artwork", "MediaImage");
    const setter_not_a_sequence = SetterImage.message_prefix ++
        "The provided value cannot be converted to a sequence.";
    const setter_not_iterable = SetterImage.message_prefix ++
        "The object must have a callable @@iterator property.";

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*MediaMetadata {
        const init = try Init.read(options_, exec);

        var chapters: []const *ChapterInformation = &.{};
        if (try init.present("chapterInfo")) |value| {
            chapters = try readChapters(value, exec);
        }

        return exec._factory.create(MediaMetadata{
            ._title = try init.string("title", "", exec.arena),
            ._artist = try init.string("artist", "", exec.arena),
            ._album = try init.string("album", "", exec.arena),
            ._artwork = try readArtwork(
                CtorImage,
                ctor_not_a_sequence,
                ctor_not_iterable,
                try init.present("artwork"),
                exec,
            ),
            ._chapters = chapters,
        });
    }

    fn readChapters(value: js.Value, exec: *const Execution) ![]const *ChapterInformation {
        if (!value.isArray()) {
            return &.{};
        }
        const Chapter = dictionary.Nested(Init, "chapterInfo", "ChapterInformationInit");
        const array = value.toArray();
        const out = try exec.arena.alloc(*ChapterInformation, array.len());
        for (out, 0..) |*slot, i| {
            const entry = try Chapter.read(try array.get(@intCast(i)), exec);
            const ChapterImage = dictionary.Nested(Chapter, "artwork", "MediaImage");
            slot.* = try exec._factory.create(ChapterInformation{
                ._title = try entry.string("title", "", exec.arena),
                ._start_time = try entry.double("startTime", 0, exec),
                ._artwork = try readArtwork(
                    ChapterImage,
                    Chapter.message_prefix ++ "Failed to read the 'artwork' property from " ++
                        "'ChapterInformationInit': The provided value cannot be converted to a sequence.",
                    Chapter.message_prefix ++ "Failed to read the 'artwork' property from " ++
                        "'ChapterInformationInit': The object must have a callable @@iterator property.",
                    try entry.present("artwork"),
                    exec,
                ),
            });
        }
        return out;
    }

    pub fn getTitle(self: *const MediaMetadata) []const u8 {
        return self._title;
    }

    pub fn setTitle(self: *MediaMetadata, value: []const u8, exec: *const Execution) !void {
        self._title = try exec.arena.dupe(u8, value);
    }

    pub fn getArtist(self: *const MediaMetadata) []const u8 {
        return self._artist;
    }

    pub fn setArtist(self: *MediaMetadata, value: []const u8, exec: *const Execution) !void {
        self._artist = try exec.arena.dupe(u8, value);
    }

    pub fn getAlbum(self: *const MediaMetadata) []const u8 {
        return self._album;
    }

    pub fn setAlbum(self: *MediaMetadata, value: []const u8, exec: *const Execution) !void {
        self._album = try exec.arena.dupe(u8, value);
    }

    /// A fresh array on every read, which is what Chrome does (measured:
    /// `m.artwork !== m.artwork`).
    pub fn getArtwork(self: *const MediaMetadata) []const MediaImage {
        return self._artwork;
    }

    pub fn setArtwork(self: *MediaMetadata, value: ?js.Value, exec: *const Execution) !void {
        self._artwork = try readArtwork(
            SetterImage,
            setter_not_a_sequence,
            setter_not_iterable,
            value,
            exec,
        );
    }

    pub fn getChapterInfo(self: *const MediaMetadata) []const *ChapterInformation {
        return self._chapters;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaMetadata);

        pub const Meta = struct {
            pub const name = "MediaMetadata";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaMetadata.constructor, .{});

        // Chrome's own prototype order.
        pub const title = bridge.accessor(MediaMetadata.getTitle, MediaMetadata.setTitle, .{});
        pub const artist = bridge.accessor(MediaMetadata.getArtist, MediaMetadata.setArtist, .{});
        pub const album = bridge.accessor(MediaMetadata.getAlbum, MediaMetadata.setAlbum, .{});
        pub const artwork = bridge.accessor(MediaMetadata.getArtwork, MediaMetadata.setArtwork, .{});
        // Read-only: assigning to it is silently dropped (measured).
        pub const chapterInfo = bridge.accessor(MediaMetadata.getChapterInfo, null, .{});
    };
};

/// One chapter of a long recording. Read-only, and only ever minted through a
/// MediaMetadata's `chapterInfo` -- `new ChapterInformation()` is illegal.
pub const ChapterInformation = struct {
    _title: []const u8 = "",
    _start_time: f64 = 0,
    _artwork: []const MediaImage = &.{},

    pub fn getTitle(self: *const ChapterInformation) []const u8 {
        return self._title;
    }

    pub fn getStartTime(self: *const ChapterInformation) f64 {
        return self._start_time;
    }

    pub fn getArtwork(self: *const ChapterInformation) []const MediaImage {
        return self._artwork;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChapterInformation);

        pub const Meta = struct {
            pub const name = "ChapterInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const title = bridge.accessor(ChapterInformation.getTitle, null, .{});
        pub const startTime = bridge.accessor(ChapterInformation.getStartTime, null, .{});
        pub const artwork = bridge.accessor(ChapterInformation.getArtwork, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaMetadata" {
    try testing.htmlRunner("media/metadata.html", .{});
}
