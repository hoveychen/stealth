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
// Two of them do reach a measurement: `letterSpacing` and `wordSpacing` are
// read by `measureText`, because without that a string came back the same width
// whatever either one said. Nothing here affects a pixel. The rest exists
// because the *shape* of
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
const canvas_objects = @import("canvas_objects.zig");
const units = @import("../../css/units.zig");
const font_metrics = @import("../../font_metrics.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    lang: []const u8 = "inherit",
    text_align: []const u8 = "start",
    text_baseline: []const u8 = "alphabetic",
    direction: []const u8 = "ltr",
    font_kerning: []const u8 = "auto",
    font_stretch: []const u8 = "normal",
    font_variant_caps: []const u8 = "normal",
    letter_spacing: Spacing = .{},
    text_rendering: []const u8 = "auto",
    word_spacing: Spacing = .{},
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

/// One of the two spacing attributes: the text it reads back as, and the number
/// and unit `measureText` resolves.
///
/// Kept as a number and a unit rather than as pixels because a font-relative
/// unit follows a LATER change of `ctx.font`: `letterSpacing = '1em'` on a 16px
/// font charges 16 per cluster, and the same context after `font = '32px serif'`
/// charges 32 (scratch/b100/expr-canvas-rem.js). Resolving at set time would
/// freeze the first answer.
///
/// The grammar is narrower than the CSS property's, and every line of it is
/// measured on Chrome 151 (scratch/b100/expr-canvas-spacing.js, 46 readings):
///
///   * a length in px, em, rem, ex, ch, in, pt, pc, cm, mm or q, and a bare `0`.
///   * NOT a percentage, NOT `calc()`, NOT `normal`, NOT `inherit` / `initial`,
///     and not a bare non-zero number. The CSS property takes the first three;
///     the attribute does not, and its initial value is `0px` rather than
///     `normal`.
///   * no surrounding white space: `'  3px  '` is refused where `'3px'` is
///     taken. The CSS property trims.
///   * a refused value leaves the previous one, which is the rule the whole of
///     this file follows.
///   * `rem` is the CANVAS font size here, not the root element's: `1rem` on a
///     32px context charges 32 with a 20px root. In CSS it would be 20.
///   * the readback is re-serialised rather than echoed: `2PX` reads back as
///     `2px`, `1e1px` as `10px`, and `0` as `0px`.
pub const Spacing = struct {
    text: []const u8 = "0px",
    value: f64 = 0,
    unit: units.Unit = .px,

    /// CSS pixels, against the font a measurement is about to use.
    pub fn pixels(self: Spacing, font_size: f64, family: font_metrics.Family) f64 {
        if (self.value == 0) return 0;
        const factor: f64 = units.absoluteLengthFactor(self.unit) orelse switch (self.unit) {
            // See the note above: `rem` is not the root's size on a canvas.
            .em, .rem => font_size,
            // `ex` is the x-height and `ch` the advance of `0`, both per family
            // and both already in the measured glyph table at basis 100 -- the
            // same two ratios the computed-style surface answers `2ex` and
            // `3ch` from.
            .ex, .ch => blk: {
                const glyph = font_metrics.glyph(family, if (self.unit == .ex) 'x' else '0') orelse
                    break :blk 0;
                const ratio = (if (self.unit == .ex) glyph.ascent else glyph.advance) / font_metrics.basis;
                break :blk font_size * ratio;
            },
            else => return 0,
        };
        const px = self.value * factor;
        return if (std.math.isFinite(px)) px else 0;
    }

    /// The attribute's value, or null when Chrome would refuse it.
    fn parse(arena: Allocator, raw: []const u8) ?Spacing {
        if (raw.len == 0) return null;
        // Chrome takes the attribute's value untrimmed, so a leading or
        // trailing space refuses it. `units.parse` trims, hence the check here
        // rather than a reliance on it.
        if (std.mem.indexOfAny(u8, raw[0..1], &std.ascii.whitespace) != null) return null;
        if (std.mem.indexOfAny(u8, raw[raw.len - 1 ..], &std.ascii.whitespace) != null) return null;

        const parsed = units.parse(raw) catch return null;
        const unit: units.Unit = switch (parsed.unit) {
            .px, .em, .rem, .ex, .ch, .cm, .mm, .in, .pt, .pc, .q => parsed.unit,
            // Zero needs no unit, and reads back as `0px`.
            .none => if (parsed.value == 0) .px else return null,
            else => return null,
        };
        if (!std.math.isFinite(parsed.value)) return null;

        var buf = std.Io.Writer.Allocating.init(arena);
        units.writeNumber(&buf.writer, parsed.value) catch return null;
        buf.writer.writeAll(units.suffix(unit)) catch return null;
        return .{ .text = buf.written(), .value = parsed.value, .unit = unit };
    }
};

/// The keyword sets Chrome accepts, so a setter can reject the way it does.
pub const text_aligns = [_][]const u8{ "start", "end", "left", "right", "center" };
pub const text_baselines = [_][]const u8{ "top", "hanging", "middle", "alphabetic", "ideographic", "bottom" };
pub const directions = [_][]const u8{ "ltr", "rtl", "inherit" };
pub const font_kernings = [_][]const u8{ "auto", "normal", "none" };

/// Whether `fontKerning` leaves the font's kern pairs on. The third of the three
/// keywords is the only one that does not: measured on Chrome 151, 'AV' at 16px
/// serif is 21.046875 under `auto` and `normal` alike and 23.109375 under
/// `none`, and an unrecognised value keeps the previous keyword rather than
/// reaching here at all (scratch/b100/expr-kern-table.js).
pub fn kerns(font_kerning: []const u8) bool {
    return !std.mem.eql(u8, font_kerning, "none");
}
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

        /// A colour attribute: parsed on assignment, read back serialised, and
        /// left alone when the value does not parse — the same three rules
        /// `fillStyle` follows, because it is the same grammar.
        ///
        /// This used to be `freeform`, which stored the source text. Measured
        /// on Chrome 150: `ctx.shadowColor = 'red'` reads back `#ff0000` and
        /// `rgb(43,22,233)` reads back `#2b16e9`, so storing `red` is a value
        /// no browser reports. It is read surface, not just shape: Akamai's
        /// macys interstitial assigns `shadowColor` twice and reads it back
        /// both times (see tools/fingerprint/probes/probe-canvas-order.js).
        pub fn colour(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *const T) []const u8 {
                    return @field(self._state, field);
                }
                pub fn set(self: *T, value: []const u8, exec: *js.Execution) void {
                    const style = canvas_objects.PaintStyle.parseColour(value) orelse return;
                    const paint: canvas_objects.PaintStyle = .{ .style = style };
                    const read = paint.read(exec.arena) catch return;
                    switch (read) {
                        .text => |text| @field(self._state, field) = text,
                        // `paint` was built without an object arm, so the other
                        // two are unreachable rather than merely unhandled.
                        else => unreachable,
                    }
                }
            };
        }

        /// A string attribute we do not validate, only store. Used for the
        /// ones whose grammar is a whole CSS value (filter, letterSpacing) —
        /// we keep what we were given rather than pretend to parse it, which is
        /// visible only to a script that sets something invalid and reads it
        /// back.
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

        /// One of the two spacing attributes. Unlike `freeform` this one does
        /// parse, because `measureText` reads the result -- see `Spacing`.
        pub fn spacing(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *const T) []const u8 {
                    return @field(self._state, field).text;
                }
                pub fn set(self: *T, value: []const u8, exec: *js.Execution) void {
                    const parsed = Spacing.parse(exec.arena, value) orelse return;
                    @field(self._state, field) = parsed;
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
