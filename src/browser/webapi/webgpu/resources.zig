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

// The nine things a GPUDevice allocates: buffers, textures and the handles that
// name parts of them. Each one is reachable -- `device.create*` builds it and
// the descriptor it was given decides what it reports back.
//
// Shapes, arities and member order are Chrome 150's, read with
// tools/fingerprint/probes/probe-win37.js. The order is not
// alphabetical and in GPUTexture's case not even grouped: Chrome carries
// `get textureBindingViewDimension` *after* createView and destroy, and that is
// how it is written here.
//
// The defaults and the refusals came off the same Chrome with probe-win39.js
// (win39-chrome.json): a texture asked for `size: [8]` reports height 1 and
// depthOrArrayLayers 1, mipLevelCount and sampleCount default to 1, dimension to
// '2d', and every required member missing gives its own TypeError. Nothing here
// is a spec reading.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const Video = @import("../element/html/Video.zig");
const VideoFrame = @import("../webcodecs/frames.zig").VideoFrame;
const Execution = js.Execution;

/// The 42 GPUTextureFormat values a *core* device accepts. Chrome gates the enum
/// itself on the device's enabled features: on a device with only
/// core-features-and-limits, the bc / etc2 / astc / *16unorm families and
/// depth32float-stencil8 are rejected as invalid enum values rather than as
/// validation errors (measured -- 42 of the spec's 101 candidates were accepted,
/// see win39b-formats-chrome.json). Only core formats are listed because only a
/// core device is reachable here.
pub const core_texture_formats = [_][]const u8{
    "r8unorm",              "r8snorm",      "r8uint",          "r8sint",
    "r16uint",              "r16sint",      "r16float",        "rg8unorm",
    "rg8snorm",             "rg8uint",      "rg8sint",         "r32uint",
    "r32sint",              "r32float",     "rg16uint",        "rg16sint",
    "rg16float",            "rgba8unorm",   "rgba8unorm-srgb", "rgba8snorm",
    "rgba8uint",            "rgba8sint",    "bgra8unorm",      "bgra8unorm-srgb",
    "rgb9e5ufloat",         "rgb10a2uint",  "rgb10a2unorm",    "rg11b10ufloat",
    "rg32uint",             "rg32sint",     "rg32float",       "rgba16uint",
    "rgba16sint",           "rgba16float",  "rgba32uint",      "rgba32sint",
    "rgba32float",          "stencil8",     "depth16unorm",    "depth24plus",
    "depth24plus-stencil8", "depth32float",
};

/// Chrome checks the argument count before it looks at the descriptor, so
/// `device.createBuffer()` and `device.createBuffer(undefined)` fail
/// differently: the first is an arity error, and the second gets as far as the
/// conversion and is refused there (measured -- `Reader.readRequired` is the
/// other half of that pair). The bridge only counts arguments for constructors,
/// so a method that needs this has to take `args: []js.Value` and say its arity
/// in its JsApi entry.
pub fn requireArgument(
    comptime interface: []const u8,
    comptime method: []const u8,
    args: []js.Value,
    exec: *const Execution,
) !js.Value {
    if (args.len == 0) {
        return dictionary.throwTypeError(
            "Failed to execute '" ++ method ++ "' on '" ++ interface ++
                "': 1 argument required, but only 0 present.",
            exec,
        );
    }
    return args[0];
}

fn requireDescriptor(
    comptime method: []const u8,
    args: []js.Value,
    exec: *const Execution,
) !js.Value {
    return requireArgument("GPUDevice", method, args, exec);
}

/// The recording calls: the ones that only exist to be called, because nothing
/// is executed behind them. They still have to *refuse* the way Chrome does --
/// every WebGPU method whose length is not zero throws when it is called with
/// nothing, and answering undefined instead is the kind of difference a
/// detector can read with a bare `try { pass.setPipeline() }` (measured across
/// all fifty-odd of them, win42-chrome.json).
///
/// Chrome's own message counts what was actually passed, so the count is
/// runtime and only the rest of the sentence is comptime.
pub fn Stub(comptime T: type, comptime interface: []const u8) type {
    return struct {
        pub fn Arity(comptime method: []const u8, comptime required: usize) type {
            return struct {
                const PREFIX = "Failed to execute '" ++ method ++ "' on '" ++ interface ++ "': " ++
                    std.fmt.comptimePrint("{d}", .{required}) ++
                    (if (required == 1) " argument required" else " arguments required") ++
                    ", but only ";

                pub fn call(_: *T, args: []js.Value, exec: *const Execution) !void {
                    if (args.len >= required) {
                        return;
                    }
                    return dictionary.throwTypeError(try std.fmt.allocPrint(
                        exec.call_arena,
                        PREFIX ++ "{d} present.",
                        .{args.len},
                    ), exec);
                }
            };
        }
    };
}

/// WebIDL `unsigned long long` / `GPUSize64`, which is what the size-ish members
/// are. Read through a double because that is what a JS number is.
fn unsignedMember(
    comptime Reader: type,
    reader: Reader,
    comptime name: []const u8,
    exec: *const Execution,
) !u64 {
    const member = try reader.required(name, exec);
    const number = member.toF64() catch 0;
    if (!(number > 0)) {
        return 0;
    }
    return @intFromFloat(number);
}

const throwDom = dictionary.throwDom;

pub fn registerTypes() []const type {
    return &.{
        GPUBindGroup,
        GPUBindGroupLayout,
        GPUBuffer,
        GPUExternalTexture,
        GPUPipelineLayout,
        GPUQuerySet,
        GPUSampler,
        GPUTexture,
        GPUTextureView,
    };
}

// `label` is the one member almost every GPU object has, and it is read/write
// everywhere (measured: `accessor label[ec-]`, and a written string reads back).
pub fn labelAccessors(comptime T: type) type {
    return struct {
        pub fn get(self: *const T) []const u8 {
            return self._label;
        }

        pub fn set(self: *T, value: []const u8, exec: *const Execution) !void {
            self._label = try exec.arena.dupe(u8, value);
        }
    };
}

pub const GPUBuffer = struct {
    _label: []const u8 = "",
    _size: u64,
    _usage: u32,
    // The state a freshly created, unmapped buffer reports (measured).
    _map_state: []const u8 = "unmapped",
    // The intervals getMappedRange() has handed out for the current mapping.
    // Chrome refuses a second range overlapping any of them and names both
    // intervals in the message; unmap() clears the list.
    _ranges: std.ArrayList(Range) = .empty,

    const Range = struct { start: u64, end: u64 };

    const label_accessors = labelAccessors(GPUBuffer);

    pub fn getSize(self: *const GPUBuffer) u64 {
        return self._size;
    }

    pub fn getUsage(self: *const GPUBuffer) u32 {
        return self._usage;
    }

    pub fn getMapState(self: *const GPUBuffer) []const u8 {
        return self._map_state;
    }

    // Shape only: there is no allocation behind the handle to destroy or hand
    // back an ArrayBuffer for.
    pub fn shapeOnly(_: *GPUBuffer) void {}

    const map_range_failed =
        "Failed to execute 'getMappedRange' on 'GPUBuffer': getMappedRange failed";

    /// The bytes behind a mapped buffer. Measured on Chrome 151
    /// (probes/expr-gpu-mapped-range.js): a mapped buffer answers an
    /// ArrayBuffer of the requested interval, all zero on a buffer nothing has
    /// been copied into; an offset on its own takes the rest; an unmapped
    /// buffer, an unaligned offset and an interval past the end all throw
    /// OperationError with the plain message; and a second range overlapping
    /// one already handed out throws with both intervals named.
    ///
    /// This is the one structural gap in the Cloudflare widget's payload B60
    /// could attribute: the widget runs a WebGPU pipeline and encodes 4096
    /// bytes out of the buffer it reads back, and answering undefined meant
    /// that segment was simply missing from ours.
    ///
    /// Not reproduced: unmap() detaches the ranges in Chrome, so their
    /// byteLength reads 0 afterwards. There is no detach in the V8 binding
    /// here, so a range handed out before unmap() keeps its bytes.
    pub fn getMappedRange(self: *GPUBuffer, args: []js.Value, exec: *const Execution) !js.ArrayBuffer {
        if (!std.mem.eql(u8, self._map_state, "mapped")) {
            return throwDom("OperationError", map_range_failed, exec);
        }

        const offset = argumentSize(args, 0) orelse 0;
        const size = argumentSize(args, 1) orelse (if (offset > self._size) 0 else self._size - offset);
        const end = offset + size;
        // The alignment WebGPU requires of the pair, and the buffer's own end.
        if (offset % 8 != 0 or size % 4 != 0 or end > self._size or offset > self._size) {
            return throwDom("OperationError", map_range_failed, exec);
        }

        for (self._ranges.items) |taken| {
            if (offset < taken.end and taken.start < end) {
                return throwDom("OperationError", try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to execute 'getMappedRange' on 'GPUBuffer': getMappedRange " ++
                        "[{d}, {d}) overlaps with previously returned range [{d}, {d}).",
                    .{ offset, end, taken.start, taken.end },
                ), exec);
            }
        }
        try self._ranges.append(exec.arena, .{ .start = offset, .end = end });

        const bytes = try exec.call_arena.alloc(u8, @intCast(size));
        @memset(bytes, 0);
        return .{ .values = bytes };
    }

    /// A `GPUSize64` argument, or null when it was left out. Anything that is
    /// not a number reads as 0, which is what the WebIDL conversion of a
    /// missing-but-present value comes to here.
    fn argumentSize(args: []js.Value, index: usize) ?u64 {
        if (index >= args.len or args[index].isUndefined()) {
            return null;
        }
        const number = args[index].toF64() catch return 0;
        if (!(number > 0)) {
            return 0;
        }
        return @intFromFloat(number);
    }

    /// A promise, not a throw, when the argument is missing -- WebIDL turns a
    /// promise-returning operation's conversion errors into rejections
    /// (measured). What is not reproduced is the usage check: Chrome rejects a
    /// buffer whose usage lacks MAP_READ / MAP_WRITE with an OperationError
    /// naming the usages it does have, and there is no usage bookkeeping here
    /// to name them from.
    ///
    /// Chrome reports 'pending' between the call and the GPU finishing; this
    /// map completes at once, so 'pending' is never observable.
    pub fn mapAsync(self: *GPUBuffer, args: []js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (args.len == 0) {
            var resolver = local.createPromiseResolver();
            resolver.rejectError("GPUBuffer.mapAsync", .{
                .type_error = "Failed to execute 'mapAsync' on 'GPUBuffer': 1 argument required, but only 0 present.",
            });
            return resolver.promise();
        }
        self._map_state = "mapped";
        self._ranges = .empty;
        return local.resolvePromise({});
    }

    /// Back to 'unmapped' (measured on a mappedAtCreation buffer), and the
    /// ranges handed out for that mapping are forgotten, so the next mapping
    /// can hand out the same interval again.
    pub fn unmap(self: *GPUBuffer) void {
        self._map_state = "unmapped";
        self._ranges = .empty;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUBuffer);

        pub const Meta = struct {
            pub const name = "GPUBuffer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const size = bridge.accessor(GPUBuffer.getSize, null, .{});
        pub const usage = bridge.accessor(GPUBuffer.getUsage, null, .{});
        pub const mapState = bridge.accessor(GPUBuffer.getMapState, null, .{});
        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const destroy = bridge.function(GPUBuffer.shapeOnly, .{});
        pub const getMappedRange = bridge.function(GPUBuffer.getMappedRange, .{ .arity = 0 });
        pub const mapAsync = bridge.function(GPUBuffer.mapAsync, .{ .arity = 1 });
        pub const unmap = bridge.function(GPUBuffer.unmap, .{});
    };
};

pub const GPUTexture = struct {
    _label: []const u8 = "",
    _width: u32,
    _height: u32,
    _depth_or_array_layers: u32,
    _mip_level_count: u32,
    _sample_count: u32,
    _dimension: []const u8,
    _format: []const u8,
    _usage: u32,
    _texture_binding_view_dimension: ?[]const u8 = null,

    const label_accessors = labelAccessors(GPUTexture);

    pub fn getWidth(self: *const GPUTexture) u32 {
        return self._width;
    }

    pub fn getHeight(self: *const GPUTexture) u32 {
        return self._height;
    }

    pub fn getDepthOrArrayLayers(self: *const GPUTexture) u32 {
        return self._depth_or_array_layers;
    }

    pub fn getMipLevelCount(self: *const GPUTexture) u32 {
        return self._mip_level_count;
    }

    pub fn getSampleCount(self: *const GPUTexture) u32 {
        return self._sample_count;
    }

    pub fn getDimension(self: *const GPUTexture) []const u8 {
        return self._dimension;
    }

    pub fn getFormat(self: *const GPUTexture) []const u8 {
        return self._format;
    }

    pub fn getUsage(self: *const GPUTexture) u32 {
        return self._usage;
    }

    /// Undefined unless the descriptor named one -- the getter exists on every
    /// texture but reads back undefined on one created without it (measured on
    /// five differently-shaped textures).
    pub fn getTextureBindingViewDimension(self: *const GPUTexture) ?[]const u8 {
        return self._texture_binding_view_dimension;
    }

    pub fn createView(_: *GPUTexture, descriptor_: ?js.Value, exec: *const Execution) !*GPUTextureView {
        const Reader = dictionary.MethodReader("GPUTexture", "createView", "GPUTextureViewDescriptor");
        const descriptor = try Reader.read(descriptor_, exec);
        return exec._factory.create(GPUTextureView{
            ._label = try descriptor.string("label", "", exec.arena),
        });
    }

    // Nothing backs the handle, so there is no allocation to release.
    pub fn shapeOnly(_: *GPUTexture) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUTexture);

        pub const Meta = struct {
            pub const name = "GPUTexture";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "destroy";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const width = bridge.accessor(GPUTexture.getWidth, null, .{});
        pub const height = bridge.accessor(GPUTexture.getHeight, null, .{});
        pub const depthOrArrayLayers = bridge.accessor(GPUTexture.getDepthOrArrayLayers, null, .{});
        pub const mipLevelCount = bridge.accessor(GPUTexture.getMipLevelCount, null, .{});
        pub const sampleCount = bridge.accessor(GPUTexture.getSampleCount, null, .{});
        pub const dimension = bridge.accessor(GPUTexture.getDimension, null, .{});
        pub const format = bridge.accessor(GPUTexture.getFormat, null, .{});
        pub const usage = bridge.accessor(GPUTexture.getUsage, null, .{});
        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const createView = bridge.function(GPUTexture.createView, .{});
        pub const destroy = bridge.function(GPUTexture.shapeOnly, .{});
        // Absent reads back as undefined, not null (measured on five textures).
        pub const textureBindingViewDimension = bridge.accessor(GPUTexture.getTextureBindingViewDimension, null, .{ .null_as_undefined = true });
    };
};

pub const GPUQuerySet = struct {
    _label: []const u8 = "",
    _type: []const u8,
    _count: u32,

    const label_accessors = labelAccessors(GPUQuerySet);

    pub fn getType(self: *const GPUQuerySet) []const u8 {
        return self._type;
    }

    pub fn getCount(self: *const GPUQuerySet) u32 {
        return self._count;
    }

    pub fn shapeOnly(_: *GPUQuerySet) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUQuerySet);

        pub const Meta = struct {
            pub const name = "GPUQuerySet";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(GPUQuerySet.getType, null, .{});
        pub const count = bridge.accessor(GPUQuerySet.getCount, null, .{});
        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const destroy = bridge.function(GPUQuerySet.shapeOnly, .{});
    };
};

// ---------------------------------------------------------------------------
// The device.create* bodies. They live here rather than in device.zig because
// each one is really "make one of these", and the messages name the method so
// they stay comptime strings.
//
// Chrome's validation is split: a missing or ill-typed *descriptor member* is a
// synchronous TypeError, while a value that is well-formed but wrong (a zero
// usage, a size the device cannot afford) is an asynchronous GPUValidationError
// delivered through an error scope. Only the first kind is reproduced here; the
// error-scope half needs the GPUError family, which is P6 of this batch.
// ---------------------------------------------------------------------------

pub fn createBuffer(args: []js.Value, exec: *const Execution) !*GPUBuffer {
    const Reader = dictionary.MethodReader("GPUDevice", "createBuffer", "GPUBufferDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("createBuffer", args, exec), exec);

    const size = try unsignedMember(Reader, descriptor, "size", exec);
    const usage = try unsignedMember(Reader, descriptor, "usage", exec);
    const mapped = try descriptor.boolean("mappedAtCreation", false);

    return exec._factory.create(GPUBuffer{
        ._label = try descriptor.string("label", "", exec.arena),
        ._size = size,
        ._usage = @truncate(usage),
        // mappedAtCreation hands back an already-mapped buffer (measured).
        ._map_state = if (mapped) "mapped" else "unmapped",
    });
}

pub fn createTexture(args: []js.Value, exec: *const Execution) !*GPUTexture {
    const Reader = dictionary.MethodReader("GPUDevice", "createTexture", "GPUTextureDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("createTexture", args, exec), exec);

    const extent = try readExtent3D(Reader, descriptor, exec);
    const format = try descriptor.requiredEnum("format", "GPUTextureFormat", &core_texture_formats, exec);
    const usage = try unsignedMember(Reader, descriptor, "usage", exec);
    const dimension = (try descriptor.enumMember(
        "dimension",
        "GPUTextureDimension",
        &.{ "1d", "2d", "3d" },
        "2d",
        exec,
    )).?;

    return exec._factory.create(GPUTexture{
        ._label = try descriptor.string("label", "", exec.arena),
        ._width = extent[0],
        ._height = extent[1],
        ._depth_or_array_layers = extent[2],
        // Both default to 1 (measured on a texture that asked for neither).
        ._mip_level_count = @intCast(@max(1, try descriptor.long("mipLevelCount", 1))),
        ._sample_count = @intCast(@max(1, try descriptor.long("sampleCount", 1))),
        ._dimension = dimension,
        ._format = format,
        ._usage = @truncate(usage),
    });
}

/// GPUExtent3D is a union: a sequence of up to three numbers, or a dictionary.
/// The missing members default to 1, not 0 (measured: `size: [8]` gives
/// height 1 and depthOrArrayLayers 1).
fn readExtent3D(
    comptime Reader: type,
    descriptor: Reader,
    exec: *const Execution,
) ![3]u32 {
    const member = try descriptor.required("size", exec);
    var extent: [3]u32 = .{ 0, 1, 1 };

    if (member.isArray()) {
        const array = member.toArray();
        const len = @min(array.len(), 3);
        for (0..len) |i| {
            const entry = try array.get(@intCast(i));
            const number = entry.toF64() catch 0;
            extent[i] = if (number > 0) @intFromFloat(number) else 0;
        }
        return extent;
    }

    if (!member.isObject()) {
        return Reader.convertFailed("size", "GPUExtent3D", exec);
    }
    const object = member.toObject();
    inline for (.{ "width", "height", "depthOrArrayLayers" }, 0..) |name, i| {
        const entry = try object.get(name);
        if (!entry.isUndefined()) {
            const number = entry.toF64() catch 0;
            extent[i] = if (number > 0) @intFromFloat(number) else 0;
        }
    }
    return extent;
}

pub fn createQuerySet(args: []js.Value, exec: *const Execution) !*GPUQuerySet {
    const Reader = dictionary.MethodReader("GPUDevice", "createQuerySet", "GPUQuerySetDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("createQuerySet", args, exec), exec);

    const kind = try descriptor.requiredEnum("type", "GPUQueryType", &.{ "occlusion", "timestamp" }, exec);
    const count = try unsignedMember(Reader, descriptor, "count", exec);

    return exec._factory.create(GPUQuerySet{
        ._label = try descriptor.string("label", "", exec.arena),
        ._type = kind,
        ._count = @truncate(count),
    });
}

/// createSampler takes an optional descriptor, so there is no arity check
/// (measured: `createSampler.length` is 0 and a bare call succeeds).
pub fn createSampler(descriptor_: ?js.Value, exec: *const Execution) !*GPUSampler {
    const Reader = dictionary.MethodReader("GPUDevice", "createSampler", "GPUSamplerDescriptor");
    const descriptor = try Reader.read(descriptor_, exec);
    return exec._factory.create(GPUSampler{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

pub fn createBindGroupLayout(args: []js.Value, exec: *const Execution) !*GPUBindGroupLayout {
    const Reader = dictionary.MethodReader("GPUDevice", "createBindGroupLayout", "GPUBindGroupLayoutDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("createBindGroupLayout", args, exec), exec);
    const entries = try descriptor.required("entries", exec);
    if (!entries.isArray()) {
        return Reader.notASequence("entries", exec);
    }
    return exec._factory.create(GPUBindGroupLayout{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

pub fn createPipelineLayout(args: []js.Value, exec: *const Execution) !*GPUPipelineLayout {
    const Reader = dictionary.MethodReader("GPUDevice", "createPipelineLayout", "GPUPipelineLayoutDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("createPipelineLayout", args, exec), exec);
    const layouts = try descriptor.required("bindGroupLayouts", exec);
    if (!layouts.isArray()) {
        return Reader.notASequence("bindGroupLayouts", exec);
    }
    return exec._factory.create(GPUPipelineLayout{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

pub fn createBindGroup(args: []js.Value, exec: *const Execution) !*GPUBindGroup {
    const Reader = dictionary.MethodReader("GPUDevice", "createBindGroup", "GPUBindGroupDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("createBindGroup", args, exec), exec);
    _ = try descriptor.interfaceMember("layout", GPUBindGroupLayout, "GPUBindGroupLayout", exec);
    const entries = try descriptor.required("entries", exec);
    if (!entries.isArray()) {
        return Reader.notASequence("entries", exec);
    }
    return exec._factory.create(GPUBindGroup{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

/// The `source` member is a `(HTMLVideoElement or VideoFrame)` union, and Chrome
/// names the whole union when the conversion fails (measured with `{source: 5}`).
/// Both arms convert; a closed VideoFrame is refused further down in Chrome
/// ("video frame that doesn't have back resource"), which is a validation step
/// this engine has no back resource to make.
pub fn importExternalTexture(args: []js.Value, exec: *const Execution) !*GPUExternalTexture {
    const Reader = dictionary.MethodReader("GPUDevice", "importExternalTexture", "GPUExternalTextureDescriptor");
    const descriptor = try Reader.readRequired(try requireDescriptor("importExternalTexture", args, exec), exec);
    const source = try descriptor.required("source", exec);
    if (source.toZig(*Video)) |_| {} else |_| {
        _ = source.toZig(*VideoFrame) catch {
            return Reader.notOfType("source", "(HTMLVideoElement or VideoFrame)", exec);
        };
    }
    return exec._factory.create(GPUExternalTexture{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

// The five handles whose whole prototype is `label`. They differ only in brand.
pub const GPUTextureView = LabelOnly("GPUTextureView");
pub const GPUSampler = LabelOnly("GPUSampler");
pub const GPUExternalTexture = LabelOnly("GPUExternalTexture");
pub const GPUBindGroup = LabelOnly("GPUBindGroup");
pub const GPUBindGroupLayout = LabelOnly("GPUBindGroupLayout");
pub const GPUPipelineLayout = LabelOnly("GPUPipelineLayout");

pub fn LabelOnly(comptime type_name: []const u8) type {
    return struct {
        const Self = @This();

        _label: []const u8 = "",

        pub fn getLabel(self: *const Self) []const u8 {
            return self._label;
        }

        pub fn setLabel(self: *Self, value: []const u8, exec: *const Execution) !void {
            self._label = try exec.arena.dupe(u8, value);
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = type_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const label = bridge.accessor(Self.getLabel, Self.setLabel, .{});
        };
    };
}

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU resources" {
    try testing.htmlRunner("webgpu/resources.html", .{});
}
