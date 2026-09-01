// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;
const ValidityState = @import("ValidityState.zig");
const barred_validation = @import("barred_validation.zig");

const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const Output = @This();

pub const Proto = HtmlElement;

_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,
// The "default value override": null while the element is in default mode, in
// which case `defaultValue` reads the child text content like `value` does.
_default_override: ?[]const u8 = null,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Output) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Output) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Output) *Node {
    return self.asElement().asNode();
}

pub fn getLabels(self: *Output, frame: *Frame) !*collections.NodeList {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub fn getHtmlFor(self: *Output, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    if (element._namespace != .html) {
        return null;
    }
    return element.getTokenList(.@"for", frame);
}

/// `[PutForwards=value]`: the setter assigns to the DOMTokenList's `value`, so
/// the `for` content attribute moves and the list object stays the same one.
/// The point is the descriptor: with a setter it reads as an accessor, which is
/// what Chrome exposes and what a bot check reads. See
/// src/browser/tests/descriptor_kind.html.
pub fn setHtmlFor(self: *Output, value: lp.String, frame: *Frame) !void {
    const list = (try self.getHtmlFor(frame)) orelse return;
    try list.setValue(value, frame);
}

// An output is barred from constraint validation; see barred_validation.zig.
const validation = barred_validation.Mixin(Output);
pub const getForm = validation.getForm;
pub const getWillValidate = validation.getWillValidate;
pub const getValidity = validation.getValidity;
pub const getValidationMessage = validation.getValidationMessage;
pub const checkValidity = validation.checkValidity;
pub const reportValidity = validation.reportValidity;
pub const setCustomValidity = validation.setCustomValidity;
pub const hasCustomValidity = validation.hasCustomValidity;

pub fn getType(_: *const Output) []const u8 {
    return "output";
}

/// `value` is the child text content, always -- reading it never consults the
/// override. Writing it moves the element out of default mode, and the text
/// content it is displacing becomes the default. Measured on a headed Chrome
/// 151 (probes/expr-form-associated-barred.js):
///
/// | step | `value` | `defaultValue` | text |
/// |---|---|---|---|
/// | fresh | "" | "" | "" |
/// | `textContent = 'text'` | text | text | text |
/// | `defaultValue = 'dv'` | dv | dv | dv |
/// | `value = 'v'` | v | **dv** | v |
/// | `defaultValue = 'dv2'` | v | dv2 | v |
/// | `textContent = 'text2'` | text2 | dv2 | text2 |
pub fn getValue(self: *Output, frame: *Frame) ![]const u8 {
    return self.asNode().getTextContentAlloc(frame.local_arena);
}

pub fn setValue(self: *Output, value: []const u8, frame: *Frame) !void {
    if (self._default_override == null) {
        const current = try self.asNode().getTextContentAlloc(frame.local_arena);
        self._default_override = try frame.dupeString(current);
    }
    try self.asNode().setTextContent(value, frame);
}

pub fn getDefaultValue(self: *Output, frame: *Frame) ![]const u8 {
    if (self._default_override) |override| {
        return override;
    }
    return self.asNode().getTextContentAlloc(frame.local_arena);
}

pub fn setDefaultValue(self: *Output, value: []const u8, frame: *Frame) !void {
    if (self._default_override != null) {
        self._default_override = try frame.dupeString(value);
        return;
    }
    try self.asNode().setTextContent(value, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Output);

    pub const Meta = struct {
        pub const name = "HTMLOutputElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Output);

    // Chrome's own-property order (measured).
    pub const htmlFor = bridge.accessor(Output.getHtmlFor, Output.setHtmlFor, .{ .null_as_undefined = true, .ce_reactions = true });
    pub const form = bridge.accessor(Output.getForm, null, .{});
    pub const name = reflect.string("name");
    pub const @"type" = bridge.accessor(Output.getType, null, .{});
    pub const defaultValue = bridge.accessor(Output.getDefaultValue, Output.setDefaultValue, .{ .ce_reactions = true });
    pub const value = bridge.accessor(Output.getValue, Output.setValue, .{ .ce_reactions = true });
    pub const willValidate = bridge.accessor(Output.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Output.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Output.getValidationMessage, null, .{});
    pub const labels = bridge.accessor(Output.getLabels, null, .{});
    pub const checkValidity = bridge.function(Output.checkValidity, .{});
    pub const reportValidity = bridge.function(Output.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Output.setCustomValidity, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Output" {
    try testing.htmlRunner("element/html/output.html", .{});
}
