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

// WebXR's geometry: the two types a page can construct outright, and the
// read-only ones a session hands back. All of it measured on a headed Chrome
// 150 at http://localhost (WebXR is [SecureContext], and localhost counts) --
// see tools/fingerprint/results/probes/win52-findings.md.
//
// Two things here are worth stating up front, because neither is in the spec
// and both are readable from script:
//
//   - XRRigidTransform normalises its orientation in *double* precision while
//     XRRay normalises its direction in *float32*. Measured on the same page:
//     `new XRRigidTransform({}, {x:3,y:0,z:4}).orientation.x` is 0.6, and
//     `new XRRay({}, {x:0,y:3,z:4}).direction.y` is 0.6000000238418579.
//   - Every accessor that returns an object returns the *same* object each
//     time (`t.position === t.position`), and `t.inverse.inverse === t` is the
//     original object rather than a rebuilt equal one.
//
// The refusals are all Chrome's wording, including the two that are not
// TypeErrors: a zero-length orientation is an InvalidStateError, and XRRay's
// two component complaints keep Blink's `1.0f!` spelling.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const dictionary = @import("../dictionary.zig");
const DOMPointReadOnly = @import("../DOMPointReadOnly.zig");

const Execution = js.Execution;
const Float32Array = js.ArrayBufferRef(.float32);

pub fn registerTypes() []const type {
    return &.{
        XRCamera,
        XRPose,
        XRRay,
        XRRigidTransform,
        XRView,
        XRViewerPose,
        XRViewport,
        XRJointPose,
    };
}

/// A 4x4 column-major matrix as Chrome hands it out: a Float32Array whose
/// identity is stable for the life of the object holding it.
fn persistMatrix(m: [16]f64, exec: *const Execution) !Float32Array.Global {
    const local = exec.js.local.?;
    const array = local.createTypedArray(.float32, 16);
    const into = array.slice();
    for (m, 0..) |value, i| {
        into[i] = @floatCast(value);
    }
    return array.persist();
}

/// A DOMPointReadOnly held by an XR object for that object's whole life, laid
/// down in that object's own arena.
///
/// Both halves matter. The ref keeps V8 from freeing the point the first time
/// it collects a wrapper the page was handed, while this struct still points
/// at it -- Chrome's `t.position === t.position` means the same object comes
/// back every time, so it has to outlive any one wrapper. Putting it in the
/// holder's arena rather than in one of its own is what keeps that ref from
/// becoming a leak: the point's own `deinit` never runs (its count never
/// reaches zero), and its memory goes when the holder releases the single
/// arena they share.
fn ownedPoint(arena: *lp.Arena, x: f64, y: f64, z: f64, w: f64) !*DOMPointReadOnly {
    const point = try arena.create(DOMPointReadOnly);
    point.* = DOMPointReadOnly.buildValue(x, y, z, w);
    point.acquireRef();
    return point;
}

/// The four members of a DOMPointInit, read raw. `dictionary.double` is not
/// usable here: it refuses a non-finite value with WebIDL's own wording, and
/// XRRigidTransform has its own message for that ("Position and Orientation
/// must consist of only finite values"), which it only reaches once every
/// member has been read.
fn readPoint(
    comptime Reader: type,
    value_: ?js.Value,
    default_w: f64,
    exec: *const Execution,
) ![4]f64 {
    const reader = try Reader.read(value_, exec);
    return .{
        try readComponent(Reader, reader, "x", 0, exec),
        try readComponent(Reader, reader, "y", 0, exec),
        try readComponent(Reader, reader, "z", 0, exec),
        try readComponent(Reader, reader, "w", default_w, exec),
    };
}

fn readComponent(
    comptime Reader: type,
    reader: Reader,
    comptime name: []const u8,
    default: f64,
    exec: *const Execution,
) !f64 {
    _ = exec;
    const member = (try reader.present(name)) orelse return default;
    return member.toF64() catch std.math.nan(f64);
}

/// The rotation half of a column-major 4x4, from a unit quaternion.
fn rotationInto(m: *[16]f64, x: f64, y: f64, z: f64, w: f64) void {
    m[0] = 1 - 2 * (y * y + z * z);
    m[1] = 2 * (x * y + z * w);
    m[2] = 2 * (x * z - y * w);
    m[3] = 0;
    m[4] = 2 * (x * y - z * w);
    m[5] = 1 - 2 * (x * x + z * z);
    m[6] = 2 * (y * z + x * w);
    m[7] = 0;
    m[8] = 2 * (x * z + y * w);
    m[9] = 2 * (y * z - x * w);
    m[10] = 1 - 2 * (x * x + y * y);
    m[11] = 0;
}

/// What a page builds to place something in a session's space, and the one XR
/// type with an `inverse` that round-trips back to the very object it came
/// from.
pub const XRRigidTransform = struct {
    // A transform and the inverse it hands out share one arena and one
    // refcount: each is reachable from the other, so neither can own the
    // other, and a pair of strong refs would keep both alive forever. `_root`
    // is whichever of the two acquired the arena; every acquire and release
    // goes through it, so the arena goes exactly when both wrappers have.
    _root: *XRRigidTransform,
    _rc: lp.RC = .{},
    _arena: *lp.Arena,

    _position: *DOMPointReadOnly,
    _orientation: *DOMPointReadOnly,
    _matrix: Float32Array.Global,
    // Filled the first time `inverse` is read. The inverse's own `_inverse`
    // points back here, which is what makes `t.inverse.inverse === t` hold.
    _inverse: ?*XRRigidTransform = null,

    const Point = dictionary.Reader("XRRigidTransform", "DOMPointInit");
    const NOT_FINITE = "Failed to construct 'XRRigidTransform': " ++
        "Position and Orientation must consist of only finite values";
    const BAD_W = "Failed to construct 'XRRigidTransform': W component of position must be 1.0";
    const ZERO_ORIENTATION = "Failed to construct 'XRRigidTransform': Orientation's length cannot be 0";

    pub fn constructor(
        position_: ?js.Value,
        orientation_: ?js.Value,
        exec: *const Execution,
    ) !*XRRigidTransform {
        const p = try readPoint(Point, position_, 1, exec);
        const o = try readPoint(Point, orientation_, 1, exec);

        for (p) |value| {
            if (!std.math.isFinite(value)) return dictionary.throwTypeError(NOT_FINITE, exec);
        }
        for (o) |value| {
            if (!std.math.isFinite(value)) return dictionary.throwTypeError(NOT_FINITE, exec);
        }
        if (p[3] != 1) return dictionary.throwTypeError(BAD_W, exec);

        const length = @sqrt(o[0] * o[0] + o[1] * o[1] + o[2] * o[2] + o[3] * o[3]);
        if (length == 0) {
            return dictionary.throwDom("InvalidStateError", ZERO_ORIENTATION, exec);
        }

        return build(
            .{ p[0], p[1], p[2] },
            .{ o[0] / length, o[1] / length, o[2] / length, o[3] / length },
            exec,
        );
    }

    /// A transform from an already-normalised quaternion, which is the form
    /// every internal caller has.
    pub fn build(position: [3]f64, orientation: [4]f64, exec: *const Execution) !*XRRigidTransform {
        const arena = try exec.page.getArena(.tiny, "XRRigidTransform");
        errdefer arena.release();
        const self = try arena.create(XRRigidTransform);
        try fill(self, arena, position, orientation, exec);
        self._root = self;
        return self;
    }

    /// The body of `build`, shared with the inverse -- which lives in the
    /// original's arena rather than acquiring one of its own.
    fn fill(
        self: *XRRigidTransform,
        arena: *lp.Arena,
        position: [3]f64,
        orientation: [4]f64,
        exec: *const Execution,
    ) !void {
        var m: [16]f64 = undefined;
        rotationInto(&m, orientation[0], orientation[1], orientation[2], orientation[3]);
        m[12] = position[0];
        m[13] = position[1];
        m[14] = position[2];
        m[15] = 1;

        self.* = .{
            ._root = undefined,
            ._arena = arena,
            ._position = try ownedPoint(arena, position[0], position[1], position[2], 1),
            ._orientation = try ownedPoint(
                arena,
                orientation[0],
                orientation[1],
                orientation[2],
                orientation[3],
            ),
            ._matrix = try persistMatrix(m, exec),
        };
    }

    pub fn identity(exec: *const Execution) !*XRRigidTransform {
        return build(.{ 0, 0, 0 }, .{ 0, 0, 0, 1 }, exec);
    }

    pub fn acquireRef(self: *XRRigidTransform) void {
        self._root._rc.acquire();
    }

    pub fn releaseRef(self: *XRRigidTransform, page: *Page) void {
        const root = self._root;
        root._rc.release(root, page);
    }

    pub fn deinit(self: *XRRigidTransform, _: *Page) void {
        self._arena.release();
    }

    pub fn getPosition(self: *const XRRigidTransform) *DOMPointReadOnly {
        return self._position;
    }

    pub fn getOrientation(self: *const XRRigidTransform) *DOMPointReadOnly {
        return self._orientation;
    }

    pub fn getMatrix(self: *const XRRigidTransform) Float32Array.Global {
        return self._matrix;
    }

    pub fn getInverse(self: *XRRigidTransform, exec: *const Execution) !*XRRigidTransform {
        if (self._inverse) |existing| {
            return existing;
        }
        const q = self._orientation;
        const p = self._position;
        // The conjugate rotates the other way; the translation is that
        // conjugate applied to the negated original translation.
        const cx = -q._x;
        const cy = -q._y;
        const cz = -q._z;
        const cw = q._w;

        var r: [16]f64 = undefined;
        rotationInto(&r, cx, cy, cz, cw);
        const x = -p._x;
        const y = -p._y;
        const z = -p._z;

        const root = self._root;
        const inverse = try root._arena.create(XRRigidTransform);
        try fill(
            inverse,
            root._arena,
            .{
                r[0] * x + r[4] * y + r[8] * z,
                r[1] * x + r[5] * y + r[9] * z,
                r[2] * x + r[6] * y + r[10] * z,
            },
            .{ cx, cy, cz, cw },
            exec,
        );
        inverse._root = root;
        inverse._inverse = self;
        self._inverse = inverse;
        return inverse;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRRigidTransform);

        pub const Meta = struct {
            pub const name = "XRRigidTransform";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(XRRigidTransform.constructor, .{});
        pub const position = bridge.accessor(XRRigidTransform.getPosition, null, .{});
        pub const orientation = bridge.accessor(XRRigidTransform.getOrientation, null, .{});
        pub const matrix = bridge.accessor(XRRigidTransform.getMatrix, null, .{});
        pub const inverse = bridge.accessor(XRRigidTransform.getInverse, null, .{});
    };
};

/// A ray for hit testing. Constructible even though nothing here can test a
/// hit with it -- and its normalisation is float32, which is the one place the
/// difference from XRRigidTransform shows.
pub const XRRay = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _origin: *DOMPointReadOnly,
    _direction: *DOMPointReadOnly,
    _matrix: Float32Array.Global,

    const Point = dictionary.Reader("XRRay", "DOMPointInit");
    const ZERO_DIRECTION = "Failed to construct 'XRRay': Unable to normalize vector of length 0.";
    const ORIGIN_W = "Failed to construct 'XRRay': Origin's `w` component must be set to 1.0f!";
    const DIRECTION_W = "Failed to construct 'XRRay': Direction's `w` component must be set to 0.0f!";

    pub fn constructor(origin_: ?js.Value, direction_: ?js.Value, exec: *const Execution) !*XRRay {
        // The overload that takes a transform: origin and direction both come
        // off it, and a second argument is then ignored rather than refused
        // (measured -- `new XRRay(t, {x:0,y:1,z:0})` builds fine).
        if (origin_) |value| {
            if (value.isObject()) {
                if (value.toZig(*XRRigidTransform)) |transform| {
                    return fromTransform(transform, exec);
                } else |_| {}
            }
        }

        const o = try readPoint(Point, origin_, 1, exec);
        // XRRayDirectionInit's `w` defaults to 0, not to DOMPointInit's 1.
        const d = try readPoint(Point, direction_, 0, exec);

        if (o[3] != 1) return dictionary.throwTypeError(ORIGIN_W, exec);
        if (d[3] != 0) return dictionary.throwTypeError(DIRECTION_W, exec);

        // The default direction is -Z rather than the all-zero one a plain
        // DOMPointInit would give.
        const dx = if (direction_ == null) 0 else d[0];
        const dy = if (direction_ == null) 0 else d[1];
        const dz = if (direction_ == null) -1 else d[2];

        const length = @sqrt(dx * dx + dy * dy + dz * dz);
        if (length == 0 or !std.math.isFinite(length)) {
            return dictionary.throwTypeError(ZERO_DIRECTION, exec);
        }
        // Narrowed to f32 on the way out, which is what makes {0,3,4} read
        // back as 0.6000000238418579 rather than as 0.6.
        return build(
            .{ o[0], o[1], o[2] },
            .{
                @as(f32, @floatCast(dx / length)),
                @as(f32, @floatCast(dy / length)),
                @as(f32, @floatCast(dz / length)),
            },
            exec,
        );
    }

    fn fromTransform(transform: *XRRigidTransform, exec: *const Execution) !*XRRay {
        const p = transform._position;
        const q = transform._orientation;
        // The transform's own -Z, which is its rotation's third column negated.
        var m: [16]f64 = undefined;
        rotationInto(&m, q._x, q._y, q._z, q._w);
        return build(
            .{ p._x, p._y, p._z },
            .{ -m[8], -m[9], -m[10] },
            exec,
        );
    }

    fn build(origin: [3]f64, direction: [3]f64, exec: *const Execution) !*XRRay {
        var m: [16]f64 = undefined;
        rotationInto(&m, direction[0], direction[1], direction[2], 0);
        // The rotation that takes -Z onto the direction, as an axis-angle
        // turned back into a quaternion. cross([0,0,-1], d) is [d.y, -d.x, 0]
        // and the dot is -d.z.
        const axis_x = direction[1];
        const axis_y = -direction[0];
        const axis_len = @sqrt(axis_x * axis_x + axis_y * axis_y);
        const cosine = -direction[2];
        var q: [4]f64 = .{ 0, 0, 0, 1 };
        if (axis_len == 0) {
            // Parallel: either already -Z, or +Z and a half turn about any
            // perpendicular axis will do.
            if (cosine < 0) q = .{ 1, 0, 0, 0 };
        } else {
            const angle = std.math.atan2(axis_len, cosine);
            const half = @sin(angle / 2);
            q = .{ axis_x / axis_len * half, axis_y / axis_len * half, 0, @cos(angle / 2) };
        }
        rotationInto(&m, q[0], q[1], q[2], q[3]);
        m[12] = origin[0];
        m[13] = origin[1];
        m[14] = origin[2];
        m[15] = 1;

        const arena = try exec.page.getArena(.tiny, "XRRay");
        errdefer arena.release();
        const self = try arena.create(XRRay);
        self.* = .{
            ._arena = arena,
            ._origin = try ownedPoint(arena, origin[0], origin[1], origin[2], 1),
            ._direction = try ownedPoint(arena, direction[0], direction[1], direction[2], 0),
            ._matrix = try persistMatrix(m, exec),
        };
        return self;
    }

    pub fn acquireRef(self: *XRRay) void {
        self._rc.acquire();
    }

    pub fn releaseRef(self: *XRRay, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn deinit(self: *XRRay, _: *Page) void {
        self._arena.release();
    }

    pub fn getOrigin(self: *const XRRay) *DOMPointReadOnly {
        return self._origin;
    }

    pub fn getDirection(self: *const XRRay) *DOMPointReadOnly {
        return self._direction;
    }

    pub fn getMatrix(self: *const XRRay) Float32Array.Global {
        return self._matrix;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRRay);

        pub const Meta = struct {
            pub const name = "XRRay";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(XRRay.constructor, .{});
        pub const origin = bridge.accessor(XRRay.getOrigin, null, .{});
        pub const direction = bridge.accessor(XRRay.getDirection, null, .{});
        pub const matrix = bridge.accessor(XRRay.getMatrix, null, .{});
    };
};

/// The pixel rectangle of a layer a view should be drawn into. An inline
/// session's is all zeroes, because the layer's framebuffer is the null one.
pub const XRViewport = struct {
    _x: i32,
    _y: i32,
    _width: i32,
    _height: i32,

    pub fn create(x: i32, y: i32, width: i32, height: i32, exec: *const Execution) !*XRViewport {
        return exec._factory.create(XRViewport{ ._x = x, ._y = y, ._width = width, ._height = height });
    }

    pub fn getX(self: *const XRViewport) i32 {
        return self._x;
    }
    pub fn getY(self: *const XRViewport) i32 {
        return self._y;
    }
    pub fn getWidth(self: *const XRViewport) i32 {
        return self._width;
    }
    pub fn getHeight(self: *const XRViewport) i32 {
        return self._height;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRViewport);

        pub const Meta = struct {
            pub const name = "XRViewport";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const x = bridge.accessor(XRViewport.getX, null, .{});
        pub const y = bridge.accessor(XRViewport.getY, null, .{});
        pub const width = bridge.accessor(XRViewport.getWidth, null, .{});
        pub const height = bridge.accessor(XRViewport.getHeight, null, .{});
    };
};

/// The size of the camera image a `camera-access` session would hand out.
/// Nothing here grants that feature, so no instance is ever produced -- the
/// interface object is the whole point.
pub const XRCamera = struct {
    _width: u32 = 0,
    _height: u32 = 0,

    pub fn getWidth(self: *const XRCamera) u32 {
        return self._width;
    }

    pub fn getHeight(self: *const XRCamera) u32 {
        return self._height;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCamera);

        pub const Meta = struct {
            pub const name = "XRCamera";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const width = bridge.accessor(XRCamera.getWidth, null, .{});
        pub const height = bridge.accessor(XRCamera.getHeight, null, .{});
    };
};

/// One eye's worth of a viewer pose. An inline session has exactly one, with
/// `eye` "none" and a projection matrix derived from the render state rather
/// than from a device.
pub const XRView = struct {
    _rc: lp.RC = .{},
    _eye: []const u8,
    _index: u32,
    _projection: Float32Array.Global,
    _transform: *XRRigidTransform,

    pub fn create(
        eye: []const u8,
        index: u32,
        projection: [16]f64,
        transform: *XRRigidTransform,
        exec: *const Execution,
    ) !*XRView {
        transform.acquireRef();
        return exec._factory.create(XRView{
            ._eye = eye,
            ._index = index,
            ._projection = try persistMatrix(projection, exec),
            ._transform = transform,
        });
    }

    pub fn acquireRef(self: *XRView) void {
        self._rc.acquire();
    }

    pub fn releaseRef(self: *XRView, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn deinit(self: *XRView, page: *Page) void {
        self._transform.releaseRef(page);
    }

    pub fn getEye(self: *const XRView) []const u8 {
        return self._eye;
    }

    /// Null unless the page has asked for a scale and the device answered;
    /// Chrome's inline session reports null (measured).
    pub fn getRecommendedViewportScale(_: *const XRView) ?f64 {
        return null;
    }

    pub fn getIsFirstPersonObserver(_: *const XRView) bool {
        return false;
    }

    pub fn getCamera(_: *const XRView) ?*XRCamera {
        return null;
    }

    /// Accepted and dropped: with no secondary views to scale there is nothing
    /// for it to record, and Chrome's inline session likewise reports null
    /// from `recommendedViewportScale` afterwards (measured).
    pub fn requestViewportScale(_: *const XRView, _: ?js.Value) void {}

    pub fn getIndex(self: *const XRView) u32 {
        return self._index;
    }

    pub fn getProjectionMatrix(self: *const XRView) Float32Array.Global {
        return self._projection;
    }

    pub fn getTransform(self: *const XRView) *XRRigidTransform {
        return self._transform;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRView);

        pub const Meta = struct {
            pub const name = "XRView";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's order, not the spec's: index/projectionMatrix/transform
        // land after requestViewportScale.
        pub const eye = bridge.accessor(XRView.getEye, null, .{});
        pub const recommendedViewportScale = bridge.accessor(XRView.getRecommendedViewportScale, null, .{});
        pub const isFirstPersonObserver = bridge.accessor(XRView.getIsFirstPersonObserver, null, .{});
        pub const camera = bridge.accessor(XRView.getCamera, null, .{});
        // Nullable-but-required in the IDL, so the declared arity is 1 even
        // though an absent argument is accepted.
        pub const requestViewportScale = bridge.function(XRView.requestViewportScale, .{ .arity = 1 });
        pub const index = bridge.accessor(XRView.getIndex, null, .{});
        pub const projectionMatrix = bridge.accessor(XRView.getProjectionMatrix, null, .{});
        pub const transform = bridge.accessor(XRView.getTransform, null, .{});
    };
};

/// Where something is, relative to the space it was asked about.
pub const XRPose = struct {
    pub const Type = union(enum) {
        generic,
        viewer: *XRViewerPose,
        joint: *XRJointPose,
    };

    _type: Type = .generic,
    _rc: lp.RC = .{},
    _transform: *XRRigidTransform,
    _emulated_position: bool = false,

    pub fn create(transform: *XRRigidTransform, exec: *const Execution) !*XRPose {
        transform.acquireRef();
        return exec._factory.create(XRPose{ ._transform = transform });
    }

    pub fn acquireRef(self: *XRPose) void {
        self._rc.acquire();
    }

    pub fn releaseRef(self: *XRPose, page: *Page) void {
        self._rc.release(self, page);
    }

    /// The whole pose family releases here: the refcount sits on the chain
    /// root, so a viewer pose's views have to be let go from the base.
    pub fn deinit(self: *XRPose, page: *Page) void {
        self._transform.releaseRef(page);
        switch (self._type) {
            .viewer => |pose| for (pose._views) |view| view.releaseRef(page),
            .generic, .joint => {},
        }
    }

    pub fn getTransform(self: *const XRPose) *XRRigidTransform {
        return self._transform;
    }

    pub fn getEmulatedPosition(self: *const XRPose) bool {
        return self._emulated_position;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRPose);

        pub const Meta = struct {
            pub const name = "XRPose";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const transform = bridge.accessor(XRPose.getTransform, null, .{});
        pub const emulatedPosition = bridge.accessor(XRPose.getEmulatedPosition, null, .{});
    };
};

/// The viewer's pose, which is the only pose that carries views.
pub const XRViewerPose = struct {
    pub const Proto = XRPose;

    _proto: *XRPose,
    _views: []const *XRView,

    pub fn create(
        transform: *XRRigidTransform,
        views: []const *XRView,
        exec: *const Execution,
    ) !*XRViewerPose {
        transform.acquireRef();
        for (views) |view| view.acquireRef();
        const pose = try exec._factory.chained(.{
            XRPose{ ._type = undefined, ._transform = transform },
            XRViewerPose{ ._proto = undefined, ._views = views },
        });
        pose._proto._type = .{ .viewer = pose };
        return pose;
    }

    pub fn asXRPose(self: *XRViewerPose) *XRPose {
        return self._proto;
    }

    /// Chrome's is a FrozenArray; this engine has no way to freeze an array it
    /// builds, so ours is an ordinary one. Recorded rather than papered over.
    pub fn getViews(self: *const XRViewerPose) []const *XRView {
        return self._views;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRViewerPose);

        pub const Meta = struct {
            pub const name = "XRViewerPose";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRPose;

        pub const views = bridge.accessor(XRViewerPose.getViews, null, .{});
    };
};

/// A hand joint's pose. Only a `hand-tracking` session produces one, which
/// nothing here grants.
pub const XRJointPose = struct {
    pub const Proto = XRPose;

    _proto: *XRPose,
    _radius: ?f64 = null,

    pub fn asXRPose(self: *XRJointPose) *XRPose {
        return self._proto;
    }

    pub fn getRadius(self: *const XRJointPose) ?f64 {
        return self._radius;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRJointPose);

        pub const Meta = struct {
            pub const name = "XRJointPose";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRPose;

        pub const radius = bridge.accessor(XRJointPose.getRadius, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebXR geometry" {
    try testing.htmlRunner("webxr/geometry.html", .{});
}
