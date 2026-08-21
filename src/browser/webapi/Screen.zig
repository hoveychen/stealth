// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
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
        Screen,
        Orientation,
    };
}

const Screen = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_orientation: ?*Orientation = null,

pub fn asEventTarget(self: *Screen) *EventTarget {
    return self._proto;
}

pub fn getOrientation(self: *Screen, frame: *Frame) !*Orientation {
    if (self._orientation) |orientation| {
        return orientation;
    }
    const orientation = try Orientation.init(frame);
    self._orientation = orientation;
    return orientation;
}

pub fn getWidth(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().width;
}

pub fn getHeight(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().height;
}

// The six below were data properties, which is a difference no value probe can
// see and one a bot check trips over: it reads a value it will not trust the
// instance to answer honestly as
// `Object.getOwnPropertyDescriptor(Screen.prototype, k).get.call(screen)`, and
// against a data property `desc.get` is undefined, so the call throws "Cannot
// read properties of undefined (reading 'call')". Cloudflare's Turnstile dies on
// exactly that line here (measured -- see the trace in tools/fingerprint's
// Turnstile section). Every value below is the one that was there.

// The usable height is the viewport less the menu bar, the 40px availTop
// reports. Kept a constant because that is what it was; only the kind changes.
pub fn getAvailHeight(_: *const Screen) u32 {
    return 1040;
}

// 24-bit colour, which is what every desktop Chrome reports.
pub fn getColorDepth(_: *const Screen) u32 {
    return 24;
}

pub fn getAvailLeft(_: *const Screen) u32 {
    return 0;
}

// The usable area starts below the menu bar.
pub fn getAvailTop(_: *const Screen) u32 {
    return 40;
}

// One display. A second one would be extra entropy, not less.
pub fn getIsExtended(_: *const Screen) bool {
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Screen);

    pub const Meta = struct {
        pub const name = "Screen";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is Object.getOwnPropertyNames(Screen.prototype) order,
    // and that list is itself fingerprinted — this is Chrome 150's own order.
    pub const availWidth = bridge.accessor(Screen.getWidth, null, .{});
    pub const availHeight = bridge.accessor(Screen.getAvailHeight, null, .{});
    pub const width = bridge.accessor(Screen.getWidth, null, .{});
    pub const height = bridge.accessor(Screen.getHeight, null, .{});
    // colorDepth and pixelDepth are the same 24 in Chrome and answer through
    // separate getters only because the two names are separate accessors there.
    pub const colorDepth = bridge.accessor(Screen.getColorDepth, null, .{});
    pub const pixelDepth = bridge.accessor(Screen.getColorDepth, null, .{});
    pub const availLeft = bridge.accessor(Screen.getAvailLeft, null, .{});
    pub const availTop = bridge.accessor(Screen.getAvailTop, null, .{});
    pub const orientation = bridge.accessor(Screen.getOrientation, null, .{});
    pub const onchange = bridge.accessor(handlerProperty(Screen, .onchange).get, handlerProperty(Screen, .onchange).set, .{});
    pub const isExtended = bridge.accessor(Screen.getIsExtended, null, .{});
};

pub const Orientation = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn init(frame: *Frame) !*Orientation {
        return frame._factory.eventTarget(Orientation{
            ._proto = undefined,
        });
    }

    pub fn asEventTarget(self: *Orientation) *EventTarget {
        return self._proto;
    }

    // The same two values that were here as data properties; only the kind
    // moves, for the reason in the comment above getAvailHeight.
    pub fn getAngle(_: *const Orientation) u16 {
        return 0;
    }

    pub fn getType(_: *const Orientation) []const u8 {
        return "landscape-primary";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Orientation);

        pub const Meta = struct {
            pub const name = "ScreenOrientation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const angle = bridge.accessor(Orientation.getAngle, null, .{});
        pub const @"type" = bridge.accessor(Orientation.getType, null, .{});
    };
};
