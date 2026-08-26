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

//! The four WebTransport interfaces.
//!
//! No HTTP/3 connection is ever opened — this engine has no QUIC stack — so the
//! object is the one Chrome hands back for a server that is not there: every URL
//! is validated exactly as Chrome validates it (the three SyntaxErrors below are
//! its own wording), the object exists with all its streams, and then the
//! handshake fails. Which failure the promises carry depends on the race Chrome
//! itself exposes: `close()` called before the handshake gives up wins, and both
//! `ready` and `closed` then reject with "close() is called while connecting."
//! instead of "Opening handshake failed." So the failure is scheduled as a task
//! rather than raised in the constructor, and a synchronous `close()` beats it —
//! which is what a script sees on a real Chrome (measured, win26-chrome.json).
//!
//! Shapes measured on a headed Chrome 150 (win20-chrome.json); behaviour in
//! win22-chrome.json and win26-chrome.json.

const std = @import("std");

const js = @import("../js/js.zig");

const U = @import("../../sys/url.zig");
const DOMException = @import("DOMException.zig");
const ReadableStream = @import("streams/ReadableStream.zig");
const WritableStream = @import("streams/WritableStream.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        WebTransport,
        WebTransportBidirectionalStream,
        WebTransportDatagramDuplexStream,
        WebTransportError,
    };
}

fn throwSyntaxError(message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, "SyntaxError"), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

pub const WebTransport = struct {
    _execution: *const Execution,
    _datagrams: ?*WebTransportDatagramDuplexStream = null,
    _incoming_uni: ?*ReadableStream = null,
    _incoming_bidi: ?*ReadableStream = null,
    _ready: ?js.PromiseResolver.Global = null,
    _closed: ?js.PromiseResolver.Global = null,
    /// Set by close(), or by the scheduled handshake failure — whichever runs
    /// first decides the wording both promises reject with.
    _failure: ?Failure = null,

    const Failure = enum {
        handshake,
        closed_while_connecting,

        fn message(self: Failure) []const u8 {
            return switch (self) {
                .handshake => "Opening handshake failed.",
                .closed_while_connecting => "close() is called while connecting.",
            };
        }
    };

    /// WebTransportOptions. Nothing here changes what a connectionless
    /// transport does, but Chrome accepts the dictionary, so it is read and
    /// discarded rather than rejected.
    const Options = struct {
        allowPooling: ?bool = null,
        requireUnreliable: ?bool = null,
        congestionControl: ?[]const u8 = null,
        anticipatedConcurrentIncomingUnidirectionalStreams: ?u32 = null,
        anticipatedConcurrentIncomingBidirectionalStreams: ?u32 = null,
        protocols: ?[]const []const u8 = null,
    };

    /// CloseInfo.
    const CloseInfo = struct {
        closeCode: ?u32 = null,
        reason: ?[]const u8 = null,
    };

    pub fn init(url: []const u8, _: ?Options, exec: *Execution) !*WebTransport {
        try validateUrl(url, exec);

        const self = try exec._factory.create(WebTransport{ ._execution = exec });
        // Zero delay: the failure lands on the next task, so an `await` sees it
        // but a synchronous close() in the same script turn still wins.
        try exec._scheduler.add(self, handshakeFailed, 0, .{ .name = "WebTransport.handshake" });
        return self;
    }

    /// Chrome checks the three in this order: parseable, then scheme, then
    /// fragment (measured — `wss://localhost:1/` reports the scheme and
    /// `https://localhost:1/x#f` reports the fragment).
    fn validateUrl(url: []const u8, exec: *const Execution) !void {
        var err: i32 = 0;
        const parsed = U.url_parse(url.ptr, url.len, &err) orelse {
            return throwSyntaxError(try std.fmt.allocPrint(
                exec.arena,
                "Failed to construct 'WebTransport': The URL '{s}' is invalid.",
                .{url},
            ), exec);
        };
        defer U.url_free(parsed);

        var ptr: [*]const u8 = undefined;
        var len: usize = 0;
        U.url_get_scheme(parsed, &ptr, &len);
        const scheme = ptr[0..len];
        if (!std.mem.eql(u8, scheme, "https")) {
            return throwSyntaxError(try std.fmt.allocPrint(
                exec.arena,
                "Failed to construct 'WebTransport': The URL's scheme must be 'https'. '{s}' is not allowed.",
                .{scheme},
            ), exec);
        }

        // An empty fragment still counts: Chrome reports ('#') for
        // "https://localhost:1/x#".
        if (U.url_get_fragment(parsed, &ptr, &len) == 0) {
            return throwSyntaxError(try std.fmt.allocPrint(
                exec.arena,
                "Failed to construct 'WebTransport': The URL contains a fragment identifier ('#{s}'). " ++
                    "Fragment identifiers are not allowed in WebTransport URLs.",
                .{ptr[0..len]},
            ), exec);
        }
    }

    fn handshakeFailed(ptr: *anyopaque) !?u32 {
        const self: *WebTransport = @ptrCast(@alignCast(ptr));

        var ls: js.Local.Scope = undefined;
        self._execution.js.localScope(&ls);
        defer ls.deinit();

        self.fail(.handshake, &ls.local);
        return null;
    }

    fn fail(self: *WebTransport, reason: Failure, local: *const js.Local) void {
        if (self._failure != null) {
            return;
        }
        self._failure = reason;

        const exec = self._execution;
        inline for (.{ "_ready", "_closed" }) |field| {
            if (@field(self, field)) |resolver| {
                const err = transportError(reason.message(), exec) catch return;
                local.toLocal(resolver).reject("WebTransport." ++ field, err);
            }
        }
    }

    fn transportError(message: []const u8, exec: *const Execution) !*WebTransportError {
        return exec._factory.domException(
            DOMException.init(message, "WebTransportError"),
            WebTransportError{ ._proto = undefined },
        );
    }

    /// Both promises are the same object on every read (measured), and both
    /// carry the same rejection.
    fn promiseFor(self: *WebTransport, comptime field: []const u8, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (@field(self, field)) |resolver| {
            return local.toLocal(resolver).promise();
        }

        const resolver = local.createPromiseResolver();
        @field(self, field) = try resolver.persist();
        if (self._failure) |reason| {
            resolver.reject("WebTransport." ++ field, try transportError(reason.message(), exec));
        }
        return resolver.promise();
    }

    pub fn getReady(self: *WebTransport, exec: *const Execution) !js.Promise {
        return self.promiseFor("_ready", exec);
    }

    pub fn getClosed(self: *WebTransport, exec: *const Execution) !js.Promise {
        return self.promiseFor("_closed", exec);
    }

    pub fn getDatagrams(self: *WebTransport, exec: *const Execution) !*WebTransportDatagramDuplexStream {
        if (self._datagrams == null) {
            self._datagrams = try WebTransportDatagramDuplexStream.init(exec);
        }
        return self._datagrams.?;
    }

    pub fn getIncomingUnidirectionalStreams(self: *WebTransport, exec: *const Execution) !*ReadableStream {
        if (self._incoming_uni == null) {
            self._incoming_uni = try ReadableStream.init(null, null, exec);
        }
        return self._incoming_uni.?;
    }

    pub fn getIncomingBidirectionalStreams(self: *WebTransport, exec: *const Execution) !*ReadableStream {
        if (self._incoming_bidi == null) {
            self._incoming_bidi = try ReadableStream.init(null, null, exec);
        }
        return self._incoming_bidi.?;
    }

    /// Always "" — the protocol is only known once a handshake succeeds.
    pub fn getProtocol(_: *const WebTransport) []const u8 {
        return "";
    }

    pub fn close(self: *WebTransport, _: ?CloseInfo, exec: *const Execution) void {
        self.fail(.closed_while_connecting, exec.js.local.?);
    }

    fn noConnection(comptime name: []const u8, exec: *const Execution) js.Promise {
        var resolver = exec.js.local.?.createPromiseResolver();
        resolver.reject("WebTransport." ++ name, DOMException.init(
            "Failed to execute '" ++ name ++ "' on 'WebTransport': No connection.",
            "NetworkError",
        ));
        return resolver.promise();
    }

    pub fn createBidirectionalStream(_: *WebTransport, _: ?js.Value, exec: *const Execution) js.Promise {
        return noConnection("createBidirectionalStream", exec);
    }

    pub fn createUnidirectionalStream(_: *WebTransport, _: ?js.Value, exec: *const Execution) js.Promise {
        return noConnection("createUnidirectionalStream", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebTransport);

        pub const Meta = struct {
            pub const name = "WebTransport";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = WebTransport;

        pub const constructor = bridge.constructor(T.init, .{});
        pub const incomingUnidirectionalStreams = bridge.accessor(T.getIncomingUnidirectionalStreams, null, .{});
        pub const incomingBidirectionalStreams = bridge.accessor(T.getIncomingBidirectionalStreams, null, .{});
        pub const datagrams = bridge.accessor(T.getDatagrams, null, .{});
        pub const ready = bridge.accessor(T.getReady, null, .{});
        pub const closed = bridge.accessor(T.getClosed, null, .{});
        pub const close = bridge.function(T.close, .{});
        pub const createBidirectionalStream = bridge.function(T.createBidirectionalStream, .{});
        pub const createUnidirectionalStream = bridge.function(T.createUnidirectionalStream, .{});
        pub const protocol = bridge.accessor(T.getProtocol, null, .{});
    };
};

/// Only ever reached through a connection that never opens, so nothing
/// constructs one. It exists because CreepJS counts the global.
pub const WebTransportBidirectionalStream = struct {
    _readable: *ReadableStream,
    _writable: *WritableStream,

    pub fn getReadable(self: *const WebTransportBidirectionalStream) *ReadableStream {
        return self._readable;
    }

    pub fn getWritable(self: *const WebTransportBidirectionalStream) *WritableStream {
        return self._writable;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebTransportBidirectionalStream);

        pub const Meta = struct {
            pub const name = "WebTransportBidirectionalStream";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = WebTransportBidirectionalStream;

        pub const readable = bridge.accessor(T.getReadable, null, .{});
        pub const writable = bridge.accessor(T.getWritable, null, .{});
    };
};

/// The datagram pair. Chrome hands one out before the handshake resolves, with
/// the values below already in place (measured); the two max ages are null and
/// both high water marks are 1, and all four are writable.
pub const WebTransportDatagramDuplexStream = struct {
    _readable: *ReadableStream,
    _writable: *WritableStream,
    _incoming_max_age: ?f64 = null,
    _outgoing_max_age: ?f64 = null,
    _incoming_high_water_mark: f64 = 1,
    _outgoing_high_water_mark: f64 = 1,
    // Both default to 1 in Chrome, measured off `new WebTransport(...).datagrams`
    // before the connection settles.
    _incoming_max_buffered_datagrams: f64 = 1,
    _outgoing_max_buffered_datagrams: f64 = 1,

    pub fn init(exec: *const Execution) !*WebTransportDatagramDuplexStream {
        return exec._factory.create(WebTransportDatagramDuplexStream{
            ._readable = try ReadableStream.init(null, null, exec),
            ._writable = try WritableStream.init(null, exec),
        });
    }

    pub fn getReadable(self: *const WebTransportDatagramDuplexStream) *ReadableStream {
        return self._readable;
    }

    pub fn getWritable(self: *const WebTransportDatagramDuplexStream) *WritableStream {
        return self._writable;
    }

    /// Chrome reports 1024 before any connection exists (measured).
    pub fn getMaxDatagramSize(_: *const WebTransportDatagramDuplexStream) u32 {
        return 1024;
    }

    pub fn getIncomingMaxAge(self: *const WebTransportDatagramDuplexStream) ?f64 {
        return self._incoming_max_age;
    }

    pub fn setIncomingMaxAge(self: *WebTransportDatagramDuplexStream, value: ?f64) void {
        self._incoming_max_age = value;
    }

    pub fn getOutgoingMaxAge(self: *const WebTransportDatagramDuplexStream) ?f64 {
        return self._outgoing_max_age;
    }

    pub fn setOutgoingMaxAge(self: *WebTransportDatagramDuplexStream, value: ?f64) void {
        self._outgoing_max_age = value;
    }

    pub fn getIncomingMaxBufferedDatagrams(self: *const WebTransportDatagramDuplexStream) f64 {
        return self._incoming_max_buffered_datagrams;
    }

    pub fn setIncomingMaxBufferedDatagrams(self: *WebTransportDatagramDuplexStream, value: f64) void {
        self._incoming_max_buffered_datagrams = value;
    }

    pub fn getOutgoingMaxBufferedDatagrams(self: *const WebTransportDatagramDuplexStream) f64 {
        return self._outgoing_max_buffered_datagrams;
    }

    pub fn setOutgoingMaxBufferedDatagrams(self: *WebTransportDatagramDuplexStream, value: f64) void {
        self._outgoing_max_buffered_datagrams = value;
    }

    pub fn getIncomingHighWaterMark(self: *const WebTransportDatagramDuplexStream) f64 {
        return self._incoming_high_water_mark;
    }

    pub fn setIncomingHighWaterMark(self: *WebTransportDatagramDuplexStream, value: f64) void {
        self._incoming_high_water_mark = value;
    }

    pub fn getOutgoingHighWaterMark(self: *const WebTransportDatagramDuplexStream) f64 {
        return self._outgoing_high_water_mark;
    }

    pub fn setOutgoingHighWaterMark(self: *WebTransportDatagramDuplexStream, value: f64) void {
        self._outgoing_high_water_mark = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebTransportDatagramDuplexStream);

        pub const Meta = struct {
            pub const name = "WebTransportDatagramDuplexStream";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = WebTransportDatagramDuplexStream;

        pub const readable = bridge.accessor(T.getReadable, null, .{});
        pub const writable = bridge.accessor(T.getWritable, null, .{});
        pub const maxDatagramSize = bridge.accessor(T.getMaxDatagramSize, null, .{});
        pub const incomingMaxAge = bridge.accessor(T.getIncomingMaxAge, T.setIncomingMaxAge, .{});
        pub const outgoingMaxAge = bridge.accessor(T.getOutgoingMaxAge, T.setOutgoingMaxAge, .{});
        pub const incomingMaxBufferedDatagrams = bridge.accessor(T.getIncomingMaxBufferedDatagrams, T.setIncomingMaxBufferedDatagrams, .{});
        pub const outgoingMaxBufferedDatagrams = bridge.accessor(T.getOutgoingMaxBufferedDatagrams, T.setOutgoingMaxBufferedDatagrams, .{});
        pub const incomingHighWaterMark = bridge.accessor(T.getIncomingHighWaterMark, T.setIncomingHighWaterMark, .{});
        pub const outgoingHighWaterMark = bridge.accessor(T.getOutgoingHighWaterMark, T.setOutgoingHighWaterMark, .{});
    };
};

/// Chrome's WebTransportError takes one optional dictionary, not (message,
/// options): `new WebTransportError('x', {...})` reports "The provided value is
/// not of type 'WebTransportErrorInit'." because the *string* is what fails the
/// conversion (measured). `source` is read-only in practice — passing
/// {source: 'session'} still reads back "stream" — and streamErrorCode is a
/// clamped octet: 4294967295 comes back as 255 and -1 as 0.
pub const WebTransportError = struct {
    pub const Proto = DOMException;

    _proto: *DOMException,
    _stream_error_code: ?u8 = null,

    // Read by hand rather than as a bridge dictionary: the point of the
    // measurement is the wording a *non*-dictionary argument produces, and the
    // bridge's own conversion failure says "invalid argument", which no browser
    // says.
    pub fn init(init_: ?js.Value, exec: *Execution) !*WebTransportError {
        var code: ?u8 = null;
        var message: []const u8 = "";

        if (init_) |value| {
            if (!value.isNullOrUndefined()) {
                if (!value.isObject()) {
                    const local = exec.js.local.?;
                    _ = local.isolate.throwException(local.isolate.createTypeError(
                        "Failed to construct 'WebTransportError': " ++
                            "The provided value is not of type 'WebTransportErrorInit'.",
                    ));
                    return error.JsException;
                }

                const obj = value.toObject();
                const raw = try obj.get("streamErrorCode");
                if (!raw.isNullOrUndefined()) {
                    // [Clamp] octet: 4294967295 reads back as 255 and -1 as 0.
                    const n = try raw.toF64();
                    code = if (std.math.isNan(n)) 0 else @intFromFloat(std.math.clamp(@round(n), 0, 255));
                }

                const raw_message = try obj.get("message");
                if (!raw_message.isUndefined()) {
                    message = try exec.arena.dupe(u8, try raw_message.toStringSmart());
                }
            }
        }

        return exec._factory.domException(
            DOMException.init(message, "WebTransportError"),
            WebTransportError{ ._proto = undefined, ._stream_error_code = code },
        );
    }

    pub fn getStreamErrorCode(self: *const WebTransportError) ?u8 {
        return self._stream_error_code;
    }

    pub fn getSource(_: *const WebTransportError) []const u8 {
        return "stream";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebTransportError);

        pub const Meta = struct {
            pub const name = "WebTransportError";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(WebTransportError.init, .{});
        pub const streamErrorCode = bridge.accessor(WebTransportError.getStreamErrorCode, null, .{});
        pub const source = bridge.accessor(WebTransportError.getSource, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: WebTransport" {
    try testing.htmlRunner("web_transport.html", .{});
}
