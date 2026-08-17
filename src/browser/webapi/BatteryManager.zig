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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// navigator.getBattery() -> BatteryManager.
//
// Chrome ships the Battery Status API and Firefox doesn't, so which shape to
// pick used to be a real choice; now that everything else here reports Chrome,
// having navigator.getBattery === undefined is the contradiction.
//
// The four values are a desktop machine on mains power, which is exactly what
// the reference Chrome 150 reported: charging true, chargingTime 0,
// dischargingTime Infinity, level 1. Nothing is invented — a plugged-in desktop
// is indistinguishable from these constants, and no battery to report is the
// honest state of a machine we know nothing about.

const std = @import("std");

const js = @import("../js/js.zig");
const EventTarget = @import("EventTarget.zig");
const handler_property = @import("handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const BatteryManager = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

pub fn asEventTarget(self: *BatteryManager) *EventTarget {
    return self._proto;
}

pub fn getCharging(_: *const BatteryManager) bool {
    return true;
}

pub fn getChargingTime(_: *const BatteryManager) f64 {
    return 0;
}

// Infinity, per the spec, when the battery is charging or the state is unknown.
pub fn getDischargingTime(_: *const BatteryManager) f64 {
    return std.math.inf(f64);
}

pub fn getLevel(_: *const BatteryManager) f64 {
    return 1;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BatteryManager);

    pub const Meta = struct {
        pub const name = "BatteryManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const charging = bridge.accessor(BatteryManager.getCharging, null, .{});
    pub const chargingTime = bridge.accessor(BatteryManager.getChargingTime, null, .{});
    pub const dischargingTime = bridge.accessor(BatteryManager.getDischargingTime, null, .{});
    pub const level = bridge.accessor(BatteryManager.getLevel, null, .{});
    pub const onchargingchange = bridge.accessor(handlerProperty(BatteryManager, .onchargingchange).get, handlerProperty(BatteryManager, .onchargingchange).set, .{});
    pub const onchargingtimechange = bridge.accessor(handlerProperty(BatteryManager, .onchargingtimechange).get, handlerProperty(BatteryManager, .onchargingtimechange).set, .{});
    pub const ondischargingtimechange = bridge.accessor(handlerProperty(BatteryManager, .ondischargingtimechange).get, handlerProperty(BatteryManager, .ondischargingtimechange).set, .{});
    pub const onlevelchange = bridge.accessor(handlerProperty(BatteryManager, .onlevelchange).get, handlerProperty(BatteryManager, .onlevelchange).set, .{});
};
