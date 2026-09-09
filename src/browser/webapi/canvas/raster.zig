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
// What is here: a *premultiplied* RGBA8 buffer, axis-aligned rectangle fills, a
// scanline fill and stroke for the flattened paths `path.zig` builds, the three
// gradients as a per-pixel paint `Source`, and source-over compositing under the
// two separable blend modes of `Composite` below. What is still not here: image
// decoding and glyph rasterisation. Text in particular needs a font rasteriser
// to land any ink at all, so a text-based canvas fingerprint still will not
// match Chrome's — see tools/fingerprint.
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
const Paint = color.Paint;
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
    /// The coefficients are the sRGB luminance ones, applied to the channels
    /// themselves — CSS filters do not linearise, and every primary confirms it
    /// (255 red reads 54, green 182, blue 18).
    ///
    /// Chrome greys the *premultiplied* bytes rather than these, which is not
    /// the same arithmetic for a translucent paint — but it reaches the same
    /// stored byte, because premultiplying an unrounded grey rounds only once
    /// either way. `rgba(64, 128, 192, 0.5)` under `grayscale(1)` reads back
    /// 120 on Chrome: greying its premultiplied `{32, 64, 96}` gives 59.5,
    /// and premultiplying this grey 119.02 gives 59.74 — the same 60 stored,
    /// and the same 120 back out.
    pub fn applyTo(self: Filter, paint: Paint) Paint {
        if (self.grayscale <= 0) {
            return paint;
        }

        const luminance = 0.2126 * paint.r + 0.7152 * paint.g + 0.0722 * paint.b;
        // `grayscale(a)` is the spec's matrix, which for every a is exactly
        // this interpolation towards the luminance. Alpha is untouched.
        const mix = struct {
            fn towards(from: f64, to: f64, amount: f64) f64 {
                return from + (to - from) * amount;
            }
        }.towards;
        return .{
            .r = mix(paint.r, luminance, self.grayscale),
            .g = mix(paint.g, luminance, self.grayscale),
            .b = mix(paint.b, luminance, self.grayscale),
            .a = paint.a,
        };
    }
};

/// What a draw op paints with, asked for its colour once per device pixel.
///
/// Every op below used to take one `Paint` for the whole shape, and that was
/// not merely a simplification: it is the reason a gradient fill landed as a
/// flat colour, because a shape whose paint is one value has nowhere to put the
/// coordinates `createLinearGradient` was given. Sampling per pixel is the
/// shape the ops need before any of the three gradients can be evaluated.
///
/// It also decides the shadows for free. A shadow's mask is the shape drawn a
/// second time through this same source (see `castShadow`), so a source whose
/// alpha varies across the shape casts a shadow that varies with it — which is
/// what Chrome does, measured on a ramp from opaque to transparent
/// (probes/canvas-gradient-paint.js, `shadow of a ramp`).
pub const Source = union(enum) {
    /// One colour everywhere: a `fillStyle` that is a colour string, and a
    /// pattern too, which still carries no pixels.
    flat: Paint,
    /// One of the three `create*Gradient` shapes, with its stops resolved.
    gradient: Gradient,

    /// The colour at a point in *device* space, which the ops ask for at each
    /// pixel's centre. Transparent black where the gradient covers nothing.
    pub fn at(self: Source, x: f64, y: f64) Paint {
        return switch (self) {
            .flat => |paint| paint,
            .gradient => |g| g.at(x, y),
        };
    }

    /// True when no point this source could be asked for lands any ink. This is
    /// the early exit a fully transparent paint takes before the op walks a
    /// single pixel; anything that only *sometimes* paints has to answer false
    /// and be tested per pixel.
    pub fn blank(self: Source) bool {
        return switch (self) {
            .flat => |paint| paint.a <= 0,
            .gradient => |g| g.stops.len == 0,
        };
    }

    /// `globalAlpha` as this source multiplies by, which is not the same number
    /// for the two arms.
    ///
    /// A flat fill reaches Skia as a premultiplied eight-bit colour, so its
    /// opacity is a byte before it is ever applied — black over white at 0.5
    /// reads 127, which only `128/255` gives (see `opacity`). A gradient is a
    /// *shader*, and the paint's alpha is scaled into its output in floating
    /// point instead: the same ramp under `globalAlpha = 0.5` reads a
    /// premultiplied 125 where the byte would give 126 (measured,
    /// probes/canvas-gradient-paint.js, `global alpha`).
    pub fn opacityOf(self: Source, global_alpha: f64) f64 {
        return switch (self) {
            .flat => opacity(global_alpha),
            .gradient => std.math.clamp(global_alpha, 0, 1),
        };
    }

    /// How much this source's premultiplied channels are nudged at one device
    /// pixel before they are rounded into the bitmap, on the 0..255 scale.
    ///
    /// Skia dithers a gradient and leaves a flat fill alone, which is why this
    /// belongs to the source rather than to the store. It is not a detail: a
    /// ramp reads a byte either side of the exact interpolation often enough
    /// that ignoring it misses roughly half the pixels of every gradient
    /// measured (probes/canvas-gradient-paint.js).
    pub fn dither(self: Source, col: u32, row: u32) f64 {
        return switch (self) {
            .flat => 0,
            .gradient => ditherOffset(col, row),
        };
    }
};

/// Skia's 8x8 ordered dither, from `SkRasterPipeline`'s `dither` stage: the six
/// low bits of x and y are interleaved and bit-reversed into a Bayer index,
/// which becomes a signed offset of just under half a byte.
///
/// The rate is one part in 255 for an eight-bit bitmap, so on this file's 0..255
/// scale the offset *is* the matrix value — no scaling on the way out.
fn ditherOffset(col: u32, row: u32) f64 {
    const x = col;
    // Only `x` and `x ^ y` are needed from here on, which is how Skia writes it.
    const y = row ^ col;
    const m = ((y & 1) << 5) | ((x & 1) << 4) |
        ((y & 2) << 2) | ((x & 2) << 1) |
        ((y & 4) >> 1) | ((x & 4) >> 2);
    return @as(f64, @floatFromInt(m)) / 64 - 63.0 / 128.0;
}

/// A gradient as the rasteriser evaluates it: a shape in *user* space, the
/// inverse of the transform that was in effect when the fill began, and the
/// stops already resolved into the bitmap's colour space.
///
/// The inverse is what makes the user-space shape work: rather than mapping the
/// gradient forward — which cannot be done for a circle under a non-uniform
/// scale without it stopping being a circle — each device pixel's centre is
/// mapped *back* into user space and the ramp evaluated there. That is Skia's
/// own local-matrix arrangement, and it gives a rotated or skewed gradient for
/// free.
pub const Gradient = struct {
    geometry: Geometry,
    /// Device space to user space. Null geometry rather than a null transform
    /// is how a singular matrix is handled: it cannot arise, because a singular
    /// transform never reaches a draw op with a shape to fill.
    inverse: path_mod.Transform,
    /// Sorted by offset, ties in insertion order. Empty means the gradient
    /// paints nothing at all, which is what the spec says and what Chrome does.
    stops: []const Stop,
    /// Which space the stops' channels are in, and so where the ramp between
    /// two of them is taken.
    interpolation: Interpolation = .srgb,
    /// `ctx.filter`, applied to the mixed colour rather than to each stop.
    ///
    /// The two are the same thing on the sRGB arm — `grayscale()` is affine, so
    /// filtering the ends and interpolating between them is filtering the
    /// interpolation — but they are not on the Oklab one, where the ramp is not
    /// linear in these channels. A filter runs on the source graphic *after*
    /// the shader has produced it, so this is the side to be on.
    filter: Filter = .none,

    /// Chrome takes a gradient's ramp in one of two places, and which one is
    /// decided by the *notation* a stop was written in rather than by the
    /// colour it names or the gamut it needs. `color(srgb 1 0 0)` is the same
    /// in-gamut red as `#ff0000` and ramps differently; `hwb()` is not a legacy
    /// notation and ramps the same as hex. One such stop takes the whole
    /// gradient, not only the segments it ends. All measured —
    /// probes/canvas-gradient-stop-space.js, sixteen rows of one red-to-blue
    /// ramp written every way that names it.
    pub const Interpolation = union(enum) {
        /// Per channel, on the bitmap's own 0..255 scale: hex, a colour name,
        /// `rgb()` in either syntax, `hsl()`, `hsla()`, `hwb()`.
        srgb,
        /// In Oklab: `color()`, `lab()`, `lch()`, `oklab()`, `oklch()`. The
        /// payload is the bitmap's space, which the mixed colour has to be
        /// converted back into — Oklab is absolute, so the way back out is a
        /// second conversion rather than the identity it is for the arm above.
        oklab: color.CanvasSpace,
    };

    /// One stop, its colour already resolved the way a flat `fillStyle` would
    /// be — so a stop and a fill written in the same notation are the same
    /// paint. Alpha stays straight and is interpolated separately in both
    /// arms: the ramp runs before anything premultiplies it (measured — opaque
    /// red to *transparent blue* reads a blue of 130 in the middle, where a
    /// premultiplied ramp carries none).
    pub const Stop = struct {
        offset: f64,
        /// In the gradient's `interpolation` space: the bitmap's own channels
        /// on 0..255 for `srgb`, and L, a, b for `oklab`.
        channels: [3]f64,
        alpha: f64 = 1,
    };

    /// The three shapes, one per factory, in the user-space coordinates the
    /// page wrote. See `CanvasGradient.geometry` for why they are not resolved
    /// when the gradient is made.
    pub const Geometry = union(enum) {
        /// `createLinearGradient(x0, y0, x1, y1)`.
        linear: struct { x0: f64, y0: f64, x1: f64, y1: f64 },
        /// `createRadialGradient(x0, y0, r0, x1, y1, r1)`.
        radial: struct { x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64 },
        /// `createConicGradient(angle, x, y)`.
        conic: struct { angle: f64, x: f64, y: f64 },
    };

    /// The ramp position at a user-space point, before it is clamped. Null
    /// where the gradient covers nothing: a zero-length linear axis, two
    /// identical circles, and — for the two-circle cone — the region outside
    /// it, all of which Chrome leaves as transparent black rather than
    /// extending an end stop over.
    fn position(self: Gradient, x: f64, y: f64) ?f64 {
        switch (self.geometry) {
            .linear => |g| {
                const dx = g.x1 - g.x0;
                const dy = g.y1 - g.y0;
                const length2 = dx * dx + dy * dy;
                if (length2 == 0) return null;
                return ((x - g.x0) * dx + (y - g.y0) * dy) / length2;
            },
            .radial => |g| {
                const cdx = g.x1 - g.x0;
                const cdy = g.y1 - g.y0;
                const dr = g.r1 - g.r0;
                const px = x - g.x0;
                const py = y - g.y0;
                if (cdx == 0 and cdy == 0) {
                    // Concentric, which is the common case and needs no
                    // quadratic: the ramp is the distance from the shared
                    // centre, measured between the two radii.
                    if (dr == 0) return null;
                    return (@sqrt(px * px + py * py) - g.r0) / dr;
                }
                // Skia's two-point conical: the largest `s` whose circle —
                // centre and radius both interpolated by `s` — passes through
                // the point, and whose radius has not gone negative.
                const a = cdx * cdx + cdy * cdy - dr * dr;
                const b = px * cdx + py * cdy + g.r0 * dr;
                const c = px * px + py * py - g.r0 * g.r0;
                if (a == 0) {
                    // The degenerate cone, where the two circles' radii grow
                    // exactly as fast as their centres separate: one root.
                    if (b == 0) return null;
                    const s = c / (2 * b);
                    return if (g.r0 + s * dr >= 0) s else null;
                }
                const discriminant = b * b - a * c;
                if (discriminant < 0) return null;
                const root = @sqrt(discriminant);
                const far = (b + root) / a;
                const near = (b - root) / a;
                if (g.r0 + @max(far, near) * dr >= 0) return @max(far, near);
                if (g.r0 + @min(far, near) * dr >= 0) return @min(far, near);
                return null;
            },
            .conic => |g| {
                // Zero points along +x and the sweep runs clockwise on screen,
                // which is what `atan2` gives with y downwards; the angle is
                // subtracted rather than added (measured, `conic quarter`).
                const turns = (std.math.atan2(y - g.y, x - g.x) - g.angle) / std.math.tau;
                // The sweep wraps rather than clamping — a conic gradient has
                // no outside.
                return turns - @floor(turns);
            },
        }
    }

    /// The colour at a device-space point.
    fn at(self: Gradient, x: f64, y: f64) Paint {
        const nothing: Paint = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (self.stops.len == 0) return nothing;
        const user = self.inverse.apply(x, y);
        const raw = self.position(user.x, user.y) orelse return nothing;
        if (!std.math.isFinite(raw)) return nothing;
        // Both ends extend, which is the spec's clamp and the only tiling a
        // canvas gradient has.
        const t = std.math.clamp(raw, 0, 1);

        // The first stop past `t`. Walking up rather than down is what makes a
        // repeated offset resolve to the *later* stop on the pixel that lands
        // exactly there: both of them are `<= t`, so both are stepped over.
        var above: usize = 0;
        while (above < self.stops.len and self.stops[above].offset <= t) above += 1;
        if (above == 0) return self.paintOf(self.stops[0].channels, self.stops[0].alpha);
        if (above == self.stops.len) {
            const last = self.stops[above - 1];
            return self.paintOf(last.channels, last.alpha);
        }

        const from = self.stops[above - 1];
        const to = self.stops[above];
        const span = to.offset - from.offset;
        if (span <= 0) return self.paintOf(to.channels, to.alpha);
        const u = (t - from.offset) / span;
        var mixed: [3]f64 = undefined;
        for (&mixed, from.channels, to.channels) |*channel, start, end| {
            channel.* = start + (end - start) * u;
        }
        return self.paintOf(mixed, from.alpha + (to.alpha - from.alpha) * u);
    }

    /// A mixed stop as the bitmap takes it: 0..255 in the bitmap's own space,
    /// unclipped and unquantised, which for the sRGB arm the channels already
    /// are.
    fn paintOf(self: Gradient, channels: [3]f64, alpha: f64) Paint {
        const to = switch (self.interpolation) {
            .srgb => return self.filter.applyTo(.{
                .r = channels[0],
                .g = channels[1],
                .b = channels[2],
                .a = alpha,
            }),
            .oklab => |space| space,
        };
        const rgb = color.oklabToSrgb(channels);
        if (to == .srgb) {
            return self.filter.applyTo(.{
                .r = rgb[0] * 255,
                .g = rgb[1] * 255,
                .b = rgb[2] * 255,
                .a = alpha,
            });
        }
        // Oklab is absolute, so a display-p3 bitmap needs the second leg. Only
        // the srgb one is measured; this is the same conversion every other
        // colour on the way into such a bitmap takes.
        const converted = color.convertCanvasUnit(.srgb, to, .{
            @floatCast(rgb[0]),
            @floatCast(rgb[1]),
            @floatCast(rgb[2]),
        });
        return self.filter.applyTo(.{
            .r = @as(f64, converted[0]) * 255,
            .g = @as(f64, converted[1]) * 255,
            .b = @as(f64, converted[2]) * 255,
            .a = alpha,
        });
    }
};

/// Frame-lifetime arena. The buffer is only reclaimed with the frame.
arena: Allocator,
/// Dimensions the current buffer was allocated for. Meaningless when the
/// bitmap is empty.
width: u32 = 0,
height: u32 = 0,
/// What one channel of this bitmap is, which `colorType` picks and which
/// decides which of the two buffers below is the live one.
channels: color.CanvasChannels = .unorm8,
/// Premultiplied RGBA8, row-major, `width * height * 4` long. The `unorm8`
/// store, and empty until something actually draws.
///
/// Premultiplied is what Chrome's bitmap is, and it is observable: the colour
/// has to be un-premultiplied again for `getImageData`, and that does not undo
/// the rounding storing it did. `rgba(200, 100, 50, 0.3)` reads back
/// `c763324d`, not the `c864324d` a straight-alpha bitmap would hand back
/// unchanged (measured -- probes/canvas-alpha-semantics.js). Every consumer
/// that wants the straight bytes a page sees goes through `readPixels`.
pixels: []u8 = &.{},
/// The `float16` store: the same premultiplied RGBA, four half floats a pixel
/// and on the 0..1 scale, `width * height * 4` long.
///
/// Premultiplied all the same — but not rounded, so here the round trip *is*
/// lossless: `color(display-p3 1 0.25 0.5 / 0.5)` comes back as itself, where
/// the eight-bit store moves two of its channels (measured --
/// results/canvas-float-source-channels.chrome.json).
halves: []f16 = &.{},
/// What the bitmap is where nothing has been painted, which `{alpha: false}`
/// changes from transparent black to opaque black. A page can read that back
/// without drawing anything, and every paint onto it composites against black
/// rather than being stored with its own alpha (measured --
/// probes/canvas-alpha-semantics.js).
background: Background = .transparent,

pub const Background = enum {
    transparent,
    /// `{alpha: false}`.
    black,

    fn pixel(self: Background) [4]u8 {
        return switch (self) {
            .transparent => .{ 0, 0, 0, 0 },
            .black => .{ 0, 0, 0, 255 },
        };
    }
};

/// Roughly a 2896x2896 canvas, and half that many pixels in the float16 store,
/// which is twice as wide. Past this we simply refuse to back the canvas, and
/// every operation degrades to the old no-op behaviour. Fingerprinting canvases
/// are tiny; this only guards against a page asking for gigabytes.
pub const max_bytes = 32 * 1024 * 1024;

/// Drops the backing store. Assigning to `canvas.width` / `canvas.height`
/// clears the bitmap in Chrome even when the value does not change.
pub fn reset(self: *Surface) void {
    if (self.pixels.len != 0) {
        self.arena.free(self.pixels);
    }
    if (self.halves.len != 0) {
        self.arena.free(self.halves);
    }
    self.pixels = &.{};
    self.halves = &.{};
    self.width = 0;
    self.height = 0;
}

/// How many pixels the live store holds, which is zero until something draws.
fn count(self: *const Surface) usize {
    return switch (self.channels) {
        .unorm8 => self.pixels.len / 4,
        .float16 => self.halves.len / 4,
    };
}

/// Backs a `width` x `height` canvas, allocating (as the background colour) or
/// reallocating as needed. False when the canvas is degenerate or too big to
/// back, in which case callers should behave as if nothing was drawn.
pub fn ensure(self: *Surface, width: u32, height: u32) bool {
    if (width == 0 or height == 0) {
        return false;
    }
    if (self.count() != 0 and self.width == width and self.height == height) {
        return true;
    }

    const pixels = @as(u64, width) * @as(u64, height);
    switch (self.channels) {
        .unorm8 => {
            if (pixels * 4 > max_bytes) return false;
            const buffer = self.arena.alloc(u8, @intCast(pixels * 4)) catch return false;
            self.reset();
            self.pixels = buffer;
        },
        .float16 => {
            if (pixels * @sizeOf(f16) * 4 > max_bytes) return false;
            const buffer = self.arena.alloc(f16, @intCast(pixels * 4)) catch return false;
            self.reset();
            self.halves = buffer;
        },
    }
    self.width = width;
    self.height = height;
    self.clear(0, @intCast(pixels));
    return true;
}

/// True when there is a buffer of this size to read or write through.
pub fn backed(self: *const Surface, width: u32, height: u32) bool {
    return self.count() != 0 and self.width == width and self.height == height;
}

/// The eight-bit buffer as it stands, without allocating. Null when nothing has
/// been drawn yet, when the canvas has since been resized — both of which mean
/// "every pixel is transparent black" — and when this bitmap is not eight bits
/// a channel at all, since then there are no such bytes to borrow.
pub fn peek(self: *const Surface, width: u32, height: u32) ?[]const u8 {
    if (self.channels != .unorm8 or !self.backed(width, height)) {
        return null;
    }
    return self.pixels;
}

// --- the store, one pixel at a time ----------------------------------------
//
// Everything below the two functions here works in one currency: premultiplied
// RGBA on the 0..255 scale, alpha included, as f64. That is the eight-bit
// store's own scale, so its arithmetic is unchanged to the byte; the float16
// store's channels are 0..1, and the factor of 255 goes on and comes back off
// exactly at f64. What the two stores do *not* share is the quantisation —
// which is the whole of the difference a page can see.

/// One stored pixel, premultiplied, on the 0..255 scale.
fn load(self: *const Surface, at: usize) [4]f64 {
    switch (self.channels) {
        .unorm8 => {
            const stored = self.pixels[at * 4 ..][0..4];
            return .{
                @floatFromInt(stored[0]),
                @floatFromInt(stored[1]),
                @floatFromInt(stored[2]),
                @floatFromInt(stored[3]),
            };
        },
        .float16 => {
            const stored = self.halves[at * 4 ..][0..4];
            return .{
                @as(f64, stored[0]) * 255,
                @as(f64, stored[1]) * 255,
                @as(f64, stored[2]) * 255,
                @as(f64, stored[3]) * 255,
            };
        },
    }
}

/// The same pixel written back. An eight-bit channel rounds and clips here; a
/// half float takes the value as it came, out-of-gamut channels included.
fn store(self: *Surface, at: usize, pixel: [4]f64) void {
    switch (self.channels) {
        .unorm8 => {
            const into = self.pixels[at * 4 ..][0..4];
            for (into, pixel) |*byte, value| byte.* = RGBA.round255(value);
        },
        .float16 => {
            const into = self.halves[at * 4 ..][0..4];
            for (into, pixel) |*half, value| half.* = @floatCast(value / 255);
        },
    }
}

/// Every pixel in `[from, to)` set to the background, which `{alpha: false}`
/// makes opaque black rather than transparent.
fn clear(self: *Surface, from: usize, to: usize) void {
    const pixel = self.background.pixel();
    switch (self.channels) {
        .unorm8 => {
            if (self.background == .transparent) {
                @memset(self.pixels[from * 4 .. to * 4], 0);
                return;
            }
            var at = from;
            while (at < to) : (at += 1) {
                @memcpy(self.pixels[at * 4 ..][0..4], &pixel);
            }
        },
        .float16 => {
            if (self.background == .transparent) {
                @memset(self.halves[from * 4 .. to * 4], 0);
                return;
            }
            var at = from;
            while (at < to) : (at += 1) {
                self.halves[at * 4 ..][0..4].* = .{ 0, 0, 0, 1 };
            }
        },
    }
}

/// One pixel copied out of another bitmap, which is what a snapshot is made of.
/// Both sides are premultiplied, so nothing is divided out on the way — but the
/// two need not be the same channel type, and a float16 source landing in an
/// eight-bit copy quantises here.
pub fn copyPixel(self: *Surface, at: usize, src: *const Surface, src_at: usize) void {
    self.store(at, src.load(src_at));
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

/// `globalAlpha` as the compositor sees it: a byte, not the float a script set.
///
/// Measured (probes/expr-globalalpha-quant.js): black over white at
/// `globalAlpha = 0.5` reads 127. An exact half would store
/// `255 * (1 - 0.5) = 127.5`, which rounds away from that — every other reading
/// here pins the rounding as half away from zero, `rgba(255, 255, 255, 0.1)`
/// answering `1a` for its `25.5` among them — while `128/255` stores
/// `255 * (1 - 128/255) = 127.0` and lands on it. The neighbours agree: 0.502
/// is also a 128 and also reads 127, and 0.498 is a 127 and reads 128.
fn opacity(global_alpha: f64) f64 {
    return @round(std.math.clamp(global_alpha, 0, 1) * 255) / 255;
}

/// A rectangle's edges kept as they were given, clipped to the canvas but not
/// snapped, plus the whole-pixel span that can touch it. An axis-aligned
/// rectangle's coverage is separable -- the overlap of a pixel square with it
/// is the x overlap times the y overlap -- so this is all an exact
/// antialiased fill needs.
const Span = struct {
    left: f64,
    right: f64,
    top: f64,
    bottom: f64,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    fn clip(x: f64, y: f64, w: f64, h: f64, width: u32, height: u32) ?Span {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or
            !std.math.isFinite(w) or !std.math.isFinite(h))
        {
            return null;
        }

        const fw: f64 = @floatFromInt(width);
        const fh: f64 = @floatFromInt(height);
        // Negative extents are normalised, matching the spec.
        const left = std.math.clamp(@min(x, x + w), 0, fw);
        const right = std.math.clamp(@max(x, x + w), 0, fw);
        const top = std.math.clamp(@min(y, y + h), 0, fh);
        const bottom = std.math.clamp(@max(y, y + h), 0, fh);
        if (left >= right or top >= bottom) {
            return null;
        }

        return .{
            .left = left,
            .right = right,
            .top = top,
            .bottom = bottom,
            .x0 = @intFromFloat(@floor(left)),
            .y0 = @intFromFloat(@floor(top)),
            .x1 = @intFromFloat(@min(@ceil(right), fw)),
            .y1 = @intFromFloat(@min(@ceil(bottom), fh)),
        };
    }

    /// How much of the pixel at `i` the interval `[lo, hi)` covers, in [0, 1].
    fn cover(lo: f64, hi: f64, i: u32) f64 {
        const a: f64 = @floatFromInt(i);
        return std.math.clamp(@min(hi, a + 1) - @max(lo, a), 0, 1);
    }
};

/// Composites `source` over the rectangle, `global_alpha` scaling its opacity.
///
/// Fractional edges are antialiased by area, which is what Chrome does and what
/// this used to round away. Measured (probes/expr-aa-coverage-curve.js): with a
/// rectangle's right edge at `24 + f/16`, Chrome's coverage of column 24 walks
/// `round(255 * f/16)` exactly -- 0, 16, 32 ... 239 -- while snapping the edge
/// answered 0 for the first half of the sweep and 255 for the second. An
/// axis-aligned rectangle's coverage is separable, so the exact area is the x
/// overlap times the y overlap and needs no sampling.
///
/// The general path rasteriser below is a separate matter and deliberately
/// untouched: there Chrome is the *coarser* of the two (quarter steps against
/// our sixteenths), and it is the shared path for text and every shape.
pub fn fillRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64, source: Source, global_alpha: f64, op: Composite) void {
    const span = Span.clip(x, y, w, h, canvas_width, canvas_height) orelse return;
    if (!self.ensure(canvas_width, canvas_height)) return;

    const global = source.opacityOf(global_alpha);
    if (global <= 0 or source.blank()) {
        return;
    }

    var row = span.y0;
    while (row < span.y1) : (row += 1) {
        const cover_y = Span.cover(span.top, span.bottom, row);
        if (cover_y <= 0) continue;
        var col = span.x0;
        while (col < span.x1) : (col += 1) {
            const cover = cover_y * Span.cover(span.left, span.right, col);
            if (cover <= 0) continue;
            const paint = source.at(@as(f64, @floatFromInt(col)) + 0.5, @as(f64, @floatFromInt(row)) + 0.5);
            const alpha = global * paint.a * cover;
            if (alpha <= 0) continue;
            const at = row * canvas_width + col;
            self.store(at, blended(self.load(at), paint, alpha, op, source.dither(col, row)));
        }
    }
}

/// Resets the rectangle to transparent black. Unlike `fillRect` this does not
/// composite, so it does not need a buffer that does not already exist.
pub fn clearRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64) void {
    const bounds = Bounds.clip(x, y, w, h, canvas_width, canvas_height) orelse return;
    if (!self.backed(canvas_width, canvas_height)) return;

    var row = bounds.y0;
    while (row < bounds.y1) : (row += 1) {
        self.clear(row * canvas_width + bounds.x0, row * canvas_width + bounds.x1);
    }
}

/// Strokes the rectangle's outline as four bands centred on its edges, which
/// is what a real stroke of an axis-aligned rectangle degenerates to once
/// joins and caps have nothing to round off.
pub fn strokeRect(self: *Surface, canvas_width: u32, canvas_height: u32, x: f64, y: f64, w: f64, h: f64, line_width: f64, source: Source, global_alpha: f64, op: Composite) void {
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
    self.fillRect(canvas_width, canvas_height, left - half, top - half, outer_w, line_width, source, global_alpha, op);
    self.fillRect(canvas_width, canvas_height, left - half, bottom - half, outer_w, line_width, source, global_alpha, op);
    const inner_h = (bottom - top) - line_width;
    if (inner_h > 0) {
        self.fillRect(canvas_width, canvas_height, left - half, top + half, line_width, inner_h, source, global_alpha, op);
        self.fillRect(canvas_width, canvas_height, right - half, top + half, line_width, inner_h, source, global_alpha, op);
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

/// Fills `p` — already flattened and already in device space — with `source`.
/// `scratch` is only used for the edge list and may be a call-lifetime arena.
pub fn fillPath(self: *Surface, scratch: Allocator, canvas_width: u32, canvas_height: u32, p: *const Path, rule: FillRule, source: Source, global_alpha: f64, op: Composite) void {
    const edges = edgesOf(scratch, p) orelse return;
    const bounds = edgeBounds(edges, canvas_width, canvas_height) orelse return;

    const global = source.opacityOf(global_alpha);
    if (global <= 0 or source.blank()) {
        return;
    }
    if (!self.ensure(canvas_width, canvas_height)) return;

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
            const paint = source.at(@as(f64, @floatFromInt(col)) + 0.5, @as(f64, @floatFromInt(row)) + 0.5);
            const alpha = global * paint.a;
            if (alpha <= 0) continue;
            const coverage = @as(f64, @floatFromInt(hits)) / (samples * samples);
            const at = row * canvas_width + col;
            self.store(at, blended(self.load(at), paint, alpha * coverage, op, source.dither(col, row)));
        }
    }
}

/// Strokes `p` by filling, for each segment, the quad `line_width` across that
/// the segment sweeps, plus a disc at every join. A round join everywhere is
/// not what `lineJoin` says, but it is the shape a miter and a bevel both
/// approach as the segments get short — and a flattened curve's segments are
/// short by construction.
pub fn strokePath(self: *Surface, scratch: Allocator, canvas_width: u32, canvas_height: u32, p: *const Path, line_width: f64, source: Source, global_alpha: f64, op: Composite) void {
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

    self.fillPath(scratch, canvas_width, canvas_height, &outline, .nonzero, source, global_alpha, op);
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
    /// The two bitmaps' colour spaces. Equal for every canvas pair until one of
    /// them is created display-p3, and then every texel is converted.
    spaces: color.SpaceChange,
    blit: Blit,
    ctm: path_mod.Transform,
    global_alpha: f64,
    op: Composite,
    filter: Filter,
) void {
    if (!src.backed(src_width, src_height)) return;
    if (blit.dw == 0 or blit.dh == 0 or blit.sw == 0 or blit.sh == 0) return;
    const inverse = ctm.invert() orelse return;

    // The destination quad, only to find which pixels can be touched.
    var quad_path: Path = .{};
    quad_path.rect(scratch, blit.dx, blit.dy, blit.dw, blit.dh, ctm) catch return;
    const edges = edgesOf(scratch, &quad_path) orelse return;
    const bounds = edgeBounds(edges, canvas_width, canvas_height) orelse return;

    const alpha = opacity(global_alpha);
    if (alpha <= 0) return;
    if (!self.ensure(canvas_width, canvas_height)) return;

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

            const texel = src.load(@as(usize, src_y) * src_width + src_x);
            if (texel[3] == 0) continue;
            // The source bitmap is premultiplied too, so the colour has to come
            // back out of its own alpha before it can be converted or blended.
            // Then into this bitmap's colour space, then through the filter — the
            // same order `context_draw`'s `paint` uses for a fill.
            const paint = filter.applyTo(color.convertCanvasPaint(spaces.from, spaces.to, straight(texel)));
            const at = row * canvas_width + col;
            self.store(at, blended(self.load(at), paint, alpha * paint.a, op, 0));
        }
    }
}

/// Erases the path's coverage, the way `clearRect` erases a rectangle. Only
/// reached for a rotated or skewed `clearRect`; the axis-aligned case has an
/// exact implementation of its own.
pub fn clearPath(self: *Surface, scratch: Allocator, canvas_width: u32, canvas_height: u32, p: *const Path) void {
    const edges = edgesOf(scratch, p) orelse return;
    const bounds = edgeBounds(edges, canvas_width, canvas_height) orelse return;
    if (!self.backed(canvas_width, canvas_height)) return;

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
            const at = row * canvas_width + col;
            if (hits == samples * samples) {
                self.clear(at, at + 1);
                continue;
            }
            const covered = @as(f64, @floatFromInt(hits)) / (samples * samples);
            if (self.background == .black) {
                // Clearing part of an opaque canvas paints that much black over
                // it; the pixel stays opaque either way.
                self.store(at, blended(self.load(at), .{ .r = 0, .g = 0, .b = 0 }, covered, .source_over, 0));
                continue;
            }
            // Premultiplied, so scaling the alpha down means scaling the colour
            // with it — the colour *is* the colour times the alpha.
            var faded = self.load(at);
            for (&faded) |*channel| channel.* *= 1 - covered;
            self.store(at, faded);
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

/// One premultiplied pixel as the straight colour a page reads: the channels
/// divided back out of their own alpha.
///
/// The division is the whole of the divergence this bitmap's premultiplication
/// buys, because it does not undo the rounding that storing the pixel did.
/// Measured (probes/canvas-alpha-semantics.js): `rgba(200, 100, 50, 0.3)`
/// stores `{60, 30, 15, 77}` and comes back out as `c76332`, where the 200 that
/// went in is gone for good.
fn straight(pixel: [4]f64) Paint {
    const alpha = pixel[3];
    if (alpha == 0) {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    return .{
        .r = pixel[0] * 255 / alpha,
        .g = pixel[1] * 255 / alpha,
        .b = pixel[2] * 255 / alpha,
        .a = alpha / 255,
    };
}

/// `straight`, in the arithmetic a float read has to be done in: normalised
/// channels, and every step in f32.
///
/// The value is the same one; the width and the order it is reached in are not,
/// and at f32 they are visible. Chrome normalises by a reciprocal — `channel *
/// (1 / 255)` — and then un-premultiplies by a second one, `1 / alpha`, both in
/// f32. Measured (probes/canvas-image-data-construct.js) against two pixels
/// that between them rule out every neighbouring order:
///
///   {60, 30, 15, 77}    0.7792208194732666  0.3896104097366333  0.19480520486831665
///   {234, 51, 35, 255}  0.917647123336792   0.20000001788139343 0.13725490868091583
///
/// Dividing by 255 instead of multiplying by its reciprocal lands one ULP low
/// on the second row; dividing by the alpha byte before normalising lands one
/// ULP high on the first. An alpha of 3 pins the alpha channel the same way:
/// `3 * (1 / 255)` is `0.011764707043766975` where `3 / 255` is
/// `0.0117647061124444`.
fn straightUnit(pixel: *const [4]u8) [4]f32 {
    const inv255: f32 = 1.0 / 255.0;
    const alpha = @as(f32, @floatFromInt(pixel[3])) * inv255;
    if (alpha == 0) {
        return .{ 0, 0, 0, 0 };
    }
    const inv_alpha = 1 / alpha;
    return .{
        @as(f32, @floatFromInt(pixel[0])) * inv255 * inv_alpha,
        @as(f32, @floatFromInt(pixel[1])) * inv255 * inv_alpha,
        @as(f32, @floatFromInt(pixel[2])) * inv255 * inv_alpha,
        alpha,
    };
}

/// The float16 store's own un-premultiplication, which has no normalising step
/// to do: the channels are already 0..1, so the whole of it is the division by
/// the alpha *as stored*. Measured
/// (results/canvas-float-source-channels.chrome.json): `rgba(255, 0, 0, 0.5)`
/// on a display-p3 float16 bitmap reads a red of 0.91796875 where the opaque
/// fill reads 0.91748046875 — the round trip through a half-precision 128/255
/// moved it, and dividing by anything but that same stored alpha does not land
/// there.
fn straightHalf(pixel: *const [4]f16) [4]f32 {
    const alpha: f32 = pixel[3];
    if (alpha == 0) {
        return .{ 0, 0, 0, 0 };
    }
    return .{
        @as(f32, pixel[0]) / alpha,
        @as(f32, pixel[1]) / alpha,
        @as(f32, pixel[2]) / alpha,
        alpha,
    };
}

/// What a draw op casts before it puts the shape down: the shape's own
/// coverage, blurred, tinted with `shadowColor` and moved by the offset.
///
/// Measured on headed Chrome (probes/canvas-shadow-blur.js). The shadow's
/// alpha is the shape's coverage times the shape's own alpha times this
/// colour's — a translucent shape and a translucent `shadowColor` land on the
/// same bytes — and it goes *under* the shape, so with no offset the shape
/// wins its own pixels and the blur only shows either side.
pub const Shadow = struct {
    /// `shadowColor`, unpremultiplied, on `Paint`'s scale. A zero alpha here
    /// is the default state and draws nothing at all.
    color: Paint,
    /// `shadowBlur`, in *device* pixels: the transform does not reach it.
    /// The same shape under a `scale(0.384, 0.384)`, its coordinates divided
    /// out so the device shape is identical, blurs byte-identically.
    blur: f64,
    /// `shadowOffsetX` / `shadowOffsetY`, device pixels and untransformed too.
    dx: f64,
    dy: f64,

    pub fn draws(self: Shadow) bool {
        return self.color.a > 0;
    }
};

/// Skia's own `hasNoBlur`. Under it a shadow is the silhouette itself, and the
/// line is sharp: sigma 0.3 draws the shape unblurred where 0.35 blurs it
/// (results/canvas-shadow-blur.chrome.json, the `taps` sweep).
fn blurs(sigma: f64) bool {
    return 3 * sigma > 1;
}

/// Where Skia changes kernel: the box triple above, the discrete Gaussian
/// below. `SkGaussFilter` asserts the same bound.
const small_sigma = 2;

/// The box window Skia picks for a sigma of 2 or more. Three passes of it
/// approximate a Gaussian, and the approximation is what Chrome puts on the
/// bitmap: at nine radii from 4 to 32 three box convolutions reproduce its
/// bytes with no residual at all.
fn blurWindow(sigma: f64) u32 {
    const scaled = @floor(sigma * 3 * @sqrt(2 * std.math.pi) / 4 + 0.5);
    if (!(scaled >= 2)) return 1;
    if (scaled > 512) return 512;
    return @intFromFloat(scaled);
}

/// A tap this small is where `SkGaussFilter` stops expanding outward.
const gauss_cutoff = 1.0 / 100.0;

/// Room for every tap the recurrence produces below sigma 2 — nine taps at
/// sigma 1.95, so five on the half — with slack for the bound itself.
const max_gauss_taps = 12;

/// The modified Bessel function of the first kind, by its defining series.
/// The argument is a variance below 4, since only the small-sigma branch asks,
/// so twenty-odd terms are already past what a double can hold.
fn besselI(order: u32, x: f64) f64 {
    var term = std.math.pow(f64, x / 2, @floatFromInt(order));
    for (1..order + 1) |i| term /= @floatFromInt(i);
    var sum = term;
    const square = x * x / 4;
    var k: u32 = 1;
    while (k < 24) : (k += 1) {
        term *= square / (@as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(k + order)));
        sum += term;
    }
    return sum;
}

/// Half of Skia's discrete Gaussian, `out[0]` being the centre tap: the
/// Bessel form `gauss(n) = I_n(var) / e^var` from "Scale-Space for Discrete
/// Signals", expanded outward by the recurrence until a tap falls below the
/// cutoff and then normalised to sum to one across the whole kernel.
///
/// It is a *discrete* Gaussian and not a sampled one, and the tails are where
/// that shows: Chrome answers `13,54,121,54,13` at sigma 1, which an
/// erf-integrated Gaussian fitted freely still misses by 23 across the row.
/// This form reproduces all eight measured kernels to the byte.
fn gaussTaps(sigma: f64, out: *[max_gauss_taps]f64) usize {
    const variance = sigma * sigma;
    const decay = @exp(variance);
    out[0] = besselI(0, variance) / decay;
    out[1] = besselI(1, variance) / decay;
    var n: usize = 1;
    while (n + 1 < max_gauss_taps and out[n] > gauss_cutoff) : (n += 1) {
        out[n + 1] = out[n - 1] - (2 * @as(f64, @floatFromInt(n)) / variance) * out[n];
    }
    var kept: usize = 1;
    while (kept < max_gauss_taps and out[kept] > gauss_cutoff) kept += 1;
    var total = out[0];
    for (out[1..kept]) |tap| total += 2 * tap;
    for (out[0..kept]) |*tap| tap.* /= total;
    return kept;
}

/// One symmetric convolution along a line, the counterpart of `boxLine` for
/// the small-sigma branch. Everything past either end reads as zero.
fn gaussLine(out: []f64, in: []const f64, taps: []const f64) void {
    const len: isize = @intCast(in.len);
    const radius: isize = @intCast(taps.len - 1);
    for (out, 0..) |*cell, i| {
        const at: isize = @intCast(i);
        var sum = taps[0] * in[i];
        var away: isize = 1;
        while (away <= radius) : (away += 1) {
            const tap = taps[@intCast(away)];
            const before = at - away;
            const after = at + away;
            if (before >= 0) sum += tap * in[@intCast(before)];
            if (after < len) sum += tap * in[@intCast(after)];
        }
        cell.* = sum;
    }
}

/// The three passes as (width, left offset) pairs. An odd window is three
/// equal centred boxes; an even one is (w, w, w+1) with the first shifted one
/// to the left, which is how Skia keeps an even box centred — both measured
/// byte-exact, the even arrangement at blurs 4, 6, 8, 11 and 32.
fn blurPasses(window: u32) [3][2]u32 {
    if (window % 2 == 1) {
        const half = (window - 1) / 2;
        return .{ .{ window, half }, .{ window, half }, .{ window, half } };
    }
    const half = window / 2;
    return .{ .{ window, half - 1 }, .{ window, half }, .{ window + 1, half } };
}

/// How much room a shadow's mask needs on every side of the canvas: the blur
/// reaches past the edge, and a shape that is itself off-canvas can still cast
/// onto it.
pub fn shadowMargin(blur: f64) u32 {
    const sigma = blur / 2;
    if (!blurs(sigma)) return 0;
    if (sigma < small_sigma) return max_gauss_taps;
    const window = blurWindow(sigma);
    if (window <= 1) return 0;
    return window * 3 / 2 + 2;
}

/// One box pass along a line, `out[i]` being the mean of the `n` samples
/// starting `off` back from `i`. Everything past either end reads as zero,
/// which is what an empty bitmap is.
fn boxLine(out: []f64, in: []const f64, n: u32, off: u32) void {
    const len: isize = @intCast(in.len);
    const width: isize = @intCast(n);
    const back: isize = @intCast(off);
    var sum: f64 = 0;
    var k: isize = -back;
    while (k < -back + width) : (k += 1) {
        if (k >= 0 and k < len) sum += in[@intCast(k)];
    }
    const scale = 1 / @as(f64, @floatFromInt(n));
    var i: isize = 0;
    while (i < len) : (i += 1) {
        out[@intCast(i)] = sum * scale;
        const leaves = i - back;
        const enters = leaves + width;
        if (leaves >= 0 and leaves < len) sum -= in[@intCast(leaves)];
        if (enters >= 0 and enters < len) sum += in[@intCast(enters)];
    }
}

/// Three box passes on each axis, in place, on a mask of whole 0..255 values.
/// Separable, so the two axes are independent — which a 4x4 square proves by
/// handing back the product of the two and a full-height bar proves by handing
/// back one of them alone.
///
/// The mask is rounded back to whole values *between* the axes, which is Skia
/// writing its eight-bit intermediate out before the second pass reads it. It
/// is worth a byte: on the square above, carrying full precision across lands
/// 16 where Chrome has 15, and rounding between the two axes reproduces the
/// whole profile exactly. Rounding after every individual pass does not.
fn blurMask(scratch: Allocator, mask: []f64, width: u32, height: u32, sigma: f64) void {
    if (!blurs(sigma)) return;
    var half: [max_gauss_taps]f64 = undefined;
    const taps: []const f64 = if (sigma < small_sigma) half[0..gaussTaps(sigma, &half)] else &.{};
    const window = if (taps.len == 0) blurWindow(sigma) else 0;
    if (taps.len == 0 and window <= 1) return;
    const passes = blurPasses(if (window == 0) 1 else window);

    const line = scratch.alloc(f64, @max(width, height)) catch return;
    defer scratch.free(line);
    const into = scratch.alloc(f64, @max(width, height)) catch return;
    defer scratch.free(into);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = mask[y * width ..][0..width];
        if (taps.len != 0) {
            gaussLine(into[0..width], row, taps);
            @memcpy(row, into[0..width]);
        } else for (passes) |pass| {
            boxLine(into[0..width], row, pass[0], pass[1]);
            @memcpy(row, into[0..width]);
        }
        for (row) |*cell| cell.* = @round(cell.*);
    }
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        for (line[0..height], 0..) |*cell, at| cell.* = mask[at * width + x];
        if (taps.len != 0) {
            gaussLine(into[0..height], line[0..height], taps);
            @memcpy(line[0..height], into[0..height]);
        } else for (passes) |pass| {
            boxLine(into[0..height], line[0..height], pass[0], pass[1]);
            @memcpy(line[0..height], into[0..height]);
        }
        for (line[0..height], 0..) |cell, at| mask[at * width + x] = cell;
    }
}

/// Composites `shadow` onto the canvas from `mask`, which the caller has
/// already drawn the shape into: a bitmap `2 * margin` wider and taller than
/// the canvas, with the shape moved by the offset *and* the margin, so mask
/// pixel `(x + margin, y + margin)` is already the shadow's own pixel.
///
/// Drawing the shape into a mask rather than tracking coverage inside every op
/// is what keeps this one function: whatever the op can rasterise, it can cast.
pub fn castShadow(
    self: *Surface,
    scratch: Allocator,
    canvas_width: u32,
    canvas_height: u32,
    mask: *const Surface,
    margin: u32,
    shadow: Shadow,
    op: Composite,
) void {
    if (mask.width != canvas_width + 2 * margin or mask.height != canvas_height + 2 * margin) return;
    if (!mask.backed(mask.width, mask.height)) return;
    const cover = scratch.alloc(f64, mask.width * mask.height) catch return;
    defer scratch.free(cover);
    for (cover, 0..) |*cell, at| cell.* = mask.load(at)[3];
    blurMask(scratch, cover, mask.width, mask.height, shadow.blur / 2);
    if (!self.ensure(canvas_width, canvas_height)) return;

    var row: u32 = 0;
    while (row < canvas_height) : (row += 1) {
        var col: u32 = 0;
        while (col < canvas_width) : (col += 1) {
            const alpha = cover[(row + margin) * mask.width + col + margin] / 255 * shadow.color.a;
            if (alpha <= 0) continue;
            const at = row * canvas_width + col;
            self.store(at, blended(self.load(at), shadow.color, alpha, op, 0));
        }
    }
}

/// Copies a `sw` x `sh` window starting at (`sx`, `sy`) into `out`, which must
/// be `sw * sh * 4` long and already zeroed, un-premultiplying on the way: this
/// is the straight-alpha form `getImageData` and a PNG both want. The window
/// may sit partly (or entirely) outside the canvas; those pixels stay
/// transparent black.
pub fn readPixels(self: *const Surface, canvas_width: u32, canvas_height: u32, sx: i64, sy: i64, sw: u32, sh: u32, out: []u8) void {
    // An opaque canvas that has never been painted still reads back as opaque
    // black, so the absence of a buffer is not the absence of pixels. `out`
    // arrives zeroed, which is already right for a transparent one.
    const painted = self.backed(canvas_width, canvas_height);
    if (!painted and self.background == .transparent) {
        return;
    }
    const background = self.background.pixel();

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
            const to: usize = (@as(usize, row) * sw + col) * 4;
            if (!painted) {
                @memcpy(out[to..][0..4], &background);
                continue;
            }
            const from: usize = @as(usize, @intCast(src_y)) * canvas_width +
                @as(usize, @intCast(src_x));
            const pixel = switch (self.channels) {
                .unorm8 => straightUnit(self.pixels[from * 4 ..][0..4]),
                .float16 => straightHalf(self.halves[from * 4 ..][0..4]),
            };
            for (out[to..][0..4], pixel) |*byte, channel| byte.* = toUnorm8(channel);
        }
    }
}

/// A normalised channel as the byte a readback answers, which is Skia's
/// `to_unorm`: clamped into the unit range, scaled, and rounded with ties going
/// to the *even* neighbour rather than away from zero.
///
/// The tie is reachable and the two rules disagree there. Measured
/// (probes/canvas-gradient-paint.js): a stored 6 over an alpha of 36 is exactly
/// 42.5 once scaled, and Chrome answers 42. That is what `_mm_cvtps_epi32` and
/// `vcvtnq_s32_f32` do by default, which is how Skia gets there — it converts,
/// it does not round and then truncate.
fn toUnorm8(value: f32) u8 {
    const scaled = std.math.clamp(value, 0, 1) * 255;
    const below = @floor(scaled);
    const fraction = scaled - below;
    const rounded = if (fraction > 0.5)
        below + 1
    else if (fraction < 0.5)
        below
    else if (@mod(below, 2) == 0)
        below
    else
        below + 1;
    return @intFromFloat(rounded);
}

/// One straight-alpha pixel in the premultiplied form the bitmap stores, which
/// is how an ImageData's bytes have to arrive. The rounding is a fill's: a
/// `blend` of the same colour at the same alpha stores the same byte.
pub fn premultiply(pixel: *const [4]u8) [4]u8 {
    const alpha = @as(f64, @floatFromInt(pixel[3])) / 255;
    return .{
        RGBA.round255(@as(f64, @floatFromInt(pixel[0])) * alpha),
        RGBA.round255(@as(f64, @floatFromInt(pixel[1])) * alpha),
        RGBA.round255(@as(f64, @floatFromInt(pixel[2])) * alpha),
        pixel[3],
    };
}

/// The same window `readPixels` copies, left unquantised: four normalised f32
/// channels a pixel rather than four bytes, so the un-premultiplication is not
/// rounded into a byte on the way out. `out` must be `sw * sh` long and already
/// transparent black; the window may hang off any edge, and those pixels stay as
/// they came.
///
/// This is what the float pixel formats read through, and the byte in between is
/// observable. Measured (probes/canvas-image-data-construct.js): a premultiplied
/// `{60, 30, 15, 77}` pixel is `199` through `rgba-unorm8` —
/// `round(60 * 255 / 77)` — but `0.7792208194732666` through `rgba-float32`,
/// which is `60 / 77`, and `0.779296875` through `rgba-float16`, which is that
/// same quotient at half precision rather than `199 / 255`. See `straightUnit`
/// for the arithmetic that last bit needs.
pub fn readUnitPixels(self: *const Surface, canvas_width: u32, canvas_height: u32, sx: i64, sy: i64, sw: u32, sh: u32, out: [][4]f32) void {
    const painted = self.backed(canvas_width, canvas_height);
    if (!painted and self.background == .transparent) {
        return;
    }
    const background = straightUnit(&self.background.pixel());

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
            const to: usize = @as(usize, row) * sw + col;
            if (!painted) {
                out[to] = background;
                continue;
            }
            const from: usize = @as(usize, @intCast(src_y)) * canvas_width +
                @as(usize, @intCast(src_x));
            out[to] = switch (self.channels) {
                .unorm8 => straightUnit(self.pixels[from * 4 ..][0..4]),
                .float16 => straightHalf(self.halves[from * 4 ..][0..4]),
            };
        }
    }
}

/// The other direction: overwrites a `sw` x `sh` window at (`dx`, `dy`) with
/// `bytes`, which are the straight-alpha RGBA8 an ImageData carries and must be
/// `sw * sh * 4` long. Nothing is composited — the destination pixels are
/// replaced, alpha and all — and the window may hang off any edge, those pixels
/// simply being dropped.
///
/// On a transparent canvas the bytes are premultiplied on the way in, which is
/// the whole of why `putImageData` does not round-trip: `{200, 100, 50, 77}`
/// stores `{60, 30, 15, 77}` and reads back `c763324d`.
///
/// An opaque canvas does *not* premultiply them, and since the read divides by
/// the alpha either way, a translucent pixel comes back brighter than it went
/// in. Measured (probes/canvas-put-image-data.js): the same bytes on an
/// `{alpha: false}` canvas read `ffffa64d`, and `{100, 50, 25, 128}` reads
/// `c7643280` where premultiplying would have read `64321a80`.
pub fn writePixels(self: *Surface, canvas_width: u32, canvas_height: u32, dx: i64, dy: i64, sw: u32, sh: u32, bytes: []const u8) void {
    if (!self.ensure(canvas_width, canvas_height)) return;

    var row: u32 = 0;
    while (row < sh) : (row += 1) {
        const dst_y = dy + @as(i64, row);
        if (dst_y < 0 or dst_y >= canvas_height) {
            continue;
        }

        var col: u32 = 0;
        while (col < sw) : (col += 1) {
            const dst_x = dx + @as(i64, col);
            if (dst_x < 0 or dst_x >= canvas_width) {
                continue;
            }
            const from: usize = (@as(usize, row) * sw + col) * 4;
            const to: usize = @as(usize, @intCast(dst_y)) * canvas_width +
                @as(usize, @intCast(dst_x));
            const pixel = bytes[from..][0..4];
            const straight_alpha: f64 = @floatFromInt(pixel[3]);
            // The eight-bit store rounds each of these back to the byte
            // `premultiply` would have handed it; the float one keeps the
            // product.
            const scale: f64 = switch (self.background) {
                .transparent => straight_alpha / 255,
                .black => 1,
            };
            self.store(to, .{
                @as(f64, @floatFromInt(pixel[0])) * scale,
                @as(f64, @floatFromInt(pixel[1])) * scale,
                @as(f64, @floatFromInt(pixel[2])) * scale,
                straight_alpha,
            });
        }
    }
}

/// The whole bitmap as the straight-alpha bytes a page reads, allocated on
/// `arena`. The store is premultiplied, so the two consumers that hand the
/// pixels straight out — a PNG and a VideoFrame — cannot borrow it the way
/// `peek` lets a second surface do.
///
/// Null when the canvas has no pixels to hand back at all, which every caller
/// already reads as "every pixel is transparent black".
pub fn straightPixels(self: *const Surface, arena: Allocator, canvas_width: u32, canvas_height: u32) !?[]u8 {
    if (!self.backed(canvas_width, canvas_height) and self.background == .transparent) {
        return null;
    }
    const out = try arena.alloc(u8, @as(usize, canvas_width) * canvas_height * 4);
    @memset(out, 0);
    self.readPixels(canvas_width, canvas_height, 0, 0, canvas_width, canvas_height, out);
    return out;
}

/// Source-over of `paint` (at effective opacity `alpha`) onto a premultiplied
/// destination pixel, `op` deciding what the two overlapping opaque parts mix
/// to. The result is premultiplied too: the compositing spec's `co` and `ao`,
/// stored as they come out rather than divided back apart.
///
/// This is where the bitmap's premultiplication is worth having. Measured
/// against Chrome 151 (probes/expr-composite-blend.js), a (backdrop alpha x
/// source alpha x globalAlpha) sweep now lands on Chrome's byte in every cell —
/// including `multiply` with *both* sides half-transparent, which a
/// straight-alpha bitmap got wrong: it un-premultiplies a half-alpha 64 back
/// into 127.5, where a straight bitmap still had the 128 that went in, and the
/// 106 Chrome reads follows from the 127.5.
///
/// `dither` is the source's ordered-dither offset (see `Source.dither`), added
/// to each premultiplied output channel. Skia's dither stage sits between the
/// shader and the blend, and for source-over — every measurement there is —
/// that is exactly this: the premultiplied source term is the only one the
/// offset can land on, so adding it to the sum and adding it to the source come
/// out the same. Under a blend mode the two would part company, and nothing
/// measured says which Chrome does.
fn blended(dst: [4]f64, paint: Paint, alpha: f64, op: Composite, dither: f64) [4]f64 {
    const dst_alpha = dst[3] / 255;
    // A blend function needs the backdrop's own colour, and there is none to
    // have when the backdrop is empty: every operator degenerates to
    // source-over there.
    const blend_op = if (dst[3] == 0) Composite.source_over else op;

    const out_alpha = alpha + dst_alpha * (1 - alpha);
    if (out_alpha <= 0) {
        return .{ 0, 0, 0, 0 };
    }

    const backdrop = straight(dst);
    const src_channels = [3]f64{ paint.r, paint.g, paint.b };
    const old_channels = [3]f64{ backdrop.r, backdrop.g, backdrop.b };
    var out: [4]f64 = .{ 0, 0, 0, out_alpha * 255 };
    for (src_channels, old_channels, 0..) |src, old, i| {
        // The blend function only governs where source and backdrop overlap;
        // the part of each that the other does not cover stays itself. Both
        // arms are the spec's `co`, and the term the source does not cover is
        // `(1 - as) * ab * Cb` — which is `(1 - as)` times the premultiplied
        // channel already sitting there.
        out[i] = dither + switch (blend_op) {
            .source_over => alpha * src + (1 - alpha) * dst[i],
            else => alpha * (1 - dst_alpha) * src +
                alpha * dst_alpha * blend_op.apply(old, src) +
                (1 - alpha) * dst[i],
        };
    }
    return out;
}

const testing = std.testing;

test "raster: fillRect composites and clips" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    // A 4x4 canvas, opaque red over the top-left 2x2, spilling out of bounds.
    surface.fillRect(4, 4, -1, -1, 3, 3, .{ .flat = .fromRGBA(RGBA.Named.red) }, 1, .source_over);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[4..8]);
    // Third column of the first row is untouched.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[8..12]);

    // Half-opaque white on top of the red.
    surface.fillRect(4, 4, 0, 0, 1, 1, .{ .flat = .fromRGBA(.{ .r = 255, .g = 255, .b = 255, .a = 128 }) }, 1, .source_over);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 128, 255 }, surface.pixels[0..4]);

    surface.clearRect(4, 4, 0, 0, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[0..4]);
}

test "raster: a translucent fill reads back Chrome's bytes" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    // Chrome 151 readbacks (probes/canvas-alpha-semantics.js). Every one of
    // them is a single fill onto an empty srgb canvas, so nothing here is about
    // compositing: the colour comes back changed because the bitmap holds it
    // premultiplied, and un-premultiplying a byte does not undo the rounding
    // that storing it did.
    // The alphas are bytes because a legacy notation's alpha already is one:
    // `rgba(200, 100, 50, 0.3)` is 77/255.
    const cases = [_]struct {
        paint: RGBA,
        global_alpha: f64 = 1,
        want: [4]u8,
    }{
        .{ .paint = .{ .r = 200, .g = 100, .b = 50, .a = 77 }, .want = .{ 0xc7, 0x63, 0x32, 0x4d } },
        .{ .paint = .{ .r = 1, .g = 2, .b = 3, .a = 1 }, .want = .{ 0x00, 0x00, 0x00, 0x01 } },
        .{ .paint = .{ .r = 37, .g = 213, .b = 91, .a = 158 }, .want = .{ 0x25, 0xd5, 0x5a, 0x9e } },
        .{ .paint = .{ .r = 255, .g = 255, .b = 255, .a = 26 }, .want = .{ 0xff, 0xff, 0xff, 0x1a } },
        .{ .paint = .{ .r = 128, .g = 128, .b = 128, .a = 128 }, .want = .{ 0x80, 0x80, 0x80, 0x80 } },
        // `globalAlpha` reaches the same place the paint's own alpha does, and
        // is a byte by the time it gets there: 0.3 is 77/255, so this is the
        // first case again (probes/expr-globalalpha-quant.js).
        .{ .paint = .{ .r = 200, .g = 100, .b = 50 }, .global_alpha = 0.3, .want = .{ 0xc7, 0x63, 0x32, 0x4d } },
        // An opaque fill is stored as itself, premultiplied or not.
        .{ .paint = .{ .r = 200, .g = 100, .b = 50 }, .want = .{ 200, 100, 50, 255 } },
    };

    for (cases, 0..) |case, i| {
        surface.reset();
        surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = .fromRGBA(case.paint) }, case.global_alpha, .source_over);

        var out = [_]u8{0} ** 4;
        surface.readPixels(1, 1, 0, 0, 1, 1, &out);
        testing.expectEqualSlices(u8, &case.want, &out) catch |err| {
            std.debug.print("case {d}\n", .{i});
            return err;
        };
    }
}

test "raster: the readback is f32 and a tie goes to even" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    // Two readings that between them pin the width the un-premultiply is done
    // at and the rounding it ends with. Both are stored-over-alpha pairs a
    // gradient's alpha ramp puts down (probes/canvas-gradient-paint.js), and
    // Chrome's answer is one below what the obvious arithmetic gives:
    //
    //   stored 18, alpha 68 -- 18/68 is exactly 67.5 in f64, so rounding half
    //   away from zero answers 68. In f32 the same value is 67.49999237, under
    //   the half, and Chrome answers 67. So the width is f32.
    //
    //   stored 6, alpha 36 -- exactly 42.5 in f32 as well, so the width alone
    //   does not decide it. Chrome answers 42, the even one. That is what
    //   `_mm_cvtps_epi32` and `vcvtnq_s32_f32` do, and so what Skia's
    //   `to_unorm` does.
    //
    // The paints are the straight colours that store those bytes: 68 at an
    // alpha of 68 premultiplies to 18.13, and 43 at 36 to 6.07.
    const cases = [_]struct {
        paint: RGBA,
        want: [4]u8,
    }{
        .{ .paint = .{ .r = 68, .g = 68, .b = 68, .a = 68 }, .want = .{ 67, 67, 67, 68 } },
        .{ .paint = .{ .r = 43, .g = 43, .b = 43, .a = 36 }, .want = .{ 42, 42, 42, 36 } },
        // A control that is nowhere near a tie, so it reads the same either
        // way and a regression here is not about rounding at all.
        .{ .paint = .{ .r = 200, .g = 100, .b = 50, .a = 77 }, .want = .{ 199, 99, 50, 77 } },
    };

    for (cases, 0..) |case, i| {
        surface.reset();
        surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = .fromRGBA(case.paint) }, 1, .source_over);

        var out = [_]u8{0} ** 4;
        surface.readPixels(1, 1, 0, 0, 1, 1, &out);
        testing.expectEqualSlices(u8, &case.want, &out) catch |err| {
            std.debug.print("case {d}\n", .{i});
            return err;
        };
    }
}

test "raster: readPixels windows out of bounds" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    surface.fillRect(2, 2, 0, 0, 2, 2, .{ .flat = .fromRGBA(RGBA.Named.lime) }, 1, .source_over);

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

    surface.fillPath(alloc, 16, 16, &p, .evenodd, .{ .flat = .fromRGBA(RGBA.Named.red) }, 1, .source_over);
    // The middle is inside both, so even-odd leaves it alone.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, surface.pixels[(8 * 16 + 8) * 4 ..][0..4]);
    // A point between the two radii is inside exactly one.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, surface.pixels[(3 * 16 + 8) * 4 ..][0..4]);

    // The same path under the non-zero rule has no hole.
    surface.reset();
    surface.fillPath(alloc, 16, 16, &p, .nonzero, .{ .flat = .fromRGBA(RGBA.Named.red) }, 1, .source_over);
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
    surface.strokePath(alloc, 8, 8, &p, 2, .{ .flat = .fromRGBA(RGBA.Named.lime) }, 1, .source_over);
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
    const steel = RGBA{ .r = 51, .g = 102, .b = 204, .a = 255 };

    // Every expectation below is a Chrome 151 readback
    // (results/expr-composite-blend.chrome.json), not a hand-derived value.
    // The whole sweep matches now; before the bitmap was premultiplied, the
    // both-half `multiply` cell did not.
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
        // Each mode's fixed points: white and black are `multiply`'s identity
        // and annihilator, and a colour differenced against itself is black.
        .{ .back = steel, .src = RGBA.Named.white, .op = .multiply, .want = .{ 51, 102, 204, 255 } },
        .{ .back = steel, .src = RGBA.Named.black, .op = .multiply, .want = .{ 0, 0, 0, 255 } },
        .{ .back = steel, .src = steel, .op = .difference, .want = .{ 0, 0, 0, 255 } },
        .{ .back = steel, .src = RGBA.Named.white, .op = .difference, .want = .{ 204, 153, 51, 255 } },
        .{ .back = steel, .src = RGBA.Named.black, .op = .difference, .want = .{ 51, 102, 204, 255 } },
        // No backdrop: nothing to blend with, so the source lands as-is.
        .{ .back = null, .src = source, .op = .multiply, .want = .{ 64, 128, 192, 255 } },
        .{ .back = null, .src = source, .op = .difference, .want = .{ 64, 128, 192, 255 } },
        // A half-opaque source only blends over the half it covers.
        .{ .back = backdrop, .src = half_source, .op = .multiply, .want = .{ 159, 96, 0, 255 } },
        .{ .back = backdrop, .src = half_source, .op = .difference, .want = .{ 223, 64, 96, 255 } },
        // The same half through `globalAlpha` instead, which Chrome reads
        // identically — it rounds that to a byte too, so 0.5 is the same
        // 128/255 the notation above parsed to (see `opacity`).
        .{ .back = backdrop, .src = source, .op = .multiply, .global_alpha = 0.5, .want = .{ 159, 96, 0, 255 } },
        .{ .back = backdrop, .src = source, .op = .difference, .global_alpha = 0.5, .want = .{ 223, 64, 96, 255 } },
        // A half-opaque backdrop: the uncovered half of the source stays itself.
        .{ .back = half_backdrop, .src = source, .op = .multiply, .want = .{ 64, 96, 96, 255 } },
        .{ .back = half_backdrop, .src = source, .op = .difference, .want = .{ 128, 64, 192, 255 } },
        // Both half-opaque, which is the corner a straight-alpha bitmap could
        // not reach: Chrome un-premultiplies its half-alpha green 64 back into
        // 127.5, where a straight bitmap still held the 128 that went in, and
        // `multiply` carries that half-unit all the way to a whole one.
        .{ .back = half_backdrop, .src = half_source, .op = .multiply, .want = .{ 128, 106, 64, 192 } },
        .{ .back = half_backdrop, .src = half_source, .op = .difference, .want = .{ 170, 85, 128, 192 } },
    };

    for (cases, 0..) |case, i| {
        surface.reset();
        if (case.back) |back| {
            surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = .fromRGBA(back) }, 1, .source_over);
        }
        surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = .fromRGBA(case.src) }, case.global_alpha, case.op);

        var out = [_]u8{0} ** 4;
        surface.readPixels(1, 1, 0, 0, 1, 1, &out);
        testing.expectEqualSlices(u8, &case.want, &out) catch |err| {
            std.debug.print("case {d}: {s}\n", .{ i, @tagName(case.op) });
            return err;
        };
    }
}

test "context filter: what a grayscale() string parses to" {
    // Chrome 151 keeps or rejects each of these at the setter, and paints the
    // amount below (probes/expr-canvas-filter-grayscale.js).
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
    // The filter works in floats, so these compare the byte it quantises to.
    const full: Filter = .{ .grayscale = 1 };
    const grey = struct {
        fn of(filter: Filter, rgba: RGBA) RGBA {
            return filter.applyTo(.fromRGBA(rgba)).toRGBA();
        }
    }.of;

    try testing.expectEqual(RGBA{ .r = 54, .g = 54, .b = 54, .a = 255 }, grey(full, RGBA.Named.red));
    try testing.expectEqual(RGBA{ .r = 182, .g = 182, .b = 182, .a = 255 }, grey(full, RGBA.Named.lime));
    try testing.expectEqual(RGBA{ .r = 18, .g = 18, .b = 18, .a = 255 }, grey(full, RGBA.Named.blue));
    try testing.expectEqual(RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }, grey(full, RGBA.Named.white));

    const teal = RGBA{ .r = 64, .g = 128, .b = 192, .a = 255 };
    try testing.expectEqual(RGBA{ .r = 119, .g = 119, .b = 119, .a = 255 }, grey(full, teal));
    try testing.expectEqual(
        RGBA{ .r = 92, .g = 124, .b = 156, .a = 255 },
        grey(.{ .grayscale = 0.5 }, teal),
    );
    try testing.expectEqual(
        RGBA{ .r = 78, .g = 126, .b = 174, .a = 255 },
        grey(.{ .grayscale = 0.25 }, teal),
    );
    // No filter is the identity, alpha included.
    const translucent = RGBA{ .r = 64, .g = 128, .b = 192, .a = 128 };
    try testing.expectEqual(translucent, grey(.none, translucent));

    // Alpha survives a filter untouched, and the grey it stores is Chrome's:
    // greying the *premultiplied* `{32, 64, 96}` the way Chrome does gives
    // 59.5, and premultiplying this unrounded 119.02 gives 59.74 — the same 60
    // in the bitmap, and the same 120 back out of it.
    var buffer: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();
    surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = full.applyTo(.fromRGBA(translucent)) }, 1, .source_over);

    var out = [_]u8{0} ** 4;
    surface.readPixels(1, 1, 0, 0, 1, 1, &out);
    try testing.expectEqualSlices(u8, &.{ 120, 120, 120, 128 }, &out);
}

test "raster: a filter greys the source, not the backdrop" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var surface = Surface{ .arena = fba.allocator() };
    defer surface.reset();

    // #ff8000, then #4080c0 greyed to 119 and differenced against it. Chrome
    // 151 reads {136, 9, 119, 255}: |255-119|, |128-119|, |0-119| — the filter
    // reached the source only.
    surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = .fromRGBA(.{ .r = 255, .g = 128, .b = 0 }) }, 1, .source_over);
    const greyed = (Filter{ .grayscale = 1 }).applyTo(.fromRGBA(.{ .r = 64, .g = 128, .b = 192 }));
    surface.fillRect(1, 1, 0, 0, 1, 1, .{ .flat = greyed }, 1, .difference);
    try testing.expectEqualSlices(u8, &.{ 136, 9, 119, 255 }, surface.pixels[0..4]);
}

test "raster: a blend mode reaches a path's partly covered edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var surface = Surface{ .arena = alloc };
    defer surface.reset();

    // 8x1 of #ff8000, then #4080c0 differenced over the left four and a half.
    surface.fillRect(8, 1, 0, 0, 8, 1, .{ .flat = .fromRGBA(.{ .r = 255, .g = 128, .b = 0 }) }, 1, .source_over);

    var p: Path = .{};
    const ctm = path_mod.Transform.identity;
    try p.rect(alloc, 0, 0, 4.5, 1, ctm);
    surface.fillPath(alloc, 8, 1, &p, .nonzero, .{ .flat = .fromRGBA(.{ .r = 64, .g = 128, .b = 192 }) }, 1, .difference);

    // Chrome 151 (probes/expr-composite-blend.js `pathEdge`): four whole
    // pixels of the difference, one at half coverage, three untouched.
    try testing.expectEqualSlices(u8, &.{ 191, 0, 192, 255 }, surface.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 191, 0, 192, 255 }, surface.pixels[3 * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 223, 64, 96, 255 }, surface.pixels[4 * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, surface.pixels[5 * 4 ..][0..4]);
}

/// One 32-wide row of a gradient-filled 32x8 canvas against the hex Chrome
/// answered for it. The height and the row matter: the dither is a function of
/// both coordinates, so the same ramp read off a different row is different
/// bytes.
fn expectGradientRow(geometry: Gradient.Geometry, stops: []const Gradient.Stop, hex: []const u8) !void {
    return expectGradientRowIn(geometry, stops, .srgb, hex);
}

fn expectGradientRowIn(
    geometry: Gradient.Geometry,
    stops: []const Gradient.Stop,
    interpolation: Gradient.Interpolation,
    hex: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var surface = Surface{ .arena = arena.allocator() };
    defer surface.reset();
    surface.fillRect(32, 8, 0, 0, 32, 8, .{ .gradient = .{
        .geometry = geometry,
        .inverse = path_mod.Transform.identity,
        .stops = stops,
        .interpolation = interpolation,
    } }, 1, .source_over);

    var got = [_]u8{0} ** (32 * 4);
    surface.readPixels(32, 8, 0, 4, 32, 1, &got);
    var want = [_]u8{0} ** (32 * 4);
    for (&want, 0..) |*byte, i| {
        byte.* = try std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16);
    }
    return testing.expectEqualSlices(u8, &want, &got);
}

test "raster: a gradient is Chrome's ramp, ordered dither and all" {
    const red: [3]f64 = .{ 255, 0, 0 };
    const blue: [3]f64 = .{ 0, 0, 255 };
    const ends = [_]Gradient.Stop{
        .{ .offset = 0, .channels = red },
        .{ .offset = 1, .channels = blue },
    };

    // Chrome 151, row 4 of each of these (probes/canvas-gradient-paint.js).
    //
    // The rows are not the exact interpolation and cannot be reached by any
    // rounding of it: at i = 4 the blue channel of the linear ramp is exactly
    // 35.859 and Chrome stores 35, while at i = 27 it is 219.141 and Chrome
    // stores 220. Both fall out of Skia's 8x8 ordered dither, which nudges a
    // gradient's premultiplied channels by up to half a byte before they are
    // rounded and leaves a flat fill alone. See `ditherOffset`.
    try expectGradientRow(
        .{ .linear = .{ .x0 = 0, .y0 = 0, .x1 = 32, .y1 = 0 } },
        &ends,
        "fb0004fff3000cffeb0014ffe4001cffdb0023ffd3002cffcb0034ffc4003cffbb0043ffb4004cffab0053ffa4005cff9b0063ff94006cff8b0073ff84007cff7b0083ff74008cff6b0093ff64009cff5b00a3ff5400acff4b00b3ff4400bcff3b00c3ff3400cbff2c00d3ff2400dcff1b00e3ff1400ebff0c00f3ff0400fbff",
    );

    // A plain disc, read through its own centre, which is the radial arm's
    // concentric shortcut: the ramp is the distance between the two radii.
    try expectGradientRow(
        .{ .radial = .{ .x0 = 16, .y0 = 4, .r0 = 0, .x1 = 16, .y1 = 4, .r1 = 16 } },
        &ends,
        "0700f7ff1800e8ff2700d7ff3800c8ff4700b7ff5800a8ff670097ff780088ff870077ff970068ffa70058ffb70049ffc60038ffd70029ffe60019fff4000cfff3000bffe60019ffd60028ffc70039ffb60048ffa70058ff970068ff880078ff770087ff680098ff5700a7ff4800b8ff3700c7ff2800d8ff1700e7ff0800f8ff",
    );

    // The sweep, which pins where zero points and which way it turns: the row
    // runs left to right half a pixel below the centre, so it starts just past
    // the negative x axis at half a turn and comes back round to it.
    try expectGradientRow(
        .{ .conic = .{ .angle = 0, .x = 16, .y = 4 } },
        &ends,
        "80007eff81007eff81007eff82007eff81007dff82007eff81007dff82007eff82007cff83007dff83007cff84007bff850079ff880078ff8c0072ffa00060ffdf001ffff2000dfff70008fffa0006fffa0004fffc0004fffc0003fffd0003fffc0002fffd0002fffd0002fffe0002fffd0001fffe0002fffd0001fffe0002ff",
    );

    // Three stops, unevenly spaced, so the ramp is per segment rather than one
    // interpolation from end to end.
    try expectGradientRow(
        .{ .linear = .{ .x0 = 0, .y0 = 0, .x1 = 32, .y1 = 0 } },
        &.{
            .{ .offset = 0, .channels = red },
            .{ .offset = 0.25, .channels = .{ 0, 255, 0 } },
            .{ .offset = 1, .channels = blue },
        },
        "ef0f00ffcf3000ffaf4f00ff907000ff6f8f00ff50b000ff30cf00ff10f000ff00f905ff00ef10ff00e41aff00da26ff00cf2fff00c53bff00ba45ff00b050ff00a45aff009a65ff008f6fff00857bff007a84ff007090ff00659aff005ba5ff004fafff0045baff003ac4ff0030d0ff0025d9ff001be5ff0010efff0006faff",
    );

    // A zero-length axis and a gradient with no stops paint nothing at all,
    // rather than extending an end stop over the shape.
    try expectGradientRow(
        .{ .linear = .{ .x0 = 8, .y0 = 0, .x1 = 8, .y1 = 0 } },
        &ends,
        "00000000" ** 32,
    );
    try expectGradientRow(
        .{ .linear = .{ .x0 = 0, .y0 = 0, .x1 = 32, .y1 = 0 } },
        &.{},
        "00000000" ** 32,
    );
}

test "raster: a wide-notation stop takes the ramp through Oklab" {
    const across: Gradient.Geometry = .{ .linear = .{ .x0 = 0, .y0 = 0, .x1 = 32, .y1 = 0 } };

    // The same sRGB red and sRGB blue as the first row of the test above, and a
    // different ramp: Chrome 151's `color srgb` row
    // (probes/canvas-gradient-stop-space.js), where the stops are written
    // `color(srgb 1 0 0)` and `#0000ff`. In gamut, same colours, and the
    // notation alone moves every pixel of it.
    try expectGradientRowIn(
        across,
        &.{
            .{ .offset = 0, .channels = color.srgbToOklab(.{ 1, 0, 0 }) },
            .{ .offset = 1, .channels = color.srgbToOklab(.{ 0, 0, 1 }) },
        },
        .{ .oklab = .srgb },
        "fb1116fff5232cffed2d3affe63546ffde3a4fffd84059ffd04461ffca486affc24a70ffbb4d78ffb44f7fffad5186ffa5518cff9f5393ff975399ff9054a0ff8852a5ff8253acff7a51b1ff7351b8ff6b4fbdff644ec3ff5c4bc9ff5549cfff4c45d4ff4542daff3c3de0ff3539e6ff2b32ebff222bf1ff1720f6ff0910fdff",
    );
}
