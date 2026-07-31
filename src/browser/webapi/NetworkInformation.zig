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

// navigator.connection.
//
// Chrome ships this on desktop and fingerprinting scripts read all four values
// as entropy, so a Chrome user-agent whose navigator.connection is undefined
// stands out. The four values below are the ones the reference Chrome 150
// reported (tools/fingerprint/results/reference-chrome-headed.json); they are
// fixed rather than measured from our own transfers.
//
// Reporting them fixed is deliberate and close to what Chrome does anyway:
// Chrome deliberately coarsens this API to limit exactly the entropy we would
// be adding, quantising rtt to 25ms steps and downlink to 25kbps steps, and it
// holds both at conservative defaults until it has enough samples. A stable
// "4g / 100ms / 1.45Mbps" is a value a real Chrome commonly reports.
//
// Only the desktop surface is here: `type` and `downlinkMax` are absent from
// Chrome's own NetworkInformation.prototype on desktop (measured), so adding
// them would be the anomaly.

const js = @import("../js/js.zig");
const EventTarget = @import("EventTarget.zig");

const NetworkInformation = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_change: ?js.Function.Global = null,

pub fn asEventTarget(self: *NetworkInformation) *EventTarget {
    return self._proto;
}

pub fn getEffectiveType(_: *const NetworkInformation) []const u8 {
    return "4g";
}

pub fn getRtt(_: *const NetworkInformation) u32 {
    return 100;
}

pub fn getDownlink(_: *const NetworkInformation) f64 {
    return 1.45;
}

pub fn getSaveData(_: *const NetworkInformation) bool {
    return false;
}

// Nothing ever fires a change event — the values don't move — but the handler
// has to exist: it is on Chrome's prototype, and a script that enumerates
// NetworkInformation.prototype would notice it missing.
pub fn getOnChange(self: *NetworkInformation) ?js.Function.Global {
    return self._on_change;
}

pub fn setOnChange(self: *NetworkInformation, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_change = try listen.persistWithThis(self);
    } else {
        self._on_change = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NetworkInformation);

    pub const Meta = struct {
        pub const name = "NetworkInformation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const effectiveType = bridge.accessor(NetworkInformation.getEffectiveType, null, .{});
    pub const rtt = bridge.accessor(NetworkInformation.getRtt, null, .{});
    pub const downlink = bridge.accessor(NetworkInformation.getDownlink, null, .{});
    pub const saveData = bridge.accessor(NetworkInformation.getSaveData, null, .{});
    pub const onchange = bridge.accessor(NetworkInformation.getOnChange, NetworkInformation.setOnChange, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: NetworkInformation" {
    try testing.htmlRunner("network_information.html", .{});
}
