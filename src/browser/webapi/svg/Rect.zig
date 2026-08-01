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

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

// SVG2 folds SVGRect into DOMRect, but no browser shipped that: Chrome and
// Firefox both still answer getBBox(), getExtentOfChar() and createSVGRect()
// with a distinct SVGRect, whose prototype descends straight from Object and
// carries nothing but the four coordinates. Fingerprinters read the interface
// off the returned object, so the name and the member list are the point;
// SVGPoint and SVGMatrix are the same story and are still DOM types here.
const Rect = @This();

_x: f64 = 0,
_y: f64 = 0,
_width: f64 = 0,
_height: f64 = 0,

pub const Data = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

pub fn create(data: Data, factory: *Factory) !*Rect {
    return factory.create(Rect{
        ._x = data.x,
        ._y = data.y,
        ._width = data.width,
        ._height = data.height,
    });
}

pub fn getX(self: *const Rect) f64 {
    return self._x;
}

pub fn getY(self: *const Rect) f64 {
    return self._y;
}

pub fn getWidth(self: *const Rect) f64 {
    return self._width;
}

pub fn getHeight(self: *const Rect) f64 {
    return self._height;
}

// Every coordinate is a WebIDL `float`, which is restricted: Chrome answers a
// non-finite assignment with "The provided float value is non-finite." The
// bridge does not police that for us.
pub fn setX(self: *Rect, value: f64) !void {
    self._x = try finite(value);
}

pub fn setY(self: *Rect, value: f64) !void {
    self._y = try finite(value);
}

pub fn setWidth(self: *Rect, value: f64) !void {
    self._width = try finite(value);
}

pub fn setHeight(self: *Rect, value: f64) !void {
    self._height = try finite(value);
}

fn finite(value: f64) !f64 {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
    return value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Rect);

    pub const Meta = struct {
        pub const name = "SVGRect";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const x = bridge.accessor(Rect.getX, Rect.setX, .{});
    pub const y = bridge.accessor(Rect.getY, Rect.setY, .{});
    pub const width = bridge.accessor(Rect.getWidth, Rect.setWidth, .{});
    pub const height = bridge.accessor(Rect.getHeight, Rect.setHeight, .{});
};
