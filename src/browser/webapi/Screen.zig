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

const std = @import("std");
const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Viewport = @import("../Viewport.zig");
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

// The display, which is the viewport plus everything that is not the viewport:
// the browser above the page and the menu bar above that. See Viewport, which
// derives the whole arrangement -- window box, position, usable area -- from
// one number so the readings agree with each other.
pub fn getWidth(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().screenWidth();
}

pub fn getHeight(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().screenHeight();
}

pub fn getAvailWidth(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().availWidth();
}

// The six below were data properties, which is a difference no value probe can
// see and one a bot check trips over: it reads a value it will not trust the
// instance to answer honestly as
// `Object.getOwnPropertyDescriptor(Screen.prototype, k).get.call(screen)`, and
// against a data property `desc.get` is undefined, so the call throws "Cannot
// read properties of undefined (reading 'call')". Cloudflare's Turnstile dies on
// exactly that line here (measured -- see the trace in tools/fingerprint's
// Turnstile section). Every value below is the one that was there.

// The usable height is the display less the menu bar. The window is maximised
// into this area, so `availHeight` is also `window.outerHeight` -- a bot check
// that reads both (Kasada reads availHeight four times and outerHeight nine on
// one x-hyatt load) gets one story.
pub fn getAvailHeight(_: *const Screen, frame: *Frame) u32 {
    return frame._page.getViewport().availHeight();
}

// 30-bit colour: ten bits a channel across three channels. Chrome reports 24 on
// an ordinary 8-bit panel and 30 on a wide-gamut one, and this fork's WebGL
// renderer names an Apple M4, which only ever drives the latter. The media
// features that describe the same panel — `color`, `color-gamut`,
// `dynamic-range` — are derived from this number in css/MediaQuery.zig and move
// with it.
pub fn getColorDepth(_: *const Screen) u32 {
    return 30;
}

pub fn getAvailLeft(_: *const Screen) u32 {
    return Viewport.availLeft;
}

// The usable area starts below the menu bar.
pub fn getAvailTop(_: *const Screen) u32 {
    return Viewport.availTop;
}

// One display. A second one would be extra entropy, not less.
pub fn getIsExtended(_: *const Screen) bool {
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Screen);

    pub const Meta = struct {
        pub const name = "Screen";
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "orientation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is Object.getOwnPropertyNames(Screen.prototype) order,
    // and that list is itself fingerprinted — this is Chrome 150's own order.
    pub const availWidth = bridge.accessor(Screen.getAvailWidth, null, .{});
    pub const availHeight = bridge.accessor(Screen.getAvailHeight, null, .{});
    pub const width = bridge.accessor(Screen.getWidth, null, .{});
    pub const height = bridge.accessor(Screen.getHeight, null, .{});
    // colorDepth and pixelDepth are the same number in Chrome and answer
    // through separate getters only because the two names are separate
    // accessors there.
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

    /// The six OrientationLockType keywords plus `any` and `natural`. Both
    /// failure modes are *rejections*, not throws: Chrome hands back a Promise
    /// for every call, including one with no argument at all, and rejects it
    /// (measured -- a first reading with `await` around the call could not
    /// tell the two apart, and the plausible answer was the wrong one). A
    /// value inside the set rejects too, because a desktop screen is not
    /// lockable. Both sentences are Blink's; the arity one comes from the
    /// bridge.
    const lock_types = [_][]const u8{
        "any",              "natural",            "landscape",         "portrait",
        "portrait-primary", "portrait-secondary", "landscape-primary", "landscape-secondary",
    };

    pub fn lock(_: *Orientation, orientation: []const u8, frame: *Frame) !js.Promise {
        for (lock_types) |candidate| {
            if (std.mem.eql(u8, candidate, orientation)) {
                return frame.js.local.?.rejectPromise(.{ .dom_exception = .{
                    .err = error.NotSupported,
                    .message = "screen.orientation.lock() is not available on this device.",
                } });
            }
        }
        return frame.js.fail(error.TypeError, try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to execute 'lock' on 'ScreenOrientation': The provided value '{s}' is not a valid enum value of type OrientationLockType.",
            .{orientation},
        ));
    }

    /// Returns undefined, not a promise (measured).
    pub fn unlock(_: *Orientation) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Orientation);

        pub const Meta = struct {
            pub const name = "ScreenOrientation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const angle = bridge.accessor(Orientation.getAngle, null, .{});
        pub const @"type" = bridge.accessor(Orientation.getType, null, .{});
        pub const onchange = bridge.accessor(handlerProperty(Orientation, .onchange).get, handlerProperty(Orientation, .onchange).set, .{});
        pub const lock = bridge.function(Orientation.lock, .{});
        pub const unlock = bridge.function(Orientation.unlock, .{});
    };
};
