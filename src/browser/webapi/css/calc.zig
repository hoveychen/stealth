//! Folding and printing a CSS `calc()`.
//!
//! A browser does not keep the expression the author wrote. It reduces the sum
//! to one term per unit, converts every absolute length to px, sorts the terms
//! and prints that -- so `calc(1px + 1em)` reads back as `calc(1em + 1px)` and
//! `calc(1px + 2px)` as `calc(3px)`. Measured over sixty-nine rows on Chrome
//! 151 (scratch/b98/expr-b98-calc.js, scratch/b98/expr-b98-calc-existing.js);
//! the rules that run came out of that and are cited at the code that applies
//! them.
//!
//! Why this is its own file rather than a branch in typed_om.zig, which already
//! has a folder: that one exists to build a `CSSMathSum` for the Typed OM, so
//! it needs a `Frame`, allocates JS objects, and only models a flat sum with
//! `*`/`/` by a bare number -- no parentheses, no nested `calc()`. What the
//! declaration path needs is text in and text out. The intent is for typed_om
//! to come here later, not for this to grow a second vocabulary.
//!
//! Three outcomes, and the difference between the last two is the whole reason
//! the error set is not a bool:
//!
//!   a folded value   the caller prints it
//!   error.Invalid    a `calc()` whose types do not work out. Chrome drops the
//!                    declaration, so the caller must too.
//!   error.Unmodelled a math function this file does not do -- `min()`,
//!                    `clamp()`, `round()`, a division that goes infinite. The
//!                    caller leaves the author's text exactly as it found it,
//!                    because refusing here would throw away a declaration
//!                    every browser keeps.

const std = @import("std");
const units = @import("../../css/units.zig");
const chrome_value_case = @import("chrome_value_case.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ Invalid, Unmodelled };

/// One unit's total. Absolute lengths never appear: they are converted to px
/// as they are parsed, which is why `calc(1q + 1cm)` prints as one term.
pub const Term = struct {
    unit: units.Unit,
    value: f64,
};

/// At most one term per unit, and there are twenty-two units.
const max_terms = 24;

pub const Folded = struct {
    terms: [max_terms]Term = undefined,
    len: usize = 0,

    fn add(self: *Folded, unit: units.Unit, value: f64) Error!void {
        // An absolute length is not a unit of its own once it is folded: px,
        // cm, mm, in, pt, pc and Q all share one bucket, which is what makes
        // `calc(1in + 1pt + 1pc)` come out as `calc(113.333px)`.
        var key = unit;
        var scaled = value;
        if (unit != .none) {
            if (units.absoluteLengthFactor(unit)) |factor| {
                key = .px;
                scaled = value * factor;
            }
        }
        for (self.terms[0..self.len]) |*term| {
            if (term.unit == key) {
                term.value += scaled;
                return;
            }
        }
        if (self.len == max_terms) return error.Invalid;
        self.terms[self.len] = .{ .unit = key, .value = scaled };
        self.len += 1;
    }

    fn scale(self: *Folded, factor: f64) void {
        for (self.terms[0..self.len]) |*term| term.value *= factor;
    }

    /// The value as a plain number, or null when it carries a unit. A `*` needs
    /// one side to be this and a `/` needs its right side to be.
    fn asNumber(self: *const Folded) ?f64 {
        if (self.len == 0) return 0;
        if (self.len != 1 or self.terms[0].unit != .none) return null;
        return self.terms[0].value;
    }
};

/// What a unit is, for the one rule that decides whether a sum makes sense.
/// `calc(1px + 1)` and `calc(1px + 1deg)` are both dropped by Chrome; `calc(1%
/// + 1px)` is kept, because a percentage takes the type of whatever it is
/// added to.
const Category = enum { number, percentage, length, angle };

fn categoryOf(unit: units.Unit) Category {
    return switch (unit) {
        .none => .number,
        .percentage => .percentage,
        .deg, .rad, .grad, .turn => .angle,
        else => .length,
    };
}

fn checkCategories(value: *const Folded) Error!void {
    var found: ?Category = null;
    var has_percentage = false;
    for (value.terms[0..value.len]) |term| {
        const category = categoryOf(term.unit);
        if (category == .percentage) {
            has_percentage = true;
            continue;
        }
        if (found) |seen| {
            if (seen != category) return error.Invalid;
        } else {
            found = category;
        }
    }
    // A bare number is not a length and a percentage of one means nothing.
    if (has_percentage and found == .number) return error.Invalid;
}

/// Folds one `calc()` body. `body` is what is between the parentheses.
pub fn foldBody(body: []const u8) Error!Folded {
    var parser: Parser = .{ .text = body };
    const value = try parser.sum();
    parser.skipSpace();
    if (parser.index != parser.text.len) return error.Invalid;
    try checkCategories(&value);
    for (value.terms[0..value.len]) |term| {
        // An infinity or a NaN has a spelling of its own in Chrome
        // (`calc(1px / 0)` prints `calc(infinity * 1px)`), which nothing here
        // models -- so the author's text is left alone rather than mangled.
        if (!std.math.isFinite(term.value)) return error.Unmodelled;
    }
    return value;
}

const Parser = struct {
    text: []const u8,
    index: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.index < self.text.len and
            std.ascii.isWhitespace(self.text[self.index])) : (self.index += 1)
        {}
    }

    /// `sum := product (<ws> ('+' | '-') <ws> product)*`
    ///
    /// The whitespace is part of the grammar and not decoration: `calc(1px +
    /// 1px)` is valid while `calc(1px +1px)` and `calc(1px+1px)` are both
    /// dropped by Chrome, because without a space on each side the `+` is part
    /// of the next number's token rather than an operator. Measured.
    fn sum(self: *Parser) Error!Folded {
        var total = try self.product();
        while (true) {
            const mark = self.index;
            self.skipSpace();
            const spaced_before = self.index != mark;
            if (self.index >= self.text.len) return total;
            const op = self.text[self.index];
            if (op != '+' and op != '-') {
                self.index = mark;
                return total;
            }
            const after = self.index + 1;
            const spaced_after = after < self.text.len and
                std.ascii.isWhitespace(self.text[after]);
            if (!spaced_before or !spaced_after) return error.Invalid;
            self.index = after;
            const operand = try self.product();
            const sign: f64 = if (op == '+') 1 else -1;
            for (operand.terms[0..operand.len]) |term| {
                try total.add(term.unit, sign * term.value);
            }
        }
    }

    /// `product := primary (('*' | '/') primary)*`, where one side of a `*` and
    /// the right side of a `/` has to be a plain number -- `calc(1px * 1px)` is
    /// a Chrome refusal, not an area.
    fn product(self: *Parser) Error!Folded {
        var total = try self.primary();
        while (true) {
            // The index is put back when this is not our operator: `sum` reads
            // the whitespace around a `+` as part of the grammar, so leaving it
            // consumed here would turn a valid `calc(1px + 1px)` into a refusal.
            const mark = self.index;
            self.skipSpace();
            if (self.index >= self.text.len) {
                self.index = mark;
                return total;
            }
            const op = self.text[self.index];
            if (op != '*' and op != '/') {
                self.index = mark;
                return total;
            }
            self.index += 1;
            self.skipSpace();
            const operand = try self.primary();
            if (op == '/') {
                const divisor = operand.asNumber() orelse return error.Invalid;
                total.scale(1 / divisor);
                continue;
            }
            if (operand.asNumber()) |factor| {
                total.scale(factor);
                continue;
            }
            const factor = total.asNumber() orelse return error.Invalid;
            total = operand;
            total.scale(factor);
        }
    }

    /// `primary := '(' sum ')' | 'calc(' sum ')' | <number> | <dimension>`
    fn primary(self: *Parser) Error!Folded {
        self.skipSpace();
        if (self.index >= self.text.len) return error.Invalid;

        if (self.text[self.index] == '(') {
            self.index += 1;
            const inner = try self.sum();
            self.skipSpace();
            if (self.index >= self.text.len or self.text[self.index] != ')') return error.Invalid;
            self.index += 1;
            return inner;
        }

        // A nested `calc()` is the same expression written twice over, so it
        // flattens into its parent. Any other function is somebody else's.
        if (identEnd(self.text, self.index)) |end| {
            if (end < self.text.len and self.text[end] == '(') {
                if (!std.ascii.eqlIgnoreCase(self.text[self.index..end], "calc")) {
                    return error.Unmodelled;
                }
                self.index = end + 1;
                const inner = try self.sum();
                self.skipSpace();
                if (self.index >= self.text.len or self.text[self.index] != ')') return error.Invalid;
                self.index += 1;
                return inner;
            }
            return error.Invalid;
        }

        const start = self.index;
        const end = numberEnd(self.text, start) orelse return error.Invalid;
        const token = self.text[start..end];
        const parsed = units.parse(token) catch return unitVerdict(token);
        self.index = end;
        var value: Folded = .{};
        try value.add(parsed.unit, parsed.value);
        return value;
    }
};

/// What a token `units.parse` refused means, which is two different things.
///
/// Chrome has sixty units and units.zig resolves twenty-two of them, so "not a
/// unit this engine knows" is not the same as "not a unit". `calc(100svh -
/// 3.5rem)` is a declaration every browser keeps and this one cannot fold;
/// `calc(10px + 2foo)` is one every browser drops. Refusing both threw away a
/// real declaration on tailwindcss.com, found by counting that page's 1415
/// calc()s on either side of the change (scratch/b98/expr-b98-calc-inventory.js).
///
/// The sixty are already written down: chrome_value_case.units is the measured
/// spelling table, so a suffix in it is a real unit whatever this engine can do
/// with it.
fn unitVerdict(token: []const u8) Error {
    var end = token.len;
    while (end > 0 and (std.ascii.isAlphabetic(token[end - 1]) or token[end - 1] == '%')) end -= 1;
    const suffix = token[end..];
    if (suffix.len == 0) return error.Invalid;
    var lower: [16]u8 = undefined;
    if (suffix.len > lower.len) return error.Invalid;
    const folded = std.ascii.lowerString(lower[0..suffix.len], suffix);
    if (chrome_value_case.units.has(folded)) return error.Unmodelled;
    return error.Invalid;
}

/// The end of an identifier starting at `start`, or null when there is not one
/// there. Only used to spot a function name, so a leading digit disqualifies.
fn identEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    const first = text[start];
    // A `-` starts an identifier only when a letter follows it: `-2px` is a
    // signed number, and reading it as a name is what made `calc(1em + -2px)`
    // and `calc(-1 * 1em)` come back refused.
    if (first == '-') {
        if (start + 1 >= text.len) return null;
        const second = text[start + 1];
        if (!std.ascii.isAlphabetic(second) and second != '_' and second != '-') return null;
    } else if (!std.ascii.isAlphabetic(first) and first != '_') {
        return null;
    }
    var end = start;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or
        text[end] == '_' or text[end] == '-')) : (end += 1)
    {}
    return end;
}

/// The end of a numeric token -- sign, digits, fraction, exponent, then the
/// unit's letters or a `%`. An unknown suffix comes back as part of the token
/// and `units.parse` refuses it, which is what drops `calc(10px + 2foo)`.
fn numberEnd(text: []const u8, start: usize) ?usize {
    var end = start;
    if (end < text.len and (text[end] == '+' or text[end] == '-')) end += 1;
    var digits = false;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) digits = true;
    if (end < text.len and text[end] == '.') {
        end += 1;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) digits = true;
    }
    if (!digits) return null;
    if (end < text.len and (text[end] == 'e' or text[end] == 'E')) {
        var probe = end + 1;
        if (probe < text.len and (text[probe] == '+' or text[probe] == '-')) probe += 1;
        var exponent = false;
        while (probe < text.len and std.ascii.isDigit(text[probe])) : (probe += 1) exponent = true;
        if (exponent) end = probe;
    }
    while (end < text.len and (std.ascii.isAlphabetic(text[end]) or text[end] == '%')) : (end += 1) {}
    return end;
}

/// Term order, measured: the percentage first, then the dimensions in
/// alphabetical order by unit -- `calc(1em + 1px + 1rem)`, `calc(1% + 1px +
/// 1vh)`, `calc(1ch + 1em)`. A plain number never shares a sum with a
/// dimension, so where it would sort does not come up.
fn before(a: Term, b: Term) bool {
    if (a.unit == .percentage) return b.unit != .percentage;
    if (b.unit == .percentage) return false;
    return std.mem.lessThan(u8, units.suffix(a.unit), units.suffix(b.unit));
}

/// Prints the folded value, `calc(` and all.
///
/// Every unit that appeared keeps a term even when it totals zero: measured,
/// `calc(0px + 0em)` prints `calc(0em + 0px)` and not `calc(0px)`.
pub fn write(writer: *std.Io.Writer, folded: Folded) !void {
    var terms: [max_terms]Term = folded.terms;
    const sorted = terms[0..folded.len];
    std.mem.sort(Term, sorted, {}, struct {
        fn lessThan(_: void, a: Term, b: Term) bool {
            return before(a, b);
        }
    }.lessThan);

    try writer.writeAll("calc(");
    if (sorted.len == 0) {
        try writer.writeAll("0");
    }
    for (sorted, 0..) |term, i| {
        if (i != 0) {
            // A negative term after the first is a subtraction, which is how
            // `calc(1em + -2px)` comes back as `calc(1em - 2px)`.
            try writer.writeAll(if (term.value < 0) " - " else " + ");
        }
        const magnitude = if (i == 0) term.value else @abs(term.value);
        try units.writeNumber(writer, magnitude);
        try writer.writeAll(units.suffix(term.unit));
    }
    try writer.writeAll(")");
}

/// Whether any `calc()` in the value is one Chrome drops the declaration for.
///
/// The same walk as `rewrite` without the writing, because the refusal is asked
/// on every declaration a page stores and has no use for the folded text.
pub fn valueIsInvalid(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) {
        const open = spanStart(value, index) orelse return false;
        const close = spanEnd(value, open) orelse return false;
        _ = foldBody(value[open + 5 .. close]) catch |err| switch (err) {
            error.Invalid => return true,
            error.Unmodelled => {},
        };
        index = close + 1;
    }
    return false;
}

/// Rewrites every `calc()` in a declaration value, leaving the rest alone.
///
/// A value can carry more than one -- `padding: calc(1em + 1px) calc(2px +
/// 3px)` folds each on its own -- and one can be nested inside another
/// function, as in `translateX(calc(1px + 1em))`, which is why this scans for
/// spans rather than asking whether the whole value is a calc.
///
/// Null when nothing changed, so the caller keeps the string it already had.
/// error.Invalid when any span is one Chrome would drop the declaration for.
/// `Unmodelled` is deliberately not in here: `rewrite` handles that case itself
/// by copying the span through, so a caller only ever has to decide what to do
/// about a genuine refusal.
pub const RewriteError = error{ Invalid, OutOfMemory, WriteFailed, StringTooLarge };

pub fn rewrite(arena: Allocator, value: []const u8) RewriteError!?[]const u8 {
    if (spanStart(value, 0) == null) return null;

    var buf: std.Io.Writer.Allocating = .init(arena);
    errdefer buf.deinit();
    var index: usize = 0;
    while (index < value.len) {
        const open = spanStart(value, index) orelse break;
        const close = spanEnd(value, open) orelse break;
        const folded = foldBody(value[open + 5 .. close]) catch |err| switch (err) {
            // Left exactly as it was: a function this file does not model is
            // not a mistake, and refusing one would drop a declaration every
            // browser keeps.
            error.Unmodelled => {
                try buf.writer.writeAll(value[index .. close + 1]);
                index = close + 1;
                continue;
            },
            error.Invalid => return error.Invalid,
        };
        try buf.writer.writeAll(value[index..open]);
        try write(&buf.writer, folded);
        index = close + 1;
    }
    try buf.writer.writeAll(value[index..]);
    const written = buf.written();
    if (std.mem.eql(u8, written, value)) {
        buf.deinit();
        return null;
    }
    return written;
}

/// The index of the next `calc(` that starts a token rather than ending an
/// identifier -- `nonsense-calc(1px)` is not one.
fn spanStart(value: []const u8, from: usize) ?usize {
    var index = from;
    while (index + 5 <= value.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + 5], "calc(")) continue;
        if (index != 0) {
            const prev = value[index - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '-') continue;
        }
        return index;
    }
    return null;
}

/// The `)` matching the `(` of the span opened at `open`.
fn spanEnd(value: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var index = open + 4;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

const testing = @import("../../../testing.zig");

test "calc: folds a sum into one term per unit" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "1px + 2px", "calc(3px)" },
        .{ "10px - 3px", "calc(7px)" },
        .{ "2em + 3em", "calc(5em)" },
        .{ "1px + 0px", "calc(1px)" },
        .{ "0px + 0em", "calc(0em + 0px)" },
        .{ "1in + 1pt + 1pc", "calc(113.333px)" },
        .{ "1px + 1em", "calc(1em + 1px)" },
        .{ "1vh + 1px + 1%", "calc(1% + 1px + 1vh)" },
        .{ "1px - 1em", "calc(-1em + 1px)" },
        .{ "1em + -2px", "calc(1em - 2px)" },
        .{ "2 * 1em + 1px", "calc(2em + 1px)" },
        .{ "1em / 2", "calc(0.5em)" },
        .{ "(1px + 1em) * 2", "calc(2em + 2px)" },
        .{ "calc(1px + 1em) + 1rem", "calc(1em + 1px + 1rem)" },
        .{ "1px * 2 * 3", "calc(6px)" },
        .{ "-1 * 1em", "calc(-1em)" },
    };
    inline for (cases) |case| {
        const folded = try foldBody(case[0]);
        var buf: std.Io.Writer.Allocating = .init(testing.arena_allocator);
        try write(&buf.writer, folded);
        try testing.expectEqual(case[1], buf.written());
    }
}

test "calc: refuses what Chrome refuses" {
    const cases = [_][]const u8{
        "1px + 1",
        "1px * 1px",
        "1px + 1deg",
        "",
        "1px +1px",
        "1px+1px",
        "10px + 2foo",
    };
    inline for (cases) |body| {
        try testing.expectError(error.Invalid, foldBody(body));
    }
}

test "calc: leaves a function it does not model alone" {
    try testing.expectError(error.Unmodelled, foldBody("min(1px, 1em) + 1rem"));
    try testing.expectError(error.Unmodelled, foldBody("1px / 0"));
}
