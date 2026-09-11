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
const collections = @import("../../collections.zig");
const TreeWalker = @import("../../TreeWalker.zig");
const Event = @import("../../Event.zig");

pub const Input = @import("Input.zig");
pub const Button = @import("Button.zig");
pub const Select = @import("Select.zig");
pub const TextArea = @import("TextArea.zig");

const Form = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

// Prevents submission of the form while we're in the process of submitting
// the form. You can imagine an onsubmit = () => form.submit() endless loop.
_firing_submission_events: bool = false,

// Prevents submission of the form while we're building the entry list for the
// form. You can imagine an formdata = () => form.submit() endless loop.
_constructing_entry_list: bool = false,

pub fn asHtmlElement(self: *Form) *HtmlElement {
    return Factory.protoOf(self);
}
fn asConstElement(self: *const Form) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asElement(self: *Form) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Form) *Node {
    return self.asElement().asNode();
}

/// The form owner of a listed form-associated element, per WHATWG HTML: a
/// `form` content attribute wins outright (even when it names nothing, in which
/// case there is no owner), otherwise the nearest <form> ancestor. Shared by the
/// four native controls and by ElementInternals, which resolves the owner of a
/// form-associated custom element the same way.
pub fn ownerOf(element: *Element, frame: *Frame) ?*Form {
    // form= resolves in the control's own tree (shadow root or document), not
    // the calling realm's. getElementByIdFromNode walks to that root.
    if (element.getAttributeSafe(comptime .wrap("form"))) |form_id| {
        const form_element = frame.getElementByIdFromNode(element.asNode(), form_id) orelse return null;
        return form_element.is(Form);
    }

    var node = element.asNode()._parent;
    while (node) |n| {
        if (n.is(Form)) |form| {
            return form;
        }
        node = n._parent;
    }
    return null;
}

/// Canonicalize the `method` content attribute (or its `formmethod` submitter
/// override) per WHATWG HTML "limited to only known values":
///   - missing → returns `missing_default`
///   - "post" / "dialog" → returns the lowercased keyword
///   - empty / invalid / "get" → returns "get" (invalid-value default)
pub fn normalizeMethod(attr: ?[]const u8, missing_default: []const u8) []const u8 {
    const method = attr orelse return missing_default;
    if (std.ascii.eqlIgnoreCase(method, "post")) return "post";
    if (std.ascii.eqlIgnoreCase(method, "dialog")) return "dialog";
    return "get";
}

/// Canonicalize the `enctype` content attribute (or its `formenctype` submitter
/// override) per WHATWG HTML "limited to only known values":
///   - missing → returns `missing_default`
///   - "multipart/form-data" / "text/plain" → returns the lowercased keyword
///   - empty / invalid / urlencoded → returns "application/x-www-form-urlencoded"
pub fn normalizeEnctype(attr: ?[]const u8, missing_default: []const u8) []const u8 {
    const enctype = attr orelse return missing_default;
    if (std.ascii.eqlIgnoreCase(enctype, "multipart/form-data")) return "multipart/form-data";
    if (std.ascii.eqlIgnoreCase(enctype, "text/plain")) return "text/plain";
    return "application/x-www-form-urlencoded";
}

pub fn getMethod(self: *const Form) []const u8 {
    return normalizeMethod(self.asConstElement().getAttributeInterned("method"), "get");
}

pub fn setMethod(self: *Form, method: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("method"), .wrap(method), frame);
}

/// `form.elements` is the *listed* elements -- which includes fieldset, object
/// and output, and excludes `input type=image` (measured on Chrome 151,
/// probes/expr-listed-elements.js). That is not the same set the form-data
/// algorithm walks; see `iterator`.
pub fn getElements(self: *Form, frame: *Frame) !*collections.HTMLFormControlsCollection {
    const key: collections.identity.Key = .{ .root = self.asNode(), .kind = .form_elements, .name = "" };
    if (collections.identity.find(frame, collections.HTMLFormControlsCollection, key)) |cached| {
        return cached;
    }

    const node_live = self.walk(.form, frame);
    const elements = try frame._factory.chained(.{
        node_live.htmlCollectionValue(),
        collections.HTMLFormControlsCollection{ ._proto = undefined },
    });
    elements._proto._chained = .form_controls;
    return collections.identity.put(frame, key, elements);
}

/// The *submittable* elements, which is what the form-data set and the
/// validity sweep are built from: `input type=image` is in (it contributes the
/// x/y pair when it is the submitter) and the three barred elements are out.
pub fn iterator(self: *Form, frame: *Frame) collections.NodeLive(.form_submittable) {
    return self.walk(.form_submittable, frame);
}

fn walk(self: *Form, comptime mode: anytype, frame: *Frame) collections.NodeLive(mode) {
    const form_id = self.asElement().getAttributeSafe(comptime .wrap("id"));
    const root = if (form_id != null)
        self.asNode().getRootNode(.{}) // Has ID: walk entire document to find form=ID controls
    else
        self.asNode(); // No ID: walk only form subtree (no external controls possible)

    return collections.NodeLive(mode).init(root, .{ .form = self, .form_id = form_id }, frame);
}

pub fn getAction(self: *Form, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const owner_url = element.ownerFrame(frame).url;
    const action = element.getAttributeInterned("action") orelse return owner_url;
    if (action.len == 0) {
        return owner_url;
    }
    return element.asNode().resolveURLReflect(action, frame, .{});
}

pub fn setAction(self: *Form, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("action"), .wrap(value), frame);
}

pub fn getAcceptCharset(self: *Form) []const u8 {
    return self.asElement().getAttributeSafe(.wrap("accept-charset")) orelse "";
}

pub fn setAcceptCharset(self: *Form, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("accept-charset"), .wrap(value), frame);
}

pub fn getEnctype(self: *const Form) []const u8 {
    return normalizeEnctype(self.asConstElement().getAttributeSafe(comptime .wrap("enctype")), "application/x-www-form-urlencoded");
}

pub fn setEnctype(self: *Form, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("enctype"), .wrap(value), frame);
}

/// Whether any listed element of the form carries this name -- as its `name`
/// or as its `id`, which name it equally.
fn namesControl(self: *Form, name: []const u8, frame: *Frame) bool {
    var listed = self.walk(.form, frame);
    while (listed.next()) |element| {
        if (namedAs(element, name)) return true;
    }
    return false;
}

fn namedAs(element: *Element, name: []const u8) bool {
    if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (std.mem.eql(u8, id, name)) return true;
    }
    if (element.getAttributeSafe(comptime .wrap("name"))) |element_name| {
        if (std.mem.eql(u8, element_name, name)) return true;
    }
    return false;
}

/// A form is named by its img elements as well as by its listed ones -- but
/// only where no listed element answers, so a control and an image sharing a
/// name reads back as the control rather than as a list of the two (measured
/// on Chrome 151, scratch/b79/edges.mjs). An img has no `form` attribute, so
/// its owner is the form it sits inside.
fn namedImage(self: *Form, name: []const u8) ?*Element {
    var tw = TreeWalker.FullExcludeSelf.Elements.init(self.asNode(), .{});
    while (tw.next()) |element| {
        if (element.is(Element.Html.Image) == null) {
            continue;
        }
        if (!namedAs(element, name)) {
            continue;
        }
        if (ownerForm(element) != self) {
            continue;
        }
        return element;
    }
    return null;
}

/// The nearest ancestor form, which is the form owner of an element that
/// cannot carry a `form` attribute.
fn ownerForm(element: *Element) ?*Form {
    var node = element.asNode()._parent;
    while (node) |n| {
        if (n.is(Form)) |form| {
            return form;
        }
        node = n._parent;
    }
    return null;
}

pub fn getLength(self: *Form, frame: *Frame) !u32 {
    const elements = try self.getElements(frame);
    return elements.length(frame);
}

pub fn submit(self: *Form, frame: *Frame) !void {
    return frame.submitForm(null, self, .{ .fire_event = false });
}

/// https://html.spec.whatwg.org/multipage/forms.html#dom-form-reset
/// A `reset` event first, which a listener can cancel; then every resettable
/// control goes back to what its attributes say. Measured on Chrome 151: an
/// `<input value="v">` typed into reads "v" again afterwards.
pub fn reset(self: *Form, frame: *Frame) !void {
    const event = try Event.init("reset", .{ .bubbles = true, .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    if (event.getDefaultPrevented()) {
        return;
    }

    var iter = self.walk(.form, frame);
    while (iter.next()) |element| {
        const html = element.as(HtmlElement);
        if (html.is(Input)) |input| {
            try input.reset(frame);
        } else if (html.is(TextArea)) |text_area| {
            text_area.reset();
        } else if (html.is(Select)) |select| {
            try select.reset(frame);
        }
    }
}

/// https://html.spec.whatwg.org/multipage/forms.html#dom-form-requestsubmit
/// Like submit(), but fires the submit event and validates the form.
pub fn requestSubmit(self: *Form, submitter: ?*Element, frame: *Frame) !void {
    const submitter_element = if (submitter) |s| blk: {
        // The submitter must be a submit button.
        if (!isSubmitButton(s)) return error.TypeError;

        // The submitter's form owner must be this form element.
        const submitter_form = getFormOwner(s, frame);
        if (submitter_form == null or submitter_form.? != self) return error.NotFound;

        break :blk s;
    } else self.asElement();

    return frame.submitForm(submitter_element, self, .{});
}

/// Returns true if the element is a submit button per the HTML spec:
/// - <input type="submit"> or <input type="image">
/// - <button type="submit"> (including default, since button's default type is "submit")
pub fn isSubmitButton(element: *Element) bool {
    if (element.is(Input)) |input| {
        return input._input_type == .submit or input._input_type == .image;
    }
    if (element.is(Button)) |button| {
        return std.mem.eql(u8, button.getType(), "submit");
    }
    return false;
}

/// Returns the form owner of a submittable element (Input or Button).
fn getFormOwner(element: *Element, frame: *Frame) ?*Form {
    if (element.is(Input)) |input| {
        return input.getForm(frame);
    }
    if (element.is(Button)) |button| {
        return button.getForm(frame);
    }
    return null;
}

/// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#dom-form-checkvalidity
/// Returns true if every submittable element in the form is valid. Fires an
/// `invalid` event on each failing element.
pub fn checkValidity(self: *Form, frame: *Frame) !bool {
    var iter = self.iterator(frame);
    var all_valid = true;
    while (iter.next()) |element| {
        const ok = try checkElementValidity(element, frame);
        if (!ok) all_valid = false;
    }
    return all_valid;
}

/// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#dom-form-reportvalidity
/// Headless: identical to checkValidity (no UI to draw).
pub fn reportValidity(self: *Form, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

fn checkElementValidity(element: *Element, frame: *Frame) !bool {
    if (element.is(Input)) |input| return input.checkValidity(frame);
    if (element.is(Select)) |select| return select.checkValidity(frame);
    if (element.is(TextArea)) |textarea| return textarea.checkValidity(frame);
    if (element.is(Button)) |button| return button.checkValidity(frame);
    return true;
}

pub fn getNoValidate(self: *const Form) bool {
    return self.asConstElement().getAttributeInterned("novalidate") != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Form);
    pub const Meta = struct {
        pub const name = "HTMLFormElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Form);
    // Chrome's own-property order: attributes in IDL order, then the
    // operations alphabetically.
    pub const acceptCharset = bridge.accessor(Form.getAcceptCharset, Form.setAcceptCharset, .{ .ce_reactions = true });
    pub const action = bridge.accessor(Form.getAction, Form.setAction, .{ .ce_reactions = true });
    pub const autocomplete = reflect.enumerated("autocomplete", &.{ "on", "off" }, .{ .missing = "on" });
    pub const enctype = bridge.accessor(Form.getEnctype, Form.setEnctype, .{ .ce_reactions = true });
    pub const encoding = reflect.enumerated("enctype", &.{ "application/x-www-form-urlencoded", "multipart/form-data", "text/plain" }, .{ .missing = "application/x-www-form-urlencoded" });
    pub const method = bridge.accessor(Form.getMethod, Form.setMethod, .{ .ce_reactions = true });
    pub const name = reflect.string("name");
    pub const noValidate = reflect.boolean("novalidate");
    pub const target = reflect.string("target");
    pub const rel = reflect.string("rel");
    pub const relList = bridge.accessor(_getRelList, _setRelList, .{ .ce_reactions = true });
    pub const elements = bridge.accessor(Form.getElements, null, .{});
    pub const length = bridge.accessor(Form.getLength, null, .{});
    pub const checkValidity = bridge.function(Form.checkValidity, .{});
    pub const reportValidity = bridge.function(Form.reportValidity, .{});
    pub const requestSubmit = bridge.function(Form.requestSubmit, .{});
    pub const reset = bridge.function(Form.reset, .{});
    pub const submit = bridge.function(Form.submit, .{});

    /// A form is indexed and named itself, not only through `form.elements`:
    /// `form[0]` is its first listed element and `form.myField` the control
    /// that name reaches -- a RadioNodeList when it reaches more than one.
    ///
    /// The two halves answer differently, which is why both were measured
    /// (Chrome 151, scratch/b79/named-objects.mjs): the indices are enumerable
    /// and listed by getOwnPropertyNames, while the names are neither listed
    /// nor enumerable and still answer `in` and hasOwnProperty. So the indexed
    /// handler has an enumerator and the named one does not.
    pub const @"[int]" = bridge.indexedFull(getAtIndex, setAtIndex, null, queryAtIndex, defineAtIndex, getIndexes, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(getByName, null, null, null, queryByName, .{ .null_as_undefined = true });

    fn getAtIndex(self: *Form, index: usize, frame: *Frame) ?*Element {
        var listed = self.walk(.form, frame);
        return listed.getAtIndex(index, frame);
    }

    // Supported indexed properties are enumerable, configurable, read-only.
    fn queryAtIndex(self: *Form, index: u32, frame: *Frame) !u32 {
        var listed = self.walk(.form, frame);
        if (index < listed.length(frame)) {
            return js.v8.ReadOnly;
        }
        return error.NotHandled;
    }

    // Web IDL gives the form no indexed setter, so assigning to or defining an
    // index fails rather than shadowing the element.
    fn setAtIndex(_: *Form, _: u32, _: js.Value) bool {
        return false;
    }

    fn defineAtIndex(_: *Form, _: u32) bool {
        return false;
    }

    fn getIndexes(self: *Form, frame: *Frame) !js.Array {
        var listed = self.walk(.form, frame);
        const len = listed.length(frame);
        var arr = frame.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }

    fn getByName(self: *Form, control_name: []const u8, frame: *Frame) !collections.HTMLFormControlsCollection.NamedItemResult {
        if (control_name.len == 0) {
            return error.NotHandled;
        }
        const controls = try self.getElements(frame);
        if (try controls.namedItem(control_name, frame)) |named| {
            return named;
        }
        return .{ .element = self.namedImage(control_name) orelse return error.NotHandled };
    }

    // Named properties are [LegacyUnenumerableNamedProperties]: non-enumerable
    // and read-only. Answered by a walk rather than by namedItem so that an
    // `in` costs no collection.
    fn queryByName(self: *Form, control_name: []const u8, frame: *Frame) !u32 {
        if (control_name.len > 0 and (self.namesControl(control_name, frame) or self.namedImage(control_name) != null)) {
            return js.v8.ReadOnly | js.v8.DontEnum;
        }
        return error.NotHandled;
    }

    fn _getRelList(self: *Form, frame: *Frame) !*collections.DOMTokenList {
        return self.asElement().getRelList(frame);
    }

    // [PutForwards=value]: the assignment goes through the list's value, so
    // the list object stays the same one and the descriptor keeps its setter.
    fn _setRelList(self: *Form, value: lp.String, frame: *Frame) !void {
        const list = try self.asElement().getRelList(frame);
        try list.setValue(value, frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Form" {
    try testing.htmlRunner("element/html/form.html", .{});
    try testing.htmlRunner("element/html/form-validity.html", .{});
    try testing.htmlRunner("element/html/form_named_access.html", .{});
}
