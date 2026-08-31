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

/// A page writes at most a couple of comparisons in one value; four is already
/// more than any measured row.
const max_fns = 4;

pub const Folded = struct {
    terms: [max_terms]Term = undefined,
    len: usize = 0,
    /// Comparison functions, already serialised, in the order they were met.
    /// They are terms of the sum like any other -- `calc(min(1px, 1em) + 1rem)`
    /// is one unit term and one of these -- but they cannot be added to a unit
    /// or to each other, because which argument wins is not known until the
    /// units resolve. So they are carried whole and printed after the units.
    fns: [max_fns][]const u8 = undefined,
    fn_len: usize = 0,

    fn addFn(self: *Folded, text: []const u8) Error!void {
        if (self.fn_len == max_fns) return error.Unmodelled;
        self.fns[self.fn_len] = text;
        self.fn_len += 1;
    }

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

    /// Multiplying a comparison would have to be pushed inside its arguments,
    /// and Chrome's spelling for that is not measured -- so it is left alone.
    fn scale(self: *Folded, factor: f64) Error!void {
        if (self.fn_len != 0) return error.Unmodelled;
        for (self.terms[0..self.len]) |*term| term.value *= factor;
    }

    /// The value as a plain number, or null when it carries a unit. A `*` needs
    /// one side to be this and a `/` needs its right side to be.
    fn asNumber(self: *const Folded) ?f64 {
        if (self.fn_len != 0) return null;
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
///
/// Allocation-free, which is what the refusal check needs: `valueIsInvalid` is
/// asked of every declaration a page stores and has no use for the folded text.
/// A comparison function met on this path reports `Unmodelled`, so the refusal
/// never has an opinion about one.
pub fn foldBody(body: []const u8) Error!Folded {
    return foldBodyIn(null, body);
}

/// The same fold with somewhere to put a comparison's serialised text.
pub fn foldBodyIn(arena: ?Allocator, body: []const u8) Error!Folded {
    var parser: Parser = .{ .text = body, .arena = arena };
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
    /// Null on the refusal path, where nothing is being written.
    arena: ?Allocator = null,

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
            // A subtracted comparison would need its sign pushed inside, which
            // is not a spelling anything here has measured.
            if (operand.fn_len != 0 and sign < 0) return error.Unmodelled;
            for (operand.fns[0..operand.fn_len]) |text| try total.addFn(text);
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
                try total.scale(1 / divisor);
                continue;
            }
            if (operand.asNumber()) |factor| {
                try total.scale(factor);
                continue;
            }
            const factor = total.asNumber() orelse return error.Invalid;
            total = operand;
            try total.scale(factor);
        }
    }

    /// `min(a, b, ...)`, `max(...)` or `clamp(lo, mid, hi)` starting at the
    /// `(` that `open` points at.
    ///
    /// Three outcomes, all measured (scratch/b98/expr-b98-compare-fns.js):
    ///
    ///   * One argument is not a comparison: `min(1px)` is `calc(1px)`.
    ///   * Arguments that all reduce to the same single unit ARE comparable
    ///     here, so the comparison is carried out: `clamp(1px, 2px, 3px)` is
    ///     `calc(2px)`, and it is what makes the inner `min(1px, 2px)` of
    ///     `min(min(1px, 2px), 1em)` disappear into `min(1px, 1em)`.
    ///   * Otherwise the shape is kept with each argument folded on its own,
    ///     in the order written -- `min(1px, 1em)` and `min(1em, 1px)` both
    ///     come back as they went in, which is what says this is not a sort.
    fn comparison(self: *Parser, kind: Kind, open: usize) Error!Folded {
        const arena = self.arena orelse return error.Unmodelled;
        self.index = open + 1;

        var args: [8]Folded = undefined;
        var count: usize = 0;
        while (true) {
            if (count == args.len) return error.Unmodelled;
            args[count] = try self.sum();
            count += 1;
            self.skipSpace();
            if (self.index >= self.text.len) return error.Invalid;
            const c = self.text[self.index];
            self.index += 1;
            if (c == ')') break;
            if (c != ',') return error.Invalid;
        }
        // `clamp()` takes exactly three; `min()`/`max()` take at least one.
        if (kind == .clamp and count != 3) return error.Invalid;

        if (count == 1) return args[0];
        if (decide(kind, args[0..count])) |value| {
            var folded: Folded = .{};
            try folded.add(value.unit, value.value);
            return folded;
        }

        var buf: std.Io.Writer.Allocating = .init(arena);
        errdefer buf.deinit();
        buf.writer.writeAll(@tagName(kind)) catch return error.Unmodelled;
        buf.writer.writeByte('(') catch return error.Unmodelled;
        for (args[0..count], 0..) |arg, i| {
            if (i != 0) buf.writer.writeAll(", ") catch return error.Unmodelled;
            writeTerms(&buf.writer, arg) catch return error.Unmodelled;
        }
        buf.writer.writeByte(')') catch return error.Unmodelled;

        var folded: Folded = .{};
        try folded.addFn(buf.written());
        return folded;
    }

    /// A bare identifier inside a math function, which is a number in exactly
    /// five spellings and a refusal in every other.
    ///
    /// Measured over seventeen rows (scratch/b98/expr-b98-calc-idents.js):
    /// Chrome keeps `e`, `pi`, `infinity`, `-infinity` and `NaN`
    /// case-insensitively, and drops the declaration for `garbage`, `auto`,
    /// `inherit`, `var` and a bare exponent like `1e`. Treating every
    /// identifier as a refusal is what took `calc(1px * infinity)` away when
    /// this refusal first landed.
    ///
    /// `e` and `pi` fold into the term as the numbers they are --
    /// `calc(1px * pi)` reads back `calc(3.14159px)`. The other three keep the
    /// author's text instead: printing them the way Chrome does
    /// (`calc(infinity * 1px)`) is a serialisation rule of its own, and
    /// answering `calc(infpx)` would be worse than not answering.
    fn constant(self: *Parser, name: []const u8, end: usize) Error!Folded {
        const value: f64 = if (std.ascii.eqlIgnoreCase(name, "e"))
            std.math.e
        else if (std.ascii.eqlIgnoreCase(name, "pi"))
            std.math.pi
        else if (std.ascii.eqlIgnoreCase(name, "infinity") or
            std.ascii.eqlIgnoreCase(name, "-infinity") or
            std.ascii.eqlIgnoreCase(name, "nan"))
            return error.Unmodelled
        else
            return error.Invalid;

        self.index = end;
        var folded: Folded = .{};
        try folded.add(.none, value);
        return folded;
    }

    /// `primary := '(' sum ')' | 'calc(' sum ')' | <constant> | <number> | <dimension>`
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
                const name = self.text[self.index..end];
                if (std.ascii.eqlIgnoreCase(name, "calc")) {
                    self.index = end + 1;
                    const inner = try self.sum();
                    self.skipSpace();
                    if (self.index >= self.text.len or self.text[self.index] != ')') return error.Invalid;
                    self.index += 1;
                    return inner;
                }
                if (comparisonKind(name)) |kind| return self.comparison(kind, end);
                return error.Unmodelled;
            }
            return self.constant(self.text[self.index..end], end);
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

pub const Kind = enum { min, max, clamp };

fn comparisonKind(name: []const u8) ?Kind {
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) return @field(Kind, field.name);
    }
    return null;
}

/// The comparison's answer when every argument is one term in the same unit,
/// or null when it cannot be settled without resolving them. Two arguments in
/// different units are not comparable here -- `1px` against `1em` needs a font
/// size -- and that is exactly the case Chrome keeps the function shape for.
fn decide(kind: Kind, args: []const Folded) ?Term {
    var unit: ?units.Unit = null;
    var values: [8]f64 = undefined;
    for (args, 0..) |arg, i| {
        if (arg.fn_len != 0 or arg.len != 1) return null;
        const term = arg.terms[0];
        if (unit) |seen| {
            if (seen != term.unit) return null;
        } else {
            unit = term.unit;
        }
        values[i] = term.value;
    }
    const u = unit orelse return null;
    const answer = switch (kind) {
        .min => blk: {
            var m = values[0];
            for (values[1..args.len]) |v| m = @min(m, v);
            break :blk m;
        },
        .max => blk: {
            var m = values[0];
            for (values[1..args.len]) |v| m = @max(m, v);
            break :blk m;
        },
        // `clamp(lo, mid, hi)` is `max(lo, min(mid, hi))`, per css-values-4.
        .clamp => @max(values[0], @min(values[1], values[2])),
    };
    return .{ .unit = u, .value = answer };
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
    // A value that is nothing but one comparison is printed as that
    // comparison: `min(1px, 1em)` and not `calc(min(1px, 1em))`. The wrapper
    // only appears once there is a sum to wrap.
    if (folded.len == 0 and folded.fn_len == 1) {
        return writer.writeAll(folded.fns[0]);
    }
    try writer.writeAll("calc(");
    try writeTerms(writer, folded);
    try writer.writeAll(")");
}

/// The sum itself, without the `calc()` around it -- which is what a
/// comparison's arguments need, since `min(1em + 1px, 2em)` writes its first
/// argument as a sum and not as a nested `calc()`.
fn writeTerms(writer: *std.Io.Writer, folded: Folded) !void {
    var terms: [max_terms]Term = folded.terms;
    const sorted = terms[0..folded.len];
    std.mem.sort(Term, sorted, {}, struct {
        fn lessThan(_: void, a: Term, b: Term) bool {
            return before(a, b);
        }
    }.lessThan);

    if (sorted.len == 0 and folded.fn_len == 0) {
        return writer.writeAll("0");
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
    // Measured: a comparison sorts after every unit term, so
    // `calc(min(1px, 1em) + 1rem)` comes back `calc(1rem + min(1px, 1em))`.
    for (folded.fns[0..folded.fn_len], 0..) |text, i| {
        if (sorted.len != 0 or i != 0) try writer.writeAll(" + ");
        try writer.writeAll(text);
    }
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
        _ = foldBody(value[open .. close + 1]) catch |err| switch (err) {
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
        // The whole span, name included: `primary` routes `calc(` and each
        // comparison from the name, so one entry serves both.
        const folded = foldBodyIn(arena, value[open .. close + 1]) catch |err| switch (err) {
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

/// The index where the next math function starts, or null when there is not
/// one left.
///
/// A math function is `calc()` or one of the comparisons; every other function
/// in a value -- `rgb()`, `translateX()`, `url()` -- is somebody else's, and is
/// skipped rather than descended into. Which is what lets
/// `translateX(calc(1px + 1em))` fold: the scan walks past `translateX(` and
/// finds the `calc(` inside it.
///
/// The name has to start a token, so `nonsense-calc(1px)` is not one.
fn spanStart(value: []const u8, from: usize) ?usize {
    var index = from;
    while (index < value.len) : (index += 1) {
        if (value[index] != '(') continue;
        var start = index;
        while (start > 0 and isNameChar(value[start - 1])) start -= 1;
        if (start == index) continue;
        if (start != 0 and isNameChar(value[start - 1])) continue;
        if (mathFunction(value[start..index])) return start;
    }
    return null;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn mathFunction(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "calc") or comparisonKind(name) != null;
}

/// The `)` matching the `(` of the span opened at `open`, which is the index of
/// the function's NAME.
fn spanEnd(value: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var index = open;
    while (index < value.len and value[index] != '(') : (index += 1) {}
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
