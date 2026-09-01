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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Window = @import("Window.zig");
const URL = @import("../URL.zig");
const idna = @import("../../sys/idna.zig");
const public_suffix_list = @import("../../data/public_suffix_list.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const Parser = @import("../parser/Parser.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const TreeWalker = @import("TreeWalker.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const DOMException = @import("DOMException.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");
const FontFaceSet = @import("css/FontFaceSet.zig");
const Selection = @import("Selection.zig");
const services = @import("document/services.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const XPathResult = @import("XPathResult.zig");
const XPathExpression = @import("XPathExpression.zig");

pub const XMLDocument = @import("XMLDocument.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");

const log = lp.log;
const String = lp.String;
const handler_property = @import("handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const Document = @This();

pub const Proto = Node;

_type: Type,
_proto: *Node,
_frame: ?*Frame = null,
_url: ?[:0]const u8 = null, // URL for documents created via DOMImplementation (about:blank)
// content type override for documents created via DOMImplementation.createDocument
_content_type: ?[]const u8 = null,
// encoding override: documents synthesized by script (createHTMLDocument,
// createDocument) are UTF-8 regardless of the frame's encoding
_charset: ?[]const u8 = null,
_ready_state: ReadyState = .loading,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,
// Track IDs that were removed from the map - they might have duplicates in the tree
_removed_ids: std.StringHashMapUnmanaged(void) = .empty,
// The document's named objects (`document.myForm`), rebuilt when the DOM
// version moves. Cached because the handler behind them answers every name
// nothing else answers, and walking the tree per read cost 0.26ms on a
// 4000-element page -- 88x what the same reads cost before the handler existed
// (scratch/b79/named-cost.mjs).
_named_objects: std.ArrayListUnmanaged(NamedObjectEntry) = .empty,
_named_objects_version: ?usize = null,
// The parser's half of the same key -- see Page.parser_dom_version.
_named_objects_parser_version: ?usize = null,
// Named objects a script has deleted. `delete document.myForm` takes the name
// away for good in Chrome -- the element stays in the tree, the property does
// not come back, not even after a DOM change (measured, scratch/b79/edges.mjs)
// -- and only a Document behaves that way; a form keeps its deleted names.
_named_objects_deleted: std.StringHashMapUnmanaged(void) = .empty,
_active_element: ?*Element = null,
_style_sheets: ?*StyleSheetList = null,
// The cascade's own list; see cascadeStyleSheets.
_cascade_sheets: ?*StyleSheetList = null,
_implementation: ?*DOMImplementation = null,
_fonts: ?*FontFaceSet = null,
_write_insertion_point: ?*Node = null,
_script_created_parser: ?Parser.Streaming = null,
_close_requested: bool = false,
_adopted_style_sheets: ?js.Object.Global = null,
_selection: Selection = .{ ._rc = .init(1) },
// Ordered stack of currently-showing popovers
_open_popovers: std.ArrayList(*Element) = .empty,

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#throw-on-dynamic-markup-insertion-counter
// Incremented during custom element reactions when parsing. When > 0,
// document.open/close/write/writeln must throw InvalidStateError.
_throw_on_dynamic_markup_insertion_counter: u32 = 0,

_design_mode: bool = false,
// Chrome keeps whatever a script assigns to these, even on an HTML document
// where they start out null/false.
_xml_version: ?[]const u8 = null,
_xml_standalone: bool = false,
_timeline: ?*services.DocumentTimeline = null,
_feature_policy: ?*services.FeaturePolicy = null,
_fragment_directive: ?*services.FragmentDirective = null,

pub const Type = union(enum) {
    generic,
    html: *HTMLDocument,
    xml: *XMLDocument,
};

pub fn is(self: *Document, comptime T: type) ?*T {
    switch (self._type) {
        .html => |html| {
            if (T == HTMLDocument) {
                return html;
            }
        },
        .xml => |xml| {
            if (T == XMLDocument) {
                return xml;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Document, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Document) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Document) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getURL(self: *const Document, frame: *const Frame) [:0]const u8 {
    return self._url orelse (self._frame orelse frame).url;
}

pub fn getLocation(self: *const Document) ?*Location {
    if (self._type != .html) return null;
    const doc_frame = self._frame orelse return null;
    return doc_frame.window._location;
}

pub fn setLocation(self: *Document, url: [:0]const u8) !void {
    if (self._type != .html) return;
    const frame = self._frame orelse return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = frame });
}

// Approximation of quirks mode: an HTML document without a doctype is in quirks mode.
pub fn isQuirksMode(self: *const Document) bool {
    if (self._type != .html) {
        return false;
    }
    var it = self._proto.childrenIterator();
    while (it.next()) |child| {
        if (child._type == .document_type) {
            return false;
        }
    }
    return true;
}

pub fn getCompatMode(self: *const Document) []const u8 {
    return if (self.isQuirksMode()) "BackCompat" else "CSS1Compat";
}

// document.lastModified: the response's Last-Modified header in local time,
// "MM/DD/YYYY hh:mm:ss", defaulting to the current time.
pub fn getLastModified(self: *const Document, frame: *Frame) ![]const u8 {
    const dt = @import("../../datetime.zig");

    const timestamp = blk: {
        if (self._frame) |owner| {
            for (owner._http_headers.items) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                    if (dt.DateTime.parse(header.value, .rfc822)) |parsed| {
                        break :blk parsed.unix(.seconds);
                    } else |_| {}
                    break;
                }
            }
        }
        // localTime is signed: a parsed Last-Modified can predate the epoch
        break :blk @as(i64, @intCast(lp.datetime.timestamp(.real)));
    };

    const tm = try dt.localTime(timestamp);
    return std.fmt.allocPrint(frame.local_arena, "{d:0>2}/{d:0>2}/{d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        tm.tm_year + 1900,
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    });
}

pub fn getReferrer(self: *const Document) []const u8 {
    const frame = self._frame orelse return "";
    return frame._referrer orelse "";
}

pub fn getCharset(self: *const Document) []const u8 {
    if (self._charset) |charset| {
        return charset;
    }
    const doc_frame = self._frame orelse return "UTF-8";
    return doc_frame.charset;
}

pub fn getContentType(self: *const Document) []const u8 {
    if (self._content_type) |content_type| {
        return content_type;
    }
    return switch (self._type) {
        .html => "text/html",
        .xml => "application/xml",
        .generic => "application/xml",
    };
}

pub fn getDomain(self: *const Document, frame: *const Frame) []const u8 {
    const doc_frame = self._frame orelse frame;

    // When document.domain has been set, the effective domain is encoded in
    // the origin key with a leading '!' marker. The key is a "!scheme://host"
    // serialization with the port already dropped, so the host *is* the
    // effective domain.
    const key = doc_frame.js.origin.key;
    if (key.len != 0 and key[0] == '!') {
        return URL.getHost(key[1..]);
    }

    // Derive from the origin, not the URL: an about:blank child inherits the
    // parent origin while keeping url == "about:blank". Opaque origin => "".
    const origin = doc_frame.origin orelse return "";
    return URL.getOriginHostname(origin);
}

pub fn setDomain(self: *Document, value: []const u8) !void {
    // e.g. (new Document().domain = '')
    const doc_frame = self._frame orelse return error.SecurityError;
    const origin = doc_frame.origin orelse return error.SecurityError;

    const arena = doc_frame.local_arena;
    const requested = if (idna.needsAscii(value)) try idna.toAscii(arena, value) else value;

    // Validate against the current effective domain. Once relaxed,
    // document.domain can only broaden further.
    //
    // Blink writes two different details behind the same lead-in and both quote
    // the value back. The empty string gets its own sentence rather than falling
    // through to the suffix one, and a public suffix ('com') gets the suffix
    // sentence like any other non-match -- there is no separate
    // top-level-domain wording. Measured on Chrome 151 from a 127.0.0.1 page.
    const prefix = "Failed to set the 'domain' property on 'Document': ";
    const base = self.getDomain(doc_frame);
    if (value.len == 0) {
        return doc_frame.js.fail(error.SecurityError, prefix ++ "'' is an empty domain.");
    }
    if (isRelaxableTo(base, requested) == false) {
        // call_arena, not the local one: handleError reads the message after
        // this frame is gone, and local_arena is reset before it gets there --
        // which showed up as a SecurityError carrying a run of blanks.
        return doc_frame.js.fail(error.SecurityError, try std.fmt.allocPrint(
            doc_frame.call_arena,
            prefix ++ "'{s}' is not a suffix of '{s}'.",
            .{ value, base },
        ));
    }

    // When the domain is explicitly set, it only matches other explicitly set
    // domains. We do this by prepending a '!' to the origin, so that it can
    // only ever match another explicitly set domain.
    // The scheme is preserved (http and https must never collide) and the
    // port is dropped, per spec.
    const scheme_end = (std.mem.indexOf(u8, origin, "://") orelse return error.SecurityError) + 3;
    const key = try std.mem.concat(arena, u8, &.{ "!", origin[0..scheme_end], requested });
    try doc_frame.js.setOrigin(key);
}

// A cookie-averse document (no browsing context: createHTMLDocument,
// DOMParser, XHR documents) reads cookies as the empty string and ignores
// writes.
fn isCookieAverse(self: *const Document, frame: *const Frame) bool {
    const doc_frame = self._frame orelse return true;
    return doc_frame.document != self and frame.document != self;
}

pub fn getCookie(self: *Document, frame: *Frame) ![]const u8 {
    if (self.isCookieAverse(frame)) {
        return "";
    }
    var aw: std.Io.Writer.Allocating = .init(frame.local_arena);
    try frame._session.cookie_jar.forRequest(frame.url, &aw.writer, .{
        .is_http = false,
        .is_navigation = true,
    });
    return aw.written();
}

pub fn setCookie(self: *Document, cookie_str: []const u8, frame: *Frame) ![]const u8 {
    if (self.isCookieAverse(frame)) {
        return cookie_str;
    }
    // we use the cookie jar's allocator to parse the cookie because it
    // outlives the frame's arena.
    const Cookie = @import("storage/Cookie.zig");
    const c = Cookie.parse(frame._session.cookie_jar.allocator, frame.url, cookie_str) catch {
        // Invalid cookies should be silently ignored, not throw errors
        return "";
    };
    if (c.http_only) {
        c.deinit();
        return ""; // HttpOnly cookies cannot be set from JS
    }
    try frame._session.cookie_jar.add(c, lp.datetime.timestamp(.real), false);
    return cookie_str;
}

// Returns true if the requested domain is valid for the given host
fn isRelaxableTo(host: []const u8, requested: []const u8) bool {
    if (requested.len == 0) {
        return false;
    }

    // Pure opt-in: relaxing to your own host is always allowed (and it's the
    // only valid value for IPs)
    if (std.mem.eql(u8, host, requested)) {
        return true;
    }

    // request must be a subset of host, so it must be smaller
    if (host.len <= requested.len) {
        return false;
    }

    if (host[host.len - requested.len - 1] != '.') {
        return false;
    }

    if (std.mem.endsWith(u8, host, requested) == false) {
        return false;
    }

    // it can't be a bare TLD, "com"
    if (std.mem.indexOfScalar(u8, requested, '.') == null) {
        return false;
    }

    // and it can't be a public suffix (e.g. "gov.uk")
    return public_suffix_list.lookup(requested) == false;
}

const CreateElementOptions = struct {
    is: ?[]const u8 = null,
};

pub fn createElement(self: *Document, name: []const u8, options_: ?CreateElementOptions, frame: *Frame) !*Element {
    try validateElementName(name, frame);
    const ns: Element.Namespace, const normalized_name = blk: {
        if (self._type == .html) {
            break :blk .{ .html, std.ascii.lowerString(&frame.buf, name) };
        }
        // Generic and XML documents create elements with null namespace
        break :blk .{ .null, name };
    };
    // HTML documents are case-insensitive - lowercase the tag name

    const node = try Frame.node_factory.createElementNS(frame, ns, normalized_name, null);
    const element = node.as(Element);

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }

    const options = options_ orelse return element;
    if (options.is) |is_value| {
        try element.setAttribute(comptime .wrap("is"), .wrap(is_value), frame);
        try Element.Html.Custom.checkAndAttachBuiltIn(element, frame);
    }

    return element;
}

pub fn createElementNS(self: *Document, namespace: ?[]const u8, name: []const u8, frame: *Frame) !*Element {
    _ = try validateAndExtract(namespace, name, .element, "createElementNS", "Document", frame);
    const ns = Element.Namespace.parse(namespace);
    // Per spec, createElementNS does NOT lowercase (unlike createElement).
    const node = try Frame.node_factory.createElementNS(frame, ns, name, null);

    // Store original URI for unknown namespaces so lookupNamespaceURI can return it
    if (ns == .unknown) {
        if (namespace) |uri| {
            const duped = try frame.dupeString(uri);
            try frame._element_namespace_uris.put(frame.arena, node.as(Element), duped);
        }
    }

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node.as(Element);
}

pub fn createAttribute(_: *const Document, name: String.Global, frame: *Frame) !?*Element.Attribute {
    try validateLocalName(name.str, "createAttribute", frame);
    return frame._factory.node(Element.Attribute{
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn createAttributeNS(_: *const Document, namespace: []const u8, name: String.Global, frame: *Frame) !?*Element.Attribute {
    if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml") == false) {
        log.warn(.not_implemented, "document.createAttributeNS", .{ .namespace = namespace });
    }

    try validateLocalName(name.str, "createAttributeNS", frame);
    return frame._factory.node(Element.Attribute{
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

/// The Document-side wording for the attribute-name rule: same set of rejected
/// characters as setAttribute, but Blink calls the input a localName here and
/// does not name the character. Measured on Chrome 151.
fn validateLocalName(name: String, comptime op: []const u8, frame: *Frame) !void {
    const name_str = name.str();
    if (Element.Attribute.checkAttributeName(name_str) == null) {
        return;
    }
    return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
        frame.call_arena,
        "Failed to execute '" ++ op ++ "' on 'Document': The localName provided ('{s}') contains an invalid character.",
        .{name_str},
    ));
}

pub fn getElementById(self: *Document, id: []const u8, frame: *Frame) ?*Element {
    if (id.len == 0) {
        return null;
    }

    if (self._elements_by_id.get(id)) |element| {
        return element;
    }

    //ID was removed but might have duplicates
    if (self._removed_ids.remove(id)) {
        var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
        while (tw.next()) |el| {
            const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
            if (std.mem.eql(u8, element_id, id)) {
                // we ignore this error to keep getElementById easy to call
                // if it really failed, then we're out of memory and nothing's
                // going to work like it should anyways.
                const owned_id = frame.dupeString(id) catch return null;
                self._elements_by_id.put(frame.arena, owned_id, el) catch return null;
                return el;
            }
        }
    }

    return null;
}

pub fn getElementsByTagName(self: *Document, tag_name: []const u8, frame: *Frame) !*collections.HTMLCollection {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Document, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !*collections.HTMLCollection {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Document, class_name: []const u8, frame: *Frame) !*collections.HTMLCollection {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn getElementsByName(self: *Document, name: []const u8, frame: *Frame) !*collections.NodeList {
    const root = self.asNode();
    const key: collections.identity.Key = .{ .root = root, .kind = .by_name, .name = name };
    if (collections.identity.find(frame, collections.NodeList, key)) |cached| {
        return cached;
    }
    const filter = try frame.arena.dupe(u8, name);
    return collections.identity.put(frame, key, try frame._factory.create(collections.NodeList{
        ._data = .{ .name = collections.NodeLive(.name).init(root, filter, frame) },
    }));
}

pub fn getChildren(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .children, .name = "" },
        collections.NodeLive(.child_elements).init(root, {}, frame).htmlCollectionValue(),
    );
}

/// What `document.myForm` reaches. An iframe's name reaches its window rather
/// than the element, which is why this is a union and not an `*Element`.
pub const NamedObject = union(enum) {
    element: *Element,
    window: *Window,
    cross_origin: *Window.CrossOriginWindow,
};

/// Which of an element's two attributes name it on the document.
///
/// Five element kinds earn a name from `name` -- embed, form, iframe, img,
/// object; an `object` earns one from `id` as well; and an `img` earns one
/// from `id` only when it also carries a non-empty `name`. Nothing else in the
/// tree contributes, however it is labelled: a div with an id, a select with a
/// name and an anchor with a name are all invisible here (measured on Chrome
/// 151, scratch/b79/named-objects.mjs).
/// https://html.spec.whatwg.org/multipage/dom.html#dom-document-nameditem
fn nameSources(element: *Element) struct { id: bool, name: bool } {
    if (element._namespace != .html) {
        return .{ .id = false, .name = false };
    }
    const Html = Element.Html;
    if (element.is(Html.Object) != null) {
        return .{ .id = true, .name = true };
    }
    if (element.is(Html.Image) != null) {
        const named = if (element.getAttributeSafe(comptime .wrap("name"))) |n| n.len > 0 else false;
        return .{ .id = named, .name = true };
    }
    if (element.is(Html.Form) != null or element.is(Html.Embed) != null or element.is(Html.IFrame) != null) {
        return .{ .id = false, .name = true };
    }
    return .{ .id = false, .name = false };
}

fn attributeIs(element: *Element, comptime attribute: String, value: []const u8) bool {
    const have = element.getAttributeSafe(attribute) orelse return false;
    return have.len > 0 and std.mem.eql(u8, have, value);
}

const NamedObjectEntry = struct {
    name: []const u8,
    element: *Element,
};

/// Every name the document answers to and what each one names, in tree order,
/// an element's id before its name when it contributes both, ignoring later
/// duplicates.
///
/// The names are borrowed from the attributes they came from and the elements
/// are held raw, which is safe for exactly as long as the cache is: every
/// mutation that could invalidate either -- an attribute written, a node
/// inserted or removed -- moves the page's DOM version, and the whole list is
/// rebuilt when it has.
fn namedObjectEntries(self: *Document, frame: *Frame) ![]const NamedObjectEntry {
    const version = frame._page.dom_version;
    // The parser does not move the DOM version -- only the DOM APIs do -- so a
    // list built while the document is still being parsed would never see the
    // rest of the page. An inline script that reads one unknown name early is
    // enough to trigger that, and it left every named object of the document
    // missing for the whole run (`document/named_objects.html`'s first block).
    // The parser's own counter is what closes that; walking every time instead
    // costs 1249ms for 2000 parse-time `document.body` reads
    // (scratch/b80/parse-cost.mjs), and the handler is masking, so every
    // property read on `document` is one of those.
    const parser_version = frame._page.parser_dom_version;
    if (self._named_objects_version == version and self._named_objects_parser_version == parser_version) {
        return self._named_objects.items;
    }

    const arena = frame.arena;
    var entries = &self._named_objects;
    entries.clearRetainingCapacity();

    var tw = TreeWalker.Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |element| {
        const sources = nameSources(element);
        if (sources.id) {
            if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
                if (id.len > 0 and !containsName(entries.items, id)) {
                    try entries.append(arena, .{ .name = id, .element = element });
                }
            }
        }
        if (sources.name) {
            if (element.getAttributeSafe(comptime .wrap("name"))) |name| {
                if (name.len > 0 and !containsName(entries.items, name)) {
                    try entries.append(arena, .{ .name = name, .element = element });
                }
            }
        }
    }

    self._named_objects_version = version;
    self._named_objects_parser_version = parser_version;
    return entries.items;
}

/// The first element in tree order that this name names, as the value the name
/// reads back as.
pub fn namedObject(self: *Document, name: []const u8, frame: *Frame) ?NamedObject {
    if (name.len == 0) {
        return null;
    }

    if (self.namedObjectDeleted(name)) {
        return null;
    }

    const entries = self.namedObjectEntries(frame) catch return null;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) {
            continue;
        }
        if (entry.element.is(Element.Html.IFrame)) |iframe| {
            // A frame with no window of its own names nothing.
            const access = iframe.getContentWindow(frame) orelse return null;
            return switch (access) {
                .window => |window| .{ .window = window },
                .cross_origin => |window| .{ .cross_origin = window },
            };
        }
        return .{ .element = entry.element };
    }
    return null;
}

/// What `window.<name>` reaches, which is the document's named objects plus
/// the id of *any* element -- a window is named by an id a document is not
/// (measured on Chrome 151, scratch/b79/window-names.mjs: `window.someDivId`
/// is the div, `document.someDivId` is undefined). The document's list already
/// answers a frame's name with its window, which is the one case where a name
/// and an id reach different things.
pub fn windowNamedObject(self: *Document, name: []const u8, frame: *Frame) ?NamedObject {
    if (self.namedObject(name, frame)) |named| {
        return named;
    }
    if (self.getElementById(name, frame)) |element| {
        return .{ .element = element };
    }
    return null;
}

/// The names alone, for the enumerator behind getOwnPropertyNames.
pub fn namedObjects(self: *Document, frame: *Frame) ![]const NamedObjectEntry {
    return self.namedObjectEntries(frame);
}

/// Whether a script has deleted this name off the document.
pub fn namedObjectDeleted(self: *const Document, name: []const u8) bool {
    if (self._named_objects_deleted.count() == 0) {
        return false;
    }
    return self._named_objects_deleted.contains(name);
}

pub fn deleteNamedObject(self: *Document, name: []const u8, frame: *Frame) !void {
    return self._named_objects_deleted.put(frame.arena, try frame.dupeString(name), {});
}

fn containsName(entries: []const NamedObjectEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

/// The four callbacks behind `document.myForm`, generated for whichever
/// concrete document interface the instance belongs to. V8 does not hand a
/// derived instance template its base's named handler -- an interceptor
/// declared on Document alone never fires for the HTMLDocument that every page
/// has -- so each interface installs its own, and they all land here.
pub fn NamedObjectAccess(comptime T: type) type {
    return struct {
        fn document(self: *T) *Document {
            return if (comptime T == Document) self else self.asDocument();
        }

        /// The names a document answers itself, which a named object must not
        /// shadow. `[LegacyOverrideBuiltIns]` puts named properties *before*
        /// the prototype chain and *after* the object's own properties, and
        /// V8 has no third setting: a masking interceptor is consulted before
        /// the own properties too, so the handler has to answer this itself.
        /// There is no HasRealNamedProperty in the vendored V8 C API to ask
        /// with, and asking through `Object.Has` would re-enter this handler.
        ///
        /// `location` is the whole list -- the only [LegacyUnforgeable] member
        /// a Document has -- and the comptime check below keeps that true if
        /// somebody adds a second one.
        ///
        /// Measured on Chrome 151 (scratch/b80/.q3.js): with a `<form
        /// name="location">` in the tree, `document.location` is still the
        /// Location and its descriptor is still the own `accessor e=true
        /// c=false`, while `document.title`, `document.getElementById` and
        /// eleven others become the form. The name is still *listed* either
        /// way, because it is a supported property name whether or not it wins
        /// the read -- so this filter is not in `namedObjects`.
        ///
        /// What it does not cover: a page that assigns its own property and
        /// then names an element after it (`document.x = 1` with a `<form
        /// name="x">`). Chrome keeps the 1; this answers the form.
        fn shadowedByOwn(name: []const u8) bool {
            return std.mem.eql(u8, name, "location");
        }

        comptime {
            var unforgeables: usize = 0;
            for (@typeInfo(Document.JsApi).@"struct".decls) |d| {
                const value = @field(Document.JsApi, d.name);
                const V = @TypeOf(value);
                if (@typeInfo(V) == .@"struct" and @hasField(V, "unforgeable") and value.unforgeable) {
                    unforgeables += 1;
                }
            }
            if (unforgeables != 1) {
                @compileError("Document gained an unforgeable member; add it to " ++
                    "NamedObjectAccess.shadowedByOwn or a named object will shadow it");
            }
        }

        pub fn get(self: *T, name: []const u8, frame: *Frame) !NamedObject {
            if (shadowedByOwn(name)) {
                return error.NotHandled;
            }
            return document(self).namedObject(name, frame) orelse error.NotHandled;
        }

        pub fn names(self: *T, frame: *Frame) !js.Array {
            const doc = document(self);
            const supported = try doc.namedObjects(frame);

            var live: u32 = 0;
            for (supported) |entry| {
                if (!doc.namedObjectDeleted(entry.name)) live += 1;
            }

            var arr = frame.js.local.?.newArray(live);
            var i: u32 = 0;
            for (supported) |entry| {
                if (doc.namedObjectDeleted(entry.name)) {
                    continue;
                }
                _ = try arr.set(i, entry.name, .{});
                i += 1;
            }
            return arr;
        }

        /// A deleted name is gone for good, which is what Chrome does with it:
        /// the element stays, the property does not come back.
        pub fn delete(self: *T, name: []const u8, frame: *Frame) !bool {
            if (shadowedByOwn(name)) {
                return error.NotHandled;
            }
            const doc = document(self);
            if (doc.namedObject(name, frame) == null) {
                return error.NotHandled;
            }
            try doc.deleteNamedObject(name, frame);
            return true;
        }

        /// Enumerable, configurable and writable: unlike a collection's named
        /// entries these look like ordinary data properties, so they come out
        /// of Object.keys as well as getOwnPropertyNames (measured on Chrome
        /// 151, scratch/b79/named-objects.mjs).
        pub fn query(self: *T, name: []const u8, frame: *Frame) !u32 {
            if (shadowedByOwn(name)) {
                return error.NotHandled;
            }
            if (document(self).namedObject(name, frame) != null) {
                return js.v8.None;
            }
            return error.NotHandled;
        }

        /// Writable in the descriptor and unassignable all the same: there is
        /// no named setter, so the define that [[Set]] falls back to is
        /// refused -- silently outside strict mode, which is what Chrome does
        /// with it.
        pub fn define(self: *T, name: []const u8, frame: *Frame) !bool {
            if (shadowedByOwn(name)) {
                return error.NotHandled;
            }
            if (document(self).namedObject(name, frame) != null) {
                return false;
            }
            return error.NotHandled;
        }
    };
}

pub fn getDocumentElement(self: *Document) ?*Element {
    var child = self.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            return el;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getSelection(self: *Document) *Selection {
    return &self._selection;
}

pub fn querySelector(self: *Document, input: String, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), input.str(), frame) catch |err|
        Selector.failToDOM(err, input.str(), "querySelector", "Document", frame);
}

pub fn querySelectorAll(self: *Document, input: String, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input.str(), frame) catch |err|
        Selector.failToDOM(err, input.str(), "querySelectorAll", "Document", frame);
}

pub fn getImplementation(self: *Document, frame: *Frame) !*DOMImplementation {
    if (self._implementation) |impl| return impl;
    const impl = try frame._factory.create(DOMImplementation{ ._document = self });
    self._implementation = impl;
    return impl;
}

pub fn createDocumentFragment(self: *Document, frame: *Frame) !*Node.DocumentFragment {
    const frag = try Node.DocumentFragment.init(frame);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(frag.asNode(), self);
    }
    return frag;
}

pub fn createComment(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createComment(frame, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createTextNode(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createTextNode(frame, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createCDATASection(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = switch (self._type) {
        .html => return error.NotSupported, // cannot create a CDataSection in an HTMLDocument
        .xml => try Frame.node_factory.createCDATASection(frame, data),
        .generic => try Frame.node_factory.createCDATASection(frame, data),
    };
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createProcessingInstruction(self: *Document, target: []const u8, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createProcessingInstruction(frame, target, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

const Range = @import("Range.zig");
pub fn createRange(self: *Document, frame: *Frame) !*Range {
    return Range.initIn(self.asNode(), frame);
}

/// Chrome names the offending type in the refusal rather than answering the
/// bare "operation is not supported" a plain error.NotSupported produces
/// (measured on a headed Chrome 150 with `createEvent('MutationEvent')`,
/// win63-chrome.json). The original casing is echoed, not the normalised one.
fn invalidEventType(event_type: []const u8, frame: *Frame) anyerror {
    const local = frame.js.local orelse return error.NotSupported;
    const message = std.fmt.allocPrint(
        frame.local_arena,
        "Failed to execute 'createEvent' on 'Document': The provided event type ('{s}') is invalid.",
        .{event_type},
    ) catch return error.NotSupported;
    const value = local.zigValueToJs(DOMException.init(message, "NotSupportedError"), .{}) catch {
        return error.JsException;
    };
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

pub fn createEvent(_: *const Document, event_type: []const u8, frame: *Frame) !*@import("Event.zig") {
    const Event = @import("Event.zig");
    if (event_type.len > 100) {
        return invalidEventType(event_type, frame);
    }
    const normalized = std.ascii.lowerString(&frame.buf, event_type);

    const event: *Event = blk: {
        if (std.mem.eql(u8, normalized, "event") or std.mem.eql(u8, normalized, "events") or std.mem.eql(u8, normalized, "htmlevents") or std.mem.eql(u8, normalized, "svgevents")) {
            break :blk try Event.init("", null, frame._page);
        }

        if (std.mem.eql(u8, normalized, "customevent")) {
            const CustomEvent = @import("event/CustomEvent.zig");
            break :blk (try CustomEvent.init("", null, frame._page)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "keyboardevent")) {
            const KeyboardEvent = @import("event/KeyboardEvent.zig");
            break :blk (try KeyboardEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "inputevent")) {
            const InputEvent = @import("event/InputEvent.zig");
            break :blk (try InputEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "mouseevent") or std.mem.eql(u8, normalized, "mouseevents")) {
            const MouseEvent = @import("event/MouseEvent.zig");
            break :blk (try MouseEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "dragevent")) {
            const DragEvent = @import("event/DragEvent.zig");
            break :blk (try DragEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "messageevent")) {
            const MessageEvent = @import("event/MessageEvent.zig");
            break :blk (try MessageEvent.init("", null, frame._page)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "hashchangeevent")) {
            const HashChangeEvent = @import("event/HashChangeEvent.zig");
            break :blk (try HashChangeEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "uievent") or std.mem.eql(u8, normalized, "uievents")) {
            const UIEvent = @import("event/UIEvent.zig");
            break :blk (try UIEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "focusevent")) {
            const FocusEvent = @import("event/FocusEvent.zig");
            break :blk (try FocusEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "textevent")) {
            const TextEvent = @import("event/TextEvent.zig");
            break :blk (try TextEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "compositionevent")) {
            const CompositionEvent = @import("event/CompositionEvent.zig");
            break :blk (try CompositionEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "beforeunloadevent")) {
            const BeforeUnloadEvent = @import("event/BeforeUnloadEvent.zig");
            break :blk (try BeforeUnloadEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "devicemotionevent")) {
            const DeviceMotionEvent = @import("event/DeviceMotionEvent.zig");
            break :blk (try DeviceMotionEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "deviceorientationevent")) {
            const DeviceOrientationEvent = @import("event/DeviceOrientationEvent.zig");
            break :blk (try DeviceOrientationEvent.init("", null, frame)).asEvent();
        }

        if (std.mem.eql(u8, normalized, "storageevent")) {
            const StorageEvent = @import("event/StorageEvent.zig");
            break :blk (try StorageEvent.init("", null, frame)).asEvent();
        }

        // No "touchevent" branch: the legacy factory only carries a type when
        // the build has touch event feature detection on, and a desktop Chrome
        // does not (maxTouchPoints 0, no window.ontouchstart). The TouchEvent
        // constructor still exists there — createEvent is the one door that
        // refuses the name, so it answers the same invalid-type refusal as any
        // other unknown string.
        return invalidEventType(event_type, frame);
    };

    // createEvent returns an uninitialized event: dispatching it before one
    // of the init*Event calls throws an InvalidStateError.
    event._initialized = false;
    return event;
}

pub fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMTreeWalker.FilterOpts, frame: *Frame) !*DOMTreeWalker {
    return DOMTreeWalker.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMNodeIterator.FilterOpts, frame: *Frame) !*DOMNodeIterator {
    return DOMNodeIterator.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn evaluate(
    self: *Document,
    expression: []const u8,
    context_node: ?*Node,
    resolver: ?js.Value,
    result_type: ?u16,
    result: ?*XPathResult,
    frame: *Frame,
) !*XPathResult {
    // resolver/result are no-ops in HTML mode (decision #2).
    // Null/missing context_node falls back to the document — matches the
    // polyfill (decision #2). Firefox throws TypeError on a *missing*
    // arg, but the bridge can't distinguish "missing" from "explicit
    // null" here, so polyfill parity wins for the ambiguity.
    _ = resolver;
    _ = result;
    return XPathResult.fromExpression(
        expression,
        context_node orelse self.asNode(),
        result_type orelse XPathResult.ANY_TYPE,
        frame,
    );
}

pub fn createExpression(
    _: *const Document,
    expression: []const u8,
    resolver: ?js.Value,
    frame: *Frame,
) !*XPathExpression {
    _ = resolver;
    return XPathExpression.init(expression, frame);
}

pub fn createNSResolver(_: *const Document, node: *Node) ?*Node {
    return node;
}

fn whatToShow(value_: ?js.Value) !u32 {
    const value = value_ orelse return 4294967295; // show all when undefined
    if (value.isUndefined()) {
        // undefined explicitly passed
        return 4294967295;
    }

    if (value.isNull()) {
        return 0;
    }

    return value.toZig(u32);
}

pub fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

pub fn getActiveElement(self: *Document) ?*Element {
    // While the focus chain runs through a child frame, this document's active
    // element is the iframe hosting it, whatever this document last focused for
    // itself. It stays the iframe after the element inside the child is
    // blurred -- blur leaves the chain where it is -- and goes back to real
    // content the moment top-level content is focused, which moves the chain.
    // Measured on Chrome 151, tools/fingerprint/probes/expr-b85-active-element.js.
    if (self._frame) |doc_frame| {
        var current: ?*Frame = doc_frame._page.focused_frame;
        while (current) |f| {
            const parent = f.parent orelse break;
            if (parent == doc_frame) {
                if (f.iframe) |host| return host.asElement();
                break;
            }
            current = parent;
        }
    }

    if (self._active_element) |el| {
        // A focused element inside a shadow tree is exposed as its outermost
        // host; one in a detached tree isn't exposed at all.
        var candidate = el;
        while (candidate.asNode().containingShadowRoot()) |shadow| {
            candidate = shadow._host;
        }
        if (candidate.asNode().getRootNode(.{}) == self.asNode()) {
            return candidate;
        }
    }

    // Default to body if it exists
    if (self.is(HTMLDocument) != null) {
        if (self.getBody()) |body| {
            return body.asElement();
        }
    }

    // Fallback to document element
    return self.getDocumentElement();
}

pub fn getStyleSheets(self: *Document, frame: *Frame) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._style_sheets = sheets;
    return sheets;
}

/// Every sheet the cascade is built from, in the order they were registered --
/// including the ones living in a shadow tree, which `document.styleSheets`
/// must not show. Chrome keeps a shadow tree's sheet only in that root's list
/// (probes/expr-shadow-stylesheet-scope.js), and we used to leave it in the
/// document's as well because this was the same list: the widget's rule text
/// then came back through the document a second time, which is why our span of
/// it in the Cloudflare payload was exactly twice Chrome's. The cascade still
/// needs all of them, so it gets its own list rather than losing the sheets.
pub fn cascadeStyleSheets(self: *Document, frame: *Frame) !*StyleSheetList {
    if (self._cascade_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._cascade_sheets = sheets;
    return sheets;
}

pub fn getFonts(self: *Document, exec: *const js.Execution) !*FontFaceSet {
    if (self._fonts) |fonts| {
        return fonts;
    }
    const fonts = try FontFaceSet.init(exec);
    fonts.acquireRef();
    self._fonts = fonts;
    return fonts;
}

pub fn adoptNode(self: *Document, node: *Node, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }
    if (node.is(Node.ShadowRoot) != null) {
        return error.HierarchyError;
    }

    const old_owner = node.ownerDocument(frame) orelse frame.document;

    if (node._parent) |parent| {
        frame.removeNode(parent, node, .{ .reconnect_to = null });
    }

    if (old_owner != self) {
        try frame.adoptNodeTree(node, old_owner, self);
    }

    return node;
}

pub fn importNode(_: *const Document, node: *Node, deep_: ?bool, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    return node.cloneNode(deep_, frame);
}

pub fn append(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    const parent = self.asNode();
    frame.domChanged();

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // DocumentFragments are special - append all their children
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.appendAllChildren(child, parent);
            continue;
        }

        var previous_root: ?*Node = null;
        if (child._parent) |previous_parent| {
            previous_root = child.getRootNode(.{});
            frame.removeNode(previous_parent, child, .{ .reconnect_to = parent });
        }
        try frame.appendNode(parent, child, .{ .previous_root = previous_root });
    }
}

pub fn prepend(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    const parent = self.asNode();
    frame.domChanged();

    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(frame);

        // DocumentFragments are special - need to insert all their children
        if (child.is(Node.DocumentFragment)) |frag| {
            const first_child = parent.firstChild();
            var frag_child = frag.asNode().lastChild();
            while (frag_child) |fc| {
                const prev = fc.previousSibling();
                frame.removeNode(frag.asNode(), fc, .{ .reconnect_to = parent });
                if (first_child) |before| {
                    try frame.insertNodeRelative(parent, fc, .{ .before = before }, .{});
                } else {
                    try frame.appendNode(parent, fc, .{});
                }
                frag_child = prev;
            }
            continue;
        }

        var previous_root: ?*Node = null;
        if (child._parent) |previous_parent| {
            previous_root = child.getRootNode(.{});
            frame.removeNode(previous_parent, child, .{ .reconnect_to = parent });
        }

        const first_child = parent.firstChild();
        if (first_child) |before| {
            try frame.insertNodeRelative(parent, child, .{ .before = before }, .{ .previous_root = previous_root });
        } else {
            try frame.appendNode(parent, child, .{ .previous_root = previous_root });
        }
    }
}

pub fn replaceChildren(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn moveBefore(self: *Document, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

pub fn elementFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*Element {
    return self.elementFromPointImpl(x, y, false, frame);
}

// The faux layout gives most elements no useful horizontal extent, so
// viewport-relative hit-testing (WebDriver scroll actions) matches on the
// vertical axis only.
pub fn elementFromVerticalPoint(self: *Document, y: f64, frame: *Frame) !?*Element {
    return self.elementFromPointImpl(0, y, true, frame);
}

fn elementFromPointImpl(self: *Document, x: f64, y: f64, ignore_x: bool, frame: *Frame) !?*Element {
    // DFS in document order; topmost = last visited element whose rect contains (x, y).
    //
    // Faux-layout shortcut: rect.top is calculateDocumentPosition × 5, which is
    // monotonically increasing in document order. So we maintain a running
    // preorder counter instead of calling calculateDocumentPosition per node
    // (which itself is O(N)). Once the counter's y passes the query y, no
    // later element can contain the point, and we can return.
    //
    // The elements whose box contains the point share one VisibilityCache, so
    // the ancestor walk inside isHidden is paid once per ancestor rather than
    // once per candidate.
    var topmost: ?*Element = null;

    const root = self.asNode();
    var stack: std.ArrayList(*Node) = .empty;
    try stack.append(frame.local_arena, root);

    var visibility_cache: Element.VisibilityCache = .{};
    var preorder_index: f64 = 0;

    while (stack.items.len > 0) {
        const node = stack.pop() orelse break;
        const pos = preorder_index * 5.0;

        if (pos > y) {
            // Monotonic: no later element has top <= y, so none can contain (x, y).
            return topmost;
        }

        preorder_index += 1;
        if (node.is(Element)) |element| {
            // x and y both come from preorder position in our faux layout, so
            // `pos` is the box's left and its top both.
            //
            // Three tests, cheapest first, because all three have to hold and
            // every one of them rejects nearly everything: a height, then a
            // width, then a computed visibility. The order is what keeps this
            // walk affordable -- a height is a couple of table reads, a width
            // can be a walk over every character of the element's text, and a
            // visibility is a CSS cascade. Of the thousands of elements a call
            // passes, single digits get as far as the last one.
            hit: {
                if (y < pos or y > pos + element.getElementHeight(frame)) {
                    break :hit;
                }
                if (!ignore_x) {
                    const dims = element.getElementDimensions(frame);
                    if (x < pos or x > pos + dims.width) {
                        break :hit;
                    }
                }
                if (element.checkVisibilityCached(&visibility_cache, frame)) {
                    topmost = element;
                }
            }
        }

        // Add children to stack in reverse order so we process them in document order
        var child = node.lastChild();
        while (child) |c| {
            try stack.append(frame.local_arena, c);
            child = c.previousSibling();
        }
    }

    return topmost;
}

pub fn elementsFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) ![]const *Element {
    // Get topmost element
    var current: ?*Element = (try self.elementFromPoint(x, y, frame)) orelse return &.{};
    var result: std.ArrayList(*Element) = .empty;
    while (current) |el| {
        try result.append(frame.local_arena, el);
        current = el.parentElement();
    }
    return result.items;
}

pub fn getDocType(self: *Document) ?*Node {
    var tw = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            return node;
        }
    }
    return null;
}

// The members below come from the HTML spec's partial interface Document. They
// belong on Document.prototype, not on HTMLDocument.prototype: a headed Chrome
// 150 carries nothing but `constructor` on HTMLDocument.prototype. Detectors
// enumerate Document.prototype one level deep, so a member parked one rung too
// low reads as missing.

// The head is the first html-namespace child of the document element whose
// local name is head, whatever its Zig element type (e.g. a createElementNS
// "blah:head" is an HTMLUnknownElement but still qualifies).
pub fn getHead(self: *Document) ?*Element {
    const doc_el = self.getDocumentElement() orelse return null;
    var it = doc_el.asNode().childrenIterator();
    while (it.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (el._namespace == .html and std.mem.eql(u8, el.getLocalName(), "head")) {
            return el;
        }
    }
    return null;
}

pub fn getBody(self: *Document) ?*Element.Html.Body {
    const document_element = self.getDocumentElement() orelse return null;
    return findBodyForDoc(document_element);
}

pub fn setBody(self: *Document, html: []const u8, frame: *Frame) !void {
    const document_element = self.getDocumentElement() orelse return error.HierarchyError;

    // Build a fresh <body> holding the parsed HTML as its children. Fragment
    // parsing strips any <html>/<body>/<head> wrappers the author included.
    const new_body_node = try Frame.node_factory.createElementNS(frame, .html, "body", null);
    if (html.len > 0) {
        try Frame.parse.htmlAsChildren(frame, new_body_node, html);
    }

    const document_node = document_element.asNode();
    if (findBodyForDoc(document_element)) |current| {
        _ = try document_node.replaceChild(new_body_node, current.asNode(), frame);
    } else {
        _ = try document_node.appendChild(new_body_node, frame);
    }
}

fn findBodyForDoc(document_element: *Element) ?*Element.Html.Body {
    var child = document_element.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Body)) |body| {
            return body;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getTitle(self: *Document, frame: *Frame) ![]const u8 {
    // Search the entire document for the first <title> element
    const root = self.getDocumentElement() orelse return "";
    const title_element = blk: {
        var walker = @import("TreeWalker.zig").Full.init(root.asNode(), .{});
        while (walker.next()) |node| {
            if (node.is(Element.Html.Title)) |title| {
                break :blk title;
            }
        }
        return "";
    };

    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try title_element.asNode().getTextContent(&buf.writer);
    const text = buf.written();

    if (text.len == 0) {
        return "";
    }

    var started = false;
    var in_whitespace = false;
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(frame.local_arena, text.len);

    for (text) |c| {
        const is_ascii_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C';

        if (is_ascii_ws) {
            if (started) {
                in_whitespace = true;
            }
        } else {
            if (in_whitespace) {
                result.appendAssumeCapacity(' ');
                in_whitespace = false;
            }
            result.appendAssumeCapacity(c);
            started = true;
        }
    }

    return result.items;
}

pub fn setTitle(self: *Document, title: []const u8, frame: *Frame) !void {
    const head = self.getHead() orelse return;

    // Find existing title element in head
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title_element| {
            // Replace children, but don't create text node for empty string
            if (title.len == 0) {
                return title_element.asElement().replaceChildren(&.{}, frame);
            } else {
                return title_element.asElement().replaceChildren(&.{.{ .text = title }}, frame);
            }
        }
    }

    // No title element found, create one
    const title_node = try Frame.node_factory.createElementNS(frame, .html, "title", null);
    const title_element = title_node.as(Element);

    // Only add text if non-empty
    if (title.len > 0) {
        try title_element.replaceChildren(&.{.{ .text = title }}, frame);
    }

    _ = try head.asNode().appendChild(title_node, frame);
}

pub fn getImages(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .images, .name = "" },
        collections.NodeLive(.tag).init(root, .img, frame).htmlCollectionValue(),
    );
}

pub fn getScripts(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .scripts, .name = "" },
        collections.NodeLive(.tag).init(root, .script, frame).htmlCollectionValue(),
    );
}

pub fn getLinks(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .links, .name = "" },
        collections.NodeLive(.links).init(root, {}, frame).htmlCollectionValue(),
    );
}

pub fn getAnchors(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .anchors, .name = "" },
        collections.NodeLive(.anchors).init(root, {}, frame).htmlCollectionValue(),
    );
}

pub fn getForms(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .forms, .name = "" },
        collections.NodeLive(.tag).init(root, .form, frame).htmlCollectionValue(),
    );
}

// `document.plugins` is bound to this too, because the HTML spec says it "must
// return the same object as that returned by the embeds IDL attribute" -- one
// kind, so one cache entry, and the two names answer the same object (measured
// on Chrome 151).
pub fn getEmbeds(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .embeds, .name = "" },
        collections.NodeLive(.tag).init(root, .embed, frame).htmlCollectionValue(),
    );
}

pub fn getApplets(self: *Document, frame: *Frame) !*collections.HTMLCollection {
    return collections.identity.get(
        frame,
        .{ .root = self.asNode(), .kind = .applets, .name = "" },
        collections.HTMLCollection{ ._data = .empty },
    );
}

pub fn getCurrentScript(self: *const Document) ?*Element.Html.Script {
    return self._current_script;
}

pub fn getDir(self: *Document) []const u8 {
    const el = self.getDocumentElement() orelse return "";
    const html = el.is(Element.Html) orelse return "";
    return html.getDir();
}

pub fn setDir(self: *Document, value: []const u8, frame: *Frame) !void {
    const el = self.getDocumentElement() orelse return;
    const html = el.is(Element.Html) orelse return;
    try html.setDir(value, frame);
}

pub fn getAll(self: *Document, frame: *Frame) !*collections.HTMLAllCollection {
    const root = self.asNode();
    return collections.identity.get(
        frame,
        .{ .root = root, .kind = .all, .name = "" },
        collections.HTMLAllCollection.init(root, frame),
    );
}

// We do not retain the XML declaration a document was parsed from, so this is
// always null. That is what Chrome reports for an HTML document; for an XML one
// it would echo the declared encoding.
pub fn getXmlEncoding(_: *const Document) ?[]const u8 {
    return null;
}

pub fn getXmlVersion(self: *const Document) ?[]const u8 {
    if (self._xml_version) |v| {
        return v;
    }
    return if (self._type == .xml) "1.0" else null;
}

pub fn setXmlVersion(self: *Document, value: ?[]const u8, frame: *Frame) !void {
    self._xml_version = if (value) |v| try frame.arena.dupe(u8, v) else null;
}

pub fn getXmlStandalone(self: *const Document) bool {
    return self._xml_standalone;
}

pub fn setXmlStandalone(self: *Document, value: bool) void {
    self._xml_standalone = value;
}

pub fn getDesignMode(self: *const Document) []const u8 {
    return if (self._design_mode) "on" else "off";
}

// Anything that is not an ASCII case-insensitive "on" turns the mode off, which
// is how Chrome normalises it: "bogus", "", null and 1 all read back as "off".
pub fn setDesignMode(self: *Document, value: []const u8) void {
    self._design_mode = std.ascii.eqlIgnoreCase(value, "on");
}

// The five below were data properties. Chrome has every one of them as a
// getter, and the difference is not cosmetic: a bot check reads a value it will
// not trust the instance to answer honestly as
// `Object.getOwnPropertyDescriptor(Document.prototype, k).get.call(document)`,
// which throws "Cannot read properties of undefined (reading 'call')" against a
// data property. Values are the ones that were there: this engine's document is
// always visible, and never prerendering.
pub fn getHidden(_: *const Document) bool {
    return false;
}

pub fn getVisibilityState(_: *const Document) []const u8 {
    return "visible";
}

pub fn getPrerendering(_: *const Document) bool {
    return false;
}

pub fn getWasDiscarded(_: *const Document) bool {
    return false;
}

// From the SVG spec, not HTML: the document element, but only when it is an
// <svg> root. An HTML page reports null, and so does an XML document whose root
// is anything else.
pub fn getRootElement(self: *Document) ?*Element {
    const el = self.getDocumentElement() orelse return null;
    if (el._namespace != .svg or !std.mem.eql(u8, el.getLocalName(), "svg")) {
        return null;
    }
    return el;
}

// document.captureEvents / releaseEvents / clear: Netscape-era no-ops that
// Chrome still exposes and that return undefined.
pub fn captureEvents(_: *const Document) void {}
pub fn releaseEvents(_: *const Document) void {}
pub fn clear(_: *const Document) void {}

// The editing commands. What a page can observe without a selection is a fixed
// table, and this is that table as measured on a headed Chrome 150 over a
// 97-name candidate list: which names Blink admits to knowing, which of those
// are enabled with nothing selected and designMode off, and what
// queryCommandValue answers.
//
// Names are matched ASCII case-insensitively ("BOLD" and "SelectAll" resolve),
// so the keys here are lowercase and lookups fold the input.
const EditingCommand = struct {
    // Enabled with no selection and designMode off. execCommand agrees with
    // queryCommandEnabled, so it returns this too.
    enabled: bool = false,
    // queryCommandValue. The boolean-state commands stringify their state, so
    // they read "false" rather than "".
    value: []const u8 = "",
};

const editing_commands = std.StaticStringMap(EditingCommand).initComptime(.{
    .{ "backcolor", EditingCommand{} },
    .{ "bold", EditingCommand{ .value = "false" } },
    .{ "copy", EditingCommand{} },
    .{ "createlink", EditingCommand{} },
    .{ "cut", EditingCommand{} },
    .{ "defaultparagraphseparator", EditingCommand{ .enabled = true, .value = "div" } },
    .{ "delete", EditingCommand{} },
    .{ "fontname", EditingCommand{} },
    .{ "fontsize", EditingCommand{} },
    .{ "fontsizedelta", EditingCommand{} },
    .{ "forecolor", EditingCommand{} },
    .{ "formatblock", EditingCommand{} },
    .{ "forwarddelete", EditingCommand{} },
    .{ "hilitecolor", EditingCommand{} },
    .{ "indent", EditingCommand{} },
    .{ "inserthorizontalrule", EditingCommand{} },
    .{ "inserthtml", EditingCommand{} },
    .{ "insertimage", EditingCommand{} },
    .{ "insertlinebreak", EditingCommand{} },
    .{ "insertnewlineinquotedcontent", EditingCommand{} },
    .{ "insertorderedlist", EditingCommand{ .value = "false" } },
    .{ "insertparagraph", EditingCommand{} },
    .{ "inserttext", EditingCommand{} },
    .{ "insertunorderedlist", EditingCommand{ .value = "false" } },
    .{ "italic", EditingCommand{ .value = "false" } },
    .{ "justifycenter", EditingCommand{} },
    .{ "justifyfull", EditingCommand{} },
    .{ "justifyleft", EditingCommand{} },
    .{ "justifynone", EditingCommand{} },
    .{ "justifyright", EditingCommand{} },
    .{ "outdent", EditingCommand{} },
    .{ "pasteandmatchstyle", EditingCommand{} },
    .{ "print", EditingCommand{ .enabled = true } },
    .{ "redo", EditingCommand{} },
    .{ "removeformat", EditingCommand{} },
    .{ "selectall", EditingCommand{ .enabled = true } },
    .{ "strikethrough", EditingCommand{ .value = "false" } },
    .{ "stylewithcss", EditingCommand{ .enabled = true } },
    .{ "subscript", EditingCommand{ .value = "false" } },
    .{ "superscript", EditingCommand{ .value = "false" } },
    .{ "transpose", EditingCommand{} },
    .{ "underline", EditingCommand{ .value = "false" } },
    .{ "undo", EditingCommand{} },
    .{ "unlink", EditingCommand{} },
    .{ "unselect", EditingCommand{} },
    .{ "usecss", EditingCommand{ .enabled = true } },
});

fn lookupCommand(name: []const u8, buf: []u8) ?EditingCommand {
    if (name.len > buf.len) {
        return null;
    }
    return editing_commands.get(std.ascii.lowerString(buf[0..name.len], name));
}

// Blink refuses "paste" (a clipboard read the page may not have) and never
// implemented the Gecko-only toggles (heading, contentReadOnly,
// enableObjectResizing, ...), so those report unsupported here as well.
pub fn queryCommandSupported(_: *const Document, name: []const u8) bool {
    var buf: [64]u8 = undefined;
    return lookupCommand(name, &buf) != null;
}

pub fn queryCommandEnabled(_: *const Document, name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const command = lookupCommand(name, &buf) orelse return false;
    return command.enabled;
}

// Nothing here is ever in an indeterminate or "on" state: with no editable
// selection Chrome answers false for every command, known or not.
pub fn queryCommandIndeterm(_: *const Document, _: []const u8) bool {
    return false;
}

pub fn queryCommandState(_: *const Document, _: []const u8) bool {
    return false;
}

// The selection-dependent commands (fontName, fontSize, foreColor, justify*)
// read "" while nothing is selected; they only report computed values once a
// range exists, which is why they carry no value in the table above.
pub fn queryCommandValue(_: *const Document, name: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const command = lookupCommand(name, &buf) orelse return "";
    return command.value;
}

// The commands that are enabled without a selection either set a
// document-level editing preference (styleWithCSS, useCSS,
// defaultParagraphSeparator) or belong to the embedder (print). We report the
// same answer Chrome does but carry out no action.
pub fn execCommand(self: *const Document, name: []const u8) bool {
    return self.queryCommandEnabled(name);
}

// Fullscreen, pointer lock and picture-in-picture. None of the three can ever
// be entered here — there is no window to fill, no cursor to capture and no
// video pipeline — so every element query answers null and every exit is a
// no-op. Chrome nonetheless advertises the capabilities as available
// (fullscreenEnabled and pictureInPictureEnabled are both true on a normal
// page), and reporting false would be a signal of its own, so the flags are
// true and the state is empty. The webkit* spellings are still shipped by
// Chrome, aliases and all.
pub fn getFullscreenEnabled(_: *const Document) bool {
    return true;
}

pub fn getFullscreen(_: *const Document) bool {
    return false;
}

pub fn getFullscreenElement(_: *const Document) ?*Element {
    return null;
}

/// The setter the three attributes above share. `fullscreenEnabled`,
/// `fullscreen` and `fullscreenElement` are `[LegacyLenientSetter]` in the
/// Fullscreen spec: readonly, but with a setter that exists and silently drops
/// the assignment. So the descriptor is an accessor with both halves, which is
/// what a bot check reads -- measured on headed Chrome 150, no throw and the
/// value stays (probe-setter-semantics, and the assertions in
/// src/browser/tests/descriptor_kind.html).
pub fn setLeniently(_: *Document, _: js.Value) void {}

pub fn getPictureInPictureEnabled(_: *const Document) bool {
    return true;
}

pub fn exitPointerLock(_: *const Document) void {}
pub fn webkitCancelFullScreen(_: *const Document) void {}
pub fn webkitExitFullscreen(_: *const Document) void {}

// Measured rejection shapes: exiting fullscreen when the document is not
// active is a plain TypeError, while leaving picture-in-picture we never
// entered is an InvalidStateError.
pub fn exitFullscreen(_: *const Document, exec: *const js.Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .type_error = "Document not active" });
}

pub fn exitPictureInPicture(_: *const Document, exec: *const js.Execution) js.Promise {
    // Chrome names the operation and says what is missing (measured); the bare
    // InvalidStateError this used to reject with printed the generic
    // "The object is in an invalid state".
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("Document.exitPictureInPicture", DOMException.init(
        "Failed to execute 'exitPictureInPicture' on 'Document': There is no Picture-in-Picture element in this document.",
        "InvalidStateError",
    ));
    return resolver.promise();
}

// Document-wide animations. Element.getAnimations already reports none; there
// is nothing on the document either.
pub fn getAnimations(_: *const Document) []*@import("animation/Animation.zig") {
    return &.{};
}

// The Storage Access API. A top-level, same-site document already has
// unpartitioned cookie access, so Chrome resolves both queries true and the
// request resolves immediately; asking on behalf of another site needs a
// permission grant we have no way to hold, and Chrome rejects that with
// NotAllowedError.
pub fn hasStorageAccess(_: *const Document, exec: *const js.Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(true);
}

pub fn requestStorageAccess(_: *const Document, exec: *const js.Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn requestStorageAccessFor(_: *const Document, _: []const u8, exec: *const js.Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
}

// Topics and Private State Tokens: we join no interest groups, observe no
// topics and hold no tokens, which is the same answer a fresh Chrome profile
// gives.
pub fn browsingTopics(_: *const Document, _: ?js.Object, exec: *const js.Execution) !js.Promise {
    const empty: []const js.Object = &.{};
    return exec.js.local.?.resolvePromise(empty);
}

pub fn hasPrivateToken(_: *const Document, _: []const u8, exec: *const js.Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(false);
}

pub fn hasRedemptionRecord(_: *const Document, _: []const u8, exec: *const js.Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(false);
}

// Announces a message to assistive technology. There is none listening.
pub fn ariaNotify(_: *const Document, _: []const u8, _: ?js.Object) void {}

pub fn getTimeline(self: *Document, frame: *Frame) !*services.DocumentTimeline {
    if (self._timeline) |existing| {
        return existing;
    }
    const created = try services.DocumentTimeline.init(frame);
    self._timeline = created;
    return created;
}

pub fn getFeaturePolicy(self: *Document, frame: *Frame) !*services.FeaturePolicy {
    return documentService(services.FeaturePolicy, &self._feature_policy, frame);
}

pub fn getFragmentDirective(self: *Document, frame: *Frame) !*services.FragmentDirective {
    return documentService(services.FragmentDirective, &self._fragment_directive, frame);
}

// Created on first read and handed back unchanged after that, so identity
// holds: Chrome's document.timeline === document.timeline.
fn documentService(comptime T: type, slot: *?*T, frame: *Frame) !*T {
    if (slot.*) |existing| {
        return existing;
    }
    const created = try frame._factory.create(T{});
    slot.* = created;
    return created;
}

// A transition that is already over — see ViewTransition for why. Chrome scopes
// a document-wide transition to the document element, which is what it reports
// as transitionRoot.
pub fn startViewTransition(self: *Document, _: ?js.Object, frame: *Frame) !*services.ViewTransition {
    return services.ViewTransition.init(self.getDocumentElement(), frame);
}

// Non-null only while a transition is running, and ours never are.
pub fn getActiveViewTransition(_: *const Document) ?*services.ViewTransition {
    return null;
}

// The same registry as window.customElements, not a second one (measured:
// document.customElementRegistry === window.customElements).
pub fn getCustomElementRegistry(self: *const Document, frame: *Frame) ?*CustomElementRegistry {
    const owner = self._frame orelse frame;
    return owner.window.getCustomElements();
}

// caretRangeFromPoint / caretPositionFromPoint. Both hit-test a viewport point
// and describe where a caret would land inside the node found there. We have no
// text layout, so the offset is always 0 — the node is real, the position within
// it is not something we can measure.
pub fn caretRangeFromPoint(self: *Document, x: ?f64, y: ?f64, frame: *Frame) !?*Range {
    const node = try self.caretNodeFromPoint(x orelse 0, y orelse 0, frame) orelse return null;
    const range = try Range.initIn(self.asNode(), frame);
    try range.setStart(node, 0);
    try range.setEnd(node, 0);
    return range;
}

pub fn caretPositionFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*services.CaretPosition {
    const node = try self.caretNodeFromPoint(x, y, frame) orelse return null;
    return services.CaretPosition.init(node, 0, frame);
}

// Chrome reports the text node under the point rather than its element, so
// descend into the first text child when there is one.
fn caretNodeFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*Node {
    const element = try self.elementFromPoint(x, y, frame) orelse return null;
    var child = element.asNode().firstChild();
    while (child) |node| {
        if (node._type == .cdata) {
            return node;
        }
        child = node.nextSibling();
    }
    return element.asNode();
}

// document.write is complicated and works differently based on the state of
// parsing. But, generally, it's supposed to be additive/streaming. Multiple
// document.writes are parsed a single unit. Well, that causes issues with
// html5ever if we're trying to parse 1 document which is really many. So we
// try to detect "new" documents. (This is particularly problematic because we
// don't have proper frame support, so document.write into a frame can get
// sent to the main document (instead of the frame document)...and it's completely
// reasonable for 2 frames to document.write("<html>...</html>") into their own
// frame.
fn looksLikeNewDocument(html: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, html, &std.ascii.whitespace);
    return std.ascii.startsWithIgnoreCase(trimmed, "<!DOCTYPE") or
        std.ascii.startsWithIgnoreCase(trimmed, "<html");
}

pub fn write(self: *Document, text: []const []const u8, frame: *Frame) !void {
    return self.writeInternal(text, false, frame);
}

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#dom-document-writeln
// `writeln(...text)` runs the document write steps with `text` followed by a
// U+000A LINE FEED character.
pub fn writeln(self: *Document, text: []const []const u8, frame: *Frame) !void {
    return self.writeInternal(text, true, frame);
}

fn writeInternal(self: *Document, text: []const []const u8, append_newline: bool, call_frame: *Frame) !void {
    // document.write acts on this document's own frame, which isn't necessarily
    // the calling frame — e.g. a parent frame writing into an iframe's document.
    // The markup (and any scripts it contains) must be parsed and run in that
    // document's context, not the caller's.
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    const html = blk: {
        var joined: std.ArrayList(u8) = .empty;
        for (text) |str| {
            // Scratch buffer, consumed synchronously below. Keep it on the
            // active (calling) frame's call_arena: a script run by the parse
            // could reset the document frame's call_arena underfoot.
            try joined.appendSlice(call_frame.call_arena, str);
        }
        if (append_newline) {
            try joined.append(call_frame.call_arena, '\n');
        }
        break :blk joined.items;
    };

    // A script-created parser always streams: `open()` puts the frame back
    // into .parsing (so that `close()` has a parse to end), and the write of a
    // script running inside that parse belongs at its insertion point, not
    // spliced in after the script element the way a parser-blocking inline
    // script's write is.
    if (self._script_created_parser != null or self._current_script == null or frame._load_state != .parsing) {
        if (self._script_created_parser == null or looksLikeNewDocument(html)) {
            _ = try self.open(frame);
        }

        if (html.len > 0) {
            if (self._script_created_parser) |*parser| {
                parser.read(html) catch |err| {
                    log.warn(.dom, "document.write parser error", .{ .err = err });
                    // html5ever's handle was destroyed inside read(), but the
                    // pending text buffer (if any) still wants to land on its
                    // text node's _data — flushPendingText doesn't depend on
                    // the handle, so attempt a final flush before dropping.
                    parser.parser.flushPendingText() catch |flush_err| {
                        log.warn(.dom, "flush after parser panic", .{ .err = flush_err });
                    };
                    self._script_created_parser = null;
                    self._close_requested = false;
                };
            }
        }

        if (self._close_requested) {
            // document.close was executed during a document.write. We couldn't
            // execute that during the write, but we can now.
            if (self._script_created_parser) |*parser| {
                if (parser.feeding == false) {
                    try self.finishScriptCreatedParser(frame);
                }
            } else {
                self._close_requested = false;
            }
        }
        return;
    }

    // Inline script during parsing
    const script = self._current_script.?;
    const parent = script.asNode().parentNode() orelse return;

    // Our implementation is hacky. We'll write to a DocumentFragment, then
    // append its children.
    const fragment = try Node.DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();

    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .document_write;
    defer frame._parse_mode = previous_parse_mode;

    const arena = try frame.getArena(.medium, "Document.write");
    defer arena.release();

    var parser = Parser.init(arena.allocator(), fragment_node, frame, .{ .allow_declarative_shadow = true });
    parser.parseFragment(html);

    // Extract children from wrapper HTML element (html5ever wraps fragments)
    // https://github.com/servo/html5ever/issues/583
    const first = fragment_node.firstChild() orelse return;

    // Collect all children to insert (to avoid iterator invalidation)
    var children_to_insert: std.ArrayList(*Node) = .empty;

    var it = if (first.is(Element.Html.Html) == null) fragment_node.childrenIterator() else first.childrenIterator();
    while (it.next()) |child| {
        try children_to_insert.append(arena.allocator(), child);
    }

    if (children_to_insert.items.len == 0) {
        return;
    }

    // Determine insertion point:
    // - If _write_insertion_point is set and still parented correctly, continue from there
    // - Otherwise, start after the script (first write, or previous insertion point was removed)
    // parseFragment above can synchronously execute a parser-blocking script
    // (e.g. <script src=...> with from_parser=true). That script's side
    // effects can detach `script` from `parent` — for instance, by writing
    // to parent.innerHTML — leaving us nowhere sensible to splice in.
    var insert_after: ?*Node = blk: {
        if (self._write_insertion_point) |wip| {
            if (wip._parent == parent) {
                break :blk wip;
            }
        }
        if (script.asNode()._parent == parent) {
            break :blk script.asNode();
        }
        return;
    };

    for (children_to_insert.items) |child| {
        // Clear parent pointer (child is currently parented to fragment/HTML wrapper)
        child._parent = null;
        try frame.insertNodeRelative(parent, child, .{ .after = insert_after.? }, .{});
        insert_after = child;
    }

    frame.domChanged();
    self._write_insertion_point = children_to_insert.getLast();
}

pub fn open(self: *Document, call_frame: *Frame) !*Document {
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (frame._load_state == .parsing) {
        return self;
    }

    if (self._script_created_parser != null) {
        return self;
    }

    // If we aren't parsing, then open clears the document.
    const doc_node = self.asNode();

    // Before any of the old document is thrown away: remove every event
    // listener registered on the document, its Window and its descendants. A
    // handler hung on the document before a write is gone by the time the
    // write is parsed -- Chrome was measured doing this to all three, and to
    // the `on*` slots with them. The iframe ELEMENT's listeners live in the
    // parent document and are untouched, which is what lets the
    // onload/write/close idiom work at all.
    {
        const arena = call_frame.call_arena;
        var targets: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer targets.deinit(arena);

        // A short allocation failure here would leave listeners standing on
        // whatever had not been collected yet, which is the state we are
        // already in; clearing what we did collect is strictly better.
        blk: {
            targets.put(arena, @intFromPtr(frame.window.asEventTarget()), {}) catch break :blk;
            targets.put(arena, @intFromPtr(self.asEventTarget()), {}) catch break :blk;
            var tw: TreeWalker.FullExcludeSelf = .init(doc_node, .{});
            while (tw.next()) |node| {
                targets.put(arena, @intFromPtr(node.asEventTarget()), {}) catch break :blk;
            }
        }
        frame._event_manager.base.removeAllForTargets(&targets);
    }

    {
        // Remove all children from document
        var it = doc_node.childrenIterator();
        while (it.next()) |child| {
            frame.removeNode(doc_node, child, .{ .reconnect_to = null });
        }
    }

    // reset the document
    self._elements_by_id.clearAndFree(frame.arena);
    self._active_element = null;
    self._open_popovers = .empty;
    self._style_sheets = null;
    self._cascade_sheets = null;
    self._implementation = null;
    self._ready_state = .loading;

    self._script_created_parser = Parser.Streaming.init(frame.arena, doc_node, frame, .{ .allow_declarative_shadow = true });
    try self._script_created_parser.?.start();
    frame._parse_mode = .document;

    // The document being opened takes the ENTRY document's URL -- the URL of
    // the document whose script is calling, not its own. A parent writing into
    // its about:blank iframe leaves that iframe claiming the parent's address,
    // which is what the realm a guard builds this way answers when asked where
    // it is. The bridge hands us the receiver's frame, so ask V8 who is
    // actually running. Cross-origin is supposed to throw SecurityError before
    // reaching here; we don't raise it, but we won't hand a document an address
    // from an origin it cannot claim either.
    const entry = frame.js.getIncumbent();
    if (entry != frame and frame.isSameOrigin(entry.url)) {
        frame.adoptDocumentUrl(entry.url) catch |err| {
            log.warn(.dom, "document.open url", .{ .err = err, .url = entry.url });
        };
    }

    if (frame._load_state == .complete) {
        // The frame is parsing again, which is what gives close() something to
        // end: ending it is what settles readyState and fires the frame's load
        // event. A frame that already reported in to its parent has to be
        // allowed to report again -- the second parse fires its own load event
        // on the iframe element -- but it delays nothing this time, because the
        // parent's own load is long over.
        frame._load_state = .parsing;
        frame._parent_notified = false;
        frame._delays_parent_load = false;
    }

    return self;
}

pub fn close(self: *Document, call_frame: *Frame) !void {
    const frame = self._frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (self._script_created_parser) |*parser| {
        if (parser.feeding) {
            // we're currently in a document.write, we cannot close. We flag
            // the close and process it at the next safe spot.
            self._close_requested = true;
            return;
        }
    } else {
        return;
    }

    try self.finishScriptCreatedParser(frame);
}

fn finishScriptCreatedParser(self: *Document, frame: *Frame) !void {
    self._close_requested = false;

    // done() finishes html5ever's handle and runs the final flushPendingText.
    // Even if flushPendingText errors, the handle is already finished and we
    // must not retain the Streaming — defer so the error path also drops it.
    // (Streaming.done nulls its own handle, so dropping the struct is safe.)
    defer self._script_created_parser = null;
    try self._script_created_parser.?.done();

    // The write'd markup is fully parsed; run any deferred scripts it produced
    // (e.g. inline modules) before firing the load event. This frame's initial
    // parse may never have set static_scripts_done (e.g. a freshly-loaded
    // iframe written into via document.write), so we can't rely on it.
    frame._script_manager.base.scriptCreatedParseDone();

    frame.documentIsComplete();
}

pub fn getFirstElementChild(self: *Document) ?*Element {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
    }
    return null;
}

pub fn getLastElementChild(self: *Document) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Document) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element) != null) {
            i += 1;
        }
    }
    return i;
}

pub fn getAdoptedStyleSheets(self: *Document, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

/// Whether this document is on the chain from the focused frame to its root.
///
/// Answering `true` unconditionally is a headless tell of the shape these
/// guards weigh: a real browser gives the top document focus and a child frame
/// nothing until something inside it is focused. Measured on Chrome 151 with
/// tools/fingerprint/probes/expr-b85-has-focus.js -- an untouched same-origin
/// child answers `false`, both answer `true` once an input in the child is
/// focused, the child still answers `true` after that input is blurred, and a
/// `createHTMLDocument` answers `false`.
pub fn hasFocus(self: *Document) bool {
    // No browsing context, no chain to be on: createHTMLDocument, DOMParser
    // output and template contents all land here.
    const doc_frame = self._frame orelse return false;
    var current: ?*Frame = doc_frame._page.focused_frame orelse &doc_frame._page.frame;
    while (current) |f| : (current = f.parent) {
        if (f == doc_frame) return true;
    }
    return false;
}

pub fn setAdoptedStyleSheets(self: *Document, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

// Validates that nodes can be inserted into a Document, respecting Document constraints:
// - At most one Element child
// - At most one DocumentType child
// - No Document, Attribute, or Text nodes
// - Only Element, DocumentType, Comment, and ProcessingInstruction are allowed
// When replacing=true, existing children are not counted (for replaceChildren)
fn validateDocumentNodes(self: *Document, nodes: []const Node.NodeOrText, comptime replacing: bool) !void {
    const parent = self.asNode();

    // Check existing elements and doctypes (unless we're replacing all children)
    var has_element = false;
    var has_doctype = false;

    if (!replacing) {
        var it = parent.childrenIterator();
        while (it.next()) |child| {
            if (child._type == .element) {
                has_element = true;
            } else if (child._type == .document_type) {
                has_doctype = true;
            }
        }
    }

    // Validate new nodes
    for (nodes) |node_or_text| {
        switch (node_or_text) {
            .text => {
                // Text nodes are not allowed as direct children of Document
                return error.HierarchyError;
            },
            .node => |child| {
                // Check if it's a DocumentFragment - need to validate its children
                if (child.is(Node.DocumentFragment)) |frag| {
                    var frag_it = frag.asNode().childrenIterator();
                    while (frag_it.next()) |frag_child| {
                        // Document can only contain: Element, DocumentType, Comment, ProcessingInstruction
                        switch (frag_child._type) {
                            .element => {
                                if (has_element) {
                                    return error.HierarchyError;
                                }
                                has_element = true;
                            },
                            .document_type => {
                                if (has_doctype) {
                                    return error.HierarchyError;
                                }
                                if (has_element) {
                                    // Doctype cannot be inserted if document already has an element
                                    return error.HierarchyError;
                                }
                                has_doctype = true;
                            },
                            .cdata => switch (frag_child.subtype(Node.CData)._type) {
                                .comment, .processing_instruction => {}, // Allowed
                                .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                            },
                            .document, .attribute, .document_fragment => return error.HierarchyError,
                        }
                    }
                } else {
                    // Validate node type for direct insertion
                    switch (child._type) {
                        .element => {
                            if (has_element) {
                                return error.HierarchyError;
                            }
                            has_element = true;
                        },
                        .document_type => {
                            if (has_doctype) {
                                return error.HierarchyError;
                            }
                            if (has_element) {
                                // Doctype cannot be inserted if document already has an element
                                return error.HierarchyError;
                            }
                            has_doctype = true;
                        },
                        .cdata => switch (child.subtype(Node.CData)._type) {
                            .comment, .processing_instruction => {}, // Allowed
                            .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                        },
                        .document, .attribute, .document_fragment => return error.HierarchyError,
                    }
                }

                // Check for cycles
                if (child.contains(parent)) {
                    return error.HierarchyError;
                }
            },
        }
    }
}

// DOM §1.4 "Name validation" productions.

pub fn isValidElementLocalName(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }
    if (std.ascii.isAlphabetic(name[0])) {
        // Names the HTML parser can construct: anything except ASCII
        // whitespace, NUL, '/' or '>'.
        for (name[1..]) |c| {
            switch (c) {
                '\t', '\n', 0x0C, '\r', ' ', 0, '/', '>' => return false,
                else => {},
            }
        }
        return true;
    }
    // Otherwise the first code point must be ':', '_' or beyond ASCII, and
    // the rest restricted to alphanumerics, '-', '.', ':', '_' or non-ASCII.
    if (name[0] != ':' and name[0] != '_' and name[0] < 0x80) {
        return false;
    }
    for (name[1..]) |c| {
        const valid = std.ascii.isAlphanumeric(c) or
            c == '-' or c == '.' or c == ':' or c == '_' or c >= 0x80;
        if (!valid) {
            return false;
        }
    }
    return true;
}

pub fn isValidNamespacePrefix(prefix: []const u8) bool {
    if (prefix.len == 0) {
        return false;
    }
    for (prefix) |c| {
        switch (c) {
            '\t', '\n', 0x0C, '\r', ' ', 0, '/', '>' => return false,
            else => {},
        }
    }
    return true;
}

/// The first character keeping `prefix` out of the namespace-prefix production.
pub fn firstInvalidPrefixChar(prefix: []const u8) ?u8 {
    for (prefix) |c| {
        switch (c) {
            '\t', '\n', 0x0C, '\r', ' ', 0, '/', '>' => return c,
            else => {},
        }
    }
    return null;
}

pub fn isValidAttributeLocalName(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }
    for (name) |c| {
        switch (c) {
            '\t', '\n', 0x0C, '\r', ' ', 0, '/', '=', '>' => return false,
            else => {},
        }
    }
    return true;
}

/// The first character that keeps `name` out of the element-name production.
/// createElementNS names it in its rejection sentence, so knowing *that* a name
/// is invalid is not enough. Mirrors `isValidElementLocalName` branch for
/// branch; an empty name has no offending character and returns null.
pub fn firstInvalidElementNameChar(name: []const u8) ?u8 {
    if (name.len == 0) {
        return null;
    }
    if (std.ascii.isAlphabetic(name[0])) {
        for (name[1..]) |c| {
            switch (c) {
                '\t', '\n', 0x0C, '\r', ' ', 0, '/', '>' => return c,
                else => {},
            }
        }
        return null;
    }
    if (name[0] != ':' and name[0] != '_' and name[0] < 0x80) {
        return name[0];
    }
    for (name[1..]) |c| {
        const valid = std.ascii.isAlphanumeric(c) or
            c == '-' or c == '.' or c == ':' or c == '_' or c >= 0x80;
        if (!valid) {
            return c;
        }
    }
    return null;
}

fn validateElementName(name: []const u8, frame: *Frame) !void {
    if (isValidElementLocalName(name)) {
        return;
    }
    // createElement quotes the whole tag name rather than one character, and
    // calls it a tag name rather than a qualified name. Chrome 151.
    return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
        frame.call_arena,
        "Failed to execute 'createElement' on 'Document': The tag name provided ('{s}') is not a valid name.",
        .{name},
    ));
}

pub const ValidatedName = struct {
    prefix: ?[]const u8,
    local_name: []const u8,
    namespace: ?[]const u8,
};

// The DOM spec's "validate and extract a namespace and qualifiedName".
/// `op` is the operation Blink names in the rejection sentence; it also fixes
/// the interface, which is 'Document' for everything here except
/// createDocument. Chrome 151 has four sentences on this path: empty name,
/// empty prefix, empty local name, and one that quotes the first character the
/// name production tripped over.
pub fn validateAndExtract(
    namespace_: ?[]const u8,
    qualified_name: []const u8,
    comptime context: enum { element, attribute },
    comptime op: []const u8,
    comptime interface: []const u8,
    frame: *Frame,
) !ValidatedName {
    const said = "Failed to execute '" ++ op ++ "' on '" ++ interface ++ "': ";

    var namespace: ?[]const u8 = namespace_;
    if (namespace) |ns| {
        if (ns.len == 0) {
            namespace = null;
        }
    }

    if (qualified_name.len == 0) {
        return frame.js.fail(
            error.InvalidCharacterError,
            said ++ "The qualified name provided is empty.",
        );
    }

    var prefix: ?[]const u8 = null;
    var local_name = qualified_name;
    if (std.mem.indexOfScalar(u8, qualified_name, ':')) |colon| {
        prefix = qualified_name[0..colon];
        local_name = qualified_name[colon + 1 ..];
        if (!isValidNamespacePrefix(prefix.?)) {
            if (prefix.?.len == 0) {
                return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
                    frame.call_arena,
                    said ++ "The qualified name provided ('{s}') has an empty namespace prefix.",
                    .{qualified_name},
                ));
            }
            return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
                frame.call_arena,
                said ++ "The qualified name provided ('{s}') contains the invalid character '{c}'.",
                .{ qualified_name, firstInvalidPrefixChar(prefix.?) orelse ' ' },
            ));
        }
    }

    const local_valid = switch (context) {
        .element => isValidElementLocalName(local_name),
        .attribute => isValidAttributeLocalName(local_name),
    };
    if (!local_valid) {
        if (local_name.len == 0) {
            return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
                frame.call_arena,
                said ++ "The qualified name provided ('{s}') has an empty local name.",
                .{qualified_name},
            ));
        }
        const bad = switch (context) {
            .element => firstInvalidElementNameChar(local_name),
            .attribute => switch (Element.Attribute.checkAttributeName(local_name) orelse
                return error.InvalidCharacterError) {
                .empty => null,
                .character => |c| c,
            },
        } orelse return error.InvalidCharacterError;
        return frame.js.fail(error.InvalidCharacterError, try std.fmt.allocPrint(
            frame.call_arena,
            said ++ "The qualified name provided ('{s}') contains the invalid character '{c}'.",
            .{ qualified_name, bad },
        ));
    }

    if (prefix != null and namespace == null) {
        return error.NamespaceError;
    }
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml") and (namespace == null or !std.mem.eql(u8, namespace.?, "http://www.w3.org/XML/1998/namespace"))) {
            return error.NamespaceError;
        }
    }
    const is_xmlns = std.mem.eql(u8, qualified_name, "xmlns") or (prefix != null and std.mem.eql(u8, prefix.?, "xmlns"));
    const ns_is_xmlns = namespace != null and std.mem.eql(u8, namespace.?, "http://www.w3.org/2000/xmlns/");
    if (is_xmlns != ns_is_xmlns) {
        return error.NamespaceError;
    }

    return .{ .prefix = prefix, .local_name = local_name, .namespace = namespace };
}

// When a frame's URL is about:blank, or as soon as a frame is
// programmatically created, it has this default "blank" content
pub fn injectBlank(self: *Document, frame: *Frame) error{InjectBlankError}!void {
    self._injectBlank(frame) catch |err| {
        // we wrap _injectBlank like this so that injectBlank can only return an
        // InjectBlankError. injectBlank is used in when nodes are inserted
        // as since it inserts node itself, Zig can't infer the error set.
        log.err(.browser, "inject blank", .{ .err = err });
        return error.InjectBlankError;
    };
}

fn _injectBlank(self: *Document, frame: *Frame) !void {
    if (comptime lp.IS_DEBUG) {
        // should only be called on an empty document
        std.debug.assert(self.asNode()._first_child == null);
    }

    const html = try Frame.node_factory.createElementNS(frame, .html, "html", null);
    const head = try Frame.node_factory.createElementNS(frame, .html, "head", null);
    const body = try Frame.node_factory.createElementNS(frame, .html, "body", null);
    try frame.appendNode(html, head, .{});
    try frame.appendNode(html, body, .{});
    try frame.appendNode(self.asNode(), html, .{});
}

const ReadyState = enum {
    loading,
    interactive,
    complete,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Document);

    pub const Meta = struct {
        pub const name = "Document";
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "writeln";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*Document {
        return frame._factory.node(Document{
            ._proto = undefined,
            ._type = .generic,
            ._url = "about:blank",
            ._charset = "UTF-8",
        });
    }

    // Declaration order is the prototype's own-property order, so it is the
    // order a detector sees. It mirrors a headed Chrome 150's
    // Object.getOwnPropertyNames(Document.prototype) exactly.
    pub const implementation = bridge.accessor(Document.getImplementation, null, .{});
    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const documentURI = bridge.accessor(Document.getURL, null, .{});
    pub const compatMode = bridge.accessor(Document.getCompatMode, null, .{});
    pub const characterSet = bridge.accessor(getCharacterSet, null, .{});
    pub const charset = bridge.accessor(getCharacterSet, null, .{});
    pub const inputEncoding = bridge.accessor(getCharacterSet, null, .{});
    pub const contentType = bridge.accessor(Document.getContentType, null, .{});
    pub const doctype = bridge.accessor(Document.getDocType, null, .{});
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const xmlEncoding = bridge.accessor(Document.getXmlEncoding, null, .{});
    pub const xmlVersion = bridge.accessor(Document.getXmlVersion, Document.setXmlVersion, .{});
    pub const xmlStandalone = bridge.accessor(Document.getXmlStandalone, Document.setXmlStandalone, .{});
    pub const domain = bridge.accessor(Document.getDomain, Document.setDomain, .{});
    // Upstream landed a real referrer (src/browser/referrer.zig); taking it
    // replaces our constant "" placeholder. Chrome's `referrer` is a getter on
    // Document.prototype, so the accessor form is also the right descriptor.
    // Position in this list is unchanged: it is Chrome's own-property order.
    pub const referrer = bridge.accessor(Document.getReferrer, null, .{});
    pub const cookie = bridge.accessor(Document.getCookie, Document.setCookie, .{});
    pub const lastModified = bridge.accessor(Document.getLastModified, null, .{});
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});
    pub const title = bridge.accessor(Document.getTitle, Document.setTitle, .{ .ce_reactions = true });
    pub const dir = bridge.accessor(Document.getDir, Document.setDir, .{ .ce_reactions = true });
    pub const body = bridge.accessor(Document.getBody, Document.setBody, .{ .ce_reactions = true });
    pub const head = bridge.accessor(Document.getHead, null, .{});
    pub const images = bridge.accessor(Document.getImages, null, .{});
    pub const embeds = bridge.accessor(Document.getEmbeds, null, .{});
    pub const plugins = bridge.accessor(Document.getEmbeds, null, .{});
    pub const links = bridge.accessor(Document.getLinks, null, .{});
    pub const forms = bridge.accessor(Document.getForms, null, .{});
    pub const scripts = bridge.accessor(Document.getScripts, null, .{});
    pub const currentScript = bridge.accessor(Document.getCurrentScript, null, .{});
    pub const defaultView = bridge.accessor(_defaultView, null, .{});
    pub const designMode = bridge.accessor(Document.getDesignMode, Document.setDesignMode, .{});
    fn _defaultView(self: *const Document) ?*Window {
        const frame = self._frame orelse return null;
        return frame.window;
    }
    pub const onreadystatechange = bridge.accessor(handlerAccessor(.onreadystatechange).get, handlerAccessor(.onreadystatechange).set, .{});
    pub const anchors = bridge.accessor(Document.getAnchors, null, .{});
    pub const applets = bridge.accessor(Document.getApplets, null, .{});
    pub const fgColor = bridge.accessor(colorAccessor("text").get, colorAccessor("text").set, .{});
    pub const linkColor = bridge.accessor(colorAccessor("link").get, colorAccessor("link").set, .{});
    pub const vlinkColor = bridge.accessor(colorAccessor("vlink").get, colorAccessor("vlink").set, .{});
    pub const alinkColor = bridge.accessor(colorAccessor("alink").get, colorAccessor("alink").set, .{});
    pub const bgColor = bridge.accessor(colorAccessor("bgcolor").get, colorAccessor("bgcolor").set, .{});
    pub const all = bridge.accessor(Document.getAll, null, .{});
    pub const scrollingElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const onpointerlockchange = bridge.accessor(handlerAccessor(.onpointerlockchange).get, handlerAccessor(.onpointerlockchange).set, .{});
    pub const onpointerlockerror = bridge.accessor(handlerAccessor(.onpointerlockerror).get, handlerAccessor(.onpointerlockerror).set, .{});
    pub const hidden = bridge.accessor(Document.getHidden, null, .{});
    pub const visibilityState = bridge.accessor(Document.getVisibilityState, null, .{});
    pub const wasDiscarded = bridge.accessor(Document.getWasDiscarded, null, .{});
    pub const prerendering = bridge.accessor(Document.getPrerendering, null, .{});
    pub const featurePolicy = bridge.accessor(Document.getFeaturePolicy, null, .{});
    // The two -webkit- aliases are the same getters under their old names.
    pub const webkitVisibilityState = bridge.accessor(Document.getVisibilityState, null, .{});
    pub const webkitHidden = bridge.accessor(Document.getHidden, null, .{});
    pub const onbeforecopy = bridge.accessor(handlerAccessor(.onbeforecopy).get, handlerAccessor(.onbeforecopy).set, .{});
    pub const onbeforecut = bridge.accessor(handlerAccessor(.onbeforecut).get, handlerAccessor(.onbeforecut).set, .{});
    pub const onbeforepaste = bridge.accessor(handlerAccessor(.onbeforepaste).get, handlerAccessor(.onbeforepaste).set, .{});
    pub const onfreeze = bridge.accessor(handlerAccessor(.onfreeze).get, handlerAccessor(.onfreeze).set, .{});
    pub const onprerenderingchange = bridge.accessor(handlerAccessor(.onprerenderingchange).get, handlerAccessor(.onprerenderingchange).set, .{});
    pub const onresume = bridge.accessor(handlerAccessor(.onresume).get, handlerAccessor(.onresume).set, .{});
    pub const onsearch = bridge.accessor(handlerAccessor(.onsearch).get, handlerAccessor(.onsearch).set, .{});
    pub const onvisibilitychange = bridge.accessor(handlerAccessor(.onvisibilitychange).get, handlerAccessor(.onvisibilitychange).set, .{});
    pub const timeline = bridge.accessor(Document.getTimeline, null, .{});
    pub const fullscreenEnabled = bridge.accessor(Document.getFullscreenEnabled, Document.setLeniently, .{});
    pub const fullscreen = bridge.accessor(Document.getFullscreen, Document.setLeniently, .{});
    pub const onfullscreenchange = bridge.accessor(handlerAccessor(.onfullscreenchange).get, handlerAccessor(.onfullscreenchange).set, .{});
    pub const onfullscreenerror = bridge.accessor(handlerAccessor(.onfullscreenerror).get, handlerAccessor(.onfullscreenerror).set, .{});
    pub const webkitIsFullScreen = bridge.accessor(Document.getFullscreen, null, .{});
    pub const webkitCurrentFullScreenElement = bridge.accessor(Document.getFullscreenElement, null, .{});
    pub const webkitFullscreenEnabled = bridge.accessor(Document.getFullscreenEnabled, null, .{});
    pub const webkitFullscreenElement = bridge.accessor(Document.getFullscreenElement, null, .{});
    pub const onwebkitfullscreenchange = bridge.accessor(handlerAccessor(.onwebkitfullscreenchange).get, handlerAccessor(.onwebkitfullscreenchange).set, .{});
    pub const onwebkitfullscreenerror = bridge.accessor(handlerAccessor(.onwebkitfullscreenerror).get, handlerAccessor(.onwebkitfullscreenerror).set, .{});
    pub const rootElement = bridge.accessor(Document.getRootElement, null, .{});
    pub const pictureInPictureEnabled = bridge.accessor(Document.getPictureInPictureEnabled, null, .{});
    pub const onabort = bridge.accessor(handlerAccessor(.onabort).get, handlerAccessor(.onabort).set, .{});
    pub const onbeforeinput = bridge.accessor(handlerAccessor(.onbeforeinput).get, handlerAccessor(.onbeforeinput).set, .{});
    pub const onbeforematch = bridge.accessor(handlerAccessor(.onbeforematch).get, handlerAccessor(.onbeforematch).set, .{});
    pub const onbeforetoggle = bridge.accessor(handlerAccessor(.onbeforetoggle).get, handlerAccessor(.onbeforetoggle).set, .{});
    pub const onblur = bridge.accessor(handlerAccessor(.onblur).get, handlerAccessor(.onblur).set, .{});
    pub const oncancel = bridge.accessor(handlerAccessor(.oncancel).get, handlerAccessor(.oncancel).set, .{});
    pub const oncanplay = bridge.accessor(handlerAccessor(.oncanplay).get, handlerAccessor(.oncanplay).set, .{});
    pub const oncanplaythrough = bridge.accessor(handlerAccessor(.oncanplaythrough).get, handlerAccessor(.oncanplaythrough).set, .{});
    pub const onchange = bridge.accessor(handlerAccessor(.onchange).get, handlerAccessor(.onchange).set, .{});
    pub const onclick = bridge.accessor(handlerAccessor(.onclick).get, handlerAccessor(.onclick).set, .{});
    pub const onclose = bridge.accessor(handlerAccessor(.onclose).get, handlerAccessor(.onclose).set, .{});
    pub const oncommand = bridge.accessor(handlerAccessor(.oncommand).get, handlerAccessor(.oncommand).set, .{});
    pub const oncontentvisibilityautostatechange = bridge.accessor(handlerAccessor(.oncontentvisibilityautostatechange).get, handlerAccessor(.oncontentvisibilityautostatechange).set, .{});
    pub const oncontextlost = bridge.accessor(handlerAccessor(.oncontextlost).get, handlerAccessor(.oncontextlost).set, .{});
    pub const oncontextmenu = bridge.accessor(handlerAccessor(.oncontextmenu).get, handlerAccessor(.oncontextmenu).set, .{});
    pub const oncontextrestored = bridge.accessor(handlerAccessor(.oncontextrestored).get, handlerAccessor(.oncontextrestored).set, .{});
    pub const oncuechange = bridge.accessor(handlerAccessor(.oncuechange).get, handlerAccessor(.oncuechange).set, .{});
    pub const ondblclick = bridge.accessor(handlerAccessor(.ondblclick).get, handlerAccessor(.ondblclick).set, .{});
    pub const ondrag = bridge.accessor(handlerAccessor(.ondrag).get, handlerAccessor(.ondrag).set, .{});
    pub const ondragend = bridge.accessor(handlerAccessor(.ondragend).get, handlerAccessor(.ondragend).set, .{});
    pub const ondragenter = bridge.accessor(handlerAccessor(.ondragenter).get, handlerAccessor(.ondragenter).set, .{});
    pub const ondragleave = bridge.accessor(handlerAccessor(.ondragleave).get, handlerAccessor(.ondragleave).set, .{});
    pub const ondragover = bridge.accessor(handlerAccessor(.ondragover).get, handlerAccessor(.ondragover).set, .{});
    pub const ondragstart = bridge.accessor(handlerAccessor(.ondragstart).get, handlerAccessor(.ondragstart).set, .{});
    pub const ondrop = bridge.accessor(handlerAccessor(.ondrop).get, handlerAccessor(.ondrop).set, .{});
    pub const ondurationchange = bridge.accessor(handlerAccessor(.ondurationchange).get, handlerAccessor(.ondurationchange).set, .{});
    pub const onemptied = bridge.accessor(handlerAccessor(.onemptied).get, handlerAccessor(.onemptied).set, .{});
    pub const onended = bridge.accessor(handlerAccessor(.onended).get, handlerAccessor(.onended).set, .{});
    pub const onerror = bridge.accessor(handlerAccessor(.onerror).get, handlerAccessor(.onerror).set, .{});
    pub const onfocus = bridge.accessor(handlerAccessor(.onfocus).get, handlerAccessor(.onfocus).set, .{});
    pub const onformdata = bridge.accessor(handlerAccessor(.onformdata).get, handlerAccessor(.onformdata).set, .{});
    pub const oninput = bridge.accessor(handlerAccessor(.oninput).get, handlerAccessor(.oninput).set, .{});
    pub const oninvalid = bridge.accessor(handlerAccessor(.oninvalid).get, handlerAccessor(.oninvalid).set, .{});
    pub const onkeydown = bridge.accessor(handlerAccessor(.onkeydown).get, handlerAccessor(.onkeydown).set, .{});
    pub const onkeypress = bridge.accessor(handlerAccessor(.onkeypress).get, handlerAccessor(.onkeypress).set, .{});
    pub const onkeyup = bridge.accessor(handlerAccessor(.onkeyup).get, handlerAccessor(.onkeyup).set, .{});
    pub const onload = bridge.accessor(handlerAccessor(.onload).get, handlerAccessor(.onload).set, .{});
    pub const onloadeddata = bridge.accessor(handlerAccessor(.onloadeddata).get, handlerAccessor(.onloadeddata).set, .{});
    pub const onloadedmetadata = bridge.accessor(handlerAccessor(.onloadedmetadata).get, handlerAccessor(.onloadedmetadata).set, .{});
    pub const onloadstart = bridge.accessor(handlerAccessor(.onloadstart).get, handlerAccessor(.onloadstart).set, .{});
    pub const onmousedown = bridge.accessor(handlerAccessor(.onmousedown).get, handlerAccessor(.onmousedown).set, .{});
    pub const onmouseenter = bridge.accessor(handlerAccessor(.onmouseenter).get, handlerAccessor(.onmouseenter).set, .{});
    pub const onmouseleave = bridge.accessor(handlerAccessor(.onmouseleave).get, handlerAccessor(.onmouseleave).set, .{});
    pub const onmousemove = bridge.accessor(handlerAccessor(.onmousemove).get, handlerAccessor(.onmousemove).set, .{});
    pub const onmouseout = bridge.accessor(handlerAccessor(.onmouseout).get, handlerAccessor(.onmouseout).set, .{});
    pub const onmouseover = bridge.accessor(handlerAccessor(.onmouseover).get, handlerAccessor(.onmouseover).set, .{});
    pub const onmouseup = bridge.accessor(handlerAccessor(.onmouseup).get, handlerAccessor(.onmouseup).set, .{});
    pub const onmousewheel = bridge.accessor(handlerAccessor(.onmousewheel).get, handlerAccessor(.onmousewheel).set, .{});
    pub const onpause = bridge.accessor(handlerAccessor(.onpause).get, handlerAccessor(.onpause).set, .{});
    pub const onplay = bridge.accessor(handlerAccessor(.onplay).get, handlerAccessor(.onplay).set, .{});
    pub const onplaying = bridge.accessor(handlerAccessor(.onplaying).get, handlerAccessor(.onplaying).set, .{});
    pub const onprogress = bridge.accessor(handlerAccessor(.onprogress).get, handlerAccessor(.onprogress).set, .{});
    pub const onratechange = bridge.accessor(handlerAccessor(.onratechange).get, handlerAccessor(.onratechange).set, .{});
    pub const onreset = bridge.accessor(handlerAccessor(.onreset).get, handlerAccessor(.onreset).set, .{});
    pub const onresize = bridge.accessor(handlerAccessor(.onresize).get, handlerAccessor(.onresize).set, .{});
    pub const onscroll = bridge.accessor(handlerAccessor(.onscroll).get, handlerAccessor(.onscroll).set, .{});
    pub const onscrollend = bridge.accessor(handlerAccessor(.onscrollend).get, handlerAccessor(.onscrollend).set, .{});
    pub const onsecuritypolicyviolation = bridge.accessor(handlerAccessor(.onsecuritypolicyviolation).get, handlerAccessor(.onsecuritypolicyviolation).set, .{});
    pub const onseeked = bridge.accessor(handlerAccessor(.onseeked).get, handlerAccessor(.onseeked).set, .{});
    pub const onseeking = bridge.accessor(handlerAccessor(.onseeking).get, handlerAccessor(.onseeking).set, .{});
    pub const onselect = bridge.accessor(handlerAccessor(.onselect).get, handlerAccessor(.onselect).set, .{});
    pub const onslotchange = bridge.accessor(handlerAccessor(.onslotchange).get, handlerAccessor(.onslotchange).set, .{});
    pub const onstalled = bridge.accessor(handlerAccessor(.onstalled).get, handlerAccessor(.onstalled).set, .{});
    pub const onsubmit = bridge.accessor(handlerAccessor(.onsubmit).get, handlerAccessor(.onsubmit).set, .{});
    pub const onsuspend = bridge.accessor(handlerAccessor(.onsuspend).get, handlerAccessor(.onsuspend).set, .{});
    pub const ontimeupdate = bridge.accessor(handlerAccessor(.ontimeupdate).get, handlerAccessor(.ontimeupdate).set, .{});
    pub const ontoggle = bridge.accessor(handlerAccessor(.ontoggle).get, handlerAccessor(.ontoggle).set, .{});
    pub const onvolumechange = bridge.accessor(handlerAccessor(.onvolumechange).get, handlerAccessor(.onvolumechange).set, .{});
    pub const onwaiting = bridge.accessor(handlerAccessor(.onwaiting).get, handlerAccessor(.onwaiting).set, .{});
    pub const onwebkitanimationend = bridge.accessor(handlerAccessor(.onwebkitanimationend).get, handlerAccessor(.onwebkitanimationend).set, .{});
    pub const onwebkitanimationiteration = bridge.accessor(handlerAccessor(.onwebkitanimationiteration).get, handlerAccessor(.onwebkitanimationiteration).set, .{});
    pub const onwebkitanimationstart = bridge.accessor(handlerAccessor(.onwebkitanimationstart).get, handlerAccessor(.onwebkitanimationstart).set, .{});
    pub const onwebkittransitionend = bridge.accessor(handlerAccessor(.onwebkittransitionend).get, handlerAccessor(.onwebkittransitionend).set, .{});
    pub const onwheel = bridge.accessor(handlerAccessor(.onwheel).get, handlerAccessor(.onwheel).set, .{});
    pub const onauxclick = bridge.accessor(handlerAccessor(.onauxclick).get, handlerAccessor(.onauxclick).set, .{});
    pub const ongotpointercapture = bridge.accessor(handlerAccessor(.ongotpointercapture).get, handlerAccessor(.ongotpointercapture).set, .{});
    pub const onlostpointercapture = bridge.accessor(handlerAccessor(.onlostpointercapture).get, handlerAccessor(.onlostpointercapture).set, .{});
    pub const onpointerdown = bridge.accessor(handlerAccessor(.onpointerdown).get, handlerAccessor(.onpointerdown).set, .{});
    pub const onpointermove = bridge.accessor(handlerAccessor(.onpointermove).get, handlerAccessor(.onpointermove).set, .{});
    pub const onpointerup = bridge.accessor(handlerAccessor(.onpointerup).get, handlerAccessor(.onpointerup).set, .{});
    pub const onpointercancel = bridge.accessor(handlerAccessor(.onpointercancel).get, handlerAccessor(.onpointercancel).set, .{});
    pub const onpointerover = bridge.accessor(handlerAccessor(.onpointerover).get, handlerAccessor(.onpointerover).set, .{});
    pub const onpointerout = bridge.accessor(handlerAccessor(.onpointerout).get, handlerAccessor(.onpointerout).set, .{});
    pub const onpointerenter = bridge.accessor(handlerAccessor(.onpointerenter).get, handlerAccessor(.onpointerenter).set, .{});
    pub const onpointerleave = bridge.accessor(handlerAccessor(.onpointerleave).get, handlerAccessor(.onpointerleave).set, .{});
    pub const onselectstart = bridge.accessor(handlerAccessor(.onselectstart).get, handlerAccessor(.onselectstart).set, .{});
    pub const onselectionchange = bridge.accessor(handlerProperty(Document, .onselectionchange).get, handlerProperty(Document, .onselectionchange).set, .{});
    pub const onanimationcancel = bridge.accessor(handlerAccessor(.onanimationcancel).get, handlerAccessor(.onanimationcancel).set, .{});
    pub const onanimationend = bridge.accessor(handlerAccessor(.onanimationend).get, handlerAccessor(.onanimationend).set, .{});
    pub const onanimationiteration = bridge.accessor(handlerAccessor(.onanimationiteration).get, handlerAccessor(.onanimationiteration).set, .{});
    pub const onanimationstart = bridge.accessor(handlerAccessor(.onanimationstart).get, handlerAccessor(.onanimationstart).set, .{});
    pub const ontransitionrun = bridge.accessor(handlerAccessor(.ontransitionrun).get, handlerAccessor(.ontransitionrun).set, .{});
    pub const ontransitionstart = bridge.accessor(handlerAccessor(.ontransitionstart).get, handlerAccessor(.ontransitionstart).set, .{});
    pub const ontransitionend = bridge.accessor(handlerAccessor(.ontransitionend).get, handlerAccessor(.ontransitionend).set, .{});
    pub const ontransitioncancel = bridge.accessor(handlerAccessor(.ontransitioncancel).get, handlerAccessor(.ontransitioncancel).set, .{});
    pub const onbeforexrselect = bridge.accessor(handlerAccessor(.onbeforexrselect).get, handlerAccessor(.onbeforexrselect).set, .{});
    pub const oncopy = bridge.accessor(handlerAccessor(.oncopy).get, handlerAccessor(.oncopy).set, .{});
    pub const oncut = bridge.accessor(handlerAccessor(.oncut).get, handlerAccessor(.oncut).set, .{});
    pub const onpaste = bridge.accessor(handlerAccessor(.onpaste).get, handlerAccessor(.onpaste).set, .{});
    pub const children = bridge.accessor(Document.getChildren, null, .{});
    pub const firstElementChild = bridge.accessor(Document.getFirstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Document.getLastElementChild, null, .{});
    pub const childElementCount = bridge.accessor(Document.getChildElementCount, null, .{});
    pub const activeElement = bridge.accessor(Document.getActiveElement, null, .{});
    pub const styleSheets = bridge.accessor(Document.getStyleSheets, null, .{});
    pub const pointerLockElement = bridge.accessor(Document.getFullscreenElement, null, .{});
    pub const fullscreenElement = bridge.accessor(Document.getFullscreenElement, Document.setLeniently, .{});
    pub const adoptedStyleSheets = bridge.accessor(Document.getAdoptedStyleSheets, Document.setAdoptedStyleSheets, .{});
    pub const pictureInPictureElement = bridge.accessor(Document.getFullscreenElement, null, .{});
    pub const fonts = bridge.accessor(Document.getFonts, null, .{});

    // `[LegacyUnforgeable]`: Chrome puts this on every document instance, not on
    // Document.prototype. Measured descriptor: enumerable, non-configurable,
    // get+set.
    pub const location = bridge.accessor(Document.getLocation, Document.setLocation, .{ .unforgeable = true, .deletable = false });

    // Operations, alphabetical, as WebIDL requires and Chrome emits.
    pub const adoptNode = bridge.function(Document.adoptNode, .{ .ce_reactions = true });
    pub const append = bridge.function(Document.append, .{ .ce_reactions = true, .arity = 0 });
    pub const captureEvents = bridge.function(Document.captureEvents, .{});
    pub const caretPositionFromPoint = bridge.function(Document.caretPositionFromPoint, .{});
    pub const caretRangeFromPoint = bridge.function(Document.caretRangeFromPoint, .{});
    pub const clear = bridge.function(Document.clear, .{});
    pub const close = bridge.function(Document.close, .{ .ce_reactions = true });
    pub const createAttribute = bridge.function(Document.createAttribute, .{});
    pub const createAttributeNS = bridge.function(Document.createAttributeNS, .{});
    pub const createCDATASection = bridge.function(Document.createCDATASection, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createElement = bridge.function(Document.createElement, .{});
    pub const createElementNS = bridge.function(Document.createElementNS, .{ .arity = 2 });
    pub const createEvent = bridge.function(Document.createEvent, .{});
    pub const createExpression = bridge.function(Document.createExpression, .{});
    pub const createNSResolver = bridge.function(Document.createNSResolver, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const createProcessingInstruction = bridge.function(Document.createProcessingInstruction, .{});
    pub const createRange = bridge.function(Document.createRange, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const elementFromPoint = bridge.function(Document.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(Document.elementsFromPoint, .{});
    pub const evaluate = bridge.function(Document.evaluate, .{ .arity = 2 });
    pub const execCommand = bridge.function(Document.execCommand, .{});
    pub const exitFullscreen = bridge.function(Document.exitFullscreen, .{});
    pub const exitPictureInPicture = bridge.function(Document.exitPictureInPicture, .{});
    pub const exitPointerLock = bridge.function(Document.exitPointerLock, .{});
    pub const getAnimations = bridge.function(Document.getAnimations, .{});
    pub const getElementById = bridge.function(_getElementById, .{ .arity = 1 });
    fn _getElementById(self: *Document, value_: ?js.Value, frame: *Frame) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) {
            return self.getElementById("null", frame);
        }
        if (value.isUndefined()) {
            return self.getElementById("undefined", frame);
        }
        return self.getElementById(try value.toZig([]const u8), frame);
    }
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
    pub const getElementsByName = bridge.function(Document.getElementsByName, .{});
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Document.getElementsByTagNameNS, .{ .arity = 2 });
    pub const getSelection = bridge.function(Document.getSelection, .{});
    pub const hasFocus = bridge.function(Document.hasFocus, .{});
    pub const hasStorageAccess = bridge.function(Document.hasStorageAccess, .{});
    pub const hasUnpartitionedCookieAccess = bridge.function(Document.hasStorageAccess, .{});
    pub const importNode = bridge.function(Document.importNode, .{ .ce_reactions = true });
    pub const moveBefore = bridge.function(Document.moveBefore, .{ .ce_reactions = true });
    pub const open = bridge.function(Document.open, .{ .ce_reactions = true });
    pub const prepend = bridge.function(Document.prepend, .{ .ce_reactions = true, .arity = 0 });
    pub const queryCommandEnabled = bridge.function(Document.queryCommandEnabled, .{});
    pub const queryCommandIndeterm = bridge.function(Document.queryCommandIndeterm, .{});
    pub const queryCommandState = bridge.function(Document.queryCommandState, .{});
    pub const queryCommandSupported = bridge.function(Document.queryCommandSupported, .{});
    pub const queryCommandValue = bridge.function(Document.queryCommandValue, .{});
    pub const querySelector = bridge.function(Document.querySelector, .{});
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{});
    pub const releaseEvents = bridge.function(Document.releaseEvents, .{});
    pub const replaceChildren = bridge.function(Document.replaceChildren, .{ .ce_reactions = true, .arity = 0 });
    pub const requestStorageAccess = bridge.function(Document.requestStorageAccess, .{});
    pub const requestStorageAccessFor = bridge.function(Document.requestStorageAccessFor, .{});
    pub const startViewTransition = bridge.function(Document.startViewTransition, .{});
    pub const webkitCancelFullScreen = bridge.function(Document.webkitCancelFullScreen, .{});
    pub const webkitExitFullscreen = bridge.function(Document.webkitExitFullscreen, .{});
    pub const write = bridge.function(Document.write, .{ .ce_reactions = true, .arity = 0 });
    pub const writeln = bridge.function(Document.writeln, .{ .ce_reactions = true, .arity = 0 });

    // Chrome emits these after `constructor`, i.e. after the main IDL block:
    // they are runtime-enabled features, appended as they are switched on.
    pub const fragmentDirective = bridge.accessor(Document.getFragmentDirective, null, .{});
    pub const onpointerrawupdate = bridge.accessor(handlerAccessor(.onpointerrawupdate).get, handlerAccessor(.onpointerrawupdate).set, .{});
    pub const browsingTopics = bridge.function(Document.browsingTopics, .{});
    pub const hasPrivateToken = bridge.function(Document.hasPrivateToken, .{});
    pub const hasRedemptionRecord = bridge.function(Document.hasRedemptionRecord, .{});
    pub const activeViewTransition = bridge.accessor(Document.getActiveViewTransition, null, .{});
    pub const onscrollsnapchange = bridge.accessor(handlerAccessor(.onscrollsnapchange).get, handlerAccessor(.onscrollsnapchange).set, .{});
    pub const onscrollsnapchanging = bridge.accessor(handlerAccessor(.onscrollsnapchanging).get, handlerAccessor(.onscrollsnapchanging).set, .{});
    pub const customElementRegistry = bridge.accessor(Document.getCustomElementRegistry, null, .{});
    pub const ariaNotify = bridge.function(Document.ariaNotify, .{});

    /// `document.myForm`; see Document.NamedObjectAccess.
    const named_objects = Document.NamedObjectAccess(Document);
    pub const @"[str]" = bridge.namedIndexedFull(named_objects.get, null, named_objects.delete, named_objects.names, named_objects.query, named_objects.define, null, .{ .null_as_undefined = true, .masking = true });

    fn getCharacterSet(self: *const Document) []const u8 {
        return self.getCharset();
    }

    // The colour properties are attribute reflections on <body>, with no colour
    // parsing in either direction: whatever string goes in comes back out. The
    // property-to-attribute mapping was measured, since the names do not line up
    // (fgColor is `text`, not `fgcolor`).
    fn colorAccessor(comptime attribute: []const u8) type {
        return struct {
            pub fn get(self: *Document) []const u8 {
                const body_element = self.getBody() orelse return "";
                return body_element.asElement().getAttributeSafe(comptime .wrap(attribute)) orelse "";
            }

            pub fn set(self: *Document, value: []const u8, frame: *Frame) !void {
                const body_element = self.getBody() orelse return;
                try body_element.asElement().setAttributeSafe(comptime .wrap(attribute), .wrap(value), frame);
            }
        };
    }

    // Generates a getter/setter pair backed by the frame's attribute-listener
    // map, like onclick above, for other document event handler properties.
    fn handlerAccessor(comptime handler: @import("global_event_handlers.zig").Handler) type {
        return struct {
            pub fn get(self: *Document, frame: *Frame) ?js.Function.Global {
                const owner = self._frame orelse frame;
                return owner.getEventHandler(self.asEventTarget(), handler);
            }

            pub fn set(self: *Document, setter: ?Window.FunctionSetter, frame: *Frame) !void {
                const owner = self._frame orelse frame;
                return owner.setEventHandler(self.asEventTarget(), handler, Window.getFunctionFromSetter(setter));
            }
        };
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}

test "WebApi: Document.evaluate" {
    try testing.htmlRunner("xpath/document_evaluate.html", .{});
}

test "Document: isRelaxableTo" {
    // Pure opt-in (relax to self) is always allowed, including IP hosts.
    try testing.expectEqual(true, isRelaxableTo("a.example.com", "a.example.com"));
    try testing.expectEqual(true, isRelaxableTo("127.0.0.1", "127.0.0.1"));

    // Relaxing to a registrable superdomain.
    try testing.expectEqual(true, isRelaxableTo("a.example.com", "example.com"));
    try testing.expectEqual(true, isRelaxableTo("a.b.example.com", "example.com"));
    try testing.expectEqual(true, isRelaxableTo("a.b.example.com", "b.example.com"));

    // Bare TLDs (single label) are never registrable. Multi-label public
    // suffixes are rejected via the PSL — note the test build stubs the PSL
    // to {gov.uk, api.gov.uk}, so those are the entries exercised here.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "com"));
    try testing.expectEqual(false, isRelaxableTo("foo.gov.uk", "gov.uk"));
    try testing.expectEqual(false, isRelaxableTo("a.api.gov.uk", "api.gov.uk"));
    // ...but a registrable domain sitting under that suffix is fine.
    try testing.expectEqual(true, isRelaxableTo("a.dept.gov.uk", "dept.gov.uk"));

    // Must be a label-boundary suffix, not a substring suffix.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "ample.com"));
    try testing.expectEqual(false, isRelaxableTo("notexample.com", "example.com"));

    // Unrelated domain, and the empty string.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "example.org"));
    try testing.expectEqual(false, isRelaxableTo("a.example.com", ""));
}
