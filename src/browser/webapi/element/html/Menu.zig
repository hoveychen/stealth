const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

// <menu>. One of G17's window keys, and the smallest of them: Chrome 150 gives
// HTMLMenuElement.prototype exactly one member besides `constructor` -- the
// deprecated `compact` boolean attribute (measured). The tag used to fall
// through to HTMLElement here, so the interface object was missing and every
// <menu> in a document was branded one level too high.

const Menu = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *Menu) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Menu) *Node {
    return self.asElement().asNode();
}

pub fn getCompact(self: *Menu) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("compact")) != null;
}

pub fn setCompact(self: *Menu, compact: bool, frame: *Frame) !void {
    if (compact) {
        try self.asElement().setAttributeSafe(comptime .wrap("compact"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("compact"), frame);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Menu);

    pub const Meta = struct {
        pub const name = "HTMLMenuElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const compact = bridge.accessor(Menu.getCompact, Menu.setCompact, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: legacy misc" {
    try testing.htmlRunner("legacy_misc.html", .{});
}
