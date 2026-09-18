// The CSSRule subclass hierarchy. Chrome exposes sixteen globals below
// CSSRule and a detector that walks `sheet.cssRules` sees the brand of every
// one of them, so an engine that answers a bare `CSSRule` for every at-rule
// stands out immediately.
//
// Shapes, member order, brands, argument counts, serialisations and mutation
// behaviour were all measured on a headed Chrome 150 over http://localhost
// (probes probe-css1.js / probe-css2.js / probe-css3.js). Where Chrome
// disagrees with the CSSOM spec the comment says so and Chrome wins.
//
// Declaration order inside each JsApi is Chrome's own
// Object.getOwnPropertyNames(X.prototype) order, because that order is itself
// part of what a detector hashes.

const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Parser = @import("../../css/Parser.zig");
const Tokenizer = @import("../../css/Tokenizer.zig");

const CSSRule = @import("CSSRule.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSStyleRule = @import("CSSStyleRule.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");
const MediaList = @import("MediaList.zig");

pub fn registerTypes() []const type {
    return &.{
        CSSGroupingRule,
        CSSConditionRule,
        CSSMediaRule,
        CSSSupportsRule,
        CSSContainerRule,
        CSSLayerBlockRule,
        CSSLayerStatementRule,
        CSSImportRule,
        CSSPageRule,
        CSSNamespaceRule,
        CSSFontFaceRule,
        CSSFontPaletteValuesRule,
        CSSCounterStyleRule,
        CSSPropertyRule,
        CSSKeyframesRule,
        CSSKeyframeRule,

        // Prototype surface only -- nothing hands out an instance yet. See the
        // section at the bottom of this file.
        CSSFontFeatureValuesRule,
        CSSFunctionDeclarations,
        CSSFunctionDescriptors,
        CSSFunctionRule,
        CSSMarginRule,
        CSSNestedDeclarations,
        CSSPositionTryDescriptors,
        CSSPositionTryRule,
        CSSScopeRule,
        CSSStartingStyleRule,
        CSSViewTransitionRule,
    };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// A parsed declaration block kept as name/value pairs. Used by the at-rules
/// whose members are individual descriptors (`@counter-style`, `@property`,
/// `@font-palette-values`) rather than a CSSStyleDeclaration.
const Descriptors = struct {
    _items: std.ArrayList(Item) = .empty,

    const Item = struct { name: []const u8, value: []const u8 };

    fn parse(text: []const u8, frame: *Frame) !Descriptors {
        var self = Descriptors{};
        var it = Parser.parseDeclarationsList(text);
        while (it.next()) |declaration| {
            try self._items.append(frame.arena, .{
                .name = try frame.dupeString(declaration.name),
                .value = try frame.dupeString(declaration.value),
            });
        }
        return self;
    }

    /// Measured: a descriptor Chrome did not see reads back as "", not null.
    fn get(self: *const Descriptors, name: []const u8) []const u8 {
        for (self._items.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return "";
    }

    fn write(self: *const Descriptors, writer: *std.Io.Writer) !void {
        for (self._items.items) |item| {
            try writer.print("{s}: {s}; ", .{ item.name, item.value });
        }
    }
};

/// `@foo <prelude> { <descriptors> }` on one line, which is how Chrome
/// serialises every descriptor at-rule.
fn writeDescriptorRule(
    writer: *std.Io.Writer,
    keyword: []const u8,
    prelude: []const u8,
    descriptors: *const Descriptors,
) !void {
    if (prelude.len == 0) {
        try writer.print("@{s} {{ ", .{keyword});
    } else {
        try writer.print("@{s} {s} {{ ", .{ keyword, prelude });
    }
    try descriptors.write(writer);
    try writer.writeAll("}");
}

/// `@foo <prelude> {\n  <child>\n  <child>\n}`, Chrome's block-rule layout:
/// two-space indent, one child per line, no blank line for an empty block.
fn writeBlockRule(
    writer: *std.Io.Writer,
    keyword: []const u8,
    prelude: []const u8,
    children: *CSSRuleList,
    frame: *Frame,
) !void {
    if (prelude.len == 0) {
        try writer.print("@{s} {{\n", .{keyword});
    } else {
        try writer.print("@{s} {s} {{\n", .{ keyword, prelude });
    }
    for (children._rules.items) |child| {
        try writer.print("  {s}\n", .{try child.getCssText(frame)});
    }
    try writer.writeAll("}");
}

/// Parse a block body into `list`, wiring each rule's parent links. Shared by
/// the grouping rules and by CSSStyleSheet.
pub fn parseInto(list: *CSSRuleList, text: []const u8, parent: ?*CSSRule, frame: *Frame) BuildError!void {
    var it = Parser.parseStylesheet(text);
    var index: u32 = 0;
    while (it.next()) |parsed| {
        const rule = (try buildRule(parsed, frame)) orelse continue;
        rule._parent_rule = parent;
        try list.insert(index, rule, frame);
        index += 1;
    }
}

/// Turn one parsed top-level rule into its CSSRule. Answers null for input
/// Chrome drops entirely (measured: `@charset` never surfaces as a rule).
pub const BuildError = error{ OutOfMemory, WriteFailed, StringTooLarge, IndexSizeError, SyntaxError };

pub fn buildRule(parsed: Parser.Rule, frame: *Frame) BuildError!?*CSSRule {
    switch (parsed) {
        .style => |s| {
            const style_rule = try CSSStyleRule.init(frame);
            try style_rule.setSelectorText(s.selector, frame);
            const style = try style_rule.getStyle(frame);
            try style.setCssText(s.block, frame);
            return style_rule._proto;
        },
        .at_rule => |a| return buildAtRuleKeepingSource(a, frame),
    }
}

fn stripVendorPrefix(keyword: []const u8) []const u8 {
    inline for (.{ "-webkit-", "-moz-", "-ms-", "-o-" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(keyword, prefix)) {
            return keyword[prefix.len..];
        }
    }
    return keyword;
}

fn buildAtRule(a: Parser.AtRule, frame: *Frame) BuildError!?*CSSRule {
    const keyword = stripVendorPrefix(a.keyword);
    const eql = std.ascii.eqlIgnoreCase;

    // Chrome consumes @charset while tokenising: it is never a rule.
    if (eql(keyword, "charset")) return null;

    if (eql(keyword, "media")) return (try CSSMediaRule.init(a.prelude, a.block orelse "", frame))._proto._proto._proto;
    if (eql(keyword, "supports")) return (try CSSSupportsRule.init(a.prelude, a.block orelse "", frame))._proto._proto._proto;
    if (eql(keyword, "container")) return (try CSSContainerRule.init(a.prelude, a.block orelse "", frame))._proto._proto._proto;
    if (eql(keyword, "page")) return (try CSSPageRule.init(a.prelude, a.block orelse "", frame))._proto._proto;
    if (eql(keyword, "layer")) {
        // One at-keyword, two interfaces: a block makes it a grouping rule, a
        // bare statement makes it a plain CSSRule holding a name list.
        if (a.block) |block| return (try CSSLayerBlockRule.init(a.prelude, block, frame))._proto._proto;
        return (try CSSLayerStatementRule.init(a.prelude, frame))._proto;
    }
    if (eql(keyword, "keyframes")) return (try CSSKeyframesRule.init(a.prelude, a.block orelse "", frame))._proto;
    if (eql(keyword, "import")) return (try CSSImportRule.init(a.prelude, frame))._proto;
    if (eql(keyword, "namespace")) return (try CSSNamespaceRule.init(a.prelude, frame))._proto;
    if (eql(keyword, "font-face")) return (try CSSFontFaceRule.init(a.block orelse "", frame))._proto;
    if (eql(keyword, "font-palette-values")) return (try CSSFontPaletteValuesRule.init(a.prelude, a.block orelse "", frame))._proto;
    if (eql(keyword, "counter-style")) return (try CSSCounterStyleRule.init(a.prelude, a.block orelse "", frame))._proto;
    if (eql(keyword, "property")) return (try CSSPropertyRule.init(a.prelude, a.block orelse "", frame))._proto;
    if (eql(keyword, "view-transition")) {
        const rule = (try CSSViewTransitionRule.init(a.prelude, a.block, frame)) orelse return null;
        return rule._proto;
    }

    // Anything we do not model keeps the opaque placeholder behaviour that
    // CSS-in-JS libraries depend on for insertRule round-trips (#2459).
    return try CSSRule.initAtRule(.unknown, a.text, frame);
}

/// Build an at-rule and stash its original source on the CSSRule. Nothing
/// JS-visible reads `_text` for a modelled rule (they all re-serialise), but
/// StyleManager re-parses it to fold `@media` / `@layer` into the cascade.
fn buildAtRuleKeepingSource(a: Parser.AtRule, frame: *Frame) BuildError!?*CSSRule {
    const rule = (try buildAtRule(a, frame)) orelse return null;
    if (rule._text.len == 0) {
        rule._text = try frame.dupeString(a.text);
    }
    return rule;
}

// ---------------------------------------------------------------------------
// CSSGroupingRule / CSSConditionRule
// ---------------------------------------------------------------------------

pub const CSSGroupingRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _rules: *CSSRuleList,

    pub fn getCssRules(self: *CSSGroupingRule) *CSSRuleList {
        return self._rules;
    }

    /// Unlike CSSStyleSheet.insertRule, which clamps, a grouping rule throws
    /// on an out-of-range index (measured: IndexSizeError).
    pub fn insertRule(self: *CSSGroupingRule, text: []const u8, maybe_index: ?u32, frame: *Frame) !u32 {
        const index = maybe_index orelse 0;
        if (index > self._rules.length()) return error.IndexSizeError;

        var it = Parser.parseStylesheet(text);
        const parsed = it.next() orelse return error.SyntaxError;
        if (it.next() != null) return error.SyntaxError;

        const rule = (try buildRule(parsed, frame)) orelse return error.SyntaxError;
        rule._parent_rule = self._proto;
        try self._rules.insert(index, rule, frame);
        frame._style_manager.sheetModified();
        return index;
    }

    pub fn deleteRule(self: *CSSGroupingRule, index: u32, frame: *Frame) !void {
        try self._rules.remove(index);
        frame._style_manager.sheetModified();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSGroupingRule);

        pub const Meta = struct {
            pub const name = "CSSGroupingRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const cssRules = bridge.accessor(CSSGroupingRule.getCssRules, null, .{});
        pub const deleteRule = bridge.function(CSSGroupingRule.deleteRule, .{});
        pub const insertRule = bridge.function(CSSGroupingRule.insertRule, .{});
    };
};

pub const CSSConditionRule = struct {
    pub const Proto = CSSGroupingRule;

    _proto: *CSSGroupingRule,
    _condition: []const u8,
    /// Only a CSSMediaRule sets this. Chrome's conditionText for a @media
    /// rule is the live serialisation of its MediaList — measured:
    /// `rule.media.mediaText = 'print'` changes `rule.conditionText` too — so
    /// the getter has to read through rather than answer a stored string.
    _media: ?*MediaList = null,

    pub fn getConditionText(self: *CSSConditionRule, frame: *Frame) ![]const u8 {
        if (self._media) |media| return media.getMediaText(frame);
        return self._condition;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSConditionRule);

        pub const Meta = struct {
            pub const name = "CSSConditionRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const conditionText = bridge.accessor(CSSConditionRule.getConditionText, null, .{});
    };
};

// ---------------------------------------------------------------------------
// @media / @supports / @container
// ---------------------------------------------------------------------------

pub const CSSMediaRule = struct {
    pub const Proto = CSSConditionRule;

    _proto: *CSSConditionRule,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSMediaRule {
        const media = try MediaList.initWithText(prelude, frame);
        const rules = try CSSRuleList.init(frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSGroupingRule{ ._proto = undefined, ._rules = rules },
            CSSConditionRule{ ._proto = undefined, ._condition = "", ._media = media },
            CSSMediaRule{ ._proto = undefined },
        });
        rule._proto._proto._proto._type = .{ .media = rule };
        try parseInto(rules, block, rule._proto._proto._proto, frame);
        return rule;
    }

    pub fn getMedia(self: *CSSMediaRule) *MediaList {
        return self._proto._media.?;
    }

    pub fn setMedia(self: *CSSMediaRule, text: []const u8, frame: *Frame) !void {
        try self.getMedia().setMediaText(text, frame);
    }

    pub fn writeCssText(self: *CSSMediaRule, writer: *std.Io.Writer, frame: *Frame) !void {
        try writeBlockRule(writer, "media", try self.getMedia().getMediaText(frame), self._proto._proto._rules, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSMediaRule);

        pub const Meta = struct {
            pub const name = "CSSMediaRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const media = bridge.accessor(CSSMediaRule.getMedia, CSSMediaRule.setMedia, .{});
    };
};

pub const CSSSupportsRule = struct {
    pub const Proto = CSSConditionRule;

    _proto: *CSSConditionRule,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSSupportsRule {
        const rules = try CSSRuleList.init(frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSGroupingRule{ ._proto = undefined, ._rules = rules },
            CSSConditionRule{ ._proto = undefined, ._condition = try frame.dupeString(prelude) },
            CSSSupportsRule{ ._proto = undefined },
        });
        rule._proto._proto._proto._type = .{ .supports = rule };
        try parseInto(rules, block, rule._proto._proto._proto, frame);
        return rule;
    }

    pub fn writeCssText(self: *CSSSupportsRule, writer: *std.Io.Writer, frame: *Frame) !void {
        try writeBlockRule(writer, "supports", self._proto._condition, self._proto._proto._rules, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSSupportsRule);

        pub const Meta = struct {
            pub const name = "CSSSupportsRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const CSSContainerRule = struct {
    pub const Proto = CSSConditionRule;

    _proto: *CSSConditionRule,
    _name: []const u8,
    _query: []const u8,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSContainerRule {
        // `@container card (min-width: 10px)`: an optional name, then the
        // query. `@container (min-width: 10px)` has no name.
        var name: []const u8 = "";
        var query = std.mem.trim(u8, prelude, &std.ascii.whitespace);
        if (query.len != 0 and query[0] != '(') {
            const split = std.mem.indexOfAny(u8, query, " \t\r\n(") orelse query.len;
            name = query[0..split];
            query = std.mem.trim(u8, query[split..], &std.ascii.whitespace);
        }

        const rules = try CSSRuleList.init(frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSGroupingRule{ ._proto = undefined, ._rules = rules },
            CSSConditionRule{ ._proto = undefined, ._condition = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)) },
            CSSContainerRule{
                ._proto = undefined,
                ._name = try frame.dupeString(name),
                ._query = try frame.dupeString(query),
            },
        });
        rule._proto._proto._proto._type = .{ .container = rule };
        try parseInto(rules, block, rule._proto._proto._proto, frame);
        return rule;
    }

    pub fn getContainerName(self: *const CSSContainerRule) []const u8 {
        return self._name;
    }

    pub fn getContainerQuery(self: *const CSSContainerRule) []const u8 {
        return self._query;
    }

    /// Chrome hands back the parsed query segments. We do not model container
    /// query internals, so this is the whole query as a single segment.
    pub fn getConditions(self: *const CSSContainerRule, frame: *Frame) ![]const []const u8 {
        const list = try frame.local_arena.alloc([]const u8, 1);
        list[0] = self._query;
        return list;
    }

    pub fn writeCssText(self: *CSSContainerRule, writer: *std.Io.Writer, frame: *Frame) !void {
        try writeBlockRule(writer, "container", self._proto._condition, self._proto._proto._rules, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSContainerRule);

        pub const Meta = struct {
            pub const name = "CSSContainerRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const containerName = bridge.accessor(CSSContainerRule.getContainerName, null, .{});
        pub const containerQuery = bridge.accessor(CSSContainerRule.getContainerQuery, null, .{});
        pub const conditions = bridge.accessor(CSSContainerRule.getConditions, null, .{});
    };
};

// ---------------------------------------------------------------------------
// @layer (block and statement forms)
// ---------------------------------------------------------------------------

pub const CSSLayerBlockRule = struct {
    pub const Proto = CSSGroupingRule;

    _proto: *CSSGroupingRule,
    _name: []const u8,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSLayerBlockRule {
        const rules = try CSSRuleList.init(frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSGroupingRule{ ._proto = undefined, ._rules = rules },
            CSSLayerBlockRule{ ._proto = undefined, ._name = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)) },
        });
        rule._proto._proto._type = .{ .layer_block = rule };
        try parseInto(rules, block, rule._proto._proto, frame);
        return rule;
    }

    pub fn getName(self: *const CSSLayerBlockRule) []const u8 {
        return self._name;
    }

    pub fn writeCssText(self: *CSSLayerBlockRule, writer: *std.Io.Writer, frame: *Frame) !void {
        try writeBlockRule(writer, "layer", self._name, self._proto._rules, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSLayerBlockRule);

        pub const Meta = struct {
            pub const name = "CSSLayerBlockRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(CSSLayerBlockRule.getName, null, .{});
    };
};

pub const CSSLayerStatementRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _names: []const []const u8,

    pub fn init(prelude: []const u8, frame: *Frame) !*CSSLayerStatementRule {
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, prelude, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            try names.append(frame.arena, try frame.dupeString(trimmed));
        }

        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSLayerStatementRule{ ._proto = undefined, ._names = names.items },
        });
        rule._proto._type = .{ .layer_statement = rule };
        return rule;
    }

    pub fn getNameList(self: *const CSSLayerStatementRule) []const []const u8 {
        return self._names;
    }

    pub fn writeCssText(self: *CSSLayerStatementRule, writer: *std.Io.Writer) !void {
        try writer.writeAll("@layer ");
        for (self._names, 0..) |layer_name, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.writeAll(layer_name);
        }
        try writer.writeAll(";");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSLayerStatementRule);

        pub const Meta = struct {
            pub const name = "CSSLayerStatementRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const nameList = bridge.accessor(CSSLayerStatementRule.getNameList, null, .{});
    };
};

// ---------------------------------------------------------------------------
// @import / @namespace
// ---------------------------------------------------------------------------

pub const CSSImportRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _href: []const u8,
    _layer_name: ?[]const u8,
    _supports_text: ?[]const u8,
    _media: *MediaList,

    pub fn init(prelude: []const u8, frame: *Frame) !*CSSImportRule {
        var rest = std.mem.trim(u8, prelude, &std.ascii.whitespace);
        const href = try frame.dupeString(takeUrl(&rest));

        // `layer(base)` and `supports(...)` are optional and, measured, read
        // back as null rather than "" when absent.
        var layer_name: ?[]const u8 = null;
        var supports_text: ?[]const u8 = null;
        while (true) {
            rest = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (takeFunction(&rest, "layer")) |value| {
                layer_name = try frame.dupeString(value);
                continue;
            }
            if (takeFunction(&rest, "supports")) |value| {
                supports_text = try frame.dupeString(value);
                continue;
            }
            break;
        }

        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSImportRule{
                ._proto = undefined,
                ._href = href,
                ._layer_name = layer_name,
                ._supports_text = supports_text,
                ._media = try MediaList.initWithText(rest, frame),
            },
        });
        rule._proto._type = .{ .import = rule };
        return rule;
    }

    /// Consume a leading `url("x")`, `url(x)` or bare `"x"` and answer its
    /// contents, advancing `rest` past it.
    fn takeUrl(rest: *[]const u8) []const u8 {
        var text = std.mem.trim(u8, rest.*, &std.ascii.whitespace);
        if (std.ascii.startsWithIgnoreCase(text, "url(")) {
            const close = std.mem.indexOfScalar(u8, text, ')') orelse text.len;
            const inner = text[4..@min(close, text.len)];
            rest.* = if (close < text.len) text[close + 1 ..] else "";
            return std.mem.trim(u8, std.mem.trim(u8, inner, &std.ascii.whitespace), "\"'");
        }
        if (text.len != 0 and (text[0] == '"' or text[0] == '\'')) {
            const quote = text[0];
            const close = std.mem.indexOfScalarPos(u8, text, 1, quote) orelse text.len;
            const inner = text[1..@min(close, text.len)];
            rest.* = if (close < text.len) text[close + 1 ..] else "";
            return inner;
        }
        const split = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
        const value = text[0..split];
        rest.* = text[split..];
        return value;
    }

    /// Consume a leading `<name>(<contents>)` and answer the contents.
    fn takeFunction(rest: *[]const u8, comptime name: []const u8) ?[]const u8 {
        const text = rest.*;
        if (!std.ascii.startsWithIgnoreCase(text, name ++ "(")) return null;
        var depth: usize = 0;
        for (text[name.len..], name.len..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) {
                    rest.* = text[i + 1 ..];
                    return std.mem.trim(u8, text[name.len + 1 .. i], &std.ascii.whitespace);
                }
            }
        }
        return null;
    }

    pub fn getHref(self: *const CSSImportRule) []const u8 {
        return self._href;
    }

    pub fn getMedia(self: *const CSSImportRule) *MediaList {
        return self._media;
    }

    pub fn setMedia(self: *const CSSImportRule, text: []const u8, frame: *Frame) !void {
        try self._media.setMediaText(text, frame);
    }

    /// We never fetch imported sheets, so this is always null — which is also
    /// what Chrome answers for an import that has not loaded.
    pub fn getStyleSheet(_: *const CSSImportRule) ?*CSSRule {
        return null;
    }

    pub fn getLayerName(self: *const CSSImportRule) ?[]const u8 {
        return self._layer_name;
    }

    pub fn getSupportsText(self: *const CSSImportRule) ?[]const u8 {
        return self._supports_text;
    }

    pub fn writeCssText(self: *CSSImportRule, writer: *std.Io.Writer, frame: *Frame) !void {
        try writer.print("@import url(\"{s}\")", .{self._href});
        if (self._layer_name) |layer_name| try writer.print(" layer({s})", .{layer_name});
        if (self._supports_text) |supports| try writer.print(" supports({s})", .{supports});
        const media_text = try self._media.getMediaText(frame);
        if (media_text.len != 0) try writer.print(" {s}", .{media_text});
        try writer.writeAll(";");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSImportRule);

        pub const Meta = struct {
            pub const name = "CSSImportRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const href = bridge.accessor(CSSImportRule.getHref, null, .{});
        pub const media = bridge.accessor(CSSImportRule.getMedia, CSSImportRule.setMedia, .{});
        pub const styleSheet = bridge.accessor(CSSImportRule.getStyleSheet, null, .{});
        pub const layerName = bridge.accessor(CSSImportRule.getLayerName, null, .{});
        pub const supportsText = bridge.accessor(CSSImportRule.getSupportsText, null, .{});
    };
};

pub const CSSNamespaceRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _namespace_uri: []const u8,
    _prefix: []const u8,

    pub fn init(prelude: []const u8, frame: *Frame) !*CSSNamespaceRule {
        // `@namespace svg url(...)` or `@namespace url(...)` — the prefix is
        // optional and empty when absent.
        var rest = std.mem.trim(u8, prelude, &std.ascii.whitespace);
        var prefix: []const u8 = "";
        if (!std.ascii.startsWithIgnoreCase(rest, "url(") and rest.len != 0 and rest[0] != '"' and rest[0] != '\'') {
            const split = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
            prefix = rest[0..split];
            rest = rest[split..];
        }
        const uri = CSSImportRule.takeUrl(&rest);

        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSNamespaceRule{
                ._proto = undefined,
                ._namespace_uri = try frame.dupeString(uri),
                ._prefix = try frame.dupeString(prefix),
            },
        });
        rule._proto._type = .{ .namespace = rule };
        return rule;
    }

    pub fn getNamespaceURI(self: *const CSSNamespaceRule) []const u8 {
        return self._namespace_uri;
    }

    pub fn getPrefix(self: *const CSSNamespaceRule) []const u8 {
        return self._prefix;
    }

    pub fn writeCssText(self: *CSSNamespaceRule, writer: *std.Io.Writer) !void {
        if (self._prefix.len == 0) {
            try writer.print("@namespace url(\"{s}\");", .{self._namespace_uri});
        } else {
            try writer.print("@namespace {s} url(\"{s}\");", .{ self._prefix, self._namespace_uri });
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSNamespaceRule);

        pub const Meta = struct {
            pub const name = "CSSNamespaceRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const namespaceURI = bridge.accessor(CSSNamespaceRule.getNamespaceURI, null, .{});
        pub const prefix = bridge.accessor(CSSNamespaceRule.getPrefix, null, .{});
    };
};

// ---------------------------------------------------------------------------
// @font-face / @page — the two rules whose block is a CSSStyleDeclaration
// ---------------------------------------------------------------------------

pub const CSSFontFaceRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _style: *CSSStyleDeclaration,

    pub fn init(block: []const u8, frame: *Frame) !*CSSFontFaceRule {
        const style = try CSSStyleDeclaration.init(null, false, frame);
        // Before the text is parsed: the block holds descriptors, not
        // properties, and three of them take a range the property does not.
        style._is_descriptors = true;
        try style.setCssText(block, frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSFontFaceRule{ ._proto = undefined, ._style = style },
        });
        rule._proto._type = .{ .font_face = rule };
        return rule;
    }

    pub fn getStyle(self: *const CSSFontFaceRule) *CSSStyleDeclaration {
        return self._style;
    }

    pub fn writeCssText(self: *CSSFontFaceRule, writer: *std.Io.Writer) !void {
        try writer.writeAll("@font-face { ");
        try self._style.format(writer);
        try writer.writeAll(" }");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSFontFaceRule);

        pub const Meta = struct {
            pub const name = "CSSFontFaceRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const style = bridge.accessor(CSSFontFaceRule.getStyle, null, .{});
    };
};

/// Measured: CSSPageRule descends from CSSGroupingRule (margin at-rules live
/// in its cssRules), but it is not a CSSConditionRule.
pub const CSSPageRule = struct {
    pub const Proto = CSSGroupingRule;

    _proto: *CSSGroupingRule,
    _selector_text: []const u8,
    _style: *CSSStyleDeclaration,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSPageRule {
        const style = try CSSStyleDeclaration.init(null, false, frame);
        try style.setCssText(block, frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSGroupingRule{ ._proto = undefined, ._rules = try CSSRuleList.init(frame) },
            CSSPageRule{
                ._proto = undefined,
                ._selector_text = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)),
                ._style = style,
            },
        });
        rule._proto._proto._type = .{ .page = rule };
        return rule;
    }

    pub fn getSelectorText(self: *const CSSPageRule) []const u8 {
        return self._selector_text;
    }

    pub fn setSelectorText(self: *CSSPageRule, text: []const u8, frame: *Frame) !void {
        self._selector_text = try frame.dupeString(text);
    }

    pub fn getStyle(self: *const CSSPageRule) *CSSStyleDeclaration {
        return self._style;
    }

    pub fn setStyle(self: *CSSPageRule, text: []const u8, frame: *Frame) !void {
        try self._style.setCssText(text, frame);
    }

    pub fn writeCssText(self: *CSSPageRule, writer: *std.Io.Writer) !void {
        if (self._selector_text.len == 0) {
            try writer.writeAll("@page { ");
        } else {
            try writer.print("@page {s} {{ ", .{self._selector_text});
        }
        try self._style.format(writer);
        try writer.writeAll(" }");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSPageRule);

        pub const Meta = struct {
            pub const name = "CSSPageRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const selectorText = bridge.accessor(CSSPageRule.getSelectorText, CSSPageRule.setSelectorText, .{});
        pub const style = bridge.accessor(CSSPageRule.getStyle, CSSPageRule.setStyle, .{});
    };
};

// ---------------------------------------------------------------------------
// The descriptor at-rules
// ---------------------------------------------------------------------------

pub const CSSFontPaletteValuesRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _name: []const u8,
    _descriptors: Descriptors,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSFontPaletteValuesRule {
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSFontPaletteValuesRule{
                ._proto = undefined,
                ._name = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)),
                ._descriptors = try Descriptors.parse(block, frame),
            },
        });
        rule._proto._type = .{ .font_palette_values = rule };
        return rule;
    }

    pub fn getName(self: *const CSSFontPaletteValuesRule) []const u8 {
        return self._name;
    }

    pub fn getFontFamily(self: *const CSSFontPaletteValuesRule) []const u8 {
        return self._descriptors.get("font-family");
    }

    pub fn getBasePalette(self: *const CSSFontPaletteValuesRule) []const u8 {
        return self._descriptors.get("base-palette");
    }

    pub fn getOverrideColors(self: *const CSSFontPaletteValuesRule) []const u8 {
        return self._descriptors.get("override-colors");
    }

    pub fn writeCssText(self: *CSSFontPaletteValuesRule, writer: *std.Io.Writer) !void {
        try writeDescriptorRule(writer, "font-palette-values", self._name, &self._descriptors);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSFontPaletteValuesRule);

        pub const Meta = struct {
            pub const name = "CSSFontPaletteValuesRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(CSSFontPaletteValuesRule.getName, null, .{});
        pub const fontFamily = bridge.accessor(CSSFontPaletteValuesRule.getFontFamily, null, .{});
        pub const basePalette = bridge.accessor(CSSFontPaletteValuesRule.getBasePalette, null, .{});
        pub const overrideColors = bridge.accessor(CSSFontPaletteValuesRule.getOverrideColors, null, .{});
    };
};

/// Every descriptor here is a getter/setter pair in Chrome, unlike the other
/// descriptor rules whose members are read-only.
pub const CSSCounterStyleRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _name: []const u8,
    _descriptors: Descriptors,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSCounterStyleRule {
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSCounterStyleRule{
                ._proto = undefined,
                ._name = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)),
                ._descriptors = try Descriptors.parse(block, frame),
            },
        });
        rule._proto._type = .{ .counter_style = rule };
        return rule;
    }

    fn set(self: *CSSCounterStyleRule, comptime descriptor: []const u8, value: []const u8, frame: *Frame) !void {
        for (self._descriptors._items.items) |*item| {
            if (std.ascii.eqlIgnoreCase(item.name, descriptor)) {
                item.value = try frame.dupeString(value);
                return;
            }
        }
        try self._descriptors._items.append(frame.arena, .{
            .name = descriptor,
            .value = try frame.dupeString(value),
        });
    }

    pub fn getName(self: *const CSSCounterStyleRule) []const u8 {
        return self._name;
    }

    pub fn setName(self: *CSSCounterStyleRule, value: []const u8, frame: *Frame) !void {
        self._name = try frame.dupeString(value);
    }

    pub fn writeCssText(self: *CSSCounterStyleRule, writer: *std.Io.Writer) !void {
        try writeDescriptorRule(writer, "counter-style", self._name, &self._descriptors);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSCounterStyleRule);

        pub const Meta = struct {
            pub const name = "CSSCounterStyleRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(CSSCounterStyleRule.getName, CSSCounterStyleRule.setName, .{});
        pub const system = Descriptor("system").pair;
        pub const symbols = Descriptor("symbols").pair;
        pub const additiveSymbols = Descriptor("additive-symbols").pair;
        pub const negative = Descriptor("negative").pair;
        pub const prefix = Descriptor("prefix").pair;
        pub const suffix = Descriptor("suffix").pair;
        pub const range = Descriptor("range").pair;
        pub const pad = Descriptor("pad").pair;
        pub const speakAs = Descriptor("speak-as").pair;
        pub const fallback = Descriptor("fallback").pair;

        /// Every counter-style descriptor is a getter/setter pair over the
        /// same parsed block, so they are generated rather than hand-written.
        fn Descriptor(comptime descriptor: []const u8) type {
            return struct {
                fn get(self: *const CSSCounterStyleRule) []const u8 {
                    return self._descriptors.get(descriptor);
                }
                fn setValue(self: *CSSCounterStyleRule, value: []const u8, frame: *Frame) !void {
                    try self.set(descriptor, value, frame);
                }
                pub const pair = bridge.accessor(get, setValue, .{});
            };
        }
    };
};

pub const CSSPropertyRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _name: []const u8,
    _descriptors: Descriptors,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSPropertyRule {
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSPropertyRule{
                ._proto = undefined,
                ._name = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)),
                ._descriptors = try Descriptors.parse(block, frame),
            },
        });
        rule._proto._type = .{ .property = rule };
        return rule;
    }

    pub fn getName(self: *const CSSPropertyRule) []const u8 {
        return self._name;
    }

    /// Measured: the quotes around the syntax string are stripped on the way
    /// out, so `syntax: "<length>"` reads back as `<length>`.
    pub fn getSyntax(self: *const CSSPropertyRule) []const u8 {
        return std.mem.trim(u8, self._descriptors.get("syntax"), "\"'");
    }

    /// A real boolean, not the descriptor's text.
    pub fn getInherits(self: *const CSSPropertyRule) bool {
        return std.ascii.eqlIgnoreCase(self._descriptors.get("inherits"), "true");
    }

    /// Chrome answers null when the rule omits initial-value.
    pub fn getInitialValue(self: *const CSSPropertyRule) ?[]const u8 {
        const value = self._descriptors.get("initial-value");
        return if (value.len == 0) null else value;
    }

    pub fn writeCssText(self: *CSSPropertyRule, writer: *std.Io.Writer) !void {
        try writeDescriptorRule(writer, "property", self._name, &self._descriptors);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSPropertyRule);

        pub const Meta = struct {
            pub const name = "CSSPropertyRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(CSSPropertyRule.getName, null, .{});
        pub const syntax = bridge.accessor(CSSPropertyRule.getSyntax, null, .{});
        pub const inherits = bridge.accessor(CSSPropertyRule.getInherits, null, .{});
        pub const initialValue = bridge.accessor(CSSPropertyRule.getInitialValue, null, .{});
    };
};

// ---------------------------------------------------------------------------
// @keyframes and its children
// ---------------------------------------------------------------------------

pub const CSSKeyframesRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _name: []const u8,
    _rules: *CSSRuleList,

    pub fn init(prelude: []const u8, block: []const u8, frame: *Frame) !*CSSKeyframesRule {
        const rules = try CSSRuleList.init(frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSKeyframesRule{
                ._proto = undefined,
                ._name = try frame.dupeString(std.mem.trim(u8, prelude, &std.ascii.whitespace)),
                ._rules = rules,
            },
        });
        rule._proto._type = .{ .keyframes = rule };

        var it = Parser.parseStylesheet(block);
        var index: u32 = 0;
        while (it.next()) |parsed| {
            const style = switch (parsed) {
                .style => |s| s,
                .at_rule => continue,
            };
            const keyframe = try CSSKeyframeRule.init(style.selector, style.block, frame);
            keyframe._proto._parent_rule = rule._proto;
            try rules.insert(index, keyframe._proto, frame);
            index += 1;
        }
        return rule;
    }

    pub fn getName(self: *const CSSKeyframesRule) []const u8 {
        return self._name;
    }

    pub fn setName(self: *CSSKeyframesRule, value: []const u8, frame: *Frame) !void {
        self._name = try frame.dupeString(value);
    }

    pub fn getCssRules(self: *const CSSKeyframesRule) *CSSRuleList {
        return self._rules;
    }

    pub fn appendRule(self: *CSSKeyframesRule, text: []const u8, frame: *Frame) !void {
        var it = Parser.parseStylesheet(text);
        const parsed = it.next() orelse return;
        const style = switch (parsed) {
            .style => |s| s,
            .at_rule => return,
        };
        const keyframe = try CSSKeyframeRule.init(style.selector, style.block, frame);
        keyframe._proto._parent_rule = self._proto;
        try self._rules.insert(self._rules.length(), keyframe._proto, frame);
    }

    /// Measured: deleting a key that is not present is silently ignored.
    pub fn deleteRule(self: *CSSKeyframesRule, select: []const u8, frame: *Frame) !void {
        const wanted = try CSSKeyframeRule.normalizeKeyText(select, frame) orelse return;
        for (self._rules._rules.items, 0..) |rule, i| {
            const keyframe = rule._type.keyframe;
            if (std.mem.eql(u8, keyframe._key_text, wanted)) {
                try self._rules.remove(@intCast(i));
                return;
            }
        }
    }

    pub fn findRule(self: *CSSKeyframesRule, select: []const u8, frame: *Frame) !?*CSSRule {
        const wanted = try CSSKeyframeRule.normalizeKeyText(select, frame) orelse return null;
        for (self._rules._rules.items) |rule| {
            if (std.mem.eql(u8, rule._type.keyframe._key_text, wanted)) return rule;
        }
        return null;
    }

    pub fn getLength(self: *const CSSKeyframesRule) u32 {
        return self._rules.length();
    }

    pub fn item(self: *const CSSKeyframesRule, index: usize) ?*CSSRule {
        return self._rules.item(index);
    }

    pub fn values(self: *CSSKeyframesRule, exec: *js.Execution) !*ValueIterator {
        return .init(.{ .rule = self }, exec);
    }

    const Iterator = struct {
        index: u32 = 0,
        rule: *CSSKeyframesRule,

        const Entry = struct { u32, *CSSRule };

        pub fn next(self: *Iterator, _: *js.Execution) ?Entry {
            const index = self.index;
            const value = self.rule.item(index) orelse return null;
            self.index = index + 1;
            return .{ index, value };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const ValueIterator = GenericIterator(Iterator, "1");

    /// `@keyframes spin { \n  0% { ... }\n}` — note the space Chrome leaves
    /// after the brace before the newline, which the other block rules do
    /// not have.
    pub fn writeCssText(self: *CSSKeyframesRule, writer: *std.Io.Writer, frame: *Frame) !void {
        try writer.print("@keyframes {s} {{ \n", .{self._name});
        for (self._rules._rules.items) |child| {
            try writer.print("  {s}\n", .{try child.getCssText(frame)});
        }
        try writer.writeAll("}");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSKeyframesRule);

        pub const Meta = struct {
            pub const name = "CSSKeyframesRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(CSSKeyframesRule.getName, CSSKeyframesRule.setName, .{});
        pub const cssRules = bridge.accessor(CSSKeyframesRule.getCssRules, null, .{});
        pub const appendRule = bridge.function(CSSKeyframesRule.appendRule, .{});
        pub const deleteRule = bridge.function(CSSKeyframesRule.deleteRule, .{});
        pub const findRule = bridge.function(CSSKeyframesRule.findRule, .{});
        pub const length = bridge.accessor(CSSKeyframesRule.getLength, null, .{});
        pub const @"[]" = bridge.indexed(CSSKeyframesRule.item, getIndexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(CSSKeyframesRule.values, .{});

        /// The indices are own properties, as in CSSRuleList -- see the note
        /// there. A `@keyframes` rule is itself the indexed thing: `rule[0]` is
        /// its first keyframe.
        fn getIndexes(self: *CSSKeyframesRule, exec: *const js.Execution) !js.Array {
            const len = self.getLength();
            var arr = exec.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }
    };
};

pub const CSSKeyframeRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _key_text: []const u8,
    _style: *CSSStyleDeclaration,

    pub fn init(key_text: []const u8, block: []const u8, frame: *Frame) !*CSSKeyframeRule {
        const style = try CSSStyleDeclaration.init(null, false, frame);
        try style.setCssText(block, frame);
        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSKeyframeRule{
                ._proto = undefined,
                ._key_text = (try normalizeKeyText(key_text, frame)) orelse "0%",
                ._style = style,
            },
        });
        rule._proto._type = .{ .keyframe = rule };
        return rule;
    }

    /// Measured: `from`/`to` normalise to `0%`/`100%` on the way in, a list
    /// keeps its commas, and anything else is a SyntaxError. Answers null for
    /// input Chrome rejects.
    pub fn normalizeKeyText(text: []const u8, frame: *Frame) !?[]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.arena);
        var it = std.mem.splitScalar(u8, text, ',');
        var count: usize = 0;
        while (it.next()) |raw| {
            const part = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (part.len == 0) return null;
            if (count != 0) try buf.writer.writeAll(", ");
            count += 1;
            if (std.ascii.eqlIgnoreCase(part, "from")) {
                try buf.writer.writeAll("0%");
                continue;
            }
            if (std.ascii.eqlIgnoreCase(part, "to")) {
                try buf.writer.writeAll("100%");
                continue;
            }
            if (part[part.len - 1] != '%') return null;
            _ = std.fmt.parseFloat(f64, part[0 .. part.len - 1]) catch return null;
            try buf.writer.writeAll(part);
        }
        if (count == 0) return null;
        return buf.written();
    }

    pub fn getKeyText(self: *const CSSKeyframeRule) []const u8 {
        return self._key_text;
    }

    pub fn setKeyText(self: *CSSKeyframeRule, text: []const u8, frame: *Frame) !void {
        self._key_text = (try normalizeKeyText(text, frame)) orelse return error.SyntaxError;
    }

    pub fn getStyle(self: *const CSSKeyframeRule) *CSSStyleDeclaration {
        return self._style;
    }

    pub fn setStyle(self: *CSSKeyframeRule, text: []const u8, frame: *Frame) !void {
        try self._style.setCssText(text, frame);
    }

    pub fn writeCssText(self: *CSSKeyframeRule, writer: *std.Io.Writer) !void {
        try writer.print("{s} {{ ", .{self._key_text});
        try self._style.format(writer);
        try writer.writeAll(" }");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSKeyframeRule);

        pub const Meta = struct {
            pub const name = "CSSKeyframeRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const keyText = bridge.accessor(CSSKeyframeRule.getKeyText, CSSKeyframeRule.setKeyText, .{});
        pub const style = bridge.accessor(CSSKeyframeRule.getStyle, CSSKeyframeRule.setStyle, .{});
    };
};

// ---------------------------------------------------------------------------
// Prototype surface only: at-rules nothing here parses yet
// ---------------------------------------------------------------------------
//
// Chrome 151 puts eleven more CSSOM interfaces on the window than we model, and
// a detector reads `Object.getOwnPropertyNames(window)` long before it reads a
// stylesheet -- so the interface objects and their prototype chains are the part
// that has to exist. The parser hands out none of these: `@scope`,
// `@starting-style`, `@position-try`, `@function`, `@margin`,
// `@font-feature-values` and a nested declaration block all still come back as
// the `.unknown` placeholder, which round-trips its source text.
//
// Every member list, argument count and prototype root below is Chrome's own,
// measured with probes/probe-shapes.js on http://localhost (the readings are in
// results/probes/probe-shapes.chrome.json). Omitting `constructor` is what makes
// `new CSSScopeRule()` answer "Illegal constructor", which is what Chrome does.

/// `@font-feature-values`. The six maps Chrome answers here are
/// CSSFontFeatureValuesMap objects, an interface it does *not* put on the
/// window, so there is nothing for these getters to answer but null.
pub const CSSFontFeatureValuesRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,

    pub fn getFontFamily(_: *const CSSFontFeatureValuesRule) []const u8 {
        return "";
    }

    pub fn setFontFamily(_: *CSSFontFeatureValuesRule, _: []const u8) void {}

    /// Chrome answers a CSSFontFeatureValuesMap, an interface it does not put on
    /// the window, so there is no type here to answer with.
    pub fn getMap(_: *const CSSFontFeatureValuesRule) ?js.Value {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSFontFeatureValuesRule);

        pub const Meta = struct {
            pub const name = "CSSFontFeatureValuesRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const R = CSSFontFeatureValuesRule;

        pub const fontFamily = bridge.accessor(R.getFontFamily, R.setFontFamily, .{});
        pub const annotation = bridge.accessor(R.getMap, null, .{});
        pub const ornaments = bridge.accessor(R.getMap, null, .{});
        pub const stylistic = bridge.accessor(R.getMap, null, .{});
        pub const swash = bridge.accessor(R.getMap, null, .{});
        pub const characterVariant = bridge.accessor(R.getMap, null, .{});
        pub const styleset = bridge.accessor(R.getMap, null, .{});
    };
};

/// The declaration block inside a `@function` body, and the nested declarations
/// a nested style rule collects: same shape, one `style` each.
fn StyleOnlyRule(comptime js_name: []const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = CSSRule;

        _proto: *CSSRule,

        pub fn getStyle(_: *const Self) ?*CSSStyleDeclaration {
            return null;
        }

        /// `[PutForwards=cssText]`, so the setter takes the declaration text --
        /// and with no declaration behind it there is nowhere to put it.
        pub fn setStyle(_: *Self, _: []const u8) void {}

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = js_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const style = bridge.accessor(Self.getStyle, Self.setStyle, .{});
        };
    };
}

pub const CSSFunctionDeclarations = StyleOnlyRule("CSSFunctionDeclarations");
pub const CSSNestedDeclarations = StyleOnlyRule("CSSNestedDeclarations");

/// `@function --foo(--arg) { result: ... }`. A grouping rule: the body holds
/// CSSFunctionDeclarations children.
pub const CSSFunctionRule = struct {
    pub const Proto = CSSGroupingRule;

    _proto: *CSSGroupingRule,

    pub fn getName(_: *const CSSFunctionRule) []const u8 {
        return "";
    }

    pub fn getReturnType(_: *const CSSFunctionRule) []const u8 {
        return "";
    }

    pub fn getParameters(_: *const CSSFunctionRule) []const js.Value {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSFunctionRule);

        pub const Meta = struct {
            pub const name = "CSSFunctionRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(CSSFunctionRule.getName, null, .{});
        pub const returnType = bridge.accessor(CSSFunctionRule.getReturnType, null, .{});
        pub const getParameters = bridge.function(CSSFunctionRule.getParameters, .{});
    };
};

/// A page-margin box (`@top-center` inside `@page`), and `@position-try`: both
/// are a name plus a declaration block, both hang straight off CSSRule.
fn NamedStyleRule(comptime js_name: []const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = CSSRule;

        _proto: *CSSRule,

        pub fn getName(_: *const Self) []const u8 {
            return "";
        }

        pub fn getStyle(_: *const Self) ?*CSSStyleDeclaration {
            return null;
        }

        pub fn setStyle(_: *Self, _: []const u8) void {}

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = js_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const name = bridge.accessor(Self.getName, null, .{});
            pub const style = bridge.accessor(Self.getStyle, Self.setStyle, .{});
        };
    };
}

pub const CSSMarginRule = NamedStyleRule("CSSMarginRule");
pub const CSSPositionTryRule = NamedStyleRule("CSSPositionTryRule");

/// `@scope (start) to (end)`. Both bounds are nullable selector text.
pub const CSSScopeRule = struct {
    pub const Proto = CSSGroupingRule;

    _proto: *CSSGroupingRule,

    pub fn getBound(_: *const CSSScopeRule) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSScopeRule);

        pub const Meta = struct {
            pub const name = "CSSScopeRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const start = bridge.accessor(CSSScopeRule.getBound, null, .{});
        pub const end = bridge.accessor(CSSScopeRule.getBound, null, .{});
    };
};

/// `@starting-style`. Adds nothing of its own, like `@supports`.
pub const CSSStartingStyleRule = struct {
    pub const Proto = CSSGroupingRule;

    _proto: *CSSGroupingRule,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSStartingStyleRule);

        pub const Meta = struct {
            pub const name = "CSSStartingStyleRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

/// `@view-transition`, whose two descriptors are validated one at a time.
///
/// Every reading here is Chrome 151's, from probes/view-transition-rule.js
/// (results/probes/view-transition-rule.chrome.json):
///
///   - An absent descriptor reads as `""` / `[]`, not as its initial value.
///   - `navigation` takes `auto` or `none`, folded to lower case; anything else
///     -- including `auto !important` -- drops the declaration.
///   - `types` is a whitespace-separated `<custom-ident>` list. `none` alone is
///     valid and means the empty list, but still serialises. A comma, a
///     dimension, a string, a CSS-wide keyword, or `none` beside anything else
///     drops the declaration.
///   - Last *valid* declaration wins: a bogus repeat leaves the earlier good
///     one standing.
///   - `cssText` re-serialises navigation first and types second, whatever
///     order the source used, and drops any descriptor it does not know.
///   - `types` is `[SameObject]` on top of being a FrozenArray, so it is the
///     same frozen array on every read -- hence the accessor cache below,
///     which is what every other FrozenArray in the engine does not have.
pub const CSSViewTransitionRule = struct {
    pub const Proto = CSSRule;

    _proto: *CSSRule,
    _navigation: []const u8 = "",
    /// The validated `types` text, kept for serialisation because `none`
    /// serialises and yet produces no entries.
    _types_text: ?[]const u8 = null,
    _types: []const []const u8 = &.{},

    /// Answers null for the input Chrome does not turn into a rule at all: a
    /// bare `@view-transition;` with no block, and any non-empty prelude.
    pub fn init(prelude: []const u8, block: ?[]const u8, frame: *Frame) !?*CSSViewTransitionRule {
        if (std.mem.trim(u8, prelude, &std.ascii.whitespace).len != 0) return null;
        const body = block orelse return null;

        var navigation: []const u8 = "";
        var types_text: ?[]const u8 = null;
        var types: []const []const u8 = &.{};

        var it = Parser.parseDeclarationsList(body);
        while (it.next()) |declaration| {
            if (declaration.important) continue;
            if (std.ascii.eqlIgnoreCase(declaration.name, "navigation")) {
                const value = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
                inline for (.{ "auto", "none" }) |keyword| {
                    if (std.ascii.eqlIgnoreCase(value, keyword)) {
                        navigation = keyword;
                    }
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(declaration.name, "types")) {
                const parsed = try parseTypes(declaration.value, frame) orelse continue;
                types_text = parsed.text;
                types = parsed.list;
            }
        }

        const rule = try frame._factory.chained(.{
            CSSRule{ ._type = undefined },
            CSSViewTransitionRule{
                ._proto = undefined,
                ._navigation = navigation,
                ._types_text = types_text,
                ._types = types,
            },
        });
        rule._proto._type = .{ .view_transition = rule };
        return rule;
    }

    const ParsedTypes = struct {
        /// The list re-joined with single spaces, which is how Chrome
        /// serialises it whatever whitespace the source used.
        text: []const u8,
        list: []const []const u8,
    };

    /// The whole declaration is valid or it is dropped: there is no partial
    /// list. Answers null for the drop.
    fn parseTypes(value: []const u8, frame: *Frame) !?ParsedTypes {
        var idents: std.ArrayList([]const u8) = .empty;
        var saw_none = false;

        var tokenizer: Tokenizer = .{ .input = value };
        while (tokenizer.next()) |token| switch (token) {
            .white_space, .comment => {},
            .ident => |name| {
                // A CSS-wide keyword is not a custom-ident anywhere, and
                // `none` is this descriptor's own reserved word: it stands for
                // the empty list and cannot share the declaration.
                inline for (.{ "initial", "inherit", "unset", "revert", "revert-layer", "default" }) |reserved| {
                    if (std.ascii.eqlIgnoreCase(name, reserved)) return null;
                }
                if (std.ascii.eqlIgnoreCase(name, "none")) {
                    if (saw_none or idents.items.len != 0) return null;
                    saw_none = true;
                    continue;
                }
                if (saw_none) return null;
                try idents.append(frame.arena, try frame.dupeString(name));
            },
            // Anything that is not an ident -- a comma, a dimension, a string,
            // a function -- invalidates the declaration.
            else => return null,
        };

        if (saw_none) return .{ .text = "none", .list = &.{} };
        if (idents.items.len == 0) return null;
        return .{
            .text = try std.mem.join(frame.arena, " ", idents.items),
            .list = idents.items,
        };
    }

    pub fn getNavigation(self: *const CSSViewTransitionRule) []const u8 {
        return self._navigation;
    }

    pub fn getTypes(self: *const CSSViewTransitionRule) js.FrozenArray([]const u8) {
        return .{ .items = self._types };
    }

    pub fn writeCssText(self: *CSSViewTransitionRule, writer: *std.Io.Writer) !void {
        try writer.writeAll("@view-transition { ");
        if (self._navigation.len != 0) {
            try writer.print("navigation: {s}; ", .{self._navigation});
        }
        if (self._types_text) |text| {
            try writer.print("types: {s}; ", .{text});
        }
        try writer.writeAll("}");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSViewTransitionRule);

        pub const Meta = struct {
            pub const name = "CSSViewTransitionRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const navigation = bridge.accessor(CSSViewTransitionRule.getNavigation, null, .{});
        pub const types = bridge.accessor(
            CSSViewTransitionRule.getTypes,
            null,
            .{ .cache = .{ .private = "view_transition_types" } },
        );
    };
};

/// The two CSSStyleDeclaration subclasses that come with the rules above. They
/// are declaration blocks with a restricted property set, and Chrome declares
/// that set on the prototype -- one accessor pair per descriptor, in both the
/// camelCase and the dashed spelling.
pub const CSSFunctionDescriptors = struct {
    pub const Proto = CSSStyleDeclaration;

    _proto: *CSSStyleDeclaration,

    pub fn get(_: *const CSSFunctionDescriptors) []const u8 {
        return "";
    }

    pub fn set(_: *CSSFunctionDescriptors, _: []const u8) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSFunctionDescriptors);

        pub const Meta = struct {
            pub const name = "CSSFunctionDescriptors";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const result = bridge.accessor(CSSFunctionDescriptors.get, CSSFunctionDescriptors.set, .{});
    };
};

/// `@position-try`'s declaration block. Chrome declares its 70 descriptors on
/// the prototype, in both spellings, in this order -- the camelCase runs first
/// and the dashed aliases follow the group they belong to, which is Blink's
/// order and not the property list's.
pub const CSSPositionTryDescriptors = struct {
    pub const Proto = CSSStyleDeclaration;

    _proto: *CSSStyleDeclaration,

    pub fn get(_: *const CSSPositionTryDescriptors) []const u8 {
        return "";
    }

    pub fn set(_: *CSSPositionTryDescriptors, _: []const u8) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSPositionTryDescriptors);

        pub const Meta = struct {
            pub const name = "CSSPositionTryDescriptors";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const D = CSSPositionTryDescriptors;

        pub const margin = bridge.accessor(D.get, D.set, .{});
        pub const marginTop = bridge.accessor(D.get, D.set, .{});
        pub const marginRight = bridge.accessor(D.get, D.set, .{});
        pub const marginBottom = bridge.accessor(D.get, D.set, .{});
        pub const marginLeft = bridge.accessor(D.get, D.set, .{});
        pub const marginBlock = bridge.accessor(D.get, D.set, .{});
        pub const marginBlockStart = bridge.accessor(D.get, D.set, .{});
        pub const marginBlockEnd = bridge.accessor(D.get, D.set, .{});
        pub const marginInline = bridge.accessor(D.get, D.set, .{});
        pub const marginInlineStart = bridge.accessor(D.get, D.set, .{});
        pub const marginInlineEnd = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-top" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-right" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-bottom" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-left" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-block" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-block-start" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-block-end" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-inline" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-inline-start" = bridge.accessor(D.get, D.set, .{});
        pub const @"margin-inline-end" = bridge.accessor(D.get, D.set, .{});
        pub const inset = bridge.accessor(D.get, D.set, .{});
        pub const insetBlock = bridge.accessor(D.get, D.set, .{});
        pub const insetBlockStart = bridge.accessor(D.get, D.set, .{});
        pub const insetBlockEnd = bridge.accessor(D.get, D.set, .{});
        pub const insetInline = bridge.accessor(D.get, D.set, .{});
        pub const insetInlineStart = bridge.accessor(D.get, D.set, .{});
        pub const insetInlineEnd = bridge.accessor(D.get, D.set, .{});
        pub const top = bridge.accessor(D.get, D.set, .{});
        pub const left = bridge.accessor(D.get, D.set, .{});
        pub const right = bridge.accessor(D.get, D.set, .{});
        pub const bottom = bridge.accessor(D.get, D.set, .{});
        pub const @"inset-block" = bridge.accessor(D.get, D.set, .{});
        pub const @"inset-block-start" = bridge.accessor(D.get, D.set, .{});
        pub const @"inset-block-end" = bridge.accessor(D.get, D.set, .{});
        pub const @"inset-inline" = bridge.accessor(D.get, D.set, .{});
        pub const @"inset-inline-start" = bridge.accessor(D.get, D.set, .{});
        pub const @"inset-inline-end" = bridge.accessor(D.get, D.set, .{});
        pub const width = bridge.accessor(D.get, D.set, .{});
        pub const minWidth = bridge.accessor(D.get, D.set, .{});
        pub const maxWidth = bridge.accessor(D.get, D.set, .{});
        pub const height = bridge.accessor(D.get, D.set, .{});
        pub const minHeight = bridge.accessor(D.get, D.set, .{});
        pub const maxHeight = bridge.accessor(D.get, D.set, .{});
        pub const blockSize = bridge.accessor(D.get, D.set, .{});
        pub const minBlockSize = bridge.accessor(D.get, D.set, .{});
        pub const maxBlockSize = bridge.accessor(D.get, D.set, .{});
        pub const inlineSize = bridge.accessor(D.get, D.set, .{});
        pub const minInlineSize = bridge.accessor(D.get, D.set, .{});
        pub const maxInlineSize = bridge.accessor(D.get, D.set, .{});
        pub const @"min-width" = bridge.accessor(D.get, D.set, .{});
        pub const @"max-width" = bridge.accessor(D.get, D.set, .{});
        pub const @"min-height" = bridge.accessor(D.get, D.set, .{});
        pub const @"max-height" = bridge.accessor(D.get, D.set, .{});
        pub const @"block-size" = bridge.accessor(D.get, D.set, .{});
        pub const @"min-block-size" = bridge.accessor(D.get, D.set, .{});
        pub const @"max-block-size" = bridge.accessor(D.get, D.set, .{});
        pub const @"inline-size" = bridge.accessor(D.get, D.set, .{});
        pub const @"min-inline-size" = bridge.accessor(D.get, D.set, .{});
        pub const @"max-inline-size" = bridge.accessor(D.get, D.set, .{});
        pub const placeSelf = bridge.accessor(D.get, D.set, .{});
        pub const alignSelf = bridge.accessor(D.get, D.set, .{});
        pub const justifySelf = bridge.accessor(D.get, D.set, .{});
        pub const @"place-self" = bridge.accessor(D.get, D.set, .{});
        pub const @"align-self" = bridge.accessor(D.get, D.set, .{});
        pub const @"justify-self" = bridge.accessor(D.get, D.set, .{});
        pub const positionAnchor = bridge.accessor(D.get, D.set, .{});
        pub const @"position-anchor" = bridge.accessor(D.get, D.set, .{});
        pub const positionArea = bridge.accessor(D.get, D.set, .{});
        pub const @"position-area" = bridge.accessor(D.get, D.set, .{});
    };
};
