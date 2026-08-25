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

//! WebUSB's device side: the twelve interfaces a granted chooser would hand
//! back.
//!
//! navigator.usb.requestDevice rejects -- Chrome will not open the chooser
//! without a user gesture and nothing here ever has one -- and getDevices()
//! answers with an empty list, so no USBDevice is ever handed out. That makes
//! USBDevice itself unreachable, and with it the four interfaces whose
//! constructors demand one: USBConfiguration wants a USBDevice,
//! USBInterface wants a USBConfiguration, USBAlternateInterface wants a
//! USBInterface, USBEndpoint wants a USBAlternateInterface, and
//! USBConnectionEvent wants a USBDevice in its init dictionary. Each of them
//! refuses with the wording Chrome uses for exactly that refusal, which is the
//! honest answer: there is no device to describe.
//!
//! The six transfer results are a different matter -- a script constructs
//! those out of plain values -- so they behave: the status enum is checked, a
//! DataView is kept as the very object it was handed, bytesWritten defaults to
//! zero, and each way of getting it wrong carries Chrome's own message.
//!
//! Everything was measured on a headed Chrome 150 over http://localhost
//! (win13-chrome.json for the shapes, win13b-chrome.json for the behaviours).
//!
//! `packets` is a FrozenArray and comes back frozen, fresh on every access
//! (measured: result.packets !== result.packets), with the same element objects
//! in both.
//!
//! One measured difference remains: a `sequence<T>` here accepts an Array where
//! Chrome accepts any iterable, so
//! `new USBIsochronousInTransferResult(new Set([packet]))` builds a result on
//! Chrome and is refused here. Telling a non-Array iterable from a plain object
//! needs a symbol-keyed property lookup this bridge does not expose; the three
//! refusal messages that do not need one are all reproduced.

const std = @import("std");

const js = @import("../../js/js.zig");
const Event = @import("../Event.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        USBDevice,
        USBConfiguration,
        USBInterface,
        USBAlternateInterface,
        USBEndpoint,
        USBInTransferResult,
        USBOutTransferResult,
        USBIsochronousInTransferPacket,
        USBIsochronousInTransferResult,
        USBIsochronousOutTransferPacket,
        USBIsochronousOutTransferResult,
        USBConnectionEvent,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

// "1 argument required, but only 0 present." -- Chrome counts what it got.
fn argCount(comptime interface: []const u8, comptime required: usize, got: usize, exec: *const Execution) anyerror {
    const plural = if (required == 1) " argument required, but only " else " arguments required, but only ";
    return throwTypeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to construct '" ++ interface ++ "': {d}" ++ plural ++ "{d} present.",
        .{ required, got },
    ), exec);
}

// Every one of these four is unreachable because its first parameter is an
// object no script can obtain, so the constructor never gets past that check.
fn wrongFirstParameter(
    comptime interface: []const u8,
    comptime wanted: []const u8,
    args: []const ?js.Value,
    comptime required: usize,
    exec: *const Execution,
) anyerror {
    var present: usize = 0;
    for (args) |arg| {
        if (arg == null) break;
        present += 1;
    }
    if (present < required) return argCount(interface, required, present, exec);
    return throwTypeError(
        "Failed to construct '" ++ interface ++ "': parameter 1 is not of type '" ++ wanted ++ "'.",
        exec,
    );
}

const TransferStatus = enum {
    ok,
    stall,
    babble,

    // A USBTransferStatus that is not one of the three carries the enum's name.
    fn parse(comptime interface: []const u8, value: ?js.Value, exec: *const Execution) !TransferStatus {
        const given = value orelse return argCount(interface, 1, 0, exec);
        const text = try given.toStringSlice();
        return std.meta.stringToEnum(TransferStatus, text) orelse throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct '" ++ interface ++ "': The provided value '{s}' is not a valid " ++
                "enum value of type USBTransferStatus.",
            .{text},
        ), exec);
    }
};

// bytesWritten is an `unsigned long` with a default of 0 (measured).
fn bytesWritten(value: ?js.Value) !u32 {
    const given = value orelse return 0;
    if (given.isNullOrUndefined()) return 0;
    const number = given.toZig(f64) catch return 0;
    if (std.math.isNan(number) or std.math.isInf(number)) return 0;
    return @intFromFloat(@mod(@trunc(number), 4294967296));
}

// `DataView? data`, defaulting to null, kept as the very object handed in.
fn dataView(comptime interface: []const u8, value: ?js.Value, exec: *const Execution) !?js.Value.Global {
    const given = value orelse return null;
    if (given.isNullOrUndefined()) return null;
    // A DataView is an ArrayBufferView that is not a typed array.
    if (!given.isArrayBufferView() or given.isTypedArray()) return throwTypeError(
        "Failed to construct '" ++ interface ++ "': parameter 2 is not of type 'DataView'.",
        exec,
    );
    return try given.persist();
}

// A packet list: the elements are kept, and a fresh array is built on every
// access -- Chrome does the same (measured: result.packets !== result.packets).
fn packetList(comptime T: type, comptime interface: []const u8, value: ?js.Value, exec: *const Execution) ![]const *T {
    const given = value orelse return argCount(interface, 1, 0, exec);
    // Chrome takes a `sequence<T>` through three distinct refusals, measured:
    // a primitive cannot be a sequence at all; an object without @@iterator is
    // named as such (and a string counts as a primitive here, not as the
    // iterable JS makes it); and only once it is iterating does a bad element
    // get blamed.
    if (!given.isObject()) return throwTypeError(
        "Failed to construct '" ++ interface ++ "': The provided value cannot be converted to a sequence.",
        exec,
    );
    if (!given.isArray()) return throwTypeError(
        "Failed to construct '" ++ interface ++ "': The object must have a callable @@iterator property.",
        exec,
    );
    return given.toZig([]const *T) catch throwTypeError(
        "Failed to construct '" ++ interface ++ "': Failed to convert value to '" ++ T.JsApi.Meta.name ++ "'.",
        exec,
    );
}

/// The device a granted chooser would hand back. Nothing constructs one, so its
/// members describe a device that was never opened.
pub const USBDevice = struct {
    _pad: bool = false,

    fn zero(_: *const USBDevice) u8 {
        return 0;
    }

    fn noName(_: *const USBDevice) ?[]const u8 {
        return null;
    }

    fn notOpen(_: *const USBDevice, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotFoundError } });
    }

    pub fn getConfiguration(_: *const USBDevice) ?*USBConfiguration {
        return null;
    }

    pub fn getConfigurations(_: *const USBDevice) []const *USBConfiguration {
        return &.{};
    }

    pub fn getOpened(_: *const USBDevice) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBDevice);

        pub const Meta = struct {
            pub const name = "USBDevice";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const D = USBDevice;

        // Chrome's own prototype order.
        pub const usbVersionMajor = bridge.accessor(D.zero, null, .{});
        pub const usbVersionMinor = bridge.accessor(D.zero, null, .{});
        pub const usbVersionSubminor = bridge.accessor(D.zero, null, .{});
        pub const deviceClass = bridge.accessor(D.zero, null, .{});
        pub const deviceSubclass = bridge.accessor(D.zero, null, .{});
        pub const deviceProtocol = bridge.accessor(D.zero, null, .{});
        pub const vendorId = bridge.accessor(D.zero, null, .{});
        pub const productId = bridge.accessor(D.zero, null, .{});
        pub const deviceVersionMajor = bridge.accessor(D.zero, null, .{});
        pub const deviceVersionMinor = bridge.accessor(D.zero, null, .{});
        pub const deviceVersionSubminor = bridge.accessor(D.zero, null, .{});
        pub const manufacturerName = bridge.accessor(D.noName, null, .{});
        pub const productName = bridge.accessor(D.noName, null, .{});
        pub const serialNumber = bridge.accessor(D.noName, null, .{});
        pub const configuration = bridge.accessor(D.getConfiguration, null, .{});
        pub const configurations = bridge.accessor(D.getConfigurations, null, .{});
        pub const opened = bridge.accessor(D.getOpened, null, .{});
        pub const claimInterface = bridge.function(D.notOpen, .{ .arity = 1 });
        pub const clearHalt = bridge.function(D.notOpen, .{ .arity = 2 });
        pub const close = bridge.function(D.notOpen, .{ .arity = 0 });
        pub const controlTransferIn = bridge.function(D.notOpen, .{ .arity = 2 });
        pub const controlTransferOut = bridge.function(D.notOpen, .{ .arity = 1 });
        pub const forget = bridge.function(D.notOpen, .{ .arity = 0 });
        pub const isochronousTransferIn = bridge.function(D.notOpen, .{ .arity = 2 });
        pub const isochronousTransferOut = bridge.function(D.notOpen, .{ .arity = 3 });
        pub const open = bridge.function(D.notOpen, .{ .arity = 0 });
        pub const releaseInterface = bridge.function(D.notOpen, .{ .arity = 1 });
        pub const reset = bridge.function(D.notOpen, .{ .arity = 0 });
        pub const selectAlternateInterface = bridge.function(D.notOpen, .{ .arity = 2 });
        pub const selectConfiguration = bridge.function(D.notOpen, .{ .arity = 1 });
        pub const transferIn = bridge.function(D.notOpen, .{ .arity = 2 });
        pub const transferOut = bridge.function(D.notOpen, .{ .arity = 2 });
    };
};

pub const USBConfiguration = struct {
    _pad: bool = false,

    pub fn constructor(a: ?js.Value, b: ?js.Value, exec: *const Execution) !*USBConfiguration {
        return wrongFirstParameter("USBConfiguration", "USBDevice", &.{ a, b }, 2, exec);
    }

    pub fn getConfigurationValue(_: *const USBConfiguration) u8 {
        return 0;
    }

    pub fn getConfigurationName(_: *const USBConfiguration) ?[]const u8 {
        return null;
    }

    pub fn getInterfaces(_: *const USBConfiguration) []const *USBInterface {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBConfiguration);

        pub const Meta = struct {
            pub const name = "USBConfiguration";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(USBConfiguration.constructor, .{ .arity = 2 });
        pub const configurationValue = bridge.accessor(USBConfiguration.getConfigurationValue, null, .{});
        pub const configurationName = bridge.accessor(USBConfiguration.getConfigurationName, null, .{});
        pub const interfaces = bridge.accessor(USBConfiguration.getInterfaces, null, .{});
    };
};

pub const USBInterface = struct {
    _pad: bool = false,

    pub fn constructor(a: ?js.Value, b: ?js.Value, exec: *const Execution) !*USBInterface {
        return wrongFirstParameter("USBInterface", "USBConfiguration", &.{ a, b }, 2, exec);
    }

    pub fn getInterfaceNumber(_: *const USBInterface) u8 {
        return 0;
    }

    pub fn getAlternate(_: *const USBInterface) ?*USBAlternateInterface {
        return null;
    }

    pub fn getAlternates(_: *const USBInterface) []const *USBAlternateInterface {
        return &.{};
    }

    pub fn getClaimed(_: *const USBInterface) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBInterface);

        pub const Meta = struct {
            pub const name = "USBInterface";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(USBInterface.constructor, .{ .arity = 2 });
        pub const interfaceNumber = bridge.accessor(USBInterface.getInterfaceNumber, null, .{});
        pub const alternate = bridge.accessor(USBInterface.getAlternate, null, .{});
        pub const alternates = bridge.accessor(USBInterface.getAlternates, null, .{});
        pub const claimed = bridge.accessor(USBInterface.getClaimed, null, .{});
    };
};

pub const USBAlternateInterface = struct {
    _pad: bool = false,

    pub fn constructor(a: ?js.Value, b: ?js.Value, exec: *const Execution) !*USBAlternateInterface {
        return wrongFirstParameter("USBAlternateInterface", "USBInterface", &.{ a, b }, 2, exec);
    }

    fn zero(_: *const USBAlternateInterface) u8 {
        return 0;
    }

    pub fn getInterfaceName(_: *const USBAlternateInterface) ?[]const u8 {
        return null;
    }

    pub fn getEndpoints(_: *const USBAlternateInterface) []const *USBEndpoint {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBAlternateInterface);

        pub const Meta = struct {
            pub const name = "USBAlternateInterface";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const A = USBAlternateInterface;

        pub const constructor = bridge.constructor(A.constructor, .{ .arity = 2 });
        pub const alternateSetting = bridge.accessor(A.zero, null, .{});
        pub const interfaceClass = bridge.accessor(A.zero, null, .{});
        pub const interfaceSubclass = bridge.accessor(A.zero, null, .{});
        pub const interfaceProtocol = bridge.accessor(A.zero, null, .{});
        pub const interfaceName = bridge.accessor(A.getInterfaceName, null, .{});
        pub const endpoints = bridge.accessor(A.getEndpoints, null, .{});
    };
};

pub const USBEndpoint = struct {
    _pad: bool = false,

    pub fn constructor(a: ?js.Value, b: ?js.Value, c: ?js.Value, exec: *const Execution) !*USBEndpoint {
        return wrongFirstParameter("USBEndpoint", "USBAlternateInterface", &.{ a, b, c }, 3, exec);
    }

    pub fn getEndpointNumber(_: *const USBEndpoint) u8 {
        return 0;
    }

    pub fn getDirection(_: *const USBEndpoint) []const u8 {
        return "in";
    }

    pub fn getType(_: *const USBEndpoint) []const u8 {
        return "bulk";
    }

    pub fn getPacketSize(_: *const USBEndpoint) u32 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBEndpoint);

        pub const Meta = struct {
            pub const name = "USBEndpoint";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(USBEndpoint.constructor, .{ .arity = 3 });
        pub const endpointNumber = bridge.accessor(USBEndpoint.getEndpointNumber, null, .{});
        pub const direction = bridge.accessor(USBEndpoint.getDirection, null, .{});
        pub const @"type" = bridge.accessor(USBEndpoint.getType, null, .{});
        pub const packetSize = bridge.accessor(USBEndpoint.getPacketSize, null, .{});
    };
};

pub const USBInTransferResult = struct {
    _status: TransferStatus,
    _data: ?js.Value.Global = null,

    pub fn constructor(status_: ?js.Value, data_: ?js.Value, exec: *const Execution) !*USBInTransferResult {
        const status = try TransferStatus.parse("USBInTransferResult", status_, exec);
        return exec._factory.create(USBInTransferResult{
            ._status = status,
            ._data = try dataView("USBInTransferResult", data_, exec),
        });
    }

    pub fn getData(self: *const USBInTransferResult) ?js.Value.Global {
        return self._data;
    }

    pub fn getStatus(self: *const USBInTransferResult) []const u8 {
        return @tagName(self._status);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBInTransferResult);

        pub const Meta = struct {
            pub const name = "USBInTransferResult";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(USBInTransferResult.constructor, .{ .arity = 1 });
        pub const data = bridge.accessor(USBInTransferResult.getData, null, .{});
        pub const status = bridge.accessor(USBInTransferResult.getStatus, null, .{});
    };
};

pub const USBOutTransferResult = struct {
    _status: TransferStatus,
    _bytes_written: u32 = 0,

    pub fn constructor(status_: ?js.Value, written_: ?js.Value, exec: *const Execution) !*USBOutTransferResult {
        const status = try TransferStatus.parse("USBOutTransferResult", status_, exec);
        return exec._factory.create(USBOutTransferResult{
            ._status = status,
            ._bytes_written = try bytesWritten(written_),
        });
    }

    pub fn getBytesWritten(self: *const USBOutTransferResult) u32 {
        return self._bytes_written;
    }

    pub fn getStatus(self: *const USBOutTransferResult) []const u8 {
        return @tagName(self._status);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBOutTransferResult);

        pub const Meta = struct {
            pub const name = "USBOutTransferResult";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(USBOutTransferResult.constructor, .{ .arity = 1 });
        pub const bytesWritten = bridge.accessor(USBOutTransferResult.getBytesWritten, null, .{});
        pub const status = bridge.accessor(USBOutTransferResult.getStatus, null, .{});
    };
};

pub const USBIsochronousInTransferPacket = struct {
    _status: TransferStatus,
    _data: ?js.Value.Global = null,

    pub fn constructor(status_: ?js.Value, data_: ?js.Value, exec: *const Execution) !*USBIsochronousInTransferPacket {
        const status = try TransferStatus.parse("USBIsochronousInTransferPacket", status_, exec);
        return exec._factory.create(USBIsochronousInTransferPacket{
            ._status = status,
            ._data = try dataView("USBIsochronousInTransferPacket", data_, exec),
        });
    }

    pub fn getStatus(self: *const USBIsochronousInTransferPacket) []const u8 {
        return @tagName(self._status);
    }

    pub fn getData(self: *const USBIsochronousInTransferPacket) ?js.Value.Global {
        return self._data;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBIsochronousInTransferPacket);

        pub const Meta = struct {
            pub const name = "USBIsochronousInTransferPacket";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const P = USBIsochronousInTransferPacket;

        pub const constructor = bridge.constructor(P.constructor, .{ .arity = 1 });
        pub const status = bridge.accessor(P.getStatus, null, .{});
        pub const data = bridge.accessor(P.getData, null, .{});
    };
};

pub const USBIsochronousInTransferResult = struct {
    _packets: []const *USBIsochronousInTransferPacket,
    _data: ?js.Value.Global = null,

    pub fn constructor(packets_: ?js.Value, data_: ?js.Value, exec: *const Execution) !*USBIsochronousInTransferResult {
        const packets = try packetList(
            USBIsochronousInTransferPacket,
            "USBIsochronousInTransferResult",
            packets_,
            exec,
        );
        return exec._factory.create(USBIsochronousInTransferResult{
            ._packets = try exec.local_arena.dupe(*USBIsochronousInTransferPacket, packets),
            ._data = try dataView("USBIsochronousInTransferResult", data_, exec),
        });
    }

    pub fn getData(self: *const USBIsochronousInTransferResult) ?js.Value.Global {
        return self._data;
    }

    pub fn getPackets(self: *const USBIsochronousInTransferResult) js.FrozenArray(*USBIsochronousInTransferPacket) {
        return .{ .items = self._packets };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBIsochronousInTransferResult);

        pub const Meta = struct {
            pub const name = "USBIsochronousInTransferResult";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const R = USBIsochronousInTransferResult;

        pub const constructor = bridge.constructor(R.constructor, .{ .arity = 1 });
        pub const data = bridge.accessor(R.getData, null, .{});
        pub const packets = bridge.accessor(R.getPackets, null, .{});
    };
};

pub const USBIsochronousOutTransferPacket = struct {
    _status: TransferStatus,
    _bytes_written: u32 = 0,

    pub fn constructor(status_: ?js.Value, written_: ?js.Value, exec: *const Execution) !*USBIsochronousOutTransferPacket {
        const status = try TransferStatus.parse("USBIsochronousOutTransferPacket", status_, exec);
        return exec._factory.create(USBIsochronousOutTransferPacket{
            ._status = status,
            ._bytes_written = try bytesWritten(written_),
        });
    }

    pub fn getBytesWritten(self: *const USBIsochronousOutTransferPacket) u32 {
        return self._bytes_written;
    }

    pub fn getStatus(self: *const USBIsochronousOutTransferPacket) []const u8 {
        return @tagName(self._status);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBIsochronousOutTransferPacket);

        pub const Meta = struct {
            pub const name = "USBIsochronousOutTransferPacket";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const P = USBIsochronousOutTransferPacket;

        pub const constructor = bridge.constructor(P.constructor, .{ .arity = 1 });
        pub const bytesWritten = bridge.accessor(P.getBytesWritten, null, .{});
        pub const status = bridge.accessor(P.getStatus, null, .{});
    };
};

pub const USBIsochronousOutTransferResult = struct {
    _packets: []const *USBIsochronousOutTransferPacket,

    pub fn constructor(packets_: ?js.Value, exec: *const Execution) !*USBIsochronousOutTransferResult {
        const packets = try packetList(
            USBIsochronousOutTransferPacket,
            "USBIsochronousOutTransferResult",
            packets_,
            exec,
        );
        return exec._factory.create(USBIsochronousOutTransferResult{
            ._packets = try exec.local_arena.dupe(*USBIsochronousOutTransferPacket, packets),
        });
    }

    pub fn getPackets(self: *const USBIsochronousOutTransferResult) js.FrozenArray(*USBIsochronousOutTransferPacket) {
        return .{ .items = self._packets };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBIsochronousOutTransferResult);

        pub const Meta = struct {
            pub const name = "USBIsochronousOutTransferResult";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const R = USBIsochronousOutTransferResult;

        pub const constructor = bridge.constructor(R.constructor, .{ .arity = 1 });
        pub const packets = bridge.accessor(R.getPackets, null, .{});
    };
};

/// The connect / disconnect event. Its init dictionary requires a USBDevice, so
/// no script can build one -- the same reason the four device-shaped
/// constructors above are unreachable.
pub const USBConnectionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*USBConnectionEvent {
        if (type_ == null) return argCount("USBConnectionEvent", 2, 0, exec);
        const options = options_ orelse return argCount("USBConnectionEvent", 2, 1, exec);

        // Anything that is not a dictionary is refused by name, before any member
        // is looked at -- including an explicit undefined, which is why an absent
        // second argument (counted above) and `undefined` differ (measured).
        if (!options.isObject()) return throwTypeError(
            "Failed to construct 'USBConnectionEvent': The provided value is not of type " ++
                "'USBConnectionEventInit'.",
            exec,
        );
        const member = try options.toObject().get("device");
        if (member.isUndefined()) return throwTypeError(
            "Failed to construct 'USBConnectionEvent': Failed to read the 'device' property " ++
                "from 'USBConnectionEventInit': Required member is undefined.",
            exec,
        );
        // There is no USBDevice to convert to, so every value fails here.
        return throwTypeError(
            "Failed to construct 'USBConnectionEvent': Failed to read the 'device' property " ++
                "from 'USBConnectionEventInit': Failed to convert value to 'USBDevice'.",
            exec,
        );
    }

    pub fn getDevice(_: *const USBConnectionEvent) ?*USBDevice {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USBConnectionEvent);

        pub const Meta = struct {
            pub const name = "USBConnectionEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(USBConnectionEvent.constructor, .{ .arity = 2 });
        pub const device = bridge.accessor(USBConnectionEvent.getDevice, null, .{});
    };
};
