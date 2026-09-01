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

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const NodeLive = @import("node_live.zig").NodeLive;
const HTMLCollection = @import("HTMLCollection.zig");
const Execution = js.Execution;

const HTMLAllCollection = @This();

// Same as getElementsByTagName('*') with the only difference being the name
// lookup which exposes the name only for a fixed list of tags.
_nodes: NodeLive(.all_elements),

pub fn init(root: *Node, frame: *Frame) HTMLAllCollection {
    return .{ ._nodes = .init(root, {}, frame) };
}

pub fn length(self: *HTMLAllCollection, frame: *const Frame) u32 {
    return self._nodes.length(frame);
}

pub fn getAtIndex(self: *HTMLAllCollection, index: usize, frame: *const Frame) ?*Element {
    return self._nodes.getAtIndex(index, frame);
}

pub fn getByName(self: *HTMLAllCollection, name: []const u8, frame: *Frame) ?*Element {
    if (frame.getElementByIdFromNode(self._nodes._tw._root, name)) |el| {
        return el;
    }

    // Fall back to searching by name attribute. Walking a clone leaves the
    // indexed-access cursor alone.
    var tw = self._nodes._tw.clone();
    while (tw.next()) |node| {
        if (node.is(Element)) |el| {
            if (!isAllNamed(el)) {
                continue;
            }
            if (el.getAttributeSafe(comptime .wrap("name"))) |attr_name| {
                if (std.mem.eql(u8, attr_name, name)) {
                    return el;
                }
            }
        }
    }

    return null;
}

// Every element in the collection is exposed by its id, but only these are
// exposed by their name.
// https://html.spec.whatwg.org/multipage/dom.html#dom-document-all
pub fn isAllNamed(el: *Element) bool {
    if (el._namespace != .html) {
        return false;
    }
    return switch (el.getTag()) {
        .anchor, .button, .embed, .form, .frameset, .iframe, .img, .input, .map, .meta, .object, .select, .textarea => true,
        else => false,
    };
}

const CAllAsFunctionArg = union(enum) {
    index: u32,
    id: []const u8,
};
pub fn callable(self: *HTMLAllCollection, arg: CAllAsFunctionArg, frame: *Frame) ?*Element {
    return switch (arg) {
        .index => |i| self.getAtIndex(i, frame),
        .id => |id| self.getByName(id, frame),
    };
}

pub fn iterator(self: *HTMLAllCollection, exec: *const Execution) !*Iterator {
    return Iterator.init(.{
        .list = self,
        .tw = self._nodes._tw.clone(),
    }, exec);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    list: *HTMLAllCollection,
    tw: TreeWalker.FullExcludeSelf,

    pub fn next(self: *@This(), _: *const Execution) ?*Element {
        return self.list._nodes.nextTw(&self.tw);
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLAllCollection);

    pub const Meta = struct {
        pub const name = "HTMLAllCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;

        // This is a very weird class that requires special JavaScript behavior
        // this htmldda and callable are only used here..
        pub const htmldda = true;
        pub const callable = JsApi.callable;
    };

    pub const length = bridge.accessor(HTMLAllCollection.length, null, .{});
    pub const @"[int]" = bridge.indexed(HTMLAllCollection.getAtIndex, getIndexes, .{ .null_as_undefined = true });

    /// The indices are own properties, as in RadioNodeList -- see the note
    /// there.
    fn getIndexes(self: *HTMLAllCollection, frame: *Frame) !js.Array {
        const len = self.length(frame);
        var arr = frame.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }

    pub const @"[str]" = bridge.namedIndexed(getNamed, null, null, getNames, queryByName, .{ .null_as_undefined = true });

    // A name the document does not carry is not a property of `document.all`
    // at all: declining here is what keeps `'anything' in document.all` false,
    // since an interceptor that answers undefined has still answered.
    fn getNamed(self: *HTMLAllCollection, name: []const u8, frame: *Frame) !*Element {
        if (name.len == 0) {
            return error.NotHandled;
        }
        return HTMLAllCollection.getByName(self, name, frame) orelse error.NotHandled;
    }

    fn getNames(self: *HTMLAllCollection, frame: *Frame) !js.Array {
        return HTMLCollection.supportedNames(self, HTMLAllCollection.isAllNamed, frame);
    }

    // `document.all` is `[LegacyUnenumerableNamedProperties]` like
    // HTMLCollection: the ids and names belong in getOwnPropertyNames but not
    // in Object.keys, and they are configurable and read-only.
    fn queryByName(self: *HTMLAllCollection, name: []const u8, frame: *Frame) !u32 {
        if (name.len > 0 and HTMLAllCollection.getByName(self, name, frame) != null) {
            return js.v8.DontEnum | js.v8.ReadOnly;
        }
        return error.NotHandled;
    }

    pub const item = bridge.function(_item, .{});
    // `item(optional DOMString nameOrIndex)`: the argument is optional, so a
    // bare item() answers null rather than refusing (Chrome 151 reports
    // item.length === 0 and accepts the call).
    fn _item(self: *HTMLAllCollection, index_: ?i32, frame: *Frame) ?*Element {
        const index = index_ orelse return null;
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index), frame);
    }

    pub const namedItem = bridge.function(HTMLAllCollection.getByName, .{});
    pub const symbol_iterator = bridge.iterator(HTMLAllCollection.iterator, .{});

    pub const callable = bridge.callable(HTMLAllCollection.callable, .{ .null_as_undefined = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: HTMLAllCollection" {
    try testing.htmlRunner("collections/html_all_collection.html", .{});
}
