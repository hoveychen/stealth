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

// The two handle types `createLinearGradient` and friends hand back, and the
// paint style that holds one. A gradient carries the geometry and stops the
// rasteriser evaluates per pixel (see `raster.Gradient`); a pattern still
// carries nothing, because there are no decoded image pixels to tile. Both
// carry their own identity either way, because `fillStyle` and `strokeStyle`
// are `(DOMString or CanvasGradient or CanvasPattern)` and a script that
// assigns a gradient reads the same object back out. Chrome's prototypes carry
// exactly `addColorStop` and `setTransform` respectively.

const std = @import("std");

const js = @import("../../js/js.zig");
const color = @import("../../color.zig");

const Surface = @import("raster.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ CanvasGradient, CanvasPattern };
}

/// What `fillStyle` / `strokeStyle` hold. Before this they were a bare `RGBA`,
/// so assigning a gradient stringified it to `[object CanvasGradient]`, failed
/// to parse as a colour, and read back as the *previous* colour: `typeof
/// ctx.fillStyle` answered `string` where Chrome answers `object`.
pub const PaintStyle = struct {
    /// The colour the rasteriser paints with, in the form the notation was
    /// written: the bytes, plus whatever of the source the notation needs kept
    /// (see `color.Style`). Assigning a gradient or a pattern leaves it alone —
    /// a gradient paints from its own stops instead, and a pattern still has no
    /// pixels, so whatever colour it replaced keeps getting painted.
    style: color.Style = .{ .rgba = color.RGBA.Named.black },
    /// Set when the last assignment was a gradient or a pattern, in which case
    /// that object — not `style` — is what a script reads back.
    object: ?Object = null,

    pub const Object = union(enum) {
        gradient: *CanvasGradient,
        pattern: *CanvasPattern,
    };

    /// The union a setter takes. The object arms come first because probing
    /// stops at the first exact match, and any object at all coerces to a
    /// string.
    pub const Assigned = union(enum) {
        gradient: *CanvasGradient,
        pattern: *CanvasPattern,
        text: []const u8,
    };

    /// The union a getter hands back — the colour arm serialised, since a
    /// string is what a script reads for it.
    pub const Read = union(enum) {
        text: []const u8,
        gradient: *CanvasGradient,
        pattern: *CanvasPattern,
    };

    /// An unparseable colour string leaves the previous value in place. So
    /// does a value that is neither a string nor either object: it arrives
    /// here as whatever it stringifies to, which no colour parser accepts.
    pub fn assign(self: *PaintStyle, value: Assigned) void {
        switch (value) {
            .gradient => |gradient| self.object = .{ .gradient = gradient },
            .pattern => |pattern| self.object = .{ .pattern = pattern },
            .text => |text| {
                self.style = parseColour(text) orelse return;
                self.object = null;
            },
        }
    }

    /// What `fillStyle` and `strokeStyle` accept. `currentColor` is the
    /// element's `color`, and neither context tracks one of its own, so it
    /// resolves to that property's initial value — measured on Chrome as
    /// `#000000`. Everything else is color.zig's grammar.
    pub fn parseColour(value: []const u8) ?color.Style {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, &std.ascii.whitespace), "currentcolor")) {
            return .{ .rgba = color.RGBA.Named.black };
        }
        return color.parseStyle(value);
    }

    /// The colour the rasteriser writes, in the bitmap's own colour space and
    /// still unquantised. This is where the two halves of a paint style come
    /// apart: what a script reads back is the notation (see `read`), and what
    /// goes into the bitmap is that notation resolved into `space`.
    ///
    /// It stays a float because the bitmap premultiplies before it rounds, and
    /// the two orders do not agree to the byte — see `color.Paint`. On a
    /// float16 bitmap it is never rounded at all. `channels` is what decides
    /// whether the bitmap sees the notation's float at all: an eight-bit sRGB
    /// one does not — see `color.Style.paint`.
    pub fn paint(
        self: *const PaintStyle,
        space: color.CanvasSpace,
        channels: color.CanvasChannels,
    ) color.Paint {
        return self.style.paint(space, channels);
    }

    /// The colour arm answers with the source notation when the colour was
    /// written in one of the five functions that keep it, and with the hex or
    /// `rgba()` form otherwise.
    pub fn read(self: *const PaintStyle, arena: Allocator) !Read {
        const object = self.object orelse {
            var w = std.Io.Writer.Allocating.init(arena);
            if (self.style.wide) |source| {
                try source.format(&w.writer);
            } else {
                try self.style.rgba.format(&w.writer);
            }
            return .{ .text = w.written() };
        };
        return switch (object) {
            .gradient => |gradient| .{ .gradient = gradient },
            .pattern => |pattern| .{ .pattern = pattern },
        };
    }
};

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasGradient
pub const CanvasGradient = struct {
    /// The coordinates the factory was handed, kept in the *user* space they
    /// were written in rather than resolved against a transform here.
    ///
    /// Which transform applies is measured, not assumed: the one in effect when
    /// the gradient is *painted with*, not the one when it was made. Three rows
    /// of probes/canvas-gradient-paint.js say it together and are byte-identical
    /// — a 0→32 axis at the identity, a 0→16 axis created under `scale(2, 1)`,
    /// and a 0→16 axis created at the identity and then filled under
    /// `scale(2, 1)`. So there is nothing to resolve until the fill, and this
    /// keeps what it was given.
    geometry: Surface.Gradient.Geometry,
    /// The stops, kept sorted by offset with ties in insertion order, the way
    /// the spec orders them. A script cannot see them (`Object.keys` on a
    /// gradient is empty in Chrome too); the rasteriser reads them through
    /// `resolve` below.
    stops: std.ArrayList(Stop) = .empty,

    pub const Stop = struct {
        offset: f64,
        /// The colour as given. Kept because `color.isColor` accepts three
        /// notations `color.parseStyle` does not convert — the system colours
        /// and `color-mix()`, neither of which is read yet — so this is the
        /// only record of a stop whose colour we recognised but cannot paint.
        text: []const u8,
        /// Null for exactly those stops. Otherwise the notation as parsed, so
        /// that a stop and a `fillStyle` written the same way resolve to the
        /// same paint.
        style: ?color.Style,
    };

    /// The stops as the rasteriser wants them: offsets in order, colours
    /// resolved into the bitmap's own space. Allocated on `scratch`, which may
    /// be a call-lifetime arena — nothing keeps this past the draw.
    ///
    /// The stops we could not parse are dropped rather than painted as
    /// anything: leaving a `color-mix()` stop out narrows the ramp, where
    /// inventing a colour for it would put the wrong one across a whole band.
    pub fn resolve(
        self: *const CanvasGradient,
        scratch: Allocator,
        space: color.CanvasSpace,
        channels: color.CanvasChannels,
    ) []const Surface.Gradient.Stop {
        var out = scratch.alloc(Surface.Gradient.Stop, self.stops.items.len) catch return &.{};
        var kept: usize = 0;
        for (self.stops.items) |stop| {
            const style = stop.style orelse continue;
            out[kept] = .{ .offset = stop.offset, .paint = style.paint(space, channels) };
            kept += 1;
        }
        return out[0..kept];
    }

    const prefix = "Failed to execute 'addColorStop' on 'CanvasGradient': ";

    /// The three refusals, in the order Chrome 151 applies them: the WebIDL
    /// `double` conversion first (a non-finite offset is a TypeError, and it
    /// wins even when the colour is also bad), then the offset's range, then
    /// the colour. Before this only the range was enforced, with the generic
    /// DOMException message and — because the check was `!isFinite or ...` —
    /// an IndexSizeError where Chrome raises a TypeError.
    pub fn addColorStop(self: *CanvasGradient, offset: f64, text: []const u8, exec: *js.Execution) !void {
        if (!std.math.isFinite(offset)) {
            return exec.js.fail(error.TypeError, prefix ++ "The provided double value is non-finite.");
        }
        if (offset < 0 or offset > 1) {
            var w = std.Io.Writer.Allocating.init(exec.call_arena);
            try w.writer.writeAll(prefix ++ "The provided value (");
            try writePrecision6(&w.writer, offset);
            try w.writer.writeAll(") is outside the range (0.0, 1.0).");
            return exec.js.fail(error.IndexSizeError, w.written());
        }
        if (!color.isColor(text)) {
            return exec.js.fail(error.SyntaxError, try std.fmt.allocPrint(
                exec.call_arena,
                prefix ++ "The value provided ('{s}') could not be parsed as a color.",
                .{text},
            ));
        }

        const stop: Stop = .{
            .offset = offset,
            .text = try exec.arena.dupe(u8, text),
            // The whole grammar, not just the hex and named forms: a stop
            // written `rgb(…)` or `oklch(…)` is one Chrome paints, and reading
            // it here is what keeps it from silently dropping out of the ramp.
            .style = PaintStyle.parseColour(text),
        };
        // Sorted by offset, and a repeated offset goes after the ones already
        // there rather than replacing them: Chrome takes two stops at 0.5.
        var at = self.stops.items.len;
        while (at > 0 and self.stops.items[at - 1].offset > offset) at -= 1;
        try self.stops.insert(exec.arena, at, stop);
    }

    /// Blink writes the offset with WTF's `String::Number`: six significant
    /// digits through double-conversion's ToPrecision. That is *not* the printf
    /// `%g` that `css/typed_om.zig`'s `writeNumber` follows, so the two cannot
    /// share an implementation — `%g` prints `1e+06` where this prints
    /// `1.00000e+6`, and `-1e-06` where this prints `-0.000001`.
    ///
    /// Measured on Chrome 151 across 30 offsets. Two rules come out of the
    /// readings: the exponential form is taken once the exponent reaches 6 or
    /// drops to -7 (`1000000` and `-1e-7` are exponential, `999999.5` is too
    /// because it rounds up into the first, while `-1e-6` and `100` are not),
    /// and the exponential mantissa keeps its trailing zeros while the decimal
    /// form drops them.
    ///
    /// One measured offset is knowingly not matched: a subnormal. Zig's `{e}`
    /// pads the shortest round-tripping digits, while double-conversion expands
    /// the value exactly, so `-5e-324` prints `-5.00000e-324` here against
    /// Chrome's `-4.94066e-324`. The two agree on every normal double, because
    /// there the shortest form and the exact expansion only part company past
    /// the sixth digit; only in the subnormal range are neighbouring doubles far
    /// enough apart for the first digit to differ. Closing it would mean
    /// carrying an exact decimal expansion for a value no script passes as a
    /// gradient offset.
    fn writePrecision6(writer: *std.Io.Writer, value: f64) !void {
        var buf: [64]u8 = undefined;
        // Rounding in scientific form first means the exponent branched on
        // below is the post-rounding one, which is what makes `999999.5` come
        // out as `1.00000e+6`.
        const formatted = try std.fmt.bufPrint(&buf, "{e:.5}", .{value});

        var rest = formatted;
        if (rest[0] == '-') {
            try writer.writeAll("-");
            rest = rest[1..];
        }
        const e_at = std.mem.indexOfScalar(u8, rest, 'e') orelse unreachable;
        var digits: [6]u8 = undefined;
        var count: usize = 0;
        for (rest[0..e_at]) |c| {
            if (c == '.') continue;
            if (count == digits.len) break;
            digits[count] = c;
            count += 1;
        }
        const exponent = std.fmt.parseInt(i32, rest[e_at + 1 ..], 10) catch unreachable;

        if (exponent >= 6 or exponent <= -7) {
            try writer.writeAll(digits[0..1]);
            try writer.writeAll(".");
            try writer.writeAll(digits[1..count]);
            try writer.print("e{c}{d}", .{
                @as(u8, if (exponent < 0) '-' else '+'),
                @abs(exponent),
            });
            return;
        }
        if (exponent >= 0) {
            const integral: usize = @intCast(exponent + 1);
            try writer.writeAll(digits[0..integral]);
            const fraction = trimTrailingZeros(digits[integral..count]);
            if (fraction.len != 0) {
                try writer.writeAll(".");
                try writer.writeAll(fraction);
            }
            return;
        }
        try writer.writeAll("0.");
        for (0..@intCast(-exponent - 1)) |_| try writer.writeAll("0");
        try writer.writeAll(trimTrailingZeros(digits[0..count]));
    }

    fn trimTrailingZeros(digits: []const u8) []const u8 {
        var end = digits.len;
        while (end > 0 and digits[end - 1] == '0') end -= 1;
        return digits[0..end];
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CanvasGradient);

        pub const Meta = struct {
            pub const name = "CanvasGradient";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const addColorStop = bridge.function(CanvasGradient.addColorStop, .{});
    };
};

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasPattern
pub const CanvasPattern = struct {
    _: u8 = 0,

    pub fn setTransform(_: *CanvasPattern, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CanvasPattern);

        pub const Meta = struct {
            pub const name = "CanvasPattern";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const setTransform = bridge.function(CanvasPattern.setTransform, .{ .noop = true });
    };
};

const testing = std.testing;

test "canvas_objects: the offset in an addColorStop message" {
    // Left column is the offset, right column the digits Chrome 151 put in
    // "The provided value (...) is outside the range (0.0, 1.0)." Only offsets
    // outside [0, 1] ever reach the message, so that is all this covers.
    const cases = [_]struct { f64, []const u8 }{
        .{ 2, "2" },
        .{ 100, "100" },
        .{ -1, "-1" },
        .{ 1.5, "1.5" },
        .{ -0.5, "-0.5" },
        // Six significant digits, so a seventh rounds away entirely.
        .{ 1.0000001, "1" },
        .{ 1.0000000000000002, "1" },
        .{ 1.00001, "1.00001" },
        // The decimal form reaches down to 1e-6 and up to 999999.
        .{ -0.00001, "-0.00001" },
        .{ -0.000001, "-0.000001" },
        .{ -1e-7, "-1.00000e-7" },
        .{ -2.5e-7, "-2.50000e-7" },
        .{ 1000000, "1.00000e+6" },
        .{ 1000001, "1.00000e+6" },
        // Rounds up into the exponential form rather than printing 999999.
        .{ 999999.5, "1.00000e+6" },
        .{ 1000000.5, "1.00000e+6" },
        .{ 1234567, "1.23457e+6" },
        .{ 9999999, "1.00000e+7" },
        .{ 12345678, "1.23457e+7" },
        .{ 123456789.5, "1.23457e+8" },
        .{ -1000000, "-1.00000e+6" },
        .{ 1e21, "1.00000e+21" },
        .{ 1e300, "1.00000e+300" },
        .{ -1e300, "-1.00000e+300" },
        .{ 1.7976931348623157e308, "1.79769e+308" },
    };

    for (cases) |case| {
        const value, const expected = case;
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try CanvasGradient.writePrecision6(&w, value);
        testing.expectEqualStrings(expected, w.buffered()) catch |err| {
            std.debug.print("writePrecision6({d})\n", .{value});
            return err;
        };
    }
}
