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

// Which image format a canvas is being asked for, and the one place that
// decides it. `HTMLCanvasElement.toDataURL`, `HTMLCanvasElement.toBlob` and
// `OffscreenCanvas.convertToBlob` all read their type and quality the same way
// (measured on Chrome 141, probes/canvas-encode-types.js), so they read them
// through here rather than each growing its own copy.

const std = @import("std");

const js = @import("../../js/js.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
const webp = @import("webp.zig");

const Allocator = std.mem.Allocator;

/// The three types Chrome encodes. Everything else in the IANA image registry
/// falls back to PNG, which is what the spec says an unsupported type does --
/// so this enum is also the whole of what a page can read back here.
pub const Format = enum {
    png,
    jpeg,
    webp,

    /// Chrome matches the whole string, ASCII case-insensitively. Measured:
    /// `IMAGE/JPEG` is JPEG, while `image/jpg`, `image/jpeg ` and
    /// `image/jpeg;q=1` are all PNG -- there is no prefix match and no
    /// parameter parsing, so a type carrying anything at all beyond the name
    /// misses.
    pub fn fromType(mime: ?[]const u8) Format {
        const requested = mime orelse return .png;
        if (std.ascii.eqlIgnoreCase(requested, "image/jpeg")) {
            return .jpeg;
        }
        if (std.ascii.eqlIgnoreCase(requested, "image/webp")) {
            return .webp;
        }
        return .png;
    }

    pub fn mimeType(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }
};

/// The `quality` argument is declared `any`, not `double`, and Blink only
/// listens to it when it really is a number inside [0, 1]. Measured: -1, 2,
/// NaN, the string 'x', null and true all leave the default in place, while 0
/// is a real request and makes a visibly smaller JPEG.
pub fn quality(value: ?js.Value) f64 {
    const given = value orelse return jpeg.default_quality;
    if (!given.isNumber()) {
        return jpeg.default_quality;
    }
    const number = given.toF64() catch return jpeg.default_quality;
    if (!(number >= 0 and number <= 1)) {
        return jpeg.default_quality;
    }
    return number;
}

/// `pixels` is straight-alpha RGBA8, or null for a canvas that was never drawn
/// into. Each encoder takes the transparency from there: PNG and WebP keep it,
/// JPEG has nowhere to put it and composites onto black.
pub fn encode(
    allocator: Allocator,
    format: Format,
    width: u32,
    height: u32,
    pixels: ?[]const u8,
    image_quality: f64,
) ![]u8 {
    return switch (format) {
        .png => png.encode(allocator, width, height, pixels),
        .jpeg => jpeg.encode(allocator, width, height, pixels, image_quality),
        // Lossless, so there is no quality to spend; see webp.zig.
        .webp => webp.encode(allocator, width, height, pixels),
    };
}

/// `encode`, base64'd behind the `data:` prefix the format names.
pub fn dataUrl(
    allocator: Allocator,
    format: Format,
    width: u32,
    height: u32,
    pixels: ?[]const u8,
    image_quality: f64,
) ![]u8 {
    const bytes = try encode(allocator, format, width, height, pixels, image_quality);
    defer allocator.free(bytes);

    const encoder = std.base64.standard.Encoder;
    const mime = format.mimeType();

    const url = try allocator.alloc(u8, "data:".len + mime.len + ";base64,".len + encoder.calcSize(bytes.len));
    errdefer allocator.free(url);

    var at: usize = 0;
    for ([_][]const u8{ "data:", mime, ";base64," }) |part| {
        @memcpy(url[at..][0..part.len], part);
        at += part.len;
    }
    _ = encoder.encode(url[at..], bytes);
    return url;
}

const testing = std.testing;

test "encode: the type is matched whole and case-insensitively" {
    try testing.expectEqual(Format.png, Format.fromType(null));
    try testing.expectEqual(Format.png, Format.fromType("image/png"));
    try testing.expectEqual(Format.jpeg, Format.fromType("image/jpeg"));
    try testing.expectEqual(Format.webp, Format.fromType("image/webp"));

    try testing.expectEqual(Format.jpeg, Format.fromType("IMAGE/JPEG"));
    try testing.expectEqual(Format.webp, Format.fromType("Image/WebP"));

    // Every one of these is PNG on Chrome.
    for ([_][]const u8{
        "",               "image/jpg",      "image/x-png", "image/gif",
        "image/bmp",      "image/apng",     "image/avif",  "image/svg+xml",
        "image/tiff",     "image/jxr",      " image/jpeg", "image/jpeg ",
        "image/jpeg;",    "image/jpeg;q=1", "image/webp;", "jpeg",
        "image/jpeg\x00",
    }) |mime| {
        try testing.expectEqual(Format.png, Format.fromType(mime));
    }
}

test "encode: each format writes its own magic and its own prefix" {
    const allocator = testing.allocator;

    const pixels = [_]u8{ 66, 133, 244, 255 } ** 4;
    const expected = [_]struct { format: Format, prefix: []const u8 }{
        .{ .format = .png, .prefix = "data:image/png;base64,iVBORw0KGgo" },
        // The SOI and the JFIF APP0, byte for byte what Chrome opens with.
        .{ .format = .jpeg, .prefix = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQAB" },
        // 'RIFF', then the size, then 'WEBP'.
        .{ .format = .webp, .prefix = "data:image/webp;base64,UklGR" },
    };
    for (expected) |want| {
        const url = try dataUrl(allocator, want.format, 2, 2, &pixels, jpeg.default_quality);
        defer allocator.free(url);
        try testing.expect(std.mem.startsWith(u8, url, want.prefix));
    }
}
