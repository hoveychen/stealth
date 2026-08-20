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

//! The "breakout box": MediaStreamTrackGenerator turns a stream of frames into
//! a media track, MediaStreamTrackProcessor turns a track back into a stream of
//! frames.
//!
//! Nothing here produces frames, so both stay empty -- but both are
//! constructible, so the parts a page can actually exercise are real: the
//! generator is a genuine MediaStreamTrack subclass with a live WritableStream
//! on it, the processor hands back a ReadableStream and two counters at zero,
//! and each keeps the same stream object across reads because Chrome's do.
//!
//! The interesting part is the argument. Both constructors are overloaded --
//! an init dictionary, or the bare value that dictionary's one required member
//! would have carried -- and Chrome picks by whether the argument is an object.
//! That gives three distinct refusals rather than one, all measured:
//!
//!   new MediaStreamTrackGenerator(5)     -> Invalid track generator kind
//!       (a primitive is read as the kind string, so 5 becomes the kind "5")
//!   new MediaStreamTrackGenerator({})    -> Required member is undefined
//!   new MediaStreamTrackGenerator(null)  -> is not of type '...Init'
//!
//! The generator's *inherited* MediaStreamTrack members answer a generator's
//! values rather than this engine's WebAudio ones: `MediaStreamTrack._source`
//! carries which of the three sources made a track, and the settings and
//! capabilities dictionaries branch on it (see streams.zig). A generator
//! reports only its deviceId plus the one member its kind implies, and its
//! capabilities name no device at all -- deviceId is the empty string there,
//! not the UUID its settings report.
//!
//! Chrome 150, headed, over http://localhost (win57-chrome.json, p66;
//! win61/win62-chrome.json for the settings and capabilities).

const std = @import("std");

const js = @import("../../js/js.zig");

const dictionary = @import("../dictionary.zig");
const streams = @import("streams.zig");
const EventTarget = @import("../EventTarget.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");

const MediaStreamTrack = streams.MediaStreamTrack;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ MediaStreamTrackGenerator, MediaStreamTrackProcessor };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    return dictionary.throwTypeError(message, exec);
}

/// A track a page writes frames into.
pub const MediaStreamTrackGenerator = struct {
    pub const Proto = MediaStreamTrack;

    _proto: *MediaStreamTrack,
    /// Created with the generator and kept: `g.writable === g.writable` is
    /// true, and it survives `stop()` (measured).
    _writable: *WritableStream,

    const Init = dictionary.Reader("MediaStreamTrackGenerator", "MediaStreamTrackGeneratorInit");

    pub fn constructor(init_: ?js.Value, exec: *Execution) !*MediaStreamTrackGenerator {
        const value = init_ orelse return throwTypeError(
            "Failed to construct 'MediaStreamTrackGenerator': 1 argument required, but only 0 present.",
            exec,
        );

        // An object goes down the dictionary overload, everything else -- null
        // included, which is why the null check is separate -- down the bare
        // kind one.
        const kind = if (value.isObject()) blk: {
            const init = try Init.readRequired(value, exec);
            const member = try init.required("kind", exec);
            break :blk try member.toStringSliceWithAlloc(exec.call_arena);
        } else if (value.isNull()) {
            // readRequired refuses null outright, which is the message Chrome
            // gives here; it always throws, so nothing comes back from it.
            _ = try Init.readRequired(value, exec);
            return error.JsException;
        } else try value.toStringSliceWithAlloc(exec.call_arena);

        const parsed = std.meta.stringToEnum(MediaStreamTrack.Kind, kind) orelse return throwTypeError(
            // No trailing full stop: Chrome's own wording, and not the WebIDL
            // enum message, because `kind` is a plain DOMString here.
            "Failed to construct 'MediaStreamTrackGenerator': Invalid track generator kind",
            exec,
        );

        // Three levels have to sit contiguously in one allocation, so the
        // whole chain is built at once rather than the base being made first.
        var id: [36]u8 = undefined;
        @import("../../../id.zig").uuidv4(&id);

        // A generator carries *two* UUIDs: `id`, and a second one that is both
        // its label and its deviceId (measured: id !== label, but
        // getSettings().deviceId === label).
        const label = try exec.arena.alloc(u8, 36);
        @import("../../../id.zig").uuidv4(label);

        const self = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            MediaStreamTrack{
                ._proto = undefined,
                ._id = id,
                ._device_id = label,
                ._label = label,
                ._source = .generator,
                ._kind = parsed,
            },
            MediaStreamTrackGenerator{
                ._proto = undefined,
                ._writable = try WritableStream.init(null, exec),
            },
        });
        self._proto._type = .{ .generator = self };
        self._proto._proto._type = .media_stream_track_generator;
        return self;
    }

    pub fn asMediaStreamTrack(self: *MediaStreamTrackGenerator) *MediaStreamTrack {
        return self._proto;
    }

    pub fn getWritable(self: *const MediaStreamTrackGenerator) *WritableStream {
        return self._writable;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamTrackGenerator);

        pub const Meta = struct {
            pub const name = "MediaStreamTrackGenerator";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = MediaStreamTrack;

        pub const constructor = bridge.constructor(MediaStreamTrackGenerator.constructor, .{ .arity = 1 });
        pub const writable = bridge.accessor(MediaStreamTrackGenerator.getWritable, null, .{});
    };
};

/// A track a page reads frames out of.
pub const MediaStreamTrackProcessor = struct {
    _track: *MediaStreamTrack,
    /// Same object on every read, like the generator's sink.
    _readable: *ReadableStream,

    const Init = dictionary.Reader("MediaStreamTrackProcessor", "MediaStreamTrackProcessorInit");

    pub fn constructor(init_: ?js.Value, exec: *const Execution) !*MediaStreamTrackProcessor {
        const value = init_ orelse return throwTypeError(
            "Failed to construct 'MediaStreamTrackProcessor': 1 argument required, but only 0 present.",
            exec,
        );

        const track = if (value.isObject()) blk: {
            // A MediaStreamTrack is an object too, so the bare-track overload
            // is tried first and only a miss falls through to the dictionary.
            if (value.toZig(*MediaStreamTrack)) |direct| {
                break :blk direct;
            } else |_| {}
            const init = try Init.readRequired(value, exec);
            break :blk try init.interfaceMember("track", MediaStreamTrack, "MediaStreamTrack", exec);
        } else if (value.isNull()) {
            _ = try Init.readRequired(value, exec);
            return error.JsException;
        } else return throwTypeError(
            // Neither overload can take a primitive, and Chrome says so in
            // those terms rather than blaming a member (measured).
            "Failed to construct 'MediaStreamTrackProcessor': Overload resolution failed.",
            exec,
        );

        return exec._factory.create(MediaStreamTrackProcessor{
            ._track = track,
            ._readable = try ReadableStream.init(null, null, exec),
        });
    }

    pub fn getReadable(self: *const MediaStreamTrackProcessor) *ReadableStream {
        return self._readable;
    }

    /// Zero until something reads a frame out, and nothing ever does.
    pub fn getTotalFrames(_: *const MediaStreamTrackProcessor) u32 {
        return 0;
    }

    pub fn getDiscardedFrames(_: *const MediaStreamTrackProcessor) u32 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaStreamTrackProcessor);

        pub const Meta = struct {
            pub const name = "MediaStreamTrackProcessor";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaStreamTrackProcessor.constructor, .{ .arity = 1 });
        pub const readable = bridge.accessor(MediaStreamTrackProcessor.getReadable, null, .{});
        pub const totalFrames = bridge.accessor(MediaStreamTrackProcessor.getTotalFrames, null, .{});
        pub const discardedFrames = bridge.accessor(MediaStreamTrackProcessor.getDiscardedFrames, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: BreakoutBox" {
    try testing.htmlRunner("media/breakout_box.html", .{});
}
