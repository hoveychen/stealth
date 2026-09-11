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

const js = @import("../js/js.zig");
const Performance = @import("Performance.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ PerformanceObserver, EntryList };
}

/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceObserver
const PerformanceObserver = @This();

/// Emitted when there are events with same interests.
_callback: js.Function.Global,
/// The threshold to deliver `PerformanceEventTiming` entries.
_duration_threshold: f64,
/// Entry types we're looking for are encoded as bit flags.
_interests: u16,
/// Fixed by the first observe(): a `type` observer can't later observe
/// `entryTypes`, nor the reverse.
_mode: enum { unset, single, multiple } = .unset,
/// Entries this observer hold.
/// Don't mutate these; other observers may hold pointers to them.
_entries: std.ArrayList(*Performance.Entry),
/// The Performance that owns this observer (Window's or Worker's).
_performance: *Performance,
/// JS context the observer's callback was created in. Captured at init so
/// dispatch() can enter the right scope without needing an Execution.
_js: *js.Context,
/// Long-lived arena (Frame's or WorkerGlobalScope's) for entry list growth
/// and takeRecords' returned slice.
_arena: Allocator,

const DefaultDurationThreshold: f64 = 104;

/// Creates a new PerformanceObserver object with the given observer callback.
pub fn init(callback: js.Function.Global, exec: *const Execution) !*PerformanceObserver {
    return exec._factory.create(PerformanceObserver{
        ._callback = callback,
        ._duration_threshold = DefaultDurationThreshold,
        ._interests = 0,
        ._entries = .empty,
        ._performance = exec.performance(),
        ._js = exec.js,
        ._arena = exec.arena,
    });
}

const ObserveOptions = struct {
    buffered: bool = false,
    durationThreshold: f64 = DefaultDurationThreshold,
    entryTypes: ?[]const []const u8 = null,
    type: ?[]const u8 = null,
};

pub fn observe(self: *PerformanceObserver, maybe_options: ?ObserveOptions, exec: *const Execution) !void {
    const options: ObserveOptions = maybe_options orelse .{};
    // Update threshold.
    self._duration_threshold = @max(@floor(options.durationThreshold / 8) * 8, 16);

    const entry_types: []const []const u8 = blk: {
        // More likely.
        if (options.type) |entry_type| {
            // Can't have both.
            if (options.entryTypes != null) {
                return error.TypeError;
            }
            if (self._mode == .multiple) {
                return error.InvalidModification;
            }
            self._mode = .single;
            break :blk &.{entry_type};
        }

        if (options.entryTypes) |entry_types| {
            // The spec wants a TypeError when `buffered` (or
            // `durationThreshold`) is used with entryTypes. But neither firefox
            // nor Chrome throw (Chrome does log an warning). They ignore it.
            if (self._mode == .single) {
                return error.InvalidModification;
            }
            self._mode = .multiple;
            break :blk entry_types;
        }

        const isolate = exec.js.isolate;
        _ = isolate.throwException(isolate.createTypeError(
            "Failed to execute 'observe' on 'PerformanceObserver': " ++
                "An observe() call must include either entryTypes or type arguments.",
        ));
        return error.JsException;
    };

    // Update entries.
    var interests: u16 = 0;
    for (entry_types) |entry_type| {
        const fields = @typeInfo(Performance.Entry.Type.Enum).@"enum".fields;
        inline for (fields) |field| {
            if (std.mem.eql(u8, field.name, entry_type)) {
                const flag = @as(u16, 1) << @as(u16, field.value);
                interests |= flag;
            }
        }
    }

    // Nothing has updated; no need to go further.
    if (interests == 0) {
        return;
    }

    // If we had no interests before, it means the Performance is not aware
    // of this observer.
    if (self._interests == 0) {
        try self._performance.registerObserver(self, exec);
    }

    // Update interests.
    self._interests = interests;

    // Deliver existing entries if buffered option is set (only honoured
    // with `type`, see above). Delivery is async via a queued task.
    if (options.buffered and options.type != null and !self.hasRecords()) {
        for ([_][]const *Performance.Entry{ self._performance._entries.items, self._performance._resources.items }) |list| {
            for (list) |entry| {
                if (self.interested(entry)) {
                    try self._entries.append(self._arena, entry);
                }
            }
        }
        if (self.hasRecords()) {
            try self._performance.scheduleDelivery();
        }
    }
}

pub fn disconnect(self: *PerformanceObserver) void {
    self._performance.unregisterObserver(self);
    // Reset observer.
    self._duration_threshold = DefaultDurationThreshold;
    self._interests = 0;
    self._entries.clearRetainingCapacity();
}

/// Returns the current list of PerformanceEntry objects
/// stored in the performance observer, emptying it out.
pub fn takeRecords(self: *PerformanceObserver) ![]*Performance.Entry {
    // Use the long-lived arena instead of call_arena because this slice is
    // wrapped in EntryList and may be accessed later.
    const records = try self._arena.dupe(*Performance.Entry, self._entries.items);
    self._entries.clearRetainingCapacity();
    return records;
}

/// Chrome's fifteen, in Chrome's order, which is alphabetical (measured on
/// Chrome 151, probes/performance-entry-types.js). Note what is *not* here:
/// `taskattribution` is a real entryType with a real interface, but Chrome
/// leaves it off this list.
///
/// `interaction-contentful-paint` and `soft-navigation` are advertised without
/// anything ever queueing one -- Chrome's own buffers for both are empty on a
/// plain page too (measured), and their interfaces are already on the window
/// here (see timing.zig's "Prototype surface only" block). So the list is the
/// only place the two names show, and leaving them out made this list two
/// entries short of every real Chrome.
pub fn getSupportedEntryTypes() js.FrozenArray([]const u8) {
    return .{ .items = &.{
        "element",
        "event",
        "first-input",
        "interaction-contentful-paint",
        "largest-contentful-paint",
        "layout-shift",
        "long-animation-frame",
        "longtask",
        "mark",
        "measure",
        "navigation",
        "paint",
        "resource",
        "soft-navigation",
        "visibility-state",
    } };
}

/// Returns true if observer interested with given entry.
pub fn interested(
    self: *const PerformanceObserver,
    entry: *const Performance.Entry,
) bool {
    return self.interestedIn(entry._type);
}

pub fn interestedIn(self: *const PerformanceObserver, kind: Performance.Entry.Type.Enum) bool {
    const flag = @as(u16, 1) << @intCast(@intFromEnum(kind));
    return self._interests & flag != 0;
}

pub inline fn hasRecords(self: *const PerformanceObserver) bool {
    return self._entries.items.len > 0;
}

/// Runs the PerformanceObserver's callback with records; emptying it out.
pub fn dispatch(self: *PerformanceObserver) !void {
    const records = try self.takeRecords();

    var ls: js.Local.Scope = undefined;
    self._js.localScope(&ls);
    defer ls.deinit();

    var caught: js.TryCatch.Caught = .{};
    ls.toLocal(self._callback).tryCall(void, .{ EntryList{ ._entries = records }, self }, &caught) catch |err| {
        log.err(.frame, "PerfObserver.dispatch", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PerformanceObserver);

    pub const Meta = struct {
        pub const name = "PerformanceObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PerformanceObserver.init, .{});

    // Chrome's prototype order (measured), which is not the order a reader
    // would pick: disconnect first, then observe.
    pub const disconnect = bridge.function(PerformanceObserver.disconnect, .{});
    pub const observe = bridge.function(PerformanceObserver.observe, .{});
    pub const takeRecords = bridge.function(PerformanceObserver.takeRecords, .{});
    pub const supportedEntryTypes = bridge.accessor(PerformanceObserver.getSupportedEntryTypes, null, .{ .static = true });
};

/// List of performance events that were explicitly
/// observed via the observe() method.
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceObserverEntryList
pub const EntryList = struct {
    _entries: []*Performance.Entry,

    pub fn getEntries(self: *const EntryList) []const *Performance.Entry {
        return self._entries;
    }

    pub fn getEntriesByType(self: *const EntryList, entry_type: []const u8, exec: *Execution) ![]const *Performance.Entry {
        const kind = Performance.Entry.Type.Enum.parse(entry_type) orelse return &.{};
        return Performance.filterEntriesByType(exec.local_arena, self._entries, kind);
    }

    pub fn getEntriesByName(self: *const EntryList, name: []const u8, entry_type: ?[]const u8, exec: *Execution) ![]const *Performance.Entry {
        const kind = if (entry_type) |t| (Performance.Entry.Type.Enum.parse(t) orelse return &.{}) else null;
        return Performance.filterEntriesByName(exec.local_arena, self._entries, name, kind);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(EntryList);

        pub const Meta = struct {
            pub const name = "PerformanceObserverEntryList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getEntries = bridge.function(EntryList.getEntries, .{});
        pub const getEntriesByName = bridge.function(EntryList.getEntriesByName, .{});
        pub const getEntriesByType = bridge.function(EntryList.getEntriesByType, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: PerformanceObserver" {
    try testing.htmlRunner("performance_observer", .{});
}
