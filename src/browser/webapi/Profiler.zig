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

// The JS self-profiling API. On a page served without a `Document-Policy:
// js-profiling` header -- which is every page here, and the default everywhere --
// Chrome validates the dictionary and then refuses:
//
//   new Profiler({sampleInterval: 10, maxBufferSize: 100})
//     -> NotAllowedError: Failed to construct 'Profiler': JS profiling is
//        disabled by Document Policy.
//
// So no instance is ever built, and the prototype's three members exist to be
// enumerated. The two dictionary members are both required, and the order they
// are read in is Chrome's: `{maxBufferSize: 10}` complains about sampleInterval,
// `{}` complains about maxBufferSize. Measured on a headed Chrome 150
// (probe-win28/29/36).

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

const Profiler = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

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

pub fn constructor(options: js.Value, exec: *const Execution) !*Profiler {
    if (!options.isObject()) {
        return throwTypeError(
            "Failed to construct 'Profiler': The provided value is not of type 'ProfilerInitOptions'.",
            exec,
        );
    }

    const object = options.toObject();
    // Read in Chrome's order: maxBufferSize is only reported once
    // sampleInterval is there.
    inline for (.{ "sampleInterval", "maxBufferSize" }) |member| {
        if ((try object.get(member)).isUndefined()) {
            return throwTypeError(
                "Failed to construct 'Profiler': Failed to read the '" ++ member ++
                    "' property from 'ProfilerInitOptions': Required member is undefined.",
                exec,
            );
        }
    }

    return throwDom(
        "NotAllowedError",
        "Failed to construct 'Profiler': JS profiling is disabled by Document Policy.",
        exec,
    );
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Profiler);

    pub const Meta = struct {
        pub const name = "Profiler";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // No instance can exist, so these three are the shape alone.
    fn unreachableSampleInterval(_: *Profiler) f64 {
        return 0;
    }

    fn unreachableStopped(_: *Profiler) bool {
        return false;
    }

    fn unreachableStop(_: *Profiler) void {}

    pub const constructor = bridge.constructor(Profiler.constructor, .{});
    pub const sampleInterval = bridge.accessor(unreachableSampleInterval, null, .{});
    pub const stopped = bridge.accessor(unreachableStopped, null, .{});
    pub const stop = bridge.function(unreachableStop, .{ .noop = true });
};

const testing = @import("../../testing.zig");
test "WebApi: Profiler" {
    try testing.htmlRunner("profiler.html", .{});
}
