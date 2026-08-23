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

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");
const HttpClient = @import("../../../network/HttpClient.zig");

const AbortSignal = @import("../AbortSignal.zig");
const DOMException = @import("../DOMException.zig");

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const log = lp.log;
const Execution = js.Execution;
const Transfer = HttpClient.Transfer;

const Fetch = @This();

_exec: *const Execution,
_url: []const u8,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PromiseResolver.Global,
_owns_response: bool,
_signal: ?*AbortSignal,
_manual_redirect: bool,

// When the request was handed to the client, on the performance clock. The
// resource entry's startTime is measured from here, so it has to be taken
// before the transfer rather than reconstructed after it.
_perf_fetch_start: f64 = 0,

// The protocol the response arrived over, read while the transfer is still
// alive. A libcurl literal, so it needs no arena.
_perf_next_hop_protocol: []const u8 = "",

// What the body weighed on the wire. `_buf` holds the decoded bytes, so the
// two differ for every compressed response; read per chunk because the
// transfer is released before the entry is filed.
_perf_encoded_body_size: u64 = 0,

// contentType / contentEncoding for the entry, copied off the headers.
_perf_labels: HttpClient.ResponseLabels = .{},

pub const Input = Request.Input;
pub const InitOpts = Request.InitOpts;

pub fn init(input: Input, options: ?InitOpts, exec: *const Execution) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();

    // A bad RequestInit (e.g. an invalid priority) must reject the promise,
    // not throw synchronously.
    const request = Request.init(input, options, exec) catch {
        resolver.rejectError("fetch init error", .{ .type_error = "Failed to construct Request" });
        return resolver.promise();
    };
    // This Request is never exposed to JS. makeRequest dupes the url/body
    // into the transfer, so nothing references it once we return.
    request.acquireRef();
    defer request.releaseRef(exec.page);

    if (request._signal) |signal| {
        if (signal._aborted) {
            resolver.reject("fetch aborted", DOMException.init("The operation was aborted.", "AbortError"));
            return resolver.promise();
        }
    }

    const response = try Response.initPending(exec);
    errdefer response.deinit(exec.page);

    const fetch = try response._arena.create(Fetch);
    fetch.* = .{
        ._exec = exec,
        ._buf = .empty,
        ._url = try response._arena.dupe(u8, request._url),
        ._resolver = try resolver.persist(),
        ._response = response,
        ._owns_response = true,
        ._signal = request._signal,
        ._manual_redirect = request._redirect == .manual,
        ._perf_fetch_start = exec.performance().now(),
    };

    const session = exec.session;

    if (comptime lp.IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    const cookie_jar = switch (request._credentials) {
        .omit => null,
        .include => &session.cookie_jar,
        .@"same-origin" => if (exec.isSameOrigin(request._url)) &session.cookie_jar else null,
    };

    const transfer = exec.newRequest(.{
        .ctx = fetch,
        .url = request._url,
        .method = request._method,
        .frame_id = exec.frameId(),
        .loader_id = exec.loaderId(),
        .body = if (request.hasBody()) try request.bodyBytes() else null,
        .resource_type = .fetch,
        .cookie_jar = cookie_jar,
        .cookie_origin = exec.url.*,
        .redirect = switch (request._redirect) {
            .follow => .follow,
            .manual => .manual,
            .@"error" => .@"error",
        },
        .notification = session.notification,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch {
        // OOM-class; nothing was committed and no callback fired.
        return resolver.promise();
    };

    {
        errdefer transfer.deinit();
        if (request._headers) |h| {
            try h.populateRequestHeaders(transfer);
        }
        try exec.headersForRequest(transfer);
    }

    // Held for Response.deinit's abort; the error, shutdown and done
    // callbacks clear it.
    response._http_transfer = transfer;

    // Failures inside submit are dispatched to httpErrorCallback, which
    // rejects the promise and releases response._arena. Propagating the
    // error from here would also fire the `errdefer response.deinit` above
    // and double-free the arena.
    transfer.submit() catch {};
    return resolver.promise();
}

fn httpHeaderDoneCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *Fetch = @ptrCast(@alignCast(transfer.req.ctx));

    if (self._signal) |signal| {
        if (signal._aborted) {
            return .abort;
        }
    }

    self._perf_next_hop_protocol = transfer.nextHopProtocol();
    self._perf_labels = transfer.responseLabels();

    const arena = self._response._arena;
    if (transfer.getContentLength()) |cl| {
        try self._buf.ensureTotalCapacityPrecise(arena.allocator(), cl);
    }

    const res = self._response;

    if (comptime lp.IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "fetch",
            .url = self._url,
            .status = transfer.responseStatus(),
        });
    }

    res._status = transfer.responseStatus().?;
    res._status_text = std.http.Status.phrase(@enumFromInt(transfer.responseStatus().?)) orelse "";
    res._url = try arena.dupeZ(u8, transfer.req.url);
    res._is_redirected = transfer.redirectCount().? > 0;

    // redirect: "manual" surfaces the unfollowed 3xx as an opaque-redirect
    // filtered response: status 0, no headers, no body.
    if (self._manual_redirect and HttpClient.isRedirectStatus(res._status)) {
        res._status = 0;
        res._status_text = "";
        res._url = "";
        res._type = .opaqueredirect;
        res._is_redirected = false;
        return .proceed;
    }

    // Determine response type based on origin comparison
    const exec = self._exec;
    const requesting_origin = URL.getOrigin(arena.allocator(), exec.url.*) catch null;
    const response_origin = URL.getOrigin(arena.allocator(), res._url) catch null;

    if (requesting_origin) |fo| {
        if (response_origin) |ro| {
            if (std.mem.eql(u8, fo, ro)) {
                res._type = .basic; // Same-origin
            } else {
                res._type = .cors; // Cross-origin (for simplicity, assume CORS passed)
            }
        } else {
            res._type = .basic;
        }
    } else {
        res._type = .basic;
    }

    var it = transfer.responseHeaderIterator();
    while (it.next()) |hdr| {
        try res._headers.append(hdr.name, hdr.value, exec);
    }

    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.req.ctx));

    // Check if aborted
    if (self._signal) |signal| {
        if (signal._aborted) {
            return error.Abort;
        }
    }

    self._perf_encoded_body_size = transfer.encodedBodySize();
    try self._buf.appendSlice(self._response._arena.allocator(), data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    var response = self._response;
    response._http_transfer = null;
    response._body = .{ .bytes = self._buf.items };

    log.info(.http, "request complete", .{
        .source = "fetch",
        .url = self._url,
        .status = response._status,
        .len = self._buf.items.len,
    });

    // Chrome names the entry with the URL the response finally came from, so a
    // redirected request is filed under its destination, not its request URL.
    const exec = self._exec;
    const loaded_len = self._buf.items.len;
    _ = try exec.performance().resourceLoaded(
        if (response._url.len > 0) response._url else self._url,
        .{
            .initiator_type = "fetch",
            .next_hop_protocol = self._perf_next_hop_protocol,
            .content_type = self._perf_labels.contentType(),
            .content_encoding = self._perf_labels.contentEncoding(),
            .fetch_start = self._perf_fetch_start,
            .response_end = exec.performance().now(),
            .response_status = response._status,
            .encoded_body_size = if (self._perf_encoded_body_size > 0) self._perf_encoded_body_size else loaded_len,
            .decoded_body_size = loaded_len,
        },
        exec,
    );

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();

    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._owns_response = false;
    response._arena.report();
    return ls.toLocal(self._resolver).resolve("fetch done", js_val);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));

    log.info(.http, "request error", .{
        .source = "fetch",
        .url = self._url,
        .status = self._response._status,
        .err = err,
    });

    var response = self._response;
    response._http_transfer = null;

    // Capture this before we reject. Rejection could trigger httpShutdownCallback
    // (via a microtask callback). But if we're here, then we'll take care of
    // cleaning up when we're done.
    const owns_response = self._owns_response;
    self._owns_response = false;

    // the response is only passed on v8 on success, if we're here, it's safe to
    // clear this. (defer since `self is in the response's arena).

    defer if (owns_response) {
        response.deinit(self._exec.page);
    };

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();

    // fetch() must reject with a TypeError on network errors per spec, and the
    // message is not private: Cloudflare's challenge posts a probe into a worker
    // that fetches cross-origin and reports `String(e)` back to their server.
    // Headless Chrome 151, measured: connection refused, DNS failure and a CORS
    // rejection all reject with exactly `TypeError: Failed to fetch`.
    ls.toLocal(self._resolver).rejectError("fetch error", .{ .type_error = "Failed to fetch" });
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));

    if (self._owns_response) {
        var response = self._response;
        response._http_transfer = null;
        response.deinit(self._exec.page);
        // Do not access `self` after this point: the Fetch struct was
        // allocated from response._arena which has been released.
    }
}

const testing = @import("../../../testing.zig");
test "WebApi: fetch" {
    // Upstream expects two .http lines here, from an abort path that logs one
    // per aborted transfer. This fork's abort path is quiet -- measured: the
    // same html produces no .http line -- so expecting them fails the run.
    try testing.htmlRunner("net/fetch.html", .{});
    try testing.htmlRunner("net/fetch_hash_route.html", .{});
}
