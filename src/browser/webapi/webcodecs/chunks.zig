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

// The three sample containers: EncodedVideoChunk, EncodedAudioChunk and
// AudioData. All three are plain wrappers around bytes a page handed in, so
// unlike the codecs that consume them there is nothing here that needs a codec
// to exist -- a page can build one, read every accessor back and copy the bytes
// out, and this reproduces all of it.
//
// Measured on a headed Chrome 150 with probe-win43.js and probe-win45.js
// (win45-chrome.json). What that turned up beyond the shapes:
//
//   * The two chunks are the same dictionary read twice over, but their
//     *prototypes* are not in the same order: byteLength lands before duration
//     on the audio one and after it on the video one.
//   * `duration` is `unsigned long long` rather than nullable: absent reads
//     back null, but an explicit `{duration: null}` is 0.
//   * AudioData's bounds refusals are bare RangeErrors, not TypeErrors, and
//     they quote the numbers -- including Chrome's own untidy wording, "Frame
//     count exceeds available_frames frames".
//   * A closed AudioData zeroes everything except its timestamp, which is what
//     a closed VideoFrame does too.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const frames = @import("frames.zig");

const Execution = js.Execution;

/// The `[AllowShared] ArrayBuffer or [AllowShared] ArrayBufferView` union,
/// spelled the way Chrome spells it when nothing in it converts.
const BUFFER_SOURCE = "([AllowShared] ArrayBuffer or [AllowShared] ArrayBufferView)";

/// Which order the four getters come in. The only thing that separates
/// EncodedVideoChunk from EncodedAudioChunk besides the brand.
const Order = enum { video, audio };

fn Chunk(comptime interface: []const u8, comptime order: Order) type {
    return struct {
        const Self = @This();

        const PREFIX = "Failed to construct '" ++ interface ++ "': ";
        const COPY_TO = "Failed to execute 'copyTo' on '" ++ interface ++ "': ";
        const Reader = dictionary.Reader(interface, interface ++ "Init");

        _type: []const u8,
        _timestamp: i64,
        _duration: ?u64,
        _data: []const u8,

        pub fn constructor(init_: js.Value, exec: *const Execution) !*Self {
            const init = try Reader.readRequired(init_, exec);

            // Alphabetical, which is the order Chrome reads them in: `{}`
            // complains about data, `{data}` about timestamp, and
            // `{data, timestamp}` about type.
            const data = frames.bufferSource(try init.required("data", exec)) orelse
                return Reader.notOfType("data", BUFFER_SOURCE, exec);
            const duration = try init.enforcedInt("duration", u64, "unsigned long long", exec);
            const timestamp = try init.enforcedInt("timestamp", i64, "long long", exec) orelse
                return Reader.missingMember("timestamp", exec);
            const chunk_type = (try init.enumMember(
                "type",
                interface ++ "Type",
                &.{ "key", "delta" },
                null,
                exec,
            )) orelse return Reader.missingMember("type", exec);

            return exec._factory.create(Self{
                ._type = chunk_type,
                ._timestamp = timestamp,
                ._duration = duration,
                ._data = try exec.arena.dupe(u8, data),
            });
        }

        pub fn getType(self: *const Self) []const u8 {
            return self._type;
        }

        /// A Number, not a BigInt: see frames.VideoFrame.getTimestamp.
        pub fn getTimestamp(self: *const Self) f64 {
            return @floatFromInt(self._timestamp);
        }

        pub fn getDuration(self: *const Self) ?f64 {
            const duration = self._duration orelse return null;
            return @floatFromInt(duration);
        }

        pub fn getByteLength(self: *const Self) u32 {
            return @intCast(self._data.len);
        }

        /// Writes the bytes and answers undefined. A larger destination keeps
        /// whatever was past the end, and a view's own byte offset is honoured
        /// because that is what the conversion hands back.
        pub fn copyTo(self: *const Self, args: []js.Value, exec: *const Execution) !void {
            if (args.len == 0) {
                return dictionary.throwTypeError(COPY_TO ++ "1 argument required, but only 0 present.", exec);
            }
            const destination = frames.bufferSource(args[0]) orelse
                return dictionary.throwTypeError(
                    COPY_TO ++ "The provided value is not of type '" ++ BUFFER_SOURCE ++ "'.",
                    exec,
                );
            if (destination.len < self._data.len) {
                return dictionary.throwTypeError(COPY_TO ++ "destination is not large enough.", exec);
            }
            @memcpy(destination[0..self._data.len], self._data);
        }

        pub const JsApi = switch (order) {
            .video => struct {
                pub const bridge = js.Bridge(Self);

                pub const Meta = struct {
                    pub const name = interface;
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const constructor = bridge.constructor(Self.constructor, .{});
                pub const @"type" = bridge.accessor(Self.getType, null, .{});
                pub const timestamp = bridge.accessor(Self.getTimestamp, null, .{});
                pub const duration = bridge.accessor(Self.getDuration, null, .{});
                pub const byteLength = bridge.accessor(Self.getByteLength, null, .{});
                pub const copyTo = bridge.function(Self.copyTo, .{ .arity = 1 });
            },
            .audio => struct {
                pub const bridge = js.Bridge(Self);

                pub const Meta = struct {
                    pub const name = interface;
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const constructor = bridge.constructor(Self.constructor, .{});
                pub const @"type" = bridge.accessor(Self.getType, null, .{});
                pub const timestamp = bridge.accessor(Self.getTimestamp, null, .{});
                pub const byteLength = bridge.accessor(Self.getByteLength, null, .{});
                pub const duration = bridge.accessor(Self.getDuration, null, .{});
                pub const copyTo = bridge.function(Self.copyTo, .{ .arity = 1 });
            },
        };
    };
}

pub const EncodedVideoChunk = Chunk("EncodedVideoChunk", .video);
pub const EncodedAudioChunk = Chunk("EncodedAudioChunk", .audio);

/// An AudioSampleFormat: how wide a sample is, and whether the channels are
/// laid out one plane each or interleaved into one.
const SampleFormat = struct {
    name: []const u8,
    bytes: u32,
    planar: bool,
};

const SAMPLE_FORMATS = [_]SampleFormat{
    .{ .name = "u8", .bytes = 1, .planar = false },
    .{ .name = "s16", .bytes = 2, .planar = false },
    .{ .name = "s32", .bytes = 4, .planar = false },
    .{ .name = "f32", .bytes = 4, .planar = false },
    .{ .name = "u8-planar", .bytes = 1, .planar = true },
    .{ .name = "s16-planar", .bytes = 2, .planar = true },
    .{ .name = "s32-planar", .bytes = 4, .planar = true },
    .{ .name = "f32-planar", .bytes = 4, .planar = true },
};

const SAMPLE_FORMAT_NAMES = blk: {
    var names: [SAMPLE_FORMATS.len][]const u8 = undefined;
    for (SAMPLE_FORMATS, 0..) |format, i| {
        names[i] = format.name;
    }
    const frozen = names;
    break :blk frozen;
};

fn sampleFormatByName(name: []const u8) *const SampleFormat {
    for (&SAMPLE_FORMATS) |*format| {
        if (std.mem.eql(u8, format.name, name)) {
            return format;
        }
    }
    unreachable; // every name came out of SAMPLE_FORMAT_NAMES
}

pub const AudioData = struct {
    const PREFIX = "Failed to construct 'AudioData': ";

    /// Chrome's own limits, quoted in the refusal it throws outside them.
    const MIN_SAMPLE_RATE = 3000;
    const MAX_SAMPLE_RATE = 768000;

    _format: *const SampleFormat,
    _sample_rate: f64,
    _frames: u32,
    _channels: u32,
    _timestamp: i64,
    /// The samples exactly as they came in. Nothing here interprets them, so a
    /// copyTo that does not change format hands them straight back.
    _samples: []const u8,
    _closed: bool = false,

    pub fn constructor(init_: js.Value, exec: *const Execution) !*AudioData {
        const Reader = dictionary.Reader("AudioData", "AudioDataInit");
        const init = try Reader.readRequired(init_, exec);

        // Alphabetical: data, format, numberOfChannels, numberOfFrames,
        // sampleRate, timestamp.
        const data = frames.bufferSource(try init.required("data", exec)) orelse
            return Reader.notOfType("data", BUFFER_SOURCE, exec);
        const format_name = (try init.enumMember(
            "format",
            "AudioSampleFormat",
            &SAMPLE_FORMAT_NAMES,
            null,
            exec,
        )) orelse return Reader.missingMember("format", exec);
        const channels = try init.enforcedInt("numberOfChannels", u32, "unsigned long", exec) orelse
            return Reader.missingMember("numberOfChannels", exec);
        const frame_count = try init.enforcedInt("numberOfFrames", u32, "unsigned long", exec) orelse
            return Reader.missingMember("numberOfFrames", exec);
        const sample_rate = (try init.present("sampleRate")) orelse
            return Reader.missingMember("sampleRate", exec);
        const rate = try Reader.finite("sampleRate", sample_rate, exec);
        const timestamp = try init.enforcedInt("timestamp", i64, "long long", exec) orelse
            return Reader.missingMember("timestamp", exec);

        if (frame_count == 0) {
            return dictionary.throwTypeError(PREFIX ++ "numberOfFrames must be greater than 0.", exec);
        }
        if (channels == 0) {
            return dictionary.throwTypeError(PREFIX ++ "numberOfChannels must be greater than 0.", exec);
        }
        if (rate < MIN_SAMPLE_RATE or rate > MAX_SAMPLE_RATE) {
            return dictionary.throwDom("NotSupportedError", try std.fmt.allocPrint(
                exec.call_arena,
                PREFIX ++ "sampleRate is outside of supported implementation limits: need between {d} and {d}, received {d}.",
                .{ MIN_SAMPLE_RATE, MAX_SAMPLE_RATE, rate },
            ), exec);
        }

        const format = sampleFormatByName(format_name);
        const needed = frame_count * format.bytes * channels;
        if (data.len < needed) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                PREFIX ++ "data is too small: needs {d} bytes, received {d}.",
                .{ needed, data.len },
            ), exec);
        }

        return exec._factory.create(AudioData{
            ._format = format,
            ._sample_rate = rate,
            ._frames = frame_count,
            ._channels = channels,
            ._timestamp = timestamp,
            ._samples = try exec.arena.dupe(u8, data[0..needed]),
        });
    }

    pub fn getFormat(self: *const AudioData) ?[]const u8 {
        return if (self._closed) null else self._format.name;
    }

    pub fn getSampleRate(self: *const AudioData) f64 {
        return if (self._closed) 0 else self._sample_rate;
    }

    pub fn getNumberOfFrames(self: *const AudioData) u32 {
        return if (self._closed) 0 else self._frames;
    }

    pub fn getNumberOfChannels(self: *const AudioData) u32 {
        return if (self._closed) 0 else self._channels;
    }

    /// The frame count in microseconds, truncated (measured: 100 frames at
    /// 48000 is 2083, 1 frame at 44100 is 22).
    pub fn getDuration(self: *const AudioData) f64 {
        if (self._closed) {
            return 0;
        }
        return @trunc(@as(f64, @floatFromInt(self._frames)) * 1_000_000 / self._sample_rate);
    }

    /// Survives close(), like a VideoFrame's.
    pub fn getTimestamp(self: *const AudioData) f64 {
        return @floatFromInt(self._timestamp);
    }

    pub fn allocationSize(self: *const AudioData, args: []js.Value, exec: *const Execution) !u32 {
        if (self._closed) {
            return closedError("allocationSize", "AudioData is closed.", exec);
        }
        if (args.len == 0) {
            return dictionary.throwTypeError(
                "Failed to execute 'allocationSize' on 'AudioData': 1 argument required, but only 0 present.",
                exec,
            );
        }
        const plan = try self.copyPlan("allocationSize", args[0], exec);
        return plan.size;
    }

    pub fn clone(self: *const AudioData, exec: *const Execution) !*AudioData {
        if (self._closed) {
            return closedError("clone", "Cannot clone closed AudioData.", exec);
        }
        return exec._factory.create(AudioData{
            ._format = self._format,
            ._sample_rate = self._sample_rate,
            ._frames = self._frames,
            ._channels = self._channels,
            ._timestamp = self._timestamp,
            ._samples = self._samples,
        });
    }

    /// Idempotent.
    pub fn close(self: *AudioData) void {
        self._closed = true;
    }

    pub fn copyTo(self: *const AudioData, args: []js.Value, exec: *const Execution) !void {
        if (self._closed) {
            return closedError("copyTo", "Cannot copy closed AudioData.", exec);
        }
        if (args.len < 2) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to execute 'copyTo' on 'AudioData': 2 arguments required, but only {d} present.",
                .{args.len},
            ), exec);
        }
        const destination = frames.bufferSource(args[0]) orelse
            return dictionary.throwTypeError(
                "Failed to execute 'copyTo' on 'AudioData': The provided value is not of type '" ++
                    BUFFER_SOURCE ++ "'.",
                exec,
            );
        const plan = try self.copyPlan("copyTo", args[1], exec);
        if (destination.len < plan.size) {
            return dictionary.throwRangeError(
                "Failed to execute 'copyTo' on 'AudioData': destination is not large enough.",
                exec,
            );
        }
        @memset(destination[0..plan.size], 0);
        // A format change would mean converting samples, which nothing here
        // has any use for; the plane is copied verbatim when it is the format
        // the data already is, and left zeroed otherwise.
        if (plan.format != self._format) {
            return;
        }
        const from = plan.offset;
        if (from + plan.size <= self._samples.len) {
            @memcpy(destination[0..plan.size], self._samples[from..][0..plan.size]);
        }
    }

    const CopyPlan = struct {
        size: u32,
        offset: u32,
        format: *const SampleFormat,
    };

    /// The shared body of allocationSize and copyTo. Every bound it checks is a
    /// RangeError rather than a TypeError, and the messages quote the numbers.
    fn copyPlan(
        self: *const AudioData,
        comptime method: []const u8,
        options_: js.Value,
        exec: *const Execution,
    ) !CopyPlan {
        const Reader = dictionary.MethodReader("AudioData", method, "AudioDataCopyToOptions");
        const E = "Failed to execute '" ++ method ++ "' on 'AudioData': ";
        const options = try Reader.read(options_, exec);

        const plane_index = try options.enforcedInt("planeIndex", u32, "unsigned long", exec) orelse
            return Reader.missingMember("planeIndex", exec);
        const frame_offset = (try options.enforcedInt("frameOffset", u32, "unsigned long", exec)) orelse 0;
        const frame_count = try options.enforcedInt("frameCount", u32, "unsigned long", exec);
        const format_name = try options.enumMember(
            "format",
            "AudioSampleFormat",
            &SAMPLE_FORMAT_NAMES,
            self._format.name,
            exec,
        );

        // planeIndex is counted against the format the data *is*, not the one
        // the copy asks for: an interleaved AudioData has one plane however it
        // is read out.
        const planes: u32 = if (self._format.planar) self._channels else 1;
        if (plane_index >= planes) {
            return dictionary.throwRangeError(E ++ "Invalid planeIndex.", exec);
        }
        if (frame_offset >= self._frames) {
            return dictionary.throwRangeError(try std.fmt.allocPrint(
                exec.call_arena,
                E ++ "Frame offset exceeds total frames ({d} >= {d}).",
                .{ frame_offset, self._frames },
            ), exec);
        }
        const available = self._frames - frame_offset;
        const count = frame_count orelse available;
        if (count > available) {
            // Chrome's wording, "available_frames" and all.
            return dictionary.throwRangeError(try std.fmt.allocPrint(
                exec.call_arena,
                E ++ "Frame count exceeds available_frames frames ({d} > {d}).",
                .{ count, self._frames },
            ), exec);
        }

        const format = sampleFormatByName(format_name.?);
        const stride: u32 = if (format.planar) format.bytes else format.bytes * self._channels;
        const source_stride: u32 = if (self._format.planar)
            self._format.bytes
        else
            self._format.bytes * self._channels;
        return .{
            .size = count * stride,
            .offset = plane_index * self._frames * source_stride + frame_offset * source_stride,
            .format = format,
        };
    }

    fn closedError(comptime method: []const u8, comptime message: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwDom(
            "InvalidStateError",
            "Failed to execute '" ++ method ++ "' on 'AudioData': " ++ message,
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioData);

        pub const Meta = struct {
            pub const name = "AudioData";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(AudioData.constructor, .{});
        pub const format = bridge.accessor(AudioData.getFormat, null, .{});
        pub const sampleRate = bridge.accessor(AudioData.getSampleRate, null, .{});
        pub const numberOfFrames = bridge.accessor(AudioData.getNumberOfFrames, null, .{});
        pub const numberOfChannels = bridge.accessor(AudioData.getNumberOfChannels, null, .{});
        pub const duration = bridge.accessor(AudioData.getDuration, null, .{});
        pub const timestamp = bridge.accessor(AudioData.getTimestamp, null, .{});
        pub const allocationSize = bridge.function(AudioData.allocationSize, .{ .arity = 1 });
        pub const clone = bridge.function(AudioData.clone, .{});
        pub const close = bridge.function(AudioData.close, .{});
        pub const copyTo = bridge.function(AudioData.copyTo, .{ .arity = 2 });
    };
};

pub fn registerTypes() []const type {
    return &.{ EncodedVideoChunk, EncodedAudioChunk, AudioData };
}

const testing = @import("../../../testing.zig");
test "WebApi: WebCodecs chunks" {
    try testing.htmlRunner("webcodecs/chunks.html", .{});
}
