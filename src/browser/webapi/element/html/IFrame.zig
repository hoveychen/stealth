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
const Window = @import("../../Window.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;
const document_services = @import("../../document/services.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;
const IFrame = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_src: []const u8 = "",
_feature_policy: ?*document_services.FeaturePolicy = null,
_executed: bool = false,
_window: ?*Window = null,

pub fn asElement(self: *IFrame) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *IFrame) *Node {
    return self.asElement().asNode();
}

pub fn getContentWindow(self: *const IFrame, frame: *Frame) ?Window.Access {
    const frame_window = self._window orelse return null;
    return Window.Access.init(frame.window, frame_window);
}

// Null when the child is cross-origin. contentWindow next to this one goes
// through Window.Access, which hands a cross-origin caller the safelisted proxy;
// this took no `frame` at all and returned the live Document, so every guard the
// proxy puts up was reachable around it -- `f.contentDocument.cookie`,
// `.defaultView`, and from there the whole other realm. Measured on Chrome 151:
// null (scratch/expr-cross-origin-proxy-shape.js).
pub fn getContentDocument(self: *const IFrame, frame: *Frame) ?*Document {
    const window = self._window orelse return null;
    return switch (Window.Access.init(frame.window, window)) {
        .window => |w| w._document,
        .cross_origin => null,
    };
}

/// The child's document without the origin check, for the engine's own readers
/// rather than a script's. `--dump` writes the whole page including its frames,
/// and it is not a caller the same-origin policy is about.
pub fn contentDocumentUnchecked(self: *const IFrame) ?*Document {
    const window = self._window orelse return null;
    return window._document;
}

// loading=lazy iframes are still but don't delay the page's "load" event
pub fn isLazyLoading(self: *IFrame) bool {
    const loading = self.asElement().getAttributeInterned("loading") orelse return false;
    return std.ascii.eqlIgnoreCase(loading, "lazy");
}

pub fn getSrc(self: *IFrame, frame: *Frame) ![]const u8 {
    if (self._src.len == 0) return "";
    return self.asNode().resolveURLReflect(self._src, frame, .{});
}

pub fn setSrc(self: *IFrame, src: []const u8, frame: *Frame) !void {
    // Build.attributeChange resyncs _src and triggers the (re)navigation, so
    // that setAttribute('src', …) — which is how Turnstile points its widget
    // frame — behaves exactly like assigning .src.
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(src), frame);
}

pub fn hasSrcdoc(self: *IFrame) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("srcdoc")) != null;
}

pub fn getSrcdoc(self: *IFrame) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("srcdoc")) orelse "";
}

pub fn setSrcdoc(self: *IFrame, value: []const u8, frame: *Frame) !void {
    // Build.attributeChange triggers the (re)navigation.
    try self.asElement().setAttributeSafe(comptime .wrap("srcdoc"), .wrap(value), frame);
}

pub fn getSandbox(self: *IFrame, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    if (element._namespace != .html) {
        return null;
    }
    return element.getTokenList(.sandbox, frame);
}

/// `[PutForwards=value]`: `sandbox` is a readonly DOMTokenList whose setter
/// assigns to the list's `value`, so the content attribute moves and the list
/// object stays the same one. That makes the descriptor an accessor with both
/// halves, which is what a bot check reads -- and Chrome behaves exactly this
/// way (measured, probe-setter-semantics). Same shape as Element.setClassList.
pub fn setSandbox(self: *IFrame, value: String, frame: *Frame) !void {
    const list = (try self.getSandbox(frame)) orelse return;
    try list.setValue(value, frame);
}

/// Chrome hands back the same FeaturePolicy object every time (measured), so
/// it is created once and cached on the element. It answers over this
/// document's policy, which is the same object shape `document.featurePolicy`
/// hands out.
pub fn getFeaturePolicy(self: *IFrame, frame: *Frame) !*document_services.FeaturePolicy {
    if (self._feature_policy) |existing| return existing;
    const created = try frame._factory.create(document_services.FeaturePolicy{});
    self._feature_policy = created;
    return created;
}

/// An `<iframe>` whose document is not an SVG document answers null, which is
/// every iframe this engine produces and also every one Chrome produces from a
/// plain `document.createElement('iframe')`, attached or not (measured).
pub fn getSVGDocument(_: *IFrame) ?*Document {
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IFrame);

    pub const Meta = struct {
        pub const name = "HTMLIFrameElement";
        pub const constructor_after = "allowPaymentRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own-property order (measured). It is not the order this file
    // used to carry, and the interstitial that led here reads `contentWindow`
    // 18 times and `contentDocument` three times per round, so the walk that
    // finds them is a walk over this list.
    const reflect = Element.Reflect(IFrame);
    pub const src = bridge.accessor(IFrame.getSrc, IFrame.setSrc, .{ .ce_reactions = true });
    pub const srcdoc = bridge.accessor(IFrame.getSrcdoc, IFrame.setSrcdoc, .{ .ce_reactions = true });
    pub const name = reflect.string("name");
    pub const sandbox = bridge.accessor(IFrame.getSandbox, IFrame.setSandbox, .{ .null_as_undefined = true, .ce_reactions = true });
    pub const allowFullscreen = reflect.boolean("allowfullscreen");
    pub const width = reflect.string("width");
    pub const height = reflect.string("height");
    pub const contentDocument = bridge.accessor(IFrame.getContentDocument, null, .{});
    pub const contentWindow = bridge.accessor(IFrame.getContentWindow, null, .{});
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const csp = reflect.string("csp");
    pub const allow = reflect.string("allow");
    pub const featurePolicy = bridge.accessor(IFrame.getFeaturePolicy, null, .{});

    /// The missing-value default is `auto`, not `eager` -- an iframe and an
    /// image disagree about this, and `<video>`'s is `eager` again (measured;
    /// see Media.zig). An unknown keyword reads back as `auto` while the
    /// content attribute keeps whatever was written.
    ///
    /// Reflecting it does not make this engine lazy-load anything: an iframe
    /// with `loading=lazy` is still fetched when it is inserted. That is a
    /// deliberate difference, not an oversight -- a headless engine has no
    /// viewport to be outside of -- and it was one before this member existed.
    pub const loading = reflect.enumerated("loading", &.{ "lazy", "eager" }, .{ .missing = "auto", .invalid = "auto" });

    pub const @"align" = reflect.string("align");
    pub const scrolling = reflect.string("scrolling");
    pub const frameBorder = reflect.string("frameborder");
    pub const longDesc = reflect.url("longdesc");
    pub const marginHeight = reflect.stringNullToEmpty("marginheight");
    pub const marginWidth = reflect.stringNullToEmpty("marginwidth");
    pub const getSVGDocument = bridge.function(IFrame.getSVGDocument, .{});
    pub const credentialless = reflect.boolean("credentialless");
    pub const allowPaymentRequest = reflect.boolean("allowpaymentrequest");

    // Everything below `constructor` is installed per context in Blink, which
    // is why Chrome's list has it here rather than at the end.
    pub const privateToken = reflect.string("privatetoken");
    pub const browsingTopics = reflect.boolean("browsingtopics");
    pub const adAuctionHeaders = reflect.boolean("adauctionheaders");
    pub const sharedStorageWritable = reflect.boolean("sharedstoragewritable");
};

pub const Build = struct {
    pub fn complete(node: *Node, _: *Frame) !void {
        const self = node.as(IFrame);
        const element = self.asElement();
        self._src = element.getAttributeInterned("src") orelse "";
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        const is_src = name.eql(comptime .wrap("src"));
        if (!is_src and !name.eql(comptime .wrap("srcdoc"))) {
            return;
        }
        const self = element.as(IFrame);
        if (is_src) {
            self._src = element.getAttributeSafe(comptime .wrap("src")) orelse "";
        }
        if (element.asNode().isConnected()) {
            // unlike script, an iframe is reloaded every time src or srcdoc is
            // set, even if the value didn't change.
            self._executed = false;
            try frame.iframeAddedCallback(self);
        }
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        const is_src = name.eql(comptime .wrap("src"));
        if (!is_src and !name.eql(comptime .wrap("srcdoc"))) {
            return;
        }
        const self = element.as(IFrame);
        if (is_src) {
            self._src = "";
        }
        if (element.asNode().isConnected()) {
            // removing srcdoc falls back to src, removing src to about:blank
            self._executed = false;
            try frame.iframeAddedCallback(self);
        }
    }
};
