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

const js = @import("../../js/js.zig");

const ReadableStream = @import("ReadableStream.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");

const Execution = js.Execution;

const ReadableStreamDefaultReader = @This();

_stream: ?*ReadableStream,
_execution: *const Execution,
_closed: ?js.PromiseResolver.Global = null,

pub fn init(stream: *ReadableStream, exec: *const Execution) !*ReadableStreamDefaultReader {
    return exec._factory.create(ReadableStreamDefaultReader{
        ._stream = stream,
        ._execution = exec,
    });
}

/// `new ReadableStreamDefaultReader(stream)`. Chrome constructs one directly,
/// with these two refusals (measured, win26-chrome.json).
pub fn constructor(stream_: ?js.Value, exec: *Execution) !*ReadableStreamDefaultReader {
    const isolate = exec.js.isolate;
    const stream = exec.js.local.?.jsValueToZig(*ReadableStream, stream_.?) catch {
        _ = isolate.throwException(isolate.createTypeError(
            "Failed to construct 'ReadableStreamDefaultReader': parameter 1 is not of type 'ReadableStream'.",
        ));
        return error.JsException;
    };
    if (stream.getLocked()) {
        _ = isolate.throwException(isolate.createTypeError(
            "Failed to construct 'ReadableStreamDefaultReader': ReadableStreamDefaultReader " ++
                "constructor can only accept readable streams that are not yet locked to a reader",
        ));
        return error.JsException;
    }
    return stream.defaultReader(exec);
}

/// Resolves when the stream closes. Nothing here ever rejects it: a stream
/// that errors takes the read promise with it.
pub fn getClosed(self: *ReadableStreamDefaultReader, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self._closed) |resolver| {
        return local.toLocal(resolver).promise();
    }
    const resolver = local.createPromiseResolver();
    self._closed = try resolver.persist();
    if (self._stream) |stream| {
        if (stream._state == .closed) {
            resolver.resolve("reader closed", {});
        }
    }
    return resolver.promise();
}

pub const ReadResult = struct {
    done: bool,
    value: Chunk,

    // Done like this so that we can properly return undefined in some cases
    const Chunk = union(enum) {
        empty,
        string: []const u8,
        uint8array: js.TypedArray(u8),
        js_value: js.Value.Global,

        pub fn fromChunk(chunk: ReadableStreamDefaultController.Chunk) Chunk {
            return switch (chunk) {
                .string => |s| .{ .string = s },
                .uint8array => |arr| .{ .uint8array = arr },
                .js_value => |val| .{ .js_value = val },
            };
        }
    };
};

pub fn read(self: *ReadableStreamDefaultReader, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Reader has been released" });
    };
    stream._disturbed = true;

    if (stream._state == .errored) {
        return local.rejectPromise(.{ .type_error = stream._stored_error orelse "Stream errored" });
    }

    if (stream._byte_controller) |byte_controller| {
        return byte_controller.addRead(null, exec);
    }

    if (stream._controller.dequeue()) |chunk| {
        const result = ReadResult{
            .done = false,
            .value = .fromChunk(chunk),
        };
        return local.resolvePromise(result);
    }

    if (stream._state == .closed) {
        const result = ReadResult{
            .done = true,
            .value = .empty,
        };
        return local.resolvePromise(result);
    }

    // No data, but not closed. We need to queue the read for any future data
    return stream._controller.addPendingRead(local);
}

pub fn releaseLock(self: *ReadableStreamDefaultReader) void {
    if (self._stream) |stream| {
        stream.releaseReader();
        self._stream = null;
    }
}

pub fn cancel(self: *ReadableStreamDefaultReader, reason_: ?[]const u8, exec: *const Execution) !js.Promise {
    const stream = self._stream orelse {
        return exec.js.local.?.rejectPromise(.{ .type_error = "Reader has been released" });
    };

    self.releaseLock();

    return stream.cancel(reason_, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ReadableStreamDefaultReader);

    pub const Meta = struct {
        pub const name = "ReadableStreamDefaultReader";
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "releaseLock";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ReadableStreamDefaultReader.constructor, .{ .arity = 1 });
    pub const read = bridge.function(ReadableStreamDefaultReader.read, .{});
    pub const releaseLock = bridge.function(ReadableStreamDefaultReader.releaseLock, .{});
    pub const closed = bridge.accessor(ReadableStreamDefaultReader.getClosed, null, .{});
    pub const cancel = bridge.function(ReadableStreamDefaultReader.cancel, .{});
};
