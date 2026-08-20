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

//! video.remote and video.getVideoPlaybackQuality(): the two objects a media
//! element hands out about playback that is not happening here.
//!
//! Neither has anything behind it -- there is no cast receiver to connect to
//! and no decoder to drop frames -- but both are reachable off a bare element
//! with no source attached, so a page reading them sees Chrome's
//! nothing-is-happening state rather than a missing property. That is the whole
//! point: `video.remote` being undefined is a louder signal than it reporting
//! "disconnected", which is what every real Chrome on a machine with no cast
//! device also reports.
//!
//! Three measured details a spec reading would miss:
//!
//!   * `getVideoPlaybackQuality` is on HTMLVideoElement.prototype, not on
//!     HTMLMediaElement.prototype, so an <audio> element does not have it.
//!   * watchAvailability() ids come from a counter shared by every
//!     RemotePlayback in the window -- two elements do not each start at 1 --
//!     but cancelWatchAvailability() only recognises the ids its own object
//!     handed out. So the counter and the bookkeeping live in different places.
//!   * All three methods report failure by rejecting, including the
//!     argument-conversion TypeErrors. None throws synchronously.
//!
//! Chrome 150, headed, over http://localhost
//! (win57/win60/win61-chrome.json).

const std = @import("std");

const js = @import("../../js/js.zig");

const DOMException = @import("../DOMException.zig");
const EventTarget = @import("../EventTarget.zig");
const Media = @import("../element/html/Media.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ RemotePlayback, VideoPlaybackQuality };
}

fn rejectDom(comptime name: []const u8, comptime message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("RemotePlayback", DOMException.init(message, name));
    return resolver.promise();
}

// ---------------------------------------------------------------------------
// RemotePlayback
// ---------------------------------------------------------------------------

/// video.remote. One per media element, created on first read and kept, because
/// `video.remote === video.remote` has to hold.
pub const RemotePlayback = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    /// The element this belongs to -- read for its `disableRemotePlayback`
    /// attribute, which changes what two of the three methods answer.
    _media: *Media,

    /// The ids this object has handed out and not yet cancelled. Per-object,
    /// even though the counter they come from is per-window: cancelling an id
    /// on the RemotePlayback that did not mint it is a NotFoundError (measured).
    _watch_ids: std.ArrayListUnmanaged(u32) = .empty,

    const WATCH = "Failed to execute 'watchAvailability' on 'RemotePlayback': ";
    const CANCEL = "Failed to execute 'cancelWatchAvailability' on 'RemotePlayback': ";
    const PROMPT = "Failed to execute 'prompt' on 'RemotePlayback': ";
    const DISABLED = "disableRemotePlayback attribute is present.";

    pub fn create(media: *Media, exec: *Execution) !*RemotePlayback {
        const self = try exec._factory.eventTarget(RemotePlayback{
            ._proto = undefined,
            ._media = media,
        });
        self._proto._type = .remote_playback;
        return self;
    }

    pub fn asEventTarget(self: *RemotePlayback) *EventTarget {
        return self._proto;
    }

    /// Nothing to connect to, so this never leaves "disconnected" -- which is
    /// also what a real Chrome reports on a machine with no cast device.
    pub fn getState(_: *const RemotePlayback) []const u8 {
        return "disconnected";
    }

    /// Registers a callback that will never fire: availability cannot change
    /// when there is no device to become available. The id is still real, so a
    /// page can cancel it.
    pub fn watchAvailability(self: *RemotePlayback, callback: ?js.Value, exec: *Execution) !js.Promise {
        const local = exec.js.local.?;
        const value = callback orelse return local.rejectPromise(.{
            .type_error = WATCH ++ "1 argument required, but only 0 present.",
        });
        if (!value.isFunction()) return local.rejectPromise(.{
            .type_error = WATCH ++ "parameter 1 is not of type 'Function'.",
        });
        // The attribute is checked after the argument, not before (measured:
        // a bad argument on a disabled element still reports the argument).
        if (self._media.getDisableRemotePlayback()) {
            return rejectDom("InvalidStateError", WATCH ++ DISABLED, exec);
        }

        const window = exec.js.global.frame.window;
        window._remote_playback_watch_id += 1;
        const id = window._remote_playback_watch_id;
        try self._watch_ids.append(exec.arena, id);
        return local.resolvePromise(id);
    }

    /// With no argument, cancels everything this object is watching. With one,
    /// cancels that id -- and refuses if this object is not the one holding it.
    pub fn cancelWatchAvailability(self: *RemotePlayback, id_: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (self._media.getDisableRemotePlayback()) {
            return rejectDom("InvalidStateError", CANCEL ++ DISABLED, exec);
        }

        const given = id_ orelse {
            self._watch_ids.clearRetainingCapacity();
            return local.resolvePromise({});
        };
        // An explicit undefined is an absent optional argument.
        if (given.isUndefined()) {
            self._watch_ids.clearRetainingCapacity();
            return local.resolvePromise({});
        }

        const id = given.toZig(u32) catch return rejectDom("NotFoundError", CANCEL ++ "A callback with the given id is not found.", exec);
        for (self._watch_ids.items, 0..) |held, i| {
            if (held == id) {
                _ = self._watch_ids.orderedRemove(i);
                return local.resolvePromise({});
            }
        }
        return rejectDom("NotFoundError", CANCEL ++ "A callback with the given id is not found.", exec);
    }

    /// Asking the user to pick a device needs a user gesture, and a script
    /// never has one -- so this is the one answer a page can get. With the
    /// attribute set it refuses for that reason instead, which takes precedence
    /// over the gesture (measured).
    pub fn prompt(self: *RemotePlayback, exec: *const Execution) js.Promise {
        if (self._media.getDisableRemotePlayback()) {
            return rejectDom("InvalidStateError", PROMPT ++ DISABLED, exec);
        }
        return rejectDom("InvalidAccessError", PROMPT ++ "RemotePlayback::prompt() requires user gesture.", exec);
    }

    fn handlerAccessors(comptime field: []const u8) type {
        return struct {
            fn get(self: *RemotePlayback) ?js.Function.Global {
                return @field(self, field);
            }

            fn set(self: *RemotePlayback, listener: ?js.Function) !void {
                @field(self, field) = if (listener) |l| try l.persistWithThis(self) else null;
            }
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RemotePlayback);

        pub const Meta = struct {
            pub const name = "RemotePlayback";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's prototype order: the three handlers sit between `state` and
        // the methods, and the methods are alphabetical after that.
        pub const state = bridge.accessor(RemotePlayback.getState, null, .{});
        pub const onconnecting = bridge.accessor(handlerProperty(RemotePlayback, .onconnecting).get, handlerProperty(RemotePlayback, .onconnecting).set, .{});
        pub const onconnect = bridge.accessor(handlerProperty(RemotePlayback, .onconnect).get, handlerProperty(RemotePlayback, .onconnect).set, .{});
        pub const ondisconnect = bridge.accessor(handlerProperty(RemotePlayback, .ondisconnect).get, handlerProperty(RemotePlayback, .ondisconnect).set, .{});
        pub const cancelWatchAvailability = bridge.function(RemotePlayback.cancelWatchAvailability, .{ .arity = 0 });
        pub const prompt = bridge.function(RemotePlayback.prompt, .{ .arity = 0 });
        pub const watchAvailability = bridge.function(RemotePlayback.watchAvailability, .{ .arity = 1 });
    };
};

// ---------------------------------------------------------------------------
// VideoPlaybackQuality
// ---------------------------------------------------------------------------

/// What video.getVideoPlaybackQuality() hands back: a snapshot, not a live
/// view, so a fresh object each call rather than one that is kept and updated
/// (measured: two calls are two objects).
pub const VideoPlaybackQuality = struct {
    /// A DOMHighResTimeStamp on the same clock as performance.now(), stamped
    /// when the snapshot is taken.
    _creation_time: f64,

    pub fn create(exec: *Execution) !*VideoPlaybackQuality {
        return exec._factory.create(VideoPlaybackQuality{
            ._creation_time = exec.js.global.frame.window._performance.now(),
        });
    }

    pub fn getCreationTime(self: *const VideoPlaybackQuality) f64 {
        return self._creation_time;
    }

    // Nothing decodes here, so nothing has been shown, dropped or corrupted.
    // A real Chrome reports the same three zeroes for a <video> that never got
    // a source.
    pub fn getTotalVideoFrames(_: *const VideoPlaybackQuality) u32 {
        return 0;
    }

    pub fn getDroppedVideoFrames(_: *const VideoPlaybackQuality) u32 {
        return 0;
    }

    pub fn getCorruptedVideoFrames(_: *const VideoPlaybackQuality) u32 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VideoPlaybackQuality);

        pub const Meta = struct {
            pub const name = "VideoPlaybackQuality";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const creationTime = bridge.accessor(VideoPlaybackQuality.getCreationTime, null, .{});
        pub const totalVideoFrames = bridge.accessor(VideoPlaybackQuality.getTotalVideoFrames, null, .{});
        pub const droppedVideoFrames = bridge.accessor(VideoPlaybackQuality.getDroppedVideoFrames, null, .{});
        pub const corruptedVideoFrames = bridge.accessor(VideoPlaybackQuality.getCorruptedVideoFrames, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: RemotePlayback" {
    try testing.htmlRunner("media/remote_playback.html", .{});
}
