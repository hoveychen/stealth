const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const Window = @import("../../Window.zig");
const HtmlElement = @import("../Html.zig");
const ValidityState = @import("ValidityState.zig");
const barred_validation = @import("barred_validation.zig");

const Object = @This();

pub const Proto = HtmlElement;

_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Object) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Object) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Object) *Node {
    return self.asElement().asNode();
}

// An object is barred from constraint validation; see barred_validation.zig.
const validation = barred_validation.Mixin(Object);
pub const getForm = validation.getForm;
pub const getWillValidate = validation.getWillValidate;
pub const getValidity = validation.getValidity;
pub const getValidationMessage = validation.getValidationMessage;
pub const checkValidity = validation.checkValidity;
pub const reportValidity = validation.reportValidity;
pub const setCustomValidity = validation.setCustomValidity;
pub const hasCustomValidity = validation.hasCustomValidity;

/// An `<object>` gets a nested browsing context only when its `data` names a
/// resource the UA decided to render as a document, which this engine never
/// does -- it has no plugin host and no image/document dispatch on `<object>`.
/// So all three are null, which is also what Chrome answers for an `<object>`
/// with no `data`, attached or not (measured,
/// probes/expr-form-associated-barred.js). They exist for their shape: an
/// interstitial that walks `HTMLObjectElement.prototype` sees three names, not
/// three holes.
pub fn getContentDocument(_: *Object) ?*Document {
    return null;
}

pub fn getContentWindow(_: *Object) ?*Window {
    return null;
}

pub fn getSVGDocument(_: *Object) ?*Document {
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Object);

    pub const Meta = struct {
        pub const name = "HTMLObjectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own-property order (measured), which is IDL order rather than
    // the reverse-alphabetical run this file used to carry.
    const reflect = Element.Reflect(Object);
    pub const data = reflect.url("data");
    pub const @"type" = reflect.string("type");
    pub const name = reflect.string("name");
    pub const useMap = reflect.string("usemap");
    pub const form = bridge.accessor(Object.getForm, null, .{});
    pub const width = reflect.string("width");
    pub const height = reflect.string("height");
    pub const contentDocument = bridge.accessor(Object.getContentDocument, null, .{});
    pub const contentWindow = bridge.accessor(Object.getContentWindow, null, .{});
    pub const willValidate = bridge.accessor(Object.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Object.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Object.getValidationMessage, null, .{});
    pub const @"align" = reflect.string("align");
    pub const archive = reflect.string("archive");
    pub const code = reflect.string("code");
    pub const declare = reflect.boolean("declare");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const standby = reflect.string("standby");
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const codeBase = reflect.url("codebase");
    pub const codeType = reflect.string("codetype");
    pub const border = reflect.stringNullToEmpty("border");
    pub const checkValidity = bridge.function(Object.checkValidity, .{});
    pub const getSVGDocument = bridge.function(Object.getSVGDocument, .{});
    pub const reportValidity = bridge.function(Object.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Object.setCustomValidity, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Object" {
    try testing.htmlRunner("element/html/object.html", .{});
}
