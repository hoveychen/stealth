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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Form = Element.Html.Form;
const Select = Element.Html.Select;

const Option = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_value: ?[]const u8 = null,
_selected: bool = false,
_default_selected: bool = false,

/// The legacy factory function `Option`, which is a second global name for
/// this same interface. Every argument is optional, so `Option.length` is 0.
///
/// The two boolean arguments are not the same thing: the third sets the
/// `selected` content attribute (which, on a fresh option, drags selectedness
/// along with it), while the fourth sets selectedness alone. Chrome therefore
/// answers `new Option('T', 'V', false, true)` with `<option value="V">T</option>`
/// whose `.selected` is true and `.defaultSelected` false. An absent -- as
/// opposed to null -- text or value argument sets nothing at all, which is why
/// both are read as raw values: `new Option(undefined, 'v')` has no text while
/// `new Option(null, null)` has the string "null" for both. Measured on a
/// headed Chrome 150 (probe-win36).
pub fn constructor(
    text_: ?js.Value,
    value_: ?js.Value,
    default_selected: ?bool,
    selected: ?bool,
    frame: *Frame,
) !*Option {
    const node = try Frame.node_factory.createElementNS(frame, .html, "option", null);
    const el = node.as(Element);

    if (text_) |text| {
        if (!text.isUndefined()) {
            const str = try text.toStringSliceWithAlloc(frame.call_arena);
            if (str.len != 0) {
                try node.setTextContent(str, frame);
            }
        }
    }

    if (value_) |value| {
        if (!value.isUndefined()) {
            const str = try value.toStringSliceWithAlloc(frame.call_arena);
            try el.setAttributeSafe(comptime .wrap("value"), .wrap(str), frame);
        }
    }

    const self = el.as(Option);
    if (default_selected orelse false) {
        try el.setAttributeSafe(comptime .wrap("selected"), comptime .wrap(""), frame);
    }
    if (selected orelse false) {
        self._selected = true;
    }
    return self;
}

pub fn asElement(self: *Option) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Option) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Option) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *Option, frame: *Frame) []const u8 {
    // If value attribute exists, use that; otherwise the `text` IDL attribute,
    // which is already stripped and collapsed.
    if (self._value) |v| {
        return v;
    }
    return stripAndCollapse(self.asNode(), frame.local_arena);
}

pub fn setValue(self: *Option, value: []const u8, frame: *Frame) !void {
    const owned = try frame.dupeString(value);
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(owned), frame);
    self._value = owned;
}

pub fn getText(self: *const Option, frame: *Frame) []const u8 {
    const node: *Node = @constCast(self.asConstElement().asConstNode());
    return stripAndCollapse(node, frame.call_arena);
}

// `text` is not textContent: the spec strips *and collapses* ASCII whitespace
// over the concatenated descendant text. A pretty-printed <select> otherwise
// hands every label back with the source indentation still attached, which is
// what a scraper reading option labels ends up storing.
// https://html.spec.whatwg.org/#dom-option-text
fn stripAndCollapse(node: *Node, allocator: std.mem.Allocator) []const u8 {
    const text = node.getTextContentAlloc(allocator) catch return "";
    // HTML's "ASCII whitespace" is exactly these five; std.ascii.whitespace
    // also carries the vertical tab, which this must not fold.
    const ws = [_]u8{ ' ', '\t', '\n', '\r', 0x0C };
    const trimmed = std.mem.trim(u8, text, &ws);
    if (trimmed.len == 0) {
        return "";
    }

    // Collapse in place: the run is never longer than what it replaces, and
    // `trimmed` is a fresh allocation this call owns.
    const buf = @constCast(trimmed);
    var len: usize = 0;
    var in_ws = false;
    for (trimmed) |c| {
        if (std.mem.indexOfScalar(u8, &ws, c) != null) {
            in_ws = true;
            continue;
        }
        if (in_ws) {
            buf[len] = ' ';
            len += 1;
            in_ws = false;
        }
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

pub fn setText(self: *Option, value: []const u8, frame: *Frame) !void {
    try self.asNode().setTextContent(value, frame);
}

pub fn getSelected(self: *const Option) bool {
    return self._selected;
}

pub fn setSelected(self: *Option, selected: bool, frame: *Frame) !void {
    self._selected = selected;
    if (self.ownerSelect()) |select| {
        if (selected) {
            if (!select.getMultiple()) {
                select.deselectOthers(self);
            }
        } else {
            select.resetToDefaultSelection();
        }
    }
    frame.domChanged();
}

/// The <select> this option belongs to, directly or through an <optgroup>.
fn ownerSelect(self: *Option) ?*Select {
    var node = self.asNode().parentNode();
    while (node) |n| : (node = n.parentNode()) {
        if (n.is(Select)) |select| return select;
        if (n.is(Element.Html.OptGroup) == null) return null;
    }
    return null;
}

pub fn getDefaultSelected(self: *const Option) bool {
    return self.asConstElement().hasAttributeInterned("selected");
}

/// Reflects the `selected` content attribute. Adding or removing it also moves
/// selectedness, which is what Build.attributeChange/attributeRemove do; the
/// field is written here too so a set-to-the-same-value (which fires no
/// attribute callback) still leaves the two consistent.
pub fn setDefaultSelected(self: *Option, value: bool, frame: *Frame) !void {
    self._default_selected = value;
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("selected"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("selected"), frame);
    }
}

/// The form owner of the select this option belongs to, and null for an option
/// that is not in one -- an option never has a form owner of its own, not even
/// inside a <form>.
pub fn getForm(self: *Option, frame: *Frame) ?*Form {
    const select = self.owningSelect() orelse return null;
    return select.getForm(frame);
}

/// The option's position among its select's options, or 0 when it has no
/// select (measured: a detached `new Option()` answers 0, not -1).
pub fn getIndex(self: *Option) i32 {
    const select = self.owningSelect() orelse return 0;
    return select.indexOfOption(self) orelse 0;
}

/// The select this option belongs to: its parent, or its parent's parent when
/// it sits in an <optgroup>.
fn owningSelect(self: *Option) ?*Select {
    const parent = self.asNode()._parent orelse return null;
    if (parent.is(Select)) |select| {
        return select;
    }
    if (parent.is(Element.Html.OptGroup) == null) {
        return null;
    }
    const grand_parent = parent._parent orelse return null;
    return grand_parent.is(Select);
}

// https://html.spec.whatwg.org/multipage/form-elements.html#dom-option-label
// On getting, return the `label` content attribute if present (verbatim, even
// when empty), otherwise the value of the `text` IDL attribute. On setting,
// reflect to the `label` content attribute.
pub fn getLabel(self: *const Option, frame: *Frame) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("label")) orelse self.getText(frame);
}

pub fn setLabel(self: *Option, label: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("label"), .wrap(label), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Option);

    pub const Meta = struct {
        pub const name = "HTMLOptionElement";
        pub const constructor_alias = "Option";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Option.constructor, .{ .arity = 0 });

    const reflect = Element.Reflect(Option);

    // Chrome's own member order (measured, probe-win28; asserted by
    // element/html/option.html #option_prototype_shape). There is no `name`
    // here -- HTMLOptionElement is one of the form-associated interfaces that
    // does not reflect it, so upstream's `reflect.string("name")` is
    // deliberately not taken: an extra own property is a tell.
    pub const disabled = reflect.boolean("disabled");
    pub const form = bridge.accessor(Option.getForm, null, .{});
    pub const label = bridge.accessor(Option.getLabel, Option.setLabel, .{ .ce_reactions = true });
    pub const defaultSelected = bridge.accessor(
        Option.getDefaultSelected,
        Option.setDefaultSelected,
        .{ .ce_reactions = true },
    );
    pub const selected = bridge.accessor(Option.getSelected, Option.setSelected, .{});
    pub const value = bridge.accessor(Option.getValue, Option.setValue, .{ .ce_reactions = true });
    pub const text = bridge.accessor(Option.getText, Option.setText, .{ .ce_reactions = true });
    pub const index = bridge.accessor(Option.getIndex, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, _: *Frame) !void {
        var self = node.as(Option);
        const element = self.asElement();

        // Check for value attribute
        self._value = element.getAttributeInterned("value");

        // Check for selected attribute
        self._default_selected = element.getAttributeInterned("selected") != null;
        self._selected = self._default_selected;
    }

    pub fn attributeChange(element: *Element, name: String, _: String, _: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { value, selected }, name.str()) orelse return;
        const self = element.as(Option);
        switch (attribute) {
            // `value` is passed by value; for <= 12 bytes, str() points into our
            // own parameter copy, so we have to re-read the owned bytes.
            .value => self._value = element.getAttributeInterned("value"),
            .selected => {
                self._default_selected = true;
                self._selected = true;
            },
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { value, selected }, name.str()) orelse return;
        const self = element.as(Option);
        switch (attribute) {
            .value => self._value = null,
            .selected => {
                self._default_selected = false;
                self._selected = false;
            },
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Option" {
    try testing.htmlRunner("element/html/option.html", .{});
}
