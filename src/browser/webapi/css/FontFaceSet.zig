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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Execution = js.Execution;

const Event = @import("../Event.zig");
const EventManagerBase = @import("../../EventManagerBase.zig");
const EventTarget = @import("../EventTarget.zig");

const FontFace = @import("FontFace.zig");

const FontFaceSet = @This();

const log = lp.log;

pub fn registerTypes() []const type {
    return &.{ FontFaceSet, ValueIterator, EntryIterator };
}

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_proto: *EventTarget,
_arena: *lp.Arena,
// The faces `add()` was given. Nothing here loads a font -- `status` stays
// "loaded" and `check` stays true -- but the set has to remember what it was
// handed, because a page walks it back out: `for (const f of document.fonts)`.
_faces: std.ArrayList(*FontFace) = .empty,

pub fn init(exec: *const Execution) !*FontFaceSet {
    const arena = try exec.getArena(.tiny, "FontFaceSet");
    errdefer arena.release();

    return exec._factory.eventTargetWithAllocator(arena.allocator(), FontFaceSet{
        ._proto = undefined,
        ._arena = arena,
    });
}

pub fn deinit(self: *FontFaceSet, page: *Page) void {
    // The set holds a reference to every face it was handed, so it has to give
    // them back: a FontFace owns an arena, and an extra reference outliving the
    // page is a leaked arena (the test runner panics on those).
    for (self._faces.items) |face| {
        face.releaseRef(page);
    }
    self._arena.release();
}

pub fn releaseRef(self: *FontFaceSet, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFaceSet) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *FontFaceSet) *EventTarget {
    return self._proto;
}

// Readonly, and answered from a getter because the kind is what a bot check
// reads (see src/browser/tests/descriptor_kind.html).
pub fn getSize(self: *const FontFaceSet) u32 {
    return @intCast(self._faces.items.len);
}

pub fn getStatus(_: *const FontFaceSet) []const u8 {
    return "loaded";
}

// FontFaceSet.ready - returns an already-resolved Promise.
// In a headless browser there is no font loading, so fonts are always ready.
pub fn getReady(_: *FontFaceSet, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

// check(font, text?) - always true; headless has no real fonts to check.
pub fn check(_: *const FontFaceSet, font: []const u8) bool {
    _ = font;
    return true;
}

// load(font, text?) - resolves immediately with an empty array.
pub fn load(self: *FontFaceSet, font: []const u8, exec: *const Execution) !js.Promise {
    // TODO parse font to check if the font has been added before dispatching
    // events.
    _ = font;

    const target = self.asEventTarget();
    try dispatch(exec, target, "loading");
    try dispatch(exec, target, "loadingdone");

    return exec.js.local.?.resolvePromise({});
}

// Into the asking realm's own listener list. Both globals carry the same two
// members -- a frame through the DOM-aware EventManager, which also keeps
// `window.event` pointed at the event being dispatched, and a worker directly --
// so the split is over which one to ask, not over what to do.
fn dispatch(exec: *const Execution, target: *EventTarget, comptime typ: []const u8) !void {
    const opts: EventManagerBase.DispatchDirectOptions = .{ .context = "load font face set" };
    switch (exec.js.global) {
        .frame => |frame| {
            if (frame._event_manager.hasDirectListeners(target, typ, null) == false) {
                return;
            }
            const event = try Event.initTrusted(comptime .wrap(typ), .{}, frame._page);
            try frame._event_manager.dispatchDirect(target, event, null, opts);
        },
        .worker => |worker| {
            if (worker.hasDirectListeners(target, typ, null) == false) {
                return;
            }
            const event = try Event.initTrusted(comptime .wrap(typ), .{}, worker._page);
            try worker.dispatch(target, event, null, opts);
        },
    }
}

// The setlike half. Chrome's semantics, measured
// (tools/fingerprint/probes/expr-fontfaceset.js): `add` is idempotent per face
// and answers the set, `delete` answers whether it removed anything, `clear`
// answers undefined, and all three refuse anything that is not a FontFace.
pub fn add(self: *FontFaceSet, face: *FontFace) !*FontFaceSet {
    if (self.indexOf(face) != null) {
        return self;
    }
    face.acquireRef();
    try self._faces.append(self._arena.allocator(), face);
    return self;
}

pub fn delete(self: *FontFaceSet, face: *FontFace, exec: *const Execution) bool {
    const index = self.indexOf(face) orelse return false;
    // orderedRemove, not swapRemove: iteration order is insertion order, and a
    // page that adds three faces and deletes the first still walks the other
    // two in the order it added them.
    _ = self._faces.orderedRemove(index);
    face.releaseRef(exec.page);
    return true;
}

pub fn clear(self: *FontFaceSet, exec: *const Execution) void {
    for (self._faces.items) |face| {
        face.releaseRef(exec.page);
    }
    self._faces.clearRetainingCapacity();
}

pub fn has(self: *const FontFaceSet, face: *FontFace) bool {
    return self.indexOf(face) != null;
}

fn indexOf(self: *const FontFaceSet, face: *FontFace) ?usize {
    for (self._faces.items, 0..) |candidate, i| {
        if (candidate == face) {
            return i;
        }
    }
    return null;
}

pub fn values(self: *FontFaceSet, exec: *const Execution) !*ValueIterator {
    return .init(.{ .set = self }, exec);
}

pub fn entries(self: *FontFaceSet, exec: *const Execution) !*EntryIterator {
    return .init(.{ .set = self }, exec);
}

// A set's callback is handed the value twice and the set third, same as
// Set.prototype.forEach.
pub fn forEach(self: *FontFaceSet, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
    for (self._faces.items) |face| {
        var caught: js.TryCatch.Caught = .{};
        cb.tryCall(void, .{ face, face, self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "FontFaceSet" });
        };
    }
}

pub const Iterator = struct {
    index: usize = 0,
    set: *FontFaceSet,

    pub const Entry = struct { *FontFace, *FontFace };

    pub fn next(self: *Iterator, _: *const Execution) ?Entry {
        const index = self.index;
        if (index >= self.set._faces.items.len) {
            return null;
        }
        self.index = index + 1;
        const face = self.set._faces.items[index];
        return .{ face, face };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome 151's own `Object.getOwnPropertyNames(FontFaceSet.prototype)`
    // order, measured; `constructor` is the bridge's and lands last.
    pub const onloading = bridge.accessor(handlerProperty(FontFaceSet, .onloading).get, handlerProperty(FontFaceSet, .onloading).set, .{});
    pub const onloadingdone = bridge.accessor(handlerProperty(FontFaceSet, .onloadingdone).get, handlerProperty(FontFaceSet, .onloadingdone).set, .{});
    pub const onloadingerror = bridge.accessor(handlerProperty(FontFaceSet, .onloadingerror).get, handlerProperty(FontFaceSet, .onloadingerror).set, .{});
    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const status = bridge.accessor(FontFaceSet.getStatus, null, .{});
    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
    pub const add = bridge.function(FontFaceSet.add, .{});
    pub const clear = bridge.function(FontFaceSet.clear, .{});
    pub const delete = bridge.function(FontFaceSet.delete, .{});
    pub const entries = bridge.function(FontFaceSet.entries, .{});
    pub const forEach = bridge.function(FontFaceSet.forEach, .{ .arity = 1 });
    pub const has = bridge.function(FontFaceSet.has, .{});
    // Chrome hands out one function object under both names; the bridge builds
    // two, which is the same shape every other collection here has.
    pub const keys = bridge.function(FontFaceSet.values, .{});
    pub const values = bridge.function(FontFaceSet.values, .{});
    pub const symbol_iterator = bridge.iterator(FontFaceSet.values, .{ .js_name = "values" });
};

const testing = @import("../../../testing.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties; per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}
