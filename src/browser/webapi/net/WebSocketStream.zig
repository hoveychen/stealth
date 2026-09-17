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
// The promise-and-streams face of WebSockets. One of the five names DataDome's
// device-check program asked for and did not get; see BarcodeDetector.zig for
// the set and where it came from.
//
// Measured on a headed Chrome 152 (probe scratch/s34/shape.js plus the
// behaviour readings in the plan's P2 notes):
//
//   * WebSocketStream.length is 1 and `new WebSocketStream()` is a TypeError
//     reading "Failed to construct 'WebSocketStream': 1 argument required, but
//     only 0 present." -- which the bridge's own arity check writes.
//   * The interface object carries no statics; the prototype carries url,
//     opened, closed and close -- in that order -- and does not descend from
//     EventTarget.
//   * `new WebSocketStream('wss://example.invalid/').url` reads back
//     "wss://example.invalid/".
//   * It is the one name of the five that is NOT [SecureContext]: it is present
//     from an insecure origin too, so it is not in the gated list. (A ws: URL
//     from a secure page is refused by mixed-content rules instead, which is a
//     different gate and not one this engine models.)
//
// Nothing here connects. `opened` and `closed` are pending promises that never
// settle -- a connection that is still being established, which is the honest
// description of a socket this engine will not open. They are cached on the
// instance so `s.opened === s.opened`, the way Chrome's are: an attribute that
// mints a fresh object per read is a one-expression tell (the same mistake that
// made document.forms !== document.forms here).

const std = @import("std");

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");

const Execution = js.Execution;

const WebSocketStream = @This();

_url: [:0]const u8,

pub fn constructor(url: []const u8, exec: *const Execution) !*WebSocketStream {
    // Same URL rules as WebSocket: no fragment, ws/wss only, with http(s)
    // rewritten to ws(s) -- see net/WebSocket.zig's init, which this mirrors.
    if (std.mem.indexOfScalar(u8, url, '#') != null) {
        return error.SyntaxError;
    }

    const resolved_url = blk: {
        const resolved = URL.resolve(exec.arena, exec.base(), url, .{ .encoding = "UTF-8" }) catch |err| switch (err) {
            error.TypeError => return error.SyntaxError,
            else => return err,
        };

        const scheme = URL.getProtocol(resolved);
        if (std.mem.eql(u8, scheme, "ws:") or std.mem.eql(u8, scheme, "wss:")) {
            break :blk resolved;
        }
        if (std.mem.eql(u8, scheme, "http:")) {
            break :blk try std.fmt.allocPrintSentinel(exec.arena, "ws{s}", .{resolved["http".len..]}, 0);
        }
        if (std.mem.eql(u8, scheme, "https:")) {
            break :blk try std.fmt.allocPrintSentinel(exec.arena, "wss{s}", .{resolved["https".len..]}, 0);
        }
        return error.SyntaxError;
    };

    return exec._factory.create(WebSocketStream{ ._url = resolved_url });
}

pub fn getUrl(self: *const WebSocketStream) []const u8 {
    return self._url;
}

/// Pending forever: nothing opens the socket. Cached so the identity is stable
/// across reads.
pub fn getOpened(_: *WebSocketStream, exec: *const Execution) js.Promise {
    return exec.js.local.?.createPromiseResolver().promise();
}

pub fn getClosed(_: *WebSocketStream, exec: *const Execution) js.Promise {
    return exec.js.local.?.createPromiseResolver().promise();
}

/// A close on a socket that never opened. Chrome's returns undefined and
/// settles `closed`; there is nothing here to settle.
pub fn close(_: *WebSocketStream, _: ?js.Value) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebSocketStream);

    pub const Meta = struct {
        pub const name = "WebSocketStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(WebSocketStream.constructor, .{});
    // Chrome's prototype order (measured), which is not alphabetical.
    pub const url = bridge.accessor(WebSocketStream.getUrl, null, .{});
    pub const opened = bridge.accessor(WebSocketStream.getOpened, null, .{ .cache = .{ .private = "web_socket_stream_opened" } });
    pub const closed = bridge.accessor(WebSocketStream.getClosed, null, .{ .cache = .{ .private = "web_socket_stream_closed" } });
    pub const close = bridge.function(WebSocketStream.close, .{ .arity = 0 });
};

const testing = @import("../../../testing.zig");
test "WebApi: WebSocketStream" {
    try testing.htmlRunner("web_socket_stream.html", .{});
}
