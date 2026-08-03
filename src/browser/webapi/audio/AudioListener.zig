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

// BaseAudioContext.listener. Nine AudioParams describing where the listener is
// and which way it faces; without a panner there is nothing downstream that
// reads them, so they are pure state.
//
// The nine defaults are the ones Chrome 150 reports (measured): the listener
// sits at the origin facing -Z with +Y up. Fingerprinting scripts that walk
// `for (k in ctx.listener)` see only objects here (AudioParams), which is why
// this type contributes prototype shape rather than values.

const js = @import("../../js/js.zig");
const AudioParam = @import("AudioParam.zig");

const Execution = js.Execution;

const AudioListener = @This();

// Each param is its own allocation rather than an inline struct: the bridge
// keys its JS-object identity map on the Zig pointer, and a struct field at
// offset zero shares its container's address — an inline `_position_x` came
// back from JS as the AudioListener itself.
_position_x: *AudioParam,
_position_y: *AudioParam,
_position_z: *AudioParam,
_forward_x: *AudioParam,
_forward_y: *AudioParam,
_forward_z: *AudioParam,
_up_x: *AudioParam,
_up_y: *AudioParam,
_up_z: *AudioParam,

pub fn init(exec: *Execution) !*AudioListener {
    const factory = exec._factory;
    return factory.create(AudioListener{
        ._position_x = try factory.create(AudioParam.init(0)),
        ._position_y = try factory.create(AudioParam.init(0)),
        ._position_z = try factory.create(AudioParam.init(0)),
        ._forward_x = try factory.create(AudioParam.init(0)),
        ._forward_y = try factory.create(AudioParam.init(0)),
        ._forward_z = try factory.create(AudioParam.init(-1)),
        ._up_x = try factory.create(AudioParam.init(0)),
        ._up_y = try factory.create(AudioParam.init(1)),
        ._up_z = try factory.create(AudioParam.init(0)),
    });
}

pub fn getPositionX(self: *AudioListener) *AudioParam {
    return self._position_x;
}

pub fn getPositionY(self: *AudioListener) *AudioParam {
    return self._position_y;
}

pub fn getPositionZ(self: *AudioListener) *AudioParam {
    return self._position_z;
}

pub fn getForwardX(self: *AudioListener) *AudioParam {
    return self._forward_x;
}

pub fn getForwardY(self: *AudioListener) *AudioParam {
    return self._forward_y;
}

pub fn getForwardZ(self: *AudioListener) *AudioParam {
    return self._forward_z;
}

pub fn getUpX(self: *AudioListener) *AudioParam {
    return self._up_x;
}

pub fn getUpY(self: *AudioListener) *AudioParam {
    return self._up_y;
}

pub fn getUpZ(self: *AudioListener) *AudioParam {
    return self._up_z;
}

// The two legacy setters, kept because they are still on Chrome's prototype.
pub fn setPosition(self: *AudioListener, x: f64, y: f64, z: f64) void {
    self._position_x._value = x;
    self._position_y._value = y;
    self._position_z._value = z;
}

pub fn setOrientation(self: *AudioListener, x: f64, y: f64, z: f64, up_x: f64, up_y: f64, up_z: f64) void {
    self._forward_x._value = x;
    self._forward_y._value = y;
    self._forward_z._value = z;
    self._up_x._value = up_x;
    self._up_y._value = up_y;
    self._up_z._value = up_z;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioListener);

    pub const Meta = struct {
        pub const name = "AudioListener";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const positionX = bridge.accessor(AudioListener.getPositionX, null, .{});
    pub const positionY = bridge.accessor(AudioListener.getPositionY, null, .{});
    pub const positionZ = bridge.accessor(AudioListener.getPositionZ, null, .{});
    pub const forwardX = bridge.accessor(AudioListener.getForwardX, null, .{});
    pub const forwardY = bridge.accessor(AudioListener.getForwardY, null, .{});
    pub const forwardZ = bridge.accessor(AudioListener.getForwardZ, null, .{});
    pub const upX = bridge.accessor(AudioListener.getUpX, null, .{});
    pub const upY = bridge.accessor(AudioListener.getUpY, null, .{});
    pub const upZ = bridge.accessor(AudioListener.getUpZ, null, .{});

    // Chrome puts setOrientation before setPosition (measured).
    pub const setOrientation = bridge.function(AudioListener.setOrientation, .{});
    pub const setPosition = bridge.function(AudioListener.setPosition, .{});
};
