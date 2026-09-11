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
const Script = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_src: []const u8 = "",
_executed: bool = false,
// dynamic scripts are forced to be async by default
_force_async: bool = true,

pub fn asElement(self: *Script) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asConstElement(self: *const Script) *const Element {
    return Factory.protoOf(self).asElement();
}

pub fn asNode(self: *Script) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *Script, frame: *Frame) ![]const u8 {
    if (self._src.len == 0) return "";
    return self.asNode().resolveURLReflect(self._src, frame, .{});
}

pub fn setSrc(self: *Script, src: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(src), frame);
}

pub fn getAsync(self: *const Script) bool {
    return self._force_async or self.asConstElement().getAttributeInterned("async") != null;
}

pub fn setAsync(self: *Script, value: bool, frame: *Frame) !void {
    self._force_async = false;
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("async"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("async"), frame);
    }
}

pub fn setInnerText(self: *Script, text: []const u8, frame: *Frame) !void {
    try self.asNode().setTextContent(text, frame);
}

/// https://html.spec.whatwg.org/multipage/scripting.html#dom-script-supports
/// Only the types this engine actually loads; loaders feature-detect module
/// support here and fall back to fetch()-based legacy loading when it fails.
pub fn supports(value: []const u8) bool {
    const supported = [_][]const u8{ "classic", "module", "importmap" };
    for (supported) |s| {
        if (std.mem.eql(u8, value, s)) return true;
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Script);

    pub const Meta = struct {
        pub const name = "HTMLScriptElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // `attributionSrc` is behind a runtime flag, so Chrome installs it from
        // the per-context batch and it lands after `constructor` (measured).
        pub const constructor_after = "innerText";
    };

    const reflect = Element.Reflect(Script);

    // Chrome's order. No `nonce`: that one is HTMLElement's, from the
    // HTMLOrSVGElement mixin (measured).
    pub const src = bridge.accessor(Script.getSrc, Script.setSrc, .{ .ce_reactions = true });
    pub const @"type" = reflect.string("type");
    pub const noModule = reflect.boolean("nomodule");
    pub const charset = reflect.string("charset");
    pub const async = bridge.accessor(Script.getAsync, Script.setAsync, .{ .ce_reactions = true });
    pub const @"defer" = reflect.boolean("defer");
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });

    pub const text = bridge.accessor(_text, Script.setInnerText, .{ .ce_reactions = true });
    fn _text(self: *Script, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.asNode().getChildTextContent(&buf.writer);
        return buf.written();
    }

    pub const referrerPolicy = reflect.referrerPolicy();
    pub const fetchPriority = reflect.enumerated("fetchpriority", &.{ "high", "low" }, .{ .missing = "auto" });
    pub const event = reflect.string("event");
    pub const htmlFor = reflect.string("for");
    pub const integrity = reflect.string("integrity");
    pub const blocking = reflect.tokenList(.blocking);

    // Chrome redeclares `textContent` here for Trusted Types; the behaviour is
    // Node's, and the tell is the name being an own property of this prototype
    // rather than only of Node's.
    pub const textContent = bridge.accessor(_textContent, _setTextContent, .{ .ce_reactions = true });
    fn _textContent(self: *Script, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.asNode().getTextContent(&buf.writer);
        return buf.written();
    }
    fn _setTextContent(self: *Script, value: js.Value, frame: *Frame) !void {
        return self.asNode().setTextContent(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }

    pub const innerText = bridge.accessor(_innerText, Script.setInnerText, .{ .ce_reactions = true });
    fn _innerText(self: *Script, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.asNode().getTextContent(&buf.writer);
        return buf.written();
    }

    pub const attributionSrc = reflect.string("attributionsrc");

    // `supports` is static, so it is on the interface object, not here.
    pub const supports = bridge.function(Script.supports, .{ .static = true });
};

pub const Build = struct {
    pub fn complete(node: *Node, _: *Frame) !void {
        const self = node.as(Script);
        const element = self.asElement();
        self._src = element.getAttributeInterned("src") orelse "";
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }

        const self = element.as(Script);
        self._src = element.getAttributeInterned("src") orelse "";
        if (self._src.len > 0 and element.asNode().isConnected()) {
            try frame.scriptAddedCallback(false, self);
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Frame) !void {
        if (name.eql(comptime .wrap("src"))) {
            element.as(Script)._src = "";
        }
    }

    // Per the HTML spec, the "already started" flag must be propagated to the
    // clone so that re-inserting a cloned <script> doesn't run it again.
    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, _: *Frame) !void {
        _ = deep;
        const source = source_element.as(Script);
        const clone = cloned_element.as(Script);
        clone._executed = source._executed;
        clone._force_async = source._force_async;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Script" {
    testing.silenceLog(&.{.http});
    testing.expectLog(&.{ .js, .js });
    try testing.htmlRunner("element/html/script", .{});
}
