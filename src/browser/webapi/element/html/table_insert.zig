const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");

// The index half of HTML's table insertion model, shared by
// HTMLTableSectionElement.insertRow and HTMLTableRowElement.insertCell. Both
// count only their own kind of child, so a stray <div> sitting between two
// rows is invisible to the index; -1 and "one past the last match" append,
// an in-range index inserts before whatever currently holds it, and anything
// else is an IndexSizeError.
pub const Kind = enum {
    row,
    cell,

    fn tagName(comptime self: Kind) []const u8 {
        return switch (self) {
            .row => "tr",
            .cell => "td",
        };
    }

    fn matches(comptime self: Kind, element: *Element) bool {
        return switch (self) {
            .row => element.getTag() == .tr,
            // A cell is a <td> or a <th>, both of which are TableCell.
            .cell => element.is(Element.Html.TableCell) != null,
        };
    }
};

pub fn insertAt(parent: *Node, comptime kind: Kind, index: i32, frame: *Frame) !*Node {
    if (index < -1) {
        return error.IndexSizeError;
    }

    var count: i32 = 0;
    var before: ?*Node = null;
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        const element = child.is(Element) orelse continue;
        if (kind.matches(element) == false) {
            continue;
        }
        if (count == index) {
            before = child;
        }
        count += 1;
    }

    if (index > count) {
        return error.IndexSizeError;
    }

    const node = try Frame.node_factory.createElementNS(frame, .html, comptime kind.tagName(), null);
    // insertBefore with a null reference appends, which is exactly the
    // index == -1 and index == count cases.
    _ = try parent.insertBefore(node, before, frame);
    return node;
}
