// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// The two encoded-media frame types from WebRTC Encoded Transform. Both are
// [Exposed=(Window,Worker)] — measured: a Chrome worker's `self` has exactly
// RTCTransformEvent / RTCRtpScriptTransformer / RTCDataChannel /
// RTCEncodedVideoFrame / RTCEncodedAudioFrame.
//
// Their constructors take an *existing* frame to clone, so on a page that has
// no media pipeline they can never succeed. Chrome answers the same shape for
// junk input — "parameter 1 is not of type 'RTCEncodedAudioFrame'", a TypeError
// — so the constructor here throws TypeError unconditionally. What matters is
// that it is arity 1 and that the global exists at all; a window carrying
// RTCPeerConnection but no RTCEncodedAudioFrame is not a Chrome shape.
//
// Prototype members, arities and the "1 argument required" arity error were all
// read off a headed Chrome 150 (/tmp/webrtc-protochain-chrome.json).

const js = @import("../../js/js.zig");

pub fn registerTypes() []const type {
    return &.{ RTCEncodedAudioFrame, RTCEncodedVideoFrame };
}

pub const RTCEncodedAudioFrame = struct {
    // Always throws: there is no frame to clone. Kept non-optional so the
    // constructor reports length 1, the way Chrome's does.
    pub fn init(_: js.Value) !*RTCEncodedAudioFrame {
        return error.TypeError;
    }

    pub fn getTimestamp(_: *const RTCEncodedAudioFrame) u32 {
        return 0;
    }

    pub fn getData(_: *const RTCEncodedAudioFrame) ?js.Value {
        return null;
    }

    pub fn setData(_: *RTCEncodedAudioFrame, _: ?js.Value) void {}

    pub fn getMetadata(_: *const RTCEncodedAudioFrame) ?js.Value {
        return null;
    }

    pub fn toString(_: *const RTCEncodedAudioFrame) []const u8 {
        return "RTCEncodedAudioFrame";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCEncodedAudioFrame);

        pub const Meta = struct {
            pub const name = "RTCEncodedAudioFrame";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const constructor = bridge.constructor(RTCEncodedAudioFrame.init, .{});
        pub const timestamp = bridge.accessor(RTCEncodedAudioFrame.getTimestamp, null, .{});
        pub const data = bridge.accessor(RTCEncodedAudioFrame.getData, RTCEncodedAudioFrame.setData, .{});
        pub const getMetadata = bridge.function(RTCEncodedAudioFrame.getMetadata, .{});
        pub const toString = bridge.function(RTCEncodedAudioFrame.toString, .{});
    };
};

pub const RTCEncodedVideoFrame = struct {
    pub fn init(_: js.Value) !*RTCEncodedVideoFrame {
        return error.TypeError;
    }

    pub fn getType(_: *const RTCEncodedVideoFrame) []const u8 {
        return "empty";
    }

    pub fn getTimestamp(_: *const RTCEncodedVideoFrame) u32 {
        return 0;
    }

    pub fn getData(_: *const RTCEncodedVideoFrame) ?js.Value {
        return null;
    }

    pub fn setData(_: *RTCEncodedVideoFrame, _: ?js.Value) void {}

    pub fn getMetadata(_: *const RTCEncodedVideoFrame) ?js.Value {
        return null;
    }

    pub fn toString(_: *const RTCEncodedVideoFrame) []const u8 {
        return "RTCEncodedVideoFrame";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCEncodedVideoFrame);

        pub const Meta = struct {
            pub const name = "RTCEncodedVideoFrame";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const constructor = bridge.constructor(RTCEncodedVideoFrame.init, .{});
        pub const @"type" = bridge.accessor(RTCEncodedVideoFrame.getType, null, .{});
        pub const timestamp = bridge.accessor(RTCEncodedVideoFrame.getTimestamp, null, .{});
        pub const data = bridge.accessor(RTCEncodedVideoFrame.getData, RTCEncodedVideoFrame.setData, .{});
        pub const getMetadata = bridge.function(RTCEncodedVideoFrame.getMetadata, .{});
        pub const toString = bridge.function(RTCEncodedVideoFrame.toString, .{});
    };
};
