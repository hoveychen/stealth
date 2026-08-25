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

const js = @import("../../js/js.zig");
const Canvas = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");
const objects = @import("webgl_objects.zig");
const gl_state = @import("webgl_state.zig");
const attributes = @import("context_attributes.zig");
const gpu_table = @import("gpu.zig");
const extensions = @import("webgl_extensions.zig");
const gpu = gpu_table.gpu;
const DOMException = @import("../DOMException.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &([_]type{
        WebGLRenderingContext,
    } ++ extensions.all);
}

const WebGLRenderingContext = @This();

/// The canvas this context draws into.
_canvas: Surface,

/// Everything the context remembers: shader and program objects, the bound
/// buffer, the attribute arrays, the viewport and the drawing buffer. Shared
/// with WebGL2RenderingContext, which is a separate type with a separate
/// prototype and the same job. See webgl_state.zig.
_gl: gl_state,

/// `drawingBufferColorSpace` and `unpackColorSpace` are the only two read-write
/// attributes on this interface, and nothing downstream reads them -- there is
/// no rasterizer to hand a colour space to. They are stored so the assignment
/// sticks, because in Chrome they are accessors and a bot check reads the
/// descriptor (see src/browser/tests/descriptor_kind.html).
_drawing_buffer_color_space: ColorSpace = .srgb,
_unpack_color_space: ColorSpace = .srgb,
/// The dictionary this context was created from. See context_attributes.zig
/// for the two members WebGL is asked for and never grants.
_attributes: attributes.Gl = .{},

/// Whether this context has asked for WEBGL_debug_renderer_info, which gates
/// the only two `getParameter` pnames that name a real GPU. Chrome answers
/// null for 37445 and 37446 until the extension has been requested, and the
/// gate is per-context: enabling it on one context leaves every other one
/// still answering null (measured, Chrome 150). See getParameter below.
_debug_renderer_info: bool = false,

/// WebIDL `PredefinedColorSpace`, whose only two members these attributes take.
/// Chrome *ignores* an out-of-range string rather than throwing the TypeError a
/// WebIDL enum would normally produce -- measured, probe-setter-semantics.
pub const ColorSpace = enum {
    srgb,
    @"display-p3",
};

/// Either kind of canvas can own a WebGL context: Chrome hands one back for
/// `new OffscreenCanvas(256, 256).getContext('webgl')` too (measured, on the
/// main thread and inside a worker), and `gl.canvas` is then the
/// OffscreenCanvas itself.
pub const Surface = union(enum) {
    html: *Canvas,
    offscreen: *OffscreenCanvas,

    pub fn width(self: Surface) u32 {
        return switch (self) {
            inline else => |canvas| canvas.getWidth(),
        };
    }

    pub fn height(self: Surface) u32 {
        return switch (self) {
            inline else => |canvas| canvas.getHeight(),
        };
    }
};

/// What `getSupportedExtensions` answers, in Chrome's order — 35 names on the
/// Linux build this engine claims to be, against 39 on macOS. The four that are
/// absent here (EXT_disjoint_timer_query, KHR_parallel_shader_compile,
/// WEBGL_blend_func_extended, WEBGL_compressed_texture_pvrtc) are the driver's
/// to advertise, not the browser's, so the list has to be measured per platform
/// rather than taken from a spec page. MDN's list is shorter still:
/// https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Using_Extensions#extension_list
pub const Extension = union(enum) {
    ANGLE_instanced_arrays: *extensions.ANGLE_instanced_arrays,
    EXT_blend_minmax: *extensions.EXT_blend_minmax,
    EXT_clip_control: *extensions.EXT_clip_control,
    EXT_color_buffer_half_float: *extensions.EXT_color_buffer_half_float,
    EXT_depth_clamp: *extensions.EXT_depth_clamp,
    EXT_disjoint_timer_query: *extensions.EXT_disjoint_timer_query,
    EXT_float_blend: *extensions.EXT_float_blend,
    EXT_frag_depth: *extensions.EXT_frag_depth,
    EXT_polygon_offset_clamp: *extensions.EXT_polygon_offset_clamp,
    EXT_shader_texture_lod: *extensions.EXT_shader_texture_lod,
    EXT_texture_compression_bptc: *extensions.EXT_texture_compression_bptc,
    EXT_texture_compression_rgtc: *extensions.EXT_texture_compression_rgtc,
    EXT_texture_filter_anisotropic: *extensions.EXT_texture_filter_anisotropic,
    EXT_texture_mirror_clamp_to_edge: *extensions.EXT_texture_mirror_clamp_to_edge,
    EXT_sRGB: *extensions.EXT_sRGB,
    KHR_parallel_shader_compile: *extensions.KHR_parallel_shader_compile,
    OES_element_index_uint: *extensions.OES_element_index_uint,
    OES_fbo_render_mipmap: *extensions.OES_fbo_render_mipmap,
    OES_standard_derivatives: *extensions.OES_standard_derivatives,
    OES_texture_float: *extensions.OES_texture_float,
    OES_texture_float_linear: *extensions.OES_texture_float_linear,
    OES_texture_half_float: *extensions.OES_texture_half_float,
    OES_texture_half_float_linear: *extensions.OES_texture_half_float_linear,
    OES_vertex_array_object: *extensions.OES_vertex_array_object,
    WEBGL_blend_func_extended: *extensions.WEBGL_blend_func_extended,
    WEBGL_color_buffer_float: *extensions.WEBGL_color_buffer_float,
    WEBGL_compressed_texture_astc: *extensions.WEBGL_compressed_texture_astc,
    WEBGL_compressed_texture_etc: *extensions.WEBGL_compressed_texture_etc,
    WEBGL_compressed_texture_etc1: *extensions.WEBGL_compressed_texture_etc1,
    WEBGL_compressed_texture_pvrtc: *extensions.WEBGL_compressed_texture_pvrtc,
    WEBGL_compressed_texture_s3tc: *extensions.WEBGL_compressed_texture_s3tc,
    WEBGL_compressed_texture_s3tc_srgb: *extensions.WEBGL_compressed_texture_s3tc_srgb,
    WEBGL_debug_renderer_info: *extensions.WEBGL_debug_renderer_info,
    WEBGL_debug_shaders: *extensions.WEBGL_debug_shaders,
    WEBGL_depth_texture: *extensions.WEBGL_depth_texture,
    WEBGL_draw_buffers: *extensions.WEBGL_draw_buffers,
    WEBGL_lose_context: *extensions.WEBGL_lose_context,
    WEBGL_multi_draw: *extensions.WEBGL_multi_draw,
    WEBGL_polygon_mode: *extensions.WEBGL_polygon_mode,

    /// Reified enum type from the fields of this union. WebGL 2 has its own
    /// union and the same need, so the reification lives in webgl_extensions.zig
    /// rather than once per context.
    const Kind = extensions.Kind(Extension);

    /// Returns the `Extension.Kind` by its name, case-insensitively.
    fn find(name: []const u8) ?Kind {
        return extensions.find(Extension, name);
    }

    /// Extension types, all 53 of them generated from a measurement of
    /// the reference Chrome. See webgl_extensions.zig.
    pub const Type = extensions;
};

// The GLenum constants, and every `getParameter` answer below, are transcribed
// from a measurement of the real Chrome on a macOS/ARM host rather than from the
// WebGL spec: the spec fixes the enum numbering but says nothing about what a
// given driver reports for MAX_TEXTURE_SIZE, SAMPLES or the renderer strings,
// and those are exactly the values a fingerprinting script reads. See
// tools/fingerprint/README.md for how the reference snapshot is produced.
pub const DEPTH_BUFFER_BIT: u32 = 0x0100;
pub const STENCIL_BUFFER_BIT: u32 = 0x0400;
pub const COLOR_BUFFER_BIT: u32 = 0x4000;
pub const POINTS: u32 = 0x0000;
pub const LINES: u32 = 0x0001;
pub const LINE_LOOP: u32 = 0x0002;
pub const LINE_STRIP: u32 = 0x0003;
pub const TRIANGLES: u32 = 0x0004;
pub const TRIANGLE_STRIP: u32 = 0x0005;
pub const TRIANGLE_FAN: u32 = 0x0006;
pub const ZERO: u32 = 0x0000;
pub const ONE: u32 = 0x0001;
pub const SRC_COLOR: u32 = 0x0300;
pub const ONE_MINUS_SRC_COLOR: u32 = 0x0301;
pub const SRC_ALPHA: u32 = 0x0302;
pub const ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
pub const DST_ALPHA: u32 = 0x0304;
pub const ONE_MINUS_DST_ALPHA: u32 = 0x0305;
pub const DST_COLOR: u32 = 0x0306;
pub const ONE_MINUS_DST_COLOR: u32 = 0x0307;
pub const SRC_ALPHA_SATURATE: u32 = 0x0308;
pub const FUNC_ADD: u32 = 0x8006;
pub const BLEND_EQUATION: u32 = 0x8009;
pub const BLEND_EQUATION_RGB: u32 = 0x8009;
pub const BLEND_EQUATION_ALPHA: u32 = 0x883D;
pub const FUNC_SUBTRACT: u32 = 0x800A;
pub const FUNC_REVERSE_SUBTRACT: u32 = 0x800B;
pub const BLEND_DST_RGB: u32 = 0x80C8;
pub const BLEND_SRC_RGB: u32 = 0x80C9;
pub const BLEND_DST_ALPHA: u32 = 0x80CA;
pub const BLEND_SRC_ALPHA: u32 = 0x80CB;
pub const CONSTANT_COLOR: u32 = 0x8001;
pub const ONE_MINUS_CONSTANT_COLOR: u32 = 0x8002;
pub const CONSTANT_ALPHA: u32 = 0x8003;
pub const ONE_MINUS_CONSTANT_ALPHA: u32 = 0x8004;
pub const BLEND_COLOR: u32 = 0x8005;
pub const ARRAY_BUFFER: u32 = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: u32 = 0x8893;
pub const ARRAY_BUFFER_BINDING: u32 = 0x8894;
pub const ELEMENT_ARRAY_BUFFER_BINDING: u32 = 0x8895;
pub const STREAM_DRAW: u32 = 0x88E0;
pub const STATIC_DRAW: u32 = 0x88E4;
pub const DYNAMIC_DRAW: u32 = 0x88E8;
pub const BUFFER_SIZE: u32 = 0x8764;
pub const BUFFER_USAGE: u32 = 0x8765;
pub const CURRENT_VERTEX_ATTRIB: u32 = 0x8626;
pub const FRONT: u32 = 0x0404;
pub const BACK: u32 = 0x0405;
pub const FRONT_AND_BACK: u32 = 0x0408;
pub const TEXTURE_2D: u32 = 0x0DE1;
pub const CULL_FACE: u32 = 0x0B44;
pub const BLEND: u32 = 0x0BE2;
pub const DITHER: u32 = 0x0BD0;
pub const STENCIL_TEST: u32 = 0x0B90;
pub const DEPTH_TEST: u32 = 0x0B71;
pub const SCISSOR_TEST: u32 = 0x0C11;
pub const POLYGON_OFFSET_FILL: u32 = 0x8037;
pub const SAMPLE_ALPHA_TO_COVERAGE: u32 = 0x809E;
pub const SAMPLE_COVERAGE: u32 = 0x80A0;
pub const NO_ERROR: u32 = 0x0000;
pub const INVALID_ENUM: u32 = 0x0500;
pub const INVALID_VALUE: u32 = 0x0501;
pub const INVALID_OPERATION: u32 = 0x0502;
pub const OUT_OF_MEMORY: u32 = 0x0505;
pub const CW: u32 = 0x0900;
pub const CCW: u32 = 0x0901;
pub const LINE_WIDTH: u32 = 0x0B21;
pub const ALIASED_POINT_SIZE_RANGE: u32 = 0x846D;
pub const ALIASED_LINE_WIDTH_RANGE: u32 = 0x846E;
pub const CULL_FACE_MODE: u32 = 0x0B45;
pub const FRONT_FACE: u32 = 0x0B46;
pub const DEPTH_RANGE: u32 = 0x0B70;
pub const DEPTH_WRITEMASK: u32 = 0x0B72;
pub const DEPTH_CLEAR_VALUE: u32 = 0x0B73;
pub const DEPTH_FUNC: u32 = 0x0B74;
pub const STENCIL_CLEAR_VALUE: u32 = 0x0B91;
pub const STENCIL_FUNC: u32 = 0x0B92;
pub const STENCIL_FAIL: u32 = 0x0B94;
pub const STENCIL_PASS_DEPTH_FAIL: u32 = 0x0B95;
pub const STENCIL_PASS_DEPTH_PASS: u32 = 0x0B96;
pub const STENCIL_REF: u32 = 0x0B97;
pub const STENCIL_VALUE_MASK: u32 = 0x0B93;
pub const STENCIL_WRITEMASK: u32 = 0x0B98;
pub const STENCIL_BACK_FUNC: u32 = 0x8800;
pub const STENCIL_BACK_FAIL: u32 = 0x8801;
pub const STENCIL_BACK_PASS_DEPTH_FAIL: u32 = 0x8802;
pub const STENCIL_BACK_PASS_DEPTH_PASS: u32 = 0x8803;
pub const STENCIL_BACK_REF: u32 = 0x8CA3;
pub const STENCIL_BACK_VALUE_MASK: u32 = 0x8CA4;
pub const STENCIL_BACK_WRITEMASK: u32 = 0x8CA5;
pub const VIEWPORT: u32 = 0x0BA2;
pub const SCISSOR_BOX: u32 = 0x0C10;
pub const COLOR_CLEAR_VALUE: u32 = 0x0C22;
pub const COLOR_WRITEMASK: u32 = 0x0C23;
pub const UNPACK_ALIGNMENT: u32 = 0x0CF5;
pub const PACK_ALIGNMENT: u32 = 0x0D05;
pub const MAX_TEXTURE_SIZE: u32 = 0x0D33;
pub const MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
pub const SUBPIXEL_BITS: u32 = 0x0D50;
pub const RED_BITS: u32 = 0x0D52;
pub const GREEN_BITS: u32 = 0x0D53;
pub const BLUE_BITS: u32 = 0x0D54;
pub const ALPHA_BITS: u32 = 0x0D55;
pub const DEPTH_BITS: u32 = 0x0D56;
pub const STENCIL_BITS: u32 = 0x0D57;
pub const POLYGON_OFFSET_UNITS: u32 = 0x2A00;
pub const POLYGON_OFFSET_FACTOR: u32 = 0x8038;
pub const TEXTURE_BINDING_2D: u32 = 0x8069;
pub const SAMPLE_BUFFERS: u32 = 0x80A8;
pub const SAMPLES: u32 = 0x80A9;
pub const SAMPLE_COVERAGE_VALUE: u32 = 0x80AA;
pub const SAMPLE_COVERAGE_INVERT: u32 = 0x80AB;
pub const COMPRESSED_TEXTURE_FORMATS: u32 = 0x86A3;
pub const DONT_CARE: u32 = 0x1100;
pub const FASTEST: u32 = 0x1101;
pub const NICEST: u32 = 0x1102;
pub const GENERATE_MIPMAP_HINT: u32 = 0x8192;
pub const BYTE: u32 = 0x1400;
pub const UNSIGNED_BYTE: u32 = 0x1401;
pub const SHORT: u32 = 0x1402;
pub const UNSIGNED_SHORT: u32 = 0x1403;
pub const INT: u32 = 0x1404;
pub const UNSIGNED_INT: u32 = 0x1405;
pub const FLOAT: u32 = 0x1406;
pub const DEPTH_COMPONENT: u32 = 0x1902;
pub const ALPHA: u32 = 0x1906;
pub const RGB: u32 = 0x1907;
pub const RGBA: u32 = 0x1908;
pub const LUMINANCE: u32 = 0x1909;
pub const LUMINANCE_ALPHA: u32 = 0x190A;
pub const UNSIGNED_SHORT_4_4_4_4: u32 = 0x8033;
pub const UNSIGNED_SHORT_5_5_5_1: u32 = 0x8034;
pub const UNSIGNED_SHORT_5_6_5: u32 = 0x8363;
pub const FRAGMENT_SHADER: u32 = 0x8B30;
pub const VERTEX_SHADER: u32 = 0x8B31;
pub const MAX_VERTEX_ATTRIBS: u32 = 0x8869;
pub const MAX_VERTEX_UNIFORM_VECTORS: u32 = 0x8DFB;
pub const MAX_VARYING_VECTORS: u32 = 0x8DFC;
pub const MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
pub const MAX_VERTEX_TEXTURE_IMAGE_UNITS: u32 = 0x8B4C;
pub const MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
pub const MAX_FRAGMENT_UNIFORM_VECTORS: u32 = 0x8DFD;
pub const SHADER_TYPE: u32 = 0x8B4F;
pub const DELETE_STATUS: u32 = 0x8B80;
pub const LINK_STATUS: u32 = 0x8B82;
pub const VALIDATE_STATUS: u32 = 0x8B83;
pub const ATTACHED_SHADERS: u32 = 0x8B85;
pub const ACTIVE_UNIFORMS: u32 = 0x8B86;
pub const ACTIVE_ATTRIBUTES: u32 = 0x8B89;
pub const SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;
pub const CURRENT_PROGRAM: u32 = 0x8B8D;
pub const NEVER: u32 = 0x0200;
pub const LESS: u32 = 0x0201;
pub const EQUAL: u32 = 0x0202;
pub const LEQUAL: u32 = 0x0203;
pub const GREATER: u32 = 0x0204;
pub const NOTEQUAL: u32 = 0x0205;
pub const GEQUAL: u32 = 0x0206;
pub const ALWAYS: u32 = 0x0207;
pub const KEEP: u32 = 0x1E00;
pub const REPLACE: u32 = 0x1E01;
pub const INCR: u32 = 0x1E02;
pub const DECR: u32 = 0x1E03;
pub const INVERT: u32 = 0x150A;
pub const INCR_WRAP: u32 = 0x8507;
pub const DECR_WRAP: u32 = 0x8508;
pub const VENDOR: u32 = 0x1F00;
pub const RENDERER: u32 = 0x1F01;
pub const VERSION: u32 = 0x1F02;
pub const NEAREST: u32 = 0x2600;
pub const LINEAR: u32 = 0x2601;
pub const NEAREST_MIPMAP_NEAREST: u32 = 0x2700;
pub const LINEAR_MIPMAP_NEAREST: u32 = 0x2701;
pub const NEAREST_MIPMAP_LINEAR: u32 = 0x2702;
pub const LINEAR_MIPMAP_LINEAR: u32 = 0x2703;
pub const TEXTURE_MAG_FILTER: u32 = 0x2800;
pub const TEXTURE_MIN_FILTER: u32 = 0x2801;
pub const TEXTURE_WRAP_S: u32 = 0x2802;
pub const TEXTURE_WRAP_T: u32 = 0x2803;
pub const TEXTURE: u32 = 0x1702;
pub const TEXTURE_CUBE_MAP: u32 = 0x8513;
pub const TEXTURE_BINDING_CUBE_MAP: u32 = 0x8514;
pub const TEXTURE_CUBE_MAP_POSITIVE_X: u32 = 0x8515;
pub const TEXTURE_CUBE_MAP_NEGATIVE_X: u32 = 0x8516;
pub const TEXTURE_CUBE_MAP_POSITIVE_Y: u32 = 0x8517;
pub const TEXTURE_CUBE_MAP_NEGATIVE_Y: u32 = 0x8518;
pub const TEXTURE_CUBE_MAP_POSITIVE_Z: u32 = 0x8519;
pub const TEXTURE_CUBE_MAP_NEGATIVE_Z: u32 = 0x851A;
pub const MAX_CUBE_MAP_TEXTURE_SIZE: u32 = 0x851C;
pub const TEXTURE0: u32 = 0x84C0;
pub const TEXTURE1: u32 = 0x84C1;
pub const TEXTURE2: u32 = 0x84C2;
pub const TEXTURE3: u32 = 0x84C3;
pub const TEXTURE4: u32 = 0x84C4;
pub const TEXTURE5: u32 = 0x84C5;
pub const TEXTURE6: u32 = 0x84C6;
pub const TEXTURE7: u32 = 0x84C7;
pub const TEXTURE8: u32 = 0x84C8;
pub const TEXTURE9: u32 = 0x84C9;
pub const TEXTURE10: u32 = 0x84CA;
pub const TEXTURE11: u32 = 0x84CB;
pub const TEXTURE12: u32 = 0x84CC;
pub const TEXTURE13: u32 = 0x84CD;
pub const TEXTURE14: u32 = 0x84CE;
pub const TEXTURE15: u32 = 0x84CF;
pub const TEXTURE16: u32 = 0x84D0;
pub const TEXTURE17: u32 = 0x84D1;
pub const TEXTURE18: u32 = 0x84D2;
pub const TEXTURE19: u32 = 0x84D3;
pub const TEXTURE20: u32 = 0x84D4;
pub const TEXTURE21: u32 = 0x84D5;
pub const TEXTURE22: u32 = 0x84D6;
pub const TEXTURE23: u32 = 0x84D7;
pub const TEXTURE24: u32 = 0x84D8;
pub const TEXTURE25: u32 = 0x84D9;
pub const TEXTURE26: u32 = 0x84DA;
pub const TEXTURE27: u32 = 0x84DB;
pub const TEXTURE28: u32 = 0x84DC;
pub const TEXTURE29: u32 = 0x84DD;
pub const TEXTURE30: u32 = 0x84DE;
pub const TEXTURE31: u32 = 0x84DF;
pub const ACTIVE_TEXTURE: u32 = 0x84E0;
pub const REPEAT: u32 = 0x2901;
pub const CLAMP_TO_EDGE: u32 = 0x812F;
pub const MIRRORED_REPEAT: u32 = 0x8370;
pub const FLOAT_VEC2: u32 = 0x8B50;
pub const FLOAT_VEC3: u32 = 0x8B51;
pub const FLOAT_VEC4: u32 = 0x8B52;
pub const INT_VEC2: u32 = 0x8B53;
pub const INT_VEC3: u32 = 0x8B54;
pub const INT_VEC4: u32 = 0x8B55;
pub const BOOL: u32 = 0x8B56;
pub const BOOL_VEC2: u32 = 0x8B57;
pub const BOOL_VEC3: u32 = 0x8B58;
pub const BOOL_VEC4: u32 = 0x8B59;
pub const FLOAT_MAT2: u32 = 0x8B5A;
pub const FLOAT_MAT3: u32 = 0x8B5B;
pub const FLOAT_MAT4: u32 = 0x8B5C;
pub const SAMPLER_2D: u32 = 0x8B5E;
pub const SAMPLER_CUBE: u32 = 0x8B60;
pub const VERTEX_ATTRIB_ARRAY_ENABLED: u32 = 0x8622;
pub const VERTEX_ATTRIB_ARRAY_SIZE: u32 = 0x8623;
pub const VERTEX_ATTRIB_ARRAY_STRIDE: u32 = 0x8624;
pub const VERTEX_ATTRIB_ARRAY_TYPE: u32 = 0x8625;
pub const VERTEX_ATTRIB_ARRAY_NORMALIZED: u32 = 0x886A;
pub const VERTEX_ATTRIB_ARRAY_POINTER: u32 = 0x8645;
pub const VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: u32 = 0x889F;
pub const IMPLEMENTATION_COLOR_READ_TYPE: u32 = 0x8B9A;
pub const IMPLEMENTATION_COLOR_READ_FORMAT: u32 = 0x8B9B;
pub const COMPILE_STATUS: u32 = 0x8B81;
pub const LOW_FLOAT: u32 = 0x8DF0;
pub const MEDIUM_FLOAT: u32 = 0x8DF1;
pub const HIGH_FLOAT: u32 = 0x8DF2;
pub const LOW_INT: u32 = 0x8DF3;
pub const MEDIUM_INT: u32 = 0x8DF4;
pub const HIGH_INT: u32 = 0x8DF5;
pub const FRAMEBUFFER: u32 = 0x8D40;
pub const RENDERBUFFER: u32 = 0x8D41;
pub const RGBA4: u32 = 0x8056;
pub const RGB5_A1: u32 = 0x8057;
pub const RGB565: u32 = 0x8D62;
pub const DEPTH_COMPONENT16: u32 = 0x81A5;
pub const STENCIL_INDEX8: u32 = 0x8D48;
pub const DEPTH_STENCIL: u32 = 0x84F9;
pub const RENDERBUFFER_WIDTH: u32 = 0x8D42;
pub const RENDERBUFFER_HEIGHT: u32 = 0x8D43;
pub const RENDERBUFFER_INTERNAL_FORMAT: u32 = 0x8D44;
pub const RENDERBUFFER_RED_SIZE: u32 = 0x8D50;
pub const RENDERBUFFER_GREEN_SIZE: u32 = 0x8D51;
pub const RENDERBUFFER_BLUE_SIZE: u32 = 0x8D52;
pub const RENDERBUFFER_ALPHA_SIZE: u32 = 0x8D53;
pub const RENDERBUFFER_DEPTH_SIZE: u32 = 0x8D54;
pub const RENDERBUFFER_STENCIL_SIZE: u32 = 0x8D55;
pub const FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: u32 = 0x8CD0;
pub const FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: u32 = 0x8CD1;
pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: u32 = 0x8CD2;
pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE: u32 = 0x8CD3;
pub const COLOR_ATTACHMENT0: u32 = 0x8CE0;
pub const DEPTH_ATTACHMENT: u32 = 0x8D00;
pub const STENCIL_ATTACHMENT: u32 = 0x8D20;
pub const DEPTH_STENCIL_ATTACHMENT: u32 = 0x821A;
pub const NONE: u32 = 0x0000;
pub const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
pub const FRAMEBUFFER_INCOMPLETE_ATTACHMENT: u32 = 0x8CD6;
pub const FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT: u32 = 0x8CD7;
pub const FRAMEBUFFER_INCOMPLETE_DIMENSIONS: u32 = 0x8CD9;
pub const FRAMEBUFFER_UNSUPPORTED: u32 = 0x8CDD;
pub const FRAMEBUFFER_BINDING: u32 = 0x8CA6;
pub const RENDERBUFFER_BINDING: u32 = 0x8CA7;
pub const MAX_RENDERBUFFER_SIZE: u32 = 0x84E8;
pub const INVALID_FRAMEBUFFER_OPERATION: u32 = 0x0506;
pub const UNPACK_FLIP_Y_WEBGL: u32 = 0x9240;
pub const UNPACK_PREMULTIPLY_ALPHA_WEBGL: u32 = 0x9241;
pub const CONTEXT_LOST_WEBGL: u32 = 0x9242;
pub const UNPACK_COLORSPACE_CONVERSION_WEBGL: u32 = 0x9243;
pub const BROWSER_DEFAULT_WEBGL: u32 = 0x9244;
pub const RGB8: u32 = 0x8051;
pub const RGBA8: u32 = 0x8058;

pub fn getCanvas(self: *const WebGLRenderingContext) Surface {
    return self._canvas;
}

// Chrome reports the canvas' bitmap size here, not the CSS box, so this tracks
// the width/height attributes.
pub fn getDrawingBufferWidth(self: *const WebGLRenderingContext) u32 {
    return self._canvas.width();
}

pub fn getDrawingBufferHeight(self: *const WebGLRenderingContext) u32 {
    return self._canvas.height();
}

// Chrome answers RGBA8 (0x8058) for the default drawing buffer, and answers it
// from a getter with no setter.
pub fn getDrawingBufferFormat(_: *const WebGLRenderingContext) u32 {
    return RGBA8;
}

pub fn getDrawingBufferColorSpace(self: *const WebGLRenderingContext) []const u8 {
    return @tagName(self._drawing_buffer_color_space);
}

pub fn setDrawingBufferColorSpace(self: *WebGLRenderingContext, value: []const u8) void {
    if (std.meta.stringToEnum(ColorSpace, value)) |cs| {
        self._drawing_buffer_color_space = cs;
    }
}

pub fn getUnpackColorSpace(self: *const WebGLRenderingContext) []const u8 {
    return @tagName(self._unpack_color_space);
}

pub fn setUnpackColorSpace(self: *WebGLRenderingContext, value: []const u8) void {
    if (std.meta.stringToEnum(ColorSpace, value)) |cs| {
        self._unpack_color_space = cs;
    }
}

/// The value `getParameter` answers with. Chrome's return type is a union of
/// GLenum/GLint (number), DOMString, GLboolean and several typed arrays; the
/// typed-array cases go through `.value` because only a `js.Value` can carry an
/// unpersisted typed array back to the caller.
const Parameter = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    /// COLOR_WRITEMASK is a plain JS array of booleans, not a typed array.
    booleans: []const bool,
    value: js.Value,
};

fn floatArray(exec: *Execution, values: []const f32) Parameter {
    const local = exec.js.local.?;
    const array = local.createTypedArray(.float32, values.len);
    @memcpy(array.slice(), values);
    return .{ .value = .{ .local = local, .handle = array.handle } };
}

fn intArray(exec: *Execution, values: []const i32) Parameter {
    const local = exec.js.local.?;
    const array = local.createTypedArray(.int32, values.len);
    @memcpy(array.slice(), values);
    return .{ .value = .{ .local = local, .handle = array.handle } };
}

fn uintArray(exec: *Execution, values: []const u32) Parameter {
    const local = exec.js.local.?;
    const array = local.createTypedArray(.uint32, values.len);
    @memcpy(array.slice(), values);
    return .{ .value = .{ .local = local, .handle = array.handle } };
}

fn boolArray(values: []const bool) Parameter {
    return .{ .booleans = values };
}

/// `pname` is a GLenum. Chrome answers `null` (and raises INVALID_ENUM) for any
/// enum that isn't a gettable state variable, which is most of them — only the
/// 85 prongs below are real parameters.
pub fn getParameter(self: *const WebGLRenderingContext, pname: u32, exec: *Execution) !?Parameter {
    const answer: ?Parameter = switch (pname) {
        // --- numbers ---
        BLEND_EQUATION => .{ .number = 32774 },
        BLEND_EQUATION_ALPHA => .{ .number = 32774 },
        BLEND_DST_RGB => .{ .number = 0 },
        BLEND_SRC_RGB => .{ .number = 1 },
        BLEND_DST_ALPHA => .{ .number = 0 },
        BLEND_SRC_ALPHA => .{ .number = 1 },
        LINE_WIDTH => .{ .number = 1 },
        CULL_FACE_MODE => .{ .number = 1029 },
        FRONT_FACE => .{ .number = 2305 },
        DEPTH_CLEAR_VALUE => .{ .number = 1 },
        DEPTH_FUNC => .{ .number = 513 },
        STENCIL_CLEAR_VALUE => .{ .number = 0 },
        STENCIL_FUNC => .{ .number = 519 },
        STENCIL_FAIL => .{ .number = 7680 },
        STENCIL_PASS_DEPTH_FAIL => .{ .number = 7680 },
        STENCIL_PASS_DEPTH_PASS => .{ .number = 7680 },
        STENCIL_REF => .{ .number = 0 },
        STENCIL_VALUE_MASK => .{ .number = 4294967295 },
        STENCIL_WRITEMASK => .{ .number = 4294967295 },
        STENCIL_BACK_FUNC => .{ .number = 519 },
        STENCIL_BACK_FAIL => .{ .number = 7680 },
        STENCIL_BACK_PASS_DEPTH_FAIL => .{ .number = 7680 },
        STENCIL_BACK_PASS_DEPTH_PASS => .{ .number = 7680 },
        STENCIL_BACK_REF => .{ .number = 0 },
        STENCIL_BACK_VALUE_MASK => .{ .number = 4294967295 },
        STENCIL_BACK_WRITEMASK => .{ .number = 4294967295 },
        UNPACK_ALIGNMENT => .{ .number = 4 },
        PACK_ALIGNMENT => .{ .number = 4 },
        MAX_TEXTURE_SIZE => .{ .number = gpu.max_texture_size },
        SUBPIXEL_BITS => .{ .number = 4 },
        RED_BITS => .{ .number = 8 },
        GREEN_BITS => .{ .number = 8 },
        BLUE_BITS => .{ .number = 8 },
        ALPHA_BITS => .{ .number = 8 },
        DEPTH_BITS => .{ .number = 24 },
        STENCIL_BITS => .{ .number = 0 },
        POLYGON_OFFSET_UNITS => .{ .number = 0 },
        POLYGON_OFFSET_FACTOR => .{ .number = 0 },
        SAMPLE_BUFFERS => .{ .number = 1 },
        SAMPLES => .{ .number = 4 },
        SAMPLE_COVERAGE_VALUE => .{ .number = 1 },
        GENERATE_MIPMAP_HINT => .{ .number = 4352 },
        MAX_VERTEX_ATTRIBS => .{ .number = 16 },
        MAX_VERTEX_UNIFORM_VECTORS => .{ .number = gpu.max_vertex_uniform_vectors },
        MAX_VARYING_VECTORS => .{ .number = gpu.max_varying_vectors },
        MAX_COMBINED_TEXTURE_IMAGE_UNITS => .{ .number = gpu.max_combined_texture_image_units },
        MAX_VERTEX_TEXTURE_IMAGE_UNITS => .{ .number = gpu.max_vertex_texture_image_units },
        MAX_TEXTURE_IMAGE_UNITS => .{ .number = gpu.max_texture_image_units },
        MAX_FRAGMENT_UNIFORM_VECTORS => .{ .number = gpu.max_fragment_uniform_vectors },
        MAX_CUBE_MAP_TEXTURE_SIZE => .{ .number = 16384 },
        ACTIVE_TEXTURE => .{ .number = 33984 },
        IMPLEMENTATION_COLOR_READ_TYPE => .{ .number = 5121 },
        IMPLEMENTATION_COLOR_READ_FORMAT => .{ .number = 6408 },
        MAX_RENDERBUFFER_SIZE => .{ .number = gpu.max_renderbuffer_size },
        UNPACK_COLORSPACE_CONVERSION_WEBGL => .{ .number = 37444 },
        // --- strings ---
        SHADING_LANGUAGE_VERSION => .{ .string = "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)" },
        VENDOR => .{ .string = "WebKit" },
        RENDERER => .{ .string = "WebKit WebGL" },
        VERSION => .{ .string = "WebGL 1.0 (OpenGL ES 2.0 Chromium)" },
        // --- booleans ---
        CULL_FACE => .{ .boolean = false },
        BLEND => .{ .boolean = false },
        DITHER => .{ .boolean = true },
        STENCIL_TEST => .{ .boolean = false },
        DEPTH_TEST => .{ .boolean = false },
        SCISSOR_TEST => .{ .boolean = false },
        POLYGON_OFFSET_FILL => .{ .boolean = false },
        SAMPLE_ALPHA_TO_COVERAGE => .{ .boolean = false },
        SAMPLE_COVERAGE => .{ .boolean = false },
        DEPTH_WRITEMASK => .{ .boolean = true },
        SAMPLE_COVERAGE_INVERT => .{ .boolean = false },
        UNPACK_FLIP_Y_WEBGL => .{ .boolean = false },
        UNPACK_PREMULTIPLY_ALPHA_WEBGL => .{ .boolean = false },
        // --- float32 arrays ---
        BLEND_COLOR => floatArray(exec, &.{ 0, 0, 0, 0 }),
        ALIASED_POINT_SIZE_RANGE => floatArray(exec, &.{ 1, gpu.aliased_point_size_max }),
        ALIASED_LINE_WIDTH_RANGE => floatArray(exec, &.{ 1, 1 }),
        DEPTH_RANGE => floatArray(exec, &.{ 0, 1 }),
        COLOR_CLEAR_VALUE => floatArray(exec, &.{ 0, 0, 0, 0 }),
        // --- int32 arrays ---
        VIEWPORT, SCISSOR_BOX => intArray(exec, &.{ 0, 0, @intCast(self._canvas.width()), @intCast(self._canvas.height()) }),
        MAX_VIEWPORT_DIMS => intArray(exec, &.{ gpu.max_viewport_dim, gpu.max_viewport_dim }),
        // --- uint32 arrays ---
        COMPRESSED_TEXTURE_FORMATS => uintArray(exec, &.{}),
        // --- bool vectors ---
        COLOR_WRITEMASK => boolArray(&.{ true, true, true, true }),
        // WEBGL_debug_renderer_info. Chrome exposes the true GPU behind ANGLE
        // here, which is the single most identifying pair of strings on the
        // whole WebGL surface, so it has to come from the reference snapshot --
        // but only once this context has asked for the extension that names
        // these two pnames. Unasked, Chrome answers null and treats the read as
        // an invalid enum; answering the GPU anyway is a tell in one expression,
        // and Kasada spent 138 of its 152 getParameter calls on 37446 alone.
        Extension.Type.WEBGL_debug_renderer_info.UNMASKED_VENDOR_WEBGL => if (self._debug_renderer_info) .{ .string = gpu.unmasked_vendor } else null,
        Extension.Type.WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL => if (self._debug_renderer_info) .{ .string = gpu.unmasked_renderer } else null,
        else => null,
    };

    // Keyed off the answer's type rather than a list of enums, so a string
    // added to the switch later cannot be the one that answers for free.
    if (answer) |a| switch (a) {
        .string => gpu_table.chargeStringQuery(),
        else => {},
    };
    return answer;
}

/// Enables a WebGL extension.
pub fn getExtension(self: *WebGLRenderingContext, name: []const u8, exec: *Execution) !?Extension {
    const tag = Extension.find(name) orelse return null;

    // A name this driver does not advertise answers null, the way Chrome does
    // for an extension the GPU does not have. Without this the engine would hand
    // out an extension it had just left off getSupportedExtensions.
    for (gpu.webgl1_unsupported) |unsupported| {
        if (std.mem.eql(u8, unsupported, @tagName(tag))) {
            return null;
        }
    }

    // Opens the getParameter gate, and only for this context.
    if (tag == .WEBGL_debug_renderer_info) {
        self._debug_renderer_info = true;
    }

    // Every extension answers with its own interface object: Chrome has one per
    // extension and a script that feature-detects with `if (gl.getExtension(x))`
    // needs something truthy back.
    switch (tag) {
        inline else => |comptime_enum| {
            const T = @field(extensions, @tagName(comptime_enum));
            const object = try exec._factory.create(T{});
            return @unionInit(Extension, @tagName(comptime_enum), object);
        },
    }
}

/// Every extension either reference Chrome advertises, in Chrome's order —
/// which is alphabetical, and is what the union's field order is kept in.
const all_extension_names: []const []const u8 = std.meta.fieldNames(Extension.Kind);

/// The subset the claimed platform's driver actually has. Four of the names
/// above are Apple-GPU only.
const advertised_extension_names = gpu_table.advertised(all_extension_names, gpu.webgl1_unsupported);

/// Returns a list of all the supported WebGL extensions.
pub fn getSupportedExtensions(_: *const WebGLRenderingContext) []const []const u8 {
    return advertised_extension_names;
}

// ---------------------------------------------------------------------------
// The calls. Nothing here touches a GPU: object-creating calls hand back a
// fresh opaque handle, queries answer what the reference Chrome answers for a
// context in this (never-drawn-into, nothing-bound) state, and the ~100 pure
// state setters below are no-ops. The point is that none of them throw — a
// consumer that feature-detects WebGL and then drives it gets a context that
// silently does nothing, instead of a TypeError on the first call.

pub fn createBuffer(_: *const WebGLRenderingContext, exec: *Execution) !*objects.WebGLBuffer {
    return objects.handle(objects.WebGLBuffer, exec);
}

pub fn createFramebuffer(_: *const WebGLRenderingContext, exec: *Execution) !*objects.WebGLFramebuffer {
    return objects.handle(objects.WebGLFramebuffer, exec);
}

pub fn createProgram(_: *const WebGLRenderingContext, exec: *Execution) !*objects.WebGLProgram {
    return objects.handle(objects.WebGLProgram, exec);
}

pub fn createRenderbuffer(_: *const WebGLRenderingContext, exec: *Execution) !*objects.WebGLRenderbuffer {
    return objects.handle(objects.WebGLRenderbuffer, exec);
}

/// The stage is fixed here and read back through SHADER_TYPE, so a program
/// that attaches two fragment shaders is one that does not link.
pub fn createShader(_: *const WebGLRenderingContext, kind: u32, exec: *Execution) !*objects.WebGLShader {
    return objects.handleInit(objects.WebGLShader, exec, .{ ._proto = undefined, ._kind = kind });
}

pub fn createTexture(_: *const WebGLRenderingContext, exec: *Execution) !*objects.WebGLTexture {
    return objects.handle(objects.WebGLTexture, exec);
}

/// We never bind anything, so there is nothing to be incomplete about.
pub fn checkFramebufferStatus(_: *const WebGLRenderingContext, _: u32) u32 {
    return FRAMEBUFFER_COMPLETE;
}

/// No call of ours can fail, so there is never a pending error. Chrome reaches
/// INVALID_OPERATION here once a script misuses the API; we do not validate.
pub fn getError(_: *const WebGLRenderingContext) u32 {
    return NO_ERROR;
}

pub fn isContextLost(_: *const WebGLRenderingContext) bool {
    return false;
}

/// DITHER is the one capability enabled by default; see the getParameter
/// booleans above, which come from the same measurement.
pub fn isEnabled(_: *const WebGLRenderingContext, cap: u32) bool {
    return cap == DITHER;
}

// Chrome answers true only once the object has been bound at least once. We
// have no binding state, so any live handle reads as valid.
pub fn isBuffer(_: *const WebGLRenderingContext, buffer: ?*objects.WebGLBuffer) bool {
    return buffer != null;
}

pub fn isFramebuffer(_: *const WebGLRenderingContext, framebuffer: ?*objects.WebGLFramebuffer) bool {
    return framebuffer != null;
}

pub fn isProgram(_: *const WebGLRenderingContext, program: ?*objects.WebGLProgram) bool {
    return program != null;
}

pub fn isRenderbuffer(_: *const WebGLRenderingContext, renderbuffer: ?*objects.WebGLRenderbuffer) bool {
    return renderbuffer != null;
}

pub fn isShader(_: *const WebGLRenderingContext, shader: ?*objects.WebGLShader) bool {
    return shader != null;
}

pub fn isTexture(_: *const WebGLRenderingContext, texture: ?*objects.WebGLTexture) bool {
    return texture != null;
}

/// A compile or link that fails here fails for want of an interpreter, not for
/// want of valid GLSL, so there is no diagnostic to report that would resemble
/// the driver's. Chrome's log is empty for everything that succeeds, which is
/// the case the widget takes.
pub fn getShaderInfoLog(_: *const WebGLRenderingContext, _: ?*objects.WebGLShader) []const u8 {
    return "";
}

pub fn getProgramInfoLog(_: *const WebGLRenderingContext, _: ?*objects.WebGLProgram) []const u8 {
    return "";
}

pub fn getShaderSource(_: *const WebGLRenderingContext, shader: ?*objects.WebGLShader) []const u8 {
    return (shader orelse return "")._source;
}

pub fn getShaderParameter(_: *const WebGLRenderingContext, shader: ?*objects.WebGLShader, pname: u32) ?Parameter {
    const target = shader orelse return null;
    return switch (pname) {
        SHADER_TYPE => .{ .number = @floatFromInt(target._kind) },
        DELETE_STATUS => .{ .boolean = target._deleted },
        COMPILE_STATUS => .{ .boolean = target._program != null },
        else => null,
    };
}

pub fn getProgramParameter(self: *const WebGLRenderingContext, program: ?*objects.WebGLProgram, pname: u32) ?Parameter {
    const target = program orelse return null;
    return switch (pname) {
        DELETE_STATUS => .{ .boolean = target._deleted },
        LINK_STATUS => .{ .boolean = target._linked },
        VALIDATE_STATUS => .{ .boolean = target._validated },
        ATTACHED_SHADERS => .{ .number = @floatFromInt(self._gl.attachedShaders(target)) },
        ACTIVE_ATTRIBUTES => .{ .number = @floatFromInt(self._gl.activeAttributes(target)) },
        // No shader this interpreter compiles has a uniform: it has nothing to
        // feed one with.
        ACTIVE_UNIFORMS => .{ .number = 0 },
        else => null,
    };
}

pub fn getBufferParameter(_: *const WebGLRenderingContext, _: u32, pname: u32) ?Parameter {
    return switch (pname) {
        BUFFER_SIZE => .{ .number = 0 },
        BUFFER_USAGE => .{ .number = STATIC_DRAW },
        else => null,
    };
}

/// The default sampler state of a freshly bound 2D texture.
pub fn getTexParameter(_: *const WebGLRenderingContext, _: u32, pname: u32) ?Parameter {
    return switch (pname) {
        TEXTURE_MAG_FILTER => .{ .number = LINEAR },
        TEXTURE_MIN_FILTER => .{ .number = NEAREST_MIPMAP_LINEAR },
        TEXTURE_WRAP_S, TEXTURE_WRAP_T => .{ .number = REPEAT },
        else => null,
    };
}

/// A renderbuffer with no storage allocated yet.
pub fn getRenderbufferParameter(_: *const WebGLRenderingContext, _: u32, pname: u32) ?Parameter {
    return switch (pname) {
        RENDERBUFFER_WIDTH,
        RENDERBUFFER_HEIGHT,
        RENDERBUFFER_RED_SIZE,
        RENDERBUFFER_GREEN_SIZE,
        RENDERBUFFER_BLUE_SIZE,
        RENDERBUFFER_ALPHA_SIZE,
        RENDERBUFFER_DEPTH_SIZE,
        RENDERBUFFER_STENCIL_SIZE,
        => .{ .number = 0 },
        RENDERBUFFER_INTERNAL_FORMAT => .{ .number = RGBA4 },
        else => null,
    };
}

/// The default state of a generic vertex attribute array.
pub fn getVertexAttrib(_: *const WebGLRenderingContext, _: u32, pname: u32, exec: *Execution) ?Parameter {
    return switch (pname) {
        VERTEX_ATTRIB_ARRAY_ENABLED, VERTEX_ATTRIB_ARRAY_NORMALIZED => .{ .boolean = false },
        VERTEX_ATTRIB_ARRAY_SIZE => .{ .number = 4 },
        VERTEX_ATTRIB_ARRAY_STRIDE => .{ .number = 0 },
        VERTEX_ATTRIB_ARRAY_TYPE => .{ .number = FLOAT },
        CURRENT_VERTEX_ATTRIB => floatArray(exec, &.{ 0, 0, 0, 1 }),
        else => null,
    };
}

pub fn getVertexAttribOffset(_: *const WebGLRenderingContext, _: u32, _: u32) u32 {
    return 0;
}

pub fn getShaderPrecisionFormat(
    _: *const WebGLRenderingContext,
    _: u32,
    precision_type: u32,
    exec: *Execution,
) !?*objects.WebGLShaderPrecisionFormat {
    const format: objects.WebGLShaderPrecisionFormat = switch (precision_type) {
        LOW_FLOAT => .from(gpu.low_float),
        MEDIUM_FLOAT => .from(gpu.medium_float),
        HIGH_FLOAT => .from(gpu.high_float),
        LOW_INT => .from(gpu.low_int),
        MEDIUM_INT => .from(gpu.medium_int),
        HIGH_INT => .from(gpu.high_int),
        else => return null,
    };
    return try exec._factory.create(format);
}

/// The attribute record a linked program has for each input its vertex stage
/// declares -- `{size: 1, type: FLOAT_VEC2, name: "p"}` for the widget's, which
/// is what Chrome answers. An un-linked program has none, and so does an index
/// past the end.
pub fn getActiveAttrib(self: *const WebGLRenderingContext, program: ?*objects.WebGLProgram, index: u32, exec: *Execution) !?*objects.WebGLActiveInfo {
    const list = self._gl.attributeList(program) orelse return null;
    if (index >= list.len) return null;
    return try exec._factory.create(objects.WebGLActiveInfo{
        ._size = 1,
        ._type = gl_state.attribType(list[index].components),
        ._name = list[index].name,
    });
}

/// No shader this interpreter compiles has a uniform.
pub fn getActiveUniform(_: *const WebGLRenderingContext, _: ?*objects.WebGLProgram, _: u32) ?*objects.WebGLActiveInfo {
    return null;
}

pub fn getAttachedShaders(self: *const WebGLRenderingContext, program: ?*objects.WebGLProgram, exec: *Execution) ![]const *objects.WebGLShader {
    return self._gl.attachedShaderList(program, exec.arena);
}

pub fn getAttribLocation(self: *const WebGLRenderingContext, program: ?*objects.WebGLProgram, name: []const u8) i32 {
    return self._gl.attribLocation(program, name);
}

pub fn getUniformLocation(_: *const WebGLRenderingContext, _: ?*objects.WebGLProgram, _: []const u8) ?*objects.WebGLUniformLocation {
    return null;
}

/// Chrome raises a TypeError when the location isn't a WebGLUniformLocation,
/// which is unreachable for us since getUniformLocation always answers null.
pub fn getUniform(_: *const WebGLRenderingContext, _: ?*objects.WebGLProgram, _: ?*objects.WebGLUniformLocation) ?Parameter {
    return null;
}

pub fn getFramebufferAttachmentParameter(_: *const WebGLRenderingContext, _: u32, _: u32, _: u32) ?Parameter {
    return null;
}

/// The attributes of a context created with no options, measured from Chrome.
/// Field order is the key order a script sees from JSON.stringify.
/// WebXR's hook into a WebGL context. Chrome rejects with a bare
/// InvalidStateError -- "An attempt was made to use an object that is not, or
/// is no longer, usable." -- when there is no XR device to make the context
/// compatible *with*, which is every machine this engine runs on (measured on
/// a headed Chrome 150). The `xrCompatible` context attribute stays false.
pub fn makeXRCompatible(_: *const WebGLRenderingContext, exec: *const js.Execution) !js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("webgl", DOMException.init(
        "An attempt was made to use an object that is not, or is no longer, usable.",
        "InvalidStateError",
    ));
    return resolver.promise();
}

pub fn getContextAttributes(self: *const WebGLRenderingContext) attributes.Gl {
    return self._attributes;
}

// The state setters. Their arguments are never read — the parameter count is
// all that is JS-visible, through Function.prototype.length.
pub fn activeTexture(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn attachShader(self: *WebGLRenderingContext, program: ?*objects.WebGLProgram, shader: ?*objects.WebGLShader) void {
    self._gl.attachShader(program, shader);
}
pub fn bindAttribLocation(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn bindBuffer(self: *WebGLRenderingContext, target: u32, buffer: ?*objects.WebGLBuffer) void {
    self._gl.bindBuffer(target, buffer);
}
pub fn bindFramebuffer(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindRenderbuffer(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindTexture(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn blendColor(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn blendEquation(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn blendEquationSeparate(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn blendFunc(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn blendFuncSeparate(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
/// The second argument is either a byte length or the bytes themselves. Only
/// the bytes are kept: a size-only call allocates a zeroed buffer in GL, and a
/// draw that reads one gets zeroes here too, which is the same picture.
pub fn bufferData(self: *WebGLRenderingContext, target: u32, data: js.Value, _: u32) void {
    if (data.isNumber()) return;
    self._gl.bufferData(target, data.toStringSmart() catch return);
}
pub fn bufferSubData(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clear(self: *WebGLRenderingContext, mask: u32) void {
    self._gl.clear(mask, self._canvas.width(), self._canvas.height());
}
pub fn clearColor(self: *WebGLRenderingContext, r: f32, g: f32, b: f32, a: f32) void {
    self._gl.clearColor(r, g, b, a);
}
pub fn clearDepth(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn clearStencil(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn colorMask(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn compileShader(self: *WebGLRenderingContext, shader: ?*objects.WebGLShader) void {
    self._gl.compileShader(shader);
}
pub fn compressedTexImage2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn compressedTexSubImage2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn copyTexImage2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn copyTexSubImage2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn cullFace(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn deleteBuffer(_: *const WebGLRenderingContext, buffer: ?*objects.WebGLBuffer) void {
    (buffer orelse return)._deleted = true;
}
pub fn deleteFramebuffer(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn deleteProgram(_: *const WebGLRenderingContext, program: ?*objects.WebGLProgram) void {
    (program orelse return)._deleted = true;
}
pub fn deleteRenderbuffer(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn deleteShader(_: *const WebGLRenderingContext, shader: ?*objects.WebGLShader) void {
    (shader orelse return)._deleted = true;
}
pub fn deleteTexture(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn depthFunc(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn depthMask(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn depthRange(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn detachShader(self: *WebGLRenderingContext, program: ?*objects.WebGLProgram, shader: ?*objects.WebGLShader) void {
    self._gl.detachShader(program, shader);
}
pub fn disable(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn disableVertexAttribArray(self: *WebGLRenderingContext, index: u32) void {
    self._gl.enableVertexAttribArray(index, false);
}
pub fn drawArrays(self: *WebGLRenderingContext, mode: u32, first: i32, count: i32) void {
    self._gl.drawArrays(mode, first, count, self._canvas.width(), self._canvas.height());
}
pub fn drawElements(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn drawingBufferStorage(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn enable(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn enableVertexAttribArray(self: *WebGLRenderingContext, index: u32) void {
    self._gl.enableVertexAttribArray(index, true);
}
pub fn finish(_: *const WebGLRenderingContext) void {}
pub fn flush(_: *const WebGLRenderingContext) void {}
pub fn framebufferRenderbuffer(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn framebufferTexture2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn frontFace(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn generateMipmap(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn hint(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn lineWidth(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn linkProgram(self: *WebGLRenderingContext, program: ?*objects.WebGLProgram) void {
    self._gl.linkProgram(program);
}
pub fn pixelStorei(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn polygonOffset(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn renderbufferStorage(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn sampleCoverage(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn scissor(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn shaderSource(self: *WebGLRenderingContext, shader: ?*objects.WebGLShader, source: []const u8) void {
    self._gl.shaderSource(shader, source);
}
pub fn stencilFunc(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn stencilFuncSeparate(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn stencilMask(_: *const WebGLRenderingContext, _: js.Value) void {}
pub fn stencilMaskSeparate(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn stencilOp(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn stencilOpSeparate(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texImage2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texParameterf(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texParameteri(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texSubImage2D(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform1f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1i(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1iv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform2f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform2fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform2i(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform2iv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform3f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform3fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform3i(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform3iv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform4f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform4fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform4i(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform4iv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix2fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix3fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix4fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn useProgram(self: *WebGLRenderingContext, program: ?*objects.WebGLProgram) void {
    self._gl.useProgram(program);
}
pub fn validateProgram(self: *WebGLRenderingContext, program: ?*objects.WebGLProgram) void {
    self._gl.validateProgram(program);
}
pub fn vertexAttrib1f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib1fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib2f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib2fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib3f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib3fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib4f(_: *const WebGLRenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib4fv(_: *const WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttribPointer(self: *WebGLRenderingContext, index: u32, size: i32, kind: u32, _: bool, stride: i32, offset: i32) void {
    self._gl.vertexAttribPointer(index, size, kind, stride, offset);
}
pub fn viewport(self: *WebGLRenderingContext, x: i32, y: i32, w: i32, h: i32) void {
    self._gl.setViewport(x, y, w, h);
}

/// Reads the drawing buffer back into the caller's view. A context that has
/// never been drawn into has no buffer, and the destination is left alone --
/// which is the transparent black Chrome reports for one.
pub fn readPixels(
    self: *WebGLRenderingContext,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    format: u32,
    kind: u32,
    dest: js.Object,
) void {
    self._gl.readPixels(x, y, w, h, format, kind, gl_state.destination(dest) orelse return);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGLRenderingContext);

    pub const Meta = struct {
        pub const name = "WebGLRenderingContext";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(WebGLRenderingContext.getCanvas, null, .{});
    pub const drawingBufferWidth = bridge.accessor(WebGLRenderingContext.getDrawingBufferWidth, null, .{});
    pub const drawingBufferHeight = bridge.accessor(WebGLRenderingContext.getDrawingBufferHeight, null, .{});
    pub const drawingBufferColorSpace = bridge.accessor(WebGLRenderingContext.getDrawingBufferColorSpace, WebGLRenderingContext.setDrawingBufferColorSpace, .{});
    pub const unpackColorSpace = bridge.accessor(WebGLRenderingContext.getUnpackColorSpace, WebGLRenderingContext.setUnpackColorSpace, .{});
    pub const drawingBufferFormat = bridge.accessor(WebGLRenderingContext.getDrawingBufferFormat, null, .{});

    pub const getParameter = bridge.function(WebGLRenderingContext.getParameter, .{});
    pub const getExtension = bridge.function(WebGLRenderingContext.getExtension, .{});
    pub const getSupportedExtensions = bridge.function(WebGLRenderingContext.getSupportedExtensions, .{});
    pub const createBuffer = bridge.function(WebGLRenderingContext.createBuffer, .{});
    pub const createFramebuffer = bridge.function(WebGLRenderingContext.createFramebuffer, .{});
    pub const createProgram = bridge.function(WebGLRenderingContext.createProgram, .{});
    pub const createRenderbuffer = bridge.function(WebGLRenderingContext.createRenderbuffer, .{});
    pub const createShader = bridge.function(WebGLRenderingContext.createShader, .{});
    pub const createTexture = bridge.function(WebGLRenderingContext.createTexture, .{});
    pub const checkFramebufferStatus = bridge.function(WebGLRenderingContext.checkFramebufferStatus, .{});
    pub const getError = bridge.function(WebGLRenderingContext.getError, .{});
    pub const isContextLost = bridge.function(WebGLRenderingContext.isContextLost, .{});
    pub const isEnabled = bridge.function(WebGLRenderingContext.isEnabled, .{});
    pub const isBuffer = bridge.function(WebGLRenderingContext.isBuffer, .{ .arity = 1 });
    pub const isFramebuffer = bridge.function(WebGLRenderingContext.isFramebuffer, .{ .arity = 1 });
    pub const isProgram = bridge.function(WebGLRenderingContext.isProgram, .{ .arity = 1 });
    pub const isRenderbuffer = bridge.function(WebGLRenderingContext.isRenderbuffer, .{ .arity = 1 });
    pub const isShader = bridge.function(WebGLRenderingContext.isShader, .{ .arity = 1 });
    pub const isTexture = bridge.function(WebGLRenderingContext.isTexture, .{ .arity = 1 });
    pub const getShaderInfoLog = bridge.function(WebGLRenderingContext.getShaderInfoLog, .{ .arity = 1 });
    pub const getProgramInfoLog = bridge.function(WebGLRenderingContext.getProgramInfoLog, .{ .arity = 1 });
    pub const getShaderSource = bridge.function(WebGLRenderingContext.getShaderSource, .{ .arity = 1 });
    pub const getShaderParameter = bridge.function(WebGLRenderingContext.getShaderParameter, .{ .arity = 2 });
    pub const getProgramParameter = bridge.function(WebGLRenderingContext.getProgramParameter, .{ .arity = 2 });
    pub const getBufferParameter = bridge.function(WebGLRenderingContext.getBufferParameter, .{});
    pub const getTexParameter = bridge.function(WebGLRenderingContext.getTexParameter, .{});
    pub const getRenderbufferParameter = bridge.function(WebGLRenderingContext.getRenderbufferParameter, .{});
    pub const getVertexAttrib = bridge.function(WebGLRenderingContext.getVertexAttrib, .{});
    pub const getVertexAttribOffset = bridge.function(WebGLRenderingContext.getVertexAttribOffset, .{});
    pub const getShaderPrecisionFormat = bridge.function(WebGLRenderingContext.getShaderPrecisionFormat, .{});
    pub const getActiveAttrib = bridge.function(WebGLRenderingContext.getActiveAttrib, .{ .arity = 2 });
    pub const getActiveUniform = bridge.function(WebGLRenderingContext.getActiveUniform, .{ .arity = 2 });
    pub const getAttachedShaders = bridge.function(WebGLRenderingContext.getAttachedShaders, .{ .arity = 1 });
    pub const getAttribLocation = bridge.function(WebGLRenderingContext.getAttribLocation, .{ .arity = 2 });
    pub const getUniformLocation = bridge.function(WebGLRenderingContext.getUniformLocation, .{ .arity = 2 });
    pub const getUniform = bridge.function(WebGLRenderingContext.getUniform, .{ .arity = 2 });
    pub const getFramebufferAttachmentParameter = bridge.function(WebGLRenderingContext.getFramebufferAttachmentParameter, .{});
    pub const getContextAttributes = bridge.function(WebGLRenderingContext.getContextAttributes, .{});
    pub const makeXRCompatible = bridge.function(WebGLRenderingContext.makeXRCompatible, .{});

    pub const activeTexture = bridge.function(WebGLRenderingContext.activeTexture, .{ .noop = true });
    pub const attachShader = bridge.function(WebGLRenderingContext.attachShader, .{ .arity = 2 });
    pub const bindAttribLocation = bridge.function(WebGLRenderingContext.bindAttribLocation, .{ .noop = true });
    pub const bindBuffer = bridge.function(WebGLRenderingContext.bindBuffer, .{ .arity = 2 });
    pub const bindFramebuffer = bridge.function(WebGLRenderingContext.bindFramebuffer, .{ .noop = true });
    pub const bindRenderbuffer = bridge.function(WebGLRenderingContext.bindRenderbuffer, .{ .noop = true });
    pub const bindTexture = bridge.function(WebGLRenderingContext.bindTexture, .{ .noop = true });
    pub const blendColor = bridge.function(WebGLRenderingContext.blendColor, .{ .noop = true });
    pub const blendEquation = bridge.function(WebGLRenderingContext.blendEquation, .{ .noop = true });
    pub const blendEquationSeparate = bridge.function(WebGLRenderingContext.blendEquationSeparate, .{ .noop = true });
    pub const blendFunc = bridge.function(WebGLRenderingContext.blendFunc, .{ .noop = true });
    pub const blendFuncSeparate = bridge.function(WebGLRenderingContext.blendFuncSeparate, .{ .noop = true });
    pub const bufferData = bridge.function(WebGLRenderingContext.bufferData, .{ .arity = 3 });
    pub const bufferSubData = bridge.function(WebGLRenderingContext.bufferSubData, .{ .noop = true });
    pub const clear = bridge.function(WebGLRenderingContext.clear, .{ .arity = 1 });
    pub const clearColor = bridge.function(WebGLRenderingContext.clearColor, .{ .arity = 4 });
    pub const clearDepth = bridge.function(WebGLRenderingContext.clearDepth, .{ .noop = true });
    pub const clearStencil = bridge.function(WebGLRenderingContext.clearStencil, .{ .noop = true });
    pub const colorMask = bridge.function(WebGLRenderingContext.colorMask, .{ .noop = true });
    pub const compileShader = bridge.function(WebGLRenderingContext.compileShader, .{ .arity = 1 });
    pub const compressedTexImage2D = bridge.function(WebGLRenderingContext.compressedTexImage2D, .{ .noop = true });
    pub const compressedTexSubImage2D = bridge.function(WebGLRenderingContext.compressedTexSubImage2D, .{ .noop = true });
    pub const copyTexImage2D = bridge.function(WebGLRenderingContext.copyTexImage2D, .{ .noop = true });
    pub const copyTexSubImage2D = bridge.function(WebGLRenderingContext.copyTexSubImage2D, .{ .noop = true });
    pub const cullFace = bridge.function(WebGLRenderingContext.cullFace, .{ .noop = true });
    pub const deleteBuffer = bridge.function(WebGLRenderingContext.deleteBuffer, .{ .arity = 1 });
    pub const deleteFramebuffer = bridge.function(WebGLRenderingContext.deleteFramebuffer, .{ .noop = true });
    pub const deleteProgram = bridge.function(WebGLRenderingContext.deleteProgram, .{ .arity = 1 });
    pub const deleteRenderbuffer = bridge.function(WebGLRenderingContext.deleteRenderbuffer, .{ .noop = true });
    pub const deleteShader = bridge.function(WebGLRenderingContext.deleteShader, .{ .arity = 1 });
    pub const deleteTexture = bridge.function(WebGLRenderingContext.deleteTexture, .{ .noop = true });
    pub const depthFunc = bridge.function(WebGLRenderingContext.depthFunc, .{ .noop = true });
    pub const depthMask = bridge.function(WebGLRenderingContext.depthMask, .{ .noop = true });
    pub const depthRange = bridge.function(WebGLRenderingContext.depthRange, .{ .noop = true });
    pub const detachShader = bridge.function(WebGLRenderingContext.detachShader, .{ .arity = 2 });
    pub const disable = bridge.function(WebGLRenderingContext.disable, .{ .noop = true });
    pub const disableVertexAttribArray = bridge.function(WebGLRenderingContext.disableVertexAttribArray, .{ .arity = 1 });
    pub const drawArrays = bridge.function(WebGLRenderingContext.drawArrays, .{ .arity = 3 });
    pub const drawElements = bridge.function(WebGLRenderingContext.drawElements, .{ .noop = true });
    pub const drawingBufferStorage = bridge.function(WebGLRenderingContext.drawingBufferStorage, .{ .noop = true });
    pub const enable = bridge.function(WebGLRenderingContext.enable, .{ .noop = true });
    pub const enableVertexAttribArray = bridge.function(WebGLRenderingContext.enableVertexAttribArray, .{ .arity = 1 });
    pub const finish = bridge.function(WebGLRenderingContext.finish, .{ .noop = true });
    pub const flush = bridge.function(WebGLRenderingContext.flush, .{ .noop = true });
    pub const framebufferRenderbuffer = bridge.function(WebGLRenderingContext.framebufferRenderbuffer, .{ .noop = true });
    pub const framebufferTexture2D = bridge.function(WebGLRenderingContext.framebufferTexture2D, .{ .noop = true });
    pub const frontFace = bridge.function(WebGLRenderingContext.frontFace, .{ .noop = true });
    pub const generateMipmap = bridge.function(WebGLRenderingContext.generateMipmap, .{ .noop = true });
    pub const hint = bridge.function(WebGLRenderingContext.hint, .{ .noop = true });
    pub const lineWidth = bridge.function(WebGLRenderingContext.lineWidth, .{ .noop = true });
    pub const linkProgram = bridge.function(WebGLRenderingContext.linkProgram, .{ .arity = 1 });
    pub const pixelStorei = bridge.function(WebGLRenderingContext.pixelStorei, .{ .noop = true });
    pub const polygonOffset = bridge.function(WebGLRenderingContext.polygonOffset, .{ .noop = true });
    pub const renderbufferStorage = bridge.function(WebGLRenderingContext.renderbufferStorage, .{ .noop = true });
    pub const sampleCoverage = bridge.function(WebGLRenderingContext.sampleCoverage, .{ .noop = true });
    pub const scissor = bridge.function(WebGLRenderingContext.scissor, .{ .noop = true });
    pub const shaderSource = bridge.function(WebGLRenderingContext.shaderSource, .{ .arity = 2 });
    pub const stencilFunc = bridge.function(WebGLRenderingContext.stencilFunc, .{ .noop = true });
    pub const stencilFuncSeparate = bridge.function(WebGLRenderingContext.stencilFuncSeparate, .{ .noop = true });
    pub const stencilMask = bridge.function(WebGLRenderingContext.stencilMask, .{ .noop = true });
    pub const stencilMaskSeparate = bridge.function(WebGLRenderingContext.stencilMaskSeparate, .{ .noop = true });
    pub const stencilOp = bridge.function(WebGLRenderingContext.stencilOp, .{ .noop = true });
    pub const stencilOpSeparate = bridge.function(WebGLRenderingContext.stencilOpSeparate, .{ .noop = true });
    pub const texImage2D = bridge.function(WebGLRenderingContext.texImage2D, .{ .noop = true });
    pub const texParameterf = bridge.function(WebGLRenderingContext.texParameterf, .{ .noop = true });
    pub const texParameteri = bridge.function(WebGLRenderingContext.texParameteri, .{ .noop = true });
    pub const texSubImage2D = bridge.function(WebGLRenderingContext.texSubImage2D, .{ .noop = true });
    pub const uniform1f = bridge.function(WebGLRenderingContext.uniform1f, .{ .noop = true });
    pub const uniform1fv = bridge.function(WebGLRenderingContext.uniform1fv, .{ .noop = true });
    pub const uniform1i = bridge.function(WebGLRenderingContext.uniform1i, .{ .noop = true });
    pub const uniform1iv = bridge.function(WebGLRenderingContext.uniform1iv, .{ .noop = true });
    pub const uniform2f = bridge.function(WebGLRenderingContext.uniform2f, .{ .noop = true });
    pub const uniform2fv = bridge.function(WebGLRenderingContext.uniform2fv, .{ .noop = true });
    pub const uniform2i = bridge.function(WebGLRenderingContext.uniform2i, .{ .noop = true });
    pub const uniform2iv = bridge.function(WebGLRenderingContext.uniform2iv, .{ .noop = true });
    pub const uniform3f = bridge.function(WebGLRenderingContext.uniform3f, .{ .noop = true });
    pub const uniform3fv = bridge.function(WebGLRenderingContext.uniform3fv, .{ .noop = true });
    pub const uniform3i = bridge.function(WebGLRenderingContext.uniform3i, .{ .noop = true });
    pub const uniform3iv = bridge.function(WebGLRenderingContext.uniform3iv, .{ .noop = true });
    pub const uniform4f = bridge.function(WebGLRenderingContext.uniform4f, .{ .noop = true });
    pub const uniform4fv = bridge.function(WebGLRenderingContext.uniform4fv, .{ .noop = true });
    pub const uniform4i = bridge.function(WebGLRenderingContext.uniform4i, .{ .noop = true });
    pub const uniform4iv = bridge.function(WebGLRenderingContext.uniform4iv, .{ .noop = true });
    pub const uniformMatrix2fv = bridge.function(WebGLRenderingContext.uniformMatrix2fv, .{ .noop = true });
    pub const uniformMatrix3fv = bridge.function(WebGLRenderingContext.uniformMatrix3fv, .{ .noop = true });
    pub const uniformMatrix4fv = bridge.function(WebGLRenderingContext.uniformMatrix4fv, .{ .noop = true });
    pub const useProgram = bridge.function(WebGLRenderingContext.useProgram, .{ .arity = 1 });
    pub const validateProgram = bridge.function(WebGLRenderingContext.validateProgram, .{ .arity = 1 });
    pub const vertexAttrib1f = bridge.function(WebGLRenderingContext.vertexAttrib1f, .{ .noop = true });
    pub const vertexAttrib1fv = bridge.function(WebGLRenderingContext.vertexAttrib1fv, .{ .noop = true });
    pub const vertexAttrib2f = bridge.function(WebGLRenderingContext.vertexAttrib2f, .{ .noop = true });
    pub const vertexAttrib2fv = bridge.function(WebGLRenderingContext.vertexAttrib2fv, .{ .noop = true });
    pub const vertexAttrib3f = bridge.function(WebGLRenderingContext.vertexAttrib3f, .{ .noop = true });
    pub const vertexAttrib3fv = bridge.function(WebGLRenderingContext.vertexAttrib3fv, .{ .noop = true });
    pub const vertexAttrib4f = bridge.function(WebGLRenderingContext.vertexAttrib4f, .{ .noop = true });
    pub const vertexAttrib4fv = bridge.function(WebGLRenderingContext.vertexAttrib4fv, .{ .noop = true });
    pub const vertexAttribPointer = bridge.function(WebGLRenderingContext.vertexAttribPointer, .{ .arity = 6 });
    pub const viewport = bridge.function(WebGLRenderingContext.viewport, .{ .arity = 4 });
    pub const readPixels = bridge.function(WebGLRenderingContext.readPixels, .{ .arity = 7 });

    // Web IDL constants live on both the interface object and the interface
    // prototype object, which is what `.template = true` gets us here.
    pub const DEPTH_BUFFER_BIT = bridge.property(WebGLRenderingContext.DEPTH_BUFFER_BIT, .{ .template = true, .readonly = true });
    pub const STENCIL_BUFFER_BIT = bridge.property(WebGLRenderingContext.STENCIL_BUFFER_BIT, .{ .template = true, .readonly = true });
    pub const COLOR_BUFFER_BIT = bridge.property(WebGLRenderingContext.COLOR_BUFFER_BIT, .{ .template = true, .readonly = true });
    pub const POINTS = bridge.property(WebGLRenderingContext.POINTS, .{ .template = true, .readonly = true });
    pub const LINES = bridge.property(WebGLRenderingContext.LINES, .{ .template = true, .readonly = true });
    pub const LINE_LOOP = bridge.property(WebGLRenderingContext.LINE_LOOP, .{ .template = true, .readonly = true });
    pub const LINE_STRIP = bridge.property(WebGLRenderingContext.LINE_STRIP, .{ .template = true, .readonly = true });
    pub const TRIANGLES = bridge.property(WebGLRenderingContext.TRIANGLES, .{ .template = true, .readonly = true });
    pub const TRIANGLE_STRIP = bridge.property(WebGLRenderingContext.TRIANGLE_STRIP, .{ .template = true, .readonly = true });
    pub const TRIANGLE_FAN = bridge.property(WebGLRenderingContext.TRIANGLE_FAN, .{ .template = true, .readonly = true });
    pub const ZERO = bridge.property(WebGLRenderingContext.ZERO, .{ .template = true, .readonly = true });
    pub const ONE = bridge.property(WebGLRenderingContext.ONE, .{ .template = true, .readonly = true });
    pub const SRC_COLOR = bridge.property(WebGLRenderingContext.SRC_COLOR, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_SRC_COLOR = bridge.property(WebGLRenderingContext.ONE_MINUS_SRC_COLOR, .{ .template = true, .readonly = true });
    pub const SRC_ALPHA = bridge.property(WebGLRenderingContext.SRC_ALPHA, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_SRC_ALPHA = bridge.property(WebGLRenderingContext.ONE_MINUS_SRC_ALPHA, .{ .template = true, .readonly = true });
    pub const DST_ALPHA = bridge.property(WebGLRenderingContext.DST_ALPHA, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_DST_ALPHA = bridge.property(WebGLRenderingContext.ONE_MINUS_DST_ALPHA, .{ .template = true, .readonly = true });
    pub const DST_COLOR = bridge.property(WebGLRenderingContext.DST_COLOR, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_DST_COLOR = bridge.property(WebGLRenderingContext.ONE_MINUS_DST_COLOR, .{ .template = true, .readonly = true });
    pub const SRC_ALPHA_SATURATE = bridge.property(WebGLRenderingContext.SRC_ALPHA_SATURATE, .{ .template = true, .readonly = true });
    pub const FUNC_ADD = bridge.property(WebGLRenderingContext.FUNC_ADD, .{ .template = true, .readonly = true });
    pub const BLEND_EQUATION = bridge.property(WebGLRenderingContext.BLEND_EQUATION, .{ .template = true, .readonly = true });
    pub const BLEND_EQUATION_RGB = bridge.property(WebGLRenderingContext.BLEND_EQUATION_RGB, .{ .template = true, .readonly = true });
    pub const BLEND_EQUATION_ALPHA = bridge.property(WebGLRenderingContext.BLEND_EQUATION_ALPHA, .{ .template = true, .readonly = true });
    pub const FUNC_SUBTRACT = bridge.property(WebGLRenderingContext.FUNC_SUBTRACT, .{ .template = true, .readonly = true });
    pub const FUNC_REVERSE_SUBTRACT = bridge.property(WebGLRenderingContext.FUNC_REVERSE_SUBTRACT, .{ .template = true, .readonly = true });
    pub const BLEND_DST_RGB = bridge.property(WebGLRenderingContext.BLEND_DST_RGB, .{ .template = true, .readonly = true });
    pub const BLEND_SRC_RGB = bridge.property(WebGLRenderingContext.BLEND_SRC_RGB, .{ .template = true, .readonly = true });
    pub const BLEND_DST_ALPHA = bridge.property(WebGLRenderingContext.BLEND_DST_ALPHA, .{ .template = true, .readonly = true });
    pub const BLEND_SRC_ALPHA = bridge.property(WebGLRenderingContext.BLEND_SRC_ALPHA, .{ .template = true, .readonly = true });
    pub const CONSTANT_COLOR = bridge.property(WebGLRenderingContext.CONSTANT_COLOR, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_CONSTANT_COLOR = bridge.property(WebGLRenderingContext.ONE_MINUS_CONSTANT_COLOR, .{ .template = true, .readonly = true });
    pub const CONSTANT_ALPHA = bridge.property(WebGLRenderingContext.CONSTANT_ALPHA, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_CONSTANT_ALPHA = bridge.property(WebGLRenderingContext.ONE_MINUS_CONSTANT_ALPHA, .{ .template = true, .readonly = true });
    pub const BLEND_COLOR = bridge.property(WebGLRenderingContext.BLEND_COLOR, .{ .template = true, .readonly = true });
    pub const ARRAY_BUFFER = bridge.property(WebGLRenderingContext.ARRAY_BUFFER, .{ .template = true, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER = bridge.property(WebGLRenderingContext.ELEMENT_ARRAY_BUFFER, .{ .template = true, .readonly = true });
    pub const ARRAY_BUFFER_BINDING = bridge.property(WebGLRenderingContext.ARRAY_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER_BINDING = bridge.property(WebGLRenderingContext.ELEMENT_ARRAY_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const STREAM_DRAW = bridge.property(WebGLRenderingContext.STREAM_DRAW, .{ .template = true, .readonly = true });
    pub const STATIC_DRAW = bridge.property(WebGLRenderingContext.STATIC_DRAW, .{ .template = true, .readonly = true });
    pub const DYNAMIC_DRAW = bridge.property(WebGLRenderingContext.DYNAMIC_DRAW, .{ .template = true, .readonly = true });
    pub const BUFFER_SIZE = bridge.property(WebGLRenderingContext.BUFFER_SIZE, .{ .template = true, .readonly = true });
    pub const BUFFER_USAGE = bridge.property(WebGLRenderingContext.BUFFER_USAGE, .{ .template = true, .readonly = true });
    pub const CURRENT_VERTEX_ATTRIB = bridge.property(WebGLRenderingContext.CURRENT_VERTEX_ATTRIB, .{ .template = true, .readonly = true });
    pub const FRONT = bridge.property(WebGLRenderingContext.FRONT, .{ .template = true, .readonly = true });
    pub const BACK = bridge.property(WebGLRenderingContext.BACK, .{ .template = true, .readonly = true });
    pub const FRONT_AND_BACK = bridge.property(WebGLRenderingContext.FRONT_AND_BACK, .{ .template = true, .readonly = true });
    pub const TEXTURE_2D = bridge.property(WebGLRenderingContext.TEXTURE_2D, .{ .template = true, .readonly = true });
    pub const CULL_FACE = bridge.property(WebGLRenderingContext.CULL_FACE, .{ .template = true, .readonly = true });
    pub const BLEND = bridge.property(WebGLRenderingContext.BLEND, .{ .template = true, .readonly = true });
    pub const DITHER = bridge.property(WebGLRenderingContext.DITHER, .{ .template = true, .readonly = true });
    pub const STENCIL_TEST = bridge.property(WebGLRenderingContext.STENCIL_TEST, .{ .template = true, .readonly = true });
    pub const DEPTH_TEST = bridge.property(WebGLRenderingContext.DEPTH_TEST, .{ .template = true, .readonly = true });
    pub const SCISSOR_TEST = bridge.property(WebGLRenderingContext.SCISSOR_TEST, .{ .template = true, .readonly = true });
    pub const POLYGON_OFFSET_FILL = bridge.property(WebGLRenderingContext.POLYGON_OFFSET_FILL, .{ .template = true, .readonly = true });
    pub const SAMPLE_ALPHA_TO_COVERAGE = bridge.property(WebGLRenderingContext.SAMPLE_ALPHA_TO_COVERAGE, .{ .template = true, .readonly = true });
    pub const SAMPLE_COVERAGE = bridge.property(WebGLRenderingContext.SAMPLE_COVERAGE, .{ .template = true, .readonly = true });
    pub const NO_ERROR = bridge.property(WebGLRenderingContext.NO_ERROR, .{ .template = true, .readonly = true });
    pub const INVALID_ENUM = bridge.property(WebGLRenderingContext.INVALID_ENUM, .{ .template = true, .readonly = true });
    pub const INVALID_VALUE = bridge.property(WebGLRenderingContext.INVALID_VALUE, .{ .template = true, .readonly = true });
    pub const INVALID_OPERATION = bridge.property(WebGLRenderingContext.INVALID_OPERATION, .{ .template = true, .readonly = true });
    pub const OUT_OF_MEMORY = bridge.property(WebGLRenderingContext.OUT_OF_MEMORY, .{ .template = true, .readonly = true });
    pub const CW = bridge.property(WebGLRenderingContext.CW, .{ .template = true, .readonly = true });
    pub const CCW = bridge.property(WebGLRenderingContext.CCW, .{ .template = true, .readonly = true });
    pub const LINE_WIDTH = bridge.property(WebGLRenderingContext.LINE_WIDTH, .{ .template = true, .readonly = true });
    pub const ALIASED_POINT_SIZE_RANGE = bridge.property(WebGLRenderingContext.ALIASED_POINT_SIZE_RANGE, .{ .template = true, .readonly = true });
    pub const ALIASED_LINE_WIDTH_RANGE = bridge.property(WebGLRenderingContext.ALIASED_LINE_WIDTH_RANGE, .{ .template = true, .readonly = true });
    pub const CULL_FACE_MODE = bridge.property(WebGLRenderingContext.CULL_FACE_MODE, .{ .template = true, .readonly = true });
    pub const FRONT_FACE = bridge.property(WebGLRenderingContext.FRONT_FACE, .{ .template = true, .readonly = true });
    pub const DEPTH_RANGE = bridge.property(WebGLRenderingContext.DEPTH_RANGE, .{ .template = true, .readonly = true });
    pub const DEPTH_WRITEMASK = bridge.property(WebGLRenderingContext.DEPTH_WRITEMASK, .{ .template = true, .readonly = true });
    pub const DEPTH_CLEAR_VALUE = bridge.property(WebGLRenderingContext.DEPTH_CLEAR_VALUE, .{ .template = true, .readonly = true });
    pub const DEPTH_FUNC = bridge.property(WebGLRenderingContext.DEPTH_FUNC, .{ .template = true, .readonly = true });
    pub const STENCIL_CLEAR_VALUE = bridge.property(WebGLRenderingContext.STENCIL_CLEAR_VALUE, .{ .template = true, .readonly = true });
    pub const STENCIL_FUNC = bridge.property(WebGLRenderingContext.STENCIL_FUNC, .{ .template = true, .readonly = true });
    pub const STENCIL_FAIL = bridge.property(WebGLRenderingContext.STENCIL_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_PASS_DEPTH_FAIL = bridge.property(WebGLRenderingContext.STENCIL_PASS_DEPTH_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_PASS_DEPTH_PASS = bridge.property(WebGLRenderingContext.STENCIL_PASS_DEPTH_PASS, .{ .template = true, .readonly = true });
    pub const STENCIL_REF = bridge.property(WebGLRenderingContext.STENCIL_REF, .{ .template = true, .readonly = true });
    pub const STENCIL_VALUE_MASK = bridge.property(WebGLRenderingContext.STENCIL_VALUE_MASK, .{ .template = true, .readonly = true });
    pub const STENCIL_WRITEMASK = bridge.property(WebGLRenderingContext.STENCIL_WRITEMASK, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_FUNC = bridge.property(WebGLRenderingContext.STENCIL_BACK_FUNC, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_FAIL = bridge.property(WebGLRenderingContext.STENCIL_BACK_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_PASS_DEPTH_FAIL = bridge.property(WebGLRenderingContext.STENCIL_BACK_PASS_DEPTH_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_PASS_DEPTH_PASS = bridge.property(WebGLRenderingContext.STENCIL_BACK_PASS_DEPTH_PASS, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_REF = bridge.property(WebGLRenderingContext.STENCIL_BACK_REF, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_VALUE_MASK = bridge.property(WebGLRenderingContext.STENCIL_BACK_VALUE_MASK, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_WRITEMASK = bridge.property(WebGLRenderingContext.STENCIL_BACK_WRITEMASK, .{ .template = true, .readonly = true });
    pub const VIEWPORT = bridge.property(WebGLRenderingContext.VIEWPORT, .{ .template = true, .readonly = true });
    pub const SCISSOR_BOX = bridge.property(WebGLRenderingContext.SCISSOR_BOX, .{ .template = true, .readonly = true });
    pub const COLOR_CLEAR_VALUE = bridge.property(WebGLRenderingContext.COLOR_CLEAR_VALUE, .{ .template = true, .readonly = true });
    pub const COLOR_WRITEMASK = bridge.property(WebGLRenderingContext.COLOR_WRITEMASK, .{ .template = true, .readonly = true });
    pub const UNPACK_ALIGNMENT = bridge.property(WebGLRenderingContext.UNPACK_ALIGNMENT, .{ .template = true, .readonly = true });
    pub const PACK_ALIGNMENT = bridge.property(WebGLRenderingContext.PACK_ALIGNMENT, .{ .template = true, .readonly = true });
    pub const MAX_TEXTURE_SIZE = bridge.property(WebGLRenderingContext.MAX_TEXTURE_SIZE, .{ .template = true, .readonly = true });
    pub const MAX_VIEWPORT_DIMS = bridge.property(WebGLRenderingContext.MAX_VIEWPORT_DIMS, .{ .template = true, .readonly = true });
    pub const SUBPIXEL_BITS = bridge.property(WebGLRenderingContext.SUBPIXEL_BITS, .{ .template = true, .readonly = true });
    pub const RED_BITS = bridge.property(WebGLRenderingContext.RED_BITS, .{ .template = true, .readonly = true });
    pub const GREEN_BITS = bridge.property(WebGLRenderingContext.GREEN_BITS, .{ .template = true, .readonly = true });
    pub const BLUE_BITS = bridge.property(WebGLRenderingContext.BLUE_BITS, .{ .template = true, .readonly = true });
    pub const ALPHA_BITS = bridge.property(WebGLRenderingContext.ALPHA_BITS, .{ .template = true, .readonly = true });
    pub const DEPTH_BITS = bridge.property(WebGLRenderingContext.DEPTH_BITS, .{ .template = true, .readonly = true });
    pub const STENCIL_BITS = bridge.property(WebGLRenderingContext.STENCIL_BITS, .{ .template = true, .readonly = true });
    pub const POLYGON_OFFSET_UNITS = bridge.property(WebGLRenderingContext.POLYGON_OFFSET_UNITS, .{ .template = true, .readonly = true });
    pub const POLYGON_OFFSET_FACTOR = bridge.property(WebGLRenderingContext.POLYGON_OFFSET_FACTOR, .{ .template = true, .readonly = true });
    pub const TEXTURE_BINDING_2D = bridge.property(WebGLRenderingContext.TEXTURE_BINDING_2D, .{ .template = true, .readonly = true });
    pub const SAMPLE_BUFFERS = bridge.property(WebGLRenderingContext.SAMPLE_BUFFERS, .{ .template = true, .readonly = true });
    pub const SAMPLES = bridge.property(WebGLRenderingContext.SAMPLES, .{ .template = true, .readonly = true });
    pub const SAMPLE_COVERAGE_VALUE = bridge.property(WebGLRenderingContext.SAMPLE_COVERAGE_VALUE, .{ .template = true, .readonly = true });
    pub const SAMPLE_COVERAGE_INVERT = bridge.property(WebGLRenderingContext.SAMPLE_COVERAGE_INVERT, .{ .template = true, .readonly = true });
    pub const COMPRESSED_TEXTURE_FORMATS = bridge.property(WebGLRenderingContext.COMPRESSED_TEXTURE_FORMATS, .{ .template = true, .readonly = true });
    pub const DONT_CARE = bridge.property(WebGLRenderingContext.DONT_CARE, .{ .template = true, .readonly = true });
    pub const FASTEST = bridge.property(WebGLRenderingContext.FASTEST, .{ .template = true, .readonly = true });
    pub const NICEST = bridge.property(WebGLRenderingContext.NICEST, .{ .template = true, .readonly = true });
    pub const GENERATE_MIPMAP_HINT = bridge.property(WebGLRenderingContext.GENERATE_MIPMAP_HINT, .{ .template = true, .readonly = true });
    pub const BYTE = bridge.property(WebGLRenderingContext.BYTE, .{ .template = true, .readonly = true });
    pub const UNSIGNED_BYTE = bridge.property(WebGLRenderingContext.UNSIGNED_BYTE, .{ .template = true, .readonly = true });
    pub const SHORT = bridge.property(WebGLRenderingContext.SHORT, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT = bridge.property(WebGLRenderingContext.UNSIGNED_SHORT, .{ .template = true, .readonly = true });
    pub const INT = bridge.property(WebGLRenderingContext.INT, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT = bridge.property(WebGLRenderingContext.UNSIGNED_INT, .{ .template = true, .readonly = true });
    pub const FLOAT = bridge.property(WebGLRenderingContext.FLOAT, .{ .template = true, .readonly = true });
    pub const DEPTH_COMPONENT = bridge.property(WebGLRenderingContext.DEPTH_COMPONENT, .{ .template = true, .readonly = true });
    pub const ALPHA = bridge.property(WebGLRenderingContext.ALPHA, .{ .template = true, .readonly = true });
    pub const RGB = bridge.property(WebGLRenderingContext.RGB, .{ .template = true, .readonly = true });
    pub const RGBA = bridge.property(WebGLRenderingContext.RGBA, .{ .template = true, .readonly = true });
    pub const LUMINANCE = bridge.property(WebGLRenderingContext.LUMINANCE, .{ .template = true, .readonly = true });
    pub const LUMINANCE_ALPHA = bridge.property(WebGLRenderingContext.LUMINANCE_ALPHA, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT_4_4_4_4 = bridge.property(WebGLRenderingContext.UNSIGNED_SHORT_4_4_4_4, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT_5_5_5_1 = bridge.property(WebGLRenderingContext.UNSIGNED_SHORT_5_5_5_1, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT_5_6_5 = bridge.property(WebGLRenderingContext.UNSIGNED_SHORT_5_6_5, .{ .template = true, .readonly = true });
    pub const FRAGMENT_SHADER = bridge.property(WebGLRenderingContext.FRAGMENT_SHADER, .{ .template = true, .readonly = true });
    pub const VERTEX_SHADER = bridge.property(WebGLRenderingContext.VERTEX_SHADER, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_ATTRIBS = bridge.property(WebGLRenderingContext.MAX_VERTEX_ATTRIBS, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_UNIFORM_VECTORS = bridge.property(WebGLRenderingContext.MAX_VERTEX_UNIFORM_VECTORS, .{ .template = true, .readonly = true });
    pub const MAX_VARYING_VECTORS = bridge.property(WebGLRenderingContext.MAX_VARYING_VECTORS, .{ .template = true, .readonly = true });
    pub const MAX_COMBINED_TEXTURE_IMAGE_UNITS = bridge.property(WebGLRenderingContext.MAX_COMBINED_TEXTURE_IMAGE_UNITS, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_TEXTURE_IMAGE_UNITS = bridge.property(WebGLRenderingContext.MAX_VERTEX_TEXTURE_IMAGE_UNITS, .{ .template = true, .readonly = true });
    pub const MAX_TEXTURE_IMAGE_UNITS = bridge.property(WebGLRenderingContext.MAX_TEXTURE_IMAGE_UNITS, .{ .template = true, .readonly = true });
    pub const MAX_FRAGMENT_UNIFORM_VECTORS = bridge.property(WebGLRenderingContext.MAX_FRAGMENT_UNIFORM_VECTORS, .{ .template = true, .readonly = true });
    pub const SHADER_TYPE = bridge.property(WebGLRenderingContext.SHADER_TYPE, .{ .template = true, .readonly = true });
    pub const DELETE_STATUS = bridge.property(WebGLRenderingContext.DELETE_STATUS, .{ .template = true, .readonly = true });
    pub const LINK_STATUS = bridge.property(WebGLRenderingContext.LINK_STATUS, .{ .template = true, .readonly = true });
    pub const VALIDATE_STATUS = bridge.property(WebGLRenderingContext.VALIDATE_STATUS, .{ .template = true, .readonly = true });
    pub const ATTACHED_SHADERS = bridge.property(WebGLRenderingContext.ATTACHED_SHADERS, .{ .template = true, .readonly = true });
    pub const ACTIVE_UNIFORMS = bridge.property(WebGLRenderingContext.ACTIVE_UNIFORMS, .{ .template = true, .readonly = true });
    pub const ACTIVE_ATTRIBUTES = bridge.property(WebGLRenderingContext.ACTIVE_ATTRIBUTES, .{ .template = true, .readonly = true });
    pub const SHADING_LANGUAGE_VERSION = bridge.property(WebGLRenderingContext.SHADING_LANGUAGE_VERSION, .{ .template = true, .readonly = true });
    pub const CURRENT_PROGRAM = bridge.property(WebGLRenderingContext.CURRENT_PROGRAM, .{ .template = true, .readonly = true });
    pub const NEVER = bridge.property(WebGLRenderingContext.NEVER, .{ .template = true, .readonly = true });
    pub const LESS = bridge.property(WebGLRenderingContext.LESS, .{ .template = true, .readonly = true });
    pub const EQUAL = bridge.property(WebGLRenderingContext.EQUAL, .{ .template = true, .readonly = true });
    pub const LEQUAL = bridge.property(WebGLRenderingContext.LEQUAL, .{ .template = true, .readonly = true });
    pub const GREATER = bridge.property(WebGLRenderingContext.GREATER, .{ .template = true, .readonly = true });
    pub const NOTEQUAL = bridge.property(WebGLRenderingContext.NOTEQUAL, .{ .template = true, .readonly = true });
    pub const GEQUAL = bridge.property(WebGLRenderingContext.GEQUAL, .{ .template = true, .readonly = true });
    pub const ALWAYS = bridge.property(WebGLRenderingContext.ALWAYS, .{ .template = true, .readonly = true });
    pub const KEEP = bridge.property(WebGLRenderingContext.KEEP, .{ .template = true, .readonly = true });
    pub const REPLACE = bridge.property(WebGLRenderingContext.REPLACE, .{ .template = true, .readonly = true });
    pub const INCR = bridge.property(WebGLRenderingContext.INCR, .{ .template = true, .readonly = true });
    pub const DECR = bridge.property(WebGLRenderingContext.DECR, .{ .template = true, .readonly = true });
    pub const INVERT = bridge.property(WebGLRenderingContext.INVERT, .{ .template = true, .readonly = true });
    pub const INCR_WRAP = bridge.property(WebGLRenderingContext.INCR_WRAP, .{ .template = true, .readonly = true });
    pub const DECR_WRAP = bridge.property(WebGLRenderingContext.DECR_WRAP, .{ .template = true, .readonly = true });
    pub const VENDOR = bridge.property(WebGLRenderingContext.VENDOR, .{ .template = true, .readonly = true });
    pub const RENDERER = bridge.property(WebGLRenderingContext.RENDERER, .{ .template = true, .readonly = true });
    pub const VERSION = bridge.property(WebGLRenderingContext.VERSION, .{ .template = true, .readonly = true });
    pub const NEAREST = bridge.property(WebGLRenderingContext.NEAREST, .{ .template = true, .readonly = true });
    pub const LINEAR = bridge.property(WebGLRenderingContext.LINEAR, .{ .template = true, .readonly = true });
    pub const NEAREST_MIPMAP_NEAREST = bridge.property(WebGLRenderingContext.NEAREST_MIPMAP_NEAREST, .{ .template = true, .readonly = true });
    pub const LINEAR_MIPMAP_NEAREST = bridge.property(WebGLRenderingContext.LINEAR_MIPMAP_NEAREST, .{ .template = true, .readonly = true });
    pub const NEAREST_MIPMAP_LINEAR = bridge.property(WebGLRenderingContext.NEAREST_MIPMAP_LINEAR, .{ .template = true, .readonly = true });
    pub const LINEAR_MIPMAP_LINEAR = bridge.property(WebGLRenderingContext.LINEAR_MIPMAP_LINEAR, .{ .template = true, .readonly = true });
    pub const TEXTURE_MAG_FILTER = bridge.property(WebGLRenderingContext.TEXTURE_MAG_FILTER, .{ .template = true, .readonly = true });
    pub const TEXTURE_MIN_FILTER = bridge.property(WebGLRenderingContext.TEXTURE_MIN_FILTER, .{ .template = true, .readonly = true });
    pub const TEXTURE_WRAP_S = bridge.property(WebGLRenderingContext.TEXTURE_WRAP_S, .{ .template = true, .readonly = true });
    pub const TEXTURE_WRAP_T = bridge.property(WebGLRenderingContext.TEXTURE_WRAP_T, .{ .template = true, .readonly = true });
    pub const TEXTURE = bridge.property(WebGLRenderingContext.TEXTURE, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP, .{ .template = true, .readonly = true });
    pub const TEXTURE_BINDING_CUBE_MAP = bridge.property(WebGLRenderingContext.TEXTURE_BINDING_CUBE_MAP, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_X = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP_POSITIVE_X, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_X = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP_NEGATIVE_X, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_Y = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP_POSITIVE_Y, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_Y = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP_NEGATIVE_Y, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_Z = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP_POSITIVE_Z, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_Z = bridge.property(WebGLRenderingContext.TEXTURE_CUBE_MAP_NEGATIVE_Z, .{ .template = true, .readonly = true });
    pub const MAX_CUBE_MAP_TEXTURE_SIZE = bridge.property(WebGLRenderingContext.MAX_CUBE_MAP_TEXTURE_SIZE, .{ .template = true, .readonly = true });
    pub const TEXTURE0 = bridge.property(WebGLRenderingContext.TEXTURE0, .{ .template = true, .readonly = true });
    pub const TEXTURE1 = bridge.property(WebGLRenderingContext.TEXTURE1, .{ .template = true, .readonly = true });
    pub const TEXTURE2 = bridge.property(WebGLRenderingContext.TEXTURE2, .{ .template = true, .readonly = true });
    pub const TEXTURE3 = bridge.property(WebGLRenderingContext.TEXTURE3, .{ .template = true, .readonly = true });
    pub const TEXTURE4 = bridge.property(WebGLRenderingContext.TEXTURE4, .{ .template = true, .readonly = true });
    pub const TEXTURE5 = bridge.property(WebGLRenderingContext.TEXTURE5, .{ .template = true, .readonly = true });
    pub const TEXTURE6 = bridge.property(WebGLRenderingContext.TEXTURE6, .{ .template = true, .readonly = true });
    pub const TEXTURE7 = bridge.property(WebGLRenderingContext.TEXTURE7, .{ .template = true, .readonly = true });
    pub const TEXTURE8 = bridge.property(WebGLRenderingContext.TEXTURE8, .{ .template = true, .readonly = true });
    pub const TEXTURE9 = bridge.property(WebGLRenderingContext.TEXTURE9, .{ .template = true, .readonly = true });
    pub const TEXTURE10 = bridge.property(WebGLRenderingContext.TEXTURE10, .{ .template = true, .readonly = true });
    pub const TEXTURE11 = bridge.property(WebGLRenderingContext.TEXTURE11, .{ .template = true, .readonly = true });
    pub const TEXTURE12 = bridge.property(WebGLRenderingContext.TEXTURE12, .{ .template = true, .readonly = true });
    pub const TEXTURE13 = bridge.property(WebGLRenderingContext.TEXTURE13, .{ .template = true, .readonly = true });
    pub const TEXTURE14 = bridge.property(WebGLRenderingContext.TEXTURE14, .{ .template = true, .readonly = true });
    pub const TEXTURE15 = bridge.property(WebGLRenderingContext.TEXTURE15, .{ .template = true, .readonly = true });
    pub const TEXTURE16 = bridge.property(WebGLRenderingContext.TEXTURE16, .{ .template = true, .readonly = true });
    pub const TEXTURE17 = bridge.property(WebGLRenderingContext.TEXTURE17, .{ .template = true, .readonly = true });
    pub const TEXTURE18 = bridge.property(WebGLRenderingContext.TEXTURE18, .{ .template = true, .readonly = true });
    pub const TEXTURE19 = bridge.property(WebGLRenderingContext.TEXTURE19, .{ .template = true, .readonly = true });
    pub const TEXTURE20 = bridge.property(WebGLRenderingContext.TEXTURE20, .{ .template = true, .readonly = true });
    pub const TEXTURE21 = bridge.property(WebGLRenderingContext.TEXTURE21, .{ .template = true, .readonly = true });
    pub const TEXTURE22 = bridge.property(WebGLRenderingContext.TEXTURE22, .{ .template = true, .readonly = true });
    pub const TEXTURE23 = bridge.property(WebGLRenderingContext.TEXTURE23, .{ .template = true, .readonly = true });
    pub const TEXTURE24 = bridge.property(WebGLRenderingContext.TEXTURE24, .{ .template = true, .readonly = true });
    pub const TEXTURE25 = bridge.property(WebGLRenderingContext.TEXTURE25, .{ .template = true, .readonly = true });
    pub const TEXTURE26 = bridge.property(WebGLRenderingContext.TEXTURE26, .{ .template = true, .readonly = true });
    pub const TEXTURE27 = bridge.property(WebGLRenderingContext.TEXTURE27, .{ .template = true, .readonly = true });
    pub const TEXTURE28 = bridge.property(WebGLRenderingContext.TEXTURE28, .{ .template = true, .readonly = true });
    pub const TEXTURE29 = bridge.property(WebGLRenderingContext.TEXTURE29, .{ .template = true, .readonly = true });
    pub const TEXTURE30 = bridge.property(WebGLRenderingContext.TEXTURE30, .{ .template = true, .readonly = true });
    pub const TEXTURE31 = bridge.property(WebGLRenderingContext.TEXTURE31, .{ .template = true, .readonly = true });
    pub const ACTIVE_TEXTURE = bridge.property(WebGLRenderingContext.ACTIVE_TEXTURE, .{ .template = true, .readonly = true });
    pub const REPEAT = bridge.property(WebGLRenderingContext.REPEAT, .{ .template = true, .readonly = true });
    pub const CLAMP_TO_EDGE = bridge.property(WebGLRenderingContext.CLAMP_TO_EDGE, .{ .template = true, .readonly = true });
    pub const MIRRORED_REPEAT = bridge.property(WebGLRenderingContext.MIRRORED_REPEAT, .{ .template = true, .readonly = true });
    pub const FLOAT_VEC2 = bridge.property(WebGLRenderingContext.FLOAT_VEC2, .{ .template = true, .readonly = true });
    pub const FLOAT_VEC3 = bridge.property(WebGLRenderingContext.FLOAT_VEC3, .{ .template = true, .readonly = true });
    pub const FLOAT_VEC4 = bridge.property(WebGLRenderingContext.FLOAT_VEC4, .{ .template = true, .readonly = true });
    pub const INT_VEC2 = bridge.property(WebGLRenderingContext.INT_VEC2, .{ .template = true, .readonly = true });
    pub const INT_VEC3 = bridge.property(WebGLRenderingContext.INT_VEC3, .{ .template = true, .readonly = true });
    pub const INT_VEC4 = bridge.property(WebGLRenderingContext.INT_VEC4, .{ .template = true, .readonly = true });
    pub const BOOL = bridge.property(WebGLRenderingContext.BOOL, .{ .template = true, .readonly = true });
    pub const BOOL_VEC2 = bridge.property(WebGLRenderingContext.BOOL_VEC2, .{ .template = true, .readonly = true });
    pub const BOOL_VEC3 = bridge.property(WebGLRenderingContext.BOOL_VEC3, .{ .template = true, .readonly = true });
    pub const BOOL_VEC4 = bridge.property(WebGLRenderingContext.BOOL_VEC4, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT2 = bridge.property(WebGLRenderingContext.FLOAT_MAT2, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT3 = bridge.property(WebGLRenderingContext.FLOAT_MAT3, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT4 = bridge.property(WebGLRenderingContext.FLOAT_MAT4, .{ .template = true, .readonly = true });
    pub const SAMPLER_2D = bridge.property(WebGLRenderingContext.SAMPLER_2D, .{ .template = true, .readonly = true });
    pub const SAMPLER_CUBE = bridge.property(WebGLRenderingContext.SAMPLER_CUBE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_ENABLED = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_ENABLED, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_SIZE = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_SIZE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_STRIDE = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_STRIDE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_TYPE = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_TYPE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_NORMALIZED = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_NORMALIZED, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_POINTER = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_POINTER, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_BUFFER_BINDING = bridge.property(WebGLRenderingContext.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const IMPLEMENTATION_COLOR_READ_TYPE = bridge.property(WebGLRenderingContext.IMPLEMENTATION_COLOR_READ_TYPE, .{ .template = true, .readonly = true });
    pub const IMPLEMENTATION_COLOR_READ_FORMAT = bridge.property(WebGLRenderingContext.IMPLEMENTATION_COLOR_READ_FORMAT, .{ .template = true, .readonly = true });
    pub const COMPILE_STATUS = bridge.property(WebGLRenderingContext.COMPILE_STATUS, .{ .template = true, .readonly = true });
    pub const LOW_FLOAT = bridge.property(WebGLRenderingContext.LOW_FLOAT, .{ .template = true, .readonly = true });
    pub const MEDIUM_FLOAT = bridge.property(WebGLRenderingContext.MEDIUM_FLOAT, .{ .template = true, .readonly = true });
    pub const HIGH_FLOAT = bridge.property(WebGLRenderingContext.HIGH_FLOAT, .{ .template = true, .readonly = true });
    pub const LOW_INT = bridge.property(WebGLRenderingContext.LOW_INT, .{ .template = true, .readonly = true });
    pub const MEDIUM_INT = bridge.property(WebGLRenderingContext.MEDIUM_INT, .{ .template = true, .readonly = true });
    pub const HIGH_INT = bridge.property(WebGLRenderingContext.HIGH_INT, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER = bridge.property(WebGLRenderingContext.FRAMEBUFFER, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER = bridge.property(WebGLRenderingContext.RENDERBUFFER, .{ .template = true, .readonly = true });
    pub const RGBA4 = bridge.property(WebGLRenderingContext.RGBA4, .{ .template = true, .readonly = true });
    pub const RGB5_A1 = bridge.property(WebGLRenderingContext.RGB5_A1, .{ .template = true, .readonly = true });
    pub const RGB565 = bridge.property(WebGLRenderingContext.RGB565, .{ .template = true, .readonly = true });
    pub const DEPTH_COMPONENT16 = bridge.property(WebGLRenderingContext.DEPTH_COMPONENT16, .{ .template = true, .readonly = true });
    pub const STENCIL_INDEX8 = bridge.property(WebGLRenderingContext.STENCIL_INDEX8, .{ .template = true, .readonly = true });
    pub const DEPTH_STENCIL = bridge.property(WebGLRenderingContext.DEPTH_STENCIL, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_WIDTH = bridge.property(WebGLRenderingContext.RENDERBUFFER_WIDTH, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_HEIGHT = bridge.property(WebGLRenderingContext.RENDERBUFFER_HEIGHT, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_INTERNAL_FORMAT = bridge.property(WebGLRenderingContext.RENDERBUFFER_INTERNAL_FORMAT, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_RED_SIZE = bridge.property(WebGLRenderingContext.RENDERBUFFER_RED_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_GREEN_SIZE = bridge.property(WebGLRenderingContext.RENDERBUFFER_GREEN_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_BLUE_SIZE = bridge.property(WebGLRenderingContext.RENDERBUFFER_BLUE_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_ALPHA_SIZE = bridge.property(WebGLRenderingContext.RENDERBUFFER_ALPHA_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_DEPTH_SIZE = bridge.property(WebGLRenderingContext.RENDERBUFFER_DEPTH_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_STENCIL_SIZE = bridge.property(WebGLRenderingContext.RENDERBUFFER_STENCIL_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE = bridge.property(WebGLRenderingContext.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_OBJECT_NAME = bridge.property(WebGLRenderingContext.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL = bridge.property(WebGLRenderingContext.FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE = bridge.property(WebGLRenderingContext.FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT0 = bridge.property(WebGLRenderingContext.COLOR_ATTACHMENT0, .{ .template = true, .readonly = true });
    pub const DEPTH_ATTACHMENT = bridge.property(WebGLRenderingContext.DEPTH_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const STENCIL_ATTACHMENT = bridge.property(WebGLRenderingContext.STENCIL_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const DEPTH_STENCIL_ATTACHMENT = bridge.property(WebGLRenderingContext.DEPTH_STENCIL_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const NONE = bridge.property(WebGLRenderingContext.NONE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_COMPLETE = bridge.property(WebGLRenderingContext.FRAMEBUFFER_COMPLETE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_ATTACHMENT = bridge.property(WebGLRenderingContext.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT = bridge.property(WebGLRenderingContext.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_DIMENSIONS = bridge.property(WebGLRenderingContext.FRAMEBUFFER_INCOMPLETE_DIMENSIONS, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_UNSUPPORTED = bridge.property(WebGLRenderingContext.FRAMEBUFFER_UNSUPPORTED, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_BINDING = bridge.property(WebGLRenderingContext.FRAMEBUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_BINDING = bridge.property(WebGLRenderingContext.RENDERBUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const MAX_RENDERBUFFER_SIZE = bridge.property(WebGLRenderingContext.MAX_RENDERBUFFER_SIZE, .{ .template = true, .readonly = true });
    pub const INVALID_FRAMEBUFFER_OPERATION = bridge.property(WebGLRenderingContext.INVALID_FRAMEBUFFER_OPERATION, .{ .template = true, .readonly = true });
    pub const UNPACK_FLIP_Y_WEBGL = bridge.property(WebGLRenderingContext.UNPACK_FLIP_Y_WEBGL, .{ .template = true, .readonly = true });
    pub const UNPACK_PREMULTIPLY_ALPHA_WEBGL = bridge.property(WebGLRenderingContext.UNPACK_PREMULTIPLY_ALPHA_WEBGL, .{ .template = true, .readonly = true });
    pub const CONTEXT_LOST_WEBGL = bridge.property(WebGLRenderingContext.CONTEXT_LOST_WEBGL, .{ .template = true, .readonly = true });
    pub const UNPACK_COLORSPACE_CONVERSION_WEBGL = bridge.property(WebGLRenderingContext.UNPACK_COLORSPACE_CONVERSION_WEBGL, .{ .template = true, .readonly = true });
    pub const BROWSER_DEFAULT_WEBGL = bridge.property(WebGLRenderingContext.BROWSER_DEFAULT_WEBGL, .{ .template = true, .readonly = true });
    pub const RGB8 = bridge.property(WebGLRenderingContext.RGB8, .{ .template = true, .readonly = true });
    pub const RGBA8 = bridge.property(WebGLRenderingContext.RGBA8, .{ .template = true, .readonly = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}
