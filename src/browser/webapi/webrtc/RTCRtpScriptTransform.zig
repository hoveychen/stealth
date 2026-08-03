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

// The handle a page assigns to sender.transform / receiver.transform to route
// encoded frames through a worker. It is constructible in Chrome — it only
// needs a Worker — and the object it returns carries nothing but `constructor`
// on its prototype (measured on a headed Chrome 150,
// /tmp/webrtc-protochain-chrome.json). So the whole interface is: take a
// Worker, hand back an inert object.
//
// Nothing consumes it: there is no encoded-transform pipeline here, and the
// `transform` setters on RTCRtpSender/RTCRtpReceiver discard what they are
// given. This exists because Object.getOwnPropertyNames(window) is read
// directly by CreepJS and RTCRtpScriptTransform is one of the 24 RTC* names a
// real Chrome window has.
//
// [Exposed=Window] only — a worker gets RTCRtpScriptTransformer (the other
// half of the pair) instead, so this stays out of the worker scope list.

const js = @import("../../js/js.zig");

const Worker = @import("../Worker.zig");

const RTCRtpScriptTransform = @This();

// `options` and `transfer` are optional, so the constructor reports length 1 —
// the arity Chrome reports. The Worker is required and unused: passing
// anything else is the TypeError Chrome answers with too.
pub fn init(_: *Worker, _: ?js.Value, _: ?[]const js.Value) RTCRtpScriptTransform {
    return .{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCRtpScriptTransform);

    pub const Meta = struct {
        pub const name = "RTCRtpScriptTransform";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(RTCRtpScriptTransform.init, .{});
};
