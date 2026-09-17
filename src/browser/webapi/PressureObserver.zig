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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Compute Pressure. One of the five names DataDome's device-check program asked
// for and did not get; see BarcodeDetector.zig for the set and where it came
// from.
//
// Measured on a headed Chrome 152 (probe scratch/s34/shape.js plus the
// behaviour readings in the plan's P2 notes):
//
//   * PressureObserver.length is 1 and `new PressureObserver()` is a TypeError
//     reading "Failed to construct 'PressureObserver': 1 argument required, but
//     only 0 present." -- which the bridge's own arity check writes.
//   * The interface object carries one static, knownSources, which is ['cpu'].
//   * The prototype carries disconnect, observe, takeRecords, unobserve, and
//     does not descend from EventTarget.
//   * observe('cpu') resolves; takeRecords() is [].
//   * [SecureContext]: absent from an insecure origin, so the name is in
//     secure_context.gated_interfaces.
//
// Nothing here samples anything, so the observer never has a record to deliver
// and its callback is never called -- which is also what a quiescent machine
// looks like between state changes. The callback is therefore not retained.

const js = @import("../js/js.zig");

const Execution = js.Execution;

const PressureObserver = @This();

// The sources a browser on this platform can observe (measured).
const known_sources = [_][]const u8{"cpu"};

// Padding to avoid a zero-size struct, which causes identity_map pointer
// collisions.
_pad: bool = false,

pub fn constructor(_: js.Function.Global, exec: *const Execution) !*PressureObserver {
    return exec._factory.create(PressureObserver{});
}

pub fn getKnownSources() []const []const u8 {
    return &known_sources;
}

/// Resolves, like Chrome's does for 'cpu'. Nothing starts sampling, so the
/// callback handed to the constructor is never invoked.
pub fn observe(_: *PressureObserver, _: []const u8, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn unobserve(_: *PressureObserver, _: []const u8) void {}

pub fn disconnect(_: *PressureObserver) void {}

/// Always empty: no source is ever sampled, so nothing is ever queued.
pub fn takeRecords(_: *PressureObserver) []const js.Value {
    return &.{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PressureObserver);

    pub const Meta = struct {
        pub const name = "PressureObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PressureObserver.constructor, .{});
    pub const knownSources = bridge.accessor(PressureObserver.getKnownSources, null, .{ .static = true });
    pub const disconnect = bridge.function(PressureObserver.disconnect, .{});
    pub const observe = bridge.function(PressureObserver.observe, .{});
    pub const takeRecords = bridge.function(PressureObserver.takeRecords, .{});
    pub const unobserve = bridge.function(PressureObserver.unobserve, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: PressureObserver" {
    try testing.htmlRunner("pressure_observer.html", .{});
}
