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

// navigator.mediaDevices.
//
// There is no media stack behind this: getUserMedia and getDisplayMedia reject,
// which is also what a real Chrome does when the user refuses permission. What
// matters for a Chrome-shaped navigator is that the object and its seven members
// exist, and that enumerateDevices() answers the way Chrome answers *before*
// permission is granted.
//
// That last part is the interesting one, and it is measured rather than
// guessed. Asked without camera or microphone permission, Chrome 150 on the
// reference machine did not return an empty list — it returned three entries
// with every identifying field blanked:
//
//   audioinput  InputDeviceInfo  deviceId "" label "" groupId ""
//   videoinput  InputDeviceInfo  deviceId "" label "" groupId ""
//   audiooutput MediaDeviceInfo  deviceId "" label "" groupId ""
//
// So the permission-gated shape reveals *that* devices exist without saying
// which, and reporting zero devices is the thing that stands out: it is what a
// machine with no camera and no microphone looks like, and fingerprinting
// scripts read a device count of 0 as a headless signal.

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ MediaDevices, MediaDeviceInfo, InputDeviceInfo };
}

const MediaDevices = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_devicechange: ?js.Function.Global = null,

// Built on the first enumerateDevices(). Most pages never ask, and building
// three objects per frame for an API nobody called would be waste.
_devices: ?Devices = null,

const Devices = struct {
    audio_input: *InputDeviceInfo,
    video_input: *InputDeviceInfo,
    audio_output: *MediaDeviceInfo,
};

pub fn asEventTarget(self: *MediaDevices) *EventTarget {
    return self._proto;
}

pub fn enumerateDevices(self: *MediaDevices, exec: *const Execution) !js.Promise {
    // Window-only, so the global is always a Frame.
    const frame = exec.js.global.frame;
    const devices = self._devices orelse blk: {
        const built = Devices{
            .audio_input = try inputDevice(frame, "audioinput"),
            .video_input = try inputDevice(frame, "videoinput"),
            .audio_output = try frame._factory.create(MediaDeviceInfo{
                ._kind = "audiooutput",
            }),
        };
        self._devices = built;
        break :blk built;
    };

    // Chrome's order: audio in, video in, audio out.
    return exec.js.local.?.resolvePromise(.{
        devices.audio_input,
        devices.video_input,
        devices.audio_output,
    });
}

fn inputDevice(frame: *Frame, kind: []const u8) !*InputDeviceInfo {
    return frame._factory.chained(.{
        MediaDeviceInfo{ ._kind = kind },
        InputDeviceInfo{ ._proto = undefined },
    });
}

// No permission, so both reject. Chrome uses NotAllowedError for a refusal,
// which is indistinguishable from a user who clicked "Block".
pub fn getUserMedia(_: *MediaDevices, _: ?js.Value, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
}

pub fn getDisplayMedia(_: *MediaDevices, _: ?js.Value, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
}

// Every constraint Chrome 150 lists, all of them true — the dictionary only
// carries the supported ones, so presence *is* the answer. Measured, and in
// Chrome's own key order.
pub fn getSupportedConstraints(_: *MediaDevices) SupportedConstraints {
    return .{};
}

pub fn setCaptureHandleConfig(_: *MediaDevices, _: ?js.Value) void {}

// Nothing ever fires devicechange — the list doesn't move — but the handler is
// on Chrome's prototype and its absence would show up in an enumeration.
pub fn getOnDeviceChange(self: *MediaDevices) ?js.Function.Global {
    return self._on_devicechange;
}

pub fn setOnDeviceChange(self: *MediaDevices, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_devicechange = try listen.persistWithThis(self);
    } else {
        self._on_devicechange = null;
    }
}

const SupportedConstraints = struct {
    width: bool = true,
    height: bool = true,
    aspectRatio: bool = true,
    frameRate: bool = true,
    facingMode: bool = true,
    resizeMode: bool = true,
    sampleRate: bool = true,
    sampleSize: bool = true,
    echoCancellation: bool = true,
    autoGainControl: bool = true,
    noiseSuppression: bool = true,
    voiceIsolation: bool = true,
    latency: bool = true,
    channelCount: bool = true,
    deviceId: bool = true,
    groupId: bool = true,
    whiteBalanceMode: bool = true,
    exposureMode: bool = true,
    focusMode: bool = true,
    pointsOfInterest: bool = true,
    exposureCompensation: bool = true,
    exposureTime: bool = true,
    colorTemperature: bool = true,
    iso: bool = true,
    brightness: bool = true,
    contrast: bool = true,
    pan: bool = true,
    saturation: bool = true,
    sharpness: bool = true,
    focusDistance: bool = true,
    tilt: bool = true,
    zoom: bool = true,
    torch: bool = true,
    displaySurface: bool = true,
    suppressLocalAudioPlayback: bool = true,
    restrictOwnAudio: bool = true,
};

// One entry of enumerateDevices(). Everything but `kind` is blank, which is
// what Chrome reports until the page holds a media permission.
pub const MediaDeviceInfo = struct {
    _kind: []const u8,

    pub fn getDeviceId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    pub fn getGroupId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    pub fn getKind(self: *const MediaDeviceInfo) []const u8 {
        return self._kind;
    }

    pub fn getLabel(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    // Chrome's key order here is deviceId, kind, label, groupId — not the
    // prototype's alphabetical one.
    pub fn toJSON(self: *const MediaDeviceInfo) struct {
        deviceId: []const u8,
        kind: []const u8,
        label: []const u8,
        groupId: []const u8,
    } {
        return .{
            .deviceId = "",
            .kind = self._kind,
            .label = "",
            .groupId = "",
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaDeviceInfo);

        pub const Meta = struct {
            pub const name = "MediaDeviceInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const deviceId = bridge.accessor(MediaDeviceInfo.getDeviceId, null, .{});
        pub const groupId = bridge.accessor(MediaDeviceInfo.getGroupId, null, .{});
        pub const kind = bridge.accessor(MediaDeviceInfo.getKind, null, .{});
        pub const label = bridge.accessor(MediaDeviceInfo.getLabel, null, .{});
        pub const toJSON = bridge.function(MediaDeviceInfo.toJSON, .{});
    };
};

// The audio and video *inputs* are InputDeviceInfo, a MediaDeviceInfo subclass
// whose only addition is getCapabilities(). Without permission it reports an
// empty dictionary.
pub const InputDeviceInfo = struct {
    pub const Proto = MediaDeviceInfo;

    _proto: *MediaDeviceInfo,

    pub fn getCapabilities(_: *const InputDeviceInfo) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(InputDeviceInfo);

        pub const Meta = struct {
            pub const name = "InputDeviceInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = MediaDeviceInfo;

        pub const getCapabilities = bridge.function(InputDeviceInfo.getCapabilities, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaDevices);

    pub const Meta = struct {
        pub const name = "MediaDevices";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const enumerateDevices = bridge.function(MediaDevices.enumerateDevices, .{});
    pub const getUserMedia = bridge.function(MediaDevices.getUserMedia, .{});
    pub const getDisplayMedia = bridge.function(MediaDevices.getDisplayMedia, .{});
    pub const getSupportedConstraints = bridge.function(MediaDevices.getSupportedConstraints, .{});
    pub const setCaptureHandleConfig = bridge.function(MediaDevices.setCaptureHandleConfig, .{});
    pub const ondevicechange = bridge.accessor(MediaDevices.getOnDeviceChange, MediaDevices.setOnDeviceChange, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaDevices" {
    try testing.htmlRunner("media_devices.html", .{});
}
