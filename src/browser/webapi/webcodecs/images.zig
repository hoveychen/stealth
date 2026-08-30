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

// Just enough image reading for ImageDecoder: the geometry and frame timing of
// the six types Chrome's `ImageDecoder.isTypeSupported` says yes to, plus real
// pixels for PNG.
//
// Why PNG gets pixels and the rest do not: a decoded frame's samples *are*
// readable from a page (`decode()` then `frame.copyTo()` -- measured, the
// 4x2 still comes back as 32 real BGRA bytes, win51-chrome.json), and PNG is
// the format a script can produce without leaving the engine, because
// `canvas.toDataURL()` writes one. The rest would each need their own entropy
// decoder; they report the right geometry and timing and hand back a frame
// whose pixels are transparent black. See image_decoder.zig.
//
// Everything here is driven by the *declared* type, never by sniffing: Chrome
// refuses `{data: png, type: 'nope'}` for the type and `{data: junk, type:
// 'image/png'}` for the metadata, so the two failures have to stay distinct.

const std = @import("std");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
// Only for the SVG root's `width`/`height`, which are CSS lengths rather than
// header fields; the six raster formats carry integers.
const units = @import("../../css/units.zig");

pub const Kind = enum {
    png,
    jpeg,
    gif,
    webp,
    avif,
    bmp,

    /// The format the bytes themselves declare, for the caller that has no
    /// declared type to go on: an `<img>` decides what it received by sniffing,
    /// because the header a server sends gets no say (`Frame.ImageRequest`).
    ///
    /// Deliberately not shared with `Mime.isImageSignature`, which answers a
    /// different question with a different budget: whether the bytes are a
    /// picture *at all*, from fourteen bytes, including the two types that have
    /// no geometry parser here -- ICO and SVG. This one picks a parser, so a
    /// format it cannot measure has no reason to appear.
    pub fn fromSignature(prefix: []const u8) ?Kind {
        if (std.mem.startsWith(u8, prefix, &PNG_SIGNATURE)) return .png;
        if (std.mem.startsWith(u8, prefix, &.{ 0xFF, 0xD8, 0xFF })) return .jpeg;
        if (std.mem.startsWith(u8, prefix, "GIF87a") or std.mem.startsWith(u8, prefix, "GIF89a")) return .gif;
        if (std.mem.startsWith(u8, prefix, "BM")) return .bmp;
        if (prefix.len >= 14 and std.mem.eql(u8, prefix[0..4], "RIFF") and
            std.mem.eql(u8, prefix[8..14], "WEBPVP")) return .webp;
        if (prefix.len >= 12 and std.mem.eql(u8, prefix[4..8], "ftyp")) {
            const brand = prefix[8..12];
            if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return .avif;
        }
        return null;
    }

    /// Chrome matches the type case-insensitively: `IMAGE/PNG` is supported
    /// (measured). x-icon, svg+xml and tiff are not.
    pub fn fromType(mime: []const u8) ?Kind {
        const known = [_]struct { name: []const u8, kind: Kind }{
            .{ .name = "image/png", .kind = .png },
            .{ .name = "image/jpeg", .kind = .jpeg },
            .{ .name = "image/gif", .kind = .gif },
            .{ .name = "image/webp", .kind = .webp },
            .{ .name = "image/avif", .kind = .avif },
            .{ .name = "image/bmp", .kind = .bmp },
        };
        for (known) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, mime)) {
                return candidate.kind;
            }
        }
        return null;
    }
};

pub const Frame = struct {
    /// Microseconds from the start of the animation.
    timestamp: i64,
    /// Microseconds, or null for the single frame of a still image.
    duration: ?u64,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// GIF answers `animated: true` even for a one-frame file, so this follows
    /// the *format* rather than the frame count (measured, win51-chrome.json).
    animated: bool,
    /// Chrome reports 0 for a still image and Infinity for a GIF -- the null
    /// an earlier probe recorded was `JSON.stringify` flattening Infinity.
    repetition_count: f64,
    frames: []const Frame,
    /// BGRA, coded_width * coded_height * 4 bytes, or null for a format whose
    /// samples nothing here decodes.
    pixels: ?[]const u8,
};

/// The image, or null when the bytes are not one -- which is the difference
/// between Chrome's two failures: a type it cannot handle at all, and a type it
/// can handle whose bytes it cannot read ("Failed to retrieve track
/// metadata.").
pub fn read(kind: Kind, data: []const u8, allocator: Allocator) ?Image {
    return switch (kind) {
        .png => readPng(data, allocator),
        .gif => readGif(data, allocator),
        .jpeg => readJpeg(data),
        .bmp => readBmp(data),
        .webp => readWebp(data),
        .avif => readAvif(data),
    };
}

pub const Size = struct {
    width: u32,
    height: u32,
};

/// Just the intrinsic size, decoding nothing and allocating nothing.
///
/// `read` above is shaped for ImageDecoder, which is asked for frames and for
/// samples. An `<img>` only ever needs these two numbers, and reaching them
/// through `read` would hand a PNG the pixel path -- a `width * height * 4`
/// allocation out of the frame arena, for a buffer that is then dropped.
///
/// `data` may be a prefix rather than the whole body: every parser here reads
/// forward from the head and stops at the field it wants, so a truncated body
/// answers null instead of guessing.
pub fn readSize(kind: Kind, data: []const u8) ?Size {
    return switch (kind) {
        .png => pngSize(data),
        .gif => gifSize(data),
        .jpeg => sizeOf(readJpeg(data)),
        .bmp => sizeOf(readBmp(data)),
        .webp => sizeOf(readWebp(data)),
        .avif => sizeOf(readAvif(data)),
    };
}

fn sizeOf(image: ?Image) ?Size {
    const found = image orelse return null;
    return .{ .width = found.width, .height = found.height };
}

/// The one frame of a still image: no duration, no repetition.
fn still(width: u32, height: u32, pixels: ?[]const u8) ?Image {
    if (width == 0 or height == 0) {
        return null;
    }
    return .{
        .width = width,
        .height = height,
        .animated = false,
        .repetition_count = 0,
        .frames = &.{.{ .timestamp = 0, .duration = null }},
        .pixels = pixels,
    };
}

// -- PNG ---------------------------------------------------------------------

const PNG_SIGNATURE = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// IHDR, which is the whole of a PNG's geometry and comes before anything a
/// decoder would need. Split out so `readSize` can stop here.
fn pngSize(data: []const u8) ?Size {
    if (data.len < 8 + 12 + 13 or !std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) {
        return null;
    }
    if (!std.mem.eql(u8, data[12..16], "IHDR")) {
        return null;
    }
    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    if (width == 0 or height == 0) {
        return null;
    }
    return .{ .width = width, .height = height };
}

fn readPng(data: []const u8, allocator: Allocator) ?Image {
    const size = pngSize(data) orelse return null;
    const header = data[16..29];
    const depth = header[8];
    const colour = header[9];
    const interlace = header[12];

    return still(size.width, size.height, pngPixels(data, size.width, size.height, depth, colour, interlace, allocator));
}

/// The samples, as BGRA. Only the shape this engine's own encoder writes and
/// the other 8-bit colour types are handled; anything else answers null, which
/// leaves the frame's geometry right and its pixels transparent black.
fn pngPixels(
    data: []const u8,
    width: u32,
    height: u32,
    depth: u8,
    colour: u8,
    interlace: u8,
    allocator: Allocator,
) ?[]const u8 {
    if (depth != 8 or interlace != 0) {
        return null;
    }
    const channels: u32 = switch (colour) {
        0 => 1, // greyscale
        2 => 3, // truecolour
        3 => 1, // palette index
        4 => 2, // greyscale + alpha
        6 => 4, // truecolour + alpha
        else => return null,
    };

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var palette: ?[]const u8 = null;
    var alpha: ?[]const u8 = null;

    var at: usize = 8;
    while (at + 12 <= data.len) {
        const length = std.mem.readInt(u32, data[at..][0..4], .big);
        const kind = data[at + 4 ..][0..4];
        const end = at + 8 + length;
        if (end + 4 > data.len) {
            return null;
        }
        const body = data[at + 8 .. end];
        if (std.mem.eql(u8, kind, "IDAT")) {
            idat.appendSlice(allocator, body) catch return null;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = body;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            alpha = body;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        at = end + 4;
    }
    if (idat.items.len == 0) {
        return null;
    }
    if (colour == 3 and palette == null) {
        return null;
    }

    var reader: std.Io.Reader = .fixed(idat.items);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&reader, .zlib, &window);
    var scanlines: std.Io.Writer.Allocating = .init(allocator);
    defer scanlines.deinit();
    _ = decompress.reader.streamRemaining(&scanlines.writer) catch return null;

    const stride: usize = @as(usize, width) * channels;
    const raw = scanlines.written();
    if (raw.len < (stride + 1) * height) {
        return null;
    }

    // Unfilter in place into a fresh buffer, then widen to BGRA.
    const lines = allocator.alloc(u8, stride * height) catch return null;
    defer allocator.free(lines);
    unfilter(raw, lines, stride, height, channels) catch return null;

    const out = allocator.alloc(u8, @as(usize, width) * height * 4) catch return null;
    for (0..height) |y| {
        const row = lines[y * stride ..][0..stride];
        for (0..width) |x| {
            const rgba = sampleToRgba(row, x, colour, channels, palette, alpha) orelse {
                allocator.free(out);
                return null;
            };
            const o = (y * width + x) * 4;
            // BGRA, which is the order a decoded frame reports.
            out[o] = rgba[2];
            out[o + 1] = rgba[1];
            out[o + 2] = rgba[0];
            out[o + 3] = rgba[3];
        }
    }
    return out;
}

fn unfilter(raw: []const u8, out: []u8, stride: usize, height: u32, channels: u32) !void {
    const bpp: usize = channels;
    for (0..height) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const line = out[y * stride ..][0..stride];
        const prior: ?[]const u8 = if (y == 0) null else out[(y - 1) * stride ..][0..stride];
        for (0..stride) |i| {
            const a: u16 = if (i >= bpp) line[i - bpp] else 0;
            const b: u16 = if (prior) |p| p[i] else 0;
            const c: u16 = if (prior != null and i >= bpp) prior.?[i - bpp] else 0;
            const x: u16 = src[i];
            line[i] = switch (filter) {
                0 => @truncate(x),
                1 => @truncate(x + a),
                2 => @truncate(x + b),
                3 => @truncate(x + (a + b) / 2),
                4 => @truncate(x + paeth(a, b, c)),
                else => return error.BadFilter,
            };
        }
    }
}

fn paeth(a: u16, b: u16, c: u16) u16 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn sampleToRgba(
    row: []const u8,
    x: usize,
    colour: u8,
    channels: u32,
    palette: ?[]const u8,
    alpha: ?[]const u8,
) ?[4]u8 {
    const at = x * channels;
    return switch (colour) {
        0 => .{ row[at], row[at], row[at], 255 },
        2 => .{ row[at], row[at + 1], row[at + 2], 255 },
        3 => blk: {
            const index = row[at];
            const table = palette.?;
            if (@as(usize, index) * 3 + 2 >= table.len) {
                break :blk null;
            }
            const a: u8 = if (alpha) |t| (if (index < t.len) t[index] else 255) else 255;
            break :blk .{ table[index * 3], table[index * 3 + 1], table[index * 3 + 2], a };
        },
        4 => .{ row[at], row[at], row[at], row[at + 1] },
        6 => .{ row[at], row[at + 1], row[at + 2], row[at + 3] },
        else => null,
    };
}

// -- GIF ---------------------------------------------------------------------

/// The frame count, per-frame delays and loop count. The samples are LZW and
/// nothing here decodes them, so the frames carry geometry and timing only.
/// The logical screen descriptor, which is a GIF's geometry and sits in the
/// first thirteen bytes. Split out for the same reason as `pngSize`: the frame
/// walk below it needs the whole file, and an intrinsic size does not.
fn gifSize(data: []const u8) ?Size {
    if (data.len < 13) {
        return null;
    }
    if (!std.mem.eql(u8, data[0..6], "GIF87a") and !std.mem.eql(u8, data[0..6], "GIF89a")) {
        return null;
    }
    const width = std.mem.readInt(u16, data[6..8], .little);
    const height = std.mem.readInt(u16, data[8..10], .little);
    if (width == 0 or height == 0) {
        return null;
    }
    return .{ .width = width, .height = height };
}

fn readGif(data: []const u8, allocator: Allocator) ?Image {
    const size = gifSize(data) orelse return null;
    const width = size.width;
    const height = size.height;

    var at: usize = 13;
    const flags = data[10];
    if (flags & 0x80 != 0) {
        at += @as(usize, 3) * (@as(usize, 2) << @intCast(flags & 7));
    }

    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    // A GIF loops forever unless a NETSCAPE block names a finite count, and
    // Chrome reports that as Infinity (measured on both a still and a
    // two-frame GIF).
    var repetitions: f64 = std.math.inf(f64);
    var delay: u16 = 0;
    var timestamp: i64 = 0;

    while (at < data.len) {
        switch (data[at]) {
            0x3B => break, // trailer
            0x21 => { // extension
                if (at + 2 > data.len) return null;
                const label = data[at + 1];
                at += 2;
                if (label == 0xF9 and at < data.len and data[at] == 4 and at + 5 <= data.len) {
                    delay = std.mem.readInt(u16, data[at + 2 ..][0..2], .little);
                } else if (label == 0xFF and at < data.len and data[at] == 11 and
                    at + 12 <= data.len and std.mem.eql(u8, data[at + 1 ..][0..11], "NETSCAPE2.0"))
                {
                    const sub = at + 12;
                    if (sub + 5 <= data.len and data[sub] == 3) {
                        const loops = std.mem.readInt(u16, data[sub + 2 ..][0..2], .little);
                        if (loops != 0) {
                            repetitions = @floatFromInt(loops);
                        }
                    }
                }
                at = skipSubBlocks(data, at) orelse return null;
            },
            0x2C => { // image descriptor
                if (at + 10 > data.len) return null;
                const local = data[at + 9];
                at += 10;
                if (local & 0x80 != 0) {
                    at += @as(usize, 3) * (@as(usize, 2) << @intCast(local & 7));
                }
                at += 1; // LZW minimum code size
                at = skipSubBlocks(data, at) orelse return null;

                // Delays are hundredths of a second; a frame reports
                // microseconds, so 10 becomes 100000.
                const duration: u64 = @as(u64, delay) * 10_000;
                frames.append(allocator, .{ .timestamp = timestamp, .duration = duration }) catch return null;
                timestamp += @intCast(duration);
                delay = 0;
            },
            else => return null,
        }
    }
    if (frames.items.len == 0) {
        return null;
    }
    return .{
        .width = width,
        .height = height,
        // True even for a one-frame GIF: it follows the format, not the count.
        .animated = true,
        .repetition_count = repetitions,
        .frames = frames.toOwnedSlice(allocator) catch return null,
        .pixels = null,
    };
}

/// Walks a chain of length-prefixed sub-blocks to the terminating zero byte.
fn skipSubBlocks(data: []const u8, start: usize) ?usize {
    var at = start;
    while (at < data.len) {
        const size = data[at];
        at += 1;
        if (size == 0) {
            return at;
        }
        at += size;
    }
    return null;
}

// -- The header-only formats -------------------------------------------------

fn readJpeg(data: []const u8) ?Image {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) {
        return null;
    }
    var at: usize = 2;
    while (at + 4 <= data.len) {
        if (data[at] != 0xFF) {
            return null;
        }
        const marker = data[at + 1];
        // Standalone markers carry no length.
        if (marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            at += 2;
            continue;
        }
        const length = std.mem.readInt(u16, data[at + 2 ..][0..2], .big);
        // SOF0..SOF15, bar the two Huffman/arithmetic table markers that share
        // the range: height then width, both big-endian, after the precision.
        const is_sof = marker >= 0xC0 and marker <= 0xCF and
            marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (is_sof) {
            if (at + 9 > data.len) return null;
            const height = std.mem.readInt(u16, data[at + 5 ..][0..2], .big);
            const width = std.mem.readInt(u16, data[at + 7 ..][0..2], .big);
            return still(width, height, null);
        }
        if (length < 2) {
            return null;
        }
        at += 2 + length;
    }
    return null;
}

fn readBmp(data: []const u8) ?Image {
    if (data.len < 26 or data[0] != 'B' or data[1] != 'M') {
        return null;
    }
    const header_size = std.mem.readInt(u32, data[14..18], .little);
    if (header_size == 12) {
        // BITMAPCOREHEADER: 16-bit dimensions.
        return still(std.mem.readInt(u16, data[18..20], .little), std.mem.readInt(u16, data[20..22], .little), null);
    }
    const width = std.mem.readInt(i32, data[18..22], .little);
    const height = std.mem.readInt(i32, data[22..26], .little);
    if (width <= 0) {
        return null;
    }
    // A negative height is a top-down bitmap, not a smaller one.
    return still(@intCast(width), @abs(height), null);
}

fn readWebp(data: []const u8) ?Image {
    if (data.len < 30 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WEBP")) {
        return null;
    }
    const chunk = data[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        // Lossy: a 3-byte start code, then 14-bit dimensions.
        if (data[23] != 0x9D or data[24] != 0x01 or data[25] != 0x2A) {
            return null;
        }
        const w = std.mem.readInt(u16, data[26..28], .little) & 0x3FFF;
        const h = std.mem.readInt(u16, data[28..30], .little) & 0x3FFF;
        return still(w, h, null);
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (data[20] != 0x2F) {
            return null;
        }
        const bits = std.mem.readInt(u32, data[21..25], .little);
        return still((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1, null);
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        // Extended: 24-bit dimensions minus one, little-endian.
        const w = readInt24(data[24..27]) + 1;
        const h = readInt24(data[27..30]) + 1;
        return still(w, h, null);
    }
    return null;
}

fn readInt24(bytes: *const [3]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}

/// AVIF is ISOBMFF, and the size lives in an `ispe` box under
/// meta/iprp/ipco. Rather than walk the box tree for one field, this scans for
/// the four-character code and reads the two dimensions that follow its version
/// and flags -- which is the whole of the box's payload.
fn readAvif(data: []const u8) ?Image {
    if (data.len < 12 or !std.mem.eql(u8, data[4..8], "ftyp")) {
        return null;
    }
    var at: usize = 8;
    while (at + 16 <= data.len) : (at += 1) {
        if (!std.mem.eql(u8, data[at..][0..4], "ispe")) {
            continue;
        }
        const width = std.mem.readInt(u32, data[at + 8 ..][0..4], .big);
        const height = std.mem.readInt(u32, data[at + 12 ..][0..4], .big);
        return still(width, height, null);
    }
    return null;
}

// -- SVG ---------------------------------------------------------------------

/// What a replaced element with no intrinsic size of its own is laid out as.
/// An SVG reaches it whenever its root declares nothing usable.
const SVG_DEFAULT_WIDTH = 300.0;
const SVG_DEFAULT_HEIGHT = 150.0;

/// SVG is not a `Kind`: it has no signature to sniff, no samples to decode, and
/// its size is markup rather than a header field. It is here anyway because
/// this is where "how big is this picture" is answered, and an `<img>` asks the
/// same question of an SVG as of a PNG.
///
/// The rules, measured on Chrome 151 against the same markup
/// (`scratch/b90/expr-img-geometry.js`, rows `svg*`):
///
///   width=4 height=6         -> 4x6        width=40px height=12px -> 40x12
///   width=7.5 height=2.25    -> 8x2        width=40               -> 40x150
///   height=12                -> 300x12     width=40 viewBox 20 5  -> 40x10
///   viewBox 0 0 20 5         -> 300x75     (nothing)              -> 300x150
///   width=50% height=25%     -> 300x150    width=0 height=0       -> 0x0
///
/// Two of those are read and then deliberately not reproduced. `2em` needs a
/// font-size context an image request does not have, so a relative unit reads
/// as absent and falls back. And the viewBox-only row is the one where Chrome's
/// BOX and its intrinsic size disagree -- 300x75 intrinsic, 1904x476 laid out,
/// because a replaced element with a ratio and no size stretches to its
/// containing block. This engine has no replaced-element layout to stretch
/// with, so it answers the intrinsic size for both.
pub fn svgSize(markup: []const u8) ?Size {
    const attrs = svgRootAttributes(markup) orelse return null;
    var width = attrs.width;
    var height = attrs.height;
    if (width == null or height == null) {
        // A viewBox has no size of its own, only a ratio, and the ratio is what
        // fills in the axis that was not declared.
        const ratio: ?f64 = if (attrs.view_w) |vw| blk: {
            const vh = attrs.view_h orelse break :blk null;
            if (vw <= 0 or vh <= 0) break :blk null;
            break :blk vw / vh;
        } else null;
        if (width) |w| {
            height = if (ratio) |r| w / r else SVG_DEFAULT_HEIGHT;
        } else if (height) |h| {
            width = if (ratio) |r| h * r else SVG_DEFAULT_WIDTH;
        } else {
            width = SVG_DEFAULT_WIDTH;
            height = if (ratio) |r| SVG_DEFAULT_WIDTH / r else SVG_DEFAULT_HEIGHT;
        }
    }
    return .{
        .width = roundToU32(width.?),
        .height = roundToU32(height.?),
    };
}

fn roundToU32(value: f64) u32 {
    if (!(value > 0)) {
        return 0;
    }
    return @intFromFloat(@round(@min(value, @as(f64, std.math.maxInt(u32)))));
}

const SvgRoot = struct {
    width: ?f64 = null,
    height: ?f64 = null,
    view_w: ?f64 = null,
    view_h: ?f64 = null,
};

/// The three attributes of the root `<svg>` that carry a size, scanned off the
/// head of the document. A hand-rolled scan rather than the HTML parser: this
/// runs in a transfer callback over the first few kilobytes, and the whole
/// question is three attributes of one element.
fn svgRootAttributes(markup: []const u8) ?SvgRoot {
    const open = std.mem.indexOf(u8, markup, "<svg") orelse return null;
    var at = open + 4;
    // `<svgfoo` is a different element.
    if (at < markup.len and !isTagBreak(markup[at])) {
        return null;
    }
    var out: SvgRoot = .{};
    while (at < markup.len) {
        while (at < markup.len and std.ascii.isWhitespace(markup[at])) at += 1;
        if (at >= markup.len or markup[at] == '>' or markup[at] == '/') {
            break;
        }
        const name_start = at;
        while (at < markup.len and markup[at] != '=' and markup[at] != '>' and
            markup[at] != '/' and !std.ascii.isWhitespace(markup[at])) at += 1;
        const name = markup[name_start..at];
        while (at < markup.len and std.ascii.isWhitespace(markup[at])) at += 1;
        if (at >= markup.len or markup[at] != '=') {
            // A valueless attribute. Nothing sized is spelled that way.
            continue;
        }
        at += 1;
        while (at < markup.len and std.ascii.isWhitespace(markup[at])) at += 1;
        if (at >= markup.len) break;
        var value: []const u8 = "";
        if (markup[at] == '"' or markup[at] == '\'') {
            const quote = markup[at];
            at += 1;
            const value_start = at;
            while (at < markup.len and markup[at] != quote) at += 1;
            value = markup[value_start..at];
            if (at < markup.len) at += 1;
        } else {
            const value_start = at;
            while (at < markup.len and markup[at] != '>' and !std.ascii.isWhitespace(markup[at])) at += 1;
            value = markup[value_start..at];
        }
        // SVG is XML, so these names are case-sensitive -- `viewbox` is not
        // `viewBox` in a standalone document, which is what an <img> loads.
        if (std.mem.eql(u8, name, "width")) {
            out.width = svgLength(value);
        } else if (std.mem.eql(u8, name, "height")) {
            out.height = svgLength(value);
        } else if (std.mem.eql(u8, name, "viewBox")) {
            var parts = std.mem.tokenizeAny(u8, value, " ,\t\r\n");
            var seen: usize = 0;
            while (parts.next()) |part| : (seen += 1) {
                const number = std.fmt.parseFloat(f64, part) catch return null;
                if (seen == 2) out.view_w = number;
                if (seen == 3) out.view_h = number;
            }
        }
    }
    return out;
}

fn isTagBreak(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '>' or c == '/';
}

/// The initial `font-size` of a standalone SVG document, which is what `em`
/// resolves against when an <img> loads one: Chrome answers 32 for `width=2em`.
const SVG_ROOT_FONT_SIZE = 16.0;

/// A number in any absolute length unit, plus the two font-relative units that
/// a document with no cascade still has an answer for. A percentage reads as
/// absent because it genuinely IS absent -- a percentage has no intrinsic size,
/// and Chrome answers 300x150 for `width="50%"`.
fn svgLength(text: []const u8) ?f64 {
    const parsed = units.parse(std.mem.trim(u8, text, &std.ascii.whitespace)) catch return null;
    const factor = units.absoluteLengthFactor(parsed.unit) orelse switch (parsed.unit) {
        .em, .rem => SVG_ROOT_FONT_SIZE,
        else => return null,
    };
    const pixels = parsed.value * factor;
    if (!std.math.isFinite(pixels) or pixels < 0) {
        return null;
    }
    return pixels;
}

const testing = @import("../../../testing.zig");

test "images: a PNG this engine wrote reads back with its own pixels" {
    const png = @import("../canvas/png.zig");
    const allocator = testing.allocator;

    // Two rows of two pixels: opaque red, then transparent, then the reverse.
    const pixels = [_]u8{
        255, 0, 0, 255, 0, 0, 0,   0,
        0,   0, 0, 0,   0, 0, 255, 255,
    };
    const bytes = try png.encode(allocator, 2, 2, &pixels);
    defer allocator.free(bytes);

    const image = read(.png, bytes, allocator) orelse return error.NotAnImage;
    defer if (image.pixels) |p| allocator.free(p);
    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
    try testing.expectEqual(false, image.animated);
    try testing.expectEqual(@as(f64, 0), image.repetition_count);
    try testing.expectEqual(@as(usize, 1), image.frames.len);
    // BGRA, so red is the third byte.
    try testing.expectEqualSlices(u8, &.{
        0, 0, 255, 255, 0,   0, 0, 0,
        0, 0, 0,   0,   255, 0, 0, 255,
    }, image.pixels.?);
}

test "images: bytes that are not the declared type read as nothing" {
    const allocator = testing.allocator;
    try testing.expect(read(.png, &.{ 1, 2, 3, 4 }, allocator) == null);
    try testing.expect(read(.gif, &.{ 1, 2, 3, 4 }, allocator) == null);
    try testing.expect(read(.jpeg, &.{ 1, 2, 3, 4 }, allocator) == null);
    try testing.expect(read(.bmp, &.{ 1, 2, 3, 4 }, allocator) == null);
    try testing.expect(read(.webp, &.{ 1, 2, 3, 4 }, allocator) == null);
    try testing.expect(read(.avif, &.{ 1, 2, 3, 4 }, allocator) == null);
}

test "images: a two-frame GIF carries its delays and loops forever" {
    const allocator = testing.allocator;
    // The same bytes probe-win47.js measured Chrome with.
    const base64 = "R0lGODlhAQABAIAAAP///wAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFCgAAACwAAAAAAQABAAACAkQBACH5BAUKAAEALAAAAAABAAEAAAICVAEAOw==";
    const decoder = std.base64.standard.Decoder;
    const bytes = try allocator.alloc(u8, try decoder.calcSizeForSlice(base64));
    defer allocator.free(bytes);
    try decoder.decode(bytes, base64);

    const image = read(.gif, bytes, allocator) orelse return error.NotAnImage;
    defer allocator.free(image.frames);
    try testing.expectEqual(@as(u32, 1), image.width);
    try testing.expectEqual(@as(u32, 1), image.height);
    try testing.expectEqual(true, image.animated);
    try testing.expectEqual(std.math.inf(f64), image.repetition_count);
    try testing.expectEqual(@as(usize, 2), image.frames.len);
    try testing.expectEqual(@as(i64, 0), image.frames[0].timestamp);
    try testing.expectEqual(@as(?u64, 100_000), image.frames[0].duration);
    try testing.expectEqual(@as(i64, 100_000), image.frames[1].timestamp);
    try testing.expectEqual(@as(?u64, 100_000), image.frames[1].duration);
}

test "images: the type match is case-insensitive, and only six types match" {
    try testing.expectEqual(Kind.png, Kind.fromType("IMAGE/PNG").?);
    try testing.expectEqual(Kind.bmp, Kind.fromType("image/bmp").?);
    try testing.expect(Kind.fromType("image/x-icon") == null);
    try testing.expect(Kind.fromType("image/svg+xml") == null);
    try testing.expect(Kind.fromType("image/tiff") == null);
    try testing.expect(Kind.fromType("") == null);
}

test "images: an SVG root's intrinsic size" {
    const cases = [_]struct { markup: []const u8, want: ?Size }{
        // Every row measured on Chrome 151 against this markup; see `svgSize`.
        .{ .markup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"6\"></svg>", .want = .{ .width = 4, .height = 6 } },
        .{ .markup = "<svg width='40px' height='12px'/>", .want = .{ .width = 40, .height = 12 } },
        // Absolute units and the two font-relative ones a document with no
        // cascade still answers: Chrome reads `2em` as 32 (measured).
        .{ .markup = "<svg width=\"2em\" height=\"3em\"/>", .want = .{ .width = 32, .height = 48 } },
        .{ .markup = "<svg width=\"1in\" height=\"6pt\"/>", .want = .{ .width = 96, .height = 8 } },
        // The IDL is an unsigned long, and Chrome rounds rather than truncates.
        .{ .markup = "<svg width=\"7.5\" height=\"2.25\"/>", .want = .{ .width = 8, .height = 2 } },
        .{ .markup = "<svg width=\"40\"/>", .want = .{ .width = 40, .height = 150 } },
        .{ .markup = "<svg height=\"12\"/>", .want = .{ .width = 300, .height = 12 } },
        .{ .markup = "<svg width=\"40\" viewBox=\"0 0 20 5\"/>", .want = .{ .width = 40, .height = 10 } },
        .{ .markup = "<svg height=\"10\" viewBox=\"0 0 20 5\"/>", .want = .{ .width = 40, .height = 10 } },
        .{ .markup = "<svg viewBox=\"0 0 20 5\"/>", .want = .{ .width = 300, .height = 75 } },
        .{ .markup = "<svg viewBox=\"0,0,20,5\"/>", .want = .{ .width = 300, .height = 75 } },
        .{ .markup = "<svg></svg>", .want = .{ .width = 300, .height = 150 } },
        // A percentage is not an intrinsic size, so the default stands.
        .{ .markup = "<svg width=\"50%\" height=\"25%\"/>", .want = .{ .width = 300, .height = 150 } },
        // XML, so the attribute name is case-sensitive: `viewbox` is not it.
        .{ .markup = "<svg viewbox=\"0 0 20 5\"/>", .want = .{ .width = 300, .height = 150 } },
        // A prolog and a comment ahead of the root are still the same document.
        .{ .markup = "<?xml version=\"1.0\"?>\n<!-- x -->\n<svg width=\"9\" height=\"3\"/>", .want = .{ .width = 9, .height = 3 } },
        // Not the root element this is looking for.
        .{ .markup = "<svgx width=\"4\" height=\"6\"/>", .want = null },
        .{ .markup = "<html><body>nope</body></html>", .want = null },
    };
    for (cases) |case| {
        const got = svgSize(case.markup);
        if (case.want) |want| {
            try testing.expectEqual(want.width, (got orelse return error.NoSize).width);
            try testing.expectEqual(want.height, (got orelse return error.NoSize).height);
        } else {
            // Compared as a boolean: the test helper cannot walk into an
            // optional struct.
            try testing.expectEqual(true, got == null);
        }
    }
}

test "images: a size from a signature and a header" {
    try testing.expectEqual(Kind.png, Kind.fromSignature(&.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }) orelse return error.NoKind);
    try testing.expectEqual(Kind.gif, Kind.fromSignature("GIF89a.......") orelse return error.NoKind);
    try testing.expectEqual(Kind.jpeg, Kind.fromSignature(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }) orelse return error.NoKind);
    try testing.expectEqual(Kind.bmp, Kind.fromSignature("BM..........") orelse return error.NoKind);
    try testing.expectEqual(Kind.webp, Kind.fromSignature("RIFF\x24\x00\x00\x00WEBPVP8 ") orelse return error.NoKind);
    try testing.expectEqual(Kind.avif, Kind.fromSignature("\x00\x00\x00\x18ftypavif....") orelse return error.NoKind);
    // ICO carries no geometry parser here, so it has no Kind to pick.
    try testing.expectEqual(true, Kind.fromSignature(&.{ 0x00, 0x00, 0x01, 0x00, 0x01 }) == null);
    try testing.expectEqual(true, Kind.fromSignature("<svg/>") == null);
    try testing.expectEqual(true, Kind.fromSignature("") == null);

    // The same 8x8 PNG the tests elsewhere use, read for geometry only: no
    // allocator, and therefore no pixels.
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x03,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x5f, 0xc3, 0x15, 0xc5,
    };
    const size = readSize(.png, &png) orelse return error.NoSize;
    try testing.expectEqual(@as(u32, 7), size.width);
    try testing.expectEqual(@as(u32, 3), size.height);
    // Truncated before IHDR is complete: no guess.
    try testing.expectEqual(true, readSize(.png, png[0..20]) == null);
}
