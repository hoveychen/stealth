// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
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

//! `CSS.registerProperty` and the registry it fills.
//!
//! The name was one of two deliberately missing from the CSS namespace object,
//! on the grounds that a registration a page can make and the cascade ignores
//! is its own kind of lie. So the bar it had to clear was the cascade, and a
//! registration changes four things a page can see -- all four measured on
//! Chrome 151 with scratch/b80/registered.mjs and scratch/b80/q6.js:
//!
//!   * the property has a computed value on every element, even one that never
//!     declared it, so `getComputedStyle(el)` enumerates it;
//!   * the value is computed per the registered syntax: `<length>` resolves
//!     `2em` against the element's font to `20px` and `1in` to `96px`,
//!     `<color>` serialises `red` to `rgb(255, 0, 0)`, `<angle>` turns
//!     `0.5turn` into `180deg`, `<time>` `500ms` into `0.5s`, `<resolution>`
//!     `96dpi` into `1dppx`, and a `calc()` is folded;
//!   * a declared value that does not parse for the syntax is invalid at
//!     computed-value time and falls back to the initial value;
//!   * `inherits: false` stops a child seeing the parent's declaration -- it
//!     sees the initial value instead.
//!
//! The initial value is computed once, at registration, because it has to be
//! *computationally independent*: `initialValue: '2em'` is refused outright
//! (measured), which is exactly what makes one stored string enough for every
//! element.
//!
//! Two component types are accepted and passed through rather than computed:
//! `<image>` and the two transform types. Chrome resolves an `<image>`'s url
//! and normalises a transform list; here they reach the computed value as
//! written, and a value that is not one of them at all is not refused. Every
//! other type in the grammar is checked.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Element = @import("../Element.zig");
const StyleManager = @import("../../StyleManager.zig");
const URL = @import("../../URL.zig");
const calc = @import("calc.zig");
const color = @import("../../color.zig");
const dictionary = @import("../dictionary.zig");
const units = @import("../../css/units.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

/// One `|`-separated alternative of a syntax string.
const Component = struct {
    kind: Kind,
    multiplier: Multiplier,
    /// The identifier itself, for `.literal`.
    literal: []const u8 = "",
};

const Multiplier = enum {
    one,
    /// `+` -- a space-separated list.
    space_list,
    /// `#` -- a comma-separated list.
    comma_list,
};

const Kind = enum {
    length,
    number,
    percentage,
    length_percentage,
    color,
    image,
    url,
    integer,
    angle,
    time,
    resolution,
    transform_function,
    transform_list,
    custom_ident,
    /// A bare identifier in the syntax string, which matches only itself.
    literal,

    fn parse(name: []const u8) ?Kind {
        const table = .{
            .{ "length", Kind.length },
            .{ "number", Kind.number },
            .{ "percentage", Kind.percentage },
            .{ "length-percentage", Kind.length_percentage },
            .{ "color", Kind.color },
            .{ "image", Kind.image },
            .{ "url", Kind.url },
            .{ "integer", Kind.integer },
            .{ "angle", Kind.angle },
            .{ "time", Kind.time },
            .{ "resolution", Kind.resolution },
            .{ "transform-function", Kind.transform_function },
            .{ "transform-list", Kind.transform_list },
            .{ "custom-ident", Kind.custom_ident },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const Syntax = struct {
    /// `*`: anything, computed as written.
    universal: bool = false,
    alternatives: []const Component = &.{},
};

pub const Entry = struct {
    name: []const u8,
    syntax: Syntax,
    inherits: bool,
    /// The computed form of `initialValue`, or null for a universal syntax that
    /// was registered without one -- the one registration that leaves the
    /// property with no value anywhere (measured: it is not enumerated either).
    initial: ?[]const u8,
};

/// Every registration a document has made, in registration order -- which is
/// the order `getComputedStyle` enumerates them in, after the standard
/// longhands.
pub const Registry = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn find(self: *const Registry, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

const DICT = dictionary.MethodReader("CSS", "registerProperty", "PropertyDefinition");

/// `CSS.registerProperty(definition)`.
///
/// The member reading order is WebIDL's -- alphabetical, so `inherits` before
/// `name` -- and it is measured: `CSS.registerProperty({})` and
/// `CSS.registerProperty({name: 'x', syntax: '*'})` both report the missing
/// `inherits` rather than the missing or bad name.
pub fn registerProperty(definition: js.Value, exec: *const Execution) !void {
    const dict = try DICT.readRequired(definition, exec);

    const inherits_value = try dict.required("inherits", exec);
    const inherits = inherits_value.toBool();

    const initial_value: ?[]const u8 = if (try dict.present("initialValue")) |v|
        try v.toStringSlice()
    else
        null;

    const name_value = try dict.required("name", exec);
    const name = try name_value.toStringSlice();
    if (!std.mem.startsWith(u8, name, "--")) {
        return dictionary.throwDom(
            "SyntaxError",
            "Failed to execute 'registerProperty' on 'CSS': " ++
                "Custom property names must start with '--'.",
            exec,
        );
    }

    // The registry is the document's, so it lives on the frame's StyleManager.
    // `CSS` is not exposed in a worker, so the other arm of the union cannot be
    // reached from here.
    const style_manager = switch (exec.js.global) {
        .frame => |frame| &frame._style_manager,
        .worker => return,
    };

    const syntax_text: []const u8 = if (try dict.present("syntax")) |v|
        try v.toStringSlice()
    else
        "*";

    // The frame's arena, not the StyleManager's: that one is reset on every
    // stylesheet rebuild (`resetRetain` in rebuildIfDirty) and a registration
    // outlives every rebuild. Storing the names there segfaulted the moment a
    // page registered a property and then touched a stylesheet.
    const arena = style_manager.frame.arena;
    const syntax = parseSyntax(arena, syntax_text) catch |err| switch (err) {
        error.InvalidSyntax => return dictionary.throwDom(
            "SyntaxError",
            "Failed to execute 'registerProperty' on 'CSS': " ++
                "The syntax provided is not a valid custom property syntax.",
            exec,
        ),
        else => return err,
    };

    // The initial value is required unless the syntax is universal, and it has
    // to compute without an element: `2em` depends on a font size and is
    // refused for that reason with a message of its own.
    var initial: ?[]const u8 = null;
    if (!syntax.universal) {
        const raw = initial_value orelse return dictionary.throwDom(
            "SyntaxError",
            "Failed to execute 'registerProperty' on 'CSS': " ++
                "An initial value must be provided if the syntax is not '*'",
            exec,
        );
        if (!isComputationallyIndependent(raw)) {
            return dictionary.throwDom(
                "SyntaxError",
                "Failed to execute 'registerProperty' on 'CSS': " ++
                    "The initial value provided is not computationally independent.",
                exec,
            );
        }
        initial = compute(arena, syntax, raw, null, style_manager) orelse
            return dictionary.throwDom(
                "SyntaxError",
                "Failed to execute 'registerProperty' on 'CSS': " ++
                    "The initial value provided does not parse for the given syntax.",
                exec,
            );
    } else if (initial_value) |raw| {
        initial = try arena.dupe(u8, std.mem.trim(u8, raw, &std.ascii.whitespace));
    }

    // Last, so every other refusal is reported for a name that is already
    // taken as well (measured: a duplicate registration whose syntax is also
    // invalid reports the syntax).
    const registry = &style_manager.registered_properties;
    if (registry.find(name) != null) {
        return dictionary.throwDom(
            "InvalidModificationError",
            "Failed to execute 'registerProperty' on 'CSS': " ++
                "The name provided has already been registered.",
            exec,
        );
    }

    try registry.entries.append(arena, .{
        .name = try arena.dupe(u8, name),
        .syntax = syntax,
        .inherits = inherits,
        .initial = initial,
    });
}

/// Whether a value can be computed with no element to compute it against,
/// which is what the spec asks of an initial value. Only the font- and
/// viewport-relative units cannot; every absolute unit, keyword and colour can.
fn isComputationallyIndependent(raw: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c,");
    while (it.next()) |token| {
        const parsed = units.parse(token) catch continue;
        if (units.absoluteLengthFactor(parsed.unit) != null) continue;
        switch (parsed.unit) {
            // A percentage, an angle and a bare number depend on nothing; the
            // font- and viewport-relative lengths are exactly the ones that do.
            .percentage, .deg, .grad, .rad, .turn, .none => continue,
            else => return false,
        }
    }
    return true;
}

/// The syntax string, or error.InvalidSyntax.
fn parseSyntax(arena: Allocator, text: []const u8) !Syntax {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.InvalidSyntax;
    if (std.mem.eql(u8, trimmed, "*")) return .{ .universal = true };

    var alternatives: std.ArrayListUnmanaged(Component) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '|');
    while (it.next()) |raw| {
        var part = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (part.len == 0) return error.InvalidSyntax;

        var multiplier: Multiplier = .one;
        if (part[part.len - 1] == '+') {
            multiplier = .space_list;
            part = std.mem.trimEnd(u8, part[0 .. part.len - 1], &std.ascii.whitespace);
        } else if (part[part.len - 1] == '#') {
            multiplier = .comma_list;
            part = std.mem.trimEnd(u8, part[0 .. part.len - 1], &std.ascii.whitespace);
        }
        if (part.len == 0) return error.InvalidSyntax;

        if (part[0] == '<') {
            if (part[part.len - 1] != '>') return error.InvalidSyntax;
            const kind = Kind.parse(part[1 .. part.len - 1]) orelse return error.InvalidSyntax;
            try alternatives.append(arena, .{ .kind = kind, .multiplier = multiplier });
            continue;
        }

        // A bare identifier: it matches only itself. `*` is not one of these --
        // the universal syntax has to be the whole string.
        if (!isIdent(part)) return error.InvalidSyntax;
        try alternatives.append(arena, .{
            .kind = .literal,
            .multiplier = multiplier,
            .literal = try arena.dupe(u8, part),
        });
    }
    if (alternatives.items.len == 0) return error.InvalidSyntax;
    return .{ .alternatives = alternatives.items };
}

fn isIdent(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80) continue;
        if (c == '-') continue;
        if (i > 0 and std.ascii.isDigit(c)) continue;
        return false;
    }
    return true;
}

/// The computed value of `raw` for a property registered with `syntax`, or null
/// when it does not parse -- which is what makes the caller fall back to the
/// initial value.
///
/// `element` is null only for an initial value, which is why every branch that
/// needs one is also a branch `isComputationallyIndependent` has already
/// refused.
pub fn compute(
    arena: Allocator,
    syntax: Syntax,
    raw: []const u8,
    element: ?*Element,
    style_manager: *StyleManager,
) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (syntax.universal) return arena.dupe(u8, trimmed) catch null;

    // A math function is folded before the type is matched, so `<number>` sees
    // `2` where the page wrote `calc(1 + 1)`.
    const folded = blk: {
        const rewritten = calc.rewrite(arena, trimmed) catch break :blk trimmed;
        break :blk rewritten orelse trimmed;
    };

    for (syntax.alternatives) |component| {
        if (computeComponent(arena, component, folded, element, style_manager)) |computed| {
            return computed;
        }
    }
    return null;
}

fn computeComponent(
    arena: Allocator,
    component: Component,
    value: []const u8,
    element: ?*Element,
    style_manager: *StyleManager,
) ?[]const u8 {
    switch (component.multiplier) {
        .one => return computeOne(arena, component, value, element, style_manager),
        .space_list, .comma_list => {
            const separator: u8 = if (component.multiplier == .comma_list) ',' else ' ';
            var buf = std.Io.Writer.Allocating.init(arena);
            var count: usize = 0;
            if (component.multiplier == .comma_list) {
                var it = std.mem.splitScalar(u8, value, ',');
                while (it.next()) |raw_item| {
                    const item = std.mem.trim(u8, raw_item, &std.ascii.whitespace);
                    // An empty slot means a stray comma, which is not a list.
                    if (item.len == 0) return null;
                    if (!appendItem(&buf, arena, component, item, element, style_manager, count, separator)) return null;
                    count += 1;
                }
            } else {
                var it = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
                while (it.next()) |item| {
                    if (!appendItem(&buf, arena, component, item, element, style_manager, count, separator)) return null;
                    count += 1;
                }
            }
            if (count == 0) return null;
            return buf.written();
        },
    }
}

fn appendItem(
    buf: *std.Io.Writer.Allocating,
    arena: Allocator,
    component: Component,
    item: []const u8,
    element: ?*Element,
    style_manager: *StyleManager,
    count: usize,
    separator: u8,
) bool {
    const computed = computeOne(arena, component, item, element, style_manager) orelse return false;
    if (count > 0) {
        buf.writer.writeByte(separator) catch return false;
        if (separator == ',') buf.writer.writeByte(' ') catch return false;
    }
    buf.writer.writeAll(computed) catch return false;
    return true;
}

fn computeOne(
    arena: Allocator,
    component: Component,
    value: []const u8,
    element: ?*Element,
    style_manager: *StyleManager,
) ?[]const u8 {
    switch (component.kind) {
        .literal => {
            if (!std.mem.eql(u8, value, component.literal)) return null;
            return value;
        },
        .custom_ident => {
            if (!isIdent(value)) return null;
            return value;
        },
        .length, .length_percentage, .percentage => {
            const parsed = units.parse(value) catch return null;
            if (parsed.unit == .percentage) {
                if (component.kind == .length) return null;
                return writeUnit(arena, parsed.value, "%");
            }
            if (component.kind == .percentage) return null;
            // A bare zero is a length (`0` computes to `0px`), and anything
            // else with no unit is not.
            if (parsed.unit == .none and parsed.value != 0) return null;
            // `computedLengthText` answers null when the text needs no
            // conversion at all -- `7px` is already px -- which is not a
            // refusal. The unit check above is the refusal; this is only the
            // conversion, so a miss falls through to the absolute factor.
            if (element) |el| {
                if (CSSStyleDeclaration.computedLengthText(style_manager, el, "", value, null)) |text| {
                    return text;
                }
            }
            const factor = units.absoluteLengthFactor(parsed.unit) orelse return null;
            return writeUnit(arena, parsed.value * factor, "px");
        },
        .number, .integer => {
            const parsed = units.parse(value) catch return null;
            if (parsed.unit != .none) return null;
            if (component.kind == .integer) {
                // `3.0` is not an <integer> -- the token has to be written
                // without a decimal point (measured).
                if (std.mem.indexOfAny(u8, value, ".eE") != null) return null;
            }
            return writeUnit(arena, parsed.value, "");
        },
        .angle => return canonicalise(arena, value, &.{
            .{ .deg, 1 }, .{ .grad, 0.9 }, .{ .rad, 180.0 / std.math.pi }, .{ .turn, 360 },
        }, "deg"),
        // `units.Unit` has no time or resolution members -- it is the length
        // and angle parser -- so these two families are read off their own
        // suffix tables. Canonical units measured: `500ms` is `0.5s` and
        // `96dpi` is `1dppx`.
        .time => {
            const seconds = suffixValue(value, &.{ .{ "ms", 0.001 }, .{ "s", 1 } }) orelse return null;
            return writeUnit(arena, seconds, "s");
        },
        .resolution => {
            const dppx = suffixValue(value, &.{
                .{ "dppx", 1 }, .{ "dpcm", 2.54 / 96.0 }, .{ "dpi", 1.0 / 96.0 }, .{ "x", 1 },
            }) orelse return null;
            return writeUnit(arena, dppx, "dppx");
        },
        .color => {
            const style = color.parseStyle(value) orelse return null;
            var buf = std.Io.Writer.Allocating.init(arena);
            CSSStyleDeclaration.writeColour(&buf.writer, .{
                .rgb = .{ style.rgba.r, style.rgba.g, style.rgba.b },
                .alpha = style.rgba.a,
            }) catch return null;
            return buf.written();
        },
        .url => {
            if (!std.mem.startsWith(u8, value, "url(")) return null;
            if (value[value.len - 1] != ')') return null;
            const inner = std.mem.trim(u8, std.mem.trim(u8, value[4 .. value.len - 1], &std.ascii.whitespace), "'\"");
            const base = if (element) |el| el.ownerFrame(style_manager.frame).base() else "";
            const resolved = URL.resolve(arena, base, inner, .{}) catch return value;
            return std.fmt.allocPrint(arena, "url(\"{s}\")", .{resolved}) catch null;
        },
        // Accepted as written -- see the header. Refusing a value here would
        // invent a fallback Chrome does not take, and computing one would mean
        // resolving an image or normalising a transform list.
        .image, .transform_function, .transform_list => return value,
    }
}

fn writeUnit(arena: Allocator, value: f64, suffix: []const u8) ?[]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);
    units.writeNumber(&buf.writer, value) catch return null;
    buf.writer.writeAll(suffix) catch return null;
    return buf.written();
}

/// One unit family reduced to its canonical unit: `0.5turn` is `180deg`
/// (measured).
fn canonicalise(
    arena: Allocator,
    value: []const u8,
    comptime table: []const struct { units.Unit, f64 },
    canonical: []const u8,
) ?[]const u8 {
    const parsed = units.parse(value) catch return null;
    inline for (table) |entry| {
        if (parsed.unit == entry[0]) {
            return writeUnit(arena, parsed.value * entry[1], canonical);
        }
    }
    return null;
}

/// The number in `value` if it ends with one of `table`'s suffixes, scaled to
/// the canonical unit. Longest suffix first, or `1x` matches `dppx`'s `x` and
/// `500ms` matches `s`.
fn suffixValue(value: []const u8, comptime table: []const struct { []const u8, f64 }) ?f64 {
    inline for (table) |entry| {
        if (value.len > entry[0].len and std.ascii.endsWithIgnoreCase(value, entry[0])) {
            const number = std.fmt.parseFloat(f64, value[0 .. value.len - entry[0].len]) catch return null;
            return number * entry[1];
        }
    }
    return null;
}
