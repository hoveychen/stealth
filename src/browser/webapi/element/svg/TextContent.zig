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
const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const text_measure = @import("../../../text_measure.zig");
const font_metrics = @import("../../../font_metrics.zig");

const Node = @import("../../Node.zig");
const Text = @import("../../cdata/Text.zig");
const SvgRect = @import("../../svg/Rect.zig");
const SvgPoint = @import("../../svg/Point.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const PathData = @import("../../svg/PathData.zig");

const Graphics = @import("Graphics.zig");

pub const TextPositioning = @import("TextPositioning.zig");
pub const TextPath = @import("TextPath.zig");

const TextContent = @This();

pub const Proto = Graphics;
_type: Type,
_proto_canary: if (lp.IS_DEBUG) *Graphics else void = undefined,

pub const Type = enum(u8) {
    positioning,
    text_path,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .positioning => TextPositioning,
        .text_path => TextPath,
    };
}

pub fn subtype(self: *const TextContent, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, TextContent);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *TextContent, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    if (self._type == .positioning) return self.subtype(TextPositioning).is(T);
    return null;
}

pub fn asElement(self: *TextContent) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TextContent) *Node {
    return self.asElement().asNode();
}

fn text(self: *TextContent, frame: *Frame) []const u8 {
    return self.asNode().getTextContentAlloc(frame.local_arena) catch "";
}

fn fontSize(self: *TextContent, frame: *Frame) f64 {
    const element = self.asElement();
    return element.ownerFrame(frame)._style_manager.computedFontSize(element);
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
        // Quotes stay on: `findEntry` needs them to tell the keyword
        // `monospace` from the family name `'monospace'`, which matches nothing.
        if (font_metrics.findEntry(raw)) |family| {
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
///
/// The ascent and descent are the LAYOUT pair and not the canvas one: measured
/// at both device scales with tools/fingerprint/scratch/expr-br-and-svg-text-dsf.js,
/// a 20px monospace `<text>` has a bbox 24 tall at scale 1 and 23 at the 2 this
/// engine claims, and 10px serif 13 then 11.5 — the same numbers the block line
/// box takes, not the canvas sum. The split between the two halves moves too,
/// which is why font_metrics keeps both rather than a height.
///
/// Chrome also unions this with the INK, which we do not model: Arial's `g`
/// descends 3.3671875 at 16px where the font descent is 4 — inside it, so no
/// difference there — but a family whose tail goes further would read wider
/// than we answer (scratch/expr-svg-ascent-split.js).
pub fn getBounds(self: *TextContent, frame: *Frame) !PathData.Bounds {
    const size = self.fontSize(frame);
    const width = text_measure.svgWidth(self.fontFamily(frame), self.text(frame), size);
    if (!std.math.isFinite(width) or width <= 0) {
        return .{};
    }
    const box = font_metrics.layoutBox(self.fontFamily(frame), size);
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
pub fn getExtentOfChar(self: *TextContent, charnum: u32, frame: *Frame) !*SvgRect {
    const size = self.fontSize(frame);
    const family = self.fontFamily(frame);
    const extent = try text_measure.svgCharExtent(family, self.text(frame), charnum, size);
    const box = font_metrics.layoutBox(family, size);
    const at = try self.origin(frame);
    return SvgRect.create(.{
        .x = at.x + extent.offset,
        .y = at.y - box.ascent,
        .width = extent.advance,
        .height = box.ascent + box.descent,
    }, frame._factory);
}

/// Blink refuses an out-of-range `charnum` with two different sentences, and
/// which one you get says whether the index is past the end or exactly at it.
/// Measured on Chrome 151 for all five callers (probes/expr-svg-family-edges.js):
/// `getStartPositionOfChar(99)` on a 5-character text says "greater than the
/// maximum bound (5)", `getStartPositionOfChar(5)` says "greater than or equal
/// to". A negative index arrives as its unsigned wrap, so `-1` is quoted back
/// as 4294967295.
fn checkCharNum(self: *TextContent, charnum: u32, comptime method: []const u8, frame: *Frame) !void {
    const bound = self.getNumberOfChars(frame);
    if (charnum > bound) {
        return frame.js.fail(error.IndexSizeError, try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to execute '" ++ method ++ "' on 'SVGTextContentElement': " ++
                "The charnum provided ({d}) is greater than the maximum bound ({d}).",
            .{ charnum, bound },
        ));
    }
    if (charnum == bound) {
        return frame.js.fail(error.IndexSizeError, try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to execute '" ++ method ++ "' on 'SVGTextContentElement': " ++
                "The charnum provided ({d}) is greater than or equal to the maximum bound ({d}).",
            .{ charnum, bound },
        ));
    }
}

/// Where the `charnum`-th character starts, in the element's user space: the
/// text's own origin plus the advance of everything before it.
pub fn getStartPositionOfChar(self: *TextContent, charnum: u32, frame: *Frame) !*SvgPoint {
    try self.checkCharNum(charnum, "getStartPositionOfChar", frame);
    return self.positionOfChar(charnum, 0, frame);
}

pub fn getEndPositionOfChar(self: *TextContent, charnum: u32, frame: *Frame) !*SvgPoint {
    try self.checkCharNum(charnum, "getEndPositionOfChar", frame);
    return self.positionOfChar(charnum, 1, frame);
}

fn positionOfChar(self: *TextContent, charnum: u32, past: u32, frame: *Frame) !*SvgPoint {
    const at = try self.origin(frame);
    if (charnum + past == 0) {
        return SvgPoint.create(SvgPoint.narrow(at.x), SvgPoint.narrow(at.y), frame._page);
    }
    const advance = try text_measure.svgSubstringWidth(
        self.fontFamily(frame),
        self.text(frame),
        0,
        charnum + past,
        self.fontSize(frame),
    );
    return SvgPoint.create(SvgPoint.narrow(at.x + advance), SvgPoint.narrow(at.y), frame._page);
}

/// Always 0: a rotation comes from the `rotate` attribute or from a
/// `<textPath>`, and neither is laid out here. Chrome answers 0 for text
/// without either.
pub fn getRotationOfChar(self: *TextContent, charnum: u32, frame: *Frame) !f64 {
    try self.checkCharNum(charnum, "getRotationOfChar", frame);
    return 0;
}

/// Which character's cell contains `point`, or -1 for a point in none of them.
/// The cell is the one `getExtentOfChar` answers with, so the two agree by
/// construction. The argument is optional -- Chrome reports arity 0 -- and an
/// omitted one asks about the origin, which for text placed anywhere else is
/// -1.
pub fn getCharNumAtPosition(self: *TextContent, point_: ?*const SvgPoint, frame: *Frame) !i32 {
    const point = point_ orelse return -1;
    const size = self.fontSize(frame);
    const family = self.fontFamily(frame);
    const text_content = self.text(frame);
    const box = font_metrics.layoutBox(family, size);
    const at = try self.origin(frame);

    if (point.getY() < at.y - box.ascent or point.getY() > at.y + box.descent) {
        return -1;
    }

    const count = text_measure.utf16Length(text_content);
    var charnum: u32 = 0;
    while (charnum < count) : (charnum += 1) {
        const extent = try text_measure.svgCharExtent(family, text_content, charnum, size);
        const start = at.x + extent.offset;
        if (point.getX() >= start and point.getX() < start + extent.advance) {
            return @intCast(charnum);
        }
    }
    return -1;
}

/// Selects `nchars` characters starting at `charnum`, which for a `<text>` with
/// a single text child is a selection over that child's code units. Chrome
/// clamps `nchars` to what is left rather than refusing it.
pub fn selectSubString(self: *TextContent, charnum: u32, nchars: u32, frame: *Frame) !void {
    try self.checkCharNum(charnum, "selectSubString", frame);
    const node = self.asNode().firstChild() orelse return;
    _ = node.is(Text) orelse return;
    const count = text_measure.utf16Length(self.text(frame));
    const end = @min(charnum +| nchars, count);
    const selection = frame.document.getSelection();
    return selection.setBaseAndExtent(node, charnum, node, end, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextContent);
    pub const Meta = struct {
        pub const name = "SVGTextContentElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order: the attributes, then the constants, then the operations
    // alphabetically.
    pub const textLength = bridge.accessor(TextContent.getTextLength, null, .{});
    pub const lengthAdjust = bridge.accessor(TextContent.getLengthAdjust, null, .{});

    pub const LENGTHADJUST_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const LENGTHADJUST_SPACING = bridge.property(1, .{ .template = true });
    pub const LENGTHADJUST_SPACINGANDGLYPHS = bridge.property(2, .{ .template = true });

    pub const getCharNumAtPosition = bridge.function(TextContent.getCharNumAtPosition, .{});
    pub const getComputedTextLength = bridge.function(TextContent.getComputedTextLength, .{});
    pub const getEndPositionOfChar = bridge.function(TextContent.getEndPositionOfChar, .{});
    pub const getExtentOfChar = bridge.function(TextContent.getExtentOfChar, .{});
    pub const getNumberOfChars = bridge.function(TextContent.getNumberOfChars, .{});
    pub const getRotationOfChar = bridge.function(TextContent.getRotationOfChar, .{});
    pub const getStartPositionOfChar = bridge.function(TextContent.getStartPositionOfChar, .{});
    pub const getSubStringLength = bridge.function(TextContent.getSubStringLength, .{});
    pub const selectSubString = bridge.function(TextContent.selectSubString, .{});
};
