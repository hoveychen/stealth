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

// zlint-disable unused-decls
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");
const MediaQuery = @import("../../css/MediaQuery.zig");
const Window = @import("../Window.zig");

const MediaQueryList = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_media: []const u8,

/// The query as the page wrote it. `_media` is the canonical form and it is
/// LOSSY -- a number in it is written to six significant figures -- so it is
/// what `media` reports and never what `matches` reads. A guard bisecting
/// `devicePixelRatio` walks past the sixth figure within a dozen steps.
_query: []const u8,

pub fn deinit(self: *MediaQueryList) void {
    _ = self;
}

pub fn asEventTarget(self: *MediaQueryList) *EventTarget {
    return self._proto;
}

pub fn getMedia(self: *const MediaQueryList) []const u8 {
    return self._media;
}

/// Re-evaluates the stored query against the current viewport on every call
/// so the result stays in sync with viewport emulation. The viewport is the
/// frame's own -- the page's for the top-level frame (overridable via
/// Emulation.setDeviceMetricsOverride), the `<iframe>` element's box for a child
/// -- matching `Window.innerWidth` / `innerHeight`. A `(max-width: 400px)` query
/// matches inside a 300x65 frame on a 1920-wide page, measured on Chrome 151.
pub fn getMatches(self: *const MediaQueryList, frame: *Frame) bool {
    return MediaQuery.matches(self._query, frame.viewport());
}

// TODO: `change` events need to fire on every listener registered here (and
// via `addEventListener("change", ...)` through the EventTarget proto) when a
// viewport override crosses the breakpoint that flips `matches`. Today these
// registrations are no-ops rather than stored hooks.
pub fn addListener(_: *const MediaQueryList, _: js.Function) void {}
pub fn removeListener(_: *const MediaQueryList, _: js.Function) void {}

/// Measured on Chrome 150: MediaQueryList.prototype carries `onchange`, between
/// `matches` and `addListener`. It goes through the frame's attribute-listener
/// store, the same mechanism Document and Element use, so a plain
/// `dispatchEvent(new MediaQueryListEvent('change'))` reaches it.
fn handlerAccessor(comptime handler: @import("../global_event_handlers.zig").Handler) type {
    return struct {
        pub fn get(self: *MediaQueryList, frame: *Frame) ?js.Function.Global {
            return frame.getEventHandler(self.asEventTarget(), handler);
        }

        pub fn set(self: *MediaQueryList, setter: ?Window.FunctionSetter, frame: *Frame) !void {
            return frame.setEventHandler(self.asEventTarget(), handler, Window.getFunctionFromSetter(setter));
        }
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaQueryList);

    pub const Meta = struct {
        pub const name = "MediaQueryList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const media = bridge.accessor(MediaQueryList.getMedia, null, .{});
    pub const matches = bridge.accessor(MediaQueryList.getMatches, null, .{});
    pub const onchange = bridge.accessor(handlerAccessor(.onchange).get, handlerAccessor(.onchange).set, .{});
    pub const addListener = bridge.function(MediaQueryList.addListener, .{ .noop = true });
    pub const removeListener = bridge.function(MediaQueryList.removeListener, .{ .noop = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaQueryList" {
    try testing.htmlRunner("css/media_query_list.html", .{});
}

test "WebApi: media @-rule cascade" {
    try testing.htmlRunner("css/media_at_rule_cascade.html", .{});
}

test "WebApi: CSS events" {
    try testing.htmlRunner("css/css_events.html", .{});
}
