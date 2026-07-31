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

const std = @import("std");

const js = @import("../../js/js.zig");

const color = @import("../../color.zig");

const Canvas = @import("../element/html/Canvas.zig");
const Font = @import("font.zig");
const state = @import("context_state.zig");
const canvas_objects = @import("canvas_objects.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const DOMMatrixReadOnly = @import("../DOMMatrixReadOnly.zig");

const CanvasGradient = canvas_objects.CanvasGradient;
const CanvasPattern = canvas_objects.CanvasPattern;
const TextMetrics = @import("TextMetrics.zig");
const text_measure = @import("../../text_measure.zig");
const ImageData = @import("../ImageData.zig");
const Surface = @import("raster.zig");

const Execution = js.Execution;

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();
/// Reference to the parent canvas element.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/canvas
_canvas: *Canvas,
/// The pixels this context has actually painted. See `raster.zig` for what
/// this does and does not attempt.
_surface: Surface,
/// Fill color.
/// TODO: Add support for `CanvasGradient` and `CanvasPattern`.
_fill_style: color.RGBA = color.RGBA.Named.black,
/// Stroke color, same caveat.
_stroke_style: color.RGBA = color.RGBA.Named.black,
_line_width: f64 = 1,
_global_alpha: f64 = 1,
/// The parsed `font` attribute. Drives measureText; see font.zig.
_font: Font = Font.default,
/// Drawing state the rasteriser does not read. See context_state.zig for
/// why it is here at all.
_state: state.State = .{},

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

pub fn getFillStyle(self: *const CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(exec.local_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
) !void {
    // Prefer the same fill_style if fails.
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
}

pub fn getStrokeStyle(self: *const CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(exec.local_arena);
    try self._stroke_style.format(&w.writer);
    return w.written();
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: []const u8) void {
    self._stroke_style = color.RGBA.parse(value) catch self._stroke_style;
}

pub fn getLineWidth(self: *const CanvasRenderingContext2D) f64 {
    return self._line_width;
}

/// Zero, negative and non-finite widths are ignored rather than applied.
pub fn setLineWidth(self: *CanvasRenderingContext2D, value: f64) void {
    if (std.math.isFinite(value) and value > 0) {
        self._line_width = value;
    }
}

pub fn getFont(self: *const CanvasRenderingContext2D) []const u8 {
    return self._font.css;
}

/// An unparseable value leaves the previous font in place, which is what
/// Chrome does — it does not fall back to the default.
pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8, exec: *Execution) void {
    self._font = Font.parse(exec.arena, value) orelse self._font;
}

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/measureText
pub fn measureText(self: *const CanvasRenderingContext2D, text: []const u8, exec: *Execution) !*TextMetrics {
    return exec._factory.create(TextMetrics{
        ._metrics = text_measure.measure(self._font.family, text, self._font.size),
    });
}

pub fn getGlobalAlpha(self: *const CanvasRenderingContext2D) f64 {
    return self._global_alpha;
}

/// Out-of-range and non-finite values are ignored, per the spec.
pub fn setGlobalAlpha(self: *CanvasRenderingContext2D, value: f64) void {
    if (std.math.isFinite(value) and value >= 0 and value <= 1) {
        self._global_alpha = value;
    }
}

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
};

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    width_or_image_data: WidthOrImageData,
    /// If `ImageData` variant preferred, this is null.
    maybe_height: ?u32,
    /// Can be used if width and height provided.
    maybe_settings: ?ImageData.ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    switch (width_or_image_data) {
        .width => |width| {
            const height = maybe_height orelse return error.TypeError;
            return ImageData.init(width, height, maybe_settings, exec);
        },
        .image_data => |image_data| {
            return ImageData.init(image_data._width, image_data._height, null, exec);
        },
    }
}

pub fn putImageData(_: *const CanvasRenderingContext2D, _: *ImageData, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

// CanvasImageSource (HTMLImageElement, HTMLCanvasElement, ImageBitmap, ...) is
// just taken as a js.Value for now since we don't use it, and that's much easier.
pub fn drawImage(_: *const CanvasRenderingContext2D, _: js.Value, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

pub fn getImageData(
    self: *const CanvasRenderingContext2D,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    exec: *Execution,
) !*ImageData {
    if (sw <= 0 or sh <= 0) {
        return error.IndexSizeError;
    }

    const image_data = try ImageData.init(@intCast(sw), @intCast(sh), null, exec);
    // Freshly created, so it is already transparent black: `readPixels` only
    // has to overwrite the part of the window that overlaps the canvas.
    const out = image_data._data.local(exec.js.local.?).slice();
    self._surface.readPixels(
        self._canvas.getWidth(),
        self._canvas.getHeight(),
        sx,
        sy,
        @intCast(sw),
        @intCast(sh),
        out,
    );
    return image_data;
}

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/getContextAttributes
pub fn getContextAttributes(_: *const CanvasRenderingContext2D) state.ContextAttributes {
    return .{};
}

/// We never lose the context: there is no GPU behind it to lose.
pub fn isContextLost(_: *const CanvasRenderingContext2D) bool {
    return false;
}

pub fn getLineDash(self: *const CanvasRenderingContext2D) []const f64 {
    return self._state.line_dash;
}

pub fn setLineDash(self: *CanvasRenderingContext2D, segments: []const f64, exec: *Execution) void {
    self._state.line_dash = state.normaliseLineDash(exec.arena, segments) orelse self._state.line_dash;
}

/// Always the identity: we do not implement transforms, so there is never
/// anything else to report.
pub fn getTransform(_: *const CanvasRenderingContext2D, exec: *Execution) !*DOMMatrix {
    return DOMMatrix.create(DOMMatrixReadOnly.identity(), true, exec.page);
}

/// Drops the bitmap and every piece of drawing state, as `reset()` does.
pub fn reset(self: *CanvasRenderingContext2D) void {
    self._surface.reset();
    self._fill_style = color.RGBA.Named.black;
    self._stroke_style = color.RGBA.Named.black;
    self._line_width = 1;
    self._global_alpha = 1;
    self._font = Font.default;
    self._state.reset();
}

// Path geometry we accept and discard, like the rest of the path API.
pub fn roundRect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: ?js.Value) void {}
pub fn ellipse(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn drawFocusIfNeeded(_: *CanvasRenderingContext2D, _: js.Value, _: ?js.Value) void {}

/// No path is ever built, so nothing is ever inside one.
pub fn isPointInPath(_: *const CanvasRenderingContext2D, _: js.Value, _: f64, _: ?js.Value) bool {
    return false;
}

pub fn isPointInStroke(_: *const CanvasRenderingContext2D, _: js.Value, _: f64) bool {
    return false;
}

// The gradient and pattern handles. They carry no paint — see
// canvas_objects.zig — but a script that builds one gets an object back
// rather than a TypeError.
pub fn createLinearGradient(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, exec: *Execution) !*CanvasGradient {
    return exec._factory.create(CanvasGradient{});
}

pub fn createRadialGradient(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, exec: *Execution) !*CanvasGradient {
    return exec._factory.create(CanvasGradient{});
}

pub fn createConicGradient(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, exec: *Execution) !*CanvasGradient {
    return exec._factory.create(CanvasGradient{});
}

pub fn createPattern(_: *CanvasRenderingContext2D, _: js.Value, _: js.Value, exec: *Execution) !*CanvasPattern {
    return exec._factory.create(CanvasPattern{});
}

pub fn save(_: *CanvasRenderingContext2D) void {}
pub fn restore(_: *CanvasRenderingContext2D) void {}
pub fn scale(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *CanvasRenderingContext2D, _: ?js.Value, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self._surface.clearRect(self._canvas.getWidth(), self._canvas.getHeight(), x, y, w, h);
}

pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self._surface.fillRect(
        self._canvas.getWidth(),
        self._canvas.getHeight(),
        x,
        y,
        w,
        h,
        self._fill_style,
        self._global_alpha,
    );
}

pub fn strokeRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self._surface.strokeRect(
        self._canvas.getWidth(),
        self._canvas.getHeight(),
        x,
        y,
        w,
        h,
        self._line_width,
        self._stroke_style,
        self._global_alpha,
    );
}

pub fn beginPath(_: *CanvasRenderingContext2D) void {}
pub fn closePath(_: *CanvasRenderingContext2D) void {}
pub fn moveTo(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn lineTo(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn quadraticCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn bezierCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn arc(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn arcTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn rect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn fill(_: *CanvasRenderingContext2D) void {}
pub fn stroke(_: *CanvasRenderingContext2D) void {}
pub fn clip(_: *CanvasRenderingContext2D) void {}
pub fn fillText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

const attr = state.Accessors(CanvasRenderingContext2D);

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});

    // These three back the rasteriser, so unlike the rest of the drawing
    // state they have to be readable from Zig. Chrome exposes every one of
    // its 2D context attributes as a prototype accessor, so this is also a
    // step towards the right shape; the remaining `bridge.property` entries
    // above are still plain data properties, which Chrome never has.
    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});
    pub const lineWidth = bridge.accessor(CanvasRenderingContext2D.getLineWidth, CanvasRenderingContext2D.setLineWidth, .{});
    pub const globalAlpha = bridge.accessor(CanvasRenderingContext2D.getGlobalAlpha, CanvasRenderingContext2D.setGlobalAlpha, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});

    // The rest of the drawing state. Chrome exposes all 28 of its 2D context
    // attributes as prototype accessors, so all of ours are accessors too.
    pub const lang = bridge.accessor(attr.freeform("lang").get, attr.freeform("lang").set, .{});
    pub const textAlign = bridge.accessor(attr.keyword("text_align", &state.text_aligns).get, attr.keyword("text_align", &state.text_aligns).set, .{});
    pub const textBaseline = bridge.accessor(attr.keyword("text_baseline", &state.text_baselines).get, attr.keyword("text_baseline", &state.text_baselines).set, .{});
    pub const direction = bridge.accessor(attr.keyword("direction", &state.directions).get, attr.keyword("direction", &state.directions).set, .{});
    pub const fontKerning = bridge.accessor(attr.keyword("font_kerning", &state.font_kernings).get, attr.keyword("font_kerning", &state.font_kernings).set, .{});
    pub const fontStretch = bridge.accessor(attr.keyword("font_stretch", &state.font_stretches).get, attr.keyword("font_stretch", &state.font_stretches).set, .{});
    pub const fontVariantCaps = bridge.accessor(attr.keyword("font_variant_caps", &state.font_variant_caps_values).get, attr.keyword("font_variant_caps", &state.font_variant_caps_values).set, .{});
    pub const letterSpacing = bridge.accessor(attr.freeform("letter_spacing").get, attr.freeform("letter_spacing").set, .{});
    pub const textRendering = bridge.accessor(attr.keyword("text_rendering", &state.text_renderings).get, attr.keyword("text_rendering", &state.text_renderings).set, .{});
    pub const wordSpacing = bridge.accessor(attr.freeform("word_spacing").get, attr.freeform("word_spacing").set, .{});
    pub const globalCompositeOperation = bridge.accessor(attr.keyword("global_composite_operation", &state.composite_operations).get, attr.keyword("global_composite_operation", &state.composite_operations).set, .{});
    pub const filter = bridge.accessor(attr.freeform("filter").get, attr.freeform("filter").set, .{});
    pub const imageSmoothingQuality = bridge.accessor(attr.keyword("image_smoothing_quality", &state.smoothing_qualities).get, attr.keyword("image_smoothing_quality", &state.smoothing_qualities).set, .{});
    pub const imageSmoothingEnabled = bridge.accessor(attr.boolean("image_smoothing_enabled").get, attr.boolean("image_smoothing_enabled").set, .{});
    pub const shadowColor = bridge.accessor(attr.freeform("shadow_color").get, attr.freeform("shadow_color").set, .{});
    pub const shadowOffsetX = bridge.accessor(attr.number("shadow_offset_x").get, attr.number("shadow_offset_x").set, .{});
    pub const shadowOffsetY = bridge.accessor(attr.number("shadow_offset_y").get, attr.number("shadow_offset_y").set, .{});
    pub const shadowBlur = bridge.accessor(attr.number("shadow_blur").get, attr.number("shadow_blur").set, .{});
    pub const lineCap = bridge.accessor(attr.keyword("line_cap", &state.line_caps).get, attr.keyword("line_cap", &state.line_caps).set, .{});
    pub const lineJoin = bridge.accessor(attr.keyword("line_join", &state.line_joins).get, attr.keyword("line_join", &state.line_joins).set, .{});
    pub const miterLimit = bridge.accessor(attr.number("miter_limit").get, attr.number("miter_limit").set, .{});
    pub const lineDashOffset = bridge.accessor(attr.number("line_dash_offset").get, attr.number("line_dash_offset").set, .{});

    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{});
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});
    pub const getContextAttributes = bridge.function(CanvasRenderingContext2D.getContextAttributes, .{});
    pub const isContextLost = bridge.function(CanvasRenderingContext2D.isContextLost, .{});
    pub const getLineDash = bridge.function(CanvasRenderingContext2D.getLineDash, .{});
    pub const setLineDash = bridge.function(CanvasRenderingContext2D.setLineDash, .{});
    pub const getTransform = bridge.function(CanvasRenderingContext2D.getTransform, .{});
    pub const reset = bridge.function(CanvasRenderingContext2D.reset, .{});
    pub const roundRect = bridge.function(CanvasRenderingContext2D.roundRect, .{ .noop = true });
    pub const ellipse = bridge.function(CanvasRenderingContext2D.ellipse, .{ .noop = true });
    pub const drawFocusIfNeeded = bridge.function(CanvasRenderingContext2D.drawFocusIfNeeded, .{ .noop = true });
    pub const isPointInPath = bridge.function(CanvasRenderingContext2D.isPointInPath, .{});
    pub const isPointInStroke = bridge.function(CanvasRenderingContext2D.isPointInStroke, .{});
    pub const createLinearGradient = bridge.function(CanvasRenderingContext2D.createLinearGradient, .{});
    pub const createRadialGradient = bridge.function(CanvasRenderingContext2D.createRadialGradient, .{});
    pub const createConicGradient = bridge.function(CanvasRenderingContext2D.createConicGradient, .{});
    pub const createPattern = bridge.function(CanvasRenderingContext2D.createPattern, .{});

    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{ .noop = true });
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{ .noop = true });
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{});
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{ .noop = true });
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{ .noop = true });
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .noop = true });
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{ .noop = true });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{ .noop = true });
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .noop = true });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .noop = true });
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .noop = true });
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{ .noop = true });
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{ .noop = true });
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{ .noop = true });
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{ .noop = true });
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{ .noop = true });
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{ .noop = true });
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{ .noop = true });
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .noop = true });
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{ .noop = true });
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{ .noop = true });
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{ .noop = true });
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{ .noop = true });
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{ .noop = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}
