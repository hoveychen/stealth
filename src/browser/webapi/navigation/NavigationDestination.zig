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

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationDestination
//
// The `destination` of a NavigateEvent, and nothing else hands one out: the
// interface has an Illegal constructor and this engine never fires `navigate`
// (see NavigateEvent in event/misc_events.zig, whose constructor cannot get
// past its required `destination` member either). So no instance is reachable
// and this is the prototype shape -- five getters then getState, in Chrome's
// own order. Measured on a headed Chrome 150 (probe-win28).

const js = @import("../../js/js.zig");

const NavigationDestination = @This();

_url: []const u8 = "",
_key: []const u8 = "",
_id: []const u8 = "",
_index: i64 = -1,
_same_document: bool = false,

pub fn getKey(self: *const NavigationDestination) []const u8 {
    return self._key;
}

pub fn getId(self: *const NavigationDestination) []const u8 {
    return self._id;
}

pub fn getUrl(self: *const NavigationDestination) []const u8 {
    return self._url;
}

pub fn getIndex(self: *const NavigationDestination) i64 {
    return self._index;
}

pub fn getSameDocument(self: *const NavigationDestination) bool {
    return self._same_document;
}

/// The destination's serialised state. A destination this engine could hand
/// out would never carry one, so it is always undefined.
pub fn getState(_: *const NavigationDestination) js.Undefined {
    return .{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationDestination);

    pub const Meta = struct {
        pub const name = "NavigationDestination";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const key = bridge.accessor(NavigationDestination.getKey, null, .{});
    pub const id = bridge.accessor(NavigationDestination.getId, null, .{});
    pub const url = bridge.accessor(NavigationDestination.getUrl, null, .{});
    pub const index = bridge.accessor(NavigationDestination.getIndex, null, .{});
    pub const sameDocument = bridge.accessor(NavigationDestination.getSameDocument, null, .{});
    pub const getState = bridge.function(NavigationDestination.getState, .{});
};
