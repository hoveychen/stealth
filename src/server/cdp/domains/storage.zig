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

const CDP = @import("../CDP.zig");
const URL = @import("../../../browser/URL.zig");
const Cookie = @import("../../../browser/webapi/storage/storage.zig").Cookie;

const log = lp.log;
const CookieJar = Cookie.Jar;
pub const PreparedUri = Cookie.PreparedUri;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        clearCookies,
        setCookies,
        getCookies,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .clearCookies => return clearCookies(cmd),
        .getCookies => return getCookies(cmd),
        .setCookies => return setCookies(cmd),
    }
}

const BrowserContextParam = struct { browserContextId: ?[]const u8 = null };

fn clearCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(BrowserContextParam)) orelse BrowserContextParam{};

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    bc.session.cookie_jar.clearRetainingCapacity();

    return cmd.sendResult(null, .{});
}

fn getCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(BrowserContextParam)) orelse BrowserContextParam{};

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }
    bc.session.cookie_jar.removeExpired(null);
    const writer = CookieWriter{ .cookies = bc.session.cookie_jar.cookies.items };
    try cmd.sendResult(.{ .cookies = writer }, .{});
}

fn setCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        cookies: []const CdpCookie,
        browserContextId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    for (params.cookies) |param| {
        try setCdpCookie(&bc.session.cookie_jar, param);
    }

    try cmd.sendResult(null, .{});
}

pub const SameSite = enum {
    Strict,
    Lax,
    None,
};
pub const CookiePriority = enum {
    Low,
    Medium,
    High,
};
pub const CookieSourceScheme = enum {
    Unset,
    NonSecure,
    Secure,
};

pub const CookiePartitionKey = struct {
    topLevelSite: []const u8,
    hasCrossSiteAncestor: bool,
};

pub const CdpCookie = struct {
    name: []const u8,
    value: []const u8,
    url: ?[:0]const u8 = null,
    domain: ?[]const u8 = null,
    path: ?[:0]const u8 = null,
    secure: ?bool = null, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    httpOnly: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    // Absent means the client said nothing about SameSite, which is not the
    // same thing as saying None: the cookie then behaves as Lax (Chrome's
    // SameSite-by-default) and reports no attribute at all.
    sameSite: ?SameSite = null,
    expires: ?f64 = null, // -1? says google
    priority: CookiePriority = .Medium, // default: https://datatracker.ietf.org/doc/html/draft-west-cookie-priority-00
    sameParty: ?bool = null,
    sourceScheme: ?CookieSourceScheme = null,
    // sourcePort: Temporary ability and it will be removed from CDP
    partitionKey: ?CookiePartitionKey = null,
};

pub fn setCdpCookie(cookie_jar: *CookieJar, param: CdpCookie) !void {
    // Silently ignore partitionKey since we don't support partitioned cookies (CHIPS).
    // This allows Puppeteer's frame.setCookie() to work, which may send cookies with
    // partitionKey as part of its cookie-setting workflow.
    if (param.partitionKey != null) {
        log.warn(.not_implemented, "partition key", .{ .src = "setCdpCookie" });
    }
    // Still reject unsupported features
    if (param.priority != .Medium or param.sameParty != null or param.sourceScheme != null) {
        return error.NotImplemented;
    }

    // The errdefer only protects construction failures. Once we `break :blk`
    // with the Cookie value, `Jar.add` owns its lifetime.
    const cookie = blk: {
        var arena = std.heap.ArenaAllocator.init(cookie_jar.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        // NOTE: The param.url can affect the default domain, (NOT path), secure, source port, and source scheme.
        const domain = try Cookie.parseDomain(a, param.url, param.domain);
        const path = if (param.path == null) "/" else try Cookie.parsePath(a, null, param.path);

        const secure = if (param.secure) |s| s else if (param.url) |url| URL.isSecure(url) else false;

        break :blk Cookie{
            .arena = arena,
            .name = try a.dupe(u8, param.name),
            .value = try a.dupe(u8, param.value),
            .path = path,
            .domain = domain,
            .expires = param.expires,
            .secure = secure,
            .http_only = param.httpOnly,
            .same_site = if (param.sameSite) |same_site| switch (same_site) {
                .Strict => .strict,
                .Lax => .lax,
                .None => .none,
            } else .lax,
            .same_site_explicit = param.sameSite != null,
        };
    };
    try cookie_jar.add(cookie, lp.datetime.timestamp(.real), true);
}

pub const CookieWriter = struct {
    cookies: []const Cookie,
    urls: ?[]const PreparedUri = null,

    pub fn jsonStringify(self: *const CookieWriter, w: anytype) !void {
        self.writeCookies(w) catch |err| {
            // The only error our jsonStringify method can return is @TypeOf(w).Error.
            log.err(.cdp, "json stringify", .{ .err = err });
            return error.WriteFailed;
        };
    }

    fn writeCookies(self: CookieWriter, w: anytype) !void {
        try w.beginArray();
        if (self.urls) |urls| {
            for (self.cookies) |*cookie| {
                for (urls) |*url| {
                    if (cookie.appliesTo(url, true, true, true)) { // TBD same_site, should we compare to the pages url?
                        try writeCookie(cookie, w);
                        break;
                    }
                }
            }
        } else {
            for (self.cookies) |*cookie| {
                try writeCookie(cookie, w);
            }
        }
        try w.endArray();
    }
};
pub fn writeCookie(cookie: *const Cookie, w: anytype) !void {
    try w.beginObject();
    {
        try w.objectField("name");
        try w.write(cookie.name);

        try w.objectField("value");
        try w.write(cookie.value);

        try w.objectField("domain");
        try w.write(cookie.domain); // Should we hide a leading dot?

        try w.objectField("path");
        try w.write(cookie.path);

        try w.objectField("expires");
        try w.write(cookie.expires orelse -1);

        try w.objectField("size");
        try w.write(cookie.name.len + cookie.value.len);

        try w.objectField("httpOnly");
        try w.write(cookie.http_only);

        try w.objectField("secure");
        try w.write(cookie.secure);

        try w.objectField("session");
        try w.write(cookie.expires == null);

        // A cookie that never carried the attribute has no `sameSite` to
        // report -- its Lax behaviour is a default, not something the cookie
        // says about itself, and Chrome leaves the key out.
        if (cookie.same_site_explicit) {
            try w.objectField("sameSite");
            switch (cookie.same_site) {
                .none => try w.write("None"),
                .lax => try w.write("Lax"),
                .strict => try w.write("Strict"),
            }
        }

        // TODO experimentals
    }
    try w.endObject();
}

const testing = @import("../testing.zig");

test "cdp.Storage: cookies" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-S" });

    // Initially empty
    try ctx.processMessage(.{
        .id = 3,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 3 });

    // Has cookies after setting them
    try ctx.processMessage(.{
        .id = 4,
        .method = "Storage.setCookies",
        .params = .{
            .cookies = &[_]CdpCookie{
                .{ .name = "test", .value = "value", .domain = "example.com", .path = "/mango" },
                .{ .name = "test2", .value = "value2", .url = "https://car.example.com/pancakes" },
                .{ .name = "test3", .value = "value3", .domain = "gov.uk" },
            },
            .browserContextId = "BID-S",
        },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ctx.processMessage(.{
        .id = 5,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "test", .value = "value", .domain = ".example.com", .path = "/mango", .size = 9 },
            .{ .name = "test2", .value = "value2", .domain = "car.example.com", .path = "/", .size = 11, .secure = true }, // No Pancakes!
            .{ .name = "test3", .value = "value3", .domain = "gov.uk", .path = "/", .size = 11 },
        },
    }, .{ .id = 5 });

    // Empty after clearing cookies
    try ctx.processMessage(.{
        .id = 6,
        .method = "Storage.clearCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(null, .{ .id = 6 });
    try ctx.processMessage(.{
        .id = 7,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 7 });
}

pub const ResCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    expires: f64 = -1,
    size: usize = 0,
    httpOnly: bool = false,
    secure: bool = false,
    // Absent unless a test names it: a cookie that never carried a SameSite
    // attribute doesn't get the key at all, so "None" is the wrong default
    // to hold every other cookie test to.
    sameSite: ?[]const u8 = null,
};

// `expectSentResult` is a subset match, so it can say what a key holds but
// never that the key is missing. Absence has to be read off the parsed
// message, the way `sentBytesFor` in network.zig reads byte counts.
fn sentCookie(ctx: anytype, id: i64, name: []const u8) !std.json.ObjectMap {
    for (ctx.received.items) |msg| {
        const obj = msg.object;
        const msg_id = obj.get("id") orelse continue;
        if (msg_id != .integer or msg_id.integer != id) continue;
        const result = (obj.get("result") orelse continue).object;
        for ((result.get("cookies") orelse continue).array.items) |cookie| {
            const cookie_name = (cookie.object.get("name") orelse continue).string;
            if (std.mem.eql(u8, cookie_name, name)) {
                return cookie.object;
            }
        }
    }
    return error.CookieNotFound;
}

// Chrome reports `sameSite` as an absent property when the cookie never
// carried a SameSite attribute. The Lax default lives in the sending
// behaviour, not in what CDP says the cookie has. Measured on
// scrapingcourse.com: the server-set `AWSALB` arrives with no attribute and
// Chrome's Network.getAllCookies omits the key, while we reported "Lax".
test "cdp.Storage: sameSite absent when it was never specified" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-SS" });

    // The way a server sets one: a Set-Cookie header with no SameSite.
    const jar = &bc.session.cookie_jar;
    try jar.add(
        try Cookie.parse(jar.allocator, "https://example.com/", "header=1"),
        lp.datetime.timestamp(.real),
        true,
    );

    try ctx.processMessage(.{
        .id = 1,
        .method = "Storage.setCookies",
        .params = .{
            .cookies = &[_]CdpCookie{
                .{ .name = "implicit", .value = "2", .url = "https://example.com/" },
                .{ .name = "explicit", .value = "3", .url = "https://example.com/", .sameSite = .Strict },
            },
            .browserContextId = "BID-SS",
        },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-SS" },
    });
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "header", .value = "1", .domain = "example.com", .size = 7 },
            .{ .name = "implicit", .value = "2", .domain = "example.com", .size = 9, .secure = true },
            .{ .name = "explicit", .value = "3", .domain = "example.com", .size = 9, .secure = true, .sameSite = "Strict" },
        },
    }, .{ .id = 2 });

    try std.testing.expect((try sentCookie(&ctx, 2, "header")).get("sameSite") == null);
    try std.testing.expect((try sentCookie(&ctx, 2, "implicit")).get("sameSite") == null);
    try std.testing.expectEqualStrings("Strict", (try sentCookie(&ctx, 2, "explicit")).get("sameSite").?.string);
}
