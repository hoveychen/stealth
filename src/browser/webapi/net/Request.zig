// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const http = @import("../../../network/http.zig");

const URL = @import("../URL.zig");
const Page = @import("../../Page.zig");
const Blob = @import("../Blob.zig");
const AbortSignal = @import("../AbortSignal.zig");

const Headers = @import("Headers.zig");
const FormData = @import("FormData.zig");
const body_init = @import("body_init.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const BodyInit = body_init.BodyInit;

const Execution = js.Execution;

const Request = @This();

_rc: lp.RC = .{},
_url: [:0]const u8,
_method: http.Method,
_headers: ?*Headers,
_body: ?[]const u8,
// A body handed over as a ReadableStream stays one until something reads it:
// Chrome exposes it on `.body` and only drains it when the request is sent or
// a body method is called.
_body_stream: ?*ReadableStream = null,
_arena: *lp.Arena,
_cache: Cache,
_credentials: Credentials,
_redirect: Redirect,
_mode: Mode,
_signal: ?*AbortSignal,
_body_used: bool = false,
_referrer: []const u8 = REFERRER_CLIENT,
_referrer_policy: []const u8 = "",
_integrity: []const u8 = "",
_keepalive: bool = false,

pub const Input = union(enum) {
    request: *Request,
    url: [:0]const u8,
};

pub const InitOpts = struct {
    // Alphabetical, because that is the order a page sees them read in: a
    // dictionary's members are read one level at a time and alphabetically
    // within a level, and RequestInit has no base. This engine read them in IDL
    // declaration order and left seven out, which a Proxy handed to `Request`
    // reports as a shorter, differently ordered log -- measured with
    // probes/expr-b85-dictionary-traps.js.
    //
    // The four with no implementation behind them are read and discarded.
    // Chrome reads them too, and on an ordinary page ignores them just as
    // thoroughly; what is observable either way is the read.
    //
    // `attributionReporting`, `browsingTopics` and `sharedStorageWritable` are
    // NOT among them any more. Chrome 151 read all three; Chrome 153 reads
    // none, so a Proxy handed to `Request` logs seventeen names there and
    // logged twenty here -- three extra reads no browser performs. Measured
    // both ways in one capture: on the live x-hyatt page the guard submits
    // this very list, and again offline with scratch/s60/expr-requestinit.js
    // against a real Chrome.
    adAuctionHeaders: ?bool = null,
    body: ?BodyInit = null,
    // Read as strings rather than as the typed enums: an out-of-range value has
    // to name the member, the dictionary and the enum type, and the bridge's
    // enum conversion knows none of the three.
    cache: ?[]const u8 = null,
    credentials: ?[]const u8 = null,
    duplex: ?[]const u8 = null,
    headers: ?Headers.InitOpts = null,
    integrity: ?[]const u8 = null,
    keepalive: ?bool = null,
    method: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    privateToken: ?js.Value = null,
    redirect: ?[]const u8 = null,
    referrer: ?[]const u8 = null,
    referrerPolicy: ?[]const u8 = null,
    signal: ?*AbortSignal = null,
    targetAddressSpace: ?[]const u8 = null,
};

// The RequestMode IDL enum, which is not the same set as the request modes that
// exist: `websocket` is an internal mode with no IDL member, so asking for it
// fails the way any nonsense string does, while `navigate` IS a member and is
// refused a step later, by its own message. Measured on Chrome 151
// (tools/fingerprint/scratch/b118/expr-fetch-mode-throw.js), where the two
// throw different TypeErrors.
pub const Mode = enum {
    @"same-origin",
    @"no-cors",
    cors,
    navigate,
    pub const js_enum_from_string = true;
};

// The default referrer for a request nobody gave one to: not the empty string,
// which is what an explicit `{referrer: ''}` produces. Measured on Chrome 151.
const REFERRER_CLIENT = "about:client";

// The only value RequestDuplex has. A streaming body must name it, which is
// what Vite's module-preload helper feature-tests for on every page it ships.
const DUPLEX_HALF = "half";

const Priority = enum { high, low, auto };

const Redirect = enum {
    follow,
    manual,
    @"error",
    pub const js_enum_from_string = true;
};

const Credentials = enum {
    omit,
    include,
    @"same-origin",
    pub const js_enum_from_string = true;
};

const Cache = enum {
    default,
    @"no-store",
    reload,
    @"no-cache",
    @"force-cache",
    @"only-if-cached",
    pub const js_enum_from_string = true;
};

// Blink words the *detail* of a rejection the same wherever the Request is
// built, and varies only the lead-in: `new Request(...)` says "Failed to
// construct 'Request': ", `fetch(...)` says "Failed to execute 'fetch' on
// 'Window': " (both measured, Chrome 151). So `init` takes the lead-in from
// whoever called it, and `null` means "this path's wording is not measured" —
// the Cache API — which keeps the bare TypeError it throws today rather than a
// guessed sentence.
const ctor_prefix = "Failed to construct 'Request': ";
// Reached from both body branches, streaming and not.
const no_body_for_method = "Request with GET/HEAD method cannot have body.";

/// Reads one of RequestInit's enum members. Blink nests the wording -- the
/// member and the dictionary it was read from, then the value and the enum type,
/// which is the one name here that comes without quotes (measured on Chrome
/// 151). `duplex` writes the same sentence inline, being the only member with no
/// enum behind it.
fn enumMember(
    comptime E: type,
    comptime member: []const u8,
    comptime idl_name: []const u8,
    value_: ?[]const u8,
    exec: *const Execution,
    prefix: ?[]const u8,
) !?E {
    const value = value_ orelse return null;
    return std.meta.stringToEnum(E, value) orelse fail(
        exec,
        prefix,
        "Failed to read the '" ++ member ++ "' property from 'RequestInit': " ++
            "The provided value '{s}' is not a valid enum value of type " ++ idl_name ++ ".",
        .{value},
    );
}

fn fail(exec: *const Execution, prefix: ?[]const u8, comptime fmt: []const u8, args: anytype) anyerror {
    const p = prefix orelse return error.TypeError;
    const detail = std.fmt.allocPrint(exec.local_arena, fmt, args) catch return error.TypeError;
    const message = std.fmt.allocPrint(exec.local_arena, "{s}{s}", .{ p, detail }) catch return error.TypeError;
    return exec.js.fail(error.TypeError, message);
}

/// `new Request(input, init)`.
pub fn constructor(input: Input, opts: ?InitOpts, exec: *const Execution) !*Request {
    return initWithContext(input, opts, exec, ctor_prefix);
}

pub fn init(input: Input, opts_: ?InitOpts, exec: *const Execution) !*Request {
    return initWithContext(input, opts_, exec, null);
}

fn initWithContext(input: Input, opts_: ?InitOpts, exec: *const Execution, prefix: ?[]const u8) !*Request {
    const arena = try exec.getPinnedArena(.medium, "Request");
    errdefer arena.release();

    const url = switch (input) {
        // Blink quotes the input as it was handed in, not the resolved URL.
        .url => |u| URL.resolve(arena.allocator(), exec.base(), u, .{ .encoding = exec.charset.* }) catch |err| switch (err) {
            error.TypeError => return fail(exec, prefix, "Failed to parse URL from {s}", .{u}),
            else => return err,
        },
        .request => |r| try arena.dupeZ(u8, r._url),
    };

    const opts = opts_ orelse InitOpts{};
    const cache = try enumMember(Cache, "cache", "RequestCache", opts.cache, exec, prefix) orelse .default;
    const credentials = try enumMember(Credentials, "credentials", "RequestCredentials", opts.credentials, exec, prefix) orelse .@"same-origin";
    const redirect = try enumMember(Redirect, "redirect", "RequestRedirect", opts.redirect, exec, prefix) orelse .follow;
    // Validated and then dropped: the value has no effect here, but an
    // out-of-range one is refused the same way Chrome refuses it.
    _ = try enumMember(Priority, "priority", "FetchPriority", opts.priority, exec, prefix);

    // `navigate` is a RequestMode member, so it survives the enum conversion,
    // and is then refused on its own: a Request is not how a navigation is
    // made. Chrome's wording, measured.
    const mode = try enumMember(Mode, "mode", "RequestMode", opts.mode, exec, prefix) orelse switch (input) {
        .url => Mode.cors,
        .request => |r| r._mode,
    };
    if (opts.mode != null and mode == .navigate) {
        return fail(exec, prefix, "Cannot construct a Request with a RequestMode of navigate", .{});
    }

    const method = if (opts.method) |m|
        try parseMethod(m, exec)
    else switch (input) {
        .url => .GET,
        .request => |r| r._method,
    };

    const guard = headerGuard(mode);
    var headers = if (opts.headers) |headers_init|
        try Headers.initGuarded(headers_init, guard, exec)
    else switch (input) {
        .url => null,
        .request => |r| if (r._headers) |h| try Headers.initGuarded(.{ .obj = h }, guard, exec) else null,
    };

    if (opts.duplex) |duplex| {
        if (!std.mem.eql(u8, duplex, DUPLEX_HALF)) {
            return fail(exec, prefix, "Failed to read the 'duplex' property from 'RequestInit': " ++
                "The provided value '{s}' is not a valid enum value of type RequestDuplex.", .{duplex});
        }
    }

    var body_stream: ?*ReadableStream = null;
    const body = if (opts.body) |b| blk: {
        if (b == .stream) {
            if (opts.duplex == null) {
                // Backticks around `duplex` and no full stop: Blink's own
                // inconsistency, kept verbatim (measured, Chrome 151).
                return fail(exec, prefix, "The `duplex` member must be specified for a request with a streaming body", .{});
            }
            if (method == .GET or method == .HEAD) {
                return fail(exec, prefix, no_body_for_method, .{});
            }
            body_stream = b.stream;
            break :blk null;
        }
        if (method == .GET or method == .HEAD) {
            return fail(exec, prefix, no_body_for_method, .{});
        }
        const extracted = try b.extract(arena.allocator());
        // Per Fetch §6.5 step 11, the default Content-Type only applies if
        // the user has not already set one via the headers init dict.
        if (extracted.content_type) |ct| {
            const hs = headers orelse try Headers.initGuarded(null, guard, exec);
            if (try hs.has("content-type", exec) == false) {
                try hs.append("content-type", ct, exec);
            }
            headers = hs;
        }
        break :blk extracted.bytes;
    } else switch (input) {
        .url => null,
        // Dupe: the source Request owns its body bytes and may be finalized
        // before this one.
        .request => |r| if (r._body) |b| try arena.dupe(u8, b) else null,
    };

    const signal = if (opts.signal) |s|
        s
    else switch (input) {
        .url => null,
        .request => |r| r._signal,
    };

    const self = try arena.create(Request);
    self.* = .{
        ._url = url,
        ._arena = arena,
        ._method = method,
        ._headers = headers,
        ._cache = cache,
        ._credentials = credentials,
        ._redirect = redirect,
        ._body = body,
        ._body_stream = body_stream,
        ._signal = signal,
        ._mode = mode,
        ._referrer = if (opts.referrer) |r| try arena.dupe(u8, r) else switch (input) {
            .url => REFERRER_CLIENT,
            .request => |r| r._referrer,
        },
        ._referrer_policy = if (opts.referrerPolicy) |r| try arena.dupe(u8, r) else switch (input) {
            .url => "",
            .request => |r| r._referrer_policy,
        },
        ._integrity = if (opts.integrity) |i| try arena.dupe(u8, i) else switch (input) {
            .url => "",
            .request => |r| r._integrity,
        },
        ._keepalive = opts.keepalive orelse switch (input) {
            .url => false,
            .request => |r| r._keepalive,
        },
    };
    arena.report();
    return self;
}

pub fn getMode(self: *const Request) []const u8 {
    return @tagName(self._mode);
}

pub fn getReferrer(self: *const Request) []const u8 {
    return self._referrer;
}

pub fn getReferrerPolicy(self: *const Request) []const u8 {
    return self._referrer_policy;
}

pub fn getIntegrity(self: *const Request) []const u8 {
    return self._integrity;
}

pub fn getKeepalive(self: *const Request) bool {
    return self._keepalive;
}

/// The four a request built from script never has anything to say about.
/// Chrome answers "" for the destination of a `new Request(...)`, "unknown"
/// for the address space it would be allowed to reach, and false for both
/// navigation flags (measured on Chrome 151).
pub fn getDestination(_: *const Request) []const u8 {
    return "";
}

pub fn getTargetAddressSpace(_: *const Request) []const u8 {
    return "unknown";
}

pub fn getIsHistoryNavigation(_: *const Request) bool {
    return false;
}

pub fn getIsReloadNavigation(_: *const Request) bool {
    return false;
}

/// The only value RequestDuplex has, and the one Chrome answers whether or not
/// the request carries a streaming body.
pub fn getDuplex(_: *const Request) []const u8 {
    return DUPLEX_HALF;
}

/// The body as a stream of text chunks, and reading it consumes the body --
/// Response's counterpart, same refusal.
pub fn textStream(self: *Request, exec: *const Execution) !*ReadableStream {
    if (self._body_used) {
        return exec.js.fail(
            error.TypeError,
            "Failed to execute 'textStream' on 'Request': body stream already read",
        );
    }
    if (self._body_stream) |stream| {
        self._body_used = true;
        return stream;
    }
    self._body_used = true;
    return ReadableStream.initWithText(self._body orelse "", exec);
}

pub fn deinit(self: *Request, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *Request, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Request) void {
    self._rc.acquire();
}

fn parseMethod(method: []const u8, exec: *const Execution) !http.Method {
    if (method.len > "propfind".len) {
        return error.InvalidMethod;
    }

    const lower = std.ascii.lowerString(exec.buf, method);

    const method_lookup = std.StaticStringMap(http.Method).initComptime(.{
        .{ "get", .GET },
        .{ "post", .POST },
        .{ "delete", .DELETE },
        .{ "put", .PUT },
        .{ "patch", .PATCH },
        .{ "head", .HEAD },
        .{ "options", .OPTIONS },
        .{ "propfind", .PROPFIND },
    });
    return method_lookup.get(lower) orelse return error.InvalidMethod;
}

pub fn getUrl(self: *const Request) []const u8 {
    return self._url;
}

pub fn getMethod(self: *const Request) []const u8 {
    return @tagName(self._method);
}

pub fn getCache(self: *const Request) []const u8 {
    return @tagName(self._cache);
}

pub fn getCredentials(self: *const Request) []const u8 {
    return @tagName(self._credentials);
}

pub fn getRedirect(self: *const Request) []const u8 {
    return @tagName(self._redirect);
}

pub fn getSignal(self: *const Request) ?*AbortSignal {
    return self._signal;
}

pub fn getHeaders(self: *Request, exec: *const Execution) !*Headers {
    if (self._headers) |headers| {
        return headers;
    }

    const headers = try Headers.initGuarded(null, headerGuard(self._mode), exec);
    self._headers = headers;
    return headers;
}

fn headerGuard(mode: Mode) Headers.Guard {
    return if (mode == .@"no-cors") .request_no_cors else .request;
}

pub fn getBodyUsed(self: *const Request) bool {
    if (self._body == null and self._body_stream == null) {
        return false;
    }
    return self._body_used;
}

/// The body as a stream, which is what Chrome puts on `.body` whichever shape
/// it was given in: a stream body is handed back as-is, and bytes are wrapped.
pub fn getBody(self: *Request, exec: *const Execution) !?*ReadableStream {
    if (self._body_stream) |stream| {
        return stream;
    }
    const body = self._body orelse return null;
    if (body.len == 0) {
        const stream = try ReadableStream.init(null, null, exec);
        try stream._controller.close();
        return stream;
    }
    return ReadableStream.initWithData(body, exec);
}

/// Whether this request carries a body at all. A GET with no body must not
/// reach curl with an empty-but-present one: curl then adds `Content-Length: 0`
/// and its own `Content-Type: application/x-www-form-urlencoded`, neither of
/// which a real fetch() GET sends.
pub fn hasBody(self: *const Request) bool {
    return self._body != null or self._body_stream != null;
}

/// The body as bytes, draining a streaming one on first read. Chrome streams
/// it to the wire instead; we buffer, which is visible only in how much of a
/// slow stream has to exist before the request goes out.
pub fn bodyBytes(self: *Request) ![]const u8 {
    if (self._body) |body| {
        return body;
    }
    const stream = self._body_stream orelse return "";
    const bytes_ = try stream.collectBodyBytes(self._arena.allocator());
    self._body = bytes_;
    return bytes_;
}

// Marks a present body consumed; returns a rejected promise if it already was.
fn consume(self: *Request, local: *const js.Local) ?js.Promise {
    if (self._body == null and self._body_stream == null) {
        return null;
    }

    if (self._body_used) {
        return local.rejectPromise(.{ .type_error = "Body has already been read" });
    }
    self._body_used = true;
    return null;
}

pub fn blob(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self.consume(local)) |rejected| {
        return rejected;
    }

    const body = try self.bodyBytes();
    const headers = try self.getHeaders(exec);
    const content_type = try headers.get("content-type", exec) orelse "";

    const b = try Blob.initFromBytes(body, content_type, exec);
    return local.resolvePromise(b);
}

pub fn text(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self.consume(local)) |rejected| {
        return rejected;
    }
    return local.resolvePromise(body_init.stripUtf8Bom(try self.bodyBytes()));
}

pub fn json(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self.consume(local)) |rejected| {
        return rejected;
    }

    const value = local.parseJSON(body_init.stripUtf8Bom(try self.bodyBytes())) catch {
        return local.rejectPromise(.{ .syntax_error = "failed to parse" });
    };
    return local.resolvePromise(try value.persist());
}

pub fn arrayBuffer(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self.consume(local)) |rejected| {
        return rejected;
    }
    return local.resolvePromise(js.ArrayBuffer{ .values = try self.bodyBytes() });
}

pub fn bytes(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self.consume(local)) |rejected| {
        return rejected;
    }
    return local.resolvePromise(js.TypedArray(u8){ .values = try self.bodyBytes() });
}

pub fn formData(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self.consume(local)) |rejected| {
        return rejected;
    }

    // Per Fetch, a null body acts as an empty byte sequence.
    const body = try self.bodyBytes();

    const headers = try self.getHeaders(exec);
    const content_type = try headers.get("content-type", exec);
    // Per Fetch, a null body acts as an empty byte sequence.
    const form_data = body_init.parseFormData(body, content_type, exec) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.TypeError => return local.typeError("Failed to parse body as FormData"),
    };
    return local.resolvePromise(form_data);
}

pub fn clone(self: *Request, exec: *const Execution) !*Request {
    const body = try self.bodyBytes();
    const arena = try exec.getPinnedArena(if (body.len != 0) body.len else 512, "Request.clone");
    errdefer arena.release();

    const request = try arena.create(Request);
    request.* = .{
        ._url = try arena.dupeZ(u8, self._url),
        ._arena = arena,
        ._method = self._method,
        ._headers = self._headers,
        ._cache = self._cache,
        ._credentials = self._credentials,
        ._redirect = self._redirect,
        ._mode = self._mode,
        ._body = if (self._body) |b| try arena.dupe(u8, b) else null,
        ._body_stream = null,
        ._signal = self._signal,
    };
    arena.report();
    return request;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Request);

    pub const Meta = struct {
        pub const name = "Request";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Request.constructor, .{});

    // Chrome's own-property order, which interleaves the Body mixin's members
    // with the request's own and puts five late-added ones after `text`.
    pub const method = bridge.accessor(Request.getMethod, null, .{});
    pub const url = bridge.accessor(Request.getUrl, null, .{});
    pub const headers = bridge.accessor(Request.getHeaders, null, .{});
    pub const destination = bridge.accessor(Request.getDestination, null, .{});
    pub const referrer = bridge.accessor(Request.getReferrer, null, .{});
    pub const referrerPolicy = bridge.accessor(Request.getReferrerPolicy, null, .{});
    pub const mode = bridge.accessor(Request.getMode, null, .{});
    pub const credentials = bridge.accessor(Request.getCredentials, null, .{});
    pub const cache = bridge.accessor(Request.getCache, null, .{});
    pub const redirect = bridge.accessor(Request.getRedirect, null, .{});
    pub const integrity = bridge.accessor(Request.getIntegrity, null, .{});
    pub const keepalive = bridge.accessor(Request.getKeepalive, null, .{});
    pub const signal = bridge.accessor(Request.getSignal, null, .{});
    pub const duplex = bridge.accessor(Request.getDuplex, null, .{});
    pub const isHistoryNavigation = bridge.accessor(Request.getIsHistoryNavigation, null, .{});
    pub const bodyUsed = bridge.accessor(Request.getBodyUsed, null, .{});
    pub const arrayBuffer = bridge.function(Request.arrayBuffer, .{});
    pub const blob = bridge.function(Request.blob, .{});
    pub const clone = bridge.function(Request.clone, .{});
    pub const formData = bridge.function(Request.formData, .{});
    pub const json = bridge.function(Request.json, .{});
    pub const text = bridge.function(Request.text, .{});
    pub const targetAddressSpace = bridge.accessor(Request.getTargetAddressSpace, null, .{});
    pub const isReloadNavigation = bridge.accessor(Request.getIsReloadNavigation, null, .{});
    pub const body = bridge.accessor(Request.getBody, null, .{});
    pub const bytes = bridge.function(Request.bytes, .{});
    pub const textStream = bridge.function(Request.textStream, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Request" {
    try testing.htmlRunner("net/request.html", .{});
}
