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
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const Matrix = @import("Matrix.zig");
const RO = @import("../DOMMatrixReadOnly.zig");

const Transform = @This();

_type: u16 = 1,
_angle: f64 = 0,
_cx: f64 = 0,
_cy: f64 = 0,
_matrix: *Matrix,
_attachment: ?Attachment = null,

// Sticky. An animVal item that a later external attribute change detaches from
// its list must not turn into a writable orphan.
_read_only: bool = false,

pub const State = struct {
    typ: u16,
    angle: f64,
    cx: f64,
    cy: f64,
    matrix: [16]f64,
    is_2d: bool,
};

pub const Attachment = struct {
    owner: *anyopaque,
    mutate: *const fn (*anyopaque, *Transform, State) anyerror!void,
};

// The transform lives in the matrix arena and owns it even when no JS wrapper
// currently references `matrix`. Forwarding the transform's bridge lifetime
// keeps the stable SameObject pointer valid across garbage collections, and
// releasing the last ref frees the transform together with its matrix.
pub fn acquireRef(self: *Transform) void {
    self._matrix.acquireRef();
}

pub fn releaseRef(self: *Transform, page: *Page) void {
    self._matrix.releaseRef(page);
}

pub fn detached(frame: *Frame) !*Transform {
    return build(.{}, .{}, frame);
}

pub fn fromMatrix(source: *const Matrix, frame: *Frame) !*Transform {
    return build(.{}, source.value(), frame);
}

fn build(fields: Fields, value: Matrix.Value, frame: *Frame) !*Transform {
    const matrix = try Matrix.create(value, frame._page);
    errdefer matrix.deinit(frame._page);
    const self = try matrix._arena.create(Transform);
    self.* = .{
        ._type = fields.typ,
        ._angle = fields.angle,
        ._cx = fields.cx,
        ._cy = fields.cy,
        ._matrix = matrix,
    };
    self.attachMatrix();
    return self;
}

const Fields = struct {
    typ: u16 = 1,
    angle: f64 = 0,
    cx: f64 = 0,
    cy: f64 = 0,
};

pub fn fromParsed(parsed: RO.ParsedTransform, frame: *Frame) !*Transform {
    const typ: u16 = switch (parsed.kind) {
        .matrix => 1,
        .translate => 2,
        .scale => 3,
        .rotate => 4,
        .skew_x => 5,
        .skew_y => 6,
        else => return error.SyntaxError,
    };
    return build(.{
        .typ = typ,
        .angle = if (typ >= 4) parsed.values[0] else 0,
        .cx = if (typ == 4 and parsed.count == 3) parsed.values[1] else 0,
        .cy = if (typ == 4 and parsed.count == 3) parsed.values[2] else 0,
    }, toValue(parsed.matrix), frame);
}

pub fn clone(self: *const Transform, frame: *Frame) !*Transform {
    const current = self.getState();
    return build(.{
        .typ = current.typ,
        .angle = current.angle,
        .cx = current.cx,
        .cy = current.cy,
    }, toValue(current.matrix), frame);
}

pub fn getType(self: *const Transform) u16 {
    return self._type;
}

pub fn getMatrix(self: *Transform) *Matrix {
    return self._matrix;
}

pub fn getAngle(self: *const Transform) f64 {
    return self._angle;
}

pub fn setMatrix(self: *Transform, source: *const Matrix) !void {
    try self.applyState(.{ .typ = 1, .angle = 0, .cx = 0, .cy = 0, .matrix = fromValue(source.value()), .is_2d = true });
}

pub fn setTranslate(self: *Transform, tx: f64, ty: f64) !void {
    try ensureFinite(&.{ tx, ty });
    try self.applyState(.{ .typ = 2, .angle = 0, .cx = 0, .cy = 0, .matrix = RO.translationMatrix(tx, ty, 0), .is_2d = true });
}

pub fn setScale(self: *Transform, sx: f64, sy: f64) !void {
    try ensureFinite(&.{ sx, sy });
    try self.applyState(.{ .typ = 3, .angle = 0, .cx = 0, .cy = 0, .matrix = RO.scaleMatrix(sx, sy, 1), .is_2d = true });
}

pub fn setRotate(self: *Transform, angle: f64, cx: f64, cy: f64) !void {
    try ensureFinite(&.{ angle, cx, cy });
    const radians = angle * Matrix.DEGREES_TO_RADIANS;
    var matrix = RO.translationMatrix(cx, cy, 0);
    matrix = RO.multiplyMatrix(matrix, RO.rotateZMatrix(radians));
    matrix = RO.multiplyMatrix(matrix, RO.translationMatrix(-cx, -cy, 0));
    try self.applyState(.{ .typ = 4, .angle = angle, .cx = cx, .cy = cy, .matrix = matrix, .is_2d = true });
}

pub fn setSkewX(self: *Transform, angle: f64) !void {
    try ensureFinite(&.{angle});
    try self.applyState(.{ .typ = 5, .angle = angle, .cx = 0, .cy = 0, .matrix = RO.skewMatrix(angle * Matrix.DEGREES_TO_RADIANS, 0), .is_2d = true });
}

pub fn setSkewY(self: *Transform, angle: f64) !void {
    try ensureFinite(&.{angle});
    try self.applyState(.{ .typ = 6, .angle = angle, .cx = 0, .cy = 0, .matrix = RO.skewMatrix(0, angle * Matrix.DEGREES_TO_RADIANS), .is_2d = true });
}

pub fn getState(self: *const Transform) State {
    return .{
        .typ = self._type,
        .angle = self._angle,
        .cx = self._cx,
        .cy = self._cy,
        .matrix = fromValue(self._matrix.value()),
        .is_2d = true,
    };
}

pub fn applyStateRaw(self: *Transform, state: State) void {
    self._type = state.typ;
    self._angle = state.angle;
    self._cx = state.cx;
    self._cy = state.cy;
    self._matrix.applyValueRaw(toValue(state.matrix));
}

fn applyState(self: *Transform, state: State) !void {
    if (self._read_only) return error.NoModificationAllowed;
    try ensureFinite(&state.matrix);
    if (self._attachment) |attachment| {
        return attachment.mutate(attachment.owner, self, state);
    }
    self.applyStateRaw(state);
}

pub fn attach(self: *Transform, attachment: Attachment, read_only: bool) void {
    self._attachment = attachment;
    if (read_only) self._read_only = true;
}

pub fn detach(self: *Transform, owner: *anyopaque) void {
    const attachment = self._attachment orelse return;
    if (attachment.owner == owner) self._attachment = null;
}

pub fn isAttached(self: *const Transform) bool {
    return self._attachment != null;
}

pub fn isAttachedTo(self: *const Transform, owner: *anyopaque) bool {
    const attachment = self._attachment orelse return false;
    return attachment.owner == owner;
}

pub fn writeState(state: State, writer: anytype) !void {
    switch (state.typ) {
        1 => try writer.print("matrix({d} {d} {d} {d} {d} {d})", .{
            state.matrix[0], state.matrix[1], state.matrix[4], state.matrix[5], state.matrix[12], state.matrix[13],
        }),
        2 => try writer.print("translate({d} {d})", .{ state.matrix[12], state.matrix[13] }),
        3 => try writer.print("scale({d} {d})", .{ state.matrix[0], state.matrix[5] }),
        4 => if (state.cx == 0 and state.cy == 0)
            try writer.print("rotate({d})", .{state.angle})
        else
            try writer.print("rotate({d} {d} {d})", .{ state.angle, state.cx, state.cy }),
        5 => try writer.print("skewX({d})", .{state.angle}),
        6 => try writer.print("skewY({d})", .{state.angle}),
        else => return error.SyntaxError,
    }
}

fn attachMatrix(self: *Transform) void {
    self._matrix.attach(.{
        .owner = self,
        .mutate = Transform.mutateMatrix,
    });
}

fn toValue(m: [16]f64) Matrix.Value {
    return .{ .a = m[0], .b = m[1], .c = m[4], .d = m[5], .e = m[12], .f = m[13] };
}

fn fromValue(v: Matrix.Value) [16]f64 {
    return .{
        v.a, v.b, 0, 0,
        v.c, v.d, 0, 0,
        0,   0,   1, 0,
        v.e, v.f, 0, 1,
    };
}

// An SVGTransform is a 2D affine transform, and the `transform` attribute has
// no syntax for anything else, so a write through the live matrix keeps only
// the six components the transform can represent.
fn mutateMatrix(context: *anyopaque, _: *Matrix, value: Matrix.Value) anyerror!void {
    const self: *Transform = @ptrCast(@alignCast(context));
    try self.applyState(.{
        .typ = 1,
        .angle = 0,
        .cx = 0,
        .cy = 0,
        .matrix = fromValue(value),
        .is_2d = true,
    });
}

fn ensureFinite(values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.TypeError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Transform);

    pub const Meta = struct {
        pub const name = "SVGTransform";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_TRANSFORM_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_TRANSFORM_MATRIX = bridge.property(1, .{ .template = true });
    pub const SVG_TRANSFORM_TRANSLATE = bridge.property(2, .{ .template = true });
    pub const SVG_TRANSFORM_SCALE = bridge.property(3, .{ .template = true });
    pub const SVG_TRANSFORM_ROTATE = bridge.property(4, .{ .template = true });
    pub const SVG_TRANSFORM_SKEWX = bridge.property(5, .{ .template = true });
    pub const SVG_TRANSFORM_SKEWY = bridge.property(6, .{ .template = true });

    pub const @"type" = bridge.accessor(Transform.getType, null, .{});
    pub const matrix = bridge.accessor(Transform.getMatrix, null, .{});
    pub const angle = bridge.accessor(Transform.getAngle, null, .{});
    pub const setMatrix = bridge.function(Transform.setMatrix, .{});
    pub const setTranslate = bridge.function(Transform.setTranslate, .{});
    pub const setScale = bridge.function(Transform.setScale, .{});
    pub const setRotate = bridge.function(Transform.setRotate, .{});
    pub const setSkewX = bridge.function(Transform.setSkewX, .{});
    pub const setSkewY = bridge.function(Transform.setSkewY, .{});
};
