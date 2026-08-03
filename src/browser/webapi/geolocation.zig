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

//! `navigator.geolocation` and the three interfaces its callbacks would receive.
//!
//! Neither callback ever fires. That is not a shortcut: on the reference Chrome
//! the permission request stayed pending and neither the success nor the error
//! callback had run after four seconds (measured again in win21b), so a request
//! nobody answered is a state a real Chrome is observably in — and inventing
//! either a fix or a denial would be a worse tell than a prompt left open.
//!
//! Which is why GeolocationPosition / GeolocationCoordinates /
//! GeolocationPositionError are shape only: the globals are what CreepJS counts,
//! and no script here can reach an instance. Shapes measured on a headed Chrome
//! 150 (win20-chrome.json), including the three error constants, which Chrome
//! puts on both the interface and its prototype.

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{
        Geolocation,
        GeolocationPosition,
        GeolocationCoordinates,
        GeolocationPositionError,
    };
}

pub const Geolocation = struct {
    // Chrome's watch ids are a 1-based counter (measured: two calls in a row
    // returned 1 then 2).
    _next_watch_id: u32 = 0,

    const PositionOptions = struct {
        enableHighAccuracy: bool = false,
        timeout: ?u32 = null,
        maximumAge: ?u32 = null,
    };

    pub fn getCurrentPosition(
        _: *Geolocation,
        _: js.Function,
        _: ?js.Function,
        _: ?PositionOptions,
    ) void {}

    pub fn watchPosition(
        self: *Geolocation,
        _: js.Function,
        _: ?js.Function,
        _: ?PositionOptions,
    ) u32 {
        self._next_watch_id += 1;
        return self._next_watch_id;
    }

    pub fn clearWatch(_: *Geolocation, _: u32) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Geolocation);

        pub const Meta = struct {
            pub const name = "Geolocation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const clearWatch = bridge.function(Geolocation.clearWatch, .{});
        pub const getCurrentPosition = bridge.function(Geolocation.getCurrentPosition, .{});
        pub const watchPosition = bridge.function(Geolocation.watchPosition, .{});
    };
};

pub const GeolocationPosition = struct {
    _pad: bool = false,

    fn coords(_: *const GeolocationPosition) ?*GeolocationCoordinates {
        return null;
    }

    fn timestamp(_: *const GeolocationPosition) f64 {
        return 0;
    }

    fn toJSON(_: *const GeolocationPosition) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GeolocationPosition);

        pub const Meta = struct {
            pub const name = "GeolocationPosition";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const coords = bridge.accessor(GeolocationPosition.coords, null, .{});
        pub const timestamp = bridge.accessor(GeolocationPosition.timestamp, null, .{});
        pub const toJSON = bridge.function(GeolocationPosition.toJSON, .{});
    };
};

pub const GeolocationCoordinates = struct {
    _pad: bool = false,

    fn zero(_: *const GeolocationCoordinates) f64 {
        return 0;
    }

    fn none(_: *const GeolocationCoordinates) ?f64 {
        return null;
    }

    fn toJSON(_: *const GeolocationCoordinates) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GeolocationCoordinates);

        pub const Meta = struct {
            pub const name = "GeolocationCoordinates";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const C = GeolocationCoordinates;

        pub const latitude = bridge.accessor(C.zero, null, .{});
        pub const longitude = bridge.accessor(C.zero, null, .{});
        pub const altitude = bridge.accessor(C.none, null, .{});
        pub const accuracy = bridge.accessor(C.zero, null, .{});
        pub const altitudeAccuracy = bridge.accessor(C.none, null, .{});
        pub const heading = bridge.accessor(C.none, null, .{});
        pub const speed = bridge.accessor(C.none, null, .{});
        pub const toJSON = bridge.function(C.toJSON, .{});
    };
};

pub const GeolocationPositionError = struct {
    _pad: bool = false,

    fn code(_: *const GeolocationPositionError) u16 {
        return 1;
    }

    fn message(_: *const GeolocationPositionError) []const u8 {
        return "";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GeolocationPositionError);

        pub const Meta = struct {
            pub const name = "GeolocationPositionError";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const E = GeolocationPositionError;

        pub const code = bridge.accessor(E.code, null, .{});
        pub const message = bridge.accessor(E.message, null, .{});
        // Chrome carries these on the prototype *and* on the interface object
        // (measured both ways).
        pub const PERMISSION_DENIED = bridge.property(1, .{ .template = true });
        pub const POSITION_UNAVAILABLE = bridge.property(2, .{ .template = true });
        pub const TIMEOUT = bridge.property(3, .{ .template = true });
    };
};
