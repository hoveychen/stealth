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

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const reflect = @import("../reflect.zig");

// Not ideal, but its children have special constructor rules (can be extended
// can't be instantiated). And rather than coming up with a generic definition
// for this one case, we just hardcode it.
const HtmlElement = @import("../webapi/element/Html.zig");

// The page realm's [Global] interface. Named here because its prototype chain
// is the one Web IDL gives an extra link (the named properties object).
const Window = @import("../webapi/Window.zig");

const v8 = js.v8;
const access_check = @import("access_check.zig");
const log = lp.log;
const JsApis = bridge.JsApis;
const PageJsApis = bridge.PageJsApis;
const SharedWorkerJsApis = bridge.SharedWorkerJsApis;
const DedicatedWorkerJsApis = bridge.DedicatedWorkerJsApis;
const secure_context = @import("secure_context.zig");

const Snapshot = @This();

const Caller = @import("Caller.zig");

const Realm = enum {
    window,
    dedicated_worker,
    shared_worker,

    /// Whether a member (or interface) tagged with `exposed` belongs in this
    /// realm. The two worker kinds are one realm as far as [Exposed=Worker]
    /// goes and two as far as [Exposed=DedicatedWorker] does.
    fn allows(comptime self: Realm, comptime exposed: Caller.Function.Opts.Exposed) bool {
        return switch (exposed) {
            .both => true,
            .window => self == .window,
            .worker => self == .dedicated_worker or self == .shared_worker,
            .dedicated_worker => self == .dedicated_worker,
        };
    }
};

const embedded_snapshot_blob = if (lp.build_config.snapshot_path) |path| @embedFile(path) else "";

// When creating our Snapshot, we use local function templates for every Zig type.
// You cannot, from what I can tell, create persisted FunctionTemplates at
// snapshot creation time. But you can embed those templates (or any other v8
// Data) so that it's available to contexts created from the snapshot. This is
// the starting index of those function templates, which we can extract. At
// creation time, in debug, we assert that this is actually a consecutive integer
// sequence
data_start: usize,

// The snapshot data (v8.StartupData is a ptr to the data and len).
startup_data: v8.StartupData,

// V8 doesn't know how to serialize external references, and pretty much any hook
// into Zig is an external reference (e.g. every accessor and function callback).
// When we create the snapshot, we give it an array with the address of every
// external reference. When we load the snapshot, we need to give it the same
// array with the exact same number of entries in the same order (but, of course
// cross-process, the value (address) might be different).
external_references: [countExternalReferences()]isize,

// Track whether this snapshot owns its data (was created in-process)
// If false, the data points into embedded_snapshot_blob and will not be freed
owns_data: bool = false,

pub fn load() !Snapshot {
    if (comptime embedded_snapshot_blob.len > 0) {
        return loadEmbedded();
    }
    return create();
}

fn loadEmbedded() !Snapshot {
    // Binary format: [data_start: usize][blob data]
    const min_size = @sizeOf(usize) + 1000;
    if (embedded_snapshot_blob.len < min_size) {
        // our blob should be in the MB, this is just a quick sanity check
        return error.InvalidSnapshot;
    }

    const data_start = std.mem.readInt(usize, embedded_snapshot_blob[0..@sizeOf(usize)], .little);
    const blob = embedded_snapshot_blob[@sizeOf(usize)..];

    const startup_data = v8.StartupData{ .data = blob.ptr, .raw_size = @intCast(blob.len) };
    if (!v8.v8__StartupData__IsValid(startup_data)) {
        return error.InvalidSnapshot;
    }

    return .{
        .owns_data = false,
        .data_start = data_start,
        .startup_data = startup_data,
        .external_references = collectExternalReferences(),
    };
}

pub fn deinit(self: Snapshot) void {
    // Only free if we own the data (was created in-process)
    if (self.owns_data) {
        // V8 allocated this with `new char[]`, so we need to use the C++ delete[] operator
        v8.v8__StartupData__DELETE(self.startup_data.data);
    }
}

pub fn write(self: Snapshot, writer: *std.Io.Writer) !void {
    if (!self.isValid()) {
        return error.InvalidSnapshot;
    }

    try writer.writeInt(usize, self.data_start, .little);
    try writer.writeAll(self.startup_data.data[0..@intCast(self.startup_data.raw_size)]);
}

pub fn fromEmbedded(self: Snapshot) bool {
    // if the snapshot comes from the embedFile, then it'll be flagged as not
    // owning (aka, not needing to free) the data.
    return self.owns_data == false;
}

fn isValid(self: Snapshot) bool {
    return v8.v8__StartupData__IsValid(self.startup_data);
}

// V8 derives an isolate's default JS stack limit from the *thread's* stack
// start minus --stack-size (984 KB by default), not from where the isolate was
// created. By the time App.init() gets here the main thread is already about
// 1.4 MB deep, so that default limit sits above our stack pointer and the very
// first Script::Compile in createSnapshotContext dies with
// `RangeError: Maximum call stack size exceeded` -- with no JS recursion
// anywhere in sight.
//
// Measured while adding the File System Access interfaces: startup broke the
// moment the registry crossed a threshold (five extra interfaces fine, six
// fatal), the frame between create() and that Compile is only 36 KB, and
// running the same build with `--v8-flags-unsafe --stack-size=4000` started
// cleanly. So the budget was already exhausted before we got here and each new
// interface was just nudging the frame along.
//
// So build the snapshot on a thread of its own, where the isolate starts from
// a fresh stack and the whole default budget is actually available. Nothing
// about the resulting blob depends on which thread produced it, and page
// isolates are untouched, so script-visible recursion depth is unchanged.
pub fn create() !Snapshot {
    var result: Result = .{ .value = error.SnapshotThreadFailed };
    const thread = try std.Thread.spawn(.{}, buildOnThread, .{&result});
    thread.join();
    return result.value;
}

const Result = struct { value: anyerror!Snapshot };

fn buildOnThread(result: *Result) void {
    result.value = build();
}

fn build() !Snapshot {
    var external_references = collectExternalReferences();

    var params: v8.CreateParams = undefined;
    v8.v8__Isolate__CreateParams__CONSTRUCT(&params);
    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator();
    defer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);
    params.external_references = @ptrCast(&external_references);

    const snapshot_creator = v8.v8__SnapshotCreator__CREATE(&params);
    defer v8.v8__SnapshotCreator__DESTRUCT(snapshot_creator);

    var data_start: usize = 0;
    const isolate = v8.v8__SnapshotCreator__getIsolate(snapshot_creator).?;
    defer v8.v8__Isolate__LowMemoryNotification(isolate);

    {
        // CreateBlob, which we'll call once everything is setup, MUST NOT
        // be called from an active HandleScope. Hence we have this scope to
        // clean it up before we call CreateBlob
        var handle_scope: v8.HandleScope = undefined;
        v8.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        defer v8.v8__HandleScope__DESTRUCT(&handle_scope);

        // Create templates for ALL types (JsApis)
        var templates: [JsApis.len]*const v8.FunctionTemplate = undefined;
        inline for (JsApis, 0..) |JsApi, i| {
            @setEvalBranchQuota(10_000);
            templates[i] = generateConstructor(JsApi, isolate);
            attachClass(JsApi, false, isolate, templates[i], null);
        }

        // Set up prototype chains BEFORE attaching properties
        inline for (JsApis, 0..) |JsApi, i| {
            // Window's chain has one more link in it; spliced in below.
            if (comptime JsApi == Window.JsApi) {
                continue;
            }
            if (comptime protoIndexLookup(JsApi)) |proto_index| {
                v8.v8__FunctionTemplate__Inherit(templates[i], templates[proto_index]);
            }
        }

        // Web IDL's *named properties object*: an interface with a named
        // property getter that is also [Global] -- Window, and only Window --
        // gets a nameless object between its interface prototype object and the
        // next one up. Measured on headless Chrome 151
        // (expr-window-properties-object): Object.getPrototypeOf(
        // Window.prototype) is an object with no own names, no `constructor`,
        // one own symbol (@@toStringTag = 'WindowProperties'), and its own
        // prototype is EventTarget.prototype. So `window`'s chain is four links
        // deep even though Window.prototype carries three names, and a script
        // that walks the chain counts them.
        const window_properties = v8.v8__FunctionTemplate__New__DEFAULT(isolate);
        {
            const window_index = comptime bridge.JsApiLookup.getId(Window.JsApi);
            const event_target_index = comptime protoIndexLookup(Window.JsApi).?;

            const tag = "WindowProperties";
            const brand = v8.v8__String__NewFromUtf8(isolate, tag.ptr, v8.kNormal, tag.len);
            const prototype = v8.v8__FunctionTemplate__PrototypeTemplate(window_properties);
            v8.v8__Template__Set(@ptrCast(prototype), v8.v8__Symbol__GetToStringTag(isolate), brand, v8.ReadOnly + v8.DontEnum);

            v8.v8__FunctionTemplate__Inherit(window_properties, templates[event_target_index]);
            v8.v8__FunctionTemplate__Inherit(templates[window_index], window_properties);
        }

        // Add ALL templates to snapshot (done once, in any context)
        // We need a context to call AddData, so create a temporary one
        {
            const temp_context = v8.v8__Context__New(isolate, null, null);
            v8.v8__Context__Enter(temp_context);
            defer v8.v8__Context__Exit(temp_context);

            var last_data_index: usize = 0;
            inline for (JsApis, 0..) |_, i| {
                @setEvalBranchQuota(10_000);
                const data_index = v8.v8__SnapshotCreator__AddData(snapshot_creator, @ptrCast(templates[i]));
                if (i == 0) {
                    data_start = data_index;
                    last_data_index = data_index;
                } else {
                    if (data_index != last_data_index + 1) {
                        return error.InvalidDataIndex;
                    }
                    last_data_index = data_index;
                }
            }

            // V8 requires a default context. We could probably make this our
            // Page context, but having both the Page and Worker context be
            // added via addContext makes things a little more consistent.
            v8.v8__SnapshotCreator__setDefaultContext(snapshot_creator, temp_context);
        }

        {
            const index = try createSnapshotContext(.window, &PageJsApis, Window.JsApi, isolate, snapshot_creator.?, &templates, window_properties);
            std.debug.assert(index == 0);
        }

        {
            const DedicatedWorkerGlobalScope = @import("../webapi/DedicatedWorkerGlobalScope.zig");
            const index = try createSnapshotContext(.dedicated_worker, &DedicatedWorkerJsApis, DedicatedWorkerGlobalScope.JsApi, isolate, snapshot_creator.?, &templates, null);
            std.debug.assert(index == 1);
        }

        {
            const SharedWorkerGlobalScope = @import("../webapi/SharedWorkerGlobalScope.zig");
            const index = try createSnapshotContext(.shared_worker, &SharedWorkerJsApis, SharedWorkerGlobalScope.JsApi, isolate, snapshot_creator.?, &templates, null);
            std.debug.assert(index == 2);
        }
    }

    const blob = v8.v8__SnapshotCreator__createBlob(snapshot_creator, v8.kKeep);

    return .{
        .owns_data = true,
        .data_start = data_start,
        .startup_data = blob,
        .external_references = external_references,
    };
}

fn createSnapshotContext(
    comptime realm: Realm,
    comptime ContextApis: []const type,
    comptime GlobalScopeApi: type,
    isolate: *v8.Isolate,
    snapshot_creator: *v8.SnapshotCreator,
    templates: []*const v8.FunctionTemplate,
    // The realm's named properties object, if its [Global] interface has one.
    named_properties: ?*const v8.FunctionTemplate,
) !usize {
    // The global object IS an instance of the global scope interface -- not of
    // some extra template that inherits from it. Upstream created a nameless
    // FunctionTemplate here and had it Inherit() the Window template, which put
    // an extra link in the chain: `window -> <that>.prototype ->
    // Window.prototype`. Measured on headless Chrome 151,
    // `Object.getPrototypeOf(window) === Window.prototype` is true, so the
    // extra link answered false -- one === away, on a name every detector
    // already has in hand.
    const global_scope_index = comptime bridge.JsApiLookup.getId(GlobalScopeApi);
    const global_template = v8.v8__FunctionTemplate__InstanceTemplate(templates[global_scope_index]).?;
    v8.v8__ObjectTemplate__SetInternalFieldCount(global_template, comptime countInternalFields(GlobalScopeApi));

    // Named element access (window.myDiv). The interface's own `index` handler
    // is already on this template, installed by attachClass; only the named one
    // is specific to being the global.
    if (comptime std.mem.eql(u8, GlobalScopeApi.Meta.name, "Window")) {
        v8.v8__ObjectTemplate__SetNamedHandler(global_template, &.{
            .getter = bridge.unknownWindowPropertyCallback,
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = null,
            .descriptor = null,
            .data = null,
            .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
        });
    }

    // Now attach the [Global] interface's members directly on the global
    // object, which is where Web IDL says they live. The regular pass skipped
    // them (see attachClass), so this is their only home -- an attribute or
    // operation is own on the global and absent from the interface prototype
    // object, which keeps only the constants and `constructor`.
    //
    // Only this one interface, not the chain above it: [Global] is a per-
    // interface annotation. Measured on headless Chrome 151 in a worker
    // (expr-worker-global-shape), `onmessage` and `postMessage` -- Dedicated-
    // WorkerGlobalScope's own members -- are own on `self`, while `fetch` and
    // `isSecureContext` answer from WorkerGlobalScope.prototype and
    // `addEventListener` from EventTarget.prototype. Walking the chain here
    // gave the worker global 29 own properties a real one does not have.
    comptime {
        if (hasGatedMember(GlobalScopeApi)) {
            @compileError("[Global] scope interface " ++ @typeName(GlobalScopeApi) ++ " has [Exposed]-gated members. This is not supported");
        }
    }
    attachClass(GlobalScopeApi, true, isolate, templates[global_scope_index], global_template);

    const context = v8.v8__Context__New(isolate, global_template, null);
    v8.v8__Context__Enter(context);
    defer v8.v8__Context__Exit(context);

    // Initialize embedder data to null so callbacks can detect snapshot creation
    v8.v8__Context__SetAlignedPointerInEmbedderData(context, 1, null);

    const global_obj = v8.v8__Context__Global(context);

    // Attach constructors for this context's APIs to the global, and for any
    // type with members tagged [Exposed=Window]/[Exposed=Worker], prune the
    // ones that don't match this realm from the per-context Func.prototype.
    const prototype_key = v8.v8__String__NewFromUtf8(isolate, "prototype", v8.kNormal, 9);

    // The named properties object is not an interface, so nothing names it and
    // it has no `constructor` back-reference -- measured: Chrome reports no own
    // names on it at all. V8 gives every template's prototype object one, so it
    // goes here.
    if (named_properties) |np| {
        const func: *const v8.Object = @ptrCast(v8.v8__FunctionTemplate__GetFunction(np, context));
        if (v8.v8__Object__Get(func, context, prototype_key)) |proto_handle| {
            const proto_obj: *const v8.Object = @ptrCast(proto_handle);
            const constructor_key = v8.v8__String__NewFromUtf8(isolate, "constructor", v8.kNormal, 11);
            var maybe_deleted: v8.MaybeBool = undefined;
            v8.v8__Object__Delete(proto_obj, context, constructor_key, &maybe_deleted);
        }
    }

    inline for (ContextApis) |JsApi| {
        @setEvalBranchQuota(10_000);
        const template_index = comptime bridge.JsApiLookup.getId(JsApi);
        const func = v8.v8__FunctionTemplate__GetFunction(templates[template_index], context);

        // WebIDL [LegacyNoInterfaceObject]: the interface still brands its
        // instances through Symbol.toStringTag, but there is no constructor on
        // the global and no `constructor` back-reference on the prototype.
        // Measured on Chrome 150: navigator.webkitTemporaryStorage is
        // "[object DeprecatedStorageQuota]" while globalThis
        // .DeprecatedStorageQuota is undefined and the prototype carries only
        // queryUsageAndQuota and requestQuota.
        //
        // A WebIDL *namespace* (GPUBufferUsage and friends) has no interface
        // object either -- the global gets the namespace object itself, see the
        // namespace_global block below.
        const namespace_global = comptime @hasDecl(JsApi.Meta, "namespace_global");
        const no_interface_object = comptime @hasDecl(JsApi.Meta, "no_interface_object") or namespace_global;
        if (comptime no_interface_object) {
            const func_obj: *const v8.Object = @ptrCast(func);
            if (v8.v8__Object__Get(func_obj, context, prototype_key)) |proto_handle| {
                const proto_obj: *const v8.Object = @ptrCast(proto_handle);
                const constructor_key = v8.v8__String__NewFromUtf8(isolate, "constructor", v8.kNormal, 11);
                var maybe_deleted: v8.MaybeBool = undefined;
                v8.v8__Object__Delete(proto_obj, context, constructor_key, &maybe_deleted);
            }
        }

        // WebIDL [Exposed] on the *interface*, as opposed to on a member: an
        // interface the realm is not in has no interface object on that global
        // at all. The type still needs its template and class id -- both realms
        // share one JsApiLookup -- so the gate is here, at the one place a name
        // reaches a global, and not in the type lists.
        //
        // A worker's `performance` is the same Performance instance shape as a
        // window's, so it travels in worker_common_apis with PerformanceTiming
        // and PerformanceNavigation in tow; Chrome exposes neither of those two
        // in a worker (measured, probes/expr-worker-surface.js).
        const interface_exposed = comptime if (@hasDecl(JsApi.Meta, "exposed")) JsApi.Meta.exposed else Caller.Function.Opts.Exposed.both;
        const in_realm = comptime realm.allows(interface_exposed);

        if (@hasDecl(JsApi.Meta, "name") and !no_interface_object and in_realm) {
            if (@hasDecl(JsApi.Meta, "constructor_alias")) {
                // Both names, and both non-enumerable: an interface object is
                // never enumerable on the global, and neither is a legacy
                // factory function (measured on a headed Chrome 150 --
                // `Option`, `Image` and `Audio` all read back as value[-cw]).
                const alias = JsApi.Meta.constructor_alias;
                const v8_class_name = v8.v8__String__NewFromUtf8(isolate, alias.ptr, v8.kNormal, @intCast(alias.len));
                var maybe_result: v8.MaybeBool = undefined;
                v8.v8__Object__DefineOwnProperty(global_obj, context, v8_class_name, func, v8.DontEnum, &maybe_result);

                const name = JsApi.Meta.name;
                const illegal_class_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                var maybe_result2: v8.MaybeBool = undefined;
                v8.v8__Object__DefineOwnProperty(global_obj, context, illegal_class_name, func, v8.DontEnum, &maybe_result2);
            } else {
                const name = JsApi.Meta.name;
                const v8_class_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                var maybe_result: v8.MaybeBool = undefined;
                // Web IDL: interface objects on the global are non-enumerable.
                v8.v8__Object__DefineOwnProperty(global_obj, context, v8_class_name, func, v8.DontEnum, &maybe_result);
            }

            // Extra global names for the *same* constructor, for the legacy
            // vendor-prefixed aliases Chrome still ships (webkitRTCPeerConnection
            // === RTCPeerConnection is true there, measured). Unlike
            // constructor_alias above, this does not rename the class: the
            // function keeps Meta.name, which is what Chrome reports for
            // webkitRTCPeerConnection.name.
            //
            // Window-only, all of them. Chrome's Window carries 14 webkit-
            // prefixed names and its dedicated worker carries four, and the
            // four are WorkerGlobalScope operations (webkitRequestFileSystem
            // and friends) rather than interface objects -- not one legacy
            // alias crosses into that realm (measured,
            // probes/expr-worker-surface.js). DOMMatrix and URL are the two
            // alias-bearing interfaces a worker does have, so without this gate
            // WebKitCSSMatrix and webkitURL leak in behind them.
            if (@hasDecl(JsApi.Meta, "constructor_aliases") and realm == .window) {
                inline for (JsApi.Meta.constructor_aliases) |alias| {
                    const alias_name = v8.v8__String__NewFromUtf8(isolate, alias.ptr, v8.kNormal, @intCast(alias.len));
                    var maybe_alias: v8.MaybeBool = undefined;
                    v8.v8__Object__DefineOwnProperty(global_obj, context, alias_name, func, v8.DontEnum, &maybe_alias);
                }
            }
        }

        // WebIDL namespaces. Nothing about a namespace looks like an interface:
        // the global carries the namespace *object*, its members are own
        // properties of that object (attachClass already put them on the
        // instance template, see own_properties), and it inherits straight from
        // %Object.prototype% rather than from an interface prototype object.
        // Measured on a headed Chrome 150:
        //
        //   typeof GPUBufferUsage                          -> 'object'
        //   Object.getPrototypeOf(GPUBufferUsage) === Object.prototype -> true
        //   Object.getOwnPropertyDescriptor(window, 'GPUBufferUsage')
        //     -> { writable: true, enumerable: false, configurable: true }
        //   Object.getOwnPropertyDescriptor(GPUBufferUsage, 'MAP_READ')
        //     -> { value: 1, writable: false, enumerable: true, configurable: false }
        //
        // CSS, console and WebAssembly read back the same way there; only the
        // WebGPU flag holders go through this path so far.
        if (comptime namespace_global and in_realm) {
            const object_template = v8.v8__FunctionTemplate__InstanceTemplate(templates[template_index]).?;
            const namespace_obj = v8.v8__ObjectTemplate__NewInstance(object_template, context).?;

            // NewInstance links the instance to the FunctionTemplate's
            // prototype object; a namespace has no prototype of its own.
            const object_prototype = v8.v8__Object__GetPrototype(v8.v8__Object__New(isolate).?).?;
            var maybe_proto: v8.MaybeBool = undefined;
            v8.v8__Object__SetPrototype(namespace_obj, context, @ptrCast(object_prototype), &maybe_proto);

            const namespace_name = JsApi.Meta.name;
            const namespace_key = v8.v8__String__NewFromUtf8(isolate, namespace_name.ptr, v8.kNormal, @intCast(namespace_name.len));
            var maybe_namespace: v8.MaybeBool = undefined;
            v8.v8__Object__DefineOwnProperty(global_obj, context, namespace_key, @ptrCast(namespace_obj), v8.DontEnum, &maybe_namespace);
        }

        // WebIDL [Exposed=...] gating. Members are installed on the shared
        // FunctionTemplate by attachClass; here we delete the ones that don't
        // match this realm from the per-context Func.prototype.
        if (comptime hasGatedMember(JsApi)) {
            const func_obj: *const v8.Object = @ptrCast(func);
            if (v8.v8__Object__Get(func_obj, context, prototype_key)) |proto_handle| {
                const proto_obj: *const v8.Object = @ptrCast(proto_handle);
                inline for (@typeInfo(JsApi).@"struct".decls) |d| {
                    const exposed = comptime memberExposed(@field(JsApi, d.name));
                    if (comptime !realm.allows(exposed)) {
                        const name: [:0]const u8 = d.name;
                        const name_v8 = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                        var maybe_deleted: v8.MaybeBool = undefined;
                        v8.v8__Object__Delete(proto_obj, context, name_v8, &maybe_deleted);
                    }
                }
            }
        }
    }

    {
        // Delete built-in console so we can inject our own. V8's own console
        // object wins the slot over the template's accessor -- measured: with
        // this delete removed, `Object.getOwnPropertyNames(console)` came back
        // as V8's list (`context`, `createTask`, no `memory`) and carried V8's
        // '[object console]' brand, so the brand alone does not tell them
        // apart. Env.zig installs the page's Console over the hole this leaves.
        const console_key = v8.v8__String__NewFromUtf8(isolate, "console", v8.kNormal, 7);
        var maybe_deleted: v8.MaybeBool = undefined;
        v8.v8__Object__Delete(global_obj, context, console_key, &maybe_deleted);
        if (maybe_deleted.value == false) {
            return error.ConsoleDeleteError;
        }
    }

    // Set prototype chains on function objects
    // https://groups.google.com/g/v8-users/c/qAQQBmbi--8
    inline for (JsApis, 0..) |JsApi, i| {
        if (comptime protoIndexLookup(JsApi)) |proto_index| {
            const proto_func = v8.v8__FunctionTemplate__GetFunction(templates[proto_index], context);
            const proto_obj: *const v8.Object = @ptrCast(proto_func);

            const self_func = v8.v8__FunctionTemplate__GetFunction(templates[i], context);
            const self_obj: *const v8.Object = @ptrCast(self_func);

            var maybe_result: v8.MaybeBool = undefined;
            v8.v8__Object__SetPrototype(self_obj, context, proto_obj, &maybe_result);
        }
    }

    {
        // DOMException prototype setup
        const code_str = "DOMException.prototype.__proto__ = Error.prototype";
        const code = v8.v8__String__NewFromUtf8(isolate, code_str.ptr, v8.kNormal, @intCast(code_str.len));
        const script = v8.v8__Script__Compile(context, code, null) orelse return error.ScriptCompileFailed;
        _ = v8.v8__Script__Run(script, context) orelse return error.ScriptRunFailed;
    }

    // Last, because it reads back the prototypes everything above installed.
    try moveConstructorSlots(isolate, context);

    return v8.v8__SnapshotCreator__AddContext(snapshot_creator, context);
}

// V8 appends `constructor` to a template's prototype object once the template's
// own members are in, so every prototype this engine builds reports it last.
// Blink's does not: Chrome installs a second batch of members per context --
// the runtime-flag and secure-context gated ones -- and that batch lands after
// V8's append, which leaves `constructor` sitting at the boundary between the
// two. Measured on Chrome 151 over https
// (tools/fingerprint/probes/expr-constructor-slot.js): 89 of its 923 interface
// prototypes report `constructor` somewhere other than last, and 26 of those
// are interfaces whose member list this engine already matches name for name --
// so the slot is the only thing left to read, and one
// Object.getOwnPropertyNames reads it.
//
// A binding cannot pick the slot: the members go on a Template and V8 decides
// where its own entry goes. What a binding *can* do is put them back. String
// keys enumerate in insertion order, so deleting the members that belong after
// `constructor` and defining them again -- with the descriptor they already
// have, so the getter, the setter, the arity and the attributes are the same
// objects -- moves them behind it without touching anything else. This runs
// once while the snapshot is being built, so a page pays nothing for it.
//
// Interfaces name their slot with `Meta.constructor_after`, the member Chrome's
// `constructor` immediately follows. A name rather than an index: the index
// moves whenever anything else on the interface changes, and a stale index
// would reshuffle the prototype silently.
fn moveConstructorSlots(isolate: *v8.Isolate, context: ?*const v8.Context) !void {
    const code_str = comptime blk: {
        @setEvalBranchQuota(200_000);
        var table: []const u8 = "";
        for (JsApis) |JsApi| {
            if (!@hasDecl(JsApi.Meta, "constructor_after")) continue;
            const after = JsApi.Meta.constructor_after;
            if (!@hasDecl(JsApi.Meta, "name")) {
                @compileError(@typeName(JsApi) ++ ": constructor_after needs an interface name");
            }
            if (@hasDecl(JsApi.Meta, "no_interface_object") or @hasDecl(JsApi.Meta, "namespace_global")) {
                @compileError(JsApi.Meta.name ++ ": constructor_after needs an interface object to reach the prototype");
            }
            if (!@hasDecl(JsApi, after)) {
                @compileError(JsApi.Meta.name ++ ": constructor_after names '" ++ after ++ "', which is not a member");
            }
            table = table ++ "'" ++ JsApi.Meta.name ++ "','" ++ after ++ "',";
        }
        break :blk "(function(t){for(var i=0;i<t.length;i+=2){" ++
            "var c=globalThis[t[i]];if(typeof c!=='function')continue;" ++
            "var p=c.prototype;if(!p)continue;" ++
            "var n=Object.getOwnPropertyNames(p),k=n.indexOf(t[i+1]);" ++
            // Nothing to do when the anchor is missing (a realm that gates the
            // member out) or when `constructor` already sits ahead of it.
            "if(k<0||n.indexOf('constructor')<k)continue;" ++
            "for(var j=k+1;j<n.length;j++){var m=n[j];if(m==='constructor')continue;" ++
            "var d=Object.getOwnPropertyDescriptor(p,m);if(!d||!d.configurable)continue;" ++
            "delete p[m];Object.defineProperty(p,m,d);}}})([" ++ table ++ "])";
    };

    const code = v8.v8__String__NewFromUtf8(isolate, code_str.ptr, v8.kNormal, @intCast(code_str.len));
    const script = v8.v8__Script__Compile(context, code, null) orelse return error.ScriptCompileFailed;
    _ = v8.v8__Script__Run(script, context) orelse return error.ScriptRunFailed;
}

fn hasGatedMember(comptime JsApi: type) bool {
    comptime {
        for (@typeInfo(JsApi).@"struct".decls) |d| {
            if (memberExposed(@field(JsApi, d.name)) != .both) {
                return true;
            }
        }
        return false;
    }
}

fn memberExposed(value: anytype) Caller.Function.Opts.Exposed {
    const T = @TypeOf(value);
    if (T == bridge.Accessor or T == bridge.Function) {
        return value.exposed;
    }
    return .both;
}

// The [SecureContext] gate works off a list of names, so a typo would silently
// gate nothing at all. Every name in it has to be a global this engine puts on
// the page realm: an interface object, one of its extra constructor names, a
// namespace, or a Window member.
comptime {
    @setEvalBranchQuota(500_000);
    for (secure_context.gated_interfaces) |name| {
        if (isPageInterfaceName(name) == false) {
            @compileError("secure_context.gated_interfaces: no interface object named " ++ name);
        }
    }
    for (secure_context.gated_members) |name| {
        if (@hasDecl(@import("../webapi/Window.zig").JsApi, name) == false) {
            @compileError("secure_context.gated_members: Window has no member named " ++ name);
        }
    }
}

fn isPageInterfaceName(comptime name: []const u8) bool {
    // One [SecureContext] list covers both realms, so a name that only a worker
    // carries -- FileSystemSyncAccessHandle is [Exposed=DedicatedWorker] -- is a
    // real entry rather than a typo.
    return isInterfaceNameIn(PageJsApis, name) or isInterfaceNameIn(DedicatedWorkerJsApis, name);
}

fn isInterfaceNameIn(comptime apis: anytype, comptime name: []const u8) bool {
    comptime {
        for (apis) |JsApi| {
            if (!@hasDecl(JsApi.Meta, "name")) continue;
            if (std.mem.eql(u8, JsApi.Meta.name, name)) return true;
            if (@hasDecl(JsApi.Meta, "constructor_alias") and
                std.mem.eql(u8, JsApi.Meta.constructor_alias, name)) return true;
            if (@hasDecl(JsApi.Meta, "constructor_aliases")) {
                for (JsApi.Meta.constructor_aliases) |alias| {
                    if (std.mem.eql(u8, alias, name)) return true;
                }
            }
        }
        return false;
    }
}

fn countExternalReferences() comptime_int {
    @setEvalBranchQuota(100_000);

    var count: comptime_int = 0;

    // +1 for the illegal constructor callback shared by various types
    count += 1;

    // +1 for the noop function shared by various types
    count += 1;

    // +1 for unknownWindowPropertyCallback used on Window's global template
    count += 1;

    // +1 for the access-check callback the cross-origin window proxy's template
    // carries. Unconditional rather than counted per interface: it is one
    // shared C function whatever number of templates install it, and an
    // uncounted entry is an isolate that aborts on deserialisation.
    count += 1;

    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (JsApis) |JsApi| {
        // Same precedence generateConstructor uses: an explicit constructor
        // wins, otherwise a built-in element interface gets its own generated
        // upgrade constructor, otherwise the shared illegal one (counted above).
        if (@hasDecl(JsApi, "constructor")) {
            count += 1;
        } else if (inheritsFromHtmlElement(JsApi)) {
            count += 1;
        }

        if (@hasDecl(JsApi, "callable")) {
            count += 1;
        }

        const declarations = @typeInfo(JsApi).@"struct".decls;
        inline for (declarations) |d| {
            const value = @field(JsApi, d.name);
            const T = @TypeOf(value);
            if (T == bridge.Accessor) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }
                count += 1;
                if (value.setter != null) {
                    count += 1;
                }
            } else if (T == bridge.Function) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }
                count += 1;
            } else if (T == bridge.Iterator) {
                count += 1;
            } else if (T == bridge.Indexed) {
                count += 1;
                if (value.enumerator != null) {
                    count += 1;
                }
                if (value.setter != null) count += 1;
                if (value.deleter != null) count += 1;
                if (value.query != null) count += 1;
                if (value.definer != null) count += 1;
            } else if (T == bridge.NamedIndexed) {
                count += 1;
                if (value.setter != null) count += 1;
                if (value.deleter != null) count += 1;
                if (value.query != null) count += 1;
                if (value.definer != null) count += 1;
                if (value.descriptor != null) count += 1;
                if (value.enumerator != null) count += 1;
            }
        }
    }

    if (comptime lp.IS_DEBUG) {
        inline for (JsApis) |JsApi| {
            if (!hasNamedIndexedGetter(JsApi)) {
                count += 1;
            }
        }
    }

    return count + 1; // +1 for null terminator
}

fn collectExternalReferences() [countExternalReferences()]isize {
    var idx: usize = 0;
    var references = std.mem.zeroes([countExternalReferences()]isize);

    references[idx] = @bitCast(@intFromPtr(&illegalConstructorCallback));
    idx += 1;

    references[idx] = @bitCast(@intFromPtr(&bridge.Function.noopFunction));
    idx += 1;

    references[idx] = @bitCast(@intFromPtr(&bridge.unknownWindowPropertyCallback));
    idx += 1;

    references[idx] = @bitCast(@intFromPtr(access_check.callbackAddress()));
    idx += 1;

    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (JsApis) |JsApi| {
        if (@hasDecl(JsApi, "constructor")) {
            references[idx] = @bitCast(@intFromPtr(JsApi.constructor.func));
            idx += 1;
        } else if (comptime inheritsFromHtmlElement(JsApi)) {
            references[idx] = @bitCast(@intFromPtr(upgradeConstructor(JsApi).func));
            idx += 1;
        }

        if (@hasDecl(JsApi, "callable")) {
            references[idx] = @bitCast(@intFromPtr(JsApi.callable.func));
            idx += 1;
        }

        const declarations = @typeInfo(JsApi).@"struct".decls;
        inline for (declarations) |d| {
            const value = @field(JsApi, d.name);
            const T = @TypeOf(value);
            if (T == bridge.Accessor) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }

                // The recorder, not the bare getter: attachClass installs the
                // wrapped pointer and V8 refuses to serialize a callback the
                // table doesn't name. Outside Debug logReads is the identity.
                references[idx] = @bitCast(@intFromPtr(bridge.logReads(JsApi, d.name, value).getter));
                idx += 1;
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
            } else if (T == bridge.Function) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }
                references[idx] = @bitCast(@intFromPtr(bridge.logReads(JsApi, d.name, value).func));
                idx += 1;
            } else if (T == bridge.Iterator) {
                references[idx] = @bitCast(@intFromPtr(value.func));
                idx += 1;
            } else if (T == bridge.Indexed) {
                references[idx] = @bitCast(@intFromPtr(value.getter));
                idx += 1;
                if (value.enumerator) |enumerator| {
                    references[idx] = @bitCast(@intFromPtr(enumerator));
                    idx += 1;
                }
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
                if (value.deleter) |deleter| {
                    references[idx] = @bitCast(@intFromPtr(deleter));
                    idx += 1;
                }
                if (value.query) |query| {
                    references[idx] = @bitCast(@intFromPtr(query));
                    idx += 1;
                }
                if (value.definer) |definer| {
                    references[idx] = @bitCast(@intFromPtr(definer));
                    idx += 1;
                }
            } else if (T == bridge.NamedIndexed) {
                // The recorder, for the same reason the accessor above uses it.
                references[idx] = @bitCast(@intFromPtr(bridge.logReads(JsApi, d.name, value).getter));
                idx += 1;
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
                if (value.deleter) |deleter| {
                    references[idx] = @bitCast(@intFromPtr(deleter));
                    idx += 1;
                }
                if (value.query) |query| {
                    references[idx] = @bitCast(@intFromPtr(query));
                    idx += 1;
                }
                if (value.definer) |definer| {
                    references[idx] = @bitCast(@intFromPtr(definer));
                    idx += 1;
                }
                if (value.descriptor) |descriptor| {
                    references[idx] = @bitCast(@intFromPtr(descriptor));
                    idx += 1;
                }
                if (value.enumerator) |enumerator| {
                    references[idx] = @bitCast(@intFromPtr(enumerator));
                    idx += 1;
                }
            }
        }
    }

    if (comptime lp.IS_DEBUG) {
        inline for (JsApis) |JsApi| {
            if (!hasNamedIndexedGetter(JsApi)) {
                references[idx] = @bitCast(@intFromPtr(bridge.unknownObjectPropertyCallback(JsApi)));
                idx += 1;
            }
        }
    }

    return references;
}

fn countInternalFields(comptime JsApi: type) u8 {
    var last_used_id = 0;
    var cache_count: u8 = 0;

    inline for (@typeInfo(JsApi).@"struct".decls) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        switch (definition) {
            inline bridge.Accessor, bridge.Function => {
                const cache = value.cache orelse continue;
                if (cache != .internal) {
                    continue;
                }
                // We assert that they are declared in-order. This isn't necessary
                // but I don't want to do anything fancy to look for gaps or
                // duplicates.
                const internal_id = cache.internal;
                if (internal_id != last_used_id + 1) {
                    @compileError(@typeName(JsApi) ++ "." ++ name ++ " has a non-monotonic cache index");
                }
                last_used_id = internal_id;
                cache_count += 1; // this is just last_used, but it's more explicit this way
            },
            else => {},
        }
    }

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        return cache_count;
    }

    // we need cache_count internal fields, + 1 for the TAO pointer (the v8 -> Zig)
    // mapping) itself.
    return cache_count + 1;
}

// Shared illegal constructor callback for types without explicit constructors
fn illegalConstructorCallback(raw_info: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(raw_info);

    // Recover the constructor's name via NewTarget, whose .name property was
    // set via SetClassName when the FunctionTemplate was built. Lets us tell
    // `new DOMException()` apart from `new MutationRecord()` in the warning.
    // A plain call has no new.target and gets no name -- which is also what
    // Chrome does, see the message below.
    var name_buf: [128]u8 = undefined;
    var name: []const u8 = "<unknown>";
    if (v8.v8__FunctionCallbackInfo__NewTarget(raw_info)) |new_target| {
        if (v8.v8__Value__IsFunction(new_target)) {
            const func: *const v8.Function = @ptrCast(new_target);
            if (v8.v8__Function__GetName(func)) |name_value| {
                if (v8.v8__Value__IsString(name_value)) {
                    const str: *const v8.String = @ptrCast(name_value);
                    const n = v8.v8__String__WriteUtf8(str, isolate, &name_buf, name_buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
                    name = name_buf[0..@intCast(n)];
                }
            }
        }
    }
    log.info(.js, "Illegal constructor call", .{ .name = name });

    // Chrome names the interface in the message (measured on a headed Chrome
    // 150: new Permissions() gives "Failed to construct 'Permissions': Illegal
    // constructor"), and the class name is already in hand from new.target.
    // Called as a plain function -- `Permissions()` -- there is no new.target
    // and Chrome answers a bare "Illegal constructor" (measured the same way),
    // so the name never reaches the message and never leaks a placeholder.
    var message_buf: [name_buf.len + 48]u8 = undefined;
    const message_text = if (v8.v8__FunctionCallbackInfo__IsConstructCall(raw_info))
        std.fmt.bufPrint(
            &message_buf,
            "Failed to construct '{s}': Illegal constructor",
            .{name},
        ) catch "Illegal constructor"
    else
        "Illegal constructor";
    const message = v8.v8__String__NewFromUtf8(isolate, message_text.ptr, v8.kNormal, @intCast(message_text.len));
    const js_exception = v8.v8__Exception__TypeError(message);

    _ = v8.v8__Isolate__ThrowException(isolate, js_exception);
    var return_value: v8.ReturnValue = undefined;
    v8.v8__FunctionCallbackInfo__GetReturnValue(raw_info, &return_value);
    v8.v8__ReturnValue__Set(return_value, js_exception);
}

// Helper to check if a JsApi has a NamedIndexed handler (public for reuse)
fn hasNamedIndexedGetter(comptime JsApi: type) bool {
    const declarations = @typeInfo(JsApi).@"struct".decls;
    inline for (declarations) |d| {
        const value = @field(JsApi, d.name);
        const T = @TypeOf(value);
        if (T == bridge.NamedIndexed) {
            return true;
        }
    }
    return false;
}

// Generic prototype index lookup for a given API list
fn protoIndexLookup(comptime JsApi: type) ?u16 {
    // Scales with the number of registered interfaces times the length of each
    // one's prototype chain, so it needs headroom every time a batch of
    // interfaces lands.
    @setEvalBranchQuota(400_000);
    comptime {
        const T = JsApi.bridge.type;
        const F = reflect.Proto(T) orelse return null;
        // Look up in the provided API list
        for (JsApis, 0..) |Api, i| {
            if (Api == F.JsApi) {
                return i;
            }
        }
        @compileError("Prototype " ++ @typeName(F.JsApi) ++ " not found in API list");
    }
}

// Generate a constructor template for a JsApi type (public for reuse)
pub fn generateConstructor(comptime JsApi: type, isolate: *v8.Isolate) *const v8.FunctionTemplate {
    const callback, const arity = comptime blk: {
        if (@hasDecl(JsApi, "constructor")) {
            break :blk .{ JsApi.constructor.func, JsApi.constructor.arity };
        }
        if (inheritsFromHtmlElement(JsApi)) {
            const upgrade = upgradeConstructor(JsApi);
            break :blk .{ upgrade.func, upgrade.arity };
        }
        break :blk .{ &illegalConstructorCallback, @as(c_int, 0) };
    };
    const template = v8.v8__FunctionTemplate__New__Config(isolate, &.{
        .length = arity,
        .callback = callback,
        .behavior = v8.kConstructorBehavior_Allow,
    }).?;
    {
        const internal_field_count = comptime countInternalFields(JsApi);
        if (internal_field_count > 0) {
            const instance_template = v8.v8__FunctionTemplate__InstanceTemplate(template);
            v8.v8__ObjectTemplate__SetInternalFieldCount(instance_template, internal_field_count);
        }
    }
    const name_str = if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi);
    const class_name = v8.v8__String__NewFromUtf8(isolate, name_str.ptr, v8.kNormal, @intCast(name_str.len));
    v8.v8__FunctionTemplate__SetClassName(template, class_name);
    // Web IDL: interface object's `prototype` property is non-writable/non-configurable.
    v8.v8__FunctionTemplate__ReadOnlyPrototype(template);
    return template;
}

// hard-coded special case for HtmlElement which can be extended but not
// instantiated.
fn inheritsFromHtmlElement(comptime JsApi: type) bool {
    const T = JsApi.bridge.type;
    if (T == HtmlElement) {
        return false;
    }
    // Two element interfaces are not valid custom element bases, so Blink gives
    // them no [HTMLConstructor] and therefore no constructor callback to reach:
    // `HTMLUnknownElement()` is a bare "Illegal constructor" where every other
    // element interface points at the `new` operator, and `new
    // HTMLUnknownElement()` still names the interface (both measured on Chrome
    // 151, probes/probe-ctor-sweep.js). Falling through to
    // illegalConstructorCallback is what produces exactly that pair.
    if (T == HtmlElement.Media or T == HtmlElement.Unknown) {
        return false;
    }
    return bridge.inheritsOrIs(JsApi, HtmlElement.JsApi);
}

// The shared constructor callback for the built-in element interfaces, but
// generated per interface rather than once: the interface name in both messages
// it can produce -- "Failed to construct 'X': Illegal constructor" for `new X()`
// and the "use the 'new' operator" sentence for `X()` -- is comptime, read off
// the type the callback was generated for. One shared callback made every
// element interface claim to be HTMLElement, which is a name a page can read
// straight off `HTMLDivElement()` (Chrome says HTMLDivElement, measured).
fn upgradeConstructor(comptime JsApi: type) bridge.Constructor {
    return JsApi.bridge.constructor(HtmlElement.upgradeConstruct, .{});
}

const Unforgeable = struct {
    Owner: type,
    name: [:0]const u8,
    member: union(enum) {
        accessor: bridge.Accessor,
        operation: bridge.Function,
    },
};

/// Whether this interface is guarded by a V8 access check rather than by a
/// plain interceptor. Read from two places -- the named handler installs the
/// check, the indexed one steps aside for it -- so it lives here.
fn isAccessChecked(comptime JsApi: type) bool {
    return @hasDecl(JsApi.Meta, "access_check") and JsApi.Meta.access_check;
}

/// The interface's `bridge.Indexed` member, if it declares one. An interface
/// has at most one; the loop below finds it by type rather than by name
/// because the member's declared name (`[]`) is not part of the contract.
fn indexedMember(comptime JsApi: type) ?bridge.Indexed {
    for (@typeInfo(JsApi).@"struct".decls) |d| {
        const value = @field(JsApi, d.name);
        if (@TypeOf(value) == bridge.Indexed) {
            return value;
        }
    }
    return null;
}

fn indexedConfiguration(member: bridge.Indexed) v8.IndexedPropertyHandlerConfiguration {
    return .{
        .getter = member.getter,
        .enumerator = member.enumerator,
        .setter = member.setter,
        .query = member.query,
        .deleter = member.deleter,
        .definer = if (member.definer) |definer| @ptrCast(definer) else null,
        .descriptor = null,
        .index_of = null,
        .data = null,
        .flags = 0,
    };
}

fn attachClass(comptime JsApi: type, comptime flatten: bool, isolate: *v8.Isolate, template: *const v8.FunctionTemplate, define_on: ?*const v8.ObjectTemplate) void {
    const instance = v8.v8__FunctionTemplate__InstanceTemplate(template);
    const prototype = v8.v8__FunctionTemplate__PrototypeTemplate(template);
    const signature = v8.v8__Signature__New(isolate, template);

    // Namespace objects (e.g. console) expose their members as own properties
    // of each instance rather than via the prototype, so Object.entries(...)
    // returns them. See https://console.spec.whatwg.org/#console-namespace.
    const own_properties = @hasDecl(JsApi.Meta, "own_properties") and JsApi.Meta.own_properties;
    const member_template = if (own_properties) instance else prototype;

    // Web IDL [Global]: this interface's attributes and operations are own
    // properties of the global object, so they do not go on the interface
    // prototype object at all. createSnapshotContext puts them on the global
    // (attachClass with flatten = true); the regular pass here leaves the
    // prototype with its constants, its brand and `constructor` -- the three
    // names headless Chrome 151 reports for Object.getOwnPropertyNames(
    // Window.prototype): PERSISTENT, TEMPORARY, constructor.
    const is_global = @hasDecl(JsApi.Meta, "global") and JsApi.Meta.global;

    // Web IDL brands the interface *prototype* object, never the instances; a
    // namespace object (which has no prototype of its own) carries the brand
    // directly. Measured on a headed Chrome 150:
    //
    //   Object.getOwnPropertyDescriptor(Element.prototype, Symbol.toStringTag)
    //     -> { value: 'Element', writable: false, enumerable: false, configurable: true }
    //   Object.getOwnPropertySymbols(document.createElement('div')) -> []
    //   Object.prototype.toString.call(console) -> '[object console]'
    //
    // This runs before the member loop so the brand sorts ahead of @@iterator
    // in getOwnPropertySymbols, the way Blink orders them. In [Global]
    // flattening mode we skip it: the class already got its brand from the
    // regular pass, and Chrome's `window` owns no symbol of its own -- it
    // inherits '[object Window]' from Window.prototype.
    if (comptime !flatten and @hasDecl(JsApi.Meta, "name")) {
        const js_name = v8.v8__Symbol__GetToStringTag(isolate);
        // A cross-origin WindowProxy carries the symbol but not a tag: the
        // value is `undefined`, so Object.prototype.toString finds nothing to
        // brand with and answers '[object Object]'.
        const js_value: *const v8.Value = if (comptime @hasDecl(JsApi.Meta, "to_string_tag_undefined"))
            @ptrCast(v8.v8__Undefined(isolate))
        else blk: {
            const tag = comptime if (@hasDecl(JsApi.Meta, "to_string_tag")) JsApi.Meta.to_string_tag else JsApi.Meta.name;
            break :blk @ptrCast(v8.v8__String__NewFromUtf8(isolate, tag.ptr, v8.kNormal, @intCast(tag.len)));
        };
        v8.v8__Template__Set(@ptrCast(if (own_properties) instance else prototype), js_name, @ptrCast(js_value), v8.ReadOnly + v8.DontEnum);
    }

    const declarations = @typeInfo(JsApi).@"struct".decls;
    var has_named_index_getter = false;

    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (declarations) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        if (comptime flatten) {
            // [Global] flattening only mirrors non-static accessors/methods onto itself
            switch (definition) {
                bridge.Accessor, bridge.Function => if (value.static) continue,
                else => continue,
            }
        } else if (comptime is_global) {
            // ...and those same members are the ones the interface prototype
            // object does not get. A static member is not part of the
            // flattening, so it still belongs on the interface object.
            switch (definition) {
                bridge.Accessor, bridge.Function => if (value.static == false) continue,
                else => {},
            }
        }

        switch (definition) {
            bridge.Accessor => {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }

                if (comptime value.unforgeable) {
                    // this accessor will be handled in the unforgeables loop
                    // later in this function.
                    continue;
                }
                attachAccessorProperty(name, bridge.logReads(JsApi, name, value), isolate, template, signature, define_on orelse member_template, own_properties);
            },
            bridge.Function => {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }

                if (comptime value.unforgeable) {
                    // this operation will be handled in the unforgeables loop
                    // later in this function.
                    continue;
                }

                const logged = bridge.logReads(JsApi, name, value);
                if (value.static and !own_properties) {
                    attachOperationProperty(name, logged, isolate, signature, template, v8.None);
                } else {
                    // Web IDL: operations on the interface prototype object
                    // (and mirrored onto [Global] instances) are enumerable and
                    // writable, unless the member opted out (window.webkitURL
                    // for the first, a cross-origin WindowProxy's four for the
                    // second).
                    var attribute: v8.PropertyAttribute = 0;
                    if (value.enumerable == false) {
                        attribute |= v8.DontEnum;
                    }
                    if (value.writable == false) {
                        attribute |= v8.ReadOnly;
                    }
                    attachOperationProperty(name, logged, isolate, signature, define_on orelse member_template, attribute);
                }
            },
            bridge.Indexed => {
                // Under an access check V8 takes the named and indexed handlers
                // together, in the single call that installs the check, so the
                // NamedIndexed arm below reaches over and installs this one too.
                if (comptime isAccessChecked(JsApi)) {
                    continue;
                }
                var configuration = indexedConfiguration(value);
                v8.v8__ObjectTemplate__SetIndexedHandler(instance, &configuration);
            },
            bridge.NamedIndexed => {
                // `access_check` swaps three things at once, and they go
                // together. The flags lose kNonMasking, because the whole point
                // is to be consulted BEFORE the own properties rather than
                // after them; they lose kOnlyInterceptStrings too, because the
                // alternative for a symbol is the failed-access-check callback,
                // which must throw -- and Chrome answers
                // `Object.prototype.toString.call(w)` with '[object Object]';
                // and the handler is installed through V8's access check rather
                // than as a plain interceptor, because an interceptor is
                // skipped on the paths this exists to close -- `JSON.stringify`,
                // `in` and `delete` over an own key. See
                // browser/js/access_check.zig.
                const guarded = comptime isAccessChecked(JsApi);
                var configuration: v8.NamedPropertyHandlerConfiguration = .{
                    .getter = bridge.logReads(JsApi, name, value).getter,
                    .setter = value.setter,
                    .query = value.query,
                    .deleter = value.deleter,
                    .enumerator = value.enumerator,
                    .definer = if (value.definer) |definer| @ptrCast(definer) else null,
                    .descriptor = if (value.descriptor) |descriptor| @ptrCast(descriptor) else null,
                    .data = null,
                    .flags = if (guarded) 0 else v8.kOnlyInterceptStrings | v8.kNonMasking,
                };
                if (guarded) {
                    // Both handlers go in together, so the interface's indexed
                    // member -- which skipped its own install above -- is
                    // picked up here. Without one every index lands on the
                    // failure callback, whose sentence is the bare one; Chrome
                    // names the index.
                    var indexed = if (comptime indexedMember(JsApi)) |member|
                        indexedConfiguration(member)
                    else
                        std.mem.zeroes(v8.IndexedPropertyHandlerConfiguration);
                    access_check.installHandler(instance, &configuration, &indexed);
                } else {
                    v8.v8__ObjectTemplate__SetNamedHandler(instance, &configuration);
                }
                has_named_index_getter = true;
            },
            bridge.Iterator => {
                const function_template = v8.v8__FunctionTemplate__New__Config(isolate, &.{ .callback = value.func }).?;
                if (value.js_name) |fn_name| {
                    v8.v8__FunctionTemplate__SetClassName(
                        function_template,
                        v8.v8__String__NewFromUtf8(isolate, fn_name.ptr, v8.kNormal, @intCast(fn_name.len)),
                    );
                }
                const js_name = if (value.async)
                    v8.v8__Symbol__GetAsyncIterator(isolate)
                else
                    v8.v8__Symbol__GetIterator(isolate);
                // Web IDL: @@iterator is { writable, enumerable: false, configurable }.
                v8.v8__Template__Set(@ptrCast(prototype), js_name, @ptrCast(function_template), v8.DontEnum);
            },
            bridge.Property => {
                const js_value = switch (value.value) {
                    .null => js.simpleZigValueToJs(.{ .handle = isolate }, null, true, false),
                    inline .bool, .int, .float, .string => |v| js.simpleZigValueToJs(.{ .handle = isolate }, v, true, false),
                };
                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));

                {
                    // A namespace's constants are own properties of the
                    // namespace object, the same as its operations.
                    const flags = if (value.readonly) v8.ReadOnly + v8.DontDelete else 0;
                    v8.v8__Template__Set(@ptrCast(member_template), js_name, js_value, flags);
                }

                if (value.template) {
                    v8.v8__Template__Set(@ptrCast(template), js_name, js_value, v8.ReadOnly + v8.DontDelete);
                }
            },
            bridge.Constructor => {},
            else => {},
        }
    }

    // HTML's CrossOriginOwnPropertyKeys ends with four keys the proxy owns but
    // never fills: `then`, then @@hasInstance and @@isConcatSpreadable (the
    // brand symbol is the third, and it is already written above so that it
    // sorts first). Each is a data property whose value is undefined --
    // `{ value: undefined, writable: false, enumerable: false, configurable:
    // true }` on Chrome 151 (expr-xo-proxy-detail). They are here, after the
    // member loop, because their order among the own names is the tail.
    //
    // `then` earns its place: an object with an own `then` is a thenable, and
    // `await w` on one that answers undefined resolves to the object instead of
    // hanging on a call to it. The symbols do the same job for
    // Object.prototype.toString, instanceof and Array.prototype.concat.
    if (comptime !flatten and @hasDecl(JsApi.Meta, "undefined_own_keys")) {
        inline for (JsApi.Meta.undefined_own_keys) |key| {
            const js_key: *const v8.Name = if (comptime @typeInfo(@TypeOf(key)) == .enum_literal) switch (key) {
                .has_instance => @ptrCast(v8.v8__Symbol__GetHasInstance(isolate)),
                .is_concat_spreadable => @ptrCast(v8.v8__Symbol__GetIsConcatSpreadable(isolate)),
                else => @compileError("unknown well-known symbol: " ++ @tagName(key)),
            } else @ptrCast(v8.v8__String__NewFromUtf8(isolate, key.ptr, v8.kNormal, @intCast(key.len)));

            v8.v8__Template__Set(
                @ptrCast(instance),
                @ptrCast(js_key),
                @ptrCast(v8.v8__Undefined(isolate)),
                v8.ReadOnly + v8.DontEnum,
            );
        }
    }

    if (comptime flatten == false) {
        inline for (unforgeables) |u| {
            if (comptime bridge.inheritsOrIs(JsApi, u.Owner)) {
                // unforgeable members aren't only applied directly on the
                // instance, they're also applied directly on every child instance
                switch (u.member) {
                    // Keyed on the declaring interface, not the one it's being
                    // installed on: an unforgeable lands on every inheriting
                    // instance, and the reference table registered it once,
                    // under its owner.
                    .accessor => |accessor| attachAccessorProperty(u.name, bridge.logReads(u.Owner, u.name, accessor), isolate, template, signature, instance, false),
                    // Web IDL: an unforgeable operation is a non-writable,
                    // non-configurable own data property of the instance --
                    // `Object.getOwnPropertyDescriptor(location, 'reload')`
                    // reports writable and configurable both false on Chrome
                    // 151. An accessor gets the same two bits from
                    // `deletable = false` plus its missing setter.
                    .operation => |operation| {
                        var attribute: v8.PropertyAttribute = v8.ReadOnly + v8.DontDelete;
                        if (operation.enumerable == false) {
                            attribute |= v8.DontEnum;
                        }
                        attachOperationProperty(u.name, bridge.logReads(u.Owner, u.name, operation), isolate, signature, instance, attribute);
                    },
                }
            }
        }
    }

    // The remaining per-class setup targets the class's own instance template;
    // in [Global] flattening mode the global already has these (or doesn't need
    // them), so skip it.
    if (comptime flatten) {
        return;
    }

    // Not a Web IDL member: HTML's "create a Location object" steps hang an own
    // @@toPrimitive of value `undefined` off every Location, so that coercing
    // one falls back to `toString` rather than reaching for @@toPrimitive and
    // finding an inherited one. Measured on Chrome 151:
    //
    //   Object.getOwnPropertySymbols(location) -> [Symbol(Symbol.toPrimitive)]
    //   ...descriptor -> { value: undefined, writable: false,
    //                      enumerable: false, configurable: false }
    //
    // The same steps also define an own `valueOf` holding the realm's
    // %Object.prototype.valueOf%. That one is not here: the value is a
    // per-context object and a template can only carry snapshot data, so
    // installing it would have to mint a *different* function -- trading a
    // missing own property for a wrong identity, which is not a trade.
    if (@hasDecl(JsApi.Meta, "to_primitive_undefined")) {
        v8.v8__Template__Set(
            @ptrCast(instance),
            @ptrCast(v8.v8__Symbol__GetToPrimitive(isolate)),
            @ptrCast(v8.v8__Undefined(isolate)),
            v8.ReadOnly + v8.DontDelete + v8.DontEnum,
        );
    }

    if (@hasDecl(JsApi.Meta, "htmldda")) {
        v8.v8__ObjectTemplate__MarkAsUndetectable(instance);
        v8.v8__ObjectTemplate__SetCallAsFunctionHandler(instance, JsApi.Meta.callable.func);
    }

    // Upstream's @@toStringTag block went here, keyed off `Meta.class_string`.
    // It is not taken: the brand is already emitted above, before the member
    // loop, off `Meta.to_string_tag` -- which is the measured shape. Upstream's
    // version always writes the symbol on `instance`, which would give every
    // ordinary interface's instances an own @@toStringTag; Chrome has none
    // (`Object.getOwnPropertySymbols(document.createElement('div'))` is empty),
    // and it would sort the brand after @@iterator instead of before it.
    if (comptime lp.IS_DEBUG) {
        // A [Global] interface's instance template is the context's global
        // object, and that one already gets a named handler in
        // createSnapshotContext; installing a second one on the same template
        // would replace it, taking named element access with it.
        if (!has_named_index_getter and !is_global) {
            var configuration: v8.NamedPropertyHandlerConfiguration = .{
                .getter = bridge.unknownObjectPropertyCallback(JsApi),
                .setter = null,
                .query = null,
                .deleter = null,
                .enumerator = null,
                .definer = null,
                .descriptor = null,
                .data = null,
                .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
            };
            v8.v8__ObjectTemplate__SetNamedHandler(instance, &configuration);
        }
    }
}

// Every [LegacyUnforgeable] member. We collect this once so we don't need to
// keep scanning for this in attachClass. Operations belong here as much as
// attributes do: Location is unforgeable end to end, and leaving `reload` on
// the prototype while moving `href` off it swaps one one-line tell for another.
const unforgeables: []const Unforgeable = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const Unforgeable = &.{};
    for (JsApis) |Api| {
        for (@typeInfo(Api).@"struct".decls) |d| {
            const value = @field(Api, d.name);
            switch (@TypeOf(value)) {
                bridge.Accessor => if (value.unforgeable and !value.static) {
                    list = list ++ &[_]Unforgeable{.{ .Owner = Api, .name = d.name, .member = .{ .accessor = value } }};
                },
                bridge.Function => if (value.unforgeable and !value.static) {
                    list = list ++ &[_]Unforgeable{.{ .Owner = Api, .name = d.name, .member = .{ .operation = value } }};
                },
                else => {},
            }
        }
    }
    break :blk list;
};

// Attach JsApi members to a template (public for reuse). This is called on all
// types. But, for globals (window, WGS) it's called twice. The first time, it's
// called like any other interface. The 2nd time, it's called with flatten == true
// and define_on != null. This is the "flattening" pass, and it defines all of
// the functions/accessors on directly on the global instance. Thus, globals have
// it defined on both their prototype (first pass) and their own instance (2nd pass).
// `static_on_target` puts a static accessor on `target` instead of on the
// interface object. A namespace (own_properties) has no prototype of its own and
// is reached as an instance, so `CSS.highlights` -- a static accessor -- has to
// land on the instance template the way a static *operation* already does.
// Builds an operation's function template and puts it on `target` with the
// attributes the caller asks for. Split out of the member loop because the
// [LegacyUnforgeable] pass installs the same operation a second way -- on the
// instance template, non-writable and non-configurable -- and one builder means
// the two spellings cannot drift apart.
fn attachOperationProperty(comptime name: [:0]const u8, value: bridge.Function, isolate: *v8.Isolate, signature: anytype, target: anytype, attribute: v8.PropertyAttribute) void {
    // A member may override its JS-visible name (see Response.json_static)
    const fn_name = value.js_name orelse name;
    const js_name = v8.v8__String__NewFromUtf8(isolate, fn_name.ptr, v8.kNormal, @intCast(fn_name.len));
    // For non-static functions, use the signature to validate the
    // receiver, unless the operation has to reject rather than throw.
    const func_signature = if (value.static or value.rejects_bad_receiver) null else signature;
    const function_template = v8.v8__FunctionTemplate__New__Config(isolate, &.{
        .callback = value.func,
        // The same string the class name uses, handed to the callback as its
        // data: a refusal that names the operation ("Failed to execute
        // 'createElement' on 'Document'") has no other way to reach the name.
        // See Caller.FunctionCallbackInfo.operationName.
        .data = @ptrCast(js_name),
        .length = @intCast(value.arity),
        .signature = func_signature,
    }).?;
    v8.v8__FunctionTemplate__SetClassName(function_template, js_name);
    v8.v8__Template__Set(@ptrCast(target), js_name, @ptrCast(function_template), attribute);
}

fn attachAccessorProperty(comptime name: [:0]const u8, value: bridge.Accessor, isolate: *v8.Isolate, template: *const v8.FunctionTemplate, signature: anytype, target: anytype, comptime static_on_target: bool) void {
    const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
    const getter_signature = if (value.static) null else signature;
    const getter_callback = v8.v8__FunctionTemplate__New__Config(isolate, &.{
        .callback = value.getter,
        .signature = getter_signature,
    }).?;
    // WebIDL: getter function's .name should be "get X". An anonymous accessor
    // (console.memory) keeps v8's default empty name instead.
    if (!value.anonymous) {
        const getter_name_str = "get " ++ name;
        const getter_name_v8 = v8.v8__String__NewFromUtf8(isolate, getter_name_str.ptr, v8.kNormal, @intCast(getter_name_str.len));
        v8.v8__FunctionTemplate__SetClassName(getter_callback, getter_name_v8);
    }

    const setter_callback = if (value.setter) |setter| blk: {
        const cb = v8.v8__FunctionTemplate__New__Config(isolate, &.{
            .callback = setter,
            // The attribute's name, handed to the callback as its data, the
            // same way an operation's template carries its own: a setter that
            // refuses a value names the property it refused it for ("Failed to
            // set the 'href' property on 'URL'") and has no other way to reach
            // the name. See Caller.setterPrefix. The getter half needs none --
            // it converts nothing and so refuses nothing.
            .data = @ptrCast(js_name),
            .signature = getter_signature,
            .length = if (value.anonymous) 0 else 1,
        }).?;
        if (!value.anonymous) {
            const setter_name_str = "set " ++ name;
            const setter_name_v8 = v8.v8__String__NewFromUtf8(isolate, setter_name_str.ptr, v8.kNormal, @intCast(setter_name_str.len));
            v8.v8__FunctionTemplate__SetClassName(cb, setter_name_v8);
        }
        break :blk cb;
    } else null;

    // No ReadOnly bit for a getter-only accessor. WebIDL says a read-only
    // attribute *is* an accessor whose setter is absent, and the bit on top of
    // that is not the same thing: it decides which of V8's two refusals a
    // strict-mode write gets. With it, `navigator.userAgent = 'x'` reads
    // "Cannot assign to read only property 'userAgent' of object
    // '#<Navigator>'" -- V8's sentence for a non-writable *data* property, and
    // naming the receiver. Without it V8 walks into the accessor pair, finds no
    // setter, and says what Chrome says: "Cannot set property userAgent of
    // #<Navigator> which has only a getter", naming the holder. The two
    // descriptors are byte-identical either way (measured on both engines), so
    // the throw is the only place this shows -- which is exactly the kind of
    // difference a detector reads and a value-comparing test cannot.
    var attribute: v8.PropertyAttribute = 0;
    if (value.deletable == false) {
        attribute |= v8.DontDelete;
    }
    if (value.enumerable == false) {
        attribute |= v8.DontEnum;
    }

    if (value.static and static_on_target == false) {
        v8.v8__Template__SetAccessorProperty(@ptrCast(template), js_name, getter_callback, setter_callback, attribute);
    } else {
        // Web IDL: attributes on the interface prototype object
        // (and mirrored onto [Global] instances) are enumerable.
        v8.v8__ObjectTemplate__SetAccessorProperty__Config(target, &.{
            .key = js_name,
            .getter = getter_callback,
            .setter = setter_callback,
            .attribute = attribute,
        });
    }
}

const testing = @import("../../testing.zig");
test "Snapshot: Symbol.toStringTag" {
    try testing.htmlRunner("to_string_tag.html", .{});
}

test "Snapshot: constructor slot" {
    try testing.htmlRunner("constructor_slot.html", .{});
}
