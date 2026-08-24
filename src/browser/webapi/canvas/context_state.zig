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

// The 2D context's drawing state that the rasteriser does not read — shadows,
// text alignment, image smoothing, the typographic knobs — plus the machinery
// to hang it off both context types without writing it twice.
//
// None of it affects a pixel today. It exists because the *shape* of
// CanvasRenderingContext2D.prototype is itself fingerprint surface: Chrome has
// 73 own properties there, of which 28 are accessors and none are plain data
// properties. Before this we had 42, six of them data properties — a profile
// no browser has. Every default below is Chrome's, read off a fresh context
// (see `sections.canvas2d.accessorDefaults` in the graphics dump).
//
// Setters follow the CSS-attribute rule the spec uses throughout the 2D
// context: an unrecognised value is ignored, leaving the previous one.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    lang: []const u8 = "inherit",
    text_align: []const u8 = "start",
    text_baseline: []const u8 = "alphabetic",
    direction: []const u8 = "ltr",
    font_kerning: []const u8 = "auto",
    font_stretch: []const u8 = "normal",
    font_variant_caps: []const u8 = "normal",
    letter_spacing: []const u8 = "0px",
    text_rendering: []const u8 = "auto",
    word_spacing: []const u8 = "0px",
    global_composite_operation: []const u8 = "source-over",
    filter: []const u8 = "none",
    image_smoothing_quality: []const u8 = "low",
    shadow_color: []const u8 = "rgba(0, 0, 0, 0)",
    line_cap: []const u8 = "butt",
    line_join: []const u8 = "miter",
    image_smoothing_enabled: bool = true,
    shadow_offset_x: f64 = 0,
    shadow_offset_y: f64 = 0,
    shadow_blur: f64 = 0,
    miter_limit: f64 = 10,
    line_dash_offset: f64 = 0,
    /// setLineDash / getLineDash round-trip. Owned by the frame arena.
    line_dash: []const f64 = &.{},

    pub fn reset(self: *State) void {
        self.* = .{};
    }
};

/// The keyword sets Chrome accepts, so a setter can reject the way it does.
pub const text_aligns = [_][]const u8{ "start", "end", "left", "right", "center" };
pub const text_baselines = [_][]const u8{ "top", "hanging", "middle", "alphabetic", "ideographic", "bottom" };
pub const directions = [_][]const u8{ "ltr", "rtl", "inherit" };
pub const font_kernings = [_][]const u8{ "auto", "normal", "none" };
pub const font_stretches = [_][]const u8{ "ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "normal", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded" };
pub const font_variant_caps_values = [_][]const u8{ "normal", "small-caps", "all-small-caps", "petite-caps", "all-petite-caps", "unicase", "titling-caps" };
pub const text_renderings = [_][]const u8{ "auto", "optimizeSpeed", "optimizeLegibility", "geometricPrecision" };
pub const smoothing_qualities = [_][]const u8{ "low", "medium", "high" };
pub const line_caps = [_][]const u8{ "butt", "round", "square" };
pub const line_joins = [_][]const u8{ "round", "bevel", "miter" };
pub const composite_operations = [_][]const u8{
    "source-over",      "source-in",      "source-out",      "source-atop",
    "destination-over", "destination-in", "destination-out", "destination-atop",
    "lighter",          "copy",           "xor",             "multiply",
    "screen",           "overlay",        "darken",          "lighten",
    "color-dodge",      "color-burn",     "hard-light",      "soft-light",
    "difference",       "exclusion",      "hue",             "saturation",
    "color",            "luminosity",
};

/// Builds the accessor pairs for a context type. `T` must have a `_state`
/// field; the returned declarations are what the JsApi block binds.
pub fn Accessors(comptime T: type) type {
    return struct {
        /// A string attribute constrained to a keyword set.
        pub fn keyword(comptime field: []const u8, comptime allowed: []const []const u8) type {
            return struct {
                pub fn get(self: *const T) []const u8 {
                    return @field(self._state, field);
                }
                pub fn set(self: *T, value: []const u8) void {
                    for (allowed) |candidate| {
                        if (std.mem.eql(u8, candidate, value)) {
                            @field(self._state, field) = candidate;
                            return;
                        }
                    }
                }
            };
        }

        /// A string attribute we do not validate, only store. Used for the
        /// ones whose grammar is a whole CSS value (filter, shadowColor,
        /// letterSpacing) — we keep what we were given rather than pretend to
        /// parse it, which is visible only to a script that sets something
        /// invalid and reads it back.
        pub fn freeform(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *const T) []const u8 {
                    return @field(self._state, field);
                }
                pub fn set(self: *T, value: []const u8, exec: *js.Execution) void {
                    @field(self._state, field) = exec.arena.dupe(u8, value) catch return;
                }
            };
        }

        /// A numeric attribute. Non-finite values are ignored, per the spec.
        pub fn number(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *const T) f64 {
                    return @field(self._state, field);
                }
                pub fn set(self: *T, value: f64) void {
                    if (std.math.isFinite(value)) {
                        @field(self._state, field) = value;
                    }
                }
            };
        }

        pub fn boolean(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *const T) bool {
                    return @field(self._state, field);
                }
                pub fn set(self: *T, value: bool) void {
                    @field(self._state, field) = value;
                }
            };
        }
    };
}

/// An even-length, non-negative, finite dash list, as `setLineDash` accepts
/// it: an odd-length list is doubled, and anything invalid is dropped whole.
pub fn normaliseLineDash(arena: Allocator, input: []const f64) ?[]const f64 {
    for (input) |segment| {
        if (!std.math.isFinite(segment) or segment < 0) {
            return null;
        }
    }
    if (input.len % 2 == 0) {
        return arena.dupe(f64, input) catch null;
    }

    const doubled = arena.alloc(f64, input.len * 2) catch return null;
    @memcpy(doubled[0..input.len], input);
    @memcpy(doubled[input.len..], input);
    return doubled;
}

const testing = std.testing;

test "context_state: line dash normalisation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualSlices(f64, &.{ 1, 2 }, normaliseLineDash(allocator, &.{ 1, 2 }).?);
    // Odd lengths are repeated, so getLineDash reports four entries.
    try testing.expectEqualSlices(f64, &.{ 1, 2, 3, 1, 2, 3 }, normaliseLineDash(allocator, &.{ 1, 2, 3 }).?);
    try testing.expectEqual(@as(?[]const f64, null), normaliseLineDash(allocator, &.{ 1, -2 }));
    try testing.expectEqual(@as(?[]const f64, null), normaliseLineDash(allocator, &.{std.math.inf(f64)}));
    try testing.expectEqual(@as(usize, 0), normaliseLineDash(allocator, &.{}).?.len);
}
