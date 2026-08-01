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

// What pc.getStats() resolves to. Maplike, and — measured — *not* a Map
// subclass: `report instanceof Map` is false in Chrome, and the prototype
// carries its own size/entries/forEach/get/has/keys/values.
//
// It carries one entry, the "peer-connection" record, which is exactly what a
// connection reports before anything is negotiated (measured: a fresh
// RTCPeerConnection reports size 1 with the record reproduced below, down to
// the key order).
//
// Known gap, stated rather than papered over: once a real Chrome has a data
// channel and a local description, the same call reports eight records —
// certificate, transport, four local-candidate rows and data-channel on top of
// this one. Those describe a DTLS certificate and ICE sockets that do not exist
// here, and inventing them would mean inventing values. So the report stays at
// one entry, and a page that counts records after setLocalDescription can tell.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ RTCStatsReport, KeyIterator, ValueIterator, EntryIterator };
}

const RTCStatsReport = @This();

// Chrome's id for the peer-connection record is the single letter "P".
const PEER_CONNECTION_ID = "P";

_timestamp: f64,

// Chrome's key order for this record, measured.
pub const PeerConnectionStats = struct {
    id: []const u8 = PEER_CONNECTION_ID,
    timestamp: f64,
    type: []const u8 = "peer-connection",
    dataChannelsClosed: u32 = 0,
    dataChannelsOpened: u32 = 0,
};

pub fn init(exec: *const Execution) !*RTCStatsReport {
    // Chrome timestamps these in epoch milliseconds carrying a sub-millisecond
    // fraction, which is the monotonic clock's fraction on top of the wall
    // clock.
    const monotonic = exec.performance().now();
    const epoch: f64 = @floatFromInt(lp.datetime.DateTime.now().unix(.milliseconds));
    return exec._factory.create(RTCStatsReport{
        ._timestamp = @floor(epoch) + (monotonic - @floor(monotonic)),
    });
}

fn record(self: *const RTCStatsReport) PeerConnectionStats {
    return .{ .timestamp = self._timestamp };
}

pub fn getSize(_: *const RTCStatsReport) u32 {
    return 1;
}

pub fn get(self: *const RTCStatsReport, key: []const u8) ?PeerConnectionStats {
    if (!std.mem.eql(u8, key, PEER_CONNECTION_ID)) {
        return null;
    }
    return self.record();
}

pub fn has(_: *const RTCStatsReport, key: []const u8) bool {
    return std.mem.eql(u8, key, PEER_CONNECTION_ID);
}

pub fn keys(self: *RTCStatsReport, frame: *Frame) !*KeyIterator {
    return .init(.{ .report = self }, frame);
}

pub fn values(self: *RTCStatsReport, frame: *Frame) !*ValueIterator {
    return .init(.{ .report = self }, frame);
}

pub fn entries(self: *RTCStatsReport, frame: *Frame) !*EntryIterator {
    return .init(.{ .report = self }, frame);
}

pub fn forEach(self: *RTCStatsReport, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    var caught: js.TryCatch.Caught = undefined;
    cb.tryCall(void, .{ self.record(), PEER_CONNECTION_ID, self }, &caught) catch {
        lp.log.debug(.js, "forEach callback", .{ .caught = caught, .source = "RTCStatsReport" });
    };
}

pub const Iterator = struct {
    index: u32 = 0,
    report: *RTCStatsReport,

    pub const Entry = struct { []const u8, PeerConnectionStats };

    pub fn next(self: *Iterator, _: *const Frame) ?Iterator.Entry {
        if (self.index != 0) {
            return null;
        }
        self.index = 1;
        return .{ PEER_CONNECTION_ID, self.report.record() };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCStatsReport);

    pub const Meta = struct {
        pub const name = "RTCStatsReport";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const size = bridge.accessor(RTCStatsReport.getSize, null, .{});
    pub const get = bridge.function(RTCStatsReport.get, .{});
    pub const has = bridge.function(RTCStatsReport.has, .{});
    pub const keys = bridge.function(RTCStatsReport.keys, .{});
    pub const values = bridge.function(RTCStatsReport.values, .{});
    pub const entries = bridge.function(RTCStatsReport.entries, .{});
    pub const forEach = bridge.function(RTCStatsReport.forEach, .{});
    pub const symbol_iterator = bridge.iterator(RTCStatsReport.entries, .{});
};
