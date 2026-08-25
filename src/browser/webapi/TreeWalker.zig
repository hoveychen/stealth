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

const Node = @import("Node.zig");
const Element = @import("Element.zig");

pub const Full = TreeWalker(.full);
pub const FullExcludeSelf = TreeWalker(.exclude_self);
pub const Children = TreeWalker(.children);

// A table's rows are not a tree-order walk, which is why this cannot be a mode
// of the generic walker above: the spec groups them thead-first, then the rows
// parented by the table itself or a tbody, then tfoot, each group in tree
// order. Authoring the sections out of order is legal -- HTML4 *required*
// tfoot before tbody -- so on a table written that way a tree-order walk and
// this one disagree, and Chrome follows the grouping (measured against a headed
// Chrome 151 on a table with tfoot, tbody, thead in that source order).
// https://html.spec.whatwg.org/#dom-table-rows
pub const TableRows = struct {
    _root: *Node,
    // The next child of the table to look at, in the current phase.
    _child: ?*Node,
    // The next row to hand out from the section we are currently inside.
    _row: ?*Node,
    _phase: Phase,

    const Self = @This();
    const Opts = struct {};

    const Phase = enum { head, body, foot, done };

    pub fn init(root: *Node, opts: Opts) Self {
        _ = opts;
        return .{ ._root = root, ._child = root.firstChild(), ._row = null, ._phase = .head };
    }

    pub fn next(self: *Self) ?*Node {
        while (true) {
            if (self._row) |row| {
                self._row = nextRow(row.nextSibling());
                return row;
            }
            const child = self._child orelse {
                switch (self._phase) {
                    .head => self._phase = .body,
                    .body => self._phase = .foot,
                    .foot, .done => {
                        self._phase = .done;
                        return null;
                    },
                }
                self._child = self._root.firstChild();
                continue;
            };
            self._child = child.nextSibling();
            const element = child.is(Element) orelse continue;
            switch (self._phase) {
                .head => if (element.getTag() == .thead) {
                    self._row = nextRow(child.firstChild());
                },
                .body => switch (element.getTag()) {
                    .tr => return child,
                    .tbody => self._row = nextRow(child.firstChild()),
                    else => {},
                },
                .foot => if (element.getTag() == .tfoot) {
                    self._row = nextRow(child.firstChild());
                },
                .done => return null,
            }
        }
    }

    pub fn reset(self: *Self) void {
        self._child = self._root.firstChild();
        self._row = null;
        self._phase = .head;
    }

    // A row is in the collection when the table owns it directly or through one
    // of its own section children -- a nested table's rows are not.
    pub fn contains(self: *const Self, target: *const Node) bool {
        const element = @constCast(target).is(Element) orelse return false;
        if (element.getTag() != .tr) {
            return false;
        }
        const parent = target._parent orelse return false;
        if (parent == self._root) {
            return true;
        }
        const section = parent.is(Element) orelse return false;
        return switch (section.getTag()) {
            .thead, .tbody, .tfoot => parent._parent == self._root,
            else => false,
        };
    }

    pub fn clone(self: *const Self) Self {
        return init(self._root, .{});
    }

    fn nextRow(from: ?*Node) ?*Node {
        var node = from;
        while (node) |candidate| : (node = candidate.nextSibling()) {
            const element = candidate.is(Element) orelse continue;
            if (element.getTag() == .tr) {
                return candidate;
            }
        }
        return null;
    }
};

const Mode = enum {
    full,
    children,
    exclude_self,
};

pub fn TreeWalker(comptime mode: Mode) type {
    return struct {
        _current: ?*Node = null,
        _next: ?*Node,
        _root: *Node,

        const Self = @This();
        const Opts = struct {};

        pub fn init(root: *Node, opts: Opts) Self {
            _ = opts;
            return .{
                ._next = firstNext(root),
                ._root = root,
            };
        }

        pub fn next(self: *Self) ?*Node {
            const node = self._next orelse return null;
            self._current = node;

            if (comptime mode == .children) {
                self._next = node.nextSibling();
                return node;
            }

            if (node.firstChild()) |child| {
                self._next = child;
            } else {
                var current: *Node = node;
                while (current != self._root) {
                    if (current.nextSibling()) |sibling| {
                        self._next = sibling;
                        return node;
                    }
                    current = current._parent orelse break;
                }
                self._next = null;
            }
            return node;
        }

        pub fn skipChildren(self: *Self) void {
            if (comptime mode == .children) return;
            const current_node = self._current orelse return;

            var current: *Node = current_node;
            while (current != self._root) {
                if (current.nextSibling()) |sibling| {
                    self._next = sibling;
                    return;
                }
                current = current._parent orelse break;
            }
            self._next = null;
        }

        pub fn reset(self: *Self) void {
            self._current = null;
            self._next = firstNext(self._root);
        }

        pub fn contains(self: *const Self, target: *const Node) bool {
            const root = self._root;

            if (comptime mode == .children) {
                var it = root.childrenIterator();
                while (it.next()) |child| {
                    if (child == target) {
                        return true;
                    }
                }
                return false;
            }

            var node = target;
            if ((comptime mode == .exclude_self) and node == root) {
                return false;
            }

            while (true) {
                if (node == root) {
                    return true;
                }
                node = node._parent orelse return false;
            }
        }

        pub fn clone(self: *const Self) Self {
            const root = self._root;
            return .{
                ._next = firstNext(root),
                ._root = root,
            };
        }

        fn firstNext(root: *Node) ?*Node {
            return switch (comptime mode) {
                .full => root,
                .exclude_self => root.firstChild(),
                .children => root.firstChild(),
            };
        }

        pub const Elements = struct {
            tw: Self,

            pub fn init(root: *Node, comptime opts: Opts) Elements {
                return .{
                    .tw = Self.init(root, opts),
                };
            }

            pub fn next(self: *Elements) ?*Element {
                while (self.tw.next()) |node| {
                    if (node.is(Element)) |el| {
                        return el;
                    }
                }
                return null;
            }

            pub fn reset(self: *Elements) void {
                self.tw.reset();
            }
        };
    };
}

test "TreeWalker: skipChildren" {
    const testing = @import("../../testing.zig");
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const doc = frame.window._document;

    // <div>
    //   <span>
    //     <b>A</b>
    //   </span>
    //   <p>B</p>
    // </div>
    const div = try doc.createElement("div", null, frame);
    const span = try doc.createElement("span", null, frame);
    const b = try doc.createElement("b", null, frame);
    const p = try doc.createElement("p", null, frame);
    _ = try span.asNode().appendChild(b.asNode(), frame);
    _ = try div.asNode().appendChild(span.asNode(), frame);
    _ = try div.asNode().appendChild(p.asNode(), frame);

    var tw = Full.init(div.asNode(), .{});

    // root (div)
    try testing.expect(tw.next() == div.asNode());

    // span
    try testing.expect(tw.next() == span.asNode());

    // skip children of span (should jump over <b> to <p>)
    tw.skipChildren();
    try testing.expect(tw.next() == p.asNode());

    try testing.expect(tw.next() == null);
}
