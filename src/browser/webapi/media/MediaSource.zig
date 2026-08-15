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
// `MediaSource.canConstructInDedicatedWorker` is here as a static accessor: on
// Chrome it is an accessor too, not the data property it reads as (measured --
// `JSON.stringify(Object.getOwnPropertyDescriptor(MediaSource,
// 'canConstructInDedicatedWorker'))` prints only enumerable and configurable,
// which is what a get/set pair serialises to).
//
// SourceBuffer, SourceBufferList and MediaSourceHandle live here too. None of
// them can ever be populated -- a buffer needs a pipeline to append into -- but
// all three are window keys a detector counts, and the two lists are real
// objects with stable identity because Chrome's are.
//
// Known gap, one level up: `URL.createObjectURL` takes only a Blob here, so
// `URL.createObjectURL(mediaSource)` is a TypeError where Chrome mints a blob:
// URL. Minting one would not buy the behaviour behind it -- there is no
// pipeline, so an attached source would still never fire `sourceopen` -- so it
// would trade a visible refusal for an invisible one. Left as it is on
// purpose.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const TimeRanges = @import("TimeRanges.zig");
const mime = @import("mime.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ MediaSource, SourceBuffer, SourceBufferList, MediaSourceHandle };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn throwDom(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

/// The refusal every mutator lands on: this source is never attached, so it
/// never opens.
fn notOpen(comptime member: []const u8, exec: *const Execution) anyerror {
    return throwDom(
        "InvalidStateError",
        "Failed to execute '" ++ member ++ "' on 'MediaSource': The MediaSource's readyState is not 'open'.",
        exec,
    );
}

const MediaSource = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
// Created on first read and kept: `ms.sourceBuffers === ms.sourceBuffers` is
// true on Chrome, and the two lists are distinct objects (measured).
_source_buffers: ?*SourceBufferList = null,
_active_source_buffers: ?*SourceBufferList = null,
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

pub fn setDuration(_: *MediaSource, _: f64, exec: *const Execution) !void {
    // A setter, so the wording is "Failed to set the 'duration' property"
    // rather than "Failed to execute" (measured).
    return throwDom(
        "InvalidStateError",
        "Failed to set the 'duration' property on 'MediaSource': The MediaSource's readyState is not 'open'.",
        exec,
    );
}

fn list(slot: *?*SourceBufferList, page: *Page) !*SourceBufferList {
    if (slot.*) |existing| {
        return existing;
    }
    const created = try page.factory.eventTarget(SourceBufferList{ ._proto = undefined });
    created._proto._type = .{ .source_buffer_list = created };
    slot.* = created;
    return created;
}

pub fn getSourceBuffers(self: *MediaSource, page: *Page) !*SourceBufferList {
    return list(&self._source_buffers, page);
}

pub fn getActiveSourceBuffers(self: *MediaSource, page: *Page) !*SourceBufferList {
    return list(&self._active_source_buffers, page);
}

// Every mutator needs an open source, and this one is never open -- which is
// also what Chrome answers for one that was never attached to an element. The
// argument checks all come first, and they carry their own wording.
pub fn addSourceBuffer(_: *MediaSource, type_: ?[]const u8, exec: *const Execution) !void {
    const content_type = type_ orelse return throwTypeError(
        "Failed to execute 'addSourceBuffer' on 'MediaSource': 1 argument required, but only 0 present.",
        exec,
    );
    if (content_type.len == 0) {
        // No trailing full stop: Chrome's own wording (measured).
        return throwTypeError(
            "Failed to execute 'addSourceBuffer' on 'MediaSource': The type provided is empty",
            exec,
        );
    }
    // The type is checked before the readyState, so an unsupported one never
    // reaches the InvalidStateError below (measured).
    if (!mime.isTypeSupported(.media_source, content_type)) {
        return throwDom("NotSupportedError", try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute 'addSourceBuffer' on 'MediaSource': The type provided ('{s}') is unsupported.",
            .{content_type},
        ), exec);
    }
    return notOpen("addSourceBuffer", exec);
}

pub fn removeSourceBuffer(_: *MediaSource, buffer_: ?js.Value, exec: *const Execution) !void {
    const buffer = buffer_ orelse return throwTypeError(
        "Failed to execute 'removeSourceBuffer' on 'MediaSource': 1 argument required, but only 0 present.",
        exec,
    );
    _ = buffer.toZig(*SourceBuffer) catch return throwTypeError(
        "Failed to execute 'removeSourceBuffer' on 'MediaSource': parameter 1 is not of type 'SourceBuffer'.",
        exec,
    );
    // Unreachable in practice: no SourceBuffer can ever be handed out, so
    // nothing can get past the conversion above. Spec order puts the
    // not-in-this-list check first, so that is what is here.
    return throwDom(
        "NotFoundError",
        "Failed to execute 'removeSourceBuffer' on 'MediaSource': The SourceBuffer provided " ++
            "is not contained in this MediaSource.",
        exec,
    );
}

pub fn endOfStream(_: *MediaSource, error_: ?[]const u8, exec: *const Execution) !void {
    // The enum is validated before the readyState (measured).
    if (error_) |name| {
        if (!std.mem.eql(u8, name, "network") and !std.mem.eql(u8, name, "decode")) {
            return throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to execute 'endOfStream' on 'MediaSource': The provided value '{s}' is not " ++
                    "a valid enum value of type EndOfStreamError.",
                .{name},
            ), exec);
        }
    }
    return notOpen("endOfStream", exec);
}

pub fn setLiveSeekableRange(_: *MediaSource, _: f64, _: f64, exec: *const Execution) !void {
    return notOpen("setLiveSeekableRange", exec);
}

pub fn clearLiveSeekableRange(_: *MediaSource, exec: *const Execution) !void {
    return notOpen("clearLiveSeekableRange", exec);
}

/// True on Chrome, and an accessor rather than a data property (measured).
pub fn canConstructInDedicatedWorker() bool {
    return true;
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

    // Statics, in Chrome's order.
    pub const canConstructInDedicatedWorker = bridge.accessor(MediaSource.canConstructInDedicatedWorker, null, .{ .static = true });
    pub const isTypeSupported = bridge.function(MediaSource.isTypeSupported, .{ .static = true, .arity = 1 });

    // Chrome's own prototype order.
    pub const sourceBuffers = bridge.accessor(MediaSource.getSourceBuffers, null, .{});
    pub const activeSourceBuffers = bridge.accessor(MediaSource.getActiveSourceBuffers, null, .{});
    pub const duration = bridge.accessor(MediaSource.getDuration, MediaSource.setDuration, .{});
    pub const onsourceopen = bridge.accessor(MediaSource.getOnSourceOpen, MediaSource.setOnSourceOpen, .{});
    pub const onsourceended = bridge.accessor(MediaSource.getOnSourceEnded, MediaSource.setOnSourceEnded, .{});
    pub const onsourceclose = bridge.accessor(MediaSource.getOnSourceClose, MediaSource.setOnSourceClose, .{});
    pub const readyState = bridge.accessor(MediaSource.getReadyState, null, .{});
    pub const addSourceBuffer = bridge.function(MediaSource.addSourceBuffer, .{ .arity = 1 });
    pub const clearLiveSeekableRange = bridge.function(MediaSource.clearLiveSeekableRange, .{});
    pub const endOfStream = bridge.function(MediaSource.endOfStream, .{});
    pub const removeSourceBuffer = bridge.function(MediaSource.removeSourceBuffer, .{ .arity = 1 });
    pub const setLiveSeekableRange = bridge.function(MediaSource.setLiveSeekableRange, .{ .arity = 2 });
};

/// A buffer a page appends media segments into. There is no pipeline here, so
/// none is ever created -- but it is a window key, and the values below are
/// Chrome's for a freshly added buffer (measured on an attached source:
/// mode "segments", not updating, an empty TimeRanges, offset 0, and an append
/// window that runs to infinity).
pub const SourceBuffer = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _mode: []const u8 = "segments",
    _timestamp_offset: f64 = 0,
    _append_window_start: f64 = 0,
    _append_window_end: f64 = std.math.inf(f64),
    _on_updatestart: ?js.Function.Global = null,
    _on_update: ?js.Function.Global = null,
    _on_updateend: ?js.Function.Global = null,
    _on_error: ?js.Function.Global = null,
    _on_abort: ?js.Function.Global = null,

    pub fn asEventTarget(self: *SourceBuffer) *EventTarget {
        return self._proto;
    }

    pub fn getMode(self: *const SourceBuffer) []const u8 {
        return self._mode;
    }

    pub fn setMode(self: *SourceBuffer, value: []const u8) void {
        if (std.mem.eql(u8, value, "segments") or std.mem.eql(u8, value, "sequence")) {
            self._mode = if (std.mem.eql(u8, value, "sequence")) "sequence" else "segments";
        }
    }

    pub fn getUpdating(_: *const SourceBuffer) bool {
        return false;
    }

    pub fn getBuffered(_: *const SourceBuffer, frame: *Frame) !*TimeRanges {
        return frame._factory.create(TimeRanges{});
    }

    pub fn getTimestampOffset(self: *const SourceBuffer) f64 {
        return self._timestamp_offset;
    }

    pub fn setTimestampOffset(self: *SourceBuffer, value: f64) void {
        self._timestamp_offset = value;
    }

    pub fn getAppendWindowStart(self: *const SourceBuffer) f64 {
        return self._append_window_start;
    }

    pub fn setAppendWindowStart(self: *SourceBuffer, value: f64) void {
        self._append_window_start = value;
    }

    pub fn getAppendWindowEnd(self: *const SourceBuffer) f64 {
        return self._append_window_end;
    }

    pub fn setAppendWindowEnd(self: *SourceBuffer, value: f64) void {
        self._append_window_end = value;
    }

    fn removed(comptime member: []const u8, exec: *const Execution) anyerror {
        return throwDom(
            "InvalidStateError",
            "Failed to execute '" ++ member ++ "' on 'SourceBuffer': This SourceBuffer has been removed " ++
                "from the parent media source.",
            exec,
        );
    }

    pub fn abort(_: *SourceBuffer, exec: *const Execution) !void {
        return removed("abort", exec);
    }

    pub fn appendBuffer(_: *SourceBuffer, _: ?js.Value, exec: *const Execution) !void {
        return removed("appendBuffer", exec);
    }

    pub fn changeType(_: *SourceBuffer, _: ?[]const u8, exec: *const Execution) !void {
        return removed("changeType", exec);
    }

    pub fn remove(_: *SourceBuffer, _: f64, _: f64, exec: *const Execution) !void {
        return removed("remove", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SourceBuffer);

        pub const Meta = struct {
            pub const name = "SourceBuffer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        fn handler(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *SourceBuffer) ?js.Function.Global {
                    return @field(self, field);
                }
                pub fn set(self: *SourceBuffer, cb: ?js.Function) !void {
                    @field(self, field) = if (cb) |c| try c.persistWithThis(self) else null;
                }
            };
        }

        // Chrome's own prototype order.
        pub const mode = bridge.accessor(SourceBuffer.getMode, SourceBuffer.setMode, .{});
        pub const updating = bridge.accessor(SourceBuffer.getUpdating, null, .{});
        pub const buffered = bridge.accessor(SourceBuffer.getBuffered, null, .{});
        pub const timestampOffset = bridge.accessor(SourceBuffer.getTimestampOffset, SourceBuffer.setTimestampOffset, .{});
        pub const appendWindowStart = bridge.accessor(SourceBuffer.getAppendWindowStart, SourceBuffer.setAppendWindowStart, .{});
        pub const appendWindowEnd = bridge.accessor(SourceBuffer.getAppendWindowEnd, SourceBuffer.setAppendWindowEnd, .{});
        pub const onupdatestart = bridge.accessor(handler("_on_updatestart").get, handler("_on_updatestart").set, .{});
        pub const onupdate = bridge.accessor(handler("_on_update").get, handler("_on_update").set, .{});
        pub const onupdateend = bridge.accessor(handler("_on_updateend").get, handler("_on_updateend").set, .{});
        pub const onerror = bridge.accessor(handler("_on_error").get, handler("_on_error").set, .{});
        pub const onabort = bridge.accessor(handler("_on_abort").get, handler("_on_abort").set, .{});
        pub const abort = bridge.function(SourceBuffer.abort, .{});
        pub const appendBuffer = bridge.function(SourceBuffer.appendBuffer, .{ .arity = 1 });
        pub const changeType = bridge.function(SourceBuffer.changeType, .{ .arity = 1 });
        pub const remove = bridge.function(SourceBuffer.remove, .{ .arity = 2 });
    };
};

/// The list of a source's buffers. Always empty here, and array-like rather
/// than a WebIDL iterable: Chrome's `@@iterator` on this one *is*
/// `Array.prototype[Symbol.iterator]`, which the bridge cannot reproduce
/// exactly -- it installs its own function of the same shape.
pub const SourceBufferList = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _items: []const *SourceBuffer = &.{},
    _on_add_source_buffer: ?js.Function.Global = null,
    _on_remove_source_buffer: ?js.Function.Global = null,

    pub fn asEventTarget(self: *SourceBufferList) *EventTarget {
        return self._proto;
    }

    pub fn getLength(self: *const SourceBufferList) u32 {
        return @intCast(self._items.len);
    }

    pub fn indexedGet(self: *const SourceBufferList, index: u32) ?*SourceBuffer {
        if (index >= self._items.len) {
            return null;
        }
        return self._items[index];
    }

    pub fn values(self: *SourceBufferList, exec: *const Execution) ![]const *SourceBuffer {
        _ = exec;
        return self._items;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SourceBufferList);

        pub const Meta = struct {
            pub const name = "SourceBufferList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        fn getIndexes(self: *SourceBufferList, frame: *Frame) !js.Array {
            var arr = frame.js.local.?.newArray(self.getLength());
            for (0..self._items.len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }

        fn handler(comptime field: []const u8) type {
            return struct {
                pub fn get(self: *SourceBufferList) ?js.Function.Global {
                    return @field(self, field);
                }
                pub fn set(self: *SourceBufferList, cb: ?js.Function) !void {
                    @field(self, field) = if (cb) |c| try c.persistWithThis(self) else null;
                }
            };
        }

        pub const length = bridge.accessor(SourceBufferList.getLength, null, .{});
        pub const @"[]" = bridge.indexed(SourceBufferList.indexedGet, getIndexes, .{ .null_as_undefined = true });
        pub const onaddsourcebuffer = bridge.accessor(handler("_on_add_source_buffer").get, handler("_on_add_source_buffer").set, .{});
        pub const onremovesourcebuffer = bridge.accessor(handler("_on_remove_source_buffer").get, handler("_on_remove_source_buffer").set, .{});
        pub const symbol_iterator = bridge.iterator(SourceBufferList.values, .{});
    };
};

/// A transferable handle to a MediaSource, for building one inside a dedicated
/// worker and handing it to the main thread. The interface object is on window,
/// but `MediaSource.prototype.handle` is not -- the attribute is worker-only,
/// and this build does not carry it (measured: the descriptor is absent, and
/// `ms.handle` is undefined). So nothing here can ever mint one, and the
/// prototype is empty apart from the brand, which is Chrome's shape too.
pub const MediaSourceHandle = struct {
    // Padding to avoid a zero-size struct, which collides in the identity map.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaSourceHandle);

        pub const Meta = struct {
            pub const name = "MediaSourceHandle";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaSource" {
    try testing.htmlRunner("media_mimes.html", .{});
}

test "WebApi: MediaSourceExtensions" {
    try testing.htmlRunner("media/mse.html", .{});
}
