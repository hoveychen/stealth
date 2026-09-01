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

//! One collection object per (root, kind, name), for the frame's lifetime.
//!
//! `document.forms === document.forms` is true in a browser. It was false here
//! because every accessor built a fresh wrapper, and the bridge keys JS
//! identity off the Zig pointer, so a fresh wrapper is a fresh JS object. One
//! expression -- needing no knowledge of the page it runs on -- told the two
//! engines apart, and it did so on twenty-two accessors at once.
//!
//! What the key has to be was measured rather than guessed
//! (scratch/b81/identity.mjs, Chrome 151). None of these collapse into one
//! entry there:
//!
//!     getElementsByTagName('div')  vs  ('DIV')          -- name as written
//!     document.getElementsByTagName('div')
//!                                  vs  body.getElementsByTagName('div')  -- root
//!     getElementsByTagName('cc')   vs  getElementsByClassName('cc')      -- kind
//!     document.forms               vs  getElementsByTagName('form')      -- kind
//!     table.rows                   vs  tbody.rows                        -- root
//!
//! and the contents are not part of it: appending a form to the document does
//! not change which object `document.forms` answers. The one pair that must
//! share an entry is `document.plugins` and `document.embeds`, which the HTML
//! spec requires to be the same object.
//!
//! Lifetime: the cache holds a reference, so a cached collection outlives the
//! garbage collection of its JS wrapper and the frame releases the lot at
//! teardown. That is the same shape as the other objects a frame keeps alive
//! for their identity -- `document.fonts`, `window.location`,
//! `document.getSelection()` -- and the reason it is safe to hand the same
//! pointer back later.
//!
//! Keying on a `*Node` is safe for the same reason `Frame._element_class_lists`
//! and the dozen side tables beside it are: nodes are allocated from the
//! frame's factory and nothing destroys one mid-frame, so a key cannot come
//! back pointing at a different node.

const std = @import("std");
const lp = @import("lightpanda");

const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const Node = @import("../Node.zig");

const NodeList = @import("NodeList.zig");
const HTMLCollection = @import("HTMLCollection.zig");
const HTMLAllCollection = @import("HTMLAllCollection.zig");
const HTMLOptionsCollection = @import("HTMLOptionsCollection.zig");
const HTMLFormControlsCollection = @import("HTMLFormControlsCollection.zig");

/// Which accessor asked. Two accessors that walk the same elements are still
/// two entries -- `document.forms` is not `getElementsByTagName('form')` -- so
/// this is the accessor's name, not a description of what it matches. The one
/// exception is `embeds`, which `plugins` shares by spec.
pub const Kind = enum {
    anchors,
    applets,
    children,
    embeds,
    forms,
    images,
    links,
    scripts,
    all,
    area_map,
    data_list_options,
    fieldset_elements,
    form_elements,
    select_options,
    selected_options,
    table_rows,
    table_bodies,
    section_rows,
    row_cells,
    labels,
    by_tag_name,
    by_tag_name_ns,
    by_class_name,
    by_name,
};

pub const Key = struct {
    root: *Node,
    kind: Kind,
    /// The argument as the caller wrote it, or "" for the accessors that take
    /// none. For `by_tag_name_ns` it is the two halves joined by
    /// `namespacedName`, because both of them pick the collection out.
    name: []const u8,
};

const Context = struct {
    pub fn hash(_: Context, key: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&@intFromPtr(key.root)));
        hasher.update(&.{@intFromEnum(key.kind)});
        hasher.update(key.name);
        return hasher.final();
    }

    pub fn eql(_: Context, a: Key, b: Key) bool {
        return a.root == b.root and a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
    }
};

/// The value is a union rather than an opaque pointer so that the release at
/// frame teardown knows which refcount to touch: `HTMLFormControlsCollection`
/// and `HTMLOptionsCollection` share their base's count through a chain
/// offset, and `HTMLAllCollection` has no count at all.
pub const Cached = union(enum) {
    html_collection: *HTMLCollection,
    node_list: *NodeList,
    form_controls: *HTMLFormControlsCollection,
    options: *HTMLOptionsCollection,
    all: *HTMLAllCollection,
};

pub const Lookup = std.HashMapUnmanaged(Key, Cached, Context, std.hash_map.default_max_load_percentage);

fn fieldNameFor(comptime T: type) []const u8 {
    inline for (@typeInfo(Cached).@"union".fields) |field| {
        if (field.type == *T) return field.name;
    }
    @compileError(@typeName(T) ++ " is not a cacheable collection");
}

/// The cached collection for this key, if there is one. Call sites whose
/// construction is more than a couple of stores -- the ones that parse a class
/// list into the arena, or chain two allocations together -- ask this first and
/// skip the building entirely on a hit. The others just call `get`.
pub fn find(frame: *Frame, comptime T: type, key: Key) ?*T {
    const cached = frame._live_collections.getContext(key, .{}) orelse return null;
    return @field(cached, fieldNameFor(T));
}

/// Adopt an already-built collection as the answer for this key. Separate from
/// `get` because `form.elements` and `select.options` are two allocations
/// chained together, which the factory builds in one go and this must not
/// second-guess.
pub fn put(frame: *Frame, key: Key, created: anytype) !@TypeOf(created) {
    const T = @typeInfo(@TypeOf(created)).pointer.child;
    if (comptime @hasDecl(T, "acquireRef")) {
        created.acquireRef();
    }

    // The name comes from the caller's arena, which is per-call, so the key has
    // to own it for as long as the entry does.
    const owned = if (key.name.len == 0) "" else try frame.arena.dupe(u8, key.name);
    try frame._live_collections.putContext(
        frame.arena,
        .{ .root = key.root, .kind = key.kind, .name = owned },
        @unionInit(Cached, fieldNameFor(T), created),
        .{},
    );
    return created;
}

/// The common entry point. `value` is the collection as it would have been
/// built anyway -- for most accessors that is a couple of pointer stores, so
/// building it before the lookup costs nothing worth avoiding and keeps the
/// call sites to one expression each.
pub fn get(frame: *Frame, key: Key, value: anytype) !*@TypeOf(value) {
    if (find(frame, @TypeOf(value), key)) |cached| {
        return cached;
    }
    return put(frame, key, try frame._factory.create(value));
}

/// `getElementsByTagNameNS` is keyed by both halves, and either may hold any
/// byte a JS string can, so they are joined length-prefixed rather than with a
/// separator that could occur in the data. A null namespace is not the empty
/// one, so the flag byte carries that too.
pub fn namespacedName(frame: *Frame, namespace: ?[]const u8, local_name: []const u8) ![]const u8 {
    const ns = namespace orelse "";
    const out = try frame.local_arena.alloc(u8, 9 + ns.len + local_name.len);
    out[0] = if (namespace == null) 0 else 1;
    std.mem.writeInt(u64, out[1..9], ns.len, .little);
    @memcpy(out[9..][0..ns.len], ns);
    @memcpy(out[9 + ns.len ..], local_name);
    return out;
}

/// Drop the references the cache holds. Called from the frame's teardown,
/// alongside the other objects it keeps alive for their identity.
pub fn releaseAll(frame: *Frame, page: *Page) void {
    var it = frame._live_collections.valueIterator();
    while (it.next()) |cached| {
        switch (cached.*) {
            .all => {},
            inline else => |collection| collection.releaseRef(page),
        }
    }
}
