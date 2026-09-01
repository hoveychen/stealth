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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// `element.attachInternals()`: the custom element's private handle on the parts
// of the element only its own definition may touch -- its form participation,
// its validity, its custom states and its ARIA defaults.
//
// Measured on a headed Chrome 150 through a `static formAssociated = true`
// custom element inside a <form> (probe-win63 for the shape, probe-win64 for the
// behaviour; win63-chrome.json -> shapes.ElementInternals, win64-chrome.json ->
// internals):
//
//   * 62 prototype members in the order below. The first seven are getter-only;
//     `role` and all 52 `aria*` members are read/write. Nothing is on the global
//     but the interface object itself, which cannot be constructed.
//   * The ARIA members are *separate storage*, not reflections: after
//     `i.ariaLabel = 'hello'` the element's `aria-label` attribute is still
//     absent and `el.ariaLabel` still reads the attribute independently. Nothing
//     parses its value either -- `i.ariaLevel = 3` reads back the string "3".
//   * `setFormValue('v2')` on an element named `x` shows up in
//     `new FormData(form)` as `x=v2`.
//   * `setValidity({customError: true})` with no message is a TypeError; with
//     one, `validity.valid` goes false and `validationMessage` is the message.
//   * On a custom element *without* `static formAssociated`, reading `form` is a
//     NotSupportedError. The spec applies that same refusal to the rest of the
//     form-associated surface (willValidate, validity, validationMessage,
//     labels, checkValidity, reportValidity, setFormValue, setValidity); only
//     `form` was measured, and the others follow it here.

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const dictionary = @import("../dictionary.zig");
const Element = @import("../Element.zig");
const ShadowRoot = @import("../ShadowRoot.zig");
const CustomStateSet = @import("CustomStateSet.zig");
const Form = @import("html/Form.zig");
const Label = @import("html/Label.zig");
const ValidityState = @import("html/ValidityState.zig");
const collections = @import("../collections.zig");

const Execution = js.Execution;

const ElementInternals = @This();

// The custom element this handle was attached to.
_element: *Element,

// Whether the element's definition declared `static formAssociated = true`. The
// whole form-associated half of the interface refuses when this is false.
_form_associated: bool,

_states: *CustomStateSet,

// The last value handed to setFormValue, which the form's entry list picks up.
_form_value: ?[]const u8 = null,

_flags: ValidityState.Flags = .{},
_validation_message: []const u8 = "",
_validity: ?*ValidityState = null,

// ARIA lives here rather than on the element: these are the element's *default*
// semantics, which an author attribute overrides without erasing.
_aria: std.StringHashMapUnmanaged([]const u8) = .empty,
_aria_elements: std.StringHashMapUnmanaged([]const *Element) = .empty,
_aria_active_descendant: ?*Element = null,

pub const Lookup = std.AutoHashMapUnmanaged(*Element, *ElementInternals);

pub fn init(element: *Element, form_associated: bool, frame: *Frame) !*ElementInternals {
    const states = try frame._factory.create(CustomStateSet{});
    return frame._factory.create(ElementInternals{
        ._element = element,
        ._form_associated = form_associated,
        ._states = states,
    });
}

fn frameOf(exec: *const Execution) *Frame {
    return switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
}

/// The refusal every form-associated member answers on a custom element whose
/// definition did not declare `formAssociated` (measured for `form`).
fn requireFormAssociated(
    self: *const ElementInternals,
    comptime member: []const u8,
    comptime verb: []const u8,
    exec: *const Execution,
) !void {
    if (self._form_associated) {
        return;
    }
    return dictionary.throwDom(
        "NotSupportedError",
        "Failed to " ++ verb ++ " the '" ++ member ++ "' property from 'ElementInternals': " ++
            "The target element is not a form-associated custom element.",
        exec,
    );
}

fn requireFormAssociatedCall(
    self: *const ElementInternals,
    comptime member: []const u8,
    exec: *const Execution,
) !void {
    if (self._form_associated) {
        return;
    }
    return dictionary.throwDom(
        "NotSupportedError",
        "Failed to execute '" ++ member ++ "' on 'ElementInternals': " ++
            "The target element is not a form-associated custom element.",
        exec,
    );
}

pub fn getForm(self: *ElementInternals, exec: *const Execution) !?*Form {
    try self.requireFormAssociated("form", "read", exec);
    return Form.ownerOf(self._element, frameOf(exec));
}

pub fn getWillValidate(self: *ElementInternals, exec: *const Execution) !bool {
    try self.requireFormAssociated("willValidate", "read", exec);
    // Measured true both inside and outside a form; nothing here can disable a
    // custom element the way `disabled` disables a native control.
    return true;
}

pub fn getValidity(self: *ElementInternals, exec: *const Execution) !*ValidityState {
    try self.requireFormAssociated("validity", "read", exec);
    if (self._validity) |validity| {
        return validity;
    }
    const validity = try frameOf(exec)._factory.create(ValidityState{
        ._owner = self._element,
        ._flags = &self._flags,
    });
    self._validity = validity;
    return validity;
}

pub fn getValidationMessage(self: *ElementInternals, exec: *const Execution) ![]const u8 {
    try self.requireFormAssociated("validationMessage", "read", exec);
    return self._validation_message;
}

pub fn getLabels(self: *ElementInternals, exec: *const Execution) !*collections.NodeList {
    try self.requireFormAssociated("labels", "read", exec);
    return Label.getControlLabels(self._element, frameOf(exec));
}

pub fn getStates(self: *ElementInternals) *CustomStateSet {
    return self._states;
}

/// What the `:state()` selector asks. Exact string equality: Chrome does not
/// fold the dashed-ident form either (measured).
pub fn hasState(self: *const ElementInternals, state: []const u8) bool {
    return self._states.contains(state);
}

pub fn getShadowRoot(self: *ElementInternals, exec: *const Execution) ?*ShadowRoot {
    return self._element.getShadowRoot(frameOf(exec));
}

pub fn checkValidity(self: *ElementInternals, exec: *const Execution) !bool {
    try self.requireFormAssociatedCall("checkValidity", exec);
    return self._flags.isValid();
}

/// Nothing is reported anywhere headless, so this is checkValidity with a
/// different name -- the same shortcut Input and friends already take.
pub fn reportValidity(self: *ElementInternals, exec: *const Execution) !bool {
    return self.checkValidity(exec);
}

pub fn setFormValue(self: *ElementInternals, args: []js.Value, exec: *const Execution) !void {
    try self.requireFormAssociatedCall("setFormValue", exec);
    if (args.len == 0) {
        return dictionary.throwTypeError(
            "Failed to execute 'setFormValue' on 'ElementInternals': 1 argument required, but only 0 present.",
            exec,
        );
    }
    if (args[0].isNull()) {
        self._form_value = null;
        return;
    }
    self._form_value = try exec.dupeString(try args[0].toStringSlice());
}

const ValidityFlagsReader = dictionary.MethodReader("ElementInternals", "setValidity", "ValidityStateFlags");

pub fn setValidity(self: *ElementInternals, args: []js.Value, exec: *const Execution) !void {
    try self.requireFormAssociatedCall("setValidity", exec);
    if (args.len == 0) {
        return dictionary.throwTypeError(
            "Failed to execute 'setValidity' on 'ElementInternals': 1 argument required, but only 0 present.",
            exec,
        );
    }

    const flags_reader = try ValidityFlagsReader.read(args[0], exec);
    const flags: ValidityState.Flags = .{
        .value_missing = try flags_reader.boolean("valueMissing", false),
        .type_mismatch = try flags_reader.boolean("typeMismatch", false),
        .pattern_mismatch = try flags_reader.boolean("patternMismatch", false),
        .too_long = try flags_reader.boolean("tooLong", false),
        .too_short = try flags_reader.boolean("tooShort", false),
        .range_underflow = try flags_reader.boolean("rangeUnderflow", false),
        .range_overflow = try flags_reader.boolean("rangeOverflow", false),
        .step_mismatch = try flags_reader.boolean("stepMismatch", false),
        .bad_input = try flags_reader.boolean("badInput", false),
        .custom_error = try flags_reader.boolean("customError", false),
    };

    const message: []const u8 = blk: {
        if (args.len < 2 or args[1].isUndefined()) {
            break :blk "";
        }
        break :blk try args[1].toStringSlice();
    };

    if (!flags.isValid() and message.len == 0) {
        return dictionary.throwTypeError(
            "Failed to execute 'setValidity' on 'ElementInternals': The second argument should not be " ++
                "empty if one or more flags in the first argument are true.",
            exec,
        );
    }

    self._flags = flags;
    self._validation_message = if (message.len == 0) "" else try exec.dupeString(message);
}

// The ARIA half. Every member is its own slot in `_aria`, keyed by the JS member
// name: assigning stores the string, assigning null clears it, and reading never
// consults the element's attributes.
fn ariaString(comptime member: []const u8) type {
    return struct {
        pub fn get(self: *ElementInternals) ?[]const u8 {
            return self._aria.get(member);
        }

        pub fn set(self: *ElementInternals, value: ?[]const u8, frame: *Frame) !void {
            const text = value orelse {
                _ = self._aria.remove(member);
                return;
            };
            try self._aria.put(frame.arena, member, try frame.dupeString(text));
        }
    };
}

// The element-list members (`aria*Elements`) answer null until assigned, then
// the Array they were assigned.
fn ariaElements(comptime member: []const u8) type {
    return struct {
        pub fn get(self: *ElementInternals) ?[]const *Element {
            return self._aria_elements.get(member);
        }

        pub fn set(self: *ElementInternals, value: ?[]const *Element, frame: *Frame) !void {
            const elements = value orelse {
                _ = self._aria_elements.remove(member);
                return;
            };
            try self._aria_elements.put(frame.arena, member, try frame.arena.dupe(*Element, elements));
        }
    };
}

pub fn getAriaActiveDescendantElement(self: *ElementInternals) ?*Element {
    return self._aria_active_descendant;
}

pub fn setAriaActiveDescendantElement(self: *ElementInternals, value: ?*Element) void {
    self._aria_active_descendant = value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ElementInternals);

    pub const Meta = struct {
        pub const name = "ElementInternals";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own prototype order (win63-chrome.json -> protoOwn): the seven
    // getter-only members, `role`, the 41 original ARIAMixin accessors, the four
    // operations, then the members ARIA added later.
    pub const form = bridge.accessor(ElementInternals.getForm, null, .{});
    pub const willValidate = bridge.accessor(ElementInternals.getWillValidate, null, .{});
    pub const validity = bridge.accessor(ElementInternals.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(ElementInternals.getValidationMessage, null, .{});
    pub const labels = bridge.accessor(ElementInternals.getLabels, null, .{});
    pub const states = bridge.accessor(ElementInternals.getStates, null, .{});
    pub const shadowRoot = bridge.accessor(ElementInternals.getShadowRoot, null, .{});

    pub const role = bridge.accessor(ariaString("role").get, ariaString("role").set, .{});
    pub const ariaAtomic = bridge.accessor(ariaString("ariaAtomic").get, ariaString("ariaAtomic").set, .{});
    pub const ariaAutoComplete = bridge.accessor(ariaString("ariaAutoComplete").get, ariaString("ariaAutoComplete").set, .{});
    pub const ariaBusy = bridge.accessor(ariaString("ariaBusy").get, ariaString("ariaBusy").set, .{});
    pub const ariaBrailleLabel = bridge.accessor(ariaString("ariaBrailleLabel").get, ariaString("ariaBrailleLabel").set, .{});
    pub const ariaBrailleRoleDescription = bridge.accessor(ariaString("ariaBrailleRoleDescription").get, ariaString("ariaBrailleRoleDescription").set, .{});
    pub const ariaChecked = bridge.accessor(ariaString("ariaChecked").get, ariaString("ariaChecked").set, .{});
    pub const ariaColCount = bridge.accessor(ariaString("ariaColCount").get, ariaString("ariaColCount").set, .{});
    pub const ariaColIndex = bridge.accessor(ariaString("ariaColIndex").get, ariaString("ariaColIndex").set, .{});
    pub const ariaColSpan = bridge.accessor(ariaString("ariaColSpan").get, ariaString("ariaColSpan").set, .{});
    pub const ariaCurrent = bridge.accessor(ariaString("ariaCurrent").get, ariaString("ariaCurrent").set, .{});
    pub const ariaDescription = bridge.accessor(ariaString("ariaDescription").get, ariaString("ariaDescription").set, .{});
    pub const ariaDisabled = bridge.accessor(ariaString("ariaDisabled").get, ariaString("ariaDisabled").set, .{});
    pub const ariaExpanded = bridge.accessor(ariaString("ariaExpanded").get, ariaString("ariaExpanded").set, .{});
    pub const ariaHasPopup = bridge.accessor(ariaString("ariaHasPopup").get, ariaString("ariaHasPopup").set, .{});
    pub const ariaHidden = bridge.accessor(ariaString("ariaHidden").get, ariaString("ariaHidden").set, .{});
    pub const ariaInvalid = bridge.accessor(ariaString("ariaInvalid").get, ariaString("ariaInvalid").set, .{});
    pub const ariaKeyShortcuts = bridge.accessor(ariaString("ariaKeyShortcuts").get, ariaString("ariaKeyShortcuts").set, .{});
    pub const ariaLabel = bridge.accessor(ariaString("ariaLabel").get, ariaString("ariaLabel").set, .{});
    pub const ariaLevel = bridge.accessor(ariaString("ariaLevel").get, ariaString("ariaLevel").set, .{});
    pub const ariaLive = bridge.accessor(ariaString("ariaLive").get, ariaString("ariaLive").set, .{});
    pub const ariaModal = bridge.accessor(ariaString("ariaModal").get, ariaString("ariaModal").set, .{});
    pub const ariaMultiLine = bridge.accessor(ariaString("ariaMultiLine").get, ariaString("ariaMultiLine").set, .{});
    pub const ariaMultiSelectable = bridge.accessor(ariaString("ariaMultiSelectable").get, ariaString("ariaMultiSelectable").set, .{});
    pub const ariaOrientation = bridge.accessor(ariaString("ariaOrientation").get, ariaString("ariaOrientation").set, .{});
    pub const ariaPlaceholder = bridge.accessor(ariaString("ariaPlaceholder").get, ariaString("ariaPlaceholder").set, .{});
    pub const ariaPosInSet = bridge.accessor(ariaString("ariaPosInSet").get, ariaString("ariaPosInSet").set, .{});
    pub const ariaPressed = bridge.accessor(ariaString("ariaPressed").get, ariaString("ariaPressed").set, .{});
    pub const ariaReadOnly = bridge.accessor(ariaString("ariaReadOnly").get, ariaString("ariaReadOnly").set, .{});
    pub const ariaRelevant = bridge.accessor(ariaString("ariaRelevant").get, ariaString("ariaRelevant").set, .{});
    pub const ariaRequired = bridge.accessor(ariaString("ariaRequired").get, ariaString("ariaRequired").set, .{});
    pub const ariaRoleDescription = bridge.accessor(ariaString("ariaRoleDescription").get, ariaString("ariaRoleDescription").set, .{});
    pub const ariaRowCount = bridge.accessor(ariaString("ariaRowCount").get, ariaString("ariaRowCount").set, .{});
    pub const ariaRowIndex = bridge.accessor(ariaString("ariaRowIndex").get, ariaString("ariaRowIndex").set, .{});
    pub const ariaRowSpan = bridge.accessor(ariaString("ariaRowSpan").get, ariaString("ariaRowSpan").set, .{});
    pub const ariaSelected = bridge.accessor(ariaString("ariaSelected").get, ariaString("ariaSelected").set, .{});
    pub const ariaSetSize = bridge.accessor(ariaString("ariaSetSize").get, ariaString("ariaSetSize").set, .{});
    pub const ariaSort = bridge.accessor(ariaString("ariaSort").get, ariaString("ariaSort").set, .{});
    pub const ariaValueMax = bridge.accessor(ariaString("ariaValueMax").get, ariaString("ariaValueMax").set, .{});
    pub const ariaValueMin = bridge.accessor(ariaString("ariaValueMin").get, ariaString("ariaValueMin").set, .{});
    pub const ariaValueNow = bridge.accessor(ariaString("ariaValueNow").get, ariaString("ariaValueNow").set, .{});
    pub const ariaValueText = bridge.accessor(ariaString("ariaValueText").get, ariaString("ariaValueText").set, .{});

    pub const checkValidity = bridge.function(ElementInternals.checkValidity, .{});
    pub const reportValidity = bridge.function(ElementInternals.reportValidity, .{});
    pub const setFormValue = bridge.function(ElementInternals.setFormValue, .{ .arity = 1 });
    pub const setValidity = bridge.function(ElementInternals.setValidity, .{ .arity = 1 });

    pub const ariaColIndexText = bridge.accessor(ariaString("ariaColIndexText").get, ariaString("ariaColIndexText").set, .{});
    pub const ariaRowIndexText = bridge.accessor(ariaString("ariaRowIndexText").get, ariaString("ariaRowIndexText").set, .{});
    pub const ariaActionsElements = bridge.accessor(ariaElements("ariaActionsElements").get, ariaElements("ariaActionsElements").set, .{});
    pub const ariaActiveDescendantElement = bridge.accessor(ElementInternals.getAriaActiveDescendantElement, ElementInternals.setAriaActiveDescendantElement, .{});
    pub const ariaControlsElements = bridge.accessor(ariaElements("ariaControlsElements").get, ariaElements("ariaControlsElements").set, .{});
    pub const ariaDescribedByElements = bridge.accessor(ariaElements("ariaDescribedByElements").get, ariaElements("ariaDescribedByElements").set, .{});
    pub const ariaDetailsElements = bridge.accessor(ariaElements("ariaDetailsElements").get, ariaElements("ariaDetailsElements").set, .{});
    pub const ariaErrorMessageElements = bridge.accessor(ariaElements("ariaErrorMessageElements").get, ariaElements("ariaErrorMessageElements").set, .{});
    pub const ariaFlowToElements = bridge.accessor(ariaElements("ariaFlowToElements").get, ariaElements("ariaFlowToElements").set, .{});
    pub const ariaLabelledByElements = bridge.accessor(ariaElements("ariaLabelledByElements").get, ariaElements("ariaLabelledByElements").set, .{});
};
