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

//! canvas.captureStream()'s track, and the ImageCapture that reads photos off
//! any video track.
//!
//! This is the one capture path that works without a permission or a device:
//! getUserMedia still refuses here and no camera exists, but a canvas is a
//! video source a browser is always willing to open, so a page can reach a live
//! `CanvasCaptureMediaStreamTrack` and a working `ImageCapture` with two calls.
//! That makes the values below reachable rather than decorative, and it is why
//! grabFrame() really produces an ImageBitmap instead of refusing.
//!
//! Four measured behaviours that a spec reading would not predict:
//!
//!   * The captured size is frozen at captureStream() time. Resizing the canvas
//!     afterwards moves neither the live track's settings nor its capability
//!     ranges; only a track opened after the resize sees the new size.
//!   * A zero-area canvas still captures. Its settings then omit width, height
//!     and aspectRatio entirely rather than reporting 0, while its capability
//!     ranges clamp to 1.
//!   * `grabFrame()` on a video track with nothing behind it -- a
//!     MediaStreamTrackGenerator -- rejects with `undefined`, not with a
//!     DOMException. A reader that reaches for `e.name` on that trips over it.
//!   * `takePhoto()` never succeeds on a canvas track: Chrome fails it with
//!     `UnknownError: setPhotoOptions failed`, because there is no still-image
//!     pipeline behind a canvas either.
//!
//! Chrome 150, headed, over http://localhost (win60/win61/win62-chrome.json).

const std = @import("std");

const js = @import("../../js/js.zig");

const Canvas = @import("../element/html/Canvas.zig");
const DOMException = @import("../DOMException.zig");
const EventTarget = @import("../EventTarget.zig");
const ImageBitmap = @import("../canvas/ImageBitmap.zig");
const streams = @import("streams.zig");

const MediaStream = streams.MediaStream;
const MediaStreamTrack = streams.MediaStreamTrack;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ CanvasCaptureMediaStreamTrack, ImageCapture };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn throwDom(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

fn rejectDom(comptime name: []const u8, comptime message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("ImageCapture", DOMException.init(message, name));
    return resolver.promise();
}

// ---------------------------------------------------------------------------
// CanvasCaptureMediaStreamTrack
// ---------------------------------------------------------------------------

/// The video track behind canvas.captureStream(). Illegal to construct: the
/// canvas mints it, and there is no other way to one.
pub const CanvasCaptureMediaStreamTrack = struct {
    pub const Proto = MediaStreamTrack;

    _proto: *MediaStreamTrack,
    _canvas: *Canvas,

    /// The rate Chrome reports when captureStream() is called with no argument.
    const DEFAULT_FRAME_RATE: f64 = 60;

    fn build(canvas: *Canvas, frame_rate: f64, device_id: []const u8, exec: *Execution) !*CanvasCaptureMediaStreamTrack {
        var id: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&id);

        // EventTarget -> MediaStreamTrack -> here: all three levels have to sit
        // contiguously in one allocation, so the chain is built at once rather
        // than the base being made first.
        const self = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            MediaStreamTrack{
                ._proto = undefined,
                ._id = id,
                ._device_id = device_id,
                // A capture track's label *is* its deviceId, not its id
                // (measured: label === getSettings().deviceId, and both differ
                // from `id`).
                ._label = device_id,
                ._kind = .video,
                ._source = .{ .canvas = .{
                    .width = canvas.getWidth(),
                    .height = canvas.getHeight(),
                    .frame_rate = frame_rate,
                } },
            },
            CanvasCaptureMediaStreamTrack{ ._proto = undefined, ._canvas = canvas },
        });
        self._proto._type = .{ .canvas_capture = self };
        self._proto._proto._type = .canvas_capture_media_stream_track;
        return self;
    }

    /// A fresh track over the canvas' size *now*, with a deviceId of its own.
    pub fn capture(canvas: *Canvas, frame_rate: f64, exec: *Execution) !*CanvasCaptureMediaStreamTrack {
        return build(canvas, frame_rate, try MediaStreamTrack.captureDeviceId(exec), exec);
    }

    /// MediaStreamTrack.clone()'s canvas branch: same canvas, same deviceId and
    /// label, same captured size, new id (measured).
    pub fn cloneOf(source: *const CanvasCaptureMediaStreamTrack, exec: *Execution) !*CanvasCaptureMediaStreamTrack {
        const base = source._proto;
        const copy = try build(source._canvas, base._source.canvas.frame_rate, base._device_id, exec);
        copy._proto._source = base._source;
        copy._proto._enabled = base._enabled;
        copy._proto._content_hint = base._content_hint;
        return copy;
    }

    pub fn asMediaStreamTrack(self: *CanvasCaptureMediaStreamTrack) *MediaStreamTrack {
        return self._proto;
    }

    pub fn getCanvas(self: *const CanvasCaptureMediaStreamTrack) *Canvas {
        return self._canvas;
    }

    /// Asks for one frame. Nothing pulls frames here, so there is nothing to
    /// do -- and Chrome's returns undefined too, including after stop().
    pub fn requestFrame(_: *CanvasCaptureMediaStreamTrack) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CanvasCaptureMediaStreamTrack);

        pub const Meta = struct {
            pub const name = "CanvasCaptureMediaStreamTrack";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = MediaStreamTrack;

        pub const canvas = bridge.accessor(CanvasCaptureMediaStreamTrack.getCanvas, null, .{});
        pub const requestFrame = bridge.function(CanvasCaptureMediaStreamTrack.requestFrame, .{});
    };
};

/// canvas.captureStream(): a one-track stream over the canvas' current size.
/// Every call is a fresh stream over a fresh track (measured).
pub fn captureStream(canvas: *Canvas, frame_rate_: ?js.Value, exec: *Execution) !*MediaStream {
    // An explicit `undefined` is an absent optional argument, so it takes the
    // default rather than failing the double conversion. An explicit `null` is
    // not: it converts to 0 like any other value.
    const frame_rate = if (frame_rate_) |value| blk: {
        if (value.isUndefined()) break :blk CanvasCaptureMediaStreamTrack.DEFAULT_FRAME_RATE;
        const rate = value.toZig(f64) catch std.math.nan(f64);
        // Non-finite is caught by the double conversion, so it is a TypeError
        // and it fires before the range check below (measured: NaN and "abc"
        // both give this, while -1 gives the NotSupportedError).
        if (!std.math.isFinite(rate)) return throwTypeError(
            "Failed to execute 'captureStream' on 'HTMLCanvasElement': The provided double value is non-finite.",
            exec,
        );
        if (rate < 0) return throwDom(
            "NotSupportedError",
            "Failed to execute 'captureStream' on 'HTMLCanvasElement': Given frame rate is not supported.",
            exec,
        );
        break :blk rate;
    } else CanvasCaptureMediaStreamTrack.DEFAULT_FRAME_RATE;

    const stream = try MediaStream.create(exec);
    const track = try CanvasCaptureMediaStreamTrack.capture(canvas, frame_rate, exec);
    try stream._tracks.append(exec.arena, track.asMediaStreamTrack());
    return stream;
}

// ---------------------------------------------------------------------------
// ImageCapture
// ---------------------------------------------------------------------------

/// Reads still images off a video track.
pub const ImageCapture = struct {
    _track: *MediaStreamTrack,

    const CONSTRUCT = "Failed to construct 'ImageCapture': ";

    // Every method answers this once the track has ended -- note the bare
    // wording: no "Failed to execute" prefix, and no trailing full stop
    // (measured on all four).
    const INVALID_STATE = "The associated Track is in an invalid state";

    pub fn constructor(track_: ?js.Value, exec: *Execution) !*ImageCapture {
        const value = track_ orelse return throwTypeError(
            CONSTRUCT ++ "1 argument required, but only 0 present.",
            exec,
        );
        const track = value.toZig(*MediaStreamTrack) catch return throwTypeError(
            CONSTRUCT ++ "parameter 1 is not of type 'MediaStreamTrack'.",
            exec,
        );
        // A real track of the wrong kind gets past the type check and is
        // refused on its own terms: a DOMException, not a TypeError.
        if (track._kind != .video) return throwDom(
            "NotSupportedError",
            CONSTRUCT ++ "Cannot create an ImageCapturer from a non-video Track.",
            exec,
        );
        // An *ended* track is still accepted here; the refusal is per-method.
        return exec._factory.create(ImageCapture{ ._track = track });
    }

    pub fn getTrack(self: *const ImageCapture) *MediaStreamTrack {
        return self._track;
    }

    fn ended(self: *const ImageCapture) bool {
        return self._track._ready_state == .ended;
    }

    /// What the camera could be asked for. A canvas has no camera, so the only
    /// member Chrome reports is the one it can answer without one -- and it is
    /// a plain object, not a branded interface: Chrome 150 has no
    /// `PhotoCapabilities` global at all.
    pub fn getPhotoCapabilities(self: *ImageCapture, exec: *const Execution) !js.Promise {
        if (self.ended()) return rejectDom("InvalidStateError", INVALID_STATE, exec);
        return exec.js.local.?.resolvePromise(Capabilities{});
    }

    const Capabilities = struct {
        redEyeReduction: []const u8 = "never",
    };

    pub fn getPhotoSettings(self: *ImageCapture, exec: *const Execution) !js.Promise {
        if (self.ended()) return rejectDom("InvalidStateError", INVALID_STATE, exec);
        return exec.js.local.?.resolvePromise(Settings{});
    }

    const Settings = struct {
        imageHeight: u32 = 0,
        imageWidth: u32 = 0,
    };

    /// The one method that really produces something: a bitmap the size of the
    /// canvas behind the track. A video track with no canvas has no frame to
    /// hand over, and Chrome's rejection there carries *nothing* -- the promise
    /// rejects with `undefined` rather than with a DOMException (measured on a
    /// MediaStreamTrackGenerator).
    pub fn grabFrame(self: *ImageCapture, exec: *const Execution) !js.Promise {
        if (self.ended()) return rejectDom("InvalidStateError", INVALID_STATE, exec);

        const local = exec.js.local.?;
        const canvas = switch (self._track._source) {
            .canvas => |source| source,
            .web_audio, .generator => {
                var resolver = local.createPromiseResolver();
                resolver.reject("ImageCapture.grabFrame", {});
                return resolver.promise();
            },
        };
        return local.resolvePromise(try exec._factory.create(ImageBitmap{
            ._width = canvas.width,
            ._height = canvas.height,
            // Sized but blank: the track records its canvas' dimensions and
            // nothing else (`CanvasSource` in streams.zig), so there is no
            // buffer here to snapshot the way createImageBitmap() does.
            ._surface = .{ .arena = exec.arena },
        }));
    }

    /// Never succeeds. There is no still-image pipeline behind a canvas track,
    /// and Chrome fails it the same way rather than falling back on the frame
    /// grabFrame() would have given.
    pub fn takePhoto(self: *ImageCapture, settings_: ?js.Value, exec: *const Execution) !js.Promise {
        // The dictionary conversion runs first, and a bad value *rejects* --
        // it does not throw synchronously, even though the failure is a
        // TypeError from argument conversion (measured: `takePhoto('nope')`
        // returns a promise that rejects).
        if (settings_) |value| {
            if (!value.isNullOrUndefined() and !value.isObject()) {
                return exec.js.local.?.rejectPromise(.{
                    .type_error = "Failed to execute 'takePhoto' on 'ImageCapture': The provided value is not of type 'PhotoSettings'.",
                });
            }
        }
        if (self.ended()) return rejectDom("InvalidStateError", INVALID_STATE, exec);
        return rejectDom("UnknownError", "setPhotoOptions failed", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ImageCapture);

        pub const Meta = struct {
            pub const name = "ImageCapture";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(ImageCapture.constructor, .{ .arity = 1 });

        // Chrome's prototype order.
        pub const track = bridge.accessor(ImageCapture.getTrack, null, .{});
        pub const getPhotoCapabilities = bridge.function(ImageCapture.getPhotoCapabilities, .{});
        pub const getPhotoSettings = bridge.function(ImageCapture.getPhotoSettings, .{});
        pub const grabFrame = bridge.function(ImageCapture.grabFrame, .{});
        pub const takePhoto = bridge.function(ImageCapture.takePhoto, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: ImageCapture" {
    try testing.htmlRunner("media/image_capture.html", .{});
}
