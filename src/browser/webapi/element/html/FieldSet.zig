const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const ValidityState = @import("ValidityState.zig");
const barred_validation = @import("barred_validation.zig");
const collections = @import("../../collections.zig");

const FieldSet = @This();

pub const Proto = HtmlElement;

_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *FieldSet) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const FieldSet) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *FieldSet) *Node {
    return self.asElement().asNode();
}

// A fieldset is barred from constraint validation, so the whole API is the
// shared shape; see barred_validation.zig for the measured readings.
const validation = barred_validation.Mixin(FieldSet);
pub const getForm = validation.getForm;
pub const getWillValidate = validation.getWillValidate;
pub const getValidity = validation.getValidity;
pub const getValidationMessage = validation.getValidationMessage;
pub const checkValidity = validation.checkValidity;
pub const reportValidity = validation.reportValidity;
pub const setCustomValidity = validation.setCustomValidity;
pub const hasCustomValidity = validation.hasCustomValidity;

/// `type` is the tag name, fixed. Not a reflection: there is no content
/// attribute behind it.
pub fn getType(_: *const FieldSet) []const u8 {
    return "fieldset";
}

/// The listed elements among the fieldset's descendants. Chrome hands back a
/// plain `HTMLCollection`, not the `HTMLFormControlsCollection` the IDL names
/// (measured: `fs.elements.constructor.name` is `HTMLCollection`), and it is
/// live and the same object every time.
pub fn getElements(self: *FieldSet, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .fieldset_elements, .name = "" },
        collections.NodeLive(.fieldset).init(root, {}, frame).htmlCollectionValue(),
    );
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FieldSet);

    pub const Meta = struct {
        pub const name = "HTMLFieldSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(FieldSet);

    // Chrome's own-property order (measured).
    pub const disabled = reflect.boolean("disabled");
    pub const form = bridge.accessor(FieldSet.getForm, null, .{});
    pub const name = reflect.string("name");
    pub const @"type" = bridge.accessor(FieldSet.getType, null, .{});
    pub const elements = bridge.accessor(FieldSet.getElements, null, .{});
    pub const willValidate = bridge.accessor(FieldSet.getWillValidate, null, .{});
    pub const validity = bridge.accessor(FieldSet.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(FieldSet.getValidationMessage, null, .{});
    pub const checkValidity = bridge.function(FieldSet.checkValidity, .{});
    pub const reportValidity = bridge.function(FieldSet.reportValidity, .{});
    pub const setCustomValidity = bridge.function(FieldSet.setCustomValidity, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.FieldSet" {
    try testing.htmlRunner("element/html/fieldset.html", .{});
}
