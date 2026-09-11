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

const std = @import("std");
const js = @import("../../js/js.zig");

const Blob = @import("../Blob.zig");
const EventTarget = @import("../EventTarget.zig");
const handler_property = @import("../handler_property.zig");
const DOMException = @import("../DOMException.zig");
const ImageBitmap = @import("ImageBitmap.zig");
const Surface = @import("raster.zig");
const encode = @import("encode.zig");
const OffscreenCanvasRenderingContext2D = @import("OffscreenCanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("WebGLRenderingContext.zig");
const WebGL2RenderingContext = @import("WebGL2RenderingContext.zig");
const GPUCanvasContext = @import("../webgpu/pipeline.zig").GPUCanvasContext;
const attributes = @import("context_attributes.zig");
const dictionary = @import("../dictionary.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas
const OffscreenCanvas = @This();

// Chrome's OffscreenCanvas inherits EventTarget: `oc instanceof EventTarget`
// is true there and `oc.addEventListener` is a function, which is the whole
// reason `oncontextlost` and `oncontextrestored` can be handler properties at
// all. This engine had it as a prototype root, so the chain was
// OffscreenCanvas -> Object and both handlers were missing (measured).
pub const Proto = EventTarget;

_proto: *EventTarget,
_width: u32,
_height: u32,
_cached: ?DrawingContext = null,

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *OffscreenCanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
    webgpu: *GPUCanvasContext,
};

pub fn constructor(width: u32, height: u32, exec: *Execution) !*OffscreenCanvas {
    return exec._factory.eventTarget(OffscreenCanvas{
        ._proto = undefined,
        ._width = width,
        ._height = height,
    });
}

pub fn asEventTarget(self: *OffscreenCanvas) *EventTarget {
    return self._proto;
}

pub fn getWidth(self: *const OffscreenCanvas) u32 {
    return self._width;
}

pub fn setWidth(self: *OffscreenCanvas, value: u32) void {
    self._width = value;
    self.resetSurface();
}

pub fn getHeight(self: *const OffscreenCanvas) u32 {
    return self._height;
}

pub fn setHeight(self: *OffscreenCanvas, value: u32) void {
    self._height = value;
    self.resetSurface();
}

/// Resizing resets the whole context — transform, paint, path and the save()
/// stack, not just the bitmap — even when the value does not change. This is
/// the reset the Turnstile widget relies on: it reuses one canvas at half a
/// dozen sizes and never clears the transform itself.
fn resetSurface(self: *OffscreenCanvas) void {
    const cached = self._cached orelse return;
    switch (cached) {
        .@"2d" => |context| context.reset(),
        // Nothing is rasterised behind a WebGL or WebGPU context, so there is
        // no bitmap to clear; the drawing-buffer size is read live off this
        // canvas.
        .webgl, .webgl2, .webgpu => {},
    }
}

/// Unlike HTMLCanvasElement.getContext, whose argument is a free-form string,
/// this one is a WebIDL enum: Chrome throws a TypeError on a name outside the
/// list rather than returning null (measured — 'experimental-webgl' throws here
/// but returns null on an HTMLCanvasElement).
const ContextType = enum {
    @"2d",
    bitmaprenderer,
    webgl,
    webgl2,
    webgpu,
};

pub fn getContext(
    self: *OffscreenCanvas,
    context_type: []const u8,
    settings: ?js.Value,
    exec: *Execution,
) !?DrawingContext {
    // The type enum first here, unlike on an HTMLCanvasElement: a bad name and
    // a bad dictionary member together report the name (measured, so this order
    // is not incidental). "of type" and not "of the type", unlike the colour
    // space's second gate in context_attributes.zig.
    const requested = std.meta.stringToEnum(ContextType, context_type) orelse {
        return dictionary.throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute 'getContext' on 'OffscreenCanvas': The provided value '{s}' " ++
                "is not a valid enum value of type OffscreenRenderingContextType.",
            .{context_type},
        ), exec);
    };

    // Then the dictionary, ahead of the cache -- see canvas/context_attributes.zig.
    const created = try attributes.Creation("OffscreenCanvas").read(settings, exec);

    // A canvas hands back the same context object every time, so the pixels a
    // caller drew are still there on the next `getContext`. Asking for a
    // different kind after the first one answers null.
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => requested == .@"2d",
            .webgl => requested == .webgl,
            .webgl2 => requested == .webgl2,
            .webgpu => requested == .webgpu,
        };
        return if (matches) cached else null;
    }

    self._cached = switch (requested) {
        .@"2d" => .{ .@"2d" = try exec._factory.create(OffscreenCanvasRenderingContext2D{
            ._canvas = self,
            ._surface = .{
                .arena = exec.arena,
                .background = if (created.two_d.alpha) .transparent else .black,
                .channels = created.two_d.channels(),
            },
            ._attributes = created.two_d,
        }) },
        .webgl => .{ .webgl = try exec._factory.create(WebGLRenderingContext{ ._canvas = .{ .offscreen = self }, ._gl = .init(exec.arena), ._attributes = created.gl }) },
        .webgl2 => .{ .webgl2 = try exec._factory.create(WebGL2RenderingContext{ ._canvas = .{ .offscreen = self }, ._gl = .init(exec.arena), ._attributes = created.gl }) },
        // An OffscreenCanvas gets a WebGPU context too, and `ctx.canvas` is
        // then the offscreen canvas itself (measured).
        .webgpu => .{ .webgpu = try exec._factory.create(GPUCanvasContext{ ._canvas = .{ .offscreen = self } }) },
        // The one valid enum member we have no context type for. Chrome does
        // return one for it, so this is a known and narrow gap.
        .bitmaprenderer => return null,
    };
    return self._cached;
}

/// The bitmap behind the canvas, *as it stores its pixels* — premultiplied, and
/// in whichever channel type `colorType` asked for, so only another bitmap
/// should read it. Null means "every pixel is transparent black", which is also
/// what a WebGL or WebGPU canvas reports: neither rasterises.
pub fn bitmap(self: *const OffscreenCanvas) ?*const Surface {
    const cached = self._cached orelse return null;
    return switch (cached) {
        .@"2d" => |context| &context._surface,
        .webgl, .webgl2, .webgpu => null,
    };
}

/// The same pixels un-premultiplied onto `arena`, which is the form everything
/// a page can actually read them through wants. See `raster.straightPixels`.
pub fn straightPixels(self: *const OffscreenCanvas, arena: Allocator) !?[]u8 {
    const cached = self._cached orelse return null;
    return switch (cached) {
        .@"2d" => |context| context._surface.straightPixels(arena, self._width, self._height),
        .webgl, .webgl2, .webgpu => null,
    };
}

/// Returns a Promise that resolves to a Blob of the canvas' pixels, in
/// whichever of the encoded types the options bag names; see
/// `HTMLCanvasElement.toDataURL` and canvas/encode.zig.
pub fn convertToBlob(self: *OffscreenCanvas, options_: ?js.Value, exec: *Execution) !js.Promise {
    const options = try BlobOptions.read(options_, exec);
    const format: encode.Format = .fromType(try options.string("type", "image/png", exec.call_arena));
    const quality = encode.quality(try options.present("quality"));

    // The degenerate extent is refused after the dictionary is read, which is
    // the order a page can see: a bad options bag throws over the rejection.
    if (self._width == 0 or self._height == 0) {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.IndexSizeError } });
    }

    const bytes = try encode.encode(
        exec.call_arena,
        format,
        self._width,
        self._height,
        try self.straightPixels(exec.call_arena),
        quality,
    );
    // Upstream's Blob.initFromBytes now takes the Execution (it pins its own
    // arena), not the Page.
    const blob = try Blob.initFromBytes(bytes, format.mimeType(), exec);
    return exec.js.local.?.resolvePromise(blob);
}

const BlobOptions = dictionary.MethodReader("OffscreenCanvas", "convertToBlob", "ImageEncodeOptions");

fn refuseTransfer(exec: *Execution, comptime message: []const u8, name: []const u8) anyerror {
    const local = exec.js.local orelse return error.JsException;
    const full = "Failed to execute 'transferToImageBitmap' on 'OffscreenCanvas': " ++ message;
    const value = local.zigValueToJs(DOMException.init(full, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

/// Hands the canvas' bitmap to a fresh ImageBitmap and leaves the canvas blank
/// — the transfer the name promises, rather than the copy `createImageBitmap`
/// takes. The Turnstile widget reaches an ImageBitmap of one 49x44 render by
/// both routes and reads each back, so answering only the copy is a readback it
/// never gets to take (tools/fingerprint/README.md).
///
/// Measured on Chrome with probes/expr-transfer-to-image-bitmap.js: the source
/// reads as fully transparent afterwards, through its own context and through a
/// later createImageBitmap alike, while keeping its size; the context object
/// survives, still answers `ctx.canvas === canvas`, and is drawable again; and
/// the bitmap is an ordinary one, unaffected by a later resize of the source and
/// detachable with close().
pub fn transferToImageBitmap(self: *OffscreenCanvas, exec: *Execution) !*ImageBitmap {
    const cached = self._cached orelse return refuseTransfer(
        exec,
        "Cannot transfer an ImageBitmap from an OffscreenCanvas with no context",
        "InvalidStateError",
    );
    // A degenerate extent is refused as a construction failure rather than an
    // invalid state, and only once there is a context to fail for (measured:
    // a 0x1 canvas hands back a 2D context and then refuses the transfer).
    if (self._width == 0 or self._height == 0) {
        return refuseTransfer(exec, "ImageBitmap construction failed", "UnknownError");
    }

    var taken: Surface = .{ .arena = exec.arena };
    switch (cached) {
        .@"2d" => |context| {
            // Moved, not copied: the bitmap takes the buffer and the context is
            // left with an empty one, which is both what "transfer" means and
            // why a second transfer answers transparent. The rest of the
            // context's state — transform, paint, path — is untouched; only
            // resizing resets that.
            taken = context._surface;
            // The emptied surface keeps the canvas opaque, so a transferred
            // opaque canvas reads back as opaque black rather than transparent.
            context._surface = .{ .arena = taken.arena, .background = taken.background, .channels = taken.channels };
        },
        // Chrome's bitmap carries the cleared colour off a WebGL canvas, but
        // nothing is rasterised behind one here — the same gap
        // `createImageBitmap` already has for a WebGL-only source. Left alone
        // so the two routes to a bitmap keep answering the same thing.
        .webgl, .webgl2, .webgpu => {},
    }

    return exec._factory.create(ImageBitmap{
        ._width = self._width,
        ._height = self._height,
        ._surface = taken,
    });
}

pub const BlankPNG = struct {
    const mime = "image/png";

    const base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==";

    pub const data_url = "data:" ++ mime ++ ";base64," ++ base64;

    pub const bytes = blk: {
        const decoder = std.base64.standard.Decoder;
        var buf: [decoder.calcSizeForSlice(base64) catch unreachable]u8 = undefined;
        decoder.decode(&buf, base64) catch unreachable;
        break :blk buf;
    };

    /// Largest canvas Chrome backs with a bitmap (16384 x 16384). Past that, and
    /// at zero size, there are no pixels to serialize and the serializers answer
    /// with the spec's "no data" values.
    const max_area = 16384 * 16384;

    pub fn hasBitmap(width: u32, height: u32) bool {
        return width > 0 and height > 0 and @as(u64, width) * height <= max_area;
    }

    pub fn blob(exec: *js.Execution) !*Blob {
        return Blob.initFromBytes(&BlankPNG.bytes, BlankPNG.mime, exec);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(OffscreenCanvas);

    pub const Meta = struct {
        pub const name = "OffscreenCanvas";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn handler(comptime which: handler_property.Handler) type {
        return handler_property.accessors(OffscreenCanvas, which);
    }

    // Chrome's own-property order (measured): the two handlers between the
    // dimensions and the three operations, and convertToBlob before
    // getContext.
    pub const constructor = bridge.constructor(OffscreenCanvas.constructor, .{});
    pub const width = bridge.accessor(OffscreenCanvas.getWidth, OffscreenCanvas.setWidth, .{});
    pub const height = bridge.accessor(OffscreenCanvas.getHeight, OffscreenCanvas.setHeight, .{});
    pub const oncontextlost = bridge.accessor(handler(.oncontextlost).get, handler(.oncontextlost).set, .{});
    pub const oncontextrestored = bridge.accessor(handler(.oncontextrestored).get, handler(.oncontextrestored).set, .{});
    pub const convertToBlob = bridge.function(OffscreenCanvas.convertToBlob, .{});
    pub const getContext = bridge.function(OffscreenCanvas.getContext, .{});
    pub const transferToImageBitmap = bridge.function(OffscreenCanvas.transferToImageBitmap, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: OffscreenCanvas" {
    try testing.htmlRunner("canvas/offscreen_canvas.html", .{});
}
