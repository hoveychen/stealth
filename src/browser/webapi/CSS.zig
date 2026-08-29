// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const std = @import("std");
const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const units = @import("../css/units.zig");
const HighlightRegistry = @import("css/highlights.zig").HighlightRegistry;
const typed_om = @import("css/typed_om.zig");

const CSS = @This();
_pad: bool = false,

pub const init: CSS = .{};

pub fn parseDimension(value: []const u8) ?f64 {
    const parsed = units.parse(value) catch return null;
    return switch (parsed.unit) {
        .none, .px => parsed.value,
        else => null,
    };
}

// parseDimension plus viewport-relative units, which the faux layout
// resolves against the page viewport.
pub fn parseDimensionViewport(value: []const u8, frame: *Frame) ?f64 {
    const parsed = units.parse(value) catch return null;
    return switch (parsed.unit) {
        .none, .px => parsed.value,
        .vh => parsed.value * @as(f64, @floatFromInt(frame._page.getViewport().height)) / 100.0,
        .vw => parsed.value * @as(f64, @floatFromInt(frame._page.getViewport().width)) / 100.0,
        else => null,
    };
}

/// Escapes a CSS identifier string
/// https://drafts.csswg.org/cssom/#the-css.escape()-method
pub fn escape(value: []const u8, frame: *Frame) ![]const u8 {
    if (value.len == 0) {
        return "";
    }

    const first = value[0];
    if (first == '-' and value.len == 1) {
        return "\\-";
    }

    // Count how many characters we need for the output
    var out_len: usize = escapeLen(true, first);
    for (value[1..], 0..) |c, i| {
        // Second char (i==0) is a digit and first is '-', needs hex escape
        if (i == 0 and first == '-' and c >= '0' and c <= '9') {
            out_len += 2 + hexDigitsNeeded(c);
        } else {
            out_len += escapeLen(false, c);
        }
    }

    if (out_len == value.len) {
        return value;
    }

    const result = try frame.local_arena.alloc(u8, out_len);
    var pos: usize = 0;

    if (needsEscape(true, first)) {
        pos = writeEscape(true, result, first);
    } else {
        result[0] = first;
        pos = 1;
    }

    for (value[1..], 0..) |c, i| {
        // Second char (i==0) is a digit and first is '-', needs hex escape
        if (i == 0 and first == '-' and c >= '0' and c <= '9') {
            result[pos] = '\\';
            const hex_str = std.fmt.bufPrint(result[pos + 1 ..], "{x} ", .{c}) catch unreachable;
            pos += 1 + hex_str.len;
        } else if (!needsEscape(false, c)) {
            result[pos] = c;
            pos += 1;
        } else {
            pos += writeEscape(false, result[pos..], c);
        }
    }

    return result;
}

pub fn supports(property_or_condition: []const u8, value: ?[]const u8) bool {
    _ = property_or_condition;
    _ = value;
    return true;
}

fn escapeLen(comptime is_first: bool, c: u8) usize {
    if (needsEscape(is_first, c) == false) {
        return 1;
    }
    if (c == 0) {
        return "\u{FFFD}".len;
    }
    if (isHexEscape(c) or ((comptime is_first) and c >= '0' and c <= '9')) {
        // Will be escaped as \XX (backslash + 1-6 hex digits + space)
        return 2 + hexDigitsNeeded(c);
    }
    // Escaped as \C (backslash + character)
    return 2;
}

fn needsEscape(comptime is_first: bool, c: u8) bool {
    if (comptime is_first) {
        if (c >= '0' and c <= '9') {
            return true;
        }
    }

    // Characters that need escaping
    return switch (c) {
        0...0x1F, 0x7F => true,
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '`', '{', '|', '}', '~' => true,
        ' ' => true,
        else => false,
    };
}

fn isHexEscape(c: u8) bool {
    return (c >= 0x00 and c <= 0x1F) or c == 0x7F;
}

fn hexDigitsNeeded(c: u8) usize {
    if (c < 0x10) {
        return 1;
    }
    return 2;
}

fn writeEscape(comptime is_first: bool, buf: []u8, c: u8) usize {
    if (c == 0) {
        // NULL character becomes replacement character (no backslash)
        const replacement = "\u{FFFD}";
        @memcpy(buf[0..replacement.len], replacement);
        return replacement.len;
    }

    buf[0] = '\\';
    var data = buf[1..];

    if (isHexEscape(c) or ((comptime is_first) and c >= '0' and c <= '9')) {
        const hex_str = std.fmt.bufPrint(data, "{x} ", .{c}) catch unreachable;
        return 1 + hex_str.len;
    }

    data[0] = c;
    return 2;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSS);

    pub const Meta = struct {
        pub const name = "Css";

        // ...and that name never reaches the global. Chrome's `CSS` is the
        // namespace object the Window accessor hands out; there is no `Css`
        // constructor beside it. Measured against a real Chrome 151:
        // Object.getOwnPropertyNames(window) has "CSS" and no "Css".
        pub const no_interface_object = true;

        // The namespace's identifier is all upper case. Measured on Chrome 150:
        //   Object.prototype.toString.call(CSS) -> '[object CSS]'
        pub const to_string_tag = "CSS";

        // Per the CSSOM spec, CSS is a namespace object — members are own
        // properties so Object.entries(CSS) returns them.
        pub const own_properties = true;

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;

        // Still open: the prototype chain here is `CSS -> {} -> Object.prototype`
        // where Chrome's is `CSS -> Object.prototype` -- one extra, empty link.
        // Everything else about `window.CSS` already matches, measured with
        // probes/expr-b85-css-namespace.js: a data property, writable,
        // non-enumerable, configurable, the same object on every read, and
        // `[object CSS]`.
        //
        // Snapshot.zig's `namespace_global` is the path that inherits straight
        // from %Object.prototype%, and setting it here does nothing: that path
        // builds the object from the snapshot's global, and this one is handed
        // out by a Window accessor (`Window._css`) and wrapped at runtime
        // instead. Moving CSS onto that path is its own change.
    };

    // Chrome's own-property order is its IDL order, and the enumeration is
    // what a page sees: `highlights` first, then every operation in one
    // alphabetical run with `escape`, `registerProperty` and `supports` sitting
    // among the unit factories rather than beside each other. Measured with
    // probes/expr-b85-css-namespace.js. The declarations below are in that
    // order because the bridge emits own properties in declaration order.
    //
    // Two of Chrome's 69 names are deliberately absent rather than stubbed:
    // `registerProperty`, which is only meaningful once the cascade honours a
    // registered custom property's syntax and initial value, and
    // `paintWorklet`, which needs a Worklet that can actually load a module.
    // A present-but-inert name is a different lie from an absent one and this
    // repo has no way to measure which a guard prefers, so neither is invented.

    // `CSS.highlights` is an own accessor on the namespace object and answers
    // the same HighlightRegistry every time (measured on Chrome 150).
    pub const highlights = bridge.accessor(_highlights, null, .{ .static = true });
    fn _highlights(frame: *Frame) !*HighlightRegistry {
        return frame.window.getHighlights(frame);
    }

    /// One numeric factory per CSS unit. Chrome's `CSS` namespace carries 64 of
    /// them; this engine carried none, so `CSS.px` was not a function.
    ///
    /// The declaration name is the JS name and it is not always the unit: the
    /// factories are `Hz`, `kHz` and `Q`, and what they build reports `hz`,
    /// `khz` and `q`. Measured over all 64 -- `CSS.Hz(3)` is `3hz`, not `3Hz`.
    fn unitFactory(comptime unit: typed_om.Unit) fn (f64, *Frame) anyerror!*typed_om.CSSUnitValue {
        return struct {
            fn factory(value: f64, frame: *Frame) !*typed_om.CSSUnitValue {
                return typed_om.CSSUnitValue.create(value, unit, frame);
            }
        }.factory;
    }

    pub const Hz = bridge.function(unitFactory(.hz), .{ .static = true });
    pub const Q = bridge.function(unitFactory(.q), .{ .static = true });
    pub const cap = bridge.function(unitFactory(.cap), .{ .static = true });
    pub const ch = bridge.function(unitFactory(.ch), .{ .static = true });
    pub const cm = bridge.function(unitFactory(.cm), .{ .static = true });
    pub const cqb = bridge.function(unitFactory(.cqb), .{ .static = true });
    pub const cqh = bridge.function(unitFactory(.cqh), .{ .static = true });
    pub const cqi = bridge.function(unitFactory(.cqi), .{ .static = true });
    pub const cqmax = bridge.function(unitFactory(.cqmax), .{ .static = true });
    pub const cqmin = bridge.function(unitFactory(.cqmin), .{ .static = true });
    pub const cqw = bridge.function(unitFactory(.cqw), .{ .static = true });
    pub const deg = bridge.function(unitFactory(.deg), .{ .static = true });
    pub const dpcm = bridge.function(unitFactory(.dpcm), .{ .static = true });
    pub const dpi = bridge.function(unitFactory(.dpi), .{ .static = true });
    pub const dppx = bridge.function(unitFactory(.dppx), .{ .static = true });
    pub const dvb = bridge.function(unitFactory(.dvb), .{ .static = true });
    pub const dvh = bridge.function(unitFactory(.dvh), .{ .static = true });
    pub const dvi = bridge.function(unitFactory(.dvi), .{ .static = true });
    pub const dvmax = bridge.function(unitFactory(.dvmax), .{ .static = true });
    pub const dvmin = bridge.function(unitFactory(.dvmin), .{ .static = true });
    pub const dvw = bridge.function(unitFactory(.dvw), .{ .static = true });
    pub const em = bridge.function(unitFactory(.em), .{ .static = true });
    pub const escape = bridge.function(CSS.escape, .{ .static = true });
    pub const ex = bridge.function(unitFactory(.ex), .{ .static = true });
    pub const fr = bridge.function(unitFactory(.fr), .{ .static = true });
    pub const grad = bridge.function(unitFactory(.grad), .{ .static = true });
    pub const ic = bridge.function(unitFactory(.ic), .{ .static = true });
    pub const in = bridge.function(unitFactory(.in), .{ .static = true });
    pub const kHz = bridge.function(unitFactory(.khz), .{ .static = true });
    pub const lh = bridge.function(unitFactory(.lh), .{ .static = true });
    pub const lvb = bridge.function(unitFactory(.lvb), .{ .static = true });
    pub const lvh = bridge.function(unitFactory(.lvh), .{ .static = true });
    pub const lvi = bridge.function(unitFactory(.lvi), .{ .static = true });
    pub const lvmax = bridge.function(unitFactory(.lvmax), .{ .static = true });
    pub const lvmin = bridge.function(unitFactory(.lvmin), .{ .static = true });
    pub const lvw = bridge.function(unitFactory(.lvw), .{ .static = true });
    pub const mm = bridge.function(unitFactory(.mm), .{ .static = true });
    pub const ms = bridge.function(unitFactory(.ms), .{ .static = true });
    pub const number = bridge.function(unitFactory(.number), .{ .static = true });
    pub const pc = bridge.function(unitFactory(.pc), .{ .static = true });
    pub const percent = bridge.function(unitFactory(.percent), .{ .static = true });
    pub const pt = bridge.function(unitFactory(.pt), .{ .static = true });
    pub const px = bridge.function(unitFactory(.px), .{ .static = true });
    pub const rad = bridge.function(unitFactory(.rad), .{ .static = true });
    pub const rcap = bridge.function(unitFactory(.rcap), .{ .static = true });
    pub const rch = bridge.function(unitFactory(.rch), .{ .static = true });
    pub const rem = bridge.function(unitFactory(.rem), .{ .static = true });
    pub const rex = bridge.function(unitFactory(.rex), .{ .static = true });
    pub const ric = bridge.function(unitFactory(.ric), .{ .static = true });
    pub const rlh = bridge.function(unitFactory(.rlh), .{ .static = true });
    pub const s = bridge.function(unitFactory(.s), .{ .static = true });
    pub const supports = bridge.function(CSS.supports, .{ .static = true });
    pub const svb = bridge.function(unitFactory(.svb), .{ .static = true });
    pub const svh = bridge.function(unitFactory(.svh), .{ .static = true });
    pub const svi = bridge.function(unitFactory(.svi), .{ .static = true });
    pub const svmax = bridge.function(unitFactory(.svmax), .{ .static = true });
    pub const svmin = bridge.function(unitFactory(.svmin), .{ .static = true });
    pub const svw = bridge.function(unitFactory(.svw), .{ .static = true });
    pub const turn = bridge.function(unitFactory(.turn), .{ .static = true });
    pub const vb = bridge.function(unitFactory(.vb), .{ .static = true });
    pub const vh = bridge.function(unitFactory(.vh), .{ .static = true });
    pub const vi = bridge.function(unitFactory(.vi), .{ .static = true });
    pub const vmax = bridge.function(unitFactory(.vmax), .{ .static = true });
    pub const vmin = bridge.function(unitFactory(.vmin), .{ .static = true });
    pub const vw = bridge.function(unitFactory(.vw), .{ .static = true });
    pub const x = bridge.function(unitFactory(.x), .{ .static = true });
};

const testing = @import("../../testing.zig");
test "WebApi: CSS" {
    try testing.htmlRunner("css.html", .{});
}

test "WebApi: CSS namespace" {
    try testing.htmlRunner("css/css_namespace.html", .{});
}
