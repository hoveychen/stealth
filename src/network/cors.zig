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

// The pieces of the Fetch spec's CORS protocol that more than one caller
// needs: what makes a request header "safelisted" (i.e. does not by itself
// force a preflight), and how an `Access-Control-Allow-*` answer is read.
//
// EventSource had the Allow-Origin half to itself for its WPTs; PreflightGate
// needs the same check against a preflight's answer, so it lives here rather
// than being written twice.

const std = @import("std");

// The three Content-Type values that ride along without a preflight. Anything
// else -- application/json above all, which is what x-hyatt's reporting POST
// carries -- makes the request non-simple.
pub const safelisted_content_types = [_][]const u8{
    "application/x-www-form-urlencoded",
    "multipart/form-data",
    "text/plain",
};

// https://fetch.spec.whatwg.org/#cors-safelisted-request-header
//
// A header the page set that is NOT safelisted forces a preflight and has to
// be named in Access-Control-Request-Headers. The value matters for two of
// them: `content-type` is only safe for the three essences above, and `range`
// only for a plain `bytes=` range.
pub fn isSafelistedRequestHeader(name: []const u8, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "accept")) return true;
    if (std.ascii.eqlIgnoreCase(name, "accept-language")) return true;
    if (std.ascii.eqlIgnoreCase(name, "content-language")) return true;
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        const essence = contentTypeEssence(value);
        for (safelisted_content_types) |safe| {
            if (std.ascii.eqlIgnoreCase(essence, safe)) return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(name, "range")) return isSimpleRange(value);
    return false;
}

// The type/subtype in front of the first `;`, trimmed. `application/json;
// charset=UTF-8` and `application/json` are the same essence, and the
// parameters never make an unsafe type safe.
fn contentTypeEssence(value: []const u8) []const u8 {
    const head = if (std.mem.indexOfScalar(u8, value, ';')) |i| value[0..i] else value;
    return std.mem.trim(u8, head, " \t");
}

// `bytes=<first>-<last?>` with both bounds decimal and no multipart ranges.
fn isSimpleRange(value: []const u8) bool {
    const prefix = "bytes=";
    if (!std.ascii.startsWithIgnoreCase(value, prefix)) return false;
    const spec = value[prefix.len..];
    if (spec.len == 0) return false;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return false;
    const first = spec[0..dash];
    const last = spec[dash + 1 ..];
    if (first.len == 0) return false;
    for (first) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    for (last) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

// Does an `Access-Control-Allow-Origin` (plus, for a credentialed request, an
// `Access-Control-Allow-Credentials`) let this origin read the response?
//
// The wildcard is not valid for a credentialed request -- that is the whole
// point of the pair -- and a missing Allow-Origin is a refusal, not a default.
pub fn originAllowed(
    allow_origin: ?[]const u8,
    allow_credentials: ?[]const u8,
    origin: []const u8,
    with_credentials: bool,
) bool {
    const allowed = allow_origin orelse return false;
    if (std.mem.eql(u8, allowed, "*")) {
        return !with_credentials;
    }
    if (!std.mem.eql(u8, allowed, origin)) {
        return false;
    }
    if (with_credentials) {
        const creds = allow_credentials orelse return false;
        return std.ascii.eqlIgnoreCase(creds, "true");
    }
    return true;
}

// Is `needle` in a comma-separated `Access-Control-Allow-{Methods,Headers}`
// list? The wildcard stands for "anything", but only for an uncredentialed
// request, same as it does for Allow-Origin.
//
// Method names are compared case-insensitively. The spec asks for a
// byte-for-byte match on methods and only case-folds header names, but a
// server answering `Access-Control-Allow-Methods: put` is answering about PUT,
// and refusing the request over its casing would block a request Chrome sends.
pub fn listAllows(
    header_value: ?[]const u8,
    needle: []const u8,
    with_credentials: bool,
) bool {
    const value = header_value orelse return false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*") and !with_credentials) return true;
        if (std.ascii.eqlIgnoreCase(entry, needle)) return true;
    }
    return false;
}

// Does this cross-origin response say the page may read it? Takes the header
// iterator rather than the transfer so this file stays independent of
// HttpClient, which reaches PreflightGate and would close a cycle.
//
// Pass the iterator by pointer: `anytype` here is
// `HttpClient.Transfer.ResponseHeaderIterator`, which advances as it is read.
pub fn responseAllowed(header_iterator: anytype, origin: []const u8, with_credentials: bool) bool {
    var allow_origin: ?[]const u8 = null;
    var allow_credentials: ?[]const u8 = null;
    while (header_iterator.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
            allow_origin = hdr.value;
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-credentials")) {
            allow_credentials = hdr.value;
        }
    }
    return originAllowed(allow_origin, allow_credentials, origin, with_credentials);
}

// https://fetch.spec.whatwg.org/#cors-safelisted-response-header-name -- the
// seven names an allowed cross-origin response shows without being asked. Every
// other name needs Access-Control-Expose-Headers, which is why a page that can
// read a cross-origin body still cannot read its `x-request-id`.
pub const safelisted_response_headers = [_][]const u8{
    "cache-control",
    "content-language",
    "content-length",
    "content-type",
    "expires",
    "last-modified",
    "pragma",
};

// May the page see this header on an allowed cross-origin response? Measured on
// Chrome 151: `x-custom` reads back null without Expose-Headers and "1" with it,
// while `content-type` reads back either way (the `expose-headers-*` pair of
// tools/fingerprint/results/b60-cors-chrome.json).
//
// The wildcard stands for every name, and -- like the one in Allow-Origin --
// only for an uncredentialed request.
pub fn responseHeaderExposed(name: []const u8, expose_headers: ?[]const u8, with_credentials: bool) bool {
    for (safelisted_response_headers) |safe| {
        if (std.ascii.eqlIgnoreCase(name, safe)) return true;
    }
    return listAllows(expose_headers, name, with_credentials);
}

// https://fetch.spec.whatwg.org/#cors-safelisted-method -- these three never
// need to appear in Access-Control-Allow-Methods. Measured on Chrome 151: a
// preflight answering `Access-Control-Allow-Methods: GET` still lets the POST
// through, and only the PUT beside it is refused (the `unlisted-post` /
// `unlisted-put` pair of tools/fingerprint/results/b57-cors-chrome.json).
pub fn isSafelistedMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "POST");
}

const testing = @import("../testing.zig");

// The request half lives with PreflightGate, which owns the preflight. This is
// the response half: what a cross-origin response has to say before the page may
// read it, and which of its headers show through when it does.
test "WebApi: CORS response check" {
    try testing.htmlRunner("net/cors_response.html", .{});
}

test "cors: safelisted request headers" {
    try testing.expect(isSafelistedRequestHeader("Accept", "*/*"));
    try testing.expect(isSafelistedRequestHeader("accept-language", "en"));
    try testing.expect(isSafelistedRequestHeader("Content-Language", "en"));
    try testing.expect(!isSafelistedRequestHeader("X-Probe", "1"));
    try testing.expect(!isSafelistedRequestHeader("Authorization", "Bearer x"));
}

test "cors: content-type is safelisted only for the three essences" {
    try testing.expect(isSafelistedRequestHeader("content-type", "text/plain"));
    try testing.expect(isSafelistedRequestHeader("content-type", "text/plain;charset=UTF-8"));
    try testing.expect(isSafelistedRequestHeader("Content-Type", "TEXT/PLAIN"));
    try testing.expect(isSafelistedRequestHeader("content-type", "application/x-www-form-urlencoded"));
    try testing.expect(isSafelistedRequestHeader("content-type", "multipart/form-data; boundary=x"));
    try testing.expect(!isSafelistedRequestHeader("content-type", "application/json"));
    try testing.expect(!isSafelistedRequestHeader("content-type", "application/json;charset=UTF-8"));
    try testing.expect(!isSafelistedRequestHeader("content-type", "text/html"));
}

test "cors: range is safelisted only in its plain form" {
    try testing.expect(isSafelistedRequestHeader("Range", "bytes=0-100"));
    try testing.expect(isSafelistedRequestHeader("range", "bytes=100-"));
    try testing.expect(!isSafelistedRequestHeader("range", "bytes=-100"));
    try testing.expect(!isSafelistedRequestHeader("range", "bytes=0-10,20-30"));
    try testing.expect(!isSafelistedRequestHeader("range", "items=0-10"));
}

test "cors: Allow-Origin, with and without credentials" {
    try testing.expect(originAllowed("*", null, "http://a.com", false));
    try testing.expect(!originAllowed("*", "true", "http://a.com", true));
    try testing.expect(originAllowed("http://a.com", null, "http://a.com", false));
    try testing.expect(!originAllowed("http://b.com", null, "http://a.com", false));
    try testing.expect(originAllowed("http://a.com", "true", "http://a.com", true));
    try testing.expect(!originAllowed("http://a.com", null, "http://a.com", true));
    try testing.expect(!originAllowed(null, "true", "http://a.com", false));
}

test "cors: which response headers an allowed cross-origin response shows" {
    // The seven safelisted names, whatever the response says.
    try testing.expect(responseHeaderExposed("Content-Type", null, false));
    try testing.expect(responseHeaderExposed("content-length", null, false));
    try testing.expect(responseHeaderExposed("Last-Modified", null, true));
    // Anything else needs naming. Case-insensitively, both ways.
    try testing.expect(!responseHeaderExposed("X-Custom", null, false));
    try testing.expect(responseHeaderExposed("X-Custom", "x-custom", false));
    try testing.expect(responseHeaderExposed("x-custom", "X-Custom", false));
    try testing.expect(responseHeaderExposed("X-Custom", "x-other, x-custom", false));
    try testing.expect(!responseHeaderExposed("X-Custom", "x-other", false));
    // The wildcard, and its one restriction.
    try testing.expect(responseHeaderExposed("X-Custom", "*", false));
    try testing.expect(!responseHeaderExposed("X-Custom", "*", true));
    // Allow-Origin is itself not safelisted, so a page cannot read back the
    // header that let it read the body.
    try testing.expect(!responseHeaderExposed("Access-Control-Allow-Origin", null, false));
}

test "cors: Allow-Methods / Allow-Headers list membership" {
    try testing.expect(listAllows("GET, POST, PUT", "PUT", false));
    try testing.expect(listAllows("GET,POST,PUT", "put", false));
    try testing.expect(!listAllows("GET, POST", "PUT", false));
    try testing.expect(!listAllows(null, "PUT", false));
    try testing.expect(listAllows("*", "PUT", false));
    try testing.expect(!listAllows("*", "PUT", true));
    try testing.expect(listAllows("content-type, x-probe", "X-Probe", false));
}
