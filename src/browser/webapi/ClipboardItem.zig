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

// One clipboard entry: a `record<DOMString, ClipboardItemData>` a page builds to
// hand to navigator.clipboard.write(). It does real work without any clipboard
// access, which is why it behaves here rather than just existing.
//
// Measured on a headed Chrome 150 (probe-win28/29/36):
//
//   * `types` keeps the dictionary's insertion order and is a fresh array each
//     read. Keys are not lowercased: `{'TEXT/Plain': x}` reports 'TEXT/Plain'.
//   * A value may be a Blob or a string; a string becomes a Blob of that type.
//     `null` is accepted (it stringifies), so the entry still exists.
//   * `getType(t)` resolves with the Blob; a type that is not there rejects with
//     NotFoundError "The type was not found".
//   * `new ClipboardItem({})` -- and `new ClipboardItem([])`, since an array has
//     no own string keys -- is "Empty dictionary argument". A non-object is
//     "Only objects can be converted to record<K,V> types".
//   * The static `supports` accepts exactly text/plain, text/html, image/png,
//     image/svg+xml and anything prefixed "web ". Everything else is false,
//     including 'TEXT/PLAIN' and 'text/plain ' -- no trimming, no case folding.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Blob = @import("Blob.zig");
const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

const ClipboardItem = @This();

const Entry = struct {
    type: []const u8,
    blob: *Blob,
};

_rc: lp.RC = .{},
_arena: *lp.Arena,
_entries: std.ArrayList(Entry),

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

pub fn constructor(items: js.Value, exec: *const Execution) !*ClipboardItem {
    if (!items.isObject()) {
        return throwTypeError(
            "Failed to construct 'ClipboardItem': Only objects can be converted to record<K,V> types",
            exec,
        );
    }

    const object = items.toObject();
    const keys = try object.getOwnPropertyNames();
    if (keys.len() == 0) {
        return throwTypeError("Failed to construct 'ClipboardItem': Empty dictionary argument", exec);
    }

    const arena = try exec.getArena(.small, "ClipboardItem");
    errdefer arena.release();

    const allocator = arena.allocator();
    const self = try arena.create(ClipboardItem);
    self.* = .{ ._arena = arena, ._entries = .empty };

    for (0..keys.len()) |i| {
        const key = try (try keys.get(@intCast(i))).toStringSlice();
        const value = try object.get(key);
        const blob = value.toZig(*Blob) catch blk: {
            // A string (or anything that stringifies) becomes a Blob of the
            // entry's own type.
            const text = try value.toStringSlice();
            break :blk try Blob.initFromBytes(text, key, exec);
        };
        blob.acquireRef();
        try self._entries.append(allocator, .{
            .type = try allocator.dupe(u8, key),
            .blob = blob,
        });
    }
    return self;
}

pub fn deinit(self: *ClipboardItem, page: *Page) void {
    for (self._entries.items) |entry| {
        entry.blob.releaseRef(page);
    }
    // Frees the entry list and this ClipboardItem itself.
    self._arena.release();
}

pub fn releaseRef(self: *ClipboardItem, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *ClipboardItem) void {
    self._rc.acquire();
}

pub fn getTypes(self: *const ClipboardItem, exec: *const Execution) !js.FrozenArray([]const u8) {
    const types = try exec.call_arena.alloc([]const u8, self._entries.items.len);
    for (self._entries.items, types) |entry, *out| {
        out.* = entry.type;
    }
    return .{ .items = types };
}

pub fn getType(self: *ClipboardItem, mime: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    for (self._entries.items) |entry| {
        if (std.mem.eql(u8, entry.type, mime)) {
            resolver.resolve("ClipboardItem.getType", entry.blob);
            return resolver.promise();
        }
    }
    resolver.reject("ClipboardItem.getType", DOMException.init(
        "Failed to execute 'getType' on 'ClipboardItem': The type was not found",
        "NotFoundError",
    ));
    return resolver.promise();
}

/// The mandatory data types, plus the "web " custom-format prefix. Takes its
/// argument as a variadic slice because the bridge only counts arguments for
/// constructors, and Chrome's count message here is measured.
pub fn supports(args: []js.Value, exec: *const Execution) !bool {
    if (args.len == 0) {
        return throwTypeError(
            "Failed to execute 'supports' on 'ClipboardItem': 1 argument required, but only 0 present.",
            exec,
        );
    }
    const mime = try args[0].toZig([]const u8);
    if (std.mem.startsWith(u8, mime, "web ")) {
        return true;
    }
    inline for (.{ "text/plain", "text/html", "image/png", "image/svg+xml" }) |supported| {
        if (std.mem.eql(u8, mime, supported)) {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ClipboardItem);

    pub const Meta = struct {
        pub const name = "ClipboardItem";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ClipboardItem.constructor, .{});
    pub const supports = bridge.function(ClipboardItem.supports, .{ .static = true, .arity = 1 });
    pub const types = bridge.accessor(ClipboardItem.getTypes, null, .{});
    pub const getType = bridge.function(ClipboardItem.getType, .{ .arity = 1 });
};

const testing = @import("../../testing.zig");
test "WebApi: ClipboardItem" {
    try testing.htmlRunner("clipboard_item.html", .{});
}
