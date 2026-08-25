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

// The one answer a desktop with no motion sensors gives.
//
// Chrome does not stay silent when a page listens for device motion or
// orientation on a machine that has neither sensor. It starts its sensor
// provider when a listener goes on and answers with an event whose every
// reading is null -- measured on a headless Chrome 151 on macOS: 43 ms after
// the first listener, ~18 ms after a later one, delivered to the whole
// listener list rather than only to the new arrival. Registrations that land
// in the same tick share one answer: two devicemotion listeners added together
// see a single event between them, while one added two seconds later earns
// another. Nothing arrives unprompted in the following nine seconds.
//
// This engine used to answer nothing at all, which is both a difference a
// fingerprint script can read directly and a way to hang one: a collector that
// waits for the reading before it reports has nothing to wait for. macys'
// Akamai sensor registers all three types.
//
// The readings themselves stay null, because there is no sensor here either --
// this supplies the answer, not an invented device.

const std = @import("std");

const Frame = @import("../../Frame.zig");
const EventManager = @import("../../EventManager.zig");
const EventTarget = @import("../EventTarget.zig");
const DeviceMotionEvent = @import("DeviceMotionEvent.zig");
const DeviceOrientationEvent = @import("DeviceOrientationEvent.zig");

// Chrome's first answer lands 43 ms after the listener and later ones ~18 ms,
// the gap being its sensor provider starting up. One delay inside that band is
// closer than the silence it replaces, and it keeps the answer where Chrome
// puts it: after the registering script has returned.
const ANSWER_DELAY_MS = 20;

/// One slot per kind: an answer already queued swallows the registrations that
/// arrive before it fires, which is how Chrome answers a burst once.
pub const Pending = std.enums.EnumFieldStruct(Kind, bool, false);

pub const Kind = enum {
    motion,
    orientation,
    orientation_absolute,

    pub fn fromType(typ: []const u8) ?Kind {
        if (std.mem.eql(u8, typ, "devicemotion")) return .motion;
        if (std.mem.eql(u8, typ, "deviceorientation")) return .orientation;
        if (std.mem.eql(u8, typ, "deviceorientationabsolute")) return .orientation_absolute;
        return null;
    }
};

/// Queues the answer a fresh listener earns. A no-op for every other event
/// type, and for every target but the window -- Chrome routes these nowhere
/// else.
pub fn answer(manager: *EventManager, target: *EventTarget, typ: []const u8) !void {
    if (target._type != .window) {
        return;
    }
    const kind = Kind.fromType(typ) orelse return;
    const pending = pendingSlot(&manager.device_sensor_pending, kind);
    if (pending.*) {
        return;
    }

    const frame = manager.frame;
    const task = try frame._factory.create(Task{ .manager = manager, .kind = kind });
    errdefer frame._factory.destroy(task);
    try frame.js.scheduler.add(task, Task.run, ANSWER_DELAY_MS, .{
        .name = "device sensor answer",
        .finalizer = Task.cancelled,
    });
    pending.* = true;
}

fn pendingSlot(pending: *Pending, kind: Kind) *bool {
    return switch (kind) {
        .motion => &pending.motion,
        .orientation => &pending.orientation,
        .orientation_absolute => &pending.orientation_absolute,
    };
}

const Task = struct {
    manager: *EventManager,
    kind: Kind,

    fn cancelled(ctx: *anyopaque) void {
        const self: *Task = @ptrCast(@alignCast(ctx));
        pendingSlot(&self.manager.device_sensor_pending, self.kind).* = false;
        self.manager.frame._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *Task = @ptrCast(@alignCast(ctx));
        const manager = self.manager;
        const frame = manager.frame;
        const kind = self.kind;
        pendingSlot(&manager.device_sensor_pending, kind).* = false;
        defer frame._factory.destroy(self);

        const target = frame.window.asEventTarget();
        const typ = switch (kind) {
            .motion => "devicemotion",
            .orientation => "deviceorientation",
            .orientation_absolute => "deviceorientationabsolute",
        };
        if (!manager.hasDirectListeners(target, typ, null)) {
            return null;
        }

        // The three sub-dictionaries are present with null members rather than
        // absent: Chrome reports `acceleration: {x: null, y: null, z: null}`,
        // not `acceleration: null`, and `interval: 16` even with no device.
        const event = switch (kind) {
            .motion => (try DeviceMotionEvent.init(typ, .{ .interval = 16, .acceleration = .{}, .accelerationIncludingGravity = .{}, .rotationRate = .{} }, frame)).asEvent(),
            .orientation => (try DeviceOrientationEvent.init(typ, .{ .absolute = false }, frame)).asEvent(),
            .orientation_absolute => (try DeviceOrientationEvent.init(typ, .{ .absolute = true }, frame)).asEvent(),
        };
        event.setTrusted();
        try manager.dispatchDirect(target, event, null, .{ .context = "device sensor" });
        return null;
    }
};
