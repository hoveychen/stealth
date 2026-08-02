const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");

const StyleSheetList = @This();

_sheets: std.ArrayList(*CSSStyleSheet) = .empty,

pub fn init(frame: *Frame) !*StyleSheetList {
    return frame._factory.create(StyleSheetList{});
}

pub fn length(self: *const StyleSheetList) u32 {
    return @intCast(self._sheets.items.len);
}

pub fn item(self: *const StyleSheetList, index: usize) ?*CSSStyleSheet {
    if (index >= self._sheets.items.len) return null;
    return self._sheets.items[index];
}

pub fn add(self: *StyleSheetList, sheet: *CSSStyleSheet, frame: *Frame) !void {
    try self._sheets.append(frame.arena, sheet);
}

pub fn remove(self: *StyleSheetList, sheet: *CSSStyleSheet) void {
    for (self._sheets.items, 0..) |s, i| {
        if (s == sheet) {
            _ = self._sheets.orderedRemove(i);
            return;
        }
    }
}

pub fn values(self: *StyleSheetList, exec: *js.Execution) !*ValueIterator {
    return .init(.{ .list = self }, exec);
}

const Iterator = struct {
    index: u32 = 0,
    list: *StyleSheetList,

    const Entry = struct { u32, *CSSStyleSheet };

    pub fn next(self: *Iterator, _: *js.Execution) ?Entry {
        const index = self.index;
        const value = self.list.item(index) orelse return null;
        self.index = index + 1;
        return .{ index, value };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const ValueIterator = GenericIterator(Iterator, "1");

pub const JsApi = struct {
    pub const bridge = js.Bridge(StyleSheetList);

    pub const Meta = struct {
        pub const name = "StyleSheetList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(StyleSheetList.length, null, .{});
    pub const item = bridge.function(StyleSheetList.item, .{});
    pub const @"[]" = bridge.indexed(StyleSheetList.item, null, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(StyleSheetList.values, .{});
};
