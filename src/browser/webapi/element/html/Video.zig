// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Media = @import("Media.zig");
const playback = @import("../../media/playback.zig");
const global_event_handlers = @import("../../global_event_handlers.zig");

const Video = @This();

pub const Proto = Media;

// Chrome's requestVideoFrameCallback hands out 1, then 2, ... per element.
// Nothing ever presents a frame here, so nothing is stored against the handle:
// a <video> with no source never runs the callback in Chrome either.
_next_frame_callback: u32 = 0,
_proto_canary: if (lp.IS_DEBUG) *Media else void = undefined,

pub fn asMedia(self: *Video) *Media {
    return Factory.protoOf(self);
}

pub fn asElement(self: *Video) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asConstElement(self: *const Video) *const Element {
    return Factory.protoOf(self).asConstElement();
}

pub fn asNode(self: *Video) *Node {
    return self.asElement().asNode();
}

pub fn getVideoWidth(_: *const Video) u32 {
    return 0;
}

pub fn getVideoHeight(_: *const Video) u32 {
    return 0;
}

pub fn getPoster(self: *const Video, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const poster = element.getAttributeSafe(comptime .wrap("poster")) orelse return "";
    if (poster.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(poster, frame, .{});
}

pub fn setPoster(self: *Video, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("poster"), .wrap(value), frame);
}

/// A snapshot of how playback is going. Nothing decodes here, so every counter
/// is zero -- but the object is real and freshly stamped on each call, which is
/// what a real Chrome hands back for a <video> that never got a source.
pub fn getVideoPlaybackQuality(_: *Video, exec: *js.Execution) !*playback.VideoPlaybackQuality {
    return playback.VideoPlaybackQuality.create(exec);
}

// Nothing decodes, so nothing is decoded or dropped. Chrome answers 0 for both
// on a <video> that never got a source.
pub fn getWebkitDecodedFrameCount(_: *const Video) u32 {
    return 0;
}

pub fn getWebkitDroppedFrameCount(_: *const Video) u32 {
    return 0;
}

pub fn requestVideoFrameCallback(self: *Video, _: js.Function) u32 {
    self._next_frame_callback += 1;
    return self._next_frame_callback;
}

pub fn cancelVideoFrameCallback(_: *Video, _: u32) void {}

/// Chrome refuses this before the metadata is in, which for a <video> that
/// never got a source is always. Measured on Chrome 151: an InvalidStateError,
/// and a rejected promise rather than a throw.
pub fn requestPictureInPicture(_: *Video, frame: *Frame) js.Promise {
    return frame.js.local.?.rejectPromise(.{ .dom_exception = .{
        .err = error.InvalidStateError,
        .message = "Failed to execute 'requestPictureInPicture' on 'HTMLVideoElement': " ++
            "Metadata for the video element are not loaded yet.",
    } });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Video);

    pub const Meta = struct {
        pub const name = "HTMLVideoElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Video);

    // Chrome's own-property order: attributes in IDL order, then the
    // operations alphabetically.
    pub const width = reflect.unsignedLong("width", .{});
    pub const height = reflect.unsignedLong("height", .{});
    pub const videoWidth = bridge.accessor(Video.getVideoWidth, null, .{});
    pub const videoHeight = bridge.accessor(Video.getVideoHeight, null, .{});
    pub const poster = bridge.accessor(Video.getPoster, Video.setPoster, .{ .ce_reactions = true });
    pub const webkitDecodedFrameCount = bridge.accessor(Video.getWebkitDecodedFrameCount, null, .{});
    pub const webkitDroppedFrameCount = bridge.accessor(Video.getWebkitDroppedFrameCount, null, .{});
    pub const playsInline = reflect.boolean("playsinline");
    pub const onenterpictureinpicture = bridge.accessor(handlerAccessor(.onenterpictureinpicture).get, handlerAccessor(.onenterpictureinpicture).set, .{});
    pub const onleavepictureinpicture = bridge.accessor(handlerAccessor(.onleavepictureinpicture).get, handlerAccessor(.onleavepictureinpicture).set, .{});
    pub const disablePictureInPicture = reflect.boolean("disablepictureinpicture");
    pub const cancelVideoFrameCallback = bridge.function(Video.cancelVideoFrameCallback, .{});
    // This is on HTMLVideoElement, not on the media base class, so an <audio>
    // element does not have it (measured).
    pub const getVideoPlaybackQuality = bridge.function(Video.getVideoPlaybackQuality, .{});
    pub const requestPictureInPicture = bridge.function(Video.requestPictureInPicture, .{});
    pub const requestVideoFrameCallback = bridge.function(Video.requestVideoFrameCallback, .{});

    fn handlerAccessor(comptime handler: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *Video, frame: *Frame) !?js.Function.Global {
                return self.asElement().getAttributeFunction(handler, frame);
            }

            pub fn set(self: *Video, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.asElement().setAttributeListener(handler, callback, frame);
            }
        };
    }
};
