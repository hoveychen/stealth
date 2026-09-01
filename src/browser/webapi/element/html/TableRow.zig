const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const table_insert = @import("table_insert.zig");
const TreeWalker = @import("../../TreeWalker.zig");

const TableRow = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableRow) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableRow) *Node {
    return self.asElement().asNode();
}

pub fn getCells(self: *TableRow, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .row_cells, .name = "" },
        collections.NodeLive(.cells).init(root, {}, frame).htmlCollectionValue(),
    );
}

pub fn insertCell(self: *TableRow, index_: ?i32, frame: *Frame) !*Node {
    return table_insert.insertAt(self.asNode(), .cell, index_ orelse -1, frame);
}

/// Removes the cell at `index`, or the last one for -1. Out of range is an
/// IndexSizeError, except that -1 on a cell-less row is a no-op -- the same
/// shape HTMLTableElement.deleteRow already has.
pub fn deleteCell(self: *TableRow, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }
    const cells = try self.getCells(frame);
    const len: i32 = @intCast(cells.length(frame));
    const at = if (index == -1) len - 1 else index;
    if (at < 0 or at >= len) {
        if (index == -1) {
            return;
        }
        return error.IndexSizeError;
    }
    const cell = cells.getAtIndex(@intCast(at), frame) orelse return error.IndexSizeError;
    const node = cell.asNode();
    _ = try node.parentNode().?.removeChild(node, frame);
}

// Position in the *table's* rows, which is the spec-ordered collection, not
// the document order -- a tfoot row authored before the tbody still indexes
// after it. -1 when the row has no table.
pub fn getRowIndex(self: *TableRow) i32 {
    const node = self.asNode();
    const table = tableOf(node) orelse return -1;
    var walker = TreeWalker.TableRows.init(table, .{});
    var index: i32 = 0;
    while (walker.next()) |row| : (index += 1) {
        if (row == node) {
            return index;
        }
    }
    return -1;
}

// Position among the rows of the row's own section. A row parented directly by
// the table has no section, and Chrome answers -1 for it.
pub fn getSectionRowIndex(self: *TableRow) i32 {
    const node = self.asNode();
    const parent = node._parent orelse return -1;
    const section = parent.is(Element) orelse return -1;
    switch (section.getTag()) {
        .thead, .tbody, .tfoot => {},
        else => return -1,
    }
    var index: i32 = 0;
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse continue;
        if (element.getTag() != .tr) {
            continue;
        }
        if (child == node) {
            return index;
        }
        index += 1;
    }
    return -1;
}

// The row's table: its section's parent, or its own parent when the row hangs
// off the table directly.
fn tableOf(node: *Node) ?*Node {
    const parent = node._parent orelse return null;
    const element = parent.is(Element) orelse return null;
    return switch (element.getTag()) {
        .table => parent,
        .thead, .tbody, .tfoot => blk: {
            const grand = parent._parent orelse break :blk null;
            const grand_element = grand.is(Element) orelse break :blk null;
            break :blk if (grand_element.getTag() == .table) grand else null;
        },
        else => null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableRow);

    pub const Meta = struct {
        pub const name = "HTMLTableRowElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableRow);

    // Chrome's order.
    pub const rowIndex = bridge.accessor(TableRow.getRowIndex, null, .{});
    pub const sectionRowIndex = bridge.accessor(TableRow.getSectionRowIndex, null, .{});
    pub const cells = bridge.accessor(TableRow.getCells, null, .{});
    pub const @"align" = reflect.string("align");
    pub const ch = reflect.string("char");
    pub const chOff = reflect.string("charoff");
    pub const vAlign = reflect.string("valign");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const deleteCell = bridge.function(TableRow.deleteCell, .{ .ce_reactions = true });
    pub const insertCell = bridge.function(TableRow.insertCell, .{ .ce_reactions = true });
};
