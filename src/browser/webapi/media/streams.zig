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

//! MediaStream and its track, plus the two events that carry them.
//!
//! Nothing here captures anything: getUserMedia still refuses, and no camera or
//! microphone is reachable. What *is* reachable is the one stream a page can
//! build without a permission — `AudioContext.createMediaStreamDestination()`
//! hands out a live stream with one audio track — and `new MediaStream()`,
//! which Chrome allows unconditionally. Both are what the three
//! MediaStream-flavoured audio nodes need to exist at all.
//!
//! Every value, every refusal and every enum member below was read off a headed
//! Chrome 150 over http://localhost (win17/win18/win19-chrome.json). Two of
//! them a spec reading would have got wrong:
//!
//!   * `contentHint` on an audio track accepts "", "speech" and "music" and
//!     silently drops everything else — including "speech-recognition", which
//!     the spec lists. Measured one value at a time.
//!   * `addTrack()` does not fire `addtrack`, and `stop()` does not fire
//!     `ended`. Both events exist only for tracks a capture source owns, and
//!     nothing here owns one, so the two handler slots are pure storage.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");
const Page = @import("../../Page.zig");

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        MediaStream,
        MediaStreamTrack,
        OverconstrainedError,
        MediaStreamTrackAudioStats,
        MediaStreamTrackEvent,
        MediaStreamEvent,
    };
}

fn typeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn handlerAccessors(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn get(self: *T) ?js.Function.Global {
            return @field(self, field);
        }

        fn set(self: *T, listener: ?js.Function) !void {
            @field(self, field) = if (listener) |l| try l.persistWithThis(self) else null;
        }
    };
}

// ---------------------------------------------------------------------------
// MediaStream
// ---------------------------------------------------------------------------

pub const MediaStream = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    // A v4 UUID, which is what Chrome hands out (measured: 36 characters, and
    // the version and variant nibbles are in the right places).
    _id: [36]u8,

    // In insertion order, which is the order getTracks() reports.
    _tracks: std.ArrayListUnmanaged(*MediaStreamTrack) = .empty,

    _on_add_track: ?js.Function.Global = null,
    _on_remove_track: ?js.Function.Global = null,
    _on_active: ?js.Function.Global = null,
    _on_inactive: ?js.Function.Global = null,

    // `new MediaStream()`, `new MediaStream(tracks)` and `new MediaStream(other)`
    // are three WebIDL overloads. Anything else — including an explicit `null`
    // or `undefined`, which Chrome does *not* treat as an absent argument
    // (measured: both are "Overload resolution failed.") — is refused.
    pub fn constructor(from: ?js.Value, exec: *Execution) !*MediaStream {
        const self = try create(exec);
        const given = from orelse return self;

        if (given.toZig(*MediaStream)) |other| {
            try self._tracks.appendSlice(exec.arena, other._tracks.items);
            return self;
        } else |_| {}

        if (given.toZig([]const *MediaStreamTrack)) |tracks| {
            try self._tracks.appendSlice(exec.arena, tracks);
            return self;
        } else |_| {}

        return typeError("Failed to construct 'MediaStream': Overload resolution failed.", exec);
    }

    pub fn create(exec: *Execution) !*MediaStream {
        var id: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&id);
        return exec._factory.eventTarget(MediaStream{ ._proto = undefined, ._id = id });
    }

    pub fn asEventTarget(self: *MediaStream) *EventTarget {
        return self._proto;
    }

    pub fn getId(self: *const MediaStream) [36]u8 {
        return self._id;
    }

    // True while at least one track is still live. An empty stream is inactive,
    // and stopping every track makes a live one inactive (both measured).
    pub fn getActive(self: *const MediaStream) bool {
        for (self._tracks.items) |track| {
            if (track._ready_state == .live) return true;
        }
        return false;
    }

    pub fn getTracks(self: *const MediaStream) []const *MediaStreamTrack {
        return self._tracks.items;
    }

    pub fn getAudioTracks(self: *const MediaStream, exec: *const Execution) ![]const *MediaStreamTrack {
        return self.ofKind(.audio, exec);
    }

    pub fn getVideoTracks(self: *const MediaStream, exec: *const Execution) ![]const *MediaStreamTrack {
        return self.ofKind(.video, exec);
    }

    fn ofKind(self: *const MediaStream, kind: MediaStreamTrack.Kind, exec: *const Execution) ![]const *MediaStreamTrack {
        var out: std.ArrayListUnmanaged(*MediaStreamTrack) = .empty;
        for (self._tracks.items) |track| {
            if (track._kind == kind) {
                try out.append(exec.call_arena, track);
            }
        }
        return out.items;
    }

    pub fn getTrackById(self: *const MediaStream, id: ?[]const u8, exec: *const Execution) !?*MediaStreamTrack {
        const wanted = id orelse return typeError(
            "Failed to execute 'getTrackById' on 'MediaStream': 1 argument required, but only 0 present.",
            exec,
        );
        for (self._tracks.items) |track| {
            if (std.mem.eql(u8, &track._id, wanted)) return track;
        }
        return null;
    }

    // A track already in the stream is ignored rather than duplicated, and no
    // `addtrack` event is fired (both measured).
    pub fn addTrack(self: *MediaStream, track: ?js.Value, exec: *Execution) !void {
        const added = try self.oneTrack("addTrack", track, exec);
        for (self._tracks.items) |existing| {
            if (existing == added) return;
        }
        return self._tracks.append(exec.arena, added);
    }

    // Removing a track that was never in the stream is not an error (measured).
    pub fn removeTrack(self: *MediaStream, track: ?js.Value, exec: *Execution) !void {
        const removed = try self.oneTrack("removeTrack", track, exec);
        for (self._tracks.items, 0..) |existing, i| {
            if (existing == removed) {
                _ = self._tracks.orderedRemove(i);
                return;
            }
        }
    }

    fn oneTrack(
        _: *MediaStream,
        comptime method: []const u8,
        value: ?js.Value,
        exec: *const Execution,
    ) !*MediaStreamTrack {
        const given = value orelse return typeError(
            "Failed to execute '" ++ method ++ "' on 'MediaStream': 1 argument required, but only 0 present.",
            exec,
        );
        return given.toZig(*MediaStreamTrack) catch typeError(
            "Failed to execute '" ++ method ++ "' on 'MediaStream': parameter 1 is not of type 'MediaStreamTrack'.",
            exec,
        );
    }

    // A fresh stream id over freshly cloned tracks — the clones are new objects
    // with new ids of their own (measured).
    pub fn clone(self: *MediaStream, exec: *Execution) !*MediaStream {
        const copy = try create(exec);
        for (self._tracks.items) |track| {
            try copy._tracks.append(exec.arena, try track.clone(exec));
        }
        return copy;
    }

    const add_track = handlerAccessors(MediaStream, "_on_add_track");
    const remove_track = handlerAccessors(MediaStream, "_on_remove_track");
    const active = handlerAccessors(MediaStream, "_on_active");
    const inactive = handlerAccessors(MediaStream, "_on_inactive");

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStream);

        pub const Meta = struct {
            pub const name = "MediaStream";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            // Chrome still ships the prefixed alias, and it is the same
            // constructor there (measured: webkitMediaStream === MediaStream).
            pub const constructor_aliases = [_][]const u8{"webkitMediaStream"};
        };

        pub const constructor = bridge.constructor(MediaStream.constructor, .{ .arity = 0 });

        // Chrome's prototype order.
        pub const id = bridge.accessor(MediaStream.getId, null, .{});
        pub const active = bridge.accessor(MediaStream.getActive, null, .{});
        pub const onaddtrack = bridge.accessor(MediaStream.add_track.get, MediaStream.add_track.set, .{});
        pub const onremovetrack = bridge.accessor(MediaStream.remove_track.get, MediaStream.remove_track.set, .{});
        pub const onactive = bridge.accessor(MediaStream.active.get, MediaStream.active.set, .{});
        pub const oninactive = bridge.accessor(MediaStream.inactive.get, MediaStream.inactive.set, .{});
        pub const addTrack = bridge.function(MediaStream.addTrack, .{ .arity = 1 });
        pub const clone = bridge.function(MediaStream.clone, .{ .arity = 0 });
        pub const getAudioTracks = bridge.function(MediaStream.getAudioTracks, .{ .arity = 0 });
        pub const getTrackById = bridge.function(MediaStream.getTrackById, .{ .arity = 1, .null_as_undefined = false });
        pub const getTracks = bridge.function(MediaStream.getTracks, .{ .arity = 0 });
        pub const getVideoTracks = bridge.function(MediaStream.getVideoTracks, .{ .arity = 0 });
        pub const removeTrack = bridge.function(MediaStream.removeTrack, .{ .arity = 1 });
    };
};

// ---------------------------------------------------------------------------
// MediaStreamTrack
// ---------------------------------------------------------------------------

pub const MediaStreamTrack = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    _id: [36]u8,

    // "WebAudio-" followed by a second UUID, which is the form Chrome gives a
    // track that a MediaStreamAudioDestinationNode owns (measured: 45
    // characters, and getCapabilities().deviceId is the same string).
    _device_id: [45]u8,

    _kind: Kind = .audio,
    _label: []const u8,
    _enabled: bool = true,
    _ready_state: ReadyState = .live,
    _content_hint: ContentHint = .none,
    _channel_count: u32 = 2,
    _sample_rate: f64 = 48000,

    _on_mute: ?js.Function.Global = null,
    _on_unmute: ?js.Function.Global = null,
    _on_ended: ?js.Function.Global = null,
    _on_capture_handle_change: ?js.Function.Global = null,

    _stats: ?*MediaStreamTrackAudioStats = null,

    pub const Kind = enum { audio, video };

    pub const ReadyState = enum { live, ended };

    // Chrome accepts exactly these three on an audio track and drops the rest,
    // including the spec's "speech-recognition" (measured one at a time). The
    // video hints are unreachable: nothing here produces a video track.
    pub const ContentHint = enum {
        none,
        speech,
        music,

        fn label(self: ContentHint) []const u8 {
            return switch (self) {
                .none => "",
                .speech => "speech",
                .music => "music",
            };
        }
    };

    pub fn create(label: []const u8, channel_count: u32, sample_rate: f64, exec: *Execution) !*MediaStreamTrack {
        var id: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&id);

        var device_id: [45]u8 = undefined;
        @memcpy(device_id[0..9], "WebAudio-");
        @import("../../../id.zig").uuidv4(device_id[9..]);

        return exec._factory.eventTarget(MediaStreamTrack{
            ._proto = undefined,
            ._id = id,
            ._device_id = device_id,
            ._label = label,
            ._channel_count = channel_count,
            ._sample_rate = sample_rate,
        });
    }

    // A new track object with a new id and a new device id, carrying the same
    // label and settings (measured).
    pub fn clone(self: *const MediaStreamTrack, exec: *Execution) !*MediaStreamTrack {
        const copy = try create(self._label, self._channel_count, self._sample_rate, exec);
        copy._kind = self._kind;
        copy._enabled = self._enabled;
        copy._content_hint = self._content_hint;
        return copy;
    }

    pub fn asEventTarget(self: *MediaStreamTrack) *EventTarget {
        return self._proto;
    }

    pub fn getKind(self: *const MediaStreamTrack) []const u8 {
        return @tagName(self._kind);
    }

    pub fn getId(self: *const MediaStreamTrack) [36]u8 {
        return self._id;
    }

    pub fn getLabel(self: *const MediaStreamTrack) []const u8 {
        return self._label;
    }

    pub fn getEnabled(self: *const MediaStreamTrack) bool {
        return self._enabled;
    }

    pub fn setEnabled(self: *MediaStreamTrack, enabled: bool) void {
        self._enabled = enabled;
    }

    // A destination node's track is never muted: there is no source that could
    // stall (measured false, and it stays false across stop()).
    pub fn getMuted(_: *const MediaStreamTrack) bool {
        return false;
    }

    pub fn getReadyState(self: *const MediaStreamTrack) []const u8 {
        return @tagName(self._ready_state);
    }

    pub fn getContentHint(self: *const MediaStreamTrack) []const u8 {
        return self._content_hint.label();
    }

    pub fn setContentHint(self: *MediaStreamTrack, hint: []const u8) void {
        if (hint.len == 0) {
            self._content_hint = .none;
            return;
        }
        if (std.meta.stringToEnum(ContentHint, hint)) |parsed| {
            if (parsed != .none) self._content_hint = parsed;
        }
    }

    // The same object every time (measured: track.stats === track.stats).
    pub fn getStats(self: *MediaStreamTrack, exec: *Execution) !*MediaStreamTrackAudioStats {
        if (self._stats) |existing| return existing;
        const created = try exec._factory.create(MediaStreamTrackAudioStats{});
        self._stats = created;
        return created;
    }

    // MediaTrackConstraints' own members. A key outside this list is dropped by
    // the dictionary conversion before applyConstraints ever sees it, so it
    // cannot overconstrain anything.
    const CONSTRAINT_MEMBERS = [_][]const u8{
        "advanced",         "autoGainControl", "channelCount",   "deviceId",
        "echoCancellation", "groupId",         "latency",        "noiseSuppression",
        "sampleRate",       "sampleSize",      "voiceIsolation",
    };

    // No constraint can be satisfied, because nothing here is configurable. An
    // empty set resolves and any non-empty one rejects, which is what Chrome
    // does for a WebAudio-backed track (measured — `{channelCount: 1}` rejects
    // even though the track already has two channels).
    pub fn applyConstraints(_: *MediaStreamTrack, constraints: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        const given = constraints orelse return local.resolvePromise({});
        if (given.isNullOrUndefined() or !given.isObject()) {
            return local.resolvePromise({});
        }
        const object = given.toObject();
        var constrained = false;
        for (CONSTRAINT_MEMBERS) |member| {
            const value = try object.get(member);
            if (!value.isUndefined()) {
                constrained = true;
                break;
            }
        }
        if (!constrained) {
            return local.resolvePromise({});
        }
        // A real OverconstrainedError, not a DOMException that merely calls
        // itself one: now that the interface exists, `err instanceof
        // OverconstrainedError` has to hold, and it reports which constraint
        // failed the way Chrome does.
        var resolver = local.createPromiseResolver();
        resolver.reject(
            "MediaStreamTrack.applyConstraints",
            try OverconstrainedError.create("", "Cannot satisfy constraints", exec.page),
        );
        return resolver.promise();
    }

    // Chrome reports a *new* object each call, with the members in this order.
    pub fn getSettings(self: *const MediaStreamTrack) Settings {
        return .{
            .channelCount = self._channel_count,
            .deviceId = self._device_id,
            .sampleRate = self._sample_rate,
        };
    }

    pub const Settings = struct {
        channelCount: u32,
        deviceId: [45]u8,
        // Chrome's WebAudio track reports a 10 ms buffer and 16-bit samples.
        latency: f64 = 0.01,
        sampleRate: f64,
        sampleSize: u32 = 16,
    };

    pub fn getCapabilities(self: *const MediaStreamTrack) Capabilities {
        return .{ .deviceId = self._device_id };
    }

    // Every boolean capability is a one-element sequence holding false: the
    // three processing stages a microphone would offer are not available on a
    // WebAudio track (measured, including the key order).
    pub const Capabilities = struct {
        autoGainControl: [1]bool = .{false},
        deviceId: [45]u8,
        echoCancellation: [1]bool = .{false},
        noiseSuppression: [1]bool = .{false},
        sampleSize: struct { max: u32 = 16, min: u32 = 16 } = .{},
        voiceIsolation: [1]bool = .{false},
    };

    // Empty, because applyConstraints never accepts anything to remember.
    pub fn getConstraints(_: *const MediaStreamTrack) struct {} {
        return .{};
    }

    // Idempotent, and it does *not* fire `ended` — that event belongs to a
    // capture source ending the track, not to the page asking for it (measured:
    // an onended handler set beforehand never runs). `enabled` is left alone.
    pub fn stop(self: *MediaStreamTrack) void {
        self._ready_state = .ended;
    }

    pub fn getCaptureHandle(_: *const MediaStreamTrack) ?js.Value {
        return null;
    }

    const mute = handlerAccessors(MediaStreamTrack, "_on_mute");
    const unmute = handlerAccessors(MediaStreamTrack, "_on_unmute");
    const ended = handlerAccessors(MediaStreamTrack, "_on_ended");
    const capture_handle_change = handlerAccessors(MediaStreamTrack, "_on_capture_handle_change");

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamTrack);

        pub const Meta = struct {
            pub const name = "MediaStreamTrack";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's prototype order, which is not alphabetical and puts
        // `oncapturehandlechange` and `getCaptureHandle` after `stop`.
        pub const kind = bridge.accessor(MediaStreamTrack.getKind, null, .{});
        pub const id = bridge.accessor(MediaStreamTrack.getId, null, .{});
        pub const label = bridge.accessor(MediaStreamTrack.getLabel, null, .{});
        pub const enabled = bridge.accessor(MediaStreamTrack.getEnabled, MediaStreamTrack.setEnabled, .{});
        pub const muted = bridge.accessor(MediaStreamTrack.getMuted, null, .{});
        pub const onmute = bridge.accessor(MediaStreamTrack.mute.get, MediaStreamTrack.mute.set, .{});
        pub const onunmute = bridge.accessor(MediaStreamTrack.unmute.get, MediaStreamTrack.unmute.set, .{});
        pub const readyState = bridge.accessor(MediaStreamTrack.getReadyState, null, .{});
        pub const onended = bridge.accessor(MediaStreamTrack.ended.get, MediaStreamTrack.ended.set, .{});
        pub const stats = bridge.accessor(MediaStreamTrack.getStats, null, .{});
        pub const contentHint = bridge.accessor(MediaStreamTrack.getContentHint, MediaStreamTrack.setContentHint, .{});
        pub const applyConstraints = bridge.function(MediaStreamTrack.applyConstraints, .{ .arity = 0 });
        pub const clone = bridge.function(MediaStreamTrack.clone, .{ .arity = 0 });
        pub const getCapabilities = bridge.function(MediaStreamTrack.getCapabilities, .{ .arity = 0 });
        pub const getConstraints = bridge.function(MediaStreamTrack.getConstraints, .{ .arity = 0 });
        pub const getSettings = bridge.function(MediaStreamTrack.getSettings, .{ .arity = 0 });
        pub const stop = bridge.function(MediaStreamTrack.stop, .{ .arity = 0 });
        pub const oncapturehandlechange = bridge.accessor(MediaStreamTrack.capture_handle_change.get, MediaStreamTrack.capture_handle_change.set, .{});
        pub const getCaptureHandle = bridge.function(MediaStreamTrack.getCaptureHandle, .{ .arity = 0, .null_as_undefined = false });
    };
};

// ---------------------------------------------------------------------------
// MediaStreamTrackAudioStats
// ---------------------------------------------------------------------------

/// MediaStreamTrack.stats. Every counter is zero, and stays zero after the
/// track is stopped — measured, and unsurprising for a track nothing ever pulled
/// a frame from. Unlike AudioPlaybackStats' toJSON, the contents here *are*
/// measured: JSON.stringify(track.stats) reports exactly these eight members in
/// this order.
pub const MediaStreamTrackAudioStats = struct {
    _pad: bool = false,

    fn zero(_: *const MediaStreamTrackAudioStats) f64 {
        return 0;
    }

    fn zeroFrames(_: *const MediaStreamTrackAudioStats) u32 {
        return 0;
    }

    pub fn resetLatency(_: *MediaStreamTrackAudioStats) void {}

    pub fn toJSON(_: *const MediaStreamTrackAudioStats) Json {
        return .{};
    }

    pub const Json = struct {
        deliveredFrames: u32 = 0,
        deliveredFramesDuration: f64 = 0,
        totalFrames: u32 = 0,
        totalFramesDuration: f64 = 0,
        latency: f64 = 0,
        averageLatency: f64 = 0,
        minimumLatency: f64 = 0,
        maximumLatency: f64 = 0,
    };

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamTrackAudioStats);

        pub const Meta = struct {
            pub const name = "MediaStreamTrackAudioStats";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const deliveredFrames = bridge.accessor(MediaStreamTrackAudioStats.zeroFrames, null, .{});
        pub const deliveredFramesDuration = bridge.accessor(MediaStreamTrackAudioStats.zero, null, .{});
        pub const totalFrames = bridge.accessor(MediaStreamTrackAudioStats.zeroFrames, null, .{});
        pub const totalFramesDuration = bridge.accessor(MediaStreamTrackAudioStats.zero, null, .{});
        pub const latency = bridge.accessor(MediaStreamTrackAudioStats.zero, null, .{});
        pub const averageLatency = bridge.accessor(MediaStreamTrackAudioStats.zero, null, .{});
        pub const minimumLatency = bridge.accessor(MediaStreamTrackAudioStats.zero, null, .{});
        pub const maximumLatency = bridge.accessor(MediaStreamTrackAudioStats.zero, null, .{});
        pub const resetLatency = bridge.function(MediaStreamTrackAudioStats.resetLatency, .{ .arity = 0 });
        pub const toJSON = bridge.function(MediaStreamTrackAudioStats.toJSON, .{ .arity = 0 });
    };
};

// ---------------------------------------------------------------------------
// The two events
// ---------------------------------------------------------------------------

/// `addtrack` / `removetrack`. Constructible, with a required `track`; nothing
/// in this engine ever fires one, because no capture source owns a track.
pub const MediaStreamTrackEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _track: *MediaStreamTrack,

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*MediaStreamTrackEvent {
        const type_value = type_ orelse return typeError(
            "Failed to construct 'MediaStreamTrackEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return typeError(
            "Failed to construct 'MediaStreamTrackEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const typ = try type_value.toStringSlice();

        const member = if (options.isObject()) try options.toObject().get("track") else null;
        const value = member orelse return requiredTrack(exec);
        if (value.isUndefined()) return requiredTrack(exec);
        const track = value.toZig(*MediaStreamTrack) catch return typeError(
            "Failed to construct 'MediaStreamTrackEvent': Failed to read the 'track' property from " ++
                "'MediaStreamTrackEventInit': Failed to convert value to 'MediaStreamTrack'.",
            exec,
        );

        const event_options = try Event.optionsFromJs(options);
        const arena = try exec.getArena(.tiny, "MediaStreamTrackEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            MediaStreamTrackEvent{ ._proto = undefined, ._track = track },
        );
        Event.populatePrototypes(event, event_options, false);
        return event;
    }

    fn requiredTrack(exec: *const Execution) anyerror {
        return typeError(
            "Failed to construct 'MediaStreamTrackEvent': Failed to read the 'track' property from " ++
                "'MediaStreamTrackEventInit': Required member is undefined.",
            exec,
        );
    }

    pub fn asEvent(self: *MediaStreamTrackEvent) *Event {
        return self._proto;
    }

    pub fn getTrack(self: *const MediaStreamTrackEvent) *MediaStreamTrack {
        return self._track;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamTrackEvent);

        pub const Meta = struct {
            pub const name = "MediaStreamTrackEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaStreamTrackEvent.constructor, .{ .arity = 2 });
        pub const track = bridge.accessor(MediaStreamTrackEvent.getTrack, null, .{});
    };
};

/// The legacy `addstream` / `removestream` event from the first WebRTC draft.
/// Chrome still ships it, its `stream` is *optional* (a missing member leaves it
/// null), and its arity is 1 rather than 2 — all measured.
pub const MediaStreamEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _stream: ?*MediaStream,

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*MediaStreamEvent {
        const type_value = type_ orelse return typeError(
            "Failed to construct 'MediaStreamEvent': 1 argument required, but only 0 present.",
            exec,
        );
        const typ = try type_value.toStringSlice();

        var stream: ?*MediaStream = null;
        if (options_) |options| {
            if (options.isObject()) {
                const member = try options.toObject().get("stream");
                if (!member.isNullOrUndefined()) {
                    stream = member.toZig(*MediaStream) catch return typeError(
                        "Failed to construct 'MediaStreamEvent': Failed to read the 'stream' property " ++
                            "from 'MediaStreamEventInit': Failed to convert value to 'MediaStream'.",
                        exec,
                    );
                }
            }
        }

        const event_options = try Event.optionsFromJs(options_);
        const arena = try exec.getArena(.tiny, "MediaStreamEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            MediaStreamEvent{ ._proto = undefined, ._stream = stream },
        );
        Event.populatePrototypes(event, event_options, false);
        return event;
    }

    pub fn asEvent(self: *MediaStreamEvent) *Event {
        return self._proto;
    }

    pub fn getStream(self: *const MediaStreamEvent) ?*MediaStream {
        return self._stream;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamEvent);

        pub const Meta = struct {
            pub const name = "MediaStreamEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaStreamEvent.constructor, .{ .arity = 1 });
        pub const stream = bridge.accessor(MediaStreamEvent.getStream, null, .{ .null_as_undefined = false });
    };
};

/// The error a failed constraint hands back. A DOMException subclass with one
/// extra member, and the only interface in this file whose constructor a page
/// can call. Measured: arity 1, name "OverconstrainedError", code 0, message
/// defaulting to "", and `String(e)` reading "OverconstrainedError: <message>".
pub const OverconstrainedError = struct {
    pub const Proto = DOMException;

    _proto: *DOMException,
    _constraint: []const u8,

    pub fn constructor(constraint: []const u8, message_: ?[]const u8, page: *Page) !*OverconstrainedError {
        return create(constraint, message_ orelse "", page);
    }

    pub fn create(constraint: []const u8, message: []const u8, page: *Page) !*OverconstrainedError {
        return page.factory.domException(
            DOMException.init(try page.frame_arena.dupe(u8, message), "OverconstrainedError"),
            OverconstrainedError{
                ._proto = undefined,
                ._constraint = try page.frame_arena.dupe(u8, constraint),
            },
        );
    }

    pub fn getConstraint(self: *const OverconstrainedError) []const u8 {
        return self._constraint;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OverconstrainedError);

        pub const Meta = struct {
            pub const name = "OverconstrainedError";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(OverconstrainedError.constructor, .{ .arity = 1 });
        pub const constraint = bridge.accessor(OverconstrainedError.getConstraint, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaStream" {
    try testing.htmlRunner("media/streams.html", .{});
}
