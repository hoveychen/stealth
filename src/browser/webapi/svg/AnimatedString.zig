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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");

pub const Lookup = std.AutoHashMapUnmanaged(Key, *AnimatedString);

const String = lp.String;

const AnimatedString = @This();

_kind: Kind,
_element: *Element,

pub const Kind = enum { class, href, in1, in2, result, target };
pub const Key = struct {
    element: *Element,
    kind: Kind,
};

// Identity map for AnimatedString, help by the frame
pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*AnimatedString {
    const key: Key = .{ .element = element, .kind = kind };
    const gop = try frame._svg_animated_strings.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_animated_strings.remove(key);
        gop.value_ptr.* = try frame._factory.create(AnimatedString{
            ._element = element,
            ._kind = kind,
        });
    }
    return gop.value_ptr.*;
}

pub fn getBaseVal(self: *const AnimatedString) []const u8 {
    if (self._kind == .href) {
        return href(self._element) orelse "";
    }
    return self._element.getAttributeSafe(self.attributeName()) orelse "";
}

/// SVG's `href` reflects the plain `href` attribute and the legacy
/// `xlink:href` one, plain winning. Measured in Chrome 151 (probe
/// `expr-xlink-p67.js`): `<use xlink:href="#icon">` reads `#icon`, and a `use`
/// carrying both reads the plain one.
///
/// Chrome tells the legacy attribute apart from a literal one by its
/// namespace -- `setAttribute('xlink:href')` lands in no namespace and is not
/// reflected. This engine has no namespace on an attribute at all, so that
/// literal spelling reflects here where it would not in Chrome. Modelling it
/// properly needs the whole attribute-namespace model.
pub fn href(element: *const Element) ?[]const u8 {
    return element.getAttributeSafe(comptime .wrap("href")) orelse
        element.getAttributeSafe(comptime .wrap("xlink:href"));
}

pub fn setBaseVal(self: *AnimatedString, value: String, frame: *Frame) !void {
    try self._element.setAttribute(self.attributeName(), value, frame);
}

// No real animation, return the BaseVal
pub fn getAnimVal(self: *const AnimatedString) []const u8 {
    return self.getBaseVal();
}

fn attributeName(self: *const AnimatedString) String {
    return switch (self._kind) {
        .class => comptime .wrap("class"),
        // Upstream's shape, adopted over ours (which always wrote the plain
        // `href`): a write updates the attribute that is actually set, so
        // `<use xlink:href>` keeps writing into xlink:href instead of growing
        // a second attribute -- which is what Chrome reports. The locals are
        // not named `href` because that would shadow the reader below.
        .href => {
            const plain: String = comptime .wrap("href");
            if (self._element.hasAttributeSafe(plain)) {
                return plain;
            }

            const legacy: String = comptime .wrap("xlink:href");
            if (self._element.hasAttributeSafe(legacy)) {
                // legacy attribute, returned if it exists and href doesn't
                return legacy;
            }
            return plain;
        },
        // The IDL attribute is `in1`; the content attribute is `in`.
        .in1 => comptime .wrap("in"),
        .in2 => comptime .wrap("in2"),
        .result => comptime .wrap("result"),
        .target => comptime .wrap("target"),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimatedString);

    pub const Meta = struct {
        pub const name = "SVGAnimatedString";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(AnimatedString.getBaseVal, AnimatedString.setBaseVal, .{});
    pub const animVal = bridge.accessor(AnimatedString.getAnimVal, null, .{});
};
