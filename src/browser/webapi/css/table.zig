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

//! How wide a table's columns are.
//!
//! Split out from CSSStyleDeclaration for the reason css/grid.zig is: once each
//! cell has been measured, what is left is arithmetic over two numbers per
//! column, and none of it needs the document.
//!
//! Every rule here was read off Chrome 153 with scratch/s79/expr-table.js (the
//! thirteen reference shapes) and scratch/s80/expr-tabledist.js (which reports
//! each cell's own min-content and max-content beside the column width it got,
//! so the sharing rule could be fitted rather than guessed).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One column, as its cells leave it.
pub const Column = struct {
    /// The widest thing in the column that a line break cannot shorten.
    min: f64 = 0,
    /// What the column takes when nothing makes it wrap.
    max: f64 = 0,
    /// A width one of its cells declared. A column that has one neither grows
    /// nor shrinks with the rest: `width:100px` on the first of two cells of a
    /// 600px table is 100 and 500 in Chrome, where sharing the surplus out in
    /// proportion would have made it 268.
    fixed: ?f64 = null,
};

/// Where a column starts and how wide it is.
pub const Placed = struct {
    start: f64,
    size: f64,
};

/// The two intrinsic widths of the whole table's content box: what it needs,
/// and what it would like. Both already hold the `border-spacing` that sits
/// between the columns and outside the end ones -- `border-spacing:7px` puts
/// the first cell at x=7, which is spacing on the outside and not only between.
pub fn intrinsicWidths(columns: []const Column, spacing: f64) struct { min: f64, max: f64 } {
    var min: f64 = 0;
    var max: f64 = 0;
    for (columns) |column| {
        min += lowerBound(column);
        max += upperBound(column);
    }
    const count: f64 = @floatFromInt(columns.len);
    const gaps = spacing * (count + 1);
    return .{ .min = min + gaps, .max = max + gaps };
}

/// A column's floor. A declared width is one, but never below what the content
/// cannot give up: `longWord` in scratch/s80 has a column whose min-content is
/// 620.7422 and which keeps every pixel of it in an 800px table.
fn lowerBound(column: Column) f64 {
    if (column.fixed) |px| return @max(px, column.min);
    return column.min;
}

fn upperBound(column: Column) f64 {
    if (column.fixed) |px| return @max(px, column.min);
    return @max(column.max, column.min);
}

/// A length on Chrome's internal layout unit, which is 1/64px -- finer than the
/// 1/128 device grid a reading comes back on at dpr 2, and so invisible except
/// where an intermediate result is proportioned over it.
fn quantise(px: f64) f64 {
    return @floor(px * 64) / 64;
}

/// Size and place the columns inside a table whose own content width is known.
///
/// Three regimes, each of which one reference shape pins:
///
///   * **too little room.** Every column takes its floor and the table
///     overflows: `width:60px` around two columns whose min-content is 52.4609
///     leaves both at 52.4609.
///   * **room to spare.** The surplus over the sum of the max-contents goes to
///     the columns in proportion to those max-contents, and skips any column a
///     cell declared a width for. A 600px table over 8.0625 and 124.1484 comes
///     out 36.5859 and 563.4141, and 8.0625 + 467.789 x 8.0625/132.2109 is
///     exactly that.
///   * **in between.** Each column gets its floor plus a share of what is left,
///     in proportion to how much it wanted ON TOP of that floor. Two columns of
///     min 52.4609 and max 685.8281 / 340.9844 in 800px come out 530 and 270,
///     which proportion-to-max would have made 534.3 and 265.7.
///
/// The sizes are what is snapped, and the last column absorbs the rounding so
/// the columns end exactly at the table's edge. That is the opposite of the
/// grid rule in css/grid.zig, and `fixedEven` is what tells them apart: three
/// even columns of a 400px table are 133.3281 / 133.3281 / **133.3438** in
/// Chrome, where snapping the running edge instead gives a third 133.3359.
pub fn sizeColumns(
    arena: Allocator,
    columns: []const Column,
    content_width: f64,
    spacing: f64,
    snap: *const fn (f64) f64,
) Allocator.Error![]Placed {
    const out = try arena.alloc(Placed, columns.len);
    if (columns.len == 0) return out;

    const count: f64 = @floatFromInt(columns.len);
    const target = content_width - spacing * (count + 1);

    var total_low: f64 = 0;
    var total_high: f64 = 0;
    var flexible_high: f64 = 0;
    // The same two sums on Chrome's own layout unit of 1/64px, which is where
    // the sharing below happens. Worth carrying separately: a min-content of
    // 52.4609375 is 3357.5 layout units, the half never survives, and two
    // columns of it in an 800px table split exactly 530 / 270 with the floor
    // against 530.0156 / 269.9844 without.
    var unit_low: f64 = 0;
    var unit_growth: f64 = 0;
    for (columns) |column| {
        const low = lowerBound(column);
        const high = upperBound(column);
        total_low += low;
        total_high += high;
        unit_low += quantise(low);
        unit_growth += quantise(high) - quantise(low);
        if (column.fixed == null) flexible_high += high;
    }
    // With nothing free to grow, the surplus has to land somewhere: a table of
    // none but declared columns still stretches to the width it was given.
    const stretch_high = if (flexible_high > 0) flexible_high else total_high;

    var edge: f64 = spacing;
    var remaining = target;
    for (columns, out, 0..) |column, *placed, i| {
        const low = lowerBound(column);
        const high = upperBound(column);

        var size: f64 = if (target <= total_low)
            low
        else if (target >= total_high) grow: {
            const surplus = target - total_high;
            if (column.fixed != null and flexible_high > 0) break :grow high;
            if (stretch_high <= 0) break :grow high + surplus / count;
            break :grow high + surplus * high / stretch_high;
        } else if (unit_growth > 0)
            quantise(low) + (target - unit_low) * (quantise(high) - quantise(low)) / unit_growth
        else
            low;

        size = snap(@max(0, size));
        // The last column is the remainder rather than its own rounding, so a
        // table that fits ends exactly where it said it would.
        if (i + 1 == columns.len and target > total_low) size = @max(0, remaining);
        remaining -= size;

        placed.* = .{ .start = edge, .size = size };
        edge += size + spacing;
    }
    return out;
}

/// `table-layout: fixed` with a table width to divide: a column a cell declared
/// a width for takes it, and the columns that declared none split what is left
/// evenly whatever they hold. `fixedEven` -- three undeclared columns of a
/// 400px table -- is 133.3281 / 133.3281 / 133.3438 and not three shares of the
/// content, which under auto layout would have been 8.0625 / 124.1484 / 8.1094.
///
/// A fixed table with NO width of its own has nothing to divide and falls back
/// to `sizeColumns`, which `fixedAuto` pins: `table-layout:fixed` over a 120px
/// cell and a word is 120 / 124.1484, the shrink-to-fit answer.
pub fn sizeFixedColumns(
    arena: Allocator,
    columns: []const Column,
    content_width: f64,
    spacing: f64,
    snap: *const fn (f64) f64,
) Allocator.Error![]Placed {
    const out = try arena.alloc(Placed, columns.len);
    if (columns.len == 0) return out;

    const count: f64 = @floatFromInt(columns.len);
    const target = content_width - spacing * (count + 1);

    var declared: f64 = 0;
    var auto_count: f64 = 0;
    for (columns) |column| {
        if (column.fixed) |px| declared += px else auto_count += 1;
    }
    const each = if (auto_count > 0) @max(0, target - declared) / auto_count else 0;

    var edge: f64 = spacing;
    var remaining = target;
    for (columns, out, 0..) |column, *placed, i| {
        var size = snap(@max(0, column.fixed orelse each));
        if (i + 1 == columns.len) size = @max(0, remaining);
        remaining -= size;
        placed.* = .{ .start = edge, .size = size };
        edge += size + spacing;
    }
    return out;
}

const testing = std.testing;

fn testSnap(px: f64) f64 {
    const narrowed: f64 = @as(f32, @floatCast(px));
    return @floor(narrowed * 128) / 128;
}

test "table: a table with room to spare is its columns' max-contents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s79 `narrow`: `a` and `Hamburgefonstiv` in an 800px host come out
    // 8.0625 and 124.1484 with the table itself 132.2109 wide.
    const columns = [_]Column{
        .{ .min = 8.0625, .max = 8.0625 },
        .{ .min = 124.1484375, .max = 124.1484375 },
    };
    const widths = intrinsicWidths(&columns, 0);
    try testing.expectEqual(@as(f64, 132.2109375), widths.max);

    const placed = try sizeColumns(a, &columns, widths.max, 0, testSnap);
    try testing.expectEqual(@as(f64, 0), placed[0].start);
    try testing.expectEqual(@as(f64, 8.0625), placed[0].size);
    try testing.expectEqual(@as(f64, 8.0625), placed[1].start);
    try testing.expectEqual(@as(f64, 124.1484375), placed[1].size);
}

test "table: the surplus is shared in proportion to the max-contents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s79 `widerTable`: the same two columns in a `width:600px` table.
    const placed = try sizeColumns(a, &.{
        .{ .min = 8.0625, .max = 8.0625 },
        .{ .min = 124.1484375, .max = 124.1484375 },
    }, 600, 0, testSnap);
    try testing.expectEqual(@as(f64, 36.5859375), placed[0].size);
    try testing.expectEqual(@as(f64, 563.4140625), placed[1].size);
}

test "table: a declared cell width neither grows nor shrinks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s79 `cellWidth`: `width:100px` on the first of two cells of a
    // 600px table is 100 and 500.
    const placed = try sizeColumns(a, &.{
        .{ .min = 8.0625, .max = 8.0625, .fixed = 100 },
        .{ .min = 124.1484375, .max = 124.1484375 },
    }, 600, 0, testSnap);
    try testing.expectEqual(@as(f64, 100), placed[0].size);
    try testing.expectEqual(@as(f64, 500), placed[1].size);
}

test "table: what is left over is shared by how much each column still wanted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s80 `overflowing`: two columns of the same min-content, wanting
    // 685.8281 and 340.9844, in 800px. Chrome puts the split at 530 / 270.
    const placed = try sizeColumns(a, &.{
        .{ .min = 52.4609375, .max = 685.828125 },
        .{ .min = 52.4609375, .max = 340.984375 },
    }, 800, 0, testSnap);
    try testing.expect(@abs(placed[0].size - 530) < 0.05);
    try testing.expectEqual(@as(f64, 800), placed[1].start + placed[1].size);
}

test "table: too little room leaves every column at its min-content" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s80 `squeezed`: a `width:60px` table over two columns whose
    // min-content is 52.4609 each keeps both and overflows.
    const placed = try sizeColumns(a, &.{
        .{ .min = 52.4609375, .max = 340.984375 },
        .{ .min = 52.4609375, .max = 168.5625 },
    }, 60, 0, testSnap);
    try testing.expectEqual(@as(f64, 52.4609375), placed[0].size);
    try testing.expectEqual(@as(f64, 52.4609375), placed[1].size);
}

test "table: border-spacing sits between the columns and outside the end ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s79 `spacing`: `border-spacing:7px 3px` puts the cells at x=7 and
    // x=22.0625, which is 7 + 8.0625 + 7.
    const columns = [_]Column{
        .{ .min = 8.0625, .max = 8.0625 },
        .{ .min = 124.1484375, .max = 124.1484375 },
    };
    const widths = intrinsicWidths(&columns, 7);
    try testing.expectEqual(@as(f64, 132.2109375 + 21), widths.max);

    const placed = try sizeColumns(a, &columns, widths.max, 7, testSnap);
    try testing.expectEqual(@as(f64, 7), placed[0].start);
    try testing.expectEqual(@as(f64, 22.0625), placed[1].start);
}

test "table: fixed layout splits what is left evenly, last column first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scratch/s79 `fixedEven`: three undeclared columns of a 400px table.
    const even = try sizeFixedColumns(a, &.{ .{}, .{}, .{} }, 400, 0, testSnap);
    try testing.expectEqual(@as(f64, 133.328125), even[0].size);
    try testing.expectEqual(@as(f64, 133.328125), even[1].size);
    try testing.expectEqual(@as(f64, 133.34375), even[2].size);
    try testing.expectEqual(@as(f64, 266.65625), even[2].start);

    // `fixed`: a declared 100px column beside an auto one.
    const mixed = try sizeFixedColumns(a, &.{
        .{ .min = 8.0625, .max = 8.0625, .fixed = 100 },
        .{ .min = 124.1484375, .max = 124.1484375 },
    }, 400, 0, testSnap);
    try testing.expectEqual(@as(f64, 100), mixed[0].size);
    try testing.expectEqual(@as(f64, 300), mixed[1].size);
}
