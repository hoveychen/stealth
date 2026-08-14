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

// The spaces a pose is expressed in. Four of them, all EventTarget subclasses,
// none constructible; plus the one event a reference space can fire.
//
// Only `viewer` is reachable on a device-less desktop -- measured on a headed
// Chrome 150, where an inline session grants `viewer` and answers
// NotSupportedError for local, local-floor, bounded-floor and unbounded. So
// XRBoundedReferenceSpace and XRJointSpace never have an instance here; they
// are on window because Chrome puts them there.
//
// The origin offset is kept as plain numbers rather than as an
// XRRigidTransform: a space outlives any transform a page hands it, and
// numbers need no ownership.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const dictionary = @import("../dictionary.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const geometry = @import("geometry.zig");

const XRRigidTransform = geometry.XRRigidTransform;
const Execution = js.Execution;
const String = lp.String;

pub fn registerTypes() []const type {
    return &.{
        XRBoundedReferenceSpace,
        XRJointSpace,
        XRReferenceSpace,
        XRReferenceSpaceEvent,
        XRSpace,
    };
}

/// A position and an orientation as bare numbers, which is what a space stores
/// instead of holding an XRRigidTransform.
pub const Rigid = struct {
    position: [3]f64 = .{ 0, 0, 0 },
    orientation: [4]f64 = .{ 0, 0, 0, 1 },

    /// `self` then `other`, the way getOffsetReferenceSpace accumulates.
    pub fn compose(self: Rigid, other: Rigid) Rigid {
        const a = self.orientation;
        const b = other.orientation;
        const q: [4]f64 = .{
            a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
            a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
            a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
            a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
        };
        const p = rotate(a, other.position);
        return .{
            .position = .{
                self.position[0] + p[0],
                self.position[1] + p[1],
                self.position[2] + p[2],
            },
            .orientation = q,
        };
    }

    fn rotate(q: [4]f64, v: [3]f64) [3]f64 {
        // v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v)
        const tx = q[1] * v[2] - q[2] * v[1] + q[3] * v[0];
        const ty = q[2] * v[0] - q[0] * v[2] + q[3] * v[1];
        const tz = q[0] * v[1] - q[1] * v[0] + q[3] * v[2];
        return .{
            v[0] + 2 * (q[1] * tz - q[2] * ty),
            v[1] + 2 * (q[2] * tx - q[0] * tz),
            v[2] + 2 * (q[0] * ty - q[1] * tx),
        };
    }

    pub fn build(self: Rigid, exec: *const Execution) !*XRRigidTransform {
        return XRRigidTransform.build(self.position, self.orientation, exec);
    }

    pub fn fromTransform(transform: *const XRRigidTransform) Rigid {
        const p = transform._position;
        const o = transform._orientation;
        return .{
            .position = .{ p._x, p._y, p._z },
            .orientation = .{ o._x, o._y, o._z, o._w },
        };
    }
};

/// The base of everything a pose can be asked about. Nothing of its own on the
/// prototype -- it is EventTarget plus a brand.
pub const XRSpace = struct {
    pub const Proto = EventTarget;

    pub const Type = union(enum) {
        generic,
        reference: *XRReferenceSpace,
        joint: *XRJointSpace,
    };

    _proto: *EventTarget,
    _type: Type = .generic,

    pub fn asEventTarget(self: *XRSpace) *EventTarget {
        return self._proto;
    }

    /// Where this space's origin sits, in the session's own coordinates. Only
    /// reference spaces carry one; a bare XRSpace is the identity.
    pub fn offset(self: *const XRSpace) Rigid {
        return switch (self._type) {
            .reference => |space| space._offset,
            .generic, .joint => .{},
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRSpace);

        pub const Meta = struct {
            pub const name = "XRSpace";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;
    };
};

/// A space a page asked the session for. `viewer` is the only kind an inline
/// session grants.
pub const XRReferenceSpace = struct {
    pub const Proto = XRSpace;

    pub const Type = union(enum) {
        generic,
        bounded: *XRBoundedReferenceSpace,
    };

    _proto: *XRSpace,
    _type: Type = .generic,
    _kind: []const u8,
    _offset: Rigid = .{},
    _on_reset: ?js.Function.Global = null,

    const ARITY = "Failed to execute 'getOffsetReferenceSpace' on 'XRReferenceSpace': " ++
        "1 argument required, but only 0 present.";
    const NOT_TRANSFORM = "Failed to execute 'getOffsetReferenceSpace' on 'XRReferenceSpace': " ++
        "parameter 1 is not of type 'XRRigidTransform'.";

    pub fn create(kind: []const u8, base: Rigid, exec: *const Execution) !*XRReferenceSpace {
        const space = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            XRSpace{ ._proto = undefined, ._type = undefined },
            XRReferenceSpace{ ._proto = undefined, ._kind = kind, ._offset = base },
        });
        space._proto._type = .{ .reference = space };
        space._proto._proto._type = .{ .xr_space = space._proto };
        return space;
    }

    pub fn asXRSpace(self: *XRReferenceSpace) *XRSpace {
        return self._proto;
    }

    pub fn getOnreset(self: *const XRReferenceSpace) ?js.Function.Global {
        return self._on_reset;
    }

    pub fn setOnreset(self: *XRReferenceSpace, listener: ?js.Function) !void {
        self._on_reset = if (listener) |l| try l.persistWithThis(self) else null;
    }

    /// A *new* space with the given offset folded in -- measured: the result is
    /// never the space it was asked of, even for an identity transform.
    pub fn getOffsetReferenceSpace(
        self: *XRReferenceSpace,
        origin_offset: ?js.Value,
        exec: *const Execution,
    ) !*XRReferenceSpace {
        const value = origin_offset orelse return dictionary.throwTypeError(ARITY, exec);
        const transform = value.toZig(*XRRigidTransform) catch
            return dictionary.throwTypeError(NOT_TRANSFORM, exec);
        return create(self._kind, self._offset.compose(Rigid.fromTransform(transform)), exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRReferenceSpace);

        pub const Meta = struct {
            pub const name = "XRReferenceSpace";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRSpace;

        pub const onreset = bridge.accessor(
            XRReferenceSpace.getOnreset,
            XRReferenceSpace.setOnreset,
            .{},
        );
        pub const getOffsetReferenceSpace = bridge.function(
            XRReferenceSpace.getOffsetReferenceSpace,
            .{ .arity = 1 },
        );
    };
};

/// What `bounded-floor` would give: the polygon the user can walk inside. No
/// session here grants it, so no instance exists.
pub const XRBoundedReferenceSpace = struct {
    pub const Proto = XRReferenceSpace;

    _proto: *XRReferenceSpace,
    _bounds: []const *@import("../DOMPointReadOnly.zig") = &.{},

    pub fn asXRReferenceSpace(self: *XRBoundedReferenceSpace) *XRReferenceSpace {
        return self._proto;
    }

    pub fn getBoundsGeometry(self: *const XRBoundedReferenceSpace) []const *@import("../DOMPointReadOnly.zig") {
        return self._bounds;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRBoundedReferenceSpace);

        pub const Meta = struct {
            pub const name = "XRBoundedReferenceSpace";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRReferenceSpace;

        pub const boundsGeometry = bridge.accessor(XRBoundedReferenceSpace.getBoundsGeometry, null, .{});
    };
};

/// One joint of a tracked hand. `hand-tracking` is not a feature any session
/// here enables, so this too is interface-only.
pub const XRJointSpace = struct {
    pub const Proto = XRSpace;

    _proto: *XRSpace,
    _joint_name: []const u8 = "wrist",

    pub fn asXRSpace(self: *XRJointSpace) *XRSpace {
        return self._proto;
    }

    pub fn getJointName(self: *const XRJointSpace) []const u8 {
        return self._joint_name;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRJointSpace);

        pub const Meta = struct {
            pub const name = "XRJointSpace";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRSpace;

        pub const jointName = bridge.accessor(XRJointSpace.getJointName, null, .{});
    };
};

/// `reset`, the one event a reference space fires. Nothing here fires it -- no
/// tracking origin can move when there is no tracking -- but a page can build
/// one, and its dictionary refusals are readable.
pub const XRReferenceSpaceEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _reference_space: *XRReferenceSpace,
    // Stored as numbers rather than as the transform itself: an Event's deinit
    // only releases its arena, so it has nowhere to let a ref go.
    _transform: ?Rigid,

    const Init = dictionary.Init("XRReferenceSpaceEvent", "XRReferenceSpaceEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*XRReferenceSpaceEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRReferenceSpaceEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRReferenceSpaceEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        const space = try init.interfaceMember(
            "referenceSpace",
            XRReferenceSpace,
            "XRReferenceSpace",
            exec,
        );
        const transform = try init.nullableInterface(
            "transform",
            XRRigidTransform,
            "XRRigidTransform",
            exec,
        );
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "XRReferenceSpaceEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            XRReferenceSpaceEvent{
                ._proto = undefined,
                ._reference_space = space,
                ._transform = if (transform) |t| Rigid.fromTransform(t) else null,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *XRReferenceSpaceEvent) *Event {
        return self._proto;
    }

    pub fn getReferenceSpace(self: *const XRReferenceSpaceEvent) *XRReferenceSpace {
        return self._reference_space;
    }

    pub fn getTransform(self: *const XRReferenceSpaceEvent, exec: *const Execution) !?*XRRigidTransform {
        const rigid = self._transform orelse return null;
        return rigid.build(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRReferenceSpaceEvent);

        pub const Meta = struct {
            pub const name = "XRReferenceSpaceEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(XRReferenceSpaceEvent.constructor, .{ .arity = 2 });
        pub const referenceSpace = bridge.accessor(XRReferenceSpaceEvent.getReferenceSpace, null, .{});
        pub const transform = bridge.accessor(XRReferenceSpaceEvent.getTransform, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebXR spaces" {
    try testing.htmlRunner("webxr/spaces.html", .{});
}
