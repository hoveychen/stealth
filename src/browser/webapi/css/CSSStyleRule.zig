const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Parser = @import("../../css/Parser.zig");
const CSSRule = @import("CSSRule.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");
const rules = @import("rules.zig");
const typed_om = @import("typed_om.zig");

const CSSStyleRule = @This();

pub const Proto = CSSRule;

_proto: *CSSRule,
_selector_text: []const u8 = "",
_style: ?*CSSStyleDeclaration = null,
/// CSS nesting: a style rule can hold child style rules. Measured — Chrome
/// puts cssRules/insertRule/deleteRule straight on CSSStyleRule rather than
/// making it a CSSGroupingRule, so the prototype chain stays
/// CSSStyleRule -> CSSRule.
_rules: ?*CSSRuleList = null,

pub fn init(frame: *Frame) !*CSSStyleRule {
    const style_rule = try frame._factory.chained(.{
        CSSRule{ ._type = undefined },
        CSSStyleRule{ ._proto = undefined },
    });
    style_rule._proto._type = .{ .style = style_rule };
    return style_rule;
}

pub fn getSelectorText(self: *const CSSStyleRule) []const u8 {
    return self._selector_text;
}

pub fn setSelectorText(self: *CSSStyleRule, text: []const u8, frame: *Frame) !void {
    self._selector_text = try frame.dupeString(text);
}

pub fn getStyle(self: *CSSStyleRule, frame: *Frame) !*CSSStyleDeclaration {
    if (self._style) |style| {
        return style;
    }
    const style = try CSSStyleDeclaration.init(null, false, frame);
    self._style = style;
    return style;
}

/// Measured: `rule.style = 'color: blue'` does not replace the declaration
/// object, it routes the string through the existing one's cssText.
pub fn setStyle(self: *CSSStyleRule, text: []const u8, frame: *Frame) !void {
    const style = try self.getStyle(frame);
    try style.setCssText(text, frame);
}

/// Measured: a style rule's styleMap is a writable StylePropertyMap over the
/// same declaration `style` hands out, and it is a stable object.
pub fn getStyleMap(self: *CSSStyleRule, frame: *Frame) !*typed_om.StylePropertyMap {
    const declaration = try self.getStyle(frame);
    return declaration.getPropertyMap(frame);
}

pub fn getCssRules(self: *CSSStyleRule, frame: *Frame) !*CSSRuleList {
    if (self._rules) |list| return list;
    const list = try CSSRuleList.init(frame);
    self._rules = list;
    return list;
}

pub fn insertRule(self: *CSSStyleRule, text: []const u8, maybe_index: ?u32, frame: *Frame) !u32 {
    const list = try self.getCssRules(frame);
    const index = maybe_index orelse 0;
    if (index > list.length()) return error.IndexSizeError;

    var it = Parser.parseStylesheet(text);
    const parsed = it.next() orelse return error.SyntaxError;
    if (it.next() != null) return error.SyntaxError;

    const rule = (try rules.buildRule(parsed, frame)) orelse return error.SyntaxError;
    rule._parent_rule = self._proto;
    try list.insert(index, rule, frame);
    frame._style_manager.sheetModified();
    return index;
}

pub fn deleteRule(self: *CSSStyleRule, index: u32, frame: *Frame) !void {
    const list = try self.getCssRules(frame);
    try list.remove(index);
    frame._style_manager.sheetModified();
}

/// One line while the rule has no children, and Chrome's indented multi-line
/// layout once nesting puts one there.
pub fn writeCssText(self: *CSSStyleRule, writer: *std.Io.Writer, frame: *Frame) !void {
    const style = try self.getStyle(frame);
    const children = self._rules;
    if (children == null or children.?.length() == 0) {
        try writer.print("{s} {{ ", .{self._selector_text});
        try style.format(writer);
        try writer.writeAll(" }");
        return;
    }

    try writer.print("{s} {{\n", .{self._selector_text});
    var declarations = std.Io.Writer.Allocating.init(frame.local_arena);
    try style.format(&declarations.writer);
    if (declarations.written().len != 0) {
        try writer.print("  {s}\n", .{declarations.written()});
    }
    for (children.?._rules.items) |child| {
        try writer.print("  {s}\n", .{try child.getCssText(frame)});
    }
    try writer.writeAll("}");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleRule);

    pub const Meta = struct {
        pub const name = "CSSStyleRule";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const selectorText = bridge.accessor(CSSStyleRule.getSelectorText, CSSStyleRule.setSelectorText, .{});
    pub const style = bridge.accessor(CSSStyleRule.getStyle, CSSStyleRule.setStyle, .{});
    pub const styleMap = bridge.accessor(CSSStyleRule.getStyleMap, null, .{});
    pub const cssRules = bridge.accessor(CSSStyleRule.getCssRules, null, .{});
    pub const deleteRule = bridge.function(CSSStyleRule.deleteRule, .{});
    pub const insertRule = bridge.function(CSSStyleRule.insertRule, .{});
};
