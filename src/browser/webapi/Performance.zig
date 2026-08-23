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

const EventCounts = @import("EventCounts.zig");
const PerformanceObserver = @import("PerformanceObserver.zig");
const timing = @import("performance/timing.zig");
const http = @import("../../network/http.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, Mark, Measure, MemoryInfo, PerformanceTiming, PerformanceNavigation };
}

const Performance = @This();

_time_origin: u64,

// What `now()` rounds to. One of the two clock_resolution_* constants below,
// per this realm's cross-origin isolation.
_clock_resolution_micros: u64,

// Wall-clock epoch microseconds at the same instant as _time_origin. The
// monotonic clock above is boot-relative, so it can't be turned into a date
// after the fact; `timeOrigin` is defined as this instant, and chrome.csi()
// and chrome.loadTimes() both report the navigation start from it too.
_epoch_origin_micros: i64,
_entries: std.ArrayList(*Entry) = .empty,
_timing: PerformanceTiming = .{},
_navigation: PerformanceNavigation = .{},
_event_counts: EventCounts = .{},

// PerformanceObserver infrastructure. Lives here (rather than on the owning
// Frame/WorkerGlobalScope) so that both contexts get observers for free.
_observers: std.ArrayList(*PerformanceObserver) = .empty,
_delivery_scheduled: bool = false,
_delivering: bool = false,

// The navigation entry. `_nav` is filled in by the Frame as the load passes
// each milestone; `_nav_entry` is the JS-visible object built the first time a
// script asks for the entry list, which reads through to `_nav` so a script
// that grabbed it early still sees the later milestones. Chrome always has
// exactly one of these, so a page that reports none is a tell on its own.
_nav: timing.Timing = .{},
_nav_name: []const u8 = "",

// Shared by every entry this navigation files. Drawn once at navigationStarted
// rather than per entry: see newNavigationId.
_navigation_id: u32 = 0,
_nav_entry: ?*timing.NavigationTiming = null,
_nav_phase: NavPhase = .none,
_paint_entries: bool = false,

// Nothing fires it — the resource buffer never fills because nothing fills it
// — but the accessor pair is on Chrome's Performance.prototype and reads back
// what a script sets.
//
// This is the one handler property still kept in a field. The rest went to the
// event manager's handler store, which is keyed by EventTarget -- and Chrome's
// Performance *is* an EventTarget while this one is not (measured: our
// `performance.addEventListener` is undefined, Chrome's runs). Giving
// Performance that prototype is its own change, with its own measurement.
_on_resource_timing_buffer_full: ?js.Function.Global = null,

/// How far the current navigation has got. Level 2 can read an unreached
/// milestone straight off `_nav` because it is 0 there anyway, but Level 1
/// reports epoch stamps, where 0 and "the epoch origin" are very different
/// answers — and on localhost a milestone can legitimately land within the
/// same rounded millisecond as the origin. So the phase is tracked rather
/// than inferred from the offsets.
pub const NavPhase = enum(u8) {
    none,
    started,
    response,
    response_end,
    interactive,
    content_loaded,
    complete,
};

/// How coarse the clock is, in microseconds, outside a cross-origin isolated
/// realm.
///
/// Every browser clamps this, and which number it clamps to is itself a
/// fingerprint -- the clamp is the resolution a timing attack has to work
/// with, so a page can measure it in a loop of `performance.now()` calls and
/// read the smallest non-zero step straight off. Chrome, outside a
/// cross-origin isolated context, clamps to 100μs; measured on the reference
/// host, its smallest step is exactly that. This was 5μs, which is Firefox's
/// number: finer than the browser this engine claims to be, and finer is not
/// safer here -- it hands a timing attack twenty times the resolution while
/// naming a browser that would not have given it.
pub const clock_resolution_micros = 100;

/// And inside one. Cross-origin isolation is the condition Chrome trades the
/// coarse clock for: a realm that cannot be shared with an untrusted origin
/// gets 5μs, the same number `SharedArrayBuffer` is gated on. Measured on the
/// Cloudflare interstitial, which carries COOP+COEP -- the reference reads
/// 0.004999995 there and 0.1 on the ordinary page that replaces it
/// (`tools/fingerprint/results/p4-oracle.json`).
pub const clock_resolution_isolated_micros = 5;

/// Get high-resolution timestamp in microseconds, clamped to the resolution
/// the claimed browser reports for the realm asking.
pub fn highResTimestamp(resolution_micros: u64) u64 {
    return @intCast(clamp(@intCast(lp.datetime.microTimestamp(.boot)), resolution_micros));
}

/// Round a microsecond stamp to the realm's clock resolution.
fn clamp(micros: i64, resolution_micros: u64) i64 {
    const resolution: i64 = @intCast(resolution_micros);
    const half = @divTrunc(resolution, 2);
    return @divTrunc(micros + half, resolution) * resolution;
}

pub fn init(resolution_micros: u64) Performance {
    return .{
        ._clock_resolution_micros = resolution_micros,
        ._time_origin = highResTimestamp(resolution_micros),
        // Clamped the same way `now()` is: the pair is what a page compares,
        // and a wall-clock origin finer than the monotonic clock beside it
        // would hand back resolution the clamp exists to withhold.
        ._epoch_origin_micros = clamp(lp.datetime.DateTime.now().unix(.microseconds), resolution_micros),
    };
}

/// Follows the realm's cross-origin isolation, which is settled per committed
/// document rather than at birth -- see Frame.commitCrossOriginIsolated.
pub fn setClockResolution(self: *Performance, resolution_micros: u64) void {
    self._clock_resolution_micros = resolution_micros;
}

pub fn getTiming(self: *Performance) *PerformanceTiming {
    return &self._timing;
}

pub fn now(self: *const Performance) f64 {
    const current = highResTimestamp(self._clock_resolution_micros);
    const elapsed = current - self._time_origin;
    // Return as milliseconds with microsecond precision
    return @as(f64, @floatFromInt(elapsed)) / 1000.0;
}

/// Epoch milliseconds, fractional — not the boot-relative clock `now()` counts
/// from. `timeOrigin + now()` is `Date.now()` in every browser, and a page that
/// subtracts the two is asking whether this one is a browser at all.
pub fn getTimeOrigin(self: *const Performance) f64 {
    return @as(f64, @floatFromInt(self._epoch_origin_micros)) / 1000.0;
}

/// The same instant as whole epoch milliseconds, which is the unit chrome.csi()
/// and the Level 1 timing attributes report.
pub fn epochOriginMs(self: *const Performance) i64 {
    return @divFloor(self._epoch_origin_micros, 1000);
}

pub fn getNavigation(self: *Performance) *PerformanceNavigation {
    return &self._navigation;
}

pub fn getEventCounts(self: *Performance) *EventCounts {
    return &self._event_counts;
}

pub fn getMemory(_: *Performance, exec: *const Execution) !*MemoryInfo {
    return memoryInfo(exec);
}

/// V8's live heap numbers, which is what Chrome's performance.memory reports
/// too. A fresh object every read (measured: `performance.memory !==
/// performance.memory`). console.memory hands out the same thing: on Chrome the
/// two share a prototype.
pub fn memoryInfo(exec: *const Execution) !*MemoryInfo {
    const stats = exec.js.isolate.getHeapStatistics();
    return exec._factory.create(MemoryInfo{
        ._total = stats.total_heap_size,
        ._used = stats.used_heap_size,
        // Not V8's own heap_size_limit: ours is sized for this process (1.46 GB
        // measured), a number no Chrome reports. Chrome caps the old space at
        // ~4 GiB on any 64-bit desktop with enough RAM and answered exactly
        // this on the reference machine (win24-chrome.json).
        ._limit = 4395630592,
    });
}

pub fn getInteractionCount(_: *const Performance) u32 {
    return 0;
}

pub fn getOnResourceTimingBufferFull(self: *const Performance) ?js.Function.Global {
    return self._on_resource_timing_buffer_full;
}

pub fn setOnResourceTimingBufferFull(self: *Performance, callback: ?js.Function) !void {
    self._on_resource_timing_buffer_full = if (callback) |c| try c.persist() else null;
}

pub fn clearResourceTimings(self: *Performance) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        if (self._entries.items[i]._type == .resource) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub const Json = struct {
    timeOrigin: f64,
    timing: *PerformanceTiming,
    navigation: *PerformanceNavigation,
};

pub fn toJSON(self: *Performance) Json {
    return .{
        .timeOrigin = self.getTimeOrigin(),
        .timing = &self._timing,
        .navigation = &self._navigation,
    };
}

// --- Navigation timing -----------------------------------------------------
//
// The Frame calls these as the load progresses. They only move numbers around;
// the JS objects are built lazily in ensureImplicitEntries so none of this needs
// an Execution.

/// Chrome tags every performance entry with the navigation it belongs to, and
/// the tag is a small random number rather than a counter: twenty navigations
/// across two tabs of one Chrome 151 answered twenty unrelated values, none
/// outside [1, 10000] and none in sequence with the last (measured; the
/// station's own reading of api.js carries 9894). A counter would leak how many
/// documents this browser has loaded, which is why Chrome does not use one.
fn newNavigationId() u32 {
    var bytes: [4]u8 = undefined;
    lp.io.random(&bytes);
    return std.mem.readInt(u32, &bytes, .little) % 10_000 + 1;
}

pub fn navigationStarted(self: *Performance, url: []const u8, navigation_type: []const u8) void {
    const at = self.now();
    self._nav_name = url;
    self._navigation_id = newNavigationId();
    self._nav = .{
        .navigation_id = self._navigation_id,
        .navigation_type = navigation_type,
        .fetch_start = at,
        .domain_lookup_start = at,
        .domain_lookup_end = at,
        .connect_start = at,
        .connect_end = at,
        .request_start = at,
    };
    self._nav_phase = .started;
}

pub fn navigationResponseStarted(
    self: *Performance,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    next_hop_protocol: []const u8,
    times: http.ResponseTimes,
) void {
    const at = self.now();
    // The document's own connection walk, same as any subresource's. What
    // navigationStarted stamped were placeholders: it had nothing to measure
    // yet, and leaving them said the document resolved and connected in the
    // same instant the navigation began.
    self._nav.setConnectionMilestones(times);
    self._nav.response_start = at;
    self._nav.final_response_headers_start = at;
    self._nav.response_status = status;
    self._nav.content_type = content_type;
    self._nav.content_encoding = content_encoding;
    self._nav.next_hop_protocol = next_hop_protocol;
    self._nav_phase = .response;
}

/// `len` is what the chunk decoded to; `encoded_total` is what the whole body
/// has weighed on the wire so far. They are the same number only for a document
/// the server did not compress, and a document that says so while carrying a
/// Content-Encoding header contradicts its own headers.
pub fn navigationBodyChunk(self: *Performance, len: usize, encoded_total: u64) void {
    self._nav.decoded_body_size += len;
    self._nav.encoded_body_size = encoded_total;
}

pub fn navigationResponseEnded(self: *Performance) void {
    self._nav.response_end = self.now();
    self._nav_phase = .response_end;
}

pub fn navigationInteractive(self: *Performance) void {
    const at = self.now();
    self._nav.dom_interactive = at;
    self._nav.dom_content_loaded_event_start = at;
    self._nav_phase = .interactive;
}

pub fn navigationContentLoaded(self: *Performance) void {
    self._nav.dom_content_loaded_event_end = self.now();
    self._nav_phase = .content_loaded;
}

/// The load event bookends domComplete. Chrome reports duration ==
/// loadEventEnd on the navigation entry (measured), so the entry's duration
/// tracks this too.
pub fn navigationComplete(self: *Performance) void {
    const at = self.now();
    if (self._nav.dom_content_loaded_event_end == 0) {
        self._nav.dom_interactive = at;
        self._nav.dom_content_loaded_event_start = at;
        self._nav.dom_content_loaded_event_end = at;
    }
    self._nav.dom_complete = at;
    self._nav.load_event_start = at;
    self._nav.load_event_end = at;
    self._nav_phase = .complete;
    if (self._nav_entry) |entry| {
        entry._proto._proto._duration = at;
    }
}

/// Records a finished subresource load as a `resource` entry.
///
/// Chrome leaves one of these behind for every script, stylesheet, image, XHR
/// and fetch a document makes. This engine left none, while still advertising
/// `resource` in `PerformanceObserver.supportedEntryTypes` — a surface that
/// contradicts itself, which is worse than one feature missing. Cloudflare's
/// own api.js reads its entry back and the page posts it to the Turnstile
/// widget, where it arrived as a 1 035-byte object on a real Chrome and
/// `undefined` here (tools/fingerprint/README.md, "the resource timing buffer
/// never fills"; `probes/expr-resource-timing.js` measures it off the station).
///
/// Built eagerly, unlike the navigation entry: that one is lazy because none of
/// its milestone callbacks have an Execution to allocate against, whereas every
/// caller here is script-facing and has one. So the entry can exist — and reach
/// the observers — when the load finished rather than when something first asks.
/// Returns the entry's stored timing, so a caller that learns something about
/// the load only after it landed can amend it. The prescan is the case that
/// needs it: it starts a `<script src>` fetch before the parser reaches the
/// element, so whether that script blocks the parser is not knowable when the
/// response arrives.
pub fn resourceLoaded(
    self: *Performance,
    name: []const u8,
    t: timing.Timing,
    exec: *const Execution,
) !*timing.Timing {
    // ResourceTiming reads its milestones through a pointer, so the timing has
    // to outlive this call rather than ride along on the stack.
    const stored = try exec.arena.create(timing.Timing);
    stored.* = t;
    // Stamped here rather than by each recorder: one navigation is one id, and
    // a recorder that forgot would let a reader tell its loads from the rest.
    stored.navigation_id = self._navigation_id;

    // The two response labels are the only fields whose bytes belong to
    // whoever performed the fetch -- an inline buffer on a Script, an
    // ImageRequest or a SyncResponse, all of which are released well before
    // the buffer is read back. Everything else in `t` is a number or a
    // literal. Copied here rather than at each of the five call sites, so a
    // new recorder cannot forget to.
    stored.content_type = try exec.arena.dupe(u8, t.content_type);
    stored.content_encoding = try exec.arena.dupe(u8, t.content_encoding);

    const entry = try exec._factory.chained(.{
        Entry{
            ._name = try exec.arena.dupe(u8, name),
            ._start_time = t.fetch_start,
            ._duration = t.response_end - t.fetch_start,
            ._type = undefined,
        },
        timing.ResourceTiming{
            ._proto = undefined,
            ._timing = stored,
        },
    });
    entry._proto._type = .{ .resource = entry };
    try self._entries.append(exec.arena, entry._proto);
    try self.notifyObservers(entry._proto, exec);
    return stored;
}

/// Builds the entries a document has without anyone asking for them — the one
/// navigation entry, the `visible` visibility-state entry, and the paint pair
/// — and leaves the buffer sorted by startTime, which is the order Chrome's
/// getEntries() answers in (measured: a measure at startTime 0 came back ahead
/// of marks made before it).
///
/// Built lazily rather than at each milestone because none of the milestone
/// callbacks have an Execution to allocate with. The entry objects read
/// through to `_nav`, so building late loses nothing.
fn ensureImplicitEntries(self: *Performance, exec: *const Execution) !void {
    if (self._nav_phase == .none) {
        return;
    }

    if (self._nav_entry == null) {
        const entry = try exec._factory.chained(.{
            Entry{
                ._name = self._nav_name,
                ._duration = self._nav.load_event_end,
                ._type = undefined,
            },
            timing.ResourceTiming{
                ._proto = undefined,
                ._timing = &self._nav,
            },
            timing.NavigationTiming{
                ._proto = undefined,
            },
        });
        entry._proto._proto._type = .{ .navigation = entry };
        self._nav_entry = entry;
        try self._entries.append(exec.arena, entry._proto._proto);

        // Chrome logs one of these per visibilitychange and always starts with
        // a `visible` one at startTime 0 (measured).
        const visibility = try exec._factory.chained(.{
            Entry{
                ._name = "visible",
                ._type = undefined,
            },
            timing.VisibilityStateEntry{
                ._proto = undefined,
            },
        });
        visibility._proto._type = .{ .@"visibility-state" = visibility };
        try self._entries.append(exec.arena, visibility._proto);
    }

    // Nothing here paints, so the pair is pinned to milestones that did
    // happen: the content exists once the parser is done with it
    // (domInteractive), and the frame it would have been presented in is the
    // one that closed the load (domComplete). Chrome's own numbers have the
    // same shape — paintTime before presentationTime, startTime equal to
    // presentationTime, duration 0.
    if (!self._paint_entries and self._nav_phase == .complete) {
        self._paint_entries = true;
        for ([_][]const u8{ "first-paint", "first-contentful-paint" }) |name| {
            const paint = try exec._factory.chained(.{
                Entry{
                    ._name = name,
                    ._start_time = self._nav.dom_complete,
                    ._type = undefined,
                },
                timing.PaintTiming{
                    ._proto = undefined,
                    ._paint_time = self._nav.dom_interactive,
                },
            });
            paint._proto._type = .{ .paint = paint };
            try self._entries.append(exec.arena, paint._proto);
        }
    }

    const Sort = struct {
        fn lessThan(_: void, a: *Entry, b: *Entry) bool {
            return a._start_time < b._start_time;
        }
    };
    std.sort.block(*Entry, self._entries.items, {}, Sort.lessThan);
}

pub fn mark(
    self: *Performance,
    name: []const u8,
    _options: ?Mark.Options,
    exec: *const Execution,
) !*Mark {
    const opts = _options orelse Mark.Options{};
    const start_time = opts.startTime orelse self.now();
    const m = try Mark.init(name, opts.detail, start_time, exec);
    try self._entries.append(exec.arena, m._proto);
    try self.notifyObservers(m._proto, exec);
    return m;
}

const MeasureOptionsOrStartMark = union(enum) {
    measure_options: Measure.Options,
    start_mark: []const u8,
};

pub fn measure(
    self: *Performance,
    name: []const u8,
    maybe_options_or_start: ?MeasureOptionsOrStartMark,
    maybe_end_mark: ?[]const u8,
    exec: *const Execution,
) !*Measure {
    if (maybe_options_or_start) |options_or_start| switch (options_or_start) {
        .measure_options => |options| {
            // Get start timestamp.
            const start_timestamp = blk: {
                if (options.start) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk 0.0;
            };

            // Get end timestamp.
            const end_timestamp = blk: {
                if (options.end) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                options.detail,
                start_timestamp,
                end_timestamp,
                options.duration,
                exec,
            );
            try self._entries.append(exec.arena, m._proto);
            try self.notifyObservers(m._proto, exec);
            return m;
        },
        .start_mark => |start_mark| {
            // Get start timestamp.
            const start_timestamp = try self.getMarkTime(start_mark);
            // Get end timestamp.
            const end_timestamp = blk: {
                if (maybe_end_mark) |mark_name| {
                    break :blk try self.getMarkTime(mark_name);
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                null,
                start_timestamp,
                end_timestamp,
                null,
                exec,
            );
            try self._entries.append(exec.arena, m._proto);
            try self.notifyObservers(m._proto, exec);
            return m;
        },
    };

    const m = try Measure.init(name, null, 0.0, self.now(), null, exec);
    try self._entries.append(exec.arena, m._proto);
    try self.notifyObservers(m._proto, exec);
    return m;
}

pub fn clearMarks(self: *Performance, mark_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .mark and (mark_name == null or std.mem.eql(u8, entry._name, mark_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearMeasures(self: *Performance, measure_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .measure and (measure_name == null or std.mem.eql(u8, entry._name, measure_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn setResourceTimingBufferSize(self: *Performance, max_size: u32) void {
    _ = self;
    _ = max_size;
}

pub fn getEntries(self: *Performance, exec: *const Execution) ![]*Entry {
    try self.ensureImplicitEntries(exec);
    return self._entries.items;
}

pub fn getEntriesByType(self: *Performance, entry_type: []const u8, exec: *const Execution) ![]const *Entry {
    try self.ensureImplicitEntries(exec);
    return filterEntriesByType(exec.local_arena, self._entries.items, entry_type);
}

pub fn getEntriesByName(self: *Performance, name: []const u8, entry_type: ?[]const u8, exec: *const Execution) ![]const *Entry {
    try self.ensureImplicitEntries(exec);
    return filterEntriesByName(exec.local_arena, self._entries.items, name, entry_type);
}

// Also used by PerformanceObserver
pub fn filterEntriesByType(arena: Allocator, list: []*Entry, entry_type: []const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.getEntryType(), entry_type)) {
            try result.append(arena, entry);
        }
    }
    return result.items;
}

// Also used by PerformanceObserver
pub fn filterEntriesByName(arena: Allocator, list: []*Entry, name: []const u8, entry_type: ?[]const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;

    for (list) |entry| {
        if (!std.mem.eql(u8, entry._name, name)) {
            continue;
        }
        if (entry_type == null or std.mem.eql(u8, entry.getEntryType(), entry_type.?)) {
            try result.append(arena, entry);
        }
    }

    return result.items;
}

fn getMarkTime(self: *const Performance, mark_name: []const u8) !f64 {
    for (self._entries.items) |entry| {
        if (entry._type == .mark and std.mem.eql(u8, entry._name, mark_name)) {
            return entry._start_time;
        }
    }

    // PerformanceTiming attribute names are valid start/end marks per the
    // W3C User Timing Level 2 spec. All are relative to navigationStart (= 0).
    // https://www.w3.org/TR/user-timing/#dom-performance-measure
    //
    // `navigationStart` is an equivalent to 0.
    // Others are dependant to request arrival, end of request etc, but we
    // return a dummy 0 value for now.
    const navigation_timing_marks = std.StaticStringMap(void).initComptime(.{
        .{ "navigationStart", {} },
        .{ "unloadEventStart", {} },
        .{ "unloadEventEnd", {} },
        .{ "redirectStart", {} },
        .{ "redirectEnd", {} },
        .{ "fetchStart", {} },
        .{ "domainLookupStart", {} },
        .{ "domainLookupEnd", {} },
        .{ "connectStart", {} },
        .{ "connectEnd", {} },
        .{ "secureConnectionStart", {} },
        .{ "requestStart", {} },
        .{ "responseStart", {} },
        .{ "responseEnd", {} },
        .{ "domLoading", {} },
        .{ "domInteractive", {} },
        .{ "domContentLoadedEventStart", {} },
        .{ "domContentLoadedEventEnd", {} },
        .{ "domComplete", {} },
        .{ "loadEventStart", {} },
        .{ "loadEventEnd", {} },
    });
    if (navigation_timing_marks.has(mark_name)) {
        return 0;
    }

    return error.SyntaxError; // Mark not found
}

pub fn registerObserver(self: *Performance, observer: *PerformanceObserver, exec: *const Execution) !void {
    for (self._observers.items) |o| {
        if (o == observer) {
            return;
        }
    }
    return self._observers.append(exec.arena, observer);
}

pub fn unregisterObserver(self: *Performance, observer: *PerformanceObserver) void {
    if (self._delivering) {
        return;
    }
    for (self._observers.items, 0..) |o, i| {
        if (o == observer) {
            _ = self._observers.swapRemove(i);
            return;
        }
    }
}

/// Append the entry to every interested observer's queue and schedule async
/// delivery. Does NOT fire the callbacks synchronously — that happens later
/// via the scheduled task.
pub fn notifyObservers(self: *Performance, entry: *Entry, exec: *const Execution) !void {
    for (self._observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(exec.arena, entry) catch |err| {
                lp.log.err(.frame, "Performance.notifyObservers", .{ .err = err });
            };
        }
    }

    try self.scheduleDelivery(exec);
}

pub fn scheduleDelivery(self: *Performance, exec: *const Execution) !void {
    if (self._delivery_scheduled) {
        return;
    }
    self._delivery_scheduled = true;

    return exec._scheduler.add(
        self,
        struct {
            fn run(_self: *anyopaque) anyerror!?u32 {
                const perf: *Performance = @ptrCast(@alignCast(_self));
                perf._delivery_scheduled = false;
                perf._delivering = true;

                defer {
                    perf._delivering = false;
                    var observers = &perf._observers;
                    var i: usize = 0;
                    while (i < observers.items.len) {
                        if (observers.items[i]._interests == 0) {
                            // it was disconencted while we ran, dangerous to
                            // remove while running, remove it now.
                            _ = observers.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }

                var i: usize = 0;
                while (i < perf._observers.items.len) : (i += 1) {
                    const observer = perf._observers.items[i];
                    if (observer.hasRecords()) {
                        try observer.dispatch();
                    }
                }
                return null;
            }
        }.run,
        0,
        .{ .name = "Performance.deliverObservers" },
    );
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declared in Chrome's own prototype order (win25-chrome.json), which puts
    // the partial-interface members — timing, navigation, memory, eventCounts,
    // interactionCount — after `constructor`.
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
    pub const onresourcetimingbufferfull = bridge.accessor(
        Performance.getOnResourceTimingBufferFull,
        Performance.setOnResourceTimingBufferFull,
        .{},
    );
    pub const clearMarks = bridge.function(Performance.clearMarks, .{});
    pub const clearMeasures = bridge.function(Performance.clearMeasures, .{});
    pub const clearResourceTimings = bridge.function(Performance.clearResourceTimings, .{});
    pub const getEntries = bridge.function(Performance.getEntries, .{});
    pub const getEntriesByName = bridge.function(Performance.getEntriesByName, .{});
    pub const getEntriesByType = bridge.function(Performance.getEntriesByType, .{});
    pub const mark = bridge.function(Performance.mark, .{});
    pub const measure = bridge.function(Performance.measure, .{});
    pub const setResourceTimingBufferSize = bridge.function(Performance.setResourceTimingBufferSize, .{ .noop = true });
    pub const toJSON = bridge.function(Performance.toJSON, .{});
    pub const now = bridge.function(Performance.now, .{});
    pub const timing = bridge.accessor(Performance.getTiming, null, .{ .exposed = .window });
    pub const navigation = bridge.accessor(Performance.getNavigation, null, .{ .exposed = .window });
    pub const memory = bridge.accessor(Performance.getMemory, null, .{ .exposed = .window });
    pub const eventCounts = bridge.accessor(Performance.getEventCounts, null, .{ .exposed = .window });
    pub const interactionCount = bridge.accessor(Performance.getInteractionCount, null, .{ .exposed = .window });
};

/// performance.memory. Chrome has no MemoryInfo global — the class is only
/// reachable through the instance's brand (measured: `typeof window.MemoryInfo
/// === 'undefined'`, `Object.prototype.toString.call(performance.memory) ===
/// '[object MemoryInfo]'`, and `memory.constructor.name === 'Object'`).
pub const MemoryInfo = struct {
    _total: usize,
    _used: usize,
    _limit: usize,

    fn totalJSHeapSize(self: *const MemoryInfo) f64 {
        return @floatFromInt(self._total);
    }

    fn usedJSHeapSize(self: *const MemoryInfo) f64 {
        return @floatFromInt(self._used);
    }

    fn jsHeapSizeLimit(self: *const MemoryInfo) f64 {
        return @floatFromInt(self._limit);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MemoryInfo);

        pub const Meta = struct {
            pub const name = "MemoryInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            // No `window.MemoryInfo`, and so no own `constructor` on the
            // prototype either: Chrome's memory.constructor is Object.
            pub const no_interface_object = true;
        };

        pub const totalJSHeapSize = bridge.accessor(MemoryInfo.totalJSHeapSize, null, .{});
        pub const usedJSHeapSize = bridge.accessor(MemoryInfo.usedJSHeapSize, null, .{});
        pub const jsHeapSizeLimit = bridge.accessor(MemoryInfo.jsHeapSizeLimit, null, .{});
    };
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,

    pub const Type = union(Enum) {
        element: *timing.ElementTiming,
        event: *timing.EventTiming,
        @"first-input": *timing.EventTiming,
        @"largest-contentful-paint": *timing.LargestContentfulPaint,
        @"layout-shift": *timing.LayoutShift,
        @"long-animation-frame",
        longtask: *timing.LongTaskTiming,
        measure: *Measure,
        navigation: *timing.NavigationTiming,
        paint: *timing.PaintTiming,
        resource: *timing.ResourceTiming,
        taskattribution: *timing.TaskAttributionTiming,
        @"visibility-state": *timing.VisibilityStateEntry,
        mark: *Mark,

        pub const Enum = enum(u8) {
            element = 1, // Changing this affect PerformanceObserver's behavior.
            event = 2,
            @"first-input" = 3,
            @"largest-contentful-paint" = 4,
            @"layout-shift" = 5,
            @"long-animation-frame" = 6,
            longtask = 7,
            measure = 8,
            navigation = 9,
            paint = 10,
            resource = 11,
            taskattribution = 12,
            @"visibility-state" = 13,
            mark = 14,
            // If we ever have types more than 16, we have to update entry
            // table of PerformanceObserver too.
        };
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return @tagName(std.meta.activeTag(self._type));
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._name;
    }

    pub fn getStartTime(self: *const Entry) f64 {
        return self._start_time;
    }

    pub const Json = struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
    };

    /// Chrome's PerformanceEntry.toJSON() is these four keys in this order, and
    /// the subclasses that add nothing of their own (PerformanceMark,
    /// PerformanceMeasure, VisibilityStateEntry) inherit it verbatim — a mark's
    /// `detail` is not in its JSON (measured).
    pub fn toJSON(self: *const Entry) Entry.Json {
        return .{
            .name = self._name,
            .entryType = self.getEntryType(),
            .startTime = self._start_time,
            .duration = self._duration,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const toJSON = bridge.function(Entry.toJSON, .{});
    };
};

pub const Mark = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        startTime: ?f64 = null,
    };

    pub fn init(name: []const u8, maybe_detail: ?js.Value, start_time: f64, exec: *const Execution) !*Mark {
        if (start_time < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.chained(.{
            Entry{
                ._start_time = start_time,
                ._name = try exec.dupeString(name),
                ._type = undefined,
            },
            Mark{
                ._proto = undefined,
                ._detail = detail,
            },
        });
        m._proto._type = .{ .mark = m };
        return m;
    }

    pub fn getDetail(self: *const Mark) ?js.Value.Global {
        return self._detail;
    }

    /// `new PerformanceMark(name, options)`. Unlike `performance.mark()`, the
    /// constructor does not add the mark to the entry buffer — Chrome answers
    /// `getEntriesByName()` with 0 for a mark built this way (measured).
    pub fn constructor(
        name: []const u8,
        options: ?Options,
        exec: *const Execution,
    ) !*Mark {
        const opts = options orelse Options{};
        const start_time = opts.startTime orelse (exec.performance().now());
        if (start_time < 0.0) {
            const isolate = exec.js.isolate;
            var buf: [256]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buf,
                "Failed to construct 'PerformanceMark': '{s}' cannot have a negative start time.",
                .{name},
            ) catch "Failed to construct 'PerformanceMark': cannot have a negative start time.";
            _ = isolate.throwException(isolate.createTypeError(message));
            return error.JsException;
        }
        return Mark.init(name, opts.detail, start_time, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Mark);

        pub const Meta = struct {
            pub const name = "PerformanceMark";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Mark.getDetail, null, .{});
        pub const constructor = bridge.constructor(Mark.constructor, .{ .arity = 1 });
    };
};

pub const Measure = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        start: ?TimestampOrMark,
        end: ?TimestampOrMark,
        duration: ?f64 = null,

        const TimestampOrMark = union(enum) {
            timestamp: f64,
            mark: []const u8,
        };
    };

    pub fn init(
        name: []const u8,
        maybe_detail: ?js.Value,
        start_timestamp: f64,
        end_timestamp: f64,
        maybe_duration: ?f64,
        exec: *const Execution,
    ) !*Measure {
        const duration = maybe_duration orelse (end_timestamp - start_timestamp);
        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.chained(.{
            Entry{
                ._start_time = start_timestamp,
                ._duration = duration,
                ._name = try exec.dupeString(name),
                ._type = undefined,
            },
            Measure{
                ._proto = undefined,
                ._detail = detail,
            },
        });
        m._proto._type = .{ .measure = m };
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Measure);

        pub const Meta = struct {
            pub const name = "PerformanceMeasure";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Measure.getDetail, null, .{});
    };
};

/// PerformanceTiming — Navigation Timing Level 1 (legacy, but widely used).
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceTiming
///
/// Every member is wall-clock epoch milliseconds, not a time-origin offset —
/// Chrome's navigationStart on this machine read 1.7e12 (measured). They come
/// from the same milestones the Level 2 navigation entry reports, shifted onto
/// the epoch origin recorded when the Performance was created; a member the
/// load never reached stays 0, which is also what Chrome does for
/// unloadEvent*/redirect* on a first navigation.
pub const PerformanceTiming = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    fn perf(self: *const PerformanceTiming) *const Performance {
        return @alignCast(@fieldParentPtr("_timing", self));
    }

    /// Level 2's offsets are fractional milliseconds from the time origin;
    /// Level 1 is an integer epoch stamp. A milestone the load has not reached
    /// yet reads 0 rather than the origin, which is what Chrome answers from a
    /// script running mid-parse.
    fn epoch(self: *const PerformanceTiming, needs: NavPhase, offset: f64) f64 {
        const p = self.perf();
        if (@intFromEnum(p._nav_phase) < @intFromEnum(needs)) {
            return 0;
        }
        return @as(f64, @floatFromInt(p.epochOriginMs())) + @round(offset);
    }

    fn navigationStart(self: *const PerformanceTiming) f64 {
        return @floatFromInt(self.perf().epochOriginMs());
    }

    fn zero(_: *const PerformanceTiming) f64 {
        return 0;
    }

    fn fetchStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.started, self.perf()._nav.fetch_start);
    }

    fn domainLookupStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.started, self.perf()._nav.domain_lookup_start);
    }

    fn domainLookupEnd(self: *const PerformanceTiming) f64 {
        return self.epoch(.started, self.perf()._nav.domain_lookup_end);
    }

    fn connectStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.started, self.perf()._nav.connect_start);
    }

    fn connectEnd(self: *const PerformanceTiming) f64 {
        return self.epoch(.started, self.perf()._nav.connect_end);
    }

    fn requestStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.started, self.perf()._nav.request_start);
    }

    fn responseStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.response, self.perf()._nav.response_start);
    }

    fn responseEnd(self: *const PerformanceTiming) f64 {
        return self.epoch(.response_end, self.perf()._nav.response_end);
    }

    fn domInteractive(self: *const PerformanceTiming) f64 {
        return self.epoch(.interactive, self.perf()._nav.dom_interactive);
    }

    fn domContentLoadedEventStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.interactive, self.perf()._nav.dom_content_loaded_event_start);
    }

    fn domContentLoadedEventEnd(self: *const PerformanceTiming) f64 {
        return self.epoch(.content_loaded, self.perf()._nav.dom_content_loaded_event_end);
    }

    fn domComplete(self: *const PerformanceTiming) f64 {
        return self.epoch(.complete, self.perf()._nav.dom_complete);
    }

    fn loadEventStart(self: *const PerformanceTiming) f64 {
        return self.epoch(.complete, self.perf()._nav.load_event_start);
    }

    fn loadEventEnd(self: *const PerformanceTiming) f64 {
        return self.epoch(.complete, self.perf()._nav.load_event_end);
    }

    /// Chrome's own toJSON order, which is neither the prototype's order nor
    /// alphabetical — it is V8's hash iteration order for this object and is
    /// stable per build (measured, win24-chrome.json).
    pub const Json = struct {
        connectStart: f64,
        secureConnectionStart: f64,
        unloadEventEnd: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        responseStart: f64,
        connectEnd: f64,
        responseEnd: f64,
        requestStart: f64,
        domLoading: f64,
        redirectStart: f64,
        loadEventEnd: f64,
        domComplete: f64,
        navigationStart: f64,
        loadEventStart: f64,
        domContentLoadedEventEnd: f64,
        unloadEventStart: f64,
        redirectEnd: f64,
        domInteractive: f64,
        fetchStart: f64,
        domContentLoadedEventStart: f64,
    };

    fn json(self: *const PerformanceTiming) PerformanceTiming.Json {
        return .{
            .connectStart = self.connectStart(),
            .secureConnectionStart = 0,
            .unloadEventEnd = 0,
            .domainLookupStart = self.domainLookupStart(),
            .domainLookupEnd = self.domainLookupEnd(),
            .responseStart = self.responseStart(),
            .connectEnd = self.connectEnd(),
            .responseEnd = self.responseEnd(),
            .requestStart = self.requestStart(),
            .domLoading = self.responseStart(),
            .redirectStart = 0,
            .loadEventEnd = self.loadEventEnd(),
            .domComplete = self.domComplete(),
            .navigationStart = self.navigationStart(),
            .loadEventStart = self.loadEventStart(),
            .domContentLoadedEventEnd = self.domContentLoadedEventEnd(),
            .unloadEventStart = 0,
            .redirectEnd = 0,
            .domInteractive = self.domInteractive(),
            .fetchStart = self.fetchStart(),
            .domContentLoadedEventStart = self.domContentLoadedEventStart(),
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = PerformanceTiming;

        pub const navigationStart = bridge.accessor(T.navigationStart, null, .{});
        pub const unloadEventStart = bridge.accessor(T.zero, null, .{});
        pub const unloadEventEnd = bridge.accessor(T.zero, null, .{});
        pub const redirectStart = bridge.accessor(T.zero, null, .{});
        pub const redirectEnd = bridge.accessor(T.zero, null, .{});
        pub const fetchStart = bridge.accessor(T.fetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(T.domainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(T.domainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(T.connectStart, null, .{});
        pub const connectEnd = bridge.accessor(T.connectEnd, null, .{});
        pub const secureConnectionStart = bridge.accessor(T.zero, null, .{});
        pub const requestStart = bridge.accessor(T.requestStart, null, .{});
        pub const responseStart = bridge.accessor(T.responseStart, null, .{});
        pub const responseEnd = bridge.accessor(T.responseEnd, null, .{});
        // Chrome's domLoading is when the parser started, which here is the
        // moment the first response byte arrived.
        pub const domLoading = bridge.accessor(T.responseStart, null, .{});
        pub const domInteractive = bridge.accessor(T.domInteractive, null, .{});
        pub const domContentLoadedEventStart = bridge.accessor(T.domContentLoadedEventStart, null, .{});
        pub const domContentLoadedEventEnd = bridge.accessor(T.domContentLoadedEventEnd, null, .{});
        pub const domComplete = bridge.accessor(T.domComplete, null, .{});
        pub const loadEventStart = bridge.accessor(T.loadEventStart, null, .{});
        pub const loadEventEnd = bridge.accessor(T.loadEventEnd, null, .{});
        pub const toJSON = bridge.function(T.json, .{});
    };
};

// PerformanceNavigation implements the Navigation Timing Level 1 API.
// https://www.w3.org/TR/navigation-timing/#sec-navigation-navigation-timing-interface
// The four TYPE_ constants sit on the prototype next to the two attributes
// (measured); Chrome does not put them on the interface object.
pub const PerformanceNavigation = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub const Json = struct {
        type: u16,
        redirectCount: u32,
    };

    fn json(_: *const PerformanceNavigation) PerformanceNavigation.Json {
        return .{ .type = 0, .redirectCount = 0 };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceNavigation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const @"type" = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectCount = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const TYPE_NAVIGATE = bridge.property(0, .{ .template = false, .readonly = true });
        pub const TYPE_RELOAD = bridge.property(1, .{ .template = false, .readonly = true });
        pub const TYPE_BACK_FORWARD = bridge.property(2, .{ .template = false, .readonly = true });
        pub const TYPE_RESERVED = bridge.property(255, .{ .template = false, .readonly = true });
        pub const toJSON = bridge.function(PerformanceNavigation.json, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}

test "WebApi: Performance resource entries" {
    // The stylesheet is one of the loads under test, so it has to actually go
    // out: the runner leaves external stylesheets off by default.
    try testing.htmlRunner("performance_resource.html", .{ .load_external_stylesheets = true });
}
