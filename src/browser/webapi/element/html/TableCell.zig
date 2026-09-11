const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const TableCell = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableCell) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableCell) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableCell);

    pub const Meta = struct {
        pub const name = "HTMLTableCellElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableCell);

    // Chrome's order.
    pub const colSpan = reflect.unsignedLong("colspan", .{ .default = 1, .clamp = .{ .min = 1, .max = 1000 } });
    pub const rowSpan = reflect.unsignedLong("rowspan", .{ .default = 1, .clamp = .{ .min = 0, .max = 65534 } });
    pub const headers = reflect.string("headers");

    /// Position among the cells of the cell's own row, -1 for a cell with no
    /// row (measured: the second <td> of a row answers 1, a detached one -1).
    pub const cellIndex = bridge.accessor(_cellIndex, null, .{});
    fn _cellIndex(self: *TableCell) i32 {
        const node = self.asNode();
        const parent = node._parent orelse return -1;
        const element = parent.is(Element) orelse return -1;
        if (element.is(HtmlElement.TableRow) == null) {
            return -1;
        }
        var index: i32 = 0;
        var child_it = parent.childrenIterator();
        while (child_it.next()) |child| {
            const child_element = child.is(Element) orelse continue;
            if (child_element.is(TableCell) == null) {
                continue;
            }
            if (child == node) {
                return index;
            }
            index += 1;
        }
        return -1;
    }

    pub const @"align" = reflect.string("align");
    pub const axis = reflect.string("axis");
    pub const height = reflect.string("height");
    pub const width = reflect.string("width");
    pub const ch = reflect.string("char");
    pub const chOff = reflect.string("charoff");
    pub const noWrap = reflect.boolean("nowrap");
    pub const vAlign = reflect.string("valign");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const abbr = reflect.string("abbr");
    pub const scope = reflect.enumerated("scope", &.{ "row", "col", "rowgroup", "colgroup" }, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TableCell" {
    try testing.htmlRunner("element/html/tablecell.html", .{});
}
