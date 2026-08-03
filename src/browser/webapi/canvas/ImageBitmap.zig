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
//! A bitmap here is its dimensions and nothing else: the rasteriser has no way
//! to blit one, and drawImage() is already a no-op in this engine, so there are
//! no pixels to carry. What a script can observe -- the brand, width/height,
//! close() zeroing both, and which sources are accepted with which rejection --
//! is reproduced from a headed Chrome 150 measurement (win9-chrome.json).

const js = @import("../../js/js.zig");

const Blob = @import("../Blob.zig");
const Canvas = @import("../element/html/Canvas.zig");
const Image = @import("../element/html/Image.zig");
const Video = @import("../element/html/Video.zig");
const ImageData = @import("../ImageData.zig");
const DOMException = @import("../DOMException.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");

const Execution = js.Execution;

const ImageBitmap = @This();

_width: u32,
_height: u32,
_closed: bool = false,

// close() does not just mark the bitmap unusable, it reports 0x0 afterwards
// (measured), so the flag is read on the way out rather than at close time.
pub fn getWidth(self: *const ImageBitmap) u32 {
    return if (self._closed) 0 else self._width;
}

pub fn getHeight(self: *const ImageBitmap) u32 {
    return if (self._closed) 0 else self._height;
}

// Idempotent: closing twice is not an error.
pub fn close(self: *ImageBitmap) void {
    self._closed = true;
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

const Source = union(enum) {
    size: struct { width: u32, height: u32 },
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

fn classify(value: js.Value) Source {
    if (value.toZig(*Canvas)) |canvas| {
        return .{ .size = .{ .width = canvas.getWidth(), .height = canvas.getHeight() } };
    } else |_| {}
    if (value.toZig(*OffscreenCanvas)) |canvas| {
        return .{ .size = .{ .width = canvas.getWidth(), .height = canvas.getHeight() } };
    } else |_| {}
    if (value.toZig(*ImageData)) |data| {
        return .{ .size = .{ .width = data.getWidth(), .height = data.getHeight() } };
    } else |_| {}
    if (value.toZig(*ImageBitmap)) |bitmap| {
        if (bitmap._closed) return .not_usable;
        return .{ .size = .{ .width = bitmap._width, .height = bitmap._height } };
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

    const size = switch (classify(source)) {
        .size => |s| s,
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
        // back its magnitude; the rect is not clipped to the source either.
        return local.resolvePromise(try exec._factory.create(ImageBitmap{
            ._width = @abs(sw),
            ._height = @abs(sh),
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
    }));
}
