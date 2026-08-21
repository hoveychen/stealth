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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const Svg = @import("../Svg.zig");

const Generic = @This();

pub const Proto = Svg;
_proto_canary: if (lp.IS_DEBUG) *Svg else void = undefined,
_tag: Element.Tag,

pub fn asElement(self: *Generic) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Generic) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Generic);

    pub const Meta = struct {
        pub const name = "SVGGenericElement";

        // Chrome has no interface for an unknown SVG tag: it lands on SVGElement
        // itself, so there is no global name to expose and the brand is plain
        // '[object SVGElement]' (measured on a headed Chrome 150 with
        // createElementNS(svgns, 'notarealtag')). Dropping the interface object
        // also drops the `constructor` back-reference, which makes
        // el.constructor resolve up the chain to SVGElement the way it does
        // there. The prototype object stays this engine's own.
        pub const no_interface_object = true;
        pub const to_string_tag = "SVGElement";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
