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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const Key = struct {
    target: *EventTarget,
    handler: Handler,

    /// Fuses `target` pointer and `handler` enum; used at hashing.
    /// NEVER use a fusion to retrieve a pointer back. Portability is not guaranteed.
    /// See `Context.hash`.
    fn fuse(self: *const Key) u64 {
        // Check if we have 3 bits available from alignment of 8.
        if (comptime IS_DEBUG) {
            lp.assert(@alignOf(EventTarget) == 8, "Key.fuse: incorrect alignment", .{
                .event_target_alignment = @alignOf(EventTarget),
            });
        }

        const ptr = @intFromPtr(self.target) >> 3;
        if (comptime IS_DEBUG) {
            lp.assert(ptr < (1 << 56), "Key.fuse: pointer overflow", .{ .ptr = ptr });
        }
        return ptr | (@as(u64, @intFromEnum(self.handler)) << 56);
    }
};

const Context = struct {
    pub fn hash(_: @This(), key: Key) u64 {
        return std.hash.int(key.fuse());
    }

    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return a.fuse() == b.fuse();
    }
};

pub const Lookup = std.HashMapUnmanaged(
    Key,
    js.Function.Global,
    Context,
    std.hash_map.default_max_load_percentage,
);

/// Enum of known event listeners; increasing the size of it (u8)
/// can cause `Key` to behave incorrectly. `Key.fuse` packs the tag into the
/// top 8 bits, so the shift there must move in step with this.
pub const Handler = enum(u8) {
    onabort,
    onafterprint,
    onanimationcancel,
    onanimationend,
    onanimationiteration,
    onanimationstart,
    onappinstalled,
    onauxclick,
    onbeforecopy,
    onbeforecut,
    onbeforeinput,
    onbeforeinstallprompt,
    onbeforematch,
    onbeforepaste,
    onbeforeprint,
    onbeforetoggle,
    onbeforeunload,
    onbeforexrselect,
    onbegin,
    onblur,
    oncancel,
    oncanplay,
    oncanplaythrough,
    onchange,
    oncharacterboundsupdate,
    onclick,
    onclose,
    oncommand,
    oncompositionend,
    oncompositionstart,
    oncontentvisibilityautostatechange,
    oncontextlost,
    oncontextmenu,
    oncontextrestored,
    oncopy,
    oncuechange,
    oncut,
    ondblclick,
    ondevicemotion,
    ondeviceorientation,
    ondeviceorientationabsolute,
    ondrag,
    ondragend,
    ondragenter,
    ondragexit,
    ondragleave,
    ondragover,
    ondragstart,
    ondrop,
    ondurationchange,
    onemptied,
    onencrypted,
    onend,
    onended,
    onerror,
    onfocus,
    onformdata,
    onfreeze,
    onfullscreenchange,
    onfullscreenerror,
    ongamepadconnected,
    ongamepaddisconnected,
    ongotpointercapture,
    onhashchange,
    oninput,
    oninvalid,
    onkeydown,
    onkeypress,
    onkeyup,
    onlanguagechange,
    onload,
    onloadeddata,
    onloadedmetadata,
    onloadstart,
    onlostpointercapture,
    onmessage,
    onmessageerror,
    onmousedown,
    onmouseenter,
    onmouseleave,
    onmousemove,
    onmouseout,
    onmouseover,
    onmouseup,
    onmousewheel,
    onoffline,
    ononline,
    onpagehide,
    onpagereveal,
    onpageshow,
    onpageswap,
    onpaste,
    onpause,
    onplay,
    onplaying,
    onpointercancel,
    onpointerdown,
    onpointerenter,
    onpointerleave,
    onpointerlockchange,
    onpointerlockerror,
    onpointermove,
    onpointerout,
    onpointerover,
    onpointerrawupdate,
    onpointerup,
    onpopstate,
    onprerenderingchange,
    onprogress,
    onratechange,
    onreadystatechange,
    onrejectionhandled,
    onrepeat,
    onreset,
    onresize,
    onresume,
    onscroll,
    onscrollend,
    onscrollsnapchange,
    onscrollsnapchanging,
    onsearch,
    onsecuritypolicyviolation,
    onseeked,
    onseeking,
    onselect,
    onselectionchange,
    onselectstart,
    onslotchange,
    onstalled,
    onstorage,
    onsubmit,
    onsuspend,
    ontextformatupdate,
    ontextupdate,
    ontimeupdate,
    ontoggle,
    ontouchcancel,
    ontouchend,
    ontouchmove,
    ontouchstart,
    ontransitioncancel,
    ontransitionend,
    ontransitionrun,
    ontransitionstart,
    onunhandledrejection,
    onunload,
    onvisibilitychange,
    onvolumechange,
    onwaiting,
    onwaitingforkey,
    onwebkitanimationend,
    onwebkitanimationiteration,
    onwebkitanimationstart,
    onwebkitfullscreenchange,
    onwebkitfullscreenerror,
    onwebkittransitionend,
    onwheel,
};

/// The handlers whose event type is not the property name with `on` stripped.
/// The four webkit-prefixed animation/transition aliases kept the camel case
/// of the events they shipped as -- measured on a headed Chrome 150,
/// `el.onwebkitanimationend` fires for `new Event('webkitAnimationEnd')` and
/// not for `new Event('webkitanimationend')`. (webkitfullscreenchange and
/// webkitfullscreenerror are genuinely lowercase and stay derived.)
const CAMEL_CASE_TYPES = [_]struct { []const u8, Handler }{
    .{ "webkitAnimationEnd", .onwebkitanimationend },
    .{ "webkitAnimationIteration", .onwebkitanimationiteration },
    .{ "webkitAnimationStart", .onwebkitanimationstart },
    .{ "webkitTransitionEnd", .onwebkittransitionend },
};

const typeToHandler = std.StaticStringMap(Handler).initComptime(blk: {
    const fields = std.meta.fields(Handler);
    var entries: [fields.len]struct { []const u8, Handler } = undefined;
    for (fields, 0..) |field, i| {
        const handler: Handler = @enumFromInt(field.value);
        entries[i] = .{ derivedType(field.name, handler), handler };
    }
    break :blk entries;
});

/// The event type for a handler: the property name without `on`, unless the
/// handler is one of the camel-cased aliases, in which case the derived
/// spelling is replaced rather than added -- Chrome routes only the camel case.
fn derivedType(comptime name: []const u8, comptime handler: Handler) []const u8 {
    for (CAMEL_CASE_TYPES) |entry| {
        if (entry[1] == handler) return entry[0];
    }
    return name[2..];
}

pub fn fromEventType(typ: []const u8) ?Handler {
    return typeToHandler.get(typ);
}

const testing = @import("../../testing.zig");
test "GlobalEventHandlers: fromEventType" {
    try testing.expectEqual(.onabort, fromEventType("abort"));
    try testing.expectEqual(.onselect, fromEventType("select"));
    try testing.expectEqual(null, fromEventType(""));
    try testing.expectEqual(null, fromEventType("unknown"));
}
