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

const js = @import("../../js/js.zig");
const WritableStream = @import("WritableStream.zig");

const Execution = js.Execution;

const WritableStreamDefaultWriter = @This();

_stream: ?*WritableStream,

pub fn init(stream: *WritableStream, exec: *const Execution) !*WritableStreamDefaultWriter {
    return exec._factory.create(WritableStreamDefaultWriter{
        ._stream = stream,
    });
}

/// `new WritableStreamDefaultWriter(stream)`, with Chrome's own refusal for a
/// non-stream (measured, win26-chrome.json).
pub fn constructor(stream_: ?js.Value, exec: *Execution) !*WritableStreamDefaultWriter {
    const isolate = exec.js.isolate;
    const stream = exec.js.local.?.jsValueToZig(*WritableStream, stream_.?) catch {
        _ = isolate.throwException(isolate.createTypeError(
            "Failed to construct 'WritableStreamDefaultWriter': parameter 1 is not of type 'WritableStream'.",
        ));
        return error.JsException;
    };
    return stream.getWriter(exec);
}

/// Aborting a sink that never existed simply closes the stream.
pub fn abort(self: *WritableStreamDefaultWriter, _: ?js.Value, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };
    stream._state = .errored;
    return local.resolvePromise(.{});
}

pub fn write(self: *WritableStreamDefaultWriter, chunk: js.Value, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state != .writable) {
        return local.rejectPromise(.{ .type_error = "Stream is not writable" });
    }

    try stream.writeChunk(chunk, exec);

    return local.resolvePromise(.{});
}

pub fn close(self: *WritableStreamDefaultWriter, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state != .writable) {
        return local.rejectPromise(.{ .type_error = "Stream is not writable" });
    }

    try stream.closeStream(exec);

    return local.resolvePromise(.{});
}

pub fn releaseLock(self: *WritableStreamDefaultWriter) void {
    if (self._stream) |stream| {
        stream._writer = null;
        self._stream = null;
    }
}

pub fn getClosed(self: *WritableStreamDefaultWriter, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state == .closed) {
        return local.resolvePromise(.{});
    }

    return local.resolvePromise(.{});
}

pub fn getDesiredSize(self: *const WritableStreamDefaultWriter) ?i32 {
    const stream = self._stream orelse return null;
    return switch (stream._state) {
        .writable => 1,
        .closed => 0,
        .errored => null,
    };
}

pub fn getReady(self: *WritableStreamDefaultWriter, exec: *const Execution) !js.Promise {
    _ = self;
    return exec.js.local.?.resolvePromise(.{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WritableStreamDefaultWriter);

    pub const Meta = struct {
        pub const name = "WritableStreamDefaultWriter";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const T = WritableStreamDefaultWriter;

    pub const constructor = bridge.constructor(T.constructor, .{ .arity = 1 });
    pub const closed = bridge.accessor(T.getClosed, null, .{});
    pub const desiredSize = bridge.accessor(T.getDesiredSize, null, .{});
    pub const ready = bridge.accessor(T.getReady, null, .{});
    pub const abort = bridge.function(T.abort, .{});
    pub const close = bridge.function(T.close, .{});
    pub const releaseLock = bridge.function(T.releaseLock, .{});
    pub const write = bridge.function(T.write, .{});
};
