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

//! The Window Management API's two interfaces.
//!
//! `window.getScreenDetails()` needs the window-management permission, and
//! asking for it needs a transient activation, so on a page that simply calls
//! it the promise rejects (measured on a headed Chrome 150:
//! `NotAllowedError: Transient activation is required to request permission.`).
//! Neither interface is therefore ever instantiated -- the globals and their
//! prototypes are the surface a detector reads.

const js = @import("../js/js.zig");

const Screen = @import("Screen.zig");
const EventTarget = @import("EventTarget.zig");
const handler_property = @import("handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

pub fn registerTypes() []const type {
    return &.{
        ScreenDetails,
        ScreenDetailed,
    };
}

pub const ScreenDetails = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn getScreens(_: *const ScreenDetails) js.FrozenArray(*ScreenDetailed) {
        return .empty;
    }

    pub fn getCurrentScreen(_: *const ScreenDetails) ?*ScreenDetailed {
        return null;
    }

    pub fn asEventTarget(self: *ScreenDetails) *EventTarget {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ScreenDetails);

        pub const Meta = struct {
            pub const name = "ScreenDetails";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const screens = bridge.accessor(ScreenDetails.getScreens, null, .{});
        pub const currentScreen = bridge.accessor(ScreenDetails.getCurrentScreen, null, .{});
        pub const onscreenschange = bridge.accessor(handlerProperty(ScreenDetails, .onscreenschange).get, handlerProperty(ScreenDetails, .onscreenschange).set, .{});
        pub const oncurrentscreenchange = bridge.accessor(handlerProperty(ScreenDetails, .oncurrentscreenchange).get, handlerProperty(ScreenDetails, .oncurrentscreenchange).set, .{});
    };
};

// Chrome roots this at Screen.prototype, so it inherits width/height/orientation
// and only adds the six placement members.
pub const ScreenDetailed = struct {
    pub const Proto = Screen;

    _proto: *Screen,

    pub fn getLeft(_: *const ScreenDetailed) i32 {
        return 0;
    }

    pub fn getTop(_: *const ScreenDetailed) i32 {
        return 0;
    }

    pub fn getIsPrimary(_: *const ScreenDetailed) bool {
        return true;
    }

    pub fn getIsInternal(_: *const ScreenDetailed) bool {
        return true;
    }

    // The same number Window reports. A page that can reach this surface can
    // reach `window.devicePixelRatio` too, so the two disagreeing is a reading
    // in itself.
    pub fn getDevicePixelRatio(_: *const ScreenDetailed) f64 {
        return 2;
    }

    pub fn getLabel(_: *const ScreenDetailed) []const u8 {
        return "";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ScreenDetailed);

        pub const Meta = struct {
            pub const name = "ScreenDetailed";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const left = bridge.accessor(ScreenDetailed.getLeft, null, .{});
        pub const top = bridge.accessor(ScreenDetailed.getTop, null, .{});
        pub const isPrimary = bridge.accessor(ScreenDetailed.getIsPrimary, null, .{});
        pub const isInternal = bridge.accessor(ScreenDetailed.getIsInternal, null, .{});
        pub const devicePixelRatio = bridge.accessor(ScreenDetailed.getDevicePixelRatio, null, .{});
        pub const label = bridge.accessor(ScreenDetailed.getLabel, null, .{});
    };
};
