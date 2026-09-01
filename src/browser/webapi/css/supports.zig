//! `<supports-condition>` evaluation (css-conditional-3 §2).
//!
//! One evaluator behind two doors: the `@supports` at-rule, which asks whether
//! to apply a block, and `CSS.supports()`, which asks the same question from
//! script. Before this existed the engine answered neither -- StyleManager had
//! no `supports` branch, so every `@supports` block was dropped whole, and
//! `CSS.supports()` returned `true` for every input including `(nonsense-prop:
//! 1)`. Those are opposite errors and both are visible from one expression.
//!
//! Everything asserted here was measured on Chrome 151 through
//! tools/fingerprint/run-expr.mjs; the probes are
//! scratch/b97/expr-b97-supports-boundary.js and
//! scratch/b97/expr-b97-general-enclosed.js, and the rows they produced are the
//! table in src/browser/tests/css/supports_condition.html. Three findings shape
//! the design:
//!
//!   1. The two doors agree on every input but one. `display: grid` -- a bare
//!      declaration with no parentheses -- is not a `<supports-condition>`, so
//!      the at-rule drops it, while the one-argument `CSS.supports()` falls back
//!      to parsing its argument as a declaration (CSSOM §CSS.supports) and says
//!      true. That is the only reason `conditionOrDeclaration` exists.
//!   2. `<general-enclosed>` evaluates to plain **false**, not to a propagating
//!      "unknown". The spec's three-valued logic and a two-valued one agree on
//!      `and` and `or`, and differ only under negation, so this was decided by
//!      measurement: `not nonsense-fn(x)` is **true** in Chrome. No tri-state.
//!   3. Vendor prefixes are not a wildcard. `-webkit-transform` and
//!      `-webkit-line-clamp` are supported while `-webkit-nonsense`,
//!      `-ms-appearance`, `-o-transform` and `-moz-user-select` are not, which
//!      is one lookup in the property table rather than a rule about prefixes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Tokenizer = @import("../../css/Tokenizer.zig");
const Selector = @import("../selector/Selector.zig");
const calc = @import("calc.zig");
const chrome_keywords = @import("chrome_keywords.zig");
const chrome_properties = @import("chrome_properties.zig");
const shorthand = @import("shorthand.zig");

/// Hard cap on `( ( ( … ) ) )` nesting, for the same reason StyleManager caps
/// at-rule nesting: the grammar allows arbitrary depth and a hostile stylesheet
/// should not be able to reach the Zig stack through it.
const max_depth: u8 = 32;

/// Whether `@supports <condition>` should apply its block.
pub fn matches(arena: Allocator, condition: []const u8) bool {
    return evalCondition(arena, condition, 0);
}

/// The one-argument `CSS.supports(conditionText)`. A `<supports-condition>`
/// first; failing that, a bare `<declaration>`, which is the branch that makes
/// `CSS.supports('display: grid')` true where `@supports display: grid` drops
/// its block.
pub fn conditionOrDeclaration(arena: Allocator, text: []const u8) bool {
    if (evalCondition(arena, text, 0)) {
        return true;
    }
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    return declarationSupported(text[0..colon], text[colon + 1 ..]);
}

/// The two-argument `CSS.supports(property, value)`. No condition grammar: the
/// arguments are one declaration, so `CSS.supports('(display', 'grid)')` is a
/// question about a property named `(display` and the answer is false.
pub fn declaration(property: []const u8, value: []const u8) bool {
    return declarationSupported(property, value);
}

// -- condition grammar ------------------------------------------------------

/// `<supports-condition> = not <supports-in-parens>
///                       | <supports-in-parens> [ and <supports-in-parens> ]*
///                       | <supports-in-parens> [ or <supports-in-parens> ]*`
///
/// The two lists do not mix and `not` does not chain, both measured: `(a) and
/// (b) or (c)`, `not not (a)` and `not (a) and (b)` are all false in Chrome
/// even when every operand is supported.
fn evalCondition(arena: Allocator, input: []const u8, depth: u8) bool {
    if (depth >= max_depth) {
        return false;
    }

    var scan: Scanner = .{ .stream = .init(input) };

    const first = scan.next() orelse return false;
    if (first == .kw_not) {
        const operand = scan.next() orelse return false;
        if (operand != .in_parens) return false;
        if (scan.next() != null) return false;
        return !evalInParens(arena, operand.in_parens, depth);
    }
    if (first != .in_parens) {
        return false;
    }

    // Every operand is parsed before any answer is given: a malformed operand
    // invalidates the whole condition, so `(display: grid) or <garbage>` cannot
    // be short-circuited to true on the strength of its first half.
    var all_true = evalInParens(arena, first.in_parens, depth);
    var any_true = all_true;
    var combinator: ?Item = null;

    while (scan.next()) |item| {
        switch (item) {
            .kw_and, .kw_or => {
                if (combinator) |seen| {
                    if (std.meta.activeTag(seen) != std.meta.activeTag(item)) return false;
                } else {
                    combinator = item;
                }
            },
            // Two operands with no combinator between them, or a leading `not`
            // in operand position.
            else => return false,
        }
        const operand = scan.next() orelse return false;
        if (operand != .in_parens) return false;
        const value = evalInParens(arena, operand.in_parens, depth);
        all_true = all_true and value;
        any_true = any_true or value;
    }
    if (scan.failed) {
        return false;
    }

    const op = combinator orelse return all_true;
    return switch (op) {
        .kw_and => all_true,
        .kw_or => any_true,
        else => unreachable,
    };
}

/// `<supports-in-parens> = ( <supports-condition> ) | <supports-feature> |
///                        <general-enclosed>`
fn evalInParens(arena: Allocator, parens: InParens, depth: u8) bool {
    if (parens.name.len != 0) {
        if (eqlIgnoreCase(parens.name, "selector")) {
            return selectorSupported(arena, parens.inner);
        }
        if (eqlIgnoreCase(parens.name, "font-format")) {
            return fontFormatSupported(parens.inner);
        }
        if (eqlIgnoreCase(parens.name, "font-tech")) {
            return fontTechSupported(parens.inner);
        }
        // `<general-enclosed>`: a function whose name means nothing here.
        return false;
    }

    // `( <declaration> )` and `( <supports-condition> )` are told apart by the
    // first two significant tokens: only a declaration starts `<ident> :`. That
    // also disposes of `<general-enclosed>` -- `(display)` and `(nonsense stuff
    // here)` reach the condition branch, fail to parse there and come out
    // false, which is what Chrome answers for both.
    if (declarationSplit(parens.inner)) |split| {
        return declarationSupported(split.name, split.value);
    }
    return evalCondition(arena, parens.inner, depth + 1);
}

const Item = union(enum) {
    kw_not,
    kw_and,
    kw_or,
    in_parens: InParens,
};

const InParens = struct {
    /// The function name for `selector(…)` / `font-format(…)`, empty for a
    /// plain `( … )`.
    name: []const u8,
    /// The text between the outermost parentheses.
    inner: []const u8,
};

/// Splits a condition into its top-level items. Driven by the CSS tokenizer
/// rather than a brace counter over the raw text, so a comment or a quoted
/// string holding a parenthesis cannot move the boundaries -- the `@media`
/// cascade test already covers that case for its own prelude.
const Scanner = struct {
    stream: Stream,
    /// Set when a token appears that no item can start with. The caller cannot
    /// tell that apart from "input exhausted" through `next()` alone, and the
    /// two mean opposite things.
    failed: bool = false,

    fn next(self: *Scanner) ?Item {
        while (true) {
            const span = self.stream.next() orelse return null;
            switch (span.token) {
                .white_space, .comment => continue,
                .ident => |name| {
                    if (eqlIgnoreCase(name, "not")) return .kw_not;
                    if (eqlIgnoreCase(name, "and")) return .kw_and;
                    if (eqlIgnoreCase(name, "or")) return .kw_or;
                    self.failed = true;
                    return null;
                },
                .parenthesis_block => {
                    const inner = self.closeParens(span.end) orelse return null;
                    return .{ .in_parens = .{ .name = "", .inner = inner } };
                },
                .function => |name| {
                    const inner = self.closeParens(span.end) orelse return null;
                    return .{ .in_parens = .{ .name = name, .inner = inner } };
                },
                else => {
                    self.failed = true;
                    return null;
                },
            }
        }
    }

    /// The text from `start` up to the parenthesis that closes the one just
    /// consumed. An unclosed group is a parse error rather than an implicit
    /// close at end of input: `@supports (display: grid` applies nothing.
    fn closeParens(self: *Scanner, start: usize) ?[]const u8 {
        var depth: usize = 1;
        while (self.stream.next()) |span| {
            switch (span.token) {
                .parenthesis_block, .function => depth += 1,
                .close_parenthesis => {
                    depth -= 1;
                    if (depth == 0) return self.stream.input[start..span.start];
                },
                else => {},
            }
        }
        self.failed = true;
        return null;
    }
};

const Span = struct {
    token: Tokenizer.Token,
    start: usize,
    end: usize,
};

const Stream = struct {
    input: []const u8,
    tokenizer: Tokenizer,

    fn init(input: []const u8) Stream {
        return .{ .input = input, .tokenizer = .{ .input = input } };
    }

    fn next(self: *Stream) ?Span {
        const start = self.tokenizer.position;
        const token = self.tokenizer.next() orelse return null;
        return .{ .token = token, .start = start, .end = self.tokenizer.position };
    }
};

// -- declarations -----------------------------------------------------------

const Split = struct {
    name: []const u8,
    value: []const u8,
};

/// The `<ident> :` prefix that marks a declaration, or null for anything else.
/// The colon is found through the tokenizer so that `(a:b)` inside a string or
/// a comment cannot be mistaken for one.
fn declarationSplit(input: []const u8) ?Split {
    var stream: Stream = .init(input);
    var name: ?[]const u8 = null;
    var name_end: usize = 0;
    while (stream.next()) |span| {
        switch (span.token) {
            .white_space, .comment => continue,
            .ident => |ident| {
                if (name != null) return null;
                name = ident;
                name_end = span.end;
            },
            .colon => {
                if (name == null) return null;
                return .{ .name = input[0..name_end], .value = input[span.end..] };
            },
            else => return null,
        }
    }
    return null;
}

fn declarationSupported(name_raw: []const u8, value_raw: []const u8) bool {
    const name = trim(name_raw);
    if (name.len == 0) {
        return false;
    }

    // A custom property takes any value at all, including none: `(--x:)` is
    // true in Chrome where `(display:)` is false. What it does need is a name --
    // `(--: 1)` is false.
    if (std.mem.startsWith(u8, name, "--")) {
        return name.len > 2;
    }

    const value = trim(value_raw);
    if (value.len == 0) {
        return false;
    }
    if (!propertyExists(name)) {
        return false;
    }
    return valueSupported(name, value);
}

/// Every CSS name a declaration answers to. Two maps rather than one because
/// the generated lists are in two different vocabularies: `computed` holds the
/// 475 longhands already spelled the CSS way, while `aliases` holds the 745 IDL
/// attribute names -- lowerCamelCase, `textWrap` and `webkitAppearance` -- so
/// they have to be turned back into property names before they can answer a
/// question about `(text-wrap: balance)`.
///
/// That vocabulary mismatch is why the first version of this said false for
/// `(-webkit-appearance: none)` and `(text-wrap: balance)`: `text-wrap` is a
/// shorthand, so it is not in `computed` at all, and `-webkit-appearance` is
/// only there as `webkitAppearance`.
///
/// Built at comptime so a lookup is a hash rather than a walk of 1211 strings:
/// `CSS.supports()` is a call a fingerprinting script can make in a loop.
const computed_set = blk: {
    @setEvalBranchQuota(16 * chrome_properties.computed.len);
    var kvs: [chrome_properties.computed.len]struct { []const u8, void } = undefined;
    for (chrome_properties.computed, 0..) |name, i| kvs[i] = .{ name, {} };
    break :blk std.StaticStringMap(void).initComptime(kvs);
};

const alias_set = blk: {
    // 512 rather than 64 per name: the `alias_set.has` below is a hash lookup
    // over 736 entries and it runs once per candidate.
    @setEvalBranchQuota(512 * chrome_properties.aliases.len);
    var kvs: [chrome_properties.aliases.len]struct { []const u8, void } = undefined;
    var i: usize = 0;
    for (chrome_properties.aliases) |name| {
        // `cssFloat` is the one IDL attribute whose name is not derived from
        // its property's (CSSOM §CSSStyleDeclaration): the property is `float`,
        // which `computed` already carries, and deriving `css-float` from it
        // would invent a name Chrome does not have.
        if (std.mem.eql(u8, name, "cssFloat")) continue;
        // Nine names in that list are ones Chrome only ever *lists* -- the
        // `epub*` block, which getOwnPropertyNames reports and nothing else
        // answers. Their dashed spellings (`-epub-word-break`) are real
        // property aliases in Chrome and no part of this engine parses one, so
        // claiming support here would put @supports out of step with what a
        // declaration retains, which is the one invariant this file has.
        if (!chrome_properties.alias_set.has(name)) continue;
        kvs[i] = .{ propertyNameOf(name), {} };
        i += 1;
    }
    break :blk std.StaticStringMap(void).initComptime(kvs[0..i].*);
};

/// The CSS property name an IDL attribute name stands for: each capital becomes
/// `-` plus its lower case, and a `webkit`-prefixed attribute regains the
/// leading dash the IDL spelling drops.
fn propertyNameOf(comptime camel: []const u8) []const u8 {
    comptime {
        var kebab: []const u8 = "";
        for (camel) |c| {
            if (std.ascii.isUpper(c)) {
                kebab = kebab ++ [2]u8{ '-', std.ascii.toLower(c) };
            } else {
                kebab = kebab ++ [1]u8{c};
            }
        }
        if (std.mem.startsWith(u8, kebab, "webkit-")) {
            return "-" ++ kebab;
        }
        return kebab;
    }
}

fn propertyExists(name: []const u8) bool {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) {
        return false;
    }
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    return computed_set.has(lower) or alias_set.has(lower);
}

fn valueSupported(property: []const u8, value: []const u8) bool {
    // Measured: `!important` inside a supports declaration is allowed --
    // `(display: grid !important)` is true -- so it is stripped rather than
    // being a reason to refuse.
    const bare = trim(stripImportant(value));
    if (bare.len == 0) {
        return false;
    }

    // Measured: a value carrying `var()` is supported for every property,
    // because substitution has not happened yet and nothing about it can be
    // wrong. `(color: var(--x))` is true even though `--x` is not registered.
    if (hasVarFunction(bare)) {
        return true;
    }
    for (chrome_keywords.css_wide) |keyword| {
        if (eqlIgnoreCase(bare, keyword)) return true;
    }

    // A `calc()` whose types do not work out is dropped whatever property it is
    // on: `width: calc(1px + 1)`, `calc(1px * 1px)`, `calc(1px + 1deg)` and
    // `calc(10px + 2foo)` are all refused by Chrome, and so are the two
    // whitespace shapes -- `calc(1px +1px)` and `calc(1px+1px)` -- where the
    // sign belongs to the next token rather than to an operator. Measured.
    //
    // Ahead of the value-class check because that one declines any value with a
    // function in it: `judgeable` cannot grade what it cannot classify, which
    // is why every one of these was stored here before.
    if (calc.valueIsInvalid(bare)) {
        return false;
    }

    if (identifierOutsideKeywordList(property, bare)) {
        return false;
    }
    return !shorthand.refusesLonghand(property, bare);
}

/// Whether the value is one bare identifier that the property's measured
/// keyword list does not contain.
///
/// This is the half `shorthand.refusesLonghand` cannot answer. That predicate
/// only grades a property the generator measured value classes for, which are
/// the longhands some shorthand expands to; `display` is not one of them, so
/// `display: nonsense-xyz` passed every check the engine had. Restricting the
/// extra check to a *single* identifier is what keeps it safe in the other
/// direction: an identifier is not a length or a function, so a property whose
/// keyword list is complete cannot be talked into refusing a real value, and
/// the multi-component grammars nobody has modelled are never asked.
///
/// A keyword list cannot be reused for one component of a *pair*, and it was
/// tried: the list is measured by offering each identifier alone, and half of
/// a two-component grammar routinely does not parse alone. `align-items: first
/// baseline` hangs off a leading modifier, and `scroll-marker-group: after
/// links` hangs off a trailing one, so neither end of a pair is safe to grade
/// this way. That is why `clip-path: circle() nonsense` is kept -- see the
/// value-class ceiling note in `shorthand.refusesLonghand`.
///
/// Two exemptions, both measured:
///   - `any_identifier` properties take an author's own name, so no list can
///     say no: `(font-family: nonsense-family)` and `(will-change:
///     nonsense-thing)` are both true.
///   - A `<dashed-ident>` is never a keyword. `(anchor-name: --a)` is true
///     while `(anchor-name: nonsense-name)` is false, and `anchor-name` is not
///     in `any_identifier`, so the two are told apart by the leading `--`.
fn identifierOutsideKeywordList(property: []const u8, value: []const u8) bool {
    if (chrome_keywords.any_identifier.has(property)) {
        return false;
    }
    if (std.mem.startsWith(u8, value, "--")) {
        return false;
    }

    const ident = soleIdentifier(value) orelse return false;

    var name_buf: [128]u8 = undefined;
    if (property.len > name_buf.len) {
        return false;
    }
    const lower_name = std.ascii.lowerString(name_buf[0..property.len], property);
    // Absence from the table is not a refusal: it means the generator never
    // offered this property an identifier, so there is nothing to compare to.
    const known = chrome_keywords.keywords.get(lower_name) orelse return false;
    // An empty list *is* a refusal -- the generated header records 114
    // properties that take no bare identifier beyond the CSS-wide ones.
    for (known) |keyword| {
        if (eqlIgnoreCase(ident, keyword)) return false;
    }
    return true;
}

/// The value's one identifier, or null when it is anything else: several
/// components, a dimension, a function, a hash.
fn soleIdentifier(value: []const u8) ?[]const u8 {
    var stream: Stream = .init(value);
    var found: ?[]const u8 = null;
    while (stream.next()) |span| {
        switch (span.token) {
            .white_space, .comment => continue,
            .ident => |ident| {
                if (found != null) return null;
                found = ident;
            },
            else => return null,
        }
    }
    return found;
}

fn stripImportant(value: []const u8) []const u8 {
    const bang = std.mem.lastIndexOfScalar(u8, value, '!') orelse return value;
    if (!eqlIgnoreCase(trim(value[bang + 1 ..]), "important")) {
        return value;
    }
    return value[0..bang];
}

fn hasVarFunction(value: []const u8) bool {
    var stream: Stream = .init(value);
    while (stream.next()) |span| {
        switch (span.token) {
            .function => |name| if (eqlIgnoreCase(name, "var")) return true,
            else => {},
        }
    }
    return false;
}

// -- selector() and the font functions --------------------------------------

/// `selector(<complex-selector>)` is true when the selector parses.
///
/// Not identical to what a stylesheet does with the same text: the b96 selector
/// sweep measured that an unknown `::-webkit-…` pseudo-element keeps its rule
/// in a stylesheet, while `selector(::-webkit-anything)` is false here. That
/// makes `selector()` stricter than the selector list it shares a grammar with,
/// and this engine answers the looser question for both -- recorded as a
/// residual in the test rather than papered over, because the strictness lives
/// in the selector parser and belongs to whoever changes it next.
fn selectorSupported(arena: Allocator, inner: []const u8) bool {
    const text = trim(inner);
    if (text.len == 0) {
        return false;
    }
    _ = Selector.parseLeaky(arena, text) catch return false;
    return true;
}

/// The `<font-format>` keywords, css-fonts-4 §11.1. Four were measured
/// (`woff2`, `woff`, `collection` true, `nonsense` false); the rest are from
/// the spec's production, so a wrong name here would be a false positive on an
/// input no page writes rather than a wrong answer for a real format.
const font_formats = [_][]const u8{
    "collection",
    "embedded-opentype",
    "opentype",
    "svg",
    "truetype",
    "woff",
    "woff2",
};

/// The `<font-tech>` keywords, css-fonts-4 §11.2. Measured: `variations`,
/// `palettes` and `color-COLRv1` true, `nonsense` false.
const font_techs = [_][]const u8{
    "color-CBDT",
    "color-COLRv0",
    "color-COLRv1",
    "color-SVG",
    "color-sbix",
    "features-aat",
    "features-graphite",
    "features-opentype",
    "incremental",
    "palettes",
    "variations",
};

fn fontFormatSupported(inner: []const u8) bool {
    return oneOf(trim(inner), &font_formats);
}

fn fontTechSupported(inner: []const u8) bool {
    return oneOf(trim(inner), &font_techs);
}

fn oneOf(value: []const u8, set: []const []const u8) bool {
    for (set) |entry| {
        if (eqlIgnoreCase(value, entry)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, &std.ascii.whitespace);
}
