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

//! The object behind window.locationbar / menubar / personalbar / scrollbars /
//! statusbar / toolbar. Six separate instances, because Chrome hands back six
//! distinct objects (measured: window.locationbar !== window.menubar).

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{BarProp};
}

const BarProp = @This();

_pad: bool = false,

pub const init: BarProp = .{};

// A headed Chrome 150 reports every bar visible, including the ones macOS
// draws nowhere near the page (menubar, personalbar). Headless answers false
// for all six, so this is one of the values that gives a headless build away.
pub fn getVisible(_: *const BarProp) bool {
    return true;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BarProp);

    pub const Meta = struct {
        pub const name = "BarProp";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const visible = bridge.accessor(BarProp.getVisible, null, .{});
};
