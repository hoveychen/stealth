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

// The working half of WebGPU: shader modules, the two pipelines, the encoders
// that record commands, and the canvas context that would present them.
// Everything a page reaches through `device.create*` once it has a device.
//
// Shapes, arities and member order are Chrome 150's, read with
// tools/fingerprint/probes/probe-win37.js. The order is not
// alphabetical, and GPUCommandEncoder's is not even one run of it: the methods
// restart at `clearBuffer` after `pushDebugGroup`, and that is how it is written
// here.
//
// The behaviours came off the same Chrome with probe-win40.js, -win40b and
// -win40c (win40-chrome.json, win40b-chrome.json, win40c-chrome.json). What is
// reproduced is the synchronous half: which descriptor member is read first,
// which dictionary each message names, and what the call answers with. The
// asynchronous half -- ill-formed WGSL, a pipeline whose entry point does not
// exist, a second finish() on a spent encoder -- is a GPUValidationError
// delivered through an error scope, which is P6 of this batch. Chrome hands back
// a perfectly good object from all three of those, and so does this.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const resources = @import("resources.zig");
const device = @import("device.zig");
const WebGLRenderingContext = @import("../canvas/WebGLRenderingContext.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        GPUCanvasContext,
        GPUCommandBuffer,
        GPUCommandEncoder,
        GPUCompilationInfo,
        GPUCompilationMessage,
        GPUComputePassEncoder,
        GPUComputePipeline,
        GPURenderBundle,
        GPURenderBundleEncoder,
        GPURenderPassEncoder,
        GPURenderPipeline,
        GPUShaderModule,
    };
}

const throwDom = dictionary.throwDom;

/// WebIDL `[EnforceRange] unsigned long`, which both the bind-group index and
/// `GPUCanvasConfiguration.usage` are: a value that is not a number in range is
/// a TypeError rather than a wrap-around, and its wording is unlike every other
/// member's (measured -- `pipeline.getBindGroupLayout('nope')` and
/// `configure({usage: 'nope'})` both say "Value is not of type 'unsigned
/// long'.").
fn enforceRange(value: js.Value, comptime message: []const u8, exec: *const Execution) !u32 {
    const number = value.toF64() catch return dictionary.throwTypeError(message, exec);
    if (!std.math.isFinite(number)) {
        return dictionary.throwTypeError(message, exec);
    }
    const truncated = @trunc(number);
    if (truncated < 0 or truncated > 4294967295) {
        return dictionary.throwTypeError(message, exec);
    }
    return @intFromFloat(truncated);
}

/// A `sequence<GPUTextureFormat?>` member. The entries really are nullable in
/// `colorFormats` -- `[null]` is accepted (measured) and names no format, so it
/// is skipped rather than refused.
fn readFormats(
    comptime Reader: type,
    comptime name: []const u8,
    member: js.Value,
    exec: *const Execution,
) ![]const []const u8 {
    if (!member.isArray()) {
        return Reader.notASequence(name, exec);
    }
    const array = member.toArray();
    const len = array.len();
    var formats: std.ArrayList([]const u8) = try .initCapacity(exec.arena, len);
    for (0..len) |i| {
        const entry = try array.get(@intCast(i));
        if (entry.isNullOrUndefined()) {
            continue;
        }
        const text = try entry.toStringSlice();
        const format = for (resources.core_texture_formats) |candidate| {
            if (std.mem.eql(u8, candidate, text)) break candidate;
        } else return dictionary.throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            Reader.message_prefix ++ "Failed to read the '" ++ name ++ "' property from '" ++ Reader.dict_name ++
                "': The provided value '{s}' is not a valid enum value of type GPUTextureFormat.",
            .{text},
        ), exec);
        formats.appendAssumeCapacity(format);
    }
    return formats.items;
}

// ---------------------------------------------------------------------------
// GPUShaderModule, and the two things getCompilationInfo() answers with.
// ---------------------------------------------------------------------------

pub const GPUShaderModule = struct {
    _label: []const u8 = "",

    const label_accessors = resources.labelAccessors(GPUShaderModule);

    /// A fresh GPUCompilationInfo every call, holding a fresh array. Chrome's
    /// are not stable either: two calls give two objects, and even one info's
    /// `messages` is a new array on every read (measured).
    pub fn getCompilationInfo(_: *GPUShaderModule, exec: *const Execution) !js.Promise {
        const info = try exec._factory.create(GPUCompilationInfo{});
        return exec.js.local.?.resolvePromise(info);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUShaderModule);

        pub const Meta = struct {
            pub const name = "GPUShaderModule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const getCompilationInfo = bridge.function(GPUShaderModule.getCompilationInfo, .{});
    };
};

pub const GPUCompilationInfo = struct {
    /// Always empty. Nothing here compiles WGSL, so there is nothing to report
    /// -- which is what Chrome answers for a module that compiled cleanly
    /// (measured). A module with a syntax error is where the two part company:
    /// Chrome fills this list in and reports the same failure through an error
    /// scope, and both halves of that belong to P6.
    _messages: []const *GPUCompilationMessage = &.{},

    pub fn getMessages(self: *const GPUCompilationInfo) []const *GPUCompilationMessage {
        return self._messages;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUCompilationInfo);

        pub const Meta = struct {
            pub const name = "GPUCompilationInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const messages = bridge.accessor(GPUCompilationInfo.getMessages, null, .{});
    };
};

/// Never handed out today, since the list above is always empty -- but the
/// interface object and its prototype are on `window` regardless, and that is
/// what a fingerprinter enumerates. The defaults are what Chrome reports for a
/// parse error (`type: 'error'`, one-based line, zero-based offset).
pub const GPUCompilationMessage = struct {
    _message: []const u8 = "",
    _type: []const u8 = "error",
    _line_num: u64 = 0,
    _line_pos: u64 = 0,
    _offset: u64 = 0,
    _length: u64 = 0,

    pub fn getMessage(self: *const GPUCompilationMessage) []const u8 {
        return self._message;
    }

    pub fn getType(self: *const GPUCompilationMessage) []const u8 {
        return self._type;
    }

    pub fn getLineNum(self: *const GPUCompilationMessage) u64 {
        return self._line_num;
    }

    pub fn getLinePos(self: *const GPUCompilationMessage) u64 {
        return self._line_pos;
    }

    pub fn getOffset(self: *const GPUCompilationMessage) u64 {
        return self._offset;
    }

    pub fn getLength(self: *const GPUCompilationMessage) u64 {
        return self._length;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUCompilationMessage);

        pub const Meta = struct {
            pub const name = "GPUCompilationMessage";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const M = GPUCompilationMessage;

        pub const message = bridge.accessor(M.getMessage, null, .{});
        pub const @"type" = bridge.accessor(M.getType, null, .{});
        pub const lineNum = bridge.accessor(M.getLineNum, null, .{});
        pub const linePos = bridge.accessor(M.getLinePos, null, .{});
        pub const offset = bridge.accessor(M.getOffset, null, .{});
        pub const length = bridge.accessor(M.getLength, null, .{});
    };
};

// ---------------------------------------------------------------------------
// The two pipelines. They differ only in brand and in the descriptor that
// builds them.
// ---------------------------------------------------------------------------

pub const GPUComputePipeline = Pipeline("GPUComputePipeline");
pub const GPURenderPipeline = Pipeline("GPURenderPipeline");

fn Pipeline(comptime type_name: []const u8) type {
    return struct {
        const Self = @This();

        _label: []const u8 = "",

        const label_accessors = resources.labelAccessors(Self);
        const ARITY = "Failed to execute 'getBindGroupLayout' on '" ++ type_name ++
            "': 1 argument required, but only 0 present.";
        const NOT_INDEX = "Failed to execute 'getBindGroupLayout' on '" ++ type_name ++
            "': Value is not of type 'unsigned long'.";

        /// A *new* layout object on every call, even for the same index
        /// (measured: `p.getBindGroupLayout(0) !== p.getBindGroupLayout(0)`).
        /// An index past the device's bind-group limit still answers with one;
        /// that complaint arrives asynchronously.
        pub fn getBindGroupLayout(_: *Self, args: []js.Value, exec: *const Execution) !*resources.GPUBindGroupLayout {
            if (args.len == 0) {
                return dictionary.throwTypeError(ARITY, exec);
            }
            _ = try enforceRange(args[0], NOT_INDEX, exec);
            return exec._factory.create(resources.GPUBindGroupLayout{});
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = type_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
            pub const getBindGroupLayout = bridge.function(Self.getBindGroupLayout, .{ .arity = 1 });
        };
    };
}

// ---------------------------------------------------------------------------
// The encoders: everything that records rather than allocates.
// ---------------------------------------------------------------------------

pub const GPUCommandBuffer = resources.LabelOnly("GPUCommandBuffer");
pub const GPURenderBundle = resources.LabelOnly("GPURenderBundle");

pub const GPUCommandEncoder = struct {
    _label: []const u8 = "",

    const label_accessors = resources.labelAccessors(GPUCommandEncoder);

    pub fn beginComputePass(_: *GPUCommandEncoder, descriptor_: ?js.Value, exec: *const Execution) !*GPUComputePassEncoder {
        const Reader = dictionary.MethodReader("GPUCommandEncoder", "beginComputePass", "GPUComputePassDescriptor");
        const descriptor = try Reader.read(descriptor_, exec);
        return exec._factory.create(GPUComputePassEncoder{
            ._label = try descriptor.string("label", "", exec.arena),
        });
    }

    /// The one encoder call whose descriptor is required: a render pass needs
    /// somewhere to draw. Each colour attachment is read too, because that is
    /// where a page finds out about a missing `loadOp` -- which it hears about
    /// before a missing `view` (measured).
    pub fn beginRenderPass(_: *GPUCommandEncoder, args: []js.Value, exec: *const Execution) !*GPURenderPassEncoder {
        const Reader = dictionary.MethodReader("GPUCommandEncoder", "beginRenderPass", "GPURenderPassDescriptor");
        const argument = try resources.requireArgument("GPUCommandEncoder", "beginRenderPass", args, exec);
        const descriptor = try Reader.readRequired(argument, exec);

        const attachments = try descriptor.required("colorAttachments", exec);
        if (!attachments.isArray()) {
            return Reader.notASequence("colorAttachments", exec);
        }
        const Attachment = dictionary.Nested(Reader, "colorAttachments", "GPURenderPassColorAttachment");
        const array = attachments.toArray();
        for (0..array.len()) |i| {
            const attachment = try Attachment.read(try array.get(@intCast(i)), exec);
            const load_op = try attachment.requiredEnum("loadOp", "GPULoadOp", &.{ "load", "clear" }, exec);
            _ = try attachment.requiredEnum("storeOp", "GPUStoreOp", &.{ "store", "discard" }, exec);
            const view = try attachment.interfaceMember("view", resources.GPUTextureView, "GPUTextureView", exec);

            // A clear is the one part of a render pass reproducible without a
            // rasteriser, so it is the one part recorded: the attachment's
            // texture remembers the colour, and a later copyTextureToBuffer
            // hands those bytes back. A `load` contributes nothing and leaves
            // whatever was there.
            if (std.mem.eql(u8, load_op, "clear")) {
                if (view._texture) |texture| {
                    texture._clear = texture.clearBytes(try clearValue(attachment, exec));
                }
            }
        }

        return exec._factory.create(GPURenderPassEncoder{
            ._label = try descriptor.string("label", "", exec.arena),
        });
    }

    /// The one recording call that is not shape-only. Everything else an
    /// encoder records has no state to change, but this one is the step the
    /// Cloudflare widget reads its WebGPU surface back through, and answering
    /// it with nothing left the buffer transparent -- a shape a real browser
    /// cannot produce, because a render pass has always at least cleared.
    ///
    /// What is reproduced is the clear colour, repeated over each row's pixel
    /// bytes. WebGPU makes `bytesPerRow` a multiple of 256, so on the widget's
    /// 16x16 target each row is 64 bytes of pixels and 192 of padding; the
    /// padding stays zero, which is what a served Chrome capture shows. The
    /// pixels an actual `draw` would have put there are not reproduced -- see
    /// the README section for B129.
    ///
    /// Chrome answers undefined, and so does this.
    pub fn copyTextureToBuffer(
        _: *GPUCommandEncoder,
        args: []js.Value,
        exec: *const Execution,
    ) !void {
        if (args.len < 3) {
            return dictionary.throwTypeError(
                "Failed to execute 'copyTextureToBuffer' on 'GPUCommandEncoder': 3 arguments required.",
                exec,
            );
        }
        const Source = dictionary.Reader("GPUCommandEncoder", "GPUTexelCopyTextureInfo");
        const Dest = dictionary.Reader("GPUCommandEncoder", "GPUTexelCopyBufferInfo");

        const source = Source.readRequired(args[0], exec) catch return;
        const dest = Dest.readRequired(args[1], exec) catch return;

        const texture = (source.interfaceMember(
            "texture",
            resources.GPUTexture,
            "GPUTexture",
            exec,
        ) catch return);
        const buffer = (dest.interfaceMember(
            "buffer",
            resources.GPUBuffer,
            "GPUBuffer",
            exec,
        ) catch return);

        // Nothing is known about the texture's contents unless a render pass
        // cleared it, and a copy out of an unknown texture leaves the zeros.
        const pixel = texture._clear orelse return;

        const stride = dest.unsignedLong("bytesPerRow", 0) catch return;
        const offset = dest.double("offset", 0, exec) catch 0;
        const size = extent(args[2], exec) catch return;

        const width = if (size[0] > 0) size[0] else texture._width;
        const height = if (size[1] > 0) size[1] else texture._height;
        // Only the 8-bit-per-channel formats have a four-byte pixel, and those
        // are the ones a readback of this kind uses.
        const row_bytes = width * 4;
        try buffer.fillRows(
            exec,
            @intFromFloat(@max(0, offset)),
            height,
            row_bytes,
            if (stride > 0) stride else row_bytes,
            pixel,
        );
    }

    /// A `GPUExtent3D`: a sequence of up to three integers, or a dict with
    /// width/height/depthOrArrayLayers. Zero means "not given" to the caller.
    fn extent(value: js.Value, exec: *const Execution) ![2]u32 {
        if (value.isArray()) {
            const array = value.toArray();
            var out: [2]u32 = .{ 0, 0 };
            var i: usize = 0;
            while (i < 2 and i < array.len()) : (i += 1) {
                const member = array.get(@intCast(i)) catch return out;
                const n = member.toF64() catch 0;
                out[i] = if (n > 0) @intFromFloat(n) else 0;
            }
            return out;
        }
        const Size = dictionary.Reader("GPUCommandEncoder", "GPUExtent3DDict");
        const size = try Size.readRequired(value, exec);
        return .{
            size.unsignedLong("width", 0) catch 0,
            size.unsignedLong("height", 0) catch 0,
        };
    }

    /// A `GPUColor`, which WebGPU takes either as a four-element sequence or as
    /// a dict with r/g/b/a. Absent is transparent black, the spec's default for
    /// a clear that names no value -- and the reason an unpainted readback is
    /// all zeros rather than opaque black.
    fn clearValue(attachment: anytype, exec: *const Execution) ![4]f64 {
        const transparent: [4]f64 = .{ 0, 0, 0, 0 };
        const value = (try attachment.present("clearValue")) orelse return transparent;
        if (value.isUndefined() or value.isNull()) {
            return transparent;
        }
        if (value.isArray()) {
            const array = value.toArray();
            var out = transparent;
            var i: usize = 0;
            while (i < 4 and i < array.len()) : (i += 1) {
                const member = array.get(@intCast(i)) catch return transparent;
                out[i] = member.toF64() catch 0;
            }
            return out;
        }
        const Color = dictionary.Reader("GPURenderPassColorAttachment", "GPUColorDict");
        const color = Color.readRequired(value, exec) catch return transparent;
        return .{
            try color.double("r", 0, exec),
            try color.double("g", 0, exec),
            try color.double("b", 0, exec),
            try color.double("a", 0, exec),
        };
    }

    pub fn finish(_: *GPUCommandEncoder, descriptor_: ?js.Value, exec: *const Execution) !*GPUCommandBuffer {
        const Reader = dictionary.MethodReader("GPUCommandEncoder", "finish", "GPUCommandBufferDescriptor");
        const descriptor = try Reader.read(descriptor_, exec);
        return exec._factory.create(GPUCommandBuffer{
            ._label = try descriptor.string("label", "", exec.arena),
        });
    }

    // The recording calls. Nothing is executed, so there is no state for them
    // to change; the name, the arity and the position in the prototype are what
    // a detector reads. Chrome answers undefined from all of them too.
    pub fn shapeOnly(_: *GPUCommandEncoder) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUCommandEncoder);

        pub const Meta = struct {
            pub const name = "GPUCommandEncoder";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const E = GPUCommandEncoder;
        const stub = resources.Stub(GPUCommandEncoder, "GPUCommandEncoder");

        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const beginComputePass = bridge.function(E.beginComputePass, .{ .arity = 0 });
        pub const beginRenderPass = bridge.function(E.beginRenderPass, .{ .arity = 1 });
        pub const copyBufferToTexture = bridge.function(stub.Arity("copyBufferToTexture", 3).call, .{ .arity = 3 });
        pub const copyTextureToBuffer = bridge.function(E.copyTextureToBuffer, .{ .arity = 3 });
        pub const copyTextureToTexture = bridge.function(stub.Arity("copyTextureToTexture", 3).call, .{ .arity = 3 });
        pub const finish = bridge.function(E.finish, .{ .arity = 0 });
        pub const insertDebugMarker = bridge.function(stub.Arity("insertDebugMarker", 1).call, .{ .arity = 1 });
        pub const pushDebugGroup = bridge.function(stub.Arity("pushDebugGroup", 1).call, .{ .arity = 1 });
        // Chrome's order restarts here rather than carrying on.
        pub const clearBuffer = bridge.function(stub.Arity("clearBuffer", 1).call, .{ .arity = 1 });
        pub const copyBufferToBuffer = bridge.function(stub.Arity("copyBufferToBuffer", 2).call, .{ .arity = 2 });
        pub const popDebugGroup = bridge.function(E.shapeOnly, .{});
        pub const resolveQuerySet = bridge.function(stub.Arity("resolveQuerySet", 5).call, .{ .arity = 5 });
    };
};

pub const GPUComputePassEncoder = struct {
    _label: []const u8 = "",

    const label_accessors = resources.labelAccessors(GPUComputePassEncoder);

    pub fn shapeOnly(_: *GPUComputePassEncoder) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUComputePassEncoder);

        pub const Meta = struct {
            pub const name = "GPUComputePassEncoder";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const P = GPUComputePassEncoder;
        const stub = resources.Stub(GPUComputePassEncoder, "GPUComputePassEncoder");

        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const insertDebugMarker = bridge.function(stub.Arity("insertDebugMarker", 1).call, .{ .arity = 1 });
        pub const pushDebugGroup = bridge.function(stub.Arity("pushDebugGroup", 1).call, .{ .arity = 1 });
        pub const dispatchWorkgroups = bridge.function(stub.Arity("dispatchWorkgroups", 1).call, .{ .arity = 1 });
        pub const dispatchWorkgroupsIndirect = bridge.function(stub.Arity("dispatchWorkgroupsIndirect", 2).call, .{ .arity = 2 });
        pub const end = bridge.function(P.shapeOnly, .{});
        pub const popDebugGroup = bridge.function(P.shapeOnly, .{});
        pub const setBindGroup = bridge.function(stub.Arity("setBindGroup", 2).call, .{ .arity = 2 });
        pub const setPipeline = bridge.function(stub.Arity("setPipeline", 1).call, .{ .arity = 1 });
        pub const writeTimestamp = bridge.function(stub.Arity("writeTimestamp", 2).call, .{ .arity = 2 });
        pub const setImmediates = bridge.function(stub.Arity("setImmediates", 2).call, .{ .arity = 2 });
    };
};

pub const GPURenderPassEncoder = struct {
    _label: []const u8 = "",

    const label_accessors = resources.labelAccessors(GPURenderPassEncoder);

    pub fn shapeOnly(_: *GPURenderPassEncoder) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPURenderPassEncoder);

        pub const Meta = struct {
            pub const name = "GPURenderPassEncoder";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const P = GPURenderPassEncoder;
        const stub = resources.Stub(GPURenderPassEncoder, "GPURenderPassEncoder");

        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const executeBundles = bridge.function(stub.Arity("executeBundles", 1).call, .{ .arity = 1 });
        pub const insertDebugMarker = bridge.function(stub.Arity("insertDebugMarker", 1).call, .{ .arity = 1 });
        pub const pushDebugGroup = bridge.function(stub.Arity("pushDebugGroup", 1).call, .{ .arity = 1 });
        pub const setBlendConstant = bridge.function(stub.Arity("setBlendConstant", 1).call, .{ .arity = 1 });
        pub const setIndexBuffer = bridge.function(stub.Arity("setIndexBuffer", 2).call, .{ .arity = 2 });
        pub const beginOcclusionQuery = bridge.function(stub.Arity("beginOcclusionQuery", 1).call, .{ .arity = 1 });
        pub const draw = bridge.function(stub.Arity("draw", 1).call, .{ .arity = 1 });
        pub const drawIndexed = bridge.function(stub.Arity("drawIndexed", 1).call, .{ .arity = 1 });
        pub const drawIndexedIndirect = bridge.function(stub.Arity("drawIndexedIndirect", 2).call, .{ .arity = 2 });
        pub const drawIndirect = bridge.function(stub.Arity("drawIndirect", 2).call, .{ .arity = 2 });
        pub const end = bridge.function(P.shapeOnly, .{});
        pub const endOcclusionQuery = bridge.function(P.shapeOnly, .{});
        pub const popDebugGroup = bridge.function(P.shapeOnly, .{});
        pub const setBindGroup = bridge.function(stub.Arity("setBindGroup", 2).call, .{ .arity = 2 });
        pub const setPipeline = bridge.function(stub.Arity("setPipeline", 1).call, .{ .arity = 1 });
        pub const setScissorRect = bridge.function(stub.Arity("setScissorRect", 4).call, .{ .arity = 4 });
        pub const setStencilReference = bridge.function(stub.Arity("setStencilReference", 1).call, .{ .arity = 1 });
        pub const setVertexBuffer = bridge.function(stub.Arity("setVertexBuffer", 2).call, .{ .arity = 2 });
        pub const setViewport = bridge.function(stub.Arity("setViewport", 6).call, .{ .arity = 6 });
        pub const writeTimestamp = bridge.function(stub.Arity("writeTimestamp", 2).call, .{ .arity = 2 });
        pub const setImmediates = bridge.function(stub.Arity("setImmediates", 2).call, .{ .arity = 2 });
    };
};

pub const GPURenderBundleEncoder = struct {
    _label: []const u8 = "",

    const label_accessors = resources.labelAccessors(GPURenderBundleEncoder);

    pub fn finish(_: *GPURenderBundleEncoder, descriptor_: ?js.Value, exec: *const Execution) !*GPURenderBundle {
        const Reader = dictionary.MethodReader("GPURenderBundleEncoder", "finish", "GPURenderBundleDescriptor");
        const descriptor = try Reader.read(descriptor_, exec);
        return exec._factory.create(GPURenderBundle{
            ._label = try descriptor.string("label", "", exec.arena),
        });
    }

    pub fn shapeOnly(_: *GPURenderBundleEncoder) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPURenderBundleEncoder);

        pub const Meta = struct {
            pub const name = "GPURenderBundleEncoder";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const B = GPURenderBundleEncoder;
        const stub = resources.Stub(GPURenderBundleEncoder, "GPURenderBundleEncoder");

        pub const label = bridge.accessor(label_accessors.get, label_accessors.set, .{});
        pub const finish = bridge.function(B.finish, .{ .arity = 0 });
        pub const insertDebugMarker = bridge.function(stub.Arity("insertDebugMarker", 1).call, .{ .arity = 1 });
        pub const pushDebugGroup = bridge.function(stub.Arity("pushDebugGroup", 1).call, .{ .arity = 1 });
        pub const setIndexBuffer = bridge.function(stub.Arity("setIndexBuffer", 2).call, .{ .arity = 2 });
        pub const draw = bridge.function(stub.Arity("draw", 1).call, .{ .arity = 1 });
        pub const drawIndexed = bridge.function(stub.Arity("drawIndexed", 1).call, .{ .arity = 1 });
        pub const drawIndexedIndirect = bridge.function(stub.Arity("drawIndexedIndirect", 2).call, .{ .arity = 2 });
        pub const drawIndirect = bridge.function(stub.Arity("drawIndirect", 2).call, .{ .arity = 2 });
        pub const popDebugGroup = bridge.function(B.shapeOnly, .{});
        pub const setBindGroup = bridge.function(stub.Arity("setBindGroup", 2).call, .{ .arity = 2 });
        pub const setPipeline = bridge.function(stub.Arity("setPipeline", 1).call, .{ .arity = 1 });
        pub const setVertexBuffer = bridge.function(stub.Arity("setVertexBuffer", 2).call, .{ .arity = 2 });
        pub const setImmediates = bridge.function(stub.Arity("setImmediates", 2).call, .{ .arity = 2 });
    };
};

// ---------------------------------------------------------------------------
// GPUCanvasContext -- what `canvas.getContext('webgpu')` hands back.
// ---------------------------------------------------------------------------

pub const GPUCanvasContext = struct {
    /// Either kind of canvas can own one: `new OffscreenCanvas(16, 8)
    /// .getContext('webgpu')` gives a context whose `canvas` is the offscreen
    /// one (measured). Same union the WebGL contexts carry.
    pub const Surface = WebGLRenderingContext.Surface;

    _canvas: Surface,
    _configuration: ?Configuration = null,
    /// The canvas' current bitmap. Chrome hands back the same object until
    /// something invalidates it -- re-configuring, or a change of size
    /// (measured: after `canvas.width = 64` the texture reports 64).
    _texture: ?*resources.GPUTexture = null,

    /// What getConfiguration() answers with: a plain object rather than a
    /// branded one, rebuilt on every read, with the members in Chrome's order --
    /// which here happens to be alphabetical (measured).
    pub const Configuration = struct {
        alphaMode: []const u8,
        colorSpace: []const u8,
        device: *device.GPUDevice,
        format: []const u8,
        toneMapping: ToneMapping,
        usage: u32,
        viewFormats: []const []const u8,

        pub const ToneMapping = struct {
            mode: []const u8,
        };
    };

    // GPUTextureUsage.RENDER_ATTACHMENT, which is what a canvas configured
    // without a `usage` reports back (measured).
    const DEFAULT_USAGE: u32 = 0x10;
    const NOT_CONFIGURED = "Failed to execute 'getCurrentTexture' on 'GPUCanvasContext': context is not configured";
    const BAD_USAGE = "Failed to execute 'configure' on 'GPUCanvasContext': " ++
        "Failed to read the 'usage' property from 'GPUCanvasConfiguration': Value is not of type 'unsigned long'.";

    pub fn getCanvas(self: *const GPUCanvasContext) Surface {
        return self._canvas;
    }

    pub fn configure(self: *GPUCanvasContext, args: []js.Value, exec: *const Execution) !void {
        const Reader = dictionary.MethodReader("GPUCanvasContext", "configure", "GPUCanvasConfiguration");
        const argument = try resources.requireArgument("GPUCanvasContext", "configure", args, exec);
        const config = try Reader.readRequired(argument, exec);

        // Read in the order Chrome does, which is the order the members are
        // declared in: `device` before `format`, and both before `usage`.
        const alpha_mode = (try config.enumMember(
            "alphaMode",
            "GPUCanvasAlphaMode",
            &.{ "opaque", "premultiplied" },
            "opaque",
            exec,
        )).?;
        const color_space = (try config.enumMember(
            "colorSpace",
            "PredefinedColorSpace",
            &.{ "srgb", "display-p3" },
            "srgb",
            exec,
        )).?;
        const gpu = try config.interfaceMember("device", device.GPUDevice, "GPUDevice", exec);
        const format = try config.requiredEnum(
            "format",
            "GPUTextureFormat",
            &resources.core_texture_formats,
            exec,
        );
        const tone_mapping = try readToneMapping(Reader, config, exec);
        const usage = if (try config.present("usage")) |member|
            try enforceRange(member, BAD_USAGE, exec)
        else
            DEFAULT_USAGE;
        const view_formats: []const []const u8 = if (try config.present("viewFormats")) |member|
            try readFormats(Reader, "viewFormats", member, exec)
        else
            &.{};

        self._configuration = .{
            .alphaMode = alpha_mode,
            .colorSpace = color_space,
            .device = gpu,
            .format = format,
            .toneMapping = .{ .mode = tone_mapping },
            .usage = usage,
            .viewFormats = view_formats,
        };
        // A new configuration means a new bitmap.
        self._texture = null;
    }

    pub fn getConfiguration(self: *const GPUCanvasContext) ?Configuration {
        return self._configuration;
    }

    pub fn getCurrentTexture(self: *GPUCanvasContext, exec: *const Execution) !*resources.GPUTexture {
        const config = self._configuration orelse return throwDom("InvalidStateError", NOT_CONFIGURED, exec);
        const width = self._canvas.width();
        const height = self._canvas.height();
        if (self._texture) |texture| {
            if (texture._width == width and texture._height == height) {
                return texture;
            }
        }
        const created = try exec._factory.create(resources.GPUTexture{
            ._width = width,
            ._height = height,
            ._depth_or_array_layers = 1,
            ._mip_level_count = 1,
            ._sample_count = 1,
            ._dimension = "2d",
            ._format = config.format,
            ._usage = config.usage,
        });
        self._texture = created;
        return created;
    }

    pub fn unconfigure(self: *GPUCanvasContext) void {
        self._configuration = null;
        self._texture = null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUCanvasContext);

        pub const Meta = struct {
            pub const name = "GPUCanvasContext";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const C = GPUCanvasContext;

        pub const canvas = bridge.accessor(C.getCanvas, null, .{});
        pub const configure = bridge.function(C.configure, .{ .arity = 1 });
        pub const getConfiguration = bridge.function(C.getConfiguration, .{});
        pub const getCurrentTexture = bridge.function(C.getCurrentTexture, .{});
        pub const unconfigure = bridge.function(C.unconfigure, .{});
    };
};

/// `CanvasToneMapping`, a dictionary of one enum. Chrome nests the wording, so
/// the message names both dictionaries (measured with
/// `{toneMapping: {mode: 'nope'}}`).
fn readToneMapping(comptime Reader: type, config: Reader, exec: *const Execution) ![]const u8 {
    const member = (try config.present("toneMapping")) orelse return "standard";
    const ToneMapping = dictionary.Nested(Reader, "toneMapping", "CanvasToneMapping");
    const tone_mapping = try ToneMapping.read(member, exec);
    return (try tone_mapping.enumMember(
        "mode",
        "CanvasToneMappingMode",
        &.{ "standard", "extended" },
        "standard",
        exec,
    )).?;
}

// ---------------------------------------------------------------------------
// The device.create* bodies for this half of the family. Same split as
// resources.zig: a missing or ill-typed descriptor member is a synchronous
// TypeError, and anything past that is P6's error scopes.
// ---------------------------------------------------------------------------

pub fn createShaderModule(args: []js.Value, exec: *const Execution) !*GPUShaderModule {
    const Reader = dictionary.MethodReader("GPUDevice", "createShaderModule", "GPUShaderModuleDescriptor");
    const argument = try resources.requireArgument("GPUDevice", "createShaderModule", args, exec);
    const descriptor = try Reader.readRequired(argument, exec);
    // `code` is a DOMString, so anything that stringifies gets through -- a
    // number reaches the WGSL parser, which complains asynchronously (measured
    // with `{code: 5}`). Read here for the conversion's side effects.
    _ = try (try descriptor.required("code", exec)).toStringSlice();
    return exec._factory.create(GPUShaderModule{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

pub fn createCommandEncoder(descriptor_: ?js.Value, exec: *const Execution) !*GPUCommandEncoder {
    const Reader = dictionary.MethodReader("GPUDevice", "createCommandEncoder", "GPUCommandEncoderDescriptor");
    const descriptor = try Reader.read(descriptor_, exec);
    return exec._factory.create(GPUCommandEncoder{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

pub fn createRenderBundleEncoder(args: []js.Value, exec: *const Execution) !*GPURenderBundleEncoder {
    const Reader = dictionary.MethodReader("GPUDevice", "createRenderBundleEncoder", "GPURenderBundleEncoderDescriptor");
    const argument = try resources.requireArgument("GPUDevice", "createRenderBundleEncoder", args, exec);
    const descriptor = try Reader.readRequired(argument, exec);
    // colorFormats is declared on GPURenderPassLayout, and every message about
    // it names that rather than the descriptor the page passed in (measured).
    const Layout = dictionary.Sibling(Reader, "GPURenderPassLayout");
    const layout = Layout{ .object = descriptor.object };
    _ = try readFormats(Layout, "colorFormats", try layout.required("colorFormats", exec), exec);
    return exec._factory.create(GPURenderBundleEncoder{
        ._label = try descriptor.string("label", "", exec.arena),
    });
}

pub fn createComputePipeline(args: []js.Value, exec: *const Execution) !*GPUComputePipeline {
    return exec._factory.create(GPUComputePipeline{
        ._label = try readComputeDescriptor("createComputePipeline", args, exec),
    });
}

pub fn createRenderPipeline(args: []js.Value, exec: *const Execution) !*GPURenderPipeline {
    return exec._factory.create(GPURenderPipeline{
        ._label = try readRenderDescriptor("createRenderPipeline", args, exec),
    });
}

/// The *Async pair does not throw: the same TypeError arrives as a rejection
/// instead (measured -- WebIDL turns a promise-returning operation's conversion
/// errors into rejections, and Chrome's message is identical down to the method
/// name, `createComputePipelineAsync`).
pub fn createComputePipelineAsync(args: []js.Value, exec: *const Execution) !js.Promise {
    return asPromise(GPUComputePipeline, "createComputePipelineAsync", false, args, exec);
}

pub fn createRenderPipelineAsync(args: []js.Value, exec: *const Execution) !js.Promise {
    return asPromise(GPURenderPipeline, "createRenderPipelineAsync", true, args, exec);
}

fn asPromise(
    comptime T: type,
    comptime method: []const u8,
    comptime render: bool,
    args: []js.Value,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    // Around the descriptor read, so the exception it throws into the isolate
    // can be moved onto the promise rather than left pending.
    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const resolver = local.createPromiseResolver();
    const read = if (comptime render)
        readRenderDescriptor(method, args, exec)
    else
        readComputeDescriptor(method, args, exec);

    if (read) |label| {
        resolver.resolve("GPUDevice." ++ method, try exec._factory.create(T{ ._label = label }));
    } else |err| {
        if (try_catch.exceptionValue()) |exception| {
            resolver.reject("GPUDevice." ++ method, exception);
        } else {
            resolver.rejectError("GPUDevice." ++ method, .{ .generic_error = @errorName(err) });
        }
    }
    return resolver.promise();
}

fn readComputeDescriptor(comptime method: []const u8, args: []js.Value, exec: *const Execution) ![]const u8 {
    const Reader = dictionary.MethodReader("GPUDevice", method, "GPUComputePipelineDescriptor");
    const argument = try resources.requireArgument("GPUDevice", method, args, exec);
    const descriptor = try Reader.readRequired(argument, exec);

    try readLayout(Reader, descriptor, exec);
    // `compute` is a GPUProgrammableStage outright, so both its own "not of
    // type" message and its `module` name that dictionary (measured).
    const Stage = dictionary.Nested(Reader, "compute", "GPUProgrammableStage");
    const stage = try Stage.read(try descriptor.required("compute", exec), exec);
    _ = try stage.interfaceMember("module", GPUShaderModule, "GPUShaderModule", exec);

    return descriptor.string("label", "", exec.arena);
}

fn readRenderDescriptor(comptime method: []const u8, args: []js.Value, exec: *const Execution) ![]const u8 {
    const Reader = dictionary.MethodReader("GPUDevice", method, "GPURenderPipelineDescriptor");
    const argument = try resources.requireArgument("GPUDevice", method, args, exec);
    const descriptor = try Reader.readRequired(argument, exec);

    try readLayout(Reader, descriptor, exec);

    // fragment is read before vertex: a descriptor carrying both, both empty,
    // complains about the fragment's module (measured).
    if (try descriptor.present("fragment")) |member| {
        const Fragment = dictionary.Nested(Reader, "fragment", "GPUFragmentState");
        const fragment = try Fragment.read(member, exec);
        // `module` is inherited from GPUProgrammableStage and says so, while
        // `targets` is the fragment state's own and says that instead.
        const Stage = dictionary.Sibling(Fragment, "GPUProgrammableStage");
        _ = try (Stage{ .object = fragment.object }).interfaceMember("module", GPUShaderModule, "GPUShaderModule", exec);
        const targets = try fragment.required("targets", exec);
        if (!targets.isArray()) {
            return Fragment.notASequence("targets", exec);
        }
    }

    const Vertex = dictionary.Nested(Reader, "vertex", "GPUVertexState");
    const vertex = try Vertex.read(try descriptor.required("vertex", exec), exec);
    const VertexStage = dictionary.Sibling(Vertex, "GPUProgrammableStage");
    _ = try (VertexStage{ .object = vertex.object }).interfaceMember("module", GPUShaderModule, "GPUShaderModule", exec);

    return descriptor.string("label", "", exec.arena);
}

/// `layout` is a `(GPUPipelineLayout or GPUAutoLayoutMode)` declared on
/// GPUPipelineDescriptorBase, and every message about it names that base
/// dictionary rather than the descriptor the page passed in (measured). It is
/// read before either pipeline descriptor's own members.
fn readLayout(comptime Reader: type, descriptor: Reader, exec: *const Execution) !void {
    const Base = dictionary.Sibling(Reader, "GPUPipelineDescriptorBase");
    const base = Base{ .object = descriptor.object };
    const member = try base.required("layout", exec);
    if (member.toZig(*resources.GPUPipelineLayout)) |_| {
        return;
    } else |_| {}

    const text = try member.toStringSlice();
    if (std.mem.eql(u8, text, "auto")) {
        return;
    }
    return dictionary.throwTypeError(try std.fmt.allocPrint(
        exec.call_arena,
        Base.message_prefix ++ "Failed to read the 'layout' property from 'GPUPipelineDescriptorBase': " ++
            "The provided value '{s}' is not a valid enum value of type GPUAutoLayoutMode.",
        .{text},
    ), exec);
}

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU pipeline" {
    try testing.htmlRunner("webgpu/pipeline.html", .{});
}
