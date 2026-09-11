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

const Event = @import("../Event.zig");
const MouseEvent = @import("MouseEvent.zig");

const String = lp.String;

const PointerEvent = @This();

pub const Proto = MouseEvent;

const PointerType = enum {
    empty,
    mouse,
    pen,
    touch,

    fn fromString(s: []const u8) PointerType {
        if (std.mem.eql(u8, s, "")) return .empty;
        if (std.mem.eql(u8, s, "mouse")) return .mouse;
        if (std.mem.eql(u8, s, "pen")) return .pen;
        if (std.mem.eql(u8, s, "touch")) return .touch;
        return .empty;
    }

    fn toString(self: PointerType) []const u8 {
        return switch (self) {
            .empty => "",
            inline else => |pt| @tagName(pt),
        };
    }
};

_proto: *MouseEvent,
_pointer_id: i32,
_pointer_type: PointerType,
_width: f64,
_height: f64,
_pressure: f64,
_tangential_pressure: f64,
_tilt_x: i32,
_tilt_y: i32,
_twist: i32,
_altitude_angle: f64,
_azimuth_angle: f64,
_is_primary: bool,
_persistent_device_id: i32,
_coalesced_events: []const *PointerEvent,
_predicted_events: []const *PointerEvent,

pub const PointerEventOptions = struct {
    // Alphabetical: a dictionary's members are read in that order, and the
    // reads are observable.
    altitudeAngle: f64 = std.math.pi / 2.0,
    azimuthAngle: f64 = 0.0,
    coalescedEvents: []const *PointerEvent = &.{},
    height: f64 = 1.0,
    isPrimary: bool = false,
    persistentDeviceId: i32 = 0,
    pointerId: i32 = 0,
    pointerType: []const u8 = "",
    predictedEvents: []const *PointerEvent = &.{},
    pressure: f64 = 0.0,
    tangentialPressure: f64 = 0.0,
    tiltX: i32 = 0,
    tiltY: i32 = 0,
    twist: i32 = 0,
    width: f64 = 1.0,
};

const Options = Event.inheritOptions(
    PointerEvent,
    PointerEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*PointerEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*PointerEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, frame: *Frame) !*PointerEvent {
    const arena = try frame.getArena(.tiny, "PointerEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.mouseEvent(
        arena,
        type_string,
        MouseEvent{
            ._type = .{ .pointer_event = undefined },
            ._proto = undefined,
            ._screen_x = opts.screenX,
            ._screen_y = opts.screenY,
            ._client_x = opts.clientX,
            ._client_y = opts.clientY,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._button = @truncate(opts.button),
            ._buttons = opts.buttons,
            ._related_target = opts.relatedTarget,
            ._movement_x = opts.movementX,
            ._movement_y = opts.movementY,
        },
        PointerEvent{
            ._proto = undefined,
            ._pointer_id = opts.pointerId,
            ._pointer_type = PointerType.fromString(opts.pointerType),
            ._width = opts.width,
            ._height = opts.height,
            ._pressure = opts.pressure,
            ._tangential_pressure = opts.tangentialPressure,
            ._tilt_x = opts.tiltX,
            ._tilt_y = opts.tiltY,
            ._twist = opts.twist,
            ._altitude_angle = opts.altitudeAngle,
            ._azimuth_angle = opts.azimuthAngle,
            ._is_primary = opts.isPrimary,
            ._persistent_device_id = opts.persistentDeviceId,
            // The dictionary's sequences are only borrowed for the call; the
            // event outlives it.
            ._coalesced_events = try arena.allocator().dupe(*PointerEvent, opts.coalescedEvents),
            ._predicted_events = try arena.allocator().dupe(*PointerEvent, opts.predictedEvents),
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *PointerEvent) *Event {
    return self._proto.asEvent();
}

pub fn getPointerId(self: *const PointerEvent) i32 {
    return self._pointer_id;
}

pub fn getPointerType(self: *const PointerEvent) []const u8 {
    return self._pointer_type.toString();
}

pub fn getWidth(self: *const PointerEvent) f64 {
    return self._width;
}

pub fn getHeight(self: *const PointerEvent) f64 {
    return self._height;
}

pub fn getPressure(self: *const PointerEvent) f64 {
    return self._pressure;
}

pub fn getTangentialPressure(self: *const PointerEvent) f64 {
    return self._tangential_pressure;
}

pub fn getTiltX(self: *const PointerEvent) i32 {
    return self._tilt_x;
}

pub fn getTiltY(self: *const PointerEvent) i32 {
    return self._tilt_y;
}

pub fn getTwist(self: *const PointerEvent) i32 {
    return self._twist;
}

pub fn getAltitudeAngle(self: *const PointerEvent) f64 {
    return self._altitude_angle;
}

pub fn getAzimuthAngle(self: *const PointerEvent) f64 {
    return self._azimuth_angle;
}

pub fn getIsPrimary(self: *const PointerEvent) bool {
    return self._is_primary;
}

pub fn getPersistentDeviceId(self: *const PointerEvent) i32 {
    return self._persistent_device_id;
}

// Both answer a fresh array every call in Chrome -- two calls on the same
// event are not identical objects -- so the slice is handed back and the
// bridge builds the array, rather than a cached one being reused.
pub fn getCoalescedEvents(self: *const PointerEvent) []const *PointerEvent {
    return self._coalesced_events;
}

pub fn getPredictedEvents(self: *const PointerEvent) []const *PointerEvent {
    return self._predicted_events;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PointerEvent);

    pub const Meta = struct {
        pub const name = "PointerEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // Chrome leaves getCoalescedEvents behind the constructor slot.
        pub const constructor_after = "persistentDeviceId";
    };

    pub const constructor = bridge.constructor(PointerEvent.init, .{});
    // Chrome's own-property order, measured.
    pub const pointerId = bridge.accessor(PointerEvent.getPointerId, null, .{});
    pub const width = bridge.accessor(PointerEvent.getWidth, null, .{});
    pub const height = bridge.accessor(PointerEvent.getHeight, null, .{});
    pub const pressure = bridge.accessor(PointerEvent.getPressure, null, .{});
    pub const tiltX = bridge.accessor(PointerEvent.getTiltX, null, .{});
    pub const tiltY = bridge.accessor(PointerEvent.getTiltY, null, .{});
    pub const azimuthAngle = bridge.accessor(PointerEvent.getAzimuthAngle, null, .{});
    pub const altitudeAngle = bridge.accessor(PointerEvent.getAltitudeAngle, null, .{});
    pub const tangentialPressure = bridge.accessor(PointerEvent.getTangentialPressure, null, .{});
    pub const twist = bridge.accessor(PointerEvent.getTwist, null, .{});
    pub const pointerType = bridge.accessor(PointerEvent.getPointerType, null, .{});
    pub const isPrimary = bridge.accessor(PointerEvent.getIsPrimary, null, .{});
    pub const getPredictedEvents = bridge.function(PointerEvent.getPredictedEvents, .{});
    pub const persistentDeviceId = bridge.accessor(PointerEvent.getPersistentDeviceId, null, .{});
    pub const getCoalescedEvents = bridge.function(PointerEvent.getCoalescedEvents, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: PointerEvent" {
    try testing.htmlRunner("event/pointer.html", .{});
}
