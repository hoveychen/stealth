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

// The worker-side half of WebRTC Encoded Transform: the event a worker receives
// when a page hands it an RTCRtpScriptTransform, and the transformer that event
// carries. Both are [Exposed=Worker] *only* — a Chrome window has neither, and
// a Chrome DedicatedWorkerGlobalScope has exactly RTCTransformEvent,
// RTCRtpScriptTransformer, RTCDataChannel, RTCEncodedVideoFrame and
// RTCEncodedAudioFrame (measured; see
// tools/fingerprint/webrtc-worker-surface.mjs and
// /tmp/webrtc-worker-chrome.json).
//
// So these two types live in the worker API list, and are named directly in the
// master JsApis list in bridge.zig rather than reached through PageJsApis —
// they are the only interfaces here that a page must not see.
//
// Nothing ever fires the event: there is no encoded-transform pipeline. Both
// constructors throw "Illegal constructor", as Chrome's do.

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");

pub fn registerTypes() []const type {
    return &.{ RTCTransformEvent, RTCRtpScriptTransformer };
}

pub const RTCTransformEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    pub fn asEvent(self: *RTCTransformEvent) *Event {
        return self._proto;
    }

    pub fn getTransformer(_: *const RTCTransformEvent) ?*RTCRtpScriptTransformer {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCTransformEvent);

        pub const Meta = struct {
            pub const name = "RTCTransformEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const transformer = bridge.accessor(RTCTransformEvent.getTransformer, null, .{});
    };
};

pub const RTCRtpScriptTransformer = struct {
    pub fn getReadable(_: *const RTCRtpScriptTransformer) ?js.Value {
        return null;
    }

    pub fn getWritable(_: *const RTCRtpScriptTransformer) ?js.Value {
        return null;
    }

    pub fn getOptions(_: *const RTCRtpScriptTransformer) ?js.Value {
        return null;
    }

    pub fn sendKeyFrameRequest(_: *const RTCRtpScriptTransformer, exec: *const js.Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCRtpScriptTransformer);

        pub const Meta = struct {
            pub const name = "RTCRtpScriptTransformer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const readable = bridge.accessor(RTCRtpScriptTransformer.getReadable, null, .{});
        pub const writable = bridge.accessor(RTCRtpScriptTransformer.getWritable, null, .{});
        pub const options = bridge.accessor(RTCRtpScriptTransformer.getOptions, null, .{});
        pub const sendKeyFrameRequest = bridge.function(RTCRtpScriptTransformer.sendKeyFrameRequest, .{});
    };
};
