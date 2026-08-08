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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// User-idle detection. Constructible everywhere -- including in a worker, which
// is one of the nine interfaces Chrome's worker scope carries -- and gated on a
// permission no headless run has. Measured on a headed Chrome 150 with the
// permission unset (probe-win28/29/36):
//
//   * userState and screenState are null before a successful start().
//   * `start()` rejects with NotAllowedError "Idle detection permission denied"
//     -- note the message has no "Failed to execute" prefix, unlike almost every
//     other one of these.
//   * A second start() on the same detector rejects with InvalidStateError
//     "Failed to execute 'start' on 'IdleDetector': Idle detector is already
//     started." So the failed first start still marks it started.
//   * The static `requestPermission()` rejects with NotAllowedError "Must be
//     handling a user gesture to show a permission request."

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

const IdleDetector = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_change: ?js.Function.Global = null,
/// Set by the first start(), even though that start fails: a second one reports
/// "already started" rather than the permission error again.
_started: bool = false,

pub fn constructor(page: *Page) !*IdleDetector {
    const self = try page.factory.eventTarget(IdleDetector{ ._proto = undefined });
    self._proto._type = .{ .idle_detector = self };
    return self;
}

pub fn asEventTarget(self: *IdleDetector) *EventTarget {
    return self._proto;
}

/// Null until a start() succeeds, which needs a permission nothing here grants.
pub fn getUserState(_: *const IdleDetector) ?[]const u8 {
    return null;
}

pub fn getScreenState(_: *const IdleDetector) ?[]const u8 {
    return null;
}

pub fn start(self: *IdleDetector, _: ?js.Value, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    if (self._started) {
        resolver.reject("IdleDetector.start", DOMException.init(
            "Failed to execute 'start' on 'IdleDetector': Idle detector is already started.",
            "InvalidStateError",
        ));
        return resolver.promise();
    }
    self._started = true;
    resolver.reject("IdleDetector.start", DOMException.init(
        "Idle detection permission denied",
        "NotAllowedError",
    ));
    return resolver.promise();
}

pub fn requestPermission(exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("IdleDetector.requestPermission", DOMException.init(
        "Failed to execute 'requestPermission' on 'IdleDetector': Must be handling a user gesture to show a permission request.",
        "NotAllowedError",
    ));
    return resolver.promise();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IdleDetector);

    pub const Meta = struct {
        pub const name = "IdleDetector";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn getOnChange(self: *IdleDetector) ?js.Function.Global {
        return self._on_change;
    }

    fn setOnChange(self: *IdleDetector, listener: ?js.Function) !void {
        self._on_change = if (listener) |l| try l.persistWithThis(self) else null;
    }

    pub const constructor = bridge.constructor(IdleDetector.constructor, .{});
    pub const requestPermission = bridge.function(IdleDetector.requestPermission, .{ .static = true });
    pub const userState = bridge.accessor(IdleDetector.getUserState, null, .{});
    pub const screenState = bridge.accessor(IdleDetector.getScreenState, null, .{});
    pub const onchange = bridge.accessor(getOnChange, setOnChange, .{});
    pub const start = bridge.function(IdleDetector.start, .{ .arity = 0 });
};

const testing = @import("../../testing.zig");
test "WebApi: IdleDetector" {
    try testing.htmlRunner("idle_detector.html", .{});
}
