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
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const Angle = @import("../../svg/Angle.zig");
const AnimatedAngle = @import("../../svg/AnimatedAngle.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedPreserveAspectRatio = @import("../../svg/AnimatedPreserveAspectRatio.zig");
const AnimatedRect = @import("../../svg/AnimatedRect.zig");

const Svg = @import("../Svg.zig");

const Marker = @This();

pub const Proto = Svg;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *Svg else void = undefined,

pub fn asElement(self: *Marker) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Marker) *Node {
    return self.asElement().asNode();
}

fn getRefX(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_ref_x, frame);
}
fn getRefY(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_ref_y, frame);
}
fn getMarkerWidth(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_width, frame);
}
fn getMarkerHeight(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_height, frame);
}
fn getMarkerUnits(self: *Marker, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .marker_units, frame);
}
fn getOrientType(self: *Marker, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .marker_orient, frame);
}
fn getOrientAngle(self: *Marker, frame: *Frame) !*AnimatedAngle {
    return AnimatedAngle.getOrCreate(self.asElement(), frame);
}
fn getViewBox(self: *Marker, frame: *Frame) !*AnimatedRect {
    return AnimatedRect.getOrCreate(self.asElement(), frame);
}
fn getPreserveAspectRatio(self: *Marker, frame: *Frame) !*AnimatedPreserveAspectRatio {
    return AnimatedPreserveAspectRatio.getOrCreate(self.asElement(), frame);
}

// Measured on Chrome 150: setOrientToAngle() writes the angle's own
// serialization into the attribute (a fresh SVGAngle gives "0") and
// setOrientToAuto() writes the keyword.
fn setOrientToAngle(self: *Marker, angle: *Angle, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(
        comptime .wrap("orient"),
        .wrap(try angle.getValueAsString(frame)),
        frame,
    );
}
fn setOrientToAuto(self: *Marker, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("orient"), .wrap("auto"), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Marker);
    pub const Meta = struct {
        pub const name = "SVGMarkerElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    // Chrome's own member order: the attributes first, then the constants,
    // then the two operations.
    pub const refX = bridge.accessor(Marker.getRefX, null, .{});
    pub const refY = bridge.accessor(Marker.getRefY, null, .{});
    pub const markerUnits = bridge.accessor(Marker.getMarkerUnits, null, .{});
    pub const markerWidth = bridge.accessor(Marker.getMarkerWidth, null, .{});
    pub const markerHeight = bridge.accessor(Marker.getMarkerHeight, null, .{});
    pub const orientType = bridge.accessor(Marker.getOrientType, null, .{});
    pub const orientAngle = bridge.accessor(Marker.getOrientAngle, null, .{});
    pub const viewBox = bridge.accessor(Marker.getViewBox, null, .{});
    pub const preserveAspectRatio = bridge.accessor(Marker.getPreserveAspectRatio, null, .{});
    pub const SVG_MARKERUNITS_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_MARKERUNITS_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_MARKERUNITS_STROKEWIDTH = bridge.property(2, .{ .template = true });
    pub const SVG_MARKER_ORIENT_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_MARKER_ORIENT_AUTO = bridge.property(1, .{ .template = true });
    pub const SVG_MARKER_ORIENT_ANGLE = bridge.property(2, .{ .template = true });
    pub const setOrientToAngle = bridge.function(Marker.setOrientToAngle, .{});
    pub const setOrientToAuto = bridge.function(Marker.setOrientToAuto, .{});
};
