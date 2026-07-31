const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const Table = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *Table) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Table) *Node {
    return self.asElement().asNode();
}

pub fn getTBodies(self: *Table, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tbody, frame);
}

pub fn deleteRow(self: *Table, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }
    var scan: RowScan = .{ .index = index };
    const row = self.findRow(index, &scan) orelse {
        if (index == -1) {
            // deleteRow(-1) on a rowless table is a no-op.
            return;
        }
        return error.IndexSizeError;
    };
    _ = try row.parentNode().?.removeChild(row, frame);
}

pub fn insertRow(self: *Table, index_: ?i32, frame: *Frame) !*Node {
    const index = index_ orelse -1;
    if (index < -1) {
        return error.IndexSizeError;
    }

    var scan: RowScan = .{ .index = index };
    const at = self.findRow(index, &scan);
    // A full walk leaves scan.count holding the row total and scan.last the
    // last row in spec order; a hit short-circuits before either is complete,
    // but then the index is in range by construction.
    if (index >= 0 and at == null and index > scan.count) {
        return error.IndexSizeError;
    }

    const row = try Frame.node_factory.createElementNS(frame, .html, "tr", null);

    if (index >= 0) {
        if (at) |before| {
            _ = try before.parentNode().?.insertBefore(row, before, frame);
            return row;
        }
    }

    // index is -1 or exactly the row count: the new row goes next to the last
    // one, wherever that lives.
    if (scan.last) |last| {
        _ = try last.parentNode().?.appendChild(row, frame);
        return row;
    }

    // A table with no rows at all puts it in the last tbody, growing one if
    // the table hasn't got one yet.
    const self_node = self.asNode();
    var last_tbody: ?*Node = null;
    var it = self_node.childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse continue;
        if (element.getTag() == .tbody) {
            last_tbody = child;
        }
    }
    const section = last_tbody orelse blk: {
        const tbody = try Frame.node_factory.createElementNS(frame, .html, "tbody", null);
        break :blk try self_node.appendChild(tbody, frame);
    };
    _ = try section.appendChild(row, frame);
    return row;
}

// Finds the index-th row (or the last row for -1) in spec order: thead, tr,
// tbody then tfoot
fn findRow(self: *Table, index: i32, scan: *RowScan) ?*Node {
    if (self.scanSectionRows(.thead, scan)) |row| {
        return row;
    }

    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        switch (el.getTag()) {
            .tr => if (scan.check(child)) |row| {
                return row;
            },
            .tbody => if (scanChildRows(child, scan)) |row| {
                return row;
            },
            else => {},
        }
    }

    if (self.scanSectionRows(.tfoot, scan)) |row| {
        return row;
    }
    if (index == -1) {
        return scan.last;
    }
    return null;
}

const RowScan = struct {
    index: i32,
    count: i32 = 0,
    last: ?*Node = null,

    fn check(self: *RowScan, row: *Node) ?*Node {
        if (self.count == self.index) {
            return row;
        }
        self.count += 1;
        self.last = row;
        return null;
    }
};

fn scanSectionRows(self: *Table, tag: Element.Tag, scan: *RowScan) ?*Node {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() != tag) {
            continue;
        }
        if (scanChildRows(child, scan)) |row| {
            return row;
        }
    }
    return null;
}

fn scanChildRows(section: *Node, scan: *RowScan) ?*Node {
    var it = section.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() == .tr) {
            if (scan.check(child)) |row| {
                return row;
            }
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Table);

    pub const Meta = struct {
        pub const name = "HTMLTableElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const tBodies = bridge.accessor(Table.getTBodies, null, .{});
    pub const deleteRow = bridge.function(Table.deleteRow, .{ .ce_reactions = true });
    pub const insertRow = bridge.function(Table.insertRow, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
