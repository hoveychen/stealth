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
const Viewport = @import("../Viewport.zig");
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

    // Focusing something moves the whole chain, not just this document: the
    // frame that owns the element holds the focus, and every ancestor of it
    // reports focus too. It stays there when the element is blurred, because
    // blur hands the focus back to this document's body rather than to the
    // parent -- measured on Chrome 151.
    {
        const doc_frame = doc._frame orelse frame;
        doc_frame._page.focused_frame = doc_frame;
    }

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

pub fn getChildren(self: *Element, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .children, .name = "" },
        collections.NodeLive(.child_elements).init(root, {}, frame).htmlCollectionValue(),
    );
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
/// This walked the ancestors itself and read each one's `getStyle`, which is
/// the element's own **inline declaration** and nothing else — so a font
/// declared by a stylesheet rule never reached the box. The cascade knew:
/// `getComputedStyle` answered `13px` to a `.x{font-size:13px}` span while the
/// layout measured it at the default 16px Times, 210.64 wide against Chrome's
/// 171.148. Real pages do not write inline fonts, so that was **every** text
/// box on **every** real page, whatever the page declared
/// (tools/fingerprint/scratch/expr-sheet-font-layout.js, ten routes, at dpr 2).
///
/// The StyleManager already answers both properly — rule against inline
/// declaration with `!important` ordering, the legacy presentational
/// attributes, and inheritance up the chain with the same depth cap this walk
/// had. Asking it is the whole fix.
fn resolveFont(self: *Element, frame: *Frame) struct { face: text_measure.Face, size: f64 } {
    const style_manager = &self.ownerFrame(frame)._style_manager;
    const family = if (style_manager.computedFontFamily(self)) |declared|
        font_metrics.findInList(declared)
    else
        null;
    // The weight and the style pick which of the family's four tables the
    // measurement reads. Without them every weight measured as the regular one,
    // so `font-weight: bold` widened nothing and the same string came back the
    // same number of pixels in both -- one expression apart from Chrome.
    // `letter-spacing` and `word-spacing` are not the font, but they are the
    // rest of what it costs to advance the pen, and every path that measures
    // text already carries the face down to the kernel. Without them a string
    // measured the same width whatever either property said, which is one
    // expression apart from Chrome. Whether the font's kern pairs are charged at
    // all is the third thing the same walk answers -- `font-kerning: none` and
    // `font-feature-settings: "kern" 0` both turn them off and both inherit --
    // and it is one walk for all three because a walk each was measurably slower
    // on a real page. See computedTextStyle.
    const text_style = style_manager.computedTextStyle(self);
    return .{
        .face = .of(
            family orelse font_metrics.fallback,
            style_manager.computedFontWeight(self),
            style_manager.computedFontItalic(self),
            .{ .letter = text_style.letter, .word = text_style.word },
            // Layout, not the canvas: it leaves an opening U+0020 unpaid where
            // `measureText` charges it, and it kerns a space against a capital
            // where `measureText` does not. See text_measure.Surface.
            .layout,
            text_style.kerning,
        ),
        .size = style_manager.computedFontSize(self),
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

/// The run of rendered characters starting at `from`, or an empty slice when
/// there is none before the end. What a preserved space needs to know to charge
/// the kern pair on its RIGHT, which the caller cannot have seen yet.
fn nextRendered(str: []const u8, from: usize) []const u8 {
    var i = from;
    while (i < str.len and std.mem.indexOfScalar(u8, css_whitespace, str[i]) != null) i += 1;
    return str[i..];
}

/// The first and last codepoint of a UTF-8 slice, for the two callers that need
/// the characters on either side of a chop point rather than the bytes.
fn firstCodepoint(str: []const u8) ?u21 {
    var it = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
    return it.nextCodepoint();
}

fn lastCodepoint(str: []const u8) ?u21 {
    var it = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
    var last: ?u21 = null;
    while (it.nextCodepoint()) |cp| last = cp;
    return last;
}

fn isCollapsibleWhitespace(str: []const u8) bool {
    for (str) |c| {
        if (std.mem.indexOfScalar(u8, css_whitespace, c) == null) return false;
    }
    return true;
}

/// A run of text measured the way a COLLAPSING `white-space` renders it: every
/// run of document white space is one space, and a run at either end is nothing
/// at all. Measured on Chrome 151 in css/../element/text_whitespace_collapse.html:
/// `a   b` is three characters wide and not five, `   ab` is two, and a box
/// holding nothing but spaces has no line and no size.
///
/// The state is a field rather than a local because the run spans the text
/// nodes: `a ` and ` b` in two nodes are one space between two words, and `ab`
/// and `cd` are one word. So is an inline child -- `a <b>x</b> c` renders three
/// words -- which is what `box` is for.
///
/// `differs` is the reason this measures rather than rewrites: asking
/// `white-space` what it wants costs a cascade read, and the answer only
/// matters when the two renderings are not the same string. Text with single
/// spaces between its words and none at either end -- which is most of the text
/// on most pages -- measures identically either way and never asks.
const CollapsedRun = struct {
    /// Whether anything has been rendered yet, so a leading run drops.
    emitted: bool = false,
    /// Whether a run of white space is waiting to become a space. It becomes one
    /// only when something follows it, which is what drops a trailing run.
    pending: bool = false,
    /// Whether the collapsed rendering is anything other than the bytes as
    /// written.
    seen_difference: bool = false,
    /// The last codepoint rendered, so the space this charges between two words
    /// can carry the kern pair on its left. Null before anything has rendered
    /// and after an inline box, whose last character this cannot see.
    previous: ?u21 = null,

    /// One text node's contribution to the run's width, in `family` at `size`.
    fn measure(self: *CollapsedRun, str: []const u8, face: text_measure.Face, size: f64) f64 {
        var width: f64 = 0;
        var i: usize = 0;
        while (i < str.len) {
            if (std.mem.indexOfScalar(u8, css_whitespace, str[i]) != null) {
                // Anything but one plain space between two words renders
                // differently: a second one in a row, one before anything has
                // been rendered, and a tab or a newline, neither of which
                // advances the way the space it becomes does.
                if (self.pending or !self.emitted or str[i] != ' ') self.seen_difference = true;
                self.pending = true;
                i += 1;
                continue;
            }
            const start = i;
            while (i < str.len and std.mem.indexOfScalar(u8, css_whitespace, str[i]) == null) i += 1;
            const word = str[start..i];
            width += self.open(face, size, firstCodepoint(word));
            // Advances are additive, and so is what the two spacing properties
            // charge -- `letter-spacing` per cluster and `word-spacing` per
            // separator -- so measuring the words and the spaces apart sums to
            // measuring the rendered string.
            //
            // What a sum LOSES is a kern pair straddling a chop point, and the
            // chop point here is a space. Chrome kerns those in layout: 'ab
            // To cd' is 54.578125 at 16px serif where the words and the space
            // measured apart sum to 54.859375. So the pair on either side of
            // the space is charged by `open`, from the codepoints this tracks
            // on its behalf -- see font_space_kerning.zig. The pairs INSIDE a
            // word are the kernel's and need nothing here. (This comment used
            // to say no pair has a space on either side, which was true of
            // font_kerning.zig alone and wrong about Chrome.)
            width += text_measure.measure(face, word, size).width;
            self.previous = lastCodepoint(word);
        }
        return width;
    }

    /// A box on the line -- an inline child, which brings its own width -- is
    /// rendered content: a run before it is a space, and a run after it is not a
    /// leading one. Returns the width of that space, in the run's own font
    /// rather than the box's.
    fn box(self: *CollapsedRun, face: text_measure.Face, size: f64) f64 {
        // No codepoint either side: the box's own first character is inside a
        // width this does not measure, so the space in front of it is charged
        // without a pair. Chrome presumably kerns there too; nobody has
        // measured it, and inventing the reading would be worse than the gap.
        const width = self.open(face, size, null);
        self.previous = null;
        return width;
    }

    /// The white space owed in front of whatever is about to be rendered.
    ///
    /// `next` is the first codepoint of that content, so the space can carry
    /// the kern pair on its right; the pair on its left comes from
    /// `self.previous`. Null for either means no pair on that side.
    fn open(self: *CollapsedRun, face: text_measure.Face, size: f64, next: ?u21) f64 {
        defer {
            self.pending = false;
            self.emitted = true;
        }
        if (!self.pending or !self.emitted) return 0;
        // A space this returns has something rendered on either side of it, so
        // it is never the run's opening character and `word-spacing` is owed.
        // The kernel cannot see that from a one-character call, which is why it
        // is added here -- see text_measure.Surface.
        var width = text_measure.measure(face, " ", size).width + face.spacing.word;
        if (self.previous) |prev| width += text_measure.kernBetween(face, prev, ' ', size);
        if (next) |cp| width += text_measure.kernBetween(face, ' ', cp, size);
        return width;
    }

    /// Whether the run rendered anything at all: text that is all white space
    /// collapses away, and a box with no line has no height either.
    fn rendered(self: *const CollapsedRun) bool {
        return self.emitted;
    }

    /// Whether the collapsed rendering differs from the bytes as written, so the
    /// caller has to ask `white-space` which of the two it wants. Asked at the
    /// end, because a run still pending is a trailing one and it drops.
    fn differs(self: *const CollapsedRun) bool {
        return self.seen_difference or self.pending;
    }
};

/// How an element's inline content lays out, or null when the element is not
/// one whose box its own content decides — a block-level child means the box is
/// a stack of child boxes and contentHeight owns it, and no content at all means
/// there is no line.
///
/// Advances are additive, as is what `letter-spacing` and `word-spacing`
/// charge, so the runs are summed rather than concatenated into a buffer: this
/// sits under `offsetWidth`, which pages read in loops. A kern pair straddling
/// a chop point is the one thing a sum loses, and no pair in the table does --
/// see the note in `CollapsedRun.measure`.
///
/// Because a plain one-line element's height is its strut and nothing else, a
/// caller that wants only the height can pass `measure_width = false` and skip
/// the walk over the text — which is the whole cost here on any element holding
/// a sentence. The returned `width` is then 0 and must not be read.
fn textLayout(self: *Element, frame: *Frame, measure_width: bool, available: ?f64, place_inline: bool) ?struct { width: f64, height: f64 } {
    var scan: InlineScan = .{ .place_inline = place_inline };
    self.scanInline(frame, &scan, 0);
    if (!scan.inline_only) {
        return null;
    }
    if (scan.total_text == 0 and !scan.has_break) {
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
    // Asking costs a cascade, so it is only asked once the characters have
    // already said the answer could go either way. The property to ask for is
    // `white-space-collapse` and not `white-space` -- see
    // CSSStyleDeclaration.preservesWhitespace, which is where that went wrong
    // the first time.
    //
    // A <br> is not whitespace, so a box holding one has a line however its
    // text collapses: `<div> <br> </div>` is ONE line in Chrome -- measured --
    // where `<div> </div>` is none. One and not two because the spaces either
    // side collapse away and what is left ends with the break, which is the
    // same rule a trailing newline follows.
    if (scan.all_collapsible and !scan.has_break and !CSSStyleDeclaration.preservesWhitespace(self, frame)) {
        return null;
    }

    const font = self.resolveFont(frame);
    const strut = self.lineBoxHalves(frame, font.face, font.size);

    // One line of this element's own text is the whole of most boxes, and it is
    // answerable without the cascade reads and the per-word walk the flow below
    // pays for. Nothing here can make a second line: no break, no newline to
    // preserve, no inline box carrying text of its own, and a width that fits.
    if (!scan.has_break and !scan.has_newline and !scan.has_inline_child) {
        var width: f64 = 0;
        // Whether the shortcut can answer at all. It measures the COLLAPSED
        // rendering, which is what every value but the preserving three shows;
        // a preserved run keeps its spaces and sends a tab to the next stop,
        // and the flow below is where that lives.
        var shortcut = true;
        if (measure_width or available != null) {
            var run: CollapsedRun = .{};
            var child = self.asNode().firstChild();
            while (child) |node| : (child = node.nextSibling()) {
                if (node.is(CData.Text)) |text| {
                    const str = Factory.protoOf(text)._data.str();
                    // Each text node meets the grid on its own -- see
                    // textAdvanceUnit, where the two-node cases that say so are.
                    width += textAdvanceUnit(run.measure(str, font.face, font.size));
                }
            }
            // Text already in its collapsed form -- single spaces between the
            // words and none at either end, which is most text -- renders the
            // same either way, so the cascade read below is paid for only by the
            // boxes whose answer it can change.
            shortcut = !run.differs() or !CSSStyleDeclaration.preservesWhitespace(self, frame);
        }
        if (shortcut) {
            const box = available orelse return .{ .width = width, .height = strut.above + strut.below };
            if (width <= box) return .{ .width = width, .height = strut.above + strut.below };
        }
    }

    // The width is on the grid already -- each text node met it as it was
    // measured. It is NOT rounded to a whole pixel here: offsetWidth is an
    // integer and getBoundingClientRect is not, and the one dimension model
    // behind both serves them by keeping the fraction and letting the integer
    // readings round it, which is what Chrome does too.
    var flow: LineFlow = .{
        .keeps_newlines = CSSStyleDeclaration.preservesNewlines(self, frame),
        .collapses = !CSSStyleDeclaration.preservesWhitespace(self, frame),
        .wraps = available != null and CSSStyleDeclaration.wrapsText(self, frame),
        .box = available orelse 0,
        .space = .of(font.face, font.size),
        .space_face = font.face,
        .space_size = font.size,
        .strut_above = strut.above,
        .strut_below = strut.below,
        .open_above = strut.above,
        .open_below = strut.below,
        .line_above = strut.above,
        .line_below = strut.below,
        .measure_width = measure_width or available != null,
    };
    self.flowInline(frame, &flow, font.face, font.size, 0);
    const height = flow.finish();
    return .{ .width = flow.width, .height = height };
}

/// What one walk over an element's children says about laying its content out
/// on lines, before any of it is measured.
const InlineScan = struct {
    total_text: usize = 0,
    all_collapsible: bool = true,
    has_newline: bool = false,
    has_break: bool = false,
    /// Whether an inline box of its own is on the line. It is the difference
    /// between a one-line box the fast path can answer and one whose line
    /// heights have to be walked, because an inline box brings its own.
    has_inline_child: bool = false,
    /// False once a block-level child is found: the box is then a stack of
    /// child boxes rather than an inline formatting context.
    inline_only: bool = true,
    /// Whether inline boxes are placed at all, which is the caller's to decide.
    ///
    /// Every reading a page can make goes through getElementDimensions and says
    /// yes. `getElementHeight` says no, and that is document.elementFromPoint:
    /// it rejects thousands of elements on their y alone, and asking the cascade
    /// what each of their children's `display` is turns forty hit tests over
    /// eight hundred elements from under a second into six. It sees the height
    /// the box had before inline boxes were placed -- the same trade the wrapped
    /// text above it already makes against a y model that is synthetic anyway.
    place_inline: bool = false,
};

fn scanInline(self: *Element, frame: *Frame, scan: *InlineScan, depth: u8) void {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (el.getTag() == .br) {
                scan.has_break = true;
                continue;
            }
            // The two cheap questions first, and between them they answer
            // almost every child without a cascade read: a caller that only
            // wants a height does not place inline boxes at all, and a
            // UA-block-level element hands the box back to the child stack.
            // That is what this walk did for every element child before there
            // was an inline flow, and it is why elementFromPoint still costs
            // what it did.
            if (!scan.place_inline or !CSSStyleDeclaration.defaultDisplayIsInline(el)) {
                scan.inline_only = false;
                return;
            }
            // One cascade read, and both halves of "is this an inline box" come
            // off it: `display: none` is not on the line and is not a reason to
            // give the box back either -- the text beside one still makes a
            // line, measured on Chrome at dpr 2, where
            // `a<span style="display:none">b</span>` is 18.5 and that span alone
            // is 0. A declared block and an out-of-flow span (which blockifies)
            // are boxes this walk cannot place, and neither is a replaced tag.
            const display = CSSStyleDeclaration.resolvedDisplay(el, frame);
            if (std.mem.eql(u8, display, "none")) continue;
            if (!std.mem.eql(u8, display, "inline") or CSSStyleDeclaration.isReplacedTag(el)) {
                scan.inline_only = false;
                return;
            }
            scan.has_inline_child = true;
            if (depth < MAX_CONTAINING_BLOCK_DEPTH) {
                el.scanInline(frame, scan, depth + 1);
                if (!scan.inline_only) return;
            }
            continue;
        }
        if (node.is(CData.Text)) |text| {
            const str = Factory.protoOf(text)._data.str();
            scan.total_text += str.len;
            if (scan.all_collapsible and !isCollapsibleWhitespace(str)) scan.all_collapsible = false;
            if (!scan.has_newline and std.mem.indexOfAny(u8, str, "\n\r") != null) scan.has_newline = true;
        }
    }
}

/// Walks this element's inline content into `flow`, one line box at a time.
///
/// Two things make a line: a hard break -- a <br>, or a preserved newline --
/// and running out of room.
///
/// Breaks first, because they are not a width question. Every
/// `white-space-collapse` but `collapse` keeps newlines, and the count is
/// measured rather than derived: `a\nb\nc` is three lines under `pre`, `a\n\nb`
/// is three (a blank line is a line), `\na` is two, `a\nb\n` is two and `\n`
/// alone is one. So it is one more line than there are breaks, less one when the
/// content ends with one -- six readings for the newline, seven more for the
/// <br>, all of them assertions in css/block_height.html and
/// css/inline_content_lines.html.
///
/// Then each of those hard lines is wrapped, greedily, at whichever word does not
/// fit. Greedy is what Chrome does and the advances here are within half a pixel
/// of its own, which is enough to land on the same count: forty `word`s in a
/// 100px box are twenty lines in Chrome and twenty here, and in 200px eight and
/// in 400px four. A word wider than the whole box overflows rather than breaking,
/// which falls out of never splitting one -- twenty-four `a` in 50px is one line.
///
/// `text-wrap-mode: nowrap`, which `white-space: pre` expands to, skips the
/// wrapping half entirely: those same forty words are one line.
///
/// An inline box on the line is walked with ITS font and brings ITS line box,
/// which is why this recurses rather than reading the text off one string: a
/// `<span style="font-size:32px">` of ten words in a 100px column is ten lines
/// of 37 in Chrome, where the block's own 16px font would make five of 18.5.
fn flowInline(self: *Element, frame: *Frame, flow: *LineFlow, face: text_measure.Face, size: f64, depth: u8) void {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            // A <br> ends the line it is on, whatever `white-space` says about
            // newlines.
            if (el.getTag() == .br) {
                flow.placeWord();
                flow.endSegment();
                continue;
            }
            // The scan has already been over these children and refused the box
            // if any of them was not an inline one, so the only thing left to
            // skip here is a `display: none` child.
            if (!CSSStyleDeclaration.isInlineBox(el, frame)) continue;
            if (depth >= MAX_CONTAINING_BLOCK_DEPTH) continue;
            const font = el.resolveFont(frame);
            // An inline box raises every line its content lands on, including
            // the ones a wrap opens inside it, which is why this is a stack and
            // not a one-off `raise`.
            const halves = el.lineBoxHalves(frame, font.face, font.size);
            const outer_above = flow.open_above;
            const outer_below = flow.open_below;
            flow.open_above = @max(outer_above, halves.above);
            flow.open_below = @max(outer_below, halves.below);
            el.flowInline(frame, flow, font.face, font.size, depth + 1);
            flow.open_above = outer_above;
            flow.open_below = outer_below;
            continue;
        }
        const text = node.is(CData.Text) orelse continue;
        // The width is the widest LINE, which addText builds as it places the
        // words. It used to be the sum of the text nodes as written, which
        // counted a run of spaces once per character and counted the two sides
        // of a hard break as one line.
        flow.addText(Factory.protoOf(text)._data.str(), face, size);
    }
}

/// The greedy line builder behind flowInline, kept as a struct because the state
/// has to survive both the walk over the content and the two places a line ends.
///
/// It accumulates a HEIGHT rather than a count, because the lines are not all
/// worth the same: every line carries the block's own strut, and each inline box
/// raises the lines its content lands on to its own line box.
/// `<span style="line-height:30px">a</span><br><span>b</span>` is 48.5 in Chrome
/// — 30 and then 18.5 — where a count times one height would say 60 or 37.
/// Measured, with twelve more readings, in
/// tools/fingerprint/scratch/expr-line-contributors.js: a SHORTER inline box
/// does not lower a line (`line-height:5px` inside a plain block is still 18.5),
/// a taller one raises it whether it holds the whole line or shares it with
/// text, and the tallest of two spans is the line.
///
/// A hard break ends a SEGMENT, and each segment is wrapped on its own. The
/// last one is dropped when it is empty, which is the whole of why `a\nb\n` is
/// two lines and `a\n\nb` is three.
/// What one rendered U+0020 is worth on a line, in the three different senses
/// the line builder needs it in.
///
/// One number was enough until `letter-spacing` and `word-spacing` reached the
/// measurement: a space is a rendered character, so it earns both, but the tab
/// grid is a count of space ADVANCES and the first space of a run goes without
/// the word part.
const SpaceCost = struct {
    /// Advance plus `letter-spacing`. NOT `word-spacing`: a lone " " handed to
    /// the kernel is in the opening position of its own measurement, and the
    /// face layout builds exempts that one (see text_measure.Spacing). The two
    /// callers below add the word part where it is owed, which is also the only
    /// place that can tell whether the space opens the run.
    charged: f64,
    /// The advance alone. `tab-size` is a number of space characters, and
    /// whether Chrome scales that grid by `letter-spacing` has not been
    /// measured -- so the grid stays what it was rather than becoming a guess.
    advance: f64,
    /// The `word-spacing` part on its own, so the opening space of a run can be
    /// charged without it: Chrome makes `' ab'` under `word-spacing: 5px`
    /// exactly as wide as without, where `'ab '` is 5 wider and `'  ab'` is 5
    /// (scratch/b100/expr-spacing-table.js).
    word: f64,

    fn of(face: text_measure.Face, size: f64) SpaceCost {
        var bare = face;
        bare.spacing = .{};
        return .{
            .charged = text_measure.measure(face, " ", size).width,
            .advance = text_measure.measure(bare, " ", size).width,
            .word = face.spacing.word,
        };
    }
};

const LineFlow = struct {
    keeps_newlines: bool,
    /// Whether a run of document white space renders as one space. It is what
    /// the words this places are already built for -- addText has always joined
    /// them with exactly one space -- so it only decides where the WIDTH comes
    /// from: the widest line when it collapses, and the sum of the text as
    /// written when it does not. See flowInline.
    collapses: bool = true,
    wraps: bool,
    box: f64,
    space: SpaceCost,
    /// The face and size `space` was priced in -- the BLOCK's font, not a
    /// nested inline child's. The kern pairs a space carries are charged in the
    /// same font as the space itself, which is what makes them consistent with
    /// `space` rather than with whichever text node happens to be either side.
    space_face: text_measure.Face,
    space_size: f64,
    /// The block's own line box, split at the baseline: every line carries it.
    strut_above: f64,
    strut_below: f64,
    /// Whether the width of the text is wanted at all: the height-only callers
    /// skip a measure per text node by saying no.
    measure_width: bool,

    /// The tallest ascent and deepest descent among the inline boxes open around
    /// the text being placed, so a box that spans a wrap raises both lines.
    ///
    /// Seeded with the strut's own halves rather than with zero, because a half
    /// can be NEGATIVE: `line-height: 10px` on a 16px serif is 10.25 above the
    /// baseline and -0.25 below, and a zero floor there would make the line
    /// 10.25 tall where Chrome says 10.
    open_above: f64,
    open_below: f64,
    /// Lines already finished.
    total: f64 = 0,
    /// The line being built, split at the baseline.
    line_above: f64 = 0,
    line_below: f64 = 0,
    /// Whether any word landed in this segment. An empty last segment is the
    /// trailing break, and it is not a line.
    segment_has_word: bool = false,
    /// Width already on the current line, and the word being built.
    placed: f64 = 0,
    word: f64 = 0,
    have_word: bool = false,
    /// The characters either side of a chop point, so the space between two
    /// words can carry its kern pairs. `previous` is the last codepoint placed
    /// and `word_first` the first of the word being built; both null when there
    /// is none, which is what an atomic inline leaves behind. Chrome kerns a
    /// space against a capital in layout, and this path prices the space
    /// itself, so without these the pair is lost -- see font_space_kerning.zig.
    ///
    /// Not optional: `inlineInk` measures a whole text node in one call and so
    /// gets the pairs from the kernel. Leaving this path without them made the
    /// two disagree, and an `inline-block` sized by the first and laid out by
    /// the second wrapped onto a second line for want of the 0.5625 the first
    /// had already taken off.
    previous: ?u21 = null,
    word_first: ?u21 = null,
    word_last: ?u21 = null,
    /// Whether the text either side of a chop point shapes as one run with the
    /// space between them. A nested inline child in a different font breaks the
    /// run, and Chrome does not carry the pair across the break -- see
    /// text_measure.shapesAsOneRun.
    previous_joins: bool = false,
    word_joins: bool = false,
    width: f64 = 0,
    /// Whether a word or a break has landed in this run at all.
    any: bool = false,

    /// Whether anything at all landed in this run. A run with no word and no
    /// break is not a line: the whitespace between two block children is a text
    /// node like any other, and it contributes nothing.
    fn hasContent(self: *const LineFlow) bool {
        return self.any;
    }

    /// Starts a fresh run, which is what a block box between two of them does.
    fn restart(self: *LineFlow) void {
        self.previous = null;
        self.word_first = null;
        self.word_last = null;
        self.previous_joins = false;
        self.word_joins = false;
        self.total = 0;
        self.open_above = self.strut_above;
        self.open_below = self.strut_below;
        self.line_above = self.strut_above;
        self.line_below = self.strut_below;
        self.segment_has_word = false;
        self.placed = 0;
        self.word = 0;
        self.have_word = false;
        self.any = false;
    }

    /// The run's height, and a fresh run after it.
    fn flush(self: *LineFlow) f64 {
        // `any` is set when a word is PLACED, and the last word of a run is
        // still pending when the run ends -- so a run holding one word would
        // otherwise flush as nothing.
        if (!self.any and !self.have_word) {
            self.restart();
            return 0;
        }
        const height = self.finish();
        self.restart();
        return height;
    }

    /// One text node's words, measured in the font that reaches them.
    fn addText(self: *LineFlow, str: []const u8, face: text_measure.Face, size: f64) void {
        if (str.len == 0) return;
        self.raise();
        // Every character this call sees is in this face, so one answer covers
        // the words it accumulates and the look-ahead a preserved space does.
        const joins = text_measure.shapesAsOneRun(face, size, self.space_face, self.space_size);
        var i: usize = 0;
        while (i < str.len) {
            if (std.mem.indexOfScalar(u8, css_whitespace, str[i]) != null) {
                // Only a line feed is a segment break. A carriage return is
                // not: `a\rb` is ONE line in Chrome under `pre` -- and two
                // characters wide, because a preserved CR renders nothing --
                // where `a\r\nb` is two lines, which is the line feed in it and
                // not the pair. The parser normalises CRLF in a source document
                // before it is ever a text node; a CR that reaches one came from
                // script or from a character reference, and this is what Chrome
                // does with it. Measured, scratch/b84/expr-b84-cr.js.
                const newline = str[i] == '\n';
                self.placeWord();
                if (newline and self.keeps_newlines) {
                    self.endSegment();
                } else if (!self.collapses) {
                    // Preserved white space is rendered, so it takes room of its
                    // own on the line rather than being the gap placeWord adds
                    // between two words. A space is its advance; a tab is the
                    // distance to the next stop on the eight-character grid,
                    // and it always moves -- `a\tb` is nine characters wide in
                    // Chrome, `\tb` is nine as well, and `aaaaaaaaa\tb`, already
                    // past the first stop, is seventeen.
                    self.placed = switch (str[i]) {
                        '\t' => tabStop(self.placed, self.space.advance),
                        // Preserved, and rendered as nothing at all.
                        '\r' => self.placed,
                        // `self.any` is still false for the first thing to
                        // land in the run, which is exactly when Chrome charges
                        // no `word-spacing` -- see SpaceCost.word.
                        else => self.placed + self.space.charged +
                            (if (self.any) self.space.word else 0) +
                            self.spacePairs(firstCodepoint(nextRendered(str, i + 1)), joins),
                    };
                    self.segment_has_word = true;
                    self.any = true;
                    if (str[i] == ' ') {
                        self.previous = ' ';
                        self.previous_joins = true;
                    }
                }
                i += 1;
                continue;
            }
            const start = i;
            while (i < str.len and std.mem.indexOfScalar(u8, css_whitespace, str[i]) == null) i += 1;
            // The word may span two text nodes, so its width is carried across
            // them rather than measured per node. Advances are additive and so
            // is the spacing charge, so two fragments of one word sum to the
            // word: two nodes holding `wordwordwordwo` and `rdword word` are two
            // lines in a 100px box in Chrome and here. Two spans holding the
            // halves are the same word for the same reason. A kern pair split
            // across the two NODES is lost, which no amount of table checking
            // fixes -- unlike the split at white space, where no pair exists to
            // lose (see `CollapsedRun.measure`).
            const word = str[start..i];
            self.word += text_measure.measure(face, word, size).width;
            if (!self.have_word) {
                self.word_first = firstCodepoint(word);
                self.word_joins = joins;
            }
            self.word_last = lastCodepoint(word);
            self.word_joins = self.word_joins and joins;
            self.have_word = true;
        }
    }

    /// Text is about to land on this line, so whatever is open around it counts.
    fn raise(self: *LineFlow) void {
        if (self.open_above > self.line_above) self.line_above = self.open_above;
        if (self.open_below > self.line_below) self.line_below = self.open_below;
    }

    /// An atomic inline — a replaced element, an inline-block — is a box ON the
    /// line rather than a box the line is made of, so it raises the line by its
    /// own two halves and takes its width along the line.
    /// Where an atomic inline was put, for the caller that is laying out rather
    /// than only measuring. `inline_at` is the line cursor before the box went
    /// down -- 0 when it opened a fresh line -- and `block_at` is the height of
    /// the lines already closed above it.
    const Placed = struct { inline_at: f64, block_at: f64 };

    fn placeAtomic(self: *LineFlow, above: f64, below: f64, width: f64) Placed {
        self.placeWord();
        if (above > self.line_above) self.line_above = above;
        if (below > self.line_below) self.line_below = below;
        var inline_at = self.placed;
        if (self.wraps and self.placed > 0 and self.placed + width > self.box) {
            self.newLine();
            if (above > self.line_above) self.line_above = above;
            if (below > self.line_below) self.line_below = below;
            self.placed = width;
            inline_at = 0;
        } else {
            self.placed += width;
        }
        self.segment_has_word = true;
        self.any = true;
        return .{ .inline_at = inline_at, .block_at = self.total };
    }

    /// A box that shares the line with the text around it rather than being a
    /// line of its own -- an inline child, measured whole by its own walk. It
    /// joins the WORD, so `a<span>b</span>` is one word and `a <span>b</span>`
    /// is two with one space between them, which is exactly what a word split
    /// across two text nodes already does.
    ///
    /// A box of no width is not content: an empty <span> between two words must
    /// leave ONE space, not two.
    fn addBox(self: *LineFlow, width: f64) void {
        if (width <= 0) return;
        self.raise();
        self.word += width;
        self.have_word = true;
    }

    fn newLine(self: *LineFlow) void {
        self.recordWidth();
        self.total += self.line_above + self.line_below;
        self.line_above = @max(self.strut_above, self.open_above);
        self.line_below = @max(self.strut_below, self.open_below);
    }

    /// The line that is ending is a candidate for the box's width, which is the
    /// widest of them: a box holding `a\nbb` under a preserved newline is two
    /// characters wide and not three, and one holding `a   b` is three and not
    /// five. Called wherever a line ends -- a wrap, a hard break, the last one.
    ///
    /// On the grid once per line rather than once per text node, because a line
    /// is what is being measured here; the difference between the two is a
    /// 128th of a pixel and every integer reading rounds it away.
    fn recordWidth(self: *LineFlow) void {
        if (!self.measure_width) return;
        const line = textAdvanceUnit(self.placed);
        if (line > self.width) self.width = line;
    }

    fn placeWord(self: *LineFlow) void {
        if (!self.have_word) return;
        // A collapsing run joins its words with exactly one space, which is the
        // whole of what collapsing a run of them means. A preserving one has
        // already placed the space it had, and adding another would count it
        // twice.
        const gap = if (self.collapses and self.placed > 0)
            self.space.charged + self.space.word + self.spacePairs(self.word_first, self.word_joins)
        else
            0;
        const joined = self.placed + gap + self.word;
        // The break goes BEFORE the word that does not fit, and never inside one:
        // a word wider than the whole box overflows instead, which is why
        // twenty-four `a` in a 50px box is one line in Chrome and not four.
        if (self.wraps and self.placed > 0 and joined > self.box) {
            self.newLine();
            self.placed = self.word;
        } else {
            self.placed = joined;
        }
        self.word = 0;
        self.have_word = false;
        self.segment_has_word = true;
        self.any = true;
        self.previous = self.word_last;
        self.previous_joins = self.word_joins;
        self.word_first = null;
        self.word_last = null;
        self.word_joins = false;
    }

    /// The kern pairs a space carries: one against whatever was placed before
    /// it, one against whatever comes after. Zero on the canvas surface and
    /// zero for a family that kerns no space pair, which is most of them.
    /// `next` is the first codepoint after the space and `next_joins` whether
    /// it shapes as one run with the space; the left-hand side comes from what
    /// was placed before.
    fn spacePairs(self: *const LineFlow, next: ?u21, next_joins: bool) f64 {
        var total: f64 = 0;
        if (self.previous_joins) {
            if (self.previous) |prev| {
                total += text_measure.kernBetween(self.space_face, prev, ' ', self.space_size);
            }
        }
        if (next_joins) {
            if (next) |cp| {
                total += text_measure.kernBetween(self.space_face, ' ', cp, self.space_size);
            }
        }
        return total;
    }

    fn endSegment(self: *LineFlow) void {
        self.any = true;
        self.newLine();
        self.placed = 0;
        self.segment_has_word = false;
    }

    fn finish(self: *LineFlow) f64 {
        self.placeWord();
        self.recordWidth();
        // The last segment counts unless it is empty -- and an empty FIRST
        // segment still counts, because a box holding one preserved space is a
        // line.
        if (self.segment_has_word or self.total == 0) self.total += self.line_above + self.line_below;
        return self.total;
    }
};

/// What one line box is worth: the computed `line-height` when the cascade or the
/// UA sheet gives one, and the font's own box when it is `normal`.
///
/// This engine was always worth the font box, so `line-height:30px` on a block
/// holding one character read 18 -- while the computed VALUE beside it already
/// said `30px`, because the computed path has resolved line-height for as long
/// as it has existed. Only the layout was not asking. Measured on Chrome 151
/// with tools/fingerprint/scratch/expr-line-box.js over thirteen forms: a
/// length, a bare number, a percentage and an em, each against two font sizes,
/// and inherited from a wrapper.
///
/// cascadedComputedLength answers all of those as one number because
/// `lengthFactor` already knows line-height is the one property where a bare
/// number is a multiple of the font size, and because `normal` is not a length
/// token and so falls through as null.
///
/// On the grid, like any other used length: `line-height:1.1` at 16px is 17.6 in
/// arithmetic and 17.59375 on the page, and two lines of it are 35.1875 -- each
/// line snapped and then summed, not the sum snapped. Measured.
///
/// Not asked for a non-replaced inline box, which keeps the font box: a `<span
/// style="line-height:30px">` is 18 tall in Chrome where an `inline-block` with
/// the same declaration is 30. That is why this sits under textLayout and not
/// under inlineInk.
///
/// The `normal` half asks font_metrics for a measured line box and NOT for
/// `boundingBox().ascent + .descent`, which is what it used to sum. Those two
/// are the same number at a device pixel ratio of 1 -- sixty of sixty (face,
/// size) pairs -- and different at the 2 this engine claims, for thirty-four of
/// the same sixty: 16px serif is 18 by the canvas metrics and 18.5 on the page,
/// 20px monospace is 24 and 23, and 10px serif is 13 and 11.5. That last one is
/// why the line box is measured rather than derived -- one and a half pixels is
/// more than re-rounding the two halves onto the device pixel can move a sum.
/// The canvas box itself does not move with the scale, so `boundingBox` is
/// unchanged and correct where it is read (src/browser/tests/element/
/// line_box_height.html).
fn lineBoxHeight(self: *Element, frame: *Frame, face: text_measure.Face, size: f64) f64 {
    const halves = self.lineBoxHalves(frame, face, size);
    return halves.above + halves.below;
}

/// A line box, split at the baseline — which is where two boxes on one line are
/// lined up, and therefore the only form in which they can be combined.
///
/// The leading a `line-height` adds is half above and half below, so a font
/// bigger than its declared line gets a NEGATIVE half and sticks out of the top
/// of its own box. That is measurable and measured
/// (tools/fingerprint/scratch/expr-line-halves.js, at dpr 2): a
/// `font-size:32px; line-height:20px` span beside plain 16px text makes a
/// **24.5** line in Chrome — 20.5 of the span above the baseline against the
/// strut's 14.5, and the strut's own 4 below against the span's -0.5. The
/// tallest-line-height model says 20 to the same page, and 19.5 where Chrome
/// says 19.5 only because both halves happen to lose there.
fn lineBoxHalves(self: *Element, frame: *Frame, face: text_measure.Face, size: f64) struct { above: f64, below: f64 } {
    const box = font_metrics.layoutBox(face.family, size);
    const declared = CSSStyleDeclaration.cascadedComputedLength(self, "line-height", frame) orelse
        return .{ .above = box.ascent, .below = box.descent };
    const height = layoutUnit(@max(0, declared));
    const leading = (height - (box.ascent + box.descent)) / 2;
    return .{ .above = box.ascent + leading, .below = box.descent + leading };
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
            widest = @max(widest, text_measure.measure(font.face, word, font.size).width);
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
/// What an inline box's own content occupies: the two ways of arriving at it --
/// a sum of the text and a stack of lines -- answer in the same shape.
const InkBox = struct { width: f64, height: f64 };

fn inlineInk(self: *Element, frame: *Frame, depth: u8, containing: *?f64) InkBox {
    // The same backstop the containing-block walk has. A chain of inline
    // elements is measured one level at a time, and this is what stops a page
    // that nests them beyond anything real from walking forever.
    if (depth >= MAX_CONTAINING_BLOCK_DEPTH) return .{ .width = 0, .height = 0 };

    if (self.inlineNeedsLines()) return self.inlineInkLines(frame, depth, containing);

    var width: f64 = 0;
    var height: f64 = 0;
    var text_width: f64 = 0;
    var has_text = false;
    // The collapsed rendering of the same text, kept beside the written one for
    // the reason textLayout's walk keeps both: which of the two an inline box
    // shows is a cascade read, and the read is worth paying for only where the
    // two disagree. An inline box is where `a   b` was five characters wide.
    var collapsed_width: f64 = 0;
    var run: CollapsedRun = .{};

    const font = self.resolveFont(frame);
    var visibility_cache: VisibilityCache = .{};
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(CData.Text)) |text| {
            const str = Factory.protoOf(text)._data.str();
            if (str.len == 0) continue;
            has_text = true;
            // Per text node, the same as textLayout's walk -- see
            // textAdvanceUnit.
            text_width += textAdvanceUnit(text_measure.measure(font.face, str, font.size).width);
            collapsed_width += textAdvanceUnit(run.measure(str, font.face, font.size));
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
            const outer = box.width + box.padding_x + box.border_x;
            width += outer;
            height = @max(height, box.height + box.padding_y + box.border_y);
            // A child that renders something is content the run either side of
            // it is measured against: `a <b>x</b> c` is three words with two
            // spaces. One that renders nothing is not, and must not eat the
            // space beside it -- an empty <span> between two words leaves ONE.
            if (outer > 0) collapsed_width += textAdvanceUnit(run.box(font.face, font.size));
        }
    }

    // Text that collapses away entirely leaves no line, so the box has no
    // height either: a <span> holding three spaces is 0x0 in Chrome and this
    // engine made it a full line of three characters.
    if (run.differs() and !CSSStyleDeclaration.preservesWhitespace(self, frame)) {
        text_width = collapsed_width;
        has_text = has_text and run.rendered();
    }

    width += text_width;
    if (has_text) {
        // The same measured line box the block path takes, and not the canvas
        // font box this used to round: a `<span>` is 18.5 tall in 16px serif
        // where ascent plus descent is 18, and 23 in 20px monospace where the
        // sum is 24. Seven forms measured with
        // tools/fingerprint/scratch/expr-inline-ink-line-box.js, including two
        // that declare a line-height -- an inline box ignores the declaration
        // and keeps the font's own line either way, which is why this asks
        // font_metrics directly rather than going through lineBoxHeight.
        height = @max(height, font_metrics.lineBox(font.face.family, font.size));
    }
    return .{ .width = width, .height = height };
}

/// Whether an inline box's own content can make more than one line, or hold a
/// tab, so the sum above is not enough and the line model has to be set up.
///
/// Asked in the BYTES, before anything costs a cascade read: a <br>, a newline
/// and a tab are all rare in inline content, and the two reads
/// `inlineInkLines` needs to resolve them are the expensive half of laying a
/// page out. A newline is asked for even where it will collapse to a space,
/// because whether it does is one of those two reads.
///
/// It does not look inside an inline child -- a <br> nested in one leaves this
/// box a sum -- for the same reason the walk below measures a child whole
/// rather than descending into it.
fn inlineNeedsLines(self: *Element) bool {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (el.getTag() == .br) return true;
            continue;
        }
        if (node.is(CData.Text)) |text| {
            const str = Factory.protoOf(text)._data.str();
            if (std.mem.indexOfAny(u8, str, "\n\r\t") != null) return true;
        }
    }
    return false;
}

/// The same ink, built as LINES rather than summed, for the inline boxes whose
/// content can make more than one of them.
///
/// The line rules are flowInline's -- one more line than there are breaks, less
/// one when the content ends with a break, and the box as wide as its widest
/// line -- so this sets up that flow rather than restating them. Measured on
/// Chrome 151 in element/text_whitespace_collapse.html: a <span> holding
/// `a\nb` under `pre` is 43x168 where this engine made it one 130x84 line, and
/// one holding `a<br>bb` is 87x168 under every value of `white-space`.
///
/// The strut is the font's own line box rather than lineBoxHalves, for the
/// reason the sum path's comment gives: an inline box ignores a declared
/// line-height. All of it above the baseline and none below, because only the
/// total a line is worth is read back out.
fn inlineInkLines(self: *Element, frame: *Frame, depth: u8, containing: *?f64) InkBox {
    const font = self.resolveFont(frame);
    const line_box = font_metrics.lineBox(font.face.family, font.size);
    var flow: LineFlow = .{
        .keeps_newlines = CSSStyleDeclaration.preservesNewlines(self, frame),
        .collapses = !CSSStyleDeclaration.preservesWhitespace(self, frame),
        // An inline box has no box to wrap in: it is as wide as its content
        // makes it, and a line ends here only where something ends it.
        .wraps = false,
        .box = 0,
        .space = .of(font.face, font.size),
        .space_face = font.face,
        .space_size = font.size,
        .strut_above = line_box,
        .strut_below = 0,
        .open_above = line_box,
        .open_below = 0,
        .line_above = line_box,
        .line_below = 0,
        .measure_width = true,
    };

    var width: f64 = 0;
    var height: f64 = 0;
    var visibility_cache: VisibilityCache = .{};
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(CData.Text)) |text| {
            flow.addText(Factory.protoOf(text)._data.str(), font.face, font.size);
            continue;
        }
        if (node.is(Element)) |el| {
            // A <br> ends the line it is on, whatever `white-space` says about
            // newlines -- the same order flowInline asks these in.
            if (el.getTag() == .br) {
                flow.placeWord();
                flow.endSegment();
                continue;
            }
            if (!el.checkVisibilityCached(&visibility_cache, frame)) continue;
            // A block-level child breaks the inline in two and the box it
            // leaves behind spans the whole line -- see the sum path.
            if (CSSStyleDeclaration.breaksInline(el, frame)) {
                const box = el.dimensionsAt(frame, true, depth + 1, true);
                height = @max(height, box.height + box.padding_y + box.border_y);
                if (CSSStyleDeclaration.containingWidth(self, frame, containing, depth)) |line| {
                    width = @max(width, line);
                }
                continue;
            }
            // ONE measurement per child, carrying the depth down -- see the sum
            // path, where what happens without that is written down.
            const box = el.dimensionsAt(frame, true, depth + 1, true);
            flow.addBox(box.width + box.padding_x + box.border_x);
            height = @max(height, box.height + box.padding_y + box.border_y);
        }
    }

    // Before the width: the last line is only recorded once the flow is
    // finished, and a box whose content all collapsed away has no line and so no
    // height of its own.
    const lines = flow.finish();
    if (flow.hasContent()) height = @max(height, lines);
    return .{ .width = @max(width, flow.width), .height = height };
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
    // Bytes that became a picture render as the picture, not as the icon. The
    // header they arrived with carries the size (Frame.ImageRequest).
    if (self.intrinsicImageSize() != null) {
        return false;
    }
    const src = self.getAttributeSafe(comptime .wrap("src")) orelse return false;
    if (src.len == 0) {
        return false;
    }
    return self.asConstNode().isConnected();
}

/// The size an arrived `<img>` declared, or null for every other element and
/// for one whose bytes never became a picture.
///
/// Imported in the body rather than at the top of the file: Image.zig imports
/// this module, and the pair only has to agree at the point of use.
pub fn intrinsicImageSize(self: *const Element) ?IntrinsicBox {
    if (self.getTag() != .img) {
        return null;
    }
    const Image = @import("element/html/Image.zig");
    const image = @constCast(self).as(Image);
    if (!image.hasIntrinsicSize()) {
        return null;
    }
    return .{
        .width = @floatFromInt(image.getNaturalWidth()),
        .height = @floatFromInt(image.getNaturalHeight()),
    };
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

/// devicePixelRatio, mirroring Window's own property -- change one and the other
/// has to move, because the grid below is a device pixel's and a page can read
/// both. Held as a float for the same reason MediaQuery.zig's copy is: it is
/// divided by rather than compared against.
const DEVICE_PIXEL_RATIO: f64 = 2;

/// Steps per CSS pixel on the layout grid. The grid is 1/64 of a **device**
/// pixel, not of a CSS one, so at devicePixelRatio 2 the step is 1/128 CSS px.
///
/// Measured by running one probe at each scale factor rather than inferred:
/// `--chrome-arg --force-device-scale-factor=1` and `=2` over the same thirty
/// cases give `ceil(x*64)/64` and `ceil(x*128)/128`, and fourteen of the thirty
/// differ (tools/fingerprint/probes/expr-b81-grid-128.js,
/// expr-b81-specified-grid-dpr.js, expr-b81-grid-test-cases.js). Say the factor
/// explicitly when re-measuring: `--headed` is NOT a substitute -- headless and
/// headed answer byte-identically at the same factor, and headed merely happens
/// to default to the display's, which was 2x on the host this was read on
/// (results/b81-2x2-{headless,headed}-dsf{1,2}.json).
const LAYOUT_GRID_STEPS: f64 = 64 * DEVICE_PIXEL_RATIO;

/// A length as the layout holds it. Chrome lays out on the grid above and
/// reaches it by flooring, not rounding: `33.3%` of 400px is 133.2 in arithmetic
/// and 17049/128 on the page, because 133.2 x 128 is 17049.6 and the .6 is
/// dropped. Measured with tools/fingerprint/scratch/expr-layout-grid.js and
/// expr-grid-props.js, and re-read at both scale factors by the probes named on
/// LAYOUT_GRID_STEPS.
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
/// (tools/fingerprint/scratch/expr-precision-model.js), and again on twelve
/// chosen to separate them at the finer step, where the float model answers 11
/// of 11 and the double 0 of 11 (probes/expr-b81-precision-at-128.js). The
/// narrowing survived the grid changing size; only the step did.
///
/// This is also what absorbs the last bit of arithmetic drift, which an epsilon
/// used to be here for -- a product that comes out 1e-13 under an exact step is
/// that step once it is a float, and the epsilon is a guess at the same thing.
pub fn layoutUnit(px: f64) f64 {
    const narrowed: f64 = @as(f32, @floatCast(px));
    return @floor(narrowed * LAYOUT_GRID_STEPS) / LAYOUT_GRID_STEPS;
}

/// A length that came from MEASURING TEXT, on the same grid, reached from the
/// other side: a text advance **ceils** where a specified length floors.
///
/// Measured over 107 readings across four probes; the model
/// `sum over text nodes of ceil(f32(advance) * steps) / steps` reproduces 100 of
/// them. The three parts each have their own discriminating case:
///
///   * the ceil. `aaa bbb ccc` at 12px is 55.95703125, whose steps either side
///     are 55.953125 and 55.9609375; flooring and rounding both answer the one
///     below and Chrome answers the one above. 14px and `aaa` at 13.25px are the
///     same shape.
///   * once per TEXT NODE, not once per box. Three text nodes holding one `a`
///     each are 17.3203125 at 13px where one node holding `aaa` is 17.3125 --
///     three ceils against one -- and `aa` + `aaa` is 28.859375 where `aaaaa` is
///     28.8515625. Both hold at either scale factor, which is what says it is
///     the node count and not the arithmetic.
///   * the 32-bit narrowing, worth two readings of the 107: over a 200-glyph run
///     at 26 sizes it answers 25 where the double answers 23. Accumulating per
///     glyph in a float instead -- which is what Blink looks like it does --
///     scores 17 and is wrong.
///
/// The seven readings the model misses are the advance rather than the grid:
/// `AV` is kerned in Chrome and not here, and 8.4px and 9.9px have a per-glyph
/// advance 0.00444px under the linear one while the 24 other sizes swept are
/// linear to within float noise.
///
/// What does NOT pass through here is the integer readings. `offsetWidth`,
/// `clientWidth` and `scrollWidth` are `round()` of the box in Chrome too, and
/// they already were here, so keeping the fraction in the box is what makes both
/// halves right at once -- 693.28125 rounds to 693 and 7101.5625 to 7102.
/// Where a preserved tab lands: the next stop on a grid eight spaces wide,
/// measured from the start of the line. A tab always moves, so one that is
/// already on a stop walks a whole eight. Measured on Chrome 151 in
/// element/text_whitespace_collapse.html, in 72px monospace, where `a\tb` is
/// nine characters wide, `\tb` is nine as well, `a\t\tb` is seventeen and
/// `aaaaaaaaa\tb` -- nine characters in, so already past the first stop -- is
/// seventeen too.
fn tabStop(from: f64, space: f64) f64 {
    const stop = space * 8;
    if (stop <= 0) return from;
    return (@floor(from / stop) + 1) * stop;
}

pub fn textAdvanceUnit(px: f64) f64 {
    const narrowed: f64 = @as(f32, @floatCast(px));
    return @ceil(narrowed * LAYOUT_GRID_STEPS) / LAYOUT_GRID_STEPS;
}

/// A form control's intrinsic box lands on the DEVICE pixel -- a half of a CSS
/// pixel at the ratio 2 this engine's persona claims -- and not on the 1/64th
/// grid `layoutUnit` and `textAdvanceUnit` use. Chrome's answers say so: an
/// input's content box is 139 wide and 15.5 tall at the UA font and 1040.5 by
/// 115 at 100px, and the halves are the only fraction in any of them.
///
/// Three directions, because the three places these are used disagree and each
/// disagreement is measured rather than chosen. See intrinsicBox.
fn deviceRound(px: f64) f64 {
    return @round(px * DEVICE_PIXEL_RATIO) / DEVICE_PIXEL_RATIO;
}

fn deviceCeil(px: f64) f64 {
    return @ceil(px * DEVICE_PIXEL_RATIO) / DEVICE_PIXEL_RATIO;
}

fn deviceFloor(px: f64) f64 {
    return @floor(px * DEVICE_PIXEL_RATIO) / DEVICE_PIXEL_RATIO;
}

/// A used border, outline or column-rule width, which lands on the DEVICE pixel
/// too -- floored, and with a floor of one device pixel so a border a page
/// asked for never disappears.
///
/// Measured over thirty widths at each of `--force-device-scale-factor=1` and
/// `=2`, in runs that reported `devicePixelRatio` in the same object as the
/// widths (scratch/b72/expr-border-grid.js, readings in
/// scratch/b72/ch-dsf{1,2}.json). The two columns are `max(floor(w), 1)` and
/// `max(floor(2w)/2, 0.5)`, and fifteen of the thirty separate them: `4.6px` is
/// `4px` at one factor and `4.5px` at the other, `1.5px` is `1px` and `1.5px`.
///
/// Say the factor out loud when re-measuring this. The engine used to answer the
/// dsf=1 column while announcing `devicePixelRatio: 2`, and the test that pinned
/// it there cited a Chrome run whose factor was never written down -- a reading
/// of a device grid taken without saying which device is a reading of nothing.
///
/// This is not `layoutUnit`'s 1/64th grid: a used border width is quantised
/// before the layout sees it, which is why `3.5px` and `3.6px` give the same box
/// rather than boxes 0.1px apart.
pub fn usedWidthUnit(px: f64) f64 {
    if (px <= 0) return 0;
    return @max(deviceFloor(px), 1 / DEVICE_PIXEL_RATIO);
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
    return self.marginPx("margin-left", frame, containing, depth) +
        self.marginPx("margin-right", frame, containing, depth);
}

/// The two block-axis margins, kept apart because they do not add: they
/// collapse, and the top one and the bottom one collapse against different
/// neighbours. See contentHeight.
pub fn verticalMargins(self: *Element, frame: *Frame, containing: *?f64, depth: u8) struct { top: f64, bottom: f64 } {
    return .{
        .top = self.marginPx("margin-top", frame, containing, depth),
        .bottom = self.marginPx("margin-bottom", frame, containing, depth),
    };
}

/// One margin of a root container. The <body> is the one tag whose UA margin is
/// load-bearing, so it goes through `bodyMarginPx`; `<html>` has none and asks
/// the cascade like anything else.
fn containerMarginPx(self: *Element, name: []const u8, frame: *Frame, containing: *?f64, depth: u8) f64 {
    return if (self.getTag() == .body)
        self.bodyMarginPx(name, frame, containing, depth)
    else
        self.marginPx(name, frame, containing, depth);
}

/// Whether one margin is `auto`, which `marginPx` cannot say: it resolves a
/// length, and `auto` is not one, so it answers 0 for both `auto` and `0`.
fn marginIsAuto(self: *Element, name: []const u8, frame: *Frame) bool {
    const declared = CSSStyleDeclaration.cascadedComputedValue(self, name, frame) orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, declared, " \t\r\n"), "auto");
}

/// Where a child's border box starts inside the content box it is laid into, on
/// the inline axis.
///
/// `margin-left`, except that an `auto` margin takes a share of what is left
/// over -- which is how a block with a width centres itself. Chrome puts a
/// 200px-wide child with both margins auto at `d=100,0` inside a 400px
/// container (`scratch/b74/expr-inflow-position-matrix.js`), where reading
/// `marginPx` alone answers 0.
///
/// Only the two shapes the matrix measures are modelled: both margins auto
/// (centred) and the near one auto (pushed to the far edge). A negative
/// remainder gives 0 rather than pulling the box out of its container.
fn staticInlineOffset(
    self: *Element,
    frame: *Frame,
    available: ?f64,
    own: f64,
    containing: *?f64,
    depth: u8,
) f64 {
    if (!self.marginIsAuto("margin-left", frame)) {
        return self.containerMarginPx("margin-left", frame, containing, depth);
    }
    const box = available orelse return 0;
    const free = box - own;
    if (free <= 0) {
        return 0;
    }
    if (self.marginIsAuto("margin-right", frame)) {
        return free / 2;
    }
    return free - self.containerMarginPx("margin-right", frame, containing, depth);
}

/// One margin in px, from the cascade, so a stylesheet rule counts.
fn marginPx(self: *Element, name: []const u8, frame: *Frame, containing: *?f64, depth: u8) f64 {
    if (CSSStyleDeclaration.marginPercentagePx(self, name, frame, containing, depth)) |px| {
        return px;
    }
    // The author's number, for the same reason the percentage above does not go
    // through the computed text: six significant figures of `465.5466592px`
    // takes a grid step too much off the line.
    if (CSSStyleDeclaration.specifiedPx(self, name, frame)) |px| return px;
    if (CSSStyleDeclaration.cascadedComputedValue(self, name, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return px;
    }
    // The UA sheet, last, because nothing in the cascade carries it: `<p>`'s
    // `margin: 1em 0` reaches `getComputedStyle` off the per-tag table and never
    // reached this walk, so every paragraph stacked flush against its neighbour
    // while the computed style said 16px. `<body>` had the only case for it
    // (`bodyMarginPx`, still routed there by `containerMarginPx` so its own
    // shape does not move); this is the same fix for the other thirty-odd tags.
    if (StyleManager.userAgentValue(self, name)) |ua| {
        if (CSS.parseDimensionViewport(ua, frame)) |px| return px;
    }
    return 0;
}

/// One of `<body>`'s used margins.
///
/// `marginPx` answers 0 for a margin nobody declared, which is right for an
/// ordinary element and wrong for this one: the UA sheet's `body { margin: 8px }`
/// is what makes a document's body box narrower than its viewport, and it is
/// what `getComputedStyle(body).marginLeft` has reported all along. So a
/// declaration wins where there is one and the UA sheet answers where there is
/// not -- the order the computed style already resolves in, which is the whole
/// point: the box and the computed style beside it now read the same cascade.
fn bodyMarginPx(self: *Element, name: []const u8, frame: *Frame, containing: *?f64, depth: u8) f64 {
    if (CSSStyleDeclaration.marginPercentagePx(self, name, frame, containing, depth)) |px| {
        return px;
    }
    if (CSSStyleDeclaration.specifiedPx(self, name, frame)) |px| return px;
    if (CSSStyleDeclaration.cascadedComputedValue(self, name, frame)) |declared| {
        return CSS.parseDimensionViewport(declared, frame) orelse 0;
    }
    return body_ua_margin;
}

/// The margins that currently adjoin each other and will become one gap.
///
/// Collapsing is not "keep the larger": a negative margin pulls the neighbour
/// back, and the rule is max(positives) + min(negatives). 30 against 10 is 30
/// and 30 against -10 is 20 -- both measured, both in css/margin_collapse.html
/// -- so the two signs are accumulated apart and added only when the group is
/// paid out.
const MarginGroup = struct {
    positive: f64 = 0,
    negative: f64 = 0,

    fn join(self: *MarginGroup, margin: f64) void {
        if (margin < 0) {
            self.negative = @min(self.negative, margin);
        } else {
            self.positive = @max(self.positive, margin);
        }
    }

    /// Two runs of margins that turn out to adjoin each other become one run.
    /// Used where a child's ESCAPED margins meet the run its own margins are in:
    /// they are the same gap, so 30 escaping into a 10 is 30 and not 40.
    fn joinGroup(self: *MarginGroup, other: MarginGroup) void {
        self.positive = @max(self.positive, other.positive);
        self.negative = @min(self.negative, other.negative);
    }

    fn gap(self: MarginGroup) f64 {
        return self.positive + self.negative;
    }
};

/// Whether a first child's top margin and a last child's bottom margin pass
/// through this element instead of being counted inside it.
///
/// A margin that escapes moves the parent rather than growing it, which is why
/// three 12px blocks 10px apart make a 56px parent and not a 76px one: only
/// the two gaps between them are inside.
fn marginEscapes(self: *Element, frame: *Frame, containing: *?f64, depth: u8) struct { top: bool, bottom: bool } {
    if (CSSStyleDeclaration.establishesBlockFormattingContext(self, frame)) {
        return .{ .top = false, .bottom = false };
    }
    return .{
        .top = CSSStyleDeclaration.blockEdgePx(self, "top", frame, containing, depth) == 0,
        .bottom = CSSStyleDeclaration.blockEdgePx(self, "bottom", frame, containing, depth) == 0,
    };
}

/// The top margin that leaves `self` through its own top edge, collapsed.
///
/// `self`'s OWN margin is not in it -- the caller joins that separately. This is
/// what its first in-flow child contributes from inside, which a box with no top
/// border or padding cannot stop.
///
/// Needed because a child's position is recorded before the walk descends into
/// it, and by then the group holds only the child's own margin. The height half
/// does not have the problem: it joins `held.escaped_top` after the recursion,
/// which is too late to place the box but in time to size the parent. Chrome, on
/// `<div style="margin-top:40px">` as body's only child, puts BODY at y=40 --
/// the child's margin collapses out through body and lands above it, and body's
/// own 8px UA margin loses the max (scratch/b99/expr-body-collapse.js, four
/// shapes; a 1px border on body stops it and body goes back to 8 with the child
/// at 49).
///
/// A walk down the first-child chain, not over the subtree: it stops at the
/// first box that has an edge, is not an element, or has content in front of it.
/// So it costs the depth of that chain.
fn escapedTopMargin(self: *Element, frame: *Frame, containing: *?f64, depth: u8) MarginGroup {
    var out: MarginGroup = .{};
    var current = self;
    var level = depth;
    while (level < MAX_CONTAINING_BLOCK_DEPTH) : (level += 1) {
        if (!current.marginEscapes(frame, containing, level).top) {
            return out;
        }
        const child = current.firstFlowChild(frame) orelse return out;
        out.join(child.containerMarginPx("margin-top", frame, containing, level + 1));
        current = child;
    }
    return out;
}

/// The first thing in `self` that a margin could adjoin, or null when the first
/// thing is content -- text stops a margin from reaching the edge as surely as a
/// border does.
fn firstFlowChild(self: *Element, frame: *Frame) ?*Element {
    var node = self.asNode().firstChild();
    while (node) |n| : (node = n.nextSibling()) {
        if (n.is(CData.Text)) |text| {
            // Whitespace between tags is not content; anything else is.
            if (std.mem.trim(u8, text.asCData().getData().str(), " \t\r\n\x0c").len == 0) continue;
            return null;
        }
        const el = n.is(Element) orelse continue;
        if (el.getTag() == .br) return null;
        if (!el.checkVisibilityCached(null, frame)) continue;
        if (CSSStyleDeclaration.flowKind(el, frame) != .in_flow) continue;
        if (CSSStyleDeclaration.defaultDisplayIsInline(el) and CSSStyleDeclaration.isInlineBox(el, frame)) return null;
        if (el.atomicInlineHalves(frame) != null) return null;
        return el;
    }
    return null;
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
/// A `width` or `height` content attribute as a number, or null when the element
/// has none or wrote something that is not one. Two shapes read these: <img> and
/// <iframe>, where they are presentational hints for the CSS properties, and
/// <canvas>, where they are the buffer's own size.
fn attributeFloat(self: *Element, comptime name: []const u8) ?f64 {
    const raw = self.getAttributeSafe(comptime .wrap(name)) orelse return null;
    return std.fmt.parseFloat(f64, raw) catch null;
}

/// A form control's box is built from its FONT, and this returned a constant.
///
/// The numbers below are the ones Chrome answers at the UA's own 13.333px, and
/// they were the answer at every font size and in every family: an `<input>` at
/// `font-size: 100px` reported the same 149x17 of client box as one at 8px, and
/// so did one in monospace. A `<span>` at the same sizes is measured to the
/// pixel, so neither the metrics nor the cascade were at fault -- only this
/// table, which never saw the font.
///
/// Kasada sizes its font-metric probes as inputs at `font-size: 100px` and
/// reads clientWidth/clientHeight, so every probe came back the same box:
/// fifteen measurements on two distinct sizes where Chrome lands on six.
/// x-hyatt withholds its clearance token for exactly that, and freezing
/// Chrome's input box the same way costs Chrome the token 3 runs of 3 while the
/// same hooks returning real values keep it (tools/fingerprint/kasada-knob.mjs).
///
/// The model, measured on Chrome 151 with scratch/b84-formbox.js and the
/// per-size sweep beside it:
///
///   * the height is the font's own `line-height: normal` line box, rounded --
///     Arial gives 15, 9, 37 and 115 at 13.333, 8, 32 and 100px, and monospace
///     117 at 100px where Arial gives 115, so no single ratio covers it;
///   * the width is `size * avgCharWidth + (maxCharWidth - avgCharWidth)`,
///     twenty characters by default, from the two font constants now on
///     `font_metrics.Family`;
///   * a `<textarea>` is `rows` of those lines, a `<select>` keeps its width
///     and grows only in height, and a `<progress>` and a `<meter>` scale on
///     both axes from a 16px basis;
///   * `button` stays absent. Its whole 16x6 box is UA padding and border
///     around a 0x0 content box, and Chrome does not move it with the font --
///     measured at 100px, still 16x6.
///
/// Both metrics are hinted to whole pixels below about 24px and left fractional
/// above, which a single pair at the 100px basis cannot reproduce everywhere:
/// rounding the scaled pair matches Chrome at 8, 10, 13.333, 20, 24, 32 and
/// 100px in Arial and is a pixel out at 16 and 50. The sizes that matter are
/// exact -- the guard's 100px, and the 13.333px every default input on every
/// page uses.
/// This element's `type` in lowercase when it is an `<input>`, for the two
/// places a form control's box depends on it: the UA edges in
/// css/chrome_input_type_values.zig and `intrinsicBox` below. Null for every
/// other tag, so neither caller pays a lookup it cannot use.
///
/// The keyword is matched case-insensitively, the way every content-attribute
/// keyword is -- `type=CHECKBOX` is a checkbox -- and an unknown or absent type
/// answers `text`, which is what a browser falls back to.
pub fn inputTypeForBox(self: *Element) ?[]const u8 {
    if (self.getTag() != .input) return null;
    const raw = self.getAttributeSafe(comptime .wrap("type")) orelse return "text";
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed.len > input_type_max) return "text";
    var buf: [input_type_max]u8 = undefined;
    const lowered = std.ascii.lowerString(buf[0..trimmed.len], trimmed);
    return input_type_names.get(lowered) orelse "text";
}

/// The longest name in `input_type_names`, which bounds the lowercasing buffer.
const input_type_max = "datetime-local".len;

/// Interned so `inputTypeForBox` can return a slice that outlives its stack
/// buffer. A name that is not here is not a type Chrome knows, and Chrome
/// renders those as a text field.
const input_type_names = std.StaticStringMap([]const u8).initComptime(.{
    .{ "text", "text" },                     .{ "search", "search" },
    .{ "tel", "tel" },                       .{ "url", "url" },
    .{ "email", "email" },                   .{ "password", "password" },
    .{ "number", "number" },                 .{ "date", "date" },
    .{ "datetime-local", "datetime-local" }, .{ "month", "month" },
    .{ "week", "week" },                     .{ "time", "time" },
    .{ "color", "color" },                   .{ "checkbox", "checkbox" },
    .{ "radio", "radio" },                   .{ "range", "range" },
    .{ "file", "file" },                     .{ "submit", "submit" },
    .{ "reset", "reset" },                   .{ "button", "button" },
    .{ "image", "image" },                   .{ "hidden", "hidden" },
});

/// The CONTENT box of an input type that does not build its box from text.
///
/// Four of them do not move with the font at all -- the same box at
/// `font-size: 100px` as at the UA's 13.333px -- because what they draw is a
/// widget rather than a field of characters. Measured on Chrome 151 with
/// tools/fingerprint/scratch/b84-typebox.js, as content boxes:
///
///   * `checkbox` and `radio` are 13x13 with no padding, no border and
///     `box-sizing: border-box`, so all three of their boxes read 13x13;
///   * `range` is 129x16, also edgeless;
///   * `color` is 44x23 of content inside 1px/2px of padding and a 1px solid
///     border, which is the 48x25 of client box and 50x27 of offset box the
///     guard reads;
///   * `image` with no `src` has no box at all, and `hidden` never had one.
/// The text a button-shaped input draws, or null when this type is not one.
///
/// Chrome's default labels, measured: a `submit` with no `value` reads
/// "Submit", a `reset` reads "Reset", and a bare `button` reads nothing at all
/// -- its content box is 0 wide, which is why an empty one is 16x21 of pure
/// padding and border.
fn buttonLabel(self: *Element, input_type: []const u8) ?[]const u8 {
    const is_button = std.mem.eql(u8, input_type, "submit") or
        std.mem.eql(u8, input_type, "reset") or
        std.mem.eql(u8, input_type, "button");
    if (!is_button) return null;
    if (self.getAttributeSafe(comptime .wrap("value"))) |value| return value;
    if (std.mem.eql(u8, input_type, "submit")) return "Submit";
    if (std.mem.eql(u8, input_type, "reset")) return "Reset";
    return "";
}

fn fixedInputBox(input_type: []const u8) ?IntrinsicBox {
    if (std.mem.eql(u8, input_type, "checkbox") or std.mem.eql(u8, input_type, "radio")) {
        return .{ .width = 13, .height = 13 };
    }
    if (std.mem.eql(u8, input_type, "range")) return .{ .width = 129, .height = 16 };
    if (std.mem.eql(u8, input_type, "color")) return .{ .width = 44, .height = 23 };
    if (std.mem.eql(u8, input_type, "image")) return .{ .width = 0, .height = 0 };

    // The date family and the file picker keep their measured box, and that is
    // a deliberate stop rather than an oversight.
    //
    // Their widths are the rendered width of what they contain -- the date
    // field's segments, the picker's "Choose File" button beside its "No file
    // chosen" label -- and neither is the text formula. In Chrome both grow
    // with the font, but not proportionally and not by any constant: the file
    // picker's width less its two labels is 97.4, 145.5, 290.1 and 723.7 at
    // 13.333, 20, 40 and 100px, which is 7.30, 7.28, 7.25 and 7.24 times the
    // size -- close to a ratio and not one. Fitting a line through two measured
    // points would reproduce those two points and assert nothing in between,
    // which is the kind of invented model this table exists to avoid.
    //
    // So they are exact at the size a date field and a file picker actually
    // render at, which is also the size the Kasada guard reads them at -- its
    // 100x20 and 253x22 on x-hyatt are the `time` and `file` boxes below -- and
    // they do not follow the font until someone measures the segment layout.
    // Chrome at 100px: date 832.5x118.5, datetime-local 1441x118.5, month
    // 1071.5x118.5, week 1011.5x118.5, time 607x118.5, file 1891x121.
    if (std.mem.eql(u8, input_type, "date")) return .{ .width = 119.828125, .height = 17.5 };
    if (std.mem.eql(u8, input_type, "datetime-local")) return .{ .width = 206.328125, .height = 17.5 };
    if (std.mem.eql(u8, input_type, "month")) return .{ .width = 149.828125, .height = 17.5 };
    if (std.mem.eql(u8, input_type, "week")) return .{ .width = 141.828125, .height = 17.5 };
    if (std.mem.eql(u8, input_type, "time")) return .{ .width = 98.5, .height = 20 };
    if (std.mem.eql(u8, input_type, "file")) return .{ .width = 252.5, .height = 21.5 };
    return null;
}

/// Named rather than anonymous because `fixedInputBox` returns one too, and two
/// anonymous struct literals with the same fields are two different types.
const IntrinsicBox = struct { width: f64, height: f64 };

fn intrinsicBox(self: *Element, frame: *Frame, tag: Tag) ?IntrinsicBox {
    switch (tag) {
        // A picture that arrived is as big as it is. One that did not has no
        // intrinsic box at all -- the icon above already spoke for it.
        .img => return self.intrinsicImageSize(),
        .canvas, .video, .object, .svg, .iframe => return .{ .width = 300, .height = 150 },
        .input, .textarea, .select, .progress, .meter => {},
        else => return null,
    }

    // An input's box is its type's box. Only the text family is the field this
    // function used to assume for all of them.
    if (self.inputTypeForBox()) |input_type| {
        if (fixedInputBox(input_type)) |box| return box;
        // A button is as wide as its LABEL, not as wide as a field of
        // characters, and that is exact rather than approximate: the content
        // box of a `submit` is 41.5 at the UA font and 311.234 at 100px, which
        // are the widths of the string "Submit" measured in the same font to
        // the last digit. `value=X` gives 8.906 against a measured 8.90625, and
        // `value=XXXXXXXXXX` 88.922 against 88.921875. Its height is the line
        // box, like every other type that follows the font.
        if (buttonLabel(self, input_type)) |label| {
            const font = self.resolveFont(frame);
            return .{
                // The measured advance on the 1/64th grid, and nothing further.
                // At the device scale factor 2 this is exact: Chrome's `submit`
                // content box is 41.4921875 wide at the UA font and 311.234375
                // at 100px, which are `textAdvanceUnit` of the label's advance
                // to the last bit. The scale-1 basis needed a nudge here to keep
                // the client box off a rounding boundary; this one does not.
                .width = textAdvanceUnit(text_measure.measure(font.face, label, font.size).width),
                .height = deviceRound(font_metrics.lineBox(font.face.family, font.size)),
            };
        }
    }

    const font = self.resolveFont(frame);
    // The line box, on the device pixel. These boxes are measured at the device
    // pixel ratio 2 this engine's persona claims and `font_metrics` is swept at,
    // so the two agree now: at that scale the input's content height and a plain
    // block's `line-height: normal` box are the same number at every size, with
    // no rounding of their own -- Arial 9, 15.5, 18.5, 37 and 115 at 8, 13.333,
    // 16, 32 and 100px, monospace 9.5, 15.5, 19, 37 and 116.5.
    //
    // Only the swept table's own gap needs closing here. It holds integer sizes
    // and 13.333px is not one, so that size is extrapolated from the top of the
    // table: monospace comes out 15.556 and Arial 15.333, where Chrome answers
    // 15.5 to both. Snapping to the device pixel lands both, which the previous
    // dpr-1 floor could not do.
    const line = deviceRound(font_metrics.lineBox(font.face.family, font.size));

    return switch (tag) {
        // A <progress> and a <meter> are 160x16 and 80x16 at the 16px they
        // inherit, and both axes go with the font from there: 1000x100 and
        // 500x100 at 100px.
        .progress, .meter => .{
            .width = @round((if (tag == .progress) @as(f64, 160) else 80) * font.size / 16),
            .height = @round(font.size),
        },
        // A <select> keeps the measured constant, deliberately.
        //
        // Its height does move with the font in Chrome -- 11, 17, 19, 24, 38
        // and 114 of content at 8, 13.333, 16, 20, 32 and 100px -- but not as
        // any function of the line box, which is 9, 15.3, 18.5, 23, 37 and 115
        // at those sizes: the gap runs +2, +1.7, +0.5, +1, +1 and -1 and
        // changes sign. Rather than fit that noise, this keeps the value that
        // is exactly right at the size a <select> actually renders at, and the
        // measured table above is left for whoever derives the real model. The
        // guard that made this plan probes inputs, never selects.
        .select => .{ .width = 20, .height = 17 },
        else => blk: {
            // Both metrics exactly as the table holds them, with no hinting.
            // The scale-1 basis needed `avg` and `max` rounded to whole pixels
            // below 24px; at scale 2 they are used as measured and the fit is
            // better for it -- see the ceil below.
            const scale = font.size / font_metrics.basis;
            const avg = font.face.family.avg_char_width * scale;
            const max = font.face.family.max_char_width * scale;
            const columns: f64 = if (tag == .textarea)
                @floatFromInt(self.attributeUnsignedOr("cols", 20))
            else
                @floatFromInt(self.attributeUnsignedOr("size", 20));
            break :blk if (tag == .textarea) .{
                // A <textarea> is `cols` advances plus a 16.5px scrollbar
                // gutter, and takes no maxCharWidth term. Floored rather than
                // ceiled, which is the one place these two disagree: 10, 20 and
                // 40 columns of monospace are 96.5, 177 and 337.5 against
                // predictions of 96.77, 177.03 and 337.57. Its height is `rows`
                // lines, two by default.
                .width = deviceFloor(columns * avg + 16.5),
                .height = line * @as(f64, @floatFromInt(self.attributeUnsignedOr("rows", 2))),
            } else .{
                // Ceiled onto the device pixel, which is what this engine
                // already says about a text-derived length: a text advance
                // ceils where a specified length floors. Seven of seven size
                // attributes land under it at the UA's 13.333px in Arial --
                // 1, 2, 3, 5, 10, 20 and 40 predict 12, 18.667, 25.333, 38.667,
                // 72, 138.667 and 272 and Chrome answers 12, 19, 25.5, 39, 72,
                // 139 and 272 -- and at 100px the basis is already on the grid,
                // so the ceil is the identity and `50 * size + 40.5` is exact.
                .width = deviceCeil(columns * avg + (max - avg)),
                .height = line,
            };
        },
    };
}

/// A content attribute read as a count, falling back when it is absent or is
/// not one -- `size`, `cols` and `rows`, which are all "a positive integer or
/// the default". Zero is not a count and takes the default too, the way Chrome
/// treats `size=0`.
fn attributeUnsignedOr(self: *Element, comptime name: []const u8, fallback: u32) u32 {
    const raw = self.getAttributeSafe(comptime .wrap(name)) orelse return fallback;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return fallback;
    return if (parsed == 0) fallback else parsed;
}

/// `distribute_flex` is how a flex item's own share of its line is kept from
/// recursing: measuring one item's flex base size asks its siblings for theirs,
/// and a sibling asked with the distribution still on would ask back.
pub fn dimensionsAt(self: *Element, frame: *Frame, comptime measure_text_width: bool, depth: u8, distribute_flex: bool) Dimensions {
    return self.dimensionsIn(frame, measure_text_width, depth, distribute_flex, null);
}

/// The same measurement, told the containing block's content width instead of
/// having to go and find it.
///
/// A caller that is already laying this element out inside a box it measured
/// KNOWS that width, and handing it over is the difference between O(n) and
/// O(n·depth) for a subtree walk: without it, every child starts its own
/// measurement, reaches the fill branch below, and re-measures the whole
/// ancestor chain to find the width its parent had in hand.
///
/// Measured on a live www.homedepot.com, which reads `offsetHeight` off 513
/// elements per load (scratch/b73/count-root-reads.mjs): 6022ms of engine time
/// in those reads before, 1783ms after. On a synthetic page the shape of the
/// cost is visible directly -- 883 nodes nested 20 deep cost more per read (33ms)
/// than 2403 flat ones (9ms), which is the ancestor walk and not the node count.
///
/// Only correct when the width really is this element's containing block's: the
/// callers are the content-extent walks, whose children are in-flow or floated
/// and therefore contained by the box being measured. An out-of-flow child is
/// contained by something else and those walks skip it.
/// How many boxes have been MEASURED, counted for the cost prototype
/// (`layout-pass-cost-prototype` P2). A walk that visits each node once enters
/// this function once per node; anything above that is re-measurement, and the
/// ratio is the difference between the linear pass the plan's budget assumed and
/// whatever this actually is. A `u64` add on a path that already does dozens of
/// property lookups, and it goes away with the prototype.
pub var measure_entries: u64 = 0;

pub fn dimensionsIn(self: *Element, frame: *Frame, comptime measure_text_width: bool, depth: u8, distribute_flex: bool, containing_width: ?f64) Dimensions {
    measure_entries += 1;
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
    //
    // Seeded when the caller already knows it -- see `dimensionsIn` -- which is
    // what keeps a subtree walk from re-measuring the ancestor chain once per
    // child.
    var containing: ?f64 = containing_width;

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

        // A document's root containers are laid out IN its viewport -- inside
        // it, not equal to it, see the two paragraphs on `available` below --
        // and its viewport is the iframe element's box when it has one. What
        // used to be here were
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
        // The HEIGHT that comes out of here is still the viewport's, and that
        // is only half right. A body filling the viewport is the *quirks*
        // rendering, and an about:blank document is in quirks mode
        // (`document.compatMode` reads BackCompat, measured). A standards-mode
        // Chrome sizes a body to its CONTENT instead -- 0px for an empty one,
        // 20px for one holding a 20px div -- which this faux layout has no way
        // to compute yet; that is `content-height-memoised-subtree`. The
        // viewport is the wrong half of a real browser's two answers there, but
        // it is one of them, which the sentinel never was.
        if (tag == .html or tag == .body) {
            const owner = self.ownerFrame(frame);
            // The space this element's MARGIN box is laid into. For the root
            // that is the viewport; for the <body> it is the ROOT's content
            // box, which is not the same thing the moment the root wears a
            // border or a padding.
            //
            // `box.width - 2 * body_ua_margin` used to stand for both, and it
            // was wrong twice over: it read the viewport for an element that is
            // not laid out in it, and it stood in a constant for a margin the
            // page can declare. A `<html style="border:7px solid">` in a 400px
            // frame left its <body> 384 wide where Chrome says 370, and
            // `body{margin:20px}` stayed 384 where Chrome says 360.
            const available: Dimensions = if (tag == .body) blk: {
                const root = owner.document.getDocumentElement() orelse break :blk .{ .width = 0, .height = 0 };
                if (root == self) break :blk .{ .width = 0, .height = 0 };
                break :blk root.dimensionsAt(frame, measure_text_width, depth + 1, true);
            } else if (owner.iframe) |iframe|
                iframe.asElement().dimensionsAt(frame, measure_text_width, depth + 1, true)
            else blk: {
                const viewport = owner._page.getViewport();
                break :blk .{
                    .width = @floatFromInt(viewport.width),
                    .height = @floatFromInt(viewport.height),
                };
            };

            // And this element's own edges come out of it, the way they do for
            // any other `auto`-width block: the root's border box is the
            // viewport, not the viewport plus a border hanging outside the
            // window. Measured over nine served documents,
            // scratch/b72/expr-root-box.js against Chrome 151.
            //
            // The MARGIN half of that arrived from `prd/body-box-margin`, which
            // landed on these same lines: the body's inset is the margin the
            // page declared and not the UA's 8px doubled. Every modern reset
            // opens with `body { margin: 0 }` and Chrome's body is then the
            // whole viewport -- on www.scrapingcourse.com its body is 1920
            // where this one answered 1904 -- and
            // `documentElement.clientWidth - body.clientWidth` is 0, 6, 16 and
            // 40 for margins of 0px, 3px, 8px and 20px, twice the margin every
            // time (probes/expr-b96-body-margin.js). The 8px is still there; it
            // is in the cascade, where `getComputedStyle(body).marginLeft` was
            // reading it all along, which is what `bodyMarginPx` asks. The root
            // has no UA margin, so it asks `marginPx` directly.
            //
            // The edges are asked for here rather than read off `dims` because
            // the y-only path never fills them: `getElementHeight` clears
            // `measure_text_width`, and the block above that measures them is
            // behind it.
            const edges = if (comptime measure_text_width)
                CSSStyleDeclaration.BoxEdges{
                    .padding_x = dims.padding_x,
                    .padding_y = dims.padding_y,
                    .border_x = dims.border_x,
                    .border_y = dims.border_y,
                }
            else
                CSSStyleDeclaration.boxEdgesSharing(self, frame, &containing, depth);
            const margin_x = self.containerMarginPx("margin-left", frame, &containing, depth) +
                self.containerMarginPx("margin-right", frame, &containing, depth);
            const margin_y = self.containerMarginPx("margin-top", frame, &containing, depth) +
                self.containerMarginPx("margin-bottom", frame, &containing, depth);

            if (width == null) {
                width = @max(0, available.width - margin_x - edges.border_x - edges.padding_x);
            }
            if (height == null) {
                height = @max(0, available.height - margin_y - edges.border_y - edges.padding_y);
            }
        } else if (tag == .canvas) {
            // A canvas is the one replaced element here with an intrinsic
            // RATIO, and it comes from the BUFFER: the width/height content
            // attributes are the buffer's size, not presentational CSS hints
            // the way <img> and <iframe> take them. So a declared width scales
            // the other axis and does not leave the height attribute standing --
            // `<canvas width=400 height=100 style="width:600px">` is 600x150 in
            // Chrome and not 600x100, and a bare one at `height:5px` is 10px
            // wide and not 300. Measured over two ratios,
            // tools/fingerprint/scratch/expr-replaced-intrinsic.js.
            //
            // video, object and svg have no ratio: each keeps its 300 or its 150
            // when the other axis is declared, and an `<svg viewBox="0 0 40 10">`
            // at 600px wide is still 150 tall. Measured too, which is why this is
            // a canvas branch and not a replaced-element one.
            const buffer_width = self.attributeFloat("width") orelse 300.0;
            const buffer_height = self.attributeFloat("height") orelse 150.0;

            // The declared width, asked for even on the height-only path: a
            // canvas is the one shape whose height DEPENDS on its width, so
            // skipping the cascade there would answer 150 for a `width:600px`
            // canvas that is 300 tall. One lookup, and only for a <canvas>.
            if (width == null) {
                if (CSSStyleDeclaration.cascadedComputedLength(self, "width", frame)) |declared| {
                    width = layoutUnit(declared);
                    dims.explicit_width = true;
                }
            }

            if (width) |w| {
                if (height == null and buffer_width > 0) {
                    height = w * buffer_height / buffer_width;
                }
            } else if (height) |h| {
                if (buffer_height > 0) width = h * buffer_width / buffer_height;
            } else {
                width = buffer_width;
                height = buffer_height;
            }
        } else if (tag == .img or intrinsicBox(self, frame, tag) != null) {
            if (width == null) {
                if (self.attributeFloat("width")) |w| {
                    width = w;
                    dims.explicit_width = true;
                }
            }
            if (height == null) {
                if (self.attributeFloat("height")) |h| {
                    height = h;
                    dims.explicit_height = true;
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
            if (intrinsicBox(self, frame, tag)) |box| {
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
        // The width the text has to wrap in is this box's CONTENT width, which is
        // what `width` already holds -- the fill branch took the padding and the
        // border off it. Null when the box has no width of its own: a
        // shrink-to-fit one takes its max-content width and does not wrap, and
        // the height-only path (`getElementHeight`, which
        // document.elementFromPoint rejects thousands of elements on) never asked
        // for a width at all. That path therefore sees a one-line height for
        // wrapped text where the reported one is right, which is a hit test
        // against a y model that is already synthetic -- see
        // calculateDocumentPosition -- and not a reading a page can make.
        if (self.textLayout(frame, wants_text_width, width, measure_text_width)) |text| {
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
    if (self.cssomViewport(frame)) |view| {
        return @floatFromInt(view.width);
    }
    var visibility_cache: VisibilityCache = .{};
    return @round(self.getClientWidthWithCache(frame, &visibility_cache));
}

/// The viewport, when this element is the one CSSOM View makes answer with it.
///
/// The rule SWAPS with the document's mode: the root element answers the
/// viewport in standards mode, and the HTML body element answers it in quirks
/// mode. Only the body half used to be here, on the reasoning that "an
/// undeclared root's box is the viewport anyway" -- true, and it stops being
/// true the moment the root is not undeclared. A `<html style="padding:5px">` in
/// a 400px frame has a 396px padding box and Chrome still answers 400 for its
/// clientWidth, and `<html style="width:300px">` answers 400 as well: the root
/// reports the window it is in, never itself. Measured over nine served
/// documents, scratch/b72/expr-root-box.js against Chrome 151, and the two
/// shapes that separate the readings are in frames/root_box_edges.html.
///
/// In QUIRKS mode the root does report its own box (386 for a 400px frame whose
/// root wears a 7px border), which is the other half of the same swap.
///
/// Found on an `about:blank` iframe, which is always quirks: Chrome 151 answers
/// 300 for `body.clientWidth` in a 300px frame where this answered 284, while
/// `offsetWidth` and `getBoundingClientRect` agreed at 284 on both arms
/// (scratch/b70/expr-qc-served.js). The body's own box is irrelevant there --
/// Chrome answers the viewport through a margin, a border, an explicit
/// `width:100px` and a `display:inline` body alike, which is why this is asked
/// before any of them are measured.
///
/// Only `clientWidth` and `clientHeight` take it. `getClientWidthWithCache` is
/// deliberately left alone: `offsetWidth` and the resolved computed `width` are
/// built off it, and Chrome keeps both of those on the body's real box.
fn cssomViewport(self: *Element, frame: *Frame) ?Viewport {
    const tag = self.getTag();
    if (tag != .body and tag != .html) {
        return null;
    }
    const owner = self.ownerFrame(frame);
    const document = owner.document;
    const quirks = document.isQuirksMode();
    if (tag == .html) {
        if (quirks) return null;
        // The document's own root, not any `<html>` a page nested deeper.
        if (document.getDocumentElement() != self) return null;
        return owner.viewport();
    }
    if (!quirks) {
        return null;
    }
    // "The HTML body element" is the document's own body, not any `<body>` a
    // page happens to have deeper in the tree.
    const body = document.getBody() orelse return null;
    if (body.asElement() != self) {
        return null;
    }
    return owner.viewport();
}

pub fn getClientWidthWithCache(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache) f64 {
    if (!self.checkVisibilityCached(visibility_cache, frame)) {
        return 0.0;
    }
    return self.clientWidthOf(frame, self.getElementDimensions(frame), visibility_cache);
}

/// clientWidth off a box already measured. Split out so the rect path, which has
/// its own `dims` in hand, does not measure the same element twice: it used to
/// build the rect from the raw dimensions, and going through clientWidth for the
/// content fallback would otherwise have cost a second full measurement per rect
/// -- plus, since getElementDimensions restarts at depth 0, a second walk over
/// the children on every level of the positioned-ancestor chain the rect recurses
/// up. Guards read the rect in loops.
fn clientWidthOf(self: *Element, frame: *Frame, dims: Dimensions, visibility_cache: *VisibilityCache) f64 {
    // clientWidth is the PADDING box: content plus the padding, with the border
    // left out. Measured -- `border:5px solid` on the 1904px line answers 1894
    // here and 1904 for offsetWidth.
    if (dims.inline_box) return 0;

    const tag = self.getTag();
    if (tag == .html or tag == .body or dims.explicit_width) {
        return dims.width + dims.padding_x;
    }

    return @max(dims.width, self.contentWidth(frame, visibility_cache, .in_flow)) + dims.padding_x;
}

pub fn getClientHeight(self: *Element, frame: *Frame) f64 {
    if (self.cssomViewport(frame)) |view| {
        return @floatFromInt(view.height);
    }
    var visibility_cache: VisibilityCache = .{};
    return @round(self.getClientHeightWithCache(frame, &visibility_cache));
}

pub fn getClientHeightWithCache(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache) f64 {
    if (!self.checkVisibilityCached(visibility_cache, frame)) {
        return 0.0;
    }
    return self.clientHeightOf(frame, self.getElementDimensions(frame), visibility_cache);
}

/// clientHeight off a box already measured. See clientWidthOf.
fn clientHeightOf(self: *Element, frame: *Frame, dims: Dimensions, visibility_cache: *VisibilityCache) f64 {
    if (dims.inline_box) return 0;

    const tag = self.getTag();
    if (tag == .html or tag == .body or dims.explicit_height) {
        return dims.height + dims.padding_y;
    }

    return @max(dims.height, self.contentHeight(frame, visibility_cache, .in_flow, dims.width, 0, null).total) + dims.padding_y;
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

pub fn boundingClientRectValuesAt(self: *Element, frame: *Frame, depth: u8) DOMRect.Data {
    const dims = self.getElementDimensions(frame);

    // getBoundingClientRect is the BORDER box, the same box offsetWidth
    // reports: measured, a `padding:10px;border:5px solid` float is 8px of
    // content, 28 of clientWidth and 38 of both offsetWidth and rect width.
    //
    // So it is built the way offsetWidth and offsetHeight are, off the client
    // box, and not off the raw dimensions -- which is what it used to do, and
    // which skipped clientHeight's fallback to the sum of the children. A div
    // holding three lines of text reported 54 of computed height, 54 of
    // clientHeight, 54 of offsetHeight and 0 of rect height; with padding and a
    // border it was 66 against 30. No browser produces either pair, and a guard
    // reading both at once sees it.
    //
    // The one difference from offsetWidth is that this keeps the fraction:
    // offsetWidth is a `long` in the IDL and rounds, and a rect does not.
    var visibility_cache: VisibilityCache = .{};
    const width = if (dims.inline_box)
        dims.width + dims.padding_x + dims.border_x
    else
        self.clientWidthOf(frame, dims, &visibility_cache) + dims.border_x;
    var height = if (dims.inline_box)
        dims.height + dims.padding_y + dims.border_y
    else
        self.clientHeightOf(frame, dims, &visibility_cache) + dims.border_y;

    // A <br> is the one element whose rect is not the box offsetHeight reports.
    // It has no box at all -- 0 of clientHeight and 0 of offsetHeight, measured
    // -- but its rect is the LINE it breaks: 0 wide and 18.5 tall on the default
    // font, which is the only reading that sees it. Chrome 151, measured with
    // tools/fingerprint/scratch/expr-five-sentinel.js, beside an empty <span>
    // whose rect IS 0 by 0 -- so this is a <br> and not inline boxes in general.
    //
    // The line it breaks is the same measured line box the block path uses, and
    // not the canvas font box: re-measured at both device scales with
    // scratch/expr-br-and-svg-text-dsf.js, a <br> in 20px monospace is 24 tall
    // at scale 1 and 23 at the 2 this engine claims, which is the line box in
    // both and the canvas sum in neither.
    if (self.getTag() == .br) {
        const font = self.resolveFont(frame);
        height = font_metrics.lineBox(font.face.family, font.size);
    }

    const origin = self.boxOrigin(frame, depth);
    return .{
        .x = origin.x,
        .y = origin.y,
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
    // The width half of this took the CSSOM swap -- the scrolling element
    // reports the viewport -- and the height half deliberately did not. The
    // heights are not a swap: Chrome answers the viewport for a short document
    // and the CONTENT for a tall one (200 and 430 for the same frame, measured
    // in scratch/b72/ch-rootbox2.json), so the reading is `max(viewport,
    // content)` and this engine cannot supply the content half yet -- an
    // `auto`-height root container is stretched to its viewport here rather
    // than sized to what it holds. That is `content-height-memoised-subtree`.
    // Until it lands, the viewport is the answer for both, which is what
    // `dims.height` already is.
    if (tag == .html or tag == .body) {
        return @round(dims.height);
    }

    if (dims.inline_box) return 0;

    return @round(@max(dims.height, self.contentHeight(frame, &visibility_cache, .scrollable, dims.width, 0, null).total) + dims.padding_y);
}

/// Where one in-flow box landed, relative to the top-left of the initial
/// containing block -- the origin `getBoundingClientRect` reports against when
/// nothing is scrolled.
pub const Point = struct { x: f64, y: f64 };

/// A placed border box: where it is and how big it is.
///
/// The size rides along because the pass has already measured it and because
/// `elementFromPoint` needs it. Asking `boundingClientRectValuesAt` per
/// candidate instead is what took `document/element_from_point.html` from its
/// budget to 51 951ms over 400 paragraphs -- that call resolves a client box,
/// which can walk an element's text.
pub const PlacedBox = struct { x: f64, y: f64, width: f64, height: f64 };

/// Every in-flow box's position, filled by one pass over the document.
pub const PositionTable = std.AutoHashMapUnmanaged(*Element, PlacedBox);

/// The document-wide layout pass, threaded through the walk that already stacks
/// the children.
///
/// `contentHeight` is that walk: it visits each child in order, pays out the
/// collapsed margin group that precedes it, and advances a running `total` by
/// the child's whole box. That `total` IS the child's offset from the content
/// box it is being stacked in -- the number this engine has never kept. So the
/// pass is not a second layout algorithm, it is a sink handed to the existing
/// one: give the walk the absolute origin of the box it is filling and it can
/// name where every child ends up.
///
/// Why a parameter and not a field on the Frame: `contentHeight` is also called
/// by the readers (clientHeight, scrollHeight), which start at an element whose
/// own absolute origin is unknown. An optional parameter is what keeps those
/// calls from writing positions measured against nothing.
///
/// **Nothing reads this table.** The prototype exists to price the pass -- see
/// the `layout-pass-cost-prototype` plan -- and wiring the rect accessors to it
/// is a separate decision that the cost has to clear first.
pub const PositionPass = struct {
    table: *PositionTable,
    /// Where a positioned box WOULD have stood had it stayed in flow.
    ///
    /// A separate table on purpose. `table` answers "where is this box", which
    /// is what the rect accessors and `elementFromPoint` ask; an absolutely
    /// positioned box's static position is emphatically not that, and putting
    /// the two in one map would hand every such reader a coordinate the box was
    /// moved away from. The only reader here is `outOfFlowPosition`, for the
    /// axes a page left `auto`.
    static_table: *PositionTable,
    /// Nodes placed, so the cost can be reported per node rather than per page.
    nodes: *usize,
    /// The absolute position of the content box currently being filled.
    x: f64,
    y: f64,

    fn record(self: PositionPass, frame: *Frame, element: *Element, at: PlacedBox) void {
        self.nodes.* += 1;
        // A prototype that is only ever measured: a table this pass could not
        // grow is a missing row, not a failed page load.
        self.table.put(frame.arena, element, at) catch {};
    }

    /// Same, for the static position of a box the flow does not place. Kept out
    /// of the `nodes` count so the pass's cost-per-node reading stays the one
    /// the prototype was priced with.
    fn recordStatic(self: PositionPass, frame: *Frame, element: *Element, at: PlacedBox) void {
        self.static_table.put(frame.arena, element, at) catch {};
    }
};

/// The same walk with no sink: the height measurement that already exists,
/// asked for the whole document at once. Times the baseline the position pass is
/// an addition to, so a cost reading can say which half it is paying for.
pub fn layoutPassHeightOnly(root: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    const dims = root.getElementDimensions(frame);
    return root.contentHeight(frame, &visibility_cache, .in_flow, dims.width, 0, null).total;
}

/// One pass over the whole document, filling `table` with every in-flow box's
/// position. Returns the number of boxes placed.
///
/// The root's own content box is the origin every position is relative to, so
/// the pass starts inside `<html>`'s border and padding -- and records the root
/// itself at 0,0, which is where Chrome reports it with nothing scrolled.
pub fn layoutPassPositions(
    root: *Element,
    frame: *Frame,
    table: *PositionTable,
    static_table: *PositionTable,
) usize {
    var nodes: usize = 0;
    var visibility_cache: VisibilityCache = .{};
    const dims = root.getElementDimensions(frame);
    var containing: ?f64 = null;
    table.put(frame.arena, root, .{
        .x = 0,
        .y = 0,
        .width = dims.width + dims.padding_x + dims.border_x,
        .height = dims.height + dims.padding_y + dims.border_y,
    }) catch {};
    _ = root.contentHeight(frame, &visibility_cache, .in_flow, dims.width, 0, .{
        .table = table,
        .static_table = static_table,
        .nodes = &nodes,
        .x = CSSStyleDeclaration.blockEdgePx(root, "left", frame, &containing, 0),
        .y = CSSStyleDeclaration.blockEdgePx(root, "top", frame, &containing, 0),
    });
    return nodes;
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
//
// The stack is not all block boxes. Inline-level content between two of them --
// this element's own text, its inline boxes, its <br>s -- is a RUN of line
// boxes and contributes its lines rather than each child's box: two spans are
// one 18.5px line in Chrome where stacking them says 37, and `a<div>b</div>c`
// is 55.5 (a line, a block, a line) where stacking the block alone says 18.5.
// Both measured at dpr 2 with
// tools/fingerprint/scratch/expr-inline-content-lines.js.
fn contentHeight(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache, extent: Extent, content_width: ?f64, depth: u8, pass: ?PositionPass) ContentHeight {
    var total: f64 = 0;
    // The margins that LEAVE through this box's two block edges. They are not
    // part of its height -- that is what escaping means -- but they are part of
    // the gap outside it, so the caller has to be told. Dropping them was worth
    // 30 to 50px on six of the twelve shapes in css/margin_collapse.html: a
    // wrapper's escaped 30 simply vanished instead of becoming the gap between
    // it and its sibling.
    //
    // Reported from here rather than walked for separately, because the walk
    // that finds them is this one: the escaped group is exactly the value of
    // `group` at the moment a pay-out is SKIPPED.
    var escaped_top: MarginGroup = .{};
    var escaped_bottom: MarginGroup = .{};

    const font = self.resolveFont(frame);
    const strut = self.lineBoxHalves(frame, font.face, font.size);
    var flow: LineFlow = .{
        .keeps_newlines = CSSStyleDeclaration.preservesNewlines(self, frame),
        .wraps = content_width != null and CSSStyleDeclaration.wrapsText(self, frame),
        .box = content_width orelse 0,
        .space = .of(font.face, font.size),
        .space_face = font.face,
        .space_size = font.size,
        .strut_above = strut.above,
        .strut_below = strut.below,
        .open_above = strut.above,
        .open_below = strut.below,
        .measure_width = false,
    };
    flow.restart();

    // Margins cannot be added as each child is reached, because the gap between
    // two blocks belongs to neither of them: it is what their two adjoining
    // margins collapse to. `group` is the run of margins currently adjoining,
    // and it is paid out only when something that is not a margin ends it --
    // which at the parent's own top edge may mean paying out nothing at all,
    // since a first child's margin escapes a parent with no edge to stop it.
    //
    // The children share one containing block, so the width a percentage margin
    // takes its share of is measured once for all of them.
    var margin_containing: ?f64 = content_width;
    var escapes = self.marginEscapes(frame, &margin_containing, depth);

    // The outermost frame of a document-wide pass is the root element, whose box
    // establishes the initial block formatting context: its containing block is
    // the initial containing block and there is no box outside it for a margin
    // to move. Chrome reports <html> at 0,0 and <body> at 8,8, so <body>'s UA
    // margin is INSIDE the root and not a gap above it -- without this every
    // position in the table came out 8px short in both axes, on all 31 boxes of
    // scratch/b75/page (scratch/b75/expr-static-positions.js).
    //
    // Confined to the pass because the height readers do not care: the root's
    // clientHeight and scrollHeight both short-circuit to the viewport before
    // this total is used, so correcting it for them would be a change with no
    // observable half.
    if (pass != null and depth == 0) escapes = .{ .top = false, .bottom = false };
    var group: MarginGroup = .{};
    var placed = false;

    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (el.getTag() == .br) {
                flow.placeWord();
                flow.endSegment();
                continue;
            }
            if (CSSStyleDeclaration.defaultDisplayIsInline(el) and CSSStyleDeclaration.isInlineBox(el, frame)) {
                const child_font = el.resolveFont(frame);
                const halves = el.lineBoxHalves(frame, child_font.face, child_font.size);
                const outer_above = flow.open_above;
                const outer_below = flow.open_below;
                flow.open_above = @max(outer_above, halves.above);
                flow.open_below = @max(outer_below, halves.below);
                // Where the line cursor stands on either side of this box is
                // where the box is and how wide it is. An inline element gets no
                // row otherwise -- the walk hands it to the line rather than
                // stacking it -- and without one it keeps the node-count
                // position, which is the last place `x == y` survives. Chrome
                // puts the `<a>` filling an `<h2>` at x=8 with the line's own
                // 27.5 of height (scratch/b99/expr-bounding-rect-page.js).
                const line_x = flow.placed;
                const line_y = flow.total;
                el.flowInline(frame, &flow, child_font.face, child_font.size, 1);
                if (pass) |p| {
                    // Only a box that stayed on its line: a wrapped inline is a
                    // union of line boxes and nothing here has measured one.
                    if (flow.total == line_y and flow.placed > line_x) {
                        p.record(frame, el, .{
                            .x = p.x + line_x,
                            .y = p.y + total + line_y,
                            .width = flow.placed - line_x,
                            .height = halves.above + halves.below,
                        });
                    }
                }
                flow.open_above = outer_above;
                flow.open_below = outer_below;
                continue;
            }
            if (!el.checkVisibilityCached(visibility_cache, frame)) continue;
            const kind = CSSStyleDeclaration.flowKind(el, frame);
            if (!extent.counts(kind)) {
                // A float leaves the block flow but still starts where the flow
                // had got to, which is what Chrome reports: the float and the
                // block after it both sit at `d=0,0` in
                // `scratch/b74/expr-inflow-position-matrix.js`. So it takes a
                // position and does not advance `total`.
                //
                if (pass) |p| {
                    const out_box = el.dimensionsIn(frame, true, depth + 1, true, content_width);
                    const at: PlacedBox = .{
                        .x = p.x + el.staticInlineOffset(
                            frame,
                            content_width,
                            out_box.width + out_box.padding_x + out_box.border_x,
                            &margin_containing,
                            depth,
                        ),
                        .y = p.y + total,
                        .width = out_box.width + out_box.padding_x + out_box.border_x,
                        .height = out_box.height + out_box.padding_y + out_box.border_y,
                    };
                    // A float leaves the block flow but still starts where the
                    // flow had got to, which is what Chrome reports: the float
                    // and the block after it both sit at `d=0,0` in
                    // `scratch/b74/expr-inflow-position-matrix.js`. So it takes
                    // a position and does not advance `total`.
                    //
                    // A positioned box takes the same reading, but into the
                    // static table rather than this one: it is where the box
                    // WOULD be, which is the answer `left:auto` resolves to and
                    // nothing else. Chrome puts an `position:absolute` box with
                    // no offsets at exactly the spot the flow had reached --
                    // 23,63 behind a 40px sibling in a host whose content box
                    // starts at 23,23 (scratch/h86/expr-h86-offsetparent.js).
                    switch (kind) {
                        .floated => p.record(frame, el, at),
                        .positioned => p.recordStatic(frame, el, at),
                        .in_flow => {},
                    }
                }
                continue;
            }
            if (el.atomicInlineHalves(frame)) |halves| {
                const box = el.dimensionsIn(frame, true, depth + 1, true, content_width);
                const at = flow.placeAtomic(halves.above, halves.below, box.width + box.padding_x + box.border_x);
                // An atomic inline shares a line, so its inline position is the
                // line cursor before it was placed -- Chrome puts a pair of
                // 80px inline-blocks at `d=0,0` and `d=80,0`. The block axis is
                // where the run of lines has got to; only the single-line case
                // is in the matrix, so that is the only one measured.
                if (pass) |p| {
                    p.record(frame, el, .{
                        .x = p.x + at.inline_at,
                        .y = p.y + total + at.block_at,
                        .width = box.width + box.padding_x + box.border_x,
                        .height = box.height + box.padding_y + box.border_y,
                    });
                }
                continue;
            }
            // A block box ends the run of lines above it, and opens a new one
            // below. Lines between two blocks also stop their margins
            // adjoining, so the group has to be settled before the lines land.
            const lines = flow.flush();
            if (lines > 0) {
                if (placed or !escapes.top) total += group.gap() else escaped_top = group;
                group = .{};
                total += lines;
                placed = true;
            }

            const box = el.dimensionsIn(frame, true, depth + 1, true, content_width);
            const margins = el.verticalMargins(frame, &margin_containing, depth);
            group.join(margins.top);
            // What the child HOLDS. `box.height` is only the child's own
            // content box, so without this a wrapper around a 12px div is 0
            // here and 12 in Chrome, at every depth -- 16 levels down and 40
            // wrappers wide alike (scratch/b72/expr-child-box-nested.js: five
            // shapes, byte-identical to Chrome now, four of the five zero
            // before).
            //
            // This term was written and reverted three times
            // (`content-height-memoised-subtree`) on the reading that it made
            // `WebApi: Element` end in ExecutionTerminated. It does not. What
            // it does is make `element/position.html`'s scrollHeight marquee
            // loop stop terminating -- correctly, and Chrome does not terminate
            // it either -- and that loop doubles its markup 50 times, so the
            // page hangs and one 30-second watchdog stall takes the rest of the
            // binary with it. That cascade is what was counted as "373
            // ExecutionTerminated"; see the B72 chapter in the fingerprint
            // README, and the loop's own comment for why it is asserted the
            // other way round now. The cost is about 9% of a warm suite run.
            //
            // `depth` bounds it at MAX_CONTAINING_BLOCK_DEPTH. The child's box
            // is measured with `dimensionsIn` and handed the width it is being
            // laid into, which is the only thing that makes this walk
            // affordable: measuring the child through `getElementDimensions`
            // instead starts it at depth 0, and it then re-measures the whole
            // ancestor chain to find the width this frame already has. Carrying
            // the depth ALONE was measured to change nothing
            // (probes/b72-depth-carry-attempt.patch), and so was a memo on the
            // Frame (probes/b72-memo-attempt.patch) -- it is the seeded width
            // that moves it, 6022ms of homedepot's offsetHeight reads down to
            // 1783 (scratch/b73/count-root-reads.mjs).
            // Where this child's border box lands, for the one caller that is
            // laying the whole document out rather than measuring one box. The
            // gap is previewed rather than paid here because the
            // self-collapsing branch below must not pay it -- the payout at the
            // end of this block computes the identical value.
            var child_pass: ?PositionPass = null;
            if (pass) |p| {
                // `containerMarginPx` and not `marginPx`: the two differ on
                // exactly one element, `<body>`, whose UA margin is a fallback
                // the cascade cannot answer for. The stacking walk asks
                // `marginPx` and therefore reads 0 there, which put every box
                // in the table 8px short in both axes -- measured on
                // scratch/b75/page, all 31 of them, before and after.
                //
                // Joined into a COPY of the group so the height half of this
                // walk keeps the number it has always had.
                var placement = group;
                placement.join(el.containerMarginPx("margin-top", frame, &margin_containing, depth));
                // What will escape out of this child from inside. It collapses
                // with the child's own margin, and the max of the two is where
                // the child's border box lands -- so it has to be known before
                // the position is written, which is before the walk descends.
                placement.joinGroup(el.escapedTopMargin(frame, &margin_containing, depth));
                const gap = if (placed or !escapes.top) placement.gap() else 0;
                const child_y = p.y + total + gap;
                const child_x = p.x + el.staticInlineOffset(
                    frame,
                    content_width,
                    box.width + box.padding_x + box.border_x,
                    &margin_containing,
                    depth,
                );
                p.record(frame, el, .{
                    .x = child_x,
                    .y = child_y,
                    .width = box.width + box.padding_x + box.border_x,
                    .height = box.height + box.padding_y + box.border_y,
                });
                child_pass = .{
                    .table = p.table,
                    .static_table = p.static_table,
                    .nodes = p.nodes,
                    .x = child_x + CSSStyleDeclaration.blockEdgePx(el, "left", frame, &margin_containing, depth),
                    .y = child_y + CSSStyleDeclaration.blockEdgePx(el, "top", frame, &margin_containing, depth),
                };
            }

            var inner = box.height;
            // What LEAVES the child through its own two edges, which adjoins
            // the run this box's margins are in. Empty unless the child has no
            // edge on that side to stop it -- `marginEscapes` inside the
            // recursion is what decides that -- so a padded or bordered child
            // reports nothing and keeps its gaps to itself.
            var held: ContentHeight = .{};
            // A declared height means the children cannot change this box, so
            // measuring one stops here -- but a document-wide pass still has to
            // place what is inside it, or the table it fills covers only the
            // auto-height part of the tree and the cost it reports is not the
            // cost of laying the document out.
            if (depth < MAX_CONTAINING_BLOCK_DEPTH and (!box.explicit_height or child_pass != null)) {
                held = el.contentHeight(frame, visibility_cache, extent, box.width, depth + 1, child_pass);
                if (!box.explicit_height) inner = @max(inner, held.total) else held = .{};
            }
            // The height the child ENDS UP with, now that the walk knows what it
            // holds. The row went in before the recursion because the position
            // had to; a box whose own content box is 0 and which wraps three
            // lines of text is 0 tall until this correction, and
            // `elementFromPoint` would never land inside it.
            if (pass) |p| {
                if (p.table.getPtr(el)) |row| {
                    row.height = inner + box.padding_y + box.border_y;
                }
            }
            group.joinGroup(held.escaped_top);
            if (inner == 0 and box.padding_y == 0 and box.border_y == 0) {
                // Self-collapsing: there is nothing between this box's two
                // margins, so they join the same group and it contributes no
                // height of its own. An empty <div style="margin:10px 0">
                // between two blocks leaves them 10 apart, not 20.
                //
                // Whatever escaped it joins that same group, from both sides:
                // a wrapper whose only content is an empty margined box is
                // itself self-collapsing, and the 30px inside it is the one gap
                // its two neighbours end up sharing.
                group.join(margins.bottom);
                group.joinGroup(held.escaped_bottom);
                continue;
            }
            if (placed or !escapes.top) total += group.gap() else escaped_top = group;
            group = .{};
            // The child's WHOLE box. `box.height` is its content height, and
            // its padding and border are inside this parent however much they
            // are outside that -- which the child itself already knows, since
            // its own offsetHeight is `height + padding_y + border_y`. Reading
            // only the middle of it made a parent disagree with its own child:
            // a padded child answers 22 for itself and the parent answered 12.
            total += inner + box.padding_y + box.border_y;
            placed = true;
            group.join(margins.bottom);
            group.joinGroup(held.escaped_bottom);
            continue;
        }
        if (node.is(CData.Text)) |text| {
            flow.addText(Factory.protoOf(text)._data.str(), font.face, font.size);
        }
    }

    const trailing = flow.flush();
    if (trailing > 0) {
        if (placed or !escapes.top) total += group.gap() else escaped_top = group;
        group = .{};
        total += trailing;
    }
    // Whatever is left is the bottom margin of the last thing in the box, and
    // it leaves through the bottom edge on the same terms the first one came in
    // through the top.
    if (!escapes.bottom) total += group.gap() else escaped_bottom = group;
    return .{ .total = total, .escaped_top = escaped_top, .escaped_bottom = escaped_bottom };
}

/// Where an atomic inline sits on the line, or null when the element is not one.
///
/// An atomic inline is a box ON the line rather than a box the line is made of:
/// a replaced element, an `inline-block`, an `inline-flex`. Which half of it is
/// above the baseline is what decides the line, and it is not the same answer
/// for all of them — measured at dpr 2 with
/// tools/fingerprint/scratch/expr-line-halves.js:
///
///   * a replaced element stands ON the baseline, so all of it is above and
///     nothing below: `a<img width=40 height=30>b` is 34, which is the img's 30
///     over the strut's own 4 of descent, and a 10px one is 18.5 because the
///     strut is taller than it is;
///   * an inline-block with a line inside it brings that line's baseline, so its
///     descent is its own font's and the rest is above: `a<div
///     style="display:inline-block">b</div>` is 18.5 and not 22.5, and one two
///     lines tall is 37;
///   * an inline-block with nothing in it has no baseline to bring and behaves
///     like a replaced element: an empty one 50px tall makes a 54px line.
fn atomicInlineHalves(self: *Element, frame: *Frame) ?struct { above: f64, below: f64 } {
    const display = CSSStyleDeclaration.resolvedDisplay(self, frame);
    const replaced = CSSStyleDeclaration.isReplacedTag(self);
    const atomic = (replaced and std.mem.eql(u8, display, "inline")) or
        std.mem.eql(u8, display, "inline-block") or
        std.mem.eql(u8, display, "inline-flex") or
        std.mem.eql(u8, display, "inline-grid") or
        std.mem.eql(u8, display, "inline-table");
    if (!atomic) return null;

    const dims = self.getElementDimensions(frame);
    const height = dims.height + dims.padding_y + dims.border_y;
    if (replaced or !self.hasInlineBaseline(frame, 0)) {
        return .{ .above = height, .below = 0 };
    }
    const font = self.resolveFont(frame);
    const below = @min(height, font_metrics.layoutBox(font.face.family, font.size).descent);
    return .{ .above = height - below, .below = below };
}

/// Whether this box has a line of its own for its baseline to come from, which
/// for an atomic inline is the difference between sitting on the baseline and
/// bringing its own. Bounded like every other walk here.
fn hasInlineBaseline(self: *Element, frame: *Frame, depth: u8) bool {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(CData.Text)) |text| {
            if (!isCollapsibleWhitespace(Factory.protoOf(text)._data.str())) return true;
            continue;
        }
        if (node.is(Element)) |el| {
            if (el.getTag() == .br) return true;
            if (depth >= MAX_CONTAINING_BLOCK_DEPTH) continue;
            if (el.hasInlineBaseline(frame, depth + 1)) return true;
        }
    }
    return false;
}

/// Which of a box's children a reading is the extent of. Every visible child used
/// to count for both, and a child that is not in the flow is not in the stack:
/// Chrome puts a block holding only a floated, `absolute` or `fixed` child at 0
/// of clientHeight, measured with
/// tools/fingerprint/scratch/expr-out-of-flow-stack.js.
///
/// The two part company on the float, which is why this is not one predicate: a
/// float is out of its parent's height and still inside the parent's scrollable
/// overflow, so a block holding one reads 0 of clientHeight and 18 of
/// scrollHeight. Measured; an `absolute` child is out of both.
/// What a box holds: its content height, and the margins that left through its
/// two block edges on the way out. See `contentHeight`.
const ContentHeight = struct {
    total: f64 = 0,
    escaped_top: MarginGroup = .{},
    escaped_bottom: MarginGroup = .{},
};

const Extent = enum {
    /// clientWidth, clientHeight and the box a computed width and height report.
    in_flow,
    /// scrollWidth and scrollHeight.
    scrollable,

    fn counts(self: Extent, kind: CSSStyleDeclaration.FlowKind) bool {
        return switch (kind) {
            .in_flow => true,
            .floated => self == .scrollable,
            .positioned => false,
        };
    }
};

pub fn getScrollWidth(self: *Element, frame: *Frame) f64 {
    var visibility_cache: VisibilityCache = .{};
    if (!self.checkVisibilityCached(&visibility_cache, frame)) {
        return 0.0;
    }

    const dims = self.getElementDimensions(frame);

    // The scrolling element reports the VIEWPORT here, exactly as it does for
    // clientWidth -- and it is the same swap, so the root answers it in
    // standards mode and the <body> in quirks. Measured over nine served
    // documents: a `<html style="width:300px">` in a 400px frame answers
    // scrollWidth 400, which is the reading that says this is the window's
    // scrolling area and not a box that happens to match it
    // (scratch/b72/expr-root-box.js, frames/root_box_edges.html).
    //
    // What used to be here was `@round(dims.width)` for BOTH root containers in
    // BOTH modes, guarding against the artificial giant defaults the root box
    // once carried (1920 and 100_000_000). Those are gone -- the root is laid
    // out in its frame's viewport now -- and the guard outlived them, dropping
    // the padding every other element adds and answering the box in the two
    // cases Chrome answers the window.
    if (self.cssomViewport(frame)) |view| {
        return @floatFromInt(view.width);
    }

    if (dims.inline_box) return 0;

    // The scrollable overflow area includes the padding: measured, a
    // `width:100px;padding:10px` box holding a 300px child answers 120 for
    // clientWidth and 320 for scrollWidth. Rounded, like the other two.
    return @round(@max(dims.width, self.contentWidth(frame, &visibility_cache, .scrollable)) + dims.padding_x);
}

// How far the direct child elements reach past this element's left content
// edge: the sum of their widths when they share a row, and the widest of them
// when they stack.
//
// It used to be the sum unconditionally, on the grounds that the layout mode
// could not be seen from here -- getStyle() saw only the inline `style=`
// attribute. `CSSStyleDeclaration.childArrangement` can see it now, and the
// difference was not small: three 400px block children in a 400px box answered
// 1200 where Chrome answers 400, and every stacking arrangement was wrong the
// same way (a flex column, a wrapping flex row, a grid in rows, floats too wide
// to share a line, inline-blocks with nothing holding the line together).
//
// The sum was also kept for a second reason, and that one was measured before
// it was dropped: a page that appends children until `scrollWidth` passes a
// threshold -- the infinite-marquee idiom -- never terminates if the metric
// ignores what was just inserted. Measured on Chrome 151
// (tools/fingerprint/probes/expr-b96-scroll-width.js), Chrome's loop does not
// terminate either when the children are blocks: fifty 100px divs appended into
// a 200px box and `scrollWidth` is still 200. No page is written that way. The
// shape a marquee actually uses -- a `white-space: nowrap` strip of
// inline-blocks -- is a row here as it is there, and both engines take three
// cells to pass 200px.
//
// Only direct children are measured, never the whole subtree. This runs on
// every scrollWidth read, and recursing would make an element's cost O(subtree)
// rather than O(fan-out). The extra per-child cascade read the row question
// needs is only paid under `.inline_row`, which is the only arrangement whose
// answer depends on the children's own displays.
//
// Text children are not measured, matching contentHeight. Estimating a text run
// from its length would need a per-character advance, which in turn has to track
// font-size or "shrink the font until it fits" loops stop converging — and it
// would report overflow for practically every element containing text, since a
// few words already exceed the default box. Element children are what content
// grown by script actually consists of.
fn contentWidth(self: *Element, frame: *Frame, visibility_cache: *VisibilityCache, extent: Extent) f64 {
    const arrangement = CSSStyleDeclaration.childArrangement(self, frame);
    if (arrangement == .reversed_row) {
        return 0;
    }

    var total: f64 = 0;
    var widest: f64 = 0;
    // Whether the children are still the kind this arrangement puts on one
    // line. Only the two arrangements that ask pay for the answer, and only
    // until the first child that says no.
    var share_a_line = true;

    // The cache arrives seeded by the caller's own visibility walk, and
    // siblings share that ancestor chain, so the loop costs one own-element
    // check per child rather than N ancestor walks.
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |el| {
            if (!el.checkVisibilityCached(visibility_cache, frame)) continue;
            if (!extent.counts(CSSStyleDeclaration.flowKind(el, frame))) continue;
            const width = el.getElementDimensions(frame).width;
            total += width;
            widest = @max(widest, width);
            if (share_a_line) {
                share_a_line = switch (arrangement) {
                    .inline_row => CSSStyleDeclaration.isInlineLevel(el, frame),
                    .unbreakable_run => CSSStyleDeclaration.isInlineBox(el, frame),
                    else => true,
                };
            }
        }
    }

    return switch (arrangement) {
        .row => total,
        .inline_row, .unbreakable_run => if (share_a_line) total else widest,
        .stacked => widest,
        .reversed_row => unreachable,
    };
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

/// Where this element's border box starts, in the same coordinates its rect is
/// in. The one dispatch both the rect and the offsets have to agree on: a box
/// the page positioned is placed by its own declaration, and everything else by
/// the flow.
fn boxOrigin(self: *Element, frame: *Frame, depth: u8) DOMRect.Data {
    if (self.outOfFlowPosition(frame, depth)) |placed| {
        return .{ .x = placed.x, .y = placed.y };
    }
    return .{
        .x = siblingPosition(self.asNode(), frame),
        .y = documentPosition(self.asNode(), frame),
    };
}

/// What `offsetLeft` and `offsetTop` are measured from: the PADDING edge of the
/// offsetParent.
///
/// Measured across twelve shapes in `scratch/h86/expr-h86-offsetparent.js`. In a
/// host at 8,8 with a 5px border, `rect - offset` is 13,13 for every descendant
/// -- a static one, a relative one, an absolute one, one reached through a
/// static wrapper -- and for a table cell, which is an offsetParent without
/// being positioned, it is the cell's own origin.
///
/// The two exceptions subtract nothing at all, and both were already right: a
/// null offsetParent (a fixed box), and the body element, where Chrome reports
/// the document coordinate even though body's padding edge is 8,8 under the
/// default margin.
fn offsetParentPaddingEdge(self: *Element, frame: *Frame) DOMRect.Data {
    const parent = self.getOffsetParent(frame) orelse return .{};
    if (parent.getTag() == .body) return .{};
    return frame.offsetParentEdge(parent);
}

/// The uncached half of the above, for `Frame.offsetParentEdge` to fill with.
///
/// Three cascade reads on the parent -- its position, and each of its two border
/// widths through the visibility and inline-box tests `clientLeft` applies --
/// which is why the answer is memoised per parent rather than per reader. Two
/// hundred siblings in one positioned host share one entry.
pub fn paddingEdgeOf(self: *Element, frame: *Frame) DOMRect.Data {
    const origin = self.boxOrigin(frame, 0);
    return .{
        .x = origin.x + self.getClientLeft(frame),
        .y = origin.y + self.getClientTop(frame),
    };
}

/// Both are a `long` in the IDL, so both round -- the same way `offsetWidth` and
/// `offsetHeight` above do. A line box above the target makes the static
/// position a fraction, and this engine handed back the raw 41.5 where Chrome
/// answers 28: `Number.isInteger(el.offsetTop)` was false, which no browser
/// produces.
pub fn getOffsetTop(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    return @round(self.boxOrigin(frame, 0).y - self.offsetParentPaddingEdge(frame).y);
}

pub fn getOffsetLeft(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    return @round(self.boxOrigin(frame, 0).x - self.offsetParentPaddingEdge(frame).x);
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
/// Only the rect is returned. `offsetLeft`/`offsetTop` used to come out of here
/// as a second pair, because the two differ by the containing block's origin and
/// computing them together kept them consistent. They are `boxOrigin` less the
/// offsetParent's padding edge now, which is a different ancestor from the
/// containing block whenever the two disagree -- a table cell is an offsetParent
/// without being positioned, and body is one that Chrome subtracts nothing for.
///
/// The `auto` case no longer comes out 0. Chrome places such a box at its static
/// position and the document-wide pass now records that, so what is left over is
/// a declaration this engine cannot resolve, and a box the pass has not reached.
fn outOfFlowPosition(self: *Element, frame: *Frame, depth: u8) ?DOMRect.Data {
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

    // The containing block is the ancestor's PADDING box, not its border box:
    // measured on a host with `border:5px;padding:10px;width:300px`, Chrome puts
    // `left:3px` at 16 -- 13 for the padding edge plus 3 -- and `right:3px` on a
    // 60px box at 270, which is the padding box's 320 of width from 13 less the
    // two (scratch/h86/expr-h86-offsetparent.js). The engine counted from the
    // border edge and from the content width, which is short by the border on
    // one side and by the padding on the other.
    //
    // The viewport branch below carries no edges, so a fixed box is unaffected.
    const origin: DOMRect.Data = if (containing) |cb| blk: {
        const rect = cb.boundingClientRectValuesAt(frame, depth + 1);
        break :blk .{
            .x = rect.x + cb.getClientLeft(frame),
            .y = rect.y + cb.getClientTop(frame),
        };
    } else .{};

    // `auto` on both edges of an axis means the box keeps its static position --
    // where the flow would have put it. The pass records that for every box it
    // steps over out of flow; it answers null while itself running, and for a
    // box no pass has reached, and 0 is what this engine has always said then.
    //
    // Asked for only when an axis is actually `auto`. `staticPositionOf` lays
    // the whole document out when the table is cold, and a box that declares
    // both edges has no use for the answer -- fetching it unconditionally turns
    // one `getBoundingClientRect` on one absolute box into a document-wide pass.
    const declared_x = self.edgeOffset(frame, "left", "right", box.width + box.padding_x, dims.width);
    const declared_y = self.edgeOffset(frame, "top", "bottom", box.height + box.padding_y, dims.height);
    const static: ?PlacedBox = if (declared_x == null or declared_y == null)
        frame.staticPositionOf(self)
    else
        null;
    const offset_x = declared_x orelse if (static) |s| s.x - origin.x else 0;
    const offset_y = declared_y orelse if (static) |s| s.y - origin.y else 0;

    return .{
        .x = origin.x + offset_x,
        .y = origin.y + offset_y,
    };
}

/// One axis of an out-of-flow box's offset: the near edge if it is declared,
/// otherwise the far edge subtracted from the containing block, otherwise null
/// -- which is the `auto` case the caller answers with the static position.
///
/// Per axis, because Chrome resolves them per axis: `left:3px` with no `top`
/// takes the declared 3 on one and the static position on the other.
fn edgeOffset(
    self: *Element,
    frame: *Frame,
    comptime near: []const u8,
    comptime far: []const u8,
    available: f64,
    own: f64,
) ?f64 {
    if (CSSStyleDeclaration.cascadedComputedValue(self, near, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return px;
    }
    if (CSSStyleDeclaration.cascadedComputedValue(self, far, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return available - px - own;
    }
    return null;
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

/// `clientTop` and `clientLeft` are the width of the top and left border,
/// rounded to an integer -- the offset from the border box's edge to the
/// padding box's.
///
/// They answered a hard-coded 0, with a comment saying the layout does not
/// apply borders. That stopped being true: `borderPx` reads the UA sheet as
/// well as the author cascade, and `offsetWidth` and `getBoundingClientRect`
/// have carried the border for a while. These two accessors were the ones left
/// behind, which is a difference a page sees in one read -- Chrome 151 answers
/// 7 and 11 for `border-top:7px;border-left:11px` where this answered 0 and 0
/// (scratch/b70/expr-client-tl.js, fifteen shapes).
///
/// Each reads its OWN edge: `border-top:6px` alone is `6,0` and
/// `border-left:9px` alone `0,9`, so neither is half of the `border_x` /
/// `border_y` pair the box model carries.
pub fn getClientTop(self: *Element, frame: *Frame) f64 {
    return self.clientBorderEdge(frame, "border-top");
}

pub fn getClientLeft(self: *Element, frame: *Frame) f64 {
    return self.clientBorderEdge(frame, "border-left");
}

/// One border edge as `clientTop`/`clientLeft` report it. Zero for an element
/// with no border box at all -- `display:none` and a non-replaced
/// `display:inline` both answer 0 in Chrome even with a border declared, while
/// `display:table` answers the border, so the test is the box and not the
/// keyword.
fn clientBorderEdge(self: *Element, frame: *Frame, comptime side: []const u8) f64 {
    var visibility_cache: VisibilityCache = .{};
    if (!self.checkVisibilityCached(&visibility_cache, frame)) {
        return 0.0;
    }
    if (CSSStyleDeclaration.isInlineBox(self, frame)) {
        return 0.0;
    }
    return @round(CSSStyleDeclaration.borderEdgePx(self, side, frame));
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
/// The y a page reads for an in-flow box.
///
/// The table from one document-wide pass answers it when it can. The count-based
/// fallback below is what the engine answered before that pass existed -- every
/// element's y being `(preceding nodes) x 5px`, and its x the same number, which
/// is one expression away from a tell. It stays for the cases the table cannot
/// serve: while the pass is running, and for an element the pass did not place.
fn documentPosition(node: *Node, frame: *Frame) f64 {
    if (node.is(Element)) |element| {
        if (frame.positionOf(element)) |point| {
            return point.y + relativeOffset(element, frame, "top", "bottom");
        }
    }
    return calculateDocumentPosition(node);
}

fn siblingPosition(node: *Node, frame: *Frame) f64 {
    if (node.is(Element)) |element| {
        if (frame.positionOf(element)) |point| {
            return point.x + relativeOffset(element, frame, "left", "right");
        }
    }
    return calculateSiblingPosition(node);
}

/// What `position: relative` moves a box by on one axis.
///
/// A relative box keeps the space the flow gave it -- which is why the pass
/// places it at its static position and this is added afterwards rather than
/// folded into the walk. Chrome puts the shape in
/// `scratch/b74/expr-inflow-position-matrix.js` at `d=7,39` where its static
/// position is `0,30` and it declares `left:7px; top:9px`: a plain sum.
///
/// The near edge wins and the far edge is its negation, per
/// css-position-3 §3.2 -- `right` alone moves the box left. Unlike
/// `edgeOffset`, neither is resolved against the containing block, because a
/// relative offset is not a placement.
fn relativeOffset(
    self: *Element,
    frame: *Frame,
    comptime near: []const u8,
    comptime far: []const u8,
) f64 {
    const position = CSSStyleDeclaration.cascadedComputedValue(self, "position", frame) orelse return 0;
    if (!std.ascii.eqlIgnoreCase(position, "relative")) {
        return 0;
    }
    if (CSSStyleDeclaration.cascadedComputedValue(self, near, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return px;
    }
    if (CSSStyleDeclaration.cascadedComputedValue(self, far, frame)) |declared| {
        if (CSS.parseDimensionViewport(declared, frame)) |px| return -px;
    }
    return 0;
}

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

pub fn getElementsByTagName(self: *Element, tag_name: []const u8, frame: *Frame) !*collections.HTMLCollection {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Element, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !*collections.HTMLCollection {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Element, class_name: []const u8, frame: *Frame) !*collections.HTMLCollection {
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
    const y = documentPosition(self.asNode(), frame);
    const scroll_y = frame.window.getScrollY();
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
    const y = documentPosition(self.asNode(), frame);
    frame.window.scrollTo(.{ .x = 0 }, @max(0, y), frame) catch {};
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        // Alphabetical: a dictionary's members are read in that order and a
        // page handing a Proxy in sees the sequence.
        behavior: []const u8 = "",
        left: ?i32 = null,
        top: ?i32 = null,
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
