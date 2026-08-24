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

//! ImageBitmap, and the createImageBitmap() behind it.
//!
//! A bitmap carries a *snapshot* of its source: createImageBitmap() copies the
//! source's pixels there and then, so repainting the source afterwards does not
//! reach through the bitmap, and close() drops the copy. That copy is what
//! drawImage(bitmap) blits -- without it the call lands nothing, which is one
//! of the reads the Cloudflare widget takes (see tools/fingerprint/README.md).
//!
//! What a script can observe -- the brand, width/height, close() zeroing both,
//! which sources are accepted with which rejection, and now the pixels -- is
//! reproduced from a headed Chrome 150/151 measurement (win9-chrome.json, and
//! probes/expr-imagebitmap-pixels.js for the pixel half).
//!
//! The one source Chrome carries pixels for and this does not is a canvas that
//! only ever had a WebGL context: Chrome's bitmap holds the cleared colour
//! (measured), while `Canvas.pixels()` rasterises nothing there.

const std = @import("std");

const js = @import("../../js/js.zig");

const Blob = @import("../Blob.zig");
const Canvas = @import("../element/html/Canvas.zig");
const Image = @import("../element/html/Image.zig");
const Video = @import("../element/html/Video.zig");
const Surface = @import("raster.zig");
const ImageData = @import("../ImageData.zig");
const DOMException = @import("../DOMException.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");

const Allocator = std.mem.Allocator;
const Execution = js.Execution;

const ImageBitmap = @This();

_width: u32,
_height: u32,
_closed: bool = false,
/// The snapshot taken at creation. Empty when the source had no pixels of its
/// own, which reads the same way as a fully transparent one.
_surface: Surface,

// close() does not just mark the bitmap unusable, it reports 0x0 afterwards
// (measured), so the flag is read on the way out rather than at close time.
pub fn getWidth(self: *const ImageBitmap) u32 {
    return if (self._closed) 0 else self._width;
}

pub fn getHeight(self: *const ImageBitmap) u32 {
    return if (self._closed) 0 else self._height;
}

// Idempotent: closing twice is not an error. Detaching really does release the
// pixels; drawing a closed bitmap throws rather than blitting stale ones.
pub fn close(self: *ImageBitmap) void {
    self._closed = true;
    self._surface.reset();
}

/// The snapshot, for `drawImage`. Null once the bitmap is closed -- drawing a
/// closed one throws rather than depositing nothing, so "detached" and "no
/// pixels" have to stay distinguishable, and an empty surface is the latter.
pub fn surface(self: *const ImageBitmap) ?*const Surface {
    if (self._closed) return null;
    return &self._surface;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageBitmap);

    pub const Meta = struct {
        pub const name = "ImageBitmap";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(ImageBitmap.getWidth, null, .{});
    pub const height = bridge.accessor(ImageBitmap.getHeight, null, .{});
    pub const close = bridge.function(ImageBitmap.close, .{});
};

const PREFIX = "Failed to execute 'createImageBitmap' on 'Window': ";

// The WebIDL union, spelled exactly as Chrome spells it in the TypeError.
const SOURCE_TYPES = "(Blob or HTMLCanvasElement or HTMLImageElement or " ++
    "HTMLVideoElement or ImageBitmap or ImageData or OffscreenCanvas or " ++
    "SVGImageElement or VideoFrame)";

/// A usable source: how big it is, and its pixels when it has any. `pixels` is
/// null for a canvas nobody drew into, which reads as fully transparent.
const Usable = struct {
    width: u32,
    height: u32,
    pixels: ?[]const u8,
    /// Whether `pixels` is already in the premultiplied form a `Surface`
    /// stores. Another bitmap's are; an ImageData's are not — that object is
    /// the straight-alpha view a page gets handed.
    premultiplied: bool = true,
};

const Source = union(enum) {
    usable: Usable,
    // In the union, but carrying nothing this engine can size: an <img> never
    // decodes (naturalWidth is always 0), a <video> never has a frame, and a
    // closed bitmap is spent. Chrome answers all three the same way.
    not_usable,
    // Chrome decodes image Blobs; this engine has a PNG encoder but no
    // decoder, so every Blob lands on the answer Chrome gives an undecodable
    // one.
    undecodable,
    not_in_union,
};

fn classify(value: js.Value, arena: Allocator) !Source {
    if (value.toZig(*Canvas)) |canvas| {
        return .{ .usable = .{
            .width = canvas.getWidth(),
            .height = canvas.getHeight(),
            .pixels = canvas.pixels(),
        } };
    } else |_| {}
    if (value.toZig(*OffscreenCanvas)) |canvas| {
        return .{ .usable = .{
            .width = canvas.getWidth(),
            .height = canvas.getHeight(),
            .pixels = canvas.pixels(),
        } };
    } else |_| {}
    if (value.toZig(*ImageData)) |data| {
        // Straight RGBA8, row-major -- the rasteriser's layout but not its
        // alpha, so these are the one source that has to be premultiplied on
        // the way in. A float16 object is quantised to that same RGBA8 first;
        // `straightBytes` is where that happens.
        return .{ .usable = .{
            .width = data.getWidth(),
            .height = data.getHeight(),
            .pixels = try data.straightBytes(value.local, arena),
            .premultiplied = false,
        } };
    } else |_| {}
    if (value.toZig(*ImageBitmap)) |bitmap| {
        if (bitmap._closed) return .not_usable;
        return .{ .usable = .{
            .width = bitmap._width,
            .height = bitmap._height,
            .pixels = bitmap._surface.peek(bitmap._width, bitmap._height),
        } };
    } else |_| {}
    if (value.toZig(*Image)) |_| {
        return .not_usable;
    } else |_| {}
    if (value.toZig(*Video)) |_| {
        return .not_usable;
    } else |_| {}
    if (value.toZig(*Blob)) |_| {
        return .undecodable;
    } else |_| {}
    return .not_in_union;
}

/// Copies `width` x `height` source pixels starting at `(left, top)` into a
/// fresh surface.
///
/// The rect is allowed to run off the source in any direction: Chrome fills
/// what overlaps and leaves the rest transparent rather than clamping or
/// refusing (measured -- a crop at sx=3 of a 4-wide source gives one column of
/// pixels and one of transparent). `ensure` hands back a zeroed buffer, so the
/// non-overlapping part needs no work.
fn snapshot(arena: Allocator, source: Usable, left: i64, top: i64, width: u32, height: u32) Surface {
    var copy = Surface{ .arena = arena };
    const from = source.pixels orelse return copy;
    const into = copy.ensure(width, height) orelse return copy;

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const sy = top + @as(i64, row);
        if (sy < 0 or sy >= @as(i64, source.height)) continue;
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const sx = left + @as(i64, col);
            if (sx < 0 or sx >= @as(i64, source.width)) continue;
            const at = (@as(usize, @intCast(sy)) * source.width + @as(usize, @intCast(sx))) * 4;
            const to = (@as(usize, row) * width + col) * 4;
            if (source.premultiplied) {
                @memcpy(into[to..][0..4], from[at..][0..4]);
            } else {
                into[to..][0..4].* = Surface.premultiply(from[at..][0..4]);
            }
        }
    }
    return copy;
}

fn rejectDom(comptime message: []const u8, name: []const u8, exec: *const Execution) js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("createImageBitmap", DOMException.init(message, name));
    return resolver.promise();
}

/// window.createImageBitmap. The source is optional so a bare call rejects the
/// way Chrome's does instead of throwing out of the bridge: measured, no
/// argument at all produces a rejected promise, not a synchronous TypeError.
pub fn create(
    source_: ?js.Value,
    sx_: ?js.Value,
    sy_: ?js.Value,
    sw_: ?js.Value,
    sh_: ?js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const source = source_ orelse return local.rejectPromise(.{
        .type_error = PREFIX ++ "1 argument required, but only 0 present.",
    });

    const size = switch (try classify(source, exec.arena)) {
        .usable => |s| s,
        .not_usable => return rejectDom(PREFIX ++ "The image source is not usable.", "InvalidStateError", exec),
        // Note the missing prefix -- Chrome's decode failure is worded on its
        // own, not as a "Failed to execute" (measured).
        .undecodable => return rejectDom("The source image could not be decoded.", "InvalidStateError", exec),
        .not_in_union => return local.rejectPromise(.{
            .type_error = PREFIX ++ "The provided value is not of type '" ++ SOURCE_TYPES ++ "'.",
        }),
    };

    // The crop-rect overload needs all four; a lone second argument is the
    // options dictionary and leaves the size alone.
    if (sx_ != null and sy_ != null and sw_ != null and sh_ != null) {
        const sw = try sw_.?.toZig(i32);
        const sh = try sh_.?.toZig(i32);
        if (sw == 0) {
            return local.rejectPromise(.{ .range_error = PREFIX ++ "The crop rect width is 0." });
        }
        if (sh == 0) {
            return local.rejectPromise(.{ .range_error = PREFIX ++ "The crop rect height is 0." });
        }
        // A negative extent is a rect running the other way, and Chrome hands
        // back its magnitude; the rect is not clipped to the source either,
        // so the crop carries transparent wherever it left the source.
        const sx: i64 = try sx_.?.toZig(i32);
        const sy: i64 = try sy_.?.toZig(i32);
        const width = @abs(sw);
        const height = @abs(sh);
        return local.resolvePromise(try exec._factory.create(ImageBitmap{
            ._width = width,
            ._height = height,
            ._surface = snapshot(
                exec.arena,
                size,
                @min(sx, sx + sw),
                @min(sy, sy + sh),
                width,
                height,
            ),
        }));
    }

    if (size.width == 0) {
        return rejectDom(PREFIX ++ "The image source's width is 0.", "InvalidStateError", exec);
    }
    if (size.height == 0) {
        return rejectDom(PREFIX ++ "The image source's height is 0.", "InvalidStateError", exec);
    }

    return local.resolvePromise(try exec._factory.create(ImageBitmap{
        ._width = size.width,
        ._height = size.height,
        ._surface = snapshot(exec.arena, size, 0, 0, size.width, size.height),
    }));
}
