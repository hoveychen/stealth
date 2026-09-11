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

// The five remaining RTC Event subclasses. (RTCPeerConnectionIceEvent has its
// own file — it is the only one the engine actually dispatches.) Nothing here
// is ever fired: no connection is established, so no track arrives, no channel
// opens, no DTMF tone plays and nothing errors. They exist because
// Object.getOwnPropertyNames(window) is read directly by CreepJS, and a window
// with RTCPeerConnection but without RTCTrackEvent is not a shape any real
// Chrome has.
//
// All five report constructor length 2 in Chrome — type plus a *required*
// dictionary — so `opts` is non-optional here (getArity stops at the first
// optional parameter). Every arity and default below was read off a headed
// Chrome 150; see tools/fingerprint/webrtc-protochain.mjs
// and /tmp/webrtc-protochain-chrome.json.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const RTCError = @import("RTCError.zig");
const RTCDataChannel = @import("RTCDataChannel.zig");

const String = lp.String;

pub fn registerTypes() []const type {
    return &.{
        RTCTrackEvent,
        RTCErrorEvent,
        RTCDataChannelEvent,
        RTCPeerConnectionIceErrorEvent,
        RTCDTMFToneChangeEvent,
    };
}

// Chrome's `onicecandidateerror` payload, and the only one of the five whose
// dictionary this engine can satisfy in full: every member is a plain value.
pub const RTCPeerConnectionIceErrorEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _address: ?[]const u8 = null,
    _port: ?u32 = null,
    _url: []const u8 = "",
    _error_code: u32 = 0,
    _error_text: []const u8 = "",

    const Extra = struct {
        // Alphabetical: a dictionary's members are read in that order.
        address: ?String.Global = null,
        // Required. Optional here so a missing one is a TypeError from the
        // check in init() rather than a bridge conversion failure.
        errorCode: ?u32 = null,
        errorText: ?String.Global = null,
        port: ?u32 = null,
        url: ?String.Global = null,
    };

    pub const Options = Event.inheritOptions(RTCPeerConnectionIceErrorEvent, Extra);

    pub fn init(typ: []const u8, opts: Options, page: *Page) !*RTCPeerConnectionIceErrorEvent {
        const error_code = opts.errorCode orelse return error.TypeError;

        const arena = try page.getArena(.tiny, "RTCPeerConnectionIceErrorEvent");
        errdefer arena.release();

        const allocator = arena.allocator();
        const event = try page.factory.event(
            arena,
            try String.init(allocator, typ, .{}),
            RTCPeerConnectionIceErrorEvent{
                ._proto = undefined,
                ._address = if (opts.address) |a| try allocator.dupe(u8, a.str.str()) else null,
                ._port = opts.port,
                ._url = if (opts.url) |u| try allocator.dupe(u8, u.str.str()) else "",
                ._error_code = error_code,
                ._error_text = if (opts.errorText) |t| try allocator.dupe(u8, t.str.str()) else "",
            },
        );

        Event.populatePrototypes(event, opts, false);
        return event;
    }

    pub fn asEvent(self: *RTCPeerConnectionIceErrorEvent) *Event {
        return self._proto;
    }

    pub fn getAddress(self: *const RTCPeerConnectionIceErrorEvent) ?[]const u8 {
        return self._address;
    }

    pub fn getPort(self: *const RTCPeerConnectionIceErrorEvent) ?u32 {
        return self._port;
    }

    // Not an init member and *not* derived from address/port: Chrome reports ""
    // for a page-constructed event even when both are given (measured with
    // `{errorCode: 701, address: '1.2.3.4', port: 5000}`). It is only filled in
    // for the event the connection itself fires, which this engine never does.
    pub fn getHostCandidate(_: *const RTCPeerConnectionIceErrorEvent) []const u8 {
        return "";
    }

    pub fn getUrl(self: *const RTCPeerConnectionIceErrorEvent) []const u8 {
        return self._url;
    }

    pub fn getErrorCode(self: *const RTCPeerConnectionIceErrorEvent) u32 {
        return self._error_code;
    }

    pub fn getErrorText(self: *const RTCPeerConnectionIceErrorEvent) []const u8 {
        return self._error_text;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCPeerConnectionIceErrorEvent);

        pub const Meta = struct {
            pub const name = "RTCPeerConnectionIceErrorEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(RTCPeerConnectionIceErrorEvent.init, .{});
        pub const address = bridge.accessor(RTCPeerConnectionIceErrorEvent.getAddress, null, .{});
        pub const port = bridge.accessor(RTCPeerConnectionIceErrorEvent.getPort, null, .{});
        pub const hostCandidate = bridge.accessor(RTCPeerConnectionIceErrorEvent.getHostCandidate, null, .{});
        pub const url = bridge.accessor(RTCPeerConnectionIceErrorEvent.getUrl, null, .{});
        pub const errorCode = bridge.accessor(RTCPeerConnectionIceErrorEvent.getErrorCode, null, .{});
        pub const errorText = bridge.accessor(RTCPeerConnectionIceErrorEvent.getErrorText, null, .{});
    };
};

// `error` is a required member, and RTCError is constructible here, so this one
// round-trips for real.
pub const RTCErrorEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _error: *RTCError,

    const Extra = struct {
        @"error": ?*RTCError = null,
    };

    pub const Options = Event.inheritOptions(RTCErrorEvent, Extra);

    pub fn init(typ: []const u8, opts: Options, page: *Page) !*RTCErrorEvent {
        const err = opts.@"error" orelse return error.TypeError;

        const arena = try page.getArena(.tiny, "RTCErrorEvent");
        errdefer arena.release();

        const event = try page.factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            RTCErrorEvent{ ._proto = undefined, ._error = err },
        );

        Event.populatePrototypes(event, opts, false);
        return event;
    }

    pub fn asEvent(self: *RTCErrorEvent) *Event {
        return self._proto;
    }

    pub fn getError(self: *const RTCErrorEvent) *RTCError {
        return self._error;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCErrorEvent);

        pub const Meta = struct {
            pub const name = "RTCErrorEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(RTCErrorEvent.init, .{});
        pub const @"error" = bridge.accessor(RTCErrorEvent.getError, null, .{});
    };
};

// `channel` is required, and a page can get an RTCDataChannel out of
// pc.createDataChannel(), so this one round-trips too (measured: constructing
// it with a live channel gives back `e.channel.label`).
pub const RTCDataChannelEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _channel: *RTCDataChannel,

    const Extra = struct {
        channel: ?*RTCDataChannel = null,
    };

    pub const Options = Event.inheritOptions(RTCDataChannelEvent, Extra);

    pub fn init(typ: []const u8, opts: Options, page: *Page) !*RTCDataChannelEvent {
        const channel = opts.channel orelse return error.TypeError;

        const arena = try page.getArena(.tiny, "RTCDataChannelEvent");
        errdefer arena.release();

        const event = try page.factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            RTCDataChannelEvent{ ._proto = undefined, ._channel = channel },
        );

        Event.populatePrototypes(event, opts, false);
        return event;
    }

    pub fn asEvent(self: *RTCDataChannelEvent) *Event {
        return self._proto;
    }

    pub fn getChannel(self: *const RTCDataChannelEvent) *RTCDataChannel {
        return self._channel;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDataChannelEvent);

        pub const Meta = struct {
            pub const name = "RTCDataChannelEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(RTCDataChannelEvent.init, .{});
        pub const channel = bridge.accessor(RTCDataChannelEvent.getChannel, null, .{});
    };
};

// `tone` defaults to "", so an empty dictionary is enough — measured:
// `new RTCDTMFToneChangeEvent('tonechange', {})` gives `tone === ""`.
pub const RTCDTMFToneChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _tone: []const u8 = "",

    const Extra = struct {
        tone: ?String.Global = null,
    };

    pub const Options = Event.inheritOptions(RTCDTMFToneChangeEvent, Extra);

    pub fn init(typ: []const u8, opts: Options, page: *Page) !*RTCDTMFToneChangeEvent {
        const arena = try page.getArena(.tiny, "RTCDTMFToneChangeEvent");
        errdefer arena.release();

        const allocator = arena.allocator();
        const event = try page.factory.event(
            arena,
            try String.init(allocator, typ, .{}),
            RTCDTMFToneChangeEvent{
                ._proto = undefined,
                ._tone = if (opts.tone) |t| try allocator.dupe(u8, t.str.str()) else "",
            },
        );

        Event.populatePrototypes(event, opts, false);
        return event;
    }

    pub fn asEvent(self: *RTCDTMFToneChangeEvent) *Event {
        return self._proto;
    }

    pub fn getTone(self: *const RTCDTMFToneChangeEvent) []const u8 {
        return self._tone;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDTMFToneChangeEvent);

        pub const Meta = struct {
            pub const name = "RTCDTMFToneChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(RTCDTMFToneChangeEvent.init, .{});
        pub const tone = bridge.accessor(RTCDTMFToneChangeEvent.getTone, null, .{});
    };
};

// The one dictionary this engine can never satisfy: `receiver` and
// `transceiver` name prototype-only interfaces, and `track` names
// MediaStreamTrack, which does not exist here at all. Chrome rejects every
// value we could pass with a TypeError, so the constructor throws one
// unconditionally rather than pretending. The accessors are still declared:
// the prototype is what gets compared.
pub const RTCTrackEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    const Extra = struct {
        // Alphabetical: a dictionary's members are read in that order.
        receiver: ?js.Value = null,
        streams: ?[]const js.Value = null,
        track: ?js.Value = null,
        transceiver: ?js.Value = null,
    };

    pub const Options = Event.inheritOptions(RTCTrackEvent, Extra);

    pub fn init(_: []const u8, _: Options, _: *Page) !*RTCTrackEvent {
        return error.TypeError;
    }

    pub fn asEvent(self: *RTCTrackEvent) *Event {
        return self._proto;
    }

    pub fn getReceiver(_: *const RTCTrackEvent) ?js.Value {
        return null;
    }

    pub fn getTrack(_: *const RTCTrackEvent) ?js.Value {
        return null;
    }

    pub fn getStreams(_: *const RTCTrackEvent) []const js.Value {
        return &.{};
    }

    pub fn getTransceiver(_: *const RTCTrackEvent) ?js.Value {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCTrackEvent);

        pub const Meta = struct {
            pub const name = "RTCTrackEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(RTCTrackEvent.init, .{});
        pub const receiver = bridge.accessor(RTCTrackEvent.getReceiver, null, .{});
        pub const track = bridge.accessor(RTCTrackEvent.getTrack, null, .{});
        pub const streams = bridge.accessor(RTCTrackEvent.getStreams, null, .{});
        pub const transceiver = bridge.accessor(RTCTrackEvent.getTransceiver, null, .{});
    };
};
