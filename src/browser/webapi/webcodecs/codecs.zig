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

// VideoDecoder, VideoEncoder, AudioDecoder and AudioEncoder: four EventTargets
// over the same state machine, differing in two prototype names and in which
// sample container they take. Nothing here codes anything -- there is no codec
// behind them -- but a detector never gets that far: what it reads is the
// state machine, the refusal wording, and above all the codec matrix that
// `isConfigSupported` exposes, which is machine-specific and therefore
// fingerprintable.
//
// Measured on Chrome 150 (macOS) with probe-win43/46/46b/46c/48/49; see
// win46-findings.md. The parts worth knowing before reading on:
//
//   * `configure()` refuses a *malformed* config synchronously and leaves the
//     state alone. A config that is well-formed but names a codec nothing
//     supports is accepted, leaves state at 'configured', and only on a later
//     task fires the error callback and turns the state to 'closed'.
//   * `close()` is NOT idempotent -- a second one throws -- which is the
//     opposite of VideoFrame's and AudioData's.
//   * The role quirk: `configure()` after `close()` names 'decode' on both
//     decoders and 'configure' on both encoders. A Blink slip, transcribed.
//   * `isConfigSupported` never throws synchronously. Every failure, down to
//     the argument count, comes back as a rejection.
//   * The echo it resolves is the input with the defaults filled in, in
//     alphabetical order, and an unrecognised member dropped.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const frames = @import("frames.zig");
const chunks = @import("chunks.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

/// As `handlerProperty`, for a property whose setter takes a non-callable and
/// stores null rather than refusing it: `ondequeue = 7` reads back null (measured).
fn handlerPropertyLenient(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.lenientAccessors(T, which);
}

const log = lp.log;
const Execution = js.Execution;
const throwTypeError = dictionary.throwTypeError;
const throwDom = dictionary.throwDom;

/// Which of the four. Everything that varies between them is a switch on this.
const Role = enum {
    video_decoder,
    video_encoder,
    audio_decoder,
    audio_encoder,

    fn interface(comptime self: Role) []const u8 {
        return switch (self) {
            .video_decoder => "VideoDecoder",
            .video_encoder => "VideoEncoder",
            .audio_decoder => "AudioDecoder",
            .audio_encoder => "AudioEncoder",
        };
    }

    fn decoder(comptime self: Role) bool {
        return self == .video_decoder or self == .audio_decoder;
    }

    fn video(comptime self: Role) bool {
        return self == .video_decoder or self == .video_encoder;
    }

    /// The verb its one working method is spelled with.
    fn verb(comptime self: Role) []const u8 {
        return if (self.decoder()) "decode" else "encode";
    }

    /// What it takes: a chunk to decode, a frame or samples to encode.
    fn Input(comptime self: Role) type {
        return switch (self) {
            .video_decoder => chunks.EncodedVideoChunk,
            .video_encoder => frames.VideoFrame,
            .audio_decoder => chunks.EncodedAudioChunk,
            .audio_encoder => chunks.AudioData,
        };
    }

    fn inputName(comptime self: Role) []const u8 {
        return switch (self) {
            .video_decoder => "EncodedVideoChunk",
            .video_encoder => "VideoFrame",
            .audio_decoder => "EncodedAudioChunk",
            .audio_encoder => "AudioData",
        };
    }

    /// What the error callback is handed when the codec name survives
    /// validation but nothing here supports it. All four differ, and the
    /// AudioEncoder one reports a channel count it never parsed -- it says
    /// "received 0" even for a config that passed 2 (measured twice).
    fn unsupportedMessage(comptime self: Role) []const u8 {
        return switch (self) {
            .video_decoder, .audio_decoder => "Unknown or ambiguous codec name.",
            .video_encoder => "Unsupported codec type.",
            .audio_encoder => "Unsupported channel count; expected range from 1 to 32, received 0.",
        };
    }
};

const State = enum {
    unconfigured,
    configured,
    closed,

    fn name(self: State) []const u8 {
        return switch (self) {
            .unconfigured => "unconfigured",
            .configured => "configured",
            .closed => "closed",
        };
    }
};

const HARDWARE_PREFERENCE = [_][]const u8{ "no-preference", "prefer-hardware", "prefer-software" };
const ALPHA_OPTION = [_][]const u8{ "keep", "discard" };
const BITRATE_MODE = [_][]const u8{ "constant", "variable" };
const LATENCY_MODE = [_][]const u8{ "quality", "realtime" };

/// One entry of the object `isConfigSupported` echoes. The members are read
/// alphabetically, so appending in read order is already the order Chrome
/// answers in.
const Echo = struct {
    const Value = union(enum) {
        string: []const u8,
        number: f64,
        boolean: bool,
        /// A member handed straight back the way it came in: a `description`
        /// buffer, or a nested dictionary this engine has no shape for.
        raw: js.Value,
        nested: *const Echo,
    };

    const Entry = struct {
        name: []const u8,
        value: Value,
    };

    /// The widest config here is VideoEncoderConfig's thirteen members.
    entries: [16]Entry = undefined,
    len: usize = 0,

    fn add(self: *Echo, name: []const u8, value: Value) void {
        self.entries[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    fn addOptional(self: *Echo, name: []const u8, value: ?Value) void {
        if (value) |v| {
            self.add(name, v);
        }
    }

    fn build(self: *const Echo, local: *const js.Local) !js.Object {
        const object = local.newObject();
        for (self.entries[0..self.len]) |entry| {
            switch (entry.value) {
                .string => |v| _ = try object.set(entry.name, v, .{}),
                .number => |v| _ = try object.set(entry.name, v, .{}),
                .boolean => |v| _ = try object.set(entry.name, v, .{}),
                .raw => |v| _ = try object.set(entry.name, v, .{}),
                .nested => |v| _ = try object.set(entry.name, try v.build(local), .{}),
            }
        }
        return object;
    }
};

/// The members of OpusEncoderConfig, which AudioEncoderConfig echoes back with
/// every default filled in -- unlike `avc`, which is handed straight back.
/// Measured with `{opus: {complexity: 5}}`, which answered with the other seven
/// at their defaults. `complexity` has no measured default, so it is echoed
/// only when the page provides one.
fn readOpus(member: js.Value, exec: *const Execution) !?*const Echo {
    if (!member.isObject()) {
        return null;
    }
    const object = member.toObject();
    const echo = try exec.call_arena.create(Echo);
    echo.* = .{};

    const present = struct {
        fn get(o: js.Object, comptime name: []const u8) !?js.Value {
            const value = try o.get(name);
            return if (value.isUndefined()) null else value;
        }
    };

    echo.add("application", .{ .string = if (try present.get(object, "application")) |v|
        try v.toStringSlice()
    else
        "audio" });
    if (try present.get(object, "complexity")) |v| {
        echo.add("complexity", .{ .number = try v.toF64() });
    }
    echo.add("format", .{ .string = if (try present.get(object, "format")) |v|
        try v.toStringSlice()
    else
        "opus" });
    echo.add("frameDuration", .{ .number = if (try present.get(object, "frameDuration")) |v|
        try v.toF64()
    else
        20000 });
    echo.add("packetlossperc", .{ .number = if (try present.get(object, "packetlossperc")) |v|
        try v.toF64()
    else
        0 });
    echo.add("signal", .{ .string = if (try present.get(object, "signal")) |v|
        try v.toStringSlice()
    else
        "auto" });
    echo.add("usedtx", .{ .boolean = if (try present.get(object, "usedtx")) |v| v.toBool() else false });
    echo.add("useinbandfec", .{ .boolean = if (try present.get(object, "useinbandfec")) |v| v.toBool() else false });
    return echo;
}

/// The codecs this build answers `supported: true` for. Machine-specific --
/// it is what a Chrome 150 on this macOS box reports, and reproducing it
/// exactly is the point, because a detector can enumerate it.
const Support = struct {
    /// Video, identical for the decoder and the encoder: `vp8` exactly, or one
    /// of five prefixes. Case-sensitive, so `VP8` and `AVC1.42E01E` are false.
    const VIDEO_PREFIXES = [_][]const u8{ "vp09.", "avc1.", "av01.", "hev1.", "hvc1." };

    /// The audio names that compare case-insensitively (`Opus`, `PCM-S16` and
    /// `ALAW` are all true).
    const AUDIO_FOLDED = [_][]const u8{ "opus", "alaw", "ulaw", "pcm-u8", "pcm-s16", "pcm-s24", "pcm-s32", "pcm-f32" };

    /// ...and the ones that do not (`MP3`, `Mp4a.40.2`, `Vorbis` and `FLAC`
    /// are all false). vorbis and flac only get this far with a description --
    /// without one the config is refused before `supported` is ever asked.
    const AUDIO_EXACT = [_][]const u8{ "mp3", "mp4a.40.2", "mp4a.40.5", "vorbis", "flac" };

    /// AudioEncoder takes a much shorter list: opus and the two AAC profiles.
    const AUDIO_ENCODER_FOLDED = [_][]const u8{"opus"};
    const AUDIO_ENCODER_EXACT = [_][]const u8{ "mp4a.40.2", "mp4a.40.5" };

    fn video(codec: []const u8) bool {
        if (std.mem.eql(u8, codec, "vp8")) {
            return true;
        }
        for (VIDEO_PREFIXES) |prefix| {
            if (std.mem.startsWith(u8, codec, prefix)) {
                return true;
            }
        }
        return false;
    }

    fn audio(codec: []const u8, comptime encoder: bool) bool {
        const folded = if (encoder) &AUDIO_ENCODER_FOLDED else &AUDIO_FOLDED;
        const exact = if (encoder) &AUDIO_ENCODER_EXACT else &AUDIO_EXACT;
        for (folded) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, codec)) {
                return true;
            }
        }
        for (exact) |candidate| {
            if (std.mem.eql(u8, candidate, codec)) {
                return true;
            }
        }
        return false;
    }
};

/// What a codec config amounts to once it has been read and validated: the
/// echo to hand back, and the two facts that decide `supported`.
const Config = struct {
    echo: Echo = .{},
    codec: []const u8 = "",
    /// Video only. `prefer-hardware` finds nothing on this box, so it turns
    /// every video codec unsupported (measured).
    prefer_hardware: bool = false,
};

pub fn registerTypes() []const type {
    return &.{ VideoDecoder, VideoEncoder, AudioDecoder, AudioEncoder };
}

fn Codec(comptime role: Role) type {
    return struct {
        const Self = @This();
        pub const Proto = EventTarget;

        const INTERFACE = role.interface();
        const VERB = role.verb();
        const CONFIG_DICT = INTERFACE ++ "Config";
        const INIT_DICT = INTERFACE ++ "Init";
        const Input = role.Input();

        const CtorReader = dictionary.Reader(INTERFACE, INIT_DICT);
        const ConfigureReader = dictionary.MethodReader(INTERFACE, "configure", CONFIG_DICT);
        const SupportReader = dictionary.MethodReader(INTERFACE, "isConfigSupported", CONFIG_DICT);

        fn executePrefix(comptime method: []const u8) []const u8 {
            return "Failed to execute '" ++ method ++ "' on '" ++ INTERFACE ++ "': ";
        }

        _proto: *EventTarget,
        _execution: *const Execution,
        _output: js.Function.Global,
        _error: js.Function.Global,
        _state: State = .unconfigured,
        _queue: u32 = 0,
        /// Set by a configure() that accepted an unsupported codec; the error
        /// callback fires on a later task. Held rather than fired immediately
        /// so a second configure() with the same bad codec still produces
        /// exactly one error (measured).
        _pending_error: bool = false,

        pub fn constructor(init_: js.Value, exec: *const Execution) !*Self {
            const init = try CtorReader.readRequired(init_, exec);

            // Alphabetical, which is the order Chrome reads them in: `{}` and
            // `{output}` both complain about `error`, `{error}` about `output`.
            const on_error = try readCallback(CtorReader, init, "error", exec);
            const on_output = try readCallback(CtorReader, init, "output", exec);

            const self = try exec._factory.eventTarget(Self{
                ._proto = undefined,
                ._execution = exec,
                ._output = try on_output.persist(),
                ._error = try on_error.persist(),
            });
            return self;
        }

        fn readCallback(
            comptime Reader: type,
            init: anytype,
            comptime name: []const u8,
            exec: *const Execution,
        ) !js.Function {
            const member = (try init.present(name)) orelse return Reader.missingMember(name, exec);
            if (!member.isFunction()) {
                return throwTypeError(
                    Reader.message_prefix ++ "Failed to read the '" ++ name ++ "' property from '" ++
                        INIT_DICT ++ "': The given value is not a function.",
                    exec,
                );
            }
            return member.toZig(js.Function);
        }

        pub fn asEventTarget(self: *Self) *EventTarget {
            return self._proto;
        }

        pub fn getState(self: *const Self) []const u8 {
            return self._state.name();
        }

        pub fn getQueueSize(self: *const Self) u32 {
            return self._queue;
        }

        // -- configure / reset / close -------------------------------------

        pub fn configure(self: *Self, args: []js.Value, exec: *const Execution) !void {
            if (args.len == 0) {
                return throwTypeError(
                    comptime executePrefix("configure") ++ "1 argument required, but only 0 present.",
                    exec,
                );
            }
            if (self._state == .closed) {
                // The role quirk: both decoders name 'decode' here and both
                // encoders name 'configure'.
                return throwDom(
                    "InvalidStateError",
                    comptime executePrefix("configure") ++ "Cannot call '" ++
                        (if (role.decoder()) "decode" else "configure") ++ "' on a closed codec.",
                    exec,
                );
            }

            const config = try readConfig(ConfigureReader, args[0], exec);
            self._state = .configured;
            self._queue = 0;
            if (supported(config)) {
                // A configure() that lands on something real cancels an error
                // an earlier one had queued.
                self._pending_error = false;
                return;
            }
            if (self._pending_error) {
                return;
            }
            self._pending_error = true;
            try exec._scheduler.add(self, deliverConfigureError, 0, .{ .name = INTERFACE ++ ".configure" });
        }

        pub fn reset(self: *Self, exec: *const Execution) !void {
            if (self._state == .closed) {
                return closedCall("reset", exec);
            }
            self._state = .unconfigured;
            self._queue = 0;
            self._pending_error = false;
        }

        pub fn close(self: *Self, exec: *const Execution) !void {
            if (self._state == .closed) {
                return closedCall("close", exec);
            }
            self._state = .closed;
            self._queue = 0;
            self._pending_error = false;
        }

        fn closedCall(comptime method: []const u8, exec: *const Execution) anyerror {
            return throwDom(
                "InvalidStateError",
                comptime executePrefix(method) ++ "Cannot call '" ++ method ++ "' on a closed codec.",
                exec,
            );
        }

        // -- decode / encode ------------------------------------------------

        pub fn work(self: *Self, args: []js.Value, exec: *const Execution) !void {
            if (args.len == 0) {
                return throwTypeError(
                    comptime executePrefix(VERB) ++ "1 argument required, but only 0 present.",
                    exec,
                );
            }
            // The conversion comes before the state check: an unconfigured
            // codec handed the wrong kind of object still reports the type
            // rather than the state (measured).
            const input = args[0].toZig(*Input) catch return throwTypeError(
                comptime executePrefix(VERB) ++ "parameter 1 is not of type '" ++ role.inputName() ++ "'.",
                exec,
            );
            switch (self._state) {
                .unconfigured => return throwDom(
                    "InvalidStateError",
                    comptime executePrefix(VERB) ++ "Cannot call '" ++ VERB ++ "' on an unconfigured codec.",
                    exec,
                ),
                .closed => return throwDom(
                    "InvalidStateError",
                    comptime executePrefix(VERB) ++ "Cannot call '" ++ VERB ++ "' on a closed codec.",
                    exec,
                ),
                .configured => {},
            }

            switch (comptime role) {
                // A VideoDecoder never accepts a chunk this engine can have
                // produced: there is no key frame in it, and Chrome says so at
                // two different lengths depending on the chunk's own type.
                .video_decoder => {
                    const tail = "A key frame is required after configure() or flush().";
                    if (std.mem.eql(u8, input._type, "key")) {
                        return throwDom("DataError", comptime executePrefix(VERB) ++
                            "An EncodedVideoChunk was marked as type `key` but wasn't a key frame. " ++ tail, exec);
                    }
                    return throwDom("DataError", comptime executePrefix(VERB) ++ tail, exec);
                },
                // The AudioDecoder's refusal carries no message text at all
                // after the prefix, and the prefix loses its colon with it.
                .audio_decoder => {
                    if (!std.mem.eql(u8, input._type, "key")) {
                        return throwDom(
                            "DataError",
                            "Failed to execute '" ++ VERB ++ "' on '" ++ INTERFACE ++ "'",
                            exec,
                        );
                    }
                },
                .video_encoder, .audio_encoder => {
                    if (input._closed) {
                        return throwTypeError(
                            comptime executePrefix(VERB) ++ "Cannot encode closed input.",
                            exec,
                        );
                    }
                },
            }

            self._queue += 1;
            try exec._scheduler.add(self, deliverDequeue, 0, .{ .name = INTERFACE ++ ".dequeue" });
        }

        pub fn flush(self: *Self, exec: *const Execution) !js.Promise {
            const local = exec.js.local.?;
            // flush() *rejects* rather than throwing, unlike every other
            // state-machine refusal here.
            const refusal: ?[]const u8 = switch (self._state) {
                .unconfigured => comptime executePrefix("flush") ++ "Cannot call 'flush' on an unconfigured codec.",
                .closed => comptime executePrefix("flush") ++ "Cannot call 'flush' on a closed codec.",
                .configured => null,
            };
            if (refusal) |message| {
                var resolver = local.createPromiseResolver();
                resolver.reject(INTERFACE, DOMException.init(message, "InvalidStateError"));
                return resolver.promise();
            }
            self._queue = 0;
            return local.resolvePromise({});
        }

        // -- isConfigSupported ----------------------------------------------

        /// Static, and it never throws: the argument count, a non-object, a
        /// missing member and a validation refusal all come back as rejections
        /// (measured -- every one of them returns a Promise synchronously).
        pub fn isConfigSupported(args: []js.Value, exec: *const Execution) !js.Promise {
            const local = exec.js.local.?;
            if (args.len == 0) {
                var resolver = local.createPromiseResolver();
                resolver.rejectError(INTERFACE, .{
                    .type_error = comptime executePrefix("isConfigSupported") ++
                        "1 argument required, but only 0 present.",
                });
                return resolver.promise();
            }

            var try_catch: js.TryCatch = undefined;
            try_catch.init(local);
            defer try_catch.deinit();

            const config = readConfig(SupportReader, args[0], exec) catch {
                var resolver = local.createPromiseResolver();
                if (try_catch.exceptionValue()) |value| {
                    resolver.reject(INTERFACE, value);
                } else {
                    resolver.rejectError(INTERFACE, .{ .generic_error = "isConfigSupported failed" });
                }
                return resolver.promise();
            };

            const answer = local.newObject();
            _ = try answer.set("config", try config.echo.build(local), .{});
            _ = try answer.set("supported", supported(config), .{});
            return local.resolvePromise(answer);
        }

        fn supported(config: Config) bool {
            if (comptime role.video()) {
                if (config.prefer_hardware) {
                    return false;
                }
                return Support.video(config.codec);
            }
            return Support.audio(config.codec, comptime !role.decoder());
        }

        // -- the config dictionary -------------------------------------------

        /// Reads the members alphabetically (which is both the order Chrome
        /// reads them in and the order it echoes them back), then validates.
        fn readConfig(comptime Reader: type, value: js.Value, exec: *const Execution) !Config {
            const config = try Reader.readRequired(value, exec);
            var out = Config{};
            const echo = &out.echo;

            switch (comptime role) {
                .video_decoder => {
                    out.codec = try requiredString(Reader, config, "codec", exec);
                    echo.add("codec", .{ .string = out.codec });

                    const coded_height = try config.enforcedInt("codedHeight", u32, "unsigned long", exec);
                    echo.addOptional("codedHeight", numberOf(coded_height));
                    const coded_width = try config.enforcedInt("codedWidth", u32, "unsigned long", exec);
                    echo.addOptional("codedWidth", numberOf(coded_width));
                    if (try readDescription(Reader, config, exec)) |bytes| {
                        echo.add("description", try descriptionEcho(bytes, exec));
                    }
                    echo.add("flip", .{ .boolean = try config.boolean("flip", false) });
                    const hardware = (try config.enumMember(
                        "hardwareAcceleration",
                        "HardwarePreference",
                        &HARDWARE_PREFERENCE,
                        "no-preference",
                        exec,
                    )).?;
                    echo.add("hardwareAcceleration", .{ .string = hardware });
                    out.prefer_hardware = std.mem.eql(u8, hardware, "prefer-hardware");
                    if (try config.present("optimizeForLatency")) |member| {
                        echo.add("optimizeForLatency", .{ .boolean = member.toBool() });
                    }
                    echo.add("rotation", .{ .number = try config.double("rotation", 0, exec) });

                    try validateCodec(Reader, out.codec, exec);
                    try validateCodedSize(Reader, coded_width, coded_height, exec);
                },
                .video_encoder => {
                    echo.add("alpha", .{ .string = (try config.enumMember("alpha", "AlphaOption", &ALPHA_OPTION, "discard", exec)).? });
                    // `avc` is handed straight back the way it came in, unlike
                    // `opus`, which AudioEncoderConfig fills out.
                    echo.addOptional("avc", rawOf(try config.present("avc")));
                    echo.addOptional("bitrate", numberOf(try config.enforcedInt("bitrate", u64, "unsigned long long", exec)));
                    echo.add("bitrateMode", .{ .string = (try config.enumMember("bitrateMode", "VideoEncoderBitrateMode", &BITRATE_MODE, "variable", exec)).? });
                    out.codec = try requiredString(Reader, config, "codec", exec);
                    echo.add("codec", .{ .string = out.codec });
                    echo.add("contentHint", .{ .string = try config.string("contentHint", "", exec.call_arena) });
                    echo.addOptional("displayHeight", numberOf(try config.enforcedInt("displayHeight", u32, "unsigned long", exec)));
                    echo.addOptional("displayWidth", numberOf(try config.enforcedInt("displayWidth", u32, "unsigned long", exec)));
                    if (try config.present("framerate")) |_| {
                        echo.add("framerate", .{ .number = try config.double("framerate", 0, exec) });
                    }
                    const hardware = (try config.enumMember(
                        "hardwareAcceleration",
                        "HardwarePreference",
                        &HARDWARE_PREFERENCE,
                        "no-preference",
                        exec,
                    )).?;
                    echo.add("hardwareAcceleration", .{ .string = hardware });
                    out.prefer_hardware = std.mem.eql(u8, hardware, "prefer-hardware");
                    const height = try config.enforcedInt("height", u32, "unsigned long", exec) orelse
                        return Reader.missingMember("height", exec);
                    echo.add("height", .{ .number = @floatFromInt(height) });
                    echo.add("latencyMode", .{ .string = (try config.enumMember("latencyMode", "LatencyMode", &LATENCY_MODE, "quality", exec)).? });
                    if (try config.present("scalabilityMode")) |member| {
                        echo.add("scalabilityMode", .{ .string = try member.toStringSlice() });
                    }
                    const width = try config.enforcedInt("width", u32, "unsigned long", exec) orelse
                        return Reader.missingMember("width", exec);
                    echo.add("width", .{ .number = @floatFromInt(width) });

                    try validateCodec(Reader, out.codec, exec);
                    if (width == 0 or height == 0) {
                        return throwTypeError(
                            Reader.message_prefix ++ "Invalid size; height and width must be greater than zero.",
                            exec,
                        );
                    }
                },
                .audio_decoder, .audio_encoder => {
                    if (comptime role == .audio_encoder) {
                        echo.addOptional("bitrate", numberOf(try config.enforcedInt("bitrate", u64, "unsigned long long", exec)));
                        echo.add("bitrateMode", .{ .string = (try config.enumMember("bitrateMode", "BitrateMode", &BITRATE_MODE, "variable", exec)).? });
                    }
                    out.codec = try requiredString(Reader, config, "codec", exec);
                    echo.add("codec", .{ .string = out.codec });
                    // AudioEncoderConfig has no `description`, so an
                    // AudioEncoder neither reads nor echoes one.
                    const description = if (comptime role == .audio_decoder)
                        try readDescription(Reader, config, exec)
                    else
                        null;
                    if (description) |bytes| {
                        echo.add("description", try descriptionEcho(bytes, exec));
                    }
                    const channels = try config.enforcedInt("numberOfChannels", u32, "unsigned long", exec) orelse
                        return Reader.missingMember("numberOfChannels", exec);
                    echo.add("numberOfChannels", .{ .number = @floatFromInt(channels) });
                    if (comptime role == .audio_encoder) {
                        if (try config.present("opus")) |member| {
                            if (try readOpus(member, exec)) |nested| {
                                echo.add("opus", .{ .nested = nested });
                            }
                        }
                    }
                    const sample_rate_member = (try config.present("sampleRate")) orelse
                        return Reader.missingMember("sampleRate", exec);
                    const sample_rate = try Reader.finite("sampleRate", sample_rate_member, exec);
                    echo.add("sampleRate", .{ .number = sample_rate });

                    // Audio validates the numbers before the codec, and the
                    // channel count before the rate: a config with both at zero
                    // reports the channels (measured, win49-chrome.json).
                    if (channels == 0) {
                        return throwTypeError(
                            Reader.message_prefix ++ "Invalid channel count; channel count must be non-zero, received 0.",
                            exec,
                        );
                    }
                    if (sample_rate == 0) {
                        return throwTypeError(
                            Reader.message_prefix ++ "Invalid sample rate; sample rate must be non-zero, received 0.",
                            exec,
                        );
                    }
                    try validateCodec(Reader, out.codec, exec);
                    // vorbis and flac carry their setup in the description, so
                    // Chrome refuses them outright without one -- a semicolon
                    // this time, where the coded-size message has a comma.
                    if (comptime role == .audio_decoder) {
                        const needs_description = std.mem.eql(u8, out.codec, "vorbis") or
                            std.mem.eql(u8, out.codec, "flac");
                        if (needs_description and description == null) {
                            return throwTypeError(
                                Reader.message_prefix ++ "Invalid config; description is required.",
                                exec,
                            );
                        }
                    }
                },
            }

            return out;
        }

        fn requiredString(
            comptime Reader: type,
            config: anytype,
            comptime name: []const u8,
            exec: *const Execution,
        ) ![]const u8 {
            const member = (try config.present(name)) orelse return Reader.missingMember(name, exec);
            return member.toStringSliceWithAlloc(exec.call_arena);
        }

        /// A `description` is a BufferSource or nothing: a string is refused
        /// with the union spelled out, not stringified into a buffer.
        fn readDescription(comptime Reader: type, config: anytype, exec: *const Execution) !?[]u8 {
            const member = (try config.present("description")) orelse return null;
            return frames.bufferSource(member) orelse
                Reader.notOfType("description", BUFFER_SOURCE, exec);
        }

        fn validateCodec(comptime Reader: type, codec: []const u8, exec: *const Execution) !void {
            if (codec.len == 0) {
                return throwTypeError(Reader.message_prefix ++ "Invalid codec; codec is required.", exec);
            }
        }

        /// codedWidth and codedHeight come as a pair, and neither may be zero.
        /// Note the comma after "config", which the description refusal spells
        /// with a semicolon instead.
        fn validateCodedSize(
            comptime Reader: type,
            width: ?u32,
            height: ?u32,
            exec: *const Execution,
        ) !void {
            if (width != null and height == null) {
                return throwTypeError(
                    Reader.message_prefix ++ "Invalid config, codedWidth specified without codedHeight.",
                    exec,
                );
            }
            if (height != null and width == null) {
                return throwTypeError(
                    Reader.message_prefix ++ "Invalid config, codedHeight specified without codedWidth.",
                    exec,
                );
            }
            const w = width orelse return;
            const h = height.?;
            if (w == 0 or h == 0) {
                return throwTypeError(try std.fmt.allocPrint(
                    exec.call_arena,
                    Reader.message_prefix ++ "Invalid coded size ({d}, {d}).",
                    .{ w, h },
                ), exec);
            }
        }

        // -- the two scheduled tasks -----------------------------------------

        fn deliverConfigureError(ptr: *anyopaque) !?u32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (!self._pending_error) {
                return null;
            }
            self._pending_error = false;
            self._state = .closed;
            self._queue = 0;

            var ls: js.Local.Scope = undefined;
            self._execution.js.localScope(&ls);
            defer ls.deinit();

            const dom = try self._execution.arena.create(DOMException);
            dom.* = DOMException.init(role.unsupportedMessage(), "NotSupportedError");
            _ = ls.toLocal(self._error).call(void, .{dom}) catch |err| {
                log.warn(.js, "codec error callback", .{ .err = err, .interface = INTERFACE });
            };
            return null;
        }

        fn deliverDequeue(ptr: *anyopaque) !?u32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self._state == .closed or self._queue == 0) {
                return null;
            }
            self._queue -= 1;

            var ls: js.Local.Scope = undefined;
            self._execution.js.localScope(&ls);
            defer ls.deinit();

            const exec = self._execution;
            const target = self.asEventTarget();
            switch (exec.js.global) {
                inline else => |g| {
                    const event = try Event.initTrusted(comptime .wrap("dequeue"), .{}, g._page);
                    try g.dispatch(target, event, null, .{ .context = "codec dequeue" });
                },
            }
            return null;
        }

        pub const JsApi = if (role.decoder()) struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = INTERFACE;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const Prototype = EventTarget;

            pub const constructor = bridge.constructor(Self.constructor, .{ .arity = 1 });
            pub const decodeQueueSize = bridge.accessor(Self.getQueueSize, null, .{});
            pub const ondequeue = bridge.accessor(handlerPropertyLenient(Self, .ondequeue).get, handlerPropertyLenient(Self, .ondequeue).set, .{});
            pub const state = bridge.accessor(Self.getState, null, .{});
            pub const close = bridge.function(Self.close, .{});
            pub const configure = bridge.function(Self.configure, .{ .arity = 1 });
            pub const decode = bridge.function(Self.work, .{ .arity = 1 });
            pub const flush = bridge.function(Self.flush, .{});
            pub const reset = bridge.function(Self.reset, .{});
            pub const isConfigSupported = bridge.function(Self.isConfigSupported, .{ .static = true, .arity = 1 });
        } else struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = INTERFACE;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const Prototype = EventTarget;

            pub const constructor = bridge.constructor(Self.constructor, .{ .arity = 1 });
            pub const encodeQueueSize = bridge.accessor(Self.getQueueSize, null, .{});
            pub const ondequeue = bridge.accessor(handlerPropertyLenient(Self, .ondequeue).get, handlerPropertyLenient(Self, .ondequeue).set, .{});
            pub const state = bridge.accessor(Self.getState, null, .{});
            pub const close = bridge.function(Self.close, .{});
            pub const configure = bridge.function(Self.configure, .{ .arity = 1 });
            pub const encode = bridge.function(Self.work, .{ .arity = 1 });
            pub const flush = bridge.function(Self.flush, .{});
            pub const reset = bridge.function(Self.reset, .{});
            pub const isConfigSupported = bridge.function(Self.isConfigSupported, .{ .static = true, .arity = 1 });
        };
    };
}

fn numberOf(value: anytype) ?Echo.Value {
    const v = value orelse return null;
    return .{ .number = @floatFromInt(v) };
}

fn rawOf(value: ?js.Value) ?Echo.Value {
    const v = value orelse return null;
    return .{ .raw = v };
}

/// The `[AllowShared] ArrayBuffer or [AllowShared] ArrayBufferView` union,
/// spelled the way Chrome spells it when nothing in it converts.
const BUFFER_SOURCE = "([AllowShared] ArrayBuffer or [AllowShared] ArrayBufferView)";

/// A `description` is never handed back the way it came in: Chrome answers
/// with a **fresh ArrayBuffer** holding a copy of exactly the bytes the view
/// covered -- a 3-byte view over an 8-byte buffer echoes a 3-byte buffer, it
/// is never the input's own `.buffer`, and two calls with the same input give
/// two different objects (measured, win50-chrome.json).
fn descriptionEcho(bytes: []const u8, exec: *const Execution) !Echo.Value {
    const local = exec.js.local.?;
    const array = local.createTypedArray(.uint8, bytes.len);
    @memcpy(array.slice(), bytes);
    const view = js.Value{ .local = local, .handle = array.handle };
    return .{ .raw = try view.toObject().get("buffer") };
}

pub const VideoDecoder = Codec(.video_decoder);
pub const VideoEncoder = Codec(.video_encoder);
pub const AudioDecoder = Codec(.audio_decoder);
pub const AudioEncoder = Codec(.audio_encoder);

const testing = @import("../../../testing.zig");
test "WebApi: WebCodecs codecs" {
    try testing.htmlRunner("webcodecs/codecs.html", .{});
}
