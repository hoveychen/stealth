//! Chrome never hands a page back the selector its author wrote. Reading
//! `rule.selectorText` re-serialises the parsed selector, so a minified sheet's
//! `a,b` comes back as `a, b`, `x~y` as `x ~ y`, `DIV` as `div` and `[a=b]` as
//! `[a="b"]`. Echoing the source instead is fingerprint-visible: two thirds of
//! the 329 characters by which the Cloudflare challenge page's `@keyframes`
//! payload is shorter here than on Chrome are this one difference.
//!
//! Every rule below was measured on Chrome over http://localhost with
//! `tools/fingerprint/probes/expr-selector-serialize.js` and its `2` sibling;
//! `tests/css/selector_serialize.html` carries the same readings.
//!
//! The scanner works on the source bytes rather than on a parsed selector, so
//! an escape survives exactly as written and anything it cannot make sense of
//! is copied through untouched. That is the safe direction: `_selector_text` is
//! also what StyleManager re-parses for the cascade, so a selector this cannot
//! model keeps the author's bytes and keeps matching rather than being
//! rewritten into something else.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The four pseudo-elements that predate `::`. Chrome writes all of them with
/// two colons however the author spelled them.
const legacy_pseudo_elements = [_][]const u8{ "before", "after", "first-line", "first-letter" };

/// Rewrite `input` the way Chrome writes a parsed selector back out. On
/// anything unexpected the trimmed input comes back unchanged.
pub fn normalize(allocator: Allocator, input: []const u8) Allocator.Error![]const u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return trimmed;

    var out = std.Io.Writer.Allocating.init(allocator);
    var scanner = Scanner{ .src = trimmed, .out = &out.writer, .allocator = allocator };
    scanner.run() catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => return trimmed,
    };
    return out.written();
}

const Error = error{ Bail, WriteFailed, OutOfMemory };

const Scanner = struct {
    src: []const u8,
    i: usize = 0,
    out: *std.Io.Writer,
    allocator: Allocator,

    /// Zero until something has been written, then the last byte written. The
    /// spacing rules are all phrased against it: a combinator needs no leading
    /// space when the output already ends in `(` or a space.
    last: u8 = 0,

    /// Whitespace has been seen and has not yet been decided on -- it becomes a
    /// descendant combinator only if something that is not a combinator, a
    /// comma or a `)` follows it.
    pending_space: bool = false,

    /// The next identifier is a type selector, so it gets lowercased. A class
    /// or id name never does.
    compound_start: bool = true,

    /// One entry per open `(`, true when the function takes An+B, where `+` is
    /// arithmetic rather than a combinator.
    nth: [16]bool = undefined,
    depth: usize = 0,

    fn run(self: *Scanner) Error!void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (isWhite(c)) {
                self.i += 1;
                self.pending_space = true;
                continue;
            }
            switch (c) {
                ',' => {
                    self.i += 1;
                    self.pending_space = false;
                    try self.write(", ");
                    self.compound_start = true;
                },
                '>', '+', '~' => {
                    self.i += 1;
                    if (self.insideNth()) {
                        try self.flushSpace();
                        try self.write(&.{c});
                    } else {
                        try self.combinator(c);
                    }
                },
                '[' => {
                    try self.flushSpace();
                    try self.attribute();
                    self.compound_start = false;
                },
                ':' => {
                    try self.flushSpace();
                    try self.pseudo();
                },
                '.', '#' => {
                    try self.flushSpace();
                    self.i += 1;
                    try self.write(&.{c});
                    try self.writeIdent(false);
                    self.compound_start = false;
                },
                '(' => {
                    try self.flushSpace();
                    self.i += 1;
                    try self.write("(");
                    try self.push(false);
                },
                ')' => {
                    self.i += 1;
                    self.pending_space = false;
                    try self.write(")");
                    self.pop();
                    self.compound_start = false;
                },
                '"', '\'' => {
                    try self.flushSpace();
                    try self.write(self.readString());
                    self.compound_start = false;
                },
                else => {
                    try self.flushSpace();
                    if (isIdentStart(c)) {
                        // A bare identifier is a type selector at the head of a
                        // compound, and inside An+B it is the `n` or the `of`.
                        try self.writeIdent(self.compound_start or self.insideNth());
                        self.compound_start = false;
                    } else {
                        self.i += 1;
                        try self.write(&.{c});
                        // A digit can still be followed by the `n` of An+B.
                        if (!std.ascii.isDigit(c)) self.compound_start = false;
                    }
                },
            }
        }
    }

    /// `a:before` and `a:BEFORE` and `a::before` all come back `a::before`;
    /// `:NOT(` opens a functional pseudo-class whose argument is a selector
    /// list, and `:nth-child(` one whose argument is arithmetic.
    fn pseudo(self: *Scanner) Error!void {
        self.i += 1;
        var double = false;
        if (self.i < self.src.len and self.src[self.i] == ':') {
            double = true;
            self.i += 1;
        }
        const name = self.readIdent();
        if (name.len == 0) {
            try self.write(if (double) "::" else ":");
            return;
        }
        const opens = self.i < self.src.len and self.src[self.i] == '(';
        const legacy = !double and !opens and isLegacyPseudoElement(name);
        try self.write(if (double or legacy) "::" else ":");
        try self.writeLower(name);
        self.compound_start = false;
        if (opens) {
            self.i += 1;
            try self.write("(");
            try self.push(std.ascii.startsWithIgnoreCase(name, "nth-"));
        }
    }

    /// `[ HREF = x I ]` comes back `[href="x" i]`: the interior loses its
    /// whitespace, the name and the flag are lowercased, and the value is
    /// always a double-quoted string. Anything that does not fit that shape is
    /// copied through as written.
    fn attribute(self: *Scanner) Error!void {
        const open = self.i;
        var scratch = std.Io.Writer.Allocating.init(self.allocator);
        const saved_last = self.last;
        const committed = self.attributeInto(&scratch.writer) catch |err| switch (err) {
            error.Bail => false,
            else => |e| return e,
        };
        if (committed) {
            self.last = saved_last;
            try self.write(scratch.written());
            return;
        }
        self.i = open;
        self.last = saved_last;
        try self.write(self.readBalancedBracket());
    }

    fn attributeInto(self: *Scanner, w: *std.Io.Writer) Error!bool {
        const src = self.src;
        self.i += 1; // '['
        self.skipWhite();

        const name_start = self.i;
        if (self.readIdent().len == 0) return error.Bail;
        // A namespace prefix, but `|=` is a matcher rather than one.
        if (self.i + 1 < src.len and src[self.i] == '|' and src[self.i + 1] != '=') {
            self.i += 1;
            _ = self.readIdent();
        }
        const name = src[name_start..self.i];
        self.skipWhite();
        try w.writeAll("[");
        try writeLowerTo(w, name);

        if (self.i < src.len and src[self.i] == ']') {
            self.i += 1;
            try w.writeAll("]");
            return true;
        }

        const matcher_start = self.i;
        if (self.i < src.len) switch (src[self.i]) {
            '~', '|', '^', '$', '*' => self.i += 1,
            else => {},
        };
        if (self.i >= src.len or src[self.i] != '=') return error.Bail;
        self.i += 1;
        try w.writeAll(src[matcher_start..self.i]);
        self.skipWhite();

        if (self.i >= src.len) return error.Bail;
        try self.writeValue(w);
        self.skipWhite();

        if (self.i < src.len and isIdentStart(src[self.i])) {
            const flag = self.readIdent();
            try w.writeAll(" ");
            try writeLowerTo(w, flag);
            self.skipWhite();
        }
        if (self.i >= src.len or src[self.i] != ']') return error.Bail;
        self.i += 1;
        try w.writeAll("]");
        return true;
    }

    /// However the author quoted it, the value comes back double-quoted.
    fn writeValue(self: *Scanner, w: *std.Io.Writer) Error!void {
        const src = self.src;
        const c = src[self.i];
        if (c == '"') {
            try w.writeAll(self.readString());
            return;
        }
        if (c == '\'') {
            const raw = self.readString();
            // Drop the quotes and re-quote: an escaped `'` no longer needs its
            // backslash, and a bare `"` now does.
            const inner = if (raw.len >= 2 and raw[raw.len - 1] == '\'') raw[1 .. raw.len - 1] else raw[1..];
            try w.writeAll("\"");
            var k: usize = 0;
            while (k < inner.len) : (k += 1) {
                if (inner[k] == '\\' and k + 1 < inner.len and inner[k + 1] == '\'') {
                    try w.writeAll("'");
                    k += 1;
                    continue;
                }
                if (inner[k] == '"') {
                    try w.writeAll("\\\"");
                    continue;
                }
                if (inner[k] == '\\' and k + 1 < inner.len) {
                    try w.writeAll(inner[k .. k + 2]);
                    k += 1;
                    continue;
                }
                try w.writeAll(inner[k .. k + 1]);
            }
            try w.writeAll("\"");
            return;
        }
        if (!isIdentStart(c)) return error.Bail;
        const ident = self.readIdent();
        try w.writeAll("\"");
        try w.writeAll(ident);
        try w.writeAll("\"");
    }

    fn combinator(self: *Scanner, c: u8) Error!void {
        self.pending_space = false;
        if (self.last != 0 and self.last != '(' and self.last != ' ') try self.write(" ");
        try self.write(&.{c});
        try self.write(" ");
        self.compound_start = true;
    }

    /// Turn held-over whitespace into the single space of a descendant
    /// combinator, unless it is leading, or already written, or sits right
    /// after a `(` where Chrome drops it.
    fn flushSpace(self: *Scanner) Error!void {
        if (!self.pending_space) return;
        self.pending_space = false;
        if (self.last == 0 or self.last == '(' or self.last == ' ') return;
        try self.write(" ");
        self.compound_start = true;
    }

    fn write(self: *Scanner, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        try self.out.writeAll(bytes);
        self.last = bytes[bytes.len - 1];
    }

    fn writeIdent(self: *Scanner, lower: bool) Error!void {
        const ident = self.readIdent();
        if (ident.len == 0) {
            // Not an identifier after all; take one byte so we cannot spin.
            if (self.i < self.src.len) {
                const c = self.src[self.i];
                self.i += 1;
                try self.write(&.{c});
            }
            return;
        }
        if (lower) return self.writeLower(ident);
        try self.write(ident);
    }

    fn writeLower(self: *Scanner, ident: []const u8) Error!void {
        try writeLowerTo(self.out, ident);
        self.last = ident[ident.len - 1];
    }

    /// The bytes of one identifier, escapes and all, exactly as written.
    fn readIdent(self: *Scanner) []const u8 {
        const src = self.src;
        const start = self.i;
        while (self.i < src.len) {
            const c = src[self.i];
            if (c == '\\') {
                self.i += 1;
                if (self.i >= src.len) break;
                if (std.ascii.isHex(src[self.i])) {
                    // Up to six hex digits, then one optional whitespace that
                    // terminates the escape and belongs to it.
                    var digits: usize = 0;
                    while (self.i < src.len and digits < 6 and std.ascii.isHex(src[self.i])) : (digits += 1) {
                        self.i += 1;
                    }
                    if (self.i < src.len and isWhite(src[self.i])) self.i += 1;
                } else {
                    self.i += 1;
                }
                continue;
            }
            if (!isIdentChar(c)) break;
            self.i += 1;
        }
        return src[start..self.i];
    }

    /// A string with its quotes, exactly as written.
    fn readString(self: *Scanner) []const u8 {
        const src = self.src;
        const start = self.i;
        const quote = src[self.i];
        self.i += 1;
        while (self.i < src.len) {
            const c = src[self.i];
            if (c == '\\' and self.i + 1 < src.len) {
                self.i += 2;
                continue;
            }
            self.i += 1;
            if (c == quote) break;
        }
        return src[start..self.i];
    }

    /// `[` through its matching `]`, strings included, for the fallback path.
    fn readBalancedBracket(self: *Scanner) []const u8 {
        const src = self.src;
        const start = self.i;
        self.i += 1;
        while (self.i < src.len) {
            const c = src[self.i];
            if (c == '"' or c == '\'') {
                _ = self.readString();
                continue;
            }
            self.i += 1;
            if (c == ']') break;
        }
        return src[start..self.i];
    }

    fn skipWhite(self: *Scanner) void {
        while (self.i < self.src.len and isWhite(self.src[self.i])) self.i += 1;
    }

    fn push(self: *Scanner, is_nth: bool) Error!void {
        if (self.depth == self.nth.len) return error.Bail;
        self.nth[self.depth] = is_nth;
        self.depth += 1;
        self.pending_space = false;
        self.compound_start = true;
    }

    fn pop(self: *Scanner) void {
        if (self.depth > 0) self.depth -= 1;
    }

    fn insideNth(self: *const Scanner) bool {
        return self.depth > 0 and self.nth[self.depth - 1];
    }
};

fn writeLowerTo(w: *std.Io.Writer, ident: []const u8) Error!void {
    for (ident) |c| try w.writeAll(&.{std.ascii.toLower(c)});
}

fn isLegacyPseudoElement(name: []const u8) bool {
    for (legacy_pseudo_elements) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn isWhite(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-' or c == '\\' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c >= 0x80;
}
