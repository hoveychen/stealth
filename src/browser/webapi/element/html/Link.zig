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
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const HtmlElement = @import("../Html.zig");

const Link = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
// Cached CSSStyleSheet for an external `rel=stylesheet` once
// `Frame.loadExternalStylesheet` has registered it. Re-fetches (href
// mutated on a connected link) reuse this sheet via `replaceSync` so the
// old rules are dropped instead of accumulating in `document.styleSheets`.
// Mirrors `Style._sheet`.
_sheet: ?*@import("../../css/CSSStyleSheet.zig") = null,

pub fn asElement(self: *Link) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Link) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Link) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Link, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeInterned("href") orelse return "";
    if (href.len == 0) {
        return "";
    }
    return element.asNode().resolveURLReflect(href, frame, .{});
}

pub fn setHref(self: *Link, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);

    if (element.asNode().isConnected()) {
        try self.linkAddedCallback(frame);
    }
}

pub fn getRel(self: *Link) []const u8 {
    return self.asElement().getAttributeInterned("rel") orelse return "";
}

pub fn setRel(self: *Link, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rel"), .wrap(value), frame);
}

pub fn getMedia(self: *Link) []const u8 {
    return self.asElement().getAttributeInterned("media") orelse return "";
}

pub fn setMedia(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
}

pub fn getSizes(self: *Link, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    if (element._namespace != .html) {
        return null;
    }
    return element.getTokenList(.sizes, frame);
}

pub fn getRelList(self: *Link, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    // relList is only valid for HTML <link> elements, not SVG or MathML
    if (element._namespace != .html) {
        return null;
    }
    return element.getRelList(frame);
}

/// `[PutForwards=value]`: the setter assigns to the DOMTokenList's `value`, so
/// the `rel` content attribute moves and the list object stays the same one.
/// The point is the descriptor: with a setter it reads as an accessor, which is
/// what Chrome exposes and what a bot check reads. See
/// src/browser/tests/descriptor_kind.html.
pub fn setRelList(self: *Link, value: lp.String, frame: *Frame) !void {
    const list = (try self.getRelList(frame)) orelse return;
    try list.setValue(value, frame);
}

pub fn linkAddedCallback(self: *Link, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();

    const href = element.getAttributeInterned("href") orelse return;
    if (href.len == 0) {
        return;
    }

    const rel = element.getAttributeInterned("rel") orelse return;

    // Opt-in fetch for `rel="stylesheet"` — drives `frame.loadExternalStylesheet`,
    // which fires the load/error event itself.
    if (std.mem.eql(u8, rel, "stylesheet")) {
        return frame.loadExternalStylesheet(self, href);
    }

    if (std.mem.eql(u8, rel, "preload")) {
        const as = element.getAttributeSafe(comptime .wrap("as")) orelse "";
        if (std.ascii.eqlIgnoreCase(as, "script")) {
            if (Frame.preload.scriptHint(frame, Factory.protoOf(self), href)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // A preload is a REQUEST, not a declaration: the browser fetches what
        // the link names and warms its cache, and the destination of that
        // request is the `as` value. Only `as=script` was ever fetched here;
        // everything else fired the synthetic load below and asked for nothing,
        // so a page preloading its hero image made one fewer request than
        // Chrome, visible in the site's own log with no script running.
        //
        // Measured (probes/b87-preload-as-fixture.mjs, eight `as` values):
        // Chrome fetches image, style, script, font and fetch, and ignores
        // document, audio and video.
        if (preloadDestination(as)) |dest| {
            if (frame.preloadResource(Factory.protoOf(self), href, dest)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // synthetic load, fires next tick
        return frame.queueLoad(Factory.protoOf(self));
    }

    // Two more rels that are a REQUEST rather than a declaration, for the same
    // reason `preload` above is: Chrome fetches both, and a client that never
    // asks for the manifest a page declares is separable in the site's own log
    // with no script running (tools/fingerprint/wire-census.mjs). Neither has
    // anywhere to go afterwards -- nothing here installs an app or warms a
    // cache -- so the bytes are discarded, as with `Frame.loadImage`.
    if (std.ascii.eqlIgnoreCase(rel, "manifest") or std.ascii.eqlIgnoreCase(rel, "prefetch")) {
        frame.requestElementResource(href, .fetch, "link");
        return;
    }

    if (std.mem.eql(u8, rel, "modulepreload")) {
        // "as" defaults to script in this case
        const as = element.getAttributeSafe(comptime .wrap("as")) orelse "";
        if (as.len == 0 or std.ascii.eqlIgnoreCase(as, "script")) {
            if (Frame.preload.moduleHint(frame, Factory.protoOf(self), href)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // synthetic load, fires next tick
        return frame.queueLoad(Factory.protoOf(self));
    }
}

// The request a `<link rel=preload as=...>` makes, or null when Chrome makes
// none. `as` is ASCII-case-insensitive, like every other enumerated attribute.
//
// `script` is absent on purpose: it goes through the script preloader above,
// which can hand the bytes to the <script> that consumes them. `document`,
// `audio` and `video` are absent because Chrome asks for nothing for them
// (measured, probes/b87-preload-as-fixture.mjs).
fn preloadDestination(as: []const u8) ?Frame.SubresourceOpts {
    if (std.ascii.eqlIgnoreCase(as, "image")) {
        // A bare `i`, not the `u=1, i` a displayed <img> carries: a preloaded
        // image is not on screen, so it never gets an image's urgency
        // (measured over h2, probes/b87-preload-priority-h2.mjs).
        return .{ .resource_type = .image, .priority = "i", .initiator = "link", .sniff = false };
    }
    if (std.ascii.eqlIgnoreCase(as, "font")) {
        return .{ .resource_type = .font, .initiator = "link", .sniff = false };
    }
    if (std.ascii.eqlIgnoreCase(as, "style")) {
        return .{ .resource_type = .stylesheet, .initiator = "link", .sniff = false };
    }
    if (std.ascii.eqlIgnoreCase(as, "fetch")) {
        // Destination `empty`, the same as a real fetch() -- but no-cors, where
        // a real fetch() is always cors. Measured; hence the mode override.
        return .{ .resource_type = .fetch, .mode = .no_cors, .initiator = "link", .sniff = false };
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Link);

    pub const Meta = struct {
        pub const name = "HTMLLinkElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Link);

    // Chrome's order. No `nonce`: that one is HTMLElement's, from the
    // HTMLOrSVGElement mixin (measured).
    pub const disabled = reflect.boolean("disabled");
    pub const href = bridge.accessor(Link.getHref, Link.setHref, .{ .ce_reactions = true });
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const rel = bridge.accessor(Link.getRel, Link.setRel, .{ .ce_reactions = true });
    pub const relList = bridge.accessor(Link.getRelList, Link.setRelList, .{ .null_as_undefined = true, .ce_reactions = true });
    pub const media = bridge.accessor(Link.getMedia, Link.setMedia, .{ .ce_reactions = true });
    pub const hreflang = reflect.string("hreflang");
    pub const @"type" = reflect.string("type");
    pub const as = reflect.enumerated("as", &.{ "fetch", "audio", "document", "embed", "font", "image", "manifest", "object", "report", "script", "sharedworker", "style", "track", "video", "worker", "xslt" }, .{});
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const sizes = bridge.accessor(Link.getSizes, null, .{ .null_as_undefined = true });
    pub const fetchPriority = reflect.enumerated("fetchpriority", &.{ "high", "low" }, .{ .missing = "auto" });
    pub const imageSrcset = reflect.string("imagesrcset");
    pub const imageSizes = reflect.string("imagesizes");
    pub const charset = reflect.string("charset");
    pub const rev = reflect.string("rev");
    pub const target = reflect.string("target");

    // Nothing here builds a CSSStyleSheet for a <link>, and Chrome answers
    // null for a link whose stylesheet has not loaded, which is the honest
    // answer to give (measured on a fresh `document.createElement('link')`).
    pub const sheet = bridge.accessor(_sheet, null, .{});
    fn _sheet(_: *Link) ?*@import("../../css/CSSStyleSheet.zig") {
        return null;
    }

    pub const integrity = reflect.string("integrity");
    pub const blocking = reflect.tokenList(.blocking);
};

// Parser-created <link> elements are void (no closing tag) so they never
// reach `Frame.nodeComplete`. Mirror `Image.Build.created` so static head
// links in HTML go through `linkAddedCallback` at element-create time,
// with attributes already populated by `populateElementAttributes`.
pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Link);
        return self.linkAddedCallback(frame);
    }
};

const testing = @import("../../../../testing.zig");
// The fixture is about the <link> element itself -- its reflected attributes,
// its load events, and what it does NOT fetch -- so it runs with external
// stylesheets off. Off is not this fork's default (see Config.LoadResources),
// which is exactly why it has to be said here: on, `rel=stylesheet` really
// goes to the network and the `/nope` hrefs the fixture uses to prove a link
// stays quiet would be real requests.
test "WebApi: HTML.Link" {
    try testing.htmlRunner("element/html/link.html", .{ .load_resources = .{ .stylesheet = false, .worker = true, .iframe = true } });
}

// The stylesheet preload is a real fetch, so the runner has to be told to make
// it: it leaves external stylesheets off by default.
test "WebApi: HTML.Link preload fetches what it names" {
    testing.silenceLog(&.{.http});
    try testing.htmlRunner("element/html/link_preload.html", .{ .load_resources = .{ .stylesheet = true, .worker = true, .iframe = true } });
}

test "WebApi: HTML.Link external stylesheet" {
    testing.silenceLog(&.{.http});
    try testing.htmlRunner("css/external_stylesheet.html", .{ .load_resources = .{ .stylesheet = true } });
}

// Regression: a synchronous external-stylesheet fetch must not strand the
// completion of an in-flight <script defer> (held back by the blocking-
// request gate during the sync window). Otherwise the deferred-script queue
// never drains and the document is stuck at readyState "loading".
test "WebApi: HTML.Link deferred script then external stylesheet" {
    testing.silenceLog(&.{.http});
    try testing.htmlRunner("css/deferred_script_then_stylesheet.html", .{ .load_resources = .{ .stylesheet = true } });
}
