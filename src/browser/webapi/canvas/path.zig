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

// The geometry half of the 2D context: the current transformation matrix, and
// the path being built under it.
//
// Both context types build a path the same way and neither of them had one, so
// the code lives here rather than twice over in
// `CanvasRenderingContext2D.zig` and `OffscreenCanvasRenderingContext2D.zig`.
//
// Everything is flattened to line segments as it arrives. Curves are
// subdivided at construction time, arcs are stepped, and the current transform
// is applied to each point as it is appended — which is what the spec asks for
// anyway: a path records device-space points, so a `scale()` between two
// `lineTo` calls affects only the second. Keeping a curve as a curve would buy
// nothing, because the rasteriser walks edges.
//
// The flattening tolerance is fixed rather than adaptive to the transform.
// Canvases that get fingerprinted are tens of pixels across, and at that size
// the step counts below are already finer than a pixel.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The 2x3 affine the spec calls the current transformation matrix, in the
/// same field order `DOMMatrix` reports: `[a c e; b d f]`.
pub const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Transform = .{};

    pub fn apply(self: Transform, x: f64, y: f64) Point {
        return .{
            .x = self.a * x + self.c * y + self.e,
            .y = self.b * x + self.d * y + self.f,
        };
    }

    /// `self` then `other` — that is, `other`'s coordinates are mapped through
    /// `self`, which is the direction `scale()` and `translate()` compose in.
    pub fn multiply(self: Transform, other: Transform) Transform {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .e = self.a * other.e + self.c * other.f + self.e,
            .f = self.b * other.e + self.d * other.f + self.f,
        };
    }

    pub fn translated(self: Transform, tx: f64, ty: f64) Transform {
        return self.multiply(.{ .e = tx, .f = ty });
    }

    pub fn scaled(self: Transform, sx: f64, sy: f64) Transform {
        return self.multiply(.{ .a = sx, .d = sy });
    }

    pub fn rotated(self: Transform, radians: f64) Transform {
        const cos = @cos(radians);
        const sin = @sin(radians);
        return self.multiply(.{ .a = cos, .b = sin, .c = -sin, .d = cos });
    }

    pub fn isFinite(self: Transform) bool {
        inline for (.{ self.a, self.b, self.c, self.d, self.e, self.f }) |v| {
            if (!std.math.isFinite(v)) return false;
        }
        return true;
    }

    /// The average of the two axis scales, which is what a stroke width has to
    /// be multiplied by. A non-uniform scale makes a stroke elliptical rather
    /// than uniformly wide, and this does not model that.
    pub fn meanScale(self: Transform) f64 {
        const sx = @sqrt(self.a * self.a + self.b * self.b);
        const sy = @sqrt(self.c * self.c + self.d * self.d);
        return (sx + sy) / 2;
    }
};

pub const Point = struct {
    x: f64,
    y: f64,
};

/// Which of the two winding rules `fill()` was asked for.
pub const FillRule = enum {
    nonzero,
    evenodd,

    /// Chrome throws a TypeError on anything else; callers decide whether to.
    pub fn parse(name: []const u8) ?FillRule {
        if (std.mem.eql(u8, name, "nonzero")) return .nonzero;
        if (std.mem.eql(u8, name, "evenodd")) return .evenodd;
        return null;
    }
};

/// Segments a cubic or quadratic is split into. Fixed, see the file comment.
const curve_steps = 24;
/// Segments a full turn of an arc or ellipse is split into.
const arc_steps = 64;

/// One `moveTo`-rooted run of points, in device space.
pub const Subpath = struct {
    points: std.ArrayList(Point) = .empty,
    /// `closePath` was called, so the rasteriser should join last to first for
    /// stroking. Filling always closes implicitly.
    closed: bool = false,
};

pub const Path = struct {
    subpaths: std.ArrayList(Subpath) = .empty,
    /// Where the next `lineTo` starts from, in *user* space — the spec keeps
    /// the current point untransformed so a later transform change does not
    /// retroactively move it.
    current: ?Point = null,
    /// Where the current subpath began, for `closePath`.
    start: ?Point = null,

    /// Drops every subpath but keeps the allocations: a page that rebuilds a
    /// path in a loop then costs the arena nothing after the first pass.
    pub fn begin(self: *Path) void {
        for (self.subpaths.items) |*sub| {
            sub.points.clearRetainingCapacity();
        }
        self.subpaths.clearRetainingCapacity();
        self.current = null;
        self.start = null;
    }

    pub fn isEmpty(self: *const Path) bool {
        for (self.subpaths.items) |sub| {
            if (sub.points.items.len >= 2) return false;
        }
        return true;
    }

    fn open(self: *Path, arena: Allocator, at: Point, ctm: Transform) !void {
        try self.subpaths.append(arena, .{});
        const sub = &self.subpaths.items[self.subpaths.items.len - 1];
        try sub.points.append(arena, ctm.apply(at.x, at.y));
        self.current = at;
        self.start = at;
    }

    fn push(self: *Path, arena: Allocator, at: Point, ctm: Transform) !void {
        if (self.subpaths.items.len == 0) {
            return self.open(arena, at, ctm);
        }
        const sub = &self.subpaths.items[self.subpaths.items.len - 1];
        if (sub.closed) {
            return self.open(arena, at, ctm);
        }
        try sub.points.append(arena, ctm.apply(at.x, at.y));
        self.current = at;
    }

    pub fn moveTo(self: *Path, arena: Allocator, x: f64, y: f64, ctm: Transform) !void {
        if (!finite2(x, y)) return;
        try self.open(arena, .{ .x = x, .y = y }, ctm);
    }

    pub fn lineTo(self: *Path, arena: Allocator, x: f64, y: f64, ctm: Transform) !void {
        if (!finite2(x, y)) return;
        // A lineTo with no current point is a moveTo, per the spec.
        try self.push(arena, .{ .x = x, .y = y }, ctm);
    }

    /// Marks the subpath closed. The current point returns to where that
    /// subpath began, and the next `lineTo` opens a fresh subpath from there.
    pub fn closePath(self: *Path) void {
        if (self.subpaths.items.len == 0) return;
        const sub = &self.subpaths.items[self.subpaths.items.len - 1];
        if (sub.points.items.len == 0) return;
        sub.closed = true;
        self.current = self.start;
    }

    pub fn quadraticCurveTo(self: *Path, arena: Allocator, cx: f64, cy: f64, x: f64, y: f64, ctm: Transform) !void {
        if (!finite2(cx, cy) or !finite2(x, y)) return;
        const from = self.current orelse blk: {
            try self.open(arena, .{ .x = cx, .y = cy }, ctm);
            break :blk Point{ .x = cx, .y = cy };
        };
        var i: usize = 1;
        while (i <= curve_steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / curve_steps;
            const u = 1 - t;
            try self.push(arena, .{
                .x = u * u * from.x + 2 * u * t * cx + t * t * x,
                .y = u * u * from.y + 2 * u * t * cy + t * t * y,
            }, ctm);
        }
        self.current = .{ .x = x, .y = y };
    }

    pub fn bezierCurveTo(self: *Path, arena: Allocator, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64, ctm: Transform) !void {
        if (!finite2(c1x, c1y) or !finite2(c2x, c2y) or !finite2(x, y)) return;
        const from = self.current orelse blk: {
            try self.open(arena, .{ .x = c1x, .y = c1y }, ctm);
            break :blk Point{ .x = c1x, .y = c1y };
        };
        var i: usize = 1;
        while (i <= curve_steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / curve_steps;
            const u = 1 - t;
            const uu = u * u;
            const tt = t * t;
            try self.push(arena, .{
                .x = uu * u * from.x + 3 * uu * t * c1x + 3 * u * tt * c2x + tt * t * x,
                .y = uu * u * from.y + 3 * uu * t * c1y + 3 * u * tt * c2y + tt * t * y,
            }, ctm);
        }
        self.current = .{ .x = x, .y = y };
    }

    pub fn arc(self: *Path, arena: Allocator, x: f64, y: f64, radius: f64, start_angle: f64, end_angle: f64, counterclockwise: bool, ctm: Transform) !void {
        return self.ellipse(arena, x, y, radius, radius, 0, start_angle, end_angle, counterclockwise, ctm);
    }

    pub fn ellipse(self: *Path, arena: Allocator, x: f64, y: f64, rx: f64, ry: f64, rotation: f64, start_angle: f64, end_angle: f64, counterclockwise: bool, ctm: Transform) !void {
        if (!finite2(x, y) or !finite2(rx, ry) or !std.math.isFinite(rotation)) return;
        if (!finite2(start_angle, end_angle)) return;
        if (rx < 0 or ry < 0) return;

        // The sweep, normalised the way Chrome 151 normalises it (measured —
        // see the `arc counterclockwise` block in the 2D context's tests for
        // the ten readings this reproduces).
        //
        // A sweep that runs against the requested direction wraps by whole
        // turns until it agrees with it, and a sweep of exactly one turn
        // against the direction becomes a whole turn rather than nothing —
        // which is what `arc(…, 0, 2 * Math.PI, true)` is, and what the
        // Turnstile widget draws every one of its circles with. A sweep past a
        // full turn *with* the direction clamps to one turn; against it, it
        // wraps. Only two angles that are exactly equal draw nothing.
        var sweep = end_angle - start_angle;
        const tau = std.math.tau;
        if (counterclockwise) {
            if (sweep > 0) {
                sweep = @rem(sweep, tau) - tau;
            } else if (sweep < -tau) {
                sweep = -tau;
            }
        } else {
            if (sweep < 0) {
                sweep = @rem(sweep, tau) + tau;
            } else if (sweep > tau) {
                sweep = tau;
            }
        }

        const cos_r = @cos(rotation);
        const sin_r = @sin(rotation);
        const at = struct {
            fn point(cx: f64, cy: f64, a: f64, b: f64, cr: f64, sr: f64, angle: f64) Point {
                const px = a * @cos(angle);
                const py = b * @sin(angle);
                return .{ .x = cx + px * cr - py * sr, .y = cy + px * sr + py * cr };
            }
        }.point;

        // An arc joins the current point with a straight line before it starts,
        // which is why two concentric arcs in one path are one shape.
        const first = at(x, y, rx, ry, cos_r, sin_r, start_angle);
        if (self.current == null) {
            try self.open(arena, first, ctm);
        } else {
            try self.push(arena, first, ctm);
        }

        const steps: usize = @max(2, @as(usize, @intFromFloat(@ceil(@abs(sweep) / tau * arc_steps))));
        var i: usize = 1;
        while (i <= steps) : (i += 1) {
            const angle = start_angle + sweep * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            try self.push(arena, at(x, y, rx, ry, cos_r, sin_r, angle), ctm);
        }
    }

    /// `arcTo` as the spec defines it: the arc of `radius` tangent to both the
    /// line from the current point to the first control point and the line
    /// between the two control points.
    pub fn arcTo(self: *Path, arena: Allocator, x1: f64, y1: f64, x2: f64, y2: f64, radius: f64, ctm: Transform) !void {
        if (!finite2(x1, y1) or !finite2(x2, y2) or !std.math.isFinite(radius)) return;
        if (radius < 0) return;
        const from = self.current orelse {
            try self.open(arena, .{ .x = x1, .y = y1 }, ctm);
            return;
        };

        const a = std.math.atan2(from.y - y1, from.x - x1);
        const b = std.math.atan2(y2 - y1, x2 - x1);
        var between = b - a;
        while (between <= -std.math.pi) between += std.math.tau;
        while (between > std.math.pi) between -= std.math.tau;
        const half = between / 2;
        // Degenerate corners collapse to a line, which is what Chrome draws.
        if (radius == 0 or @abs(@sin(half)) < 1e-9) {
            try self.push(arena, .{ .x = x1, .y = y1 }, ctm);
            return;
        }

        const dist = radius / @abs(@tan(half));
        const start = Point{ .x = x1 + dist * @cos(a), .y = y1 + dist * @sin(a) };
        const end = Point{ .x = x1 + dist * @cos(b), .y = y1 + dist * @sin(b) };
        const away = radius / @abs(@sin(half));
        const bisector = a + half;
        const centre = Point{ .x = x1 + away * @cos(bisector), .y = y1 + away * @sin(bisector) };

        try self.push(arena, start, ctm);
        const from_angle = std.math.atan2(start.y - centre.y, start.x - centre.x);
        const to_angle = std.math.atan2(end.y - centre.y, end.x - centre.x);
        try self.ellipse(arena, centre.x, centre.y, radius, radius, 0, from_angle, to_angle, between > 0, ctm);
    }

    /// A rectangle is its own closed subpath, and it leaves the current point
    /// at its origin.
    pub fn rect(self: *Path, arena: Allocator, x: f64, y: f64, w: f64, h: f64, ctm: Transform) !void {
        if (!finite2(x, y) or !finite2(w, h)) return;
        try self.open(arena, .{ .x = x, .y = y }, ctm);
        try self.push(arena, .{ .x = x + w, .y = y }, ctm);
        try self.push(arena, .{ .x = x + w, .y = y + h }, ctm);
        try self.push(arena, .{ .x = x, .y = y + h }, ctm);
        const sub = &self.subpaths.items[self.subpaths.items.len - 1];
        sub.closed = true;
        self.current = .{ .x = x, .y = y };
        self.start = self.current;
    }

    /// The four corner radii the spec allows, already resolved to one number
    /// each by the caller.
    pub fn roundRect(self: *Path, arena: Allocator, x: f64, y: f64, w: f64, h: f64, radii: [4]f64, ctm: Transform) !void {
        if (!finite2(x, y) or !finite2(w, h)) return;
        const half_w = @abs(w) / 2;
        const half_h = @abs(h) / 2;
        var r: [4]f64 = radii;
        for (&r) |*v| {
            if (!std.math.isFinite(v.*) or v.* < 0) v.* = 0;
            v.* = @min(v.*, @min(half_w, half_h));
        }

        const left = @min(x, x + w);
        const right = @max(x, x + w);
        const top = @min(y, y + h);
        const bottom = @max(y, y + h);
        const pi: f64 = std.math.pi;
        const quarter = pi / 2.0;

        try self.open(arena, .{ .x = left + r[0], .y = top }, ctm);
        try self.push(arena, .{ .x = right - r[1], .y = top }, ctm);
        try self.ellipse(arena, right - r[1], top + r[1], r[1], r[1], 0, -quarter, 0, false, ctm);
        try self.push(arena, .{ .x = right, .y = bottom - r[2] }, ctm);
        try self.ellipse(arena, right - r[2], bottom - r[2], r[2], r[2], 0, 0, quarter, false, ctm);
        try self.push(arena, .{ .x = left + r[3], .y = bottom }, ctm);
        try self.ellipse(arena, left + r[3], bottom - r[3], r[3], r[3], 0, quarter, pi, false, ctm);
        try self.push(arena, .{ .x = left, .y = top + r[0] }, ctm);
        try self.ellipse(arena, left + r[0], top + r[0], r[0], r[0], 0, pi, 3.0 * quarter, false, ctm);

        const sub = &self.subpaths.items[self.subpaths.items.len - 1];
        sub.closed = true;
        self.current = .{ .x = left + r[0], .y = top };
        self.start = self.current;
    }
};

fn finite2(a: f64, b: f64) bool {
    return std.math.isFinite(a) and std.math.isFinite(b);
}

const testing = std.testing;

test "path: the transform is applied as points are appended" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var p: Path = .{};
    try p.moveTo(arena.allocator(), 1, 1, Transform.identity);
    // A scale between two appends only moves the second one.
    try p.lineTo(arena.allocator(), 2, 2, Transform.identity.scaled(3, 3));

    const points = p.subpaths.items[0].points.items;
    try testing.expectEqual(@as(f64, 1), points[0].x);
    try testing.expectEqual(@as(f64, 6), points[1].x);
}

test "path: a rect is a closed subpath of four corners" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var p: Path = .{};
    try p.rect(arena.allocator(), 0, 0, 2, 4, Transform.identity);
    try testing.expectEqual(@as(usize, 1), p.subpaths.items.len);
    try testing.expectEqual(@as(usize, 4), p.subpaths.items[0].points.items.len);
    try testing.expect(p.subpaths.items[0].closed);

    // begin() drops the subpaths without giving the memory back.
    p.begin();
    try testing.expect(p.isEmpty());
}

test "path: a full circle closes on its own start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var p: Path = .{};
    try p.arc(arena.allocator(), 10, 10, 5, 0, std.math.tau, false, Transform.identity);
    const points = p.subpaths.items[0].points.items;
    try testing.expect(points.len > 16);
    try testing.expectApproxEqAbs(points[0].x, points[points.len - 1].x, 1e-9);
    try testing.expectApproxEqAbs(points[0].y, points[points.len - 1].y, 1e-9);
}

test "path: a counterclockwise turn of exactly tau is a whole circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Measured against Chrome 151: arc(0, 2pi, true) fills the same disc as
    // arc(0, 2pi), rather than the nothing a naive `sweep - tau` gives.
    var ccw: Path = .{};
    try ccw.arc(alloc, 0, 0, 1, 0, std.math.tau, true, Transform.identity);
    var cw: Path = .{};
    try cw.arc(alloc, 0, 0, 1, 0, std.math.tau, false, Transform.identity);
    try testing.expectEqual(cw.subpaths.items[0].points.items.len, ccw.subpaths.items[0].points.items.len);

    // And a turn and a half against the direction wraps rather than clamping:
    // 3pi counterclockwise is half a turn, not a whole one.
    var three: Path = .{};
    try three.arc(alloc, 0, 0, 1, 0, 3 * std.math.pi, true, Transform.identity);
    var half: Path = .{};
    try half.arc(alloc, 0, 0, 1, 0, -std.math.pi, true, Transform.identity);
    try testing.expectEqual(half.subpaths.items[0].points.items.len, three.subpaths.items[0].points.items.len);
}
