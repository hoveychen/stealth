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

//! The Web MIDI API.
//!
//! Six of the eight interfaces here are unreachable from script, and that is
//! the answer rather than a gap: navigator.requestMIDIAccess never settles --
//! which is where Chrome's own permission prompt leaves it, measured on a
//! headed Chrome 150 over http://localhost -- so no MIDIAccess is ever handed
//! out, and with it no port and no map. Resolving one would mean inventing a
//! permission grant and a device list this engine does not have. What a script
//! can see is the interface: the constructor, the prototype and its members,
//! all shaped as Chrome shapes them (win11-chrome.json).
//!
//! MIDIMessageEvent and MIDIConnectionEvent are a different matter -- a script
//! constructs those itself -- so they behave: data keeps the very Uint8Array
//! it was handed, port refuses everything because there is no MIDIPort to
//! accept, and each way of getting the dictionary wrong carries Chrome's own
//! wording.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const Frame = @import("../Frame.zig");
const EventTarget = @import("EventTarget.zig");
const handler_property = @import("handler_property.zig");

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
        MIDIAccess,
        MIDIPort,
        MIDIInput,
        MIDIOutput,
        MIDIInputMap,
        MIDIInputMap.KeyIterator,
        MIDIInputMap.ValueIterator,
        MIDIInputMap.EntryIterator,
        MIDIOutputMap,
        MIDIOutputMap.KeyIterator,
        MIDIOutputMap.ValueIterator,
        MIDIOutputMap.EntryIterator,
        MIDIMessageEvent,
        MIDIConnectionEvent,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

/// The entry point a granted requestMIDIAccess would hand back. Nothing
/// constructs one, so its members describe an access with no devices.
pub const MIDIAccess = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _inputs: MIDIInputMap = .{},
    _outputs: MIDIOutputMap = .{},

    pub fn getInputs(self: *MIDIAccess) *MIDIInputMap {
        return &self._inputs;
    }

    pub fn getOutputs(self: *MIDIAccess) *MIDIOutputMap {
        return &self._outputs;
    }

    pub fn getSysexEnabled(_: *const MIDIAccess) bool {
        return false;
    }

    pub fn asEventTarget(self: *MIDIAccess) *EventTarget {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MIDIAccess);

        pub const Meta = struct {
            pub const name = "MIDIAccess";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        // Chrome's own prototype order.
        pub const inputs = bridge.accessor(MIDIAccess.getInputs, null, .{});
        pub const outputs = bridge.accessor(MIDIAccess.getOutputs, null, .{});
        pub const sysexEnabled = bridge.accessor(MIDIAccess.getSysexEnabled, null, .{});
        pub const onstatechange = bridge.accessor(handlerProperty(MIDIAccess, .onstatechange).get, handlerProperty(MIDIAccess, .onstatechange).set, .{});
    };
};

/// One end of a MIDI connection. The base of MIDIInput and MIDIOutput, and
/// like them never instantiated here.
pub const MIDIPort = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _id: []const u8 = "",
    _manufacturer: []const u8 = "",
    _name: []const u8 = "",
    _version: []const u8 = "",
    _type: []const u8 = "input",
    _state: []const u8 = "disconnected",
    _connection: []const u8 = "closed",

    pub fn getConnection(self: *const MIDIPort) []const u8 {
        return self._connection;
    }

    pub fn getId(self: *const MIDIPort) []const u8 {
        return self._id;
    }

    pub fn getManufacturer(self: *const MIDIPort) []const u8 {
        return self._manufacturer;
    }

    pub fn getName(self: *const MIDIPort) []const u8 {
        return self._name;
    }

    pub fn getState(self: *const MIDIPort) []const u8 {
        return self._state;
    }

    pub fn getType(self: *const MIDIPort) []const u8 {
        return self._type;
    }

    pub fn getVersion(self: *const MIDIPort) []const u8 {
        return self._version;
    }

    // A port that does not exist cannot be opened or closed, and there is no
    // device to wait on, so both settle at once with the port itself.
    pub fn close(self: *MIDIPort, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(self);
    }

    pub fn open(self: *MIDIPort, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(self);
    }

    pub fn asEventTarget(self: *MIDIPort) *EventTarget {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MIDIPort);

        pub const Meta = struct {
            pub const name = "MIDIPort";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        pub const connection = bridge.accessor(MIDIPort.getConnection, null, .{});
        pub const id = bridge.accessor(MIDIPort.getId, null, .{});
        pub const manufacturer = bridge.accessor(MIDIPort.getManufacturer, null, .{});
        pub const name = bridge.accessor(MIDIPort.getName, null, .{});
        pub const state = bridge.accessor(MIDIPort.getState, null, .{});
        pub const @"type" = bridge.accessor(MIDIPort.getType, null, .{});
        pub const version = bridge.accessor(MIDIPort.getVersion, null, .{});
        pub const onstatechange = bridge.accessor(handlerProperty(MIDIPort, .onstatechange).get, handlerProperty(MIDIPort, .onstatechange).set, .{});
        pub const close = bridge.function(MIDIPort.close, .{});
        pub const open = bridge.function(MIDIPort.open, .{});
    };
};

pub const MIDIInput = struct {
    pub const Proto = MIDIPort;

    _proto: *MIDIPort,

    pub fn asEventTarget(self: *MIDIInput) *EventTarget {
        return self._proto.asEventTarget();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MIDIInput);

        pub const Meta = struct {
            pub const name = "MIDIInput";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = MIDIPort;

        pub const onmidimessage = bridge.accessor(handlerProperty(MIDIInput, .onmidimessage).get, handlerProperty(MIDIInput, .onmidimessage).set, .{});
    };
};

pub const MIDIOutput = struct {
    pub const Proto = MIDIPort;

    _proto: *MIDIPort,

    // Nowhere to send it.
    pub fn send(_: *MIDIOutput, _: js.Value, _: ?f64) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MIDIOutput);

        pub const Meta = struct {
            pub const name = "MIDIOutput";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = MIDIPort;

        pub const send = bridge.function(MIDIOutput.send, .{ .arity = 1 });
    };
};

/// The two readonly maplikes. They are identical but for their name, and both
/// are always empty: there is no MIDIAccess to reach one through, and no
/// device to put in it if there were.
fn PortMap(comptime interface: []const u8) type {
    return struct {
        const Self = @This();

        const Pair = struct { []const u8, *MIDIPort };

        _ports: []const Pair = &.{},

        pub fn getSize(self: *const Self) u32 {
            return @intCast(self._ports.len);
        }

        pub fn get(self: *const Self, id: []const u8) ?*MIDIPort {
            for (self._ports) |pair| {
                if (std.mem.eql(u8, pair[0], id)) {
                    return pair[1];
                }
            }
            return null;
        }

        pub fn has(self: *const Self, id: []const u8) bool {
            return self.get(id) != null;
        }

        pub fn keys(self: *Self, frame: *Frame) !*KeyIterator {
            return .init(.{ .map = self }, frame);
        }

        pub fn values(self: *Self, frame: *Frame) !*ValueIterator {
            return .init(.{ .map = self }, frame);
        }

        pub fn entries(self: *Self, frame: *Frame) !*EntryIterator {
            return .init(.{ .map = self }, frame);
        }

        pub fn forEach(self: *Self, cb_: js.Function, js_this_: ?js.Object) !void {
            const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
            for (self._ports) |pair| {
                var caught: js.TryCatch.Caught = .{};
                cb.tryCall(void, .{ pair[1], pair[0], self }, &caught) catch {
                    log.debug(.js, "forEach callback", .{ .caught = caught, .source = interface });
                };
            }
        }

        pub const Iterator = struct {
            index: u32 = 0,
            map: *Self,

            pub const Entry = Pair;

            pub fn next(self: *Iterator, _: *const Frame) ?Entry {
                const index = self.index;
                if (index >= self.map._ports.len) {
                    return null;
                }
                self.index = index + 1;
                return self.map._ports[index];
            }
        };

        const GenericIterator = @import("collections/iterator.zig").Entry;
        pub const KeyIterator = GenericIterator(Iterator, "0");
        pub const ValueIterator = GenericIterator(Iterator, "1");
        pub const EntryIterator = GenericIterator(Iterator, null);

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = interface;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            // Chrome's own prototype order.
            pub const size = bridge.accessor(Self.getSize, null, .{});
            pub const entries = bridge.function(Self.entries, .{});
            pub const forEach = bridge.function(Self.forEach, .{});
            pub const get = bridge.function(Self.get, .{});
            pub const has = bridge.function(Self.has, .{});
            pub const keys = bridge.function(Self.keys, .{});
            pub const values = bridge.function(Self.values, .{});
            pub const symbol_iterator = bridge.iterator(Self.entries, .{});
        };
    };
}

pub const MIDIInputMap = PortMap("MIDIInputMap");
pub const MIDIOutputMap = PortMap("MIDIOutputMap");

/// A MIDI message. Script-constructible, so this one really behaves: `data` is
/// the very Uint8Array it was handed, not a copy (measured -- a later write to
/// the array is visible through the event).
pub const MIDIMessageEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _data: ?js.Value.Global = null,

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*MIDIMessageEvent {
        const typ = try readEventType("MIDIMessageEvent", type_, exec);

        var data: ?js.Value.Global = null;
        if (options_) |options| {
            if (options.isObject()) {
                const member = try options.toObject().get("data");
                if (!member.isNullOrUndefined()) {
                    if (!member.isUint8Array()) {
                        return throwTypeError(
                            "Failed to construct 'MIDIMessageEvent': Failed to read the 'data' property " ++
                                "from 'MIDIMessageEventInit': Failed to convert value to 'Uint8Array'.",
                            exec,
                        );
                    }
                    data = try member.persist();
                }
            }
        }

        return buildEvent(MIDIMessageEvent{ ._proto = undefined, ._data = data }, typ, options_, exec);
    }

    pub fn getData(self: *const MIDIMessageEvent) ?js.Value.Global {
        return self._data;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MIDIMessageEvent);

        pub const Meta = struct {
            pub const name = "MIDIMessageEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(MIDIMessageEvent.constructor, .{ .arity = 1 });
        pub const data = bridge.accessor(MIDIMessageEvent.getData, null, .{});
    };
};

/// A port's state change. `port` is a MIDIPort, and this engine has none, so
/// every value but null and undefined is refused.
pub const MIDIConnectionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _port: ?*MIDIPort = null,

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*MIDIConnectionEvent {
        const typ = try readEventType("MIDIConnectionEvent", type_, exec);

        var port: ?*MIDIPort = null;
        if (options_) |options| {
            if (options.isObject()) {
                const member = try options.toObject().get("port");
                if (!member.isNullOrUndefined()) {
                    port = member.toZig(*MIDIPort) catch return throwTypeError(
                        "Failed to construct 'MIDIConnectionEvent': Failed to read the 'port' property " ++
                            "from 'MIDIConnectionEventInit': Failed to convert value to 'MIDIPort'.",
                        exec,
                    );
                }
            }
        }

        return buildEvent(MIDIConnectionEvent{ ._proto = undefined, ._port = port }, typ, options_, exec);
    }

    pub fn getPort(self: *const MIDIConnectionEvent) ?*MIDIPort {
        return self._port;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MIDIConnectionEvent);

        pub const Meta = struct {
            pub const name = "MIDIConnectionEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(MIDIConnectionEvent.constructor, .{ .arity = 1 });
        pub const port = bridge.accessor(MIDIConnectionEvent.getPort, null, .{});
    };
};

fn readEventType(comptime interface: []const u8, type_: ?js.Value, exec: *const Execution) ![]const u8 {
    const value = type_ orelse return throwTypeError(
        "Failed to construct '" ++ interface ++ "': 1 argument required, but only 0 present.",
        exec,
    );
    return value.toStringSlice();
}

// Both events read the same three Event init members, and neither adds one of
// its own that Event has to know about.
fn buildEvent(child: anytype, typ: []const u8, options_: ?js.Value, exec: *const Execution) !*@TypeOf(child) {
    const T = @TypeOf(child);

    const options = try Event.optionsFromJs(options_);

    const arena = try exec.getArena(.tiny, T.JsApi.Meta.name);
    errdefer arena.release();

    const event = try exec._factory.event(arena, try String.init(arena.allocator(), typ, .{}), child);
    Event.populatePrototypes(event, options, false);
    return event;
}
