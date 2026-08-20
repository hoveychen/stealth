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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const Factory = @import("../../Factory.zig");
const AnimatedString = @import("../svg/AnimatedString.zig");
pub const Generic = @import("svg/Generic.zig");
pub const Graphics = @import("svg/Graphics.zig");
pub const View = @import("svg/View.zig");
pub const Title = @import("svg/Title.zig");
pub const Desc = @import("svg/Desc.zig");
pub const Metadata = @import("svg/Metadata.zig");
pub const GradientElement = @import("svg/GradientElement.zig");
pub const ClipPath = @import("svg/ClipPath.zig");
pub const Marker = @import("svg/Marker.zig");
pub const Mask = @import("svg/Mask.zig");
pub const Pattern = @import("svg/Pattern.zig");
pub const Stop = @import("svg/Stop.zig");
pub const filter = @import("svg/filter.zig");
pub const animation = @import("svg/animation.zig");
pub const Script = @import("svg/Script.zig");
pub const Style = @import("svg/Style.zig");

const String = lp.String;

const Svg = @This();

pub const Proto = Element;
_type: Type,
_tag_name: String, // Svg elements are case-preserving
_proto_canary: if (lp.IS_DEBUG) *Element else void = undefined,

pub const Type = enum(u8) {
    graphics,
    view,
    title,
    desc,
    metadata,
    gradient,
    clip_path,
    marker,
    mask,
    pattern,
    stop,
    // <filter> and its primitives. Each primitive derives straight from
    // SVGElement in Chrome, so each is its own variant rather than a nested
    // union under a shared base that does not exist.
    filter,
    component_transfer_function,
    fe_blend,
    fe_color_matrix,
    fe_convolve_matrix,
    fe_turbulence,
    fe_component_transfer,
    fe_composite,
    fe_diffuse_lighting,
    fe_displacement_map,
    fe_distant_light,
    fe_drop_shadow,
    fe_flood,
    fe_gaussian_blur,
    fe_image,
    fe_merge,
    fe_merge_node,
    fe_morphology,
    fe_offset,
    fe_point_light,
    fe_specular_lighting,
    fe_spot_light,
    fe_tile,
    // The SMIL elements. <animate>, <animateMotion>, <animateTransform> and
    // <set> share SVGAnimationElement; <mpath>, <script> and <style> each
    // derive straight from SVGElement.
    animation,
    mpath,
    script,
    style,
    generic,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .graphics => Graphics,
        .view => View,
        .title => Title,
        .desc => Desc,
        .metadata => Metadata,
        .gradient => GradientElement,
        .clip_path => ClipPath,
        .marker => Marker,
        .mask => Mask,
        .pattern => Pattern,
        .stop => Stop,
        .filter => filter.Filter,
        .component_transfer_function => filter.ComponentTransferFunction,
        .fe_blend => filter.FEBlend,
        .fe_color_matrix => filter.FEColorMatrix,
        .fe_convolve_matrix => filter.FEConvolveMatrix,
        .fe_turbulence => filter.FETurbulence,
        .fe_component_transfer => filter.FEComponentTransfer,
        .fe_composite => filter.FEComposite,
        .fe_diffuse_lighting => filter.FEDiffuseLighting,
        .fe_displacement_map => filter.FEDisplacementMap,
        .fe_distant_light => filter.FEDistantLight,
        .fe_drop_shadow => filter.FEDropShadow,
        .fe_flood => filter.FEFlood,
        .fe_gaussian_blur => filter.FEGaussianBlur,
        .fe_image => filter.FEImage,
        .fe_merge => filter.FEMerge,
        .fe_merge_node => filter.FEMergeNode,
        .fe_morphology => filter.FEMorphology,
        .fe_offset => filter.FEOffset,
        .fe_point_light => filter.FEPointLight,
        .fe_specular_lighting => filter.FESpecularLighting,
        .fe_spot_light => filter.FESpotLight,
        .fe_tile => filter.FETile,
        .animation => animation.Animation,
        .mpath => animation.MPath,
        .script => Script,
        .style => Style,
        .generic => Generic,
    };
}

pub fn subtype(self: *const Svg, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, Svg);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *Svg, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    if (self._type == .graphics) {
        return self.subtype(Graphics).is(T);
    }
    if (self._type == .gradient) {
        return self.subtype(GradientElement).is(T);
    }
    if (self._type == .component_transfer_function) {
        return self.subtype(filter.ComponentTransferFunction).is(T);
    }
    if (self._type == .animation) {
        return self.subtype(animation.Animation).is(T);
    }
    return null;
}

pub fn getTag(self: *const Svg) Element.Tag {
    return switch (self._type) {
        .graphics => blk: {
            const g = self.subtype(Graphics);
            break :blk switch (g._type) {
                .svg => .svg,
                .g => .g,
                // No dedicated Element.Tag values; tag-name matching falls back
                // to _tag_name, like it does for generic SVG elements.
                .a, .use, .image, .defs, .symbol, .switch_element, .foreign_object => .unknown,
                .text_content => tc: {
                    const content = g.subtype(Graphics.TextContent);
                    break :tc switch (content._type) {
                        .positioning => switch (content.subtype(Graphics.TextContent.TextPositioning)._type) {
                            .text => .text,
                            .tspan => .unknown,
                        },
                        .text_path => .unknown,
                    };
                },
                .geometry => switch (g.subtype(Graphics.Geometry)._type) {
                    .rect => .rect,
                    .circle => .circle,
                    .ellipse => .ellipse,
                    .line => .line,
                    .path => .path,
                    .polygon => .polygon,
                    .polyline => .polyline,
                },
            };
        },
        .generic => self.subtype(Generic)._tag,
        .title => .title,
        .view,
        .desc,
        .metadata,
        .gradient,
        .clip_path,
        .marker,
        .mask,
        .pattern,
        .stop,
        .filter,
        .component_transfer_function,
        .fe_blend,
        .fe_color_matrix,
        .fe_convolve_matrix,
        .fe_turbulence,
        .fe_component_transfer,
        .fe_composite,
        .fe_diffuse_lighting,
        .fe_displacement_map,
        .fe_distant_light,
        .fe_drop_shadow,
        .fe_flood,
        .fe_gaussian_blur,
        .fe_image,
        .fe_merge,
        .fe_merge_node,
        .fe_morphology,
        .fe_offset,
        .fe_point_light,
        .fe_specular_lighting,
        .fe_spot_light,
        .fe_tile,
        .animation,
        .mpath,
        .script,
        .style,
        => .unknown,
    };
}

pub fn asElement(self: *Svg) *Element {
    return Factory.protoOf(self);
}
pub fn asNode(self: *Svg) *Node {
    return self.asElement().asNode();
}

// The nearest ancestor <svg> element, null when this is the outermost svg.
pub fn getOwnerSvgElement(self: *Svg) ?*Graphics.Svg {
    var node = self.asNode().parentNode();
    while (node) |n| : (node = n.parentNode()) {
        const element = n.is(Element) orelse return null;
        if (element._namespace != .svg) {
            return null;
        }
        const svg = element.as(Svg);
        if (svg.is(Graphics.Svg)) |gfx_svg| {
            return gfx_svg;
        }
        if (svg._tag_name.eql(.wrap("foreignObject"))) {
            return null;
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Svg);

    pub const Meta = struct {
        pub const name = "SVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    //  Overrides el.className to return a readonly AnimatedString
    pub const className = bridge.accessor(_className, null, .{});
    fn _className(self: *Svg, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .class, frame);
    }

    pub const ownerSVGElement = bridge.accessor(Svg.getOwnerSvgElement, null, .{});
    // closest thing we can provide
    pub const viewportElement = bridge.accessor(Svg.getOwnerSvgElement, null, .{});

    // Chrome declares `style` and `attributeStyleMap` on SVGElement.prototype
    // as well as on HTMLElement.prototype -- neither is on Element.prototype.
    // Without them a Vue-style `element.style[prop] = value` on an SVG node
    // throws, which is enough to take a whole page's render down.
    pub const style = bridge.accessor(_style, _setStyle, .{});
    fn _style(self: *Svg, frame: *Frame) !*@import("../css/CSSStyleDeclaration.zig") {
        return self.asElement().getOrCreateStyle(frame);
    }
    fn _setStyle(self: *Svg, value: []const u8, frame: *Frame) !void {
        return self.asElement().setStyle(value, frame);
    }

    pub const attributeStyleMap = bridge.accessor(_attributeStyleMap, null, .{});
    fn _attributeStyleMap(self: *Svg, frame: *Frame) !*@import("../css/typed_om.zig").StylePropertyMap {
        const declaration = try self.asElement().getOrCreateStyle(frame);
        return declaration.getPropertyMap(frame);
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: Svg" {
    try testing.htmlRunner("element/svg", .{});
}
