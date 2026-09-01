const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TableCaption = @import("TableCaption.zig");
const TableSection = @import("TableSection.zig");
const collections = @import("../../collections.zig");

const Table = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Table) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Table) *Node {
    return self.asElement().asNode();
}

pub fn getTBodies(self: *Table, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .table_bodies, .name = "" },
        collections.NodeLive(.child_tag).init(root, .tbody, frame).htmlCollectionValue(),
    );
}

// thead rows, then the rows parented by the table or a tbody, then tfoot rows.
// The ordering lives in TreeWalker.TableRows, next to the reason it cannot be
// a plain tree walk.
pub fn getRows(self: *Table, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .table_rows, .name = "" },
        collections.NodeLive(.table_rows).init(root, {}, frame).htmlCollectionValue(),
    );
}

// The caption/thead/tfoot trio. Each is "the first child of that kind, in tree
// order", and each has a create-or-return, a delete-if-present and a setter
// that replaces. The three differ only in where a fresh one is put:
//
//   caption -> first child of the table
//   thead   -> before the first child that is neither a caption nor a colgroup
//   tfoot   -> last child of the table
//
// The setters are not [CEReactions]-free: replacing means removing the old
// one, which is a mutation of its own.

fn firstChildOfKind(self: *Table, comptime T: type) ?*T {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse continue;
        if (element.is(T)) |match| {
            return match;
        }
    }
    return null;
}

fn firstSectionOfTag(self: *Table, tag: Element.Tag) ?*TableSection {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse continue;
        if (element.getTag() != tag) continue;
        if (element.is(TableSection)) |section| {
            return section;
        }
    }
    return null;
}

fn removeChildNode(self: *Table, node: *Node, frame: *Frame) !void {
    _ = try self.asNode().removeChild(node, frame);
}

pub fn getCaption(self: *Table) ?*TableCaption {
    return self.firstChildOfKind(TableCaption);
}

pub fn setCaption(self: *Table, value: ?*TableCaption, frame: *Frame) !void {
    if (self.getCaption()) |old| {
        try self.removeChildNode(old.asNode(), frame);
    }
    const caption = value orelse return;
    const self_node = self.asNode();
    _ = try self_node.insertBefore(caption.asNode(), self_node.firstChild(), frame);
}

pub fn createCaption(self: *Table, frame: *Frame) !*Node {
    if (self.getCaption()) |existing| {
        return existing.asNode();
    }
    const caption = try Frame.node_factory.createElementNS(frame, .html, "caption", null);
    const self_node = self.asNode();
    return self_node.insertBefore(caption, self_node.firstChild(), frame);
}

pub fn deleteCaption(self: *Table, frame: *Frame) !void {
    const caption = self.getCaption() orelse return;
    try self.removeChildNode(caption.asNode(), frame);
}

pub fn getTHead(self: *Table) ?*TableSection {
    return self.firstSectionOfTag(.thead);
}

pub fn setTHead(self: *Table, value: ?*TableSection, frame: *Frame) !void {
    if (value) |section| {
        if (section.asElement().getTag() != .thead) {
            // Chrome's own sentence, measured: a *section* of the wrong kind
            // is a HierarchyRequestError with this text, while a non-section
            // is the bridge's stock "Failed to convert value to
            // 'HTMLTableSectionElement'" TypeError.
            return frame.js.fail(error.HierarchyError, "Failed to set the 'tHead' property on 'HTMLTableElement': Not a thead element.");
        }
    }
    if (self.getTHead()) |old| {
        try self.removeChildNode(old.asNode(), frame);
    }
    const section = value orelse return;
    _ = try self.asNode().insertBefore(section.asNode(), self.headInsertionPoint(), frame);
}

// "Immediately before the first element that is neither a caption nor a
// colgroup", which for a table whose only children are those two is the end.
fn headInsertionPoint(self: *Table) ?*Node {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse return child;
        switch (element.getTag()) {
            .caption, .colgroup => {},
            else => return child,
        }
    }
    return null;
}

pub fn createTHead(self: *Table, frame: *Frame) !*Node {
    if (self.getTHead()) |existing| {
        return existing.asNode();
    }
    const thead = try Frame.node_factory.createElementNS(frame, .html, "thead", null);
    return self.asNode().insertBefore(thead, self.headInsertionPoint(), frame);
}

pub fn deleteTHead(self: *Table, frame: *Frame) !void {
    const thead = self.getTHead() orelse return;
    try self.removeChildNode(thead.asNode(), frame);
}

pub fn getTFoot(self: *Table) ?*TableSection {
    return self.firstSectionOfTag(.tfoot);
}

pub fn setTFoot(self: *Table, value: ?*TableSection, frame: *Frame) !void {
    if (value) |section| {
        if (section.asElement().getTag() != .tfoot) {
            return frame.js.fail(error.HierarchyError, "Failed to set the 'tFoot' property on 'HTMLTableElement': Not a tfoot element.");
        }
    }
    if (self.getTFoot()) |old| {
        try self.removeChildNode(old.asNode(), frame);
    }
    const section = value orelse return;
    _ = try self.asNode().appendChild(section.asNode(), frame);
}

pub fn createTFoot(self: *Table, frame: *Frame) !*Node {
    if (self.getTFoot()) |existing| {
        return existing.asNode();
    }
    const tfoot = try Frame.node_factory.createElementNS(frame, .html, "tfoot", null);
    return self.asNode().appendChild(tfoot, frame);
}

pub fn deleteTFoot(self: *Table, frame: *Frame) !void {
    const tfoot = self.getTFoot() orelse return;
    try self.removeChildNode(tfoot.asNode(), frame);
}

// Unlike the other three there is no getter and no delete: a table may hold
// any number of tbodies, so this only ever appends one, immediately after the
// last one already there.
pub fn createTBody(self: *Table, frame: *Frame) !*Node {
    const tbody = try Frame.node_factory.createElementNS(frame, .html, "tbody", null);
    const self_node = self.asNode();

    var last: ?*Node = null;
    var it = self_node.childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse continue;
        if (element.getTag() == .tbody) {
            last = child;
        }
    }
    return self_node.insertBefore(tbody, if (last) |l| l.nextSibling() else null, frame);
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

    // Chrome's own-property order (measured), which puts the three section
    // accessors first and the presentational reflections in IDL order rather
    // than the reverse order they were declared in here.
    const reflect = Element.Reflect(Table);
    pub const caption = bridge.accessor(Table.getCaption, Table.setCaption, .{ .ce_reactions = true });
    pub const tHead = bridge.accessor(Table.getTHead, Table.setTHead, .{ .ce_reactions = true });
    pub const tFoot = bridge.accessor(Table.getTFoot, Table.setTFoot, .{ .ce_reactions = true });
    pub const tBodies = bridge.accessor(Table.getTBodies, null, .{});
    pub const rows = bridge.accessor(Table.getRows, null, .{});
    pub const @"align" = reflect.string("align");
    pub const border = reflect.string("border");
    pub const frame = reflect.string("frame");
    pub const rules = reflect.string("rules");
    pub const summary = reflect.string("summary");
    pub const width = reflect.string("width");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const cellPadding = reflect.stringNullToEmpty("cellpadding");
    pub const cellSpacing = reflect.stringNullToEmpty("cellspacing");
    pub const createCaption = bridge.function(Table.createCaption, .{ .ce_reactions = true });
    pub const createTBody = bridge.function(Table.createTBody, .{ .ce_reactions = true });
    pub const createTFoot = bridge.function(Table.createTFoot, .{ .ce_reactions = true });
    pub const createTHead = bridge.function(Table.createTHead, .{ .ce_reactions = true });
    pub const deleteCaption = bridge.function(Table.deleteCaption, .{ .ce_reactions = true });
    pub const deleteRow = bridge.function(Table.deleteRow, .{ .ce_reactions = true });
    pub const deleteTFoot = bridge.function(Table.deleteTFoot, .{ .ce_reactions = true });
    pub const deleteTHead = bridge.function(Table.deleteTHead, .{ .ce_reactions = true });
    pub const insertRow = bridge.function(Table.insertRow, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
