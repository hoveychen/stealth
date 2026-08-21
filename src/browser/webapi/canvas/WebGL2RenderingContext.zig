// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! WebGL 2.0. Same deal as WebGLRenderingContext: no GPU, no rasterization,
//! every state call a no-op, every query answering what the reference Chrome
//! answers for a context with nothing bound and nothing drawn.
//!
//! This is a separate type rather than a subclass because Chrome's is too —
//! `Object.getPrototypeOf(WebGL2RenderingContext.prototype)` is
//! `Object.prototype` there, not `WebGLRenderingContext.prototype`, and both
//! interfaces carry the full flattened member list. Sharing a Zig prototype
//! would be visible to any script that walks the chain.
//!
//! The constant values, the 130 gettable parameters and the 36 extension names
//! all come from a measurement of the real Chrome; see tools/fingerprint/.

const std = @import("std");

const js = @import("../../js/js.zig");
const objects = @import("webgl_objects.zig");
const gpu_table = @import("gpu.zig");
const gpu = gpu_table.gpu;
const DOMException = @import("../DOMException.zig");
const WebGL1 = @import("WebGLRenderingContext.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{WebGL2RenderingContext};
}

const WebGL2RenderingContext = @This();

_canvas: Surface,

/// Shared with WebGL 1, along with the two colour-space attributes below: see
/// WebGLRenderingContext.
_drawing_buffer_color_space: ColorSpace = .srgb,
_unpack_color_space: ColorSpace = .srgb,

pub const Surface = WebGL1.Surface;
pub const ColorSpace = WebGL1.ColorSpace;

// The GLenum constants, measured from Chrome.
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
pub const READ_BUFFER: u32 = 0x0C02;
pub const UNPACK_ROW_LENGTH: u32 = 0x0CF2;
pub const UNPACK_SKIP_ROWS: u32 = 0x0CF3;
pub const UNPACK_SKIP_PIXELS: u32 = 0x0CF4;
pub const PACK_ROW_LENGTH: u32 = 0x0D02;
pub const PACK_SKIP_ROWS: u32 = 0x0D03;
pub const PACK_SKIP_PIXELS: u32 = 0x0D04;
pub const COLOR: u32 = 0x1800;
pub const DEPTH: u32 = 0x1801;
pub const STENCIL: u32 = 0x1802;
pub const RED: u32 = 0x1903;
pub const RGB8: u32 = 0x8051;
pub const RGBA8: u32 = 0x8058;
pub const RGB10_A2: u32 = 0x8059;
pub const TEXTURE_BINDING_3D: u32 = 0x806A;
pub const UNPACK_SKIP_IMAGES: u32 = 0x806D;
pub const UNPACK_IMAGE_HEIGHT: u32 = 0x806E;
pub const TEXTURE_3D: u32 = 0x806F;
pub const TEXTURE_WRAP_R: u32 = 0x8072;
pub const MAX_3D_TEXTURE_SIZE: u32 = 0x8073;
pub const UNSIGNED_INT_2_10_10_10_REV: u32 = 0x8368;
pub const MAX_ELEMENTS_VERTICES: u32 = 0x80E8;
pub const MAX_ELEMENTS_INDICES: u32 = 0x80E9;
pub const TEXTURE_MIN_LOD: u32 = 0x813A;
pub const TEXTURE_MAX_LOD: u32 = 0x813B;
pub const TEXTURE_BASE_LEVEL: u32 = 0x813C;
pub const TEXTURE_MAX_LEVEL: u32 = 0x813D;
pub const MIN: u32 = 0x8007;
pub const MAX: u32 = 0x8008;
pub const DEPTH_COMPONENT24: u32 = 0x81A6;
pub const MAX_TEXTURE_LOD_BIAS: u32 = 0x84FD;
pub const TEXTURE_COMPARE_MODE: u32 = 0x884C;
pub const TEXTURE_COMPARE_FUNC: u32 = 0x884D;
pub const CURRENT_QUERY: u32 = 0x8865;
pub const QUERY_RESULT: u32 = 0x8866;
pub const QUERY_RESULT_AVAILABLE: u32 = 0x8867;
pub const STREAM_READ: u32 = 0x88E1;
pub const STREAM_COPY: u32 = 0x88E2;
pub const STATIC_READ: u32 = 0x88E5;
pub const STATIC_COPY: u32 = 0x88E6;
pub const DYNAMIC_READ: u32 = 0x88E9;
pub const DYNAMIC_COPY: u32 = 0x88EA;
pub const MAX_DRAW_BUFFERS: u32 = 0x8824;
pub const DRAW_BUFFER0: u32 = 0x8825;
pub const DRAW_BUFFER1: u32 = 0x8826;
pub const DRAW_BUFFER2: u32 = 0x8827;
pub const DRAW_BUFFER3: u32 = 0x8828;
pub const DRAW_BUFFER4: u32 = 0x8829;
pub const DRAW_BUFFER5: u32 = 0x882A;
pub const DRAW_BUFFER6: u32 = 0x882B;
pub const DRAW_BUFFER7: u32 = 0x882C;
pub const DRAW_BUFFER8: u32 = 0x882D;
pub const DRAW_BUFFER9: u32 = 0x882E;
pub const DRAW_BUFFER10: u32 = 0x882F;
pub const DRAW_BUFFER11: u32 = 0x8830;
pub const DRAW_BUFFER12: u32 = 0x8831;
pub const DRAW_BUFFER13: u32 = 0x8832;
pub const DRAW_BUFFER14: u32 = 0x8833;
pub const DRAW_BUFFER15: u32 = 0x8834;
pub const MAX_FRAGMENT_UNIFORM_COMPONENTS: u32 = 0x8B49;
pub const MAX_VERTEX_UNIFORM_COMPONENTS: u32 = 0x8B4A;
pub const SAMPLER_3D: u32 = 0x8B5F;
pub const SAMPLER_2D_SHADOW: u32 = 0x8B62;
pub const FRAGMENT_SHADER_DERIVATIVE_HINT: u32 = 0x8B8B;
pub const PIXEL_PACK_BUFFER: u32 = 0x88EB;
pub const PIXEL_UNPACK_BUFFER: u32 = 0x88EC;
pub const PIXEL_PACK_BUFFER_BINDING: u32 = 0x88ED;
pub const PIXEL_UNPACK_BUFFER_BINDING: u32 = 0x88EF;
pub const FLOAT_MAT2x3: u32 = 0x8B65;
pub const FLOAT_MAT2x4: u32 = 0x8B66;
pub const FLOAT_MAT3x2: u32 = 0x8B67;
pub const FLOAT_MAT3x4: u32 = 0x8B68;
pub const FLOAT_MAT4x2: u32 = 0x8B69;
pub const FLOAT_MAT4x3: u32 = 0x8B6A;
pub const SRGB: u32 = 0x8C40;
pub const SRGB8: u32 = 0x8C41;
pub const SRGB8_ALPHA8: u32 = 0x8C43;
pub const COMPARE_REF_TO_TEXTURE: u32 = 0x884E;
pub const RGBA32F: u32 = 0x8814;
pub const RGB32F: u32 = 0x8815;
pub const RGBA16F: u32 = 0x881A;
pub const RGB16F: u32 = 0x881B;
pub const VERTEX_ATTRIB_ARRAY_INTEGER: u32 = 0x88FD;
pub const MAX_ARRAY_TEXTURE_LAYERS: u32 = 0x88FF;
pub const MIN_PROGRAM_TEXEL_OFFSET: u32 = 0x8904;
pub const MAX_PROGRAM_TEXEL_OFFSET: u32 = 0x8905;
pub const MAX_VARYING_COMPONENTS: u32 = 0x8B4B;
pub const TEXTURE_2D_ARRAY: u32 = 0x8C1A;
pub const TEXTURE_BINDING_2D_ARRAY: u32 = 0x8C1D;
pub const R11F_G11F_B10F: u32 = 0x8C3A;
pub const UNSIGNED_INT_10F_11F_11F_REV: u32 = 0x8C3B;
pub const RGB9_E5: u32 = 0x8C3D;
pub const UNSIGNED_INT_5_9_9_9_REV: u32 = 0x8C3E;
pub const TRANSFORM_FEEDBACK_BUFFER_MODE: u32 = 0x8C7F;
pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS: u32 = 0x8C80;
pub const TRANSFORM_FEEDBACK_VARYINGS: u32 = 0x8C83;
pub const TRANSFORM_FEEDBACK_BUFFER_START: u32 = 0x8C84;
pub const TRANSFORM_FEEDBACK_BUFFER_SIZE: u32 = 0x8C85;
pub const TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN: u32 = 0x8C88;
pub const RASTERIZER_DISCARD: u32 = 0x8C89;
pub const MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: u32 = 0x8C8A;
pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: u32 = 0x8C8B;
pub const INTERLEAVED_ATTRIBS: u32 = 0x8C8C;
pub const SEPARATE_ATTRIBS: u32 = 0x8C8D;
pub const TRANSFORM_FEEDBACK_BUFFER: u32 = 0x8C8E;
pub const TRANSFORM_FEEDBACK_BUFFER_BINDING: u32 = 0x8C8F;
pub const RGBA32UI: u32 = 0x8D70;
pub const RGB32UI: u32 = 0x8D71;
pub const RGBA16UI: u32 = 0x8D76;
pub const RGB16UI: u32 = 0x8D77;
pub const RGBA8UI: u32 = 0x8D7C;
pub const RGB8UI: u32 = 0x8D7D;
pub const RGBA32I: u32 = 0x8D82;
pub const RGB32I: u32 = 0x8D83;
pub const RGBA16I: u32 = 0x8D88;
pub const RGB16I: u32 = 0x8D89;
pub const RGBA8I: u32 = 0x8D8E;
pub const RGB8I: u32 = 0x8D8F;
pub const RED_INTEGER: u32 = 0x8D94;
pub const RGB_INTEGER: u32 = 0x8D98;
pub const RGBA_INTEGER: u32 = 0x8D99;
pub const SAMPLER_2D_ARRAY: u32 = 0x8DC1;
pub const SAMPLER_2D_ARRAY_SHADOW: u32 = 0x8DC4;
pub const SAMPLER_CUBE_SHADOW: u32 = 0x8DC5;
pub const UNSIGNED_INT_VEC2: u32 = 0x8DC6;
pub const UNSIGNED_INT_VEC3: u32 = 0x8DC7;
pub const UNSIGNED_INT_VEC4: u32 = 0x8DC8;
pub const INT_SAMPLER_2D: u32 = 0x8DCA;
pub const INT_SAMPLER_3D: u32 = 0x8DCB;
pub const INT_SAMPLER_CUBE: u32 = 0x8DCC;
pub const INT_SAMPLER_2D_ARRAY: u32 = 0x8DCF;
pub const UNSIGNED_INT_SAMPLER_2D: u32 = 0x8DD2;
pub const UNSIGNED_INT_SAMPLER_3D: u32 = 0x8DD3;
pub const UNSIGNED_INT_SAMPLER_CUBE: u32 = 0x8DD4;
pub const UNSIGNED_INT_SAMPLER_2D_ARRAY: u32 = 0x8DD7;
pub const DEPTH_COMPONENT32F: u32 = 0x8CAC;
pub const DEPTH32F_STENCIL8: u32 = 0x8CAD;
pub const FLOAT_32_UNSIGNED_INT_24_8_REV: u32 = 0x8DAD;
pub const FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING: u32 = 0x8210;
pub const FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE: u32 = 0x8211;
pub const FRAMEBUFFER_ATTACHMENT_RED_SIZE: u32 = 0x8212;
pub const FRAMEBUFFER_ATTACHMENT_GREEN_SIZE: u32 = 0x8213;
pub const FRAMEBUFFER_ATTACHMENT_BLUE_SIZE: u32 = 0x8214;
pub const FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE: u32 = 0x8215;
pub const FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE: u32 = 0x8216;
pub const FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE: u32 = 0x8217;
pub const FRAMEBUFFER_DEFAULT: u32 = 0x8218;
pub const UNSIGNED_INT_24_8: u32 = 0x84FA;
pub const DEPTH24_STENCIL8: u32 = 0x88F0;
pub const UNSIGNED_NORMALIZED: u32 = 0x8C17;
pub const DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;
pub const READ_FRAMEBUFFER: u32 = 0x8CA8;
pub const DRAW_FRAMEBUFFER: u32 = 0x8CA9;
pub const READ_FRAMEBUFFER_BINDING: u32 = 0x8CAA;
pub const RENDERBUFFER_SAMPLES: u32 = 0x8CAB;
pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER: u32 = 0x8CD4;
pub const MAX_COLOR_ATTACHMENTS: u32 = 0x8CDF;
pub const COLOR_ATTACHMENT1: u32 = 0x8CE1;
pub const COLOR_ATTACHMENT2: u32 = 0x8CE2;
pub const COLOR_ATTACHMENT3: u32 = 0x8CE3;
pub const COLOR_ATTACHMENT4: u32 = 0x8CE4;
pub const COLOR_ATTACHMENT5: u32 = 0x8CE5;
pub const COLOR_ATTACHMENT6: u32 = 0x8CE6;
pub const COLOR_ATTACHMENT7: u32 = 0x8CE7;
pub const COLOR_ATTACHMENT8: u32 = 0x8CE8;
pub const COLOR_ATTACHMENT9: u32 = 0x8CE9;
pub const COLOR_ATTACHMENT10: u32 = 0x8CEA;
pub const COLOR_ATTACHMENT11: u32 = 0x8CEB;
pub const COLOR_ATTACHMENT12: u32 = 0x8CEC;
pub const COLOR_ATTACHMENT13: u32 = 0x8CED;
pub const COLOR_ATTACHMENT14: u32 = 0x8CEE;
pub const COLOR_ATTACHMENT15: u32 = 0x8CEF;
pub const FRAMEBUFFER_INCOMPLETE_MULTISAMPLE: u32 = 0x8D56;
pub const MAX_SAMPLES: u32 = 0x8D57;
pub const HALF_FLOAT: u32 = 0x140B;
pub const RG: u32 = 0x8227;
pub const RG_INTEGER: u32 = 0x8228;
pub const R8: u32 = 0x8229;
pub const RG8: u32 = 0x822B;
pub const R16F: u32 = 0x822D;
pub const R32F: u32 = 0x822E;
pub const RG16F: u32 = 0x822F;
pub const RG32F: u32 = 0x8230;
pub const R8I: u32 = 0x8231;
pub const R8UI: u32 = 0x8232;
pub const R16I: u32 = 0x8233;
pub const R16UI: u32 = 0x8234;
pub const R32I: u32 = 0x8235;
pub const R32UI: u32 = 0x8236;
pub const RG8I: u32 = 0x8237;
pub const RG8UI: u32 = 0x8238;
pub const RG16I: u32 = 0x8239;
pub const RG16UI: u32 = 0x823A;
pub const RG32I: u32 = 0x823B;
pub const RG32UI: u32 = 0x823C;
pub const VERTEX_ARRAY_BINDING: u32 = 0x85B5;
pub const R8_SNORM: u32 = 0x8F94;
pub const RG8_SNORM: u32 = 0x8F95;
pub const RGB8_SNORM: u32 = 0x8F96;
pub const RGBA8_SNORM: u32 = 0x8F97;
pub const SIGNED_NORMALIZED: u32 = 0x8F9C;
pub const COPY_READ_BUFFER: u32 = 0x8F36;
pub const COPY_WRITE_BUFFER: u32 = 0x8F37;
pub const COPY_READ_BUFFER_BINDING: u32 = 0x8F36;
pub const COPY_WRITE_BUFFER_BINDING: u32 = 0x8F37;
pub const UNIFORM_BUFFER: u32 = 0x8A11;
pub const UNIFORM_BUFFER_BINDING: u32 = 0x8A28;
pub const UNIFORM_BUFFER_START: u32 = 0x8A29;
pub const UNIFORM_BUFFER_SIZE: u32 = 0x8A2A;
pub const MAX_VERTEX_UNIFORM_BLOCKS: u32 = 0x8A2B;
pub const MAX_FRAGMENT_UNIFORM_BLOCKS: u32 = 0x8A2D;
pub const MAX_COMBINED_UNIFORM_BLOCKS: u32 = 0x8A2E;
pub const MAX_UNIFORM_BUFFER_BINDINGS: u32 = 0x8A2F;
pub const MAX_UNIFORM_BLOCK_SIZE: u32 = 0x8A30;
pub const MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS: u32 = 0x8A31;
pub const MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS: u32 = 0x8A33;
pub const UNIFORM_BUFFER_OFFSET_ALIGNMENT: u32 = 0x8A34;
pub const ACTIVE_UNIFORM_BLOCKS: u32 = 0x8A36;
pub const UNIFORM_TYPE: u32 = 0x8A37;
pub const UNIFORM_SIZE: u32 = 0x8A38;
pub const UNIFORM_BLOCK_INDEX: u32 = 0x8A3A;
pub const UNIFORM_OFFSET: u32 = 0x8A3B;
pub const UNIFORM_ARRAY_STRIDE: u32 = 0x8A3C;
pub const UNIFORM_MATRIX_STRIDE: u32 = 0x8A3D;
pub const UNIFORM_IS_ROW_MAJOR: u32 = 0x8A3E;
pub const UNIFORM_BLOCK_BINDING: u32 = 0x8A3F;
pub const UNIFORM_BLOCK_DATA_SIZE: u32 = 0x8A40;
pub const UNIFORM_BLOCK_ACTIVE_UNIFORMS: u32 = 0x8A42;
pub const UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES: u32 = 0x8A43;
pub const UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER: u32 = 0x8A44;
pub const UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER: u32 = 0x8A46;
pub const INVALID_INDEX: u32 = 0xFFFFFFFF;
pub const MAX_VERTEX_OUTPUT_COMPONENTS: u32 = 0x9122;
pub const MAX_FRAGMENT_INPUT_COMPONENTS: u32 = 0x9125;
pub const MAX_SERVER_WAIT_TIMEOUT: u32 = 0x9111;
pub const OBJECT_TYPE: u32 = 0x9112;
pub const SYNC_CONDITION: u32 = 0x9113;
pub const SYNC_STATUS: u32 = 0x9114;
pub const SYNC_FLAGS: u32 = 0x9115;
pub const SYNC_FENCE: u32 = 0x9116;
pub const SYNC_GPU_COMMANDS_COMPLETE: u32 = 0x9117;
pub const UNSIGNALED: u32 = 0x9118;
pub const SIGNALED: u32 = 0x9119;
pub const ALREADY_SIGNALED: u32 = 0x911A;
pub const TIMEOUT_EXPIRED: u32 = 0x911B;
pub const CONDITION_SATISFIED: u32 = 0x911C;
pub const WAIT_FAILED: u32 = 0x911D;
pub const SYNC_FLUSH_COMMANDS_BIT: u32 = 0x0001;
pub const VERTEX_ATTRIB_ARRAY_DIVISOR: u32 = 0x88FE;
pub const ANY_SAMPLES_PASSED: u32 = 0x8C2F;
pub const ANY_SAMPLES_PASSED_CONSERVATIVE: u32 = 0x8D6A;
pub const SAMPLER_BINDING: u32 = 0x8919;
pub const RGB10_A2UI: u32 = 0x906F;
pub const INT_2_10_10_10_REV: u32 = 0x8D9F;
pub const TRANSFORM_FEEDBACK: u32 = 0x8E22;
pub const TRANSFORM_FEEDBACK_PAUSED: u32 = 0x8E23;
pub const TRANSFORM_FEEDBACK_ACTIVE: u32 = 0x8E24;
pub const TRANSFORM_FEEDBACK_BINDING: u32 = 0x8E25;
pub const TEXTURE_IMMUTABLE_FORMAT: u32 = 0x912F;
pub const MAX_ELEMENT_INDEX: u32 = 0x8D6B;
pub const TEXTURE_IMMUTABLE_LEVELS: u32 = 0x82DF;
/// The one signed constant on the interface: a GLint64 sentinel, which Chrome
/// hands to JS as -1 rather than as an unsigned wrap-around.
pub const TIMEOUT_IGNORED: f64 = -1;
pub const MAX_CLIENT_WAIT_TIMEOUT_WEBGL: u32 = 0x9247;

/// WebGL 2.0 advertises a different extension set than 1.0 does — names it adds,
/// and names it drops because they became core. Order is Chrome's, which is
/// alphabetical. This is the union of both reference drivers; which of them the
/// claimed one actually has is `advertised_extension_names` below.
const extension_names = [_][]const u8{
    "EXT_clip_control",
    "EXT_color_buffer_float",
    "EXT_color_buffer_half_float",
    "EXT_conservative_depth",
    "EXT_depth_clamp",
    "EXT_disjoint_timer_query_webgl2",
    "EXT_float_blend",
    "EXT_polygon_offset_clamp",
    "EXT_render_snorm",
    "EXT_texture_compression_bptc",
    "EXT_texture_compression_rgtc",
    "EXT_texture_filter_anisotropic",
    "EXT_texture_mirror_clamp_to_edge",
    "EXT_texture_norm16",
    "KHR_parallel_shader_compile",
    "NV_shader_noperspective_interpolation",
    "OES_draw_buffers_indexed",
    "OES_sample_variables",
    "OES_shader_multisample_interpolation",
    "OES_texture_float_linear",
    "OVR_multiview2",
    "WEBGL_blend_func_extended",
    "WEBGL_clip_cull_distance",
    "WEBGL_compressed_texture_astc",
    "WEBGL_compressed_texture_etc",
    "WEBGL_compressed_texture_etc1",
    "WEBGL_compressed_texture_pvrtc",
    "WEBGL_compressed_texture_s3tc",
    "WEBGL_compressed_texture_s3tc_srgb",
    "WEBGL_debug_renderer_info",
    "WEBGL_debug_shaders",
    "WEBGL_lose_context",
    "WEBGL_multi_draw",
    "WEBGL_polygon_mode",
    "WEBGL_provoking_vertex",
    "WEBGL_render_shared_exponent",
    "WEBGL_stencil_texturing",
};

/// The two extensions that hand an object back; the rest answer with an empty
/// object, which is what a script gets from Chrome for a supported extension
/// that exposes no members of its own.
const Extension = union(enum) {
    debug_renderer_info: *WebGL1.Extension.Type.WEBGL_debug_renderer_info,
    lose_context: *WebGL1.Extension.Type.WEBGL_lose_context,
    supported: struct {},
};

/// The subset the claimed platform's driver has: eight of the names above are
/// Apple-GPU only, and OVR_multiview2 is SwiftShader-only.
const advertised_extension_names = gpu_table.advertised(&extension_names, gpu.webgl2_unsupported);

pub fn getSupportedExtensions(_: *const WebGL2RenderingContext) []const []const u8 {
    return advertised_extension_names;
}

pub fn getExtension(_: *const WebGL2RenderingContext, name: []const u8, exec: *Execution) !?Extension {
    var supported = false;
    for (advertised_extension_names) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) {
            supported = true;
            break;
        }
    }
    if (supported == false) {
        return null;
    }

    if (std.ascii.eqlIgnoreCase(name, "WEBGL_debug_renderer_info")) {
        return .{ .debug_renderer_info = try exec._factory.create(WebGL1.Extension.Type.WEBGL_debug_renderer_info{}) };
    }
    if (std.ascii.eqlIgnoreCase(name, "WEBGL_lose_context")) {
        return .{ .lose_context = try exec._factory.create(WebGL1.Extension.Type.WEBGL_lose_context{}) };
    }
    return .{ .supported = .{} };
}

pub fn getCanvas(self: *const WebGL2RenderingContext) Surface {
    return self._canvas;
}

pub fn getDrawingBufferWidth(self: *const WebGL2RenderingContext) u32 {
    return self._canvas.width();
}

pub fn getDrawingBufferHeight(self: *const WebGL2RenderingContext) u32 {
    return self._canvas.height();
}

pub fn getDrawingBufferFormat(_: *const WebGL2RenderingContext) u32 {
    return RGBA8;
}

pub fn getDrawingBufferColorSpace(self: *const WebGL2RenderingContext) []const u8 {
    return @tagName(self._drawing_buffer_color_space);
}

pub fn setDrawingBufferColorSpace(self: *WebGL2RenderingContext, value: []const u8) void {
    if (std.meta.stringToEnum(ColorSpace, value)) |cs| {
        self._drawing_buffer_color_space = cs;
    }
}

pub fn getUnpackColorSpace(self: *const WebGL2RenderingContext) []const u8 {
    return @tagName(self._unpack_color_space);
}

pub fn setUnpackColorSpace(self: *WebGL2RenderingContext, value: []const u8) void {
    if (std.meta.stringToEnum(ColorSpace, value)) |cs| {
        self._unpack_color_space = cs;
    }
}

const Parameter = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
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

pub fn getParameter(self: *const WebGL2RenderingContext, pname: u32, exec: *Execution) !?Parameter {
    const answer: ?Parameter = switch (pname) {
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
        READ_BUFFER => .{ .number = 1029 },
        UNPACK_ROW_LENGTH => .{ .number = 0 },
        UNPACK_SKIP_ROWS => .{ .number = 0 },
        UNPACK_SKIP_PIXELS => .{ .number = 0 },
        PACK_ROW_LENGTH => .{ .number = 0 },
        PACK_SKIP_ROWS => .{ .number = 0 },
        PACK_SKIP_PIXELS => .{ .number = 0 },
        UNPACK_SKIP_IMAGES => .{ .number = 0 },
        UNPACK_IMAGE_HEIGHT => .{ .number = 0 },
        MAX_3D_TEXTURE_SIZE => .{ .number = 2048 },
        MAX_ELEMENTS_VERTICES => .{ .number = 2147483647 },
        MAX_ELEMENTS_INDICES => .{ .number = 2147483647 },
        MAX_TEXTURE_LOD_BIAS => .{ .number = 15 },
        MAX_DRAW_BUFFERS => .{ .number = gpu.max_draw_buffers },
        // Only as many slots as MAX_DRAW_BUFFERS: querying DRAW_BUFFER6 on a
        // six-buffer context is not a gettable state variable, and Chrome
        // answers null rather than a slot value (measured). Where the run stops
        // therefore moves with the limit above -- six slots on SwiftShader,
        // eight on Metal.
        DRAW_BUFFER0...DRAW_BUFFER15 => if (pname - DRAW_BUFFER0 < gpu.max_draw_buffers)
            .{ .number = 1029 }
        else
            null,
        MAX_FRAGMENT_UNIFORM_COMPONENTS => .{ .number = gpu.max_fragment_uniform_components },
        MAX_VERTEX_UNIFORM_COMPONENTS => .{ .number = gpu.max_vertex_uniform_components },
        FRAGMENT_SHADER_DERIVATIVE_HINT => .{ .number = 4352 },
        MAX_ARRAY_TEXTURE_LAYERS => .{ .number = 2048 },
        MIN_PROGRAM_TEXEL_OFFSET => .{ .number = -8 },
        MAX_PROGRAM_TEXEL_OFFSET => .{ .number = 7 },
        MAX_VARYING_COMPONENTS => .{ .number = gpu.max_varying_components },
        MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS => .{ .number = 4 },
        MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS => .{ .number = 128 },
        MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS => .{ .number = 4 },
        MAX_COLOR_ATTACHMENTS => .{ .number = gpu.max_color_attachments },
        MAX_SAMPLES => .{ .number = 4 },
        MAX_VERTEX_UNIFORM_BLOCKS => .{ .number = gpu.max_vertex_uniform_blocks },
        MAX_FRAGMENT_UNIFORM_BLOCKS => .{ .number = gpu.max_fragment_uniform_blocks },
        MAX_COMBINED_UNIFORM_BLOCKS => .{ .number = gpu.max_combined_uniform_blocks },
        MAX_UNIFORM_BUFFER_BINDINGS => .{ .number = gpu.max_uniform_buffer_bindings },
        MAX_UNIFORM_BLOCK_SIZE => .{ .number = gpu.max_uniform_block_size },
        MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS => .{ .number = gpu.max_combined_vertex_uniform_components },
        MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS => .{ .number = gpu.max_combined_fragment_uniform_components },
        UNIFORM_BUFFER_OFFSET_ALIGNMENT => .{ .number = gpu.uniform_buffer_offset_alignment },
        MAX_VERTEX_OUTPUT_COMPONENTS => .{ .number = gpu.max_vertex_output_components },
        MAX_FRAGMENT_INPUT_COMPONENTS => .{ .number = gpu.max_fragment_input_components },
        MAX_SERVER_WAIT_TIMEOUT => .{ .number = 0 },
        MAX_ELEMENT_INDEX => .{ .number = gpu.max_element_index },
        MAX_CLIENT_WAIT_TIMEOUT_WEBGL => .{ .number = 0 },
        SHADING_LANGUAGE_VERSION => .{ .string = "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Chromium)" },
        VENDOR => .{ .string = "WebKit" },
        RENDERER => .{ .string = "WebKit WebGL" },
        VERSION => .{ .string = "WebGL 2.0 (OpenGL ES 3.0 Chromium)" },
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
        RASTERIZER_DISCARD => .{ .boolean = false },
        TRANSFORM_FEEDBACK_PAUSED => .{ .boolean = false },
        TRANSFORM_FEEDBACK_ACTIVE => .{ .boolean = false },
        BLEND_COLOR => floatArray(exec, &.{ 0, 0, 0, 0 }),
        ALIASED_POINT_SIZE_RANGE => floatArray(exec, &.{ 1, gpu.aliased_point_size_max }),
        ALIASED_LINE_WIDTH_RANGE => floatArray(exec, &.{ 1, 1 }),
        DEPTH_RANGE => floatArray(exec, &.{ 0, 1 }),
        COLOR_CLEAR_VALUE => floatArray(exec, &.{ 0, 0, 0, 0 }),
        MAX_VIEWPORT_DIMS => intArray(exec, &.{ gpu.max_viewport_dim, gpu.max_viewport_dim }),
        COMPRESSED_TEXTURE_FORMATS => uintArray(exec, &.{}),
        COLOR_WRITEMASK => .{ .booleans = &.{ true, true, true, true } },
        // The viewport and scissor box default to the whole drawing buffer.
        VIEWPORT, SCISSOR_BOX => intArray(exec, &.{ 0, 0, @intCast(self._canvas.width()), @intCast(self._canvas.height()) }),
        WebGL1.Extension.Type.WEBGL_debug_renderer_info.UNMASKED_VENDOR_WEBGL => .{ .string = gpu.unmasked_vendor },
        WebGL1.Extension.Type.WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL => .{ .string = gpu.unmasked_renderer },
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

// ---------------------------------------------------------------------------
// The calls.

pub fn createBuffer(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLBuffer {
    return objects.handle(objects.WebGLBuffer, exec);
}

pub fn createFramebuffer(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLFramebuffer {
    return objects.handle(objects.WebGLFramebuffer, exec);
}

pub fn createProgram(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLProgram {
    return objects.handle(objects.WebGLProgram, exec);
}

pub fn createRenderbuffer(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLRenderbuffer {
    return objects.handle(objects.WebGLRenderbuffer, exec);
}

pub fn createShader(_: *const WebGL2RenderingContext, _: u32, exec: *Execution) !*objects.WebGLShader {
    return objects.handle(objects.WebGLShader, exec);
}

pub fn createTexture(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLTexture {
    return objects.handle(objects.WebGLTexture, exec);
}

pub fn createQuery(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLQuery {
    return objects.handle(objects.WebGLQuery, exec);
}

pub fn createSampler(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLSampler {
    return objects.handle(objects.WebGLSampler, exec);
}

pub fn createVertexArray(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLVertexArrayObject {
    return objects.handle(objects.WebGLVertexArrayObject, exec);
}

pub fn createTransformFeedback(_: *const WebGL2RenderingContext, exec: *Execution) !*objects.WebGLTransformFeedback {
    return objects.handle(objects.WebGLTransformFeedback, exec);
}

pub fn fenceSync(_: *const WebGL2RenderingContext, _: u32, _: u32, exec: *Execution) !*objects.WebGLSync {
    return objects.handle(objects.WebGLSync, exec);
}

pub fn checkFramebufferStatus(_: *const WebGL2RenderingContext, _: u32) u32 {
    return FRAMEBUFFER_COMPLETE;
}

pub fn getError(_: *const WebGL2RenderingContext) u32 {
    return NO_ERROR;
}

pub fn isContextLost(_: *const WebGL2RenderingContext) bool {
    return false;
}

pub fn isEnabled(_: *const WebGL2RenderingContext, cap: u32) bool {
    return cap == DITHER;
}

pub fn isBuffer(_: *const WebGL2RenderingContext, buffer: ?*objects.WebGLBuffer) bool {
    return buffer != null;
}

pub fn isFramebuffer(_: *const WebGL2RenderingContext, framebuffer: ?*objects.WebGLFramebuffer) bool {
    return framebuffer != null;
}

pub fn isProgram(_: *const WebGL2RenderingContext, program: ?*objects.WebGLProgram) bool {
    return program != null;
}

pub fn isRenderbuffer(_: *const WebGL2RenderingContext, renderbuffer: ?*objects.WebGLRenderbuffer) bool {
    return renderbuffer != null;
}

pub fn isShader(_: *const WebGL2RenderingContext, shader: ?*objects.WebGLShader) bool {
    return shader != null;
}

pub fn isTexture(_: *const WebGL2RenderingContext, texture: ?*objects.WebGLTexture) bool {
    return texture != null;
}

pub fn isSampler(_: *const WebGL2RenderingContext, sampler: ?*objects.WebGLSampler) bool {
    return sampler != null;
}

pub fn isSync(_: *const WebGL2RenderingContext, sync: ?*objects.WebGLSync) bool {
    return sync != null;
}

// Chrome answers false for these two until the object has actually been bound;
// samplers and syncs are valid the moment they exist. We have no binding state,
// so this mirrors the measurement rather than deriving it.
pub fn isQuery(_: *const WebGL2RenderingContext, _: ?*objects.WebGLQuery) bool {
    return false;
}

pub fn isVertexArray(_: *const WebGL2RenderingContext, _: ?*objects.WebGLVertexArrayObject) bool {
    return false;
}

pub fn isTransformFeedback(_: *const WebGL2RenderingContext, _: ?*objects.WebGLTransformFeedback) bool {
    return false;
}

pub fn getShaderInfoLog(_: *const WebGL2RenderingContext, _: ?*objects.WebGLShader) []const u8 {
    return "";
}

pub fn getProgramInfoLog(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram) []const u8 {
    return "";
}

pub fn getShaderSource(_: *const WebGL2RenderingContext, _: ?*objects.WebGLShader) []const u8 {
    return "";
}

pub fn getShaderParameter(_: *const WebGL2RenderingContext, _: ?*objects.WebGLShader, pname: u32) ?Parameter {
    return switch (pname) {
        SHADER_TYPE => .{ .number = VERTEX_SHADER },
        DELETE_STATUS, COMPILE_STATUS => .{ .boolean = false },
        else => null,
    };
}

pub fn getProgramParameter(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, pname: u32) ?Parameter {
    return switch (pname) {
        DELETE_STATUS, LINK_STATUS, VALIDATE_STATUS => .{ .boolean = false },
        ATTACHED_SHADERS, ACTIVE_UNIFORMS, ACTIVE_ATTRIBUTES, ACTIVE_UNIFORM_BLOCKS, TRANSFORM_FEEDBACK_VARYINGS => .{ .number = 0 },
        TRANSFORM_FEEDBACK_BUFFER_MODE => .{ .number = INTERLEAVED_ATTRIBS },
        else => null,
    };
}

pub fn getBufferParameter(_: *const WebGL2RenderingContext, _: u32, pname: u32) ?Parameter {
    return switch (pname) {
        BUFFER_SIZE => .{ .number = 0 },
        BUFFER_USAGE => .{ .number = STATIC_DRAW },
        else => null,
    };
}

pub fn getTexParameter(_: *const WebGL2RenderingContext, _: u32, pname: u32) ?Parameter {
    return switch (pname) {
        TEXTURE_MAG_FILTER => .{ .number = LINEAR },
        TEXTURE_MIN_FILTER => .{ .number = NEAREST_MIPMAP_LINEAR },
        TEXTURE_WRAP_S, TEXTURE_WRAP_T, TEXTURE_WRAP_R => .{ .number = REPEAT },
        else => null,
    };
}

pub fn getSamplerParameter(_: *const WebGL2RenderingContext, _: ?*objects.WebGLSampler, pname: u32) ?Parameter {
    return switch (pname) {
        TEXTURE_MAG_FILTER => .{ .number = LINEAR },
        TEXTURE_MIN_FILTER => .{ .number = NEAREST_MIPMAP_LINEAR },
        TEXTURE_WRAP_S, TEXTURE_WRAP_T, TEXTURE_WRAP_R => .{ .number = REPEAT },
        else => null,
    };
}

pub fn getRenderbufferParameter(_: *const WebGL2RenderingContext, _: u32, pname: u32) ?Parameter {
    return switch (pname) {
        RENDERBUFFER_WIDTH,
        RENDERBUFFER_HEIGHT,
        RENDERBUFFER_RED_SIZE,
        RENDERBUFFER_GREEN_SIZE,
        RENDERBUFFER_BLUE_SIZE,
        RENDERBUFFER_ALPHA_SIZE,
        RENDERBUFFER_DEPTH_SIZE,
        RENDERBUFFER_STENCIL_SIZE,
        RENDERBUFFER_SAMPLES,
        => .{ .number = 0 },
        RENDERBUFFER_INTERNAL_FORMAT => .{ .number = RGBA4 },
        else => null,
    };
}

pub fn getVertexAttrib(_: *const WebGL2RenderingContext, _: u32, pname: u32, exec: *Execution) ?Parameter {
    return switch (pname) {
        VERTEX_ATTRIB_ARRAY_ENABLED, VERTEX_ATTRIB_ARRAY_NORMALIZED, VERTEX_ATTRIB_ARRAY_INTEGER => .{ .boolean = false },
        VERTEX_ATTRIB_ARRAY_SIZE => .{ .number = 4 },
        VERTEX_ATTRIB_ARRAY_STRIDE, VERTEX_ATTRIB_ARRAY_DIVISOR => .{ .number = 0 },
        VERTEX_ATTRIB_ARRAY_TYPE => .{ .number = FLOAT },
        CURRENT_VERTEX_ATTRIB => floatArray(exec, &.{ 0, 0, 0, 1 }),
        else => null,
    };
}

pub fn getVertexAttribOffset(_: *const WebGL2RenderingContext, _: u32, _: u32) u32 {
    return 0;
}

pub fn getShaderPrecisionFormat(
    _: *const WebGL2RenderingContext,
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

pub fn getActiveAttrib(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: u32) ?*objects.WebGLActiveInfo {
    return null;
}

pub fn getActiveUniform(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: u32) ?*objects.WebGLActiveInfo {
    return null;
}

pub fn getTransformFeedbackVarying(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: u32) ?*objects.WebGLActiveInfo {
    return null;
}

pub fn getAttachedShaders(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram) []const *objects.WebGLShader {
    return &.{};
}

pub fn getAttribLocation(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: []const u8) i32 {
    return -1;
}

pub fn getFragDataLocation(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: []const u8) i32 {
    return -1;
}

pub fn getUniformLocation(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: []const u8) ?*objects.WebGLUniformLocation {
    return null;
}

pub fn getUniform(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: ?*objects.WebGLUniformLocation) ?Parameter {
    return null;
}

/// GL_INVALID_INDEX. Chrome answers this for a name that is not an active
/// uniform block, which for an un-linked program is every name.
const invalid_index: f64 = 0xFFFFFFFF;

pub fn getUniformBlockIndex(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: []const u8) f64 {
    return invalid_index;
}

pub fn getUniformIndices(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, names: []const []const u8, exec: *Execution) Parameter {
    const local = exec.js.local.?;
    const array = local.createTypedArray(.uint32, names.len);
    @memset(array.slice(), 0xFFFFFFFF);
    return .{ .value = .{ .local = local, .handle = array.handle } };
}

pub fn getActiveUniforms(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: []const u32, _: u32) ?Parameter {
    return null;
}

pub fn getActiveUniformBlockName(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: u32) ?[]const u8 {
    return null;
}

pub fn getActiveUniformBlockParameter(_: *const WebGL2RenderingContext, _: ?*objects.WebGLProgram, _: u32, _: u32) ?Parameter {
    return null;
}

pub fn getFramebufferAttachmentParameter(_: *const WebGL2RenderingContext, _: u32, _: u32, _: u32) ?Parameter {
    return null;
}

pub fn getIndexedParameter(_: *const WebGL2RenderingContext, _: u32, _: u32) ?Parameter {
    return null;
}

pub fn getQuery(_: *const WebGL2RenderingContext, _: u32, _: u32) ?*objects.WebGLQuery {
    return null;
}

pub fn getQueryParameter(_: *const WebGL2RenderingContext, _: ?*objects.WebGLQuery, _: u32) ?Parameter {
    return null;
}

/// Chrome reports a fresh fence sync as UNSIGNALED, and a zero-timeout wait on
/// it as TIMEOUT_EXPIRED rather than ALREADY_SIGNALED — measured, and the
/// opposite of what "we never queued any work behind it" would suggest.
pub fn getSyncParameter(_: *const WebGL2RenderingContext, _: ?*objects.WebGLSync, pname: u32) ?Parameter {
    return switch (pname) {
        SYNC_STATUS => .{ .number = UNSIGNALED },
        OBJECT_TYPE => .{ .number = SYNC_FENCE },
        SYNC_CONDITION => .{ .number = SYNC_GPU_COMMANDS_COMPLETE },
        SYNC_FLAGS => .{ .number = 0 },
        else => null,
    };
}

pub fn clientWaitSync(_: *const WebGL2RenderingContext, _: ?*objects.WebGLSync, _: u32, _: u32) u32 {
    return TIMEOUT_EXPIRED;
}

/// SAMPLES for a multisample-capable format; Chrome reports 4 and 2 here.
pub fn getInternalformatParameter(_: *const WebGL2RenderingContext, _: u32, _: u32, pname: u32, exec: *Execution) ?Parameter {
    if (pname != SAMPLES) {
        return null;
    }
    return intArray(exec, gpu.internalformat_samples);
}

const ContextAttributes = struct {
    alpha: bool = true,
    antialias: bool = true,
    depth: bool = true,
    desynchronized: bool = false,
    failIfMajorPerformanceCaveat: bool = false,
    powerPreference: []const u8 = "default",
    premultipliedAlpha: bool = true,
    preserveDrawingBuffer: bool = false,
    stencil: bool = false,
    xrCompatible: bool = false,
};

/// WebXR's hook into a WebGL context. Chrome rejects with a bare
/// InvalidStateError -- "An attempt was made to use an object that is not, or
/// is no longer, usable." -- when there is no XR device to make the context
/// compatible *with*, which is every machine this engine runs on (measured on
/// a headed Chrome 150). The `xrCompatible` context attribute stays false.
pub fn makeXRCompatible(_: *const WebGL2RenderingContext, exec: *const js.Execution) !js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("webgl", DOMException.init(
        "An attempt was made to use an object that is not, or is no longer, usable.",
        "InvalidStateError",
    ));
    return resolver.promise();
}

pub fn getContextAttributes(_: *const WebGL2RenderingContext) ContextAttributes {
    return .{};
}

// The state setters, plus readPixels and getBufferSubData, which write into a
// caller-supplied buffer that Chrome leaves at zero for a context this empty.

pub fn activeTexture(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn attachShader(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn beginQuery(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn beginTransformFeedback(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn bindAttribLocation(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn bindBuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindBufferBase(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn bindBufferRange(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn bindFramebuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindRenderbuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindSampler(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindTexture(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindTransformFeedback(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn bindVertexArray(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn blendColor(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn blendEquation(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn blendEquationSeparate(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn blendFunc(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn blendFuncSeparate(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn blitFramebuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn bufferData(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn bufferSubData(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clear(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn clearBufferfi(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clearBufferfv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clearBufferiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clearBufferuiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clearColor(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn clearDepth(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn clearStencil(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn colorMask(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn compileShader(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn compressedTexImage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn compressedTexImage3D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn compressedTexSubImage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn compressedTexSubImage3D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn copyBufferSubData(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn copyTexImage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn copyTexSubImage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn copyTexSubImage3D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn cullFace(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteBuffer(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteFramebuffer(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteProgram(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteQuery(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteRenderbuffer(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteSampler(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteShader(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteSync(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteTexture(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteTransformFeedback(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn deleteVertexArray(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn depthFunc(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn depthMask(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn depthRange(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn detachShader(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn disable(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn disableVertexAttribArray(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn drawArrays(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn drawArraysInstanced(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn drawBuffers(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn drawElements(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn drawElementsInstanced(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn drawingBufferStorage(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn drawRangeElements(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn enable(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn enableVertexAttribArray(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn endQuery(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn endTransformFeedback(_: *const WebGL2RenderingContext) void {}
pub fn finish(_: *const WebGL2RenderingContext) void {}
pub fn flush(_: *const WebGL2RenderingContext) void {}
pub fn framebufferRenderbuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn framebufferTexture2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn framebufferTextureLayer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn frontFace(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn generateMipmap(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn getBufferSubData(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn hint(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn invalidateFramebuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn invalidateSubFramebuffer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn lineWidth(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn linkProgram(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn pauseTransformFeedback(_: *const WebGL2RenderingContext) void {}
pub fn pixelStorei(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn polygonOffset(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn readBuffer(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn readPixels(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn renderbufferStorage(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn renderbufferStorageMultisample(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn resumeTransformFeedback(_: *const WebGL2RenderingContext) void {}
pub fn sampleCoverage(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn samplerParameterf(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn samplerParameteri(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn scissor(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn shaderSource(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn stencilFunc(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn stencilFuncSeparate(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn stencilMask(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn stencilMaskSeparate(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn stencilOp(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn stencilOpSeparate(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texImage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texImage3D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texParameterf(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texParameteri(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texStorage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texStorage3D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texSubImage2D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn texSubImage3D(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn transformFeedbackVaryings(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform1f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1i(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1iv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1ui(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform1uiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform2f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform2fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform2i(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform2iv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform2ui(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform2uiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform3f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform3fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform3i(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform3iv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform3ui(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform3uiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform4f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform4fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform4i(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform4iv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniform4ui(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniform4uiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn uniformBlockBinding(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix2fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix2x3fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix2x4fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix3fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix3x2fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix3x4fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix4fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix4x2fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn uniformMatrix4x3fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn useProgram(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn validateProgram(_: *const WebGL2RenderingContext, _: js.Value) void {}
pub fn vertexAttrib1f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib1fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib2f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib2fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib3f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib3fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib4f(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttrib4fv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttribDivisor(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttribI4i(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttribI4iv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttribI4ui(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttribI4uiv(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value) void {}
pub fn vertexAttribIPointer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn vertexAttribPointer(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn viewport(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value, _: js.Value) void {}
pub fn waitSync(_: *const WebGL2RenderingContext, _: js.Value, _: js.Value, _: js.Value) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGL2RenderingContext);

    pub const Meta = struct {
        pub const name = "WebGL2RenderingContext";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(WebGL2RenderingContext.getCanvas, null, .{});
    pub const drawingBufferWidth = bridge.accessor(WebGL2RenderingContext.getDrawingBufferWidth, null, .{});
    pub const drawingBufferHeight = bridge.accessor(WebGL2RenderingContext.getDrawingBufferHeight, null, .{});
    pub const drawingBufferColorSpace = bridge.accessor(WebGL2RenderingContext.getDrawingBufferColorSpace, WebGL2RenderingContext.setDrawingBufferColorSpace, .{});
    pub const unpackColorSpace = bridge.accessor(WebGL2RenderingContext.getUnpackColorSpace, WebGL2RenderingContext.setUnpackColorSpace, .{});
    pub const drawingBufferFormat = bridge.accessor(WebGL2RenderingContext.getDrawingBufferFormat, null, .{});

    pub const checkFramebufferStatus = bridge.function(WebGL2RenderingContext.checkFramebufferStatus, .{});
    pub const clientWaitSync = bridge.function(WebGL2RenderingContext.clientWaitSync, .{});
    pub const createBuffer = bridge.function(WebGL2RenderingContext.createBuffer, .{});
    pub const createFramebuffer = bridge.function(WebGL2RenderingContext.createFramebuffer, .{});
    pub const createProgram = bridge.function(WebGL2RenderingContext.createProgram, .{});
    pub const createQuery = bridge.function(WebGL2RenderingContext.createQuery, .{});
    pub const createRenderbuffer = bridge.function(WebGL2RenderingContext.createRenderbuffer, .{});
    pub const createSampler = bridge.function(WebGL2RenderingContext.createSampler, .{});
    pub const createShader = bridge.function(WebGL2RenderingContext.createShader, .{});
    pub const createTexture = bridge.function(WebGL2RenderingContext.createTexture, .{});
    pub const createTransformFeedback = bridge.function(WebGL2RenderingContext.createTransformFeedback, .{});
    pub const createVertexArray = bridge.function(WebGL2RenderingContext.createVertexArray, .{});
    pub const fenceSync = bridge.function(WebGL2RenderingContext.fenceSync, .{});
    pub const getActiveAttrib = bridge.function(WebGL2RenderingContext.getActiveAttrib, .{});
    pub const getActiveUniform = bridge.function(WebGL2RenderingContext.getActiveUniform, .{});
    pub const getActiveUniformBlockName = bridge.function(WebGL2RenderingContext.getActiveUniformBlockName, .{});
    pub const getActiveUniformBlockParameter = bridge.function(WebGL2RenderingContext.getActiveUniformBlockParameter, .{});
    pub const getActiveUniforms = bridge.function(WebGL2RenderingContext.getActiveUniforms, .{});
    pub const getAttachedShaders = bridge.function(WebGL2RenderingContext.getAttachedShaders, .{});
    pub const getAttribLocation = bridge.function(WebGL2RenderingContext.getAttribLocation, .{});
    pub const getBufferParameter = bridge.function(WebGL2RenderingContext.getBufferParameter, .{});
    pub const getContextAttributes = bridge.function(WebGL2RenderingContext.getContextAttributes, .{});
    pub const makeXRCompatible = bridge.function(WebGL2RenderingContext.makeXRCompatible, .{});
    pub const getError = bridge.function(WebGL2RenderingContext.getError, .{});
    pub const getExtension = bridge.function(WebGL2RenderingContext.getExtension, .{});
    pub const getFragDataLocation = bridge.function(WebGL2RenderingContext.getFragDataLocation, .{});
    pub const getFramebufferAttachmentParameter = bridge.function(WebGL2RenderingContext.getFramebufferAttachmentParameter, .{});
    pub const getIndexedParameter = bridge.function(WebGL2RenderingContext.getIndexedParameter, .{});
    pub const getInternalformatParameter = bridge.function(WebGL2RenderingContext.getInternalformatParameter, .{});
    pub const getParameter = bridge.function(WebGL2RenderingContext.getParameter, .{});
    pub const getProgramInfoLog = bridge.function(WebGL2RenderingContext.getProgramInfoLog, .{});
    pub const getProgramParameter = bridge.function(WebGL2RenderingContext.getProgramParameter, .{});
    pub const getQuery = bridge.function(WebGL2RenderingContext.getQuery, .{});
    pub const getQueryParameter = bridge.function(WebGL2RenderingContext.getQueryParameter, .{});
    pub const getRenderbufferParameter = bridge.function(WebGL2RenderingContext.getRenderbufferParameter, .{});
    pub const getSamplerParameter = bridge.function(WebGL2RenderingContext.getSamplerParameter, .{});
    pub const getShaderInfoLog = bridge.function(WebGL2RenderingContext.getShaderInfoLog, .{});
    pub const getShaderParameter = bridge.function(WebGL2RenderingContext.getShaderParameter, .{});
    pub const getShaderPrecisionFormat = bridge.function(WebGL2RenderingContext.getShaderPrecisionFormat, .{});
    pub const getShaderSource = bridge.function(WebGL2RenderingContext.getShaderSource, .{});
    pub const getSupportedExtensions = bridge.function(WebGL2RenderingContext.getSupportedExtensions, .{});
    pub const getSyncParameter = bridge.function(WebGL2RenderingContext.getSyncParameter, .{});
    pub const getTexParameter = bridge.function(WebGL2RenderingContext.getTexParameter, .{});
    pub const getTransformFeedbackVarying = bridge.function(WebGL2RenderingContext.getTransformFeedbackVarying, .{});
    pub const getUniform = bridge.function(WebGL2RenderingContext.getUniform, .{});
    pub const getUniformBlockIndex = bridge.function(WebGL2RenderingContext.getUniformBlockIndex, .{});
    pub const getUniformIndices = bridge.function(WebGL2RenderingContext.getUniformIndices, .{});
    pub const getUniformLocation = bridge.function(WebGL2RenderingContext.getUniformLocation, .{});
    pub const getVertexAttrib = bridge.function(WebGL2RenderingContext.getVertexAttrib, .{});
    pub const getVertexAttribOffset = bridge.function(WebGL2RenderingContext.getVertexAttribOffset, .{});
    pub const isBuffer = bridge.function(WebGL2RenderingContext.isBuffer, .{});
    pub const isContextLost = bridge.function(WebGL2RenderingContext.isContextLost, .{});
    pub const isEnabled = bridge.function(WebGL2RenderingContext.isEnabled, .{});
    pub const isFramebuffer = bridge.function(WebGL2RenderingContext.isFramebuffer, .{});
    pub const isProgram = bridge.function(WebGL2RenderingContext.isProgram, .{});
    pub const isQuery = bridge.function(WebGL2RenderingContext.isQuery, .{});
    pub const isRenderbuffer = bridge.function(WebGL2RenderingContext.isRenderbuffer, .{});
    pub const isSampler = bridge.function(WebGL2RenderingContext.isSampler, .{});
    pub const isShader = bridge.function(WebGL2RenderingContext.isShader, .{});
    pub const isSync = bridge.function(WebGL2RenderingContext.isSync, .{});
    pub const isTexture = bridge.function(WebGL2RenderingContext.isTexture, .{});
    pub const isTransformFeedback = bridge.function(WebGL2RenderingContext.isTransformFeedback, .{});
    pub const isVertexArray = bridge.function(WebGL2RenderingContext.isVertexArray, .{});

    pub const activeTexture = bridge.function(WebGL2RenderingContext.activeTexture, .{ .noop = true });
    pub const attachShader = bridge.function(WebGL2RenderingContext.attachShader, .{ .noop = true });
    pub const beginQuery = bridge.function(WebGL2RenderingContext.beginQuery, .{ .noop = true });
    pub const beginTransformFeedback = bridge.function(WebGL2RenderingContext.beginTransformFeedback, .{ .noop = true });
    pub const bindAttribLocation = bridge.function(WebGL2RenderingContext.bindAttribLocation, .{ .noop = true });
    pub const bindBuffer = bridge.function(WebGL2RenderingContext.bindBuffer, .{ .noop = true });
    pub const bindBufferBase = bridge.function(WebGL2RenderingContext.bindBufferBase, .{ .noop = true });
    pub const bindBufferRange = bridge.function(WebGL2RenderingContext.bindBufferRange, .{ .noop = true });
    pub const bindFramebuffer = bridge.function(WebGL2RenderingContext.bindFramebuffer, .{ .noop = true });
    pub const bindRenderbuffer = bridge.function(WebGL2RenderingContext.bindRenderbuffer, .{ .noop = true });
    pub const bindSampler = bridge.function(WebGL2RenderingContext.bindSampler, .{ .noop = true });
    pub const bindTexture = bridge.function(WebGL2RenderingContext.bindTexture, .{ .noop = true });
    pub const bindTransformFeedback = bridge.function(WebGL2RenderingContext.bindTransformFeedback, .{ .noop = true });
    pub const bindVertexArray = bridge.function(WebGL2RenderingContext.bindVertexArray, .{ .noop = true });
    pub const blendColor = bridge.function(WebGL2RenderingContext.blendColor, .{ .noop = true });
    pub const blendEquation = bridge.function(WebGL2RenderingContext.blendEquation, .{ .noop = true });
    pub const blendEquationSeparate = bridge.function(WebGL2RenderingContext.blendEquationSeparate, .{ .noop = true });
    pub const blendFunc = bridge.function(WebGL2RenderingContext.blendFunc, .{ .noop = true });
    pub const blendFuncSeparate = bridge.function(WebGL2RenderingContext.blendFuncSeparate, .{ .noop = true });
    pub const blitFramebuffer = bridge.function(WebGL2RenderingContext.blitFramebuffer, .{ .noop = true });
    pub const bufferData = bridge.function(WebGL2RenderingContext.bufferData, .{ .noop = true });
    pub const bufferSubData = bridge.function(WebGL2RenderingContext.bufferSubData, .{ .noop = true });
    pub const clear = bridge.function(WebGL2RenderingContext.clear, .{ .noop = true });
    pub const clearBufferfi = bridge.function(WebGL2RenderingContext.clearBufferfi, .{ .noop = true });
    pub const clearBufferfv = bridge.function(WebGL2RenderingContext.clearBufferfv, .{ .noop = true });
    pub const clearBufferiv = bridge.function(WebGL2RenderingContext.clearBufferiv, .{ .noop = true });
    pub const clearBufferuiv = bridge.function(WebGL2RenderingContext.clearBufferuiv, .{ .noop = true });
    pub const clearColor = bridge.function(WebGL2RenderingContext.clearColor, .{ .noop = true });
    pub const clearDepth = bridge.function(WebGL2RenderingContext.clearDepth, .{ .noop = true });
    pub const clearStencil = bridge.function(WebGL2RenderingContext.clearStencil, .{ .noop = true });
    pub const colorMask = bridge.function(WebGL2RenderingContext.colorMask, .{ .noop = true });
    pub const compileShader = bridge.function(WebGL2RenderingContext.compileShader, .{ .noop = true });
    pub const compressedTexImage2D = bridge.function(WebGL2RenderingContext.compressedTexImage2D, .{ .noop = true });
    pub const compressedTexImage3D = bridge.function(WebGL2RenderingContext.compressedTexImage3D, .{ .noop = true });
    pub const compressedTexSubImage2D = bridge.function(WebGL2RenderingContext.compressedTexSubImage2D, .{ .noop = true });
    pub const compressedTexSubImage3D = bridge.function(WebGL2RenderingContext.compressedTexSubImage3D, .{ .noop = true });
    pub const copyBufferSubData = bridge.function(WebGL2RenderingContext.copyBufferSubData, .{ .noop = true });
    pub const copyTexImage2D = bridge.function(WebGL2RenderingContext.copyTexImage2D, .{ .noop = true });
    pub const copyTexSubImage2D = bridge.function(WebGL2RenderingContext.copyTexSubImage2D, .{ .noop = true });
    pub const copyTexSubImage3D = bridge.function(WebGL2RenderingContext.copyTexSubImage3D, .{ .noop = true });
    pub const cullFace = bridge.function(WebGL2RenderingContext.cullFace, .{ .noop = true });
    pub const deleteBuffer = bridge.function(WebGL2RenderingContext.deleteBuffer, .{ .noop = true });
    pub const deleteFramebuffer = bridge.function(WebGL2RenderingContext.deleteFramebuffer, .{ .noop = true });
    pub const deleteProgram = bridge.function(WebGL2RenderingContext.deleteProgram, .{ .noop = true });
    pub const deleteQuery = bridge.function(WebGL2RenderingContext.deleteQuery, .{ .noop = true });
    pub const deleteRenderbuffer = bridge.function(WebGL2RenderingContext.deleteRenderbuffer, .{ .noop = true });
    pub const deleteSampler = bridge.function(WebGL2RenderingContext.deleteSampler, .{ .noop = true });
    pub const deleteShader = bridge.function(WebGL2RenderingContext.deleteShader, .{ .noop = true });
    pub const deleteSync = bridge.function(WebGL2RenderingContext.deleteSync, .{ .noop = true });
    pub const deleteTexture = bridge.function(WebGL2RenderingContext.deleteTexture, .{ .noop = true });
    pub const deleteTransformFeedback = bridge.function(WebGL2RenderingContext.deleteTransformFeedback, .{ .noop = true });
    pub const deleteVertexArray = bridge.function(WebGL2RenderingContext.deleteVertexArray, .{ .noop = true });
    pub const depthFunc = bridge.function(WebGL2RenderingContext.depthFunc, .{ .noop = true });
    pub const depthMask = bridge.function(WebGL2RenderingContext.depthMask, .{ .noop = true });
    pub const depthRange = bridge.function(WebGL2RenderingContext.depthRange, .{ .noop = true });
    pub const detachShader = bridge.function(WebGL2RenderingContext.detachShader, .{ .noop = true });
    pub const disable = bridge.function(WebGL2RenderingContext.disable, .{ .noop = true });
    pub const disableVertexAttribArray = bridge.function(WebGL2RenderingContext.disableVertexAttribArray, .{ .noop = true });
    pub const drawArrays = bridge.function(WebGL2RenderingContext.drawArrays, .{ .noop = true });
    pub const drawArraysInstanced = bridge.function(WebGL2RenderingContext.drawArraysInstanced, .{ .noop = true });
    pub const drawBuffers = bridge.function(WebGL2RenderingContext.drawBuffers, .{ .noop = true });
    pub const drawElements = bridge.function(WebGL2RenderingContext.drawElements, .{ .noop = true });
    pub const drawElementsInstanced = bridge.function(WebGL2RenderingContext.drawElementsInstanced, .{ .noop = true });
    pub const drawingBufferStorage = bridge.function(WebGL2RenderingContext.drawingBufferStorage, .{ .noop = true });
    pub const drawRangeElements = bridge.function(WebGL2RenderingContext.drawRangeElements, .{ .noop = true });
    pub const enable = bridge.function(WebGL2RenderingContext.enable, .{ .noop = true });
    pub const enableVertexAttribArray = bridge.function(WebGL2RenderingContext.enableVertexAttribArray, .{ .noop = true });
    pub const endQuery = bridge.function(WebGL2RenderingContext.endQuery, .{ .noop = true });
    pub const endTransformFeedback = bridge.function(WebGL2RenderingContext.endTransformFeedback, .{ .noop = true });
    pub const finish = bridge.function(WebGL2RenderingContext.finish, .{ .noop = true });
    pub const flush = bridge.function(WebGL2RenderingContext.flush, .{ .noop = true });
    pub const framebufferRenderbuffer = bridge.function(WebGL2RenderingContext.framebufferRenderbuffer, .{ .noop = true });
    pub const framebufferTexture2D = bridge.function(WebGL2RenderingContext.framebufferTexture2D, .{ .noop = true });
    pub const framebufferTextureLayer = bridge.function(WebGL2RenderingContext.framebufferTextureLayer, .{ .noop = true });
    pub const frontFace = bridge.function(WebGL2RenderingContext.frontFace, .{ .noop = true });
    pub const generateMipmap = bridge.function(WebGL2RenderingContext.generateMipmap, .{ .noop = true });
    pub const getBufferSubData = bridge.function(WebGL2RenderingContext.getBufferSubData, .{ .noop = true });
    pub const hint = bridge.function(WebGL2RenderingContext.hint, .{ .noop = true });
    pub const invalidateFramebuffer = bridge.function(WebGL2RenderingContext.invalidateFramebuffer, .{ .noop = true });
    pub const invalidateSubFramebuffer = bridge.function(WebGL2RenderingContext.invalidateSubFramebuffer, .{ .noop = true });
    pub const lineWidth = bridge.function(WebGL2RenderingContext.lineWidth, .{ .noop = true });
    pub const linkProgram = bridge.function(WebGL2RenderingContext.linkProgram, .{ .noop = true });
    pub const pauseTransformFeedback = bridge.function(WebGL2RenderingContext.pauseTransformFeedback, .{ .noop = true });
    pub const pixelStorei = bridge.function(WebGL2RenderingContext.pixelStorei, .{ .noop = true });
    pub const polygonOffset = bridge.function(WebGL2RenderingContext.polygonOffset, .{ .noop = true });
    pub const readBuffer = bridge.function(WebGL2RenderingContext.readBuffer, .{ .noop = true });
    pub const readPixels = bridge.function(WebGL2RenderingContext.readPixels, .{ .noop = true });
    pub const renderbufferStorage = bridge.function(WebGL2RenderingContext.renderbufferStorage, .{ .noop = true });
    pub const renderbufferStorageMultisample = bridge.function(WebGL2RenderingContext.renderbufferStorageMultisample, .{ .noop = true });
    pub const resumeTransformFeedback = bridge.function(WebGL2RenderingContext.resumeTransformFeedback, .{ .noop = true });
    pub const sampleCoverage = bridge.function(WebGL2RenderingContext.sampleCoverage, .{ .noop = true });
    pub const samplerParameterf = bridge.function(WebGL2RenderingContext.samplerParameterf, .{ .noop = true });
    pub const samplerParameteri = bridge.function(WebGL2RenderingContext.samplerParameteri, .{ .noop = true });
    pub const scissor = bridge.function(WebGL2RenderingContext.scissor, .{ .noop = true });
    pub const shaderSource = bridge.function(WebGL2RenderingContext.shaderSource, .{ .noop = true });
    pub const stencilFunc = bridge.function(WebGL2RenderingContext.stencilFunc, .{ .noop = true });
    pub const stencilFuncSeparate = bridge.function(WebGL2RenderingContext.stencilFuncSeparate, .{ .noop = true });
    pub const stencilMask = bridge.function(WebGL2RenderingContext.stencilMask, .{ .noop = true });
    pub const stencilMaskSeparate = bridge.function(WebGL2RenderingContext.stencilMaskSeparate, .{ .noop = true });
    pub const stencilOp = bridge.function(WebGL2RenderingContext.stencilOp, .{ .noop = true });
    pub const stencilOpSeparate = bridge.function(WebGL2RenderingContext.stencilOpSeparate, .{ .noop = true });
    pub const texImage2D = bridge.function(WebGL2RenderingContext.texImage2D, .{ .noop = true });
    pub const texImage3D = bridge.function(WebGL2RenderingContext.texImage3D, .{ .noop = true });
    pub const texParameterf = bridge.function(WebGL2RenderingContext.texParameterf, .{ .noop = true });
    pub const texParameteri = bridge.function(WebGL2RenderingContext.texParameteri, .{ .noop = true });
    pub const texStorage2D = bridge.function(WebGL2RenderingContext.texStorage2D, .{ .noop = true });
    pub const texStorage3D = bridge.function(WebGL2RenderingContext.texStorage3D, .{ .noop = true });
    pub const texSubImage2D = bridge.function(WebGL2RenderingContext.texSubImage2D, .{ .noop = true });
    pub const texSubImage3D = bridge.function(WebGL2RenderingContext.texSubImage3D, .{ .noop = true });
    pub const transformFeedbackVaryings = bridge.function(WebGL2RenderingContext.transformFeedbackVaryings, .{ .noop = true });
    pub const uniform1f = bridge.function(WebGL2RenderingContext.uniform1f, .{ .noop = true });
    pub const uniform1fv = bridge.function(WebGL2RenderingContext.uniform1fv, .{ .noop = true });
    pub const uniform1i = bridge.function(WebGL2RenderingContext.uniform1i, .{ .noop = true });
    pub const uniform1iv = bridge.function(WebGL2RenderingContext.uniform1iv, .{ .noop = true });
    pub const uniform1ui = bridge.function(WebGL2RenderingContext.uniform1ui, .{ .noop = true });
    pub const uniform1uiv = bridge.function(WebGL2RenderingContext.uniform1uiv, .{ .noop = true });
    pub const uniform2f = bridge.function(WebGL2RenderingContext.uniform2f, .{ .noop = true });
    pub const uniform2fv = bridge.function(WebGL2RenderingContext.uniform2fv, .{ .noop = true });
    pub const uniform2i = bridge.function(WebGL2RenderingContext.uniform2i, .{ .noop = true });
    pub const uniform2iv = bridge.function(WebGL2RenderingContext.uniform2iv, .{ .noop = true });
    pub const uniform2ui = bridge.function(WebGL2RenderingContext.uniform2ui, .{ .noop = true });
    pub const uniform2uiv = bridge.function(WebGL2RenderingContext.uniform2uiv, .{ .noop = true });
    pub const uniform3f = bridge.function(WebGL2RenderingContext.uniform3f, .{ .noop = true });
    pub const uniform3fv = bridge.function(WebGL2RenderingContext.uniform3fv, .{ .noop = true });
    pub const uniform3i = bridge.function(WebGL2RenderingContext.uniform3i, .{ .noop = true });
    pub const uniform3iv = bridge.function(WebGL2RenderingContext.uniform3iv, .{ .noop = true });
    pub const uniform3ui = bridge.function(WebGL2RenderingContext.uniform3ui, .{ .noop = true });
    pub const uniform3uiv = bridge.function(WebGL2RenderingContext.uniform3uiv, .{ .noop = true });
    pub const uniform4f = bridge.function(WebGL2RenderingContext.uniform4f, .{ .noop = true });
    pub const uniform4fv = bridge.function(WebGL2RenderingContext.uniform4fv, .{ .noop = true });
    pub const uniform4i = bridge.function(WebGL2RenderingContext.uniform4i, .{ .noop = true });
    pub const uniform4iv = bridge.function(WebGL2RenderingContext.uniform4iv, .{ .noop = true });
    pub const uniform4ui = bridge.function(WebGL2RenderingContext.uniform4ui, .{ .noop = true });
    pub const uniform4uiv = bridge.function(WebGL2RenderingContext.uniform4uiv, .{ .noop = true });
    pub const uniformBlockBinding = bridge.function(WebGL2RenderingContext.uniformBlockBinding, .{ .noop = true });
    pub const uniformMatrix2fv = bridge.function(WebGL2RenderingContext.uniformMatrix2fv, .{ .noop = true });
    pub const uniformMatrix2x3fv = bridge.function(WebGL2RenderingContext.uniformMatrix2x3fv, .{ .noop = true });
    pub const uniformMatrix2x4fv = bridge.function(WebGL2RenderingContext.uniformMatrix2x4fv, .{ .noop = true });
    pub const uniformMatrix3fv = bridge.function(WebGL2RenderingContext.uniformMatrix3fv, .{ .noop = true });
    pub const uniformMatrix3x2fv = bridge.function(WebGL2RenderingContext.uniformMatrix3x2fv, .{ .noop = true });
    pub const uniformMatrix3x4fv = bridge.function(WebGL2RenderingContext.uniformMatrix3x4fv, .{ .noop = true });
    pub const uniformMatrix4fv = bridge.function(WebGL2RenderingContext.uniformMatrix4fv, .{ .noop = true });
    pub const uniformMatrix4x2fv = bridge.function(WebGL2RenderingContext.uniformMatrix4x2fv, .{ .noop = true });
    pub const uniformMatrix4x3fv = bridge.function(WebGL2RenderingContext.uniformMatrix4x3fv, .{ .noop = true });
    pub const useProgram = bridge.function(WebGL2RenderingContext.useProgram, .{ .noop = true });
    pub const validateProgram = bridge.function(WebGL2RenderingContext.validateProgram, .{ .noop = true });
    pub const vertexAttrib1f = bridge.function(WebGL2RenderingContext.vertexAttrib1f, .{ .noop = true });
    pub const vertexAttrib1fv = bridge.function(WebGL2RenderingContext.vertexAttrib1fv, .{ .noop = true });
    pub const vertexAttrib2f = bridge.function(WebGL2RenderingContext.vertexAttrib2f, .{ .noop = true });
    pub const vertexAttrib2fv = bridge.function(WebGL2RenderingContext.vertexAttrib2fv, .{ .noop = true });
    pub const vertexAttrib3f = bridge.function(WebGL2RenderingContext.vertexAttrib3f, .{ .noop = true });
    pub const vertexAttrib3fv = bridge.function(WebGL2RenderingContext.vertexAttrib3fv, .{ .noop = true });
    pub const vertexAttrib4f = bridge.function(WebGL2RenderingContext.vertexAttrib4f, .{ .noop = true });
    pub const vertexAttrib4fv = bridge.function(WebGL2RenderingContext.vertexAttrib4fv, .{ .noop = true });
    pub const vertexAttribDivisor = bridge.function(WebGL2RenderingContext.vertexAttribDivisor, .{ .noop = true });
    pub const vertexAttribI4i = bridge.function(WebGL2RenderingContext.vertexAttribI4i, .{ .noop = true });
    pub const vertexAttribI4iv = bridge.function(WebGL2RenderingContext.vertexAttribI4iv, .{ .noop = true });
    pub const vertexAttribI4ui = bridge.function(WebGL2RenderingContext.vertexAttribI4ui, .{ .noop = true });
    pub const vertexAttribI4uiv = bridge.function(WebGL2RenderingContext.vertexAttribI4uiv, .{ .noop = true });
    pub const vertexAttribIPointer = bridge.function(WebGL2RenderingContext.vertexAttribIPointer, .{ .noop = true });
    pub const vertexAttribPointer = bridge.function(WebGL2RenderingContext.vertexAttribPointer, .{ .noop = true });
    pub const viewport = bridge.function(WebGL2RenderingContext.viewport, .{ .noop = true });
    pub const waitSync = bridge.function(WebGL2RenderingContext.waitSync, .{ .noop = true });

    // Web IDL constants live on both the interface object and the prototype.
    pub const DEPTH_BUFFER_BIT = bridge.property(WebGL2RenderingContext.DEPTH_BUFFER_BIT, .{ .template = true, .readonly = true });
    pub const STENCIL_BUFFER_BIT = bridge.property(WebGL2RenderingContext.STENCIL_BUFFER_BIT, .{ .template = true, .readonly = true });
    pub const COLOR_BUFFER_BIT = bridge.property(WebGL2RenderingContext.COLOR_BUFFER_BIT, .{ .template = true, .readonly = true });
    pub const POINTS = bridge.property(WebGL2RenderingContext.POINTS, .{ .template = true, .readonly = true });
    pub const LINES = bridge.property(WebGL2RenderingContext.LINES, .{ .template = true, .readonly = true });
    pub const LINE_LOOP = bridge.property(WebGL2RenderingContext.LINE_LOOP, .{ .template = true, .readonly = true });
    pub const LINE_STRIP = bridge.property(WebGL2RenderingContext.LINE_STRIP, .{ .template = true, .readonly = true });
    pub const TRIANGLES = bridge.property(WebGL2RenderingContext.TRIANGLES, .{ .template = true, .readonly = true });
    pub const TRIANGLE_STRIP = bridge.property(WebGL2RenderingContext.TRIANGLE_STRIP, .{ .template = true, .readonly = true });
    pub const TRIANGLE_FAN = bridge.property(WebGL2RenderingContext.TRIANGLE_FAN, .{ .template = true, .readonly = true });
    pub const ZERO = bridge.property(WebGL2RenderingContext.ZERO, .{ .template = true, .readonly = true });
    pub const ONE = bridge.property(WebGL2RenderingContext.ONE, .{ .template = true, .readonly = true });
    pub const SRC_COLOR = bridge.property(WebGL2RenderingContext.SRC_COLOR, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_SRC_COLOR = bridge.property(WebGL2RenderingContext.ONE_MINUS_SRC_COLOR, .{ .template = true, .readonly = true });
    pub const SRC_ALPHA = bridge.property(WebGL2RenderingContext.SRC_ALPHA, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_SRC_ALPHA = bridge.property(WebGL2RenderingContext.ONE_MINUS_SRC_ALPHA, .{ .template = true, .readonly = true });
    pub const DST_ALPHA = bridge.property(WebGL2RenderingContext.DST_ALPHA, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_DST_ALPHA = bridge.property(WebGL2RenderingContext.ONE_MINUS_DST_ALPHA, .{ .template = true, .readonly = true });
    pub const DST_COLOR = bridge.property(WebGL2RenderingContext.DST_COLOR, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_DST_COLOR = bridge.property(WebGL2RenderingContext.ONE_MINUS_DST_COLOR, .{ .template = true, .readonly = true });
    pub const SRC_ALPHA_SATURATE = bridge.property(WebGL2RenderingContext.SRC_ALPHA_SATURATE, .{ .template = true, .readonly = true });
    pub const FUNC_ADD = bridge.property(WebGL2RenderingContext.FUNC_ADD, .{ .template = true, .readonly = true });
    pub const BLEND_EQUATION = bridge.property(WebGL2RenderingContext.BLEND_EQUATION, .{ .template = true, .readonly = true });
    pub const BLEND_EQUATION_RGB = bridge.property(WebGL2RenderingContext.BLEND_EQUATION_RGB, .{ .template = true, .readonly = true });
    pub const BLEND_EQUATION_ALPHA = bridge.property(WebGL2RenderingContext.BLEND_EQUATION_ALPHA, .{ .template = true, .readonly = true });
    pub const FUNC_SUBTRACT = bridge.property(WebGL2RenderingContext.FUNC_SUBTRACT, .{ .template = true, .readonly = true });
    pub const FUNC_REVERSE_SUBTRACT = bridge.property(WebGL2RenderingContext.FUNC_REVERSE_SUBTRACT, .{ .template = true, .readonly = true });
    pub const BLEND_DST_RGB = bridge.property(WebGL2RenderingContext.BLEND_DST_RGB, .{ .template = true, .readonly = true });
    pub const BLEND_SRC_RGB = bridge.property(WebGL2RenderingContext.BLEND_SRC_RGB, .{ .template = true, .readonly = true });
    pub const BLEND_DST_ALPHA = bridge.property(WebGL2RenderingContext.BLEND_DST_ALPHA, .{ .template = true, .readonly = true });
    pub const BLEND_SRC_ALPHA = bridge.property(WebGL2RenderingContext.BLEND_SRC_ALPHA, .{ .template = true, .readonly = true });
    pub const CONSTANT_COLOR = bridge.property(WebGL2RenderingContext.CONSTANT_COLOR, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_CONSTANT_COLOR = bridge.property(WebGL2RenderingContext.ONE_MINUS_CONSTANT_COLOR, .{ .template = true, .readonly = true });
    pub const CONSTANT_ALPHA = bridge.property(WebGL2RenderingContext.CONSTANT_ALPHA, .{ .template = true, .readonly = true });
    pub const ONE_MINUS_CONSTANT_ALPHA = bridge.property(WebGL2RenderingContext.ONE_MINUS_CONSTANT_ALPHA, .{ .template = true, .readonly = true });
    pub const BLEND_COLOR = bridge.property(WebGL2RenderingContext.BLEND_COLOR, .{ .template = true, .readonly = true });
    pub const ARRAY_BUFFER = bridge.property(WebGL2RenderingContext.ARRAY_BUFFER, .{ .template = true, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER = bridge.property(WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER, .{ .template = true, .readonly = true });
    pub const ARRAY_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.ARRAY_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const STREAM_DRAW = bridge.property(WebGL2RenderingContext.STREAM_DRAW, .{ .template = true, .readonly = true });
    pub const STATIC_DRAW = bridge.property(WebGL2RenderingContext.STATIC_DRAW, .{ .template = true, .readonly = true });
    pub const DYNAMIC_DRAW = bridge.property(WebGL2RenderingContext.DYNAMIC_DRAW, .{ .template = true, .readonly = true });
    pub const BUFFER_SIZE = bridge.property(WebGL2RenderingContext.BUFFER_SIZE, .{ .template = true, .readonly = true });
    pub const BUFFER_USAGE = bridge.property(WebGL2RenderingContext.BUFFER_USAGE, .{ .template = true, .readonly = true });
    pub const CURRENT_VERTEX_ATTRIB = bridge.property(WebGL2RenderingContext.CURRENT_VERTEX_ATTRIB, .{ .template = true, .readonly = true });
    pub const FRONT = bridge.property(WebGL2RenderingContext.FRONT, .{ .template = true, .readonly = true });
    pub const BACK = bridge.property(WebGL2RenderingContext.BACK, .{ .template = true, .readonly = true });
    pub const FRONT_AND_BACK = bridge.property(WebGL2RenderingContext.FRONT_AND_BACK, .{ .template = true, .readonly = true });
    pub const TEXTURE_2D = bridge.property(WebGL2RenderingContext.TEXTURE_2D, .{ .template = true, .readonly = true });
    pub const CULL_FACE = bridge.property(WebGL2RenderingContext.CULL_FACE, .{ .template = true, .readonly = true });
    pub const BLEND = bridge.property(WebGL2RenderingContext.BLEND, .{ .template = true, .readonly = true });
    pub const DITHER = bridge.property(WebGL2RenderingContext.DITHER, .{ .template = true, .readonly = true });
    pub const STENCIL_TEST = bridge.property(WebGL2RenderingContext.STENCIL_TEST, .{ .template = true, .readonly = true });
    pub const DEPTH_TEST = bridge.property(WebGL2RenderingContext.DEPTH_TEST, .{ .template = true, .readonly = true });
    pub const SCISSOR_TEST = bridge.property(WebGL2RenderingContext.SCISSOR_TEST, .{ .template = true, .readonly = true });
    pub const POLYGON_OFFSET_FILL = bridge.property(WebGL2RenderingContext.POLYGON_OFFSET_FILL, .{ .template = true, .readonly = true });
    pub const SAMPLE_ALPHA_TO_COVERAGE = bridge.property(WebGL2RenderingContext.SAMPLE_ALPHA_TO_COVERAGE, .{ .template = true, .readonly = true });
    pub const SAMPLE_COVERAGE = bridge.property(WebGL2RenderingContext.SAMPLE_COVERAGE, .{ .template = true, .readonly = true });
    pub const NO_ERROR = bridge.property(WebGL2RenderingContext.NO_ERROR, .{ .template = true, .readonly = true });
    pub const INVALID_ENUM = bridge.property(WebGL2RenderingContext.INVALID_ENUM, .{ .template = true, .readonly = true });
    pub const INVALID_VALUE = bridge.property(WebGL2RenderingContext.INVALID_VALUE, .{ .template = true, .readonly = true });
    pub const INVALID_OPERATION = bridge.property(WebGL2RenderingContext.INVALID_OPERATION, .{ .template = true, .readonly = true });
    pub const OUT_OF_MEMORY = bridge.property(WebGL2RenderingContext.OUT_OF_MEMORY, .{ .template = true, .readonly = true });
    pub const CW = bridge.property(WebGL2RenderingContext.CW, .{ .template = true, .readonly = true });
    pub const CCW = bridge.property(WebGL2RenderingContext.CCW, .{ .template = true, .readonly = true });
    pub const LINE_WIDTH = bridge.property(WebGL2RenderingContext.LINE_WIDTH, .{ .template = true, .readonly = true });
    pub const ALIASED_POINT_SIZE_RANGE = bridge.property(WebGL2RenderingContext.ALIASED_POINT_SIZE_RANGE, .{ .template = true, .readonly = true });
    pub const ALIASED_LINE_WIDTH_RANGE = bridge.property(WebGL2RenderingContext.ALIASED_LINE_WIDTH_RANGE, .{ .template = true, .readonly = true });
    pub const CULL_FACE_MODE = bridge.property(WebGL2RenderingContext.CULL_FACE_MODE, .{ .template = true, .readonly = true });
    pub const FRONT_FACE = bridge.property(WebGL2RenderingContext.FRONT_FACE, .{ .template = true, .readonly = true });
    pub const DEPTH_RANGE = bridge.property(WebGL2RenderingContext.DEPTH_RANGE, .{ .template = true, .readonly = true });
    pub const DEPTH_WRITEMASK = bridge.property(WebGL2RenderingContext.DEPTH_WRITEMASK, .{ .template = true, .readonly = true });
    pub const DEPTH_CLEAR_VALUE = bridge.property(WebGL2RenderingContext.DEPTH_CLEAR_VALUE, .{ .template = true, .readonly = true });
    pub const DEPTH_FUNC = bridge.property(WebGL2RenderingContext.DEPTH_FUNC, .{ .template = true, .readonly = true });
    pub const STENCIL_CLEAR_VALUE = bridge.property(WebGL2RenderingContext.STENCIL_CLEAR_VALUE, .{ .template = true, .readonly = true });
    pub const STENCIL_FUNC = bridge.property(WebGL2RenderingContext.STENCIL_FUNC, .{ .template = true, .readonly = true });
    pub const STENCIL_FAIL = bridge.property(WebGL2RenderingContext.STENCIL_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_PASS_DEPTH_FAIL = bridge.property(WebGL2RenderingContext.STENCIL_PASS_DEPTH_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_PASS_DEPTH_PASS = bridge.property(WebGL2RenderingContext.STENCIL_PASS_DEPTH_PASS, .{ .template = true, .readonly = true });
    pub const STENCIL_REF = bridge.property(WebGL2RenderingContext.STENCIL_REF, .{ .template = true, .readonly = true });
    pub const STENCIL_VALUE_MASK = bridge.property(WebGL2RenderingContext.STENCIL_VALUE_MASK, .{ .template = true, .readonly = true });
    pub const STENCIL_WRITEMASK = bridge.property(WebGL2RenderingContext.STENCIL_WRITEMASK, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_FUNC = bridge.property(WebGL2RenderingContext.STENCIL_BACK_FUNC, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_FAIL = bridge.property(WebGL2RenderingContext.STENCIL_BACK_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_PASS_DEPTH_FAIL = bridge.property(WebGL2RenderingContext.STENCIL_BACK_PASS_DEPTH_FAIL, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_PASS_DEPTH_PASS = bridge.property(WebGL2RenderingContext.STENCIL_BACK_PASS_DEPTH_PASS, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_REF = bridge.property(WebGL2RenderingContext.STENCIL_BACK_REF, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_VALUE_MASK = bridge.property(WebGL2RenderingContext.STENCIL_BACK_VALUE_MASK, .{ .template = true, .readonly = true });
    pub const STENCIL_BACK_WRITEMASK = bridge.property(WebGL2RenderingContext.STENCIL_BACK_WRITEMASK, .{ .template = true, .readonly = true });
    pub const VIEWPORT = bridge.property(WebGL2RenderingContext.VIEWPORT, .{ .template = true, .readonly = true });
    pub const SCISSOR_BOX = bridge.property(WebGL2RenderingContext.SCISSOR_BOX, .{ .template = true, .readonly = true });
    pub const COLOR_CLEAR_VALUE = bridge.property(WebGL2RenderingContext.COLOR_CLEAR_VALUE, .{ .template = true, .readonly = true });
    pub const COLOR_WRITEMASK = bridge.property(WebGL2RenderingContext.COLOR_WRITEMASK, .{ .template = true, .readonly = true });
    pub const UNPACK_ALIGNMENT = bridge.property(WebGL2RenderingContext.UNPACK_ALIGNMENT, .{ .template = true, .readonly = true });
    pub const PACK_ALIGNMENT = bridge.property(WebGL2RenderingContext.PACK_ALIGNMENT, .{ .template = true, .readonly = true });
    pub const MAX_TEXTURE_SIZE = bridge.property(WebGL2RenderingContext.MAX_TEXTURE_SIZE, .{ .template = true, .readonly = true });
    pub const MAX_VIEWPORT_DIMS = bridge.property(WebGL2RenderingContext.MAX_VIEWPORT_DIMS, .{ .template = true, .readonly = true });
    pub const SUBPIXEL_BITS = bridge.property(WebGL2RenderingContext.SUBPIXEL_BITS, .{ .template = true, .readonly = true });
    pub const RED_BITS = bridge.property(WebGL2RenderingContext.RED_BITS, .{ .template = true, .readonly = true });
    pub const GREEN_BITS = bridge.property(WebGL2RenderingContext.GREEN_BITS, .{ .template = true, .readonly = true });
    pub const BLUE_BITS = bridge.property(WebGL2RenderingContext.BLUE_BITS, .{ .template = true, .readonly = true });
    pub const ALPHA_BITS = bridge.property(WebGL2RenderingContext.ALPHA_BITS, .{ .template = true, .readonly = true });
    pub const DEPTH_BITS = bridge.property(WebGL2RenderingContext.DEPTH_BITS, .{ .template = true, .readonly = true });
    pub const STENCIL_BITS = bridge.property(WebGL2RenderingContext.STENCIL_BITS, .{ .template = true, .readonly = true });
    pub const POLYGON_OFFSET_UNITS = bridge.property(WebGL2RenderingContext.POLYGON_OFFSET_UNITS, .{ .template = true, .readonly = true });
    pub const POLYGON_OFFSET_FACTOR = bridge.property(WebGL2RenderingContext.POLYGON_OFFSET_FACTOR, .{ .template = true, .readonly = true });
    pub const TEXTURE_BINDING_2D = bridge.property(WebGL2RenderingContext.TEXTURE_BINDING_2D, .{ .template = true, .readonly = true });
    pub const SAMPLE_BUFFERS = bridge.property(WebGL2RenderingContext.SAMPLE_BUFFERS, .{ .template = true, .readonly = true });
    pub const SAMPLES = bridge.property(WebGL2RenderingContext.SAMPLES, .{ .template = true, .readonly = true });
    pub const SAMPLE_COVERAGE_VALUE = bridge.property(WebGL2RenderingContext.SAMPLE_COVERAGE_VALUE, .{ .template = true, .readonly = true });
    pub const SAMPLE_COVERAGE_INVERT = bridge.property(WebGL2RenderingContext.SAMPLE_COVERAGE_INVERT, .{ .template = true, .readonly = true });
    pub const COMPRESSED_TEXTURE_FORMATS = bridge.property(WebGL2RenderingContext.COMPRESSED_TEXTURE_FORMATS, .{ .template = true, .readonly = true });
    pub const DONT_CARE = bridge.property(WebGL2RenderingContext.DONT_CARE, .{ .template = true, .readonly = true });
    pub const FASTEST = bridge.property(WebGL2RenderingContext.FASTEST, .{ .template = true, .readonly = true });
    pub const NICEST = bridge.property(WebGL2RenderingContext.NICEST, .{ .template = true, .readonly = true });
    pub const GENERATE_MIPMAP_HINT = bridge.property(WebGL2RenderingContext.GENERATE_MIPMAP_HINT, .{ .template = true, .readonly = true });
    pub const BYTE = bridge.property(WebGL2RenderingContext.BYTE, .{ .template = true, .readonly = true });
    pub const UNSIGNED_BYTE = bridge.property(WebGL2RenderingContext.UNSIGNED_BYTE, .{ .template = true, .readonly = true });
    pub const SHORT = bridge.property(WebGL2RenderingContext.SHORT, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT = bridge.property(WebGL2RenderingContext.UNSIGNED_SHORT, .{ .template = true, .readonly = true });
    pub const INT = bridge.property(WebGL2RenderingContext.INT, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT = bridge.property(WebGL2RenderingContext.UNSIGNED_INT, .{ .template = true, .readonly = true });
    pub const FLOAT = bridge.property(WebGL2RenderingContext.FLOAT, .{ .template = true, .readonly = true });
    pub const DEPTH_COMPONENT = bridge.property(WebGL2RenderingContext.DEPTH_COMPONENT, .{ .template = true, .readonly = true });
    pub const ALPHA = bridge.property(WebGL2RenderingContext.ALPHA, .{ .template = true, .readonly = true });
    pub const RGB = bridge.property(WebGL2RenderingContext.RGB, .{ .template = true, .readonly = true });
    pub const RGBA = bridge.property(WebGL2RenderingContext.RGBA, .{ .template = true, .readonly = true });
    pub const LUMINANCE = bridge.property(WebGL2RenderingContext.LUMINANCE, .{ .template = true, .readonly = true });
    pub const LUMINANCE_ALPHA = bridge.property(WebGL2RenderingContext.LUMINANCE_ALPHA, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT_4_4_4_4 = bridge.property(WebGL2RenderingContext.UNSIGNED_SHORT_4_4_4_4, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT_5_5_5_1 = bridge.property(WebGL2RenderingContext.UNSIGNED_SHORT_5_5_5_1, .{ .template = true, .readonly = true });
    pub const UNSIGNED_SHORT_5_6_5 = bridge.property(WebGL2RenderingContext.UNSIGNED_SHORT_5_6_5, .{ .template = true, .readonly = true });
    pub const FRAGMENT_SHADER = bridge.property(WebGL2RenderingContext.FRAGMENT_SHADER, .{ .template = true, .readonly = true });
    pub const VERTEX_SHADER = bridge.property(WebGL2RenderingContext.VERTEX_SHADER, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_ATTRIBS = bridge.property(WebGL2RenderingContext.MAX_VERTEX_ATTRIBS, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_UNIFORM_VECTORS = bridge.property(WebGL2RenderingContext.MAX_VERTEX_UNIFORM_VECTORS, .{ .template = true, .readonly = true });
    pub const MAX_VARYING_VECTORS = bridge.property(WebGL2RenderingContext.MAX_VARYING_VECTORS, .{ .template = true, .readonly = true });
    pub const MAX_COMBINED_TEXTURE_IMAGE_UNITS = bridge.property(WebGL2RenderingContext.MAX_COMBINED_TEXTURE_IMAGE_UNITS, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_TEXTURE_IMAGE_UNITS = bridge.property(WebGL2RenderingContext.MAX_VERTEX_TEXTURE_IMAGE_UNITS, .{ .template = true, .readonly = true });
    pub const MAX_TEXTURE_IMAGE_UNITS = bridge.property(WebGL2RenderingContext.MAX_TEXTURE_IMAGE_UNITS, .{ .template = true, .readonly = true });
    pub const MAX_FRAGMENT_UNIFORM_VECTORS = bridge.property(WebGL2RenderingContext.MAX_FRAGMENT_UNIFORM_VECTORS, .{ .template = true, .readonly = true });
    pub const SHADER_TYPE = bridge.property(WebGL2RenderingContext.SHADER_TYPE, .{ .template = true, .readonly = true });
    pub const DELETE_STATUS = bridge.property(WebGL2RenderingContext.DELETE_STATUS, .{ .template = true, .readonly = true });
    pub const LINK_STATUS = bridge.property(WebGL2RenderingContext.LINK_STATUS, .{ .template = true, .readonly = true });
    pub const VALIDATE_STATUS = bridge.property(WebGL2RenderingContext.VALIDATE_STATUS, .{ .template = true, .readonly = true });
    pub const ATTACHED_SHADERS = bridge.property(WebGL2RenderingContext.ATTACHED_SHADERS, .{ .template = true, .readonly = true });
    pub const ACTIVE_UNIFORMS = bridge.property(WebGL2RenderingContext.ACTIVE_UNIFORMS, .{ .template = true, .readonly = true });
    pub const ACTIVE_ATTRIBUTES = bridge.property(WebGL2RenderingContext.ACTIVE_ATTRIBUTES, .{ .template = true, .readonly = true });
    pub const SHADING_LANGUAGE_VERSION = bridge.property(WebGL2RenderingContext.SHADING_LANGUAGE_VERSION, .{ .template = true, .readonly = true });
    pub const CURRENT_PROGRAM = bridge.property(WebGL2RenderingContext.CURRENT_PROGRAM, .{ .template = true, .readonly = true });
    pub const NEVER = bridge.property(WebGL2RenderingContext.NEVER, .{ .template = true, .readonly = true });
    pub const LESS = bridge.property(WebGL2RenderingContext.LESS, .{ .template = true, .readonly = true });
    pub const EQUAL = bridge.property(WebGL2RenderingContext.EQUAL, .{ .template = true, .readonly = true });
    pub const LEQUAL = bridge.property(WebGL2RenderingContext.LEQUAL, .{ .template = true, .readonly = true });
    pub const GREATER = bridge.property(WebGL2RenderingContext.GREATER, .{ .template = true, .readonly = true });
    pub const NOTEQUAL = bridge.property(WebGL2RenderingContext.NOTEQUAL, .{ .template = true, .readonly = true });
    pub const GEQUAL = bridge.property(WebGL2RenderingContext.GEQUAL, .{ .template = true, .readonly = true });
    pub const ALWAYS = bridge.property(WebGL2RenderingContext.ALWAYS, .{ .template = true, .readonly = true });
    pub const KEEP = bridge.property(WebGL2RenderingContext.KEEP, .{ .template = true, .readonly = true });
    pub const REPLACE = bridge.property(WebGL2RenderingContext.REPLACE, .{ .template = true, .readonly = true });
    pub const INCR = bridge.property(WebGL2RenderingContext.INCR, .{ .template = true, .readonly = true });
    pub const DECR = bridge.property(WebGL2RenderingContext.DECR, .{ .template = true, .readonly = true });
    pub const INVERT = bridge.property(WebGL2RenderingContext.INVERT, .{ .template = true, .readonly = true });
    pub const INCR_WRAP = bridge.property(WebGL2RenderingContext.INCR_WRAP, .{ .template = true, .readonly = true });
    pub const DECR_WRAP = bridge.property(WebGL2RenderingContext.DECR_WRAP, .{ .template = true, .readonly = true });
    pub const VENDOR = bridge.property(WebGL2RenderingContext.VENDOR, .{ .template = true, .readonly = true });
    pub const RENDERER = bridge.property(WebGL2RenderingContext.RENDERER, .{ .template = true, .readonly = true });
    pub const VERSION = bridge.property(WebGL2RenderingContext.VERSION, .{ .template = true, .readonly = true });
    pub const NEAREST = bridge.property(WebGL2RenderingContext.NEAREST, .{ .template = true, .readonly = true });
    pub const LINEAR = bridge.property(WebGL2RenderingContext.LINEAR, .{ .template = true, .readonly = true });
    pub const NEAREST_MIPMAP_NEAREST = bridge.property(WebGL2RenderingContext.NEAREST_MIPMAP_NEAREST, .{ .template = true, .readonly = true });
    pub const LINEAR_MIPMAP_NEAREST = bridge.property(WebGL2RenderingContext.LINEAR_MIPMAP_NEAREST, .{ .template = true, .readonly = true });
    pub const NEAREST_MIPMAP_LINEAR = bridge.property(WebGL2RenderingContext.NEAREST_MIPMAP_LINEAR, .{ .template = true, .readonly = true });
    pub const LINEAR_MIPMAP_LINEAR = bridge.property(WebGL2RenderingContext.LINEAR_MIPMAP_LINEAR, .{ .template = true, .readonly = true });
    pub const TEXTURE_MAG_FILTER = bridge.property(WebGL2RenderingContext.TEXTURE_MAG_FILTER, .{ .template = true, .readonly = true });
    pub const TEXTURE_MIN_FILTER = bridge.property(WebGL2RenderingContext.TEXTURE_MIN_FILTER, .{ .template = true, .readonly = true });
    pub const TEXTURE_WRAP_S = bridge.property(WebGL2RenderingContext.TEXTURE_WRAP_S, .{ .template = true, .readonly = true });
    pub const TEXTURE_WRAP_T = bridge.property(WebGL2RenderingContext.TEXTURE_WRAP_T, .{ .template = true, .readonly = true });
    pub const TEXTURE = bridge.property(WebGL2RenderingContext.TEXTURE, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP, .{ .template = true, .readonly = true });
    pub const TEXTURE_BINDING_CUBE_MAP = bridge.property(WebGL2RenderingContext.TEXTURE_BINDING_CUBE_MAP, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_X = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP_POSITIVE_X, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_X = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP_NEGATIVE_X, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_Y = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP_POSITIVE_Y, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_Y = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP_NEGATIVE_Y, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_POSITIVE_Z = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP_POSITIVE_Z, .{ .template = true, .readonly = true });
    pub const TEXTURE_CUBE_MAP_NEGATIVE_Z = bridge.property(WebGL2RenderingContext.TEXTURE_CUBE_MAP_NEGATIVE_Z, .{ .template = true, .readonly = true });
    pub const MAX_CUBE_MAP_TEXTURE_SIZE = bridge.property(WebGL2RenderingContext.MAX_CUBE_MAP_TEXTURE_SIZE, .{ .template = true, .readonly = true });
    pub const TEXTURE0 = bridge.property(WebGL2RenderingContext.TEXTURE0, .{ .template = true, .readonly = true });
    pub const TEXTURE1 = bridge.property(WebGL2RenderingContext.TEXTURE1, .{ .template = true, .readonly = true });
    pub const TEXTURE2 = bridge.property(WebGL2RenderingContext.TEXTURE2, .{ .template = true, .readonly = true });
    pub const TEXTURE3 = bridge.property(WebGL2RenderingContext.TEXTURE3, .{ .template = true, .readonly = true });
    pub const TEXTURE4 = bridge.property(WebGL2RenderingContext.TEXTURE4, .{ .template = true, .readonly = true });
    pub const TEXTURE5 = bridge.property(WebGL2RenderingContext.TEXTURE5, .{ .template = true, .readonly = true });
    pub const TEXTURE6 = bridge.property(WebGL2RenderingContext.TEXTURE6, .{ .template = true, .readonly = true });
    pub const TEXTURE7 = bridge.property(WebGL2RenderingContext.TEXTURE7, .{ .template = true, .readonly = true });
    pub const TEXTURE8 = bridge.property(WebGL2RenderingContext.TEXTURE8, .{ .template = true, .readonly = true });
    pub const TEXTURE9 = bridge.property(WebGL2RenderingContext.TEXTURE9, .{ .template = true, .readonly = true });
    pub const TEXTURE10 = bridge.property(WebGL2RenderingContext.TEXTURE10, .{ .template = true, .readonly = true });
    pub const TEXTURE11 = bridge.property(WebGL2RenderingContext.TEXTURE11, .{ .template = true, .readonly = true });
    pub const TEXTURE12 = bridge.property(WebGL2RenderingContext.TEXTURE12, .{ .template = true, .readonly = true });
    pub const TEXTURE13 = bridge.property(WebGL2RenderingContext.TEXTURE13, .{ .template = true, .readonly = true });
    pub const TEXTURE14 = bridge.property(WebGL2RenderingContext.TEXTURE14, .{ .template = true, .readonly = true });
    pub const TEXTURE15 = bridge.property(WebGL2RenderingContext.TEXTURE15, .{ .template = true, .readonly = true });
    pub const TEXTURE16 = bridge.property(WebGL2RenderingContext.TEXTURE16, .{ .template = true, .readonly = true });
    pub const TEXTURE17 = bridge.property(WebGL2RenderingContext.TEXTURE17, .{ .template = true, .readonly = true });
    pub const TEXTURE18 = bridge.property(WebGL2RenderingContext.TEXTURE18, .{ .template = true, .readonly = true });
    pub const TEXTURE19 = bridge.property(WebGL2RenderingContext.TEXTURE19, .{ .template = true, .readonly = true });
    pub const TEXTURE20 = bridge.property(WebGL2RenderingContext.TEXTURE20, .{ .template = true, .readonly = true });
    pub const TEXTURE21 = bridge.property(WebGL2RenderingContext.TEXTURE21, .{ .template = true, .readonly = true });
    pub const TEXTURE22 = bridge.property(WebGL2RenderingContext.TEXTURE22, .{ .template = true, .readonly = true });
    pub const TEXTURE23 = bridge.property(WebGL2RenderingContext.TEXTURE23, .{ .template = true, .readonly = true });
    pub const TEXTURE24 = bridge.property(WebGL2RenderingContext.TEXTURE24, .{ .template = true, .readonly = true });
    pub const TEXTURE25 = bridge.property(WebGL2RenderingContext.TEXTURE25, .{ .template = true, .readonly = true });
    pub const TEXTURE26 = bridge.property(WebGL2RenderingContext.TEXTURE26, .{ .template = true, .readonly = true });
    pub const TEXTURE27 = bridge.property(WebGL2RenderingContext.TEXTURE27, .{ .template = true, .readonly = true });
    pub const TEXTURE28 = bridge.property(WebGL2RenderingContext.TEXTURE28, .{ .template = true, .readonly = true });
    pub const TEXTURE29 = bridge.property(WebGL2RenderingContext.TEXTURE29, .{ .template = true, .readonly = true });
    pub const TEXTURE30 = bridge.property(WebGL2RenderingContext.TEXTURE30, .{ .template = true, .readonly = true });
    pub const TEXTURE31 = bridge.property(WebGL2RenderingContext.TEXTURE31, .{ .template = true, .readonly = true });
    pub const ACTIVE_TEXTURE = bridge.property(WebGL2RenderingContext.ACTIVE_TEXTURE, .{ .template = true, .readonly = true });
    pub const REPEAT = bridge.property(WebGL2RenderingContext.REPEAT, .{ .template = true, .readonly = true });
    pub const CLAMP_TO_EDGE = bridge.property(WebGL2RenderingContext.CLAMP_TO_EDGE, .{ .template = true, .readonly = true });
    pub const MIRRORED_REPEAT = bridge.property(WebGL2RenderingContext.MIRRORED_REPEAT, .{ .template = true, .readonly = true });
    pub const FLOAT_VEC2 = bridge.property(WebGL2RenderingContext.FLOAT_VEC2, .{ .template = true, .readonly = true });
    pub const FLOAT_VEC3 = bridge.property(WebGL2RenderingContext.FLOAT_VEC3, .{ .template = true, .readonly = true });
    pub const FLOAT_VEC4 = bridge.property(WebGL2RenderingContext.FLOAT_VEC4, .{ .template = true, .readonly = true });
    pub const INT_VEC2 = bridge.property(WebGL2RenderingContext.INT_VEC2, .{ .template = true, .readonly = true });
    pub const INT_VEC3 = bridge.property(WebGL2RenderingContext.INT_VEC3, .{ .template = true, .readonly = true });
    pub const INT_VEC4 = bridge.property(WebGL2RenderingContext.INT_VEC4, .{ .template = true, .readonly = true });
    pub const BOOL = bridge.property(WebGL2RenderingContext.BOOL, .{ .template = true, .readonly = true });
    pub const BOOL_VEC2 = bridge.property(WebGL2RenderingContext.BOOL_VEC2, .{ .template = true, .readonly = true });
    pub const BOOL_VEC3 = bridge.property(WebGL2RenderingContext.BOOL_VEC3, .{ .template = true, .readonly = true });
    pub const BOOL_VEC4 = bridge.property(WebGL2RenderingContext.BOOL_VEC4, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT2 = bridge.property(WebGL2RenderingContext.FLOAT_MAT2, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT3 = bridge.property(WebGL2RenderingContext.FLOAT_MAT3, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT4 = bridge.property(WebGL2RenderingContext.FLOAT_MAT4, .{ .template = true, .readonly = true });
    pub const SAMPLER_2D = bridge.property(WebGL2RenderingContext.SAMPLER_2D, .{ .template = true, .readonly = true });
    pub const SAMPLER_CUBE = bridge.property(WebGL2RenderingContext.SAMPLER_CUBE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_ENABLED = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_ENABLED, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_SIZE = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_SIZE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_STRIDE = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_STRIDE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_TYPE = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_TYPE, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_NORMALIZED = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_NORMALIZED, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_POINTER = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_POINTER, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const IMPLEMENTATION_COLOR_READ_TYPE = bridge.property(WebGL2RenderingContext.IMPLEMENTATION_COLOR_READ_TYPE, .{ .template = true, .readonly = true });
    pub const IMPLEMENTATION_COLOR_READ_FORMAT = bridge.property(WebGL2RenderingContext.IMPLEMENTATION_COLOR_READ_FORMAT, .{ .template = true, .readonly = true });
    pub const COMPILE_STATUS = bridge.property(WebGL2RenderingContext.COMPILE_STATUS, .{ .template = true, .readonly = true });
    pub const LOW_FLOAT = bridge.property(WebGL2RenderingContext.LOW_FLOAT, .{ .template = true, .readonly = true });
    pub const MEDIUM_FLOAT = bridge.property(WebGL2RenderingContext.MEDIUM_FLOAT, .{ .template = true, .readonly = true });
    pub const HIGH_FLOAT = bridge.property(WebGL2RenderingContext.HIGH_FLOAT, .{ .template = true, .readonly = true });
    pub const LOW_INT = bridge.property(WebGL2RenderingContext.LOW_INT, .{ .template = true, .readonly = true });
    pub const MEDIUM_INT = bridge.property(WebGL2RenderingContext.MEDIUM_INT, .{ .template = true, .readonly = true });
    pub const HIGH_INT = bridge.property(WebGL2RenderingContext.HIGH_INT, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER = bridge.property(WebGL2RenderingContext.FRAMEBUFFER, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER = bridge.property(WebGL2RenderingContext.RENDERBUFFER, .{ .template = true, .readonly = true });
    pub const RGBA4 = bridge.property(WebGL2RenderingContext.RGBA4, .{ .template = true, .readonly = true });
    pub const RGB5_A1 = bridge.property(WebGL2RenderingContext.RGB5_A1, .{ .template = true, .readonly = true });
    pub const RGB565 = bridge.property(WebGL2RenderingContext.RGB565, .{ .template = true, .readonly = true });
    pub const DEPTH_COMPONENT16 = bridge.property(WebGL2RenderingContext.DEPTH_COMPONENT16, .{ .template = true, .readonly = true });
    pub const STENCIL_INDEX8 = bridge.property(WebGL2RenderingContext.STENCIL_INDEX8, .{ .template = true, .readonly = true });
    pub const DEPTH_STENCIL = bridge.property(WebGL2RenderingContext.DEPTH_STENCIL, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_WIDTH = bridge.property(WebGL2RenderingContext.RENDERBUFFER_WIDTH, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_HEIGHT = bridge.property(WebGL2RenderingContext.RENDERBUFFER_HEIGHT, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_INTERNAL_FORMAT = bridge.property(WebGL2RenderingContext.RENDERBUFFER_INTERNAL_FORMAT, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_RED_SIZE = bridge.property(WebGL2RenderingContext.RENDERBUFFER_RED_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_GREEN_SIZE = bridge.property(WebGL2RenderingContext.RENDERBUFFER_GREEN_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_BLUE_SIZE = bridge.property(WebGL2RenderingContext.RENDERBUFFER_BLUE_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_ALPHA_SIZE = bridge.property(WebGL2RenderingContext.RENDERBUFFER_ALPHA_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_DEPTH_SIZE = bridge.property(WebGL2RenderingContext.RENDERBUFFER_DEPTH_SIZE, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_STENCIL_SIZE = bridge.property(WebGL2RenderingContext.RENDERBUFFER_STENCIL_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_OBJECT_NAME = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT0 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT0, .{ .template = true, .readonly = true });
    pub const DEPTH_ATTACHMENT = bridge.property(WebGL2RenderingContext.DEPTH_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const STENCIL_ATTACHMENT = bridge.property(WebGL2RenderingContext.STENCIL_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const DEPTH_STENCIL_ATTACHMENT = bridge.property(WebGL2RenderingContext.DEPTH_STENCIL_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const NONE = bridge.property(WebGL2RenderingContext.NONE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_COMPLETE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_COMPLETE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_ATTACHMENT = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_DIMENSIONS = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_INCOMPLETE_DIMENSIONS, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_UNSUPPORTED = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_UNSUPPORTED, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_BINDING = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_BINDING = bridge.property(WebGL2RenderingContext.RENDERBUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const MAX_RENDERBUFFER_SIZE = bridge.property(WebGL2RenderingContext.MAX_RENDERBUFFER_SIZE, .{ .template = true, .readonly = true });
    pub const INVALID_FRAMEBUFFER_OPERATION = bridge.property(WebGL2RenderingContext.INVALID_FRAMEBUFFER_OPERATION, .{ .template = true, .readonly = true });
    pub const UNPACK_FLIP_Y_WEBGL = bridge.property(WebGL2RenderingContext.UNPACK_FLIP_Y_WEBGL, .{ .template = true, .readonly = true });
    pub const UNPACK_PREMULTIPLY_ALPHA_WEBGL = bridge.property(WebGL2RenderingContext.UNPACK_PREMULTIPLY_ALPHA_WEBGL, .{ .template = true, .readonly = true });
    pub const CONTEXT_LOST_WEBGL = bridge.property(WebGL2RenderingContext.CONTEXT_LOST_WEBGL, .{ .template = true, .readonly = true });
    pub const UNPACK_COLORSPACE_CONVERSION_WEBGL = bridge.property(WebGL2RenderingContext.UNPACK_COLORSPACE_CONVERSION_WEBGL, .{ .template = true, .readonly = true });
    pub const BROWSER_DEFAULT_WEBGL = bridge.property(WebGL2RenderingContext.BROWSER_DEFAULT_WEBGL, .{ .template = true, .readonly = true });
    pub const READ_BUFFER = bridge.property(WebGL2RenderingContext.READ_BUFFER, .{ .template = true, .readonly = true });
    pub const UNPACK_ROW_LENGTH = bridge.property(WebGL2RenderingContext.UNPACK_ROW_LENGTH, .{ .template = true, .readonly = true });
    pub const UNPACK_SKIP_ROWS = bridge.property(WebGL2RenderingContext.UNPACK_SKIP_ROWS, .{ .template = true, .readonly = true });
    pub const UNPACK_SKIP_PIXELS = bridge.property(WebGL2RenderingContext.UNPACK_SKIP_PIXELS, .{ .template = true, .readonly = true });
    pub const PACK_ROW_LENGTH = bridge.property(WebGL2RenderingContext.PACK_ROW_LENGTH, .{ .template = true, .readonly = true });
    pub const PACK_SKIP_ROWS = bridge.property(WebGL2RenderingContext.PACK_SKIP_ROWS, .{ .template = true, .readonly = true });
    pub const PACK_SKIP_PIXELS = bridge.property(WebGL2RenderingContext.PACK_SKIP_PIXELS, .{ .template = true, .readonly = true });
    pub const COLOR = bridge.property(WebGL2RenderingContext.COLOR, .{ .template = true, .readonly = true });
    pub const DEPTH = bridge.property(WebGL2RenderingContext.DEPTH, .{ .template = true, .readonly = true });
    pub const STENCIL = bridge.property(WebGL2RenderingContext.STENCIL, .{ .template = true, .readonly = true });
    pub const RED = bridge.property(WebGL2RenderingContext.RED, .{ .template = true, .readonly = true });
    pub const RGB8 = bridge.property(WebGL2RenderingContext.RGB8, .{ .template = true, .readonly = true });
    pub const RGBA8 = bridge.property(WebGL2RenderingContext.RGBA8, .{ .template = true, .readonly = true });
    pub const RGB10_A2 = bridge.property(WebGL2RenderingContext.RGB10_A2, .{ .template = true, .readonly = true });
    pub const TEXTURE_BINDING_3D = bridge.property(WebGL2RenderingContext.TEXTURE_BINDING_3D, .{ .template = true, .readonly = true });
    pub const UNPACK_SKIP_IMAGES = bridge.property(WebGL2RenderingContext.UNPACK_SKIP_IMAGES, .{ .template = true, .readonly = true });
    pub const UNPACK_IMAGE_HEIGHT = bridge.property(WebGL2RenderingContext.UNPACK_IMAGE_HEIGHT, .{ .template = true, .readonly = true });
    pub const TEXTURE_3D = bridge.property(WebGL2RenderingContext.TEXTURE_3D, .{ .template = true, .readonly = true });
    pub const TEXTURE_WRAP_R = bridge.property(WebGL2RenderingContext.TEXTURE_WRAP_R, .{ .template = true, .readonly = true });
    pub const MAX_3D_TEXTURE_SIZE = bridge.property(WebGL2RenderingContext.MAX_3D_TEXTURE_SIZE, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_2_10_10_10_REV = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_2_10_10_10_REV, .{ .template = true, .readonly = true });
    pub const MAX_ELEMENTS_VERTICES = bridge.property(WebGL2RenderingContext.MAX_ELEMENTS_VERTICES, .{ .template = true, .readonly = true });
    pub const MAX_ELEMENTS_INDICES = bridge.property(WebGL2RenderingContext.MAX_ELEMENTS_INDICES, .{ .template = true, .readonly = true });
    pub const TEXTURE_MIN_LOD = bridge.property(WebGL2RenderingContext.TEXTURE_MIN_LOD, .{ .template = true, .readonly = true });
    pub const TEXTURE_MAX_LOD = bridge.property(WebGL2RenderingContext.TEXTURE_MAX_LOD, .{ .template = true, .readonly = true });
    pub const TEXTURE_BASE_LEVEL = bridge.property(WebGL2RenderingContext.TEXTURE_BASE_LEVEL, .{ .template = true, .readonly = true });
    pub const TEXTURE_MAX_LEVEL = bridge.property(WebGL2RenderingContext.TEXTURE_MAX_LEVEL, .{ .template = true, .readonly = true });
    pub const MIN = bridge.property(WebGL2RenderingContext.MIN, .{ .template = true, .readonly = true });
    pub const MAX = bridge.property(WebGL2RenderingContext.MAX, .{ .template = true, .readonly = true });
    pub const DEPTH_COMPONENT24 = bridge.property(WebGL2RenderingContext.DEPTH_COMPONENT24, .{ .template = true, .readonly = true });
    pub const MAX_TEXTURE_LOD_BIAS = bridge.property(WebGL2RenderingContext.MAX_TEXTURE_LOD_BIAS, .{ .template = true, .readonly = true });
    pub const TEXTURE_COMPARE_MODE = bridge.property(WebGL2RenderingContext.TEXTURE_COMPARE_MODE, .{ .template = true, .readonly = true });
    pub const TEXTURE_COMPARE_FUNC = bridge.property(WebGL2RenderingContext.TEXTURE_COMPARE_FUNC, .{ .template = true, .readonly = true });
    pub const CURRENT_QUERY = bridge.property(WebGL2RenderingContext.CURRENT_QUERY, .{ .template = true, .readonly = true });
    pub const QUERY_RESULT = bridge.property(WebGL2RenderingContext.QUERY_RESULT, .{ .template = true, .readonly = true });
    pub const QUERY_RESULT_AVAILABLE = bridge.property(WebGL2RenderingContext.QUERY_RESULT_AVAILABLE, .{ .template = true, .readonly = true });
    pub const STREAM_READ = bridge.property(WebGL2RenderingContext.STREAM_READ, .{ .template = true, .readonly = true });
    pub const STREAM_COPY = bridge.property(WebGL2RenderingContext.STREAM_COPY, .{ .template = true, .readonly = true });
    pub const STATIC_READ = bridge.property(WebGL2RenderingContext.STATIC_READ, .{ .template = true, .readonly = true });
    pub const STATIC_COPY = bridge.property(WebGL2RenderingContext.STATIC_COPY, .{ .template = true, .readonly = true });
    pub const DYNAMIC_READ = bridge.property(WebGL2RenderingContext.DYNAMIC_READ, .{ .template = true, .readonly = true });
    pub const DYNAMIC_COPY = bridge.property(WebGL2RenderingContext.DYNAMIC_COPY, .{ .template = true, .readonly = true });
    pub const MAX_DRAW_BUFFERS = bridge.property(WebGL2RenderingContext.MAX_DRAW_BUFFERS, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER0 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER0, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER1 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER1, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER2 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER2, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER3 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER3, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER4 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER4, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER5 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER5, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER6 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER6, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER7 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER7, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER8 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER8, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER9 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER9, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER10 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER10, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER11 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER11, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER12 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER12, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER13 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER13, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER14 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER14, .{ .template = true, .readonly = true });
    pub const DRAW_BUFFER15 = bridge.property(WebGL2RenderingContext.DRAW_BUFFER15, .{ .template = true, .readonly = true });
    pub const MAX_FRAGMENT_UNIFORM_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_FRAGMENT_UNIFORM_COMPONENTS, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_UNIFORM_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_VERTEX_UNIFORM_COMPONENTS, .{ .template = true, .readonly = true });
    pub const SAMPLER_3D = bridge.property(WebGL2RenderingContext.SAMPLER_3D, .{ .template = true, .readonly = true });
    pub const SAMPLER_2D_SHADOW = bridge.property(WebGL2RenderingContext.SAMPLER_2D_SHADOW, .{ .template = true, .readonly = true });
    pub const FRAGMENT_SHADER_DERIVATIVE_HINT = bridge.property(WebGL2RenderingContext.FRAGMENT_SHADER_DERIVATIVE_HINT, .{ .template = true, .readonly = true });
    pub const PIXEL_PACK_BUFFER = bridge.property(WebGL2RenderingContext.PIXEL_PACK_BUFFER, .{ .template = true, .readonly = true });
    pub const PIXEL_UNPACK_BUFFER = bridge.property(WebGL2RenderingContext.PIXEL_UNPACK_BUFFER, .{ .template = true, .readonly = true });
    pub const PIXEL_PACK_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.PIXEL_PACK_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const PIXEL_UNPACK_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.PIXEL_UNPACK_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT2x3 = bridge.property(WebGL2RenderingContext.FLOAT_MAT2x3, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT2x4 = bridge.property(WebGL2RenderingContext.FLOAT_MAT2x4, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT3x2 = bridge.property(WebGL2RenderingContext.FLOAT_MAT3x2, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT3x4 = bridge.property(WebGL2RenderingContext.FLOAT_MAT3x4, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT4x2 = bridge.property(WebGL2RenderingContext.FLOAT_MAT4x2, .{ .template = true, .readonly = true });
    pub const FLOAT_MAT4x3 = bridge.property(WebGL2RenderingContext.FLOAT_MAT4x3, .{ .template = true, .readonly = true });
    pub const SRGB = bridge.property(WebGL2RenderingContext.SRGB, .{ .template = true, .readonly = true });
    pub const SRGB8 = bridge.property(WebGL2RenderingContext.SRGB8, .{ .template = true, .readonly = true });
    pub const SRGB8_ALPHA8 = bridge.property(WebGL2RenderingContext.SRGB8_ALPHA8, .{ .template = true, .readonly = true });
    pub const COMPARE_REF_TO_TEXTURE = bridge.property(WebGL2RenderingContext.COMPARE_REF_TO_TEXTURE, .{ .template = true, .readonly = true });
    pub const RGBA32F = bridge.property(WebGL2RenderingContext.RGBA32F, .{ .template = true, .readonly = true });
    pub const RGB32F = bridge.property(WebGL2RenderingContext.RGB32F, .{ .template = true, .readonly = true });
    pub const RGBA16F = bridge.property(WebGL2RenderingContext.RGBA16F, .{ .template = true, .readonly = true });
    pub const RGB16F = bridge.property(WebGL2RenderingContext.RGB16F, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_INTEGER = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_INTEGER, .{ .template = true, .readonly = true });
    pub const MAX_ARRAY_TEXTURE_LAYERS = bridge.property(WebGL2RenderingContext.MAX_ARRAY_TEXTURE_LAYERS, .{ .template = true, .readonly = true });
    pub const MIN_PROGRAM_TEXEL_OFFSET = bridge.property(WebGL2RenderingContext.MIN_PROGRAM_TEXEL_OFFSET, .{ .template = true, .readonly = true });
    pub const MAX_PROGRAM_TEXEL_OFFSET = bridge.property(WebGL2RenderingContext.MAX_PROGRAM_TEXEL_OFFSET, .{ .template = true, .readonly = true });
    pub const MAX_VARYING_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_VARYING_COMPONENTS, .{ .template = true, .readonly = true });
    pub const TEXTURE_2D_ARRAY = bridge.property(WebGL2RenderingContext.TEXTURE_2D_ARRAY, .{ .template = true, .readonly = true });
    pub const TEXTURE_BINDING_2D_ARRAY = bridge.property(WebGL2RenderingContext.TEXTURE_BINDING_2D_ARRAY, .{ .template = true, .readonly = true });
    pub const R11F_G11F_B10F = bridge.property(WebGL2RenderingContext.R11F_G11F_B10F, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_10F_11F_11F_REV = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_10F_11F_11F_REV, .{ .template = true, .readonly = true });
    pub const RGB9_E5 = bridge.property(WebGL2RenderingContext.RGB9_E5, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_5_9_9_9_REV = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_5_9_9_9_REV, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_BUFFER_MODE = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_BUFFER_MODE, .{ .template = true, .readonly = true });
    pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_VARYINGS = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_VARYINGS, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_BUFFER_START = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_BUFFER_START, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_BUFFER_SIZE = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_BUFFER_SIZE, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, .{ .template = true, .readonly = true });
    pub const RASTERIZER_DISCARD = bridge.property(WebGL2RenderingContext.RASTERIZER_DISCARD, .{ .template = true, .readonly = true });
    pub const MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS, .{ .template = true, .readonly = true });
    pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS = bridge.property(WebGL2RenderingContext.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, .{ .template = true, .readonly = true });
    pub const INTERLEAVED_ATTRIBS = bridge.property(WebGL2RenderingContext.INTERLEAVED_ATTRIBS, .{ .template = true, .readonly = true });
    pub const SEPARATE_ATTRIBS = bridge.property(WebGL2RenderingContext.SEPARATE_ATTRIBS, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_BUFFER = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_BUFFER, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const RGBA32UI = bridge.property(WebGL2RenderingContext.RGBA32UI, .{ .template = true, .readonly = true });
    pub const RGB32UI = bridge.property(WebGL2RenderingContext.RGB32UI, .{ .template = true, .readonly = true });
    pub const RGBA16UI = bridge.property(WebGL2RenderingContext.RGBA16UI, .{ .template = true, .readonly = true });
    pub const RGB16UI = bridge.property(WebGL2RenderingContext.RGB16UI, .{ .template = true, .readonly = true });
    pub const RGBA8UI = bridge.property(WebGL2RenderingContext.RGBA8UI, .{ .template = true, .readonly = true });
    pub const RGB8UI = bridge.property(WebGL2RenderingContext.RGB8UI, .{ .template = true, .readonly = true });
    pub const RGBA32I = bridge.property(WebGL2RenderingContext.RGBA32I, .{ .template = true, .readonly = true });
    pub const RGB32I = bridge.property(WebGL2RenderingContext.RGB32I, .{ .template = true, .readonly = true });
    pub const RGBA16I = bridge.property(WebGL2RenderingContext.RGBA16I, .{ .template = true, .readonly = true });
    pub const RGB16I = bridge.property(WebGL2RenderingContext.RGB16I, .{ .template = true, .readonly = true });
    pub const RGBA8I = bridge.property(WebGL2RenderingContext.RGBA8I, .{ .template = true, .readonly = true });
    pub const RGB8I = bridge.property(WebGL2RenderingContext.RGB8I, .{ .template = true, .readonly = true });
    pub const RED_INTEGER = bridge.property(WebGL2RenderingContext.RED_INTEGER, .{ .template = true, .readonly = true });
    pub const RGB_INTEGER = bridge.property(WebGL2RenderingContext.RGB_INTEGER, .{ .template = true, .readonly = true });
    pub const RGBA_INTEGER = bridge.property(WebGL2RenderingContext.RGBA_INTEGER, .{ .template = true, .readonly = true });
    pub const SAMPLER_2D_ARRAY = bridge.property(WebGL2RenderingContext.SAMPLER_2D_ARRAY, .{ .template = true, .readonly = true });
    pub const SAMPLER_2D_ARRAY_SHADOW = bridge.property(WebGL2RenderingContext.SAMPLER_2D_ARRAY_SHADOW, .{ .template = true, .readonly = true });
    pub const SAMPLER_CUBE_SHADOW = bridge.property(WebGL2RenderingContext.SAMPLER_CUBE_SHADOW, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_VEC2 = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_VEC2, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_VEC3 = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_VEC3, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_VEC4 = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_VEC4, .{ .template = true, .readonly = true });
    pub const INT_SAMPLER_2D = bridge.property(WebGL2RenderingContext.INT_SAMPLER_2D, .{ .template = true, .readonly = true });
    pub const INT_SAMPLER_3D = bridge.property(WebGL2RenderingContext.INT_SAMPLER_3D, .{ .template = true, .readonly = true });
    pub const INT_SAMPLER_CUBE = bridge.property(WebGL2RenderingContext.INT_SAMPLER_CUBE, .{ .template = true, .readonly = true });
    pub const INT_SAMPLER_2D_ARRAY = bridge.property(WebGL2RenderingContext.INT_SAMPLER_2D_ARRAY, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_SAMPLER_2D = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_SAMPLER_2D, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_SAMPLER_3D = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_SAMPLER_3D, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_SAMPLER_CUBE = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_SAMPLER_CUBE, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_SAMPLER_2D_ARRAY = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_SAMPLER_2D_ARRAY, .{ .template = true, .readonly = true });
    pub const DEPTH_COMPONENT32F = bridge.property(WebGL2RenderingContext.DEPTH_COMPONENT32F, .{ .template = true, .readonly = true });
    pub const DEPTH32F_STENCIL8 = bridge.property(WebGL2RenderingContext.DEPTH32F_STENCIL8, .{ .template = true, .readonly = true });
    pub const FLOAT_32_UNSIGNED_INT_24_8_REV = bridge.property(WebGL2RenderingContext.FLOAT_32_UNSIGNED_INT_24_8_REV, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_RED_SIZE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_RED_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_GREEN_SIZE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_GREEN_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_BLUE_SIZE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_BLUE_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_DEFAULT = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_DEFAULT, .{ .template = true, .readonly = true });
    pub const UNSIGNED_INT_24_8 = bridge.property(WebGL2RenderingContext.UNSIGNED_INT_24_8, .{ .template = true, .readonly = true });
    pub const DEPTH24_STENCIL8 = bridge.property(WebGL2RenderingContext.DEPTH24_STENCIL8, .{ .template = true, .readonly = true });
    pub const UNSIGNED_NORMALIZED = bridge.property(WebGL2RenderingContext.UNSIGNED_NORMALIZED, .{ .template = true, .readonly = true });
    pub const DRAW_FRAMEBUFFER_BINDING = bridge.property(WebGL2RenderingContext.DRAW_FRAMEBUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const READ_FRAMEBUFFER = bridge.property(WebGL2RenderingContext.READ_FRAMEBUFFER, .{ .template = true, .readonly = true });
    pub const DRAW_FRAMEBUFFER = bridge.property(WebGL2RenderingContext.DRAW_FRAMEBUFFER, .{ .template = true, .readonly = true });
    pub const READ_FRAMEBUFFER_BINDING = bridge.property(WebGL2RenderingContext.READ_FRAMEBUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const RENDERBUFFER_SAMPLES = bridge.property(WebGL2RenderingContext.RENDERBUFFER_SAMPLES, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER, .{ .template = true, .readonly = true });
    pub const MAX_COLOR_ATTACHMENTS = bridge.property(WebGL2RenderingContext.MAX_COLOR_ATTACHMENTS, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT1 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT1, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT2 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT2, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT3 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT3, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT4 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT4, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT5 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT5, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT6 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT6, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT7 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT7, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT8 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT8, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT9 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT9, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT10 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT10, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT11 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT11, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT12 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT12, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT13 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT13, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT14 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT14, .{ .template = true, .readonly = true });
    pub const COLOR_ATTACHMENT15 = bridge.property(WebGL2RenderingContext.COLOR_ATTACHMENT15, .{ .template = true, .readonly = true });
    pub const FRAMEBUFFER_INCOMPLETE_MULTISAMPLE = bridge.property(WebGL2RenderingContext.FRAMEBUFFER_INCOMPLETE_MULTISAMPLE, .{ .template = true, .readonly = true });
    pub const MAX_SAMPLES = bridge.property(WebGL2RenderingContext.MAX_SAMPLES, .{ .template = true, .readonly = true });
    pub const HALF_FLOAT = bridge.property(WebGL2RenderingContext.HALF_FLOAT, .{ .template = true, .readonly = true });
    pub const RG = bridge.property(WebGL2RenderingContext.RG, .{ .template = true, .readonly = true });
    pub const RG_INTEGER = bridge.property(WebGL2RenderingContext.RG_INTEGER, .{ .template = true, .readonly = true });
    pub const R8 = bridge.property(WebGL2RenderingContext.R8, .{ .template = true, .readonly = true });
    pub const RG8 = bridge.property(WebGL2RenderingContext.RG8, .{ .template = true, .readonly = true });
    pub const R16F = bridge.property(WebGL2RenderingContext.R16F, .{ .template = true, .readonly = true });
    pub const R32F = bridge.property(WebGL2RenderingContext.R32F, .{ .template = true, .readonly = true });
    pub const RG16F = bridge.property(WebGL2RenderingContext.RG16F, .{ .template = true, .readonly = true });
    pub const RG32F = bridge.property(WebGL2RenderingContext.RG32F, .{ .template = true, .readonly = true });
    pub const R8I = bridge.property(WebGL2RenderingContext.R8I, .{ .template = true, .readonly = true });
    pub const R8UI = bridge.property(WebGL2RenderingContext.R8UI, .{ .template = true, .readonly = true });
    pub const R16I = bridge.property(WebGL2RenderingContext.R16I, .{ .template = true, .readonly = true });
    pub const R16UI = bridge.property(WebGL2RenderingContext.R16UI, .{ .template = true, .readonly = true });
    pub const R32I = bridge.property(WebGL2RenderingContext.R32I, .{ .template = true, .readonly = true });
    pub const R32UI = bridge.property(WebGL2RenderingContext.R32UI, .{ .template = true, .readonly = true });
    pub const RG8I = bridge.property(WebGL2RenderingContext.RG8I, .{ .template = true, .readonly = true });
    pub const RG8UI = bridge.property(WebGL2RenderingContext.RG8UI, .{ .template = true, .readonly = true });
    pub const RG16I = bridge.property(WebGL2RenderingContext.RG16I, .{ .template = true, .readonly = true });
    pub const RG16UI = bridge.property(WebGL2RenderingContext.RG16UI, .{ .template = true, .readonly = true });
    pub const RG32I = bridge.property(WebGL2RenderingContext.RG32I, .{ .template = true, .readonly = true });
    pub const RG32UI = bridge.property(WebGL2RenderingContext.RG32UI, .{ .template = true, .readonly = true });
    pub const VERTEX_ARRAY_BINDING = bridge.property(WebGL2RenderingContext.VERTEX_ARRAY_BINDING, .{ .template = true, .readonly = true });
    pub const R8_SNORM = bridge.property(WebGL2RenderingContext.R8_SNORM, .{ .template = true, .readonly = true });
    pub const RG8_SNORM = bridge.property(WebGL2RenderingContext.RG8_SNORM, .{ .template = true, .readonly = true });
    pub const RGB8_SNORM = bridge.property(WebGL2RenderingContext.RGB8_SNORM, .{ .template = true, .readonly = true });
    pub const RGBA8_SNORM = bridge.property(WebGL2RenderingContext.RGBA8_SNORM, .{ .template = true, .readonly = true });
    pub const SIGNED_NORMALIZED = bridge.property(WebGL2RenderingContext.SIGNED_NORMALIZED, .{ .template = true, .readonly = true });
    pub const COPY_READ_BUFFER = bridge.property(WebGL2RenderingContext.COPY_READ_BUFFER, .{ .template = true, .readonly = true });
    pub const COPY_WRITE_BUFFER = bridge.property(WebGL2RenderingContext.COPY_WRITE_BUFFER, .{ .template = true, .readonly = true });
    pub const COPY_READ_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.COPY_READ_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const COPY_WRITE_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.COPY_WRITE_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const UNIFORM_BUFFER = bridge.property(WebGL2RenderingContext.UNIFORM_BUFFER, .{ .template = true, .readonly = true });
    pub const UNIFORM_BUFFER_BINDING = bridge.property(WebGL2RenderingContext.UNIFORM_BUFFER_BINDING, .{ .template = true, .readonly = true });
    pub const UNIFORM_BUFFER_START = bridge.property(WebGL2RenderingContext.UNIFORM_BUFFER_START, .{ .template = true, .readonly = true });
    pub const UNIFORM_BUFFER_SIZE = bridge.property(WebGL2RenderingContext.UNIFORM_BUFFER_SIZE, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_UNIFORM_BLOCKS = bridge.property(WebGL2RenderingContext.MAX_VERTEX_UNIFORM_BLOCKS, .{ .template = true, .readonly = true });
    pub const MAX_FRAGMENT_UNIFORM_BLOCKS = bridge.property(WebGL2RenderingContext.MAX_FRAGMENT_UNIFORM_BLOCKS, .{ .template = true, .readonly = true });
    pub const MAX_COMBINED_UNIFORM_BLOCKS = bridge.property(WebGL2RenderingContext.MAX_COMBINED_UNIFORM_BLOCKS, .{ .template = true, .readonly = true });
    pub const MAX_UNIFORM_BUFFER_BINDINGS = bridge.property(WebGL2RenderingContext.MAX_UNIFORM_BUFFER_BINDINGS, .{ .template = true, .readonly = true });
    pub const MAX_UNIFORM_BLOCK_SIZE = bridge.property(WebGL2RenderingContext.MAX_UNIFORM_BLOCK_SIZE, .{ .template = true, .readonly = true });
    pub const MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS, .{ .template = true, .readonly = true });
    pub const MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS, .{ .template = true, .readonly = true });
    pub const UNIFORM_BUFFER_OFFSET_ALIGNMENT = bridge.property(WebGL2RenderingContext.UNIFORM_BUFFER_OFFSET_ALIGNMENT, .{ .template = true, .readonly = true });
    pub const ACTIVE_UNIFORM_BLOCKS = bridge.property(WebGL2RenderingContext.ACTIVE_UNIFORM_BLOCKS, .{ .template = true, .readonly = true });
    pub const UNIFORM_TYPE = bridge.property(WebGL2RenderingContext.UNIFORM_TYPE, .{ .template = true, .readonly = true });
    pub const UNIFORM_SIZE = bridge.property(WebGL2RenderingContext.UNIFORM_SIZE, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_INDEX = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_INDEX, .{ .template = true, .readonly = true });
    pub const UNIFORM_OFFSET = bridge.property(WebGL2RenderingContext.UNIFORM_OFFSET, .{ .template = true, .readonly = true });
    pub const UNIFORM_ARRAY_STRIDE = bridge.property(WebGL2RenderingContext.UNIFORM_ARRAY_STRIDE, .{ .template = true, .readonly = true });
    pub const UNIFORM_MATRIX_STRIDE = bridge.property(WebGL2RenderingContext.UNIFORM_MATRIX_STRIDE, .{ .template = true, .readonly = true });
    pub const UNIFORM_IS_ROW_MAJOR = bridge.property(WebGL2RenderingContext.UNIFORM_IS_ROW_MAJOR, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_BINDING = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_BINDING, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_DATA_SIZE = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_DATA_SIZE, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_ACTIVE_UNIFORMS = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_ACTIVE_UNIFORMS, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER, .{ .template = true, .readonly = true });
    pub const UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER = bridge.property(WebGL2RenderingContext.UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER, .{ .template = true, .readonly = true });
    pub const INVALID_INDEX = bridge.property(WebGL2RenderingContext.INVALID_INDEX, .{ .template = true, .readonly = true });
    pub const MAX_VERTEX_OUTPUT_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_VERTEX_OUTPUT_COMPONENTS, .{ .template = true, .readonly = true });
    pub const MAX_FRAGMENT_INPUT_COMPONENTS = bridge.property(WebGL2RenderingContext.MAX_FRAGMENT_INPUT_COMPONENTS, .{ .template = true, .readonly = true });
    pub const MAX_SERVER_WAIT_TIMEOUT = bridge.property(WebGL2RenderingContext.MAX_SERVER_WAIT_TIMEOUT, .{ .template = true, .readonly = true });
    pub const OBJECT_TYPE = bridge.property(WebGL2RenderingContext.OBJECT_TYPE, .{ .template = true, .readonly = true });
    pub const SYNC_CONDITION = bridge.property(WebGL2RenderingContext.SYNC_CONDITION, .{ .template = true, .readonly = true });
    pub const SYNC_STATUS = bridge.property(WebGL2RenderingContext.SYNC_STATUS, .{ .template = true, .readonly = true });
    pub const SYNC_FLAGS = bridge.property(WebGL2RenderingContext.SYNC_FLAGS, .{ .template = true, .readonly = true });
    pub const SYNC_FENCE = bridge.property(WebGL2RenderingContext.SYNC_FENCE, .{ .template = true, .readonly = true });
    pub const SYNC_GPU_COMMANDS_COMPLETE = bridge.property(WebGL2RenderingContext.SYNC_GPU_COMMANDS_COMPLETE, .{ .template = true, .readonly = true });
    pub const UNSIGNALED = bridge.property(WebGL2RenderingContext.UNSIGNALED, .{ .template = true, .readonly = true });
    pub const SIGNALED = bridge.property(WebGL2RenderingContext.SIGNALED, .{ .template = true, .readonly = true });
    pub const ALREADY_SIGNALED = bridge.property(WebGL2RenderingContext.ALREADY_SIGNALED, .{ .template = true, .readonly = true });
    pub const TIMEOUT_EXPIRED = bridge.property(WebGL2RenderingContext.TIMEOUT_EXPIRED, .{ .template = true, .readonly = true });
    pub const CONDITION_SATISFIED = bridge.property(WebGL2RenderingContext.CONDITION_SATISFIED, .{ .template = true, .readonly = true });
    pub const WAIT_FAILED = bridge.property(WebGL2RenderingContext.WAIT_FAILED, .{ .template = true, .readonly = true });
    pub const SYNC_FLUSH_COMMANDS_BIT = bridge.property(WebGL2RenderingContext.SYNC_FLUSH_COMMANDS_BIT, .{ .template = true, .readonly = true });
    pub const VERTEX_ATTRIB_ARRAY_DIVISOR = bridge.property(WebGL2RenderingContext.VERTEX_ATTRIB_ARRAY_DIVISOR, .{ .template = true, .readonly = true });
    pub const ANY_SAMPLES_PASSED = bridge.property(WebGL2RenderingContext.ANY_SAMPLES_PASSED, .{ .template = true, .readonly = true });
    pub const ANY_SAMPLES_PASSED_CONSERVATIVE = bridge.property(WebGL2RenderingContext.ANY_SAMPLES_PASSED_CONSERVATIVE, .{ .template = true, .readonly = true });
    pub const SAMPLER_BINDING = bridge.property(WebGL2RenderingContext.SAMPLER_BINDING, .{ .template = true, .readonly = true });
    pub const RGB10_A2UI = bridge.property(WebGL2RenderingContext.RGB10_A2UI, .{ .template = true, .readonly = true });
    pub const INT_2_10_10_10_REV = bridge.property(WebGL2RenderingContext.INT_2_10_10_10_REV, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_PAUSED = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_PAUSED, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_ACTIVE = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_ACTIVE, .{ .template = true, .readonly = true });
    pub const TRANSFORM_FEEDBACK_BINDING = bridge.property(WebGL2RenderingContext.TRANSFORM_FEEDBACK_BINDING, .{ .template = true, .readonly = true });
    pub const TEXTURE_IMMUTABLE_FORMAT = bridge.property(WebGL2RenderingContext.TEXTURE_IMMUTABLE_FORMAT, .{ .template = true, .readonly = true });
    pub const MAX_ELEMENT_INDEX = bridge.property(WebGL2RenderingContext.MAX_ELEMENT_INDEX, .{ .template = true, .readonly = true });
    pub const TEXTURE_IMMUTABLE_LEVELS = bridge.property(WebGL2RenderingContext.TEXTURE_IMMUTABLE_LEVELS, .{ .template = true, .readonly = true });
    pub const TIMEOUT_IGNORED = bridge.property(WebGL2RenderingContext.TIMEOUT_IGNORED, .{ .template = true, .readonly = true });
    pub const MAX_CLIENT_WAIT_TIMEOUT_WEBGL = bridge.property(WebGL2RenderingContext.MAX_CLIENT_WAIT_TIMEOUT_WEBGL, .{ .template = true, .readonly = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGL2RenderingContext" {
    try testing.htmlRunner("canvas/webgl2_rendering_context.html", .{});
}
