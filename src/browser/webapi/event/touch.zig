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

// The two objects a touch event carries. TouchEvent itself already exists here;
// its three lists were plain empty JS Arrays, and Touch had no global at all --
// so `window.Touch` was undefined on an engine that claims a Chrome that ships
// touch events. Chrome exposes both on the window of a desktop build too
// (measured on a headed Chrome 150, no touchscreen attached).
//
// Touch is constructible and its dictionary has two required members; both
// messages below are Chrome's own. Every other member defaults to 0.

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const EventTarget = @import("../EventTarget.zig");

pub fn registerTypes() []const type {
    return &.{
        Touch,
        TouchList,
        TouchList.Iterator,
    };
}

fn throwTypeError(message: []const u8, exec: *const js.Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

pub const Touch = struct {
    _identifier: i32,
    _target: *EventTarget,
    _screen_x: f64 = 0,
    _screen_y: f64 = 0,
    _client_x: f64 = 0,
    _client_y: f64 = 0,
    _page_x: f64 = 0,
    _page_y: f64 = 0,
    _radius_x: f64 = 0,
    _radius_y: f64 = 0,
    _rotation_angle: f64 = 0,
    _force: f64 = 0,

    const PREFIX = "Failed to construct 'Touch': Failed to read the '";

    /// Read by hand rather than through a typed dictionary: the two required
    /// members need Chrome's "Required member is undefined." wording, which
    /// the bridge's generic conversion failure cannot produce.
    pub fn constructor(init_: ?js.Value, exec: *const js.Execution) !*Touch {
        const init = init_ orelse return throwTypeError(
            "Failed to construct 'Touch': The provided value is not of type 'TouchInit'.",
            exec,
        );
        if (!init.isObject()) {
            return throwTypeError(
                "Failed to construct 'Touch': The provided value is not of type 'TouchInit'.",
                exec,
            );
        }
        const object = init.toObject();

        const identifier = try requiredMember(object, "identifier", exec);
        const target_value = try requiredMember(object, "target", exec);
        const target = target_value.toZig(*EventTarget) catch return throwTypeError(
            PREFIX ++ "target' property from 'TouchInit': Failed to convert value to 'EventTarget'.",
            exec,
        );

        const self = try exec.page.factory.create(Touch{
            ._identifier = @intFromFloat(try identifier.toF64()),
            ._target = target,
        });
        inline for (.{
            .{ "screenX", "_screen_x" },
            .{ "screenY", "_screen_y" },
            .{ "clientX", "_client_x" },
            .{ "clientY", "_client_y" },
            .{ "pageX", "_page_x" },
            .{ "pageY", "_page_y" },
            .{ "radiusX", "_radius_x" },
            .{ "radiusY", "_radius_y" },
            .{ "rotationAngle", "_rotation_angle" },
            .{ "force", "_force" },
        }) |pair| {
            const member = try object.get(pair[0]);
            if (!member.isUndefined()) {
                @field(self, pair[1]) = try member.toF64();
            }
        }
        return self;
    }

    fn requiredMember(object: js.Object, comptime name: []const u8, exec: *const js.Execution) !js.Value {
        const member = try object.get(name);
        if (member.isUndefined()) {
            return throwTypeError(
                PREFIX ++ name ++ "' property from 'TouchInit': Required member is undefined.",
                exec,
            );
        }
        return member;
    }

    pub fn getIdentifier(self: *const Touch) i32 {
        return self._identifier;
    }

    pub fn getTarget(self: *const Touch) *EventTarget {
        return self._target;
    }

    pub fn getScreenX(self: *const Touch) f64 {
        return self._screen_x;
    }

    pub fn getScreenY(self: *const Touch) f64 {
        return self._screen_y;
    }

    pub fn getClientX(self: *const Touch) f64 {
        return self._client_x;
    }

    pub fn getClientY(self: *const Touch) f64 {
        return self._client_y;
    }

    pub fn getPageX(self: *const Touch) f64 {
        return self._page_x;
    }

    pub fn getPageY(self: *const Touch) f64 {
        return self._page_y;
    }

    pub fn getRadiusX(self: *const Touch) f64 {
        return self._radius_x;
    }

    pub fn getRadiusY(self: *const Touch) f64 {
        return self._radius_y;
    }

    pub fn getRotationAngle(self: *const Touch) f64 {
        return self._rotation_angle;
    }

    pub fn getForce(self: *const Touch) f64 {
        return self._force;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Touch);

        pub const Meta = struct {
            pub const name = "Touch";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(Touch.constructor, .{ .arity = 1 });
        pub const identifier = bridge.accessor(Touch.getIdentifier, null, .{});
        pub const target = bridge.accessor(Touch.getTarget, null, .{});
        pub const screenX = bridge.accessor(Touch.getScreenX, null, .{});
        pub const screenY = bridge.accessor(Touch.getScreenY, null, .{});
        pub const clientX = bridge.accessor(Touch.getClientX, null, .{});
        pub const clientY = bridge.accessor(Touch.getClientY, null, .{});
        pub const pageX = bridge.accessor(Touch.getPageX, null, .{});
        pub const pageY = bridge.accessor(Touch.getPageY, null, .{});
        pub const radiusX = bridge.accessor(Touch.getRadiusX, null, .{});
        pub const radiusY = bridge.accessor(Touch.getRadiusY, null, .{});
        pub const rotationAngle = bridge.accessor(Touch.getRotationAngle, null, .{});
        pub const force = bridge.accessor(Touch.getForce, null, .{});
    };
};

/// TouchEvent's three lists. Not constructible in Chrome either -- the removed
/// document.createTouchList is the only thing that ever built one from a page
/// (measured: it is gone from Chrome 150).
pub const TouchList = struct {
    _touches: []const *Touch = &.{},

    pub fn create(touches: []const *Touch, page: *Page) !*TouchList {
        return page.factory.create(TouchList{ ._touches = touches });
    }

    pub fn getLength(self: *const TouchList) u32 {
        return @intCast(self._touches.len);
    }

    pub fn item(self: *const TouchList, index: u32) ?*Touch {
        if (index >= self._touches.len) {
            return null;
        }
        return self._touches[index];
    }

    pub fn iterator(self: *TouchList, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *TouchList,

        pub fn next(self: *@This(), _: *const js.Execution) ?*Touch {
            const index = self.index;
            const touch = self.list.item(index) orelse return null;
            self.index = index + 1;
            return touch;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TouchList);

        pub const Meta = struct {
            pub const name = "TouchList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(TouchList.getLength, null, .{});
        pub const item = bridge.function(TouchList.item, .{});
        pub const @"[]" = bridge.indexed(TouchList.item, getIndexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(TouchList.iterator, .{ .js_name = "values" });

        fn getIndexes(self: *TouchList, exec: *const js.Execution) !js.Array {
            const len = self.getLength();
            var arr = exec.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: Touch" {
    try testing.htmlRunner("touch.html", .{});
}
