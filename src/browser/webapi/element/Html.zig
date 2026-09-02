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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

const Frame = @import("../../Frame.zig");
const StyleManager = @import("../../StyleManager.zig");
const text_case = @import("../../text_case.zig");
const reflection = @import("reflection.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const dictionary = @import("../dictionary.zig");
const EditContext = @import("../EditContext.zig");
const ElementInternals = @import("ElementInternals.zig");
const global_event_handlers = @import("../global_event_handlers.zig");
const CustomElementDefinition = @import("../CustomElementDefinition.zig");
const CSSStyleDeclaration = @import("../css/CSSStyleDeclaration.zig");

const popover = @import("popover.zig");
pub const Anchor = @import("html/Anchor.zig");
pub const Area = @import("html/Area.zig");
pub const Base = @import("html/Base.zig");
pub const Body = @import("html/Body.zig");
pub const BR = @import("html/BR.zig");
pub const Button = @import("html/Button.zig");
pub const Canvas = @import("html/Canvas.zig");
pub const Custom = @import("html/Custom.zig");
pub const Data = @import("html/Data.zig");
pub const DataList = @import("html/DataList.zig");
pub const Details = @import("html/Details.zig");
pub const Dialog = @import("html/Dialog.zig");
pub const Directory = @import("html/Directory.zig");
pub const Menu = @import("html/Menu.zig");
pub const FrameElement = @import("html/FrameElement.zig");
pub const Div = @import("html/Div.zig");
pub const DList = @import("html/DList.zig");
pub const Embed = @import("html/Embed.zig");
pub const FieldSet = @import("html/FieldSet.zig");
pub const Font = @import("html/Font.zig");
pub const Form = @import("html/Form.zig");
pub const FrameSet = @import("html/FrameSet.zig");
pub const Generic = @import("html/Generic.zig");
pub const Head = @import("html/Head.zig");
pub const Heading = @import("html/Heading.zig");
pub const HR = @import("html/HR.zig");
pub const Html = @import("html/Html.zig");
pub const IFrame = @import("html/IFrame.zig");
pub const Image = @import("html/Image.zig");
pub const Input = @import("html/Input.zig");
pub const Label = @import("html/Label.zig");
pub const Legend = @import("html/Legend.zig");
pub const LI = @import("html/LI.zig");
pub const Link = @import("html/Link.zig");
pub const Map = @import("html/Map.zig");
pub const Marquee = @import("html/Marquee.zig");
pub const Media = @import("html/Media.zig");
pub const Meta = @import("html/Meta.zig");
pub const Meter = @import("html/Meter.zig");
pub const Mod = @import("html/Mod.zig");
pub const Object = @import("html/Object.zig");
pub const OL = @import("html/OL.zig");
pub const OptGroup = @import("html/OptGroup.zig");
pub const Option = @import("html/Option.zig");
pub const Output = @import("html/Output.zig");
pub const Paragraph = @import("html/Paragraph.zig");
pub const Picture = @import("html/Picture.zig");
pub const Param = @import("html/Param.zig");
pub const Pre = @import("html/Pre.zig");
pub const Progress = @import("html/Progress.zig");
pub const Quote = @import("html/Quote.zig");
pub const Script = @import("html/Script.zig");
pub const Select = @import("html/Select.zig");
pub const SelectedContent = @import("html/SelectedContent.zig");
pub const Slot = @import("html/Slot.zig");
pub const Geolocation = @import("html/Geolocation.zig");
pub const UserMedia = @import("html/UserMedia.zig");
pub const Source = @import("html/Source.zig");
pub const Span = @import("html/Span.zig");
pub const Style = @import("html/Style.zig");
pub const Table = @import("html/Table.zig");
pub const TableCaption = @import("html/TableCaption.zig");
pub const TableCell = @import("html/TableCell.zig");
pub const TableCol = @import("html/TableCol.zig");
pub const TableRow = @import("html/TableRow.zig");
pub const TableSection = @import("html/TableSection.zig");
pub const Template = @import("html/Template.zig");
pub const TextArea = @import("html/TextArea.zig");
pub const Time = @import("html/Time.zig");
pub const Title = @import("html/Title.zig");
pub const Track = @import("html/Track.zig");
pub const UL = @import("html/UL.zig");
pub const Unknown = @import("html/Unknown.zig");

const log = lp.log;
const String = lp.String;
const GlobalEventHandler = global_event_handlers.Handler;

const HtmlElement = @This();

pub const Proto = Element;

_type: Type,
_proto_canary: if (lp.IS_DEBUG) *Element else void = undefined,

// Special constructor for custom elements (autonomous, `extends HTMLElement`).
// Two paths:
//  - Upgrade path: customElements.define / createElement / upgrade set
//    `_upgrading_element` before calling newInstance, and we just return it.
//  - Direct path: `new MyElement()` from user code. `new.target` tells us
//    which custom element class was invoked; look it up in the registry.
pub fn construct(new_target: js.Function, frame: *Frame) !*Element {
    if (frame._upgrading_element) |node| {
        if (frame._upgrading_consumed) {
            return error.TypeError;
        }
        frame._upgrading_consumed = true;
        return node.is(Element) orelse return error.IllegalConstructor;
    }
    return Frame.node_factory.constructCustomElement(frame, new_target);
}

// Shared constructor callback for builtin html element interfaces. These types
// cannot be instantinated (e.g. new HTMLDivElement), but a custom element can
// be extended, so super() has to create them. All of these types have their
// constructors routed here.
pub fn upgradeConstruct(frame: *Frame) !*Element {
    // Nothing set up an element to upgrade, so this is page script calling
    // `new HTMLDivElement()` (or `new` on an unregistered subclass of one).
    // Chrome refuses with "Failed to construct 'HTMLDivElement': Illegal
    // constructor" (measured on Chrome 151); a bare TypeError left the message
    // empty, which no browser has for any constructor. The interface named comes
    // from the callback being generated per interface -- see
    // Snapshot.upgradeConstructor.
    const node = frame._upgrading_element orelse return error.IllegalConstructor;
    if (frame._upgrading_consumed) {
        return error.TypeError;
    }
    frame._upgrading_consumed = true;
    return node.is(Element) orelse return error.TypeError;
}

pub const Type = enum(u8) {
    anchor,
    area,
    base,
    body,
    br,
    button,
    canvas,
    custom,
    data,
    datalist,
    details,
    dialog,
    directory,
    menu,
    frame_element,
    div,
    dl,
    embed,
    fieldset,
    font,
    form,
    frameset,
    generic,
    heading,
    head,
    html,
    hr,
    img,
    iframe,
    input,
    label,
    legend,
    li,
    link,
    map,
    marquee,
    media,
    meta,
    meter,
    mod,
    object,
    ol,
    optgroup,
    option,
    output,
    p,
    picture,
    param,
    pre,
    progress,
    quote,
    script,
    select,
    selected_content,
    slot,
    geolocation,
    user_media,
    source,
    span,
    style,
    table,
    table_caption,
    table_cell,
    table_col,
    table_row,
    table_section,
    template,
    textarea,
    time,
    title,
    track,
    ul,
    unknown,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .anchor => Anchor,
        .area => Area,
        .base => Base,
        .body => Body,
        .br => BR,
        .button => Button,
        .canvas => Canvas,
        .custom => Custom,
        .data => Data,
        .datalist => DataList,
        .details => Details,
        .dialog => Dialog,
        .directory => Directory,
        .menu => Menu,
        .frame_element => FrameElement,
        .div => Div,
        .dl => DList,
        .embed => Embed,
        .fieldset => FieldSet,
        .font => Font,
        .form => Form,
        .frameset => FrameSet,
        .generic => Generic,
        .heading => Heading,
        .head => Head,
        .html => Html,
        .hr => HR,
        .img => Image,
        .iframe => IFrame,
        .input => Input,
        .label => Label,
        .legend => Legend,
        .li => LI,
        .link => Link,
        .map => Map,
        .marquee => Marquee,
        .media => Media,
        .meta => Meta,
        .meter => Meter,
        .mod => Mod,
        .object => Object,
        .ol => OL,
        .optgroup => OptGroup,
        .option => Option,
        .output => Output,
        .p => Paragraph,
        .picture => Picture,
        .param => Param,
        .pre => Pre,
        .progress => Progress,
        .quote => Quote,
        .script => Script,
        .select => Select,
        .selected_content => SelectedContent,
        .slot => Slot,
        .geolocation => Geolocation,
        .user_media => UserMedia,
        .source => Source,
        .span => Span,
        .style => Style,
        .table => Table,
        .table_caption => TableCaption,
        .table_cell => TableCell,
        .table_col => TableCol,
        .table_row => TableRow,
        .table_section => TableSection,
        .template => Template,
        .textarea => TextArea,
        .time => Time,
        .title => Title,
        .track => Track,
        .ul => UL,
        .unknown => Unknown,
    };
}

pub fn subtype(self: *const HtmlElement, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, HtmlElement);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *HtmlElement, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    return null;
}

pub fn asElement(self: *HtmlElement) *Element {
    return Factory.protoOf(self);
}

pub fn asNode(self: *HtmlElement) *Node {
    return self.asElement().asNode();
}

pub fn asEventTarget(self: *HtmlElement) *@import("../EventTarget.zig") {
    return self.asNode().asEventTarget();
}

pub fn getInnerText(self: *HtmlElement, writer: *std.Io.Writer, frame: *Frame) !void {
    const tag = self.asElement().getTag();

    // innerText's first step: an element with no box at all answers with its
    // descendant text content, which is textContent's answer and not the layout
    // walk's -- no line breaks, whatever its children are. Measured on Chrome
    // 151 (probes/expr-inner-text-{skip-tags,not-rendered-subtree,detached}.js):
    // a `<style>` reads its CSS, a `display: none` div reads its blocks run
    // together, and a detached one does too.
    if (!isBeingRendered(self, tag, frame)) {
        return self.asNode().getTextContent(writer);
    }

    // A replaced element *is* rendered; its subtree just is not text. That is a
    // different answer from the one above -- `<textarea>x</textarea>` reads ""
    // in Chrome, not "x".
    if (innerTextDisplay(self, tag, frame) == .replaced) {
        return;
    }

    var state = InnerTextState{
        .writer = writer,
        .frame = frame,
        // The root's own value, which is the one walk up the ancestors this
        // costs: every element below answers with its own declaration or with
        // this one.
        .white_space = WhiteSpace.of(CSSStyleDeclaration.whiteSpaceCollapse(self.asElement(), frame)),
        .transform = frame._style_manager.computedTextTransform(self.asElement()),
        // Seeded from the element's own computed value, which is an ancestor walk
        // because `visibility` inherits -- reading innerText off a hidden element
        // is `""` in Chrome 151 (probe w1-visibility) even though the hiding
        // declaration may sit on an ancestor. Every element below is resolved
        // against this value instead of walking again.
        .visible = !(frame._style_manager.computedVisibility(self.asElement()) orelse StyleManager.Visibility.visible).hides(),
    };
    try self.collectInnerText(&state);
}

pub fn setInnerText(self: *HtmlElement, text: []const u8, frame: *Frame) !void {
    const items = try renderedTextFragment(text, frame);
    try self.asElement().replaceChildren(items, frame);
}

pub fn setOuterText(self: *HtmlElement, text: []const u8, frame: *Frame) !void {
    const el = self.asElement();
    // outerText is an HTMLElement property. MathML elements currently share
    // the HTML wrapper types, so keep the assignment inert for them.
    if (el._namespace != .html) {
        return;
    }
    const node = el.asNode();
    const parent = node.parentNode() orelse return error.NoModificationAllowed;

    const prev = node.previousSibling();
    const next = node.nextSibling();

    var items: []const Node.NodeOrText = try renderedTextFragment(text, frame);
    if (items.len == 0) {
        // A fragment with no node still replaces the element with an empty Text
        // node so surrounding text can merge with it.
        items = &.{.{ .text = "" }};
    }
    try el.replaceWith(items, frame);

    // Merge with the immediately neighbouring Text nodes (only those two; the
    // tree is not fully normalised, per spec).
    const first = if (prev) |p| p.nextSibling() else parent.firstChild();
    var last = if (next) |n| n.previousSibling() else parent.lastChild();

    if (prev) |p| {
        if (first) |f| {
            if (mergeTextNodes(p, f, frame) catch false) {
                if (f == last) last = p;
            }
        }
    }

    if (next) |n| {
        if (last) |l| {
            _ = mergeTextNodes(l, n, frame) catch false;
        }
    }
}

pub fn insertAdjacentHTML(
    self: *HtmlElement,
    position: []const u8,
    html: []const u8,
    frame: *Frame,
) !void {
    const DocumentFragment = @import("../DocumentFragment.zig");
    const fragment = (try DocumentFragment.init(frame)).asNode();
    try Frame.parse.htmlAsChildren(frame, fragment, html);

    const target_node, const prev_node = try self.asNode().findAdjacentNodes(position, .html);

    var iter = fragment.childrenIterator();
    while (iter.next()) |child_node| {
        _ = try target_node.insertBefore(child_node, prev_node, frame);
    }
}

/// `element.attachInternals()`. Only a custom element has internals to hand out,
/// and only once: both refusals are NotSupportedErrors whose wording is measured
/// on a headed Chrome 150 (win63-chrome.json, win64-chrome.json).
pub fn attachInternals(self: *HtmlElement, exec: *const js.Execution) !*ElementInternals {
    const frame = switch (exec.js.global) {
        .frame => |f| f,
        .worker => unreachable,
    };

    const element = Factory.protoOf(self);
    const definition = definitionOf(element, frame) orelse return dictionary.throwDom(
        "NotSupportedError",
        "Failed to execute 'attachInternals' on 'HTMLElement': " ++
            "Unable to attach ElementInternals to non-custom elements.",
        exec,
    );

    if (frame._element_internals.get(element) != null) {
        return dictionary.throwDom(
            "NotSupportedError",
            "Failed to execute 'attachInternals' on 'HTMLElement': " ++
                "ElementInternals for the specified element was already attached.",
            exec,
        );
    }

    const internals = try ElementInternals.init(element, definition.form_associated, frame);
    try frame._element_internals.put(frame.arena, element, internals);
    return internals;
}

/// The definition behind a custom element, autonomous or customized built-in.
/// Autonomous elements look theirs up by tag name the same way attachShadow
/// does, so an element created before its `define()` still finds it.
fn definitionOf(element: *Element, frame: *Frame) ?*CustomElementDefinition {
    if (element.is(Custom)) |custom| {
        if (custom._definition) |definition| {
            return definition;
        }
        return frame.window._custom_elements._definitions.get(custom._tag_name.str());
    }
    return frame._customized_builtin_definitions.get(element);
}

pub fn click(self: *HtmlElement, frame: *Frame) !void {
    switch (self._type) {
        inline .button, .input, .textarea, .select => |tag| {
            if (self.subtype(Subtype(tag)).getDisabled()) {
                return;
            }
        },
        else => {},
    }

    const flags = &self.asElement()._flags;
    if (flags.click_in_progress) {
        return;
    }
    flags.click_in_progress = true;
    defer flags.click_in_progress = false;

    const event = (try @import("../event/MouseEvent.zig").init("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = 0,
        .clientY = 0,
    }, frame)).asEvent();

    // Keep the event alive past dispatch (which runs handlers/microtasks) so we
    // can read _prevent_default afterwards.
    event.acquireRef();
    defer _ = event.releaseRef(frame._page);

    try frame._event_manager.dispatch(self.asEventTarget(), event);

    if (event._prevent_default == false) {
        // toggle the popover_target
        const explicit: ?*Element = switch (self._type) {
            .button => self.subtype(Button)._popover_target,
            .input => self.subtype(Input)._popover_target,
            else => null,
        };
        try popover.runInvokerActivation(self, explicit, frame);
    }
}

// TODO: Per spec, hidden is a tristate: true | false | "until-found".
// We only support boolean for now; "until-found" would need bridge union support.
pub fn getHidden(self: *HtmlElement) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("hidden")) != null;
}

pub fn setHidden(self: *HtmlElement, hidden: bool, frame: *Frame) !void {
    if (hidden) {
        try self.asElement().setAttributeSafe(comptime .wrap("hidden"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("hidden"), frame);
    }
}

// The translate IDL attribute reflects the element's translation mode:
// translate="yes"/"" enables it, "no" disables it, anything else (or no
// attribute) inherits from the parent, defaulting to enabled.
pub fn getTranslate(self: *HtmlElement) bool {
    var node: ?*Node = self.asElement().asNode();
    while (node) |n| : (node = n.parentNode()) {
        const el = n.is(Element) orelse continue;
        const value = el.getAttributeSafe(comptime .wrap("translate")) orelse continue;
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "yes")) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(value, "no")) {
            return false;
        }
    }
    return true;
}

pub fn setTranslate(self: *HtmlElement, translate: bool, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("translate"), .wrap(if (translate) "yes" else "no"), frame);
}

// accessKeyLabel: the UA-assigned shortcut for a valid (single character)
// accesskey, or the empty string. We report an Alt+ chord like Chromium.
pub fn getAccessKeyLabel(self: *HtmlElement, frame: *Frame) ![]const u8 {
    const value = self.asElement().getAttributeSafe(comptime .wrap("accesskey")) orelse return "";
    const codepoints = std.unicode.utf8CountCodepoints(value) catch return "";
    if (codepoints != 1) {
        return "";
    }
    return std.fmt.allocPrint(frame.local_arena, "Alt+{s}", .{value});
}

pub fn getPopover(self: *HtmlElement) ?[]const u8 {
    const s = popover.getState(self.asElement()) orelse return null;
    return @tagName(s);
}

pub fn setPopover(self: *HtmlElement, value_: ?[]const u8, frame: *Frame) !void {
    if (value_) |value| {
        // does not validate the value, stores it as-is
        try self.asElement().setAttribute(comptime .wrap("popover"), .wrap(value), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("popover"), frame);
    }
}

pub fn showPopover(self: *HtmlElement, frame: *Frame) !void {
    return popover.show(self.asElement(), frame);
}

pub fn hidePopover(self: *HtmlElement, frame: *Frame) !void {
    return popover.hide(self.asElement(), frame);
}

pub fn togglePopover(self: *HtmlElement, force: ?bool, frame: *Frame) !bool {
    return popover.toggle(self.asElement(), force, frame);
}

pub fn getTabIndex(self: *HtmlElement) i32 {
    if (self.asElement().getAttributeSafe(comptime .wrap("tabindex"))) |attr| {
        if (parseInteger(attr)) |tab_index| {
            return tab_index;
        }
    }

    return switch (self._type) {
        .anchor, .area, .button, .input, .select, .textarea, .iframe => 0,
        else => -1,
    };
}

pub fn setTabIndex(self: *HtmlElement, value: i32, frame: *Frame) !void {
    var buf: [12]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap("tabindex"), .wrap(str), frame);
}

pub fn getDir(self: *HtmlElement) []const u8 {
    return reflection.enumeratedValue(self.asElement().getAttributeSafe(comptime .wrap("dir")), &.{ "ltr", "rtl", "auto" }, "", "").?;
}

// An enumerated attribute reflects the value it was given, invalid or not --
// the keyword folding happens on the way out, in getDir.
pub fn setDir(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("dir"), .wrap(value), frame);
}

pub fn getAccessKey(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("accesskey")) orelse "";
}

pub fn setAccessKey(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("accesskey"), .wrap(value), frame);
}

pub fn getAutofocus(self: *HtmlElement) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("autofocus")) != null;
}

pub fn setAutofocus(self: *HtmlElement, autofocus: bool, frame: *Frame) !void {
    if (autofocus) {
        try self.asElement().setAttributeSafe(comptime .wrap("autofocus"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("autofocus"), frame);
    }
}

// Not the content attribute -- see Element.getNonce for the measurement.
pub fn getNonce(self: *HtmlElement, frame: *Frame) []const u8 {
    return self.asElement().getNonce(frame);
}

pub fn setNonce(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    return self.asElement().setNonce(value, frame);
}

pub fn getLang(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("lang")) orelse "";
}

pub fn setLang(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("lang"), .wrap(value), frame);
}

pub fn getTitle(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("title")) orelse "";
}

pub fn setTitle(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("title"), .wrap(value), frame);
}

// HTML §7.7.5.2 specifies the IDL attribute as true iff the element's effective
// content editable state is "true" or "plaintext-only". Lightpanda has no
// caret/keyboard editing pipeline, so a true answer cannot be honored
// end-to-end — downstream CDP tools (notably Puppeteer's dispatchKeyEvent
// path) would route into an input pipeline that silently no-ops. Always
// return false, and log .not_implemented when the spec would have said true
// so usage surfaces in telemetry rather than silently depending on an
// unsupported value. Spec walk per HTML §7.7.5.2 still applies — the nearest
// ancestor with `contenteditable` wins; "false" disables. See PR #2310 for
// the routing-vs-fail-loud discussion.
//
// "contenteditable" is 15 bytes — past the comptime SSO limit — so the
// String wrap runs at runtime, mirroring the pattern in interactive.zig.
pub fn getIsContentEditable(self: *HtmlElement) bool {
    var current: ?*Element = self.asElement();
    while (current) |el| : (current = el.parentElement()) {
        const raw = el.getAttributeSafe(.wrap("contenteditable")) orelse continue;
        if (!std.ascii.eqlIgnoreCase(raw, "false")) {
            log.info(.not_implemented, "IsContentEditable", .{});
        }
        break;
    }
    return false;
}

// `inert` and `focusgroupstart` are boolean content attributes: present is
// true whatever the value, and the setter writes "" or removes. Measured on a
// headed Chrome 150 -- unlike the inertness *state*, which a subtree inherits,
// the IDL attribute is attribute-local.
pub fn getInert(self: *HtmlElement) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("inert")) != null;
}

pub fn setInert(self: *HtmlElement, value: bool, frame: *Frame) !void {
    return self.setBooleanAttribute(comptime .wrap("inert"), value, frame);
}

pub fn getFocusGroupStart(self: *HtmlElement) bool {
    return self.asElement().getAttributeSafe(.wrap("focusgroupstart")) != null;
}

pub fn setFocusGroupStart(self: *HtmlElement, value: bool, frame: *Frame) !void {
    return self.setBooleanAttribute(.wrap("focusgroupstart"), value, frame);
}

fn setBooleanAttribute(self: *HtmlElement, name: String, value: bool, frame: *Frame) !void {
    const el = self.asElement();
    if (value) {
        return el.setAttributeSafe(name, .wrap(""), frame);
    }
    return el.removeAttribute(name, frame);
}

// draggable is enumerated, not boolean: only an ASCII case-insensitive "true"
// enables it. With no attribute the default is per-element -- measured on a
// headed Chrome 150, `img` and an `a`/`area` carrying href are draggable and
// nothing else is (an href on `link`, `base` or `object` changes nothing).
pub fn getDraggable(self: *HtmlElement) bool {
    const el = self.asElement();
    if (el.getAttributeSafe(comptime .wrap("draggable"))) |value| {
        return std.ascii.eqlIgnoreCase(value, "true");
    }
    return switch (self._type) {
        .img => true,
        .anchor, .area => el.hasAttributeSafe(comptime .wrap("href")),
        else => false,
    };
}

pub fn setDraggable(self: *HtmlElement, value: bool, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("draggable"), .wrap(if (value) "true" else "false"), frame);
}

// spellcheck and writingSuggestions are the two inherited enumerated
// attributes: the getter walks self and ancestors and answers off the first
// element whose value maps to a state. They differ in what an unrecognised
// value does, which is visible in the walk -- measured on a headed Chrome 150
// with `<div spellcheck=false><div spellcheck=garbage><span>`:
//
//   * spellcheck's invalid-value default is "inherit", so "garbage" keeps
//     walking and the span answers false. Its empty-string state is "true",
//     so an empty attribute stops the walk and answers true.
//   * writingsuggestions' invalid-value default is "true", so any value that
//     is not "false" stops the walk. Only an absent attribute keeps walking.
pub fn getSpellcheck(self: *HtmlElement) bool {
    var current: ?*Element = self.asElement();
    while (current) |el| : (current = el.parentElement()) {
        const value = el.getAttributeSafe(comptime .wrap("spellcheck")) orelse continue;
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "true")) return true;
        if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    }
    return true;
}

pub fn setSpellcheck(self: *HtmlElement, value: bool, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("spellcheck"), .wrap(if (value) "true" else "false"), frame);
}

pub fn getWritingSuggestions(self: *HtmlElement) []const u8 {
    var current: ?*Element = self.asElement();
    while (current) |el| : (current = el.parentElement()) {
        const value = el.getAttributeSafe(.wrap("writingsuggestions")) orelse continue;
        return if (std.ascii.eqlIgnoreCase(value, "false")) "false" else "true";
    }
    return "true";
}

// The setter is a plain string reflection: whatever it is given lands in the
// attribute verbatim, even though the getter only reads the two keywords.
pub fn setWritingSuggestions(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("writingsuggestions"), .wrap(value), frame);
}

// autocapitalize carries two legacy aliases -- "off" is "none" and "on" is
// "sentences" -- and an empty (or absent) attribute is the empty string while
// any other value is "sentences".
pub fn getAutocapitalize(self: *HtmlElement) []const u8 {
    const value = self.asElement().getAttributeSafe(.wrap("autocapitalize")) orelse return "";
    if (value.len == 0) return "";
    if (std.ascii.eqlIgnoreCase(value, "off")) return "none";
    if (std.ascii.eqlIgnoreCase(value, "on")) return "sentences";
    return reflection.enumeratedValue(value, &.{ "none", "sentences", "words", "characters" }, "", "sentences").?;
}

pub fn setAutocapitalize(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("autocapitalize"), .wrap(value), frame);
}

pub fn getEnterKeyHint(self: *HtmlElement) []const u8 {
    const value = self.asElement().getAttributeSafe(comptime .wrap("enterkeyhint"));
    return reflection.enumeratedValue(value, &.{ "enter", "done", "go", "next", "previous", "search", "send" }, "", "").?;
}

pub fn setEnterKeyHint(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("enterkeyhint"), .wrap(value), frame);
}

pub fn getInputMode(self: *HtmlElement) []const u8 {
    const value = self.asElement().getAttributeSafe(comptime .wrap("inputmode"));
    return reflection.enumeratedValue(value, &.{ "none", "text", "tel", "url", "email", "numeric", "decimal", "search" }, "", "").?;
}

pub fn setInputMode(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("inputmode"), .wrap(value), frame);
}

pub fn getVirtualKeyboardPolicy(self: *HtmlElement) []const u8 {
    const value = self.asElement().getAttributeSafe(.wrap("virtualkeyboardpolicy"));
    return reflection.enumeratedValue(value, &.{ "auto", "manual" }, "", "").?;
}

pub fn setVirtualKeyboardPolicy(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("virtualkeyboardpolicy"), .wrap(value), frame);
}

// contentEditable has a fourth state, "inherit", which means "no attribute" --
// so unlike every other enumerated reflection here its missing and invalid
// values are the same keyword rather than the empty string. An empty attribute
// reads as "true".
const CONTENT_EDITABLE = "contenteditable";

pub fn getContentEditable(self: *HtmlElement) []const u8 {
    const value = self.asElement().getAttributeSafe(.wrap(CONTENT_EDITABLE)) orelse return "inherit";
    if (value.len == 0) return "true";
    return reflection.enumeratedValue(value, &.{ "true", "false", "plaintext-only" }, "inherit", "inherit").?;
}

// The setter validates: "inherit" removes the attribute, the three keywords
// are normalised to lowercase, and anything else throws a SyntaxError naming
// the offending value (message measured on a headed Chrome 150).
pub fn setContentEditable(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    for ([_][]const u8{ "true", "false", "plaintext-only" }) |keyword| {
        if (std.ascii.eqlIgnoreCase(value, keyword)) {
            return self.asElement().setAttributeSafe(.wrap(CONTENT_EDITABLE), .wrap(keyword), frame);
        }
    }
    if (std.ascii.eqlIgnoreCase(value, "inherit")) {
        return self.asElement().removeAttribute(.wrap(CONTENT_EDITABLE), frame);
    }

    const local = frame.js.local orelse return error.SyntaxError;
    // DOMException.init() keeps the slice rather than copying it -- every other
    // caller hands it a literal -- so the message has to outlive this call. The
    // frame arena is the shortest-lived one that does.
    const message = std.fmt.allocPrint(
        frame.arena,
        "Failed to set the 'contentEditable' property on 'HTMLElement': The value provided ('{s}') is not one of 'true', 'false', 'plaintext-only', or 'inherit'.",
        .{value},
    ) catch return error.SyntaxError;
    const exception = local.zigValueToJs(
        @import("../DOMException.zig").init(message, "SyntaxError"),
        .{},
    ) catch return error.JsException;
    _ = local.isolate.throwException(exception.handle);
    return error.JsException;
}

// focusGroup is a DOMTokenList over the focusgroup attribute, with
// `[PutForwards=value]` on the setter. Unlike classList it declares supported
// tokens, so `supports()` answers rather than throwing -- see DOMTokenList.
pub fn getFocusGroup(self: *HtmlElement, frame: *Frame) !*@import("../collections.zig").DOMTokenList {
    return self.asElement().getTokenList(.focusgroup, frame);
}

pub fn setFocusGroup(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("focusgroup"), .wrap(value), frame);
}

// editContext is not a content attribute at all -- it is a live association
// with an EditContext object, and assigning one leaves the markup untouched.
// Measured on a headed Chrome 150 (probe-g20e/g20f/g20j): the getter is null
// until something is attached, a non-EditContext value is a TypeError, an
// element outside the host set and a context that already has a host are each
// a NotSupportedError, and the host check runs first when both would fail.
pub fn getEditContext(self: *HtmlElement, frame: *Frame) ?*EditContext {
    return frame._element_edit_contexts.get(self.asElement());
}

pub fn setEditContext(self: *HtmlElement, value: js.Value, exec: *const js.Execution) !void {
    const frame = exec.js.global.frame;
    const element = self.asElement();
    if (value.isNullOrUndefined()) {
        if (frame._element_edit_contexts.fetchRemove(element)) |entry| {
            entry.value.detach();
        }
        return;
    }
    const context = value.toZig(*EditContext) catch return dictionary.throwTypeError(
        "Failed to set the 'editContext' property on 'HTMLElement': Failed to convert value to 'EditContext'.",
        exec,
    );

    if (!EditContext.isValidHost(element)) {
        return dictionary.throwDom(
            "NotSupportedError",
            "Failed to set the 'editContext' property on 'HTMLElement': This element does not support EditContext",
            exec,
        );
    }
    context.attach(element) catch return dictionary.throwDom(
        "NotSupportedError",
        "Failed to set the 'editContext' property on 'HTMLElement': An EditContext can be only be associated with a single element",
        exec,
    );

    const gop = try frame._element_edit_contexts.getOrPut(frame.arena, element);
    if (gop.found_existing and gop.value_ptr.* != context) {
        gop.value_ptr.*.detach();
    }
    gop.value_ptr.* = context;
}

// The attribute-listener plumbing lives on Element: fullscreen handlers are
// declared there, not here, so both interfaces need it.
pub fn getAttributeFunction(
    self: *HtmlElement,
    listener_type: GlobalEventHandler,
    frame: *Frame,
) !?js.Function.Global {
    return self.asElement().getAttributeFunction(listener_type, frame);
}

pub fn hasAttributeFunction(self: *HtmlElement, listener_type: GlobalEventHandler, frame: *const Frame) bool {
    return self.asElement().hasAttributeFunction(listener_type, frame);
}

fn setAttributeListener(
    self: *HtmlElement,
    listener_type: GlobalEventHandler,
    listener_callback: ?js.Function.Global,
    frame: *Frame,
) !void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.event, "Html.setAttributeListener", .{
            .type = self._type,
            .listener_type = listener_type,
        });
    }
    return self.asElement().setAttributeListener(listener_type, listener_callback, frame);
}

pub fn setOnAbort(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onabort, callback, frame);
}

pub fn getOnAbort(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onabort, frame);
}

pub fn setOnAnimationCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationcancel, callback, frame);
}

pub fn getOnAnimationCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationcancel, frame);
}

pub fn setOnAnimationEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationend, callback, frame);
}

pub fn getOnAnimationEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationend, frame);
}

pub fn setOnAnimationIteration(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationiteration, callback, frame);
}

pub fn getOnAnimationIteration(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationiteration, frame);
}

pub fn setOnAnimationStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationstart, callback, frame);
}

pub fn getOnAnimationStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationstart, frame);
}

pub fn setOnAuxClick(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onauxclick, callback, frame);
}

pub fn getOnAuxClick(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onauxclick, frame);
}

pub fn setOnBeforeInput(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforeinput, callback, frame);
}

pub fn getOnBeforeInput(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforeinput, frame);
}

pub fn setOnBeforeMatch(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforematch, callback, frame);
}

pub fn getOnBeforeMatch(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforematch, frame);
}

pub fn setOnBeforeToggle(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforetoggle, callback, frame);
}

pub fn getOnBeforeToggle(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforetoggle, frame);
}

pub fn setOnBlur(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onblur, callback, frame);
}

pub fn getOnBlur(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onblur, frame);
}

pub fn setOnCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncancel, callback, frame);
}

pub fn getOnCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncancel, frame);
}

pub fn setOnCanPlay(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncanplay, callback, frame);
}

pub fn getOnCanPlay(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncanplay, frame);
}

pub fn setOnCanPlayThrough(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncanplaythrough, callback, frame);
}

pub fn getOnCanPlayThrough(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncanplaythrough, frame);
}

pub fn setOnChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onchange, callback, frame);
}

pub fn getOnChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onchange, frame);
}

pub fn setOnClick(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onclick, callback, frame);
}

pub fn getOnClick(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onclick, frame);
}

pub fn setOnClose(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onclose, callback, frame);
}

pub fn getOnClose(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onclose, frame);
}

pub fn setOnCommand(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncommand, callback, frame);
}

pub fn getOnCommand(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncommand, frame);
}

pub fn setOnContentVisibilityAutoStateChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontentvisibilityautostatechange, callback, frame);
}

pub fn getOnContentVisibilityAutoStateChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontentvisibilityautostatechange, frame);
}

pub fn setOnContextLost(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontextlost, callback, frame);
}

pub fn getOnContextLost(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontextlost, frame);
}

pub fn setOnContextMenu(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontextmenu, callback, frame);
}

pub fn getOnContextMenu(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontextmenu, frame);
}

pub fn setOnContextRestored(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontextrestored, callback, frame);
}

pub fn getOnContextRestored(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontextrestored, frame);
}

pub fn setOnCopy(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncopy, callback, frame);
}

pub fn getOnCopy(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncopy, frame);
}

pub fn setOnCueChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncuechange, callback, frame);
}

pub fn getOnCueChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncuechange, frame);
}

pub fn setOnCut(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncut, callback, frame);
}

pub fn getOnCut(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncut, frame);
}

pub fn setOnDblClick(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondblclick, callback, frame);
}

pub fn getOnDblClick(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondblclick, frame);
}

pub fn setOnDrag(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondrag, callback, frame);
}

pub fn getOnDrag(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondrag, frame);
}

pub fn setOnDragEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragend, callback, frame);
}

pub fn getOnDragEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragend, frame);
}

pub fn setOnDragEnter(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragenter, callback, frame);
}

pub fn getOnDragEnter(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragenter, frame);
}

pub fn setOnDragExit(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragexit, callback, frame);
}

pub fn getOnDragExit(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragexit, frame);
}

pub fn setOnDragLeave(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragleave, callback, frame);
}

pub fn getOnDragLeave(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragleave, frame);
}

pub fn setOnDragOver(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragover, callback, frame);
}

pub fn getOnDragOver(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragover, frame);
}

pub fn setOnDragStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragstart, callback, frame);
}

pub fn getOnDragStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragstart, frame);
}

pub fn setOnDrop(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondrop, callback, frame);
}

pub fn getOnDrop(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondrop, frame);
}

pub fn setOnDurationChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondurationchange, callback, frame);
}

pub fn getOnDurationChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondurationchange, frame);
}

pub fn setOnEmptied(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onemptied, callback, frame);
}

pub fn getOnEmptied(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onemptied, frame);
}

pub fn setOnEnded(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onended, callback, frame);
}

pub fn getOnEnded(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onended, frame);
}

pub fn setOnError(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onerror, callback, frame);
}

pub fn getOnError(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onerror, frame);
}

pub fn setOnFocus(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onfocus, callback, frame);
}

pub fn getOnFocus(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onfocus, frame);
}

pub fn setOnFormData(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onformdata, callback, frame);
}

pub fn getOnFormData(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onformdata, frame);
}

pub fn setOnFullscreenChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onfullscreenchange, callback, frame);
}

pub fn getOnFullscreenChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onfullscreenchange, frame);
}

pub fn setOnFullscreenError(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onfullscreenerror, callback, frame);
}

pub fn getOnFullscreenError(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onfullscreenerror, frame);
}

pub fn setOnGotPointerCapture(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ongotpointercapture, callback, frame);
}

pub fn getOnGotPointerCapture(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ongotpointercapture, frame);
}

pub fn setOnInput(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oninput, callback, frame);
}

pub fn getOnInput(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oninput, frame);
}

pub fn setOnInvalid(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oninvalid, callback, frame);
}

pub fn getOnInvalid(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oninvalid, frame);
}

pub fn setOnKeyDown(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onkeydown, callback, frame);
}

pub fn getOnKeyDown(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onkeydown, frame);
}

pub fn setOnKeyPress(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onkeypress, callback, frame);
}

pub fn getOnKeyPress(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onkeypress, frame);
}

pub fn setOnKeyUp(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onkeyup, callback, frame);
}

pub fn getOnKeyUp(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onkeyup, frame);
}

pub fn setOnLoad(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onload, callback, frame);
}

pub fn getOnLoad(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onload, frame);
}

pub fn setOnLoadedData(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onloadeddata, callback, frame);
}

pub fn getOnLoadedData(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onloadeddata, frame);
}

pub fn setOnLoadedMetadata(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onloadedmetadata, callback, frame);
}

pub fn getOnLoadedMetadata(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onloadedmetadata, frame);
}

pub fn setOnLoadStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onloadstart, callback, frame);
}

pub fn getOnLoadStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onloadstart, frame);
}

pub fn setOnLostPointerCapture(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onlostpointercapture, callback, frame);
}

pub fn getOnLostPointerCapture(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onlostpointercapture, frame);
}

pub fn setOnMouseDown(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmousedown, callback, frame);
}

pub fn getOnMouseDown(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmousedown, frame);
}

pub fn setOnMouseMove(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmousemove, callback, frame);
}

pub fn getOnMouseMove(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmousemove, frame);
}

pub fn setOnMouseOut(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseout, callback, frame);
}

pub fn getOnMouseOut(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseout, frame);
}

pub fn setOnMouseOver(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseover, callback, frame);
}

pub fn getOnMouseOver(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseover, frame);
}

pub fn setOnMouseUp(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseup, callback, frame);
}

pub fn getOnMouseUp(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseup, frame);
}

pub fn setOnPaste(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpaste, callback, frame);
}

pub fn getOnPaste(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpaste, frame);
}

pub fn setOnPause(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpause, callback, frame);
}

pub fn getOnPause(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpause, frame);
}

pub fn setOnPlay(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onplay, callback, frame);
}

pub fn getOnPlay(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onplay, frame);
}

pub fn setOnPlaying(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onplaying, callback, frame);
}

pub fn getOnPlaying(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onplaying, frame);
}

pub fn setOnPointerCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointercancel, callback, frame);
}

pub fn getOnPointerCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointercancel, frame);
}

pub fn setOnPointerDown(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerdown, callback, frame);
}

pub fn getOnPointerDown(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerdown, frame);
}

pub fn setOnPointerEnter(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerenter, callback, frame);
}

pub fn getOnPointerEnter(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerenter, frame);
}

pub fn setOnPointerLeave(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerleave, callback, frame);
}

pub fn getOnPointerLeave(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerleave, frame);
}

pub fn setOnPointerMove(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointermove, callback, frame);
}

pub fn getOnPointerMove(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointermove, frame);
}

pub fn setOnPointerOut(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerout, callback, frame);
}

pub fn getOnPointerOut(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerout, frame);
}

pub fn setOnPointerOver(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerover, callback, frame);
}

pub fn getOnPointerOver(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerover, frame);
}

pub fn setOnPointerRawUpdate(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerrawupdate, callback, frame);
}

pub fn getOnPointerRawUpdate(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerrawupdate, frame);
}

pub fn setOnPointerUp(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerup, callback, frame);
}

pub fn getOnPointerUp(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerup, frame);
}

pub fn setOnProgress(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onprogress, callback, frame);
}

pub fn getOnProgress(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onprogress, frame);
}

pub fn setOnRateChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onratechange, callback, frame);
}

pub fn getOnRateChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onratechange, frame);
}

pub fn setOnReset(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onreset, callback, frame);
}

pub fn getOnReset(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onreset, frame);
}

pub fn setOnResize(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onresize, callback, frame);
}

pub fn getOnResize(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onresize, frame);
}

pub fn setOnScroll(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onscroll, callback, frame);
}

pub fn getOnScroll(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onscroll, frame);
}

pub fn setOnScrollEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onscrollend, callback, frame);
}

pub fn getOnScrollEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onscrollend, frame);
}

pub fn setOnSecurityPolicyViolation(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onsecuritypolicyviolation, callback, frame);
}

pub fn getOnSecurityPolicyViolation(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onsecuritypolicyviolation, frame);
}

pub fn setOnSeeked(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onseeked, callback, frame);
}

pub fn getOnSeeked(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onseeked, frame);
}

pub fn setOnSeeking(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onseeking, callback, frame);
}

pub fn getOnSeeking(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onseeking, frame);
}

pub fn setOnSelect(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onselect, callback, frame);
}

pub fn getOnSelect(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onselect, frame);
}

pub fn setOnSelectionChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onselectionchange, callback, frame);
}

pub fn getOnSelectionChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onselectionchange, frame);
}

pub fn setOnSelectStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onselectstart, callback, frame);
}

pub fn getOnSelectStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onselectstart, frame);
}

pub fn setOnSlotChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onslotchange, callback, frame);
}

pub fn getOnSlotChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onslotchange, frame);
}

pub fn setOnStalled(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onstalled, callback, frame);
}

pub fn getOnStalled(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onstalled, frame);
}

pub fn setOnSubmit(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onsubmit, callback, frame);
}

pub fn getOnSubmit(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onsubmit, frame);
}

pub fn setOnSuspend(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onsuspend, callback, frame);
}

pub fn getOnSuspend(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onsuspend, frame);
}

pub fn setOnTimeUpdate(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontimeupdate, callback, frame);
}

pub fn getOnTimeUpdate(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontimeupdate, frame);
}

pub fn setOnToggle(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontoggle, callback, frame);
}

pub fn getOnToggle(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontoggle, frame);
}

pub fn setOnTouchCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontouchcancel, callback, frame);
}

pub fn getOnTouchCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontouchcancel, frame);
}

pub fn setOnTouchEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontouchend, callback, frame);
}

pub fn getOnTouchEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontouchend, frame);
}

pub fn setOnTouchMove(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontouchmove, callback, frame);
}

pub fn getOnTouchMove(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontouchmove, frame);
}

pub fn setOnTouchStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontouchstart, callback, frame);
}

pub fn getOnTouchStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontouchstart, frame);
}

pub fn setOnTransitionCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitioncancel, callback, frame);
}

pub fn getOnTransitionCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitioncancel, frame);
}

pub fn setOnTransitionEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitionend, callback, frame);
}

pub fn getOnTransitionEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitionend, frame);
}

pub fn setOnTransitionRun(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitionrun, callback, frame);
}

pub fn getOnTransitionRun(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitionrun, frame);
}

pub fn setOnTransitionStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitionstart, callback, frame);
}

pub fn getOnTransitionStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitionstart, frame);
}

pub fn setOnVolumeChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onvolumechange, callback, frame);
}

pub fn getOnVolumeChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onvolumechange, frame);
}

pub fn setOnWaiting(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwaiting, callback, frame);
}

pub fn getOnWaiting(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwaiting, frame);
}

pub fn setOnWheel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwheel, callback, frame);
}

pub fn getOnWheel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwheel, frame);
}

pub fn setOnMouseEnter(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseenter, callback, frame);
}

pub fn getOnMouseEnter(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseenter, frame);
}

pub fn setOnMouseLeave(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseleave, callback, frame);
}

pub fn getOnMouseLeave(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseleave, frame);
}

pub fn setOnMouseWheel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmousewheel, callback, frame);
}

pub fn getOnMouseWheel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmousewheel, frame);
}

pub fn setOnBeforeXrSelect(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforexrselect, callback, frame);
}

pub fn getOnBeforeXrSelect(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforexrselect, frame);
}

pub fn setOnScrollSnapChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onscrollsnapchange, callback, frame);
}

pub fn getOnScrollSnapChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onscrollsnapchange, frame);
}

pub fn setOnScrollSnapChanging(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onscrollsnapchanging, callback, frame);
}

pub fn getOnScrollSnapChanging(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onscrollsnapchanging, frame);
}

pub fn setOnWebkitAnimationEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwebkitanimationend, callback, frame);
}

pub fn getOnWebkitAnimationEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwebkitanimationend, frame);
}

pub fn setOnWebkitAnimationIteration(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwebkitanimationiteration, callback, frame);
}

pub fn getOnWebkitAnimationIteration(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwebkitanimationiteration, frame);
}

pub fn setOnWebkitAnimationStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwebkitanimationstart, callback, frame);
}

pub fn getOnWebkitAnimationStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwebkitanimationstart, frame);
}

pub fn setOnWebkitTransitionEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwebkittransitionend, callback, frame);
}

pub fn getOnWebkitTransitionEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwebkittransitionend, frame);
}

// HTML "rules for parsing integers", for callers that want an i32 (tabindex);
// out-of-range values parse as failure.
pub fn parseInteger(input: []const u8) ?i32 {
    const value = reflection.parseInteger(input) orelse return null;
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
        return null;
    }
    return @intCast(value);
}

/// What `white-space-collapse` keeps of a run of document white space, which is
/// what innerText reports: it is defined on the RENDERED text, so the two
/// answer together. `preserve` (from `pre` and `pre-wrap`) and `break-spaces`
/// keep the spaces and the breaks; `preserve-breaks` (from `pre-line`) keeps
/// only the breaks; `collapse` (from `normal` and `nowrap`) keeps neither.
///
/// This used to be `tag == .pre`, which is right for a <pre> only because the UA
/// stylesheet gives one `white-space: pre` -- and wrong in both directions for
/// anything else. Measured on Chrome 151, scratch/b84/expr-b84-innertext.js.
const WhiteSpace = enum {
    collapse,
    preserve_breaks,
    preserve,

    fn of(declared: []const u8) WhiteSpace {
        if (std.ascii.eqlIgnoreCase(declared, "preserve")) return .preserve;
        if (std.ascii.eqlIgnoreCase(declared, "break-spaces")) return .preserve;
        if (std.ascii.eqlIgnoreCase(declared, "preserve-breaks")) return .preserve_breaks;
        return .collapse;
    }

    fn keepsSpaces(self: WhiteSpace) bool {
        return self == .preserve;
    }

    fn keepsBreaks(self: WhiteSpace) bool {
        return self != .collapse;
    }
};

const InnerTextState = struct {
    writer: *std.Io.Writer,

    // Needed to reach the StyleManager for CSS-driven visibility (display:none).
    frame: *Frame,

    // number of line breaks we've accumulated for the block. Emitted lazily that
    // leading/trailing breaks aren't written and so that we can emit the max
    // requested, which can change as we render children.
    pending_breaks: u8 = 0,

    // suppresses leading line breaks if nothing has been written yet
    wrote_any: bool = false,

    // A collapsible space is pending from a previous text run, it should only
    // be written if there's more to write
    pre_w: bool = false,

    // Trim leading whitespace of the next text run.
    trim_left: bool = true,

    // The pending breaks came from inside an atomic inline box rather than from
    // a block boundary of this run. Such a box is its own formatting context, so
    // its break does not collapse the whitespace of the run around it. Measured
    // on Chrome 151 (probe d4-space):
    //   `a <span style="display:inline-flex"><span>M</span></span> b`
    // reads "a \nM\n b", where the same shape with a plain block reads "a\nM\nb".
    breaks_inside_atomic: bool = false,

    // What `white-space-collapse` leaves in the rendered text of the element
    // whose children we are walking. Threaded rather than resolved per element,
    // for the reason `visibility` below is: the property inherits, so the walk
    // already carries it, and only an element with a declaration of its own
    // pays a lookup.
    white_space: WhiteSpace = .collapse,

    // The computed text-transform of the element whose children we are walking.
    // innerText is defined in terms of layout, so it reports rendered casing.
    // Resolved per element rather than threaded down, because
    // computedTextTransform already walks ancestors -- inheritance comes from
    // that walk, and a descendant's own declaration overrides it for free.
    transform: text_case.Transform = .none,

    // Whether the next letter starts a word, for `capitalize`. Lives here and
    // not in the per-node write so a word split across text nodes or element
    // boundaries is still one word.
    at_word_start: bool = true,

    // The computed `visibility` of the element whose children we are walking:
    // text is rendered only when its nearest element ancestor is visible.
    // Threaded rather than resolved per element because `visibility` inherits,
    // so the walk we are already doing carries the value for free -- and a
    // descendant declaring `visible` inside a hidden subtree turns it back on
    // (Chrome 151, probe w1-visibility).
    visible: bool = true,

    fn requireBreaks(self: *InnerTextState, n: u8) void {
        if (n > self.pending_breaks) {
            self.pending_breaks = n;
        }
        // A boundary of this run's own, so it collapses this run's whitespace
        // even if an atomic inline box just handed us a break that would not.
        self.breaks_inside_atomic = false;
    }

    fn flushBreaks(self: *InnerTextState) !void {
        if (self.pending_breaks == 0) {
            return;
        }
        const atomic = self.breaks_inside_atomic;
        if (self.wrote_any) {
            if (atomic and self.pre_w) {
                // The space belongs to the run outside the box, which the box's
                // own break does not reach into.
                try self.writer.writeByte(' ');
            }
            for (0..self.pending_breaks) |_| {
                try self.writer.writeByte('\n');
            }
        }
        self.pending_breaks = 0;
        self.breaks_inside_atomic = false;
        self.pre_w = false;
        // A block boundary trims the whitespace on either side of it; a break
        // that only escaped an atomic inline box does not.
        self.trim_left = !atomic;
    }

    // The boundary of a block box whose own visibility is hidden. Such a box
    // contributes no line break of its own, but it is still a box: it trims the
    // collapsible whitespace on either side of it exactly as a visible block
    // boundary does. Chrome 151 (probe w1b-visibility):
    // `a <div style="visibility:hidden">M</div> b` reads "ab", where the same
    // shape with display:none reads "a b" -- absent, so the two spaces merge.
    // pending_breaks is deliberately left alone: a *visible* block nested inside
    // may have armed one, and that break has to survive out here.
    fn hiddenBlockBoundary(self: *InnerTextState) void {
        self.pre_w = false;
        self.trim_left = true;
    }

    // Emit a literal separator (table cell tab / row newline).
    fn writeSeparator(self: *InnerTextState, ch: u8) !void {
        try self.flushBreaks();
        try self.writer.writeByte(ch);
        self.wrote_any = true;
        self.pre_w = false;
        self.trim_left = true;
    }
};

const ChildFilter = enum { none, select, optgroup };

fn collectInnerText(self: *HtmlElement, state: *InnerTextState) std.Io.Writer.Error!void {
    const el = self.asElement();
    const self_tag = el.getTag();

    // special filtering type applied to children based on the tag
    const child_filter: ChildFilter = switch (self_tag) {
        .select => .select,
        .optgroup => .optgroup,
        else => .none,
    };

    // Inside table containers, inter-cell/row whitespace text is not rendered.
    const table_ctx = switch (self_tag) {
        .table, .tbody, .thead, .tfoot, .tr => true,
        else => false,
    };

    // Track whether we've already emitted a cell/row in this parent so we can
    // insert tab/newline separators *between* them.
    var saw_row = false;
    var saw_cell = false;

    var it = el.asNode().childrenIterator();
    while (it.next()) |child| {
        switch (child._type) {
            .element => {
                const e = child.subtype(Node.Element);
                switch (e._type) {
                    .svg, .mathml, .plain => {},
                    .html => {
                        const tag = e.getTag();
                        switch (child_filter) {
                            .none => {},
                            .select => if (tag != .option and tag != .optgroup) continue,
                            .optgroup => if (tag != .option) continue,
                        }
                        try handleChildElement(e.subtype(HtmlElement), tag, state, &saw_cell, &saw_row);
                    },
                }
            },
            .cdata => {
                const c = child.subtype(Node.CData);
                switch (c._type) {
                    .text => {
                        if (child_filter != .none) {
                            // Text directly inside <select>/<optgroup> is skipped
                            continue;
                        }
                        if (table_ctx and isAllAsciiWhitespace(c.getData().str())) {
                            continue;
                        }
                        try writeText(c, state);
                    },
                    .comment, .cdata_section, .processing_instruction => {},
                }
            },
            else => {},
        }
    }
}

const Display = enum { skip, replaced, @"inline", atomic_inline, block, block_p, transparent, table_cell, table_row };

fn handleChildElement(
    he: *HtmlElement,
    tag: Element.Tag,
    state: *InnerTextState,
    saw_cell: *bool,
    saw_row: *bool,
) !void {
    // doesn't use StyleManger's isHidden, because we don't care if the element
    // is hidden through its parent. If you can el.innerText on an element, the
    // visibility of el.parent doesn't matter. So we only care about visibility
    // on the element itself and then on each child. This is much simpler too.
    if (state.frame._style_manager.hasDisplayNone(he.asElement())) {
        return;
    }

    // This element's computed `visibility`, restored on the way out. Only its own
    // declaration is looked up: the value it inherits is whatever the walk
    // brought here, so a subtree with no declaration of its own costs nothing.
    const outer_visible = state.visible;
    defer state.visible = outer_visible;
    if (state.frame._style_manager.declaredVisibility(he.asElement())) |declared| {
        state.visible = !declared.hides();
    }
    const visible = state.visible;

    if (he._type == .br) {
        // A hidden <br> is silent (Chrome 151, probe w1b-visibility:
        // `a<div style="visibility:hidden"><br></div>b` reads "ab").
        if (!visible) {
            return;
        }
        try state.flushBreaks();
        try state.writer.writeByte('\n');
        state.wrote_any = true;
        state.pre_w = false;
        state.trim_left = true;
        return;
    }

    // This element's own computed value, restored on the way out.
    const outer_transform = state.transform;
    defer state.transform = outer_transform;
    state.transform = state.frame._style_manager.computedTextTransform(he.asElement());

    // And its own `white-space-collapse`, on the same terms as `visibility`
    // above: only its own declaration is looked up, because what it inherits is
    // what the walk brought here.
    const outer_white_space = state.white_space;
    defer state.white_space = outer_white_space;
    if (CSSStyleDeclaration.declaredWhiteSpaceCollapse(he.asElement(), state.frame)) |declared| {
        state.white_space = WhiteSpace.of(declared);
    }

    switch (innerTextDisplay(he, tag, state.frame)) {
        // Not rendered: skip the subtree entirely (script/style/metadata/...).
        .skip => {},
        // Replaced/embedded content: the subtree is not rendered.
        .replaced => {},
        // A hidden inline box needs nothing of its own: what keeps the spaces on
        // either side of it apart is the zero-width text run inside it, which
        // writeText handles. Measured on Chrome 151 (probe w2-boundary):
        // `a <span style="visibility:hidden">M</span> b` reads "a  b" but
        // `a <span style="visibility:hidden"></span> b` reads "a b" -- an empty
        // hidden inline merges them, where an empty inline-block keeps both.
        .@"inline", .transparent => try he.collectInnerText(state),
        // An atomic inline box is content in the run around it, and its own
        // formatting context inside. So a space pending before it is written
        // rather than collapsed by whatever the box contains; the box's own
        // leading whitespace is trimmed; and the run resuming after it keeps
        // its leading space. Chrome 151 (probe d4-space3) is emphatic about
        // this: an empty `a <span style="display:inline-block"></span> b`
        // reads "a  b", with both spaces intact.
        .atomic_inline => {
            if (state.pre_w) {
                try state.writer.writeByte(' ');
                state.pre_w = false;
            }
            state.trim_left = true;
            try he.collectInnerText(state);
            state.breaks_inside_atomic = true;
            state.pre_w = false;
            state.trim_left = false;
        },
        // A hidden block box arms no break of its own -- not even <p>'s blank
        // line, whose two come from the UA margin. Its children still recurse and
        // still arm theirs, which is what makes
        // `a<div style="visibility:hidden"><div style="visibility:visible">M</div></div>b`
        // read "a\nM\nb" where the same with a visible span inside reads "aMb".
        .block => {
            if (visible) state.requireBreaks(1) else state.hiddenBlockBoundary();
            try he.collectInnerText(state);
            if (visible) state.requireBreaks(1) else state.hiddenBlockBoundary();
        },
        .block_p => {
            if (visible) state.requireBreaks(2) else state.hiddenBlockBoundary();
            try he.collectInnerText(state);
            if (visible) state.requireBreaks(2) else state.hiddenBlockBoundary();
        },
        // A hidden cell or row contributes no separator and does not count as one
        // for the next sibling either, the same way a hidden block contributes no
        // break. Chrome 151 (probe w2-boundary): a three-cell row whose middle
        // cell is hidden reads "M\tP", with one tab, and a three-row table whose
        // middle row is hidden reads "M\nP".
        .table_cell => {
            if (visible) {
                if (saw_cell.*) {
                    try state.writeSeparator('\t');
                }
                saw_cell.* = true;
            }
            try he.collectInnerText(state);
        },
        .table_row => {
            if (visible) {
                if (saw_row.*) {
                    try state.writeSeparator('\n');
                }
                saw_row.* = true;
            }
            try he.collectInnerText(state);
        },
    }
}

/// How far up `isBeingRendered` walks before giving up, matching the ceiling the
/// style manager's own inheritance walks use.
const max_render_ancestor_depth = 100;

/// Does `he` generate a box? innerText asks this first, and the answer is not
/// the element's own `display` alone: having no box is inherited downwards, so
/// an element inside `<head>`, inside a `<template>`, inside a `display: none`
/// subtree, or in no document at all has none however its own `display`
/// computes.
fn isBeingRendered(he: *HtmlElement, tag: Element.Tag, frame: *Frame) bool {
    if (innerTextTagDisplay(he, tag) == .skip) {
        return false;
    }
    if (!he.asNode().isConnected()) {
        return false;
    }
    if (declaresDisplayNone(he.asElement(), frame)) {
        return false;
    }

    var current = he.asElement().parentElement();
    var depth: usize = 0;
    while (current) |element| : (depth += 1) {
        if (depth >= max_render_ancestor_depth) {
            break;
        }
        if (element.is(HtmlElement)) |ancestor| {
            if (innerTextTagDisplay(ancestor, element.getTag()) == .skip) {
                return false;
            }
        }
        if (declaresDisplayNone(element, frame)) {
            return false;
        }
        current = element.parentElement();
    }
    return true;
}

/// `display: none` as cascaded onto `element` itself. `display` does not
/// inherit, so this is one lookup per ancestor rather than a walk of its own.
fn declaresDisplayNone(element: *Element, frame: *Frame) bool {
    const value = frame._style_manager.computedDisplay(element) orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, &std.ascii.whitespace), "none");
}

/// Which of innerText's categories `he` falls into. innerText is defined in
/// terms of layout, so the computed `display` decides -- the per-tag default is
/// only what stands when nothing declares one.
fn innerTextDisplay(he: *HtmlElement, tag: Element.Tag, frame: *Frame) Display {
    const fallback = innerTextTagDisplay(he, tag);
    switch (fallback) {
        // Never rendered, or replaced content whose subtree is not text: no
        // author `display` brings either into innerText.
        .skip, .replaced => return fallback,
        // <p> is the measured exception. Its blank line comes from the UA
        // margin rather than from its display, so it survives display:inline
        // (Chrome 151, probe d4-cases: `a<p style="display:inline">M</p>b`
        // reads "a\n\nM\n\nb", not "aMb").
        .block_p => return fallback,
        else => {},
    }

    const element = he.asElement();
    const style_manager = &frame._style_manager;
    const blockified = if (element.parentElement()) |parent|
        style_manager.blockifiesChildren(parent)
    else
        false;

    const declared = style_manager.computedDisplay(element) orelse {
        // Nothing declares one, so the per-tag default stands -- unless a flex
        // or grid parent has turned it block-level. Every default reaching here
        // is a real box, and blockify turns all of those block-level.
        return if (blockified) .block else fallback;
    };

    const resolved = if (blockified) StyleManager.blockify(declared) else declared;
    return innerTextDisplayOf(resolved) orelse fallback;
}

/// Where a `display` keyword puts an element for innerText's purposes. Measured
/// on Chrome 151 (probes d1-matrix and d4-cases): a block-level outer display
/// breaks a line, an inline-level one does not, and `contents` generates no box
/// of its own so its children are walked in place. Null for a keyword not listed
/// here, which leaves the caller's per-tag default standing rather than guessing.
fn innerTextDisplayOf(value: []const u8) ?Display {
    const map = .{
        .{ "block", Display.block },
        .{ "flex", Display.block },
        .{ "grid", Display.block },
        .{ "table", Display.block },
        .{ "list-item", Display.block },
        .{ "flow-root", Display.block },
        .{ "table-caption", Display.block },
        .{ "block ruby", Display.block },
        .{ "inline", Display.@"inline" },
        .{ "inline-block", Display.atomic_inline },
        .{ "inline-flex", Display.atomic_inline },
        .{ "inline-grid", Display.atomic_inline },
        .{ "inline-table", Display.atomic_inline },
        .{ "ruby", Display.@"inline" },
        .{ "ruby-text", Display.@"inline" },
        .{ "ruby-base", Display.@"inline" },
        .{ "table-cell", Display.table_cell },
        .{ "table-row", Display.table_row },
        .{ "table-row-group", Display.transparent },
        .{ "table-header-group", Display.transparent },
        .{ "table-footer-group", Display.transparent },
        .{ "contents", Display.transparent },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(value, entry[0])) {
            return entry[1];
        }
    }
    return null;
}

fn innerTextTagDisplay(he: *HtmlElement, tag: Element.Tag) Display {
    return switch (he._type) {
        .br => .@"inline", // handled before this point
        .p => .block_p,
        .table_cell => .table_cell,
        .table_row => .table_row,
        .table_caption => .block,
        // Row groups / column groups are transparent: no break of their own.
        .table_section => .transparent,
        .table_col => .skip,
        .option, .optgroup => .block,
        // Replaced / embedded content whose subtree is not part of innerText.
        .img, .canvas, .iframe, .embed, .object, .media, .input, .textarea => .replaced,
        // Never-rendered elements (UA display:none / not parsed as content).
        .script, .style, .template, .head, .base, .link, .meta, .title, .source, .track, .param, .area, .datalist => .skip,
        else => if (tag.isHiddenByUaStylesheet())
            .skip
        else if (isInnerTextBlockTag(tag))
            .block
        else
            .@"inline",
    };
}

fn isInnerTextBlockTag(tag: Element.Tag) bool {
    if (tag.isBlock()) {
        return true;
    }
    return switch (tag) {
        .summary, .details, .dialog, .menu, .dd, .dt, .form, .li => true,
        else => false,
    };
}

fn isAllAsciiWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) {
            return false;
        }
    }
    return true;
}

// `uppercase` / `lowercase` / `capitalize`, ASCII only. The non-ASCII cases need
// Unicode case tables we do not carry; a byte above 0x7F passes through, which
// is wrong for those scripts and right for the Latin text every detector reads.
// Writes `s` with the current text-transform applied, updating the word-start
// flag so `capitalize` survives a word split across nodes.
//
// The mapping itself is `text_case`, shared with the measurement. It used to be
// here, byte by byte over ASCII, and the measurement had no transform at all --
// so an element read as uppercase and measured as though it did not. Three
// things were wrong in this copy besides: the word-start flag reset on white
// space alone, where Chrome resets on every separator ('x-ray' -> 'X-Ray', not
// 'X-ray'); `'` and U+00AD and U+00B7 join a word rather than separating it;
// and no Latin-1 character mapped at all.
//
// A codepoint at a time rather than through `text_case.write`, because there is
// a writer here and no buffer to size.
fn writeTransformed(state: *InnerTextState, s: []const u8) !void {
    const writer = state.writer;
    if (state.transform == .none) {
        return writer.writeAll(s);
    }
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.i < s.len) {
        const before = it.i;
        const codepoint = it.nextCodepoint() orelse {
            // Invalid UTF-8: the bytes as written, which is what every other
            // path in this file does with them.
            try writer.writeAll(s[before..]);
            return;
        };
        const mapped = text_case.map(codepoint, state.transform, &state.at_word_start);
        var buf: [4]u8 = undefined;
        const first = std.unicode.utf8Encode(mapped.first, &buf) catch {
            try writer.writeAll(s[before..it.i]);
            continue;
        };
        try writer.writeAll(buf[0..first]);
        if (mapped.second) |second| {
            const extra = std.unicode.utf8Encode(second, &buf) catch continue;
            try writer.writeAll(buf[0..extra]);
        }
    }
}

fn writeText(c: *Node.CData, state: *InnerTextState) !void {
    const writer = state.writer;

    const s = c.getData().str();

    // Hidden text: zero-width, but still a run in the inline flow. It writes no
    // characters of its own, yet the collapsible spaces on either side of it do
    // not merge across it -- Chrome 151 (probe w2-boundary) reads
    // `a <span style="visibility:hidden">M</span> b` as "a  b" and the same with
    // an empty span as "a b", so it is the run and not the box that separates
    // them. `display: none` merges them, which is why the two cannot share this.
    if (!state.visible) {
        // Whitespace has nothing to separate, and a pending block break already
        // trims both sides: a zero-width run may not undo either.
        if (state.pending_breaks != 0 or isAllAsciiWhitespace(s)) {
            return;
        }
        if (state.pre_w) {
            try writer.writeByte(' ');
            state.pre_w = false;
        }
        // Not wrote_any: nothing was rendered, so a leading break stays suppressed.
        state.trim_left = false;
        return;
    }
    if (state.white_space.keepsSpaces()) {
        if (s.len == 0) {
            return;
        }
        try state.flushBreaks();
        // Verbatim, carriage returns and all: `a&#13;b` reads back with the CR
        // still in it in Chrome 151. This used to normalise CR and CRLF to a
        // line feed, which is what the PARSER does to a source document -- a CR
        // that survives into a text node came from script or from a character
        // reference, and innerText hands it back.
        try writeTransformed(state, s);
        state.wrote_any = true;
        state.pre_w = false;
        state.trim_left = false;
        return;
    }

    if (!state.white_space.keepsBreaks()) {
        return writeCollapsedRun(state, c, s);
    }

    // `preserve-breaks`: the line feeds are written and each run between two of
    // them collapses on its own. The break is written STRAIGHT OUT rather than
    // armed as a pending one, because a leading break survives where a block
    // boundary's does not -- `<div style="white-space:pre-line">\na</div>` reads
    // "\na" in Chrome, and the same shape with a leading <div> reads "a".
    var rest = s;
    while (true) {
        const feed = std.mem.indexOfScalar(u8, rest, '\n');
        try writeCollapsedRun(state, c, rest[0 .. feed orelse rest.len]);
        const at = feed orelse return;
        try state.flushBreaks();
        try writer.writeByte('\n');
        state.wrote_any = true;
        // A break trims the collapsible white space on either side of it, the
        // same as the block boundary it stands in for.
        state.pre_w = false;
        state.trim_left = true;
        rest = rest[at + 1 ..];
    }
}

/// One run of collapsible text: a run of document white space becomes one space,
/// and one at either end of the run becomes nothing.
///
/// `c` is only along for its `render`, which reads the node's data; a run that is
/// a SLICE of it -- which is what `preserve-breaks` hands over -- goes through
/// renderText instead.
fn writeCollapsedRun(state: *InnerTextState, c: *Node.CData, s: []const u8) !void {
    if (isAllAsciiWhitespace(s)) {
        // A run of collapsible whitespace collapses to one space, so a space
        // already pending stays pending: this node adds nothing but takes
        // nothing away either. Clearing it is what made iphey's
        // `Looks <span> <span>Trustworthy</span> </span>` read LooksTrustworthy.
        // `wrote_any` still gates it, so leading whitespace is dropped, and
        // trim_left without a pending space means a block boundary already
        // trimmed here -- neither may start a space.
        //
        // An EMPTY run is neither: it is the nothing between two line feeds, and
        // it may not arm a space that was not in the text.
        if (s.len != 0) {
            state.pre_w = state.wrote_any and (state.pre_w or state.trim_left == false);
        }
        return;
    }

    try state.flushBreaks();
    if (state.pre_w) {
        try writeTransformed(state, " ");
    }
    const whole = s.len == c.getData().str().len;
    if (state.transform == .none) {
        state.pre_w = if (whole)
            try c.render(state.writer, .{ .trim_left = state.trim_left })
        else
            try Node.CData.renderText(s, state.writer, .{ .trim_left = state.trim_left });
    } else {
        // render() writes straight to the writer, so the transform cannot wrap
        // it in place: render once into the frame arena, then transform the
        // bytes it produced. innerText is not a hot path.
        var run = std.Io.Writer.Allocating.init(state.frame.local_arena);
        state.pre_w = if (whole)
            try c.render(&run.writer, .{ .trim_left = state.trim_left })
        else
            try Node.CData.renderText(s, &run.writer, .{ .trim_left = state.trim_left });
        try writeTransformed(state, run.written());
    }
    state.wrote_any = true;
    state.trim_left = state.pre_w;
}

fn mergeTextNodes(left_node: *Node, right_node: *Node, frame: *Frame) !bool {
    const left = left_node.is(Node.CData) orelse return false;
    const right = right_node.is(Node.CData) orelse return false;
    if (left._type != .text or right._type != .text) return false;

    // both nodes are Text nodes

    const merged = try std.mem.concat(frame.local_arena, u8, &.{ left.getData().str(), right.getData().str() });
    // set the left node to the merged value
    try left.setData(merged, frame);

    if (right_node.parentNode()) |p| {
        // remove right node
        frame.removeNode(p, right_node, .{ .reconnect_to = null });
    }
    return true;
}

fn renderedTextFragment(value: []const u8, frame: *Frame) ![]Node.NodeOrText {
    const arena = frame.local_arena;
    var nodes: std.ArrayList(Node.NodeOrText) = .empty;

    var rest = value;
    while (true) {
        const text_end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
        if (text_end > 0) {
            try nodes.append(arena, .{ .text = rest[0..text_end] });
        }
        rest = rest[text_end..];
        if (rest.len == 0) {
            return nodes.items;
        }

        // Each line break becomes one <br>; a CR/LF pair counts as a single
        // break (so "\r\n" is one <br> but "\n\n" is two).
        const break_len: usize = if (rest[0] == '\r' and rest.len > 1 and rest[1] == '\n') 2 else 1;

        try nodes.append(arena, .{ .node = try Frame.node_factory.createElementNS(frame, .html, "br", null) });
        rest = rest[break_len..];
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HtmlElement);

    pub const Meta = struct {
        pub const name = "HTMLElement";
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "focusGroupStart";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn _innerText(self: *HtmlElement, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerText(&buf.writer, frame);
        return buf.written();
    }
    fn _setInnerText(self: *HtmlElement, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString]`: a JS null becomes "", not "null".
        return self.setInnerText(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }
    fn _setOuterText(self: *HtmlElement, value: js.Value, frame: *Frame) !void {
        return self.setOuterText(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }
    // Two absences on purpose. `insertAdjacentHTML` is Element's alone --
    // Element.zig already forwards to HtmlElement.insertAdjacentHTML, and
    // declaring it on both put a member on HTMLElement.prototype that no
    // browser has. `accessKeyLabel` is Gecko-only.
    //
    // The `pub const` members below are in Chrome 150's own-property order
    // (probe-g20a), because that order is itself a fingerprint surface: the
    // bridge emits them in declaration order. The one difference we cannot
    // close is `constructor`, which V8 always puts last while Chrome has
    // `onpointerrawupdate` after it.

    // Declared here rather than on Element because Chrome declares them here:
    // an SVG or MathML element has no style, no dataset, no offset geometry and
    // cannot be focused. The behaviour stays on Element; only the name moves.
    fn _dataset(self: *HtmlElement, frame: *Frame) !*@import("DOMStringMap.zig") {
        return self.asElement().getDataset(frame);
    }
    fn _style(self: *HtmlElement, frame: *Frame) !*@import("../css/CSSStyleDeclaration.zig") {
        return self.asElement().getOrCreateStyle(frame);
    }
    fn _setStyle(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
        return self.asElement().setStyle(value, frame);
    }
    /// Measured on Chrome 150: `attributeStyleMap` sits on
    /// HTMLElement.prototype (not Element.prototype) and is a StylePropertyMap
    /// over the same declaration `style` hands out.
    fn _attributeStyleMap(self: *HtmlElement, frame: *Frame) !*@import("../css/typed_om.zig").StylePropertyMap {
        const declaration = try self.asElement().getOrCreateStyle(frame);
        return declaration.getPropertyMap(frame);
    }
    fn _offsetTop(self: *HtmlElement, frame: *Frame) f64 {
        return self.asElement().getOffsetTop(frame);
    }
    fn _offsetLeft(self: *HtmlElement, frame: *Frame) f64 {
        return self.asElement().getOffsetLeft(frame);
    }
    fn _offsetWidth(self: *HtmlElement, frame: *Frame) f64 {
        return self.asElement().getOffsetWidth(frame);
    }
    fn _offsetHeight(self: *HtmlElement, frame: *Frame) f64 {
        return self.asElement().getOffsetHeight(frame);
    }
    fn _offsetParent(self: *HtmlElement, frame: *Frame) ?*Element {
        return self.asElement().getOffsetParent(frame);
    }
    fn _focus(self: *HtmlElement, frame: *Frame) !void {
        return self.asElement().focus(frame);
    }
    fn _blur(self: *HtmlElement, frame: *Frame) !void {
        return self.asElement().blur(frame);
    }

    pub const title = bridge.accessor(HtmlElement.getTitle, HtmlElement.setTitle, .{ .ce_reactions = true });
    pub const lang = bridge.accessor(HtmlElement.getLang, HtmlElement.setLang, .{ .ce_reactions = true });
    pub const translate = bridge.accessor(HtmlElement.getTranslate, HtmlElement.setTranslate, .{ .ce_reactions = true });
    pub const dir = bridge.accessor(HtmlElement.getDir, HtmlElement.setDir, .{ .ce_reactions = true });
    pub const hidden = bridge.accessor(HtmlElement.getHidden, HtmlElement.setHidden, .{ .ce_reactions = true });
    pub const inert = bridge.accessor(HtmlElement.getInert, HtmlElement.setInert, .{ .ce_reactions = true });
    pub const accessKey = bridge.accessor(HtmlElement.getAccessKey, HtmlElement.setAccessKey, .{ .ce_reactions = true });
    pub const draggable = bridge.accessor(HtmlElement.getDraggable, HtmlElement.setDraggable, .{ .ce_reactions = true });
    pub const spellcheck = bridge.accessor(HtmlElement.getSpellcheck, HtmlElement.setSpellcheck, .{ .ce_reactions = true });
    pub const autocapitalize = bridge.accessor(HtmlElement.getAutocapitalize, HtmlElement.setAutocapitalize, .{ .ce_reactions = true });
    pub const editContext = bridge.accessor(HtmlElement.getEditContext, HtmlElement.setEditContext, .{});
    pub const contentEditable = bridge.accessor(HtmlElement.getContentEditable, HtmlElement.setContentEditable, .{ .ce_reactions = true });
    pub const enterKeyHint = bridge.accessor(HtmlElement.getEnterKeyHint, HtmlElement.setEnterKeyHint, .{ .ce_reactions = true });
    pub const isContentEditable = bridge.accessor(HtmlElement.getIsContentEditable, null, .{});
    pub const inputMode = bridge.accessor(HtmlElement.getInputMode, HtmlElement.setInputMode, .{ .ce_reactions = true });
    pub const virtualKeyboardPolicy = bridge.accessor(HtmlElement.getVirtualKeyboardPolicy, HtmlElement.setVirtualKeyboardPolicy, .{ .ce_reactions = true });
    pub const offsetParent = bridge.accessor(_offsetParent, null, .{});
    pub const offsetTop = bridge.accessor(_offsetTop, null, .{});
    pub const offsetLeft = bridge.accessor(_offsetLeft, null, .{});
    pub const offsetWidth = bridge.accessor(_offsetWidth, null, .{});
    pub const offsetHeight = bridge.accessor(_offsetHeight, null, .{});
    pub const popover = bridge.accessor(HtmlElement.getPopover, HtmlElement.setPopover, .{ .ce_reactions = true });
    pub const innerText = bridge.accessor(_innerText, _setInnerText, .{ .ce_reactions = true });
    pub const outerText = bridge.accessor(_innerText, _setOuterText, .{ .ce_reactions = true });
    pub const writingSuggestions = bridge.accessor(HtmlElement.getWritingSuggestions, HtmlElement.setWritingSuggestions, .{ .ce_reactions = true });
    pub const onabort = bridge.accessor(HtmlElement.getOnAbort, HtmlElement.setOnAbort, .{});
    pub const onbeforeinput = bridge.accessor(HtmlElement.getOnBeforeInput, HtmlElement.setOnBeforeInput, .{});
    pub const onbeforematch = bridge.accessor(HtmlElement.getOnBeforeMatch, HtmlElement.setOnBeforeMatch, .{});
    pub const onbeforetoggle = bridge.accessor(HtmlElement.getOnBeforeToggle, HtmlElement.setOnBeforeToggle, .{});
    pub const onblur = bridge.accessor(HtmlElement.getOnBlur, HtmlElement.setOnBlur, .{});
    pub const oncancel = bridge.accessor(HtmlElement.getOnCancel, HtmlElement.setOnCancel, .{});
    pub const oncanplay = bridge.accessor(HtmlElement.getOnCanPlay, HtmlElement.setOnCanPlay, .{});
    pub const oncanplaythrough = bridge.accessor(HtmlElement.getOnCanPlayThrough, HtmlElement.setOnCanPlayThrough, .{});
    pub const onchange = bridge.accessor(HtmlElement.getOnChange, HtmlElement.setOnChange, .{});
    pub const onclick = bridge.accessor(HtmlElement.getOnClick, HtmlElement.setOnClick, .{});
    pub const onclose = bridge.accessor(HtmlElement.getOnClose, HtmlElement.setOnClose, .{});
    pub const oncommand = bridge.accessor(HtmlElement.getOnCommand, HtmlElement.setOnCommand, .{});
    pub const oncontentvisibilityautostatechange = bridge.accessor(HtmlElement.getOnContentVisibilityAutoStateChange, HtmlElement.setOnContentVisibilityAutoStateChange, .{});
    pub const oncontextlost = bridge.accessor(HtmlElement.getOnContextLost, HtmlElement.setOnContextLost, .{});
    pub const oncontextmenu = bridge.accessor(HtmlElement.getOnContextMenu, HtmlElement.setOnContextMenu, .{});
    pub const oncontextrestored = bridge.accessor(HtmlElement.getOnContextRestored, HtmlElement.setOnContextRestored, .{});
    pub const oncuechange = bridge.accessor(HtmlElement.getOnCueChange, HtmlElement.setOnCueChange, .{});
    pub const ondblclick = bridge.accessor(HtmlElement.getOnDblClick, HtmlElement.setOnDblClick, .{});
    pub const ondrag = bridge.accessor(HtmlElement.getOnDrag, HtmlElement.setOnDrag, .{});
    pub const ondragend = bridge.accessor(HtmlElement.getOnDragEnd, HtmlElement.setOnDragEnd, .{});
    pub const ondragenter = bridge.accessor(HtmlElement.getOnDragEnter, HtmlElement.setOnDragEnter, .{});
    pub const ondragleave = bridge.accessor(HtmlElement.getOnDragLeave, HtmlElement.setOnDragLeave, .{});
    pub const ondragover = bridge.accessor(HtmlElement.getOnDragOver, HtmlElement.setOnDragOver, .{});
    pub const ondragstart = bridge.accessor(HtmlElement.getOnDragStart, HtmlElement.setOnDragStart, .{});
    pub const ondrop = bridge.accessor(HtmlElement.getOnDrop, HtmlElement.setOnDrop, .{});
    pub const ondurationchange = bridge.accessor(HtmlElement.getOnDurationChange, HtmlElement.setOnDurationChange, .{});
    pub const onemptied = bridge.accessor(HtmlElement.getOnEmptied, HtmlElement.setOnEmptied, .{});
    pub const onended = bridge.accessor(HtmlElement.getOnEnded, HtmlElement.setOnEnded, .{});
    pub const onerror = bridge.accessor(HtmlElement.getOnError, HtmlElement.setOnError, .{});
    pub const onfocus = bridge.accessor(HtmlElement.getOnFocus, HtmlElement.setOnFocus, .{});
    pub const onformdata = bridge.accessor(HtmlElement.getOnFormData, HtmlElement.setOnFormData, .{});
    pub const oninput = bridge.accessor(HtmlElement.getOnInput, HtmlElement.setOnInput, .{});
    pub const oninvalid = bridge.accessor(HtmlElement.getOnInvalid, HtmlElement.setOnInvalid, .{});
    pub const onkeydown = bridge.accessor(HtmlElement.getOnKeyDown, HtmlElement.setOnKeyDown, .{});
    pub const onkeypress = bridge.accessor(HtmlElement.getOnKeyPress, HtmlElement.setOnKeyPress, .{});
    pub const onkeyup = bridge.accessor(HtmlElement.getOnKeyUp, HtmlElement.setOnKeyUp, .{});
    pub const onload = bridge.accessor(HtmlElement.getOnLoad, HtmlElement.setOnLoad, .{});
    pub const onloadeddata = bridge.accessor(HtmlElement.getOnLoadedData, HtmlElement.setOnLoadedData, .{});
    pub const onloadedmetadata = bridge.accessor(HtmlElement.getOnLoadedMetadata, HtmlElement.setOnLoadedMetadata, .{});
    pub const onloadstart = bridge.accessor(HtmlElement.getOnLoadStart, HtmlElement.setOnLoadStart, .{});
    pub const onmousedown = bridge.accessor(HtmlElement.getOnMouseDown, HtmlElement.setOnMouseDown, .{});
    pub const onmouseenter = bridge.accessor(HtmlElement.getOnMouseEnter, HtmlElement.setOnMouseEnter, .{});
    pub const onmouseleave = bridge.accessor(HtmlElement.getOnMouseLeave, HtmlElement.setOnMouseLeave, .{});
    pub const onmousemove = bridge.accessor(HtmlElement.getOnMouseMove, HtmlElement.setOnMouseMove, .{});
    pub const onmouseout = bridge.accessor(HtmlElement.getOnMouseOut, HtmlElement.setOnMouseOut, .{});
    pub const onmouseover = bridge.accessor(HtmlElement.getOnMouseOver, HtmlElement.setOnMouseOver, .{});
    pub const onmouseup = bridge.accessor(HtmlElement.getOnMouseUp, HtmlElement.setOnMouseUp, .{});
    pub const onmousewheel = bridge.accessor(HtmlElement.getOnMouseWheel, HtmlElement.setOnMouseWheel, .{});
    pub const onpause = bridge.accessor(HtmlElement.getOnPause, HtmlElement.setOnPause, .{});
    pub const onplay = bridge.accessor(HtmlElement.getOnPlay, HtmlElement.setOnPlay, .{});
    pub const onplaying = bridge.accessor(HtmlElement.getOnPlaying, HtmlElement.setOnPlaying, .{});
    pub const onprogress = bridge.accessor(HtmlElement.getOnProgress, HtmlElement.setOnProgress, .{});
    pub const onratechange = bridge.accessor(HtmlElement.getOnRateChange, HtmlElement.setOnRateChange, .{});
    pub const onreset = bridge.accessor(HtmlElement.getOnReset, HtmlElement.setOnReset, .{});
    pub const onresize = bridge.accessor(HtmlElement.getOnResize, HtmlElement.setOnResize, .{});
    pub const onscroll = bridge.accessor(HtmlElement.getOnScroll, HtmlElement.setOnScroll, .{});
    pub const onscrollend = bridge.accessor(HtmlElement.getOnScrollEnd, HtmlElement.setOnScrollEnd, .{});
    pub const onsecuritypolicyviolation = bridge.accessor(HtmlElement.getOnSecurityPolicyViolation, HtmlElement.setOnSecurityPolicyViolation, .{});
    pub const onseeked = bridge.accessor(HtmlElement.getOnSeeked, HtmlElement.setOnSeeked, .{});
    pub const onseeking = bridge.accessor(HtmlElement.getOnSeeking, HtmlElement.setOnSeeking, .{});
    pub const onselect = bridge.accessor(HtmlElement.getOnSelect, HtmlElement.setOnSelect, .{});
    pub const onslotchange = bridge.accessor(HtmlElement.getOnSlotChange, HtmlElement.setOnSlotChange, .{});
    pub const onstalled = bridge.accessor(HtmlElement.getOnStalled, HtmlElement.setOnStalled, .{});
    pub const onsubmit = bridge.accessor(HtmlElement.getOnSubmit, HtmlElement.setOnSubmit, .{});
    pub const onsuspend = bridge.accessor(HtmlElement.getOnSuspend, HtmlElement.setOnSuspend, .{});
    pub const ontimeupdate = bridge.accessor(HtmlElement.getOnTimeUpdate, HtmlElement.setOnTimeUpdate, .{});
    pub const ontoggle = bridge.accessor(HtmlElement.getOnToggle, HtmlElement.setOnToggle, .{});
    pub const onvolumechange = bridge.accessor(HtmlElement.getOnVolumeChange, HtmlElement.setOnVolumeChange, .{});
    pub const onwaiting = bridge.accessor(HtmlElement.getOnWaiting, HtmlElement.setOnWaiting, .{});
    pub const onwebkitanimationend = bridge.accessor(HtmlElement.getOnWebkitAnimationEnd, HtmlElement.setOnWebkitAnimationEnd, .{});
    pub const onwebkitanimationiteration = bridge.accessor(HtmlElement.getOnWebkitAnimationIteration, HtmlElement.setOnWebkitAnimationIteration, .{});
    pub const onwebkitanimationstart = bridge.accessor(HtmlElement.getOnWebkitAnimationStart, HtmlElement.setOnWebkitAnimationStart, .{});
    pub const onwebkittransitionend = bridge.accessor(HtmlElement.getOnWebkitTransitionEnd, HtmlElement.setOnWebkitTransitionEnd, .{});
    pub const onwheel = bridge.accessor(HtmlElement.getOnWheel, HtmlElement.setOnWheel, .{});
    pub const onauxclick = bridge.accessor(HtmlElement.getOnAuxClick, HtmlElement.setOnAuxClick, .{});
    pub const ongotpointercapture = bridge.accessor(HtmlElement.getOnGotPointerCapture, HtmlElement.setOnGotPointerCapture, .{});
    pub const onlostpointercapture = bridge.accessor(HtmlElement.getOnLostPointerCapture, HtmlElement.setOnLostPointerCapture, .{});
    pub const onpointerdown = bridge.accessor(HtmlElement.getOnPointerDown, HtmlElement.setOnPointerDown, .{});
    pub const onpointermove = bridge.accessor(HtmlElement.getOnPointerMove, HtmlElement.setOnPointerMove, .{});
    pub const onpointerup = bridge.accessor(HtmlElement.getOnPointerUp, HtmlElement.setOnPointerUp, .{});
    pub const onpointercancel = bridge.accessor(HtmlElement.getOnPointerCancel, HtmlElement.setOnPointerCancel, .{});
    pub const onpointerover = bridge.accessor(HtmlElement.getOnPointerOver, HtmlElement.setOnPointerOver, .{});
    pub const onpointerout = bridge.accessor(HtmlElement.getOnPointerOut, HtmlElement.setOnPointerOut, .{});
    pub const onpointerenter = bridge.accessor(HtmlElement.getOnPointerEnter, HtmlElement.setOnPointerEnter, .{});
    pub const onpointerleave = bridge.accessor(HtmlElement.getOnPointerLeave, HtmlElement.setOnPointerLeave, .{});
    pub const onselectstart = bridge.accessor(HtmlElement.getOnSelectStart, HtmlElement.setOnSelectStart, .{});
    pub const onselectionchange = bridge.accessor(HtmlElement.getOnSelectionChange, HtmlElement.setOnSelectionChange, .{});
    pub const onanimationcancel = bridge.accessor(HtmlElement.getOnAnimationCancel, HtmlElement.setOnAnimationCancel, .{});
    pub const onanimationend = bridge.accessor(HtmlElement.getOnAnimationEnd, HtmlElement.setOnAnimationEnd, .{});
    pub const onanimationiteration = bridge.accessor(HtmlElement.getOnAnimationIteration, HtmlElement.setOnAnimationIteration, .{});
    pub const onanimationstart = bridge.accessor(HtmlElement.getOnAnimationStart, HtmlElement.setOnAnimationStart, .{});
    pub const ontransitionrun = bridge.accessor(HtmlElement.getOnTransitionRun, HtmlElement.setOnTransitionRun, .{});
    pub const ontransitionstart = bridge.accessor(HtmlElement.getOnTransitionStart, HtmlElement.setOnTransitionStart, .{});
    pub const ontransitionend = bridge.accessor(HtmlElement.getOnTransitionEnd, HtmlElement.setOnTransitionEnd, .{});
    pub const ontransitioncancel = bridge.accessor(HtmlElement.getOnTransitionCancel, HtmlElement.setOnTransitionCancel, .{});
    pub const onbeforexrselect = bridge.accessor(HtmlElement.getOnBeforeXrSelect, HtmlElement.setOnBeforeXrSelect, .{});
    pub const oncopy = bridge.accessor(HtmlElement.getOnCopy, HtmlElement.setOnCopy, .{});
    pub const oncut = bridge.accessor(HtmlElement.getOnCut, HtmlElement.setOnCut, .{});
    pub const onpaste = bridge.accessor(HtmlElement.getOnPaste, HtmlElement.setOnPaste, .{});
    pub const dataset = bridge.accessor(_dataset, null, .{});
    pub const nonce = bridge.accessor(HtmlElement.getNonce, HtmlElement.setNonce, .{ .ce_reactions = true });
    pub const autofocus = bridge.accessor(HtmlElement.getAutofocus, HtmlElement.setAutofocus, .{ .ce_reactions = true });
    pub const tabIndex = bridge.accessor(HtmlElement.getTabIndex, HtmlElement.setTabIndex, .{ .ce_reactions = true });
    pub const style = bridge.accessor(_style, _setStyle, .{});
    pub const attributeStyleMap = bridge.accessor(_attributeStyleMap, null, .{});
    pub const attachInternals = bridge.function(HtmlElement.attachInternals, .{});
    pub const blur = bridge.function(_blur, .{});
    pub const click = bridge.function(HtmlElement.click, .{});
    pub const focus = bridge.function(_focus, .{});
    pub const hidePopover = bridge.function(HtmlElement.hidePopover, .{});
    pub const showPopover = bridge.function(HtmlElement.showPopover, .{});
    pub const togglePopover = bridge.function(HtmlElement.togglePopover, .{});
    pub const onscrollsnapchange = bridge.accessor(HtmlElement.getOnScrollSnapChange, HtmlElement.setOnScrollSnapChange, .{});
    pub const onscrollsnapchanging = bridge.accessor(HtmlElement.getOnScrollSnapChanging, HtmlElement.setOnScrollSnapChanging, .{});
    pub const focusGroup = bridge.accessor(HtmlElement.getFocusGroup, HtmlElement.setFocusGroup, .{ .ce_reactions = true });
    pub const focusGroupStart = bridge.accessor(HtmlElement.getFocusGroupStart, HtmlElement.setFocusGroupStart, .{ .ce_reactions = true });
    pub const onpointerrawupdate = bridge.accessor(HtmlElement.getOnPointerRawUpdate, HtmlElement.setOnPointerRawUpdate, .{});
    pub const constructor = bridge.constructor(HtmlElement.construct, .{ .new_target = true });
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the HtmlElement itself.
    pub fn call(self: *const HtmlElement, comptime func_name: []const u8, args: anytype) !bool {
        switch (self._type) {
            inline else => |tag| {
                const S = Subtype(tag);
                // The inner type implements this function. Call it and we're done.
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, func_name)) {
                        try @call(.auto, @field(S.Build, func_name), args);
                        return true;
                    }
                }
            },
        }

        if (@hasDecl(HtmlElement.Build, func_name)) {
            // Our last resort - the node implements this function.
            try @call(.auto, @field(HtmlElement.Build, func_name), args);
            return true;
        }

        // inform our caller (the Element) that we didn't find anything that implemented
        // func_name and it should keep searching for a match.
        return false;
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: HTML.event_listeners" {
    try testing.htmlRunner("element/html/event_listeners.html", .{});
}
test "WebApi: HTMLElement.props" {
    try testing.htmlRunner("element/html/htmlelement-props.html", .{});
}
test "WebApi: HTMLElement.contenteditable" {
    try testing.htmlRunner("element/html/contenteditable.html", .{});
}
test "WebApi: ElementInternals" {
    try testing.htmlRunner("element/element_internals.html", .{});
}
