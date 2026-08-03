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

//! Byte streams: `new ReadableStream({type: 'bytes'})` and the three interfaces
//! it brings with it.
//!
//! The round trip a detector can reach is the one measured on a headed Chrome
//! 150 (win22-chrome.json, win26-chrome.json): a read on a byte stream with an
//! `autoAllocateChunkSize` makes `controller.byobRequest` appear with a
//! Uint8Array view of that size, the source writes into the view and calls
//! `respond(n)`, and the read resolves with the first n bytes. A BYOB reader
//! does the same with the view the reader itself supplied. Without an
//! `autoAllocateChunkSize` there is no byobRequest and `enqueue(view)` is the
//! only way in.
//!
//! One documented departure: Chrome detaches the view and transfers its buffer,
//! so the resolved chunk shares the source's ArrayBuffer. Here the bytes are
//! copied into a fresh Uint8Array — the contents and the length are what
//! Chrome reports, the buffer identity is not.

const std = @import("std");

const js = @import("../../js/js.zig");

const ReadableStream = @import("ReadableStream.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const Bytes = js.ArrayBufferRef(.uint8);

pub fn registerTypes() []const type {
    return &.{
        ReadableByteStreamController,
        ReadableStreamBYOBReader,
        ReadableStreamBYOBRequest,
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

/// The bytes an ArrayBufferView spans, as a mutable slice of the backing store.
fn viewBytes(value: js.Value) []u8 {
    const ref = Bytes{ .local = value.local, .handle = value.handle };
    return ref.slice();
}

/// A fresh Uint8Array holding a copy of `bytes`.
fn toUint8Array(bytes: []const u8, local: *const js.Local) js.Value {
    const array = Bytes.init(local, bytes.len);
    @memcpy(array.slice(), bytes);
    return .{ .local = local, .handle = array.handle };
}

pub const ReadableByteStreamController = struct {
    _stream: *ReadableStream,
    _execution: *const Execution,
    _arena: Allocator,
    _queue: std.ArrayList([]const u8) = .empty,
    _pending: std.ArrayList(PendingRead) = .empty,
    _auto_allocate_chunk_size: ?u32 = null,
    _high_water_mark: f64 = 0,
    _byob_request: ?*ReadableStreamBYOBRequest = null,

    const PendingRead = struct {
        resolver: js.PromiseResolver.Global,
        /// The view a BYOB read supplied; a default read has none until the
        /// controller allocates one from autoAllocateChunkSize.
        view: ?js.Value.Global = null,
    };

    pub fn init(
        stream: *ReadableStream,
        auto_allocate_chunk_size: ?u32,
        high_water_mark: f64,
        exec: *const Execution,
    ) !*ReadableByteStreamController {
        return exec._factory.create(ReadableByteStreamController{
            ._stream = stream,
            ._execution = exec,
            ._arena = exec.arena,
            ._auto_allocate_chunk_size = auto_allocate_chunk_size,
            ._high_water_mark = high_water_mark,
        });
    }

    /// A read from either kind of reader. `view_` is the BYOB reader's buffer;
    /// a default read passes null and gets the auto-allocated one instead.
    pub fn addRead(self: *ReadableByteStreamController, view_: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;

        if (self._queue.items.len > 0) {
            const chunk = self._queue.orderedRemove(0);
            const limit = if (view_) |v| @min(chunk.len, viewBytes(v).len) else chunk.len;
            return local.resolvePromise(.{ .done = false, .value = toUint8Array(chunk[0..limit], local) });
        }

        if (self._stream._state == .closed) {
            return local.resolvePromise(.{ .done = true, .value = null });
        }

        const resolver = local.createPromiseResolver();
        const view: ?js.Value = view_ orelse blk: {
            const size = self._auto_allocate_chunk_size orelse break :blk null;
            const array = Bytes.init(local, size);
            break :blk js.Value{ .local = local, .handle = array.handle };
        };

        try self._pending.append(self._arena, .{
            .resolver = try resolver.persist(),
            .view = if (view) |v| try v.persist() else null,
        });

        if (view) |v| {
            self._byob_request = try ReadableStreamBYOBRequest.init(self, v, exec);
        }
        return resolver.promise();
    }

    /// Hands the first n bytes of the outstanding view to the waiting read.
    fn respondWith(self: *ReadableByteStreamController, bytes: []const u8, exec: *const Execution) void {
        const local = exec.js.local.?;
        self._byob_request = null;
        if (self._pending.items.len == 0) {
            return;
        }
        const pending = self._pending.orderedRemove(0);
        local.toLocal(pending.resolver).resolve("byte stream respond", .{
            .done = false,
            .value = toUint8Array(bytes, local),
        });
    }

    pub fn enqueue(self: *ReadableByteStreamController, chunk_: ?js.Value, exec: *const Execution) !void {
        const chunk = chunk_ orelse return throwTypeError(
            "Failed to execute 'enqueue' on 'ReadableByteStreamController': 1 argument required, but only 0 present.",
            exec,
        );
        if (!chunk.isArrayBufferView()) {
            return throwTypeError(
                "Failed to execute 'enqueue' on 'ReadableByteStreamController': " ++
                    "parameter 1 is not of type 'ArrayBufferView'.",
                exec,
            );
        }
        if (self._stream._state != .readable) {
            return error.InvalidStateError;
        }

        const bytes = viewBytes(chunk);
        if (self._pending.items.len > 0) {
            return self.respondWith(bytes, exec);
        }
        try self._queue.append(self._arena, try self._arena.dupe(u8, bytes));
    }

    pub fn close(self: *ReadableByteStreamController, exec: *const Execution) !void {
        if (self._stream._state != .readable) {
            return error.InvalidStateError;
        }
        self._stream._state = .closed;
        self._byob_request = null;

        const local = exec.js.local.?;
        for (self._pending.items) |pending| {
            local.toLocal(pending.resolver).resolve("byte stream close", .{ .done = true, .value = null });
        }
        self._pending.clearRetainingCapacity();
    }

    pub fn doError(self: *ReadableByteStreamController, reason_: ?js.Value, exec: *const Execution) !void {
        if (self._stream._state != .readable) {
            return;
        }
        self._stream._state = .errored;
        self._byob_request = null;

        const local = exec.js.local.?;
        const reason = reason_ orelse js.Value{ .local = local, .handle = local.isolate.initUndefined() };
        for (self._pending.items) |pending| {
            local.toLocal(pending.resolver).reject("byte stream error", reason);
        }
        self._pending.clearRetainingCapacity();
    }

    /// Chrome reports 0 for a byte stream built without a strategy: byte
    /// streams default to a high water mark of 0, not 1 (measured).
    pub fn getDesiredSize(self: *const ReadableByteStreamController) ?f64 {
        return switch (self._stream._state) {
            .errored => null,
            .closed => 0,
            .readable => blk: {
                var queued: f64 = 0;
                for (self._queue.items) |chunk| queued += @floatFromInt(chunk.len);
                break :blk self._high_water_mark - queued;
            },
        };
    }

    pub fn getByobRequest(self: *ReadableByteStreamController) ?*ReadableStreamBYOBRequest {
        return self._byob_request;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ReadableByteStreamController);

        pub const Meta = struct {
            pub const name = "ReadableByteStreamController";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = ReadableByteStreamController;

        pub const byobRequest = bridge.accessor(T.getByobRequest, null, .{});
        pub const desiredSize = bridge.accessor(T.getDesiredSize, null, .{});
        pub const close = bridge.function(T.close, .{});
        pub const enqueue = bridge.function(T.enqueue, .{ .arity = 1 });
        pub const @"error" = bridge.function(T.doError, .{});
    };
};

pub const ReadableStreamBYOBRequest = struct {
    _controller: *ReadableByteStreamController,
    _view: js.Value.Global,

    pub fn init(
        controller: *ReadableByteStreamController,
        view: js.Value,
        exec: *const Execution,
    ) !*ReadableStreamBYOBRequest {
        return exec._factory.create(ReadableStreamBYOBRequest{
            ._controller = controller,
            ._view = try view.persist(),
        });
    }

    pub fn getView(self: *const ReadableStreamBYOBRequest, exec: *const Execution) js.Value {
        return exec.js.local.?.toLocal(self._view);
    }

    pub fn respond(self: *ReadableStreamBYOBRequest, written: u32, exec: *const Execution) !void {
        const bytes = viewBytes(self.getView(exec));
        if (written == 0) {
            return throwTypeError(
                "Failed to execute 'respond' on 'ReadableStreamBYOBRequest': bytes written is 0",
                exec,
            );
        }
        if (written > bytes.len) {
            return throwRangeError(
                "Failed to execute 'respond' on 'ReadableStreamBYOBRequest': " ++
                    "available read buffer is too small for specified number of bytes",
                exec,
            );
        }
        self._controller.respondWith(bytes[0..written], exec);
    }

    pub fn respondWithNewView(self: *ReadableStreamBYOBRequest, view_: ?js.Value, exec: *const Execution) !void {
        const view = view_ orelse return throwTypeError(
            "Failed to execute 'respondWithNewView' on 'ReadableStreamBYOBRequest': " ++
                "1 argument required, but only 0 present.",
            exec,
        );
        if (!view.isArrayBufferView()) {
            return throwTypeError(
                "Failed to execute 'respondWithNewView' on 'ReadableStreamBYOBRequest': " ++
                    "parameter 1 is not of type 'ArrayBufferView'.",
                exec,
            );
        }
        self._controller.respondWith(viewBytes(view), exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ReadableStreamBYOBRequest);

        pub const Meta = struct {
            pub const name = "ReadableStreamBYOBRequest";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = ReadableStreamBYOBRequest;

        pub const view = bridge.accessor(T.getView, null, .{});
        pub const respond = bridge.function(T.respond, .{});
        pub const respondWithNewView = bridge.function(T.respondWithNewView, .{ .arity = 1 });
    };
};

pub const ReadableStreamBYOBReader = struct {
    _stream: ?*ReadableStream,
    _closed: ?js.PromiseResolver.Global = null,

    /// `new ReadableStreamBYOBReader(stream)`. Both refusals are Chrome's own
    /// wording (measured): a non-stream is a parameter error, a default stream
    /// is the BYOB-specific one.
    pub fn init(stream_: ?js.Value, exec: *Execution) !*ReadableStreamBYOBReader {
        const value = stream_.?;
        const stream = exec.js.local.?.jsValueToZig(*ReadableStream, value) catch return throwTypeError(
            "Failed to construct 'ReadableStreamBYOBReader': parameter 1 is not of type 'ReadableStream'.",
            exec,
        );
        return initFrom(stream, "Failed to construct 'ReadableStreamBYOBReader'", exec);
    }

    /// `where` is the operation the refusal names: Chrome reports the same
    /// "non-byte stream" sentence from the constructor and from
    /// `getReader({mode: 'byob'})`, each under its own prefix (measured).
    pub fn initFrom(
        stream: *ReadableStream,
        comptime where: []const u8,
        exec: *const Execution,
    ) !*ReadableStreamBYOBReader {
        if (stream._byte_controller == null) {
            return throwTypeError(where ++ ": Cannot use a BYOB reader with a non-byte stream", exec);
        }
        if (stream.getLocked()) {
            return throwTypeError(
                "Failed to construct 'ReadableStreamBYOBReader': ReadableStreamBYOBReader " ++
                    "constructor can only accept readable streams that are not yet locked to a reader",
                exec,
            );
        }

        const reader = try exec._factory.create(ReadableStreamBYOBReader{ ._stream = stream });
        stream._byob_reader = reader;
        return reader;
    }

    pub fn read(self: *ReadableStreamBYOBReader, view_: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        const stream = self._stream orelse {
            return local.rejectPromise(.{ .type_error = "Reader has been released" });
        };
        const view = view_ orelse return local.rejectPromise(.{
            .type_error = "Failed to execute 'read' on 'ReadableStreamBYOBReader': " ++
                "1 argument required, but only 0 present.",
        });
        if (!view.isArrayBufferView()) {
            return local.rejectPromise(.{
                .type_error = "Failed to execute 'read' on 'ReadableStreamBYOBReader': " ++
                    "parameter 1 is not of type 'ArrayBufferView'.",
            });
        }
        return stream._byte_controller.?.addRead(view, exec);
    }

    pub fn releaseLock(self: *ReadableStreamBYOBReader) void {
        if (self._stream) |stream| {
            stream._byob_reader = null;
            self._stream = null;
        }
    }

    pub fn getClosed(self: *ReadableStreamBYOBReader, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (self._closed) |resolver| {
            return local.toLocal(resolver).promise();
        }
        const resolver = local.createPromiseResolver();
        self._closed = try resolver.persist();
        if (self._stream) |stream| {
            if (stream._state == .closed) {
                resolver.resolve("BYOB reader closed", {});
            }
        }
        return resolver.promise();
    }

    pub fn cancel(self: *ReadableStreamBYOBReader, reason_: ?[]const u8, exec: *const Execution) !js.Promise {
        const stream = self._stream orelse {
            return exec.js.local.?.rejectPromise(.{ .type_error = "Reader has been released" });
        };
        self.releaseLock();
        return stream.cancel(reason_, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ReadableStreamBYOBReader);

        pub const Meta = struct {
            pub const name = "ReadableStreamBYOBReader";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = ReadableStreamBYOBReader;

        pub const constructor = bridge.constructor(T.init, .{ .arity = 1 });
        pub const read = bridge.function(T.read, .{ .arity = 1 });
        pub const releaseLock = bridge.function(T.releaseLock, .{});
        pub const closed = bridge.accessor(T.getClosed, null, .{});
        pub const cancel = bridge.function(T.cancel, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: ByteStream" {
    try testing.htmlRunner("streams/byte_stream.html", .{});
}
