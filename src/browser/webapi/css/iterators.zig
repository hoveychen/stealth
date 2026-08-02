// The iterator objects behind `Symbol.iterator` on the CSSOM collections.
// Chrome gives CSSRuleList, StyleSheetList, MediaList and CSSKeyframesRule an
// iterator, and each one needs its generated iterator type registered with the
// bridge. Their owning modules export a single JsApi apiece, so the
// registrations are collected here rather than scattered.

const CSSRuleList = @import("CSSRuleList.zig");
const StyleSheetList = @import("StyleSheetList.zig");
const MediaList = @import("MediaList.zig");
const rules = @import("rules.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");

pub fn registerTypes() []const type {
    return &.{
        CSSRuleList.ValueIterator,
        StyleSheetList.ValueIterator,
        MediaList.ValueIterator,
        rules.CSSKeyframesRule.ValueIterator,
        CSSStyleDeclaration.ValueIterator,
    };
}
