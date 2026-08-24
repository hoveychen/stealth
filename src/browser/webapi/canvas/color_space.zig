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

// `PredefinedColorSpace`, which reaches a canvas through two dictionaries —
// getContext's CanvasContextCreationAttributesModule and getImageData's
// ImageDataSettings — and is refused by *two* gates in both of them:
//
//   1. The dictionary's own WebIDL conversion, which takes all seven members
//      and names the property it read: "Failed to read the 'colorSpace'
//      property from 'X': The provided value 'nonesuch' is not a valid enum
//      value of type PredefinedColorSpace."
//   2. The canvas's own refusal of the five members no bitmap can be in, which
//      names no property and says "of *the* type": "The provided value
//      'rec2020' is not a valid enum value of the type PredefinedColorSpace."
//
// Which gate a name gets is the reading a detector can take with a bare
// try/catch, and getting it backwards is the whole tell. Measured in
// probes/canvas-context-settings.js and probes/canvas-image-data-settings.js.

const std = @import("std");

const js = @import("../../js/js.zig");
const color = @import("../../color.zig");
const dictionary = @import("../dictionary.zig");

const Execution = js.Execution;

/// The IDL enum's own members. Five of them clear gate one and are then refused
/// by gate two. `display-p3-linear` is the one most easily left out — it is not
/// a name any other colour API here takes, and omitting it would hand it the
/// wrong one of the two refusals.
pub const members = [_][]const u8{
    "srgb",              "display-p3",  "rec2020",    "srgb-linear",
    "display-p3-linear", "rec2100-hlg", "rec2100-pq",
};

/// Gate one, over whichever dictionary reader is doing the reading.
pub fn read(
    reader: anytype,
    comptime name: []const u8,
    default: []const u8,
    exec: *const Execution,
) ![]const u8 {
    return (try reader.enumMember(name, "PredefinedColorSpace", &members, default, exec)).?;
}

/// Gate two: the two a bitmap can actually be. `prefix` is the reader's own
/// message prefix, which is all this refusal keeps of where it came from.
pub fn canvasSpace(
    comptime prefix: []const u8,
    name: []const u8,
    exec: *const Execution,
) !color.CanvasSpace {
    return std.meta.stringToEnum(color.CanvasSpace, name) orelse dictionary.throwTypeError(
        try std.fmt.allocPrint(
            exec.call_arena,
            prefix ++
                "The provided value '{s}' is not a valid enum value of the type PredefinedColorSpace.",
            .{name},
        ),
        exec,
    );
}
