// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// A very small GLSL ES interpreter: enough to run the shaders a fingerprinting
// script compiles, and nothing like enough to run a renderer.
//
// The reason it exists is that a WebGL readback is arithmetic. The widget's
// first fragment shader is
//
//     gl_FragColor = vec4(sin(1.0), cos(1.0), sin(1.0)*cos(1.0), 1.0);
//
// and Chrome answers d7 8a 74 ff for every pixel it covers -- the three
// constants quantised to eight bits. Nothing in that number came from a GPU,
// so nothing about reproducing it needs one. The second shader is per-pixel
// rather than constant, but it reads only `gl_FragCoord`, so it is the same
// statement with a coordinate in it.
//
// Precision is the part worth stating, because it is the part that decides
// whether the bytes match rather than merely look plausible. Everything is
// evaluated at fp32, which is what `highp` and (on every driver measured here)
// `mediump` give. The transcendentals are the exception: `sin`, `cos` and
// `inversesqrt` are computed at double and rounded once to fp32, because that
// is what the reference answers -- checked component by component against
// Chrome's 1024 and 16 bytes before any of this was written.
//
// What is deliberately absent: textures, varyings, uniforms, matrices,
// user-defined functions, structs, arrays and every builtin the two shaders do
// not call. A shader using any of them fails to compile, which is a state
// Chrome also reaches and which the caller reports honestly through
// COMPILE_STATUS rather than papering over with a colour it made up.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ SyntaxError, Unsupported, OutOfMemory };

/// A GLSL value: one to four components, with the int/float distinction kept
/// because `/` truncates on ints and a loop counter is one.
pub const Value = struct {
    n: u8 = 1,
    int: bool = false,
    v: [4]f32 = @splat(0),

    pub fn float(x: f32) Value {
        return .{ .n = 1, .v = .{ x, 0, 0, 0 } };
    }

    pub fn integer(x: i32) Value {
        return .{ .n = 1, .int = true, .v = .{ @floatFromInt(x), 0, 0, 0 } };
    }

    pub fn vec4(x: f32, y: f32, z: f32, w: f32) Value {
        return .{ .n = 4, .v = .{ x, y, z, w } };
    }
};

// ---------------------------------------------------------------------------
// Tokens

const Token = struct {
    kind: Kind,
    text: []const u8,
    number: f64 = 0,
    int: bool = false,

    const Kind = enum { ident, number, punct, eof };
};

/// Splits the source into tokens. Comments and preprocessor lines are dropped
/// here: `#version 300 es` is the only directive the shaders carry, and the
/// two dialects differ in ways this interpreter does not look at.
fn lex(arena: Allocator, src: []const u8) Error![]const Token {
    var tokens: std.ArrayList(Token) = .empty;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i = @min(i + 2, src.len);
            continue;
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
            try tokens.append(arena, .{ .kind = .ident, .text = src[start..i] });
            continue;
        }

        if (std.ascii.isDigit(c) or (c == '.' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]))) {
            const start = i;
            var is_int = true;
            while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            if (i < src.len and src[i] == '.') {
                is_int = false;
                i += 1;
                while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            }
            if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
                is_int = false;
                i += 1;
                if (i < src.len and (src[i] == '+' or src[i] == '-')) i += 1;
                while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            }
            const text = src[start..i];
            // A trailing `f` suffix is ES 3.0 only; accepting it in both
            // dialects costs nothing and rejecting it would be a syntax error
            // Chrome does not report.
            if (i < src.len and (src[i] == 'f' or src[i] == 'F')) {
                is_int = false;
                i += 1;
            }
            const number = std.fmt.parseFloat(f64, text) catch return error.SyntaxError;
            try tokens.append(arena, .{ .kind = .number, .text = text, .number = number, .int = is_int });
            continue;
        }

        // Two-character operators first, so `<=` does not lex as `<` then `=`.
        const two: []const []const u8 = &.{ "++", "--", "<=", ">=", "==", "!=", "&&", "||", "+=", "-=", "*=", "/=" };
        var matched = false;
        if (i + 1 < src.len) {
            for (two) |op| {
                if (std.mem.eql(u8, src[i .. i + 2], op)) {
                    try tokens.append(arena, .{ .kind = .punct, .text = op });
                    i += 2;
                    matched = true;
                    break;
                }
            }
        }
        if (matched) continue;

        if (std.mem.indexOfScalar(u8, "+-*/%<>=!(){}[];,.?:", c) == null) {
            return error.SyntaxError;
        }
        try tokens.append(arena, .{ .kind = .punct, .text = src[i .. i + 1] });
        i += 1;
    }

    try tokens.append(arena, .{ .kind = .eof, .text = "" });
    return tokens.items;
}

// ---------------------------------------------------------------------------
// Syntax tree

const Op = enum { add, sub, mul, div, lt, gt, le, ge, eq, ne, andand, oror };

const Expr = union(enum) {
    literal: Value,
    ident: []const u8,
    call: struct { name: []const u8, args: []const *Expr },
    negate: *Expr,
    not: *Expr,
    binary: struct { op: Op, l: *Expr, r: *Expr },
    /// `.xyz`, `.rgb`, `.st` -- one to four components selected by name.
    swizzle: struct { e: *Expr, sel: []const u8 },
    /// `=` when `op` is null, `+=` and friends otherwise.
    assign: struct { name: []const u8, op: ?Op, value: *Expr },
    /// `i++` / `i--`, whose value is the one before the step. Nothing here
    /// reads that value, but evaluating it as the stepped one would be wrong
    /// for anything that did.
    postfix: struct { name: []const u8, inc: bool },
};

const Stmt = union(enum) {
    decl: struct { name: []const u8, int: bool, init: ?*Expr },
    expr: *Expr,
    block: []const Stmt,
    loop: struct { init: ?*Stmt, cond: ?*Expr, step: ?*Expr, body: *const Stmt },
    branch: struct { cond: *Expr, then: *const Stmt, otherwise: ?*const Stmt },
};

/// One declared vertex input. The component count is kept because
/// `getActiveAttrib` reports the declared type -- Chrome answers FLOAT_VEC2
/// for `attribute vec2 p`, not the vec4 the value is padded to on the way in.
pub const Attribute = struct {
    name: []const u8,
    components: u8,
};

/// One compiled shader stage.
pub const Shader = struct {
    body: []const Stmt,
    /// Declared `attribute` (ES 1.0) or `in` (ES 3.0) inputs in declaration
    /// order, which is the order `getAttribLocation` numbers them in.
    attributes: []const Attribute,
    /// Declared `out` variables. ES 1.0 writes its colour to the built-in
    /// `gl_FragColor`; ES 3.0 removed that and makes the shader name its own
    /// output, so the caller has to be told which name to read.
    outputs: []const Attribute,
};

const Parser = struct {
    arena: Allocator,
    tokens: []const Token,
    i: usize = 0,
    attributes: std.ArrayList(Attribute) = .empty,
    outputs: std.ArrayList(Attribute) = .empty,

    fn peek(self: *const Parser) Token {
        return self.tokens[self.i];
    }

    fn isPunct(self: *const Parser, text: []const u8) bool {
        const t = self.peek();
        return t.kind == .punct and std.mem.eql(u8, t.text, text);
    }

    fn isIdent(self: *const Parser, text: []const u8) bool {
        const t = self.peek();
        return t.kind == .ident and std.mem.eql(u8, t.text, text);
    }

    fn eat(self: *Parser, text: []const u8) bool {
        if (self.isPunct(text) or self.isIdent(text)) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, text: []const u8) Error!void {
        if (!self.eat(text)) return error.SyntaxError;
    }

    fn node(self: *Parser, e: Expr) Error!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    // -- declarations --------------------------------------------------------

    /// Storage and precision qualifiers, which this interpreter records (for
    /// `attribute`) or discards (for the rest) but never acts on.
    fn qualifier(text: []const u8) bool {
        const all: []const []const u8 = &.{
            "const",    "uniform",   "varying",   "attribute", "in",     "out",
            "inout",    "highp",     "mediump",   "lowp",      "flat",   "smooth",
            "centroid", "invariant", "precision", "layout",    "sample", "patch",
        };
        for (all) |q| if (std.mem.eql(u8, text, q)) return true;
        return false;
    }

    fn typeName(text: []const u8) ?u8 {
        if (std.mem.eql(u8, text, "float")) return 1;
        if (std.mem.eql(u8, text, "int")) return 1;
        if (std.mem.eql(u8, text, "bool")) return 1;
        if (std.mem.eql(u8, text, "vec2")) return 2;
        if (std.mem.eql(u8, text, "vec3")) return 3;
        if (std.mem.eql(u8, text, "vec4")) return 4;
        return null;
    }

    /// The top level: `precision` statements, global declarations and the one
    /// function this interpreter runs. Anything else -- a second function, a
    /// struct, a uniform block -- is a shader we cannot answer for.
    fn parseUnit(self: *Parser) Error![]const Stmt {
        var main_body: ?[]const Stmt = null;

        while (self.peek().kind != .eof) {
            if (self.eat(";")) continue;

            // `precision mediump float;`
            if (self.isIdent("precision")) {
                while (!self.isPunct(";") and self.peek().kind != .eof) self.i += 1;
                try self.expect(";");
                continue;
            }

            // `layout(location = 0) in vec2 p;`
            if (self.isIdent("layout")) {
                self.i += 1;
                try self.expect("(");
                var depth: usize = 1;
                while (depth > 0 and self.peek().kind != .eof) {
                    if (self.isPunct("(")) depth += 1;
                    if (self.isPunct(")")) depth -= 1;
                    self.i += 1;
                }
                continue;
            }

            var is_attribute = false;
            var is_output = false;
            while (self.peek().kind == .ident and qualifier(self.peek().text)) {
                if (std.mem.eql(u8, self.peek().text, "attribute") or std.mem.eql(u8, self.peek().text, "in")) {
                    is_attribute = true;
                }
                if (std.mem.eql(u8, self.peek().text, "out")) is_output = true;
                self.i += 1;
            }

            const type_token = self.peek();
            if (type_token.kind != .ident) return error.SyntaxError;
            const is_void = std.mem.eql(u8, type_token.text, "void");
            const components = typeName(type_token.text);
            if (!is_void and components == null) return error.Unsupported;
            self.i += 1;

            const name_token = self.peek();
            if (name_token.kind != .ident) return error.SyntaxError;
            self.i += 1;

            if (self.isPunct("(")) {
                if (!std.mem.eql(u8, name_token.text, "main") or !is_void) return error.Unsupported;
                try self.expect("(");
                // `void main(void)` is as common as `void main()`.
                _ = self.eat("void");
                try self.expect(")");
                if (main_body != null) return error.Unsupported;
                main_body = try self.parseBlock();
                continue;
            }

            if (is_attribute) {
                try self.attributes.append(self.arena, .{ .name = name_token.text, .components = components.? });
            }
            if (is_output) {
                try self.outputs.append(self.arena, .{ .name = name_token.text, .components = components.? });
            }
            // A global with an initialiser would have to run before main; none
            // of the shaders this answers for has one.
            if (self.eat("=")) {
                _ = try self.parseExpr();
            }
            while (self.eat(",")) {
                const extra = self.peek();
                if (extra.kind != .ident) return error.SyntaxError;
                self.i += 1;
                if (is_attribute) {
                    try self.attributes.append(self.arena, .{ .name = extra.text, .components = components.? });
                }
                if (is_output) {
                    try self.outputs.append(self.arena, .{ .name = extra.text, .components = components.? });
                }
            }
            try self.expect(";");
        }

        return main_body orelse error.SyntaxError;
    }

    fn parseBlock(self: *Parser) Error![]const Stmt {
        try self.expect("{");
        var out: std.ArrayList(Stmt) = .empty;
        while (!self.isPunct("}")) {
            if (self.peek().kind == .eof) return error.SyntaxError;
            try out.append(self.arena, try self.parseStmt());
        }
        try self.expect("}");
        return out.items;
    }

    fn stmtNode(self: *Parser, s: Stmt) Error!*const Stmt {
        const p = try self.arena.create(Stmt);
        p.* = s;
        return p;
    }

    fn parseStmt(self: *Parser) Error!Stmt {
        if (self.isPunct("{")) return .{ .block = try self.parseBlock() };

        if (self.isIdent("for")) {
            self.i += 1;
            try self.expect("(");
            var init_stmt: ?*Stmt = null;
            if (!self.isPunct(";")) {
                const s = try self.arena.create(Stmt);
                s.* = try self.parseStmt(); // consumes its own `;`
                init_stmt = s;
            } else {
                try self.expect(";");
            }
            var cond: ?*Expr = null;
            if (!self.isPunct(";")) cond = try self.parseExpr();
            try self.expect(";");
            var step: ?*Expr = null;
            if (!self.isPunct(")")) step = try self.parseExpr();
            try self.expect(")");
            const body = try self.stmtNode(try self.parseStmt());
            return .{ .loop = .{ .init = init_stmt, .cond = cond, .step = step, .body = body } };
        }

        if (self.isIdent("if")) {
            self.i += 1;
            try self.expect("(");
            const cond = try self.parseExpr();
            try self.expect(")");
            const then = try self.stmtNode(try self.parseStmt());
            var otherwise: ?*const Stmt = null;
            if (self.eat("else")) otherwise = try self.stmtNode(try self.parseStmt());
            return .{ .branch = .{ .cond = cond, .then = then, .otherwise = otherwise } };
        }

        // A declaration, which is the one place a leading identifier is a type
        // rather than a value.
        var save = self.i;
        while (self.peek().kind == .ident and qualifier(self.peek().text)) self.i += 1;
        if (self.peek().kind == .ident and typeName(self.peek().text) != null) {
            const is_int = std.mem.eql(u8, self.peek().text, "int") or std.mem.eql(u8, self.peek().text, "bool");
            self.i += 1;
            const name = self.peek();
            if (name.kind != .ident) return error.SyntaxError;
            self.i += 1;
            var init_expr: ?*Expr = null;
            if (self.eat("=")) init_expr = try self.parseExpr();
            try self.expect(";");
            return .{ .decl = .{ .name = name.text, .int = is_int, .init = init_expr } };
        }
        self.i = save;
        save = self.i;

        if (self.eat(";")) return .{ .block = &.{} };

        const e = try self.parseExpr();
        try self.expect(";");
        return .{ .expr = e };
    }

    // -- expressions ---------------------------------------------------------

    fn parseExpr(self: *Parser) Error!*Expr {
        // Assignment is the only right-associative form here, and its target is
        // always a plain name: nothing writes through a swizzle.
        if (self.peek().kind == .ident and self.tokens[self.i + 1].kind == .punct) {
            const op_text = self.tokens[self.i + 1].text;
            const compound: ?Op = if (std.mem.eql(u8, op_text, "+=")) .add else if (std.mem.eql(u8, op_text, "-=")) .sub else if (std.mem.eql(u8, op_text, "*=")) .mul else if (std.mem.eql(u8, op_text, "/=")) .div else null;
            if (std.mem.eql(u8, op_text, "=") or compound != null) {
                const name = self.peek().text;
                self.i += 2;
                const value = try self.parseExpr();
                return self.node(.{ .assign = .{ .name = name, .op = compound, .value = value } });
            }
        }
        return self.parseBinary(0);
    }

    /// Precedence climbing. The levels are GLSL's, minus the ones no shader
    /// here uses (bitwise, shift, ternary, comma).
    fn precedenceOf(text: []const u8) ?struct { op: Op, level: u8 } {
        if (std.mem.eql(u8, text, "||")) return .{ .op = .oror, .level = 1 };
        if (std.mem.eql(u8, text, "&&")) return .{ .op = .andand, .level = 2 };
        if (std.mem.eql(u8, text, "==")) return .{ .op = .eq, .level = 3 };
        if (std.mem.eql(u8, text, "!=")) return .{ .op = .ne, .level = 3 };
        if (std.mem.eql(u8, text, "<")) return .{ .op = .lt, .level = 4 };
        if (std.mem.eql(u8, text, ">")) return .{ .op = .gt, .level = 4 };
        if (std.mem.eql(u8, text, "<=")) return .{ .op = .le, .level = 4 };
        if (std.mem.eql(u8, text, ">=")) return .{ .op = .ge, .level = 4 };
        if (std.mem.eql(u8, text, "+")) return .{ .op = .add, .level = 5 };
        if (std.mem.eql(u8, text, "-")) return .{ .op = .sub, .level = 5 };
        if (std.mem.eql(u8, text, "*")) return .{ .op = .mul, .level = 6 };
        if (std.mem.eql(u8, text, "/")) return .{ .op = .div, .level = 6 };
        return null;
    }

    fn parseBinary(self: *Parser, min_level: u8) Error!*Expr {
        var left = try self.parseUnary();
        while (self.peek().kind == .punct) {
            const found = precedenceOf(self.peek().text) orelse break;
            if (found.level < min_level) break;
            self.i += 1;
            const right = try self.parseBinary(found.level + 1);
            left = try self.node(.{ .binary = .{ .op = found.op, .l = left, .r = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!*Expr {
        if (self.eat("-")) return self.node(.{ .negate = try self.parseUnary() });
        if (self.eat("+")) return self.parseUnary();
        if (self.eat("!")) return self.node(.{ .not = try self.parseUnary() });
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!*Expr {
        var e = try self.parsePrimary();
        while (true) {
            if (self.isPunct(".")) {
                self.i += 1;
                const sel = self.peek();
                if (sel.kind != .ident) return error.SyntaxError;
                self.i += 1;
                e = try self.node(.{ .swizzle = .{ .e = e, .sel = sel.text } });
                continue;
            }
            if (self.isPunct("++") or self.isPunct("--")) {
                const inc = self.isPunct("++");
                self.i += 1;
                switch (e.*) {
                    .ident => |name| e = try self.node(.{ .postfix = .{ .name = name, .inc = inc } }),
                    else => return error.Unsupported,
                }
                continue;
            }
            break;
        }
        return e;
    }

    fn parsePrimary(self: *Parser) Error!*Expr {
        const t = self.peek();
        if (t.kind == .number) {
            self.i += 1;
            return self.node(.{ .literal = if (t.int)
                .{ .n = 1, .int = true, .v = .{ @floatCast(t.number), 0, 0, 0 } }
            else
                .float(@floatCast(t.number)) });
        }
        if (self.eat("(")) {
            const e = try self.parseExpr();
            try self.expect(")");
            return e;
        }
        // A prefix `++i` steps and then reads; the loops here use the postfix
        // form, but rejecting this one outright would fail shaders Chrome
        // compiles.
        if (self.isPunct("++") or self.isPunct("--")) {
            const inc = self.isPunct("++");
            self.i += 1;
            const name = self.peek();
            if (name.kind != .ident) return error.Unsupported;
            self.i += 1;
            const one = try self.node(.{ .literal = .integer(1) });
            const cur = try self.node(.{ .ident = name.text });
            const stepped = try self.node(.{ .binary = .{ .op = if (inc) .add else .sub, .l = cur, .r = one } });
            return self.node(.{ .assign = .{ .name = name.text, .op = null, .value = stepped } });
        }
        if (t.kind == .ident) {
            self.i += 1;
            if (self.isPunct("(")) {
                self.i += 1;
                var args: std.ArrayList(*Expr) = .empty;
                if (!self.isPunct(")")) {
                    while (true) {
                        try args.append(self.arena, try self.parseExpr());
                        if (!self.eat(",")) break;
                    }
                }
                try self.expect(")");
                return self.node(.{ .call = .{ .name = t.text, .args = args.items } });
            }
            if (std.mem.eql(u8, t.text, "true")) return self.node(.{ .literal = .integer(1) });
            if (std.mem.eql(u8, t.text, "false")) return self.node(.{ .literal = .integer(0) });
            return self.node(.{ .ident = t.text });
        }
        return error.SyntaxError;
    }
};

/// Compiles one stage. Everything the result points at lives in `arena`.
///
/// Every call in the body is resolved here rather than when a fragment runs,
/// so a shader reaching a builtin we do not have fails COMPILE_STATUS instead
/// of reporting success and then drawing nothing. A page that is told its
/// shader compiled and reads back an empty buffer is being lied to twice; a
/// page told it did not compile is in a state real drivers put it in.
pub fn compile(arena: Allocator, src: []const u8) Error!Shader {
    var parser: Parser = .{ .arena = arena, .tokens = try lex(arena, src) };
    const body = try parser.parseUnit();
    try checkCalls(body);
    return .{ .body = body, .attributes = parser.attributes.items, .outputs = parser.outputs.items };
}

/// The functions this interpreter can evaluate: the vector constructors plus
/// the builtins `builtin` implements. Kept beside it, because a name added
/// there and not here would still fail at draw time.
fn known(name: []const u8) bool {
    if (Parser.typeName(name) != null) return true;
    const names: []const []const u8 = &.{
        "sin", "cos",  "tan",   "exp",  "log",   "sqrt",   "inversesqrt",
        "abs", "sign", "floor", "ceil", "fract", "length", "min",
        "max", "mod",  "pow",   "step", "dot",   "clamp",  "mix",
    };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn checkCalls(stmts: []const Stmt) Error!void {
    for (stmts) |stmt| switch (stmt) {
        .block => |b| try checkCalls(b),
        .expr => |e| try checkCallsIn(e),
        .decl => |d| if (d.init) |e| try checkCallsIn(e),
        .branch => |b| {
            try checkCallsIn(b.cond);
            try checkCalls(&.{b.then.*});
            if (b.otherwise) |otherwise| try checkCalls(&.{otherwise.*});
        },
        .loop => |l| {
            if (l.init) |init_stmt| try checkCalls(&.{init_stmt.*});
            if (l.cond) |c| try checkCallsIn(c);
            if (l.step) |st| try checkCallsIn(st);
            try checkCalls(&.{l.body.*});
        },
    };
}

fn checkCallsIn(expr: *const Expr) Error!void {
    switch (expr.*) {
        .literal, .ident, .postfix => {},
        .negate, .not => |e| try checkCallsIn(e),
        .swizzle => |sw| try checkCallsIn(sw.e),
        .assign => |a| try checkCallsIn(a.value),
        .binary => |b| {
            try checkCallsIn(b.l);
            try checkCallsIn(b.r);
        },
        .call => |c| {
            if (!known(c.name)) return error.Unsupported;
            for (c.args) |a| try checkCallsIn(a);
        },
    }
}

// ---------------------------------------------------------------------------
// Evaluation

/// A shader that loops longer than this is not one a fingerprint takes, and
/// running it would let a page spend our time rather than its own. The two
/// real loops run 20 and 10 times.
const max_iterations = 1 << 16;

/// Function-scope bindings. Flat and fixed: GLSL has no closures, the shaders
/// declare a handful of locals, and a shader that wants more than this is one
/// we decline to compile rather than one we grow an allocator for.
const Scope = struct {
    names: [32][]const u8 = undefined,
    values: [32]Value = undefined,
    len: usize = 0,

    fn find(self: *Scope, name: []const u8) ?*Value {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.names[i], name)) return &self.values[i];
        }
        return null;
    }

    fn define(self: *Scope, name: []const u8, value: Value) Error!void {
        if (self.find(name)) |slot| {
            slot.* = value;
            return;
        }
        if (self.len == self.names.len) return error.Unsupported;
        self.names[self.len] = name;
        self.values[self.len] = value;
        self.len += 1;
    }
};

/// One run of one stage.
pub const Run = struct {
    scope: Scope = .{},
    steps: usize = 0,

    /// Ceiling on evaluated nodes for a single invocation, so a pathological
    /// shader cannot stall the page it is on.
    const max_steps = 1 << 22;

    pub fn set(self: *Run, name: []const u8, value: Value) Error!void {
        try self.scope.define(name, value);
    }

    pub fn get(self: *Run, name: []const u8) ?Value {
        const slot = self.scope.find(name) orelse return null;
        return slot.*;
    }

    pub fn run(self: *Run, shader: *const Shader) Error!void {
        try self.execAll(shader.body);
    }

    fn execAll(self: *Run, stmts: []const Stmt) Error!void {
        for (stmts) |*s| try self.exec(s);
    }

    fn exec(self: *Run, stmt: *const Stmt) Error!void {
        self.steps += 1;
        if (self.steps > max_steps) return error.Unsupported;

        switch (stmt.*) {
            .block => |b| try self.execAll(b),
            .expr => |e| _ = try self.eval(e),
            .decl => |d| {
                var value: Value = if (d.int) .integer(0) else .float(0);
                if (d.init) |e| {
                    value = try self.eval(e);
                    // `float d = 1;` and `int i = 0;` both need the declared
                    // type to win, or `i / 2` stops truncating.
                    value.int = d.int;
                }
                try self.scope.define(d.name, value);
            },
            .branch => |b| {
                const cond = try self.eval(b.cond);
                if (cond.v[0] != 0) {
                    try self.exec(b.then);
                } else if (b.otherwise) |otherwise| {
                    try self.exec(otherwise);
                }
            },
            .loop => |l| {
                if (l.init) |init_stmt| try self.exec(init_stmt);
                var count: usize = 0;
                while (true) {
                    if (l.cond) |c| {
                        const keep = try self.eval(c);
                        if (keep.v[0] == 0) break;
                    }
                    try self.exec(l.body);
                    if (l.step) |s| _ = try self.eval(s);
                    count += 1;
                    if (count >= max_iterations) return error.Unsupported;
                }
            },
        }
    }

    fn eval(self: *Run, expr: *const Expr) Error!Value {
        self.steps += 1;
        if (self.steps > max_steps) return error.Unsupported;

        switch (expr.*) {
            .literal => |v| return v,
            .ident => |name| return (self.scope.find(name) orelse return error.Unsupported).*,
            .negate => |e| {
                var v = try self.eval(e);
                for (0..v.n) |i| v.v[i] = -v.v[i];
                return v;
            },
            .not => |e| {
                const v = try self.eval(e);
                return .integer(if (v.v[0] == 0) 1 else 0);
            },
            .swizzle => |s| return swizzle(try self.eval(s.e), s.sel),
            .call => |c| {
                var args: [8]Value = undefined;
                if (c.args.len > args.len) return error.Unsupported;
                for (c.args, 0..) |a, i| args[i] = try self.eval(a);
                return builtin(c.name, args[0..c.args.len]);
            },
            .binary => |b| return binary(b.op, try self.eval(b.l), try self.eval(b.r)),
            .assign => |a| {
                var value = try self.eval(a.value);
                const slot = self.scope.find(a.name) orelse {
                    // Writing to `gl_FragColor` in ES 1.0 needs no declaration.
                    try self.scope.define(a.name, value);
                    return value;
                };
                if (a.op) |op| value = try binary(op, slot.*, value);
                value.int = slot.int;
                slot.* = value;
                return value;
            },
            .postfix => |p| {
                const slot = self.scope.find(p.name) orelse return error.Unsupported;
                const before = slot.*;
                slot.v[0] += if (p.inc) 1 else -1;
                return before;
            },
        }
    }
};

fn swizzle(v: Value, sel: []const u8) Error!Value {
    if (sel.len == 0 or sel.len > 4) return error.SyntaxError;
    var out: Value = .{ .n = @intCast(sel.len), .int = v.int };
    for (sel, 0..) |c, i| {
        const index: usize = switch (c) {
            'x', 'r', 's' => 0,
            'y', 'g', 't' => 1,
            'z', 'b', 'p' => 2,
            'w', 'a', 'q' => 3,
            else => return error.SyntaxError,
        };
        if (index >= v.n) return error.SyntaxError;
        out.v[i] = v.v[index];
    }
    return out;
}

/// Component-wise, with a scalar operand broadcast -- which is all GLSL does
/// for these operators once matrices are out of scope.
fn binary(op: Op, l: Value, r: Value) Error!Value {
    const n = @max(l.n, r.n);
    if (l.n != r.n and l.n != 1 and r.n != 1) return error.SyntaxError;

    switch (op) {
        .lt, .gt, .le, .ge, .eq, .ne, .andand, .oror => {
            const a = l.v[0];
            const b = r.v[0];
            const truth = switch (op) {
                .lt => a < b,
                .gt => a > b,
                .le => a <= b,
                .ge => a >= b,
                .eq => a == b,
                .ne => a != b,
                .andand => a != 0 and b != 0,
                .oror => a != 0 or b != 0,
                else => unreachable,
            };
            return .integer(if (truth) 1 else 0);
        },
        else => {},
    }

    // Integer division truncates; float division does not. Getting this the
    // wrong way round would only show up in a shader that indexes with it.
    const int = l.int and r.int;
    var out: Value = .{ .n = n, .int = int };
    for (0..n) |i| {
        const a = l.v[if (l.n == 1) 0 else i];
        const b = r.v[if (r.n == 1) 0 else i];
        out.v[i] = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (int) @trunc(a / b) else a / b,
            else => unreachable,
        };
    }
    return out;
}

/// The transcendentals, at double and rounded once. Chrome's readbacks match
/// this and not a single-precision `sin`; see the file comment.
fn wide(comptime f: fn (f64) f64, x: f32) f32 {
    return @floatCast(f(@as(f64, x)));
}

fn sin64(x: f64) f64 {
    return std.math.sin(x);
}

fn cos64(x: f64) f64 {
    return std.math.cos(x);
}

fn inverseSqrt64(x: f64) f64 {
    return 1.0 / std.math.sqrt(x);
}

fn builtin(name: []const u8, args: []const Value) Error!Value {
    // Constructors. `vec4(v.xy, 0, 1)` flattens its arguments, and a single
    // scalar fills every component.
    if (Parser.typeName(name)) |n| {
        const int = std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "bool");
        if (args.len == 0) return error.SyntaxError;
        var out: Value = .{ .n = n, .int = int };
        if (args.len == 1 and args[0].n == 1) {
            const fill = if (int) @trunc(args[0].v[0]) else args[0].v[0];
            for (0..n) |i| out.v[i] = fill;
            return out;
        }
        var filled: usize = 0;
        for (args) |a| {
            for (0..a.n) |i| {
                if (filled == n) break;
                out.v[filled] = a.v[i];
                filled += 1;
            }
        }
        if (filled != n) return error.SyntaxError;
        return out;
    }

    const one = struct {
        fn apply(comptime f: fn (f32) f32, a: Value) Value {
            var out: Value = .{ .n = a.n };
            for (0..a.n) |i| out.v[i] = f(a.v[i]);
            return out;
        }
    };

    if (args.len == 1) {
        const a = args[0];
        const F = struct {
            fn sin(x: f32) f32 {
                return wide(sin64, x);
            }
            fn cos(x: f32) f32 {
                return wide(cos64, x);
            }
            fn tan(x: f32) f32 {
                return @floatCast(std.math.tan(@as(f64, x)));
            }
            fn exp(x: f32) f32 {
                return @floatCast(std.math.exp(@as(f64, x)));
            }
            fn log(x: f32) f32 {
                return @floatCast(std.math.log(f64, std.math.e, @as(f64, x)));
            }
            fn sqrt(x: f32) f32 {
                return @floatCast(std.math.sqrt(@as(f64, x)));
            }
            fn inversesqrt(x: f32) f32 {
                return wide(inverseSqrt64, x);
            }
            fn abs(x: f32) f32 {
                return @abs(x);
            }
            fn sign(x: f32) f32 {
                return if (x > 0) 1 else if (x < 0) @as(f32, -1) else 0;
            }
            fn floor(x: f32) f32 {
                return @floor(x);
            }
            fn ceil(x: f32) f32 {
                return @ceil(x);
            }
            fn fract(x: f32) f32 {
                return x - @floor(x);
            }
        };
        if (std.mem.eql(u8, name, "sin")) return one.apply(F.sin, a);
        if (std.mem.eql(u8, name, "cos")) return one.apply(F.cos, a);
        if (std.mem.eql(u8, name, "tan")) return one.apply(F.tan, a);
        if (std.mem.eql(u8, name, "exp")) return one.apply(F.exp, a);
        if (std.mem.eql(u8, name, "log")) return one.apply(F.log, a);
        if (std.mem.eql(u8, name, "sqrt")) return one.apply(F.sqrt, a);
        if (std.mem.eql(u8, name, "inversesqrt")) return one.apply(F.inversesqrt, a);
        if (std.mem.eql(u8, name, "abs")) return one.apply(F.abs, a);
        if (std.mem.eql(u8, name, "sign")) return one.apply(F.sign, a);
        if (std.mem.eql(u8, name, "floor")) return one.apply(F.floor, a);
        if (std.mem.eql(u8, name, "ceil")) return one.apply(F.ceil, a);
        if (std.mem.eql(u8, name, "fract")) return one.apply(F.fract, a);
        if (std.mem.eql(u8, name, "length")) {
            var sum: f64 = 0;
            for (0..a.n) |i| sum += @as(f64, a.v[i]) * @as(f64, a.v[i]);
            return .float(@floatCast(std.math.sqrt(sum)));
        }
    }

    if (args.len == 2) {
        const a = args[0];
        const b = args[1];
        if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max") or
            std.mem.eql(u8, name, "mod") or std.mem.eql(u8, name, "pow") or
            std.mem.eql(u8, name, "step"))
        {
            const n = @max(a.n, b.n);
            var out: Value = .{ .n = n };
            for (0..n) |i| {
                const x = a.v[if (a.n == 1) 0 else i];
                const y = b.v[if (b.n == 1) 0 else i];
                out.v[i] = if (std.mem.eql(u8, name, "min"))
                    @min(x, y)
                else if (std.mem.eql(u8, name, "max"))
                    @max(x, y)
                else if (std.mem.eql(u8, name, "mod"))
                    x - y * @floor(x / y)
                else if (std.mem.eql(u8, name, "pow"))
                    @as(f32, @floatCast(std.math.pow(f64, @as(f64, x), @as(f64, y))))
                else if (x < y) 0 else 1;
            }
            return out;
        }
        if (std.mem.eql(u8, name, "dot")) {
            var sum: f32 = 0;
            for (0..@max(a.n, b.n)) |i| sum += a.v[i] * b.v[i];
            return .float(sum);
        }
    }

    if (args.len == 3 and std.mem.eql(u8, name, "clamp")) {
        const a = args[0];
        var out: Value = .{ .n = a.n };
        for (0..a.n) |i| {
            out.v[i] = @min(@max(a.v[i], args[1].v[if (args[1].n == 1) 0 else i]), args[2].v[if (args[2].n == 1) 0 else i]);
        }
        return out;
    }

    if (args.len == 3 and std.mem.eql(u8, name, "mix")) {
        const a = args[0];
        var out: Value = .{ .n = a.n };
        for (0..a.n) |i| {
            const t = args[2].v[if (args[2].n == 1) 0 else i];
            out.v[i] = a.v[i] * (1 - t) + args[1].v[i] * t;
        }
        return out;
    }

    // An unknown call is a shader we cannot answer for, which the caller turns
    // into a compile failure rather than a colour.
    return error.Unsupported;
}

const testing = std.testing;

test "glsl: the widget's constant fragment shader" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const shader = try compile(
        arena.allocator(),
        "precision mediump float;void main(){gl_FragColor=vec4(sin(1.0),cos(1.0),sin(1.0)*cos(1.0),1.0);}",
    );

    var run: Run = .{};
    try run.run(&shader);
    const out = run.get("gl_FragColor").?;

    try testing.expectEqual(@as(u8, 4), out.n);
    // The bytes Chrome reads back, which is what the quantised components have
    // to come to: d7 8a 74 ff.
    try testing.expectEqual(@as(u8, 0xd7), quantise(out.v[0]));
    try testing.expectEqual(@as(u8, 0x8a), quantise(out.v[1]));
    try testing.expectEqual(@as(u8, 0x74), quantise(out.v[2]));
    try testing.expectEqual(@as(u8, 0xff), quantise(out.v[3]));
}

test "glsl: the widget's per-pixel fragment shader" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const shader = try compile(arena.allocator(),
        \\precision highp float;
        \\void main() {
        \\  float a = gl_FragCoord.x;
        \\  float b = 1.0;
        \\  for (int i = 0; i < 20; i++) { b = b * 1.1 + 0.001; }
        \\  float c = sin(cos(sin(cos(a * 0.1))));
        \\  float d = 1.0;
        \\  for (int i = 0; i < 10; i++) { d = inversesqrt(d + 0.01); }
        \\  float e = fract(a * 12345.6789);
        \\  gl_FragColor = vec4(
        \\    fract(b * 0.5 + 0.5),
        \\    fract(c * 0.5 + 0.5),
        \\    fract(d * 0.5 + 0.5),
        \\    fract(e)
        \\  );
        \\}
    );

    // The 4x1 readback, byte for byte off Chrome 151.
    const want: [4][4]u8 = .{
        .{ 0xe4, 0xce, 0xff, 0xd6 },
        .{ 0xe4, 0xcf, 0xff, 0x84 },
        .{ 0xe4, 0xd0, 0xff, 0x32 },
        .{ 0xe4, 0xd1, 0xff, 0xdf },
    };
    for (want, 0..) |expected, pixel| {
        var run: Run = .{};
        try run.set("gl_FragCoord", .vec4(@as(f32, @floatFromInt(pixel)) + 0.5, 0.5, 0, 1));
        try run.run(&shader);
        const out = run.get("gl_FragColor").?;
        for (expected, 0..) |byte, i| {
            try testing.expectEqual(byte, quantise(out.v[i]));
        }
    }
}

test "glsl: a source that is not GLSL does not compile" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `this` reads as a type name and `is` as the thing being declared, so
    // this one dies on the type rather than on the grammar. Both are compile
    // failures to the caller; the distinction is only interesting here.
    try testing.expectError(error.Unsupported, compile(arena.allocator(), "this is not glsl"));
    try testing.expectError(error.SyntaxError, compile(arena.allocator(), "void main() { gl_FragColor = ; }"));
    // No `main` at all is not a shader either.
    try testing.expectError(error.SyntaxError, compile(arena.allocator(), "float x = 1.0;"));
    // A second function is one we decline rather than half-run.
    try testing.expectError(error.Unsupported, compile(arena.allocator(), "void other(){} void main(){}"));
    // A builtin we do not have is refused at compile time, not left to fail
    // once a fragment runs -- a shader reported as compiled that then draws
    // nothing is worse than one reported as failed.
    try testing.expectError(error.Unsupported, compile(arena.allocator(), "void main(){gl_FragColor=texture2D(s, vec2(0.0));}"));
    try testing.expectError(error.Unsupported, compile(arena.allocator(), "void main(){float x=1.0;for(int i=0;i<2;i++){x=dFdx(x);}gl_FragColor=vec4(x);}"));
}

test "glsl: the widget's vertex shader positions its quad" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const shader = try compile(arena.allocator(), "attribute vec2 p;void main(){gl_Position=vec4(p,0,1);}");
    try testing.expectEqual(@as(usize, 1), shader.attributes.len);
    try testing.expectEqualStrings("p", shader.attributes[0].name);
    // Chrome reports FLOAT_VEC2 for this one through getActiveAttrib, so the
    // declared width has to survive compilation.
    try testing.expectEqual(@as(u8, 2), shader.attributes[0].components);

    var run: Run = .{};
    try run.set("p", .{ .n = 2, .v = .{ -1, 1, 0, 0 } });
    try run.run(&shader);
    const out = run.get("gl_Position").?;
    try testing.expectEqual(@as(f32, -1), out.v[0]);
    try testing.expectEqual(@as(f32, 1), out.v[1]);
    try testing.expectEqual(@as(f32, 0), out.v[2]);
    try testing.expectEqual(@as(f32, 1), out.v[3]);
}

/// RGBA8 conversion: clamp to [0,1] and round to nearest, which is what the
/// framebuffer does to a shader's output.
pub fn quantise(x: f32) u8 {
    if (!(x > 0)) return 0; // also catches NaN
    if (x >= 1) return 255;
    return @intFromFloat(@round(x * 255));
}
