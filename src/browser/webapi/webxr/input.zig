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

// The input half: a source, the array a session lists its sources in, and the
// map of hand joints.
//
// An inline session on a device-less desktop reports zero input sources and
// never grants hand tracking (measured on a headed Chrome 150:
// `session.inputSources.length` is 0 and the array carries no own property
// names), so XRInputSource and XRHand have no instance here at all. The array
// does: it is what `session.inputSources` hands back, empty.
//
// Two shape details that are only visible by measuring, both pinned in the
// tests: XRInputSourceArray is array-like with its four iteration methods
// declared *before* `length`, and XRHand is the one collection in this family
// whose @@iterator is `entries` rather than `values`.

const std = @import("std");

const js = @import("../../js/js.zig");
const spaces = @import("spaces.zig");
const Gamepad = @import("../gamepad.zig").Gamepad;

const XRSpace = spaces.XRSpace;
const XRJointSpace = spaces.XRJointSpace;
const Execution = js.Execution;
const GenericIterator = @import("../collections/iterator.zig").Entry;

pub fn registerTypes() []const type {
    return &.{
        XRHand,
        XRHand.KeyIterator,
        XRHand.ValueIterator,
        XRHand.EntryIterator,
        XRInputSource,
        XRInputSourceArray,
        XRInputSourceArray.KeyIterator,
        XRInputSourceArray.ValueIterator,
        XRInputSourceArray.EntryIterator,
    };
}

/// One controller, hand or gaze ray. Nothing here produces one -- an inline
/// session has no input sources -- so every getter is the shape only.
pub const XRInputSource = struct {
    _handedness: []const u8 = "none",
    _target_ray_mode: []const u8 = "gaze",
    _target_ray_space: *XRSpace,
    _grip_space: ?*XRSpace = null,
    _gamepad: ?*Gamepad = null,
    _hand: ?*XRHand = null,
    _profiles: []const []const u8 = &.{},

    pub fn getHandedness(self: *const XRInputSource) []const u8 {
        return self._handedness;
    }

    pub fn getTargetRayMode(self: *const XRInputSource) []const u8 {
        return self._target_ray_mode;
    }

    pub fn getTargetRaySpace(self: *const XRInputSource) *XRSpace {
        return self._target_ray_space;
    }

    pub fn getGripSpace(self: *const XRInputSource) ?*XRSpace {
        return self._grip_space;
    }

    pub fn getGamepad(self: *const XRInputSource) ?*Gamepad {
        return self._gamepad;
    }

    pub fn getHand(self: *const XRInputSource) ?*XRHand {
        return self._hand;
    }

    pub fn getProfiles(self: *const XRInputSource) []const []const u8 {
        return self._profiles;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRInputSource);

        pub const Meta = struct {
            pub const name = "XRInputSource";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const handedness = bridge.accessor(XRInputSource.getHandedness, null, .{});
        pub const targetRayMode = bridge.accessor(XRInputSource.getTargetRayMode, null, .{});
        pub const targetRaySpace = bridge.accessor(XRInputSource.getTargetRaySpace, null, .{});
        pub const gripSpace = bridge.accessor(XRInputSource.getGripSpace, null, .{});
        pub const gamepad = bridge.accessor(XRInputSource.getGamepad, null, .{});
        pub const hand = bridge.accessor(XRInputSource.getHand, null, .{});
        pub const profiles = bridge.accessor(XRInputSource.getProfiles, null, .{});
    };
};

/// `session.inputSources`. Array-like, not an Array, and always empty here.
pub const XRInputSourceArray = struct {
    _sources: []const *XRInputSource = &.{},

    pub fn create(exec: *const Execution) !*XRInputSourceArray {
        return exec._factory.create(XRInputSourceArray{});
    }

    pub fn getLength(self: *const XRInputSourceArray) u32 {
        return @intCast(self._sources.len);
    }

    pub fn keys(self: *XRInputSourceArray, exec: *const Execution) !*KeyIterator {
        return .init(.{ .list = self }, exec);
    }

    pub fn values(self: *XRInputSourceArray, exec: *const Execution) !*ValueIterator {
        return .init(.{ .list = self }, exec);
    }

    pub fn entries(self: *XRInputSourceArray, exec: *const Execution) !*EntryIterator {
        return .init(.{ .list = self }, exec);
    }

    /// Chrome does not arity-check this one: calling it with no argument gives
    /// a plain "TypeError: undefined is not a function" rather than WebIDL's
    /// "1 argument required" (measured, and unlike XRAnchorSet.forEach).
    pub fn forEach(self: *XRInputSourceArray, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._sources, 0..) |source, index| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ source, @as(u32, @intCast(index)), self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        list: *XRInputSourceArray,

        pub const Entry = struct { u32, *XRInputSource };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const sources = self.list._sources;
            const index = self.index;
            if (index >= sources.len) {
                return null;
            }
            self.index = index + 1;
            return .{ index, sources[index] };
        }
    };

    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRInputSourceArray);

        pub const Meta = struct {
            pub const name = "XRInputSourceArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome declares the four iteration methods before `length`.
        pub const entries = bridge.function(XRInputSourceArray.entries, .{});
        pub const keys = bridge.function(XRInputSourceArray.keys, .{});
        pub const values = bridge.function(XRInputSourceArray.values, .{});
        pub const forEach = bridge.function(XRInputSourceArray.forEach, .{});
        pub const length = bridge.accessor(XRInputSourceArray.getLength, null, .{});
        pub const symbol_iterator = bridge.iterator(XRInputSourceArray.values, .{ .js_name = "values" });
    };
};

/// The 25 joints of a tracked hand, keyed by joint name. `hand-tracking` is
/// not a feature any session here enables, so this is interface-only.
pub const XRHand = struct {
    _joints: []const Joint = &.{},

    pub const Joint = struct {
        name: []const u8,
        space: *XRJointSpace,
    };

    pub fn getSize(self: *const XRHand) u32 {
        return @intCast(self._joints.len);
    }

    pub fn get(self: *XRHand, name: []const u8) ?*XRJointSpace {
        for (self._joints) |joint| {
            if (std.mem.eql(u8, joint.name, name)) {
                return joint.space;
            }
        }
        return null;
    }

    pub fn keys(self: *XRHand, exec: *const Execution) !*KeyIterator {
        return .init(.{ .hand = self }, exec);
    }

    pub fn values(self: *XRHand, exec: *const Execution) !*ValueIterator {
        return .init(.{ .hand = self }, exec);
    }

    pub fn entries(self: *XRHand, exec: *const Execution) !*EntryIterator {
        return .init(.{ .hand = self }, exec);
    }

    pub fn forEach(self: *XRHand, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._joints) |joint| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ joint.space, joint.name, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        hand: *XRHand,

        pub const Entry = struct { []const u8, *XRJointSpace };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const joints = self.hand._joints;
            const index = self.index;
            if (index >= joints.len) {
                return null;
            }
            self.index = index + 1;
            return .{ joints[index].name, joints[index].space };
        }
    };

    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRHand);

        pub const Meta = struct {
            pub const name = "XRHand";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const size = bridge.accessor(XRHand.getSize, null, .{});
        pub const get = bridge.function(XRHand.get, .{});
        pub const entries = bridge.function(XRHand.entries, .{});
        pub const forEach = bridge.function(XRHand.forEach, .{});
        pub const keys = bridge.function(XRHand.keys, .{});
        pub const values = bridge.function(XRHand.values, .{});
        // The odd one out: a map-like whose default iterator is `entries`.
        pub const symbol_iterator = bridge.iterator(XRHand.entries, .{ .js_name = "entries" });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebXR input" {
    try testing.htmlRunner("webxr/input.html", .{});
}
