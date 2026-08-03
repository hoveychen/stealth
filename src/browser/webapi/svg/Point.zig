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
const Page = @import("../../Page.zig");
const Matrix = @import("Matrix.zig");

// Like SVGRect and SVGMatrix, SVGPoint survived SVG2's plan to fold it into
// the DOM geometry types: createSVGPoint(), matrixTransform() and every
// SVGPointList item still answer with this interface, which carries x and y
// but no z or w, and rejects a DOMPoint where one is expected. Its
// coordinates are WebIDL floats, so a double round-trips through single
// precision -- 0.1 reads back as 0.10000000149011612 -- while SVGMatrix keeps
// doubles.
const Point = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_x: f64 = 0,
_y: f64 = 0,
_attachment: ?Attachment = null,
_read_only: bool = false,

pub const Coordinate = enum { x, y };

// A point that is an item of a reflected list hands writes to the list, which
// reserialises the attribute around them.
pub const Attachment = struct {
    owner: *anyopaque,
    mutate: *const fn (*anyopaque, *Point, Coordinate, f64) anyerror!void,
};

pub fn create(x: f64, y: f64, page: *Page) !*Point {
    const arena = try page.getArena(.tiny, "SVGPoint");
    errdefer arena.release();
    const self = try arena.create(Point);
    self.* = .{ ._arena = arena, ._x = x, ._y = y };
    return self;
}

pub fn deinit(self: *Point, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *Point) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Point, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getX(self: *const Point) f64 {
    return self._x;
}

pub fn getY(self: *const Point) f64 {
    return self._y;
}

pub fn setX(self: *Point, value: f64) !void {
    return self.setCoordinate(.x, value);
}

pub fn setY(self: *Point, value: f64) !void {
    return self.setCoordinate(.y, value);
}

pub fn setCoordinate(self: *Point, coordinate: Coordinate, value: f64) !void {
    if (self._read_only) return error.NoModificationAllowed;
    const narrowed = try asFloat(value);
    if (self._attachment) |attachment| {
        return attachment.mutate(attachment.owner, self, coordinate, narrowed);
    }
    self.setCoordinateRaw(coordinate, narrowed);
}

pub fn setCoordinateRaw(self: *Point, coordinate: Coordinate, value: f64) void {
    switch (coordinate) {
        .x => self._x = value,
        .y => self._y = value,
    }
}

pub fn attach(self: *Point, attachment: Attachment, read_only: bool) void {
    self._attachment = attachment;
    if (read_only) self._read_only = true;
}

pub fn detach(self: *Point, owner: *anyopaque) void {
    const attachment = self._attachment orelse return;
    if (attachment.owner == owner) self._attachment = null;
}

pub fn isAttached(self: *const Point) bool {
    return self._attachment != null;
}

pub fn isAttachedTo(self: *const Point, owner: *anyopaque) bool {
    const attachment = self._attachment orelse return false;
    return attachment.owner == owner;
}

pub fn matrixTransform(self: *const Point, matrix: *const Matrix, frame: *Frame) !*Point {
    const m = matrix.value();
    return create(
        narrow(m.a * self._x + m.c * self._y + m.e),
        narrow(m.b * self._x + m.d * self._y + m.f),
        frame._page,
    );
}

// A restricted float, not a restricted double: 1e40 is a finite double but
// overflows to infinity as a float, and Chrome rejects it for that reason.
fn asFloat(value: f64) !f64 {
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
    const narrowed: f32 = @floatCast(value);
    if (!std.math.isFinite(narrowed)) {
        return error.TypeError;
    }
    return @floatCast(narrowed);
}

pub fn narrow(value: f64) f64 {
    return @floatCast(@as(f32, @floatCast(value)));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Point);

    pub const Meta = struct {
        pub const name = "SVGPoint";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const x = bridge.accessor(Point.getX, Point.setX, .{});
    pub const y = bridge.accessor(Point.getY, Point.setY, .{});
    pub const matrixTransform = bridge.function(Point.matrixTransform, .{});
};
