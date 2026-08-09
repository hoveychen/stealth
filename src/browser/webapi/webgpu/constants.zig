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

// The five WebGPU flag namespaces. Unlike everything else in the WebGPU family
// these carry no behaviour at all -- each is a WebIDL `namespace` holding a
// handful of integer constants, which is why they are also the cheapest way to
// exercise the namespace-object plumbing (see Meta.namespace_global).
//
// Every value below was read off a headed Chrome 150, e.g.
//
//   Object.getOwnPropertyNames(GPUBufferUsage).map((k) => `${k}=${GPUBufferUsage[k]}`)
//     -> ['MAP_READ=1', 'MAP_WRITE=2', 'COPY_SRC=4', 'COPY_DST=8', 'INDEX=16',
//         'VERTEX=32', 'UNIFORM=64', 'STORAGE=128', 'INDIRECT=256',
//         'QUERY_RESOLVE=512']
//
// and the declaration order here is Chrome's own enumeration order.

const js = @import("../../js/js.zig");

pub fn registerTypes() []const type {
    return &.{
        GPUBufferUsage,
        GPUColorWrite,
        GPUMapMode,
        GPUShaderStage,
        GPUTextureUsage,
    };
}

pub const GPUBufferUsage = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUBufferUsage);

        pub const Meta = struct {
            pub const name = "GPUBufferUsage";
            pub const namespace_global = true;
            pub const own_properties = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const MAP_READ = bridge.property(@as(u32, 0x0001), .{ .template = false });
        pub const MAP_WRITE = bridge.property(@as(u32, 0x0002), .{ .template = false });
        pub const COPY_SRC = bridge.property(@as(u32, 0x0004), .{ .template = false });
        pub const COPY_DST = bridge.property(@as(u32, 0x0008), .{ .template = false });
        pub const INDEX = bridge.property(@as(u32, 0x0010), .{ .template = false });
        pub const VERTEX = bridge.property(@as(u32, 0x0020), .{ .template = false });
        pub const UNIFORM = bridge.property(@as(u32, 0x0040), .{ .template = false });
        pub const STORAGE = bridge.property(@as(u32, 0x0080), .{ .template = false });
        pub const INDIRECT = bridge.property(@as(u32, 0x0100), .{ .template = false });
        pub const QUERY_RESOLVE = bridge.property(@as(u32, 0x0200), .{ .template = false });
    };
};

pub const GPUMapMode = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUMapMode);

        pub const Meta = struct {
            pub const name = "GPUMapMode";
            pub const namespace_global = true;
            pub const own_properties = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const READ = bridge.property(@as(u32, 0x0001), .{ .template = false });
        pub const WRITE = bridge.property(@as(u32, 0x0002), .{ .template = false });
    };
};

pub const GPUShaderStage = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUShaderStage);

        pub const Meta = struct {
            pub const name = "GPUShaderStage";
            pub const namespace_global = true;
            pub const own_properties = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const VERTEX = bridge.property(@as(u32, 0x1), .{ .template = false });
        pub const FRAGMENT = bridge.property(@as(u32, 0x2), .{ .template = false });
        pub const COMPUTE = bridge.property(@as(u32, 0x4), .{ .template = false });
    };
};

pub const GPUColorWrite = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUColorWrite);

        pub const Meta = struct {
            pub const name = "GPUColorWrite";
            pub const namespace_global = true;
            pub const own_properties = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const RED = bridge.property(@as(u32, 0x1), .{ .template = false });
        pub const GREEN = bridge.property(@as(u32, 0x2), .{ .template = false });
        pub const BLUE = bridge.property(@as(u32, 0x4), .{ .template = false });
        pub const ALPHA = bridge.property(@as(u32, 0x8), .{ .template = false });
        pub const ALL = bridge.property(@as(u32, 0xF), .{ .template = false });
    };
};

// GPUTextureUsage.TRANSIENT_ATTACHMENT is not in the WebGPU spec; Chrome 150
// ships it anyway, so it is here too.
pub const GPUTextureUsage = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPUTextureUsage);

        pub const Meta = struct {
            pub const name = "GPUTextureUsage";
            pub const namespace_global = true;
            pub const own_properties = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const COPY_SRC = bridge.property(@as(u32, 0x01), .{ .template = false });
        pub const COPY_DST = bridge.property(@as(u32, 0x02), .{ .template = false });
        pub const TEXTURE_BINDING = bridge.property(@as(u32, 0x04), .{ .template = false });
        pub const STORAGE_BINDING = bridge.property(@as(u32, 0x08), .{ .template = false });
        pub const RENDER_ATTACHMENT = bridge.property(@as(u32, 0x10), .{ .template = false });
        pub const TRANSIENT_ATTACHMENT = bridge.property(@as(u32, 0x20), .{ .template = false });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGPU constants" {
    try testing.htmlRunner("webgpu/constants.html", .{});
}
