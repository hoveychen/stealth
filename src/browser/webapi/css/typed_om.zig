// The CSS Typed OM: twenty-seven globals below CSSStyleValue plus the writable
// half of the style maps. Chrome exposes all of them and CreepJS counts every
// window own key, so an engine that only has the CSSStyleValue base stands out
// twenty-seven names short.
//
// Shapes, member order, brands, argument counts, serialisations, unit
// conversions and the error each rejection path throws were all measured on a
// headed Chrome 150 over http://localhost (probes probe-css1.js,
// probe-css7.js and probe-css8.js in
// tools/fingerprint/probes/). Where Chrome disagrees
// with the CSS Typed OM spec the comment says so and Chrome wins.
//
// Declaration order inside each JsApi is Chrome's own
// Object.getOwnPropertyNames(X.prototype) order, because that order is itself
// part of what a detector hashes.

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const DOMMatrixReadOnly = @import("../DOMMatrixReadOnly.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");
const Css = @import("../Css.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        CSSStyleValue,
        CSSKeywordValue,
        CSSNumericValue,
        CSSUnitValue,
        CSSMathValue,
        CSSMathSum,
        CSSMathProduct,
        CSSMathMin,
        CSSMathMax,
        CSSMathNegate,
        CSSMathInvert,
        CSSMathClamp,
        CSSNumericArray,
        CSSUnparsedValue,
        CSSVariableReferenceValue,
        CSSImageValue,
        CSSPositionValue,
        CSSTransformComponent,
        CSSTranslate,
        CSSRotate,
        CSSScale,
        CSSSkew,
        CSSSkewX,
        CSSSkewY,
        CSSPerspective,
        CSSMatrixComponent,
        CSSTransformValue,
        StylePropertyMapReadOnly,
        StylePropertyMap,
    };
}

pub const SerializeError = error{ OutOfMemory, WriteFailed, StringTooLarge };

/// Explicit rather than inferred: CSSNumericValue and CSSMathValue call each
/// other's `numericType`, and mutually inferred error sets are a dependency
/// loop. Same reason the serialisers share SerializeError.
pub const NumericError = error{ TypeError, OutOfMemory };

/// The error set of `CSSNumericValue.parse`, which recurses through itself for
/// the arguments of `min()`/`max()`.
pub const ParseError = NumericError || error{ SyntaxError, RangeError };

// ---------------------------------------------------------------------------
// Number serialisation
// ---------------------------------------------------------------------------

/// Typed OM numbers serialise through printf `%g`: six significant digits,
/// trailing zeros dropped, scientific notation once the exponent leaves
/// [-4, 6), exponent padded to at least two digits. Measured — `1/3` prints
/// `0.333333` while `.value` still reads back the full double, and `999999.9`
/// rounds up into `1e+06`.
pub fn writeNumber(writer: *std.Io.Writer, v: f64) SerializeError!void {
    if (std.math.isNan(v)) return writer.writeAll("NaN");
    if (std.math.isInf(v)) return writer.writeAll(if (v > 0) "Infinity" else "-Infinity");
    if (v == 0) return writer.writeAll("0");

    var buf: [64]u8 = undefined;
    // Rounding to five decimals in scientific form first means the exponent we
    // branch on is the post-rounding one, exactly as %g does.
    const formatted = std.fmt.bufPrint(&buf, "{e:.5}", .{v}) catch return error.StringTooLarge;

    var rest = formatted;
    const negative = rest[0] == '-';
    if (negative) rest = rest[1..];

    const e_at = std.mem.indexOfScalar(u8, rest, 'e') orelse return error.StringTooLarge;
    var digits: [6]u8 = undefined;
    var count: usize = 0;
    for (rest[0..e_at]) |c| {
        if (c == '.') continue;
        if (count == digits.len) break;
        digits[count] = c;
        count += 1;
    }
    const exponent = std.fmt.parseInt(i32, rest[e_at + 1 ..], 10) catch return error.StringTooLarge;

    if (negative) try writer.writeAll("-");

    if (exponent < -4 or exponent >= 6) {
        const mantissa = stripTrailingZeros(digits[0..count]);
        try writer.writeAll(mantissa[0..1]);
        if (mantissa.len > 1) {
            try writer.writeAll(".");
            try writer.writeAll(mantissa[1..]);
        }
        const sign: u8 = if (exponent < 0) '-' else '+';
        try writer.print("e{c}{d:0>2}", .{ sign, @abs(exponent) });
        return;
    }

    if (exponent >= 0) {
        const int_len: usize = @intCast(exponent + 1);
        if (int_len >= count) {
            try writer.writeAll(digits[0..count]);
            for (0..int_len - count) |_| try writer.writeAll("0");
            return;
        }
        try writer.writeAll(digits[0..int_len]);
        const fraction = stripFraction(digits[int_len..count]);
        if (fraction.len != 0) {
            try writer.writeAll(".");
            try writer.writeAll(fraction);
        }
        return;
    }

    try writer.writeAll("0.");
    for (0..@intCast(-exponent - 1)) |_| try writer.writeAll("0");
    try writer.writeAll(stripTrailingZeros(digits[0..count]));
}

fn stripTrailingZeros(digits: []const u8) []const u8 {
    var end = digits.len;
    while (end > 1 and digits[end - 1] == '0') end -= 1;
    return digits[0..end];
}

/// Unlike a mantissa, a fraction may strip away entirely: `5px`, not `5.0px`.
fn stripFraction(digits: []const u8) []const u8 {
    var end = digits.len;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    return digits[0..end];
}

// ---------------------------------------------------------------------------
// Units and the numeric type algebra
// ---------------------------------------------------------------------------

/// The base types a numeric value's exponents are counted in. The order here is
/// internal; `type()` emits its keys in WebIDL dictionary (lexicographic)
/// order instead, which is why `px * deg` reports angle before length.
pub const BaseType = enum(u3) { length, angle, time, frequency, resolution, flex, percent };

pub const Unit = enum {
    number,
    percent,
    // Absolute lengths, canonical px.
    px,
    cm,
    mm,
    q,
    in,
    pt,
    pc,
    // Relative lengths: length-typed, but no factor, so they only convert to
    // themselves.
    em,
    ex,
    ch,
    ic,
    rem,
    lh,
    rlh,
    vw,
    vh,
    vi,
    vb,
    vmin,
    vmax,
    cqw,
    cqh,
    cqi,
    cqb,
    cqmin,
    cqmax,
    // Angles, canonical deg.
    deg,
    grad,
    rad,
    turn,
    // Times, canonical s.
    s,
    ms,
    // Frequencies, canonical hz.
    hz,
    khz,
    // Resolutions, canonical dppx. Measured: `x` is its own unit name with the
    // same factor, and both report a resolution type.
    dpi,
    dpcm,
    dppx,
    x,
    // Flex.
    fr,

    // Blink derives these from one double to the next, so each step rounds to
    // f64. Left as comptime_float they would be computed in one arbitrary
    // precision expression and land on a different double: 96px -> q comes out
    // 101.6 instead of Chrome's 101.60000000000002.
    const CM_PER_PX: f64 = 96.0 / 2.54;
    const MM_PER_PX: f64 = CM_PER_PX / 10.0;
    const Q_PER_PX: f64 = CM_PER_PX / 40.0;
    const PT_PER_PX: f64 = 96.0 / 72.0;
    const PC_PER_PX: f64 = 96.0 / 6.0;
    const DEG_PER_RAD: f64 = 180.0 / std.math.pi;
    const DPPX_PER_DPI: f64 = 1.0 / 96.0;
    const DPPX_PER_DPCM: f64 = 2.54 / 96.0;

    pub fn parse(name: []const u8) ?Unit {
        if (name.len == 0 or name.len > 8) return null;
        var lower: [8]u8 = undefined;
        const key = std.ascii.lowerString(lower[0..name.len], name);
        return std.meta.stringToEnum(Unit, key);
    }

    pub fn baseType(self: Unit) ?BaseType {
        return switch (self) {
            .number => null,
            .percent => .percent,
            .px, .cm, .mm, .q, .in, .pt, .pc => .length,
            .em, .ex, .ch, .ic, .rem, .lh, .rlh => .length,
            .vw, .vh, .vi, .vb, .vmin, .vmax => .length,
            .cqw, .cqh, .cqi, .cqb, .cqmin, .cqmax => .length,
            .deg, .grad, .rad, .turn => .angle,
            .s, .ms => .time,
            .hz, .khz => .frequency,
            .dpi, .dpcm, .dppx, .x => .resolution,
            .fr => .flex,
        };
    }

    /// How many canonical units one of these is, or null when the unit is
    /// relative to something the value does not carry.
    pub fn factor(self: Unit) ?f64 {
        return switch (self) {
            .number, .percent, .px, .deg, .s, .hz, .fr => 1.0,
            .cm => CM_PER_PX,
            .mm => MM_PER_PX,
            .q => Q_PER_PX,
            .in => 96.0,
            .pt => PT_PER_PX,
            .pc => PC_PER_PX,
            .grad => 0.9,
            .rad => DEG_PER_RAD,
            .turn => 360.0,
            .ms => 0.001,
            .khz => 1000.0,
            .dpi => DPPX_PER_DPI,
            .dpcm => DPPX_PER_DPCM,
            .dppx, .x => 1.0,
            else => null,
        };
    }

    pub fn suffix(self: Unit) []const u8 {
        return switch (self) {
            .number => "",
            .percent => "%",
            else => @tagName(self),
        };
    }
};

/// Exponent per base type, plus the percent hint a length+percent sum picks up.
pub const NumericType = struct {
    exponents: [7]i32 = @splat(0),
    percent_hint: ?BaseType = null,

    fn get(self: NumericType, base: BaseType) i32 {
        return self.exponents[@intFromEnum(base)];
    }

    fn set(self: *NumericType, base: BaseType, value: i32) void {
        self.exponents[@intFromEnum(base)] = value;
    }

    fn forUnit(unit: Unit) NumericType {
        var out = NumericType{};
        if (unit.baseType()) |base| out.set(base, 1);
        return out;
    }

    fn eql(self: NumericType, other: NumericType) bool {
        return std.mem.eql(i32, &self.exponents, &other.exponents) and
            self.percent_hint == other.percent_hint;
    }

    fn onlyBase(self: NumericType) ?BaseType {
        var found: ?BaseType = null;
        for (self.exponents, 0..) |exp, i| {
            if (exp == 0) continue;
            if (found != null) return null;
            found = @enumFromInt(i);
        }
        return found;
    }

    /// Addition requires matching types, except that a bare percent folds into
    /// whatever single base type the other side has and leaves a hint behind.
    /// Measured: `1px + 2%` types as `{length: 1, percentHint: "length"}`.
    fn add(self: NumericType, other: NumericType) NumericError!NumericType {
        if (self.eql(other)) return self;

        var left = self;
        var right = other;
        if (left.get(.percent) != 0 and right.get(.percent) == 0) {
            if (right.onlyBase()) |base| {
                if (base != .percent) {
                    left.set(base, left.get(base) + left.get(.percent));
                    left.set(.percent, 0);
                    left.percent_hint = base;
                    if (left.eql(right)) {
                        left.percent_hint = base;
                        return left;
                    }
                }
            }
        } else if (right.get(.percent) != 0 and left.get(.percent) == 0) {
            if (left.onlyBase()) |base| {
                if (base != .percent) {
                    right.set(base, right.get(base) + right.get(.percent));
                    right.set(.percent, 0);
                    if (std.mem.eql(i32, &left.exponents, &right.exponents)) {
                        var out = left;
                        out.percent_hint = base;
                        return out;
                    }
                }
            }
        }
        return error.TypeError;
    }

    fn multiply(self: NumericType, other: NumericType) NumericError!NumericType {
        var out = NumericType{ .percent_hint = self.percent_hint orelse other.percent_hint };
        for (&out.exponents, self.exponents, other.exponents) |*slot, a, b| {
            slot.* = a + b;
        }
        return out;
    }

    fn invert(self: NumericType) NumericType {
        var out = NumericType{ .percent_hint = self.percent_hint };
        for (&out.exponents, self.exponents) |*slot, exp| {
            slot.* = -exp;
        }
        return out;
    }

    fn baseName(base: BaseType) []const u8 {
        return switch (base) {
            .length => "length",
            .angle => "angle",
            .time => "time",
            .frequency => "frequency",
            .resolution => "resolution",
            .flex => "flex",
            .percent => "percent",
        };
    }

    /// The CSSNumericType dictionary, whose members WebIDL serialises in
    /// lexicographic order: angle, flex, frequency, length, percent,
    /// percentHint, resolution, time.
    fn toObject(self: NumericType, exec: *const Execution) !js.Object {
        const object = exec.js.local.?.newObject();
        const order = [_]BaseType{ .angle, .flex, .frequency, .length };
        for (order) |base| {
            const exp = self.get(base);
            if (exp != 0) _ = try object.set(baseName(base), exp, .{});
        }
        if (self.get(.percent) != 0) _ = try object.set("percent", self.get(.percent), .{});
        if (self.percent_hint) |hint| _ = try object.set("percentHint", baseName(hint), .{});
        if (self.get(.resolution) != 0) _ = try object.set("resolution", self.get(.resolution), .{});
        if (self.get(.time) != 0) _ = try object.set("time", self.get(.time), .{});
        return object;
    }
};

/// WebIDL `CSSNumberish`: a bare double or a CSSNumericValue. `numeric` comes
/// first so an object matches it before the double coercion is considered.
pub const Numberish = union(enum) {
    numeric: *CSSNumericValue,
    number: f64,

    fn resolve(self: Numberish, frame: *Frame) !*CSSNumericValue {
        return switch (self) {
            .numeric => |n| n,
            .number => |v| (try CSSUnitValue.create(v, .number, frame))._proto,
        };
    }
};

// ---------------------------------------------------------------------------
// CSSStyleValue: the root of the hierarchy
// ---------------------------------------------------------------------------

pub const CSSStyleValue = struct {
    /// Which subclass this value actually is. `.plain` is a value Chrome could
    /// not map onto one of the typed subclasses; it keeps the raw text.
    pub const Type = union(enum) {
        plain: void,
        keyword: *CSSKeywordValue,
        numeric: *CSSNumericValue,
        unparsed: *CSSUnparsedValue,
        image: *CSSImageValue,
        position: *CSSPositionValue,
        transform: *CSSTransformValue,
    };

    _type: Type = .plain,
    _text: []const u8 = "",

    pub fn init(text: []const u8, frame: *Frame) !*CSSStyleValue {
        return frame._factory.create(CSSStyleValue{ ._text = try frame.dupeString(text) });
    }

    /// The one `toString` on the hierarchy: Chrome puts it on
    /// CSSStyleValue.prototype and nowhere else, so every subclass's
    /// serialisation is routed from here.
    pub fn toString(self: *CSSStyleValue, frame: *Frame) SerializeError![]const u8 {
        switch (self._type) {
            .plain => return self._text,
            else => {},
        }
        var out = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.write(&out.writer, frame);
        return out.written();
    }

    fn write(self: *CSSStyleValue, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        switch (self._type) {
            .plain => try writer.writeAll(self._text),
            .keyword => |k| try k.write(writer, frame),
            .numeric => |n| try n.write(writer, frame, false),
            .unparsed => |u| try u.write(writer, frame),
            .image => |i| try writer.writeAll(i._text),
            .position => |p| try p.write(writer, frame),
            .transform => |t| try t.write(writer, frame),
        }
    }

    /// `CSSStyleValue.parse(property, value)` runs the same property-aware
    /// dispatch a style map does.
    pub fn parse(property: []const u8, value: []const u8, frame: *Frame) !*CSSStyleValue {
        if (!isKnownProperty(property)) return error.TypeError;
        return dispatch(property, value, frame);
    }

    /// Measured: parseAll never splits, it hands back a one-element sequence
    /// even for a shorthand or a comma list.
    pub fn parseAll(property: []const u8, value: []const u8, frame: *Frame) ![]const *CSSStyleValue {
        const list = try frame.local_arena.alloc(*CSSStyleValue, 1);
        list[0] = try CSSStyleValue.parse(property, value, frame);
        return list;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSStyleValue);

        pub const Meta = struct {
            pub const name = "CSSStyleValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const toString = bridge.function(CSSStyleValue.toString, .{});
        pub const parse = bridge.function(CSSStyleValue.parse, .{ .static = true });
        pub const parseAll = bridge.function(CSSStyleValue.parseAll, .{ .static = true });
    };
};

// ---------------------------------------------------------------------------
// CSSKeywordValue
// ---------------------------------------------------------------------------

pub const CSSKeywordValue = struct {
    pub const Proto = CSSStyleValue;

    _proto: *CSSStyleValue,
    _value: []const u8,

    pub fn init(value: []const u8, frame: *Frame) !*CSSKeywordValue {
        return create(value, frame);
    }

    pub fn create(value: []const u8, frame: *Frame) !*CSSKeywordValue {
        // Measured: an empty keyword is a TypeError, both here and in the setter.
        if (value.len == 0) return error.TypeError;
        const keyword = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSKeywordValue{ ._proto = undefined, ._value = try frame.dupeString(value) },
        });
        keyword._proto._type = .{ .keyword = keyword };
        return keyword;
    }

    pub fn getValue(self: *const CSSKeywordValue) []const u8 {
        return self._value;
    }

    pub fn setValue(self: *CSSKeywordValue, value: []const u8, frame: *Frame) !void {
        if (value.len == 0) return error.TypeError;
        self._value = try frame.dupeString(value);
    }

    /// Measured: the keyword serialises as a CSS identifier, so
    /// `new CSSKeywordValue(5)` prints `\35 `.
    fn write(self: *const CSSKeywordValue, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        const escaped = Css.escape(self._value, frame) catch return error.OutOfMemory;
        try writer.writeAll(escaped);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSKeywordValue);

        pub const Meta = struct {
            pub const name = "CSSKeywordValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSKeywordValue.init, .{});
        pub const value = bridge.accessor(CSSKeywordValue.getValue, CSSKeywordValue.setValue, .{});
    };
};

// ---------------------------------------------------------------------------
// CSSNumericValue: the arithmetic
// ---------------------------------------------------------------------------

pub const CSSNumericValue = struct {
    pub const Proto = CSSStyleValue;

    pub const Type = union(enum) {
        unit: *CSSUnitValue,
        math: *CSSMathValue,
    };

    _proto: *CSSStyleValue,
    _type: Type,

    fn asUnit(self: *CSSNumericValue) ?*CSSUnitValue {
        return switch (self._type) {
            .unit => |u| u,
            .math => null,
        };
    }

    fn numericType(self: *CSSNumericValue) NumericError!NumericType {
        return switch (self._type) {
            .unit => |u| NumericType.forUnit(u._unit),
            .math => |m| m.numericType(),
        };
    }

    pub fn getTypeRecord(self: *CSSNumericValue, exec: *const Execution) !js.Object {
        return (try self.numericType()).toObject(exec);
    }

    fn write(self: *CSSNumericValue, writer: *std.Io.Writer, frame: *Frame, nested: bool) SerializeError!void {
        switch (self._type) {
            .unit => |u| try u.write(writer),
            .math => |m| try m.write(writer, frame, nested),
        }
    }

    /// A math node needs parentheses inside another math node's calc(); a unit
    /// value and the functional forms (min/max/clamp) do not. Measured:
    /// `calc(1px + 2em + (3px + 4em))` and `calc((2px * 3) + 1em)`.
    fn needsParens(self: *CSSNumericValue) bool {
        const math = switch (self._type) {
            .unit => return false,
            .math => |m| m,
        };
        return switch (math._type) {
            .sum, .product, .negate, .invert => true,
            .min, .max, .clamp => false,
        };
    }

    fn eqlValue(self: *CSSNumericValue, other: *CSSNumericValue) bool {
        switch (self._type) {
            .unit => |a| {
                const b = other.asUnit() orelse return false;
                return a._unit == b._unit and a._value == b._value;
            },
            .math => |a| {
                const b = switch (other._type) {
                    .unit => return false,
                    .math => |m| m,
                };
                return a.eqlValue(b);
            },
        }
    }

    /// Flattened leaf terms, used by `to`, `toSum` and the sum/min/max
    /// builders. A nested sum contributes its own terms.
    fn collectSumTerms(self: *CSSNumericValue, out: *std.ArrayList(*CSSNumericValue), frame: *Frame) error{OutOfMemory}!void {
        switch (self._type) {
            .unit => try out.append(frame.local_arena, self),
            .math => |m| switch (m._type) {
                .sum => |sum| {
                    for (sum._values._items) |item| try item.collectSumTerms(out, frame);
                },
                else => try out.append(frame.local_arena, self),
            },
        }
    }

    // -- add / sub ---------------------------------------------------------

    pub fn add(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !*CSSNumericValue {
        return self.addAll(values, false, frame);
    }

    /// Measured: `sub` is `add` of the negated argument, and negating a unit
    /// value flips the value rather than wrapping it, so `1px.sub(2em)` is
    /// `calc(1px + -2em)`.
    pub fn sub(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !*CSSNumericValue {
        return self.addAll(values, true, frame);
    }

    fn addAll(self: *CSSNumericValue, values: []const Numberish, negate: bool, frame: *Frame) !*CSSNumericValue {
        if (values.len == 0) return self;

        const resolved = try frame.local_arena.alloc(*CSSNumericValue, values.len);
        var running = try self.numericType();
        for (values, resolved) |raw, *slot| {
            var value = try raw.resolve(frame);
            if (negate) value = try value.negated(frame);
            running = try running.add(try value.numericType());
            slot.* = value;
        }

        // Same unit throughout collapses into one unit value.
        if (self.asUnit()) |base| {
            var total = base._value;
            var same = true;
            for (resolved) |value| {
                const unit = value.asUnit() orelse {
                    same = false;
                    break;
                };
                if (unit._unit != base._unit) {
                    same = false;
                    break;
                }
                total += unit._value;
            }
            if (same) return (try CSSUnitValue.create(total, base._unit, frame))._proto;
        }

        var terms: std.ArrayList(*CSSNumericValue) = .empty;
        try self.collectSumTerms(&terms, frame);
        try terms.appendSlice(frame.local_arena, resolved);
        return (try CSSMathSum.create(terms.items, frame))._proto._proto;
    }

    fn negated(self: *CSSNumericValue, frame: *Frame) !*CSSNumericValue {
        if (self.asUnit()) |unit| {
            return (try CSSUnitValue.create(-unit._value, unit._unit, frame))._proto;
        }
        return (try CSSMathNegate.create(self, frame))._proto._proto;
    }

    // -- mul / div ---------------------------------------------------------

    pub fn mul(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !*CSSNumericValue {
        if (values.len == 0) return self;
        const resolved = try frame.local_arena.alloc(*CSSNumericValue, values.len);
        for (values, resolved) |raw, *slot| slot.* = try raw.resolve(frame);

        // Measured: a unit value times plain numbers stays a unit value, and
        // anything else becomes a product node.
        if (self.asUnit()) |base| {
            var total = base._value;
            var plain = true;
            for (resolved) |value| {
                const unit = value.asUnit() orelse {
                    plain = false;
                    break;
                };
                if (unit._unit != .number) {
                    plain = false;
                    break;
                }
                total *= unit._value;
            }
            if (plain) return (try CSSUnitValue.create(total, base._unit, frame))._proto;
        }

        var factors: std.ArrayList(*CSSNumericValue) = .empty;
        try factors.append(frame.local_arena, self);
        try factors.appendSlice(frame.local_arena, resolved);
        return (try CSSMathProduct.create(factors.items, frame))._proto._proto;
    }

    /// Measured: dividing multiplies by the reciprocal, so a sum divided by 2
    /// serialises as `calc((1px + 2em) * 0.5)`, and a zero divisor is a
    /// RangeError rather than a TypeError.
    pub fn div(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !*CSSNumericValue {
        if (values.len == 0) return self;
        const reciprocals = try frame.local_arena.alloc(Numberish, values.len);
        for (values, reciprocals) |raw, *slot| {
            const value = try raw.resolve(frame);
            const unit = value.asUnit() orelse {
                slot.* = .{ .numeric = (try CSSMathInvert.create(value, frame))._proto._proto };
                continue;
            };
            if (unit._value == 0) return error.RangeError;
            if (unit._unit != .number) {
                slot.* = .{ .numeric = (try CSSMathInvert.create(value, frame))._proto._proto };
                continue;
            }
            slot.* = .{ .numeric = (try CSSUnitValue.create(1.0 / unit._value, .number, frame))._proto };
        }
        return self.mul(reciprocals, frame);
    }

    // -- min / max / equals ------------------------------------------------

    pub fn min(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !*CSSNumericValue {
        return self.extremum(values, true, frame);
    }

    pub fn max(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !*CSSNumericValue {
        return self.extremum(values, false, frame);
    }

    fn extremum(self: *CSSNumericValue, values: []const Numberish, want_min: bool, frame: *Frame) !*CSSNumericValue {
        if (values.len == 0) return self;
        const resolved = try frame.local_arena.alloc(*CSSNumericValue, values.len);
        var running = try self.numericType();
        for (values, resolved) |raw, *slot| {
            const value = try raw.resolve(frame);
            running = try running.add(try value.numericType());
            slot.* = value;
        }

        if (self.asUnit()) |base| {
            var best = base._value;
            var same = true;
            for (resolved) |value| {
                const unit = value.asUnit() orelse {
                    same = false;
                    break;
                };
                if (unit._unit != base._unit) {
                    same = false;
                    break;
                }
                if (want_min) {
                    best = @min(best, unit._value);
                } else {
                    best = @max(best, unit._value);
                }
            }
            if (same) return (try CSSUnitValue.create(best, base._unit, frame))._proto;
        }

        var terms: std.ArrayList(*CSSNumericValue) = .empty;
        try terms.append(frame.local_arena, self);
        try terms.appendSlice(frame.local_arena, resolved);
        const math = if (want_min)
            (try CSSMathMin.create(terms.items, frame))._proto._proto
        else
            (try CSSMathMax.create(terms.items, frame))._proto._proto;
        return math;
    }

    pub fn equals(self: *CSSNumericValue, values: []const Numberish, frame: *Frame) !bool {
        for (values) |raw| {
            const other = try raw.resolve(frame);
            if (!self.eqlValue(other)) return false;
        }
        return true;
    }

    // -- to / toSum --------------------------------------------------------

    /// Measured: an unknown target unit is a SyntaxError while an
    /// unconvertible one is a TypeError.
    pub fn to(self: *CSSNumericValue, unit_name: []const u8, frame: *Frame) !*CSSUnitValue {
        const target = Unit.parse(unit_name) orelse return error.SyntaxError;

        var terms: std.ArrayList(*CSSNumericValue) = .empty;
        try self.collectSumTerms(&terms, frame);

        var total: f64 = 0;
        for (terms.items) |term| {
            const unit = term.asUnit() orelse return error.TypeError;
            total += try convert(unit._value, unit._unit, target);
        }
        return CSSUnitValue.create(total, target, frame);
    }

    fn convert(value: f64, from: Unit, to_unit: Unit) !f64 {
        if (from == to_unit) return value;
        if (from.baseType() != to_unit.baseType()) return error.TypeError;
        const from_factor = from.factor() orelse return error.TypeError;
        const to_factor = to_unit.factor() orelse return error.TypeError;
        // Blink multiplies by the reciprocal of the target factor rather than
        // dividing, and the last bits differ: 96px -> cm is
        // 2.5400000000000005, not 2.54.
        return (value * from_factor) * (1.0 / to_factor);
    }

    pub fn toSum(self: *CSSNumericValue, unit_names: []const []const u8, frame: *Frame) !*CSSMathSum {
        var terms: std.ArrayList(*CSSNumericValue) = .empty;
        try self.collectSumTerms(&terms, frame);

        if (unit_names.len != 0) {
            const slots = try frame.local_arena.alloc(f64, unit_names.len);
            const units = try frame.local_arena.alloc(Unit, unit_names.len);
            for (unit_names, units, slots) |name, *unit, *slot| {
                unit.* = Unit.parse(name) orelse return error.SyntaxError;
                slot.* = 0;
            }
            for (terms.items) |term| {
                const unit = term.asUnit() orelse return error.TypeError;
                var placed = false;
                for (units, slots) |target, *slot| {
                    const converted = convert(unit._value, unit._unit, target) catch continue;
                    slot.* += converted;
                    placed = true;
                    break;
                }
                // Measured: a term that fits none of the requested units is
                // "leftover terms that were not converted", a TypeError.
                if (!placed) return error.TypeError;
            }
            const values = try frame.local_arena.alloc(*CSSNumericValue, units.len);
            for (units, slots, values) |unit, total, *slot| {
                slot.* = (try CSSUnitValue.create(total, unit, frame))._proto;
            }
            return CSSMathSum.create(values, frame);
        }

        // Without explicit units the terms are folded per unit and, measured,
        // come out sorted by unit name: `calc(2em + 4px)`.
        var buckets: std.ArrayList(struct { unit: Unit, total: f64 }) = .empty;
        for (terms.items) |term| {
            const unit = term.asUnit() orelse return error.TypeError;
            for (buckets.items) |*bucket| {
                if (bucket.unit == unit._unit) {
                    bucket.total += unit._value;
                    break;
                }
            } else {
                try buckets.append(frame.local_arena, .{ .unit = unit._unit, .total = unit._value });
            }
        }
        std.mem.sort(@TypeOf(buckets.items[0]), buckets.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(buckets.items[0]), b: @TypeOf(buckets.items[0])) bool {
                return std.mem.lessThan(u8, a.unit.suffix(), b.unit.suffix());
            }
        }.lessThan);

        const values = try frame.local_arena.alloc(*CSSNumericValue, buckets.items.len);
        for (buckets.items, values) |bucket, *slot| {
            slot.* = (try CSSUnitValue.create(bucket.total, bucket.unit, frame))._proto;
        }
        return CSSMathSum.create(values, frame);
    }

    /// Measured: `parse` accepts a dimension or a math function and nothing
    /// else — a bare keyword, an empty string and `var()` are all SyntaxErrors.
    /// A `calc()` always comes back as a CSSMathSum, already folded per unit,
    /// while `min()`/`max()` fold all the way to a unit value when they can.
    pub fn parse(text: []const u8, frame: *Frame) ParseError!*CSSNumericValue {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.SyntaxError;

        if (parseDimension(trimmed)) |dimension| {
            return (try CSSUnitValue.create(dimension.value, dimension.unit, frame))._proto;
        }

        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.SyntaxError;
        if (trimmed[trimmed.len - 1] != ')') return error.SyntaxError;
        const name = trimmed[0..open];
        const body = trimmed[open + 1 .. trimmed.len - 1];

        if (std.ascii.eqlIgnoreCase(name, "calc")) {
            const folded = try foldExpression(body, frame);
            return (try CSSMathSum.create(folded, frame))._proto._proto;
        }
        if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) {
            var args = std.mem.splitScalar(u8, body, ',');
            var values: std.ArrayList(Numberish) = .empty;
            var first: ?*CSSNumericValue = null;
            while (args.next()) |arg| {
                const value = try CSSNumericValue.parse(arg, frame);
                if (first == null) {
                    first = value;
                } else {
                    try values.append(frame.local_arena, .{ .numeric = value });
                }
            }
            const head = first orelse return error.SyntaxError;
            return if (std.ascii.eqlIgnoreCase(name, "min"))
                head.min(values.items, frame)
            else
                head.max(values.items, frame);
        }
        return error.SyntaxError;
    }

    const Dimension = struct { value: f64, unit: Unit };

    fn parseDimension(text: []const u8) ?Dimension {
        var end: usize = 0;
        var seen_digit = false;
        if (end < text.len and (text[end] == '+' or text[end] == '-')) end += 1;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) seen_digit = true;
        if (end < text.len and text[end] == '.') {
            end += 1;
            while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) seen_digit = true;
        }
        if (!seen_digit) return null;
        if (end < text.len and (text[end] == 'e' or text[end] == 'E')) {
            var probe = end + 1;
            if (probe < text.len and (text[probe] == '+' or text[probe] == '-')) probe += 1;
            var exponent_digits = false;
            while (probe < text.len and std.ascii.isDigit(text[probe])) : (probe += 1) exponent_digits = true;
            if (exponent_digits) end = probe;
        }
        const value = std.fmt.parseFloat(f64, text[0..end]) catch return null;
        const suffix = text[end..];
        if (suffix.len == 0) return .{ .value = value, .unit = .number };
        if (std.mem.eql(u8, suffix, "%")) return .{ .value = value, .unit = .percent };
        const unit = Unit.parse(suffix) orelse return null;
        return .{ .value = value, .unit = unit };
    }

    /// Folds the inside of a `calc()` into one term per unit. Only the shapes
    /// Chrome was measured on are supported: `+`/`-` between dimensions and
    /// `*`/`/` by a plain number.
    fn foldExpression(body: []const u8, frame: *Frame) ![]const *CSSNumericValue {
        var buckets: std.ArrayList(struct { unit: Unit, total: f64 }) = .empty;
        var index: usize = 0;
        var sign: f64 = 1;
        while (index < body.len) {
            while (index < body.len and std.ascii.isWhitespace(body[index])) index += 1;
            if (index >= body.len) break;

            const start = index;
            while (index < body.len and body[index] != '+' and !isTermBreak(body, index)) index += 1;
            const term_text = std.mem.trim(u8, body[start..index], " \t\r\n");
            if (term_text.len == 0) return error.SyntaxError;

            const term = try foldTerm(term_text);
            for (buckets.items) |*bucket| {
                if (bucket.unit == term.unit) {
                    bucket.total += sign * term.value;
                    break;
                }
            } else {
                try buckets.append(frame.local_arena, .{ .unit = term.unit, .total = sign * term.value });
            }

            while (index < body.len and std.ascii.isWhitespace(body[index])) index += 1;
            if (index >= body.len) break;
            sign = switch (body[index]) {
                '+' => 1,
                '-' => -1,
                else => return error.SyntaxError,
            };
            index += 1;
        }
        if (buckets.items.len == 0) return error.SyntaxError;

        const values = try frame.local_arena.alloc(*CSSNumericValue, buckets.items.len);
        for (buckets.items, values) |bucket, *slot| {
            slot.* = (try CSSUnitValue.create(bucket.total, bucket.unit, frame))._proto;
        }
        return values;
    }

    /// A `-` only separates terms when it follows whitespace; otherwise it is
    /// the sign of the next number (`calc(1px + -2em)`).
    fn isTermBreak(body: []const u8, index: usize) bool {
        if (body[index] != '-') return false;
        if (index == 0) return false;
        return std.ascii.isWhitespace(body[index - 1]);
    }

    fn foldTerm(text: []const u8) !Dimension {
        var value: f64 = 1;
        var unit: Unit = .number;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        var operator: u8 = '*';
        var first = true;
        while (it.next()) |token| {
            if (!first and (std.mem.eql(u8, token, "*") or std.mem.eql(u8, token, "/"))) {
                operator = token[0];
                continue;
            }
            const dimension = parseDimension(token) orelse return error.SyntaxError;
            if (first) {
                value = dimension.value;
                unit = dimension.unit;
                first = false;
                continue;
            }
            if (dimension.unit != .number) {
                if (unit != .number) return error.SyntaxError;
                unit = dimension.unit;
            }
            if (operator == '*') {
                value *= dimension.value;
            } else {
                if (dimension.value == 0) return error.RangeError;
                value /= dimension.value;
            }
        }
        if (first) return error.SyntaxError;
        return .{ .value = value, .unit = unit };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSNumericValue);

        pub const Meta = struct {
            pub const name = "CSSNumericValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const add = bridge.function(CSSNumericValue.add, .{ .arity = 0 });
        pub const div = bridge.function(CSSNumericValue.div, .{ .arity = 0 });
        pub const equals = bridge.function(CSSNumericValue.equals, .{ .arity = 0 });
        pub const max = bridge.function(CSSNumericValue.max, .{ .arity = 0 });
        pub const min = bridge.function(CSSNumericValue.min, .{ .arity = 0 });
        pub const mul = bridge.function(CSSNumericValue.mul, .{ .arity = 0 });
        pub const sub = bridge.function(CSSNumericValue.sub, .{ .arity = 0 });
        pub const to = bridge.function(CSSNumericValue.to, .{});
        pub const toSum = bridge.function(CSSNumericValue.toSum, .{ .arity = 0 });
        pub const @"type" = bridge.function(CSSNumericValue.getTypeRecord, .{});
        pub const parse = bridge.function(CSSNumericValue.parse, .{ .static = true });
    };
};

// ---------------------------------------------------------------------------
// CSSUnitValue
// ---------------------------------------------------------------------------

pub const CSSUnitValue = struct {
    pub const Proto = CSSNumericValue;

    _proto: *CSSNumericValue,
    _value: f64,
    _unit: Unit,

    pub fn init(value: f64, unit_name: []const u8, frame: *Frame) !*CSSUnitValue {
        // Measured: a non-finite number and an unknown unit are both TypeErrors.
        if (!std.math.isFinite(value)) return error.TypeError;
        const unit = Unit.parse(unit_name) orelse return error.TypeError;
        return create(value, unit, frame);
    }

    pub fn create(value: f64, unit: Unit, frame: *Frame) !*CSSUnitValue {
        const unit_value = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSNumericValue{ ._proto = undefined, ._type = undefined },
            CSSUnitValue{ ._proto = undefined, ._value = value, ._unit = unit },
        });
        unit_value._proto._proto._type = .{ .numeric = unit_value._proto };
        unit_value._proto._type = .{ .unit = unit_value };
        return unit_value;
    }

    pub fn getValue(self: *const CSSUnitValue) f64 {
        return self._value;
    }

    pub fn setValue(self: *CSSUnitValue, value: f64) !void {
        if (!std.math.isFinite(value)) return error.TypeError;
        self._value = value;
    }

    /// Measured: `unit` is read-only, and assigning to it is a silent no-op
    /// rather than a throw.
    pub fn getUnit(self: *const CSSUnitValue) []const u8 {
        return @tagName(self._unit);
    }

    fn write(self: *const CSSUnitValue, writer: *std.Io.Writer) SerializeError!void {
        try writeNumber(writer, self._value);
        try writer.writeAll(self._unit.suffix());
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSUnitValue);

        pub const Meta = struct {
            pub const name = "CSSUnitValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSUnitValue.init, .{});
        pub const value = bridge.accessor(CSSUnitValue.getValue, CSSUnitValue.setValue, .{});
        pub const unit = bridge.accessor(CSSUnitValue.getUnit, null, .{});
    };
};

// ---------------------------------------------------------------------------
// CSSNumericArray
// ---------------------------------------------------------------------------

pub const CSSNumericArray = struct {
    _items: []const *CSSNumericValue,

    pub fn create(items: []const *CSSNumericValue, frame: *Frame) !*CSSNumericArray {
        return frame._factory.create(CSSNumericArray{
            ._items = try frame.arena.dupe(*CSSNumericValue, items),
        });
    }

    pub fn getLength(self: *const CSSNumericArray) u32 {
        return @intCast(self._items.len);
    }

    pub fn item(self: *const CSSNumericArray, index: usize) ?*CSSNumericValue {
        if (index >= self._items.len) return null;
        return self._items[index];
    }

    fn indexes(self: *CSSNumericArray, exec: *const Execution) !js.Array {
        return indexArray(self._items.len, exec);
    }

    pub fn keys(self: *CSSNumericArray, exec: *const Execution) !*KeyIterator {
        return .init(.{ .array = self }, exec);
    }

    pub fn values(self: *CSSNumericArray, exec: *const Execution) !*ValueIterator {
        return .init(.{ .array = self }, exec);
    }

    pub fn entries(self: *CSSNumericArray, exec: *const Execution) !*EntryIterator {
        return .init(.{ .array = self }, exec);
    }

    pub fn forEach(self: *CSSNumericArray, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._items, 0..) |value, index| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ value, index, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        array: *CSSNumericArray,

        pub const Entry = struct { u32, *CSSNumericValue };

        pub fn next(self: *Iterator, _: *const Execution) ?Entry {
            const index = self.index;
            const value = self.array.item(index) orelse return null;
            self.index = index + 1;
            return .{ index, value };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSNumericArray);

        pub const Meta = struct {
            pub const name = "CSSNumericArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const entries = bridge.function(CSSNumericArray.entries, .{});
        pub const keys = bridge.function(CSSNumericArray.keys, .{});
        pub const values = bridge.function(CSSNumericArray.values, .{});
        pub const forEach = bridge.function(CSSNumericArray.forEach, .{});
        pub const length = bridge.accessor(CSSNumericArray.getLength, null, .{});
        pub const @"[]" = bridge.indexed(CSSNumericArray.item, CSSNumericArray.indexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(CSSNumericArray.values, .{});
    };
};

fn indexArray(len: usize, exec: *const Execution) !js.Array {
    var array = exec.js.local.?.newArray(@intCast(len));
    for (0..len) |index| {
        _ = try array.set(@intCast(index), index, .{});
    }
    return array;
}

// ---------------------------------------------------------------------------
// CSSMathValue and its seven leaves
// ---------------------------------------------------------------------------

pub const CSSMathValue = struct {
    pub const Proto = CSSNumericValue;

    pub const Type = union(enum) {
        sum: *CSSMathSum,
        product: *CSSMathProduct,
        min: *CSSMathMin,
        max: *CSSMathMax,
        negate: *CSSMathNegate,
        invert: *CSSMathInvert,
        clamp: *CSSMathClamp,
    };

    _proto: *CSSNumericValue,
    _type: Type,

    pub fn getOperator(self: *const CSSMathValue) []const u8 {
        return @tagName(self._type);
    }

    fn args(self: *CSSMathValue) []const *CSSNumericValue {
        return switch (self._type) {
            .sum => |m| m._values._items,
            .product => |m| m._values._items,
            .min => |m| m._values._items,
            .max => |m| m._values._items,
            .negate => |m| m._one[0..],
            .invert => |m| m._one[0..],
            .clamp => |m| m._three[0..],
        };
    }

    fn numericType(self: *CSSMathValue) NumericError!NumericType {
        const values = self.args();
        switch (self._type) {
            .sum, .min, .max, .clamp => {
                var running = try values[0].numericType();
                for (values[1..]) |value| {
                    running = try running.add(try value.numericType());
                }
                return running;
            },
            .product => {
                var running = try values[0].numericType();
                for (values[1..]) |value| {
                    running = try running.multiply(try value.numericType());
                }
                return running;
            },
            .negate => return values[0].numericType(),
            .invert => return (try values[0].numericType()).invert(),
        }
    }

    fn eqlValue(self: *CSSMathValue, other: *CSSMathValue) bool {
        if (std.meta.activeTag(self._type) != std.meta.activeTag(other._type)) return false;
        const mine = self.args();
        const theirs = other.args();
        if (mine.len != theirs.len) return false;
        for (mine, theirs) |a, b| {
            if (!a.eqlValue(b)) return false;
        }
        return true;
    }

    /// `nested` says the caller is already inside a calc(), so the `calc(`
    /// wrapper is dropped and the shape parenthesised by the caller instead.
    fn write(self: *CSSMathValue, writer: *std.Io.Writer, frame: *Frame, nested: bool) SerializeError!void {
        switch (self._type) {
            .min, .max, .clamp => {
                try writer.writeAll(@tagName(self._type));
                try writer.writeAll("(");
                for (self.args(), 0..) |value, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try value.write(writer, frame, false);
                }
                try writer.writeAll(")");
                return;
            },
            else => {},
        }

        if (!nested) try writer.writeAll("calc(");
        switch (self._type) {
            .sum => try self.writeJoined(writer, frame, " + "),
            .product => try self.writeJoined(writer, frame, " * "),
            .negate => {
                try writer.writeAll("-");
                try writeTerm(writer, frame, self.args()[0]);
            },
            .invert => {
                try writer.writeAll("1 / ");
                try writeTerm(writer, frame, self.args()[0]);
            },
            .min, .max, .clamp => unreachable,
        }
        if (!nested) try writer.writeAll(")");
    }

    fn writeJoined(self: *CSSMathValue, writer: *std.Io.Writer, frame: *Frame, separator: []const u8) SerializeError!void {
        for (self.args(), 0..) |value, index| {
            if (index != 0) try writer.writeAll(separator);
            try writeTerm(writer, frame, value);
        }
    }

    fn writeTerm(writer: *std.Io.Writer, frame: *Frame, value: *CSSNumericValue) SerializeError!void {
        if (value.needsParens()) {
            try writer.writeAll("(");
            try value.write(writer, frame, true);
            try writer.writeAll(")");
            return;
        }
        try value.write(writer, frame, true);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSMathValue);

        pub const Meta = struct {
            pub const name = "CSSMathValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const operator = bridge.accessor(CSSMathValue.getOperator, null, .{});
    };
};

/// The four variadic math nodes share everything but their name and tag.
fn VariadicMath(comptime class_name: []const u8, comptime tag: []const u8) type {
    return struct {
        pub const Proto = CSSMathValue;

        const Self = @This();

        _proto: *CSSMathValue,
        _values: *CSSNumericArray,

        pub fn init(values: []const Numberish, frame: *Frame) !*Self {
            // Measured: an empty argument list is a SyntaxError ("Arguments
            // can't be empty"), not a TypeError.
            if (values.len == 0) return error.SyntaxError;
            const resolved = try frame.local_arena.alloc(*CSSNumericValue, values.len);
            for (values, resolved) |raw, *slot| slot.* = try raw.resolve(frame);
            return create(resolved, frame);
        }

        pub fn create(values: []const *CSSNumericValue, frame: *Frame) !*Self {
            if (values.len == 0) return error.SyntaxError;
            // Type-check up front so `new CSSMathSum(1px, 2deg)` throws from
            // the constructor rather than later from a getter.
            var running = try values[0].numericType();
            for (values[1..]) |value| {
                running = if (comptime std.mem.eql(u8, tag, "product"))
                    try running.multiply(try value.numericType())
                else
                    try running.add(try value.numericType());
            }

            const node = try frame._factory.chained(.{
                CSSStyleValue{ ._type = undefined },
                CSSNumericValue{ ._proto = undefined, ._type = undefined },
                CSSMathValue{ ._proto = undefined, ._type = undefined },
                Self{ ._proto = undefined, ._values = try CSSNumericArray.create(values, frame) },
            });
            node._proto._proto._proto._type = .{ .numeric = node._proto._proto };
            node._proto._proto._type = .{ .math = node._proto };
            node._proto._type = @unionInit(CSSMathValue.Type, tag, node);
            return node;
        }

        pub fn getValues(self: *const Self) *CSSNumericArray {
            return self._values;
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = class_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const constructor = bridge.constructor(Self.init, .{ .arity = 0 });
            pub const values = bridge.accessor(Self.getValues, null, .{});
        };
    };
}

pub const CSSMathSum = VariadicMath("CSSMathSum", "sum");
pub const CSSMathProduct = VariadicMath("CSSMathProduct", "product");
pub const CSSMathMin = VariadicMath("CSSMathMin", "min");
pub const CSSMathMax = VariadicMath("CSSMathMax", "max");

/// CSSMathNegate and CSSMathInvert differ only in their tag.
fn UnaryMath(comptime class_name: []const u8, comptime tag: []const u8) type {
    return struct {
        pub const Proto = CSSMathValue;

        const Self = @This();

        _proto: *CSSMathValue,
        _one: [1]*CSSNumericValue,

        pub fn init(raw: Numberish, frame: *Frame) !*Self {
            return create(try raw.resolve(frame), frame);
        }

        pub fn create(value: *CSSNumericValue, frame: *Frame) !*Self {
            const node = try frame._factory.chained(.{
                CSSStyleValue{ ._type = undefined },
                CSSNumericValue{ ._proto = undefined, ._type = undefined },
                CSSMathValue{ ._proto = undefined, ._type = undefined },
                Self{ ._proto = undefined, ._one = .{value} },
            });
            node._proto._proto._proto._type = .{ .numeric = node._proto._proto };
            node._proto._proto._type = .{ .math = node._proto };
            node._proto._type = @unionInit(CSSMathValue.Type, tag, node);
            return node;
        }

        pub fn getValue(self: *const Self) *CSSNumericValue {
            return self._one[0];
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = class_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const constructor = bridge.constructor(Self.init, .{});
            pub const value = bridge.accessor(Self.getValue, null, .{});
        };
    };
}

pub const CSSMathNegate = UnaryMath("CSSMathNegate", "negate");
pub const CSSMathInvert = UnaryMath("CSSMathInvert", "invert");

pub const CSSMathClamp = struct {
    pub const Proto = CSSMathValue;

    _proto: *CSSMathValue,
    _three: [3]*CSSNumericValue,

    pub fn init(lower: Numberish, value: Numberish, upper: Numberish, frame: *Frame) !*CSSMathClamp {
        const three = [3]*CSSNumericValue{
            try lower.resolve(frame),
            try value.resolve(frame),
            try upper.resolve(frame),
        };
        var running = try three[0].numericType();
        for (three[1..]) |member| {
            running = try running.add(try member.numericType());
        }

        const node = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSNumericValue{ ._proto = undefined, ._type = undefined },
            CSSMathValue{ ._proto = undefined, ._type = undefined },
            CSSMathClamp{ ._proto = undefined, ._three = three },
        });
        node._proto._proto._proto._type = .{ .numeric = node._proto._proto };
        node._proto._proto._type = .{ .math = node._proto };
        node._proto._type = .{ .clamp = node };
        return node;
    }

    pub fn getLower(self: *const CSSMathClamp) *CSSNumericValue {
        return self._three[0];
    }

    pub fn getValue(self: *const CSSMathClamp) *CSSNumericValue {
        return self._three[1];
    }

    pub fn getUpper(self: *const CSSMathClamp) *CSSNumericValue {
        return self._three[2];
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSMathClamp);

        pub const Meta = struct {
            pub const name = "CSSMathClamp";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSMathClamp.init, .{});
        pub const lower = bridge.accessor(CSSMathClamp.getLower, null, .{});
        pub const value = bridge.accessor(CSSMathClamp.getValue, null, .{});
        pub const upper = bridge.accessor(CSSMathClamp.getUpper, null, .{});
    };
};

// ---------------------------------------------------------------------------
// CSSUnparsedValue and CSSVariableReferenceValue
// ---------------------------------------------------------------------------

pub const CSSVariableReferenceValue = struct {
    _variable: []const u8,
    _fallback: ?*CSSUnparsedValue,

    pub fn init(variable: []const u8, fallback: ?*CSSUnparsedValue, frame: *Frame) !*CSSVariableReferenceValue {
        if (!isCustomProperty(variable)) return error.TypeError;
        return frame._factory.create(CSSVariableReferenceValue{
            ._variable = try frame.dupeString(variable),
            ._fallback = fallback,
        });
    }

    pub fn getVariable(self: *const CSSVariableReferenceValue) []const u8 {
        return self._variable;
    }

    pub fn setVariable(self: *CSSVariableReferenceValue, variable: []const u8, frame: *Frame) !void {
        if (!isCustomProperty(variable)) return error.TypeError;
        self._variable = try frame.dupeString(variable);
    }

    pub fn getFallback(self: *const CSSVariableReferenceValue) ?*CSSUnparsedValue {
        return self._fallback;
    }

    fn write(self: *CSSVariableReferenceValue, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try writer.print("var({s}", .{self._variable});
        if (self._fallback) |fallback| {
            try writer.writeAll(",");
            try fallback.write(writer, frame);
        }
        try writer.writeAll(")");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSVariableReferenceValue);

        pub const Meta = struct {
            pub const name = "CSSVariableReferenceValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSVariableReferenceValue.init, .{});
        pub const variable = bridge.accessor(CSSVariableReferenceValue.getVariable, CSSVariableReferenceValue.setVariable, .{});
        pub const fallback = bridge.accessor(CSSVariableReferenceValue.getFallback, null, .{});
    };
};

pub const CSSUnparsedValue = struct {
    pub const Proto = CSSStyleValue;

    /// WebIDL `CSSUnparsedSegment`: a string or a variable reference. The
    /// reference comes first so an object matches it before the string
    /// coercion is considered.
    pub const Segment = union(enum) {
        variable: *CSSVariableReferenceValue,
        text: []const u8,
    };

    _proto: *CSSStyleValue,
    _items: []Segment,

    /// Takes the raw value rather than a slice because, measured, a missing
    /// argument is a TypeError while an empty list is fine -- and a slice
    /// parameter cannot tell those two apart.
    pub fn init(members: js.Value, frame: *Frame) !*CSSUnparsedValue {
        if (members.isUndefined()) return error.TypeError;
        return create(try members.toZig([]const Segment), frame);
    }

    pub fn create(members: []const Segment, frame: *Frame) !*CSSUnparsedValue {
        const items = try frame.arena.alloc(Segment, members.len);
        for (members, items) |member, *slot| {
            slot.* = switch (member) {
                .text => |t| .{ .text = try frame.dupeString(t) },
                .variable => |v| .{ .variable = v },
            };
        }
        const value = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSUnparsedValue{ ._proto = undefined, ._items = items },
        });
        value._proto._type = .{ .unparsed = value };
        return value;
    }

    pub fn getLength(self: *const CSSUnparsedValue) u32 {
        return @intCast(self._items.len);
    }

    pub fn item(self: *const CSSUnparsedValue, index: usize) ?Segment {
        if (index >= self._items.len) return null;
        return self._items[index];
    }

    pub fn setItem(self: *CSSUnparsedValue, index: usize, member: Segment, frame: *Frame) !bool {
        if (index >= self._items.len) return false;
        self._items[index] = switch (member) {
            .text => |t| .{ .text = try frame.dupeString(t) },
            .variable => |v| .{ .variable = v },
        };
        return true;
    }

    fn indexes(self: *CSSUnparsedValue, exec: *const Execution) !js.Array {
        return indexArray(self._items.len, exec);
    }

    /// Measured: two adjacent strings serialise with a `/**/` between them so
    /// they cannot merge into a single token.
    fn write(self: *CSSUnparsedValue, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        var previous_text: ?[]const u8 = null;
        for (self._items) |member| {
            switch (member) {
                .text => |text| {
                    // Measured: `['a', 'b']` is `a/**/b` but `['a', ' ', 'b']`
                    // is `a b` -- the comment only goes in when neither side
                    // already has the whitespace that keeps the tokens apart.
                    if (previous_text) |previous| {
                        const left_open = previous.len == 0 or !std.ascii.isWhitespace(previous[previous.len - 1]);
                        const right_open = text.len == 0 or !std.ascii.isWhitespace(text[0]);
                        if (left_open and right_open) try writer.writeAll("/**/");
                    }
                    try writer.writeAll(text);
                    previous_text = text;
                },
                .variable => |variable| {
                    try variable.write(writer, frame);
                    previous_text = null;
                },
            }
        }
    }

    pub fn keys(self: *CSSUnparsedValue, exec: *const Execution) !*KeyIterator {
        return .init(.{ .value = self }, exec);
    }

    pub fn values(self: *CSSUnparsedValue, exec: *const Execution) !*ValueIterator {
        return .init(.{ .value = self }, exec);
    }

    pub fn entries(self: *CSSUnparsedValue, exec: *const Execution) !*EntryIterator {
        return .init(.{ .value = self }, exec);
    }

    pub fn forEach(self: *CSSUnparsedValue, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._items, 0..) |member, index| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ member, index, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        value: *CSSUnparsedValue,

        pub const Entry = struct { u32, Segment };

        pub fn next(self: *Iterator, _: *const Execution) ?Entry {
            const index = self.index;
            const member = self.value.item(index) orelse return null;
            self.index = index + 1;
            return .{ index, member };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSUnparsedValue);

        pub const Meta = struct {
            pub const name = "CSSUnparsedValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSUnparsedValue.init, .{});
        pub const entries = bridge.function(CSSUnparsedValue.entries, .{});
        pub const keys = bridge.function(CSSUnparsedValue.keys, .{});
        pub const values = bridge.function(CSSUnparsedValue.values, .{});
        pub const forEach = bridge.function(CSSUnparsedValue.forEach, .{});
        pub const length = bridge.accessor(CSSUnparsedValue.getLength, null, .{});
        pub const @"[]" = bridge.indexedReadWrite(CSSUnparsedValue.item, CSSUnparsedValue.setItem, null, null, CSSUnparsedValue.indexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(CSSUnparsedValue.values, .{});
    };
};

fn isCustomProperty(name: []const u8) bool {
    return name.len > 2 and name[0] == '-' and name[1] == '-';
}

// ---------------------------------------------------------------------------
// CSSImageValue and CSSPositionValue
// ---------------------------------------------------------------------------

/// Chrome hands one of these back for a `url()` value. It has no members of its
/// own, only the brand and whatever CSSStyleValue.toString prints.
pub const CSSImageValue = struct {
    pub const Proto = CSSStyleValue;

    _proto: *CSSStyleValue,
    _text: []const u8,

    pub fn create(text: []const u8, frame: *Frame) !*CSSImageValue {
        const image = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSImageValue{ ._proto = undefined, ._text = try frame.dupeString(text) },
        });
        image._proto._type = .{ .image = image };
        return image;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSImageValue);

        pub const Meta = struct {
            pub const name = "CSSImageValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const CSSPositionValue = struct {
    pub const Proto = CSSStyleValue;

    _proto: *CSSStyleValue,
    _x: *CSSNumericValue,
    _y: *CSSNumericValue,

    pub fn init(x: *CSSNumericValue, y: *CSSNumericValue, frame: *Frame) !*CSSPositionValue {
        try requireLengthPercent(x);
        try requireLengthPercent(y);
        return create(x, y, frame);
    }

    pub fn create(x: *CSSNumericValue, y: *CSSNumericValue, frame: *Frame) !*CSSPositionValue {
        const position = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSPositionValue{ ._proto = undefined, ._x = x, ._y = y },
        });
        position._proto._type = .{ .position = position };
        return position;
    }

    pub fn getX(self: *const CSSPositionValue) *CSSNumericValue {
        return self._x;
    }

    pub fn setX(self: *CSSPositionValue, x: *CSSNumericValue) !void {
        try requireLengthPercent(x);
        self._x = x;
    }

    pub fn getY(self: *const CSSPositionValue) *CSSNumericValue {
        return self._y;
    }

    pub fn setY(self: *CSSPositionValue, y: *CSSNumericValue) !void {
        try requireLengthPercent(y);
        self._y = y;
    }

    fn write(self: *CSSPositionValue, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try self._x.write(writer, frame, false);
        try writer.writeAll(" ");
        try self._y.write(writer, frame, false);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSPositionValue);

        pub const Meta = struct {
            pub const name = "CSSPositionValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSPositionValue.init, .{});
        pub const x = bridge.accessor(CSSPositionValue.getX, CSSPositionValue.setX, .{});
        pub const y = bridge.accessor(CSSPositionValue.getY, CSSPositionValue.setY, .{});
    };
};

fn requireLengthPercent(value: *CSSNumericValue) !void {
    const numeric_type = try value.numericType();
    const base = numeric_type.onlyBase() orelse return error.TypeError;
    if (numeric_type.get(base) != 1) return error.TypeError;
    if (base != .length and base != .percent) return error.TypeError;
}

fn requireAngle(value: *CSSNumericValue) !void {
    const numeric_type = try value.numericType();
    const base = numeric_type.onlyBase() orelse return error.TypeError;
    if (base != .angle or numeric_type.get(.angle) != 1) return error.TypeError;
}

fn requireNumber(value: *CSSNumericValue) !void {
    const numeric_type = try value.numericType();
    if (numeric_type.onlyBase() != null) return error.TypeError;
}

// ---------------------------------------------------------------------------
// CSSTransformComponent and its eight leaves
// ---------------------------------------------------------------------------

pub const CSSTransformComponent = struct {
    pub const Type = union(enum) {
        translate: *CSSTranslate,
        rotate: *CSSRotate,
        scale: *CSSScale,
        skew: *CSSSkew,
        skew_x: *CSSSkewX,
        skew_y: *CSSSkewY,
        perspective: *CSSPerspective,
        matrix: *CSSMatrixComponent,
    };

    _type: Type,
    _is_2d: bool,

    pub fn getIs2D(self: *const CSSTransformComponent) bool {
        return self._is_2d;
    }

    /// Measured: the three skews ignore the setter and stay 2D, a perspective
    /// ignores it and stays 3D, and the rest follow it.
    pub fn setIs2D(self: *CSSTransformComponent, is_2d: bool) void {
        switch (self._type) {
            .skew, .skew_x, .skew_y => return,
            .perspective => return,
            else => self._is_2d = is_2d,
        }
    }

    pub fn toString(self: *CSSTransformComponent, frame: *Frame) SerializeError![]const u8 {
        var out = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.write(&out.writer, frame);
        return out.written();
    }

    fn write(self: *CSSTransformComponent, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        switch (self._type) {
            .translate => |c| try c.write(writer, frame),
            .rotate => |c| try c.write(writer, frame),
            .scale => |c| try c.write(writer, frame),
            .skew => |c| try c.write(writer, frame),
            .skew_x => |c| try c.write(writer, frame),
            .skew_y => |c| try c.write(writer, frame),
            .perspective => |c| try c.write(writer, frame),
            .matrix => |c| try c.write(writer),
        }
    }

    fn matrix(self: *CSSTransformComponent) ![16]f64 {
        return switch (self._type) {
            .translate => |c| c.matrix(),
            .rotate => |c| c.matrix(),
            .scale => |c| c.matrix(),
            .skew => |c| c.matrix(),
            .skew_x => |c| c.matrix(),
            .skew_y => |c| c.matrix(),
            // Measured: a perspective's toMatrix() is the identity, the 3D
            // term never makes it in.
            .perspective => DOMMatrixReadOnly.identity(),
            .matrix => |c| c._matrix,
        };
    }

    pub fn toMatrix(self: *CSSTransformComponent, frame: *Frame) !*DOMMatrix {
        // Measured: a perspective serialises its matrix as `matrix(1, 0, 0, 1,
        // 0, 0)`, so the matrix it yields is 2D even though the component is not.
        const is_2d = self._is_2d or self._type == .perspective;
        return DOMMatrix.create(try self.matrix(), is_2d, frame._page);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSTransformComponent);

        pub const Meta = struct {
            pub const name = "CSSTransformComponent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const is2D = bridge.accessor(CSSTransformComponent.getIs2D, CSSTransformComponent.setIs2D, .{});
        pub const toMatrix = bridge.function(CSSTransformComponent.toMatrix, .{});
        pub const toString = bridge.function(CSSTransformComponent.toString, .{});
    };
};

fn chainComponent(comptime Leaf: type, comptime tag: []const u8, leaf: Leaf, is_2d: bool, frame: *Frame) !*Leaf {
    const component = try frame._factory.chained(.{
        CSSTransformComponent{ ._type = undefined, ._is_2d = is_2d },
        leaf,
    });
    component._proto._type = @unionInit(CSSTransformComponent.Type, tag, component);
    return component;
}

/// The px value of a length, for the matrix builders. Measured: a non-px
/// length (or a percentage) cannot become a matrix and throws.
fn lengthInPixels(value: *CSSNumericValue) !f64 {
    const unit = value.asUnit() orelse return error.TypeError;
    return CSSNumericValue.convert(unit._value, unit._unit, .px);
}

fn numberOf(value: *CSSNumericValue) !f64 {
    const unit = value.asUnit() orelse return error.TypeError;
    if (unit._unit != .number) return error.TypeError;
    return unit._value;
}

fn degreesOf(value: *CSSNumericValue) !f64 {
    const unit = value.asUnit() orelse return error.TypeError;
    return CSSNumericValue.convert(unit._value, unit._unit, .deg);
}

/// Blink snaps the quarter turns to exact values, so `rotate(90deg)` yields
/// `matrix(0, 1, -1, 0, 0, 0)` rather than leaving a 6.1e-17 cosine behind.
fn sinCosDegrees(degrees: f64) struct { sin: f64, cos: f64 } {
    const wrapped = @mod(degrees, 360.0);
    if (wrapped == 0) return .{ .sin = 0, .cos = 1 };
    if (wrapped == 90) return .{ .sin = 1, .cos = 0 };
    if (wrapped == 180) return .{ .sin = 0, .cos = -1 };
    if (wrapped == 270) return .{ .sin = -1, .cos = 0 };
    const radians = degrees * std.math.pi / 180.0;
    return .{ .sin = @sin(radians), .cos = @cos(radians) };
}

pub const CSSTranslate = struct {
    pub const Proto = CSSTransformComponent;

    _proto: *CSSTransformComponent,
    _x: *CSSNumericValue,
    _y: *CSSNumericValue,
    _z: *CSSNumericValue,

    pub fn init(x: *CSSNumericValue, y: *CSSNumericValue, z_: ?*CSSNumericValue, frame: *Frame) !*CSSTranslate {
        try requireLengthPercent(x);
        try requireLengthPercent(y);
        if (z_) |z| try requireLengthPercent(z);
        const z = z_ orelse (try CSSUnitValue.create(0, .px, frame))._proto;
        return chainComponent(CSSTranslate, "translate", CSSTranslate{
            ._proto = undefined,
            ._x = x,
            ._y = y,
            ._z = z,
        }, z_ == null, frame);
    }

    pub fn getX(self: *const CSSTranslate) *CSSNumericValue {
        return self._x;
    }
    pub fn getY(self: *const CSSTranslate) *CSSNumericValue {
        return self._y;
    }
    pub fn getZ(self: *const CSSTranslate) *CSSNumericValue {
        return self._z;
    }

    pub fn setX(self: *CSSTranslate, x: *CSSNumericValue) !void {
        try requireLengthPercent(x);
        self._x = x;
    }
    pub fn setY(self: *CSSTranslate, y: *CSSNumericValue) !void {
        try requireLengthPercent(y);
        self._y = y;
    }
    /// Measured: assigning z does NOT make the component 3D.
    pub fn setZ(self: *CSSTranslate, z: *CSSNumericValue) !void {
        try requireLengthPercent(z);
        self._z = z;
    }

    fn write(self: *CSSTranslate, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        if (self._proto._is_2d) {
            try writer.writeAll("translate(");
            try self._x.write(writer, frame, false);
            try writer.writeAll(", ");
            try self._y.write(writer, frame, false);
            try writer.writeAll(")");
            return;
        }
        try writer.writeAll("translate3d(");
        try self._x.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._y.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._z.write(writer, frame, false);
        try writer.writeAll(")");
    }

    fn matrix(self: *CSSTranslate) ![16]f64 {
        return DOMMatrixReadOnly.translationMatrix(
            try lengthInPixels(self._x),
            try lengthInPixels(self._y),
            if (self._proto._is_2d) 0 else try lengthInPixels(self._z),
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSTranslate);

        pub const Meta = struct {
            pub const name = "CSSTranslate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSTranslate.init, .{});
        pub const x = bridge.accessor(CSSTranslate.getX, CSSTranslate.setX, .{});
        pub const y = bridge.accessor(CSSTranslate.getY, CSSTranslate.setY, .{});
        pub const z = bridge.accessor(CSSTranslate.getZ, CSSTranslate.setZ, .{});
    };
};

pub const CSSRotate = struct {
    pub const Proto = CSSTransformComponent;

    _proto: *CSSTransformComponent,
    _angle: *CSSNumericValue,
    _x: *CSSNumericValue,
    _y: *CSSNumericValue,
    _z: *CSSNumericValue,

    /// One argument is the 2D form; four are `rotate3d(x, y, z, angle)`.
    pub fn init(first: Numberish, second_: ?Numberish, third_: ?Numberish, fourth_: ?Numberish, frame: *Frame) !*CSSRotate {
        if (second_ == null) {
            const angle = try first.resolve(frame);
            try requireAngle(angle);
            return chainComponent(CSSRotate, "rotate", CSSRotate{
                ._proto = undefined,
                ._angle = angle,
                ._x = (try CSSUnitValue.create(0, .number, frame))._proto,
                ._y = (try CSSUnitValue.create(0, .number, frame))._proto,
                ._z = (try CSSUnitValue.create(1, .number, frame))._proto,
            }, true, frame);
        }

        const second = second_ orelse return error.TypeError;
        const third = third_ orelse return error.TypeError;
        const fourth = fourth_ orelse return error.TypeError;

        const x = try first.resolve(frame);
        const y = try second.resolve(frame);
        const z = try third.resolve(frame);
        const angle = try fourth.resolve(frame);
        try requireNumber(x);
        try requireNumber(y);
        try requireNumber(z);
        try requireAngle(angle);
        return chainComponent(CSSRotate, "rotate", CSSRotate{
            ._proto = undefined,
            ._angle = angle,
            ._x = x,
            ._y = y,
            ._z = z,
        }, false, frame);
    }

    pub fn getAngle(self: *const CSSRotate) *CSSNumericValue {
        return self._angle;
    }
    pub fn getX(self: *const CSSRotate) *CSSNumericValue {
        return self._x;
    }
    pub fn getY(self: *const CSSRotate) *CSSNumericValue {
        return self._y;
    }
    pub fn getZ(self: *const CSSRotate) *CSSNumericValue {
        return self._z;
    }

    pub fn setAngle(self: *CSSRotate, angle: *CSSNumericValue) !void {
        try requireAngle(angle);
        self._angle = angle;
    }
    /// Measured: assigning an axis on a 2D rotate leaves it 2D.
    pub fn setX(self: *CSSRotate, x: Numberish, frame: *Frame) !void {
        const value = try x.resolve(frame);
        try requireNumber(value);
        self._x = value;
    }
    pub fn setY(self: *CSSRotate, y: Numberish, frame: *Frame) !void {
        const value = try y.resolve(frame);
        try requireNumber(value);
        self._y = value;
    }
    pub fn setZ(self: *CSSRotate, z: Numberish, frame: *Frame) !void {
        const value = try z.resolve(frame);
        try requireNumber(value);
        self._z = value;
    }

    fn write(self: *CSSRotate, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        if (self._proto._is_2d) {
            try writer.writeAll("rotate(");
            try self._angle.write(writer, frame, false);
            try writer.writeAll(")");
            return;
        }
        try writer.writeAll("rotate3d(");
        try self._x.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._y.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._z.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._angle.write(writer, frame, false);
        try writer.writeAll(")");
    }

    fn matrix(self: *CSSRotate) ![16]f64 {
        const degrees = try degreesOf(self._angle);
        const trig = sinCosDegrees(degrees);
        if (self._proto._is_2d) {
            return .{
                trig.cos,  trig.sin, 0, 0,
                -trig.sin, trig.cos, 0, 0,
                0,         0,        1, 0,
                0,         0,        0, 1,
            };
        }

        var ax = try numberOf(self._x);
        var ay = try numberOf(self._y);
        var az = try numberOf(self._z);
        const magnitude = @sqrt(ax * ax + ay * ay + az * az);
        if (magnitude == 0) return DOMMatrixReadOnly.identity();
        ax /= magnitude;
        ay /= magnitude;
        az /= magnitude;

        const c = trig.cos;
        const s = trig.sin;
        const t = 1 - c;
        return .{
            t * ax * ax + c,      t * ax * ay + s * az, t * ax * az - s * ay, 0,
            t * ax * ay - s * az, t * ay * ay + c,      t * ay * az + s * ax, 0,
            t * ax * az + s * ay, t * ay * az - s * ax, t * az * az + c,      0,
            0,                    0,                    0,                    1,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSRotate);

        pub const Meta = struct {
            pub const name = "CSSRotate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSRotate.init, .{});
        pub const angle = bridge.accessor(CSSRotate.getAngle, CSSRotate.setAngle, .{});
        pub const x = bridge.accessor(CSSRotate.getX, CSSRotate.setX, .{});
        pub const y = bridge.accessor(CSSRotate.getY, CSSRotate.setY, .{});
        pub const z = bridge.accessor(CSSRotate.getZ, CSSRotate.setZ, .{});
    };
};

pub const CSSScale = struct {
    pub const Proto = CSSTransformComponent;

    _proto: *CSSTransformComponent,
    _x: *CSSNumericValue,
    _y: *CSSNumericValue,
    _z: *CSSNumericValue,

    pub fn init(x_raw: Numberish, y_raw: Numberish, z_: ?Numberish, frame: *Frame) !*CSSScale {
        const x = try x_raw.resolve(frame);
        const y = try y_raw.resolve(frame);
        try requireNumber(x);
        try requireNumber(y);

        var z = (try CSSUnitValue.create(1, .number, frame))._proto;
        if (z_) |z_raw| {
            z = try z_raw.resolve(frame);
            try requireNumber(z);
        }
        return chainComponent(CSSScale, "scale", CSSScale{
            ._proto = undefined,
            ._x = x,
            ._y = y,
            ._z = z,
        }, z_ == null, frame);
    }

    pub fn getX(self: *const CSSScale) *CSSNumericValue {
        return self._x;
    }
    pub fn getY(self: *const CSSScale) *CSSNumericValue {
        return self._y;
    }
    pub fn getZ(self: *const CSSScale) *CSSNumericValue {
        return self._z;
    }

    pub fn setX(self: *CSSScale, x: Numberish, frame: *Frame) !void {
        const value = try x.resolve(frame);
        try requireNumber(value);
        self._x = value;
    }
    pub fn setY(self: *CSSScale, y: Numberish, frame: *Frame) !void {
        const value = try y.resolve(frame);
        try requireNumber(value);
        self._y = value;
    }
    pub fn setZ(self: *CSSScale, z: Numberish, frame: *Frame) !void {
        const value = try z.resolve(frame);
        try requireNumber(value);
        self._z = value;
    }

    fn write(self: *CSSScale, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try writer.writeAll(if (self._proto._is_2d) "scale(" else "scale3d(");
        try self._x.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._y.write(writer, frame, false);
        if (!self._proto._is_2d) {
            try writer.writeAll(", ");
            try self._z.write(writer, frame, false);
        }
        try writer.writeAll(")");
    }

    fn matrix(self: *CSSScale) ![16]f64 {
        return DOMMatrixReadOnly.scaleMatrix(
            try numberOf(self._x),
            try numberOf(self._y),
            if (self._proto._is_2d) 1 else try numberOf(self._z),
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSScale);

        pub const Meta = struct {
            pub const name = "CSSScale";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSScale.init, .{});
        pub const x = bridge.accessor(CSSScale.getX, CSSScale.setX, .{});
        pub const y = bridge.accessor(CSSScale.getY, CSSScale.setY, .{});
        pub const z = bridge.accessor(CSSScale.getZ, CSSScale.setZ, .{});
    };
};

/// The skew matrix is `matrix(1, tan(ay), tan(ax), 1, 0, 0)`; measured, Blink
/// does not snap these, so `tan(45deg)` stays 0.9999999999999999.
fn skewMatrix(ax_degrees: f64, ay_degrees: f64) [16]f64 {
    return .{
        1,                   tangent(ay_degrees), 0, 0,
        tangent(ax_degrees), 1,                   0, 0,
        0,                   0,                   1, 0,
        0,                   0,                   0, 1,
    };
}

/// sin/cos rather than @tan: measured, Zig's @tan is one ulp off V8 for
/// tan(30deg) (…257 against Chrome's …256) while sin/cos agrees on every angle
/// the probes covered.
fn tangent(degrees: f64) f64 {
    const radians = degrees * std.math.pi / 180.0;
    return @sin(radians) / @cos(radians);
}

pub const CSSSkew = struct {
    pub const Proto = CSSTransformComponent;

    _proto: *CSSTransformComponent,
    _ax: *CSSNumericValue,
    _ay: *CSSNumericValue,

    pub fn init(ax: *CSSNumericValue, ay: *CSSNumericValue, frame: *Frame) !*CSSSkew {
        try requireAngle(ax);
        try requireAngle(ay);
        return chainComponent(CSSSkew, "skew", CSSSkew{ ._proto = undefined, ._ax = ax, ._ay = ay }, true, frame);
    }

    pub fn getAx(self: *const CSSSkew) *CSSNumericValue {
        return self._ax;
    }
    pub fn getAy(self: *const CSSSkew) *CSSNumericValue {
        return self._ay;
    }
    pub fn setAx(self: *CSSSkew, ax: *CSSNumericValue) !void {
        try requireAngle(ax);
        self._ax = ax;
    }
    pub fn setAy(self: *CSSSkew, ay: *CSSNumericValue) !void {
        try requireAngle(ay);
        self._ay = ay;
    }

    fn write(self: *CSSSkew, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try writer.writeAll("skew(");
        try self._ax.write(writer, frame, false);
        try writer.writeAll(", ");
        try self._ay.write(writer, frame, false);
        try writer.writeAll(")");
    }

    fn matrix(self: *CSSSkew) ![16]f64 {
        return skewMatrix(try degreesOf(self._ax), try degreesOf(self._ay));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSSkew);

        pub const Meta = struct {
            pub const name = "CSSSkew";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSSkew.init, .{});
        pub const ax = bridge.accessor(CSSSkew.getAx, CSSSkew.setAx, .{});
        pub const ay = bridge.accessor(CSSSkew.getAy, CSSSkew.setAy, .{});
    };
};

pub const CSSSkewX = struct {
    pub const Proto = CSSTransformComponent;

    _proto: *CSSTransformComponent,
    _ax: *CSSNumericValue,

    pub fn init(ax: *CSSNumericValue, frame: *Frame) !*CSSSkewX {
        try requireAngle(ax);
        return chainComponent(CSSSkewX, "skew_x", CSSSkewX{ ._proto = undefined, ._ax = ax }, true, frame);
    }

    pub fn getAx(self: *const CSSSkewX) *CSSNumericValue {
        return self._ax;
    }
    pub fn setAx(self: *CSSSkewX, ax: *CSSNumericValue) !void {
        try requireAngle(ax);
        self._ax = ax;
    }

    fn write(self: *CSSSkewX, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try writer.writeAll("skewX(");
        try self._ax.write(writer, frame, false);
        try writer.writeAll(")");
    }

    fn matrix(self: *CSSSkewX) ![16]f64 {
        return skewMatrix(try degreesOf(self._ax), 0);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSSkewX);

        pub const Meta = struct {
            pub const name = "CSSSkewX";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSSkewX.init, .{});
        pub const ax = bridge.accessor(CSSSkewX.getAx, CSSSkewX.setAx, .{});
    };
};

pub const CSSSkewY = struct {
    pub const Proto = CSSTransformComponent;

    _proto: *CSSTransformComponent,
    _ay: *CSSNumericValue,

    pub fn init(ay: *CSSNumericValue, frame: *Frame) !*CSSSkewY {
        try requireAngle(ay);
        return chainComponent(CSSSkewY, "skew_y", CSSSkewY{ ._proto = undefined, ._ay = ay }, true, frame);
    }

    pub fn getAy(self: *const CSSSkewY) *CSSNumericValue {
        return self._ay;
    }
    pub fn setAy(self: *CSSSkewY, ay: *CSSNumericValue) !void {
        try requireAngle(ay);
        self._ay = ay;
    }

    fn write(self: *CSSSkewY, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try writer.writeAll("skewY(");
        try self._ay.write(writer, frame, false);
        try writer.writeAll(")");
    }

    fn matrix(self: *CSSSkewY) ![16]f64 {
        return skewMatrix(0, try degreesOf(self._ay));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSSkewY);

        pub const Meta = struct {
            pub const name = "CSSSkewY";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSSkewY.init, .{});
        pub const ay = bridge.accessor(CSSSkewY.getAy, CSSSkewY.setAy, .{});
    };
};

pub const CSSPerspective = struct {
    pub const Proto = CSSTransformComponent;

    /// Measured: the length may be the keyword `none`, and `p.length` hands
    /// that keyword straight back.
    pub const Length = union(enum) {
        numeric: *CSSNumericValue,
        keyword: *CSSKeywordValue,
    };

    _proto: *CSSTransformComponent,
    _length: Length,

    pub fn init(length: Length, frame: *Frame) !*CSSPerspective {
        try validate(length);
        // Measured: a perspective is never 2D.
        return chainComponent(CSSPerspective, "perspective", CSSPerspective{
            ._proto = undefined,
            ._length = length,
        }, false, frame);
    }

    fn validate(length: Length) !void {
        switch (length) {
            .numeric => |numeric| {
                const numeric_type = try numeric.numericType();
                const base = numeric_type.onlyBase() orelse return error.TypeError;
                if (base != .length or numeric_type.get(.length) != 1) return error.TypeError;
            },
            .keyword => |keyword| {
                if (!std.ascii.eqlIgnoreCase(keyword._value, "none")) return error.TypeError;
            },
        }
    }

    pub fn getLength(self: *const CSSPerspective) Length {
        return self._length;
    }

    pub fn setLength(self: *CSSPerspective, length: Length) !void {
        try validate(length);
        self._length = length;
    }

    fn write(self: *CSSPerspective, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        try writer.writeAll("perspective(");
        switch (self._length) {
            .numeric => |numeric| try numeric.write(writer, frame, false),
            .keyword => |keyword| try keyword.write(writer, frame),
        }
        try writer.writeAll(")");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSPerspective);

        pub const Meta = struct {
            pub const name = "CSSPerspective";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSPerspective.init, .{});
        pub const length = bridge.accessor(CSSPerspective.getLength, CSSPerspective.setLength, .{});
    };
};

pub const CSSMatrixComponent = struct {
    pub const Proto = CSSTransformComponent;

    pub const Options = struct { is2D: ?bool = null };

    _proto: *CSSTransformComponent,
    _matrix: [16]f64,

    pub fn init(matrix: *DOMMatrixReadOnly, options_: ?Options, frame: *Frame) !*CSSMatrixComponent {
        const state = matrix.getState();
        const options = options_ orelse Options{};
        return chainComponent(CSSMatrixComponent, "matrix", CSSMatrixComponent{
            ._proto = undefined,
            ._matrix = state.matrix,
        }, options.is2D orelse state.is_2d, frame);
    }

    /// Measured: the component copies the matrix, so neither `matrix` nor
    /// `toMatrix()` is the object that was handed in.
    pub fn getMatrix(self: *CSSMatrixComponent, frame: *Frame) !*DOMMatrix {
        return DOMMatrix.create(self._matrix, self._proto._is_2d, frame._page);
    }

    pub fn setMatrix(self: *CSSMatrixComponent, matrix: *DOMMatrixReadOnly) !void {
        const state = matrix.getState();
        self._matrix = state.matrix;
        self._proto._is_2d = state.is_2d;
    }

    fn write(self: *CSSMatrixComponent, writer: *std.Io.Writer) SerializeError!void {
        if (self._proto._is_2d) {
            try writer.writeAll("matrix(");
            const order = [_]usize{ 0, 1, 4, 5, 12, 13 };
            for (order, 0..) |index, position| {
                if (position != 0) try writer.writeAll(", ");
                try writeMatrixNumber(writer, self._matrix[index]);
            }
            try writer.writeAll(")");
            return;
        }
        try writer.writeAll("matrix3d(");
        for (self._matrix, 0..) |value, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeMatrixNumber(writer, value);
        }
        try writer.writeAll(")");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSMatrixComponent);

        pub const Meta = struct {
            pub const name = "CSSMatrixComponent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSMatrixComponent.init, .{});
        pub const matrix = bridge.accessor(CSSMatrixComponent.getMatrix, CSSMatrixComponent.setMatrix, .{});
    };
};

/// Matrices serialise at full double precision, unlike the %g the numeric
/// values use: measured, `skewX(45deg).toMatrix()` prints
/// `matrix(1, 0, 0.9999999999999999, 1, 0, 0)`.
fn writeMatrixNumber(writer: *std.Io.Writer, value: f64) SerializeError!void {
    if (value == 0) return writer.writeAll("0");
    try writer.print("{d}", .{value});
}

// ---------------------------------------------------------------------------
// CSSTransformValue
// ---------------------------------------------------------------------------

pub const CSSTransformValue = struct {
    pub const Proto = CSSStyleValue;

    _proto: *CSSStyleValue,
    _items: std.ArrayList(*CSSTransformComponent),

    pub fn init(components: []const *CSSTransformComponent, frame: *Frame) !*CSSTransformValue {
        // Measured: both a missing argument and an empty list are TypeErrors,
        // and both arrive here as an empty slice.
        if (components.len == 0) return error.TypeError;
        return create(components, frame);
    }

    pub fn create(components: []const *CSSTransformComponent, frame: *Frame) !*CSSTransformValue {
        var items: std.ArrayList(*CSSTransformComponent) = .empty;
        try items.appendSlice(frame.arena, components);
        const value = try frame._factory.chained(.{
            CSSStyleValue{ ._type = undefined },
            CSSTransformValue{ ._proto = undefined, ._items = items },
        });
        value._proto._type = .{ .transform = value };
        return value;
    }

    pub fn getLength(self: *const CSSTransformValue) u32 {
        return @intCast(self._items.items.len);
    }

    /// Measured: is2D is read-only here and is false as soon as any component
    /// is 3D.
    pub fn getIs2D(self: *const CSSTransformValue) bool {
        for (self._items.items) |component| {
            if (!component._is_2d) return false;
        }
        return true;
    }

    pub fn item(self: *const CSSTransformValue, index: usize) ?*CSSTransformComponent {
        if (index >= self._items.items.len) return null;
        return self._items.items[index];
    }

    pub fn setItem(self: *CSSTransformValue, index: usize, component: *CSSTransformComponent, frame: *Frame) !bool {
        if (index < self._items.items.len) {
            self._items.items[index] = component;
            return true;
        }
        // Measured: writing past the end appends rather than throwing.
        try self._items.append(frame.arena, component);
        return true;
    }

    fn indexes(self: *CSSTransformValue, exec: *const Execution) !js.Array {
        return indexArray(self._items.items.len, exec);
    }

    pub fn toMatrix(self: *CSSTransformValue, frame: *Frame) !*DOMMatrix {
        var product = DOMMatrixReadOnly.identity();
        var is_2d = true;
        for (self._items.items) |component| {
            product = DOMMatrixReadOnly.multiplyMatrix(product, try component.matrix());
            if (!component._is_2d) is_2d = false;
        }
        return DOMMatrix.create(product, is_2d, frame._page);
    }

    fn write(self: *CSSTransformValue, writer: *std.Io.Writer, frame: *Frame) SerializeError!void {
        for (self._items.items, 0..) |component, index| {
            if (index != 0) try writer.writeAll(" ");
            try component.write(writer, frame);
        }
    }

    pub fn keys(self: *CSSTransformValue, exec: *const Execution) !*KeyIterator {
        return .init(.{ .value = self }, exec);
    }

    pub fn values(self: *CSSTransformValue, exec: *const Execution) !*ValueIterator {
        return .init(.{ .value = self }, exec);
    }

    pub fn entries(self: *CSSTransformValue, exec: *const Execution) !*EntryIterator {
        return .init(.{ .value = self }, exec);
    }

    pub fn forEach(self: *CSSTransformValue, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._items.items, 0..) |component, index| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ component, index, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        value: *CSSTransformValue,

        pub const Entry = struct { u32, *CSSTransformComponent };

        pub fn next(self: *Iterator, _: *const Execution) ?Entry {
            const index = self.index;
            const component = self.value.item(index) orelse return null;
            self.index = index + 1;
            return .{ index, component };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSTransformValue);

        pub const Meta = struct {
            pub const name = "CSSTransformValue";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CSSTransformValue.init, .{});
        pub const entries = bridge.function(CSSTransformValue.entries, .{});
        pub const keys = bridge.function(CSSTransformValue.keys, .{});
        pub const values = bridge.function(CSSTransformValue.values, .{});
        pub const forEach = bridge.function(CSSTransformValue.forEach, .{});
        pub const length = bridge.accessor(CSSTransformValue.getLength, null, .{});
        pub const is2D = bridge.accessor(CSSTransformValue.getIs2D, null, .{});
        pub const toMatrix = bridge.function(CSSTransformValue.toMatrix, .{});
        pub const @"[]" = bridge.indexedReadWrite(CSSTransformValue.item, CSSTransformValue.setItem, null, null, CSSTransformValue.indexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(CSSTransformValue.values, .{});
    };
};

// ---------------------------------------------------------------------------
// Value -> subclass dispatch
// ---------------------------------------------------------------------------

/// The properties Blink's Typed OM does not model. Measured by sweeping all 474
/// computed longhands on a headed Chrome 150 (probe-css9.js) and keeping the
/// ones that answered a bare CSSStyleValue: every one of them answers
/// CSSStyleValue whatever value it holds, so `color: red` stays a
/// CSSStyleValue where `display: block` becomes a CSSKeywordValue.
const unsupported_properties = [_][]const u8{
    "-webkit-border-horizontal-spacing",       "-webkit-border-image",              "-webkit-border-vertical-spacing",     "-webkit-box-align",
    "-webkit-box-decoration-break",            "-webkit-box-direction",             "-webkit-box-flex",                    "-webkit-box-ordinal-group",
    "-webkit-box-orient",                      "-webkit-box-pack",                  "-webkit-box-reflect",                 "-webkit-font-smoothing",
    "-webkit-line-break",                      "-webkit-line-clamp",                "-webkit-locale",                      "-webkit-mask-box-image",
    "-webkit-mask-box-image-outset",           "-webkit-mask-box-image-repeat",     "-webkit-mask-box-image-slice",        "-webkit-mask-box-image-source",
    "-webkit-mask-box-image-width",            "-webkit-mask-position-x",           "-webkit-mask-position-y",             "-webkit-rtl-ordering",
    "-webkit-ruby-position",                   "-webkit-tap-highlight-color",       "-webkit-text-combine",                "-webkit-text-decorations-in-effect",
    "-webkit-text-fill-color",                 "-webkit-text-orientation",          "-webkit-text-security",               "-webkit-text-stroke-color",
    "-webkit-text-stroke-width",               "-webkit-user-drag",                 "-webkit-user-modify",                 "-webkit-writing-mode",
    "align-content",                           "align-items",                       "align-self",                          "animation-range-end",
    "animation-range-start",                   "animation-trigger",                 "app-region",                          "appearance",
    "aspect-ratio",                            "background-color",                  "background-position",                 "background-repeat",
    "border-block-end-color",                  "border-block-end-style",            "border-block-end-width",              "border-block-start-color",
    "border-block-start-style",                "border-block-start-width",          "border-bottom-color",                 "border-image-outset",
    "border-image-repeat",                     "border-image-slice",                "border-image-width",                  "border-inline-end-color",
    "border-inline-end-style",                 "border-inline-end-width",           "border-inline-start-color",           "border-inline-start-style",
    "border-inline-start-width",               "border-left-color",                 "border-right-color",                  "border-top-color",
    "box-decoration-break",                    "buffered-rendering",                "caret-color",                         "color",
    "color-scheme",                            "column-rule-color",                 "column-rule-style",                   "column-rule-width",
    "contain-intrinsic-height",                "contain-intrinsic-size",            "contain-intrinsic-width",             "content",
    "corner-bottom-left-shape",                "corner-bottom-right-shape",         "corner-end-end-shape",                "corner-end-start-shape",
    "corner-start-end-shape",                  "corner-start-start-shape",          "corner-top-left-shape",               "corner-top-right-shape",
    "fill",                                    "flood-color",                       "font-family",                         "font-variant",
    "hyphenate-character",                     "hyphenate-limit-chars",             "image-orientation",                   "initial-letter",
    "interest-delay-end",                      "interest-delay-start",              "justify-content",                     "justify-items",
    "justify-self",                            "lighting-color",                    "list-style-type",                     "mask-clip",
    "mask-composite",                          "mask-image",                        "mask-mode",                           "mask-origin",
    "mask-position",                           "mask-repeat",                       "mask-size",                           "offset-rotate",
    "outline-color",                           "overflow-block",                    "overflow-clip-margin",                "overflow-inline",
    "overscroll-behavior-block",               "overscroll-behavior-inline",        "position-visibility",                 "print-color-adjust",
    "rotate",                                  "row-rule-color",                    "row-rule-style",                      "row-rule-width",
    "ruby-align",                              "ruby-position",                     "scale",                               "scroll-initial-target",
    "scroll-snap-align",                       "scroll-timeline-axis",              "scroll-timeline-name",                "scrollbar-color",
    "speak",                                   "stop-color",                        "stroke",                              "text-box-edge",
    "text-decoration",                         "text-decoration-color",             "text-emphasis-color",                 "text-emphasis-position",
    "text-emphasis-style",                     "text-fit",                          "timeline-scope",                      "timeline-trigger-activation-range-end",
    "timeline-trigger-activation-range-start", "timeline-trigger-active-range-end", "timeline-trigger-active-range-start", "timeline-trigger-name",
    "transform-origin",                        "translate",                         "view-timeline-axis",                  "view-timeline-inset",
    "view-timeline-name",                      "zoom",
};

/// Measured: only these two answer a CSSPositionValue.
const position_properties = [_][]const u8{ "object-position", "perspective-origin" };

fn isUnsupported(property: []const u8) bool {
    for (unsupported_properties) |name| {
        if (std.mem.eql(u8, name, property)) return true;
    }
    return false;
}

fn isPositionProperty(property: []const u8) bool {
    for (position_properties) |name| {
        if (std.mem.eql(u8, name, property)) return true;
    }
    return false;
}

fn isComputedLonghand(property: []const u8) bool {
    for (@import("chrome_properties.zig").computed) |name| {
        if (std.mem.eql(u8, name, property)) return true;
    }
    return false;
}

/// Whether a style map answers this name at all. A name Chrome has never heard
/// of is a TypeError from every accessor, not a null.
pub fn isKnownProperty(property: []const u8) bool {
    if (isCustomProperty(property)) return true;
    if (isComputedLonghand(property)) return true;
    return CSSStyleDeclaration.isKnownPropertyName(property);
}

/// The subclass a value string maps onto. Reproduces every one of the 474
/// computed longhands measured in probe-css9.js plus the explicit-value cases
/// in probe-css10.js; see the module docs for the two rows that do not match.
pub fn dispatch(property: []const u8, value: []const u8, frame: *Frame) !*CSSStyleValue {
    if (isCustomProperty(property)) {
        // Measured: the segment is the trimmed value -- `--v: " 1px "` yields
        // a CSSUnparsedValue that prints `1px`.
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const unparsed = try CSSUnparsedValue.create(&.{.{ .text = trimmed }}, frame);
        return unparsed._proto;
    }
    // A shorthand (and anything that is not a computed longhand) is not
    // modelled, exactly as Blink leaves it.
    if (!isComputedLonghand(property) or isUnsupported(property)) {
        return CSSStyleValue.init(value, frame);
    }
    if (isPositionProperty(property)) {
        if (parsePosition(value, frame)) |position| return position._proto;
        return CSSStyleValue.init(value, frame);
    }
    if (std.mem.startsWith(u8, value, "url(")) {
        return (try CSSImageValue.create(value, frame))._proto;
    }
    if (std.mem.eql(u8, property, "transform")) {
        if (try parseTransformList(value, frame)) |transform| return transform._proto;
    }
    if (CSSNumericValue.parseDimension(value)) |dimension| {
        const unit = try CSSUnitValue.create(dimension.value, dimension.unit, frame);
        return unit._proto._proto;
    }
    if (isIdentifier(value)) {
        return (try CSSKeywordValue.create(value, frame))._proto;
    }
    return CSSStyleValue.init(value, frame);
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    while (index < value.len and value[index] == '-' and index < 2) index += 1;
    if (index >= value.len) return false;
    if (!std.ascii.isAlphabetic(value[index]) and value[index] != '_') return false;
    for (value[index..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn parsePosition(value: []const u8, frame: *Frame) ?*CSSPositionValue {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    const x_text = it.next() orelse return null;
    const y_text = it.next() orelse return null;
    if (it.next() != null) return null;
    const x = CSSNumericValue.parseDimension(x_text) orelse return null;
    const y = CSSNumericValue.parseDimension(y_text) orelse return null;
    const x_value = (CSSUnitValue.create(x.value, x.unit, frame) catch return null)._proto;
    const y_value = (CSSUnitValue.create(y.value, y.unit, frame) catch return null)._proto;
    return CSSPositionValue.create(x_value, y_value, frame) catch null;
}

/// Only the transform functions Chrome was measured turning into components.
/// A `transform` value it cannot model (or the keyword `none`) falls through to
/// the keyword/CSSStyleValue arms of `dispatch`.
fn parseTransformList(value: []const u8, frame: *Frame) !?*CSSTransformValue {
    var components: std.ArrayList(*CSSTransformComponent) = .empty;
    var index: usize = 0;
    while (index < value.len) {
        while (index < value.len and (value[index] == ' ' or value[index] == '\t')) index += 1;
        if (index >= value.len) break;
        const open = std.mem.indexOfScalarPos(u8, value, index, '(') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, value, open, ')') orelse return null;
        const name = std.mem.trim(u8, value[index..open], " \t");
        const args = value[open + 1 .. close];
        index = close + 1;

        const component = (try buildComponent(name, args, frame)) orelse return null;
        try components.append(frame.local_arena, component);
    }
    if (components.items.len == 0) return null;
    return try CSSTransformValue.create(components.items, frame);
}

fn buildComponent(name: []const u8, args: []const u8, frame: *Frame) !?*CSSTransformComponent {
    var numbers: std.ArrayList(CSSNumericValue.Dimension) = .empty;
    var it = std.mem.splitScalar(u8, args, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        const dimension = CSSNumericValue.parseDimension(trimmed) orelse return null;
        try numbers.append(frame.local_arena, dimension);
    }
    const items = numbers.items;
    const unit = struct {
        fn make(d: CSSNumericValue.Dimension, f: *Frame) !*CSSNumericValue {
            return (try CSSUnitValue.create(d.value, d.unit, f))._proto;
        }
    }.make;

    if (std.mem.eql(u8, name, "translate") and (items.len == 1 or items.len == 2)) {
        const y = if (items.len == 2) try unit(items[1], frame) else (try CSSUnitValue.create(0, .px, frame))._proto;
        return (try CSSTranslate.init(try unit(items[0], frame), y, null, frame))._proto;
    }
    if (std.mem.eql(u8, name, "translate3d") and items.len == 3) {
        return (try CSSTranslate.init(try unit(items[0], frame), try unit(items[1], frame), try unit(items[2], frame), frame))._proto;
    }
    if (std.mem.eql(u8, name, "scale") and (items.len == 1 or items.len == 2)) {
        const second = if (items.len == 2) items[1] else items[0];
        return (try CSSScale.init(
            .{ .numeric = try unit(items[0], frame) },
            .{ .numeric = try unit(second, frame) },
            null,
            frame,
        ))._proto;
    }
    if (std.mem.eql(u8, name, "scale3d") and items.len == 3) {
        return (try CSSScale.init(
            .{ .numeric = try unit(items[0], frame) },
            .{ .numeric = try unit(items[1], frame) },
            .{ .numeric = try unit(items[2], frame) },
            frame,
        ))._proto;
    }
    if (std.mem.eql(u8, name, "rotate") and items.len == 1) {
        return (try CSSRotate.init(.{ .numeric = try unit(items[0], frame) }, null, null, null, frame))._proto;
    }
    if (std.mem.eql(u8, name, "skew") and (items.len == 1 or items.len == 2)) {
        const second = if (items.len == 2) try unit(items[1], frame) else (try CSSUnitValue.create(0, .deg, frame))._proto;
        return (try CSSSkew.init(try unit(items[0], frame), second, frame))._proto;
    }
    if (std.mem.eql(u8, name, "skewX") and items.len == 1) {
        return (try CSSSkewX.init(try unit(items[0], frame), frame))._proto;
    }
    if (std.mem.eql(u8, name, "skewY") and items.len == 1) {
        return (try CSSSkewY.init(try unit(items[0], frame), frame))._proto;
    }
    if (std.mem.eql(u8, name, "perspective") and items.len == 1) {
        return (try CSSPerspective.init(.{ .numeric = try unit(items[0], frame) }, frame))._proto;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The style maps
// ---------------------------------------------------------------------------

pub const StylePropertyMapReadOnly = struct {
    pub const Type = union(enum) {
        read_only: void,
        writable: *StylePropertyMap,
    };

    _type: Type = .read_only,
    _style: *CSSStyleDeclaration,
    // The iterators reach values through here: their `next` only receives an
    // Execution, which cannot reach a Frame.
    _frame: *Frame,

    pub fn init(style: *CSSStyleDeclaration, frame: *Frame) !*StylePropertyMapReadOnly {
        return frame._factory.create(StylePropertyMapReadOnly{ ._style = style, ._frame = frame });
    }

    /// Measured: the size is the declaration's own property count — 474 for a
    /// computed view, one per declared property for an inline style.
    pub fn getSize(self: *const StylePropertyMapReadOnly) u32 {
        return self._style.length();
    }

    pub fn has(self: *StylePropertyMapReadOnly, property: []const u8) !bool {
        if (!isKnownProperty(property)) return error.TypeError;
        return (try self.get(property)) != null;
    }

    pub fn get(self: *StylePropertyMapReadOnly, property: []const u8) !?*CSSStyleValue {
        if (!isKnownProperty(property)) return error.TypeError;
        const frame = self._frame;
        const value = self._style.getPropertyValue(property, frame);
        if (value.len == 0) return null;
        // frame.arena, not local_arena: the value outlives this call.
        return dispatch(property, try frame.arena.dupe(u8, value), frame);
    }

    /// A property can hold a list of values, so getAll returns a sequence where
    /// get returns one. Measured: entries() and values() yield these sequences,
    /// not bare values.
    pub fn getAll(self: *StylePropertyMapReadOnly, property: []const u8) ![]const *CSSStyleValue {
        const single = try self.get(property) orelse return &.{};
        const list = try self._frame.local_arena.alloc(*CSSStyleValue, 1);
        list[0] = single;
        return list;
    }

    pub fn keys(self: *StylePropertyMapReadOnly, exec: *const Execution) !*KeyIterator {
        return .init(.{ .map = self }, exec);
    }

    pub fn values(self: *StylePropertyMapReadOnly, exec: *const Execution) !*ValueIterator {
        return .init(.{ .map = self }, exec);
    }

    pub fn entries(self: *StylePropertyMapReadOnly, exec: *const Execution) !*EntryIterator {
        return .init(.{ .map = self }, exec);
    }

    pub fn forEach(self: *StylePropertyMapReadOnly, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        const count = self._style.length();
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const name = self._style.item(index);
            const list = try self.getAll(name);
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ list, name, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        map: *StylePropertyMapReadOnly,

        pub const Entry = struct { []const u8, []const *CSSStyleValue };

        pub fn next(self: *Iterator, _: *const Execution) !?Iterator.Entry {
            const index = self.index;
            if (index >= self.map._style.length()) return null;
            self.index = index + 1;
            const name = self.map._style.item(index);
            return .{ name, try self.map.getAll(name) };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StylePropertyMapReadOnly);

        pub const Meta = struct {
            pub const name = "StylePropertyMapReadOnly";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const size = bridge.accessor(StylePropertyMapReadOnly.getSize, null, .{});
        pub const get = bridge.function(StylePropertyMapReadOnly.get, .{ .null_as_undefined = true });
        pub const getAll = bridge.function(StylePropertyMapReadOnly.getAll, .{});
        pub const has = bridge.function(StylePropertyMapReadOnly.has, .{});
        pub const entries = bridge.function(StylePropertyMapReadOnly.entries, .{});
        pub const forEach = bridge.function(StylePropertyMapReadOnly.forEach, .{});
        pub const keys = bridge.function(StylePropertyMapReadOnly.keys, .{});
        pub const values = bridge.function(StylePropertyMapReadOnly.values, .{});
        pub const symbol_iterator = bridge.iterator(StylePropertyMapReadOnly.entries, .{});
    };
};

pub const StylePropertyMap = struct {
    pub const Proto = StylePropertyMapReadOnly;

    /// A value handed to `set`: a typed value or the string form.
    pub const Value = union(enum) {
        typed: *CSSStyleValue,
        text: []const u8,
    };

    _proto: *StylePropertyMapReadOnly,

    pub fn init(style: *CSSStyleDeclaration, frame: *Frame) !*StylePropertyMap {
        const map = try frame._factory.chained(.{
            StylePropertyMapReadOnly{ ._type = undefined, ._style = style, ._frame = frame },
            StylePropertyMap{ ._proto = undefined },
        });
        map._proto._type = .{ .writable = map };
        return map;
    }

    /// Measured: Blink has no list-valued append for any property, so this
    /// always throws — with a different message for a custom property, but the
    /// same TypeError.
    pub fn append(_: *StylePropertyMap, property: []const u8, _: []const Value) !void {
        if (!isCustomProperty(property) and !isKnownProperty(property)) return error.TypeError;
        return error.TypeError;
    }

    /// Measured: clear() empties the style attribute but leaves it in place.
    pub fn clear(self: *StylePropertyMap, frame: *Frame) !void {
        try self._proto._style.setCssText("", frame);
    }

    pub fn delete(self: *StylePropertyMap, property: []const u8, frame: *Frame) !void {
        if (!isKnownProperty(property)) return error.TypeError;
        _ = try self._proto._style.removeProperty(property, frame);
    }

    pub fn set(self: *StylePropertyMap, property: []const u8, values: []const Value, frame: *Frame) !void {
        if (!isKnownProperty(property)) return error.TypeError;
        // Measured: a missing value is "Invalid type for property", a TypeError.
        if (values.len != 1) return error.TypeError;
        const text = switch (values[0]) {
            .text => |t| t,
            .typed => |typed| try typed.toString(frame),
        };
        try self.validateFor(property, values[0], frame);
        try self._proto._style.setProperty(property, text, null, frame);
    }

    /// Measured: `set('left', CSS.deg(3))` is "Invalid type for property". Only
    /// the numeric case can be checked without per-property grammars, which is
    /// where Chrome's check lives.
    fn validateFor(_: *StylePropertyMap, property: []const u8, value: Value, frame: *Frame) !void {
        const typed = switch (value) {
            .text => return,
            .typed => |t| t,
        };
        const numeric = switch (typed._type) {
            .numeric => |n| n,
            else => return,
        };
        const current = frame.local_arena.dupe(u8, "0px") catch return;
        _ = current;
        const numeric_type = try numeric.numericType();
        const base = numeric_type.onlyBase() orelse return;
        if (base == .angle and isLengthProperty(property)) return error.TypeError;
    }

    fn isLengthProperty(property: []const u8) bool {
        const names = [_][]const u8{
            "width",         "height",         "top",          "left",          "right",       "bottom",
            "margin-top",    "margin-left",    "margin-right", "margin-bottom", "padding-top", "padding-left",
            "padding-right", "padding-bottom", "min-width",    "min-height",    "max-width",   "max-height",
        };
        for (names) |name| {
            if (std.mem.eql(u8, name, property)) return true;
        }
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StylePropertyMap);

        pub const Meta = struct {
            pub const name = "StylePropertyMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const append = bridge.function(StylePropertyMap.append, .{ .arity = 1 });
        pub const clear = bridge.function(StylePropertyMap.clear, .{});
        pub const delete = bridge.function(StylePropertyMap.delete, .{});
        pub const set = bridge.function(StylePropertyMap.set, .{ .arity = 1 });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: CSS Typed OM" {
    try testing.htmlRunner("css/typed_om.html", .{});
}
