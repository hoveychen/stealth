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

const Canvas = @import("../element/html/Canvas.zig");
const Font = @import("font.zig");
const state = @import("context_state.zig");
const attributes = @import("context_attributes.zig");
const path = @import("path.zig");
const context_draw = @import("context_draw.zig");
const canvas_objects = @import("canvas_objects.zig");
const DOMMatrix = @import("../DOMMatrix.zig");

const PaintStyle = canvas_objects.PaintStyle;
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
/// Fill style: a colour, or the gradient/pattern object assigned to it.
_fill_style: PaintStyle = .{},
/// Stroke style, same three arms.
_stroke_style: PaintStyle = .{},
_line_width: f64 = 1,
_global_alpha: f64 = 1,
/// The parsed `font` attribute. Drives measureText; see font.zig.
_font: Font = Font.default,
/// Drawing state the rasteriser does not read. See context_state.zig for
/// why it is here at all.
_state: state.State = .{},
/// The dictionary this context was created from. Fixed for its whole life:
/// a later `getContext` call's settings are dropped, and so is a `width`
/// assignment's reset. See context_attributes.zig.
_attributes: attributes.TwoD = .{},
/// The current transformation matrix, and the path being built under it.
/// Both live in context_draw.zig, which is shared with the other 2D context.
_transform: path.Transform = .{},
_path: path.Path = .{},
/// The save() stack. Frame-arena backed, like the path.
_saved: std.ArrayList(context_draw.Saved(Font)) = .empty,

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

pub fn getFillStyle(self: *const CanvasRenderingContext2D, exec: *Execution) !PaintStyle.Read {
    return self._fill_style.read(exec.local_arena);
}

pub fn setFillStyle(self: *CanvasRenderingContext2D, value: PaintStyle.Assigned) void {
    self._fill_style.assign(value);
}

pub fn getStrokeStyle(self: *const CanvasRenderingContext2D, exec: *Execution) !PaintStyle.Read {
    return self._stroke_style.read(exec.local_arena);
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: PaintStyle.Assigned) void {
    self._stroke_style.assign(value);
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
    // A worker's OffscreenCanvas has no document, so no `@font-face` file can
    // have supplied a family for it -- `null` there is the right answer, not a
    // gap.
    const loaded = switch (exec.js.global) {
        .frame => |frame| frame.loadedFonts(),
        .worker => null,
    };
    self._font = Font.parse(exec.arena, value, loaded) orelse self._font;
}

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/measureText
pub fn measureText(self: *const CanvasRenderingContext2D, text: []const u8, exec: *Execution) !*TextMetrics {
    return exec._factory.create(TextMetrics{
        ._metrics = text_measure.measure(
            .of(self._font.family, self._font.weight, self._font.italic, .{
                // Both attributes were kept and never read, so a string came
                // back the same width whatever either one said. A relative unit
                // resolves here rather than where it was set, because it
                // follows a later change of `font` -- see context_state.Spacing.
                .letter = self._state.letter_spacing.pixels(self._font.size, self._font.family),
                .word = self._state.word_spacing.pixels(self._font.size, self._font.family),
            }, .canvas, state.kerns(self._state.font_kerning),
                // The canvas has no `text-transform`: there is no attribute for it
                // and `measureText` sees none of the element's style. Measured --
                // 'hello world' is 73.3203125 through measureText whatever the
                // canvas element's own `text-transform` says.
                .none,
                // Nor a `font-variant-caps`: the `font` attribute's grammar has
                // a variant slot, but what a small-caps canvas font measures has
                // not been read off Chrome, so this stays at the value that
                // changes nothing.
                .none),
            text,
            self._font.size,
        ),
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

/// All three of these are the same code on either context but for the interface
/// name their refusals carry, so they live in the mixin.
pub const createImageData = draw.createImageData;
pub const getImageData = draw.getImageData;
pub const putImageData = draw.putImageData;

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/getContextAttributes
pub fn getContextAttributes(self: *const CanvasRenderingContext2D) attributes.TwoD {
    return self._attributes;
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

pub const getTransform = draw.getTransform;

/// Drops the bitmap and every piece of drawing state, as `reset()` does.
pub fn reset(self: *CanvasRenderingContext2D) void {
    self._surface.reset();
    self._fill_style = .{};
    self._stroke_style = .{};
    self._line_width = 1;
    self._global_alpha = 1;
    self._font = Font.default;
    self._state.reset();
    draw.resetDrawing(self);
}

pub fn drawFocusIfNeeded(_: *CanvasRenderingContext2D, _: js.Value, _: ?js.Value) void {}

/// No path is ever built, so nothing is ever inside one.
pub fn isPointInPath(_: *const CanvasRenderingContext2D, _: js.Value, _: f64, _: ?js.Value) bool {
    return false;
}

pub fn isPointInStroke(_: *const CanvasRenderingContext2D, _: js.Value, _: f64) bool {
    return false;
}

// The gradient and pattern handles, shared with the other 2D context: the
// sentences they refuse with name the interface, so they are written once and
// take the name from `T`.
pub const createLinearGradient = draw.createLinearGradient;
pub const createRadialGradient = draw.createRadialGradient;
pub const createConicGradient = draw.createConicGradient;
pub const createPattern = draw.createPattern;

pub const save = draw.save;
pub const restore = draw.restore;
pub const scale = draw.scale;
pub const rotate = draw.rotate;
pub const translate = draw.translate;
pub const transform = draw.transform;
pub const setTransform = draw.setTransform;
pub const resetTransform = draw.resetTransform;
pub const fillRect = draw.fillRect;
pub const strokeRect = draw.strokeRect;
pub const clearRect = draw.clearRect;
pub const beginPath = draw.beginPath;
pub const closePath = draw.closePath;
pub const moveTo = draw.moveTo;
pub const lineTo = draw.lineTo;
pub const quadraticCurveTo = draw.quadraticCurveTo;
pub const bezierCurveTo = draw.bezierCurveTo;
pub const arc = draw.arc;
pub const arcTo = draw.arcTo;
pub const ellipse = draw.ellipse;
pub const rect = draw.rect;
pub const roundRect = draw.roundRect;
pub const drawImage = draw.drawImage;
pub const fill = draw.fill;
pub const stroke = draw.stroke;

/// No clipping region is kept, so the path a script clips to is discarded --
/// the same silence as before, now that everything around it draws.
pub fn clip(_: *CanvasRenderingContext2D, _: ?js.Value, _: ?js.Value) void {}
pub fn fillText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

const attr = state.Accessors(CanvasRenderingContext2D);
const draw = context_draw.Mixin(CanvasRenderingContext2D);

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is own-property order, and this is Chrome 151's own
    // Object.getOwnPropertyNames(CanvasRenderingContext2D.prototype) verbatim,
    // so the drawing state is not grouped the way it reads in the spec.
    //
    // Chrome exposes all 28 of its 2D context attributes as prototype
    // accessors, so all of ours are accessors too. Five of them --
    // fillStyle, strokeStyle, lineWidth, globalAlpha and font -- back the
    // rasteriser as well, so unlike the rest they read through to Zig instead
    // of only through `attr`.
    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});
    pub const lang = bridge.accessor(attr.freeform("lang").get, attr.freeform("lang").set, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const textAlign = bridge.accessor(attr.keyword("text_align", &state.text_aligns).get, attr.keyword("text_align", &state.text_aligns).set, .{});
    pub const textBaseline = bridge.accessor(attr.keyword("text_baseline", &state.text_baselines).get, attr.keyword("text_baseline", &state.text_baselines).set, .{});
    pub const direction = bridge.accessor(attr.keyword("direction", &state.directions).get, attr.keyword("direction", &state.directions).set, .{});
    pub const fontKerning = bridge.accessor(attr.keyword("font_kerning", &state.font_kernings).get, attr.keyword("font_kerning", &state.font_kernings).set, .{});
    pub const fontStretch = bridge.accessor(attr.keyword("font_stretch", &state.font_stretches).get, attr.keyword("font_stretch", &state.font_stretches).set, .{});
    pub const fontVariantCaps = bridge.accessor(attr.keyword("font_variant_caps", &state.font_variant_caps_values).get, attr.keyword("font_variant_caps", &state.font_variant_caps_values).set, .{});
    pub const letterSpacing = bridge.accessor(attr.spacing("letter_spacing").get, attr.spacing("letter_spacing").set, .{});
    pub const textRendering = bridge.accessor(attr.keyword("text_rendering", &state.text_renderings).get, attr.keyword("text_rendering", &state.text_renderings).set, .{});
    pub const wordSpacing = bridge.accessor(attr.spacing("word_spacing").get, attr.spacing("word_spacing").set, .{});
    pub const globalCompositeOperation = bridge.accessor(attr.keyword("global_composite_operation", &state.composite_operations).get, attr.keyword("global_composite_operation", &state.composite_operations).set, .{});
    pub const filter = bridge.accessor(attr.freeform("filter").get, attr.freeform("filter").set, .{});
    pub const imageSmoothingQuality = bridge.accessor(attr.keyword("image_smoothing_quality", &state.smoothing_qualities).get, attr.keyword("image_smoothing_quality", &state.smoothing_qualities).set, .{});
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});
    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const shadowColor = bridge.accessor(attr.colour("shadow_color").get, attr.colour("shadow_color").set, .{});
    pub const lineCap = bridge.accessor(attr.keyword("line_cap", &state.line_caps).get, attr.keyword("line_cap", &state.line_caps).set, .{});
    pub const lineJoin = bridge.accessor(attr.keyword("line_join", &state.line_joins).get, attr.keyword("line_join", &state.line_joins).set, .{});
    pub const globalAlpha = bridge.accessor(CanvasRenderingContext2D.getGlobalAlpha, CanvasRenderingContext2D.setGlobalAlpha, .{});
    pub const imageSmoothingEnabled = bridge.accessor(attr.boolean("image_smoothing_enabled").get, attr.boolean("image_smoothing_enabled").set, .{});
    pub const shadowOffsetX = bridge.accessor(attr.number("shadow_offset_x").get, attr.number("shadow_offset_x").set, .{});
    pub const shadowOffsetY = bridge.accessor(attr.number("shadow_offset_y").get, attr.number("shadow_offset_y").set, .{});
    pub const shadowBlur = bridge.accessor(attr.number("shadow_blur").get, attr.number("shadow_blur").set, .{});
    pub const lineWidth = bridge.accessor(CanvasRenderingContext2D.getLineWidth, CanvasRenderingContext2D.setLineWidth, .{});
    pub const miterLimit = bridge.accessor(attr.number("miter_limit").get, attr.number("miter_limit").set, .{});
    pub const lineDashOffset = bridge.accessor(attr.number("line_dash_offset").get, attr.number("line_dash_offset").set, .{});
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const createConicGradient = bridge.function(CanvasRenderingContext2D.createConicGradient, .{});
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{});
    pub const createLinearGradient = bridge.function(CanvasRenderingContext2D.createLinearGradient, .{});
    pub const createPattern = bridge.function(CanvasRenderingContext2D.createPattern, .{});
    pub const createRadialGradient = bridge.function(CanvasRenderingContext2D.createRadialGradient, .{});
    pub const drawFocusIfNeeded = bridge.function(CanvasRenderingContext2D.drawFocusIfNeeded, .{ .noop = true });
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{ .arity = 3 });
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{ .arity = 0 });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{ .noop = true });
    pub const getContextAttributes = bridge.function(CanvasRenderingContext2D.getContextAttributes, .{});
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{});
    pub const getLineDash = bridge.function(CanvasRenderingContext2D.getLineDash, .{});
    pub const getTransform = bridge.function(CanvasRenderingContext2D.getTransform, .{});
    pub const isContextLost = bridge.function(CanvasRenderingContext2D.isContextLost, .{});
    pub const isPointInPath = bridge.function(CanvasRenderingContext2D.isPointInPath, .{});
    pub const isPointInStroke = bridge.function(CanvasRenderingContext2D.isPointInStroke, .{});
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});
    pub const reset = bridge.function(CanvasRenderingContext2D.reset, .{});
    pub const roundRect = bridge.function(CanvasRenderingContext2D.roundRect, .{ .arity = 4 });
    pub const setLineDash = bridge.function(CanvasRenderingContext2D.setLineDash, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{ .noop = true });
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{ .arity = 5 });
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .arity = 5 });
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{ .arity = 0 });
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{ .arity = 6 });
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{ .arity = 0 });
    pub const ellipse = bridge.function(CanvasRenderingContext2D.ellipse, .{ .arity = 7 });
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{ .arity = 2 });
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{ .arity = 2 });
    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{ .arity = 4 });
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{ .arity = 4 });
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .arity = 0 });
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{ .arity = 0 });
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{ .arity = 1 });
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{ .arity = 0 });
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .arity = 2 });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .arity = 0 });
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{ .arity = 0 });
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .arity = 6 });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{ .arity = 2 });
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}
