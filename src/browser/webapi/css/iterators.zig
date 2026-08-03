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
const typed_om = @import("typed_om.zig");

pub fn registerTypes() []const type {
    return &.{
        CSSRuleList.ValueIterator,
        StyleSheetList.ValueIterator,
        MediaList.ValueIterator,
        rules.CSSKeyframesRule.ValueIterator,
        CSSStyleDeclaration.ValueIterator,
        typed_om.CSSNumericArray.KeyIterator,
        typed_om.CSSNumericArray.ValueIterator,
        typed_om.CSSNumericArray.EntryIterator,
        typed_om.CSSUnparsedValue.KeyIterator,
        typed_om.CSSUnparsedValue.ValueIterator,
        typed_om.CSSUnparsedValue.EntryIterator,
        typed_om.CSSTransformValue.KeyIterator,
        typed_om.CSSTransformValue.ValueIterator,
        typed_om.CSSTransformValue.EntryIterator,
        typed_om.StylePropertyMapReadOnly.KeyIterator,
        typed_om.StylePropertyMapReadOnly.ValueIterator,
        typed_om.StylePropertyMapReadOnly.EntryIterator,
    };
}
