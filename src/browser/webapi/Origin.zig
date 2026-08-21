// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! `Origin`: the WebIDL wrapper around a URL origin. The one interface of the
//! window-surface cut with real behaviour to reproduce rather than a default to
//! report, because both of its comparisons answer for real.
//!
//! The constructor is the surprise: `new Origin(anything)` ignores its argument
//! entirely and always answers an *opaque* origin -- a valid URL, a garbage
//! string, a number and null all read back `opaque === true` (measured). A real
//! origin only comes from the static `Origin.from()`, which is also where the
//! two refusals live: a string that will not parse as a URL is one message, a
//! value that is not a string at all is another.
//!
//! Two opaque origins are never same-origin, not even with each other; an opaque
//! origin is same-origin only with itself, which is why identity rather than
//! contents decides that arm.
//!
//! Measured on a headed Chrome 151 with tools/fingerprint/probes/probe-shapes.js
//! and probe-s7-misc.js. A Chrome DedicatedWorkerGlobalScope carries this name
//! too (measured, probe-shapes-worker), so it goes on the worker list as well.

const std = @import("std");

const js = @import("../js/js.zig");
const URL = @import("URL.zig");
const dictionary = @import("dictionary.zig");
const Cookie = @import("storage/Cookie.zig");

const Execution = js.Execution;

const Origin = @This();

/// Null for an opaque origin, which has no scheme/host/port to compare.
_tuple: ?Tuple = null,

const Tuple = struct {
    scheme: []const u8,
    host: []const u8,
    port: []const u8,
};

const PREFIX = "Failed to execute '";

/// `new Origin()`. The argument is accepted and discarded: every constructed
/// Origin is opaque, whatever was passed (measured with seven different values).
pub fn constructor(_: ?js.Value, exec: *const Execution) !*Origin {
    return exec._factory.create(Origin{});
}

/// `Origin.from(urlOrOrigin)`. One required argument, and three outcomes: an
/// Origin passes through as an equal one, a string is parsed as a URL, and
/// anything else cannot have an origin extracted from it.
pub fn from(value_: ?js.Value, exec: *const Execution) !*Origin {
    const value = value_ orelse return dictionary.throwTypeError(
        PREFIX ++ "from' on 'Origin': 1 argument required, but only 0 present.",
        exec,
    );
    if (value.toZig(*Origin)) |origin| {
        return exec._factory.create(Origin{ ._tuple = origin._tuple });
    } else |_| {}
    if (value.isString() == null) {
        return dictionary.throwTypeError(
            PREFIX ++ "from' on 'Origin': An origin cannot be extracted from the given parameter.",
            exec,
        );
    }
    const text = try value.toStringSlice();
    const url = URL.parse(text, null, exec) orelse return dictionary.throwTypeError(
        PREFIX ++ "from' on 'Origin': The string provided cannot be parsed as a serialized URL.",
        exec,
    );
    const arena = exec.arena;
    return exec._factory.create(Origin{ ._tuple = .{
        .scheme = try arena.dupe(u8, url.getProtocol()),
        .host = try arena.dupe(u8, url.getHostname()),
        .port = try arena.dupe(u8, url.getPort()),
    } });
}

pub fn getOpaque(self: *const Origin) bool {
    return self._tuple == null;
}

fn other(self: *const Origin, comptime method: []const u8, value_: ?js.Value, exec: *const Execution) !*Origin {
    const value = value_ orelse return dictionary.throwTypeError(
        PREFIX ++ method ++ "' on 'Origin': 1 argument required, but only 0 present.",
        exec,
    );
    _ = self;
    return value.toZig(*Origin) catch dictionary.throwTypeError(
        PREFIX ++ method ++ "' on 'Origin': parameter 1 is not of type 'Origin'.",
        exec,
    );
}

/// Scheme, host and port all equal -- or, for an opaque origin, the very same
/// object: two separately constructed opaque origins are different origins.
pub fn isSameOrigin(self: *const Origin, value_: ?js.Value, exec: *const Execution) !bool {
    const target = try self.other("isSameOrigin", value_, exec);
    const mine = self._tuple orelse return target == self;
    const theirs = target._tuple orelse return false;
    return std.mem.eql(u8, mine.scheme, theirs.scheme) and
        std.mem.eql(u8, mine.host, theirs.host) and
        std.mem.eql(u8, mine.port, theirs.port);
}

/// Scheme plus registrable domain, so the port drops out and two subdomains of
/// one site match -- but http and https never do (all measured).
pub fn isSameSite(self: *const Origin, value_: ?js.Value, exec: *const Execution) !bool {
    const target = try self.other("isSameSite", value_, exec);
    const mine = self._tuple orelse return target == self;
    const theirs = target._tuple orelse return false;
    return std.mem.eql(u8, mine.scheme, theirs.scheme) and
        std.mem.eql(u8, Cookie.findSecondLevelDomain(mine.host), Cookie.findSecondLevelDomain(theirs.host));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Origin);

    pub const Meta = struct {
        pub const name = "Origin";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // One optional argument, so Chrome reports Origin.length === 0.
    pub const constructor = bridge.constructor(Origin.constructor, .{ .arity = 0 });
    pub const @"opaque" = bridge.accessor(Origin.getOpaque, null, .{});
    pub const isSameOrigin = bridge.function(Origin.isSameOrigin, .{ .arity = 1 });
    pub const isSameSite = bridge.function(Origin.isSameSite, .{ .arity = 1 });
    pub const from = bridge.function(Origin.from, .{ .static = true, .arity = 1 });
};

const testing = @import("../../testing.zig");
test "WebApi: SurfaceMisc" {
    try testing.htmlRunner("surface_misc.html", .{});
}
