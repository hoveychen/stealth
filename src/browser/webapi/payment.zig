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

//! The Payment Request family: six interfaces, of which three are constructible
//! and therefore have behaviour a detector can reach without a payment app.
//!
//! `new PaymentRequest(methods, details)` validates a lot before it succeeds,
//! and every refusal below was read off a headed Chrome 150 over
//! http://localhost (win20-chrome.json for the shapes, win21 and win23 for the
//! behaviours). Notable measured details:
//!
//!   * `id` is a lowercase v4 UUID unless `details.id` supplies one.
//!   * The amount checks name where they failed: "'abc' is not a valid amount
//!     format for total" versus "... for display items".
//!   * A bad payment-method identifier is a **RangeError**, not a TypeError, and
//!     an invalid currency is one too. Only the amount format and the enum
//!     members are TypeErrors.
//!   * `show()` on a request that already showed is InvalidStateError "Already
//!     called show() once"; the first `show()` of a page load rejects
//!     NotSupportedError naming the payment method, with no user gesture needed.
//!     Chrome's *second* show() per page load rejects SecurityError about
//!     transient activation instead, which is not modelled here — that would
//!     need page-wide state, and a page that calls show() on two different
//!     requests still gets a rejection either way.
//!   * `PaymentRequestUpdateEvent.updateWith()` refuses a script-built event:
//!     "Cannot update details when the event is not trusted", thrown
//!     synchronously.

const std = @import("std");

const js = @import("../js/js.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const permissions_policy = @import("../permissions_policy.zig");
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
        PaymentRequest,
        PaymentResponse,
        PaymentAddress,
        PaymentManager,
        PaymentRequestUpdateEvent,
        PaymentMethodChangeEvent,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn throwRangeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createRangeError(message));
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
    resolver.reject("payment", DOMException.init(message, name));
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

/// `new PaymentRequest(methodData, details, options)`.
pub const PaymentRequest = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _id: []const u8,
    _method: []const u8,
    _shipping_type: ?ShippingType = null,
    _shown: bool = false,

    const ShippingType = enum { shipping, delivery, pickup };

    pub fn asEventTarget(self: *PaymentRequest) *EventTarget {
        return self._proto;
    }

    pub fn constructor(
        methods_: ?js.Value,
        details_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*PaymentRequest {
        const prefix = "Failed to construct 'PaymentRequest': ";
        const methods = methods_ orelse return throwTypeError(
            prefix ++ "1 argument required, but only 0 present.",
            exec,
        );
        // Chrome words a missing second argument as a missing dictionary member
        // rather than as an argument count (measured).
        const details_value = details_ orelse return throwTypeError(prefix ++ "required member details is undefined.", exec);
        // Past the argument checks, a frame the payment feature did not reach is
        // refused before anything is validated (measured, Chrome 153).
        if (!permissions_policy.execAllows(exec, "payment")) {
            return throwDom("SecurityError", prefix ++ "Must be in a top-level browsing context or an iframe needs to specify allow=\"payment\" explicitly", exec);
        }

        if (!methods.isArray()) return throwTypeError(prefix ++ "The provided value cannot be converted to a sequence.", exec);
        const list = try methods.toZig([]const js.Value);
        if (list.len == 0) return throwTypeError(prefix ++ "At least one payment method is required", exec);

        var first_method: []const u8 = "";
        for (list, 0..) |entry, i| {
            if (!entry.isObject()) return throwTypeError(prefix ++ "The provided value is not of type 'PaymentMethodData'.", exec);
            const entry_object = try entry.toZig(js.Object);
            const supported = try entry_object.get("supportedMethods");
            const text = if (supported.isUndefined()) "" else try supported.toStringSlice();
            if (!validMethod(text)) return throwRangeError(prefix ++ "Invalid payment method identifier format", exec);
            if (i == 0) first_method = try exec.arena.dupe(u8, text);
        }

        if (!details_value.isObject()) return throwTypeError(prefix ++ "The provided value is not of type 'PaymentDetailsInit'.", exec);
        const details = try details_value.toZig(js.Object);

        const total = try details.get("total");
        if (total.isUndefined()) return throwTypeError(prefix ++ "required member details is undefined.", exec);
        try checkAmount(total, "total", exec);

        const display_items = try details.get("displayItems");
        if (!display_items.isUndefined() and display_items.isArray()) {
            for (try display_items.toZig([]const js.Value)) |item| {
                try checkAmount(item, "display items", exec);
            }
        }

        var shipping_type: ?ShippingType = null;
        if (options_) |options_value| {
            if (options_value.isObject()) {
                const options = try options_value.toZig(js.Object);
                const given = try options.get("shippingType");
                if (!given.isUndefined() and !given.isNull()) {
                    const text = try given.toStringSlice();
                    shipping_type = std.meta.stringToEnum(ShippingType, text) orelse return throwTypeError(
                        try std.fmt.allocPrint(
                            exec.call_arena,
                            prefix ++ "Failed to read the 'shippingType' property from 'PaymentOptions': " ++
                                "The provided value '{s}' is not a valid enum value of type PaymentShippingType.",
                            .{text},
                        ),
                        exec,
                    );
                }
            }
        }

        const given_id = try details.get("id");
        const id = if (given_id.isUndefined() or given_id.isNull())
            try uuid(exec)
        else
            try exec.arena.dupe(u8, try given_id.toStringSlice());

        return exec._factory.eventTarget(PaymentRequest{
            ._proto = undefined,
            ._id = id,
            ._method = first_method,
            ._shipping_type = shipping_type,
        });
    }

    // A standardized identifier ("basic-card") or an absolute URL. Measured:
    // "basic-card" and "https://pay.example" are accepted, "" and 5 are not.
    fn validMethod(text: []const u8) bool {
        if (text.len == 0) return false;
        if (std.mem.startsWith(u8, text, "https://") or std.mem.startsWith(u8, text, "http://")) return true;
        if (!std.ascii.isLower(text[0])) return false;
        for (text[1..]) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
        }
        return true;
    }

    // `{label, amount: {currency, value}}`. Chrome checks the currency (a
    // RangeError) before the value format (a TypeError), and refuses a negative
    // total separately (all measured).
    fn checkAmount(item: js.Value, comptime where: []const u8, exec: *const Execution) !void {
        const prefix = "Failed to construct 'PaymentRequest': ";
        if (!item.isObject()) return;
        const item_object = try item.toZig(js.Object);
        const amount_value = try item_object.get("amount");
        if (!amount_value.isObject()) return;
        const amount = try amount_value.toZig(js.Object);

        const currency_value = try amount.get("currency");
        const currency = if (currency_value.isUndefined()) "" else try currency_value.toStringSlice();
        if (!validCurrency(currency)) return throwRangeError(try std.fmt.allocPrint(
            exec.call_arena,
            prefix ++ "'{s}' is not a valid ISO 4217 currency code, should be well-formed 3-letter alphabetic code.",
            .{currency},
        ), exec);

        const value_value = try amount.get("value");
        const text = if (value_value.isUndefined()) "" else try value_value.toStringSlice();
        if (!validAmount(text)) return throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            prefix ++ "'{s}' is not a valid amount format for " ++ where,
            .{text},
        ), exec);

        if (comptime std.mem.eql(u8, where, "total")) {
            if (text.len > 0 and text[0] == '-') return throwTypeError(
                prefix ++ "Total amount value should be non-negative",
                exec,
            );
        }
    }

    fn validCurrency(text: []const u8) bool {
        if (text.len != 3) return false;
        for (text) |c| {
            if (!std.ascii.isAlphabetic(c)) return false;
        }
        return true;
    }

    fn validAmount(text: []const u8) bool {
        if (text.len == 0) return false;
        var rest = text;
        if (rest[0] == '-' or rest[0] == '+') rest = rest[1..];
        if (rest.len == 0) return false;
        var seen_dot = false;
        var digits_before: usize = 0;
        var digits_after: usize = 0;
        for (rest) |c| {
            if (c == '.') {
                if (seen_dot) return false;
                seen_dot = true;
            } else if (std.ascii.isDigit(c)) {
                if (seen_dot) digits_after += 1 else digits_before += 1;
            } else return false;
        }
        if (digits_before == 0) return false;
        if (seen_dot and digits_after == 0) return false;
        return true;
    }

    // Chrome's ids are lowercase v4 UUIDs and differ per request (measured two
    // in a row); the engine already has the generator crypto.randomUUID uses.
    fn uuid(exec: *const Execution) ![]const u8 {
        const out = try exec.arena.alloc(u8, 36);
        @import("../../id.zig").uuidv4(out[0..36]);
        return out;
    }

    pub fn getId(self: *const PaymentRequest) []const u8 {
        return self._id;
    }

    // All three stay null: no payment sheet ever opens, so nothing is picked.
    pub fn getShippingAddress(_: *const PaymentRequest) ?*PaymentAddress {
        return null;
    }

    pub fn getShippingOption(_: *const PaymentRequest) ?[]const u8 {
        return null;
    }

    pub fn getShippingType(self: *const PaymentRequest) ?[]const u8 {
        const shipping_type = self._shipping_type orelse return null;
        return @tagName(shipping_type);
    }

    pub fn abort(_: *PaymentRequest, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute 'abort' on 'PaymentRequest': No show() or retry() in progress, so nothing to abort",
            exec,
        );
    }

    pub fn canMakePayment(_: *PaymentRequest, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(false);
    }

    pub fn hasEnrolledInstrument(_: *PaymentRequest, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(false);
    }

    pub fn show(self: *PaymentRequest, _: ?js.Value, exec: *const Execution) js.Promise {
        if (self._shown) return rejectDom(
            "InvalidStateError",
            "Failed to execute 'show' on 'PaymentRequest': Already called show() once",
            exec,
        );
        self._shown = true;
        const message = std.fmt.allocPrint(
            exec.arena,
            "The payment method \"{s}\" is not supported.",
            .{self._method},
        ) catch "The payment method is not supported.";
        return rejectDom("NotSupportedError", message, exec);
    }

    // Chrome answers "available" here and reports hardware-backed browser-bound
    // keys, on this Mac (both measured).
    pub fn securePaymentConfirmationAvailability(exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as([]const u8, "available"));
    }

    const Capabilities = struct {
        browserBoundKeyHardware: bool = true,
    };

    pub fn getSecurePaymentConfirmationCapabilities(exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(Capabilities{});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaymentRequest);

        pub const Meta = struct {
            pub const name = "PaymentRequest";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const R = PaymentRequest;

        pub const constructor = bridge.constructor(R.constructor, .{ .arity = 1 });
        pub const id = bridge.accessor(R.getId, null, .{});
        pub const shippingAddress = bridge.accessor(R.getShippingAddress, null, .{});
        pub const shippingOption = bridge.accessor(R.getShippingOption, null, .{});
        pub const shippingType = bridge.accessor(R.getShippingType, null, .{});
        pub const onshippingaddresschange = bridge.accessor(handlerProperty(PaymentRequest, .onshippingaddresschange).get, handlerProperty(PaymentRequest, .onshippingaddresschange).set, .{});
        pub const onshippingoptionchange = bridge.accessor(handlerProperty(PaymentRequest, .onshippingoptionchange).get, handlerProperty(PaymentRequest, .onshippingoptionchange).set, .{});
        pub const abort = bridge.function(R.abort, .{});
        pub const canMakePayment = bridge.function(R.canMakePayment, .{});
        pub const hasEnrolledInstrument = bridge.function(R.hasEnrolledInstrument, .{});
        pub const show = bridge.function(R.show, .{ .arity = 0 });
        pub const onpaymentmethodchange = bridge.accessor(handlerProperty(PaymentRequest, .onpaymentmethodchange).get, handlerProperty(PaymentRequest, .onpaymentmethodchange).set, .{});

        pub const getSecurePaymentConfirmationCapabilities = bridge.function(R.getSecurePaymentConfirmationCapabilities, .{ .static = true });
        pub const securePaymentConfirmationAvailability = bridge.function(R.securePaymentConfirmationAvailability, .{ .static = true });
    };
};

/// What a completed payment resolves with. Unreachable: no sheet ever opens.
pub const PaymentResponse = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *PaymentResponse) *EventTarget {
        return self._proto;
    }

    fn empty(_: *const PaymentResponse) []const u8 {
        return "";
    }

    fn none(_: *const PaymentResponse) ?[]const u8 {
        return null;
    }

    fn details(_: *const PaymentResponse) struct {} {
        return .{};
    }

    fn shippingAddressOf(_: *const PaymentResponse) ?*PaymentAddress {
        return null;
    }

    fn refuse(_: *PaymentResponse, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute 'complete' on 'PaymentResponse': Attempted to call complete() again",
            exec,
        );
    }

    fn refuse1(_: *PaymentResponse, _: ?js.Value, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute 'retry' on 'PaymentResponse': Attempted to call retry() again",
            exec,
        );
    }

    fn toJSON(_: *const PaymentResponse) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaymentResponse);

        pub const Meta = struct {
            pub const name = "PaymentResponse";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const R = PaymentResponse;

        pub const requestId = bridge.accessor(R.empty, null, .{});
        pub const methodName = bridge.accessor(R.empty, null, .{});
        pub const details = bridge.accessor(R.details, null, .{});
        pub const shippingAddress = bridge.accessor(R.shippingAddressOf, null, .{});
        pub const shippingOption = bridge.accessor(R.none, null, .{});
        pub const payerName = bridge.accessor(R.none, null, .{});
        pub const payerEmail = bridge.accessor(R.none, null, .{});
        pub const payerPhone = bridge.accessor(R.none, null, .{});
        pub const onpayerdetailchange = bridge.accessor(handlerProperty(PaymentResponse, .onpayerdetailchange).get, handlerProperty(PaymentResponse, .onpayerdetailchange).set, .{});
        pub const complete = bridge.function(R.refuse, .{ .arity = 0 });
        pub const retry = bridge.function(R.refuse1, .{ .arity = 0 });
        pub const toJSON = bridge.function(R.toJSON, .{});
    };
};

/// The address a payment sheet would collect. Unreachable here.
pub const PaymentAddress = struct {
    _pad: bool = false,

    fn empty(_: *const PaymentAddress) []const u8 {
        return "";
    }

    fn addressLines(_: *const PaymentAddress) []const []const u8 {
        return &.{};
    }

    fn toJSON(_: *const PaymentAddress) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaymentAddress);

        pub const Meta = struct {
            pub const name = "PaymentAddress";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const A = PaymentAddress;

        pub const city = bridge.accessor(A.empty, null, .{});
        pub const country = bridge.accessor(A.empty, null, .{});
        pub const dependentLocality = bridge.accessor(A.empty, null, .{});
        pub const organization = bridge.accessor(A.empty, null, .{});
        pub const phone = bridge.accessor(A.empty, null, .{});
        pub const postalCode = bridge.accessor(A.empty, null, .{});
        pub const recipient = bridge.accessor(A.empty, null, .{});
        pub const region = bridge.accessor(A.empty, null, .{});
        pub const sortingCode = bridge.accessor(A.empty, null, .{});
        pub const addressLine = bridge.accessor(A.addressLines, null, .{});
        pub const toJSON = bridge.function(A.toJSON, .{});
    };
};

/// `ServiceWorkerRegistration.paymentManager`, which no page can reach here
/// because no registration is ever handed out.
pub const PaymentManager = struct {
    _user_hint: []const u8 = "",

    pub fn getUserHint(self: *const PaymentManager) []const u8 {
        return self._user_hint;
    }

    pub fn setUserHint(self: *PaymentManager, value: []const u8, exec: *const Execution) !void {
        self._user_hint = try exec.arena.dupe(u8, value);
    }

    pub fn enableDelegations(_: *PaymentManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute 'enableDelegations' on 'PaymentManager': " ++
                "The payment handler is not installed.",
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaymentManager);

        pub const Meta = struct {
            pub const name = "PaymentManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const userHint = bridge.accessor(PaymentManager.getUserHint, PaymentManager.setUserHint, .{});
        pub const enableDelegations = bridge.function(PaymentManager.enableDelegations, .{ .arity = 1 });
    };
};

/// The base of the shipping-change events. Constructible, and its one method
/// refuses a script-built (untrusted) event.
pub const PaymentRequestUpdateEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _type: Type = .generic,

    pub const Type = union(enum) {
        generic,
        method_change: *PaymentMethodChangeEvent,
    };

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*PaymentRequestUpdateEvent {
        const type_value = type_ orelse return throwTypeError(
            "Failed to construct 'PaymentRequestUpdateEvent': 1 argument required, but only 0 present.",
            exec,
        );
        const typ = try type_value.toStringSlice();
        const event_options: Event.Options = if (options_) |options| try Event.optionsFromJs(options) else .{};
        const arena = try exec.getArena(.tiny, "PaymentRequestUpdateEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            PaymentRequestUpdateEvent{ ._proto = undefined },
        );
        Event.populatePrototypes(event, event_options, false);
        return event;
    }

    pub fn asEvent(self: *PaymentRequestUpdateEvent) *Event {
        return self._proto;
    }

    pub fn updateWith(_: *PaymentRequestUpdateEvent, details_: ?js.Value, exec: *const Execution) !void {
        if (details_ == null) return throwTypeError(
            "Failed to execute 'updateWith' on 'PaymentRequestUpdateEvent': 1 argument required, but only 0 present.",
            exec,
        );
        return throwDom(
            "InvalidStateError",
            "Failed to execute 'updateWith' on 'PaymentRequestUpdateEvent': " ++
                "Cannot update details when the event is not trusted",
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaymentRequestUpdateEvent);

        pub const Meta = struct {
            pub const name = "PaymentRequestUpdateEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(PaymentRequestUpdateEvent.constructor, .{ .arity = 1 });
        pub const updateWith = bridge.function(PaymentRequestUpdateEvent.updateWith, .{ .arity = 1 });
    };
};

/// A three-deep event chain: Event -> PaymentRequestUpdateEvent -> here.
pub const PaymentMethodChangeEvent = struct {
    pub const Proto = PaymentRequestUpdateEvent;

    _proto: *PaymentRequestUpdateEvent,
    _method_name: []const u8,
    _method_details: ?js.Value.Global,

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*PaymentMethodChangeEvent {
        const type_value = type_ orelse return throwTypeError(
            "Failed to construct 'PaymentMethodChangeEvent': 1 argument required, but only 0 present.",
            exec,
        );
        const typ = try type_value.toStringSlice();

        var method_name: []const u8 = "";
        var method_details: ?js.Value.Global = null;
        if (options_) |options| {
            if (options.isObject()) {
                const object = try options.toZig(js.Object);
                const name_value = try object.get("methodName");
                if (!name_value.isUndefined()) {
                    method_name = try exec.arena.dupe(u8, try name_value.toStringSlice());
                }
                const details_value = try object.get("methodDetails");
                if (!details_value.isUndefined() and !details_value.isNull()) {
                    // Measured: a non-object is refused by the member's own name.
                    if (!details_value.isObject()) return throwTypeError(
                        "Failed to construct 'PaymentMethodChangeEvent': Failed to read the 'methodDetails' " ++
                            "property from 'PaymentMethodChangeEventInit': Failed to convert value to 'object'.",
                        exec,
                    );
                    method_details = try details_value.persist();
                }
            }
        }

        const event_options: Event.Options = if (options_) |options| try Event.optionsFromJs(options) else .{};
        const arena = try exec.getArena(.tiny, "PaymentMethodChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.paymentMethodChangeEvent(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            PaymentRequestUpdateEvent{ ._proto = undefined, ._type = .generic },
            PaymentMethodChangeEvent{
                ._proto = undefined,
                ._method_name = method_name,
                ._method_details = method_details,
            },
        );
        Event.populatePrototypes(event._proto, event_options, false);
        return event;
    }

    pub fn getMethodName(self: *const PaymentMethodChangeEvent) []const u8 {
        return self._method_name;
    }

    // Measured: null when the member was absent, and the object itself when it
    // was given.
    pub fn getMethodDetails(self: *const PaymentMethodChangeEvent) ?js.Value.Global {
        return self._method_details;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaymentMethodChangeEvent);

        pub const Meta = struct {
            pub const name = "PaymentMethodChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = PaymentRequestUpdateEvent;

        pub const constructor = bridge.constructor(PaymentMethodChangeEvent.constructor, .{ .arity = 1 });
        pub const methodName = bridge.accessor(PaymentMethodChangeEvent.getMethodName, null, .{});
        pub const methodDetails = bridge.accessor(
            PaymentMethodChangeEvent.getMethodDetails,
            null,
            .{ .null_as_undefined = false },
        );
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Payment" {
    try testing.htmlRunner("payment.html", .{});
}
