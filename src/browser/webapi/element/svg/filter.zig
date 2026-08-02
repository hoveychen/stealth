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

//! <filter> and its primitives. This engine does not run the filter pipeline,
//! so nothing here paints; what it provides is the interface surface — the
//! window globals, the prototype members in Chrome's own order, the SVG_*
//! constants and the attribute reflection behind each animated value.
//!
//! Every default, enumeration value and prototype order below was read off a
//! headed Chrome 150 over http://localhost, not off the specification: the
//! two disagree in places (feDisplacementMap's channel selectors default to
//! A, not R, and feDropShadow's dx/dy/stdDeviation default to 2).
//!
//! The primitives that carry no members beyond the shared subregion still
//! need their own class, because the class name is exactly what a detector
//! reads.

const std = @import("std");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedNumber = @import("../../svg/AnimatedNumber.zig");
const AnimatedPreserveAspectRatio = @import("../../svg/AnimatedPreserveAspectRatio.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");

pub fn registerTypes() []const type {
    return &.{
        Filter,
        FEBlend,
        FEComponentTransfer,
        FEComposite,
        FEDiffuseLighting,
        FEDisplacementMap,
        FEDistantLight,
        FEDropShadow,
        FEFlood,
        FEGaussianBlur,
        FEImage,
        FEMerge,
        FEMergeNode,
        FEMorphology,
        FEOffset,
        FEPointLight,
        FESpecularLighting,
        FESpotLight,
        FETile,
    };
}

// Accessor factories. Every primitive reaches its animated values the same
// way — through the element and a reflection kind — so the getters are
// generated rather than written out nineteen times.
fn Len(comptime T: type, comptime kind: AnimatedLength.Kind) type {
    return struct {
        pub fn get(self: *T, frame: *Frame) !*AnimatedLength {
            return AnimatedLength.getOrCreate(self._proto.asElement(), kind, frame);
        }
    };
}

fn Num(comptime T: type, comptime kind: AnimatedNumber.Kind) type {
    return struct {
        pub fn get(self: *T, frame: *Frame) !*AnimatedNumber {
            return AnimatedNumber.getOrCreate(self._proto.asElement(), kind, frame);
        }
    };
}

fn Str(comptime T: type, comptime kind: AnimatedString.Kind) type {
    return struct {
        pub fn get(self: *T, frame: *Frame) !*AnimatedString {
            return AnimatedString.getOrCreate(self._proto.asElement(), kind, frame);
        }
    };
}

fn Enum(comptime T: type, comptime kind: AnimatedEnumeration.Kind) type {
    return struct {
        pub fn get(self: *T, frame: *Frame) !*AnimatedEnumeration {
            return AnimatedEnumeration.getOrCreate(self._proto.asElement(), kind, frame);
        }
    };
}

// setStdDeviation() on feGaussianBlur and feDropShadow. Measured on Chrome:
// it moves both base values and leaves the attribute alone.
fn setStdDeviationOn(
    element: *Element,
    x_kind: AnimatedNumber.Kind,
    y_kind: AnimatedNumber.Kind,
    x: f32,
    y: f32,
    frame: *Frame,
) !void {
    const std_x = try AnimatedNumber.getOrCreate(element, x_kind, frame);
    const std_y = try AnimatedNumber.getOrCreate(element, y_kind, frame);
    try std_x.setOverride(x);
    try std_y.setOverride(y);
}

pub const Filter = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *Filter) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *Filter) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Filter);
        pub const Meta = struct {
            pub const name = "SVGFilterElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const filterUnits = bridge.accessor(Enum(Filter, .filter_units).get, null, .{});
        pub const primitiveUnits = bridge.accessor(Enum(Filter, .primitive_units).get, null, .{});
        pub const x = bridge.accessor(Len(Filter, .filter_x).get, null, .{});
        pub const y = bridge.accessor(Len(Filter, .filter_y).get, null, .{});
        pub const width = bridge.accessor(Len(Filter, .filter_width).get, null, .{});
        pub const height = bridge.accessor(Len(Filter, .filter_height).get, null, .{});
        pub const href = bridge.accessor(Str(Filter, .href).get, null, .{});
    };
};

pub const FEBlend = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEBlend) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEBlend) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEBlend);
        pub const Meta = struct {
            pub const name = "SVGFEBlendElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEBlend, .in1).get, null, .{});
        pub const in2 = bridge.accessor(Str(FEBlend, .in2).get, null, .{});
        pub const mode = bridge.accessor(Enum(FEBlend, .blend_mode).get, null, .{});
        pub const x = bridge.accessor(Len(FEBlend, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEBlend, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEBlend, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEBlend, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEBlend, .result).get, null, .{});

        pub const SVG_FEBLEND_MODE_UNKNOWN = bridge.property(0, .{ .template = true });
        pub const SVG_FEBLEND_MODE_NORMAL = bridge.property(1, .{ .template = true });
        pub const SVG_FEBLEND_MODE_MULTIPLY = bridge.property(2, .{ .template = true });
        pub const SVG_FEBLEND_MODE_SCREEN = bridge.property(3, .{ .template = true });
        pub const SVG_FEBLEND_MODE_DARKEN = bridge.property(4, .{ .template = true });
        pub const SVG_FEBLEND_MODE_LIGHTEN = bridge.property(5, .{ .template = true });
        pub const SVG_FEBLEND_MODE_OVERLAY = bridge.property(6, .{ .template = true });
        pub const SVG_FEBLEND_MODE_COLOR_DODGE = bridge.property(7, .{ .template = true });
        pub const SVG_FEBLEND_MODE_COLOR_BURN = bridge.property(8, .{ .template = true });
        pub const SVG_FEBLEND_MODE_HARD_LIGHT = bridge.property(9, .{ .template = true });
        pub const SVG_FEBLEND_MODE_SOFT_LIGHT = bridge.property(10, .{ .template = true });
        pub const SVG_FEBLEND_MODE_DIFFERENCE = bridge.property(11, .{ .template = true });
        pub const SVG_FEBLEND_MODE_EXCLUSION = bridge.property(12, .{ .template = true });
        pub const SVG_FEBLEND_MODE_HUE = bridge.property(13, .{ .template = true });
        pub const SVG_FEBLEND_MODE_SATURATION = bridge.property(14, .{ .template = true });
        pub const SVG_FEBLEND_MODE_COLOR = bridge.property(15, .{ .template = true });
        pub const SVG_FEBLEND_MODE_LUMINOSITY = bridge.property(16, .{ .template = true });
    };
};

pub const FEComponentTransfer = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEComponentTransfer) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEComponentTransfer) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEComponentTransfer);
        pub const Meta = struct {
            pub const name = "SVGFEComponentTransferElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEComponentTransfer, .in1).get, null, .{});
        pub const x = bridge.accessor(Len(FEComponentTransfer, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEComponentTransfer, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEComponentTransfer, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEComponentTransfer, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEComponentTransfer, .result).get, null, .{});
    };
};

pub const FEComposite = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEComposite) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEComposite) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEComposite);
        pub const Meta = struct {
            pub const name = "SVGFECompositeElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome really does put in2 before in1 here, unlike every other
        // primitive that takes two inputs.
        pub const in2 = bridge.accessor(Str(FEComposite, .in2).get, null, .{});
        pub const in1 = bridge.accessor(Str(FEComposite, .in1).get, null, .{});
        pub const operator = bridge.accessor(Enum(FEComposite, .composite_operator).get, null, .{});
        pub const k1 = bridge.accessor(Num(FEComposite, .composite_k1).get, null, .{});
        pub const k2 = bridge.accessor(Num(FEComposite, .composite_k2).get, null, .{});
        pub const k3 = bridge.accessor(Num(FEComposite, .composite_k3).get, null, .{});
        pub const k4 = bridge.accessor(Num(FEComposite, .composite_k4).get, null, .{});
        pub const x = bridge.accessor(Len(FEComposite, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEComposite, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEComposite, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEComposite, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEComposite, .result).get, null, .{});

        pub const SVG_FECOMPOSITE_OPERATOR_UNKNOWN = bridge.property(0, .{ .template = true });
        pub const SVG_FECOMPOSITE_OPERATOR_OVER = bridge.property(1, .{ .template = true });
        pub const SVG_FECOMPOSITE_OPERATOR_IN = bridge.property(2, .{ .template = true });
        pub const SVG_FECOMPOSITE_OPERATOR_OUT = bridge.property(3, .{ .template = true });
        pub const SVG_FECOMPOSITE_OPERATOR_ATOP = bridge.property(4, .{ .template = true });
        pub const SVG_FECOMPOSITE_OPERATOR_XOR = bridge.property(5, .{ .template = true });
        pub const SVG_FECOMPOSITE_OPERATOR_ARITHMETIC = bridge.property(6, .{ .template = true });
    };
};

pub const FEDiffuseLighting = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEDiffuseLighting) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEDiffuseLighting) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEDiffuseLighting);
        pub const Meta = struct {
            pub const name = "SVGFEDiffuseLightingElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEDiffuseLighting, .in1).get, null, .{});
        pub const surfaceScale = bridge.accessor(Num(FEDiffuseLighting, .surface_scale).get, null, .{});
        pub const diffuseConstant = bridge.accessor(Num(FEDiffuseLighting, .diffuse_constant).get, null, .{});
        pub const kernelUnitLengthX = bridge.accessor(Num(FEDiffuseLighting, .kernel_unit_length_x).get, null, .{});
        pub const kernelUnitLengthY = bridge.accessor(Num(FEDiffuseLighting, .kernel_unit_length_y).get, null, .{});
        pub const x = bridge.accessor(Len(FEDiffuseLighting, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEDiffuseLighting, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEDiffuseLighting, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEDiffuseLighting, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEDiffuseLighting, .result).get, null, .{});
    };
};

pub const FEDisplacementMap = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEDisplacementMap) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEDisplacementMap) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEDisplacementMap);
        pub const Meta = struct {
            pub const name = "SVGFEDisplacementMapElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEDisplacementMap, .in1).get, null, .{});
        pub const in2 = bridge.accessor(Str(FEDisplacementMap, .in2).get, null, .{});
        pub const scale = bridge.accessor(Num(FEDisplacementMap, .displacement_scale).get, null, .{});
        pub const xChannelSelector = bridge.accessor(Enum(FEDisplacementMap, .displacement_x_channel).get, null, .{});
        pub const yChannelSelector = bridge.accessor(Enum(FEDisplacementMap, .displacement_y_channel).get, null, .{});
        pub const x = bridge.accessor(Len(FEDisplacementMap, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEDisplacementMap, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEDisplacementMap, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEDisplacementMap, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEDisplacementMap, .result).get, null, .{});

        pub const SVG_CHANNEL_UNKNOWN = bridge.property(0, .{ .template = true });
        pub const SVG_CHANNEL_R = bridge.property(1, .{ .template = true });
        pub const SVG_CHANNEL_G = bridge.property(2, .{ .template = true });
        pub const SVG_CHANNEL_B = bridge.property(3, .{ .template = true });
        pub const SVG_CHANNEL_A = bridge.property(4, .{ .template = true });
    };
};

pub const FEDistantLight = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEDistantLight) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEDistantLight) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEDistantLight);
        pub const Meta = struct {
            pub const name = "SVGFEDistantLightElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const azimuth = bridge.accessor(Num(FEDistantLight, .light_azimuth).get, null, .{});
        pub const elevation = bridge.accessor(Num(FEDistantLight, .light_elevation).get, null, .{});
    };
};

pub const FEDropShadow = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEDropShadow) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEDropShadow) *Node {
        return self.asElement().asNode();
    }

    pub fn setStdDeviation(self: *FEDropShadow, x: f32, y: f32, frame: *Frame) !void {
        return setStdDeviationOn(self.asElement(), .drop_shadow_std_x, .drop_shadow_std_y, x, y, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEDropShadow);
        pub const Meta = struct {
            pub const name = "SVGFEDropShadowElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEDropShadow, .in1).get, null, .{});
        pub const dx = bridge.accessor(Num(FEDropShadow, .drop_shadow_dx).get, null, .{});
        pub const dy = bridge.accessor(Num(FEDropShadow, .drop_shadow_dy).get, null, .{});
        pub const stdDeviationX = bridge.accessor(Num(FEDropShadow, .drop_shadow_std_x).get, null, .{});
        pub const stdDeviationY = bridge.accessor(Num(FEDropShadow, .drop_shadow_std_y).get, null, .{});
        pub const x = bridge.accessor(Len(FEDropShadow, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEDropShadow, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEDropShadow, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEDropShadow, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEDropShadow, .result).get, null, .{});
        pub const setStdDeviation = bridge.function(FEDropShadow.setStdDeviation, .{});
    };
};

pub const FEFlood = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEFlood) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEFlood) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEFlood);
        pub const Meta = struct {
            pub const name = "SVGFEFloodElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const x = bridge.accessor(Len(FEFlood, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEFlood, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEFlood, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEFlood, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEFlood, .result).get, null, .{});
    };
};

pub const FEGaussianBlur = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEGaussianBlur) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEGaussianBlur) *Node {
        return self.asElement().asNode();
    }

    pub fn setStdDeviation(self: *FEGaussianBlur, x: f32, y: f32, frame: *Frame) !void {
        return setStdDeviationOn(self.asElement(), .std_deviation_x, .std_deviation_y, x, y, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEGaussianBlur);
        pub const Meta = struct {
            pub const name = "SVGFEGaussianBlurElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEGaussianBlur, .in1).get, null, .{});
        pub const stdDeviationX = bridge.accessor(Num(FEGaussianBlur, .std_deviation_x).get, null, .{});
        pub const stdDeviationY = bridge.accessor(Num(FEGaussianBlur, .std_deviation_y).get, null, .{});
        pub const x = bridge.accessor(Len(FEGaussianBlur, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEGaussianBlur, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEGaussianBlur, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEGaussianBlur, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEGaussianBlur, .result).get, null, .{});
        pub const setStdDeviation = bridge.function(FEGaussianBlur.setStdDeviation, .{});
    };
};

pub const FEImage = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEImage) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEImage) *Node {
        return self.asElement().asNode();
    }

    pub fn getPreserveAspectRatio(self: *FEImage, frame: *Frame) !*AnimatedPreserveAspectRatio {
        return AnimatedPreserveAspectRatio.getOrCreate(self.asElement(), frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEImage);
        pub const Meta = struct {
            pub const name = "SVGFEImageElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const preserveAspectRatio = bridge.accessor(FEImage.getPreserveAspectRatio, null, .{});
        pub const x = bridge.accessor(Len(FEImage, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEImage, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEImage, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEImage, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEImage, .result).get, null, .{});
        pub const href = bridge.accessor(Str(FEImage, .href).get, null, .{});
    };
};

pub const FEMerge = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEMerge) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEMerge) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEMerge);
        pub const Meta = struct {
            pub const name = "SVGFEMergeElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const x = bridge.accessor(Len(FEMerge, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEMerge, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEMerge, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEMerge, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEMerge, .result).get, null, .{});
    };
};

pub const FEMergeNode = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEMergeNode) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEMergeNode) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEMergeNode);
        pub const Meta = struct {
            pub const name = "SVGFEMergeNodeElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEMergeNode, .in1).get, null, .{});
    };
};

pub const FEMorphology = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEMorphology) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEMorphology) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEMorphology);
        pub const Meta = struct {
            pub const name = "SVGFEMorphologyElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEMorphology, .in1).get, null, .{});
        pub const operator = bridge.accessor(Enum(FEMorphology, .morphology_operator).get, null, .{});
        pub const radiusX = bridge.accessor(Num(FEMorphology, .morphology_radius_x).get, null, .{});
        pub const radiusY = bridge.accessor(Num(FEMorphology, .morphology_radius_y).get, null, .{});
        pub const x = bridge.accessor(Len(FEMorphology, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEMorphology, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEMorphology, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEMorphology, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEMorphology, .result).get, null, .{});

        pub const SVG_MORPHOLOGY_OPERATOR_UNKNOWN = bridge.property(0, .{ .template = true });
        pub const SVG_MORPHOLOGY_OPERATOR_ERODE = bridge.property(1, .{ .template = true });
        pub const SVG_MORPHOLOGY_OPERATOR_DILATE = bridge.property(2, .{ .template = true });
    };
};

pub const FEOffset = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEOffset) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEOffset) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEOffset);
        pub const Meta = struct {
            pub const name = "SVGFEOffsetElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FEOffset, .in1).get, null, .{});
        pub const dx = bridge.accessor(Num(FEOffset, .offset_dx).get, null, .{});
        pub const dy = bridge.accessor(Num(FEOffset, .offset_dy).get, null, .{});
        pub const x = bridge.accessor(Len(FEOffset, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FEOffset, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FEOffset, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FEOffset, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FEOffset, .result).get, null, .{});
    };
};

pub const FEPointLight = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FEPointLight) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FEPointLight) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FEPointLight);
        pub const Meta = struct {
            pub const name = "SVGFEPointLightElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // A light's x/y/z are plain numbers, not lengths.
        pub const x = bridge.accessor(Num(FEPointLight, .light_x).get, null, .{});
        pub const y = bridge.accessor(Num(FEPointLight, .light_y).get, null, .{});
        pub const z = bridge.accessor(Num(FEPointLight, .light_z).get, null, .{});
    };
};

pub const FESpecularLighting = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FESpecularLighting) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FESpecularLighting) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FESpecularLighting);
        pub const Meta = struct {
            pub const name = "SVGFESpecularLightingElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FESpecularLighting, .in1).get, null, .{});
        pub const surfaceScale = bridge.accessor(Num(FESpecularLighting, .surface_scale).get, null, .{});
        pub const specularConstant = bridge.accessor(Num(FESpecularLighting, .specular_constant).get, null, .{});
        pub const specularExponent = bridge.accessor(Num(FESpecularLighting, .specular_exponent).get, null, .{});
        pub const kernelUnitLengthX = bridge.accessor(Num(FESpecularLighting, .kernel_unit_length_x).get, null, .{});
        pub const kernelUnitLengthY = bridge.accessor(Num(FESpecularLighting, .kernel_unit_length_y).get, null, .{});
        pub const x = bridge.accessor(Len(FESpecularLighting, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FESpecularLighting, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FESpecularLighting, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FESpecularLighting, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FESpecularLighting, .result).get, null, .{});
    };
};

pub const FESpotLight = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FESpotLight) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FESpotLight) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FESpotLight);
        pub const Meta = struct {
            pub const name = "SVGFESpotLightElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const x = bridge.accessor(Num(FESpotLight, .light_x).get, null, .{});
        pub const y = bridge.accessor(Num(FESpotLight, .light_y).get, null, .{});
        pub const z = bridge.accessor(Num(FESpotLight, .light_z).get, null, .{});
        pub const pointsAtX = bridge.accessor(Num(FESpotLight, .light_points_at_x).get, null, .{});
        pub const pointsAtY = bridge.accessor(Num(FESpotLight, .light_points_at_y).get, null, .{});
        pub const pointsAtZ = bridge.accessor(Num(FESpotLight, .light_points_at_z).get, null, .{});
        pub const specularExponent = bridge.accessor(Num(FESpotLight, .specular_exponent).get, null, .{});
        pub const limitingConeAngle = bridge.accessor(Num(FESpotLight, .limiting_cone_angle).get, null, .{});
    };
};

pub const FETile = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *FETile) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *FETile) *Node {
        return self.asElement().asNode();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FETile);
        pub const Meta = struct {
            pub const name = "SVGFETileElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(Str(FETile, .in1).get, null, .{});
        pub const x = bridge.accessor(Len(FETile, .primitive_x).get, null, .{});
        pub const y = bridge.accessor(Len(FETile, .primitive_y).get, null, .{});
        pub const width = bridge.accessor(Len(FETile, .primitive_width).get, null, .{});
        pub const height = bridge.accessor(Len(FETile, .primitive_height).get, null, .{});
        pub const result = bridge.accessor(Str(FETile, .result).get, null, .{});
    };
};
