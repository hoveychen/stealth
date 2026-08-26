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
const AnimatedPreserveAspectRatio = @import("../../svg/AnimatedPreserveAspectRatio.zig");
const AnimatedRect = @import("../../svg/AnimatedRect.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const Svg = @import("../Svg.zig");
const ZoomAndPan = @import("zoom_and_pan.zig");

const View = @This();

pub const Proto = Svg;
_zoom_and_pan: ZoomAndPan.State = .{},
_proto_canary: if (lp.IS_DEBUG) *Svg else void = undefined,

pub fn asElement(self: *View) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *View) *Node {
    return self.asElement().asNode();
}

fn getViewBox(self: *View, frame: *Frame) !*AnimatedRect {
    return AnimatedRect.getOrCreate(self.asElement(), frame);
}
fn getPreserveAspectRatio(self: *View, frame: *Frame) !*AnimatedPreserveAspectRatio {
    return AnimatedPreserveAspectRatio.getOrCreate(self.asElement(), frame);
}

fn getZoomAndPan(self: *View) u16 {
    return self._zoom_and_pan.get(self.asElement());
}
fn setZoomAndPan(self: *View, value: u16) void {
    self._zoom_and_pan.set(self.asElement(), value);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(View);
    pub const Meta = struct {
        pub const name = "SVGViewElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const viewBox = bridge.accessor(View.getViewBox, null, .{});
    pub const preserveAspectRatio = bridge.accessor(View.getPreserveAspectRatio, null, .{});

    // The SVGZoomAndPan mixin, which `<view>` includes alongside `<svg>`.
    pub const zoomAndPan = bridge.accessor(View.getZoomAndPan, View.setZoomAndPan, .{});
    pub const SVG_ZOOMANDPAN_UNKNOWN = bridge.property(ZoomAndPan.unknown, .{ .template = true });
    pub const SVG_ZOOMANDPAN_DISABLE = bridge.property(ZoomAndPan.disable, .{ .template = true });
    pub const SVG_ZOOMANDPAN_MAGNIFY = bridge.property(ZoomAndPan.magnify, .{ .template = true });
};
