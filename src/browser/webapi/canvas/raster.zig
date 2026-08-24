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
// `getImageData` hands back) buffer, axis-aligned rectangle fills, a scanline
// fill and stroke for the flattened paths `path.zig` builds, and source-over
// compositing under the two separable blend modes of `Composite` below. What
// is still not here: gradients, image decoding, and glyph rasterisation. Text
// in particular needs a font rasteriser to land any ink at all, so a text-based
// canvas fingerprint still will not match Chrome's — see tools/fingerprint.
//
// Rectangles are rounded to whole pixels rather than antialiased, so a
// fractional rectangle edge lands one pixel off from Chrome's coverage-blended
// edge. Paths are not: a path edge crosses pixels at arbitrary angles, and
// snapping those would turn every curve into a staircase no browser produces.
// They are sampled on a 4x4 grid per pixel instead, which costs 16 point-in-
// polygon tests on canvases that are tens of pixels across.

const std = @import("std");

const color = @import("../../color.zig");
const path_mod = @import("path.zig");

const Allocator = std.mem.Allocator;
const RGBA = color.RGBA;
const Path = path_mod.Path;
const Point = path_mod.Point;
const FillRule = path_mod.FillRule;

const Surface = @This();

/// The part of `globalCompositeOperation` the rasteriser can act on: the
/// separable blend modes, which keep source-over's coverage arithmetic and only
/// change what the overlapping *opaque* parts of source and backdrop mix to.
///
/// The other twenty-four keywords are Porter-Duff operators — they change which
/// pixels survive, not just their colour — and they all read as `source_over`
/// here, which is what every one of them did before any of this. Two is what
/// the widget uses.
pub const Composite = enum {
    source_over,
    multiply,
    difference,

    pub fn fromKeyword(keyword: []const u8) Composite {
        if (std.mem.eql(u8, keyword, "multiply")) return .multiply;
        if (std.mem.eql(u8, keyword, "difference")) return .difference;
        return .source_over;
    }

    /// `B(Cb, Cs)` from the compositing spec, on 0..255 channels rather than
    /// the spec's 0..1 — hence the divisor in `multiply`. `source_over` is the
    /// identity blend `B(Cb, Cs) = Cs`.
    fn apply(self: Composite, backdrop: f64, source: f64) f64 {
        return switch (self) {
            .source_over => source,
            .multiply => backdrop * source / 255,
            .difference => @abs(backdrop - source),
        };
    }
};

/// The part of `ctx.filter` the rasteriser can act on: a lone `grayscale()`.
///
/// A filter applies to the *source* graphic before it is composited, and never
/// to the backdrop — which is why it lives next to `Composite` and is applied
/// to the paint on its way in rather than to the pixels already there. That
/// order is measured, not assumed: `grayscale(1)` under `difference` reads
/// `|backdrop - luminance(source)|` on Chrome 151, to the byte.
///
/// A string that is anything other than one `grayscale()` — a chain, a filter
/// we do not implement, junk — leaves the paint alone. Honouring the half of a
/// `grayscale(1) blur(2px)` we understand would land further from Chrome than
/// honouring none of it: Chrome reads `{128, 128, 128, 8}` there, because the
/// blur is most of what happened.
pub const Filter = struct {
    /// 0 leaves the colour alone; 1 replaces it with its own luminance.
    grayscale: f64 = 0,

    pub const none: Filter = .{};

    /// `ctx.filter` as the paint should read it. Chrome's own parse is
    /// case-insensitive, tolerates whitespace inside the parentheses, takes a
    /// number or a percentage, defaults an empty argument to 1, clamps above 1,
    /// and — measured — accepts an unclosed `grayscale(1`. It rejects a
    /// negative amount outright at the setter, so one can only reach us on a
    /// context that never had it, and reads as no filter here.
    pub fn parse(text: []const u8) Filter {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return .none;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[0..open], &std.ascii.whitespace), "grayscale")) {
            return .none;
        }

        var argument = trimmed[open + 1 ..];
        if (std.mem.endsWith(u8, argument, ")")) {
            argument = argument[0 .. argument.len - 1];
        }
        // A second function would have left its own parenthesis behind.
        if (std.mem.indexOfScalar(u8, argument, '(') != null) return .none;
        argument = std.mem.trim(u8, argument, &std.ascii.whitespace);
        if (argument.len == 0) return .{ .grayscale = 1 };

        const percent = std.mem.endsWith(u8, argument, "%");
        const number = std.fmt.parseFloat(f64, if (percent) argument[0 .. argument.len - 1] else argument) catch return .none;
        if (!std.math.isFinite(number) or number < 0) return .none;
        return .{ .grayscale = @min(1, if (percent) number / 100 else number) };
    }

    /// The paint after the filter, which for a flat colour is the whole of it.
    /// The coefficients are the sRGB luminance ones, applied to the bytes
    /// themselves — CSS filters do not linearise, and every primary confirms it
    /// (255 red reads 54, green 182, blue 18).
    pub fn applyTo(self: Filter, paint: RGBA) RGBA {
        if (self.grayscale <= 0) {
            return paint;
        }

        const r: f64 = @floatFromInt(paint.r);
        const g: f64 = @floatFromInt(paint.g);
        const b: f64 = @floatFromInt(paint.b);
        const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        // `grayscale(a)` is the spec's matrix, which for every a is exactly
        // this interpolation towards the luminance. Alpha is untouched.
        const mix = struct {
            fn towards(from: f64, to: f64, amount: f64) u8 {
                return @intFromFloat(std.math.clamp(@round(from + (to - from) * amount), 0, 255));
            }
        }.towards;
        return .{
            .r = mix(r, luminance, self.grayscale),
            .g = mix(g, luminance, self.grayscale),
            .b = mix(b, luminance, self.grayscale),
            .a = paint.a,
        };
    }
};

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
pub fn fillRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64, paint: RGBA, global_alpha: f64, op: Composite) void {
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
            blend(pixels[at..][0..4], paint, alpha, op);
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
pub fn strokeRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64, line_width: f64, paint: RGBA, global_alpha: f64, op: Composite) void {
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
    self.fillRect(canvas_width, canvas_height, left - half, top - half, outer_w, line_width, paint, global_alpha, op);
    self.fillRect(canvas_width, canvas_height, left - half, bottom - half, outer_w, line_width, paint, global_alpha, op);
    const inner_h = (bottom - top) - line_width;
    if (inner_h > 0) {
        self.fillRect(canvas_width, canvas_height, left - half, top + half, line_width, inner_h, paint, global_alpha, op);
        self.fillRect(canvas_width, canvas_height, right - half, top + half, line_width, inner_h, paint, global_alpha, op);
    }
}

/// Samples per pixel along each axis. Sixteen samples resolve a sixteenth of
/// a pixel of coverage, which is finer than the eighth Chrome's own edges
/// quantise to in practice.
const samples = 4;

/// One flattened edge, kept in the order the winding test wants: `dir` is +1
/// when the edge runs downwards and -1 when it runs up.
const Edge = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    dir: f64,
};

/// Coverage of one sample point under `rule`, from the edges crossing the ray
/// that runs to the right of it.
fn covers(edges: []const Edge, x: f64, y: f64, rule: FillRule) bool {
    var winding: i32 = 0;
    for (edges) |e| {
        // Half-open in y so a vertex shared by two edges is counted once.
        if ((y >= e.y0) != (y >= e.y1)) {
            const t = (y - e.y0) / (e.y1 - e.y0);
            if (e.x0 + t * (e.x1 - e.x0) > x) {
                winding += if (e.dir > 0) 1 else -1;
            }
        }
    }
    return switch (rule) {
        .nonzero => winding != 0,
        .evenodd => @rem(winding, 2) != 0,
    };
}

/// Collects every subpath's segments as edges, closing each subpath — a fill
/// closes implicitly whether or not `closePath` was called.
fn edgesOf(arena: Allocator, p: *const Path) ?[]Edge {
    var total: usize = 0;
    for (p.subpaths.items) |sub| {
        if (sub.points.items.len >= 2) total += sub.points.items.len;
    }
    if (total == 0) return null;

    const edges = arena.alloc(Edge, total) catch return null;
    var n: usize = 0;
    for (p.subpaths.items) |sub| {
        const pts = sub.points.items;
        if (pts.len < 2) continue;
        for (pts, 0..) |from, i| {
            const to = pts[(i + 1) % pts.len];
            if (from.y == to.y) continue;
            edges[n] = if (from.y < to.y)
                .{ .x0 = from.x, .y0 = from.y, .x1 = to.x, .y1 = to.y, .dir = 1 }
            else
                .{ .x0 = to.x, .y0 = to.y, .x1 = from.x, .y1 = from.y, .dir = -1 };
            n += 1;
        }
    }
    if (n == 0) return null;
    return edges[0..n];
}

/// The pixel rectangle the edges can possibly touch, clipped to the canvas.
fn edgeBounds(edges: []const Edge, width: u32, height: u32) ?Bounds {
    var min_x: f64 = std.math.floatMax(f64);
    var min_y: f64 = std.math.floatMax(f64);
    var max_x: f64 = -std.math.floatMax(f64);
    var max_y: f64 = -std.math.floatMax(f64);
    for (edges) |e| {
        min_x = @min(min_x, @min(e.x0, e.x1));
        max_x = @max(max_x, @max(e.x0, e.x1));
        min_y = @min(min_y, e.y0);
        max_y = @max(max_y, e.y1);
    }
    if (!std.math.isFinite(min_x) or !std.math.isFinite(max_x) or
        !std.math.isFinite(min_y) or !std.math.isFinite(max_y))
    {
        return null;
    }
    return Bounds.clip(@floor(min_x), @floor(min_y), @ceil(max_x) - @floor(min_x) + 1, @ceil(max_y) - @floor(min_y) + 1, width, height);
}

/// Fills `p` — already flattened and already in device space — with `paint`.
/// `scratch` is only used for the edge list and may be a call-lifetime arena.
pub fn fillPath(self: *Surface, scratch: Allocator, canvas_width: u32, canvas_height: u32, p: *const Path, rule: FillRule, paint: RGBA, global_alpha: f64, op: Composite) void {
    const edges = edgesOf(scratch, p) orelse return;
    const bounds = edgeBounds(edges, canvas_width, canvas_height) orelse return;

    const alpha = std.math.clamp(global_alpha, 0, 1) * paint.normalizedAlpha();
    if (alpha <= 0) {
        return;
    }
    const pixels = self.ensure(canvas_width, canvas_height) orelse return;

    const step: f64 = 1.0 / @as(f64, samples);
    const per_sample = step / 2;

    var row = bounds.y0;
    while (row < bounds.y1) : (row += 1) {
        var col = bounds.x0;
        while (col < bounds.x1) : (col += 1) {
            var hits: u32 = 0;
            var sy: usize = 0;
            while (sy < samples) : (sy += 1) {
                const y = @as(f64, @floatFromInt(row)) + @as(f64, @floatFromInt(sy)) * step + per_sample;
                var sx: usize = 0;
                while (sx < samples) : (sx += 1) {
                    const x = @as(f64, @floatFromInt(col)) + @as(f64, @floatFromInt(sx)) * step + per_sample;
                    if (covers(edges, x, y, rule)) hits += 1;
                }
            }
            if (hits == 0) continue;
            const coverage = @as(f64, @floatFromInt(hits)) / (samples * samples);
            const at = (row * canvas_width + col) * 4;
            blend(pixels[at..][0..4], paint, alpha * coverage, op);
        }
    }
}

/// Strokes `p` by filling, for each segment, the quad `line_width` across that
/// the segment sweeps, plus a disc at every join. A round join everywhere is
/// not what `lineJoin` says, but it is the shape a miter and a bevel both
/// approach as the segments get short — and a flattened curve's segments are
/// short by construction.
pub fn strokePath(self: *Surface, scratch: Allocator, canvas_width: u32, canvas_height: u32, p: *const Path, line_width: f64, paint: RGBA, global_alpha: f64, op: Composite) void {
    if (!std.math.isFinite(line_width) or line_width <= 0) {
        return;
    }
    const half = line_width / 2;

    // One outline holding every quad and disc, filled in one pass under the
    // non-zero rule so the overlaps between them do not double-composite —
    // which under a blend mode would fold the backdrop in twice, not merely
    // darken the seams.
    var outline: Path = .{};
    for (p.subpaths.items) |sub| {
        const pts = sub.points.items;
        if (pts.len == 0) continue;
        if (pts.len == 1) {
            disc(scratch, &outline, pts[0], half);
            continue;
        }
        const last = if (sub.closed) pts.len else pts.len - 1;
        for (0..last) |i| {
            const from = pts[i];
            const to = pts[(i + 1) % pts.len];
            const dx = to.x - from.x;
            const dy = to.y - from.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (len <= 0 or !std.math.isFinite(len)) continue;
            const nx = -dy / len * half;
            const ny = dx / len * half;
            quad(scratch, &outline, .{
                .{ .x = from.x + nx, .y = from.y + ny },
                .{ .x = to.x + nx, .y = to.y + ny },
                .{ .x = to.x - nx, .y = to.y - ny },
                .{ .x = from.x - nx, .y = from.y - ny },
            });
        }
        // Joins, and the two ends when the subpath is open. Chrome's default
        // cap is butt, so the ends themselves get nothing.
        const joins_from: usize = if (sub.closed) 0 else 1;
        const joins_to: usize = if (sub.closed) pts.len else pts.len - 1;
        for (joins_from..joins_to) |i| {
            disc(scratch, &outline, pts[i], half);
        }
    }

    self.fillPath(scratch, canvas_width, canvas_height, &outline, .nonzero, paint, global_alpha, op);
}

/// The source rectangle and the destination rectangle `drawImage` was given,
/// both in the units the caller used: source pixels and user space.
pub const Blit = struct {
    sx: f64,
    sy: f64,
    sw: f64,
    sh: f64,
    dx: f64,
    dy: f64,
    dw: f64,
    dh: f64,
};

/// Composites another surface's pixels into this one under `ctm`.
///
/// The destination is walked pixel by pixel and each centre is mapped back
/// through the inverse transform into the source, which handles a rotated or
/// skewed blit with the same code as an upright one. Sampling is
/// nearest-neighbour: Chrome box-filters a downscale when
/// `imageSmoothingEnabled` is on, so a minified image is the one case where
/// this lands a different colour rather than a different edge.
pub fn drawSurface(
    self: *Surface,
    scratch: Allocator,
    canvas_width: u32,
    canvas_height: u32,
    src: *const Surface,
    src_width: u32,
    src_height: u32,
    blit: Blit,
    ctm: path_mod.Transform,
    global_alpha: f64,
    op: Composite,
    filter: Filter,
) void {
    const source = src.peek(src_width, src_height) orelse return;
    if (blit.dw == 0 or blit.dh == 0 or blit.sw == 0 or blit.sh == 0) return;
    const inverse = ctm.invert() orelse return;

    // The destination quad, only to find which pixels can be touched.
    var quad_path: Path = .{};
    quad_path.rect(scratch, blit.dx, blit.dy, blit.dw, blit.dh, ctm) catch return;
    const edges = edgesOf(scratch, &quad_path) orelse return;
    const bounds = edgeBounds(edges, canvas_width, canvas_height) orelse return;

    const alpha = std.math.clamp(global_alpha, 0, 1);
    if (alpha <= 0) return;
    const pixels = self.ensure(canvas_width, canvas_height) orelse return;

    const left = @min(blit.dx, blit.dx + blit.dw);
    const top = @min(blit.dy, blit.dy + blit.dh);

    var row = bounds.y0;
    while (row < bounds.y1) : (row += 1) {
        var col = bounds.x0;
        while (col < bounds.x1) : (col += 1) {
            const user = inverse.apply(@as(f64, @floatFromInt(col)) + 0.5, @as(f64, @floatFromInt(row)) + 0.5);
            // Where in the destination rectangle, as a fraction of it.
            const u = (user.x - left) / @abs(blit.dw);
            const v = (user.y - top) / @abs(blit.dh);
            if (u < 0 or u >= 1 or v < 0 or v >= 1) continue;

            const fx = blit.sx + u * blit.sw;
            const fy = blit.sy + v * blit.sh;
            if (fx < 0 or fy < 0) continue;
            const src_x: u32 = @intFromFloat(@floor(fx));
            const src_y: u32 = @intFromFloat(@floor(fy));
            if (src_x >= src_width or src_y >= src_height) continue;

            const from = (@as(usize, src_y) * src_width + src_x) * 4;
            const texel = source[from..][0..4];
            if (texel[3] == 0) continue;
            const paint = filter.applyTo(.{ .r = texel[0], .g = texel[1], .b = texel[2], .a = 255 });
            const at = (row * canvas_width + col) * 4;
            blend(pixels[at..][0..4], paint, alpha * (@as(f64, @floatFromInt(texel[3])) / 255), op);
        }
    }
}

/// Erases the path's coverage, the way `clearRect` erases a rectangle. Only
/// reached for a rotated or skewed `clearRect`; the axis-aligned case has an
/// exact implementation of its own.
pub fn clearPath(self: *Surface, scratch: Allocator, canvas_width: u32, canvas_height: u32, p: *const Path) void {
    const edges = edgesOf(scratch, p) orelse return;
    const bounds = edgeBounds(edges, canvas_width, canvas_height) orelse return;
    const pixels = self.peekMut(canvas_width, canvas_height) orelse return;

    const step: f64 = 1.0 / @as(f64, samples);
    const per_sample = step / 2;

    var row = bounds.y0;
    while (row < bounds.y1) : (row += 1) {
        var col = bounds.x0;
        while (col < bounds.x1) : (col += 1) {
            var hits: u32 = 0;
            var sy: usize = 0;
            while (sy < samples) : (sy += 1) {
                const y = @as(f64, @floatFromInt(row)) + @as(f64, @floatFromInt(sy)) * step + per_sample;
                var sx: usize = 0;
                while (sx < samples) : (sx += 1) {
                    const x = @as(f64, @floatFromInt(col)) + @as(f64, @floatFromInt(sx)) * step + per_sample;
                    if (covers(edges, x, y, .nonzero)) hits += 1;
                }
            }
            if (hits == 0) continue;
            const at = (row * canvas_width + col) * 4;
            if (hits == samples * samples) {
                @memset(pixels[at..][0..4], 0);
                continue;
            }
            const keep = 1 - @as(f64, @floatFromInt(hits)) / (samples * samples);
            const alpha: f64 = @floatFromInt(pixels[at + 3]);
            pixels[at + 3] = @intFromFloat(std.math.clamp(@round(alpha * keep), 0, 255));
        }
    }
}

fn quad(arena: Allocator, out: *Path, corners: [4]Point) void {
    out.subpaths.append(arena, .{}) catch return;
    const sub = &out.subpaths.items[out.subpaths.items.len - 1];
    for (corners) |c| {
        sub.points.append(arena, c) catch return;
    }
    sub.closed = true;
}

fn disc(arena: Allocator, out: *Path, at: Point, radius: f64) void {
    if (radius <= 0) return;
    const steps = 16;
    out.subpaths.append(arena, .{}) catch return;
    const sub = &out.subpaths.items[out.subpaths.items.len - 1];
    for (0..steps) |i| {
        const angle = std.math.tau * @as(f64, @floatFromInt(i)) / steps;
        sub.points.append(arena, .{
            .x = at.x + radius * @cos(angle),
            .y = at.y + radius * @sin(angle),
        }) catch return;
    }
    sub.closed = true;
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

/// Source-over of a straight-alpha `paint` (at effective opacity `alpha`) onto
/// a straight-alpha destination pixel, `op` deciding what the two overlapping
/// opaque parts mix to.
///
/// Measured against Chrome 151 (probes/expr-composite-blend.js): every cell of
/// a (backdrop alpha x source alpha x globalAlpha) sweep lands on the byte
/// Chrome does, bar one channel of one cell — `multiply` with *both* sides
/// half-transparent, where we give 107 and Chrome 106. That one is structural:
/// Chrome's backdrop is premultiplied 8-bit, so the colour it un-premultiplies
/// back out of a half-alpha 128 is 127, not the 128 we still have. Not a bug to
/// chase without making the whole surface premultiplied.
fn blend(dst: *[4]u8, paint: RGBA, alpha: f64, op: Composite) void {
    // A blend mode still needs the backdrop when the source is opaque — but
    // not when there is no backdrop to blend with.
    if (alpha >= 1 and (op == .source_over or dst[3] == 0)) {
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
        // The blend function only governs where source and backdrop overlap;
        // the part of each that the other does not cover stays itself. The two
        // arms are the same expression for `source_over` — spelled separately
        // so its arithmetic, and so every pixel we already produce, is
        // untouched to the last bit.
        const mixed = switch (op) {
            .source_over => (src * alpha + old * dst_alpha * (1 - alpha)) / out_alpha,
            else => (alpha * (1 - dst_alpha) * src +
                alpha * dst_alpha * op.apply(old, src) +
                (1 - alpha) * dst_alpha * old) / out_alpha,
        };
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
    surface.fillRect(4, 4, -1, -1, 3, 3, RGBA.Named.red, 1, .source_over);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[4..8]);
    // Third column of the first row is untouched.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[8..12]);

    // Half-opaque white on top of the red.
    surface.fillRect(4, 4, 0, 0, 1, 1, .{ .r = 255, .g = 255, .b = 255, .a = 128 }, 1, .source_over);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 128, 255 }, surface.pixels[0..4]);

    surface.clearRect(4, 4, 0, 0, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[0..4]);
}

test "raster: readPixels windows out of bounds" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    surface.fillRect(2, 2, 0, 0, 2, 2, RGBA.Named.lime, 1, .source_over);

    var out = [_]u8{0} ** (2 * 2 * 4);
    surface.readPixels(2, 2, 1, 1, 2, 2, &out);
    // Only the canvas' bottom-right pixel lands, at the window's origin.
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[8..12]);
}

test "raster: a filled path is ink, and the winding rule decides the hole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var surface = Surface{ .arena = alloc };
    defer surface.reset();

    // Two concentric circles wound the same way on a 16x16 canvas.
    var p: Path = .{};
    const ctm = path_mod.Transform.identity;
    try p.arc(alloc, 8, 8, 7, 0, std.math.tau, false, ctm);
    try p.arc(alloc, 8, 8, 3, 0, std.math.tau, false, ctm);

    surface.fillPath(alloc, 16, 16, &p, .evenodd, RGBA.Named.red, 1, .source_over);
    // The middle is inside both, so even-odd leaves it alone.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[(8 * 16 + 8) * 4 ..][0..4]);
    // A point between the two radii is inside exactly one.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[(3 * 16 + 8) * 4 ..][0..4]);

    // The same path under the non-zero rule has no hole.
    surface.reset();
    surface.fillPath(alloc, 16, 16, &p, .nonzero, RGBA.Named.red, 1, .source_over);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[(8 * 16 + 8) * 4 ..][0..4]);
}

test "raster: a stroke lands on both sides of its path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var surface = Surface{ .arena = alloc };
    defer surface.reset();

    var p: Path = .{};
    const ctm = path_mod.Transform.identity;
    try p.moveTo(alloc, 0, 4, ctm);
    try p.lineTo(alloc, 8, 4, ctm);

    // Two wide, centred on y=4: rows 3 and 4 are covered whole, row 5 is not.
    surface.strokePath(alloc, 8, 8, &p, 2, RGBA.Named.lime, 1, .source_over);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, surface.pixels[(3 * 8 + 4) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, surface.pixels[(4 * 8 + 4) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[(6 * 8 + 4) * 4 ..][0..4]);
}

test "raster: the blend modes land on Chrome's bytes" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    const backdrop = RGBA{ .r = 255, .g = 128, .b = 0, .a = 255 };
    const source = RGBA{ .r = 64, .g = 128, .b = 192, .a = 255 };
    const half_source = RGBA{ .r = 64, .g = 128, .b = 192, .a = 128 };
    const half_backdrop = RGBA{ .r = 255, .g = 128, .b = 0, .a = 128 };

    // Every expectation below is a Chrome 151 readback
    // (scratch/expr-composite-blend.js), not a hand-derived value — bar the one
    // cell called out in place, where the comment says what Chrome reads.
    const cases = [_]struct {
        back: ?RGBA,
        src: RGBA,
        op: Composite,
        global_alpha: f64 = 1,
        want: [4]u8,
    }{
        // Opaque over opaque is the blend function on its own.
        .{ .back = backdrop, .src = source, .op = .multiply, .want = .{ 64, 64, 0, 255 } },
        .{ .back = backdrop, .src = source, .op = .difference, .want = .{ 191, 0, 192, 255 } },
        // No backdrop: nothing to blend with, so the source lands as-is.
        .{ .back = null, .src = source, .op = .multiply, .want = .{ 64, 128, 192, 255 } },
        .{ .back = null, .src = source, .op = .difference, .want = .{ 64, 128, 192, 255 } },
        // A half-opaque source only blends over the half it covers.
        .{ .back = backdrop, .src = half_source, .op = .multiply, .want = .{ 159, 96, 0, 255 } },
        .{ .back = backdrop, .src = half_source, .op = .difference, .want = .{ 223, 64, 96, 255 } },
        // A `globalAlpha` of 0.5 is *not* tested against Chrome here, and it is
        // the one thing in the sweep that does not line up: Chrome rounds the
        // paint's alpha to a byte, so its 0.5 is 128/255 and it reads 159 where
        // we read 160. That is a divergence in the alpha, not in the blending —
        // it is there under plain source-over too — so it belongs to whatever
        // fixes the alpha rather than being smuggled in here. Measured in
        // scratch/expr-globalalpha-quant.js.
        // A half-opaque backdrop: the uncovered half of the source stays itself.
        .{ .back = half_backdrop, .src = source, .op = .multiply, .want = .{ 64, 96, 96, 255 } },
        .{ .back = half_backdrop, .src = source, .op = .difference, .want = .{ 128, 64, 192, 255 } },
        // Both half-opaque — the one cell of the sweep that does not match, and
        // only under `multiply`: Chrome reads {128, 106, 64, 192} where we read
        // {127, 107, 64, 192}. Both channels land within half a unit of the
        // rounding boundary (127.4998 and 106.65), and Chrome is on the other
        // side of it because its backdrop is premultiplied 8-bit, so what it
        // un-premultiplies out of a half-alpha 128 is 127 (see `blend`). Chasing
        // it means making this whole surface premultiplied. `difference` at the
        // same corner matches whole.
        .{ .back = half_backdrop, .src = half_source, .op = .multiply, .want = .{ 127, 107, 64, 192 } },
        .{ .back = half_backdrop, .src = half_source, .op = .difference, .want = .{ 170, 85, 128, 192 } },
    };

    for (cases, 0..) |case, i| {
        surface.reset();
        if (case.back) |back| {
            surface.fillRect(1, 1, 0, 0, 1, 1, back, 1, .source_over);
        }
        surface.fillRect(1, 1, 0, 0, 1, 1, case.src, case.global_alpha, case.op);
        testing.expectEqualSlices(u8, &case.want, surface.pixels[0..4]) catch |err| {
            std.debug.print("case {d}: {s}\n", .{ i, @tagName(case.op) });
            return err;
        };
    }
}

test "context filter: what a grayscale() string parses to" {
    // Chrome 151 keeps or rejects each of these at the setter, and paints the
    // amount below (scratch/expr-canvas-filter-grayscale.js).
    for ([_]struct { text: []const u8, want: f64 }{
        .{ .text = "grayscale(1)", .want = 1 },
        .{ .text = "grayscale(0)", .want = 0 },
        .{ .text = "grayscale(0.5)", .want = 0.5 },
        .{ .text = "grayscale(.5)", .want = 0.5 },
        .{ .text = "grayscale(+1)", .want = 1 },
        .{ .text = "grayscale(1e0)", .want = 1 },
        .{ .text = "grayscale(50%)", .want = 0.5 },
        .{ .text = "grayscale(100%)", .want = 1 },
        // An empty argument means 1, and anything above 1 clamps to it.
        .{ .text = "grayscale()", .want = 1 },
        .{ .text = "grayscale(2)", .want = 1 },
        // Case-insensitive, and whitespace anywhere is fine.
        .{ .text = "GRAYSCALE(1)", .want = 1 },
        .{ .text = " grayscale( 1 ) ", .want = 1 },
        // Chrome takes an unclosed function; so do we.
        .{ .text = "grayscale(1", .want = 1 },
        // A negative amount never reaches a real context — Chrome's setter
        // drops it — so it reads as no filter rather than as a clamp to 0.
        .{ .text = "grayscale(-1)", .want = 0 },
        // Not a filter we act on: the default, junk, a bare keyword, a chain.
        .{ .text = "none", .want = 0 },
        .{ .text = "", .want = 0 },
        .{ .text = "grayscale", .want = 0 },
        .{ .text = "notafilter(1)", .want = 0 },
        .{ .text = "blur(2px)", .want = 0 },
        .{ .text = "grayscale(1) blur(2px)", .want = 0 },
    }) |case| {
        testing.expectEqual(case.want, Filter.parse(case.text).grayscale) catch |err| {
            std.debug.print("filter '{s}'\n", .{case.text});
            return err;
        };
    }
}

test "context filter: grayscale lands on Chrome's bytes" {
    // The sRGB luminance of each primary, and the interpolation towards it.
    const full: Filter = .{ .grayscale = 1 };
    try testing.expectEqual(RGBA{ .r = 54, .g = 54, .b = 54, .a = 255 }, full.applyTo(RGBA.Named.red));
    try testing.expectEqual(RGBA{ .r = 182, .g = 182, .b = 182, .a = 255 }, full.applyTo(RGBA.Named.lime));
    try testing.expectEqual(RGBA{ .r = 18, .g = 18, .b = 18, .a = 255 }, full.applyTo(RGBA.Named.blue));
    try testing.expectEqual(RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }, full.applyTo(RGBA.Named.white));

    const teal = RGBA{ .r = 64, .g = 128, .b = 192, .a = 255 };
    try testing.expectEqual(RGBA{ .r = 119, .g = 119, .b = 119, .a = 255 }, full.applyTo(teal));
    try testing.expectEqual(
        RGBA{ .r = 92, .g = 124, .b = 156, .a = 255 },
        (Filter{ .grayscale = 0.5 }).applyTo(teal),
    );
    try testing.expectEqual(
        RGBA{ .r = 78, .g = 126, .b = 174, .a = 255 },
        (Filter{ .grayscale = 0.25 }).applyTo(teal),
    );
    // No filter is the identity, alpha included.
    const translucent = RGBA{ .r = 64, .g = 128, .b = 192, .a = 128 };
    try testing.expectEqual(translucent, Filter.none.applyTo(translucent));
    // Alpha survives a filter untouched. Chrome reads 120 rather than our 119
    // here, having greyed the premultiplied bytes; see `blend` for the same
    // one-unit gap under `multiply`.
    try testing.expectEqual(
        RGBA{ .r = 119, .g = 119, .b = 119, .a = 128 },
        full.applyTo(translucent),
    );
}

test "raster: a filter greys the source, not the backdrop" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    // #ff8000, then #4080c0 greyed to 119 and differenced against it. Chrome
    // 151 reads {136, 9, 119, 255}: |255-119|, |128-119|, |0-119| — the filter
    // reached the source only.
    surface.fillRect(1, 1, 0, 0, 1, 1, .{ .r = 255, .g = 128, .b = 0, .a = 255 }, 1, .source_over);
    const greyed = (Filter{ .grayscale = 1 }).applyTo(.{ .r = 64, .g = 128, .b = 192, .a = 255 });
    surface.fillRect(1, 1, 0, 0, 1, 1, greyed, 1, .difference);
    try testing.expectEqualSlices(u8, &.{ 136, 9, 119, 255 }, surface.pixels[0..4]);
}

test "raster: a blend mode reaches a path's partly covered edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var surface = Surface{ .arena = alloc };
    defer surface.reset();

    // 8x1 of #ff8000, then #4080c0 differenced over the left four and a half.
    surface.fillRect(8, 1, 0, 0, 8, 1, .{ .r = 255, .g = 128, .b = 0, .a = 255 }, 1, .source_over);

    var p: Path = .{};
    const ctm = path_mod.Transform.identity;
    try p.rect(alloc, 0, 0, 4.5, 1, ctm);
    surface.fillPath(alloc, 8, 1, &p, .nonzero, .{ .r = 64, .g = 128, .b = 192, .a = 255 }, 1, .difference);

    // Chrome 151 (scratch/expr-composite-blend.js `pathEdge`): four whole
    // pixels of the difference, one at half coverage, three untouched.
    try testing.expectEqualSlices(u8, &.{ 191, 0, 192, 255 }, surface.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 191, 0, 192, 255 }, surface.pixels[3 * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 223, 64, 96, 255 }, surface.pixels[4 * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, surface.pixels[5 * 4 ..][0..4]);
}
