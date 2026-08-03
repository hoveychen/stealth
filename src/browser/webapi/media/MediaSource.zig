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

// window.MediaSource. It was absent entirely, and its absence was doing real
// damage well beyond itself: CreepJS's media probe calls
// MediaSource.isTypeSupported() inside the same try block as canPlayType(), so
// a ReferenceError there threw away the whole grid and the row read
// "mimes (0/12): blocked" even though canPlayType worked.
//
// isTypeSupported() is the part that matters and it is real — see mime.zig.
// The rest is the surface: a source buffer needs a media pipeline to attach to,
// so a MediaSource here stays "closed" and addSourceBuffer throws, which is
// also what Chrome does for a MediaSource that was never attached to an element
// (measured: readyState "closed", duration NaN, sourceBuffers empty).
//
// Known gap: Chrome also carries a static boolean data property
// `MediaSource.canConstructInDedicatedWorker` (true on this build). The bridge
// can only put functions on a constructor, not data properties, so it is
// missing here.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const mime = @import("mime.zig");

const Execution = js.Execution;

const MediaSource = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_on_sourceopen: ?js.Function.Global = null,
_on_sourceended: ?js.Function.Global = null,
_on_sourceclose: ?js.Function.Global = null,

pub fn constructor(exec: *Execution) !*MediaSource {
    return exec._factory.eventTarget(MediaSource{ ._proto = undefined });
}

pub fn asEventTarget(self: *MediaSource) *EventTarget {
    return self._proto;
}

pub fn isTypeSupported(mime_type: []const u8) bool {
    return mime.isTypeSupported(.media_source, mime_type);
}

// Never attached to a media element, so it never opens.
pub fn getReadyState(_: *const MediaSource) []const u8 {
    return "closed";
}

// NaN until a duration is set on an open source, which is what Chrome reports
// for a detached one.
pub fn getDuration(_: *const MediaSource) f64 {
    return std.math.nan(f64);
}

pub fn setDuration(_: *MediaSource, _: f64) !void {
    return error.InvalidStateError;
}

pub fn getSourceBuffers(_: *const MediaSource) []const js.Value {
    return &.{};
}

pub fn getActiveSourceBuffers(_: *const MediaSource) []const js.Value {
    return &.{};
}

// Every mutator needs an open source, and this one is never open. Chrome's
// error for all of them on a closed source is InvalidStateError.
pub fn addSourceBuffer(_: *MediaSource, _: []const u8) !void {
    return error.InvalidStateError;
}

pub fn removeSourceBuffer(_: *MediaSource, _: ?js.Value) !void {
    return error.InvalidStateError;
}

pub fn endOfStream(_: *MediaSource, _: ?[]const u8) !void {
    return error.InvalidStateError;
}

pub fn setLiveSeekableRange(_: *MediaSource, _: f64, _: f64) !void {
    return error.InvalidStateError;
}

pub fn clearLiveSeekableRange(_: *MediaSource) !void {
    return error.InvalidStateError;
}

pub fn getOnSourceOpen(self: *const MediaSource) ?js.Function.Global {
    return self._on_sourceopen;
}

pub fn setOnSourceOpen(self: *MediaSource, cb: ?js.Function) !void {
    self._on_sourceopen = if (cb) |c| try c.persistWithThis(self) else null;
}

pub fn getOnSourceEnded(self: *const MediaSource) ?js.Function.Global {
    return self._on_sourceended;
}

pub fn setOnSourceEnded(self: *MediaSource, cb: ?js.Function) !void {
    self._on_sourceended = if (cb) |c| try c.persistWithThis(self) else null;
}

pub fn getOnSourceClose(self: *const MediaSource) ?js.Function.Global {
    return self._on_sourceclose;
}

pub fn setOnSourceClose(self: *MediaSource, cb: ?js.Function) !void {
    self._on_sourceclose = if (cb) |c| try c.persistWithThis(self) else null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaSource);

    pub const Meta = struct {
        pub const name = "MediaSource";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MediaSource.constructor, .{});

    pub const isTypeSupported = bridge.function(MediaSource.isTypeSupported, .{ .static = true });

    pub const readyState = bridge.accessor(MediaSource.getReadyState, null, .{});
    pub const duration = bridge.accessor(MediaSource.getDuration, MediaSource.setDuration, .{});
    pub const sourceBuffers = bridge.accessor(MediaSource.getSourceBuffers, null, .{});
    pub const activeSourceBuffers = bridge.accessor(MediaSource.getActiveSourceBuffers, null, .{});
    pub const onsourceopen = bridge.accessor(MediaSource.getOnSourceOpen, MediaSource.setOnSourceOpen, .{});
    pub const onsourceended = bridge.accessor(MediaSource.getOnSourceEnded, MediaSource.setOnSourceEnded, .{});
    pub const onsourceclose = bridge.accessor(MediaSource.getOnSourceClose, MediaSource.setOnSourceClose, .{});

    pub const addSourceBuffer = bridge.function(MediaSource.addSourceBuffer, .{});
    pub const removeSourceBuffer = bridge.function(MediaSource.removeSourceBuffer, .{});
    pub const endOfStream = bridge.function(MediaSource.endOfStream, .{});
    pub const setLiveSeekableRange = bridge.function(MediaSource.setLiveSeekableRange, .{});
    pub const clearLiveSeekableRange = bridge.function(MediaSource.clearLiveSeekableRange, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaSource" {
    try testing.htmlRunner("media_mimes.html", .{});
}
