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
_on_change: ?js.Function.Global = null,

pub fn asEventTarget(self: *Screen) *EventTarget {
    return self._proto;
}

// Nothing ever fires a change event — the screen doesn't move — but the
// handler has to exist: it is on Chrome's Screen.prototype, and a script that
// enumerates the prototype would notice it missing.
pub fn getOnChange(self: *Screen) ?js.Function.Global {
    return self._on_change;
}

pub fn setOnChange(self: *Screen, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_change = try listen.persistWithThis(self);
    } else {
        self._on_change = null;
    }
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
    pub const availHeight = bridge.property(1040, .{ .template = false });
    pub const width = bridge.accessor(Screen.getWidth, null, .{});
    pub const height = bridge.accessor(Screen.getHeight, null, .{});
    pub const colorDepth = bridge.property(24, .{ .template = false });
    pub const pixelDepth = bridge.property(24, .{ .template = false });
    // The usable area starts at the left edge and below the menu bar, which is
    // the 40px that separates height from availHeight.
    pub const availLeft = bridge.property(0, .{ .template = false });
    pub const availTop = bridge.property(40, .{ .template = false });
    pub const orientation = bridge.accessor(Screen.getOrientation, null, .{});
    pub const onchange = bridge.accessor(Screen.getOnChange, Screen.setOnChange, .{});
    // One display. A second one would be extra entropy, not less.
    pub const isExtended = bridge.property(false, .{ .template = false });
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

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Orientation);

        pub const Meta = struct {
            pub const name = "ScreenOrientation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const angle = bridge.property(0, .{ .template = false });
        pub const @"type" = bridge.property("landscape-primary", .{ .template = false });
    };
};
