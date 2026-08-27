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

const js = @import("../js/js.zig");
const dump = @import("../dump.zig");
const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const StyleManager = @import("../StyleManager.zig");

const CSS = @import("CSS.zig");
const CData = @import("CData.zig");
const Node = @import("Node.zig");
const font_metrics = @import("../font_metrics.zig");
const text_measure = @import("../text_measure.zig");
const ShadowRoot = @import("ShadowRoot.zig");
const EventTarget = @import("EventTarget.zig");
const collections = @import("collections.zig");
const DOMRectList = @import("collections/DOMRectList.zig");

const Selector = @import("selector/Selector.zig");
const Animation = @import("animation/Animation.zig");
const KeyframeEffect = @import("animation/KeyframeEffect.zig");
const global_event_handlers = @import("global_event_handlers.zig");
const document_services = @import("document/services.zig");
const typed_om = @import("css/typed_om.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
// Both `element.style` and getComputedStyle() hand out a CSSStyleDeclaration.
// Upstream splits a CSSStyleProperties off it; we do not, because Chrome has no
// such global -- `typeof CSSStyleProperties === 'undefined'` (measured off
// HeadlessChrome/151, see css/chrome_properties.zig and the
// tests/css/declaration_surface.html pin), so exposing one is itself a signal.
const CSSStyleDeclaration = @import("css/CSSStyleDeclaration.zig");

const slotting = @import("element/slotting.zig");
const DOMStringMap = @import("element/DOMStringMap.zig");

pub const DOMRect = @import("DOMRect.zig");
pub const Svg = @import("element/Svg.zig");
pub const MathML = @import("element/MathML.zig");
pub const Html = @import("element/Html.zig");
pub const Attribute = @import("element/Attribute.zig");
pub const Reflect = @import("element/reflection.zig").Reflect;

const log = lp.log;
const String = lp.String;

const Element = @This();

pub const Proto = Node;

pub const DatasetLookup = std.AutoHashMapUnmanaged(*Element, *DOMStringMap);
pub const StyleLookup = std.AutoHashMapUnmanaged(*Element, *CSSStyleDeclaration);
pub const ComputedStyleLookup = std.AutoHashMapUnmanaged(ComputedStyleKey, *CSSStyleDeclaration);

pub const ComputedStyleKey = struct {
    element: *Element,
    pseudo: PseudoElement,
};

pub const PseudoElement = enum {
    none,
    before,
    after,
    other,

    // Named `selector` rather than `pseudo`: Element declares a `pseudo()`
    // method of its own further down, and a parameter of that name shadows it.
    pub fn parse(selector: []const u8) PseudoElement {
        if (selector.len == 0 or selector[0] != ':') {
            return .none;
        }
        const name = if (std.mem.startsWith(u8, selector, "::")) selector[2..] else selector[1..];
        if (std.ascii.eqlIgnoreCase(name, "before")) return .before;
        if (std.ascii.eqlIgnoreCase(name, "after")) return .after;
        return .other;
    }
};

pub const ClassListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const RelListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const ShadowRootLookup = std.AutoHashMapUnmanaged(*Element, *ShadowRoot);
pub const NamespaceUriLookup = std.AutoHashMapUnmanaged(*Element, []const u8);
// The namespace prefix an XML document wrote the element with. A side table
// like the one above rather than a field, and rather than storing the whole
// qualified name in `_tag_name`: the tag name is what picks the element's type
// out of the factory's dispatch table, so it has to stay the local name.
pub const PrefixLookup = std.AutoHashMapUnmanaged(*Element, []const u8);

pub const ScrollPosition = struct {
    x: u32 = 0,
    y: u32 = 0,
    // Throttle state for the async scroll/scrollend dispatch (mirrors
    // Window._scroll_pos.state).
    state: enum { scroll, end, done } = .done,
};
pub const ScrollPositionLookup = std.AutoHashMapUnmanaged(*Element, ScrollPosition);

pub const Namespace = enum(u8) {
    html,
    svg,
    mathml,
    xml,
    // We should keep the original value, but don't.  If this becomes important
    // consider storing it in a frame lookup, like `_element_class_lists`, rather
    // that adding a slice directly here (directly in every element).
    unknown,
    null,

    pub fn toUri(self: Namespace) ?[]const u8 {
        return switch (self) {
            .html => "http://www.w3.org/1999/xhtml",
            .svg => "http://www.w3.org/2000/svg",
            .mathml => "http://www.w3.org/1998/Math/MathML",
            .xml => "http://www.w3.org/XML/1998/namespace",
            .unknown => "http://lightpanda.io/unsupported/namespace",
            .null => null,
        };
    }

    pub fn parse(namespace_: ?[]const u8) Namespace {
        const namespace = namespace_ orelse return .null;
        // Chrome maps an empty namespace to a null one: the namespaceURI of
        // `createElementNS('', 'x')` reads back as null, not "".
        if (namespace.len == 0) {
            return .null;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml")) {
            // Common case. The comparison cannot be skipped on length alone
            // (as upstream does): an XML document can declare any uri at all,
            // and a 28-character one is not the XHTML namespace just because
            // it is 28 characters.
            @branchHint(.likely);
            return .html;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/XML/1998/namespace")) {
            return .xml;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/2000/svg")) {
            return .svg;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/1998/Math/MathML")) {
            return .mathml;
        }
        return .unknown;
    }
};

pub const Flags = packed struct(u8) {
    shadow_host: bool = false,
    customized_builtin: bool = false,

    // Prevents nested clicks (which have a specific spec-compliant behavior
    // compared to other events). If this bit can be more useful for something
    // else, a stack in EventManager (for click-specifically) is an alterantive
    // approach
    click_in_progress: bool = false,

    _unused: u5 = 0,
};

_type: Type,
_namespace: Namespace = .html,
// Presence hints for the frame's element-keyed side tables: a set bit means
// "maybe in the map" (the map stays the authority), a clear bit skips the
// lookup. Turns the per-element map probe in tree walks into a bit test on
// memory the walk already touches. Fits in existing struct padding.
_flags: Flags = .{},
_attributes: Attribute.List = .{},
// The tag name of a `.plain` element. Html, Svg and MathML each keep their own
// copy on the subtype, which is where this would belong -- but a `.plain`
// element has no subtype by construction: the JS bridge brands an element from
// whatever the `_type` payload points at, and Chrome's chain for one of these
// is exactly Element < Node < EventTarget, so the payload has to be `void`.
_plain_tag_name: String = .empty,
// In debug, set so that we can check that we have a proper contiguous block
// of memory for the entire chain (and thus, simple pointer arithmetics will
// work to resolve the proto).
_proto_canary: if (lp.IS_DEBUG) *Node else void = undefined,

pub const Type = enum(u8) {
    html,
    svg,
    // The whole MathML namespace is one interface, so there is nothing under
    // this the way there is under Html and Svg.
    mathml,
    // A namespace with no interface of its own -- null, XML, or anything
    // unrecognised. Measured on Chrome 150: `createElementNS('urn:x', 'thing')`
    // is `[object Element]` sitting straight on Element.prototype, with no
    // style, no dataset and no constructor of its own. There is no subtype at
    // all for exactly that reason (see `_plain_tag_name`).
    plain,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .html => Html,
        .svg => Svg,
        .mathml => MathML,
        // A `.plain` element's chain stops at Element: it has no subtype to
        // name. Callers that dispatch over Subtype() must skip `void`.
        .plain => void,
    };
}

pub fn subtype(self: *const Element, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, Element);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *Element, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .html => {
            const el = self.subtype(Html);
            if (T == Html) {
                return el;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.")) {
                return el.is(T);
            }
        },
        .svg => {
            const svg = self.subtype(Svg);
            if (T == Svg) {
                return svg;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.svg.")) {
                return svg.is(T);
            }
        },
        .mathml => {
            if (T == MathML) {
                return self.subtype(MathML);
            }
        },
        // No subtype to hand back, by construction.
        .plain => {},
    }
    return null;
}

pub fn as(self: *Element, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Element) *Node {
    return Factory.protoOf(self);
}

pub fn asEventTarget(self: *Element) *EventTarget {
    return self.asNode().asEventTarget();
}

pub fn asConstNode(self: *const Element) *const Node {
    return Factory.protoOf(@constCast(self));
}

/// TODO: localName and prefix comparison.
pub fn isEqualNode(self: *Element, other: *Element) bool {
    const self_tag = self.getTagNameDump();
    const other_tag = other.getTagNameDump();
    // Compare namespaces and tags.
    const dirty = self._namespace != other._namespace or !std.mem.eql(u8, self_tag, other_tag);
    if (dirty) {
        return false;
    }

    if (self._attributes.eql(&other._attributes) == false) {
        return false;
    }

    return self.asNode().isEqualChildren(other.asNode());
}

pub fn getTagNameLower(self: *const Element) []const u8 {
    switch (self._type) {
        .html => {
            const he = self.subtype(Html);
            switch (he._type) {
                .custom => {
                    @branchHint(.unlikely);
                    return he.subtype(Html.Custom)._tag_name.str();
                },
                else => return switch (he._type) {
                    .anchor => "a",
                    .area => "area",
                    .base => "base",
                    .body => "body",
                    .br => "br",
                    .button => "button",
                    .canvas => "canvas",
                    .custom => he.subtype(Html.Custom)._tag_name.str(),
                    .data => "data",
                    .datalist => "datalist",
                    .details => "details",
                    .dialog => "dialog",
                    .directory => "dir",
                    .menu => "menu",
                    .frame_element => "frame",
                    .div => "div",
                    .dl => "dl",
                    .embed => "embed",
                    .fieldset => "fieldset",
                    .font => "font",
                    .frameset => "frameset",
                    .form => "form",
                    .generic => he.subtype(Html.Generic)._tag_name.str(),
                    .heading => he.subtype(Html.Heading)._tag_name.str(),
                    .head => "head",
                    .html => "html",
                    .hr => "hr",
                    .iframe => "iframe",
                    .img => "img",
                    .input => "input",
                    .label => "label",
                    .legend => "legend",
                    .li => "li",
                    .link => "link",
                    .map => "map",
                    .marquee => "marquee",
                    .media => switch (he.subtype(Html.Media)._type) {
                        .audio => "audio",
                        .video => "video",
                        .generic => "media",
                    },
                    .meta => "meta",
                    .meter => "meter",
                    .mod => he.subtype(Html.Mod)._tag_name.str(),
                    .object => "object",
                    .ol => "ol",
                    .optgroup => "optgroup",
                    .option => "option",
                    .output => "output",
                    .p => "p",
                    .picture => "picture",
                    .param => "param",
                    .pre => "pre",
                    .progress => "progress",
                    .quote => he.subtype(Html.Quote)._tag_name.str(),
                    .script => "script",
                    .select => "select",
                    .selected_content => "selectedcontent",
                    .slot => "slot",
                    .geolocation => "geolocation",
                    .user_media => "usermedia",
                    .source => "source",
                    .span => "span",
                    .style => "style",
                    .table => "table",
                    .table_caption => "caption",
                    .table_cell => he.subtype(Html.TableCell)._tag_name.str(),
                    .table_col => he.subtype(Html.TableCol)._tag_name.str(),
                    .table_row => "tr",
                    .table_section => he.subtype(Html.TableSection)._tag_name.str(),
                    .template => "template",
                    .textarea => "textarea",
                    .time => "time",
                    .title => "title",
                    .track => "track",
                    .ul => "ul",
                    .unknown => he.subtype(Html.Unknown)._tag_name.str(),
                },
            }
        },
        .svg => return self.subtype(Svg)._tag_name.str(),
        // Case-preserving, like SVG: 'mSpace' stays 'mSpace'.
        .mathml => return self.subtype(MathML)._tag_name.str(),
        .plain => return self._plain_tag_name.str(),
    }
}

/// `tagName` (and so `nodeName`) per spec: the qualified name, ASCII-uppercased
/// only when the element is in the HTML namespace *and* its node document is an
/// HTML document. An XHTML `<p>` therefore reads `p`, and a prefixed XML
/// element keeps the prefix -- `<s:clipPath/>` reads `s:clipPath`. Chrome 151
/// readings: probe expr-g4-p67.js.
///
/// `frame` is optional for the two internal consumers that have none -- the CDP
/// node dump and the XPath name functions, which only reach the element arm for
/// a document the frame itself loaded -- and a null one reads as an HTML
/// document, which is what both did before.
pub fn getTagNameSpec(self: *Element, frame: ?*const Frame, buf: []u8) []const u8 {
    const fold = if (frame) |f| self.inHtmlDocument(f) else true;
    // Only the parser's side table composes: `createElementNS('urn:x', 'p:q')`
    // already stored `p:q` as the tag name, so prepending would double it.
    const prefix = self.parsedPrefix(frame) orelse {
        return if (fold) self.tagNameFolded(buf) else self.getTagNameLower();
    };

    // "prefix" + ":" + the name, composed into the caller's buffer. The folded
    // name is written into the tail so that prepending cannot clobber it.
    const total = prefix.len + 1 + self.getTagNameLower().len;
    if (total > buf.len) {
        log.info(.dom, "tag.long.name", .{ .name = self.getTagNameLower() });
        return self.getTagNameLower();
    }
    const name = if (fold) self.tagNameFolded(buf[prefix.len + 1 ..]) else self.getTagNameLower();
    std.mem.copyBackwards(u8, buf[prefix.len + 1 ..][0..name.len], name);
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = ':';
    return buf[0 .. prefix.len + 1 + name.len];
}

/// The namespace prefix the element was written with, or null. The XML parser
/// files it in a side table, the way it files a namespace uri outside the
/// built-in set; `createElementNS('urn:x', 'p:q')` instead stores the qualified
/// name whole, so that spelling is still found by splitting.
pub fn getPrefix(self: *Element, frame: ?*const Frame) ?[]const u8 {
    if (self.parsedPrefix(frame)) |prefix| {
        return prefix;
    }
    const name = self.getTagNameLower();
    if (std.mem.indexOfScalar(u8, name, ':')) |pos| {
        return name[0..pos];
    }
    return null;
}

fn parsedPrefix(self: *Element, frame: ?*const Frame) ?[]const u8 {
    const f = frame orelse return null;
    return f._element_prefixes.get(self);
}

/// A case fold follows the *document*, not the element's namespace: an HTML
/// document folds, an XML one does not. A detached node with no owner falls
/// back to the frame's document, which is how `ownerDocument` already reads it.
pub fn inHtmlDocument(self: *Element, frame: *const Frame) bool {
    const doc = self.asNode().ownerDocument(frame) orelse return true;
    return doc._type == .html;
}

fn tagNameFolded(self: *const Element, buf: []u8) []const u8 {
    return switch (self._type) {
        .html => blk: {
            const he = self.subtype(Html);
            break :blk switch (he._type) {
                .anchor => "A",
                .area => "AREA",
                .base => "BASE",
                .body => "BODY",
                .br => "BR",
                .button => "BUTTON",
                .canvas => "CANVAS",
                .custom => upperTagName(&he.subtype(Html.Custom)._tag_name, buf),
                .data => "DATA",
                .datalist => "DATALIST",
                .details => "DETAILS",
                .dialog => "DIALOG",
                .directory => "DIR",
                .menu => "MENU",
                .frame_element => "FRAME",
                .div => "DIV",
                .dl => "DL",
                .embed => "EMBED",
                .fieldset => "FIELDSET",
                .font => "FONT",
                .frameset => "FRAMESET",
                .form => "FORM",
                .generic => upperTagName(&he.subtype(Html.Generic)._tag_name, buf),
                .heading => upperTagName(&he.subtype(Html.Heading)._tag_name, buf),
                .head => "HEAD",
                .html => "HTML",
                .hr => "HR",
                .iframe => "IFRAME",
                .img => "IMG",
                .input => "INPUT",
                .label => "LABEL",
                .legend => "LEGEND",
                .li => "LI",
                .link => "LINK",
                .map => "MAP",
                .marquee => "MARQUEE",
                .meta => "META",
                .media => switch (he.subtype(Html.Media)._type) {
                    .audio => "AUDIO",
                    .video => "VIDEO",
                    .generic => "MEDIA",
                },
                .meter => "METER",
                .mod => upperTagName(&he.subtype(Html.Mod)._tag_name, buf),
                .object => "OBJECT",
                .ol => "OL",
                .optgroup => "OPTGROUP",
                .option => "OPTION",
                .output => "OUTPUT",
                .p => "P",
                .picture => "PICTURE",
                .param => "PARAM",
                .pre => "PRE",
                .progress => "PROGRESS",
                .quote => upperTagName(&he.subtype(Html.Quote)._tag_name, buf),
                .script => "SCRIPT",
                .select => "SELECT",
                .selected_content => "SELECTEDCONTENT",
                .slot => "SLOT",
                .geolocation => "GEOLOCATION",
                .user_media => "USERMEDIA",
                .source => "SOURCE",
                .span => "SPAN",
                .style => "STYLE",
                .table => "TABLE",
                .table_caption => "CAPTION",
                .table_cell => upperTagName(&he.subtype(Html.TableCell)._tag_name, buf),
                .table_col => upperTagName(&he.subtype(Html.TableCol)._tag_name, buf),
                .table_row => "TR",
                .table_section => upperTagName(&he.subtype(Html.TableSection)._tag_name, buf),
                .template => "TEMPLATE",
                .textarea => "TEXTAREA",
                .time => "TIME",
                .title => "TITLE",
                .track => "TRACK",
                .ul => "UL",
                .unknown => switch (self._namespace) {
                    .html => upperTagName(&he.subtype(Html.Unknown)._tag_name, buf),
                    .svg, .xml, .mathml, .unknown, .null => he.subtype(Html.Unknown)._tag_name.str(),
                },
            };
        },
        .svg => self.subtype(Svg)._tag_name.str(),
        .mathml => self.subtype(MathML)._tag_name.str(),
        // Only the HTML namespace uppercases, and a plain element is never in
        // it.
        .plain => self._plain_tag_name.str(),
    };
}

pub fn getTagNameDump(self: *const Element) []const u8 {
    switch (self._type) {
        .html => return self.getTagNameLower(),
        .svg => return self.subtype(Svg)._tag_name.str(),
        .mathml => return self.subtype(MathML)._tag_name.str(),
        .plain => return self._plain_tag_name.str(),
    }
}

pub fn getNamespaceURI(self: *const Element) ?[]const u8 {
    return self._namespace.toUri();
}

pub fn getNamespaceUri(self: *Element, frame: *Frame) ?[]const u8 {
    if (self._namespace != .unknown) return self._namespace.toUri();
    return frame._element_namespace_uris.get(self);
}

pub fn lookupNamespaceURIForElement(self: *Element, prefix: ?[]const u8, frame: *Frame) ?[]const u8 {
    // Hardcoded reserved prefixes
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml")) return "http://www.w3.org/XML/1998/namespace";
        if (std.mem.eql(u8, p, "xmlns")) return "http://www.w3.org/2000/xmlns/";
    }

    // Step 1: check element's own namespace/prefix
    if (self.getNamespaceUri(frame)) |ns_uri| {
        const el_prefix = self.getPrefix(frame);
        const match = if (prefix == null and el_prefix == null)
            true
        else if (prefix != null and el_prefix != null)
            std.mem.eql(u8, prefix.?, el_prefix.?)
        else
            false;
        if (match) return ns_uri;
    }

    // Step 2: search xmlns attributes
    for (self._attributes.entries()) |*entry| {
        if (prefix == null) {
            if (std.mem.eql(u8, entry.name(), "xmlns")) {
                const val = entry.value();
                return if (val.len == 0) null else val;
            }
        } else {
            const name = entry.name();
            if (std.mem.startsWith(u8, name, "xmlns:")) {
                if (std.mem.eql(u8, name["xmlns:".len..], prefix.?)) {
                    const val = entry.value();
                    return if (val.len == 0) null else val;
                }
            }
        }
    }

    // Step 3: recurse to parent element
    const parent = self.asNode().parentElement() orelse return null;
    return parent.lookupNamespaceURIForElement(prefix, frame);
}

// Locate a namespace prefix: the inverse of lookupNamespaceURIForElement.
// Given a namespace URI, find the prefix that declares it.
pub fn lookupPrefixForElement(self: *Element, namespace: []const u8, frame: *Frame) ?[]const u8 {
    // Step 1: element's own namespace/prefix
    if (self.getNamespaceUri(frame)) |ns_uri| {
        if (self.getPrefix(frame)) |el_prefix| {
            if (std.mem.eql(u8, ns_uri, namespace)) {
                return el_prefix;
            }
        }
    }

    // Step 2: search xmlns: attribute declarations for one whose value is the namespace
    for (self._attributes.entries()) |*entry| {
        const name = entry.name();
        if (std.mem.startsWith(u8, name, "xmlns:") and std.mem.eql(u8, entry.value(), namespace)) {
            return name["xmlns:".len..];
        }
    }

    // Step 3: recurse to parent element
    const parent = self.asNode().parentElement() orelse return null;
    return parent.lookupPrefixForElement(namespace, frame);
}

fn _prefix(self: *Element, frame: *Frame) ?[]const u8 {
    return self.getPrefix(frame);
}

pub fn getLocalName(self: *Element) []const u8 {
    const name = self.getTagNameLower();
    if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
        return name[pos + 1 ..];
    }

    return name;
}

// Wrapper methods that delegate to Html implementations
pub fn getInnerText(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.getInnerText(writer, frame);
}

pub fn setInnerText(self: *Element, text: []const u8, frame: *Frame) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.setInnerText(text, frame);
}

pub fn insertAdjacentHTML(
    self: *Element,
    position: []const u8,
    html_or_xml: []const u8,
    frame: *Frame,
) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.insertAdjacentHTML(position, html_or_xml, frame);
}

pub fn getOuterHTML(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.deep(self.asNode(), .{ .shadow = .skip }, writer, frame);
}

pub fn setOuterHTML(self: *Element, html: []const u8, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node._parent orelse return;

    // The parent of a documentElement is the Document, which cannot be modified.
    if (parent._type == .document) {
        // An element with no parent at all is a different case and Chrome does
        // not throw for it (measured on Chrome 151: `document.createElement
        // ('div').outerHTML = 'x'` is silent), which is why the early return
        // above stays a plain return.
        return frame.js.fail(error.NoModificationAllowed, "Failed to set the 'outerHTML' " ++
            "property on 'Element': This element's parent is a Document, which may not be modified.");
    }

    frame.domChanged();

    // Observers of the parent must see a single mutation record replacing
    // this node with the parsed nodes.
    const notify = Frame.observers.hasMutationObservers(frame);
    var added: std.ArrayList(*Node) = .empty;

    var fragment: ?*Node = null;
    if (html.len > 0) {
        const frag = (try Node.DocumentFragment.init(frame)).asNode();
        try Frame.parse.htmlAsChildren(frame, frag, html);
        fragment = frag;
    }

    // Parsing (and each insertion below) can synchronously run a custom
    // element constructor that mutates the live tree; per the spec's replace
    // step, a node that is no longer our parent's child cannot be replaced.
    if (node._parent != parent) {
        return error.NotFound;
    }

    // Captured after the parse: a constructor may have reshuffled siblings.
    const previous_sibling = node.previousSibling();
    const next_sibling = node.nextSibling();

    if (fragment) |frag| {
        var it = frag.childrenIterator();
        while (it.next()) |child| {
            if (node._parent != parent) {
                return error.NotFound;
            }
            if (notify) {
                try added.append(frame.call_arena, child);
            }
            frame.removeNode(frag, child, .{ .reconnect_to = parent, .notify_observers = false });
            try frame.insertNodeRelative(parent, child, .{ .before = node }, .{ .notify_observers = false });
        }
    }

    if (node._parent != parent) {
        return error.NotFound;
    }
    frame.removeNode(parent, node, .{ .reconnect_to = null, .notify_observers = false });

    if (notify) {
        const removed = [_]*Node{node};
        Frame.observers.notifyChildListChange(frame, parent, added.items, &removed, previous_sibling, next_sibling);
    }
}

pub fn getInnerHTML(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    // A template's own childNodes are always empty; what it holds lives in its
    // content fragment, and that is what `innerHTML` reads and writes. Chrome
    // has no HTMLTemplateElement.prototype.innerHTML of its own (measured), so
    // the redirect belongs here rather than on a second binding.
    if (self.is(Html.Template)) |template| {
        return dump.children(template._content.asNode(), .{ .shadow = .skip }, writer, frame);
    }
    return dump.children(self.asNode(), .{ .shadow = .skip }, writer, frame);
}

pub fn getHTML(self: *Element, opts: dump.Opts.Shadow.Declarative, writer: *std.Io.Writer, frame: *Frame) !void {
    return dump.getHTML(self.asNode(), opts, writer, frame);
}

pub fn setInnerHTML(self: *Element, html: []const u8, frame: *Frame) !void {
    // See getInnerHTML: a template parses into its content fragment.
    if (self.is(Html.Template)) |template| {
        return template.setInnerHTML(html, frame);
    }
    const parent = self.asNode();
    return parent.setHTML(html, false, frame);
}

/// allows declarative shadow dom
pub fn setHTMLUnsafe(self: *Element, html: []const u8, frame: *Frame) !void {
    const parent = self.asNode();
    return parent.setHTML(html, true, frame);
}

pub fn getId(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("id")) orelse "";
}

pub fn setId(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("id"), .wrap(value), frame);
}

pub fn getSlot(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("slot")) orelse "";
}

pub fn setSlot(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("slot"), .wrap(value), frame);
}

pub fn getDir(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("dir")) orelse "";
}

pub fn setDir(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("dir"), .wrap(value), frame);
}

pub fn getClassName(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("class")) orelse "";
}

pub fn setClassName(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("class"), .wrap(value), frame);
}

/// DANGER: Invalidated by mutation of the attribute list.
pub fn attributeEntries(self: *const Element) []const Attribute.List.Entry {
    return self._attributes.entries();
}

pub fn getAttribute(self: *const Element, name: String, frame: *Frame) !?String {
    return self._attributes.get(name, frame);
}

pub fn getAttributeNS(
    self: *const Element,
    namespace_: ?[]const u8,
    local_name: String,
    frame: *Frame,
) !?String {
    if (namespace_) |namespace| {
        // we don't really support namespaces, but if the namespace has a fixed
        // prefix, we can try to fetch the attribute with it
        if (try prefixedAttributeName(namespace, local_name.str(), frame)) |prefixed| {
            if (try self.getAttribute(.wrap(prefixed), frame)) |value| {
                return value;
            }
        }
    }
    return self.getAttribute(local_name, frame);
}

pub fn prefixedAttributeName(namespace: []const u8, local_name: []const u8, frame: *Frame) !?[]const u8 {
    const prefix = blk: {
        if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xlink")) {
            break :blk "xlink";
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/XML/1998/namespace")) {
            break :blk "xml";
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/2000/xmlns/")) {
            break :blk "xmlns";
        }
        return null;
    };
    return try std.fmt.allocPrint(frame.local_arena, "{s}:{s}", .{ prefix, local_name });
}

pub fn getAttributeSafe(self: *const Element, name: String) ?[]const u8 {
    return self._attributes.getSafe(name);
}

pub fn hasAttribute(self: *const Element, name: String, frame: *Frame) !bool {
    const value = try self._attributes.get(name, frame);
    return value != null;
}

pub fn hasAttributeNS(
    self: *const Element,
    namespace_: ?[]const u8,
    local_name: String,
    frame: *Frame,
) !bool {
    return try self.getAttributeNS(namespace_, local_name, frame) != null;
}

pub fn hasAttributeSafe(self: *const Element, name: String) bool {
    return self._attributes.hasSafe(name);
}

// Per HTML "concept-fe-disabled", only listed elements participate in the
// disabled concept. Anything else (e.g. <div disabled>) has no disabled
// state and never matches :disabled / :enabled.
pub fn hasDisabledConcept(self: *const Element) bool {
    return switch (self.getTag()) {
        .button, .input, .select, .textarea, .optgroup, .option, .fieldset => true,
        else => false,
    };
}

pub fn isDisabled(self: *Element) bool {
    if (!self.hasDisabledConcept()) {
        return false;
    }

    if (self.getAttributeSafe(comptime .wrap("disabled")) != null) {
        return true;
    }

    // <option> takes a different inheritance path: per HTML
    // "concept-option-disabled" an option is disabled when its parent is an
    // <optgroup disabled>. It does NOT inherit from <select disabled> or
    // an ancestor <fieldset disabled>.
    if (self.getTag() == .option) {
        if (self.asNode()._parent) |parent_node| {
            if (parent_node.is(Element)) |parent_el| {
                if (parent_el.getTag() == .optgroup and
                    parent_el.getAttributeSafe(comptime .wrap("disabled")) != null)
                {
                    return true;
                }
            }
        }
        return false;
    }

    const element_node = self.asNode();
    var current: ?*Node = element_node._parent;
    while (current) |node| {
        current = node._parent;
        const ancestor = node.is(Element) orelse continue;

        if (ancestor.getTag() == .fieldset and ancestor.getAttributeSafe(comptime .wrap("disabled")) != null) {
            var child = ancestor.firstElementChild();
            while (child) |c| {
                if (c.getTag() == .legend) {
                    if (c.asNode().contains(element_node)) return false;
                    break;
                }
                child = c.nextElementSibling();
            }
            return true;
        }
    }
    return false;
}

pub fn hasAttributes(self: *const Element) bool {
    return self._attributes.isEmpty() == false;
}

pub fn getAttributeNode(self: *Element, name: String, frame: *Frame) !?*Attribute {
    return self._attributes.getAttribute(name, self, frame);
}

pub fn setAttribute(self: *Element, name: String, value: String, frame: *Frame) !void {
    try Attribute.validateAttributeName(name, "setAttribute", frame);
    _ = try self._attributes.put(name, value, self, frame);
}

pub fn setAttributeNS(
    self: *Element,
    namespace_: ?[]const u8,
    qualified_name: []const u8,
    value: String,
    frame: *Frame,
) !void {
    // Same rule as setAttribute, worded a third way: this one calls the input a
    // qualified name and names the character it tripped over.
    if (Attribute.checkAttributeName(qualified_name)) |rejection| {
        const prefix = "Failed to execute 'setAttributeNS' on 'Element': ";
        switch (rejection) {
            .empty => return frame.js.fail(
                error.InvalidCharacterError,
                prefix ++ "The qualified name provided is empty.",
            ),
            .character => |c| return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
                frame.call_arena,
                prefix ++ "The qualified name provided ('{s}') contains the invalid character '{c}'.",
                .{ qualified_name, c },
            )),
        }
    }

    const local_start = if (std.mem.indexOfScalarPos(u8, qualified_name, 0, ':')) |idx| blk: {
        if (idx == 0 or idx == qualified_name.len - 1) {
            // cannot be at the start or end of the qname
            return error.InvalidCharacterError;
        }
        if (std.mem.indexOfScalarPos(u8, qualified_name, idx + 1, ':') != null) {
            // and can only have one
            return error.InvalidCharacterError;
        }
        break :blk idx + 1;
    } else 0;

    const attr_name = if (namespace_ != null) qualified_name else qualified_name[local_start..];
    return self.setAttribute(.wrap(attr_name), value, frame);
}

pub fn setAttributeSafe(self: *Element, name: String, value: String, frame: *Frame) !void {
    _ = try self._attributes.putSafe(name, value, self, frame);
}

pub fn getShadowRoot(self: *Element, frame: *Frame) ?*ShadowRoot {
    const shadow_root = self.hostedShadowRoot(frame) orelse return null;
    if (shadow_root._mode == .closed) return null;
    return shadow_root;
}

pub fn getAssignedSlot(self: *Element, frame: *Frame) ?*Html.Slot {
    // Hidden by a closed shadow tree
    return slotting.findSlot(self.asNode(), true, frame);
}

// Whether this element may host a shadow root
fn isValidShadowHost(self: *const Element) bool {
    if (self._namespace != .html) {
        return false;
    }

    return switch (self.getTag()) {
        .article, .aside, .blockquote, .body, .div, .footer, .header, .main, .nav, .p, .section, .span, .h1, .h2, .h3, .h4, .h5, .h6, .custom => true,
        else => false,
    };
}

pub fn attachShadow(self: *Element, opts: ShadowRoot.AttachOptions, frame: *Frame) !*ShadowRoot {
    if (!self.isValidShadowHost()) {
        return error.NotSupported;
    }

    // A custom element whose definition lists "shadow" in disabledFeatures
    // cannot host a shadow root (imperative or declarative).
    if (self.is(Html.Custom)) |custom| {
        if (frame.window._custom_elements._definitions.get(custom._tag_name.str())) |def| {
            if (def.disable_shadow) {
                return error.NotSupported;
            }
        }
    }

    if (self.hostedShadowRoot(frame)) |existing| {
        // Imperative attachShadow over a declarative shadow root with a matching
        // mode empties it and returns the same root. The parser
        // (opts.declarative) never replaces an existing root.
        if (opts.declarative or !existing._declarative or existing._mode != opts.mode) {
            return error.NotSupported;
        }
        try existing.asNode().replaceChildren(&.{}, frame);
        existing._declarative = false;
        return existing;
    }

    const shadow_root = try ShadowRoot.init(self, opts, frame);
    try frame._element_shadow_roots.put(frame.arena, self, shadow_root);
    self._flags.shadow_host = true;
    return shadow_root;
}

// The shadow root this element hosts, closed ones included (the JS-facing
// getShadowRoot filters those). The flag check skips the map probe for the
// overwhelming majority of elements, which host nothing.
pub fn hostedShadowRoot(self: *Element, frame: *const Frame) ?*ShadowRoot {
    if (!self._flags.shadow_host) {
        return null;
    }
    return frame._element_shadow_roots.get(self);
}

pub fn insertAdjacentElement(
    self: *Element,
    position: []const u8,
    element: *Element,
    frame: *Frame,
) !?*Element {
    const target_node, const prev_node = self.asNode().findAdjacentNodes(position, .node) catch |err| switch (err) {
        // beforebegin/afterend with no parent is a no-op returning null.
        error.AdjacentNoParent => return null,
        else => return err,
    };
    _ = try target_node.insertBefore(element.asNode(), prev_node, frame);
    return element;
}

pub fn insertAdjacentText(
    self: *Element,
    where: []const u8,
    data: []const u8,
    frame: *Frame,
) !void {
    const target_node, const prev_node = self.asNode().findAdjacentNodes(where, .node) catch |err| switch (err) {
        // beforebegin/afterend with no parent is a no-op.
        error.AdjacentNoParent => return,
        else => return err,
    };
    const text_node = try Frame.node_factory.createTextNode(frame, data);
    _ = try target_node.insertBefore(text_node, prev_node, frame);
}

pub fn setAttributeNode(self: *Element, attr: *Attribute, frame: *Frame) !?*Attribute {
    if (attr._element) |el| {
        if (el == self) {
            return attr;
        }
        attr._element = null;
        _ = try el.removeAttributeNode(attr, frame);
    }

    return self._attributes.putAttribute(attr, self, frame);
}

pub fn removeAttribute(self: *Element, name: String, frame: *Frame) !void {
    return self._attributes.delete(name, self, frame);
}

pub fn removeAttributeSafe(self: *Element, name: String, frame: *Frame) void {
    self._attributes.deleteSafe(name, self, frame);
}

pub fn toggleAttribute(self: *Element, name: String, force: ?bool, frame: *Frame) !bool {
    try Attribute.validateAttributeName(name, "toggleAttribute", frame);
    const has = try self.hasAttribute(name, frame);

    const should_add = force orelse !has;

    if (should_add and !has) {
        try self.setAttribute(name, String.empty, frame);
        return true;
    } else if (!should_add and has) {
        try self.removeAttribute(name, frame);
        return false;
    }

    return should_add;
}

pub fn removeAttributeNode(self: *Element, attr: *Attribute, frame: *Frame) !*Attribute {
    if (attr._element == null or attr._element.? != self) {
        return error.NotFound;
    }
    try self.removeAttribute(attr._name, frame);
    attr._element = null;
    return attr;
}

pub fn getAttributeNames(self: *const Element, frame: *Frame) ![][]const u8 {
    return self._attributes.getNames(frame.local_arena);
}

pub fn getAttributeNamedNodeMap(self: *Element, frame: *Frame) !*Attribute.NamedNodeMap {
    const gop = try frame._attribute_named_node_map_lookup.getOrPut(frame.arena, @intFromPtr(self));
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(Attribute.NamedNodeMap{ ._element = self });
    }
    return gop.value_ptr.*;
}

// Event handler attributes ("onclick=...") and the IDL properties that shadow
// them share one store, keyed by event target. Elements of any namespace need
// this, not just HTML ones: Chrome declares onfullscreenchange and
// onfullscreenerror on Element.
pub fn getAttributeFunction(
    self: *Element,
    listener_type: global_event_handlers.Handler,
    frame: *Frame,
) !?js.Function.Global {
    if (frame.getEventHandler(self.asEventTarget(), listener_type)) |cached| {
        return cached;
    }

    const attr = self.getAttributeSafe(.wrap(@tagName(listener_type))) orelse return null;
    const function = frame.js.stringToPersistedFunction(attr, &.{"event"}, &.{}) catch |err| {
        // Not a valid expression; log this to find out if its something we should be supporting.
        log.warn(.js, "Element.getAttributeFunction", .{
            .expression = attr,
            .err = err,
        });
        return null;
    };

    // Cache the compiled expression, but don't go through setAttributeListener:
    // this runs from inside a dispatch, where the handler's listener is already
    // in the list (it was registered when the attribute was set) and touching
    // the list mid-iteration would be a mistake.
    try frame._event_manager.base.cacheHandlerFunction(self.asEventTarget(), listener_type, function);
    return function;
}

pub fn hasAttributeFunction(self: *Element, listener_type: global_event_handlers.Handler, frame: *const Frame) bool {
    return frame._event_manager.base.hasHandlerFunction(self.asEventTarget(), listener_type);
}

pub fn setAttributeListener(
    self: *Element,
    listener_type: global_event_handlers.Handler,
    listener_callback: ?js.Function.Global,
    frame: *Frame,
) !void {
    return frame.setEventHandler(self.asEventTarget(), listener_type, listener_callback);
}

// The materialized style lives in the map of the element's own frame, not
// the caller's: attributeChange (which resyncs it) is dispatched on the owner
// frame, and a same-origin script can reach an element in another frame.
pub fn getOrCreateStyle(self: *Element, frame: *Frame) !*CSSStyleDeclaration {
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_styles.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try CSSStyleDeclaration.init(self, false, owner);
    }
    return gop.value_ptr.*;
}

// The element's inline `style=` declaration, materializing it from the
// attribute if nothing has asked for `el.style` yet.
//
// A plain map lookup was not enough: the map is filled by getOrCreateStyle,
// which only runs when script touches `el.style` or the CSSOM does. So an
// `<iframe style="width:300px;height:65px">` that no script had reached
// measured as the UA stylesheet's undeclared 300x150 in `dimensions` below,
// and the child document laid out in that box read 150 tall through both
// documentElement.clientHeight and window.innerHeight. Reading it once through
// `el.style` first made the same page answer 65 -- an order dependence, not a
// layout rule.
//
// Same idiom StyleManager.getInlineStyleProperty uses, so the cascade and these
// callers resolve an inline declaration from the same source.
fn getStyle(self: *Element, frame: *Frame) ?*CSSStyleDeclaration {
    const owner = self.ownerFrame(frame);
    return owner._element_styles.get(self) orelse blk: {
        if (self.getAttributeSafe(comptime .wrap("style")) == null) break :blk null;
        break :blk self.getOrCreateStyle(owner) catch |err| {
            log.err(.browser, "Element getOrCreateStyle", .{ .err = err });
            break :blk null;
        };
    };
}

pub fn setStyle(self: *Element, value: []const u8, frame: *Frame) !void {
    const style = try self.getOrCreateStyle(frame);
    try style.setCssText(value, frame);
}

pub fn getClassList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_class_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("class"),
        });
    }
    return gop.value_ptr.*;
}

pub fn setClassList(self: *Element, value: String, frame: *Frame) !void {
    const class_list = try self.getClassList(frame);
    try class_list.setValue(value, frame);
}

pub fn getRelList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_rel_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("rel"),
        });
    }
    return gop.value_ptr.*;
}

// The other DOMTokenList-reflected attributes (class and rel have dedicated
// lookups above).
pub const TokenListAttribute = enum { sizes, sandbox, @"for", part, focusgroup, blocking, controlslist };

/// The content attributes whose IDL member is an element reference rather than
/// a string: `interestfor` and `commandfor`. Setting the IDL member does not
/// write an id -- Chrome writes the attribute as the empty string and keeps the
/// element itself, so a target with no id still reads back (measured:
/// `b.commandForElement = div` leaves `getAttribute('commandfor')` as `""` and
/// `b.commandForElement` as the div). That explicit reference lives here rather
/// than in a field on each element type, the way a token list does.
pub const ElementReferenceAttribute = enum { interestfor, commandfor };
pub const ElementReferenceKey = struct { element: *Element, attribute: ElementReferenceAttribute };
pub const ElementReferenceLookup = std.AutoHashMapUnmanaged(ElementReferenceKey, *Element);
pub const EditContextLookup = std.AutoHashMapUnmanaged(*Element, *@import("EditContext.zig"));
pub const TokenListKey = struct { element: *Element, attribute: TokenListAttribute };
pub const TokenListLookup = std.AutoHashMapUnmanaged(TokenListKey, *collections.DOMTokenList);

pub fn getTokenList(self: *Element, comptime attribute: TokenListAttribute, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_token_lists.getOrPut(frame.arena, .{ .element = self, .attribute = attribute });
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap(@tagName(attribute)),
        });
    }
    return gop.value_ptr.*;
}

pub const NonceLookup = std.AutoHashMapUnmanaged(*Element, []const u8);

// `nonce` is a slot, not a reflection of the content attribute -- there is one
// storage and two writers, and only one of them touches the markup. Measured
// on Chrome 151, on HTMLElement, SVGElement and MathMLElement alike:
//
//   el.nonce = 'abc'                  -> nonce 'abc', getAttribute null
//   setAttribute('nonce', 'zzz')      -> nonce 'zzz', getAttribute 'zzz'
//   nonce='abc' then setAttribute     -> nonce 'zzz' (the later write wins)
//   ...then removeAttribute           -> nonce '',    getAttribute null
//   cloneNode                         -> nonce '' unless an attribute came too
//
// A read-time rule over (slot, attribute) cannot tell the third line's end
// state from the first's, which is why the attribute's writers reach in here
// rather than the getter preferring the attribute. The one attribute writer
// that does not is the parser, which fills a node's initial attributes without
// running change reactions -- so an *unset* slot still falls back, and that is
// what a parsed `<script nonce=...>` reads.
pub fn getNonce(self: *Element, frame: *Frame) []const u8 {
    if (frame._element_nonces.get(self)) |slot| return slot;
    return self.getAttributeSafe(comptime .wrap("nonce")) orelse "";
}

pub fn setNonce(self: *Element, value: []const u8, frame: *Frame) !void {
    return frame._element_nonces.put(frame.arena, self, try frame.dupeString(value));
}

// Called by Frame.attributeChange / attributeRemove for the `nonce` attribute:
// a removal empties the slot rather than deleting it, matching the empty
// string a never-written element answers.
pub fn nonceAttributeChanged(self: *Element, value: []const u8, frame: *Frame) void {
    frame._element_nonces.put(frame.arena, self, frame.dupeString(value) catch return) catch {};
}

pub fn getElementReference(self: *Element, comptime attribute: ElementReferenceAttribute, frame: *Frame) ?*Element {
    if (frame._element_references.get(.{ .element = self, .attribute = attribute })) |explicit| {
        // Same rule as popover's invoker target: the two have to share a root.
        if (explicit.asNode().getRootNode(.{}) == self.asNode().getRootNode(.{})) {
            return explicit;
        }
        return null;
    }
    const id = self.getAttributeSafe(comptime .wrap(@tagName(attribute))) orelse return null;
    return frame.getElementByIdFromNode(self.asNode(), id);
}

pub fn setElementReference(self: *Element, comptime attribute: ElementReferenceAttribute, value: ?*Element, frame: *Frame) !void {
    const name = comptime String.wrap(@tagName(attribute));
    const target = value orelse {
        _ = frame._element_references.remove(.{ .element = self, .attribute = attribute });
        return self.removeAttribute(name, frame);
    };
    try frame._element_references.put(frame.arena, .{ .element = self, .attribute = attribute }, target);
    return self.setAttributeSafe(name, .wrap(""), frame);
}

pub fn getDataset(self: *Element, frame: *Frame) !*DOMStringMap {
    const gop = try frame._element_datasets.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(DOMStringMap{
            ._element = self,
        });
    }
    return gop.value_ptr.*;
}

// ARIAMixin. Every member reflects a lowercase attribute of the same name with
// the `aria` camel case flattened — ariaBrailleRoleDescription is
// aria-brailleroledescription, ariaPosInSet is aria-posinset — and none of them
// parses its value: null when the attribute is absent, the raw string
// otherwise, and assigning null removes the attribute. Measured uniformly
// across the whole family on a headed Chrome 150, including the ones whose
// names suggest a number (ariaValueMax, ariaColSpan) or a boolean
// (ariaMultiLine).
fn reflectedAttribute(comptime attribute: []const u8) type {
    return struct {
        // Most of these names are past String's 12-byte comptime SSO limit
        // (aria-brailleroledescription is 27), so the wrap runs at runtime.
        pub fn get(self: *const Element) ?[]const u8 {
            return self.getAttributeSafe(.wrap(attribute));
        }

        pub fn set(self: *Element, value: ?[]const u8, frame: *Frame) !void {
            if (value) |v| {
                return self.setAttributeSafe(.wrap(attribute), .wrap(v), frame);
            }
            return self.removeAttribute(.wrap(attribute), frame);
        }
    };
}

// elementTiming is not part of ARIAMixin and does not behave like it: it is a
// plain DOMString reflection, so it reads "" when unset and assigning null
// writes the string "null" instead of removing the attribute (measured).
pub fn getElementTiming(self: *const Element) []const u8 {
    return self.getAttributeSafe(.wrap("elementtiming")) orelse "";
}

pub fn setElementTiming(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(.wrap("elementtiming"), .wrap(value), frame);
}

// The IDREF-list reflections resolve their attribute to elements, so they answer
// null while the attribute is absent rather than an empty array.
fn reflectedElements(comptime attribute: []const u8) type {
    return struct {
        pub fn get(self: *Element, frame: *Frame) !?[]const *Element {
            const raw = self.getAttributeSafe(.wrap(attribute)) orelse return null;
            const document = self.asNode().ownerDocument(frame) orelse return null;

            var found: std.ArrayList(*Element) = .empty;
            var it = std.mem.tokenizeAny(u8, raw, " \t\n\r\x0C");
            while (it.next()) |id| {
                const element = document.getElementById(id, frame) orelse continue;
                try found.append(frame.local_arena, element);
            }
            return found.items;
        }

        pub fn set(self: *Element, _: ?[]const *Element, frame: *Frame) !void {
            // Assigning elements would need a per-element explicit-set store,
            // which nothing here reads back. Clearing the attribute is the part
            // that is observable through the reflection.
            return self.removeAttribute(.wrap(attribute), frame);
        }
    };
}

// Pointer capture. There is no pointer to capture, so nothing is ever captured
// and both the grab and the release are no-ops. Chrome answers the same shapes
// on a page that has not been interacted with.
pub fn hasPointerCapture(_: *const Element, _: ?i32) bool {
    return false;
}

pub fn setPointerCapture(_: *const Element, _: ?i32) void {}
pub fn releasePointerCapture(_: *const Element, _: ?i32) void {}

// The webkit spellings are synchronous and return undefined; only the
// unprefixed requestFullscreen is a promise. Measured rejections: a fullscreen
// request with no user gesture behind it is a bare TypeError ("Permissions
// check failed"), and pointer lock on a document that cannot host it is a
// WrongDocumentError.
pub fn webkitRequestFullscreen(_: *const Element) void {}

pub fn requestFullscreen(_: *const Element, _: ?js.Object, exec: *const js.Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .type_error = "Permissions check failed" });
}

pub fn requestPointerLock(_: *const Element, _: ?js.Object, exec: *const js.Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.WrongDocumentError } });
}

// CSS zoom is not something we apply, so the effective zoom is always 1.
pub fn getCurrentCSSZoom(_: *const Element) f64 {
    return 1;
}

pub fn getActiveViewTransition(_: *const Element) ?*document_services.ViewTransition {
    return null;
}

// The same registry as window.customElements (measured:
// element.customElementRegistry === window.customElements).
pub fn getCustomElementRegistry(_: *const Element, frame: *Frame) ?*CustomElementRegistry {
    return frame.window.getCustomElements();
}

pub fn ariaNotify(_: *const Element, _: []const u8, _: ?js.Object) void {}

// A transition scoped to this element rather than to the document, which is
// what Chrome reports as its transitionRoot.
pub fn startViewTransition(self: *Element, _: ?js.Object, frame: *Frame) !*document_services.ViewTransition {
    return document_services.ViewTransition.init(self, frame);
}

// getHTML is the modern name for getInnerHTML. The options dictionary selects
// which shadow roots are serialized; upstream's `Element.getHTML` above (which
// takes a writer and a dump.Opts) implements it, and the JsApi member wraps it.
// The duplicate that ignored the dictionary lived here and is gone.

// setHTML parses with sanitization: measured in Chrome,
// '<b onclick="x()">hi</b><script>bad()</script>' becomes '<b>hi</b>'. Event
// handler attributes and script elements are dropped.
pub fn setHTML(self: *Element, html: []const u8, _: ?js.Object, frame: *Frame) !void {
    try self.setHTMLUnsafe(html, frame);
    sanitizeTree(self.asNode(), frame);
}

pub fn sanitizeTree(root: *Node, frame: *Frame) void {
    var walker = @import("TreeWalker.zig").Full.init(root, .{});
    while (walker.next()) |node| {
        const element = node.is(Element) orelse continue;
        if (element.is(Element.Html.Script) != null) {
            element.remove(frame);
            continue;
        }
        const names = element.getAttributeNames(frame) catch continue;
        for (names) |name| {
            if (name.len > 2 and std.ascii.startsWithIgnoreCase(name, "on")) {
                element.removeAttribute(.wrap(name), frame) catch {};
            }
        }
    }
}

// element.pseudo(selector) names one of this element's pseudo-elements. The
// selector must be a pseudo-element selector; anything else is null rather than
// an error (measured).
pub fn pseudo(self: *Element, selector: []const u8, frame: *Frame) !?*document_services.CSSPseudoElement {
    if (!std.mem.startsWith(u8, selector, "::")) {
        return null;
    }
    return document_services.CSSPseudoElement.init(self, try frame.arena.dupe(u8, selector), frame);
}

pub fn replaceChildren(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn replaceWith(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const ref_node = self.asNode();
    const parent = ref_node._parent orelse return;
    frame.domChanged();

    // Detect if the ref_node must be removed (by default) or kept.
    // We kept it when ref_node is present into the nodes list.
    var rm_ref_node = true;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // If a child is the ref node. We keep it at its own current position.
        if (child == ref_node) {
            rm_ref_node = false;
            continue;
        }

        // A DocumentFragment contributes its children, not itself
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.insertAllChildrenBefore(child, parent, ref_node);
            continue;
        }

        var previous_root: ?*Node = null;
        if (child._parent) |current_parent| {
            previous_root = child.getRootNode(.{});
            frame.removeNode(current_parent, child, .{ .reconnect_to = parent });
        }

        try frame.insertNodeRelative(
            parent,
            child,
            .{ .before = ref_node },
            .{ .previous_root = previous_root },
        );
    }

    // Re-check parent after insertNodeRelative since callbacks (e.g. connectedCallback)
    // could have already removed ref_node from parent.
    if (rm_ref_node and ref_node._parent == parent) {
        frame.removeNode(parent, ref_node, .{ .reconnect_to = null });
    }
}

pub fn remove(self: *Element, frame: *Frame) void {
    const node = self.asNode();
    const parent = node._parent orelse return;
    frame.domChanged();
    frame.removeNode(parent, node, .{ .reconnect_to = null });
}

pub fn focus(self: *Element, frame: *Frame) !void {
    if (self.asNode().isConnected() == false) {
        // a disconnected node cannot take focus
        return;
    }

    // Per HTML spec §6.4.4, an element must be "being rendered" (not
    // display:none on self or any ancestor) to be focusable.
    if (!self.checkVisibilityCached(null, frame)) {
        return;
    }

    const FocusEvent = @import("event/FocusEvent.zig");

    const new_target = self.asEventTarget();
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    const old_active = doc._active_element;
    doc._active_element = self;

    if (old_active) |old| {
        if (old == self) {
            return;
        }

        const old_target = old.asEventTarget();

        // Dispatch blur on old element (no bubble, composed)
        const blur_event = try FocusEvent.initTrusted(comptime .wrap("blur"), .{ .composed = true, .relatedTarget = new_target }, frame);
        try frame._event_manager.dispatch(old_target, blur_event.asEvent());

        // Dispatch focusout on old element (bubbles, composed)
        const focusout_event = try FocusEvent.initTrusted(comptime .wrap("focusout"), .{ .bubbles = true, .composed = true, .relatedTarget = new_target }, frame);
        try frame._event_manager.dispatch(old_target, focusout_event.asEvent());
    }

    const old_related: ?*EventTarget = if (old_active) |old| old.asEventTarget() else null;

    // Dispatch focus on new element (no bubble, composed)
    const focus_event = try FocusEvent.initTrusted(comptime .wrap("focus"), .{ .composed = true, .relatedTarget = old_related }, frame);
    try frame._event_manager.dispatch(new_target, focus_event.asEvent());

    // Dispatch focusin on new element (bubbles, composed)
    const focusin_event = try FocusEvent.initTrusted(comptime .wrap("focusin"), .{ .bubbles = true, .composed = true, .relatedTarget = old_related }, frame);
    try frame._event_manager.dispatch(new_target, focusin_event.asEvent());
}

pub fn blur(self: *Element, frame: *Frame) !void {
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    if (doc._active_element != self) return;

    doc._active_element = null;

    const FocusEvent = @import("event/FocusEvent.zig");
    const old_target = self.asEventTarget();

    // Dispatch blur (no bubble, composed)
    const blur_event = try FocusEvent.initTrusted(comptime .wrap("blur"), .{ .composed = true }, frame);
    try frame._event_manager.dispatch(old_target, blur_event.asEvent());

    // Dispatch focusout (bubbles, composed)
    const focusout_event = try FocusEvent.initTrusted(comptime .wrap("focusout"), .{ .bubbles = true, .composed = true }, frame);
    try frame._event_manager.dispatch(old_target, focusout_event.asEvent());
}

pub fn getChildren(self: *Element, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn append(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().appendNodes(nodes, frame);
}

pub fn prepend(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().prependNodes(nodes, frame);
}

pub fn moveBefore(self: *Element, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

pub fn before(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, node, frame);
    }
}

pub fn after(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const viable_next = Node.NodeOrText.viableNextSibling(node, nodes);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, viable_next, frame);
    }
}

pub fn firstElementChild(self: *Element) ?*Element {
    var maybe_child = self.asNode().firstChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.nextSibling();
    }
    return null;
}

pub fn lastElementChild(self: *Element) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn nextElementSibling(self: *Element) ?*Element {
    var maybe_sibling = self.asNode().nextSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Element)) |el| return el;
        maybe_sibling = sibling.nextSibling();
    }
    return null;
}

pub fn previousElementSibling(self: *Element) ?*Element {
    var maybe_sibling = self.asNode().previousSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Element)) |el| return el;
        maybe_sibling = sibling.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Element) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element) != null) {
            count += 1;
        }
    }
    return count;
}

pub fn matches(self: *Element, selector: []const u8, frame: *Frame) !bool {
    return Selector.matches(self, selector, frame) catch |err|
        Selector.failToDOM(err, selector, "matches", "Element", frame);
}

pub fn querySelector(self: *Element, selector: []const u8, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), selector, frame) catch |err|
        Selector.failToDOM(err, selector, "querySelector", "Element", frame);
}

pub fn querySelectorAll(self: *Element, input: []const u8, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, frame) catch |err|
        Selector.failToDOM(err, input, "querySelectorAll", "Element", frame);
}

pub fn getAnimations(_: *const Element) []*Animation {
    return &.{};
}

/// Chrome answers with an Animation whose `effect` is a KeyframeEffect built
/// from the two arguments; ours used to leave `effect` null, which no browser
/// does (measured on a headed Chrome 150, probe-win29).
pub fn animate(self: *Element, keyframes: ?js.Value, options: ?js.Value, exec: *js.Execution) !*Animation {
    const frame = switch (exec.js.global) {
        .frame => |f| f,
        .worker => return error.NotSupportedError,
    };

    const animation = try Animation.init(frame);
    const effect = try KeyframeEffect.initForTarget(self, keyframes, options, exec);
    const value = try exec.js.local.?.zigValueToJs(effect, .{});
    animation._effect = try value.toObject().persist();
    return animation;
}

pub fn closest(self: *Element, input: []const u8, frame: *Frame) !?*Element {
    // Unlike its three neighbours this one never went through the DOMException
    // mapping, so a bad selector came out as the raw Zig error name
    // (`Error: InvalidIDSelector`), which no browser produces.
    const selector = Selector.cachedParse(frame._session.browser, input) catch |err|
        return Selector.failToDOM(err, input, "closest", "Element", frame);

    var current: ?*Element = self;
    while (current) |el| {
        if (try Selector.matchesWithScope(el, selector, self, frame)) {
            return el;
        }

        const parent = el.asNode()._parent orelse break;

        if (parent.is(ShadowRoot) != null) {
            break;
        }

        current = parent.is(Element);
    }
    return null;
}

pub fn parentElement(self: *Element) ?*Element {
    return self.asNode().parentElement();
}

/// Cache for visibility checks - re-exported from StyleManager for convenience.
pub const VisibilityCache = StyleManager.VisibilityCache;

/// Cache for pointer-events checks - re-exported from StyleManager for convenience.
pub const PointerEventsCache = StyleManager.PointerEventsCache;

// Style checks go through the StyleManager of the element's own frame, not
// the caller's: its stylesheets and materialized inline styles are per-frame,
// and a same-origin script can reach an element in another frame.
pub fn hasPointerEventsNone(self: *Element, cache: ?*PointerEventsCache, frame: *Frame) bool {
    return self.ownerFrame(frame)._style_manager.hasPointerEventsNone(self, cache);
}

pub fn checkVisibilityCached(self: *Element, cache: ?*VisibilityCache, frame: *Frame) bool {
    return !self.ownerFrame(frame)._style_manager.isHidden(self, cache, .{ .boxless_hidden = true });
}

const CheckVisibilityOpts = struct {
    checkOpacity: bool = false,
    opacityProperty: bool = false,
    checkVisibilityCSS: bool = false,
    visibilityProperty: bool = false,
};
pub fn checkVisibility(self: *Element, opts_: ?CheckVisibilityOpts, frame: *Frame) bool {
    const opts = opts_ orelse CheckVisibilityOpts{};
    return !self.ownerFrame(frame)._style_manager.isHidden(self, null, .{
        .check_opacity = opts.checkOpacity or opts.opacityProperty,
        .check_visibility = opts.visibilityProperty or opts.checkVisibilityCSS,
        .boxless_hidden = true,
    });
}

/// Chrome's default font size, and what text inherits when nothing on the
/// ancestor chain sets one.
const default_font_size = 16.0;

/// The font an element's text is laid out in.
///
/// There is no cascade in this engine — `getStyle` hands back the element's
/// own inline declaration and nothing else — so inheritance is done here, by
/// walking to the nearest ancestor that names each property. That covers the
/// pages that set a font at all; anything relying on a stylesheet's cascade
/// gets the default, which is what it got before this existed too.
fn resolveFont(self: *Element, frame: *Frame) struct { family: font_metrics.Family, size: f64 } {
    var size: ?f64 = null;
    var family: ?font_metrics.Family = null;

    var node: ?*Node = self.asNode();
    while (node) |current| : (node = current._parent) {
        const el = current.is(Element) orelse continue;
        const style = el.getStyle(frame) orelse continue;

        if (size == null) {
            const declared = style.getPropertyValue("font-size", frame);
            if (declared.len != 0) {
                size = CSS.parseDimensionViewport(declared, frame);
            }
        }
        if (family == null) {
            const declared = style.getPropertyValue("font-family", frame);
            if (declared.len != 0) {
                family = font_metrics.findInList(declared);
            }
        }
        if (size != null and family != null) {
            break;
        }
    }

    return .{
        .family = family orelse font_metrics.fallback,
        .size = size orelse default_font_size,
    };
}

/// The characters CSS collapses: "document white space characters" are space,
/// tab, line feed, carriage return and form feed. Deliberately not
/// `std.ascii.whitespace`, which also holds a vertical tab -- CSS does not
/// collapse one -- and deliberately byte-wise, because every character CSS
/// treats as whitespace is ASCII: `&nbsp;` (U+00A0) and a zero-width space
/// (U+200B) are not collapsible, and their UTF-8 bytes are all >= 0x80, so they
/// fall out of this on their own. Both measured at a full line in Chrome.
const css_whitespace = " \t\n\r\x0c";

fn isCollapsibleWhitespace(str: []const u8) bool {
    for (str) |c| {
        if (std.mem.indexOfScalar(u8, css_whitespace, c) == null) return false;
    }
    return true;
}

/// Whether `white-space` keeps this element's spaces rather than collapsing
/// them. Only `pre`, `pre-wrap` and `break-spaces` do: `pre-line` collapses
/// spaces and tabs (it preserves only newlines, and a newline alone still makes
/// no line box) and `nowrap` collapses everything `normal` does. Measured, see
/// textLayout.
fn preservesWhitespace(self: *Element, frame: *Frame) bool {
    const declared = CSSStyleDeclaration.cascadedComputedValue(self, "white-space", frame) orelse return false;
    const trimmed = std.mem.trim(u8, declared, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "pre") or
        std.ascii.eqlIgnoreCase(trimmed, "pre-wrap") or
        std.ascii.eqlIgnoreCase(trimmed, "break-spaces");
}

/// How an element's own text lays out, or null when the element is not one
/// whose box its text decides — it has element children of its own, or it
/// holds no text.
///
/// Advances are additive and we model no kerning (see `text_measure`), so the
/// runs are summed rather than concatenated into a buffer: this sits under
/// `offsetWidth`, which pages read in loops.
///
/// Height is the font's own box, ascent plus descent. Chrome's line box is a
/// little taller — it adds the font's line gap, which these tables do not
/// carry (the reference reports 83 for 72px serif where ascent and descent sum
/// to 80). Close and derived from a measurement, rather than exact; still the
/// difference between a line that scales with its font and one that does not.
///
/// Because the height is the font's box and nothing else, a caller that wants
/// only the height can pass `measure_width = false` and skip the walk over the
/// text — which is the whole cost here on any element holding a sentence. The
/// returned `width` is then 0 and must not be read.
fn textLayout(self: *Element, frame: *Frame, measure_width: bool) ?struct { width: f64, height: f64 } {
    var total_text: usize = 0;
    var all_collapsible = true;
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element) != null) {
            return null;
        }
        if (node.is(CData.Text)) |text| {
            const str = Factory.protoOf(text)._data.str();
            total_text += str.len;
            if (all_collapsible and !isCollapsibleWhitespace(str)) all_collapsible = false;
        }
    }
    if (total_text == 0) {
        return null;
    }
    // Whitespace with nothing beside it collapses away entirely, so there is no
    // line box and the box is 0 tall -- this engine gave `<div> </div>` a full
    // 18px line, which is the opposite mistake to the 5px placeholder. Unless
    // `white-space` preserves it, in which case the space is a space.
    // Measured on Chrome 151 with
    // tools/fingerprint/scratch/expr-whitespace-linebox.js: a space, a tab and
    // three newlines are all 0; `pre` and `pre-wrap` are 18 and `pre-line` and
    // `nowrap` are 0; and `&nbsp;` and a zero-width space are 18, because
    // neither is collapsible whitespace to begin with.
    //
    // Asking for `white-space` costs a cascade, so it is only asked once the
    // characters have already said the answer could go either way.
    if (all_collapsible and !self.preservesWhitespace(frame)) {
        return null;
    }

    const font = self.resolveFont(frame);
    var width: f64 = 0;
    if (measure_width) {
        child = self.asNode().firstChild();
        while (child) |node| : (child = node.nextSibling()) {
            if (node.is(CData.Text)) |text| {
                width += text_measure.measure(font.family, Factory.protoOf(text)._data.str(), font.size).width;
            }
        }
    }

    const box = font_metrics.boundingBox(font.family, font.size);

    // offsetWidth is an integer; getBoundingClientRect keeps the fraction, but
    // this engine has one dimension model behind both.
    return .{ .width = @round(width), .height = @round(box.ascent + box.descent) };
}

/// The narrowest box this element's text can be laid out in: its longest
/// unbreakable word, since that is the one thing a line break cannot shorten.
/// Null for an element this faux layout has no text run for -- one holding
/// other elements, or holding nothing.
///
/// A flex item is never sized below this, which is CSS Flexbox's automatic
/// minimum size. Measured against Chrome 151 with
/// tools/fingerprint/scratch/expr-flex-min-content.js: an item of twenty `x`
/// in a row, given `flex-basis: 0`, is 160px in Chrome and not 0 -- and one
/// holding a sentence of four-letter words is 32, which is one word and not the
/// 363 the whole sentence takes. Two `flex: 1` items of that same word in a
/// 200px row are 160 each, overflowing the row rather than taking their 100.
pub fn minContentWidth(self: *Element, frame: *Frame) ?f64 {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element) != null) {
            return null;
        }
    }

    const font = self.resolveFont(frame);
    var widest: f64 = 0;
    var seen = false;
    child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        const text = node.is(CData.Text) orelse continue;
        var words = std.mem.tokenizeAny(u8, Factory.protoOf(text)._data.str(), &std.ascii.whitespace);
        while (words.next()) |word| {
            seen = true;
            widest = @max(widest, text_measure.measure(font.family, word, font.size).width);
        }
    }
    if (!seen) return null;
    return @round(widest);
}

/// The ink a non-replaced inline box's line boxes take: this element's own text
/// plus whatever its children occupy. Neither a declared width nor a declared
/// height reaches it -- neither property applies to an inline box -- so this is
/// the only size it has.
///
/// Measured with tools/fingerprint/scratch/expr-inline-box.js against Chrome
/// 151: `<span>x</span>` is 8x18 with an empty one at 0x0, `<span>xx<b>yy</b>
/// </span>` is 32 wide (its own text plus the child's), and a <span> holding a
/// <div> is 1904 -- the block escapes the inline and fills the block container,
/// which is what containingBlock walks up to find.
fn inlineInk(self: *Element, frame: *Frame, depth: u8, containing: *?f64) struct { width: f64, height: f64 } {
    // The same backstop the containing-block walk has. A chain of inline
    // elements is measured one level at a time, and this is what stops a page
    // that nests them beyond anything real from walking forever.
    if (depth >= MAX_CONTAINING_BLOCK_DEPTH) return .{ .width = 0, .height = 0 };

    var width: f64 = 0;
    var height: f64 = 0;
    var text_width: f64 = 0;
    var has_text = false;

    const font = self.resolveFont(frame);
    var visibility_cache: VisibilityCache = .{};
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(CData.Text)) |text| {
            const str = Factory.protoOf(text)._data.str();
            if (str.len == 0) continue;
            has_text = true;
            text_width += text_measure.measure(font.family, str, font.size).width;
            continue;
        }
        if (node.is(Element)) |el| {
            if (!el.checkVisibilityCached(&visibility_cache, frame)) continue;
            // A block-level child breaks the inline in two and the box it
            // leaves behind spans the whole line, whatever width the child
            // itself took: `<span><div style="width:50%">x</div></span>` is
            // 1904 in Chrome on the 1904px line and not the 952 the <div> is.
            if (CSSStyleDeclaration.breaksInline(el, frame)) {
                const box = el.dimensionsAt(frame, true, depth + 1, true);
                height = @max(height, box.height + box.padding_y + box.border_y);
                if (CSSStyleDeclaration.containingWidth(self, frame, containing, depth)) |line| {
                    width = @max(width, line);
                }
                continue;
            }
            // ONE measurement per child, carrying the depth down. Asking
            // getOffsetWidth and getOffsetHeight instead measured the child
            // twice and started each measurement over at depth 0, so a chain
            // of nested inlines cost 2^n: sixty <span>s around one character
            // never came back, and a real page's did not either -- it took the
            // engine out with a SIGBUS mid-sweep.
            const box = el.dimensionsAt(frame, true, depth + 1, true);
            width += box.width + box.padding_x + box.border_x;
            height = @max(height, box.height + box.padding_y + box.border_y);
        }
    }

    width += @round(text_width);
    if (has_text) {
        const box = font_metrics.boundingBox(font.family, font.size);
        height = @max(height, @round(box.ascent + box.descent));
    }
    return .{ .width = width, .height = height };
}

/// Chrome draws a broken-image icon in place of an <img> whose bytes never
/// became a picture, so the element still has a box even though it has no
/// intrinsic size. Measured on Chrome 151 (probe `expr-broken-image.js`): a
/// connected <img> with an unresolvable src reads 16 for width, height,
/// offsetWidth, offsetHeight and getBoundingClientRect, while naturalWidth and
/// naturalHeight stay 0. bot.sannysoft.com's "Broken Image Dimensions" row
/// reads exactly this pair.
pub const broken_image_icon_size = 16.0;

/// The `body { margin: 8px }` every UA stylesheet carries, which is why a
/// document's <body> box is 16px narrower and shorter than its viewport --
/// Chrome reports 284x134 for the body of a 300x150 iframe. The same 8px is in
/// css/chrome_per_tag_values.zig as the value getComputedStyle reports; this is
/// the one place layout has to subtract it.
const body_ua_margin = 8.0;

/// Is this element laid out as the broken-image icon?
///
/// Nothing here decodes -- the bytes are fetched and dropped (see
/// `Frame.loadImage`) -- so every <img> that asked for bytes is in the broken
/// state, which is the state a real browser draws the icon for.
///
/// Drawing one takes a rendering. Chrome reads 0 for a detached <img> and 0
/// for a connected one with no src, and in both cases that is what the
/// reflected width/height attribute already answers, so neither gets an icon.
pub fn hasBrokenImageBox(self: *const Element) bool {
    if (self.getTag() != .img) {
        return false;
    }
    const src = self.getAttributeSafe(comptime .wrap("src")) orelse return false;
    if (src.len == 0) {
        return false;
    }
    return self.asConstNode().isConnected();
}

/// `width` and `height` are the CONTENT box. What a page reads is one of three
/// boxes and the edges are how they are told apart: clientWidth is content +
/// padding, offsetWidth and getBoundingClientRect add the border, and a
/// computed `width` is the content box (or the border box, under
/// `box-sizing: border-box`). CSSStyleDeclaration.boxEdges carries the
/// measurements.
///
/// The edges are only filled in on the `measure_text_width` path. The one
/// caller that clears that flag is `getElementHeight`, the y-only walk
/// document.elementFromPoint rejects thousands of elements on, and reading four
/// more longhands per element there is what the whole flag exists to avoid --
/// so hit testing goes on using the content box, as it always has.
pub const Dimensions = struct {
    width: f64,
    height: f64,
    // if the value is explicit (e.g. inline style, width attribute, ...) or defaulted
    explicit_width: bool = false,
    explicit_height: bool = false,
    padding_x: f64 = 0,
    padding_y: f64 = 0,
    border_x: f64 = 0,
    border_y: f64 = 0,
    /// A non-replaced `display: inline` element, which has no CSS box: its
    /// clientWidth, clientHeight, scrollWidth and scrollHeight are all 0 and
    /// its computed `width` and `height` are `auto`, while offsetWidth and
    /// getBoundingClientRect still answer the ink its line boxes take.
    /// `width` and `height` here are that ink. Only ever set on the
    /// `measure_text_width` path, like the edges.
    inline_box: bool = false,
};

pub fn getElementDimensions(self: *Element, frame: *Frame) Dimensions {
    return self.dimensions(frame, true);
}

/// Just the height of the box, for the callers that have no use for its width.
/// Worth its own entry point because a width can cost a walk over every
/// character of the element's text while the height never does: an element
/// holding a sentence is two orders of magnitude cheaper to measure vertically.
/// `document.elementFromPoint` rejects all but a handful of elements on their
/// y alone, and it is the difference between reading a document and measuring
/// one.
pub fn getElementHeight(self: *Element, frame: *Frame) f64 {
    return self.dimensions(frame, false).height;
}

fn dimensions(self: *Element, frame: *Frame, comptime measure_text_width: bool) Dimensions {
    return self.dimensionsAt(frame, measure_text_width, 0, true);
}

/// A length as the layout holds it. Chrome lays out on a 1/64px grid --
/// Blink's LayoutUnit -- and reaches it by flooring, not rounding: `33.3%` of
/// 400px is 133.2 in arithmetic and 8524/64 on the page, because 133.2 x 64 is
/// 8524.8 and the .8 is dropped. Measured with
/// tools/fingerprint/scratch/expr-layout-grid.js and expr-grid-props.js.
///
/// Only USED lengths pass through here. A computed value that is not one --
/// `padding-left:10.1px`, `margin-left:10.1px`, `font-size:13.3px`, `0.5em` of
/// it -- is the length the author wrote and Chrome reports it unchanged, which
/// the same probes checked one property at a time.
///
/// Feed this the number, never a number parsed back out of a computed style: a
/// computed length is written to six significant figures, and a snapped
/// `33.328125` comes back as `33.3281`, a hair below its own grid step, which
/// this would then drop to the step beneath. There is no tolerance that fixes
/// that -- a value genuinely 0.0002 below a step and a printed one 0.0002
/// below the same step are the same two digits -- so the layout asks
/// CSSStyleDeclaration.cascadedComputedLength for the number instead.
///
/// The number is narrowed to a **32-bit float** before the floor, because that
/// is the width Blink carries a length in and it decides which side of a step
/// the value falls on: `width:100.0156249px` is a hair under a step as a double
/// and floors to 100, and IS the step as a float, which is what Chrome answers.
/// Measured over twenty-one widths chosen to separate the two
/// (tools/fingerprint/scratch/expr-precision-model.js): the float matches Chrome
/// 21 times and the double 15.
///
/// This is also what absorbs the last bit of arithmetic drift, which an epsilon
/// used to be here for -- a product that comes out 1e-13 under an exact step is
/// that step once it is a float, and the epsilon is a guess at the same thing.
pub fn layoutUnit(px: f64) f64 {
    const narrowed: f64 = @as(f32, @floatCast(px));
    return @floor(narrowed * 64.0) / 64.0;
}

/// How many measurements may be in flight at once, counting every route in --
/// including the ones that do not carry `depth`. Well past any real page's
/// nesting, and small enough that a cycle unwinds long before the stack ends.
pub const MAX_LAYOUT_REENTRY = 256;

/// How deep the containing-block walk may go. A page's block nesting is far
/// shallower than this; the cap exists so a tree that somehow made a cycle
/// stops rather than recursing forever.
pub const MAX_CONTAINING_BLOCK_DEPTH = 64;

/// The ancestor whose content box this element's own box is laid out in. Not
/// always the parent element: an inline box is not a containing block for a
/// block-level child, so a <div> inside a <span> fills the block container the
/// span itself sits in -- 1904 and not the span's 8, measured.
pub fn containingBlock(self: *Element, frame: *Frame) ?*Element {
    var ancestor = self.parentElement();
    while (ancestor) |current| : (ancestor = current.parentElement()) {
        if (!CSSStyleDeclaration.isInlineBox(current, frame)) return current;
    }
    return null;
}

/// The horizontal margin that comes off the containing block before the box
/// gets what is left. From the cascade, so a stylesheet rule counts. Asked from
/// two places, both of which already hold the containing block's width: the fill
/// branch in dimensionsAt, and the flex line in CSSStyleDeclaration.
///
/// `containing` is the caller's own measurement of the containing block, shared
/// so that a percentage margin costs nothing extra. Both margins go through the
/// one number: letting each measure the parent for itself is the shape that made
/// a percentage padding cost 5^n down a chain and took the engine out with a
/// SIGBUS on www.sony.com, and the computed-value path a percentage would
/// otherwise take is worse still -- it starts a fresh measurement at depth 0.
pub fn horizontalMargin(self: *Element, frame: *Frame, containing: *?f64, depth: u8) f64 {
    var total: f64 = 0;
    inline for (.{ "margin-left", "margin-right" }) |name| {
        if (CSSStyleDeclaration.marginPercentagePx(self, name, frame, containing, depth)) |px| {
            total += px;
        } else if (CSSStyleDeclaration.specifiedPx(self, name, frame)) |px| {
            // The author's number, for the same reason the percentage above
            // does not go through the computed text: six significant figures of
            // `465.5466592px` takes a grid step too much off the line.
            total += px;
        } else if (CSSStyleDeclaration.cascadedComputedValue(self, name, frame)) |declared| {
            if (CSS.parseDimensionViewport(declared, frame)) |px| {
                total += px;
            }
        }
    }
    return total;
}

/// The CONTENT box an element has because of what it is rather than what it
/// holds, for one that declares no size. Null for a tag whose empty box is
/// nothing at all -- a div, a table, an <img> with no src -- which is the
/// majority and which `null` at the end of dimensionsAt already answers as 0.
///
/// Measured on Chrome 151 with tools/fingerprint/scratch/expr-empty-intrinsic.js,
/// expr-five-sentinel.js and expr-replaced-intrinsic.js, in a 400px line. Not a
/// rule with exceptions -- twenty tags fell into four groups and a blanket 0
/// would be wrong for eleven of them -- so it is the table:
///
///   * `canvas`, `video`, `object`, `svg` and `iframe` are 300x150, the replaced
///     default, with no attributes and no rules at all;
///   * a form control's size is its own and no two are alike. These are content
///     boxes, so the UA padding and border add on top: an `<input>` is 145x15 of
///     content, 149x17 of client and 153x21 of offset, and a `<select>` is
///     20x17, 20x17 and 22x19 -- and 22x19 of computed size too, because
///     `box-sizing: border-box` is a UA rule for it;
///   * `button` is deliberately absent. Its whole 16x6 box is the UA padding and
///     border around a 0x0 content box -- forcing it to content-box computes
///     `0px` of width in Chrome, measured -- so it needs no entry, only the UA
///     edges the layout can now see.
///
/// One measured gap left out on purpose, because it is a different feature: a
/// `<canvas>` has an intrinsic RATIO from its buffer, so `width:600px` on a bare
/// one makes it 300 tall in Chrome and 150 here, and `<canvas width=400
/// height=100 style="height:50px">` is 200 wide. `video`, `object` and `svg`
/// have no such ratio -- each keeps its 300 or its 150 when the other axis is
/// declared, and an `<svg viewBox="0 0 40 10">` at 600px wide is still 150 tall.
/// All four measured (expr-replaced-intrinsic.js and the ratio probe beside it).
fn intrinsicBox(tag: Tag) ?struct { width: f64, height: f64 } {
    return switch (tag) {
        .canvas, .video, .object, .svg, .iframe => .{ .width = 300, .height = 150 },
        .input => .{ .width = 145, .height = 15 },
        .textarea => .{ .width = 177, .height = 30 },
        .select => .{ .width = 20, .height = 17 },
        .progress => .{ .width = 160, .height = 16 },
        .meter => .{ .width = 80, .height = 16 },
        else => null,
    };
}

/// `distribute_flex` is how a flex item's own share of its line is kept from
/// recursing: measuring one item's flex base size asks its siblings for theirs,
/// and a sibling asked with the distribution still on would ask back.
pub fn dimensionsAt(self: *Element, frame: *Frame, comptime measure_text_width: bool, depth: u8, distribute_flex: bool) Dimensions {
    // A backstop the `depth` parameter cannot be: not every path down carries
    // it. A percentage width resolves through the computed-value machinery,
    // which reaches back for the containing block's box through
    // `getElementDimensions` -- and that starts a fresh measurement at depth 0.
    // `<span><div style="width:50%">x</div></span>` used to be a closed loop
    // because of it: the span's ink asked the div, the div's percentage asked
    // the span, and neither call's depth ever grew. This counter grows for
    // every measurement in flight whatever route it came in by.
    if (frame._layout_depth >= MAX_LAYOUT_REENTRY) {
        return .{ .width = 0, .height = 0 };
    }
    frame._layout_depth += 1;
    defer frame._layout_depth -= 1;

    var dims: Dimensions = .{ .width = 0, .height = 0 };

    // Nothing has sized the box yet, and `null` is how that is said. It used to
    // be said with 5.0 -- the measurement started at {5, 5} and every branch
    // below asked `dims.height == 5.0` to mean "still undetermined" -- which
    // made a magic number out of a length an author may write. Measured on
    // Chrome 151 with tools/fingerprint/scratch/expr-five-sentinel.js: seven
    // readings across four shapes had their declaration taken for the absence
    // of one, and `<div style="width:5px">` came out reporting a computed
    // `width` of 5px beside a clientWidth of 400, because getComputedStyle
    // reads the declaration and the fill branch had overwritten the box. No
    // browser produces a 5px-wide box that is 400px wide, and a guard reading
    // both at once sees it.
    //
    // Whatever is still `null` at the end is a box with no size, which is 0 --
    // an empty `<div>`, an empty `<table>`, an `<img>` with no src, an empty
    // float or absolute, all measured at 0 in Chrome. Per-tag intrinsic sizes
    // that are NOT 0 (the 300x150 of a `<canvas>`, a form control's own height)
    // are the tag branches' to fill in.
    var width: ?f64 = null;
    var height: ?f64 = null;

    // Width comes from the cascade, so a stylesheet rule reaches the box the
    // way it already reached `getComputedStyle`. It is behind
    // `measure_text_width` because asking costs a cascade and the caller that
    // clears that flag -- `getElementHeight`, the y-only path
    // document.elementFromPoint rejects thousands of elements on -- has no use
    // for a width at all.
    //
    // `inline-size` and `width` are one property under two spellings
    // (chrome_logical.zig is the measured pairing); cascadedComputedValue asks
    // for the other one when the first has nothing, the same as the computed
    // path does.
    // The containing block's content width, measured at most once for this
    // element and then shared: a percentage padding needs it, and so does the
    // fill branch below. Measuring it per asker cost 5^n down a chain of
    // percentage-padded elements -- see CSSStyleDeclaration.boxEdgesSharing.
    var containing: ?f64 = null;

    // What a declared width and height name: the content box, or the border box
    // when `box-sizing` says so. Only asked on this path -- see Dimensions.
    const border_box = if (comptime measure_text_width) CSSStyleDeclaration.usesBorderBox(self, frame) else false;
    dims.inline_box = if (comptime measure_text_width) CSSStyleDeclaration.isInlineBox(self, frame) else false;

    // A non-replaced inline box takes no width or height from a declaration --
    // neither property applies to one -- so its ink is all there is. Measured:
    // `<span style="width:300px">x</span>` is 8px wide in Chrome and reports
    // the 300px only from getComputedStyle.
    if (dims.inline_box) {
        const edges = CSSStyleDeclaration.boxEdgesSharing(self, frame, &containing, depth);
        dims.padding_x = edges.padding_x;
        dims.padding_y = edges.padding_y;
        dims.border_x = edges.border_x;
        dims.border_y = edges.border_y;
        const ink = self.inlineInk(frame, depth, &containing);
        dims.width = ink.width;
        dims.height = ink.height;
        dims.explicit_width = true;
        dims.explicit_height = true;
        dims.width = layoutUnit(dims.width);
        dims.height = layoutUnit(dims.height);
        return dims;
    }

    if (comptime measure_text_width) {
        const edges = CSSStyleDeclaration.boxEdgesSharing(self, frame, &containing, depth);
        dims.padding_x = edges.padding_x;
        dims.padding_y = edges.padding_y;
        dims.border_x = edges.border_x;
        dims.border_y = edges.border_y;

        if (CSSStyleDeclaration.cascadedComputedLength(self, "width", frame)) |declared| {
            const w = layoutUnit(declared);
            width = if (border_box) @max(0, w - dims.padding_x - dims.border_x) else w;
            dims.explicit_width = true;
        }

        // A flex item's width is the flex container's to give: it is a share of
        // the line in a row -- which outranks the width just read, because
        // `flex: 1` sizes from a `0%` basis and never looks at one -- and a
        // stretch across it in a column. CSSStyleDeclaration.flexItemWidth is
        // where the measurements are.
        if (distribute_flex) {
            if (CSSStyleDeclaration.flexItemWidth(self, frame, depth, dims.explicit_width, edges)) |w| {
                width = w;
                dims.explicit_width = true;
            }
        }
    }

    // Height comes from the cascade too, and unlike width it is NOT gated:
    // `getElementHeight` is the y-only path document.elementFromPoint rejects
    // thousands of elements on, and it needs the height. What makes that
    // affordable is StyleManager's index of the longhand names any rule in the
    // document declares -- a page that never mentions `height` answers the
    // lookup in one hash probe instead of comparing the name against every
    // declaration of every rule keyed to the element.
    if (CSSStyleDeclaration.cascadedComputedLength(self, "height", frame)) |declared| {
        const h = layoutUnit(declared);
        height = if (border_box) @max(0, h - dims.padding_y - dims.border_y) else h;
        dims.explicit_height = true;
    }

    if (width == null or height == null) {
        const tag = self.getTag();

        // A document's root containers fill its viewport, and its viewport is
        // the iframe element's box when it has one. What used to be here were
        // two constants for every document at any depth -- 1920 wide and
        // 100_000_000 tall, so that calculateDocumentPosition's 100px-per-level
        // stacking always had room -- and both went straight out through
        // getComputedStyle. 100000000px is not a number any browser reports, so
        // reading it off a <body> identified this engine on its own.
        //
        // Measured on Chrome 151 (probe frames/iframe_root_box.html): the
        // <html> of a 300x150 iframe reports 300x150 and its <body> 284x134 --
        // the viewport less the body's own 8px UA margins -- while a 0x0 iframe
        // reports 0px throughout. That 0x0 case is the one the Cloudflare
        // widget reads: it dumps a computed style over the <body> of a 0x0
        // about:blank iframe.
        //
        // A body filling the viewport is the *quirks* rendering, and an
        // about:blank document is in quirks mode (`document.compatMode` reads
        // BackCompat, measured). A standards-mode Chrome sizes a body to its
        // content instead -- 0px for an empty one -- which this faux layout has
        // no way to compute for the top-level document. The viewport is the
        // wrong half of a real browser's two answers there, but it is one of
        // them, which the sentinel never was.
        if (tag == .html or tag == .body) {
            const owner = self.ownerFrame(frame);
            const box: Dimensions = if (owner.iframe) |iframe|
                iframe.asElement().dimensionsAt(frame, measure_text_width, depth + 1, true)
            else blk: {
                const viewport = owner._page.getViewport();
                break :blk .{
                    .width = @floatFromInt(viewport.width),
                    .height = @floatFromInt(viewport.height),
                };
            };
            const inset: f64 = if (tag == .body) 2 * body_ua_margin else 0;
            if (width == null) width = @max(0, box.width - inset);
            if (height == null) height = @max(0, box.height - inset);
        } else if (tag == .img or intrinsicBox(tag) != null) {
            if (width == null) {
                if (self.getAttributeSafe(comptime .wrap("width"))) |w| {
                    if (std.fmt.parseFloat(f64, w)) |parsed| {
                        width = parsed;
                        dims.explicit_width = true;
                    } else |_| {}
                }
            }
            if (height == null) {
                if (self.getAttributeSafe(comptime .wrap("height"))) |h| {
                    if (std.fmt.parseFloat(f64, h)) |parsed| {
                        height = parsed;
                        dims.explicit_height = true;
                    } else |_| {}
                }
            }

            // Whatever the attributes left undeclared, a broken <img> fills
            // with the icon rather than the generic placeholder above. Not
            // `explicit`: it is what the element renders as, not a declared
            // value, so clientWidth/clientHeight still take the max with the
            // content extent the way a measured size does.
            if (self.hasBrokenImageBox()) {
                if (width == null) width = broken_image_icon_size;
                if (height == null) height = broken_image_icon_size;
            }

            // Whatever is still open is the box this element has because of what
            // it IS. It matters more than it looks for an <iframe>: the
            // html/body branch above hands a child document this box, so a
            // fallback of 0 would make every undeclared iframe's <body> report
            // 0px once the UA margins came off.
            if (intrinsicBox(tag)) |box| {
                if (width == null) width = box.width;
                if (height == null) height = box.height;
            }
        } else if (measure_text_width and width == null and depth < MAX_CONTAINING_BLOCK_DEPTH) {
            // A block-level box in normal flow is as wide as its containing
            // block, whatever it holds -- and measuring its text instead is how
            // an ordinary `<div>x</div>` in a 1904px body came out 8px wide,
            // and an empty one 5px. Neither is a number a browser reports, and
            // both guards read this: Kasada asks for `width` 19 times on
            // x-hyatt, and the Cloudflare challenge sweeps it with 735 other
            // property names.
            //
            // Which boxes fill and which shrink to fit is
            // CSSStyleDeclaration.fillsContainingBlock's question, measured
            // against Chrome. The width itself is the parent's, recursively,
            // terminating at the <html>/<body> branch above -- so the depth cap
            // is a backstop against a cycle, not a real page's nesting.
            //
            // Behind `measure_text_width` for the same reason the text walk
            // below is: asking costs a cascade, and `getElementHeight` -- the
            // reason that flag exists -- has no use for a width. Without the
            // gate, document.elementFromPoint pays it for every element it
            // rejects on height alone, which is thousands per call.
            if (CSSStyleDeclaration.fillsContainingBlock(self, frame)) {
                if (self.containingBlock(frame)) |parent| {
                    // What fills the containing block is the BORDER box, so the
                    // padding and the border come out of the content: measured,
                    // `padding:10px` on the 1904px line is 1884 of content and
                    // 1904 of offsetWidth, and `padding:20px;border:5px solid`
                    // leaves its own children 1854 to fill.
                    const available = if (comptime measure_text_width)
                        CSSStyleDeclaration.containingWidth(self, frame, &containing, depth) orelse
                            parent.dimensionsAt(frame, measure_text_width, depth + 1, true).width
                    else
                        parent.dimensionsAt(frame, measure_text_width, depth + 1, true).width;
                    // The width a percentage margin takes its share of is this
                    // same one, so it is remembered here rather than measured
                    // again: the two branches above reach it by different
                    // routes, and only one of them fills the cache.
                    if (containing == null) containing = available;
                    width = @max(0, available -
                        horizontalMargin(self, frame, &containing, depth) - dims.padding_x - dims.border_x);
                    // Not a declared value, but the same thing a declared one
                    // means here: the box has a width of its own, so
                    // clientWidth must not take the max with its content and
                    // the text walk below has nothing left to answer.
                    dims.explicit_width = true;
                }
            }
        }
    }

    // An element with no box of its own gets one from its text. Without this
    // every font-enumeration probe — all of which lay out one of these twice
    // and compare — reports that no font is installed, which no real browser
    // does. The text-derived size is not `explicit`: it is a measurement, not
    // a declared value, and clientWidth/clientHeight still take the max with
    // the (zero, for a text-only element) content extent.
    // A declared width already answers the only question the measurement is
    // for, so it also gates the walk over the text -- not just the caller's
    // opt-out above.
    const wants_text_width = measure_text_width and width == null;
    if (wants_text_width or height == null) {
        if (self.textLayout(frame, wants_text_width)) |text| {
            if (wants_text_width) width = text.width;
            if (height == null) height = text.height;
        }
    }

    // The box is a used length, so it lands on the layout grid. Nothing sized
    // it means it has no size: 0, which is what Chrome reports for every empty
    // box whose intrinsic size is not spelled out above.
    dims.width = layoutUnit(width orelse 0);
    dims.height = layoutUnit(height orelse 0);
    return dims;
}

// We can't do this correctly without full styles and more rendering. We also
// can't just ignore the children since some sites append nodes until a certain
// width / height treshold is reached. If the size isn't explicit, we fallback
// to contentWidth/contentHeight
/// clientWidth is a `long` in the IDL, and Chrome rounds the box to reach one:
/// a 1652.911px padding box reads 1653, measured. The `WithCache` form keeps
/// the fraction, because a computed `width` is built off it and Chrome prints
/// `1619.97px` there rather than an integer.
pub fn getClientWidth(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    return @round(self.getClientWidthWithCache(frame, &visibility_cache));
}

pub fn getClientWidthWithCache(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache) f64 {
    if (!self.checkVisibilityCached(visibility_cache, frame)) {
        return 0.0;
    }

    const dims = self.getElementDimensions(frame);

    // clientWidth is the PADDING box: content plus the padding, with the border
    // left out. Measured -- `border:5px solid` on the 1904px line answers 1894
    // here and 1904 for offsetWidth.
    if (dims.inline_box) return 0;

    const tag = self.getTag();
    if (tag == .html or tag == .body or dims.explicit_width) {
        return dims.width + dims.padding_x;
    }

    return @max(dims.width, self.contentWidth(frame, visibility_cache)) + dims.padding_x;
}

pub fn getClientHeight(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    return @round(self.getClientHeightWithCache(frame, &visibility_cache));
}

pub fn getClientHeightWithCache(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache) f64 {
    if (!self.checkVisibilityCached(visibility_cache, frame)) {
        return 0.0;
    }

    const dims = self.getElementDimensions(frame);

    if (dims.inline_box) return 0;

    const tag = self.getTag();
    if (tag == .html or tag == .body or dims.explicit_height) {
        return dims.height + dims.padding_y;
    }

    return @max(dims.height, self.contentHeight(frame, visibility_cache)) + dims.padding_y;
}

pub fn getBoundingClientRect(self: *Element, frame: *Frame) !*DOMRect {
    return DOMRect.create(self.boundingClientRectValues(frame), frame._factory);
}

// Plain rect values, no JS-backed allocation: the internal fast path shared by
// getBoundingClientRect, getClientRects, and IntersectionObserver. A DOMRect is
// only materialized at the JS boundary.
pub fn boundingClientRectValues(self: *Element, frame: *Frame) DOMRect.Data {
    if (!self.checkVisibilityCached(null, frame)) {
        return .{};
    }
    return self.boundingClientRectValuesForVisible(frame);
}

// Some cases need the bounding rect but have already done the visibility check.
pub fn boundingClientRectValuesForVisible(self: *Element, frame: *Frame) DOMRect.Data {
    return self.boundingClientRectValuesAt(frame, 0);
}

fn boundingClientRectValuesAt(self: *Element, frame: *Frame, depth: u8) DOMRect.Data {
    const dims = self.getElementDimensions(frame);

    // getBoundingClientRect is the BORDER box, the same box offsetWidth
    // reports: measured, a `padding:10px;border:5px solid` float is 8px of
    // content, 28 of clientWidth and 38 of both offsetWidth and rect width.
    const width = dims.width + dims.padding_x + dims.border_x;
    var height = dims.height + dims.padding_y + dims.border_y;

    // A <br> is the one element whose rect is not the box offsetHeight reports.
    // It has no box at all -- 0 of clientHeight and 0 of offsetHeight, measured
    // -- but its rect is the LINE it breaks: 0 wide and 18 tall on the default
    // font, which is the only reading that sees it. Chrome 151, measured with
    // tools/fingerprint/scratch/expr-five-sentinel.js, beside an empty <span>
    // whose rect IS 0 by 0 -- so this is a <br> and not inline boxes in general.
    if (self.getTag() == .br) {
        const font = self.resolveFont(frame);
        const box = font_metrics.boundingBox(font.family, font.size);
        height = @round(box.ascent + box.descent);
    }

    // An out-of-flow box is placed by its own declaration, which is the half of
    // positioning this engine can compute exactly.
    if (self.outOfFlowPosition(frame, depth)) |placed| {
        return .{ .x = placed.x, .y = placed.y, .width = width, .height = height };
    }

    const y = calculateDocumentPosition(self.asNode());

    // Use sibling position for x coordinate to ensure siblings have different x values
    const x = calculateSiblingPosition(self.asNode());

    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
}

// A DOMRectList, not a JS Array: `getClientRects().constructor.name` is read
// directly by fingerprinting scripts, and Array is not an answer any browser
// gives. The list and its rects both come from the frame arena because the
// wrapper a script keeps outlives this call.
pub fn getClientRects(self: *Element, frame: *Frame) !*DOMRectList {
    if (!self.checkVisibilityCached(null, frame)) {
        return frame._factory.create(DOMRectList{});
    }
    const rects = try frame.arena.alloc(*DOMRect, 1);
    rects[0] = try DOMRect.create(self.boundingClientRectValuesForVisible(frame), frame._factory);
    return frame._factory.create(DOMRectList{ ._rects = rects });
}

// Scroll positions live in the map of the element's own frame — not the
// caller's, which differs when a same-origin script scrolls an element in
// another frame (e.g. inside an iframe). All scroll accessors resolve the
// owner frame first so the state, the fired events and the document
// comparison stay in the element's frame.
pub fn getScrollTop(self: *Element, frame: *Frame) u32 {
    const owner = self.ownerFrame(frame);
    const pos = owner._element_scroll_positions.get(self) orelse return 0;
    return pos.y;
}

pub fn setScrollTop(self: *Element, value: i32, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const new_y: u32 = @intCast(@max(0, value));
    if (gop.value_ptr.y != new_y) {
        gop.value_ptr.y = new_y;
        try self.scheduleScrollEvents(owner);
    }
}

pub fn getScrollLeft(self: *Element, frame: *Frame) u32 {
    const owner = self.ownerFrame(frame);
    const pos = owner._element_scroll_positions.get(self) orelse return 0;
    return pos.x;
}

pub fn setScrollLeft(self: *Element, value: i32, frame: *Frame) !void {
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const new_x: u32 = @intCast(@max(0, value));
    if (gop.value_ptr.x != new_x) {
        gop.value_ptr.x = new_x;
        try self.scheduleScrollEvents(owner);
    }
}

pub fn getScrollHeight(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    if (!self.checkVisibilityCached(&visibility_cache, frame)) {
        return 0.0;
    }

    const dims = self.getElementDimensions(frame);

    const tag = self.getTag();
    // As in getScrollWidth: the root containers carry artificial giant
    // defaults, and page-level overflow checks read them.
    if (tag == .html or tag == .body) {
        return dims.height;
    }

    if (dims.inline_box) return 0;

    return @round(@max(dims.height, self.contentHeight(frame, &visibility_cache)) + dims.padding_y);
}

// The height of the direct child elements stacked vertically, the counterpart
// of contentWidth.
//
// Note that the two assume contradictory arrangements — contentWidth lays the
// children out in a row, this stacks them. That is deliberate. We can't detect
// the real layout mode (see contentWidth), so each axis independently assumes
// the arrangement that produces overflow. Together they bound the content
// extent per axis rather than describing one coherent layout: reporting no
// overflow when there is some is what wedges measure-then-mutate loops,
// while the reverse merely over-reports.
fn contentHeight(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache) f64 {
    var total: f64 = 0;

    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (el.checkVisibilityCached(visibility_cache, frame)) {
                total += el.getElementDimensions(frame).height;
            }
        }
    }

    return total;
}

pub fn getScrollWidth(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    if (!self.checkVisibilityCached(&visibility_cache, frame)) {
        return 0.0;
    }

    const dims = self.getElementDimensions(frame);

    const tag = self.getTag();
    // The root containers carry artificial giant defaults (1920 and
    // 100_000_000, see getElementDimensions). Stacking their children on
    // top would inflate a value sites read to detect page overflow.
    if (tag == .html or tag == .body) {
        return dims.width;
    }

    if (dims.inline_box) return 0;

    // The scrollable overflow area includes the padding: measured, a
    // `width:100px;padding:10px` box holding a 300px child answers 120 for
    // clientWidth and 320 for scrollWidth. Rounded, like the other two.
    return @round(@max(dims.width, self.contentWidth(frame, &visibility_cache)) + dims.padding_x);
}

// The width of the direct child elements laid end to end on a single row.
//
// The dummy layout engine has no line-breaking, and an element only overflows
// horizontally when its children don't wrap (white-space:nowrap, a flex row, an
// inline-block strip), so the single-row assumption covers the case that
// matters. We can't detect the layout mode to do better: getStyle() sees only
// the inline `style=` attribute, and the computed cascade resolves stylesheet
// rules for `display:none` and `visibility` alone.
//
// Only direct children are measured, never the whole subtree. This runs on
// every scrollWidth read, and recursing would make an element's cost O(subtree)
// rather than O(fan-out).
//
// Growing with the child count is the point: JS that appends content until
// `scrollWidth` passes a threshold (the infinite-marquee idiom) never
// terminates when the metric ignores what it just inserted.
//
// Text children are not measured, matching contentHeight. Estimating a text run
// from its length would need a per-character advance, which in turn has to track
// font-size or "shrink the font until it fits" loops stop converging — and it
// would report overflow for practically every element containing text, since a
// few words already exceed the default box. Element children are what content
// grown by script actually consists of.
fn contentWidth(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache) f64 {
    var total: f64 = 0;

    // The cache arrives seeded by the caller's own visibility walk, and
    // siblings share that ancestor chain, so the loop costs one own-element
    // check per child rather than N ancestor walks.
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (el.checkVisibilityCached(visibility_cache, frame)) {
                total += el.getElementDimensions(frame).width;
            }
        }
    }

    return total;
}

pub fn getOffsetHeight(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    if (!self.checkVisibilityCached(&visibility_cache, frame)) {
        return 0.0;
    }
    const dims = self.getElementDimensions(frame);
    if (dims.inline_box) return @round(dims.height + dims.padding_y + dims.border_y);
    return @round(self.getClientHeightWithCache(frame, &visibility_cache) + dims.border_y);
}

/// offsetWidth is the BORDER box: content, padding and border. It takes the
/// same content fallback clientWidth does, so a box whose children overflow it
/// still reports a width that grows with them.
pub fn getOffsetWidth(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    if (!self.checkVisibilityCached(&visibility_cache, frame)) {
        return 0.0;
    }
    const dims = self.getElementDimensions(frame);
    // An inline box has no clientWidth to build on -- that reading is 0 for one
    // -- so its ink is added up directly.
    if (dims.inline_box) return @round(dims.width + dims.padding_x + dims.border_x);
    return @round(self.getClientWidthWithCache(frame, &visibility_cache) + dims.border_x);
}

pub fn getOffsetTop(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    if (self.outOfFlowPosition(frame, 0)) |placed| {
        return placed.offset_y;
    }
    return calculateDocumentPosition(self.asNode());
}

pub fn getOffsetLeft(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    if (self.outOfFlowPosition(frame, 0)) |placed| {
        return placed.offset_x;
    }
    return calculateSiblingPosition(self.asNode());
}

/// Where the element's box sits when the flow does not decide it, or null when
/// it does.
///
/// `absolute` and `fixed` are the two this engine can place exactly: the box
/// goes at its containing block's origin plus its own `left`/`top`, or at the
/// far edge less `right`/`bottom` and its own width. Measured against Chrome
/// with tools/fingerprint/scratch/expr-absolute-position.js -- `left:37px;
/// top:53px` with no positioned ancestor is 37,53 in the viewport and 37,53
/// from the offset parent both.
///
/// `static` and `relative` are not here. A box in flow sits after its preceding
/// siblings, and that sum needs their heights, which are still content-derived
/// guesses; the synthetic walk stands until there is a flow to replace it.
///
/// `offset_*` is what `offsetLeft`/`offsetTop` report and `x`/`y` is the
/// viewport rect, and the two differ by the containing block's own origin --
/// which may itself still be synthetic. That keeps the pair *consistent* even
/// where neither is Chrome's number: a script comparing `getBoundingClientRect`
/// against `offsetLeft` is comparing the relation between them.
///
/// A declaration this engine cannot resolve, and the `auto` case Chrome places
/// at the static position, both come out 0 -- there is no static position to
/// fall back to.
fn outOfFlowPosition(self: *Element, frame: *Frame, depth: u8) ?struct {
    x: f64,
    y: f64,
    offset_x: f64,
    offset_y: f64,
} {
    if (depth >= MAX_CONTAINING_BLOCK_DEPTH) return null;

    const position = CSSStyleDeclaration.cascadedComputedValue(self, "position", frame) orelse return null;
    const is_fixed = std.ascii.eqlIgnoreCase(position, "fixed");
    if (!is_fixed and !std.ascii.eqlIgnoreCase(position, "absolute")) return null;

    const dims = self.getElementDimensions(frame);

    // A fixed box is placed against the viewport; an absolute one against the
    // nearest positioned ancestor, or the initial containing block when it has
    // none. Both of those origins are 0, 0.
    const containing: ?*Element = if (is_fixed) null else self.nearestPositionedAncestor(frame);

    const box: Dimensions = if (containing) |cb|
        cb.getElementDimensions(frame)
    else blk: {
        const viewport = self.ownerFrame(frame)._page.getViewport();
        break :blk .{
            .width = @floatFromInt(viewport.width),
            .height = @floatFromInt(viewport.height),
        };
    };

    const offset_x = self.edgeOffset(frame, "left", "right", box.width, dims.width);
    const offset_y = self.edgeOffset(frame, "top", "bottom", box.height, dims.height);

    const origin: DOMRect.Data = if (containing) |cb|
        cb.boundingClientRectValuesAt(frame, depth + 1)
    else
        .{};

    return .{
        .x = origin.x + offset_x,
        .y = origin.y + offset_y,
        .offset_x = offset_x,
        .offset_y = offset_y,
    };
}

/// One axis of an out-of-flow box's offset: the near edge if it is declared,
/// otherwise the far edge subtracted from the containing block, otherwise zero.
fn edgeOffset(
    self: *Element,
    frame: *Frame,
    comptime near: []const u8,
    comptime far: []const u8,
    available: f64,
    own: f64,
) f64 {
    if (CSSStyleDeclaration.cascadedComputedValue(self, near, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return px;
    }
    if (CSSStyleDeclaration.cascadedComputedValue(self, far, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return available - px - own;
    }
    return 0;
}

/// The ancestor an absolutely positioned box is placed against: the nearest one
/// the page positioned, or null for the initial containing block.
fn nearestPositionedAncestor(self: *Element, frame: *Frame) ?*Element {
    var current = self.parentElement();
    while (current) |element| : (current = element.parentElement()) {
        const position = CSSStyleDeclaration.cascadedComputedValue(element, "position", frame) orelse continue;
        if (!std.ascii.eqlIgnoreCase(position, "static")) return element;
    }
    return null;
}

pub fn getOffsetParent(self: *Element, frame: *Frame) ?*Element {
    if (!self.asNode().isConnected() or !self.checkVisibilityCached(null, frame)) {
        return null;
    }

    switch (self.getTag()) {
        .html, .body => return null,
        else => {},
    }

    const self_position = self.positionStyle(frame);
    if (std.mem.eql(u8, self_position, "fixed")) {
        return null;
    }
    const self_static = self_position.len == 0 or std.mem.eql(u8, self_position, "static");

    var node: ?*Node = self.asNode()._parent;
    while (node) |n| {
        if (n.is(ShadowRoot)) |sr| {
            // this always pokes through the shadow dom
            node = sr.getHost().asNode();
            continue;
        }
        const ancestor = n.is(Element) orelse break;

        const tag = ancestor.getTag();
        if (tag == .body) {
            return ancestor;
        }
        const position = ancestor.positionStyle(frame);
        if (position.len > 0 and !std.mem.eql(u8, position, "static")) {
            return ancestor;
        }
        if (self_static and (tag == .td or tag == .th or tag == .table)) {
            return ancestor;
        }
        node = n._parent;
    }
    return null;
}

fn positionStyle(self: *Element, frame: *Frame) []const u8 {
    const style = self.getStyle(frame) orelse return "";
    return style.getPropertyValue("position", frame);
}

pub fn getClientTop(_: *Element) f64 {
    // Border width - in our dummy layout, we don't apply borders to layout
    return 0.0;
}

pub fn getClientLeft(_: *Element) f64 {
    // Border width - in our dummy layout, we don't apply borders to layout
    return 0.0;
}

// Calculates document position by counting all nodes that appear before this one
// in tree order, but only traversing the "left side" of the tree.
//
// This walks up from the target node to the root, and at each level counts:
// 1. All previous siblings and their descendants
// 2. The parent itself
//
// Example:
//   <body>              → y=0
//     <h1>Text</h1>     → y=1    (body=1)
//     <h2>              → y=2    (body=1 + h1=1)
//       <a>Link1</a>    → y=3    (body=1 + h1=1 + h2=1)
//     </h2>
//     <p>Text</p>       → y=5    (body=1 + h1=1 + h2=2)
//     <h2>              → y=6    (body=1 + h1=1 + h2=2 + p=1)
//       <a>Link2</a>    → y=7    (body=1 + h1=1 + h2=2 + p=1 + h2=1)
//     </h2>
//   </body>
//
// Trade-offs:
// - O(depth × siblings × subtree_height) - only left-side traversal
// - Linear scaling: 5px per node
// - Perfect document order, guaranteed unique positions
// - Compact coordinates (1000 nodes ≈ 5,000px)
fn calculateDocumentPosition(node: *Node) f64 {
    var position: f64 = 0.0;
    var current = node;

    // Walk up to root, counting preceding nodes
    while (current.parentNode()) |parent| {
        // Count all previous siblings and their descendants
        var sibling = parent.firstChild();
        while (sibling) |s| {
            if (s == current) break;
            position += countSubtreeNodes(s);
            sibling = s.nextSibling();
        }

        // Count the parent itself
        position += 1.0;
        current = parent;
    }

    return position * 5.0; // 5px per node
}

// Counts total nodes in a subtree (node + all descendants)
fn countSubtreeNodes(node: *Node) f64 {
    var count: f64 = 1.0; // Count this node

    var child = node.firstChild();
    while (child) |c| {
        count += countSubtreeNodes(c);
        child = c.nextSibling();
    }

    return count;
}

// Calculates horizontal position using the same approach as y,
// just scaled differently for visual distinction
fn calculateSiblingPosition(node: *Node) f64 {
    var position: f64 = 0.0;
    var current = node;

    // Walk up to root, counting preceding nodes (same as y)
    while (current.parentNode()) |parent| {
        // Count all previous siblings and their descendants
        var sibling = parent.firstChild();
        while (sibling) |s| {
            if (s == current) break;
            position += countSubtreeNodes(s);
            sibling = s.nextSibling();
        }

        // Count the parent itself
        position += 1.0;
        current = parent;
    }

    return position * 5.0; // 5px per node
}

pub fn getElementsByTagName(self: *Element, tag_name: []const u8, frame: *Frame) !Node.GetElementsByTagNameResult {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Element, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Element, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn clone(self: *Element, deep: bool, frame: *Frame) !*Node {
    const tag_name = self.getTagNameDump();
    const node = try Frame.node_factory.createElementNS(frame, self._namespace, tag_name, &self._attributes);

    // A namespace outside the built-in set lives in a side table; the clone
    // must report the same namespaceURI.
    if (self._namespace == .unknown) {
        if (frame._element_namespace_uris.get(self)) |uri| {
            try frame._element_namespace_uris.put(frame.arena, node.as(Element), uri);
        }
    }

    // Allow element-specific types to copy their runtime state
    _ = Element.Build.call(node.as(Element), "cloned", .{ self, node.as(Element), deep, frame }) catch |err| {
        log.err(.dom, "element.clone.failed", .{ .err = err });
    };

    // Per spec, a clonable shadow root is cloned along with its host — its
    // children always deep-cloned, even when the host clone is shallow.
    if (self.hostedShadowRoot(frame)) |shadow| {
        if (shadow._clonable) {
            const cloned_shadow = node.as(Element).attachShadow(.{
                .mode = shadow._mode,
                .clonable = true,
                .delegates_focus = shadow._delegates_focus,
                .slot_assignment = shadow._slot_assignment,
                .serializable = shadow._serializable,
                .declarative = shadow._declarative,
            }, frame) catch return error.CloneError;

            const cloned_shadow_node = cloned_shadow.asNode();
            var shadow_child_it = shadow.asNode().childrenIterator();
            while (shadow_child_it.next()) |child| {
                if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                    try frame.appendNode(cloned_shadow_node, cloned_child, .{});
                }
            }
        }
    }

    if (deep) {
        var child_it = self.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                try frame.appendNode(node, cloned_child, .{});
            }
        }
    }

    return node;
}

pub fn scrollIntoViewIfNeeded(self: *Element, center_if_needed: ?bool, frame: *Frame) void {
    _ = center_if_needed;
    const y = calculateDocumentPosition(self.asNode());
    const scroll_y: f64 = @floatFromInt(frame.window.getScrollY());
    const viewport_height: f64 = @floatFromInt(frame.window.getInnerHeight(frame));
    if (y >= scroll_y and y <= scroll_y + viewport_height) {
        return;
    }
    self.scrollIntoView(null, frame);
}

const ScrollIntoViewOpts = union {
    align_to_top: bool,
    obj: js.Object,
};
pub fn scrollIntoView(self: *Element, opts: ?ScrollIntoViewOpts, frame: *Frame) void {
    _ = opts;
    // Scroll the window so the element's top is brought into the viewport.
    // Positions come from the faux-layout document position (top = preorder
    // depth-scaled y), the same source getBoundingClientRect uses.
    const y = calculateDocumentPosition(self.asNode());
    frame.window.scrollTo(.{ .x = 0 }, @intFromFloat(@max(0, y)), frame) catch {};
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        top: ?i32 = null,
        left: ?i32 = null,
        behavior: []const u8 = "",
    };
};

pub fn scrollTo(self: *Element, opts: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts orelse return;
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const old_x = gop.value_ptr.x;
    const old_y = gop.value_ptr.y;
    switch (o) {
        .x => |x| {
            gop.value_ptr.x = @intCast(@max(0, x));
            gop.value_ptr.y = @intCast(@max(0, y orelse 0));
        },
        .opts => |dict| {
            if (dict.left) |left| gop.value_ptr.x = @intCast(@max(0, left));
            if (dict.top) |top| gop.value_ptr.y = @intCast(@max(0, top));
        },
    }
    if (gop.value_ptr.x != old_x or gop.value_ptr.y != old_y) {
        try self.scheduleScrollEvents(owner);
    }
}

// scrollBy(): like scrollTo() but relative to the current position.
pub fn scrollBy(self: *Element, opts: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts orelse return;
    const owner = self.ownerFrame(frame);
    const gop = try owner._element_scroll_positions.getOrPut(owner.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const dx: i32, const dy: i32 = switch (o) {
        .x => |x| .{ x, y orelse 0 },
        .opts => |dict| .{ dict.left orelse 0, dict.top orelse 0 },
    };
    const old_x = gop.value_ptr.x;
    const old_y = gop.value_ptr.y;
    gop.value_ptr.x = @intCast(@max(0, @as(i32, @intCast(gop.value_ptr.x)) + dx));
    gop.value_ptr.y = @intCast(@max(0, @as(i32, @intCast(gop.value_ptr.y)) + dy));
    if (gop.value_ptr.x != old_x or gop.value_ptr.y != old_y) {
        try self.scheduleScrollEvents(owner);
    }
}

// Scrolling an element fires a scroll event and then a scrollend event,
// asynchronously and throttled, mirroring Window.scrollTo. Scrolls of the
// scrolling element (the root) are fired at the document instead.
// `frame` is the element's owner frame (resolved by the public accessors).
fn scheduleScrollEvents(self: *Element, frame: *Frame) !void {
    const gop = try frame._element_scroll_positions.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const task_pending = gop.value_ptr.state != .done;
    gop.value_ptr.state = .scroll;
    if (task_pending) {
        return;
    }

    const task = try frame._factory.create(ScrollEventTask{ .frame = frame, .element = self });
    errdefer {
        gop.value_ptr.state = .done;
        frame._factory.destroy(task);
    }
    try frame.js.scheduler.add(task, ScrollEventTask.run, 10, .{
        .name = "element.scrollEvents",
        .blocks_done = false,
        .finalizer = ScrollEventTask.cancelled,
    });
}

const ScrollEventTask = struct {
    frame: *Frame,
    element: *Element,

    fn eventTarget(self: *ScrollEventTask) *@import("EventTarget.zig") {
        if (self.frame.document.getDocumentElement() == self.element) {
            return self.frame.document.asEventTarget();
        }
        return self.element.asEventTarget();
    }

    // Scroll events fired at an element don't bubble; only document-level
    // scrolls (the scrolling element, dispatched at the document) do.
    fn bubbles(self: *ScrollEventTask) bool {
        return self.frame.document.getDocumentElement() == self.element;
    }

    fn cancelled(ptr: *anyopaque) void {
        const self: *ScrollEventTask = @ptrCast(@alignCast(ptr));
        if (self.frame._element_scroll_positions.getPtr(self.element)) |pos| {
            pos.state = .done;
        }
        self.frame._factory.destroy(self);
    }

    fn run(ptr: *anyopaque) anyerror!?u32 {
        const self: *ScrollEventTask = @ptrCast(@alignCast(ptr));
        const f = self.frame;
        const pos = f._element_scroll_positions.getPtr(self.element) orelse {
            f._factory.destroy(self);
            return null;
        };
        switch (pos.state) {
            .scroll => {
                pos.state = .end;
                self.dispatchEvent(comptime .wrap("scroll"));
                return 10;
            },
            .end => {
                pos.state = .done;
                defer f._factory.destroy(self);
                self.dispatchEvent(comptime .wrap("scrollend"));
                return null;
            },
            .done => {
                f._factory.destroy(self);
                return null;
            },
        }
    }

    fn dispatchEvent(self: *ScrollEventTask, comptime event_type: String) void {
        const Event = @import("Event.zig");
        const event = Event.initTrusted(event_type, .{ .bubbles = self.bubbles() }, self.frame._page) catch |err| {
            log.warn(.dom, "element.scroll.event", .{ .err = err });
            return;
        };
        self.frame._event_manager.dispatch(self.eventTarget(), event) catch |err| {
            log.warn(.dom, "element.scroll.dispatch", .{ .err = err });
        };
    }
};

pub fn format(self: *Element, writer: *std.Io.Writer) !void {
    try writer.writeByte('<');
    try writer.writeAll(self.getTagNameDump());

    for (self._attributes.entries()) |*attr| {
        try writer.print(" {f}", .{attr});
    }
    try writer.writeByte('>');
}

fn upperTagName(tag_name: *String, buf: []u8) []const u8 {
    if (tag_name.len > buf.len) {
        log.info(.dom, "tag.long.name", .{ .name = tag_name.str() });
        return tag_name.str();
    }
    const tag = tag_name.str();
    return std.ascii.upperString(buf, tag);
}

pub fn getTag(self: *const Element) Tag {
    return switch (self._type) {
        .html => blk: {
            const he = self.subtype(Html);
            break :blk switch (he._type) {
                .anchor => .anchor,
                .area => .area,
                .base => .base,
                .div => .div,
                .dl => .dl,
                .embed => .embed,
                .form => .form,
                .p => .p,
                .custom => .custom,
                .data => .data,
                .datalist => .datalist,
                .details => .details,
                .dialog => .dialog,
                .directory => .directory,
                .menu => .menu,
                .frame_element => .frame,
                .iframe => .iframe,
                .img => .img,
                .br => .br,
                .button => .button,
                .canvas => .canvas,
                .fieldset => .fieldset,
                .font => .font,
                .frameset => .frameset,
                .heading => he.subtype(Html.Heading)._tag,
                .label => .label,
                .legend => .legend,
                .li => .li,
                .map => .map,
                .marquee => .marquee,
                .ul => .ul,
                .ol => .ol,
                .object => .object,
                .optgroup => .optgroup,
                .output => .output,
                .picture => .picture,
                .param => .param,
                .pre => .pre,
                .generic => he.subtype(Html.Generic)._tag,
                .media => switch (he.subtype(Html.Media)._type) {
                    .audio => .audio,
                    .video => .video,
                    .generic => .media,
                },
                .meter => .meter,
                .mod => he.subtype(Html.Mod)._tag,
                .progress => .progress,
                .quote => he.subtype(Html.Quote)._tag,
                .script => .script,
                .select => .select,
                .slot => .slot,
                // No Element.Tag entry for the three surface elements, the
                // way no MathML tag has one: tag-name matching falls back to
                // the tagName string, which is all a selector needs.
                .selected_content, .geolocation, .user_media => .unknown,
                .source => .source,
                .span => .span,
                .option => .option,
                .table => .table,
                .table_caption => .caption,
                .table_cell => he.subtype(Html.TableCell)._tag,
                .table_col => he.subtype(Html.TableCol)._tag,
                .table_row => .tr,
                .table_section => he.subtype(Html.TableSection)._tag,
                .template => .template,
                .textarea => .textarea,
                .time => .time,
                .track => .track,
                .input => .input,
                .link => .link,
                .meta => .meta,
                .hr => .hr,
                .style => .style,
                .title => .title,
                .body => .body,
                .html => .html,
                .head => .head,
                .unknown => .unknown,
            };
        },
        .svg => self.subtype(Svg).getTag(),
        // No MathML tag is in Element.Tag; tag-name matching falls back to
        // _tag_name, the way it does for generic SVG elements. Same for a
        // plain element, whose name is arbitrary by definition.
        .mathml, .plain => .unknown,
    };
}

pub fn ownerFrame(self: *const Element, default: *Frame) *Frame {
    return self.asConstNode().ownerFrame(default);
}

pub const Tag = enum {
    address,
    anchor,
    audio,
    area,
    aside,
    article,
    b,
    blockquote,
    body,
    br,
    button,
    base,
    canvas,
    caption,
    circle,
    code,
    col,
    colgroup,
    custom,
    data,
    datalist,
    dd,
    details,
    del,
    dfn,
    dialog,
    div,
    directory,
    dl,
    dt,
    embed,
    ellipse,
    em,
    fieldset,
    figure,
    frameset,
    frame,
    form,
    font,
    footer,
    g,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    heading,
    hgroup,
    hr,
    html,
    i,
    iframe,
    img,
    input,
    ins,
    label,
    legend,
    li,
    line,
    link,
    main,
    map,
    marquee,
    media,
    menu,
    meta,
    meter,
    nav,
    noscript,
    object,
    ol,
    optgroup,
    option,
    output,
    p,
    path,
    param,
    picture,
    polygon,
    polyline,
    pre,
    progress,
    quote,
    rect,
    s,
    script,
    section,
    select,
    slot,
    source,
    span,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    time,
    tbody,
    td,
    text,
    template,
    textarea,
    tfoot,
    th,
    thead,
    title,
    tr,
    track,
    ul,
    video,
    unknown,

    // If the tag is "unknown", we can't use the optimized tag matching, but
    // need to fallback to the actual tag name
    pub fn parseForMatch(lower: []const u8) ?Tag {
        const tag = std.meta.stringToEnum(Tag, lower) orelse return null;
        return switch (tag) {
            .unknown, .custom => null,
            else => tag,
        };
    }

    pub fn isBlock(self: Tag) bool {
        // zig fmt: off
        return switch (self) {
            // Semantic Layout
            .article, .aside, .footer, .header, .main, .nav, .section,
            // Grouping / Containers
            .address, .div, .fieldset, .figure, .p,
            // Headings
            .h1, .h2, .h3, .h4, .h5, .h6,
            // Lists
            .dl, .ol, .ul,
            // Preformatted / Quotes
            .blockquote, .pre,
            // Tables
            .table,
            // Other
            .hr,
            => true,
            else => false,
        };
        // zig fmt: on
    }

    pub fn isMetadata(self: Tag) bool {
        return switch (self) {
            .base, .head, .link, .meta, .noscript, .script, .style, .template, .title => true,
            else => false,
        };
    }

    // UA stylesheet display:none defaults per HTML Rendering §15.3.1
    // "Hidden elements" (https://html.spec.whatwg.org/multipage/rendering.html#hidden-elements).
    // The spec also lists basefont, noembed, noframes, rp; those tags are
    // obsolete and not represented in this enum, so they fall through to
    // `.unknown`/`.custom` and aren't matched here.
    pub fn isHiddenByUaStylesheet(self: Tag) bool {
        // Three tags came off HTML Rendering 15.3.1's list because Chrome does
        // not hide them: measured loose with tools/fingerprint/scratch/
        // expr-area-loose.js, `area`, `source` and `track` each compute
        // `display: inline` and answer `checkVisibility()` true. Both of
        // Chrome's answers agree for all three, so they leave together rather
        // than being special-cased for one of them.
        //
        // `noscript` stays, even though Chrome computes `inline` for it too:
        // there the two answers disagree -- `checkVisibility()` is false and
        // its content never reaches innerText (expr-noscript-area-render.js) --
        // and this switch is what makes ours agree with each other. Splitting
        // them is a change to that contract, not to this list.
        //
        // A <source> or <track> inside a <video> is the one case neither
        // answer covers: there Chrome returns the empty string for `display`,
        // declining to give the element a style at all. `inline` is what it
        // says everywhere else, including inside a <picture>.
        return switch (self) {
            .base,
            .datalist,
            .head,
            .link,
            .meta,
            .noscript,
            .param,
            .script,
            .style,
            .template,
            .title,
            => true,
            else => false,
        };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Element);

    // Getter/setter pair for an event handler property, backed by the frame's
    // attribute-listener store.
    fn handlerAccessor(comptime handler: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *Element, frame: *Frame) !?js.Function.Global {
                return self.getAttributeFunction(handler, frame);
            }

            pub fn set(self: *Element, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.setAttributeListener(handler, callback, frame);
            }
        };
    }

    pub const Meta = struct {
        pub const name = "Element";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn _tagName(self: *Element, frame: *Frame) []const u8 {
        return self.getTagNameSpec(frame, &frame.buf);
    }
    // the frame-aware variant returns the original URI for namespaces
    // outside the built-in set instead of the placeholder

    fn _getOuterHTML(self: *Element, frame: *Frame) ![]const u8 {
        // local_arena: serialization is read-only and the returned string is
        // converted to v8 before this call returns. No JS runs in between.
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getOuterHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setOuterHTML(self: *Element, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] DOMString`: a JS null becomes "", not "null".
        return self.setOuterHTML(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }

    fn _getInnerHTML(self: *Element, frame: *Frame) ![]const u8 {
        // local_arena: read-only serialization, result converted to v8 before
        // returning; no JS runs in between.
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setInnerHTML(self: *Element, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] DOMString`: a JS null becomes "", not "null".
        return self.setInnerHTML(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }

    fn _part(self: *Element, frame: *Frame) !*collections.DOMTokenList {
        return self.getTokenList(.part, frame);
    }
    fn _setPart(self: *Element, value: []const u8, frame: *Frame) !void {
        return self.setAttributeSafe(comptime .wrap("part"), .wrap(value), frame);
    }
    fn _computedStyleMap(self: *Element, frame: *Frame) !*typed_om.StylePropertyMapReadOnly {
        return typed_om.StylePropertyMapReadOnly.init(try frame.window.getComputedStyle(self, null, frame), frame);
    }
    // The namespace is ignored, as it already is for getAttributeNS,
    // hasAttributeNS and setAttributeNS: attributes are stored by local name.
    fn _getAttributeNodeNS(self: *Element, _: ?[]const u8, local_name: String, frame: *Frame) !?*Attribute {
        return self.getAttributeNode(local_name, frame);
    }
    // Attributes are keyed by qualified name here, so a namespaced one has to
    // be reached through the same fixed-prefix mapping getAttributeNS uses --
    // dropping the namespace and removing the bare local name leaves an
    // `xlink:href` in place, which is observable through SVG's targetElement.
    fn _removeAttributeNS(self: *Element, namespace_: ?[]const u8, local_name: String, frame: *Frame) !void {
        if (namespace_) |namespace| {
            if (try Element.prefixedAttributeName(namespace, local_name.str(), frame)) |prefixed| {
                if (self.hasAttributeSafe(.wrap(prefixed))) {
                    return self.removeAttribute(.wrap(prefixed), frame);
                }
            }
        }
        return self.removeAttribute(local_name, frame);
    }
    // getHTML's options dictionary actually selects which shadow roots are
    // serialized (upstream's mechanism); the member itself is declared below,
    // in Chrome's own-property order.
    const GetHTMLOpts = struct {
        serializableShadowRoots: bool = false,
        shadowRoots: []const *ShadowRoot = &.{},
    };
    fn _getHTML(self: *Element, opts_: ?GetHTMLOpts, frame: *Frame) ![]const u8 {
        const opts = opts_ orelse GetHTMLOpts{};
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getHTML(.{
            .shadow_roots = opts.shadowRoots,
            .serializable_shadow_roots = opts.serializableShadowRoots,
        }, &buf.writer, frame);
        return buf.written();
    }

    fn _setAttribute(self: *Element, name: String, value: js.Value, frame: *Frame) !void {
        return self.setAttribute(name, .wrap(try value.toStringSlice()), frame);
    }

    fn _setAttributeNS(self: *Element, maybe_ns: ?[]const u8, qn: []const u8, value: js.Value, frame: *Frame) !void {
        return self.setAttributeNS(maybe_ns, qn, .wrap(try value.toStringSlice()), frame);
    }

    const ShadowRootInit = struct {
        mode: String,
        delegatesFocus: bool = false,
        slotAssignment: ?String = null,
        clonable: bool = false,
        serializable: bool = false,
    };
    fn _attachShadow(self: *Element, init: ShadowRootInit, frame: *Frame) !*ShadowRoot {
        const mode: ShadowRoot.Mode = blk: {
            if (init.mode.eql(comptime .wrap("open"))) break :blk .open;
            if (init.mode.eql(comptime .wrap("closed"))) break :blk .closed;
            // Blink nests the wording for a dictionary member: the operation's
            // prefix, then which member of which dictionary was read, then the
            // value and the enum type -- the one name in the sentence that
            // comes without quotes (measured on Chrome 151).
            return frame.js.fail(error.TypeError, try std.fmt.allocPrint(
                frame.call_arena,
                "Failed to execute 'attachShadow' on 'Element': Failed to read the 'mode' property " ++
                    "from 'ShadowRootInit': The provided value '{s}' is not a valid enum value of " ++
                    "type ShadowRootMode.",
                .{init.mode.str()},
            ));
        };
        const slot_assignment: ShadowRoot.SlotAssignment = blk: {
            const sa = init.slotAssignment orelse break :blk .named;
            if (sa.eql(comptime .wrap("named"))) break :blk .named;
            if (sa.eql(comptime .wrap("manual"))) break :blk .manual;
            return error.InvalidArgument;
        };
        return self.attachShadow(.{
            .mode = mode,
            .delegates_focus = init.delegatesFocus,
            .slot_assignment = slot_assignment,
            .clonable = init.clonable,
            .serializable = init.serializable,
        }, frame);
    }

    // Declaration order is the prototype's own-property order, and that order
    // is itself part of what a detector hashes. This is a headed Chrome 150's
    // Object.getOwnPropertyNames(Element.prototype), name for name.
    pub const namespaceURI = bridge.accessor(Element.getNamespaceUri, null, .{});
    pub const prefix = bridge.accessor(Element._prefix, null, .{});
    pub const localName = bridge.accessor(Element.getLocalName, null, .{});
    pub const tagName = bridge.accessor(_tagName, null, .{});
    pub const id = bridge.accessor(Element.getId, Element.setId, .{ .ce_reactions = true });
    pub const className = bridge.accessor(Element.getClassName, Element.setClassName, .{ .ce_reactions = true });
    pub const classList = bridge.accessor(Element.getClassList, Element.setClassList, .{ .ce_reactions = true });
    pub const slot = bridge.accessor(Element.getSlot, Element.setSlot, .{ .ce_reactions = true });
    pub const attributes = bridge.accessor(Element.getAttributeNamedNodeMap, null, .{});
    pub const shadowRoot = bridge.accessor(Element.getShadowRoot, null, .{});
    pub const part = bridge.accessor(_part, _setPart, .{ .ce_reactions = true });
    pub const assignedSlot = bridge.accessor(Element.getAssignedSlot, null, .{});
    pub const innerHTML = bridge.accessor(_getInnerHTML, _setInnerHTML, .{ .ce_reactions = true });
    pub const outerHTML = bridge.accessor(_getOuterHTML, _setOuterHTML, .{ .ce_reactions = true });
    pub const scrollTop = bridge.accessor(Element.getScrollTop, Element.setScrollTop, .{});
    pub const scrollLeft = bridge.accessor(Element.getScrollLeft, Element.setScrollLeft, .{});
    pub const scrollWidth = bridge.accessor(Element.getScrollWidth, null, .{});
    pub const scrollHeight = bridge.accessor(Element.getScrollHeight, null, .{});
    pub const clientTop = bridge.accessor(Element.getClientTop, null, .{});
    pub const clientLeft = bridge.accessor(Element.getClientLeft, null, .{});
    pub const clientWidth = bridge.accessor(Element.getClientWidth, null, .{});
    pub const clientHeight = bridge.accessor(Element.getClientHeight, null, .{});
    pub const onbeforecopy = bridge.accessor(handlerAccessor(.onbeforecopy).get, handlerAccessor(.onbeforecopy).set, .{});
    pub const onbeforecut = bridge.accessor(handlerAccessor(.onbeforecut).get, handlerAccessor(.onbeforecut).set, .{});
    pub const onbeforepaste = bridge.accessor(handlerAccessor(.onbeforepaste).get, handlerAccessor(.onbeforepaste).set, .{});
    pub const onsearch = bridge.accessor(handlerAccessor(.onsearch).get, handlerAccessor(.onsearch).set, .{});
    pub const elementTiming = bridge.accessor(Element.getElementTiming, Element.setElementTiming, .{ .ce_reactions = true });
    pub const onfullscreenchange = bridge.accessor(handlerAccessor(.onfullscreenchange).get, handlerAccessor(.onfullscreenchange).set, .{});
    pub const onfullscreenerror = bridge.accessor(handlerAccessor(.onfullscreenerror).get, handlerAccessor(.onfullscreenerror).set, .{});
    pub const onwebkitfullscreenchange = bridge.accessor(handlerAccessor(.onwebkitfullscreenchange).get, handlerAccessor(.onwebkitfullscreenchange).set, .{});
    pub const onwebkitfullscreenerror = bridge.accessor(handlerAccessor(.onwebkitfullscreenerror).get, handlerAccessor(.onwebkitfullscreenerror).set, .{});
    pub const activeViewTransition = bridge.accessor(Element.getActiveViewTransition, null, .{});
    pub const role = bridge.accessor(reflectedAttribute("role").get, reflectedAttribute("role").set, .{ .ce_reactions = true });
    pub const ariaAtomic = bridge.accessor(reflectedAttribute("aria-atomic").get, reflectedAttribute("aria-atomic").set, .{ .ce_reactions = true });
    pub const ariaAutoComplete = bridge.accessor(reflectedAttribute("aria-autocomplete").get, reflectedAttribute("aria-autocomplete").set, .{ .ce_reactions = true });
    pub const ariaBusy = bridge.accessor(reflectedAttribute("aria-busy").get, reflectedAttribute("aria-busy").set, .{ .ce_reactions = true });
    pub const ariaBrailleLabel = bridge.accessor(reflectedAttribute("aria-braillelabel").get, reflectedAttribute("aria-braillelabel").set, .{ .ce_reactions = true });
    pub const ariaBrailleRoleDescription = bridge.accessor(reflectedAttribute("aria-brailleroledescription").get, reflectedAttribute("aria-brailleroledescription").set, .{ .ce_reactions = true });
    pub const ariaChecked = bridge.accessor(reflectedAttribute("aria-checked").get, reflectedAttribute("aria-checked").set, .{ .ce_reactions = true });
    pub const ariaColCount = bridge.accessor(reflectedAttribute("aria-colcount").get, reflectedAttribute("aria-colcount").set, .{ .ce_reactions = true });
    pub const ariaColIndex = bridge.accessor(reflectedAttribute("aria-colindex").get, reflectedAttribute("aria-colindex").set, .{ .ce_reactions = true });
    pub const ariaColSpan = bridge.accessor(reflectedAttribute("aria-colspan").get, reflectedAttribute("aria-colspan").set, .{ .ce_reactions = true });
    pub const ariaCurrent = bridge.accessor(reflectedAttribute("aria-current").get, reflectedAttribute("aria-current").set, .{ .ce_reactions = true });
    pub const ariaDescription = bridge.accessor(reflectedAttribute("aria-description").get, reflectedAttribute("aria-description").set, .{ .ce_reactions = true });
    pub const ariaDisabled = bridge.accessor(reflectedAttribute("aria-disabled").get, reflectedAttribute("aria-disabled").set, .{ .ce_reactions = true });
    pub const ariaExpanded = bridge.accessor(reflectedAttribute("aria-expanded").get, reflectedAttribute("aria-expanded").set, .{ .ce_reactions = true });
    pub const ariaHasPopup = bridge.accessor(reflectedAttribute("aria-haspopup").get, reflectedAttribute("aria-haspopup").set, .{ .ce_reactions = true });
    pub const ariaHidden = bridge.accessor(reflectedAttribute("aria-hidden").get, reflectedAttribute("aria-hidden").set, .{ .ce_reactions = true });
    pub const ariaInvalid = bridge.accessor(reflectedAttribute("aria-invalid").get, reflectedAttribute("aria-invalid").set, .{ .ce_reactions = true });
    pub const ariaKeyShortcuts = bridge.accessor(reflectedAttribute("aria-keyshortcuts").get, reflectedAttribute("aria-keyshortcuts").set, .{ .ce_reactions = true });
    pub const ariaLabel = bridge.accessor(reflectedAttribute("aria-label").get, reflectedAttribute("aria-label").set, .{ .ce_reactions = true });
    pub const ariaLevel = bridge.accessor(reflectedAttribute("aria-level").get, reflectedAttribute("aria-level").set, .{ .ce_reactions = true });
    pub const ariaLive = bridge.accessor(reflectedAttribute("aria-live").get, reflectedAttribute("aria-live").set, .{ .ce_reactions = true });
    pub const ariaModal = bridge.accessor(reflectedAttribute("aria-modal").get, reflectedAttribute("aria-modal").set, .{ .ce_reactions = true });
    pub const ariaMultiLine = bridge.accessor(reflectedAttribute("aria-multiline").get, reflectedAttribute("aria-multiline").set, .{ .ce_reactions = true });
    pub const ariaMultiSelectable = bridge.accessor(reflectedAttribute("aria-multiselectable").get, reflectedAttribute("aria-multiselectable").set, .{ .ce_reactions = true });
    pub const ariaOrientation = bridge.accessor(reflectedAttribute("aria-orientation").get, reflectedAttribute("aria-orientation").set, .{ .ce_reactions = true });
    pub const ariaPlaceholder = bridge.accessor(reflectedAttribute("aria-placeholder").get, reflectedAttribute("aria-placeholder").set, .{ .ce_reactions = true });
    pub const ariaPosInSet = bridge.accessor(reflectedAttribute("aria-posinset").get, reflectedAttribute("aria-posinset").set, .{ .ce_reactions = true });
    pub const ariaPressed = bridge.accessor(reflectedAttribute("aria-pressed").get, reflectedAttribute("aria-pressed").set, .{ .ce_reactions = true });
    pub const ariaReadOnly = bridge.accessor(reflectedAttribute("aria-readonly").get, reflectedAttribute("aria-readonly").set, .{ .ce_reactions = true });
    pub const ariaRelevant = bridge.accessor(reflectedAttribute("aria-relevant").get, reflectedAttribute("aria-relevant").set, .{ .ce_reactions = true });
    pub const ariaRequired = bridge.accessor(reflectedAttribute("aria-required").get, reflectedAttribute("aria-required").set, .{ .ce_reactions = true });
    pub const ariaRoleDescription = bridge.accessor(reflectedAttribute("aria-roledescription").get, reflectedAttribute("aria-roledescription").set, .{ .ce_reactions = true });
    pub const ariaRowCount = bridge.accessor(reflectedAttribute("aria-rowcount").get, reflectedAttribute("aria-rowcount").set, .{ .ce_reactions = true });
    pub const ariaRowIndex = bridge.accessor(reflectedAttribute("aria-rowindex").get, reflectedAttribute("aria-rowindex").set, .{ .ce_reactions = true });
    pub const ariaRowSpan = bridge.accessor(reflectedAttribute("aria-rowspan").get, reflectedAttribute("aria-rowspan").set, .{ .ce_reactions = true });
    pub const ariaSelected = bridge.accessor(reflectedAttribute("aria-selected").get, reflectedAttribute("aria-selected").set, .{ .ce_reactions = true });
    pub const ariaSetSize = bridge.accessor(reflectedAttribute("aria-setsize").get, reflectedAttribute("aria-setsize").set, .{ .ce_reactions = true });
    pub const ariaSort = bridge.accessor(reflectedAttribute("aria-sort").get, reflectedAttribute("aria-sort").set, .{ .ce_reactions = true });
    pub const ariaValueMax = bridge.accessor(reflectedAttribute("aria-valuemax").get, reflectedAttribute("aria-valuemax").set, .{ .ce_reactions = true });
    pub const ariaValueMin = bridge.accessor(reflectedAttribute("aria-valuemin").get, reflectedAttribute("aria-valuemin").set, .{ .ce_reactions = true });
    pub const ariaValueNow = bridge.accessor(reflectedAttribute("aria-valuenow").get, reflectedAttribute("aria-valuenow").set, .{ .ce_reactions = true });
    pub const ariaValueText = bridge.accessor(reflectedAttribute("aria-valuetext").get, reflectedAttribute("aria-valuetext").set, .{ .ce_reactions = true });
    pub const children = bridge.accessor(Element.getChildren, null, .{});
    pub const firstElementChild = bridge.accessor(Element.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Element.lastElementChild, null, .{});
    pub const childElementCount = bridge.accessor(Element.getChildElementCount, null, .{});
    pub const previousElementSibling = bridge.accessor(Element.previousElementSibling, null, .{});
    pub const nextElementSibling = bridge.accessor(Element.nextElementSibling, null, .{});
    pub const after = bridge.function(Element.after, .{ .ce_reactions = true, .arity = 0 });
    pub const animate = bridge.function(Element.animate, .{ .arity = 1 });
    pub const append = bridge.function(Element.append, .{ .ce_reactions = true, .arity = 0 });
    pub const attachShadow = bridge.function(_attachShadow, .{});
    pub const before = bridge.function(Element.before, .{ .ce_reactions = true, .arity = 0 });
    pub const checkVisibility = bridge.function(Element.checkVisibility, .{});
    pub const closest = bridge.function(Element.closest, .{});
    pub const computedStyleMap = bridge.function(_computedStyleMap, .{});
    pub const getAnimations = bridge.function(Element.getAnimations, .{});
    pub const getAttribute = bridge.function(Element.getAttribute, .{});
    pub const getAttributeNS = bridge.function(Element.getAttributeNS, .{ .arity = 2 });
    pub const getAttributeNames = bridge.function(Element.getAttributeNames, .{});
    pub const getAttributeNode = bridge.function(Element.getAttributeNode, .{});
    pub const getAttributeNodeNS = bridge.function(_getAttributeNodeNS, .{ .arity = 2 });
    pub const getBoundingClientRect = bridge.function(Element.getBoundingClientRect, .{});
    pub const getClientRects = bridge.function(Element.getClientRects, .{});
    pub const getElementsByClassName = bridge.function(Element.getElementsByClassName, .{});
    pub const getElementsByTagName = bridge.function(Element.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Element.getElementsByTagNameNS, .{ .arity = 2 });
    pub const getHTML = bridge.function(_getHTML, .{});
    pub const hasAttribute = bridge.function(Element.hasAttribute, .{});
    pub const hasAttributeNS = bridge.function(Element.hasAttributeNS, .{ .arity = 2 });
    pub const hasAttributes = bridge.function(Element.hasAttributes, .{});
    pub const hasPointerCapture = bridge.function(Element.hasPointerCapture, .{ .arity = 1 });
    pub const insertAdjacentElement = bridge.function(Element.insertAdjacentElement, .{ .ce_reactions = true });
    pub const insertAdjacentHTML = bridge.function(Element.insertAdjacentHTML, .{ .ce_reactions = true });
    pub const insertAdjacentText = bridge.function(Element.insertAdjacentText, .{ .ce_reactions = true });
    pub const matches = bridge.function(Element.matches, .{});
    pub const moveBefore = bridge.function(Element.moveBefore, .{ .ce_reactions = true });
    pub const prepend = bridge.function(Element.prepend, .{ .ce_reactions = true, .arity = 0 });
    pub const querySelector = bridge.function(Element.querySelector, .{});
    pub const querySelectorAll = bridge.function(Element.querySelectorAll, .{});
    pub const releasePointerCapture = bridge.function(Element.releasePointerCapture, .{ .arity = 1 });
    pub const remove = bridge.function(Element.remove, .{ .ce_reactions = true });
    pub const removeAttribute = bridge.function(Element.removeAttribute, .{ .ce_reactions = true });
    pub const removeAttributeNS = bridge.function(_removeAttributeNS, .{ .ce_reactions = true, .arity = 2 });
    pub const removeAttributeNode = bridge.function(Element.removeAttributeNode, .{ .ce_reactions = true });
    pub const replaceChildren = bridge.function(Element.replaceChildren, .{ .ce_reactions = true, .arity = 0 });
    pub const replaceWith = bridge.function(Element.replaceWith, .{ .ce_reactions = true, .arity = 0 });
    pub const requestFullscreen = bridge.function(Element.requestFullscreen, .{});
    pub const requestPointerLock = bridge.function(Element.requestPointerLock, .{});
    pub const scroll = bridge.function(Element.scrollTo, .{});
    pub const scrollBy = bridge.function(Element.scrollBy, .{});
    pub const scrollIntoView = bridge.function(Element.scrollIntoView, .{});
    pub const scrollIntoViewIfNeeded = bridge.function(Element.scrollIntoViewIfNeeded, .{});
    pub const scrollTo = bridge.function(Element.scrollTo, .{});
    pub const setAttribute = bridge.function(_setAttribute, .{ .ce_reactions = true });
    pub const setAttributeNS = bridge.function(_setAttributeNS, .{ .ce_reactions = true, .arity = 3 });
    pub const setAttributeNode = bridge.function(Element.setAttributeNode, .{ .ce_reactions = true });
    pub const setAttributeNodeNS = bridge.function(Element.setAttributeNode, .{ .ce_reactions = true });
    pub const setHTMLUnsafe = bridge.function(Element.setHTMLUnsafe, .{ .ce_reactions = true });
    pub const setPointerCapture = bridge.function(Element.setPointerCapture, .{ .arity = 1 });
    pub const startViewTransition = bridge.function(Element.startViewTransition, .{});
    pub const toggleAttribute = bridge.function(Element.toggleAttribute, .{ .ce_reactions = true });
    pub const webkitMatchesSelector = bridge.function(Element.matches, .{});
    pub const webkitRequestFullScreen = bridge.function(Element.webkitRequestFullscreen, .{});
    pub const webkitRequestFullscreen = bridge.function(Element.webkitRequestFullscreen, .{});
    pub const currentCSSZoom = bridge.accessor(Element.getCurrentCSSZoom, null, .{});
    pub const customElementRegistry = bridge.accessor(Element.getCustomElementRegistry, null, .{});
    pub const ariaColIndexText = bridge.accessor(reflectedAttribute("aria-colindextext").get, reflectedAttribute("aria-colindextext").set, .{ .ce_reactions = true });
    pub const ariaRowIndexText = bridge.accessor(reflectedAttribute("aria-rowindextext").get, reflectedAttribute("aria-rowindextext").set, .{ .ce_reactions = true });
    pub const ariaActionsElements = bridge.accessor(reflectedElements("aria-actions").get, reflectedElements("aria-actions").set, .{ .ce_reactions = true });
    pub const ariaActiveDescendantElement = bridge.accessor(reflectedElements("aria-activedescendant").get, reflectedElements("aria-activedescendant").set, .{ .ce_reactions = true });
    pub const ariaControlsElements = bridge.accessor(reflectedElements("aria-controls").get, reflectedElements("aria-controls").set, .{ .ce_reactions = true });
    pub const ariaDescribedByElements = bridge.accessor(reflectedElements("aria-describedby").get, reflectedElements("aria-describedby").set, .{ .ce_reactions = true });
    pub const ariaDetailsElements = bridge.accessor(reflectedElements("aria-details").get, reflectedElements("aria-details").set, .{ .ce_reactions = true });
    pub const ariaErrorMessageElements = bridge.accessor(reflectedElements("aria-errormessage").get, reflectedElements("aria-errormessage").set, .{ .ce_reactions = true });
    pub const ariaFlowToElements = bridge.accessor(reflectedElements("aria-flowto").get, reflectedElements("aria-flowto").set, .{ .ce_reactions = true });
    pub const ariaLabelledByElements = bridge.accessor(reflectedElements("aria-labelledby").get, reflectedElements("aria-labelledby").set, .{ .ce_reactions = true });
    pub const ariaNotify = bridge.function(Element.ariaNotify, .{});
    pub const pseudo = bridge.function(Element.pseudo, .{});
    pub const setHTML = bridge.function(Element.setHTML, .{ .ce_reactions = true });
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the Element itself.
    pub fn call(self: *const Element, comptime func_name: []const u8, args: anytype) !bool {
        switch (self._type) {
            inline else => |tag| {
                const S = Subtype(tag);
                // `.plain` carries no subtype to dispatch to (Subtype is
                // `void`); it falls through to Element.Build below like any
                // type that implements nothing.
                if (S != void) {
                    if (@hasDecl(S, "Build")) {
                        // The inner type has its own "call" method. Defer to it.
                        if (@hasDecl(S.Build, "call")) {
                            return S.Build.call(self.subtype(S), func_name, args);
                        }

                        // The inner type implements this function. Call it and we're done.
                        if (@hasDecl(S, func_name)) {
                            return @call(.auto, @field(S, func_name), args);
                        }
                    }
                }
            },
        }

        if (@hasDecl(Element.Build, func_name)) {
            // Our last resort - the element implements this function.
            try @call(.auto, @field(Element.Build, func_name), args);
            return true;
        }

        // inform our caller (the Node) that we didn't find anything that implemented
        // func_name and it should keep searching for a match.
        return false;
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Element" {
    try testing.htmlRunner("element", .{});
}

test "Element: div chain slot size" {
    // Guard against accidental growth: new Element fields (e.g. _flags) must
    // fit in existing padding. Debug is larger from the _proto_canary fields.
    //
    // 16 bytes above upstream's own figure, which is the deliberate cost of
    // `_plain_tag_name: String`: a `.plain` element has no subtype to keep its
    // tag name on (see Element.Type.plain), so Element carries it.
    const Div = @import("element/html/Div.zig");
    const slot = comptime Factory.chainOffsetOf(Div, Div) + @sizeOf(Div);
    try testing.expectEqual(if (comptime lp.IS_DEBUG) 136 else 90, slot);
}
