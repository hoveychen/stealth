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

// SVG2 says SVGMatrix is an alias of DOMMatrix, but no browser shipped that.
// Chrome answers createSVGMatrix(), getCTM(), getScreenCTM() and
// SVGTransform.matrix with a distinct interface: 2D only, no is2D/isIdentity,
// no mutating self methods, and a prototype hanging straight off
// Object.prototype. It is not even numerically identical to DOMMatrix -- see
// the degrees-to-radians note below -- so it cannot share that implementation.
const Matrix = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_value: Value = .{},
_attachment: ?Attachment = null,

pub const Value = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,
};

// An SVGMatrix that is the live view of something else -- an SVGTransform --
// hands writes to its owner instead of applying them itself.
pub const Attachment = struct {
    owner: *anyopaque,
    mutate: *const fn (*anyopaque, *Matrix, Value) anyerror!void,
};

// Blink multiplies by a precomputed pi/180 rather than multiplying by pi and
// then dividing by 180, and the two disagree in the last bits: SVGMatrix
// answers skewX(89) with 57.289961630759144 where DOMMatrix -- which does
// divide -- answers 57.289961630759876. Both measured on Chrome 150.
pub const DEGREES_TO_RADIANS: f64 = 0.017453292519943295;

pub fn create(initial: Value, page: *Page) !*Matrix {
    const arena = try page.getArena(.tiny, "SVGMatrix");
    errdefer arena.release();
    const self = try arena.create(Matrix);
    self.* = .{ ._arena = arena, ._value = initial };
    return self;
}

pub fn deinit(self: *Matrix, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *Matrix) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Matrix, page: *Page) void {
    self._rc.release(self, page);
}

pub fn value(self: *const Matrix) Value {
    return self._value;
}

pub fn applyValueRaw(self: *Matrix, new_value: Value) void {
    self._value = new_value;
}

pub fn attach(self: *Matrix, attachment: Attachment) void {
    self._attachment = attachment;
}

fn applyValue(self: *Matrix, new_value: Value) !void {
    if (self._attachment) |attachment| {
        return attachment.mutate(attachment.owner, self, new_value);
    }
    self.applyValueRaw(new_value);
}

/// `self` post-multiplied by `other`, the order every SVGMatrix operation
/// uses: the new transform applies first in user space.
pub fn multiplyValues(lhs: Value, rhs: Value) Value {
    return .{
        .a = lhs.a * rhs.a + lhs.c * rhs.b,
        .b = lhs.b * rhs.a + lhs.d * rhs.b,
        .c = lhs.a * rhs.c + lhs.c * rhs.d,
        .d = lhs.b * rhs.c + lhs.d * rhs.d,
        .e = lhs.a * rhs.e + lhs.c * rhs.f + lhs.e,
        .f = lhs.b * rhs.e + lhs.d * rhs.f + lhs.f,
    };
}

pub fn rotationValue(radians: f64) Value {
    const cos = @cos(radians);
    const sin = @sin(radians);
    return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
}

pub fn invertValue(m: Value) ?Value {
    const determinant = m.a * m.d - m.b * m.c;
    if (determinant == 0 or !std.math.isFinite(determinant)) {
        return null;
    }
    return .{
        .a = m.d / determinant,
        .b = -m.b / determinant,
        .c = -m.c / determinant,
        .d = m.a / determinant,
        .e = (m.c * m.f - m.d * m.e) / determinant,
        .f = (m.b * m.e - m.a * m.f) / determinant,
    };
}

fn derive(self: *const Matrix, rhs: Value, frame: *Frame) !*Matrix {
    return create(multiplyValues(self._value, rhs), frame._page);
}

pub fn getA(self: *const Matrix) f64 {
    return self._value.a;
}
pub fn getB(self: *const Matrix) f64 {
    return self._value.b;
}
pub fn getC(self: *const Matrix) f64 {
    return self._value.c;
}
pub fn getD(self: *const Matrix) f64 {
    return self._value.d;
}
pub fn getE(self: *const Matrix) f64 {
    return self._value.e;
}
pub fn getF(self: *const Matrix) f64 {
    return self._value.f;
}

// a..f are unrestricted in magnitude -- Chrome accepts 1e308 -- but not in
// kind: NaN and infinity are rejected as "non-finite".
pub fn setA(self: *Matrix, new: f64) !void {
    var next = self._value;
    next.a = try finite(new);
    try self.applyValue(next);
}
pub fn setB(self: *Matrix, new: f64) !void {
    var next = self._value;
    next.b = try finite(new);
    try self.applyValue(next);
}
pub fn setC(self: *Matrix, new: f64) !void {
    var next = self._value;
    next.c = try finite(new);
    try self.applyValue(next);
}
pub fn setD(self: *Matrix, new: f64) !void {
    var next = self._value;
    next.d = try finite(new);
    try self.applyValue(next);
}
pub fn setE(self: *Matrix, new: f64) !void {
    var next = self._value;
    next.e = try finite(new);
    try self.applyValue(next);
}
pub fn setF(self: *Matrix, new: f64) !void {
    var next = self._value;
    next.f = try finite(new);
    try self.applyValue(next);
}

pub fn multiply(self: *const Matrix, other: *const Matrix, frame: *Frame) !*Matrix {
    return self.derive(other._value, frame);
}

pub fn translate(self: *const Matrix, tx: f64, ty: f64, frame: *Frame) !*Matrix {
    return self.derive(.{ .e = try finite(tx), .f = try finite(ty) }, frame);
}

pub fn scale(self: *const Matrix, factor: f64, frame: *Frame) !*Matrix {
    return self.scaleNonUniform(factor, factor, frame);
}

pub fn scaleNonUniform(self: *const Matrix, sx: f64, sy: f64, frame: *Frame) !*Matrix {
    return self.derive(.{ .a = try finite(sx), .d = try finite(sy) }, frame);
}

pub fn rotate(self: *const Matrix, degrees: f64, frame: *Frame) !*Matrix {
    return self.derive(rotationValue(try finite(degrees) * DEGREES_TO_RADIANS), frame);
}

// Chrome rejects a zero component even though the angle is perfectly defined
// there, and it takes the angle through atan2 rather than normalising the
// vector: (3, 4) comes back as 0.6 / 0.7999999999999999, not 0.6 / 0.8.
pub fn rotateFromVector(self: *const Matrix, x: f64, y: f64, frame: *Frame) !*Matrix {
    if (try finite(x) == 0 or try finite(y) == 0) {
        return error.InvalidAccess;
    }
    return self.derive(rotationValue(std.math.atan2(y, x)), frame);
}

pub fn skewX(self: *const Matrix, degrees: f64, frame: *Frame) !*Matrix {
    return self.derive(.{ .c = @tan(try finite(degrees) * DEGREES_TO_RADIANS) }, frame);
}

pub fn skewY(self: *const Matrix, degrees: f64, frame: *Frame) !*Matrix {
    return self.derive(.{ .b = @tan(try finite(degrees) * DEGREES_TO_RADIANS) }, frame);
}

pub fn flipX(self: *const Matrix, frame: *Frame) !*Matrix {
    return self.derive(.{ .a = -1 }, frame);
}

pub fn flipY(self: *const Matrix, frame: *Frame) !*Matrix {
    return self.derive(.{ .d = -1 }, frame);
}

pub fn inverse(self: *const Matrix, frame: *Frame) !*Matrix {
    const inverted = invertValue(self._value) orelse return error.InvalidStateError;
    return create(inverted, frame._page);
}

fn finite(input: f64) !f64 {
    if (!std.math.isFinite(input)) {
        return error.TypeError;
    }
    return input;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Matrix);

    pub const Meta = struct {
        pub const name = "SVGMatrix";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const a = bridge.accessor(Matrix.getA, Matrix.setA, .{});
    pub const b = bridge.accessor(Matrix.getB, Matrix.setB, .{});
    pub const c = bridge.accessor(Matrix.getC, Matrix.setC, .{});
    pub const d = bridge.accessor(Matrix.getD, Matrix.setD, .{});
    pub const e = bridge.accessor(Matrix.getE, Matrix.setE, .{});
    pub const f = bridge.accessor(Matrix.getF, Matrix.setF, .{});

    pub const flipX = bridge.function(Matrix.flipX, .{});
    pub const flipY = bridge.function(Matrix.flipY, .{});
    pub const inverse = bridge.function(Matrix.inverse, .{});
    pub const multiply = bridge.function(Matrix.multiply, .{});
    pub const rotate = bridge.function(Matrix.rotate, .{});
    pub const rotateFromVector = bridge.function(Matrix.rotateFromVector, .{});
    pub const scale = bridge.function(Matrix.scale, .{});
    pub const scaleNonUniform = bridge.function(Matrix.scaleNonUniform, .{});
    pub const skewX = bridge.function(Matrix.skewX, .{});
    pub const skewY = bridge.function(Matrix.skewY, .{});
    pub const translate = bridge.function(Matrix.translate, .{});
};
