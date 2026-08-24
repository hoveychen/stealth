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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// The drawing half of the 2D context, written once for both context types.
//
// `CanvasRenderingContext2D` and `OffscreenCanvasRenderingContext2D` are
// near-identical files, and everything below would otherwise be written twice
// — which is how one of them ends up a version behind the other. The mixin is
// generic over the context struct and reaches only for fields both have:
// `_surface`, `_path`, `_transform`, `_saved`, `_canvas`, and the paint state.
// `state.Accessors` in this directory shares the attribute half the same way.
//
// The rectangle calls keep their existing pixel-snapped implementations
// whenever the transform has no rotation or skew, which covers the identity
// and every `scale`/`translate`: an axis-aligned rectangle's coverage is
// exactly 0 or 1 on each pixel, so snapping and sampling agree, and the
// existing behaviour is preserved exactly. Only a rotated or skewed rectangle
// takes the general path.

const std = @import("std");

const js = @import("../../js/js.zig");
const color = @import("../../color.zig");

const path = @import("path.zig");
const Surface = @import("raster.zig");
const state = @import("context_state.zig");
const canvas_objects = @import("canvas_objects.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const ImageData = @import("../ImageData.zig");
const ImageBitmap = @import("ImageBitmap.zig");
const dictionary = @import("../dictionary.zig");
const DOMException = @import("../DOMException.zig");
const CanvasElement = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");
// The rest of the CanvasImageSource union. Named after the interface rather
// than the file, since two of the files are both called Image.zig.
const ImageElement = @import("../element/html/Image.zig");
const VideoElement = @import("../element/html/Video.zig");
const SvgImageElement = @import("../element/svg/Image.zig");
const VideoFrame = @import("../webcodecs/frames.zig").VideoFrame;
const CSSImageValue = @import("../css/typed_om.zig").CSSImageValue;

const Execution = js.Execution;
const Transform = path.Transform;
const FillRule = path.FillRule;

/// The drawing state `save()` puts on the stack. The path is deliberately not
/// part of it: the spec keeps one path across save/restore.
pub fn Saved(comptime Font: type) type {
    return struct {
        transform: Transform,
        fill_style: canvas_objects.PaintStyle,
        stroke_style: canvas_objects.PaintStyle,
        line_width: f64,
        global_alpha: f64,
        font: Font,
        attrs: state.State,
    };
}

pub fn Mixin(comptime T: type) type {
    return struct {
        /// The frame arena both the path and the save stack live in.
        fn arena(self: *T) std.mem.Allocator {
            return self._surface.arena;
        }

        fn width(self: *const T) u32 {
            return self._canvas.getWidth();
        }

        fn height(self: *const T) u32 {
            return self._canvas.getHeight();
        }

        /// The bitmap's own colour space, which every colour is resolved into
        /// on the way in and converted out of on the way back.
        fn space(self: *const T) color.CanvasSpace {
            return self._attributes.space();
        }

        /// True when the transform maps axis-aligned rectangles to
        /// axis-aligned rectangles, which is every `scale` and `translate`.
        fn upright(ctm: Transform) bool {
            return ctm.b == 0 and ctm.c == 0;
        }

        /// `globalCompositeOperation` as the rasteriser reads it. The keyword
        /// itself is already validated by the setter, so anything the
        /// rasteriser does not implement simply falls back to source-over.
        fn composite(self: *const T) Surface.Composite {
            return .fromKeyword(self._state.global_composite_operation);
        }

        /// `ctx.filter` as the rasteriser reads it.
        fn filter(self: *const T) Surface.Filter {
            return .parse(self._state.filter);
        }

        /// A flat paint after `ctx.filter`. The filter applies to the source
        /// graphic, and a fill's source graphic is one colour all over — so for
        /// everything but `drawImage` the whole of it lands here rather than in
        /// the rasteriser. Chrome runs the filter on fills too, not only on
        /// images (measured, probes/expr-canvas-filter-grayscale.js).
        fn paint(self: *const T, style: canvas_objects.PaintStyle) color.Paint {
            // Resolved into the bitmap's colour space first, then filtered. The
            // order is a guess where the space is not: nothing measured says
            // whether Chrome filters before or after the conversion, and on an
            // srgb canvas — every canvas until one asks for display-p3 — the
            // conversion is the identity and the question does not arise.
            return filter(self).applyTo(style.paint(space(self)));
        }

        // --- state stack ---------------------------------------------------

        pub fn save(self: *T) void {
            if (!self._transform.isFinite()) return;
            self._saved.append(arena(self), .{
                .transform = self._transform,
                .fill_style = self._fill_style,
                .stroke_style = self._stroke_style,
                .line_width = self._line_width,
                .global_alpha = self._global_alpha,
                .font = self._font,
                .attrs = self._state,
            }) catch return;
        }

        pub fn restore(self: *T) void {
            const top = self._saved.pop() orelse return;
            self._transform = top.transform;
            self._fill_style = top.fill_style;
            self._stroke_style = top.stroke_style;
            self._line_width = top.line_width;
            self._global_alpha = top.global_alpha;
            self._font = top.font;
            self._state = top.attrs;
        }

        // --- transforms ----------------------------------------------------

        pub fn scale(self: *T, x: f64, y: f64) void {
            if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
            self._transform = self._transform.scaled(x, y);
        }

        pub fn rotate(self: *T, radians: f64) void {
            if (!std.math.isFinite(radians)) return;
            self._transform = self._transform.rotated(radians);
        }

        pub fn translate(self: *T, x: f64, y: f64) void {
            if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
            self._transform = self._transform.translated(x, y);
        }

        pub fn transform(self: *T, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
            const m = Transform{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f };
            if (!m.isFinite()) return;
            self._transform = self._transform.multiply(m);
        }

        /// The six-number form, plus the no-argument one that resets to the
        /// identity. Chrome also takes a `DOMMatrix2DInit` as the single
        /// argument; that is left alone here rather than half-read, and the
        /// first parameter stays a `js.Value` so passing one is ignored rather
        /// than refused — which is what it did before this.
        pub fn setTransform(self: *T, a_: ?js.Value, b: ?f64, c: ?f64, d: ?f64, e: ?f64, f: ?f64) void {
            const given = a_ orelse {
                self._transform = Transform.identity;
                return;
            };
            const a = given.toZig(f64) catch return;
            const m = Transform{
                .a = a,
                .b = b orelse return,
                .c = c orelse return,
                .d = d orelse return,
                .e = e orelse return,
                .f = f orelse return,
            };
            if (!m.isFinite()) return;
            self._transform = m;
        }

        pub fn resetTransform(self: *T) void {
            self._transform = Transform.identity;
        }

        pub fn getTransform(self: *const T, exec: *Execution) !*DOMMatrix {
            const t = self._transform;
            var m = [_]f64{0} ** 16;
            m[0] = t.a;
            m[1] = t.b;
            m[4] = t.c;
            m[5] = t.d;
            m[10] = 1;
            m[12] = t.e;
            m[13] = t.f;
            m[15] = 1;
            return DOMMatrix.create(m, true, exec.page);
        }

        // --- path construction ---------------------------------------------

        pub fn beginPath(self: *T) void {
            self._path.begin();
        }

        pub fn closePath(self: *T) void {
            self._path.closePath();
        }

        pub fn moveTo(self: *T, x: f64, y: f64) void {
            self._path.moveTo(arena(self), x, y, self._transform) catch {};
        }

        pub fn lineTo(self: *T, x: f64, y: f64) void {
            self._path.lineTo(arena(self), x, y, self._transform) catch {};
        }

        pub fn quadraticCurveTo(self: *T, cx: f64, cy: f64, x: f64, y: f64) void {
            self._path.quadraticCurveTo(arena(self), cx, cy, x, y, self._transform) catch {};
        }

        pub fn bezierCurveTo(self: *T, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) void {
            self._path.bezierCurveTo(arena(self), c1x, c1y, c2x, c2y, x, y, self._transform) catch {};
        }

        pub fn arc(self: *T, x: f64, y: f64, radius: f64, start_angle: f64, end_angle: f64, counterclockwise: ?bool) void {
            self._path.arc(arena(self), x, y, radius, start_angle, end_angle, counterclockwise orelse false, self._transform) catch {};
        }

        pub fn arcTo(self: *T, x1: f64, y1: f64, x2: f64, y2: f64, radius: f64) void {
            self._path.arcTo(arena(self), x1, y1, x2, y2, radius, self._transform) catch {};
        }

        pub fn ellipse(self: *T, x: f64, y: f64, rx: f64, ry: f64, rotation: f64, start_angle: f64, end_angle: f64, counterclockwise: ?bool) void {
            self._path.ellipse(arena(self), x, y, rx, ry, rotation, start_angle, end_angle, counterclockwise orelse false, self._transform) catch {};
        }

        pub fn rect(self: *T, x: f64, y: f64, w: f64, h: f64) void {
            self._path.rect(arena(self), x, y, w, h, self._transform) catch {};
        }

        /// A single number is the only radius form read here; the spec's list
        /// of up to four (and of `DOMPointInit`s) falls back to square
        /// corners, which is the shape this drew before.
        pub fn roundRect(self: *T, x: f64, y: f64, w: f64, h: f64, radii: ?js.Value) void {
            var r: f64 = 0;
            if (radii) |v| {
                r = v.toZig(f64) catch 0;
                if (!std.math.isFinite(r) or r < 0) r = 0;
            }
            self._path.roundRect(arena(self), x, y, w, h, .{ r, r, r, r }, self._transform) catch {};
        }

        // --- painting -------------------------------------------------------

        /// `fill()` takes a winding rule, a `Path2D`, or both. A `Path2D`
        /// records no geometry here (see Path2D.zig), so an argument that is
        /// not one of the two rule names is ignored rather than refused.
        pub fn fill(self: *T, first: ?js.Value, second: ?js.Value, exec: *Execution) void {
            const rule = ruleOf(second, exec) orelse ruleOf(first, exec) orelse .nonzero;
            self._surface.fillPath(
                exec.call_arena,
                width(self),
                height(self),
                &self._path,
                rule,
                paint(self, self._fill_style),
                self._global_alpha,
                composite(self),
            );
        }

        pub fn stroke(self: *T, _: ?js.Value, exec: *Execution) void {
            self._surface.strokePath(
                exec.call_arena,
                width(self),
                height(self),
                &self._path,
                self._line_width * self._transform.meanScale(),
                paint(self, self._stroke_style),
                self._global_alpha,
                composite(self),
            );
        }

        // --- gradient and pattern factories -----------------------------------

        // These carry no paint — see canvas_objects.zig — but they do refuse
        // the way Chrome refuses, and the sentence names the interface, which
        // is the reason they live here rather than twice over in the two
        // context files: `OffscreenCanvasRenderingContext2D` has to say its own
        // name (measured on Chrome 151, both contexts).
        const said = "Failed to execute '{s}' on '" ++ T.JsApi.Meta.name ++ "': ";

        /// WebIDL `double` is restricted, so a non-finite coordinate is refused
        /// before the operation's own steps run — which is why this beats the
        /// radius check below even when both are wrong.
        fn nonFinite(comptime operation: []const u8, exec: *Execution) anyerror {
            return exec.js.fail(error.TypeError, comptime std.fmt.comptimePrint(
                said ++ "The provided double value is non-finite.",
                .{operation},
            ));
        }

        fn finite(comptime operation: []const u8, values: []const f64, exec: *Execution) !void {
            for (values) |value| {
                if (!std.math.isFinite(value)) return nonFinite(operation, exec);
            }
        }

        pub fn createLinearGradient(_: *T, x0: f64, y0: f64, x1: f64, y1: f64, exec: *Execution) !*canvas_objects.CanvasGradient {
            try finite("createLinearGradient", &.{ x0, y0, x1, y1 }, exec);
            return exec._factory.create(canvas_objects.CanvasGradient{});
        }

        /// Both radii have to be non-negative, and `r0` is checked first — so
        /// two negative radii name `r0` (measured). `-0` is not negative.
        pub fn createRadialGradient(_: *T, x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64, exec: *Execution) !*canvas_objects.CanvasGradient {
            try finite("createRadialGradient", &.{ x0, y0, r0, x1, y1, r1 }, exec);
            if (r0 < 0) {
                return exec.js.fail(error.IndexSizeError, comptime std.fmt.comptimePrint(
                    said ++ "The r0 provided is less than 0.",
                    .{"createRadialGradient"},
                ));
            }
            if (r1 < 0) {
                return exec.js.fail(error.IndexSizeError, comptime std.fmt.comptimePrint(
                    said ++ "The r1 provided is less than 0.",
                    .{"createRadialGradient"},
                ));
            }
            return exec._factory.create(canvas_objects.CanvasGradient{});
        }

        /// The angle is not wrapped or bounded: Chrome takes 1e6 turns.
        pub fn createConicGradient(_: *T, angle: f64, x: f64, y: f64, exec: *Execution) !*canvas_objects.CanvasGradient {
            try finite("createConicGradient", &.{ angle, x, y }, exec);
            return exec._factory.create(canvas_objects.CanvasGradient{});
        }

        /// The repetition is one of four keywords, and `null`/`undefined`/`''`
        /// all mean `repeat` (measured).
        ///
        /// The image is an eight-member IDL union, converted before the
        /// operation's steps run, so anything that is none of the eight — a
        /// primitive or a plain object alike — is refused with the union's whole
        /// spelling. This is a wider test than `sourceOf` above, which only
        /// answers the three we can actually read pixels out of: an `<img>` is a
        /// valid argument here even though drawing it paints nothing yet.
        pub fn createPattern(_: *T, image: js.Value, repetition: js.Value, exec: *Execution) !*canvas_objects.CanvasPattern {
            if (!isImageSource(image)) {
                return exec.js.fail(error.TypeError, comptime std.fmt.comptimePrint(said, .{"createPattern"}) ++
                    "The provided value is not of type '(CSSImageValue or " ++
                    "HTMLCanvasElement or HTMLImageElement or HTMLVideoElement or " ++
                    "ImageBitmap or OffscreenCanvas or SVGImageElement or VideoFrame)'.");
            }
            if (!repetition.isNullOrUndefined()) {
                const text = try repetition.toStringSliceWithAlloc(exec.call_arena);
                if (text.len != 0 and !isRepetition(text)) {
                    return exec.js.fail(error.SyntaxError, try std.fmt.allocPrint(
                        exec.call_arena,
                        comptime std.fmt.comptimePrint(said, .{"createPattern"}) ++
                            "The provided type ('{s}') is not one of 'repeat', " ++
                            "'no-repeat', 'repeat-x', or 'repeat-y'.",
                        .{text},
                    ));
                }
            }
            return exec._factory.create(canvas_objects.CanvasPattern{});
        }

        /// The `CanvasImageSource` union, member for member.
        fn isImageSource(value: js.Value) bool {
            if (!value.isObject()) return false;
            inline for (.{
                *CanvasElement,
                *OffscreenCanvas,
                *ImageBitmap,
                *ImageElement,
                *VideoElement,
                *SvgImageElement,
                *VideoFrame,
                *CSSImageValue,
            }) |Member| {
                if (value.toZig(Member)) |_| return true else |_| {}
            }
            return false;
        }

        fn isRepetition(text: []const u8) bool {
            for ([_][]const u8{ "repeat", "no-repeat", "repeat-x", "repeat-y" }) |allowed| {
                if (std.mem.eql(u8, allowed, text)) return true;
            }
            return false;
        }

        fn ruleOf(value: ?js.Value, exec: *Execution) ?FillRule {
            const v = value orelse return null;
            if (v.isString() == null) return null;
            const text = v.toStringSliceWithAlloc(exec.call_arena) catch return null;
            return FillRule.parse(text);
        }

        // --- rectangles ------------------------------------------------------

        pub fn fillRect(self: *T, x: f64, y: f64, w: f64, h: f64, exec: *Execution) void {
            const ctm = self._transform;
            if (upright(ctm)) {
                const at = ctm.apply(x, y);
                self._surface.fillRect(width(self), height(self), at.x, at.y, w * ctm.a, h * ctm.d, paint(self, self._fill_style), self._global_alpha, composite(self));
                return;
            }
            var quad: path.Path = .{};
            quad.rect(exec.call_arena, x, y, w, h, ctm) catch return;
            self._surface.fillPath(exec.call_arena, width(self), height(self), &quad, .nonzero, paint(self, self._fill_style), self._global_alpha, composite(self));
        }

        pub fn strokeRect(self: *T, x: f64, y: f64, w: f64, h: f64, exec: *Execution) void {
            const ctm = self._transform;
            const line_width = self._line_width * ctm.meanScale();
            if (upright(ctm)) {
                const at = ctm.apply(x, y);
                self._surface.strokeRect(width(self), height(self), at.x, at.y, w * ctm.a, h * ctm.d, line_width, paint(self, self._stroke_style), self._global_alpha, composite(self));
                return;
            }
            var quad: path.Path = .{};
            quad.rect(exec.call_arena, x, y, w, h, ctm) catch return;
            self._surface.strokePath(exec.call_arena, width(self), height(self), &quad, line_width, paint(self, self._stroke_style), self._global_alpha, composite(self));
        }

        pub fn clearRect(self: *T, x: f64, y: f64, w: f64, h: f64, exec: *Execution) void {
            const ctm = self._transform;
            if (upright(ctm)) {
                const at = ctm.apply(x, y);
                self._surface.clearRect(width(self), height(self), at.x, at.y, w * ctm.a, h * ctm.d);
                return;
            }
            var quad: path.Path = .{};
            quad.rect(exec.call_arena, x, y, w, h, ctm) catch return;
            self._surface.clearPath(exec.call_arena, width(self), height(self), &quad);
        }

        /// `drawImage(source, dx, dy)`, `(source, dx, dy, dw, dh)` and the
        /// nine-argument form, for the sources that have pixels behind them:
        /// a canvas element, an `OffscreenCanvas`, and an `ImageBitmap`. An
        /// image element would need a decoder, so it deposits nothing — the
        /// call still succeeds, which is the part that matters: on the
        /// offscreen context this member did not exist at all, and the
        /// `TypeError` that raised took the rest of the caller's function with
        /// it. A *closed* bitmap is the one source that refuses outright.
        pub fn drawImage(self: *T, source: js.Value, a: f64, b: f64, c: ?f64, d: ?f64, e: ?f64, f: ?f64, g: ?f64, h: ?f64, exec: *Execution) !void {
            const src = try sourceOf(source, exec) orelse return;
            const sw: f64 = @floatFromInt(src.width);
            const sh: f64 = @floatFromInt(src.height);
            if (sw == 0 or sh == 0) return;

            // Which of the three forms this is, by how many numbers arrived.
            const blit: Surface.Blit = if (e) |dx| .{
                .sx = a,
                .sy = b,
                .sw = c orelse return,
                .sh = d orelse return,
                .dx = dx,
                .dy = f orelse return,
                .dw = g orelse return,
                .dh = h orelse return,
            } else if (c) |dw| .{
                .sx = 0,
                .sy = 0,
                .sw = sw,
                .sh = sh,
                .dx = a,
                .dy = b,
                .dw = dw,
                .dh = d orelse return,
            } else .{
                .sx = 0,
                .sy = 0,
                .sw = sw,
                .sh = sh,
                .dx = a,
                .dy = b,
                .dw = sw,
                .dh = sh,
            };

            self._surface.drawSurface(
                exec.call_arena,
                width(self),
                height(self),
                src.surface,
                src.width,
                src.height,
                // Chrome converts rather than copies when the two bitmaps are
                // in different spaces: a display-p3 `ff407f` drawn onto an srgb
                // canvas lands as `ff1c7e` (measured --
                // probes/canvas-own-color-space.js).
                .{ .from = src.space, .to = space(self) },
                blit,
                self._transform,
                self._global_alpha,
                composite(self),
                filter(self),
            );
        }

        const Source = struct {
            surface: *const Surface,
            width: u32,
            height: u32,
            /// The space the source's own bytes are in, which decides whether
            /// they are copied or converted. An ImageBitmap is srgb because
            /// nothing here builds one from a display-p3 canvas yet.
            space: color.CanvasSpace = .srgb,
        };

        /// The pixels behind a `CanvasImageSource`, when there are any. Both
        /// canvas types keep theirs on the 2D context they handed out, so a
        /// canvas that was never drawn into — or was only ever used for WebGL
        /// — has nothing to give. An `ImageBitmap` keeps a snapshot of its own.
        fn sourceOf(value: js.Value, exec: *Execution) !?Source {
            if (value.toZig(*CanvasElement)) |canvas| {
                const cached = canvas._cached orelse return null;
                return switch (cached) {
                    .@"2d" => |ctx| .{
                        .surface = &ctx._surface,
                        .width = canvas.getWidth(),
                        .height = canvas.getHeight(),
                        .space = ctx._attributes.space(),
                    },
                    else => null,
                };
            } else |_| {}
            if (value.toZig(*OffscreenCanvas)) |canvas| {
                const cached = canvas._cached orelse return null;
                return switch (cached) {
                    .@"2d" => |ctx| .{
                        .surface = &ctx._surface,
                        .width = canvas.getWidth(),
                        .height = canvas.getHeight(),
                        .space = ctx._attributes.space(),
                    },
                    else => null,
                };
            } else |_| {}
            if (value.toZig(*ImageBitmap)) |bitmap| {
                const snapshot = bitmap.surface() orelse return throwDetached(exec);
                return .{ .surface = snapshot, .width = bitmap._width, .height = bitmap._height };
            } else |_| {}
            return null;
        }

        /// Drawing a closed bitmap is refused, not ignored, and Chrome names
        /// the receiver's own interface in the message — measured on both 2D
        /// contexts (probes/expr-imagebitmap-pixels.js).
        fn throwDetached(exec: *Execution) anyerror {
            const local = exec.js.local.?;
            const message = "Failed to execute 'drawImage' on '" ++ T.JsApi.Meta.name ++
                "': The image source is detached";
            const value = local.zigValueToJs(
                DOMException.init(message, "InvalidStateError"),
                .{},
            ) catch return error.JsException;
            _ = local.isolate.throwException(value.handle);
            return error.JsException;
        }

        /// Everything the rasteriser drops on `reset()`.
        pub fn resetDrawing(self: *T) void {
            self._transform = Transform.identity;
            self._path.begin();
            self._saved.clearRetainingCapacity();
        }

        // --- image data ----------------------------------------------------

        /// One dictionary reader per method, differing only in the prefix its
        /// refusals carry.
        fn ImageDataSettings(comptime method: []const u8) type {
            return ImageData.Settings.Reading(dictionary.MethodReader(
                T.JsApi.Meta.name,
                method,
                "ImageDataSettings",
            ));
        }

        const WidthOrImageData = union(enum) {
            width: u32,
            image_data: *ImageData,
        };

        pub fn createImageData(
            self: *const T,
            width_or_image_data: WidthOrImageData,
            /// If `ImageData` variant preferred, this is null.
            maybe_height: ?u32,
            /// Can be used if width and height provided.
            settings: ?js.Value,
            exec: *Execution,
        ) !*ImageData {
            switch (width_or_image_data) {
                .width => |w| {
                    const read = try ImageDataSettings("createImageData")
                        .read(settings, space(self), exec);
                    const h = maybe_height orelse return error.TypeError;
                    return ImageData.init(w, h, read, exec);
                },
                // From a source ImageData the settings are inherited rather
                // than given: `createImageData(new ImageData(2, 2,
                // {colorSpace: 'display-p3'}))` answers display-p3 (measured --
                // probes/canvas-image-data-settings.js).
                .image_data => |image_data| {
                    return ImageData.init(
                        image_data._width,
                        image_data._height,
                        image_data._settings,
                        exec,
                    );
                },
            }
        }

        pub fn getImageData(
            self: *const T,
            sx: i32,
            sy: i32,
            sw: i32,
            sh: i32,
            settings: ?js.Value,
            exec: *Execution,
        ) !*ImageData {
            // Read before the rect is looked at, which is the order a page can
            // see: a zero-sized window and a bad member together report the
            // member (measured).
            const read = try ImageDataSettings("getImageData").read(settings, space(self), exec);
            const window = try imageDataWindow(sx, sy, sw, sh, exec);

            const image_data = try ImageData.init(window.width, window.height, read, exec);
            switch (image_data._data) {
                // Freshly created, so it is already transparent black:
                // `readPixels` only has to overwrite the part of the window
                // that overlaps the canvas. In this format the array the page
                // will be handed *is* the read's destination.
                .@"rgba-unorm8" => |data| {
                    const out = data.local(exec.js.local.?).slice();
                    try readInto(self, window, read.color_space, out, exec);
                },
                // A float pixel format is a finer *read*, not a finer bitmap:
                // the un-premultiplication and the colour conversion both
                // happen in floating point, and neither is rounded into a byte
                // on the way. Off a `colorType: 'unorm8'` bitmap — which is
                // every canvas that did not ask otherwise — the channel it
                // answers is still the neighbour of some `n / 255`, because
                // that is all the bitmap held. The finer *bitmap* is the other
                // axis, and it is `colorType` that picks it. See
                // `readFloatInto` and `raster.Surface.channels`.
                inline .@"rgba-float16", .@"rgba-float32" => |data| {
                    try readFloatInto(self, window, read.color_space, data.local(exec.js.local.?).slice(), exec);
                },
            }
            return image_data;
        }

        /// The float formats' read: normalised f32 channels out of the bitmap,
        /// converted unclipped, and only then narrowed to the format's element.
        ///
        /// Two bytes the byte path would have gone through are missing here, and
        /// both are observable (measured --
        /// probes/canvas-image-data-construct.js):
        ///
        ///   - The un-premultiplication. A premultiplied `{60, 30, 15, 77}`
        ///     pixel is `0.7792208194732666` = `60 / 77` as float32, not the
        ///     `199 / 255` its unorm8 byte would give. Every opaque pixel hides
        ///     this, since dividing by an alpha of 255 is not dividing at all —
        ///     which is why the float16 rows measured before this all agreed
        ///     with the byte path.
        ///   - The gamut clip. A display-p3 red read back as srgb answers
        ///     `1.0930633544921875 -0.22672080993652344`, where the unorm8 read
        ///     of the same pixel clamps to `255 0 0`.
        fn readFloatInto(
            self: *const T,
            window: Window,
            to: color.CanvasSpace,
            out: anytype,
            exec: *Execution,
        ) !void {
            const units = try exec.arena.alloc([4]f32, out.len / 4);
            // The read overwrites only the part of the window that overlaps the
            // canvas, and this buffer is not the fresh array the byte arm has.
            @memset(units, .{ 0, 0, 0, 0 });
            self._surface.readUnitPixels(
                width(self),
                height(self),
                window.x,
                window.y,
                window.width,
                window.height,
                units,
            );
            for (units, 0..) |pixel, i| {
                const rgb = color.convertCanvasUnit(space(self), to, pixel[0..3].*);
                out[i * 4 + 0] = @floatCast(rgb[0]);
                out[i * 4 + 1] = @floatCast(rgb[1]);
                out[i * 4 + 2] = @floatCast(rgb[2]);
                out[i * 4 + 3] = @floatCast(pixel[3]);
            }
        }

        /// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/putImageData
        ///
        /// The one paint that ignores the drawing state whole: the transform,
        /// `globalAlpha` and the composite operator set together still land the
        /// ImageData's own bytes, and transparent black over a painted pixel
        /// erases it rather than leaving it alone (measured --
        /// probes/canvas-put-image-data.js). So this reaches past every helper
        /// the drawing calls share and writes the bitmap directly.
        ///
        /// The dirty rectangle is a whole WebIDL overload rather than four
        /// optional arguments, so a call carrying some of it is refused the way
        /// an unmatched overload is.
        pub fn putImageData(
            self: *T,
            image_data: *ImageData,
            dx: i32,
            dy: i32,
            dirty_x: ?i32,
            dirty_y: ?i32,
            dirty_width: ?i32,
            dirty_height: ?i32,
            exec: *Execution,
        ) !void {
            const given: u3 = @as(u3, @intFromBool(dirty_x != null)) +
                @intFromBool(dirty_y != null) +
                @intFromBool(dirty_width != null) +
                @intFromBool(dirty_height != null);
            if (given != 0 and given != 4) {
                return dictionary.throwTypeError(
                    "Failed to execute 'putImageData' on '" ++ T.JsApi.Meta.name ++
                        "': Overload resolution failed.",
                    exec,
                );
            }

            // The dirty rectangle is in the ImageData's own coordinates, and it
            // is a window rather than a demand: a negative extent flips it
            // about its origin and an oversized one clips to the source, the
            // way getImageData's window does.
            const source_width: i64 = image_data._width;
            const source_height: i64 = image_data._height;
            var x0: i64 = 0;
            var y0: i64 = 0;
            var x1: i64 = source_width;
            var y1: i64 = source_height;
            if (given == 4) {
                const ox: i64 = dirty_x.?;
                const oy: i64 = dirty_y.?;
                const ow: i64 = dirty_width.?;
                const oh: i64 = dirty_height.?;
                x0 = @max(0, @min(ox, ox + ow));
                x1 = @min(source_width, @max(ox, ox + ow));
                y0 = @max(0, @min(oy, oy + oh));
                y1 = @min(source_height, @max(oy, oy + oh));
            }
            if (x0 >= x1 or y0 >= y1) {
                return;
            }

            const window_width: u32 = @intCast(x1 - x0);
            const window_height: u32 = @intCast(y1 - y0);
            const source = try image_data.straightBytes(exec.js.local.?, exec.arena);

            // Copied out row by row rather than converted in place: the unorm8
            // arm of `straightBytes` hands over the array the page itself holds,
            // and the conversion below writes into what it is given.
            const stride = @as(usize, window_width) * 4;
            const window = try exec.arena.alloc(u8, stride * window_height);
            for (0..window_height) |row| {
                const from = ((@as(usize, @intCast(y0)) + row) * image_data._width +
                    @as(usize, @intCast(x0))) * 4;
                @memcpy(window[row * stride ..][0..stride], source[from..][0..stride]);
            }
            color.convertCanvasPixels(image_data._settings.color_space, space(self), window);

            self._surface.writePixels(
                width(self),
                height(self),
                dx + x0,
                dy + y0,
                window_width,
                window_height,
                window,
            );
        }

        /// The byte format's read: the window's overlap with the bitmap, in the
        /// space the caller asked for — which is the bitmap's own only by
        /// default.
        ///
        /// When the two spaces differ the quantisation waits until the end. The
        /// bitmap is premultiplied, so the read divides the alpha back out
        /// first, and that quotient is not a byte: rounding it to one before
        /// converting loses both a fraction and — where the un-premultiplied
        /// channel lands outside the gamut, which is the whole reason the
        /// premultiply kept it — the clip. Measured
        /// (results/canvas-color-notation.chrome.json): `color(display-p3 1
        /// 0.25 0.5 / 0.5)` on an srgb bitmap stores a red of 139, which is
        /// 276.8 of 255 once divided back out, and reads `fe407e80` as
        /// display-p3 where rounding first clamps it to 255 and answers
        /// `ea3b7e80`.
        fn readInto(
            self: *const T,
            window: Window,
            to: color.CanvasSpace,
            out: []u8,
            exec: *Execution,
        ) !void {
            const from = space(self);
            if (from == to) {
                self._surface.readPixels(
                    width(self),
                    height(self),
                    window.x,
                    window.y,
                    window.width,
                    window.height,
                    out,
                );
                return;
            }

            const units = try exec.arena.alloc([4]f32, out.len / 4);
            // `out` is the fresh array the page will be handed and so already
            // transparent black; this buffer is not.
            @memset(units, .{ 0, 0, 0, 0 });
            self._surface.readUnitPixels(
                width(self),
                height(self),
                window.x,
                window.y,
                window.width,
                window.height,
                units,
            );
            for (units, 0..) |pixel, i| {
                const rgb = color.convertCanvasUnit(from, to, pixel[0..3].*);
                out[i * 4 + 0] = color.RGBA.round255(@as(f64, rgb[0]) * 255);
                out[i * 4 + 1] = color.RGBA.round255(@as(f64, rgb[1]) * 255);
                out[i * 4 + 2] = color.RGBA.round255(@as(f64, rgb[2]) * 255);
                out[i * 4 + 3] = color.RGBA.round255(@as(f64, pixel[3]) * 255);
            }
        }

        const Window = struct { x: i32, y: i32, width: u32, height: u32 };

        /// The rect `getImageData` reads. A negative size is not a refusal: the
        /// window is flipped about the origin, so `getImageData(1, 0, -1, 1)` on
        /// a painted 2x2 answers the pixel at x=0 and `(0, 0, -1, 1)` answers
        /// the transparent one off the left edge. A *zero* size is a refusal,
        /// and it names the dimension (measured --
        /// probes/canvas-image-data-settings-2.js).
        fn imageDataWindow(sx: i32, sy: i32, sw: i32, sh: i32, exec: *Execution) !Window {
            if (sw == 0) {
                return throwSourceZero("width", exec);
            }
            if (sh == 0) {
                return throwSourceZero("height", exec);
            }
            return .{
                .x = if (sw < 0) sx +% sw else sx,
                .y = if (sh < 0) sy +% sh else sy,
                .width = @abs(sw),
                .height = @abs(sh),
            };
        }

        fn throwSourceZero(comptime dimension: []const u8, exec: *Execution) anyerror {
            return dictionary.throwDom(
                "IndexSizeError",
                "Failed to execute 'getImageData' on '" ++ T.JsApi.Meta.name ++
                    "': The source " ++ dimension ++ " is 0.",
                exec,
            );
        }
    };
}
