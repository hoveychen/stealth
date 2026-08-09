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

// How WebGPU says something went wrong. Three different hierarchies, which is
// the whole reason this file is worth writing down (all measured on a headed
// Chrome 150, probe-win38.js and probe-win41.js):
//
//   GPUValidationError / GPUOutOfMemoryError / GPUInternalError
//       -> GPUError -> Object.  Not Error instances: String(e) is
//       "[object GPUValidationError]", e.stack is undefined, and `message`
//       lives on GPUError.prototype rather than on the instance.
//   GPUPipelineError -> DOMException -> Error -> Object, with name
//       "GPUPipelineError" and code 0. Its *second* argument is the required
//       one even though the arity is 1.
//   GPUUncapturedErrorEvent -> Event, arity 2, and `cancelable` is true --
//       which is unusual enough that it was worth checking, and it stays true
//       even when the init says `cancelable: false`.
//
// All six are constructible from script, so a detector can build one and read
// it back; that is what this file is for. What it does *not* do is produce one:
// nothing here validates a buffer size or compiles WGSL, so a scope always pops
// null. See device.zig's pushErrorScope for the shape of that gap.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const resources = @import("resources.zig");
const DOMException = @import("../DOMException.zig");
const Event = @import("../Event.zig");
const String = @import("lightpanda").String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        GPUError,
        GPUInternalError,
        GPUOutOfMemoryError,
        GPUPipelineError,
        GPUUncapturedErrorEvent,
        GPUValidationError,
    };
}

/// The base of the three concrete errors. Not constructible, and its whole
/// prototype is `message` -- which is where the concrete errors' messages
/// actually live (measured: `getOwnPropertyNames(GPUError.prototype)` is
/// ['message', 'constructor'], and an instance has no own properties at all).
pub const GPUError = struct {
    /// Which of the three a base pointer really belongs to. `GPUError` itself
    /// is never handed to script, and the one place a page reads one back --
    /// `GPUUncapturedErrorEvent.error` -- gets the very object it was given
    /// (measured), so the leaf has to be recoverable from the base.
    pub const Type = union(enum) {
        validation: *GPUValidationError,
        out_of_memory: *GPUOutOfMemoryError,
        internal: *GPUInternalError,
    };

    _type: Type,
    _message: []const u8 = "",

    pub fn getMessage(self: *const GPUError) []const u8 {
        return self._message;
    }

    pub fn leaf(self: *const GPUError) Type {
        return self._type;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUError);

        pub const Meta = struct {
            pub const name = "GPUError";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const message = bridge.accessor(GPUError.getMessage, null, .{});
    };
};

pub const GPUValidationError = Concrete("GPUValidationError");
pub const GPUOutOfMemoryError = Concrete("GPUOutOfMemoryError");
pub const GPUInternalError = Concrete("GPUInternalError");

/// The three errors that differ only in brand: one DOMString argument, nothing
/// of their own on the prototype, and the message read back through GPUError.
fn Concrete(comptime type_name: []const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = GPUError;

        _proto: *GPUError,

        const ARITY = "Failed to construct '" ++ type_name ++ "': 1 argument required, but only 0 present.";

        pub fn constructor(message_: ?js.Value, exec: *const Execution) !*Self {
            const message = message_ orelse return dictionary.throwTypeError(ARITY, exec);
            // A DOMString, so a number stringifies rather than being refused
            // (measured: `new GPUValidationError(5).message` is '5').
            const text = try message.toStringSlice();
            return exec._factory.gpuError(
                GPUError{ ._type = undefined, ._message = try exec.arena.dupe(u8, text) },
                Self{ ._proto = undefined },
            );
        }

        pub fn asGPUError(self: *Self) *GPUError {
            return self._proto;
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = type_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const Prototype = GPUError;

            pub const constructor = bridge.constructor(Self.constructor, .{ .arity = 1 });
        };
    };
}

/// What `createComputePipelineAsync` rejects with. A DOMException, so it *is*
/// an Error and stringifies as "GPUPipelineError: boom" -- and its required
/// argument is the second one, `options`, not the message (measured: both
/// `new GPUPipelineError('boom')` and `new GPUPipelineError({reason: ...})`
/// complain that the value is not a GPUPipelineErrorInit).
pub const GPUPipelineError = struct {
    pub const Proto = DOMException;

    _proto: *DOMException,
    _reason: []const u8,

    const Init = dictionary.Reader("GPUPipelineError", "GPUPipelineErrorInit");
    const ARITY = "Failed to construct 'GPUPipelineError': 1 argument required, but only 0 present.";
    const NOT_INIT = "Failed to construct 'GPUPipelineError': The provided value is not of type 'GPUPipelineErrorInit'.";

    pub fn constructor(message_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*GPUPipelineError {
        const options = options_ orelse return dictionary.throwTypeError(
            if (message_ == null) ARITY else NOT_INIT,
            exec,
        );
        if (!options.isObject()) {
            return dictionary.throwTypeError(NOT_INIT, exec);
        }
        const init = try Init.read(options, exec);
        const reason = try resources.requiredEnum(
            Init,
            init,
            "reason",
            "GPUPipelineErrorReason",
            &.{ "validation", "internal" },
            exec,
        );

        // An absent message is '' rather than DOMException's canned text, and
        // Error.prototype.toString then drops the separator (measured:
        // String(new GPUPipelineError(undefined, {reason: 'internal'})) is
        // 'GPUPipelineError').
        // A provided `undefined` is not the same as an absent argument here:
        // the bridge hands the first one through as a value, and WebIDL treats
        // an undefined optional DOMString as absent rather than as "undefined".
        const message = if (message_) |value|
            (if (value.isUndefined()) "" else try value.toStringSlice())
        else
            "";
        return exec._factory.domException(
            DOMException.init(try exec.arena.dupe(u8, message), "GPUPipelineError"),
            GPUPipelineError{ ._proto = undefined, ._reason = reason },
        );
    }

    pub fn asDOMException(self: *GPUPipelineError) *DOMException {
        return self._proto;
    }

    pub fn getReason(self: *const GPUPipelineError) []const u8 {
        return self._reason;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUPipelineError);

        pub const Meta = struct {
            pub const name = "GPUPipelineError";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = DOMException;

        pub const constructor = bridge.constructor(GPUPipelineError.constructor, .{ .arity = 1 });
        pub const reason = bridge.accessor(GPUPipelineError.getReason, null, .{});
    };
};

/// `device.onuncapturederror`'s payload. Nothing fires one here -- no error is
/// ever raised to go uncaptured -- but a page can build one, and its flags are
/// worth transcribing: `cancelable` is true no matter what the init says, which
/// is not what EventInit's default would give (measured with `cancelable:
/// false` and with `bubbles: true`, both ignored).
pub const GPUUncapturedErrorEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    // The leaf rather than the base, so the getter hands back the very object
    // the page passed in (measured: `event.error === err`).
    _error: GPUError.Type,

    const Init = dictionary.Init("GPUUncapturedErrorEvent", "GPUUncapturedErrorEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*GPUUncapturedErrorEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'GPUUncapturedErrorEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'GPUUncapturedErrorEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        const err = try init.interfaceMember("error", GPUError, "GPUError", exec);
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "GPUUncapturedErrorEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            GPUUncapturedErrorEvent{ ._proto = undefined, ._error = err.leaf() },
        );
        // Chrome fixes all three flags rather than reading them off the init.
        Event.populatePrototypes(event, Event.Options{ .cancelable = true }, false);
        return event;
    }

    pub fn asEvent(self: *GPUUncapturedErrorEvent) *Event {
        return self._proto;
    }

    // The very error that was handed in, not a copy (measured).
    pub fn getError(self: *const GPUUncapturedErrorEvent) GPUError.Type {
        return self._error;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUUncapturedErrorEvent);

        pub const Meta = struct {
            pub const name = "GPUUncapturedErrorEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(GPUUncapturedErrorEvent.constructor, .{ .arity = 2 });
        pub const @"error" = bridge.accessor(GPUUncapturedErrorEvent.getError, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU errors" {
    try testing.htmlRunner("webgpu/errors.html", .{});
}
