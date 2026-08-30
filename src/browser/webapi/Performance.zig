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
const EventTarget = @import("EventTarget.zig");
const URL = @import("../URL.zig");
const http = @import("../../network/http.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, Mark, Measure, MemoryInfo, PerformanceTiming, PerformanceNavigation };
}

const Performance = @This();

_proto: *EventTarget,
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
_loaf_entry: bool = false,

// Nothing fires it — the resource buffer never fills because nothing fills it
// — but the accessor pair is on Chrome's Performance.prototype and reads back
// what a script sets.
//
// This is the one handler property still kept in a field. The rest went to the
// event manager's handler store, which is keyed by EventTarget. Performance is
// an EventTarget now (see Proto below), so this could join them; nothing fires
// the event either way, so the move would be a change with no reading behind
// it.
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

// Chrome's Performance inherits EventTarget -- `performance instanceof
// EventTarget` is true there and `performance.addEventListener` is a function.
// This engine had it as a prototype root in both realms, which the member
// table could not show: `Performance.prototype`'s own names were already
// byte-identical, and only the *chain* differed
// (probes/expr-proto-chains.js). It was the last chain difference in either
// realm.
pub const Proto = EventTarget;

pub fn asEventTarget(self: *Performance) *EventTarget {
    return self._proto;
}

pub fn init(resolution_micros: u64) Performance {
    return .{
        ._proto = undefined,
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
    return self.latticeMsSince(@intCast(highResTimestamp(self._clock_resolution_micros)));
}

/// The lattice a timestamp is spelled on, in milliseconds.
///
/// The clamp above decides which grid point a reading lands on; this decides
/// how that grid point is written down, and the two are separate tells. The
/// reference host does not hand out the double nearest the grid point: 133.8
/// comes back as 133.79999999701977, because the value it hands out has been
/// rounded onto a lattice of 2^-26 ms. Only one grid point in five is on that
/// lattice, so four readings in five carry a dozen digits of dust -- and a
/// clock that answers "133.8" every time is a clock no browser has.
///
/// Measured across 75M samples of Chrome 151 spanning 0.1ms to 32s: every
/// reading is a grid point offset by one of {0, +/-1, +/-2} multiples of
/// 2^-25/10 ms, fixed by the grid index mod 5, exactly as this lattice
/// predicts (tools/fingerprint/scratch/expr-now-octave.js).
const lattice_step_ms = 1.0 / 67108864.0;

/// How far a stamp sits from the lattice.
///
/// The offset is set by the fractional part of `ms * 2^26`, and since
/// `ms = micros / 1000` and `2^26 / 1000 = 2^23 / 125`, that fraction is
/// `(micros * 2^23) mod 125` over 125. Integers, so the offset stays exact
/// however far from zero the stamp is -- the reference's own arithmetic loses
/// the lattice once the stamp needs more than 27 bits, and reproducing that
/// would trade a shape a page can read for one it cannot.
fn latticeOffset(micros: i64) f64 {
    // 2^23 mod 125 == 108, folded in so the multiply cannot overflow.
    const numerator: i64 = @mod(@mod(micros, 125) * 108, 125);
    const fraction = @as(f64, @floatFromInt(numerator)) / 125.0;
    // 125 is odd, so the fraction is never exactly one half and the rounding
    // never has a tie to break.
    const rounded = if (fraction * 2.0 < 1.0) -fraction else 1.0 - fraction;
    return rounded * lattice_step_ms;
}

/// A clamped boot-relative stamp as milliseconds on this document's timeline.
///
/// The reference rounds the stamp and the document's origin onto the lattice
/// and subtracts, so the origin's own offset rides along on every reading:
/// the five offsets are the same five on every page, rotated by wherever that
/// document's origin happened to fall. Measured over five loads, three of
/// about:blank and two of a real page, each one deterministic and each one a
/// rotation of the same table (tools/fingerprint/scratch/expr-now-residue.js).
fn latticeMsSince(self: *const Performance, clamped: i64) f64 {
    const origin: i64 = @intCast(self._time_origin);
    const elapsed = @as(f64, @floatFromInt(clamped - origin)) / 1000.0;
    return elapsed + (latticeOffset(clamped) - latticeOffset(origin));
}

/// Puts a point on this document's timeline back on the clock the page was
/// told it has.
///
/// A resource entry's connection walk arrives from libcurl in microseconds and
/// is laid out as offsets from fetchStart, so carrying those offsets across
/// unchanged reports milestones finer than the `now()` sitting beside them --
/// `entry.requestStart * 10 % 1` is the whole expression. Chrome puts every
/// one of them on the same grid as `now()`: 60 of 60 non-zero fields across a
/// navigation entry and four resource entries came back whole multiples of
/// 0.1ms, several of them collapsed onto one grid point
/// (tools/fingerprint/scratch/expr-entry-grid.js).
pub fn snapMs(self: *const Performance, ms: f64) f64 {
    const origin: i64 = @intCast(self._time_origin);
    const absolute = origin + @as(i64, @intFromFloat(@round(ms * 1000.0)));
    return self.latticeMsSince(clamp(absolute, self._clock_resolution_micros));
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

/// A copy of this document's own navigation timing, restated on `host`'s
/// timeline.
///
/// For the parent of an <iframe>: Chrome files the child document's load in
/// the PARENT's resource buffer under `initiatorType: "iframe"`, and the
/// numbers it reports there are the child's own fetch and connection walk --
/// which is exactly what this already holds, milestones and all. Copying it is
/// therefore not an approximation of the entry, it is the entry.
///
/// But only after the restatement. Every stamp in the record is milliseconds
/// since THIS document's time origin, and a framed document's origin is the
/// moment it was navigated -- later than its parent's. Handed over unchanged
/// the parent reports an <iframe> that began loading before the elements above
/// it in its own document were parsed: measured at `start=2.4` against a
/// nearest sibling of `8.3`, with the two origins 10.9ms apart
/// (tools/fingerprint/probes/expr-b87-iframe-timebase.js). Chrome's answer on
/// the same fixture is the child's numbers plus that gap, to the tenth.
pub fn navigationTimingOn(self: *const Performance, host: *const Performance) timing.Timing {
    var t = self._nav;
    // Both origins are boot-relative microseconds, so the difference is how
    // much later this document's clock started than the host's.
    const mine: i64 = @intCast(self._time_origin);
    const theirs: i64 = @intCast(host._time_origin);
    t.restateOn(host, @as(f64, @floatFromInt(mine - theirs)) / 1000.0);
    return t;
}

pub fn navigationResponseStarted(
    self: *Performance,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    next_hop_protocol: []const u8,
    times: http.ResponseTimes,
    redirect: http.RedirectTiming,
) void {
    const at = self.now();
    // A redirected navigation has two fetches in it, and both Navigation Timing
    // levels are defined against the second one: fetchStart moves to where the
    // last redirect response landed, which is also the anchor the final hop's
    // connection walk below is measured from. Chrome reports fetchStart == 0
    // for the redirect it hides and a moved fetchStart for the one it shows, so
    // this part happens either way.
    self.navigationRedirected(redirect);
    // The document's own connection walk, same as any subresource's. What
    // navigationStarted stamped were placeholders: it had nothing to measure
    // yet, and leaving them said the document resolved and connected in the
    // same instant the navigation began.
    self._nav.setConnectionMilestones(times, self);
    self._nav.response_start = at;
    self._nav.final_response_headers_start = at;
    self._nav.response_status = status;
    // See Timing.responded: transferSize keys on this rather than on the
    // status, which the cross-origin mask can zero.
    self._nav.responded = status != 0;
    self._nav.content_type = content_type;
    self._nav.content_encoding = content_encoding;
    self._nav.next_hop_protocol = next_hop_protocol;
    self._nav_phase = .response;
}

/// Folds the redirect chain the transfer walked into the navigation record.
///
/// Navigation Timing exposes a chain only when every hop passed the timing allow
/// check, which for a plain document means every hop stayed on one origin.
/// Chrome 151 on a same-origin 302 reports redirectCount 1 with redirectStart at
/// the first fetch and redirectEnd where the hop landed; on a cross-origin 302 it
/// reports 0 for all three (measured against the two `/redirect_nav_timing*`
/// routes in testing.zig). Either way `fetchStart` moves to the end of the
/// chain: the document really did start fetching second.
fn navigationRedirected(self: *Performance, redirect: http.RedirectTiming) void {
    if (redirect.count == 0) {
        return;
    }

    const first_fetch_start = self._nav.fetch_start;
    const chain_end = self.relativeMs(redirect.end_micros);
    // A hop measured as landing before the navigation began is a clock reading
    // we should not turn into a negative milestone.
    self._nav.fetch_start = @max(first_fetch_start, chain_end);

    if (redirect.same_origin == false) {
        return;
    }
    self._nav.redirect_count = redirect.count;
    self._nav.redirect_start = first_fetch_start;
    self._nav.redirect_end = self._nav.fetch_start;
}

/// A boot-relative microsecond stamp as milliseconds on this document's
/// timeline, clamped the same way `now()` is -- a milestone finer than the
/// clock beside it would hand back resolution the clamp exists to withhold.
fn relativeMs(self: *const Performance, micros: u64) f64 {
    return self.latticeMsSince(clamp(@intCast(micros), self._clock_resolution_micros));
}

/// The URL the document was finally served from, which is what Chrome names the
/// navigation entry after. `navigationStarted` only knows the URL that was
/// asked for, and a redirect makes those two different -- an entry still named
/// after the request is a document claiming it never redirected.
pub fn navigationUrl(self: *Performance, url: []const u8) void {
    self._nav_name = url;
    if (self._nav_entry) |entry| {
        entry._proto._proto._name = url;
    }
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
/// Whether a load of `url` counts as same-origin for this document.
///
/// `_nav_name` is the document's own URL, set at navigationStarted. A realm
/// that never navigated -- a worker, a fresh realm -- has none, and answering
/// "same origin" there keeps this from hiding a worker's own fetches from it;
/// the cross-origin rule is about what one DOCUMENT may learn about another
/// origin, and with no document URL there is nothing to compare against.
fn sameOriginAsDocument(self: *const Performance, url: []const u8) bool {
    if (self._nav_name.len == 0) {
        return true;
    }
    return URL.isSameOrigin(url, self._nav_name);
}

/// Whether a `Timing-Allow-Origin` header lets `document_url`'s origin read the
/// response's timing.
///
/// The header is `*` or a comma-separated origin list. Each entry is compared
/// as an origin rather than as a string, so the default port may be written or
/// left off either side; `URL.isSameOrigin` only looks at scheme, host and
/// port, which is exactly what an origin is. A `null` entry matches nothing,
/// since nothing here reads timing from an opaque origin.
fn timingAllowed(header: []const u8, document_url: []const u8) bool {
    if (header.len == 0) {
        return false;
    }
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, entry, "*")) {
            return true;
        }
        if (document_url.len != 0 and URL.isSameOrigin(entry, document_url)) {
            return true;
        }
    }
    return false;
}

/// What a recorder has to say about a load beyond the numbers, so
/// `resourceLoaded` can decide how much of it this document may see.
pub const LoadedOpts = struct {
    /// The response's `Timing-Allow-Origin` header, empty when it sent none.
    timing_allow_origin: []const u8 = "",

    /// Whether the request went out in CORS mode and came back a CORS
    /// response, rather than an opaque one. True for fetch and XHR, which
    /// announce an Origin and are refused without a matching Allow-Origin;
    /// false for the loads that go out no-cors -- an <img>, a <script src>, a
    /// stylesheet, an <iframe>.
    ///
    /// It decides one thing: whether `responseStatus` and `contentType` are
    /// readable. See Timing.maskCrossOrigin for the measurements.
    ///
    /// This engine has no `crossorigin` attribute support on script, image or
    /// link elements, so those really are no-cors here and `false` is the
    /// honest answer for them -- but it is honest about US, not about Chrome.
    /// A page that loads a cross-origin script WITH `crossorigin` gets a status
    /// from Chrome and a zero from this engine; that gap belongs to the
    /// element's request, not to this entry, and is its own plan.
    cors_response: bool = false,
};

pub fn resourceLoaded(
    self: *Performance,
    name: []const u8,
    t: timing.Timing,
    opts: LoadedOpts,
    exec: *const Execution,
) !*timing.Timing {
    // ResourceTiming reads its milestones through a pointer, so the timing has
    // to outlive this call rather than ride along on the stack.
    const stored = try exec.arena.create(timing.Timing);
    stored.* = t;
    // Stamped here rather than by each recorder: one navigation is one id, and
    // a recorder that forgot would let a reader tell its loads from the rest.
    stored.navigation_id = self._navigation_id;

    // Read off the status before the mask below can zero it. See
    // Timing.responded.
    stored.responded = t.response_status != 0;

    // What this document is allowed to know about the load, applied here for
    // the same reason the labels are duped here: five recorders file entries
    // and a sixth will, and the one that forgot would be the one that leaks.
    const same_origin = self.sameOriginAsDocument(name);
    stored.maskCrossOrigin(
        same_origin,
        opts.cors_response,
        same_origin or timingAllowed(opts.timing_allow_origin, self._nav_name),
    );

    // The two response labels are the only fields whose bytes belong to
    // whoever performed the fetch -- an inline buffer on a Script, an
    // ImageRequest or a SyncResponse, all of which are released well before
    // the buffer is read back. Everything else in `t` is a number or a
    // literal. Copied here rather than at each of the five call sites, so a
    // new recorder cannot forget to. After the mask, so a hidden content type
    // does not take arena space to say nothing.
    stored.content_type = try exec.arena.dupe(u8, stored.content_type);
    stored.content_encoding = try exec.arena.dupe(u8, stored.content_encoding);

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
    // A long animation frame, on the same terms as the paint pair below:
    // nothing here renders, so the frame is pinned to milestones that did
    // happen. It opens where the bytes started arriving and closes where the
    // load did, which is the interval every script on the page ran in.
    //
    // Filed only past Chrome's threshold, because that is what makes it an
    // entry at all: a frame under 50ms is not a long one, and a document that
    // loads that fast leaves Chrome's buffer without one too. Measured on
    // Chrome 151, one entry per document and no `scripts` children with it:
    // www.scrapingcourse.com (startTime 3.5, duration 1268.8) and, inside the
    // Cloudflare widget, startTime 87.0, duration 746.4 -- the realm the
    // cf-scrapingcourse guard runs in, which walks `getEntries()` reading
    // `entryType` off every entry. Listing `long-animation-frame` in
    // `PerformanceObserver.supportedEntryTypes` and never filing one is a shape
    // no browser has.
    if (!self._loaf_entry and self._nav_phase == .complete) {
        self._loaf_entry = true;
        const opened = self._nav.response_start;
        const closed = self._nav.dom_complete;
        if (closed - opened > LONG_ANIMATION_FRAME_MS) {
            const loaf = try exec._factory.chained(.{
                Entry{
                    ._name = "long-animation-frame",
                    ._start_time = opened,
                    ._duration = closed - opened,
                    ._type = undefined,
                },
                timing.PerformanceLongAnimationFrameTiming{
                    ._proto = undefined,
                    // The parser is done here, so this is where a style and
                    // layout pass would begin.
                    ._render_start = self._nav.dom_interactive,
                    // Chrome's own invariant, read off the entry above:
                    // paintTime is exactly the end of the frame.
                    ._paint_time = closed,
                    ._presentation_time = @max(closed, self._nav.load_event_end),
                },
            });
            loaf._proto._type = .{ .@"long-animation-frame" = loaf };
            try self._entries.append(exec.arena, loaf._proto);
        }
    }

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
        // Chrome's `constructor` sits here rather than last; the members
        // below it are the ones Blink installs per context. See
        // Snapshot.moveConstructorSlots.
        pub const constructor_after = "now";
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

/// What makes an animation frame a long one. Chrome's threshold, and the reason
/// a fast local document leaves no `long-animation-frame` entry in either
/// engine's buffer.
const LONG_ANIMATION_FRAME_MS: f64 = 50;

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
        @"long-animation-frame": *timing.PerformanceLongAnimationFrameTiming,
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
        navigationId: u32,
    };

    /// Chrome's PerformanceEntry.toJSON() is these five keys in this order, and
    /// the subclasses that add nothing of their own (PerformanceMark,
    /// PerformanceMeasure, VisibilityStateEntry) inherit it verbatim — a mark's
    /// `detail` is not in its JSON (measured).
    pub fn toJSON(self: *const Entry, exec: *const Execution) Entry.Json {
        return .{
            .name = self._name,
            .entryType = self.getEntryType(),
            .startTime = self._start_time,
            .duration = self._duration,
            .navigationId = self.getNavigationId(exec),
        };
    }

    /// `navigationId` belongs to PerformanceEntry, not to
    /// PerformanceResourceTiming: every entry of a navigation carries the same
    /// tag, a mark filed right after a resource reads the same number
    /// (measured). It sits behind `constructor` because Chrome installs it from
    /// the per-context batch.
    pub fn getNavigationId(_: *const Entry, exec: *const Execution) u32 {
        return exec.performance()._navigation_id;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const constructor_after = "toJSON";
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const toJSON = bridge.function(Entry.toJSON, .{});
        pub const navigationId = bridge.accessor(Entry.getNavigationId, null, .{});
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

    /// Chrome fills this from the TLS handshake and only leaves it at 0 when
    /// there was none -- a plain-HTTP document, or one served off a socket that
    /// was already open. It was hardwired to 0 here while the modern navigation
    /// entry reported the real number from the same reading, so an https
    /// document that spent time connecting claimed no handshake: a shape Chrome
    /// cannot produce (tools/fingerprint/scratch/expr-nav-timing-https.js calls
    /// that pair `impossibleShape`).
    ///
    /// 0 is the answer for "no handshake" rather than the epoch origin, which is
    /// what `epoch` would make of a 0 offset -- "the navigation began" is a very
    /// different claim from "this did not happen".
    fn secureConnectionStart(self: *const PerformanceTiming) f64 {
        const offset = self.perf()._nav.secure_connection_start;
        if (offset == 0) {
            return 0;
        }
        return self.epoch(.started, offset);
    }

    /// The redirect pair is gated on the count rather than on the offsets being
    /// non-zero: a chain that is not reportable leaves the offsets at 0, and a
    /// reportable one can legitimately start within the same rounded
    /// millisecond as the time origin. See Performance.navigationRedirected for
    /// which chains are reportable.
    fn redirectStart(self: *const PerformanceTiming) f64 {
        const p = self.perf();
        if (p._nav.redirect_count == 0) {
            return 0;
        }
        return self.epoch(.started, p._nav.redirect_start);
    }

    fn redirectEnd(self: *const PerformanceTiming) f64 {
        const p = self.perf();
        if (p._nav.redirect_count == 0) {
            return 0;
        }
        return self.epoch(.started, p._nav.redirect_end);
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
            .secureConnectionStart = self.secureConnectionStart(),
            .unloadEventEnd = 0,
            .domainLookupStart = self.domainLookupStart(),
            .domainLookupEnd = self.domainLookupEnd(),
            .responseStart = self.responseStart(),
            .connectEnd = self.connectEnd(),
            .responseEnd = self.responseEnd(),
            .requestStart = self.requestStart(),
            .domLoading = self.responseStart(),
            .redirectStart = self.redirectStart(),
            .loadEventEnd = self.loadEventEnd(),
            .domComplete = self.domComplete(),
            .navigationStart = self.navigationStart(),
            .loadEventStart = self.loadEventStart(),
            .domContentLoadedEventEnd = self.domContentLoadedEventEnd(),
            .unloadEventStart = 0,
            .redirectEnd = self.redirectEnd(),
            .domInteractive = self.domInteractive(),
            .fetchStart = self.fetchStart(),
            .domContentLoadedEventStart = self.domContentLoadedEventStart(),
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceTiming";
            // [Exposed=Window]. The only way here is performance.timing, which
            // is window-gated too, so the interface object was the whole of
            // this type's presence in a worker realm.
            pub const exposed: js.Caller.Function.Opts.Exposed = .window;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = PerformanceTiming;

        pub const navigationStart = bridge.accessor(T.navigationStart, null, .{});
        pub const unloadEventStart = bridge.accessor(T.zero, null, .{});
        pub const unloadEventEnd = bridge.accessor(T.zero, null, .{});
        pub const redirectStart = bridge.accessor(T.redirectStart, null, .{});
        pub const redirectEnd = bridge.accessor(T.redirectEnd, null, .{});
        pub const fetchStart = bridge.accessor(T.fetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(T.domainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(T.domainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(T.connectStart, null, .{});
        pub const connectEnd = bridge.accessor(T.connectEnd, null, .{});
        pub const secureConnectionStart = bridge.accessor(T.secureConnectionStart, null, .{});
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

    fn perf(self: *const PerformanceNavigation) *const Performance {
        return @alignCast(@fieldParentPtr("_navigation", self));
    }

    pub const Json = struct {
        type: u16,
        redirectCount: u32,
    };

    fn json(self: *const PerformanceNavigation) PerformanceNavigation.Json {
        return .{ .type = self.navigationType(), .redirectCount = self.redirectCount() };
    }

    /// The Level 1 spelling of the navigation type the Level 2 entry reports as
    /// a string. Level 1 has no name for anything else, so a navigation that is
    /// neither a reload nor a history traversal is TYPE_NAVIGATE.
    fn navigationType(self: *const PerformanceNavigation) u16 {
        const kind = self.perf()._nav.navigation_type;
        if (std.mem.eql(u8, kind, "reload")) {
            return 1;
        }
        if (std.mem.eql(u8, kind, "back_forward")) {
            return 2;
        }
        return 0;
    }

    /// Zero unless the document arrived through a reportable redirect chain --
    /// see Performance.navigationRedirected for which chains those are. This was
    /// a hardwired 0, so a document that only existed because of a redirect said
    /// none had happened while Chrome answered 1 (measured).
    fn redirectCount(self: *const PerformanceNavigation) u32 {
        return self.perf()._nav.redirect_count;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceNavigation";
            // [Exposed=Window], same as PerformanceTiming above: performance
            // .navigation is the only reference and it is window-gated.
            pub const exposed: js.Caller.Function.Opts.Exposed = .window;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            // No `empty_with_no_proto`: that stores no pointer back to the Zig
            // instance, so an accessor here would receive a static empty struct
            // rather than the `_navigation` field of a Performance -- fine while
            // both attributes were hardwired constants, useless now that they
            // read the navigation record. PerformanceTiming next door is the
            // same one-field shape and has always been TAO-backed.
        };

        const T = PerformanceNavigation;

        // The two attributes are getters and the four TYPE_ constants are data
        // properties -- measured on Chrome 151, which is also what the IDL says
        // (readonly attribute vs const). All six were data properties here.
        pub const @"type" = bridge.accessor(T.navigationType, null, .{});
        pub const redirectCount = bridge.accessor(T.redirectCount, null, .{});
        pub const TYPE_NAVIGATE = bridge.property(0, .{ .template = false, .readonly = true });
        pub const TYPE_RELOAD = bridge.property(1, .{ .template = false, .readonly = true });
        pub const TYPE_BACK_FORWARD = bridge.property(2, .{ .template = false, .readonly = true });
        pub const TYPE_RESERVED = bridge.property(255, .{ .template = false, .readonly = true });
        pub const toJSON = bridge.function(T.json, .{});
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

test "WebApi: Performance level 1 timing reports the TLS handshake" {
    // No test server here speaks TLS, so the handshake is staged on the
    // navigation record exactly as `Timing.setConnectionMilestones` fills it
    // from libcurl's `appconnect` reading. Chrome over https puts
    // secureConnectionStart between connectStart and connectEnd; an https
    // document that spent time connecting and still reports 0 is a shape
    // Chrome cannot produce (tools/fingerprint/scratch/expr-nav-timing-https.js
    // calls that pair `impossibleShape`).
    var p = Performance.init(clock_resolution_micros);
    p.navigationStarted("https://example.com/", "navigate");
    p._nav.connect_start = 10;
    p._nav.secure_connection_start = 20;
    p._nav.connect_end = 69;

    // Read through toJSON, which is the surface a script that stringifies
    // `performance.timing` walks -- and the one the widget was measured
    // walking.
    const origin: f64 = @floatFromInt(p.epochOriginMs());
    {
        const j = p._timing.json();
        try testing.expectEqual(origin + 20, j.secureConnectionStart);
        try testing.expect(j.secureConnectionStart > j.connectStart);
        try testing.expect(j.secureConnectionStart < j.connectEnd);
    }

    // Over plain HTTP there is no handshake to time, and Level 1 reports that
    // as 0 rather than as the epoch origin -- which is what every other
    // unreached milestone reads too.
    p._nav.secure_connection_start = 0;
    try testing.expectEqual(0, p._timing.json().secureConnectionStart);
}

test "WebApi: Performance reports a same-origin navigation redirect" {
    // Chrome 151 on a same-origin 302, measured against
    // tools/fingerprint/scratch/redirect-server.mjs: redirectCount 1 on both
    // Navigation Timing levels, redirectStart/redirectEnd non-zero, fetchStart
    // sitting exactly on redirectEnd, and the entry named after the document
    // that actually loaded rather than the URL the navigation asked for.
    const session = testing.test_session;
    defer session.closeAllPages();

    const page = try session.createPage();
    defer page.close();
    try page.navigate("http://127.0.0.1:9582/redirect_nav_timing", .{});

    var runner = session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });

    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    try expectAllTrue(&ls.local, &.{
        "performance.navigation.redirectCount === 1",
        "performance.getEntriesByType('navigation')[0].redirectCount === 1",
        "performance.timing.redirectStart > 0",
        "performance.timing.redirectEnd >= performance.timing.redirectStart",
        "performance.timing.fetchStart >= performance.timing.redirectEnd",
        "performance.getEntriesByType('navigation')[0].redirectEnd > 0",
        "performance.getEntriesByType('navigation')[0].fetchStart >= performance.getEntriesByType('navigation')[0].redirectEnd",
        "performance.getEntriesByType('navigation')[0].name === location.href",
    });
}

test "WebApi: Performance hides a cross-origin navigation redirect" {
    // The other half of the same reading: a hop onto the localhost alias is a
    // different origin, so the timing allow check fails and Chrome reports no
    // redirect at all -- while fetchStart still moves past it, because the
    // document really did arrive second (measured, same sitting).
    const session = testing.test_session;
    defer session.closeAllPages();

    const page = try session.createPage();
    defer page.close();
    try page.navigate("http://127.0.0.1:9582/redirect_nav_timing_cross", .{});

    var runner = session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });

    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    try expectAllTrue(&ls.local, &.{
        "performance.navigation.redirectCount === 0",
        "performance.getEntriesByType('navigation')[0].redirectCount === 0",
        "performance.timing.redirectStart === 0",
        "performance.timing.redirectEnd === 0",
        "performance.getEntriesByType('navigation')[0].redirectStart === 0",
        "performance.getEntriesByType('navigation')[0].redirectEnd === 0",
        "performance.getEntriesByType('navigation')[0].name === location.href",
    });
}

/// Evaluates each expression and fails naming the first one that was not true,
/// so a row of related invariants can be asserted without one `expect` per line.
fn expectAllTrue(local: *const js.Local, exprs: []const []const u8) !void {
    for (exprs) |expr| {
        const value = try local.exec(expr, null);
        if (value.toBool() == false) {
            std.debug.print("expected true: {s}\n", .{expr});
            return error.TestUnexpectedResult;
        }
    }
}
