// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! The sandboxed filesystem behind `webkitRequestFileSystem` and
//! `webkitResolveLocalFileSystemURL`.
//!
//! Those two names are the last of G17's webkit-legacy window keys. Unlike the
//! interface objects they read back as *enumerable* own properties of the
//! global -- "ecw" where an interface object is "-cw" (measured) -- and unlike
//! `openDatabase`, which Chrome 150 has dropped, they still work.
//!
//! And "work" is the point. On a headed Chrome 150 the callback really lands,
//! with a `[object DOMFileSystem]` whose `name` is derived from the origin:
//! `http_localhost_8731:Temporary`. That name is itself a fingerprint surface --
//! it hands a page the origin in a shape it can predict -- so an engine that
//! refuses the call, or hands back a filesystem with a made-up name, is
//! answering a question Chrome answers differently.
//!
//! Nothing this API hands out is a global. `DOMFileSystem`, `Entry`,
//! `DirectoryEntry`, `FileEntry`, `DirectoryReader`, `Metadata` and
//! `FileWriter` are all `[LegacyNoInterfaceObject]` on Chrome 150 (measured):
//! branded through Symbol.toStringTag, reachable only through the callbacks,
//! with no constructor on the global and none on the prototype. So they are
//! registered with `no_interface_object`, and the brand strings are not the
//! WebIDL interface names a spec reader would expect -- `DOMFileSystem`, not
//! `FileSystem`; `DirectoryEntry`, not `FileSystemDirectoryEntry`.
//!
//! The tree behind it is real but in-memory and per-origin: entries are created,
//! moved, copied, removed and written for as long as the page lives, and nothing
//! touches the host filesystem. A fresh wrapper object is handed out on every
//! lookup, which is Chrome's behaviour too (measured: two `getFile` calls for
//! one path compare unequal).
//!
//! Measured on a headed Chrome 150 over http://localhost:8731 --
//! win63-chrome.json, win66-chrome.json, win67-chrome.json, plus the FileWriter
//! runs recorded in the batch-20 notes.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Blob = @import("Blob.zig");
const File = @import("File.zig");
const EventTarget = @import("EventTarget.zig");
const Event = @import("Event.zig");
const DOMException = @import("DOMException.zig");
const dictionary = @import("dictionary.zig");
const Mime = @import("../Mime.zig");
const Factory = @import("../Factory.zig");
const Window = @import("Window.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");
const handler_property = @import("handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

/// As `handlerProperty`, for the properties whose setter takes a non-callable
/// and stores null rather than refusing it.
fn handlerPropertyLenient(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.lenientAccessors(T, which);
}

const Execution = js.Execution;
const String = lp.String;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        DOMFileSystem,
        Entry,
        DirectoryEntry,
        FileEntry,
        DirectoryReader,
        Metadata,
        FileWriter,
    };
}

/// Chrome's own words for the four failures this API can produce. They are
/// generic DOMException messages rather than anything filesystem-specific,
/// which is exactly why they are quoted rather than paraphrased.
const messages = struct {
    const not_found = "A requested file or directory could not be found at the time an operation was processed.";
    const invalid_modification = "The object can not be modified in this way.";
    const already_exists = "An attempt was made to create a file or directory where an element already exists.";
    const type_mismatch = "The path supplied exists, but was not an entry of requested type.";
    const security = "It was determined that certain files are unsafe for access within a Web application, " ++
        "or that too many calls are being made on file resources.";
    const encoding = "A URI supplied to the API was malformed, or the resulting Data URL has exceeded " ++
        "the URL length limitations for Data URLs.";
};

// ----------------------------------------------------------------------------
// The in-memory tree
// ----------------------------------------------------------------------------

/// One node of the per-origin tree. Entries handed to a page are throwaway
/// wrappers over these; the tree is what survives.
pub const Node = struct {
    kind: enum { file, directory },
    name: []const u8,
    full_path: []const u8,
    parent: ?*Node,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    contents: []const u8 = "",
    modified_ms: i64 = 0,

    pub fn find(self: *Node, name: []const u8) ?*Node {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }
        return null;
    }

    pub fn detach(self: *Node) void {
        const parent = self.parent orelse return;
        for (parent.children.items, 0..) |child, i| {
            if (child == self) {
                _ = parent.children.orderedRemove(i);
                return;
            }
        }
    }
};

/// Resolves a slash-separated path against a directory. Both `getFile` and
/// `getDirectory` take a path, not just a name, so `d/inner.txt` has to walk.
const Walk = struct {
    parent: *Node,
    name: []const u8,
};

fn walk(base: *Node, path: []const u8) ?Walk {
    var current = base;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var pending: ?[]const u8 = null;

    while (it.next()) |segment| {
        if (pending) |name| {
            const next = current.find(name) orelse return null;
            if (next.kind != .directory) return null;
            current = next;
        }
        pending = segment;
    }

    return .{ .parent = current, .name = pending orelse "" };
}

/// The five tree operations, named so that the origin private file system in
/// `file_system_access.zig` can share the tree rather than grow one of its own.
/// It reaches these and `Node.find` / `Node.detach`; nothing else here.
pub const NodeKind = @FieldType(Node, "kind");

/// An empty tree: the root of one sandboxed filesystem.
pub fn createRoot(allocator: Allocator) !*Node {
    const root = try allocator.create(Node);
    root.* = .{ .kind = .directory, .name = "", .full_path = "/", .parent = null };
    return root;
}

/// Creates `name` under `parent` and links it in. The caller has already
/// checked that no entry by that name is there.
pub fn createNode(allocator: Allocator, parent: *Node, kind: NodeKind, name: []const u8) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .kind = kind,
        .name = try allocator.dupe(u8, name),
        .full_path = try joinPath(allocator, parent.full_path, name),
        .parent = parent,
    };
    try parent.children.append(allocator, node);
    return node;
}

/// Writes `payload` at `at`, zero-filling any gap it leaves behind the old end.
pub fn writeAt(allocator: Allocator, node: *Node, at: usize, payload: []const u8) !void {
    const existing = node.contents;
    const end = at + payload.len;
    const buffer = try allocator.alloc(u8, @max(existing.len, end));
    @memcpy(buffer[0..existing.len], existing);
    if (end > existing.len) {
        @memset(buffer[existing.len..end], 0);
    }
    @memcpy(buffer[at..end], payload);
    node.contents = buffer;
}

/// Shrinks or zero-extends `node` to `length`.
pub fn truncateTo(allocator: Allocator, node: *Node, length: usize) !void {
    const existing = node.contents;
    if (length <= existing.len) {
        node.contents = existing[0..length];
        return;
    }
    const buffer = try allocator.alloc(u8, length);
    @memcpy(buffer[0..existing.len], existing);
    @memset(buffer[existing.len..], 0);
    node.contents = buffer;
}

// ----------------------------------------------------------------------------
// DOMFileSystem
// ----------------------------------------------------------------------------

pub const Kind = enum {
    temporary,
    persistent,

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .temporary => "Temporary",
            .persistent => "Persistent",
        };
    }

    fn urlSegment(self: Kind) []const u8 {
        return switch (self) {
            .temporary => "temporary",
            .persistent => "persistent",
        };
    }
};

pub const DOMFileSystem = struct {
    _name: []const u8,
    _kind: Kind,
    _origin: []const u8,
    _root: *Node,

    pub fn getName(self: *const DOMFileSystem) []const u8 {
        return self._name;
    }

    pub fn getRoot(self: *DOMFileSystem, exec: *const Execution) !*DirectoryEntry {
        return DirectoryEntry.wrap(self, self._root, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DOMFileSystem);

        pub const Meta = struct {
            pub const name = "DOMFileSystem";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const name = bridge.accessor(DOMFileSystem.getName, null, .{});
        pub const root = bridge.accessor(DOMFileSystem.getRoot, null, .{});
    };
};

/// Chrome's name for a sandboxed filesystem: the origin with every `:`, `/` and
/// `.` collapsed to `_`, then the quota type. Measured over
/// http://localhost:8731 as `http_localhost_8731:Temporary`.
fn filesystemName(allocator: Allocator, origin: []const u8, kind: Kind) ![]const u8 {
    const collapsed = try allocator.alloc(u8, origin.len);
    for (origin, collapsed) |c, *out| {
        out.* = switch (c) {
            ':', '/', '.' => '_',
            else => c,
        };
    }
    // Consecutive punctuation collapses to a single underscore: "http://" is
    // three characters of punctuation and reads back as one.
    var squashed = try std.ArrayListUnmanaged(u8).initCapacity(allocator, origin.len);
    var previous_underscore = false;
    for (collapsed) |c| {
        if (c == '_') {
            if (previous_underscore) continue;
            previous_underscore = true;
        } else {
            previous_underscore = false;
        }
        squashed.appendAssumeCapacity(c);
    }

    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ squashed.items, kind.label() });
}

// ----------------------------------------------------------------------------
// Entry and its two subclasses
// ----------------------------------------------------------------------------

pub const Entry = struct {
    _type: Type,
    _filesystem: *DOMFileSystem,
    _node: *Node,

    pub const Type = union(enum) {
        directory_entry: *DirectoryEntry,
        file_entry: *FileEntry,
    };

    pub fn getIsFile(self: *const Entry) bool {
        return self._node.kind == .file;
    }

    pub fn getIsDirectory(self: *const Entry) bool {
        return self._node.kind == .directory;
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._node.name;
    }

    pub fn getFullPath(self: *const Entry) []const u8 {
        return self._node.full_path;
    }

    pub fn getFilesystem(self: *const Entry) *DOMFileSystem {
        return self._filesystem;
    }

    pub fn toURL(self: *const Entry, exec: *const Execution) ![]const u8 {
        const fs = self._filesystem;
        const path = self._node.full_path;
        return std.fmt.allocPrint(exec._factory._arena, "filesystem:{s}/{s}{s}", .{
            fs._origin,
            fs._kind.urlSegment(),
            if (path.len > 1) path else "/",
        });
    }

    pub fn getMetadata(self: *Entry, success_: ?js.Function, _: ?js.Function, exec: *Execution) !void {
        const success = success_ orelse return missing("getMetadata", "Entry", exec);
        const metadata = try exec._factory.create(Metadata{
            ._modification_time_ms = self._node.modified_ms,
            ._size = self._node.contents.len,
        });
        return callLater(exec, success, metadata);
    }

    pub fn getParent(self: *Entry, success_: ?js.Function, _: ?js.Function, exec: *Execution) !void {
        // Both callbacks are optional here and only here (measured:
        // `root.getParent()` is undefined rather than a TypeError).
        const success = success_ orelse return;
        const node = self._node.parent orelse self._node;
        const entry = try DirectoryEntry.wrap(self._filesystem, node, exec);
        return callLater(exec, success, entry);
    }

    pub fn remove(self: *Entry, success_: ?js.Function, failure: ?js.Function, exec: *Execution) !void {
        const success = success_ orelse return missing("remove", "Entry", exec);
        const node = self._node;
        if (node.parent == null) {
            return failLater(exec, failure, "InvalidModificationError", messages.invalid_modification);
        }
        if (node.kind == .directory and node.children.items.len > 0) {
            return failLater(exec, failure, "InvalidModificationError", messages.invalid_modification);
        }
        node.detach();
        return callLater(exec, success, {});
    }

    pub fn moveTo(
        self: *Entry,
        parent_: ?*DirectoryEntry,
        new_name: ?String.Global,
        success: ?js.Function,
        failure: ?js.Function,
        exec: *Execution,
    ) !void {
        return self.transfer(parent_, new_name, success, failure, true, "moveTo", exec);
    }

    pub fn copyTo(
        self: *Entry,
        parent_: ?*DirectoryEntry,
        new_name: ?String.Global,
        success: ?js.Function,
        failure: ?js.Function,
        exec: *Execution,
    ) !void {
        return self.transfer(parent_, new_name, success, failure, false, "copyTo", exec);
    }

    fn transfer(
        self: *Entry,
        parent_: ?*DirectoryEntry,
        new_name: ?String.Global,
        success: ?js.Function,
        failure: ?js.Function,
        move: bool,
        comptime operation: []const u8,
        exec: *Execution,
    ) !void {
        const destination = parent_ orelse return missing(operation, "Entry", exec);
        const node = self._node;
        if (node.parent == null) {
            return failLater(exec, failure, "InvalidModificationError", messages.invalid_modification);
        }

        const name = if (new_name) |n| n.str.str() else node.name;
        const target = destination.asEntry()._node;
        if (target.find(name)) |_| {
            return failLater(exec, failure, "InvalidModificationError", messages.already_exists);
        }

        const arena = exec._factory._arena;
        const moved = if (move) node else try clone(arena, node);
        if (move) node.detach();

        moved.name = try arena.dupe(u8, name);
        moved.parent = target;
        moved.full_path = try joinPath(arena, target.full_path, moved.name);
        try target.children.append(arena, moved);

        const entry = try wrapNode(self._filesystem, moved, exec);
        return callLater(exec, success, entry);
    }

    fn clone(arena: Allocator, node: *Node) !*Node {
        const copy = try arena.create(Node);
        copy.* = .{
            .kind = node.kind,
            .name = node.name,
            .full_path = node.full_path,
            .parent = null,
            .contents = node.contents,
            .modified_ms = node.modified_ms,
        };
        for (node.children.items) |child| {
            const child_copy = try clone(arena, child);
            child_copy.parent = copy;
            try copy.children.append(arena, child_copy);
        }
        return copy;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "Entry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const isFile = bridge.accessor(Entry.getIsFile, null, .{});
        pub const isDirectory = bridge.accessor(Entry.getIsDirectory, null, .{});
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const fullPath = bridge.accessor(Entry.getFullPath, null, .{});
        pub const filesystem = bridge.accessor(Entry.getFilesystem, null, .{});
        pub const copyTo = bridge.function(Entry.copyTo, .{ .arity = 1 });
        pub const getMetadata = bridge.function(Entry.getMetadata, .{ .arity = 1 });
        pub const getParent = bridge.function(Entry.getParent, .{ .arity = 0 });
        pub const moveTo = bridge.function(Entry.moveTo, .{ .arity = 1 });
        pub const remove = bridge.function(Entry.remove, .{ .arity = 1 });
        pub const toURL = bridge.function(Entry.toURL, .{ .arity = 0 });
    };
};

fn joinPath(arena: Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, parent, "/")) {
        return std.fmt.allocPrint(arena, "/{s}", .{name});
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, name });
}

fn wrapNode(fs: *DOMFileSystem, node: *Node, exec: *const Execution) !*Entry {
    return switch (node.kind) {
        .directory => (try DirectoryEntry.wrap(fs, node, exec)).asEntry(),
        .file => (try FileEntry.wrap(fs, node, exec)).asEntry(),
    };
}

pub const DirectoryEntry = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn wrap(fs: *DOMFileSystem, node: *Node, exec: *const Execution) !*DirectoryEntry {
        const entry = try exec._factory.chained(.{
            Entry{ ._type = undefined, ._filesystem = fs, ._node = node },
            DirectoryEntry{ ._proto = undefined },
        });
        entry._proto._type = .{ .directory_entry = entry };
        return entry;
    }

    pub fn asEntry(self: *DirectoryEntry) *Entry {
        return self._proto;
    }

    pub fn createReader(self: *DirectoryEntry, exec: *const Execution) !*DirectoryReader {
        return exec._factory.create(DirectoryReader{
            ._filesystem = self._proto._filesystem,
            ._node = self._proto._node,
        });
    }

    pub fn getFile(
        self: *DirectoryEntry,
        path_: ?String.Global,
        options: ?js.Value,
        success: ?js.Function,
        failure: ?js.Function,
        exec: *Execution,
    ) !void {
        return self.lookup(.file, path_, options, success, failure, "getFile", exec);
    }

    pub fn getDirectory(
        self: *DirectoryEntry,
        path_: ?String.Global,
        options: ?js.Value,
        success: ?js.Function,
        failure: ?js.Function,
        exec: *Execution,
    ) !void {
        return self.lookup(.directory, path_, options, success, failure, "getDirectory", exec);
    }

    fn lookup(
        self: *DirectoryEntry,
        kind: @FieldType(Node, "kind"),
        path_: ?String.Global,
        options: ?js.Value,
        success: ?js.Function,
        failure: ?js.Function,
        comptime operation: []const u8,
        exec: *Execution,
    ) !void {
        const path_value = path_ orelse return missing(operation, "DirectoryEntry", exec);
        const path = path_value.str.str();

        const Options = dictionary.MethodReader("DirectoryEntry", operation, "FileSystemFlags");
        const flags = try Options.read(options, exec);
        const create = try flags.boolean("create", false);
        const exclusive = try flags.boolean("exclusive", false);

        const base = self._proto._node;
        // The root is reachable by its own path, and it is the one lookup that
        // resolves to a node with no parent.
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            if (kind != .directory) {
                return failLater(exec, failure, "TypeMismatchError", messages.type_mismatch);
            }
            const entry = try DirectoryEntry.wrap(self._proto._filesystem, base, exec);
            return callLater(exec, success, entry);
        }

        const target = walk(base, path) orelse {
            return failLater(exec, failure, "NotFoundError", messages.not_found);
        };

        if (target.parent.find(target.name)) |existing| {
            if (existing.kind != kind) {
                return failLater(exec, failure, "TypeMismatchError", messages.type_mismatch);
            }
            if (create and exclusive) {
                return failLater(exec, failure, "InvalidModificationError", messages.already_exists);
            }
            const entry = try wrapNode(self._proto._filesystem, existing, exec);
            return callLater(exec, success, entry);
        }

        if (create == false) {
            return failLater(exec, failure, "NotFoundError", messages.not_found);
        }

        const node = try createNode(exec._factory._arena, target.parent, kind, target.name);
        const entry = try wrapNode(self._proto._filesystem, node, exec);
        return callLater(exec, success, entry);
    }

    pub fn removeRecursively(self: *DirectoryEntry, success_: ?js.Function, failure: ?js.Function, exec: *Execution) !void {
        const success = success_ orelse return missing("removeRecursively", "DirectoryEntry", exec);
        const node = self._proto._node;
        if (node.parent == null) {
            return failLater(exec, failure, "InvalidModificationError", messages.invalid_modification);
        }
        node.detach();
        return callLater(exec, success, {});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DirectoryEntry);

        pub const Meta = struct {
            pub const name = "DirectoryEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const Prototype = Entry;

        pub const createReader = bridge.function(DirectoryEntry.createReader, .{ .arity = 0 });
        pub const getDirectory = bridge.function(DirectoryEntry.getDirectory, .{ .arity = 1 });
        pub const getFile = bridge.function(DirectoryEntry.getFile, .{ .arity = 1 });
        pub const removeRecursively = bridge.function(DirectoryEntry.removeRecursively, .{ .arity = 1 });
    };
};

pub const FileEntry = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn wrap(fs: *DOMFileSystem, node: *Node, exec: *const Execution) !*FileEntry {
        const entry = try exec._factory.chained(.{
            Entry{ ._type = undefined, ._filesystem = fs, ._node = node },
            FileEntry{ ._proto = undefined },
        });
        entry._proto._type = .{ .file_entry = entry };
        return entry;
    }

    pub fn asEntry(self: *FileEntry) *Entry {
        return self._proto;
    }

    pub fn createWriter(self: *FileEntry, success_: ?js.Function, _: ?js.Function, exec: *Execution) !void {
        const success = success_ orelse return missing("createWriter", "FileEntry", exec);
        const writer = try FileWriter.init(self._proto._node, exec);
        return callLater(exec, success, writer);
    }

    /// The File handed back carries the type Chrome infers from the extension
    /// (measured: a `.txt` entry reads back `text/plain`, not `""`).
    pub fn file(self: *FileEntry, success_: ?js.Function, _: ?js.Function, exec: *Execution) !void {
        const success = success_ orelse return missing("file", "FileEntry", exec);
        const node = self._proto._node;
        const arena = try exec.getArena(node.contents.len + node.name.len + 256, "FileEntry.file");
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
        return callLater(exec, success, handle);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileEntry);

        pub const Meta = struct {
            pub const name = "FileEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const Prototype = Entry;

        pub const createWriter = bridge.function(FileEntry.createWriter, .{ .arity = 1 });
        pub const file = bridge.function(FileEntry.file, .{ .arity = 1 });
    };
};

// ----------------------------------------------------------------------------
// DirectoryReader / Metadata
// ----------------------------------------------------------------------------

pub const DirectoryReader = struct {
    _filesystem: *DOMFileSystem,
    _node: *Node,
    _drained: bool = false,

    /// The spec's protocol is "read until it answers empty", so a second call
    /// answers empty even when the directory is not.
    pub fn readEntries(self: *DirectoryReader, success_: ?js.Function, _: ?js.Function, exec: *Execution) !void {
        const success = success_ orelse return missing("readEntries", "DirectoryReader", exec);
        if (self._drained) {
            const empty: []const *Entry = &.{};
            return callLater(exec, success, empty);
        }
        self._drained = true;

        const children = self._node.children.items;
        const entries = try exec._factory._arena.alloc(*Entry, children.len);
        for (children, entries) |child, *slot| {
            slot.* = try wrapNode(self._filesystem, child, exec);
        }
        return callLater(exec, success, entries);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DirectoryReader);

        pub const Meta = struct {
            pub const name = "DirectoryReader";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const readEntries = bridge.function(DirectoryReader.readEntries, .{ .arity = 1 });
    };
};

/// A snapshot, not a live view: the values are read when getMetadata() is
/// called, so a later write does not change a Metadata a page is still holding.
pub const Metadata = struct {
    _modification_time_ms: i64,
    _size: u64,

    /// Chrome hands back a Date, not a number (measured:
    /// `m.modificationTime instanceof Date`).
    pub fn getModificationTime(self: *const Metadata, exec: *const Execution) !js.Value {
        return exec.js.local.?.newDate(@floatFromInt(self._modification_time_ms));
    }

    pub fn getSize(self: *const Metadata) u64 {
        return self._size;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Metadata);

        pub const Meta = struct {
            pub const name = "Metadata";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const modificationTime = bridge.accessor(Metadata.getModificationTime, null, .{});
        pub const size = bridge.accessor(Metadata.getSize, null, .{});
    };
};

// ----------------------------------------------------------------------------
// FileWriter
// ----------------------------------------------------------------------------

/// Writing is asynchronous and observable: `readyState` flips to WRITING in the
/// same task as the call, then a task later Chrome fires writestart, *two*
/// progress events, write and writeend -- measured, including the doubled
/// progress -- with position and length already at their final values from the
/// first progress on.
pub const FileWriter = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _node: *Node,
    _position: u64 = 0,
    _ready_state: u16 = 0,

    const INIT: u16 = 0;
    const WRITING: u16 = 1;
    const DONE: u16 = 2;

    fn init(node: *Node, exec: *const Execution) !*FileWriter {
        return exec._factory.eventTarget(FileWriter{ ._proto = undefined, ._node = node });
    }

    pub fn asEventTarget(self: *FileWriter) *EventTarget {
        return self._proto;
    }

    pub fn getReadyState(self: *const FileWriter) u16 {
        return self._ready_state;
    }

    pub fn getError(_: *const FileWriter) ?*DOMException {
        return null;
    }

    pub fn getPosition(self: *const FileWriter) u64 {
        return self._position;
    }

    pub fn getLength(self: *const FileWriter) u64 {
        return self._node.contents.len;
    }

    /// The argument is read as a union rather than as `?*Blob` so the refusal
    /// is Chrome's wording rather than the bridge's generic "invalid argument".
    const Data = union(enum) {
        blob: *Blob,
        anything: js.Value,
    };

    pub fn write(self: *FileWriter, data_: ?Data, exec: *Execution) !void {
        const data = data_ orelse return notABlob(exec);
        const blob = switch (data) {
            .blob => |b| b,
            .anything => return notABlob(exec),
        };
        self._ready_state = WRITING;
        return self.settle(exec, .{ .write = blob._slice });
    }

    fn notABlob(exec: *const Execution) anyerror {
        return dictionary.throwTypeError(
            "Failed to execute 'write' on 'FileWriter': parameter 1 is not of type 'Blob'.",
            exec,
        );
    }

    pub fn truncate(self: *FileWriter, size: u64, exec: *Execution) !void {
        self._ready_state = WRITING;
        return self.settle(exec, .{ .truncate = size });
    }

    /// What a scheduled write is going to do once `writestart` has been
    /// delivered. Chrome reports position and length unchanged at `writestart`
    /// and already final at the first `progress` (measured), so the bytes move
    /// between those two events rather than in the call itself.
    const Pending = union(enum) {
        write: []const u8,
        truncate: u64,
    };

    fn apply(self: *FileWriter, pending: Pending, exec: *Execution) !void {
        const arena = exec._factory._arena;

        switch (pending) {
            .write => |payload| {
                const start: usize = @intCast(self._position);
                try writeAt(arena, self._node, start, payload);
                self._position = start + payload.len;
            },
            .truncate => |size| {
                const length: usize = @intCast(size);
                try truncateTo(arena, self._node, length);
                self._position = @min(self._position, length);
            },
        }
    }

    /// A negative offset counts from the end (measured: `seek(-1)` on a
    /// two-byte file leaves position at 1).
    pub fn seek(self: *FileWriter, offset: i64) void {
        const length: i64 = @intCast(self._node.contents.len);
        const resolved = if (offset < 0) @max(0, length + offset) else @min(offset, length);
        self._position = @intCast(resolved);
    }

    pub fn abort(self: *FileWriter) void {
        self._ready_state = DONE;
    }

    fn settle(self: *FileWriter, exec: *Execution, pending: Pending) !void {
        const task = try exec._factory.create(WriteTask{
            .writer = self,
            .pending = pending,
            .exec = exec,
        });
        try exec.js.scheduler.add(task, WriteTask.run, 0, .{
            .name = "FileWriter.write",
            .finalizer = WriteTask.cancelled,
        });
    }

    const WriteTask = struct {
        writer: *FileWriter,
        pending: Pending,
        exec: *Execution,

        fn cancelled(ctx: *anyopaque) void {
            const self: *WriteTask = @ptrCast(@alignCast(ctx));
            self.exec._factory.destroy(self);
        }

        fn run(ctx: *anyopaque) !?u32 {
            const self: *WriteTask = @ptrCast(@alignCast(ctx));
            defer self.exec._factory.destroy(self);

            const writer = self.writer;
            try writer.fire(self.exec, comptime String.wrap("writestart"), null);
            try writer.apply(self.pending, self.exec);
            // Chrome fires progress twice for one write, both already carrying
            // the final position (measured).
            try writer.fire(self.exec, comptime String.wrap("progress"), null);
            try writer.fire(self.exec, comptime String.wrap("progress"), null);
            writer._ready_state = DONE;
            try writer.fire(self.exec, comptime String.wrap("write"), null);
            try writer.fire(self.exec, comptime String.wrap("writeend"), null);
            return null;
        }
    };

    fn fire(self: *FileWriter, exec: *Execution, typ: String, handler: ?js.Function.Global) !void {
        const event = try Event.initTrusted(typ, .{}, exec.page);
        return exec.dispatch(self.asEventTarget(), event, handler, .{ .context = "FileWriter" });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FileWriter);

        pub const Meta = struct {
            pub const name = "FileWriter";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const no_interface_object = {};
        };

        pub const readyState = bridge.accessor(FileWriter.getReadyState, null, .{});
        pub const @"error" = bridge.accessor(FileWriter.getError, null, .{ .null_as_undefined = false });
        pub const position = bridge.accessor(FileWriter.getPosition, null, .{});
        pub const length = bridge.accessor(FileWriter.getLength, null, .{});
        pub const onwritestart = bridge.accessor(handlerPropertyLenient(FileWriter, .onwritestart).get, handlerPropertyLenient(FileWriter, .onwritestart).set, .{});
        pub const onprogress = bridge.accessor(handlerPropertyLenient(FileWriter, .onprogress).get, handlerPropertyLenient(FileWriter, .onprogress).set, .{});
        pub const onwrite = bridge.accessor(handlerPropertyLenient(FileWriter, .onwrite).get, handlerPropertyLenient(FileWriter, .onwrite).set, .{});
        pub const onabort = bridge.accessor(handlerPropertyLenient(FileWriter, .onabort).get, handlerPropertyLenient(FileWriter, .onabort).set, .{});
        pub const onerror = bridge.accessor(handlerPropertyLenient(FileWriter, .onerror).get, handlerPropertyLenient(FileWriter, .onerror).set, .{});
        pub const onwriteend = bridge.accessor(handlerPropertyLenient(FileWriter, .onwriteend).get, handlerPropertyLenient(FileWriter, .onwriteend).set, .{});
        pub const INIT = bridge.property(0, .{ .template = true });
        pub const WRITING = bridge.property(1, .{ .template = true });
        pub const DONE = bridge.property(2, .{ .template = true });
        pub const abort = bridge.function(FileWriter.abort, .{ .arity = 0 });
        pub const seek = bridge.function(FileWriter.seek, .{ .arity = 1 });
        pub const truncate = bridge.function(FileWriter.truncate, .{ .arity = 1 });
        pub const write = bridge.function(FileWriter.write, .{ .arity = 1 });
    };
};

// ----------------------------------------------------------------------------
// The two window entry points
// ----------------------------------------------------------------------------

fn missing(comptime operation: []const u8, comptime interface: []const u8, exec: *const Execution) anyerror {
    return dictionary.throwTypeError(
        "Failed to execute '" ++ operation ++ "' on '" ++ interface ++
            "': 1 argument required, but only 0 present.",
        exec,
    );
}

/// Every one of these operations answers on a task rather than synchronously,
/// which is what Chrome does and what a page's control flow assumes.
fn callLater(exec: *Execution, callback_: ?js.Function, argument: anytype) !void {
    // The success callback is optional on the operations that take a path
    // (measured: `root.getFile('x')` with no callback is undefined, not a
    // TypeError), so "no callback" means "do the work and say nothing".
    const callback = callback_ orelse return;
    const persisted = try callback.persist();
    const task = try exec._factory.create(CallbackTask(@TypeOf(argument)){
        .callback = persisted,
        .argument = argument,
        .exec = exec,
    });
    try exec.js.scheduler.add(task, CallbackTask(@TypeOf(argument)).run, 0, .{
        .name = "filesystem.callback",
        .finalizer = CallbackTask(@TypeOf(argument)).cancelled,
    });
}

fn CallbackTask(comptime T: type) type {
    return struct {
        callback: js.Function.Global,
        argument: T,
        exec: *Execution,

        const Self = @This();

        fn cancelled(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.exec._factory.destroy(self);
        }

        fn run(ctx: *anyopaque) !?u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.exec._factory.destroy(self);

            // A scheduler task runs outside any JS call, so it opens its own
            // handle scope before it can turn the persisted callback back into
            // something callable -- the same shape Timers.zig uses.
            var scope: js.Local.Scope = undefined;
            self.exec.js.localScope(&scope);
            defer scope.deinit();

            const callback = scope.toLocal(self.callback);
            if (T == void) {
                callback.call(void, .{}) catch |err| {
                    self.exec.page.recordJsError(err);
                };
            } else {
                callback.call(void, .{self.argument}) catch |err| {
                    self.exec.page.recordJsError(err);
                };
            }
            return null;
        }
    };
}

fn failLater(exec: *Execution, failure: ?js.Function, comptime name: []const u8, message: []const u8) !void {
    const callback = failure orelse return;
    const exception = try exec._factory.create(DOMException.init(message, name));
    return callLater(exec, callback, exception);
}

/// window.webkitRequestFileSystem. Arity 3: the error callback is the only
/// optional argument. Chrome reports 2 for the same operation on a worker
/// global (measured) -- its own inconsistency, mirrored where it is registered.
pub fn requestFileSystem(
    _: *Window,
    kind_: ?u32,
    size: ?f64,
    success_: ?js.Function,
    failure: ?js.Function,
    exec: *Execution,
) !void {
    return request("Window", 3, kind_, size, success_, failure, exec);
}

/// The same operation on a dedicated worker global -- own on the global there,
/// not on WorkerGlobalScope.prototype, which is why the self type is the
/// [Global] interface. Chrome's blob worker carries both of these as own
/// enumerable functions and names none of the entry interfaces, the same shape
/// its Window has (measured).
pub fn workerRequestFileSystem(
    _: *DedicatedWorkerGlobalScope,
    kind_: ?u32,
    size: ?f64,
    success_: ?js.Function,
    failure: ?js.Function,
    exec: *Execution,
) !void {
    return request("WorkerGlobalScope", 2, kind_, size, success_, failure, exec);
}

fn request(
    comptime iface: []const u8,
    comptime arity: usize,
    kind_: ?u32,
    _: ?f64,
    success_: ?js.Function,
    failure: ?js.Function,
    exec: *Execution,
) !void {
    const kind_value = kind_ orelse return missingArgs(iface, "webkitRequestFileSystem", arity, 0, exec);
    const success = success_ orelse return missingArgs(iface, "webkitRequestFileSystem", arity, 2, exec);

    const kind: Kind = switch (kind_value) {
        0 => .temporary,
        1 => .persistent,
        else => return failLater(exec, failure, "InvalidModificationError", messages.invalid_modification),
    };

    const filesystem = try forKind(kind, exec);
    return callLater(exec, success, filesystem);
}

/// window.webkitResolveLocalFileSystemURL. Arity 2.
pub fn resolveLocalFileSystemURL(
    _: *Window,
    url_: ?String.Global,
    success_: ?js.Function,
    failure: ?js.Function,
    exec: *Execution,
) !void {
    return resolveURL("Window", url_, success_, failure, exec);
}

pub fn workerResolveLocalFileSystemURL(
    _: *DedicatedWorkerGlobalScope,
    url_: ?String.Global,
    success_: ?js.Function,
    failure: ?js.Function,
    exec: *Execution,
) !void {
    return resolveURL("WorkerGlobalScope", url_, success_, failure, exec);
}

fn resolveURL(
    comptime iface: []const u8,
    url_: ?String.Global,
    success_: ?js.Function,
    failure: ?js.Function,
    exec: *Execution,
) !void {
    const url_value = url_ orelse return missingArgs(iface, "webkitResolveLocalFileSystemURL", 2, 0, exec);
    const success = success_ orelse return missingArgs(iface, "webkitResolveLocalFileSystemURL", 2, 1, exec);

    const url = url_value.str.str();
    const prefix = "filesystem:";
    if (std.mem.startsWith(u8, url, prefix) == false) {
        return failLater(exec, failure, "EncodingError", messages.encoding);
    }

    const origin = originFor(exec);
    const rest = url[prefix.len..];
    if (std.mem.startsWith(u8, rest, origin) == false) {
        return failLater(exec, failure, "SecurityError", messages.security);
    }

    var tail = rest[origin.len..];
    if (std.mem.startsWith(u8, tail, "/")) tail = tail[1..];

    const kind: Kind = if (std.mem.startsWith(u8, tail, "temporary"))
        .temporary
    else if (std.mem.startsWith(u8, tail, "persistent"))
        .persistent
    else
        return failLater(exec, failure, "EncodingError", messages.encoding);

    const path = tail[kind.urlSegment().len..];
    const filesystem = try forKind(kind, exec);

    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
        const entry = try DirectoryEntry.wrap(filesystem, filesystem._root, exec);
        return callLater(exec, success, entry);
    }

    const target = walk(filesystem._root, path) orelse {
        return failLater(exec, failure, "NotFoundError", messages.not_found);
    };
    const node = target.parent.find(target.name) orelse {
        return failLater(exec, failure, "NotFoundError", messages.not_found);
    };

    const entry = try wrapNode(filesystem, node, exec);
    return callLater(exec, success, entry);
}

// Chrome names the interface the operation is on, the way `missing` above does.
// Only the Window wording is measured; the worker one follows that pattern
// rather than a reading.
fn missingArgs(
    comptime iface: []const u8,
    comptime operation: []const u8,
    comptime required: usize,
    comptime got: usize,
    exec: *const Execution,
) anyerror {
    return dictionary.throwTypeError(std.fmt.comptimePrint(
        "Failed to execute '{s}' on '{s}': {d} arguments required, but only {d} present.",
        .{ operation, iface, required, got },
    ), exec);
}

/// The two slots this realm keeps its filesystems in. A worker gets its own
/// pair rather than the owner window's: the objects are branded in the realm
/// that asked for them, so handing back the window's would be a cross-realm
/// object -- and the realm is also what the name below is derived from.
fn slotsFor(exec: *Execution) *[2]?*DOMFileSystem {
    return switch (exec.js.global) {
        .frame => |frame| &frame.window._filesystems,
        .worker => |worker| &worker._filesystems,
    };
}

fn originFor(exec: *const Execution) []const u8 {
    return switch (exec.js.global) {
        .frame => |frame| frame.origin,
        .worker => |worker| worker.origin,
    } orelse "null";
}

/// The two filesystems are per-origin and live as long as the realm: a second
/// request hands back the same object (measured, `===` holds).
fn forKind(kind: Kind, exec: *Execution) !*DOMFileSystem {
    const slot = &slotsFor(exec)[@intFromEnum(kind)];
    if (slot.*) |existing| {
        return existing;
    }

    const arena = exec._factory._arena;
    const root = try createRoot(arena);

    const origin = originFor(exec);
    const filesystem = try exec._factory.create(DOMFileSystem{
        ._name = try filesystemName(arena, origin, kind),
        ._kind = kind,
        ._origin = try arena.dupe(u8, origin),
        ._root = root,
    });
    slot.* = filesystem;
    return filesystem;
}

const testing = @import("../../testing.zig");
test "WebApi: filesystem" {
    try testing.htmlRunner("filesystem.html", .{});
}
