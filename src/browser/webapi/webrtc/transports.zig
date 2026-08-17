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

// The four EventTarget-derived RTC transport interfaces. Chrome only ever hands
// one of these out from a connection that has actually negotiated (pc.sctp, a
// sender's .transport / .dtmf), and this engine negotiates nothing — so no
// instance is ever produced. They exist because the *constructors* are what a
// fingerprinting script sees: `Object.getOwnPropertyNames(window)` is read
// directly by CreepJS, and a window that has RTCPeerConnection but not
// RTCDtlsTransport is not a shape any real Chrome has.
//
// Everything below was read off a headed Chrome 150
// (/tmp/webrtc-protochain-chrome.json, agent-workspace/stealth-detector-probes/
// webrtc-protochain.mjs): the prototype member set, the accessor/method split,
// each method's arity, the EventTarget prototype link, and the fact that `new`
// on any of them throws "Illegal constructor" — which is what omitting a
// `constructor` decl gets us here.

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

pub fn registerTypes() []const type {
    return &.{ RTCDtlsTransport, RTCIceTransport, RTCSctpTransport, RTCDTMFSender };
}

pub const RTCDtlsTransport = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *RTCDtlsTransport) *EventTarget {
        return self._proto;
    }

    pub fn getIceTransport(_: *const RTCDtlsTransport) ?*RTCIceTransport {
        return null;
    }

    pub fn getState(_: *const RTCDtlsTransport) []const u8 {
        return "new";
    }

    pub fn getRemoteCertificates(_: *const RTCDtlsTransport) []const js.Value {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDtlsTransport);

        pub const Meta = struct {
            pub const name = "RTCDtlsTransport";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const iceTransport = bridge.accessor(RTCDtlsTransport.getIceTransport, null, .{});
        pub const state = bridge.accessor(RTCDtlsTransport.getState, null, .{});
        pub const onstatechange = bridge.accessor(handlerProperty(RTCDtlsTransport, .onstatechange).get, handlerProperty(RTCDtlsTransport, .onstatechange).set, .{});
        pub const onerror = bridge.accessor(handlerProperty(RTCDtlsTransport, .onerror).get, handlerProperty(RTCDtlsTransport, .onerror).set, .{});
        pub const getRemoteCertificates = bridge.function(RTCDtlsTransport.getRemoteCertificates, .{});
    };
};

pub const RTCIceTransport = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *RTCIceTransport) *EventTarget {
        return self._proto;
    }

    pub fn getRole(_: *const RTCIceTransport) []const u8 {
        return "unknown";
    }

    pub fn getState(_: *const RTCIceTransport) []const u8 {
        return "new";
    }

    pub fn getGatheringState(_: *const RTCIceTransport) []const u8 {
        return "new";
    }

    pub fn getLocalCandidates(_: *const RTCIceTransport) []const js.Value {
        return &.{};
    }

    pub fn getRemoteCandidates(_: *const RTCIceTransport) []const js.Value {
        return &.{};
    }

    pub fn getLocalParameters(_: *const RTCIceTransport) ?js.Value {
        return null;
    }

    pub fn getRemoteParameters(_: *const RTCIceTransport) ?js.Value {
        return null;
    }

    pub fn getSelectedCandidatePair(_: *const RTCIceTransport) ?js.Value {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCIceTransport);

        pub const Meta = struct {
            pub const name = "RTCIceTransport";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const role = bridge.accessor(RTCIceTransport.getRole, null, .{});
        pub const state = bridge.accessor(RTCIceTransport.getState, null, .{});
        pub const gatheringState = bridge.accessor(RTCIceTransport.getGatheringState, null, .{});
        pub const onstatechange = bridge.accessor(handlerProperty(RTCIceTransport, .onstatechange).get, handlerProperty(RTCIceTransport, .onstatechange).set, .{});
        pub const ongatheringstatechange = bridge.accessor(handlerProperty(RTCIceTransport, .ongatheringstatechange).get, handlerProperty(RTCIceTransport, .ongatheringstatechange).set, .{});
        pub const onselectedcandidatepairchange = bridge.accessor(handlerProperty(RTCIceTransport, .onselectedcandidatepairchange).get, handlerProperty(RTCIceTransport, .onselectedcandidatepairchange).set, .{});
        pub const getLocalCandidates = bridge.function(RTCIceTransport.getLocalCandidates, .{});
        pub const getLocalParameters = bridge.function(RTCIceTransport.getLocalParameters, .{});
        pub const getRemoteCandidates = bridge.function(RTCIceTransport.getRemoteCandidates, .{});
        pub const getRemoteParameters = bridge.function(RTCIceTransport.getRemoteParameters, .{});
        pub const getSelectedCandidatePair = bridge.function(RTCIceTransport.getSelectedCandidatePair, .{});
    };
};

pub const RTCSctpTransport = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *RTCSctpTransport) *EventTarget {
        return self._proto;
    }

    pub fn getTransport(_: *const RTCSctpTransport) ?*RTCDtlsTransport {
        return null;
    }

    pub fn getState(_: *const RTCSctpTransport) []const u8 {
        return "connecting";
    }

    // Chrome reports this as a double, so it must not go through an i64 (which
    // the bridge would hand back as a BigInt).
    pub fn getMaxMessageSize(_: *const RTCSctpTransport) f64 {
        return 0;
    }

    pub fn getMaxChannels(_: *const RTCSctpTransport) ?u32 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCSctpTransport);

        pub const Meta = struct {
            pub const name = "RTCSctpTransport";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const transport = bridge.accessor(RTCSctpTransport.getTransport, null, .{});
        pub const state = bridge.accessor(RTCSctpTransport.getState, null, .{});
        pub const maxMessageSize = bridge.accessor(RTCSctpTransport.getMaxMessageSize, null, .{});
        pub const maxChannels = bridge.accessor(RTCSctpTransport.getMaxChannels, null, .{});
        pub const onstatechange = bridge.accessor(handlerProperty(RTCSctpTransport, .onstatechange).get, handlerProperty(RTCSctpTransport, .onstatechange).set, .{});
    };
};

pub const RTCDTMFSender = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *RTCDTMFSender) *EventTarget {
        return self._proto;
    }

    pub fn getCanInsertDTMF(_: *const RTCDTMFSender) bool {
        return false;
    }

    pub fn getToneBuffer(_: *const RTCDTMFSender) []const u8 {
        return "";
    }

    pub fn insertDTMF(_: *RTCDTMFSender, _: []const u8, _: ?u32, _: ?u32) !void {
        return error.InvalidStateError;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDTMFSender);

        pub const Meta = struct {
            pub const name = "RTCDTMFSender";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Declaration order is the order Object.getOwnPropertyNames() reports,
        // and Chrome's is ontonechange first (measured).
        pub const ontonechange = bridge.accessor(handlerProperty(RTCDTMFSender, .ontonechange).get, handlerProperty(RTCDTMFSender, .ontonechange).set, .{});
        pub const canInsertDTMF = bridge.accessor(RTCDTMFSender.getCanInsertDTMF, null, .{});
        pub const toneBuffer = bridge.accessor(RTCDTMFSender.getToneBuffer, null, .{});
        pub const insertDTMF = bridge.function(RTCDTMFSender.insertDTMF, .{});
    };
};
