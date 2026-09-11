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

// What `pc.localDescription` hands back. Note that this is *not* what
// createOffer() resolves to — Chrome resolves that with a plain object whose
// prototype is Object.prototype, and a page can see the difference
// (measured: `Object.getPrototypeOf(offer).constructor.name` is "Object" for
// the createOffer result but "RTCSessionDescription" for localDescription).
//
// Both accessors are writable in Chrome even though the spec says readonly, and
// a default-constructed one reports `type` null with `sdp` "" — measured, and
// reproduced here because `JSON.stringify(new RTCSessionDescription())` is a
// one-liner a fingerprinting script can compare.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Execution = js.Execution;

const RTCSessionDescription = @This();

_type: ?lp.String = null,
_sdp: lp.String = .empty,

pub const Init = struct {
    // Alphabetical: a dictionary's members are read in that order.
    sdp: ?lp.String.Global = null,
    type: ?lp.String.Global = null,
};

// `init` is optional so the reported arity is 0, matching Chrome's
// RTCSessionDescription.length (measured).
pub fn constructor(init: ?Init, exec: *Execution) !*RTCSessionDescription {
    return exec._factory.create(RTCSessionDescription{
        ._type = if (init) |i| (if (i.type) |t| t.str else null) else null,
        ._sdp = if (init) |i| (if (i.sdp) |s| s.str else .empty) else .empty,
    });
}

pub fn getType(self: *const RTCSessionDescription) ?lp.String {
    return self._type;
}

pub fn setType(self: *RTCSessionDescription, value: ?lp.String.Global) void {
    self._type = if (value) |v| v.str else null;
}

pub fn getSdp(self: *const RTCSessionDescription) lp.String {
    return self._sdp;
}

pub fn setSdp(self: *RTCSessionDescription, value: lp.String.Global) void {
    self._sdp = value.str;
}

// Chrome's key order, and only these two keys.
pub fn toJSON(self: *const RTCSessionDescription) struct {
    type: ?lp.String,
    sdp: lp.String,
} {
    return .{ .type = self._type, .sdp = self._sdp };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCSessionDescription);

    pub const Meta = struct {
        pub const name = "RTCSessionDescription";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCSessionDescription.constructor, .{});

    pub const @"type" = bridge.accessor(RTCSessionDescription.getType, RTCSessionDescription.setType, .{});
    pub const sdp = bridge.accessor(RTCSessionDescription.getSdp, RTCSessionDescription.setSdp, .{});
    pub const toJSON = bridge.function(RTCSessionDescription.toJSON, .{});
};
