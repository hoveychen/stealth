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

// The value carrier behind every automatable audio parameter. Only
// AudioListener's nine parameters reach this type today, so nothing here
// schedules anything: the automation methods record the target value and
// return the param, which is what a script that chains them observes.
//
// minValue/maxValue are -FLT_MAX/FLT_MAX rather than the f64 extremes, because
// that is what Chrome reports (measured: ±3.4028234663852886e38) — the values
// are single-precision inside Blink.

const std = @import("std");

const js = @import("../../js/js.zig");

const AudioParam = @This();

// -FLT_MAX / FLT_MAX, measured off Chrome 150's AudioListener.positionX.
const MIN_VALUE: f64 = -3.4028234663852886e38;
const MAX_VALUE: f64 = 3.4028234663852886e38;

_value: f64,
_default_value: f64,
_automation_rate: AutomationRate,

pub const AutomationRate = enum {
    @"a-rate",
    @"k-rate",
};

pub fn init(default_value: f64) AudioParam {
    return .{
        ._value = default_value,
        ._default_value = default_value,
        ._automation_rate = .@"a-rate",
    };
}

pub fn getValue(self: *const AudioParam) f64 {
    return self._value;
}

pub fn setValue(self: *AudioParam, value: f64) void {
    self._value = value;
}

pub fn getDefaultValue(self: *const AudioParam) f64 {
    return self._default_value;
}

pub fn getMinValue(_: *const AudioParam) f64 {
    return MIN_VALUE;
}

pub fn getMaxValue(_: *const AudioParam) f64 {
    return MAX_VALUE;
}

pub fn getAutomationRate(self: *const AudioParam) []const u8 {
    return @tagName(self._automation_rate);
}

// A string rather than a Zig enum parameter, for the same reason as
// AudioNode.setChannelCountMode.
pub fn setAutomationRate(self: *AudioParam, rate: []const u8) !void {
    self._automation_rate = std.meta.stringToEnum(AutomationRate, rate) orelse return error.TypeError;
}

// The automation methods below all return the param so scripts can chain them.
// With no rendering thread there is no timeline to schedule against, so each
// one applies its target value immediately; `time` is validated the way Chrome
// validates it (negative times are a RangeError) and then ignored.

pub fn setValueAtTime(self: *AudioParam, value: f64, time: f64) !*AudioParam {
    try validateTime(time);
    self._value = value;
    return self;
}

pub fn linearRampToValueAtTime(self: *AudioParam, value: f64, time: f64) !*AudioParam {
    try validateTime(time);
    self._value = value;
    return self;
}

pub fn exponentialRampToValueAtTime(self: *AudioParam, value: f64, time: f64) !*AudioParam {
    try validateTime(time);
    // Chrome rejects a zero target for an exponential ramp.
    if (value == 0) {
        return error.RangeError;
    }
    self._value = value;
    return self;
}

pub fn setTargetAtTime(self: *AudioParam, target: f64, start_time: f64, time_constant: f64) !*AudioParam {
    try validateTime(start_time);
    if (time_constant < 0) {
        return error.RangeError;
    }
    self._value = target;
    return self;
}

pub fn setValueCurveAtTime(self: *AudioParam, values: []const f64, start_time: f64, duration: f64) !*AudioParam {
    try validateTime(start_time);
    if (duration <= 0) {
        return error.RangeError;
    }
    if (values.len < 2) {
        return error.InvalidStateError;
    }
    self._value = values[values.len - 1];
    return self;
}

pub fn cancelScheduledValues(self: *AudioParam, time: f64) !*AudioParam {
    try validateTime(time);
    return self;
}

pub fn cancelAndHoldAtTime(self: *AudioParam, time: f64) !*AudioParam {
    try validateTime(time);
    return self;
}

fn validateTime(time: f64) !void {
    if (time < 0) {
        return error.RangeError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioParam);

    pub const Meta = struct {
        pub const name = "AudioParam";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(AudioParam.getValue, AudioParam.setValue, .{});
    pub const defaultValue = bridge.accessor(AudioParam.getDefaultValue, null, .{});
    pub const minValue = bridge.accessor(AudioParam.getMinValue, null, .{});
    pub const maxValue = bridge.accessor(AudioParam.getMaxValue, null, .{});
    pub const automationRate = bridge.accessor(AudioParam.getAutomationRate, AudioParam.setAutomationRate, .{});

    pub const setValueAtTime = bridge.function(AudioParam.setValueAtTime, .{});
    pub const linearRampToValueAtTime = bridge.function(AudioParam.linearRampToValueAtTime, .{});
    pub const exponentialRampToValueAtTime = bridge.function(AudioParam.exponentialRampToValueAtTime, .{});
    pub const setTargetAtTime = bridge.function(AudioParam.setTargetAtTime, .{});
    pub const setValueCurveAtTime = bridge.function(AudioParam.setValueCurveAtTime, .{});
    pub const cancelScheduledValues = bridge.function(AudioParam.cancelScheduledValues, .{});
    pub const cancelAndHoldAtTime = bridge.function(AudioParam.cancelAndHoldAtTime, .{});
};
