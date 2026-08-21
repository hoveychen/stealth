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
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        MediaStream,
        MediaStreamTrack,
        OverconstrainedError,
        MediaStreamTrackAudioStats,
        MediaStreamTrackVideoStats,
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
        pub const onaddtrack = bridge.accessor(handlerProperty(MediaStream, .onaddtrack).get, handlerProperty(MediaStream, .onaddtrack).set, .{});
        pub const onremovetrack = bridge.accessor(handlerProperty(MediaStream, .onremovetrack).get, handlerProperty(MediaStream, .onremovetrack).set, .{});
        pub const onactive = bridge.accessor(handlerProperty(MediaStream, .onactive).get, handlerProperty(MediaStream, .onactive).set, .{});
        pub const oninactive = bridge.accessor(handlerProperty(MediaStream, .oninactive).get, handlerProperty(MediaStream, .oninactive).set, .{});
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

    // Which subclass, if any, this track really is. A stream hands its tracks
    // out as plain `*MediaStreamTrack`, so without this a canvas track coming
    // back through getVideoTracks() would be wrapped as its base class and lose
    // both its brand and its `canvas` property.
    _type: Type = .generic,

    _id: [36]u8,

    // What the deviceId looks like depends on the source, so it is no longer a
    // fixed width: a WebAudio track carries "WebAudio-" plus a UUID (45
    // characters), a generator carries a bare UUID, and a canvas track carries
    // 88 characters of base64. All three measured.
    _device_id: []const u8,

    // Which of the three sources produced this track. It decides what
    // getSettings(), getCapabilities() and applyConstraints() answer, and
    // whether clone() keeps the deviceId -- Chrome's answers differ per source,
    // not just per kind.
    _source: Source = .web_audio,

    _kind: Kind = .audio,
    _label: []const u8,
    _enabled: bool = true,
    _ready_state: ReadyState = .live,
    _content_hint: ContentHint = .none,
    _channel_count: u32 = 2,
    _sample_rate: f64 = 48000,

    _stats: ?*MediaStreamTrackAudioStats = null,

    pub const Type = union(enum) {
        generic,
        generator: *@import("breakout_box.zig").MediaStreamTrackGenerator,
        canvas_capture: *@import("image_capture.zig").CanvasCaptureMediaStreamTrack,
    };

    pub const Kind = enum { audio, video };

    pub const ReadyState = enum { live, ended };

    /// Where the track's frames come from. Chrome reports a different settings
    /// and capabilities dictionary for each, and they are not just the audio
    /// set with video keys swapped in -- a canvas track carries sizes a
    /// generator has no notion of.
    pub const Source = union(enum) {
        /// MediaStreamAudioDestinationNode's track.
        web_audio,
        /// The breakout box's MediaStreamTrackGenerator.
        generator,
        /// canvas.captureStream(). The dimensions are the canvas' size *at the
        /// moment of capture*: resizing the canvas afterwards does not move a
        /// live track's settings or its capability ranges (measured).
        canvas: CanvasSource,

        pub const CanvasSource = struct {
            width: u32,
            height: u32,
            frame_rate: f64,

            /// A zero-area canvas is still capturable, but Chrome then omits
            /// width, height and aspectRatio from the settings rather than
            /// reporting zero, and clamps every capability range to 1.
            fn empty(self: CanvasSource) bool {
                return self.width == 0 or self.height == 0;
            }
        };
    };

    // The two vocabularies are disjoint, and a hint from the wrong one is
    // dropped rather than refused: setting "speech" on a video track leaves the
    // previous value in place (measured one value at a time, both kinds). The
    // spec's "speech-recognition" is in neither.
    pub const ContentHint = enum {
        none,
        speech,
        music,
        motion,
        detail,
        text,

        fn label(self: ContentHint) []const u8 {
            return switch (self) {
                .none => "",
                .speech => "speech",
                .music => "music",
                .motion => "motion",
                .detail => "detail",
                .text => "text",
            };
        }

        fn allowedFor(self: ContentHint, kind: Kind) bool {
            return switch (self) {
                .none => true,
                .speech, .music => kind == .audio,
                .motion, .detail, .text => kind == .video,
            };
        }
    };

    pub fn create(label: []const u8, channel_count: u32, sample_rate: f64, exec: *Execution) !*MediaStreamTrack {
        var id: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&id);

        return exec._factory.eventTarget(MediaStreamTrack{
            ._proto = undefined,
            ._id = id,
            ._device_id = try webAudioDeviceId(exec),
            ._label = label,
            ._channel_count = channel_count,
            ._sample_rate = sample_rate,
        });
    }

    /// "WebAudio-" followed by a UUID, which is the form Chrome gives a track a
    /// MediaStreamAudioDestinationNode owns (measured: 45 characters, and
    /// getCapabilities().deviceId is the same string).
    pub fn webAudioDeviceId(exec: *Execution) ![]const u8 {
        const device_id = try exec.arena.alloc(u8, 45);
        @memcpy(device_id[0..9], "WebAudio-");
        @import("../../../id.zig").uuidv4(device_id[9..]);
        return device_id;
    }

    /// 64 random bytes in base64 -- 88 characters -- which is what a canvas
    /// capture track reports as both its deviceId and its label (measured).
    pub fn captureDeviceId(exec: *Execution) ![]const u8 {
        var raw: [64]u8 = undefined;
        lp.io.random(&raw);
        const encoder = std.base64.standard.Encoder;
        const out = try exec.arena.alloc(u8, encoder.calcSize(raw.len));
        return encoder.encode(out, &raw);
    }

    // A new track object with a new id, carrying the same label and settings.
    // Whether the deviceId comes along is per-source: a WebAudio clone gets a
    // fresh one, a capture clone keeps the original's (both measured, and the
    // difference is why this is not one rule).
    pub fn clone(self: *const MediaStreamTrack, exec: *Execution) !*MediaStreamTrack {
        // A canvas track clones as a canvas track: the copy keeps the brand and
        // the `canvas` back-reference (measured). `clone` lives on this
        // prototype rather than the subclass', so the dispatch has to happen
        // here.
        if (self._type == .canvas_capture) {
            const copy = try @import("image_capture.zig").CanvasCaptureMediaStreamTrack.cloneOf(self._type.canvas_capture, exec);
            return copy.asMediaStreamTrack();
        }

        var id: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&id);

        return exec._factory.eventTarget(MediaStreamTrack{
            ._proto = undefined,
            ._id = id,
            ._device_id = switch (self._source) {
                .web_audio => try webAudioDeviceId(exec),
                .generator, .canvas => self._device_id,
            },
            ._source = self._source,
            ._kind = self._kind,
            ._label = self._label,
            ._enabled = self._enabled,
            ._content_hint = self._content_hint,
            ._channel_count = self._channel_count,
            ._sample_rate = self._sample_rate,
        });
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
        const parsed = std.meta.stringToEnum(ContentHint, hint) orelse return;
        if (parsed != .none and parsed.allowedFor(self._kind)) {
            self._content_hint = parsed;
        }
    }

    // The same object every time (measured: track.stats === track.stats), and
    // null on a video track -- these counters are audio-only, so a canvas or
    // video-generator track has no object here at all rather than one full of
    // zeroes (measured).
    pub fn getStats(self: *MediaStreamTrack, exec: *Execution) !?*MediaStreamTrackAudioStats {
        if (self._kind == .video) return null;
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

    // No constraint can be satisfied on a WebAudio track, because nothing about
    // it is configurable: an empty set resolves and any non-empty one rejects
    // (measured — `{channelCount: 1}` rejects even though the track already has
    // two channels). A capture track is the other way round: it can be scaled,
    // so Chrome accepts constraints there and resolves.
    //
    // Known gap: Chrome then *remembers* what it accepted, and getConstraints()
    // reports back the members it recognised. This engine keeps nothing, so
    // getConstraints() stays empty on a capture track where Chrome would echo
    // `{"width":10}`.
    pub fn applyConstraints(self: *MediaStreamTrack, constraints: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        const given = constraints orelse return local.resolvePromise({});
        if (self._source != .web_audio) return local.resolvePromise({});
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
    // Which dictionary it is depends on the source, and the three barely
    // overlap: only deviceId is common to all of them.
    pub fn getSettings(self: *const MediaStreamTrack) Settings {
        return switch (self._source) {
            .web_audio => .{ .web_audio = .{
                .channelCount = self._channel_count,
                .deviceId = self._device_id,
                .sampleRate = self._sample_rate,
            } },
            // A generator has no device behind it, so it reports the bare
            // minimum: its deviceId plus the one member its kind implies.
            .generator => switch (self._kind) {
                .audio => .{ .generator_audio = .{ .deviceId = self._device_id } },
                .video => .{ .generator_video = .{ .deviceId = self._device_id } },
            },
            .canvas => |canvas| if (canvas.empty()) .{ .canvas_empty = .{
                .deviceId = self._device_id,
                .frameRate = canvas.frame_rate,
            } } else .{ .canvas = .{
                .aspectRatio = @as(f64, @floatFromInt(canvas.width)) / @as(f64, @floatFromInt(canvas.height)),
                .deviceId = self._device_id,
                .frameRate = canvas.frame_rate,
                .height = canvas.height,
                .width = canvas.width,
            } },
        };
    }

    pub const Settings = union(enum) {
        web_audio: WebAudio,
        generator_audio: GeneratorAudio,
        generator_video: GeneratorVideo,
        canvas: CanvasSettings,
        canvas_empty: CanvasEmpty,

        pub const WebAudio = struct {
            channelCount: u32,
            deviceId: []const u8,
            // Chrome's WebAudio track reports a 10 ms buffer and 16-bit samples.
            latency: f64 = 0.01,
            sampleRate: f64,
            sampleSize: u32 = 16,
        };

        pub const GeneratorAudio = struct {
            deviceId: []const u8,
            sampleSize: u32 = 16,
        };

        pub const GeneratorVideo = struct {
            deviceId: []const u8,
            resizeMode: []const u8 = "none",
        };

        pub const CanvasSettings = struct {
            aspectRatio: f64,
            deviceId: []const u8,
            frameRate: f64,
            height: u32,
            resizeMode: []const u8 = "none",
            width: u32,
        };

        // Zero area: the three size members are gone rather than zero.
        pub const CanvasEmpty = struct {
            deviceId: []const u8,
            frameRate: f64,
            resizeMode: []const u8 = "none",
        };
    };

    pub fn getCapabilities(self: *const MediaStreamTrack) Capabilities {
        return switch (self._source) {
            .web_audio => .{ .web_audio = .{ .deviceId = self._device_id } },
            // A generator's capabilities name no device at all: deviceId is the
            // empty string, not the one its settings report (measured).
            .generator => switch (self._kind) {
                .audio => .{ .generator_audio = .{} },
                .video => .{ .generator_video = .{} },
            },
            .canvas => |canvas| {
                // The ranges are the captured size, and a zero-area canvas
                // clamps every one of them to 1 rather than to 0.
                const width = @max(canvas.width, 1);
                const height = @max(canvas.height, 1);
                const widthf: f64 = @floatFromInt(width);
                const heightf: f64 = @floatFromInt(height);
                return .{
                    .canvas = .{
                        // Widest and narrowest a crop-and-scale could reach: the
                        // full width over one row, and one column over the full
                        // height.
                        .aspectRatio = .{ .max = widthf, .min = 1 / heightf },
                        .deviceId = self._device_id,
                        .frameRate = .{ .max = 60, .min = 0 },
                        .height = .{ .max = height, .min = 1 },
                        .width = .{ .max = width, .min = 1 },
                    },
                };
            },
        };
    }

    pub const Capabilities = union(enum) {
        web_audio: WebAudio,
        generator_audio: GeneratorAudio,
        generator_video: GeneratorVideo,
        canvas: CanvasCapabilities,

        // Every boolean capability is a one-element sequence holding false: the
        // three processing stages a microphone would offer are not available on
        // a WebAudio track (measured, including the key order).
        pub const WebAudio = struct {
            autoGainControl: [1]bool = .{false},
            deviceId: []const u8,
            echoCancellation: [1]bool = .{false},
            noiseSuppression: [1]bool = .{false},
            sampleSize: struct { max: u32 = 16, min: u32 = 16 } = .{},
            voiceIsolation: [1]bool = .{false},
        };

        // The same members as WebAudio's, but every sequence empty: a generator
        // offers no processing stage at all, not even one it has turned off.
        pub const GeneratorAudio = struct {
            autoGainControl: [0]bool = .{},
            deviceId: []const u8 = "",
            echoCancellation: [0]bool = .{},
            noiseSuppression: [0]bool = .{},
            voiceIsolation: [0]bool = .{},
        };

        pub const GeneratorVideo = struct {
            deviceId: []const u8 = "",
            facingMode: [0][]const u8 = .{},
            resizeMode: [2][]const u8 = .{ "none", "crop-and-scale" },
        };

        pub const Range = struct { max: f64, min: f64 };
        pub const IntRange = struct { max: u32, min: u32 };

        pub const CanvasCapabilities = struct {
            aspectRatio: Range,
            deviceId: []const u8,
            facingMode: [0][]const u8 = .{},
            frameRate: Range,
            height: IntRange,
            resizeMode: [2][]const u8 = .{ "none", "crop-and-scale" },
            width: IntRange,
        };
    };

    // Empty: applyConstraints keeps nothing, on any source. See the note there
    // for what Chrome would echo back on a capture track.
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
        pub const onmute = bridge.accessor(handlerProperty(MediaStreamTrack, .onmute).get, handlerProperty(MediaStreamTrack, .onmute).set, .{});
        pub const onunmute = bridge.accessor(handlerProperty(MediaStreamTrack, .onunmute).get, handlerProperty(MediaStreamTrack, .onunmute).set, .{});
        pub const readyState = bridge.accessor(MediaStreamTrack.getReadyState, null, .{});
        pub const onended = bridge.accessor(handlerProperty(MediaStreamTrack, .onended).get, handlerProperty(MediaStreamTrack, .onended).set, .{});
        pub const stats = bridge.accessor(MediaStreamTrack.getStats, null, .{ .null_as_undefined = false });
        pub const contentHint = bridge.accessor(MediaStreamTrack.getContentHint, MediaStreamTrack.setContentHint, .{});
        pub const applyConstraints = bridge.function(MediaStreamTrack.applyConstraints, .{ .arity = 0 });
        pub const clone = bridge.function(MediaStreamTrack.clone, .{ .arity = 0 });
        pub const getCapabilities = bridge.function(MediaStreamTrack.getCapabilities, .{ .arity = 0 });
        pub const getConstraints = bridge.function(MediaStreamTrack.getConstraints, .{ .arity = 0 });
        pub const getSettings = bridge.function(MediaStreamTrack.getSettings, .{ .arity = 0 });
        pub const stop = bridge.function(MediaStreamTrack.stop, .{ .arity = 0 });
        pub const oncapturehandlechange = bridge.accessor(handlerProperty(MediaStreamTrack, .oncapturehandlechange).get, handlerProperty(MediaStreamTrack, .oncapturehandlechange).set, .{});
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

/// `track.stats` on a *video* track: three frame counters and a toJSON. Same
/// stance as its audio sibling -- no capture source owns a track here, so
/// nothing hands one out and every counter is zero. Illegal to construct
/// (measured), so the prototype is the whole surface a page can read.
pub const MediaStreamTrackVideoStats = struct {
    _pad: bool = false,

    fn zeroFrames(_: *const MediaStreamTrackVideoStats) u32 {
        return 0;
    }

    pub fn toJSON(_: *const MediaStreamTrackVideoStats) Json {
        return .{};
    }

    pub const Json = struct {
        deliveredFrames: u32 = 0,
        discardedFrames: u32 = 0,
        totalFrames: u32 = 0,
    };

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamTrackVideoStats);

        pub const Meta = struct {
            pub const name = "MediaStreamTrackVideoStats";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const V = MediaStreamTrackVideoStats;

        pub const deliveredFrames = bridge.accessor(V.zeroFrames, null, .{});
        pub const discardedFrames = bridge.accessor(V.zeroFrames, null, .{});
        pub const totalFrames = bridge.accessor(V.zeroFrames, null, .{});
        pub const toJSON = bridge.function(V.toJSON, .{ .arity = 0 });
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
