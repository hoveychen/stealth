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

// The floating window a video is promoted into. There is no compositor here, so
// no instance is ever handed out -- requestPictureInPicture has nothing to
// promote and Chrome itself rejects it on a video whose metadata never loaded
// (measured) -- but the interface is on every Chrome window, alongside the
// document.pictureInPictureEnabled this engine already reports as true.

const js = @import("../../js/js.zig");
const EventTarget = @import("../EventTarget.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const PictureInPictureWindow = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_width: u32 = 0,
_height: u32 = 0,

pub fn asEventTarget(self: *PictureInPictureWindow) *EventTarget {
    return self._proto;
}

pub fn getWidth(self: *const PictureInPictureWindow) u32 {
    return self._width;
}

pub fn getHeight(self: *const PictureInPictureWindow) u32 {
    return self._height;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PictureInPictureWindow);

    pub const Meta = struct {
        pub const name = "PictureInPictureWindow";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(PictureInPictureWindow.getWidth, null, .{});
    pub const height = bridge.accessor(PictureInPictureWindow.getHeight, null, .{});
    pub const onresize = bridge.accessor(handlerProperty(PictureInPictureWindow, .onresize).get, handlerProperty(PictureInPictureWindow, .onresize).set, .{});
};
