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
// paint style that holds one. The rasteriser only knows how to fill with a
// flat colour, so neither handle paints anything yet; what they do carry is
// their own identity, because `fillStyle` and `strokeStyle` are
// `(DOMString or CanvasGradient or CanvasPattern)` and a script that assigns a
// gradient reads the same object back out. Chrome's prototypes carry exactly
// `addColorStop` and `setTransform` respectively.

const std = @import("std");

const js = @import("../../js/js.zig");
const color = @import("../../color.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ CanvasGradient, CanvasPattern };
}

/// What `fillStyle` / `strokeStyle` hold. Before this they were a bare `RGBA`,
/// so assigning a gradient stringified it to `[object CanvasGradient]`, failed
/// to parse as a colour, and read back as the *previous* colour: `typeof
/// ctx.fillStyle` answered `string` where Chrome answers `object`.
pub const PaintStyle = struct {
    /// The colour the rasteriser paints with. A gradient or a pattern leaves
    /// it alone, since neither carries paint yet — whatever colour they
    /// replaced keeps getting painted, which is what happened before this
    /// too. Giving them real paint is the `cfsc-gradient-paint-source` plan.
    colour: color.RGBA = color.RGBA.Named.black,
    /// Set when the last assignment was a gradient or a pattern, in which case
    /// that object — not `colour` — is what a script reads back.
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
                self.colour = color.RGBA.parse(text) catch return;
                self.object = null;
            },
        }
    }

    pub fn read(self: *const PaintStyle, arena: Allocator) !Read {
        const object = self.object orelse {
            var w = std.Io.Writer.Allocating.init(arena);
            try self.colour.format(&w.writer);
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
    /// Gives each gradient its own allocation, and so its own JS identity.
    _: u8 = 0,

    /// Offsets outside [0, 1] and unparseable colours throw in Chrome; we
    /// only enforce the offset, since the colour would need a full CSS
    /// colour parser to reject faithfully.
    pub fn addColorStop(_: *CanvasGradient, offset: f64, _: []const u8) !void {
        if (!std.math.isFinite(offset) or offset < 0 or offset > 1) {
            return error.IndexSizeError;
        }
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
