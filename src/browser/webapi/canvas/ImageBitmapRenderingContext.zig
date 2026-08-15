// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// canvas.getContext('bitmaprenderer'). One of G17's window keys, and the only
// canvas context type this engine did not answer for -- `getContext` returned
// null, which is a louder signal than any of its members would have been.
//
// Two prototype members. `canvas` points back at the element, and
// `transferFromImageBitmap` returns undefined, consumes the bitmap (the source
// reads back 0x0 afterwards, exactly as if close() had been called) and does
// *not* resize the canvas -- a 4x4 canvas fed an 8x8 bitmap stays 4x4. All
// measured on a headed Chrome 150, win64-chrome.json. `null` is accepted and
// clears rather than throwing; anything else is a TypeError naming ImageBitmap.

const js = @import("../../js/js.zig");

const Canvas = @import("../element/html/Canvas.zig");
const ImageBitmap = @import("ImageBitmap.zig");
const dictionary = @import("../dictionary.zig");

const Execution = js.Execution;

const ImageBitmapRenderingContext = @This();

_canvas: *Canvas,

pub fn getCanvas(self: *const ImageBitmapRenderingContext) *Canvas {
    return self._canvas;
}

// The argument is read as a raw value rather than as `?*ImageBitmap` for two
// reasons: the bridge's refusal would be "invalid argument" where Chrome names
// the interface, and an explicit `null` -- which Chrome accepts -- would be
// indistinguishable from a missing argument, which it does not.
pub fn transferFromImageBitmap(_: *ImageBitmapRenderingContext, source_: ?js.Value, exec: *const Execution) !void {
    const source = source_ orelse return dictionary.throwTypeError(
        "Failed to execute 'transferFromImageBitmap' on 'ImageBitmapRenderingContext': " ++
            "1 argument required, but only 0 present.",
        exec,
    );

    // null clears the context and returns undefined without throwing.
    if (source.isNull() or source.isUndefined()) {
        return;
    }

    const bitmap = source.toZig(*ImageBitmap) catch return dictionary.throwTypeError(
        "Failed to execute 'transferFromImageBitmap' on 'ImageBitmapRenderingContext': " ++
            "parameter 1 is not of type 'ImageBitmap'.",
        exec,
    );
    // The bitmap is consumed: it reads back 0x0 afterwards, the same as a
    // closed one (measured). The canvas is NOT resized to match it.
    bitmap.close();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageBitmapRenderingContext);

    pub const Meta = struct {
        pub const name = "ImageBitmapRenderingContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(ImageBitmapRenderingContext.getCanvas, null, .{});
    pub const transferFromImageBitmap = bridge.function(ImageBitmapRenderingContext.transferFromImageBitmap, .{ .arity = 1 });
};
