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

// VideoFrame and VideoColorSpace: the two WebCodecs interfaces a page can build
// out of things this engine already has. Unlike WebGPU, these are reachable --
// `new VideoFrame(canvas, {timestamp})` works in Chrome and works here, and it
// hands back real pixels, because the 2D canvas behind it really did rasterise.
//
// Everything below was read off a Chrome 150 rather than off the spec
// (probe-win43/44/44b..44f, win44*-chrome.json). The spec-vs-Chrome gaps this
// found are marked where they matter; the ones worth naming up front:
//
//   * A canvas source produces a **BGRA** frame and an OffscreenCanvas source an
//     **RGBA** one -- a GPU-backed bitmap versus a software one -- and copyTo
//     really does hand back the byte order the format promises (measured:
//     a red pixel reads 255,0,0,255 through getImageData and 0,0,255,255
//     through VideoFrame.copyTo).
//   * `new VideoFrame(bytes)` with one argument does not consider the buffer
//     overload at all: it reports the *image* union. Two arguments is what
//     turns "not of type '(CSSImageValue or ...)'" into "Overload resolution
//     failed."
//   * A missing timestamp is bare prose -- "VideoFrameInit must provide
//     timestamp" -- rather than the dictionary wording, and it is checked after
//     every member has been read but before visibleRect and displayWidth are
//     validated.
//   * `rotation` is rounded to a quarter turn with ties going *up*, not away
//     from zero: 45 is 90 but -45 is 0.
//   * A closed frame keeps its timestamp, hands back a *new* all-null
//     VideoColorSpace (not the one it had), and answers null for both rects.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const Canvas = @import("../element/html/Canvas.zig");
const Image = @import("../element/html/Image.zig");
const Video = @import("../element/html/Video.zig");
const ImageBitmap = @import("../canvas/ImageBitmap.zig");
const OffscreenCanvas = @import("../canvas/OffscreenCanvas.zig");
const DOMException = @import("../DOMException.zig");
const DOMRectReadOnly = @import("../DOMRectReadOnly.zig");

const Execution = js.Execution;

// The three VideoColorSpaceInit enumerations, in Chrome's order. Only these
// values are accepted; the spec's wider candidate lists (smpte240m, film,
// srgb, identity, ycgco) are all rejected as invalid enum values.
const PRIMARIES = [_][]const u8{ "bt709", "bt470bg", "smpte170m", "bt2020", "smpte432" };
const TRANSFER = [_][]const u8{ "bt709", "smpte170m", "iec61966-2-1", "linear", "pq", "hlg" };
const MATRIX = [_][]const u8{ "rgb", "bt709", "bt470bg", "smpte170m", "bt2020-ncl" };

pub const VideoColorSpace = struct {
    _primaries: ?[]const u8 = null,
    _transfer: ?[]const u8 = null,
    _matrix: ?[]const u8 = null,
    _full_range: ?bool = null,

    /// What every RGB-formatted frame reports.
    const srgb = VideoColorSpace{
        ._primaries = "bt709",
        ._transfer = "iec61966-2-1",
        ._matrix = "rgb",
        ._full_range = true,
    };

    /// What a planar (I420 / NV12 / ...) buffer frame reports instead.
    const rec709 = VideoColorSpace{
        ._primaries = "bt709",
        ._transfer = "bt709",
        ._matrix = "bt709",
        ._full_range = false,
    };

    pub fn constructor(init_: ?js.Value, exec: *const Execution) !*VideoColorSpace {
        const Reader = dictionary.Reader("VideoColorSpace", "VideoColorSpaceInit");
        return exec._factory.create(try read(try Reader.read(init_, exec), exec));
    }

    /// The four members, read through whichever reader owns the message prefix:
    /// a VideoFrameBufferInit's `colorSpace` nests the wording rather than
    /// restating the constructor. The members are read in the prototype's
    /// order, which is also the order Chrome reports a bad one in.
    fn read(reader: anytype, exec: *const Execution) !VideoColorSpace {
        return .{
            ._primaries = try reader.nullableEnum("primaries", "VideoColorPrimaries", &PRIMARIES, exec),
            ._transfer = try reader.nullableEnum("transfer", "VideoTransferCharacteristics", &TRANSFER, exec),
            ._matrix = try reader.nullableEnum("matrix", "VideoMatrixCoefficients", &MATRIX, exec),
            ._full_range = try reader.nullableBoolean("fullRange"),
        };
    }

    pub fn getPrimaries(self: *const VideoColorSpace) ?[]const u8 {
        return self._primaries;
    }

    pub fn getTransfer(self: *const VideoColorSpace) ?[]const u8 {
        return self._transfer;
    }

    pub fn getMatrix(self: *const VideoColorSpace) ?[]const u8 {
        return self._matrix;
    }

    pub fn getFullRange(self: *const VideoColorSpace) ?bool {
        return self._full_range;
    }

    /// A plain object whose keys are alphabetical -- not the prototype's order.
    pub fn toJSON(self: *const VideoColorSpace) struct {
        fullRange: ?bool,
        matrix: ?[]const u8,
        primaries: ?[]const u8,
        transfer: ?[]const u8,
    } {
        return .{
            .fullRange = self._full_range,
            .matrix = self._matrix,
            .primaries = self._primaries,
            .transfer = self._transfer,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VideoColorSpace);

        pub const Meta = struct {
            pub const name = "VideoColorSpace";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(VideoColorSpace.constructor, .{});
        pub const primaries = bridge.accessor(VideoColorSpace.getPrimaries, null, .{});
        pub const transfer = bridge.accessor(VideoColorSpace.getTransfer, null, .{});
        pub const matrix = bridge.accessor(VideoColorSpace.getMatrix, null, .{});
        pub const fullRange = bridge.accessor(VideoColorSpace.getFullRange, null, .{});
        pub const toJSON = bridge.function(VideoColorSpace.toJSON, .{});
    };
};

/// A VideoPixelFormat: its planes, and whether dropping alpha renames it.
const PixelFormat = struct {
    name: []const u8,
    planes: []const Plane,
    /// What `alpha: 'discard'` turns this into. Only the two RGB formats with
    /// an alpha channel are renamed; I420A and friends keep their name
    /// (measured).
    opaque_name: ?[]const u8 = null,

    const Plane = struct {
        /// Horizontal and vertical subsampling: 2 means the plane has half as
        /// many samples along that axis.
        x_sub: u32 = 1,
        y_sub: u32 = 1,
        bytes: u32,
    };

    const rgb = [_]Plane{.{ .bytes = 4 }};
    const yuv420 = [_]Plane{ .{ .bytes = 1 }, .{ .x_sub = 2, .y_sub = 2, .bytes = 1 }, .{ .x_sub = 2, .y_sub = 2, .bytes = 1 } };
    const yuv420a = yuv420 ++ [_]Plane{.{ .bytes = 1 }};
    const yuv422 = [_]Plane{ .{ .bytes = 1 }, .{ .x_sub = 2, .bytes = 1 }, .{ .x_sub = 2, .bytes = 1 } };
    const yuv422a = yuv422 ++ [_]Plane{.{ .bytes = 1 }};
    const yuv444 = [_]Plane{ .{ .bytes = 1 }, .{ .bytes = 1 }, .{ .bytes = 1 } };
    const yuv444a = yuv444 ++ [_]Plane{.{ .bytes = 1 }};
    const nv12 = [_]Plane{ .{ .bytes = 1 }, .{ .x_sub = 2, .y_sub = 2, .bytes = 2 } };

    /// The same plane layout with two bytes per sample, which is what the P10
    /// and P12 variants are.
    fn wide(comptime planes: []const Plane) []const Plane {
        comptime var out: [planes.len]Plane = undefined;
        inline for (planes, 0..) |plane, i| {
            out[i] = .{ .x_sub = plane.x_sub, .y_sub = plane.y_sub, .bytes = plane.bytes * 2 };
        }
        const frozen = out;
        return &frozen;
    }
};

/// The twenty values Chrome 150 accepts, in the order the enum declares them.
/// Note the three holes: I420AP12, I422AP12 and I444AP12 are *not* valid enum
/// values even though their P10 siblings are (measured).
const FORMATS = [_]PixelFormat{
    .{ .name = "I420", .planes = &PixelFormat.yuv420 },
    .{ .name = "I420P10", .planes = PixelFormat.wide(&PixelFormat.yuv420) },
    .{ .name = "I420P12", .planes = PixelFormat.wide(&PixelFormat.yuv420) },
    .{ .name = "I420A", .planes = &PixelFormat.yuv420a },
    .{ .name = "I420AP10", .planes = PixelFormat.wide(&PixelFormat.yuv420a) },
    .{ .name = "I422", .planes = &PixelFormat.yuv422 },
    .{ .name = "I422P10", .planes = PixelFormat.wide(&PixelFormat.yuv422) },
    .{ .name = "I422P12", .planes = PixelFormat.wide(&PixelFormat.yuv422) },
    .{ .name = "I422A", .planes = &PixelFormat.yuv422a },
    .{ .name = "I422AP10", .planes = PixelFormat.wide(&PixelFormat.yuv422a) },
    .{ .name = "I444", .planes = &PixelFormat.yuv444 },
    .{ .name = "I444P10", .planes = PixelFormat.wide(&PixelFormat.yuv444) },
    .{ .name = "I444P12", .planes = PixelFormat.wide(&PixelFormat.yuv444) },
    .{ .name = "I444A", .planes = &PixelFormat.yuv444a },
    .{ .name = "I444AP10", .planes = PixelFormat.wide(&PixelFormat.yuv444a) },
    .{ .name = "NV12", .planes = &PixelFormat.nv12 },
    .{ .name = "RGBA", .planes = &PixelFormat.rgb, .opaque_name = "RGBX" },
    .{ .name = "RGBX", .planes = &PixelFormat.rgb },
    .{ .name = "BGRA", .planes = &PixelFormat.rgb, .opaque_name = "BGRX" },
    .{ .name = "BGRX", .planes = &PixelFormat.rgb },
};

const FORMAT_NAMES = blk: {
    var names: [FORMATS.len][]const u8 = undefined;
    for (FORMATS, 0..) |format, i| {
        names[i] = format.name;
    }
    const frozen = names;
    break :blk frozen;
};

fn formatByName(name: []const u8) *const PixelFormat {
    for (&FORMATS) |*format| {
        if (std.mem.eql(u8, format.name, name)) {
            return format;
        }
    }
    unreachable; // every name came out of FORMAT_NAMES
}

fn isPlanar(format: *const PixelFormat) bool {
    return format.planes.len > 1;
}

const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// One entry of what copyTo resolves with.
const PlaneLayout = struct {
    offset: u32,
    stride: u32,
};

pub const VideoFrame = struct {
    _format: *const PixelFormat,
    _timestamp: i64,
    _duration: ?u64,
    _coded_width: u32,
    _coded_height: u32,
    _visible: Rect,
    _display_width: u32,
    _display_height: u32,
    _rotation: u32,
    _flip: bool,
    _color_space: *VideoColorSpace,
    /// The coded picture, in `_format`, when the source had one. Null is a
    /// frame whose pixels this engine never had -- an ImageBitmap, which
    /// carries dimensions and nothing else.
    _pixels: ?[]const u8,
    _closed: bool = false,
    /// Cached so `frame.codedRect === frame.codedRect` holds, which it does in
    /// Chrome.
    _coded_rect: *DOMRectReadOnly,
    _visible_rect: *DOMRectReadOnly,

    const PREFIX = "Failed to construct 'VideoFrame': ";

    /// The image half of the overload, spelled as Chrome spells it when nothing
    /// matches. CSSImageValue and SVGImageElement are in the union even though
    /// neither is constructible here.
    const IMAGE_SOURCE = "(CSSImageValue or HTMLCanvasElement or HTMLImageElement or " ++
        "HTMLVideoElement or ImageBitmap or OffscreenCanvas or SVGImageElement or VideoFrame)";

    pub fn constructor(source: js.Value, init_: ?js.Value, exec: *const Execution) !*VideoFrame {
        if (try imageSource(source, exec)) |image| {
            return fromImage(image, init_, exec);
        }
        // One argument never reaches the buffer overload: Chrome reports the
        // image union instead of "Overload resolution failed."
        const init = init_ orelse return dictionary.throwTypeError(
            PREFIX ++ "The provided value is not of type '" ++ IMAGE_SOURCE ++ "'.",
            exec,
        );
        const data = bufferSource(source) orelse return dictionary.throwTypeError(
            PREFIX ++ "Overload resolution failed.",
            exec,
        );
        return fromBuffer(data, init, exec);
    }

    /// What the image half of the overload resolved to, and the size and
    /// format that source implies.
    const ImageSource = struct {
        width: u32,
        height: u32,
        format: []const u8,
        pixels: ?[]const u8,
        /// Set only when the source is another VideoFrame, whose timestamp,
        /// duration, visible rect, rotation and flip are inherited.
        frame: ?*const VideoFrame = null,
    };

    fn imageSource(source: js.Value, exec: *const Execution) !?ImageSource {
        if (source.toZig(*Canvas)) |canvas| {
            const width = canvas.getWidth();
            const height = canvas.getHeight();
            if (width == 0 or height == 0) {
                return invalidSource("The image argument is a canvas element with a width or height of 0.", exec);
            }
            // A GPU-backed HTMLCanvasElement bitmap is BGRA in Chrome, so the
            // pixels have to be swapped out of the rasteriser's RGBA order.
            return .{
                .width = width,
                .height = height,
                .format = "BGRA",
                .pixels = try swapRedBlue(canvas.pixels(), width, height, exec),
            };
        } else |_| {}

        if (source.toZig(*OffscreenCanvas)) |canvas| {
            const width = canvas.getWidth();
            const height = canvas.getHeight();
            if (width == 0 or height == 0) {
                return invalidSource("The image argument is an OffscreenCanvas element with a width or height of 0.", exec);
            }
            // Software-backed, and therefore RGBA: the rasteriser's own order,
            // so nothing is swapped.
            return .{ .width = width, .height = height, .format = "RGBA", .pixels = canvas.pixels() };
        } else |_| {}

        if (source.toZig(*ImageBitmap)) |bitmap| {
            if (bitmap.getWidth() == 0 and bitmap.getHeight() == 0) {
                // close() is what zeroes both, and a closed bitmap is what
                // Chrome calls detached.
                return invalidSource("The image source is detached", exec);
            }
            return .{ .width = bitmap.getWidth(), .height = bitmap.getHeight(), .format = "BGRA", .pixels = null };
        } else |_| {}

        if (source.toZig(*VideoFrame)) |frame| {
            if (frame._closed) {
                return invalidSource("The VideoFrame has been closed", exec);
            }
            return .{
                .width = frame._coded_width,
                .height = frame._coded_height,
                .format = frame._format.name,
                .pixels = frame._pixels,
                .frame = frame,
            };
        } else |_| {}

        // Neither an <img> nor a <video> ever has decoded data in this engine,
        // which is the same state Chrome refuses an unloaded one in.
        if (source.toZig(*Image)) |_| {
            return invalidSource("Invalid source state", exec);
        } else |_| {}
        if (source.toZig(*Video)) |_| {
            return invalidSource("Invalid source state", exec);
        } else |_| {}

        return null;
    }

    fn invalidSource(comptime message: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwDom("InvalidStateError", PREFIX ++ message, exec);
    }

    /// `new VideoFrame(canvasOrFrame, init)`.
    fn fromImage(image: ImageSource, init_: ?js.Value, exec: *const Execution) !*VideoFrame {
        const Reader = dictionary.Reader("VideoFrame", "VideoFrameInit");
        const init = try Reader.read(init_, exec);

        // Alphabetical, which is the order Chrome reads them in.
        const alpha = try init.enumMember("alpha", "AlphaOption", &.{ "keep", "discard" }, "keep", exec);
        const display_height = try init.enforcedInt("displayHeight", u32, "unsigned long", exec);
        const display_width = try init.enforcedInt("displayWidth", u32, "unsigned long", exec);
        const duration = try init.enforcedInt("duration", u64, "unsigned long long", exec);
        const flip = try init.present("flip");
        const rotation_given = try init.present("rotation");
        const rotation = try init.double("rotation", 0, exec);
        const timestamp = try init.enforcedInt("timestamp", i64, "long long", exec);
        const visible = try readVisibleRect(Reader, init, exec);

        var format = formatByName(image.format);
        if (std.mem.eql(u8, alpha.?, "discard")) {
            if (format.opaque_name) |name| {
                format = formatByName(name);
            }
        }

        // A frame source carries its own timestamp, so the init may leave it
        // out; anything else must provide one.
        const source_frame = image.frame;
        const stamp = timestamp orelse blk: {
            const frame = source_frame orelse return dictionary.throwTypeError(
                PREFIX ++ "VideoFrameInit must provide timestamp",
                exec,
            );
            break :blk frame._timestamp;
        };

        const visible_rect = visible orelse blk: {
            if (source_frame) |frame| {
                break :blk frame._visible;
            }
            break :blk Rect{ .x = 0, .y = 0, .width = image.width, .height = image.height };
        };
        try validateVisibleRect(visible_rect, image.width, image.height, PREFIX, exec);

        const turn = blk: {
            if (rotation_given != null) {
                break :blk quarterTurn(rotation);
            }
            break :blk if (source_frame) |frame| frame._rotation else 0;
        };

        return create(.{
            .format = format,
            .timestamp = stamp,
            .duration = duration orelse (if (source_frame) |frame| frame._duration else null),
            .coded_width = image.width,
            .coded_height = image.height,
            .visible = visible_rect,
            .display = try displaySize(display_width, display_height, visible_rect, turn, PREFIX, exec),
            .rotation = turn,
            .flip = if (flip) |value| value.toBool() else (if (source_frame) |frame| frame._flip else false),
            .color_space = if (source_frame) |frame| frame._color_space.* else defaultColorSpace(format),
            .pixels = image.pixels,
        }, exec);
    }

    /// `new VideoFrame(bufferSource, init)`, whose init is required and whose
    /// members are read alphabetically -- so `{}` complains about codedHeight
    /// before codedWidth, and about both before format.
    fn fromBuffer(data: []const u8, init_: js.Value, exec: *const Execution) !*VideoFrame {
        const Reader = dictionary.Reader("VideoFrame", "VideoFrameBufferInit");
        const init = try Reader.readRequired(init_, exec);

        const coded_height = try init.enforcedInt("codedHeight", u32, "unsigned long", exec) orelse
            return Reader.missingMember("codedHeight", exec);
        const coded_width = try init.enforcedInt("codedWidth", u32, "unsigned long", exec) orelse
            return Reader.missingMember("codedWidth", exec);
        const color_space = try readColorSpace(Reader, init, exec);
        const display_height = try init.enforcedInt("displayHeight", u32, "unsigned long", exec);
        const display_width = try init.enforcedInt("displayWidth", u32, "unsigned long", exec);
        const duration = try init.enforcedInt("duration", u64, "unsigned long long", exec);
        const flip = try init.boolean("flip", false);
        const format_name = (try init.enumMember("format", "VideoPixelFormat", &FORMAT_NAMES, null, exec)) orelse
            return Reader.missingMember("format", exec);
        const rotation = try init.double("rotation", 0, exec);
        const timestamp = try init.enforcedInt("timestamp", i64, "long long", exec) orelse
            return Reader.missingMember("timestamp", exec);
        const visible = try readVisibleRect(Reader, init, exec);

        const format = formatByName(format_name);
        if (coded_width == 0) {
            return dictionary.throwTypeError(PREFIX ++ "codedWidth must be nonzero.", exec);
        }
        if (coded_height == 0) {
            return dictionary.throwTypeError(PREFIX ++ "codedHeight must be nonzero.", exec);
        }

        const visible_rect = visible orelse Rect{ .x = 0, .y = 0, .width = coded_width, .height = coded_height };
        try validateVisibleRect(visible_rect, coded_width, coded_height, PREFIX, exec);

        const needed = allocationFor(format, .{ .x = 0, .y = 0, .width = coded_width, .height = coded_height });
        if (data.len < needed) {
            return dictionary.throwTypeError(PREFIX ++ "data is not large enough.", exec);
        }

        const turn = quarterTurn(rotation);
        return create(.{
            .format = format,
            .timestamp = timestamp,
            .duration = duration,
            .coded_width = coded_width,
            .coded_height = coded_height,
            .visible = visible_rect,
            .display = try displaySize(display_width, display_height, visible_rect, turn, PREFIX, exec),
            .rotation = turn,
            .flip = flip,
            .color_space = color_space orelse defaultColorSpace(format),
            .pixels = try exec.arena.dupe(u8, data[0..needed]),
        }, exec);
    }

    const Fields = struct {
        format: *const PixelFormat,
        timestamp: i64,
        duration: ?u64,
        coded_width: u32,
        coded_height: u32,
        visible: Rect,
        display: Rect,
        rotation: u32,
        flip: bool,
        color_space: VideoColorSpace,
        pixels: ?[]const u8,
    };

    fn create(fields: Fields, exec: *const Execution) !*VideoFrame {
        return exec._factory.create(VideoFrame{
            ._format = fields.format,
            ._timestamp = fields.timestamp,
            ._duration = fields.duration,
            ._coded_width = fields.coded_width,
            ._coded_height = fields.coded_height,
            ._visible = fields.visible,
            ._display_width = fields.display.width,
            ._display_height = fields.display.height,
            ._rotation = fields.rotation,
            ._flip = fields.flip,
            ._color_space = try exec._factory.create(fields.color_space),
            ._pixels = fields.pixels,
            ._coded_rect = try DOMRectReadOnly.createBare(.{
                .width = @floatFromInt(fields.coded_width),
                .height = @floatFromInt(fields.coded_height),
            }, exec._factory),
            ._visible_rect = try DOMRectReadOnly.createBare(.{
                .x = @floatFromInt(fields.visible.x),
                .y = @floatFromInt(fields.visible.y),
                .width = @floatFromInt(fields.visible.width),
                .height = @floatFromInt(fields.visible.height),
            }, exec._factory),
        });
    }

    fn defaultColorSpace(format: *const PixelFormat) VideoColorSpace {
        return if (isPlanar(format)) VideoColorSpace.rec709 else VideoColorSpace.srgb;
    }

    /// The nested `colorSpace` member of a VideoFrameBufferInit.
    fn readColorSpace(comptime Reader: type, init: anytype, exec: *const Execution) !?VideoColorSpace {
        const member = (try init.present("colorSpace")) orelse return null;
        const Nested = dictionary.Nested(Reader, "colorSpace", "VideoColorSpaceInit");
        return try VideoColorSpace.read(try Nested.read(member, exec), exec);
    }

    /// A DOMRectInit whose doubles truncate toward zero.
    fn readVisibleRect(comptime Reader: type, init: anytype, exec: *const Execution) !?Rect {
        return readRectMember(Reader, init, "visibleRect", exec);
    }

    /// Negative components are not a conversion error -- Chrome reports them
    /// further down as an invalid rect -- so the sign survives as the sentinel
    /// `maxInt(u32)`, which no real coded size can reach.
    const NEGATIVE = std.math.maxInt(u32);

    fn rectMember(rect: anytype, comptime name: []const u8, exec: *const Execution) !u32 {
        const value = try rect.double(name, 0, exec);
        if (value < 0) {
            return NEGATIVE;
        }
        return @intFromFloat(@min(@trunc(value), @as(f64, NEGATIVE - 1)));
    }

    fn validateVisibleRect(
        rect: Rect,
        coded_width: u32,
        coded_height: u32,
        comptime prefix: []const u8,
        exec: *const Execution,
    ) !void {
        if (rect.x == NEGATIVE) {
            return dictionary.throwTypeError(prefix ++ "Invalid visibleRect. x cannot be negative.", exec);
        }
        if (rect.y == NEGATIVE) {
            return dictionary.throwTypeError(prefix ++ "Invalid visibleRect. y cannot be negative.", exec);
        }
        if (rect.width == 0 or rect.width == NEGATIVE) {
            return dictionary.throwTypeError(prefix ++ "Invalid visibleRect. width must be nonzero.", exec);
        }
        if (rect.height == 0 or rect.height == NEGATIVE) {
            return dictionary.throwTypeError(prefix ++ "Invalid visibleRect. height must be nonzero.", exec);
        }
        if (rect.x + rect.width > coded_width) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                prefix ++ "Invalid visibleRect. right {d} exceeds codedWidth {d}.",
                .{ rect.x + rect.width, coded_width },
            ), exec);
        }
        if (rect.y + rect.height > coded_height) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                prefix ++ "Invalid visibleRect. bottom {d} exceeds codedHeight {d}.",
                .{ rect.y + rect.height, coded_height },
            ), exec);
        }
    }

    /// displayWidth and displayHeight come as a pair or not at all, and a
    /// quarter turn swaps whichever pair is in force.
    fn displaySize(
        width_: ?u32,
        height_: ?u32,
        visible: Rect,
        rotation: u32,
        comptime prefix: []const u8,
        exec: *const Execution,
    ) !Rect {
        if (width_ != null and height_ == null) {
            return dictionary.throwTypeError(prefix ++ "displayWidth specified without displayHeight.", exec);
        }
        if (height_ != null and width_ == null) {
            return dictionary.throwTypeError(prefix ++ "displayHeight specified without displayWidth.", exec);
        }
        var width = visible.width;
        var height = visible.height;
        if (width_) |given| {
            if (given == 0) {
                return dictionary.throwTypeError(prefix ++ "displayWidth must be nonzero.", exec);
            }
            if (height_.? == 0) {
                return dictionary.throwTypeError(prefix ++ "displayHeight must be nonzero.", exec);
            }
            width = given;
            height = height_.?;
        }
        if (rotation == 90 or rotation == 270) {
            return .{ .x = 0, .y = 0, .width = height, .height = width };
        }
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }

    /// Chrome rounds `rotation` to a quarter turn with ties going *up* rather
    /// than away from zero: 45 becomes 90 but -45 becomes 0 (measured across
    /// 44, 45, 46, 135, 225, -45, -90, 359 and 450).
    fn quarterTurn(degrees: f64) u32 {
        const quarters = @floor(degrees / 90 + 0.5);
        const wrapped = @mod(quarters, 4);
        return @as(u32, @intFromFloat(wrapped)) * 90;
    }

    /// BGRA out of the rasteriser's RGBA. Null in, null out: a canvas that
    /// never drew anything reports transparent black either way.
    fn swapRedBlue(source: ?[]const u8, width: u32, height: u32, exec: *const Execution) !?[]const u8 {
        const rgba = source orelse return null;
        const out = try exec.arena.alloc(u8, @as(usize, width) * height * 4);
        var i: usize = 0;
        while (i + 3 < rgba.len and i + 3 < out.len) : (i += 4) {
            out[i] = rgba[i + 2];
            out[i + 1] = rgba[i + 1];
            out[i + 2] = rgba[i];
            out[i + 3] = rgba[i + 3];
        }
        return out;
    }

    pub fn getFormat(self: *const VideoFrame) ?[]const u8 {
        return if (self._closed) null else self._format.name;
    }

    /// The one field a closed frame keeps.
    ///
    /// A `long long` reaches JS as a Number, not a BigInt: the bridge maps a
    /// Zig i64 to BigInt, which `frame.timestamp === 1234` would see straight
    /// through, so both microsecond fields are handed over as doubles.
    pub fn getTimestamp(self: *const VideoFrame) f64 {
        return @floatFromInt(self._timestamp);
    }

    pub fn getDuration(self: *const VideoFrame) ?f64 {
        if (self._closed) {
            return null;
        }
        const duration = self._duration orelse return null;
        return @floatFromInt(duration);
    }

    pub fn getCodedWidth(self: *const VideoFrame) u32 {
        return if (self._closed) 0 else self._coded_width;
    }

    pub fn getCodedHeight(self: *const VideoFrame) u32 {
        return if (self._closed) 0 else self._coded_height;
    }

    pub fn getCodedRect(self: *const VideoFrame) ?*DOMRectReadOnly {
        return if (self._closed) null else self._coded_rect;
    }

    pub fn getVisibleRect(self: *const VideoFrame) ?*DOMRectReadOnly {
        return if (self._closed) null else self._visible_rect;
    }

    pub fn getRotation(self: *const VideoFrame) u32 {
        return if (self._closed) 0 else self._rotation;
    }

    pub fn getFlip(self: *const VideoFrame) bool {
        return if (self._closed) false else self._flip;
    }

    pub fn getDisplayWidth(self: *const VideoFrame) u32 {
        return if (self._closed) 0 else self._display_width;
    }

    pub fn getDisplayHeight(self: *const VideoFrame) u32 {
        return if (self._closed) 0 else self._display_height;
    }

    /// Same object on every read, but *not* the same one across close(): a
    /// closed frame hands back a fresh all-null space and keeps handing back
    /// that one (measured).
    pub fn getColorSpace(self: *const VideoFrame) *VideoColorSpace {
        return self._color_space;
    }

    pub fn allocationSize(self: *const VideoFrame, options_: ?js.Value, exec: *const Execution) !u32 {
        if (self._closed) {
            return closedError("allocationSize", "VideoFrame is closed.", exec);
        }
        const plan = try self.copyPlan("allocationSize", options_, exec);
        return plan.size;
    }

    pub fn clone(self: *VideoFrame, exec: *const Execution) !*VideoFrame {
        if (self._closed) {
            return closedError("clone", "Cannot clone closed VideoFrame.", exec);
        }
        return create(.{
            .format = self._format,
            .timestamp = self._timestamp,
            .duration = self._duration,
            .coded_width = self._coded_width,
            .coded_height = self._coded_height,
            .visible = self._visible,
            .display = .{ .x = 0, .y = 0, .width = self._display_width, .height = self._display_height },
            .rotation = self._rotation,
            .flip = self._flip,
            .color_space = self._color_space.*,
            .pixels = self._pixels,
        }, exec);
    }

    /// Idempotent, and it replaces the colour space rather than emptying the
    /// one a page may already be holding.
    pub fn close(self: *VideoFrame, exec: *const Execution) !void {
        if (self._closed) {
            return;
        }
        self._closed = true;
        self._color_space = try exec._factory.create(VideoColorSpace{});
    }

    /// Every failure here is a rejection, including the argument count and the
    /// closed-frame check -- unlike allocationSize, which throws (measured).
    pub fn copyTo(self: *const VideoFrame, args: []js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        var resolver = local.createPromiseResolver();
        if (args.len == 0) {
            resolver.rejectError("VideoFrame.copyTo", .{
                .type_error = "Failed to execute 'copyTo' on 'VideoFrame': 1 argument required, but only 0 present.",
            });
            return resolver.promise();
        }
        if (self._closed) {
            resolver.reject("VideoFrame.copyTo", DOMException.init(
                "Failed to execute 'copyTo' on 'VideoFrame': Cannot copy closed VideoFrame.",
                "InvalidStateError",
            ));
            return resolver.promise();
        }
        const buffer = bufferSource(args[0]) orelse {
            resolver.rejectError("VideoFrame.copyTo", .{
                .type_error = "Failed to execute 'copyTo' on 'VideoFrame': The provided value is not of type " ++
                    "'([AllowShared] ArrayBuffer or [AllowShared] ArrayBufferView)'.",
            });
            return resolver.promise();
        };

        // A bad options dictionary is a rejection here too, not a throw, so the
        // exception the reader raised has to be caught and handed to the
        // promise instead of escaping to the caller.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        const plan = self.copyPlan("copyTo", if (args.len > 1) args[1] else null, exec) catch |err| {
            const caught = try_catch.exceptionValue() orelse return err;
            resolver.reject("VideoFrame.copyTo", caught);
            return resolver.promise();
        };

        if (buffer.len < plan.size) {
            resolver.rejectError("VideoFrame.copyTo", .{
                .type_error = "Failed to execute 'copyTo' on 'VideoFrame': destination is not large enough.",
            });
            return resolver.promise();
        }
        self.blit(plan, buffer);
        resolver.resolve("VideoFrame.copyTo", plan.planes);
        return resolver.promise();
    }

    /// A plain object with no keys. Chrome hands back a *different* one every
    /// call, and it is empty even when the init supplied members.
    pub fn metadata(self: *const VideoFrame, exec: *const Execution) !struct {} {
        if (self._closed) {
            return closedError("metadata", "VideoFrame is closed.", exec);
        }
        return .{};
    }

    fn closedError(comptime method: []const u8, comptime message: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwDom(
            "InvalidStateError",
            "Failed to execute '" ++ method ++ "' on 'VideoFrame': " ++ message,
            exec,
        );
    }

    const CopyPlan = struct {
        size: u32,
        rect: Rect,
        format: *const PixelFormat,
        planes: []const PlaneLayout,
    };

    /// The shared body of allocationSize and copyTo: a VideoFrameCopyToOptions
    /// read against the frame's own visible rect and format.
    fn copyPlan(
        self: *const VideoFrame,
        comptime method: []const u8,
        options_: ?js.Value,
        exec: *const Execution,
    ) !CopyPlan {
        const Reader = dictionary.MethodReader("VideoFrame", method, "VideoFrameCopyToOptions");
        const options = try Reader.read(options_, exec);
        const format_name = try options.enumMember("format", "VideoPixelFormat", &FORMAT_NAMES, self._format.name, exec);
        const format = formatByName(format_name.?);
        const rect = (try readRectMember(Reader, options, "rect", exec)) orelse self._visible;
        try validateRect(rect, self._coded_width, self._coded_height, method, exec);

        var planes = try exec.call_arena.alloc(PlaneLayout, format.planes.len);
        var offset: u32 = 0;
        for (format.planes, 0..) |plane, i| {
            const stride = ceilDiv(rect.width, plane.x_sub) * plane.bytes;
            planes[i] = .{ .offset = offset, .stride = stride };
            offset += stride * ceilDiv(rect.height, plane.y_sub);
        }
        return .{ .size = offset, .rect = rect, .format = format, .planes = planes };
    }

    /// A DOMRectInit member of some dictionary -- `visibleRect` on the two
    /// inits, `rect` on VideoFrameCopyToOptions -- which report under their own
    /// names but read identically.
    fn readRectMember(
        comptime Reader: type,
        reader: anytype,
        comptime name: []const u8,
        exec: *const Execution,
    ) !?Rect {
        const member = (try reader.present(name)) orelse return null;
        if (!member.isObject()) {
            return Reader.notOfType(name, "DOMRectInit", exec);
        }
        const Nested = dictionary.Nested(Reader, name, "DOMRectInit");
        const rect = try Nested.read(member, exec);
        return .{
            .x = try rectMember(rect, "x", exec),
            .y = try rectMember(rect, "y", exec),
            .width = try rectMember(rect, "width", exec),
            .height = try rectMember(rect, "height", exec),
        };
    }

    fn validateRect(
        rect: Rect,
        coded_width: u32,
        coded_height: u32,
        comptime method: []const u8,
        exec: *const Execution,
    ) !void {
        const prefix = "Failed to execute '" ++ method ++ "' on 'VideoFrame': ";
        if (rect.x == NEGATIVE or rect.y == NEGATIVE) {
            return dictionary.throwTypeError(prefix ++ "Invalid rect. x cannot be negative.", exec);
        }
        if (rect.width == 0 or rect.height == 0) {
            return dictionary.throwTypeError(prefix ++ "Invalid rect. width must be nonzero.", exec);
        }
        if (rect.x + rect.width > coded_width) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                prefix ++ "Invalid rect. right {d} exceeds codedWidth {d}.",
                .{ rect.x + rect.width, coded_width },
            ), exec);
        }
        if (rect.y + rect.height > coded_height) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                prefix ++ "Invalid rect. bottom {d} exceeds codedHeight {d}.",
                .{ rect.y + rect.height, coded_height },
            ), exec);
        }
    }

    /// Copy the requested rect out of the stored picture. A frame with no
    /// pixels writes zeros rather than leaving whatever the page had there.
    fn blit(self: *const VideoFrame, plan: CopyPlan, destination: []u8) void {
        @memset(destination[0..plan.size], 0);
        const pixels = self._pixels orelse return;
        // Only the single-plane formats are ever stored here: a planar frame
        // can only come in through the buffer overload, and that path keeps
        // the caller's bytes verbatim, so a straight run-per-row copy is right
        // for both.
        if (plan.format != self._format) {
            return;
        }
        var offset_in: usize = 0;
        for (self._format.planes, plan.planes) |plane, layout| {
            const src_stride = ceilDiv(self._coded_width, plane.x_sub) * plane.bytes;
            const rows = ceilDiv(plan.rect.height, plane.y_sub);
            const skip_x = ceilDiv(plan.rect.x, plane.x_sub) * plane.bytes;
            const skip_y = ceilDiv(plan.rect.y, plane.y_sub);
            var row: u32 = 0;
            while (row < rows) : (row += 1) {
                const from = offset_in + (skip_y + row) * src_stride + skip_x;
                const to = layout.offset + row * layout.stride;
                if (from + layout.stride > pixels.len or to + layout.stride > destination.len) {
                    break;
                }
                @memcpy(destination[to..][0..layout.stride], pixels[from..][0..layout.stride]);
            }
            offset_in += src_stride * ceilDiv(self._coded_height, plane.y_sub);
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VideoFrame);

        pub const Meta = struct {
            pub const name = "VideoFrame";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(VideoFrame.constructor, .{});
        pub const format = bridge.accessor(VideoFrame.getFormat, null, .{});
        pub const timestamp = bridge.accessor(VideoFrame.getTimestamp, null, .{});
        pub const duration = bridge.accessor(VideoFrame.getDuration, null, .{});
        pub const codedWidth = bridge.accessor(VideoFrame.getCodedWidth, null, .{});
        pub const codedHeight = bridge.accessor(VideoFrame.getCodedHeight, null, .{});
        pub const codedRect = bridge.accessor(VideoFrame.getCodedRect, null, .{});
        pub const visibleRect = bridge.accessor(VideoFrame.getVisibleRect, null, .{});
        pub const rotation = bridge.accessor(VideoFrame.getRotation, null, .{});
        pub const flip = bridge.accessor(VideoFrame.getFlip, null, .{});
        pub const displayWidth = bridge.accessor(VideoFrame.getDisplayWidth, null, .{});
        pub const displayHeight = bridge.accessor(VideoFrame.getDisplayHeight, null, .{});
        pub const colorSpace = bridge.accessor(VideoFrame.getColorSpace, null, .{});
        pub const allocationSize = bridge.function(VideoFrame.allocationSize, .{ .arity = 0 });
        pub const clone = bridge.function(VideoFrame.clone, .{});
        pub const close = bridge.function(VideoFrame.close, .{});
        pub const copyTo = bridge.function(VideoFrame.copyTo, .{ .arity = 1 });
        pub const metadata = bridge.function(VideoFrame.metadata, .{});
    };
};

fn ceilDiv(value: u32, divisor: u32) u32 {
    return (value + divisor - 1) / divisor;
}

/// The bytes a whole coded picture of this format occupies.
fn allocationFor(format: *const PixelFormat, rect: Rect) u32 {
    var total: u32 = 0;
    for (format.planes) |plane| {
        total += ceilDiv(rect.width, plane.x_sub) * plane.bytes * ceilDiv(rect.height, plane.y_sub);
    }
    return total;
}

/// A `BufferSource` seen as bytes. The `[]u8` arm already covers an
/// ArrayBuffer and a DataView -- the conversion forces u8 for both -- so the
/// rest exist only to catch the wider element types.
const Bytes = union(enum) {
    uint8: []u8,
    int8: []i8,
    uint16: []u16,
    int16: []i16,
    uint32: []u32,
    int32: []i32,
    uint64: []u64,
    int64: []i64,
    float16: []f16,
    float32: []f32,
    float64: []f64,

    fn asBuffer(self: Bytes) []u8 {
        return switch (self) {
            inline else => |slice| std.mem.sliceAsBytes(slice),
        };
    }
};

/// The bytes behind a BufferSource, or null for anything that is not one.
///
/// The type check is not redundant: a bare `[]u8` conversion falls back to
/// *stringifying* whatever it was given, so `{}` would otherwise come back as
/// the fifteen bytes of "[object Object]" and be accepted as a buffer.
pub fn bufferSource(value: js.Value) ?[]u8 {
    if (!value.isArrayBuffer() and !value.isArrayBufferView()) {
        return null;
    }
    const view = value.toZig(Bytes) catch return null;
    return view.asBuffer();
}

pub fn registerTypes() []const type {
    return &.{ VideoColorSpace, VideoFrame };
}

const testing = @import("../../../testing.zig");
test "WebApi: WebCodecs frames" {
    try testing.htmlRunner("webcodecs/frames.html", .{});
}
