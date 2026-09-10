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

// The struct is like a mix of Page and Window, but a very limited Page and
// a very limited Window. This dual-purpose does make it a bit harder to know
// what's what...e.g what is a WebAPI call and what it called internally.

const std = @import("std");
const lp = @import("lightpanda");

const JS = @import("../js/js.zig");
const referrer = @import("../referrer.zig");
const URL = @import("../URL.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const Session = @import("../Session.zig");
const HttpClient = @import("../../network/HttpClient.zig");
const EventManagerBase = @import("../EventManagerBase.zig");
const ScriptManagerBase = @import("../ScriptManagerBase.zig");

const Event = @import("Event.zig");
const global_event_handlers = @import("global_event_handlers.zig");
const Crypto = @import("Crypto.zig");
const cache_storage = @import("storage/cache_storage.zig");
const ImageBitmap = @import("canvas/ImageBitmap.zig");
const Console = @import("Console.zig");
const WorkerNavigator = @import("WorkerNavigator.zig");
const Timers = @import("Timers.zig");
// This fork keeps Scheduler, TaskSignal, TaskController and
// TaskPriorityChangeEvent in one module, so the alias is lower-case even
// though the file is not: the path stays `Scheduler.zig` to keep the shared
// history with upstream, which a case-only rename hides on a
// case-insensitive filesystem.
const scheduler = @import("Scheduler.zig");
const EventTarget = @import("EventTarget.zig");
const Performance = @import("Performance.zig");
const trusted_types = @import("trusted_types.zig");
const Worker = @import("Worker.zig");
const WorkerLocation = @import("WorkerLocation.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const Fetch = @import("net/Fetch.zig");
const idb = @import("storage/idb/idb.zig");
const FontFaceSet = @import("css/FontFaceSet.zig");
const filesystem = @import("filesystem.zig");
const CookieStore = @import("storage/CookieStore.zig");
const MessagePort = @import("MessagePort.zig");
const SharedWorkerGlobalScope = @import("SharedWorkerGlobalScope.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const WorkerGlobalScope = @This();

pub const Proto = EventTarget;

_type: Type,
_frame: *Frame,
_is_module: bool,

// Meant to follow the same field naming as Page so that an anytype of generic
// can access these the same for a Page of a WGS.
// These fields represent the "Page"-like component of the WGS
_page: *Page,
_session: *Session,
_factory: *Factory,
_identity: JS.Identity = .{},
_http_owner: HttpClient.Owner,

arena: Allocator,
_call_arena: *lp.Arena,
_local_arena: *lp.Arena,
call_arena: Allocator,
local_arena: Allocator,
url: [:0]const u8,
// Same-origin constraint: a worker's origin is inherited from its parent frame.
origin: ?[]const u8 = null,
buf: [1024]u8 = undefined, // same size as frame.buf
// Document charset (matches Page.charset). Workers default to UTF-8.
charset: []const u8 = "UTF-8",
js: *JS.Context,

// HTTP attribution
_frame_id: u32,
_loader_id: u32,

// Event management for non-DOM targets in worker context
_event_manager: EventManagerBase,

// Handles module imports (static + dynamic). No parser integration since
// workers don't have <script> tags.
_script_manager: ScriptManagerBase,

// List of open BroadcastChannels, used to route  HTTP attribution. Mirrors Frame's fiage between same-named
// channels in this worker's origin
_broadcast_channels: std.DoublyLinkedList = .{},

// The dedicated workers this worker started. A worker can start another one, so
// the list Frame keeps for the document has to exist here too -- it is what
// tears the children down when this realm dies.
_workers: std.ArrayList(*Worker) = .empty,

// List of MessagePorts living in this worker's context.
_message_ports: std.DoublyLinkedList = .{},

// These fields represent the "Window"-like component of the WGS
_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_navigator: WorkerNavigator = .{},
_performance: *Performance,
_idb_factory: ?*idb.IDBFactory = null,
// `self.fonts`, the worker realm's counterpart to `document.fonts`. Its own,
// for the same reason the trusted-types factory below is: the set is an
// EventTarget, and its listener list has to be this realm's.
_fonts: ?*FontFaceSet = null,
// The two sandboxed filesystems `webkitRequestFileSystem` hands out, this
// realm's own for the same reason -- see slotsFor in filesystem.zig. Chrome's
// worker carries both operations (measured).
_filesystems: [2]?*filesystem.DOMFileSystem = .{ null, null },
_caches: cache_storage.CacheStorage = .init,
_on_language_change: ?JS.Function.Global = null,
_on_error: ?JS.Function.Global = null,
_on_rejection_handled: ?JS.Function.Global = null,
_on_unhandled_rejection: ?JS.Function.Global = null,
_cookie_store: ?*CookieStore = null,

_location: WorkerLocation,

_timers: Timers = .{},
_scheduler: scheduler.Scheduler = .init,
// The factory is per-realm state: it caches emptyHTML/emptyScript, which keep
// their identity across reads. A worker gets its own rather than reaching for
// the owning frame's -- see the module comment in trusted_types.zig.
_trusted_types: trusted_types.TrustedTypePolicyFactory = .init,

pub const Type = union(enum) {
    shared: *SharedWorkerGlobalScope,
    dedicated: *DedicatedWorkerGlobalScope,
};

pub fn init(
    arena: Allocator,
    url: [:0]const u8,
    comptime tag: std.meta.Tag(Type),
    leaf_value: anytype,
    is_module: bool,
    frame_id: u32,
    loader_id: u32,
    frame: *Frame,
) !*@TypeOf(leaf_value) {
    const session = frame._session;

    const call_arena = try session.getArena(.small, "WorkerGlobalScope.call_arena");
    errdefer call_arena.release();

    const local_arena = try session.getArena(.small, "WorkerGlobalScope.local_arena");
    errdefer local_arena.release();

    const factory = frame._factory;
    const leaf = try Factory.chainedWithAllocator(arena, .{
        EventTarget{ ._type = .worker_global_scope },
        WorkerGlobalScope{
            .url = url,
            .arena = arena,
            .origin = frame.origin,
            .js = undefined,
            ._call_arena = call_arena,
            ._local_arena = local_arena,
            .call_arena = call_arena.allocator(),
            .local_arena = local_arena.allocator(),
            ._frame = frame,
            ._page = frame._page,
            ._session = session,
            ._identity = .{},
            ._type = undefined,
            ._proto = undefined,
            ._factory = factory,
            ._is_module = is_module,
            ._frame_id = frame_id,
            ._loader_id = loader_id,
            ._event_manager = .init(arena),
            ._script_manager = undefined,
            ._location = .{ ._url = url },
            // A worker inherits its owner's cross-origin isolation, so it
            // inherits the clock clamp that follows from it. Settled once at
            // birth: a worker outlives no navigation of the frame that made it.
            // Heap-allocated on the worker's own arena rather than inline:
            // Performance is an EventTarget, and the prototype chain is one
            // allocation with the parent immediately before the child.
            ._performance = try factory.eventTargetWithAllocator(arena, Performance.init(if (frame.cross_origin_isolated)
                Performance.clock_resolution_isolated_micros
            else
                Performance.clock_resolution_micros)),
            ._http_owner = undefined,
        },
        leaf_value,
    });
    const self = leaf._proto;
    self._type = @unionInit(Type, @tagName(tag), leaf);

    self._http_owner = .init(&frame._page.blob_urls, &self.origin);

    self._script_manager = ScriptManagerBase.init(
        arena,
        &session.browser.http_client,
        .{ .worker = self },
    );

    self.js = try session.browser.env.createWorkerContext(self, .{
        .call_arena = call_arena.allocator(),
        .local_arena = local_arena.allocator(),
        .identity_arena = arena,
        .identity = &self._identity,
    });

    // A dedicated worker is in the same agent cluster and inherits its creator's
    // origin. Adopt the parent frame's origin (shared *Origin + v8 security
    // token) in place of the context's initial opaque one, so same-origin
    // features like BroadcastChannel can reach across the page/worker boundary.
    try self.js.setOrigin(self.origin);

    // Same for the [SecureContext] gate, and once is enough: a worker realm has
    // no navigation, so its answer cannot change after this. Measured on a
    // headed Chrome 151, a worker owned by an insecure page sees 243 globals
    // against 336 for one owned by a trustworthy origin.
    if (frame.secure_context == false) {
        self.js.hideSecureContextGlobals();
    }

    return leaf;
}

pub fn deinit(self: *WorkerGlobalScope) void {
    const page = self._page;
    const session = page.session;
    const browser = session.browser;

    browser.http_client.abortOwner(&self._http_owner);

    // Close this worker's MessagePorts before the context dies: this severs
    // entanglement with page-side ports (which may outlive us) and releases
    // any still-queued messages.
    while (self._message_ports.first) |node| {
        const port: *MessagePort = @alignCast(@fieldParentPtr("_node", node));
        port.close(); // removes from self._message_ports
    }

    // The reference `getFonts` took, released the way Frame.deinit releases the
    // document's: the set holds a pooled arena, and nothing else drops it.
    if (self._fonts) |fonts| {
        fonts.releaseRef(page);
    }

    self._identity.deinit();
    self._script_manager.deinit();

    page.revokeBlobUrlsFor(self._frame_id);
    browser.env.destroyContext(self.js);

    // After the context is destroyed, the same order Frame.deinit uses: a
    // finalizer can still reach into a child *Worker, so it has to outlive the
    // context that might touch it.
    for (self._workers.items) |worker| {
        worker.deinit();
    }
    self._call_arena.release();
    self._local_arena.release();
}

pub fn trackWorker(self: *WorkerGlobalScope, worker: *Worker) !void {
    try self._workers.append(self.arena, worker);
}

pub fn removeWorker(self: *WorkerGlobalScope, worker: *Worker) void {
    for (self._workers.items, 0..) |w, i| {
        if (w == worker) {
            _ = self._workers.swapRemove(i);
            break;
        }
    }
}

pub fn base(self: *const WorkerGlobalScope) [:0]const u8 {
    return self.url;
}

pub fn asEventTarget(self: *WorkerGlobalScope) *EventTarget {
    return self._proto;
}

// Dispatch an event to listeners on the given target within this worker context.
pub fn dispatch(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    try self._event_manager.dispatchDirect(
        self.call_arena,
        self.js,
        target,
        event,
        handler,
        self._page,
        opts,
    );
}

pub fn hasDirectListeners(self: *WorkerGlobalScope, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

/// The listener lists and the `on*` handler store this scope dispatches
/// against. Mirrors Frame.eventManagerBase.
pub fn eventManagerBase(self: *WorkerGlobalScope) *EventManagerBase {
    return &self._event_manager;
}

pub fn setEventHandler(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    handler: global_event_handlers.Handler,
    callback: ?JS.Function.Global,
) !void {
    return self._event_manager.setHandler(target, handler, callback);
}

pub fn getEventHandler(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    handler: global_event_handlers.Handler,
) ?JS.Function.Global {
    return self._event_manager.getHandler(target, handler);
}

// A worker's requests take their Referer from the worker's OWN script URL, not
// from the owning document -- measured on Chrome 151, where a worker loaded
// from `/w/url-worker.js` fetches with `Referer: .../w/url-worker.js` while the
// page that made it sits at `/top` (tools/fingerprint/scratch/b120). A worker
// whose script is a blob: URL therefore sends no Referer at all, which is what
// the cf-scrapingcourse challenge's own worker does; referrer.compute is where
// that falls out.
//
// The referrer POLICY is still the owning frame's: a worker inherits its
// creator's policy container.
pub fn headersForRequest(self: *WorkerGlobalScope, transfer: *HttpClient.Transfer) !void {
    const arena = transfer.arena.allocator();
    if (try referrer.compute(arena, self._frame.referrer_policy, self.url, transfer.req.url)) |ref| {
        try transfer.setHeader("Referer", ref, .{});
        transfer.req.referrer_policy = self._frame.referrer_policy;
    }
}

pub fn isSameOrigin(self: *const WorkerGlobalScope, url: [:0]const u8) bool {
    const current_origin = self.origin orelse return false;
    return URL.isSameOrigin(url, current_origin);
}

pub fn makeRequest(self: *WorkerGlobalScope, req: HttpClient.Request) !void {
    var r = req;
    r.from_worker = true;
    r.partition = self._frame.storagePartition();
    const transfer = try self._session.browser.http_client.newRequest(r, &self._http_owner);
    {
        errdefer transfer.deinit();
        try self.headersForRequest(transfer);
    }
    return transfer.submit();
}

// Two-phase variant; see HttpClient.newRequest for the ownership contract.
pub fn newRequest(self: *WorkerGlobalScope, req: HttpClient.Request) !*HttpClient.Transfer {
    var r = req;
    r.from_worker = true;
    r.document_frame_id = self._frame._frame_id;
    // Same delegation as headersForRequest above, and for the same reason: the
    // partition a worker's requests sit in is the owning document's.
    r.partition = self._frame.storagePartition();
    return self._session.browser.http_client.newRequest(r, &self._http_owner);
}

pub fn getSelf(self: *WorkerGlobalScope) *WorkerGlobalScope {
    return self;
}

pub fn setSelf(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "self");
}

pub fn getConsole(self: *WorkerGlobalScope) *Console {
    return &self._console;
}

pub fn setConsole(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "console");
}

pub fn getCrypto(self: *WorkerGlobalScope) *Crypto {
    return &self._crypto;
}

pub fn getNavigator(self: *WorkerGlobalScope) *WorkerNavigator {
    return &self._navigator;
}

// The worker's own origin when it has one, otherwise the frame it was created
// from -- a worker inherits its owner's origin and a blob: worker has no other.
// Chrome holds this as a [Replaceable] accessor on WorkerGlobalScope.prototype:
// enumerable, configurable, with a setter that defines an own property over it
// (measured, probes/expr-worker-surface.js).
pub fn getOrigin(self: *const WorkerGlobalScope) []const u8 {
    return self.origin orelse (self._frame.origin orelse "null");
}

pub fn setOrigin(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "origin");
}

// COOP+COEP isolation belongs to the agent cluster, not to the document, so a
// worker answers what its owner answers. The window realm already reads this
// off the committing response (Frame.commitCrossOriginIsolated); the worker was
// left without the property at all, which on a Cloudflare challenge means the
// page says true and the thread one over says undefined.
pub fn getCrossOriginIsolated(self: *const WorkerGlobalScope) bool {
    return self._frame.cross_origin_isolated;
}

pub fn getScheduler(self: *WorkerGlobalScope) *scheduler.Scheduler {
    return &self._scheduler;
}

pub fn getTrustedTypes(self: *WorkerGlobalScope) *trusted_types.TrustedTypePolicyFactory {
    return &self._trusted_types;
}

pub fn performance(self: *WorkerGlobalScope) *Performance {
    return self._performance;
}

pub fn getLocation(self: *WorkerGlobalScope) *WorkerLocation {
    return &self._location;
}

// The owner's answer -- a worker script has to be same-origin with the document
// that spawned it, so there is nothing of its own to judge.
pub fn getIsSecureContext(self: *const WorkerGlobalScope) bool {
    return self._frame.secure_context;
}

pub fn getCookieStore(self: *WorkerGlobalScope) !*CookieStore {
    if (self._cookie_store) |cs| return cs;
    const cs = try self._factory.eventTargetWithAllocator(self.arena, CookieStore{ ._proto = undefined });
    self._cookie_store = cs;
    return cs;
}

pub fn getCaches(self: *WorkerGlobalScope) *cache_storage.CacheStorage {
    return &self._caches;
}

pub fn getOnLanguageChange(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_language_change;
}

pub fn setOnLanguageChange(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_language_change = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

const base64 = @import("encoding/base64.zig");
// Not 'DedicatedWorkerGlobalScope' / 'SharedWorkerGlobalScope': Chrome names the
// mixin's own interface here, whichever worker flavour is calling.
const base64_messages = base64.Messages("WorkerGlobalScope");

pub fn btoa(_: *const WorkerGlobalScope, input: base64.BinInput, exec: *JS.Execution) ![]const u8 {
    const bytes = try input.bytes(exec.local_arena, exec.js, base64_messages.btoa_not_latin1);
    return base64.encode(exec.local_arena, bytes);
}

pub fn atob(_: *const WorkerGlobalScope, input: base64.BinInput, exec: *JS.Execution) !JS.String.OneByte {
    const input_bytes = try input.bytes(exec.local_arena, exec.js, base64_messages.atob_not_latin1);
    const bytes = base64.decode(exec.local_arena, input_bytes) catch |err| switch (err) {
        error.InvalidCharacterError => return exec.js.fail(err, base64_messages.atob_not_encoded),
        else => return err,
    };
    return .{ .bytes = bytes };
}

pub fn structuredClone(_: *const WorkerGlobalScope, value: JS.Value) !JS.Value {
    return value.structuredClone("Failed to execute 'structuredClone' on 'WorkerGlobalScope': ");
}

pub fn unhandledPromiseRejection(self: *WorkerGlobalScope, no_handler: bool, promise: JS.Promise, reason: ?JS.Value) !void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "worker",
            .value = reason,
            .stack = promise.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    if (no_handler) {
        self._page.recordJsError(error.JsException);
    }

    const target = self.asEventTarget();
    if (self._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (reason) |r| try r.persist() else null,
            .promise = try promise.persist(),
        }, self._page)).asEvent();
        try self.dispatch(target, event, attribute_callback, .{});
    }
}

pub fn importScripts(self: *WorkerGlobalScope, urls: []const [:0]const u8) !void {
    if (self._is_module) {
        // not allowed to be called when the worker type is module (scripts should
        // use actual imports).
        return error.TypeError;
    }

    const session = self._session;
    // HttpClient will take out a larger arena for the body, if necessary
    const arena = try session.getArena(.small, "importScript");
    defer arena.release();

    for (urls) |url| {
        defer arena.resetRetain();
        try self.importScript(arena.allocator(), url);
    }
}

fn importScript(self: *WorkerGlobalScope, arena: Allocator, url: [:0]const u8) !void {
    const session = self._session;

    const resolved_url = try URL.resolve(arena, self.url, url, .{});

    const http_client = &session.browser.http_client;

    const transfer = http_client.newRequest(.{
        .url = resolved_url,
        .method = .GET,
        .frame_id = self._frame_id,
        .document_frame_id = self._frame._frame_id,
        .loader_id = self._loader_id,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = self.url,
        .resource_type = .script,
        .from_worker = true,
        .partition = self._frame.storagePartition(),
        .notification = session.notification,
        .shutdown_callback = HttpClient.noopShutdown, // syncRequest installs its own
    }, &self._http_owner) catch |err| {
        log.warn(.http, "importScript", .{ .url = resolved_url, .err = err });
        return error.NetworkError;
    };
    {
        errdefer transfer.deinit();
        try self.headersForRequest(transfer);
    }

    var response = http_client.syncRequest(transfer) catch |err| {
        log.warn(.http, "importScript", .{ .url = resolved_url, .err = err });
        return error.NetworkError;
    };
    defer response.deinit();

    if (response.status != 200) {
        log.warn(.http, "importScript", .{ .url = resolved_url, .status = response.status });
        return error.NetworkError;
    }

    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: JS.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = ls.local.eval(response.body.items, url) catch |err| {
        self._page.recordJsError(err);
        const caught = try_catch.caughtOrError(arena, err);
        log.err(.browser, "importScript", .{ .url = resolved_url, .caught = caught });
        return;
    };

    ls.local.runMacrotasks();
}

pub fn reportError(self: *WorkerGlobalScope, err: JS.Value) !void {
    self._page.recordJsError(error.JsException);

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, self._page);

    // Invoke onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = local_func.call(JS.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }) catch null;

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try self.dispatch(self.asEventTarget(), event, null, .{});

    if (comptime lp.IS_TEST == false) {
        if (!event._prevent_default) {
            log.warn(.js, "worker.reportError", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn fetch(_: *const WorkerGlobalScope, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const JS.Execution) !JS.Promise {
    return Fetch.init(input, options, exec);
}

pub fn queueMicrotask(self: *WorkerGlobalScope, cb: JS.Function) void {
    self.js.queueMicrotaskFunc(cb);
}

pub fn setTimeout(self: *WorkerGlobalScope, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []JS.Value.Global, exec: *JS.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .name = "worker.setTimeout",
    });
}

pub fn clearTimeout(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn setInterval(self: *WorkerGlobalScope, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []JS.Value.Global, exec: *JS.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .name = "worker.setInterval",
    });
}

pub fn clearInterval(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn getFonts(self: *WorkerGlobalScope, exec: *const JS.Execution) !*FontFaceSet {
    if (self._fonts) |fonts| {
        return fonts;
    }
    const fonts = try FontFaceSet.init(exec);
    fonts.acquireRef();
    self._fonts = fonts;
    return fonts;
}

pub fn getIndexedDB(self: *WorkerGlobalScope, exec: *JS.Execution) !*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    const f = try exec._factory.create(idb.IDBFactory{});
    self._idb_factory = f;
    return f;
}

// Some properties are readonly but [Replaceable]. They get assigned as own
// data properties on the underlying v8::object that represents the global (the
// WorkerGlobalScope)
fn replaceGlobalProperty(self: *WorkerGlobalScope, value: JS.Value, comptime name: []const u8) void {
    const global = self.js.globalObject(value.local);
    _ = global.defineOwnProperty(name, value, 0);
}

pub const FunctionSetter = union(enum) {
    func: JS.Function.Global,
    anything: JS.Value,
};

pub fn getFunctionFromSetter(setter_: ?FunctionSetter) ?JS.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = JS.Bridge(WorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "WorkerGlobalScope";
        // Chrome's `constructor` sits after `importScripts`; everything below
        // it is installed per context. Measured in a blob worker.
        pub const constructor_after = "importScripts";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own-property order for WorkerGlobalScope.prototype, measured in
    // a blob worker on Chrome 151 (probes/expr-worker-proto-table.js):
    //
    //   self, location, onerror, onlanguagechange, navigator,
    //   onrejectionhandled, onunhandledrejection, origin, performance,
    //   trustedTypes, crypto, indexedDB, fonts, createImageBitmap, fetch,
    //   importScripts, constructor, isSecureContext, crossOriginIsolated,
    //   scheduler, caches, atob, btoa, queueMicrotask, reportError,
    //   structuredClone, clearInterval, clearTimeout, setInterval, setTimeout
    //
    // The members after `constructor` are the ones Blink installs per context;
    // see Meta.constructor_after above.
    pub const self = bridge.accessor(WorkerGlobalScope.getSelf, WorkerGlobalScope.setSelf, .{});
    pub const location = bridge.accessor(WorkerGlobalScope.getLocation, null, .{});
    pub const onerror = bridge.accessor(WorkerGlobalScope.getOnError, WorkerGlobalScope.setOnError, .{});
    pub const onlanguagechange = bridge.accessor(WorkerGlobalScope.getOnLanguageChange, WorkerGlobalScope.setOnLanguageChange, .{});
    pub const navigator = bridge.accessor(WorkerGlobalScope.getNavigator, null, .{});
    pub const onrejectionhandled = bridge.accessor(WorkerGlobalScope.getOnRejectionHandled, WorkerGlobalScope.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(WorkerGlobalScope.getOnUnhandledRejection, WorkerGlobalScope.setOnUnhandledRejection, .{});

    // Measured on a headless Chrome 151 blob worker (probes/expr-worker-surface
    // .js): `origin` is [Replaceable], so it has a setter as well as a getter.
    pub const origin = bridge.accessor(WorkerGlobalScope.getOrigin, WorkerGlobalScope.setOrigin, .{});
    pub const performance = bridge.accessor(struct {
        // Unnecessary, But, our WebAPI getters are ALWAYS `fn getPerformance()...`.
        // But for performance, we _need_ to have fn performance() *Performance to
        // have parity with frame. So rather than having method called `performance`
        // and one called `getPerformance`, we create this wrapper here.
        pub fn wrap(wgs: *WorkerGlobalScope) *Performance {
            return wgs.performance();
        }
    }.wrap, null, .{});
    pub const trustedTypes = bridge.accessor(WorkerGlobalScope.getTrustedTypes, null, .{});
    pub const crypto = bridge.accessor(WorkerGlobalScope.getCrypto, null, .{});
    pub const indexedDB = bridge.accessor(WorkerGlobalScope.getIndexedDB, null, .{});
    pub const fonts = bridge.accessor(WorkerGlobalScope.getFonts, null, .{});
    pub const createImageBitmap = bridge.function(struct {
        fn createImageBitmap(
            _: *WorkerGlobalScope,
            source: ?JS.Value,
            sx: ?JS.Value,
            sy: ?JS.Value,
            sw: ?JS.Value,
            sh: ?JS.Value,
            exec: *const JS.Execution,
        ) !JS.Promise {
            return ImageBitmap.create(source, sx, sy, sw, sh, exec);
        }
    }.createImageBitmap, .{ .arity = 1 });
    pub const fetch = bridge.function(WorkerGlobalScope.fetch, .{});
    // A variadic operation's arity is 0, and the bridge would count the
    // variadic slice as one required argument (measured: Chrome's
    // `importScripts.length` is 0, this engine answered 1 -- read from inside
    // a worker, where the sensor reads it).
    pub const importScripts = bridge.function(WorkerGlobalScope.importScripts, .{ .arity = 0 });

    // A worker's secure-context state is its owner's, not a constant: measured
    // on a headed Chrome 151, a worker on http://localhost:8777 answers true
    // and one on http://192.168.68.78:8777 answers false, and its global
    // surface follows (336 own names vs 243). Chrome holds it as an
    // enumerable, configurable getter on WorkerGlobalScope.prototype, which is
    // an accessor here rather than the read-only data property it used to be.
    pub const isSecureContext = bridge.accessor(WorkerGlobalScope.getIsSecureContext, null, .{});
    pub const crossOriginIsolated = bridge.accessor(WorkerGlobalScope.getCrossOriginIsolated, null, .{});
    pub const scheduler = bridge.accessor(WorkerGlobalScope.getScheduler, null, .{});
    pub const caches = bridge.accessor(WorkerGlobalScope.getCaches, null, .{});
    pub const atob = bridge.function(WorkerGlobalScope.atob, .{});
    pub const btoa = bridge.function(WorkerGlobalScope.btoa, .{});
    pub const queueMicrotask = bridge.function(WorkerGlobalScope.queueMicrotask, .{});
    pub const reportError = bridge.function(WorkerGlobalScope.reportError, .{});
    pub const structuredClone = bridge.function(WorkerGlobalScope.structuredClone, .{});
    pub const clearInterval = bridge.function(WorkerGlobalScope.clearInterval, .{});
    pub const clearTimeout = bridge.function(WorkerGlobalScope.clearTimeout, .{});
    pub const setInterval = bridge.function(WorkerGlobalScope.setInterval, .{});
    pub const setTimeout = bridge.function(WorkerGlobalScope.setTimeout, .{});
};
