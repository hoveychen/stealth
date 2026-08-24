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

// `getContext`'s second argument: the dictionary every context type is created
// from, and the two shapes `getContextAttributes` answers it back as.
//
// Until this landed the argument was not a parameter at all — both canvas types
// took only the context name — so all four context types answered a fixed set
// of defaults. That is a one-line tell: the Turnstile widget builds four 2D
// contexts and passes `willReadFrequently: true` to every one of them
// (results/ibt2-oracle.json), and we answered `false` four times. The colour
// fields are the same story on a second axis — it varies `colorSpace` and
// `colorType` across the four and we answered srgb/unorm8 for all of them.
//
// The whole dictionary is measured, not derived from the IDL, in
// probes/canvas-context-settings{,-2,-3,-4}.js. What the readings say:
//
//   - It is *one* dictionary, `CanvasContextCreationAttributesModule`, shared by
//     the 2D and the WebGL members: a bad `powerPreference` names that same
//     dictionary when passed to `getContext('2d')`.
//   - It is converted before the context type is dispatched and before the
//     cached-context check, so `getContext('nonesuch', {colorSpace: 'bad'})`
//     throws and a second `getContext('2d', …)` on a canvas that already has one
//     throws too — even though the settings could not have been used either way.
//   - A non-object second argument is *not* a conversion failure, which is where
//     this departs from WebIDL's own rule: `getContext('2d', 'srgb')` takes the
//     defaults rather than throwing.
//   - Members are read in alphabetical order, so a throwing `alpha` getter beats
//     a bad `colorSpace` and a throwing `xrCompatible` one does not.
//   - `alpha`, `antialias`, `depth`, `desynchronized`,
//     `failIfMajorPerformanceCaveat`, `premultipliedAlpha`,
//     `preserveDrawingBuffer`, `stencil` and `xrCompatible` are plain booleans,
//     so ToBoolean: `{alpha: 0}` is false and `{alpha: 'false'}` is true.
//   - `willReadFrequently` is *not* a boolean but an enum, which is why the JS
//     boolean works at all — `true` stringifies onto the member "true". `1` and
//     "auto" are both refused; "undefined" is a member and means false.
//   - `toneMapping` is answered and never read: `{toneMapping: {mode:
//     'extended'}}` still reports "standard", and a bogus mode does not throw.
//
// Two of the members are honoured by the 2D context and dropped by WebGL, or the
// other way about; `Gl` says which.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/getContextAttributes
///
/// Field order is the key order Chrome enumerates, since a script can read
/// `Object.keys` without touching a single value.
pub const TwoD = struct {
    alpha: bool = true,
    colorSpace: []const u8 = "srgb",
    colorType: []const u8 = "unorm8",
    desynchronized: bool = false,
    toneMapping: ToneMapping = .{},
    willReadFrequently: bool = false,

    pub const ToneMapping = struct {
        mode: []const u8 = "standard",
    };
};

/// https://developer.mozilla.org/en-US/docs/Web/API/WebGLRenderingContext/getContextAttributes
///
/// Shared by WebGLRenderingContext and WebGL2RenderingContext, which answered
/// this from two identical private copies before.
pub const Gl = struct {
    alpha: bool = true,
    antialias: bool = true,
    depth: bool = true,
    /// Asked for and never granted: `{desynchronized: true}` still reads back
    /// false on a WebGL context, where the same member on a 2D one is honoured.
    desynchronized: bool = false,
    failIfMajorPerformanceCaveat: bool = false,
    powerPreference: []const u8 = "default",
    premultipliedAlpha: bool = true,
    preserveDrawingBuffer: bool = false,
    stencil: bool = false,
    /// Also asked for and never granted, for the reason `makeXRCompatible`
    /// rejects: there is no XR device to be compatible with.
    xrCompatible: bool = false,
};

/// One dictionary, read once, handed to whichever context type the call goes on
/// to build.
pub const Created = struct {
    two_d: TwoD = .{},
    gl: Gl = .{},
};

/// The IDL enum's own members. Four of them clear the dictionary conversion and
/// are then refused by the canvas itself, with a different message — see `read`.
const predefined_color_spaces = [_][]const u8{
    "srgb", "display-p3", "rec2020", "srgb-linear", "rec2100-hlg", "rec2100-pq",
};

/// The two a canvas can actually be.
const canvas_color_spaces = [_][]const u8{ "srgb", "display-p3" };

const color_types = [_][]const u8{ "unorm8", "float16" };
const power_preferences = [_][]const u8{ "default", "low-power", "high-performance" };

/// "undefined" is a member of the enum and means false, which is not the same
/// thing as the member being absent even though both read back the same.
const will_read_frequentlies = [_][]const u8{ "true", "false", "undefined" };

/// The reader for one canvas type. `interface` is the name its refusals carry:
/// the two differ only in that word ("Failed to execute 'getContext' on
/// 'HTMLCanvasElement'" against "… on 'OffscreenCanvas'").
pub fn Creation(comptime interface: []const u8) type {
    return struct {
        const Reader = dictionary.MethodReader(
            interface,
            "getContext",
            "CanvasContextCreationAttributesModule",
        );

        pub fn read(settings: ?js.Value, exec: *const Execution) !Created {
            // A non-object argument is the defaults rather than the
            // "is not of type" refusal `Reader.read` would give it, so it never
            // reaches the reader.
            const object: ?js.Value = if (settings) |value| blk: {
                break :blk if (value.isObject()) value else null;
            } else null;
            const reader = try Reader.read(object, exec);

            // Alphabetical, because that is the order Blink reads them in and a
            // page can tell: a member whose getter throws pre-empts every
            // refusal that would have come from a later one.
            const alpha = try reader.boolean("alpha", true);
            const antialias = try reader.boolean("antialias", true);
            const color_space = (try reader.enumMember(
                "colorSpace",
                "PredefinedColorSpace",
                &predefined_color_spaces,
                "srgb",
                exec,
            )).?;
            const color_type = (try reader.enumMember(
                "colorType",
                "CanvasPixelFormat",
                &color_types,
                "unorm8",
                exec,
            )).?;
            const depth = try reader.boolean("depth", true);
            const desynchronized = try reader.boolean("desynchronized", false);
            const fail_if_caveat = try reader.boolean("failIfMajorPerformanceCaveat", false);
            const power_preference = (try reader.enumMember(
                "powerPreference",
                "CanvasPowerPreference",
                &power_preferences,
                "default",
                exec,
            )).?;
            const premultiplied_alpha = try reader.boolean("premultipliedAlpha", true);
            const preserve_drawing_buffer = try reader.boolean("preserveDrawingBuffer", false);
            const stencil = try reader.boolean("stencil", false);
            const will_read_frequently = (try reader.enumMember(
                "willReadFrequently",
                "CanvasWillReadFrequently",
                &will_read_frequentlies,
                "false",
                exec,
            )).?;
            // Read for its side effect alone: the value is never granted, but a
            // getter on it still runs, and it has to run *after* colorSpace's.
            _ = try reader.boolean("xrCompatible", false);

            // The second gate. `rec2020` and the other three are members of
            // PredefinedColorSpace, so they clear the conversion above and are
            // refused here instead — by a message that names no property and
            // says "the type" where the conversion says "type".
            for (canvas_color_spaces) |candidate| {
                if (std.mem.eql(u8, candidate, color_space)) break;
            } else {
                return dictionary.throwTypeError(try std.fmt.allocPrint(
                    exec.call_arena,
                    Reader.message_prefix ++
                        "The provided value '{s}' is not a valid enum value of the type PredefinedColorSpace.",
                    .{color_space},
                ), exec);
            }

            return .{
                .two_d = .{
                    .alpha = alpha,
                    .colorSpace = color_space,
                    .colorType = color_type,
                    .desynchronized = desynchronized,
                    .willReadFrequently = std.mem.eql(u8, "true", will_read_frequently),
                },
                .gl = .{
                    .alpha = alpha,
                    .antialias = antialias,
                    .depth = depth,
                    .failIfMajorPerformanceCaveat = fail_if_caveat,
                    .powerPreference = power_preference,
                    .premultipliedAlpha = premultiplied_alpha,
                    .preserveDrawingBuffer = preserve_drawing_buffer,
                    .stencil = stencil,
                },
            };
        }
    };
}
