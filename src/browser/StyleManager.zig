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

const Frame = @import("Frame.zig");

const units = @import("css/units.zig");
const CssParser = @import("css/Parser.zig");
const Tokenizer = @import("css/Tokenizer.zig");
const MediaQuery = @import("css/MediaQuery.zig");
const Element = @import("webapi/Element.zig");

const Selector = @import("webapi/selector/Selector.zig");
const SelectorParser = @import("webapi/selector/Parser.zig");
const SelectorList = @import("webapi/selector/List.zig");

const CSSStyleRule = @import("webapi/css/CSSStyleRule.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const chrome_per_tag_values = @import("webapi/css/chrome_per_tag_values.zig");
const CSSStyleDeclaration = @import("webapi/css/CSSStyleDeclaration.zig");
const CSSStyleProperty = @import("webapi/css/CSSStyleDeclaration.zig").Property;
const shorthand = @import("webapi/css/shorthand.zig");
const registered_property = @import("webapi/css/registered_property.zig");
const supports_condition = @import("webapi/css/supports.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

pub const VisibilityCache = std.AutoHashMapUnmanaged(*Element, bool);
pub const PointerEventsCache = std.AutoHashMapUnmanaged(*Element, bool);

// Tracks the CSS rules we resolve from <style> elements: the visibility
// filter's properties, plus font-size, which SVG's `em` units and text
// measurement read back.
// Rules are bucketed by their rightmost selector part for fast lookup.
const StyleManager = @This();

const Tag = Element.Tag;
const Input = Element.Html.Input;
const RuleList = std.MultiArrayList(Rule);

/// One step of a `@keyframes` rule: where in the animation it sits, and the
/// declarations it carries. A shared selector (`0%, 50% { ... }`) is stored as
/// one entry per key, all pointing at the same block.
pub const Keyframe = struct {
    /// A fraction of one iteration, so `from` is 0 and `to` is 1. Outside
    /// [0, 1] is possible -- `-50%` parses -- and the interval search that
    /// reads these simply never selects such a frame.
    offset: f64,
    /// The declaration block, verbatim, still to be parsed by whoever wants a
    /// property out of it. Which property that is depends on the reader, so
    /// nothing is extracted here.
    block: []const u8,
};

frame: *Frame,

arena: *lp.Arena,

// Bucketed rules for fast lookup - keyed by rightmost selector part
id_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
class_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
tag_rules: std.AutoHashMapUnmanaged(Tag, RuleList) = .empty,
other_rules: RuleList = .empty, // universal, attribute, pseudo-class endings

/// The thing to remember about layers is that we can't determine priority's
/// layer_rank until everything is parsed. So we need to build up meta data when
/// rebuilding and do one final pass to apply the resulting layering rank.

// Layer registry rebuilt with the rules. Append-only.
layers: std.ArrayList(Layer) = .empty,
// layer full name -> layers index
layer_ids: std.StringHashMapUnmanaged(u16) = .empty,
// rule -> layers index, e.g. for rule at index N, rule_layers[N] is its layer
rule_layers: std.ArrayList(u16) = .empty,

next_anon_layer: u32 = 0,

// Document order counter for tie-breaking equal specificity. Starts at 1, 0
// is used as a sentinel is isElementHidden()
next_doc_order: u32 = 1,

// When true, rules need to be rebuilt
dirty: bool = false,

// Every longhand name any rule in the document declares, rebuilt with the
// rules. A cascade lookup for a name that is not in here cannot have a winner,
// and answering that in one hash probe is what makes the lookup affordable on
// the paths that ask per element: `cascadedNamedDeclaration` otherwise compares
// the wanted name against every declaration of every rule keyed to the
// element's id, classes and tag before it can say "nobody declared it".
//
// document.elementFromPoint is the path that cares. It rejects thousands of
// elements on their y alone, and `element_from_point.html` budgets 40 calls
// over 800 elements at 1500ms.
declared_longhands: std.StringHashMapUnmanaged(void) = .empty,

/// `@keyframes` name -> its steps, rebuilt with the rules. Keyframes take no
/// part in the cascade -- they declare nothing on any element, which is why
/// `parseSheet` skipped them for so long -- but the computed value of an
/// animated property is read out of them, and `animation-name` is the only
/// thing that resolves the name. Names are case-sensitive custom identifiers,
/// so the lookup is an exact match.
keyframes: std.StringHashMapUnmanaged([]const Keyframe) = .empty,

/// What `cascadedNamedDeclaration` last answered, per element and property.
///
/// The walk behind `getBoundingClientRect` asks about two dozen properties of
/// every node it visits, and a page asks for the box over and over: homedepot
/// takes 314 layout reads in one load, kohls 1 943, macys 21 695
/// (`scratch/b99/mutation-between-reads-sync.mjs`). Nothing about the answer
/// changes between two of those reads unless the rules changed or the DOM did,
/// and on those same three pages only 36, 25 and 35 reads had any mutation
/// since the read before them -- 88.5%, 98.7% and 99.8% of reads are asking
/// again about a document nobody touched.
///
/// Lives in `self.arena` beside the rules whose text the answers point into, so
/// the two are discarded together: `rebuildIfDirty` resets that arena, which is
/// why the map is reset there rather than cleared.
cascade_cache: CascadeCache = .empty,

/// The same, for `cascadedDeclaration`'s five fixed properties. Separate map
/// rather than a third `NamedList` variant because the key needs no name: the
/// property is an enum, so this one is a pointer and a tag.
///
/// Worth its own entry because the named cache leaves it as the largest term.
/// With `cascadedNamedDeclaration` cached, a sample of ak-homedepot puts
/// `cascadedDeclaration` at 6.8% of the busy thread and the selector matching it
/// drives at 26.1%; under the layout-pass prototype, which measures every box
/// on the page, those become 17.6% and 65.1%.
fixed_cascade_cache: FixedCascadeCache = .empty,

/// The same again, for `ruleHiding`. Its key is the element alone: the answer
/// takes no property name, no `options` and no inline style, which is the whole
/// reason `isElementHidden` was split in two.
///
/// It earns a third map because it is what the other two left behind. Under the
/// layout-pass prototype, with the named and fixed caches in place, a sample of
/// ak-homedepot put `isElementHidden` at 16.5% of the busy thread and the
/// selector matching it drives at 50.8%.
rule_hiding_cache: RuleHidingCache = .empty,

/// The `Page.dom_version` the cache's contents were computed under. Any DOM
/// mutation moves it -- `Frame.domChanged` covers structure and, through
/// `Attribute.List.put`/`remove`, class and id -- and every entry is stale at
/// once, because a single inserted node changes what `:nth-child`, `+` and `~`
/// match for other elements.
cache_dom_version: usize = 0,

/// What `CSS.registerProperty` has registered, in registration order. Not
/// rebuilt with the rules: a registration is the document's for its lifetime
/// and no stylesheet can undo one -- which is why its entries are allocated
/// from the *frame's* arena and not from `self.arena`, the one `rebuildIfDirty`
/// resets.
registered_properties: registered_property.Registry = .{},

pub fn init(frame: *Frame) !StyleManager {
    return .{
        .frame = frame,
        .arena = try frame.getArena(.medium, "StyleManager"),
    };
}

pub fn deinit(self: *StyleManager) void {
    self.arena.release();
}

/// Hard cap on `@media` / `@layer` nesting depth. CSS allows arbitrarily-deep
/// at-rule nesting; without a cap a hostile inline stylesheet could blow the
/// Zig stack via the mutually-recursive `applyMediaAtRule` / `applyLayerAtRule`
/// `applyInnerRules` frames. 32 is well past anything seen in the wild.
const MAX_AT_RULE_NESTING: u8 = 32;

/// Hard cap on nested *style* rule depth (css-nesting-1), for the same reason
/// as `MAX_AT_RULE_NESTING`. Lower than that cap because each level here also
/// grows the resolved selector by a `:is(…)` wrapper, so the cost is in the
/// selector text as well as the stack.
const MAX_NESTING_DEPTH: u8 = 16;

fn parseSheet(self: *StyleManager, build_arena: Allocator, sheet: *CSSStyleSheet) !void {
    if (sheet._css_rules) |css_rules| {
        for (css_rules._rules.items) |rule| {
            switch (rule._type) {
                .style => |sr| try self.addRule(build_arena, sr),
                // Re-parse the stored source so an `@media` rule inserted via
                // `insertRule` / `replaceSync` participates in the cascade
                // when its query matches the viewport.
                .media => try self.applyMediaAtRule(build_arena, rule._text, 0, NO_LAYER),
                .supports => try self.applySupportsAtRule(build_arena, rule._text, 0, NO_LAYER),
                .layer_block, .layer_statement => try self.applyLayerAtRule(build_arena, rule._text, 0, NO_LAYER),
                // Off the stored source for the same reason `@media` is: this
                // reads the rule as the page wrote it, so a keyframe added
                // afterwards through `CSSKeyframesRule.appendRule` is not seen
                // here any more than an `insertRule` inside an `@media` is.
                .keyframes => try self.addKeyframesAtRule(rule._text),
                else => {},
            }
        }
        return;
    }

    // Nothing has materialised the CSSOM view, so the rules come straight from
    // the owner element's text. <style> in either namespace owns its rules that
    // way -- SVG's is not scoped to its subtree, it feeds the same cascade the
    // HTML one does (Chrome 151 reads `hidden` for a span next to
    // `<svg><style>.tv{visibility:hidden}</style></svg>`; probe v2-diag).
    const owner_node = sheet.getOwnerNode() orelse return;
    const owner_style_node = if (owner_node.is(Element.Html.Style)) |style|
        style.asNode()
    else if (owner_node.is(Element.Svg.Style)) |style|
        style.asNode()
    else
        return;

    const text = try owner_style_node.getTextContentAlloc(self.arena.allocator());
    var it = CssParser.parseStylesheet(text);
    while (it.next()) |parsed_rule| {
        switch (parsed_rule) {
            .style => |s| try self.addRawRule(build_arena, s.selector, s.block, NO_LAYER),
            .at_rule => |a| {
                // Only the conditional group rules participate in the cascade
                // here. The rest (`@font-face`, `@page`, …) don't carry
                // top-level declarations relevant to the visibility filter and
                // stay skipped as before. `@keyframes` is skipped by the
                // cascade too -- it declares nothing on any element -- but it
                // is indexed by name, because a computed animated property is
                // read out of it.
                if (std.ascii.eqlIgnoreCase(a.keyword, "media")) {
                    try self.applyMediaAtRule(build_arena, a.text, 0, NO_LAYER);
                } else if (std.ascii.eqlIgnoreCase(a.keyword, "supports")) {
                    try self.applySupportsAtRule(build_arena, a.text, 0, NO_LAYER);
                } else if (std.ascii.eqlIgnoreCase(a.keyword, "layer")) {
                    try self.applyLayerAtRule(build_arena, a.text, 0, NO_LAYER);
                } else if (isKeyframesKeyword(a.keyword)) {
                    try self.addKeyframesAtRule(a.text);
                }
            },
        }
    }
}

/// Apply an `@media` at-rule by evaluating its query against the current
/// viewport and, if it matches, parsing the inner block as if its declarations
/// lived at the top level. Non-matching queries silently drop the inner
/// rules. Inline-only by design: external `<link rel="stylesheet">` is out
/// of scope for the headless engine.
fn applyMediaAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }

    const block = atRuleBlock(text, "@media") orelse return;
    const query = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);

    if (MediaQuery.matches(query, self.frame.viewport()) == false) {
        return;
    }

    try self.applyInnerRules(build_arena, block.body, depth + 1, layer);
}

/// Apply an `@supports` at-rule by evaluating its condition and, if it holds,
/// parsing the inner block as if its declarations lived at the top level. Same
/// shape as `applyMediaAtRule`, and for the same reason: the block is a
/// conditional group rule, so what it holds is ordinary rules.
///
/// Every `@supports` block used to be dropped here -- the keyword was simply
/// not in the dispatch -- which showed up as a page's grid layout never being
/// applied. Measured against Chrome 151: the four spellings a page actually
/// writes (`(display: grid)`, `not (…)`, `selector(…)`, a functional value)
/// were all dropped.
fn applySupportsAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }

    const block = atRuleBlock(text, "@supports") orelse return;
    if (!supports_condition.matches(build_arena, block.prelude)) {
        return;
    }

    try self.applyInnerRules(build_arena, block.body, depth + 1, layer);
}

/// Apply an `@layer` rule (css-cascade-5). Layers have two forms:
/// 1 - Block form which may or may not have a name. We register the layer and
//      parse the inner block. This can recurse.
/// 2 - Statement form only registes the name for ordering.
///
/// The layer parameter is the enclosing layer, or NO_LAYER at the top level.
/// Priority is not assigned here, we need all the layers parsed to do that
/// (since a layer statement can alter the ordering). So we'll do one final pass
// in finalizerLayerRanks
fn applyLayerAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }
    if (std.ascii.startsWithIgnoreCase(text, "@layer") == false) {
        return;
    }

    const block = atRuleBlock(text, "@layer") orelse {
        // Statement form: `@layer <name>, <name>;`. One invalid name
        // invalidates the whole statement. Validate everything before
        // registering anything.
        var names = text["@layer".len..];
        if (std.mem.indexOfScalar(u8, names, ';')) |semi| {
            names = names[0..semi];
        }

        var check = std.mem.splitScalar(u8, names, ',');
        while (check.next()) |raw| {
            if (isValidLayerName(std.mem.trim(u8, raw, &std.ascii.whitespace)) == false) {
                return;
            }
        }

        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |raw| {
            _ = try self.registerLayerPath(build_arena, layer, std.mem.trim(u8, raw, &std.ascii.whitespace));
        }
        return;
    };

    const prelude = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);
    if (prelude.len != 0 and isValidLayerName(prelude) == false) {
        // An invalid layer name invalidates the whole rule.
        return;
    }

    const id = if (prelude.len == 0)
        try self.internAnonymousLayer(build_arena, layer)
    else
        try self.registerLayerPath(build_arena, layer, prelude);

    try self.applyInnerRules(build_arena, block.body, depth + 1, id);
}

/// Parse a conditional at-rule's inner block, adding style rules to the
/// cascade and recursing into nested `@media` / `@layer`. `layer` is the
/// enclosing cascade layer (NO_LAYER when unlayered); `depth` is the nesting
/// depth of the *nested* at-rules (callers pass their own depth + 1).
fn applyInnerRules(self: *StyleManager, build_arena: Allocator, inner: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    var it = CssParser.parseStylesheet(inner);
    while (it.next()) |nested_rule| {
        switch (nested_rule) {
            .style => |s| try self.addRawRule(build_arena, s.selector, s.block, layer),
            .at_rule => |nested| {
                if (std.ascii.eqlIgnoreCase(nested.keyword, "media")) {
                    try self.applyMediaAtRule(build_arena, nested.text, depth, layer);
                } else if (std.ascii.eqlIgnoreCase(nested.keyword, "supports")) {
                    try self.applySupportsAtRule(build_arena, nested.text, depth, layer);
                } else if (std.ascii.eqlIgnoreCase(nested.keyword, "layer")) {
                    try self.applyLayerAtRule(build_arena, nested.text, depth, layer);
                } else if (isKeyframesKeyword(nested.keyword)) {
                    try self.addKeyframesAtRule(nested.text);
                }
            },
        }
    }
}

/// Both spellings of the one at-rule. `@-webkit-keyframes` is not a separate
/// rule -- a page writing it and reading `animation-name` back gets the same
/// animation -- so the two index into the same table.
fn isKeyframesKeyword(keyword: []const u8) bool {
    return std.ascii.eqlIgnoreCase(keyword, "keyframes") or
        std.ascii.eqlIgnoreCase(keyword, "-webkit-keyframes");
}

/// Index one `@keyframes` rule under its name. Everything kept lives in
/// `self.arena`, since `text` is borrowed from whatever produced it -- a
/// CSSOM rule's stored source, or a `<style>` element's text -- and only the
/// first of those outlives the rebuild.
fn addKeyframesAtRule(self: *StyleManager, text: []const u8) Allocator.Error!void {
    const block = atRuleBlock(text, "@keyframes") orelse
        atRuleBlock(text, "@-webkit-keyframes") orelse return;
    const name = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);
    if (name.len == 0) {
        return;
    }

    const allocator = self.arena.allocator();
    var frames: std.ArrayList(Keyframe) = .empty;

    var it = CssParser.parseStylesheet(block.body);
    while (it.next()) |parsed| {
        const step = switch (parsed) {
            .style => |s| s,
            // A `@keyframes` block holds keyframe rules and nothing else.
            .at_rule => continue,
        };
        const declarations = try allocator.dupe(u8, step.block);
        // `0%, 50% { … }` is two steps sharing one block, which is why the
        // selector is split rather than parsed as a whole.
        var keys = std.mem.splitScalar(u8, step.selector, ',');
        while (keys.next()) |key| {
            const offset = keyframeOffset(key) orelse continue;
            try frames.append(allocator, .{ .offset = offset, .block = declarations });
        }
    }

    // The later rule replaces the earlier one outright rather than merging
    // into it: two `@keyframes` under one name are one animation, and it is
    // the last one that describes it.
    try self.keyframes.put(allocator, try allocator.dupe(u8, name), frames.items);
}

/// A keyframe selector as a fraction of one iteration. `from` and `to` are the
/// two keywords; everything else has to be a percentage, and a selector that is
/// neither -- `50`, `half` -- takes only itself out of the list.
fn keyframeOffset(raw: []const u8) ?f64 {
    const key = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (key.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(key, "from")) return 0;
    if (std.ascii.eqlIgnoreCase(key, "to")) return 1;
    if (key[key.len - 1] != '%') return null;
    const percent = std.fmt.parseFloat(f64, key[0 .. key.len - 1]) catch return null;
    return percent / 100;
}

/// The steps of the `@keyframes` rule named `name`, or null when the document
/// declares no such rule -- which is what an `animation-name` pointing at
/// nothing computes as: no animation at all, not an empty one.
pub fn keyframesFor(self: *StyleManager, name: []const u8) ?[]const Keyframe {
    self.rebuildIfDirty() catch return null;
    return self.keyframes.get(name);
}

/// Split a block at-rule into its prelude and inner block: for
/// `@media <query> { <body> }` returns `.{ .prelude = "<query>", .body = "<body>" }`.
/// Returns `null` when `text` doesn't start with `keyword`, or when it carries
/// no block — notably the statement form (`@layer a, b;`), which declares
/// ordering only.
///
/// `CssParser.RulesIterator.consumeAtRule` always emits a span starting at `@`;
/// for unclosed blocks it runs to EOF, so the closing `}` is located explicitly
/// rather than assumed to be the final byte. The opening `{` is found with a
/// comment-aware scan so a `/* { */` in the prelude doesn't split the rule at
/// the wrong place; the block's own trivia is handled by the CssParser re-parse
/// in `applyInnerRules`, so only this outer boundary needs the special-case scan.
fn atRuleBlock(text: []const u8, keyword: []const u8) ?struct { prelude: []const u8, body: []const u8 } {
    if (std.ascii.startsWithIgnoreCase(text, keyword) == false) {
        return null;
    }

    const rest = text[keyword.len..];
    const open = indexOfOpenBraceSkippingComments(rest) orelse return null;

    // Search only past the opening brace — the matching `}` lives there, and
    // any returned position is naturally `> open` (since `rest[open] == '{'`).
    const close = open + (std.mem.lastIndexOfScalar(u8, rest[open..], '}') orelse return null);
    return .{ .prelude = rest[0..open], .body = rest[open + 1 .. close] };
}

/// Find the first `{` in `s` that is not inside a CSS `/* ... */` comment.
/// An unclosed comment returns `null` (treat the whole rule as malformed).
fn indexOfOpenBraceSkippingComments(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOf(u8, s[i + 2 ..], "*/") orelse return null;
            i = i + 2 + close + 2;
            continue;
        }
        if (s[i] == '{') return i;
        i += 1;
    }
    return null;
}

/// Register a (possibly dotted) layer name declared inside `parent`,
/// creating any missing ancestors, and return the layer's id. The name must
/// already have passed isValidLayerName — per css-cascade-5 an invalid name
/// invalidates the containing rule, which callers handle before registering.
fn registerLayerPath(self: *StyleManager, build_arena: Allocator, parent: u16, dotted: []const u8) Allocator.Error!u16 {
    var current = parent;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |component| {
        // should have been verified by the caller, via isValidLayerName
        if (comptime lp.IS_DEBUG) {
            std.debug.assert(isValidLayerComponent(component));
        }

        // Components past the depth cap collapse into their ancestor;
        // MAX_AT_RULE_NESTING also bounds finalizeLayerRanks' path buffers.
        if (current != NO_LAYER and self.layers.items[current].depth >= MAX_AT_RULE_NESTING) {
            break;
        }
        current = try self.internLayer(build_arena, current, component);
    }
    return current;
}

/// Each anonymous `@layer { … }` block is its own distinct layer
fn internAnonymousLayer(self: *StyleManager, build_arena: Allocator, parent: u16) Allocator.Error!u16 {
    const id = self.next_anon_layer;
    // \x00{d} isn't a valid layer name, so this can't conflict
    const name = try std.fmt.allocPrint(build_arena, "\x00{d}", .{id});
    self.next_anon_layer = id + 1;
    return self.internLayer(build_arena, parent, name);
}

fn internLayer(self: *StyleManager, build_arena: Allocator, parent: u16, name: []const u8) Allocator.Error!u16 {
    const path = if (parent == NO_LAYER)
        try build_arena.dupe(u8, name)
    else
        try std.fmt.allocPrint(build_arena, "{s}.{s}", .{ self.layers.items[parent].path, name });

    const gop = try self.layer_ids.getOrPut(build_arena, path);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }

    if (self.layers.items.len >= MAX_LAYERS) {
        _ = self.layer_ids.remove(path);
        return parent;
    }

    const id: u16 = @intCast(self.layers.items.len);
    gop.value_ptr.* = id;
    const depth = if (parent == NO_LAYER) 1 else self.layers.items[parent].depth + 1;
    try self.layers.append(build_arena, .{ .path = path, .parent = parent, .depth = depth });
    return id;
}

fn isValidLayerName(dotted: []const u8) bool {
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |component| {
        if (isValidLayerComponent(component) == false) {
            return false;
        }
    }
    return true;
}

fn isValidLayerComponent(component: []const u8) bool {
    if (component.len == 0) {
        return false;
    }
    if (std.ascii.isDigit(component[0])) {
        return false;
    }
    for (component) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => if (c < 0x80) return false,
        }
    }
    return true;
}

/// Compute every layer's rank and apply it to every Rule we have.
/// We can only do this now that we've parsed every parsed every sheet since
/// @layer statement can change the ordering/
fn finalizeLayerRanks(self: *StyleManager, build_arena: Allocator) Allocator.Error!void {
    const layers = self.layers.items;

    if (layers.len == 0) {
        // No layers. Every Rule already has the correct layerless
        // priority, and with no layers, there's nothing to adjust.
        return;
    }

    {
        // If we have three layers:
        //   @layer a.x { ... }
        //   @layer b   { ... }
        //   @layer a.y { ... }
        // If we prioritize them by the order they are defined, we'd get:
        //    a.x => 1  (lowest priority),  b => 2  and  a.y => 3 (highest priority)
        //
        // But it should really be:
        //     a.x => 1, a.y => 2, b => 3
        //
        // because a.y "inherits" the lower priority of the "a" from "a.x" having
        // been declared first.
        //
        // So we need to create something:
        //  a.x => [0, 1],  b => [2], a.y => [0, 3]
        //
        // And now when we sort them, we'll get the correct order because[2] > [0, 3]

        const paths = try build_arena.alloc([]const u16, layers.len);
        for (layers, 0..) |layer, i| {
            const path = try build_arena.alloc(u16, layer.depth);
            var id: u16 = @intCast(i);
            var d = layer.depth;
            while (d > 0) {
                d -= 1;
                path[d] = id;
                id = layers[id].parent;
            }
            paths[i] = path;
        }

        const order = try build_arena.alloc(u16, layers.len);
        for (order, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }

        std.mem.sort(u16, order, paths, struct {
            fn lessThan(ctx: []const []const u16, a: u16, b: u16) bool {
                const pa = ctx[a];
                const pb = ctx[b];
                const common = @min(pa.len, pb.len);
                for (pa[0..common], pb[0..common]) |ca, cb| {
                    if (ca != cb) {
                        return ca < cb;
                    }
                }
                return pa.len > pb.len;
            }
        }.lessThan);

        for (order, 0..) |id, rank| {
            layers[id].rank = @intCast(rank);
        }
    }

    self.stampRuleList(&self.other_rules);

    var id_it = self.id_rules.valueIterator();
    while (id_it.next()) |rules| {
        self.stampRuleList(rules);
    }

    var class_it = self.class_rules.valueIterator();
    while (class_it.next()) |rules| {
        self.stampRuleList(rules);
    }

    var tag_it = self.tag_rules.valueIterator();
    while (tag_it.next()) |rules| {
        self.stampRuleList(rules);
    }
}

fn stampRuleList(self: *StyleManager, rules: *RuleList) void {
    const layers = self.layers.items;
    const rule_layers = self.rule_layers.items;
    for (rules.items(.priority)) |*priority| {
        const doc_order: u32 = @as(u22, @truncate(priority.*));
        const layer = rule_layers[doc_order - 1];
        const rank = if (layer == NO_LAYER) UNLAYERED_RANK else layers[layer].rank;
        priority.* |= @as(u64, rank) << RANK_SHIFT;
    }
}

fn addRawRule(self: *StyleManager, build_arena: Allocator, selector_text: []const u8, block_text: []const u8, layer: u16) !void {
    return self.addRawRuleAtDepth(build_arena, selector_text, block_text, layer, 0);
}

fn addRawRuleAtDepth(self: *StyleManager, build_arena: Allocator, selector_text: []const u8, block_text: []const u8, layer: u16, depth: u8) !void {
    if (selector_text.len == 0) return;

    var props = RuleProperties{};
    var custom: std.ArrayList(NamedDeclaration) = .empty;
    var longhands: std.ArrayList(NamedDeclaration) = .empty;
    var it = CssParser.parseDeclarationsList(block_text);
    while (it.next()) |decl| {
        const name = decl.name;
        const val = decl.value;
        if (std.ascii.eqlIgnoreCase(name, "display")) {
            props.display_none = std.ascii.eqlIgnoreCase(val, "none");
            props.display_none_important = decl.important;
            props.display = .{ .value = val, .important = decl.important };
        } else if (std.ascii.eqlIgnoreCase(name, "visibility")) {
            props.visibility_hidden = std.ascii.eqlIgnoreCase(val, "hidden") or std.ascii.eqlIgnoreCase(val, "collapse");
            props.visibility_hidden_important = decl.important;
            props.visibility = .{ .value = val, .important = decl.important };
        } else if (std.ascii.eqlIgnoreCase(name, "opacity")) {
            props.opacity_zero = std.ascii.eqlIgnoreCase(val, "0");
            props.opacity_zero_important = decl.important;
        } else if (std.ascii.eqlIgnoreCase(name, "pointer-events")) {
            props.pointer_events_none = std.ascii.eqlIgnoreCase(val, "none");
        } else if (std.ascii.eqlIgnoreCase(name, "font-size")) {
            props.font_size = .{ .value = val, .important = decl.important };
        } else if (std.ascii.eqlIgnoreCase(name, "font-family")) {
            props.font_family = .{ .value = val, .important = decl.important };
        } else if (std.ascii.eqlIgnoreCase(name, "text-transform")) {
            props.text_transform = .{ .value = val, .important = decl.important };
        }

        if (CSSStyleDeclaration.isCustomProperty(name)) {
            try custom.append(self.arena.allocator(), .{
                .name = try self.arena.allocator().dupe(u8, name),
                .value = try self.arena.allocator().dupe(u8, val),
                .important = decl.important,
            });
            continue;
        }

        // The raw path parses declarations straight out of the sheet's text, so
        // unlike the CSSOM one it sees shorthands unexpanded. A rule that says
        // `margin:11px` has said `margin-top:11px`, and a computed style is
        // asked for the longhand, so the expansion happens here rather than
        // being missing on whichever of the two paths a page happens to take.
        // `font` is the same story twice over: it expands, but not through
        // `lookup` -- the table still calls it unmodelled, so the parsing half
        // lives in `fontExpansion` and the six system keywords in
        // `systemFontExpansion`. Both have to be asked HERE as well as on the
        // CSSOM path, or a page that writes `font` in a stylesheet gets none of
        // it: measured, a rule `.x{font:13px serif}` left computed font-size at
        // 16px while the same declaration inline gave 13px
        // (probes/expr-b81-font-shorthand-layout.js, the `sheet` case).
        if (shorthand.systemFontExpansion(name, val)) |expansion| {
            for (expansion.names, expansion.values) |longhand_name, longhand_value| {
                try longhands.append(
                    self.arena.allocator(),
                    namedDeclaration(self.arena.allocator(), longhand_name, longhand_value, decl.important),
                );
                carryFontProp(&props, longhand_name, longhand_value, decl.important);
            }
            continue;
        }
        if (shorthand.fontExpansion(self.arena.allocator(), name, val) catch null) |outcome| switch (outcome) {
            // Chrome drops an invalid `font` rather than keeping it whole, so
            // the declaration contributes nothing to the cascade either.
            .refused => continue,
            .wide => |wide| {
                for (wide.expansion.names, wide.expansion.values) |longhand_name, longhand_value| {
                    try longhands.append(self.arena.allocator(), .{
                        .name = longhand_name,
                        .value = longhand_value,
                        .important = decl.important,
                        .specified = null,
                    });
                    carryFontProp(&props, longhand_name, longhand_value, decl.important);
                }
                continue;
            },
            .parsed => |expansion| {
                for (expansion.names, expansion.values) |longhand_name, longhand_value| {
                    try longhands.append(
                        self.arena.allocator(),
                        namedDeclaration(self.arena.allocator(), longhand_name, longhand_value, decl.important),
                    );
                    carryFontProp(&props, longhand_name, longhand_value, decl.important);
                }
                continue;
            },
        };

        // Same story a third time, for `columns` / `list-style` / `grid-area`:
        // the table calls them unmodelled, so `lookup` below declines them and
        // the grammar lives beside it. A rule saying `columns: 3 100px` has
        // said `column-count: 3`, and a computed style is asked for the
        // longhand.
        if (shorthand.grammarExpansion(self.arena.allocator(), name, val) catch null) |expansion| {
            for (expansion.names, expansion.values) |longhand_name, longhand_value| {
                try longhands.append(
                    self.arena.allocator(),
                    namedDeclaration(self.arena.allocator(), longhand_name, longhand_value, decl.important),
                );
            }
            continue;
        }

        if (shorthand.lookup(name)) |entry| {
            if (shorthand.expand(self.arena.allocator(), entry, val) catch null) |expansion| {
                for (expansion.names, expansion.values) |longhand_name, longhand_value| {
                    try longhands.append(
                        self.arena.allocator(),
                        namedDeclaration(self.arena.allocator(), longhand_name, longhand_value, decl.important),
                    );
                }
                continue;
            }
        }

        const lowered = try lowerDuped(self.arena.allocator(), name);
        try longhands.append(
            self.arena.allocator(),
            namedDeclaration(self.arena.allocator(), lowered, val, decl.important),
        );
    }
    props.custom = custom.items;
    props.longhands = longhands.items;
    try self.indexLonghands(props);

    // Not an early return any more: a rule whose own block declares nothing
    // relevant can still hold nested rules that do. `.a { & { … } }` is exactly
    // that shape, and it is the one Tailwind emits.
    if (props.isRelevant()) try self.indexRule(build_arena, props, selector_text, layer);

    return self.addNestedRules(build_arena, selector_text, block_text, layer, depth);
}

/// Bucket one rule's selectors so element matching can find them.
fn indexRule(self: *StyleManager, build_arena: Allocator, props: RuleProperties, selector_text: []const u8, layer: u16) !void {
    const selectors = SelectorParser.parseList(self.arena.allocator(), selector_text) catch return;
    // Every selector in the list shares one declaration block, so the masks are
    // hashed once for the whole rule rather than once per selector.
    const longhand_names = namesMask(props.longhands);
    const custom_names = namesMask(props.custom);
    for (selectors) |selector| {
        const rightmost = if (selector.segments.len > 0) selector.segments[selector.segments.len - 1].compound else selector.first;
        const bucket_key = getBucketKey(rightmost) orelse continue;
        const rule = Rule{
            .props = props,
            .selector = selector,
            .longhand_names = longhand_names,
            .custom_names = custom_names,
            .priority = (@as(u64, computeSpecificity(selector)) << SPEC_SHIFT) | @min(self.next_doc_order, MAX_DOC_ORDER),
        };
        self.next_doc_order += 1;
        try self.rule_layers.append(build_arena, layer);

        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena.allocator(), id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena.allocator(), rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena.allocator(), class);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena.allocator(), rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena.allocator(), tag);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena.allocator(), rule);
            },
            .other => {
                try self.other_rules.append(self.arena.allocator(), rule);
            },
        }
    }
}

/// Add the style rules nested inside `block_text` (css-nesting-1), each with
/// `&` resolved against `parent_selector`.
///
/// After the parent, not before: nested rules come later in document order, and
/// document order is the cascade's last tie-break.
///
/// A conditional group rule nested inside a style rule (`.a { @media … { … } }`)
/// goes through `addNestedAtRule` rather than `applyMediaAtRule`, because the
/// two put the inner block somewhere different: at the top level it holds
/// rules, and inside a style rule it holds *declarations belonging to the
/// enclosing selector* -- plus, optionally, further nested rules.
// Explicit rather than inferred because this and `addRawRuleAtDepth` call each
// other, and two inferred error sets in a cycle is a compile error.
fn addNestedRules(self: *StyleManager, build_arena: Allocator, parent_selector: []const u8, block_text: []const u8, layer: u16, depth: u8) Allocator.Error!void {
    if (depth >= MAX_NESTING_DEPTH) return;
    // A declaration block with no brace in it holds no nested rule, and that is
    // the overwhelming majority of them.
    if (std.mem.indexOfScalar(u8, block_text, '{') == null) return;

    var it = CssParser.parseNestedRules(block_text);
    while (it.next()) |nested| {
        switch (nested) {
            .style => |rule| {
                const resolved = nestedSelectorText(self.arena.allocator(), parent_selector, rule.selector) catch continue;
                if (resolved.len == 0) continue;
                try self.addRawRuleAtDepth(build_arena, resolved, rule.block, layer, depth + 1);
            },
            .at_rule => |a| try self.addNestedAtRule(build_arena, parent_selector, a, layer, depth),
        }
    }
}

/// One at-rule nested inside a style rule. Handing its block back to
/// `addRawRuleAtDepth` under the parent's selector is the whole trick: that is
/// what "these declarations belong to the enclosing selector" means, and it
/// carries `&` resolution and deeper nesting along with it.
///
/// Measured missing on Chrome 151, all seven rows of it
/// (scratch/b97/expr-b97-nested-at-rules.js): every declaration under a nested
/// `@media` / `@supports` / `@layer` was being dropped.
///
/// The at-rules absent from this dispatch are absent because Chrome applies
/// nothing for them either: `@container` finds no container-type ancestor,
/// `@starting-style` is not in a transition, and an unknown at-rule is dropped.
/// All three were measured as already matching, which is why adding them would
/// be a guess rather than a fix.
fn addNestedAtRule(self: *StyleManager, build_arena: Allocator, parent_selector: []const u8, at_rule: CssParser.AtRule, layer: u16, depth: u8) Allocator.Error!void {
    if (std.ascii.eqlIgnoreCase(at_rule.keyword, "media")) {
        const block = atRuleBlock(at_rule.text, "@media") orelse return;
        const query = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);
        if (MediaQuery.matches(query, self.frame.viewport()) == false) return;
        return self.addRawRuleAtDepth(build_arena, parent_selector, block.body, layer, depth + 1);
    }

    if (std.ascii.eqlIgnoreCase(at_rule.keyword, "supports")) {
        const block = atRuleBlock(at_rule.text, "@supports") orelse return;
        if (supports_condition.matches(build_arena, block.prelude) == false) return;
        return self.addRawRuleAtDepth(build_arena, parent_selector, block.body, layer, depth + 1);
    }

    if (std.ascii.eqlIgnoreCase(at_rule.keyword, "layer")) {
        // Block form only. A statement form here (`.a { @layer x; }`) declares
        // an ordering and has nothing nested under it to place.
        const block = atRuleBlock(at_rule.text, "@layer") orelse return;
        const prelude = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);
        if (prelude.len != 0 and isValidLayerName(prelude) == false) return;
        const id = if (prelude.len == 0)
            try self.internAnonymousLayer(build_arena, layer)
        else
            try self.registerLayerPath(build_arena, layer, prelude);
        return self.addRawRuleAtDepth(build_arena, parent_selector, block.body, id, depth + 1);
    }
}

/// The selector a nested rule matches, with `&` standing in for the parent.
///
/// `&` becomes `:is(<parent>)` rather than the parent's own text: a parent that
/// is a selector list has to collapse into one compound for the nested selector
/// to mean what it says, and `:is()` is how css-nesting-1 spells that. It keeps
/// the specificity right for free, since `:is()` takes its arguments' maximum,
/// which is what `computeSpecificity` already does with it.
///
/// A part carrying no `&` is a *descendant* of the parent -- css-nesting-1
/// prepends an implied one -- and every part of a list gets its own, so `#a,
/// #b` nested under `.p` is `:is(.p) #a, :is(.p) #b` and not a prefix on the
/// first alone.
///
/// Returns an empty slice for a selector with nothing left to match, which the
/// caller treats as a rule to drop. Deliberately not `?[]const u8`: an optional
/// slice return crashes the Zig 0.16 compiler backend, the same way it does in
/// `shorthand.valueClasses`.
fn nestedSelectorText(arena: Allocator, parent: []const u8, nested: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    var parts: TopLevelParts = .init(nested);
    var written: usize = 0;
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (written != 0) try out.writer.writeAll(", ");
        written += 1;
        try writeWithParent(&out.writer, parent, trimmed);
    }
    if (written == 0) return "";
    return out.written();
}

fn writeWithParent(writer: *std.Io.Writer, parent: []const u8, part: []const u8) !void {
    var tokenizer: Tokenizer = .{ .input = part };
    var depth: usize = 0;
    var copied: usize = 0;
    var saw_ampersand = false;

    while (true) {
        const at = tokenizer.position;
        const token = tokenizer.next() orelse break;
        switch (token) {
            .parenthesis_block, .function, .square_bracket_block, .curly_bracket_block => depth += 1,
            .close_parenthesis, .close_square_bracket, .close_curly_bracket => {
                if (depth > 0) depth -= 1;
            },
            // An `&` inside `:is(&)` or `[a=&]` belongs to whatever encloses it.
            .delim => |c| if (c == '&' and depth == 0) {
                try writer.writeAll(part[copied..at]);
                try writeParentRef(writer, parent);
                copied = tokenizer.position;
                saw_ampersand = true;
            },
            else => {},
        }
    }

    if (!saw_ampersand) {
        try writeParentRef(writer, parent);
        try writer.writeByte(' ');
    }
    try writer.writeAll(part[copied..]);
}

fn writeParentRef(writer: *std.Io.Writer, parent: []const u8) !void {
    try writer.writeAll(":is(");
    try writer.writeAll(parent);
    try writer.writeByte(')');
}

/// Splits a selector on the commas that separate its parts, ignoring the ones
/// inside `:is(…)` or an attribute selector. Tokenizer-driven so a comma in a
/// quoted attribute value cannot split anything.
const TopLevelParts = struct {
    input: []const u8,
    tokenizer: Tokenizer,
    start: usize = 0,
    finished: bool = false,

    fn init(input: []const u8) TopLevelParts {
        return .{ .input = input, .tokenizer = .{ .input = input } };
    }

    fn next(self: *TopLevelParts) ?[]const u8 {
        if (self.finished) return null;
        var depth: usize = 0;
        while (true) {
            const at = self.tokenizer.position;
            const token = self.tokenizer.next() orelse {
                self.finished = true;
                return self.input[self.start..];
            };
            switch (token) {
                .parenthesis_block, .function, .square_bracket_block, .curly_bracket_block => depth += 1,
                .close_parenthesis, .close_square_bracket, .close_curly_bracket => {
                    if (depth > 0) depth -= 1;
                },
                .comma => if (depth == 0) {
                    const part = self.input[self.start..at];
                    self.start = self.tokenizer.position;
                    return part;
                },
                else => {},
            }
        }
    }
};

pub fn sheetRemoved(self: *StyleManager) void {
    self.dirty = true;
    Frame.observers.scheduleResizeDelivery(self.frame);
}

pub fn sheetModified(self: *StyleManager) void {
    self.dirty = true;
    Frame.observers.scheduleResizeDelivery(self.frame);
}

/// Rebuilds the rule list from all document stylesheets.
/// Called lazily when dirty flag is set and rules are needed.
fn rebuildIfDirty(self: *StyleManager) !void {
    if (!self.dirty) {
        return;
    }

    // There are some allocations that only need to live for the duration of
    // this rebuild. Having two arena (build_arena and self.arena) isn't ideal
    // as it's easy to use the wrong one.
    const build_arena = try self.frame.getArena(.medium, "StyleManager.rebuild");
    defer {
        self.layers = .empty;
        self.layer_ids = .empty;
        self.next_anon_layer = 0;
        self.rule_layers = .empty;
        build_arena.release();
    }

    self.dirty = false;
    errdefer self.dirty = true;
    const id_rules_count = self.id_rules.count();
    const class_rules_count = self.class_rules.count();
    const tag_rules_count = self.tag_rules.count();
    const other_rules_count = self.other_rules.len;

    self.arena.resetRetain();

    // Both the cached answers and the maps holding them were allocated from that
    // arena, so these are `.empty` rather than a clear: the buckets are gone.
    self.cascade_cache = .empty;
    self.fixed_cascade_cache = .empty;
    self.rule_hiding_cache = .empty;

    self.next_doc_order = 1;

    self.id_rules = .empty;
    try self.id_rules.ensureTotalCapacity(self.arena.allocator(), id_rules_count);

    self.class_rules = .empty;
    try self.class_rules.ensureTotalCapacity(self.arena.allocator(), class_rules_count);

    self.tag_rules = .empty;
    try self.tag_rules.ensureTotalCapacity(self.arena.allocator(), tag_rules_count);

    self.other_rules = .{};
    try self.other_rules.ensureTotalCapacity(self.arena.allocator(), other_rules_count);

    self.declared_longhands = .empty;
    self.keyframes = .empty;

    // The cascade's own list, which unlike `document.styleSheets` also holds
    // the sheets living in shadow trees. See Document.cascadeStyleSheets.
    const sheets = self.frame.document._cascade_sheets orelse return;
    for (sheets._sheets.items) |sheet| {
        self.parseSheet(build_arena.allocator(), sheet) catch |err| {
            log.err(.browser, "StyleManager parseSheet", .{ .err = err });
            return err;
        };
    }

    try self.finalizeLayerRanks(build_arena.allocator());
}

// Check if an element is hidden based on options.
// By default only checks display:none.
// Walks up the tree to check ancestors.
pub fn isHidden(self: *StyleManager, el: *Element, cache: ?*VisibilityCache, options: CheckVisibilityOptions) bool {
    self.rebuildIfDirty() catch return false;

    // `display: contents` generates no box, so the element itself is not
    // visible and has no geometry -- but its descendants still render.
    // Measured on Chrome 151 (probe v1-contents): the contents element reads
    // `checkVisibility() === false` with a zero rect and no client rects,
    // while its child reads true with a box of its own. Hence the check sits
    // here, ahead of the ancestor walk and outside the cache: it is a verdict
    // about `el` alone, and caching it would leak onto every descendant.
    if (options.boxless_hidden and self.generatesNoBox(el)) {
        return true;
    }

    var current: ?*Element = el;

    while (current) |elem| {
        // Check cache first (only when checking all properties for caching consistency)
        if (cache) |c| {
            if (c.get(elem)) |hidden| {
                if (hidden) {
                    return true;
                }
                current = elem.parentElement();
                continue;
            }
        }

        const hidden = self.isElementHidden(elem, options);

        // Store in cache
        if (cache) |c| {
            c.put(self.frame.call_arena, elem, hidden) catch |err| {
                log.warn(.browser, "StyleManager cache", .{ .err = err, .src = "isHidden" });
            };
        }

        if (hidden) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Does `el` generate no box of its own? Only `display: contents` does that --
/// `none` is a different answer (no box *and* no subtree), and no per-tag UA
/// default is `contents`, so a null cascade is a no.
fn generatesNoBox(self: *StyleManager, el: *Element) bool {
    const value = self.computedDisplay(el) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "contents");
}

/// Computed display:none for a single element (own property, no ancestor walk).
/// Honors the UA stylesheet rules per HTML Rendering §15.3.1 "Hidden elements"
/// via `isElementHidden`.
pub fn hasDisplayNone(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    return self.isElementHidden(el, .{});
}

/// Computed display:none coming only from inline style or an author stylesheet
/// rule — the UA stylesheet's hidden elements (<head>, <script>, [hidden], …)
/// are NOT counted, so document scaffolding is preserved. Used by the HTML
/// dump's "invisible" strip mode.
pub fn hasAuthorDisplayNone(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    return self.isElementHidden(el, .{ .ua_display_none = false });
}

/// Centralizes UA-stylesheet display:none truth so `getComputedStyle().display`
/// (via `hasDisplayNone`) and `el.checkVisibility()` (via `isHidden`) agree.
/// Spec: HTML Rendering §15.3.1 "Hidden elements".
fn matchesUaDisplayNoneRule(el: *Element) bool {
    // Tag check first: O(1) switch, exits for the ~95% of elements with
    // ordinary tags before we touch the attribute list.
    const tag = el.getTag();
    if (tag.isHiddenByUaStylesheet()) return true;

    if (el.hasAttributeSafe(comptime .wrap("hidden"))) return true;

    // input[type="hidden" i] { display: none !important }
    // _input_type is parsed case-insensitively at attribute-set time.
    if (tag == .input) {
        if (el.is(Input)) |input| {
            if (input._input_type == .hidden) return true;
        }
    }

    // details:not([open]) > *:not(summary) { display: none }
    if (tag != .summary) {
        if (el.parentElement()) |parent| {
            if (parent.getTag() == .details and !parent.hasAttributeSafe(comptime .wrap("open"))) {
                return true;
            }
        }
    }

    return false;
}

/// Computed visibility:hidden for an element, considering only the `visibility`
/// chain (walks ancestors since `visibility` inherits by default). Ignores
/// display:none: an ancestor with display:none means the element isn't
/// rendered, but its computed `visibility` still reflects inherited visibility.
pub fn hasVisibilityHiddenInherited(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    var current: ?*Element = el;
    while (current) |elem| {
        if (self.isElementHidden(elem, .{ .check_display = false, .check_visibility = true })) {
            return true;
        }
        current = elem.parentElement();
    }
    return false;
}

/// The winning declaration for one of the three hiding properties, as a hides /
/// does-not-hide boolean plus what it took to win. Importance is tracked apart
/// from `priority` for two reasons: the packed priority has no bits left, and
/// CSS Cascade 4 §6.9 compares importance *before* specificity -- including the
/// style attribute's, which is ordinary specificity and not a tier of its own.
/// So an `!important` rule beats the style attribute and an `!important` style
/// attribute beats that (Chrome 151, probe t4-important).
const HidingWinner = struct {
    hides: ?bool = null,
    priority: u64 = 0,
    important: bool = false,

    // Pinned so that nothing can win it: for a property the caller did not ask
    // about, which keeps the rule loop from having to re-check the options.
    const unbeatable: HidingWinner = .{ .priority = INLINE_PRIORITY, .important = true };

    fn isUnbeatable(self: HidingWinner) bool {
        return self.important and self.priority == INLINE_PRIORITY;
    }

    fn beatenBy(self: HidingWinner, priority: u64, important: bool) bool {
        if (important != self.important) {
            return important;
        }
        return priority > self.priority;
    }

    fn set(self: *HidingWinner, hides: bool, priority: u64, important: bool) void {
        self.hides = hides;
        self.priority = priority;
        self.important = important;
    }
};

/// Check if a single element (not ancestors) is hidden.
fn isElementHidden(self: *StyleManager, el: *Element, options: CheckVisibilityOptions) bool {
    var display: HidingWinner = .{};
    var visibility: HidingWinner = .{};
    var opacity: HidingWinner = .{};

    // The style attribute first: it outranks every rule of equal importance, so
    // recording it up front lets the rule loop compare against one value.
    if (options.check_display) {
        if (getInlineStyleProperty(el, comptime .wrap("display"), self.frame)) |property| {
            const hides = property._value.eql(comptime .wrap("none"));
            if (hides and property._important) {
                return true; // nothing outranks an important style attribute
            }
            display.set(hides, INLINE_PRIORITY, property._important);
        }
    } else {
        display = HidingWinner.unbeatable;
    }

    if (options.check_visibility) {
        if (getInlineStyleProperty(el, comptime .wrap("visibility"), self.frame)) |property| {
            const hides = property._value.eql(comptime .wrap("hidden")) or property._value.eql(comptime .wrap("collapse"));
            if (hides and property._important) {
                return true;
            }
            visibility.set(hides, INLINE_PRIORITY, property._important);
        }
    } else {
        visibility = HidingWinner.unbeatable;
    }

    if (options.check_opacity) {
        if (getInlineStyleProperty(el, comptime .wrap("opacity"), self.frame)) |property| {
            const hides = property._value.eql(comptime .wrap("0"));
            if (hides and property._important) {
                return true;
            }
            opacity.set(hides, INLINE_PRIORITY, property._important);
        }
    } else {
        opacity = HidingWinner.unbeatable;
    }

    if (display.isUnbeatable() and visibility.isUnbeatable() and opacity.isUnbeatable()) {
        return (display.hides orelse false) or (visibility.hides orelse false) or (opacity.hides orelse false);
    }

    // The rule scan used to run seeded with the inline values above, which let
    // it skip any rule that could not beat them. Splitting it out costs that
    // pruning and buys something worth more: the answer no longer depends on
    // the element's inline style, and an answer that depends only on the rules
    // and the tree is one that can be remembered.
    //
    // The merge is the same verdict the seeded loop reached. `beatenBy` is a
    // total order on (important, priority), the seeded loop's winner is
    // `max(inline, every matching rule)`, and max is associative -- so taking
    // the max over rules first and comparing that to the inline seed lands on
    // the same rule. `unbeatable` sits at INLINE_PRIORITY with important set, so
    // a property the caller did not ask about still cannot be beaten.
    const from_rules = self.ruleHiding(el);
    if (from_rules.display.hides != null and
        display.beatenBy(from_rules.display.priority, from_rules.display.important))
    {
        display = from_rules.display;
    }
    if (from_rules.visibility.hides != null and
        visibility.beatenBy(from_rules.visibility.priority, from_rules.visibility.important))
    {
        visibility = from_rules.visibility;
    }
    if (from_rules.opacity.hides != null and
        opacity.beatenBy(from_rules.opacity.priority, from_rules.opacity.important))
    {
        opacity = from_rules.opacity;
    }

    // UA stylesheet display:none fallback (HTML Rendering §15.3.1 "Hidden
    // elements"). Applied only when nothing authored a `display` for the
    // element — per CSS Cascade §6.1 any normal-origin author rule beats UA
    // origin regardless of specificity, so `.x { display: flex }` on a
    // `<div class="x" hidden>` must report visible.
    if (options.check_display and options.ua_display_none and display.hides == null) {
        if (matchesUaDisplayNoneRule(el)) {
            display.hides = true;
        }
    }

    return (display.hides orelse false) or (visibility.hides orelse false) or (opacity.hides orelse false);
}

/// What the stylesheet rules alone say about an element's three hiding
/// properties. No inline style, no UA fallback and no `options`: those are the
/// caller's to apply, and leaving them out is what makes this answer a function
/// of the rules and the tree only.
const RuleHiding = struct {
    display: HidingWinner = .{},
    visibility: HidingWinner = .{},
    opacity: HidingWinner = .{},
};

fn ruleHiding(self: *StyleManager, el: *Element) RuleHiding {
    self.dropCachesIfDomMoved();
    if (self.rule_hiding_cache.get(el)) |cached| {
        return cached;
    }

    var out: RuleHiding = .{};

    // Helper to check a single rule
    const Ctx = struct {
        display: *HidingWinner,
        visibility: *HidingWinner,
        opacity: *HidingWinner,
        el: *Element,
        frame: *Frame,

        fn checkRules(ctx: @This(), rules: *const RuleList) void {
            if (ctx.display.isUnbeatable() and ctx.visibility.isUnbeatable() and ctx.opacity.isUnbeatable()) {
                return;
            }

            const priorities = rules.items(.priority);
            const props_list = rules.items(.props);
            const selectors = rules.items(.selector);

            for (priorities, props_list, selectors) |p, props, selector| {
                // Would any of the three declarations this rule carries win?
                // Cheaper than matchesSelector, so it runs first.
                const wins = (props.display_none != null and ctx.display.beatenBy(p, props.display_none_important)) or
                    (props.visibility_hidden != null and ctx.visibility.beatenBy(p, props.visibility_hidden_important)) or
                    (props.opacity_zero != null and ctx.opacity.beatenBy(p, props.opacity_zero_important));

                if (!wins) continue;

                if (matchesSelector(ctx.el, selector, ctx.frame)) {
                    if (props.display_none) |hides| {
                        if (ctx.display.beatenBy(p, props.display_none_important)) {
                            ctx.display.set(hides, p, props.display_none_important);
                        }
                    }
                    if (props.visibility_hidden) |hides| {
                        if (ctx.visibility.beatenBy(p, props.visibility_hidden_important)) {
                            ctx.visibility.set(hides, p, props.visibility_hidden_important);
                        }
                    }
                    if (props.opacity_zero) |hides| {
                        if (ctx.opacity.beatenBy(p, props.opacity_zero_important)) {
                            ctx.opacity.set(hides, p, props.opacity_zero_important);
                        }
                    }
                }
            }
        }
    };
    const ctx = Ctx{
        .display = &out.display,
        .visibility = &out.visibility,
        .opacity = &out.opacity,
        .el = el,
        .frame = self.frame,
    };

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            ctx.checkRules(&rules);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                ctx.checkRules(&rules);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        ctx.checkRules(&rules);
    }

    ctx.checkRules(&self.other_rules);

    // "No rule hides this element" is the usual answer and cost the same walk,
    // so it is kept like any other.
    if (self.rule_hiding_cache.count() < MAX_CASCADE_CACHE) {
        self.rule_hiding_cache.put(self.arena.allocator(), el, out) catch {};
    }

    return out;
}

/// Check if an element has pointer-events:none.
/// Checks inline style first - if set, skips stylesheet lookup.
/// Walks up the tree to check ancestors.
pub fn hasPointerEventsNone(self: *StyleManager, el: *Element, cache: ?*PointerEventsCache) bool {
    self.rebuildIfDirty() catch return false;

    var current: ?*Element = el;

    while (current) |elem| {
        // Check cache first
        if (cache) |c| {
            if (c.get(elem)) |pe_none| {
                if (pe_none) return true;
                current = elem.parentElement();
                continue;
            }
        }

        const pe_none = self.elementHasPointerEventsNone(elem);

        if (cache) |c| {
            c.put(self.frame.call_arena, elem, pe_none) catch |err| {
                log.warn(.browser, "StyleManager cache", .{ .err = err, .src = "hasPointerEventsNone" });
            };
        }

        if (pe_none) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Check if a single element (not ancestors) has pointer-events:none.
fn elementHasPointerEventsNone(self: *StyleManager, el: *Element) bool {
    const frame = self.frame;

    // Check inline style first
    if (getInlineStyleProperty(el, .wrap("pointer-events"), frame)) |property| {
        if (property._value.eql(comptime .wrap("none"))) {
            return true;
        }
        return false;
    }

    var result: ?bool = null;
    var best_priority: u64 = 0;

    // Helper to check a single rule
    const checkRules = struct {
        fn check(rules: *const RuleList, res: *?bool, current_priority: *u64, elem: *Element, p: *Frame) void {
            if (current_priority.* == INLINE_PRIORITY) return;

            const priorities = rules.items(.priority);
            const props_list = rules.items(.props);
            const selectors = rules.items(.selector);

            for (priorities, props_list, selectors) |priority, props, selector| {
                if (priority <= current_priority.*) continue;
                if (props.pointer_events_none == null) continue;

                if (matchesSelector(elem, selector, p)) {
                    res.* = props.pointer_events_none;
                    current_priority.* = priority;
                }
            }
        }
    }.check;

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            checkRules(&rules, &result, &best_priority, el, frame);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                checkRules(&rules, &result, &best_priority, el, frame);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        checkRules(&rules, &result, &best_priority, el, frame);
    }

    checkRules(&self.other_rules, &result, &best_priority, el, frame);

    return result orelse false;
}

// Extracts the rules we resolve from a CSS rule.
// Creates one Rule per selector (not per selector list) so each has correct specificity.
// Buckets rules by their rightmost selector part for fast lookup.
fn addRule(self: *StyleManager, build_arena: Allocator, style_rule: *CSSStyleRule) !void {
    const selector_text = style_rule._selector_text;
    if (selector_text.len == 0) {
        return;
    }

    // Check if the rule declares anything we resolve
    const style = style_rule._style orelse return;
    const props = try extractRuleProperties(self.arena.allocator(), style);
    try self.indexLonghands(props);
    if (!props.isRelevant()) {
        return;
    }

    // Parse the selector list
    const selectors = SelectorParser.parseList(self.arena.allocator(), selector_text) catch return;
    if (selectors.len == 0) {
        return;
    }

    // Every selector in the list shares one declaration block, so the masks are
    // hashed once for the whole rule rather than once per selector.
    const longhand_names = namesMask(props.longhands);
    const custom_names = namesMask(props.custom);

    // Create one rule per selector - each has its own specificity
    // e.g., "#id, .class { display: none }" becomes two rules with different specificities
    for (selectors) |selector| {
        // Get the rightmost compound (last segment, or first if no segments)
        const rightmost = if (selector.segments.len > 0)
            selector.segments[selector.segments.len - 1].compound
        else
            selector.first;

        // Find the bucketing key from rightmost compound
        const bucket_key = getBucketKey(rightmost) orelse continue; // skip if dynamic pseudo-class

        const rule = Rule{
            .props = props,
            .selector = selector,
            .longhand_names = longhand_names,
            .custom_names = custom_names,
            .priority = (@as(u64, computeSpecificity(selector)) << SPEC_SHIFT) | @min(self.next_doc_order, MAX_DOC_ORDER),
        };
        self.next_doc_order += 1;
        try self.rule_layers.append(build_arena, NO_LAYER);

        // Add to appropriate bucket
        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena.allocator(), id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena.allocator(), rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena.allocator(), class);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena.allocator(), rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena.allocator(), tag);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena.allocator(), rule);
            },
            .other => {
                try self.other_rules.append(self.arena.allocator(), rule);
            },
        }
    }
}

const BucketKey = union(enum) {
    id: []const u8,
    class: []const u8,
    tag: Tag,
    other,
};

/// Returns the best bucket key for a compound selector, or null if it contains
/// a dynamic pseudo-class we should skip (hover, active, focus, etc.)
/// Priority: id > class > tag > other
fn getBucketKey(compound: Selector.Compound) ?BucketKey {
    var best_key: BucketKey = .other;

    for (compound.parts) |part| {
        switch (part) {
            .id => |id| {
                best_key = .{ .id = id };
            },
            .class => |class| {
                if (best_key != .id) {
                    best_key = .{ .class = class };
                }
            },
            .tag => |tag| {
                if (best_key == .other) {
                    best_key = .{ .tag = tag };
                }
            },
            .tag_name => {
                // Custom tag - put in other bucket (can't efficiently look up)
                // Keep current best_key if we have something better
            },
            .pseudo_class => |pc| {
                // Skip dynamic pseudo-classes - they depend on interaction state
                switch (pc) {
                    .hover, .active, .focus, .focus_within, .focus_visible, .visited, .target => {
                        return null; // Skip this selector entirely
                    },
                    else => {},
                }
            },
            // A compound holding a pseudo-element matches no element, so which
            // bucket it lands in cannot matter -- but it must not be dropped
            // either, because the compounds BESIDE it in the list are the
            // reason it parses at all.
            .universal, .attribute, .pseudo_element => {},
        }
    }

    return best_key;
}

/// Extracts the properties we resolve from a style declaration. `arena` owns
/// the copies of any value we keep verbatim: the declaration belongs to the
/// stylesheet, which outlives no rebuild in particular.
/// Records the longhand names a rule declares, so a lookup for a name nothing
/// declares can stop at one hash probe.
fn indexLonghands(self: *StyleManager, props: RuleProperties) !void {
    for (props.longhands) |declaration| {
        try self.declared_longhands.put(self.arena.allocator(), declaration.name, {});
    }
}

fn extractRuleProperties(arena: Allocator, style: *CSSStyleDeclaration) !RuleProperties {
    var props = RuleProperties{};
    const decl = style;

    if (decl.findProperty(comptime .wrap("font-size"))) |property| {
        props.font_size = .{
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
        };
    }

    if (decl.findProperty(comptime .wrap("font-family"))) |property| {
        props.font_family = .{
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
        };
    }

    if (decl.findProperty(String.wrap("text-transform"))) |property| {
        props.text_transform = .{
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
        };
    }

    if (decl.findProperty(comptime .wrap("display"))) |property| {
        props.display_none = property._value.eql(comptime .wrap("none"));
        props.display_none_important = property._important;
        props.display = .{
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
        };
    }

    if (decl.findProperty(comptime .wrap("visibility"))) |property| {
        props.visibility_hidden = property._value.eql(comptime .wrap("hidden")) or property._value.eql(comptime .wrap("collapse"));
        props.visibility_hidden_important = property._important;
        props.visibility = .{
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
        };
    }

    if (decl.findProperty(comptime .wrap("opacity"))) |property| {
        props.opacity_zero = property._value.eql(comptime .wrap("0"));
        props.opacity_zero_important = property._important;
    }

    if (decl.findProperty(.wrap("pointer-events"))) |property| {
        props.pointer_events_none = property._value.eql(comptime .wrap("none"));
    }

    var custom: std.ArrayList(NamedDeclaration) = .empty;
    var longhands: std.ArrayList(NamedDeclaration) = .empty;
    var node = decl._properties.first;
    while (node) |n| : (node = n.next) {
        const property = CSSStyleProperty.fromNodeLink(n);
        const name = property._name.str();
        const entry: NamedDeclaration = .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
            .specified = property._specified,
            .raw = if (property._raw) |*raw| try arena.dupe(u8, raw.str()) else null,
        };
        // This path reads a materialised CSSOM declaration, whose shorthands
        // the declaration's own parser already expanded -- unlike the raw one,
        // which has to expand them itself.
        if (CSSStyleDeclaration.isCustomProperty(name)) {
            try custom.append(arena, entry);
        } else {
            try longhands.append(arena, entry);
        }
    }
    props.custom = custom.items;
    props.longhands = longhands.items;

    return props;
}

/// A lower-case copy of `name`, for the by-name lookups. The raw parser hands
/// declaration names back as the sheet spelled them and CSS property names are
/// ASCII case-insensitive, so `COLOR:red` has to answer a lookup for `color`.
fn lowerDuped(arena: Allocator, name: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, name.len);
    return std.ascii.lowerString(out, name);
}

/// The canonical spelling of a raw declaration's value. The CSSOM path's
/// declarations went through storeProperty and are already canonical; the raw
/// path's are whatever the author typed, and a computed style has to report the
/// same string either way -- `rgb(1,2,3)` reads back `rgb(1, 2, 3)` on both.
///
/// No copy either way: what it hands back is either freshly allocated on
/// `arena` or a slice of the sheet text, which parseSheet already put on the
/// same arena. That is why the reduced fields above store `val` unowned too.
fn canonicalValue(arena: Allocator, property_name: []const u8, raw: []const u8) []const u8 {
    return CSSStyleDeclaration.normalizePropertyValue(arena, property_name, raw) catch raw;
}

// Computes CSS specificity for a selector.
// Returns packed value: (id_count << 20) | (class_count << 10) | element_count
pub fn computeSpecificity(selector: Selector.Selector) u32 {
    var ids: u32 = 0;
    var classes: u32 = 0; // includes classes, attributes, pseudo-classes
    var elements: u32 = 0; // includes elements, pseudo-elements

    // Count specificity for first compound
    countCompoundSpecificity(selector.first, &ids, &classes, &elements);

    // Count specificity for subsequent segments
    for (selector.segments) |segment| {
        countCompoundSpecificity(segment.compound, &ids, &classes, &elements);
    }

    // Pack into single u32: (ids << 20) | (classes << 10) | elements
    // This gives us 10 bits each, supporting up to 1023 of each type
    return (@as(u32, @min(ids, 1023)) << 20) | (@as(u32, @min(classes, 1023)) << 10) | @min(elements, 1023);
}

fn countCompoundSpecificity(compound: Selector.Compound, ids: *u32, classes: *u32, elements: *u32) void {
    for (compound.parts) |part| {
        switch (part) {
            .id => ids.* += 1,
            .class => classes.* += 1,
            .tag, .tag_name => elements.* += 1,
            .universal => {}, // zero specificity
            // A pseudo-element counts as an element, the way a type selector
            // does -- per Selectors 4, and it costs nothing to be right about
            // it here since nothing matches through one anyway.
            .pseudo_element => elements.* += 1,
            .attribute => classes.* += 1,
            .pseudo_class => |pc| {
                switch (pc) {
                    // :where() has zero specificity
                    .where => {},
                    // :not(), :is(), :has() take specificity of their most specific argument
                    .not, .is, .has => |nested| {
                        var max_nested: u32 = 0;
                        for (nested) |nested_sel| {
                            const spec = computeSpecificity(nested_sel);
                            if (spec > max_nested) max_nested = spec;
                        }
                        // Unpack and add to our counts
                        ids.* += (max_nested >> 20) & 0x3FF;
                        classes.* += (max_nested >> 10) & 0x3FF;
                        elements.* += max_nested & 0x3FF;
                    },
                    // All other pseudo-classes count as class-level specificity
                    else => classes.* += 1,
                }
            },
        }
    }
}

fn matchesSelector(el: *Element, selector: Selector.Selector, frame: *Frame) bool {
    const node = el.asNode();
    return SelectorList.matches(node, selector, node, frame);
}

/// A declaration we keep verbatim rather than reducing to a flag, because the
/// caller needs the value and not just its presence.
pub const Declaration = struct {
    value: []const u8,
    important: bool,
    /// The number the author wrote, when the whole declaration was one numeric
    /// token. `value` is its six-significant-figure print, which the layout is
    /// not allowed to read back -- CSSStyleDeclaration.specifiedNumber says why.
    specified: ?f64 = null,
    /// The TEXT the author wrote, for the properties whose value is a function
    /// and whose numbers therefore cannot be carried in `specified` -- one f64
    /// does not hold `rotate(45deg) translateX(3px)`. Same reason as `specified`
    /// and the same rule: `value` is the print, this is what to compute from.
    /// Null when there is nothing to keep, which is every property that has no
    /// consumer for it -- see `keepsAuthorText`.
    raw: ?[]const u8 = null,
};

const RuleProperties = struct {
    // `display_none` is the visibility answer (isElementHidden and everything
    // built on it); `display` is the value itself, which innerText and
    // getComputedStyle need and a boolean cannot carry. Both are filled from
    // the same declaration rather than one deriving from the other, because the
    // hidden-element path predates the value and must keep its exact semantics.
    display_none: ?bool = null,
    display: ?Declaration = null,
    // Importance of the declaration each reduced boolean came from. It cannot be
    // folded into the packed `priority`, which is full, and importance outranks
    // specificity anyway -- including the style attribute's, which is why
    // isElementHidden has to carry it per property (a rule can declare
    // `display:none!important; visibility:hidden` and mean both).
    display_none_important: bool = false,
    visibility_hidden_important: bool = false,
    opacity_zero_important: bool = false,
    // Same split as display, and for the same reason: `visibility_hidden` is
    // what isElementHidden reduces the declaration to, `visibility` is the
    // keyword itself, which innerText needs because `visibility` inherits and a
    // descendant declaring `visible` has to be able to outrank a hidden
    // ancestor -- a boolean that has already forgotten which element declared
    // what cannot answer that.
    visibility_hidden: ?bool = null,
    visibility: ?Declaration = null,
    opacity_zero: ?bool = null,
    pointer_events_none: ?bool = null,
    font_size: ?Declaration = null,
    font_family: ?Declaration = null,
    text_transform: ?Declaration = null,
    // Every custom property the rule declares, in declaration order. Unlike
    // the fields above there is no fixed set of names to pick from, and a page
    // can read any of them back through getComputedStyle.
    custom: []const NamedDeclaration = &.{},
    // ...and every *standard* longhand it declares, for the same reason: a page
    // can read any of them back too, and there is no fixed set worth picking
    // from once the answer has to be right for all of them.
    //
    // The named fields above stay rather than being folded into this list. They
    // are read on the hidden-element path, which runs per element per layout
    // question, and a field access is not a name scan.
    longhands: []const NamedDeclaration = &.{},

    // return true if any field in RuleProperties is not null
    fn isRelevant(self: RuleProperties) bool {
        return self.display_none != null or
            self.display != null or
            self.visibility_hidden != null or
            self.visibility != null or
            self.opacity_zero != null or
            self.pointer_events_none != null or
            self.font_size != null or
            self.font_family != null or
            self.text_transform != null or
            self.custom.len > 0 or
            self.longhands.len > 0;
    }
};

pub const NamedDeclaration = struct {
    name: []const u8,
    value: []const u8,
    important: bool,
    /// As Declaration.specified: the author's number beside its print.
    specified: ?f64 = null,
    /// As Declaration.raw: the author's text beside its print.
    raw: ?[]const u8 = null,
};

/// One longhand as the cascade keeps it: the canonical print to read back, the
/// author's number where a single token carried one, and the author's text where
/// a function's numbers cannot fit in that.
///
/// Written once and called from each expansion branch rather than repeated: the
/// five branches held byte-identical initialisers, and the whole point of the
/// two extra fields is that every branch has to fill them the same way.
fn namedDeclaration(arena: Allocator, name: []const u8, raw: []const u8, important: bool) NamedDeclaration {
    const canonical = canonicalValue(arena, name, raw);
    return .{
        .name = name,
        .value = canonical,
        .important = important,
        .specified = CSSStyleDeclaration.specifiedNumber(raw),
        .raw = CSSStyleDeclaration.authorText(arena, name, raw, canonical),
    };
}

const CascadeKey = struct {
    element: *Element,
    name: []const u8,
    which: NamedList,
};

const CascadeCache = std.HashMapUnmanaged(CascadeKey, ?Declaration, struct {
    pub fn hash(_: @This(), key: CascadeKey) u64 {
        var hasher = std.hash.Wyhash.init(@intFromEnum(key.which));
        hasher.update(std.mem.asBytes(&@intFromPtr(key.element)));
        hasher.update(key.name);
        return hasher.final();
    }
    pub fn eql(_: @This(), a: CascadeKey, b: CascadeKey) bool {
        return a.element == b.element and a.which == b.which and std.mem.eql(u8, a.name, b.name);
    }
}, 80);

const FixedCascadeKey = struct {
    element: *Element,
    property: CascadedProperty,
};

const FixedCascadeCache = std.AutoHashMapUnmanaged(FixedCascadeKey, ?Declaration);

const RuleHidingCache = std.AutoHashMapUnmanaged(*Element, RuleHiding);

/// Ceiling on cached answers. A page with a hundred thousand elements would
/// otherwise hold an entry per element per property asked, and the cache is
/// meant to pay for repeated reads of the same document, not to grow with it
/// without bound. Past the cap reads still answer correctly, just uncached.
const MAX_CASCADE_CACHE = 1 << 17;

/// Two bits per name in a 128-bit word, so a property read can ask "can this
/// rule possibly declare it" without touching the rule's declaration list.
///
/// `declared_longhands` already answers that question for the document as a
/// whole; this answers it per rule, which is the loop that costs. A read walks
/// every rule keyed to the element's id, classes and tag, and inside each one
/// compared the wanted name against every declaration the rule carries. That
/// inner scan is what the cost tracks: holding the rule and node counts fixed
/// and only growing the declarations per rule took one read from 127ms at one
/// declaration to 963ms at twenty-four (scratch/b99/cascade-cost.mjs --decls).
///
/// A false positive costs only the scan that used to happen unconditionally, so
/// the filter can never change an answer -- it can only skip rules that were
/// always going to miss.
fn nameMask(name: []const u8) u128 {
    const h = std.hash.Wyhash.hash(0, name);
    const a: u7 = @truncate(h);
    const b: u7 = @truncate(h >> 32);
    return (@as(u128, 1) << a) | (@as(u128, 1) << b);
}

/// The union of `nameMask` over a declaration list, built once per rule.
fn namesMask(declarations: []const NamedDeclaration) u128 {
    var mask: u128 = 0;
    for (declarations) |declaration| mask |= nameMask(declaration.name);
    return mask;
}

const Rule = struct {
    selector: Selector.Selector, // Single selector, not a list
    props: RuleProperties,

    /// `nameMask` over props.longhands and props.custom respectively. Kept on
    /// the Rule rather than in RuleProperties so the reject reads one word out
    /// of a MultiArrayList column instead of reaching into the properties.
    longhand_names: u128,
    custom_names: u128,

    // Packed priority: layer_rank:12 | specificity:30 | doc_order:22.
    // The rank bits are 0 until finalizeLayerRanks stamps them (the rank
    // isn't known until all sheets are parsed); the rule's layer lives in
    // the build-only rule_layers side array, indexed by doc_order - 1.
    priority: u64,
};

const Layer = struct {
    // dotted path from the root
    path: []const u8,

    // Number of path components
    depth: u16,

    // Index of the parent layer in `layers` (NO_LAYER for top level)
    parent: u16,

    /// Position in the final cascade order, lowest priority first.
    rank: u32 = 0,
};

/// This sentinel has two meanings. AS a rule's layer, it's the highest priority
/// (rules outside of a layer are highest priority). As a Layer.parent, it means
// no paren (top-level layer)
const NO_LAYER: u16 = std.math.maxInt(u16);

const UNLAYERED_RANK: u32 = std.math.maxInt(u12);

/// Protect against hostile input. Must be < UNLAYERED_RANK so that it fits in
// its 12 bits of VisibleRule.priority
const MAX_LAYERS: usize = 1024;

// Rule.priority field offsets (layer_rank:12 | spec:30 | doc:22).
const SPEC_SHIFT: u6 = 22;
const RANK_SHIFT: u6 = 52;

// - 1 since INLINE_PRIORITY is _always_ higher
const MAX_DOC_ORDER: u32 = std.math.maxInt(u22) - 1;

const CheckVisibilityOptions = struct {
    check_display: bool = true,
    check_visibility: bool = false,
    check_opacity: bool = false,
    ua_display_none: bool = true,
    // Count an element that generates no box of its own -- `display: contents`
    // -- as hidden. Off by default because most callers want the opposite: the
    // accessibility tree keeps such an element rather than pruning its subtree,
    // and `getComputedStyle().display` has to keep reporting `contents`.
    // `checkVisibility` and the geometry keyed off it are the ones that opt in.
    boxless_hidden: bool = false,
};

// Inline styles always win over stylesheets - use max u64 as sentinel.
// Strictly above any packed rule priority: doc_order saturates one below
// its field max, so a real rule can never pack to all-ones.
const INLINE_PRIORITY: u64 = std.math.maxInt(u64);

// `frame` is the StyleManager's frame, which callers guarantee is el's owner
// frame (el.ownerFrame) — the map where the materialized style lives.
fn getInlineStyleProperty(el: *Element, property_name: String, frame: *Frame) ?*CSSStyleProperty {
    const style = frame._element_styles.get(el) orelse blk: {
        // No JS-set style object and no style attribute -> nothing inline to read.
        if (el.getAttributeSafe(comptime .wrap("style")) == null) return null;
        break :blk el.getOrCreateStyle(frame) catch |err| {
            log.err(.browser, "StyleManager getOrCreateStyle", .{ .err = err });
            return null;
        };
    };
    return style.findProperty(property_name);
}

/// Resolved value of an element's inline `style=` declaration for `property_name`,
/// or null when the element has no such declaration. Reads the element's parsed
/// inline style (the same source `el.style` exposes), so `getComputedStyle` and
/// `el.style` agree on inline values instead of resolving them independently.
pub fn inlineStyleValue(self: *StyleManager, el: *Element, property_name: String) ?[]const u8 {
    const property = getInlineStyleProperty(el, property_name, self.frame) orelse return null;
    return property._value.str();
}

/// The same declaration with its importance, for the callers that have to rank
/// it against a rule. The style attribute is the highest specificity rather
/// than a tier of its own, so an `!important` rule beats it and an `!important`
/// style attribute beats that (CSS Cascade 4 §6.9; see
/// css/important_vs_inline.html).
pub fn inlineStyleDeclaration(self: *StyleManager, el: *Element, property_name: String) ?Declaration {
    const property = getInlineStyleProperty(el, property_name, self.frame) orelse return null;
    return .{
        .value = property._value.str(),
        .important = property._important,
        .specified = property._specified,
        // Captured BY POINTER. `String` is a German string: a short one lives
        // in the struct's own bytes, so `str()` on a by-value capture of the
        // optional hands out a slice into a temporary that dies with the `if`.
        // Measured: `scale(1e-6)` (11 bytes, inline) came back as
        // `qqqqqqqqqqqqqqo` and refused to parse, while
        // `rotate(1.5707963267948966rad)` (31 bytes, heap) was fine.
        .raw = if (property._raw) |*raw| raw.str() else null,
    };
}

/// Bounds computedFontSize's ancestor recursion (the parent walk and
/// `inherit`/relative-unit chains share it).
const MAX_FONT_ANCESTOR_DEPTH = 32;

/// Computed font-size in CSS pixels, cascading the three author sources CSS
/// orders — `!important` first, then the inline declaration, then normal
/// declarations, with the presentation attribute below every rule — and
/// inheriting up the parent chain when the element declares nothing.
pub fn computedFontSize(self: *StyleManager, element: ?*Element) f64 {
    return self.computedFontSizeAt(element, 0);
}

fn computedFontSizeAt(self: *StyleManager, element: ?*Element, depth: u8) f64 {
    if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
        return 16;
    }
    const current = element orelse return 16;
    const parent = current.parentElement();

    const inline_property = getInlineStyleProperty(current, comptime .wrap("font-size"), self.frame);
    const rule = self.cascadedFontSize(current);

    // An `!important` rule beats the inline declaration unless that one is
    // itself `!important` (CSS Cascade §6.2: same origin, importance first,
    // then the style attribute).
    if (rule) |declaration| {
        if (declaration.important and !(inline_property != null and inline_property.?._important)) {
            if (self.parseFontSize(declaration.value, parent, depth + 1)) |size| {
                return size;
            }
        }
    }
    if (inline_property) |property| {
        if (self.parseFontSize(property._value.str(), parent, depth + 1)) |size| {
            return size;
        }
    }
    if (rule) |declaration| {
        if (self.parseFontSize(declaration.value, parent, depth + 1)) |size| {
            return size;
        }
    }
    if (current.getAttributeSafe(comptime .wrap("font-size"))) |raw| {
        if (self.parseFontSize(raw, parent, depth + 1)) |size| {
            return size;
        }
    }
    // The UA stylesheet, which declares a font on the element ITSELF and so
    // outranks anything inherited from an ancestor. Leaving it out is why a
    // bare `<input>` laid out at the inherited 16px while `getComputedStyle`
    // read it back as the UA's 13.3333px -- the two surfaces disagreed, and the
    // layout was the one that was wrong.
    if (userAgentFontProperty(current, "font-size")) |raw| {
        if (self.parseFontSize(raw, parent, depth + 1)) |size| {
            return size;
        }
    }
    return self.computedFontSizeAt(parent, depth + 1);
}

/// A font declaration the UA stylesheet makes on this tag, or null where it
/// makes none. The same table `getComputedStyle` answers from, so the layout
/// and the computed-style surface cannot drift apart again.
fn userAgentFontProperty(element: *Element, comptime property: []const u8) ?[]const u8 {
    return userAgentValue(element, property);
}

/// Any declaration the UA stylesheet makes on this tag, or null where it makes
/// none -- the same table, opened up because the fonts were not the only thing
/// reading it out of the cascade's reach.
///
/// The margins are the other: nothing but `<body>` had a case for them, so the
/// stacking walk read 0 for `<p>`'s `margin: 1em 0` while `getComputedStyle`
/// answered `16px` off this table. Chrome puts `<div><p>x</p></div>` as body's
/// first child at y=16 and this engine put it at 8
/// (scratch/b99/expr-escape-with-text.js: an explicit `margin-top:16px` on a
/// plain div was already right, so it was the UA half alone).
pub fn userAgentValue(element: *Element, property: []const u8) ?[]const u8 {
    const rows = chrome_per_tag_values.per_tag.get(element.getTagNameLower()) orelse return null;
    return rows.get(property);
}

/// Cascaded `text-transform` keyword, or null when nothing declares one
/// anywhere up the chain. Same source order and inheritance walk as
/// computedFontFamily, minus its presentational-attribute step: `text-transform`
/// has no HTML attribute form. `innerText` is the caller -- it is defined in
/// terms of layout, so it reports text the way this says it is rendered.
pub fn computedTextTransform(self: *StyleManager, element: ?*Element) ?[]const u8 {
    return self.computedTextTransformAt(element, 0);
}

fn computedTextTransformAt(self: *StyleManager, element: ?*Element, depth: u8) ?[]const u8 {
    if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
        return null;
    }
    const current = element orelse return null;

    // "text-transform" is 14 bytes, past String's 12-byte SSO limit, so the
    // wrap has to happen at runtime -- same as String.wrap("preserveAspectRatio").
    const inline_property = getInlineStyleProperty(current, String.wrap("text-transform"), self.frame);
    const rule = self.cascadedDeclaration(current, .text_transform);

    if (rule) |declaration| {
        if (declaration.important and !(inline_property != null and inline_property.?._important)) {
            return declaration.value;
        }
    }
    if (inline_property) |property| {
        return property._value.str();
    }
    if (rule) |declaration| {
        return declaration.value;
    }
    return self.computedTextTransformAt(current.parentElement(), depth + 1);
}

/// Cascaded `display` keyword, or null when neither a stylesheet rule nor the
/// inline style declares one -- the caller then falls back to the per-tag UA
/// default it already has. Same source order as computedFontFamily, minus the
/// ancestor walk: `display` does not inherit (measured on Chrome 151, probe
/// d2-cascade -- a span inside a `display: inline-block` div reads `inline`).
pub fn computedDisplay(self: *StyleManager, element: *Element) ?[]const u8 {
    const inline_property = getInlineStyleProperty(element, comptime .wrap("display"), self.frame);
    const rule = self.cascadedDeclaration(element, .display);

    if (rule) |declaration| {
        if (declaration.important and !(inline_property != null and inline_property.?._important)) {
            return declaration.value;
        }
    }
    if (inline_property) |property| {
        return property._value.str();
    }
    if (rule) |declaration| {
        return declaration.value;
    }
    return null;
}

/// The `visibility` keywords, canonicalised. Null from `of` means the declared
/// value is not one of them, and an unrecognised value is not a declaration at
/// all: it is dropped and inheritance carries on past it.
pub const Visibility = enum {
    visible,
    hidden,
    collapse,

    pub fn of(value: []const u8) ?Visibility {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "visible")) return .visible;
        if (std.ascii.eqlIgnoreCase(trimmed, "hidden")) return .hidden;
        if (std.ascii.eqlIgnoreCase(trimmed, "collapse")) return .collapse;
        return null;
    }

    /// `hidden` and `collapse` both render nothing (Chrome 151 reads `""` from
    /// innerText for either, probe w1-visibility).
    pub fn hides(self: Visibility) bool {
        return self != .visible;
    }

    pub fn keyword(self: Visibility) []const u8 {
        return @tagName(self);
    }
};

/// The element's *own* cascaded `visibility`, or null when neither a stylesheet
/// rule nor the inline style declares one (or declares one this engine knows).
/// Same source order as computedDisplay. `visibility` inherits, so a null here
/// means "whatever the parent computes to": computedVisibility does that walk,
/// and innerText threads the answer down its own top-down walk instead, which is
/// the same answer for one lookup per element rather than one per ancestor.
pub fn declaredVisibility(self: *StyleManager, element: *Element) ?Visibility {
    const inline_property = getInlineStyleProperty(element, comptime .wrap("visibility"), self.frame);
    const rule = self.cascadedDeclaration(element, .visibility);

    if (rule) |declaration| {
        if (declaration.important and !(inline_property != null and inline_property.?._important)) {
            return Visibility.of(declaration.value);
        }
    }
    if (inline_property) |property| {
        if (Visibility.of(property._value.str())) |value| {
            return value;
        }
    }
    if (rule) |declaration| {
        return Visibility.of(declaration.value);
    }
    return null;
}

/// Computed `visibility` for `element`, walking ancestors because `visibility`
/// inherits, and stopping at the nearest one that declares a value. That is what
/// makes it a different question from hasVisibilityHiddenInherited, which answers
/// "does anything up the chain hide" and so cannot see a descendant turning
/// visibility back on. Chrome 151 renders the text of such a descendant (probe
/// w1-visibility), which is why innerText and getComputedStyle ask this one.
pub fn computedVisibility(self: *StyleManager, element: *Element) ?Visibility {
    var current: ?*Element = element;
    var depth: u8 = 0;
    while (current) |elem| : (depth += 1) {
        if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
            return null;
        }
        if (self.declaredVisibility(elem)) |value| {
            return value;
        }
        current = elem.parentElement();
    }
    // Nothing up the chain declares one, so the initial value `visible` stands.
    return null;
}

/// Does `element` lay its children out as flex or grid items? Those are exactly
/// the containers that blockify a child's outer display, so this is the question
/// `blockify` needs answered about the parent. A null cascade means no rule and
/// no inline style set one, and no per-tag UA default is flex or grid, so the
/// answer is no. Blockifying the parent itself would not change this: `blockify`
/// only rewrites the outer half of a display, never the inner flex/grid half.
pub fn blockifiesChildren(self: *StyleManager, element: *Element) bool {
    const value = self.computedDisplay(element) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "flex") or
        std.ascii.eqlIgnoreCase(value, "inline-flex") or
        std.ascii.eqlIgnoreCase(value, "grid") or
        std.ascii.eqlIgnoreCase(value, "inline-grid");
}

/// A flex or grid item's display, blockified: the outer half turns block-level
/// and the inner half is kept. Measured on Chrome 151 (probe d3-blockify: every
/// one of sixteen child values under each of four container types, plus the
/// table-internal and ruby-internal values); `contents` and `none` generate no
/// box of their own and are the two exemptions.
pub fn blockify(display: []const u8) []const u8 {
    const map = .{
        .{ "inline", "block" },
        .{ "inline-block", "block" },
        .{ "inline-flex", "flex" },
        .{ "inline-grid", "grid" },
        .{ "inline-table", "table" },
        .{ "table-cell", "block" },
        .{ "table-row", "block" },
        .{ "table-row-group", "block" },
        .{ "table-header-group", "block" },
        .{ "table-footer-group", "block" },
        .{ "table-column", "block" },
        .{ "table-column-group", "block" },
        .{ "table-caption", "block" },
        .{ "ruby", "block ruby" },
        .{ "ruby-text", "block" },
        .{ "ruby-base", "block" },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(display, entry[0])) {
            return entry[1];
        }
    }
    // Already block-level (block / flex / grid / table / list-item / flow-root),
    // or box-less (contents / none): unchanged.
    return display;
}

/// The two longhands the LAYOUT reads out of a rule, carried across a shorthand
/// expansion.
///
/// `props` is what `cascadedDeclaration` answers from, and it is filled by name
/// while the declarations are walked — so a rule that writes `font-size`
/// directly reaches the box and one that writes `font: 13px serif` reached only
/// the computed style, whose longhand list is a different collection. Measured:
/// `.x{font:13px serif}` computed `13px` and laid out at 210.64 where Chrome
/// lays out at 171.148 (tools/fingerprint/scratch/expr-sheet-font-layout.js).
fn carryFontProp(props: *RuleProperties, name: []const u8, value: []const u8, important: bool) void {
    if (std.ascii.eqlIgnoreCase(name, "font-size")) {
        props.font_size = .{ .value = value, .important = important };
    } else if (std.ascii.eqlIgnoreCase(name, "font-family")) {
        props.font_family = .{ .value = value, .important = important };
    }
}

/// Cascaded `font-family` list, verbatim, or null when nothing declares one
/// anywhere up the chain. Same source order as computedFontSize; the caller
/// decides which of the listed names it can actually resolve.
pub fn computedFontFamily(self: *StyleManager, element: ?*Element) ?[]const u8 {
    return self.computedFontFamilyAt(element, 0);
}

fn computedFontFamilyAt(self: *StyleManager, element: ?*Element, depth: u8) ?[]const u8 {
    if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
        return null;
    }
    const current = element orelse return null;

    const inline_property = getInlineStyleProperty(current, comptime .wrap("font-family"), self.frame);
    const rule = self.cascadedDeclaration(current, .font_family);

    if (rule) |declaration| {
        if (declaration.important and !(inline_property != null and inline_property.?._important)) {
            return declaration.value;
        }
    }
    if (inline_property) |property| {
        return property._value.str();
    }
    if (rule) |declaration| {
        return declaration.value;
    }
    if (current.getAttributeSafe(comptime .wrap("font-family"))) |raw| {
        return raw;
    }
    if (userAgentFontProperty(current, "font-family")) |raw| {
        return raw;
    }
    return self.computedFontFamilyAt(current.parentElement(), depth + 1);
}

/// The winning `font-size` declaration among the stylesheet rules matching
/// `el`, or null when none match.
fn cascadedFontSize(self: *StyleManager, el: *Element) ?Declaration {
    return self.cascadedDeclaration(el, .font_size);
}

const CascadedProperty = enum { font_size, font_family, text_transform, display, visibility };

/// The winning declaration of `property` among the stylesheet rules matching
/// `el`, or null when none match. Importance outranks specificity, which is
/// why the two are tracked apart rather than folded into `priority`.
/// Both caches answer for a document that has not moved, so one mutation drops
/// both. `clearRetainingCapacity` keeps the buckets: the arena cannot give
/// memory back, and a page that mutates a thousand times must not pay for a
/// thousand maps.
fn dropCachesIfDomMoved(self: *StyleManager) void {
    const dom_version = self.frame._page.dom_version;
    if (dom_version == self.cache_dom_version) {
        return;
    }
    self.cascade_cache.clearRetainingCapacity();
    self.fixed_cascade_cache.clearRetainingCapacity();
    self.rule_hiding_cache.clearRetainingCapacity();
    self.cache_dom_version = dom_version;
}

fn cascadedDeclaration(self: *StyleManager, el: *Element, property: CascadedProperty) ?Declaration {
    self.rebuildIfDirty() catch return null;

    self.dropCachesIfDomMoved();
    if (self.fixed_cascade_cache.get(.{ .element = el, .property = property })) |cached| {
        return cached;
    }

    var best: ?Declaration = null;
    var best_priority: u64 = 0;
    var best_important = false;

    const checkRules = struct {
        fn check(rules: *const RuleList, which: CascadedProperty, winner: *?Declaration, priority: *u64, important: *bool, elem: *Element, frame: *Frame) void {
            for (rules.items(.priority), rules.items(.props), rules.items(.selector)) |p, props, selector| {
                const declaration = (switch (which) {
                    .font_size => props.font_size,
                    .font_family => props.font_family,
                    .text_transform => props.text_transform,
                    .display => props.display,
                    .visibility => props.visibility,
                }) orelse continue;
                if (important.* and !declaration.important) continue;
                if (declaration.important == important.* and p <= priority.*) continue;
                if (!matchesSelector(elem, selector, frame)) continue;
                winner.* = declaration;
                priority.* = p;
                important.* = declaration.important;
            }
        }
    }.check;

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            checkRules(&rules, property, &best, &best_priority, &best_important, el, self.frame);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                checkRules(&rules, property, &best, &best_priority, &best_important, el, self.frame);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        checkRules(&rules, property, &best, &best_priority, &best_important, el, self.frame);
    }

    checkRules(&self.other_rules, property, &best, &best_priority, &best_important, el, self.frame);

    // Misses cached alongside hits, as in the named cache: "no rule sets display
    // on this element" is the usual answer and it cost the same walk.
    if (self.fixed_cascade_cache.count() < MAX_CASCADE_CACHE) {
        self.fixed_cascade_cache.put(
            self.arena.allocator(),
            .{ .element = el, .property = property },
            best,
        ) catch {};
    }

    return best;
}

/// The cascaded value of a custom property on `element`, or null when nothing
/// up the tree declares it. Custom properties inherit, so a miss walks to the
/// parent -- which is also why this is a tree walk rather than a lookup.
///
/// A *registered* property (`CSS.registerProperty`) answers differently on
/// three counts, all measured: `inherits: false` stops the walk at the element
/// itself, the declared value is computed per the registered syntax, and a
/// value that does not parse for that syntax falls back to the registered
/// initial value instead of reaching the page as written.
pub fn customPropertyValue(self: *StyleManager, element: *Element, name: []const u8) ?[]const u8 {
    if (self.registered_properties.find(name)) |entry| {
        const declared: ?[]const u8, const on: ?*Element = blk: {
            if (entry.inherits) {
                break :blk self.declaredCustomPropertyUpTree(element, name, 0);
            }
            break :blk .{ self.declaredCustomProperty(element, name), element };
        };
        if (declared) |raw| {
            const arena = self.frame.call_arena;
            if (registered_property.compute(arena, entry.syntax, raw, on, self)) |computed| {
                return computed;
            }
        }
        return entry.initial;
    }
    return self.customPropertyValueAt(element, name, 0);
}

fn customPropertyValueAt(self: *StyleManager, element: ?*Element, name: []const u8, depth: u8) ?[]const u8 {
    if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
        return null;
    }
    const current = element orelse return null;
    if (self.declaredCustomProperty(current, name)) |value| {
        return value;
    }
    return self.customPropertyValueAt(current.parentElement(), name, depth + 1);
}

/// What `element` itself declares for `name`, inline or through a matching
/// rule, with no ancestor walk. The unit the walk above is built out of, and
/// the whole of the answer for a property registered with `inherits: false`.
fn declaredCustomProperty(self: *StyleManager, element: *Element, name: []const u8) ?[]const u8 {
    const inline_property = getInlineStyleProperty(element, .wrap(name), self.frame);
    const rule = self.cascadedCustomDeclaration(element, name);

    // Same order as computedFontFamily: an `!important` rule beats the style
    // attribute unless that one is `!important` too.
    if (rule) |declaration| {
        if (declaration.important and !(inline_property != null and inline_property.?._important)) {
            return declaration.value;
        }
    }
    if (inline_property) |property| {
        return property._value.str();
    }
    if (rule) |declaration| {
        return declaration.value;
    }
    return null;
}

/// The nearest declaration of `name` at or above `element`, and the element it
/// was found on. A registered property's syntax is applied where the value was
/// written -- `2em` on an ancestor resolves against *that* element's font and
/// the computed result is what inherits.
fn declaredCustomPropertyUpTree(
    self: *StyleManager,
    element: ?*Element,
    name: []const u8,
    depth: u8,
) struct { ?[]const u8, ?*Element } {
    if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
        return .{ null, null };
    }
    const current = element orelse return .{ null, null };
    if (self.declaredCustomProperty(current, name)) |value| {
        return .{ value, current };
    }
    return self.declaredCustomPropertyUpTree(current.parentElement(), name, depth + 1);
}

/// Every custom property name in effect on `element`: the ones it declares
/// itself, inline or through a matching rule, then the ones it inherits, each
/// name once. Chrome's computed style enumerates these alongside the standard
/// longhands (the order within them is Blink's own and is not reproduced).
pub fn collectCustomPropertyNames(self: *StyleManager, element: *Element, out: *std.ArrayList([]const u8)) !void {
    self.rebuildIfDirty() catch return;

    var current: ?*Element = element;
    var depth: u8 = 0;
    while (current) |el| : ({
        current = el.parentElement();
        depth += 1;
    }) {
        if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
            return;
        }
        if (self.frame._element_styles.get(el) orelse blk: {
            if (el.getAttributeSafe(comptime .wrap("style")) == null) break :blk null;
            break :blk el.getOrCreateStyle(self.frame) catch null;
        }) |style| {
            var node = style._properties.first;
            while (node) |n| : (node = n.next) {
                const property = CSSStyleProperty.fromNodeLink(n);
                try appendUnique(self.frame.local_arena, out, property._name.str());
            }
        }

        try self.appendMatchingCustomNames(el, out);
    }

    // A registered property has a computed value on every element, whether
    // anything declared it or not, so it is enumerated everywhere -- except
    // the one registration that has no value to report: a universal syntax
    // with no initial value (measured, scratch/b80/q6.js).
    for (self.registered_properties.entries.items) |entry| {
        if (entry.initial == null) continue;
        try appendUnique(self.frame.local_arena, out, entry.name);
    }
}

fn appendMatchingCustomNames(self: *StyleManager, el: *Element, out: *std.ArrayList([]const u8)) !void {
    const collect = struct {
        fn run(manager: *StyleManager, rules: *const RuleList, elem: *Element, sink: *std.ArrayList([]const u8)) !void {
            for (rules.items(.props), rules.items(.selector)) |props, selector| {
                if (props.custom.len == 0) continue;
                if (!matchesSelector(elem, selector, manager.frame)) continue;
                for (props.custom) |declaration| {
                    try appendUnique(manager.frame.local_arena, sink, declaration.name);
                }
            }
        }
    }.run;

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            try collect(self, &rules, el, out);
        }
    }
    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                try collect(self, &rules, el, out);
            }
        }
    }
    if (self.tag_rules.get(el.getTag())) |rules| {
        try collect(self, &rules, el, out);
    }
    try collect(self, &self.other_rules, el, out);
}

fn appendUnique(allocator: Allocator, out: *std.ArrayList([]const u8), name: []const u8) !void {
    if (!CSSStyleDeclaration.isCustomProperty(name)) {
        return;
    }
    for (out.items) |seen| {
        if (std.mem.eql(u8, seen, name)) return;
    }
    try out.append(allocator, name);
}

/// Bounds the var() substitution recursion. A reference cycle
/// (`--a: var(--b); --b: var(--a)`) is only visible as depth here, and Chrome
/// makes a cycle invalid at computed-value time -- which is what returning
/// null means to the caller.
const MAX_VAR_DEPTH = 16;

/// `raw` with every `var()` replaced by the custom property it names, or by
/// that reference's fallback when the name is not declared anywhere up the
/// tree. Returns null when the value is invalid at computed-value time: an
/// undeclared name with no fallback, or a reference cycle.
///
/// Only computed values are substituted; a specified value keeps its var()
/// text, which is why this is applied at read time rather than when a
/// declaration is stored.
pub fn substituteVars(self: *StyleManager, element: *Element, raw: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, raw, "var(") == null and std.mem.indexOf(u8, raw, "VAR(") == null) {
        return raw;
    }
    return self.substituteVarsAt(element, raw, 0);
}

fn substituteVarsAt(self: *StyleManager, element: *Element, raw: []const u8, depth: u8) ?[]const u8 {
    if (depth >= MAX_VAR_DEPTH) {
        return null;
    }

    const allocator = self.frame.local_arena;
    var out: std.ArrayList(u8) = .empty;
    var rest = raw;
    while (findVarReference(rest)) |reference| {
        out.appendSlice(allocator, rest[0..reference.start]) catch return null;

        const name = std.mem.trim(u8, reference.name, &std.ascii.whitespace);
        if (self.customPropertyValue(element, name)) |value| {
            // A property declared empty is still declared: the fallback does
            // not apply, and the reference contributes nothing.
            const substituted = self.substituteVarsAt(element, value, depth + 1) orelse return null;
            out.appendSlice(allocator, substituted) catch return null;
        } else {
            const fallback = reference.fallback orelse return null;
            const trimmed = std.mem.trim(u8, fallback, &std.ascii.whitespace);
            const substituted = self.substituteVarsAt(element, trimmed, depth + 1) orelse return null;
            out.appendSlice(allocator, substituted) catch return null;
        }

        rest = rest[reference.end..];
    }
    out.appendSlice(allocator, rest) catch return null;
    return std.mem.trim(u8, out.items, &std.ascii.whitespace);
}

const VarReference = struct {
    // Offsets into the slice searched: `start` is the `v` of `var(`, `end` is
    // one past the closing paren.
    start: usize,
    end: usize,
    name: []const u8,
    // Everything after the first top-level comma, verbatim: Chrome keeps the
    // commas of `var(--nope, a, b)` and answers "a, b".
    fallback: ?[]const u8,
};

fn findVarReference(input: []const u8) ?VarReference {
    var i: usize = 0;
    const start = while (i + 4 <= input.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(input[i .. i + 4], "var(")) break i;
    } else return null;

    var depth: usize = 1;
    var comma: ?usize = null;
    var j = start + 4;
    while (j < input.len) : (j += 1) {
        switch (input[j]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break;
            },
            ',' => if (depth == 1 and comma == null) {
                comma = j;
            },
            else => {},
        }
    }
    if (depth != 0) {
        // Unclosed reference: treat the rest as the name, the way a token
        // stream that ends mid-function does.
        return .{ .start = start, .end = input.len, .name = input[start + 4 ..], .fallback = null };
    }

    const close = j;
    const inner_end = comma orelse close;
    return .{
        .start = start,
        .end = close + 1,
        .name = input[start + 4 .. inner_end],
        .fallback = if (comma) |c| input[c + 1 .. close] else null,
    };
}

/// Which of a rule's two by-name declaration lists a lookup reads.
const NamedList = enum { custom, longhand };

/// The winning declaration of custom property `name` among the stylesheet
/// rules matching `el`. Custom property names are case-sensitive.
fn cascadedCustomDeclaration(self: *StyleManager, el: *Element, name: []const u8) ?Declaration {
    return self.cascadedNamedDeclaration(el, name, .custom);
}

/// The winning declaration of standard longhand `name` among the stylesheet
/// rules matching `el`, or null when no matching rule declares it. `name` is
/// compared as stored, which is lower-case on both build paths -- callers
/// normalise (`CSSStyleDeclaration.normalizePropertyName` does).
///
/// This is what lets a computed style answer what the author sheet said for a
/// property nothing precomputes. The reduced fields on RuleProperties stay for
/// the hidden-element path, which asks the same question per element per layout
/// operation and can afford neither the name scan nor a miss.
pub fn cascadedLonghand(self: *StyleManager, el: *Element, name: []const u8) ?Declaration {
    return self.cascadedNamedDeclaration(el, name, .longhand);
}

fn cascadedNamedDeclaration(self: *StyleManager, el: *Element, name: []const u8, which: NamedList) ?Declaration {
    self.rebuildIfDirty() catch return null;

    // Nothing in the document declares it, so no rule can win it. Ahead of the
    // cache and not worth caching: it is already a single hash lookup.
    if (which == .longhand and !self.declared_longhands.contains(name)) {
        return null;
    }

    self.dropCachesIfDomMoved();
    if (self.cascade_cache.get(.{ .element = el, .name = name, .which = which })) |cached| {
        return cached;
    }

    var best: ?Declaration = null;
    var best_priority: u64 = 0;
    var best_important = false;

    // Hashed once for the whole read, then tested against each rule's mask.
    const wanted_mask = nameMask(name);

    const checkRules = struct {
        fn check(rules: *const RuleList, wanted: []const u8, wanted_bits: u128, list: NamedList, winner: *?Declaration, priority: *u64, important: *bool, elem: *Element, frame: *Frame) void {
            const masks = switch (list) {
                .custom => rules.items(.custom_names),
                .longhand => rules.items(.longhand_names),
            };
            for (rules.items(.priority), rules.items(.props), rules.items(.selector), masks) |p, props, selector, mask| {
                // Subsumes the empty-list check: a rule that declares nothing in
                // this list has a zero mask and no name hashes to zero bits.
                if (mask & wanted_bits != wanted_bits) continue;
                const declarations = switch (list) {
                    .custom => props.custom,
                    .longhand => props.longhands,
                };
                var matched: ?NamedDeclaration = null;
                // Within one rule the last declaration of a name wins.
                for (declarations) |declaration| {
                    if (std.mem.eql(u8, declaration.name, wanted)) {
                        matched = declaration;
                    }
                }
                const declaration = matched orelse continue;
                if (important.* and !declaration.important) continue;
                if (declaration.important == important.* and p <= priority.*) continue;
                if (!matchesSelector(elem, selector, frame)) continue;
                winner.* = .{
                    .value = declaration.value,
                    .important = declaration.important,
                    .specified = declaration.specified,
                    .raw = declaration.raw,
                };
                priority.* = p;
                important.* = declaration.important;
            }
        }
    }.check;

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            checkRules(&rules, name, wanted_mask, which, &best, &best_priority, &best_important, el, self.frame);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                checkRules(&rules, name, wanted_mask, which, &best, &best_priority, &best_important, el, self.frame);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        checkRules(&rules, name, wanted_mask, which, &best, &best_priority, &best_important, el, self.frame);
    }

    checkRules(&self.other_rules, name, wanted_mask, which, &best, &best_priority, &best_important, el, self.frame);

    // A miss is worth keeping too: "no rule declares this for this element" is
    // what most of these reads conclude, and concluding it cost the same walk.
    // `name` is the caller's slice, so the key holds a copy from the arena the
    // answers already live in.
    if (self.cascade_cache.count() < MAX_CASCADE_CACHE) {
        const allocator = self.arena.allocator();
        const gop = self.cascade_cache.getOrPut(allocator, .{
            .element = el,
            .name = name,
            .which = which,
        }) catch return best;
        if (!gop.found_existing) {
            gop.key_ptr.name = allocator.dupe(u8, name) catch {
                _ = self.cascade_cache.remove(.{ .element = el, .name = name, .which = which });
                return best;
            };
        }
        gop.value_ptr.* = best;
    }

    return best;
}

fn parseFontSize(self: *StyleManager, raw: []const u8, parent: ?*Element, depth: u8) ?f64 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset")) {
        return self.computedFontSizeAt(parent, depth);
    }
    if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "medium")) {
        return 16;
    }

    const parsed = units.parse(value) catch return null;
    const factor = units.absoluteLengthFactor(parsed.unit) orelse switch (parsed.unit) {
        .percentage => self.computedFontSizeAt(parent, depth) / 100.0,
        .em => self.computedFontSizeAt(parent, depth),
        .ex => self.computedFontSizeAt(parent, depth) / 2.0,
        else => return null,
    };
    const size = parsed.value * factor;
    return if (size >= 0 and std.math.isFinite(size)) size else null;
}

const testing = @import("../testing.zig");
test "StyleManager: computeSpecificity: element selector" {
    // div -> (0, 0, 1)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{},
    };
    try testing.expectEqual(1, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: class selector" {
    // .foo -> (0, 1, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: id selector" {
    // #bar -> (1, 0, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .id = "bar" }} },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 20, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: combined selector" {
    // div.foo#bar -> (1, 1, 1)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .tag = .div },
            .{ .class = "foo" },
            .{ .id = "bar" },
        } },
        .segments = &.{},
    };
    try testing.expectEqual((1 << 20) | (1 << 10) | 1, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: universal selector" {
    // * -> (0, 0, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.universal} },
        .segments = &.{},
    };
    try testing.expectEqual(0, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: multiple classes" {
    // .a.b.c -> (0, 3, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .class = "a" },
            .{ .class = "b" },
            .{ .class = "c" },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(3 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: descendant combinator" {
    // div span -> (0, 0, 2)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{
            .{ .combinator = .descendant, .compound = .{ .parts = &.{.{ .tag = .span }} } },
        },
    };
    try testing.expectEqual(2, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :where() has zero specificity" {
    // :where(.foo) -> (0, 0, 0) regardless of what's inside
    const inner_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .where = &.{inner_selector} } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(0, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :not() takes inner specificity" {
    // :not(.foo) -> (0, 1, 0) - takes specificity of .foo
    const inner_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .not = &.{inner_selector} } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :is() takes most specific inner" {
    // :is(.foo, #bar) -> (1, 0, 0) - takes the most specific (#bar)
    const class_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const id_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .id = "bar" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .is = &.{ class_selector, id_selector } } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 20, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: pseudo-class (general)" {
    // :hover -> (0, 1, 0) - pseudo-classes count as class-level
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .hover },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: document order tie-breaking" {
    // When specificity is equal, higher doc_order (later in document) wins
    const beats = struct {
        fn f(spec: u32, doc_order: u32, best_spec: u32, best_doc_order: u32) bool {
            return spec > best_spec or (spec == best_spec and doc_order > best_doc_order);
        }
    }.f;

    // Higher specificity always wins regardless of doc_order
    try testing.expect(beats(2, 0, 1, 10));
    try testing.expect(!beats(1, 10, 2, 0));

    // Equal specificity: higher doc_order wins
    try testing.expect(beats(1, 5, 1, 3)); // doc_order 5 > 3
    try testing.expect(!beats(1, 3, 1, 5)); // doc_order 3 < 5

    // Equal specificity and doc_order: no win
    try testing.expect(!beats(1, 5, 1, 5));
}

test "StyleManager: packed priority bounds" {
    // The three fields fill the u64 exactly, without overlap.
    try testing.expectEqual(64, @as(u32, RANK_SHIFT) + 12);
    try testing.expectEqual(RANK_SHIFT, @as(u32, SPEC_SHIFT) + 30);

    // The maximum packable rule priority (unlayered rank, fully-clamped
    // specificity, saturated doc_order) stays below INLINE_PRIORITY.
    const max_packed = (@as(u64, UNLAYERED_RANK) << RANK_SHIFT) |
        (@as(u64, std.math.maxInt(u30)) << SPEC_SHIFT) |
        MAX_DOC_ORDER;
    try testing.expect(max_packed < INLINE_PRIORITY);

    // Real layer ranks fit the 12 rank bits below the unlayered sentinel.
    try testing.expect(MAX_LAYERS < UNLAYERED_RANK);
}

test "StyleManager: nameMask never rejects a name the rule declares" {
    // The filter's one safety requirement: a false positive only costs the scan
    // that used to happen anyway, but a false NEGATIVE would silently drop a
    // winning declaration and change what the page computes. Every name in the
    // list must therefore survive its own mask.
    const declarations = [_]NamedDeclaration{
        .{ .name = "margin-top", .value = "1px", .important = false },
        .{ .name = "display", .value = "block", .important = false },
        .{ .name = "--brand", .value = "red", .important = false },
        .{ .name = "border-bottom-left-radius", .value = "2px", .important = false },
        .{ .name = "", .value = "x", .important = false },
    };
    const mask = namesMask(&declarations);
    for (declarations) |declaration| {
        const wanted = nameMask(declaration.name);
        try testing.expect(mask & wanted == wanted);
    }

    // An empty list rejects everything, which is what lets the mask test stand
    // in for the old `declarations.len == 0` check.
    try testing.expectEqual(@as(u128, 0), namesMask(&.{}));
    try testing.expect(nameMask("margin-top") != 0);
}
