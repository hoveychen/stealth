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

// window.MediaRecorder. Only the static isTypeSupported() is reachable, and
// that is not a shortcut — the constructor takes a MediaStream, and there is no
// way to obtain one here because getUserMedia rejects (see media/MediaDevices.zig).
//
// CreepJS guards its call with `'MediaRecorder' in window`, so the class had to
// exist for the fourth column of its media grid to be anything but blank. The
// answers come from the same table as the other two APIs — see mime.zig — which
// is what keeps them from contradicting each other.

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const mime = @import("mime.zig");

const MediaRecorder = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

pub fn isTypeSupported(mime_type: []const u8) bool {
    return mime.isTypeSupported(.media_recorder, mime_type);
}

// The stream argument is required, so the reported arity is 1 and a bare
// `new MediaRecorder()` is a TypeError, both matching Chrome. Given a stream it
// still cannot record: nothing here can produce a MediaStream in the first
// place (getUserMedia rejects), so any value that reaches this is not one.
pub fn constructor(_: js.Value) !*MediaRecorder {
    return error.NotSupported;
}

pub fn asEventTarget(self: *MediaRecorder) *EventTarget {
    return self._proto;
}

// None of the below can run: reaching them needs an instance, and the
// constructor never returns one.
pub fn getStream(_: *const MediaRecorder) ?js.Value {
    return null;
}

pub fn getMimeType(_: *const MediaRecorder) []const u8 {
    return "";
}

pub fn getState(_: *const MediaRecorder) []const u8 {
    return "inactive";
}

pub fn getVideoBitsPerSecond(_: *const MediaRecorder) u32 {
    return 0;
}

pub fn getAudioBitsPerSecond(_: *const MediaRecorder) u32 {
    return 0;
}

pub fn getAudioBitrateMode(_: *const MediaRecorder) []const u8 {
    return "variable";
}

pub fn getHandler(_: *const MediaRecorder) ?js.Function.Global {
    return null;
}

pub fn setHandler(_: *MediaRecorder, _: ?js.Function) void {}

pub fn unsupported(_: *MediaRecorder) !void {
    return error.InvalidStateError;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaRecorder);

    pub const Meta = struct {
        pub const name = "MediaRecorder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MediaRecorder.constructor, .{});
    pub const isTypeSupported = bridge.function(MediaRecorder.isTypeSupported, .{ .static = true });

    // Unreachable — no instance can exist — but declared so the prototype
    // enumerates the way Chrome's does.
    pub const stream = bridge.accessor(MediaRecorder.getStream, null, .{});
    pub const mimeType = bridge.accessor(MediaRecorder.getMimeType, null, .{});
    pub const state = bridge.accessor(MediaRecorder.getState, null, .{});
    pub const onstart = bridge.accessor(MediaRecorder.getHandler, MediaRecorder.setHandler, .{});
    pub const onstop = bridge.accessor(MediaRecorder.getHandler, MediaRecorder.setHandler, .{});
    pub const ondataavailable = bridge.accessor(MediaRecorder.getHandler, MediaRecorder.setHandler, .{});
    pub const onpause = bridge.accessor(MediaRecorder.getHandler, MediaRecorder.setHandler, .{});
    pub const onresume = bridge.accessor(MediaRecorder.getHandler, MediaRecorder.setHandler, .{});
    pub const onerror = bridge.accessor(MediaRecorder.getHandler, MediaRecorder.setHandler, .{});
    pub const videoBitsPerSecond = bridge.accessor(MediaRecorder.getVideoBitsPerSecond, null, .{});
    pub const audioBitsPerSecond = bridge.accessor(MediaRecorder.getAudioBitsPerSecond, null, .{});
    pub const audioBitrateMode = bridge.accessor(MediaRecorder.getAudioBitrateMode, null, .{});
    pub const pause = bridge.function(MediaRecorder.unsupported, .{});
    pub const requestData = bridge.function(MediaRecorder.unsupported, .{});
    pub const @"resume" = bridge.function(MediaRecorder.unsupported, .{});
    pub const start = bridge.function(MediaRecorder.unsupported, .{});
    pub const stop = bridge.function(MediaRecorder.unsupported, .{});
};
