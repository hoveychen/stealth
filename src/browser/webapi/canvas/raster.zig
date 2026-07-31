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

// A deliberately small raster backing store for the 2D canvas contexts.
//
// The point is not to be a renderer. It is that a canvas which reports pixels
// is much less remarkable than one which reports nothing: a script that fills
// two different rectangles and compares `toDataURL()` gets two different
// strings, the way it would in any real browser. Before this, every canvas in
// the engine hashed to the same value, which is a signal no browser produces.
//
// What is here: an RGBA8 (straight, *not* premultiplied — that is what
// `getImageData` hands back) buffer plus axis-aligned rectangle fills with
// source-over compositing. What is not here, and is not planned: paths,
// transforms, gradients, image decoding, and glyph rasterisation. Text in
// particular needs a font rasteriser to land any ink at all, so a text-based
// canvas fingerprint still will not match Chrome's — see tools/fingerprint.
//
// Coordinates are rounded to whole pixels rather than antialiased, so a
// fractional rectangle edge lands one pixel off from Chrome's coverage-blended
// edge.

const std = @import("std");

const color = @import("../../color.zig");

const Allocator = std.mem.Allocator;
const RGBA = color.RGBA;

const Surface = @This();

/// Frame-lifetime arena. The buffer is only reclaimed with the frame.
arena: Allocator,
/// Dimensions the current buffer was allocated for. Meaningless when
/// `pixels` is empty.
width: u32 = 0,
height: u32 = 0,
/// Straight (non-premultiplied) RGBA8, row-major, `width * height * 4` long.
/// Empty until something actually draws.
pixels: []u8 = &.{},

/// Roughly a 2896x2896 canvas. Past this we simply refuse to back the canvas,
/// and every operation degrades to the old no-op behaviour. Fingerprinting
/// canvases are tiny; this only guards against a page asking for gigabytes.
pub const max_bytes = 32 * 1024 * 1024;

/// Drops the backing store. Assigning to `canvas.width` / `canvas.height`
/// clears the bitmap in Chrome even when the value does not change.
pub fn reset(self: *Surface) void {
    if (self.pixels.len != 0) {
        self.arena.free(self.pixels);
    }
    self.pixels = &.{};
    self.width = 0;
    self.height = 0;
}

/// The buffer for a `width` x `height` canvas, allocating (zeroed) or
/// reallocating it as needed. Null when the canvas is degenerate or too big
/// to back, in which case callers should behave as if nothing was drawn.
pub fn ensure(self: *Surface, width: u32, height: u32) ?[]u8 {
    if (width == 0 or height == 0) {
        return null;
    }
    if (self.pixels.len != 0 and self.width == width and self.height == height) {
        return self.pixels;
    }

    const bytes = @as(u64, width) * @as(u64, height) * 4;
    if (bytes > max_bytes) {
        return null;
    }

    const pixels = self.arena.alloc(u8, @intCast(bytes)) catch return null;
    @memset(pixels, 0);

    self.reset();
    self.pixels = pixels;
    self.width = width;
    self.height = height;
    return pixels;
}

/// The buffer as it stands, without allocating. Null when nothing has been
/// drawn yet or the canvas has since been resized, both of which mean "every
/// pixel is transparent black".
pub fn peek(self: *const Surface, width: u32, height: u32) ?[]const u8 {
    if (self.pixels.len == 0 or self.width != width or self.height != height) {
        return null;
    }
    return self.pixels;
}

/// `peek`, for the callers that write back.
fn peekMut(self: *Surface, width: u32, height: u32) ?[]u8 {
    if (self.pixels.len == 0 or self.width != width or self.height != height) {
        return null;
    }
    return self.pixels;
}

/// A rectangle snapped to whole pixels and clipped to the canvas, as a
/// half-open `[x0, x1) x [y0, y1)` range. Null when nothing is covered.
const Bounds = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    fn clip(x: f64, y: f64, w: f64, h: f64, width: u32, height: u32) ?Bounds {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or
            !std.math.isFinite(w) or !std.math.isFinite(h))
        {
            return null;
        }

        // Negative extents are normalised, matching the spec.
        const left = @round(@min(x, x + w));
        const right = @round(@max(x, x + w));
        const top = @round(@min(y, y + h));
        const bottom = @round(@max(y, y + h));

        const fw: f64 = @floatFromInt(width);
        const fh: f64 = @floatFromInt(height);

        const x0 = std.math.clamp(left, 0, fw);
        const x1 = std.math.clamp(right, 0, fw);
        const y0 = std.math.clamp(top, 0, fh);
        const y1 = std.math.clamp(bottom, 0, fh);
        if (x0 >= x1 or y0 >= y1) {
            return null;
        }

        return .{
            .x0 = @intFromFloat(x0),
            .y0 = @intFromFloat(y0),
            .x1 = @intFromFloat(x1),
            .y1 = @intFromFloat(y1),
        };
    }
};

/// Composites `paint` over the rectangle, `global_alpha` scaling its opacity.
pub fn fillRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64, paint: RGBA, global_alpha: f64) void {
    const bounds = Bounds.clip(x, y, w, h, canvas_width, canvas_height) orelse return;
    const pixels = self.ensure(canvas_width, canvas_height) orelse return;

    const alpha = std.math.clamp(global_alpha, 0, 1) * paint.normalizedAlpha();
    if (alpha <= 0) {
        return;
    }

    var row = bounds.y0;
    while (row < bounds.y1) : (row += 1) {
        var col = bounds.x0;
        while (col < bounds.x1) : (col += 1) {
            const at = (row * canvas_width + col) * 4;
            blend(pixels[at..][0..4], paint, alpha);
        }
    }
}

/// Resets the rectangle to transparent black. Unlike `fillRect` this does not
/// composite, so it does not need a buffer that does not already exist.
pub fn clearRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64) void {
    const bounds = Bounds.clip(x, y, w, h, canvas_width, canvas_height) orelse return;
    const pixels = self.peekMut(canvas_width, canvas_height) orelse return;

    var row = bounds.y0;
    while (row < bounds.y1) : (row += 1) {
        const from = (row * canvas_width + bounds.x0) * 4;
        const to = (row * canvas_width + bounds.x1) * 4;
        @memset(pixels[from..to], 0);
    }
}

/// Strokes the rectangle's outline as four bands centred on its edges, which
/// is what a real stroke of an axis-aligned rectangle degenerates to once
/// joins and caps have nothing to round off.
pub fn strokeRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64, line_width: f64, paint: RGBA, global_alpha: f64) void {
    if (!std.math.isFinite(line_width) or line_width <= 0) {
        return;
    }

    const half = line_width / 2;
    const left = @min(x, x + w);
    const right = @max(x, x + w);
    const top = @min(y, y + h);
    const bottom = @max(y, y + h);
    const outer_w = (right - left) + line_width;

    // Top and bottom bands span the full outer width so the corners are
    // covered once; the side bands then only need the span between them.
    self.fillRect(canvas_width, canvas_height, left - half, top - half, outer_w, line_width, paint, global_alpha);
    self.fillRect(canvas_width, canvas_height, left - half, bottom - half, outer_w, line_width, paint, global_alpha);
    const inner_h = (bottom - top) - line_width;
    if (inner_h > 0) {
        self.fillRect(canvas_width, canvas_height, left - half, top + half, line_width, inner_h, paint, global_alpha);
        self.fillRect(canvas_width, canvas_height, right - half, top + half, line_width, inner_h, paint, global_alpha);
    }
}

/// Copies a `sw` x `sh` window starting at (`sx`, `sy`) into `out`, which must
/// be `sw * sh * 4` long and already zeroed. The window may sit partly (or
/// entirely) outside the canvas; those pixels stay transparent black.
pub fn readPixels(self: *const Surface, canvas_width: u32, canvas_height: u32, sx: i64, sy: i64, sw: u32, sh: u32, out: []u8) void {
    const pixels = self.peek(canvas_width, canvas_height) orelse return;

    var row: u32 = 0;
    while (row < sh) : (row += 1) {
        const src_y = sy + @as(i64, row);
        if (src_y < 0 or src_y >= canvas_height) {
            continue;
        }

        var col: u32 = 0;
        while (col < sw) : (col += 1) {
            const src_x = sx + @as(i64, col);
            if (src_x < 0 or src_x >= canvas_width) {
                continue;
            }
            const from: usize = (@as(usize, @intCast(src_y)) * canvas_width + @as(usize, @intCast(src_x))) * 4;
            const to: usize = (@as(usize, row) * sw + col) * 4;
            @memcpy(out[to..][0..4], pixels[from..][0..4]);
        }
    }
}

/// Source-over of a straight-alpha `paint` (at effective opacity `alpha`)
/// onto a straight-alpha destination pixel.
fn blend(dst: *[4]u8, paint: RGBA, alpha: f64) void {
    if (alpha >= 1) {
        dst.* = .{ paint.r, paint.g, paint.b, 255 };
        return;
    }

    const dst_alpha = @as(f64, @floatFromInt(dst[3])) / 255;
    const out_alpha = alpha + dst_alpha * (1 - alpha);
    if (out_alpha <= 0) {
        dst.* = .{ 0, 0, 0, 0 };
        return;
    }

    const src_channels = [3]u8{ paint.r, paint.g, paint.b };
    for (src_channels, 0..) |channel, i| {
        const src: f64 = @floatFromInt(channel);
        const old: f64 = @floatFromInt(dst[i]);
        const mixed = (src * alpha + old * dst_alpha * (1 - alpha)) / out_alpha;
        dst[i] = @intFromFloat(std.math.clamp(@round(mixed), 0, 255));
    }
    dst[3] = @intFromFloat(std.math.clamp(@round(out_alpha * 255), 0, 255));
}

const testing = std.testing;

test "raster: fillRect composites and clips" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    // A 4x4 canvas, opaque red over the top-left 2x2, spilling out of bounds.
    surface.fillRect(4, 4, -1, -1, 3, 3, RGBA.Named.red, 1);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[4..8]);
    // Third column of the first row is untouched.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[8..12]);

    // Half-opaque white on top of the red.
    surface.fillRect(4, 4, 0, 0, 1, 1, .{ .r = 255, .g = 255, .b = 255, .a = 128 }, 1);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 128, 255 }, surface.pixels[0..4]);

    surface.clearRect(4, 4, 0, 0, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[0..4]);
}

test "raster: readPixels windows out of bounds" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    surface.fillRect(2, 2, 0, 0, 2, 2, RGBA.Named.lime, 1);

    var out = [_]u8{0} ** (2 * 2 * 4);
    surface.readPixels(2, 2, 1, 1, 2, 2, &out);
    // Only the canvas' bottom-right pixel lands, at the window's origin.
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[8..12]);
}
