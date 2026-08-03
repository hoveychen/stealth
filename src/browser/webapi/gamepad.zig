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

//! The three Gamepad interfaces behind `navigator.getGamepads()`.
//!
//! Nothing is ever plugged in — Chrome itself answers `[null, null, null, null]`
//! on a machine with no pad (measured), and `GamepadEvent.gamepad` is the only
//! other route to an instance, which nothing dispatches here. So all three are
//! shape only: the classes exist because CreepJS counts the globals and
//! browserleaks walks their prototypes, and the values below are what a pad
//! would report if one arrived.
//!
//! Shapes measured on a headed Chrome 150 (win20-chrome.json).

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{
        Gamepad,
        GamepadButton,
        GamepadHapticActuator,
    };
}

pub const Gamepad = struct {
    _pad: bool = false,

    fn empty(_: *const Gamepad) []const u8 {
        return "";
    }

    fn zero(_: *const Gamepad) u32 {
        return 0;
    }

    fn timestamp(_: *const Gamepad) f64 {
        return 0;
    }

    fn connected(_: *const Gamepad) bool {
        return false;
    }

    fn axes(_: *const Gamepad) []const f64 {
        return &.{};
    }

    fn buttons(_: *const Gamepad) []const *GamepadButton {
        return &.{};
    }

    fn actuator(_: *const Gamepad) ?*GamepadHapticActuator {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Gamepad);

        pub const Meta = struct {
            pub const name = "Gamepad";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const G = Gamepad;

        pub const id = bridge.accessor(G.empty, null, .{});
        pub const index = bridge.accessor(G.zero, null, .{});
        pub const connected = bridge.accessor(G.connected, null, .{});
        pub const timestamp = bridge.accessor(G.timestamp, null, .{});
        pub const mapping = bridge.accessor(G.empty, null, .{});
        pub const axes = bridge.accessor(G.axes, null, .{});
        pub const buttons = bridge.accessor(G.buttons, null, .{});
        pub const vibrationActuator = bridge.accessor(G.actuator, null, .{});
    };
};

pub const GamepadButton = struct {
    _pad: bool = false,

    fn off(_: *const GamepadButton) bool {
        return false;
    }

    fn zero(_: *const GamepadButton) f64 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GamepadButton);

        pub const Meta = struct {
            pub const name = "GamepadButton";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const pressed = bridge.accessor(GamepadButton.off, null, .{});
        pub const touched = bridge.accessor(GamepadButton.off, null, .{});
        pub const value = bridge.accessor(GamepadButton.zero, null, .{});
    };
};

pub const GamepadHapticActuator = struct {
    _pad: bool = false,

    fn effects(_: *const GamepadHapticActuator) []const []const u8 {
        return &.{};
    }

    fn @"type"(_: *const GamepadHapticActuator) []const u8 {
        return "dual-rumble";
    }

    fn playEffect(_: *GamepadHapticActuator, _: ?js.Value, _: ?js.Value, exec: *const js.Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as([]const u8, "preempted"));
    }

    fn reset(_: *GamepadHapticActuator, exec: *const js.Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as([]const u8, "preempted"));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GamepadHapticActuator);

        pub const Meta = struct {
            pub const name = "GamepadHapticActuator";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const A = GamepadHapticActuator;

        pub const effects = bridge.accessor(A.effects, null, .{});
        pub const @"type" = bridge.accessor(A.type, null, .{});
        pub const playEffect = bridge.function(A.playEffect, .{ .arity = 2 });
        pub const reset = bridge.function(A.reset, .{});
    };
};
