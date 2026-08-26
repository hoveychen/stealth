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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// MathMLElement: the one interface the whole MathML namespace uses. There are no
// per-tag subclasses -- `<math>`, `<mi>` and `<annotation-xml>` are all
// MathMLElement -- so this is a sibling of HTMLElement and SVGElement under
// Element, exactly as Chrome has it (protoChain measured:
// Element > Node > EventTarget > Object).
//
// Before this, both routes into the namespace answered HTMLUnknownElement:
// `document.createElementNS(mathml, 'math')` and a `<math>` in parsed markup.
// Measured on a headed Chrome 150 (probe-win28/29/32):
//
//   * The tag name is case-preserving like SVG's:
//     createElementNS(mathml, 'mSpace').tagName is 'mSpace'. Markup lowercases
//     it first, so `<MATH>` in innerHTML gives tagName 'math'.
//   * `document.createElement('math')` is *not* MathML -- it lands in the HTML
//     namespace and stays HTMLUnknownElement.
//   * The prototype carries the HTMLOrSVGElement / GlobalEventHandlers pile:
//     the on* handlers, dataset, nonce, autofocus, tabIndex, style,
//     attributeStyleMap, blur, focus, focusGroup and focusGroupStart -- in the
//     order below, which is Chrome's own.
//   * `new MathMLElement()` is an illegal constructor.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const DOMStringMap = @import("DOMStringMap.zig");
const DOMTokenList = @import("../collections.zig").DOMTokenList;
const CSSStyleDeclaration = @import("../css/CSSStyleDeclaration.zig");
const StylePropertyMap = @import("../css/typed_om.zig").StylePropertyMap;
const global_event_handlers = @import("../global_event_handlers.zig");

const String = lp.String;

const MathML = @This();

pub const Proto = Element;

_proto: *Element,
// Case-preserving, like SVG: nothing in the MathML namespace is uppercased.
_tag_name: String,

pub fn asElement(self: *MathML) *Element {
    return self._proto;
}

pub fn asNode(self: *MathML) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MathML);

    pub const Meta = struct {
        pub const name = "MathMLElement";
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "focusGroupStart";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // The on* handlers have no dedicated storage; they ride the same
    // attribute-listener store every other element handler uses.
    fn handler(comptime which: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *MathML, frame: *Frame) !?js.Function.Global {
                return self.asElement().getAttributeFunction(which, frame);
            }
            pub fn set(self: *MathML, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.asElement().setAttributeListener(which, callback, frame);
            }
        };
    }

    fn _dataset(self: *MathML, frame: *Frame) !*DOMStringMap {
        return self.asElement().getDataset(frame);
    }
    fn _style(self: *MathML, frame: *Frame) !*CSSStyleDeclaration {
        return self.asElement().getOrCreateStyle(frame);
    }
    fn _setStyle(self: *MathML, value: []const u8, frame: *Frame) !void {
        return self.asElement().setStyle(value, frame);
    }
    fn _attributeStyleMap(self: *MathML, frame: *Frame) !*StylePropertyMap {
        const declaration = try self.asElement().getOrCreateStyle(frame);
        return declaration.getPropertyMap(frame);
    }
    // A slot, not the content attribute -- see Element.getNonce.
    fn _nonce(self: *MathML, frame: *Frame) []const u8 {
        return self.asElement().getNonce(frame);
    }
    fn _setNonce(self: *MathML, value: []const u8, frame: *Frame) !void {
        return self.asElement().setNonce(value, frame);
    }
    fn _autofocus(self: *MathML) bool {
        return self.asElement().getAttributeSafe(comptime .wrap("autofocus")) != null;
    }
    fn _setAutofocus(self: *MathML, value: bool, frame: *Frame) !void {
        const element = self.asElement();
        if (value) {
            return element.setAttributeSafe(comptime .wrap("autofocus"), .wrap(""), frame);
        }
        return element.removeAttribute(comptime .wrap("autofocus"), frame);
    }
    /// -1 unless the attribute says otherwise: nothing in MathML is focusable
    /// by default (measured).
    fn _tabIndex(self: *MathML) i32 {
        const attribute = self.asElement().getAttributeSafe(comptime .wrap("tabindex")) orelse return -1;
        return std.fmt.parseInt(i32, std.mem.trim(u8, attribute, &std.ascii.whitespace), 10) catch -1;
    }
    fn _setTabIndex(self: *MathML, value: i32, frame: *Frame) !void {
        var buf: [12]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        return self.asElement().setAttributeSafe(comptime .wrap("tabindex"), .wrap(str), frame);
    }
    fn _focus(self: *MathML, frame: *Frame) !void {
        return self.asElement().focus(frame);
    }
    fn _blur(self: *MathML, frame: *Frame) !void {
        return self.asElement().blur(frame);
    }
    // A DOMTokenList over the focusgroup attribute, exactly as HTMLElement
    // has it -- measured: `rect.focusGroup.constructor.name` is DOMTokenList
    // on all three element families, and the same object comes back twice.
    fn _focusGroup(self: *MathML, frame: *Frame) !*DOMTokenList {
        return self.asElement().getTokenList(.focusgroup, frame);
    }
    fn _setFocusGroup(self: *MathML, value: []const u8, frame: *Frame) !void {
        return self.asElement().setAttributeSafe(comptime .wrap("focusgroup"), .wrap(value), frame);
    }
    fn _focusGroupStart(_: *MathML) bool {
        return false;
    }
    fn _setFocusGroupStart(_: *MathML, _: ?js.Value) void {}

    // Chrome's own prototype order (measured on Chrome 150).
    pub const onabort = bridge.accessor(handler(.onabort).get, handler(.onabort).set, .{});
    pub const onbeforeinput = bridge.accessor(handler(.onbeforeinput).get, handler(.onbeforeinput).set, .{});
    pub const onbeforematch = bridge.accessor(handler(.onbeforematch).get, handler(.onbeforematch).set, .{});
    pub const onbeforetoggle = bridge.accessor(handler(.onbeforetoggle).get, handler(.onbeforetoggle).set, .{});
    pub const onblur = bridge.accessor(handler(.onblur).get, handler(.onblur).set, .{});
    pub const oncancel = bridge.accessor(handler(.oncancel).get, handler(.oncancel).set, .{});
    pub const oncanplay = bridge.accessor(handler(.oncanplay).get, handler(.oncanplay).set, .{});
    pub const oncanplaythrough = bridge.accessor(handler(.oncanplaythrough).get, handler(.oncanplaythrough).set, .{});
    pub const onchange = bridge.accessor(handler(.onchange).get, handler(.onchange).set, .{});
    pub const onclick = bridge.accessor(handler(.onclick).get, handler(.onclick).set, .{});
    pub const onclose = bridge.accessor(handler(.onclose).get, handler(.onclose).set, .{});
    pub const oncommand = bridge.accessor(handler(.oncommand).get, handler(.oncommand).set, .{});
    pub const oncontentvisibilityautostatechange = bridge.accessor(handler(.oncontentvisibilityautostatechange).get, handler(.oncontentvisibilityautostatechange).set, .{});
    pub const oncontextlost = bridge.accessor(handler(.oncontextlost).get, handler(.oncontextlost).set, .{});
    pub const oncontextmenu = bridge.accessor(handler(.oncontextmenu).get, handler(.oncontextmenu).set, .{});
    pub const oncontextrestored = bridge.accessor(handler(.oncontextrestored).get, handler(.oncontextrestored).set, .{});
    pub const oncuechange = bridge.accessor(handler(.oncuechange).get, handler(.oncuechange).set, .{});
    pub const ondblclick = bridge.accessor(handler(.ondblclick).get, handler(.ondblclick).set, .{});
    pub const ondrag = bridge.accessor(handler(.ondrag).get, handler(.ondrag).set, .{});
    pub const ondragend = bridge.accessor(handler(.ondragend).get, handler(.ondragend).set, .{});
    pub const ondragenter = bridge.accessor(handler(.ondragenter).get, handler(.ondragenter).set, .{});
    pub const ondragleave = bridge.accessor(handler(.ondragleave).get, handler(.ondragleave).set, .{});
    pub const ondragover = bridge.accessor(handler(.ondragover).get, handler(.ondragover).set, .{});
    pub const ondragstart = bridge.accessor(handler(.ondragstart).get, handler(.ondragstart).set, .{});
    pub const ondrop = bridge.accessor(handler(.ondrop).get, handler(.ondrop).set, .{});
    pub const ondurationchange = bridge.accessor(handler(.ondurationchange).get, handler(.ondurationchange).set, .{});
    pub const onemptied = bridge.accessor(handler(.onemptied).get, handler(.onemptied).set, .{});
    pub const onended = bridge.accessor(handler(.onended).get, handler(.onended).set, .{});
    pub const onerror = bridge.accessor(handler(.onerror).get, handler(.onerror).set, .{});
    pub const onfocus = bridge.accessor(handler(.onfocus).get, handler(.onfocus).set, .{});
    pub const onformdata = bridge.accessor(handler(.onformdata).get, handler(.onformdata).set, .{});
    pub const oninput = bridge.accessor(handler(.oninput).get, handler(.oninput).set, .{});
    pub const oninvalid = bridge.accessor(handler(.oninvalid).get, handler(.oninvalid).set, .{});
    pub const onkeydown = bridge.accessor(handler(.onkeydown).get, handler(.onkeydown).set, .{});
    pub const onkeypress = bridge.accessor(handler(.onkeypress).get, handler(.onkeypress).set, .{});
    pub const onkeyup = bridge.accessor(handler(.onkeyup).get, handler(.onkeyup).set, .{});
    pub const onload = bridge.accessor(handler(.onload).get, handler(.onload).set, .{});
    pub const onloadeddata = bridge.accessor(handler(.onloadeddata).get, handler(.onloadeddata).set, .{});
    pub const onloadedmetadata = bridge.accessor(handler(.onloadedmetadata).get, handler(.onloadedmetadata).set, .{});
    pub const onloadstart = bridge.accessor(handler(.onloadstart).get, handler(.onloadstart).set, .{});
    pub const onmousedown = bridge.accessor(handler(.onmousedown).get, handler(.onmousedown).set, .{});
    pub const onmouseenter = bridge.accessor(handler(.onmouseenter).get, handler(.onmouseenter).set, .{});
    pub const onmouseleave = bridge.accessor(handler(.onmouseleave).get, handler(.onmouseleave).set, .{});
    pub const onmousemove = bridge.accessor(handler(.onmousemove).get, handler(.onmousemove).set, .{});
    pub const onmouseout = bridge.accessor(handler(.onmouseout).get, handler(.onmouseout).set, .{});
    pub const onmouseover = bridge.accessor(handler(.onmouseover).get, handler(.onmouseover).set, .{});
    pub const onmouseup = bridge.accessor(handler(.onmouseup).get, handler(.onmouseup).set, .{});
    pub const onmousewheel = bridge.accessor(handler(.onmousewheel).get, handler(.onmousewheel).set, .{});
    pub const onpause = bridge.accessor(handler(.onpause).get, handler(.onpause).set, .{});
    pub const onplay = bridge.accessor(handler(.onplay).get, handler(.onplay).set, .{});
    pub const onplaying = bridge.accessor(handler(.onplaying).get, handler(.onplaying).set, .{});
    pub const onprogress = bridge.accessor(handler(.onprogress).get, handler(.onprogress).set, .{});
    pub const onratechange = bridge.accessor(handler(.onratechange).get, handler(.onratechange).set, .{});
    pub const onreset = bridge.accessor(handler(.onreset).get, handler(.onreset).set, .{});
    pub const onresize = bridge.accessor(handler(.onresize).get, handler(.onresize).set, .{});
    pub const onscroll = bridge.accessor(handler(.onscroll).get, handler(.onscroll).set, .{});
    pub const onscrollend = bridge.accessor(handler(.onscrollend).get, handler(.onscrollend).set, .{});
    pub const onsecuritypolicyviolation = bridge.accessor(handler(.onsecuritypolicyviolation).get, handler(.onsecuritypolicyviolation).set, .{});
    pub const onseeked = bridge.accessor(handler(.onseeked).get, handler(.onseeked).set, .{});
    pub const onseeking = bridge.accessor(handler(.onseeking).get, handler(.onseeking).set, .{});
    pub const onselect = bridge.accessor(handler(.onselect).get, handler(.onselect).set, .{});
    pub const onslotchange = bridge.accessor(handler(.onslotchange).get, handler(.onslotchange).set, .{});
    pub const onstalled = bridge.accessor(handler(.onstalled).get, handler(.onstalled).set, .{});
    pub const onsubmit = bridge.accessor(handler(.onsubmit).get, handler(.onsubmit).set, .{});
    pub const onsuspend = bridge.accessor(handler(.onsuspend).get, handler(.onsuspend).set, .{});
    pub const ontimeupdate = bridge.accessor(handler(.ontimeupdate).get, handler(.ontimeupdate).set, .{});
    pub const ontoggle = bridge.accessor(handler(.ontoggle).get, handler(.ontoggle).set, .{});
    pub const onvolumechange = bridge.accessor(handler(.onvolumechange).get, handler(.onvolumechange).set, .{});
    pub const onwaiting = bridge.accessor(handler(.onwaiting).get, handler(.onwaiting).set, .{});
    pub const onwebkitanimationend = bridge.accessor(handler(.onwebkitanimationend).get, handler(.onwebkitanimationend).set, .{});
    pub const onwebkitanimationiteration = bridge.accessor(handler(.onwebkitanimationiteration).get, handler(.onwebkitanimationiteration).set, .{});
    pub const onwebkitanimationstart = bridge.accessor(handler(.onwebkitanimationstart).get, handler(.onwebkitanimationstart).set, .{});
    pub const onwebkittransitionend = bridge.accessor(handler(.onwebkittransitionend).get, handler(.onwebkittransitionend).set, .{});
    pub const onwheel = bridge.accessor(handler(.onwheel).get, handler(.onwheel).set, .{});
    pub const onauxclick = bridge.accessor(handler(.onauxclick).get, handler(.onauxclick).set, .{});
    pub const ongotpointercapture = bridge.accessor(handler(.ongotpointercapture).get, handler(.ongotpointercapture).set, .{});
    pub const onlostpointercapture = bridge.accessor(handler(.onlostpointercapture).get, handler(.onlostpointercapture).set, .{});
    pub const onpointerdown = bridge.accessor(handler(.onpointerdown).get, handler(.onpointerdown).set, .{});
    pub const onpointermove = bridge.accessor(handler(.onpointermove).get, handler(.onpointermove).set, .{});
    pub const onpointerup = bridge.accessor(handler(.onpointerup).get, handler(.onpointerup).set, .{});
    pub const onpointercancel = bridge.accessor(handler(.onpointercancel).get, handler(.onpointercancel).set, .{});
    pub const onpointerover = bridge.accessor(handler(.onpointerover).get, handler(.onpointerover).set, .{});
    pub const onpointerout = bridge.accessor(handler(.onpointerout).get, handler(.onpointerout).set, .{});
    pub const onpointerenter = bridge.accessor(handler(.onpointerenter).get, handler(.onpointerenter).set, .{});
    pub const onpointerleave = bridge.accessor(handler(.onpointerleave).get, handler(.onpointerleave).set, .{});
    pub const onselectstart = bridge.accessor(handler(.onselectstart).get, handler(.onselectstart).set, .{});
    pub const onselectionchange = bridge.accessor(handler(.onselectionchange).get, handler(.onselectionchange).set, .{});
    pub const onanimationcancel = bridge.accessor(handler(.onanimationcancel).get, handler(.onanimationcancel).set, .{});
    pub const onanimationend = bridge.accessor(handler(.onanimationend).get, handler(.onanimationend).set, .{});
    pub const onanimationiteration = bridge.accessor(handler(.onanimationiteration).get, handler(.onanimationiteration).set, .{});
    pub const onanimationstart = bridge.accessor(handler(.onanimationstart).get, handler(.onanimationstart).set, .{});
    pub const ontransitionrun = bridge.accessor(handler(.ontransitionrun).get, handler(.ontransitionrun).set, .{});
    pub const ontransitionstart = bridge.accessor(handler(.ontransitionstart).get, handler(.ontransitionstart).set, .{});
    pub const ontransitionend = bridge.accessor(handler(.ontransitionend).get, handler(.ontransitionend).set, .{});
    pub const ontransitioncancel = bridge.accessor(handler(.ontransitioncancel).get, handler(.ontransitioncancel).set, .{});
    pub const onbeforexrselect = bridge.accessor(handler(.onbeforexrselect).get, handler(.onbeforexrselect).set, .{});
    pub const oncopy = bridge.accessor(handler(.oncopy).get, handler(.oncopy).set, .{});
    pub const oncut = bridge.accessor(handler(.oncut).get, handler(.oncut).set, .{});
    pub const onpaste = bridge.accessor(handler(.onpaste).get, handler(.onpaste).set, .{});
    pub const dataset = bridge.accessor(_dataset, null, .{});
    pub const nonce = bridge.accessor(_nonce, _setNonce, .{ .ce_reactions = true });
    pub const autofocus = bridge.accessor(_autofocus, _setAutofocus, .{ .ce_reactions = true });
    pub const tabIndex = bridge.accessor(_tabIndex, _setTabIndex, .{ .ce_reactions = true });
    pub const style = bridge.accessor(_style, _setStyle, .{});
    pub const attributeStyleMap = bridge.accessor(_attributeStyleMap, null, .{});
    pub const blur = bridge.function(_blur, .{});
    pub const focus = bridge.function(_focus, .{});
    pub const onscrollsnapchange = bridge.accessor(handler(.onscrollsnapchange).get, handler(.onscrollsnapchange).set, .{});
    pub const onscrollsnapchanging = bridge.accessor(handler(.onscrollsnapchanging).get, handler(.onscrollsnapchanging).set, .{});
    pub const focusGroup = bridge.accessor(_focusGroup, _setFocusGroup, .{ .ce_reactions = true });
    pub const focusGroupStart = bridge.accessor(_focusGroupStart, _setFocusGroupStart, .{ .ce_reactions = true });
    pub const onpointerrawupdate = bridge.accessor(handler(.onpointerrawupdate).get, handler(.onpointerrawupdate).set, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MathMLElement" {
    try testing.htmlRunner("element/mathml.html", .{});
}
