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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Transfer = @import("../../network/HttpClient.zig").Transfer;

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");

const log = lp.log;

const Worker = @This();

pub const Proto = EventTarget;

pub const WorkerType = enum {
    classic,
    module,
    pub const js_enum_from_string = true;
};

// used by HttpClient when generating notification
// Ultimately used by CDP to generate request/loader ids.
_frame_id: u32,
_loader_id: u32,

_proto: *EventTarget,
// The realm that created this worker, not its Frame. A dedicated worker can
// create another one, and a worker realm has no Frame to hand out: asking for
// one there is `unreachable` in Caller.getGlobalArg, and handing over the
// OWNER's Frame instead aborts on the live Cloudflare station (see the comment
// there). Everything this file wanted a Frame for -- the base URL, the arenas,
// the factory, the event manager, the scheduler, the HTTP owner -- is either on
// the Execution or on this union, and each answers with the asking realm's own
// state.
_global: lp.GlobalScope,

// The DOCUMENT's frame, kept only to build this worker's own global scope,
// which inherits the document's origin, storage partition, secure-context flag
// and referrer policy. A first-level worker already stores exactly this; a
// nested one inherits the same document, so the child scope is built from the
// same state either way.
//
// This is NOT the thing Caller.getGlobalArg refuses to do. What aborts on the
// live station is handing a Frame to JS-facing code RUNNING in a worker realm,
// which then reaches the page thread's factory and arenas from worker code.
// Everything on that path here goes through `exec()` instead.
_owner_frame: *Frame,
_arena: *lp.Arena,
_worker_scope: *DedicatedWorkerGlobalScope,

_url: [:0]const u8,
// The `name` option, which the worker's own global reports as `self.name`. An
// omitted option is the empty string, not undefined (measured on a Chrome 151
// blob worker, probes/expr-worker-surface.js).
_name: []const u8 = "",
_type: WorkerType = .classic,
_script_loaded: bool = false,
// Set before the script fetch is aborted on purpose. An abort we asked for is
// not a load failure, and Chrome reports nothing for it -- the Cloudflare
// challenge terminates a 13-byte blob worker before its script can land and
// its page hears nothing, where this fired `error` with message "Abort".
_script_arena: ?*lp.Arena = null,
_script_buffer: std.ArrayList(u8) = .empty,
_http_transfer: ?*Transfer = null,

const WorkerOptions = struct {
    // Alphabetical: a dictionary's members are read in that order.
    name: []const u8 = "",
    type: WorkerType = .classic,
};

// The Execution of the realm that created this worker. It lives on that
// realm's Context, so it is as long-lived as the realm and safe to reach for
// from a callback that runs long after the constructor returned.
fn exec(self: *const Worker) *js.Execution {
    return &self._global.getJs().execution;
}

pub fn init(url: []const u8, options: ?WorkerOptions, exec_: *js.Execution) !*Worker {
    const session = exec_.session;

    const arena = try session.getArena(.small, "Worker");
    errdefer arena.release();

    // The asking realm's base, so a nested worker resolves its script against
    // the outer WORKER's URL rather than the document's.
    const resolved_url = try URL.resolve(arena.allocator(), exec_.base(), url, .{ .encoding = exec_.charset.* });
    const self = try exec_.page.factory.eventTargetWithAllocator(arena.allocator(), Worker{
        ._arena = arena,
        ._proto = undefined,
        ._global = exec_.js.global,
        ._owner_frame = switch (exec_.js.global) {
            .frame => |f| f,
            .worker => |w| w._frame,
        },
        ._url = resolved_url,
        ._type = if (options) |o| o.type else .classic,
        ._name = if (options) |o| try arena.allocator().dupe(u8, o.name) else "",
        ._worker_scope = undefined,
        ._frame_id = session.nextFrameId(),
        ._loader_id = session.nextLoaderId(),
    });
    const dedicated_worker = try DedicatedWorkerGlobalScope.init(self, resolved_url);
    errdefer dedicated_worker.deinit();

    self._worker_scope = dedicated_worker;
    try exec_.trackWorker(self);

    if (session.load_resources.worker == false) {
        log.warnDisabledWorker();
        return self;
    }

    self._script_arena = try session.getArena(.large, "Worker.script");
    errdefer self.releaseScriptArena();

    const transfer = exec_.newRequest(.{
        .ctx = self,
        .method = .GET,
        .url = resolved_url,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .resource_type = .worker,
        .cookie_origin = .{ .url = resolved_url },
        .notification = session.notification,
        .origin = self._owner_frame.origin,
        .request_mode = .same_origin,
        .credentials_mode = .same_origin,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        log.err(.browser, "Worker request", .{ .url = resolved_url, .err = err });
        exec_.removeWorker(self);
        return err;
    };

    // Held for deinit's abort; the done, error and shutdown callbacks clear
    // it. The shutdown one matters: Frame.deinit's abortOwner kills the
    // transfer before it deinits this worker, and deinit must not abort a
    // freed transfer.
    self._http_transfer = transfer;

    // Chrome puts the creating document's URL on the script fetch itself
    // (measured, scratch/b120/blob-chrome.json). Frame.newRequest is the
    // two-phase helper and does not add it, so ask for it here.
    exec_.headersForRequest(transfer) catch |err| {
        log.err(.browser, "Worker request headers", .{ .url = resolved_url, .err = err });
    };

    transfer.submit() catch |err| {
        log.err(.browser, "Worker request", .{ .url = resolved_url, .err = err });
        exec_.removeWorker(self);
        return err;
    };
    return self;
}

// Called from Frame.deinit when the frame is destroyed, so we don't need to
// remove from the frame's worker list.
pub fn deinit(self: *Worker) void {
    // No pending frame for workers, so we can abort all frames.
    if (self._http_transfer) |res| {
        res.cancel();
        self._http_transfer = null;
    }
    self.releaseScriptArena();
    self._worker_scope.deinit();
    self._arena.release();
}

pub fn asEventTarget(self: *Worker) *EventTarget {
    return self._proto;
}

fn httpHeaderCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *Worker = @ptrCast(@alignCast(transfer.req.ctx));

    const status = transfer.responseStatus() orelse return .abort;
    if (status < 200 or status >= 300) {
        log.warn(.browser, "Worker status", .{
            .url = self._url,
            .status = status,
        });
        return .abort;
    }

    if (transfer.getContentLength()) |cl| {
        try self._script_buffer.ensureTotalCapacityPrecise(self._script_arena.?.allocator(), cl);
    }

    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *Worker = @ptrCast(@alignCast(transfer.req.ctx));
    try self._script_buffer.appendSlice(self._script_arena.?.allocator(), data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    defer self.releaseScriptArena();

    const url = self._url;
    const script = self._script_buffer.items;

    if (comptime lp.IS_DEBUG) {
        log.info(.browser, "worker fetch done", .{
            .url = url,
            .len = script.len,
        });
    }

    try self.loadInitialScript(script);
}

fn loadInitialScript(self: *Worker, script: []const u8) !void {
    const js_context = self._worker_scope._proto.js;

    if (js_context.env.terminatePending()) {
        return;
    }

    // Keep buffering throughout the entire outer eval (including any
    // runMacrotasks pumped by importScripts via the synchronous CDP path,
    // see WorkerGlobalScope.importScripts). The flip-and-drain happens
    // via defer so it runs after eval AND after the trailing
    // runMacrotasks below — by which point the outer script has had its
    // only chance to register onmessage. drainPendingMessages enqueues
    // messages in receive order, so pre-eval and during-eval messages
    // are delivered FIFO on the next runner tick, matching the spec.
    //
    // On eval-throw the defer still fires; the messages get scheduled
    // and then drop at the "no listener" check, mirroring the
    // httpErrorCallback path.
    defer {
        self._script_loaded = true;
        self._worker_scope.drainPendingMessages();
    }

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Classic workers evaluate the entry script as a classic script; module
    // workers (`new Worker(url, { type: "module" })`) instantiate it as a
    // module so top-level `import`/`export` work. Static imports load
    // synchronously through ScriptManagerBase (client.tick sync_wait).
    switch (self._type) {
        .classic => _ = ls.local.eval(script, self._url) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            js_context.page.recordJsError(err);
            const caught = try_catch.caughtOrError(self._script_arena.?.allocator(), err);
            log.err(.browser, "worker script error", .{ .url = self._url, .caught = caught });
            self.fireErrorEvent(caught.exception orelse @errorName(err), null);
            return;
        },
        .module => js_context.module(false, &ls.local, script, self._url, true) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            js_context.page.recordJsError(err);
            const caught = try_catch.caughtOrError(self._script_arena.?.allocator(), err);
            log.err(.browser, "worker module error", .{ .url = self._url, .caught = caught });
            self.fireErrorEvent(caught.exception orelse @errorName(err), null);
            return;
        },
    }

    ls.local.runMacrotasks();
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    self.releaseScriptArena();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    self.releaseScriptArena();

    // TransferCanceled is not a load failure: terminate() (or worker teardown)
    // cancelled a still-inflight script fetch. We shouldn't fireErrorEvent
    // (or bother logging)
    const canceled = err == error.TransferCanceled;
    if (!canceled) {
        log.err(.browser, "worker fetch error", .{
            .url = self._url,
            .err = err,
        });
    }

    // The worker will never load and onmessage will never be registered.
    // Drain any buffered messages so they get dispatched (and silently
    // dropped at the "no listener" check) rather than accumulating until
    // worker teardown. Future postMessages then schedule normally.
    self._script_loaded = true;
    self._worker_scope.drainPendingMessages();

    if (!canceled) {
        self.fireErrorEvent(@errorName(err), null);
    }
}

fn releaseScriptArena(self: *Worker) void {
    const arena = self._script_arena orelse return;
    self._script_arena = null;
    self._script_buffer = .empty;
    arena.release();
}

// Fire an error event on the Worker object (parent context)
fn fireErrorEvent(self: *Worker, message: []const u8, error_value: ?js.Value.Global) void {
    self._fireErrorEvent(message, error_value) catch |err| {
        log.warn(.browser, "worker fire error", .{ .err = err, .message = message });
    };
}

fn _fireErrorEvent(self: *Worker, message: []const u8, error_value: ?js.Value.Global) !void {
    const e = self.exec();
    const target = self.asEventTarget();

    // Check if there are any listeners
    if (!e.hasDirectListeners(target, "error", null)) {
        if (error_value) |ev| ev.release();
        return;
    }

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = error_value,
        .message = message,
        .filename = self._url,
        .bubbles = false,
        .cancelable = true,
    }, e.page);

    try e.dispatch(target, error_event.asEvent(), null, .{
        .context = "Worker.onerror",
    });
}

pub fn terminate(self: *Worker) void {
    // Abort any pending script fetch
    if (self._http_transfer) |resp| {
        resp.cancel();
        self._http_transfer = null;
    }
}

// Posts a message from the frame to the worker.
pub fn postMessage(self: *Worker, data: js.Value) !void {
    try self._worker_scope.receiveMessage(data);
}

// Called internally by DedicatedWorkerGlobalScope when it wants to post a message to us
pub fn receiveMessage(self: *Worker, data: js.Value) !void {
    const ctx = self._global.getJs();
    const cloned_data = blk: {
        var ls: js.Local.Scope = undefined;
        ctx.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker context) to our Page's context
        const cloned = data.structuredCloneTo(&ls.local, null) catch |err| break :blk err;
        break :blk cloned.persist();
    };

    const message_arena = try ctx.page.getArena(.tiny, "Worker.receiveMessage");
    errdefer message_arena.release();

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .worker = self,
        .data = cloned_data,
        .arena = message_arena,
    };

    try ctx.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "Worker.receiveMessage",
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

const ReceiveMessageCallback = struct {
    data: anyerror!js.Value.Global,
    arena: *lp.Arena,
    worker: *Worker,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| {
            d.release();
        } else |_| {}
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.arena.release();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker = self.worker;
        const e = worker.exec();
        const target = worker.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        const data = self.data catch |err| {
            if (!e.hasDirectListeners(target, "messageerror", null)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .data = .{ .string = @errorName(err) },
                .bubbles = false,
                .cancelable = false,
            }, e.page)).asEvent();
            try e.dispatch(target, event, null, .{ .context = "Worker.messageerror" });
            return null;
        };

        // Check if there are any listeners before creating the event
        if (!e.hasDirectListeners(target, "message", null)) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .bubbles = false,
            .cancelable = false,
        }, e.page)).asEvent();

        try e.dispatch(target, event, null, .{ .context = "Worker.receiveMessage" });

        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Worker);

    pub const Meta = struct {
        pub const name = "Worker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // `onerror` comes from the AbstractWorker mixin, which Chrome installs
        // per context rather than on the template, so it lands behind
        // `constructor` (measured).
        pub const constructor_after = "terminate";
    };

    fn handler(comptime which: @import("global_event_handlers.zig").Handler) type {
        return @import("handler_property.zig").accessors(Worker, which);
    }

    pub const constructor = bridge.constructor(Worker.init, .{});

    pub const onmessage = bridge.accessor(handler(.onmessage).get, handler(.onmessage).set, .{});
    pub const postMessage = bridge.function(Worker.postMessage, .{});
    pub const terminate = bridge.function(Worker.terminate, .{});
    // No `onmessageerror`: Chrome's Worker.prototype does not carry one
    // (measured), even though the mixin it would come from does elsewhere.
    pub const onerror = bridge.accessor(handler(.onerror).get, handler(.onerror).set, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Worker" {
    testing.silenceLog(&.{ .http, .browser, .browser });

    // Worker tests chain a worker-script fetch with a dynamic-import fetch
    // and a cross-context postMessage. The default 2 s assertion budget can
    // blow up on TSAN CI; give it more room.
    try testing.htmlRunner("worker", .{ .timeout_ms = 8000 });
}
