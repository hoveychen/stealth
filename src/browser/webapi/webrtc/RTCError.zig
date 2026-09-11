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

// The one RTC interface that is not rooted at Object or EventTarget: Chrome
// puts RTCError.prototype on top of DOMException.prototype, so the chain reads
// RTCError -> DOMException -> Error -> Object (measured on a headed Chrome 150,
// /tmp/webrtc-protochain-chrome.json). It is also the only member of the RTC
// family this engine can construct for real, so the values below are the
// measured ones rather than placeholders:
//
//   new RTCError({errorDetail: 'data-channel-failure'})
//     -> name "OperationError", message "", code 0, every numeric member null
//   new RTCError({errorDetail: 'sdp-syntax-error', sdpLineNumber: 7, ...}, 'boom')
//     -> message "boom", each numeric member round-trips
//   new RTCError()                    -> TypeError (1 argument required)
//   new RTCError({errorDetail: 'nope'}) -> TypeError (not a valid enum value)
//
// Nothing in the engine raises one — no connection ever fails, because none is
// ever established. It is here because Object.getOwnPropertyNames(window) is
// read directly by CreepJS, and because RTCErrorEvent's required `error`
// member needs a type to accept.

const std = @import("std");

const js = @import("../../js/js.zig");

const DOMException = @import("../DOMException.zig");

const Execution = js.Execution;

const RTCError = @This();

pub const Proto = DOMException;

// RTCErrorDetailType. Chrome rejects anything outside this set with a
// TypeError from the dictionary conversion, before the object exists.
const Detail = enum {
    @"data-channel-failure",
    @"dtls-failure",
    @"fingerprint-failure",
    @"sctp-failure",
    @"sdp-syntax-error",
    @"hardware-encoder-not-available",
    @"hardware-encoder-error",
};

_proto: *DOMException,
_error_detail: []const u8,
_sdp_line_number: ?i32 = null,
_http_request_status_code: ?i32 = null,
_sctp_cause_code: ?i32 = null,
_received_alert: ?u32 = null,
_sent_alert: ?u32 = null,

// `errorDetail` is a required member; it is declared optional here so a missing
// one produces a TypeError from the check below rather than a bridge-level
// conversion failure.
pub const Init = struct {
    // Alphabetical: a dictionary's members are read in that order.
    errorDetail: ?[]const u8 = null,
    httpRequestStatusCode: ?i32 = null,
    receivedAlert: ?u32 = null,
    sctpCauseCode: ?i32 = null,
    sdpLineNumber: ?i32 = null,
    sentAlert: ?u32 = null,
};

// `message` is optional, so the constructor reports length 1 — Chrome's arity.
pub fn init(options: Init, message: ?[]const u8, exec: *Execution) !*RTCError {
    const detail_string = options.errorDetail orelse return error.TypeError;
    const detail = std.meta.stringToEnum(Detail, detail_string) orelse return error.TypeError;

    const allocator = exec._factory._arena;

    // Chrome reports name "OperationError" and code 0 for every RTCError, and
    // an absent message as "" rather than as DOMException's canned text — so
    // the message is always passed through, empty or not.
    return exec._factory.domException(
        DOMException.init(try allocator.dupe(u8, message orelse ""), "OperationError"),
        RTCError{
            ._proto = undefined,
            ._error_detail = @tagName(detail),
            ._sdp_line_number = options.sdpLineNumber,
            ._http_request_status_code = options.httpRequestStatusCode,
            ._sctp_cause_code = options.sctpCauseCode,
            ._received_alert = options.receivedAlert,
            ._sent_alert = options.sentAlert,
        },
    );
}

pub fn asDOMException(self: *RTCError) *DOMException {
    return self._proto;
}

pub fn getErrorDetail(self: *const RTCError) []const u8 {
    return self._error_detail;
}

pub fn getSdpLineNumber(self: *const RTCError) ?i32 {
    return self._sdp_line_number;
}

pub fn getHttpRequestStatusCode(self: *const RTCError) ?i32 {
    return self._http_request_status_code;
}

pub fn getSctpCauseCode(self: *const RTCError) ?i32 {
    return self._sctp_cause_code;
}

pub fn getReceivedAlert(self: *const RTCError) ?u32 {
    return self._received_alert;
}

pub fn getSentAlert(self: *const RTCError) ?u32 {
    return self._sent_alert;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCError);

    pub const Meta = struct {
        pub const name = "RTCError";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCError.init, .{});
    pub const errorDetail = bridge.accessor(RTCError.getErrorDetail, null, .{});
    pub const sdpLineNumber = bridge.accessor(RTCError.getSdpLineNumber, null, .{});
    pub const httpRequestStatusCode = bridge.accessor(RTCError.getHttpRequestStatusCode, null, .{});
    pub const sctpCauseCode = bridge.accessor(RTCError.getSctpCauseCode, null, .{});
    pub const receivedAlert = bridge.accessor(RTCError.getReceivedAlert, null, .{});
    pub const sentAlert = bridge.accessor(RTCError.getSentAlert, null, .{});
};
