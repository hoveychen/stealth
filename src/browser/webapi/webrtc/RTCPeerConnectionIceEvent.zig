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

// The event delivered to `pc.onicecandidate`. Its only addition to Event is
// `candidate`, which is null on the end-of-candidates event.

const lp = @import("lightpanda");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const RTCIceCandidate = @import("RTCIceCandidate.zig");

const String = lp.String;

const RTCPeerConnectionIceEvent = @This();

pub const Proto = Event;

_proto: *Event,
_candidate: ?*RTCIceCandidate = null,

const RTCPeerConnectionIceEventOptions = struct {
    candidate: ?*RTCIceCandidate = null,
};

pub const Options = Event.inheritOptions(RTCPeerConnectionIceEvent, RTCPeerConnectionIceEventOptions);

pub fn init(typ: []const u8, opts: ?Options, page: *Page) !*RTCPeerConnectionIceEvent {
    const arena = try page.getArena(.tiny, "RTCPeerConnectionIceEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts, false, page);
}

pub fn initTrusted(typ: String, opts: ?Options, page: *Page) !*RTCPeerConnectionIceEvent {
    const arena = try page.getArena(.tiny, "RTCPeerConnectionIceEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, page: *Page) !*RTCPeerConnectionIceEvent {
    const opts = opts_ orelse Options{};

    const event = try page.factory.event(
        arena,
        typ,
        RTCPeerConnectionIceEvent{
            ._proto = undefined,
            ._candidate = opts.candidate,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *RTCPeerConnectionIceEvent) *Event {
    return self._proto;
}

pub fn getCandidate(self: *const RTCPeerConnectionIceEvent) ?*RTCIceCandidate {
    return self._candidate;
}

pub const JsApi = struct {
    const js = @import("../../js/js.zig");
    pub const bridge = js.Bridge(RTCPeerConnectionIceEvent);

    pub const Meta = struct {
        pub const name = "RTCPeerConnectionIceEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCPeerConnectionIceEvent.init, .{});
    pub const candidate = bridge.accessor(RTCPeerConnectionIceEvent.getCandidate, null, .{});
};
