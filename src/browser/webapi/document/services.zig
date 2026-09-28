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

// The objects hanging off Document that are plain interfaces: the animation
// timeline, the permissions-policy view, the fragment directive, view
// transitions and caret positions. Chrome 150 has all of them and we had none,
// which left the Document members that return them unimplementable and the
// matching window globals absent.
//
// Shapes, brands, prototype orders, argument counts and return values were
// measured on a headed Chrome 150 over http://localhost. Where a value is a
// stub it says so and says why.
//
// Declaration order inside each JsApi is Chrome's own
// Object.getOwnPropertyNames(X.prototype) order, since that order is itself
// part of what a detector hashes.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");
const Frame = @import("../../Frame.zig");
const permissions_policy = @import("../../permissions_policy.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const DOMRect = @import("../DOMRect.zig");
const DOMException = @import("../DOMException.zig");
const typed_om = @import("../css/typed_om.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        AnimationTimeline,
        DocumentTimeline,
        FeaturePolicy,
        FragmentDirective,
        ViewTransition,
        ViewTransitionTypeSet,
        ViewTransitionTypeSet.KeyIterator,
        ViewTransitionTypeSet.ValueIterator,
        ViewTransitionTypeSet.EntryIterator,
        CaretPosition,
        CSSPseudoElement,
    };
}

// The base of the animation-timeline hierarchy. It is never instantiated
// directly — a document hands out a DocumentTimeline, and a page builds the two
// scroll-driven ones itself — but Chrome exposes the global and puts currentTime
// and duration here rather than on the subclasses, so a detector walking the
// chain sees two levels.
//
// Both of those getters are polymorphic, which is why this struct carries a
// field at all: a document timeline reports a millisecond number and a null
// duration, while a scroll-driven one reports a CSSUnitValue duration of 100%
// and a progress percentage (measured, probe-s5-timelines). Since the flag is
// read through a base pointer, the type cannot be `empty_with_no_proto` —
// TaggedOpaque.fromJS hands an empty struct back for those.
pub const AnimationTimeline = struct {
    _kind: Kind = .document,

    pub const Kind = enum {
        /// document.timeline: a millisecond clock with no intrinsic duration.
        document,
        /// A scroll-driven timeline whose source cannot scroll, which is every
        /// source this engine has. Chrome reports a null currentTime for those
        /// too, so this arm agrees with it rather than approximating it.
        scroll,
        /// A ViewTimeline with a subject, which Chrome reports progress through
        /// whatever the source does. The number is layout and this engine has
        /// none, so it is 0% — but the *type* is the CSSUnitValue Chrome gives.
        view,
    };

    // Three different types out of one getter, which is why this answers a
    // js.Value: milliseconds for a document timeline, null for a scroll-driven
    // one and a percentage for a view timeline (all measured).
    pub fn getCurrentTime(self: *const AnimationTimeline, frame: *Frame) !js.Value {
        const local = frame.js.local.?;
        return switch (self._kind) {
            .document => local.zigValueToJs(frame.window.getPerformance().now(), .{}),
            .scroll => local.zigValueToJs(@as(?f64, null), .{}),
            .view => local.zigValueToJs(try typed_om.CSSUnitValue.create(0, .percent, frame), .{}),
        };
    }

    // Null for a document timeline: it is unbounded, so it has no intrinsic
    // duration. A scroll-driven one is always the whole of its scroll range,
    // reported as a fresh CSSUnitValue of 100% on every read (measured: two
    // reads are not the same object).
    pub fn getDuration(self: *const AnimationTimeline, frame: *Frame) !?*typed_om.CSSUnitValue {
        return switch (self._kind) {
            .document => null,
            .scroll, .view => try typed_om.CSSUnitValue.create(100, .percent, frame),
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AnimationTimeline);

        pub const Meta = struct {
            pub const name = "AnimationTimeline";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const currentTime = bridge.accessor(AnimationTimeline.getCurrentTime, null, .{});
        pub const duration = bridge.accessor(AnimationTimeline.getDuration, null, .{});
    };
};

// document.timeline. Unlike its siblings in this file it is constructible, with
// a zero-length constructor.
pub const DocumentTimeline = struct {
    pub const Proto = AnimationTimeline;

    _proto: *AnimationTimeline,

    pub fn init(frame: *Frame) !*DocumentTimeline {
        return frame._factory.chained(.{
            AnimationTimeline{},
            DocumentTimeline{ ._proto = undefined },
        });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DocumentTimeline);

        pub const Meta = struct {
            pub const name = "DocumentTimeline";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // `new DocumentTimeline()` takes an optional options dictionary whose
        // only member is an origin time we have nothing to do with, so the
        // arity is what matters here and it is zero either way.
        pub const constructor = bridge.constructor(DocumentTimeline.init, .{});
    };
};

// document.featurePolicy: the permissions policy in force for this document.
pub const FeaturePolicy = struct {
    _pad: bool = false,

    // The 82 permission-policy features a headed Chrome 150 reports at a
    // top-level document, in Chrome's own iteration order. That order is stable
    // across processes (verified over two separate launches) and the list is a
    // sharp version fingerprint — features arrive and leave with nearly every
    // milestone — so it is reproduced verbatim rather than sorted or invented.
    const features_list = [_][]const u8{
        "geolocation",
        "ch-ua-full-version-list",
        "cross-origin-isolated",
        "screen-wake-lock",
        "on-device-speech-recognition",
        "translator",
        "publickey-credentials-get",
        "shared-storage-select-url",
        "ch-ua-arch",
        "bluetooth",
        "compute-pressure",
        "ch-prefers-reduced-transparency",
        "deferred-fetch",
        "usb",
        "ch-save-data",
        "publickey-credentials-create",
        "shared-storage",
        "deferred-fetch-minimal",
        "run-ad-auction",
        "ch-downlink",
        "ch-ua-form-factors",
        "otp-credentials",
        "payment",
        "ch-ua",
        "ch-ua-model",
        "ch-ect",
        "autoplay",
        "camera",
        "language-detector",
        "private-state-token-issuance",
        "digital-credentials-get",
        "accelerometer",
        "ch-ua-platform-version",
        "idle-detection",
        "language-model",
        "private-aggregation",
        "interest-cohort",
        "ch-viewport-height",
        "captured-surface-control",
        "local-fonts",
        "ch-ua-platform",
        "midi",
        "ch-ua-full-version",
        "xr-spatial-tracking",
        "clipboard-read",
        "gamepad",
        "display-capture",
        "keyboard-map",
        "join-ad-interest-group",
        "aria-notify",
        "local-network",
        "ch-ua-high-entropy-values",
        "ch-width",
        "ch-prefers-reduced-motion",
        "browsing-topics",
        "encrypted-media",
        "local-network-access",
        "gyroscope",
        "serial",
        "ch-rtt",
        "ch-ua-mobile",
        "window-management",
        "unload",
        "ch-dpr",
        "ch-prefers-color-scheme",
        "ch-ua-wow64",
        "attribution-reporting",
        "fullscreen",
        "identity-credentials-get",
        "private-state-token-redemption",
        "hid",
        "summarizer",
        "ch-ua-bitness",
        "storage-access",
        "sync-xhr",
        "ch-device-memory",
        "ch-viewport-width",
        "picture-in-picture",
        "loopback-network",
        "magnetometer",
        "clipboard-write",
        "microphone",
    };

    fn known(name: []const u8) bool {
        for (features_list) |feature| {
            if (std.mem.eql(u8, feature, name)) {
                return true;
            }
        }
        return false;
    }

    pub fn features(_: *const FeaturePolicy) []const []const u8 {
        return &features_list;
    }

    // A top-level document with no Permissions-Policy header is allowed
    // everything, which is what Chrome reports: allowedFeatures() equals
    // features(). A cross-origin frame keeps only the '*' features, in the
    // same order (measured: Chrome's 16 are its top-level list filtered).
    pub fn allowedFeatures(_: *const FeaturePolicy, frame: *Frame) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (features_list) |feature| {
            if (permissions_policy.allows(frame, feature)) {
                try list.append(frame.local_arena, feature);
            }
        }
        return list.items;
    }

    pub fn allowsFeature(_: *const FeaturePolicy, name: []const u8, _: ?[]const u8, frame: *Frame) bool {
        return known(name) and permissions_policy.allows(frame, name);
    }

    // A '*' feature is allowlisted to "*"; a 'self' one to the document's own
    // origin, or to nobody in a frame that did not inherit it. An unknown name
    // gets an empty list rather than an error.
    pub fn getAllowlistForFeature(_: *const FeaturePolicy, name: []const u8, frame: *Frame) ![]const []const u8 {
        if (!known(name)) {
            return &.{};
        }
        if (permissions_policy.isStarDefault(name)) {
            return &.{"*"};
        }
        if (!permissions_policy.allows(frame, name)) {
            return &.{};
        }
        const origin = try URL.getOrigin(frame.local_arena, frame.url) orelse return &.{};
        const list = try frame.local_arena.alloc([]const u8, 1);
        list[0] = origin;
        return list;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FeaturePolicy);

        pub const Meta = struct {
            pub const name = "FeaturePolicy";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const allowedFeatures = bridge.function(FeaturePolicy.allowedFeatures, .{});
        pub const allowsFeature = bridge.function(FeaturePolicy.allowsFeature, .{});
        pub const features = bridge.function(FeaturePolicy.features, .{});
        pub const getAllowlistForFeature = bridge.function(FeaturePolicy.getAllowlistForFeature, .{});
    };
};

// document.fragmentDirective. The text directives parsed out of a URL's `:~:`
// fragment are not readable from script — Chrome's prototype carries nothing but
// `constructor` and the instance has no own keys — so an empty interface is the
// whole observable surface, not a stub.
pub const FragmentDirective = struct {
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FragmentDirective);

        pub const Meta = struct {
            pub const name = "FragmentDirective";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
    };
};

// The set of active view-transition types. Setlike, and mutable: add / delete /
// clear all work on a live transition.
pub const ViewTransitionTypeSet = struct {
    _types: std.ArrayList([]const u8) = .empty,
    _arena: std.mem.Allocator,

    pub fn getSize(self: *const ViewTransitionTypeSet) u32 {
        return @intCast(self._types.items.len);
    }

    fn find(self: *const ViewTransitionTypeSet, name: []const u8) ?usize {
        for (self._types.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) {
                return i;
            }
        }
        return null;
    }

    pub fn add(self: *ViewTransitionTypeSet, name: []const u8) !void {
        if (self.find(name) != null) {
            return;
        }
        try self._types.append(self._arena, try self._arena.dupe(u8, name));
    }

    pub fn clear(self: *ViewTransitionTypeSet) void {
        self._types.clearRetainingCapacity();
    }

    pub fn delete(self: *ViewTransitionTypeSet, name: []const u8) bool {
        const index = self.find(name) orelse return false;
        _ = self._types.orderedRemove(index);
        return true;
    }

    pub fn has(self: *const ViewTransitionTypeSet, name: []const u8) bool {
        return self.find(name) != null;
    }

    pub fn keys(self: *ViewTransitionTypeSet, exec: *const Execution) !*KeyIterator {
        return .init(.{ .set = self }, exec);
    }

    pub fn values(self: *ViewTransitionTypeSet, exec: *const Execution) !*ValueIterator {
        return .init(.{ .set = self }, exec);
    }

    pub fn entries(self: *ViewTransitionTypeSet, exec: *const Execution) !*EntryIterator {
        return .init(.{ .set = self }, exec);
    }

    pub fn forEach(self: *ViewTransitionTypeSet, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._types.items) |name| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ name, name, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        set: *ViewTransitionTypeSet,

        pub const Entry = struct { []const u8, []const u8 };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const index = self.index;
            if (index >= self.set._types.items.len) {
                return null;
            }
            self.index = index + 1;
            const name = self.set._types.items[index];
            return .{ name, name };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ViewTransitionTypeSet);

        pub const Meta = struct {
            pub const name = "ViewTransitionTypeSet";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const size = bridge.accessor(ViewTransitionTypeSet.getSize, null, .{});
        pub const add = bridge.function(ViewTransitionTypeSet.add, .{});
        pub const clear = bridge.function(ViewTransitionTypeSet.clear, .{});
        pub const delete = bridge.function(ViewTransitionTypeSet.delete, .{});
        pub const entries = bridge.function(ViewTransitionTypeSet.entries, .{});
        pub const forEach = bridge.function(ViewTransitionTypeSet.forEach, .{});
        pub const has = bridge.function(ViewTransitionTypeSet.has, .{});
        pub const keys = bridge.function(ViewTransitionTypeSet.keys, .{});
        pub const values = bridge.function(ViewTransitionTypeSet.values, .{});
        pub const symbol_iterator = bridge.iterator(ViewTransitionTypeSet.values, .{});
    };
};

// What document.startViewTransition() and element.startViewTransition() hand
// back. We do not animate anything, so the transition is born already skipped:
// updateCallbackDone and finished resolve immediately and ready rejects with the
// AbortError Chrome uses for a skipped transition ("Transition was skipped",
// measured). A page that awaits any of the three therefore proceeds instead of
// hanging, which is the behaviour that matters — the visual half of a view
// transition is not something a headless engine has.
pub const ViewTransition = struct {
    _types: *ViewTransitionTypeSet,
    _root: ?*Element,
    _finished: ?js.PromiseResolver.Global = null,
    _ready: ?js.PromiseResolver.Global = null,
    _update_callback_done: ?js.PromiseResolver.Global = null,

    pub fn init(root: ?*Element, frame: *Frame) !*ViewTransition {
        const types = try frame._factory.create(ViewTransitionTypeSet{ ._arena = frame.arena });
        return frame._factory.create(ViewTransition{ ._types = types, ._root = root });
    }

    fn settled(
        slot: *?js.PromiseResolver.Global,
        comptime source: []const u8,
        comptime outcome: enum { resolve, abort },
        frame: *Frame,
    ) !js.Promise {
        if (slot.* != null) {
            return frame.js.toLocal(slot.*).?.promise();
        }
        const resolver = frame.js.local.?.createPromiseResolver();
        switch (outcome) {
            .resolve => resolver.resolve(source, {}),
            // Chrome's own wording for a skipped transition, not the generic
            // "The operation was aborted" an AbortError carries by default.
            .abort => resolver.reject(source, DOMException.init("Transition was skipped", "AbortError")),
        }
        slot.* = try resolver.persist();
        return resolver.promise();
    }

    pub fn getFinished(self: *ViewTransition, frame: *Frame) !js.Promise {
        return settled(&self._finished, "ViewTransition.finished", .resolve, frame);
    }

    pub fn getReady(self: *ViewTransition, frame: *Frame) !js.Promise {
        return settled(&self._ready, "ViewTransition.ready", .abort, frame);
    }

    pub fn getUpdateCallbackDone(self: *ViewTransition, frame: *Frame) !js.Promise {
        return settled(&self._update_callback_done, "ViewTransition.updateCallbackDone", .resolve, frame);
    }

    pub fn getTypes(self: *const ViewTransition) *ViewTransitionTypeSet {
        return self._types;
    }

    pub fn skipTransition(_: *const ViewTransition) void {}

    // The element the transition is scoped to. For a document-wide transition
    // that is the document element, which is why Chrome reports an
    // HTMLHtmlElement here.
    pub fn getTransitionRoot(self: *const ViewTransition) ?*Element {
        return self._root;
    }

    // One required argument, so waitUntil.length is 1 as in Chrome.
    pub fn waitUntil(_: *const ViewTransition, _: js.Object) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ViewTransition);

        pub const Meta = struct {
            pub const name = "ViewTransition";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const finished = bridge.accessor(ViewTransition.getFinished, null, .{});
        pub const ready = bridge.accessor(ViewTransition.getReady, null, .{});
        pub const updateCallbackDone = bridge.accessor(ViewTransition.getUpdateCallbackDone, null, .{});
        pub const types = bridge.accessor(ViewTransition.getTypes, null, .{});
        pub const transitionRoot = bridge.accessor(ViewTransition.getTransitionRoot, null, .{});
        pub const skipTransition = bridge.function(ViewTransition.skipTransition, .{});
        pub const waitUntil = bridge.function(ViewTransition.waitUntil, .{});
    };
};

// What document.caretPositionFromPoint() returns: a node plus an offset into it.
pub const CaretPosition = struct {
    _node: *Node,
    _offset: u32,

    pub fn init(node: *Node, offset: u32, frame: *Frame) !*CaretPosition {
        return frame._factory.create(CaretPosition{ ._node = node, ._offset = offset });
    }

    pub fn getOffsetNode(self: *const CaretPosition) *Node {
        return self._node;
    }

    pub fn getOffset(self: *const CaretPosition) u32 {
        return self._offset;
    }

    // The caret's own rectangle. We have no text layout to measure a caret
    // against, so this is the zero rect — the same shape Chrome returns, with
    // dimensions we cannot produce.
    pub fn getClientRect(_: *const CaretPosition, exec: *const Execution) !*DOMRect {
        return DOMRect.init(0, 0, 0, 0, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CaretPosition);

        pub const Meta = struct {
            pub const name = "CaretPosition";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const offsetNode = bridge.accessor(CaretPosition.getOffsetNode, null, .{});
        pub const offset = bridge.accessor(CaretPosition.getOffset, null, .{});
        pub const getClientRect = bridge.function(CaretPosition.getClientRect, .{});
    };
};

// What element.pseudo("::before") names. It identifies a pseudo-element of a
// real element; we generate no boxes for pseudo-elements, so `type` and
// `element` are the whole of it, which is also all Chrome exposes beyond the
// nesting accessors.
pub const CSSPseudoElement = struct {
    _element: *Element,
    _type: []const u8,

    pub fn init(element: *Element, pseudo_type: []const u8, frame: *Frame) !*CSSPseudoElement {
        return frame._factory.create(CSSPseudoElement{ ._element = element, ._type = pseudo_type });
    }

    pub fn getType(self: *const CSSPseudoElement) []const u8 {
        return self._type;
    }

    pub fn getElement(self: *const CSSPseudoElement) *Element {
        return self._element;
    }

    // The originating element, same as `element` for a first-level
    // pseudo-element. Nested pseudo-elements (::before::marker) would differ,
    // and we do not create those.
    pub fn getParent(self: *const CSSPseudoElement) *Element {
        return self._element;
    }

    pub fn pseudo(_: *const CSSPseudoElement, _: []const u8) ?*CSSPseudoElement {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSPseudoElement);

        pub const Meta = struct {
            pub const name = "CSSPseudoElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(CSSPseudoElement.getType, null, .{});
        pub const element = bridge.accessor(CSSPseudoElement.getElement, null, .{});
        pub const parent = bridge.accessor(CSSPseudoElement.getParent, null, .{});
        pub const pseudo = bridge.function(CSSPseudoElement.pseudo, .{});
    };
};
