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
const Factory = @import("../../Factory.zig");
const Element = @import("../Element.zig");

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
// Set when this rect is the base or animated value of a reflected rect
// attribute (viewBox). The four coordinates then come from the attribute and
// a write puts the whole rect back into it.
_element: ?*Element = null,
_attr_name: lp.String = .empty,
_read_only: bool = false,

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

/// A rect that mirrors a `x y width height` attribute, such as viewBox.
pub fn reflected(element: *Element, attr_name: lp.String, read_only: bool, factory: *Factory) !*Rect {
    return factory.create(Rect{
        ._element = element,
        ._attr_name = attr_name,
        ._read_only = read_only,
    });
}

pub fn getX(self: *Rect) f64 {
    self.syncFromAttribute();
    return self._x;
}

pub fn getY(self: *Rect) f64 {
    self.syncFromAttribute();
    return self._y;
}

pub fn getWidth(self: *Rect) f64 {
    self.syncFromAttribute();
    return self._width;
}

pub fn getHeight(self: *Rect) f64 {
    self.syncFromAttribute();
    return self._height;
}

// Chrome throws away the whole attribute unless it holds exactly four
// numbers, so a short, long or malformed list reads back as 0 0 0 0. A
// negative width or height is kept as written.
fn syncFromAttribute(self: *Rect) void {
    const element = self._element orelse return;
    self._x = 0;
    self._y = 0;
    self._width = 0;
    self._height = 0;
    const raw = element.getAttributeSafe(self._attr_name) orelse return;

    var values: [4]f64 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c,");
    while (it.next()) |token| {
        if (count == values.len) return;
        values[count] = std.fmt.parseFloat(f64, token) catch return;
        if (!std.math.isFinite(values[count])) return;
        count += 1;
    }
    if (count != values.len) {
        return;
    }
    self._x = values[0];
    self._y = values[1];
    self._width = values[2];
    self._height = values[3];
}

fn writeBack(self: *Rect, frame: *Frame) !void {
    const element = self._element orelse return;
    const value = try std.fmt.allocPrint(frame.local_arena, "{d} {d} {d} {d}", .{
        self._x, self._y, self._width, self._height,
    });
    try element.setAttributeSafe(self._attr_name, .wrap(value), frame);
}

// Every coordinate is a WebIDL `float`, which is restricted: Chrome answers a
// non-finite assignment with "The provided float value is non-finite." The
// bridge does not police that for us.
pub fn setX(self: *Rect, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    self.syncFromAttribute();
    self._x = try finite(value);
    try self.writeBack(frame);
}

pub fn setY(self: *Rect, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    self.syncFromAttribute();
    self._y = try finite(value);
    try self.writeBack(frame);
}

pub fn setWidth(self: *Rect, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    self.syncFromAttribute();
    self._width = try finite(value);
    try self.writeBack(frame);
}

pub fn setHeight(self: *Rect, value: f64, frame: *Frame) !void {
    try self.ensureWritable();
    self.syncFromAttribute();
    self._height = try finite(value);
    try self.writeBack(frame);
}

fn ensureWritable(self: *const Rect) !void {
    if (self._read_only) {
        return error.NoModificationAllowed;
    }
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
