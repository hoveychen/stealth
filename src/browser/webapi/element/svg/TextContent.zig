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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const text_measure = @import("../../../text_measure.zig");
const font_metrics = @import("../../../font_metrics.zig");

const Node = @import("../../Node.zig");
const DOMRect = @import("../../DOMRect.zig");
const Element = @import("../../Element.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const PathData = @import("../../svg/PathData.zig");

const Graphics = @import("Graphics.zig");

pub const TextPositioning = @import("TextPositioning.zig");
pub const TextPath = @import("TextPath.zig");

const TextContent = @This();

pub const Proto = Graphics;
_proto: *Graphics,
_type: Type,

pub const Type = union(enum) {
    positioning: *TextPositioning,
    text_path: *TextPath,
};

pub fn is(self: *TextContent, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |field| {
        if (@field(Type, field.name) == self._type) {
            if (field.type == *T) return @field(self._type, field.name);
        }
    }
    if (self._type == .positioning) return self._type.positioning.is(T);
    return null;
}

pub fn asElement(self: *TextContent) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextContent) *Node {
    return self.asElement().asNode();
}

fn text(self: *TextContent, frame: *Frame) []const u8 {
    return self.asNode().getTextContentAlloc(frame.local_arena) catch "";
}

fn fontSize(self: *TextContent, frame: *Frame) f64 {
    return frame._style_manager.computedFontSize(self.asElement());
}

/// The first family in the cascaded `font-family` list we have a table for.
/// Chrome falls back to the standard font for anything it cannot resolve and
/// so do we, which is also what an SVG with no `font-family` at all gets:
/// serif is Chrome's default SVG font, not sans-serif.
fn fontFamily(self: *TextContent, frame: *Frame) font_metrics.Family {
    const list = frame._style_manager.computedFontFamily(self.asElement()) orelse {
        return font_metrics.fallback;
    };
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n\x0c'\"");
        if (font_metrics.find(name)) |family| {
            return family;
        }
    }
    return font_metrics.fallback;
}

/// Where the element's first glyph sits, from its `x` / `y` attributes. Only
/// the single-value form is read: a `x="10 20 30"` list positions each glyph
/// separately, which needs a layout we do not have.
fn origin(self: *TextContent, frame: *Frame) !struct { x: f64, y: f64 } {
    const element = self.asElement();
    const x = (try AnimatedLength.getOrCreate(element, .x, frame)).getBaseVal().getValue(frame);
    const y = (try AnimatedLength.getOrCreate(element, .y, frame)).getBaseVal().getValue(frame);
    return .{
        .x = if (std.math.isFinite(x)) x else 0,
        .y = if (std.math.isFinite(y)) y else 0,
    };
}

/// The box Chrome answers for a `<text>`: the advance width of its content,
/// standing on the font's ascent and descent at the text's own origin. Chrome
/// grows this by the ink a colour-emoji bitmap spills past its advance —
/// under a pixel at 20px, a few at 200px — which we do not model.
pub fn getBounds(self: *TextContent, frame: *Frame) !PathData.Bounds {
    const size = self.fontSize(frame);
    const width = text_measure.svgWidth(self.fontFamily(frame), self.text(frame), size);
    if (!std.math.isFinite(width) or width <= 0) {
        return .{};
    }
    const box = font_metrics.boundingBox(self.fontFamily(frame), size);
    const at = try self.origin(frame);
    return .{
        .min_x = at.x,
        .min_y = at.y - box.ascent,
        .max_x = at.x + width,
        .max_y = at.y + box.descent,
    };
}

fn getTextLength(self: *TextContent, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .text_length, frame);
}

fn getLengthAdjust(self: *TextContent, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .length_adjust, frame);
}

pub fn getNumberOfChars(self: *TextContent, frame: *Frame) u32 {
    return text_measure.utf16Length(self.text(frame));
}

pub fn getComputedTextLength(self: *TextContent, frame: *Frame) f64 {
    return text_measure.svgWidth(self.fontFamily(frame), self.text(frame), self.fontSize(frame));
}

pub fn getSubStringLength(self: *TextContent, charnum: u32, nchars: u32, frame: *Frame) !f64 {
    return text_measure.svgSubstringWidth(self.fontFamily(frame), self.text(frame), charnum, nchars, self.fontSize(frame));
}

// One character's glyph cell: as wide as that cluster's advance, standing on
// the font's ascent and descent, placed where the character starts in the
// element's user space. Chrome answers the same box.
pub fn getExtentOfChar(self: *TextContent, charnum: u32, frame: *Frame) !*DOMRect {
    const size = self.fontSize(frame);
    const family = self.fontFamily(frame);
    const extent = try text_measure.svgCharExtent(family, self.text(frame), charnum, size);
    const box = font_metrics.boundingBox(family, size);
    const at = try self.origin(frame);
    return DOMRect.create(.{
        .x = at.x + extent.offset,
        .y = at.y - box.ascent,
        .width = extent.advance,
        .height = box.ascent + box.descent,
    }, frame._factory);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextContent);
    pub const Meta = struct {
        pub const name = "SVGTextContentElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const LENGTHADJUST_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const LENGTHADJUST_SPACING = bridge.property(1, .{ .template = true });
    pub const LENGTHADJUST_SPACINGANDGLYPHS = bridge.property(2, .{ .template = true });

    pub const textLength = bridge.accessor(TextContent.getTextLength, null, .{});
    pub const lengthAdjust = bridge.accessor(TextContent.getLengthAdjust, null, .{});
    pub const getNumberOfChars = bridge.function(TextContent.getNumberOfChars, .{});
    pub const getComputedTextLength = bridge.function(TextContent.getComputedTextLength, .{});
    pub const getSubStringLength = bridge.function(TextContent.getSubStringLength, .{});
    pub const getExtentOfChar = bridge.function(TextContent.getExtentOfChar, .{});
};
