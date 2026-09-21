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

const std = @import("std");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const PopStateEvent = @import("event/PopStateEvent.zig");

const History = @This();

const ScrollRestoration = enum { auto, manual };

_scroll_restoration: ScrollRestoration = .auto,

pub fn getLength(_: *const History, frame: *Frame) u32 {
    return @intCast(frame._navigation._state._entries.items.len);
}

pub fn getState(_: *const History, frame: *Frame) !?js.Value {
    if (frame._navigation.getCurrentEntry()._state.value) |state| {
        const value = try frame.js.local.?.parseJSON(state);
        return value;
    } else return null;
}

pub fn getScrollRestoration(self: *History) []const u8 {
    return @tagName(self._scroll_restoration);
}

pub fn setScrollRestoration(self: *History, str: []const u8) void {
    if (std.meta.stringToEnum(ScrollRestoration, str)) |sr| {
        self._scroll_restoration = sr;
    }
}

/// Resolves the `url` argument of pushState/replaceState and refuses it when it
/// leaves the document's origin, which is what the spec's "can have its URL
/// rewritten" step says and what Blink throws a SecurityError for.
///
/// Not a pedantic detail: a Cloudflare guard calls
/// `replaceState({}, '', 'https://example.org/')` from inside the challenge
/// widget and branches on whether it throws. Without this check the call
/// succeeded here AND retargeted the widget's own `location.href` at
/// example.org, so the guard then issued a second call to put the real URL
/// back -- a two-call signature no browser produces (measured 3/3 on both
/// arms, scratch/s70/w-*.json).
///
/// A frame with no origin (about:blank, and anything else that never committed
/// a network document) is left alone: there is nothing to compare against, and
/// the same-URL call such a page makes is legal.
fn stateUrl(frame: *Frame, _url: ?[]const u8, comptime method: []const u8) ![:0]const u8 {
    const arena = frame._session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena.allocator(), frame.url, u, .{})
    else
        return try arena.dupeZ(u8, frame.url);

    if (frame.origin) |origin| {
        if (!@import("../URL.zig").isSameOrigin(url, origin)) {
            return frame.js.fail(error.SecurityError, try std.fmt.allocPrint(
                frame.call_arena,
                "Failed to execute '" ++ method ++ "' on 'History': A history state object with URL '{s}' cannot be created in a document with origin '{s}' and URL '{s}'.",
                .{ url, origin, frame.url },
            ));
        }
    }
    return url;
}

/// The state argument is structured-serialised, not JSON-stringified, so a
/// value JSON quietly drops or flattens -- a function, a DOM node, `location`,
/// `document` -- is a DataCloneError rather than `{}`. We keep the JSON for
/// storage and run the serialiser only for its verdict; `serialize` raises the
/// exception itself, with Blink's own sentence after this prefix.
///
/// Measured order: Chrome answers `replaceState(document, '', <cross-origin>)`
/// with DataCloneError, so this runs before the URL check.
fn checkCloneable(state: js.Value, comptime method: []const u8) !void {
    const serialized = try state.serialize("Failed to execute '" ++ method ++ "' on 'History': ");
    serialized.deinit();
}

pub fn pushState(_: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, frame: *Frame) !void {
    const session = frame._session;
    const arena = session.arena;
    try checkCloneable(state, "pushState");
    const url = try stateUrl(frame, _url, "pushState");

    const json = state.toJson(arena.allocator()) catch return error.DataClone;
    _ = try frame._navigation.pushEntry(url, .{ .source = .history, .value = json }, frame, true);

    frame.url = url;
    // setHref == reinitializing.
    try frame.window._location._url.setHref(url, &frame.js.execution);
    // `:target` matches off the fragment, which the new URL can change.
    frame.styleChanged();

    session.notification.dispatch(.frame_navigated_within_document, &.{
        .url = url,
        .frame_id = frame._frame_id,
        .navigation_type = .historyApi,
    });
}

pub fn replaceState(_: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, frame: *Frame) !void {
    const session = frame._session;
    const arena = session.arena;
    try checkCloneable(state, "replaceState");
    const url = try stateUrl(frame, _url, "replaceState");

    const json = state.toJson(arena.allocator()) catch return error.DataClone;
    _ = try frame._navigation.replaceEntry(url, .{ .source = .history, .value = json }, frame, true);

    frame.url = url;
    // setHref == reinitializing.
    try frame.window._location._url.setHref(url, &frame.js.execution);
    // `:target` matches off the fragment, which the new URL can change.
    frame.styleChanged();

    session.notification.dispatch(.frame_navigated_within_document, &.{
        .url = url,
        .frame_id = frame._frame_id,
        .navigation_type = .historyApi,
    });
}

fn goInner(delta: i32, frame: *Frame) !void {
    // 0 behaves the same as no argument, both reloading the frame.

    const current = frame._navigation._state._index;
    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s > frame._navigation._state._entries.items.len - 1) {
        return;
    }

    const index = @as(usize, @intCast(index_s));
    const entry = frame._navigation._state._entries.items[index];

    if (entry._url) |url| {
        if (frame.isSameOrigin(url)) {
            const target = frame.window.asEventTarget();
            if (frame._event_manager.hasDirectListeners(target, "popstate", null)) {
                const event = (try PopStateEvent.initTrusted(comptime .wrap("popstate"), .{ .state = entry._state.value }, frame)).asEvent();
                try frame._event_manager.dispatchDirect(target, event, null, .{ .context = "Pop State" });
            }
            // hashchange is queued by navigateInner.
        }
    }

    _ = try frame._navigation.navigateInner(entry._url, .{ .traverse = index }, frame);
}

pub fn back(_: *History, frame: *Frame) !void {
    try goInner(-1, frame);
}

pub fn forward(_: *History, frame: *Frame) !void {
    try goInner(1, frame);
}

pub fn go(_: *History, delta: ?i32, frame: *Frame) !void {
    try goInner(delta orelse 0, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(History);

    pub const Meta = struct {
        pub const name = "History";
        pub var class_id: bridge.ClassId = 0;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const length = bridge.accessor(History.getLength, null, .{});
    pub const scrollRestoration = bridge.accessor(History.getScrollRestoration, History.setScrollRestoration, .{});
    pub const state = bridge.accessor(History.getState, null, .{});
    pub const back = bridge.function(History.back, .{});
    pub const forward = bridge.function(History.forward, .{});
    pub const go = bridge.function(History.go, .{});
    // WebIDL makes both `data` and `unused` required, so these take two --
    // Chrome 151 reports length 2 and refuses a one-argument call. The Zig
    // signature has the unused title optional, which derived 1.
    pub const pushState = bridge.function(History.pushState, .{ .arity = 2 });
    pub const replaceState = bridge.function(History.replaceState, .{ .arity = 2 });
};

const testing = @import("../../testing.zig");
test "WebApi: History" {
    try testing.htmlRunner("history.html", .{});
    try testing.htmlRunner("history_url_update.html", .{});
}
