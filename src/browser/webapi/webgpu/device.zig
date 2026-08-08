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
// owns. Reachable only through GPUAdapter.requestDevice, which is itself only
// reachable through GPU.requestAdapter, which resolves null: see adapter.zig for
// what that means for this file.
//
// Everything measured on a headed Chrome 150 with
// stealth-detector-probes/win-batch/probe-win38.js: the getter block comes
// before the accessor block and neither is alphabetical, `label` starts empty
// and round-trips a written string, `onuncapturederror` reads back null, and
// `lost` stays pending until destroy() settles it with
// {reason: 'destroyed', message: 'Device was destroyed.'}.

const js = @import("../../js/js.zig");
const adapter = @import("adapter.zig");
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
            ._features = &adapter.GPUSupportedFeatures.device_default,
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

    // A promise that never settles. Chrome settles it when the device is lost or
    // destroyed and hands back the same promise on every read; we have neither a
    // device to lose nor a place to keep the resolver, so each read makes a new
    // pending one. Unobservable while nothing can reach a device.
    pub fn getLost(_: *GPUDevice, exec: *const Execution) !js.Promise {
        var resolver = exec.js.local.?.createPromiseResolver();
        return resolver.promise();
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

    // Everything below is shape only -- the name, the argument count and the
    // position in the prototype. None of it can be called while requestAdapter
    // resolves null, and none of it can be honest before then either: each one
    // owes a GPUBuffer, a GPUTexture or a Promise of a pipeline that we have no
    // backend to produce.
    pub fn shapeOnly(_: *GPUDevice) void {}

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
        pub const createBindGroup = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createBindGroupLayout = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createBuffer = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createCommandEncoder = bridge.function(D.shapeOnly, .{});
        pub const createComputePipeline = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createComputePipelineAsync = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createPipelineLayout = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createQuerySet = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createRenderBundleEncoder = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createRenderPipeline = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createRenderPipelineAsync = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createSampler = bridge.function(D.shapeOnly, .{});
        pub const createShaderModule = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const createTexture = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const destroy = bridge.function(D.shapeOnly, .{});
        pub const importExternalTexture = bridge.function(D.shapeOnly, .{ .arity = 1 });
        pub const popErrorScope = bridge.function(D.shapeOnly, .{});
        pub const pushErrorScope = bridge.function(D.shapeOnly, .{ .arity = 1 });
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

    // Shape only, for the same reason as GPUDevice's methods.
    pub fn shapeOnly(_: *GPUQueue) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUQueue);

        pub const Meta = struct {
            pub const name = "GPUQueue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const Q = GPUQueue;

        pub const label = bridge.accessor(Q.getLabel, Q.setLabel, .{});
        pub const copyExternalImageToTexture = bridge.function(Q.shapeOnly, .{ .arity = 3 });
        pub const onSubmittedWorkDone = bridge.function(Q.shapeOnly, .{});
        pub const submit = bridge.function(Q.shapeOnly, .{ .arity = 1 });
        pub const writeBuffer = bridge.function(Q.shapeOnly, .{ .arity = 3 });
        pub const writeTexture = bridge.function(Q.shapeOnly, .{ .arity = 4 });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU device" {
    try testing.htmlRunner("webgpu/device.html", .{});
}
