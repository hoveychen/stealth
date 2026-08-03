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

// The certificate object RTCPeerConnection.generateCertificate() resolves with.
// This engine never generates one, so only the constructor and its prototype
// are reachable — which is the point: CreepJS reads
// Object.getOwnPropertyNames(window) directly, and RTCCertificate is one of the
// 24 RTC* names a real Chrome has there.
//
// Shape measured on a headed Chrome 150 (/tmp/webrtc-protochain-chrome.json):
// rooted at Object, two prototype members, and `new RTCCertificate()` throws
// "Illegal constructor" — which omitting a `constructor` decl gets us here.

const js = @import("../../js/js.zig");

const RTCCertificate = @This();

pub fn getExpires(_: *const RTCCertificate) f64 {
    return 0;
}

pub fn getFingerprints(_: *const RTCCertificate) []const js.Value {
    return &.{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCCertificate);

    pub const Meta = struct {
        pub const name = "RTCCertificate";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const expires = bridge.accessor(RTCCertificate.getExpires, null, .{});
    pub const getFingerprints = bridge.function(RTCCertificate.getFingerprints, .{});
};
