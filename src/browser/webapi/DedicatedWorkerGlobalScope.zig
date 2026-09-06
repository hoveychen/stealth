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

// The global object of a dedicated worker. Per the HTML spec this is the most
// derived interface of a dedicated worker's global, inheriting from
// WorkerGlobalScope (-> EventTarget). It is the actual JS global object (`self`);
// the WorkerGlobalScope base holds all of the state and implementation, reached
// here through `_proto`. Sites branch on `self instanceof DedicatedWorkerGlobalScope`
// to tell a worker apart from an iframe (e.g. Shopify's Web Pixel sandbox).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Worker = @import("Worker.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");

const MessageEvent = @import("event/MessageEvent.zig");
const handler_property = @import("handler_property.zig");
const EventTarget = @import("EventTarget.zig");
const filesystem = @import("filesystem.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
/// As `handlerProperty` elsewhere, but these setters take a non-callable and
/// store null rather than refusing it, which is what the worker scopes measured.
fn handlerPropertyLenient(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.lenientAccessors(T, which);
}

const DedicatedWorkerGlobalScope = @This();

pub const Proto = WorkerGlobalScope;

_proto: *WorkerGlobalScope,
_worker: *Worker,
_closed: bool = false,

// Messages received before the worker script finished evaluating. Per the
// HTML spec, postMessage'd data is buffered while the worker is loading
// and delivered once the worker is ready (i.e. once onmessage can be set).
// Drained by drainPendingMessages, called from Worker.loadInitialScript
// after the initial script has been evaluated.
_pending_messages: std.ArrayList(?js.Value.Global) = .empty,

pub fn init(worker: *Worker, url: [:0]const u8) !*DedicatedWorkerGlobalScope {
    return WorkerGlobalScope.init(
        worker._arena.allocator(),
        url,
        .dedicated,
        DedicatedWorkerGlobalScope{
            ._worker = worker,
            ._proto = undefined,
        },
        worker._type == .module,
        worker._frame_id,
        worker._loader_id,
        worker._owner_frame,
    );
}

pub fn deinit(self: *DedicatedWorkerGlobalScope) void {
    for (self._pending_messages.items) |maybe_data| {
        if (maybe_data) |d| {
            d.release();
        }
    }
    self._proto.deinit();
}

// A dedicated worker's name is the one the `new Worker(url, {name})` option
// gave it, and the empty string when the option was left out -- which is what a
// Chrome blob worker answers (measured, probes/expr-worker-surface.js). The
// property was missing here entirely, so `self.name` read `undefined`.
pub fn getName(self: *const DedicatedWorkerGlobalScope) []const u8 {
    return self._worker._name;
}

pub fn postMessage(self: *DedicatedWorkerGlobalScope, data: js.Value) !void {
    try self._worker.receiveMessage(data);
}

pub fn close(self: *DedicatedWorkerGlobalScope) void {
    // TODO: we should also stop new tasks from being scheduled
    self._proto._session.idb.detachContext(self._proto.js);
    self._proto.js.scheduler.reset();
    self._closed = true;
}

pub fn requestAnimationFrame(self: *DedicatedWorkerGlobalScope, cb: js.Function.Global, exec: *js.Execution) !u32 {
    return self._proto._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "worker.requestAnimationFrame",
    });
}

pub fn cancelAnimationFrame(self: *DedicatedWorkerGlobalScope, id: u32) void {
    self._proto._timers.clear(id);
}

// Called internally by Worker when it wants to post a message to us
pub fn receiveMessage(self: *DedicatedWorkerGlobalScope, data: js.Value) !void {
    if (self._closed) {
        return;
    }

    const cloned_data: ?js.Value.Global = blk: {
        // Enter our context to clone the message
        var ls: js.Local.Scope = undefined;
        self._proto.js.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker's Page context) to our Context
        const cloned = data.structuredCloneTo(&ls.local, null) catch break :blk null;
        break :blk cloned.persist() catch break :blk null;
    };

    if (!self._worker._script_loaded) {
        // Buffer until Worker.loadInitialScript calls drainPendingMessages.
        // Without this, postMessage'd data races against the worker's
        // script load: if onmessage hasn't been registered yet (because
        // the worker hasn't been evaluated), the dispatched event finds
        // no listener and the message is silently dropped.
        try self._pending_messages.append(self._proto.arena, cloned_data);
        return;
    }

    try self.scheduleMessage(cloned_data);
}

fn scheduleMessage(self: *DedicatedWorkerGlobalScope, cloned_data: ?js.Value.Global) !void {
    const wgs = self._proto;
    const session = wgs._session;

    const message_arena = try session.getArena(.tiny, "DedicatedWorkerGlobalScope.receiveMessage");
    errdefer message_arena.release();

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .data = cloned_data,
        .worker_scope = self,
        .arena = message_arena,
    };

    try wgs.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "WorkerGlobalScope.receiveMessage",
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

// Called by Worker.loadInitialScript once the initial script has been
// evaluated and onmessage has had a chance to be registered. Any messages
// that arrived while the worker was loading are scheduled for delivery in
// the order they were received.
pub fn drainPendingMessages(self: *DedicatedWorkerGlobalScope) void {
    for (self._pending_messages.items) |cloned_data| {
        self.scheduleMessage(cloned_data) catch |err| {
            lp.log.warn(.browser, "worker drain msg failed", .{ .err = err });
            if (cloned_data) |d| d.release();
        };
    }
    self._pending_messages.clearRetainingCapacity();
}

const ReceiveMessageCallback = struct {
    data: ?js.Value.Global,
    arena: *lp.Arena,
    worker_scope: *DedicatedWorkerGlobalScope,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| {
            d.release();
        }
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.arena.release();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker_scope = self.worker_scope;
        const wsg = worker_scope._proto;
        const target = wsg.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        if (self.data == null) {
            if (!wsg._event_manager.hasDirectListeners(target, "messageerror", null)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .bubbles = false,
                .cancelable = false,
            }, wsg._page)).asEvent();
            try wsg.dispatch(target, event, null, .{});
            return null;
        }

        // Check if there are any listeners before creating the event
        if (!wsg._event_manager.hasDirectListeners(target, "message", null)) {
            self.data.?.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.data.? },
            .bubbles = false,
            .cancelable = false,
        }, wsg._page)).asEvent();
        try wsg.dispatch(target, event, null, .{});
        return null;
    }
};

pub fn asEventTarget(self: *DedicatedWorkerGlobalScope) *EventTarget {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DedicatedWorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "DedicatedWorkerGlobalScope";
        // Web IDL [Global]: this interface's attributes and operations are own
        // properties of the global object rather than properties of the
        // interface prototype object. The annotation is per-interface -- the
        // inherited ones (WorkerGlobalScope, EventTarget) keep theirs where
        // they are.
        pub const global = true;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const postMessage = bridge.function(DedicatedWorkerGlobalScope.postMessage, .{});
    pub const close = bridge.function(DedicatedWorkerGlobalScope.close, .{});
    pub const onmessage = bridge.accessor(handlerPropertyLenient(DedicatedWorkerGlobalScope, .onmessage).get, handlerPropertyLenient(DedicatedWorkerGlobalScope, .onmessage).set, .{});
    pub const onmessageerror = bridge.accessor(handlerPropertyLenient(DedicatedWorkerGlobalScope, .onmessageerror).get, handlerPropertyLenient(DedicatedWorkerGlobalScope, .onmessageerror).set, .{});
    pub const requestAnimationFrame = bridge.function(DedicatedWorkerGlobalScope.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(DedicatedWorkerGlobalScope.cancelAnimationFrame, .{});
    pub const name = bridge.accessor(DedicatedWorkerGlobalScope.getName, null, .{});

    // The sandboxed filesystem entry points, and they belong here rather than
    // on WorkerGlobalScope for a measurable reason: Chrome's blob worker holds
    // both as own properties of the global, and only a [Global] interface's own
    // members land there -- WorkerGlobalScope's stay on its prototype, where
    // these two are absent. The two quota constants they take live here too.
    // Arity 2 for the request operation where the Window's is 3 (measured); the
    // error callback is optional in both, so that is Chrome's inconsistency.
    // A shared worker was not measured, so it does not get them.
    pub const webkitRequestFileSystem = bridge.function(filesystem.workerRequestFileSystem, .{ .arity = 2 });
    pub const webkitResolveLocalFileSystemURL = bridge.function(filesystem.workerResolveLocalFileSystemURL, .{ .arity = 2 });

    // The two deprecated quota constants Chrome still carries. [Global] moves
    // operations and attributes onto the global object; constants stay on the
    // interface prototype, which is why Chrome's
    // getOwnPropertyNames(DedicatedWorkerGlobalScope.prototype) is exactly
    // TEMPORARY, PERSISTENT, constructor -- in that order.
    pub const TEMPORARY = bridge.property(0, .{ .template = true });
    pub const PERSISTENT = bridge.property(1, .{ .template = true });
};
