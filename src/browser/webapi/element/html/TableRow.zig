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

pub fn getCells(self: *TableRow, frame: *Frame) collections.NodeLive(.cells) {
    return collections.NodeLive(.cells).init(self.asNode(), {}, frame);
}

pub fn insertCell(self: *TableRow, index_: ?i32, frame: *Frame) !*Node {
    return table_insert.insertAt(self.asNode(), .cell, index_ orelse -1, frame);
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
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const @"align" = reflect.string("align");

    pub const cells = bridge.accessor(TableRow.getCells, null, .{});
    pub const rowIndex = bridge.accessor(TableRow.getRowIndex, null, .{});
    pub const sectionRowIndex = bridge.accessor(TableRow.getSectionRowIndex, null, .{});
    pub const insertCell = bridge.function(TableRow.insertCell, .{ .ce_reactions = true });
};
