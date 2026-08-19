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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const EventTarget = @import("EventTarget.zig");
const ProgressEvent = @import("event/ProgressEvent.zig");
const Blob = @import("Blob.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

/// https://w3c.github.io/FileAPI/#dfn-filereader
/// https://developer.mozilla.org/en-US/docs/Web/API/FileReader
const FileReader = @This();

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_exec: *Execution,
_proto: *EventTarget,
_arena: *lp.Arena,

_ready_state: ReadyState = .empty,
_result: ?Result = null,
_error: ?[]const u8 = null,

_aborted: bool = false,

const ReadyState = enum(u8) {
    empty = 0,
    loading = 1,
    done = 2,
};

const Result = union(enum) {
    string: []const u8,
    binary_string: js.String.OneByte,
    arraybuffer: js.ArrayBuffer,
};

pub fn init(exec: *Execution) !*FileReader {
    const arena = try exec.getArena(.tiny, "FileReader");
    errdefer arena.release();

    return exec._factory.eventTargetWithAllocator(arena.allocator(), FileReader{
        ._exec = exec,
        ._arena = arena,
        ._proto = undefined,
    });
}

pub fn deinit(self: *FileReader, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *FileReader, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FileReader) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *FileReader) *EventTarget {
    return self._proto;
}

pub fn getReadyState(self: *const FileReader) u8 {
    return @intFromEnum(self._ready_state);
}

pub fn getResult(self: *const FileReader) ?Result {
    return self._result;
}

pub fn getError(self: *const FileReader) ?[]const u8 {
    return self._error;
}

pub fn readAsArrayBuffer(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .arraybuffer);
}

pub fn readAsBinaryString(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .binary_string);
}

pub fn readAsText(self: *FileReader, blob: *Blob, encoding_: ?[]const u8) !void {
    _ = encoding_; // TODO: Handle encoding properly
    try self.readInternal(blob, .text);
}

pub fn readAsDataURL(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .data_url);
}

const ReadType = enum {
    arraybuffer,
    binary_string,
    text,
    data_url,
};

/// The bytes are in memory, so the read itself costs nothing -- but it still
/// answers on a task, because that is the only part of it a page can observe.
/// Chrome returns from `readAsDataURL` with `readyState` at LOADING and a null
/// result, and pages are written to that: browserscan.net registers its `load`
/// listener on the line after the call, so a read that dispatched before
/// returning would fire into an empty listener list and the page would wait on
/// its promise forever (measured -- the whole hardware card never resolved).
fn readInternal(self: *FileReader, blob: *Blob, read_type: ReadType) !void {
    if (self._ready_state == .loading) {
        return error.InvalidStateError;
    }

    // Reset state
    self._ready_state = .loading;
    self._result = null;
    self._error = null;
    self._aborted = false;

    const exec = self._exec;

    // _result outlives this call and the blob can be GC'd before the task
    // runs, let alone before JS reads the result, so neither the bytes nor the
    // mime type may be borrowed from it.
    const task = try exec._factory.create(ReadTask{
        .reader = self,
        .exec = exec,
        .read_type = read_type,
        .data = try self._arena.dupe(u8, blob._slice),
        .mime = try self._arena.dupe(u8, blob._mime),
    });
    errdefer exec._factory.destroy(task);

    // The reader has to outlive the task even if JS drops its last reference
    // in between, the same way an in-flight XMLHttpRequest holds itself.
    self.acquireRef();
    errdefer self.releaseRef(exec.page);

    try exec.js.scheduler.add(task, ReadTask.run, 0, .{
        .name = "FileReader.read",
        .finalizer = ReadTask.cancelled,
    });
}

const ReadTask = struct {
    reader: *FileReader,
    exec: *Execution,
    read_type: ReadType,
    data: []const u8,
    mime: []const u8,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReadTask = @ptrCast(@alignCast(ctx));
        const exec = self.exec;
        self.reader.releaseRef(exec.page);
        exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReadTask = @ptrCast(@alignCast(ctx));
        const exec = self.exec;
        const reader = self.reader;
        defer {
            reader.releaseRef(exec.page);
            exec._factory.destroy(self);
        }

        // abort() ran between the call and this task: it has already moved the
        // reader to done and fired abort/loadend, and nothing is left to do.
        if (reader._aborted) {
            return null;
        }

        const size = self.data.len;
        try reader.dispatch(.load_start, .{ .loaded = 0, .total = size }, exec);
        if (reader._aborted) {
            return null;
        }

        try reader.dispatch(.progress, .{ .loaded = size, .total = size }, exec);
        if (reader._aborted) {
            return null;
        }

        reader._result = switch (self.read_type) {
            .arraybuffer => .{ .arraybuffer = .{ .values = self.data } },
            .binary_string => .{ .binary_string = .{ .bytes = self.data } },
            .text => .{ .string = self.data },
            .data_url => blk: {
                const mime = if (self.mime.len > 0) self.mime else "application/octet-stream";
                const data_url = try encodeDataURL(reader._arena.allocator(), mime, self.data);
                break :blk .{ .string = data_url };
            },
        };

        reader._ready_state = .done;

        try reader.dispatch(.load, .{ .loaded = size, .total = size }, exec);
        try reader.dispatch(.load_end, .{ .loaded = size, .total = size }, exec);
        return null;
    }
};

pub fn abort(self: *FileReader) !void {
    if (self._ready_state != .loading) {
        return;
    }

    self._aborted = true;
    self._ready_state = .done;
    self._result = null;

    const exec = self._exec;
    try self.dispatch(.abort, null, exec);
    try self.dispatch(.load_end, null, exec);
}

fn dispatch(self: *FileReader, comptime event_type: DispatchType, progress_: ?Progress, exec: *Execution) !void {
    const typ = comptime switch (event_type) {
        .abort => "abort",
        .err => "error",
        .load => "load",
        .load_end => "loadend",
        .load_start => "loadstart",
        .progress => "progress",
    };

    const progress = progress_ orelse Progress{};
    const event = (try ProgressEvent.initTrusted(
        comptime .wrap(typ),
        .{ .total = progress.total, .loaded = progress.loaded },
        exec.page,
    )).asEvent();

    // The handler is a listener in the list now; nothing is passed by hand.
    return exec.dispatch(
        self.asEventTarget(),
        event,
        null,
        .{ .context = "FileReader " ++ typ },
    );
}

const DispatchType = enum {
    abort,
    err,
    load,
    load_end,
    load_start,
    progress,
};

const Progress = struct {
    loaded: usize = 0,
    total: usize = 0,
};

/// Encodes binary data as a data URL with base64 encoding.
/// Format: data:[<mediatype>][;base64],<data>
fn encodeDataURL(arena: Allocator, mime: []const u8, data: []const u8) ![]const u8 {
    const base64 = std.base64.standard.Encoder;

    // Calculate size needed for base64 encoding
    const encoded_size = base64.calcSize(data.len);

    // Allocate buffer for the full data URL
    // Format: "data:" + mime + ";base64," + encoded_data
    const prefix = "data:";
    const suffix = ";base64,";
    const total_size = prefix.len + mime.len + suffix.len + encoded_size;

    var pos: usize = 0;
    const buf = try arena.alloc(u8, total_size);

    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    @memcpy(buf[pos..][0..mime.len], mime);
    pos += mime.len;

    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    _ = base64.encode(buf[pos..], data);

    return buf;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FileReader);

    pub const Meta = struct {
        pub const name = "FileReader";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FileReader.init, .{});

    // State constants
    pub const EMPTY = bridge.property(@intFromEnum(FileReader.ReadyState.empty), .{ .template = true });
    pub const LOADING = bridge.property(@intFromEnum(FileReader.ReadyState.loading), .{ .template = true });
    pub const DONE = bridge.property(@intFromEnum(FileReader.ReadyState.done), .{ .template = true });

    // Properties
    pub const readyState = bridge.accessor(FileReader.getReadyState, null, .{});
    pub const result = bridge.accessor(FileReader.getResult, null, .{});
    pub const @"error" = bridge.accessor(FileReader.getError, null, .{});

    // Event handlers
    fn handler(comptime which: @import("global_event_handlers.zig").Handler) type {
        return @import("handler_property.zig").accessors(FileReader, which);
    }

    pub const onabort = bridge.accessor(handler(.onabort).get, handler(.onabort).set, .{});
    pub const onerror = bridge.accessor(handler(.onerror).get, handler(.onerror).set, .{});
    pub const onload = bridge.accessor(handler(.onload).get, handler(.onload).set, .{});
    pub const onloadend = bridge.accessor(handler(.onloadend).get, handler(.onloadend).set, .{});
    pub const onloadstart = bridge.accessor(handler(.onloadstart).get, handler(.onloadstart).set, .{});
    pub const onprogress = bridge.accessor(handler(.onprogress).get, handler(.onprogress).set, .{});

    // Methods
    pub const readAsArrayBuffer = bridge.function(FileReader.readAsArrayBuffer, .{});
    pub const readAsBinaryString = bridge.function(FileReader.readAsBinaryString, .{});
    pub const readAsText = bridge.function(FileReader.readAsText, .{});
    pub const readAsDataURL = bridge.function(FileReader.readAsDataURL, .{});
    pub const abort = bridge.function(FileReader.abort, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: FileReader" {
    try testing.htmlRunner("file_reader.html", .{});
}
