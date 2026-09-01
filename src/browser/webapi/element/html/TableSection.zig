const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const table_insert = @import("table_insert.zig");

const String = lp.String;

const TableSection = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableSection) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableSection) *Node {
    return self.asElement().asNode();
}

pub fn getRows(self: *TableSection, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .section_rows, .name = "" },
        collections.NodeLive(.child_tag).init(root, .tr, frame).htmlCollectionValue(),
    );
}

pub fn insertRow(self: *TableSection, index_: ?i32, frame: *Frame) !*Node {
    return table_insert.insertAt(self.asNode(), .row, index_ orelse -1, frame);
}

/// The section's own half of HTMLTableElement.deleteRow: same rules, but over
/// this section's rows rather than the table's.
pub fn deleteRow(self: *TableSection, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }
    const rows = try self.getRows(frame);
    const len: i32 = @intCast(rows.length(frame));
    const at = if (index == -1) len - 1 else index;
    if (at < 0 or at >= len) {
        if (index == -1) {
            return;
        }
        return error.IndexSizeError;
    }
    const row = rows.getAtIndex(@intCast(at), frame) orelse return error.IndexSizeError;
    const node = row.asNode();
    _ = try node.parentNode().?.removeChild(node, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableSection);

    pub const Meta = struct {
        pub const name = "HTMLTableSectionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableSection);

    // Chrome's order.
    pub const rows = bridge.accessor(TableSection.getRows, null, .{});
    pub const @"align" = reflect.string("align");
    pub const ch = reflect.string("char");
    pub const chOff = reflect.string("charoff");
    pub const vAlign = reflect.string("valign");
    pub const deleteRow = bridge.function(TableSection.deleteRow, .{ .ce_reactions = true });
    pub const insertRow = bridge.function(TableSection.insertRow, .{ .ce_reactions = true });
};
