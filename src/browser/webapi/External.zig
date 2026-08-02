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

//! window.external. Both operations were removed from Blink years ago but the
//! interface survives; the two methods are no-ops there and return undefined
//! (measured on a headed Chrome 150). Their capitalised names are the real
//! ones -- the IDL predates the lowerCamelCase convention.

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{External};
}

const External = @This();

_pad: bool = false,

pub const init: External = .{};

pub fn addSearchProvider(_: *const External) void {}

pub fn isSearchProviderInstalled(_: *const External) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(External);

    pub const Meta = struct {
        pub const name = "External";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const AddSearchProvider = bridge.function(External.addSearchProvider, .{});
    pub const IsSearchProviderInstalled = bridge.function(External.isSearchProviderInstalled, .{});
};
