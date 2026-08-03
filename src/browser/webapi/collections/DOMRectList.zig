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

// What getClientRects() hands back. It used to be a plain JS Array here, which
// is a tell a one-liner reads: `document.body.getClientRects().constructor.name`
// is DOMRectList in every browser and was Array in ours. Measured on a headed
// Chrome 150: length, item(i) returning null past the end, indexed access that
// ignores assignment, and @@iterator being a function named "values" with no
// `values` property of its own.

const js = @import("../../js/js.zig");
const DOMRect = @import("../DOMRect.zig");

pub fn registerTypes() []const type {
    return &.{
        DOMRectList,
        DOMRectList.Iterator,
    };
}

const DOMRectList = @This();

_rects: []*DOMRect = &.{},

pub fn getLength(self: *const DOMRectList) u32 {
    return @intCast(self._rects.len);
}

pub fn item(self: *const DOMRectList, index: u32) ?*DOMRect {
    if (index >= self._rects.len) {
        return null;
    }
    return self._rects[index];
}

pub fn iterator(self: *DOMRectList, exec: *const js.Execution) !*Iterator {
    return Iterator.init(.{ .index = 0, .list = self }, exec);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    index: u32,
    list: *DOMRectList,

    pub fn next(self: *@This(), _: *const js.Execution) ?*DOMRect {
        const index = self.index;
        const rect = self.list.item(index) orelse return null;
        self.index = index + 1;
        return rect;
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMRectList);

    pub const Meta = struct {
        pub const name = "DOMRectList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(DOMRectList.getLength, null, .{});
    pub const item = bridge.function(DOMRectList.item, .{});
    pub const @"[]" = bridge.indexed(DOMRectList.item, getIndexes, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(DOMRectList.iterator, .{ .js_name = "values" });

    fn getIndexes(self: *DOMRectList, exec: *const js.Execution) !js.Array {
        const len = self.getLength();
        var arr = exec.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: DOMRectList" {
    try testing.htmlRunner("dom_rect_list.html", .{});
}
