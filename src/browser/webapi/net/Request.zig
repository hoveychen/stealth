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
const ContentTypeIterator = @import("../../Mime.zig").ContentTypeIterator;

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
_signal: ?*AbortSignal,
_body_used: bool = false,

pub const Input = union(enum) {
    request: *Request,
    url: [:0]const u8,
};

pub const InitOpts = struct {
    method: ?[]const u8 = null,
    headers: ?Headers.InitOpts = null,
    body: ?BodyInit = null,
    cache: Cache = .default,
    credentials: Credentials = .@"same-origin",
    redirect: Redirect = .follow,
    signal: ?*AbortSignal = null,
    priority: ?[]const u8 = null,
    duplex: ?[]const u8 = null,
};

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

pub fn init(input: Input, opts_: ?InitOpts, exec: *const Execution) !*Request {
    const arena = try exec.getPinnedArena(.medium, "Request");
    errdefer arena.release();

    const url = switch (input) {
        .url => |u| try URL.resolve(arena.allocator(), exec.base(), u, .{ .encoding = exec.charset.* }),
        .request => |r| try arena.dupeZ(u8, r._url),
    };

    const opts = opts_ orelse InitOpts{};
    if (opts.priority) |p| {
        if (std.meta.stringToEnum(Priority, p) == null) {
            return error.InvalidArgument;
        }
    }

    const method = if (opts.method) |m|
        try parseMethod(m, exec)
    else switch (input) {
        .url => .GET,
        .request => |r| r._method,
    };

    var headers = if (opts.headers) |headers_init| switch (headers_init) {
        .obj => |h| h,
        else => try Headers.init(headers_init, exec),
    } else switch (input) {
        .url => null,
        .request => |r| r._headers,
    };

    if (opts.duplex) |duplex| {
        if (!std.mem.eql(u8, duplex, DUPLEX_HALF)) {
            return error.TypeError;
        }
    }

    var body_stream: ?*ReadableStream = null;
    const body = if (opts.body) |b| blk: {
        if (b == .stream) {
            if (opts.duplex == null) {
                return error.TypeError;
            }
            if (method == .GET or method == .HEAD) {
                return error.TypeError;
            }
            body_stream = b.stream;
            break :blk null;
        }
        if (method == .GET or method == .HEAD) {
            return error.TypeError;
        }
        const extracted = try b.extract(arena.allocator());
        // Per Fetch §6.5 step 11, the default Content-Type only applies if
        // the user has not already set one via the headers init dict.
        if (extracted.content_type) |ct| {
            const hs = headers orelse try Headers.init(null, exec);
            if (!hs.has("content-type", exec)) {
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
        ._cache = opts.cache,
        ._credentials = opts.credentials,
        ._redirect = opts.redirect,
        ._body = body,
        ._body_stream = body_stream,
        ._signal = signal,
    };
    arena.report();
    return self;
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

    const headers = try Headers.init(null, exec);
    self._headers = headers;
    return headers;
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

    const b = try Blob.initFromBytes(body, content_type, exec.page);
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
    const content_type = try headers.get("content-type", exec) orelse {
        return local.rejectPromise(.{ .type_error = "Failed to parse body as FormData" });
    };
    var it = ContentTypeIterator.init(content_type);
    const essence = it.essence;

    // [RFC7578]
    // Parse bytes, using the value of the `boundary` parameter from mimeType,
    // per the rules set forth in Returning Values from Forms: multipart/form-data.
    if (std.ascii.eqlIgnoreCase(essence, "multipart/form-data")) {
        const boundary = it.findBoundary();
        if (boundary.len == 0) {
            return local.rejectPromise(.{ .type_error = "Failed to parse body as FormData" });
        }

        const form_data = FormData.initFromMultipart(body, boundary, exec) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return local.rejectPromise(.{ .type_error = "Failed to parse body as FormData" }),
        };
        return local.resolvePromise(form_data);
    }

    if (std.ascii.eqlIgnoreCase(essence, "application/x-www-form-urlencoded")) {
        const form_data = FormData.initFromUrlEncoded(body, exec) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return local.rejectPromise(.{ .type_error = "Failed to parse body as FormData" }),
        };
        return local.resolvePromise(form_data);
    }

    return local.rejectPromise(.{ .type_error = "Failed to parse body as FormData" });
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

    pub const constructor = bridge.constructor(Request.init, .{});
    pub const url = bridge.accessor(Request.getUrl, null, .{});
    pub const method = bridge.accessor(Request.getMethod, null, .{});
    pub const headers = bridge.accessor(Request.getHeaders, null, .{});
    pub const cache = bridge.accessor(Request.getCache, null, .{});
    pub const credentials = bridge.accessor(Request.getCredentials, null, .{});
    pub const redirect = bridge.accessor(Request.getRedirect, null, .{});
    pub const signal = bridge.accessor(Request.getSignal, null, .{});
    pub const body = bridge.accessor(Request.getBody, null, .{});
    pub const bodyUsed = bridge.accessor(Request.getBodyUsed, null, .{});
    pub const blob = bridge.function(Request.blob, .{});
    pub const text = bridge.function(Request.text, .{});
    pub const json = bridge.function(Request.json, .{});
    pub const arrayBuffer = bridge.function(Request.arrayBuffer, .{});
    pub const bytes = bridge.function(Request.bytes, .{});
    pub const formData = bridge.function(Request.formData, .{});
    pub const clone = bridge.function(Request.clone, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Request" {
    try testing.htmlRunner("net/request.html", .{});
}
