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
const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");
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
const eme = @import("../../media/eme.zig");
const global_event_handlers = @import("../../global_event_handlers.zig");
const playback = @import("../../media/playback.zig");
const MediaStream = @import("../../media/streams.zig").MediaStream;
const DOMTokenList = @import("../../collections.zig").DOMTokenList;
const Execution = js.Execution;

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

pub const Type = enum(u8) {
    generic,
    audio,
    video,
};

// `.generic` maps to Media itself: a bare <media> chain ends at Media, so the
// tag has no chain member of its own.
pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .generic => Media,
        .audio => Audio,
        .video => Video,
    };
}

pub fn subtype(self: *const Media, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, Media);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

_type: Type,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_text_tracks: ?*text_tracks.TextTrackList = null,
_paused: bool = true,
_current_time: f64 = 0,
_volume: f64 = 1.0,
_muted: bool = false,
_playback_rate: f64 = 1.0,
// Two slots, not attribute reflections: `preservespitch` is never written to
// the markup and `defaultPlaybackRate` does not move `playbackRate`
// (measured, probes/expr-read-path-members.js).
_default_playback_rate: f64 = 1.0,
_preserves_pitch: bool = true,
_sink_id: []const u8 = "",
_src_object: ?*MediaStream = null,
_ready_state: ReadyState = .HAVE_NOTHING,

// Set once a MediaElementAudioSourceNode has claimed this element. An element
// can only ever back one of them, and Chrome refuses the second attempt rather
// than handing back the first node (measured).
_audio_source_connected: bool = false,
_network_state: NetworkState = .NETWORK_EMPTY,
_error: ?*MediaError = null,

// The MediaKeys last handed to setMediaKeys(). Null until a page attaches one,
// and settable back to null (measured).
_media_keys: ?*eme.MediaKeys = null,

// video.remote. Built on first read and then kept, because
// `video.remote === video.remote` has to hold -- and each element gets its own,
// so an <audio> next to a <video> does not share one (both measured).
_remote: ?*playback.RemotePlayback = null,

pub fn asElement(self: *Media) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Media) *const Element {
    return Factory.protoOf(@constCast(self)).asElement();
}
pub fn asNode(self: *Media) *Node {
    return self.asElement().asNode();
}

pub fn is(self: *Media, comptime T: type) ?*T {
    switch (self._type) {
        inline .audio, .video => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
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
    const src = element.getAttributeInterned("src") orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Media, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

// autoplay/controls/loop/preload moved to the `Element.Reflect` helpers in
// JsApi below: `reflect.boolean` is the same attribute-presence reflection our
// hand-written pairs did, and `reflect.enumerated("preload", ...)` additionally
// canonicalizes an unknown keyword to the "auto" missing/invalid default, which
// is what Blink's HTMLMediaElement::preload() does.

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
    // The factory tags the EventTarget from the leaf type (Factory.typeInit),
    // so there is no `_type` to assign by hand any more.
    const list = try page.factory.eventTarget(text_tracks.TextTrackList{ ._proto = undefined });
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
    try exec.dispatch(list.asEventTarget(), add_track.asEvent(), null, .{ .context = "TextTrackList addtrack" });

    const change = try Event.initTrusted(try String.init(page.frame_arena, "change", .{}), null, page);
    try exec.dispatch(list.asEventTarget(), change, null, .{ .context = "TextTrackList change" });
    return track;
}

// == Encrypted Media Extensions ==

pub fn getMediaKeys(self: *const Media) ?*eme.MediaKeys {
    return self._media_keys;
}

// Chrome accepts the same keys twice, accepts a different set, and accepts
// null to detach -- all of them resolve (measured on an element with no
// source). A non-MediaKeys argument is a rejection, not a synchronous throw.
pub fn setMediaKeys(self: *Media, keys_: ?js.Value, exec: *const js.Execution) js.Promise {
    const local = exec.js.local.?;
    const keys = keys_ orelse return local.rejectPromise(.{
        .type_error = "Failed to execute 'setMediaKeys' on 'HTMLMediaElement': " ++
            "1 argument required, but only 0 present.",
    });
    if (keys.isNull()) {
        self._media_keys = null;
        return local.resolvePromise(null) catch local.rejectPromise(.{
            .type_error = "Failed to execute 'setMediaKeys' on 'HTMLMediaElement'.",
        });
    }
    const attached = keys.toZig(*eme.MediaKeys) catch return local.rejectPromise(.{
        .type_error = "Failed to execute 'setMediaKeys' on 'HTMLMediaElement': " ++
            "parameter 1 is not of type 'MediaKeys'.",
    });
    self._media_keys = attached;
    return local.resolvePromise(null) catch local.rejectPromise(.{
        .type_error = "Failed to execute 'setMediaKeys' on 'HTMLMediaElement'.",
    });
}

/// video.remote, created on first read.
pub fn getRemote(self: *Media, exec: *js.Execution) !*playback.RemotePlayback {
    if (self._remote) |existing| return existing;
    const created = try playback.RemotePlayback.create(self, exec);
    self._remote = created;
    return created;
}

/// Reflects the `disableremoteplayback` content attribute: setting it true
/// writes an empty attribute, false removes it (measured).
pub fn getDisableRemotePlayback(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(.wrap("disableremoteplayback")) != null;
}

pub fn setDisableRemotePlayback(self: *Media, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(.wrap("disableremoteplayback"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(.wrap("disableremoteplayback"), frame);
    }
}

pub fn getDefaultPlaybackRate(self: *const Media) f64 {
    return self._default_playback_rate;
}

pub fn setDefaultPlaybackRate(self: *Media, value: f64) void {
    self._default_playback_rate = value;
}

pub fn getPreservesPitch(self: *const Media) bool {
    return self._preserves_pitch;
}

pub fn setPreservesPitch(self: *Media, value: bool) void {
    self._preserves_pitch = value;
}

pub fn getSrcObject(self: *const Media) ?*MediaStream {
    return self._src_object;
}

pub fn setSrcObject(self: *Media, value: ?*MediaStream) void {
    self._src_object = value;
}

/// Chrome counts bytes the decoder has consumed. Nothing here decodes, so both
/// are zero -- which is also what Chrome answers for an element that has never
/// been given a source (measured).
pub fn getWebkitAudioDecodedByteCount(_: *const Media) u32 {
    return 0;
}

pub fn getWebkitVideoDecodedByteCount(_: *const Media) u32 {
    return 0;
}

/// Chrome hands back a MediaStream even from an element with nothing playing;
/// it simply has no tracks yet.
pub fn captureStream(_: *Media, exec: *Execution) !*MediaStream {
    return MediaStream.create(exec);
}

/// The empty string is the default audio device and always selectable, so it
/// resolves; anything else is a device this engine does not have. Chrome
/// answers the same two ways on a machine with no such device (measured), and
/// the rejection carries Blink's own sentence.
pub fn setSinkId(self: *Media, sink_id: []const u8, frame: *Frame) !js.Promise {
    if (sink_id.len == 0) {
        self._sink_id = "";
        return frame.js.local.?.resolvePromise({});
    }
    return frame.js.local.?.rejectPromise(.{ .dom_exception = .{
        .err = error.NotFound,
        .message = "Requested device not found",
    } });
}

pub fn getSinkId(self: *const Media) []const u8 {
    return self._sink_id;
}

pub fn getControlsList(self: *Media, frame: *Frame) !*DOMTokenList {
    return self.asElement().getTokenList(.controlslist, frame);
}

pub fn setControlsList(self: *Media, value: lp.String, frame: *Frame) !void {
    const list = try self.getControlsList(frame);
    try list.setValue(value, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Media);

    // Getter/setter pair for an event handler property, through the element
    // the media element is.
    fn handlerAccessor(comptime handler: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *Media, frame: *Frame) !?js.Function.Global {
                return self.asElement().getAttributeFunction(handler, frame);
            }

            pub fn set(self: *Media, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.asElement().setAttributeListener(handler, callback, frame);
            }
        };
    }

    pub const Meta = struct {
        pub const name = "HTMLMediaElement";
        pub const constructor_after = "setSinkId";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own-property order, measured. It is not IDL order and it is not
    // the order this file used to carry: the numeric constants sit in the
    // middle rather than at the top, and `constructor` lands after `setSinkId`
    // because everything below it is installed per context.
    const reflect = Element.Reflect(Media);
    pub const @"error" = bridge.accessor(Media.getError, null, .{});
    pub const src = bridge.accessor(Media.getSrc, Media.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Media.getSrc, null, .{});
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const networkState = bridge.accessor(Media.getNetworkState, null, .{});
    pub const preload = reflect.enumerated("preload", &.{ "none", "metadata", "auto" }, .{ .missing = "auto" });
    pub const buffered = bridge.accessor(Media.getBuffered, null, .{});
    pub const readyState = bridge.accessor(Media.getReadyState, null, .{});
    pub const seeking = bridge.accessor(Media.getSeeking, null, .{});
    pub const currentTime = bridge.accessor(Media.getCurrentTime, Media.setCurrentTime, .{});
    pub const duration = bridge.accessor(Media.getDuration, null, .{});
    pub const paused = bridge.accessor(Media.getPaused, null, .{});
    pub const defaultPlaybackRate = bridge.accessor(Media.getDefaultPlaybackRate, Media.setDefaultPlaybackRate, .{});
    pub const playbackRate = bridge.accessor(Media.getPlaybackRate, Media.setPlaybackRate, .{});
    pub const played = bridge.accessor(Media.getPlayed, null, .{});
    pub const seekable = bridge.accessor(Media.getSeekable, null, .{});
    pub const ended = bridge.accessor(Media.getEnded, null, .{});
    pub const autoplay = reflect.boolean("autoplay");
    pub const loop = reflect.boolean("loop");
    pub const preservesPitch = bridge.accessor(Media.getPreservesPitch, Media.setPreservesPitch, .{});
    pub const controls = reflect.boolean("controls");
    pub const controlsList = bridge.accessor(Media.getControlsList, Media.setControlsList, .{ .ce_reactions = true });
    pub const volume = bridge.accessor(Media.getVolume, Media.setVolume, .{});
    pub const muted = bridge.accessor(Media.getMuted, Media.setMuted, .{});
    pub const defaultMuted = reflect.boolean("muted");
    pub const textTracks = bridge.accessor(Media.getTextTracks, null, .{});
    pub const webkitAudioDecodedByteCount = bridge.accessor(Media.getWebkitAudioDecodedByteCount, null, .{});
    pub const webkitVideoDecodedByteCount = bridge.accessor(Media.getWebkitVideoDecodedByteCount, null, .{});
    pub const onencrypted = bridge.accessor(handlerAccessor(.onencrypted).get, handlerAccessor(.onencrypted).set, .{});
    pub const onwaitingforkey = bridge.accessor(handlerAccessor(.onwaitingforkey).get, handlerAccessor(.onwaitingforkey).set, .{});
    pub const srcObject = bridge.accessor(Media.getSrcObject, Media.setSrcObject, .{});

    pub const NETWORK_EMPTY = bridge.property(@intFromEnum(NetworkState.NETWORK_EMPTY), .{ .template = true });
    pub const NETWORK_IDLE = bridge.property(@intFromEnum(NetworkState.NETWORK_IDLE), .{ .template = true });
    pub const NETWORK_LOADING = bridge.property(@intFromEnum(NetworkState.NETWORK_LOADING), .{ .template = true });
    pub const NETWORK_NO_SOURCE = bridge.property(@intFromEnum(NetworkState.NETWORK_NO_SOURCE), .{ .template = true });

    pub const HAVE_NOTHING = bridge.property(@intFromEnum(ReadyState.HAVE_NOTHING), .{ .template = true });
    pub const HAVE_METADATA = bridge.property(@intFromEnum(ReadyState.HAVE_METADATA), .{ .template = true });
    pub const HAVE_CURRENT_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_CURRENT_DATA), .{ .template = true });
    pub const HAVE_FUTURE_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_FUTURE_DATA), .{ .template = true });
    pub const HAVE_ENOUGH_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_ENOUGH_DATA), .{ .template = true });

    pub const addTextTrack = bridge.function(Media.addTextTrack, .{ .arity = 1 });
    pub const canPlayType = bridge.function(Media.canPlayType, .{});
    pub const captureStream = bridge.function(Media.captureStream, .{});
    pub const load = bridge.function(Media.load, .{});
    pub const pause = bridge.function(Media.pause, .{});
    pub const play = bridge.function(Media.play, .{});

    /// A media element's missing-value default is `eager`, where an iframe's
    /// is `auto` (both measured). Same attribute name, different default --
    /// which is why this is a reflection written out per element rather than a
    /// shared helper.
    pub const loading = reflect.enumerated("loading", &.{ "lazy", "eager" }, .{ .missing = "eager", .invalid = "eager" });

    pub const sinkId = bridge.accessor(Media.getSinkId, null, .{});
    pub const remote = bridge.accessor(Media.getRemote, null, .{});
    pub const disableRemotePlayback = bridge.accessor(Media.getDisableRemotePlayback, Media.setDisableRemotePlayback, .{ .ce_reactions = true });
    pub const setSinkId = bridge.function(Media.setSinkId, .{ .arity = 1 });

    // EME arrives on a partial interface, so Chrome lists these two *after*
    // `constructor`.
    pub const mediaKeys = bridge.accessor(Media.getMediaKeys, null, .{});
    pub const setMediaKeys = bridge.function(Media.setMediaKeys, .{ .arity = 1 });
};

const testing = @import("../../../../testing.zig");
test "WebApi: Media" {
    try testing.htmlRunner("element/html/media.html", .{});
}
