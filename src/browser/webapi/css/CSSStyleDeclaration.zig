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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const StyleManager = @import("../../StyleManager.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

const chrome_properties = @import("chrome_properties.zig");
const typed_om = @import("typed_om.zig");

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

pub fn length(self: *const CSSStyleDeclaration) u32 {
    // A computed view enumerates every longhand Chrome computes, whether or not
    // the page set any of them, so its length does not depend on _properties.
    if (self._is_computed) {
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

fn propertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame, surface: Surface) []const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
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
        }
    }

    const prop = self.findProperty(wrapped) orelse {
        // Only return default values for computed styles
        if (self._is_computed) {
            if (self._element) |element| {
                // Resolve inline `style=` declarations through the element's
                // parsed inline style, so computed values match `el.style`.
                const style_manager = &element.ownerFrame(frame)._style_manager;
                if (style_manager.inlineStyleValue(element, wrapped)) |value| {
                    // var() is substituted at computed-value time; the
                    // specified value `el.style` hands out keeps its var() text.
                    return style_manager.substituteVars(element, value) orelse "";
                }

                // Computed width/height must agree with the synthetic layout
                // metrics. Returning "" makes measurement code see
                // contradictory sizes — jQuery's "shrink text until it fits"
                // loops then never terminate. jQuery's .width() reads this
                // value, so it must also carry clientWidth's content fallback
                // or append-until-wide marquee loops never terminate.
                if (wrapped.eql(comptime .wrap("width"))) {
                    return resolvedDimension(element, .width, frame);
                }
                if (wrapped.eql(comptime .wrap("height"))) {
                    return resolvedDimension(element, .height, frame);
                }
            }
            return getDefaultPropertyValue(self, wrapped, surface);
        }
        return "";
    };
    return prop._value.str();
}

/// The `display` a computed view reports: the cascade first (a stylesheet rule
/// sets display as often as an inline declaration does, and the generic inline
/// path cannot let a sheet's `!important` outrank one), the per-tag UA default
/// when nothing declares one, and then blockification -- a flex or grid parent
/// turns its child element's outer display block-level, which is how Chrome
/// exposes it and the reason innerText breaks a line there.
pub fn resolvedDisplay(element: *Element, frame: *Frame) []const u8 {
    const specified = frame._style_manager.computedDisplay(element) orelse getDefaultDisplay(element);
    const parent = element.parentElement() orelse return specified;
    if (!frame._style_manager.blockifiesChildren(parent)) {
        return specified;
    }
    return StyleManager.blockify(specified);
}

fn resolvedDimension(element: *Element, dimension: enum { width, height }, frame: *Frame) []const u8 {
    var visibility_cache: Element.VisibilityCache = .{};
    if (!element.checkVisibilityCached(&visibility_cache, frame)) {
        return "auto";
    }
    const value = switch (dimension) {
        .width => element.getClientWidthWithCache(frame, &visibility_cache),
        .height => element.getClientHeightWithCache(frame, &visibility_cache),
    };
    return std.fmt.allocPrint(frame.local_arena, "{d}px", .{value}) catch "auto";
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const prop = self.findProperty(.wrap(normalized)) orelse return "";
    return if (prop._important) "important" else "";
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

    try self.setPropertyImpl(property_name, value, important, frame);

    try self.syncStyleAttribute(frame);
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
        return self.storeProperty(declaration.name, "", declaration.important, frame);
    }
    try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, frame);
}

fn setPropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, frame: *Frame) !void {
    if (value.len == 0) {
        _ = try self.removePropertyImpl(property_name, frame);
        return;
    }

    return self.storeProperty(property_name, value, important, frame);
}

fn storeProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, frame: *Frame) !void {
    const normalized = normalizePropertyName(property_name, &frame.buf);

    // Normalize the value for canonical serialization
    const normalized_value = try normalizePropertyValue(frame.local_arena, normalized, value);

    // Find existing property
    if (self.findProperty(.wrap(normalized))) |existing| {
        existing._value = try String.init(frame.arena, normalized_value, .{});
        existing._important = important;
        return;
    }

    // Create new property
    const prop = try frame._factory.create(Property{
        ._node = .{},
        ._name = try String.init(frame.arena, normalized, .{}),
        ._value = try String.init(frame.arena, normalized_value, .{}),
        ._important = important,
    });
    self._properties.append(&prop._node);
}

pub fn removeProperty(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    const result = try self.removePropertyImpl(property_name, frame);
    try self.syncStyleAttribute(frame);
    return result;
}

fn removePropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const prop = self.findProperty(.wrap(normalized)) orelse return "";

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
    try self.setPropertyImpl("float", value_ orelse "", false, frame);
    try self.syncStyleAttribute(frame);
}

pub fn getCssText(self: *const CSSStyleDeclaration, frame: *Frame) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try self.format(&buf.writer);
    return buf.written();
}

pub fn setCssText(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    self.clearProperties(frame);

    try self.applyDeclarations(text, frame);
    try self.syncStyleAttribute(frame);
}

pub fn format(self: *const CSSStyleDeclaration, writer: *std.Io.Writer) !void {
    const node = self._properties.first orelse return;
    try Property.fromNodeLink(node).format(writer);

    var next = node.next;
    while (next) |n| {
        try writer.writeByte(' ');
        try Property.fromNodeLink(n).format(writer);
        next = n.next;
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

fn normalizePropertyName(name: []const u8, buf: []u8) []const u8 {
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

// Normalize CSS property values for canonical serialization
fn normalizePropertyValue(arena: Allocator, property_name: []const u8, raw_value: []const u8) ![]const u8 {
    // A custom property's value is an arbitrary token stream: Chrome stores it
    // as written, minus the surrounding whitespace (`--c: 01.50` stays
    // "01.50", `--e: a  b   c` keeps its inner runs).
    if (isCustomProperty(property_name)) {
        return std.mem.trim(u8, raw_value, &std.ascii.whitespace);
    }
    const value = try normalizeLeadingZeros(arena, raw_value);

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

    // For 2-value shorthand properties, collapse "X X" to "X"
    if (isTwoValueShorthand(property_name)) {
        if (collapseDuplicateValue(value)) |single| {
            return single;
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

// Insert a leading "0" before any bare ".<digit>". A value might have multiple
// such bare digits
fn normalizeLeadingZeros(arena: Allocator, value: []const u8) ![]const u8 {
    // A bare ".<digit>" needs at least 2 chars, and a trailing "." can never be
    // followed by a digit. So we only ever scan up to value.len - 1, which lets
    // us index value[i + 1] without a bounds check.
    if (value.len < 2) {
        return value;
    }

    var inserts: usize = 0;
    for (value[0 .. value.len - 1], 0..) |c, i| {
        if (c != '.') {
            continue;
        }
        if (!std.ascii.isDigit(value[i + 1])) {
            // next value isn't a digit
            continue;
        }
        if (i > 0 and std.ascii.isDigit(value[i - 1])) {
            // previous value is a digit
            continue;
        }
        inserts += 1;
    }
    if (inserts == 0) {
        return value;
    }

    const buf = try arena.alloc(u8, value.len + inserts);
    var w: usize = 0;
    for (value[0 .. value.len - 1], 0..) |c, i| {
        if (c == '.' and std.ascii.isDigit(value[i + 1]) and (i == 0 or !std.ascii.isDigit(value[i - 1]))) {
            buf[w] = '0';
            w += 1;
        }
        buf[w] = c;
        w += 1;
    }
    // The last char is copied unconditionally: it can't start a bare ".<digit>".
    buf[w] = value[value.len - 1];
    w += 1;
    return buf[0..w];
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

// Check if a value is "X X" (duplicate) and return just "X"
fn collapseDuplicateValue(value: []const u8) ?[]const u8 {
    const space_idx = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
    if (space_idx == 0 or space_idx >= value.len - 1) return null;

    const first = value[0..space_idx];
    const rest = std.mem.trimStart(u8, value[space_idx + 1 ..], " ");

    // Check if there's only one more value (no additional spaces)
    if (std.mem.indexOfScalar(u8, rest, ' ') != null) return null;

    if (std.mem.eql(u8, first, rest)) {
        return first;
    }
    return null;
}

fn isTwoValueShorthand(name: []const u8) bool {
    const shorthands = std.StaticStringMap(void).initComptime(.{
        .{ "place-content", {} },
        .{ "place-items", {} },
        .{ "place-self", {} },
        .{ "margin-block", {} },
        .{ "margin-inline", {} },
        .{ "padding-block", {} },
        .{ "padding-inline", {} },
        .{ "inset-block", {} },
        .{ "inset-inline", {} },
        .{ "border-block-style", {} },
        .{ "border-inline-style", {} },
        .{ "border-block-width", {} },
        .{ "border-inline-width", {} },
        .{ "border-block-color", {} },
        .{ "border-inline-color", {} },
        .{ "overflow", {} },
        .{ "overscroll-behavior", {} },
        .{ "gap", {} },
        .{ "grid-gap", {} },
        // Scroll
        .{ "scroll-padding-block", {} },
        .{ "scroll-padding-inline", {} },
        .{ "scroll-snap-align", {} },
        // Background/Mask
        .{ "background-size", {} },
        .{ "border-image-repeat", {} },
        .{ "mask-repeat", {} },
        .{ "mask-size", {} },
    });
    return shorthands.has(name);
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
    });

    return length_properties.has(name);
}

fn getDefaultPropertyValue(self: *const CSSStyleDeclaration, name: String, surface: Surface) []const u8 {
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
    return "";
}

/// The one initial value measured to differ between the two surfaces: the
/// initial `border-width: medium` computes to 3px, and the CSS Typed OM reports
/// that, while getComputedStyle reports the used width, which `border-style:
/// none` collapses to 0px. Chrome 151 on a div with no border answers `3px` from
/// `computedStyleMap().get('border-top-width')` and `0px` from
/// `getComputedStyle().borderTopWidth`.
///
/// Only the undeclared case comes through here, so a declared width is reported
/// as declared on both surfaces. An element that declares a border *style* but
/// no width still reads 0px here where Chrome would say 3px: the used width then
/// depends on the cascaded border-style, which this computed view does not
/// resolve.
fn borderWidth(surface: Surface) []const u8 {
    return switch (surface) {
        .used => "0px",
        .computed => "3px",
    };
}

fn getDefaultDisplay(element: *const Element) []const u8 {
    switch (element._type) {
        .html => {
            return switch (element.subtype(Element.Html)._type) {
                .anchor, .br, .span, .label, .time, .font, .mod, .quote => "inline",
                .body, .div, .dl, .p, .heading, .form, .button, .canvas, .details, .dialog, .embed, .head, .html, .hr, .iframe, .img, .input, .li, .link, .meta, .ol, .option, .script, .select, .slot, .style, .template, .textarea, .title, .ul, .media, .area, .base, .datalist, .directory, .menu, .frame_element, .fieldset, .frameset, .legend, .map, .marquee, .meter, .object, .optgroup, .output, .param, .picture, .pre, .progress, .source, .table, .table_caption, .table_cell, .table_col, .table_row, .table_section, .track => "block",
                .generic, .custom, .unknown, .data => blk: {
                    const tag = element.getTagNameLower();
                    if (isInlineTag(tag)) break :blk "inline";
                    break :blk "block";
                },
            };
        },
        // Chrome lays MathML out as inline too (`math` is display: inline
        // math), which is as close as the faux layout gets. An element in a
        // namespace we know nothing about is inline for the same reason.
        .svg, .mathml, .plain => return "inline",
    }
}

fn isInlineTag(tag_name: []const u8) bool {
    const inline_tags = [_][]const u8{
        "abbr",  "b",    "bdi",    "bdo",  "cite", "code", "dfn",
        "em",    "i",    "kbd",    "mark", "q",    "s",    "samp",
        "small", "span", "strong", "sub",  "sup",  "time", "u",
        "var",   "wbr",
    };

    for (inline_tags) |inline_tag| {
        if (std.mem.eql(u8, tag_name, inline_tag)) {
            return true;
        }
    }
    return false;
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

test "normalizePropertyValue: first baseline to baseline" {
    const result = try normalizePropertyValue(testing.allocator, "align-items", "first baseline");
    try testing.expectEqual("baseline", result);

    const result2 = try normalizePropertyValue(testing.allocator, "align-self", "last baseline");
    try testing.expectEqual("last baseline", result2);
}

test "normalizePropertyValue: collapse duplicate two-value shorthands" {
    const cases = .{
        .{ "overflow", "hidden hidden", "hidden" },
        .{ "gap", "10px 10px", "10px" },
        .{ "scroll-snap-align", "start start", "start" },
        .{ "scroll-padding-block", "5px 5px", "5px" },
        .{ "background-size", "auto auto", "auto" },
        .{ "overscroll-behavior", "auto auto", "auto" },
        // Different values should NOT collapse
        .{ "overflow", "hidden scroll", "hidden scroll" },
        .{ "gap", "10px 20px", "10px 20px" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, case[0], case[1]);
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
