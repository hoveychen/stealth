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

const BatteryManager = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_charging_change: ?js.Function.Global = null,
_on_charging_time_change: ?js.Function.Global = null,
_on_discharging_time_change: ?js.Function.Global = null,
_on_level_change: ?js.Function.Global = null,

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

// None of the four ever fires: the values are constant. They exist because
// they're on Chrome's prototype.
pub fn getOnChargingChange(self: *BatteryManager) ?js.Function.Global {
    return self._on_charging_change;
}

pub fn setOnChargingChange(self: *BatteryManager, listener: ?js.Function) !void {
    self._on_charging_change = if (listener) |l| try l.persistWithThis(self) else null;
}

pub fn getOnChargingTimeChange(self: *BatteryManager) ?js.Function.Global {
    return self._on_charging_time_change;
}

pub fn setOnChargingTimeChange(self: *BatteryManager, listener: ?js.Function) !void {
    self._on_charging_time_change = if (listener) |l| try l.persistWithThis(self) else null;
}

pub fn getOnDischargingTimeChange(self: *BatteryManager) ?js.Function.Global {
    return self._on_discharging_time_change;
}

pub fn setOnDischargingTimeChange(self: *BatteryManager, listener: ?js.Function) !void {
    self._on_discharging_time_change = if (listener) |l| try l.persistWithThis(self) else null;
}

pub fn getOnLevelChange(self: *BatteryManager) ?js.Function.Global {
    return self._on_level_change;
}

pub fn setOnLevelChange(self: *BatteryManager, listener: ?js.Function) !void {
    self._on_level_change = if (listener) |l| try l.persistWithThis(self) else null;
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
    pub const onchargingchange = bridge.accessor(BatteryManager.getOnChargingChange, BatteryManager.setOnChargingChange, .{});
    pub const onchargingtimechange = bridge.accessor(BatteryManager.getOnChargingTimeChange, BatteryManager.setOnChargingTimeChange, .{});
    pub const ondischargingtimechange = bridge.accessor(BatteryManager.getOnDischargingTimeChange, BatteryManager.setOnDischargingTimeChange, .{});
    pub const onlevelchange = bridge.accessor(BatteryManager.getOnLevelChange, BatteryManager.setOnLevelChange, .{});
};
