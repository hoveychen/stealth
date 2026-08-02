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

//! SVGNumberList: the live view over a whitespace/comma separated list of
//! numbers in an attribute (feColorMatrix values, feConvolveMatrix
//! kernelMatrix, the transfer functions' tableValues, text rotate).
//!
//! Built on the same reflected-list machinery as SVGPointList, so the items
//! are live: writing SVGNumber.value rewrites the whole attribute. Measured on
//! Chrome 150 — `values="1 2 3"` then `getItem(1).value = 9` leaves the
//! attribute at "1 9 3", and a single malformed token empties the list.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const Number = @import("Number.zig");
const reflected_list = @import("reflected_list.zig");

const NumberList = @This();

_frame: *Frame,
_element: *Element,
_attr_name: lp.String,
_read_only: bool,
_synced: bool = false,
_snapshot: std.ArrayList(u8) = .empty,
_items: std.ArrayList(*Number) = .empty,
_retired: std.ArrayList(*Number) = .empty,

const M = reflected_list.Mixin(NumberList, Number, .{
    .attrName = attrName,
    .parse = parse,
    .writeItem = writeItem,
    .prepareItem = prepareItem,
    .attach = attach,
    .detachItem = detachItem,
    .releaseItem = releaseItem,
});

pub const Kind = enum {
    color_matrix_values,
    kernel_matrix,
    table_values,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .color_matrix_values => .wrap("values"),
            .kernel_matrix => .wrap("kernelMatrix"),
            .table_values => .wrap("tableValues"),
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
    animated: bool,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *NumberList);

pub fn getOrCreate(element: *Element, kind: Kind, animated: bool, frame: *Frame) !*NumberList {
    const key: Key = .{ .element = element, .kind = kind, .animated = animated };
    const gop = try frame._svg_number_lists.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_number_lists.remove(key);
        gop.value_ptr.* = try frame._factory.create(NumberList{
            ._frame = frame,
            ._element = element,
            ._attr_name = kind.attributeName(),
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

fn attrName(self: *const NumberList) lp.String {
    return self._attr_name;
}

// An SVGNumber that already belongs to a list is copied rather than moved,
// which is what SVGPointList does and what Chrome does.
fn prepareItem(_: *NumberList, item: *Number, frame: *Frame) !*Number {
    if (!std.math.isFinite(item._value)) return error.TypeError;
    const prepared = if (item.isAttached())
        try Number.create(item._value, frame._page)
    else
        item;
    prepared.acquireRef();
    return prepared;
}

fn attach(self: *NumberList, item: *Number) void {
    item.attach(.{
        .owner = self,
        .mutate = NumberList.mutateItem,
    }, self._read_only);
}

fn detachItem(item: *Number, owner: *NumberList) void {
    item.detach(owner);
}

fn releaseItem(item: *Number, page: *Page) void {
    item.releaseRef(page);
}

fn mutateItem(context: *anyopaque, item: *Number, value: f32) anyerror!void {
    const self: *NumberList = @ptrCast(@alignCast(context));
    const frame = self._frame;
    try M.sync(self, frame);

    // An external attribute mutation detaches the old item during sync. The
    // caller still owns that SVGNumber, but it no longer drives the list.
    if (!item.isAttachedTo(self)) {
        item.setValueRaw(value);
        return;
    }

    const index = for (self._items.items, 0..) |candidate, i| {
        if (candidate == item) break i;
    } else unreachable;

    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (self._items.items, 0..) |candidate, i| {
        if (i != 0) try writer.writeByte(' ');
        try writer.print("{d}", .{if (i == index) value else candidate._value});
    }
    try M.commitAttribute(self, serialized.written(), frame);
    item.setValueRaw(value);
}

// A list of numbers separated by whitespace and/or a single comma. Chrome
// throws the whole attribute away when any token is malformed.
fn parse(raw: []const u8, frame: *Frame) !std.ArrayList(*Number) {
    var parsed: std.ArrayList(*Number) = .empty;
    errdefer for (parsed.items) |item| item.releaseRef(frame._page);

    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c,");
    while (it.next()) |token| {
        const value = std.fmt.parseFloat(f32, token) catch return error.SyntaxError;
        if (!std.math.isFinite(value)) return error.SyntaxError;
        const number = try Number.create(value, frame._page);
        number.acquireRef();
        parsed.append(frame.local_arena, number) catch |err| {
            number.releaseRef(frame._page);
            return err;
        };
    }
    return parsed;
}

fn writeItem(item: *Number, writer: *std.Io.Writer) !void {
    try writer.print("{d}", .{item._value});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NumberList);

    pub const Meta = struct {
        pub const name = "SVGNumberList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(NumberList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(NumberList.getNumberOfItems, null, .{});
    pub const appendItem = bridge.function(NumberList.appendItem, .{});
    pub const clear = bridge.function(NumberList.clear, .{});
    pub const getItem = bridge.function(NumberList.getItem, .{});
    pub const initialize = bridge.function(NumberList.initialize, .{});
    pub const insertItemBefore = bridge.function(NumberList.insertItemBefore, .{});
    pub const removeItem = bridge.function(NumberList.removeItem, .{});
    pub const replaceItem = bridge.function(NumberList.replaceItem, .{});
};
