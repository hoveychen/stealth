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

//! The module load behind `CSS.paintWorklet.addModule(url)`.
//!
//! `CSS.paintWorklet` was deliberately absent from the CSS namespace for a
//! while, on the grounds that a Worklet which cannot load a module is its own
//! kind of lie (CSS.zig said so in a comment). This is the load, so the name
//! can be there: the URL is parsed against the document's base, the module is
//! really fetched over the network -- it shows up as a `script` resource entry
//! the way Chrome's does -- and it is really compiled, so a module that does
//! not parse rejects with the parse error rather than resolving anyway.
//!
//! What it stops short of, and there is no way around it here: Chrome then
//! *runs* the module in a paint worklet global, where `registerPaint` defines a
//! paint class. There is no second realm to run it in and nothing rasterises,
//! so the compiled module is dropped. Running it in the page's realm would be
//! worse than not running it -- a worklet global has no DOM and no window, and
//! a module written for one would either throw or, worse, succeed at touching
//! the page.
//!
//! Chrome 151, measured with scratch/b80/addmodule.mjs against a local fixture:
//!
//!   no argument       TypeError, 1 argument required, but only 0 present.
//!   a real module     resolves with undefined, entry initiatorType "script"
//!   a 404             AbortError: Unable to load a worklet's module.
//!   a parse error     SyntaxError carrying V8's own message
//!   a data: URL       resolves
//!   an unparseable URL SyntaxError: '<url>' is not a valid URL.
//!
//! The audio half of the same interface still rejects everything, and that is
//! deliberate too -- see the header of ../audio/worklet.zig.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");
const HttpClient = @import("../../../network/HttpClient.zig");
const timing = @import("../performance/timing.zig");
const DOMException = @import("../DOMException.zig");

const log = lp.log;
const Execution = js.Execution;
const Transfer = HttpClient.Transfer;

const PaintModule = @This();

_exec: *const Execution,
_arena: *lp.Arena,
_url: [:0]const u8,
_body: std.ArrayList(u8) = .empty,
_resolver: js.PromiseResolver.Global,
_http_transfer: ?*Transfer = null,
_fetch_start: f64 = 0,
_next_hop_protocol: []const u8 = "",
_encoded_body_size: u64 = 0,
_labels: HttpClient.ResponseLabels = .{},
_times: HttpClient.ResponseTimes = .{},
_status: u16 = 0,

/// `Worklet.addModule` for the paint variant. Always answers a promise: a
/// WebIDL operation returning one turns every failure into a rejection, so an
/// unparseable URL does not throw synchronously either.
pub fn addModule(url: []const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const arena = try exec.getArena(.small, "CSS.paintWorklet.addModule");
    errdefer arena.release();

    const resolved = URL.resolve(arena.allocator(), exec.base(), url, .{ .encoding = exec.charset.* }) catch {
        arena.release();
        var resolver = local.createPromiseResolver();
        // Chrome quotes the URL as the page wrote it, not as it resolved.
        const message = try std.fmt.allocPrint(exec.call_arena, "'{s}' is not a valid URL.", .{url});
        resolver.reject("Worklet.addModule", DOMException.init(message, "SyntaxError"));
        return resolver.promise();
    };

    const resolver = local.createPromiseResolver();
    const self = try arena.allocator().create(PaintModule);
    self.* = .{
        ._exec = exec,
        ._arena = arena,
        ._url = resolved,
        ._resolver = try resolver.persist(),
        ._fetch_start = exec.performance().now(),
    };

    const session = exec.session;
    const transfer = exec.newRequest(.{
        .ctx = self,
        .method = .GET,
        .url = resolved,
        .frame_id = exec.frameId(),
        .loader_id = exec.loaderId(),
        .resource_type = .script,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = exec.url.*,
        .notification = session.notification,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch {
        // OOM-class: nothing was committed and no callback will fire.
        self.rejectAbort(local);
        arena.release();
        return resolver.promise();
    };

    {
        errdefer transfer.deinit();
        try exec.headersForRequest(transfer);
    }

    self._http_transfer = transfer;
    transfer.submit() catch {};
    return resolver.promise();
}

fn rejectAbort(self: *PaintModule, local: *const js.Local) void {
    local.toLocal(self._resolver).reject(
        "Worklet.addModule",
        DOMException.init("Unable to load a worklet's module.", "AbortError"),
    );
}

fn httpHeaderCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *PaintModule = @ptrCast(@alignCast(transfer.req.ctx));
    self._status = transfer.responseStatus() orelse 0;
    self._next_hop_protocol = transfer.nextHopProtocol();
    self._labels = transfer.responseLabels();
    self._times = transfer.responseTimes();

    // A worklet module is fetched with a "script" destination and nothing but
    // a 2xx counts: Chrome reports the same AbortError for a 404 as for a
    // connection failure, which is what `.abort` here produces.
    if (self._status < 200 or self._status >= 300) {
        return .abort;
    }
    if (transfer.getContentLength()) |cl| {
        try self._body.ensureTotalCapacityPrecise(self._arena.allocator(), cl);
    }
    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *PaintModule = @ptrCast(@alignCast(transfer.req.ctx));
    self._encoded_body_size = transfer.encodedBodySize();
    try self._body.appendSlice(self._arena.allocator(), data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *PaintModule = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    defer self._arena.release();

    const exec = self._exec;
    const loaded_len = self._body.items.len;

    var t: timing.Timing = .{
        .initiator_type = "script",
        .next_hop_protocol = self._next_hop_protocol,
        .content_type = self._labels.contentType(),
        .content_encoding = self._labels.contentEncoding(),
        .fetch_start = self._fetch_start,
        .response_end = exec.performance().now(),
        .response_status = self._status,
        .encoded_body_size = if (self._encoded_body_size > 0) self._encoded_body_size else loaded_len,
        .decoded_body_size = loaded_len,
    };
    t.setConnectionMilestones(self._times, exec.performance());
    _ = try exec.performance().resourceLoaded(self._url, t, .{
        .timing_allow_origin = self._labels.timingAllowOrigin(),
        .cors_response = false,
    }, exec);

    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();

    // Compiled and dropped -- see the header. The compile is not ceremony: it
    // is the only thing that can tell a module that parses from one that does
    // not, and Chrome answers the two differently.
    var message: []const u8 = "";
    js.Context.compileModuleSyntaxOnly(
        &ls.local,
        exec.call_arena,
        self._body.items,
        self._url,
        &message,
    ) catch {
        ls.toLocal(self._resolver).reject(
            "Worklet.addModule",
            DOMException.init(message, "SyntaxError"),
        );
        return;
    };

    ls.toLocal(self._resolver).resolve("Worklet.addModule", {});
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *PaintModule = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
    defer self._arena.release();

    log.info(.http, "request error", .{
        .source = "paintWorklet.addModule",
        .url = self._url,
        .status = self._status,
        .err = err,
    });

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();
    self.rejectAbort(&ls.local);
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *PaintModule = @ptrCast(@alignCast(ctx));
    if (self._http_transfer != null) {
        self._http_transfer = null;
        self._arena.release();
    }
}
