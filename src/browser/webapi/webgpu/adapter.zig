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

// The adapter half of the WebGPU family: what `navigator.gpu.requestAdapter()`
// would hand back, and the three read-only descriptions hanging off it.
//
// All of it is reachable: GPU.requestAdapter hands out one of these, the way
// the reference Chrome does on this hardware (see navigator/services.zig).
//
// The values the getters return are not filler: every one was read off a headed
// Chrome 150 on the reference machine (Apple / metal-3) with
// tools/fingerprint/probes/probe-win38.js, whose output is recorded
// in win38-chrome.json. The feature *set* is Chrome's; its iteration order is
// not a fingerprint at all, because Chrome's own order is unstable -- see the
// note on GPUSupportedFeatures.adapter below.
//
// Declaration order inside each JsApi is Chrome's
// `Object.getOwnPropertyNames(X.prototype)` order, not alphabetical.

const std = @import("std");

const js = @import("../../js/js.zig");
const device = @import("device.zig");
const dictionary = @import("../dictionary.zig");
const DOMException = @import("../DOMException.zig");
const Execution = js.Execution;

/// Rejects with the OperationError Chrome gives, message text and all.
fn rejectOperationError(message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("webgpu", DOMException.init(message, "OperationError"));
    return resolver.promise();
}

pub fn registerTypes() []const type {
    return &.{
        GPUAdapter,
        GPUAdapterInfo,
        GPUDeviceLostInfo,
        GPUSupportedFeatures,
        GPUSupportedFeatures.KeyIterator,
        GPUSupportedFeatures.ValueIterator,
        GPUSupportedFeatures.EntryIterator,
        GPUSupportedLimits,
    };
}

/// A readonly setlike of feature-name strings: keys(), values() and the default
/// iterator all yield the entry itself, and entries() yields it twice. Same
/// shape as WGSLLanguageFeatures, but the contents differ between the adapter
/// (23 entries) and the device it hands out (1).
pub const GPUSupportedFeatures = struct {
    _features: []const []const u8,

    /// Chrome's own iteration order is *not* stable everywhere -- Dawn iterates
    /// a hash set -- but it is not free either, and the two halves were measured
    /// apart rather than assumed. Twelve adapters in a row off a headed Chrome
    /// 153 (scratch/s72/expr-gpuidx.js) permute exactly two clusters and pin the
    /// other nineteen positions to one name each:
    ///
    ///   indices 2-3    {texture-formats-tier1, bgra8unorm-storage}
    ///   indices 16-19  {shader-f16, texture-formats-tier2, clip-distances,
    ///                   timestamp-query}
    ///
    /// So a position outside those two clusters IS a reading, and this table had
    /// one wrong: `subgroup-size-control` was appended at the end (index 22)
    /// where Chrome puts it at 11, twelve times out of twelve -- and the
    /// Cloudflare guard serialises this list into its payload verbatim, so the
    /// arm-to-arm diff read it straight off the wire. The order inside a cluster
    /// stays whatever it is; any of Chrome's permutations there is as authentic
    /// as another.
    pub const adapter = [_][]const u8{
        "depth32float-stencil8",
        "rg11b10ufloat-renderable",
        "texture-formats-tier1",
        "bgra8unorm-storage",
        "texture-compression-bc",
        "dual-source-blending",
        "core-features-and-limits",
        "float32-filterable",
        "indirect-first-instance",
        "texture-compression-astc-sliced-3d",
        "float32-blendable",
        "subgroup-size-control",
        "texture-compression-astc",
        "texture-compression-etc2",
        "depth-clip-control",
        "texture-compression-bc-sliced-3d",
        "shader-f16",
        "texture-formats-tier2",
        "clip-distances",
        "timestamp-query",
        "primitive-index",
        "texture-component-swizzle",
        "subgroups",
    };

    // A device only gets the features it was asked for, and a no-argument
    // requestDevice() asks for none; Chrome still adds this one (measured).
    pub const device_default = [_][]const u8{"core-features-and-limits"};

    pub fn getSize(self: *const GPUSupportedFeatures) u32 {
        return @intCast(self._features.len);
    }

    pub fn has(self: *const GPUSupportedFeatures, name: []const u8) bool {
        for (self._features) |feature| {
            if (std.mem.eql(u8, feature, name)) {
                return true;
            }
        }
        return false;
    }

    pub fn keys(self: *GPUSupportedFeatures, exec: *const Execution) !*KeyIterator {
        return .init(.{ .features = self }, exec);
    }

    pub fn values(self: *GPUSupportedFeatures, exec: *const Execution) !*ValueIterator {
        return .init(.{ .features = self }, exec);
    }

    pub fn entries(self: *GPUSupportedFeatures, exec: *const Execution) !*EntryIterator {
        return .init(.{ .features = self }, exec);
    }

    pub fn forEach(self: *GPUSupportedFeatures, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._features) |feature| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ feature, feature, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        features: *GPUSupportedFeatures,

        pub const Entry = struct { []const u8, []const u8 };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const list = self.features._features;
            const index = self.index;
            if (index >= list.len) {
                return null;
            }
            self.index = index + 1;
            return .{ list[index], list[index] };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUSupportedFeatures);

        pub const Meta = struct {
            pub const name = "GPUSupportedFeatures";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const size = bridge.accessor(GPUSupportedFeatures.getSize, null, .{});
        pub const entries = bridge.function(GPUSupportedFeatures.entries, .{});
        pub const forEach = bridge.function(GPUSupportedFeatures.forEach, .{});
        pub const has = bridge.function(GPUSupportedFeatures.has, .{});
        pub const keys = bridge.function(GPUSupportedFeatures.keys, .{});
        pub const values = bridge.function(GPUSupportedFeatures.values, .{});
        pub const symbol_iterator = bridge.iterator(GPUSupportedFeatures.values, .{ .js_name = "values" });
    };
};

/// 36 read-only numbers. The adapter advertises what the hardware can do; the
/// device it hands out gets the smaller default set unless asked otherwise.
pub const GPUSupportedLimits = struct {
    _values: Values,

    pub const Values = struct {
        maxTextureDimension1D: u64,
        maxTextureDimension2D: u64,
        maxTextureDimension3D: u64,
        maxTextureArrayLayers: u64,
        maxBindGroups: u64,
        maxBindGroupsPlusVertexBuffers: u64,
        maxBindingsPerBindGroup: u64,
        maxDynamicUniformBuffersPerPipelineLayout: u64,
        maxDynamicStorageBuffersPerPipelineLayout: u64,
        maxSampledTexturesPerShaderStage: u64,
        maxSamplersPerShaderStage: u64,
        maxStorageBuffersPerShaderStage: u64,
        maxStorageTexturesPerShaderStage: u64,
        maxUniformBuffersPerShaderStage: u64,
        maxUniformBufferBindingSize: u64,
        maxStorageBufferBindingSize: u64,
        minUniformBufferOffsetAlignment: u64,
        minStorageBufferOffsetAlignment: u64,
        maxVertexBuffers: u64,
        maxBufferSize: u64,
        maxVertexAttributes: u64,
        maxVertexBufferArrayStride: u64,
        maxInterStageShaderVariables: u64,
        maxColorAttachments: u64,
        maxColorAttachmentBytesPerSample: u64,
        maxComputeWorkgroupStorageSize: u64,
        maxComputeInvocationsPerWorkgroup: u64,
        maxComputeWorkgroupSizeX: u64,
        maxComputeWorkgroupSizeY: u64,
        maxComputeWorkgroupSizeZ: u64,
        maxComputeWorkgroupsPerDimension: u64,
        maxImmediateSize: u64,
        maxStorageBuffersInFragmentStage: u64,
        maxStorageTexturesInFragmentStage: u64,
        maxStorageBuffersInVertexStage: u64,
        maxStorageTexturesInVertexStage: u64,
    };

    /// The supported value for a limit the page named, or null when the name is
    /// not one of ours -- which Chrome reports as a different error from asking
    /// for too much.
    pub fn lookup(values: *const Values, name: []const u8) ?u64 {
        inline for (comptime @typeInfo(Values).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return @field(values, field.name);
            }
        }
        return null;
    }

    pub const adapter = Values{
        .maxTextureDimension1D = 16384,
        .maxTextureDimension2D = 16384,
        .maxTextureDimension3D = 2048,
        .maxTextureArrayLayers = 2048,
        .maxBindGroups = 4,
        .maxBindGroupsPlusVertexBuffers = 24,
        .maxBindingsPerBindGroup = 1000,
        .maxDynamicUniformBuffersPerPipelineLayout = 10,
        .maxDynamicStorageBuffersPerPipelineLayout = 8,
        .maxSampledTexturesPerShaderStage = 48,
        .maxSamplersPerShaderStage = 16,
        .maxStorageBuffersPerShaderStage = 10,
        .maxStorageTexturesPerShaderStage = 8,
        .maxUniformBuffersPerShaderStage = 12,
        .maxUniformBufferBindingSize = 65536,
        .maxStorageBufferBindingSize = 4294967292,
        .minUniformBufferOffsetAlignment = 256,
        .minStorageBufferOffsetAlignment = 256,
        .maxVertexBuffers = 8,
        .maxBufferSize = 4294967292,
        .maxVertexAttributes = 30,
        .maxVertexBufferArrayStride = 2048,
        .maxInterStageShaderVariables = 28,
        .maxColorAttachments = 8,
        .maxColorAttachmentBytesPerSample = 128,
        .maxComputeWorkgroupStorageSize = 32768,
        .maxComputeInvocationsPerWorkgroup = 1024,
        .maxComputeWorkgroupSizeX = 1024,
        .maxComputeWorkgroupSizeY = 1024,
        .maxComputeWorkgroupSizeZ = 64,
        .maxComputeWorkgroupsPerDimension = 65535,
        .maxImmediateSize = 64,
        .maxStorageBuffersInFragmentStage = 10,
        .maxStorageTexturesInFragmentStage = 8,
        .maxStorageBuffersInVertexStage = 10,
        .maxStorageTexturesInVertexStage = 8,
    };

    pub const device_default = Values{
        .maxTextureDimension1D = 8192,
        .maxTextureDimension2D = 8192,
        .maxTextureDimension3D = 2048,
        .maxTextureArrayLayers = 256,
        .maxBindGroups = 4,
        .maxBindGroupsPlusVertexBuffers = 24,
        .maxBindingsPerBindGroup = 1000,
        .maxDynamicUniformBuffersPerPipelineLayout = 8,
        .maxDynamicStorageBuffersPerPipelineLayout = 4,
        .maxSampledTexturesPerShaderStage = 16,
        .maxSamplersPerShaderStage = 16,
        .maxStorageBuffersPerShaderStage = 8,
        .maxStorageTexturesPerShaderStage = 4,
        .maxUniformBuffersPerShaderStage = 12,
        .maxUniformBufferBindingSize = 65536,
        .maxStorageBufferBindingSize = 134217728,
        .minUniformBufferOffsetAlignment = 256,
        .minStorageBufferOffsetAlignment = 256,
        .maxVertexBuffers = 8,
        .maxBufferSize = 268435456,
        .maxVertexAttributes = 16,
        .maxVertexBufferArrayStride = 2048,
        .maxInterStageShaderVariables = 16,
        .maxColorAttachments = 8,
        .maxColorAttachmentBytesPerSample = 32,
        .maxComputeWorkgroupStorageSize = 16384,
        .maxComputeInvocationsPerWorkgroup = 256,
        .maxComputeWorkgroupSizeX = 256,
        .maxComputeWorkgroupSizeY = 256,
        .maxComputeWorkgroupSizeZ = 64,
        .maxComputeWorkgroupsPerDimension = 65535,
        .maxImmediateSize = 64,
        .maxStorageBuffersInFragmentStage = 8,
        .maxStorageTexturesInFragmentStage = 4,
        .maxStorageBuffersInVertexStage = 8,
        .maxStorageTexturesInVertexStage = 4,
    };

    fn limit(comptime field: []const u8) fn (*const GPUSupportedLimits) u64 {
        return struct {
            fn get(self: *const GPUSupportedLimits) u64 {
                return @field(self._values, field);
            }
        }.get;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUSupportedLimits);

        pub const Meta = struct {
            pub const name = "GPUSupportedLimits";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "maxImmediateSize";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const maxTextureDimension1D = bridge.accessor(limit("maxTextureDimension1D"), null, .{});
        pub const maxTextureDimension2D = bridge.accessor(limit("maxTextureDimension2D"), null, .{});
        pub const maxTextureDimension3D = bridge.accessor(limit("maxTextureDimension3D"), null, .{});
        pub const maxTextureArrayLayers = bridge.accessor(limit("maxTextureArrayLayers"), null, .{});
        pub const maxBindGroups = bridge.accessor(limit("maxBindGroups"), null, .{});
        pub const maxBindGroupsPlusVertexBuffers = bridge.accessor(limit("maxBindGroupsPlusVertexBuffers"), null, .{});
        pub const maxBindingsPerBindGroup = bridge.accessor(limit("maxBindingsPerBindGroup"), null, .{});
        pub const maxDynamicUniformBuffersPerPipelineLayout = bridge.accessor(limit("maxDynamicUniformBuffersPerPipelineLayout"), null, .{});
        pub const maxDynamicStorageBuffersPerPipelineLayout = bridge.accessor(limit("maxDynamicStorageBuffersPerPipelineLayout"), null, .{});
        pub const maxSampledTexturesPerShaderStage = bridge.accessor(limit("maxSampledTexturesPerShaderStage"), null, .{});
        pub const maxSamplersPerShaderStage = bridge.accessor(limit("maxSamplersPerShaderStage"), null, .{});
        pub const maxStorageBuffersPerShaderStage = bridge.accessor(limit("maxStorageBuffersPerShaderStage"), null, .{});
        pub const maxStorageTexturesPerShaderStage = bridge.accessor(limit("maxStorageTexturesPerShaderStage"), null, .{});
        pub const maxUniformBuffersPerShaderStage = bridge.accessor(limit("maxUniformBuffersPerShaderStage"), null, .{});
        pub const maxUniformBufferBindingSize = bridge.accessor(limit("maxUniformBufferBindingSize"), null, .{});
        pub const maxStorageBufferBindingSize = bridge.accessor(limit("maxStorageBufferBindingSize"), null, .{});
        pub const minUniformBufferOffsetAlignment = bridge.accessor(limit("minUniformBufferOffsetAlignment"), null, .{});
        pub const minStorageBufferOffsetAlignment = bridge.accessor(limit("minStorageBufferOffsetAlignment"), null, .{});
        pub const maxVertexBuffers = bridge.accessor(limit("maxVertexBuffers"), null, .{});
        pub const maxBufferSize = bridge.accessor(limit("maxBufferSize"), null, .{});
        pub const maxVertexAttributes = bridge.accessor(limit("maxVertexAttributes"), null, .{});
        pub const maxVertexBufferArrayStride = bridge.accessor(limit("maxVertexBufferArrayStride"), null, .{});
        pub const maxInterStageShaderVariables = bridge.accessor(limit("maxInterStageShaderVariables"), null, .{});
        pub const maxColorAttachments = bridge.accessor(limit("maxColorAttachments"), null, .{});
        pub const maxColorAttachmentBytesPerSample = bridge.accessor(limit("maxColorAttachmentBytesPerSample"), null, .{});
        pub const maxComputeWorkgroupStorageSize = bridge.accessor(limit("maxComputeWorkgroupStorageSize"), null, .{});
        pub const maxComputeInvocationsPerWorkgroup = bridge.accessor(limit("maxComputeInvocationsPerWorkgroup"), null, .{});
        pub const maxComputeWorkgroupSizeX = bridge.accessor(limit("maxComputeWorkgroupSizeX"), null, .{});
        pub const maxComputeWorkgroupSizeY = bridge.accessor(limit("maxComputeWorkgroupSizeY"), null, .{});
        pub const maxComputeWorkgroupSizeZ = bridge.accessor(limit("maxComputeWorkgroupSizeZ"), null, .{});
        pub const maxComputeWorkgroupsPerDimension = bridge.accessor(limit("maxComputeWorkgroupsPerDimension"), null, .{});
        pub const maxImmediateSize = bridge.accessor(limit("maxImmediateSize"), null, .{});
        pub const maxStorageBuffersInFragmentStage = bridge.accessor(limit("maxStorageBuffersInFragmentStage"), null, .{});
        pub const maxStorageTexturesInFragmentStage = bridge.accessor(limit("maxStorageTexturesInFragmentStage"), null, .{});
        pub const maxStorageBuffersInVertexStage = bridge.accessor(limit("maxStorageBuffersInVertexStage"), null, .{});
        pub const maxStorageTexturesInVertexStage = bridge.accessor(limit("maxStorageTexturesInVertexStage"), null, .{});
    };
};

/// What used to be `adapter.requestAdapterInfo()` and is now the `info`
/// property. Chrome hands the device its own copy rather than the adapter's
/// object (measured: `device.adapterInfo !== adapter.info`).
pub const GPUAdapterInfo = struct {
    _vendor: []const u8 = "apple",
    _architecture: []const u8 = "metal-3",
    _device: []const u8 = "",
    _description: []const u8 = "",
    _subgroup_min_size: u32 = 32,
    _subgroup_max_size: u32 = 32,
    _is_fallback_adapter: bool = false,

    pub fn getVendor(self: *const GPUAdapterInfo) []const u8 {
        return self._vendor;
    }

    pub fn getArchitecture(self: *const GPUAdapterInfo) []const u8 {
        return self._architecture;
    }

    pub fn getDevice(self: *const GPUAdapterInfo) []const u8 {
        return self._device;
    }

    pub fn getDescription(self: *const GPUAdapterInfo) []const u8 {
        return self._description;
    }

    pub fn getSubgroupMinSize(self: *const GPUAdapterInfo) u32 {
        return self._subgroup_min_size;
    }

    pub fn getSubgroupMaxSize(self: *const GPUAdapterInfo) u32 {
        return self._subgroup_max_size;
    }

    pub fn getIsFallbackAdapter(self: *const GPUAdapterInfo) bool {
        return self._is_fallback_adapter;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUAdapterInfo);

        pub const Meta = struct {
            pub const name = "GPUAdapterInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const vendor = bridge.accessor(GPUAdapterInfo.getVendor, null, .{});
        pub const architecture = bridge.accessor(GPUAdapterInfo.getArchitecture, null, .{});
        pub const device = bridge.accessor(GPUAdapterInfo.getDevice, null, .{});
        pub const description = bridge.accessor(GPUAdapterInfo.getDescription, null, .{});
        pub const subgroupMinSize = bridge.accessor(GPUAdapterInfo.getSubgroupMinSize, null, .{});
        pub const subgroupMaxSize = bridge.accessor(GPUAdapterInfo.getSubgroupMaxSize, null, .{});
        pub const isFallbackAdapter = bridge.accessor(GPUAdapterInfo.getIsFallbackAdapter, null, .{});
    };
};

/// `adapter.isFallbackAdapter` is gone in Chrome 150 -- it moved onto
/// GPUAdapterInfo (measured: `'isFallbackAdapter' in adapter` is false).
pub const GPUAdapter = struct {
    // Allocated on first read rather than embedded: the JS identity map is
    // keyed by Zig address alone, and a struct's first-in-memory field shares
    // its owner's address -- an embedded instance would come back branded as
    // its owner. Each is stable once created, which is what Chrome does
    // (measured: `adapter.features === adapter.features`).
    _features: ?*GPUSupportedFeatures = null,
    _limits: ?*GPUSupportedLimits = null,
    _info: ?*GPUAdapterInfo = null,
    // An adapter is single use: once it has produced a device, every later
    // requestDevice rejects (measured -- this is not in the spec's prose).
    _consumed: bool = false,

    const AdapterOptions = dictionary.MethodReader("GPU", "requestAdapter", "GPURequestAdapterOptions");
    const DeviceDescriptor = dictionary.MethodReader("GPUAdapter", "requestDevice", "GPUDeviceDescriptor");

    const CONSUMED =
        "Failed to execute 'requestDevice' on 'GPUAdapter': adapter is \"consumed\": " ++
        "it has already been used to create a device\n" ++
        "    at CreateDeviceInternal (../../third_party/dawn/src/dawn/native/Adapter.cpp:328)\n";

    /// The body of `navigator.gpu.requestAdapter(options)`. A *fresh* adapter
    /// every call (measured: two calls give two objects), or null when the page
    /// insists on a fallback adapter -- there isn't one here, and Chrome does not
    /// substitute the real one for it.
    pub fn request(options_: ?js.Value, exec: *const Execution) !js.Promise {
        const options = try AdapterOptions.read(options_, exec);
        // Read for its side effect only: an unrecognised value is a TypeError,
        // and which adapter we hand back does not otherwise depend on it.
        _ = try options.enumMember(
            "powerPreference",
            "GPUPowerPreference",
            &.{ "low-power", "high-performance" },
            null,
            exec,
        );
        const local = exec.js.local.?;
        if (try options.boolean("forceFallbackAdapter", false)) {
            return local.resolvePromise(null);
        }
        return local.resolvePromise(try exec._factory.create(GPUAdapter{}));
    }

    pub fn getFeatures(self: *GPUAdapter, exec: *const Execution) !*GPUSupportedFeatures {
        if (self._features) |features| {
            return features;
        }
        const created = try exec._factory.create(GPUSupportedFeatures{ ._features = &GPUSupportedFeatures.adapter });
        self._features = created;
        return created;
    }

    pub fn getLimits(self: *GPUAdapter, exec: *const Execution) !*GPUSupportedLimits {
        if (self._limits) |limits| {
            return limits;
        }
        const created = try exec._factory.create(GPUSupportedLimits{ ._values = GPUSupportedLimits.adapter });
        self._limits = created;
        return created;
    }

    pub fn getInfo(self: *GPUAdapter, exec: *const Execution) !*GPUAdapterInfo {
        if (self._info) |info| {
            return info;
        }
        const created = try exec._factory.create(GPUAdapterInfo{});
        self._info = created;
        return created;
    }

    pub fn requestDevice(self: *GPUAdapter, descriptor_: ?js.Value, exec: *const Execution) !js.Promise {
        if (self._consumed) {
            return rejectOperationError(CONSUMED, exec);
        }

        const descriptor = try DeviceDescriptor.read(descriptor_, exec);
        const label = try descriptor.string("label", "", exec.arena);
        const features = try readRequiredFeatures(descriptor, exec);
        if (try checkRequiredLimits(descriptor, exec)) |failure| {
            return rejectOperationError(failure, exec);
        }

        self._consumed = true;
        const created = try exec._factory.eventTarget(device.GPUDevice{
            ._proto = undefined,
            ._label = label,
            ._feature_names = features,
        });
        return exec.js.local.?.resolvePromise(created);
    }

    /// requiredFeatures is validated against the adapter's own set, and the
    /// accepted names are appended *after* the device's default one, in the order
    /// the page listed them (measured: asking for shader-f16 gives
    /// 'core-features-and-limits,shader-f16').
    fn readRequiredFeatures(descriptor: DeviceDescriptor, exec: *const Execution) ![]const []const u8 {
        const default = &GPUSupportedFeatures.device_default;
        const member = (try descriptor.present("requiredFeatures")) orelse return default;
        if (!member.isArray()) {
            return DeviceDescriptor.notASequence("requiredFeatures", exec);
        }
        const array = member.toArray();
        const len = array.len();

        const names = try exec.arena.alloc([]const u8, default.len + len);
        @memcpy(names[0..default.len], default);
        var count: usize = default.len;

        for (0..len) |i| {
            const entry = try array.get(@intCast(i));
            const text = try entry.toStringSlice();
            const known = blk: {
                for (GPUSupportedFeatures.adapter) |candidate| {
                    if (std.mem.eql(u8, candidate, text)) break :blk candidate;
                }
                return dictionary.throwTypeError(try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to execute 'requestDevice' on 'GPUAdapter': Failed to read the " ++
                        "'requiredFeatures' property from 'GPUDeviceDescriptor': The provided value " ++
                        "'{s}' is not a valid enum value of type GPUFeatureName.",
                    .{text},
                ), exec);
            };
            if (std.mem.eql(u8, known, default[0])) {
                continue;
            }
            names[count] = known;
            count += 1;
        }
        return names[0..count];
    }

    /// requiredLimits is checked but never stored: a device that asked for more
    /// still reports the default set (measured), so the only observable outcomes
    /// are the two OperationError messages below.
    fn checkRequiredLimits(descriptor: DeviceDescriptor, exec: *const Execution) !?[]const u8 {
        const member = (try descriptor.present("requiredLimits")) orelse return null;
        if (!member.isObject()) {
            return null;
        }
        const object = member.toObject();
        const names = try object.getOwnPropertyNames();
        for (0..names.len()) |i| {
            const key = try (try names.get(@intCast(i))).toStringSlice();
            const entry = try object.get(key);
            if (entry.isUndefined()) {
                continue;
            }
            const supported = GPUSupportedLimits.lookup(&GPUSupportedLimits.adapter, key) orelse {
                return try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to execute 'requestDevice' on 'GPUAdapter': The limit \"{s}\" with a " ++
                        "non-undefined value is not recognized.",
                    .{key},
                );
            };
            const wanted = entry.toF64() catch continue;
            if (wanted > @as(f64, @floatFromInt(supported))) {
                return try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to execute 'requestDevice' on 'GPUAdapter': Required limit ({d}) is " ++
                        "greater than the supported limit ({d}).\n - While validating {s}\n" ++
                        " - While validating required limits\n",
                    .{ @as(u64, @intFromFloat(wanted)), supported, key },
                );
            }
        }
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUAdapter);

        pub const Meta = struct {
            pub const name = "GPUAdapter";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const features = bridge.accessor(GPUAdapter.getFeatures, null, .{});
        pub const limits = bridge.accessor(GPUAdapter.getLimits, null, .{});
        pub const info = bridge.accessor(GPUAdapter.getInfo, null, .{});
        pub const requestDevice = bridge.function(GPUAdapter.requestDevice, .{});
    };
};

/// What `device.lost` resolves with. Measured after `device.destroy()`:
/// `{reason: 'destroyed', message: 'Device was destroyed.'}`.
pub const GPUDeviceLostInfo = struct {
    _reason: []const u8 = "destroyed",
    _message: []const u8 = "Device was destroyed.",

    pub fn getReason(self: *const GPUDeviceLostInfo) []const u8 {
        return self._reason;
    }

    pub fn getMessage(self: *const GPUDeviceLostInfo) []const u8 {
        return self._message;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUDeviceLostInfo);

        pub const Meta = struct {
            pub const name = "GPUDeviceLostInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const reason = bridge.accessor(GPUDeviceLostInfo.getReason, null, .{});
        pub const message = bridge.accessor(GPUDeviceLostInfo.getMessage, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU adapter" {
    try testing.htmlRunner("webgpu/adapter.html", .{});
}
