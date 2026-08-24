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

const path = @import("path.zig");
const Surface = @import("raster.zig");
const state = @import("context_state.zig");
const canvas_objects = @import("canvas_objects.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const ImageBitmap = @import("ImageBitmap.zig");
const DOMException = @import("../DOMException.zig");
const CanvasElement = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");

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

        /// True when the transform maps axis-aligned rectangles to
        /// axis-aligned rectangles, which is every `scale` and `translate`.
        fn upright(ctm: Transform) bool {
            return ctm.b == 0 and ctm.c == 0;
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
                self._fill_style.colour,
                self._global_alpha,
            );
        }

        pub fn stroke(self: *T, _: ?js.Value, exec: *Execution) void {
            self._surface.strokePath(
                exec.call_arena,
                width(self),
                height(self),
                &self._path,
                self._line_width * self._transform.meanScale(),
                self._stroke_style.colour,
                self._global_alpha,
            );
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
                self._surface.fillRect(width(self), height(self), at.x, at.y, w * ctm.a, h * ctm.d, self._fill_style.colour, self._global_alpha);
                return;
            }
            var quad: path.Path = .{};
            quad.rect(exec.call_arena, x, y, w, h, ctm) catch return;
            self._surface.fillPath(exec.call_arena, width(self), height(self), &quad, .nonzero, self._fill_style.colour, self._global_alpha);
        }

        pub fn strokeRect(self: *T, x: f64, y: f64, w: f64, h: f64, exec: *Execution) void {
            const ctm = self._transform;
            const line_width = self._line_width * ctm.meanScale();
            if (upright(ctm)) {
                const at = ctm.apply(x, y);
                self._surface.strokeRect(width(self), height(self), at.x, at.y, w * ctm.a, h * ctm.d, line_width, self._stroke_style.colour, self._global_alpha);
                return;
            }
            var quad: path.Path = .{};
            quad.rect(exec.call_arena, x, y, w, h, ctm) catch return;
            self._surface.strokePath(exec.call_arena, width(self), height(self), &quad, line_width, self._stroke_style.colour, self._global_alpha);
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
                blit,
                self._transform,
                self._global_alpha,
            );
        }

        const Source = struct {
            surface: *const Surface,
            width: u32,
            height: u32,
        };

        /// The pixels behind a `CanvasImageSource`, when there are any. Both
        /// canvas types keep theirs on the 2D context they handed out, so a
        /// canvas that was never drawn into — or was only ever used for WebGL
        /// — has nothing to give. An `ImageBitmap` keeps a snapshot of its own.
        fn sourceOf(value: js.Value, exec: *Execution) !?Source {
            if (value.toZig(*CanvasElement)) |canvas| {
                const cached = canvas._cached orelse return null;
                return switch (cached) {
                    .@"2d" => |ctx| .{ .surface = &ctx._surface, .width = canvas.getWidth(), .height = canvas.getHeight() },
                    else => null,
                };
            } else |_| {}
            if (value.toZig(*OffscreenCanvas)) |canvas| {
                const cached = canvas._cached orelse return null;
                return switch (cached) {
                    .@"2d" => |ctx| .{ .surface = &ctx._surface, .width = canvas.getWidth(), .height = canvas.getHeight() },
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
    };
}
