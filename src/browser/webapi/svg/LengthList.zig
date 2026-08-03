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

//! SVGLengthList: the live view over the x / y / dx / dy attributes of a text
//! positioning element, built on the same reflected-list machinery as
//! SVGPointList and SVGNumberList.
//!
//! Measured on Chrome 150: the items keep their units (`x="1px 2em"` gives
//! unit types 5 and 3), a single malformed token empties the whole list, and
//! appendItem copies its argument even when that argument is a fresh
//! createSVGLength() — unlike SVGNumberList, which only copies an item that
//! already belongs to a list.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const Length = @import("Length.zig");
const reflected_list = @import("reflected_list.zig");

const LengthList = @This();

_frame: *Frame,
_element: *Element,
_kind: Kind,
_read_only: bool,
_synced: bool = false,
_snapshot: std.ArrayList(u8) = .empty,
_items: std.ArrayList(*Length) = .empty,
_retired: std.ArrayList(*Length) = .empty,

const M = reflected_list.Mixin(LengthList, Length, .{
    .attrName = attrName,
    .parse = parse,
    .writeItem = writeItem,
    .prepareItem = prepareItem,
    .attach = attach,
    .detachItem = detachItem,
    .releaseItem = releaseItem,
});

pub const Kind = enum {
    x,
    y,
    dx,
    dy,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .x => .wrap("x"),
            .y => .wrap("y"),
            .dx => .wrap("dx"),
            .dy => .wrap("dy"),
        };
    }

    fn direction(self: Kind) Length.Direction {
        return switch (self) {
            .x, .dx => .horizontal,
            .y, .dy => .vertical,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
    animated: bool,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *LengthList);

pub fn getOrCreate(element: *Element, kind: Kind, animated: bool, frame: *Frame) !*LengthList {
    const key: Key = .{ .element = element, .kind = kind, .animated = animated };
    const gop = try frame._svg_length_lists.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_length_lists.remove(key);
        gop.value_ptr.* = try frame._factory.create(LengthList{
            ._frame = frame,
            ._element = element,
            ._kind = kind,
            ._read_only = animated,
        });
    }
    return gop.value_ptr.*;
}

pub const deinit = M.deinit;
pub const getLength = M.getLength;
pub const getNumberOfItems = M.getNumberOfItems;
pub const clear = M.clear;
pub const initialize = M.initialize;
pub const getItem = M.getItem;
pub const insertItemBefore = M.insertItemBefore;
pub const replaceItem = M.replaceItem;
pub const removeItem = M.removeItem;
pub const appendItem = M.appendItem;

fn attrName(self: *const LengthList) lp.String {
    return self._kind.attributeName();
}

fn prepareItem(self: *LengthList, item: *Length, frame: *Frame) !*Length {
    const copy = try Length.listItem(
        self._element,
        self._kind.direction(),
        item.rawValue(),
        item.rawUnit(),
        frame,
    );
    copy.acquireRef();
    return copy;
}

fn attach(self: *LengthList, item: *Length) void {
    item.attach(.{
        .owner = self,
        .mutate = LengthList.mutateItem,
    }, self._read_only);
}

fn detachItem(item: *Length, owner: *LengthList) void {
    item.detach(owner);
}

fn releaseItem(item: *Length, page: *Page) void {
    item.releaseRef(page);
}

// The item has already written its new value into its own fields; all that is
// left is to put the whole list back into the attribute.
fn mutateItem(context: *anyopaque, item: *Length) anyerror!void {
    const self: *LengthList = @ptrCast(@alignCast(context));
    const frame = self._frame;

    // An external attribute mutation detaches the old item during sync. The
    // caller still owns that SVGLength, but it no longer drives the list.
    if (!item.isAttachedTo(self)) {
        return;
    }
    try M.setAttribute(self, self._items.items, frame);
}

fn parse(self: *LengthList, raw: []const u8, frame: *Frame) !std.ArrayList(*Length) {
    var parsed: std.ArrayList(*Length) = .empty;
    errdefer for (parsed.items) |item| item.releaseRef(frame._page);

    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c,");
    while (it.next()) |token| {
        const value = Length.parseValue(token) catch return error.SyntaxError;
        const item = try Length.listItem(
            self._element,
            self._kind.direction(),
            value.value,
            value.unit,
            frame,
        );
        item.acquireRef();
        parsed.append(frame.local_arena, item) catch |err| {
            item.releaseRef(frame._page);
            return err;
        };
    }
    return parsed;
}

fn writeItem(item: *Length, writer: *std.Io.Writer) !void {
    try item.writeTo(writer);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(LengthList);

    pub const Meta = struct {
        pub const name = "SVGLengthList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(LengthList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(LengthList.getNumberOfItems, null, .{});
    pub const appendItem = bridge.function(LengthList.appendItem, .{});
    pub const clear = bridge.function(LengthList.clear, .{});
    pub const getItem = bridge.function(LengthList.getItem, .{});
    pub const initialize = bridge.function(LengthList.initialize, .{});
    pub const insertItemBefore = bridge.function(LengthList.insertItemBefore, .{});
    pub const removeItem = bridge.function(LengthList.removeItem, .{});
    pub const replaceItem = bridge.function(LengthList.replaceItem, .{});
};
