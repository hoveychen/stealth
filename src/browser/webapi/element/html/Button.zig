// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const std = @import("std");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Event = @import("../../Event.zig");
const ValidityState = @import("ValidityState.zig");

const popover = @import("../popover.zig");
const collections = @import("../../collections.zig");

const Button = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,
_popover_target: ?*Element = null,

pub fn asElement(self: *Button) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Button) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Button) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeInterned("type") orelse "submit";
}

pub fn getForm(self: *Button, frame: *Frame) ?*Form {
    return Form.ownerOf(self.asElement(), frame);
}

pub fn getLabels(self: *Button, frame: *Frame) !*collections.NodeList {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Form submission attribute overrides
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#form-submission-0
//
// Each `formX` IDL attribute reflects the matching `formx` content attribute and
// overrides the form-owner's value when this button is the submitter. Per spec
// these are "no missing value default" reflections — getters return "" when the
// content attribute is absent, so the `submitter.formX || form.X` idiom in
// downstream CDP clients (e.g. Turbo's FormSubmission constructor) falls
// through to the form's value.

pub fn getFormAction(self: *Button, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const owner_url = element.ownerFrame(frame).url;
    const action = element.getAttributeSafe(comptime .wrap("formaction")) orelse return owner_url;
    if (action.len == 0) {
        return owner_url;
    }
    return element.asNode().resolveURLReflect(action, frame, .{});
}

pub fn setFormAction(self: *Button, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formaction"), .wrap(value), frame);
}

pub fn getFormEnctype(self: *const Button) []const u8 {
    return Form.normalizeEnctype(self.asConstElement().getAttributeSafe(comptime .wrap("formenctype")), "");
}

pub fn setFormEnctype(self: *Button, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formenctype"), .wrap(value), frame);
}

pub fn getFormMethod(self: *const Button) []const u8 {
    return Form.normalizeMethod(self.asConstElement().getAttributeSafe(comptime .wrap("formmethod")), "");
}

pub fn setFormMethod(self: *Button, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formmethod"), .wrap(value), frame);
}

pub fn getFormNoValidate(self: *const Button) bool {
    return self.asConstElement().getAttributeSafe(.wrap("formnovalidate")) != null;
}

pub fn setFormNoValidate(self: *Button, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(.wrap("formnovalidate"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(.wrap("formnovalidate"), frame);
    }
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api
//
// Per spec, only buttons with type="submit" participate in constraint validation,
// and the only flag they can raise is customError. type="reset" and type="button"
// are barred from constraint validation entirely.

pub fn getWillValidate(self: *const Button) bool {
    if (self.asConstElement().isDisabled()) return false;
    return std.mem.eql(u8, self.getType(), "submit");
}

pub fn getValidity(self: *Button, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

pub fn getValidationMessage(self: *const Button) []const u8 {
    if (!self.getWillValidate()) return "";
    return self._custom_validity orelse "";
}

pub fn checkValidity(self: *Button, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    if (self._custom_validity == null) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *Button, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *Button, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const Button) bool {
    return self._custom_validity != null;
}

pub fn getPopoverTargetElement(self: *Button, frame: *Frame) ?*Element {
    return popover.invokerTarget(self.asNode(), self._popover_target, frame);
}

pub fn setPopoverTargetElement(self: *Button, value: ?*Element, frame: *Frame) !void {
    self._popover_target = value;
    if (value == null) {
        try self.asElement().removeAttribute(.wrap("popovertarget"), frame);
    } else {
        try self.asElement().setAttribute(.wrap("popovertarget"), .wrap(""), frame);
    }
}

pub fn getPopoverTargetAction(self: *Button) []const u8 {
    return @tagName(popover.getInvokerAction(self.asElement()));
}

pub fn setPopoverTargetAction(self: *Button, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttribute(.wrap("popovertargetaction"), .wrap(value), frame);
}

pub fn getDisabled(self: *const Button) bool {
    return self.asConstElement().getAttributeInterned("disabled") != null;
}

pub fn getValue(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeInterned("value") orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Button);

    pub const Meta = struct {
        pub const name = "HTMLButtonElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Button);

    // Chrome's order. No `required`: a button has never had one, and Chrome's
    // prototype does not carry it (measured).
    pub const disabled = reflect.boolean("disabled");
    pub const form = bridge.accessor(Button.getForm, null, .{});
    pub const formAction = bridge.accessor(Button.getFormAction, Button.setFormAction, .{ .ce_reactions = true });
    pub const formEnctype = bridge.accessor(Button.getFormEnctype, Button.setFormEnctype, .{ .ce_reactions = true });
    pub const formMethod = bridge.accessor(Button.getFormMethod, Button.setFormMethod, .{ .ce_reactions = true });
    pub const formNoValidate = bridge.accessor(Button.getFormNoValidate, Button.setFormNoValidate, .{ .ce_reactions = true });
    pub const formTarget = reflect.string("formtarget");
    pub const name = reflect.string("name");
    pub const @"type" = reflect.enumerated("type", &.{ "submit", "reset", "button" }, .{ .missing = "submit" });
    pub const value = reflect.string("value");
    pub const willValidate = bridge.accessor(Button.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Button.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Button.getValidationMessage, null, .{});
    pub const labels = bridge.accessor(Button.getLabels, null, .{});
    pub const popoverTargetElement = bridge.accessor(Button.getPopoverTargetElement, Button.setPopoverTargetElement, .{ .ce_reactions = true });
    pub const popoverTargetAction = bridge.accessor(Button.getPopoverTargetAction, Button.setPopoverTargetAction, .{ .ce_reactions = true });
    pub const commandForElement = reflect.elementReference(.commandfor);

    /// An enumerated attribute with one extension: a value starting with `--`
    /// is a custom command and reads back verbatim, anything else outside the
    /// keyword set reads back as the empty string, and the keywords themselves
    /// are ASCII case-insensitive (measured: `SHOW-POPOVER` reads
    /// `show-popover`, `nope` reads ``, `--custom` reads `--custom`).
    pub const command = bridge.accessor(_command, _setCommand, .{ .ce_reactions = true });
    const command_keywords = [_][]const u8{
        "toggle-popover", "show-popover", "hide-popover",
        "close",          "show-modal",   "request-close",
    };
    fn _command(self: *const Button) []const u8 {
        const value_ = self.asConstElement().getAttributeSafe(comptime .wrap("command")) orelse return "";
        if (std.mem.startsWith(u8, value_, "--")) {
            return value_;
        }
        for (command_keywords) |keyword| {
            if (std.ascii.eqlIgnoreCase(value_, keyword)) {
                return keyword;
            }
        }
        return "";
    }
    fn _setCommand(self: *Button, value_: []const u8, frame: *Frame) !void {
        return self.asElement().setAttributeSafe(comptime .wrap("command"), .wrap(value_), frame);
    }

    pub const interestForElement = reflect.elementReference(.interestfor);
    pub const checkValidity = bridge.function(Button.checkValidity, .{});
    pub const reportValidity = bridge.function(Button.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Button.setCustomValidity, .{});
};

pub const Build = struct {
    pub fn created(_: *Node, _: *Frame) !void {
        // No initialization needed - disabled is lazy from attribute
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Button" {
    try testing.htmlRunner("element/html/button.html", .{});
}
