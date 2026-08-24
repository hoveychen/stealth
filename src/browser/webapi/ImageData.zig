// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");
const Allocator = std.mem.Allocator;

const js = @import("../js/js.zig");
const color = @import("../color.zig");
const Page = @import("../Page.zig");
const dictionary = @import("dictionary.zig");
const color_space_gate = @import("canvas/color_space.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/ImageData/ImageData
const ImageData = @This();

_rc: lp.RC = .{},
_width: u32,
_height: u32,
_settings: Settings = .{},
_data: Data,

/// The pixels, in the typed array the settings' `pixelFormat` calls for.
///
/// All three formats carry the same four channels per pixel in the same order,
/// so `data.length` is the same whichever it is and the array's *type* is the
/// whole of what a page sees: `rgba-unorm8` is a Uint8ClampedArray of 0..255
/// bytes, `rgba-float16` a Float16Array and `rgba-float32` a Float32Array of
/// floats around 0..1 (measured --
/// results/canvas-image-data-construct.chrome.json, where each of the three
/// reports its own constructor's name and `len=4`).
pub const Data = union(Settings.PixelFormat) {
    @"rgba-unorm8": js.ArrayBufferRef(.uint8_clamped).Global,
    @"rgba-float16": js.ArrayBufferRef(.float16).Global,
    @"rgba-float32": js.ArrayBufferRef(.float32).Global,

    /// The typed array kind one arm hands out, for the code that is written
    /// once over all three.
    pub fn kind(comptime format: Settings.PixelFormat) js.ArrayType {
        return switch (format) {
            .@"rgba-unorm8" => .uint8_clamped,
            .@"rgba-float16" => .float16,
            .@"rgba-float32" => .float32,
        };
    }

    /// One channel of that array, which is what says how many bytes an element
    /// takes on the wire.
    pub fn Element(comptime format: Settings.PixelFormat) type {
        return switch (format) {
            .@"rgba-unorm8" => u8,
            .@"rgba-float16" => f16,
            .@"rgba-float32" => f32,
        };
    }
};

/// `ImageDataSettings`: the dictionary this constructor shares with
/// `createImageData` and `getImageData`, and the two members it carries.
///
/// It is *not* read the way getContext's dictionary is, even though both take a
/// PredefinedColorSpace: a non-object argument here is refused where there it
/// takes the defaults. Measured in probes/canvas-image-data-settings{,-2}.js:
///
///   getImageData(0, 0, 1, 1, 'nope') -> TypeError: … The provided value is not
///                                       of type 'ImageDataSettings'.
///   getContext('2d', 'nope')         -> the defaults
///
/// An array and a null are objects enough to be read as an empty dictionary in
/// both.
pub const Settings = struct {
    color_space: color.CanvasSpace = .srgb,
    pixel_format: PixelFormat = .@"rgba-unorm8",

    /// `ImageDataPixelFormat`, which picks the typed array `data` hands out —
    /// see `Data`. A widget that asks for float16 canvases (the Turnstile one
    /// asks for two of its four) reads the format off `data.constructor.name`
    /// without looking at a pixel.
    ///
    /// Three members, not two: `rgba-float32` is accepted by every entry point
    /// that takes this dictionary and hands out a Float32Array (measured --
    /// results/canvas-image-data-construct.chrome.json, and Chrome names it
    /// itself when refusing a Float32Array under another format).
    pub const PixelFormat = enum {
        @"rgba-unorm8",
        @"rgba-float16",
        @"rgba-float32",
    };

    const pixel_formats = [_][]const u8{ "rgba-unorm8", "rgba-float16", "rgba-float32" };

    /// The reader for one entry point. `Reader` carries the prefix that says
    /// where the call came from — "Failed to construct 'ImageData': " against
    /// "Failed to execute 'getImageData' on 'CanvasRenderingContext2D': " — and
    /// is the only thing the three differ in.
    pub fn Reading(comptime Reader: type) type {
        return struct {
            /// `default_space` is what an *absent* `colorSpace` member means,
            /// which is not always srgb: both canvas entry points default to
            /// the canvas's own space and only an explicit value overrides it,
            /// while `new ImageData` — which has no canvas — does default to
            /// srgb. Measured in probes/canvas-own-color-space.js: on a
            /// display-p3 canvas `getImageData(0, 0, 1, 1)` and
            /// `createImageData(1, 1)` both answer display-p3, and so do `{}`,
            /// `[]`, `null` and `{colorSpace: undefined}`.
            pub fn read(
                settings: ?js.Value,
                default_space: color.CanvasSpace,
                exec: *const Execution,
            ) !Settings {
                const reader = try Reader.read(settings, exec);
                // Alphabetical, which is the order Blink reads them in: a
                // throwing `colorSpace` getter pre-empts `pixelFormat`'s.
                const space = try color_space_gate.read(
                    reader,
                    "colorSpace",
                    @tagName(default_space),
                    exec,
                );
                const format = (try reader.enumMember(
                    "pixelFormat",
                    "ImageDataPixelFormat",
                    &pixel_formats,
                    "rgba-unorm8",
                    exec,
                )).?;
                return .{
                    // Gate two, after both members have been read, as it is on
                    // getContext's dictionary.
                    .color_space = try color_space_gate.canvasSpace(
                        Reader.message_prefix,
                        space,
                        exec,
                    ),
                    .pixel_format = std.meta.stringToEnum(PixelFormat, format).?,
                };
            }
        };
    }
};

/// This has many constructors:
///
/// ```js
/// new ImageData(width, height)
/// new ImageData(width, height, settings)
///
/// new ImageData(dataArray, width)
/// new ImageData(dataArray, width, height)
/// new ImageData(dataArray, width, height, settings)
/// ```
///
/// We currently support only the first 2.
pub fn constructor(width: u32, height: u32, settings: ?js.Value, exec: *Execution) !*ImageData {
    const Reading = Settings.Reading(dictionary.Reader("ImageData", "ImageDataSettings"));
    return init(width, height, try Reading.read(settings, .srgb, exec), exec);
}

/// The creator the three entry points share, past the point where the settings
/// have been read — each of them reads them with its own message prefix.
pub fn init(width: u32, height: u32, settings: Settings, exec: *Execution) !*ImageData {
    // Though arguments are unsigned long, these are capped to max. i32 on Chrome.
    // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/html/canvas/image_data.cc#L61
    const max_i32 = std.math.maxInt(i32);
    if (width == 0 or width > max_i32 or height == 0 or height > max_i32) {
        return error.IndexSizeError;
    }

    var size, var overflown = @mulWithOverflow(width, height);
    if (overflown == 1) {
        return error.IndexSizeError;
    }

    size, overflown = @mulWithOverflow(size, 4);
    if (overflown == 1) {
        return error.IndexSizeError;
    }

    const local = exec.js.local.?;
    return exec._factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._settings = settings,
        // `size` is the channel count, which is the element count in every
        // format -- only the bytes behind an element differ.
        ._data = switch (settings.pixel_format) {
            inline else => |format| @unionInit(
                Data,
                @tagName(format),
                try local.createTypedArray(Data.kind(format), size).persist(),
            ),
        },
    });
}

pub fn deinit(self: *ImageData, page: *Page) void {
    switch (self._data) {
        inline else => |data| data.release(),
    }
    page.factory.destroy(self);
}

pub fn releaseRef(self: *ImageData, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *ImageData) void {
    self._rc.acquire();
}

pub fn structuredSerialize(self: *const ImageData, writer: *js.StructuredWriter) !void {
    writer.writeUint32(self._width);
    writer.writeUint32(self._height);
    // A clone keeps the settings: they are as much of the object as the bytes.
    // The format especially so — the bytes alone would not say which typed
    // array to rebuild.
    writer.writeUint32(@intFromEnum(self._settings.color_space));
    writer.writeUint32(@intFromEnum(self._settings.pixel_format));
    switch (self._data) {
        inline else => |data| writer.writeBytes(
            std.mem.sliceAsBytes(data.local(writer.local).slice()),
        ),
    }
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*ImageData {
    const width = try reader.readUint32();
    const height = try reader.readUint32();
    const color_space = try reader.readUint32();
    const pixel_format = try reader.readUint32();
    const bytes = try reader.readBytes();

    const format = std.enums.fromInt(Settings.PixelFormat, pixel_format) orelse .@"rgba-unorm8";
    const data: Data = switch (format) {
        inline else => |tag| blk: {
            // The serialiser wrote whole elements out, so the byte count
            // divides by however wide this format's element is.
            const array = reader.local.createTypedArray(
                Data.kind(tag),
                bytes.len / @sizeOf(Data.Element(tag)),
            );
            @memcpy(std.mem.sliceAsBytes(array.slice()), bytes);
            break :blk @unionInit(Data, @tagName(tag), try array.persist());
        },
    };

    return page.factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._settings = .{
            .color_space = std.enums.fromInt(color.CanvasSpace, color_space) orelse .srgb,
            .pixel_format = format,
        },
        ._data = data,
    });
}

pub fn getWidth(self: *const ImageData) u32 {
    return self._width;
}

pub fn getHeight(self: *const ImageData) u32 {
    return self._height;
}

pub fn getData(self: *const ImageData) Data {
    return self._data;
}

/// The pixels as the straight-alpha RGBA8 every rasteriser entry point here
/// takes, whichever format they are stored in.
///
/// A unorm8 object hands over its own storage; a float one is quantised into
/// `arena` on the way, because the `Surface` behind all of this is eight bits a
/// channel and has nowhere to put the extra range. `round255` clamps, which is
/// what a channel outside 0..1 does: `[2, -1, 0.5, 1]` writes `ff0080ff`
/// (measured -- probes/canvas-image-data-construct.js).
pub fn straightBytes(
    self: *const ImageData,
    local: *const js.Local,
    arena: Allocator,
) ![]const u8 {
    return switch (self._data) {
        .@"rgba-unorm8" => |data| data.local(local).slice(),
        inline .@"rgba-float16", .@"rgba-float32" => |data| blk: {
            const from = data.local(local).slice();
            const into = try arena.alloc(u8, from.len);
            for (into, from) |*byte, channel| {
                byte.* = color.RGBA.round255(@as(f64, channel) * 255);
            }
            break :blk into;
        },
    };
}

pub fn getColorSpace(self: *const ImageData) []const u8 {
    return @tagName(self._settings.color_space);
}

pub fn getPixelFormat(self: *const ImageData) []const u8 {
    return @tagName(self._settings.pixel_format);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageData);

    pub const Meta = struct {
        pub const name = "ImageData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ImageData.constructor, .{});

    // Prototype getters, not own values: `Object.getOwnPropertyDescriptor` on
    // an instance answers undefined for both, and on the prototype answers a
    // getter (measured -- probes/canvas-image-data-settings-2.js).
    pub const colorSpace = bridge.accessor(ImageData.getColorSpace, null, .{});
    pub const pixelFormat = bridge.accessor(ImageData.getPixelFormat, null, .{});

    pub const data = bridge.accessor(ImageData.getData, null, .{});
    pub const width = bridge.accessor(ImageData.getWidth, null, .{});
    pub const height = bridge.accessor(ImageData.getHeight, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ImageData" {
    try testing.htmlRunner("image_data.html", .{});
}
