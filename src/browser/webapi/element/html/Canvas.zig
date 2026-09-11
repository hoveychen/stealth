// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Blob = @import("../../Blob.zig");
const attributes = @import("../../canvas/context_attributes.zig");
const encode = @import("../../canvas/encode.zig");
const Surface = @import("../../canvas/raster.zig");
const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const WebGL2RenderingContext = @import("../../canvas/WebGL2RenderingContext.zig");
const ImageBitmapRenderingContext = @import("../../canvas/ImageBitmapRenderingContext.zig");
const GPUCanvasContext = @import("../../webgpu/pipeline.zig").GPUCanvasContext;
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");
const image_capture = @import("../../media/image_capture.zig");
const MediaStream = @import("../../media/streams.zig").MediaStream;

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Canvas = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_cached: ?DrawingContext = null,

pub fn asElement(self: *Canvas) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeInterned("width") orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
    self.resetSurface();
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeInterned("height") orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
    self.resetSurface();
}

/// Assigning to `width` or `height` resets the whole context even when the
/// value is unchanged — transform, paint, path and the save() stack, not just
/// the bitmap (measured against Chrome 151). Going through the attribute
/// instead (`setAttribute("width", …)`) is caught later, when the raster
/// notices the dimensions moved.
fn resetSurface(self: *Canvas) void {
    const cached = self._cached orelse return;
    switch (cached) {
        .@"2d" => |context| context.reset(),
        .webgl, .webgl2, .webgpu, .bitmaprenderer => {},
    }
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
    webgpu: *GPUCanvasContext,
    bitmaprenderer: *ImageBitmapRenderingContext,
};

pub fn getContext(
    self: *Canvas,
    context_type: []const u8,
    settings: ?js.Value,
    frame: *Frame,
) !?DrawingContext {
    // Before the cache and before the context type is looked at, because that
    // is the order a page can see: a bad member throws even when the canvas
    // already has a context, and even when the type is one we answer null for.
    // See canvas/context_attributes.zig.
    const created = try attributes.Creation("HTMLCanvasElement").read(settings, &frame.js.execution);

    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
            .webgl2 => std.mem.eql(u8, context_type, "webgl2"),
            .webgpu => std.mem.eql(u8, context_type, "webgpu"),
            .bitmaprenderer => std.mem.eql(u8, context_type, "bitmaprenderer"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            const ctx = try frame._factory.create(CanvasRenderingContext2D{
                ._canvas = self,
                ._surface = .{
                    .arena = frame.arena,
                    .background = if (created.two_d.alpha) .transparent else .black,
                    .channels = created.two_d.channels(),
                },
                ._attributes = created.two_d,
            });
            break :blk .{ .@"2d" = ctx };
        }

        // We rasterize nothing here: the WebGL context is a stub whose state
        // calls are no-ops and whose getters answer with the values a real
        // Chrome reports. This used to return null instead, on the grounds
        // that a *partial* stub is worse than none — a consumer like Three.js
        // would call createTexture, hit `TypeError: not a function`, and a
        // page with an error boundary above the widget would catch, reset,
        // re-render and loop forever. That objection is about throwing, not
        // about existing, so the stub is now wide enough not to throw (see
        // WebGLRenderingContext). The trade-off we accept in exchange: a page
        // that waits for WebGL output before showing content now waits
        // forever instead of taking its no-WebGL path. Absent WebGL is itself
        // a loud signal — `getContext('webgl') === null` happens on no real
        // browser on this hardware.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            const ctx = try frame._factory.create(WebGLRenderingContext{ ._canvas = .{ .html = self }, ._gl = .init(frame.arena), ._attributes = created.gl });
            break :blk .{ .webgl = ctx };
        }

        // An ImageBitmap sink: it rasterises nothing here either, but returning
        // null for it was the loud answer -- no real Chrome refuses this
        // context type. See canvas/ImageBitmapRenderingContext.zig.
        if (std.mem.eql(u8, context_type, "bitmaprenderer")) {
            const ctx = try frame._factory.create(ImageBitmapRenderingContext{ ._canvas = self });
            break :blk .{ .bitmaprenderer = ctx };
        }

        if (std.mem.eql(u8, context_type, "webgl2")) {
            const ctx = try frame._factory.create(WebGL2RenderingContext{ ._canvas = .{ .html = self }, ._gl = .init(frame.arena), ._attributes = created.gl });
            break :blk .{ .webgl2 = ctx };
        }

        // Unlike WebGL, a WebGPU context rasterises nothing even in Chrome
        // until a page configures it and submits work; what it owes is the
        // handle, its `canvas` back-reference and the texture getCurrentTexture
        // hands out. See webgpu/pipeline.zig.
        if (std.mem.eql(u8, context_type, "webgpu")) {
            const ctx = try frame._factory.create(GPUCanvasContext{ ._canvas = .{ .html = self } });
            break :blk .{ .webgpu = ctx };
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// The bitmap behind the canvas, *as it stores its pixels* — premultiplied, and
/// in whichever channel type `colorType` asked for, so only another bitmap
/// should read it. Null means "every pixel is transparent black", which is also
/// what a WebGL canvas reports here: that context does not rasterise.
pub fn bitmap(self: *const Canvas) ?*const Surface {
    const cached = self._cached orelse return null;
    return switch (cached) {
        .@"2d" => |context| &context._surface,
        .webgl, .webgl2, .webgpu, .bitmaprenderer => null,
    };
}

/// The same pixels un-premultiplied onto `arena`, which is the form everything
/// a page can actually read them through wants. See `raster.straightPixels`.
pub fn straightPixels(self: *const Canvas, arena: Allocator) !?[]u8 {
    const cached = self._cached orelse return null;
    return switch (cached) {
        .@"2d" => |context| context._surface.straightPixels(arena, self.getWidth(), self.getHeight()),
        .webgl, .webgl2, .webgpu, .bitmaprenderer => null,
    };
}

/// https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/toDataURL
///
/// The type picks the encoder, and anything outside the handful we write falls
/// back to PNG — which is both what the spec says an unsupported type does and
/// what Chrome answers for the rest of the IANA image registry. See
/// canvas/encode.zig for how the match is made.
pub fn toDataURL(self: *Canvas, mime: ?[]const u8, quality: ?js.Value, frame: *Frame) ![]const u8 {
    const width = self.getWidth();
    const height = self.getHeight();
    if (width == 0 or height == 0) {
        // What Chrome answers for a canvas with no area, whatever type was
        // asked for (measured).
        return "data:,";
    }
    return encode.dataUrl(
        frame.local_arena,
        .fromType(mime),
        width,
        height,
        try self.straightPixels(frame.local_arena),
        encode.quality(quality),
    );
}

/// https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/toBlob
///
/// The type and quality read exactly as `toDataURL`'s do. The callback is
/// invoked from a task, not synchronously, which is what the spec requires
/// and what pages that chain off it expect.
pub fn toBlob(self: *Canvas, callback: js.Function.Global, mime: ?[]const u8, quality: ?js.Value, exec: *Execution) !void {
    const width = self.getWidth();
    const height = self.getHeight();

    const blob: ?*Blob = if (width == 0 or height == 0) null else blk: {
        const format: encode.Format = .fromType(mime);
        const bytes = try encode.encode(
            exec.call_arena,
            format,
            width,
            height,
            try self.straightPixels(exec.call_arena),
            encode.quality(quality),
        );
        // Upstream's Blob.initFromBytes now takes the Execution (it pins its
        // own arena), not the Page.
        break :blk try Blob.initFromBytes(bytes, format.mimeType(), exec);
    };

    const argument = try exec.js.local.?.zigValueToJs(blob, .{});
    var params = [_]js.Value.Global{try argument.persist()};

    _ = try exec.js.global.frame.window._timers.schedule(exec, callback, 0, .{
        .repeat = false,
        .params = &params,
        .name = "canvas.toBlob",
    });
}

/// https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/captureStream
///
/// A canvas is the one video source this engine can open without a permission
/// or a device, so unlike getUserMedia this really hands back a live stream.
/// Nothing pulls frames from it -- see media/image_capture.zig for what the
/// track does and does not carry.
pub fn captureStream(self: *Canvas, frame_rate: ?js.Value, exec: *Execution) !*MediaStream {
    return image_capture.captureStream(self, frame_rate, exec);
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's prototype order, which puts captureStream straight after the two
    // dimensions and toBlob before toDataURL (measured).
    //
    // Upstream's `reflect.unsignedLong("width"/"height", ...)` is not taken
    // here: assigning to either IDL attribute has to drop the bitmap
    // (`resetSurface`), which the generic reflection helper knows nothing about.
    pub const width = bridge.accessor(Canvas.getWidth, Canvas.setWidth, .{ .ce_reactions = true });
    pub const height = bridge.accessor(Canvas.getHeight, Canvas.setHeight, .{ .ce_reactions = true });
    // Arity 0: the frame rate is optional, so it does not count.
    pub const captureStream = bridge.function(Canvas.captureStream, .{ .arity = 0 });
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const toBlob = bridge.function(Canvas.toBlob, .{});
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLCanvasElement serialization" {
    try testing.htmlRunner("canvas/canvas_serialization.html", .{});
}
