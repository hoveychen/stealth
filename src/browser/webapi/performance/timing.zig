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

//! The PerformanceEntry subclasses, plus the two helper interfaces they drag
//! in (PerformanceTimingConfidence, PerformanceServerTiming).
//!
//! Only PerformanceResourceTiming and PerformanceNavigationTiming carry real
//! data: `performance.getEntriesByType('navigation')` returns one live entry
//! whose numbers come from the fetch and load milestones the frame actually
//! passed through (see `Timing` below and Frame's calls into it). Everything a
//! renderer would have to paint or observe to produce — element timing, event
//! timing, layout shifts, largest contentful paint, long tasks — is shape only:
//! the globals exist because CreepJS counts them and browserleaks walks their
//! prototypes, but nothing here ever produces an instance.
//!
//! Shapes measured on a headed Chrome 150 over http://localhost
//! (win20-chrome.json for the eleven interfaces, win24/win25-chrome.json for
//! the Performance host object, the entry toJSON key lists, and the two classes
//! win20's list did not name).

const std = @import("std");

const js = @import("../../js/js.zig");
const http = @import("../../../network/http.zig");

const Element = @import("../Element.zig");
const DOMRectReadOnly = @import("../DOMRectReadOnly.zig");
const Performance = @import("../Performance.zig");

const Entry = Performance.Entry;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        ResourceTiming,
        NavigationTiming,
        TimingConfidence,
        ServerTiming,
        PaintTiming,
        ElementTiming,
        EventTiming,
        LongTaskTiming,
        TaskAttributionTiming,
        LargestContentfulPaint,
        LayoutShift,
        LayoutShiftAttribution,
        VisibilityStateEntry,

        // Prototype surface only -- nothing queues one and Chrome does not let
        // a page build one. See the section at the bottom of this file.
        PerformanceLongAnimationFrameTiming,
        PerformanceScriptTiming,
        PerformanceSoftNavigation,
        InteractionContentfulPaint,
    };
}

/// The numbers behind one PerformanceResourceTiming, owned by whoever
/// performed the fetch and mutated in place as the load progresses — the entry
/// object reads through to it, so a script that grabbed the entry early sees
/// the later milestones too, exactly as Chrome's does.
///
/// Every timestamp is milliseconds relative to the Performance time origin.
/// The trailing block is navigation-only; a plain resource entry leaves it at
/// zero.
pub const Timing = struct {
    // Which navigation this entry belongs to. Every entry in one navigation
    // carries the same number and the next navigation draws a fresh one; see
    // Performance.newNavigationId.
    navigation_id: u32 = 0,

    initiator_type: []const u8 = "navigation",
    next_hop_protocol: []const u8 = "",
    delivery_type: []const u8 = "",
    render_blocking_status: []const u8 = "non-blocking",
    content_type: []const u8 = "",
    content_encoding: []const u8 = "",

    worker_start: f64 = 0,
    redirect_start: f64 = 0,
    redirect_end: f64 = 0,
    fetch_start: f64 = 0,
    domain_lookup_start: f64 = 0,
    domain_lookup_end: f64 = 0,
    connect_start: f64 = 0,
    connect_end: f64 = 0,
    secure_connection_start: f64 = 0,
    request_start: f64 = 0,
    response_start: f64 = 0,
    first_interim_response_start: f64 = 0,
    final_response_headers_start: f64 = 0,
    response_end: f64 = 0,

    encoded_body_size: u64 = 0,
    decoded_body_size: u64 = 0,
    response_status: u16 = 0,

    // Whether a response actually arrived. `response_status != 0` used to stand
    // in for this, and cannot any more: `maskCrossOrigin` zeroes the status of
    // an entry that DID respond, and transferSize still has to answer for it
    // (Chrome reports 4438 bytes for a cross-origin entry whose responseStatus
    // reads 0 -- measured, probes/expr-b87-crossorigin.js).
    responded: bool = false,

    unload_event_start: f64 = 0,
    unload_event_end: f64 = 0,
    dom_interactive: f64 = 0,
    dom_content_loaded_event_start: f64 = 0,
    dom_content_loaded_event_end: f64 = 0,
    dom_complete: f64 = 0,
    load_event_start: f64 = 0,
    load_event_end: f64 = 0,
    navigation_type: []const u8 = "navigate",
    redirect_count: u32 = 0,

    /// Chrome's transferSize is the body plus a flat 300 bytes of header
    /// overhead — measured twice, on a 104-byte document (404) and on a
    /// 460-byte 404 page (760). A response served from cache reports 0, which
    /// nothing here produces yet.
    pub fn transferSize(self: *const Timing) f64 {
        if (!self.responded) {
            return 0;
        }
        return @floatFromInt(self.encoded_body_size + 300);
    }

    /// Hides from a page what Resource Timing does not let it see about a load
    /// from another origin.
    ///
    /// Two gates, and they are governed by different things, which is the part
    /// that is easy to get wrong. Measured on a two-origin fixture
    /// (probes/b87-crossorigin-fixture.mjs + probes/expr-b87-crossorigin.js)
    /// against Chrome, where the last two rows are the ones that settle it:
    ///
    ///   load            mode      TAO   sizes/proto/walk   status   contentType
    ///   same-origin     --        --    real               200      real
    ///   <img>           no-cors   no    0                  0        ''
    ///   <img>           no-cors   yes   real               0        ''
    ///   <iframe>        no-cors   yes   real               0        ''
    ///   fetch()         cors      no    0                  200      real
    ///   fetch()         cors      yes   real               200      real
    ///
    /// So `Timing-Allow-Origin` governs the *timing and the sizes* and nothing
    /// else, while the status and the content type ride on the response TYPE:
    /// a CORS-mode request that succeeded is not an opaque response, and its
    /// status is the page's to read whatever TAO says. Reading the status gate
    /// as "same origin" -- which the <img> rows alone would suggest -- hides
    /// the status of every cross-origin fetch and XHR, and is contradicted on
    /// the live station too: Chrome reports cf-scrapingcourse's cross-origin
    /// api.js with responseStatus 200.
    ///
    /// What survives either way is `fetchStart`, `responseEnd` and therefore
    /// `startTime` and `duration` -- a page may always know that it loaded
    /// something and how long it took. This engine hid none of it before: every
    /// cross-origin entry carried its real byte count, protocol and connection
    /// walk, which on cf-scrapingcourse handed the page the widget document's
    /// exact size.
    ///
    /// `content_encoding` and `delivery_type` are deliberately left alone: both
    /// read empty in all seven rows of the fixture on both arms, so the reading
    /// does not say which side of either gate they sit on, and blanking a field
    /// on a guess is how the wrong subset gets zeroed.
    pub fn maskCrossOrigin(self: *Timing, same_origin: bool, cors_response: bool, timing_allowed: bool) void {
        if (!same_origin and !cors_response) {
            self.response_status = 0;
            self.content_type = "";
        }
        if (timing_allowed) {
            return;
        }
        self.next_hop_protocol = "";
        self.encoded_body_size = 0;
        self.decoded_body_size = 0;
        // Not "collapsed onto fetchStart", which is what a REUSED connection
        // reports; an opaque entry reports a true zero, and confusing the two
        // would say every cross-origin load rode a warm socket.
        self.responded = false;
        self.worker_start = 0;
        self.redirect_start = 0;
        self.redirect_end = 0;
        self.domain_lookup_start = 0;
        self.domain_lookup_end = 0;
        self.connect_start = 0;
        self.connect_end = 0;
        self.secure_connection_start = 0;
        self.request_start = 0;
        self.response_start = 0;
        self.first_interim_response_start = 0;
        self.final_response_headers_start = 0;
    }

    /// Restates every timestamp in this record on another document's timeline.
    ///
    /// `shift_ms` is how much later this record's document started than
    /// `host`'s, so adding it moves a stamp from one origin to the other; the
    /// result goes back onto `host`'s lattice for the same reason
    /// `setConnectionMilestones` snaps its own arithmetic, since the page reads
    /// these beside `host`'s `now()`.
    ///
    /// Done by reflection rather than by naming the fields because the
    /// invariant is exactly "every f64 here is milliseconds since the owning
    /// document's time origin" (see the struct's own doc comment) — a list
    /// would be a second place for a later field to fall off of.
    ///
    /// A zero is left alone: it means the milestone did not happen (no
    /// redirect, no TLS, no 1xx), and shifting it would report one that did.
    pub fn restateOn(self: *Timing, host: *const Performance, shift_ms: f64) void {
        inline for (std.meta.fields(Timing)) |field| {
            if (comptime field.type == f64) {
                const value = @field(self, field.name);
                if (value != 0) {
                    @field(self, field.name) = host.snapMs(value + shift_ms);
                }
            }
        }
    }

    /// Lays libcurl's connection walk onto the eight milestones between
    /// fetchStart and responseStart. `fetch_start` must already be set.
    ///
    /// Chrome 151 over plain HTTP fills seven of the nine and leaves exactly
    /// two at zero: secureConnectionStart, because there is no TLS handshake to
    /// time, and firstInterimResponseStart, because there was no 1xx (measured,
    /// tools/fingerprint/resource-timing-response-fields.mjs). A reused
    /// connection collapses the first four onto fetchStart, which is what a
    /// browser reports for one too — nothing was looked up and nothing opened.
    ///
    /// curl has no name-resolution *start*: it starts resolving as soon as the
    /// transfer does, so domainLookupStart is fetchStart.
    ///
    /// curl reports the walk in microseconds and the clock the page reads is
    /// clamped coarser than that, so every milestone goes back onto that grid
    /// on the way in -- the same grid `fetchStart` and `responseEnd` are
    /// already on, since both come from `now()`. Two milestones inside one
    /// grid step therefore land on the same number, which is what a browser
    /// reports for them too.
    pub fn setConnectionMilestones(self: *Timing, times: http.ResponseTimes, perf: *const Performance) void {
        const at = self.fetch_start;
        const ms = struct {
            fn f(p: *const Performance, base: f64, micros: u64) f64 {
                return p.snapMs(base + @as(f64, @floatFromInt(micros)) / 1000.0);
            }
        }.f;

        self.domain_lookup_start = at;
        self.domain_lookup_end = ms(perf, at, times.name_lookup);
        self.connect_start = self.domain_lookup_end;

        if (times.app_connect > 0) {
            // The TLS handshake begins once the socket is up, so the TCP
            // connect time is where the secure part starts.
            self.secure_connection_start = ms(perf, at, times.connect);
            self.connect_end = ms(perf, at, times.app_connect);
        } else {
            self.connect_end = ms(perf, at, times.connect);
            // A REUSED connection reports no handshake, and the two schemes
            // part company here: over https Chrome still answers
            // `secureConnectionStart`, collapsed onto fetchStart like the rest
            // of the walk, and over http it answers 0. Reporting 0 for both
            // said every https entry this engine produced had negotiated no
            // TLS at all -- one expression on any entry of any https page.
            if (times.secure) self.secure_connection_start = at;
        }

        self.request_start = ms(perf, at, times.pre_transfer);
        self.response_start = ms(perf, at, times.start_transfer);
        self.final_response_headers_start = self.response_start;
    }
};

pub const ResourceTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _timing: *const Timing,

    /// The 34 keys Chrome's PerformanceResourceTiming.toJSON() answers, in
    /// Chrome's order — which is not the prototype's order (measured: the
    /// prototype interleaves secureConnectionStart between connectStart and
    /// connectEnd, toJSON does not).
    pub const Json = struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        navigationId: u32,
        initiatorType: []const u8,
        deliveryType: []const u8,
        nextHopProtocol: []const u8,
        renderBlockingStatus: []const u8,
        contentType: []const u8,
        contentEncoding: []const u8,
        workerStart: f64,
        workerRouterEvaluationStart: f64,
        workerCacheLookupStart: f64,
        workerMatchedSourceType: []const u8,
        workerFinalSourceType: []const u8,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        secureConnectionStart: f64,
        connectEnd: f64,
        requestStart: f64,
        responseStart: f64,
        firstInterimResponseStart: f64,
        finalResponseHeadersStart: f64,
        responseEnd: f64,
        transferSize: f64,
        encodedBodySize: f64,
        decodedBodySize: f64,
        responseStatus: u16,
        serverTiming: []const *ServerTiming,
    };

    pub fn json(self: *const ResourceTiming) Json {
        const t = self._timing;
        return .{
            .name = self._proto._name,
            .entryType = self._proto.getEntryType(),
            .startTime = self._proto._start_time,
            .duration = self._proto._duration,
            .navigationId = t.navigation_id,
            .initiatorType = t.initiator_type,
            .deliveryType = t.delivery_type,
            .nextHopProtocol = t.next_hop_protocol,
            .renderBlockingStatus = t.render_blocking_status,
            .contentType = t.content_type,
            .contentEncoding = t.content_encoding,
            .workerStart = t.worker_start,
            .workerRouterEvaluationStart = 0,
            .workerCacheLookupStart = 0,
            .workerMatchedSourceType = "",
            .workerFinalSourceType = "",
            .redirectStart = t.redirect_start,
            .redirectEnd = t.redirect_end,
            .fetchStart = t.fetch_start,
            .domainLookupStart = t.domain_lookup_start,
            .domainLookupEnd = t.domain_lookup_end,
            .connectStart = t.connect_start,
            .secureConnectionStart = t.secure_connection_start,
            .connectEnd = t.connect_end,
            .requestStart = t.request_start,
            .responseStart = t.response_start,
            .firstInterimResponseStart = t.first_interim_response_start,
            .finalResponseHeadersStart = t.final_response_headers_start,
            .responseEnd = t.response_end,
            .transferSize = t.transferSize(),
            .encodedBodySize = @floatFromInt(t.encoded_body_size),
            .decodedBodySize = @floatFromInt(t.decoded_body_size),
            .responseStatus = t.response_status,
            .serverTiming = &.{},
        };
    }

    fn initiatorType(self: *const ResourceTiming) []const u8 {
        return self._timing.initiator_type;
    }

    fn nextHopProtocol(self: *const ResourceTiming) []const u8 {
        return self._timing.next_hop_protocol;
    }

    fn deliveryType(self: *const ResourceTiming) []const u8 {
        return self._timing.delivery_type;
    }

    fn renderBlockingStatus(self: *const ResourceTiming) []const u8 {
        return self._timing.render_blocking_status;
    }

    fn contentType(self: *const ResourceTiming) []const u8 {
        return self._timing.content_type;
    }

    fn contentEncoding(self: *const ResourceTiming) []const u8 {
        return self._timing.content_encoding;
    }

    fn workerStart(self: *const ResourceTiming) f64 {
        return self._timing.worker_start;
    }

    fn redirectStart(self: *const ResourceTiming) f64 {
        return self._timing.redirect_start;
    }

    fn redirectEnd(self: *const ResourceTiming) f64 {
        return self._timing.redirect_end;
    }

    fn fetchStart(self: *const ResourceTiming) f64 {
        return self._timing.fetch_start;
    }

    fn domainLookupStart(self: *const ResourceTiming) f64 {
        return self._timing.domain_lookup_start;
    }

    fn domainLookupEnd(self: *const ResourceTiming) f64 {
        return self._timing.domain_lookup_end;
    }

    fn connectStart(self: *const ResourceTiming) f64 {
        return self._timing.connect_start;
    }

    fn connectEnd(self: *const ResourceTiming) f64 {
        return self._timing.connect_end;
    }

    fn secureConnectionStart(self: *const ResourceTiming) f64 {
        return self._timing.secure_connection_start;
    }

    fn requestStart(self: *const ResourceTiming) f64 {
        return self._timing.request_start;
    }

    fn responseStart(self: *const ResourceTiming) f64 {
        return self._timing.response_start;
    }

    fn responseEnd(self: *const ResourceTiming) f64 {
        return self._timing.response_end;
    }

    fn firstInterimResponseStart(self: *const ResourceTiming) f64 {
        return self._timing.first_interim_response_start;
    }

    fn finalResponseHeadersStart(self: *const ResourceTiming) f64 {
        return self._timing.final_response_headers_start;
    }

    fn transferSize(self: *const ResourceTiming) f64 {
        return self._timing.transferSize();
    }

    fn encodedBodySize(self: *const ResourceTiming) f64 {
        return @floatFromInt(self._timing.encoded_body_size);
    }

    fn decodedBodySize(self: *const ResourceTiming) f64 {
        return @floatFromInt(self._timing.decoded_body_size);
    }

    fn responseStatus(self: *const ResourceTiming) u16 {
        return self._timing.response_status;
    }

    fn workerZero(_: *const ResourceTiming) f64 {
        return 0;
    }

    fn workerEmpty(_: *const ResourceTiming) []const u8 {
        return "";
    }

    fn serverTiming(_: *const ResourceTiming) js.FrozenArray(*ServerTiming) {
        return .empty;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResourceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceResourceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const R = ResourceTiming;

        // No `navigationId`: it is PerformanceEntry's, inherited (measured --
        // Chrome's PerformanceResourceTiming.prototype does not own one).
        pub const initiatorType = bridge.accessor(R.initiatorType, null, .{});
        pub const nextHopProtocol = bridge.accessor(R.nextHopProtocol, null, .{});
        pub const deliveryType = bridge.accessor(R.deliveryType, null, .{});
        pub const workerStart = bridge.accessor(R.workerStart, null, .{});
        pub const redirectStart = bridge.accessor(R.redirectStart, null, .{});
        pub const redirectEnd = bridge.accessor(R.redirectEnd, null, .{});
        pub const fetchStart = bridge.accessor(R.fetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(R.domainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(R.domainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(R.connectStart, null, .{});
        pub const connectEnd = bridge.accessor(R.connectEnd, null, .{});
        pub const secureConnectionStart = bridge.accessor(R.secureConnectionStart, null, .{});
        pub const requestStart = bridge.accessor(R.requestStart, null, .{});
        pub const responseStart = bridge.accessor(R.responseStart, null, .{});
        pub const responseEnd = bridge.accessor(R.responseEnd, null, .{});
        pub const transferSize = bridge.accessor(R.transferSize, null, .{});
        pub const encodedBodySize = bridge.accessor(R.encodedBodySize, null, .{});
        pub const decodedBodySize = bridge.accessor(R.decodedBodySize, null, .{});
        pub const serverTiming = bridge.accessor(R.serverTiming, null, .{});
        pub const renderBlockingStatus = bridge.accessor(R.renderBlockingStatus, null, .{});
        pub const responseStatus = bridge.accessor(R.responseStatus, null, .{});
        pub const contentType = bridge.accessor(R.contentType, null, .{});
        pub const contentEncoding = bridge.accessor(R.contentEncoding, null, .{});
        pub const finalResponseHeadersStart = bridge.accessor(R.finalResponseHeadersStart, null, .{});
        pub const firstInterimResponseStart = bridge.accessor(R.firstInterimResponseStart, null, .{});
        pub const toJSON = bridge.function(R.json, .{});
        pub const workerRouterEvaluationStart = bridge.accessor(R.workerZero, null, .{});
        pub const workerCacheLookupStart = bridge.accessor(R.workerZero, null, .{});
        pub const workerMatchedSourceType = bridge.accessor(R.workerEmpty, null, .{});
        pub const workerFinalSourceType = bridge.accessor(R.workerEmpty, null, .{});
    };
};

pub const NavigationTiming = struct {
    pub const Proto = ResourceTiming;

    _proto: *ResourceTiming,
    _confidence: TimingConfidence = .{},

    /// PerformanceResourceTiming's 34 keys followed by navigation's own 14, in
    /// Chrome's order (win25-chrome.json `confidenceValues.navToJSONKeys`).
    pub const Json = struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        navigationId: u32,
        initiatorType: []const u8,
        deliveryType: []const u8,
        nextHopProtocol: []const u8,
        renderBlockingStatus: []const u8,
        contentType: []const u8,
        contentEncoding: []const u8,
        workerStart: f64,
        workerRouterEvaluationStart: f64,
        workerCacheLookupStart: f64,
        workerMatchedSourceType: []const u8,
        workerFinalSourceType: []const u8,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        secureConnectionStart: f64,
        connectEnd: f64,
        requestStart: f64,
        responseStart: f64,
        firstInterimResponseStart: f64,
        finalResponseHeadersStart: f64,
        responseEnd: f64,
        transferSize: f64,
        encodedBodySize: f64,
        decodedBodySize: f64,
        responseStatus: u16,
        serverTiming: []const *ServerTiming,
        unloadEventStart: f64,
        unloadEventEnd: f64,
        domInteractive: f64,
        domContentLoadedEventStart: f64,
        domContentLoadedEventEnd: f64,
        domComplete: f64,
        loadEventStart: f64,
        loadEventEnd: f64,
        type: []const u8,
        redirectCount: u32,
        activationStart: f64,
        criticalCHRestart: f64,
        notRestoredReasons: ?u8,
        confidence: *TimingConfidence,
    };

    pub fn json(self: *NavigationTiming) Json {
        const base = self._proto.json();
        const t = self._proto._timing;
        return .{
            .name = base.name,
            .entryType = base.entryType,
            .startTime = base.startTime,
            .duration = base.duration,
            .navigationId = base.navigationId,
            .initiatorType = base.initiatorType,
            .deliveryType = base.deliveryType,
            .nextHopProtocol = base.nextHopProtocol,
            .renderBlockingStatus = base.renderBlockingStatus,
            .contentType = base.contentType,
            .contentEncoding = base.contentEncoding,
            .workerStart = base.workerStart,
            .workerRouterEvaluationStart = base.workerRouterEvaluationStart,
            .workerCacheLookupStart = base.workerCacheLookupStart,
            .workerMatchedSourceType = base.workerMatchedSourceType,
            .workerFinalSourceType = base.workerFinalSourceType,
            .redirectStart = base.redirectStart,
            .redirectEnd = base.redirectEnd,
            .fetchStart = base.fetchStart,
            .domainLookupStart = base.domainLookupStart,
            .domainLookupEnd = base.domainLookupEnd,
            .connectStart = base.connectStart,
            .secureConnectionStart = base.secureConnectionStart,
            .connectEnd = base.connectEnd,
            .requestStart = base.requestStart,
            .responseStart = base.responseStart,
            .firstInterimResponseStart = base.firstInterimResponseStart,
            .finalResponseHeadersStart = base.finalResponseHeadersStart,
            .responseEnd = base.responseEnd,
            .transferSize = base.transferSize,
            .encodedBodySize = base.encodedBodySize,
            .decodedBodySize = base.decodedBodySize,
            .responseStatus = base.responseStatus,
            .serverTiming = base.serverTiming,
            .unloadEventStart = t.unload_event_start,
            .unloadEventEnd = t.unload_event_end,
            .domInteractive = t.dom_interactive,
            .domContentLoadedEventStart = t.dom_content_loaded_event_start,
            .domContentLoadedEventEnd = t.dom_content_loaded_event_end,
            .domComplete = t.dom_complete,
            .loadEventStart = t.load_event_start,
            .loadEventEnd = t.load_event_end,
            .type = t.navigation_type,
            .redirectCount = t.redirect_count,
            .activationStart = 0,
            .criticalCHRestart = 0,
            .notRestoredReasons = null,
            .confidence = &self._confidence,
        };
    }

    fn unloadEventStart(self: *const NavigationTiming) f64 {
        return self._proto._timing.unload_event_start;
    }

    fn unloadEventEnd(self: *const NavigationTiming) f64 {
        return self._proto._timing.unload_event_end;
    }

    fn domInteractive(self: *const NavigationTiming) f64 {
        return self._proto._timing.dom_interactive;
    }

    fn domContentLoadedEventStart(self: *const NavigationTiming) f64 {
        return self._proto._timing.dom_content_loaded_event_start;
    }

    fn domContentLoadedEventEnd(self: *const NavigationTiming) f64 {
        return self._proto._timing.dom_content_loaded_event_end;
    }

    fn domComplete(self: *const NavigationTiming) f64 {
        return self._proto._timing.dom_complete;
    }

    fn loadEventStart(self: *const NavigationTiming) f64 {
        return self._proto._timing.load_event_start;
    }

    fn loadEventEnd(self: *const NavigationTiming) f64 {
        return self._proto._timing.load_event_end;
    }

    fn navigationType(self: *const NavigationTiming) []const u8 {
        return self._proto._timing.navigation_type;
    }

    fn redirectCount(self: *const NavigationTiming) u32 {
        return self._proto._timing.redirect_count;
    }

    fn zero(_: *const NavigationTiming) f64 {
        return 0;
    }

    fn confidence(self: *NavigationTiming) *TimingConfidence {
        return &self._confidence;
    }

    fn notRestoredReasons(_: *const NavigationTiming) ?u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigationTiming);

        pub const Meta = struct {
            pub const name = "PerformanceNavigationTiming";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "confidence";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const N = NavigationTiming;

        pub const unloadEventStart = bridge.accessor(N.unloadEventStart, null, .{});
        pub const unloadEventEnd = bridge.accessor(N.unloadEventEnd, null, .{});
        pub const domInteractive = bridge.accessor(N.domInteractive, null, .{});
        pub const domContentLoadedEventStart = bridge.accessor(N.domContentLoadedEventStart, null, .{});
        pub const domContentLoadedEventEnd = bridge.accessor(N.domContentLoadedEventEnd, null, .{});
        pub const domComplete = bridge.accessor(N.domComplete, null, .{});
        pub const loadEventStart = bridge.accessor(N.loadEventStart, null, .{});
        pub const loadEventEnd = bridge.accessor(N.loadEventEnd, null, .{});
        pub const @"type" = bridge.accessor(N.navigationType, null, .{});
        pub const redirectCount = bridge.accessor(N.redirectCount, null, .{});
        pub const criticalCHRestart = bridge.accessor(N.zero, null, .{});
        pub const activationStart = bridge.accessor(N.zero, null, .{});
        pub const toJSON = bridge.function(N.json, .{});
        pub const confidence = bridge.accessor(N.confidence, null, .{});
        pub const notRestoredReasons = bridge.accessor(N.notRestoredReasons, null, .{});
    };
};

/// navigation.confidence. Chrome's randomizedTriggerRate is a per-build
/// constant, not per-navigation noise: two Chrome launches with fresh profiles
/// both answered 0.4994798 (win24, win25).
pub const TimingConfidence = struct {
    _pad: bool = false,

    pub const Json = struct {
        randomizedTriggerRate: f64,
        value: []const u8,
    };

    fn json(_: *const TimingConfidence) Json {
        return .{ .randomizedTriggerRate = 0.4994798, .value = "high" };
    }

    fn randomizedTriggerRate(_: *const TimingConfidence) f64 {
        return 0.4994798;
    }

    fn value(_: *const TimingConfidence) []const u8 {
        return "high";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TimingConfidence);

        pub const Meta = struct {
            pub const name = "PerformanceTimingConfidence";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const C = TimingConfidence;

        pub const randomizedTriggerRate = bridge.accessor(C.randomizedTriggerRate, null, .{});
        pub const value = bridge.accessor(C.value, null, .{});
        pub const toJSON = bridge.function(C.json, .{});
    };
};

/// A Server-Timing header entry. Nothing parses that header here yet, so the
/// class exists for the global count and for resourceTiming.serverTiming's
/// element type.
pub const ServerTiming = struct {
    _pad: bool = false,

    pub const Json = struct {
        name: []const u8,
        duration: f64,
        description: []const u8,
    };

    fn json(_: *const ServerTiming) Json {
        return .{ .name = "", .duration = 0, .description = "" };
    }

    fn empty(_: *const ServerTiming) []const u8 {
        return "";
    }

    fn zero(_: *const ServerTiming) f64 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ServerTiming);

        pub const Meta = struct {
            pub const name = "PerformanceServerTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const S = ServerTiming;

        pub const name = bridge.accessor(S.empty, null, .{});
        pub const duration = bridge.accessor(S.zero, null, .{});
        pub const description = bridge.accessor(S.empty, null, .{});
        pub const toJSON = bridge.function(S.json, .{});
    };
};

pub const PaintTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _paint_time: f64,

    pub const Json = struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        // Fifth, as on every entry -- PerformanceEntry's own four plus this
        // one, then whatever the subclass adds (measured).
        navigationId: u32,
        paintTime: f64,
        presentationTime: f64,
    };

    fn json(self: *const PaintTiming, exec: *const Execution) Json {
        return .{
            .name = self._proto._name,
            .entryType = self._proto.getEntryType(),
            .startTime = self._proto._start_time,
            .duration = self._proto._duration,
            .navigationId = self._proto.getNavigationId(exec),
            .paintTime = self._paint_time,
            .presentationTime = self._proto._start_time,
        };
    }

    fn paintTime(self: *const PaintTiming) f64 {
        return self._paint_time;
    }

    fn presentationTime(self: *const PaintTiming) f64 {
        return self._proto._start_time;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PaintTiming);

        pub const Meta = struct {
            pub const name = "PerformancePaintTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const P = PaintTiming;

        pub const paintTime = bridge.accessor(P.paintTime, null, .{});
        pub const presentationTime = bridge.accessor(P.presentationTime, null, .{});
        pub const toJSON = bridge.function(P.json, .{});
    };
};

pub const ElementTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const ElementTiming) f64 {
        return 0;
    }

    fn empty(_: *const ElementTiming) []const u8 {
        return "";
    }

    fn rect(_: *const ElementTiming) ?*DOMRectReadOnly {
        return null;
    }

    fn element(_: *const ElementTiming) ?*Element {
        return null;
    }

    fn json(_: *const ElementTiming) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ElementTiming);

        pub const Meta = struct {
            pub const name = "PerformanceElementTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const E = ElementTiming;

        pub const renderTime = bridge.accessor(E.zero, null, .{});
        pub const loadTime = bridge.accessor(E.zero, null, .{});
        pub const intersectionRect = bridge.accessor(E.rect, null, .{});
        pub const identifier = bridge.accessor(E.empty, null, .{});
        pub const naturalWidth = bridge.accessor(E.zero, null, .{});
        pub const naturalHeight = bridge.accessor(E.zero, null, .{});
        pub const id = bridge.accessor(E.empty, null, .{});
        pub const element = bridge.accessor(E.element, null, .{});
        pub const url = bridge.accessor(E.empty, null, .{});
        pub const toJSON = bridge.function(E.json, .{});
        pub const paintTime = bridge.accessor(E.zero, null, .{});
        pub const presentationTime = bridge.accessor(E.zero, null, .{});
    };
};

pub const EventTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const EventTiming) f64 {
        return 0;
    }

    fn cancelable(_: *const EventTiming) bool {
        return false;
    }

    fn target(_: *const EventTiming) ?*Element {
        return null;
    }

    fn interactionId(_: *const EventTiming) u32 {
        return 0;
    }

    fn json(_: *const EventTiming) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(EventTiming);

        pub const Meta = struct {
            pub const name = "PerformanceEventTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const E = EventTiming;

        pub const processingStart = bridge.accessor(E.zero, null, .{});
        pub const processingEnd = bridge.accessor(E.zero, null, .{});
        pub const cancelable = bridge.accessor(E.cancelable, null, .{});
        pub const target = bridge.accessor(E.target, null, .{});
        pub const interactionId = bridge.accessor(E.interactionId, null, .{});
        pub const toJSON = bridge.function(E.json, .{});
    };
};

pub const LongTaskTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn attribution(_: *const LongTaskTiming) []const *TaskAttributionTiming {
        return &.{};
    }

    fn json(_: *const LongTaskTiming) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LongTaskTiming);

        pub const Meta = struct {
            pub const name = "PerformanceLongTaskTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const attribution = bridge.accessor(LongTaskTiming.attribution, null, .{});
        pub const toJSON = bridge.function(LongTaskTiming.json, .{});
    };
};

pub const TaskAttributionTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn empty(_: *const TaskAttributionTiming) []const u8 {
        return "";
    }

    fn json(_: *const TaskAttributionTiming) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TaskAttributionTiming);

        pub const Meta = struct {
            pub const name = "TaskAttributionTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = TaskAttributionTiming;

        pub const containerType = bridge.accessor(T.empty, null, .{});
        pub const containerSrc = bridge.accessor(T.empty, null, .{});
        pub const containerId = bridge.accessor(T.empty, null, .{});
        pub const containerName = bridge.accessor(T.empty, null, .{});
        pub const toJSON = bridge.function(T.json, .{});
    };
};

pub const LargestContentfulPaint = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const LargestContentfulPaint) f64 {
        return 0;
    }

    fn size(_: *const LargestContentfulPaint) u32 {
        return 0;
    }

    fn empty(_: *const LargestContentfulPaint) []const u8 {
        return "";
    }

    fn element(_: *const LargestContentfulPaint) ?*Element {
        return null;
    }

    fn json(_: *const LargestContentfulPaint) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LargestContentfulPaint);

        pub const Meta = struct {
            pub const name = "LargestContentfulPaint";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const L = LargestContentfulPaint;

        pub const renderTime = bridge.accessor(L.zero, null, .{});
        pub const loadTime = bridge.accessor(L.zero, null, .{});
        pub const size = bridge.accessor(L.size, null, .{});
        pub const id = bridge.accessor(L.empty, null, .{});
        pub const url = bridge.accessor(L.empty, null, .{});
        pub const element = bridge.accessor(L.element, null, .{});
        pub const toJSON = bridge.function(L.json, .{});
        pub const paintTime = bridge.accessor(L.zero, null, .{});
        pub const presentationTime = bridge.accessor(L.zero, null, .{});
    };
};

pub const LayoutShift = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const LayoutShift) f64 {
        return 0;
    }

    fn hadRecentInput(_: *const LayoutShift) bool {
        return false;
    }

    fn sources(_: *const LayoutShift) []const *LayoutShiftAttribution {
        return &.{};
    }

    fn json(_: *const LayoutShift) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LayoutShift);

        pub const Meta = struct {
            pub const name = "LayoutShift";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const L = LayoutShift;

        pub const value = bridge.accessor(L.zero, null, .{});
        pub const hadRecentInput = bridge.accessor(L.hadRecentInput, null, .{});
        pub const lastInputTime = bridge.accessor(L.zero, null, .{});
        pub const sources = bridge.accessor(L.sources, null, .{});
        pub const toJSON = bridge.function(L.json, .{});
    };
};

pub const LayoutShiftAttribution = struct {
    _pad: bool = false,

    fn node(_: *const LayoutShiftAttribution) ?*Element {
        return null;
    }

    fn rect(_: *const LayoutShiftAttribution) ?*DOMRectReadOnly {
        return null;
    }

    fn json(_: *const LayoutShiftAttribution) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LayoutShiftAttribution);

        pub const Meta = struct {
            pub const name = "LayoutShiftAttribution";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const L = LayoutShiftAttribution;

        pub const node = bridge.accessor(L.node, null, .{});
        pub const previousRect = bridge.accessor(L.rect, null, .{});
        pub const currentRect = bridge.accessor(L.rect, null, .{});
        pub const toJSON = bridge.function(L.json, .{});
    };
};

/// Chrome logs one of these per visibilitychange, starting with a `visible`
/// entry at startTime 0. It adds nothing of its own — the whole interface is
/// PerformanceEntry plus a brand (measured: protoKeys is just `constructor`).
pub const VisibilityStateEntry = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VisibilityStateEntry);

        pub const Meta = struct {
            pub const name = "VisibilityStateEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

// ---------------------------------------------------------------------------
// Prototype surface only: four more entry subclasses
// ---------------------------------------------------------------------------
//
// Chrome 151 puts four more PerformanceEntry subclasses on the window than the
// eleven above. Nothing here queues one — there is no frame-timing pass, no
// script attribution, no soft-navigation heuristic and no interaction paint —
// and Chrome does not let a page build one either, so the interface object and
// the prototype are the whole surface, same as LargestContentfulPaint's.
//
// Every member list, order and arity is Chrome's own, measured with
// probes/probe-shapes.js on http://localhost:8777 (readings in
// results/probes/probe-shapes.chrome.json). `paintTime` and `presentationTime`
// come last on the three that have them, *after* toJSON, and they are own
// properties of each prototype rather than inherited — which is the shape
// LargestContentfulPaint already has here. None of the four is [SecureContext],
// and a Chrome worker has none of them (measured, probe-shapes-worker).

/// One `long-animation-frame` entry: a rendering frame that took long enough for
/// Chrome to attribute the blocking work inside it. `scripts` would hold the
/// PerformanceScriptTiming children below.
pub const PerformanceLongAnimationFrameTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const PerformanceLongAnimationFrameTiming) f64 {
        return 0;
    }

    fn scripts(_: *const PerformanceLongAnimationFrameTiming) []const js.Value {
        return &.{};
    }

    fn json(_: *const PerformanceLongAnimationFrameTiming) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceLongAnimationFrameTiming);

        pub const Meta = struct {
            pub const name = "PerformanceLongAnimationFrameTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const L = PerformanceLongAnimationFrameTiming;

        pub const renderStart = bridge.accessor(L.zero, null, .{});
        pub const styleAndLayoutStart = bridge.accessor(L.zero, null, .{});
        pub const firstUIEventTimestamp = bridge.accessor(L.zero, null, .{});
        pub const blockingDuration = bridge.accessor(L.zero, null, .{});
        pub const scripts = bridge.accessor(L.scripts, null, .{});
        pub const toJSON = bridge.function(L.json, .{});
        pub const paintTime = bridge.accessor(L.zero, null, .{});
        pub const presentationTime = bridge.accessor(L.zero, null, .{});
    };
};

/// One `script` entry: a single callback or classic script inside a long
/// animation frame, with who invoked it and where it came from. `window` is the
/// window the invoker belonged to, which is why this one has no paintTime.
pub const PerformanceScriptTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const PerformanceScriptTiming) f64 {
        return 0;
    }

    fn empty(_: *const PerformanceScriptTiming) []const u8 {
        return "";
    }

    fn position(_: *const PerformanceScriptTiming) i32 {
        return -1;
    }

    /// A Window, and only the browser's own entry ever names one.
    fn nullWindow(_: *const PerformanceScriptTiming) ?js.Value {
        return null;
    }

    fn json(_: *const PerformanceScriptTiming) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceScriptTiming);

        pub const Meta = struct {
            pub const name = "PerformanceScriptTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const S = PerformanceScriptTiming;

        pub const invokerType = bridge.accessor(S.empty, null, .{});
        pub const invoker = bridge.accessor(S.empty, null, .{});
        pub const windowAttribution = bridge.accessor(S.empty, null, .{});
        pub const executionStart = bridge.accessor(S.zero, null, .{});
        pub const forcedStyleAndLayoutDuration = bridge.accessor(S.zero, null, .{});
        pub const pauseDuration = bridge.accessor(S.zero, null, .{});
        pub const window = bridge.accessor(S.nullWindow, null, .{});
        pub const sourceURL = bridge.accessor(S.empty, null, .{});
        pub const sourceFunctionName = bridge.accessor(S.empty, null, .{});
        pub const sourceCharPosition = bridge.accessor(S.position, null, .{});
        pub const toJSON = bridge.function(S.json, .{});
    };
};

/// One `soft-navigation` entry: a route change a single-page app made without a
/// document navigation, which Chrome detects heuristically. The only one of the
/// four with no toJSON of its own — it inherits PerformanceEntry's.
pub const PerformanceSoftNavigation = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const PerformanceSoftNavigation) f64 {
        return 0;
    }

    fn empty(_: *const PerformanceSoftNavigation) []const u8 {
        return "";
    }

    fn interactionId(_: *const PerformanceSoftNavigation) u32 {
        return 0;
    }

    fn largestInteractionContentfulPaint(_: *PerformanceSoftNavigation) []const js.Value {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceSoftNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceSoftNavigation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const N = PerformanceSoftNavigation;

        pub const navigationType = bridge.accessor(N.empty, null, .{});
        pub const interactionId = bridge.accessor(N.interactionId, null, .{});
        pub const getLargestInteractionContentfulPaint =
            bridge.function(N.largestInteractionContentfulPaint, .{});
        pub const paintTime = bridge.accessor(N.zero, null, .{});
        pub const presentationTime = bridge.accessor(N.zero, null, .{});
    };
};

/// One `interaction-contentful-paint` entry: the largest paint attributable to
/// one interaction, which is how INP gets a visual counterpart.
pub const InteractionContentfulPaint = struct {
    pub const Proto = Entry;

    _proto: *Entry,

    fn zero(_: *const InteractionContentfulPaint) f64 {
        return 0;
    }

    fn interactionId(_: *const InteractionContentfulPaint) u32 {
        return 0;
    }

    /// A LargestContentfulPaint, which only the browser's own entry carries.
    fn largestContentfulPaint(_: *const InteractionContentfulPaint) ?*LargestContentfulPaint {
        return null;
    }

    fn json(_: *const InteractionContentfulPaint) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(InteractionContentfulPaint);

        pub const Meta = struct {
            pub const name = "InteractionContentfulPaint";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const I = InteractionContentfulPaint;

        pub const largestContentfulPaint = bridge.accessor(I.largestContentfulPaint, null, .{});
        pub const interactionId = bridge.accessor(I.interactionId, null, .{});
        pub const toJSON = bridge.function(I.json, .{});
        pub const paintTime = bridge.accessor(I.zero, null, .{});
        pub const presentationTime = bridge.accessor(I.zero, null, .{});
    };
};
