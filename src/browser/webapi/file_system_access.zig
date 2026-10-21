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

//! The File System Access API, and behind it the origin private file system.
//!
//! Three of the four doors into it are still shut: the window pickers all reject
//! with `SecurityError: Failed to execute 'show*Picker' on 'Window': Must be
//! handling a user gesture to show a file picker.` (measured on a headed
//! Chrome 150), and `DataTransferItem.getAsFileSystemHandle()` has no item to
//! hand out. The fourth is open: `navigator.storage.getDirectory()` returns the
//! root of this origin's private file system, and from there the whole tree
//! works -- entries are created, looked up, written, read, truncated and
//! removed.
//!
//! It is open because Cloudflare's Turnstile widget walks it. Its blob worker
//! feature-detects `navigator.storage.getDirectory` and, when it is there, posts
//! `getDirectory -> getFileHandle({create:true}) -> createSyncAccessHandle`,
//! writes a byte, times a `flush()` and reports the double -- `0.4949999749660492`
//! on the oracle arm. With no `getDirectory` the probe was never posted at all,
//! so the answer field did not exist rather than being wrong, which is a louder
//! tell than any number. See tools/fingerprint/README.md, "The probe table, both
//! arms, one sitting".
//!
//! The tree itself is `filesystem.zig`'s `Node`: in-memory, per-origin, shared
//! by every realm of that origin (a page and its workers reach the same
//! entries, as in Chrome), and anchored on the Page. The interfaces around it
//! are a different API from that file's `webkitRequestFileSystem` tree -- these
//! are the modern handles -- but the tree operations are the same ones, so they
//! are shared rather than rewritten.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const File = @import("File.zig");
const Blob = @import("Blob.zig");
const Factory = @import("../Factory.zig");
const DOMException = @import("DOMException.zig");
const WritableStream = @import("streams/WritableStream.zig");
const fs = @import("filesystem.zig");
const Mime = @import("../Mime.zig");
const frames = @import("webcodecs/frames.zig");

const Execution = js.Execution;
const Node = fs.Node;

pub fn registerTypes() []const type {
    return &.{
        FileSystemHandle,
        FileSystemFileHandle,
        FileSystemDirectoryHandle,
        FileSystemWritableFileStream,
    };
}

// A PermissionStatus-shaped answer; `queryPermission` and `requestPermission`
// resolve with the state string.
const PERMISSION_STATE = "granted";

/// Chrome's own words for the refusals these operations can produce. Only the
/// two DOMException messages are quoted from a measurement (they are the
/// generic per-name strings, the same ones filesystem.zig quotes); the TypeError
/// wording below is this engine's, not a measured Blink string.
const messages = struct {
    const not_found = "A requested file or directory could not be found at the time an operation was processed.";
    const type_mismatch = "The path supplied exists, but was not an entry of requested type.";
    const closed = "The access handle was already closed.";
};

fn rejectDom(comptime name: []const u8, message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("file_system_access", DOMException.init(message, name));
    return resolver.promise();
}

fn rejectTypeError(message: []const u8, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .type_error = message });
}

fn throwDom(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

/// Per spec a name is a single path component: not empty, not `.` or `..`, and
/// with no separator in it. Chrome refuses the rest with a TypeError before it
/// looks anything up, so a page cannot use the name to walk out of the root.
fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\") == null;
}

/// The two lookup operations differ only in the kind they insist on, so they
/// share this. `create` comes from the `{ create: true }` dictionary.
const GetOptions = struct {
    create: bool = false,
};

fn newHandle(node: *Node, exec: *const Execution) !js.Promise {
    switch (node.kind) {
        .file => return exec.js.local.?.resolvePromise(try wrapFile(node, exec)),
        .directory => return exec.js.local.?.resolvePromise(try wrapDirectory(node, exec)),
    }
}

fn wrapFile(node: *Node, exec: *const Execution) !*FileSystemFileHandle {
    return exec._factory.chained(.{
        FileSystemHandle{ ._node = node },
        FileSystemFileHandle{ ._proto = undefined },
    });
}

fn wrapDirectory(node: *Node, exec: *const Execution) !*FileSystemDirectoryHandle {
    return exec._factory.chained(.{
        FileSystemHandle{ ._node = node },
        FileSystemDirectoryHandle{ ._proto = undefined },
    });
}

/// `navigator.storage.getDirectory()`. A fresh wrapper over the origin's root
/// on every call -- Chrome's two answers compare unequal but report
/// `isSameEntry` true (the same thing the legacy tree does with its entries).
pub fn getDirectory(exec: *const Execution) !js.Promise {
    const root = try exec.page.opfsRoot(exec.origin());
    return exec.js.local.?.resolvePromise(try wrapDirectory(root, exec));
}

pub const FileSystemHandle = struct {
    _node: *Node,

    pub fn getKind(self: *const FileSystemHandle) []const u8 {
        return switch (self._node.kind) {
            .file => "file",
            .directory => "directory",
        };
    }

    pub fn getName(self: *const FileSystemHandle) []const u8 {
        return self._node.name;
    }

    /// Two wrappers over one entry are the same entry, which is the only way a
    /// page can tell that `getDirectory()` handed it the root twice.
    pub fn isSameEntry(self: *const FileSystemHandle, other: ?*FileSystemHandle) bool {
        const handle = other orelse return false;
        return self._node == handle._node;
    }

    pub fn queryPermission(_: *const FileSystemHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(PERMISSION_STATE);
    }

    pub fn requestPermission(_: *const FileSystemHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(PERMISSION_STATE);
    }

    /// Unlinks the entry from its parent. What Chrome does when asked to remove
    /// the *root* is not measured, so that case is left alone rather than
    /// guessed at.
    pub fn remove(self: *const FileSystemHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        self._node.detach();
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileSystemHandle);

        pub const Meta = struct {
            pub const name = "FileSystemHandle";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const kind = bridge.accessor(FileSystemHandle.getKind, null, .{});
        pub const name = bridge.accessor(FileSystemHandle.getName, null, .{});
        // An optional-typed argument does not count toward the reflected
        // arity, and Chrome reports 1 (probe-operation-arity).
        pub const isSameEntry = bridge.function(FileSystemHandle.isSameEntry, .{ .arity = 1 });
        pub const queryPermission = bridge.function(FileSystemHandle.queryPermission, .{});
        pub const remove = bridge.function(FileSystemHandle.remove, .{});
        pub const requestPermission = bridge.function(FileSystemHandle.requestPermission, .{});
    };
};

pub const FileSystemFileHandle = struct {
    pub const Proto = FileSystemHandle;

    _proto: *FileSystemHandle,

    /// The writable stream is still a shell -- there is no
    /// FileSystemWritableFileStream instance to hand out -- so this keeps
    /// resolving with undefined. The sync access handle below is the path the
    /// widget takes, and it is real.
    pub fn createWritable(_: *const FileSystemFileHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    /// A File over the entry's current bytes, typed from the extension the way
    /// the legacy tree types its own (measured there: a `.txt` entry reads back
    /// `text/plain`, not `""`).
    pub fn getFile(self: *const FileSystemFileHandle, exec: *Execution) !js.Promise {
        const node = self._proto._node;
        const arena = try exec.getArena(node.contents.len + node.name.len + 256, "FileSystemFileHandle.getFile");
        errdefer arena.release();

        const handle = try Factory.chainedWithAllocator(arena.allocator(), .{
            try Blob.buildValueFromBytes(arena, node.contents, Mime.fromExtension(node.name)),
            File{
                ._proto = undefined,
                ._name = try arena.dupe(u8, node.name),
                ._last_modified = node.modified_ms,
            },
        });
        handle._proto._type = .{ .file = handle };
        return exec.js.local.?.resolvePromise(handle);
    }

    pub fn move(_: *const FileSystemFileHandle, _: js.Value, _: ?[]const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    /// The operation the Turnstile probe reaches for. `[Exposed=DedicatedWorker]`
    /// in Chrome; the engine's exposure gate is window-or-worker, so a shared
    /// worker carries it too -- a residual, and the smaller half of it, since
    /// `FileSystemSyncAccessHandle` itself is registered for the dedicated
    /// worker alone.
    pub fn createSyncAccessHandle(self: *const FileSystemFileHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        const handle = try exec._factory.create(FileSystemSyncAccessHandle{ ._node = self._proto._node });
        return exec.js.local.?.resolvePromise(handle);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileSystemFileHandle);

        pub const Meta = struct {
            pub const name = "FileSystemFileHandle";
            // `createSyncAccessHandle` is worker-only, so Blink installs it
            // per context and `constructor` lands ahead of it (measured).
            pub const constructor_after = "move";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const createWritable = bridge.function(FileSystemFileHandle.createWritable, .{});
        pub const getFile = bridge.function(FileSystemFileHandle.getFile, .{});
        pub const move = bridge.function(FileSystemFileHandle.move, .{});
        pub const createSyncAccessHandle = bridge.function(FileSystemFileHandle.createSyncAccessHandle, .{ .exposed = .dedicated_worker });
    };
};

pub const FileSystemDirectoryHandle = struct {
    pub const Proto = FileSystemHandle;

    _proto: *FileSystemHandle,

    fn lookup(
        self: *const FileSystemDirectoryHandle,
        kind: fs.NodeKind,
        name: []const u8,
        options: ?GetOptions,
        comptime operation: []const u8,
        exec: *const Execution,
    ) !js.Promise {
        if (validName(name) == false) {
            return rejectTypeError("Failed to execute '" ++ operation ++
                "' on 'FileSystemDirectoryHandle': Name is not allowed.", exec);
        }

        const dir = self._proto._node;
        if (dir.find(name)) |existing| {
            if (existing.kind != kind) {
                return rejectDom("TypeMismatchError", messages.type_mismatch, exec);
            }
            return newHandle(existing, exec);
        }

        const create = (options orelse GetOptions{}).create;
        if (create == false) {
            return rejectDom("NotFoundError", messages.not_found, exec);
        }

        // Page lifetime, not the calling realm's: a worker can create an entry
        // and a worker can die, and the tree outlives it.
        const node = try fs.createNode(exec.page.frame_arena, dir, kind, name);
        return newHandle(node, exec);
    }

    pub fn getDirectoryHandle(
        self: *const FileSystemDirectoryHandle,
        name: []const u8,
        options: ?GetOptions,
        exec: *const Execution,
    ) !js.Promise {
        return self.lookup(.directory, name, options, "getDirectoryHandle", exec);
    }

    pub fn getFileHandle(
        self: *const FileSystemDirectoryHandle,
        name: []const u8,
        options: ?GetOptions,
        exec: *const Execution,
    ) !js.Promise {
        return self.lookup(.file, name, options, "getFileHandle", exec);
    }

    pub fn removeEntry(
        self: *const FileSystemDirectoryHandle,
        name: []const u8,
        _: ?js.Value,
        exec: *const Execution,
    ) !js.Promise {
        if (validName(name) == false) {
            return rejectTypeError("Failed to execute 'removeEntry' on " ++
                "'FileSystemDirectoryHandle': Name is not allowed.", exec);
        }
        const entry = self._proto._node.find(name) orelse {
            return rejectDom("NotFoundError", messages.not_found, exec);
        };
        entry.detach();
        return exec.js.local.?.resolvePromise({});
    }

    /// The path from this directory down to `descendant`, one name per segment,
    /// or null when it is not underneath. The same handle resolves to an empty
    /// array.
    pub fn resolve(self: *const FileSystemDirectoryHandle, other: ?*FileSystemHandle, exec: *const Execution) !js.Promise {
        const handle = other orelse return exec.js.local.?.resolvePromise(null);

        var segments: std.ArrayList([]const u8) = .empty;
        var walk: ?*Node = handle._node;
        while (walk) |node| {
            if (node == self._proto._node) {
                std.mem.reverse([]const u8, segments.items);
                return exec.js.local.?.resolvePromise(segments.items);
            }
            try segments.append(exec.call_arena, node.name);
            walk = node.parent;
        }
        return exec.js.local.?.resolvePromise(null);
    }

    // entries/keys/values (and Symbol.asyncIterator, which is entries again)
    // are the async-iterable declaration. They still walk nothing: an async
    // iterator over [name, handle] pairs is machinery this file does not have,
    // and nothing measured reads it. A directory with entries therefore
    // iterates as empty, which is a residual worth its own plan.
    pub fn entries(_: *const FileSystemDirectoryHandle) []const []const u8 {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileSystemDirectoryHandle);

        pub const Meta = struct {
            pub const name = "FileSystemDirectoryHandle";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getDirectoryHandle = bridge.function(FileSystemDirectoryHandle.getDirectoryHandle, .{});
        pub const getFileHandle = bridge.function(FileSystemDirectoryHandle.getFileHandle, .{});
        pub const removeEntry = bridge.function(FileSystemDirectoryHandle.removeEntry, .{});
        // As isSameEntry: the optional handle argument is not reflected.
        pub const resolve = bridge.function(FileSystemDirectoryHandle.resolve, .{ .arity = 1 });
        pub const entries = bridge.function(FileSystemDirectoryHandle.entries, .{});
        pub const keys = bridge.function(FileSystemDirectoryHandle.entries, .{});
        pub const values = bridge.function(FileSystemDirectoryHandle.entries, .{});
        pub const symbol_async_iterator = bridge.iterator(FileSystemDirectoryHandle.entries, .{ .async = true });
    };
};

/// `[Exposed=DedicatedWorker]`, and every operation on it is synchronous -- that
/// is the whole point of it, and why the Turnstile probe can time a `flush()`
/// with two `performance.now()` reads around it.
pub const FileSystemSyncAccessHandle = struct {
    _node: *Node,
    _closed: bool = false,

    /// `{ at: n }`, the offset every read and write takes. Unlike the writable
    /// stream there is no cursor: an omitted `at` means 0, not "where the last
    /// call left off".
    const AtOptions = struct {
        at: f64 = 0,
    };

    fn open(self: *const FileSystemSyncAccessHandle, exec: *const Execution) !void {
        if (self._closed) {
            return throwDom("InvalidStateError", messages.closed, exec);
        }
    }

    fn offset(options: ?AtOptions) usize {
        const at = (options orelse AtOptions{}).at;
        if (at <= 0) return 0;
        return @intFromFloat(at);
    }

    /// f64 rather than u64 for the same reason StorageManager quotes its quota
    /// as one: past 2^32 a u64 marshals as a BigInt where Chrome reports a
    /// plain Number.
    pub fn getSize(self: *const FileSystemSyncAccessHandle, exec: *const Execution) !f64 {
        try self.open(exec);
        return @floatFromInt(self._node.contents.len);
    }

    pub fn read(self: *const FileSystemSyncAccessHandle, buffer: js.Value, options: ?AtOptions, exec: *const Execution) !f64 {
        try self.open(exec);
        const into = frames.bufferSource(buffer) orelse return error.TypeMismatch;

        const contents = self._node.contents;
        const at = offset(options);
        if (at >= contents.len) {
            return 0;
        }
        const count = @min(into.len, contents.len - at);
        @memcpy(into[0..count], contents[at..][0..count]);
        return @floatFromInt(count);
    }

    pub fn write(self: *FileSystemSyncAccessHandle, buffer: js.Value, options: ?AtOptions, exec: *const Execution) !f64 {
        try self.open(exec);
        const payload = frames.bufferSource(buffer) orelse return error.TypeMismatch;
        try fs.writeAt(exec.page.frame_arena, self._node, offset(options), payload);
        return @floatFromInt(payload.len);
    }

    pub fn truncate(self: *FileSystemSyncAccessHandle, size: f64, exec: *const Execution) !void {
        try self.open(exec);
        const length: usize = if (size <= 0) 0 else @intFromFloat(size);
        return fs.truncateTo(exec.page.frame_arena, self._node, length);
    }

    /// Nothing is buffered -- a write has already landed in the tree by the time
    /// it returns -- so there is nothing to push, and the honest answer is that
    /// this costs nothing.
    ///
    /// It cannot cost nothing. Chrome's flush() is a real fsync and the probe
    /// exists to time it: three oracle sittings answered 0.400, 0.495 and 4.145
    /// milliseconds (results/fopt-e1-oracle.json, fopt-e3-oracle.json,
    /// p4-oracle.json). The spread is wide enough that no particular number is
    /// expected, but a flat `0` for a timed operation is a value no machine with
    /// a disk produces -- and the whole point of implementing OPFS here was that
    /// a missing answer is louder than a wrong one, which goes for an impossible
    /// answer too. So the call spends a slice of that band, jittered, because a
    /// constant repeated across samples would be a tell of its own.
    pub fn flush(self: *const FileSystemSyncAccessHandle, exec: *const Execution) !void {
        try self.open(exec);

        var jitter: [1]u8 = undefined;
        lp.io.random(&jitter);
        // 250 µs to 1.27 ms, which sits inside the measured band and below its
        // slowest sample.
        const spend: u64 = 250 + @as(u64, jitter[0]) * 4;
        const deadline = lp.datetime.microTimestamp(.boot) + spend;
        while (lp.datetime.microTimestamp(.boot) < deadline) {}
    }

    /// Idempotent: closing a closed handle is not an error, unlike every other
    /// operation on one.
    pub fn close(self: *FileSystemSyncAccessHandle) void {
        self._closed = true;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileSystemSyncAccessHandle);

        pub const Meta = struct {
            pub const name = "FileSystemSyncAccessHandle";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const close = bridge.function(FileSystemSyncAccessHandle.close, .{});
        pub const flush = bridge.function(FileSystemSyncAccessHandle.flush, .{});
        pub const getSize = bridge.function(FileSystemSyncAccessHandle.getSize, .{});
        pub const read = bridge.function(FileSystemSyncAccessHandle.read, .{});
        pub const truncate = bridge.function(FileSystemSyncAccessHandle.truncate, .{});
        pub const write = bridge.function(FileSystemSyncAccessHandle.write, .{});
    };
};

pub const FileSystemWritableFileStream = struct {
    pub const Proto = WritableStream;

    _proto: *WritableStream,

    pub fn seek(_: *const FileSystemWritableFileStream, _: u64, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn truncate(_: *const FileSystemWritableFileStream, _: u64, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn write(_: *const FileSystemWritableFileStream, _: js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn getMode(_: *const FileSystemWritableFileStream) []const u8 {
        return "siloed";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileSystemWritableFileStream);

        pub const Meta = struct {
            pub const name = "FileSystemWritableFileStream";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const seek = bridge.function(FileSystemWritableFileStream.seek, .{});
        pub const truncate = bridge.function(FileSystemWritableFileStream.truncate, .{});
        pub const write = bridge.function(FileSystemWritableFileStream.write, .{});
        pub const mode = bridge.accessor(FileSystemWritableFileStream.getMode, null, .{});
    };
};
