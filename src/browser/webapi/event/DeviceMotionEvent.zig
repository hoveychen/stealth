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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");

const String = lp.String;

// https://w3c.github.io/deviceorientation/#devicemotionevent
const DeviceMotionEvent = @This();

pub fn registerTypes() []const type {
    return &.{
        DeviceMotionEvent,
        DeviceMotionEventAcceleration,
        DeviceMotionEventRotationRate,
    };
}

pub const Proto = Event;

_proto: *Event,
_interval: f64 = 0,
_acceleration: ?*DeviceMotionEventAcceleration = null,
_acceleration_including_gravity: ?*DeviceMotionEventAcceleration = null,
_rotation_rate: ?*DeviceMotionEventRotationRate = null,

const AccelerationInit = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    z: ?f64 = null,
};

const RotationRateInit = struct {
    alpha: ?f64 = null,
    beta: ?f64 = null,
    gamma: ?f64 = null,
};

const DeviceMotionEventOptions = struct {
    // Alphabetical: a dictionary's members are read in that order, and the
    // reads are observable.
    acceleration: ?AccelerationInit = null,
    accelerationIncludingGravity: ?AccelerationInit = null,
    interval: f64 = 0,
    rotationRate: ?RotationRateInit = null,
};

const Options = Event.inheritOptions(DeviceMotionEvent, DeviceMotionEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*DeviceMotionEvent {
    const arena = try frame.getArena(.tiny, "DeviceMotionEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = _opts orelse Options{};
    const factory = frame._factory;
    const event = try factory.event(
        arena,
        type_string,
        DeviceMotionEvent{
            ._proto = undefined,
            ._interval = opts.interval,
            ._acceleration = if (opts.acceleration) |a| try factory.create(DeviceMotionEventAcceleration{
                ._x = a.x,
                ._y = a.y,
                ._z = a.z,
            }) else null,
            ._acceleration_including_gravity = if (opts.accelerationIncludingGravity) |a| try factory.create(DeviceMotionEventAcceleration{
                ._x = a.x,
                ._y = a.y,
                ._z = a.z,
            }) else null,
            ._rotation_rate = if (opts.rotationRate) |r| try factory.create(DeviceMotionEventRotationRate{
                ._alpha = r.alpha,
                ._beta = r.beta,
                ._gamma = r.gamma,
            }) else null,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn asEvent(self: *DeviceMotionEvent) *Event {
    return self._proto;
}

// There is no motion sensor, so an event the engine itself fires (it never
// does) would report null. A page that builds one gets back what it put in the
// dictionary, which is what Chrome does too: measured,
// `new DeviceMotionEvent('devicemotion', {acceleration: {x: 1, y: 2, z: 3}})`
// answers a DeviceMotionEventAcceleration whose x is 1, and a bare event
// answers null for all three.
pub fn getAcceleration(self: *const DeviceMotionEvent) ?*DeviceMotionEventAcceleration {
    return self._acceleration;
}

pub fn getAccelerationIncludingGravity(self: *const DeviceMotionEvent) ?*DeviceMotionEventAcceleration {
    return self._acceleration_including_gravity;
}

pub fn getRotationRate(self: *const DeviceMotionEvent) ?*DeviceMotionEventRotationRate {
    return self._rotation_rate;
}

pub fn getInterval(self: *const DeviceMotionEvent) f64 {
    return self._interval;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DeviceMotionEvent);

    pub const Meta = struct {
        pub const name = "DeviceMotionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DeviceMotionEvent.init, .{});
    pub const acceleration = bridge.accessor(DeviceMotionEvent.getAcceleration, null, .{});
    pub const accelerationIncludingGravity = bridge.accessor(DeviceMotionEvent.getAccelerationIncludingGravity, null, .{});
    pub const rotationRate = bridge.accessor(DeviceMotionEvent.getRotationRate, null, .{});
    pub const interval = bridge.accessor(DeviceMotionEvent.getInterval, null, .{});
};

/// The acceleration triple. Chrome exposes the interface on the window even
/// though nothing but a devicemotion event ever hands one out, and its
/// constructor throws "Illegal constructor" (measured), which is what a class
/// with no `constructor` declaration does here.
pub const DeviceMotionEventAcceleration = struct {
    _x: ?f64 = null,
    _y: ?f64 = null,
    _z: ?f64 = null,

    pub fn getX(self: *const DeviceMotionEventAcceleration) ?f64 {
        return self._x;
    }

    pub fn getY(self: *const DeviceMotionEventAcceleration) ?f64 {
        return self._y;
    }

    pub fn getZ(self: *const DeviceMotionEventAcceleration) ?f64 {
        return self._z;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DeviceMotionEventAcceleration);

        pub const Meta = struct {
            pub const name = "DeviceMotionEventAcceleration";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const x = bridge.accessor(DeviceMotionEventAcceleration.getX, null, .{});
        pub const y = bridge.accessor(DeviceMotionEventAcceleration.getY, null, .{});
        pub const z = bridge.accessor(DeviceMotionEventAcceleration.getZ, null, .{});
    };
};

/// The rotation triple, same story as the acceleration one.
pub const DeviceMotionEventRotationRate = struct {
    _alpha: ?f64 = null,
    _beta: ?f64 = null,
    _gamma: ?f64 = null,

    pub fn getAlpha(self: *const DeviceMotionEventRotationRate) ?f64 {
        return self._alpha;
    }

    pub fn getBeta(self: *const DeviceMotionEventRotationRate) ?f64 {
        return self._beta;
    }

    pub fn getGamma(self: *const DeviceMotionEventRotationRate) ?f64 {
        return self._gamma;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DeviceMotionEventRotationRate);

        pub const Meta = struct {
            pub const name = "DeviceMotionEventRotationRate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const alpha = bridge.accessor(DeviceMotionEventRotationRate.getAlpha, null, .{});
        pub const beta = bridge.accessor(DeviceMotionEventRotationRate.getBeta, null, .{});
        pub const gamma = bridge.accessor(DeviceMotionEventRotationRate.getGamma, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: DeviceMotionEvent" {
    try testing.htmlRunner("event/device_motion.html", .{});
}
