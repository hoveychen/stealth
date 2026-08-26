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
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");
// Not upstream's DOMRect: getBBox() answers the legacy SVGRect in Chrome (see
// tests/element/svg/matrix.html, which asserts SVGRect !== DOMRect), and
// getCTM()/getScreenCTM() answer SVGMatrix rather than DOMMatrix.
const SvgRect = @import("../../svg/Rect.zig");
const SvgPoint = @import("../../svg/Point.zig");
const SvgMatrix = @import("../../svg/Matrix.zig");
const SvgLength = @import("../../svg/Length.zig");
const PreserveAspectRatio = @import("../../svg/PreserveAspectRatio.zig");
const DOMMatrixReadOnly = @import("../../DOMMatrixReadOnly.zig");
const SvgElement = @import("../Svg.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");
const PathData = @import("../../svg/PathData.zig");
const StringList = @import("../../svg/StringList.zig");

pub const Svg = @import("Svg.zig");
pub const G = @import("G.zig");
pub const A = @import("A.zig");
pub const Use = @import("Use.zig");
pub const Image = @import("Image.zig");
pub const Defs = @import("Defs.zig");
pub const Symbol = @import("Symbol.zig");
pub const Switch = @import("Switch.zig");
pub const ForeignObject = @import("ForeignObject.zig");
pub const TextContent = @import("TextContent.zig");
pub const Geometry = @import("Geometry.zig");

const Graphics = @This();

pub const Proto = SvgElement;
_type: Type,
_proto_canary: if (lp.IS_DEBUG) *SvgElement else void = undefined,

pub const Type = enum(u8) {
    svg,
    g,
    a,
    use,
    image,
    defs,
    symbol,
    switch_element,
    foreign_object,
    text_content,
    geometry,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .svg => Svg,
        .g => G,
        .a => A,
        .use => Use,
        .image => Image,
        .defs => Defs,
        .symbol => Symbol,
        .switch_element => Switch,
        .foreign_object => ForeignObject,
        .text_content => TextContent,
        .geometry => Geometry,
    };
}

pub fn subtype(self: *const Graphics, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, Graphics);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *Graphics, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    if (self._type == .geometry) {
        return self.subtype(Geometry).is(T);
    }
    if (self._type == .text_content) {
        return self.subtype(TextContent).is(T);
    }
    return null;
}

pub fn asElement(self: *Graphics) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Graphics) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Graphics);

    pub const Meta = struct {
        pub const name = "SVGGraphicsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const transform = bridge.accessor(Graphics.getTransform, null, .{});
    pub const nearestViewportElement = bridge.accessor(Graphics.getNearestViewportElement, null, .{});
    pub const farthestViewportElement = bridge.accessor(Graphics.getFarthestViewportElement, null, .{});
    pub const requiredExtensions = bridge.accessor(Graphics.getRequiredExtensions, null, .{});
    pub const systemLanguage = bridge.accessor(Graphics.getSystemLanguage, null, .{});
    pub const getBBox = bridge.function(Graphics.getBBox, .{});
    pub const getCTM = bridge.function(Graphics.getCTM, .{});
    pub const getScreenCTM = bridge.function(Graphics.getScreenCTM, .{});
};

// The viewport-establishing elements, measured on Chrome 150 by asking a
// child for its nearestViewportElement: <marker>, <pattern>, <mask>,
// <clipPath>, <view>, <use> and <defs> all answer with the enclosing <svg>
// instead, so none of them establish one.
fn establishesViewport(element: *Element) bool {
    if (element._namespace != .svg) {
        return false;
    }
    const tag = element.getTagNameLower();
    return std.mem.eql(u8, tag, "svg") or
        std.mem.eql(u8, tag, "symbol") or
        std.mem.eql(u8, tag, "image") or
        std.mem.eql(u8, tag, "foreignObject");
}

pub fn getNearestViewportElement(self: *Graphics) ?*Element {
    var current = self.asElement().parentElement();
    while (current) |element| : (current = element.parentElement()) {
        if (establishesViewport(element)) {
            return element;
        }
    }
    return null;
}

pub fn getFarthestViewportElement(self: *Graphics) ?*Element {
    var farthest: ?*Element = null;
    var current = self.asElement().parentElement();
    while (current) |element| : (current = element.parentElement()) {
        if (establishesViewport(element)) {
            farthest = element;
        }
    }
    return farthest;
}

/// The transform from this element's user space to the coordinate system of
/// `nearestViewportElement`. Chrome hands back the identity rather than null
/// for an element that is not in a document.
pub fn getCTM(self: *Graphics, frame: *Frame) !*SvgMatrix {
    return SvgMatrix.create(self.currentTransform(true, frame), frame._page);
}

// getScreenCTM walks all the way out and then offsets by where the outermost
// <svg> sits on the page, so it is getCTM plus the root's client origin.
pub fn getScreenCTM(self: *Graphics, frame: *Frame) !*SvgMatrix {
    var value = self.currentTransform(false, frame);
    if (self.outermostSvg()) |root| {
        const rect = try root.getBoundingClientRect(frame);
        value.e += rect.getX();
        value.f += rect.getY();
    }
    return SvgMatrix.create(value, frame._page);
}

fn outermostSvg(self: *Graphics) ?*Element {
    var outermost: ?*Element = null;
    var current: ?*Element = self.asElement();
    while (current) |element| : (current = element.parentElement()) {
        if (element._namespace != .svg) {
            break;
        }
        if (std.mem.eql(u8, element.getTagNameLower(), "svg")) {
            outermost = element;
        }
    }
    return outermost;
}

// Accumulates the ancestor chain outwards. Each element contributes its
// `transform` attribute; a viewport-establishing one additionally contributes
// its own x/y placement and viewBox, and ends the walk when `stop_at_viewport`
// is set. The outermost <svg> is the exception: it contributes its viewBox
// but neither its placement nor its transform, which Chrome ignores there.
fn currentTransform(self: *Graphics, stop_at_viewport: bool, frame: *Frame) SvgMatrix.Value {
    var value: SvgMatrix.Value = .{};
    var current: ?*Element = self.asElement();
    var first = true;
    while (current) |element| : (current = element.parentElement()) {
        if (element._namespace != .svg) {
            break;
        }
        const viewport = establishesViewport(element);
        if (viewport) {
            value = SvgMatrix.multiplyValues(viewportTransform(element, frame), value);
        } else {
            value = SvgMatrix.multiplyValues(transformValue(element), value);
        }
        if (viewport and !first and stop_at_viewport) {
            break;
        }
        first = false;
    }
    return value;
}

// A nested viewport places itself with x/y and then rescales its children
// through viewBox; <symbol>, <image> and <foreignObject> have no viewBox of
// their own to apply here, and an outermost <svg> has nowhere to be placed.
fn viewportTransform(element: *Element, frame: *Frame) SvgMatrix.Value {
    const is_svg = std.mem.eql(u8, element.getTagNameLower(), "svg");
    if (!is_svg) {
        return .{};
    }

    const view_box = viewBoxTransform(element, frame);
    const graphics = element.as(SvgElement).is(Graphics) orelse return view_box;
    if (graphics.getNearestViewportElement() == null) {
        return view_box;
    }

    const placement = SvgMatrix.Value{
        .e = attributeLength(element, comptime .wrap("x"), .horizontal, frame),
        .f = attributeLength(element, comptime .wrap("y"), .vertical, frame),
    };
    return SvgMatrix.multiplyValues(
        SvgMatrix.multiplyValues(transformValue(element), placement),
        view_box,
    );
}

fn attributeLength(element: *Element, attr_name: lp.String, direction: SvgLength.Direction, frame: *Frame) f64 {
    const raw = element.getAttributeSafe(attr_name) orelse return 0;
    const parsed = SvgLength.parseValue(raw) catch return 0;
    if (parsed.unit == .percentage) {
        return SvgLength.viewportDimension(element, direction, frame) * parsed.value / 100.0;
    }
    return parsed.value;
}

fn viewBoxTransform(element: *Element, frame: *Frame) SvgMatrix.Value {
    const box = SvgRect.viewBoxOf(element) orelse return .{};
    if (box[2] <= 0 or box[3] <= 0) {
        return .{};
    }
    const width = SvgLength.viewportDimension(element, .horizontal, frame);
    const height = SvgLength.viewportDimension(element, .vertical, frame);

    var scale_x = width / box[2];
    var scale_y = height / box[3];
    const ratio = PreserveAspectRatio.valueOf(element);
    if (ratio.alignment != 1) {
        const uniform = if (ratio.meet_or_slice == 2)
            @max(scale_x, scale_y)
        else
            @min(scale_x, scale_y);
        scale_x = uniform;
        scale_y = uniform;
    }

    // xMinYMin is 2 and the nine aligned values run x-fastest, so the index
    // within the row is the horizontal anchor and the row is the vertical one.
    const anchor = if (ratio.alignment >= 2 and ratio.alignment <= 10) ratio.alignment - 2 else 4;
    const anchor_x: f64 = @as(f64, @floatFromInt(anchor % 3)) / 2.0;
    const anchor_y: f64 = @as(f64, @floatFromInt(anchor / 3)) / 2.0;

    return .{
        .a = scale_x,
        .d = scale_y,
        .e = -box[0] * scale_x + anchor_x * (width - box[2] * scale_x),
        .f = -box[1] * scale_y + anchor_y * (height - box[3] * scale_y),
    };
}

fn transformValue(element: *Element) SvgMatrix.Value {
    const matrix = transformMatrix(element);
    return .{
        .a = matrix.a,
        .b = matrix.b,
        .c = matrix.c,
        .d = matrix.d,
        .e = matrix.e,
        .f = matrix.f,
    };
}

// SVGBoundingBoxOptions is not modelled: Chrome declares no parameter at all
// and Firefox's flags degenerate to the fill geometry, so both engines answer
// every call with the fill box.
pub fn getBBox(self: *Graphics, frame: *Frame) !*SvgRect {
    const box = try self.bounds(frame);
    if (box.isEmpty()) {
        return SvgRect.create(.{}, frame._factory);
    }

    return SvgRect.create(.{
        .x = box.min_x,
        .y = box.min_y,
        .width = box.width(),
        .height = box.height(),
    }, frame._factory);
}

/// getBBox's answer before it is wrapped in an SVGRect, so the intersection and
/// enclosure lists can ask a whole subtree for its boxes without allocating one
/// per element.
pub fn bounds(self: *Graphics, frame: *Frame) !PathData.Bounds {
    var box: PathData.Bounds = .{};
    switch (self._type) {
        .geometry => {
            var path = try self.subtype(Geometry).buildPath(frame);
            defer path.deinit(frame.local_arena);
            box = path.bounds(.{});
        },
        .foreign_object => box = try self.subtype(ForeignObject).getBounds(frame),
        // Upstream leaves <text> boxless; we measure it, so the arm stays.
        .text_content => box = try self.subtype(TextContent).getBounds(frame),
        .g, .a, .svg => try accumulateChildren(self, .{}, &box, frame),
        .defs, .symbol, .switch_element, .use, .image => {},
    }
    return box;
}

fn accumulateChildren(parent: *Graphics, matrix: PathData.Matrix, into: *PathData.Bounds, frame: *Frame) !void {
    const Cursor = struct {
        next: ?*Node,
        matrix: PathData.Matrix,
    };
    var cursors: std.ArrayList(Cursor) = .empty;
    try cursors.append(frame.local_arena, .{
        .next = parent.asNode().firstChild(),
        .matrix = matrix,
    });

    while (cursors.items.len != 0) {
        const top = cursors.items.len - 1;
        const node = cursors.items[top].next orelse {
            _ = cursors.pop();
            continue;
        };
        cursors.items[top].next = node.nextSibling();
        const parent_matrix = cursors.items[top].matrix;

        const element = node.is(Element) orelse continue;
        if (element._namespace != .svg) continue;
        const svg = element.as(SvgElement);
        const graphics = svg.is(Graphics) orelse continue;
        const child_matrix = parent_matrix.multiply(transformMatrix(element));

        switch (graphics._type) {
            .geometry => {
                var path = try graphics.subtype(Geometry).buildPath(frame);
                defer path.deinit(frame.local_arena);
                into.merge(path.bounds(child_matrix));
            },
            // Upstream inlines the four-corner walk here; mergeBox is the same
            // code and <text> needs it too, so both arms go through the helper.
            .foreign_object => {
                try mergeBox(into, try graphics.subtype(ForeignObject).getBounds(frame), child_matrix, frame);
            },
            .text_content => {
                try mergeBox(into, try graphics.subtype(TextContent).getBounds(frame), child_matrix, frame);
            },
            .g, .a => try cursors.append(frame.local_arena, .{
                .next = graphics.asNode().firstChild(),
                .matrix = child_matrix,
            }),
            // <defs> and <symbol> never render. Nested viewports, <switch>,
            // <use> and <image> have geometry we cannot resolve yet, so they
            // contribute nothing rather than making the whole box
            // unavailable.
            .defs, .symbol, .svg, .switch_element, .use, .image => {},
        }
    }
}

/// Folds an axis-aligned child box into `into` under `matrix`, which can
/// rotate or skew it, so the box goes through the path machinery as four
/// corners rather than as a min/max pair.
fn mergeBox(into: *PathData.Bounds, box: PathData.Bounds, matrix: PathData.Matrix, frame: *Frame) !void {
    if (box.isEmpty()) {
        return;
    }
    var path: PathData.Path = .{};
    defer path.deinit(frame.local_arena);
    const top_left = PathData.Point{ .x = box.min_x, .y = box.min_y };
    const top_right = PathData.Point{ .x = box.max_x, .y = box.min_y };
    const bottom_right = PathData.Point{ .x = box.max_x, .y = box.max_y };
    const bottom_left = PathData.Point{ .x = box.min_x, .y = box.max_y };
    try path.appendLine(top_left, top_right, frame.local_arena);
    try path.appendLine(top_right, bottom_right, frame.local_arena);
    try path.appendLine(bottom_right, bottom_left, frame.local_arena);
    try path.appendLine(bottom_left, top_left, frame.local_arena);
    into.merge(path.bounds(matrix));
}

fn transformMatrix(element: *Element) PathData.Matrix {
    const raw = element.getAttributeSafe(comptime .wrap("transform")) orelse return .{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) {
        return .{};
    }

    var matrix = DOMMatrixReadOnly.identity();
    var iterator = DOMMatrixReadOnly.TransformFunctionIterator{ .input = trimmed, .allow_comma = true };
    while (iterator.next() catch return .{}) |function| {
        const parsed = DOMMatrixReadOnly.parseTransformFunction(function, .svg) catch return .{};
        matrix = DOMMatrixReadOnly.multiplyMatrix(matrix, parsed.matrix);
    }
    return .{
        .a = matrix[0],
        .b = matrix[1],
        .c = matrix[4],
        .d = matrix[5],
        .e = matrix[12],
        .f = matrix[13],
    };
}

pub fn getTransform(self: *Graphics, frame: *Frame) !*AnimatedTransformList {
    return AnimatedTransformList.getOrCreate(self.asElement(), .transform, frame);
}

pub fn getRequiredExtensions(self: *Graphics, frame: *Frame) !*StringList {
    return StringList.getOrCreate(self.asElement(), .required_extensions, frame);
}

pub fn getSystemLanguage(self: *Graphics, frame: *Frame) !*StringList {
    return StringList.getOrCreate(self.asElement(), .system_language, frame);
}
