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
const UIEvent = @import("UIEvent.zig");
const touch = @import("touch.zig");

const Touch = touch.Touch;
const TouchList = touch.TouchList;

const String = lp.String;

// https://w3c.github.io/touch-events/#touchevent-interface
// There is no touch input source, so an event the engine fires carries three
// empty lists -- but they are TouchLists now, not JS Arrays, and a page that
// passes touches in the dictionary gets them back (measured on Chrome 150).
const TouchEvent = @This();

pub const Proto = UIEvent;

_proto: *UIEvent,
_alt_key: bool = false,
_meta_key: bool = false,
_ctrl_key: bool = false,
_shift_key: bool = false,
_touches: *TouchList,
_target_touches: *TouchList,
_changed_touches: *TouchList,

pub const TouchEventOptions = struct {
    // Two IDL levels in one Zig struct: EventModifierInit's members first, then
    // TouchEventInit's own, each group alphabetical -- which is the order Web
    // IDL reads them in.
    js_grouped_dictionary: void = {},

    // EventModifierInit.
    altKey: bool = false,
    ctrlKey: bool = false,
    metaKey: bool = false,
    shiftKey: bool = false,

    // TouchEventInit.
    changedTouches: ?[]const *Touch = null,
    targetTouches: ?[]const *Touch = null,
    touches: ?[]const *Touch = null,
};

pub const Options = Event.inheritOptions(
    TouchEvent,
    TouchEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*TouchEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*TouchEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, frame: *Frame) !*TouchEvent {
    const arena = try frame.getArena(.tiny, "TouchEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.uiEvent(
        arena,
        type_string,
        TouchEvent{
            ._proto = undefined,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._touches = try touchList(opts.touches, frame),
            ._target_touches = try touchList(opts.targetTouches, frame),
            ._changed_touches = try touchList(opts.changedTouches, frame),
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *TouchEvent) *Event {
    return self._proto.asEvent();
}

// The sequence arrives on the call arena, which is gone by the time a script
// reads the list back, so the touches are copied onto the frame arena first.
fn touchList(touches_: ?[]const *Touch, frame: *Frame) !*TouchList {
    const touches = touches_ orelse return frame._factory.create(TouchList{});
    return frame._factory.create(TouchList{ ._touches = try frame.arena.dupe(*Touch, touches) });
}

pub fn getTouches(self: *const TouchEvent) *TouchList {
    return self._touches;
}

pub fn getTargetTouches(self: *const TouchEvent) *TouchList {
    return self._target_touches;
}

pub fn getChangedTouches(self: *const TouchEvent) *TouchList {
    return self._changed_touches;
}

pub fn getAltKey(self: *const TouchEvent) bool {
    return self._alt_key;
}

pub fn getMetaKey(self: *const TouchEvent) bool {
    return self._meta_key;
}

pub fn getCtrlKey(self: *const TouchEvent) bool {
    return self._ctrl_key;
}

pub fn getShiftKey(self: *const TouchEvent) bool {
    return self._shift_key;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TouchEvent);

    pub const Meta = struct {
        pub const name = "TouchEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TouchEvent.init, .{});
    pub const touches = bridge.accessor(TouchEvent.getTouches, null, .{});
    pub const targetTouches = bridge.accessor(TouchEvent.getTargetTouches, null, .{});
    pub const changedTouches = bridge.accessor(TouchEvent.getChangedTouches, null, .{});
    pub const altKey = bridge.accessor(TouchEvent.getAltKey, null, .{});
    pub const metaKey = bridge.accessor(TouchEvent.getMetaKey, null, .{});
    pub const ctrlKey = bridge.accessor(TouchEvent.getCtrlKey, null, .{});
    pub const shiftKey = bridge.accessor(TouchEvent.getShiftKey, null, .{});
};
