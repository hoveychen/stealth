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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const MouseEvent = @import("MouseEvent.zig");

const String = lp.String;

const WheelEvent = @This();

pub const Proto = MouseEvent;

_proto: *MouseEvent,
_delta_x: f64,
_delta_y: f64,
_delta_z: f64,
_delta_mode: u32,
_wheel_delta_x: f64,
_wheel_delta_y: f64,
_momentum: bool,

pub const DOM_DELTA_PIXEL: u32 = 0x00;
pub const DOM_DELTA_LINE: u32 = 0x01;
pub const DOM_DELTA_PAGE: u32 = 0x02;

pub const WheelEventOptions = struct {
    // Alphabetical: a dictionary's members are read in that order, and the
    // reads are observable. The two legacy pairs are optional so that
    // "absent" is distinguishable from "0" -- they only fill in a delta that
    // was never given. See Deltas.
    deltaMode: u32 = 0,
    deltaX: ?f64 = null,
    deltaY: ?f64 = null,
    deltaZ: f64 = 0.0,
    momentum: bool = false,
    wheelDeltaX: ?f64 = null,
    wheelDeltaY: ?f64 = null,
};

// Each axis is two members that fill each other's gaps, and only one of the
// two directions flips the sign. Measured on a constructed Chrome 151 event,
// both axes, both signs, all three deltaModes:
//
//   {deltaY: 10}                 -> deltaY  10, wheelDeltaY 10  (no flip)
//   {wheelDeltaY: 2}             -> deltaY  -2, wheelDeltaY  2  (the flip)
//   {deltaY: 10, wheelDeltaY: 2} -> deltaY  10, wheelDeltaY  2  (neither fills)
//
// So a given value is always kept, and only a *missing* delta is derived --
// which is why both halves have to be optional rather than defaulted to zero.
// deltaMode never scales either value; the 120-per-notch factor real Chrome
// puts on a trusted wheel event is not applied to a synthesised one.
const Deltas = struct {
    delta: f64,
    wheel_delta: f64,

    fn derive(delta: ?f64, wheel_delta: ?f64) Deltas {
        return .{
            .delta = delta orelse if (wheel_delta) |wd| -wd else 0,
            .wheel_delta = wheel_delta orelse delta orelse 0,
        };
    }
};

pub const Options = Event.inheritOptions(
    WheelEvent,
    WheelEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*WheelEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*WheelEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, frame: *Frame) !*WheelEvent {
    const arena = try frame.getArena(.medium, "WheelEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = _opts orelse Options{};
    const x = Deltas.derive(opts.deltaX, opts.wheelDeltaX);
    const y = Deltas.derive(opts.deltaY, opts.wheelDeltaY);

    const event = try frame._factory.mouseEvent(
        arena,
        type_string,
        MouseEvent{
            ._type = .{ .wheel_event = undefined },
            ._proto = undefined,
            ._screen_x = opts.screenX,
            ._screen_y = opts.screenY,
            ._client_x = opts.clientX,
            ._client_y = opts.clientY,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._button = @truncate(opts.button),
            ._buttons = opts.buttons,
            ._related_target = opts.relatedTarget,
            ._movement_x = opts.movementX,
            ._movement_y = opts.movementY,
        },
        WheelEvent{
            ._proto = undefined,
            ._delta_x = x.delta,
            ._delta_y = y.delta,
            ._delta_z = opts.deltaZ,
            ._delta_mode = opts.deltaMode,
            ._wheel_delta_x = x.wheel_delta,
            ._wheel_delta_y = y.wheel_delta,
            ._momentum = opts.momentum,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *WheelEvent) *Event {
    return self._proto.asEvent();
}

pub fn getDeltaX(self: *const WheelEvent) f64 {
    return self._delta_x;
}

pub fn getDeltaY(self: *const WheelEvent) f64 {
    return self._delta_y;
}

pub fn getDeltaZ(self: *const WheelEvent) f64 {
    return self._delta_z;
}

pub fn getDeltaMode(self: *const WheelEvent) u32 {
    return self._delta_mode;
}

pub fn getWheelDeltaX(self: *const WheelEvent) f64 {
    return self._wheel_delta_x;
}

pub fn getWheelDeltaY(self: *const WheelEvent) f64 {
    return self._wheel_delta_y;
}

// The single-axis reading: Y unless Y is exactly zero, then X. Measured on
// {deltaX: 3, deltaY: 7} -> 7 and {deltaX: 5} -> 5.
pub fn getWheelDelta(self: *const WheelEvent) f64 {
    if (self._wheel_delta_y != 0) return self._wheel_delta_y;
    return self._wheel_delta_x;
}

pub fn getMomentum(self: *const WheelEvent) bool {
    return self._momentum;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WheelEvent);

    pub const Meta = struct {
        pub const name = "WheelEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(WheelEvent.init, .{});
    pub const deltaX = bridge.accessor(WheelEvent.getDeltaX, null, .{});
    pub const deltaY = bridge.accessor(WheelEvent.getDeltaY, null, .{});
    pub const deltaZ = bridge.accessor(WheelEvent.getDeltaZ, null, .{});
    pub const deltaMode = bridge.accessor(WheelEvent.getDeltaMode, null, .{});
    pub const wheelDeltaX = bridge.accessor(WheelEvent.getWheelDeltaX, null, .{});
    pub const wheelDeltaY = bridge.accessor(WheelEvent.getWheelDeltaY, null, .{});
    pub const wheelDelta = bridge.accessor(WheelEvent.getWheelDelta, null, .{});
    pub const DOM_DELTA_PIXEL = bridge.property(WheelEvent.DOM_DELTA_PIXEL, .{ .template = true });
    pub const DOM_DELTA_LINE = bridge.property(WheelEvent.DOM_DELTA_LINE, .{ .template = true });
    pub const DOM_DELTA_PAGE = bridge.property(WheelEvent.DOM_DELTA_PAGE, .{ .template = true });
    pub const momentum = bridge.accessor(WheelEvent.getMomentum, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: WheelEvent" {
    try testing.htmlRunner("event/wheel.html", .{});
}
