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
const DOMStringMap = @import("DOMStringMap.zig");
const DOMTokenList = @import("../collections.zig").DOMTokenList;
const CSSStyleDeclaration = @import("../css/CSSStyleDeclaration.zig");
const StylePropertyMap = @import("../css/typed_om.zig").StylePropertyMap;
const global_event_handlers = @import("../global_event_handlers.zig");
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
        // Chrome's `constructor` sits between focusGroupStart and
        // onpointerrawupdate, exactly as it does on MathMLElement -- the two
        // interfaces carry the identical 113-name tail (measured).
        pub const constructor_after = "focusGroupStart";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    //  Overrides el.className to return a readonly AnimatedString
    fn _className(self: *Svg, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .class, frame);
    }

    // The HTMLOrSVGElement / GlobalEventHandlers pile. SVGElement carries the
    // same 110 members MathMLElement does, in the same order, so these mirror
    // element/MathML.zig's -- the on* handlers have no dedicated storage and
    // ride the same attribute-listener store every other element handler uses.
    fn handler(comptime which: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *Svg, frame: *Frame) !?js.Function.Global {
                return self.asElement().getAttributeFunction(which, frame);
            }
            pub fn set(self: *Svg, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.asElement().setAttributeListener(which, callback, frame);
            }
        };
    }

    fn _dataset(self: *Svg, frame: *Frame) !*DOMStringMap {
        return self.asElement().getDataset(frame);
    }
    // Chrome declares `style` and `attributeStyleMap` on SVGElement.prototype
    // as well as on HTMLElement.prototype -- neither is on Element.prototype.
    // Without them a Vue-style `element.style[prop] = value` on an SVG node
    // throws, which is enough to take a whole page's render down.
    fn _style(self: *Svg, frame: *Frame) !*CSSStyleDeclaration {
        return self.asElement().getOrCreateStyle(frame);
    }
    fn _setStyle(self: *Svg, value: []const u8, frame: *Frame) !void {
        return self.asElement().setStyle(value, frame);
    }
    fn _attributeStyleMap(self: *Svg, frame: *Frame) !*StylePropertyMap {
        const declaration = try self.asElement().getOrCreateStyle(frame);
        return declaration.getPropertyMap(frame);
    }
    // A slot, not the content attribute -- see Element.getNonce.
    fn _nonce(self: *Svg, frame: *Frame) []const u8 {
        return self.asElement().getNonce(frame);
    }
    fn _setNonce(self: *Svg, value: []const u8, frame: *Frame) !void {
        return self.asElement().setNonce(value, frame);
    }
    fn _autofocus(self: *Svg) bool {
        return self.asElement().getAttributeSafe(comptime .wrap("autofocus")) != null;
    }
    fn _setAutofocus(self: *Svg, value: bool, frame: *Frame) !void {
        const element = self.asElement();
        if (value) {
            return element.setAttributeSafe(comptime .wrap("autofocus"), .wrap(""), frame);
        }
        return element.removeAttribute(comptime .wrap("autofocus"), frame);
    }
    /// -1 unless the attribute says otherwise, with one exception: `<a>` is
    /// the only SVG tag focusable by default, and unlike HTML's it does not
    /// need an href to be (measured -- svg, rect, g, text, foreignObject, use
    /// and image all answer -1; `<a>` answers 0 with and without one).
    fn _tabIndex(self: *Svg) i32 {
        const default: i32 = if (self.is(Graphics.A) != null) 0 else -1;
        const attribute = self.asElement().getAttributeSafe(comptime .wrap("tabindex")) orelse return default;
        return std.fmt.parseInt(i32, std.mem.trim(u8, attribute, &std.ascii.whitespace), 10) catch default;
    }
    fn _setTabIndex(self: *Svg, value: i32, frame: *Frame) !void {
        var buf: [12]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        return self.asElement().setAttributeSafe(comptime .wrap("tabindex"), .wrap(str), frame);
    }
    fn _focus(self: *Svg, frame: *Frame) !void {
        return self.asElement().focus(frame);
    }
    fn _blur(self: *Svg, frame: *Frame) !void {
        return self.asElement().blur(frame);
    }
    // A DOMTokenList over the focusgroup attribute, exactly as HTMLElement
    // has it -- measured: `rect.focusGroup.constructor.name` is DOMTokenList
    // on all three element families, and the same object comes back twice.
    fn _focusGroup(self: *Svg, frame: *Frame) !*DOMTokenList {
        return self.asElement().getTokenList(.focusgroup, frame);
    }
    fn _setFocusGroup(self: *Svg, value: []const u8, frame: *Frame) !void {
        return self.asElement().setAttributeSafe(comptime .wrap("focusgroup"), .wrap(value), frame);
    }
    fn _focusGroupStart(_: *Svg) bool {
        return false;
    }
    fn _setFocusGroupStart(_: *Svg, _: ?js.Value) void {}

    // Chrome's own prototype order (measured).
    pub const className = bridge.accessor(_className, null, .{});
    pub const ownerSVGElement = bridge.accessor(Svg.getOwnerSvgElement, null, .{});
    // closest thing we can provide
    pub const viewportElement = bridge.accessor(Svg.getOwnerSvgElement, null, .{});
    pub const onabort = bridge.accessor(handler(.onabort).get, handler(.onabort).set, .{});
    pub const onbeforeinput = bridge.accessor(handler(.onbeforeinput).get, handler(.onbeforeinput).set, .{});
    pub const onbeforematch = bridge.accessor(handler(.onbeforematch).get, handler(.onbeforematch).set, .{});
    pub const onbeforetoggle = bridge.accessor(handler(.onbeforetoggle).get, handler(.onbeforetoggle).set, .{});
    pub const onblur = bridge.accessor(handler(.onblur).get, handler(.onblur).set, .{});
    pub const oncancel = bridge.accessor(handler(.oncancel).get, handler(.oncancel).set, .{});
    pub const oncanplay = bridge.accessor(handler(.oncanplay).get, handler(.oncanplay).set, .{});
    pub const oncanplaythrough = bridge.accessor(handler(.oncanplaythrough).get, handler(.oncanplaythrough).set, .{});
    pub const onchange = bridge.accessor(handler(.onchange).get, handler(.onchange).set, .{});
    pub const onclick = bridge.accessor(handler(.onclick).get, handler(.onclick).set, .{});
    pub const onclose = bridge.accessor(handler(.onclose).get, handler(.onclose).set, .{});
    pub const oncommand = bridge.accessor(handler(.oncommand).get, handler(.oncommand).set, .{});
    pub const oncontentvisibilityautostatechange = bridge.accessor(handler(.oncontentvisibilityautostatechange).get, handler(.oncontentvisibilityautostatechange).set, .{});
    pub const oncontextlost = bridge.accessor(handler(.oncontextlost).get, handler(.oncontextlost).set, .{});
    pub const oncontextmenu = bridge.accessor(handler(.oncontextmenu).get, handler(.oncontextmenu).set, .{});
    pub const oncontextrestored = bridge.accessor(handler(.oncontextrestored).get, handler(.oncontextrestored).set, .{});
    pub const oncuechange = bridge.accessor(handler(.oncuechange).get, handler(.oncuechange).set, .{});
    pub const ondblclick = bridge.accessor(handler(.ondblclick).get, handler(.ondblclick).set, .{});
    pub const ondrag = bridge.accessor(handler(.ondrag).get, handler(.ondrag).set, .{});
    pub const ondragend = bridge.accessor(handler(.ondragend).get, handler(.ondragend).set, .{});
    pub const ondragenter = bridge.accessor(handler(.ondragenter).get, handler(.ondragenter).set, .{});
    pub const ondragleave = bridge.accessor(handler(.ondragleave).get, handler(.ondragleave).set, .{});
    pub const ondragover = bridge.accessor(handler(.ondragover).get, handler(.ondragover).set, .{});
    pub const ondragstart = bridge.accessor(handler(.ondragstart).get, handler(.ondragstart).set, .{});
    pub const ondrop = bridge.accessor(handler(.ondrop).get, handler(.ondrop).set, .{});
    pub const ondurationchange = bridge.accessor(handler(.ondurationchange).get, handler(.ondurationchange).set, .{});
    pub const onemptied = bridge.accessor(handler(.onemptied).get, handler(.onemptied).set, .{});
    pub const onended = bridge.accessor(handler(.onended).get, handler(.onended).set, .{});
    pub const onerror = bridge.accessor(handler(.onerror).get, handler(.onerror).set, .{});
    pub const onfocus = bridge.accessor(handler(.onfocus).get, handler(.onfocus).set, .{});
    pub const onformdata = bridge.accessor(handler(.onformdata).get, handler(.onformdata).set, .{});
    pub const oninput = bridge.accessor(handler(.oninput).get, handler(.oninput).set, .{});
    pub const oninvalid = bridge.accessor(handler(.oninvalid).get, handler(.oninvalid).set, .{});
    pub const onkeydown = bridge.accessor(handler(.onkeydown).get, handler(.onkeydown).set, .{});
    pub const onkeypress = bridge.accessor(handler(.onkeypress).get, handler(.onkeypress).set, .{});
    pub const onkeyup = bridge.accessor(handler(.onkeyup).get, handler(.onkeyup).set, .{});
    pub const onload = bridge.accessor(handler(.onload).get, handler(.onload).set, .{});
    pub const onloadeddata = bridge.accessor(handler(.onloadeddata).get, handler(.onloadeddata).set, .{});
    pub const onloadedmetadata = bridge.accessor(handler(.onloadedmetadata).get, handler(.onloadedmetadata).set, .{});
    pub const onloadstart = bridge.accessor(handler(.onloadstart).get, handler(.onloadstart).set, .{});
    pub const onmousedown = bridge.accessor(handler(.onmousedown).get, handler(.onmousedown).set, .{});
    pub const onmouseenter = bridge.accessor(handler(.onmouseenter).get, handler(.onmouseenter).set, .{});
    pub const onmouseleave = bridge.accessor(handler(.onmouseleave).get, handler(.onmouseleave).set, .{});
    pub const onmousemove = bridge.accessor(handler(.onmousemove).get, handler(.onmousemove).set, .{});
    pub const onmouseout = bridge.accessor(handler(.onmouseout).get, handler(.onmouseout).set, .{});
    pub const onmouseover = bridge.accessor(handler(.onmouseover).get, handler(.onmouseover).set, .{});
    pub const onmouseup = bridge.accessor(handler(.onmouseup).get, handler(.onmouseup).set, .{});
    pub const onmousewheel = bridge.accessor(handler(.onmousewheel).get, handler(.onmousewheel).set, .{});
    pub const onpause = bridge.accessor(handler(.onpause).get, handler(.onpause).set, .{});
    pub const onplay = bridge.accessor(handler(.onplay).get, handler(.onplay).set, .{});
    pub const onplaying = bridge.accessor(handler(.onplaying).get, handler(.onplaying).set, .{});
    pub const onprogress = bridge.accessor(handler(.onprogress).get, handler(.onprogress).set, .{});
    pub const onratechange = bridge.accessor(handler(.onratechange).get, handler(.onratechange).set, .{});
    pub const onreset = bridge.accessor(handler(.onreset).get, handler(.onreset).set, .{});
    pub const onresize = bridge.accessor(handler(.onresize).get, handler(.onresize).set, .{});
    pub const onscroll = bridge.accessor(handler(.onscroll).get, handler(.onscroll).set, .{});
    pub const onscrollend = bridge.accessor(handler(.onscrollend).get, handler(.onscrollend).set, .{});
    pub const onsecuritypolicyviolation = bridge.accessor(handler(.onsecuritypolicyviolation).get, handler(.onsecuritypolicyviolation).set, .{});
    pub const onseeked = bridge.accessor(handler(.onseeked).get, handler(.onseeked).set, .{});
    pub const onseeking = bridge.accessor(handler(.onseeking).get, handler(.onseeking).set, .{});
    pub const onselect = bridge.accessor(handler(.onselect).get, handler(.onselect).set, .{});
    pub const onslotchange = bridge.accessor(handler(.onslotchange).get, handler(.onslotchange).set, .{});
    pub const onstalled = bridge.accessor(handler(.onstalled).get, handler(.onstalled).set, .{});
    pub const onsubmit = bridge.accessor(handler(.onsubmit).get, handler(.onsubmit).set, .{});
    pub const onsuspend = bridge.accessor(handler(.onsuspend).get, handler(.onsuspend).set, .{});
    pub const ontimeupdate = bridge.accessor(handler(.ontimeupdate).get, handler(.ontimeupdate).set, .{});
    pub const ontoggle = bridge.accessor(handler(.ontoggle).get, handler(.ontoggle).set, .{});
    pub const onvolumechange = bridge.accessor(handler(.onvolumechange).get, handler(.onvolumechange).set, .{});
    pub const onwaiting = bridge.accessor(handler(.onwaiting).get, handler(.onwaiting).set, .{});
    pub const onwebkitanimationend = bridge.accessor(handler(.onwebkitanimationend).get, handler(.onwebkitanimationend).set, .{});
    pub const onwebkitanimationiteration = bridge.accessor(handler(.onwebkitanimationiteration).get, handler(.onwebkitanimationiteration).set, .{});
    pub const onwebkitanimationstart = bridge.accessor(handler(.onwebkitanimationstart).get, handler(.onwebkitanimationstart).set, .{});
    pub const onwebkittransitionend = bridge.accessor(handler(.onwebkittransitionend).get, handler(.onwebkittransitionend).set, .{});
    pub const onwheel = bridge.accessor(handler(.onwheel).get, handler(.onwheel).set, .{});
    pub const onauxclick = bridge.accessor(handler(.onauxclick).get, handler(.onauxclick).set, .{});
    pub const ongotpointercapture = bridge.accessor(handler(.ongotpointercapture).get, handler(.ongotpointercapture).set, .{});
    pub const onlostpointercapture = bridge.accessor(handler(.onlostpointercapture).get, handler(.onlostpointercapture).set, .{});
    pub const onpointerdown = bridge.accessor(handler(.onpointerdown).get, handler(.onpointerdown).set, .{});
    pub const onpointermove = bridge.accessor(handler(.onpointermove).get, handler(.onpointermove).set, .{});
    pub const onpointerup = bridge.accessor(handler(.onpointerup).get, handler(.onpointerup).set, .{});
    pub const onpointercancel = bridge.accessor(handler(.onpointercancel).get, handler(.onpointercancel).set, .{});
    pub const onpointerover = bridge.accessor(handler(.onpointerover).get, handler(.onpointerover).set, .{});
    pub const onpointerout = bridge.accessor(handler(.onpointerout).get, handler(.onpointerout).set, .{});
    pub const onpointerenter = bridge.accessor(handler(.onpointerenter).get, handler(.onpointerenter).set, .{});
    pub const onpointerleave = bridge.accessor(handler(.onpointerleave).get, handler(.onpointerleave).set, .{});
    pub const onselectstart = bridge.accessor(handler(.onselectstart).get, handler(.onselectstart).set, .{});
    pub const onselectionchange = bridge.accessor(handler(.onselectionchange).get, handler(.onselectionchange).set, .{});
    pub const onanimationcancel = bridge.accessor(handler(.onanimationcancel).get, handler(.onanimationcancel).set, .{});
    pub const onanimationend = bridge.accessor(handler(.onanimationend).get, handler(.onanimationend).set, .{});
    pub const onanimationiteration = bridge.accessor(handler(.onanimationiteration).get, handler(.onanimationiteration).set, .{});
    pub const onanimationstart = bridge.accessor(handler(.onanimationstart).get, handler(.onanimationstart).set, .{});
    pub const ontransitionrun = bridge.accessor(handler(.ontransitionrun).get, handler(.ontransitionrun).set, .{});
    pub const ontransitionstart = bridge.accessor(handler(.ontransitionstart).get, handler(.ontransitionstart).set, .{});
    pub const ontransitionend = bridge.accessor(handler(.ontransitionend).get, handler(.ontransitionend).set, .{});
    pub const ontransitioncancel = bridge.accessor(handler(.ontransitioncancel).get, handler(.ontransitioncancel).set, .{});
    pub const onbeforexrselect = bridge.accessor(handler(.onbeforexrselect).get, handler(.onbeforexrselect).set, .{});
    pub const oncopy = bridge.accessor(handler(.oncopy).get, handler(.oncopy).set, .{});
    pub const oncut = bridge.accessor(handler(.oncut).get, handler(.oncut).set, .{});
    pub const onpaste = bridge.accessor(handler(.onpaste).get, handler(.onpaste).set, .{});
    pub const dataset = bridge.accessor(_dataset, null, .{});
    pub const nonce = bridge.accessor(_nonce, _setNonce, .{ .ce_reactions = true });
    pub const autofocus = bridge.accessor(_autofocus, _setAutofocus, .{ .ce_reactions = true });
    pub const tabIndex = bridge.accessor(_tabIndex, _setTabIndex, .{ .ce_reactions = true });
    pub const style = bridge.accessor(_style, _setStyle, .{});
    pub const attributeStyleMap = bridge.accessor(_attributeStyleMap, null, .{});
    pub const blur = bridge.function(_blur, .{});
    pub const focus = bridge.function(_focus, .{});
    pub const onscrollsnapchange = bridge.accessor(handler(.onscrollsnapchange).get, handler(.onscrollsnapchange).set, .{});
    pub const onscrollsnapchanging = bridge.accessor(handler(.onscrollsnapchanging).get, handler(.onscrollsnapchanging).set, .{});
    pub const focusGroup = bridge.accessor(_focusGroup, _setFocusGroup, .{ .ce_reactions = true });
    pub const focusGroupStart = bridge.accessor(_focusGroupStart, _setFocusGroupStart, .{ .ce_reactions = true });
    pub const onpointerrawupdate = bridge.accessor(handler(.onpointerrawupdate).get, handler(.onpointerrawupdate).set, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Svg" {
    try testing.htmlRunner("element/svg", .{});
}
