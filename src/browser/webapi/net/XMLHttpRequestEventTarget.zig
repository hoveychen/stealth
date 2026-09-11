// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");
const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");
const ProgressEvent = @import("../event/ProgressEvent.zig");

const Execution = js.Execution;

const XMLHttpRequestEventTarget = @This();

pub const Proto = EventTarget;

_type: Type,
_proto: *EventTarget,

pub const Type = union(enum) {
    request: *@import("XMLHttpRequest.zig"),
    upload: *@import("XMLHttpRequestUpload.zig"),
};

pub fn asEventTarget(self: *XMLHttpRequestEventTarget) *EventTarget {
    return self._proto;
}

pub fn dispatch(self: *XMLHttpRequestEventTarget, comptime event_type: DispatchType, progress_: ?Progress, exec: *const Execution) !void {
    const typ = comptime switch (event_type) {
        .abort => "abort",
        .err => "error",
        .load => "load",
        .load_end => "loadend",
        .load_start => "loadstart",
        .progress => "progress",
        .timeout => "timeout",
    };

    const progress = progress_ orelse Progress{};
    const event = (try ProgressEvent.initTrusted(
        comptime .wrap(typ),
        .{
            .total = progress.total,
            .loaded = progress.loaded,
            .lengthComputable = progress.length_computable,
        },
        exec.page,
    )).asEvent();

    // No handler is passed by hand: `onload` and friends sit in the listener
    // list, in the place each was set (see handler_property).
    return exec.dispatch(
        self.asEventTarget(),
        event,
        null,
        .{ .context = "XHR " ++ typ },
    );
}

const DispatchType = enum {
    abort,
    err,
    load,
    load_end,
    load_start,
    progress,
    timeout,
};

const Progress = struct {
    loaded: usize = 0,
    total: usize = 0,
    length_computable: bool = false,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequestEventTarget);

    pub const Meta = struct {
        pub const name = "XMLHttpRequestEventTarget";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn handler(comptime which: @import("../global_event_handlers.zig").Handler) type {
        return @import("../handler_property.zig").accessors(XMLHttpRequestEventTarget, which);
    }

    pub const onloadstart = bridge.accessor(handler(.onloadstart).get, handler(.onloadstart).set, .{});
    pub const onprogress = bridge.accessor(handler(.onprogress).get, handler(.onprogress).set, .{});
    pub const onabort = bridge.accessor(handler(.onabort).get, handler(.onabort).set, .{});
    pub const onerror = bridge.accessor(handler(.onerror).get, handler(.onerror).set, .{});
    pub const onload = bridge.accessor(handler(.onload).get, handler(.onload).set, .{});
    pub const ontimeout = bridge.accessor(handler(.ontimeout).get, handler(.ontimeout).set, .{});
    pub const onloadend = bridge.accessor(handler(.onloadend).get, handler(.onloadend).set, .{});
};
