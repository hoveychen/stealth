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

// The fourth member of the geometry set, next to DOMPoint, DOMRect and
// DOMMatrix. It is a plain value type -- four points and the arithmetic over
// them -- so unlike most of what a headless engine stubs, this one is the real
// thing: nothing here needs a layout box.
//
// Every default and every bound below was read off a headed Chrome 150; see
// tools/fingerprint/scratch/win-batch/probe-win29.js and
// win29-chrome.json.

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Factory = @import("../Factory.zig");
const DOMPoint = @import("DOMPoint.zig");
const DOMRect = @import("DOMRect.zig");
const DOMRectReadOnly = @import("DOMRectReadOnly.zig");
const DOMPointReadOnly = @import("DOMPointReadOnly.zig");

const DOMQuad = @This();

const PointInit = DOMPointReadOnly.DOMPointInit;

_rc: lp.RC = .{},
_arena: *lp.Arena,
_p1: *DOMPoint,
_p2: *DOMPoint,
_p3: *DOMPoint,
_p4: *DOMPoint,

// The four points are reference-counted (a DOMPoint holds its own arena), and
// three of them are usually never handed to JS -- a script that only reads
// getBounds() never touches p2. So the quad owns a reference to each and drops
// them when its own wrapper goes away.
pub fn deinit(self: *DOMQuad, page: *Page) void {
    for ([_]*DOMPoint{ self._p1, self._p2, self._p3, self._p4 }) |point| {
        point._proto.releaseRef(page);
    }
    self._arena.release();
}

pub fn acquireRef(self: *DOMQuad) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *DOMQuad, page: *Page) void {
    self._rc.release(self, page);
}

// Measured: `new DOMQuad()` gives four points at (0, 0, 0, 1) -- the w of 1 is
// DOMPointInit's own default, not a quad rule -- and a missing argument is the
// same as an empty dictionary.
pub fn init(p1_: ?PointInit, p2_: ?PointInit, p3_: ?PointInit, p4_: ?PointInit, page: *Page) !*DOMQuad {
    return create(p1_ orelse .{}, p2_ orelse .{}, p3_ orelse .{}, p4_ orelse .{}, page);
}

fn create(p1: PointInit, p2: PointInit, p3: PointInit, p4: PointInit, page: *Page) !*DOMQuad {
    const arena = try page.getArena(.tiny, "DOMQuad");
    errdefer arena.release();

    const self = try arena.create(DOMQuad);
    self.* = .{
        ._arena = arena,
        ._p1 = try DOMPoint.create(p1.x, p1.y, p1.z, p1.w, page),
        ._p2 = try DOMPoint.create(p2.x, p2.y, p2.z, p2.w, page),
        ._p3 = try DOMPoint.create(p3.x, p3.y, p3.z, p3.w, page),
        ._p4 = try DOMPoint.create(p4.x, p4.y, p4.z, p4.w, page),
    };
    for ([_]*DOMPoint{ self._p1, self._p2, self._p3, self._p4 }) |point| {
        point._proto.acquireRef();
    }
    return self;
}

/// The rect's four corners, clockwise from its origin. Measured with
/// `DOMQuad.fromRect({x: 1, y: 2, width: 3, height: 4})`: p1 (1, 2),
/// p2 (4, 2), p3 (4, 6), p4 (1, 6).
pub fn fromRect(other_: ?DOMRectReadOnly.Data, page: *Page) !*DOMQuad {
    const r: DOMRectReadOnly.Data = other_ orelse .{};
    return create(
        .{ .x = r.x, .y = r.y },
        .{ .x = r.x + r.width, .y = r.y },
        .{ .x = r.x + r.width, .y = r.y + r.height },
        .{ .x = r.x, .y = r.y + r.height },
        page,
    );
}

const QuadInit = struct {
    p1: PointInit = .{},
    p2: PointInit = .{},
    p3: PointInit = .{},
    p4: PointInit = .{},
};

/// Measured: members left out of the dictionary are (0, 0, 0, 1), so
/// `DOMQuad.fromQuad({p1: {x: 5, y: 6}})` leaves p2 at the origin -- the
/// points are read independently, not derived from p1.
pub fn fromQuad(other_: ?QuadInit, page: *Page) !*DOMQuad {
    const q: QuadInit = other_ orelse .{};
    return create(q.p1, q.p2, q.p3, q.p4, page);
}

pub fn getP1(self: *const DOMQuad) *DOMPoint {
    return self._p1;
}

pub fn getP2(self: *const DOMQuad) *DOMPoint {
    return self._p2;
}

pub fn getP3(self: *const DOMQuad) *DOMPoint {
    return self._p3;
}

pub fn getP4(self: *const DOMQuad) *DOMPoint {
    return self._p4;
}

/// The axis-aligned box around the four points. Measured with a rect built
/// from a negative width and height: the bounds are normalised, so
/// `DOMQuad.fromRect({x: 5, y: 5, width: -3, height: -4}).getBounds()` is
/// {x: 2, y: 1, width: 3, height: 4}.
pub fn getBounds(self: *const DOMQuad, page: *Page) !*DOMRect {
    var left = self._p1._proto._x;
    var right = left;
    var top = self._p1._proto._y;
    var bottom = top;

    for ([_]*DOMPoint{ self._p2, self._p3, self._p4 }) |point| {
        const x = point._proto._x;
        const y = point._proto._y;
        left = @min(left, x);
        right = @max(right, x);
        top = @min(top, y);
        bottom = @max(bottom, y);
    }

    return page.factory.domRect(.{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    });
}

/// The four points themselves, not copies: JSON.stringify of the result is the
/// same shape Chrome produces because DOMPoint carries its own toJSON.
pub fn toJSON(self: *const DOMQuad, exec: *const js.Execution) !js.Object {
    const object = exec.js.local.?.newObject();
    _ = try object.set("p1", self._p1, .{});
    _ = try object.set("p2", self._p2, .{});
    _ = try object.set("p3", self._p3, .{});
    _ = try object.set("p4", self._p4, .{});
    return object;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMQuad);

    pub const Meta = struct {
        pub const name = "DOMQuad";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Measured: both statics report arity 0 -- their dictionary is optional.
    pub const constructor = bridge.constructor(DOMQuad.init, .{});
    pub const fromQuad = bridge.function(DOMQuad.fromQuad, .{ .static = true });
    pub const fromRect = bridge.function(DOMQuad.fromRect, .{ .static = true });
    pub const p1 = bridge.accessor(DOMQuad.getP1, null, .{});
    pub const p2 = bridge.accessor(DOMQuad.getP2, null, .{});
    pub const p3 = bridge.accessor(DOMQuad.getP3, null, .{});
    pub const p4 = bridge.accessor(DOMQuad.getP4, null, .{});
    pub const getBounds = bridge.function(DOMQuad.getBounds, .{});
    pub const toJSON = bridge.function(DOMQuad.toJSON, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMQuad" {
    try testing.htmlRunner("domquad.html", .{});
}
