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
const lp = @import("lightpanda");
const URL = @import("../URL.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const log = lp.log;

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

pub const Proto = EventTarget;

const NavigationKind = @import("root.zig").NavigationKind;
const NavigationActivation = @import("NavigationActivation.zig");
const NavigationTransition = @import("NavigationTransition.zig");
const NavigationState = @import("root.zig").NavigationState;

const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");
const NavigationCurrentEntryChangeEvent = @import("../event/NavigationCurrentEntryChangeEvent.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

/// The joint session history, shared by every frame in the session. The
/// Navigation objects in front of it are per-frame -- Chrome's window.navigation
/// is per-window, and a child that shares its parent's object also shares the
/// parent's realm, which is how a child's navigate() ends up moving the parent.
pub const State = struct {
    _current_navigation_kind: ?NavigationKind = null,

    _index: usize = 0,
    // Need to be stable pointers, because Events can reference entries.
    _entries: std.ArrayList(*NavigationHistoryEntry) = .empty,
    _next_entry_id: usize = 0,
    _activation: ?NavigationActivation = null,
};

_proto: *EventTarget,

_state: *State,

pub fn asEventTarget(self: *Navigation) *EventTarget {
    return self._proto;
}

pub fn getActivation(self: *const Navigation) ?NavigationActivation {
    return self._state._activation;
}

pub fn getCanGoBack(self: *const Navigation) bool {
    return self._state._index > 0;
}

pub fn getCanGoForward(self: *const Navigation) bool {
    return self._state._entries.items.len > self._state._index + 1;
}

pub fn getCurrentEntryOrNull(self: *Navigation) ?*NavigationHistoryEntry {
    if (self._state._entries.items.len > self._state._index) {
        return self._state._entries.items[self._state._index];
    } else return null;
}

pub fn getCurrentEntry(self: *Navigation) *NavigationHistoryEntry {
    // This should never fail. An entry should always be created before
    // we run the scripts on the frame we are loading.
    const len = self._state._entries.items.len;
    lp.assert(len > 0, "Navigation.getCurrentEntry", .{ .len = len });

    return self.getCurrentEntryOrNull().?;
}

pub fn getTransition(_: *const Navigation) ?*NavigationTransition {
    // For now, all transitions are just considered complete.
    return null;
}

const NavigationReturn = struct {
    committed: js.Promise.Global,
    finished: js.Promise.Global,
};

pub fn back(self: *Navigation, frame: *Frame) !NavigationReturn {
    if (!self.getCanGoBack()) {
        return error.InvalidStateError;
    }

    const new_index = self._state._index - 1;
    const next_entry = self._state._entries.items[new_index];

    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, frame);
}

pub fn entries(self: *const Navigation) []*NavigationHistoryEntry {
    return self._state._entries.items;
}

pub fn forward(self: *Navigation, frame: *Frame) !NavigationReturn {
    if (!self.getCanGoForward()) {
        return error.InvalidStateError;
    }

    const new_index = self._state._index + 1;
    const next_entry = self._state._entries.items[new_index];

    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, frame);
}

pub fn updateEntries(
    self: *Navigation,
    url: [:0]const u8,
    kind: NavigationKind,
    frame: *Frame,
    should_dispatch: bool,
) !void {
    switch (kind) {
        .replace => |state| {
            _ = try self.replaceEntry(url, .{ .source = .navigation, .value = state }, frame, should_dispatch);
        },
        .push => |state| {
            _ = try self.pushEntry(url, .{ .source = .navigation, .value = state }, frame, should_dispatch);
        },
        .traverse => |index| {
            self._state._index = index;
        },
        .reload => {},
    }
}

// This is for after true navigation processing, where we need to ensure that our entries are up to date.
//
// This is only really safe to run in the `frameDoneCallback`
// where we can guarantee that the URL and NavigationKind are correct.
pub fn commitNavigation(self: *Navigation, frame: *Frame) !void {
    const url = frame.url;

    var kind: NavigationKind = self._state._current_navigation_kind orelse .{ .push = null };
    defer self._state._current_navigation_kind = null;

    const from_entry = self.getCurrentEntryOrNull();
    if (from_entry == null) {
        kind = .{ .push = null };
    }

    try self.updateEntries(url, kind, frame, false);

    self._state._activation = NavigationActivation{
        ._from = from_entry,
        ._entry = self.getCurrentEntry(),
        ._type = kind.toNavigationType(),
    };
}

/// Pushes an entry into the Navigation stack WITHOUT actually navigating to it.
/// For that, use `navigate`.
pub fn pushEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    frame: *Frame,
    should_dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = frame._session.arena;
    const url = try arena.dupeZ(u8, _url);

    // truncates our history here.
    const retained_index = self._state._index + 1;
    var disposed: []*NavigationHistoryEntry = &.{};
    if (self._state._entries.items.len > retained_index) {
        disposed = try frame.call_arena.dupe(
            *NavigationHistoryEntry,
            self._state._entries.items[retained_index..],
        );
        self._state._entries.shrinkRetainingCapacity(retained_index);
    }

    // Per spec, dispose fires last: after the entry list is updated and
    // currententrychange has been dispatched. These entries are already out
    // of _entries, so fire even if a later step fails, and don't let one
    // entry's failure skip the others.
    defer for (disposed) |d| {
        d.fireDispose(frame) catch |err| {
            log.warn(.event, "NavigationHistoryEntry.dispose", .{ .err = err });
        };
    };

    const index = self._state._entries.items.len;

    const id = self._state._next_entry_id;
    self._state._next_entry_id += 1;

    const id_str = try std.fmt.allocPrint(arena.allocator(), "{d}", .{id});

    const entry = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .navigation_history_entry },
        NavigationHistoryEntry{
            ._proto = undefined,
            ._id = id_str,
            ._key = id_str,
            ._url = url,
            ._state = state,
        },
    });

    // we don't always have a current entry...
    const previous = if (self._state._entries.items.len > 0) self.getCurrentEntry() else null;
    try self._state._entries.append(arena.allocator(), entry);
    self._state._index = index;

    if (previous != null and should_dispatch) {
        if (frame.hasDirectListeners(self.asEventTarget(), "currententrychange", null)) {
            const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
                .wrap("currententrychange"),
                .{ .from = previous.?, .navigationType = @tagName(.push) },
                frame,
            )).asEvent();
            try self.dispatch(event, frame);
        }
    }

    return entry;
}

pub fn replaceEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    frame: *Frame,
    should_dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = frame._session.arena;
    const url = try arena.dupeZ(u8, _url);

    const previous = self.getCurrentEntry();

    const id = self._state._next_entry_id;
    self._state._next_entry_id += 1;
    const id_str = try std.fmt.allocPrint(arena.allocator(), "{d}", .{id});

    const entry = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .navigation_history_entry },
        NavigationHistoryEntry{
            ._proto = undefined,
            ._id = id_str,
            ._key = previous._key,
            ._url = url,
            ._state = state,
        },
    });

    const old_entry = self._state._entries.items[self._state._index];
    self._state._entries.items[self._state._index] = entry;

    // Per spec, dispose fires last, after currententrychange. old_entry is
    // already out of _entries, so fire even if the dispatch below fails.
    defer old_entry.fireDispose(frame) catch |err| {
        log.warn(.event, "NavigationHistoryEntry.dispose", .{ .err = err });
    };

    if (should_dispatch) {
        if (frame.hasDirectListeners(self.asEventTarget(), "currententrychange", null)) {
            const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
                .wrap("currententrychange"),
                .{ .from = previous, .navigationType = @tagName(.replace) },
                frame,
            )).asEvent();
            try self.dispatch(event, frame);
        }
    }

    return entry;
}

const NavigateOptions = struct {
    state: ?js.Value = null,
    info: ?js.Value = null,
    history: ?[]const u8 = null,
};

pub fn navigateInner(
    self: *Navigation,
    _url: ?[:0]const u8,
    kind: NavigationKind,
    frame: *Frame,
) !NavigationReturn {
    const arena = frame._session.arena;
    const url = _url orelse return error.MissingURL;

    // https://github.com/WICG/navigation-api/issues/95
    //
    // These will only settle on same-origin navigation (mostly intended for SPAs).
    // It is fine (and expected) for these to not settle on cross-origin requests :)
    const local = frame.js.local.?;
    const committed = local.createPromiseResolver();
    const finished = local.createPromiseResolver();

    var new_url = try URL.resolve(arena.allocator(), frame.url, url, .{});
    const is_same_document = URL.eqlDocument(new_url, frame.url);

    // In case of navigation to the same document, we force an url duplication.
    // Keeping the same url generates a crash during WPT test navigate-history-push-same-url.html.
    // When building a script's src, script's base and frame url overlap.
    if (is_same_document) {
        new_url = try arena.dupeZ(u8, new_url);
    }

    // Captured before the switch overwrites frame.url in the same_document
    // branches; used to queue the hashchange once below.
    const old_url = frame.url;

    const previous = self.getCurrentEntry();

    switch (kind) {
        .push => |state| {
            if (is_same_document) {
                frame.url = new_url;

                committed.resolve("navigation push", {});
                // todo: Fire navigate event
                finished.resolve("navigation push", {});

                _ = try self.pushEntry(url, .{ .source = .navigation, .value = state }, frame, true);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .replace => |state| {
            if (is_same_document) {
                frame.url = new_url;

                committed.resolve("navigation replace", {});
                // todo: Fire navigate event
                finished.resolve("navigation replace", {});

                _ = try self.replaceEntry(url, .{ .source = .navigation, .value = state }, frame, true);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .traverse => |index| {
            self._state._index = index;

            if (is_same_document) {
                frame.url = new_url;

                committed.resolve("navigation traverse", {});
                // todo: Fire navigate event
                finished.resolve("navigation traverse", {});
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .reload => {
            try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
        },
    }

    if (is_same_document and !std.mem.eql(u8, old_url, new_url)) {
        try frame.queueHashChange(old_url, new_url);
    }

    if (frame.hasDirectListeners(self.asEventTarget(), "currententrychange", null)) {
        // If we haven't navigated off, let us fire off an a currententrychange.
        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = @tagName(kind) },
            frame,
        )).asEvent();
        try self.dispatch(event, frame);
    }

    _ = try committed.persist();
    _ = try finished.persist();
    return .{
        .committed = try committed.promise().persist(),
        .finished = try finished.promise().persist(),
    };
}

pub fn navigate(self: *Navigation, _url: [:0]const u8, _opts: ?NavigateOptions, frame: *Frame) !NavigationReturn {
    const arena = frame._session.arena;
    const opts = _opts orelse NavigateOptions{};
    const json = if (opts.state) |state| state.toJson(arena.allocator()) catch return error.DataClone else null;

    const kind: NavigationKind = if (opts.history) |history|
        if (std.mem.eql(u8, "replace", history)) .{ .replace = json } else .{ .push = json }
    else
        .{ .push = json };

    return try self.navigateInner(_url, kind, frame);
}

pub const ReloadOptions = struct {
    state: ?js.Value = null,
    info: ?js.Value = null,
};

pub fn reload(self: *Navigation, _opts: ?ReloadOptions, frame: *Frame) !NavigationReturn {
    const arena = frame._session.arena;

    const opts = _opts orelse ReloadOptions{};
    const entry = self.getCurrentEntry();
    if (opts.state) |state| {
        const previous = entry;
        entry._state = .{ .source = .navigation, .value = state.toJson(arena.allocator()) catch return error.DataClone };

        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = @tagName(.reload) },
            frame,
        )).asEvent();
        try self.dispatch(event, frame);
    }

    return self.navigateInner(entry._url, .reload, frame);
}

pub const TraverseToOptions = struct {
    info: ?js.Value = null,
};

pub fn traverseTo(self: *Navigation, key: []const u8, _opts: ?TraverseToOptions, frame: *Frame) !NavigationReturn {
    if (_opts != null) {
        log.warn(.not_implemented, "Navigation.traverseTo", .{ .has_options = true });
    }

    for (self._state._entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, key, entry._key)) {
            return try self.navigateInner(entry._url, .{ .traverse = i }, frame);
        }
    }

    return error.InvalidStateError;
}

pub const UpdateCurrentEntryOptions = struct {
    state: js.Value,
};

pub fn updateCurrentEntry(self: *Navigation, options: UpdateCurrentEntryOptions, frame: *Frame) !void {
    const arena = frame._session.arena;

    const previous = self.getCurrentEntry();
    self.getCurrentEntry()._state = .{
        .source = .navigation,
        .value = options.state.toJson(arena.allocator()) catch return error.DataClone,
    };

    if (frame.hasDirectListeners(self.asEventTarget(), "currententrychange", null)) {
        const event = (try NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{ .from = previous, .navigationType = null },
            frame,
        )).asEvent();
        try self.dispatch(event, frame);
    }
}

pub fn dispatch(self: *Navigation, event: *Event, frame: *Frame) !void {
    return frame.dispatch(self.asEventTarget(), event, null, .{ .context = "Navigation" });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigation);

    pub const Meta = struct {
        pub const name = "Navigation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's order: the attributes, then the four handlers, then the
    // operations alphabetically.
    pub const currentEntry = bridge.accessor(Navigation.getCurrentEntry, null, .{});
    pub const transition = bridge.accessor(Navigation.getTransition, null, .{});
    pub const activation = bridge.accessor(Navigation.getActivation, null, .{});
    pub const canGoBack = bridge.accessor(Navigation.getCanGoBack, null, .{});
    pub const canGoForward = bridge.accessor(Navigation.getCanGoForward, null, .{});
    pub const onnavigate = bridge.accessor(handlerProperty(Navigation, .onnavigate).get, handlerProperty(Navigation, .onnavigate).set, .{});
    pub const onnavigatesuccess = bridge.accessor(handlerProperty(Navigation, .onnavigatesuccess).get, handlerProperty(Navigation, .onnavigatesuccess).set, .{});
    pub const onnavigateerror = bridge.accessor(handlerProperty(Navigation, .onnavigateerror).get, handlerProperty(Navigation, .onnavigateerror).set, .{});
    pub const oncurrententrychange = bridge.accessor(handlerProperty(Navigation, .oncurrententrychange).get, handlerProperty(Navigation, .oncurrententrychange).set, .{});
    pub const back = bridge.function(Navigation.back, .{});
    pub const entries = bridge.function(Navigation.entries, .{});
    pub const forward = bridge.function(Navigation.forward, .{});
    pub const navigate = bridge.function(Navigation.navigate, .{});
    pub const reload = bridge.function(Navigation.reload, .{});
    pub const traverseTo = bridge.function(Navigation.traverseTo, .{});
    pub const updateCurrentEntry = bridge.function(Navigation.updateCurrentEntry, .{});
};

const testing = @import("../../../testing.zig");

test "Navigation: about:blank commits entry" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // The test_session is shared; prior tests leak entries into it via
    // session.navigation_state. Reset it so we exercise a fresh session-style state.
    testing.test_session.navigation_state._entries.clearRetainingCapacity();
    testing.test_session.navigation_state._index = 0;

    try frame.navigate("about:blank", .{});
    try testing.waitForFrame();

    // about:blank / blob: handling in Frame.navigate bypasses rameDoneCallback,
    // so commitNavigation never runs and _entries stays empty. Reading
    // `navigation.currentEntry` from JS then hits the `lp.assert(len > 0, ...)`
    // in Navigation.getCurrentEntry
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const result = try ls.local.exec(
        "navigation.currentEntry.url === 'about:blank'",
        "Navigation.test",
    );
    try testing.expect(result.isTrue());
}

test "Navigation: reload on empty stack seeds an entry" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    testing.test_session.navigation_state._entries.clearRetainingCapacity();
    testing.test_session.navigation_state._index = 0;

    // Mirrors CDP Page.reload arriving on a fresh session: doReload reads
    // frame.url (default "about:blank") and routes through the synchronous
    // about:blank commit with kind=.reload. updateEntries is a no-op for
    // .reload, so without the empty-stack guard this would assert
    // `len: 0` in getCurrentEntry.
    try frame.navigate("about:blank", .{ .kind = .reload });
    try testing.waitForFrame();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const result = try ls.local.exec(
        "navigation.currentEntry.url === 'about:blank'",
        "Navigation.test",
    );
    try testing.expect(result.isTrue());
}
