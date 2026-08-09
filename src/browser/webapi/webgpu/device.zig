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

// GPUDevice -- the only EventTarget in the WebGPU family -- and the GPUQueue it
// owns. Reached through GPUAdapter.requestDevice, which a page gets to through
// GPU.requestAdapter; see adapter.zig for why that now hands out a real adapter.
//
// Everything measured on a headed Chrome 150 with
// stealth-detector-probes/win-batch/probe-win38.js: the getter block comes
// before the accessor block and neither is alphabetical, `label` starts empty
// and round-trips a written string, `onuncapturederror` reads back null, and
// `lost` stays pending until destroy() settles it with
// {reason: 'destroyed', message: 'Device was destroyed.'}.

const std = @import("std");

const js = @import("../../js/js.zig");
const adapter = @import("adapter.zig");
const dictionary = @import("../dictionary.zig");
const DOMException = @import("../DOMException.zig");
const pipeline = @import("pipeline.zig");
const resources = @import("resources.zig");
const EventTarget = @import("../EventTarget.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        GPUDevice,
        GPUQueue,
    };
}

pub const GPUDevice = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _label: []const u8 = "",
    _on_uncaptured_error: ?js.Function.Global = null,
    // What requestDevice settled on: the default single feature, plus whatever
    // requiredFeatures the adapter accepted.
    _feature_names: []const []const u8 = &adapter.GPUSupportedFeatures.device_default,
    // `device.lost` is the same promise on every read (measured), so the resolver
    // is kept rather than the promise; destroy() settles it.
    _lost: ?js.PromiseResolver.Global = null,
    _destroyed: bool = false,
    // How many error scopes are open. Nothing ever lands in one, so the depth
    // is all there is to keep; see pushErrorScope.
    _error_scopes: u32 = 0,

    // Allocated on first read, never re-created: Chrome hands back the same
    // objects on every read (measured), and an embedded struct would share its
    // owner's address, which is what the JS identity map keys on.
    _features: ?*adapter.GPUSupportedFeatures = null,
    _limits: ?*adapter.GPUSupportedLimits = null,
    _adapter_info: ?*adapter.GPUAdapterInfo = null,
    _queue: ?*GPUQueue = null,

    pub fn asEventTarget(self: *GPUDevice) *EventTarget {
        return self._proto;
    }

    pub fn getFeatures(self: *GPUDevice, exec: *const Execution) !*adapter.GPUSupportedFeatures {
        if (self._features) |features| {
            return features;
        }
        const created = try exec._factory.create(adapter.GPUSupportedFeatures{
            ._features = self._feature_names,
        });
        self._features = created;
        return created;
    }

    pub fn getLimits(self: *GPUDevice, exec: *const Execution) !*adapter.GPUSupportedLimits {
        if (self._limits) |limits| {
            return limits;
        }
        const created = try exec._factory.create(adapter.GPUSupportedLimits{
            ._values = adapter.GPUSupportedLimits.device_default,
        });
        self._limits = created;
        return created;
    }

    // Its own GPUAdapterInfo, not the adapter's: Chrome hands out a distinct
    // object with the same values (measured, `device.adapterInfo !== adapter.info`).
    pub fn getAdapterInfo(self: *GPUDevice, exec: *const Execution) !*adapter.GPUAdapterInfo {
        if (self._adapter_info) |info| {
            return info;
        }
        const created = try exec._factory.create(adapter.GPUAdapterInfo{});
        self._adapter_info = created;
        return created;
    }

    /// Pending while the device is alive, and the same promise on every read
    /// (measured). destroy() is the only thing that settles it here.
    pub fn getLost(self: *GPUDevice, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (self._lost) |resolver| {
            return local.toLocal(resolver).promise();
        }
        const resolver = local.createPromiseResolver();
        self._lost = try resolver.persist();
        const promise = resolver.promise();
        // Nothing rejects it, so a page that never reads it is not a leak the
        // unhandled-rejection tracker should shout about.
        promise.markAsHandled();
        if (self._destroyed) {
            try self.settleLost(exec);
        }
        return promise;
    }

    /// `lost` *resolves* (it does not reject) with reason 'destroyed' and
    /// Chrome's own message. Measured after `device.destroy()`.
    fn settleLost(self: *GPUDevice, exec: *const Execution) !void {
        const resolver = self._lost orelse return;
        const info = try exec._factory.create(adapter.GPUDeviceLostInfo{
            ._reason = "destroyed",
            ._message = "Device was destroyed.",
        });
        exec.js.local.?.toLocal(resolver).resolve("GPUDevice.lost", info);
    }

    /// Chrome keeps the device object usable after destroy() -- the label, the
    /// queue and the limits all still read back -- and only settles `lost`.
    pub fn destroy(self: *GPUDevice, exec: *const Execution) !void {
        if (self._destroyed) {
            return;
        }
        self._destroyed = true;
        if (self._lost != null) {
            try self.settleLost(exec);
        }
    }

    pub fn getQueue(self: *GPUDevice, exec: *const Execution) !*GPUQueue {
        if (self._queue) |queue| {
            return queue;
        }
        const created = try exec._factory.create(GPUQueue{});
        self._queue = created;
        return created;
    }

    pub fn getLabel(self: *const GPUDevice) []const u8 {
        return self._label;
    }

    pub fn setLabel(self: *GPUDevice, value: []const u8, exec: *const Execution) !void {
        self._label = try exec.arena.dupe(u8, value);
    }

    pub fn getOnUncapturedError(self: *GPUDevice) ?js.Function.Global {
        return self._on_uncaptured_error;
    }

    pub fn setOnUncapturedError(self: *GPUDevice, listener: ?js.Function) !void {
        self._on_uncaptured_error = if (listener) |l| try l.persistWithThis(self) else null;
    }

    // The create* family. Each one reads its descriptor the way Chrome does --
    // a missing required member is a synchronous TypeError naming the method,
    // the dictionary and the member -- and hands back the object resources.zig
    // builds. See resources.zig for what is still missing (the asynchronous,
    // error-scope half of validation).
    pub fn createBuffer(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUBuffer {
        return resources.createBuffer(args, exec);
    }

    pub fn createTexture(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUTexture {
        return resources.createTexture(args, exec);
    }

    pub fn createQuerySet(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUQuerySet {
        return resources.createQuerySet(args, exec);
    }

    pub fn createSampler(_: *GPUDevice, descriptor_: ?js.Value, exec: *const Execution) !*resources.GPUSampler {
        return resources.createSampler(descriptor_, exec);
    }

    pub fn createBindGroupLayout(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUBindGroupLayout {
        return resources.createBindGroupLayout(args, exec);
    }

    pub fn createPipelineLayout(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUPipelineLayout {
        return resources.createPipelineLayout(args, exec);
    }

    pub fn createBindGroup(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUBindGroup {
        return resources.createBindGroup(args, exec);
    }

    pub fn importExternalTexture(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*resources.GPUExternalTexture {
        return resources.importExternalTexture(args, exec);
    }

    pub fn createShaderModule(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*pipeline.GPUShaderModule {
        return pipeline.createShaderModule(args, exec);
    }

    pub fn createCommandEncoder(_: *GPUDevice, descriptor_: ?js.Value, exec: *const Execution) !*pipeline.GPUCommandEncoder {
        return pipeline.createCommandEncoder(descriptor_, exec);
    }

    pub fn createRenderBundleEncoder(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*pipeline.GPURenderBundleEncoder {
        return pipeline.createRenderBundleEncoder(args, exec);
    }

    pub fn createComputePipeline(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*pipeline.GPUComputePipeline {
        return pipeline.createComputePipeline(args, exec);
    }

    pub fn createRenderPipeline(_: *GPUDevice, args: []js.Value, exec: *const Execution) !*pipeline.GPURenderPipeline {
        return pipeline.createRenderPipeline(args, exec);
    }

    pub fn createComputePipelineAsync(_: *GPUDevice, args: []js.Value, exec: *const Execution) !js.Promise {
        return pipeline.createComputePipelineAsync(args, exec);
    }

    pub fn createRenderPipelineAsync(_: *GPUDevice, args: []js.Value, exec: *const Execution) !js.Promise {
        return pipeline.createRenderPipelineAsync(args, exec);
    }

    /// Scopes are counted rather than filled: nothing in this engine raises a
    /// GPUValidationError, so every scope is an empty one -- which is also what
    /// Chrome gives for a scope that saw nothing go wrong (measured). What a
    /// real Chrome would additionally deliver here is the asynchronous half of
    /// WebGPU validation, the errors the create* calls decline to throw: a zero
    /// `usage`, a size past a limit, ill-formed WGSL. Reproducing those means
    /// re-implementing Dawn's validation, not this dispatch, and until someone
    /// does, a page that pushes a scope around a deliberately bad call sees
    /// null where Chrome hands it a GPUValidationError.
    ///
    /// The filter is checked, though, and its message is an argument's rather
    /// than a dictionary member's (measured).
    pub fn pushErrorScope(self: *GPUDevice, filter_: ?js.Value, exec: *const Execution) !void {
        const filter = filter_ orelse return dictionary.throwTypeError(
            "Failed to execute 'pushErrorScope' on 'GPUDevice': 1 argument required, but only 0 present.",
            exec,
        );
        const text = try filter.toStringSlice();
        for (&[_][]const u8{ "validation", "out-of-memory", "internal" }) |candidate| {
            if (std.mem.eql(u8, candidate, text)) {
                self._error_scopes += 1;
                return;
            }
        }
        return dictionary.throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute 'pushErrorScope' on 'GPUDevice': The provided value '{s}' " ++
                "is not a valid enum value of type GPUErrorFilter.",
            .{text},
        ), exec);
    }

    /// One pop too many *rejects* with an OperationError rather than throwing,
    /// and the message is Dawn's own (measured). A destroyed device still keeps
    /// its scopes.
    pub fn popErrorScope(self: *GPUDevice, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (self._error_scopes == 0) {
            var resolver = local.createPromiseResolver();
            resolver.reject("GPUDevice.popErrorScope", DOMException.init(
                "No error scopes to pop",
                "OperationError",
            ));
            return resolver.promise();
        }
        self._error_scopes -= 1;
        return local.resolvePromise(null);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUDevice);

        pub const Meta = struct {
            pub const name = "GPUDevice";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const D = GPUDevice;

        pub const features = bridge.accessor(D.getFeatures, null, .{});
        pub const limits = bridge.accessor(D.getLimits, null, .{});
        pub const adapterInfo = bridge.accessor(D.getAdapterInfo, null, .{});
        pub const lost = bridge.accessor(D.getLost, null, .{});
        pub const queue = bridge.accessor(D.getQueue, null, .{});
        pub const onuncapturederror = bridge.accessor(D.getOnUncapturedError, D.setOnUncapturedError, .{});
        pub const label = bridge.accessor(D.getLabel, D.setLabel, .{});
        pub const createBindGroup = bridge.function(D.createBindGroup, .{ .arity = 1 });
        pub const createBindGroupLayout = bridge.function(D.createBindGroupLayout, .{ .arity = 1 });
        pub const createBuffer = bridge.function(D.createBuffer, .{ .arity = 1 });
        pub const createCommandEncoder = bridge.function(D.createCommandEncoder, .{});
        pub const createComputePipeline = bridge.function(D.createComputePipeline, .{ .arity = 1 });
        pub const createComputePipelineAsync = bridge.function(D.createComputePipelineAsync, .{ .arity = 1 });
        pub const createPipelineLayout = bridge.function(D.createPipelineLayout, .{ .arity = 1 });
        pub const createQuerySet = bridge.function(D.createQuerySet, .{ .arity = 1 });
        pub const createRenderBundleEncoder = bridge.function(D.createRenderBundleEncoder, .{ .arity = 1 });
        pub const createRenderPipeline = bridge.function(D.createRenderPipeline, .{ .arity = 1 });
        pub const createRenderPipelineAsync = bridge.function(D.createRenderPipelineAsync, .{ .arity = 1 });
        pub const createSampler = bridge.function(D.createSampler, .{});
        pub const createShaderModule = bridge.function(D.createShaderModule, .{ .arity = 1 });
        pub const createTexture = bridge.function(D.createTexture, .{ .arity = 1 });
        pub const destroy = bridge.function(D.destroy, .{});
        pub const importExternalTexture = bridge.function(D.importExternalTexture, .{ .arity = 1 });
        pub const popErrorScope = bridge.function(D.popErrorScope, .{});
        pub const pushErrorScope = bridge.function(D.pushErrorScope, .{ .arity = 1 });
    };
};

pub const GPUQueue = struct {
    _label: []const u8 = "",

    pub fn getLabel(self: *const GPUQueue) []const u8 {
        return self._label;
    }

    pub fn setLabel(self: *GPUQueue, value: []const u8, exec: *const Execution) !void {
        self._label = try exec.arena.dupe(u8, value);
    }

    // Nothing is ever submitted, so the recording calls have nothing to do --
    // but they still refuse a call with no arguments the way Chrome does (see
    // resources.Stub).
    pub fn shapeOnly(_: *GPUQueue) void {}

    /// A resolved promise, not undefined (measured: Chrome hands back a
    /// Promise that resolves with undefined). There is no queue to drain.
    pub fn onSubmittedWorkDone(_: *GPUQueue, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUQueue);

        pub const Meta = struct {
            pub const name = "GPUQueue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const Q = GPUQueue;
        const stub = resources.Stub(GPUQueue, "GPUQueue");

        pub const label = bridge.accessor(Q.getLabel, Q.setLabel, .{});
        pub const copyExternalImageToTexture = bridge.function(stub.Arity("copyExternalImageToTexture", 3).call, .{ .arity = 3 });
        pub const onSubmittedWorkDone = bridge.function(Q.onSubmittedWorkDone, .{});
        pub const submit = bridge.function(stub.Arity("submit", 1).call, .{ .arity = 1 });
        pub const writeBuffer = bridge.function(stub.Arity("writeBuffer", 3).call, .{ .arity = 3 });
        pub const writeTexture = bridge.function(stub.Arity("writeTexture", 4).call, .{ .arity = 4 });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU device" {
    try testing.htmlRunner("webgpu/device.html", .{});
}
