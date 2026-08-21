// `<selectedcontent>`: the slot inside a customisable <select>'s button that the
// selected <option>'s content is projected into. Chrome 151 maps the tag and
// exposes the interface; this engine answered HTMLUnknownElement for both.
//
// The prototype carries nothing but `constructor` (measured, probe-shapes), and
// nothing here projects a selection, so the tag mapping is the whole surface.

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const SelectedContent = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *SelectedContent) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asNode(self: *SelectedContent) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SelectedContent);

    pub const Meta = struct {
        pub const name = "HTMLSelectedContentElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

const testing = @import("../../../../testing.zig");
test "WebApi: SurfaceElements" {
    try testing.htmlRunner("element/html/surface_elements.html", .{});
}
