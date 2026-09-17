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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// The Shape Detection barcode reader. One of five names DataDome's device-check
// program asked this engine for and did not get (the engine's own unknown_prop
// log on dd-tripadvisor, plus an `in` probe against Chrome to separate the real
// gaps from the bot markers); the other four are WebSocketStream,
// PressureObserver, Summarizer and navigator.cpuPerformance.
//
// Measured on a headed Chrome 152 (probe scratch/s34/shape.js, behaviour readings
// in the plan's P2 notes):
//
//   * BarcodeDetector.length is 0 -- the options dictionary is optional.
//   * The interface object carries one static, getSupportedFormats, and the
//     prototype carries detect (length 1).
//   * getSupportedFormats() resolves with eleven formats, in this order:
//     aztec, code_128, code_39, code_93, data_matrix, ean_13, ean_8, itf,
//     pdf417, qr_code, upc_e.
//   * `new BarcodeDetector({formats:['nope']})` is a TypeError reading "Failed
//     to construct 'BarcodeDetector': Failed to read the 'formats' property
//     from 'BarcodeDetectorOptions': The provided value 'nope' is not a valid
//     enum value of type BarcodeFormat." A member of the enum that is not one of
//     the eleven -- upc_a -- is accepted.
//   * detect() refuses anything outside the ImageBitmapSource union by name:
//     "Failed to execute 'detect' on 'BarcodeDetector': The provided value is
//     not of type '(Blob or HTMLCanvasElement or ...)'."; the whole sentence is
//     below.
//   * [SecureContext]: absent from an insecure origin, so the name is in
//     secure_context.gated_interfaces.
//
// Nothing here decodes an image: detect() resolves with an empty list, which is
// also what a real detector answers for a source with no barcode in it.

const std = @import("std");

const js = @import("../js/js.zig");

const Execution = js.Execution;

const BarcodeDetector = @This();

// The formats getSupportedFormats() reports, in Chrome's order (measured).
const supported_formats = [_][]const u8{
    "aztec",
    "code_128",
    "code_39",
    "code_93",
    "data_matrix",
    "ean_13",
    "ean_8",
    "itf",
    "pdf417",
    "qr_code",
    "upc_e",
};

// The BarcodeFormat enum, which is what the constructor validates against --
// wider than the supported set above, because an unsupported-but-valid member
// is a different refusal from a value that is not in the enum at all.
const barcode_formats = supported_formats ++ [_][]const u8{
    "codabar",
    "unknown",
    "upc_a",
};

pub const Options = struct {
    pub const js_idl_name = "BarcodeDetectorOptions";

    formats: ?[]const []const u8 = null,
};

// Padding to avoid a zero-size struct, which causes identity_map pointer
// collisions. The requested formats are not readable from JS -- the prototype
// has detect and nothing else -- so they are not kept.
_pad: bool = false,

pub fn constructor(options: ?Options, exec: *const Execution) !*BarcodeDetector {
    if (options) |opts| {
        for (opts.formats orelse &.{}) |format| {
            for (barcode_formats) |known| {
                if (std.mem.eql(u8, known, format)) break;
            } else {
                return exec.js.fail(error.TypeError, try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to construct 'BarcodeDetector': Failed to read the 'formats' property from 'BarcodeDetectorOptions': The provided value '{s}' is not a valid enum value of type BarcodeFormat.",
                    .{format},
                ));
            }
        }
    }
    return exec._factory.create(BarcodeDetector{});
}

pub fn getSupportedFormats(exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as([]const []const u8, &supported_formats));
}

/// Nothing here reads pixels, so every source that is a source at all is a
/// source with no barcode in it. The type check is still real: Chrome names the
/// whole ImageBitmapSource union back at a caller that hands it anything else,
/// and that sentence is a cheaper thing for a script to read than a decode.
pub fn detect(_: *BarcodeDetector, source: js.Value, exec: *const Execution) !js.Promise {
    if (isImageBitmapSource(source) == false) {
        return exec.js.fail(
            error.TypeError,
            "Failed to execute 'detect' on 'BarcodeDetector': The provided value is not of type '" ++
                image_bitmap_source ++ "'.",
        );
    }
    return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
}

const image_bitmap_source =
    "(Blob or HTMLCanvasElement or HTMLImageElement or HTMLVideoElement or ImageBitmap or " ++
    "ImageData or OffscreenCanvas or SVGImageElement or VideoFrame)";

fn isImageBitmapSource(source: js.Value) bool {
    if (source.isObject() == false) {
        return false;
    }
    inline for (.{
        *@import("Blob.zig"),
        *@import("element/html/Canvas.zig"),
        *@import("element/html/Image.zig"),
        *@import("element/html/Video.zig"),
        *@import("canvas/ImageBitmap.zig"),
        *@import("ImageData.zig"),
        *@import("canvas/OffscreenCanvas.zig"),
        *@import("element/svg/Image.zig"),
        *@import("webcodecs/frames.zig").VideoFrame,
    }) |T| {
        if (source.toZig(T)) |_| return true else |_| {}
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BarcodeDetector);

    pub const Meta = struct {
        pub const name = "BarcodeDetector";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(BarcodeDetector.constructor, .{});
    pub const getSupportedFormats = bridge.function(BarcodeDetector.getSupportedFormats, .{ .static = true });
    pub const detect = bridge.function(BarcodeDetector.detect, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: BarcodeDetector" {
    try testing.htmlRunner("barcode_detector.html", .{});
}
