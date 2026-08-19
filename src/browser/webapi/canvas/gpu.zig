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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Everything on the WebGL surface that comes from the driver rather than from
//! the spec, in one table per claimed platform.
//!
//! The spec pins the enum numbering and says nothing about what a driver
//! answers for `MAX_TEXTURE_SIZE`, which extensions it advertises, or what
//! `WEBGL_debug_renderer_info` reports — and those are exactly the values that
//! identify a machine. A detector that reads the ANGLE renderer string and then
//! checks whether the limits beside it belong to that GPU sees one browser only
//! if both come from the same recording, which is why they live together here
//! and are selected by one constant.
//!
//! Both columns are measured, not derived:
//!
//!   * `.macos` — the Chrome on the reference host, an Apple M4 behind ANGLE's
//!     Metal backend (`tools/fingerprint/results/reference-chrome-graphics.json`).
//!   * `.linux` — the official amd64 Chrome in a container, which has no GPU and
//!     falls back to SwiftShader
//!     (`tools/fingerprint/results/reference-linux-graphics.json`).
//!
//! Re-record with `tools/fingerprint/dump-graphics.mjs` rather than editing a
//! value from memory. A limit invented to look plausible is worse than a wrong
//! one that at least belongs to a real driver: the fake will not cross-check.

const std = @import("std");
const claimed_platform = @import("../../../claimed_platform.zig");

/// A range/precision triple as `getShaderPrecisionFormat` reports it.
pub const Precision = struct {
    range_min: i32,
    range_max: i32,
    precision: i32,
};

pub const Gpu = struct {
    /// `WEBGL_debug_renderer_info`. The single most identifying pair of strings
    /// on the whole surface.
    unmasked_vendor: []const u8,
    unmasked_renderer: []const u8,

    // Limits both WebGL 1 and WebGL 2 report, with the same value in each.
    aliased_point_size_max: f32,
    max_texture_size: u32,
    max_renderbuffer_size: u32,
    max_viewport_dim: i32,
    max_vertex_uniform_vectors: u32,
    max_fragment_uniform_vectors: u32,
    max_varying_vectors: u32,
    max_combined_texture_image_units: u32,
    max_vertex_texture_image_units: u32,
    max_texture_image_units: u32,

    // WebGL 2 only.
    max_draw_buffers: u32,
    max_color_attachments: u32,
    max_element_index: u32,
    max_fragment_input_components: u32,
    max_vertex_output_components: u32,
    max_varying_components: u32,
    max_vertex_uniform_blocks: u32,
    max_fragment_uniform_blocks: u32,
    max_combined_uniform_blocks: u32,
    max_uniform_buffer_bindings: u32,
    max_uniform_block_size: u32,
    max_vertex_uniform_components: u32,
    max_fragment_uniform_components: u32,
    max_combined_vertex_uniform_components: u32,
    max_combined_fragment_uniform_components: u32,
    uniform_buffer_offset_alignment: u32,

    /// `getShaderPrecisionFormat`. The high precisions are the same on both
    /// drivers; the low and medium ones are where an ES2-era driver differs from
    /// one that promotes everything to highp, so they are not folded together.
    low_float: Precision,
    medium_float: Precision,
    high_float: Precision,
    low_int: Precision,
    medium_int: Precision,
    high_int: Precision,

    /// What `getInternalformatParameter(RENDERBUFFER, RGBA8, SAMPLES)` answers:
    /// the multisample counts the driver offers, descending.
    internalformat_samples: []const i32,

    /// Extension names this driver does *not* advertise, out of the superset the
    /// two contexts know about. Stored as the exclusions rather than as two full
    /// lists so that adding an extension to a context cannot silently skip one
    /// platform.
    webgl1_unsupported: []const []const u8,
    webgl2_unsupported: []const []const u8,
};

const macos: Gpu = .{
    .unmasked_vendor = "Google Inc. (Apple)",
    .unmasked_renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)",

    .aliased_point_size_max = 511,
    .max_texture_size = 16384,
    .max_renderbuffer_size = 16384,
    .max_viewport_dim = 16384,
    .max_vertex_uniform_vectors = 1024,
    .max_fragment_uniform_vectors = 1024,
    .max_varying_vectors = 30,
    .max_combined_texture_image_units = 32,
    .max_vertex_texture_image_units = 16,
    .max_texture_image_units = 16,

    .max_draw_buffers = 8,
    .max_color_attachments = 8,
    .max_element_index = 4294967294,
    .max_fragment_input_components = 120,
    .max_vertex_output_components = 120,
    .max_varying_components = 120,
    .max_vertex_uniform_blocks = 16,
    .max_fragment_uniform_blocks = 16,
    .max_combined_uniform_blocks = 32,
    .max_uniform_buffer_bindings = 32,
    .max_uniform_block_size = 16384,
    .max_vertex_uniform_components = 4096,
    .max_fragment_uniform_components = 4096,
    .max_combined_vertex_uniform_components = 69632,
    .max_combined_fragment_uniform_components = 69632,
    .uniform_buffer_offset_alignment = 16,

    // Metal has no lowp or mediump: all six answer the highp triple.
    .low_float = .{ .range_min = 127, .range_max = 127, .precision = 23 },
    .medium_float = .{ .range_min = 127, .range_max = 127, .precision = 23 },
    .high_float = .{ .range_min = 127, .range_max = 127, .precision = 23 },
    .low_int = .{ .range_min = 31, .range_max = 30, .precision = 0 },
    .medium_int = .{ .range_min = 31, .range_max = 30, .precision = 0 },
    .high_int = .{ .range_min = 31, .range_max = 30, .precision = 0 },

    .internalformat_samples = &.{ 4, 2 },

    .webgl1_unsupported = &.{},
    .webgl2_unsupported = &.{"OVR_multiview2"},
};

const linux: Gpu = .{
    .unmasked_vendor = "Google Inc. (Google)",
    .unmasked_renderer = "ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)",

    .aliased_point_size_max = 1023,
    .max_texture_size = 8192,
    .max_renderbuffer_size = 8192,
    .max_viewport_dim = 8192,
    .max_vertex_uniform_vectors = 4096,
    .max_fragment_uniform_vectors = 4096,
    .max_varying_vectors = 31,
    .max_combined_texture_image_units = 64,
    .max_vertex_texture_image_units = 32,
    .max_texture_image_units = 32,

    .max_draw_buffers = 6,
    .max_color_attachments = 6,
    .max_element_index = 1073741823,
    .max_fragment_input_components = 128,
    .max_vertex_output_components = 128,
    .max_varying_components = 124,
    .max_vertex_uniform_blocks = 14,
    .max_fragment_uniform_blocks = 14,
    .max_combined_uniform_blocks = 60,
    .max_uniform_buffer_bindings = 72,
    .max_uniform_block_size = 65536,
    .max_vertex_uniform_components = 16384,
    .max_fragment_uniform_components = 16384,
    .max_combined_vertex_uniform_components = 245760,
    .max_combined_fragment_uniform_components = 245760,
    .uniform_buffer_offset_alignment = 256,

    // SwiftShader does distinguish them, and the difference is readable.
    .low_float = .{ .range_min = 15, .range_max = 15, .precision = 10 },
    .medium_float = .{ .range_min = 15, .range_max = 15, .precision = 10 },
    .high_float = .{ .range_min = 127, .range_max = 127, .precision = 23 },
    .low_int = .{ .range_min = 15, .range_max = 14, .precision = 0 },
    .medium_int = .{ .range_min = 15, .range_max = 14, .precision = 0 },
    .high_int = .{ .range_min = 31, .range_max = 30, .precision = 0 },

    .internalformat_samples = &.{4},

    .webgl1_unsupported = &.{
        "EXT_disjoint_timer_query",
        "KHR_parallel_shader_compile",
        "WEBGL_blend_func_extended",
        "WEBGL_compressed_texture_pvrtc",
    },
    .webgl2_unsupported = &.{
        "EXT_disjoint_timer_query_webgl2",
        "EXT_render_snorm",
        "EXT_texture_norm16",
        "KHR_parallel_shader_compile",
        "WEBGL_blend_func_extended",
        "WEBGL_compressed_texture_pvrtc",
        "WEBGL_provoking_vertex",
        "WEBGL_render_shared_exponent",
    },
};

/// The table the engine reports from, following the platform claim.
pub const gpu: Gpu = switch (claimed_platform.claimed) {
    .macos => macos,
    .linux => linux,
};

/// Drops the names this driver does not advertise, keeping the order it was
/// given. Chrome's own order is alphabetical on both platforms, so a list that
/// arrives sorted stays sorted.
pub fn advertised(comptime names: []const []const u8, comptime unsupported: []const []const u8) []const []const u8 {
    comptime {
        var kept: [names.len][]const u8 = undefined;
        var len: usize = 0;
        outer: for (names) |name| {
            for (unsupported) |drop| {
                if (std.mem.eql(u8, name, drop)) continue :outer;
            }
            kept[len] = name;
            len += 1;
        }
        const final = kept[0..len].*;
        return &final;
    }
}
