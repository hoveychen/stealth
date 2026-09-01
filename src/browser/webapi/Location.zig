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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const URL = @import("URL.zig");
const U = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const DOMStringList = @import("collections.zig").DOMStringList;

const Location = @This();

_url: *URL,
_rc: lp.RC = .{},
/// Built once and handed back by identity: Chrome answers the same
/// DOMStringList on every read, and a document's ancestors cannot change
/// under it -- a fragment navigation replaces the whole Location anyway.
_ancestor_origins: ?*DOMStringList = null,

pub fn init(raw_url: []const u8, frame: *Frame) !*Location {
    const url = try URL.init(raw_url, null, &frame.js.execution);
    url.acquireRef();
    errdefer url.releaseRef(frame._page);

    return frame._factory.create(Location{
        ._url = url,
    });
}

pub fn deinit(self: *const Location, page: *Page) void {
    self._url.releaseRef(page);
    if (self._ancestor_origins) |list| {
        list.releaseRef(page);
    }
}

pub fn acquireRef(self: *Location) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Location, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getPathname(self: *const Location) []const u8 {
    return self._url.getPathname();
}

pub fn getProtocol(self: *const Location) []const u8 {
    return self._url.getProtocol();
}

pub fn getHostname(self: *const Location) []const u8 {
    return self._url.getHostname();
}

pub fn getHost(self: *const Location) []const u8 {
    return self._url.getHost();
}

pub fn getPort(self: *const Location) []const u8 {
    return self._url.getPort();
}

pub fn getOrigin(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getOrigin(exec);
}

/// The origins of the frames above this one, immediate parent first and the
/// top frame last. A frame that is not framed gets an empty list.
///
/// This is the one place a frame is told about ancestors it may not otherwise
/// touch: a cross-origin ancestor is listed all the same. An ancestor whose
/// origin is opaque serialises as the string "null", the way it does
/// everywhere else an origin is written down.
pub fn getAncestorOrigins(self: *Location, frame: *Frame) !*DOMStringList {
    if (self._ancestor_origins) |list| {
        return list;
    }

    var count: usize = 0;
    var ancestor = frame.parent;
    while (ancestor) |f| : (ancestor = f.parent) {
        count += 1;
    }

    const arena = try frame.js.execution.getArena(.small, "Location.ancestorOrigins");
    errdefer arena.release();

    const items = try arena.allocator().alloc([]const u8, count);
    var i: usize = 0;
    ancestor = frame.parent;
    while (ancestor) |f| : (ancestor = f.parent) {
        items[i] = try arena.dupe(u8, f.origin orelse "null");
        i += 1;
    }

    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = items, ._arena = arena };
    list.acquireRef();
    self._ancestor_origins = list;
    return list;
}

pub fn getSearch(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getSearch(exec);
}

pub fn getHash(self: *const Location) []const u8 {
    return self._url.getHash();
}

pub fn setPathname(_: *const Location, pathname: []const u8, frame: *Frame) !void {
    const new_url = try U.setPathname(frame.url, pathname, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

/// The four components Chrome lets a page write and we did not. Each rebuilds
/// the URL around the one part that changed and navigates, exactly the way the
/// pathname setter above does -- there is no in-place mutation of a Location.
///
/// Their absence was readable without ever assigning anything:
/// `Object.getOwnPropertyDescriptor(location, 'protocol').set` answers
/// `undefined` on an engine that made the attribute read-only and a function on
/// Chrome, which is the same shape of tell as the member's placement.
pub fn setProtocol(_: *const Location, protocol: []const u8, frame: *Frame) !void {
    const new_url = try U.setProtocol(frame.url, protocol, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

pub fn setHost(_: *const Location, host: []const u8, frame: *Frame) !void {
    const new_url = try U.setHost(frame.url, host, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

pub fn setHostname(_: *const Location, hostname: []const u8, frame: *Frame) !void {
    const new_url = try U.setHostname(frame.url, hostname, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

/// An empty string clears the port, which is why the underlying helper takes an
/// optional: `location.port = ''` drops it rather than writing an empty one.
pub fn setPort(_: *const Location, port: []const u8, frame: *Frame) !void {
    const new_url = try U.setPort(frame.url, if (port.len == 0) null else port, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

pub fn setSearch(_: *const Location, search: []const u8, frame: *Frame) !void {
    const new_url = try U.setSearch(frame.url, search, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

pub fn setHash(_: *const Location, hash: []const u8, frame: *Frame) !void {
    const old_url = frame.url;
    const base_end = std.mem.indexOfScalar(u8, old_url, '#') orelse old_url.len;
    // Includes the leading '#'; empty when the URL has no fragment.
    const old_fragment = old_url[base_end..];

    const normalized_hash: []const u8 = blk: {
        if (hash.len == 0) {
            break :blk "";
        } else if (hash[0] == '#') {
            break :blk hash;
        }
        // Scratch only: scheduleNavigation dupes the URL into its own arena
        // synchronously, so the local arena suffices.
        break :blk try std.fmt.allocPrint(frame.local_arena, "#{s}", .{hash});
    };

    // Per the Location hash setter, when the fragment doesn't change no
    // navigation happens at all — in particular `location.hash = ""` on a
    // fragment-less URL must not turn into a same-URL reload.
    if (std.mem.eql(u8, old_fragment, normalized_hash)) {
        return;
    }

    const target_url = if (normalized_hash.len == 0) old_url[0..base_end] else normalized_hash;

    return frame.scheduleNavigation(target_url, .{
        .reason = .script,
        .kind = .{ .replace = null },
    }, .{ .script = frame });
}

pub fn assign(_: *const Location, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = frame });
}

pub fn replace(_: *const Location, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .replace = null } }, .{ .script = frame });
}

pub fn reload(_: *const Location, frame: *Frame) !void {
    return frame.scheduleNavigation(frame.url, .{ .reason = .script, .kind = .reload }, .{ .script = frame });
}

pub fn toString(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.toString(exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Location);

    pub const Meta = struct {
        pub const name = "Location";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // See the comment in Snapshot.attachClass: an own @@toPrimitive of
        // value undefined, from HTML's Location creation steps.
        pub const to_primitive_undefined = true;
        // ...and the own `valueOf` those same steps define, which is the
        // realm's %Object.prototype.valueOf% and therefore cannot come out of
        // a template. attachClass reserves the slot and Local.zigValueToJs
        // fills it; both halves are keyed on this one flag.
        pub const own_value_of = true;
    };

    // Every member of Location is [LegacyUnforgeable]: it lives on the instance
    // as a non-configurable own property, and `Location.prototype` is left with
    // nothing but `constructor` (measured on Chrome 151). This is the whole
    // interface, operations included -- a detector that finds `href` gone from
    // the prototype only has to look one name over at `reload`.
    const unforgeable: js.Caller.Function.Opts = .{ .unforgeable = true, .deletable = false };

    // Declaration order is install order is `Object.getOwnPropertyNames(location)`
    // order, and with every member unforgeable that list is now a fingerprint of
    // its own. This is Chrome 151's, which is neither IDL order nor alphabetical:
    //
    //   valueOf, ancestorOrigins, href, origin, protocol, host, hostname, port,
    //   pathname, search, hash, assign, reload, replace, toString
    //
    // `valueOf` is not declared here because it is not an IDL member at all:
    // HTML's creation steps define it before any of these, which is why it
    // sorts first. `Meta.own_value_of` is where it comes from.
    pub const ancestorOrigins = bridge.accessor(Location.getAncestorOrigins, null, unforgeable);
    pub const href = bridge.accessor(Location.toString, setHref, unforgeable);
    fn setHref(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
        return self.assign(url, frame);
    }

    // `origin` and `ancestorOrigins` are the interface's only two read-only
    // attributes; every other one is writable on Chrome.
    pub const origin = bridge.accessor(Location.getOrigin, null, unforgeable);
    pub const protocol = bridge.accessor(Location.getProtocol, Location.setProtocol, unforgeable);
    pub const host = bridge.accessor(Location.getHost, Location.setHost, unforgeable);
    pub const hostname = bridge.accessor(Location.getHostname, Location.setHostname, unforgeable);
    pub const port = bridge.accessor(Location.getPort, Location.setPort, unforgeable);
    pub const pathname = bridge.accessor(Location.getPathname, Location.setPathname, unforgeable);
    pub const search = bridge.accessor(Location.getSearch, Location.setSearch, unforgeable);
    pub const hash = bridge.accessor(Location.getHash, Location.setHash, unforgeable);
    pub const assign = bridge.function(Location.assign, unforgeable);
    pub const reload = bridge.function(Location.reload, unforgeable);
    pub const replace = bridge.function(Location.replace, unforgeable);
    pub const toString = bridge.function(Location.toString, unforgeable);
};
