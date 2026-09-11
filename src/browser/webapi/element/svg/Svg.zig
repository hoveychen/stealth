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

const lp = @import("lightpanda");
const std = @import("std");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TreeWalker = @import("../../TreeWalker.zig");
const SelectorList = @import("../../selector/List.zig");
const SvgElement = @import("../Svg.zig");
const PathData = @import("../../svg/PathData.zig");
const ZoomAndPan = @import("zoom_and_pan.zig");
const SvgRect = @import("../../svg/Rect.zig");
const SvgPoint = @import("../../svg/Point.zig");
const SvgMatrix = @import("../../svg/Matrix.zig");
const SvgNumber = @import("../../svg/Number.zig");
const SvgLength = @import("../../svg/Length.zig");
const SvgAngle = @import("../../svg/Angle.zig");
const SvgTransform = @import("../../svg/Transform.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedPreserveAspectRatio = @import("../../svg/AnimatedPreserveAspectRatio.zig");
const AnimatedRect = @import("../../svg/AnimatedRect.zig");

const Graphics = @import("Graphics.zig");

const Svg = @This();

pub const Proto = Graphics;

// The four pieces of SVGSVGElement state that live on the element rather than
// in an attribute: the zoom and pan the user agent applies, the SMIL clock, and
// whether it is running.
_current_scale: f64 = 1,
_current_translate: [2]f64 = .{ 0, 0 },
_current_time: f64 = 0,
_animations_paused: bool = false,
_zoom_and_pan: ZoomAndPan.State = .{},
_proto_canary: if (lp.IS_DEBUG) *Graphics else void = undefined,

pub fn asElement(self: *Svg) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Svg) *Node {
    return self.asElement().asNode();
}
fn asGraphics(self: *Svg) *Graphics {
    return Factory.protoOf(self);
}

pub fn getElementById(self: *Svg, id: []const u8) ?*Element {
    if (id.len == 0) {
        return null;
    }

    var tw = TreeWalker.Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        const element_id = el.getId() orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub fn getX(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .x, frame);
}

pub fn getY(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .y, frame);
}

pub fn getWidth(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .svg_width, frame);
}

pub fn getHeight(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .svg_height, frame);
}

pub fn getViewBox(self: *Svg, frame: *Frame) !*AnimatedRect {
    return AnimatedRect.getOrCreate(self.asElement(), frame);
}

pub fn getPreserveAspectRatio(self: *Svg, frame: *Frame) !*AnimatedPreserveAspectRatio {
    return AnimatedPreserveAspectRatio.getOrCreate(self.asElement(), frame);
}

pub fn createSVGPoint(_: *Svg, frame: *Frame) !*SvgPoint {
    return SvgPoint.create(0, 0, frame._page);
}

pub fn createSVGMatrix(_: *Svg, frame: *Frame) !*SvgMatrix {
    return SvgMatrix.create(.{}, frame._page);
}

pub fn createSVGRect(_: *Svg, frame: *Frame) !*SvgRect {
    return SvgRect.create(.{}, frame._factory);
}

pub fn createSVGNumber(_: *Svg, frame: *Frame) !*SvgNumber {
    return SvgNumber.detached(frame);
}

pub fn createSVGLength(_: *Svg, frame: *Frame) !*SvgLength {
    return SvgLength.detached(frame);
}

pub fn createSVGAngle(_: *Svg, frame: *Frame) !*SvgAngle {
    return SvgAngle.detached(frame);
}

pub fn createSVGTransform(_: *Svg, frame: *Frame) !*SvgTransform {
    return SvgTransform.detached(frame);
}

pub fn createSVGTransformFromMatrix(_: *Svg, matrix: *const SvgMatrix, frame: *Frame) !*SvgTransform {
    return SvgTransform.fromMatrix(matrix, frame);
}

/// The zoom the user agent applies, which only the outermost `<svg>` carries: a
/// nested one reads 1 and ignores a write. Chrome takes any finite number here,
/// including 0 and negatives (measured on Chrome 151).
pub fn getCurrentScale(self: *Svg) f64 {
    if (self.asGraphics().getNearestViewportElement() != null) {
        return 1;
    }
    return self._current_scale;
}

pub fn setCurrentScale(self: *Svg, value: f64) void {
    if (self.asGraphics().getNearestViewportElement() != null) {
        return;
    }
    self._current_scale = value;
}

/// A fresh SVGPoint every read -- `svg.currentTranslate === svg.currentTranslate`
/// is false in Chrome -- but one that writes through to the element, so
/// assigning to its `x` and reading it back on the *next* point still answers
/// what was written. Blink calls this a tear-off; the Point's attachment hook is
/// the same mechanism a reflected point list uses.
pub fn getCurrentTranslate(self: *Svg, frame: *Frame) !*SvgPoint {
    const point = try SvgPoint.create(self._current_translate[0], self._current_translate[1], frame._page);
    point.attach(.{ .owner = self, .mutate = mutateTranslate }, false);
    return point;
}

fn mutateTranslate(owner: *anyopaque, point: *SvgPoint, coordinate: SvgPoint.Coordinate, value: f64) anyerror!void {
    const self: *Svg = @ptrCast(@alignCast(owner));
    self._current_translate[@intFromEnum(coordinate)] = value;
    point.setCoordinateRaw(coordinate, value);
}

fn getZoomAndPan(self: *Svg) u16 {
    return self._zoom_and_pan.get(self.asElement());
}
fn setZoomAndPan(self: *Svg, value: u16) void {
    self._zoom_and_pan.set(self.asElement(), value);
}

pub fn animationsPaused(self: *Svg) bool {
    return self._animations_paused;
}

pub fn pauseAnimations(self: *Svg) void {
    self._animations_paused = true;
}

pub fn unpauseAnimations(self: *Svg) void {
    self._animations_paused = false;
}

/// The SMIL clock. Nothing advances it: Chrome answers 0 on a document that has
/// been open for minutes with no animation in it, and `setCurrentTime` is the
/// only thing that moves the number either engine reports.
pub fn getCurrentTime(self: *Svg) f64 {
    return self._current_time;
}

pub fn setCurrentTime(self: *Svg, seconds: f64) void {
    if (std.math.isNan(seconds)) {
        return;
    }
    self._current_time = seconds;
}

/// The redraw-suspension trio, kept for their shape. Chrome hands back 1 from
/// every `suspendRedraw` -- not an incrementing handle -- and does nothing
/// observable with the id afterwards, which is what these do.
pub fn suspendRedraw(_: *Svg, _: u32) u32 {
    return 1;
}

pub fn unsuspendRedraw(_: *Svg, _: u32) void {}

pub fn unsuspendRedrawAll(_: *Svg) void {}

pub fn forceRedraw(_: *Svg) void {}

pub fn deselectAll(_: *Svg, frame: *Frame) !void {
    return frame.document.getSelection().removeAllRanges(frame);
}

/// Whether `element`'s bounding box meets `rect`, both in the element's own user
/// space. Chrome tests the rendered geometry rather than the box, so a shape
/// whose box overlaps but whose ink does not is where the two would part; every
/// reading taken for this batch agrees.
pub fn checkIntersection(_: *Svg, element: *SvgElement, rect: *SvgRect, frame: *Frame) !bool {
    const graphics = element.is(Graphics) orelse return false;
    return meets(try graphics.bounds(frame), rect, false);
}

pub fn checkEnclosure(_: *Svg, element: *SvgElement, rect: *SvgRect, frame: *Frame) !bool {
    const graphics = element.is(Graphics) orelse return false;
    return meets(try graphics.bounds(frame), rect, true);
}

fn meets(box: PathData.Bounds, rect: *SvgRect, enclosed: bool) bool {
    // An empty query rect meets nothing, which is Blink's rule for both
    // gfx::RectF::Intersects and ::Contains: `getIntersectionList` over a fresh
    // `createSVGRect()` comes back with length 0 even on a document full of
    // shapes sitting at the origin. The *element's* box is not held to the same
    // rule below -- Chrome does list a `<image>` with no width or height.
    if (rect.getWidth() <= 0 or rect.getHeight() <= 0) {
        return false;
    }

    const min_x = rect.getX();
    const min_y = rect.getY();
    const max_x = min_x + rect.getWidth();
    const max_y = min_y + rect.getHeight();

    // An empty box is a point at the origin, and Chrome does count a zero-sized
    // `<image>` sitting inside the rect as both intersecting and enclosed.
    const box_min_x = if (box.isEmpty()) 0 else box.min_x;
    const box_min_y = if (box.isEmpty()) 0 else box.min_y;
    const box_max_x = if (box.isEmpty()) 0 else box.max_x;
    const box_max_y = if (box.isEmpty()) 0 else box.max_y;

    if (enclosed) {
        return box_min_x >= min_x and box_max_x <= max_x and
            box_min_y >= min_y and box_max_y <= max_y;
    }
    return box_min_x <= max_x and box_max_x >= min_x and
        box_min_y <= max_y and box_max_y >= min_y;
}

/// Every rendered descendant whose box meets `rect`, in document order, as a
/// static NodeList. `reference` scopes the walk to its own subtree; Chrome
/// excludes the reference itself, and lists only the elements that draw --
/// shapes, text, images and foreign objects -- so the `<a>` and `<g>` wrappers
/// around them never appear.
pub fn getIntersectionList(self: *Svg, rect: *SvgRect, reference: ?*SvgElement, frame: *Frame) !*SelectorList {
    return self.collectMeeting(rect, reference, false, frame);
}

pub fn getEnclosureList(self: *Svg, rect: *SvgRect, reference: ?*SvgElement, frame: *Frame) !*SelectorList {
    return self.collectMeeting(rect, reference, true, frame);
}

fn collectMeeting(self: *Svg, rect: *SvgRect, reference: ?*SvgElement, enclosed: bool, frame: *Frame) !*SelectorList {
    const root: *Node = if (reference) |element| element.asElement().asNode() else self.asNode();

    const arena = try frame.getArena(.small, "SVGSVGElement.getIntersectionList");
    errdefer arena.release();

    var found: std.ArrayList(*Node) = .empty;
    var tw = TreeWalker.Full.Elements.init(root, .{});
    _ = tw.next(); // the root itself is never a candidate
    while (tw.next()) |el| {
        if (el._namespace != .svg) continue;
        const graphics = el.as(SvgElement).is(Graphics) orelse continue;
        switch (graphics._type) {
            .geometry, .text_content, .image, .foreign_object => {},
            .svg, .g, .a, .use, .defs, .symbol, .switch_element => continue,
        }
        if (meets(try graphics.bounds(frame), rect, enclosed)) {
            try found.append(arena.allocator(), el.asNode());
        }
    }

    const list = try arena.create(SelectorList);
    list.* = .{ ._arena = arena, ._nodes = found.items };
    return list;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Svg);

    pub const Meta = struct {
        pub const name = "SVGSVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order: the attributes in IDL order, then the SVGZoomAndPan
    // constants, then every operation alphabetically.
    pub const x = bridge.accessor(Svg.getX, null, .{});
    pub const y = bridge.accessor(Svg.getY, null, .{});
    pub const width = bridge.accessor(Svg.getWidth, null, .{});
    pub const height = bridge.accessor(Svg.getHeight, null, .{});
    pub const currentScale = bridge.accessor(Svg.getCurrentScale, Svg.setCurrentScale, .{});
    pub const currentTranslate = bridge.accessor(Svg.getCurrentTranslate, null, .{});
    pub const viewBox = bridge.accessor(Svg.getViewBox, null, .{});
    pub const preserveAspectRatio = bridge.accessor(Svg.getPreserveAspectRatio, null, .{});
    pub const zoomAndPan = bridge.accessor(Svg.getZoomAndPan, Svg.setZoomAndPan, .{});

    pub const SVG_ZOOMANDPAN_UNKNOWN = bridge.property(ZoomAndPan.unknown, .{ .template = true });
    pub const SVG_ZOOMANDPAN_DISABLE = bridge.property(ZoomAndPan.disable, .{ .template = true });
    pub const SVG_ZOOMANDPAN_MAGNIFY = bridge.property(ZoomAndPan.magnify, .{ .template = true });

    pub const animationsPaused = bridge.function(Svg.animationsPaused, .{});
    pub const checkEnclosure = bridge.function(Svg.checkEnclosure, .{});
    pub const checkIntersection = bridge.function(Svg.checkIntersection, .{});
    pub const createSVGAngle = bridge.function(Svg.createSVGAngle, .{});
    pub const createSVGLength = bridge.function(Svg.createSVGLength, .{});
    pub const createSVGMatrix = bridge.function(Svg.createSVGMatrix, .{});
    pub const createSVGNumber = bridge.function(Svg.createSVGNumber, .{});
    pub const createSVGPoint = bridge.function(Svg.createSVGPoint, .{});
    pub const createSVGRect = bridge.function(Svg.createSVGRect, .{});
    pub const createSVGTransform = bridge.function(Svg.createSVGTransform, .{});
    pub const createSVGTransformFromMatrix = bridge.function(Svg.createSVGTransformFromMatrix, .{});
    pub const deselectAll = bridge.function(Svg.deselectAll, .{});
    pub const forceRedraw = bridge.function(Svg.forceRedraw, .{});
    pub const getCurrentTime = bridge.function(Svg.getCurrentTime, .{});
    pub const getElementById = bridge.function(Svg.getElementById, .{});
    // The reference element is nullable, which stops the derived arity at 1;
    // Chrome reports 2 for both.
    pub const getEnclosureList = bridge.function(Svg.getEnclosureList, .{ .arity = 2 });
    pub const getIntersectionList = bridge.function(Svg.getIntersectionList, .{ .arity = 2 });
    pub const pauseAnimations = bridge.function(Svg.pauseAnimations, .{});
    pub const setCurrentTime = bridge.function(Svg.setCurrentTime, .{});
    pub const suspendRedraw = bridge.function(Svg.suspendRedraw, .{});
    pub const unpauseAnimations = bridge.function(Svg.unpauseAnimations, .{});
    pub const unsuspendRedraw = bridge.function(Svg.unsuspendRedraw, .{});
    pub const unsuspendRedrawAll = bridge.function(Svg.unsuspendRedrawAll, .{});
};
