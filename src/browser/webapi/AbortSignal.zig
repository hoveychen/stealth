// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const ModelContextTool = @import("ModelContext.zig").Tool;

const log = lp.log;
const Execution = js.Execution;

const AbortSignal = @This();

pub const Proto = EventTarget;

// What an abort with no reason of its own reports. This is Chrome's wording,
// measured; the generic "The operation was aborted" an AbortError carries by
// default is not what a script sees.
const NO_REASON = "signal is aborted without reason";

// Likewise for AbortSignal.timeout(), whose reason is not the generic
// "The operation timed out" either.
const TIMED_OUT = "signal timed out";

const Dependend = union(enum) {
    signal: *AbortSignal,
    model_context_tool: *ModelContextTool,

    // Returns false if the dependent was already aborted, in which case no
    // abort event must be dispatched for it.
    fn markAborted(self: Dependend, reason_: ?Reason, exec: *const Execution) !bool {
        switch (self) {
            .signal => |dep| {
                if (dep._aborted) return false;
                try dep.markAborted(reason_, exec);
                return true;
            },
            .model_context_tool => |dep| {
                try dep.markAborted(exec);
                return true;
            },
        }
    }

    fn dispatchAbortEvent(self: Dependend, exec: *const Execution) !void {
        switch (self) {
            .signal => |dep| try dep.dispatchAbortEvent(exec),
            .model_context_tool => {},
        }
    }
};

// A TaskSignal is an AbortSignal, and a script can reach one through
// AbortSignal-typed surfaces (a prioritychange event's target, TaskSignal.any).
// This is what lets those come back as the TaskSignal they are.

_proto: *EventTarget,
_type: Type = .generic,
_aborted: bool = false,
_is_dependent: bool = false,
_reason: Reason = .undefined,
_dependents: std.ArrayList(Dependend) = .empty,
_source_signals: std.ArrayList(*AbortSignal) = .empty,

pub const Type = union(enum) {
    generic: void,
    task_signal: *@import("Scheduler.zig").TaskSignal,
};

pub fn init(exec: *const Execution) !*AbortSignal {
    return exec._factory.eventTarget(AbortSignal{
        ._proto = undefined,
        ._type = .generic,
    });
}

pub fn getAborted(self: *const AbortSignal) bool {
    return self._aborted;
}

pub fn getReason(self: *const AbortSignal) Reason {
    return self._reason;
}

pub fn asEventTarget(self: *AbortSignal) *EventTarget {
    return self._proto;
}

pub fn abort(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    if (self._aborted) {
        return;
    }

    try self.markAborted(reason_, exec);

    // Per spec: mark all direct dependents aborted (with this signal's reason)
    // BEFORE firing any abort events. The graph is flattened at any() creation,
    // so we never need to recurse here.
    var to_dispatch: std.ArrayList(Dependend) = .empty;
    for (self._dependents.items) |dep| {
        if (try dep.markAborted(self._reason, exec)) {
            try to_dispatch.append(exec.call_arena, dep);
        }
    }

    try self.dispatchAbortEvent(exec);
    for (to_dispatch.items) |dep| {
        dep.dispatchAbortEvent(exec) catch |err| {
            log.warn(.app, "abort dependent dispatch", .{ .err = err });
        };
    }
}

fn markAborted(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    self._aborted = true;
    if (reason_) |reason| {
        switch (reason) {
            .dom => |dom| self._reason = .{ .dom = dom },
            .js_val => |js_val| self._reason = .{ .js_val = js_val },
            .string => |str| self._reason = .{ .string = try exec.dupeString(str) },
            .undefined => self._reason = reason,
        }
    } else {
        // Allocate the DOMException so the reason keeps a single JS identity:
        // dependent signals must expose the very same DOMException instance.
        const dom = try exec.arena.create(DOMException);
        dom.* = DOMException.init(NO_REASON, "AbortError");
        self._reason = .{ .dom = dom };
    }

    // Unlike the loop in abort(), this runs for dependent signals too, so a
    // task registered on an any() signal still gets rejected.
    for (self._dependents.items) |dep| {
        switch (dep) {
            else => {},
        }
    }
}

fn dispatchAbortEvent(self: *AbortSignal, exec: *const Execution) !void {
    const target = self.asEventTarget();
    // Upstream keeps `onabort` in an `_on_abort` field and hands it to the
    // dispatch as the handler. We keep it in the event manager's handler store
    // instead, so the listener standing for it is already in the target's list
    // in dispatch order -- hence `null` here rather than a handler.
    if (exec.hasDirectListeners(target, "abort", null)) {
        const event = try Event.initTrusted(comptime .wrap("abort"), .{}, exec.page);
        try exec.dispatch(target, event, null, .{ .context = "abort signal" });
    }
}

// Converts an abort(reason) JS argument to a Reason. Per spec, only a
// missing or undefined reason falls back to the default "AbortError"
// DOMException: an explicit null (or any other value) is kept as-is.
pub fn reasonFromJs(reason_: ?js.Value) !?Reason {
    const reason = reason_ orelse return null;
    if (reason.isUndefined()) {
        return null;
    }
    return .{ .js_val = try reason.persist() };
}

// Static method to create an already-aborted signal
pub fn createAborted(reason_: ?js.Value, exec: *const Execution) !*AbortSignal {
    const signal = try init(exec);
    try signal.abort(try reasonFromJs(reason_), exec);
    return signal;
}

pub fn createAny(signals_value: js.Value, exec: *const Execution) !*AbortSignal {
    // The parameter isn't optional. If we declared it as a slice directy, the
    // bridge would treat it as a variadic and map it to empty rather than throwing
    // a TypeError as it should.
    const signals = try signals_value.toZig([]const *AbortSignal);

    const result = try init(exec);
    try linkAny(result, signals, exec);
    return result;
}

// The dependency half of any(), split out so TaskSignal.any can reuse it on a
// signal it has already built as the right subtype.
pub fn linkAny(result: *AbortSignal, signals: []const *AbortSignal, exec: *const Execution) !void {
    for (signals) |source| {
        if (source._aborted) {
            return result.abort(source._reason, exec);
        }
    }

    result._is_dependent = true;

    for (signals) |source| {
        if (!source._is_dependent) {
            try source._dependents.append(exec.arena, .{ .signal = result });
            try result._source_signals.append(exec.arena, source);
        } else {
            for (source._source_signals.items) |s| {
                try s._dependents.append(exec.arena, .{ .signal = result });
                try result._source_signals.append(exec.arena, s);
            }
        }
    }
}

pub fn createTimeout(delay: u32, exec: *const Execution) !*AbortSignal {
    const callback = try exec.arena.create(TimeoutCallback);
    callback.* = .{
        .exec = exec,
        .signal = try init(exec),
    };

    try exec._scheduler.add(callback, TimeoutCallback.run, delay, .{
        .name = "AbortSignal.timeout",
    });

    return callback.signal;
}

const ThrowIfAborted = union(enum) {
    exception: js.Exception,
    undefined: void,
};
pub fn throwIfAborted(self: *const AbortSignal, exec: *const Execution) !ThrowIfAborted {
    const local = exec.js.local.?;

    if (self._aborted) {
        const exception = switch (self._reason) {
            .dom => |err| local.newException(err),
            .string => |str| local.newException(str),
            .js_val => |js_val| local.newException(js_val),
            .undefined => local.newException(DOMException.init(NO_REASON, "AbortError")),
        };
        return .{ .exception = exception };
    }
    return .undefined;
}

pub const Reason = union(enum) {
    js_val: js.Value.Global,
    dom: *DOMException,
    string: []const u8,
    undefined: void,
};

// The reason as a JS value, e.g. to reject a promise with it.
pub fn reasonJsValue(reason: Reason, local: *const js.Local) !js.Value {
    return switch (reason) {
        .dom => |dom| local.zigValueToJs(dom, .{}),
        .string => |str| local.zigValueToJs(str, .{}),
        .js_val => |global| local.toLocal(global),
        .undefined => local.zigValueToJs(DOMException.fromError(error.AbortError).?, .{}),
    };
}

const TimeoutCallback = struct {
    exec: *const Execution,
    signal: *AbortSignal,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *TimeoutCallback = @ptrCast(@alignCast(ctx));
        self.timeoutAbort() catch |err| {
            log.warn(.app, "abort signal timeout", .{ .err = err });
        };
        return null;
    }

    fn timeoutAbort(self: *TimeoutCallback) !void {
        // Per spec, the abort is queued as a global task on the signal's
        // global: it must not run when the global's document is no longer
        // fully active (e.g. the iframe that created the signal was detached).
        switch (self.exec.js.global) {
            .frame => |frame| {
                var current: ?@TypeOf(frame) = frame;
                while (current) |f| : (current = f.parent) {
                    const iframe = f.iframe orelse continue;
                    if (!iframe.asNode().isConnected()) {
                        return;
                    }
                }
            },
            .worker => {},
        }

        const dom = try self.exec.arena.create(DOMException);
        dom.* = DOMException.init(TIMED_OUT, "TimeoutError");
        try self.signal.abort(.{ .dom = dom }, self.exec);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbortSignal);

    pub const Meta = struct {
        pub const name = "AbortSignal";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = EventTarget;

    pub const aborted = bridge.accessor(AbortSignal.getAborted, null, .{});
    pub const reason = bridge.accessor(AbortSignal.getReason, null, .{});
    pub const onabort = bridge.accessor(
        @import("handler_property.zig").accessors(AbortSignal, .onabort).get,
        @import("handler_property.zig").accessors(AbortSignal, .onabort).set,
        .{},
    );
    pub const throwIfAborted = bridge.function(AbortSignal.throwIfAborted, .{});

    // Static method
    pub const abort = bridge.function(AbortSignal.createAborted, .{ .static = true });
    pub const any = bridge.function(AbortSignal.createAny, .{ .static = true });
    pub const timeout = bridge.function(AbortSignal.createTimeout, .{ .static = true });
};
