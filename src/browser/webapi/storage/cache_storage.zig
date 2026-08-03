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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! window.caches: the Cache Storage API, in memory and for the life of the
//! page.
//!
//! Chrome's version is backed by disk and survives a reload; this one does
//! not, which no script can tell apart inside a single page. What it does
//! reproduce is everything a script can observe within that page -- open/has/
//! keys/delete on the storage, put/match/matchAll/keys/delete on a cache, and
//! the argument errors -- all measured on a headed Chrome 150 over
//! http://localhost (win7-chrome.json).
//!
//! add() and addAll() are the exception: they fetch, and there is no way to
//! chain a Zig continuation onto this engine's fetch promise, so they give the
//! answer Chrome gives when the fetch does not come back. See addFailed().

const std = @import("std");

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");

const Request = @import("../net/Request.zig");
const Response = @import("../net/Response.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        CacheStorage,
        Cache,
    };
}

// Both `cache.match('/x')` and `cache.put('/x', ...)` name an entry by its
// absolute URL, so requests are keyed on the resolved string. Request.init
// resolves the same way, which is why a Request and the string it was built
// from find each other.
fn keyOf(input: Request.Input, exec: *const Execution) ![]const u8 {
    return switch (input) {
        .request => |request| request._url,
        .url => |url| try URL.resolve(exec.call_arena, exec.base(), url, .{ .encoding = exec.charset.* }),
    };
}

pub const CacheStorage = struct {
    _named: std.ArrayListUnmanaged(Named) = .empty,

    const Named = struct {
        name: []const u8,
        cache: *Cache,
    };

    pub const init: CacheStorage = .{};

    fn find(self: *const CacheStorage, name: []const u8) ?*Cache {
        for (self._named.items) |named| {
            if (std.mem.eql(u8, named.name, name)) return named.cache;
        }
        return null;
    }

    pub fn open(self: *CacheStorage, name_: ?[]const u8, exec: *const Execution) !js.Promise {
        const name = name_ orelse return missingArgument("open", "CacheStorage", exec);
        if (self.find(name)) |cache| {
            return exec.js.local.?.resolvePromise(cache);
        }
        const cache = try exec._factory.create(Cache{});
        try self._named.append(exec.arena, .{
            .name = try exec.dupeString(name),
            .cache = cache,
        });
        return exec.js.local.?.resolvePromise(cache);
    }

    pub fn has(self: *const CacheStorage, name_: ?[]const u8, exec: *const Execution) !js.Promise {
        const name = name_ orelse return missingArgument("has", "CacheStorage", exec);
        return exec.js.local.?.resolvePromise(self.find(name) != null);
    }

    pub fn delete(self: *CacheStorage, name_: ?[]const u8, exec: *const Execution) !js.Promise {
        const name = name_ orelse return missingArgument("delete", "CacheStorage", exec);
        for (self._named.items, 0..) |named, i| {
            if (std.mem.eql(u8, named.name, name)) {
                _ = self._named.orderedRemove(i);
                return exec.js.local.?.resolvePromise(true);
            }
        }
        return exec.js.local.?.resolvePromise(false);
    }

    // Insertion order, which is the order Chrome reports too.
    pub fn keys(self: *const CacheStorage, exec: *const Execution) !js.Promise {
        const names = try exec.call_arena.alloc([]const u8, self._named.items.len);
        for (self._named.items, names) |named, *out| {
            out.* = named.name;
        }
        return exec.js.local.?.resolvePromise(names);
    }

    // Storage-wide match: the first hit, walking the caches in creation order.
    pub fn match(self: *const CacheStorage, input_: ?Request.Input, _: ?js.Value, exec: *const Execution) !js.Promise {
        const input = input_ orelse return missingArgument("match", "CacheStorage", exec);
        const key = try keyOf(input, exec);
        for (self._named.items) |named| {
            if (named.cache.lookup(key)) |response| {
                return exec.js.local.?.resolvePromise(response);
            }
        }
        // A miss resolves with undefined, not null (measured).
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CacheStorage);

        pub const Meta = struct {
            pub const name = "CacheStorage";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order.
        pub const delete = bridge.function(CacheStorage.delete, .{ .arity = 1 });
        pub const has = bridge.function(CacheStorage.has, .{ .arity = 1 });
        pub const keys = bridge.function(CacheStorage.keys, .{});
        pub const match = bridge.function(CacheStorage.match, .{ .arity = 1 });
        pub const open = bridge.function(CacheStorage.open, .{ .arity = 1 });
    };
};

pub const Cache = struct {
    _records: std.ArrayListUnmanaged(Record) = .empty,

    const Record = struct {
        key: []const u8,
        request: *Request,
        response: *Response,
    };

    fn lookup(self: *const Cache, key: []const u8) ?*Response {
        for (self._records.items) |record| {
            if (std.mem.eql(u8, record.key, key)) return record.response;
        }
        return null;
    }

    pub fn put(
        self: *Cache,
        input_: ?Request.Input,
        response_: ?js.Value,
        exec: *const Execution,
    ) !js.Promise {
        const input = input_ orelse return missingPutArgument("0", exec);
        const value = response_ orelse return missingPutArgument("1", exec);
        const response = value.toZig(*Response) catch return exec.js.local.?.rejectPromise(.{
            .type_error = "Failed to execute 'put' on 'Cache': parameter 2 is not of type 'Response'.",
        });
        const key = try keyOf(input, exec);
        const request = switch (input) {
            .request => |r| r,
            .url => try Request.init(input, null, exec),
        };
        for (self._records.items) |*record| {
            if (std.mem.eql(u8, record.key, key)) {
                record.request = request;
                record.response = response;
                return exec.js.local.?.resolvePromise({});
            }
        }
        try self._records.append(exec.arena, .{
            .key = try exec.dupeString(key),
            .request = request,
            .response = response,
        });
        return exec.js.local.?.resolvePromise({});
    }

    pub fn match(self: *const Cache, input_: ?Request.Input, _: ?js.Value, exec: *const Execution) !js.Promise {
        const input = input_ orelse return missingArgument("match", "Cache", exec);
        if (self.lookup(try keyOf(input, exec))) |response| {
            return exec.js.local.?.resolvePromise(response);
        }
        return exec.js.local.?.resolvePromise({});
    }

    // With no request, every entry; with one, the entries that match it.
    pub fn matchAll(self: *const Cache, input_: ?Request.Input, _: ?js.Value, exec: *const Execution) !js.Promise {
        if (input_) |input| {
            const key = try keyOf(input, exec);
            if (self.lookup(key)) |response| {
                const one = try exec.call_arena.alloc(*Response, 1);
                one[0] = response;
                return exec.js.local.?.resolvePromise(one);
            }
            const none: []const *Response = &.{};
            return exec.js.local.?.resolvePromise(none);
        }
        const all = try exec.call_arena.alloc(*Response, self._records.items.len);
        for (self._records.items, all) |record, *out| {
            out.* = record.response;
        }
        return exec.js.local.?.resolvePromise(all);
    }

    pub fn keys(self: *const Cache, input_: ?Request.Input, _: ?js.Value, exec: *const Execution) !js.Promise {
        if (input_) |input| {
            const key = try keyOf(input, exec);
            for (self._records.items) |record| {
                if (std.mem.eql(u8, record.key, key)) {
                    const one = try exec.call_arena.alloc(*Request, 1);
                    one[0] = record.request;
                    return exec.js.local.?.resolvePromise(one);
                }
            }
            const none: []const *Request = &.{};
            return exec.js.local.?.resolvePromise(none);
        }
        const all = try exec.call_arena.alloc(*Request, self._records.items.len);
        for (self._records.items, all) |record, *out| {
            out.* = record.request;
        }
        return exec.js.local.?.resolvePromise(all);
    }

    pub fn delete(self: *Cache, input_: ?Request.Input, _: ?js.Value, exec: *const Execution) !js.Promise {
        const input = input_ orelse return missingArgument("delete", "Cache", exec);
        const key = try keyOf(input, exec);
        for (self._records.items, 0..) |record, i| {
            if (std.mem.eql(u8, record.key, key)) {
                _ = self._records.orderedRemove(i);
                return exec.js.local.?.resolvePromise(true);
            }
        }
        return exec.js.local.?.resolvePromise(false);
    }

    // add() and addAll() are "fetch it, then put it". This engine's fetch hands
    // back a JS promise with no way to hang a Zig continuation off it, so
    // nothing can be fetched and stored from here. Chrome's answer when the
    // fetch does not come back is a plain TypeError, which is what a script
    // gets here for every URL -- including ones Chrome would have fetched. It
    // is the one place in this file where a script can tell the two apart.
    fn addFailed(comptime method: []const u8, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{
            .type_error = "Failed to execute '" ++ method ++ "' on 'Cache': Request failed",
        });
    }

    pub fn add(_: *Cache, input_: ?Request.Input, exec: *const Execution) !js.Promise {
        _ = input_ orelse return missingArgument("add", "Cache", exec);
        return addFailed("add", exec);
    }

    pub fn addAll(_: *Cache, requests_: ?[]const Request.Input, exec: *const Execution) !js.Promise {
        _ = requests_ orelse return missingArgument("addAll", "Cache", exec);
        return addFailed("addAll", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Cache);

        pub const Meta = struct {
            pub const name = "Cache";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order.
        pub const add = bridge.function(Cache.add, .{ .arity = 1 });
        pub const addAll = bridge.function(Cache.addAll, .{ .arity = 1 });
        pub const delete = bridge.function(Cache.delete, .{ .arity = 1 });
        pub const keys = bridge.function(Cache.keys, .{});
        pub const match = bridge.function(Cache.match, .{ .arity = 1 });
        pub const matchAll = bridge.function(Cache.matchAll, .{});
        pub const put = bridge.function(Cache.put, .{ .arity = 2 });
    };
};

// WebIDL's missing-argument TypeError, worded the way Chrome words it. These
// are rejections, not synchronous throws: measured, every one of these
// operations hands back a promise first and rejects it.
fn missingArgument(comptime method: []const u8, comptime iface: []const u8, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{
        .type_error = "Failed to execute '" ++ method ++ "' on '" ++ iface ++
            "': 1 argument required, but only 0 present.",
    });
}

fn missingPutArgument(comptime present: []const u8, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{
        .type_error = "Failed to execute 'put' on 'Cache': 2 arguments required, but only " ++
            present ++ " present.",
    });
}
