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

//! window.styleMedia, the pre-matchMedia way to ask whether a media query
//! holds. [LegacyNoInterfaceObject]: measured on a headed Chrome 150,
//! Object.prototype.toString.call(window.styleMedia) is '[object StyleMedia]'
//! while globalThis.StyleMedia is undefined and the prototype carries no
//! `constructor` -- only `type` and `matchMedium`.

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const MediaQuery = @import("../css/MediaQuery.zig");

pub fn registerTypes() []const type {
    return &.{StyleMedia};
}

const StyleMedia = @This();

_pad: bool = false,

pub const init: StyleMedia = .{};

pub fn getType(_: *const StyleMedia) []const u8 {
    return "screen";
}

// The same evaluation matchMedia()/MediaQueryList.matches goes through, so the
// two entry points can never disagree.
pub fn matchMedium(_: *const StyleMedia, query: ?[]const u8, frame: *Frame) bool {
    return MediaQuery.matches(query orelse "", frame.viewport());
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StyleMedia);

    pub const Meta = struct {
        pub const name = "StyleMedia";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const no_interface_object = true;
    };

    pub const @"type" = bridge.accessor(StyleMedia.getType, null, .{});
    pub const matchMedium = bridge.function(StyleMedia.matchMedium, .{});
};
