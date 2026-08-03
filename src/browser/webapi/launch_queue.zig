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

//! window.launchQueue and the two interfaces behind it.
//!
//! The queue only ever delivers anything to an installed PWA started through a
//! file or protocol handler. An ordinary navigation -- Chrome's included, as
//! measured -- leaves it empty, the consumer is never called, and no
//! LaunchParams is ever created. So the queue here is a real object that
//! remembers its consumer and never has a reason to run it.

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

pub fn registerTypes() []const type {
    return &.{
        LaunchQueue,
        LaunchParams,
    };
}

pub const LaunchQueue = struct {
    _consumer: ?js.Function.Global = null,

    pub const init: LaunchQueue = .{};

    pub fn setConsumer(self: *LaunchQueue, consumer_: ?js.Value, frame: *Frame) !void {
        // WebIDL's two argument errors, both measured. They are raised here
        // rather than left to the bridge so the wording matches Chrome's.
        const value = consumer_ orelse return throwTypeError(
            "Failed to execute 'setConsumer' on 'LaunchQueue': 1 argument required, but only 0 present.",
            frame,
        );
        if (!value.isFunction()) {
            return throwTypeError(
                "Failed to execute 'setConsumer' on 'LaunchQueue': parameter 1 is not of type 'Function'.",
                frame,
            );
        }
        self._consumer = try (try value.toZig(js.Function)).persist();
    }

    fn throwTypeError(message: []const u8, frame: *Frame) anyerror {
        const isolate = frame.js.isolate;
        _ = isolate.throwException(isolate.createTypeError(message));
        return error.JsException;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LaunchQueue);

        pub const Meta = struct {
            pub const name = "LaunchQueue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const setConsumer = bridge.function(LaunchQueue.setConsumer, .{ .arity = 1 });
    };
};

/// Never instantiated: see the note at the top of the file.
pub const LaunchParams = struct {
    _target_url: ?[]const u8 = null,

    pub fn getTargetURL(self: *const LaunchParams) ?[]const u8 {
        return self._target_url;
    }

    pub fn getFiles(_: *const LaunchParams) []const []const u8 {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LaunchParams);

        pub const Meta = struct {
            pub const name = "LaunchParams";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const targetURL = bridge.accessor(LaunchParams.getTargetURL, null, .{});
        pub const files = bridge.accessor(LaunchParams.getFiles, null, .{});
    };
};
