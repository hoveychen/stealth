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

// What `uiEvent.sourceCapabilities` would describe: whether the device that
// produced an event also fires touch events. Constructible with a one-member
// dictionary, and that is the whole interface.
//
// Measured on a headed Chrome 150 (probe-win28/29/36): firesTouchEvents defaults
// to false, an init dictionary sets it, and a non-dictionary argument is "The
// provided value is not of type 'InputDeviceCapabilitiesInit'." No UIEvent here
// carries one -- Chrome's own `new UIEvent('click').sourceCapabilities` is null.

const js = @import("../js/js.zig");

const Execution = js.Execution;

const InputDeviceCapabilities = @This();

_fires_touch_events: bool = false,

pub fn constructor(options_: ?js.Value, exec: *const Execution) !*InputDeviceCapabilities {
    var fires_touch_events = false;
    if (options_) |options| {
        if (!options.isNullOrUndefined()) {
            if (!options.isObject()) {
                const isolate = exec.js.isolate;
                _ = isolate.throwException(isolate.createTypeError(
                    "Failed to construct 'InputDeviceCapabilities': The provided value is not of type 'InputDeviceCapabilitiesInit'.",
                ));
                return error.JsException;
            }
            const member = try options.toObject().get("firesTouchEvents");
            if (!member.isUndefined()) {
                fires_touch_events = member.toBool();
            }
        }
    }

    return exec.page.factory.create(InputDeviceCapabilities{ ._fires_touch_events = fires_touch_events });
}

pub fn getFiresTouchEvents(self: *const InputDeviceCapabilities) bool {
    return self._fires_touch_events;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(InputDeviceCapabilities);

    pub const Meta = struct {
        pub const name = "InputDeviceCapabilities";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(InputDeviceCapabilities.constructor, .{ .arity = 0 });
    pub const firesTouchEvents = bridge.accessor(InputDeviceCapabilities.getFiresTouchEvents, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: InputDeviceCapabilities" {
    try testing.htmlRunner("input_device_capabilities.html", .{});
}
