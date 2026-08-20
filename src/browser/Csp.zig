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

//! Content-Security-Policy, as far as `script-src` goes.
//!
//! The engine used to ignore page CSP entirely, and that is *itself* a
//! detectable behaviour rather than a missing feature: rebrowser's bot detector
//! appends a `<script src>` to a host its own policy does not list and watches
//! which of onload/onerror fires. A real browser fires onerror; ignoring the
//! policy fires onload, which rebrowser reports in as many words — "Content
//! Security Policy (CSP) was ignored, you might use Page.setBypassCSP
//! (Puppeteer) or bypassCSP: true (Playwright). It's invalid behavior for a
//! normal browser."
//!
//! Scope, deliberately narrow and stated rather than implied:
//!
//! * Only `script-src` (falling back to `default-src`) is enforced, and only
//!   for *external* script loads. Inline-script and eval blocking are not here:
//!   they need the nonce/hash machinery to avoid breaking pages that legitimately
//!   carry `'unsafe-inline'`, and no detector this fork chases probes them.
//! * `style-src`, `img-src`, `connect-src`, `frame-ancestors`, `report-uri` and
//!   the rest are parsed past and ignored.
//! * Source expressions understood: `*`, `'none'`, `'self'`, scheme-sources
//!   (`https:`, `blob:`, `data:`), and host-sources with an optional scheme, a
//!   leading `*.` wildcard, and an optional port or `:*`. A host-source's path
//!   is ignored, so a policy that allows one path of a host allows all of it —
//!   more permissive than the spec, never less, so it cannot break a page.
//! * `'nonce-…'` matches a script element carrying that exact nonce, whatever
//!   its URL — which is what the spec says and is not an inline-only rule. An
//!   earlier revision of this file claimed the opposite ("nonces never match a
//!   URL, correct: they apply to inline scripts") and that cost us every
//!   Cloudflare managed challenge: the interstitial sends
//!   `script-src 'nonce-…' 'unsafe-eval' https://challenges.cloudflare.com`
//!   with no `'self'`, then injects its own loader with `a.nonce` set on the
//!   element, so the nonce is the only source expression admitting that
//!   same-origin URL. Refusing it left the engine on `Just a moment...` forever
//!   (`tools/fingerprint/results/antibot-2026-08-20-vs-chrome.md`).
//! * `'sha256-…'` still never matches a URL: a hash is over a script's body,
//!   and nothing here hashes a response to check it.
//! * `'strict-dynamic'` is ignored rather than honoured. Honouring it would
//!   allow every script inserted by another script, which is exactly the load
//!   rebrowser tests, so ignoring it is the strict reading. A nonce is narrower
//!   than that on purpose: it admits the one element the page put a secret on,
//!   not everything that element goes on to insert.
//!
//! Multiple policies are conjunctive per spec: a URL has to satisfy every one.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Csp = @This();

_policies: []const Policy,

pub const empty = Csp{ ._policies = &.{} };

pub const Policy = struct {
    // Source expressions exactly as written, case preserved. A nonce is
    // base64 and compared exactly, so lower-casing them here -- which this
    // parser used to do -- silently breaks every mixed-case nonce; the keyword,
    // scheme and host comparisons fold case themselves instead. Null means the
    // directive was absent from this policy.
    script_src: ?[]const []const u8 = null,
    default_src: ?[]const []const u8 = null,
};

/// Parses one policy string — the value of one `Content-Security-Policy` header
/// or of one `<meta http-equiv>`. A header may carry several policies separated
/// by commas; `parseInto` handles that, this handles a single one.
pub fn parsePolicy(allocator: Allocator, text: []const u8) !Policy {
    var policy = Policy{};

    var directives = std.mem.splitScalar(u8, text, ';');
    while (directives.next()) |raw| {
        const directive = std.mem.trim(u8, raw, " \t\r\n");
        if (directive.len == 0) {
            continue;
        }

        var parts = std.mem.tokenizeAny(u8, directive, " \t\r\n");
        const name = parts.next() orelse continue;

        const field: enum { script_src, default_src, other } = blk: {
            if (std.ascii.eqlIgnoreCase(name, "script-src")) break :blk .script_src;
            if (std.ascii.eqlIgnoreCase(name, "default-src")) break :blk .default_src;
            break :blk .other;
        };
        if (field == .other) {
            continue;
        }

        var sources: std.ArrayList([]const u8) = .empty;
        while (parts.next()) |source| {
            try sources.append(allocator, try allocator.dupe(u8, source));
        }
        const owned = try sources.toOwnedSlice(allocator);

        // A repeated directive is ignored per spec: the first one wins.
        switch (field) {
            .script_src => if (policy.script_src == null) {
                policy.script_src = owned;
            },
            .default_src => if (policy.default_src == null) {
                policy.default_src = owned;
            },
            .other => unreachable,
        }
    }

    return policy;
}

/// Appends every policy in one header value or meta content. A header value can
/// carry several policies, comma-separated.
pub fn parseInto(allocator: Allocator, into: *std.ArrayList(Policy), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |one| {
        if (std.mem.trim(u8, one, " \t\r\n").len == 0) {
            continue;
        }
        try into.append(allocator, try parsePolicy(allocator, one));
    }
}

pub fn init(policies: []const Policy) Csp {
    return .{ ._policies = policies };
}

pub fn isEmpty(self: *const Csp) bool {
    return self._policies.len == 0;
}

/// Would a real browser fetch `url` for a `<script src>` in a document served
/// from `document_url`? Every policy has to say yes.
///
/// `nonce` is the element's `nonce` content attribute, or null when it carries
/// none. A policy listing a matching `'nonce-…'` is satisfied whatever the URL
/// says, which is how a page admits one script it trusts without opening its
/// origin -- and how Cloudflare's interstitial loads its own challenge.
pub fn allowsScript(self: *const Csp, url: []const u8, document_url: []const u8, nonce: ?[]const u8) bool {
    for (self._policies) |policy| {
        const sources = policy.script_src orelse policy.default_src orelse continue;
        if (nonceMatches(sources, nonce)) {
            continue;
        }
        if (!anySourceMatches(sources, url, document_url)) {
            return false;
        }
    }
    return true;
}

/// Does this source list carry a `'nonce-…'` equal to the element's nonce?
///
/// The `nonce-` keyword folds case; the value after it does not. It is base64
/// and the spec compares it exactly, so `'nonce-ABC'` must not admit an element
/// claiming `abc` -- a fold there would turn a secret into a guess.
fn nonceMatches(sources: []const []const u8, nonce: ?[]const u8) bool {
    const have = nonce orelse return false;
    if (have.len == 0) {
        return false;
    }
    for (sources) |source| {
        // The shortest possible form is 'nonce-x': two quotes, the keyword, and
        // at least one character of value.
        if (source.len < 9 or source[0] != '\'' or source[source.len - 1] != '\'') {
            continue;
        }
        const inner = source[1 .. source.len - 1];
        if (!std.ascii.startsWithIgnoreCase(inner, "nonce-")) {
            continue;
        }
        if (std.mem.eql(u8, inner["nonce-".len..], have)) {
            return true;
        }
    }
    return false;
}

fn anySourceMatches(sources: []const []const u8, url: []const u8, document_url: []const u8) bool {
    for (sources) |source| {
        if (sourceMatches(source, url, document_url)) {
            return true;
        }
    }
    return false;
}

fn sourceMatches(source: []const u8, url: []const u8, document_url: []const u8) bool {
    if (source.len == 0) {
        return false;
    }

    // Keyword sources. Only 'self' says anything about a URL; 'none' says no,
    // and the rest ('unsafe-inline', 'unsafe-eval', 'strict-dynamic', hashes)
    // are about inline script or are deliberately not honoured. A nonce is
    // handled before this, against the element rather than the URL.
    if (source[0] == '\'') {
        if (std.ascii.eqlIgnoreCase(source, "'self'")) {
            return sameOrigin(url, document_url);
        }
        return false;
    }

    if (std.mem.eql(u8, source, "*")) {
        return true;
    }

    // A scheme-source is a bare "scheme:" with nothing after it.
    if (source[source.len - 1] == ':' and std.mem.indexOfScalar(u8, source, '/') == null) {
        return schemeOf(url) != null and std.ascii.eqlIgnoreCase(schemeOf(url).?, source[0 .. source.len - 1]);
    }

    return hostSourceMatches(source, url);
}

const Parts = struct {
    scheme: []const u8,
    host: []const u8,
    port: []const u8,
};

fn schemeOf(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    // A scheme can only be alphanumerics plus +-. and must start with a letter.
    if (colon == 0 or !std.ascii.isAlphabetic(url[0])) {
        return null;
    }
    return url[0..colon];
}

/// Splits an absolute URL into the three pieces CSP matching needs. Returns null
/// for anything that is not `scheme://…`, which covers the schemes that carry no
/// authority (`data:`, `javascript:`) — those only ever match a scheme-source.
fn split(url: []const u8) ?Parts {
    const scheme = schemeOf(url) orelse return null;
    const after = url[scheme.len + 1 ..];
    if (!std.mem.startsWith(u8, after, "//")) {
        return null;
    }
    var authority = after[2..];
    if (std.mem.indexOfAny(u8, authority, "/?#")) |end| {
        authority = authority[0..end];
    }
    // Userinfo is not part of the origin.
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        authority = authority[at + 1 ..];
    }
    // A bracketed IPv6 host may contain colons that are not the port separator.
    const port_sep = if (authority.len > 0 and authority[0] == '[')
        (if (std.mem.indexOfScalar(u8, authority, ']')) |close| std.mem.indexOfScalarPos(u8, authority, close, ':') else null)
    else
        std.mem.lastIndexOfScalar(u8, authority, ':');

    if (port_sep) |sep| {
        return .{ .scheme = scheme, .host = authority[0..sep], .port = authority[sep + 1 ..] };
    }
    return .{ .scheme = scheme, .host = authority, .port = "" };
}

fn defaultPort(scheme: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return "443";
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return "80";
    if (std.ascii.eqlIgnoreCase(scheme, "ws")) return "80";
    if (std.ascii.eqlIgnoreCase(scheme, "wss")) return "443";
    return "";
}

fn effectivePort(parts: Parts) []const u8 {
    return if (parts.port.len > 0) parts.port else defaultPort(parts.scheme);
}

fn sameOrigin(a: []const u8, b: []const u8) bool {
    const pa = split(a) orelse return false;
    const pb = split(b) orelse return false;
    return std.ascii.eqlIgnoreCase(pa.scheme, pb.scheme) and
        std.ascii.eqlIgnoreCase(pa.host, pb.host) and
        std.mem.eql(u8, effectivePort(pa), effectivePort(pb));
}

fn hostSourceMatches(source: []const u8, url: []const u8) bool {
    const target = split(url) orelse return false;

    // The source may or may not carry a scheme. Without one, http upgrades to
    // https are allowed but not the reverse, which is what browsers do.
    var rest = source;
    var source_scheme: ?[]const u8 = null;
    if (std.mem.indexOf(u8, source, "://")) |sep| {
        source_scheme = source[0..sep];
        rest = source[sep + 3 ..];
    }
    if (source_scheme) |scheme| {
        if (!std.ascii.eqlIgnoreCase(scheme, target.scheme)) {
            return false;
        }
    } else if (std.ascii.eqlIgnoreCase(target.scheme, "http") == false and
        std.ascii.eqlIgnoreCase(target.scheme, "https") == false and
        std.ascii.eqlIgnoreCase(target.scheme, "ws") == false and
        std.ascii.eqlIgnoreCase(target.scheme, "wss") == false)
    {
        // A schemeless host-source only ever matches the network schemes.
        return false;
    }

    // Drop the path: see the scope note at the top.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |end| {
        rest = rest[0..end];
    }

    var source_port: []const u8 = "";
    var host = rest;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |sep| {
        host = rest[0..sep];
        source_port = rest[sep + 1 ..];
    }

    if (host.len == 0) {
        return false;
    }
    if (std.mem.eql(u8, host, "*")) {
        // "*:port" — host is anything, the port still has to line up.
    } else if (std.mem.startsWith(u8, host, "*.")) {
        const suffix = host[1..]; // keeps the leading dot
        if (!std.ascii.endsWithIgnoreCase(target.host, suffix)) {
            return false;
        }
    } else if (!std.ascii.eqlIgnoreCase(host, target.host)) {
        return false;
    }

    if (source_port.len == 0) {
        // No port in the source: the target has to be on the scheme's default.
        const scheme = source_scheme orelse target.scheme;
        return std.mem.eql(u8, effectivePort(target), defaultPort(scheme));
    }
    if (std.mem.eql(u8, source_port, "*")) {
        return true;
    }
    return std.mem.eql(u8, source_port, effectivePort(target));
}

const testing = @import("../testing.zig");

test "Csp: absent directive allows everything" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var policies: std.ArrayList(Policy) = .empty;
    try Csp.parseInto(a, &policies, "img-src 'self'; report-uri /r");
    const csp = Csp.init(policies.items);
    try testing.expectEqual(true, csp.allowsScript("https://cdn.example.com/x.js", "https://site.test/", null));
}

test "Csp: rebrowser's own policy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Verbatim from bot-detector.rebrowser.net's <meta http-equiv>.
    var policies: std.ArrayList(Policy) = .empty;
    try Csp.parseInto(a, &policies, "default-src * data: 'unsafe-eval' 'unsafe-inline' blob:; script-src blob: 'self' 'unsafe-eval' 'unsafe-inline' https://static.cloudflareinsights.com https://cloudflareinsights.com;");
    const csp = Csp.init(policies.items);

    const doc = "https://bot-detector.rebrowser.net/";
    // The script the bypassCsp test appends: not listed, so blocked.
    try testing.expectEqual(false, csp.allowsScript("https://www.w3schools.com/js/myScript.js", doc, null));
    // Its own scripts, and the two hosts it does list.
    try testing.expectEqual(true, csp.allowsScript("https://bot-detector.rebrowser.net/index.js?2", doc, null));
    try testing.expectEqual(true, csp.allowsScript("https://static.cloudflareinsights.com/beacon.js", doc, null));
    try testing.expectEqual(true, csp.allowsScript("blob:https://bot-detector.rebrowser.net/abc", doc, null));
    // default-src's `*` does not rescue it: script-src overrides default-src.
    try testing.expectEqual(false, csp.allowsScript("https://evil.test/x.js", doc, null));
}

test "Csp: source expressions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = "https://site.test/page";
    const cases = .{
        .{ "script-src 'none'", "https://site.test/a.js", false },
        .{ "script-src 'self'", "https://site.test/a.js", true },
        .{ "script-src 'self'", "https://other.test/a.js", false },
        .{ "script-src 'self'", "https://site.test:8443/a.js", false },
        .{ "script-src *", "https://anything.test/a.js", true },
        .{ "script-src https:", "https://anything.test/a.js", true },
        .{ "script-src https:", "http://anything.test/a.js", false },
        .{ "script-src *.example.com", "https://cdn.example.com/a.js", true },
        .{ "script-src *.example.com", "https://example.com/a.js", false },
        .{ "script-src *.example.com", "https://cdn.example.com.evil.test/a.js", false },
        .{ "script-src example.com", "https://example.com/a.js", true },
        .{ "script-src example.com", "https://example.com:8443/a.js", false },
        .{ "script-src example.com:*", "https://example.com:8443/a.js", true },
        .{ "script-src example.com:8443", "https://example.com:8443/a.js", true },
        .{ "script-src http://example.com", "https://example.com/a.js", false },
        // A path in a host-source is ignored: more permissive, never less.
        .{ "script-src example.com/only/here", "https://example.com/elsewhere.js", true },
        // Nonces and hashes are about inline script and never match a URL.
        .{ "script-src 'nonce-abc123'", "https://site.test/a.js", false },
        .{ "script-src 'sha256-abc'", "https://site.test/a.js", false },
        // strict-dynamic is deliberately not honoured.
        .{ "script-src 'strict-dynamic' 'nonce-abc'", "https://site.test/a.js", false },
        // default-src is the fallback when script-src is absent.
        .{ "default-src 'self'", "https://site.test/a.js", true },
        .{ "default-src 'self'", "https://other.test/a.js", false },
        // data: and blob: only ever match a scheme-source.
        .{ "script-src blob:", "blob:https://site.test/x", true },
        .{ "script-src 'self'", "data:text/javascript,1", false },
        .{ "script-src data:", "data:text/javascript,1", true },
    };

    inline for (cases) |case| {
        var policies: std.ArrayList(Policy) = .empty;
        try Csp.parseInto(a, &policies, case[0]);
        const csp = Csp.init(policies.items);
        testing.expectEqual(case[2], csp.allowsScript(case[1], doc, null)) catch |err| {
            std.debug.print("csp case failed: \"{s}\" vs {s}\n", .{ case[0], case[1] });
            return err;
        };
    }
}

test "Csp: a nonce admits the element carrying it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = "https://site.test/page";
    // Cloudflare's interstitial policy, verbatim apart from the random value.
    const cf = "script-src 'nonce-v4r3E9xWYvR93f3o09vl4E' 'unsafe-eval' https://challenges.cloudflare.com";
    const cases = .{
        // The load that was being refused: same-origin, no 'self' in the
        // policy, the nonce set on the element.
        .{ cf, "https://site.test/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1?ray=a", "v4r3E9xWYvR93f3o09vl4E", true },
        // Without the nonce the same URL is still refused, so honouring one is
        // not the same as ignoring the policy -- rebrowser's bypassCsp row
        // cannot regress into a pass through here.
        .{ cf, "https://site.test/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1?ray=a", null, false },
        // Exact comparison: base64 is case-sensitive, and a fold would turn the
        // secret into a guess. This is the case the old parser could not have
        // passed even with the matching in place, because it lower-cased every
        // source expression as it read it.
        .{ cf, "https://site.test/a.js", "v4r3e9xwyvr93f3o09vl4e", false },
        .{ cf, "https://site.test/a.js", "not-the-nonce", false },
        .{ cf, "https://site.test/a.js", "", false },
        // A host the policy does list needs no nonce.
        .{ cf, "https://challenges.cloudflare.com/turnstile/v0/api.js", null, true },
        // The keyword folds even though the value does not.
        .{ "script-src 'NONCE-abc123'", "https://other.test/a.js", "abc123", true },
        // A nonce satisfies the policy it appears in, and only that one. Both
        // must be satisfied, and the second names no nonce.
        .{ "script-src 'nonce-abc', script-src 'self'", "https://other.test/a.js", "abc", false },
        .{ "script-src 'nonce-abc', script-src 'self'", "https://site.test/a.js", "abc", true },
        // 'strict-dynamic' is still not honoured: the nonce admits the element
        // that carries it, not whatever that element goes on to insert.
        .{ "script-src 'strict-dynamic' 'nonce-abc'", "https://site.test/a.js", null, false },
        // A hash is over a body nothing here reads, so it still matches no URL.
        .{ "script-src 'sha256-abc'", "https://site.test/a.js", "abc", false },
        // default-src carries a nonce the same way script-src does.
        .{ "default-src 'nonce-abc'", "https://other.test/a.js", "abc", true },
    };

    inline for (cases) |case| {
        var policies: std.ArrayList(Policy) = .empty;
        try Csp.parseInto(a, &policies, case[0]);
        const csp = Csp.init(policies.items);
        // Annotated rather than inferred: a bare `null` in the table has type
        // @TypeOf(null), which neither coerces at the call nor formats as {?s}.
        const nonce: ?[]const u8 = case[2];
        testing.expectEqual(case[3], csp.allowsScript(case[1], doc, nonce)) catch |err| {
            std.debug.print("csp nonce case failed: \"{s}\" vs {s} nonce={?s}\n", .{ case[0], case[1], nonce });
            return err;
        };
    }
}

test "Csp: policies are conjunctive" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = "https://site.test/";
    var policies: std.ArrayList(Policy) = .empty;
    // Two policies in one header value, comma-separated.
    try Csp.parseInto(a, &policies, "script-src *, script-src 'self'");
    try testing.expectEqual(2, policies.items.len);
    const csp = Csp.init(policies.items);
    try testing.expectEqual(true, csp.allowsScript("https://site.test/a.js", doc, null));
    try testing.expectEqual(false, csp.allowsScript("https://cdn.test/a.js", doc, null));
}

test "WebApi: CSP script-src" {
    try testing.htmlRunner("csp.html", .{});
}

test "WebApi: CSP nonce" {
    try testing.htmlRunner("csp_nonce.html", .{});
}
