// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const Factory = @import("../../../Factory.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Media = @import("Media.zig");
const text_tracks = @import("../../media/text_tracks.zig");
const reflection = @import("../reflection.zig");

const String = lp.String;

const Track = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_kind: String,
_ready_state: ReadyState,
// Built on the first read of `track` and kept: `t.track === t.track` is true
// in Chrome, and the same object is what the owning media element lists in
// `textTracks` (measured: a `<video>` with one `<track>` child reports
// textTracks.length 1).
_track: ?*text_tracks.TextTrack = null,

const ReadyState = enum(u8) { none, loading, loaded, @"error" };

pub fn asElement(self: *Track) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Track) *Node {
    return self.asElement().asNode();
}

/// NONE until something loads the cue file, which nothing here does. Chrome
/// answers 0 for a `<track>` whose media has not been asked to load it either.
pub fn getReadyState(self: *const Track) u16 {
    return @intFromEnum(self._ready_state);
}

/// The `TextTrack` this element owns. Chrome builds it from the element's
/// attributes -- kind, label and srclang -- and starts it "showing" when the
/// element carries `default`, "disabled" otherwise. Creating it also puts it in
/// the owning media element's `textTracks`, which is where a page looks for it.
pub fn getTrack(self: *Track, page: *Page) !*text_tracks.TextTrack {
    if (self._track) |track| {
        return track;
    }

    const element = self.asElement();
    const keywords = [_][]const u8{ "subtitles", "captions", "descriptions", "chapters", "metadata" };
    const kind_name = reflection.enumeratedValue(
        element.getAttributeSafe(comptime .wrap("kind")),
        &keywords,
        "subtitles",
        "metadata",
    ) orelse "subtitles";

    const track = try text_tracks.TextTrack.create(
        std.meta.stringToEnum(text_tracks.TextTrack.Kind, kind_name).?,
        element.getAttributeSafe(comptime .wrap("label")) orelse "",
        element.getAttributeSafe(comptime .wrap("srclang")) orelse "",
        page,
    );
    track.setMode(if (element.hasAttributeSafe(comptime .wrap("default"))) "showing" else "disabled");
    self._track = track;

    if (self.asNode().parentElement()) |parent| {
        if (parent.as(HtmlElement).is(Media)) |media| {
            const list = try media.getTextTracks(page);
            try list._items.append(page.frame_arena, track);
        }
    }
    return track;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Track);

    pub const Meta = struct {
        pub const name = "HTMLTrackElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Track);

    // Chrome's order: the attributes in IDL order, then readyState and track,
    // then the four constants.
    pub const kind = reflect.enumerated("kind", &.{ "subtitles", "captions", "descriptions", "chapters", "metadata" }, .{ .missing = "subtitles", .invalid = "metadata" });
    pub const src = reflect.url("src");
    pub const srclang = reflect.string("srclang");
    pub const label = reflect.string("label");
    pub const default = reflect.boolean("default");

    pub const readyState = bridge.accessor(Track.getReadyState, null, .{});
    pub const track = bridge.accessor(Track.getTrack, null, .{});

    pub const NONE = bridge.property(@as(u16, @intFromEnum(ReadyState.none)), .{ .template = true });
    pub const LOADING = bridge.property(@as(u16, @intFromEnum(ReadyState.loading)), .{ .template = true });
    pub const LOADED = bridge.property(@as(u16, @intFromEnum(ReadyState.loaded)), .{ .template = true });
    pub const ERROR = bridge.property(@as(u16, @intFromEnum(ReadyState.@"error")), .{ .template = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Track" {
    try testing.htmlRunner("element/html/track.html", .{});
}
