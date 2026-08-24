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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Execution = js.Execution;

const Event = @import("../Event.zig");
const EventManagerBase = @import("../../EventManagerBase.zig");
const EventTarget = @import("../EventTarget.zig");

const FontFace = @import("FontFace.zig");

const FontFaceSet = @This();

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_proto: *EventTarget,
_arena: *lp.Arena,

pub fn init(exec: *const Execution) !*FontFaceSet {
    const arena = try exec.getArena(.tiny, "FontFaceSet");
    errdefer arena.release();

    return exec._factory.eventTargetWithAllocator(arena.allocator(), FontFaceSet{
        ._proto = undefined,
        ._arena = arena,
    });
}

pub fn deinit(self: *FontFaceSet, _: *Page) void {
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

// Both readonly, and both the values that were already here as data properties:
// nothing is tracked, so the set is empty and never loading. Chrome answers them
// from getters, and the kind is what a bot check reads (see
// src/browser/tests/descriptor_kind.html).
pub fn getSize(_: *const FontFaceSet) u32 {
    return 0;
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

// add(fontFace) - no-op; headless browser does not track loaded fonts.
pub fn add(self: *FontFaceSet, _: *FontFace) *FontFaceSet {
    return self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFaceSet);

    pub const Meta = struct {
        pub const name = "FontFaceSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const size = bridge.accessor(FontFaceSet.getSize, null, .{});
    pub const status = bridge.accessor(FontFaceSet.getStatus, null, .{});
    pub const ready = bridge.accessor(FontFaceSet.getReady, null, .{});
    pub const check = bridge.function(FontFaceSet.check, .{});
    pub const load = bridge.function(FontFaceSet.load, .{});
    pub const add = bridge.function(FontFaceSet.add, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFaceSet" {
    try testing.htmlRunner("css/font_face_set.html", .{});
}
