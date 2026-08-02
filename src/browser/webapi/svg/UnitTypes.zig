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

// SVGUnitTypes exists only to hold the three unit-type constants that
// SVGFilterElement, SVGClipPathElement, SVGMaskElement, SVGPatternElement and
// SVGGradientElement all include. Nothing ever constructs one — Chrome answers
// `new SVGUnitTypes()` with "Illegal constructor" — but the global and its
// prototype are part of the window surface, so the interface is registered
// like any other.

const js = @import("../../js/js.zig");

const UnitTypes = @This();

_pad: bool = false,

pub const JsApi = struct {
    pub const bridge = js.Bridge(UnitTypes);

    pub const Meta = struct {
        pub const name = "SVGUnitTypes";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_UNIT_TYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_UNIT_TYPE_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_UNIT_TYPE_OBJECTBOUNDINGBOX = bridge.property(2, .{ .template = true });
};
