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

const CssParser = @import("../../css/Parser.zig");
const units = @import("../../css/units.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const StyleManager = @import("../../StyleManager.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

const chrome_arity = @import("chrome_arity.zig");
const chrome_keywords = @import("chrome_keywords.zig");
const chrome_current_color = @import("chrome_current_color.zig");
const chrome_default_display = @import("chrome_default_display.zig");
const chrome_inherited = @import("chrome_inherited.zig");
const chrome_initial_values = @import("chrome_initial_values.zig");
const chrome_logical = @import("chrome_logical.zig");
const chrome_per_tag_values = @import("chrome_per_tag_values.zig");
const chrome_input_type_values = @import("chrome_input_type_values.zig");
const chrome_properties = @import("chrome_properties.zig");
const chrome_value_case = @import("chrome_value_case.zig");
const shorthand = @import("shorthand.zig");
const font_metrics = @import("../../font_metrics.zig");
const transform = @import("transform.zig");
const typed_om = @import("typed_om.zig");
const color = @import("../../color.zig");

const CSSStyleDeclaration = @This();

_element: ?*Element = null,
_properties: std.DoublyLinkedList = .{},
_is_computed: bool = false,
_syncing: bool = false,
/// The frame this declaration belongs to. A computed view's indexed list has
/// to resolve the element's custom properties through the style manager, and
/// the accessors behind it (`cs.length`, `cs[0]`, the iterator) are not all
/// handed a frame.
_frame: *Frame = undefined,
/// The Typed OM view of this declaration, created on first use. Measured:
/// `el.attributeStyleMap` and `rule.styleMap` are stable objects, so the map
/// has to be cached rather than rebuilt per access.
_property_map: ?*typed_om.StylePropertyMap = null,

/// Chrome has one interface for both kinds of declaration -- an element's inline
/// `style` and the view `getComputedStyle` hands back are both branded
/// CSSStyleDeclaration, and it has no CSSStyleProperties global at all
/// (measured; see chrome_properties.zig). The two differ only in what they
/// enumerate: a computed view lists Chrome's 474 longhands by index, an inline
/// one lists whatever is actually set.
pub fn init(element: ?*Element, is_computed: bool, frame: *Frame) !*CSSStyleDeclaration {
    const self = try frame._factory.create(CSSStyleDeclaration{
        ._element = element,
        ._is_computed = is_computed,
        ._frame = frame,
    });
    try self.parseInlineStyle(frame);
    return self;
}

// Parse the element's existing style attribute into _properties so that
// subsequent JS reads and writes see all CSS properties, not just newly
// added ones.  Computed styles have no inline attribute to parse.
pub fn parseInlineStyle(self: *CSSStyleDeclaration, frame: *Frame) !void {
    if (self._is_computed) {
        return;
    }
    const el = self._element orelse return;
    const attr_value = el.getAttributeSafe(comptime .wrap("style")) orelse return;
    try self.applyDeclarations(attr_value, frame);
}

fn applyDeclarations(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    var it = CssParser.parseDeclarationsList(text);
    while (it.next()) |declaration| {
        try self.applyParsedDeclaration(declaration, frame);
    }
}

/// The writable Typed OM view: `element.attributeStyleMap` and
/// `cssRule.styleMap` are both StylePropertyMaps over the declaration.
pub fn getPropertyMap(self: *CSSStyleDeclaration, frame: *Frame) !*typed_om.StylePropertyMap {
    if (self._property_map) |map| {
        return map;
    }
    const map = try typed_om.StylePropertyMap.init(self, frame);
    self._property_map = map;
    return map;
}

/// Whether Chrome answers this property name at all, under either spelling.
/// Exposed for the style maps, whose accessors throw rather than answer null
/// for a name Chrome has never heard of.
pub fn isKnownPropertyName(name: []const u8) bool {
    return isAliasSpelling(name);
}

/// Whether this computed view has nothing to report, because its element is not
/// in a document with a browsing context.
///
/// Chrome answers an EMPTY declaration there -- `length` 0, `item(0)` "", every
/// property "" including `display` and custom properties -- and this engine
/// answered full values, which is one expression a page can tell the two apart
/// with. Measured with probes/expr-b85-detached-computed.js.
///
/// The predicate is not "has no box": a `display: none` element is in the
/// document, has no box, and has a complete computed style. It is being out of
/// a browsing context, and that covers a shape easy to miss -- an element
/// CONNECTED to a `createHTMLDocument`, whose document has no browsing context
/// of its own. This engine answered the viewport's width for one of those.
///
/// Asked per call rather than cached: the declaration object is live, so the
/// same object reports values while the element is attached and empties the
/// moment it is removed.
fn computedIsEmpty(self: *const CSSStyleDeclaration) bool {
    if (!self._is_computed) return false;
    const element = self._element orelse return false;
    const node = element.asNode();
    if (!node.isConnected()) return true;
    const document = node.ownerDocument(self._frame) orelse return true;
    return document._frame == null;
}

pub fn length(self: *const CSSStyleDeclaration) u32 {
    // A computed view enumerates every longhand Chrome computes, whether or not
    // the page set any of them, so its length does not depend on _properties.
    if (self._is_computed) {
        if (self.computedIsEmpty()) return 0;
        return chrome_properties.computed.len;
    }
    return @intCast(self._properties.len());
}

/// What the indexed surface reports, which for a computed view is the standard
/// longhands plus the custom properties in effect on the element -- Chrome
/// lists those alongside them. The Typed OM views keep to `length`, whose
/// measured size is the standard count alone.
pub fn indexedLength(self: *const CSSStyleDeclaration) u32 {
    if (!self._is_computed) {
        return self.length();
    }
    return self.length() + @as(u32, @intCast(self.computedCustomNames().len));
}

/// The custom property names a computed view enumerates. Recomputed per call:
/// the declaration object is cached per element for the frame's lifetime, so a
/// stored list would go stale the moment the page declares another one.
fn computedCustomNames(self: *const CSSStyleDeclaration) [][]const u8 {
    if (self.computedIsEmpty()) return &.{};
    const element = self._element orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    self._frame._style_manager.collectCustomPropertyNames(element, &names) catch return &.{};
    return names.items;
}

pub fn indexedItem(self: *const CSSStyleDeclaration, index: u32) []const u8 {
    if (self._is_computed and index >= chrome_properties.computed.len) {
        const names = self.computedCustomNames();
        const custom_index = index - chrome_properties.computed.len;
        if (custom_index >= names.len) {
            return "";
        }
        return names[custom_index];
    }
    return self.item(index);
}

pub fn item(self: *const CSSStyleDeclaration, index: u32) []const u8 {
    if (self._is_computed) {
        if (self.computedIsEmpty()) return "";
        if (index >= chrome_properties.computed.len) {
            return "";
        }
        return chrome_properties.computed[index];
    }
    var i: u32 = 0;
    var node = self._properties.first;
    while (node) |n| {
        if (i == index) {
            const prop = Property.fromNodeLink(n);
            return prop._name.str();
        }
        i += 1;
        node = n.next;
    }
    return "";
}

/// Chrome's parentRule is null for both an inline style and a computed view; only
/// a declaration reached through a CSSRule has one, and nothing here hands those
/// out yet.
pub fn getParentRule(_: *const CSSStyleDeclaration) ?bool {
    return null;
}

/// Which of the two values a computed declaration is being asked for. They only
/// differ in the initial values below; a declared value reads the same either
/// way.
pub const Surface = enum { used, computed };

/// What `getComputedStyle()` reports: the used value.
pub fn getPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    return self.propertyValue(property_name, frame, .used);
}

/// What the CSS Typed OM reports: the computed value. See `borderWidth`.
pub fn getComputedValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    return self.propertyValue(property_name, frame, .computed);
}

/// The six properties whose `<alpha-value>` is brought into [0,1] at
/// computed-value time.
///
/// Only at computed time: `el.style.opacity` still reads back what the author
/// wrote. Measured on Chrome 151 with probes/expr-b85-clamped-props.js over
/// twenty-two properties with a range in their grammar -- exactly these six
/// clamp, and the near neighbours that look like they should do not.
/// `flex-grow: 1.015625` computes to `1.01562` with no upper bound, and a
/// negative one is rejected at parse rather than clamped.
fn clampAlphaValue(property_name: []const u8, value: []const u8) ?[]const u8 {
    const ALPHA = [_][]const u8{
        "opacity",      "fill-opacity",  "stroke-opacity",
        "stop-opacity", "flood-opacity", "shape-image-threshold",
    };
    const matches = for (ALPHA) |name| {
        if (std.ascii.eqlIgnoreCase(property_name, name)) break true;
    } else false;
    if (!matches) return null;

    const parsed = units.parse(value) catch return null;
    if (parsed.unit != .none) return null;
    if (parsed.value < 0) return "0";
    if (parsed.value > 1) return "1";
    return null;
}

fn propertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame, surface: Surface) []const u8 {
    if (self.computedIsEmpty()) return "";
    const value = self.propertyValueAt(property_name, frame, surface, 0);
    // On the computed view only, and on both surfaces it reports: the CSS-OM
    // reads the used value here and the Typed OM the computed one, and Chrome
    // clamps the alpha family in both. An inline declaration is untouched --
    // `el.style.opacity` reads back what the author wrote.
    if (!self._is_computed) return value;
    return clampAlphaValue(property_name, value) orelse value;
}

/// Bounds the two reads that reach back into this function: a longhand whose
/// initial value is `currentcolor` asks for `color`, and a shorthand asks for
/// each of its longhands. Neither chains -- `color` is a longhand and a
/// longhand is not a shorthand -- so the limit is a backstop against a table
/// entry that ever pointed a shorthand at itself, not a depth pages reach.
const MAX_PROPERTY_DEPTH = 4;

fn propertyValueAt(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame, surface: Surface, depth: u8) []const u8 {
    // The name is normalised into a local buffer rather than `frame.buf`,
    // because it has to outlive every call below and that one does not. The
    // cascade's first read is the one that rebuilds the stylesheets, and the
    // rebuild normalises declaration names into the same shared buffer -- so
    // the name went to garbage mid-lookup and the initial-value table missed,
    // which is why the *first* property read off a fresh computed style
    // answered "". See css/computed_first_read.html.
    //
    // 128 is well past the longest name Chrome computes
    // (-webkit-text-decorations-in-effect, 35); anything longer falls back to
    // the caller's spelling, exactly as normalizePropertyName does for frame.buf.
    var name_buf: [128]u8 = undefined;
    const normalized = normalizePropertyName(property_name, &name_buf);
    const wrapped = String.wrap(normalized);

    // Computed styles must reflect stylesheet rules, not just the element's
    // inline `style=` attribute. Limited to display/visibility — what aria
    // tree builders (Playwright ariaSnapshot) consult on every element.
    // A custom property is resolved by the cascade rather than stored on the
    // computed declaration: it can come from a stylesheet rule, from the style
    // attribute, or from an ancestor, and nothing precomputes the set.
    if (self._is_computed and isCustomProperty(normalized)) {
        const element = self._element orelse return "";
        const value = frame._style_manager.customPropertyValue(element, normalized) orelse return "";
        // var() is substituted at computed-value time; the specified value
        // that `el.style` hands out keeps its var() text.
        return frame._style_manager.substituteVars(element, value) orelse "";
    }

    if (self._is_computed) {
        if (self._element) |element| {
            const style_manager = &element.ownerFrame(frame)._style_manager;
            if (wrapped.eql(comptime .wrap("display"))) {
                if (style_manager.hasDisplayNone(element)) return "none";
                return resolvedDisplay(element, frame);
            } else if (wrapped.eql(comptime .wrap("visibility"))) {
                // The cascade, not the style attribute: an `!important` rule
                // outranks it (Chrome 151, probe t4-important -- an inline
                // `visibility:hidden` under `.tv{visibility:visible!important}`
                // computes to `visible`). This is the same answer innerText
                // reads, so the two cannot disagree, and it keeps `collapse`
                // distinct from `hidden` the way Chrome reports it. Upstream's
                // hasVisibilityHiddenInherited() cannot express the !important
                // case or tell `collapse` from `hidden`, so it is not used here.
                const value = style_manager.computedVisibility(element) orelse
                    StyleManager.Visibility.visible;
                return value.keyword();
            }
            // Two font longhands whose computed value is not the keyword the
            // author wrote. Measured on Chrome 151
            // (probes/expr-b83-weight-stretch-computed.js and
            // expr-b83-relative-weight.js): `font-weight: bold` computes to
            // `700` and an undeclared one to `400`, and every `font-stretch`
            // keyword computes to a percentage. The SPECIFIED value stays the
            // keyword in both engines, so this is a computed-value mapping and
            // not a parsing difference -- which is why it sits here rather than
            // in the store.
            if (wrapped.eql(comptime .wrap("font-weight"))) {
                return computedFontWeight(style_manager, element, frame, depth);
            } else if (wrapped.eql(comptime .wrap("font-stretch"))) {
                return computedFontStretch(style_manager, element, wrapped);
            } else if (wrapped.eql(comptime .wrap("font"))) {
                // `font` is no longer stored under its own name -- it expands
                // now -- so the generic computed join would answer the recorded
                // initial `16px Times` for every element on every page. It
                // cannot go through `computedShorthandValue` either: that one
                // treats an empty join as "no answer" because Chrome answers
                // every other shorthand off getComputedStyle, and `font` is the
                // one that does answer "" -- measured, for four separate
                // reasons. See computedFontText.
                return self.computedFontText(frame, surface, depth);
            }
            // The used surface only. The CSS Typed OM reports the computed
            // width, which `border-style: none` does not collapse -- see
            // `borderWidth`, and typedom_computed_initial_values, where the two
            // surfaces answer 3px and 0px off the same undeclared border.
            if (surface == .used) {
                if (borderStyleFor(normalized)) |style_name| {
                    return self.computedBorderWidth(element, normalized, wrapped, style_name, frame, surface, depth);
                }
            }
        }
    }

    const prop = self.findProperty(wrapped) orelse {
        // A shorthand is never stored, so it is answered by putting its
        // longhands back together -- and "" is one of the answers, since a
        // `border` whose components all hold their initial value cannot be
        // written as a shorthand at all.
        if (!self._is_computed) {
            if (self.shorthandValue(normalized, frame)) |value| return value;
        }
        // Only return default values for computed styles
        if (self._is_computed) {
            if (self._element) |element| {
                const style_manager = &element.ownerFrame(frame)._style_manager;

                // What the cascade says about this name, and then -- when it says
                // nothing at all -- what it says about the name's other
                // spelling. `margin-block-start` and `margin-top` are one
                // property under two names, so an element declaring either
                // computes both, and this engine stores only what the page
                // wrote. chrome_logical.zig is the measured pairing.
                //
                // Only when the name being asked for has no declaration of its
                // own. A counterpart must never outrank one the page made under
                // this very name, and `unreportable` is a declaration -- the
                // page did set this property, this engine just cannot finish
                // resolving the value. Chrome resolves the both-declared case in
                // one storage slot instead, where the later declaration wins for
                // both names; see css/computed_logical_physical.html.
                // Chrome reports a used width, and a flex item's width is its
                // container's to give -- so a declared one is not the answer
                // when the flex layout overrode it. Measured with
                // tools/fingerprint/scratch/expr-flex-item-width.js:
                // `flex: 1; width: 60px` computes 1904px, because `flex: 1`
                // sizes from a `0%` basis and the width never enters the
                // sizing. Asked before the cascade for that reason; every other
                // case falls through to the same resolvedDimension below.
                const on_width = wrapped.eql(comptime .wrap("width")) or
                    wrapped.eql(comptime .wrap("inline-size")) or
                    wrapped.eqlSlice("-webkit-logical-width");
                const on_height = wrapped.eql(comptime .wrap("height")) or
                    wrapped.eql(comptime .wrap("block-size")) or
                    wrapped.eqlSlice("-webkit-logical-height");

                if (on_width and flexItemWidth(element, frame, 0, true, boxEdges(element, frame)) != null) {
                    return resolvedDimension(element, .width, frame);
                }

                // `box-sizing: border-box` moves which box a declaration names,
                // so the declaration is not the computed answer either.
                // Measured: `width:20px` with 10px of padding and 5px of border
                // per side computes `30px` -- the border box, clamped up to
                // what its own parts need, with nothing left for the content.
                if ((on_width or on_height) and !isInlineBox(element, frame) and
                    usesBorderBox(element, frame))
                {
                    return resolvedDimension(element, if (on_width) .width else .height, frame);
                }

                // `width` and `height` report a USED value, so whatever the
                // cascade says lands on the layout grid: a declared `133.2px`
                // computes `133.188px` in Chrome, measured. The cascade still
                // answers rather than the box, because a detached element has
                // no box to measure and Chrome hands back the declaration
                // there. Asked after the two above, which decide that the
                // declaration is not the answer at all.
                if ((on_width or on_height) and declaredInPixels(style_manager, element, normalized, wrapped)) {
                    const specified = if (declaredDeclaration(style_manager, element, normalized, wrapped)) |d| d.specified else null;
                    switch (cascadedValue(style_manager, element, normalized, wrapped)) {
                        .value => |value| if (usedLengthText(value, specified, frame)) |snapped| return snapped,
                        .unreportable, .none => {},
                    }
                }

                switch (cascadedValue(style_manager, element, normalized, wrapped)) {
                    .value => |value| return self.resolveCurrentColour(value, frame, surface),
                    .unreportable => {},
                    .none => if (chrome_logical.counterpart(normalized)) |other| {
                        switch (cascadedValue(style_manager, element, other, .wrap(other))) {
                            .value => |value| return self.resolveCurrentColour(value, frame, surface),
                            .unreportable, .none => {},
                        }
                    },
                }

                // A shorthand this engine expands is never stored under its own
                // name, so the computed view answers it the way an inline
                // declaration does: by putting the longhands back together.
                // They go through propertyValue rather than findProperty,
                // because a computed view stores none of them either -- each
                // one is the cascade's answer or the recorded initial value.
                //
                // Only the shorthands the table models are joined, and only
                // after the cascade above has had its say. One the table keeps
                // whole -- `font`, `columns`, `border-image` -- is stored under
                // its own name, so the cascade answered it already, and joining
                // its longhands would report the initial value over the
                // author's own text.
                if (depth < MAX_PROPERTY_DEPTH and !declinesComputedJoin(normalized)) {
                    if (shorthand.lookup(normalized)) |entry| {
                        if (self.computedShorthandValue(normalized, entry, frame, surface, depth)) |value| return value;
                    }
                }

                // Sixteen longhands have `currentcolor` as their initial value,
                // so an element that declares none of them still answers its own
                // colour for all sixteen. chrome_initial_values recorded one
                // number for each, measured on an element whose text was black,
                // which is right exactly while a page leaves it black.
                if (chrome_current_color.followsColor(normalized)) {
                    return self.propertyValueAt("color", frame, surface, depth + 1);
                }

                // Computed width/height must agree with the synthetic layout
                // metrics. Returning "" makes measurement code see
                // contradictory sizes — jQuery's "shrink text until it fits"
                // loops then never terminate. jQuery's .width() reads this
                // value, so it must also carry clientWidth's content fallback
                // or append-until-wide marquee loops never terminate.
                if (wrapped.eql(comptime .wrap("width")) or wrapped.eql(comptime .wrap("inline-size")) or wrapped.eqlSlice("-webkit-logical-width")) {
                    return resolvedDimension(element, .width, frame);
                }
                if (wrapped.eql(comptime .wrap("height")) or wrapped.eql(comptime .wrap("block-size")) or wrapped.eqlSlice("-webkit-logical-height")) {
                    return resolvedDimension(element, .height, frame);
                }
                // The other two the recorded table deliberately has no entry
                // for: both origins are the box's centre, so they follow the
                // same metrics rather than a stored number. `inline-size` and
                // `block-size` above are the logical spellings of the physical
                // pair, which is what they resolve to in a horizontal-tb box —
                // the only writing mode this engine lays out, and the
                // `-webkit-logical-*` pair is the legacy spelling of the same.
                if (wrapped.eqlSlice("transform-origin") or wrapped.eqlSlice("perspective-origin") or
                    wrapped.eqlSlice("-webkit-transform-origin") or wrapped.eqlSlice("-webkit-perspective-origin"))
                {
                    return boxCentre(element, frame, wrapped.str());
                }
            }
            return getDefaultPropertyValue(self, wrapped, surface);
        }
        return "";
    };
    return prop._value.str();
}

/// What the cascade says about one property name on one element: what the
/// element itself was given, and then -- for a property a child takes from its
/// parent -- what the nearest ancestor that declares one was given.
///
/// The ancestor walk stops at the first ancestor with a declaration whether or
/// not that declaration can be reported: an ancestor declaring
/// `letter-spacing:2em` is the one that decides the answer, so a grandparent's
/// `3px` must not show through it.
fn cascadedValue(style_manager: *StyleManager, element: *Element, property_name: []const u8, wrapped: String) Declared {
    switch (declaredValue(style_manager, element, property_name, wrapped)) {
        .value => |value| return .{ .value = value },
        .unreportable => return .unreportable,
        .none => {},
    }
    if (!chrome_inherited.inherits(property_name)) {
        return .none;
    }
    const on_line_height = std.mem.eql(u8, property_name, "line-height");
    var ancestor = element.parentElement();
    while (ancestor) |current| : (ancestor = current.parentElement()) {
        // An inherited length is the ancestor's resolved px -- `letter-spacing:
        // 2em` on a 20px ancestor is 40px on every descendant whatever their
        // own size. A bare number on `line-height` is the exception: it
        // computes to the number itself, so what comes down is the number and
        // each element multiplies it by its own font size. Measured on Chrome
        // 151 (probes/expr-line-height-number.js): 1.5 declared on a 16px
        // parent is 24px there, 108px on a 72px child and 15px on a 10px
        // grandchild, where `30px` and `150%` hand the same px to all three.
        if (on_line_height) {
            if (declaredDeclaration(style_manager, current, property_name, wrapped)) |declaration| {
                const trimmed = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
                if (units.parse(trimmed)) |parsed| {
                    if (parsed.unit == .none) {
                        if (computedLengthText(style_manager, element, property_name, declaration.value, declaration.specified)) |px| {
                            return .{ .value = px };
                        }
                    }
                } else |_| {}
            }
        }
        switch (declaredValue(style_manager, current, property_name, wrapped)) {
            .value => |value| return .{ .value = value },
            .unreportable => return .unreportable,
            .none => {},
        }
    }
    return .none;
}

/// What one element was declared for a property: nothing, something this engine
/// cannot report, or the value to report.
const Declared = union(enum) {
    none,
    unreportable,
    value: []const u8,
};

/// The value `element` itself was declared for `property_name`, ranking the
/// author cascade against the style attribute the way CSS Cascade §6.2 does: an
/// `!important` rule first, then the style attribute, then a normal rule. That
/// is the order computedFontSize spells out for its one property, generalised.
///
/// `var()` is substituted at computed-value time either way; the specified value
/// `el.style` hands out keeps its var() text.
fn declaredValue(style_manager: *StyleManager, element: *Element, property_name: []const u8, wrapped: String) Declared {
    const declaration = declaredDeclaration(style_manager, element, property_name, wrapped) orelse
        return flexShorthandDeclared(style_manager, element, property_name);
    const substituted = declaration.value;
    const frame = element.ownerFrame(style_manager.frame);

    // `transform` computes to one matrix rather than to the list the author
    // wrote. A function this engine does not model answers `unreportable`, so
    // the initial `none` is reported instead of a spelling Chrome never prints.
    if (std.mem.eql(u8, property_name, "transform")) {
        const folded = transform.computedValue(frame.call_arena, substituted) catch null;
        return if (folded) |matrix| .{ .value = matrix } else .unreportable;
    }

    // An origin resolves its whole value against the border box, so it cannot go
    // through the generic length path: that one refuses a percentage and knows
    // nothing about `left`. Null means the element has no box, and Chrome
    // reports the specified value there -- `unreportable` leaves the fallback
    // that already does that.
    if (isOriginProperty(property_name)) {
        if (resolvedOrigin(style_manager, element, property_name, substituted)) |px| {
            return .{ .value = px };
        }
        return .unreportable;
    }

    if (computedColourText(frame.call_arena, property_name, substituted)) |folded| {
        return .{ .value = folded };
    }

    // A length resolves at computed-value time, so the unit the author wrote is
    // one a computed style never carries: `padding-top:2em` on a 20px element
    // is `40px` in every browser, and so is `12pt`.
    if (computedLengthText(style_manager, element, property_name, substituted, declaration.specified)) |px| {
        return .{ .value = px };
    }

    // What is left is either already in the shape a computed style has, or a
    // length this engine cannot finish resolving -- a percentage against a
    // containing block it does not model, an `ex` it has no font metrics for, a
    // `calc()` it does not evaluate. Those are *not* reported: answering the
    // author's text would trade one wrong answer for a wronger one, since `0px`
    // is a value Chrome does print here and `2em` is one it never prints.
    // `unreportable` leaves the initial value that was reported before the
    // cascade was consulted at all, which is never worse.
    //
    // The guard runs on the substituted text rather than the declaration's, so a
    // `var()` holding a relative length is caught too -- it used to pass, having
    // no unit of its own to see, and leak the substituted `2em` straight out.
    if (!resolvesHere(element, frame, property_name, substituted)) {
        return .unreportable;
    }
    return .{ .value = substituted };
}

/// The declaration text one element carries for a property, with its `var()`
/// substituted and before anything a computed style does to it. Null when
/// neither a rule nor the style attribute declares it.
fn declaredText(style_manager: *StyleManager, element: *Element, property_name: []const u8, wrapped: String) ?[]const u8 {
    const declaration = declaredDeclaration(style_manager, element, property_name, wrapped) orelse return null;
    return declaration.value;
}

/// declaredText with the author's number still attached, for the callers that
/// want the value rather than its print. `value` has already had `var()`
/// substituted; `specified` is null whenever the substitution changed anything,
/// because the number belongs to the text that was stored and not to what came
/// out of a custom property.
fn declaredDeclaration(style_manager: *StyleManager, element: *Element, property_name: []const u8, wrapped: String) ?StyleManager.Declaration {
    const rule = style_manager.cascadedLonghand(element, property_name);
    const inline_declaration = style_manager.inlineStyleDeclaration(element, wrapped);
    const rule_wins = if (rule) |declaration| declaration.important and
        !(inline_declaration != null and inline_declaration.?.important) else false;

    const winner: ?StyleManager.Declaration = if (rule_wins)
        rule
    else if (inline_declaration) |declaration|
        declaration
    else
        rule;

    const declaration = winner orelse return null;
    const substituted = style_manager.substituteVars(element, declaration.value) orelse "";
    return .{
        .value = substituted,
        .important = declaration.important,
        .specified = if (std.mem.eql(u8, substituted, declaration.value)) declaration.specified else null,
    };
}

/// What `flex-grow`, `flex-shrink` and `flex-basis` read when nothing declared
/// them but a `flex` shorthand did.
///
/// `flex` is `.unmodelled` in chrome_shorthands.zig -- no distribution rule
/// reproduced every reading, because `flex: none` is `0 0 auto` while every
/// other value fills the two numbers and then the basis -- so the declaration
/// is kept whole and the three longhands had nothing declared at all. Chrome
/// stores them, so `getComputedStyle(el).flexGrow` on `flex: 1` reads 1 there
/// and read the initial 0 here, and the layout asking whether an item grows
/// read that same 0. The declaration is still stored whole, so `style.length`
/// answers 1 where Chrome says 3; only the computed read is derived.
fn flexShorthandDeclared(style_manager: *StyleManager, element: *Element, property_name: []const u8) Declared {
    if (!std.mem.eql(u8, property_name, "flex-grow") and
        !std.mem.eql(u8, property_name, "flex-shrink") and
        !std.mem.eql(u8, property_name, "flex-basis")) return .none;

    // The raw declaration rather than declaredValue's: a `flex: 50%` would come
    // back `unreportable` from the computed path, which refuses a percentage it
    // cannot resolve, and the percentage is exactly what the basis keeps.
    const value = declaredText(style_manager, element, "flex", comptime .wrap("flex")) orelse return .none;
    const part = flexShorthandPart(value, property_name) orelse return .none;
    return .{ .value = part };
}

/// One longhand of a `flex` shorthand, or null when the value does not parse --
/// which is the same answer, because Chrome drops a `flex` it cannot parse and
/// the three initial values are what a dropped declaration leaves behind.
///
/// Measured with tools/fingerprint/scratch/expr-flex-shorthand.js against
/// Chrome 151: `1` is `1 1 0%`, `0` is `0 1 0%`, `none` is `0 0 auto`, `auto`
/// and `1 auto` are `1 1 auto`, `2 3` is `2 3 0%`, `200px` and `1 200px` are
/// `1 1 200px`, `2 3 40px` is itself, `50%` is `1 1 50%`, and `content` is
/// `1 1 content`. So the numbers fill grow and then shrink, anything else is
/// the basis, and what the value left out is 1, 1 and `0%` -- except after
/// `none`, which is the one value no distribution rule covers.
fn flexShorthandPart(value: []const u8, longhand: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    const on_grow = std.mem.eql(u8, longhand, "flex-grow");
    const on_shrink = std.mem.eql(u8, longhand, "flex-shrink");

    if (std.ascii.eqlIgnoreCase(trimmed, "none")) {
        return if (on_grow or on_shrink) "0" else "auto";
    }

    var grow: ?[]const u8 = null;
    var shrink: ?[]const u8 = null;
    var basis: ?[]const u8 = null;

    var seen: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    while (it.next()) |token| {
        seen += 1;
        if (seen > 3) return null;
        if (isFlexFactor(token)) {
            if (grow == null) {
                grow = token;
            } else if (shrink == null) {
                shrink = token;
            } else return null;
            continue;
        }
        if (basis != null or !isFlexBasis(token)) return null;
        basis = token;
    }

    if (on_grow) return grow orelse "1";
    if (on_shrink) return shrink orelse "1";
    return basis orelse "0%";
}

/// A `flex` component that is one of the two factors: a bare number, which is
/// the only shape either takes.
fn isFlexFactor(token: []const u8) bool {
    const parsed = units.parse(token) catch return false;
    return parsed.unit == .none;
}

/// A `flex` component that is the basis: a length or percentage, or one of the
/// keywords `flex-basis` takes. A bare `0` is NOT one -- measured,
/// expr-flex-more.js: `flex-basis: 0` is dropped and the item comes out at its
/// content width.
fn isFlexBasis(token: []const u8) bool {
    const KEYWORDS = [_][]const u8{ "auto", "content", "min-content", "max-content", "fit-content" };
    for (KEYWORDS) |keyword| {
        if (std.ascii.eqlIgnoreCase(token, keyword)) return true;
    }
    const parsed = units.parse(token) catch return false;
    return parsed.unit != .none;
}

/// The properties whose computed value keeps a percentage rather than resolving
/// it against anything. Measured with expr-flex-shorthand.js: `flex: 50%`
/// computes to `1 1 50%`, so the basis is one of them. Every other percentage
/// this engine cannot resolve is still refused rather than reported as written.
fn percentageIsComputedValue(property_name: []const u8) bool {
    const NAMES = std.StaticStringMap(void).initComptime(.{
        // Resolved against the image at paint time, so the computed value keeps
        // the percentage.
        .{ "background-position", {} },
        .{ "background-position-x", {} },
        .{ "background-position-y", {} },
        .{ "background-size", {} },
        .{ "object-position", {} },
        .{ "mask-position", {} },
        // Not a length against anything at all: `font-stretch` IS a percentage,
        // and every one of its nine keywords computes to one. Measured
        // (probes/expr-b83-weight-stretch-computed.js): `50%` computes to `50%`,
        // where this engine reported the initial `100%` because a percentage it
        // could not resolve against a box was refused.
        .{ "font-stretch", {} },
        // Resolved against the box at LAYOUT time, which is later than computed
        // value: a percentage radius, translate or inset is reported as written.
        .{ "border-top-left-radius", {} },
        .{ "border-top-right-radius", {} },
        .{ "border-bottom-left-radius", {} },
        .{ "border-bottom-right-radius", {} },
        .{ "border-start-start-radius", {} },
        .{ "border-start-end-radius", {} },
        .{ "border-end-start-radius", {} },
        .{ "border-end-end-radius", {} },
        .{ "translate", {} },
        .{ "top", {} },
        .{ "right", {} },
        .{ "bottom", {} },
        .{ "left", {} },
        .{ "inset-block-start", {} },
        .{ "inset-block-end", {} },
        .{ "inset-inline-start", {} },
        .{ "inset-inline-end", {} },
        // Resolved against the line box, likewise later.
        .{ "vertical-align", {} },
        .{ "text-indent", {} },
        // Resolved against the flex line by the flex container.
        .{ "flex-basis", {} },
    });
    return NAMES.has(property_name);
}

/// Whether a percentage on this property stays a percentage for THIS element,
/// as opposed to for every element (which is percentageIsComputedValue).
///
/// One case, and it is about the element rather than the property: a
/// `display: none` element has no box, so a percentage that would be a share of
/// its containing block has nothing to be a share of -- and Chrome reports it as
/// written rather than inventing a box. `width: 50%` stays `50%`, and so do
/// `padding-left: 10%` and `margin-left: 10%`.
///
/// Measured on Chrome 151 with
/// tools/fingerprint/scratch/expr-display-none-percentages.js over 36 longhands
/// in seven states. Two of those states are what makes this "no box" rather than
/// "a zero box", and both are assertions in
/// css/computed_unrendered_percentages.html: `visibility: hidden` still has a box
/// and still resolves, and a rendered `width:0;height:0` element resolves to 0 --
/// which is the answer this engine used to give the unrendered one.
fn percentageStaysHere(element: *Element, frame: *Frame, property_name: []const u8) bool {
    if (!percentageOfTheBox(property_name)) return false;
    return !element.checkVisibilityCached(null, frame);
}

/// The properties whose percentage is a share of the element's own containing
/// block, on either axis. `percentageOfContainingBlockWidth` is the subset that
/// takes the WIDTH -- which is all of them except the block axis of `height`, and
/// the reason the two lists are not one: a percentage padding is a share of the
/// width top and bottom included, measured, while a percentage height is a share
/// of the height.
///
/// Only asked about an element with no box, where the axis no longer matters
/// because neither is being measured. `top`/`left`/`right`/`bottom` are
/// deliberately absent: Chrome reports a percentage there verbatim whether the
/// element is rendered or not -- `top: 10%` is `10%` on a rendered element too,
/// measured -- so they are `percentageIsComputedValue`'s business and not this
/// one, and this engine answers `auto` for them in both states.
fn percentageOfTheBox(property_name: []const u8) bool {
    if (percentageOfContainingBlockWidth(property_name)) return true;
    return std.mem.eql(u8, property_name, "height") or
        std.mem.eql(u8, property_name, "block-size");
}

/// What a position keyword computes to, or null when this property has no
/// position keywords or the token is not one.
///
/// A position keyword is shorthand for one of three percentages -- `left` and
/// `top` for 0%, `center` for 50%, `right` and `bottom` for 100% -- and Chrome's
/// computed style prints the percentage: `background-position: left 30%` is
/// `0% 30%` and not `left 30%`. Measured on Chrome 151, twenty-three readings
/// over background-position, its two longhands and object-position
/// (css/computed_position_keywords.html asserts all of them).
///
/// Which axis a keyword takes is NOT decided here for the two-token form, and
/// does not need to be: this engine's `background-position` expansion already
/// assigns them, so `30% center` arrives as `30%` then `center` and `center 30%`
/// as `center` then `30%`. The same word is vertical in the first and horizontal
/// in the second, and both come out right because the percentage is the same
/// either way. That is what makes this a token map rather than a grammar.
///
/// The ONE-token form does need the axis, and only `object-position` reaches
/// here with one: `background-position` has already grown its second axis by
/// then. See twoAxisPosition.
///
/// Gated on the property, because the rule is about POSITION keywords and not
/// about keywords: `vertical-align: top` stays `top` and `background-size: cover`
/// stays `cover`. Both are assertions, so a later widening of this list cannot
/// take them with it.
///
/// `mask-position` is deliberately absent even though the same rule applies to
/// it: measured, it never reaches this path -- `mask-position: left` still comes
/// out `left center` with this map in place, and `mask-position: 30%` comes out
/// `0% center`, wrong in the first slot too. It has an expansion of its own with
/// a defect of its own, recorded rather than papered over by a name here that
/// would do nothing.
fn positionKeywordPercentage(property_name: []const u8, token: []const u8) ?[]const u8 {
    const PROPERTIES = std.StaticStringMap(void).initComptime(.{
        .{ "background-position", {} },
        .{ "background-position-x", {} },
        .{ "background-position-y", {} },
        .{ "object-position", {} },
    });
    if (!PROPERTIES.has(property_name)) return null;

    if (std.ascii.eqlIgnoreCase(token, "left") or std.ascii.eqlIgnoreCase(token, "top")) {
        return "0%";
    }
    if (std.ascii.eqlIgnoreCase(token, "center")) return "50%";
    if (std.ascii.eqlIgnoreCase(token, "right") or std.ascii.eqlIgnoreCase(token, "bottom")) {
        return "100%";
    }
    return null;
}

/// The position properties that always print BOTH axes, so a one-value
/// declaration grows the axis it left out. Measured on Chrome 151:
/// `object-position: left` is `0% 50%`, `top` is `50% 0%`, `30%` is `30% 50%`,
/// `2em` is `32px 50%` and `10px` is `10px 50%` -- the missing axis is always
/// 50%, and only `top` and `bottom` take the second slot, being the two keywords
/// that name the vertical axis and nothing else.
///
/// `background-position` is not in the list because it never arrives here with
/// one token: its own expansion has already made the pair, and all three of the
/// length forms above were measured coming out right through it.
fn twoAxisPosition(property_name: []const u8) bool {
    return std.mem.eql(u8, property_name, "object-position");
}

/// The px a computed style reports for a declaration written in some other
/// length unit, or null when nothing here needed converting and the value can go
/// through as it stands.
///
/// Null is also the answer for a length this engine cannot resolve, which leaves
/// the caller's guard to refuse it. The two it refuses are measured refusals
/// rather than gaps waiting to be filled: a percentage against a containing
/// block, because nothing here models one, and `ex`/`ch`, because
/// scratch/expr-ex-ch-ratio.js shows the ratio to the font size is exactly
/// constant per family and different for every family tried -- font metrics, not
/// a number. The two percentages that need no containing block are resolved:
/// `font-size` against the parent's size and `line-height` against the element's
/// own.
fn computedLengthText(style_manager: *StyleManager, element: *Element, property_name: []const u8, value: []const u8, specified: ?f64) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    // Functions and comma lists are somebody else's: `rgb(1, 2, 3)` and
    // `calc(10px + 5px)` both have digits in them and neither is a length this
    // walk can take apart.
    for (trimmed) |c| {
        if (c == '(' or c == ')' or c == ',') return null;
    }

    const frame = element.ownerFrame(style_manager.frame);
    var buf = std.Io.Writer.Allocating.init(frame.call_arena);
    const writer = &buf.writer;
    var converted = false;
    var first = true;
    // Whether the whole value is the one token `specified` was taken from.
    const single_token = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) == null;
    // One or two tokens, which is the only shape the position keyword map is
    // measured for: `background-position` also takes a three- and four-value
    // form (`left 10px top 20px`) whose computed value nobody has measured here,
    // and mapping its keywords word by word would turn it into a four-value list
    // of percentages that Chrome does not print. Those go through untouched, the
    // same as before.
    const single_or_pair = blk: {
        var count: usize = 0;
        var walk = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
        while (walk.next()) |_| count += 1;
        break :blk count <= 2;
    };
    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    while (it.next()) |token| {
        if (!first) writer.writeByte(' ') catch return null;
        first = false;

        // A token with no digit in it is a keyword -- `solid`, `Georgia`,
        // `normal` -- and goes through untouched.
        const numeric = for (token) |c| {
            if (std.ascii.isDigit(c)) break true;
        } else false;
        if (!numeric) {
            // A position keyword IS a percentage, so it converts here rather
            // than going through untouched. See positionKeywordPercentage.
            if (single_or_pair) {
                if (positionKeywordPercentage(property_name, token)) |pct| {
                    writer.writeAll(pct) catch return null;
                    converted = true;
                    continue;
                }
            }
            writer.writeAll(token) catch return null;
            continue;
        }

        const parsed = units.parse(token) catch return null;
        // `specified` belongs to the value as a whole, which is why it is only
        // ever the first token's: specifiedNumber refuses anything with a
        // second one in it, so this branch and that refusal describe the same
        // shape from either end.
        const number = if (single_token) specified orelse parsed.value else parsed.value;
        switch (lengthFactor(style_manager, element, property_name, parsed.unit)) {
            .unresolvable => return null,
            .verbatim => writer.writeAll(token) catch return null,
            .pixels => |factor| {
                const product = number * factor;
                // A percentage resolves against a used length, so its answer is
                // one too and lands on the layout grid: `33.3%` of 400px is
                // `133.188px` in Chrome and not 133.2. So does anything at all
                // on `width` or `height`, which report the used value whatever
                // unit the page wrote. A length in some other unit on any other
                // property is only converted, not laid out -- `0.5em` of a
                // 13.3px font is `6.65px` there -- so it goes through as it is.
                const snaps = parsed.unit == .percentage or usedLengthProperty(property_name);
                units.writeNumber(writer, if (snaps)
                    Element.layoutUnit(product)
                else
                    product) catch return null;
                writer.writeAll("px") catch return null;
                converted = true;
            },
        }
    }
    // A one-value `object-position` prints both axes, with the one it left out
    // as 50%. `top` and `bottom` are the two keywords that name the vertical
    // axis and nothing else, so they take the second slot; everything else --
    // keyword, percentage or length -- takes the first. See twoAxisPosition.
    if (single_token and twoAxisPosition(property_name)) {
        const one = buf.written();
        var pair = std.Io.Writer.Allocating.init(frame.call_arena);
        const vertical_only = std.ascii.eqlIgnoreCase(trimmed, "top") or
            std.ascii.eqlIgnoreCase(trimmed, "bottom");
        if (vertical_only) {
            pair.writer.writeAll("50% ") catch return null;
            pair.writer.writeAll(one) catch return null;
        } else {
            pair.writer.writeAll(one) catch return null;
            pair.writer.writeAll(" 50%") catch return null;
        }
        return pair.written();
    }

    if (!converted) return null;
    return buf.written();
}

/// What one token of a declaration has to become.
const LengthFactor = union(enum) {
    /// Already what a computed style carries; the token goes through as it is.
    verbatim,
    /// CSS pixels per unit, to multiply the token's number by.
    pixels: f64,
    /// A unit this engine cannot resolve here, so the whole value is refused.
    unresolvable,
};

fn lengthFactor(style_manager: *StyleManager, element: *Element, property_name: []const u8, unit: units.Unit) LengthFactor {
    const on_font_size = std.mem.eql(u8, property_name, "font-size");
    const on_line_height = std.mem.eql(u8, property_name, "line-height");

    if (unit == .px) return .verbatim;

    // A bare number is a length only for `line-height`, where it is a multiple
    // of the element's font size. Everywhere else -- `opacity`, `z-index`,
    // `flex-grow`, `order` -- the number *is* the computed value.
    if (unit == .none) {
        if (!on_line_height) return .verbatim;
        return .{ .pixels = style_manager.computedFontSize(element) };
    }

    if (units.absoluteLengthFactor(unit)) |factor| {
        return .{ .pixels = factor };
    }

    const viewport = element.ownerFrame(style_manager.frame)._page.getViewport();
    const width: f64 = @floatFromInt(viewport.width);
    const height: f64 = @floatFromInt(viewport.height);
    return switch (unit) {
        // `em` is the element's own computed font size, except on `font-size`
        // itself, where it is the parent's -- measured, expr-relative-units.js:
        // `font-size:1.5em` under a 20px parent computes to 30px.
        .em => .{ .pixels = if (on_font_size)
            style_manager.computedFontSize(element.parentElement())
        else
            style_manager.computedFontSize(element) },
        .rem => .{ .pixels = style_manager.computedFontSize(rootElement(element)) },
        // `ex` is the x-height of the element's first available font and `ch`
        // the advance of its `0`, so both are per-family constants that the
        // font size alone cannot give. This engine answered a flat `0px` for
        // every one, which is the shape a guard reads as a probe that cannot
        // tell its inputs apart rather than as a wrong number.
        //
        // font_metrics.zig has carried both all along: the per-glyph table is
        // measured at basis 100, `x`'s ink ascent is the x-height and `0`'s
        // advance is the ch width. Twelve family/unit pairs check out to the
        // digit against headed Chrome 151 -- see computed_relative_units.html.
        .ex, .ch => blk: {
            const family = if (style_manager.computedFontFamily(element)) |declared|
                font_metrics.findInList(declared)
            else
                font_metrics.fallback;
            const g = font_metrics.glyph(family, if (unit == .ex) 'x' else '0') orelse
                break :blk .unresolvable;
            const ratio = (if (unit == .ex) g.ascent else g.advance) / font_metrics.basis;
            break :blk .{ .pixels = style_manager.computedFontSize(element) * ratio };
        },
        // `font-size` and `line-height` are the two percentages with no
        // containing block in them. `width` now has one -- the containing
        // block's width is what a block-level box already takes when it
        // declares nothing -- so it is no longer refused.
        .percentage => if (on_font_size)
            .{ .pixels = style_manager.computedFontSize(element.parentElement()) / 100.0 }
        else if (on_line_height)
            .{ .pixels = style_manager.computedFontSize(element) / 100.0 }
        else if (percentageIsComputedValue(property_name))
            .verbatim
        else if (percentageOfContainingBlockWidth(property_name)) blk: {
            const frame = element.ownerFrame(style_manager.frame);
            // A `display: none` element has no box, so there is nothing for the
            // percentage to be a share of -- and Chrome does not invent one. It
            // reports the percentage as written: `width: 50%` stays `50%`, and
            // so do `padding-left: 10%` and `margin-left: 10%`. This engine
            // resolved against the containing block regardless and answered
            // `200px` and `40px`, which are the numbers a RENDERED element with
            // that declaration gets.
            //
            // Measured on Chrome 151 with
            // tools/fingerprint/scratch/expr-display-none-percentages.js over 36
            // longhands in seven states. Two of those states are what makes this
            // "no box" rather than "a zero box": `visibility: hidden` still has a
            // box and still resolves, and a rendered `width:0;height:0` element
            // resolves to 0 -- which is the answer this used to give the
            // unrendered one. And a percentage `line-height` is `24px` in both
            // states, because it resolves against the font size and not a box, so
            // this sits inside the containing-block branch and not above it.
            if (!element.checkVisibilityCached(null, frame)) break :blk .verbatim;
            // The containing block, which is not always the parent: an inline
            // box is not one, so `<span><div style="width:50%">x</div></span>`
            // takes its half from the block the span sits in. Chrome answers
            // 952 on the 1904px line, measured -- and asking the span instead
            // was a closed loop, because the span's own ink is the div's box.
            const parent = element.containingBlock(frame) orelse break :blk .unresolvable;
            break :blk .{ .pixels = parent.getElementDimensions(frame).width / 100.0 };
        } else .unresolvable,
        .vw => .{ .pixels = width / 100.0 },
        .vh => .{ .pixels = height / 100.0 },
        .vmin => .{ .pixels = @min(width, height) / 100.0 },
        .vmax => .{ .pixels = @max(width, height) / 100.0 },
        else => .unresolvable,
    };
}

/// The properties whose percentage is a share of the containing block's width.
///
/// The two spellings of `width`, all four paddings and all four margins.
/// Measured with tools/fingerprint/scratch/expr-percentage-width.js:
/// `width:50%` in a 400px parent is 200px, in a parent that declares nothing it
/// is half the 1904 that parent itself took, and in a shrink-to-fit parent it is
/// half of what that parent's content came to.
///
/// A padding and a margin each take their share of the same width on BOTH axes,
/// which is the part worth writing down: expr-box-parts.js puts `width:400px;
/// padding:10%` in the 1904px line at 190.391px per side, top and bottom
/// included, so its clientHeight is 399 and not 18, and expr-margin-pct.js puts
/// `margin-top:10%` of a 400px line at 40px.
fn percentageOfContainingBlockWidth(property_name: []const u8) bool {
    const NAMES = [_][]const u8{
        "width",                "inline-size",
        "padding-left",         "padding-right",
        "padding-top",          "padding-bottom",
        "padding-inline-start", "padding-inline-end",
        "padding-block-start",  "padding-block-end",
        "margin-left",          "margin-right",
        "margin-top",           "margin-bottom",
        "margin-inline-start",  "margin-inline-end",
        "margin-block-start",   "margin-block-end",
    };
    for (NAMES) |name| {
        if (std.mem.eql(u8, property_name, name)) return true;
    }
    return false;
}

/// The document element, whose font size `rem` is a multiple of.
fn rootElement(element: *Element) ?*Element {
    var current = element;
    while (current.parentElement()) |parent| current = parent;
    return current;
}

/// Whether a specified value is already in the shape a computed style reports,
/// so the cascade's answer can be handed straight back.
///
/// The three that are not: `calc()`, which a browser reduces; a font- or
/// viewport-relative length, which resolves against the element's own font or
/// the viewport; and a percentage, which resolves against the containing block.
/// A bare number counts for `line-height`, where it means a multiple of the
/// font size and Chrome reports the product in px.
fn resolvesHere(element: *Element, frame: *Frame, property_name: []const u8, value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;

    if (std.ascii.indexOfIgnoreCase(trimmed, "calc(") != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '%') != null and
        !percentageIsComputedValue(property_name) and
        !percentageStaysHere(element, frame, property_name)) return false;

    if (std.mem.eql(u8, property_name, "line-height")) {
        // `normal` and a length are reportable; a bare multiplier is not, and a
        // bare number is the one with no alphabetic tail.
        if (std.ascii.isDigit(trimmed[0]) or trimmed[0] == '.') {
            const has_unit = for (trimmed) |c| {
                if (std.ascii.isAlphabetic(c)) break true;
            } else false;
            if (!has_unit) return false;
        }
    }

    // The unit is the alphabetic tail of a numeric token, so this walks the
    // value looking for one rather than tokenising it properly -- a family name
    // like `Georgia` has no digit in front of it and is left alone.
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (!std.ascii.isDigit(trimmed[i]) and trimmed[i] != '.') continue;
        while (i < trimmed.len and (std.ascii.isDigit(trimmed[i]) or trimmed[i] == '.')) : (i += 1) {}
        const unit_start = i;
        while (i < trimmed.len and std.ascii.isAlphabetic(trimmed[i])) : (i += 1) {}
        if (i == unit_start) continue;
        for (RELATIVE_UNITS) |unit| {
            if (std.ascii.eqlIgnoreCase(trimmed[unit_start..i], unit)) return false;
        }
    }
    return true;
}

/// Length units a computed value never carries, because they resolve before it.
const RELATIVE_UNITS = [_][]const u8{
    "em",    "ex",    "rem",   "ch",    "cap",   "ic",    "lh",  "rlh",
    "vw",    "vh",    "vmin",  "vmax",  "vi",    "vb",    "svw", "svh",
    "lvw",   "lvh",   "dvw",   "dvh",   "rex",   "rch",   "ric", "rcap",
    "svmin", "svmax", "lvmin", "lvmax", "dvmin", "dvmax",
};

/// The shorthand `name` reads back as, or null when it is not a shorthand this
/// engine joins or not every longhand it covers is in the declaration. Reading
/// one back is a wider set than storing one: `border-image` joins here without
/// being expandable, so `getPropertyValue("border-image")` answers the same
/// text cssText writes.
fn shorthandValue(self: *const CSSStyleDeclaration, name: []const u8, frame: *Frame) ?[]const u8 {
    const entry = shorthand.lookupJoinable(name) orelse return null;
    const held = frame.local_arena.alloc([]const u8, entry.longhands.len) catch return null;
    for (entry.longhands, held) |longhand, *value| {
        const prop = self.findProperty(.wrap(longhand)) orelse return null;
        value.* = prop._value.str();
    }
    return shorthand.join(frame.local_arena, entry, held) catch null;
}

/// Three shorthands Chrome serialises differently off a computed style than off
/// a declared one, measured with tools/fingerprint/scratch/expr-computed-shorthands.js
/// against Chrome 151: a computed `animation` reads `none` where the declared
/// form spells all eight components; a computed `background` puts the layer's
/// colour first and writes every slot; a computed `flex-flow` keeps `nowrap`
/// where the declared form drops it. chrome_shorthands measured the declared
/// serialisation -- that is what a page can write -- so joining these off a
/// computed view answers the wrong shape. The recorded initial value stands
/// instead, which is what they answered before the join existed: all three were
/// already wrong on a declaring element, and this keeps them right on one that
/// declares nothing.
const COMPUTED_JOIN_DECLINED = [_][]const u8{
    "animation",         "-webkit-animation",
    "background",        "flex-flow",
    "-webkit-flex-flow",
};

fn declinesComputedJoin(name: []const u8) bool {
    for (COMPUTED_JOIN_DECLINED) |declined| {
        if (std.mem.eql(u8, name, declined)) return true;
    }
    return false;
}

/// The style longhand that decides whether a border-width longhand is drawn, or
/// null for every other name. `border-image-width` is not one of these: it has
/// no style beside it and answers a number, not a length.
fn borderStyleFor(name: []const u8) ?[]const u8 {
    const PAIRS = [_][2][]const u8{
        .{ "border-top-width", "border-top-style" },
        .{ "border-right-width", "border-right-style" },
        .{ "border-bottom-width", "border-bottom-style" },
        .{ "border-left-width", "border-left-style" },
        .{ "border-block-start-width", "border-block-start-style" },
        .{ "border-block-end-width", "border-block-end-style" },
        .{ "border-inline-start-width", "border-inline-start-style" },
        .{ "border-inline-end-width", "border-inline-end-style" },
    };
    for (PAIRS) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// A computed `border-*-width` is a used value: what the border is actually
/// drawn at, not the length the page wrote. Measured on Chrome 151 over six
/// styles x eleven widths with tools/fingerprint/scratch/expr-border-width-used.js.
///
///   * `none` and `hidden` draw nothing, so the width is `0px` however it was
///     declared -- all 22 cells of those two rows.
///   * Otherwise the keywords resolve (thin 1px, medium 3px, thick 5px), an
///     undeclared width is `medium`, a length truncates to whole pixels
///     (`4.6px` -> `4px`) and a declared length above zero never truncates away
///     (`0.4px` -> `1px`), and a declaration the parser rejected is `medium`
///     (`50%` -> `3px`), not the recorded initial.
///
/// This is the computed view only. `el.style.borderTopWidth` keeps the page's
/// own text, keyword and all, which is what Chrome hands back there.
///
/// One known miss: `calc(2px + 3px)` computes to `5px` in Chrome and takes the
/// rejected-declaration path here, so it answers `3px`. There is no calc
/// evaluator to ask; `3px` is at least a shape Chrome prints.
/// `getComputedStyle(el).font`, rebuilt from the computed longhands.
///
/// A different join from the one `el.style.font` uses, in four ways, all
/// measured with probes/expr-b83-computed-font-join.js over 27 cases:
///
///   * the weight is a number and `400` is left out, where the specified side
///     echoes `bold`;
///   * the line height is in px and `normal` is left out, so `line-height: 1.4`
///     on 16px writes `16px / 22.4px serif`;
///   * the stretch goes BACK to a keyword. Computed `font-stretch` is a
///     percentage, and the computed `font` writes `condensed` for 75% and
///     `semi-condensed` for 87.5% -- so the mapping runs both ways for this one
///     part, which is why it is read rather than derived.
///   * and it answers the empty string when the shorthand cannot express the
///     element's state at all. Four separate causes were measured: a stretch
///     percentage with no keyword (60%, 133%), a `font-variant-caps` beyond the
///     shorthand's two (`all-small-caps`), and any of the twelve longhands the
///     grammar never names holding something other than its initial
///     (`font-kerning: none`, `font-size-adjust: 0.5`).
fn computedFontText(self: *const CSSStyleDeclaration, frame: *Frame, surface: Surface, depth: u8) []const u8 {
    if (depth >= MAX_PROPERTY_DEPTH) return "";
    // The twelve the `font` grammar cannot write. Any of them off its own
    // initial and there is no shorthand that says what this element is.
    const untouchable = [_][2][]const u8{
        .{ "font-variant-ligatures", "normal" },  .{ "font-variant-numeric", "normal" },
        .{ "font-variant-east-asian", "normal" }, .{ "font-variant-alternates", "normal" },
        .{ "font-variant-position", "normal" },   .{ "font-variant-emoji", "normal" },
        .{ "font-size-adjust", "none" },          .{ "font-language-override", "normal" },
        .{ "font-kerning", "auto" },              .{ "font-optical-sizing", "auto" },
        .{ "font-feature-settings", "normal" },   .{ "font-variation-settings", "normal" },
    };
    for (untouchable) |pair| {
        const value = self.propertyValueAt(pair[0], frame, surface, depth + 1);
        if (!std.ascii.eqlIgnoreCase(value, pair[1])) return "";
    }

    const style = self.propertyValueAt("font-style", frame, surface, depth + 1);
    const variant = self.propertyValueAt("font-variant-caps", frame, surface, depth + 1);
    const weight = self.propertyValueAt("font-weight", frame, surface, depth + 1);
    const stretch = self.propertyValueAt("font-stretch", frame, surface, depth + 1);
    const size = self.propertyValueAt("font-size", frame, surface, depth + 1);
    const line_height = self.propertyValueAt("line-height", frame, surface, depth + 1);
    const family = self.propertyValueAt("font-family", frame, surface, depth + 1);
    if (size.len == 0 or family.len == 0) return "";
    // `small-caps` is the only variant the shorthand carries; the other five
    // `font-variant-caps` keywords have no place in it.
    if (!std.ascii.eqlIgnoreCase(variant, "normal") and !std.ascii.eqlIgnoreCase(variant, "small-caps")) {
        return "";
    }
    const stretch_word = computedStretchKeyword(stretch) orelse return "";

    var out: std.ArrayList(u8) = .empty;
    const append = struct {
        fn one(list: *std.ArrayList(u8), arena: Allocator, text: []const u8) !void {
            if (list.items.len > 0) try list.append(arena, ' ');
            try list.appendSlice(arena, text);
        }
    }.one;
    const arena = frame.local_arena;
    if (!std.ascii.eqlIgnoreCase(style, "normal")) append(&out, arena, style) catch return "";
    if (!std.ascii.eqlIgnoreCase(variant, "normal")) append(&out, arena, variant) catch return "";
    if (!std.mem.eql(u8, weight, "400")) append(&out, arena, weight) catch return "";
    if (stretch_word.len > 0) append(&out, arena, stretch_word) catch return "";
    append(&out, arena, size) catch return "";
    if (!std.ascii.eqlIgnoreCase(line_height, "normal")) {
        out.appendSlice(arena, " /") catch return "";
        append(&out, arena, line_height) catch return "";
    }
    append(&out, arena, family) catch return "";
    return out.items;
}

/// The keyword a computed `font-stretch` percentage is written as inside the
/// computed `font`, empty for the 100% that is left out, and null for a
/// percentage with no keyword -- which is one of the four things that makes the
/// whole shorthand unwritable.
fn computedStretchKeyword(stretch: []const u8) ?[]const u8 {
    const WORDS = std.StaticStringMap([]const u8).initComptime(.{
        .{ "100%", "" },
        .{ "50%", "ultra-condensed" },
        .{ "62.5%", "extra-condensed" },
        .{ "75%", "condensed" },
        .{ "87.5%", "semi-condensed" },
        .{ "112.5%", "semi-expanded" },
        .{ "125%", "expanded" },
        .{ "150%", "extra-expanded" },
        .{ "200%", "ultra-expanded" },
    });
    return WORDS.get(stretch);
}

/// `font-weight` as the cascade computes it: a number, always.
///
/// Chrome answers `400` for an undeclared weight and `700` for `bold`; the
/// keyword is what `el.style.font-weight` keeps, and only the computed side
/// resolves. `bolder` and `lighter` are not values at all -- each resolves
/// against the INHERITED computed weight -- so they walk up, with `depth`
/// stopping a tree that somehow made a cycle.
///
/// The relative pair is a set of RANGES rather than the nine-step table CSS 2.1
/// wrote, which two of the eleven measured rows show outright: an inherited
/// `1000` gives `bolder` = 1000 rather than 900, and an inherited `350` -- not a
/// step at all -- gives 700. Measured with probes/expr-b83-relative-weight.js;
/// all eleven rows fit the ranges below and none fits the step table.
fn computedFontWeight(style_manager: *StyleManager, element: *Element, frame: *Frame, depth: u8) []const u8 {
    const weight = resolvedFontWeight(style_manager, element, depth);
    return std.fmt.allocPrint(frame.local_arena, "{d}", .{weight}) catch "400";
}

/// The initial `font-weight`, and what every path here falls back to.
const initial_font_weight: f64 = 400;

fn resolvedFontWeight(style_manager: *StyleManager, element: *Element, depth: u8) f64 {
    if (depth >= MAX_COMPUTED_DEPTH) return initial_font_weight;
    const wrapped = comptime String.wrap("font-weight");
    const declared = found: {
        switch (declaredValue(style_manager, element, "font-weight", wrapped)) {
            .value => |value| break :found std.mem.trim(u8, value, &std.ascii.whitespace),
            .unreportable, .none => {},
        }
        // The UA stylesheet, which is where `<b>` and `<th>` get theirs -- no
        // author declaration sets those and Chrome still computes 700. Walking
        // straight past it to the parent was a regression this caught.
        if (uaValue(element, "font-weight")) |value| {
            break :found std.mem.trim(u8, value, &std.ascii.whitespace);
        }
        // Nothing here under either: `font-weight` inherits, so the answer is
        // the parent's -- and the initial when there is no parent left.
        const parent = element.parentElement() orelse return initial_font_weight;
        return resolvedFontWeight(style_manager, parent, depth + 1);
    };
    if (std.ascii.eqlIgnoreCase(declared, "normal")) return initial_font_weight;
    if (std.ascii.eqlIgnoreCase(declared, "bold")) return 700;
    const bolder = std.ascii.eqlIgnoreCase(declared, "bolder");
    if (bolder or std.ascii.eqlIgnoreCase(declared, "lighter")) {
        const parent = element.parentElement();
        const inherited = if (parent) |current|
            resolvedFontWeight(style_manager, current, depth + 1)
        else
            initial_font_weight;
        return relativeFontWeight(inherited, bolder);
    }
    return std.fmt.parseFloat(f64, declared) catch initial_font_weight;
}

/// `bolder` and `lighter` against an inherited weight, as css-fonts-4 states it
/// and as all eleven measured rows answer.
fn relativeFontWeight(inherited: f64, bolder: bool) f64 {
    if (bolder) {
        if (inherited < 350) return 400;
        if (inherited < 550) return 700;
        if (inherited < 900) return 900;
        return inherited;
    }
    if (inherited < 100) return inherited;
    if (inherited < 550) return 100;
    if (inherited < 750) return 400;
    return 700;
}

/// How far the weight walk may climb. Well past any real nesting; the cap is
/// there so a tree that somehow made a cycle stops rather than recursing.
const MAX_COMPUTED_DEPTH: u8 = 64;

/// Every `font-stretch` keyword and the percentage it computes to, measured one
/// keyword at a time (probes/expr-b83-weight-stretch-computed.js). A percentage
/// computes to itself, and an undeclared stretch is `100%`.
const font_stretch_percentages = std.StaticStringMap([]const u8).initComptime(.{
    .{ "normal", "100%" },
    .{ "ultra-condensed", "50%" },
    .{ "extra-condensed", "62.5%" },
    .{ "condensed", "75%" },
    .{ "semi-condensed", "87.5%" },
    .{ "semi-expanded", "112.5%" },
    .{ "expanded", "125%" },
    .{ "extra-expanded", "150%" },
    .{ "ultra-expanded", "200%" },
});

fn computedFontStretch(style_manager: *StyleManager, element: *Element, wrapped: String) []const u8 {
    const declared = switch (cascadedValue(style_manager, element, "font-stretch", wrapped)) {
        .value => |value| std.mem.trim(u8, value, &std.ascii.whitespace),
        .unreportable, .none => return "100%",
    };
    var lower: [32]u8 = undefined;
    if (declared.len <= lower.len) {
        const key = std.ascii.lowerString(lower[0..declared.len], declared);
        if (font_stretch_percentages.get(key)) |percentage| return percentage;
    }
    return declared;
}

fn computedBorderWidth(
    self: *const CSSStyleDeclaration,
    element: *Element,
    name: []const u8,
    wrapped: String,
    style_name: []const u8,
    frame: *Frame,
    surface: Surface,
    depth: u8,
) []const u8 {
    const style = self.propertyValueAt(style_name, frame, surface, depth + 1);
    return usedBorderWidth(element, name, wrapped, style, frame);
}

/// The numbers behind computedBorderWidth, given the border style already read.
/// Split out so the box the layout builds can ask for the same used value
/// without a computed view to ask through -- boxEdges reads all four.
fn usedBorderWidth(
    element: *Element,
    name: []const u8,
    wrapped: String,
    style: []const u8,
    frame: *Frame,
) []const u8 {
    if (std.ascii.eqlIgnoreCase(style, "none") or std.ascii.eqlIgnoreCase(style, "hidden")) {
        return "0px";
    }

    const style_manager = &element.ownerFrame(frame)._style_manager;
    const declared = found: {
        switch (cascadedValue(style_manager, element, name, wrapped)) {
            .value => |value| break :found std.mem.trim(u8, value, &std.ascii.whitespace),
            // Written, and this engine cannot report it: `medium`, the same as
            // a declaration Chrome's own parser drops.
            .unreportable => return "3px",
            .none => {},
        }
        // The name's other spelling, the way the generic path falls back:
        // `border-block-start-width` and `border-top-width` are one property
        // under two names, and this engine stores only the one the page wrote.
        if (chrome_logical.counterpart(name)) |other| {
            switch (cascadedValue(style_manager, element, other, .wrap(other))) {
                .value => |value| break :found std.mem.trim(u8, value, &std.ascii.whitespace),
                .unreportable, .none => {},
            }
        }
        // Nothing the page wrote under either spelling, which is where the UA
        // stylesheet gets its turn -- and it is per-tag, so this cannot fall
        // through to one number. Six tags carry a border of their own and this
        // used to answer `medium` for all six, while the border-STYLE read
        // beside it did consult the same table and came back `inset`: an
        // `<input>` reported a 2px inset border as 3px, which is 2px of
        // offsetWidth per side wrong on every form control on a page. Measured
        // on Chrome 151 (tools/fingerprint/scratch/expr-empty-edges.js): input
        // and button and iframe and fieldset 2px, textarea and select and hr
        // 1px.
        if (uaValue(element, name)) |value| break :found value;

        // Nothing written and no UA rule: `medium`.
        return "3px";
    };

    if (std.ascii.eqlIgnoreCase(declared, "thin")) return "1px";
    if (std.ascii.eqlIgnoreCase(declared, "medium")) return "3px";
    if (std.ascii.eqlIgnoreCase(declared, "thick")) return "5px";

    // Anything the length pass already resolved arrives here as px; anything
    // else is a value Chrome's parser would have dropped.
    if (!std.mem.endsWith(u8, declared, "px")) return "3px";
    const number = std.fmt.parseFloat(f64, declared[0 .. declared.len - 2]) catch return "3px";
    if (number <= 0) return "0px";
    const whole: i64 = @intFromFloat(@floor(number));
    return std.fmt.allocPrint(frame.local_arena, "{d}px", .{@max(whole, 1)}) catch "3px";
}

/// The border family writes all three components off a computed view, where the
/// declared serialisation drops one holding its initial value: a bare `border`
/// computes to `0px none rgb(0, 0, 0)` while `el.style.border` on the same
/// element reads `0px rgb(0, 0, 0)`. Measured across five declaration states
/// with tools/fingerprint/scratch/expr-computed-border-join.js.
///
/// The per-corner spellings (`border-block-start` and its three siblings) are
/// absent because they already agree: their omit lists hold the literal
/// `initial`, which no computed longhand ever reads back as, so nothing is
/// dropped there to begin with. `outline` agrees for the same reason.
const COMPUTED_KEEPS_ALL = [_][]const u8{
    "border",        "border-top",
    "border-right",  "border-bottom",
    "border-left",   "border-block",
    "border-inline",
};

fn computedKeepsAll(name: []const u8) bool {
    for (COMPUTED_KEEPS_ALL) |kept| {
        if (std.mem.eql(u8, name, kept)) return true;
    }
    return false;
}

/// The same join off a computed view, where no longhand is stored: each one is
/// read back through propertyValue, which answers the cascade's value or the
/// recorded initial one.
///
/// Null means "this engine has no join to offer", and the recorded initial
/// value stands. That covers two holes as well as an arena failure. A longhand
/// reading back empty, or reading back the literal `initial`, is one this
/// engine cannot compute -- a computed style reports neither -- so a join over
/// it would be built on a value Chrome never prints. And a join that comes out
/// empty is the declared serialisation saying "this cannot be written as one
/// shorthand", which is an answer for `el.style` and not for a computed view:
/// Chrome answers every one of these names off getComputedStyle.
fn computedShorthandValue(
    self: *const CSSStyleDeclaration,
    name: []const u8,
    entry: shorthand.Shorthand,
    frame: *Frame,
    surface: Surface,
    depth: u8,
) ?[]const u8 {
    const held = frame.local_arena.alloc([]const u8, entry.longhands.len) catch return null;
    for (entry.longhands, held) |longhand, *value| {
        const computed = self.propertyValueAt(longhand, frame, surface, depth + 1);
        if (computed.len == 0 or std.mem.eql(u8, computed, "initial")) return null;
        value.* = if (self.leftAtCurrentColour(name, longhand, frame)) "currentcolor" else computed;
    }
    const joined = shorthand.joinKeeping(frame.local_arena, entry, held, computedKeepsAll(name)) catch return null;
    return if (joined.len == 0) null else joined;
}

/// Whether `text-decoration`'s colour is one the page never touched, and so one
/// Chrome writes nothing for.
///
/// The rule is not "the colour equals the element's colour":
/// tools/fingerprint/scratch/expr-textdecoration-color-omit.js separates the two
/// on an element whose colour is rgb(1, 2, 3), where declaring
/// `text-decoration-color: rgb(1, 2, 3)` prints it and declaring `currentcolor`
/// does not -- and both compute to the same rgb(1, 2, 3). What Chrome kept is
/// the unresolved value, so that is what the join is handed: `currentcolor` is
/// already in this slot's omit list, and the resolved colour is not.
///
/// Only `text-decoration`. The border family's colour slot lists `currentcolor`
/// too, and Chrome prints it there whatever the page did.
fn leftAtCurrentColour(
    self: *const CSSStyleDeclaration,
    name: []const u8,
    longhand: []const u8,
    frame: *Frame,
) bool {
    if (!std.mem.eql(u8, longhand, "text-decoration-color")) return false;
    if (!std.mem.eql(u8, name, "text-decoration") and
        !std.mem.eql(u8, name, "-webkit-text-decoration")) return false;

    const element = self._element orelse return false;
    const style_manager = &element.ownerFrame(frame)._style_manager;
    return switch (cascadedValue(style_manager, element, longhand, .wrap(longhand))) {
        .none => true,
        .unreportable => false,
        .value => |value| std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, &std.ascii.whitespace), "currentcolor"),
    };
}

/// The `display` a computed view reports: the cascade first (a stylesheet rule
/// sets display as often as an inline declaration does, and the generic inline
/// path cannot let a sheet's `!important` outrank one), the per-tag UA default
/// when nothing declares one, and then blockification -- a flex or grid parent
/// turns its child element's outer display block-level, which is how Chrome
/// exposes it and the reason innerText breaks a line there.
pub fn resolvedDisplay(element: *Element, frame: *Frame) []const u8 {
    const specified = frame._style_manager.computedDisplay(element) orelse getDefaultDisplay(element);

    // Nothing below can change a display that is block-level already, and
    // asking would cost two cascade reads per element on a path that runs per
    // element -- so the inline-level ones are the only ones that pay.
    const blockified = StyleManager.blockify(specified);
    if (std.mem.eql(u8, blockified, specified)) return specified;

    // Taking a box out of flow makes it block-level, and so does floating it.
    // Measured with tools/fingerprint/scratch/expr-abs-inline-display.js:
    // `<span style="position:absolute">` computes `display: block` in Chrome,
    // as do `position:fixed` and `float:left`, while `relative` and `sticky`
    // leave it inline. That is why an absolutely positioned <span> honours a
    // declared width -- it is no longer an inline box.
    if (flowKind(element, frame) != .in_flow) return blockified;

    const parent = element.parentElement() orelse return specified;
    if (!frame._style_manager.blockifiesChildren(parent)) {
        return specified;
    }
    return blockified;
}

/// The value the cascade gives `element` for one longhand -- a stylesheet rule,
/// the style attribute, whichever won -- already in the shape a computed style
/// reports. Null when nothing declares it, or when this engine cannot finish
/// resolving what was declared.
///
/// Element.dimensions used to read the style attribute alone, so a `width` a
/// stylesheet declared reached `getComputedStyle` and never reached the box:
/// one element answered 300px and 1904 to two readings of the same edge.
///
/// The other spelling is asked for too, the way propertyValueAt asks: an
/// element that declared `inline-size` has declared `width`, and only the
/// computed path knew that before this.
pub fn cascadedComputedValue(element: *Element, name: []const u8, frame: *Frame) ?[]const u8 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    switch (cascadedValue(style_manager, element, name, .wrap(name))) {
        .value => |value| return value,
        .unreportable => return null,
        .none => {},
    }
    const other = chrome_logical.counterpart(name) orelse return null;
    return switch (cascadedValue(style_manager, element, other, .wrap(other))) {
        .value => |value| value,
        .unreportable, .none => null,
    };
}

/// How this element's box sits in its parent's flow. Three answers rather than a
/// boolean, because a float and an out-of-flow box part company on exactly one
/// reading: a float is out of its parent's HEIGHT but still inside the parent's
/// scrollable overflow, while an `absolute` or `fixed` child is out of both.
/// Measured on Chrome 151 with
/// tools/fingerprint/scratch/expr-out-of-flow-stack.js -- a block holding one
/// floated child answers 0 of clientHeight and 18 of scrollHeight, and the same
/// block holding one absolute child answers 0 of both.
///
/// `relative` and `sticky` are `in_flow`: they keep their place in the stack, and
/// they leave an inline display inline. Measured too, and they are the half that
/// a "position is not static" test would get wrong.
///
/// Position before float, because `position: absolute` makes `float` compute to
/// `none` -- the two existing callers are indifferent to the order since they
/// only ask whether it is `in_flow` at all, but the third one is not.
pub const FlowKind = enum { in_flow, floated, positioned };

pub fn flowKind(element: *Element, frame: *Frame) FlowKind {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    if (cascadedKeyword(style_manager, element, "position")) |position| {
        if (std.ascii.eqlIgnoreCase(position, "absolute") or
            std.ascii.eqlIgnoreCase(position, "fixed")) return .positioned;
    }
    if (cascadedKeyword(style_manager, element, "float")) |float| {
        if (!std.ascii.eqlIgnoreCase(float, "none")) return .floated;
    }
    return .in_flow;
}

/// Whether this element's box takes its width from its containing block rather
/// than from its own content.
///
/// A block-level box in normal flow with `width: auto` is as wide as its
/// containing block, whatever it holds -- an empty <div> in a 1904px body is
/// 1904px wide, not 0. Measured against Chrome 151 with
/// tools/fingerprint/scratch/expr-layout-box-shapes.js, which also pins down
/// the boxes that do NOT fill, and those are the reason this is a question
/// rather than "is it display: block":
///
///   * a float, an `absolute` and a `fixed` box each shrink to fit;
///   * a flex ITEM shrinks too -- `<div style="display:flex"><div>x</div></div>`
///     puts the child at 8px in Chrome -- while a grid item stretches to 1904.
///     Both children compute `display: block` after blockification, so the
///     parent has to be asked, not the child;
///   * an `inline-block` shrinks, which its own display already says.
///
/// This engine agreed with Chrome on every one of those before this existed,
/// and the point of the list is that it still does.
pub fn fillsContainingBlock(element: *Element, frame: *Frame) bool {
    if (flowKind(element, frame) != .in_flow) return false;

    if (!fillsAtDisplay(resolvedDisplay(element, frame))) return false;

    if (element.parentElement()) |parent| {
        const parent_display = resolvedDisplay(parent, frame);

        // A flex item is sized by its content, not by the line it sits on.
        if (std.mem.eql(u8, parent_display, "flex") or
            std.mem.eql(u8, parent_display, "inline-flex")) return false;

        // A grid item stretches across its column -- but only while nothing has
        // said to place it instead. Measured with
        // tools/fingerprint/scratch/expr-grid-justify.js: `stretch` and
        // `normal` stretch, `start` / `end` / `center` / `left` do not, the
        // item's own `justify-self` wins whenever it is not `auto`, and
        // `justify-self: stretch` stretches an item inside a
        // `justify-items: start` container.
        if (std.mem.eql(u8, parent_display, "grid") or
            std.mem.eql(u8, parent_display, "inline-grid"))
        {
            return stretchesInGrid(element, parent, frame);
        }
    }

    return true;
}

fn stretchesInGrid(element: *Element, parent: *Element, frame: *Frame) bool {
    const style_manager = &element.ownerFrame(frame)._style_manager;

    const declared = if (cascadedKeyword(style_manager, element, "justify-self")) |self_value| blk: {
        if (std.ascii.eqlIgnoreCase(self_value, "auto")) break :blk null;
        break :blk self_value;
    } else null;

    const effective = declared orelse
        cascadedKeyword(style_manager, parent, "justify-items") orelse
        // Neither declared: `justify-items` computes to `normal`, which stretches.
        return true;

    return std.ascii.eqlIgnoreCase(effective, "stretch") or
        std.ascii.eqlIgnoreCase(effective, "normal");
}

/// What sits between an element's content box and its border box, per axis.
///
/// One element has three boxes and each reading takes a different one --
/// computed `width` the content box, `clientWidth` content + padding,
/// `offsetWidth` and `getBoundingClientRect` content + padding + border.
/// Measured with tools/fingerprint/scratch/expr-box-parts.js against Chrome
/// 151: `<div style="padding:10px">` on the 1904px line answers 1884, 1904 and
/// 1904, and `border:5px solid` answers 1894, 1894, 1904.
///
/// Both sides are read separately rather than doubled from one, which
/// `padding-left:7px; padding-right:13px` with a 2px and a 4px border is the
/// test for: 1878, 1898, 1904.
pub const BoxEdges = struct {
    padding_x: f64 = 0,
    padding_y: f64 = 0,
    border_x: f64 = 0,
    border_y: f64 = 0,
};

pub fn boxEdges(element: *Element, frame: *Frame) BoxEdges {
    var containing: ?f64 = null;
    return boxEdgesSharing(element, frame, &containing, 0);
}

/// boxEdges with the containing block's width shared with the caller, which is
/// what keeps a percentage padding from costing an exponential number of
/// measurements.
///
/// A percentage padding resolves against the containing block, so reading one
/// means measuring the parent -- and there are four of them, on top of the
/// measurement `dimensionsAt` already makes to fill a containing block. Asking
/// separately each time made the parent's box cost five of the grandparent's,
/// which is 5^n down a chain: eight nested `padding: 1%` elements took 626ms to
/// answer one clientWidth and twelve never came back at all. On www.sony.com it
/// took the engine out with a SIGBUS in the middle of an antibot sweep.
///
/// `containing` is that measurement, made at most once and then reused --
/// including by the fill branch in `dimensionsAt` -- which makes the whole
/// chain linear again.
pub fn boxEdgesSharing(element: *Element, frame: *Frame, containing: *?f64, depth: u8) BoxEdges {
    return .{
        .padding_x = paddingPx(element, "padding-left", frame, containing, depth) +
            paddingPx(element, "padding-right", frame, containing, depth),
        .padding_y = paddingPx(element, "padding-top", frame, containing, depth) +
            paddingPx(element, "padding-bottom", frame, containing, depth),
        // A border that draws nothing is 0 wide however the page wrote it, and
        // `thin` is 1px -- both are already the used value the computed border
        // width reports (computed-border-width-used-value), so nothing here has
        // to know about `none`. A border width is never a percentage, so none
        // of this applies to one.
        .border_x = borderPx(element, "border-left", frame) + borderPx(element, "border-right", frame),
        .border_y = borderPx(element, "border-top", frame) + borderPx(element, "border-bottom", frame),
    };
}

/// Padding plus border on one block edge, which is what decides whether a
/// child's margin passes through that edge or is counted inside it. Chrome
/// answers 12 for `<div><div style="margin-top:20px;height:12px"></div></div>`
/// and 34 for the same parent with `border:1px` -- measured with
/// probes/expr-b86-margin-collapse.js -- so a single px on the edge is the
/// whole difference between the margin escaping and not.
///
/// Takes the caller's shared containing block for the same reason paddingPx
/// does: a percentage padding otherwise measures the parent again.
pub fn blockEdgePx(
    element: *Element,
    comptime side: []const u8,
    frame: *Frame,
    containing: *?f64,
    depth: u8,
) f64 {
    return paddingPx(element, "padding-" ++ side, frame, containing, depth) +
        borderPx(element, "border-" ++ side, frame);
}

/// Whether this element establishes a block formatting context, which is what
/// stops its children's margins from collapsing out through it.
///
/// `overflow:hidden` is the case the probe pins down: the same markup that is
/// 12 tall on a bare parent is 32 on this one, because the child's 20px margin
/// is contained rather than escaping. The rest of the list is the standard one
/// -- a float, an out-of-flow box, and the displays that are their own
/// formatting context -- and it is deliberately not "display is not block":
/// `flow-root` exists precisely to be a block that does this.
pub fn establishesBlockFormattingContext(element: *Element, frame: *Frame) bool {
    if (flowKind(element, frame) != .in_flow) return true;

    const style_manager = &element.ownerFrame(frame)._style_manager;
    inline for (.{ "overflow", "overflow-x", "overflow-y" }) |name| {
        if (cascadedKeyword(style_manager, element, name)) |value| {
            const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len != 0 and !std.ascii.eqlIgnoreCase(trimmed, "visible")) return true;
        }
    }

    const display = resolvedDisplay(element, frame);
    inline for (.{
        "flow-root",    "inline-block", "inline-flex",   "inline-grid",
        "inline-table", "table-cell",   "table-caption", "flex",
        "grid",
    }) |name| {
        if (std.mem.eql(u8, display, name)) return true;
    }
    return false;
}

/// One padding in px. A percentage is resolved here, against the shared
/// containing-block width, rather than through the computed-value machinery --
/// that path measures the parent from scratch for every property that asks.
fn paddingPx(element: *Element, name: []const u8, frame: *Frame, containing: *?f64, depth: u8) f64 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    if (declaredDeclaration(style_manager, element, name, .wrap(name))) |declaration| {
        const trimmed = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
        if (std.mem.endsWith(u8, trimmed, "%")) {
            const parsed = units.parse(trimmed) catch return 0;
            const percent = declaration.specified orelse parsed.value;
            const width = containingWidth(element, frame, containing, depth) orelse return 0;
            return @max(0, Element.layoutUnit(width * percent / 100.0));
        }
    }
    return computedPx(element, name, frame);
}

/// A margin declared as a percentage, in px against the shared containing-block
/// width. Null when the declaration is not a percentage, which leaves the
/// caller to resolve it the ordinary way.
///
/// A percentage margin is a share of the containing block's WIDTH on all four
/// sides, the way a percentage padding is: measured with
/// tools/fingerprint/scratch/expr-margin-pct.js, `margin-top:10%` of a 400px
/// line is 40px and not a tenth of any height.
///
/// Resolved here rather than through the computed-value machinery for the same
/// reason paddingPx is: that path measures the containing block from scratch for
/// every property that asks, and this is called from inside the measurement that
/// already holds the number. Two margins asking separately would put back on the
/// chain exactly the multiplier boxEdgesSharing exists to keep off it.
///
/// Signed, unlike a padding: `margin-left:-10%` of a 400px line is -40px, and
/// the box beside it gets 440 rather than 360.
///
/// Both spellings are asked for, the way cascadedComputedValue asks: an element
/// that declared `margin-inline-start` has declared `margin-left`, and the box
/// has to lose the same 40px either way.
pub fn marginPercentagePx(element: *Element, name: []const u8, frame: *Frame, containing: *?f64, depth: u8) ?f64 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    const declaration = declaredEitherSpelling(style_manager, element, name) orelse return null;
    const trimmed = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
    if (!std.mem.endsWith(u8, trimmed, "%")) return null;
    const parsed = units.parse(trimmed) catch return 0;
    const percent = declaration.specified orelse parsed.value;
    const width = containingWidth(element, frame, containing, depth) orelse return 0;
    return Element.layoutUnit(width * percent / 100.0);
}

/// declaredDeclaration for a property under either of its two spellings,
/// physical or logical.
fn declaredEitherSpelling(style_manager: *StyleManager, element: *Element, name: []const u8) ?StyleManager.Declaration {
    if (declaredDeclaration(style_manager, element, name, .wrap(name))) |declaration| return declaration;
    const other = chrome_logical.counterpart(name) orelse return null;
    return declaredDeclaration(style_manager, element, other, .wrap(other));
}

/// The containing block's content width, measured once and remembered.
pub fn containingWidth(element: *Element, frame: *Frame, containing: *?f64, depth: u8) ?f64 {
    if (containing.*) |width| return width;
    if (depth >= Element.MAX_CONTAINING_BLOCK_DEPTH) return null;
    // The same ancestor the fill branch measures -- Element.containingBlock,
    // which walks past an inline one -- so the two share a number rather than
    // each measuring a different element.
    const parent = element.containingBlock(frame) orelse return null;
    const width = parent.dimensionsAt(frame, true, depth + 1, true).width;
    containing.* = width;
    return width;
}

/// Whether a declared width and height name the border box rather than the
/// content box. Measured: `width:400px; box-sizing:border-box; padding:10px;
/// border:5px solid` is 370px of content, 390 of clientWidth and 400 of
/// offsetWidth, and its computed `width` answers the 400 -- the border box,
/// because that is the box `box-sizing` named.
/// Whether this element is a non-replaced inline box -- one with no CSS box of
/// its own, so `width` and `height` do not apply to it and clientWidth,
/// clientHeight, scrollWidth and scrollHeight are all 0. Element.Dimensions
/// carries what that leaves.
///
/// A replaced element is `display: inline` too and DOES have a box: an <img
/// width=40 height=30> answers 40 and 30 for every one of those readings,
/// measured with tools/fingerprint/scratch/expr-inline-box.js.
/// Whether the UA sheet alone makes this element inline-level, answered off the
/// per-tag table with no cascade read at all.
///
/// It is the cheap first question the inline flow walk asks of every element
/// child: a child the UA sheet calls block-level hands the box straight back to
/// the child stack, which is what this engine did for every element child before
/// there was an inline flow, and only the ones that could be inline pay for
/// `resolvedDisplay` to confirm it. The walk sits under `elementFromPoint`,
/// which the suite budgets at forty calls over eight hundred elements, and a
/// cascade read per child there costs seconds.
///
/// A `<div style="display:inline">` is therefore not treated as inline content.
/// That is the pre-existing answer -- the walk used to stop at any element child
/// whatever its display -- and not a new one.
pub fn defaultDisplayIsInline(element: *Element) bool {
    return std.mem.eql(u8, getDefaultDisplay(element), "inline");
}

pub fn isInlineBox(element: *Element, frame: *Frame) bool {
    if (!std.mem.eql(u8, resolvedDisplay(element, frame), "inline")) return false;
    return !isReplacedTag(element);
}

/// Whether this element has a box of its own however it is displayed — the
/// replaced elements, which are `display: inline` and still 40 by 30. Split out
/// of isInlineBox so a caller that has already paid for `resolvedDisplay` can
/// ask the second half without paying for the first again: the cascade read is
/// a selector match against every rule that could reach the element, and the
/// inline flow walk does it per child.
pub fn isReplacedTag(element: *Element) bool {
    return switch (element.getTag()) {
        .img, .iframe, .video, .audio, .canvas, .embed, .object, .svg, .input, .select, .textarea, .button, .meter, .progress, .frame => true,
        else => false,
    };
}

/// What Chrome's UA stylesheet gives this element for a property the page did
/// not declare, or null when the sheet says nothing about it either.
///
/// The layout's own readers -- paddingPx, borderPx, usesBorderBox, the used
/// border width -- asked the cascade and stopped, and the cascade is the AUTHOR's
/// only. So the box the layout built never saw the UA sheet, while the computed
/// style beside it did (through getDefaultPropertyValue, which reaches this same
/// table). Measured on Chrome 151 with
/// tools/fingerprint/scratch/expr-empty-edges.js, what that cost:
///
///   * a <ul> kept its 40px padding-inline-start inside the content box, so its
///     computed width was the whole 400px line and not 360;
///   * an <iframe> and an <hr> drew no default border, so an iframe's offsetWidth
///     was 300 against Chrome's 304 and an <hr> was 0 tall where Chrome is 2;
///   * a <button>, whose entire 16x6 box IS padding and border around a 0x0
///     content box, came out 0 by 0;
///   * a <select> declared `width:100px` reported a clientWidth of 100 against
///     Chrome's 98, because `box-sizing: border-box` is a UA rule for it and the
///     1px border it takes off was invisible here too.
fn uaValue(element: *Element, name: []const u8) ?[]const u8 {
    // Chrome's UA sheet for <input> is per TYPE, and the generated table is per
    // tag: its `input` row is the text field's, so before this a checkbox
    // carried the text field's padding inside its 2px inset border and measured
    // 149x17 against Chrome's 13x13. The type's own overrides come first and
    // fall through to that row for every name they do not mention.
    if (element.inputTypeForBox()) |input_type| {
        if (chrome_input_type_values.get(input_type, name)) |value| return value;
    }
    const rows = chrome_per_tag_values.per_tag.get(element.getTagNameLower()) orelse
        chrome_per_tag_values.unknown_tag;
    return rows.get(name);
}

/// Whether `white-space` keeps this element's spaces rather than collapsing
/// them, which is what decides whether whitespace with nothing beside it makes a
/// line box at all.
///
/// The longhand to ask is `white-space-collapse`, NOT `white-space`.
/// `white-space` is a shorthand -- Chrome expands it to `white-space-collapse`
/// and `text-wrap-mode`, which chrome_shorthands.zig carries as a measured
/// preset table -- so the cascade never holds a longhand by that name and asking
/// for one always finds nothing. The first version of the collapse rule asked
/// for it anyway, so the escape hatch never fired and a `pre` div holding one
/// space was 0 tall where Chrome makes it 18.
///
/// `preserve` (which `pre` and `pre-wrap` expand to) and `break-spaces` keep the
/// space; `preserve-breaks` (from `pre-line`) and `collapse` (from `normal` and
/// `nowrap`) drop it. All measured on Chrome 151 with
/// tools/fingerprint/scratch/expr-whitespace-linebox.js.
///
/// Walked one element at a time, asking the cascade and THEN the UA sheet at
/// each level, because the property inherits and the two origins interleave: a
/// <pre> inside `white-space: normal` is `preserve` in Chrome, measured -- the UA
/// rule on the element itself outranks an author value inherited from a parent,
/// since inheritance only applies where nothing in the cascade set the property.
/// Asking the whole chain for a declaration first and only then for UA values
/// gets that case backwards.
/// The cascaded value of an INHERITED property, walking one element at a time
/// and asking the cascade and then the UA sheet at each level.
///
/// The levels have to interleave, because the two origins do: a <pre> inside
/// `white-space: normal` is `preserve` in Chrome, measured -- the UA rule on the
/// element itself outranks an author value inherited from a parent, since
/// inheritance only applies where nothing in the cascade set the property on the
/// element. Asking the whole ancestor chain for a declaration first and only then
/// for UA values gets that case backwards.
fn cascadedOrUaInherited(element: *Element, frame: *Frame, name: []const u8, wrapped: String) ?[]const u8 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    var current: ?*Element = element;
    while (current) |el| : (current = el.parentElement()) {
        switch (declaredValue(style_manager, el, name, wrapped)) {
            .value => |value| return std.mem.trim(u8, value, &std.ascii.whitespace),
            .unreportable => return null,
            .none => {},
        }
        if (uaValue(el, name)) |value| return std.mem.trim(u8, value, &std.ascii.whitespace);
    }
    return null;
}

/// `white-space-collapse`, which is the longhand `white-space` expands to along
/// with `text-wrap-mode`. NOT `white-space`: that is a shorthand -- Chrome's
/// expansion is the measured preset table in chrome_shorthands.zig -- so the
/// cascade never holds a longhand by that name and asking for one always finds
/// nothing. The first version of the collapse rule asked for it anyway, so the
/// escape hatch never fired and a `pre` div holding one space was 0 tall where
/// Chrome makes it 18.
fn whiteSpaceCollapse(element: *Element, frame: *Frame) []const u8 {
    // Not `comptime .wrap`: a comptime String has to fit the small-string
    // optimisation's twelve bytes and `white-space-collapse` is twenty.
    const name = "white-space-collapse";
    return cascadedOrUaInherited(element, frame, name, .wrap(name)) orelse "collapse";
}

/// Whether a run of spaces survives, so whitespace with nothing beside it is
/// still a line box. `preserve` (from `pre` and `pre-wrap`) and `break-spaces`
/// keep it; `preserve-breaks` (from `pre-line`) and `collapse` (from `normal` and
/// `nowrap`) drop it. All measured on Chrome 151 with
/// tools/fingerprint/scratch/expr-whitespace-linebox.js.
pub fn preservesWhitespace(element: *Element, frame: *Frame) bool {
    const collapse = whiteSpaceCollapse(element, frame);
    return std.ascii.eqlIgnoreCase(collapse, "preserve") or
        std.ascii.eqlIgnoreCase(collapse, "break-spaces");
}

/// Whether a newline in the source is a line break rather than a space. Every
/// value but `collapse` keeps it, which is `pre`, `pre-wrap`, `pre-line` and
/// `break-spaces` -- measured: `a\nb\nc` is three lines under all four and one
/// line under `normal`.
pub fn preservesNewlines(element: *Element, frame: *Frame) bool {
    return !std.ascii.eqlIgnoreCase(whiteSpaceCollapse(element, frame), "collapse");
}

/// Whether a line too long for its box breaks. `text-wrap-mode: nowrap` is the
/// one that says no, and `white-space: pre` expands to it -- measured, forty
/// words in a 100px box are 20 lines under `normal` and `pre-wrap` and one line
/// under `nowrap` and `pre`.
pub fn wrapsText(element: *Element, frame: *Frame) bool {
    // Not `comptime .wrap`: fourteen bytes, and a comptime String has to fit the
    // small-string optimisation's twelve.
    const name = "text-wrap-mode";
    const mode = cascadedOrUaInherited(element, frame, name, .wrap(name)) orelse return true;
    return !std.ascii.eqlIgnoreCase(mode, "nowrap");
}

pub fn usesBorderBox(element: *Element, frame: *Frame) bool {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    const declared = cascadedKeyword(style_manager, element, "box-sizing") orelse
        uaValue(element, "box-sizing") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, declared, &std.ascii.whitespace), "border-box");
}

/// One border's used width in px. `side` is the stem, so `border-left` reads
/// `border-left-width` against `border-left-style`: a border that draws nothing
/// is 0 however it was written, an undeclared width beside a style is `medium`
/// (3px), and the keywords resolve to 1, 3 and 5.
fn borderPx(element: *Element, comptime side: []const u8, frame: *Frame) f64 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    // The UA sheet before `none`: an <iframe> draws a 2px inset border and an
    // <hr> a 1px one with nothing declared, and this asked the author cascade
    // only -- so the layout saw no border on either. See uaValue.
    const style = cascadedKeyword(style_manager, element, side ++ "-style") orelse
        uaValue(element, side ++ "-style") orelse "none";
    const width_name = side ++ "-width";
    const used = usedBorderWidth(element, width_name, .wrap(width_name), style, frame);
    const parsed = units.parse(used) catch return 0;
    return @max(0, parsed.value);
}

/// The px the cascade gives one property, as a NUMBER rather than the text a
/// computed style writes. The layout asks through here so its numbers never
/// make a round trip through six significant figures -- see Element.layoutUnit
/// for what that costs.
///
/// One token only, which every length this is asked for is. Null when nothing
/// declares the property, or when the value is not a length this engine
/// resolves.
pub fn cascadedComputedLength(element: *Element, name: []const u8, frame: *Frame) ?f64 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    const declared = cascadedLengthToken(style_manager, element, name) orelse blk: {
        const other = chrome_logical.counterpart(name) orelse return null;
        break :blk cascadedLengthToken(style_manager, element, other) orelse return null;
    };
    return declared;
}

fn cascadedLengthToken(style_manager: *StyleManager, element: *Element, name: []const u8) ?f64 {
    const declaration = cascadedRawDeclaration(style_manager, element, name) orelse return null;
    const trimmed = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
    const parsed = units.parse(trimmed) catch return null;
    // The author's number when there is one, and the print only when there is
    // not: this is the path a used `width` reaches the layout by, and six
    // significant figures of it lands a grid step off.
    const number = declaration.specified orelse parsed.value;
    return switch (lengthFactor(style_manager, element, name, parsed.unit)) {
        .verbatim => number,
        .pixels => |factor| number * factor,
        .unresolvable => null,
    };
}

/// The cascade's answer before anything a computed style does to it: the
/// specified text, with `var()` substituted and inheritance followed.
fn cascadedValueRaw(style_manager: *StyleManager, element: *Element, name: []const u8) Declared {
    const declaration = cascadedRawDeclaration(style_manager, element, name) orelse return .none;
    return .{ .value = declaration.value };
}

/// cascadedValueRaw with the author's number still on it.
fn cascadedRawDeclaration(style_manager: *StyleManager, element: *Element, name: []const u8) ?StyleManager.Declaration {
    if (declaredDeclaration(style_manager, element, name, .wrap(name))) |declaration| {
        return declaration;
    }
    if (!chrome_inherited.inherits(name)) return null;
    var ancestor = element.parentElement();
    while (ancestor) |current| : (ancestor = current.parentElement()) {
        if (declaredDeclaration(style_manager, current, name, .wrap(name))) |declaration| {
            return declaration;
        }
    }
    return null;
}

/// The properties whose computed value is the USED one, so it lands on the
/// layout grid whatever unit the page wrote it in.
fn usedLengthProperty(property_name: []const u8) bool {
    return std.mem.eql(u8, property_name, "width") or
        std.mem.eql(u8, property_name, "height") or
        std.mem.eql(u8, property_name, "inline-size") or
        std.mem.eql(u8, property_name, "block-size");
}

/// Whether the page wrote this property as a px length or a bare number, which
/// is the only case a computed answer still needs putting on the grid: any
/// other unit went through computedLengthText, which snapped it as it
/// converted, and snapping again would work off the six figures that got
/// written rather than the value behind them.
fn declaredInPixels(style_manager: *StyleManager, element: *Element, name: []const u8, wrapped: String) bool {
    const declared = declaredText(style_manager, element, name, wrapped) orelse return false;
    const parsed = units.parse(std.mem.trim(u8, declared, &std.ascii.whitespace)) catch return false;
    return parsed.unit == .px or parsed.unit == .none;
}

/// A `width` or `height` the cascade answered, put on the layout grid and
/// written the way every other computed length is. Null for anything that is
/// not a plain px length -- `auto`, `min-content`, a keyword -- which goes
/// through untouched.
fn usedLengthText(value: []const u8, specified: ?f64, frame: *Frame) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    const parsed = units.parse(trimmed) catch return null;
    if (parsed.unit != .px) return null;

    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    // The author's number when there is one. Snapping `value` would snap the
    // six figures it was printed to, which is the grid step this whole path
    // exists to get right.
    units.writeNumber(&buf.writer, Element.layoutUnit(specified orelse parsed.value)) catch return null;
    buf.writer.writeAll("px") catch return null;
    return buf.written();
}

/// One computed length in px, or 0 when the page declared none and when this
/// engine cannot finish resolving what it did declare. Percentages are already
/// px by here for the properties that resolve them.
fn computedPx(element: *Element, name: []const u8, frame: *Frame) f64 {
    // The UA sheet counts here too, which is what a <ul>'s 40px
    // padding-inline-start and an <input>'s `1px 2px` ride in on. See uaValue.
    const declared = cascadedComputedValue(element, name, frame) orelse
        uaValue(element, name) orelse return 0;
    const parsed = units.parse(std.mem.trim(u8, declared, &std.ascii.whitespace)) catch return 0;
    return switch (parsed.unit) {
        // The author's number rather than the six figures it printed to, when
        // the page wrote one this path can still recognise: a padding of
        // `465.5466592px` takes 465.53125 off the box in Chrome, and the print
        // would take 465.546875.
        .px, .none => @max(0, specifiedPx(element, name, frame) orelse parsed.value),
        else => 0,
    };
}

/// The author's number for a length declared directly in px, or null when the
/// declaration was in some other unit and the computed text is the resolved
/// answer rather than a print of the specified one.
pub fn specifiedPx(element: *Element, name: []const u8, frame: *Frame) ?f64 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    const declaration = declaredEitherSpelling(style_manager, element, name) orelse return null;
    const specified = declaration.specified orelse return null;
    const parsed = units.parse(std.mem.trim(u8, declaration.value, &std.ascii.whitespace)) catch return null;
    if (parsed.unit != .px and parsed.unit != .none) return null;
    // On the grid before it is used, not after: a box's parts are added and
    // subtracted as grid units, so each one snaps on the way in. Measured --
    // `padding-left:465.5466592px` inside a 1000px line leaves 534.46875 of
    // content and a border box of exactly 1000, where subtracting the unsnapped
    // 465.546646 leaves 534.453125 and a border box that misses 1000 entirely.
    return Element.layoutUnit(specified);
}

/// How wide a flex item comes out, or null when nothing about the flex layout
/// decides its width and the box keeps the one it already had.
///
/// `width_declared` says the caller already took a width off the cascade. It
/// only settles the cross axis: in a ROW, `flex-grow` outranks a declared width
/// -- measured, `flex: 1; width: 60px` is 1904 and not 60, because `flex: 1`
/// sets the basis to `0%` and the width never enters the sizing.
///
/// Measured against Chrome 151 on the 1904px line with
/// tools/fingerprint/scratch/expr-flex-shorthand.js and expr-flex-more.js:
///
///   * a row divides its line the way CSS Flexbox does. Each item starts at its
///     flex base size -- `flex-basis` when that is a length or a percentage,
///     else whatever width the box would have had -- and every item whose
///     `flex-grow` is above zero takes a share of what is left over, in
///     proportion to its factor. Two `flex: 1` items are 952 each; `1` beside
///     `3` is 476 and 1428; `flex: 1` beside a 300px sibling is 1604; bases of
///     100 and 500 with equal factors come out 752 and 1152.
///   * a margin comes off the line before anything is shared: `flex: 1;
///     margin: 0 20px` in a 400px row is 360.
///   * a COLUMN container lays its items along the other axis, so a width there
///     is a cross-axis size: the item stretches unless `align-items` or its own
///     `align-self` places it instead, and unless it declares a width. That is
///     the shape `stretchesInGrid` has for `justify-items`.
///   * an out-of-flow or `display: none` child is not an item and takes no
///     share -- `flex: 1` beside an absolutely positioned sibling is the whole
///     400px line.
///   * whatever the line gives it, an item is never narrower than its own
///     longest word (`flooredAtMinContent`). That floor is why `flex-basis: 0`
///     leaves an item at its content width rather than at 0.
///
/// What is deliberately not modelled, with the reading that says so:
/// `flex-shrink` (two 300px items in a 200px row are 100 each in Chrome and 300
/// here); a declared `min-width` / `max-width`; and the anonymous item Chrome
/// makes of a text node between two elements, which is why one there divides a
/// 400px line into 184s where this divides it into 200s.
pub fn flexItemWidth(element: *Element, frame: *Frame, depth: u8, width_declared: bool, edges: BoxEdges) ?f64 {
    // The same backstop the containing-block walk has, for the same reason: a
    // tree that somehow made a cycle stops rather than recursing forever.
    if (depth >= Element.MAX_CONTAINING_BLOCK_DEPTH) return null;
    const parent = element.parentElement() orelse return null;
    const parent_display = resolvedDisplay(parent, frame);
    if (!std.mem.eql(u8, parent_display, "flex") and
        !std.mem.eql(u8, parent_display, "inline-flex")) return null;
    if (!isFlexItem(element, frame)) return null;

    const style_manager = &element.ownerFrame(frame)._style_manager;
    const container = parent.dimensionsAt(frame, true, depth + 1, true).width;
    const outside = edges.padding_x + edges.border_x;

    if (isColumnFlex(style_manager, parent)) {
        if (width_declared) return null;
        // A stretch fills the line with the BORDER box, the way an auto-width
        // block fills its containing one.
        return if (stretchesAcrossFlexLine(element, parent, frame)) @max(0, container - outside) else null;
    }

    // An item that does not grow takes no share, so it needs nothing from its
    // siblings: a declared basis is its width, and otherwise the box keeps the
    // one it has. Asked first because it is the common case, and because the
    // walk below measures every sibling -- a cost no ordinary flex item should
    // pay for a share it is not taking.
    const own_basis = flexBase(element, container, frame, edges);
    const own_grow = flexFactor(element, "flex-grow", frame);
    if (own_grow <= 0) {
        return flooredAtMinContent(element, frame, own_basis orelse return null);
    }

    var total_grow: f64 = 0;
    var taken: f64 = 0;
    var own_base: f64 = 0;

    // Every item on this line has the same containing block -- the flex
    // container, which `container` is already the content width of -- so the
    // percentage margins below resolve against it without measuring anything.
    var line_width: ?f64 = container;

    var child = parent.firstElementChild();
    while (child) |sibling| : (child = sibling.nextElementSibling()) {
        if (!isFlexItem(sibling, frame)) continue;
        const sibling_edges = if (sibling == element) edges else boxEdges(sibling, frame);
        const base = if (sibling == element)
            own_basis orelse sibling.dimensionsAt(frame, true, depth + 1, false).width
        else
            flexBaseSize(sibling, container, frame, depth, sibling_edges);
        // What the line gives out is BORDER boxes: an item's padding, border
        // and margin all come off the free space before anything is shared.
        // Measured -- `flex: 1; padding: 0 25px` in a 400px row is 350px of
        // content and 400 of offsetWidth, and beside an unpadded `flex: 1` the
        // two come out 175 of content each.
        taken += base + sibling_edges.padding_x + sibling_edges.border_x +
            Element.horizontalMargin(sibling, frame, &line_width, depth);
        total_grow += flexFactor(sibling, "flex-grow", frame);
        if (sibling == element) own_base = base;
    }

    const free = container - taken;
    if (total_grow > 0 and free > 0) {
        return flooredAtMinContent(element, frame, own_base + free * own_grow / total_grow);
    }
    return flooredAtMinContent(element, frame, own_basis orelse return null);
}

/// A flex item's automatic minimum size: it is never laid out narrower than its
/// own longest word, whatever the line has to give it. Element.minContentWidth
/// carries the measurements.
///
/// Skipped when the page declares a `min-width` of its own, because that is the
/// property this floor is the `auto` value OF -- `min-width: 0` turns it off in
/// Chrome, and this engine models neither the zero nor any other value, so the
/// honest answer to a declared one is to leave the size alone.
fn flooredAtMinContent(element: *Element, frame: *Frame, width: f64) f64 {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    if (cascadedKeyword(style_manager, element, "min-width") != null) return width;
    const floor = element.minContentWidth(frame) orelse return width;
    return @max(width, floor);
}

/// The flex base size one item starts from: its `flex-basis` when that is a
/// length or a percentage of the container, and otherwise the width the box
/// would have had on its own.
///
/// That second measurement is taken with the distribution turned off, which is
/// what keeps this from recursing: an item asking for a sibling's base would
/// otherwise send the sibling back around the same walk, asking for this one's.
fn flexBaseSize(element: *Element, container: f64, frame: *Frame, depth: u8, edges: BoxEdges) f64 {
    if (flexBase(element, container, frame, edges)) |px| return px;
    return element.dimensionsAt(frame, true, depth + 1, false).width;
}

/// The declared flex base size as a CONTENT width. `flex-basis` is measured in
/// the box-sizing's own terms, so a `border-box` item's basis has its padding
/// and border taken back off: measured, `flex-basis: 200px; padding: 0 25px` is
/// 200px of content and 250 of offsetWidth, and the same with `box-sizing:
/// border-box` is 150 of content and 200 of offsetWidth.
fn flexBase(element: *Element, container: f64, frame: *Frame, edges: BoxEdges) ?f64 {
    const basis = flexBasisLength(element, container, frame) orelse return null;
    if (!usesBorderBox(element, frame)) return basis;
    return @max(0, basis - edges.padding_x - edges.border_x);
}

/// The `flex-basis` of one item in px, or null when it is `auto`, `content`, or
/// nothing at all -- the three that send the base back to the box.
fn flexBasisLength(element: *Element, container: f64, frame: *Frame) ?f64 {
    const declared = cascadedComputedValue(element, "flex-basis", frame) orelse return null;
    const parsed = units.parse(std.mem.trim(u8, declared, &std.ascii.whitespace)) catch return null;
    return switch (parsed.unit) {
        .px => parsed.value,
        .percentage => container * parsed.value / 100.0,
        else => null,
    };
}

/// A flex factor, which is a bare number. Zero when the page declared none, or
/// declared one this engine cannot read: `flex-grow`'s initial value is 0 and
/// `flex-shrink`'s is 1, and only `flex-grow` is asked for here.
fn flexFactor(element: *Element, name: []const u8, frame: *Frame) f64 {
    const declared = cascadedComputedValue(element, name, frame) orelse return 0;
    const parsed = units.parse(std.mem.trim(u8, declared, &std.ascii.whitespace)) catch return 0;
    if (parsed.unit != .none) return 0;
    return @max(0, parsed.value);
}

/// Whether a child of a flex container is one of its items. An out-of-flow box
/// is not laid out on the line, and a `display: none` one is not laid out at
/// all; both were measured taking no share of a 400px row.
fn isFlexItem(element: *Element, frame: *Frame) bool {
    const style_manager = &element.ownerFrame(frame)._style_manager;
    if (cascadedKeyword(style_manager, element, "position")) |position| {
        if (std.ascii.eqlIgnoreCase(position, "absolute") or
            std.ascii.eqlIgnoreCase(position, "fixed")) return false;
    }
    return !std.mem.eql(u8, resolvedDisplay(element, frame), "none");
}

/// Whether the container stacks its items down the page, which puts a width on
/// the cross axis.
fn isColumnFlex(style_manager: *StyleManager, container: *Element) bool {
    const declared = cascadedKeyword(style_manager, container, "flex-direction") orelse return false;
    return std.ascii.eqlIgnoreCase(declared, "column") or
        std.ascii.eqlIgnoreCase(declared, "column-reverse");
}

/// Whether an item stretches across the flex line rather than being placed on
/// it. Measured with expr-flex-shorthand.js: a column container's item is
/// 1904px by default, 8px under `align-items: flex-start`, and 1904 again when
/// it answers with `align-self: stretch` -- the same `stretch`/`normal` pair,
/// and the same self-beats-container rule, that `justify-items` has on a grid.
fn stretchesAcrossFlexLine(element: *Element, parent: *Element, frame: *Frame) bool {
    const style_manager = &element.ownerFrame(frame)._style_manager;

    const declared = if (cascadedKeyword(style_manager, element, "align-self")) |self_value| blk: {
        if (std.ascii.eqlIgnoreCase(self_value, "auto")) break :blk null;
        break :blk self_value;
    } else null;

    const effective = declared orelse
        cascadedKeyword(style_manager, parent, "align-items") orelse
        return true;

    return std.ascii.eqlIgnoreCase(effective, "stretch") or
        std.ascii.eqlIgnoreCase(effective, "normal");
}

/// Whether this element is block-level, which is what breaks an inline box it
/// sits inside into fragments around it.
pub fn breaksInline(element: *Element, frame: *Frame) bool {
    return fillsAtDisplay(resolvedDisplay(element, frame));
}

fn fillsAtDisplay(display: []const u8) bool {
    const FILLS = [_][]const u8{ "block", "flow-root", "list-item", "grid", "flex" };
    for (FILLS) |name| {
        if (std.mem.eql(u8, display, name)) return true;
    }
    return false;
}

/// The cascaded keyword for a property whose value is one, skipping everything
/// a computed style does to a length or a colour. `position` and `float` are
/// both keywords and neither inherits, so this is the declaration itself.
fn cascadedKeyword(style_manager: *StyleManager, element: *Element, name: []const u8) ?[]const u8 {
    // Not `comptime .wrap`: a comptime String has to fit the small-string
    // optimisation's twelve bytes and `justify-items` is thirteen.
    return switch (cascadedValue(style_manager, element, name, .wrap(name))) {
        .value => |value| value,
        .unreportable, .none => null,
    };
}

fn resolvedDimension(element: *Element, dimension: enum { width, height }, frame: *Frame) []const u8 {
    var visibility_cache: Element.VisibilityCache = .{};
    if (!element.checkVisibilityCached(&visibility_cache, frame)) {
        return "auto";
    }
    // clientWidth is content + padding, and a computed width is the box
    // `box-sizing` names: the content box by default, the border box under
    // `border-box`. Both are that same clientWidth with one edge moved, which
    // is deliberate -- the padding box is where clientWidth's fallback to the
    // content extent lives, and a computed width has to carry it too or a
    // "widen until it fits" loop reads two contradictory sizes and never
    // terminates.
    // Neither property applies to a non-replaced inline box, so there is
    // nothing to report: Chrome answers `auto` for both, measured.
    if (isInlineBox(element, frame)) return "auto";

    const edges = boxEdges(element, frame);
    const client = switch (dimension) {
        .width => element.getClientWidthWithCache(frame, &visibility_cache),
        .height => element.getClientHeightWithCache(frame, &visibility_cache),
    };
    const padding, const border = switch (dimension) {
        .width => .{ edges.padding_x, edges.border_x },
        .height => .{ edges.padding_y, edges.border_y },
    };
    const value = if (usesBorderBox(element, frame)) client + border else @max(0, client - padding);

    // Six significant figures, the way every other computed length is written.
    // `{d}` printed a fractional box in full -- a percentage-padded element
    // computed `1619.8527949957197px` here where Chrome prints `1619.85px`,
    // and seventeen digits is a number no browser has ever answered.
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    units.writeNumber(&buf.writer, value) catch return "auto";
    buf.writer.writeAll("px") catch return "auto";
    return buf.written();
}

/// Whether a property name is one of the two origins, in either spelling.
fn isOriginProperty(property_name: []const u8) bool {
    return std.mem.eql(u8, property_name, "transform-origin") or
        std.mem.eql(u8, property_name, "perspective-origin") or
        std.mem.eql(u8, property_name, "-webkit-transform-origin") or
        std.mem.eql(u8, property_name, "-webkit-perspective-origin");
}

/// A declared origin, resolved against the BORDER box the way Chrome resolves
/// it: keywords become percentages, percentages become lengths, and the axis
/// the author left out is filled with `center`.
///
/// The declaration used to be thrown away entirely -- a percentage form fell
/// through to `boxCentre` and a keyword form was echoed back -- so
/// `transform-origin: 25% 75%` on a 240x24 border box answered `120px 12px`
/// where Chrome answers `60px 18px`, and `left top` answered `left top`.
/// Measured over eighteen forms with probes/expr-b85-transform-origin.js.
///
/// Null when the element has no box, which is not a failure: Chrome reports the
/// SPECIFIED value there, and returning null leaves the caller to fall through
/// to the path that already does that.
fn resolvedOrigin(
    style_manager: *StyleManager,
    element: *Element,
    property_name: []const u8,
    value: []const u8,
) ?[]const u8 {
    const frame = element.ownerFrame(style_manager.frame);
    var visibility_cache: Element.VisibilityCache = .{};
    if (!element.checkVisibilityCached(&visibility_cache, frame)) return null;

    const edges = boxEdges(element, frame);
    const width = element.getClientWidthWithCache(frame, &visibility_cache) + edges.border_x;
    const height = element.getClientHeightWithCache(frame, &visibility_cache) + edges.border_y;

    // The ordering and the missing-axis fill are the specified serialiser's job
    // and it already does them: horizontal first, `center` for the axis left
    // out, and a z offset staying third. Anything it refuses is a shape Chrome
    // does not resolve either.
    const ordered = (writeOrigin(frame.call_arena, value) catch null) orelse value;

    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var walk = shorthand.Components.init(ordered);
    while (walk.next()) |part| {
        if (count == parts.len) return null;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) return null;

    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    for (parts[0..count], 0..) |part, i| {
        // The z offset is a length and nothing else, so it has no extent to
        // take a percentage of.
        const extent: ?f64 = switch (i) {
            0 => width,
            1 => height,
            else => null,
        };
        const px = originComponentPx(style_manager, element, property_name, part, extent) orelse return null;
        if (i != 0) buf.writer.writeAll(" ") catch return null;
        units.writeNumber(&buf.writer, px) catch return null;
        buf.writer.writeAll("px") catch return null;
    }
    return buf.written();
}

/// One origin component in pixels. `extent` is the border box's size along that
/// component's axis, or null for the z offset, which takes no percentage.
fn originComponentPx(
    style_manager: *StyleManager,
    element: *Element,
    property_name: []const u8,
    part: []const u8,
    extent: ?f64,
) ?f64 {
    // The keywords are percentages: left and top 0%, center 50%, right and
    // bottom 100%.
    const keyword: ?f64 = if (std.ascii.eqlIgnoreCase(part, "left") or std.ascii.eqlIgnoreCase(part, "top"))
        0
    else if (std.ascii.eqlIgnoreCase(part, "center"))
        50
    else if (std.ascii.eqlIgnoreCase(part, "right") or std.ascii.eqlIgnoreCase(part, "bottom"))
        100
    else
        null;
    if (keyword) |pct| {
        const of = extent orelse return null;
        return of * pct / 100.0;
    }

    const parsed = units.parse(part) catch return null;
    if (parsed.unit == .percentage) {
        const of = extent orelse return null;
        return of * parsed.value / 100.0;
    }
    // Every other unit converts the way it does anywhere else, which is what
    // makes `1em` 16px here without this knowing anything about fonts.
    return switch (lengthFactor(style_manager, element, property_name, parsed.unit)) {
        .pixels => |factor| parsed.value * factor,
        .verbatim => parsed.value,
        .unresolvable => null,
    };
}

/// `transform-origin` and `perspective-origin` both compute to the centre of the
/// border box, which Chrome serialises as two lengths. An element with no box
/// answers from a zero-sized one, the way the dimension path answers "auto".
fn boxCentre(element: *Element, frame: *Frame, property_name: []const u8) []const u8 {
    var visibility_cache: Element.VisibilityCache = .{};
    if (!element.checkVisibilityCached(&visibility_cache, frame)) {
        // No box, so there is no centre to report -- and Chrome does not report
        // a zero one. It answers the SPECIFIED value: `50% 50%` with nothing
        // declared, and the declaration verbatim when there is one. Measured on
        // Chrome 151 with
        // tools/fingerprint/scratch/expr-display-none-percentages.js, beside the
        // two states that make this "no box" and not "a zero box": a rendered
        // `width:0;height:0` element really does answer `0px 0px`, which is what
        // this used to say to both, and `visibility: hidden` still has a box and
        // still reports its centre.
        //
        // The declaration is read under the unprefixed spelling, because the
        // `-webkit-` pair are aliases and a page declares one of them: measured,
        // `-webkit-transform-origin` reports whatever `transform-origin` was set
        // to.
        const unprefixed = if (std.mem.startsWith(u8, property_name, "-webkit-"))
            property_name["-webkit-".len..]
        else
            property_name;
        // The RAW cascade, not cascadedComputedValue: that path runs the computed
        // conversion first and reports `unreportable` for exactly the percentage
        // this branch exists to hand back, so asking it returns nothing. What is
        // wanted here is the specified text.
        const style_manager = &element.ownerFrame(frame)._style_manager;
        switch (cascadedValueRaw(style_manager, element, unprefixed)) {
            .value => |declared| return std.mem.trim(u8, declared, &std.ascii.whitespace),
            .unreportable, .none => {},
        }
        // The initial value, whose own percentages are what Chrome prints here.
        // Deliberately not from chrome_initial_values: both origins are absent
        // from that table on purpose, because a rendered element answers them
        // from the box rather than from a stored string.
        return "50% 50%";
    }
    // The BORDER box, so the border counts: measured, a `border:5px solid`
    // block on the 1904px line has its origin at 952px, the centre of the 1904
    // it occupies, and not at 947, the centre of the 1894 inside its border.
    const edges = boxEdges(element, frame);
    const width = element.getClientWidthWithCache(frame, &visibility_cache) + edges.border_x;
    const height = element.getClientHeightWithCache(frame, &visibility_cache) + edges.border_y;

    // Six significant figures, like every other computed length: the centre of
    // a 133.1875px box is `66.5938px` in Chrome and not the 66.59375 `{d}`
    // prints.
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    units.writeNumber(&buf.writer, width / 2) catch return "0px 0px";
    buf.writer.writeAll("px ") catch return "0px 0px";
    units.writeNumber(&buf.writer, height / 2) catch return "0px 0px";
    buf.writer.writeAll("px") catch return "0px 0px";
    return buf.written();
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    if (self.findProperty(.wrap(normalized))) |prop| {
        return if (prop._important) "important" else "";
    }
    // A shorthand is not stored, so its priority is its longhands': important
    // only when every one of them is.
    const entry = shorthand.lookup(normalized) orelse return "";
    for (entry.longhands) |longhand| {
        const prop = self.findProperty(.wrap(longhand)) orelse return "";
        if (!prop._important) return "";
    }
    return "important";
}

pub fn setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, priority_: ?[]const u8, frame: *Frame) !void {
    // Validate priority
    const priority = priority_ orelse "";
    const important = if (priority.len > 0) blk: {
        if (!std.ascii.eqlIgnoreCase(priority, "important")) {
            return;
        }
        break :blk true;
    } else false;

    // Measured: a set that changes nothing does not rewrite the attribute.
    if (try self.setPropertyImpl(property_name, value, important, frame)) {
        try self.syncStyleAttribute(frame);
    }
}

/// Apply one declaration parsed from a `style=` block. Unlike the imperative
/// setProperty path, within a single declaration block a normal declaration must
/// not override an earlier !important one (CSS cascade precedence).
fn applyParsedDeclaration(self: *CSSStyleDeclaration, declaration: CssParser.Declaration, frame: *Frame) !void {
    if (!declaration.important) {
        const normalized = normalizePropertyName(declaration.name, &frame.buf);
        if (self.findProperty(.wrap(normalized))) |existing| {
            if (existing._important) return;
        }
    }
    // A custom property's value may be empty (`--d:;`), and Chrome keeps the
    // declaration; an empty value for a normal property drops it, and so does
    // an explicit `setProperty(name, "")` for either kind.
    if (isCustomProperty(declaration.name) and declaration.value.len == 0) {
        _ = try self.storeProperty(declaration.name, "", declaration.important, frame);
        return;
    }
    // The caller syncs once for the whole block, so whether this one declaration
    // changed anything does not matter here.
    _ = try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, frame);
}

/// Whether the declaration block came out of this any different. Measured: the
/// style attribute is rewritten only when it did -- see `syncStyleAttribute`.
fn setPropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, frame: *Frame) !bool {
    if (value.len == 0) {
        return (try self.removePropertyImpl(property_name, frame)) != null;
    }

    return self.storeProperty(property_name, value, important, frame);
}

fn storeProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, frame: *Frame) !bool {
    const normalized = normalizePropertyName(property_name, &frame.buf);

    // Chrome does not keep a shorthand: it stores the longhands and rebuilds
    // every read of the shorthand from them. A shorthand whose value does not
    // fit its grammar -- and one the tables do not model -- falls through and
    // is kept whole.
    // `font` is one of the shorthands no model reproduced, so it is kept whole
    // -- except for the six system keywords, which are a closed set with one
    // measured expansion and need none of the grammar. Ahead of the table
    // lookup because that lookup declines an unmodelled shorthand.
    if (shorthand.systemFontExpansion(normalized, value)) |expansion| {
        var changed = false;
        for (expansion.names, expansion.values) |name, longhand| {
            changed = try self.storeLonghand(name, longhand, null, important, frame) or changed;
        }
        // Chrome rebuilds `font` from the longhands on every read; this engine
        // answers a kept-whole shorthand from storage, so the text it will
        // answer goes in beside them.
        return try self.storeLonghand(normalized, shorthand.system_font_shorthand, null, important, frame) or changed;
    }

    // The rest of the `font` grammar, which the table still calls unmodelled --
    // the expansion is read off Chrome rather than derived from the table, so it
    // sits beside the system-keyword branch rather than inside `expand`. Three
    // outcomes: nineteen longhands, a refusal that stores nothing at all (Chrome
    // drops an invalid `font` where every other shorthand is kept whole), or
    // null for a value carrying `var()` / a function / a comment, which falls
    // through and is kept whole as before.
    if (try shorthand.fontExpansion(frame.local_arena, normalized, value)) |outcome| switch (outcome) {
        .refused => return false,
        .wide => |wide| {
            var changed = false;
            for (wide.expansion.names, wide.expansion.values) |name, longhand| {
                changed = try self.storeLonghand(name, longhand, null, important, frame) or changed;
            }
            return changed;
        },
        .parsed => |expansion| {
            var changed = false;
            for (expansion.names, expansion.values) |name, longhand| {
                const canonical = try normalizePropertyValue(frame.local_arena, name, longhand);
                changed = try self.storeLonghand(name, canonical, specifiedNumber(longhand), important, frame) or changed;
            }
            // No `font` entry beside them, unlike the system-keyword branch
            // above: `font` joins now (shorthand.isFont), so every read rebuilds
            // it from the nineteen the way Chrome does, and storing a twentieth
            // would put `style.length` one past Chrome's nineteen.
            return changed;
        },
    };

    if (shorthand.lookup(normalized)) |entry| {
        if (try shorthand.expand(frame.local_arena, entry, value)) |expansion| {
            // Measured: refusing is not a partial write. `border-radius: 10px
            // 20px 30px 40px 50px` leaves no corner holding anything, so every
            // longhand has to be acceptable before the first one is stored.
            for (expansion.names, expansion.values) |name, longhand| {
                if (shorthand.refusesLonghand(name, longhand)) return false;
            }
            var changed = false;
            for (expansion.names, expansion.values) |name, longhand| {
                const canonical = try normalizePropertyValue(frame.local_arena, name, longhand);
                changed = try self.storeLonghand(name, canonical, specifiedNumber(longhand), important, frame) or changed;
            }
            return changed;
        }
        if (shorthand.refusesDeclined(entry, value)) return false;
    } else if (shorthand.refusesLonghand(normalized, value) or
        tooManyComponents(normalized, value))
    {
        return false;
    }

    // Normalize the value for canonical serialization
    const normalized_value = try normalizePropertyValue(frame.local_arena, normalized, value);
    return self.storeLonghand(normalized, normalized_value, specifiedNumber(value), important, frame);
}

fn storeLonghand(self: *CSSStyleDeclaration, normalized: []const u8, normalized_value: []const u8, specified: ?f64, important: bool, frame: *Frame) !bool {

    // Find existing property
    if (self.findProperty(.wrap(normalized))) |existing| {
        // Measured: setting a property to the value it already holds does not
        // touch the attribute -- `setProperty('width', '10px')` over a
        // `width: 10px` leaves the authored text, semicolon and all.
        if (existing._important == important and std.mem.eql(u8, existing._value.str(), normalized_value)) {
            return false;
        }
        existing._value = try String.init(frame.arena, normalized_value, .{});
        existing._specified = specified;
        existing._important = important;
        return true;
    }

    // Create new property
    const prop = try frame._factory.create(Property{
        ._node = .{},
        ._name = try String.init(frame.arena, normalized, .{}),
        ._value = try String.init(frame.arena, normalized_value, .{}),
        ._specified = specified,
        ._important = important,
    });
    self._properties.append(&prop._node);
    return true;
}

pub fn removeProperty(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    const removed = try self.removePropertyImpl(property_name, frame) orelse return "";
    try self.syncStyleAttribute(frame);
    return removed;
}

/// The value the property held, or null if it was not there at all -- which is
/// not the same as an empty one, because a custom property may legitimately
/// hold "" (`--d:;`).
fn removePropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) !?[]const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);

    // Removing a shorthand removes every longhand it expanded to, and answers
    // what it read as on the way out.
    if (shorthand.lookup(normalized)) |entry| {
        const was = self.shorthandValue(normalized, frame) orelse return null;
        const old_value = try frame.call_arena.dupe(u8, was);
        for (entry.longhands) |longhand| {
            const prop = self.findProperty(.wrap(longhand)) orelse continue;
            self._properties.remove(&prop._node);
            frame._factory.destroy(prop);
        }
        return old_value;
    }

    const prop = self.findProperty(.wrap(normalized)) orelse return null;

    // the value might not be on the heap (it could be inlined in the small string
    // optimization), so we need to dupe it.
    const old_value = try frame.call_arena.dupe(u8, prop._value.str());
    self._properties.remove(&prop._node);
    frame._factory.destroy(prop);
    return old_value;
}

// Serialize current properties back to the element's style attribute so that
// DOM serialization (outerHTML, getAttribute) reflects JS-modified styles.
fn syncStyleAttribute(self: *CSSStyleDeclaration, frame: *Frame) !void {
    const element = self._element orelse return;
    const css_text = try self.getCssText(frame);
    self._syncing = true;
    defer self._syncing = false;
    try element.setAttributeSafe(comptime .wrap("style"), .wrap(css_text), frame);
}

// The element's style attribute changed (null: removed)
pub fn styleAttributeChanged(self: *CSSStyleDeclaration, text: ?[]const u8, frame: *Frame) !void {
    if (self._syncing) {
        // this was us making the change internally, automatically in-sync
        return;
    }
    // ok, this change was from the outside, e.g. via setAttribute('style', ....)
    // we need to get this declaration back in sync
    self.clearProperties(frame);
    if (text) |t| {
        try self.applyDeclarations(t, frame);
    }
}

fn clearProperties(self: *CSSStyleDeclaration, frame: *Frame) void {
    var node = self._properties.first;
    while (node) |n| {
        const next = n.next;
        const prop = Property.fromNodeLink(n);
        self._properties.remove(n);
        frame._factory.destroy(prop);
        node = next;
    }
}

pub fn getFloat(self: *const CSSStyleDeclaration, frame: *Frame) []const u8 {
    return self.getPropertyValue("float", frame);
}

pub fn setFloat(self: *CSSStyleDeclaration, value_: ?[]const u8, frame: *Frame) !void {
    if (try self.setPropertyImpl("float", value_ orelse "", false, frame)) {
        try self.syncStyleAttribute(frame);
    }
}

pub fn getCssText(self: *const CSSStyleDeclaration, frame: *Frame) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try self.format(&buf.writer);
    return buf.written();
}

/// Writes `name` as one shorthand if every longhand it covers is in the
/// declaration and unwritten, and if it can be written as one at all. A
/// shorthand that cannot -- `border` with every component at its initial value
/// -- writes the sub-shorthands Chrome was measured writing instead.
fn writeShorthand(
    self: *const CSSStyleDeclaration,
    writer: *std.Io.Writer,
    name: []const u8,
    emitted: *std.StringHashMapUnmanaged(void),
    first: *bool,
    frame: *Frame,
) !bool {
    const entry = shorthand.lookupJoinable(name) orelse return false;
    const held = try frame.local_arena.alloc([]const u8, entry.longhands.len);
    var important = false;
    for (entry.longhands, held, 0..) |longhand, *value, i| {
        if (emitted.contains(longhand)) return false;
        const prop = self.findProperty(.wrap(longhand)) orelse return false;
        if (i == 0) important = prop._important else if (prop._important != important) return false;
        value.* = prop._value.str();
    }

    const text = try shorthand.join(frame.local_arena, entry, held);
    if (text.len == 0) {
        if (entry.fallback.len == 0) return false;
        for (entry.fallback) |sub| {
            if (!try self.writeShorthand(writer, sub, emitted, first, frame)) return false;
        }
        return true;
    }

    if (!first.*) try writer.writeByte(' ');
    first.* = false;
    try writer.writeAll(name);
    try writer.writeAll(": ");
    try writer.writeAll(text);
    if (important) try writer.writeAll(" !important");
    try writer.writeByte(';');
    for (entry.longhands) |longhand| try emitted.put(frame.local_arena, longhand, {});
    return true;
}

pub fn setCssText(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    self.clearProperties(frame);

    try self.applyDeclarations(text, frame);
    try self.syncStyleAttribute(frame);
}

/// The declaration as CSS text, with the longhands a shorthand expanded to
/// written back as that shorthand. Chrome rebuilds this the same way -- it has
/// no record of what was authored -- so `border: 1px solid red` comes back
/// whole, while a `border` whose components all hold their initial value comes
/// back as the four sub-shorthands it was measured writing
/// (`border-width: medium; border-style: none; ...`).
pub fn format(self: *const CSSStyleDeclaration, writer: *std.Io.Writer) !void {
    const frame = self._frame;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted.deinit(frame.local_arena);

    var first = true;
    var node = self._properties.first;
    while (node) |n| : (node = n.next) {
        const prop = Property.fromNodeLink(n);
        if (emitted.contains(prop._name.str())) continue;

        var candidates: [8][]const u8 = undefined;
        for (shorthand.covering(prop._name.str(), &candidates)) |name| {
            if (try self.writeShorthand(writer, name, &emitted, &first, frame)) break;
        } else {
            if (!first) try writer.writeByte(' ');
            first = false;
            try prop.format(writer);
        }
    }
}

pub fn findProperty(self: *const CSSStyleDeclaration, name: String) ?*Property {
    var node = self._properties.first;
    while (node) |n| {
        const prop = Property.fromNodeLink(n);
        if (prop._name.eql(name)) {
            return prop;
        }
        node = n.next;
    }
    return null;
}

/// A property name is matched case-insensitively -- `style.getPropertyValue`
/// and the Typed OM (see `typed_om.normalizeProperty`) both answer `WIDTH`.
pub fn normalizePropertyName(name: []const u8, buf: []u8) []const u8 {
    // Custom property names are case-sensitive: Chrome answers `--Case` and
    // `--case` as two different properties.
    if (isCustomProperty(name)) {
        return name;
    }
    if (name.len > buf.len) {
        log.info(.dom, "css.long.name", .{ .name = name });
        return name;
    }
    return std.ascii.lowerString(buf, name);
}

/// A property name starting with two dashes is a custom property, whose name
/// and value the CSSOM stores as written.
pub fn isCustomProperty(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "--");
}

// Normalize CSS property values for canonical serialization.
//
// Public for StyleManager's raw rule path, which parses declarations straight
// out of a sheet's text and so never went through storeProperty. A computed
// style reports the canonical spelling whatever the author wrote -- `rgb(1,2,3)`
// reads back `rgb(1, 2, 3)` -- and without this the same declaration answered
// one way through `style=` and another through a rule.
pub fn normalizePropertyValue(arena: Allocator, property_name: []const u8, raw_value: []const u8) ![]const u8 {
    // A custom property's value is an arbitrary token stream: Chrome stores it
    // as written, minus the surrounding whitespace (`--c: 01.50` stays
    // "01.50", `--e: a  b   c` keeps its inner runs).
    if (isCustomProperty(property_name)) {
        return std.mem.trim(u8, raw_value, &std.ascii.whitespace);
    }
    const value = try canonicaliseValue(arena, property_name, raw_value);

    // Per CSSOM spec, unitless zero in length properties should serialize as "0px"
    if (std.mem.eql(u8, value, "0") and isLengthProperty(property_name)) {
        return "0px";
    }

    // "first baseline" serializes canonically as "baseline" (first is the default)
    if (std.ascii.startsWithIgnoreCase(value, "first baseline")) {
        if (value.len == 14) {
            // Exact match "first baseline"
            return "baseline";
        }
        if (value.len > 14 and value[14] == ' ') {
            // "first baseline X" -> "baseline X"
            return try std.mem.concat(arena, u8, &.{ "baseline", value[14..] });
        }
    }

    // A counter name carries a count, and Chrome fills in the one it was
    // written without.
    if (counterDefault(property_name)) |default| {
        return writeCounters(arena, value, default);
    }

    // A property written as a pair comes back shorter, by whichever of the
    // three measured rules it takes.
    if (twoValueRule(property_name)) |rule| {
        if (try shortenPairs(arena, rule, value)) |shortened| {
            return shortened;
        }
    }

    // A shadow's components come back in Chrome's order rather than the
    // author's, whichever of the two properties carries them.
    if (std.mem.eql(u8, property_name, "box-shadow") or
        std.mem.eql(u8, property_name, "text-shadow"))
    {
        if (try writeShadow(arena, value)) |ordered| {
            return ordered;
        }
    }

    // An origin is written with its horizontal axis first, and with the axis
    // the author left out filled in.
    if (std.mem.eql(u8, property_name, "transform-origin") or
        std.mem.eql(u8, property_name, "perspective-origin"))
    {
        if (try writeOrigin(arena, value)) |ordered| {
            return ordered;
        }
    }

    // Canonicalize anchor-size() function: anchor name (dashed ident) comes before size keyword
    if (std.mem.indexOf(u8, value, "anchor-size(")) |idx| {
        return canonicalizeAnchorSize(arena, value, idx);
    }

    // Canonicalize anchor() function: anchor name (dashed ident) comes before position keyword
    // Note: indexOf finds first occurrence, so we check it's not part of "anchor-size("
    if (std.mem.indexOf(u8, value, "anchor(")) |idx| {
        if (idx == 0 or value[idx - 1] != '-') {
            return canonicalizeAnchor(arena, value, idx);
        }
    }

    return value;
}

/// Which axis an origin component names, or null for a length or a percentage,
/// which takes whichever axis its slot gives it.
const OriginAxis = enum { horizontal, vertical, either };

fn originAxis(part: []const u8) ?OriginAxis {
    if (std.ascii.eqlIgnoreCase(part, "left") or std.ascii.eqlIgnoreCase(part, "right")) {
        return .horizontal;
    }
    if (std.ascii.eqlIgnoreCase(part, "top") or std.ascii.eqlIgnoreCase(part, "bottom")) {
        return .vertical;
    }
    if (std.ascii.eqlIgnoreCase(part, "center")) return .either;
    return null;
}

/// `transform-origin` and `perspective-origin` as Chrome writes them. Measured
/// with tools/fingerprint/probes/expr-transform-serialize.js: both axes are
/// always written, horizontal first, and a third component -- the z offset --
/// stays where it is while the first two swap.
///
/// A lone component takes `center` on the other axis, and which side it goes
/// depends on the axis the component itself names: `top` is `center top` where
/// `right` is `right center` and `50%` is `50% center`.
///
/// Answers null for anything not of that shape, which keeps the value as
/// written. That covers `transform-origin: top 20px`, which Chrome refuses
/// outright: swapping it would invent `20px top`, a value with a different
/// meaning that Chrome never writes, and keeping it is the wrong this engine
/// already had.
fn writeOrigin(arena: Allocator, value: []const u8) !?[]const u8 {
    if (hasVerbatimFunction(value)) {
        return null;
    }

    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var walk = shorthand.Components.init(value);
    while (walk.next()) |part| {
        if (count == parts.len) return null;
        parts[count] = part;
        count += 1;
    }
    // A `/` stops the walk, and an origin never carries one.
    if (walk.stopped or count == 0) return null;

    if (count == 1) {
        const filled: [2][]const u8 = if (originAxis(parts[0]) == .vertical)
            .{ "center", parts[0] }
        else
            .{ parts[0], "center" };
        return try std.mem.join(arena, " ", &filled);
    }

    // Only a vertical keyword in front of something that can hold the
    // horizontal axis is out of order. A length second -- `top 20px` -- is the
    // shape Chrome refuses, and is left alone rather than swapped.
    const lead = originAxis(parts[0]);
    const follow = originAxis(parts[1]);
    if (lead != .vertical or (follow != .horizontal and follow != .either)) {
        return null;
    }

    var out: [3][]const u8 = .{ parts[1], parts[0], undefined };
    if (count == 3) out[2] = parts[2];
    return try std.mem.join(arena, " ", out[0..count]);
}

/// A shadow layer as Chrome writes it: the colour first, then the lengths in
/// the order the author gave them, then `inset`. Measured with
/// `tools/fingerprint/probes/expr-shadow-serialize.js` over `box-shadow` and
/// `text-shadow` -- `inset 0 0 0 rgb(34, 139, 73)` comes back
/// `rgb(34, 139, 73) 0px 0px 0px inset`, which is seven of the rules in the
/// Cloudflare @keyframes payload.
///
/// Chrome reorders but does not fill in: `1px 1px red` keeps its two lengths
/// rather than gaining the blur and spread it was written without. The lengths
/// are also the one slot a unitless zero can hide in, and Chrome answers it
/// `0px` there -- `normalizePropertyValue`'s whole-value rule never reaches it,
/// because the zero is one component of a list.
///
/// Answers null for anything that is not this shape, which leaves the value the
/// bytes it arrived with: `none` and the CSS-wide keywords, a layer carrying no
/// length at all, a second colour or a second `inset`, and a value calling a
/// function whose text this engine does not have.
fn writeShadow(arena: Allocator, value: []const u8) !?[]const u8 {
    // A substitution stands in for text that arrives later, so which slot each
    // component lands in is not knowable here.
    if (hasVerbatimFunction(value)) {
        return null;
    }

    // The colour slot takes a colour keyword and nothing else, so the measured
    // spellings of one are enough to re-case it. `background-color` carries
    // that list -- the same 160-odd names, `currentcolor` and `transparent`
    // included -- and a name that is not on it is left alone.
    const colours = chrome_keywords.keywords.get("background-color");

    var buf = std.Io.Writer.Allocating.init(arena);
    errdefer buf.deinit();

    var layers = shorthand.Layers.init(value);
    var first = true;
    while (layers.next()) |layer| {
        var lengths: [4][]const u8 = undefined;
        var length_count: usize = 0;
        var colour: ?[]const u8 = null;
        var inset = false;

        var parts = shorthand.Components.init(layer);
        while (parts.next()) |part| {
            if (std.ascii.eqlIgnoreCase(part, "inset")) {
                if (inset) return null;
                inset = true;
            } else if (isLengthToken(part)) {
                if (length_count == lengths.len) return null;
                // Only a zero is a bare number a length slot takes; writing
                // `px` onto any other would invent a length Chrome refused.
                lengths[length_count] = if (std.mem.eql(u8, part, "0")) "0px" else part;
                length_count += 1;
            } else {
                if (colour != null) return null;
                colour = keywordSpelling(colours, part, false);
            }
        }
        // A `/` stops the walk, and a shadow never carries one.
        if (parts.stopped) return null;
        // Two lengths are the fewest a shadow has. Fewer means this is not one:
        // `none`, `inherit`, or a value that did not parse as a shadow at all.
        if (length_count < 2) return null;

        if (!first) {
            try buf.writer.writeAll(", ");
        }
        first = false;

        if (colour) |name| {
            try buf.writer.writeAll(name);
            try buf.writer.writeByte(' ');
        }
        for (lengths[0..length_count], 0..) |dimension, i| {
            if (i != 0) try buf.writer.writeByte(' ');
            try buf.writer.writeAll(dimension);
        }
        if (inset) {
            try buf.writer.writeAll(" inset");
        }
    }

    // A value already in Chrome's order is far commoner than one out of it, so
    // the copy is usually thrown away.
    if (std.mem.eql(u8, buf.written(), value)) {
        buf.deinit();
        return null;
    }
    return buf.written();
}

/// Whether a shadow component is one of its lengths rather than its colour: a
/// number, optionally signed, optionally carrying a unit. `-webkit-x` opens
/// with the same byte as `-1px` and is not one, so the sign has to be followed
/// by a digit or a dot.
fn isLengthToken(part: []const u8) bool {
    var i: usize = 0;
    if (i < part.len and (part[i] == '-' or part[i] == '+')) i += 1;
    if (i >= part.len) return false;
    return std.ascii.isDigit(part[i]) or part[i] == '.';
}

/// Rewrite a value into the text Chrome answers with. Measured
/// (probe-css13.js, and the number and colour readings in the plan's C1 notes),
/// Chrome touches six things and leaves everything else as the author wrote it:
///
///   * a keyword the property takes, a CSS-wide keyword, a dimension's unit and
///     a function name are re-spelled -- to the spelling Chrome answers with
///     rather than lowercased, so `TranslateX(1PX)` comes back
///     `translateX(1px)` and a blanket `toLowerCase()` would trade one tell for
///     another;
///   * a number is reprinted rather than echoed (`writeCssNumber`);
///   * a colour is folded to `rgb()`/`rgba()` when Chrome folds it
///     (`parseHexColour`, `parseColourFunction`).
///
/// The tables and shapes are the limit of what is rewritten: a keyword the
/// property is not measured as taking, a unit or a function name no measurement
/// reached, a colour space Chrome keeps, and anything that is not one of those
/// shapes at all -- a `<custom-ident>`, a string, an unquoted url path -- all
/// come through untouched. Under-normalising leaves a page working;
/// over-normalising invents a spelling Chrome never uses.
///
/// `property_name` has already been lowercased by `storeProperty`, which is the
/// spelling both keyword tables are keyed on.
fn canonicaliseValue(arena: Allocator, property_name: []const u8, value: []const u8) ![]const u8 {
    // Measured: a value whose real content is substituted later is kept byte
    // for byte, and that covers everything around the substitution as well --
    // `width: CALC(1PX + VAR(--a))` reads back exactly as written.
    if (hasVerbatimFunction(value)) {
        return value;
    }

    // A property taking an arbitrary `<custom-ident>` still has keywords --
    // `font-family` takes `MyOwnFont` and `sans-serif` both -- so it gets the
    // table measured by re-casing rather than by acceptance. Everything the
    // measurement did not name there is a custom ident and keeps its capitals.
    const keywords: ?[]const []const u8 = if (chrome_keywords.any_identifier.has(property_name))
        chrome_value_case.any_identifier_keywords.get(property_name)
    else
        chrome_keywords.keywords.get(property_name);

    // A CSS-wide keyword is only one when it is the whole value; inside a list
    // the same word can be a family name.
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);

    // The two properties whose value carries a font family.
    const is_font_shorthand = std.mem.eql(u8, property_name, "font");
    const is_font_family = std.mem.eql(u8, property_name, "font-family") or is_font_shorthand;

    // Measured: `stroke-dasharray` is a list whatever separates it, and Chrome
    // answers every separator as `, ` -- `32 32` comes back `32, 32`. No other
    // property in the measurement turns a space into a comma.
    const is_dasharray = std.mem.eql(u8, property_name, "stroke-dasharray");

    var buf = std.Io.Writer.Allocating.init(arena);
    errdefer buf.deinit();
    var changed = false;
    // In the `font` shorthand the family is whatever follows the size, so a run
    // of identifiers is only a family name once a number has gone past. Before
    // that the run is `italic bold`, which stays two keywords.
    var seen_number = false;
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        const before_i = i;
        const before_len = buf.written().len;

        // Chrome re-serialises a value's punctuation rather than echoing it:
        // whatever the author wrote, every comma comes back `, ` and every
        // slash ` / `. Measured across font-family, transition, will-change,
        // grid-area, grid-row, aspect-ratio, font and border-radius; a custom
        // property never reaches here, and its punctuation stays as written.
        if (std.ascii.isWhitespace(c)) {
            var end = i;
            while (end < value.len and std.ascii.isWhitespace(value[end])) end += 1;
            // A run in front of a comma or a slash belongs to that token's own
            // spacing, and a run at the end is not part of the value at all.
            if (end < value.len and value[end] != ',' and value[end] != '/') {
                if (buf.written().len != 0) {
                    try buf.writer.writeAll(if (is_dasharray) ", " else " ");
                }
            }
            changed = changed or !std.mem.eql(u8, buf.written()[before_len..], value[i..end]);
            i = end;
            continue;
        }

        if (c == ',' or c == '/') {
            if (c == ',') {
                try buf.writer.writeAll(", ");
            } else {
                try buf.writer.writeAll(if (buf.written().len == 0) "/ " else " / ");
            }
            i += 1;
            while (i < value.len and std.ascii.isWhitespace(value[i])) i += 1;
            changed = changed or !std.mem.eql(u8, buf.written()[before_len..], value[before_i..i]);
            continue;
        }

        // A string is content rather than syntax: `content: "MiXeD"` keeps its
        // case, quotes and escapes. A font family is the exception -- there the
        // quotes are punctuation around a name, and Chrome drops the ones the
        // name does not need.
        if (c == '"' or c == '\'') {
            const end = stringEnd(value, i);
            if (is_font_family) {
                const before = buf.written().len;
                i = try writeFontFamily(&buf.writer, value, i);
                changed = changed or !std.mem.eql(u8, buf.written()[before..], value[before_i..i]);
            } else {
                try buf.writer.writeAll(value[i..end]);
                i = end;
            }
            continue;
        }

        // A hash is one token: the digits of `#AABBCC` are neither an
        // identifier to re-case nor a number to reprint, and the whole of it is
        // what folds to an rgb().
        if (c == '#') {
            const end = hashEnd(value, i);
            const token = value[i..end];
            if (parseHexColour(token)) |colour| {
                const before = buf.written().len;
                try writeColour(&buf.writer, colour);
                changed = changed or !std.mem.eql(u8, buf.written()[before..], token);
            } else {
                try buf.writer.writeAll(token);
            }
            i = end;
            continue;
        }

        if (isIdentStart(value, i)) {
            const end = identEnd(value, i);
            const name = value[i..end];

            if (end < value.len and value[end] == '(') {
                // A colour Chrome folds is answered as an rgb() whatever it was
                // written as, so the call goes rather than being re-spelled.
                if (colourFunction(name)) |kind| {
                    if (parseColourFunction(kind, value, end)) |colour| {
                        const before = buf.written().len;
                        try writeColour(&buf.writer, colour.value);
                        changed = changed or
                            !std.mem.eql(u8, buf.written()[before..], value[before_i..colour.end]);
                        i = colour.end;
                        continue;
                    }
                }
                const spelling = lookupSpelling(chrome_value_case.functions, name) orelse name;
                try buf.writer.writeAll(spelling);
                changed = changed or !std.mem.eql(u8, spelling, name);
                i = end;
                // A url()'s content is one token rather than a value, and it
                // gets its own serialisation: measured, Chrome answers a path
                // in double quotes however it was written.
                if (std.ascii.eqlIgnoreCase(name, "url")) {
                    const before = buf.written().len;
                    i = try writeUrl(&buf.writer, value, i);
                    changed = changed or !std.mem.eql(u8, buf.written()[before..], value[end..i]);
                }
                continue;
            }

            // Two or more bare identifiers in a row are one family name, and
            // Chrome answers it as a quoted string: `Times New Roman` reads
            // back `"Times New Roman"`. A lone identifier keeps its own
            // spelling -- quoting it would turn the generic `serif` into a
            // family that happens to be called that.
            if (is_font_family and (!is_font_shorthand or seen_number)) {
                if (familyRunEnd(value, i)) |run_end| {
                    try writeFamilyRun(&buf.writer, value[i..run_end]);
                    changed = true;
                    i = run_end;
                    continue;
                }
            }

            const spelling = keywordSpelling(keywords, name, std.mem.eql(u8, trimmed, name));
            try buf.writer.writeAll(spelling);
            changed = changed or !std.mem.eql(u8, spelling, name);
            i = end;
            continue;
        }

        // A digit run right after an identifier character belongs to that token
        // rather than starting a number of its own -- the `+0` of
        // `unicode-range: U+0-7F` is not a number Chrome would reprint.
        const number_end = if (i > 0 and isIdentChar(value[i - 1]))
            null
        else
            numberEnd(value, i);
        if (number_end) |end| {
            const before = buf.written().len;
            const dimension = end < value.len and (value[end] == '%' or isIdentStart(value, end));
            if (!dimension and isIntegerToken(value[i..end]) and
                (isIntegerProperty(property_name) or takesIntegerFirst(value, i)))
            {
                try writeCssInteger(&buf.writer, value[i..end]);
            } else {
                try writeCssNumber(&buf.writer, value[i..end]);
            }
            seen_number = true;
            i = end;
            if (i < value.len and isIdentStart(value, i)) {
                const unit_end = identEnd(value, i);
                const unit = value[i..unit_end];
                try buf.writer.writeAll(lookupSpelling(chrome_value_case.units, unit) orelse unit);
                i = unit_end;
            }
            changed = changed or !std.mem.eql(u8, buf.written()[before..], value[before_i..i]);
            continue;
        }

        try buf.writer.writeByte(c);
        i += 1;
    }

    // Most values carry no capital at all, so the copy is thrown away far more
    // often than it is kept.
    if (!changed) {
        buf.deinit();
        return value;
    }
    return buf.written();
}

/// Serialise the `url(...)` whose opening paren is at `open`, and answer the
/// index just past its closing one. Measured: Chrome always answers
/// `url("<path>")` -- an unquoted path gains quotes, a single-quoted one is
/// requoted, the whitespace around it goes, the escapes an unquoted path needs
/// are resolved (`url(a\ b)` is `url("a b")`, `url(a\28 b)` is `url("a(b")`),
/// and the two characters a quoted path cannot hold bare are escaped back.
fn writeUrl(writer: *std.Io.Writer, value: []const u8, open: usize) !usize {
    var i = open + 1;
    while (i < value.len and std.ascii.isWhitespace(value[i])) : (i += 1) {}

    var content: []const u8 = "";
    if (i < value.len and (value[i] == '"' or value[i] == '\'')) {
        const end = stringEnd(value, i);
        const terminated = end > i + 1 and value[end - 1] == value[i];
        content = value[i + 1 .. if (terminated) end - 1 else end];
        i = end;
    } else {
        const start = i;
        while (i < value.len and value[i] != ')') : (i += 1) {
            if (value[i] == '\\' and i + 1 < value.len) i += 1;
        }
        content = std.mem.trimEnd(u8, value[start..i], &std.ascii.whitespace);
    }
    while (i < value.len and value[i] != ')') : (i += 1) {}

    try writer.writeAll("(\"");
    try writeEscaped(writer, content);
    try writer.writeAll("\")");
    return if (i < value.len) i + 1 else i;
}

/// The code points a url path or a string is really made of: `a\28 b` is
/// `a(b`, `a\ b` is `a b`. Chrome resolves these before it decides anything
/// about the text -- whether a font family can go unquoted, what a url()
/// serialises as -- so the decision and the output both read through here.
const Escapes = struct {
    raw: []const u8,
    index: usize = 0,

    fn next(self: *Escapes) ?u32 {
        if (self.index == self.raw.len) {
            return null;
        }
        const c = self.raw[self.index];
        if (c != '\\') {
            self.index += 1;
            return c;
        }
        self.index += 1;
        if (self.index == self.raw.len) {
            // A trailing backslash escapes nothing.
            return null;
        }
        if (std.fmt.charToDigit(self.raw[self.index], 16) catch null == null) {
            // `\x` is whatever x is, escape or no escape.
            defer self.index += 1;
            return self.raw[self.index];
        }
        var code: u32 = 0;
        var digits: usize = 0;
        while (self.index < self.raw.len and digits < 6) : (digits += 1) {
            const digit = std.fmt.charToDigit(self.raw[self.index], 16) catch break;
            code = code * 16 + digit;
            self.index += 1;
        }
        // A single whitespace may follow, to say where the escape stops.
        if (self.index < self.raw.len and std.ascii.isWhitespace(self.raw[self.index])) {
            self.index += 1;
        }
        return code;
    }
};

/// Write the decoded text back out, escaping the two characters a quoted one
/// cannot hold bare.
fn writeEscaped(writer: *std.Io.Writer, raw: []const u8) !void {
    var escapes: Escapes = .{ .raw = raw };
    while (escapes.next()) |code| {
        if (code == '"' or code == '\\') {
            try writer.writeByte('\\');
        }
        if (code < 0x80) {
            try writer.writeByte(@intCast(code));
            continue;
        }
        var utf8: [4]u8 = undefined;
        // A zero, a surrogate half or anything past the last code point is the
        // replacement character, which is what the tokeniser is specified to do.
        const len = std.unicode.utf8Encode(std.math.cast(u21, code) orelse 0xFFFD, &utf8) catch
            std.unicode.utf8Encode(0xFFFD, &utf8) catch unreachable;
        try writer.writeAll(utf8[0..len]);
    }
}

/// A quoted font family loses its quotes when it does not need them. Measured:
/// that is when the decoded name is a single identifier which is not a keyword
/// -- the quotes are what tell a family *called* `monospace` from the generic
/// one, so a name spelling one keeps them. That comparison is case-sensitive:
/// `"MONOSPACE"` comes out bare, and is not then re-cased into the keyword.
fn writeFontFamily(writer: *std.Io.Writer, value: []const u8, start: usize) !usize {
    const end = stringEnd(value, start);
    const quote = value[start];
    const terminated = end > start + 1 and value[end - 1] == quote;
    const raw = value[start + 1 .. if (terminated) end - 1 else end];

    var buf: [128]u8 = undefined;
    if (decodeInto(&buf, raw)) |name| {
        if (isBareFamilyName(name)) {
            try writer.writeAll(name);
            return end;
        }
    }
    // Whatever keeps its quotes gets Chrome's: `'a b'` answers `"a b"`.
    try writer.writeByte('"');
    try writeEscaped(writer, raw);
    try writer.writeByte('"');
    return end;
}

/// The end of the run of whitespace-separated bare identifiers starting at
/// `start`, or null when only one identifier is there. A run of two or more is
/// a single family name written without quotes, which is what Chrome quotes on
/// the way back out; one identifier is a name or a keyword and stays as it is.
fn familyRunEnd(value: []const u8, start: usize) ?usize {
    var end = identEnd(value, start);
    var count: usize = 1;
    while (true) {
        var next = end;
        while (next < value.len and std.ascii.isWhitespace(value[next])) next += 1;
        // No gap means the next token is punctuation, and anything that is not
        // an identifier ends the name.
        if (next == end or next >= value.len or !isIdentStart(value, next)) {
            break;
        }
        const ident_end = identEnd(value, next);
        // A call is a value of its own, not a word of the name.
        if (ident_end < value.len and value[ident_end] == '(') {
            break;
        }
        count += 1;
        end = ident_end;
    }
    return if (count > 1) end else null;
}

/// Write the run as Chrome does: one double-quoted string, the identifiers
/// joined by single spaces however many the author wrote.
fn writeFamilyRun(writer: *std.Io.Writer, run: []const u8) !void {
    try writer.writeByte('"');
    var i: usize = 0;
    var first = true;
    while (i < run.len) {
        while (i < run.len and std.ascii.isWhitespace(run[i])) i += 1;
        if (i >= run.len) {
            break;
        }
        if (!first) {
            try writer.writeByte(' ');
        }
        first = false;
        const end = identEnd(run, i);
        try writeEscaped(writer, run[i..end]);
        i = end;
    }
    try writer.writeByte('"');
}

fn decodeInto(buf: []u8, raw: []const u8) ?[]const u8 {
    var escapes: Escapes = .{ .raw = raw };
    var len: usize = 0;
    while (escapes.next()) |code| {
        if (code >= 0x80 or len == buf.len) {
            // A name needing more room than this, or holding anything outside
            // ASCII, is not one that could go bare anyway.
            return null;
        }
        buf[len] = @intCast(code);
        len += 1;
    }
    return buf[0..len];
}

fn isBareFamilyName(name: []const u8) bool {
    if (name.len == 0 or !isIdentStart(name, 0) or identEnd(name, 0) != name.len) {
        return false;
    }
    // Measured: `-a` goes bare but `--a` does not.
    if (std.mem.startsWith(u8, name, "--")) {
        return false;
    }
    for (chrome_keywords.css_wide) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return false;
    }
    const generic = chrome_value_case.any_identifier_keywords.get("font-family") orelse return true;
    for (generic) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return false;
    }
    return true;
}

/// The canonical spelling of a bare identifier, or the one it was written with
/// when no table vouches for it -- the same judgement `typed_om.lookupIdentifier`
/// makes, and for the same reason: guessing at a name the measurement never
/// covered is how an engine ends up stricter, or louder, than Chrome.
fn keywordSpelling(keywords: ?[]const []const u8, name: []const u8, whole_value: bool) []const u8 {
    if (whole_value) {
        for (chrome_keywords.css_wide) |keyword| {
            if (std.ascii.eqlIgnoreCase(keyword, name)) return keyword;
        }
    }
    for (keywords orelse return name) |keyword| {
        if (std.ascii.eqlIgnoreCase(keyword, name)) return keyword;
    }
    return name;
}

fn lookupSpelling(table: std.StaticStringMap([]const u8), name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) {
        return null;
    }
    return table.get(std.ascii.lowerString(buf[0..name.len], name));
}

/// Whether the value calls one of the functions Chrome does not re-case.
fn hasVerbatimFunction(value: []const u8) bool {
    for (chrome_value_case.verbatim_functions) |name| {
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(value, from, name)) |at| {
            from = at + name.len;
            // A function name is only one when it is a whole name followed
            // immediately by the paren: `--myvar(` is not `var(`.
            if (from < value.len and value[from] == '(' and (at == 0 or !isIdentChar(value[at - 1]))) {
                return true;
            }
        }
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isIdentStart(value: []const u8, index: usize) bool {
    const c = value[index];
    if (std.ascii.isAlphabetic(c) or c == '_') {
        return true;
    }
    if (c != '-' or index + 1 >= value.len) {
        return false;
    }
    const next = value[index + 1];
    return std.ascii.isAlphabetic(next) or next == '_' or next == '-';
}

fn identEnd(value: []const u8, start: usize) usize {
    var i = start;
    while (i < value.len and isIdentChar(value[i])) : (i += 1) {}
    return i;
}

/// Where the number starting at `index` ends, or null when one does not start
/// there. The exponent is only taken when digits follow it, so the `e` of
/// `1em` stays with the unit.
fn numberEnd(value: []const u8, index: usize) ?usize {
    var i = index;
    if (value[i] == '+' or value[i] == '-') {
        i += 1;
    }
    var digits: usize = 0;
    while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
        digits += 1;
    }
    if (i < value.len and value[i] == '.') {
        var j = i + 1;
        while (j < value.len and std.ascii.isDigit(value[j])) : (j += 1) {
            digits += 1;
        }
        if (j > i + 1) {
            i = j;
        }
    }
    if (digits == 0) {
        return null;
    }
    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        var j = i + 1;
        if (j < value.len and (value[j] == '+' or value[j] == '-')) {
            j += 1;
        }
        const exponent_start = j;
        while (j < value.len and std.ascii.isDigit(value[j])) : (j += 1) {}
        if (j > exponent_start) {
            i = j;
        }
    }
    return i;
}

fn stringEnd(value: []const u8, start: usize) usize {
    const quote = value[start];
    var i = start + 1;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\') {
            i += 1;
            continue;
        }
        if (value[i] == quote) {
            return i + 1;
        }
    }
    return value.len;
}

/// A `<number>` or `<length>` is not echoed back: Chrome reprints it, which is
/// what folds `1E2px` to `100px`, `1.50px` to `1.5px` and `+1px` to `1px`. The
/// printer is the one Typed OM already uses -- printf `%g`, six significant
/// digits -- over a value clamped to the float range: measured,
/// `width: 1e100px` answers `3.40282e+38px` (FLT_MAX), while `width: 1e-40px`
/// keeps all six digits no float could hold, so the clamp is to the range and
/// not to float precision.
/// The number a whole declaration is, when it is one numeric token, kept beside
/// the six-significant-figure text writeCssNumber prints.
///
/// The two cannot be one string. `width:465.5466592px` reads back `465.547px`
/// in Chrome as it does here -- that print is measured and must not change --
/// but the box Chrome lays out is 465.53125, which is what the AUTHOR's number
/// floors to on the 1/64 grid. Parsing the print back gives 465.546875, a step
/// high; the same rounding runs the other way on `width:465.53125px`, where the
/// print floors a step LOW. So the print is stored for reading and this number
/// for laying out.
///
/// It is a **32-bit float**, because that is the width Blink parses a CSS length
/// into and the difference is visible: `width:100.0156249px` is a hair under a
/// grid step as a double and floors to 100, and IS the step as a float, which is
/// what Chrome answers. Over the twenty-one widths in
/// tools/fingerprint/scratch/expr-precision-model.js the float model matches
/// Chrome 21 times, the double 15 and the printed text 14.
///
/// Null for anything that is not a single number with an optional unit -- a
/// keyword, a list, a function, a shorthand's leftovers -- which leaves every
/// caller on the text path it was already on.
pub fn specifiedNumber(raw_value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    for (trimmed) |c| {
        if (std.ascii.isWhitespace(c) or c == ',' or c == '(' or c == '/') return null;
    }
    const parsed = units.parse(trimmed) catch return null;
    return @as(f32, @floatCast(parsed.value));
}

fn writeCssNumber(writer: *std.Io.Writer, text: []const u8) !void {
    const v = std.fmt.parseFloat(f64, text) catch return writer.writeAll(text);
    const limit: f64 = std.math.floatMax(f32);
    try typed_om.writeNumber(writer, std.math.clamp(v, -limit, limit));
}

/// An `<integer>` is printed as an integer rather than through `%g`, so it keeps
/// its digits past the sixth: measured, `z-index: 1000000` answers `1000000`
/// where `flex-grow: 1000000` answers `1e+06`. Blink parses one into an int, and
/// the value clamps there -- `z-index: 3000000000` answers `2147483647`,
/// measured over ten integer-valued properties and both integer-taking
/// functions.
fn writeCssInteger(writer: *std.Io.Writer, text: []const u8) !void {
    const v = std.fmt.parseFloat(f64, text) catch return writer.writeAll(text);
    const clamped = std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32));
    try writer.print("{d}", .{@as(i32, @intFromFloat(clamped))});
}

/// Whether the number is written as a bare integer -- the only shape an
/// `<integer>` can have, so the only one printed as one.
fn isIntegerToken(text: []const u8) bool {
    const digits = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
    if (digits.len == 0) {
        return false;
    }
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// The properties whose bare number is an `<integer>`. Measured by writing
/// `1000000` to each of the 772 property names Chrome knows and reading it back:
/// 19 answer `1000000` and 72 answer `1e+06`. The four below that the bare form
/// cannot reach -- their integer sits after an identifier or a string -- were
/// measured in that longer form (`counter-increment: c 1000000`,
/// `font-feature-settings: "liga" 1000000`).
///
/// A dimension is never one of these: `columns: 1000000px` answers `1e+06px`
/// even though `columns: 1000000` answers `1000000`, so only the unitless token
/// takes this path.
fn isIntegerProperty(name: []const u8) bool {
    const integer_properties = std.StaticStringMap(void).initComptime(.{
        .{ "-webkit-box-ordinal-group", {} },
        .{ "-webkit-line-clamp", {} },
        .{ "column-count", {} },
        .{ "columns", {} },
        .{ "counter-increment", {} },
        .{ "counter-reset", {} },
        .{ "counter-set", {} },
        .{ "flex-line-count", {} },
        .{ "font-feature-settings", {} },
        .{ "grid-area", {} },
        .{ "grid-column", {} },
        .{ "grid-column-end", {} },
        .{ "grid-column-start", {} },
        .{ "grid-row", {} },
        .{ "grid-row-end", {} },
        .{ "grid-row-start", {} },
        .{ "hyphenate-limit-chars", {} },
        .{ "math-depth", {} },
        .{ "order", {} },
        .{ "orphans", {} },
        .{ "reading-order", {} },
        .{ "widows", {} },
        .{ "z-index", {} },
    });
    return integer_properties.has(name);
}

/// The two functions whose first argument is an `<integer>` whatever property
/// they sit in: measured, `grid-template-columns: repeat(1000000, 1px)` and
/// `steps(1000000, jump-start)` both keep their digits where every other
/// function argument goes through `%g` (`transform: scale(1000000)` answers
/// `scale(1e+06)`).
fn takesIntegerFirst(value: []const u8, index: usize) bool {
    var i = index;
    while (i > 0 and std.ascii.isWhitespace(value[i - 1])) : (i -= 1) {}
    if (i == 0 or value[i - 1] != '(') {
        return false;
    }
    const paren = i - 1;
    var start = paren;
    while (start > 0 and isIdentChar(value[start - 1])) : (start -= 1) {}
    const name = value[start..paren];
    return std.ascii.eqlIgnoreCase(name, "repeat") or std.ascii.eqlIgnoreCase(name, "steps");
}

/// Where the hash token starting at `index` ends. Its content is only ever hex
/// digits when it is a colour, but an id in a value (`url(#a)` aside) can hold
/// any identifier character, and reading the whole token is what keeps the
/// digits away from the number and identifier paths.
fn hashEnd(value: []const u8, index: usize) usize {
    var i = index + 1;
    while (i < value.len and isIdentChar(value[i])) : (i += 1) {}
    return i;
}

/// A colour as Chrome answers it: three bytes and an alpha byte.
const Colour = struct {
    rgb: [3]u8,
    alpha: u8,
};

/// Measured: `#AABBCC` answers `rgb(170, 187, 204)`, the three and four digit
/// forms double each nibble, and an alpha of 255 answers `rgb()` rather than
/// `rgba(..., 1)`. A hash of any other length is not a colour -- Chrome drops
/// the declaration, this engine keeps the text, which is the difference it keeps
/// everywhere else too.
fn parseHexColour(token: []const u8) ?Colour {
    const digits = token[1..];
    switch (digits.len) {
        3, 4, 6, 8 => {},
        else => return null,
    }
    var nibbles: [8]u8 = undefined;
    for (digits, 0..) |c, i| {
        nibbles[i] = std.fmt.charToDigit(c, 16) catch return null;
    }
    if (digits.len <= 4) {
        var colour: Colour = .{ .rgb = undefined, .alpha = 255 };
        for (0..3) |i| colour.rgb[i] = nibbles[i] * 17;
        if (digits.len == 4) colour.alpha = nibbles[3] * 17;
        return colour;
    }
    var colour: Colour = .{ .rgb = undefined, .alpha = 255 };
    for (0..3) |i| colour.rgb[i] = nibbles[i * 2] * 16 + nibbles[i * 2 + 1];
    if (digits.len == 8) colour.alpha = nibbles[6] * 16 + nibbles[7];
    return colour;
}

/// The colour functions Chrome answers as an `rgb()`. Measured: `oklch()`,
/// `lab()`, `lch()`, `oklab()`, `color()`, `color-mix()` and `light-dark()` keep
/// their own function, so they are not here and their arguments are left as
/// written.
const ColourFunction = enum { rgb, hsl, hwb };

fn colourFunction(name: []const u8) ?ColourFunction {
    if (std.ascii.eqlIgnoreCase(name, "rgb") or std.ascii.eqlIgnoreCase(name, "rgba")) {
        return .rgb;
    }
    if (std.ascii.eqlIgnoreCase(name, "hsl") or std.ascii.eqlIgnoreCase(name, "hsla")) {
        return .hsl;
    }
    if (std.ascii.eqlIgnoreCase(name, "hwb")) {
        return .hwb;
    }
    return null;
}

/// One channel as it was written. `none` is a channel Chrome reads as zero.
const Channel = union(enum) {
    number: f64,
    percentage: f64,
    angle: f64,
    none,
};

/// What separates an argument from the one before it. Which separators a call
/// uses is what tells the two argument forms apart, and Chrome accepts each
/// whole rather than mixed: `rgb(50%, 25, 0%)` and `rgb(1 2 3 4)` are both
/// dropped, so a call that is neither form is left as written.
const Separator = enum { first, space, comma, slash };

/// Parse the arguments of a colour function whose `(` is at `open`, answering
/// null for anything the fold cannot be sure of -- a `calc()` or any other
/// nested call, a relative colour (`rgb(from red r g b)`), a channel in a unit
/// the function does not take, an argument count Chrome rejects. Those keep the
/// text the author wrote, which is the safe direction: Chrome drops what it
/// rejects, and inventing an `rgb()` for it would be a spelling Chrome never
/// answers.
fn parseColourFunction(
    kind: ColourFunction,
    value: []const u8,
    open: usize,
) ?struct { value: Colour, end: usize } {
    var channels: [5]Channel = undefined;
    var separators: [5]Separator = undefined;
    var count: usize = 0;

    var i = open + 1;
    var pending: Separator = .first;
    while (i < value.len and value[i] != ')') {
        const c = value[i];
        if (std.ascii.isWhitespace(c)) {
            if (count > 0 and pending == .first) pending = .space;
            i += 1;
            continue;
        }
        if (c == ',' or c == '/') {
            pending = if (c == ',') .comma else .slash;
            i += 1;
            continue;
        }
        // A nested call is a value this fold cannot compute.
        if (c == '(') {
            return null;
        }
        const start = i;
        while (i < value.len and value[i] != ')' and value[i] != ',' and value[i] != '/' and
            !std.ascii.isWhitespace(value[i])) : (i += 1)
        {
            if (value[i] == '(') return null;
        }
        if (count == channels.len) {
            return null;
        }
        channels[count] = parseChannel(value[start..i]) orelse return null;
        separators[count] = pending;
        count += 1;
        pending = .first;
    }
    if (i == value.len) {
        // Unclosed: leave it alone rather than guess where it ended.
        return null;
    }
    const end = i + 1;

    // Three components, then an alpha introduced by a comma in the comma form
    // and by a slash in the space separated one.
    if (count != 3 and count != 4) {
        return null;
    }
    const comma_form = separators[1] == .comma;
    for (separators[1..3]) |separator| {
        if (separator != (if (comma_form) Separator.comma else Separator.space)) return null;
    }
    if (count == 4 and separators[3] != (if (comma_form) Separator.comma else Separator.slash)) {
        return null;
    }

    const alpha: u8 = if (count == 4) alphaByte(channels[3]) orelse return null else 255;
    const components = channels[0..3];
    const rgb: [3]f64 = switch (kind) {
        .rgb => blk: {
            // Measured: every component is a number or every component is a
            // percentage. `none` counts as either.
            var percentage: ?bool = null;
            for (components) |channel| {
                const is_percentage = switch (channel) {
                    .number => false,
                    .percentage => true,
                    .angle => return null,
                    .none => continue,
                };
                if (percentage) |p| {
                    if (p != is_percentage) return null;
                } else {
                    percentage = is_percentage;
                }
            }
            // Kept on the 0..255 scale a number is already written on: taking
            // it to 0..1 and back moves the halfway cases a byte.
            var out: [3]f64 = undefined;
            for (components, 0..) |channel, at| {
                out[at] = switch (channel) {
                    .number => |n| n,
                    .percentage => |p| p / 100.0 * 255.0,
                    else => 0,
                };
            }
            break :blk out;
        },
        .hsl, .hwb => blk: {
            const hue = switch (components[0]) {
                .number => |n| n,
                .angle => |a| a,
                .none => 0,
                .percentage => return null,
            };
            // Measured: the other two are percentages. A bare number there is
            // left to the author -- no measurement says what Chrome answers.
            var pair: [2]f64 = undefined;
            for (components[1..3], 0..) |channel, at| {
                pair[at] = switch (channel) {
                    .percentage => |p| std.math.clamp(p / 100.0, 0, 1),
                    .none => 0,
                    else => return null,
                };
            }
            const unit = if (kind == .hsl)
                color.hslToRgb(hue, pair[0], pair[1])
            else
                color.hwbToRgb(hue, pair[0], pair[1]);
            break :blk .{ unit[0] * 255.0, unit[1] * 255.0, unit[2] * 255.0 };
        },
    };

    var colour: Colour = .{ .rgb = undefined, .alpha = alpha };
    for (rgb, 0..) |channel, at| {
        colour.rgb[at] = colourByte(channel);
    }
    return .{ .value = colour, .end = end };
}

fn parseChannel(text: []const u8) ?Channel {
    if (std.ascii.eqlIgnoreCase(text, "none")) {
        return .none;
    }
    if (std.mem.endsWith(u8, text, "%")) {
        const n = std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch return null;
        return .{ .percentage = n };
    }
    // A hue takes any angle unit; the factors are the exact ones, since a
    // rounded pi would move the answer a byte.
    const angle_units = [_]struct { []const u8, f64 }{
        .{ "deg", 1 },
        .{ "grad", 0.9 },
        .{ "rad", 180.0 / std.math.pi },
        .{ "turn", 360 },
    };
    for (angle_units) |unit| {
        if (text.len > unit[0].len and std.ascii.endsWithIgnoreCase(text, unit[0])) {
            const n = std.fmt.parseFloat(f64, text[0 .. text.len - unit[0].len]) catch return null;
            return .{ .angle = n * unit[1] };
        }
    }
    const n = std.fmt.parseFloat(f64, text) catch return null;
    return .{ .number = n };
}

/// A channel already on the 0..255 scale as the byte Chrome answers: rounded
/// half away from zero, which is what makes `rgb(2.5)` a 3 and `50%` a 128.
fn colourByte(channel: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(channel), 0, 255));
}

fn alphaByte(channel: Channel) ?u8 {
    const alpha: f64 = switch (channel) {
        .number => |n| n,
        .percentage => |p| p / 100.0,
        .none => 0,
        .angle => return null,
    };
    return colourByte(std.math.clamp(alpha, 0, 1) * 255.0);
}

/// `currentcolor` written out by an author means the element's own computed
/// `color`, and a computed style reports that rather than the keyword. Any other
/// value comes back untouched.
///
/// `color` is never itself one of these -- it is the source, not a follower --
/// so the recursion is one level deep.
fn resolveCurrentColour(self: *const CSSStyleDeclaration, value: []const u8, frame: *Frame, surface: Surface) []const u8 {
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, &std.ascii.whitespace), "currentcolor")) {
        return value;
    }
    return self.propertyValue("color", frame, surface);
}

/// The `rgb()` a computed style reports for a value written as a colour
/// keyword, or null when the value is not one.
///
/// A *specified* value keeps the keyword -- `el.style.color` answers `red` on
/// Chrome 151 -- so this is not part of canonicaliseValue, which is what
/// storeProperty runs. A *computed* colour is always a function there:
/// `getComputedStyle(el).color === 'red'` is one expression no browser can
/// produce, and this engine produced it for every keyword a page wrote.
///
/// The `any_identifier` gate is the reason this can look at the value rather
/// than needing a list of which longhands are colours: it is the measured set of
/// properties whose value may be an author's own name, and `font-family: red`
/// is a family called red, not a colour. Everything outside that set that
/// spells a colour keyword means the colour.
fn computedColourText(arena: Allocator, property_name: []const u8, value: []const u8) ?[]const u8 {
    if (chrome_keywords.any_identifier.has(property_name)) return null;
    if (!takesColour(property_name)) return null;

    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed.len > 32) return null;
    // A function or a hash was already folded by canonicaliseValue; what
    // reaches here as a colour is a bare keyword.
    if (std.mem.indexOfAny(u8, trimmed, "(#, \t") != null) return null;

    const rgba = color.RGBA.parse(trimmed) catch blk: {
        // A system colour is a keyword `RGBA.parse` does not know, and it is a
        // colour all the same: `color: buttonface` computes to `rgb(239, 239,
        // 239)` in Chrome. canonicaliseValue has already lowercased it, but the
        // lowering here is what makes that an optimisation rather than a
        // premise.
        var lower: [32]u8 = undefined;
        break :blk color.systemColor(std.ascii.lowerString(lower[0..trimmed.len], trimmed)) orelse return null;
    };

    var buf = std.Io.Writer.Allocating.init(arena);
    writeColour(&buf.writer, .{ .rgb = .{ rgba.r, rgba.g, rgba.b }, .alpha = rgba.a }) catch return null;
    return buf.written();
}

/// Whether the property takes a `<color>` at all, which is what makes folding a
/// bare keyword to `rgb()` the right thing to do to it.
///
/// The `any_identifier` gate above is not enough on its own. It keeps
/// `font-family: red` a family called red, but plenty of properties outside it
/// take a keyword that happens to spell a colour -- the system colours are
/// words like `menu`, `caption`, `field`, `window`, `mark` and `background`,
/// and `font` takes six of them. Folding there made
/// `getComputedStyle(el).font` answer `rgb(255, 255, 255)` for `font: menu`,
/// which is further from Chrome's `16px Arial` than the keyword it replaced.
/// Kasada writes all six at x-hyatt, one per system font keyword, so it is not
/// a corner either.
///
/// `currentcolor` is the discriminator and an exact one: all sixty
/// colour-valued properties in the measured keyword tables list it, and no
/// other property does.
fn takesColour(property_name: []const u8) bool {
    const known = chrome_keywords.keywords.get(property_name) orelse return false;
    for (known) |keyword| {
        if (std.mem.eql(u8, keyword, "currentcolor")) return true;
    }
    return false;
}

fn writeColour(writer: *std.Io.Writer, colour: Colour) !void {
    const rgb = colour.rgb;
    if (colour.alpha == 255) {
        return writer.print("rgb({d}, {d}, {d})", .{ rgb[0], rgb[1], rgb[2] });
    }
    try writer.print("rgba({d}, {d}, {d}, ", .{ rgb[0], rgb[1], rgb[2] });
    try color.writeAlpha(writer, colour.alpha);
    try writer.writeByte(')');
}

// Canonicalize anchor-size() so that the dashed ident (anchor name) comes before the size keyword.
// e.g. "anchor-size(width --foo)" -> "anchor-size(--foo width)"
fn canonicalizeAnchorSize(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor-size(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
            try buf.writer.writeAll("anchor-size(");
            i += "anchor-size(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor_size);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

const AnchorFnKind = enum { anchor, anchor_size };

// Parse anchor/anchor-size arguments and write them in canonical order
fn canonicalizeAnchorFnArgs(value: []const u8, start: usize, writer: *std.Io.Writer, kind: AnchorFnKind) !usize {
    var i = start;
    var depth: usize = 1;

    // Skip leading whitespace
    while (i < value.len and value[i] == ' ') : (i += 1) {}

    var token_count: usize = 0;
    var comma_pos: ?usize = null;

    var first_token_end: usize = 0;
    var first_token_start: ?usize = null;

    var second_token_end: usize = 0;
    var second_token_start: ?usize = null;

    const args_start = i;
    var in_token = false;

    // First pass: find the structure of arguments before comma/closing paren at depth 1
    while (i < value.len and depth > 0) {
        const c = value[i];

        if (c == '(') {
            depth += 1;
            in_token = true;
            i += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                if (in_token) {
                    if (token_count == 0) {
                        first_token_end = i;
                    } else if (token_count == 1) {
                        second_token_end = i;
                    }
                }
                break;
            }
            i += 1;
        } else if (c == ',' and depth == 1) {
            if (in_token) {
                if (token_count == 0) {
                    first_token_end = i;
                } else if (token_count == 1) {
                    second_token_end = i;
                }
            }
            comma_pos = i;
            break;
        } else if (c == ' ') {
            if (in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_end = i;
                    token_count = 1;
                } else if (token_count == 1 and second_token_start != null) {
                    second_token_end = i;
                    token_count = 2;
                }
                in_token = false;
            }
            i += 1;
        } else {
            if (!in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_start = i;
                } else if (token_count == 1) {
                    second_token_start = i;
                }
                in_token = true;
            }
            i += 1;
        }
    }

    // Handle end of tokens
    if (in_token and token_count == 1 and second_token_start != null) {
        second_token_end = i;
        token_count = 2;
    } else if (in_token and token_count == 0) {
        first_token_end = i;
        token_count = 1;
    }

    // Check if we have exactly two tokens that need reordering
    if (token_count == 2) {
        const first_start = first_token_start orelse args_start;
        const second_start = second_token_start orelse first_token_end;

        const first_token = value[first_start..first_token_end];
        const second_token = value[second_start..second_token_end];

        // If second token is a dashed ident, it should come first
        // For anchor-size, also check that first token is a size keyword
        const should_swap = std.mem.startsWith(u8, second_token, "--") and
            (kind == .anchor or isAnchorSizeKeyword(first_token));

        if (should_swap) {
            try writer.writeAll(second_token);
            try writer.writeByte(' ');
            try writer.writeAll(first_token);
        } else {
            try writer.writeAll(first_token);
            try writer.writeByte(' ');
            try writer.writeAll(second_token);
        }
    } else if (first_token_start) |fts| {
        // Single token, just copy it
        try writer.writeAll(value[fts..first_token_end]);
    }

    // Handle comma and fallback value (may contain nested functions)
    if (comma_pos) |cp| {
        try writer.writeAll(", ");
        i = cp + 1;
        // Skip whitespace after comma
        while (i < value.len and value[i] == ' ') : (i += 1) {}

        // Copy the fallback, recursively handling nested anchor/anchor-size
        while (i < value.len and depth > 0) {
            if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
                try writer.writeAll("anchor-size(");
                i += "anchor-size(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor_size);
                depth -= 1;
            } else if (std.mem.startsWith(u8, value[i..], "anchor(")) {
                try writer.writeAll("anchor(");
                i += "anchor(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor);
                depth -= 1;
            } else if (value[i] == '(') {
                depth += 1;
                try writer.writeByte(value[i]);
                i += 1;
            } else if (value[i] == ')') {
                depth -= 1;
                if (depth == 0) break;
                try writer.writeByte(value[i]);
                i += 1;
            } else {
                try writer.writeByte(value[i]);
                i += 1;
            }
        }
    }

    // Write closing paren
    try writer.writeByte(')');

    return i + 1; // Skip past the closing paren
}

fn isAnchorSizeKeyword(token: []const u8) bool {
    const keywords = std.StaticStringMap(void).initComptime(.{
        .{ "width", {} },
        .{ "height", {} },
        .{ "block", {} },
        .{ "inline", {} },
        .{ "self-block", {} },
        .{ "self-inline", {} },
    });
    return keywords.has(token);
}

// Canonicalize anchor() so that the dashed ident (anchor name) comes before the position keyword.
// e.g. "anchor(left --foo)" -> "anchor(--foo left)"
fn canonicalizeAnchor(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor(" but not "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor(") and (i == 0 or value[i - 1] != '-')) {
            try buf.writer.writeAll("anchor(");
            i += "anchor(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

/// Shorten every comma-separated layer of a value by `rule`, or null when no
/// layer had anything to shorten -- Chrome runs these per layer, so
/// `background-repeat: repeat, repeat no-repeat` answers `repeat, repeat-x`.
fn shortenPairs(arena: Allocator, rule: TwoValueRule, value: []const u8) !?[]const u8 {
    var written: std.ArrayList([]const u8) = .empty;
    defer written.deinit(arena);

    var changed = false;
    var layers = shorthand.Layers.init(value);
    while (layers.next()) |layer| {
        const trimmed = std.mem.trim(u8, layer, &std.ascii.whitespace);
        if (try shortenPair(arena, rule, trimmed)) |shorter| {
            changed = true;
            try written.append(arena, shorter);
        } else {
            try written.append(arena, trimmed);
        }
    }
    if (!changed) return null;
    return try std.mem.join(arena, ", ", written.items);
}

/// One layer under one rule, or null when the layer is already as short as
/// Chrome writes it. A layer of more components than the rule knows about is
/// left alone rather than guessed at.
fn shortenPair(arena: Allocator, rule: TwoValueRule, layer: []const u8) !?[]const u8 {
    var parts: [2][]const u8 = undefined;
    var count: usize = 0;
    var walk = shorthand.Components.init(layer);
    while (walk.next()) |component| {
        if (count == parts.len) return null;
        parts[count] = component;
        count += 1;
    }
    if (count == 0 or !walk.exhausted()) return null;

    switch (rule) {
        .fold => {
            if (count != 2 or !std.mem.eql(u8, parts[0], parts[1])) return null;
            return parts[0];
        },
        .repeat => {
            if (count != 2) return null;
            // The two pairs that name an axis have a keyword of their own.
            if (std.mem.eql(u8, parts[0], "repeat") and std.mem.eql(u8, parts[1], "no-repeat")) {
                return "repeat-x";
            }
            if (std.mem.eql(u8, parts[0], "no-repeat") and std.mem.eql(u8, parts[1], "repeat")) {
                return "repeat-y";
            }
            if (!std.mem.eql(u8, parts[0], parts[1])) return null;
            return parts[0];
        },
        .size => {
            var shortened = false;
            // Both halves are lengths, and a bare `0` takes its unit in
            // either -- the whole-value rule above only reaches a lone one.
            for (parts[0..count]) |*part| {
                if (!std.mem.eql(u8, part.*, "0")) continue;
                part.* = "0px";
                shortened = true;
            }
            // A trailing `auto` is the half a one-value size would have
            // implied, so Chrome drops it. An equal pair is not a fold here:
            // `10px 10px` stays two values.
            var kept = count;
            if (count == 2 and std.mem.eql(u8, parts[1], "auto")) {
                kept = 1;
                shortened = true;
            }
            if (!shortened) return null;
            return try std.mem.join(arena, " ", parts[0..kept]);
        },
        .radius => {
            var shortened = false;
            // Both halves are a length or a percentage, so a bare `0` takes
            // its unit in either -- the whole-value rule above only reaches a
            // lone one, and only for the spellings isLengthProperty lists.
            for (parts[0..count]) |*part| {
                if (!std.mem.eql(u8, part.*, "0")) continue;
                part.* = "0px";
                shortened = true;
            }
            // And then it folds, on the units the zero rule just filled in:
            // `0 0` is `0px`, not `0px 0px`.
            if (count == 2 and std.mem.eql(u8, parts[0], parts[1])) {
                return parts[0];
            }
            if (!shortened) return null;
            return try std.mem.join(arena, " ", parts[0..count]);
        },
    }
}

/// The count a counter property gives a name written without one. Measured:
/// `counter-increment: c` answers `c 1` and `counter-reset: c` / `counter-set: c`
/// answer `c 0`, per name rather than per declaration (`counter-reset: a b c`
/// answers `a 0 b 0 c 0`).
fn counterDefault(property_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, property_name, "counter-increment")) return "1";
    if (std.mem.eql(u8, property_name, "counter-reset")) return "0";
    if (std.mem.eql(u8, property_name, "counter-set")) return "0";
    return null;
}

/// Rewrite a counter list with every name's count filled in. `none` is the whole
/// value rather than a counter name, so it comes through untouched.
fn writeCounters(arena: Allocator, value: []const u8, default: []const u8) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);
    errdefer buf.deinit();
    var changed = false;
    var tokens = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
    var pending: ?[]const u8 = null;
    while (tokens.next()) |token| {
        const is_number = numberEnd(token, 0) == token.len;
        if (pending) |name| {
            if (buf.written().len != 0) try buf.writer.writeByte(' ');
            try buf.writer.print("{s} ", .{name});
            if (is_number) {
                try buf.writer.writeAll(token);
                pending = null;
                continue;
            }
            try buf.writer.writeAll(default);
            changed = true;
            pending = token;
            continue;
        }
        if (is_number) {
            // A count with no name before it is not a shape Chrome accepts; keep
            // the value as written rather than invent a name for it.
            buf.deinit();
            return value;
        }
        pending = token;
    }
    if (pending) |name| {
        if (std.ascii.eqlIgnoreCase(name, "none") and buf.written().len == 0) {
            buf.deinit();
            return value;
        }
        if (buf.written().len != 0) try buf.writer.writeByte(' ');
        try buf.writer.print("{s} {s}", .{ name, default });
        changed = true;
    }
    if (!changed) {
        buf.deinit();
        return value;
    }
    return buf.written();
}

/// How Chrome shortens a property written as a pair. Measured by
/// tools/fingerprint/probes/probe-css15.js and probe-css16.js -- four rules,
/// not one, and the difference between them is only visible on the values
/// where they disagree.
const TwoValueRule = enum {
    /// An equal pair becomes one value and an unequal pair stays two:
    /// `gap: 10px 10px` is `10px`, `gap: 10px 20px` is itself. What every
    /// two-value property but a size and a repeat does.
    fold,
    /// A trailing `auto` goes -- `10px auto` is `10px`, `auto auto` is `auto`
    /// -- and an equal pair does *not* fold: `background-size: 10px 10px`
    /// stays two values, which is where a plain fold gets it wrong.
    size,
    /// A fold, plus the rename an axis keyword gives the two pairs that spell
    /// it: `repeat no-repeat` is `repeat-x` and `no-repeat repeat` is
    /// `repeat-y`. Every other mixed pair (`space round`, `repeat space`)
    /// stays a pair.
    repeat,
    /// A fold, plus the zero rule a size takes: both halves are a length or a
    /// percentage, so `10px 0` is `10px 0px` and `0 0` is `0px` -- a fold on
    /// the unit the zero rule just filled in, which neither a plain fold nor a
    /// size reaches. What the eight corner radius longhands do.
    radius,
};

/// The rule a property takes, or null for one Chrome leaves as written.
///
/// Most of the `.fold` names are shorthands, which reach this only when the
/// shorthand table declines their value -- `storeProperty` expands the ones it
/// models and canonicalises the longhands instead. They are listed anyway,
/// because the fallback path should not answer differently from the modelled
/// one.
///
/// The `-webkit-` spellings of mask are not here: `-webkit-mask-size` and
/// `-webkit-mask-repeat` are stored under the unprefixed name, so they arrive
/// already renamed. `-webkit-mask-box-image-repeat` keeps its own name and so
/// needs its own entry.
fn twoValueRule(name: []const u8) ?TwoValueRule {
    const rules = std.StaticStringMap(TwoValueRule).initComptime(.{
        .{ "place-content", .fold },
        .{ "place-items", .fold },
        .{ "place-self", .fold },
        .{ "margin-block", .fold },
        .{ "margin-inline", .fold },
        .{ "padding-block", .fold },
        .{ "padding-inline", .fold },
        .{ "inset-block", .fold },
        .{ "inset-inline", .fold },
        .{ "border-block-style", .fold },
        .{ "border-inline-style", .fold },
        .{ "border-block-width", .fold },
        .{ "border-inline-width", .fold },
        .{ "border-block-color", .fold },
        .{ "border-inline-color", .fold },
        .{ "overflow", .fold },
        .{ "overscroll-behavior", .fold },
        .{ "gap", .fold },
        .{ "grid-gap", .fold },
        // Scroll
        .{ "scroll-padding-block", .fold },
        .{ "scroll-padding-inline", .fold },
        .{ "scroll-snap-align", .fold },
        // Background/Mask
        .{ "background-size", .size },
        .{ "mask-size", .size },
        .{ "background-repeat", .repeat },
        .{ "mask-repeat", .repeat },
        .{ "border-image-repeat", .fold },
        .{ "-webkit-mask-box-image-repeat", .fold },
        // A corner radius, in both spellings of every corner. These are
        // longhands rather than shorthands: the `/` belongs to `border-radius`
        // and a corner rejects one.
        .{ "border-top-left-radius", .radius },
        .{ "border-top-right-radius", .radius },
        .{ "border-bottom-right-radius", .radius },
        .{ "border-bottom-left-radius", .radius },
        .{ "border-start-start-radius", .radius },
        .{ "border-start-end-radius", .radius },
        .{ "border-end-start-radius", .radius },
        .{ "border-end-end-radius", .radius },
    });
    return rules.get(name);
}

/// Whether the declaration holds more than the property takes. Two counts over
/// the same components: the two-value rule above, and `chrome_arity`, which is
/// the wider of them -- 461 measured property names that take no second
/// component at all, so `margin-top: 1px 2px` and `width: 1px / 2px` are both
/// thrown away where every other test in this engine passes them (each half is
/// a `<length>` `margin-top` takes).
///
/// A comma is a list and the count runs per item, which leaves the comma itself
/// to answer for: a property measured never to take one is refused the whole
/// value. That is what separates `transition-duration: 1s, 2s` -- kept, two
/// items of one -- from `margin-top: 1px,2px`.
///
/// Nothing here counts a value it cannot see whole. A `var()` stands in for
/// text this engine does not have, and Chrome keeps `margin-top: var(--a)
/// var(--b)` and resolves it later. A comment is taken out before Chrome's own
/// count -- `margin-top: 10px /* c */` reads back `10px` -- and nothing here
/// removes one, so its components would come back as punctuation.
fn tooManyComponents(name: []const u8, value: []const u8) bool {
    if (std.mem.indexOf(u8, value, "/*") != null) return false;
    if (std.ascii.indexOfIgnoreCase(value, "var(") != null) return false;

    // A `<transform-list>` is one value however many functions it holds. The
    // arity sweep that built the table never offered `transform` two of them --
    // only identifier and generic-value pairs -- so it reads as one-component,
    // and `rotate(0deg) scale(1)` was thrown away as a declaration holding too
    // much. That is a style the page loses, not only a serialisation
    // difference. Measured (expr-transform-serialize.js): Chrome keeps a list
    // of calls and refuses one with anything else in it, which is what the
    // count below still answers -- `rotate(45deg) 5px` is not exempted here.
    if (std.mem.eql(u8, name, "transform") and isTransformList(value)) {
        return false;
    }

    const holds: usize = if (chrome_arity.one_component.has(name))
        1
    else if (twoValueRule(name) != null)
        2
    else
        return false;

    var items = shorthand.Layers.init(value);
    var seen: usize = 0;
    while (items.next()) |list_item| {
        seen += 1;
        if (seen > 1 and !chrome_arity.comma_lists.has(name)) return true;
        var components = shorthand.slashComponents(list_item);
        var count: usize = 0;
        while (components.next()) |_| count += 1;
        if (count > holds) return true;
    }
    return false;
}

/// Whether every top-level component of the value is a function call, which is
/// what makes a `transform` a list rather than a declaration holding too much.
/// Two or more: a single call was never in question, and answering true for one
/// would exempt `transform: 5px` from the count as well.
fn isTransformList(value: []const u8) bool {
    var walk = shorthand.Components.init(value);
    var count: usize = 0;
    while (walk.next()) |part| {
        if (part.len == 0 or part[part.len - 1] != ')') return false;
        if (std.mem.indexOfScalar(u8, part, '(') == null) return false;
        count += 1;
    }
    return !walk.stopped and count > 1;
}

fn isLengthProperty(name: []const u8) bool {
    // Properties that accept <length> or <length-percentage> values
    const length_properties = std.StaticStringMap(void).initComptime(.{
        // Sizing
        .{ "width", {} },
        .{ "height", {} },
        .{ "min-width", {} },
        .{ "min-height", {} },
        .{ "max-width", {} },
        .{ "max-height", {} },
        // Margins
        .{ "margin", {} },
        .{ "margin-top", {} },
        .{ "margin-right", {} },
        .{ "margin-bottom", {} },
        .{ "margin-left", {} },
        .{ "margin-block", {} },
        .{ "margin-block-start", {} },
        .{ "margin-block-end", {} },
        .{ "margin-inline", {} },
        .{ "margin-inline-start", {} },
        .{ "margin-inline-end", {} },
        // Padding
        .{ "padding", {} },
        .{ "padding-top", {} },
        .{ "padding-right", {} },
        .{ "padding-bottom", {} },
        .{ "padding-left", {} },
        .{ "padding-block", {} },
        .{ "padding-block-start", {} },
        .{ "padding-block-end", {} },
        .{ "padding-inline", {} },
        .{ "padding-inline-start", {} },
        .{ "padding-inline-end", {} },
        // Positioning
        .{ "top", {} },
        .{ "right", {} },
        .{ "bottom", {} },
        .{ "left", {} },
        .{ "inset", {} },
        .{ "inset-block", {} },
        .{ "inset-block-start", {} },
        .{ "inset-block-end", {} },
        .{ "inset-inline", {} },
        .{ "inset-inline-start", {} },
        .{ "inset-inline-end", {} },
        // Border
        .{ "border-width", {} },
        .{ "border-top-width", {} },
        .{ "border-right-width", {} },
        .{ "border-bottom-width", {} },
        .{ "border-left-width", {} },
        .{ "border-block-width", {} },
        .{ "border-block-start-width", {} },
        .{ "border-block-end-width", {} },
        .{ "border-inline-width", {} },
        .{ "border-inline-start-width", {} },
        .{ "border-inline-end-width", {} },
        .{ "border-radius", {} },
        .{ "border-top-left-radius", {} },
        .{ "border-top-right-radius", {} },
        .{ "border-bottom-left-radius", {} },
        .{ "border-bottom-right-radius", {} },
        // Text
        .{ "font-size", {} },
        .{ "letter-spacing", {} },
        .{ "word-spacing", {} },
        .{ "text-indent", {} },
        // Flexbox/Grid
        .{ "gap", {} },
        .{ "row-gap", {} },
        .{ "column-gap", {} },
        .{ "flex-basis", {} },
        // Legacy grid aliases
        .{ "grid-column-gap", {} },
        .{ "grid-row-gap", {} },
        // Outline
        .{ "outline", {} },
        .{ "outline-width", {} },
        .{ "outline-offset", {} },
        // Multi-column
        .{ "column-rule-width", {} },
        .{ "column-width", {} },
        // Scroll
        .{ "scroll-margin", {} },
        .{ "scroll-margin-top", {} },
        .{ "scroll-margin-right", {} },
        .{ "scroll-margin-bottom", {} },
        .{ "scroll-margin-left", {} },
        .{ "scroll-padding", {} },
        .{ "scroll-padding-top", {} },
        .{ "scroll-padding-right", {} },
        .{ "scroll-padding-bottom", {} },
        .{ "scroll-padding-left", {} },
        // Shapes
        .{ "shape-margin", {} },
        // Motion path
        .{ "offset-distance", {} },
        // Transforms
        .{ "translate", {} },
        // Animations
        .{ "animation-range-end", {} },
        .{ "animation-range-start", {} },
        // Other
        .{ "border-spacing", {} },
        .{ "text-shadow", {} },
        .{ "box-shadow", {} },
        .{ "baseline-shift", {} },
        .{ "vertical-align", {} },
        .{ "text-decoration-inset", {} },
        .{ "block-step-size", {} },
        // Grid lanes
        .{ "flow-tolerance", {} },
        .{ "column-rule-edge-inset", {} },
        .{ "column-rule-interior-inset", {} },
        .{ "row-rule-edge-inset", {} },
        .{ "row-rule-interior-inset", {} },
        .{ "rule-edge-inset", {} },
        .{ "rule-interior-inset", {} },
        // Every remaining property this list was missing, from the shorthand
        // probe: these are the longhands where Chrome was measured storing a
        // bare `0` as `0px` (tools/fingerprint/dump-css-shorthands.mjs writes
        // one token per class to each of them). `background: 0` reaching
        // background-position-x is what turned them up.
        .{ "-webkit-border-horizontal-spacing", {} },
        .{ "-webkit-border-vertical-spacing", {} },
        .{ "-webkit-mask-position-x", {} },
        .{ "-webkit-mask-position-y", {} },
        .{ "-webkit-text-stroke-width", {} },
        .{ "background-position-x", {} },
        .{ "background-position-y", {} },
        .{ "background-size", {} },
        .{ "block-size", {} },
        .{ "column-height", {} },
        .{ "column-rule-inset-cap-end", {} },
        .{ "column-rule-inset-cap-start", {} },
        .{ "column-rule-inset-junction-end", {} },
        .{ "column-rule-inset-junction-start", {} },
        .{ "contain-intrinsic-height", {} },
        .{ "contain-intrinsic-width", {} },
        .{ "grid-auto-columns", {} },
        .{ "grid-auto-rows", {} },
        .{ "grid-template-columns", {} },
        .{ "grid-template-rows", {} },
        .{ "inline-size", {} },
        .{ "mask-size", {} },
        .{ "max-block-size", {} },
        .{ "max-inline-size", {} },
        .{ "min-block-size", {} },
        .{ "min-inline-size", {} },
        .{ "perspective", {} },
        .{ "row-rule-inset-cap-end", {} },
        .{ "row-rule-inset-cap-start", {} },
        .{ "row-rule-inset-junction-end", {} },
        .{ "row-rule-inset-junction-start", {} },
        .{ "row-rule-width", {} },
        .{ "scroll-margin-block-end", {} },
        .{ "scroll-margin-block-start", {} },
        .{ "scroll-margin-inline-end", {} },
        .{ "scroll-margin-inline-start", {} },
        .{ "scroll-padding-block-end", {} },
        .{ "scroll-padding-block-start", {} },
        .{ "scroll-padding-inline-end", {} },
        .{ "scroll-padding-inline-start", {} },
        .{ "text-decoration-thickness", {} },
        .{ "timeline-trigger-activation-range-end", {} },
        .{ "timeline-trigger-activation-range-start", {} },
        .{ "timeline-trigger-active-range-end", {} },
        .{ "timeline-trigger-active-range-start", {} },
        .{ "view-timeline-inset", {} },
    });

    return length_properties.has(name);
}

fn getDefaultPropertyValue(self: *const CSSStyleDeclaration, name: String, surface: Surface) []const u8 {
    // The UA stylesheet first, because it is what a browser cascades ahead of
    // the property's initial value and it is per-tag where the flat table is
    // not: <body> takes `margin: 8px`, <pre> a monospace 13px font, <hr> a grey
    // inset border, and the flat table would answer a div's value for all of
    // them. An element whose tag the UA sheet says nothing about is not a div
    // either -- a div carries UA rules of its own -- so a miss falls to the
    // recorded unknown-tag row rather than straight through.
    if (self._element) |element| {
        // Per TYPE before per tag for an <input>, the same order uaValue uses.
        // Both lookups have to agree: the layout reads uaValue and this is what
        // getComputedStyle reports, and when only the first knew about types a
        // `submit` laid out on the button's 6px of padding while reporting the
        // text field's 2px.
        if (element.inputTypeForBox()) |input_type| {
            if (chrome_input_type_values.get(input_type, name.str())) |value| return value;
        }
        const rows = chrome_per_tag_values.per_tag.get(element.getTagNameLower()) orelse
            chrome_per_tag_values.unknown_tag;
        if (rows.get(name.str())) |value| {
            return value;
        }
    }

    switch (name.len) {
        5 => {
            if (name.eql(comptime .wrap("color"))) {
                const element = self._element orelse return "";
                return getDefaultColor(element);
            }
        },
        7 => {
            if (name.eql(comptime .wrap("opacity"))) {
                return "1";
            }
            if (name.eql(comptime .wrap("display"))) {
                const element = self._element orelse return "";
                return getDefaultDisplay(element);
            }
            if (name.eql(comptime .wrap("z-index"))) {
                return "auto";
            }
        },
        9 => {
            if (name.eqlSlice("flex-grow")) {
                return "0";
            }
        },
        10 => {
            if (name.eql(comptime .wrap("visibility"))) {
                return "visible";
            }
        },
        11 => {
            if (name.eqlSlice("line-height")) {
                return "normal";
            }
            // The serif this engine's font metrics already model as the default
            // family (font_metrics.zig maps "Times" onto its serif table), which
            // is also what Chrome reports on the platform this build claims.
            if (name.eqlSlice("font-family")) {
                return "Times";
            }
        },
        16 => {
            if (name.eqlSlice("background-color")) {
                // transparent
                return "rgba(0, 0, 0, 0)";
            }
            if (name.eqlSlice("border-top-width")) {
                return borderWidth(surface);
            }
        },
        17 => {
            if (name.eqlSlice("border-left-width")) {
                return borderWidth(surface);
            }
        },
        18 => {
            if (name.eqlSlice("border-right-width")) {
                return borderWidth(surface);
            }
        },
        19 => {
            if (name.eqlSlice("transition-duration")) {
                return "0s";
            }
            if (name.eqlSlice("border-bottom-width")) {
                return borderWidth(surface);
            }
        },
        else => {},
    }
    // Everything the cases above do not special-case comes from the recorded
    // table. They are ahead of it because they are the ones that depend on the
    // element rather than only on the property: `color` and `display` differ per
    // tag, and `border-*-width` differs per surface.
    //
    // "" was the old answer for every other longhand, and it is not a value
    // Chrome computes for one — a widget that dumps getComputedStyle over the
    // whole enumeration reads 720 empties here against Chrome's 34, which is the
    // gap this table closes (README, "Reading the same two files record by
    // record"). The six that resolve against the box are answered by the layout
    // path before this point and deliberately have no entry.
    return chrome_initial_values.initial.get(name.str()) orelse "";
}

/// The one initial value measured to differ between the two surfaces: the
/// initial `border-width: medium` computes to 3px, and the CSS Typed OM reports
/// that, while getComputedStyle reports the used width, which `border-style:
/// none` collapses to 0px. Chrome 151 on a div with no border answers `3px` from
/// `computedStyleMap().get('border-top-width')` and `0px` from
/// `getComputedStyle().borderTopWidth`.
///
/// Only the Typed OM still reaches this: the used surface resolves the whole
/// question in `computedBorderWidth`, which reads the cascaded border-style and
/// answers `medium` as 3px when a border is actually drawn.
fn borderWidth(surface: Surface) []const u8 {
    return switch (surface) {
        .used => "0px",
        .computed => "3px",
    };
}

/// The UA stylesheet's `display` for an element that declares none.
///
/// Measured tag by tag rather than sorted into three hand-written groups: 46 of
/// 128 tags disagreed with Chrome that way, among them <img>, <input>,
/// <button>, <select>, <textarea>, <iframe>, <canvas>, <video>, <li> and every
/// table tag, and this engine had no way at all to say `table-cell`,
/// `list-item`, `ruby` or `contents`. chrome_default_display.zig is generated by
/// tools/fingerprint/dump-default-display.mjs.
///
/// Three things are asked in order, because two of them outrank the tag: an
/// attribute that switches the tag on (`audio` is `none` until it has
/// `controls`), then the one parent a tag reads differently inside (`summary` is
/// `list-item` in a <details> and `block` loose), then the tag alone.
fn getDefaultDisplay(element: *Element) []const u8 {
    switch (element._type) {
        .html => {},
        // Chrome lays MathML out as inline too (`math` is display: inline
        // math), which is as close as the faux layout gets. An element in a
        // namespace we know nothing about is inline for the same reason.
        .svg, .mathml, .plain => return "inline",
    }

    // The two declarative request elements are not in the generated table:
    // the Chrome the generator drives has no such tags, so it would measure
    // them as unknown and answer `inline`. Their `inline-block` was measured
    // on a headed Chrome 151 that does (surface_elements.html).
    switch (element.subtype(Element.Html)._type) {
        .geolocation, .user_media => return "inline-block",
        else => {},
    }

    const tag = element.getTagNameLower();

    if (chrome_default_display.attributed(tag)) |rule| {
        if (element.hasAttributeSafe(.wrap(rule.attribute))) {
            return rule.display;
        }
    }

    if (chrome_default_display.contextual(tag)) |rule| {
        if (element.parentElement()) |parent| {
            if (std.mem.eql(u8, parent.getTagNameLower(), rule.parent)) {
                return rule.display;
            }
        }
    }

    if (chrome_default_display.lookup(tag)) |display| {
        return display;
    }

    // A tag the table does not name is one no stylesheet mentions, and Chrome
    // gives that an inline box -- measured as `lp-unknown-element`, which is
    // in the table for exactly this reason.
    return "inline";
}

fn getDefaultColor(element: *const Element) []const u8 {
    switch (element._type) {
        .html => {
            return switch (element.subtype(Element.Html)._type) {
                .anchor => "rgb(0, 0, 238)", // blue
                else => "rgb(0, 0, 0)",
            };
        },
        .svg, .mathml, .plain => return "rgb(0, 0, 0)",
    }
}

pub const Property = struct {
    _name: String,
    _value: String,
    _important: bool = false,
    /// The number the author wrote, when the whole declaration was one numeric
    /// token. `_value` is the six-significant-figure print of it and cannot be
    /// parsed back into it -- see specifiedNumber.
    _specified: ?f64 = null,
    _node: std.DoublyLinkedList.Node,

    pub fn fromNodeLink(n: *std.DoublyLinkedList.Node) *Property {
        return @alignCast(@fieldParentPtr("_node", n));
    }

    pub fn format(self: *const Property, writer: *std.Io.Writer) !void {
        try self._name.format(writer);
        try writer.writeAll(": ");
        try self._value.format(writer);

        if (self._important) {
            try writer.writeAll(" !important");
        }
        try writer.writeByte(';');
    }
};

fn camelCaseToDashCase(name: []const u8, buf: []u8) []const u8 {
    if (name.len == 0) {
        return name;
    }

    // Special case: cssFloat -> float
    const lower_name = std.ascii.lowerString(buf, name);
    if (std.mem.eql(u8, lower_name, "cssfloat")) {
        return "float";
    }

    // If already contains dashes, just return lowercased
    if (std.mem.indexOfScalar(u8, name, '-')) |_| {
        return lower_name;
    }

    // Check if this looks like proper camelCase (starts with lowercase)
    // If not (e.g. "COLOR", "BackgroundColor"), just lowercase it
    if (name.len == 0 or !std.ascii.isLower(name[0])) {
        return lower_name;
    }

    // Check for vendor prefixes: webkitTransform -> -webkit-transform
    // Must have uppercase letter after the prefix
    const has_vendor_prefix = blk: {
        if (name.len > 6 and std.mem.startsWith(u8, name, "webkit") and std.ascii.isUpper(name[6])) break :blk true;
        if (name.len > 3 and std.mem.startsWith(u8, name, "moz") and std.ascii.isUpper(name[3])) break :blk true;
        if (name.len > 2 and std.mem.startsWith(u8, name, "ms") and std.ascii.isUpper(name[2])) break :blk true;
        if (name.len > 1 and std.mem.startsWith(u8, name, "o") and std.ascii.isUpper(name[1])) break :blk true;
        break :blk false;
    };

    var write_pos: usize = 0;

    if (has_vendor_prefix) {
        buf[write_pos] = '-';
        write_pos += 1;
    }

    for (name, 0..) |c, i| {
        if (write_pos >= buf.len) {
            return lower_name;
        }

        if (std.ascii.isUpper(c)) {
            const skip_dash = has_vendor_prefix and i < 10 and write_pos == 1;

            if (i > 0 and !skip_dash) {
                if (write_pos >= buf.len) break;
                buf[write_pos] = '-';
                write_pos += 1;
            }
            if (write_pos >= buf.len) break;
            buf[write_pos] = std.ascii.toLower(c);
            write_pos += 1;
        } else {
            buf[write_pos] = c;
            write_pos += 1;
        }
    }

    return buf[0..write_pos];
}

// ---------------------------------------------------------------------------
// Named property access.
//
// Chrome answers every name in chrome_properties.aliases as an own enumerable
// property of the declaration -- 735 of them, the camelCase spelling of each
// supported property plus the shorthands and legacy webkit aliases -- and
// answers undefined to anything else. Membership in that list is the whole
// rule, and it has to be: Chrome reads style.webkitBorderRadius as "" but
// style.webkitNotSet as undefined, and no test on the `webkit` prefix tells
// those two apart.
//
// Dash-case names are not in the list. They arrive only through bracket
// notation (style['-moz-user-select']), where Chrome answers the stored value
// if the page set one and undefined otherwise.
// ---------------------------------------------------------------------------

const method_names = std.StaticStringMap(void).initComptime(.{
    .{ "getPropertyValue", {} },
    .{ "setProperty", {} },
    .{ "removeProperty", {} },
    .{ "getPropertyPriority", {} },
    .{ "item", {} },
    .{ "cssText", {} },
    .{ "length", {} },
    .{ "parentRule", {} },
    .{ "cssFloat", {} },
});

pub fn setNamed(self: *CSSStyleDeclaration, name: []const u8, value: []const u8, frame: *Frame) !void {
    if (method_names.has(name)) {
        return error.NotHandled;
    }
    const dash_case = camelCaseToDashCase(name, &frame.buf);
    try self.setProperty(dash_case, value, null, frame);
}

/// Whether Chrome answers this name at all, under either spelling. `border-block`
/// and `borderBlock` are the same property to a declaration, and the dashed form
/// is how CreepJS recovers the shorthands, so both have to resolve to the one
/// alias list. A prefix Chrome does not support (`-moz-user-select`) is in
/// neither spelling and stays absent.
fn isAliasSpelling(name: []const u8) bool {
    if (chrome_properties.alias_set.has(name)) {
        return true;
    }
    if (std.mem.indexOfScalar(u8, name, '-') == null) {
        return false;
    }
    var buf: [128]u8 = undefined;
    const camel = dashCaseToCamelCase(name, &buf) orelse return false;
    return chrome_properties.alias_set.has(camel);
}

fn dashCaseToCamelCase(name: []const u8, buf: []u8) ?[]const u8 {
    // A leading dash is a vendor prefix: `-webkit-box-align` is `webkitBoxAlign`.
    const body = if (name.len > 0 and name[0] == '-') name[1..] else name;
    if (body.len == 0 or body.len > buf.len) {
        return null;
    }
    var write: usize = 0;
    var upper_next = false;
    for (body) |c| {
        if (c == '-') {
            upper_next = true;
            continue;
        }
        buf[write] = if (upper_next) std.ascii.toUpper(c) else c;
        upper_next = false;
        write += 1;
    }
    return buf[0..write];
}

pub fn getNamed(self: *CSSStyleDeclaration, name: []const u8, frame: *Frame) ![]const u8 {
    if (method_names.has(name)) {
        return error.NotHandled;
    }

    const is_alias = isAliasSpelling(name);
    if (!is_alias and std.mem.indexOfScalar(u8, name, '-') == null) {
        return error.NotHandled;
    }

    const dash_case = camelCaseToDashCase(name, &frame.buf);
    const value = self.getPropertyValue(dash_case, frame);
    if (value.len > 0) {
        return value;
    }
    // A name Chrome knows reads as the empty string when nothing is set; a
    // dash-case name reaching here was never set, so it stays undefined.
    if (is_alias) {
        return "";
    }
    return error.NotHandled;
}

/// The names Object.keys() reports. Numeric indices come from the indexed
/// enumerator instead, so this is the alias list alone.
fn aliasNames(_: *const CSSStyleDeclaration, exec: *const js.Execution) !js.Array {
    var arr = exec.js.local.?.newArray(chrome_properties.aliases.len);
    for (chrome_properties.aliases, 0..) |name, i| {
        _ = try arr.set(@intCast(i), name, .{});
    }
    return arr;
}

fn queryAlias(self: *const CSSStyleDeclaration, name: []const u8, frame: *Frame) !u32 {
    if (method_names.has(name)) {
        return error.NotHandled;
    }
    if (isAliasSpelling(name)) {
        // Chrome's descriptors are plain data properties: writable, enumerable
        // and configurable, so no attribute bits are set.
        return js.v8.None;
    }
    if (std.mem.indexOfScalar(u8, name, '-') != null) {
        const dash_case = camelCaseToDashCase(name, &frame.buf);
        if (self.getPropertyValue(dash_case, frame).len > 0) {
            return js.v8.None;
        }
    }
    return error.NotHandled;
}

fn indexes(self: *const CSSStyleDeclaration, exec: *const js.Execution) !js.Array {
    const len = self.indexedLength();
    var arr = exec.js.local.?.newArray(len);
    for (0..len) |i| {
        _ = try arr.set(@intCast(i), i, .{});
    }
    return arr;
}

fn getAtIndex(self: *const CSSStyleDeclaration, index: u32) ?[]const u8 {
    if (index >= self.indexedLength()) {
        return null;
    }
    return self.indexedItem(index);
}

/// Chrome puts Symbol.iterator on CSSStyleDeclaration.prototype and it walks
/// the indexed half, yielding property names. Unexposed as keys/values/entries
/// because Chrome has none of those here.
pub fn values(self: *CSSStyleDeclaration, exec: *js.Execution) !*ValueIterator {
    return .init(.{ .declaration = self }, exec);
}

const Iterator = struct {
    index: u32 = 0,
    declaration: *CSSStyleDeclaration,

    const Entry = struct { u32, []const u8 };

    pub fn next(self: *Iterator, _: *js.Execution) ?Entry {
        const index = self.index;
        if (index >= self.declaration.indexedLength()) {
            return null;
        }
        self.index = index + 1;
        return .{ index, self.declaration.indexedItem(index) };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const ValueIterator = GenericIterator(Iterator, "1");

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleDeclaration);

    pub const Meta = struct {
        pub const name = "CSSStyleDeclaration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is the prototype's own-property order, and Chrome's is
    // WebIDL's: the attributes first, then the operations alphabetically.
    // Measured off a headed Chrome 150 and asserted in
    // tests/css/declaration_surface.html, so reordering these renames the engine.
    pub const cssText = bridge.accessor(CSSStyleDeclaration.getCssText, CSSStyleDeclaration.setCssText, .{});
    pub const length = bridge.accessor(CSSStyleDeclaration.indexedLength, null, .{});
    pub const parentRule = bridge.accessor(CSSStyleDeclaration.getParentRule, null, .{});
    pub const cssFloat = bridge.accessor(CSSStyleDeclaration.getFloat, CSSStyleDeclaration.setFloat, .{});
    pub const getPropertyPriority = bridge.function(CSSStyleDeclaration.getPropertyPriority, .{});
    pub const getPropertyValue = bridge.function(CSSStyleDeclaration.getPropertyValue, .{});
    pub const item = bridge.function(_item, .{});
    pub const removeProperty = bridge.function(CSSStyleDeclaration.removeProperty, .{});
    pub const setProperty = bridge.function(CSSStyleDeclaration.setProperty, .{});
    pub const symbol_iterator = bridge.iterator(CSSStyleDeclaration.values, .{});

    fn _item(self: *const CSSStyleDeclaration, index: i32) []const u8 {
        if (index < 0) {
            return "";
        }
        return self.indexedItem(@intCast(index));
    }

    // The indexed half is the property list -- Chrome's 474 computed longhands
    // for a computed view, whatever is set for an inline one -- and the named
    // half is the 735 aliases. Both need their enumerator: Object.keys() is what
    // fingerprinting scripts read, and it is empty without them.
    pub const @"[int]" = bridge.indexed(getAtIndex, indexes, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(
        CSSStyleDeclaration.getNamed,
        CSSStyleDeclaration.setNamed,
        null,
        aliasNames,
        queryAlias,
        .{},
    );
};

const testing = @import("../../../testing.zig");
test "normalizePropertyValue: unitless zero to 0px" {
    const cases = .{
        .{ "width", "0", "0px" },
        .{ "height", "0", "0px" },
        .{ "scroll-margin-top", "0", "0px" },
        .{ "scroll-padding-bottom", "0", "0px" },
        .{ "column-width", "0", "0px" },
        .{ "column-rule-width", "0", "0px" },
        .{ "outline", "0", "0px" },
        .{ "shape-margin", "0", "0px" },
        .{ "offset-distance", "0", "0px" },
        .{ "translate", "0", "0px" },
        .{ "grid-column-gap", "0", "0px" },
        .{ "grid-row-gap", "0", "0px" },
        // Non-length properties should NOT normalize
        .{ "opacity", "0", "0" },
        .{ "z-index", "0", "0" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

// Measured with tools/fingerprint/probes/expr-shadow-serialize.js: Chrome
// writes a shadow layer as `[colour] <lengths, as written> [inset]`, however
// the author ordered them. The lengths keep their count -- an omitted blur is
// not filled in -- but a unitless zero among them becomes `0px`, which the
// whole-value rule above never reaches inside a list.
test "normalizePropertyValue: a shadow layer is colour, lengths, inset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = .{
        // The colour moves to the front from wherever it was written.
        .{ "box-shadow", "1px 2px red", "red 1px 2px" },
        .{ "box-shadow", "1px 2px 3px 4px red", "red 1px 2px 3px 4px" },
        // Already in Chrome's order: unchanged.
        .{ "box-shadow", "red 1px 2px", "red 1px 2px" },
        // `inset` moves to the end, from either side.
        .{ "box-shadow", "inset 1px 2px red", "red 1px 2px inset" },
        .{ "box-shadow", "1px 2px red inset", "red 1px 2px inset" },
        .{ "box-shadow", "red inset 1px 2px", "red 1px 2px inset" },
        // Keywords are lowercased, the colour folds to rgb().
        .{ "box-shadow", "INSET 1px 2px RED", "red 1px 2px inset" },
        .{ "box-shadow", "inset 0 0 0 #228b49", "rgb(34, 139, 73) 0px 0px 0px inset" },
        // The exact shape the Cloudflare payload carries.
        .{ "box-shadow", "inset 0 0 0 rgb(34, 139, 73)", "rgb(34, 139, 73) 0px 0px 0px inset" },
        // A unitless zero in a length slot gains `px`; `0em` keeps its unit.
        .{ "box-shadow", "0px 0em 0 0 red", "red 0px 0em 0px 0px" },
        // Each comma layer is ordered on its own.
        .{ "box-shadow", "1px 1px red,2px 2px blue", "red 1px 1px, blue 2px 2px" },
        .{ "box-shadow", "inset 0 0 0 red,0 1px 2px blue", "red 0px 0px 0px inset, blue 0px 1px 2px" },
        // A layer with no colour keeps its lengths; Chrome invents none.
        .{ "box-shadow", "inset 1px 2px 3px 4px", "1px 2px 3px 4px inset" },
        .{ "box-shadow", "1px 2px", "1px 2px" },
        // `none` is a keyword, not a layer.
        .{ "box-shadow", "none", "none" },
        // text-shadow takes the same rule, minus `inset`.
        .{ "text-shadow", "1px 2px 3px red", "red 1px 2px 3px" },
        .{ "text-shadow", "0 0 red", "red 0px 0px" },
        .{ "text-shadow", "1px 1px red,2px 2px blue", "red 1px 1px, blue 2px 2px" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: first baseline to baseline" {
    const result = try normalizePropertyValue(testing.allocator, "align-items", "first baseline");
    try testing.expectEqual("baseline", result);

    const result2 = try normalizePropertyValue(testing.allocator, "align-self", "last baseline");
    try testing.expectEqual("last baseline", result2);
}

// The three rules of `twoValueRule`, and the rows where they disagree: a fold
// keeps nothing of an equal pair, a size keeps both halves but drops a trailing
// `auto`, a repeat renames the two pairs that spell an axis. The fixture in
// tests/css/declaration_serialize.html carries the same readings through the
// CSSOM; these are the ones taken straight off the canonicaliser.
test "normalizePropertyValue: shorten a two-value property" {
    const cases = .{
        // .fold
        .{ "overflow", "hidden hidden", "hidden" },
        .{ "gap", "10px 10px", "10px" },
        .{ "scroll-snap-align", "start start", "start" },
        .{ "scroll-padding-block", "5px 5px", "5px" },
        .{ "overscroll-behavior", "auto auto", "auto" },
        .{ "border-image-repeat", "stretch stretch", "stretch" },
        .{ "-webkit-mask-box-image-repeat", "stretch stretch", "stretch" },
        .{ "overflow", "hidden scroll", "hidden scroll" },
        .{ "gap", "10px 20px", "10px 20px" },
        // .size -- an equal pair is two values, and only a trailing `auto` goes
        .{ "background-size", "auto auto", "auto" },
        .{ "background-size", "10px auto", "10px" },
        .{ "background-size", "auto 10px", "auto 10px" },
        .{ "background-size", "10px 10px", "10px 10px" },
        .{ "mask-size", "10px 10px", "10px 10px" },
        .{ "background-size", "0 0", "0px 0px" },
        .{ "background-size", "0 auto", "0px" },
        .{ "background-size", "cover", "cover" },
        // .repeat
        .{ "background-repeat", "repeat no-repeat", "repeat-x" },
        .{ "background-repeat", "no-repeat repeat", "repeat-y" },
        .{ "background-repeat", "round round", "round" },
        .{ "background-repeat", "space round", "space round" },
        .{ "mask-repeat", "repeat no-repeat", "repeat-x" },
        // Per layer, both rules
        .{ "background-size", "10px auto, 20px", "10px, 20px" },
        .{ "background-repeat", "repeat repeat, no-repeat repeat", "repeat, repeat-y" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

// The tokenising edges the fixture in tests/css/declaration_serialize.html does
// not reach. Those rows are all Chrome's answer; three of these are not, and say
// so -- they are shapes Chrome rewrites past a case change (a hex colour into
// `rgb()`, an exponent into digits, an unquoted url into a quoted one), which is
// out of this plan's scope. What is asserted there is that the case pass leaves
// the rest of the value exactly where it found it.
test "normalizePropertyValue: value case" {
    const cases = .{
        // The four shapes Chrome re-cases, in the spelling it answers with.
        .{ "display", "BLOCK", "block" },
        .{ "width", "INHERIT", "inherit" },
        .{ "width", "10PX", "10px" },
        .{ "transform", "TranslateX(1PX)", "translateX(1px)" },
        .{ "margin", "-1PX -2.5EM", "-1px -2.5em" },
        .{ "width", "CALC(1PX)", "calc(1px)" },
        // Measured: only the whole value is a CSS-wide keyword. `font-family:
        // Initial` is `initial`, where `font-family: MyFont, Initial` is not a
        // list with a lowercased tail -- Chrome drops the declaration whole.
        .{ "font-family", "Initial", "initial" },
        .{ "font-family", "SANS-SERIF", "sans-serif" },
        .{ "font-family", "MyOwnFont", "MyOwnFont" },
        .{ "font-family", "MyFont, Initial", "MyFont, Initial" },
        // A keyword the property is not measured as taking is left alone.
        // (Chrome drops this declaration; this engine keeps invalid values, a
        // separate and already-recorded difference.)
        .{ "display", "Nonsense", "Nonsense" },
        // The hex digits are not read as an identifier: the whole hash is one
        // token, and it folds to the rgb() Chrome answers.
        .{ "color", "#AABBCC", "rgb(170, 187, 204)" },
        .{ "content", "\"MiXeD\"", "\"MiXeD\"" },
        .{ "content", "\"1PX\"", "\"1PX\"" },
        .{ "background-image", "URL(Foo/Bar.PNG)", "url(\"Foo/Bar.PNG\")" },
        // An `e` only starts an exponent when digits follow it, or `1em` would
        // lose its unit.
        .{ "width", "1EM", "1em" },
        .{ "width", "1E2PX", "100px" },
        // A substituted value freezes whole, capitals and all.
        .{ "width", "VAR(--Foo)", "VAR(--Foo)" },
        .{ "width", "CALC(1PX + VAR(--a))", "CALC(1PX + VAR(--a))" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: numbers" {
    const cases = .{
        // printf %g over a value clamped to the float range.
        .{ "width", "1E2px", "100px" },
        .{ "width", "1E-2px", "0.01px" },
        .{ "width", "1.50px", "1.5px" },
        .{ "width", "+1px", "1px" },
        .{ "width", ".5px", "0.5px" },
        .{ "width", "01.5px", "1.5px" },
        .{ "width", "3.14159265358979px", "3.14159px" },
        .{ "width", "999999.9px", "1e+06px" },
        .{ "width", "1e100px", "3.40282e+38px" },
        .{ "width", "1e-40px", "1e-40px" },
        .{ "width", "-0px", "0px" },
        .{ "margin", "1.500px -2.0px +3px .5px", "1.5px -2px 3px 0.5px" },
        .{ "transform", "scale(1E1)", "scale(10)" },
        // An <integer> prints as one, clamped to the 32-bit range.
        .{ "z-index", "1000000", "1000000" },
        .{ "z-index", "3000000000", "2147483647" },
        .{ "z-index", "-3000000000", "-2147483648" },
        .{ "order", "010", "10" },
        .{ "counter-increment", "c 1000000", "c 1000000" },
        .{ "grid-template-columns", "repeat(1000000, 1px)", "repeat(1000000, 1px)" },
        // Everywhere else the same digits are a <number>.
        .{ "flex-grow", "1000000", "1e+06" },
        .{ "width", "1234567px", "1.23457e+06px" },
        .{ "columns", "1000000px", "1e+06px" },
        // Not a value: a string, a url() path, a substituted value.
        .{ "content", "\".5\"", "\".5\"" },
        .{ "background-image", "url(.5)", "url(\".5\")" },
        .{ "width", "var(--a, .5px)", "var(--a, .5px)" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: colours" {
    const cases = .{
        .{ "color", "#AABBCC", "rgb(170, 187, 204)" },
        .{ "color", "#abc", "rgb(170, 187, 204)" },
        .{ "color", "#AABBCCFF", "rgb(170, 187, 204)" },
        .{ "color", "#AABBCCDD", "rgba(170, 187, 204, 0.867)" },
        .{ "color", "#1234", "rgba(17, 34, 51, 0.267)" },
        .{ "color", "rgb(1 2 3)", "rgb(1, 2, 3)" },
        .{ "color", "rgb(1 2 3 / 50%)", "rgba(1, 2, 3, 0.5)" },
        .{ "color", "rgba(1,2,3,1)", "rgb(1, 2, 3)" },
        .{ "color", "rgb(300, -5, 2.6)", "rgb(255, 0, 3)" },
        .{ "color", "rgb(50%, 25%, 0%)", "rgb(128, 64, 0)" },
        .{ "color", "rgb(none 2 3)", "rgb(0, 2, 3)" },
        .{ "color", "hsl(120, 50%, 50%)", "rgb(64, 191, 64)" },
        .{ "color", "hsl(2rad 50% 50%)", "rgb(75, 191, 64)" },
        .{ "color", "hwb(120 20% 30%)", "rgb(51, 179, 51)" },
        .{ "color", "hwb(120 50% 60%)", "rgb(116, 116, 116)" },
        .{ "border", "1px solid #ABC", "1px solid rgb(170, 187, 204)" },
        // Left alone: a named colour, a space Chrome does not fold, arguments
        // that are not plain numbers, and a hex of any other length.
        .{ "color", "rebeccapurple", "rebeccapurple" },
        .{ "color", "oklch(0.5 0.1 200)", "oklch(0.5 0.1 200)" },
        .{ "color", "rgb(from red r g b)", "rgb(from red r g b)" },
        .{ "color", "#12345", "#12345" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: anchor() canonical order" {
    const cases = .{
        // Dashed ident should come before keyword
        .{ "left", "anchor(left --foo)", "anchor(--foo left)" },
        .{ "left", "anchor(inside --foo)", "anchor(--foo inside)" },
        .{ "left", "anchor(50% --foo)", "anchor(--foo 50%)" },
        // Already canonical order - keep as-is
        .{ "left", "anchor(--foo left)", "anchor(--foo left)" },
        .{ "left", "anchor(left)", "anchor(left)" },
        // With fallback
        .{ "left", "anchor(left --foo, 1px)", "anchor(--foo left, 1px)" },
        // Nested anchor in fallback
        .{ "left", "anchor(left --foo, anchor(right --bar))", "anchor(--foo left, anchor(--bar right))" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "WebApi: CSSStyleDeclaration surface" {
    try testing.htmlRunner("css/declaration_surface.html", .{});
}

test "WebApi: CSSStyleDeclaration computed initial values" {
    try testing.htmlRunner("css/computed_initial_values.html", .{});
}

test "WebApi: CSSStyleDeclaration computed per-tag values" {
    try testing.htmlRunner("css/computed_per_tag_values.html", .{});
}

test "WebApi: CSSStyleDeclaration serialize" {
    try testing.htmlRunner("css/declaration_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration font family serialize" {
    try testing.htmlRunner("css/font_family_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration value list serialize" {
    try testing.htmlRunner("css/value_list_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration transform serialize" {
    try testing.htmlRunner("css/transform_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration border image serialize" {
    try testing.htmlRunner("css/border_image_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration animation serialize" {
    try testing.htmlRunner("css/animation_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration shadow serialize" {
    try testing.htmlRunner("css/shadow_serialize.html", .{});
}

test "WebApi: CSSStyleDeclaration custom properties" {
    try testing.htmlRunner("css/custom_properties_inline.html", .{});
}

test "WebApi: CSSStyleDeclaration custom property cascade" {
    try testing.htmlRunner("css/custom_properties_cascade.html", .{});
}

test "WebApi: CSSStyleDeclaration custom property var substitution" {
    try testing.htmlRunner("css/custom_properties_var.html", .{});
}

test "WebApi: CSSStyleDeclaration display cascade" {
    try testing.htmlRunner("css/display_cascade.html", .{});
}

test "WebApi: CSSStyleDeclaration important beats the style attribute" {
    try testing.htmlRunner("css/important_vs_inline.html", .{});
}

test "WebApi: CSSStyleDeclaration author longhands" {
    try testing.htmlRunner("css/computed_author_longhands.html", .{});
}

test "WebApi: CSSStyleDeclaration inheritance" {
    try testing.htmlRunner("css/computed_inheritance.html", .{});
}

test "WebApi: CSSStyleDeclaration computed colours" {
    try testing.htmlRunner("css/computed_color_values.html", .{});
}

test "WebApi: CSSStyleDeclaration computed system fonts" {
    try testing.htmlRunner("css/computed_system_fonts.html", .{});
}

test "WebApi: CSSStyleDeclaration font shorthand" {
    try testing.htmlRunner("css/font_shorthand.html", .{});
}

test "WebApi: CSSStyleDeclaration computed font weight and stretch" {
    try testing.htmlRunner("css/computed_font_weight_stretch.html", .{});
}

test "WebApi: CSSStyleDeclaration first computed read" {
    try testing.htmlRunner("css/computed_first_read.html", .{});
}

test "WebApi: CSSStyleDeclaration computed transform" {
    try testing.htmlRunner("css/computed_transform.html", .{});
}

test "WebApi: CSSStyleDeclaration percentage width" {
    try testing.htmlRunner("css/percentage_width.html", .{});
}

test "WebApi: CSSStyleDeclaration percentage margin" {
    try testing.htmlRunner("css/margin_percentage.html", .{});
}

test "WebApi: CSSStyleDeclaration specified precision" {
    try testing.htmlRunner("css/specified_precision.html", .{});
}

test "WebApi: CSSStyleDeclaration block height" {
    try testing.htmlRunner("css/block_height.html", .{});
}

test "WebApi: CSSStyleDeclaration margin collapse" {
    try testing.htmlRunner("css/margin_collapse.html", .{});
}

test "WebApi: CSSStyleDeclaration inline content lines" {
    try testing.htmlRunner("css/inline_content_lines.html", .{});
}

test "WebApi: CSSStyleDeclaration stylesheet font layout" {
    try testing.htmlRunner("css/stylesheet_font_layout.html", .{});
}

test "WebApi: CSSStyleDeclaration default display" {
    try testing.htmlRunner("css/default_display.html", .{});
}

test "WebApi: CSSStyleDeclaration computed border width" {
    try testing.htmlRunner("css/computed_border_width.html", .{});
}

test "WebApi: CSSStyleDeclaration computed shorthand join" {
    try testing.htmlRunner("css/computed_shorthand_join.html", .{});
}

test "WebApi: CSSStyleDeclaration computed logical properties" {
    try testing.htmlRunner("css/computed_logical_physical.html", .{});
}

test "WebApi: CSSStyleDeclaration computed relative units" {
    try testing.htmlRunner("css/computed_relative_units.html", .{});
}

test "WebApi: CSSStyleDeclaration computed alpha clamp" {
    try testing.htmlRunner("css/computed_alpha_clamp.html", .{});
}

test "WebApi: CSSStyleDeclaration computed style of a detached element" {
    try testing.htmlRunner("css/computed_detached.html", .{});
}

test "WebApi: CSSStyleDeclaration computed transform-origin" {
    try testing.htmlRunner("css/computed_origin.html", .{});
}

test "WebApi: CSSStyleDeclaration unrendered percentages" {
    try testing.htmlRunner("css/computed_unrendered_percentages.html", .{});
}

test "WebApi: CSSStyleDeclaration percentage kept" {
    try testing.htmlRunner("css/computed_percentage_kept.html", .{});
}

test "WebApi: CSSStyleDeclaration position keywords" {
    try testing.htmlRunner("css/computed_position_keywords.html", .{});
}
