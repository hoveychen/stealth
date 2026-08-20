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

//! The File System Access API's four interfaces.
//!
//! Every door into them is shut: the three window pickers all reject with
//! `SecurityError: Failed to execute 'show*Picker' on 'Window': Must be
//! handling a user gesture to show a file picker.` (measured on a headed
//! Chrome 150), and this engine has no `navigator.storage.getDirectory()` and
//! no `DataTransferItem.getAsFileSystemHandle()`, the other two ways a page
//! could get a handle. So, as with CSSAnimation, no instance is ever created
//! and what a detector reads is the globals plus their prototypes.

const js = @import("../js/js.zig");

const File = @import("File.zig");
const WritableStream = @import("streams/WritableStream.zig");

const Execution = js.Execution;

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

pub const FileSystemHandle = struct {
    _kind: []const u8 = "file",
    _name: []const u8 = "",

    pub fn getKind(self: *const FileSystemHandle) []const u8 {
        return self._kind;
    }

    pub fn getName(self: *const FileSystemHandle) []const u8 {
        return self._name;
    }

    pub fn isSameEntry(_: *const FileSystemHandle, _: js.Value) bool {
        return false;
    }

    pub fn queryPermission(_: *const FileSystemHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(PERMISSION_STATE);
    }

    pub fn requestPermission(_: *const FileSystemHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(PERMISSION_STATE);
    }

    pub fn remove(_: *const FileSystemHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
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
        pub const isSameEntry = bridge.function(FileSystemHandle.isSameEntry, .{});
        pub const queryPermission = bridge.function(FileSystemHandle.queryPermission, .{});
        pub const remove = bridge.function(FileSystemHandle.remove, .{});
        pub const requestPermission = bridge.function(FileSystemHandle.requestPermission, .{});
    };
};

pub const FileSystemFileHandle = struct {
    pub const Proto = FileSystemHandle;

    _proto: *FileSystemHandle,

    pub fn createWritable(_: *const FileSystemFileHandle, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn getFile(_: *const FileSystemFileHandle, exec: *Execution) !js.Promise {
        const empty = try File.init(null, "", null, exec);
        return exec.js.local.?.resolvePromise(empty);
    }

    pub fn move(_: *const FileSystemFileHandle, _: js.Value, _: ?[]const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileSystemFileHandle);

        pub const Meta = struct {
            pub const name = "FileSystemFileHandle";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const createWritable = bridge.function(FileSystemFileHandle.createWritable, .{});
        pub const getFile = bridge.function(FileSystemFileHandle.getFile, .{});
        pub const move = bridge.function(FileSystemFileHandle.move, .{});
    };
};

pub const FileSystemDirectoryHandle = struct {
    pub const Proto = FileSystemHandle;

    _proto: *FileSystemHandle,

    pub fn getDirectoryHandle(_: *const FileSystemDirectoryHandle, _: []const u8, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn getFileHandle(_: *const FileSystemDirectoryHandle, _: []const u8, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn removeEntry(_: *const FileSystemDirectoryHandle, _: []const u8, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn resolve(_: *const FileSystemDirectoryHandle, _: js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(null);
    }

    // entries/keys/values (and Symbol.asyncIterator, which is entries again)
    // are the async-iterable declaration; with no entries to walk they hand
    // back an iterator over nothing.
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
        pub const resolve = bridge.function(FileSystemDirectoryHandle.resolve, .{});
        pub const entries = bridge.function(FileSystemDirectoryHandle.entries, .{});
        pub const keys = bridge.function(FileSystemDirectoryHandle.entries, .{});
        pub const values = bridge.function(FileSystemDirectoryHandle.entries, .{});
        pub const symbol_async_iterator = bridge.iterator(FileSystemDirectoryHandle.entries, .{ .async = true });
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
