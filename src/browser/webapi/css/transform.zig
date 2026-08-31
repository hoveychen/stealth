// The computed value of `transform`, which is never the list the author wrote.
//
// A browser folds the whole list into one matrix: `translateX(3px)` computes to
// `matrix(1, 0, 0, 1, 3, 0)` and `rotate(45deg)` to
// `matrix(0.707107, 0.707107, -0.707107, 0.707107, 0, 0)`. Answering the
// author's text instead is a spelling Chrome never prints, which is the same
// reason an unresolved `2em` is not reported either.
//
// Every reading below is from Chrome 151, tools/fingerprint/scratch/
// expr-transform-matrix.js, over the thirty-eight forms this file parses.
//
// Two conventions decide the whole file:
//
//   * The list composes left to right, so the result is M1 × M2 × … . Measured:
//     `rotate(45deg) translateX(3px)` answers a translation of 2.12132 on both
//     axes -- the 3px turned by the rotation -- while `translateX(3px)
//     rotate(45deg)` keeps its 3, 0.
//   * A list that mentions no third dimension answers `matrix()` with the six
//     2D components; one that does answers `matrix3d()` with all sixteen in
//     column-major order. `rotateZ` is 2D by that rule and measured as such.
const std = @import("std");

const calc = @import("calc.zig");
const units = @import("../../css/units.zig");

const Allocator = std.mem.Allocator;

/// What a percentage inside a transform function resolves against: the
/// element's own BORDER box. Attributed rather than assumed -- on a 100x50 <p>,
/// `translate(50%, 50%)` answers 50,25 in Chrome, `padding:10px` moves it to
/// 60,35, `border:5px` to 55,30, and `box-sizing:border-box` puts it back at
/// 50,25 (scratch/b74/expr-test-shape-percent.js).
///
/// `zero` is the basis of a box that has no reference box of its own -- a
/// non-replaced inline element -- where every percentage resolves to nothing
/// while the lengths beside it still translate. An element with no box at all
/// never gets here: `transform` computes to `none` there, percentage or not.
pub const Basis = struct {
    width: f64,
    height: f64,
    /// CSS pixels per unit for the lengths that need the element or the
    /// viewport before they mean anything. Null for a unit the caller could
    /// not resolve, which refuses that argument exactly as before -- so a
    /// caller that fills none of them keeps the old behaviour.
    ///
    /// The absolute units are deliberately absent: `units.absoluteLengthFactor`
    /// answers those with no context at all, so asking the caller for them
    /// would be asking it to pass through a constant.
    factors: Factors = .{},

    pub const zero: Basis = .{ .width = 0, .height = 0 };
};

pub const Factors = struct {
    em: ?f64 = null,
    rem: ?f64 = null,
    ex: ?f64 = null,
    ch: ?f64 = null,
    vh: ?f64 = null,
    vw: ?f64 = null,
    vmin: ?f64 = null,
    vmax: ?f64 = null,

    fn of(self: Factors, unit: units.Unit) ?f64 {
        return switch (unit) {
            .em => self.em,
            .rem => self.rem,
            .ex => self.ex,
            .ch => self.ch,
            .vh => self.vh,
            .vw => self.vw,
            .vmin => self.vmin,
            .vmax => self.vmax,
            else => null,
        };
    }
};

/// What one argument's percentage is a percentage OF. `refused` is a percentage
/// the grammar does not allow at all, which takes the whole declaration with it
/// -- measured on both engines for `translateZ(50%)`, `rotate(50%)`,
/// `skewX(50%)` and `perspective(50%)`.
const Percent = enum { refused, width, height, number };

/// Which extent a percentage in argument `index` of `name` resolves against.
fn percentBasis(name: []const u8, index: usize) Percent {
    if (eq(name, "translate") or eq(name, "translate3d")) {
        return switch (index) {
            0 => .width,
            1 => .height,
            // translate3d's third argument is a z offset, and z has no extent.
            else => .refused,
        };
    }
    if (eq(name, "translatex")) return if (index == 0) .width else .refused;
    if (eq(name, "translatey")) return if (index == 0) .height else .refused;
    // A scale is a ratio, so its percentage is just the number over a hundred
    // and needs no box: `scale(50%)` is `matrix(0.5, 0, 0, 0.5, 0, 0)` on an
    // element of any size.
    if (eq(name, "scale") or eq(name, "scalex") or eq(name, "scaley") or
        eq(name, "scalez") or eq(name, "scale3d")) return .number;
    return .refused;
}

/// Column-major, the order `matrix3d()` lists: m[column][row].
const Matrix = struct {
    m: [4][4]f64,

    const identity: Matrix = .{ .m = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    fn multiply(a: Matrix, b: Matrix) Matrix {
        var out: Matrix = .{ .m = @splat(@splat(0)) };
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f64 = 0;
                for (0..4) |k| {
                    sum += a.m[k][row] * b.m[col][k];
                }
                out.m[col][row] = sum;
            }
        }
        return out;
    }
};

/// The `matrix()` or `matrix3d()` a computed style reports for `value`, or null
/// when the list holds something this file does not model -- in which case the
/// caller reports the initial value rather than inventing one.
///
/// `none` answers `none`, which is what Chrome answers and what an element with
/// no transform reads anyway.
pub fn computedValue(arena: Allocator, value: []const u8, basis: Basis) !?[]const u8 {
    var it = ListIterator.init(value, basis) orelse return null;
    if (it.is_none) return "none";

    var matrix: Matrix = .identity;
    var three_d = false;
    var seen = false;

    while (true) {
        switch (it.next()) {
            .done => break,
            .refused => return null,
            .function => |f| {
                const parsed = matrixFor(f.name, f.scalars()) orelse return null;
                matrix = matrix.multiply(parsed.matrix);
                three_d = three_d or parsed.three_d;
                seen = true;
            },
        }
    }

    if (!seen) return null;
    return try write(arena, matrix, three_d);
}

/// The matrix `from` folds to when it has travelled `fraction` of the way to
/// `to`, or null when the pair is one this file will not interpolate -- the
/// caller then reports an endpoint rather than a value Chrome never shows.
///
/// Chrome interpolates a transform FUNCTION BY FUNCTION when the two lists have
/// the same shape: `rotate(0deg)` to `rotate(90deg)` at the halfway point is
/// `rotate(45deg)`, not the average of the two matrices. Only that case is
/// modelled. Lists of different shapes -- `rotate(…)` against `scale(…)`, or
/// `scale(2)` against `scale(2, 3)`, which are the same transform written two
/// ways but not the same shape -- fall to matrix decomposition in Chrome, which
/// this refuses instead.
///
/// `none` on one side is not a shape mismatch: it stands for the other side's
/// functions holding their neutral values, so `none` to `rotate(90deg)` is a
/// rotation from zero. The one exception is a `matrix`, `matrix3d` or
/// `perspective` opposite a `none`, which has no such neutral form here.
pub fn interpolatedValue(arena: Allocator, from: []const u8, to: []const u8, fraction: f64, basis: Basis) !?[]const u8 {
    var start: [MAX_FUNCTIONS]Function = undefined;
    var end: [MAX_FUNCTIONS]Function = undefined;

    const start_count = collect(from, &start, basis) orelse return null;
    const end_count = collect(to, &end, basis) orelse return null;

    if (start_count == 0 and end_count == 0) return "none";
    if (start_count == 0) {
        if (!neutralise(end[0..end_count], &start)) return null;
        return try foldPair(arena, start[0..end_count], end[0..end_count], fraction);
    }
    if (end_count == 0) {
        if (!neutralise(start[0..start_count], &end)) return null;
        return try foldPair(arena, start[0..start_count], end[0..start_count], fraction);
    }
    if (start_count != end_count) return null;
    return try foldPair(arena, start[0..start_count], end[0..end_count], fraction);
}

/// Interpolate two lists already known to be the same length, then fold the
/// result. Null when the two disagree on a function or on its arity.
fn foldPair(arena: Allocator, from: []const Function, to: []const Function, fraction: f64) !?[]const u8 {
    var matrix: Matrix = .identity;
    var three_d = false;

    for (from, to) |a, b| {
        if (!std.ascii.eqlIgnoreCase(a.name, b.name)) return null;
        if (a.count != b.count) return null;

        var lerped: [MAX_ARGS]f64 = undefined;
        for (a.scalars(), b.scalars(), lerped[0..a.count]) |x, y, *out| {
            out.* = x + (y - x) * fraction;
        }

        const parsed = matrixFor(a.name, lerped[0..a.count]) orelse return null;
        matrix = matrix.multiply(parsed.matrix);
        three_d = three_d or parsed.three_d;
    }

    return try write(arena, matrix, three_d);
}

/// The list a `none` stands for when it is interpolated against `functions`:
/// the same functions holding the values that leave the element where it was.
/// False when one of them has no such value here.
fn neutralise(functions: []const Function, out: *[MAX_FUNCTIONS]Function) bool {
    for (functions, out[0..functions.len]) |f, *slot| {
        slot.* = f;
        if (eq(f.name, "translate") or eq(f.name, "translatex") or eq(f.name, "translatey") or
            eq(f.name, "translatez") or eq(f.name, "translate3d") or
            eq(f.name, "rotate") or eq(f.name, "rotatex") or eq(f.name, "rotatey") or
            eq(f.name, "rotatez") or eq(f.name, "skew") or eq(f.name, "skewx") or eq(f.name, "skewy"))
        {
            slot.args = @splat(0);
        } else if (eq(f.name, "scale") or eq(f.name, "scalex") or eq(f.name, "scaley") or
            eq(f.name, "scalez") or eq(f.name, "scale3d"))
        {
            slot.args = @splat(1);
        } else if (eq(f.name, "rotate3d")) {
            // The axis stays; only the angle goes to zero. Interpolating the
            // axis towards a made-up one would rotate about the wrong line.
            if (f.count != 4) return false;
            slot.args[3] = 0;
        } else {
            // `matrix`, `matrix3d` and `perspective`: no neutral argument list
            // stands for `none` here.
            return false;
        }
    }
    return true;
}

/// The most functions a list may hold before interpolation gives up on it.
/// Only interpolation is capped: `computedValue` streams the list and folds
/// any length, so a page writing more than this still reads a matrix back --
/// it just does not get an interpolated one.
const MAX_FUNCTIONS = 32;

/// A whole `<transform-list>` into `out`, answering how many functions it held.
/// `none` is zero of them. Null for a list this file does not model, or one
/// longer than `out`.
fn collect(value: []const u8, out: *[MAX_FUNCTIONS]Function, basis: Basis) ?usize {
    var it = ListIterator.init(value, basis) orelse return null;
    if (it.is_none) return 0;

    var count: usize = 0;
    while (true) {
        switch (it.next()) {
            .done => break,
            .refused => return null,
            .function => |f| {
                if (count == out.len) return null;
                if (matrixFor(f.name, f.scalars()) == null) return null;
                out[count] = f;
                count += 1;
            },
        }
    }
    if (count == 0) return null;
    return count;
}

/// Walks a `<transform-list>` one function at a time. The arguments are parsed
/// here but not folded, so both the reader that wants a matrix and the one that
/// wants to interpolate read the list the same way.
const ListIterator = struct {
    text: []const u8,
    basis: Basis,
    i: usize = 0,
    is_none: bool = false,

    const Item = union(enum) { function: Function, done, refused };

    /// Null when there is no list at all -- an empty value, which is not the
    /// same as `none`.
    fn init(value: []const u8, basis: Basis) ?ListIterator {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;
        return .{ .text = trimmed, .basis = basis, .is_none = std.ascii.eqlIgnoreCase(trimmed, "none") };
    }

    fn next(self: *ListIterator) Item {
        const text = self.text;
        while (self.i < text.len and std.ascii.isWhitespace(text[self.i])) : (self.i += 1) {}
        if (self.i >= text.len) return .done;

        const name_start = self.i;
        while (self.i < text.len and (std.ascii.isAlphanumeric(text[self.i]) or text[self.i] == '-')) : (self.i += 1) {}
        if (self.i >= text.len or text[self.i] != '(') return .refused;
        const name = text[name_start..self.i];

        // The MATCHING paren, not the first one. A math-function argument brings
        // parens of its own, so `translateX(calc(10px + 5px))` cut at the first
        // `)` left an unbalanced `calc(10px + 5px` that nothing could parse.
        const close = matchingParen(text, self.i) orelse return .refused;
        var args: [MAX_ARGS]f64 = undefined;
        const count = parseArgs(name, text[self.i + 1 .. close], &args, self.basis) orelse return .refused;
        self.i = close + 1;

        return .{ .function = .{ .name = name, .args = args, .count = count } };
    }
};

const Parsed = struct {
    matrix: Matrix,
    three_d: bool,
};

/// The most arguments any transform function takes: `matrix3d`'s sixteen.
const MAX_ARGS = 16;

/// One function of a `<transform-list>`, kept as the numbers the matrix wants
/// rather than as a matrix. Interpolation happens between these -- Chrome
/// interpolates a rotation's angle, not the matrix it folds to -- so the
/// scalars have to survive the parse.
const Function = struct {
    name: []const u8,
    args: [MAX_ARGS]f64,
    count: usize,

    fn scalars(self: *const Function) []const f64 {
        return self.args[0..self.count];
    }
};

/// The index of the `)` matching the `(` at `open`.
fn matchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The comma-separated arguments as the numbers the matrix wants, answering
/// how many there were. Null for an argument this file does not model, which
/// takes the whole declaration with it.
///
/// The split is at depth zero: `min(1px, 1em)` is one argument with a comma in
/// it, and splitting on every comma made it two arguments neither of which
/// parses.
fn parseArgs(name: []const u8, args: []const u8, out: *[MAX_ARGS]f64, basis: Basis) ?usize {
    var count: usize = 0;
    var depth: usize = 0;
    var start: usize = 0;
    for (args, 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                if (!takeArg(name, args[start..i], out, &count, basis)) return null;
                start = i + 1;
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    if (!takeArg(name, args[start..], out, &count, basis)) return null;
    return count;
}

fn takeArg(name: []const u8, raw: []const u8, out: *[MAX_ARGS]f64, count: *usize, basis: Basis) bool {
    if (count.* == out.len) return false;
    const arg = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (arg.len == 0) return false;
    out[count.*] = parseScalar(arg, scalarType(name, count.*), percentBasis(name, count.*), basis) orelse return false;
    count.* += 1;
    return true;
}

fn matrixFor(name: []const u8, n: []const f64) ?Parsed {
    var m: Matrix = .identity;

    // The names are compared case-insensitively because a declaration keeps the
    // author's spelling and `TranslateX(3px)` is the same function.
    if (eq(name, "matrix")) {
        if (n.len != 6) return null;
        m.m[0][0] = n[0];
        m.m[0][1] = n[1];
        m.m[1][0] = n[2];
        m.m[1][1] = n[3];
        m.m[3][0] = n[4];
        m.m[3][1] = n[5];
        return .{ .matrix = m, .three_d = false };
    }
    if (eq(name, "matrix3d")) {
        if (n.len != 16) return null;
        for (0..4) |col| {
            for (0..4) |row| {
                m.m[col][row] = n[col * 4 + row];
            }
        }
        return .{ .matrix = m, .three_d = true };
    }
    if (eq(name, "translate") or eq(name, "translatex") or eq(name, "translatey") or
        eq(name, "translatez") or eq(name, "translate3d"))
    {
        var tx: f64 = 0;
        var ty: f64 = 0;
        var tz: f64 = 0;
        if (eq(name, "translate")) {
            if (n.len < 1 or n.len > 2) return null;
            tx = n[0];
            ty = if (n.len == 2) n[1] else 0;
        } else if (eq(name, "translatex")) {
            if (n.len != 1) return null;
            tx = n[0];
        } else if (eq(name, "translatey")) {
            if (n.len != 1) return null;
            ty = n[0];
        } else if (eq(name, "translatez")) {
            if (n.len != 1) return null;
            tz = n[0];
        } else {
            if (n.len != 3) return null;
            tx = n[0];
            ty = n[1];
            tz = n[2];
        }
        m.m[3][0] = tx;
        m.m[3][1] = ty;
        m.m[3][2] = tz;
        return .{ .matrix = m, .three_d = eq(name, "translatez") or eq(name, "translate3d") };
    }
    if (eq(name, "scale") or eq(name, "scalex") or eq(name, "scaley") or
        eq(name, "scalez") or eq(name, "scale3d"))
    {
        var sx: f64 = 1;
        var sy: f64 = 1;
        var sz: f64 = 1;
        if (eq(name, "scale")) {
            if (n.len < 1 or n.len > 2) return null;
            sx = n[0];
            sy = if (n.len == 2) n[1] else n[0];
        } else if (eq(name, "scalex")) {
            if (n.len != 1) return null;
            sx = n[0];
        } else if (eq(name, "scaley")) {
            if (n.len != 1) return null;
            sy = n[0];
        } else if (eq(name, "scalez")) {
            if (n.len != 1) return null;
            sz = n[0];
        } else {
            if (n.len != 3) return null;
            sx = n[0];
            sy = n[1];
            sz = n[2];
        }
        m.m[0][0] = sx;
        m.m[1][1] = sy;
        m.m[2][2] = sz;
        return .{ .matrix = m, .three_d = eq(name, "scalez") or eq(name, "scale3d") };
    }
    if (eq(name, "rotate") or eq(name, "rotatez")) {
        if (n.len != 1) return null;
        const c = cosine(n[0]);
        const s = sine(n[0]);
        m.m[0][0] = c;
        m.m[0][1] = s;
        m.m[1][0] = -s;
        m.m[1][1] = c;
        return .{ .matrix = m, .three_d = false };
    }
    if (eq(name, "rotatex")) {
        if (n.len != 1) return null;
        const c = cosine(n[0]);
        const s = sine(n[0]);
        m.m[1][1] = c;
        m.m[1][2] = s;
        m.m[2][1] = -s;
        m.m[2][2] = c;
        return .{ .matrix = m, .three_d = true };
    }
    if (eq(name, "rotatey")) {
        if (n.len != 1) return null;
        const c = cosine(n[0]);
        const s = sine(n[0]);
        m.m[0][0] = c;
        m.m[0][2] = -s;
        m.m[2][0] = s;
        m.m[2][2] = c;
        return .{ .matrix = m, .three_d = true };
    }
    if (eq(name, "rotate3d")) {
        if (n.len != 4) return null;
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (len == 0) return null;
        const x = n[0] / len;
        const y = n[1] / len;
        const z = n[2] / len;
        const c = cosine(n[3]);
        const s = sine(n[3]);
        const t = 1 - c;
        m.m[0][0] = t * x * x + c;
        m.m[0][1] = t * x * y + s * z;
        m.m[0][2] = t * x * z - s * y;
        m.m[1][0] = t * x * y - s * z;
        m.m[1][1] = t * y * y + c;
        m.m[1][2] = t * y * z + s * x;
        m.m[2][0] = t * x * z + s * y;
        m.m[2][1] = t * y * z - s * x;
        m.m[2][2] = t * z * z + c;
        return .{ .matrix = m, .three_d = true };
    }
    if (eq(name, "skew") or eq(name, "skewx") or eq(name, "skewy")) {
        var ax: f64 = 0;
        var ay: f64 = 0;
        if (eq(name, "skew")) {
            if (n.len < 1 or n.len > 2) return null;
            ax = n[0];
            ay = if (n.len == 2) n[1] else 0;
        } else if (eq(name, "skewx")) {
            if (n.len != 1) return null;
            ax = n[0];
        } else {
            if (n.len != 1) return null;
            ay = n[0];
        }
        m.m[1][0] = @tan(ax);
        m.m[0][1] = @tan(ay);
        return .{ .matrix = m, .three_d = false };
    }
    if (eq(name, "perspective")) {
        if (n.len != 1 or n[0] == 0) return null;
        m.m[2][3] = -1 / n[0];
        return .{ .matrix = m, .three_d = true };
    }
    return null;
}

fn eq(a: []const u8, comptime b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// One argument as the number the matrix wants: an angle becomes radians, a
/// length its pixel count, a bare number itself, and a percentage whatever
/// `basis` says it is a percentage of. A unit this does not know -- `em` -- and
/// a percentage in a slot whose grammar has none answer null and take the whole
/// declaration with them, which is the same refusal `resolvesHere` makes for
/// every other property.
/// The digits a DIMENSION keeps: at most seven after the decimal point, as
/// WRITTEN. A slice of the input, so nothing is allocated and nothing is
/// re-printed.
///
/// This is a rule about the text and not about the value, which is what the
/// measurements say and what a numeric truncation could not reproduce:
/// `rotate(1e-9rad)` keeps its `1e-09` while `rotate(0.000000001rad)` -- the
/// same double -- comes out `0`. So an exponent form is exempt, because it has
/// no decimal digits to cut.
///
/// Measured on Chrome 151, scratch/b75/expr-number-retention.js,
/// expr-truncation-boundary.js and expr-token-kinds.js, read through cos and
/// through a translation because those turn a dropped digit into a printable
/// difference:
///
///   * the cut is at the seventh decimal -- pi/2 in radians written to 6dp gives
///     `3.26795e-07`, to 7dp `2.67949e-08`, and to 8, 9, 12 and 17dp the same
///     answer as 7dp; `0.00000012px` and `0.0000001234px` are both `1e-07` and
///     `0.000000001px` is `0`;
///   * it truncates, it does not round -- `89.99999985deg` and `89.99999989deg`
///     both give `3.49066e-09`, which is `89.9999998`; rounding would have given
///     the `1.74533e-09` that `89.99999995deg` gives;
///   * decimal places and not significant digits -- `36089.9999999deg` keeps its
///     seventh decimal, which is twelve significant digits;
///   * a DIMENSION and nothing else. A bare `<number>` keeps everything
///     (`scale(0.000000001)` is `1e-09` where `translateX(0.000000001px)` is
///     `0`), and so does a `<percentage>` (`translateX(0.000123456789%)` on a
///     100px box is `0.000123457`, not the `0.0001234` the same digits in `px`
///     give).
///
/// Applied before any unit conversion, because the cut is in the written unit:
/// `89.9999999deg` keeps its seventh DEGREE decimal, which is nothing like a
/// seventh decimal of the radians it becomes.
///
/// It is also what keeps the exact-right-angle path honest, in both directions.
/// `rotate(90deg)` keeps its 90 and `quarterTurns` still sees a right angle;
/// `rotate(1.5707963267948966rad)` becomes `1.5707963`, which is NOT one, and
/// Chrome answers `2.67949e-08` for it. Write the same angle with an exponent
/// and nothing is cut -- `rotate(1.5707963267948966e0rad)` is an exact
/// `matrix(0, 1, -1, 0, 0, 0)` in Chrome, and this keeps it one here.
fn dimensionDigits(text: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return text;
    for (text[dot + 1 ..]) |c| {
        if (c == 'e' or c == 'E') return text;
    }
    const decimals = text.len - dot - 1;
    if (decimals <= 7) return text;
    return text[0 .. dot + 1 + 7];
}

/// Whether the token is a `calc()` call rather than a plain value.
fn isCalcCall(arg: []const u8) bool {
    const trimmed = std.mem.trim(u8, arg, &std.ascii.whitespace);
    if (trimmed.len < 6 or trimmed[trimmed.len - 1] != ')') return false;
    return std.ascii.eqlIgnoreCase(trimmed[0..5], "calc(");
}

/// One length token as a number and a unit, or null when it is not one. The
/// units this file already handles by hand -- `px`, the four angles, a bare
/// number -- are declined here so the branches above keep their measured
/// digit-for-digit behaviour (see `dimensionDigits`).
fn lengthUnit(arg: []const u8) ?units.Parsed {
    const parsed = units.parse(arg) catch return null;
    return switch (parsed.unit) {
        .none, .percentage, .px, .deg, .rad, .grad, .turn => null,
        else => parsed,
    };
}

/// A length in CSS pixels, or null when this engine cannot resolve that unit
/// here.
fn pixelsOf(value: f64, unit: units.Unit, basis: Basis) ?f64 {
    if (units.absoluteLengthFactor(unit)) |factor| return value * factor;
    const factor = basis.factors.of(unit) orelse return null;
    return value * factor;
}

/// A `calc()` or comparison argument, resolved to the number the surrounding
/// function wants.
///
/// The fold gives one term per unit, so this is the same sum the declaration
/// path does: absolute lengths are already px by then, the rest go through the
/// basis, an angle folds in radians the way the bare angles above do, and a
/// percentage takes whichever extent this argument's slot resolves against.
/// Null for anything with a term it cannot finish, which refuses the argument
/// and, as before, the whole declaration with it.
fn mathScalar(arg: []const u8, kind: Scalar, percent: Percent, basis: Basis) ?f64 {
    // A comparison is resolved from its parts rather than folded, which is what
    // keeps this allocation-free: `calc.foldBodyIn` would have to write the
    // function's text somewhere, and there is nothing to write it into here.
    if (calc.callOf(arg)) |call| {
        var pixels: [8]f64 = undefined;
        for (0..call.len) |i| {
            pixels[i] = mathScalar(call.arg(i), kind, percent, basis) orelse
                parseScalar(call.arg(i), kind, percent, basis) orelse return null;
        }
        if (call.len == 0) return null;
        return switch (call.kind) {
            .min => blk: {
                var m = pixels[0];
                for (pixels[1..call.len]) |v| m = @min(m, v);
                break :blk m;
            },
            .max => blk: {
                var m = pixels[0];
                for (pixels[1..call.len]) |v| m = @max(m, v);
                break :blk m;
            },
            .clamp => if (call.len == 3) @max(pixels[0], @min(pixels[1], pixels[2])) else null,
        };
    }

    // Only an actual `calc()`. Without this the fold would also swallow a plain
    // `10px`, and the branches below it keep every digit the author wrote --
    // which is measured behaviour this must not walk over.
    if (!isCalcCall(arg)) return null;
    const folded = calc.foldBody(arg) catch return null;
    if (folded.fn_len != 0) return null;
    var total: f64 = 0;
    for (folded.terms[0..folded.len]) |term| {
        total += switch (term.unit) {
            .px => if (kind == .length) term.value else return null,
            // A bare number is the whole answer in a number slot and not a
            // length anywhere else.
            .none => if (kind == .number) term.value else return null,
            .percentage => switch (percent) {
                .refused => return null,
                .width => term.value / 100 * basis.width,
                .height => term.value / 100 * basis.height,
                .number => term.value / 100,
            },
            .deg, .grad, .turn, .rad => if (kind == .angle) switch (term.unit) {
                .deg => term.value * std.math.pi / 180.0,
                .grad => term.value * std.math.pi / 200.0,
                .turn => term.value * 2 * std.math.pi,
                else => term.value,
            } else return null,
            else => if (kind == .length)
                pixelsOf(term.value, term.unit, basis) orelse return null
            else
                return null,
        };
    }
    return total;
}

/// What kind of value an argument slot takes, which nothing here used to ask.
///
/// `parseScalar` accepted `px` for every function, so `matrix(1, 0, 0, 1, 10px,
/// 0)`, `scale(2px)`, `rotate(45px)`, `rotate(45)`, `translateX(45)`,
/// `skewX(10px)` and `perspective(100)` were all stored where Chrome drops the
/// declaration -- eight of thirteen measured rows wrong before any of this, and
/// widening the accepted lengths would have made it nine.
///
/// Read off Chrome 151 by putting one token of each type in each slot of each
/// function and seeing which survive (scratch/b98/expr-b98-transform-slot-types.js
/// and expr-b98-rotate3d.js). Five groups came out, and they are these.
const Scalar = enum { number, length, angle };

fn scalarType(name: []const u8, index: usize) Scalar {
    if (eq(name, "matrix") or eq(name, "matrix3d")) return .number;
    if (eq(name, "rotate3d")) return if (index == 3) .angle else .number;
    if (std.ascii.startsWithIgnoreCase(name, "rotate") or
        std.ascii.startsWithIgnoreCase(name, "skew")) return .angle;
    if (std.ascii.startsWithIgnoreCase(name, "scale")) return .number;
    // What is left is the translate family and `perspective`, which take a
    // length. Whether a percentage comes with it is `percentBasis`'s question,
    // and the two disagree on purpose: `translateZ` is a length that refuses
    // one.
    return .length;
}

fn parseScalar(arg: []const u8, kind: Scalar, percent: Percent, basis: Basis) ?f64 {
    // A math function is resolved before anything else looks at the token: its
    // answer is a length, an angle or a number like any other argument, and
    // every one of its terms goes through the same table the bare units below
    // do. This is why `translateX(calc(1px + 1em))` works exactly as far as
    // `translateX(1em)` does and no further.
    if (mathScalar(arg, kind, percent, basis)) |value| return value;

    if (arg.len > 1 and arg[arg.len - 1] == '%') {
        // A percentage is not a dimension and keeps every digit -- measured, see
        // dimensionDigits.
        const number = std.fmt.parseFloat(f64, arg[0 .. arg.len - 1]) catch return null;
        return switch (percent) {
            .refused => null,
            .width => number / 100 * basis.width,
            .height => number / 100 * basis.height,
            .number => number / 100,
        };
    }

    const Suffix = struct { []const u8, f64 };
    const angles = [_]Suffix{
        .{ "deg", std.math.pi / 180.0 },
        .{ "grad", std.math.pi / 200.0 },
        .{ "turn", 2 * std.math.pi },
        .{ "rad", 1 },
    };
    for (angles) |suffix| {
        if (kind != .angle) break;
        if (arg.len > suffix[0].len and std.ascii.endsWithIgnoreCase(arg, suffix[0])) {
            const digits = dimensionDigits(arg[0 .. arg.len - suffix[0].len]);
            const number = std.fmt.parseFloat(f64, digits) catch return null;
            return number * suffix[1];
        }
    }
    if (kind == .length) {
        if (arg.len > 2 and std.ascii.endsWithIgnoreCase(arg, "px")) {
            return std.fmt.parseFloat(f64, dimensionDigits(arg[0 .. arg.len - 2])) catch null;
        }
        // Every other length. The absolute ones convert with no context; the
        // font-relative and viewport ones come from the basis, and a unit the
        // caller left null is refused the way it was before this existed.
        if (lengthUnit(arg)) |parsed| {
            return pixelsOf(parsed.value, parsed.unit, basis);
        }
    }
    // A bare `<number>`, which keeps every digit the author wrote -- and only
    // where a number is what the slot takes. `rotate(45)` and `translateX(45)`
    // are both refusals in Chrome and were both stored here.
    if (kind != .number) return null;
    return std.fmt.parseFloat(f64, arg) catch null;
}

fn write(arena: Allocator, matrix: Matrix, three_d: bool) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);
    const writer = &buf.writer;

    if (three_d) {
        try writer.writeAll("matrix3d(");
        for (0..4) |col| {
            for (0..4) |row| {
                if (col != 0 or row != 0) try writer.writeAll(", ");
                try writeNumber(writer, matrix.m[col][row]);
            }
        }
    } else {
        try writer.writeAll("matrix(");
        const parts = [_]f64{
            matrix.m[0][0], matrix.m[0][1],
            matrix.m[1][0], matrix.m[1][1],
            matrix.m[3][0], matrix.m[3][1],
        };
        for (parts, 0..) |part, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeNumber(writer, part);
        }
    }
    try writer.writeByte(')');
    return buf.written();
}

/// A rotation's cosine and sine, exact at multiples of a right angle.
///
/// Chrome answers `matrix(0, 1, -1, 0, 0, 0)` for `rotate(90deg)` and for the
/// `turn`, `grad` and `rad` spellings of it, and this engine's `@cos` there is
/// `6.123233995736766e-17`. It is not a print-time epsilon on Chrome's side:
/// `rotate(89.9999999deg)` prints `1.74533e-09`, so nothing near zero is being
/// swallowed -- the rotation itself is exact when the angle is a right angle.
/// Six decimals used to hide the difference; six significant digits does not.
///
/// The angle arrives in radians (`parseScalar`), so the test is against
/// multiples of pi/2 rather than of 90.
fn quarterTurns(radians: f64) ?i64 {
    const quarter = std.math.pi / 2.0;
    const turns = radians / quarter;
    const rounded = @round(turns);
    if (@abs(turns - rounded) > 1e-12) return null;
    if (@abs(rounded) > 1e15) return null;
    return @intFromFloat(rounded);
}

fn cosine(radians: f64) f64 {
    if (quarterTurns(radians)) |q| {
        return switch (@mod(q, 4)) {
            0 => 1,
            1, 3 => 0,
            else => -1,
        };
    }
    return @cos(radians);
}

fn sine(radians: f64) f64 {
    if (quarterTurns(radians)) |q| {
        return switch (@mod(q, 4)) {
            0, 2 => 0,
            1 => 1,
            else => -1,
        };
    }
    return @sin(radians);
}

/// `%g` with precision 6 -- six SIGNIFICANT digits, not six decimals, with the
/// exponent form C uses outside `[1e-4, 1e6)`. Measured on Chrome 151 over ten
/// magnitudes and a ladder from 1e-6 to 1e-17
/// (css/transform_number_format.html): `scale(0.000123456789)` is
/// `0.000123457`, `translate(1234567.89px)` is `1.23457e+06`,
/// `scale(-0.0000001234)` is `-1.234e-07`, and nothing is ever clamped to zero.
///
/// Six decimals agreed with this between about 0.1 and 10, which is where the
/// rule was first read off (`rotate(45deg)` is `0.707107` either way).
///
/// Built off Zig's `{e:.5}`, which is the same six digits in scientific form
/// (`1.23457e-4`), because a runtime number of decimal places is not something
/// `bufPrint` takes. The digits are then placed either side of a point.
fn writeNumber(writer: *std.Io.Writer, value: f64) !void {
    if (value == 0) return writer.writeAll("0");

    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{e:.5}", .{value}) catch return error.WriteFailed;
    const e_at = std.mem.indexOfScalar(u8, text, 'e') orelse return writer.writeAll(text);
    const mantissa = text[0..e_at];
    const exponent = std.fmt.parseInt(i32, text[e_at + 1 ..], 10) catch return error.WriteFailed;

    if (exponent < -4 or exponent >= 6) {
        try writer.writeAll(trimZeros(mantissa));
        try writer.writeByte('e');
        try writer.writeByte(if (exponent < 0) '-' else '+');
        var exp_buf: [8]u8 = undefined;
        const digits = std.fmt.bufPrint(&exp_buf, "{d}", .{@abs(exponent)}) catch return error.WriteFailed;
        if (digits.len < 2) try writer.writeByte('0');
        return writer.writeAll(digits);
    }

    // Fixed notation: the same digits with the point moved `exponent` places.
    var fixed_buf: [64]u8 = undefined;
    const written = placePoint(&fixed_buf, mantissa, exponent) orelse return error.WriteFailed;
    return writer.writeAll(trimZeros(written));
}

/// `-1.23457` and an exponent of -3 becomes `-0.00123457`. Only ever called
/// with an exponent in [-4, 6), so the point lands inside the buffer.
fn placePoint(buf: []u8, mantissa: []const u8, exponent: i32) ?[]const u8 {
    var at: usize = 0;
    var body = mantissa;
    if (body.len > 0 and (body[0] == '-' or body[0] == '+')) {
        if (body[0] == '-') {
            buf[at] = '-';
            at += 1;
        }
        body = body[1..];
    }
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    for (body) |c| {
        if (c == '.') continue;
        if (count == digits.len) return null;
        digits[count] = c;
        count += 1;
    }
    if (count == 0) return null;

    // Where the decimal point goes, counted from the left of `digits`.
    const point: i32 = exponent + 1;
    if (point <= 0) {
        if (at + 2 + @as(usize, @intCast(-point)) + count > buf.len) return null;
        buf[at] = '0';
        buf[at + 1] = '.';
        at += 2;
        var pad: i32 = 0;
        while (pad < -point) : (pad += 1) {
            buf[at] = '0';
            at += 1;
        }
        @memcpy(buf[at..][0..count], digits[0..count]);
        return buf[0 .. at + count];
    }

    const whole: usize = @intCast(point);
    if (whole >= count) {
        if (at + whole > buf.len) return null;
        @memcpy(buf[at..][0..count], digits[0..count]);
        at += count;
        var pad = whole - count;
        while (pad > 0) : (pad -= 1) {
            buf[at] = '0';
            at += 1;
        }
        return buf[0..at];
    }
    if (at + count + 1 > buf.len) return null;
    @memcpy(buf[at..][0..whole], digits[0..whole]);
    at += whole;
    buf[at] = '.';
    at += 1;
    @memcpy(buf[at..][0 .. count - whole], digits[whole..count]);
    return buf[0 .. at + count - whole];
}

/// Trailing zeros dropped, and no negative zero -- `%g` does both.
fn trimZeros(text: []const u8) []const u8 {
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        while (end > 0 and text[end - 1] == '0') : (end -= 1) {}
        if (end > 0 and text[end - 1] == '.') end -= 1;
    }
    const trimmed = text[0..end];
    if (std.mem.eql(u8, trimmed, "-0")) return "0";
    return trimmed;
}
