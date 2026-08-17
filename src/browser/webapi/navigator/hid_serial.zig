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

//! WebHID's and Web Serial's device sides: the three HID interfaces and
//! SerialPort.
//!
//! Same story as WebUSB and Web Bluetooth: navigator.hid.requestDevice and
//! navigator.serial.requestPort reject without a user gesture and neither
//! getDevices() nor getPorts() has anything to list, so no HIDDevice and no
//! SerialPort is ever handed out. Their members answer for a device that was
//! never opened rather than inventing one.
//!
//! HIDConnectionEvent is the only one of the four with a constructor, and it
//! cannot succeed either: its init dictionary requires an HIDDevice. It still
//! refuses the way Chrome refuses -- counting arguments first, then naming the
//! missing member, then naming the type it could not convert to.
//!
//! Measured on a headed Chrome 150 over http://localhost (win13-chrome.json
//! for the shapes, win13b-chrome.json for the behaviours).

const std = @import("std");

const js = @import("../../js/js.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        HIDDevice,
        HIDConnectionEvent,
        HIDInputReportEvent,
        SerialPort,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn handlerAccessors(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn get(self: *T) ?js.Function.Global {
            return @field(self, field);
        }

        fn set(self: *T, listener: ?js.Function) !void {
            @field(self, field) = if (listener) |l| try l.persistWithThis(self) else null;
        }
    };
}

// Nothing is open, so every operation that would need an open device fails the
// way Chrome fails one: NotFoundError, not a hang.
fn notOpen(exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotFoundError } });
}

pub const HIDDevice = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *HIDDevice) *EventTarget {
        return self._proto;
    }

    pub fn getOpened(_: *const HIDDevice) bool {
        return false;
    }

    fn zero(_: *const HIDDevice) u16 {
        return 0;
    }

    pub fn getProductName(_: *const HIDDevice) []const u8 {
        return "";
    }

    pub fn getCollections(_: *const HIDDevice) []const []const u8 {
        return &.{};
    }

    fn refuse(_: *const HIDDevice, exec: *const Execution) js.Promise {
        return notOpen(exec);
    }

    fn refuse1(_: *const HIDDevice, _: ?js.Value, exec: *const Execution) js.Promise {
        return notOpen(exec);
    }

    fn refuse2(_: *const HIDDevice, _: ?js.Value, _: ?js.Value, exec: *const Execution) js.Promise {
        return notOpen(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HIDDevice);

        pub const Meta = struct {
            pub const name = "HIDDevice";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const D = HIDDevice;

        // Chrome's own prototype order.
        pub const oninputreport = bridge.accessor(handlerProperty(HIDDevice, .oninputreport).get, handlerProperty(HIDDevice, .oninputreport).set, .{});
        pub const opened = bridge.accessor(D.getOpened, null, .{});
        pub const vendorId = bridge.accessor(D.zero, null, .{});
        pub const productId = bridge.accessor(D.zero, null, .{});
        pub const productName = bridge.accessor(D.getProductName, null, .{});
        pub const collections = bridge.accessor(D.getCollections, null, .{});
        pub const close = bridge.function(D.refuse, .{ .arity = 0 });
        pub const forget = bridge.function(D.refuse, .{ .arity = 0 });
        pub const open = bridge.function(D.refuse, .{ .arity = 0 });
        pub const receiveFeatureReport = bridge.function(D.refuse1, .{ .arity = 1 });
        pub const sendFeatureReport = bridge.function(D.refuse2, .{ .arity = 2 });
        pub const sendReport = bridge.function(D.refuse2, .{ .arity = 2 });
    };
};

/// The connect / disconnect event. Its init dictionary requires an HIDDevice,
/// so no script can build one.
pub const HIDConnectionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*HIDConnectionEvent {
        const got: usize = if (type_ == null) 0 else if (options_ == null) 1 else 2;
        if (got < 2) return throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'HIDConnectionEvent': 2 arguments required, but only {d} present.",
            .{got},
        ), exec);

        const options = options_.?;
        // Anything that is not a dictionary is refused by name, before any member
        // is looked at -- including an explicit undefined, which is why an absent
        // second argument (counted above) and `undefined` differ (measured).
        if (!options.isObject()) return throwTypeError(
            "Failed to construct 'HIDConnectionEvent': The provided value is not of type " ++
                "'HIDConnectionEventInit'.",
            exec,
        );
        const member = try options.toObject().get("device");
        if (member.isUndefined()) return throwTypeError(
            "Failed to construct 'HIDConnectionEvent': Failed to read the 'device' property " ++
                "from 'HIDConnectionEventInit': Required member is undefined.",
            exec,
        );
        // There is no HIDDevice to convert to, so every value fails here.
        return throwTypeError(
            "Failed to construct 'HIDConnectionEvent': Failed to read the 'device' property " ++
                "from 'HIDConnectionEventInit': Failed to convert value to 'HIDDevice'.",
            exec,
        );
    }

    pub fn getDevice(_: *const HIDConnectionEvent) ?*HIDDevice {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HIDConnectionEvent);

        pub const Meta = struct {
            pub const name = "HIDConnectionEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(HIDConnectionEvent.constructor, .{ .arity = 2 });
        pub const device = bridge.accessor(HIDConnectionEvent.getDevice, null, .{});
    };
};

/// Dispatched when an open device reports. Nothing here ever opens one, and
/// Chrome does not let a script construct it either.
pub const HIDInputReportEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    pub fn getDevice(_: *const HIDInputReportEvent) ?*HIDDevice {
        return null;
    }

    pub fn getReportId(_: *const HIDInputReportEvent) u8 {
        return 0;
    }

    pub fn getData(_: *const HIDInputReportEvent) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HIDInputReportEvent);

        pub const Meta = struct {
            pub const name = "HIDInputReportEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const device = bridge.accessor(HIDInputReportEvent.getDevice, null, .{});
        pub const reportId = bridge.accessor(HIDInputReportEvent.getReportId, null, .{});
        pub const data = bridge.accessor(HIDInputReportEvent.getData, null, .{});
    };
};

pub const SerialPort = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *SerialPort) *EventTarget {
        return self._proto;
    }

    pub fn getReadable(_: *const SerialPort) ?[]const u8 {
        return null;
    }

    pub fn getWritable(_: *const SerialPort) ?[]const u8 {
        return null;
    }

    pub fn getConnected(_: *const SerialPort) bool {
        return false;
    }

    fn refuse(_: *const SerialPort, exec: *const Execution) js.Promise {
        return notOpen(exec);
    }

    fn refuse1(_: *const SerialPort, _: ?js.Value, exec: *const Execution) js.Promise {
        return notOpen(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SerialPort);

        pub const Meta = struct {
            pub const name = "SerialPort";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const P = SerialPort;

        // Chrome's own prototype order, `connected` included -- it comes after
        // setSignals rather than beside readable and writable.
        pub const onconnect = bridge.accessor(handlerProperty(SerialPort, .onconnect).get, handlerProperty(SerialPort, .onconnect).set, .{});
        pub const ondisconnect = bridge.accessor(handlerProperty(SerialPort, .ondisconnect).get, handlerProperty(SerialPort, .ondisconnect).set, .{});
        pub const readable = bridge.accessor(P.getReadable, null, .{});
        pub const writable = bridge.accessor(P.getWritable, null, .{});
        pub const close = bridge.function(P.refuse, .{ .arity = 0 });
        pub const forget = bridge.function(P.refuse, .{ .arity = 0 });
        pub const getInfo = bridge.function(P.refuse, .{ .arity = 0 });
        pub const getSignals = bridge.function(P.refuse, .{ .arity = 0 });
        pub const open = bridge.function(P.refuse1, .{ .arity = 1 });
        pub const setSignals = bridge.function(P.refuse1, .{ .arity = 0 });
        pub const connected = bridge.accessor(P.getConnected, null, .{});
    };
};
