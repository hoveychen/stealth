const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Frame = @import("../../../Frame.zig");

const Legend = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Legend) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Legend) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Legend);

    pub const Meta = struct {
        pub const name = "HTMLLegendElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Legend);

    /// A legend's form is its *fieldset's* form, not its own nearest ancestor
    /// form: a legend outside a fieldset answers null even inside a form, and a
    /// legend in a fieldset in a form answers that form (measured).
    pub const form = bridge.accessor(_form, null, .{});
    fn _form(self: *Legend, frame: *Frame) ?*Form {
        var ancestor = self.asNode()._parent;
        while (ancestor) |node| : (ancestor = node._parent) {
            const element = node.is(Element) orelse continue;
            const fieldset = element.is(HtmlElement.FieldSet) orelse continue;
            return Form.ownerOf(fieldset.asElement(), frame);
        }
        return null;
    }

    pub const @"align" = reflect.string("align");
};
