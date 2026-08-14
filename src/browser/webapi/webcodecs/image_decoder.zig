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

// ImageDecoder, ImageTrack and ImageTrackList. The bytes are read by
// images.zig; this is the object graph and the state machine over it.
//
// Measured on Chrome 150 / macOS with probe-win43.js, probe-win47.js and
// probe-win51.js; see win47-findings.md and win51-findings.md. What that turned
// up beyond the shapes:
//
//   * The track list is empty until `tracks.ready` settles: 0 / -1 / null
//     before, 1 / 0 / the track after. `decode()` called before then still
//     works -- it waits.
//   * A still image reports `repetitionCount` 0; a GIF reports **Infinity**,
//     and `animated` true even when it has one frame. (An earlier probe
//     recorded null for the GIF, which was `JSON.stringify` flattening
//     Infinity.)
//   * `close()` is idempotent -- unlike the four codec classes, where a second
//     one is an InvalidStateError -- and afterwards `type` is the empty string
//     while `complete` stays true.
//   * Two failures that must stay distinct: a type nothing supports rejects
//     `ready` NotSupportedError and leaves `completed` **pending forever**;
//     bytes that are not the declared type reject `ready` InvalidStateError
//     "Failed to retrieve track metadata." and *resolve* `completed`.
//   * `decode()`'s refusals are rejections, never synchronous throws, and the
//     closed one has no "Failed to execute" prefix.
//   * `ImageDecoderInit` does not validate its enum members: `{premultiplyAlpha:
//     'nope'}` builds a decoder rather than throwing.
//   * `desiredWidth` / `desiredHeight` are accepted and do not resize anything.

const std = @import("std");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const frames = @import("frames.zig");
const images = @import("images.zig");
const DOMException = @import("../DOMException.zig");

const Execution = js.Execution;
const throwTypeError = dictionary.throwTypeError;

/// The `data` member's union, spelled the way Chrome spells it. A
/// ReadableStream is in it even though nothing here reads one.
const IMAGE_DATA = "(ReadableStream or [AllowShared] ArrayBuffer or [AllowShared] ArrayBufferView)";

const CTOR = "Failed to construct 'ImageDecoder': ";
const DECODE = "Failed to execute 'decode' on 'ImageDecoder': ";

/// Where the metadata got to. `pending` until the scheduled read runs.
const Status = enum {
    pending,
    ready,
    /// The declared type is not one of the six.
    unsupported_type,
    /// The type is fine, the bytes are not.
    metadata_failed,
    closed,
};

pub const ImageTrack = struct {
    _list: *ImageTrackList,
    _frame_count: u32,
    _animated: bool,
    _repetition_count: f64,
    _selected: bool = true,

    pub fn getFrameCount(self: *const ImageTrack) u32 {
        return self._frame_count;
    }

    pub fn getAnimated(self: *const ImageTrack) bool {
        return self._animated;
    }

    pub fn getRepetitionCount(self: *const ImageTrack) f64 {
        return self._repetition_count;
    }

    pub fn getSelected(self: *const ImageTrack) bool {
        return self._selected;
    }

    /// Deselecting does not remove the track: the list keeps its length and
    /// only its selectedIndex/selectedTrack go to -1 and null (measured).
    pub fn setSelected(self: *ImageTrack, selected: bool) void {
        self._selected = selected;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ImageTrack);

        pub const Meta = struct {
            pub const name = "ImageTrack";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const frameCount = bridge.accessor(ImageTrack.getFrameCount, null, .{});
        pub const animated = bridge.accessor(ImageTrack.getAnimated, null, .{});
        pub const repetitionCount = bridge.accessor(ImageTrack.getRepetitionCount, null, .{});
        pub const selected = bridge.accessor(ImageTrack.getSelected, ImageTrack.setSelected, .{});
    };
};

pub const ImageTrackList = struct {
    /// At most one: nothing here reads a format with several tracks.
    _track: ?*ImageTrack = null,
    _ready: ?js.PromiseResolver.Global = null,
    _settled: bool = false,

    pub fn getLength(self: *const ImageTrackList) u32 {
        return if (self._track == null) 0 else 1;
    }

    pub fn getSelectedIndex(self: *const ImageTrackList) i32 {
        const track = self._track orelse return -1;
        return if (track._selected) 0 else -1;
    }

    pub fn getSelectedTrack(self: *const ImageTrackList) ?*ImageTrack {
        const track = self._track orelse return null;
        return if (track._selected) track else null;
    }

    /// The same promise on every read.
    pub fn getReady(self: *ImageTrackList, exec: *const Execution) !js.Promise {
        return (try self.resolver(exec.js.local.?)).promise();
    }

    /// Takes the local explicitly: a scheduled task runs with `exec.js.local`
    /// unset and has to hand in its own scope's.
    fn resolver(self: *ImageTrackList, local: *const js.Local) !js.PromiseResolver {
        if (self._ready) |global| {
            return local.toLocal(global);
        }
        const created = local.createPromiseResolver();
        self._ready = try created.persist();
        return created;
    }

    pub fn item(self: *const ImageTrackList, index: u32) ?*ImageTrack {
        if (index != 0) {
            return null;
        }
        return self._track;
    }

    pub fn values(self: *ImageTrackList, exec: *const Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *ImageTrackList,

        pub fn next(self: *@This(), _: *const js.Execution) ?*ImageTrack {
            const index = self.index;
            const track = self.list.item(index) orelse return null;
            self.index = index + 1;
            return track;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ImageTrackList);

        pub const Meta = struct {
            pub const name = "ImageTrackList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(ImageTrackList.getLength, null, .{});
        pub const selectedIndex = bridge.accessor(ImageTrackList.getSelectedIndex, null, .{});
        pub const selectedTrack = bridge.accessor(ImageTrackList.getSelectedTrack, null, .{});
        pub const ready = bridge.accessor(ImageTrackList.getReady, null, .{});
        pub const @"[]" = bridge.indexed(ImageTrackList.item, getIndexes, .{ .null_as_undefined = true });
        // Chrome's @@iterator *is* the values function rather than a copy of
        // it, so the symbol has to carry that name.
        pub const symbol_iterator = bridge.iterator(ImageTrackList.values, .{ .js_name = "values" });

        fn getIndexes(self: *ImageTrackList, exec: *const js.Execution) !js.Array {
            const len = self.getLength();
            var arr = exec.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }
    };
};

pub const ImageDecoder = struct {
    _execution: *const Execution,
    _type: []const u8,
    _data: []const u8,
    _tracks: *ImageTrackList,
    _completed: ?js.PromiseResolver.Global = null,
    _status: Status = .pending,
    _image: ?images.Image = null,

    pub fn constructor(init_: js.Value, exec: *const Execution) !*ImageDecoder {
        const Reader = dictionary.Reader("ImageDecoder", "ImageDecoderInit");
        const init = try Reader.readRequired(init_, exec);

        // `data` is read before `type`: `{}` complains about data, `{data}`
        // about type.
        const data_member = try init.required("data", exec);
        const data = frames.bufferSource(data_member) orelse
            return Reader.notOfType("data", IMAGE_DATA, exec);
        const mime = (try init.present("type")) orelse return Reader.missingMember("type", exec);

        // The optional members are read and dropped. Unusually for a WebIDL
        // dictionary, a bogus enum value among them is not refused --
        // `{premultiplyAlpha: 'nope'}` builds a decoder (measured).
        _ = try init.present("premultiplyAlpha");
        _ = try init.present("colorSpaceConversion");
        _ = try init.present("desiredWidth");
        _ = try init.present("desiredHeight");
        _ = try init.present("preferAnimation");

        const self = try exec._factory.create(ImageDecoder{
            ._execution = exec,
            ._type = try mime.toStringSliceWithAlloc(exec.arena),
            ._data = try exec.arena.dupe(u8, data),
            ._tracks = try exec._factory.create(ImageTrackList{}),
        });
        // `completed` means "all the input is in", and every byte already is,
        // so it resolves right here -- before the track metadata, which Chrome
        // settles later still: a page that awaits `completed` and then reads
        // `decoder.tracks` sees 0 / -1 (measured, win43-chrome.json). A type
        // nothing supports never settles it at all.
        if (images.Kind.fromType(self._type) != null) {
            (try self.completedResolver(exec.js.local.?)).resolve("ImageDecoder", {});
        }
        try exec._scheduler.add(self, readMetadata, 0, .{ .name = "ImageDecoder.metadata" });
        return self;
    }

    /// Echoes the string it was given, and becomes empty once closed.
    pub fn getType(self: *const ImageDecoder) []const u8 {
        return if (self._status == .closed) "" else self._type;
    }

    /// All the bytes are always in hand here, and Chrome answers true even for
    /// a decoder it has closed or failed (measured).
    pub fn getComplete(_: *const ImageDecoder) bool {
        return true;
    }

    /// The same promise on every read. It resolves once the metadata is in,
    /// resolves for unreadable bytes, and stays pending forever for a type
    /// nothing supports.
    pub fn getCompleted(self: *ImageDecoder, exec: *const Execution) !js.Promise {
        return (try self.completedResolver(exec.js.local.?)).promise();
    }

    fn completedResolver(self: *ImageDecoder, local: *const js.Local) !js.PromiseResolver {
        if (self._completed) |global| {
            return local.toLocal(global);
        }
        const created = local.createPromiseResolver();
        self._completed = try created.persist();
        return created;
    }

    pub fn getTracks(self: *const ImageDecoder) *ImageTrackList {
        return self._tracks;
    }

    /// Nothing here buffers between frames, so a reset changes nothing that a
    /// page can see -- which is what Chrome reports too (measured: `complete`
    /// and the track list are untouched).
    pub fn reset(_: *ImageDecoder) void {}

    /// Idempotent, unlike the four codec classes.
    pub fn close(self: *ImageDecoder) void {
        self._status = .closed;
        self._tracks._track = null;
        self._image = null;
    }

    pub fn decode(self: *ImageDecoder, options_: ?js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;

        // The options are read now -- the value does not survive the task --
        // but every refusal is a rejection, never a throw (measured). The
        // TryCatch has to be standing *before* the reading so the conversion's
        // own message is what the promise rejects with.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        var frame_index: u32 = 0;
        if (options_) |options_value| {
            if (!options_value.isNullOrUndefined()) {
                if (!options_value.isObject()) {
                    return rejectType(local, DECODE ++ "The provided value is not of type 'ImageDecodeOptions'.");
                }
                const Reader = dictionary.MethodReader("ImageDecoder", "decode", "ImageDecodeOptions");
                const read = struct {
                    fn call(value: js.Value, e: *const Execution) !u32 {
                        const options = try Reader.read(value, e);
                        _ = try options.boolean("completeFramesOnly", true);
                        return (try options.enforcedInt("frameIndex", u32, "unsigned long", e)) orelse 0;
                    }
                }.call;
                frame_index = read(options_value, exec) catch
                    return rejectCaught(local, &try_catch);
            }
        }

        const resolver = local.createPromiseResolver();
        const pending = try exec.arena.create(PendingDecode);
        pending.* = .{
            .decoder = self,
            .frame_index = frame_index,
            .resolver = try resolver.persist(),
        };
        // Scheduled rather than answered here so a decode() issued before the
        // metadata task runs still waits for it: the scheduler keeps insertion
        // order for tasks due at the same time.
        try exec._scheduler.add(pending, deliverDecode, 0, .{ .name = "ImageDecoder.decode" });
        return resolver.promise();
    }

    const PendingDecode = struct {
        decoder: *ImageDecoder,
        frame_index: u32,
        resolver: js.PromiseResolver.Global,
    };

    fn rejectType(local: *const js.Local, comptime message: []const u8) js.Promise {
        var resolver = local.createPromiseResolver();
        resolver.rejectError("ImageDecoder", .{ .type_error = message });
        return resolver.promise();
    }

    /// A conversion that already threw: the exception the standing TryCatch
    /// holds is what the promise rejects with, so the wording stays Chrome's.
    fn rejectCaught(local: *const js.Local, try_catch: *js.TryCatch) js.Promise {
        var resolver = local.createPromiseResolver();
        if (try_catch.exceptionValue()) |value| {
            resolver.reject("ImageDecoder", value);
        } else {
            resolver.rejectError("ImageDecoder", .{
                .type_error = DECODE ++ "The provided value is not of type 'ImageDecodeOptions'.",
            });
        }
        return resolver.promise();
    }

    fn unsupportedTypeMessage(self: *const ImageDecoder) ![]const u8 {
        return std.fmt.allocPrint(
            self._execution.arena,
            // No trailing period on this one.
            "The provided image type ({s}) is not supported",
            .{self._type},
        );
    }

    // -- the two scheduled tasks ------------------------------------------

    fn readMetadata(ptr: *anyopaque) !?u32 {
        const self: *ImageDecoder = @ptrCast(@alignCast(ptr));
        if (self._status != .pending) {
            return null;
        }

        var ls: js.Local.Scope = undefined;
        self._execution.js.localScope(&ls);
        defer ls.deinit();

        const exec = self._execution;
        const ready = try self._tracks.resolver(&ls.local);
        self._tracks._settled = true;

        const kind = images.Kind.fromType(self._type) orelse {
            self._status = .unsupported_type;
            ready.reject("ImageDecoder", DOMException.init(
                try self.unsupportedTypeMessage(),
                "NotSupportedError",
            ));
            return null;
        };

        const image = images.read(kind, self._data, exec.arena) orelse {
            self._status = .metadata_failed;
            ready.reject("ImageDecoder", DOMException.init(
                "Failed to retrieve track metadata.",
                "InvalidStateError",
            ));
            return null;
        };

        self._image = image;
        self._status = .ready;
        self._tracks._track = try exec._factory.create(ImageTrack{
            ._list = self._tracks,
            ._frame_count = @intCast(image.frames.len),
            ._animated = image.animated,
            ._repetition_count = image.repetition_count,
        });
        ready.resolve("ImageDecoder", {});
        return null;
    }

    fn deliverDecode(ptr: *anyopaque) !?u32 {
        const pending: *PendingDecode = @ptrCast(@alignCast(ptr));
        const self = pending.decoder;

        var ls: js.Local.Scope = undefined;
        self._execution.js.localScope(&ls);
        defer ls.deinit();

        const exec = self._execution;
        const resolver = ls.local.toLocal(pending.resolver);

        switch (self._status) {
            .unsupported_type => {
                resolver.reject("ImageDecoder", DOMException.init(
                    try self.unsupportedTypeMessage(),
                    "NotSupportedError",
                ));
                return null;
            },
            // Both a closed decoder and one whose bytes could not be read
            // answer the same way -- and this one has no "Failed to execute"
            // prefix (measured).
            // `.pending` cannot be reached: the constructor queues the
            // metadata task first, and the scheduler keeps insertion order for
            // tasks due at the same time, so a decode() issued before `ready`
            // still finds the status settled -- which is what Chrome does too
            // (measured, win51-chrome.json).
            .pending, .closed, .metadata_failed => {
                resolver.reject("ImageDecoder", DOMException.init(
                    "The decoder has been closed.",
                    "InvalidStateError",
                ));
                return null;
            },
            .ready => {},
        }

        const image = self._image.?;
        if (pending.frame_index >= image.frames.len) {
            resolver.rejectError("ImageDecoder", .{ .range_error = try std.fmt.allocPrint(
                exec.call_arena,
                "The frame index provided ({d}) is outside the range [0, {d}).",
                .{ pending.frame_index, image.frames.len },
            ) });
            return null;
        }

        const frame_info = image.frames[pending.frame_index];
        const frame = try frames.VideoFrame.decoded(
            image.width,
            image.height,
            frame_info.timestamp,
            frame_info.duration,
            image.pixels,
            exec,
        );
        const answer = ls.local.newObject();
        _ = try answer.set("complete", true, .{});
        _ = try answer.set("image", frame, .{});
        resolver.resolve("ImageDecoder", answer);
        return null;
    }

    /// Static, and it never throws *synchronously*: no argument at all comes
    /// back as a rejected promise (measured -- win43 awaited it and saw the
    /// TypeError, win47 only saw that a Promise came back).
    pub fn isTypeSupported(args: []js.Value, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (args.len == 0) {
            var resolver = local.createPromiseResolver();
            resolver.rejectError("ImageDecoder", .{
                .type_error = "Failed to execute 'isTypeSupported' on 'ImageDecoder': " ++
                    "1 argument required, but only 0 present.",
            });
            return resolver.promise();
        }
        const mime = try args[0].toStringSliceWithAlloc(exec.call_arena);
        return local.resolvePromise(images.Kind.fromType(mime) != null);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ImageDecoder);

        pub const Meta = struct {
            pub const name = "ImageDecoder";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(ImageDecoder.constructor, .{ .arity = 1 });
        pub const @"type" = bridge.accessor(ImageDecoder.getType, null, .{});
        pub const complete = bridge.accessor(ImageDecoder.getComplete, null, .{});
        pub const completed = bridge.accessor(ImageDecoder.getCompleted, null, .{});
        pub const tracks = bridge.accessor(ImageDecoder.getTracks, null, .{});
        pub const close = bridge.function(ImageDecoder.close, .{});
        // Arity zero, not one: the options are optional.
        pub const decode = bridge.function(ImageDecoder.decode, .{});
        pub const reset = bridge.function(ImageDecoder.reset, .{});
        pub const isTypeSupported = bridge.function(ImageDecoder.isTypeSupported, .{ .static = true, .arity = 1 });
    };
};

pub fn registerTypes() []const type {
    return &.{ ImageTrack, ImageTrackList, ImageTrackList.Iterator, ImageDecoder };
}

const testing = @import("../../../testing.zig");
test "WebApi: WebCodecs ImageDecoder" {
    try testing.htmlRunner("webcodecs/image_decoder.html", .{});
}
