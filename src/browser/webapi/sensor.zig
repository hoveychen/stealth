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

//! The Generic Sensor API: Sensor and the six concrete motion sensors, plus
//! the SensorErrorEvent they fail with.
//!
//! There is no accelerometer behind this engine, and start() says so rather
//! than inventing readings: it queues a NotReadableError "Could not connect to
//! a sensor", which is exactly what a headed Chrome 150 answers on a machine
//! with no motion sensors (measured over http://localhost; the probes live in
//! tools/fingerprint/results/probes/). The sensor never
//! activates, never reads, and every reading attribute stays null -- the same
//! observable state Chrome leaves behind after that failure.
//!
//! The argument errors are the interesting half, and all of them throw
//! synchronously: none of these entry points hands back a promise to reject.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const DOMMatrix = @import("DOMMatrix.zig");
const handler_property = @import("handler_property.zig");
const permissions_policy = @import("../permissions_policy.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        Sensor,
        SensorErrorEvent,
        Accelerometer,
        LinearAccelerationSensor,
        GravitySensor,
        Gyroscope,
        OrientationSensor,
        AbsoluteOrientationSensor,
        RelativeOrientationSensor,
    };
}

// Chrome does not fail the start on this turn, nor on a microtask, nor even
// before a setTimeout(0) that follows it -- measured. A short scheduler delay
// puts the failure where a script sees it: later than both.
const CONNECT_FAILURE_DELAY_MS = 5;

const NOT_READABLE = "Could not connect to a sensor";

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

// The policy features each sensor needs, all 'self' by default. A frame that
// did not inherit one gets a SecurityError from the constructor, before the
// options are read (measured, Chrome 153 cross-origin iframe).
fn policyFeatures(comptime name: []const u8) []const []const u8 {
    if (comptime std.mem.eql(u8, name, "Gyroscope")) return &.{"gyroscope"};
    if (comptime std.mem.eql(u8, name, "AbsoluteOrientationSensor")) return &.{ "accelerometer", "gyroscope", "magnetometer" };
    if (comptime std.mem.eql(u8, name, "RelativeOrientationSensor")) return &.{ "accelerometer", "gyroscope" };
    return &.{"accelerometer"};
}

fn checkPolicy(comptime name: []const u8, exec: *const Execution) !void {
    inline for (comptime policyFeatures(name)) |feature| {
        if (!permissions_policy.execAllows(exec, feature)) {
            return exec.js.fail(error.SecurityError, "Failed to construct '" ++ name ++ "': Access to sensor features is disallowed by permissions policy");
        }
    }
}

/// SensorOptions plus SpatialSensorOptions: Chrome reads both dictionaries on
/// every concrete sensor, including the ones with no spatial meaning
/// (measured: `new Accelerometer({referenceFrame: 'bogus'})` is a
/// LocalCoordinateSystem enum error, not an ignored member).
const Options = struct {
    fn read(comptime name: []const u8, options_: ?js.Value, exec: *const Execution) !void {
        try checkPolicy(name, exec);
        const options = options_ orelse return;
        if (options.isNullOrUndefined()) {
            return;
        }
        if (!options.isObject()) {
            return throwTypeError(
                "Failed to construct '" ++ name ++ "': The provided value is not of type 'SpatialSensorOptions'.",
                exec,
            );
        }
        const object = options.toObject();

        const frequency = try object.get("frequency");
        if (!frequency.isUndefined()) {
            const hz = frequency.toF64() catch std.math.nan(f64);
            if (!std.math.isFinite(hz)) {
                return throwTypeError(
                    "Failed to construct '" ++ name ++ "': Failed to read the 'frequency' property from " ++
                        "'SensorOptions': The provided double value is non-finite.",
                    exec,
                );
            }
        }

        const reference_frame = try object.get("referenceFrame");
        if (!reference_frame.isUndefined()) {
            const text = try reference_frame.toStringSlice();
            if (!std.mem.eql(u8, text, "device") and !std.mem.eql(u8, text, "screen")) {
                const message = std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to construct '" ++ name ++ "': Failed to read the 'referenceFrame' property from " ++
                        "'SpatialSensorOptions': The provided value '{s}' is not a valid enum value of type " ++
                        "LocalCoordinateSystem.",
                    .{text},
                ) catch return error.TypeError;
                return throwTypeError(message, exec);
            }
        }
    }
};

/// The abstract base. `new Sensor()` is an illegal constructor, which is what
/// declaring no constructor gets us.
pub const Sensor = struct {
    pub const Proto = EventTarget;

    // A sensor always reaches JS as its concrete type, so an error event's
    // target reads back as the Accelerometer it is rather than as a Sensor.
    pub const Type = union(enum) {
        accelerometer: *Accelerometer,
        gyroscope: *Gyroscope,
        orientation_sensor: *OrientationSensor,
    };

    _proto: *EventTarget,
    _type: Type,
    // A start() that has not yet failed. stop() clears it, which is what keeps
    // a sensor stopped before the failure lands from ever firing (measured).
    _running: bool = false,
    // Bumped by every start(), so a queued failure from an earlier start()
    // cannot fire against a later one.
    _generation: u32 = 0,

    pub fn asEventTarget(self: *Sensor) *EventTarget {
        return self._proto;
    }

    // Nothing ever activates or reads here, so these are the constants Chrome
    // reports for a sensor that failed to connect.
    pub fn getActivated(_: *const Sensor) bool {
        return false;
    }

    pub fn getHasReading(_: *const Sensor) bool {
        return false;
    }

    pub fn getTimestamp(_: *const Sensor) ?f64 {
        return null;
    }

    // start() answers nothing and never throws, even when called twice
    // (measured); the second call joins the failure already queued.
    pub fn start(self: *Sensor, exec: *const Execution) !void {
        if (self._running) {
            return;
        }
        self._running = true;
        self._generation +%= 1;

        const failure = try exec.arena.create(ConnectFailure);
        failure.* = .{
            .exec = exec,
            .sensor = self,
            .generation = self._generation,
        };
        try exec._scheduler.add(failure, ConnectFailure.run, CONNECT_FAILURE_DELAY_MS, .{
            .name = "Sensor.start",
        });
    }

    // Idempotent, and never throws.
    pub fn stop(self: *Sensor) void {
        self._running = false;
    }

    fn fail(self: *Sensor, exec: *const Execution) !void {
        self._running = false;

        const target = self.asEventTarget();
        const on_error = null;
        switch (exec.js.global) {
            inline else => |g| {
                if (!g._event_manager.hasDirectListeners(target, "error", on_error)) {
                    return;
                }
                const dom = try exec.arena.create(DOMException);
                dom.* = DOMException.init(NOT_READABLE, "NotReadableError");
                const event = try SensorErrorEvent.initTrusted(dom, exec);
                try g.dispatch(target, event.asEvent(), on_error, .{ .context = "sensor error" });
            },
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Sensor);

        pub const Meta = struct {
            pub const name = "Sensor";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        // Chrome's own prototype order.
        pub const activated = bridge.accessor(Sensor.getActivated, null, .{});
        pub const hasReading = bridge.accessor(Sensor.getHasReading, null, .{});
        pub const timestamp = bridge.accessor(Sensor.getTimestamp, null, .{});
        pub const onerror = bridge.accessor(handlerProperty(Sensor, .onerror).get, handlerProperty(Sensor, .onerror).set, .{});
        pub const onreading = bridge.accessor(handlerProperty(Sensor, .onreading).get, handlerProperty(Sensor, .onreading).set, .{});
        pub const onactivate = bridge.accessor(handlerProperty(Sensor, .onactivate).get, handlerProperty(Sensor, .onactivate).set, .{});
        pub const start = bridge.function(Sensor.start, .{});
        pub const stop = bridge.function(Sensor.stop, .{});
    };
};

const ConnectFailure = struct {
    exec: *const Execution,
    sensor: *Sensor,
    generation: u32,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ConnectFailure = @ptrCast(@alignCast(ctx));
        // Stopped, or restarted since this failure was queued.
        if (!self.sensor._running or self.sensor._generation != self.generation) {
            return null;
        }
        self.sensor.fail(self.exec) catch |err| {
            log.warn(.app, "sensor connect failure", .{ .err = err });
        };
        return null;
    }
};

/// An accelerometer's three axes. Null until there is a reading, and there
/// never is one.
pub const Accelerometer = struct {
    pub const Proto = Sensor;

    // The tag Sensor._type carries for this branch of the tree.
    const sensor_tag = "accelerometer";

    pub const Type = union(enum) {
        generic: void,
        linear_acceleration: *LinearAccelerationSensor,
        gravity: *GravitySensor,
    };

    _proto: *Sensor,
    _type: Type = .generic,

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*Accelerometer {
        try Options.read("Accelerometer", options_, exec);
        const leaf = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            Sensor{ ._proto = undefined, ._type = undefined },
            Accelerometer{ ._proto = undefined },
        });
        link(leaf._proto, .{ .accelerometer = leaf });
        return leaf;
    }

    pub fn getX(_: *const Accelerometer) ?f64 {
        return null;
    }

    pub fn getY(_: *const Accelerometer) ?f64 {
        return null;
    }

    pub fn getZ(_: *const Accelerometer) ?f64 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Accelerometer);

        pub const Meta = struct {
            pub const name = "Accelerometer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Sensor;

        pub const constructor = bridge.constructor(Accelerometer.constructor, .{ .arity = 0 });
        pub const x = bridge.accessor(Accelerometer.getX, null, .{});
        pub const y = bridge.accessor(Accelerometer.getY, null, .{});
        pub const z = bridge.accessor(Accelerometer.getZ, null, .{});
    };
};

pub const Gyroscope = struct {
    pub const Proto = Sensor;

    _proto: *Sensor,

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*Gyroscope {
        try Options.read("Gyroscope", options_, exec);
        const leaf = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            Sensor{ ._proto = undefined, ._type = undefined },
            Gyroscope{ ._proto = undefined },
        });
        link(leaf._proto, .{ .gyroscope = leaf });
        return leaf;
    }

    pub fn getX(_: *const Gyroscope) ?f64 {
        return null;
    }

    pub fn getY(_: *const Gyroscope) ?f64 {
        return null;
    }

    pub fn getZ(_: *const Gyroscope) ?f64 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Gyroscope);

        pub const Meta = struct {
            pub const name = "Gyroscope";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Sensor;

        pub const constructor = bridge.constructor(Gyroscope.constructor, .{ .arity = 0 });
        pub const x = bridge.accessor(Gyroscope.getX, null, .{});
        pub const y = bridge.accessor(Gyroscope.getY, null, .{});
        pub const z = bridge.accessor(Gyroscope.getZ, null, .{});
    };
};

/// The abstract orientation base: quaternion plus a populateMatrix that has
/// nothing to populate.
pub const OrientationSensor = struct {
    pub const Proto = Sensor;

    const sensor_tag = "orientation_sensor";

    pub const Type = union(enum) {
        absolute: *AbsoluteOrientationSensor,
        relative: *RelativeOrientationSensor,
    };

    _proto: *Sensor,
    _type: Type,

    pub fn getQuaternion(_: *const OrientationSensor) ?[]const f64 {
        return null;
    }

    // NotReadableError has no legacy code and no entry in DOMException's error
    // set, so it travels back as a built exception rather than as a Zig error.
    const Populated = union(enum) {
        exception: js.Exception,
        undefined: void,
    };

    // The target may be a DOMMatrix, a Float32Array or a Float64Array. The
    // length check comes before the no-data one: a short Float32Array is a
    // TypeError, a 16-element one is the NotReadableError (measured).
    pub fn populateMatrix(_: *OrientationSensor, target_: ?js.Value, exec: *const Execution) !Populated {
        const target = target_ orelse return throwTypeError(
            "Failed to execute 'populateMatrix' on 'OrientationSensor': 1 argument required, but only 0 present.",
            exec,
        );

        const length: ?usize = blk: {
            if (target.isFloat32Array()) {
                break :blk (try target.toZig(js.TypedArray(f32))).values.len;
            }
            if (target.isFloat64Array()) {
                break :blk (try target.toZig(js.TypedArray(f64))).values.len;
            }
            if (target.isObject()) {
                if (target.toZig(*DOMMatrix)) |_| break :blk null else |_| {}
            }
            return throwTypeError(
                "Failed to execute 'populateMatrix' on 'OrientationSensor': The provided value is not of " ++
                    "type '(DOMMatrix or Float32Array or Float64Array)'.",
                exec,
            );
        };

        if (length) |len| {
            if (len < 16) {
                return throwTypeError(
                    "Failed to execute 'populateMatrix' on 'OrientationSensor': Target buffer must have " ++
                        "at least 16 elements.",
                    exec,
                );
            }
        }

        const dom = try exec.arena.create(DOMException);
        dom.* = DOMException.init(
            "Failed to execute 'populateMatrix' on 'OrientationSensor': Sensor data is not available.",
            "NotReadableError",
        );
        return .{ .exception = exec.js.local.?.newException(dom) };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OrientationSensor);

        pub const Meta = struct {
            pub const name = "OrientationSensor";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Sensor;

        pub const quaternion = bridge.accessor(OrientationSensor.getQuaternion, null, .{});
        pub const populateMatrix = bridge.function(OrientationSensor.populateMatrix, .{ .arity = 1 });
    };
};

/// The four leaves that add nothing of their own: they exist so a script can
/// see the right brand and the right prototype chain.
fn Leaf(comptime interface: []const u8, comptime Parent: type, comptime tag: []const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = Parent;

        _proto: *Parent,

        pub fn constructor(options_: ?js.Value, exec: *const Execution) !*Self {
            try Options.read(interface, options_, exec);
            const leaf = try exec._factory.chained(.{
                EventTarget{ ._type = undefined },
                Sensor{ ._proto = undefined, ._type = undefined },
                Parent{ ._proto = undefined, ._type = undefined },
                Self{ ._proto = undefined },
            });
            const parent = leaf._proto;
            parent._type = @unionInit(Parent.Type, tag, leaf);
            link(parent._proto, @unionInit(Sensor.Type, Parent.sensor_tag, parent));
            return leaf;
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = interface;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const Prototype = Parent;

            pub const constructor = bridge.constructor(Self.constructor, .{ .arity = 0 });
        };
    };
}

pub const LinearAccelerationSensor = Leaf("LinearAccelerationSensor", Accelerometer, "linear_acceleration");
pub const GravitySensor = Leaf("GravitySensor", Accelerometer, "gravity");
pub const AbsoluteOrientationSensor = Leaf("AbsoluteOrientationSensor", OrientationSensor, "absolute");
pub const RelativeOrientationSensor = Leaf("RelativeOrientationSensor", OrientationSensor, "relative");

// Ties a freshly chained sensor to its EventTarget and records which concrete
// sensor it is, so both levels resolve down to the leaf's JS object.
fn link(sensor: *Sensor, typ: Sensor.Type) void {
    sensor._proto._type = .sensor;
    sensor._type = typ;
}

/// The event a failed start() fires. `error` is a required member of its init
/// dictionary and has to be a DOMException, so each way of getting it wrong
/// has its own message.
pub const SensorErrorEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _error: *DOMException,

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*SensorErrorEvent {
        const type_value = type_ orelse return throwTypeError(
            "Failed to construct 'SensorErrorEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return throwTypeError(
            "Failed to construct 'SensorErrorEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const typ = try type_value.toStringSlice();

        const member = if (options.isObject()) try options.toObject().get("error") else null;
        const value = member orelse return throwTypeError(
            "Failed to construct 'SensorErrorEvent': Failed to read the 'error' property from " ++
                "'SensorErrorEventInit': Required member is undefined.",
            exec,
        );
        if (value.isUndefined()) {
            return throwTypeError(
                "Failed to construct 'SensorErrorEvent': Failed to read the 'error' property from " ++
                    "'SensorErrorEventInit': Required member is undefined.",
                exec,
            );
        }
        const dom = value.toZig(*DOMException) catch return throwTypeError(
            "Failed to construct 'SensorErrorEvent': Failed to read the 'error' property from " ++
                "'SensorErrorEventInit': Failed to convert value to 'DOMException'.",
            exec,
        );

        const event_options = try Event.optionsFromJs(options);

        const arena = try exec.getArena(.tiny, "SensorErrorEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            SensorErrorEvent{ ._proto = undefined, ._error = dom },
        );
        Event.populatePrototypes(event, event_options, false);
        return event;
    }

    fn initTrusted(dom: *DOMException, exec: *const Execution) !*SensorErrorEvent {
        const arena = try exec.getArena(.tiny, "SensorErrorEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), "error", .{}),
            SensorErrorEvent{ ._proto = undefined, ._error = dom },
        );
        Event.populatePrototypes(event, Event.Options{}, true);
        return event;
    }

    pub fn asEvent(self: *SensorErrorEvent) *Event {
        return self._proto;
    }

    // The very DOMException that was handed in, not a copy (measured).
    pub fn getError(self: *const SensorErrorEvent) *DOMException {
        return self._error;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SensorErrorEvent);

        pub const Meta = struct {
            pub const name = "SensorErrorEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(SensorErrorEvent.constructor, .{ .arity = 2 });
        pub const @"error" = bridge.accessor(SensorErrorEvent.getError, null, .{});
    };
};
