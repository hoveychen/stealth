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

//! CompressionStream / DecompressionStream, on the real zlib.
//!
//! These compress for real rather than reporting a shape, because the bytes
//! themselves are the fingerprint: a detector can gzip a known string and
//! compare. Chrome 150 answers 'hello hello hello' with 28 gzip bytes, 16
//! deflate bytes and 10 deflate-raw bytes (measured, win22-chrome.json), and
//! stock zlib at its default level reproduces all three exactly — Zig's own
//! flate does not (it emits 9 raw bytes for that input, not 10). So the engine
//! links the same zlib curl already carries.
//!
//! The gzip header's OS byte is zlib's OS_CODE for the build platform, which is
//! how Chrome gets its own — 19 on macOS, where the measurement was taken, so
//! nothing overrides it here. Chrome also answers in a single chunk however
//! much goes in: 70 KB of input still came back as one 597-byte chunk.
//!
//! Errors are zlib's: Chrome's "The compressed data was not valid: incorrect
//! header check." is its prefix plus zlib's `msg`, and an input that ends
//! before the stream does is "Compressed input was truncated."

const std = @import("std");

const c = @import("zlib");
const js = @import("../../js/js.zig");

const ReadableStream = @import("ReadableStream.zig");
const WritableStream = @import("WritableStream.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const Bytes = js.ArrayBufferRef(.uint8);

pub fn registerTypes() []const type {
    return &.{
        CompressionStream,
        DecompressionStream,
    };
}

const Format = enum {
    gzip,
    deflate,
    @"deflate-raw",

    /// zlib's windowBits encodes the container: 15 is a zlib header, +16 is
    /// gzip, negative is a bare deflate stream.
    fn windowBits(self: Format) c_int {
        return switch (self) {
            .gzip => 15 + 16,
            .deflate => 15,
            .@"deflate-raw" => -15,
        };
    }
};

/// Chrome stringifies whatever it is given before complaining, so
/// `new CompressionStream(undefined)` names 'undefined' (measured).
fn parseFormat(comptime name: []const u8, raw: []const u8, exec: *const Execution) !Format {
    return std.meta.stringToEnum(Format, raw) orelse {
        const isolate = exec.js.isolate;
        const message = try std.fmt.allocPrint(
            exec.arena,
            "Failed to construct '" ++ name ++ "': Unsupported compression format: '{s}'",
            .{raw},
        );
        _ = isolate.throwException(isolate.createTypeError(message));
        return error.JsException;
    };
}

/// One side of a transform, holding the zlib stream and the readable it feeds.
const Codec = struct {
    _readable: *ReadableStream,
    _writable: *WritableStream,
    _arena: Allocator,
    _input: std.ArrayList(u8) = .empty,
    _format: Format,
    _decompress: bool,
    /// zlib's complaint, kept until the readable side can carry it.
    _error: ?[]const u8 = null,

    fn init(
        format: Format,
        comptime decompress: bool,
        owner: *anyopaque,
        exec: *const Execution,
    ) !Codec {
        var self = Codec{
            ._readable = try ReadableStream.init(null, null, exec),
            ._writable = try WritableStream.init(null, exec),
            ._arena = exec.arena,
            ._format = format,
            ._decompress = decompress,
        };
        self._writable._native = .{
            .ctx = owner,
            .write = nativeWrite,
            .close = nativeClose,
        };
        return self;
    }

    /// The owner's Codec always sits at the front of the owner struct, so the
    /// sink hooks can recover it from the opaque pointer the sink carries.
    fn fromCtx(ctx: *anyopaque) *Codec {
        return @ptrCast(@alignCast(ctx));
    }

    fn nativeWrite(ctx: *anyopaque, chunk: js.Value, _: *const Execution) anyerror!void {
        const self = fromCtx(ctx);
        // Chrome leaves the write promise of a chunk that is not a BufferSource
        // pending forever (measured); refusing it here does the same.
        if (!chunk.isArrayBufferView() and !chunk.isArrayBuffer()) {
            return error.ChunkNotAccepted;
        }
        const ref = Bytes{ .local = chunk.local, .handle = chunk.handle };
        try self._input.appendSlice(self._arena, ref.slice());
    }

    fn nativeClose(ctx: *anyopaque, exec: *const Execution) anyerror!void {
        const self = fromCtx(ctx);
        // A bad stream is not a synchronous throw: Chrome errors the readable
        // side, so it is the pending read that rejects (measured).
        const out = self.run() catch {
            const message = self._error orelse "The compressed data was not valid.";
            return self._readable._controller.doError(message);
        };
        const local = exec.js.local.?;
        const array = Bytes.init(local, out.len);
        @memcpy(array.slice(), out);
        try self._readable._controller.enqueueValue(.{ .local = local, .handle = array.handle });
        try self._readable._controller.close();
    }

    fn run(self: *Codec) ![]const u8 {
        return if (self._decompress)
            inflateAll(self._input.items, self._format, self._arena, &self._error)
        else
            deflateAll(self._input.items, self._format, self._arena);
    }
};

fn deflateAll(input: []const u8, format: Format, arena: Allocator) ![]const u8 {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.deflateInit2_(
        &stream,
        c.Z_DEFAULT_COMPRESSION,
        c.Z_DEFLATED,
        format.windowBits(),
        8, // memLevel: zlib's own default
        c.Z_DEFAULT_STRATEGY,
        c.ZLIB_VERSION,
        @sizeOf(c.z_stream),
    ) != c.Z_OK) {
        return error.OutOfMemory;
    }
    defer _ = c.deflateEnd(&stream);

    var out: std.ArrayList(u8) = .empty;
    // deflateBound is exact enough that one pass always suffices.
    const cap = c.deflateBound(&stream, @intCast(input.len)) + 64;
    try out.resize(arena, cap);

    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);
    stream.next_out = out.items.ptr;
    stream.avail_out = @intCast(cap);

    if (c.deflate(&stream, c.Z_FINISH) != c.Z_STREAM_END) {
        return error.OutOfMemory;
    }
    out.shrinkRetainingCapacity(cap - stream.avail_out);
    return out.items;
}

fn inflateAll(input: []const u8, format: Format, arena: Allocator, out_error: *?[]const u8) ![]const u8 {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.inflateInit2_(&stream, format.windowBits(), c.ZLIB_VERSION, @sizeOf(c.z_stream)) != c.Z_OK) {
        return error.OutOfMemory;
    }
    defer _ = c.inflateEnd(&stream);

    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);

    var out: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        stream.next_out = &chunk;
        stream.avail_out = chunk.len;
        const rc = c.inflate(&stream, c.Z_NO_FLUSH);
        try out.appendSlice(arena, chunk[0 .. chunk.len - stream.avail_out]);
        switch (rc) {
            c.Z_STREAM_END => return out.items,
            c.Z_OK => {
                if (stream.avail_in == 0 and stream.avail_out != 0) {
                    // The input ran out mid-stream.
                    out_error.* = "Compressed input was truncated.";
                    return error.DecompressionFailed;
                }
            },
            c.Z_BUF_ERROR => {
                out_error.* = "Compressed input was truncated.";
                return error.DecompressionFailed;
            },
            else => {
                out_error.* = if (stream.msg) |msg|
                    try std.fmt.allocPrint(
                        arena,
                        "The compressed data was not valid: {s}.",
                        .{std.mem.span(msg)},
                    )
                else
                    "The compressed data was not valid.";
                return error.DecompressionFailed;
            },
        }
    }
}

pub const CompressionStream = struct {
    // The Codec has to be the first field: the sink hooks recover it from the
    // opaque pointer they are handed.
    _codec: Codec,

    pub fn init(format_: []const u8, exec: *Execution) !*CompressionStream {
        const format = try parseFormat("CompressionStream", format_, exec);
        const self = try exec._factory.createT(CompressionStream);
        self.* = .{ ._codec = try Codec.init(format, false, self, exec) };
        return self;
    }

    pub fn getReadable(self: *const CompressionStream) *ReadableStream {
        return self._codec._readable;
    }

    pub fn getWritable(self: *const CompressionStream) *WritableStream {
        return self._codec._writable;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CompressionStream);

        pub const Meta = struct {
            pub const name = "CompressionStream";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CompressionStream.init, .{});
        pub const readable = bridge.accessor(CompressionStream.getReadable, null, .{});
        pub const writable = bridge.accessor(CompressionStream.getWritable, null, .{});
    };
};

pub const DecompressionStream = struct {
    _codec: Codec,

    pub fn init(format_: []const u8, exec: *Execution) !*DecompressionStream {
        const format = try parseFormat("DecompressionStream", format_, exec);
        const self = try exec._factory.createT(DecompressionStream);
        self.* = .{ ._codec = try Codec.init(format, true, self, exec) };
        return self;
    }

    pub fn getReadable(self: *const DecompressionStream) *ReadableStream {
        return self._codec._readable;
    }

    pub fn getWritable(self: *const DecompressionStream) *WritableStream {
        return self._codec._writable;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DecompressionStream);

        pub const Meta = struct {
            pub const name = "DecompressionStream";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(DecompressionStream.init, .{});
        pub const readable = bridge.accessor(DecompressionStream.getReadable, null, .{});
        pub const writable = bridge.accessor(DecompressionStream.getWritable, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: CompressionStream" {
    try testing.htmlRunner("streams/compression.html", .{});
}
