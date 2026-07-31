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

// A minimal 8-bit RGBA PNG writer, for `canvas.toDataURL()` and friends.
//
// The output is a correct PNG that decodes to the pixels it was given. It is
// deliberately not a byte-for-byte match for Chrome's: Chrome hands the bitmap
// to libpng, which picks a per-row filter heuristically and drives zlib at
// level 1 with a sync flush between passes, so its IDAT splits and its exact
// deflate stream are artefacts of that pipeline. Reproducing them would mean
// reimplementing zlib's match finder, and it would buy nothing while text
// still does not rasterise (see raster.zig) — any canvas fingerprint that
// draws a string diverges long before the compressor does.
//
// So: one IDAT, every row filtered with None, deflate at the default level.

const std = @import("std");

const flate = std.compress.flate;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// Encodes `width` x `height` straight-alpha RGBA8 pixels. A null `pixels`
/// means the canvas was never drawn into, i.e. every pixel is transparent
/// black; that is the common case and it avoids materialising the buffer.
pub fn encode(allocator: Allocator, width: u32, height: u32, pixels: ?[]const u8) ![]u8 {
    std.debug.assert(width > 0 and height > 0);
    if (pixels) |p| {
        std.debug.assert(p.len == @as(usize, width) * height * 4);
    }

    const image_data = try deflate(allocator, width, height, pixels);
    defer allocator.free(image_data);

    var out: Writer.Allocating = try .initCapacity(allocator, image_data.len + 64);
    errdefer out.deinit();

    try out.writer.writeAll(&signature);

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8; // bit depth
    header[9] = 6; // colour type: truecolour with alpha
    header[10] = 0; // compression: deflate
    header[11] = 0; // filter method: adaptive
    header[12] = 0; // interlace: none
    try writeChunk(&out.writer, "IHDR", &header);
    try writeChunk(&out.writer, "IDAT", image_data);
    try writeChunk(&out.writer, "IEND", &.{});

    return out.toOwnedSlice();
}

/// `encode`, base64'd and prefixed, ready to hand back from `toDataURL`.
pub fn dataUrl(allocator: Allocator, width: u32, height: u32, pixels: ?[]const u8) ![]u8 {
    const bytes = try encode(allocator, width, height, pixels);
    defer allocator.free(bytes);

    const encoder = std.base64.standard.Encoder;
    const prefix = "data:image/png;base64,";

    const url = try allocator.alloc(u8, prefix.len + encoder.calcSize(bytes.len));
    errdefer allocator.free(url);

    @memcpy(url[0..prefix.len], prefix);
    _ = encoder.encode(url[prefix.len..], bytes);
    return url;
}

/// The zlib stream for the IDAT chunk: each row prefixed with its filter type.
fn deflate(allocator: Allocator, width: u32, height: u32, pixels: ?[]const u8) ![]u8 {
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var out: Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();

    var compress: flate.Compress = try .init(&out.writer, window, .zlib, .default);

    const stride = @as(usize, width) * 4;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        // Filter type 0 (None). A real encoder would pick per row; we would
        // still not match Chrome's choices, so there is nothing to gain.
        try compress.writer.writeByte(0);
        if (pixels) |p| {
            try compress.writer.writeAll(p[row * stride ..][0..stride]);
        } else {
            try compress.writer.splatByteAll(0, stride);
        }
    }
    try compress.finish();

    return out.toOwnedSlice();
}

fn writeChunk(w: *Writer, comptime kind: *const [4:0]u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try w.writeAll(&length);
    try w.writeAll(kind);
    try w.writeAll(data);

    var crc = std.hash.crc.Crc32.init();
    crc.update(kind);
    crc.update(data);

    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try w.writeAll(&checksum);
}

const testing = std.testing;

test "png: round-trips through the standard decoder" {
    const allocator = testing.allocator;

    // A 2x1 image: opaque red, then half-transparent blue.
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 128 };
    const bytes = try encode(allocator, 2, 1, &pixels);
    defer allocator.free(bytes);

    try testing.expectEqualSlices(u8, &signature, bytes[0..8]);

    // Walk the chunks, checking every CRC, and inflate the IDAT.
    var image_data: std.ArrayList(u8) = .empty;
    defer image_data.deinit(allocator);

    var seen_end = false;
    var at: usize = 8;
    while (at < bytes.len) {
        const length = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        const data = bytes[at + 8 ..][0..length];

        var crc = std.hash.crc.Crc32.init();
        crc.update(kind);
        crc.update(data);
        try testing.expectEqual(crc.final(), std.mem.readInt(u32, bytes[at + 8 + length ..][0..4], .big));

        if (std.mem.eql(u8, kind, "IHDR")) {
            try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, data[0..4], .big));
            try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, data[4..8], .big));
            try testing.expectEqual(@as(u8, 8), data[8]);
            try testing.expectEqual(@as(u8, 6), data[9]);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try image_data.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            seen_end = true;
        }

        at += 12 + length;
    }
    try testing.expect(seen_end);
    try testing.expectEqual(bytes.len, at);

    var reader: std.Io.Reader = .fixed(image_data.items);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&reader, .zlib, &window);

    var scanlines: Writer.Allocating = .init(allocator);
    defer scanlines.deinit();
    _ = try decompress.reader.streamRemaining(&scanlines.writer);

    // One row: the filter byte, then the pixels unchanged.
    try testing.expectEqual(@as(usize, 9), scanlines.written().len);
    try testing.expectEqual(@as(u8, 0), scanlines.written()[0]);
    try testing.expectEqualSlices(u8, &pixels, scanlines.written()[1..]);
}

test "png: an undrawn canvas encodes as transparent black" {
    const allocator = testing.allocator;

    const url = try dataUrl(allocator, 10, 10, null);
    defer allocator.free(url);

    try testing.expect(std.mem.startsWith(u8, url, "data:image/png;base64,iVBORw0KGgo"));

    // Same pixels, spelled out, must give the same string.
    const explicit = [_]u8{0} ** (10 * 10 * 4);
    const other = try dataUrl(allocator, 10, 10, &explicit);
    defer allocator.free(other);
    try testing.expectEqualStrings(url, other);
}
