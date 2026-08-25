const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const CSSStyleRule = @import("CSSStyleRule.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");
const rules = @import("rules.zig");

const CSSRule = @This();

/// Which subclass this rule actually is. Every variant but `.unknown` carries
/// the leaf pointer, which is what `getType` and `getCssText` dispatch on: the
/// bridge only ever installs one `cssText` accessor (Chrome has it on
/// CSSRule.prototype and nowhere else), so the serialisation has to be routed
/// from here rather than overridden per subclass.
pub const Type = union(enum) {
    style: *CSSStyleRule,
    import: *rules.CSSImportRule,
    media: *rules.CSSMediaRule,
    font_face: *rules.CSSFontFaceRule,
    page: *rules.CSSPageRule,
    keyframes: *rules.CSSKeyframesRule,
    keyframe: *rules.CSSKeyframeRule,
    namespace: *rules.CSSNamespaceRule,
    counter_style: *rules.CSSCounterStyleRule,
    supports: *rules.CSSSupportsRule,
    container: *rules.CSSContainerRule,
    layer_block: *rules.CSSLayerBlockRule,
    layer_statement: *rules.CSSLayerStatementRule,
    property: *rules.CSSPropertyRule,
    font_palette_values: *rules.CSSFontPaletteValuesRule,
    view_transition: *rules.CSSViewTransitionRule,
    unknown: void,
};

_type: Type,
/// Original source text, only used by the `.unknown` placeholder: every
/// modelled rule re-serialises itself instead. See lightpanda-io/browser#2459
/// for why unmodelled at-rules still have to round-trip through `cssRules`.
_text: []const u8 = "",
_parent_rule: ?*CSSRule = null,
_parent_style_sheet: ?*CSSStyleSheet = null,

pub fn as(self: *CSSRule, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *CSSRule, comptime T: type) ?*T {
    switch (self._type) {
        .style => |r| return if (T == CSSStyleRule) r else null,
        else => return null,
    }
}

pub fn init(rule_type: Type, frame: *Frame) !*CSSRule {
    return frame._factory.create(CSSRule{
        ._type = rule_type,
    });
}

/// Construct an at-rule placeholder with stored source text, for at-rules we
/// do not model. Everything Chrome gives a brand to goes through `rules.zig`
/// instead.
pub fn initAtRule(rule_type: Type, text: []const u8, frame: *Frame) !*CSSRule {
    return frame._factory.create(CSSRule{
        ._type = rule_type,
        ._text = try frame.dupeString(text),
    });
}

/// The legacy numeric type constants. Rules that postdate them (`@layer`,
/// `@container`, `@property`, `@font-palette-values`, `@view-transition`)
/// answer 0, and so does an at-rule we do not model.
pub fn getType(self: *const CSSRule) u16 {
    return switch (self._type) {
        .style => 1,
        .import => 3,
        .media => 4,
        .font_face => 5,
        .page => 6,
        .keyframes => 7,
        .keyframe => 8,
        .namespace => 10,
        .counter_style => 11,
        .supports => 12,
        .container,
        .layer_block,
        .layer_statement,
        .property,
        .font_palette_values,
        .view_transition,
        .unknown,
        => 0,
    };
}

/// Explicit rather than inferred: the serialisers recurse back into this
/// function for their children, and an inferred error set would be a
/// dependency loop.
pub const SerializeError = error{ OutOfMemory, WriteFailed, StringTooLarge };

pub fn getCssText(self: *CSSRule, frame: *Frame) SerializeError![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    const writer = &buf.writer;
    switch (self._type) {
        .style => |r| try r.writeCssText(writer, frame),
        .import => |r| try r.writeCssText(writer, frame),
        .media => |r| try r.writeCssText(writer, frame),
        .font_face => |r| try r.writeCssText(writer),
        .page => |r| try r.writeCssText(writer),
        .keyframes => |r| try r.writeCssText(writer, frame),
        .keyframe => |r| try r.writeCssText(writer),
        .namespace => |r| try r.writeCssText(writer),
        .counter_style => |r| try r.writeCssText(writer),
        .supports => |r| try r.writeCssText(writer, frame),
        .container => |r| try r.writeCssText(writer, frame),
        .layer_block => |r| try r.writeCssText(writer, frame),
        .layer_statement => |r| try r.writeCssText(writer),
        .property => |r| try r.writeCssText(writer),
        .font_palette_values => |r| try r.writeCssText(writer),
        .view_transition => |r| try r.writeCssText(writer),
        .unknown => return self._text,
    }
    return buf.written();
}

/// Measured: the setter exists but is a silent no-op — assigning to
/// `rule.cssText` leaves the rule untouched and does not throw.
pub fn setCssText(_: *CSSRule, _: []const u8) void {}

pub fn getParentRule(self: *const CSSRule) ?*CSSRule {
    return self._parent_rule;
}

pub fn getParentStyleSheet(self: *const CSSRule) ?*CSSStyleSheet {
    // A nested rule reports the sheet its outermost ancestor belongs to.
    var node: *const CSSRule = self;
    while (node._parent_style_sheet == null) {
        node = node._parent_rule orelse return null;
    }
    return node._parent_style_sheet;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSRule);

    pub const Meta = struct {
        pub const name = "CSSRule";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(CSSRule.getType, null, .{});
    pub const cssText = bridge.accessor(CSSRule.getCssText, CSSRule.setCssText, .{});
    pub const parentRule = bridge.accessor(CSSRule.getParentRule, null, .{});
    pub const parentStyleSheet = bridge.accessor(CSSRule.getParentStyleSheet, null, .{});

    // Spec rule-type constants, in Chrome's own declaration order (which is
    // not numeric order) and limited to the thirteen Chrome still ships:
    // DOCUMENT_RULE, VIEWPORT_RULE and REGION_STYLE_RULE are gone. Wrapped
    // with `bridge.property(.template)` so they also land on the JS-side
    // constructor, e.g. `CSSRule.KEYFRAMES_RULE === 7`.
    pub const STYLE_RULE = bridge.property(1, .{ .template = true });
    pub const CHARSET_RULE = bridge.property(2, .{ .template = true });
    pub const IMPORT_RULE = bridge.property(3, .{ .template = true });
    pub const MEDIA_RULE = bridge.property(4, .{ .template = true });
    pub const FONT_FACE_RULE = bridge.property(5, .{ .template = true });
    pub const PAGE_RULE = bridge.property(6, .{ .template = true });
    pub const MARGIN_RULE = bridge.property(9, .{ .template = true });
    pub const NAMESPACE_RULE = bridge.property(10, .{ .template = true });
    pub const KEYFRAMES_RULE = bridge.property(7, .{ .template = true });
    pub const KEYFRAME_RULE = bridge.property(8, .{ .template = true });
    pub const COUNTER_STYLE_RULE = bridge.property(11, .{ .template = true });
    pub const FONT_FEATURE_VALUES_RULE = bridge.property(14, .{ .template = true });
    pub const SUPPORTS_RULE = bridge.property(12, .{ .template = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: CSSRule hierarchy" {
    try testing.htmlRunner("css/rule_hierarchy.html", .{});
}
