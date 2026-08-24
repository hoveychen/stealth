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

    /// What the array calls itself in JS, which is how Chrome names it when the
    /// data constructor's array and pixelFormat disagree.
    pub fn arrayName(comptime format: Settings.PixelFormat) []const u8 {
        return switch (format) {
            .@"rgba-unorm8" => "Uint8ClampedArray",
            .@"rgba-float16" => "Float16Array",
            .@"rgba-float32" => "Float32Array",
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

/// Two overloads, five spellings:
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
/// Which one a call is depends only on the *type* of the first argument, not on
/// how many there are: anything that is not one of the three `ImageDataArray`
/// members is a width, and every argument after it moves up a slot. So
/// `new ImageData(new Uint8Array(4), 1, 1)` is not a near-miss of the data form
/// — it is the size form, and Chrome refuses it for its *third* argument, which
/// landed where the settings dictionary goes (measured --
/// probes/canvas-image-data-construct.js).
///
/// Both arguments are taken as `js.Value` rather than converted by the bridge
/// because that type test has to happen before either is read as a number.
pub fn constructor(
    first: js.Value,
    second: js.Value,
    third: ?js.Value,
    fourth: ?js.Value,
    exec: *Execution,
) !*ImageData {
    const Reading = Settings.Reading(dictionary.Reader("ImageData", "ImageDataSettings"));

    const format = arrayFormat(first) orelse {
        const width = first.toU32() catch 0;
        const height = second.toU32() catch 0;
        const settings = try Reading.read(third, .srgb, exec);
        try refuseSize(width, height, exec);
        return init(width, height, settings, exec);
    };

    const width = second.toU32() catch 0;
    // An undefined height counts as absent only while it is the last argument
    // given. Once a fourth follows it, it is converted like any other value and
    // becomes a zero: `(data, w, undefined)` infers a height where
    // `(data, w, undefined, settings)` is refused for one (measured).
    const height: ?u32 = if (third) |value| blk: {
        if (value.isUndefined() and fourth == null) {
            break :blk null;
        }
        break :blk value.toU32() catch 0;
    } else null;
    const settings = try Reading.read(fourth, .srgb, exec);
    return fromArray(first, format, width, height, settings, exec);
}

/// Which of `ImageDataArray`'s three members a value is, if it is one at all —
/// which is the whole of this constructor's overload resolution.
fn arrayFormat(value: js.Value) ?Settings.PixelFormat {
    if (value.isUint8ClampedArray()) return .@"rgba-unorm8";
    if (value.isFloat16Array()) return .@"rgba-float16";
    if (value.isFloat32Array()) return .@"rgba-float32";
    return null;
}

/// The data overload, past the point where its arguments have been converted.
///
/// Every refusal below is Blink's own sentence, and they are in Blink's own
/// order — which is measured rather than guessed, from calls that earn two of
/// them at once (probes/canvas-image-data-construct.js, the `order` group). A
/// zero width pre-empts even the array's type; the type pre-empts everything
/// about the array's length.
fn fromArray(
    value: js.Value,
    format: Settings.PixelFormat,
    width: u32,
    height: ?u32,
    settings: Settings,
    exec: *Execution,
) !*ImageData {
    const max_i32 = std.math.maxInt(i32);
    if (width == 0) {
        return sourceZero("width", exec);
    }
    if (width > max_i32) {
        return sizeRange(exec);
    }
    // The array's type decides the format, so a pixelFormat naming another one
    // is a refusal rather than a conversion — and the sentence names the array,
    // not the setting.
    if (format != settings.pixel_format) {
        return switch (format) {
            inline else => |tag| refuse(
                "InvalidStateError",
                Data.arrayName(tag) ++ " must use " ++ @tagName(tag) ++ " pixelFormat.",
                exec,
            ),
        };
    }

    // The element count, which is the channel count in every format: only the
    // bytes behind an element differ. A detached array reports zero, which is
    // the sentence Chrome gives it.
    const length = switch (format) {
        inline else => |tag| blk: {
            const ref: js.ArrayBufferRef(Data.kind(tag)) = .{
                .local = exec.js.local.?,
                .handle = value.handle,
            };
            break :blk ref.slice().len;
        },
    };
    if (length == 0) {
        return refuse("InvalidStateError", "The input data has zero elements.", exec);
    }
    if (length % 4 != 0) {
        return refuse("InvalidStateError", "The input data length is not a multiple of 4.", exec);
    }
    const row = @as(usize, width) * 4;
    if (length % row != 0) {
        return refuse(
            "IndexSizeError",
            "The input data length is not a multiple of (4 * width).",
            exec,
        );
    }
    const rows = length / row;
    if (height) |given| {
        if (given == 0) {
            return sourceZero("height", exec);
        }
        if (given > max_i32) {
            return sizeRange(exec);
        }
        if (given != rows) {
            return refuse(
                "IndexSizeError",
                "The input data length is not equal to (4 * width * height).",
                exec,
            );
        }
    }

    return exec._factory.create(ImageData{
        ._width = width,
        ._height = @intCast(rows),
        ._settings = settings,
        // The array itself, not a copy of it: `new ImageData(a, 1, 1).data === a`
        // is true, writes go both ways, and a view onto part of a buffer keeps
        // its offset (measured).
        ._data = switch (format) {
            inline else => |tag| @unionInit(Data, @tagName(tag), try (js.ArrayBufferRef(
                Data.kind(tag),
            ){ .local = exec.js.local.?, .handle = value.handle }).persist()),
        },
    });
}

const message_prefix = "Failed to construct 'ImageData': ";

fn refuse(comptime name: []const u8, comptime message: []const u8, exec: *const Execution) anyerror {
    return dictionary.throwDom(name, message_prefix ++ message, exec);
}

fn sourceZero(comptime dimension: []const u8, exec: *const Execution) anyerror {
    return refuse("IndexSizeError", "The source " ++ dimension ++ " is zero or not a number.", exec);
}

fn sizeRange(exec: *const Execution) anyerror {
    return refuse("IndexSizeError", "The requested image size exceeds the supported range.", exec);
}

/// The size overload's own refusals, which are the same sentences the data one
/// reaches (measured -- the `sized` group of probes/canvas-image-data-construct.js:
/// `new ImageData(0, 1)` names the width, `(1, 0)` the height, and `(-1, 1)`,
/// `(1e10, 1)` and `(65536, 65536)` are all one range refusal).
fn refuseSize(width: u32, height: u32, exec: *const Execution) !void {
    const max_i32 = std.math.maxInt(i32);
    if (width == 0) {
        return sourceZero("width", exec);
    }
    if (width > max_i32) {
        return sizeRange(exec);
    }
    if (height == 0) {
        return sourceZero("height", exec);
    }
    if (height > max_i32) {
        return sizeRange(exec);
    }
    const area, const overflown = @mulWithOverflow(width, height);
    if (overflown == 1 or @mulWithOverflow(area, 4)[1] == 1) {
        return sizeRange(exec);
    }
}

/// The creator the canvas entry points share, past the point where the settings
/// have been read — each of them reads them with its own message prefix, and
/// refuses a bad size with its own too, so the refusal here stays the bare error
/// the bridge maps to a plain DOMException.
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
