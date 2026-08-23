// The comma-separated media query list behind `sheet.media`, `@media`'s
// `media` and `@import`'s `media`.
//
// Chrome keeps the queries as separate entries and re-serialises them joined
// with ", ", so `item(i)` hands back one query and `mediaText` hands back the
// join. Measured on Chrome 150: appendMedium / deleteMedium mutate in place
// and `mediaText` is the live serialisation, which is what makes
// `mediaRule.media.mediaText = 'print'` change the owning rule's cssText.

const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const MediaList = @This();

_items: std.ArrayList([]const u8) = .empty,

pub fn init(frame: *Frame) !*MediaList {
    return frame._factory.create(MediaList{});
}

pub fn initWithText(text: []const u8, frame: *Frame) !*MediaList {
    const list = try MediaList.init(frame);
    try list.setMediaText(text, frame);
    return list;
}

pub fn getLength(self: *const MediaList) u32 {
    return @intCast(self._items.items.len);
}

pub fn getMediaText(self: *const MediaList, frame: *Frame) ![]const u8 {
    if (self._items.items.len == 0) return "";
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    for (self._items.items, 0..) |query, i| {
        if (i != 0) try buf.writer.writeAll(", ");
        try buf.writer.writeAll(query);
    }
    return buf.written();
}

pub fn setMediaText(self: *MediaList, text: []const u8, frame: *Frame) !void {
    self._items.clearRetainingCapacity();
    var it = splitTopLevel(text);
    while (it.next()) |query| {
        if (query.len == 0) continue;
        try self._items.append(frame.arena, try frame.dupeString(query));
    }
}

pub fn item(self: *const MediaList, index: u32) ?[]const u8 {
    if (index >= self._items.items.len) return null;
    return self._items.items[index];
}

pub fn appendMedium(self: *MediaList, medium: []const u8, frame: *Frame) !void {
    const trimmed = std.mem.trim(u8, medium, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    for (self._items.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, trimmed)) return;
    }
    try self._items.append(frame.arena, try frame.dupeString(trimmed));
}

pub fn deleteMedium(self: *MediaList, medium: []const u8) void {
    const trimmed = std.mem.trim(u8, medium, &std.ascii.whitespace);
    var i: usize = 0;
    while (i < self._items.items.len) {
        if (std.ascii.eqlIgnoreCase(self._items.items[i], trimmed)) {
            _ = self._items.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn toString(self: *const MediaList, frame: *Frame) ![]const u8 {
    return self.getMediaText(frame);
}

// Chrome's MediaList.prototype has no keys/values/entries of its own, only
// Symbol.iterator, so this stays unexposed and only feeds `symbol_iterator`.
pub fn values(self: *MediaList, exec: *js.Execution) !*ValueIterator {
    return .init(.{ .list = self }, exec);
}

const Iterator = struct {
    index: u32 = 0,
    list: *MediaList,

    const Entry = struct { u32, []const u8 };

    pub fn next(self: *Iterator, _: *js.Execution) ?Entry {
        const index = self.index;
        const value = self.list.item(index) orelse return null;
        self.index = index + 1;
        return .{ index, value };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const ValueIterator = GenericIterator(Iterator, "1");

/// Split on commas that are not inside parentheses, quotes or a url() token.
/// `screen and (min-width: 1px), print` is two queries, not three.
fn splitTopLevel(text: []const u8) TopLevelSplitter {
    return .{ ._text = text };
}

const TopLevelSplitter = struct {
    _text: []const u8,
    _pos: usize = 0,

    fn next(self: *TopLevelSplitter) ?[]const u8 {
        if (self._pos > self._text.len) return null;
        const start = self._pos;
        var depth: usize = 0;
        var quote: ?u8 = null;
        var i = start;
        while (i < self._text.len) : (i += 1) {
            const c = self._text[i];
            if (quote) |q| {
                if (c == '\\') {
                    i += 1;
                } else if (c == q) {
                    quote = null;
                }
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '(' => depth += 1,
                ')' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => if (depth == 0) {
                    self._pos = i + 1;
                    return std.mem.trim(u8, self._text[start..i], &std.ascii.whitespace);
                },
                else => {},
            }
        }
        self._pos = self._text.len + 1;
        return std.mem.trim(u8, self._text[start..], &std.ascii.whitespace);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaList);

    pub const Meta = struct {
        pub const name = "MediaList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(MediaList.getLength, null, .{});
    pub const mediaText = bridge.accessor(MediaList.getMediaText, MediaList.setMediaText, .{});
    pub const appendMedium = bridge.function(MediaList.appendMedium, .{});
    pub const deleteMedium = bridge.function(MediaList.deleteMedium, .{});
    pub const item = bridge.function(MediaList.item, .{});
    pub const toString = bridge.function(MediaList.toString, .{});
    pub const @"[]" = bridge.indexed(MediaList.item, getIndexes, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(MediaList.values, .{});

    /// The indices are own properties, as in CSSRuleList -- see the note there.
    /// Chrome stringifies a two-medium list as `{"0":"screen","1":"print"}`.
    fn getIndexes(self: *MediaList, exec: *const js.Execution) !js.Array {
        const len = self.getLength();
        var arr = exec.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};
