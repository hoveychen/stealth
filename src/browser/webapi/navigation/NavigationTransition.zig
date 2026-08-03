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

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationTransition
//
// `navigation.transition`, which is non-null only while a same-document
// navigation is in flight. Every navigation this engine performs is already
// finished by the time script can look, so the accessor answers null -- as it
// does in a quiet Chrome tab too (measured) -- and the interface itself is
// unconstructible. This is therefore the prototype shape.
//
// Chrome 150 carries five members, two more than the specification's three:
// `to` and `committed` sit either side of `from`/`finished`. Measured on a
// headed Chrome 150 (probe-win28).

const js = @import("../../js/js.zig");

const NavigationType = @import("root.zig").NavigationType;
const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");

const NavigationTransition = @This();

_type: NavigationType = .push,
_from: ?*NavigationHistoryEntry = null,
_to: ?*NavigationHistoryEntry = null,
_committed: ?js.Promise.Global = null,
_finished: ?js.Promise.Global = null,

pub fn getNavigationType(self: *const NavigationTransition) []const u8 {
    return @tagName(self._type);
}

pub fn getFrom(self: *const NavigationTransition) ?*NavigationHistoryEntry {
    return self._from;
}

pub fn getTo(self: *const NavigationTransition) ?*NavigationHistoryEntry {
    return self._to;
}

pub fn getCommitted(self: *const NavigationTransition) ?js.Promise.Global {
    return self._committed;
}

pub fn getFinished(self: *const NavigationTransition) ?js.Promise.Global {
    return self._finished;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationTransition);

    pub const Meta = struct {
        pub const name = "NavigationTransition";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const navigationType = bridge.accessor(NavigationTransition.getNavigationType, null, .{});
    pub const from = bridge.accessor(NavigationTransition.getFrom, null, .{});
    pub const to = bridge.accessor(NavigationTransition.getTo, null, .{});
    pub const committed = bridge.accessor(NavigationTransition.getCommitted, null, .{});
    pub const finished = bridge.accessor(NavigationTransition.getFinished, null, .{});
};
