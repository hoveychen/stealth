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

// The two handle types `createLinearGradient` and friends hand back. The
// rasteriser only knows how to fill a rectangle with a flat colour, so these
// paint nothing; they exist so a script that builds a gradient gets an object
// with the right constructor name and the right one method on its prototype,
// instead of a TypeError. Chrome's prototypes carry exactly `addColorStop`
// and `setTransform` respectively.

const std = @import("std");

const js = @import("../../js/js.zig");

pub fn registerTypes() []const type {
    return &.{ CanvasGradient, CanvasPattern };
}

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
