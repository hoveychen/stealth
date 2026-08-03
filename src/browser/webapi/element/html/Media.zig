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

const std = @import("std");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Event = @import("../../Event.zig");
pub const Audio = @import("Audio.zig");
pub const Video = @import("Video.zig");
const MediaError = @import("../../media/MediaError.zig");
const TimeRanges = @import("../../media/TimeRanges.zig");
const text_tracks = @import("../../media/text_tracks.zig");
const misc_events = @import("../../event/misc_events.zig");
const String = @import("lightpanda").String;
const mime = @import("../../media/mime.zig");

const Media = @This();

pub const Proto = HtmlElement;

pub const ReadyState = enum(u16) {
    HAVE_NOTHING = 0,
    HAVE_METADATA = 1,
    HAVE_CURRENT_DATA = 2,
    HAVE_FUTURE_DATA = 3,
    HAVE_ENOUGH_DATA = 4,
};

pub const NetworkState = enum(u16) {
    NETWORK_EMPTY = 0,
    NETWORK_IDLE = 1,
    NETWORK_LOADING = 2,
    NETWORK_NO_SOURCE = 3,
};

pub const Type = union(enum) {
    generic,
    audio: *Audio,
    video: *Video,
};

_type: Type,
_proto: *HtmlElement,
_text_tracks: ?*text_tracks.TextTrackList = null,
_paused: bool = true,
_current_time: f64 = 0,
_volume: f64 = 1.0,
_muted: bool = false,
_playback_rate: f64 = 1.0,
_ready_state: ReadyState = .HAVE_NOTHING,

// Set once a MediaElementAudioSourceNode has claimed this element. An element
// can only ever back one of them, and Chrome refuses the second attempt rather
// than handing back the first node (measured).
_audio_source_connected: bool = false,
_network_state: NetworkState = .NETWORK_EMPTY,
_error: ?*MediaError = null,

pub fn asElement(self: *Media) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Media) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Media) *Node {
    return self.asElement().asNode();
}

pub fn is(self: *Media, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .audio => |a| {
            if (T == *Audio) return a;
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.Audio")) {
                return a;
            }
        },
        .video => |v| {
            if (T == *Video) return v;
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.Video")) {
                return v;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Media, comptime T: type) *T {
    return self.is(T).?;
}

// Answered from the shared Chrome table, so that canPlayType(),
// MediaSource.isTypeSupported() and MediaRecorder.isTypeSupported() cannot
// contradict each other — see media/mime.zig.
pub fn canPlayType(_: *const Media, mime_type: []const u8) []const u8 {
    return mime.canPlayType(mime_type).toString();
}

pub fn play(self: *Media, frame: *Frame) !js.Promise {
    const was_paused = self._paused;
    self._paused = false;
    self._ready_state = .HAVE_ENOUGH_DATA;
    self._network_state = .NETWORK_IDLE;
    if (was_paused) {
        try self.dispatchEvent("play", frame);
        try self.dispatchEvent("playing", frame);
    }
    return frame.js.local.?.resolvePromise(js.Undefined{});
}

pub fn pause(self: *Media, frame: *Frame) !void {
    if (!self._paused) {
        self._paused = true;
        try self.dispatchEvent("pause", frame);
    }
}

pub fn load(self: *Media, frame: *Frame) !void {
    self._paused = true;
    self._current_time = 0;
    self._ready_state = .HAVE_NOTHING;
    self._network_state = .NETWORK_LOADING;
    self._error = null;
    try self.dispatchEvent("emptied", frame);
}

fn dispatchEvent(self: *Media, name: []const u8, frame: *Frame) !void {
    const event = try Event.init(name, .{ .bubbles = false, .cancelable = false }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub fn getPaused(self: *const Media) bool {
    return self._paused;
}

pub fn getCurrentTime(self: *const Media) f64 {
    return self._current_time;
}

pub fn getDuration(_: *const Media) f64 {
    return std.math.nan(f64);
}

pub fn getReadyState(self: *const Media) u16 {
    return @intFromEnum(self._ready_state);
}

pub fn getNetworkState(self: *const Media) u16 {
    return @intFromEnum(self._network_state);
}

pub fn getEnded(_: *const Media) bool {
    return false;
}

pub fn getSeeking(_: *const Media) bool {
    return false;
}

pub fn getError(self: *const Media) ?*MediaError {
    return self._error;
}

pub fn getVolume(self: *const Media) f64 {
    return self._volume;
}

pub fn setVolume(self: *Media, value: f64) void {
    self._volume = @max(0.0, @min(1.0, value));
}

pub fn getMuted(self: *const Media) bool {
    return self._muted;
}

pub fn setMuted(self: *Media, value: bool) void {
    self._muted = value;
}

pub fn getPlaybackRate(self: *const Media) f64 {
    return self._playback_rate;
}

pub fn setPlaybackRate(self: *Media, value: f64) void {
    self._playback_rate = value;
}

pub fn setCurrentTime(self: *Media, value: f64) void {
    self._current_time = value;
}

pub fn getSrc(self: *const Media, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Media, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getAutoplay(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("autoplay")) != null;
}

pub fn setAutoplay(self: *Media, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("autoplay"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("autoplay"), frame);
    }
}

pub fn getControls(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("controls")) != null;
}

pub fn setControls(self: *Media, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("controls"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("controls"), frame);
    }
}

pub fn getLoop(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loop")) != null;
}

pub fn setLoop(self: *Media, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("loop"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("loop"), frame);
    }
}

pub fn getPreload(self: *const Media) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("preload")) orelse "auto";
}

pub fn setPreload(self: *Media, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("preload"), .wrap(value), frame);
}

// No media is ever loaded, so all three ranges are empty -- which is also what
// a real Chrome answers for an element that was never given a src (measured:
// `document.createElement('video').buffered.length === 0`). Before this they
// were undefined, and a media element without them is not a shape any browser
// has.
pub fn getBuffered(_: *const Media, frame: *Frame) !*TimeRanges {
    return frame._factory.create(TimeRanges{});
}

pub fn getPlayed(_: *const Media, frame: *Frame) !*TimeRanges {
    return frame._factory.create(TimeRanges{});
}

pub fn getSeekable(_: *const Media, frame: *Frame) !*TimeRanges {
    return frame._factory.create(TimeRanges{});
}

const Page = @import("../../../Page.zig");

// One list per element, created on first read and kept: `v.textTracks ===
// v.textTracks` is true in Chrome (measured), so a fresh list per read would be
// a tell of its own.
pub fn getTextTracks(self: *Media, page: *Page) !*text_tracks.TextTrackList {
    if (self._text_tracks) |list| {
        return list;
    }
    const list = try page.factory.eventTarget(text_tracks.TextTrackList{ ._proto = undefined });
    list._proto._type = .{ .text_track_list = list };
    self._text_tracks = list;
    return list;
}

// Chrome reports arity 1 and validates the kind against TextTrackKind, with the
// label and language defaulting to the empty string (measured).
pub fn addTextTrack(
    self: *Media,
    kind: []const u8,
    label_: ?[]const u8,
    language_: ?[]const u8,
    exec: *const js.Execution,
) !*text_tracks.TextTrack {
    const parsed = std.meta.stringToEnum(text_tracks.TextTrack.Kind, kind) orelse {
        const isolate = exec.js.isolate;
        const message = try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute 'addTextTrack' on 'HTMLMediaElement': The provided value '{s}' is not a valid enum value of type TextTrackKind.",
            .{kind},
        );
        _ = isolate.throwException(isolate.createTypeError(message));
        return error.JsException;
    };

    const page = exec.page;
    const track = try text_tracks.TextTrack.create(parsed, label_ orelse "", language_ orelse "", page);
    const list = try self.getTextTracks(page);
    try list._items.append(page.frame_arena, track);

    // Chrome fires both, in this order, on the list itself (measured: an
    // addtrack listener sees a TrackEvent carrying the new track, then onchange
    // runs).
    const add_track = try misc_events.TrackEvent.initTrusted("addtrack", track, exec);
    try exec.dispatch(list.asEventTarget(), add_track.asEvent(), list._on_add_track, .{ .context = "TextTrackList addtrack" });

    const change = try Event.initTrusted(try String.init(page.frame_arena, "change", .{}), null, page);
    try exec.dispatch(list.asEventTarget(), change, list._on_change, .{ .context = "TextTrackList change" });
    return track;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Media);

    pub const Meta = struct {
        pub const name = "HTMLMediaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const NETWORK_EMPTY = bridge.property(@intFromEnum(NetworkState.NETWORK_EMPTY), .{ .template = true });
    pub const NETWORK_IDLE = bridge.property(@intFromEnum(NetworkState.NETWORK_IDLE), .{ .template = true });
    pub const NETWORK_LOADING = bridge.property(@intFromEnum(NetworkState.NETWORK_LOADING), .{ .template = true });
    pub const NETWORK_NO_SOURCE = bridge.property(@intFromEnum(NetworkState.NETWORK_NO_SOURCE), .{ .template = true });

    pub const HAVE_NOTHING = bridge.property(@intFromEnum(ReadyState.HAVE_NOTHING), .{ .template = true });
    pub const HAVE_METADATA = bridge.property(@intFromEnum(ReadyState.HAVE_METADATA), .{ .template = true });
    pub const HAVE_CURRENT_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_CURRENT_DATA), .{ .template = true });
    pub const HAVE_FUTURE_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_FUTURE_DATA), .{ .template = true });
    pub const HAVE_ENOUGH_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_ENOUGH_DATA), .{ .template = true });

    pub const src = bridge.accessor(Media.getSrc, Media.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Media.getSrc, null, .{});
    pub const autoplay = bridge.accessor(Media.getAutoplay, Media.setAutoplay, .{ .ce_reactions = true });
    pub const controls = bridge.accessor(Media.getControls, Media.setControls, .{ .ce_reactions = true });
    pub const loop = bridge.accessor(Media.getLoop, Media.setLoop, .{ .ce_reactions = true });
    pub const muted = bridge.accessor(Media.getMuted, Media.setMuted, .{});
    pub const preload = bridge.accessor(Media.getPreload, Media.setPreload, .{ .ce_reactions = true });
    pub const volume = bridge.accessor(Media.getVolume, Media.setVolume, .{});
    pub const playbackRate = bridge.accessor(Media.getPlaybackRate, Media.setPlaybackRate, .{});
    pub const currentTime = bridge.accessor(Media.getCurrentTime, Media.setCurrentTime, .{});
    pub const duration = bridge.accessor(Media.getDuration, null, .{});
    pub const paused = bridge.accessor(Media.getPaused, null, .{});
    pub const ended = bridge.accessor(Media.getEnded, null, .{});
    pub const seeking = bridge.accessor(Media.getSeeking, null, .{});
    pub const readyState = bridge.accessor(Media.getReadyState, null, .{});
    pub const buffered = bridge.accessor(Media.getBuffered, null, .{});
    pub const played = bridge.accessor(Media.getPlayed, null, .{});
    pub const seekable = bridge.accessor(Media.getSeekable, null, .{});
    pub const networkState = bridge.accessor(Media.getNetworkState, null, .{});
    pub const @"error" = bridge.accessor(Media.getError, null, .{});

    pub const textTracks = bridge.accessor(Media.getTextTracks, null, .{});

    pub const addTextTrack = bridge.function(Media.addTextTrack, .{ .arity = 1 });
    pub const canPlayType = bridge.function(Media.canPlayType, .{});
    pub const play = bridge.function(Media.play, .{});
    pub const pause = bridge.function(Media.pause, .{});
    pub const load = bridge.function(Media.load, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Media" {
    try testing.htmlRunner("element/html/media.html", .{});
}
