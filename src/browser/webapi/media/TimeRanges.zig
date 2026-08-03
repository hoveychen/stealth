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

// The buffered / played / seekable ranges of a media element. Nothing here ever
// loads media, so every list is empty -- which is also what a real Chrome
// reports for a `document.createElement('video')` that was never given a src
// (measured: length 0 on all three).
//
// The two IndexSizeError messages are Chrome's, measured on a headed Chrome 150:
// an index equal to the bound says "greater than or equal to", one past it says
// "greater than". `start(-1)` reaches the second branch because the index is an
// unsigned long, so it arrives as 4294967295.

const std = @import("std");

const js = @import("../../js/js.zig");
const DOMException = @import("../DOMException.zig");

const TimeRanges = @This();

pub const Range = struct {
    start: f64,
    end: f64,
};

_ranges: []const Range = &.{},

pub fn getLength(self: *const TimeRanges) u32 {
    return @intCast(self._ranges.len);
}

pub fn start(self: *const TimeRanges, index: u32, exec: *const js.Execution) !f64 {
    try self.checkBound("start", index, exec);
    return self._ranges[index].start;
}

pub fn end(self: *const TimeRanges, index: u32, exec: *const js.Execution) !f64 {
    try self.checkBound("end", index, exec);
    return self._ranges[index].end;
}

fn checkBound(
    self: *const TimeRanges,
    comptime name: []const u8,
    index: u32,
    exec: *const js.Execution,
) !void {
    const len = self.getLength();
    if (index < len) {
        return;
    }

    const comparison = if (index == len) "greater than or equal to" else "greater than";
    // The DOMException borrows the message, so it cannot come off the stack.
    const message = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ name ++ "' on 'TimeRanges': The index provided ({d}) is {s} the maximum bound ({d}).",
        .{ index, comparison, len },
    );

    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, "IndexSizeError"), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TimeRanges);

    pub const Meta = struct {
        pub const name = "TimeRanges";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(TimeRanges.getLength, null, .{});
    pub const end = bridge.function(TimeRanges.end, .{});
    pub const start = bridge.function(TimeRanges.start, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TimeRanges" {
    try testing.htmlRunner("time_ranges.html", .{});
}
