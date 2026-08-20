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

// The text-track cluster. TextTrackCue and VTTCue were already here, but the
// track that owns them, the list of tracks on a media element and the list of
// cues on a track were not -- so `video.textTracks` was undefined and three
// globals a detector enumerates were missing.
//
// None of this needs media to load: addTextTrack() builds a track from script
// alone, and everything below (the default mode of "hidden", cues going null
// while the mode is "disabled", the NotFoundError from removing a cue that was
// never added) is real behaviour, measured on a headed Chrome 150. See
// tools/fingerprint/scratch/win-batch/probe-win31.js.

const std = @import("std");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const EventTarget = @import("../EventTarget.zig");
const TextTrackCue = @import("TextTrackCue.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

pub fn registerTypes() []const type {
    return &.{
        TextTrack,
        TextTrackList,
        TextTrackList.Iterator,
        TextTrackCueList,
        TextTrackCueList.Iterator,
    };
}

fn throwTypeError(message: []const u8, exec: *const js.Execution) anyerror {
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

pub const TextTrack = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _kind: Kind,
    _label: []const u8,
    _language: []const u8,
    _id: []const u8 = "",
    _mode: Mode = .hidden,
    _cues: *TextTrackCueList,
    _active_cues: *TextTrackCueList,

    /// The five values HTMLMediaElement.addTextTrack accepts; anything else is
    /// a TypeError from the caller, with Chrome's enum wording.
    pub const Kind = enum {
        subtitles,
        captions,
        descriptions,
        chapters,
        metadata,
    };

    pub const Mode = enum { disabled, hidden, showing };

    /// Measured: a track built by addTextTrack starts "hidden", with an empty
    /// id, and both cue lists already materialised.
    pub fn create(kind: Kind, label: []const u8, language: []const u8, page: *Page) !*TextTrack {
        const factory = &page.factory;
        const track = try factory.eventTarget(TextTrack{
            ._proto = undefined,
            ._kind = kind,
            ._label = try page.frame_arena.dupe(u8, label),
            ._language = try page.frame_arena.dupe(u8, language),
            ._cues = try factory.create(TextTrackCueList{}),
            ._active_cues = try factory.create(TextTrackCueList{}),
        });
        track._proto._type = .text_track;
        return track;
    }

    pub fn asEventTarget(self: *TextTrack) *EventTarget {
        return self._proto;
    }

    pub fn getKind(self: *const TextTrack) []const u8 {
        return @tagName(self._kind);
    }

    pub fn getLabel(self: *const TextTrack) []const u8 {
        return self._label;
    }

    pub fn getLanguage(self: *const TextTrack) []const u8 {
        return self._language;
    }

    pub fn getId(self: *const TextTrack) []const u8 {
        return self._id;
    }

    pub fn getMode(self: *const TextTrack) []const u8 {
        return @tagName(self._mode);
    }

    /// An IDL enum attribute: a value outside the enum is ignored rather than
    /// thrown (measured: `t.mode = 'nope'` leaves it at "hidden").
    pub fn setMode(self: *TextTrack, value: []const u8) void {
        self._mode = std.meta.stringToEnum(Mode, value) orelse return;
    }

    /// Both lists read null while the track is disabled (measured), and are the
    /// same objects on every read otherwise.
    pub fn getCues(self: *const TextTrack) ?*TextTrackCueList {
        if (self._mode == .disabled) {
            return null;
        }
        return self._cues;
    }

    pub fn getActiveCues(self: *const TextTrack) ?*TextTrackCueList {
        if (self._mode == .disabled) {
            return null;
        }
        return self._active_cues;
    }

    pub fn addCue(self: *TextTrack, cue_: ?js.Value, exec: *const js.Execution) !void {
        const value = cue_ orelse return throwTypeError(
            "Failed to execute 'addCue' on 'TextTrack': 1 argument required, but only 0 present.",
            exec,
        );
        const cue = value.toZig(*TextTrackCue) catch return throwTypeError(
            "Failed to execute 'addCue' on 'TextTrack': parameter 1 is not of type 'TextTrackCue'.",
            exec,
        );

        if (self._cues.indexOf(cue) != null) {
            return;
        }
        try self._cues._items.append(exec.page.frame_arena, cue);
        cue._track = self;
    }

    pub fn removeCue(self: *TextTrack, cue_: ?js.Value, exec: *const js.Execution) !void {
        const value = cue_ orelse return throwTypeError(
            "Failed to execute 'removeCue' on 'TextTrack': 1 argument required, but only 0 present.",
            exec,
        );
        const cue = value.toZig(*TextTrackCue) catch return throwTypeError(
            "Failed to execute 'removeCue' on 'TextTrack': parameter 1 is not of type 'TextTrackCue'.",
            exec,
        );

        const index = self._cues.indexOf(cue) orelse {
            const local = exec.js.local.?;
            const dom = @import("../DOMException.zig").init(
                "Failed to execute 'removeCue' on 'TextTrack': The specified cue is not listed in the TextTrack's list of cues.",
                "NotFoundError",
            );
            const exception = local.zigValueToJs(dom, .{}) catch return error.JsException;
            _ = local.isolate.throwException(exception.handle);
            return error.JsException;
        };
        _ = self._cues._items.orderedRemove(index);
        cue._track = null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TextTrack);

        pub const Meta = struct {
            pub const name = "TextTrack";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const kind = bridge.accessor(TextTrack.getKind, null, .{});
        pub const label = bridge.accessor(TextTrack.getLabel, null, .{});
        pub const language = bridge.accessor(TextTrack.getLanguage, null, .{});
        pub const id = bridge.accessor(TextTrack.getId, null, .{});
        pub const mode = bridge.accessor(TextTrack.getMode, TextTrack.setMode, .{});
        pub const cues = bridge.accessor(TextTrack.getCues, null, .{});
        pub const activeCues = bridge.accessor(TextTrack.getActiveCues, null, .{});
        pub const oncuechange = bridge.accessor(handlerProperty(TextTrack, .oncuechange).get, handlerProperty(TextTrack, .oncuechange).set, .{});
        pub const addCue = bridge.function(TextTrack.addCue, .{ .arity = 1 });
        pub const removeCue = bridge.function(TextTrack.removeCue, .{ .arity = 1 });
    };
};

/// `video.textTracks`. An EventTarget in Chrome, with the three track handlers
/// on its prototype; nothing here fires them yet.
pub const TextTrackList = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _items: std.ArrayListUnmanaged(*TextTrack) = .empty,

    pub fn asEventTarget(self: *TextTrackList) *EventTarget {
        return self._proto;
    }

    pub fn getLength(self: *const TextTrackList) u32 {
        return @intCast(self._items.items.len);
    }

    pub fn item(self: *const TextTrackList, index: u32) ?*TextTrack {
        if (index >= self._items.items.len) {
            return null;
        }
        return self._items.items[index];
    }

    /// A plain id match, so the empty id every script-built track carries finds
    /// the first track (measured: `getTrackById('')` answers it).
    pub fn getTrackById(self: *const TextTrackList, id: []const u8) ?*TextTrack {
        for (self._items.items) |track| {
            if (std.mem.eql(u8, track._id, id)) {
                return track;
            }
        }
        return null;
    }

    pub fn iterator(self: *TextTrackList, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *TextTrackList,

        pub fn next(self: *@This(), _: *const js.Execution) ?*TextTrack {
            const index = self.index;
            const track = self.list.item(index) orelse return null;
            self.index = index + 1;
            return track;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TextTrackList);

        pub const Meta = struct {
            pub const name = "TextTrackList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(TextTrackList.getLength, null, .{});
        pub const onchange = bridge.accessor(handlerProperty(TextTrackList, .onchange).get, handlerProperty(TextTrackList, .onchange).set, .{});
        pub const onaddtrack = bridge.accessor(handlerProperty(TextTrackList, .onaddtrack).get, handlerProperty(TextTrackList, .onaddtrack).set, .{});
        pub const onremovetrack = bridge.accessor(handlerProperty(TextTrackList, .onremovetrack).get, handlerProperty(TextTrackList, .onremovetrack).set, .{});
        pub const getTrackById = bridge.function(TextTrackList.getTrackById, .{});
        pub const @"[]" = bridge.indexed(TextTrackList.item, getIndexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(TextTrackList.iterator, .{ .js_name = "values" });

        fn getIndexes(self: *TextTrackList, exec: *const js.Execution) !js.Array {
            const len = self.getLength();
            var arr = exec.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }
    };
};

/// `track.cues`. Unlike the other lists in this file it has no item() method --
/// indexed access and getCueById are all Chrome puts on the prototype.
pub const TextTrackCueList = struct {
    _items: std.ArrayListUnmanaged(*TextTrackCue) = .empty,

    pub fn getLength(self: *const TextTrackCueList) u32 {
        return @intCast(self._items.items.len);
    }

    fn indexOf(self: *const TextTrackCueList, cue: *TextTrackCue) ?usize {
        return std.mem.indexOfScalar(*TextTrackCue, self._items.items, cue);
    }

    pub fn item(self: *const TextTrackCueList, index: u32) ?*TextTrackCue {
        if (index >= self._items.items.len) {
            return null;
        }
        return self._items.items[index];
    }

    /// The empty string is never a match, even though every cue starts with an
    /// empty id (measured: Chrome answers null). TextTrackList.getTrackById
    /// does the opposite, and does match its empty ids.
    pub fn getCueById(self: *const TextTrackCueList, id: []const u8) ?*TextTrackCue {
        if (id.len == 0) {
            return null;
        }
        for (self._items.items) |cue| {
            if (std.mem.eql(u8, cue._id, id)) {
                return cue;
            }
        }
        return null;
    }

    pub fn iterator(self: *TextTrackCueList, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *TextTrackCueList,

        pub fn next(self: *@This(), _: *const js.Execution) ?*TextTrackCue {
            const index = self.index;
            const cue = self.list.item(index) orelse return null;
            self.index = index + 1;
            return cue;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TextTrackCueList);

        pub const Meta = struct {
            pub const name = "TextTrackCueList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(TextTrackCueList.getLength, null, .{});
        pub const getCueById = bridge.function(TextTrackCueList.getCueById, .{});
        pub const @"[]" = bridge.indexed(TextTrackCueList.item, getIndexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(TextTrackCueList.iterator, .{ .js_name = "values" });

        fn getIndexes(self: *TextTrackCueList, exec: *const js.Execution) !js.Array {
            const len = self.getLength();
            var arr = exec.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: TextTrack" {
    try testing.htmlRunner("text_tracks.html", .{});
}
