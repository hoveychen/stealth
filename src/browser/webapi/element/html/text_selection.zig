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

//! `setRangeText`, which <input> and <textarea> share verbatim -- the only
//! thing that differs between them is the interface name in the refusal.

const std = @import("std");

const Frame = @import("../../../Frame.zig");

pub const Result = struct {
    value: []const u8,
    selection_start: u32,
    selection_end: u32,
};

pub const Args = struct {
    value: []const u8,
    selection_start: u32,
    selection_end: u32,
    replacement: []const u8,
    start: ?u32 = null,
    end: ?u32 = null,
    mode: ?[]const u8 = null,
};

/// Replaces `[start, end)` with the replacement and reports where the selection
/// lands. With no range, the *current* selection is what gets replaced
/// (measured: value "abcdef", selection [2, 4), `setRangeText('ZZ')` gives
/// "abZZef" with the selection still [2, 4)).
///
/// The three explicit modes, measured on value "abcdef" with the selection and
/// the replaced range both [1, 3) and the replacement "XY": `select` selects
/// the replacement [1, 3), `start` collapses to [1, 1), `end` collapses to
/// [3, 3). `preserve`, the default, is `shiftStart`/`shiftEnd` below.
pub fn setRangeText(args: Args, comptime interface: []const u8, frame: *Frame) !Result {
    const value = args.value;
    const len: u32 = @intCast(value.len);
    const start = @min(args.start orelse args.selection_start, len);
    const end = @min(args.end orelse args.selection_end, len);

    if (start > end) {
        return frame.js.fail(error.IndexSizeError, try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to execute 'setRangeText' on '" ++ interface ++
                "': The provided start value ({d}) is larger than the provided end value ({d}).",
            .{ start, end },
        ));
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(frame.arena, value.len - (end - start) + args.replacement.len);
    buf.appendSliceAssumeCapacity(value[0..start]);
    buf.appendSliceAssumeCapacity(args.replacement);
    buf.appendSliceAssumeCapacity(value[end..]);

    const replacement_len: u32 = @intCast(args.replacement.len);
    const mode = args.mode orelse "preserve";
    var selection_start = args.selection_start;
    var selection_end = args.selection_end;

    if (std.mem.eql(u8, mode, "select")) {
        selection_start = start;
        selection_end = start + replacement_len;
    } else if (std.mem.eql(u8, mode, "start")) {
        selection_start = start;
        selection_end = start;
    } else if (std.mem.eql(u8, mode, "end")) {
        selection_start = start + replacement_len;
        selection_end = selection_start;
    } else {
        selection_start = shiftStart(selection_start, start, end, replacement_len);
        selection_end = shiftEnd(selection_end, start, end, replacement_len);
    }

    return .{
        .value = buf.items,
        .selection_start = selection_start,
        .selection_end = selection_end,
    };
}

/// The "preserve" rule for the selection's start: past the replaced range it
/// moves by the length difference, inside it collapses to the range's start,
/// before it stays put.
fn shiftStart(offset: u32, start: u32, end: u32, replacement_len: u32) u32 {
    if (offset > end) {
        return offset - (end - start) + replacement_len;
    }
    if (offset > start) {
        return start;
    }
    return offset;
}

/// The same rule for the selection's end, except that an end sitting exactly on
/// the replaced range's end moves rather than collapsing -- the one place the
/// two halves differ. Four measurements pin it, all with the selection at
/// [1, 3) on "abcdef": replacing [1, 3) with "XY" leaves [1, 3), with "Z"
/// leaves [1, 2), replacing [4, 5) with "ZZZ" leaves [1, 3) untouched, and
/// replacing [0, 1) with "QQ" gives [0, 4).
fn shiftEnd(offset: u32, start: u32, end: u32, replacement_len: u32) u32 {
    if (offset >= end) {
        return offset - (end - start) + replacement_len;
    }
    if (offset > start) {
        return start;
    }
    return offset;
}
