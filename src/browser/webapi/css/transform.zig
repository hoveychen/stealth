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

const Allocator = std.mem.Allocator;

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
pub fn computedValue(arena: Allocator, value: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "none")) return "none";

    var matrix: Matrix = .identity;
    var three_d = false;
    var seen = false;

    var i: usize = 0;
    while (i < trimmed.len) {
        while (i < trimmed.len and std.ascii.isWhitespace(trimmed[i])) : (i += 1) {}
        if (i >= trimmed.len) break;

        const name_start = i;
        while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '-')) : (i += 1) {}
        if (i >= trimmed.len or trimmed[i] != '(') return null;
        const name = trimmed[name_start..i];

        const close = std.mem.indexOfScalarPos(u8, trimmed, i, ')') orelse return null;
        const args = trimmed[i + 1 .. close];
        i = close + 1;

        const parsed = try parseFunction(name, args) orelse return null;
        matrix = matrix.multiply(parsed.matrix);
        three_d = three_d or parsed.three_d;
        seen = true;
    }

    if (!seen) return null;
    return try write(arena, matrix, three_d);
}

const Parsed = struct {
    matrix: Matrix,
    three_d: bool,
};

fn parseFunction(name: []const u8, args: []const u8) !?Parsed {
    var numbers: [16]f64 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, args, ',');
    while (it.next()) |raw| {
        if (count == numbers.len) return null;
        const arg = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (arg.len == 0) return null;
        numbers[count] = parseScalar(arg) orelse return null;
        count += 1;
    }
    const n = numbers[0..count];

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
        const c = @cos(n[0]);
        const s = @sin(n[0]);
        m.m[0][0] = c;
        m.m[0][1] = s;
        m.m[1][0] = -s;
        m.m[1][1] = c;
        return .{ .matrix = m, .three_d = false };
    }
    if (eq(name, "rotatex")) {
        if (n.len != 1) return null;
        const c = @cos(n[0]);
        const s = @sin(n[0]);
        m.m[1][1] = c;
        m.m[1][2] = s;
        m.m[2][1] = -s;
        m.m[2][2] = c;
        return .{ .matrix = m, .three_d = true };
    }
    if (eq(name, "rotatey")) {
        if (n.len != 1) return null;
        const c = @cos(n[0]);
        const s = @sin(n[0]);
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
        const c = @cos(n[3]);
        const s = @sin(n[3]);
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
/// length its pixel count, a bare number itself. A unit this does not know --
/// `em`, `%` -- answers null and takes the whole declaration with it, which is
/// the same refusal `resolvesHere` makes for every other property.
fn parseScalar(arg: []const u8) ?f64 {
    const Suffix = struct { []const u8, f64 };
    const angles = [_]Suffix{
        .{ "deg", std.math.pi / 180.0 },
        .{ "grad", std.math.pi / 200.0 },
        .{ "turn", 2 * std.math.pi },
        .{ "rad", 1 },
    };
    for (angles) |suffix| {
        if (arg.len > suffix[0].len and std.ascii.endsWithIgnoreCase(arg, suffix[0])) {
            const number = std.fmt.parseFloat(f64, arg[0 .. arg.len - suffix[0].len]) catch return null;
            return number * suffix[1];
        }
    }
    if (arg.len > 2 and std.ascii.endsWithIgnoreCase(arg, "px")) {
        return std.fmt.parseFloat(f64, arg[0 .. arg.len - 2]) catch null;
    }
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

/// Six decimals, trailing zeros dropped, and no negative zero. Measured:
/// `rotate(45deg)` answers `0.707107` rather than `0.70710678`,
/// `skew(10deg, 20deg)` answers `0.36397` rather than `0.363970`, and
/// `rotate(0.25turn)` answers a plain `0` for a cosine that is 6.1e-17.
fn writeNumber(writer: *std.Io.Writer, value: f64) !void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch return error.WriteFailed;

    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        while (end > 0 and text[end - 1] == '0') : (end -= 1) {}
        if (end > 0 and text[end - 1] == '.') end -= 1;
    }
    const trimmed = text[0..end];
    if (std.mem.eql(u8, trimmed, "-0")) return writer.writeAll("0");
    return writer.writeAll(trimmed);
}
