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

pub const Key = struct {
    target: *EventTarget,
    handler: Handler,
    // No `Key.fuse` here: upstream packs the handler tag into the top 7 bits of
    // the target pointer, which caps `Handler` at 128 tags. Ours has 261 (the
    // measured Chrome handler set), so `Context.hash` mixes instead of fusing --
    // see the comment there.
};

const Context = struct {
    /// Mixes the target pointer with the handler tag. The tag rides in the top
    /// bits, which a user-space pointer never reaches, but nothing depends on
    /// that being injective: `eql` compares the two fields, so a collision here
    /// costs a probe and never a wrong answer. (An earlier version fused the
    /// pair into one u64 and compared *that*, which capped `Handler` at the 256
    /// tags a u8 can hold -- the enum has since outgrown it.)
    pub fn hash(_: @This(), key: Key) u64 {
        const ptr = @intFromPtr(key.target);
        // Upstream dropped this file's local IS_DEBUG for `lp.IS_DEBUG`.
        if (comptime lp.IS_DEBUG) {
            lp.assert(ptr < (1 << 48), "Key.hash: pointer overflow", .{ .ptr = ptr });
        }
        return std.hash.int(ptr ^ (@as(u64, @intFromEnum(key.handler)) << 48));
    }

    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return a.target == b.target and a.handler == b.handler;
    }
};

pub const Lookup = std.HashMapUnmanaged(
    Key,
    js.Function.Global,
    Context,
    std.hash_map.default_max_load_percentage,
);

/// Enum of known event listeners. `Context.hash` mixes the tag in above a
/// pointer's 48 significant bits, so the tag has 16 bits to grow into; the
/// hash map stays correct past that anyway, because `Context.eql` compares the
/// fields rather than the mix.
pub const Handler = enum(u16) {
    onabort,
    onactivate,
    onactive,
    onaddsourcebuffer,
    onaddstream,
    onaddtrack,
    onafterprint,
    onanimationcancel,
    onanimationend,
    onanimationiteration,
    onanimationstart,
    onappinstalled,
    onaudioend,
    onaudioprocess,
    onaudiostart,
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
    onblocked,
    onblur,
    onboundary,
    onbufferedamountlow,
    oncancel,
    oncanplay,
    oncanplaythrough,
    oncapturehandlechange,
    onchange,
    oncharacterboundsupdate,
    oncharacteristicvaluechanged,
    onchargingchange,
    onchargingtimechange,
    onclick,
    onclipboardchange,
    onclose,
    onclosing,
    oncommand,
    oncomplete,
    oncompositionend,
    oncompositionstart,
    onconnect,
    onconnecting,
    onconnectionavailable,
    onconnectionstatechange,
    oncontentvisibilityautostatechange,
    oncontextlost,
    oncontextmenu,
    oncontextrestored,
    oncontrollerchange,
    oncopy,
    oncuechange,
    oncurrententrychange,
    oncurrentscreenchange,
    oncut,
    ondatachannel,
    ondblclick,
    ondequeue,
    ondevicechange,
    ondevicemotion,
    ondeviceorientation,
    ondeviceorientationabsolute,
    ondischargingtimechange,
    ondisconnect,
    ondispose,
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
    onenter,
    onenterpictureinpicture,
    onerror,
    onexit,
    onfinish,
    onfocus,
    onformdata,
    onfreeze,
    onfullscreenchange,
    onfullscreenerror,
    ongamepadconnected,
    ongamepaddisconnected,
    ongatheringstatechange,
    ongattserverdisconnected,
    ongeometrychange,
    ongotpointercapture,
    onhashchange,
    onicecandidate,
    onicecandidateerror,
    oniceconnectionstatechange,
    onicegatheringstatechange,
    oninactive,
    oninput,
    oninputreport,
    oninputsourceschange,
    oninvalid,
    onkeydown,
    onkeypress,
    onkeystatuseschange,
    onkeyup,
    onlanguagechange,
    onleavepictureinpicture,
    onlevelchange,
    onload,
    onloadeddata,
    onloadedmetadata,
    onloadend,
    // FontFaceSet's three, the only interface that has them.
    onloading,
    onloadingdone,
    onloadingerror,
    onloadstart,
    onlocation,
    onlostpointercapture,
    onmanagedconfigurationchange,
    onmark,
    onmessage,
    onmessageerror,
    onmidimessage,
    onmousedown,
    onmouseenter,
    onmouseleave,
    onmousemove,
    onmouseout,
    onmouseover,
    onmouseup,
    onmousewheel,
    onmute,
    onnavigate,
    onnavigateerror,
    onnavigatesuccess,
    onnegotiationneeded,
    onnomatch,
    onoffline,
    ononline,
    onopen,
    onpagehide,
    onpagereveal,
    onpageshow,
    onpageswap,
    onpaste,
    onpause,
    onpayerdetailchange,
    onpaymentmethodchange,
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
    onprioritychange,
    onprogress,
    onpromptaction,
    onpromptdismiss,
    onratechange,
    onreading,
    onreadystatechange,
    onredraw,
    onreflectionchange,
    onrejectionhandled,
    onrelease,
    onremove,
    onremovesourcebuffer,
    onremovestream,
    onremovetrack,
    onrepeat,
    onreset,
    onresize,
    onresourcetimingbufferfull,
    onresult,
    onresume,
    onscreenschange,
    onscroll,
    onscrollend,
    onscrollsnapchange,
    onscrollsnapchanging,
    onsearch,
    onsecuritypolicyviolation,
    onseeked,
    onseeking,
    onselect,
    onselectedcandidatepairchange,
    onselectend,
    onselectionchange,
    onselectstart,
    onshippingaddresschange,
    onshippingoptionchange,
    onshow,
    onsignalingstatechange,
    onsinkchange,
    onslotchange,
    onsoundend,
    onsoundstart,
    onsourceclose,
    onsourceended,
    onsourceopen,
    onspeechend,
    onspeechstart,
    onsqueeze,
    onsqueezeend,
    onsqueezestart,
    onstalled,
    onstart,
    onstatechange,
    onstorage,
    onstream,
    onsubmit,
    onsuccess,
    onsuspend,
    onterminate,
    ontextformatupdate,
    ontextupdate,
    ontimeout,
    ontimeupdate,
    ontoggle,
    ontonechange,
    ontouchcancel,
    ontouchend,
    ontouchmove,
    ontouchstart,
    ontrack,
    ontransitioncancel,
    ontransitionend,
    ontransitionrun,
    ontransitionstart,
    onuncapturederror,
    onunhandledrejection,
    onunload,
    onunmute,
    onupdate,
    onupdateend,
    onupdatefound,
    onupdatestart,
    onupgradeneeded,
    onvalidationstatuschange,
    onversionchange,
    onvisibilitychange,
    onvisibilitymaskchange,
    onvoiceschanged,
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
    onwrite,
    onwriteend,
    onwritestart,
    onzoomlevelchange,
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
    @setEvalBranchQuota(10_000);
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

const handlerToType = blk: {
    @setEvalBranchQuota(10_000);
    const fields = std.meta.fields(Handler);
    var entries: [fields.len][]const u8 = undefined;
    for (fields) |field| {
        const handler: Handler = @enumFromInt(field.value);
        entries[field.value] = derivedType(field.name, handler);
    }
    break :blk entries;
};

pub fn fromEventType(typ: []const u8) ?Handler {
    return typeToHandler.get(typ);
}

/// The inverse of `fromEventType`: the event type a handler listens for.
pub fn toEventType(handler: Handler) []const u8 {
    return handlerToType[@intFromEnum(handler)];
}

const testing = @import("../../testing.zig");
test "GlobalEventHandlers: fromEventType" {
    try testing.expectEqual(.onabort, fromEventType("abort"));
    try testing.expectEqual(.onselect, fromEventType("select"));
    try testing.expectEqual(null, fromEventType(""));
    try testing.expectEqual(null, fromEventType("unknown"));
}

test "GlobalEventHandlers: toEventType round trips" {
    inline for (std.meta.fields(Handler)) |field| {
        const handler: Handler = @enumFromInt(field.value);
        try testing.expectEqual(handler, fromEventType(toEventType(handler)));
    }
    try testing.expectEqual("webkitAnimationEnd", toEventType(.onwebkitanimationend));
}
