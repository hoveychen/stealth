// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Context = @import("Context.zig");
const Isolate = @import("Isolate.zig");
const Platform = @import("Platform.zig");
const Inspector = @import("Inspector.zig");

const App = @import("../../App.zig");
const Frame = @import("../Frame.zig");
const Chrome = @import("../webapi/Chrome.zig");
const Window = @import("../webapi/Window.zig");
const access_check = @import("access_check.zig");
const trusted_types = @import("../webapi/trusted_types.zig");
const WorkerGlobalScope = @import("../webapi/WorkerGlobalScope.zig");
const SharedWorkerGlobalScope = @import("../webapi/SharedWorkerGlobalScope.zig");
const DedicatedWorkerGlobalScope = @import("../webapi/DedicatedWorkerGlobalScope.zig");

const v8 = js.v8;
const log = lp.log;

const JsApis = bridge.JsApis;
const Allocator = std.mem.Allocator;

const MAX_CONTEXTS = if (lp.build_config.wpt_extensions) 8192 else 128;

const GC_HINT_FLOOR = 1 * 1024 * 1024;

fn initClassIds() void {
    @setEvalBranchQuota(JsApis.len * 8);
    inline for (JsApis, 0..) |JsApi, i| {
        JsApi.Meta.class_id = i;
    }
}

var class_id_once = lp.once(initClassIds);

// The Env maps to a V8 isolate, which represents a isolated sandbox for
// executing JavaScript. The Env is where we'll define our V8 <-> Zig bindings,
// and it's where we'll start ExecutionWorlds, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an ExecutionWorld, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
const Env = @This();

app: *App,

allocator: Allocator,

platform: *const Platform,

// the global isolate
isolate: js.Isolate,

contexts: std.ArrayList(*Context),

// just kept around because we need to free it on deinit
isolate_params: *v8.CreateParams,

context_id: usize,

// Maps origin -> shared Origin contains, for v8 values shared across
// same-origin Contexts. There's a mismatch here between our JS model and our
// Browser model. Origins only live as long as the root frame of a session exists.
// It would be wrong/dangerous to re-use an Origin across root frame navigations.

// Global handles that need to be freed on deinit
eternal_function_templates: []v8.Eternal,

// Dynamic slice to avoid circular dependency on JsApis.len at comptime
templates: []*const v8.FunctionTemplate,

// Inspector associated with the Isolate. Exists when CDP is being used.
inspector: ?*Inspector,

// We can store data in a v8::Object's Private data bag. The keys are v8::Private
// which an be created once per isolaet.
private_symbols: PrivateSymbols,

microtask_queues_are_running: bool,

// Serializes V8 calls that race with TerminateExecution (which can fire from
// the sighandler thread). Without this, a terminate landing between the
// IsExecutionTerminating check and PerformCheckpoint trips a V8 debug assert.
terminate_mutex: std.Io.Mutex = .init,

// Set from network thread, saying termination should happen. Read from worker
// thread making sure terminate hasn't been canceled.
terminate_requested: std.atomic.Value(bool) = .init(false),

pub const InitOpts = struct {
    with_inspector: bool = false,
};

pub fn init(app: *App, opts: InitOpts) !Env {
    if (comptime lp.IS_DEBUG) {
        comptime {
            // V8 requirement for any data using SetAlignedPointerInInternalField
            const a = @alignOf(@import("TaggedOpaque.zig"));
            std.debug.assert(a >= 2 and a % 2 == 0);
        }
    }

    // Initialize class IDs once before any V8 work
    class_id_once.call();

    const allocator = app.allocator;
    const snapshot = &app.snapshot;

    var params = try allocator.create(v8.CreateParams);
    errdefer allocator.destroy(params);
    v8.v8__Isolate__CreateParams__CONSTRUCT(params);
    params.snapshot_blob = @ptrCast(&snapshot.startup_data);

    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator().?;
    errdefer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);

    params.external_references = &snapshot.external_references;

    if (app.config.v8MaxHeapMb()) |mb| {
        v8.v8__ResourceConstraints__ConfigureDefaultsFromHeapSize(
            &params.constraints,
            0,
            @as(usize, mb) * 1024 * 1024,
        );
    }

    var isolate = js.Isolate.init(params);
    errdefer isolate.deinit();
    const isolate_handle = isolate.handle;

    v8.v8__Isolate__SetHostImportModuleDynamicallyCallback(isolate_handle, Context.dynamicModuleCallback);
    v8.v8__Isolate__SetPromiseRejectCallback(isolate_handle, promiseRejectCallback);
    v8.v8__Isolate__SetMicrotasksPolicy(isolate_handle, v8.kExplicit);
    v8.v8__Isolate__SetFatalErrorHandler(isolate_handle, fatalCallback);
    v8.v8__Isolate__SetOOMErrorHandler(isolate_handle, oomCallback);
    trusted_types.installCodeGenerationCallback(isolate_handle);
    // Isolate-wide, and inert until a template turns the check on: a refused
    // operation the cross-origin handler did not answer has to throw rather
    // than come back undefined. See browser/js/access_check.zig.
    access_check.installFailureCallback(isolate_handle);

    if (comptime lp.IS_DEBUG) {
        v8.v8__Isolate__SetCaptureStackTraceForUncaughtExceptions(isolate_handle, true, 64);
    }

    isolate.enter();
    errdefer isolate.exit();

    v8.v8__Isolate__SetHostInitializeImportMetaObjectCallback(isolate_handle, Context.metaObjectCallback);

    // Allocate arrays dynamically to avoid comptime dependency on JsApis.len
    const eternal_function_templates = try allocator.alloc(v8.Eternal, JsApis.len);
    errdefer allocator.free(eternal_function_templates);

    const templates = try allocator.alloc(*const v8.FunctionTemplate, JsApis.len);
    errdefer allocator.free(templates);

    var private_symbols: PrivateSymbols = undefined;
    {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();

        @setEvalBranchQuota(JsApis.len * 8);
        inline for (JsApis, 0..) |_, i| {
            const data = v8.v8__Isolate__GetDataFromSnapshotOnce(isolate_handle, snapshot.data_start + i);
            const function_handle: *const v8.FunctionTemplate = @ptrCast(data);
            // Make function template eternal
            v8.v8__Eternal__New(isolate_handle, @ptrCast(function_handle), &eternal_function_templates[i]);

            // Extract the local handle from the global for easy access
            const eternal_ptr = v8.v8__Eternal__Get(&eternal_function_templates[i], isolate_handle);
            templates[i] = @ptrCast(@alignCast(eternal_ptr.?));
        }

        private_symbols = PrivateSymbols.init(isolate_handle);
    }

    var inspector: ?*js.Inspector = null;
    if (opts.with_inspector) {
        inspector = try Inspector.init(allocator, isolate_handle);
    }

    return .{
        .app = app,
        .context_id = 0,
        .allocator = allocator,
        .contexts = .empty,
        .isolate = isolate,
        .platform = &app.platform,
        .templates = templates,
        .isolate_params = params,
        .inspector = inspector,
        .private_symbols = private_symbols,
        .microtask_queues_are_running = false,
        .eternal_function_templates = eternal_function_templates,
    };
}

pub fn deinit(self: *Env) void {
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(self.contexts.items.len == 0);
    }
    for (self.contexts.items) |ctx| {
        ctx.deinit();
    }
    self.contexts.deinit(self.allocator);

    const app = self.app;
    const allocator = app.allocator;

    if (self.inspector) |i| {
        i.deinit(allocator);
    }

    allocator.free(self.templates);
    allocator.free(self.eternal_function_templates);
    self.private_symbols.deinit();

    self.isolate.exit();
    self.isolate.deinit();
    v8.v8__ArrayBuffer__Allocator__DELETE(self.isolate_params.array_buffer_allocator.?);
    allocator.destroy(self.isolate_params);
}

pub const ContextParams = struct {
    identity: *js.Identity,
    identity_arena: Allocator,
    call_arena: Allocator,
    local_arena: Allocator,
    debug_name: []const u8 = "Context",
};

pub fn createContext(self: *Env, frame: *Frame, params: ContextParams) !*Context {
    return self._createContext(frame, params);
}

pub fn createWorkerContext(self: *Env, worker: *WorkerGlobalScope, params: ContextParams) !*Context {
    return self._createContext(worker, params);
}

fn _createContext(self: *Env, global: anytype, params: ContextParams) !*Context {
    const T = @TypeOf(global);
    const is_frame = T == *Frame;

    const context_arena = try self.app.arena_pool.acquire(.medium, params.debug_name);
    errdefer context_arena.release();

    const isolate = self.isolate;
    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();

    // Create a per-context microtask queue for isolation
    const microtask_queue = v8.v8__MicrotaskQueue__New(isolate.handle, v8.kExplicit).?;
    errdefer v8.v8__MicrotaskQueue__DELETE(microtask_queue);

    // Reuse the window's existing global proxy across an in-place navigation.
    // The same *Window keeps its identity_map entry so reattaching it to the
    // new context preserves WindowProxy identity
    const reuse_global_object: ?*const v8.Value = blk: {
        if (comptime !is_frame) break :blk null;
        const existing = params.identity.identity_map.getPtr(@intFromPtr(global.window)) orelse break :blk null;
        break :blk @ptrCast(v8.v8__Global__Get(existing, isolate.handle));
    };

    // Restore the context from the snapshot
    // (0 = Page, 1 = DedicatedWorker, 2 = SharedWorker)
    const snapshot_index: u32 = if (comptime is_frame) 0 else switch (global._type) {
        .dedicated => 1,
        .shared => 2,
    };
    const v8_context = v8.v8__Context__FromSnapshot__Config(isolate.handle, snapshot_index, &.{
        .global_template = null,
        .global_object = reuse_global_object,
        .microtask_queue = microtask_queue,
    }).?;

    // Create the v8::Context and wrap it in a v8::Global
    var context_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, v8_context, &context_global);

    // Get the global object for the context
    const global_obj = v8.v8__Context__Global(v8_context).?;

    // Store our TAO inside the internal field of the global object. This
    // maps the v8::Object -> Zig instance.
    const tao = try params.identity_arena.create(@import("TaggedOpaque.zig"));
    tao.* = if (comptime is_frame) .{
        .value = @ptrCast(global.window),
        .prototype_chain = (&Window.JsApi.Meta.prototype_chain).ptr,
        .prototype_len = @intCast(Window.JsApi.Meta.prototype_chain.len),
        .subtype = .node,
    } else switch (global._type) {
        .dedicated => |scope| .{
            .value = @ptrCast(scope),
            .prototype_chain = (&DedicatedWorkerGlobalScope.JsApi.Meta.prototype_chain).ptr,
            .prototype_len = @intCast(DedicatedWorkerGlobalScope.JsApi.Meta.prototype_chain.len),
            .subtype = null,
        },
        .shared => |scope| .{
            .value = @ptrCast(scope),
            .prototype_chain = (&SharedWorkerGlobalScope.JsApi.Meta.prototype_chain).ptr,
            .prototype_len = @intCast(SharedWorkerGlobalScope.JsApi.Meta.prototype_chain.len),
            .subtype = null,
        },
    };
    v8.v8__Object__SetAlignedPointerInInternalField(global_obj, 0, tao);

    const context_id = self.context_id;
    self.context_id = context_id + 1;

    const page = global._page;
    const origin = try page.getOrCreateOrigin(null);
    errdefer page.releaseOrigin(origin);

    const context = try context_arena.create(Context);
    context.* = .{
        .env = self,
        .global = if (comptime is_frame) .{ .frame = global } else .{ .worker = global },
        .origin = origin,
        .id = context_id,
        .page = page,
        .isolate = isolate,
        .arena = context_arena,
        .handle = context_global,
        .templates = self.templates,
        .call_arena = params.call_arena,
        .local_arena = params.local_arena,
        .microtask_queue = microtask_queue,
        .script_manager = if (comptime is_frame) &global._script_manager.base else &global._script_manager,
        .scheduler = .init(context_arena.allocator()),
        .identity = params.identity,
        .identity_arena = params.identity_arena,
        .execution = undefined,
    };

    context.execution = .{
        .js = context,
        .url = &global.url,
        .buf = &global.buf,
        .charset = &global.charset,
        .arena = global.arena,
        .page = context.page,
        .session = page.session,
        .call_arena = params.call_arena,
        .local_arena = params.local_arena,
        ._factory = global._factory,
        ._scheduler = &context.scheduler,
    };

    // Register in the identity map. Multiple contexts can be created for the
    // same global (via CDP), so we only register the first one.
    const identity_ptr = if (comptime is_frame) @intFromPtr(global.window) else switch (global._type) {
        inline else => |scope| @intFromPtr(scope),
    };
    const gop = try params.identity.identity_map.getOrPut(params.identity_arena, identity_ptr);
    if (gop.found_existing == false) {
        var global_global: v8.Global = undefined;
        v8.v8__Global__New(isolate.handle, global_obj, &global_global);
        gop.value_ptr.* = global_global;
    }

    // Store a pointer to our context inside the v8 context so that, given
    // a v8 context, we can get our context out
    v8.v8__Context__SetAlignedPointerInEmbedderData(v8_context, 1, @ptrCast(context));

    if (self.contexts.items.len >= MAX_CONTEXTS) {
        return error.TooManyContexts;
    }
    try self.contexts.append(self.allocator, context);

    {
        var ls: js.Local.Scope = undefined;
        context.localScope(&ls);
        defer ls.deinit();
        bindWasmStreaming(context, ls.local) catch |err| {
            log.err(.js, "wasm streaming bootstrap", .{ .err = err });
        };

        // Snapshot creation deletes V8's built-in `console` from the global so
        // ours takes over, and it deletes the [Global] copy with it. Chrome has
        // it as an own, non-enumerable data property of `window` (measured on a
        // headed Chrome 150: Object.getOwnPropertyDescriptor(window, 'console')
        // is a value descriptor, and Window.prototype has no `console` at all),
        // and Object.getOwnPropertyNames(window) is a surface fingerprinters
        // read directly -- so the property is put back here, per context.
        //
        // Both realms resolve it from the scope object itself. A worker used to
        // read it back off the global, which worked only because
        // WorkerGlobalScope.prototype carried a `console` accessor -- and Chrome
        // has nothing named console on that prototype (measured,
        // probes/expr-worker-surface.js), so the accessor is gone and the value
        // has to come from the same place the window realm's does.
        const global_object = context.globalObject(&ls.local);
        const console_value = if (comptime is_frame)
            ls.local.zigValueToJs(global.window.getConsole(), .{})
        else
            ls.local.zigValueToJs(global.getConsole(), .{});
        if (console_value) |value| {
            _ = global_object.defineOwnProperty("console", value, v8.DontEnum);
        } else |err| {
            log.err(.js, "console own property", .{ .err = err });
        }

        // `chrome` and `CSS` are data properties of the window in Chrome, not
        // accessors, and the bridge only declares accessors -- so they are
        // installed here for the same reason `console` above is. Descriptors
        // measured on Chrome 151 with
        // tools/fingerprint/scratch/expr-chrome-css-descriptor.js; the kind is
        // readable in one expression (`desc.get` is a function or it is not),
        // and it is the kind a bot check reads a value through when it will not
        // trust the instance to answer honestly.
        //
        // Both keep their identity across reads by construction: there is one
        // of each, built once, per realm.
        if (comptime is_frame) {
            // {writable: true, enumerable: true, configurable: false}, so
            // DontDelete and nothing else. Note it enumerates, unlike every
            // other property installed here.
            if (Chrome.build(&ls.local)) |chrome| {
                _ = global_object.defineOwnProperty("chrome", chrome.toValue(), v8.DontDelete);
            } else |err| {
                log.err(.js, "chrome own property", .{ .err = err });
            }

            // A WebIDL namespace object, which WebIDL §3.2 hangs off the global
            // as {writable: true, enumerable: false, configurable: true} --
            // the same shape `console` gets.
            if (ls.local.zigValueToJs(global.window.getCSS(), .{})) |value| {
                _ = global_object.defineOwnProperty("CSS", value, v8.DontEnum);
            } else |err| {
                log.err(.js, "CSS own property", .{ .err = err });
            }
        }

        // SharedArrayBuffer is behind cross-origin isolation. A real browser
        // that is not isolated does not expose the constructor at all: measured
        // on a headed Chrome 150 at http://localhost:8731/, where
        // `crossOriginIsolated` is false, `typeof SharedArrayBuffer` is
        // "undefined" and it is not a window own property. V8 installs it
        // unconditionally, so it is removed here and the handle kept, for
        // Frame.commitCrossOriginIsolated to hand back to a document that turns
        // out to carry COOP+COEP.
        //
        // Not-isolated is the right state to start in: a context is born before
        // any document commits, and the frame settles the question from the
        // response headers afterwards. `Atomics` (waitAsync included) and
        // `WebAssembly.Memory` are *not* gated with it and stay; also measured.
        //
        // This was the last CreepJS `.unsupport` span between this engine and
        // the reference browser: with it gone both score 128.
        if (global_object.get("SharedArrayBuffer")) |value| {
            var sab_global: v8.Global = undefined;
            v8.v8__Global__New(isolate.handle, value.handle, &sab_global);
            context.shared_array_buffer = sab_global;
        } else |err| {
            log.err(.js, "SharedArrayBuffer stash", .{ .err = err });
        }
        if (global_object.delete("SharedArrayBuffer") != true) {
            log.err(.js, "SharedArrayBuffer gate", .{});
        }

        // Every WebIDL FrozenArray comes back frozen and the only freeze this
        // engine can reach is the JS builtin, so the pristine one is taken here
        // -- before a script can replace it and make the engine call into page
        // code on every FrozenArray read.
        if (context.objectFreeze(&ls.local)) |_| {} else |err| {
            log.err(.js, "Object.freeze stash", .{ .err = err });
        }

        // This fork's WebMCP surface is three names Chrome does not have, and
        // Kasada was measured reading one of them, so a run that did not ask for
        // WebMCP does not carry it. Window realm only: the interfaces are
        // [Exposed=Window] and a worker's navigator never had the member.
        if (comptime is_frame) {
            if (self.app.config.enableWebMcp() == false) {
                context.hideWebMcpSurface();
            }
        }
    }

    return context;
}

pub fn destroyContext(self: *Env, context: *Context) void {
    for (self.contexts.items, 0..) |ctx, i| {
        if (ctx == context) {
            _ = self.contexts.swapRemove(i);
            break;
        }
    } else {
        if (comptime lp.IS_DEBUG) {
            @panic("Tried to remove unknown context");
        }
    }

    const isolate = self.isolate;
    if (self.inspector) |inspector| {
        var hs: js.HandleScope = undefined;
        hs.init(isolate);
        defer hs.deinit();
        inspector.contextDestroyed(@ptrCast(v8.v8__Global__Get(&context.handle, isolate.handle)));
    }

    context.deinit();
}

pub fn runMicrotasks(self: *Env) void {
    if (self.microtask_queues_are_running == false) {
        self.terminate_mutex.lockUncancelable(lp.io);
        defer self.terminate_mutex.unlock(lp.io);

        const v8_isolate = self.isolate.handle;

        if (self.terminatePending()) {
            return;
        }

        self.microtask_queues_are_running = true;
        defer self.microtask_queues_are_running = false;

        // Re-read len/items each iteration: a checkpoint can run JS that creates
        // a new context (e.g. an iframe), appending to (and reallocating) the list.
        var i: usize = 0;
        while (i < self.contexts.items.len) : (i += 1) {
            const ctx = self.contexts.items[i];
            v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, v8_isolate);

            // The checkpoint is where "still unhandled" becomes knowable: every
            // handler that was going to arrive in this turn has arrived. A
            // listener that runs here can queue microtasks of its own, so the
            // queue gets one more pass.
            if (ctx.notifyRejectedPromises()) {
                v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, v8_isolate);
            }

            if (self.terminatePending()) {
                if (v8.v8__Isolate__IsExecutionTerminating(v8_isolate)) {
                    for (self.contexts.items) |c| {
                        if (c.call_depth > 0) {
                            return;
                        }
                    }
                    // None of the contexts are "entered", it's safe to
                    // clear the termination flag.
                    v8.v8__Isolate__CancelTerminateExecution(v8_isolate);
                }
                return;
            }
        }
    }
}

pub fn runMacrotasks(self: *Env) !void {
    if (self.terminatePending()) {
        return;
    }

    // Re-read len/items each iteration: scheduler.run() can create a new context
    // (e.g. an iframe), appending to (and reallocating) the list.
    var i: usize = 0;
    while (i < self.contexts.items.len) : (i += 1) {
        const ctx = self.contexts.items[i];
        if (comptime lp.IS_TEST == false) {
            // I hate this comptime check as much as you do. But we have tests
            // which rely on short execution before shutdown. In real world, it's
            // underterministic whether a timer will or won't run before the
            // frame shutsdown. But for tests, we need to run them to their end.
            if (ctx.scheduler.hasReadyTasks() == false) {
                continue;
            }
        }

        var hs: js.HandleScope = undefined;
        const entered = ctx.enter(&hs);
        defer entered.exit();

        // One turn of the loop for one realm is the closest this engine has to
        // an animation frame: the queue is drained with nothing scheduled
        // between the tasks, and whatever they did is over when it empties. A
        // turn that ran long is what Chrome files a `long-animation-frame` for
        // -- see Performance.taskFrameEnded, and the widget realm it exists
        // for.
        switch (ctx.global) {
            .frame => |frame| {
                const opened = frame.performance().now();
                try ctx.scheduler.run();
                frame.taskFrameEnded(opened);
            },
            // Chrome files no long animation frames in a worker: the entry
            // describes a rendering frame and a worker has none (measured,
            // `probe-shapes-worker` -- a Chrome worker does not even have the
            // interface object).
            .worker => try ctx.scheduler.run(),
        }
    }
}

pub fn hasMacrotasks(self: *Env) bool {
    for (self.contexts.items) |ctx| {
        if (ctx.scheduler.blocksCompletion()) {
            return true;
        }
    }
    return false;
}

pub fn msToNextTask(self: *Env) ?u64 {
    var next_task: u64 = std.math.maxInt(u64);
    for (self.contexts.items) |ctx| {
        const candidate = ctx.scheduler.msToNext() orelse continue;
        next_task = @min(candidate, next_task);
    }
    return if (next_task == std.math.maxInt(u64)) null else next_task;
}

pub fn pumpMessageLoop(self: *const Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Platform__PumpMessageLoop(platform, isolate, false)) {}
}

pub fn hasBackgroundTasks(self: *const Env) bool {
    return v8.v8__Isolate__HasPendingBackgroundTasks(self.isolate.handle);
}

pub fn waitForBackgroundTasks(self: *Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Isolate__HasPendingBackgroundTasks(isolate)) {
        _ = v8.v8__Platform__PumpMessageLoop(platform, isolate, true);
        self.runMicrotasks();
    }
}

pub fn runIdleTasks(self: *const Env) void {
    v8.v8__Platform__RunIdleTasks(self.platform.handle, self.isolate.handle, 1);
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `memoryPressureNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// Skips if there's little to reclaim
pub fn memoryPressureNotification(self: *Env, level: Isolate.MemoryPressureLevel) void {
    const stats = self.isolate.getHeapStatistics();
    if (stats.used_heap_size + stats.external_memory < GC_HINT_FLOOR) {
        return;
    }
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.memoryPressureNotification(level);
}

pub fn dumpMemoryStats(self: *Env) void {
    const stats = self.isolate.getHeapStatistics();
    std.debug.print(
        \\ Total Heap Size: {d}
        \\ Total Heap Size Executable: {d}
        \\ Total Physical Size: {d}
        \\ Total Available Size: {d}
        \\ Used Heap Size: {d}
        \\ Heap Size Limit: {d}
        \\ Malloced Memory: {d}
        \\ External Memory: {d}
        \\ Peak Malloced Memory: {d}
        \\ Number Of Native Contexts: {d}
        \\ Number Of Detached Contexts: {d}
        \\ Total Global Handles Size: {d}
        \\ Used Global Handles Size: {d}
        \\ Zap Garbage: {any}
        \\
    , .{ stats.total_heap_size, stats.total_heap_size_executable, stats.total_physical_size, stats.total_available_size, stats.used_heap_size, stats.heap_size_limit, stats.malloced_memory, stats.external_memory, stats.peak_malloced_memory, stats.number_of_native_contexts, stats.number_of_detached_contexts, stats.total_global_handles_size, stats.used_global_handles_size, stats.does_zap_garbage });
}

// The single "must not run JS" predicate. We're the only ones who ever call
// TerminateExecution (here and in terminateInterrupt) and both set this flag,
// so it's always at least as true as v8__Isolate__IsExecutionTerminating —
// and it stays true after V8 consumes the terminate on the JSEntry unwind,
// which is what stops a fresh eval from re-entering mid-teardown.
pub fn terminatePending(self: *const Env) bool {
    return self.terminate_requested.load(.acquire);
}

pub fn terminate(self: *Env) void {
    self.terminate_mutex.lockUncancelable(lp.io);
    defer self.terminate_mutex.unlock(lp.io);
    self.terminate_requested.store(true, .release);
    v8.v8__Isolate__TerminateExecution(self.isolate.handle);
}

// We need a stable pointer for *Env, so can't be setup in init.
pub fn protectHeapLimit(self: *Env) void {
    v8.v8__Isolate__AddNearHeapLimitCallback(self.isolate.handle, nearHeapLimit, self);
    // TODO: uncomment this when https://github.com/lightpanda-io/zig-v8-fork/pull/187 lands
    // if our nearHeapLimit extends the memory, we want to  restore the original
    // value, since the isolate can be long lived (relative to the page/script
    // that caused the memory spike).
    // v8.v8__Isolate__AutomaticallyRestoreInitialHeapLimit(self.isolate.handle, 0.5);
}

// v8 is telling us it's about to run out of memory for this isolate. We'll
// do two things:
// 1 - Terminate the execution (attempting to prevent v8 from OOM'ing the process)
// 2 - Grant more headroom so execution can reach a stack-guard check, where
//     the terminate lands
//
// The terminate must go through requestTerminate (RequestInterrupt), NOT a
// direct TerminateExecution: we're mid-GC, which is an arbitrary point —
// possibly inside a microtask run — and flagging termination there lets the
// run complete with a result while the isolate is terminating, tripping
// V8's DCHECK(maybe_result.is_null()) in MicrotaskQueue::RunMicrotasks. The
// interrupt lands at a stack-guard check, where termination unwinds the way
// V8 expects.
fn nearHeapLimit(data: ?*anyopaque, current_limit: usize, initial_limit: usize) callconv(.c) usize {
    const self: *Env = @ptrCast(@alignCast(data.?));
    lp.metrics.js_heap_limits.incr();
    log.err(.app, "JS heap limit reached", .{
        .initial_limit = initial_limit,
        .current_limit = current_limit,
    });
    self.requestTerminate();

    const cap = initial_limit + 256 * 1024 * 1024;
    if (current_limit >= cap) {
        return current_limit;
    }
    return @min(cap, current_limit + 64 * 1024 * 1024);
}

// Called from the network thread, caused v8 to eventually call terminateInterrupt
pub fn requestTerminate(self: *Env) void {
    self.terminate_requested.store(true, .release);
    v8.v8__Isolate__RequestInterrupt(self.isolate.handle, terminateInterrupt, self);
}

// Runs on the worker thread
fn terminateInterrupt(_: ?*v8.Isolate, data: ?*anyopaque) callconv(.c) void {
    const self: *Env = @ptrCast(@alignCast(data.?));
    if (self.terminate_requested.load(.acquire)) {
        v8.v8__Isolate__TerminateExecution(self.isolate.handle);
    }
}

/// Clears a pending termination so V8 calls (e.g. those made during cleanup)
/// don't keep tripping over the terminating-state asserts. Safe to call
/// unconditionally; a no-op if termination wasn't pending. Also clears the
/// requestTerminate gate so any still-pending interrupt becomes a no-op.
pub fn cancelTerminate(self: *Env) void {
    self.terminate_mutex.lockUncancelable(lp.io);
    defer self.terminate_mutex.unlock(lp.io);
    self.terminate_requested.store(false, .release);
    v8.v8__Isolate__CancelTerminateExecution(self.isolate.handle);
}

/// Like `runMicrotasks`, but for the isolate-default queue used by contexts
/// created outside `createContext` (the agent runtime's bare context), which
/// aren't tracked in `contexts`. Guarded so a sighandler-thread terminate
/// can't land mid-checkpoint.
pub fn performIsolateMicrotasks(self: *Env) void {
    self.terminate_mutex.lockUncancelable(lp.io);
    defer self.terminate_mutex.unlock(lp.io);
    if (self.terminatePending()) return;
    v8.v8__Isolate__PerformMicrotaskCheckpoint(self.isolate.handle);
}

fn promiseRejectCallback(message_handle: v8.PromiseRejectMessage) callconv(.c) void {
    const promise_event = v8.v8__PromiseRejectMessage__GetEvent(&message_handle);
    if (promise_event != v8.kPromiseRejectWithNoHandler and promise_event != v8.kPromiseHandlerAddedAfterReject) {
        return;
    }

    const v8_isolate = v8.v8__Isolate__GetCurrent().?;
    const isolate = js.Isolate{ .handle = v8_isolate };
    const ctx, const v8_context = Context.fromIsolate(isolate) orelse return;

    const local = js.Local{
        .ctx = ctx,
        .isolate = isolate,
        .handle = v8_context,
        .call_arena = ctx.call_arena,
    };

    const rejection: js.PromiseRejection = .{ .local = &local, .handle = &message_handle };

    if (promise_event == v8.kPromiseRejectWithNoHandler) {
        // Deliberately silent here. The spec announces at the end of the
        // microtask checkpoint, and a handler attached before then takes the
        // promise back off the list -- see Context.notifyRejectedPromises.
        ctx.queueRejection(rejection.promise(), rejection.reason()) catch |err| {
            log.warn(.browser, "queue promise rejection", .{ .err = err });
        };
        return;
    }

    // A handler arrived. If it beat the drain the announcement is cancelled and
    // there is nothing to say; otherwise this is the retraction, and it carries
    // the reason V8 no longer hands back on this event.
    const announced = ctx.retractRejection(rejection.promise()) orelse return;
    defer announced.release();

    const promise = announced.promise.local(&local);
    const reason: ?js.Value = if (announced.reason) |r| r.local(&local) else null;
    switch (ctx.global) {
        .frame => |frame| {
            frame.window.unhandledPromiseRejection(false, promise, reason, frame) catch |err| {
                log.warn(.browser, "unhandled rejection handler", .{ .err = err, .target = "window" });
            };
        },
        .worker => |wsg| {
            wsg.unhandledPromiseRejection(false, promise, reason) catch |err| {
                log.warn(.browser, "unhandled rejection handler", .{ .err = err, .target = "worker" });
            };
        },
    }
}

fn fatalCallback(c_location: [*c]const u8, c_message: [*c]const u8) callconv(.c) void {
    const location = std.mem.span(c_location);
    const message = std.mem.span(c_message);
    log.fatal(.app, "V8 fatal callback", .{ .location = location, .message = message });
    @import("../../crash_handler.zig").crash("Fatal V8 Error", .{ .location = location, .message = message }, @returnAddress());
}

fn oomCallback(c_location: [*c]const u8, details: ?*const v8.OOMDetails) callconv(.c) void {
    const location = std.mem.span(c_location);
    const detail = if (details) |d| std.mem.span(d.detail) else "";
    log.fatal(.app, "V8 OOM", .{ .location = location, .detail = detail });
    @import("../../crash_handler.zig").crash("V8 OOM", .{ .location = location, .detail = detail }, @returnAddress());
}

const PrivateSymbols = struct {
    const Private = @import("Private.zig");

    child_nodes: Private,
    // CSSViewTransitionRule.types is [SameObject] as well as a FrozenArray, so
    // the frozen array is built once per rule and cached here.
    view_transition_types: Private,

    fn init(isolate: *v8.Isolate) PrivateSymbols {
        return .{
            .child_nodes = Private.init(isolate, "child_nodes"),
            .view_transition_types = Private.init(isolate, "view_transition_types"),
        };
    }

    fn deinit(self: *PrivateSymbols) void {
        self.child_nodes.deinit();
        self.view_transition_types.deinit();
    }
};

const testing = @import("../../testing.zig");
test "Env: Worker context " {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const worker = try @import("../webapi/Worker.zig").init("http://localhost:9582/src/browser/tests/testing.js", null, &frame.js.execution);

    var ls: js.Local.Scope = undefined;
    worker._worker_scope._proto.js.localScope(&ls);
    defer ls.deinit();

    try testing.expectEqual(true, (try ls.local.exec("typeof Node === 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof WorkerGlobalScope !== 'undefined'", null)).isTrue());

    // A dedicated worker's global is a DedicatedWorkerGlobalScope, which inherits
    // from WorkerGlobalScope. Both instanceof checks must hold (real sites, e.g.
    // Shopify's Web Pixel sandbox, use `self instanceof DedicatedWorkerGlobalScope`
    // to tell a worker apart from an iframe).
    try testing.expectEqual(true, (try ls.local.exec("typeof DedicatedWorkerGlobalScope !== 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("self instanceof DedicatedWorkerGlobalScope", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("self instanceof WorkerGlobalScope", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("self.constructor.name === 'DedicatedWorkerGlobalScope'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("self === globalThis", null)).isTrue());

    // postMessage/close/onmessage belong to DedicatedWorkerGlobalScope, which
    // is the [Global] interface here -- so they are own properties of the
    // global object and are on neither interface prototype object. Measured on
    // headless Chrome 151 in a blob worker (expr-worker-global-shape):
    // getOwnPropertyNames(DedicatedWorkerGlobalScope.prototype) is
    // PERSISTENT / TEMPORARY / constructor, and `self` owns postMessage.
    try testing.expectEqual(true, (try ls.local.exec("Object.prototype.hasOwnProperty.call(self, 'postMessage')", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("!DedicatedWorkerGlobalScope.prototype.hasOwnProperty('postMessage')", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("!WorkerGlobalScope.prototype.hasOwnProperty('postMessage')", null)).isTrue());
    // ...while an inherited interface's members stay on its prototype object,
    // which is why `self` does not own fetch there or here.
    try testing.expectEqual(true, (try ls.local.exec("WorkerGlobalScope.prototype.hasOwnProperty('fetch')", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("!Object.prototype.hasOwnProperty.call(self, 'fetch')", null)).isTrue());

    // AnimationFrameProvider mixin is exposed on the dedicated worker global.
    try testing.expectEqual(true, (try ls.local.exec("typeof self.requestAnimationFrame === 'function'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof self.cancelAnimationFrame === 'function'", null)).isTrue());
}

test "Env: Frame context" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // Frame already has a context created, use it directly
    const ctx = frame.js;

    var ls: js.Local.Scope = undefined;
    ctx.localScope(&ls);
    defer ls.deinit();

    try testing.expectEqual(true, (try ls.local.exec("typeof Node !== 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof WorkerGlobalScope === 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof DedicatedWorkerGlobalScope === 'undefined'", null)).isTrue());
}

// WebAssembly.compileStreaming and WebAssembly.instantiateStreaming are the only
// two members of the namespace that V8 does not provide: they take a Response
// rather than bytes, so they belong to the embedder. Chrome exposes them as
// plain writable, enumerable, configurable data properties of arity 1, and both
// reject with a TypeError on a missing argument, a non-Response argument, or a
// response whose MIME type is not application/wasm (all measured).
//
// Blink streams the module through the compiler as the bytes arrive; we read the
// body first and hand it to WebAssembly.compile. The difference is not
// observable from script beyond the timing of a large download.
//
// Being the embedder's is visible in the shape of the two functions, not just in
// the fact that the names exist. Chrome's print `[native code]`, own nothing but
// `length` and `name`, and throw on `new`; a plain script function fails all
// three, and Kasada's decoded guard greps for precisely that family
// (`\[native code\]`, `patchedFuncStringErrMsg`, `^[a-z]+\s*\(\)\s*\{...\}`).
// Binding a shorthand method got all three *nearly* right, and printed
// *anonymously* -- `function () { [native code] }` where Chrome names the
// function, a shape no built-in has. That last one needs a real embedder
// binding, which is what `bindWasmStreaming` below now does: the bootstrap
// hands back the implementations and each is wrapped in a
// `newNamedCallback`, so `toString` reports
// `function compileStreaming() { [native code] }`.
//
// Measured not to be the x-hyatt door either way: handing Chrome the old
// script-defined shape cost it nothing, 2/2, and did not move the payload by a
// byte (README, "the two functions written in javascript"). This is a fidelity
// fix, not a gate.
//
// This has to run per context rather than once at snapshot time: V8 materialises
// the WebAssembly namespace when a context is deserialised, so it does not exist
// yet while the snapshot is being built (reading it there gives undefined). One
// deviation follows from defining the two names afterwards: Chrome lists them
// between RuntimeError and Suspending, while appending puts them last. The set
// is what detectors compare, not the position within the namespace object.
/// Puts `compileStreaming` and `instantiateStreaming` on the `WebAssembly`
/// namespace as functions a script cannot tell from V8's own.
///
/// The bootstrap script hands back the two implementations rather than defining
/// them, and each is wrapped in a `newNamedCallback` that forwards to it. That
/// wrapper is what closes the last of the three tells: a FunctionTemplate-backed
/// function reports `function compileStreaming() { [native code] }`, owns
/// nothing but `length` and `name`, and throws on `new`. Binding a shorthand
/// method -- what this used to do -- gets the last two right and prints
/// *anonymously*, which is a shape no built-in has.
fn bindWasmStreaming(context: *Context, local: js.Local) !void {
    const returned = try local.exec(wasm_streaming_bootstrap, "wasm-streaming");
    if (!returned.isArray()) {
        return error.WasmStreamingBootstrap;
    }
    const impls = returned.toArray();

    const wasm = try context.globalObject(&local).get("WebAssembly");
    if (!wasm.isObject()) {
        return error.WasmStreamingBootstrap;
    }
    const namespace = wasm.toObject();

    inline for (.{ "compileStreaming", "instantiateStreaming" }, 0..) |name, i| {
        const impl = try impls.get(i);
        if (!impl.isFunction()) {
            return error.WasmStreamingBootstrap;
        }
        const impl_fn = js.Function{ .local = impl.local, .handle = @ptrCast(impl.handle) };
        context.wasm_streaming[i] = try impl_fn.persist();

        // Arity 1 on both: Chrome reports 1 for instantiateStreaming too, since
        // its `importObject` is optional (measured).
        const fn_ = try local.newNamedCallback(name, 1, callStreaming(i), context);
        // Writable, enumerable, configurable -- a plain data property, which is
        // what the rest of the namespace's members are.
        _ = try namespace.set(name, fn_, .{});
    }
}

/// The trampoline for one of the two. Everything the spec text needs -- the
/// Response check, the MIME check, awaiting a promised Response -- lives in the
/// implementation this forwards to; the only job here is to be a native
/// function while doing it.
fn callStreaming(comptime i: usize) fn (*Context, []js.Value) anyerror!js.Value {
    return struct {
        fn call(context: *Context, args: []js.Value) !js.Value {
            const local = context.local.?;
            const impl = local.toLocal(context.wasm_streaming[i] orelse {
                return error.WasmStreamingBootstrap;
            });
            return impl.call(js.Value, args);
        }
    }.call;
}

const wasm_streaming_bootstrap =
    \\(() => {
    \\  const wasm = globalThis.WebAssembly;
    \\  const compile = wasm.compile;
    \\  const instantiate = wasm.instantiate;
    \\  async function bytesOf(source, name) {
    \\    const response = await source;
    \\    if (!(response instanceof Response)) {
    \\      throw new TypeError("Failed to execute '" + name + "' on 'WebAssembly': An argument must be provided, which must be a Response or Promise<Response> object");
    \\    }
    \\    const type = response.headers.get('content-type');
    \\    if (type === null || type.split(';')[0].trim().toLowerCase() !== 'application/wasm') {
    \\      throw new TypeError("Failed to execute '" + name + "' on 'WebAssembly': Incorrect response MIME type. Expected 'application/wasm'.");
    \\    }
    \\    return response.arrayBuffer();
    \\  }
    \\  return [
    \\    (source) => bytesOf(source, 'compileStreaming').then((bytes) => compile.call(wasm, bytes)),
    \\    (source, imports) => bytesOf(source, 'instantiateStreaming').then((bytes) => instantiate.call(wasm, bytes, imports)),
    \\  ];
    \\})()
;
