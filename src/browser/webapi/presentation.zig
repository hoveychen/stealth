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

//! The Presentation API: `navigator.presentation` and the seven interfaces
//! hanging off it.
//!
//! Only `PresentationRequest` is constructible, and it is the one with real
//! behaviour: it filters the URLs it is given by scheme, refuses a set that
//! filters down to nothing, hands out a PresentationAvailability that says
//! "no display", and refuses `start()` for want of a user gesture. Everything a
//! connection would expose is unreachable because no display is ever found, so
//! PresentationConnection / ConnectionList / Receiver are shape only.
//!
//! Measured on a headed Chrome 150 over http://localhost (win20-chrome.json for
//! the shapes, win21 and win23 for the behaviours). Three measured details that
//! a spec reading would get wrong:
//!
//!   * A URL with an unsupported scheme is *dropped*, not refused, so
//!     `new PresentationRequest('ftp://x/y')` fails as "An empty sequence of
//!     URLs is not supported" — the same NotSupportedError as `new
//!     PresentationRequest([])` — while `['ftp://a/b', 'https://ok.example/x']`
//!     succeeds.
//!   * Anything stringifiable is accepted: `new PresentationRequest(5)` and
//!     `new PresentationRequest('')` both build a request, because "5" and ""
//!     resolve against the document's base URL.
//!   * `getAvailability()` hands back the *same* PresentationAvailability object
//!     on every call for a given request.

const std = @import("std");

const js = @import("../js/js.zig");
const URL = @import("../URL.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const String = @import("../../lightpanda.zig").String;
const handler_property = @import("handler_property.zig");

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
        Presentation,
        PresentationRequest,
        PresentationAvailability,
        PresentationConnection,
        PresentationConnectionList,
        PresentationReceiver,
        PresentationConnectionAvailableEvent,
        PresentationConnectionCloseEvent,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn throwDom(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

fn rejectDom(comptime name: []const u8, message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("presentation", DOMException.init(message, name));
    return resolver.promise();
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

/// `navigator.presentation`.
pub const Presentation = struct {
    _default_request: ?*PresentationRequest = null,

    // Writable, unlike almost everything else on this family: a page nominates
    // the request the browser should use for its own "cast this tab" affordance.
    // It round-trips by identity, and null and undefined both clear it
    // (measured).
    pub fn getDefaultRequest(self: *const Presentation) ?*PresentationRequest {
        return self._default_request;
    }

    pub fn setDefaultRequest(self: *Presentation, value: ?js.Value, exec: *const Execution) !void {
        const given = value orelse {
            self._default_request = null;
            return;
        };
        if (given.isNullOrUndefined()) {
            self._default_request = null;
            return;
        }
        self._default_request = given.toZig(*PresentationRequest) catch return throwTypeError(
            "Failed to set the 'defaultRequest' property on 'Presentation': " ++
                "Failed to convert value to 'PresentationRequest'.",
            exec,
        );
    }

    // Only a page opened *as* a presentation receiver gets one, which this
    // engine never is (measured null on an ordinary page).
    pub fn getReceiver(_: *const Presentation) ?*PresentationReceiver {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Presentation);

        pub const Meta = struct {
            pub const name = "Presentation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const defaultRequest = bridge.accessor(Presentation.getDefaultRequest, Presentation.setDefaultRequest, .{});
        pub const receiver = bridge.accessor(Presentation.getReceiver, null, .{});
    };
};

/// `new PresentationRequest(url | urls)`.
pub const PresentationRequest = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _urls: []const []const u8,
    _availability: ?*PresentationAvailability = null,

    // Chrome's own list of the schemes a presentation URL may use. `https` and
    // `http` were measured directly; `cast:` was measured as accepted in a mixed
    // sequence, and the two proprietary ones ride along with it because Chrome
    // registers them the same way (not separately measured).
    const supported_schemes = [_][]const u8{ "https:", "http:", "cast:", "cast-dial:", "dial:" };

    pub fn asEventTarget(self: *PresentationRequest) *EventTarget {
        return self._proto;
    }

    pub fn constructor(urls_: ?js.Value, exec: *const Execution) !*PresentationRequest {
        const value = urls_ orelse return throwTypeError(
            "Failed to construct 'PresentationRequest': 1 argument required, but only 0 present.",
            exec,
        );

        // Relative URLs resolve against the document, which is how
        // `new PresentationRequest('receiver.html')` succeeds (measured).
        const base = try exec.call_arena.dupeZ(u8, exec.origin() orelse "");

        var collected: std.ArrayList([]const u8) = .empty;
        if (value.isArray()) {
            const list = try value.toZig([]const []const u8);
            for (list) |text| try keep(&collected, text, base, exec);
        } else {
            try keep(&collected, try value.toStringSlice(), base, exec);
        }

        // Every URL was dropped (bad scheme, or unparseable), which Chrome
        // reports as the empty-sequence refusal rather than as a scheme error.
        if (collected.items.len == 0) return throwDom(
            "NotSupportedError",
            "Failed to construct 'PresentationRequest': An empty sequence of URLs is not supported.",
            exec,
        );

        return exec._factory.eventTarget(PresentationRequest{
            ._proto = undefined,
            ._urls = collected.items,
        });
    }

    fn keep(
        collected: *std.ArrayList([]const u8),
        text: []const u8,
        base: [:0]const u8,
        exec: *const Execution,
    ) !void {
        // A URL that will not parse at all is dropped, exactly like one with an
        // unsupported scheme: both end up as the empty-sequence refusal.
        const href = URL.resolve(exec.arena, base, text, .{}) catch return;
        const scheme = URL.getProtocol(href);
        for (supported_schemes) |supported| {
            if (std.ascii.eqlIgnoreCase(scheme, supported)) {
                try collected.append(exec.arena, href);
                return;
            }
        }
    }

    // The same object every time, and it reports no display available — which is
    // what Chrome reports on a machine with nothing to cast to (measured).
    pub fn getAvailability(self: *PresentationRequest, exec: *const Execution) !js.Promise {
        if (self._availability == null) {
            self._availability = try exec._factory.eventTarget(PresentationAvailability{ ._proto = undefined });
        }
        return exec.js.local.?.resolvePromise(self._availability.?);
    }

    // Chrome refuses for want of a gesture before it looks for a display, so
    // this is the answer whatever is plugged in (measured).
    pub fn start(_: *PresentationRequest, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidAccessError",
            "Failed to execute 'start' on 'PresentationRequest': " ++
                "PresentationRequest::start() requires user gesture.",
            exec,
        );
    }

    // No connection was ever established, so there is no route to rejoin.
    pub fn reconnect(_: *PresentationRequest, id_: ?js.Value, exec: *const Execution) js.Promise {
        if (id_ == null) return exec.js.local.?.rejectPromise(.{
            .type_error = "Failed to execute 'reconnect' on 'PresentationRequest': " ++
                "1 argument required, but only 0 present.",
        });
        return rejectDom("NotFoundError", "Route not found", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationRequest);

        pub const Meta = struct {
            pub const name = "PresentationRequest";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const R = PresentationRequest;

        pub const constructor = bridge.constructor(R.constructor, .{ .arity = 1 });
        pub const onconnectionavailable = bridge.accessor(handlerProperty(PresentationRequest, .onconnectionavailable).get, handlerProperty(PresentationRequest, .onconnectionavailable).set, .{});
        pub const getAvailability = bridge.function(R.getAvailability, .{});
        pub const reconnect = bridge.function(R.reconnect, .{ .arity = 1 });
        pub const start = bridge.function(R.start, .{});
    };
};

/// What `getAvailability()` resolves with. Not constructible.
pub const PresentationAvailability = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *PresentationAvailability) *EventTarget {
        return self._proto;
    }

    pub fn getValue(_: *const PresentationAvailability) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationAvailability);

        pub const Meta = struct {
            pub const name = "PresentationAvailability";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        pub const value = bridge.accessor(PresentationAvailability.getValue, null, .{});
        pub const onchange = bridge.accessor(handlerProperty(PresentationAvailability, .onchange).get, handlerProperty(PresentationAvailability, .onchange).set, .{});
    };
};

/// A live connection to a presentation. Unreachable here: nothing ever starts or
/// rejoins one, so this is Chrome's shape with the state a closed connection
/// would report.
pub const PresentationConnection = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _binary_type: BinaryType = .arraybuffer,

    const BinaryType = enum { blob, arraybuffer };

    pub fn asEventTarget(self: *PresentationConnection) *EventTarget {
        return self._proto;
    }

    fn empty(_: *const PresentationConnection) []const u8 {
        return "";
    }

    pub fn getState(_: *const PresentationConnection) []const u8 {
        return "closed";
    }

    pub fn getBinaryType(self: *const PresentationConnection) []const u8 {
        return @tagName(self._binary_type);
    }

    pub fn setBinaryType(self: *PresentationConnection, value: []const u8) void {
        if (std.meta.stringToEnum(BinaryType, value)) |parsed| self._binary_type = parsed;
    }

    fn noop(_: *PresentationConnection) void {}

    fn noop1(_: *PresentationConnection, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationConnection);

        pub const Meta = struct {
            pub const name = "PresentationConnection";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const C = PresentationConnection;

        pub const id = bridge.accessor(C.empty, null, .{});
        pub const url = bridge.accessor(C.empty, null, .{});
        pub const state = bridge.accessor(C.getState, null, .{});
        pub const onconnect = bridge.accessor(handlerProperty(PresentationConnection, .onconnect).get, handlerProperty(PresentationConnection, .onconnect).set, .{});
        pub const onclose = bridge.accessor(handlerProperty(PresentationConnection, .onclose).get, handlerProperty(PresentationConnection, .onclose).set, .{});
        pub const onterminate = bridge.accessor(handlerProperty(PresentationConnection, .onterminate).get, handlerProperty(PresentationConnection, .onterminate).set, .{});
        pub const binaryType = bridge.accessor(C.getBinaryType, C.setBinaryType, .{});
        pub const onmessage = bridge.accessor(handlerProperty(PresentationConnection, .onmessage).get, handlerProperty(PresentationConnection, .onmessage).set, .{});
        pub const close = bridge.function(C.noop, .{});
        pub const send = bridge.function(C.noop1, .{ .arity = 1 });
        pub const terminate = bridge.function(C.noop, .{});
    };
};

/// What a receiving page's `connectionList` resolves with.
pub const PresentationConnectionList = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *PresentationConnectionList) *EventTarget {
        return self._proto;
    }

    pub fn getConnections(_: *const PresentationConnectionList) []const *PresentationConnection {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationConnectionList);

        pub const Meta = struct {
            pub const name = "PresentationConnectionList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        pub const connections = bridge.accessor(PresentationConnectionList.getConnections, null, .{});
        pub const onconnectionavailable = bridge.accessor(handlerProperty(PresentationConnectionList, .onconnectionavailable).get, handlerProperty(PresentationConnectionList, .onconnectionavailable).set, .{});
    };
};

/// `navigator.presentation.receiver`, which is null unless the page *is* the
/// presentation. Not an EventTarget, unlike the rest of the family.
pub const PresentationReceiver = struct {
    _pad: bool = false,

    pub fn getConnectionList(_: *const PresentationReceiver, exec: *const Execution) !js.Promise {
        const resolver = exec.js.local.?.createPromiseResolver();
        const promise = resolver.promise();
        promise.markAsHandled();
        return promise;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationReceiver);

        pub const Meta = struct {
            pub const name = "PresentationReceiver";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const connectionList = bridge.accessor(PresentationReceiver.getConnectionList, null, .{});
    };
};

/// Both events take two required arguments, and both refuse every value a script
/// could pass for the required member of their init dictionary — one because
/// there is no PresentationConnection to convert to, the other because `reason`
/// is an enum.
pub const PresentationConnectionAvailableEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*PresentationConnectionAvailableEvent {
        const got: usize = if (type_ == null) 0 else if (options_ == null) 1 else 2;
        if (got < 2) return throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'PresentationConnectionAvailableEvent': 2 arguments required, but only {d} present.",
            .{got},
        ), exec);

        const options = options_.?;
        if (!options.isObject()) return throwTypeError(
            "Failed to construct 'PresentationConnectionAvailableEvent': The provided value is not of type " ++
                "'PresentationConnectionAvailableEventInit'.",
            exec,
        );
        const object = try options.toZig(js.Object);
        const connection = try object.get("connection");
        if (connection.isUndefined()) return throwTypeError(
            "Failed to construct 'PresentationConnectionAvailableEvent': Failed to read the 'connection' " ++
                "property from 'PresentationConnectionAvailableEventInit': Required member is undefined.",
            exec,
        );
        // Nothing hands out a PresentationConnection, so every value lands here.
        return throwTypeError(
            "Failed to construct 'PresentationConnectionAvailableEvent': Failed to read the 'connection' " ++
                "property from 'PresentationConnectionAvailableEventInit': Failed to convert value to " ++
                "'PresentationConnection'.",
            exec,
        );
    }

    pub fn asEvent(self: *PresentationConnectionAvailableEvent) *Event {
        return self._proto;
    }

    pub fn getConnection(_: *const PresentationConnectionAvailableEvent) ?*PresentationConnection {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationConnectionAvailableEvent);

        pub const Meta = struct {
            pub const name = "PresentationConnectionAvailableEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(PresentationConnectionAvailableEvent.constructor, .{ .arity = 2 });
        pub const connection = bridge.accessor(PresentationConnectionAvailableEvent.getConnection, null, .{});
    };
};

pub const PresentationConnectionCloseEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _reason: Reason,
    _message: []const u8,

    // Measured: exactly these three, and `wentaway` has no hyphen.
    const Reason = enum { @"error", closed, wentaway };

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*PresentationConnectionCloseEvent {
        const got: usize = if (type_ == null) 0 else if (options_ == null) 1 else 2;
        if (got < 2) return throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'PresentationConnectionCloseEvent': 2 arguments required, but only {d} present.",
            .{got},
        ), exec);

        const options = options_.?;
        if (!options.isObject()) return throwTypeError(
            "Failed to construct 'PresentationConnectionCloseEvent': The provided value is not of type " ++
                "'PresentationConnectionCloseEventInit'.",
            exec,
        );
        const object = try options.toZig(js.Object);

        const reason_value = try object.get("reason");
        if (reason_value.isUndefined()) return throwTypeError(
            "Failed to construct 'PresentationConnectionCloseEvent': Failed to read the 'reason' property " ++
                "from 'PresentationConnectionCloseEventInit': Required member is undefined.",
            exec,
        );
        const reason_text = try reason_value.toStringSlice();
        const reason = std.meta.stringToEnum(Reason, reason_text) orelse return throwTypeError(
            try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to construct 'PresentationConnectionCloseEvent': Failed to read the 'reason' property " ++
                    "from 'PresentationConnectionCloseEventInit': The provided value '{s}' is not a valid enum " ++
                    "value of type PresentationConnectionCloseReason.",
                .{reason_text},
            ),
            exec,
        );

        const message_value = try object.get("message");
        const message = if (message_value.isUndefined())
            ""
        else
            try exec.arena.dupe(u8, try message_value.toStringSlice());

        const event_options = try Event.optionsFromJs(options);
        const typ = try type_.?.toStringSlice();
        const arena = try exec.getArena(.tiny, "PresentationConnectionCloseEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            PresentationConnectionCloseEvent{
                ._proto = undefined,
                ._reason = reason,
                ._message = message,
            },
        );
        Event.populatePrototypes(event, event_options, false);
        return event;
    }

    pub fn asEvent(self: *PresentationConnectionCloseEvent) *Event {
        return self._proto;
    }

    pub fn getReason(self: *const PresentationConnectionCloseEvent) []const u8 {
        return @tagName(self._reason);
    }

    pub fn getMessage(self: *const PresentationConnectionCloseEvent) []const u8 {
        return self._message;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PresentationConnectionCloseEvent);

        pub const Meta = struct {
            pub const name = "PresentationConnectionCloseEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        const E = PresentationConnectionCloseEvent;

        pub const constructor = bridge.constructor(E.constructor, .{ .arity = 2 });
        pub const reason = bridge.accessor(E.getReason, null, .{});
        pub const message = bridge.accessor(E.getMessage, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Presentation" {
    try testing.htmlRunner("presentation.html", .{});
}
