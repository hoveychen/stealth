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
const URL = @import("../URL.zig");
const NavigationState = @import("root.zig").NavigationState;
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const Frame = @import("../../Frame.zig");
const js = @import("../../js/js.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const NavigationHistoryEntry = @This();

pub const Proto = EventTarget;

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationHistoryEntry
_proto: *EventTarget,
_id: []const u8,
_key: []const u8,
_url: ?[:0]const u8,
_state: NavigationState,

pub fn asEventTarget(self: *NavigationHistoryEntry) *EventTarget {
    return self._proto;
}

pub fn id(self: *const NavigationHistoryEntry) []const u8 {
    return self._id;
}

pub fn index(self: *const NavigationHistoryEntry, frame: *Frame) i32 {
    const navigation = frame._navigation;

    for (navigation._state._entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry._id, self._id)) {
            return @intCast(i);
        }
    }

    return -1;
}

pub fn key(self: *const NavigationHistoryEntry) []const u8 {
    return self._key;
}

pub fn sameDocument(self: *const NavigationHistoryEntry, frame: *Frame) bool {
    const got_url = self._url orelse return false;
    return URL.eqlDocument(got_url, frame.base());
}

pub fn url(self: *const NavigationHistoryEntry) ?[:0]const u8 {
    return self._url;
}

pub const StateReturn = union(enum) { value: ?js.Value, undefined: void };

pub fn getState(self: *const NavigationHistoryEntry, frame: *Frame) !StateReturn {
    if (self._state.source == .navigation) {
        if (self._state.value) |value| {
            return .{ .value = try frame.js.local.?.parseJSON(value) };
        }
    }

    return .undefined;
}

pub fn fireDispose(self: *NavigationHistoryEntry, frame: *Frame) !void {
    if (!frame.hasDirectListeners(self.asEventTarget(), "dispose", null)) return;

    const event = try Event.initTrusted(comptime .wrap("dispose"), .{}, frame._page);
    try frame.dispatch(self.asEventTarget(), event, null, .{ .context = "NavigationHistoryEntry" });
}

pub fn setOnDispose(self: *NavigationHistoryEntry, cb_: ?js.Function) !void {
    if (self._on_dispose) |od| od.release();
    if (cb_) |cb| {
        self._on_dispose = try cb.persistWithThis(self);
    } else {
        self._on_dispose = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationHistoryEntry);

    pub const Meta = struct {
        pub const name = "NavigationHistoryEntry";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const key = bridge.accessor(NavigationHistoryEntry.key, null, .{});
    pub const id = bridge.accessor(NavigationHistoryEntry.id, null, .{});
    pub const url = bridge.accessor(NavigationHistoryEntry.url, null, .{});
    pub const index = bridge.accessor(NavigationHistoryEntry.index, null, .{});
    pub const sameDocument = bridge.accessor(NavigationHistoryEntry.sameDocument, null, .{});
    pub const ondispose = bridge.accessor(handlerProperty(NavigationHistoryEntry, .ondispose).get, handlerProperty(NavigationHistoryEntry, .ondispose).set, .{});
    pub const getState = bridge.function(NavigationHistoryEntry.getState, .{});
};
