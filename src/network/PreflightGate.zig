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

// CORS preflight gate for the HttpClient request pipeline. A cross-origin
// fetch()/XHR whose method or headers put it outside the CORS-safelist has to
// be announced with an OPTIONS first; only if the answer permits it does the
// real request go out.
//
// Shaped like RobotsGate, and for the same reason: "send an internal
// sub-request, then allow or refuse the original one" is a pipeline pattern
// this file borrows rather than reinvents. It parks the transfer, coalesces
// concurrent requests behind one preflight through SingleFlight, and resumes
// (or fails) the parked transfers when the answer lands.
//
// What is NOT here: any check of the *actual* response's Access-Control-Allow-
// Origin. This engine still reads a cross-origin body a browser would refuse,
// which is a separate and larger decision -- lightpanda exists to scrape pages
// -- than sending the OPTIONS the spec requires.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../browser/URL.zig");
const ArenaPool = @import("../ArenaPool.zig");

const cors = @import("cors.zig");
const Transfer = @import("HttpClient.zig").Transfer;
const SingleFlight = @import("SingleFlight.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const PreflightGate = @This();

// Chrome clamps Access-Control-Max-Age at 600 seconds no matter what the
// server asks for, so a long-lived cache entry cannot outlive a policy change
// by more than ten minutes.
const max_age_cap: u32 = 600;

allocator: Allocator,
single_flight: SingleFlight,

// Successful preflights only, keyed by everything the answer was about
// (origin, url, credentials mode, method, requested headers) and valued by
// when the entry stops being usable, on the boot clock. A refusal is not
// cached: the spec only caches success, and re-asking after a server-side fix
// is what a browser does.
cache: std.StringHashMapUnmanaged(u64) = .empty,

pub const Result = enum { allowed, pending };

pub fn deinit(self: *PreflightGate) void {
    var it = self.cache.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
    }
    self.cache.deinit(self.allocator);
    self.single_flight.deinit();
}

// What the preflight has to say about this request. Built on the transfer's
// arena, so it lives exactly as long as the transfer that needs it.
const Plan = struct {
    // The page's origin, for the Origin header and the Allow-Origin check.
    origin: []const u8,
    // Access-Control-Request-Method.
    method: []const u8,
    // Access-Control-Request-Headers, already lowercased, sorted and joined,
    // or null when every header the page set was safelisted.
    request_headers: ?[]const u8,
    with_credentials: bool,
};

pub fn check(self: *PreflightGate, transfer: *Transfer) !Result {
    const plan = try describe(transfer) orelse return .allowed;

    const arena = transfer.arena.allocator();
    const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}\x00{s}\x00{s}", .{
        plan.origin,
        transfer.req.url,
        if (plan.with_credentials) "include" else "omit",
        plan.method,
        plan.request_headers orelse "",
    });

    if (self.cache.getEntry(key)) |entry| {
        if (entry.value_ptr.* > lp.datetime.timestamp(.boot)) {
            return .allowed;
        }
        // Expired. Drop it now so the fresh answer can take the slot without
        // the put below having to reason about an existing key.
        const owned = entry.key_ptr.*;
        _ = self.cache.remove(key);
        self.allocator.free(owned);
    }

    try self.preflightThenResume(key, transfer, plan);
    return .pending;
}

// A parked transfer is dying out-of-band (abort, owner teardown) -- unlink it
// so the preflight's resolution doesn't touch freed memory. Same contract as
// RobotsGate.remove: the map entry stays, owned by the in-flight OPTIONS.
pub fn remove(self: *PreflightGate, transfer: *Transfer) void {
    self.single_flight.remove(transfer);
}

// Does this request need a preflight, and if so what does the OPTIONS have to
// announce? Null means it goes straight to the network.
//
// The trigger, per the Fetch spec and matching Chrome 151 case for case in
// tools/fingerprint/results/b57-cors-chrome.json: cross-origin, script-issued,
// and either a method outside GET/HEAD/POST or at least one header the page
// set that is not CORS-safelisted.
fn describe(transfer: *Transfer) !?Plan {
    const req = &transfer.req;

    // Internal sub-requests -- including the OPTIONS this gate itself sends,
    // which is what keeps it from recursing.
    if (req.internal) return null;

    switch (req.resource_type) {
        // `Sec-Fetch-Mode: cors`, the requests that go through the CORS
        // protocol at all. Subresources the parser pulls in are no-cors and a
        // navigation is not a CORS request; EventSource does its own check.
        .fetch, .xhr => {},
        .document, .stylesheet, .script, .image, .eventsource => return null,
    }

    // Same-origin first, and without allocating: this runs on every fetch()
    // and XHR the page makes, and most of them are same-origin.
    if (URL.isSameOrigin(req.url, req.cookie_origin)) return null;

    const arena = transfer.arena.allocator();
    const origin = try URL.getOrigin(arena, req.cookie_origin) orelse return null;

    // Only what the page itself set counts. Everything this engine adds --
    // Sec-Fetch-*, Origin, Referer, the client hints, Content-Length -- is a
    // forbidden header name in a browser, which is exactly why a browser can
    // send it without announcing it.
    var unsafe: std.ArrayList([]const u8) = .empty;
    for (transfer.req_headers.items) |hdr| {
        if (hdr.source != .author) continue;
        if (cors.isSafelistedRequestHeader(hdr.name, hdr.value)) continue;

        const lowered = try arena.alloc(u8, hdr.name.len);
        _ = std.ascii.lowerString(lowered, hdr.name);
        try unsafe.append(arena, lowered);
    }

    const method = @tagName(req.method);
    if (cors.isSafelistedMethod(method) and unsafe.items.len == 0) {
        return null;
    }

    return .{
        .origin = origin,
        .method = method,
        .request_headers = try joinRequestHeaders(arena, unsafe.items),
        // Chrome sends the preflight itself uncredentialed either way (no
        // Cookie on it, measured); the flag decides how strictly the answer is
        // read, not what goes out.
        .with_credentials = req.cookie_jar != null,
    };
}

// Sorted, deduplicated, comma-joined with no spaces -- `x-alpha,x-zeta` for a
// page that set X-Zeta then X-Alpha. Measured on Chrome 151, the
// `two-custom-headers` case of tools/fingerprint/results/b57-cors-chrome.json.
fn joinRequestHeaders(arena: Allocator, names: [][]const u8) !?[]const u8 {
    if (names.len == 0) return null;
    std.mem.sort([]const u8, names, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    var previous: []const u8 = "";
    for (names) |name| {
        if (std.mem.eql(u8, name, previous)) continue;
        if (out.items.len > 0) try out.append(arena, ',');
        try out.appendSlice(arena, name);
        previous = name;
    }
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn preflightThenResume(self: *PreflightGate, key: []const u8, transfer: *Transfer, plan: Plan) !void {
    const client = transfer.client;

    const result = try self.single_flight.enter(key, transfer, .preflight);
    if (result == .queued) return;
    errdefer {
        self.single_flight.discard(key);
        transfer.unpark();
    }

    const arena = try client.arena_pool.acquire(.small, "PreflightGate.PreflightContext");
    errdefer arena.release();

    const ctx = try arena.create(PreflightContext);
    ctx.* = .{
        .gate = self,
        .arena = arena,
        .key = try arena.dupe(u8, key),
        .url = try arena.dupeZ(u8, transfer.req.url),
        .origin = try arena.dupe(u8, plan.origin),
        .method = plan.method,
        .request_headers = if (plan.request_headers) |h| try arena.dupe(u8, h) else null,
        .with_credentials = plan.with_credentials,
    };

    log.debug(.http, "cors preflight", .{
        .url = ctx.url,
        .method = ctx.method,
        .headers = ctx.request_headers,
    });

    // Carries the parent's frame/loader ids (CDP correlation) and its
    // notification, plus the initiator origin so Origin and Sec-Fetch-Site
    // come out of seedFetchMetadata the way Chrome writes them. No cookie jar:
    // a preflight is never credentialed, even for `credentials: "include"`.
    const fetch_transfer = try client.newRequest(.{
        .url = ctx.url,
        .method = .OPTIONS,
        .internal = true,
        .preflight = true,
        .skip_cache = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .document_frame_id = transfer.req.document_frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .cookie_jar = null,
        .cookie_origin = transfer.req.cookie_origin,
        .ctx = ctx,
        .header_callback = PreflightContext.headerCallback,
        .done_callback = PreflightContext.doneCallback,
        .error_callback = PreflightContext.errorCallback,
        .shutdown_callback = PreflightContext.shutdownCallback,
    }, null);

    try fetch_transfer.setHeader("Access-Control-Request-Method", ctx.method, .{ .source = .cdp });
    if (ctx.request_headers) |headers| {
        try fetch_transfer.setHeader("Access-Control-Request-Headers", headers, .{ .source = .cdp });
    }
    // Chrome puts the initiating document's Referer on the preflight too.
    if (transfer.findRequestHeader("Referer")) |referer| {
        try fetch_transfer.setHeader("Referer", referer, .{});
    }

    // From here the OPTIONS owns the pending entry and the context arena. A
    // failing submit fires error_callback -- possibly synchronously, right
    // here -- which resolves the waiters and releases the arena, so there is
    // nothing to unwind locally and the errdefers above must not run.
    fetch_transfer.submit() catch {};
}

// The preflight resolved: every waiter behind this key asked the same
// question, so one verdict covers them all.
fn flushPending(self: *PreflightGate, key: []const u8, allowed: bool) void {
    var queued = self.single_flight.take(key) orelse return;
    defer queued.deinit(self.single_flight.allocator);

    for (queued.items) |transfer| {
        transfer.unpark();

        if (!allowed) {
            log.info(.http, "blocked by cors preflight", .{ .url = transfer.req.url });
            transfer.failAsync(error.CorsPreflightBlocked);
            continue;
        }
        // Hand back to the pipeline; the preflight gate is the last step
        // before the network. If it fails while we still own the transfer,
        // clean up here.
        transfer.client.resumeAfterPreflight(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}

fn remember(self: *PreflightGate, key: []const u8, max_age: u32) void {
    if (max_age == 0) return;

    const owned = self.allocator.dupe(u8, key) catch return;
    const expires_at = lp.datetime.timestamp(.boot) + @min(max_age, max_age_cap);
    self.cache.put(self.allocator, owned, expires_at) catch {
        self.allocator.free(owned);
    };
}

const PreflightContext = struct {
    gate: *PreflightGate,
    arena: *lp.Arena,
    key: []const u8,
    url: [:0]const u8,
    origin: []const u8,
    method: []const u8,
    request_headers: ?[]const u8,
    with_credentials: bool,

    status: u16 = 0,
    allow_origin: ?[]const u8 = null,
    allow_credentials: ?[]const u8 = null,
    allow_methods: ?[]const u8 = null,
    allow_headers: ?[]const u8 = null,
    max_age: u32 = 0,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *PreflightContext = @ptrCast(@alignCast(transfer.req.ctx));
        const arena = self.arena.allocator();

        if (transfer.res.header) |hdr| {
            self.status = hdr.status;
        }

        var it = transfer.responseHeaderIterator();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
                self.allow_origin = try arena.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-credentials")) {
                self.allow_credentials = try arena.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-methods")) {
                self.allow_methods = try arena.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-headers")) {
                self.allow_headers = try arena.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-max-age")) {
                self.max_age = std.fmt.parseInt(u32, std.mem.trim(u8, hdr.value, " \t"), 10) catch 0;
            }
        }
        return .proceed;
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *PreflightContext = @ptrCast(@alignCast(ctx_ptr));

        const allowed = self.permits();
        if (allowed) {
            self.gate.remember(self.key, self.max_age);
        } else {
            log.info(.http, "cors preflight refused", .{
                .url = self.url,
                .status = self.status,
                .allow_origin = self.allow_origin,
                .allow_methods = self.allow_methods,
                .allow_headers = self.allow_headers,
            });
        }
        self.resolve(allowed);
    }

    // Does the answer permit the request that provoked it?
    fn permits(self: *const PreflightContext) bool {
        // An "ok status". A 4xx/5xx answer to the OPTIONS is a refusal even if
        // it somehow carries Allow-* headers.
        if (self.status < 200 or self.status > 299) return false;

        if (!cors.originAllowed(self.allow_origin, self.allow_credentials, self.origin, self.with_credentials)) {
            return false;
        }
        // GET/HEAD/POST are safelisted methods: they do not have to appear in
        // Allow-Methods, and leaving them out does not block them.
        if (!cors.isSafelistedMethod(self.method)) {
            if (!cors.listAllows(self.allow_methods, self.method, self.with_credentials)) return false;
        }
        if (self.request_headers) |headers| {
            var it = std.mem.splitScalar(u8, headers, ',');
            while (it.next()) |name| {
                if (name.len == 0) continue;
                if (!cors.listAllows(self.allow_headers, name, self.with_credentials)) return false;
            }
        }
        return true;
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *PreflightContext = @ptrCast(@alignCast(ctx_ptr));

        // A preflight that never got an answer is a refusal, not a pass: the
        // browser has no permission to show for the request behind it.
        log.info(.http, "cors preflight failed", .{ .url = self.url, .err = err });
        self.resolve(false);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *PreflightContext = @ptrCast(@alignCast(ctx_ptr));

        log.debug(.http, "cors preflight shutdown", .{ .url = self.url });
        const gate = self.gate;
        const arena = self.arena;
        gate.single_flight.discard(self.key);
        arena.release();
    }

    fn resolve(self: *PreflightContext, allowed: bool) void {
        const gate = self.gate;
        const arena = self.arena;
        gate.flushPending(self.key, allowed);
        arena.release();
    }
};

const testing = @import("../testing.zig");

test "PreflightGate: the cross-origin non-simple cases, end to end" {
    try testing.htmlRunner("net/cors_preflight.html", .{});
}

// The stylesheet rows are real fetches, so the runner has to be told to make
// them: it leaves external stylesheets off by default.
test "PreflightGate: the crossorigin attribute puts a subresource in CORS mode" {
    try testing.htmlRunner("net/crossorigin_attribute.html", .{ .load_external_stylesheets = true });
}
