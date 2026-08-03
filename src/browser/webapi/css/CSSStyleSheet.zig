const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Parser = @import("../../css/Parser.zig");

const Element = @import("../Element.zig");

const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");
const CSSStyleRule = @import("CSSStyleRule.zig");
const StyleSheet = @import("StyleSheet.zig");
const MediaList = @import("MediaList.zig");
const rules_mod = @import("rules.zig");

const log = lp.log;

const CSSStyleSheet = @This();

pub const CSSError = error{
    OutOfMemory,
    IndexSizeError,
    WriteFailed,
    StringTooLarge,
    SyntaxError,
};

pub const Proto = StyleSheet;

_proto: *StyleSheet,
_css_rules: ?*CSSRuleList = null,
_owner_rule: ?*CSSRule = null,

pub fn init(frame: *Frame) !*CSSStyleSheet {
    return frame._factory.chained(.{
        StyleSheet{},
        CSSStyleSheet{ ._proto = undefined },
    });
}

pub fn initWithOwner(owner: *Element, frame: *Frame) !*CSSStyleSheet {
    return frame._factory.chained(.{
        StyleSheet{ ._owner_node = owner, ._title = owner.getAttributeSafe(.wrap("title")) },
        CSSStyleSheet{ ._proto = undefined },
    });
}

/// Convenience passthroughs: these members live on StyleSheet in JS, but
/// engine-side callers reach them through the CSSStyleSheet they hold.
pub fn getOwnerNode(self: *const CSSStyleSheet) ?*Element {
    return self._proto._owner_node;
}

pub fn setHref(self: *CSSStyleSheet, href: []const u8) void {
    self._proto._href = href;
}

pub fn getDisabled(self: *const CSSStyleSheet) bool {
    return self._proto._disabled;
}

pub fn setDisabled(self: *CSSStyleSheet, disabled: bool) void {
    self._proto._disabled = disabled;
}

pub fn getCssRules(self: *CSSStyleSheet, frame: *Frame) !*CSSRuleList {
    if (self._css_rules) |rules| return rules;

    const rules = try CSSRuleList.init(frame);
    self._css_rules = rules;

    if (self.getOwnerNode()) |owner| {
        // <style> in either namespace owns its rules through its text.
        if (owner.is(Element.Html.Style)) |style| {
            const text = try style.asNode().getTextContentAlloc(frame.local_arena);
            try self.replaceSync(text, frame);
        } else if (owner.is(Element.Svg.Style)) |style| {
            const text = try style.asNode().getTextContentAlloc(frame.local_arena);
            try self.replaceSync(text, frame);
        }
    }

    return rules;
}

pub fn getOwnerRule(self: *const CSSStyleSheet) ?*CSSRule {
    return self._owner_rule;
}

pub fn insertRule(self: *CSSStyleSheet, rule: []const u8, maybe_index: ?u32, frame: *Frame) !u32 {
    const requested_index = maybe_index orelse 0;
    var it = Parser.parseStylesheet(rule);
    const parsed_rule = it.next() orelse return error.SyntaxError;

    if (it.next() != null) return error.SyntaxError;

    const inserted = (try rules_mod.buildRule(parsed_rule, frame)) orelse return error.SyntaxError;
    inserted._parent_style_sheet = self;

    const rules = try self.getCssRules(frame);

    // Per spec, an index > rules.length should throw IndexSizeError. But because
    // we don't process @import and @font-face, indexes that code hard-codes can
    // be off. As a workaround, we clamp to the tail.
    // See #2214 (and the sibling #1970 / #1972 tolerance for at-rules).
    const length = rules.length();
    const index = if (requested_index > length) length else requested_index;
    if (index != requested_index) {
        log.debug(.not_implemented, "insertRule clamped index", .{});
    }
    try rules.insert(index, inserted, frame);

    // Notify StyleManager that rules have changed
    frame._style_manager.sheetModified();

    return index;
}

pub fn deleteRule(self: *CSSStyleSheet, index: u32, frame: *Frame) !void {
    const rules = try self.getCssRules(frame);
    try rules.remove(index);

    // Notify StyleManager that rules have changed
    frame._style_manager.sheetModified();
}

/// How a rule interacts with the leading `@import` window.
const ImportWindowKind = enum { import, transparent, closes_window };

fn importWindowKind(parsed_rule: Parser.Rule) ImportWindowKind {
    const at_rule = switch (parsed_rule) {
        .style => return .closes_window,
        .at_rule => |a| a,
    };
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(at_rule.keyword, "import")) return .import;
    if (eql(at_rule.keyword, "charset")) return .transparent;
    // Only the statement form of @layer is transparent; a block closes it.
    if (eql(at_rule.keyword, "layer") and at_rule.block == null) return .transparent;
    return .closes_window;
}

/// The IE-era aliases Chrome still ships. Measured: `addRule` appends and
/// answers -1 (not the index), `removeRule` answers undefined, and calling
/// `addRule()` with no selector is a TypeError.
pub fn addRule(self: *CSSStyleSheet, selector_: ?[]const u8, declarations_: ?[]const u8, index_: ?u32, frame: *Frame) !i32 {
    // Chrome declares every argument optional (arity 0) but rejects the
    // zero-argument call at runtime.
    const selector = selector_ orelse return error.TypeError;
    const declarations = declarations_ orelse "";
    const text = try std.fmt.allocPrint(frame.local_arena, "{s} {{ {s} }}", .{ selector, declarations });
    const rules = try self.getCssRules(frame);
    _ = try self.insertRule(text, index_ orelse rules.length(), frame);
    return -1;
}

pub fn removeRule(self: *CSSStyleSheet, index_: ?u32, frame: *Frame) !void {
    return self.deleteRule(index_ orelse 0, frame);
}

pub fn replace(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!js.Promise {
    try self.replaceSync(text, frame);
    return frame.js.local.?.resolvePromise(self);
}

pub fn replaceSync(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!void {
    const rules = try self.getCssRules(frame);
    rules.clear();

    var it = Parser.parseStylesheet(text);
    var index: u32 = 0;
    // Measured on Chrome 150: an `@import` only survives while nothing but
    // `@charset`, `@layer` *statements* and other `@import`s has been seen.
    // A `@namespace`, a style rule or a `@layer` block all close the window
    // and every later `@import` is dropped without a trace.
    var imports_allowed = true;
    while (it.next()) |parsed_rule| {
        const kind = importWindowKind(parsed_rule);
        if (kind == .import and !imports_allowed) continue;
        if (kind == .closes_window) imports_allowed = false;

        // Chrome drops @charset entirely: buildRule answers null for it.
        const inserted = (try rules_mod.buildRule(parsed_rule, frame)) orelse continue;
        inserted._parent_style_sheet = self;

        try rules.insert(index, inserted, frame);
        index += 1;
    }

    // Notify StyleManager that rules have changed
    frame._style_manager.sheetModified();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleSheet);

    pub const Meta = struct {
        pub const name = "CSSStyleSheet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // ownerNode / href / title / disabled now live on StyleSheet, which is
    // where Chrome keeps them. Order below is Chrome's own.
    pub const constructor = bridge.constructor(CSSStyleSheet.init, .{});
    pub const ownerRule = bridge.accessor(CSSStyleSheet.getOwnerRule, null, .{});
    pub const cssRules = bridge.accessor(CSSStyleSheet.getCssRules, null, .{});
    pub const rules = bridge.accessor(CSSStyleSheet.getCssRules, null, .{});
    pub const addRule = bridge.function(CSSStyleSheet.addRule, .{});
    pub const deleteRule = bridge.function(CSSStyleSheet.deleteRule, .{});
    pub const insertRule = bridge.function(CSSStyleSheet.insertRule, .{});
    pub const removeRule = bridge.function(CSSStyleSheet.removeRule, .{});
    pub const replace = bridge.function(CSSStyleSheet.replace, .{});
    pub const replaceSync = bridge.function(CSSStyleSheet.replaceSync, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CSSStyleSheet" {
    testing.silenceLog(&.{.js});
    try testing.htmlRunner("css/stylesheet.html", .{});
}

test "WebApi: layer @-rule cascade" {
    try testing.htmlRunner("css/layer_at_rule_cascade.html", .{});
}

test "WebApi: layer order cascade" {
    try testing.htmlRunner("css/layer_order_cascade.html", .{});
}
