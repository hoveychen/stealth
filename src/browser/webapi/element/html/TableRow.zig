const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const table_insert = @import("table_insert.zig");

const TableRow = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *TableRow) *Element {
    return self._proto._proto;
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableRow);

    pub const Meta = struct {
        pub const name = "HTMLTableRowElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cells = bridge.accessor(TableRow.getCells, null, .{});
    pub const insertCell = bridge.function(TableRow.insertCell, .{ .ce_reactions = true });
};
