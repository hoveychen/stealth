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

// The value carrier behind every automatable audio parameter. Nothing here
// schedules anything: the automation methods record the target value and
// return the param, which is what a script that chains them observes.
//
// The bounds are per-parameter, not universal. Most of them are
// -FLT_MAX/FLT_MAX rather than the f64 extremes, because that is what Chrome
// reports (measured: ±3.4028234663852886e38 — the values are single-precision
// inside Blink), but a good few are much narrower: DelayNode.delayTime is
// 0..maxDelayTime, StereoPannerNode.pan is -1..1, OscillatorNode.frequency is
// ±Nyquist. Every pair in this file was read off a headed Chrome 150
// (win15-chrome.json), never off the spec.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");

const Execution = js.Execution;

const AudioParam = @This();

// -FLT_MAX / FLT_MAX, measured off Chrome 150's AudioListener.positionX.
pub const MIN_VALUE: f64 = -3.4028234663852886e38;
pub const MAX_VALUE: f64 = 3.4028234663852886e38;

_value: f64,
_default_value: f64,
_automation_rate: AutomationRate,
_min_value: f64 = MIN_VALUE,
_max_value: f64 = MAX_VALUE,

// What a render would hold this parameter at is not `value`: an automation
// event does not move the getter before the render thread has walked the
// timeline — Chrome's does not move either, which is why this gap stayed
// invisible until somebody rendered the graph — but it is exactly what gets
// rendered. The two fields below carry that, and `renderValue()` reads them.
//
// A `setValueAtTime` landing at the very start of the render. `value = x` is
// the same event at the same instant, so whichever came last wins: assigning
// clears this, which is Chrome's answer both ways round (measured — scheduling
// 10 kHz then assigning 1 kHz renders 1 kHz, and the reverse renders 1 kHz
// too).
_scheduled_start: ?f64 = null,

// The timeline does something after the start that is not a single constant.
// Any recorded render is then off the table, and not only for the obvious
// shapes: Chrome renders 124.04346760431508 for the canonical graph with one
// event scheduled a full second past the end of a 0.1134 s render, against
// 124.04347624466754 with no event at all. A timeline that exists is walked,
// and nearly-right is the one answer worth less than silence.
_timeline_moves: bool = false,

// A few parameters refuse to have their rate changed at all, and Chrome names
// them when it refuses: AudioBufferSourceNode's detune and playbackRate are
// k-rate for good (measured). Null means the rate is free to move.
_fixed_rate_label: ?[]const u8 = null,

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

// The full form: a parameter whose range or rate is not the default one.
pub fn bounded(default_value: f64, min: f64, max: f64, rate: AutomationRate) AudioParam {
    return .{
        ._value = default_value,
        ._default_value = default_value,
        ._automation_rate = rate,
        ._min_value = min,
        ._max_value = max,
    };
}

pub fn getValue(self: *const AudioParam) f64 {
    return self._value;
}

// Chrome clamps into [minValue, maxValue] rather than throwing (measured:
// `pan.value = 5` reads back 1), and refuses a non-finite float outright.
pub fn setValue(self: *AudioParam, value: f64, exec: *const Execution) !void {
    if (std.math.isNan(value) or std.math.isInf(value)) return idl.typeError(
        "Failed to set the 'value' property on 'AudioParam': The provided float value is non-finite.",
        exec,
    );
    self._value = std.math.clamp(value, self._min_value, self._max_value);
    self._scheduled_start = null;
}

/// The constant a render would hold this parameter at, or null when the
/// timeline moves it and no recorded render can stand in for the result. Read
/// by the two graph matchers (canonical_render.zig, buffer_render.zig) and by
/// nothing else, which is why the handful of places that write `_value`
/// directly -- constructor options, and the legacy setPosition/setOrientation
/// setters -- are left alone: none of them touch a parameter either matcher
/// looks at.
pub fn renderValue(self: *const AudioParam) ?f64 {
    if (self._timeline_moves) return null;
    return self._scheduled_start orelse self._value;
}

pub fn getDefaultValue(self: *const AudioParam) f64 {
    return self._default_value;
}

pub fn getMinValue(self: *const AudioParam) f64 {
    return self._min_value;
}

pub fn getMaxValue(self: *const AudioParam) f64 {
    return self._max_value;
}

pub fn getAutomationRate(self: *const AudioParam) []const u8 {
    return @tagName(self._automation_rate);
}

// A string rather than a Zig enum parameter, for the same reason as
// AudioNode.setChannelCountMode: a value outside the enum is ignored, but a
// parameter whose rate is pinned throws and names itself.
pub fn setAutomationRate(self: *AudioParam, rate: []const u8, exec: *const Execution) !void {
    if (self._fixed_rate_label) |label| {
        if (!std.mem.eql(u8, rate, @tagName(self._automation_rate))) {
            return idl.domError("InvalidStateError", try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to set the 'automationRate' property on 'AudioParam': {s}.automationRate is " ++
                    "fixed and cannot be changed to \"{s}\"",
                .{ label, rate },
            ), exec);
        }
        return;
    }
    idl.assignEnum(AutomationRate, &self._automation_rate, rate);
}

// The automation methods below all return the param so scripts can chain them.
// None of them move `value`, which is what Chrome does on a context that never
// ran: the events land on a timeline the render thread would walk, and with
// currentTime pinned at 0 nothing has been applied yet (measured —
// `pan.setValueAtTime(5, 0)` leaves `pan.value` at 0). `time` is validated the
// way Chrome validates it and then dropped.
//
// What they do move is the render, and that is what `_scheduled_start` and
// `_timeline_moves` carry. A single event at the very start of the render is
// still one constant — it is how Kasada sets the oscillator's frequency on
// x-hyatt — so it is recorded as the value a recorded render can be matched
// against. Everything else says the parameter is not a constant and no
// recording applies.

pub fn setValueAtTime(self: *AudioParam, value: f64, time: f64) !*AudioParam {
    try validateTime(time);
    if (time == 0) {
        self._scheduled_start = value;
    } else {
        self._timeline_moves = true;
    }
    return self;
}

pub fn linearRampToValueAtTime(self: *AudioParam, value: f64, time: f64) !*AudioParam {
    _ = value;
    try validateTime(time);
    self._timeline_moves = true;
    return self;
}

pub fn exponentialRampToValueAtTime(self: *AudioParam, value: f64, time: f64) !*AudioParam {
    try validateTime(time);
    // Chrome rejects a zero target for an exponential ramp.
    if (value == 0) {
        return error.RangeError;
    }
    self._timeline_moves = true;
    return self;
}

pub fn setTargetAtTime(self: *AudioParam, target: f64, start_time: f64, time_constant: f64) !*AudioParam {
    _ = target;
    try validateTime(start_time);
    if (time_constant < 0) {
        return error.RangeError;
    }
    self._timeline_moves = true;
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
    self._timeline_moves = true;
    return self;
}

// The two cancels take events off the timeline rather than putting any on, so
// they leave `_timeline_moves` alone: a cancel on a parameter that was only
// ever assigned is a no-op in Chrome, and marking it would turn a graph that
// renders into silence. A cancel *after* a ramp does not clear the flag, which
// errs the way the rest of this file errs — towards silence.
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

    // Chrome's own order: the five attributes first, then the seven automation
    // methods alphabetically (measured — Blink emits the methods sorted).
    pub const value = bridge.accessor(AudioParam.getValue, AudioParam.setValue, .{});
    pub const automationRate = bridge.accessor(AudioParam.getAutomationRate, AudioParam.setAutomationRate, .{});
    pub const defaultValue = bridge.accessor(AudioParam.getDefaultValue, null, .{});
    pub const minValue = bridge.accessor(AudioParam.getMinValue, null, .{});
    pub const maxValue = bridge.accessor(AudioParam.getMaxValue, null, .{});

    pub const cancelAndHoldAtTime = bridge.function(AudioParam.cancelAndHoldAtTime, .{});
    pub const cancelScheduledValues = bridge.function(AudioParam.cancelScheduledValues, .{});
    pub const exponentialRampToValueAtTime = bridge.function(AudioParam.exponentialRampToValueAtTime, .{});
    pub const linearRampToValueAtTime = bridge.function(AudioParam.linearRampToValueAtTime, .{});
    pub const setTargetAtTime = bridge.function(AudioParam.setTargetAtTime, .{});
    pub const setValueAtTime = bridge.function(AudioParam.setValueAtTime, .{});
    pub const setValueCurveAtTime = bridge.function(AudioParam.setValueCurveAtTime, .{});
};
