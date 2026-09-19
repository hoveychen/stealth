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

const Inbox = @import("../Inbox.zig");
const Watchdog = @import("../Watchdog.zig");
const ArenaPool = @import("../ArenaPool.zig");
const Notification = @import("../Notification.zig");
const Driver = @import("../server/Driver.zig");

const URL = @import("../browser/URL.zig");
const referrer = @import("../browser/referrer.zig");
const WebSocket = @import("../browser/webapi/net/WebSocket.zig");
const Cookie = @import("../browser/webapi/storage/Cookie.zig");
const CookieJar = Cookie.Jar;
const Performance = @import("../browser/webapi/Performance.zig");

const Config = @import("../Config.zig");
const http = @import("http.zig");
const blink_header_order = @import("blink_header_order.zig");

/// Re-exported so the resource-timing recorders — which know HttpClient and not
/// the curl layer under it — can hold one between a header callback and the
/// entry they file later.
pub const ResponseLabels = http.ResponseLabels;
pub const ResponseTimes = http.ResponseTimes;
const Network = @import("Network.zig");
const Cache = @import("cache/Cache.zig");
const RobotsGate = @import("RobotsGate.zig");
const PreflightGate = @import("PreflightGate.zig");
const ClientHints = @import("ClientHints.zig");
const CorsGate = @import("CorsGate.zig");
const UrlBlocklist = @import("UrlBlocklist.zig");

pub const BlockPattern = UrlBlocklist.Pattern;

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const Method = http.Method;
pub const Header = http.Header;
pub const HeaderIterator = http.HeaderIterator;

// This is loosely tied to a browser Frame. Loading all the <scripts>, doing
// XHR requests, and loading imports all happens through here. Sine the app
// currently supports 1 browser and 1 frame at-a-time, we only have 1 Client and
// re-use it from frame to frame. This allows us better re-use of the various
// buffers/caches (including keepalive connections) that libcurl has.
//
// The app has other secondary http needs, like telemetry. While we want to
// share some things (namely the ca blob, and maybe some configuration
// (TODO: ??? should proxy settings be global ???)), we're able to call
// client.abortList() to abort the transfers being made by a frame, without
// impacting those other http requests.
pub const Client = @This();

// Count of active ws requests
ws_active: usize = 0,

// Count of active http requests
http_active: usize = 0,

// Our curl multi handle.
handles: http.Handles,

// Watchdog instrumentation for this client's worker thread. Wraps the poll
// in perform (and the background-task wait in Runner) so the watchdog can
// tell "parked, waiting for work" from "stuck between waits". Registered
// with App.watchdog by Browser.init.
heartbeat: Watchdog.Heartbeat = .{},

// Use to generate the next request ID
next_request_id: u32 = 0,

// Every currently-alive Transfer indexed by its id. Maintained so cross-
// component code (CDP intercept state, future scheduling/debugging) can
// look up a transfer by id without holding a *Transfer that might dangle.
// Inserted in Client.request, removed in Transfer.deinit. The pointer is
// only valid for the lifetime of the entry.
transfers: std.AutoHashMapUnmanaged(u32, *Transfer) = .empty,

// Connections currently in this client's curl_multi.
in_use: std.DoublyLinkedList = .{},

// Queue for request that are waiting an available connection (aka, easy)
pending_queue: std.DoublyLinkedList = .{},

// Transfers waiting out the per-host navigation throttle, ordered by _run_at.
delayed_queue: std.DoublyLinkedList = .{},
delayed_count: usize = 0,

// Queue for completed transfers that haven't had their callbacks executed yet
dispatch_queue: std.DoublyLinkedList = .{},

// WebSockets with buffered incoming events awaiting delivery. Separate from
// dispatch_queue because the entries aren't Transfers and the gating rule is
// simpler: WS events only deliver at tick(.all).
ws_dispatch_queue: std.DoublyLinkedList = .{},
ws_dispatch_count: usize = 0,

// Completed transfers held back by a frame's blocking request. dispatch()
// parks them here on first sight so the gate is evaluated once per transfer
// per blocking window, not once per tick; releaseBlocking splices them
// back. Blocking requests are common (every bare <script src> is one), so
// this keeps dispatch O(new work) during page load.
gated_queue: std.DoublyLinkedList = .{},

// Undelivered transfers across dispatch_queue + gated_queue.
dispatch_count: usize = 0,

// Transfers retired by Transfer.deinit. This is a safety measure incase
// something tries to use the transfer after it's freed.
graveyard: std.DoublyLinkedList = .{},

// The main app allocator
allocator: Allocator,

network: *Network,

arena_pool: *ArenaPool,

// The current proxy. Callers can change it, changeProxy(null) restores
// from config. May point either at `http_proxy_owned` (a caller-supplied
// dupe) or at the config string (which we must not free).
http_proxy: ?[:0]const u8 = null,

// When a caller (e.g. CDP) supplies a proxy, we have to dupe it to take ownership
// which we'll be responsible for freeing.
http_proxy_owned: ?[:0]const u8 = null,

// track if the client use a proxy for connections.
// We can't use http_proxy because we want also to track proxy configured via
// CDP.
use_proxy: bool,

// Current TLS verification state, applied per-connection in makeRequest.
tls_verify: bool = true,

// Test-only fault injection: makes the next submit() fail synchronously from
// inside the pipeline, the shape where error_callback fires AND the error is
// returned to the caller (see Transfer.submit).
test_fail_submit: if (lp.IS_TEST) ?anyerror else void = if (lp.IS_TEST) null else {},

// User agent override set via CDP Emulation.setUserAgentOverride.
// When set, takes precedence over the config's http_headers value.
// Allocated from self.allocator when set, null otherwise.
user_agent_override: ?[:0]const u8 = null,

// Accept-Language / platform overrides, also from Emulation.setUserAgentOverride.
// Kept alongside the UA override so all three move together: a Chrome UA next
// to a stale platform hint is a worse fingerprint than either alone.
// Upstream's type: the header and the tags it lists, so navigator.languages
// and the wire header cannot disagree.
accept_language_override: ?lp.Config.HttpHeaders.AcceptLanguage = null,
platform_override: ?[:0]const u8 = null,
// The same platform, quoted, as the Sec-Ch-Ua-Platform hint carries it. The
// override arrives bare (that is the form navigator.userAgentData reports), so
// the quoted form is built once here rather than per request.
platform_quoted_override: ?[:0]const u8 = null,

// The driver (CDP / BiDi) attached to us. If there's a driver, then there's
// an inbox for us to process (and there's someone to wake us up from a poll)
driver: ?Driver = null,

// If there's a driver, it can tell us to disconnect and that has to stick
// until _tick is called and picks it up.
disconnected: bool = false,

// Test-only: an inbox for a client with no driver (the shared test browser),
// so the pending-teardown checks can be exercised without a CDP connection.
test_inbox: if (lp.IS_TEST) ?*Inbox else void = if (lp.IS_TEST) null else {},

max_response_size: usize,

// While a frame has a blocking (synchronous) request in flight, dispatch
// holds back every other transfer for that frame so their callbacks can't
// run JS while the parser is on the stack. frame_id -> blocking transfer id.
blocking_requests: std.AutoHashMapUnmanaged(u32, u32) = .empty,

// Count of transfers parked for CDP interception (request or auth phase).
// They're off every other activity counter while parked; the network-idle
// heuristics add this in.
intercepted: usize = 0,

cache: *Cache,

// Cached config decisions, resolved once at init.
serve_mode: bool,
obey_robots: bool,
obey_cors: bool,

// Applied to every transfer at configureConn, so a CDP change takes effect
// on the next request, not on in-flight ones.
http_version: lp.Config.HttpVersion,

robots: RobotsGate,
preflight: PreflightGate,
cors: CorsGate,
url_blocklist: ?UrlBlocklist,

// Which high-entropy client hints each origin has asked for via Accept-CH.
// Browser-lifetime, like Chrome's: the negotiation outlives the navigation
// that carried it, so a second visit to an origin still sends what the first
// one was asked for.
client_hints: ClientHints = .{},

pub fn init(self: *Client, app: *lp.App) !void {
    const config = app.config;
    const allocator = app.allocator;

    var handles = try http.Handles.init(config);
    errdefer handles.deinit();

    const http_proxy = config.httpProxy();

    var url_blocklist: ?UrlBlocklist = null;
    if (config.blockedUrlPatterns()) |initial_patterns| {
        var patterns: std.ArrayList([]const u8) = .empty;
        defer patterns.deinit(allocator);

        var it = initial_patterns;
        while (it.next()) |pattern| {
            if (pattern.len > 0) try patterns.append(allocator, pattern);
        }
        if (patterns.items.len > 0) {
            url_blocklist = try UrlBlocklist.init(allocator, patterns.items);
        }
    }
    errdefer if (url_blocklist) |*blocklist| blocklist.deinit();

    const network = &app.network;

    self.* = Client{
        .handles = handles,
        .network = network,
        .allocator = app.allocator,
        .cache = &network.cache,

        .use_proxy = http_proxy != null,
        .http_proxy = http_proxy,
        .tls_verify = network.config.tlsVerifyHost(),
        .max_response_size = network.config.httpMaxResponseSize() orelse 1 * 1024 * 1024 * 1024, // 1 GiB

        .serve_mode = config.mode == .serve,
        .obey_robots = config.obeyRobots(),
        .http_version = config.httpVersion(),
        .obey_cors = config.experimentalFeatures().cors,
        .robots = .{
            .network = network,
            .single_flight = .init(allocator),
        },
        .preflight = .{
            .allocator = allocator,
            .single_flight = .init(allocator),
        },
        .cors = .{ .single_flight = .init(allocator) },
        .url_blocklist = url_blocklist,
        .arena_pool = &app.arena_pool,
    };
}

pub fn deinit(self: *Client) void {
    self.abort();
    self.processGraveyard();

    if (comptime lp.IS_DEBUG) {
        lp.assert(
            self.dispatch_count == 0,
            "dispatch_count must be 0",
            .{ .value = self.dispatch_count },
        );
        lp.assert(
            self.ws_dispatch_count == 0,
            "ws_dispatch_count must be 0",
            .{ .value = self.ws_dispatch_count },
        );
    }

    self.handles.deinit();

    self.clearUserAgentOverride();
    self.clearAcceptLanguageOverride();
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
    }

    self.clearUrlBlocklist();
    self.client_hints.deinit(self.allocator);
    self.robots.deinit();
    self.preflight.deinit();
    self.cors.deinit();
    self.blocking_requests.deinit(self.allocator);
    self.transfers.deinit(self.allocator);
    self.cache.maintenance(lp.datetime.timestamp(.real));
}

// Look up a live transfer by its id. Returns null if the transfer has been
// destroyed. Use this — rather than holding *Transfer across yields — for
// any code path that's interleaved with the request lifecycle (CDP
// continueRequest/fulfill/abort, async cleanups).
pub fn findTransfer(self: *Client, id: u32) ?*Transfer {
    return self.transfers.get(id);
}

pub fn incrReqId(self: *Client) u32 {
    const id = self.next_request_id +% 1;
    self.next_request_id = id;
    return id;
}

// Set a user agent override, allocated from self.allocator.
pub fn setUserAgentOverride(self: *Client, ua: []const u8) !void {
    self.clearUserAgentOverride();
    self.user_agent_override = try self.allocator.dupeZ(u8, ua);
}

pub fn setPlatformOverride(self: *Client, value: []const u8) !void {
    const bare = try self.allocator.dupeZ(u8, value);
    errdefer self.allocator.free(bare);
    const quoted = try std.fmt.allocPrintSentinel(self.allocator, "\"{s}\"", .{value}, 0);

    self.clearOverride(&self.platform_override);
    self.clearOverride(&self.platform_quoted_override);
    self.platform_override = bare;
    self.platform_quoted_override = quoted;
}

fn clearOverride(self: *Client, field: *?[:0]const u8) void {
    if (field.*) |v| {
        self.allocator.free(v);
        field.* = null;
    }
}

// Clear any user agent override, restoring the default from config.
pub fn clearUserAgentOverride(self: *Client) void {
    // All three move together: a Chrome UA next to a stale platform hint is a
    // worse fingerprint than either alone.
    self.clearOverride(&self.user_agent_override);
    self.clearAcceptLanguageOverride();
    self.clearOverride(&self.platform_override);
    self.clearOverride(&self.platform_quoted_override);
}

// Set an Accept-Language override, allocated from self.allocator.
pub fn setAcceptLanguageOverride(self: *Client, value: []const u8) !void {
    self.clearAcceptLanguageOverride();
    self.accept_language_override = try .init(self.allocator, value);
}

pub fn clearAcceptLanguageOverride(self: *Client) void {
    if (self.accept_language_override) |override| {
        override.deinit(self.allocator);
        self.accept_language_override = null;
    }
}

// Enable TLS verification on all connections.
pub fn setTlsVerify(self: *Client, verify: bool) !void {
    // Remove inflight connections check on enable TLS b/c chromiumoxide calls
    // the command during navigate and Curl seems to accept it...

    var it = self.in_use.first;
    while (it) |node| : (it = node.next) {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try conn.setTlsVerify(verify, self.use_proxy);
    }

    self.tls_verify = verify;
}

pub fn obeyRobots(self: *Client, enable: bool) !void {
    if (self.obey_robots == enable) return;
    try self.ensureNoActiveConnection();
    self.obey_robots = enable;
}

pub fn setHttpVersion(self: *Client, version: lp.Config.HttpVersion) void {
    self.http_version = version;
}

pub fn disableCache(self: *Client, disable: bool) void {
    if (disable) {
        self.cache = &Cache.noop;
    } else {
        self.cache = &self.network.cache;
    }
}

// Restrictive since it'll only work if there are no inflight requests. In some
// cases, the libcurl documentation is clear that changing settings while a
// connection is inflight is undefined. It doesn't say anything about CURLOPT_PROXY,
// but better to be safe than sorry.
// For now, this restriction is ok, since it's only called by CDP on
// createBrowserContext, at which point, if we do have an active connection,
// that's probably a bug (a previous abort failed?). But if we need to call this
// at any point in time, it could be worth digging into libcurl to see if this
// can be changed at any point in the easy's lifecycle.
pub fn changeProxy(self: *Client, proxy: ?[:0]const u8) !void {
    try self.ensureNoActiveConnection();

    // Free any previously-duped proxy before we overwrite http_proxy.
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
        self.http_proxy_owned = null;
    }

    // Reset to the config default; if dupeZ below fails, http_proxy is
    // left pointing at this rather than at the freed dup.
    self.http_proxy = self.network.config.httpProxy();

    if (proxy) |p| {
        const owned = try self.allocator.dupeZ(u8, p);
        self.http_proxy_owned = owned;
        self.http_proxy = owned;
    }
    self.use_proxy = self.http_proxy != null;
}

/// Replace the current URL blocklist. The caller retains ownership of
/// `patterns`; compiled copies remain valid after the CDP command arena is
/// released.
pub fn setBlockedUrls(self: *Client, patterns: []const []const u8) !void {
    const replacement: ?UrlBlocklist = if (patterns.len == 0)
        null
    else
        try UrlBlocklist.init(self.allocator, patterns);

    self.clearUrlBlocklist();
    self.url_blocklist = replacement;
}

pub fn setBlockedUrlPatterns(self: *Client, patterns: []const BlockPattern) !void {
    const replacement: ?UrlBlocklist = if (patterns.len == 0)
        null
    else
        try UrlBlocklist.initPatterns(self.allocator, patterns);

    self.clearUrlBlocklist();
    self.url_blocklist = replacement;
}

fn clearUrlBlocklist(self: *Client) void {
    if (self.url_blocklist) |*blocklist| {
        blocklist.deinit();
        self.url_blocklist = null;
    }
}

/// Every reason a request is refused before it reaches the network:
/// `--block-urls` patterns and the `--adblock-lists` filters both land here
/// so that no call site can apply one without the other.
fn isUrlBlocked(self: *const Client, transfer: *const Transfer) bool {
    const req = &transfer.req;
    if (req.internal) return false;
    if (self.url_blocklist) |*blocklist| {
        if (blocklist.isBlocked(req.url)) return true;
    }
    return if (self.network.adblocker) |*blocker| blocker.isBlocked(transfer) else false;
}

fn adblockSourceUrl(transfer: *const Transfer) ?[]const u8 {
    var owner: *const Owner = transfer.owner orelse return null;
    if (transfer.req.resource_type == .document) {
        owner = owner.parent orelse return null;
    }
    return owner.documentUrl();
}

fn isCrossOriginModeAllowed(transfer: *const Transfer) bool {
    const req = &transfer.req;
    if (req.request_mode != .same_origin) {
        return true;
    }
    const origin = req.origin orelse return false;
    return URL.isSameOrigin(req.url, origin);
}

const FetchSite = enum { same_origin, same_site, cross_site };

// Compares an initiator origin against a request URL the way Sec-Fetch-Site
// does: `same-origin` for an identical scheme/host/port tuple, `same-site` when
// the scheme and the registrable domain match but the tuple does not.
//
// The registrable-domain half used to be approximated by "one host is a suffix
// of the other", which is wrong on both of the shapes a real page actually has.
// Measured against Chrome (tools/fingerprint/scratch/b119, `--scenario
// fetch-site`): another PORT of one host is same-site, and so are two SIBLING
// subdomains -- neither of which is a suffix of the other, and the port the old
// comparison never even stripped. The same capture also settles the scheme:
// https -> http on one host is `cross-site`, so this is the schemeful notion of
// same site, exactly what sameSiteForStorage already computes.
fn fetchSite(initiator_: []const u8, url_: []const u8) FetchSite {
    const initiator = withoutBlobPrefix(initiator_);
    const url = withoutBlobPrefix(url_);
    const a = originOf(initiator);
    const b = originOf(url);
    if (std.mem.eql(u8, a.scheme, b.scheme) and std.mem.eql(u8, a.host, b.host)) {
        return .same_origin;
    }
    return if (sameSiteForStorage(initiator, url)) .same_site else .cross_site;
}

// Whether two URLs are same-site: scheme plus registrable domain, port ignored.
// That is both what a *storage partition key* compares and, measured, what
// Sec-Fetch-Site reports -- so fetchSite defers to this too.
//
// The real eTLD+1 walk already exists for cookies; reuse it rather than
// approximating with a suffix comparison, which gets two sibling subdomains
// wrong in the direction that matters.
// A blob: URL is as same-site as the origin it was minted from, the same
// unwrapping URL.isPotentiallyTrustworthy does. Without it the "blob:" prefix
// reads as the scheme and a document loaded from a blob URL is cross-site with
// its own host -- which the cf-scrapingcourse challenge, whose last two
// requests come out of a blob: document, would notice.
fn withoutBlobPrefix(url: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, url, "blob:")) url["blob:".len..] else url;
}

pub fn sameSiteForStorage(a_: []const u8, b_: []const u8) bool {
    const a = withoutBlobPrefix(a_);
    const b = withoutBlobPrefix(b_);
    if (!std.mem.eql(u8, URL.getProtocol(a), URL.getProtocol(b))) {
        return false;
    }
    const host_a = URL.getHostname(a);
    const host_b = URL.getHostname(b);
    // An empty host is about:blank, data: and friends: no site to compare, so
    // nothing is same-site with it -- not even another one of them.
    if (host_a.len == 0 or host_b.len == 0) {
        return false;
    }
    return std.mem.eql(u8, Cookie.findSecondLevelDomain(host_a), Cookie.findSecondLevelDomain(host_b));
}

const Origin = struct { scheme: []const u8, host: []const u8 };

fn originOf(url: []const u8) Origin {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return .{ .scheme = "", .host = url };
    const rest = url[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return .{ .scheme = url[0..scheme_end], .host = rest[0..host_end] };
}

// Bare (non-header) values the JS side reports, with CDP overrides applied.
pub fn getPlatform(self: *const Client) []const u8 {
    return self.platform_override orelse self.httpHeaders().platform;
}

pub fn getUserAgent(self: *const Client) [:0]const u8 {
    return self.user_agent_override orelse self.network.config.http_headers.user_agent;
}

pub fn getAcceptLanguage(self: *const Client) [:0]const u8 {
    return (self.accept_language_override orelse self.network.config.http_headers.accept_language).header;
}

pub fn getLanguages(self: *const Client) []const []const u8 {
    return (self.accept_language_override orelse self.network.config.http_headers.accept_language).languages;
}

// The resolved header/client-hint values. The JS side (navigator.userAgentData,
// navigator.platform, navigator.languages) reads the same struct the wire
// headers are built from, so the two can't disagree — which is the whole point:
// a Sec-Ch-Ua saying Chrome next to a userAgentData saying something else is a
// louder signal than either value alone.
pub fn httpHeaders(self: *const Client) *const Config.HttpHeaders {
    return &self.network.config.http_headers;
}

// Headers _all_ requests include, in the order this engine emits them. The
// client hints come first, then the User-Agent, then Accept-Language; the
// per-destination Accept and the Sec-Fetch-* set are added later, by
// Transfer.seedFetchMetadata, which is the only place that knows the request's
// destination and initiator.
//
// A Sec-* name is a forbidden header name, so the client hints go in at `.cdp`
// rather than the default: page script (`.author`, a lower rank) cannot forge
// one, while a CDP or CLI override still lands -- which is what a driver
// setting Emulation.setUserAgentOverride or Network.setExtraHTTPHeaders
// expects, and what this fork did before upstream's source ladder existed.
// The User-Agent and Accept-Language are not forbidden names, so they stay at
// the default rank and a page may legitimately set them.
//
// Note what is NOT here: Sec-Ch-Ua-Full-Version-List. It is a high-entropy
// hint, and Chrome sends it only after a server asks via Accept-CH — sending it
// unsolicited is itself a tell. The full versions are still reachable from JS,
// through navigator.userAgentData.getHighEntropyValues.
pub fn baselineHeaders(self: *const Client) [7]Transfer.RequestHeader {
    const headers = self.httpHeaders();
    return .{
        // Chrome sends this on every HTTP/1.1 request, right after Host, and
        // curl sends nothing at all. Emitted here rather than left implicit;
        // the vendored curl places the field for us (its H1_HD_CONNECTION slot,
        // moved to follow Host) and drops it entirely on HTTP/2, which is also
        // what Chrome does.
        .{ .name = "Connection", .value = "keep-alive", .source = .cdp },
        // Lowercase, and only these three. Chromium Title-Cases every other
        // field name it writes and spells the client hints in lowercase --
        // measured, the `localHeaders` step of
        // tools/fingerprint/results/px-hdr-chrome-ua.json. Visible on HTTP/1.1
        // only: HPACK requires lowercase names, so curl lowercases the whole
        // set on the way into h2 and the casing there is not ours to pick.
        .{ .name = "sec-ch-ua", .value = headers.sec_ch_ua, .source = .cdp },
        .{ .name = "sec-ch-ua-mobile", .value = Config.HttpHeaders.sec_ch_ua_mobile, .source = .cdp },
        .{ .name = "sec-ch-ua-platform", .value = self.platformHeader(), .source = .cdp },
        .{ .name = "User-Agent", .value = self.getUserAgent() },
        // Sent from here rather than left to curl's CURLOPT_ACCEPT_ENCODING,
        // which writes it second -- one position after Host -- where Chrome has
        // it second to last. curl skips its own copy once the header list
        // carries one (Curl_checkheaders in deps/curl-patched/lib/http.c), and
        // response decoding is gated on CURLOPT_ACCEPT_ENCODING being *set*
        // rather than on curl having written the header, so the body still
        // arrives decompressed. The value must stay in step with what
        // http.Connection.reset configures, or we would advertise an encoding
        // the decoder was never told to accept -- hence the shared constant.
        .{ .name = "Accept-Encoding", .value = http.accept_encoding, .source = .cdp },
        // Omitting Accept-Language triggers bot-protection on some CDNs
        // (Akamai) when Accept-Encoding is present.
        .{ .name = "Accept-Language", .value = self.getAcceptLanguage() },
    };
}

// The Sec-Ch-Ua-Platform value, quoted, with the CDP override applied. The
// override arrives bare, so it is quoted here rather than at set time.
fn platformHeader(self: *const Client) []const u8 {
    return self.platform_quoted_override orelse self.httpHeaders().sec_ch_ua_platform;
}

// The wire value of a high-entropy hint, for an origin that asked. Four of the
// six are fixed by the claimed platform and two follow the brand list, and each
// is the same value navigator.userAgentData.getHighEntropyValues answers -- the
// header and the JS call have to describe one machine.
//
// Emulation.setUserAgentOverride can carry a userAgentMetadata with its own
// architecture/model/platformVersion; this engine reads only the platform out
// of it (Client.platform_quoted_override), so a driver that overrides the rest
// is not honoured here either. Consistent, if incomplete.
fn clientHintValue(self: *const Client, hint: ClientHints.Hint) []const u8 {
    const H = Config.HttpHeaders;
    return switch (hint) {
        .arch => H.sec_ch_ua_arch,
        .bitness => H.sec_ch_ua_bitness,
        .model => H.sec_ch_ua_model,
        .platform_version => H.sec_ch_ua_platform_version,
        .full_version => self.httpHeaders().sec_ch_ua_full_version,
        .full_version_list => self.httpHeaders().sec_ch_ua_full_version_list,
    };
}

pub fn abort(self: *Client) void {
    // Snapshot before killing: kill() -> deinit removes entries from
    // self.transfers, which would invalidate a live iterator.
    var snapshot = std.ArrayList(*Transfer).initCapacity(self.allocator, self.transfers.count()) catch @panic("OOM");
    defer snapshot.deinit(self.allocator);
    var it = self.transfers.valueIterator();
    while (it.next()) |t| {
        snapshot.appendAssumeCapacity(t.*);
    }

    for (snapshot.items) |t| {
        t.kill();
    }

    // After the kill loop, every internal list should drain itself via
    // each transfer's deinit:
    //   - self.transfers : transfers.remove(self.id)
    //   - self.pending_queue     : unlinked if _queued is set
    //   - self.in_use    : via removeConn
    // Any non-empty list means a transfer escaped cleanup — assert so we
    // catch the regression rather than silently leaking on next use.
    // ws_dispatch_queue drains through owner teardown (abortOwner -> kill),
    // which precedes Client.deinit.
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(self.transfers.size == 0);
        std.debug.assert(self.pending_queue.first == null);
        std.debug.assert(self.delayed_queue.first == null);
        std.debug.assert(self.dispatch_queue.first == null);
        std.debug.assert(self.gated_queue.first == null);
        std.debug.assert(self.in_use.first == null);
        std.debug.assert(self.ws_dispatch_queue.first == null);
        // - self.robots.pending : each robots fetch's shutdown_callback
        //   drops its entry; parked waiters unlink in their own deinit.
        std.debug.assert(self.robots.single_flight.count() == 0);
        std.debug.assert(self.preflight.single_flight.count() == 0);
        std.debug.assert(self.cors.single_flight.count() == 0);
    }
}

// Release the arenas of retired transfers. Must only run at a safe point, e.g.
// tick(.all)
fn processGraveyard(self: *Client) void {
    while (self.graveyard.popFirst()) |node| {
        const transfer: *Transfer = @fieldParentPtr("_node", node);
        const arena = transfer.arena;
        arena.release();
    }
}

// Kill every transfer + websocket owned by `owner`. Used when the owner
// (Frame / WorkerGlobalScope) is being torn down. After this returns,
// every WebSocket is fully gone; a transfer whose callbacks are being
// delivered right now may still be on `owner.transfers` (Transfer.kill
// defers its deinit), but it's been unlinked from the owner list via
// kill()'s deferred branch so the owner is free to die.
pub fn abortOwner(self: *Client, owner: *Owner) void {
    self.abortRequests(owner);
    var n = owner.websockets.first;
    while (n) |node| {
        n = node.next;
        const ws: *WebSocket = @fieldParentPtr("_owner_node", node);
        ws.kill();
    }
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(owner.websockets.first == null);
    }
}

// HTTP-only variant. WebSockets survive (they're cross-document by
// design). Used by the navigation path that aborts in-flight resource
// loads for a frame but lets its WebSockets keep running.
pub fn abortRequests(_: *Client, owner: *Owner) void {
    var n = owner.transfers.first;
    while (n) |node| {
        n = node.next;
        const t: *Transfer = @fieldParentPtr("owner_node", node);
        t.kill();
    }
    // owner.transfers may still have entries: Transfer.kill defers
    // (flags `aborted` + noops callbacks) when called from inside a
    // deliver() and only fully deinits when its loop exits. The deferred
    // branch unlinks the node and clears Transfer.owner, so by the time
    // the owner itself is freed, no orphan transfer points at it.
}

// Unlike abortOwner, the owner intends to stay alive (e.g. window.stop()). Our
// shutdown has to be a little nicer, i.e. firing error callbacks.
pub fn cancelRequests(self: *Client, owner: *Owner) void {
    const last_id = self.next_request_id;
    while (true) {
        // Don't walk the linked list "normally", instead keep poping the head...
        // cancel() can run JS which can mutate / invalidate nodes
        var n = owner.transfers.first;

        const target = while (n) |node| : (n = node.next) {
            const t: *Transfer = @fieldParentPtr("owner_node", node);
            if (t.id <= last_id and !t._outcome_delivered and !t.isCompleteAwaitingDispatch()) {
                break t;
            }
        } else return;
        target.cancel();
    }
}

// Point-in-time snapshot of the client's outstanding work
pub const Activity = struct {
    // in-flight + buffered-awaiting-dispatch + parked-for-CDP-interception
    http: usize,

    // WebSockets with undelivered events. Unlike ws_conns which only captures
    // a connected websocket, this actually indicates that there's some activity
    // on i
    ws_events: usize,

    // Live WebSocket connections.
    ws_conns: usize,

    // transfers waiting on a free connection
    pending: bool,

    pub fn total(self: Activity) usize {
        return self.http + self.ws_events;
    }

    pub fn idle(self: Activity) bool {
        return self.total() == 0 and !self.pending;
    }
};

pub fn activity(self: *const Client) Activity {
    return .{
        .http = self.http_active + self.dispatch_count + self.intercepted + self.delayed_count,
        .ws_events = self.ws_dispatch_count,
        .ws_conns = self.ws_active,
        .pending = self.pending_queue.first != null,
    };
}

// What client messages drainInbox is allowed to dispatch this tick.
//   .all       — outer event loop (Runner.tick). Safe to dispatch
//                everything; the JS stack is empty.
//   .sync_wait — reachable from inside a JS callback (syncRequest,
//                waitForImport). The JS callstack above us holds
//                refs to page / session / V8 state; dispatching a
//                command that frees that state would UAF on unwind.
//                Cherry-pick only Fetch interception responses
// .terminal    - pops only close/disconnect: the connection is going away and
//                nothing else may be dispatched, but the peer still gets its
//                close reason.
const DrainMode = enum { all, sync_wait, terminal };

// One-shot convenience: create and submit in a single call.
pub fn request(self: *Client, req: Request, owner: ?*Owner) anyerror!void {
    const transfer = try self.newRequest(req, owner);
    return transfer.submit();
}

// Create a request without submitting it. The caller owns the returned
// transfer until transfer.submit() consumes it (or until syncRequest, which
// consumes it the same way): it can add headers and mutate transfer.req,
// scoped as:
//
//   const transfer = try client.newRequest(.{...}, owner);
//   {
//       errdefer transfer.deinit();
//       try transfer.setHeader("Blah", "x", .{});
//   }
//   try transfer.submit();
//
// The errdefer must cover the mutation only, never submit itself.
pub fn newRequest(self: *Client, req: Request, owner: ?*Owner) anyerror!*Transfer {
    const arena = try self.arena_pool.acquire(.small, "Request.arena");

    const transfer = blk: {
        var owned = req;
        errdefer arena.release();

        // Most of the time, the req data will outlive the transfer. But not
        // always. The most problematic case is with a QueuedNavigation which
        // is freed quite quickly and would definetly not survive a queued
        // request.
        //
        // These are all small, so duping them into the transfer's arena is
        // cheap and can solve some nasty UAF.
        owned.url = try arena.dupeZ(u8, req.url);

        var cookie_jar: ?*CookieJar = null;
        if (owner) |o| {
            if (owned.frame_id == 0) owned.frame_id = o.frame_id;
            if (owned.loader_id == 0) owned.loader_id = o.loader_id;
            if (owned.document_frame_id == null) owned.document_frame_id = o.document_frame_id;
            if (owned.notification == null) owned.notification = o.notification;
            cookie_jar = o.cookie_jar;
        }
        // Same reason: the top-level URL lives in the root frame's arena, and a
        // queued navigation's transfer can outlive the frame that filled it in.
        if (req.partition) |p| {
            owned.partition.?.top_level_url = try arena.dupe(u8, p.top_level_url);
        }
        // Resolved onto the transfer; the request's copy is left null so
        // nothing reads the caller's (possibly short-lived) url through it.
        const cookie_origin: Cookie.SiteForCookies = switch (req.cookie_origin orelse if (owner) |o| o.siteForCookies() else .none) {
            .none => .none,
            .url => |url| .{ .url = try arena.dupeZ(u8, url) },
        };
        owned.cookie_origin = null;

        if (req.basic_auth_credentials) |c| {
            owned.basic_auth_credentials = try arena.dupeZ(u8, c);
        }

        const raw_origin: ?[]const u8 = req.origin orelse if (owner) |o| o.origin.* else null;
        owned.origin = if (raw_origin) |origin| try arena.dupe(u8, origin) else null;

        // The body can be larger, so callers can signal, via the
        // `body_outlives_request` flag that they guarantee that the body
        // will outlive the transfer (and thus doesn't need to be duped)
        if (req.body) |b| {
            if (req.body_outlives_request == false) {
                owned.body = try arena.dupe(u8, b);
            }
        }

        const t = try arena.create(Transfer);
        t.* = .{
            .req = owned,
            .cookie_jar = cookie_jar,
            .cookie_origin = cookie_origin,
            .client = self,
            .arena = arena,
            .id = self.incrReqId(),
            .start_time = lp.datetime.timestamp(.boot),
            // owner is set AFTER we've actually appended to the owner list,
            // so transfer.deinit's `if (self.owner)` branch only fires when
            // we're truly linked. Otherwise we'd try to remove a node from
            // a list it was never in.
            .owner = null,
            .owner_node = .{},
        };
        try t.seedHeaders();
        break :blk t;
    };

    // From here the transfer owns `req` and `arena`
    self.transfers.putNoClobber(self.allocator, transfer.id, transfer) catch |err| {
        transfer.deinit();
        return err;
    };

    if (owner) |o| {
        o.addTransfer(transfer);
        transfer.owner = o;
    }

    return transfer;
}

pub fn tick(self: *Client, timeout_ms: u32) !bool {
    self.processGraveyard();
    return self._tick(timeout_ms, .all);
}

pub fn tickSync(self: *Client, timeout_ms: u32) !void {
    if (self.hasPendingTeardown()) {
        return error.SyncWaitInterrupted;
    }
    _ = try self._tick(timeout_ms, .sync_wait);
}

fn hasPendingTeardown(self: *Client) bool {
    const inbox = blk: {
        if (comptime lp.IS_TEST) {
            if (self.test_inbox) |test_inbox| break :blk test_inbox;
        }
        const driver = &(self.driver orelse return false);
        break :blk driver.inbox;
    };
    return inbox.contains(isSyncWaitInterrupt);
}

// Returns false iff the tick was a no-op. When false is returned, immediately
// calling this again will almost [instantly] return false again, potentially
// causing a spin.
pub fn _tick(self: *Client, timeout_ms: u32, mode: DrainMode) !bool {
    if (self.disconnected) {
        return error.ClientDisconnected;
    }

    var waited = true;
    const dispatched = self.dispatchCompleted(mode);

    try self.startPending();

    const running = try self.handles.perform();

    const processed = try self.processMessages();
    if (dispatched == false and processed == false and self.dispatch_queue.first == null and self.ws_dispatch_queue.first == null) {
        // Nothing was dispatched, no messages were processed and nothing is
        // waiting for dispatch. We need to wait for I/O.
        if (running > 0 or self.driver != null or self.delayed_queue.first != null) {
            {
                self.heartbeat.enterWait();
                defer self.heartbeat.exitWait();
                // The network layer will wake this up if there's acticity.
                try self.handles.poll(&.{}, @intCast(self.clampToDelayed(timeout_ms)));
            }
            // poll only waits, so we do the perform -> process dance again
            _ = try self.handles.perform();
            _ = try self.processMessages();
        } else {
            // There's nothing inflight. Polling will always wait until
            // timeout_ms. Rather than do that, let's signal our caller (by
            // returning false) and letting it decide what to do.
            waited = false;
        }
    } else {
        // If we DID dispatch or process messages, we don't wan to wait / poll.
        // We want to proceses completions and return to the caller ASAP so that
        // it can check progress, e.g. maybe the message we processed cause
        // "load" to fire, and that's what it was waiting for.
    }

    try self.startPending();

    _ = self.dispatchCompleted(mode);

    // dispatch CDP commands
    try self.drainInbox(mode);

    if (comptime lp.IS_DEBUG) {
        if (waited == false) {
            // we're about to tell our caller not to call us again without it
            // doing some work (e.g. running tasks). Let's assert that we were
            // right in doing that, else we'll likely introduce latency.
            std.debug.assert(self.pending_queue.first == null);
            std.debug.assert(self.delayed_queue.first == null);
            std.debug.assert(self.dispatch_queue.first == null);
            std.debug.assert(self.ws_dispatch_queue.first == null);
        }
    }

    return waited;
}

// Never sleep past the next delayed transfer's start time.
fn clampToDelayed(self: *const Client, timeout_ms: u32) u32 {
    const node = self.delayed_queue.first orelse return timeout_ms;
    const transfer: *const Transfer = @fieldParentPtr("_node", node);
    const now = lp.datetime.milliTimestamp(.boot);
    if (transfer._run_at <= now) {
        return 0;
    }
    return @intCast(@min(timeout_ms, transfer._run_at - now));
}

// Deliver completed response. This is the ONLY place user callbacks run,
// so a callback is free to start new requests, abort transfers, or tear down
// its frame. The client is never inside libcurl here.
//
// This should be as simple as: iterate the `dispatch_queue` and dispatch each
// transfer...EXCEPT...a frame can have a blocking request. So, as we iterate
// we find out if a transfer is gated behind a blocking request and move it
// from the `dispatch_queue` to the `gated_queue`. That way, every call to
// `dispatchCompleted` doesn't keep checking the same gated transfers over and
// over.
fn dispatchCompleted(self: *Client, mode: DrainMode) bool {
    if (mode == .all) {
        if (comptime lp.IS_DEBUG) {
            // .all never inside a syncRequest, so nothing can be gating requests.
            std.debug.assert(self.blocking_requests.count() == 0);
        }
    }

    // blocking_requests.count() is always true on tick(.all) but can also
    // happen mid .sync_wait. This is important to do. During blocking, we gated
    // every request. When the blocking requested completed, it only unblocked
    // it's frames request.
    if (self.blocking_requests.count() == 0) {
        var node = self.gated_queue.last;
        while (node) |n| {
            node = n.prev;
            const transfer: *Transfer = @fieldParentPtr("_queue_node", n);
            if (mode == .sync_wait and self.isGated(transfer)) {
                // still gated: a document is never delivered on a sync pump
                continue;
            }
            transfer._gated = false;
            self.gated_queue.remove(n);
            self.dispatch_queue.prepend(n);
        }
    }

    var dispatched = false;

    // pop is safest as it allows anything to manipulate the queue as necessary
    // (e.g. a frame could be aborted)s
    while (self.dispatch_queue.popFirst()) |n| {
        const transfer: *Transfer = @fieldParentPtr("_queue_node", n);
        if (mode == .sync_wait and self.isGated(transfer)) {
            transfer._gated = true;
            self.gated_queue.append(n);
            continue;
        }
        self.dispatch_count -= 1;
        transfer._dispatch_queued = false;
        transfer.deliver();
        dispatched = true;
    }

    if (mode == .all) {
        while (self.ws_dispatch_queue.popFirst()) |n| {
            const ws: *WebSocket = @fieldParentPtr("_dispatch_node", n);
            self.ws_dispatch_count -= 1;
            ws._dispatch_queued = false;
            ws.deliverEvents();
            dispatched = true;
        }
    }

    return dispatched;
}

// wsEnqueue and wsDequeue are the only places ws_dispatch_queue is mutated.
pub fn wsEnqueue(self: *Client, node: *std.DoublyLinkedList.Node) void {
    self.ws_dispatch_queue.append(node);
    self.ws_dispatch_count += 1;
}

pub fn wsDequeue(self: *Client, node: *std.DoublyLinkedList.Node) void {
    self.ws_dispatch_queue.remove(node);
    self.ws_dispatch_count -= 1;
}

// Is this transfer gated behind a blocking request
fn isGated(self: *const Client, transfer: *const Transfer) bool {
    if (transfer.req.internal) {
        // internal transfers are never blocked (e.g. robots.txt)
        return false;
    }
    if (transfer.req.resource_type == .document) {
        // isGated is only ever called during a syncRequest, so if we're here,
        // we know we're trying to load a blocking request. We don't want to
        // deliver a document here, even on a different frame, because that
        // will start the parser, which can trigger more sync blocks. That
        // sounds fine, but we're on the stack of the sync request, and this
        // can easily end up overflowing v8's stack if we have a lot of nested
        // or even sibling blocking scripts to fetch.
        return true;
    }
    if (transfer.req.resource_type == .font) {
        // A `@font-face` file runs no JS on arrival, which is the only thing
        // this gate exists to prevent: `Frame.ImageRequest.doneCallback` parses
        // the bytes, files a resource entry and QUEUES whatever has to reach
        // the page (`fontSettled` schedules a task, `report` queues an event) --
        // it has no element to size and no callback to call. So holding it back
        // buys nothing, and it costs the page its fonts.
        //
        // Measured on a page whose <div> sits ahead of a 1500ms <script src>
        // (tools/fingerprint/webfont-timeline.mjs): the font's bytes landed at
        // 16.6ms and the face became usable at 1524.1ms, the entire wait being
        // this gate. Chrome had it usable at 31.9ms -- it lays out and paints
        // while a parser-blocking script is outstanding, so its fonts land
        // there too.
        return false;
    }
    if (self.blocking_requests.count() == 0) {
        // O(1) quick check.
        return false;
    }
    // The gate is global, not per-frame: delivering another frame's
    // JS-running callback (script eval, XHR onload) here still executes on
    // the blocking request's stack and can nest parse -> syncRequest ->
    // parse until v8's stack overflows — same hazard as the .document case
    // above. Only the blocking transfer itself gets through.
    const blocking_id = self.blocking_requests.get(transfer.req.frame_id) orelse return true;
    return transfer.id != blocking_id;
}

fn startPending(self: *Client) !void {
    try self.startDelayed();
    while (self.pending_queue.popFirst()) |queue_node| {
        const transfer: *Transfer = @fieldParentPtr("_node", queue_node);
        const conn = self.network.getConnection() orelse {
            self.pending_queue.prepend(queue_node);
            return;
        };
        // Bridge state to .created so a failure inside makeRequest before
        // any commit cleans up via the failAsync below. makeRequest flips to
        // .inflight on a successful trackConn.
        transfer.state = .created;
        self.makeRequest(conn, transfer) catch |err| {
            if (transfer.state == .created) {
                // Fail through the dispatcher: this can run from a
                // tick(.sync_wait), and error_callback JS must not fire
                // on a blocking request's stack.
                transfer.failAsync(err);
            }
            return err;
        };
    }
}

// Enter the pipeline for every delayed transfer whose time has come.
fn startDelayed(self: *Client) !void {
    if (self.delayed_queue.first == null) {
        return;
    }
    const now = lp.datetime.milliTimestamp(.boot);
    while (self.delayed_queue.first) |node| {
        const transfer: *Transfer = @fieldParentPtr("_node", node);
        if (transfer._run_at > now) {
            // these are added to the queue in order, so we can exit as soon as
            // we hit the first future _run_at.
            return;
        }
        self.delayed_count -= 1;
        self.delayed_queue.remove(node);

        transfer.state = .created;
        // The throttle is the last step before the network, resume there.
        self.pipeline(transfer, .network) catch |err| {
            // Same as startPending: this can run from a tick(.sync_wait), and
            // error_callback JS must not fire on a blocking request's stack.
            if (transfer.state == .created) {
                transfer.failAsync(err);
            }
            return err;
        };
    }
}

// Hold the transfer out of the pipeline until `run_at` (ms, boot clock).
fn delay(self: *Client, transfer: *Transfer, run_at: u64) void {
    transfer._run_at = run_at;
    transfer.state = .delayed;
    self.delayed_count += 1;

    // Ordered insert; reservations for one host are monotonic, so this is
    // usually an append.
    var node = self.delayed_queue.last;
    while (node) |n| {
        const other: *const Transfer = @fieldParentPtr("_node", n);
        if (other._run_at <= run_at) {
            break;
        }
        node = n.prev;
    }
    if (node) |n| {
        self.delayed_queue.insertAfter(n, &transfer._node);
    } else {
        self.delayed_queue.prepend(&transfer._node);
    }
}

const SubmitFrom = enum {
    start, // Transfer.submit — a brand new request.
    redirect, // Followed 3xx. Same as .start, but a distinct name (e.g. for CDP)
    after_intercept, // Released by CDP
    after_cors, // CorsGate allowed the request.
    after_robots, // the robots gate allowed the request.
    throttle, // PreflightGate allowed the request.
    network, // released by throttle
};

// Process a transfer, passing it through our pipeline. A transfer an move off
// the pipeline(e.g. while parked waiting for a robots.txt check) and then
// pushed back onto it, which is what `from` helps us achieve.
fn pipeline(self: *Client, transfer: *Transfer, from: SubmitFrom) !void {
    sw: switch (from) {
        .start, .redirect => {
            if (comptime lp.IS_TEST) {
                if (self.test_fail_submit) |err| {
                    return err;
                }
            }

            if (self.network.web_bot_auth) |wba| {
                const authority = URL.getHost(transfer.req.url);
                try wba.signRequest(transfer, authority);
            }

            if (self.serve_mode) {
                transfer._notify_cdp = true;
                transfer.notify(.http_request_start, &.{
                    .transfer = transfer,
                    .redirect_response = from == .redirect,
                });

                var wait_for_interception = false;
                transfer.notify(.http_request_intercept, &.{
                    .transfer = transfer,
                    .wait_for_interception = &wait_for_interception,
                });
                if (wait_for_interception) {
                    // The CDP listener stashed the transfer id and will
                    // resolve it via continueIntercepted / fulfillIntercepted
                    // / abortParked.
                    self.intercepted += 1;
                    transfer.park(.intercept_request);
                    if (comptime lp.IS_DEBUG) {
                        log.debug(.http, "wait for interception", .{ .intercepted = self.intercepted });
                    }
                    return;
                }
            }
            continue :sw SubmitFrom.after_intercept;
        },
        .after_intercept => {
            if (self.isUrlBlocked(transfer)) {
                log.info(.http, "blocked url", .{ .url = transfer.req.url });
                return transfer.failAsync(error.UrlBlocked);
            }

            if (transfer.req.internal == false) {
                try setOriginHeader(transfer);
            }

            if (self.obey_cors and !transfer.req.internal) {
                if (!isCrossOriginModeAllowed(transfer)) {
                    log.warn(.http, "blocked by mode", .{
                        .url = transfer.req.url,
                        .mode = @tagName(transfer.req.request_mode),
                    });
                    return transfer.failAsync(error.ModeBlocked);
                }

                switch (try self.cors.check(transfer)) {
                    .allowed => {},
                    .pending => return,
                }
            }
            continue :sw SubmitFrom.after_cors;
        },
        .after_cors => {
            if (try self.cacheLookup(transfer)) {
                return;
            }

            if (self.obey_robots and !transfer.req.internal) {
                switch (try self.robots.check(transfer)) {
                    .allowed => {
                        lp.metrics.robots_access.incr(.allow);
                    },
                    .blocked => {
                        lp.metrics.robots_access.incr(.deny);
                        return transfer.failAsync(error.RobotsBlocked);
                    },
                    .pending => return,
                }
            }
            continue :sw SubmitFrom.after_robots;
        },
        .after_robots => {
            // Cross-origin fetch()/XHR outside the CORS safelist has to be
            // announced with an OPTIONS before it goes out. Same shape as the
            // robots gate above: answered from cache, or parked until the
            // preflight resolves. Unconditional, unlike CorsGate above: Chrome
            // preflights whether or not anyone asked it to, and not sending the
            // OPTIONS is visible on the wire.
            switch (try self.preflight.check(transfer)) {
                .allowed => {},
                .pending => return,
            }
            continue :sw SubmitFrom.throttle;
        },
        .throttle => {
            // Last because we only want to reserve a slot for a request we
            // intend to actually send out (e.g. not cached, not blocked by
            // robots, not answered by request intercetion)
            if (transfer.req.throttle) {
                if (self.network.rate_limiter) |*rl| {
                    const now = lp.datetime.milliTimestamp(.boot);
                    const run_at = try rl.reserve(URL.getHostname(transfer.req.url), now);
                    if (run_at > now) {
                        const d = run_at - now;
                        lp.metrics.http_navigation_delay_ms.observe(@intCast(d));
                        log.debug(.http, "navigation delayed", .{ .url = transfer.req.url, .ms = d });
                        return self.delay(transfer, run_at);
                    }
                }
            }
            continue :sw SubmitFrom.network;
        },
        .network => try self.processTransfer(transfer),
    }
}

// A cors request always carries an Origin. Everything else only carries one
// for an unsafe method - same origin or not. Can't go in CorsGate since it can
// be disabled.
fn setOriginHeader(transfer: *Transfer) !void {
    const req = &transfer.req;

    const cross_origin = transfer._cors_origin_tainted or blk: {
        const origin = req.origin orelse break :blk true;
        break :blk URL.isSameOrigin(req.url, origin) == false;
    };

    const cors_tainted = cross_origin and switch (req.request_mode) {
        .cors, .same_origin => true,
        // A navigation is never cors-tainted. Chrome only sends an Origin on
        // an unsafe one (a form POST), which the method check below covers.
        .no_cors, .navigate => false,
    };

    const unsafe_method = req.method != .GET and req.method != .HEAD;
    if (cors_tainted == false and unsafe_method == false) {
        // A 301/302/303 rewrites the method to GET, leaving the previous hop's
        // Origin behind. Only drop one we put there ourselves.
        for (transfer.req_headers.items, 0..) |hdr, i| {
            if (hdr.source == .user_agent and std.ascii.eqlIgnoreCase(hdr.name, "origin")) {
                _ = transfer.req_headers.orderedRemove(i);
                break;
            }
        }
        return;
    }

    try transfer.setHeader("Origin", transfer.effectiveOrigin(), .{});
}

// PreflightGate resumption. The preflight gate hands an allowed transfer to
// the throttle, which is the last step before the network.
pub fn resumeAfterPreflight(self: *Client, transfer: *Transfer) !void {
    return self.pipeline(transfer, .throttle);
}

// RobotsGate resumption.
pub fn resumeAfterRobots(self: *Client, transfer: *Transfer) !void {
    return self.pipeline(transfer, .throttle);
}

// CorsGate resumption after a preflight resolves as allowed. Re-enters
// right after the CORS step (not .after_intercept)
pub fn resumeAfterCors(self: *Client, transfer: *Transfer) !void {
    return self.pipeline(transfer, .after_cors);
}

pub fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
            return hdr.value;
        }
    }
    return null;
}

// Returns true if the request was served from the cache (response buffered
// for dispatch). On a miss the transfer is tagged so completion can store
// the response; on an expired-with-validators entry the request becomes a
// conditional revalidation.
fn cacheLookup(self: *Client, transfer: *Transfer) !bool {
    const cache = self.cache.active() orelse return false;

    const req = &transfer.req;
    if (req.method != .GET or req.streaming or req.skip_cache) {
        return false;
    }

    // A request already carrying its own validators (e.g. a script-set
    // If-None-Match) should reach the server as-is. The script may be doing its
    // own caching, and if we inject our own headers and our own interpretation,
    // we can cause issues for the script (e.g. we respond with a 200 from our
    // cache, the server repaints the page because it didn't get the correct 304
    // that the upstream would have returned).
    if (transfer.findRequestHeader("If-None-Match") != null or transfer.findRequestHeader("If-Modified-Since") != null) {
        return false;
    }

    const arena = transfer.arena;

    // Redirects rewrite req.url; the entry must be stored/renewed under the
    // URL this lookup ran against, not the final hop. req.url is arena-owned,
    // so the captured slice outlives any redirect rewrite.
    const key: [:0]const u8 = if (req.headers_only)
        try std.fmt.allocPrintSentinel(arena.allocator(), "headers-only:{s}", .{req.url}, 0)
    else
        req.url;
    transfer._cache_key = key;

    const req_headers = try arena.alloc(http.Header, transfer.req_headers.items.len);
    for (transfer.req_headers.items, req_headers) |hdr, *out| {
        out.* = .{ .name = hdr.name, .value = hdr.value };
    }

    const cache_result = cache.get(arena.allocator(), .{
        .url = key,
        .timestamp = lp.datetime.timestamp(.real),
        .request_headers = req_headers,
    }) catch |e| blk: {
        log.err(.cache, "failed to get", .{ .url = req.url, .err = e });
        break :blk .miss;
    };

    switch (cache_result) {
        .hit => |cached| {
            lp.metrics.http_cache.incr(.hit);
            try transfer.bufferCached(cached, .local);
            return true;
        },
        .revalidate => |cached| {
            log.debug(.cache, "revalidate cache entry", .{
                .url = key,
                .etag = cached.etag,
                .last_modified = cached.last_modified,
            });
            if (cached.etag) |etag| {
                try transfer.setHeader("If-None-Match", etag, .{});
            }
            if (cached.last_modified) |lm| {
                try transfer.setHeader("If-Modified-Since", lm, .{});
            }
            transfer._cache_intent = .{ .revalidate = cached };
            return false;
        },
        .miss => {
            lp.metrics.http_cache.incr(.miss);
            transfer._cache_intent = .store;
            return false;
        },
        .stale => {
            lp.metrics.http_cache.incr(.miss);
            cache.evict(key);
            transfer._cache_intent = .store;
            return false;
        },
    }
}

// 304 on a revalidation: renew the stored entry from the fresh headers and
// serve the stale copy. Returns true if the stale entry became the response.
fn cacheRevalidated(self: *Client, transfer: *Transfer) !bool {
    if (transfer._cache_intent != .revalidate) {
        return false;
    }
    const rh = transfer.res.header orelse return false;
    if (rh.status != 304) {
        return false;
    }
    // could have been disabled in-between
    const cache = self.cache.active() orelse return false;

    const stale = transfer._cache_intent.revalidate;
    transfer._cache_intent = .none;

    cache.renew(transfer.arena.allocator(), .{
        .url = transfer._cache_key,
        .timestamp = lp.datetime.timestamp(.real),
        .headers = transfer.res.headers,
    }) catch |err| {
        log.warn(.cache, "renew failed", .{ .err = err });
    };

    lp.metrics.http_cache.incr(.revalidated);
    try transfer.bufferCached(stale, .validated);
    return true;
}

// Store a cacheable response at completion, from the materialized response
// headers and the buffered body. Failures are logged, never fatal — the
// consumer gets its response either way.
fn cacheStore(self: *Client, transfer: *Transfer) void {
    switch (transfer._cache_intent) {
        .none => return,
        .store => {},
        .revalidate => |stale| {
            // Not a 304: the stored entry is out of date. Drop it and store
            // the fresh response below.
            stale.data.deinit();
        },
    }
    // Cleared with the release above: deinit must not release the stale
    // entry a second time on any early return below.
    transfer._cache_intent = .none;

    // could have been disabled while waiting of the response
    const cache = self.cache.active() orelse return;

    const arena = transfer.arena;
    const rh = &(transfer.res.header orelse return);
    const headers = transfer.res.headers;

    const vary = findHeader(headers, "vary");
    const maybe_req = Cache.tryCache(
        arena.allocator(),
        lp.datetime.timestamp(.real),
        transfer._cache_key,
        rh.status,
        rh.contentType(),
        findHeader(headers, "cache-control"),
        vary,
        findHeader(headers, "age"),
        findHeader(headers, "etag"),
        findHeader(headers, "last-modified"),
        findHeader(headers, "set-cookie") != null,
        findHeader(headers, "authorization") != null,
    ) catch |err| {
        log.warn(.http, "cache eligibility", .{ .err = err });
        return;
    };
    var req = maybe_req orelse return;

    var vary_headers: std.ArrayList(http.Header) = .empty;
    if (vary) |vary_str| {
        for (transfer.req_headers.items) |hdr| {
            var vary_iter = std.mem.splitScalar(u8, vary_str, ',');
            while (vary_iter.next()) |part| {
                const name = std.mem.trim(u8, part, &std.ascii.whitespace);
                if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                    // name/value already live in transfer.arena
                    vary_headers.append(arena.allocator(), .{
                        .name = hdr.name,
                        .value = hdr.value,
                    }) catch return;
                }
            }
        }
    }

    req.headers = headers;
    req.vary_headers = vary_headers.items;

    if (comptime lp.IS_DEBUG) {
        log.debug(.browser, "http cache", .{ .key = transfer._cache_key, .put = req });
    }
    cache.put(req, transfer.res.buffer.items) catch |err| {
        log.warn(.http, "cache put failed", .{ .err = err });
    };
}

const SyncContext = struct {
    client: *Client,
    completion: union(enum) {
        in_progress: void,
        done: void,
        err: anyerror,
        shutdown: void,
    } = .in_progress,

    status: u16 = 0,
    body: std.ArrayList(u8),

    // Read here rather than after the wait: the connection it comes off is
    // gone by the time syncRequest returns.
    next_hop_protocol: []const u8 = "",

    // Same reason, one callback later: the encoded size is only final once the
    // body has arrived.
    encoded_body_size: u64 = 0,

    // contentType / contentEncoding for the resource entry the caller files.
    labels: ResponseLabels = .{},

    // The connection walk, same reason.
    times: ResponseTimes = .{},

    // Acquired on the first byte we have to buffer, so a bodyless response
    // never takes one. Ownership moves to the SyncResponse.
    arena: ?*lp.Arena = null,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *SyncContext = @ptrCast(@alignCast(transfer.req.ctx));
        lp.assert(transfer.responseStatus() != null, "HttpClient.SyncRequest.headerCallback", .{ .value = transfer.responseStatus() });
        self.status = transfer.responseStatus().?;
        self.next_hop_protocol = transfer.nextHopProtocol();
        self.labels = transfer.responseLabels();
        self.times = transfer.responseTimes();
        if (transfer.getContentLength()) |cl| {
            try self.body.ensureTotalCapacityPrecise(try self.bodyAllocator(cl), cl);
        }
        return .proceed;
    }

    fn bodyAllocator(self: *SyncContext, content_length: ?usize) !Allocator {
        if (self.arena) |arena| {
            return arena.allocator();
        }
        const arena = if (content_length) |cl|
            try self.client.arena_pool.acquire(cl, "syncRequest.body")
        else
            try self.client.arena_pool.acquire(.large, "syncRequest.body");
        self.arena = arena;
        return arena.allocator();
    }

    fn dataCallback(transfer: *Transfer, data: []const u8) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(transfer.req.ctx));
        self.encoded_body_size = transfer.encodedBodySize();
        try self.body.appendSlice(try self.bodyAllocator(null), data);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .done;
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .{ .err = err };
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .shutdown;
    }
};

fn processTransfer(self: *Client, transfer: *Transfer) !void {
    if (self.network.getConnection()) |conn| {
        return self.makeRequest(conn, transfer);
    }

    self.pending_queue.append(&transfer._node);
    transfer.state = .queued;
}

// A blocking request is complete. Any completed transfer that was placed in the
// gated_queue because of it can now be placed back in the dispatch queue.
fn releaseBlocking(self: *Client, frame_id: u32) void {
    _ = self.blocking_requests.remove(frame_id);
    // items were added to the gate in order, so walking backwards restores that
    // order. (Order might not matter, but preserving it costs nothing)

    // No callback is executed here. Nothing mutates our queues, so iterating
    // it this way is safe.
    var node = self.gated_queue.last;
    while (node) |n| {
        node = n.prev;
        const transfer: *Transfer = @fieldParentPtr("_queue_node", n);
        if (transfer.req.frame_id != frame_id) {
            continue;
        }
        transfer._gated = false;
        self.gated_queue.remove(n);
        self.dispatch_queue.prepend(n);
    }
}

fn makeRequest(self: *Client, conn: *http.Connection, transfer: *Transfer) anyerror!void {
    {
        // Reset per-response state for retries (auth challenge, queue).
        const auth = transfer._auth_challenge;
        transfer.reset();
        transfer._auth_challenge = auth;

        // conn is locally held during configure; we don't write it to
        // `transfer._conn` until trackConn commits it to the multi
        // handle. If configureConn fails, release the conn back to the
        // pool — `transfer.state` stays `.created`, and the caller
        // (Client.request's errdefer or drainQueue's catch) aborts
        // the transfer.
        errdefer self.releaseConn(conn);

        try transfer.configureConn(conn);
    }

    // As soon as trackConn succeeds, the multi handle owns the transfer's
    // lifecycle. perform/processMessages will eventually invoke completion
    // callbacks and call transfer.deinit.
    self.trackConn(conn) catch |err| {
        self.releaseConn(conn);
        return err;
    };
    transfer._conn = conn;
    transfer.state = .inflight;
    transfer._timing.hop_start = lp.datetime.microTimestamp(.boot);

    // Start the request (and move along any other request).
    _ = try self.handles.perform();
}

pub fn drainTerminal(self: *Client) !void {
    return self.drainInbox(.terminal);
}

// Drain any client messages the Network thread pushed into our inbox
// and dispatch them via the driver callbacks. Returns
// error.ClientDisconnected if the inbox surfaced a disconnect message,
// so the worker loop can tear down the connection. Called from tick
// only — NOT from perform, because perform recurses through
// processOneMessage's redirect path.
fn drainInbox(self: *Client, mode: DrainMode) !void {
    const driver = &(self.driver orelse return);
    const inbox = driver.inbox;
    while (true) {
        const msg = switch (mode) {
            .all => inbox.pop(),
            .sync_wait => inbox.popIf(allowDuringSyncWait),
            .terminal => inbox.popIf(isTerminal),
        } orelse return;

        defer msg.deinit();

        switch (msg.payload) {
            .cdp, .bidi => driver.onMessage(msg) catch |err| {
                // A single malformed/failed dispatch shouldn't poison
                // the rest of the batch — log and continue.
                log.err(.app, "client dispatch", .{ .err = err });
            },
            .ping => |body| driver.onPing(body),
            .close => {
                driver.onClose();
                self.disconnected = true;
                return error.ClientDisconnected;
            },
            .disconnect => |err| {
                driver.onDisconnect(err);
                self.disconnected = true;
                return error.ClientDisconnected;
            },
        }
    }
}

// Predicate for Inbox.popIf during sync_wait drains. Always allows
// ping/close/disconnect (control frames must be observed). CDP data
// messages are filtered: only the four Fetch interception methods
// are safe to dispatch from inside a JS callback (they mutate
// transfer state via the interception gate; they don't touch page /
// session / V8 state). The check is exact on the parsed `method`
// field — no substring matching against raw JSON.
//
// Every method listed here must be safe to dispatch with
// JS on the stack — meaning it must NO reach any other code
// path that frees Page/Session/Frame/Worker state the unwinding
// eval frame above us will dereference.
fn allowDuringSyncWait(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .ping, .close, .disconnect => true,
        .cdp => |c| isFetchInterceptionMethod(c.input.method),
        // BiDi has no request interception yet, so nothing it can send is
        // safe to dispatch from inside a JS callback.
        .bidi => false,
    };
}

fn isTerminal(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .close, .disconnect => true,
        .ping, .cdp, .bidi => false,
    };
}

fn isFetchInterceptionMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "Fetch.continueRequest") or
        std.mem.eql(u8, method, "Fetch.failRequest") or
        std.mem.eql(u8, method, "Fetch.fulfillRequest") or
        std.mem.eql(u8, method, "Fetch.continueWithAuth");
}

// True for inbox messages that mean "this page/connection is going away".
// syncRequest uses this to bail out of a blocking-script wait promptly
// rather than holding the worker for the per-request timeout while a
// teardown command sits undispatched behind the sync_wait allowlist.
fn isSyncWaitInterrupt(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .close, .disconnect => true,
        .ping => false,
        .cdp => |c| isTeardownMethod(c.input.method),
        // Frames aren't parsed on the Network thread for BiDi, so we
        // can't spot a teardown command without re-parsing here.
        .bidi => false,
    };
}

fn isTeardownMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "Target.closeTarget") or
        std.mem.eql(u8, method, "Target.disposeBrowserContext") or
        std.mem.eql(u8, method, "Page.close");
}

pub fn isRedirectStatus(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

fn processMessages(self: *Client) !bool {
    var processed = false;
    while (try self.handles.readMessage()) |msg| {
        switch (msg.conn.transport) {
            .http => |transfer| {
                // On success, processOneMessage owns the transfer's fate: it
                // either buffered it for dispatch, parked it, or deinit'd it.
                // Only the throw path cleans up here.
                const done = self.processOneMessage(msg, transfer) catch |err| blk: {
                    log.err(.http, "process_messages", .{ .err = err, .req = transfer });
                    if (transfer._conn) |c| {
                        self.removeConn(c);
                        transfer._conn = null;
                    }
                    // Fail through the dispatcher — error_callback must not
                    // run user code from the pump; it would bypass the
                    // blocking gate (see dispatchCompleted).
                    transfer.failAsync(err);
                    break :blk true;
                };
                if (done) {
                    processed = true;
                }
            },
            .websocket => |ws| {
                // Releases the conn now (decrementing ws_active); the JS
                // close/error events are buffered for dispatchCompleted.
                if (msg.err) |err| switch (err) {
                    error.GotNothing => ws.transportClosed(null),
                    else => ws.transportClosed(err),
                } else {
                    // Clean close - no error
                    ws.transportClosed(null);
                }

                processed = true;
            },
            .none => unreachable,
        }
    }
    return processed;
}

fn enforceCorsResponse(self: *Client, msg: http.Handles.MultiMessage, transfer: *Transfer) bool {
    if (!(transfer._cors_cross_origin and transfer.req.request_mode == .cors)) {
        return false;
    }
    CorsGate.validateResponse(transfer) catch |err| {
        self.removeConn(msg.conn);
        transfer._conn = null;
        transfer.failAsync(err);
        return true;
    };
    return false;
}

fn processOneMessage(self: *Client, msg: http.Handles.MultiMessage, transfer: *Transfer) !bool {
    // Workaround for libcurl Brotli trailing-byte rejection.
    //
    // Some CDNs (e.g. CloudFront serving Brave Search) emit a Brotli stream
    // whose compressed payload has 1+ trailing bytes after the logical end.
    // The Brotli decoder reports BROTLI_DECODER_RESULT_SUCCESS, but libcurl's
    // brotli_do_write() (content_encoding.c:439) treats any unconsumed input
    // bytes as CURLE_WRITE_ERROR. All decompressed body data has already been
    // delivered to our write callback successfully.
    //
    // Browsers accept such responses (the decompressed content is valid), so
    // we match that behavior: when CURLE_WRITE_ERROR arrives but our callback
    // never errored and bytes were received, treat it as success.
    const effective_err: ?anyerror = if (msg.err) |err| blk: {
        // Our own headers_only abort, not a failure: fall through so the
        // response is materialized and delivered with an empty body.
        if (err == error.WriteError and transfer.res.headers_only_abort) {
            break :blk null;
        }
        if (err == error.WriteError and transfer.res.callback_error == null and transfer.res.bytes_received > 0) {
            log.debug(.http, "WriteError downgraded", .{ .url = transfer.req.url, .bytes = transfer.res.bytes_received });
            break :blk null;
        }
        break :blk err;
    } else null;

    if (transfer.state == .aborted) {
        // A streaming transfer's callback aborted it mid-deliver and a
        // nested pump saw the completion; there is nothing to deliver and
        // nobody else owns the transfer anymore.
        self.removeConn(msg.conn);
        transfer._conn = null;
        transfer.deinit();
        return true;
    }

    // A streaming response that has emitted events is committed: its header
    // (and data) already reached the consumer, so it can't be transparently
    // retried as an auth challenge — don't even offer it to CDP, parking it
    // would strand the already-queued events.
    if (!transfer.res.stream.started and (effective_err == null or effective_err.? == error.RecvError)) {
        transfer.detectAuthChallenge(msg.conn);
    }

    // In case of auth challenge
    // TODO give a way to configure the number of auth retries.
    if (transfer._auth_challenge != null and transfer._tries < 10) {
        var wait_for_interception = false;
        transfer.notify(
            .http_request_auth_required,
            &.{ .transfer = transfer, .wait_for_interception = &wait_for_interception },
        );
        if (wait_for_interception) {
            self.intercepted += 1;
            if (comptime lp.IS_DEBUG) {
                log.debug(.http, "wait for auth interception", .{ .intercepted = self.intercepted });
            }

            // Whether or not this is a blocking request, we're not going
            // to process it now. We can end the transfer, which will
            // release the easy handle back into the pool. The transfer
            // is still valid/alive (just has no handle); park it for
            // continueWithAuth.
            self.removeConn(transfer._conn.?);
            transfer._conn = null;
            transfer.state = .{ .parked = .intercept_auth };
            return false;
        }
    }

    // Handle redirects: reuse the same connection to preserve TCP state.
    // A redirect status without a Location header is not a redirect, it's a
    // final response and falls through so its body is delivered.
    // When the server closes the TLS connection without a close_notify alert,
    // BoringSSL reports RecvError. If we already received valid HTTP headers,
    // this is a normal end-of-body (the connection closure signals the end
    // of the response per HTTP/1.1 when there is no Content-Length).
    // We must check this before endTransfer, which may reset the easy handle.
    const is_conn_close_recv = blk: {
        const err = effective_err orelse break :blk false;
        if (err != error.RecvError) break :blk false;
        const hdr = msg.conn.getResponseHeader("connection", 0) orelse break :blk true;
        break :blk std.ascii.eqlIgnoreCase(hdr.value, "close");
    };

    if (effective_err == null or is_conn_close_recv) {
        const status = try msg.conn.getResponseCode();
        if (isRedirectStatus(status)) {
            if (msg.conn.getResponseHeader("location", 0)) |location| switch (transfer.req.redirect) {
                .follow => {
                    transfer.restoreInterceptHeaders();
                    // Preserve the completed 3xx response until the redirected
                    // requestWillBeSent event has been serialized. Will be
                    // reset() in makeRequest.
                    try transfer.materializeResponse(msg.conn, .{ .check_content_length = false });
                    if (self.enforceCorsResponse(msg, transfer)) return true;

                    try transfer.handleRedirect(location.value);

                    if (!transfer.req.internal) {
                        lp.metrics.http_redirects.incr();
                    }

                    // The multi should keep this alive. Releasing it now makes
                    // it so we can re-enter the pipeline and keeps the code
                    // streamlined.
                    self.removeConn(msg.conn);
                    transfer._conn = null;
                    transfer.state = .created;

                    // We have to restart (.redirect == .start) the whole
                    // pipeline, rechecking the cache/robot/ratelimit/...
                    try self.pipeline(transfer, .redirect);
                    return true;
                },
                // error_callback surfaces this as a TypeError.
                .@"error" => {
                    self.removeConn(msg.conn);
                    transfer._conn = null;
                    transfer.failAsync(error.RedirectNotAllowed);
                    return true;
                },
                // Don't follow; fall through to deliver the 3xx as the final
                // response, which the fetch layer turns into an opaque redirect.
                .manual => {},
            };
        }
    }

    // Transfer is done (success or error). Materialize the response into the
    // transfer's arena, release the conn, and buffer the events — user
    // callbacks run later, from dispatch(), never from here.

    if (effective_err != null and !is_conn_close_recv) {
        self.removeConn(msg.conn);
        transfer._conn = null;
        transfer.failAsync(transfer.res.callback_error orelse effective_err.?);
        return true;
    }

    try transfer.materializeResponse(msg.conn, .{});
    if (self.enforceCorsResponse(msg, transfer)) return true;

    // Critical-CH: the origin has just told us this response was computed for a
    // client it now knows we aren't. Throw it away and re-send the navigation
    // with the hints attached, on the same conn, the way a redirect hop is
    // re-sent. Capped at one restart by _critical_hints_restarted.
    //
    // Nothing has been delivered yet -- the response events are buffered below,
    // and CDP's are dispatched from deliver() -- so the discarded response
    // leaves no trace with the consumer. Chrome shows the restart as a second
    // request in devtools; we don't, which is a devtools difference and not a
    // wire one.
    if (transfer.shouldRestartForCriticalHints()) {
        transfer._critical_hints_restarted = true;
        try transfer.seedClientHints();

        try self.handles.remove(msg.conn);
        // Conn temporarily out of the multi while it is reconfigured;
        // _detached_conn lets processMessages release it if a step throws.
        transfer._detached_conn = msg.conn;

        transfer.reset();
        try transfer.configureConn(msg.conn);
        try self.handles.add(msg.conn);
        transfer._detached_conn = null;

        _ = try self.handles.perform();
        return false;
    }

    // Latency is only meaningful for responses that hit the network (cache
    // and synthetic responses never reach processOneMessage).
    if (!transfer.req.internal) {
        if (msg.conn.getTotalTimeMicros()) |micros| {
            lp.metrics.http_duration_ms.observe(@intCast(@max(0, @divTrunc(micros, 1000))));
        } else |_| {}
    }

    // The authoritative reading, taken while the conn is still ours: the
    // per-chunk one above stops at the last chunk, and a bodyless response has
    // no chunks at all.
    transfer.res.encoded_body_size = msg.conn.getEncodedBodySize() catch transfer.res.encoded_body_size;

    // Release the conn before any of this response's callbacks can run —
    // they'll want it for the next resource.
    self.removeConn(msg.conn);
    transfer._conn = null;

    if (try self.cacheRevalidated(transfer)) {
        return true;
    }
    self.cacheStore(transfer);

    transfer._content_length = transfer.getContentLength() orelse 0;
    try transfer.bufferEvents(transfer.res.buffer.items);
    return true;
}

// Commit a configured conn to the multi handle. On error the conn is left
// with the caller (makeRequest's catch and WebSocket.init's errdefer
// release it).
pub fn trackConn(self: *Client, conn: *http.Connection) !void {
    // Set private pointer so readMessage can find the Connection.
    // Must be done each time since curl_easy_reset clears it when
    // connections are returned to pool.
    try conn.setPrivate(conn);
    try self.handles.add(conn);

    self.in_use.append(&conn.node);
    switch (conn.transport) {
        .http => self.http_active += 1,
        .websocket => self.ws_active += 1,
        else => unreachable,
    }
}

pub fn removeConn(self: *Client, conn: *http.Connection) void {
    self.in_use.remove(&conn.node);
    switch (conn.transport) {
        .http => self.http_active -= 1,
        .websocket => self.ws_active -= 1,
        else => unreachable,
    }
    // User code never runs inside perform anymore, so this can't be a
    // mid-perform removal; a failure here is a usage bug.
    self.handles.remove(conn) catch |err| {
        lp.assert(false, "multi_remove_handle", .{ .err = err });
    };
    self.releaseConn(conn);
}

fn releaseConn(self: *Client, conn: *http.Connection) void {
    self.network.releaseConnection(conn);
}

fn ensureNoActiveConnection(self: *const Client) !void {
    if (self.http_active > 0 or self.ws_active > 0) {
        return error.InflightConnection;
    }
}

pub const Request = struct {
    pub const StartCallback = *const fn (transfer: *Transfer) anyerror!void;
    pub const HeaderCallback = *const fn (transfer: *Transfer) anyerror!Transfer.HeaderResult;
    pub const DataCallback = *const fn (transfer: *Transfer, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    pub const ResourceType = enum {
        document,
        xhr,
        script,
        // A dedicated worker's script. Chrome fetches it with
        // `Sec-Fetch-Dest: worker` rather than `script`, and carries no client
        // hints on it (measured, scratch/b120/blob-chrome.json).
        worker,
        fetch,
        stylesheet,
        image,
        eventsource,
        // Only `<link rel=preload as=font>` reaches this today -- nothing here
        // loads a font face. Chrome answers `Sec-Fetch-Dest: font`, `Accept:
        // */*` and `priority: u=1` for it, all measured over h2
        // (probes/b87-preload-priority-h2.mjs).
        font,

        // Allowed Values: Document, Stylesheet, Image, Media, Font, Script,
        // TextTrack, XHR, Fetch, Prefetch, EventSource, WebSocket, Manifest,
        // SignedExchange, Ping, CSPViolationReport, Preflight, FedCM, Other
        // https://chromedevtools.github.io/devtools-protocol/tot/Network/#type-ResourceType
        pub fn string(self: ResourceType) []const u8 {
            return switch (self) {
                .document => "Document",
                .xhr => "XHR",
                .script => "Script",
                // CDP has no worker resource type; Chrome reports the script
                // fetch as a Script there too.
                .worker => "Script",
                .fetch => "Fetch",
                .stylesheet => "Stylesheet",
                .image => "Image",
                .eventsource => "EventSource",
                .font => "Font",
            };
        }
    };

    // Fetch request redirect mode. `.follow` keeps navigations, XHR and
    // internal requests transparently following redirects.
    pub const RedirectMode = enum { follow, manual, @"error" };

    // Fetch request mode, as Sec-Fetch-Mode reports it. Every request has one
    // by destination; `Request.mode` overrides that default for the loads whose
    // mode is not implied by what they are fetching.
    //
    // Four values, all four measured coming out of Chrome
    // (tools/fingerprint/scratch/b118/fm-chrome.json crosses mode against
    // cross-siteness and method; `navigate` is the document row of the older
    // captures). `same_origin` is only reachable through `fetch(u, {mode:
    // 'same-origin'})`, and only same-origin: Chrome does not put such a
    // request on the wire at all when it points elsewhere.
    pub const Mode = enum { navigate, no_cors, cors, same_origin };

    // Upstream's name for the same thing, so its CORS machinery reads the
    // one enum rather than a second that can drift from it.
    pub const RequestMode = Mode;

    // The RequestInit `cache` member, which Chrome turns into a Cache-Control
    // (and sometimes a Pragma) on the wire. Only fetch() can set one; every
    // other load is `default`.
    pub const CacheMode = enum { default, no_store, reload, no_cache, force_cache, only_if_cached };

    // Where this request sits in the storage partition tree, which is what
    // Sec-Fetch-Storage-Access reports. Filled by the frame that asks for the
    // request; null on the loads with no document behind them at all (a
    // preflight, robots.txt, the web-bot-auth probe), which Chrome does not
    // send the field on either.
    pub const Partition = struct {
        // The top-level document's URL. The partition key: a request whose own
        // URL is cross-site with this one carries partitioned cookies.
        top_level_url: []const u8,
        // The asking document is itself not same-site with the top-level one --
        // Chrome's ancestor-chain bit. Such a document's requests are
        // partitioned even when they point back AT the top-level site, which is
        // the row that separates this from a plain cross-site test (measured,
        // `/sub/back-to-top-from-cross-site-frame` in
        // tools/fingerprint/scratch/b117/sa-chrome-p2.json).
        third_party_client: bool = false,
    };

    // Fetch-metadata inputs for a document request that only the navigating
    // frame knows. Absent on subresources, where cookie_origin and
    // resource_type are enough.
    pub const Navigation = struct {
        // null means the navigation had no initiator document — an address-bar
        // or bookmark navigation — which is what Sec-Fetch-Site: none reports.
        // Distinct from a same-origin navigation, so it cannot be derived from
        // cookie_origin (which falls back to the target URL).
        initiator_origin: ?[]const u8 = null,
        // Sec-Fetch-Dest: iframe rather than document.
        subframe: bool = false,
        // Sec-Fetch-User: ?1 — set when a user gesture caused the navigation.
        user_activated: bool = false,
    };

    // How much of a headers_only body we'll read rather than abort. Draining
    // costs bandwidth but keeps the connection poolable; aborting saves
    // bandwidth but forces a reconnect. 16 KiB is the rough break-even: about
    // ten segments, versus a TCP handshake plus a TLS one.
    const HEADERS_ONLY_DRAIN_MAX: usize = 16 * 1024;

    pub const CredentialsMode = enum {
        // Never send credentials, even same-origin.
        omit,
        // Send credentials only for same-origin requests.
        same_origin,
        // Always send credentials, including cross-origin.
        include,
    };

    method: Method,
    url: [:0]const u8,
    body: ?[]const u8 = null,
    resource_type: ResourceType,
    cache: CacheMode = .default,
    // Issued from inside a worker rather than from a document. Only the client
    // hints read it: a worker's requests carry none.
    from_worker: bool = false,
    // Only meaningful when resource_type == .document.
    nav: ?Navigation = null,
    partition: ?Partition = null,

    // A subresource whose element carried `crossorigin`, which puts the load
    // in CORS mode: it announces an Origin and says `cors` in Sec-Fetch-Mode
    // where a bare <script src>, <img> or stylesheet says `no-cors` and names
    // nobody. Only meaningful for .script, .stylesheet and .image -- fetch, XHR
    // and EventSource are CORS mode by construction, and a document navigation
    // is neither.
    //
    // Measured (probes/b87-crossorigin-request-fixture.mjs, twenty rows over
    // two rounds and two origins): Chrome appends the Origin for these even
    // when the load is SAME-origin, which is where they part company with
    // fetch() -- a same-origin GET through fetch carries none.
    //
    // `anonymous` and `use-credentials` are not distinguished. Telling them
    // apart needs a cross-site cookie, which needs SameSite=None; Secure,
    // which needs https, which no fixture here speaks; both spellings read as
    // "CORS mode" until someone can measure the difference.
    cors: bool = false,

    // Overrides the RFC 9218 `priority` hint the destination would otherwise
    // imply. One thing needs it: a preloaded image, which Chrome sends as bare
    // `i` where a real <img> is `u=1, i` -- the preload is not on screen, so it
    // never gets the urgency a displayed image does (measured over h2 three
    // times, probes/b87-preload-priority-h2.mjs).
    priority: ?[]const u8 = null,

    // Overrides the mode this request's destination would otherwise imply.
    // Only one thing needs it today: `<link rel=preload as=fetch>`, whose
    // destination is `empty` -- the same as a real fetch() -- but which Chrome
    // sends no-cors, where a real fetch() is always cors (measured,
    // probes/b87-preload-as-fixture.mjs). Left null everywhere else, so the
    // per-destination defaults below stay the single description of the rule.
    mode: ?Mode = null,
    redirect: RedirectMode = .follow,
    referrer_policy: ?referrer.Policy = null,
    basic_auth_credentials: ?[:0]const u8 = null,
    credentials_mode: CredentialsMode,
    request_mode: RequestMode,
    timeout_ms: u32 = 0,
    skip_cache: bool = false,

    // The caller wants the status and the response headers, not the body.
    // Unlike a HEAD, the request itself is byte-for-byte a normal GET, so
    // origins and CDNs see (and answer) exactly what a real browser sends;
    // the body is then discarded, and torn off the wire if it doesn't fit in
    // HEADERS_ONLY_DRAIN_MAX. The consumer still gets the usual
    // start/header/done sequence, with an empty body; `data_callback` never
    // fires.
    headers_only: bool = false,

    // Should only be set when they need to differ from the owner's.
    frame_id: u32 = 0,
    loader_id: u32 = 0,
    // The document frame this request belongs to. Differs from frame_id for
    // Workers.
    document_frame_id: ?u32 = null,
    notification: ?*Notification = null,

    // The site for SameSite checks. null = the owner's (Owner.siteForCookies).
    // Frame.navigate is the one caller with a reason to override it: the
    // initiator of a top-level navigation isn't the frame being navigated.
    cookie_origin: ?Cookie.SiteForCookies = null,

    // The Origin of the Request.
    origin: ?[]const u8,

    // Requests that are internal to the browser and skip various layers,
    // these do not need to be deferred and do not obey robots.txt.
    internal: bool = false,

    // The internal OPTIONS a PreflightGate sends. Chrome writes a preflight
    // with neither the client hints nor the field order of the request it is
    // asking about, so seedHeaders and emitHeaders both need to know.
    preflight: bool = false,
    // Whether this request should (possibly) be throttled based on the RateLimiter
    throttle: bool = false,

    // Set by syncRequest; only used to label the http_requests metric.
    sync: bool = false,

    // Deliver the response body progressively: data_callback can fire multiple
    // times. Currently, streaming request always bypass the cache as they are only
    // used for EventSource.
    streaming: bool = false,

    // When false, the caller does not guarantee that the body outlives the
    // transfer, and thus we'll need to dupe it.
    body_outlives_request: bool = false,

    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    start_callback: ?StartCallback = null,
    header_callback: HeaderCallback = Noop.headerCallback,
    data_callback: DataCallback = Noop.dataCallback,
    done_callback: DoneCallback = Noop.doneCallback,
    error_callback: ErrorCallback = Noop.errorCallback,

    // Fired exactly once if the transfer is torn down by its owner (frame /
    // worker teardown, a superseding navigation) before completing. It must
    // drop any stored *Transfer and must not run JS. Deliberately has no
    // default: anyone holding a *Transfer forgets this at their peril, so
    // every caller decides — pass `HttpClient.noopShutdown` to opt out,
    // knowingly.
    shutdown_callback: ShutdownCallback,

    // The mode this request goes out in: `mode` when it was set, and the
    // destination's own default otherwise. A document navigates; a subresource
    // the parser pulls in is no-cors unless its element asked for CORS; a
    // script-issued fetch or XHR goes through the CORS protocol.
    pub fn requestMode(self: *const Request) Mode {
        if (self.mode) |m| {
            return m;
        }
        return switch (self.resource_type) {
            .document => .navigate,
            .stylesheet, .script, .image, .font => if (self.cors) .cors else .no_cors,
            // A classic dedicated worker's script is fetched in same-origin
            // mode (measured; it is also what the spec asks for).
            .worker => .same_origin,
            .fetch, .xhr, .eventsource => .cors,
        };
    }

    pub fn credentialsAllowed(req: *const Request) bool {
        return switch (req.credentials_mode) {
            .omit => false,
            .include => true,
            .same_origin => blk: {
                const origin = req.origin orelse break :blk false;
                break :blk URL.isSameOrigin(req.url, origin);
            },
        };
    }
};

pub const SyncResponse = struct {
    status: u16,
    body: std.ArrayList(u8),

    // The protocol the response arrived over, for the resource entry the
    // caller files. A literal from libcurl, so it needs no arena.
    next_hop_protocol: []const u8 = "",

    // What the body weighed on the wire, which `body.items.len` cannot say for
    // a compressed response: curl hands over the decoded bytes.
    encoded_body_size: u64 = 0,

    // contentType / contentEncoding, held inline so they survive the transfer.
    labels: ResponseLabels = .{},

    // The connection walk behind the response, for the entry's milestones.
    times: ResponseTimes = .{},

    // Owns `body`. Null when the response had nothing to buffer. Callers that
    // keep `body` past this call take the arena instead of releasing it.
    arena: ?*lp.Arena,

    pub fn deinit(self: *SyncResponse) void {
        if (self.arena) |arena| {
            arena.release();
        }
    }
};

// CDP Fetch.continueWithAuth: resume a transfer parked on an auth
// challenge. The auth retry goes straight back to the network — it already
// passed the request-side pipeline on its first attempt.
pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.http, "continue transfer", .{ .intercepted = self.intercepted });
    }

    transfer.unpark();
    self.processTransfer(transfer) catch |err| {
        transfer.abortPipelineError(err);
        return err;
    };
}

// CDP Fetch.continueRequest: resume a transfer parked at the interception
// gate, re-entering the pipeline at the step after interception. The CDP
// command may have mutated req (url / method / headers / body) first.
pub fn continueIntercepted(self: *Client, transfer: *Transfer) !void {
    if (comptime lp.IS_DEBUG) {
        lp.assert(self.intercepted > 0, "Client.continueIntercepted", .{ .value = self.intercepted });
    }

    transfer.unpark();
    self.pipeline(transfer, .after_intercept) catch |err| {
        transfer.abortPipelineError(err);
        return err;
    };
}

// CDP Fetch.fulfillRequest: resolve a parked transfer with an interceptor-
// supplied response. A redirect status with a Location header is followed
// like a real network redirect; anything else is buffered for dispatch —
// the consumer's callbacks never run from the CDP command itself.
pub fn fulfillIntercepted(
    self: *Client,
    transfer: *Transfer,
    status: u16,
    headers: []const http.Header,
    body: ?[]const u8,
) !void {
    if (comptime lp.IS_DEBUG) {
        lp.assert(self.intercepted > 0, "Client.fulfillIntercepted", .{ .value = self.intercepted });
    }

    transfer.unpark();

    const followed = blk: {
        if (isRedirectStatus(status) == false) {
            break :blk false;
        }
        const location = findHeader(headers, "location") orelse break :blk false;
        try self.fulfillRedirect(transfer, status, headers, location);
        break :blk true;
    };

    if (followed) {
        return;
    }

    transfer.bufferFulfilled(status, headers, body) catch |err| {
        transfer.abortPipelineError(err);
        return err;
    };
}

fn fulfillRedirect(
    self: *Client,
    transfer: *Transfer,
    status: u16,
    headers: []const http.Header,
    location: []const u8,
) !void {
    errdefer |err| transfer.abortPipelineError(err);

    // retrieve cookies from the fulfilled response's headers.
    if (transfer.req.credentialsAllowed()) {
        if (transfer.cookie_jar) |jar| {
            for (headers) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) {
                    try jar.populateFromResponse(transfer.req.url, hdr.value);
                }
            }
        }
    }

    transfer.recordRedirectTiming(headers);
    try transfer.applyRedirectTarget(transfer.req.url, location, status);
    try self.pipeline(transfer, .after_intercept);
}

// The explicit opt-out for Request.shutdown_callback, for callers that hold
// no reference to the transfer (or whose cleanup runs through other paths).
pub fn noopShutdown(_: *anyopaque) void {}

const Noop = struct {
    fn headerCallback(_: *Transfer) !Transfer.HeaderResult {
        return .proceed;
    }
    fn dataCallback(_: *Transfer, _: []const u8) !void {}
    fn doneCallback(_: *anyopaque) !void {}
    fn errorCallback(_: *anyopaque, _: anyerror) void {}
};

// Debug-only stubs installed on retirement. Unlike detachInDelivery's Noop
// set (which curl legitimately drains through), nothing may ever invoke a
// callback on a retired transfer.
const Poison = struct {
    fn headerCallback(_: *Transfer) anyerror!Transfer.HeaderResult {
        @panic("callback on retired transfer");
    }
    fn dataCallback(_: *Transfer, _: []const u8) anyerror!void {
        @panic("callback on retired transfer");
    }
    fn doneCallback(_: *anyopaque) anyerror!void {
        @panic("callback on retired transfer");
    }
    fn errorCallback(_: *anyopaque, _: anyerror) void {
        @panic("callback on retired transfer");
    }
    fn shutdownCallback(_: *anyopaque) void {
        @panic("callback on retired transfer");
    }
};

// An opaque-from-the-outside handle that Frame / WorkerGlobalScope embed
// to track the HTTP transfers + WebSockets they own.
pub const Owner = struct {
    transfers: std.DoublyLinkedList = .{},
    websockets: std.DoublyLinkedList = .{},

    // The Page-level blob: URL store, shared by every context on the page.
    blob_urls: *const Blob.UrlMap,

    // The owning Frame's / WorkerGlobalScope's origin slot. Pointer because
    // it can change during navigation.
    origin: *const ?[]const u8,

    // The owning Frame's URL slot, a pointer for the same reason. A worker
    // has none: its site for cookies is its creating document's.
    url: ?*const [:0]const u8,

    // The parent frame's Owner; for a worker, its creating frame's. Outlives
    // this Owner: child frames are torn down before their parent, a worker
    // before its frame. A `.document` request's owner is the frame it
    // navigates, so a parent here is what makes that load a nested frame's;
    // the adblocker tells $document from $subdocument by it.
    parent: ?*const Owner,

    // Copied onto every request made through this owner, see Request.
    frame_id: u32,
    document_frame_id: u32,
    loader_id: u32,
    cookie_jar: *CookieJar,
    performance: *Performance,
    notification: *Notification,

    const Blob = @import("../browser/webapi/Blob.zig");

    /// The URL of the document this owner's requests belong to.
    /// Handles `about:` case also.
    pub fn documentUrl(self: *const Owner) ?[:0]const u8 {
        var source = self;
        while (true) {
            if (source.url) |url| {
                if (!std.mem.startsWith(u8, url.*, "about:")) return url.*;
            }
            source = source.parent orelse return null;
        }
    }

    // RFC 6265bis "site for cookies"
    pub fn siteForCookies(self: *const Owner) Cookie.SiteForCookies {
        var source = self;
        while (source.parent) |parent| : (source = parent) {
            const url = source.url orelse continue;
            if (!std.mem.startsWith(u8, url.*, "about:")) break;
        }
        // Only a worker has no url, and a worker always hangs off a Frame.
        const own_url = source.url.?.*;
        const own_host = URL.getHostname(own_url);

        var owner = source;
        while (owner.parent) |parent| : (owner = parent) {
            const parent_url = parent.url orelse continue;
            const parent_host = URL.getHostname(parent_url.*);
            if (parent_host.len == 0) {
                continue;
            }
            if (Cookie.areHostsSameSite(parent_host, own_host) == false) {
                return .none;
            }
        }
        return .{ .url = own_url };
    }

    pub fn addTransfer(self: *Owner, t: *Transfer) void {
        self.transfers.append(&t.owner_node);
    }

    pub fn removeTransfer(self: *Owner, t: *Transfer) void {
        self.transfers.remove(&t.owner_node);
    }

    pub fn addWS(self: *Owner, ws: *WebSocket) void {
        self.websockets.append(&ws._owner_node);
    }

    pub fn removeWS(self: *Owner, ws: *WebSocket) void {
        self.websockets.remove(&ws._owner_node);
    }
};

pub const Transfer = struct {
    id: u32 = 0,
    arena: *lp.Arena,

    owner: ?*Owner,
    owner_node: std.DoublyLinkedList.Node = .{},

    // The transfer's lifecycle position. Source of truth for
    // "is this committed?" and "can we deinit synchronously?".
    // The conn the transfer holds (if any) is tracked separately
    // in `_conn` — orthogonal to state. See `State` below.
    state: State = .created,

    // Conn the transfer currently holds. Set when makeRequest commits
    // the conn to the multi handle; cleared by the "release ASAP" step
    // inside processOneMessage, by the auth-parking path, and by deinit.
    // Lifetime is decoupled from `state` on purpose: a single transition
    // shouldn't have to thread the conn pointer, and aborts in mid-flight
    // can let `deinit` find the conn via this field instead of carrying
    // it on every state variant.
    _conn: ?*http.Connection = null,

    req: Request,
    res: Response = .{},
    client: *Client,

    // The owner's jar, unless the request opted out of cookies.
    cookie_jar: ?*CookieJar = null,
    // The site for SameSite checks: Request.cookie_origin, else the owner's.
    cookie_origin: Cookie.SiteForCookies = .none,

    req_headers: std.ArrayList(RequestHeader) = .empty,

    start_time: u64,

    // Earliest start time (ms, boot clock) while .delayed.
    _run_at: u64 = 0,

    _notified_fail: bool = false,

    // guard to ensure only one of done/error/shutdown is ever called
    _outcome_delivered: bool = false,

    // Set when conn is temporarily detached from transfer during redirect
    // reconfiguration. Used by processMessages to release the orphaned conn
    // if reconfiguration fails. Transient inside the redirect path only.
    _detached_conn: ?*http.Connection = null,

    _auth_challenge: ?http.AuthChallenge = null,

    // number of times the transfer has been tried.
    // incremented by reset func.
    _tries: u8 = 0,
    _redirect_count: u8 = 0,

    // What Navigation Timing needs to say about the redirect chain. The clock is
    // the boot-relative one `Performance.now()` counts from, so the last hop's
    // stamp is directly convertible to the document's timeline.
    //
    // `_redirects_same_origin` is Navigation Timing's timing allow check: a
    // chain is only reportable when every hop stayed on one origin. Chrome
    // reports redirectCount 1 and non-zero redirectStart/End for a same-origin
    // 302 and 0 for all three when one hop crossed origins, while fetchStart
    // moves past the hop either way (measured; see the two
    // `/redirect_nav_timing*` routes in testing.zig).
    _last_redirect_micros: u64 = 0,
    _redirects_same_origin: bool = true,

    // Fetch.continueRequest header overrides apply to a single network hop. We
    // need to restore (and hence capture) the original headers.
    _intercept_original_headers: ?[]const RequestHeader = null,

    // Linked into client.pending_queue while .queued and client.delayed_queue
    // while .delayed; reused to link the retired transfer into
    // client.graveyard (deinit unlinks it from those queues first, so the
    // node is always free by then).
    _node: std.DoublyLinkedList.Node = .{},

    // Buffered response ordered events awaiting dispatch.
    _events: std.ArrayList(Event) = .empty,

    // controls if _queue_node is in client.dispatch_queue (false) or
    // client.gated_queue (true)
    _gated: bool = false,

    // True while _queue_node is linked into dispatch_queue/gated_queue.
    // A streaming transfer can be queued while still .inflight (in the multi)
    _dispatch_queued: bool = false,

    _queue_node: std.DoublyLinkedList.Node = .{},

    // Mirror this transfer's lifecycle as CDP Network.* events (serve mode).
    _notify_cdp: bool = false,

    // Response came from the http cache; drives the served-from-cache
    // notification at delivery.
    _from_cache: bool = false,

    // This navigation has already been thrown away and re-sent once for a
    // Critical-CH. Caps it at one: an origin that keeps asking for a hint we
    // don't answer would otherwise loop the navigation forever.
    _critical_hints_restarted: bool = false,

    // What the cache wants from this transfer's response.
    _cache_intent: CacheIntent = .none,

    // Cache key captured at lookup time (req.url before any redirect
    // rewrote it). Only meaningful while _cache_intent != .none.
    _cache_key: [:0]const u8 = "",

    // Content length reported on the CDP loadingFinished event.
    _content_length: usize = 0,

    _conn_id: i64 = 0,
    _conn_reused: bool = false,
    _timing: ResourceTiming = .{},

    // Set by the first deinit. A retired transfer is unlinked from
    // everything and sits on client.graveyard
    _retired: bool = false,

    _cors_cross_origin: bool = false,
    // Set once a redirect target origin differs from origin of the URL
    // that redirected to it.
    _cors_origin_tainted: bool = false,

    pub const State = union(enum) {
        // Pre-commit. Only valid inside the request flow (Client.request
        // or a re-entry like continueTransfer / unpark) before any commit
        // point hands the transfer to an external owner. Client.request's
        // errdefer uses `.created` to decide whether to abort.
        created,

        // On client.queue, waiting for a libcurl handle. `_node` is
        // linked into client.queue.
        queued,

        // On client.delayed_queue, waiting for its per-host navigation slot
        // (`_run_at`) before entering the pipeline. `_node` is linked into
        // client.delayed_queue.
        delayed,

        // Response events are buffered on `_events`, waiting for dispatch
        // to deliver them. `_queue_node` is linked into
        // client.dispatch_queue. No conn is held.
        buffered,

        // Conn (in `_conn`) is in the multi handle; libcurl owns the
        // lifecycle. processOneMessage will eventually fire callbacks
        // for us.
        inflight,

        // deliver() is running user callbacks (abort() also latches this
        // to defer re-entrant teardown). For a buffered transfer no conn
        // is held; a streaming transfer's conn is still in the multi and
        // the state returns to .inflight after the batch.
        delivering,

        // External owner is holding the transfer paused. The owner is
        // responsible for resuming or terminating it.
        parked: ParkedBy,

        // detachInDelivery ran; delivery callbacks are noop'd, owner link
        // is cleared, deliver() will finishDelivery when its loop exits.
        // `_conn` (if any) is what `deinit` will release.
        aborted,
    };

    pub const ParkedBy = enum {
        // CDP Fetch interception, request phase.
        intercept_request,

        // CDP auth challenge — processOneMessage stashed the transfer
        // waiting for continueWithAuth.
        intercept_auth,

        // RobotsGate holds the transfer pending a robots.txt fetch.
        robots,

        // PreflightGate holds the transfer pending its CORS OPTIONS.
        preflight,
        // CorsGate holds the tranfer pending a CORS preflight.
        cors,
    };

    pub const HeaderResult = enum {
        /// Continue processing normally.
        proceed,
        /// Abort the Transfer,
        abort,
    };

    // Gate-facing: park the transfer for an external owner. The caller
    // must be holding the transfer in the request flow (state == .created).
    pub fn park(self: *Transfer, by: ParkedBy) void {
        lp.assert(self.state == .created, "Transfer.park", .{ .state = self.state });
        self.state = .{ .parked = by };
    }

    // Gate-facing: take the transfer out of .parked and return it to
    // the request flow (.created). This assumes pre-inflight handling (i.e. the
    // transfer was in .created before being parked). This is true today, but
    // could become false if Request Interception ever supports the "response"
    // requestStage (although, to support this, I think the safety of transfers
    // post-perform would need to be improved),
    pub fn unpark(self: *Transfer) void {
        lp.assert(self.state == .parked, "Transfer.unpark", .{ .state = self.state });
        self.leaveIntercept();
        self.state = .created;
    }

    // Decrement the interception counter iff this transfer is currently
    // parked for CDP interception.
    fn leaveIntercept(self: *Transfer) void {
        if (self.state != .parked) {
            return;
        }
        switch (self.state.parked) {
            .robots, .preflight, .cors => {},
            .intercept_request, .intercept_auth => {
                lp.assert(self.client.intercepted > 0, "Transfer.leaveIntercept", .{ .value = self.client.intercepted });
                self.client.intercepted -= 1;
            },
        }
    }

    // Submit a transfer created with Client.newRequest, entering the
    // request pipeline. Consumes the caller's ownership unconditionally:
    // on failure the transfer is already cleaned up (error_callback fired,
    // memory freed) — do not deinit it, and do not touch it after this.
    pub fn submit(self: *Transfer) anyerror!void {
        if (!self.req.internal) {
            lp.metrics.http_requests.incr(if (self.req.sync) .sync else .async);
        }
        // Synthetic schemes never touch the network — no robots, cache, or
        // interception. The response is materialized here and delivered by
        // the dispatcher like any other transfer.
        if (Synthetic.isSynthetic(self.req.url)) {
            // Skipping the pipeline also skipped the only site that arms CDP
            // reporting, so a blob: or data: subresource used to load and run
            // while every Network consumer saw nothing at all. Chrome reports
            // these like any other request, and a wire log that silently omits
            // them reads as "not loaded" — it cost a debugging session exactly
            // that. Interception stays out: there is no socket to hold.
            if (self.client.serve_mode) {
                self._notify_cdp = true;
                if (self.req.notification) |n| n.dispatch(.http_request_start, &.{ .transfer = self });
            }
            Synthetic.buffer(self) catch |err| {
                // Buffer the failure too (blob-not-found is a normal
                // JS-visible TypeError). Delivered like any other error (e.g
                // asynchronously in deliver).
                self.failAsync(err);
            };
            return;
        }

        self._timing.start(self.req.url);
        self.client.pipeline(self, .start) catch |err| {
            self.abortPipelineError(err);
            return err;
        };
    }

    pub fn submitSync(self: *Transfer) !SyncResponse {
        const client = self.client;

        if (client.disconnected) {
            self.deinit();
            return error.ClientDisconnected;
        }

        // A parser can start another blocking script/style fetch while unwinding
        // a previous interrupted fetch. The first tickSync below would fail
        // anyway; bail before submitting and notifying CDP.
        if (client.hasPendingTeardown()) {
            self.deinit();
            return error.SyncWaitInterrupted;
        }

        var sync_ctx = SyncContext{ .client = client, .body = .empty };
        errdefer if (sync_ctx.arena) |arena| arena.release();

        const req = &self.req;
        req.sync = true;
        req.ctx = &sync_ctx;
        req.header_callback = SyncContext.headerCallback;
        req.data_callback = SyncContext.dataCallback;
        req.done_callback = SyncContext.doneCallback;
        req.error_callback = SyncContext.errorCallback;
        req.shutdown_callback = SyncContext.shutdownCallback;

        const frame_id = req.frame_id;
        client.blocking_requests.putNoClobber(client.allocator, frame_id, self.id) catch |err| {
            self.deinit();
            return err;
        };
        defer client.releaseBlocking(frame_id);

        try self.submit();

        while (sync_ctx.completion == .in_progress) {
            client.tickSync(200) catch |err| {
                if (sync_ctx.completion == .in_progress) {
                    // tick failed for a reason unrelated to our transfer: OOM,
                    // client disconnect, or a queued teardown command (which
                    // sync_wait can't dispatch mid-parse — it would free the
                    // Page/Frame this stack holds). transfer.req.ctx points at
                    // &sync_ctx on this stack — abort to sever that reference
                    // before we return
                    self.abort(err);
                }
                return err;
            };
        }

        switch (sync_ctx.completion) {
            .in_progress => @panic("Impossible to be in progress here."),
            .done, .shutdown => return .{
                .status = sync_ctx.status,
                .body = sync_ctx.body,
                .arena = sync_ctx.arena,
                // Read off the connection in the header/data callbacks,
                // because the connection is gone by the time we return -- and
                // carried out here because the caller files a resource entry
                // from them (`nextHopProtocol`, `contentType`, the connection
                // walk). Dropping them leaves a stylesheet's entry reporting
                // an empty protocol where every other initiator reports one.
                .next_hop_protocol = sync_ctx.next_hop_protocol,
                .encoded_body_size = sync_ctx.encoded_body_size,
                .labels = sync_ctx.labels,
                .times = sync_ctx.times,
            },
            .err => |e| return e,
        }
    }

    pub fn deinit(self: *Transfer) void {
        if (self._retired) {
            // transfer.deinit should be called once. But _retired and the graveyard
            // are a safety net born out of UAFs.
            if (comptime lp.IS_DEBUG) {
                lp.assert(false, "Transfer.deinit on retired transfer", .{ .id = self.id });
            }
            return;
        }
        self._retired = true;
        self.leaveIntercept();
        if (self._conn) |c| {
            self.client.removeConn(c);
            self._conn = null;
        }

        // Unlink from client.pending_queue if we were waiting for a handle,
        // or from client.delayed_queue if we were waiting for our slot.
        if (self.state == .queued) {
            self.client.pending_queue.remove(&self._node);
        } else if (self.state == .delayed) {
            self.client.delayed_queue.remove(&self._node);
            self.client.delayed_count -= 1;
        }

        // Same for the dispatch queue: a queued transfer (buffered, or
        // streaming with a pending batch) killed out-of-band (owner
        // teardown, abort) must not be delivered.
        if (self._dispatch_queued) {
            if (self._gated) {
                self.client.gated_queue.remove(&self._queue_node);
            } else {
                self.client.dispatch_queue.remove(&self._queue_node);
            }
            self.client.dispatch_count -= 1;
            self._dispatch_queued = false;
        }

        // And for the robots gate: RobotsGate.pending holds a raw *Transfer
        // while we're parked.
        if (self.state == .parked) {
            switch (self.state.parked) {
                .cors => self.client.cors.remove(self),
                .preflight => self.client.preflight.remove(self),
                .robots => self.client.robots.remove(self),
                .intercept_auth, .intercept_request => {},
            }
        }
        // Same for the preflight gate.
        if (self.state == .parked and self.state.parked == .preflight) {
            self.client.preflight.remove(self);
        }

        // A pending revalidation entry owns cache resources (possibly an
        // open file). It's resolved at completion; if we die first, release.
        switch (self._cache_intent) {
            .revalidate => |stale| stale.data.deinit(),
            .none, .store => {},
        }

        // Drop the id→*Transfer index entry before freeing the memory.
        // Any concurrent CDP lookup by id will now see this transfer as gone.
        _ = self.client.transfers.remove(self.id);

        if (self.owner) |o| {
            o.removeTransfer(self);
        }

        if (comptime lp.IS_DEBUG) {
            // Any callback on a corpse is a bug — fail loudly instead of
            // silently running user code from a retired transfer.
            self.req.start_callback = null;
            self.req.header_callback = Poison.headerCallback;
            self.req.data_callback = Poison.dataCallback;
            self.req.done_callback = Poison.doneCallback;
            self.req.error_callback = Poison.errorCallback;
            self.req.shutdown_callback = Poison.shutdownCallback;
        }

        // Why not free the memory here? It _should_ be safe, but the flow is
        // complicated, and history tells us we'll get UAF. The above effectively
        // rendered the transfer dead,but it's memory alive, just incase
        // something uses it. We'll clean it up when it's likely to be safer.
        self.client.graveyard.append(&self._node);
    }

    // The consumer doesn't want this transfer. Reserved for things like
    // xhr.abort(), an AbortController, a worker.terminate(), i.e. mostly JS
    // driven (though, potentially indirectly).
    // HeaderResult.abort on the other hand is more internal, e.g. ScriptManager
    // getting a non-2xx response code.
    // cancel results in a `error.TransferCanceled` and abort results in an
    // error.Abort. Various places need to make the distinction between the two.
    pub fn cancel(self: *Transfer) void {
        self.abort(error.TransferCanceled);
    }

    // Fail this transfer with `err`. Fires error_callback once (latched
    // via _notified_fail), then either deinits synchronously or, if
    // deliver() is running our callbacks, detaches and lets deliver()
    // deinit when its loop exits.
    //
    // abort() or cancel() are the only entry points external callers should use
    // to end a transfer. Don't reach for kill() or requestFailed() directly —
    // they're internal helpers.
    pub fn abort(self: *Transfer, err: anyerror) void {
        // error_callback can run JS that tears this transfer down again
        // (e.g. an XHR abort handler navigates -> abortRequests -> kill).
        // Hold the state at .delivering so the re-entrant teardown defers,
        // then do the single real teardown against the original state.
        const state = self.state;
        self.state = .delivering;
        self.requestFailed(err);
        self.state = state;
        self.detachOrDeinit();
    }

    // take whatever we have, and deliver it.
    pub fn finishEarly(self: *Transfer) bool {
        if (self.state != .inflight or self.req.streaming or self._cache_intent == .revalidate) {
            return false;
        }
        const conn = self._conn orelse return false;
        const status = conn.getResponseCode() catch 0;
        if (status == 0 or (status >= 300 and status < 400)) {
            // we don't have a status code yet, or it's a 3xx. Nothing to deliver.
            return false;
        }

        self.materializeResponse(conn, .{}) catch return false;
        self.client.removeConn(conn);
        self._conn = null;
        self._content_length = self.res.buffer.items.len;
        self.bufferEvents(self.res.buffer.items) catch |err| {
            self.failAsync(err);
        };
        return true;
    }

    // We have our events, and the last event is .done
    fn isCompleteAwaitingDispatch(self: *const Transfer) bool {
        if (self.state != .buffered) {
            return false;
        }
        const events = self._events.items;
        return events.len > 0 and events[events.len - 1] == .done;
    }

    // A pipeline entry point failed. The pipeline still owns the transfer in
    // two states: .created and .inflight. In all other states, the owner
    // delivers the failure.
    pub fn abortPipelineError(self: *Transfer, err: anyerror) void {
        switch (self.state) {
            .created, .inflight => self.abort(err),
            else => {},
        }
    }

    // Abort a transfer that an external owner (CDP interception) is holding
    // in a .parked state.
    pub fn abortParked(self: *Transfer, err: anyerror) void {
        self.unpark();
        self.failAsync(err);
    }

    pub fn effectiveOrigin(transfer: *const Transfer) []const u8 {
        if (transfer._cors_origin_tainted) return "null";
        return transfer.req.origin orelse "null";
    }

    pub fn getCookieString(self: *Transfer, arena: Allocator) !?[:0]const u8 {
        const req = &self.req;
        if (!req.credentialsAllowed()) return null;

        const jar = self.cookie_jar orelse return null;
        var aw: std.Io.Writer.Allocating = .init(arena);
        try jar.forRequest(req.url, &aw.writer, .{
            .is_http = true,
            .origin_url = self.cookie_origin,
            .is_navigation = req.resource_type == .document,
        });
        if (aw.written().len == 0) {
            return null;
        }
        try aw.writer.writeByte(0);
        const written = aw.written();
        return written.ptr[0 .. written.len - 1 :0];
    }

    // Mirrors the transfer to whoever the owner reports to (CDP). A request
    // without attribution has nobody listening.
    fn notify(self: *Transfer, comptime event: Notification.EventType, data: Notification.ArgType(event)) void {
        const notification = self.req.notification orelse return;
        notification.dispatch(event, data);
    }

    // Owner-driven teardown: fires shutdown_callback (not error_callback)
    // and otherwise behaves like abort. Called by Client.abortOwner /
    // abortRequests when a Frame / WGS is being torn down. Any buffered,
    // undelivered events are dropped — the consumer is going away with us.
    fn kill(self: *Transfer) void {
        if (self._notify_cdp and !self._notified_fail) {
            self._notified_fail = true;
            self.notify(.http_request_fail, &.{
                .transfer = self,
                .err = error.Shutdown,
            });
        }
        switch (self.state) {
            .delivering => self.detachInDelivery(),
            .aborted => {}, // already detached
            else => {
                self.req.shutdown_callback(self.req.ctx);
                self.deinit();
            },
        }
    }

    // Decide whether to tear down now or defer.
    //
    // Only `.delivering` forces deferral — deliver() is running this
    // transfer's callbacks and will call `transfer.deinit` itself after
    // its loop exits; deiniting here would double-free.
    //
    // Otherwise (created / queued / inflight / parked / fully drained),
    // nothing else references this transfer and we can safely deinit
    // inline. User code never runs inside libcurl, so an abort can't
    // arrive mid-perform: removing an .inflight conn from the multi here
    // is always legal.
    fn detachOrDeinit(self: *Transfer) void {
        if (self.state == .delivering) {
            self.detachInDelivery();
        } else {
            self.deinit();
        }
    }

    // Deferred-cleanup path when deliver() owns the transfer.
    //
    // We:
    //   - transition state to `.aborted` so deliver()'s loop stops before
    //     the next event (and, for a streaming transfer whose conn is
    //     still in the multi, so a nested pump's completion path
    //     short-circuits),
    //   - noop every delivery callback so a nested pump draining the still-
    //     inflight response can't re-enter user code. shutdown_callback is
    //     kept: only kill() calls it.
    //   - unlink from owner.transfers and clear `owner` so the owning
    //     Frame/WGS can be freed while this transfer is still draining.
    //     transfer.deinit (called by deliver() on exit) sees
    //     `owner == null` and skips the list-remove that would otherwise
    //     UAF against a freed list.
    fn detachInDelivery(self: *Transfer) void {
        // `_conn` (if any) rides through .aborted untouched; deinit
        // releases it once libcurl is done.
        self.state = .aborted;
        self.req.start_callback = null;
        self.req.header_callback = Noop.headerCallback;
        self.req.data_callback = Noop.dataCallback;
        self.req.done_callback = Noop.doneCallback;
        self.req.error_callback = Noop.errorCallback;
        if (self.owner) |o| {
            o.removeTransfer(self);
            self.owner = null;
        }
    }

    // Some type of failure, either internal or external, either explicit or
    // implicit. transfer.abort() is the external and explicit path. There are
    // various internal callers, but the most common is a callback error.
    fn requestFailed(self: *Transfer, err: anyerror) void {
        if (self._notified_fail) {
            return;
        }

        if (self.state == .aborted) {
            return;
        }
        self._notified_fail = true;

        if (!self.req.internal) {
            lp.metrics.http_error.incr(http.errorReason(err));
        }

        if (self._notify_cdp) {
            self.notify(.http_request_fail, &.{
                .transfer = self,
                .err = err,
                .blocked_reason = if (err == error.UrlBlocked) .inspector else null,
            });
        }

        self._outcome_delivered = true;
        self.req.error_callback(self.req.ctx, err);
    }

    // A consumer callback failed mid-delivery: latch the failure, notify,
    // free. Only called from deliver().
    fn failDelivery(self: *Transfer, err: anyerror) void {
        if (err != error.TransferCanceled) {
            log.err(.http, "delivery callback", .{ .err = err, .req = self });
        }
        self.requestFailed(err);
        self.finishDelivery();
    }

    // Fail the transfer asynchronously: the error is buffered and
    // error_callback fires from the dispatcher, never from the caller's
    // stack.
    pub fn failAsync(self: *Transfer, err: anyerror) void {
        self._events.append(self.arena.allocator(), .{ .err = err }) catch {
            // Can't buffer (OOM): failing inline beats losing the error.
            return self.abort(err);
        };
        self.scheduleDispatch();
    }

    // Commit the transfer's buffered events for delivery. From here on the
    // dispatcher owns the transfer's fate; deinit unlinks it if it dies
    // out-of-band first.
    fn scheduleDispatch(self: *Transfer) void {
        if (self.state == .delivering) {
            return;
        }
        if (comptime lp.IS_DEBUG) {
            lp.assert(
                self.state == .created or self.state == .inflight,
                "Transfer.scheduleDispatch",
                .{ .state = self.state },
            );
        }
        self.state = .buffered;
        self.enqueueDispatch();
    }

    fn enqueueDispatch(self: *Transfer) void {
        if (self._dispatch_queued) {
            return;
        }
        self._dispatch_queued = true;
        self.client.dispatch_queue.append(&self._queue_node);
        self.client.dispatch_count += 1;
    }

    fn captureTiming(self: *Transfer, conn: *const http.Connection) void {
        const t = &self._timing;
        const ct = conn.getTiming() catch return;
        const base = t.hop_start + ct.queue;
        const tls = std.mem.startsWith(u8, self.req.url, "https://");

        if (self._conn_reused) {
            // Nothing was resolved or connected for this fetch
            t.dns_start = t.fetch_start;
            t.dns_end = t.fetch_start;
            t.connect_start = t.fetch_start;
            t.connect_end = t.fetch_start;
            t.secure_start = if (tls) t.fetch_start else 0;
        } else {
            t.dns_start = base;
            t.dns_end = base + ct.namelookup;
            t.connect_start = t.dns_end;
            t.connect_end = base + @max(ct.connect, ct.appconnect);
            t.secure_start = if (tls) base + ct.connect else 0;
        }
        t.request_start = base + ct.pretransfer;
        t.response_start = base + ct.starttransfer;
        // the stream's response_end will get captured in recordResourceTiming
        t.response_end = if (self.req.streaming) 0 else base + ct.total;

        t.encoded_body_size = conn.getDownloadSize() catch 0;
        t.protocol = switch (conn.getHttpVersionEnum() catch .none) {
            .v1_0 => "http/1.0",
            .v1_1 => "http/1.1",
            .v2 => "h2",
            .v3 => "h3",
            else => "",
        };
    }

    fn recordRedirectTiming(self: *Transfer, headers: []const http.Header) void {
        const t = &self._timing;
        const now = lp.datetime.microTimestamp(.boot);
        if (t.redirect_start == 0) {
            t.redirect_start = t.start_time;
        }
        t.redirect_end = now;
        t.fetch_start = now;
        if (t.timing_allow) {
            const target = self.timingTarget() orelse return;
            t.timing_allow = timingAllowPassed(target.origin, self.req.url, headers, t.tainted);
        }
    }

    // If A -> B -> A, we sent the tainted flag (on the B -> A transition) so
    // that we know how to apply the timing-allow-origin header.
    fn redirectTaint(self: *Transfer, url: []const u8) void {
        const target = self.timingTarget() orelse return;
        const origin = target.origin orelse "null";
        if (!URL.isSameOrigin(self.req.url, origin) and !URL.isSameOrigin(url, self.req.url)) {
            self._timing.tainted = true;
        }
    }

    const TimingTarget = struct {
        origin: ?[]const u8,
        performance: *Performance,
    };

    fn timingTarget(self: *const Transfer) ?TimingTarget {
        const owner = self.owner orelse return null;
        const target: *const Owner = if (self.req.resource_type == .document)
            owner.parent orelse return null
        else
            owner;
        return .{ .performance = target.performance, .origin = target.origin.* };
    }

    // https://fetch.spec.whatwg.org/#concept-tao-check
    fn timingAllowPassed(document_origin: ?[]const u8, url: []const u8, headers: []const http.Header, tainted: bool) bool {
        const origin = document_origin orelse "null";
        if (!tainted and URL.isSameOrigin(url, origin)) {
            return true;
        }
        for (headers) |hdr| {
            if (!std.ascii.eqlIgnoreCase(hdr.name, "timing-allow-origin")) {
                continue;
            }
            var it = std.mem.splitScalar(u8, hdr.value, ',');
            while (it.next()) |part| {
                const value = std.mem.trim(u8, part, " \t");
                if (std.mem.eql(u8, value, "*") or (!tainted and std.mem.eql(u8, value, origin))) {
                    return true;
                }
            }
        }
        return false;
    }

    // Buffer the standard success event sequence. `body` is either owned by
    // transfer.arena OR, through some other mechanism, outlives the transfer.
    fn bufferEvents(self: *Transfer, body: []const u8) !void {
        // Single delivery point for every successful response — network,
        // cache, and synthetic, on both the sync and async paths. Redirect
        // hops never reach here (they loop back in processOneMessage), so
        // http_status reflects the final response only. Internal requests
        // (robots.txt) are tracked by the robots_* metrics instead.
        if (self.res.stream.started) {
            try self._events.append(self.arena.allocator(), .done);
            self.scheduleDispatch();
            return;
        }

        if (!self.req.internal) {
            const status = if (self.res.header) |h| h.status else 0;
            lp.metrics.http_status.incr(http.statusCategory(status));
            lp.metrics.http_response_size_bytes.observe(body.len);
        }

        try self._events.ensureUnusedCapacity(self.arena.allocator(), 4);
        self._events.appendAssumeCapacity(.start);
        self._events.appendAssumeCapacity(.header);
        if (body.len > 0) {
            self._events.appendAssumeCapacity(.{ .data = body });
        }
        self._events.appendAssumeCapacity(.done);
        self.scheduleDispatch();
    }

    fn setResponseHead(self: *Transfer, status: u16, content_type: ?[]const u8) void {
        self.res.header = .{
            .url = self.req.url.ptr,
            .status = status,
            .redirect_count = self._redirect_count,
        };
        if (content_type) |ct| {
            var hdr = &self.res.header.?;
            const len = @min(ct.len, http.ResponseHead.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], ct[0..len]);
        }
    }

    // Serve a cache entry as this transfer's response. Takes ownership of
    // `cached` (file-backed bodies are read into the arena and closed).
    fn bufferCached(self: *Transfer, cached: Cache.CachedResponse, cache_state: ResourceTiming.CacheState) !void {
        const body: []const u8 = switch (cached.data) {
            .buffer => |b| b,
        };

        self.setResponseHead(cached.status, cached.content_type);
        self.res.headers = cached.headers;
        self._from_cache = true;
        self._timing.cache = cache_state;
        self._content_length = body.len;
        try self.bufferEvents(body);
    }

    // Materialize an interceptor-supplied response (CDP fulfillRequest).
    // `headers` and `body` are caller-owned; copy everything that must
    // survive until dispatch.
    fn bufferFulfilled(self: *Transfer, status: u16, headers: []const http.Header, body: ?[]const u8) !void {
        const arena = self.arena;

        const owned = try arena.alloc(http.Header, headers.len);
        var content_type: ?[]const u8 = null;
        for (headers, 0..) |hdr, i| {
            owned[i] = .{
                .name = try arena.dupe(u8, hdr.name),
                .value = try arena.dupe(u8, hdr.value),
            };
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                content_type = owned[i].value;
            }
        }

        const owned_body: []const u8 = if (body) |b| try arena.dupe(u8, b) else "";

        self.setResponseHead(status, content_type);
        self.res.headers = owned;
        self._content_length = owned_body.len;
        try self.bufferEvents(owned_body);
    }

    // Copy everything the response needs out of the conn and into the
    // transfer arena. After this, delivery never touches libcurl state —
    // the conn can be released and reused before the consumer sees a byte.
    const MaterializeResponseOpts = struct {
        check_content_length: bool = true,
    };

    fn materializeResponse(self: *Transfer, conn: *http.Connection, opts: MaterializeResponseOpts) !void {
        if (self.res.stream.started) {
            // Streaming: already materialized at the first delivered chunk.
            return;
        }

        // libcurl returns -1 if the connection wasn't used. We want to avoid
        // negative, so -1 -> 0 and everything else += 1;
        const conn_id = conn.getConnId() catch -1;
        self._conn_id = if (conn_id < 0) 0 else conn_id + 1;
        self._conn_reused = conn.isConnReused() catch false;
        self.captureTiming(conn);

        const arena = self.arena;

        if (self.res.header == null) {
            try self.buildResponseHeader(conn);
        }
        // buildResponseHeader stores a curl-owned url pointer; re-anchor it
        // in the arena so it survives the conn release.
        self.res.header.?.url = (try arena.dupeZ(u8, std.mem.span(self.res.header.?.url))).ptr;

        var it = HeaderIterator{ .curl = .{ .conn = conn } };
        const headers = try it.collect(arena.allocator());
        self.res.headers = headers.items;

        if (self.req.credentialsAllowed()) {
            if (self.cookie_jar) |jar| {
                for (self.res.headers) |hdr| {
                    if (std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) {
                        jar.populateFromResponse(self.req.url, hdr.value) catch |err| {
                            log.err(.http, "set cookie", .{ .err = err, .req = self });
                            return err;
                        };
                    }
                }
            }
        }

        try self.negotiateClientHints();

        // headers_only is exempt: the cap exists to bound how much body we
        // buffer, and this transfer buffers none of it. Failing a 4 MB image
        // we were never going to read would turn the size limit into a
        // spurious `error` event on a perfectly good response.
        if (opts.check_content_length and !self.req.headers_only) {
            if (self.getContentLength()) |cl| {
                if (cl > self.client.max_response_size) {
                    return error.ResponseTooLarge;
                }
            }
        }
    }

    // Remember what this response's `Accept-CH` asks for, so later requests to
    // the origin carry the high-entropy hints it wants.
    //
    // Navigations only -- an `Accept-CH` on a subresource response is ignored,
    // which is Chrome's rule (Chromium persists hints from
    // NavigationRequest::OnResponseStarted and from nowhere else).
    //
    // Top-level navigations only, at that. A subframe's ask is worth nothing,
    // and this file used to say the opposite -- that "both frames count",
    // reasoning from Cloudflare's Turnstile widget sending the header on its own
    // OOPIF document. That was an inference, and it was backwards: the widget
    // sends `Accept-CH` from a place a real browser must refuse it, and honouring
    // it is what put the six high-entropy hints on every request the widget then
    // made. Measured three ways against a bare headless Chrome
    // (`accept-ch-echo.mjs --scenario frame`, two loopback origins):
    //
    //   subframe asks                       Chrome sends 0 of the six, and does
    //                                       not restart for the Critical-CH
    //   ...after a top-level visit to the
    //      same origin, so its ask is on
    //      record                           still 0
    //   ...and with the top document
    //      delegating ch-ua-* by
    //      Permissions-Policy and `allow=`  still 0
    //
    // So the gate is which frame did the asking, not which origin, and there is
    // no delegated path to build behind it -- no arm was found in which Chrome
    // gives a cross-origin frame these hints at all.
    //
    // A response *without* the header leaves the origin's set alone rather than
    // clearing it, also Chrome's rule -- measured, the `/revisit` navigation in
    // tools/fingerprint/results/acceptch-chrome.json still carries all nine
    // hints though nothing on that hop asked again.
    fn negotiateClientHints(self: *Transfer) !void {
        if (self.req.resource_type != .document) {
            return;
        }
        // A navigation this engine did not label is a top-level one: `nav` is
        // only absent on requests built outside Frame.navigate, which is where
        // subframes come from.
        if (self.req.nav) |nav| {
            if (nav.subframe) {
                return;
            }
        }
        for (self.res.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "accept-ch") == false) {
                continue;
            }
            try self.client.client_hints.negotiate(
                self.client.allocator,
                self.req.url,
                hdr.value,
            );
        }
    }

    fn configureConn(self: *Transfer, conn: *http.Connection) anyerror!void {
        const client = self.client;
        const req = &self.req;

        // Set callbacks and per-client settings on the pooled connection.
        try conn.setWriteCallback(Transfer.dataCallback);
        try conn.setFollowLocation(false);
        try conn.setProxy(client.http_proxy);
        try conn.setTlsVerify(client.tls_verify, client.use_proxy);
        try conn.setHttpVersion(client.http_version);

        try conn.setURL(req.url);
        try conn.setMethod(req.method);
        if (req.body) |b| {
            try conn.setBody(b);
        } else {
            try conn.setGetMode();
        }

        // Build the conn's curl_slist from req_headers, fresh on every
        // attempt so redirect/auth retries pick up mutations and never
        // accumulate duplicates.
        conn.clearHeaders();
        const arena = self.arena.allocator();
        try self.seedCookie();
        try self.emitHeaders(conn, arena);
        if (req.body != null) {
            // Browsers never send Expect: 100-continue; libcurl generates it
            // for HTTP/1.1 requests whose body exceeds 1MB
            // (EXPECT_100_THRESHOLD), which stalls the request ~1s against
            // servers/proxies that never answer the interim response. An
            // empty value ("Expect:") suppresses the generated header. Only
            // requests with a body can trigger it, and over HTTP/2 curl never
            // generates it, so the entry is inert there.
            try conn.addRawHeader("Expect:");
        }
        try conn.secretHeaders(&client.network.config.http_headers);
        try conn.commitHeaders();

        conn.transport = .{ .http = self };

        // Per-request timeout override (e.g. XHR timeout). Set on every
        // request rather than relying on the value `Connection.reset` left
        // behind, so the transfer's timeout is decided here and not by
        // whatever the pooled connection was last used for.
        if (req.timeout_ms > 0) {
            try conn.setTimeout(req.timeout_ms);
        } else if (req.streaming) {
            try conn.setTimeout(0);
        } else {
            try conn.setTimeout(client.network.config.httpTimeout());
        }

        // add credentials
        if (req.basic_auth_credentials) |creds| {
            if (self._auth_challenge != null and self._auth_challenge.?.source == .proxy) {
                try conn.setProxyCredentials(creds);
            } else {
                try conn.setCredentials(creds);
            }
        }
    }

    pub fn reset(self: *Transfer) void {
        // Note: do NOT reset _auth_challenge or _redirect_count here. They
        // span retries — _auth_challenge tells makeRequest whether to use
        // setProxyCredentials vs setCredentials; _redirect_count caps the
        // total hops. The rest of the response state is per-attempt.
        self._notified_fail = false;
        self._tries += 1;
        self.res.buffer.clearRetainingCapacity();
        self.res = .{
            .buffer = self.res.buffer,
            .stream = .{ .spare = self.res.stream.spare },
        };
    }

    fn buildResponseHeader(self: *Transfer, conn: *const http.Connection) !void {
        if (comptime lp.IS_DEBUG) {
            std.debug.assert(self.res.header == null);
        }

        const url = try conn.getEffectiveUrl();

        const status: u16 = if (self._auth_challenge != null)
            407
        else
            try conn.getResponseCode();

        self.res.times = conn.getResponseTimes();
        self.res.header_bytes = conn.getResponseHeaderSize() catch 0;

        self.res.header = .{
            .url = url,
            .status = status,
            .redirect_count = self._redirect_count,
            .next_hop_protocol = conn.getHttpVersion() catch "",
        };

        if (conn.getResponseHeader("content-type", 0)) |first| {
            // last one wins
            const ct = if (first.amount < 2) first else conn.getResponseHeader("content-type", first.amount - 1) orelse first;
            var hdr = &self.res.header.?;
            const value = ct.value;
            const len = @min(value.len, http.ResponseHead.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], value[0..len]);
        }

        if (conn.getResponseHeader("content-encoding", 0)) |ce| {
            var hdr = &self.res.header.?;
            const value = ce.value;
            const len = @min(value.len, http.ResponseHead.MAX_CONTENT_ENCODING_LEN);
            hdr._content_encoding_len = len;
            @memcpy(hdr._content_encoding[0..len], value[0..len]);
        }

        // The only one of the four that may legitimately arrive more than once:
        // a proxy adds its own members rather than replacing the origin's, and
        // the page sees one list either way. Joined with a comma, which is what
        // the header's own grammar says two copies mean.
        {
            var i: usize = 0;
            while (conn.getResponseHeader("server-timing", i)) |st| : (i += 1) {
                var hdr = &self.res.header.?;
                const value = std.mem.trim(u8, st.value, " \t");
                if (value.len == 0) {
                    continue;
                }
                var at = hdr._server_timing_len;
                if (at > 0) {
                    if (at + 2 > http.ResponseLabels.MAX_SERVER_TIMING_LEN) {
                        break;
                    }
                    @memcpy(hdr._server_timing[at..][0..2], ", ");
                    at += 2;
                }
                const len = @min(value.len, http.ResponseLabels.MAX_SERVER_TIMING_LEN - at);
                @memcpy(hdr._server_timing[at..][0..len], value[0..len]);
                hdr._server_timing_len = at + len;
                if (len < value.len) {
                    break;
                }
            }
        }

        if (conn.getResponseHeader("timing-allow-origin", 0)) |tao| {
            var hdr = &self.res.header.?;
            const value = tao.value;
            const len = @min(value.len, http.ResponseHead.MAX_TIMING_ALLOW_LEN);
            hdr._timing_allow_len = len;
            @memcpy(hdr._timing_allow[0..len], value[0..len]);
        }
    }

    pub fn format(self: *Transfer, writer: *std.Io.Writer) !void {
        const req = self.req;
        return writer.print("{s} {s}", .{ @tagName(req.method), req.url });
    }

    // `url` must have transfer-arena lifetime: it's stored as-is, not duped.
    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        self.req.url = url;
    }

    fn handleRedirect(transfer: *Transfer, location: []const u8) !void {
        const req = &transfer.req;
        const conn = transfer._conn.?;

        // Cookies were applied while materializing the redirect response.

        // A Referrer-Policy header on a redirect response applies to the
        // remaining hops.
        if (req.referrer_policy != null) {
            // referrer-policy is re-applied on every hop.
            var i: usize = 0;
            while (conn.getResponseHeader("referrer-policy", i)) |hdr| : (i += 1) {
                if (referrer.parseHeader(hdr.value)) |policy| {
                    req.referrer_policy = policy;
                }
                if (i >= hdr.amount) {
                    break;
                }
            }
        }

        // base_url and location are owned by curl; applyRedirectTarget resolves a
        // fresh arena-owned copy that gets stored in transfer.req.url.
        const base_url = try conn.getEffectiveUrl();
        const status = try conn.getResponseCode();
        transfer.recordRedirectTiming(transfer.res.headers);
        try transfer.applyRedirectTarget(std.mem.span(base_url), location, status);
    }

    // Called above (in handleRedirect) and by a CDP fulfill request which redirects
    fn applyRedirectTarget(transfer: *Transfer, base: [:0]const u8, location: []const u8, status: u16) !void {
        const req = &transfer.req;
        const arena = transfer.arena;

        transfer._redirect_count += 1;
        if (transfer._redirect_count > transfer.client.network.config.httpMaxRedirects()) {
            return error.TooManyRedirects;
        }

        if (transfer._cache_intent == .revalidate) {
            transfer._cache_intent.revalidate.data.deinit();
            transfer.removeHeader("If-None-Match");
            transfer.removeHeader("If-Modified-Since");
        }
        transfer._cache_intent = .none;

        // resolve the redirect target.
        const url: [:0]const u8 = blk: {
            if (location.len == 0) {
                // Might seem silly, but URL.resovle will return location as-is
                // if empty, and location may be memory owned by libcurl.
                break :blk "";
            }

            const resolved = try URL.resolve(arena.allocator(), base, location, .{});

            // RFC 7231 §7.1.2: if the Location value has no fragment, the redirect
            // inherits the fragment from the URI used to generate the request.
            // URL.resolve follows RFC 3986 §5.3, which drops the base fragment when
            // the relative ref has none, so we re-attach it here.
            if (URL.getHash(resolved).len == 0) {
                const original_hash = URL.getHash(transfer.req.url);
                if (original_hash.len != 0) {
                    break :blk try std.mem.joinZ(arena.allocator(), "", &.{ resolved, original_hash });
                }
            }
            break :blk resolved;
        };

        // Recorded before the URL moves, so `base` is still the origin that
        // answered and `url` the one the answer points at.
        transfer._last_redirect_micros = lp.datetime.microTimestamp(.boot);
        if (transfer._redirects_same_origin and url.len > 0) {
            transfer._redirects_same_origin = URL.isSameOrigin(url, base);
        }

        // When the redirect target is not same-origin with the current URL,
        // the Authorization header must not follow the request to the new
        // origin.
        // _auth_challenge is always cleared thanks to detectAuthChallenge.
        if (!URL.isSameOrigin(url, req.url)) {
            transfer.removeHeader("Authorization");
        }

        transfer.redirectTaint(url);

        if (transfer.req.request_mode == .cors and !transfer._cors_origin_tainted) {
            const already_cross_origin = if (req.origin) |o| !URL.isSameOrigin(base, o) else true;
            if (already_cross_origin and !URL.isSameOrigin(url, base)) {
                transfer._cors_origin_tainted = true;
            }
        }

        try transfer.updateURL(url);
        // 301, 302, 303 → change to GET, drop body.
        // 307, 308 → keep method and body.
        if (status == 301 or status == 302 or status == 303) {
            req.method = .GET;
            req.body = null;
        }

        // Both of these are decided by the method, the body and the target, and
        // all three can have just changed: the length header has to follow the
        // body it describes, and Fetch re-decides the Origin header per hop
        // rather than once at the start.
        try transfer.seedContentLength();
        try transfer.seedOrigin();

        if (req.referrer_policy) |policy| {
            // Referer header was applied based on the original target. It
            // needs to be updated based on the redirect target. A redirect can
            // only strip it (full -> origin -> none), so we can use whatever
            // value we have now as the base
            if (transfer.findRequestHeader("referer")) |current| {
                const alloc = arena.allocator();
                if (try referrer.compute(alloc, policy, try alloc.dupeZ(u8, current), req.url)) |value| {
                    try transfer.setHeader("Referer", value, .{});
                } else {
                    transfer.removeHeader("Referer");
                }
            }
        }
    }

    fn detectAuthChallenge(transfer: *Transfer, conn: *const http.Connection) void {
        const status = conn.getResponseCode() catch return;
        const connect_status = conn.getConnectCode() catch return;

        if (status != 401 and status != 407 and connect_status != 401 and connect_status != 407) {
            transfer._auth_challenge = null;
            return;
        }

        if (conn.getResponseHeader("WWW-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .server, hdr.value) catch null;
        } else if (conn.getConnectHeader("WWW-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .server, hdr.value) catch null;
        } else if (conn.getResponseHeader("Proxy-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .proxy, hdr.value) catch null;
        } else if (conn.getConnectHeader("Proxy-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .proxy, hdr.value) catch null;
        } else {
            transfer._auth_challenge = .{ .status = status, .source = null, .scheme = null, .realm = null };
        }
    }

    pub fn updateCredentials(self: *Transfer, userpwd: [:0]const u8) void {
        self.req.basic_auth_credentials = userpwd;
    }

    pub const RequestHeader = struct {
        name: []const u8,
        value: []const u8,
        source: HeaderSource = .user_agent,
    };

    // Who put the header on the request, ordered lowest priority first:
    // setHeader/appendHeader let a source overwrite headers from its own or
    // a lower layer, never a higher one. .fixed is hardcoded and can't be
    // changed (Sec-Ch-Ua). For CORS, only script-set headers cause a preflight.
    pub const HeaderSource = enum { user_agent, author, cdp, cli, fixed };

    pub const HeaderOpts = struct {
        source: HeaderSource = .user_agent,
    };

    fn addHeader(self: *Transfer, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        const arena = self.arena.allocator();
        try self.req_headers.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, value),
            .source = opts.source,
        });
    }

    pub fn findRequestHeader(self: *const Transfer, name: []const u8) ?[]const u8 {
        for (self.req_headers.items) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                return hdr.value;
            }
        }
        return null;
    }

    fn removeHeader(self: *Transfer, name: []const u8) void {
        var i: usize = 0;
        while (i < self.req_headers.items.len) {
            if (std.ascii.eqlIgnoreCase(self.req_headers.items[i].name, name)) {
                _ = self.req_headers.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    // Add or replace or noops the header based on the source layering priority
    pub fn setHeader(self: *Transfer, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        return self.putHeader(name, value, opts.source, .set);
    }

    // Add or append or noops the header based on the source layering priority
    pub fn appendHeader(self: *Transfer, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        return self.putHeader(name, value, opts.source, .append);
    }

    fn putHeader(self: *Transfer, name: []const u8, value: []const u8, source: HeaderSource, mode: enum { set, append }) !void {
        if (verifyHeader(name, value) == false) {
            return;
        }

        var found = false;
        var i: usize = 0;
        while (i < self.req_headers.items.len) {
            const hdr = &self.req_headers.items[i];
            if (std.ascii.eqlIgnoreCase(hdr.name, name) == false) {
                i += 1;
                continue;
            }
            if (found) {
                _ = self.req_headers.orderedRemove(i);
                continue;
            }
            found = true;

            if (@intFromEnum(hdr.source) > @intFromEnum(source)) {
                if (hdr.source == .fixed) {
                    log.warn(.http, "ignore overriding fixed header", .{ .header = hdr.name });
                }
                return;
            }
            if (mode == .append and hdr.source == source) {
                const sep = if (std.ascii.eqlIgnoreCase(name, "cookie")) "; " else ", ";
                hdr.value = try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{s}", .{ hdr.value, sep, value });
                return;
            }
            hdr.value = try self.arena.allocator().dupe(u8, value);
            hdr.source = source;
            i += 1;
        }
        if (!found) {
            try self.addHeader(name, value, .{ .source = source });
        }
    }

    // Central gate for every header entering req_headers; name-keyed
    // restrictions live here so entry points don't need their own checks.
    fn verifyHeader(name: []const u8, value: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(name, "user-agent")) {
            lp.Config.validateUserAgent(value) catch |err| {
                log.warn(.http, "invalid header dropped", .{ .name = name, .err = err });
                return false;
            };
        }
        return true;
    }

    // Chrome's header order, measured per destination rather than assumed --
    // see the `localHeaders` step of tools/fingerprint/results/*-chrome-*.json.
    // Order is a fingerprint in its own right, and it is NOT insertion order:
    // a navigation leads with the three client hints, while a subresource
    // leads with sec-ch-ua-platform and User-Agent and only then repeats
    // sec-ch-ua / sec-ch-ua-mobile. Referer lands late, after the Sec-Fetch
    // block, which insertion order cannot express either: it is added by
    // Frame.headersForRequest after the transfer already exists.
    //
    // Anything not named here (author headers, CDP extras, Content-*) follows
    // in insertion order.
    //
    // These are lookup keys, matched case-insensitively below -- the casing
    // that reaches the wire is the one baselineHeaders and seedFetchMetadata
    // spell. Written here the same way anyway, so each field name has one
    // spelling in this file.
    // The six negotiated hints are interleaved with the three baseline ones
    // rather than appended -- measured, the nine-hint navigations in
    // tools/fingerprint/results/acceptch-chrome.json. A name nothing set simply
    // doesn't match, so the three-hint case this table described before comes
    // out of it byte-identical.
    const chrome_navigation_order = [_][]const u8{
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-full-version",
        "sec-ch-ua-arch",
        "sec-ch-ua-platform",
        "sec-ch-ua-platform-version",
        "sec-ch-ua-model",
        "sec-ch-ua-bitness",
        "sec-ch-ua-full-version-list",
        "Upgrade-Insecure-Requests",
        "User-Agent",
        "Accept",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-User",
        "Sec-Fetch-Dest",
        // Behind Dest and ahead of Referer -- measured on the cross-site
        // subframe navigation of scratch/b117/sa-chrome-p2.json, the one
        // navigation shape that carries it (a top-level document is never in a
        // third-party partition, so it never does).
        "Sec-Fetch-Storage-Access",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        // The last two, in this order: Chrome writes cookie behind every real
        // field and priority behind that (measured over h2, all four shapes).
        "Cookie",
        "priority",
    };

    // Three names here are not on a GET at all -- Content-Length, content-type
    // and Origin ride along with a request that has a body or a cors taint.
    // Chrome does not append them after the set it already sends: Content-
    // Length goes third on the wire (Host, Connection, then it), content-type
    // sits inside the hint block, and Origin between Accept and the Sec-Fetch
    // triple. Measured, the same-origin `POST /sub/xhr-*` of
    // tools/fingerprint/results/xhr-post-nohints-chrome.json.
    //
    // Navigations are not in the tables above: a form POST's Content-Length
    // position was not measured, so it keeps falling to the trailing pass
    // rather than being guessed into place.
    // A subresource has no fixed table at all, because Chrome does not have one:
    // the fields the renderer keeps in HTTPHeaderMap come out in that hash
    // table's bucket order, which is a function of the whole set of names on the
    // request -- author headers included, so one `fetch(url, {headers})` moves
    // User-Agent. blink_header_order.zig rebuilds it; these two are only the
    // fields the network stack appends to an *ordered* vector further down, and
    // they bracket the map block.
    //
    // The two tables this replaced -- the plain one and the nine-hint one, both
    // measured, and different enough that they could not share a table -- are
    // exactly what the model reproduces from the name set alone. That is the
    // regression test in blink_header_order.zig.
    // A worker's script fetch has a fixed order of its own, and it is neither of
    // the other two: no client hints at all, and User-Agent BEHIND Referer
    // rather than inside a renderer map block. Measured on Chrome 151 over h1,
    // the `/w/url-worker.js` request of scratch/b120/blob-chrome.json. Cookie
    // and priority are not in that capture (no cookie was set, and h1 carries
    // no priority), so they are left to the trailing pass, which puts them
    // behind everything named here -- where every other table has them anyway.
    const chrome_worker_script_order = [_][]const u8{
        "Accept",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-Dest",
        "Referer",
        "User-Agent",
        "Accept-Encoding",
        "Accept-Language",
    };

    const chrome_subresource_before_map = [_][]const u8{
        "Content-Length",
        // Both ahead of the map block: on the `top-reload` row of
        // scratch/b120/blob-chrome.json they arrive right behind Connection,
        // in front of sec-ch-ua-platform. Their order relative to
        // Content-Length is not measured -- no captured request carried a body
        // and a cache mode at once.
        "Pragma",
        "Cache-Control",
    };

    const chrome_subresource_after_map = [_][]const u8{
        "Accept",
        "Origin",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-Dest",
        // Same place as on a navigation -- measured on the cross-site image and
        // the four cross-site fetches of scratch/b117/sa-chrome-p2.json, five
        // rows agreeing.
        "Sec-Fetch-Storage-Access",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        "Cookie",
        "priority",
    };

    // The engine's own map-block fields, in the order the renderer inserts them
    // into the map. Insertion order is invisible unless two names collide, so
    // most shapes cannot see it -- three do, and between them they pin it: five
    // author headers alongside the baseline hints (`hold-five` in
    // results/b59-h1-chrome.json), and the two nine-hint blocks below, where
    // sec-ch-ua collides with sec-ch-ua-bitness and User-Agent with
    // sec-ch-ua-full-version.
    //
    // What comes out is the hints in the order they are declared -- the same
    // sequence chrome_navigation_order carries, which is what the browser side
    // writes too -- and User-Agent behind them. A request carries the three
    // baseline hints plus whatever its origin asked for via Accept-CH; the
    // absent names just drop out of the sequence.
    //
    // content-type last is the one placement here rather than a measurement: it
    // collides with nothing in any capture we have, so every shape we can check
    // comes out the same wherever it sits.
    const blink_map_insertion = [_][]const u8{
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-full-version",
        "sec-ch-ua-arch",
        "sec-ch-ua-platform",
        "sec-ch-ua-platform-version",
        "sec-ch-ua-model",
        "sec-ch-ua-bitness",
        "sec-ch-ua-full-version-list",
        "User-Agent",
        "content-type",
    };

    // A navigation re-sent for a Critical-CH, which Chrome does not spell like
    // a fresh navigation carrying the same nine hints: Upgrade-Insecure-
    // Requests, User-Agent and Accept move ahead of the whole hint block.
    // Measured, the second `GET /critical-ch` in
    // tools/fingerprint/results/acceptch-chrome.json -- and it is the shape
    // that matters most here, because a Critical-CH restart is exactly what
    // Cloudflare's challenge provokes.
    const chrome_restarted_navigation_order = [_][]const u8{
        "Upgrade-Insecure-Requests",
        "User-Agent",
        "Accept",
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-full-version",
        "sec-ch-ua-arch",
        "sec-ch-ua-platform",
        "sec-ch-ua-platform-version",
        "sec-ch-ua-model",
        "sec-ch-ua-bitness",
        "sec-ch-ua-full-version-list",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-User",
        "Sec-Fetch-Dest",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        "Cookie",
        "priority",
    };

    // A CORS preflight, which is not the subresource table with two names
    // added: Chrome leads with Accept, puts the two Access-Control-Request-*
    // fields ahead of Origin, and -- unlike every other shape here -- writes
    // Sec-Fetch-Mode *before* Sec-Fetch-Site. Measured, the OPTIONS requests of
    // tools/fingerprint/results/b57-cors-chrome.json (all five agree).
    // No Content-Length and no Cookie: a preflight has no body and is never
    // credentialed, so neither name has a measured position to give it.
    const chrome_preflight_order = [_][]const u8{
        "Accept",
        "Access-Control-Request-Method",
        "Access-Control-Request-Headers",
        "Origin",
        "User-Agent",
        "Sec-Fetch-Mode",
        "Sec-Fetch-Site",
        "Sec-Fetch-Dest",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        "priority",
    };

    // Materializes req_headers onto the connection in Chrome's order.
    //
    // One emission stays out of our hands: curl writes `Host` first, which is
    // where Chrome has it anyway. `Connection: keep-alive` is the remaining
    // gap -- Chrome sends it on HTTP/1.1, curl sends nothing, and we cannot add
    // it from here because the same list is reused for an HTTP/2 attempt, where
    // a connection header is a protocol error.
    // Which fixed table this request's fields come out in, or null for the
    // subresource shape, which has no table at all -- see
    // chrome_subresource_before_map.
    fn orderTable(self: *const Transfer) ?[]const []const u8 {
        if (self.req.preflight) return &chrome_preflight_order;
        if (self.req.resource_type == .document) {
            return if (self._critical_hints_restarted)
                &chrome_restarted_navigation_order
            else
                &chrome_navigation_order;
        }
        if (self.req.resource_type == .worker) return &chrome_worker_script_order;
        return null;
    }

    fn emitHeaders(self: *Transfer, conn: *http.Connection, arena: Allocator) !void {
        // Bitset of what an ordered pass already emitted, so the trailing pass
        // can skip them without a second name comparison per header.
        var emitted = [_]bool{false} ** 64;

        if (self.orderTable()) |order| {
            try self.emitNamed(conn, arena, order, &emitted);
        } else {
            try self.emitNamed(conn, arena, &chrome_subresource_before_map, &emitted);
            try self.emitMapBlock(conn, arena, &emitted);
            try self.emitNamed(conn, arena, &chrome_subresource_after_map, &emitted);
        }

        const tracked = @min(self.req_headers.items.len, emitted.len);
        for (self.req_headers.items, 0..) |hdr, i| {
            if (i < tracked and emitted[i]) continue;
            try conn.addHeader(arena, hdr.name, hdr.value);
        }
    }

    fn emitNamed(
        self: *Transfer,
        conn: *http.Connection,
        arena: Allocator,
        order: []const []const u8,
        emitted: *[64]bool,
    ) !void {
        const tracked = @min(self.req_headers.items.len, emitted.len);
        for (order) |name| {
            for (self.req_headers.items[0..tracked], 0..) |hdr, i| {
                if (emitted[i]) continue;
                if (std.ascii.eqlIgnoreCase(hdr.name, name) == false) continue;
                try conn.addHeader(arena, hdr.name, hdr.value);
                emitted[i] = true;
                // No break: a name can legitimately appear once only, but if a
                // duplicate ever survives putHeader's dedup, keeping it beside
                // its twin is better than stranding it in the trailing pass.
            }
        }
    }

    // The fields the renderer keeps in Blink's HTTPHeaderMap, emitted in that
    // map's bucket order. Which fields those are is decided by exclusion: this
    // runs between the two ordered brackets, so anything already emitted or named
    // in the trailing bracket is out, and what is left is the hint block, the
    // engine's User-Agent and content-type, and the page's own headers.
    //
    // Only `.author` headers are gathered from the page side. A CDP or --http-
    // header extra is not something any capture covers, and moving it into the
    // block would be a guess; it keeps falling to the trailing pass as before.
    fn emitMapBlock(self: *Transfer, conn: *http.Connection, arena: Allocator, emitted: *[64]bool) !void {
        const items = self.req_headers.items;
        const tracked = @min(items.len, emitted.len);

        var names: [blink_header_order.max_names][]const u8 = undefined;
        var slots: [blink_header_order.max_names]usize = undefined;
        var n: usize = 0;

        // The page's own headers first, in the order it set them: that is the
        // order they reach the map, and it decides the outcome whenever two of
        // the names collide.
        for (items[0..tracked], 0..) |hdr, i| {
            if (n == names.len) break;
            if (emitted[i] or hdr.source != .author) continue;
            if (namedIn(&chrome_subresource_after_map, hdr.name)) continue;
            names[n] = hdr.name;
            slots[n] = i;
            n += 1;
        }

        for (blink_map_insertion) |name| {
            for (items[0..tracked], 0..) |hdr, i| {
                if (n == names.len) break;
                if (emitted[i] or hdr.source == .author) continue;
                if (std.ascii.eqlIgnoreCase(hdr.name, name) == false) continue;
                names[n] = hdr.name;
                slots[n] = i;
                n += 1;
            }
        }

        var order: [blink_header_order.max_names]u8 = undefined;
        // More names than the model can lay out: leave every one of them to the
        // trailing pass rather than emit a partial block in the wrong place.
        const count = blink_header_order.bucketOrder(names[0..n], &order) orelse return;
        for (order[0..count]) |slot| {
            const i = slots[slot];
            try conn.addHeader(arena, items[i].name, items[i].value);
            emitted[i] = true;
        }
    }

    fn namedIn(order: []const []const u8, name: []const u8) bool {
        for (order) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
        }
        return false;
    }

    // The client's baseline headers, added to every request at creation.
    fn seedHeaders(self: *Transfer) !void {
        // A preflight carries no client hints at all -- not the three baseline
        // ones, not the negotiated ones -- while the request it asks about
        // carries the full set. Measured on Chrome 151: the OPTIONS of the
        // `post-json` case in tools/fingerprint/results/b57-cors-chrome.json
        // has no sec-ch-ua* field, the POST behind it has three.
        const preflight = self.req.preflight;

        // Nor does anything to do with a worker: neither the fetch of the
        // worker's own script nor a request the worker then makes carries a
        // single sec-ch-ua* field, where the page that made the worker carries
        // three (measured, the `url-worker` / `blob-worker` rows and the
        // `/w/url-worker.js` fetch of scratch/b120/blob-chrome.json).
        const worker = self.req.from_worker or self.req.resource_type == .worker;
        const hintless = preflight or worker;

        for (self.client.baselineHeaders()) |hdr| {
            if (hintless and std.ascii.startsWithIgnoreCase(hdr.name, "sec-ch-ua")) continue;
            try self.addHeader(hdr.name, hdr.value, .{ .source = hdr.source });
        }

        if (!hintless) {
            try self.seedClientHints();
        }

        // --http-header extras; setHeader so a same-name header (e.g.
        // Accept-Language) overrides the baseline instead of duplicating.
        for (self.client.network.config.httpHeaders()) |hdr| {
            try self.setHeader(hdr.name, hdr.value, .{ .source = .cli });
        }

        try self.seedCacheControl();
        try self.seedFetchMetadata();
        try self.seedContentLength();
    }

    // The RequestInit `cache` member, as Chrome spells it on the wire.
    // Measured across the five values a same-origin GET can carry
    // (tools/fingerprint/scratch/b120/blob-chrome.json): `no-cache` asks to
    // revalidate and says so with a zero lifetime, `reload` and `no-store` skip
    // the cache outright and add the HTTP/1.0 field beside it, and the other
    // three put nothing on the request at all.
    //
    // `only-if-cached` was not measured -- it is only legal in same-origin mode
    // and never reaches a server when the cache answers -- so it is grouped
    // with the silent ones rather than guessed into a field.
    fn seedCacheControl(self: *Transfer) !void {
        switch (self.req.cache) {
            .default, .force_cache, .only_if_cached => {},
            .no_cache => try self.setHeader("Cache-Control", "max-age=0", .{ .source = .cdp }),
            .reload, .no_store => {
                try self.setHeader("Pragma", "no-cache", .{ .source = .cdp });
                try self.setHeader("Cache-Control", "no-cache", .{ .source = .cdp });
            },
        }
    }

    // The high-entropy hints this request's origin asked for via Accept-CH,
    // and only those. They are not in baselineHeaders because unsolicited they
    // are a tell of their own -- see the note there. Once an origin has asked,
    // Chrome puts them on every request to it, navigation and subresource
    // alike, which is what makes the difference visible on every hop rather
    // than only on the document.
    //
    // Forbidden header names, so they enter at `.cdp`, the same rank the three
    // baseline hints use: page script cannot rewrite one, a driver still can.
    //
    // Read against the request's own URL. A cross-origin redirect therefore
    // keeps the hints the first hop's origin asked for, where Chrome would
    // re-resolve per hop; the seeding happens once, when the transfer is built.
    // setHeader rather than addHeader, unlike the baseline seeding beside it:
    // the Critical-CH restart re-runs this on a request that may already carry
    // some of the hints, and a duplicated field name is its own tell.
    fn seedClientHints(self: *Transfer) !void {
        var it = self.client.client_hints.acceptedFor(self.req.url).iterator();
        while (it.next()) |hint| {
            try self.setHeader(hint.header(), self.client.clientHintValue(hint), .{ .source = .cdp });
        }
    }

    // Does this response say it is only valid with hints the request didn't
    // carry? `Critical-CH` is the stronger half of the negotiation: `Accept-CH`
    // alone means "next time", `Critical-CH` means "that answer was for someone
    // else, ask me again". Chrome obeys it by discarding the response and
    // re-sending the same navigation at once -- measured, the two
    // `GET /critical-ch` hits in tools/fingerprint/results/acceptch-chrome.json
    // where the first carries three hints and the second nine.
    //
    // Call after the response's Accept-CH has been recorded: what the origin
    // will accept is half the question, and the other half is what this request
    // already sent.
    fn shouldRestartForCriticalHints(self: *const Transfer) bool {
        if (self.req.resource_type != .document) {
            return false;
        }
        if (self._critical_hints_restarted) {
            return false;
        }

        var accepted = self.client.client_hints.acceptedFor(self.req.url);
        if (accepted.count() == 0) {
            // Either nothing was accepted or the origin isn't one we remember
            // hints for. Restarting would re-send a byte-identical request.
            return false;
        }

        for (self.res.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "critical-ch") == false) {
                continue;
            }
            // A hint is worth a restart only if the origin accepts it (so we
            // would send it next time) *and* this request went without it.
            // A Critical-CH we can't fully answer buys nothing by restarting:
            // the Accept-CH beside it was declined for the same reason, so the
            // second request would be the first one again.
            var wanted = ClientHints.parse(hdr.value) orelse continue;
            wanted.setIntersection(accepted);
            var it = wanted.iterator();
            while (it.next()) |hint| {
                if (self.findRequestHeader(hint.header()) == null) {
                    return true;
                }
            }
        }
        return false;
    }

    // The destination's `Accept` plus the Sec-Fetch-* set, which real Chrome
    // sends on every request and which this engine sent on none before it
    // existed. This is the only place that knows both the destination
    // (resource_type) and the initiator (nav / cookie_origin), which is what
    // Sec-Fetch-Site needs.
    //
    // Sec-Fetch-* are forbidden header names — page script cannot set them — so
    // they enter at `.cdp`, above an author's reach but still replaceable by a
    // driver. `Accept` is different: fetch()/XHR may legitimately specify it,
    // so it enters at the default rank and a later author/CDP/CLI value wins.
    fn seedFetchMetadata(self: *Transfer) !void {
        const H = Config.HttpHeaders;
        const req = &self.req;

        try self.setHeader("Accept", switch (req.resource_type) {
            .document => H.Accept.document,
            .stylesheet => H.Accept.style,
            .image => H.Accept.image,
            .eventsource => H.Accept.event_stream,
            // A font asks for `*/*`, the same as a script (measured).
            .script, .worker, .fetch, .xhr, .font => H.Accept.any,
        }, .{});

        // Chrome labels a subframe navigation "iframe" and a top-level one
        // "document"; everything else is named after the destination.
        try self.setHeader("Sec-Fetch-Dest", switch (req.resource_type) {
            .document => if (req.nav) |n| (if (n.subframe) "iframe" else "document") else "document",
            .stylesheet => "style",
            .image => "image",
            .script => "script",
            // A worker's own script is not a `script` destination; Chrome
            // spells it `worker` (measured, scratch/b120/blob-chrome.json).
            .worker => "worker",
            .font => "font",
            // fetch(), XHR and EventSource all report an empty destination.
            .fetch, .xhr, .eventsource => "empty",
        }, .{ .source = .cdp });

        try self.setHeader("Sec-Fetch-Mode", switch (req.requestMode()) {
            .navigate => "navigate",
            .no_cors => "no-cors",
            .cors => "cors",
            .same_origin => "same-origin",
        }, .{ .source = .cdp });

        try self.setHeader("Sec-Fetch-Site", if (self.initiatorOrigin()) |origin|
            switch (fetchSite(origin, req.url)) {
                .same_origin => "same-origin",
                .same_site => "same-site",
                .cross_site => "cross-site",
            }
        else
            "none", .{ .source = .cdp });

        // Sec-Fetch-Storage-Access, which Chrome puts on a request whose cookies
        // are partitioned -- and only there. Two halves, and both are needed:
        //
        //   * the request is CREDENTIALED. Three cross-site fetches differing
        //     only in `credentials` split this half off by themselves: `include`
        //     carries the field, the same-origin default and `omit` do not.
        //     Here that is exactly "a jar is attached".
        //   * its cookies are THIRD-PARTY, i.e. either the request is cross-site
        //     with the top-level document, or the asking document already is --
        //     a cross-site frame carries the field even on a request pointing
        //     back at the top-level site.
        //
        // Measured over sixteen rows across two top-level documents,
        // tools/fingerprint/scratch/b117/sa-chrome-p2.json. `active` is the only
        // value ever observed; the spec's `none` and `inactive` never appeared,
        // so nothing here tries to guess when they would.
        if (req.credentialsAllowed()) {
            if (req.partition) |p| {
                if (p.third_party_client or !sameSiteForStorage(p.top_level_url, req.url)) {
                    try self.setHeader("Sec-Fetch-Storage-Access", "active", .{ .source = .cdp });
                }
            }
        }

        try self.seedOrigin();

        // Only navigations carry these two, and Sec-Fetch-User only when the
        // navigation came from a user gesture rather than from script.
        if (req.resource_type == .document) {
            try self.setHeader("Upgrade-Insecure-Requests", H.upgrade_insecure_requests, .{ .source = .cdp });
            if (req.nav) |n| {
                if (n.user_activated) try self.setHeader("Sec-Fetch-User", "?1", .{ .source = .cdp });
            }
        }

        // RFC 9218 extensible priorities. Chrome sends a hint on every HTTP/2
        // and HTTP/3 request and nothing at all on HTTP/1.1, where the field
        // has no meaning -- measured, 16 of 16 requests against a local http2
        // echo and 0 of 14 against the h1 one. Emitted unconditionally here
        // because this header list is reused across an h1 and an h2 attempt
        // (see the note on emitHeaders); the vendored curl drops the field
        // below h2, the mirror of what it already does for Connection.
        //
        // The values are per destination: u=0 for the render-blocking
        // destinations, u=1 for the rest, and incremental everywhere except
        // style and script. Chrome re-sends a bare `i` for an image once it
        // matters on screen; that re-prioritisation is not modelled, so an
        // image always carries the value of its first request.
        try self.setHeader("priority", req.priority orelse switch (req.resource_type) {
            .document => "u=0, i",
            .stylesheet => "u=0",
            // A font is urgent and not incremental -- there is nothing to show
            // until all of it is there (measured over h2).
            // A worker script is grouped with `script` rather than measured:
            // the capture that named its destination was HTTP/1.1, where the
            // field is not sent at all.
            .script, .worker, .font => "u=1",
            // EventSource was not in the capture, grouped with fetch and XHR
            // the way every other per-destination switch here groups it.
            .image, .fetch, .xhr, .eventsource => "u=1, i",
        }, .{ .source = .cdp });
    }

    // The origin of the document that asked for this request, as Sec-Fetch-Site
    // and the Origin header both need it. A null return is "no initiator
    // document at all" -- an address-bar navigation, a bookmark, an internal
    // fetch -- which is not the same as a request whose initiator has an opaque
    // origin, and is what Sec-Fetch-Site reports as `none`.
    fn initiatorOrigin(self: *const Transfer) ?[]const u8 {
        const req = &self.req;
        if (req.resource_type == .document) {
            return if (req.nav) |n| n.initiator_origin else null;
        }
        return self.initiatorUrl();
    }

    // The initiating document's URL, from whichever copy holds it.
    //
    // There are two, and only one is filled in on a served page: makeTransfer
    // resolves `req.cookie_origin orelse owner.siteForCookies()` onto the
    // transfer and then sets `owned.cookie_origin = null`, so a real
    // subresource always reads null off the request. Reading only the
    // request's copy is what made Sec-Fetch-Site answer `none` -- "a user
    // typed this in the address bar" -- on every stylesheet, script, image and
    // fetch this engine has ever sent, a combination no browser can produce
    // (measured against Chrome over both relationships, 9 of 9 wrong,
    // scratch/b146/site-echo.mjs).
    //
    // The request's copy is still read first because the unit tests build a
    // Transfer directly and set it there, never going through makeTransfer.
    // Dropping it would trade a real-page bug for a test-path one.
    fn initiatorUrl(self: *const Transfer) ?[:0]const u8 {
        if (self.req.cookie_origin) |c| switch (c) {
            .url => |u| return u,
            .none => {},
        };
        return switch (self.cookie_origin) {
            .none => null,
            .url => |u| u,
        };
    }

    // Content-Length, written by us rather than left to curl. Not because the
    // number differs -- curl computes the same body length -- but because
    // curl's copy comes out of its H1_HD_CONTENT slot, after every custom
    // header, where Chrome has the field third on the wire, right behind Host
    // and Connection. A header we own is a header emitHeaders can place; curl
    // skips its own once ours is in the list (Curl_checkheaders in
    // deps/curl-patched/lib/http.c).
    //
    // Re-run after a redirect changes the request: a 301/302/303 turns it into
    // a GET and drops the body, and a length header left behind announces bytes
    // that will never be sent.
    // The jar's cookies, written by us rather than handed to curl. Same reason
    // as Content-Length above: CURLOPT_COOKIE comes out of curl's own slot,
    // immediately behind the pseudo headers, where Chrome has the field second
    // to last with only `priority` behind it (measured over h2 on a
    // navigation, a subresource, an XHR POST and a fetch POST -- every other
    // name already matched). A header we own is a header emitHeaders can
    // place, and curl skips its own once ours is in the list.
    //
    // Re-run on every attempt, because a redirect can cross an origin: the
    // cookies for the new URL are a different set, and a stale header would
    // hand them to a host the jar never meant to.
    // Enters at `.user_agent`, the engine's own layer, so an author's or a
    // driver's Cookie header outranks it and the jar stays out of the way --
    // which is what happened before too, curl skipping CURLOPT_COOKIE whenever
    // a Cookie header was already in the list (Curl_checkheaders).
    fn seedCookie(self: *Transfer) !void {
        const cookies = try self.getCookieString(self.arena.allocator()) orelse {
            // Drop only our own: a header from a higher layer was never ours
            // to withdraw.
            for (self.req_headers.items) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "Cookie") and hdr.source != .user_agent) return;
            }
            self.removeHeader("Cookie");
            return;
        };
        try self.setHeader("Cookie", cookies, .{});
    }

    fn seedContentLength(self: *Transfer) !void {
        const body = self.req.body orelse {
            self.removeHeader("Content-Length");
            return;
        };
        const value = try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{body.len});
        try self.setHeader("Content-Length", value, .{ .source = .cdp });
    }

    // Fetch's "append a request `Origin` header", which is not "the origin of
    // every request": a request gets one when its response tainting is cors --
    // any cross-origin fetch/XHR -- or when its method is neither GET nor HEAD.
    // So a same-origin POST carries it and the same-origin GET beside it does
    // not. Measured on the Chrome side in
    // tools/fingerprint/results/acceptch-chrome.json, where the same-origin
    // `POST /sub/xhr-*` has `Origin: http://127.0.0.1:9586` and the
    // `GET /sub/fetch-*` from the same page has none. Before this, no request
    // this engine made carried the header at all, on a POST-shaped surface --
    // Cloudflare's managed challenge is three of them -- which is a difference
    // no real browser has.
    //
    // A forbidden header name, so it enters at `.cdp` like the Sec-Fetch-* set:
    // page script cannot forge one, a driver's override still lands.
    //
    // Only the cors destinations for now. A form POST navigation carries an
    // Origin in Chrome too, with its own referrer-policy-driven downgrade to
    // `null`; that shape is unmeasured here, so it is left alone rather than
    // guessed at.
    // Re-run after a redirect for the same reason as seedContentLength: a 303
    // that turns a same-origin POST into a GET is a request that no longer
    // qualifies, and Fetch re-decides this per hop rather than once.
    fn seedOrigin(self: *Transfer) !void {
        if (try self.originHeader()) |value| {
            try self.setHeader("Origin", value, .{ .source = .cdp });
        } else {
            self.removeHeader("Origin");
        }
    }

    fn originHeader(self: *Transfer) !?[]const u8 {
        const req = &self.req;
        // A `crossorigin` subresource names its origin unconditionally --
        // same-origin included, unlike the fetch rule below. Measured: a
        // same-origin `<script crossorigin src>` and `<img crossorigin>` both
        // carry `Origin: <page origin>` in Chrome, while a same-origin GET
        // through fetch() carries none
        // (probes/b87-crossorigin-request-fixture.mjs).
        const cors_mode = req.requestMode() == .cors;
        const element_cors = cors_mode and switch (req.resource_type) {
            .stylesheet, .script, .image, .font => true,
            .document, .worker, .fetch, .xhr, .eventsource => false,
        };
        const safe_method = req.method == .GET or req.method == .HEAD;
        if (!element_cors) {
            switch (req.resource_type) {
                // A no-cors request names nobody, whatever its destination:
                // `<link rel=preload as=fetch>` has a fetch's destination and a
                // no-cors mode, and Chrome sends it without an Origin.
                //
                // Unless the METHOD names it anyway. Chrome puts an Origin on
                // every non-GET/HEAD request whatever the mode -- measured, the
                // twelve POST rows of
                // tools/fingerprint/scratch/b118/fm-chrome.json, which include
                // no-cors and same-origin. This branch used to be unreachable
                // for a fetch (every fetch was cors here, because the page's
                // `mode` was dropped on the way down), so returning early was
                // right for as long as it never ran.
                .fetch, .xhr, .eventsource => if (!cors_mode and safe_method) return null,
                .document, .stylesheet, .script, .worker, .image, .font => return null,
            }
        }

        // No initiator document at all (an internal or CDP-issued request) is
        // not an opaque origin -- there is nothing to name, so nothing is sent.
        const origin = self.initiatorOrigin() orelse return null;
        if (origin.len == 0) return null;

        const tainting_cors = fetchSite(origin, req.url) != .same_origin;
        if (!element_cors and !tainting_cors and safe_method) return null;

        // The initiator's origin, serialized: scheme, host, non-default port,
        // nothing else. `null` for anything without a tuple origin (a data: or
        // about: document), which is what Chrome sends for an opaque origin.
        //
        // Read off cookie_origin, the initiator document's URL, so an
        // about:blank frame that inherited its parent's origin reports `null`
        // where Chrome would name the parent -- the same limit Sec-Fetch-Site
        // already has, and not one this header introduces.
        //
        // Through initiatorUrl for the same reason Sec-Fetch-Site goes through
        // it: the request's copy is null on a served page. This line could not
        // be wrong before, because initiatorOrigin's null returned above and
        // nothing reached here -- one bug hiding the other.
        const origin_url = self.initiatorUrl() orelse return "null";
        return (try URL.getOrigin(self.arena.allocator(), origin_url)) orelse "null";
    }

    // CDP Fetch.continueRequest: the intercepting client supplies the
    // complete header set, replacing whatever the request carried.
    pub fn replaceRequestHeaders(self: *Transfer, headers: []const http.Header) !void {
        lp.assert(self._intercept_original_headers == null, "Transfer.replaceRequestHeaders", .{ .id = self.id });
        self._intercept_original_headers = try self.arena.allocator().dupe(RequestHeader, self.req_headers.items);
        self.req_headers.clearRetainingCapacity();
        try self.seedHeaders();
        for (headers) |hdr| {
            try self.setHeader(hdr.name, hdr.value, .{ .source = .cdp });
        }
    }

    fn restoreInterceptHeaders(self: *Transfer) void {
        const headers = self._intercept_original_headers orelse return;
        self.req_headers.clearRetainingCapacity();
        // _intercept_original_headers.items.len MIGHT be larger than self.req_headers.items.len
        // but the capacity never shrank from when _intercept_original_headers WAS req_headers.
        self.req_headers.appendSliceAssumeCapacity(headers);
        self._intercept_original_headers = null;
    }

    // abortAuthChallenge is called when an auth challenge interception is
    // abort. We don't call self.releaseConn here b/c it has been done
    // before interception process.
    pub fn abortAuthChallenge(self: *Transfer) void {
        if (comptime lp.IS_DEBUG) {
            log.debug(.http, "abort auth transfer", .{ .intercepted = self.client.intercepted });
        }

        // The transfer is still .parked(.intercept_auth)
        self.abortParked(error.AbortAuthChallenge);
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 chunk at a time
        if (comptime lp.IS_DEBUG) {
            std.debug.assert(chunk_count == 1);
        }

        const conn: *http.Connection = @ptrCast(@alignCast(data));
        var transfer = conn.transport.http;
        const res = &transfer.res;

        if (!res.first_data_received) {
            res.first_data_received = true;

            // Skip body for responses that will be retried (redirects, auth challenges).
            const status = conn.getResponseCode() catch |err| {
                log.err(.http, "getResponseCode", .{ .err = err, .source = "body callback" });
                return http.writefunc_error;
            };

            // Only skip the body when the response will actually be retried
            // as a redirect (a redirect status with a Location header). Any
            // other 3xx is a final response whose body must be kept.
            if (isRedirectStatus(status) and conn.getResponseHeader("location", 0) != null) {
                res.skip_body = true;
                return @intCast(chunk_len);
            }

            if (transfer.req.headers_only == false) {
                if (transfer.getContentLength()) |cl| {
                    if (cl > transfer.client.max_response_size) {
                        res.callback_error = error.ResponseTooLarge;
                        return http.writefunc_error;
                    }
                    res.buffer.ensureTotalCapacityPrecise(transfer.arena.allocator(), cl) catch {};
                }
            }
        }

        if (res.skip_body) {
            return @intCast(chunk_len);
        }

        res.bytes_received += chunk_len;
        // Read per chunk rather than once at completion: a streaming transfer
        // hands its data to the consumer while the conn is still live, and the
        // consumer files its resource entry off the last chunk it sees.
        res.encoded_body_size = conn.getEncodedBodySize() catch res.encoded_body_size;

        if (transfer.req.headers_only) {
            // Plenty of images have no Content-Length to decide this up front, so
            // decide it as the body arrives.
            if (res.bytes_received <= Request.HEADERS_ONLY_DRAIN_MAX) {
                return @intCast(chunk_len);
            }

            // Returning writefunc_error is the only way to end a transfer
            // early from a write callback; processOneMessage recognises the
            // flag and treats the resulting CURLE_WRITE_ERROR as a completed
            // response with an empty body.
            res.headers_only_abort = true;
            return http.writefunc_error;
        }

        const chunk = buffer[0..chunk_len];

        if (transfer.req.streaming) {
            if (transfer.state == .aborted) {
                return http.writefunc_error;
            }
            // A stream's total is unbounded by design; cap the undelivered
            // batch instead — that's what actually occupies memory.
            if (res.buffer.items.len + chunk_len > transfer.client.max_response_size) {
                res.callback_error = error.ResponseTooLarge;
                return http.writefunc_error;
            }
            transfer.streamChunk(conn, chunk) catch |err| {
                res.callback_error = err;
                return http.writefunc_error;
            };
            return @intCast(chunk_len);
        }

        if (res.bytes_received > transfer.client.max_response_size) {
            res.callback_error = error.ResponseTooLarge;
            return http.writefunc_error;
        }

        res.buffer.appendSlice(transfer.arena.allocator(), chunk) catch |err| {
            res.callback_error = err;
            return http.writefunc_error;
        };

        if (transfer.state == .aborted) {
            return http.writefunc_error;
        }

        return @intCast(chunk_len);
    }

    fn streamChunk(self: *Transfer, conn: *http.Connection, chunk: []const u8) !void {
        const res = &self.res;
        if (res.stream.started == false) {
            // we haven't delivered the start/header events yet
            try self.materializeResponse(conn, .{});
            try self._events.ensureUnusedCapacity(self.arena.allocator(), 3);
            self._events.appendAssumeCapacity(.start);
            self._events.appendAssumeCapacity(.header);
            res.stream.started = true;
        }
        // append the data to whatever data we already have (but haven't delivered)
        try res.buffer.appendSlice(self.arena.allocator(), chunk);
        if (res.stream.data_queued == false) {
            res.stream.data_queued = true;
            try self._events.append(self.arena.allocator(), .stream_data);
        }

        switch (self.state) {
            .inflight => self.enqueueDispatch(),
            // deliver() is mid-batch on this transfer; its loop consumes
            // events appended behind its cursor.
            .delivering => {},
            else => if (comptime lp.IS_DEBUG) {
                lp.assert(false, "Transfer.scheduleStreamDispatch", .{ .state = self.state });
            },
        }
    }

    // Response-view accessors. Callbacks receive the *Transfer once the
    // response is materialized, so these are always safe from a callback;
    // header/status are null before that point.
    pub fn responseStatus(self: *const Transfer) ?u16 {
        const rh = self.res.header orelse return null;
        return rh.status;
    }

    pub fn contentType(self: *Transfer) ?[]const u8 {
        if (self.res.header) |*rh| {
            return rh.contentType();
        }
        return null;
    }

    pub fn responseTimes(self: *const Transfer) ResponseTimes {
        return self.res.times;
    }

    pub fn contentEncoding(self: *Transfer) ?[]const u8 {
        if (self.res.header) |*rh| {
            return rh.contentEncoding();
        }
        return null;
    }

    /// The two labels a `resource` PerformanceEntry quotes back, copied out of
    /// the response so they outlive the transfer. Every recorder captures this
    /// from its header callback and files it later.
    pub fn responseLabels(self: *Transfer) ResponseLabels {
        var labels: ResponseLabels = .{};
        if (self.contentType()) |ct| {
            labels.setContentType(ct);
        }
        if (self.contentEncoding()) |ce| {
            labels.setContentEncoding(ce);
        }
        if (self.timingAllowOrigin()) |tao| {
            labels.setTimingAllowOrigin(tao);
        }
        if (self.serverTiming()) |st| {
            labels.addServerTiming(st);
        }
        return labels;
    }

    /// The response's `Server-Timing` members, joined if it sent the header more
    /// than once. Empty when it sent none.
    pub fn serverTiming(self: *Transfer) ?[]const u8 {
        if (self.res.header) |*rh| {
            return rh.serverTiming();
        }
        return null;
    }

    /// The response's `Timing-Allow-Origin`, if it sent one. Whether it permits
    /// the reading document is `ResponseLabels.timingAllowed`'s question, not
    /// this one -- the origin doing the reading is not known down here.
    pub fn timingAllowOrigin(self: *Transfer) ?[]const u8 {
        if (self.res.header) |*rh| {
            return rh.timingAllowOrigin();
        }
        return null;
    }

    pub fn nextHopProtocol(self: *const Transfer) []const u8 {
        const rh = self.res.header orelse return "";
        return rh.next_hop_protocol;
    }

    /// Resource Timing's `encodedBodySize`: the body as it arrived, before the
    /// content-encoding was undone. Falls back to the decoded byte count for a
    /// response that never came off a socket -- a cache hit or a synthetic
    /// reply was not encoded, so the two sizes are the same number there.
    pub fn encodedBodySize(self: *const Transfer) u64 {
        if (self.res.encoded_body_size > 0) {
            return self.res.encoded_body_size;
        }
        return self.res.bytes_received;
    }

    /// What the response head weighed on the wire. CDP reports this as the
    /// `encodedDataLength` of a response at the moment `responseReceived`
    /// fires, when no body has arrived yet: measured against Chrome 151, a
    /// 135-byte head over a socket writing known bytes answered 135 there.
    /// Zero for a response that never came off a socket -- a cache hit, a
    /// data: URL, a reply an interceptor fulfilled -- which is also what
    /// Chrome reports for those.
    pub fn responseHeaderSize(self: *const Transfer) u64 {
        return self.res.header_bytes;
    }

    /// The whole response as it sat on the wire: head plus the body before
    /// its content-encoding was undone. This is CDP's `encodedDataLength` on
    /// `loadingFinished`; the same Chrome reading that answered 135 at the
    /// headers answered 7194 here, for a 7059-byte body.
    ///
    /// Reads slightly low for a chunked response, where Chrome counts the
    /// chunk headers and curl strips them before anything here can see them.
    pub fn encodedDataLength(self: *const Transfer) u64 {
        const body = self.encodedBodySize();
        if (body > 0) {
            return self.res.header_bytes + body;
        }
        // Nothing was counted off a socket, which is either an empty response
        // or one that never touched the network. The second kind still has a
        // length -- Chrome reports a data: subresource as its body's size, not
        // as nothing -- and `_content_length` is where the buffered paths put
        // it. Both readings are zero for a genuinely empty reply.
        return self.res.header_bytes + self._content_length;
    }

    pub fn redirectCount(self: *const Transfer) ?u32 {
        const rh = self.res.header orelse return null;
        return rh.redirect_count;
    }

    pub fn redirectTiming(self: *const Transfer) http.RedirectTiming {
        return .{
            .count = self._redirect_count,
            .same_origin = self._redirects_same_origin,
            .end_micros = self._last_redirect_micros,
        };
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        if (self.res.headers.len > 0 or self._conn == null) {
            return .{ .list = .{ .list = self.res.headers } };
        }
        // Mid-stream (pump time): headers aren't materialized yet, read
        // them off the live conn.
        return .{ .curl = .{ .conn = self._conn.? } };
    }

    pub fn getContentLength(self: *const Transfer) ?usize {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(usize, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        // Materialized headers (dispatch time, any source).
        for (self.res.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }

        // Mid-stream (curl's write callback): read from the live conn.
        if (self._conn) |c| {
            const cl = c.getResponseHeader("content-length", 0) orelse return null;
            return cl.value;
        }

        return null;
    }

    // Only ever called from tick, delivers buffered events to their consumer.
    // A buffered (completed) transfer gets exactly one deliver() and dies at
    // the end of it. A streaming transfer gets one deliver() per dispatched
    // batch and stays inflight between batches, until a terminal event
    // (done / err) or an abort.
    fn deliver(transfer: *Transfer) void {
        // A streaming batch is delivered while the conn is still inflight;
        // that state is restored after the batch unless it turned terminal.
        const was_inflight = transfer.state == .inflight;

        // Important. If a callback tries to kill the transfer (e.g. abort()),
        // this will cause the teardown to be deferred so that it doesn't get
        // freed from under us.
        transfer.state = .delivering;

        const req = &transfer.req;
        if (transfer._from_cache) {
            transfer.notify(
                .http_request_served_from_cache,
                &.{ .transfer = transfer },
            );
        }

        // Index loop, re-reading len and items on every iteration: a
        // streaming transfer's callback can re-enter the pump (syncRequest)
        // and append more events — possibly the terminal one — to the batch
        // being delivered.
        var terminal = !was_inflight;
        var i: usize = 0;
        while (i < transfer._events.items.len) : (i += 1) {
            if (transfer.state == .aborted) {
                // the state can become aborted as events are processed, check
                // it on every iteration.
                break;
            }
            const event = transfer._events.items[i];
            switch (event) {
                .start => {
                    if (req.start_callback) |cb| {
                        cb(transfer) catch |err| {
                            return transfer.failDelivery(err);
                        };
                    }
                },
                .header => {
                    if (transfer._notify_cdp) {
                        transfer.notify(.http_response_header_done, &.{
                            .transfer = transfer,
                        });
                    }
                    const result = req.header_callback(transfer) catch |err| {
                        return transfer.failDelivery(err);
                    };
                    if (result == .abort) {
                        return transfer.failDelivery(error.Abort);
                    }
                },
                .data => |chunk| {
                    if (transfer._notify_cdp) {
                        transfer.notify(.http_response_data, &.{
                            .data = chunk,
                            .transfer = transfer,
                        });
                    }
                    transfer._timing.decoded_body_size += chunk.len;
                    req.data_callback(transfer, chunk) catch |err| {
                        return transfer.failDelivery(err);
                    };
                },
                .stream_data => {
                    // Move the batch into stream.spare and deliver it from
                    // there: chunks received during the callback (re-entrant
                    // pump) append to the swapped-in buffer and queue a new
                    // .stream_data that this loop picks up, while the batch
                    // the consumer is reading stays untouched. The batch is
                    // only valid during the callback — it's cleared right
                    // after, ready to be swapped back in.
                    const res = &transfer.res;
                    res.stream.data_queued = false;
                    std.mem.swap(std.ArrayList(u8), &res.buffer, &res.stream.spare);
                    const chunk = res.stream.spare.items;
                    if (transfer._notify_cdp) {
                        transfer.notify(.http_response_data, &.{
                            .data = chunk,
                            .transfer = transfer,
                        });
                    }
                    transfer._timing.decoded_body_size += chunk.len;
                    req.data_callback(transfer, chunk) catch |err| {
                        return transfer.failDelivery(err);
                    };
                    res.stream.spare.clearRetainingCapacity();
                },
                .done => {
                    terminal = true;
                    if (transfer._notify_cdp) {
                        transfer.notify(.http_request_done, &.{
                            .transfer = transfer,
                        });
                    }
                    transfer._outcome_delivered = true;
                    req.done_callback(req.ctx) catch |err| {
                        return transfer.failDelivery(err);
                    };
                },
                .err => |err| {
                    terminal = true;
                    transfer.requestFailed(err);
                    break;
                },
            }
        }

        if (transfer.state == .aborted or terminal) {
            transfer.finishDelivery();
            return;
        }

        // Mid-stream batch fully delivered; the conn is still receiving.
        transfer._events.clearRetainingCapacity();
        transfer.state = .inflight;
    }

    fn finishDelivery(self: *Transfer) void {
        if (self.state == .aborted and self._outcome_delivered == false) {
            // the transfer is aborted and hasn't had a done/error/shutdown
            // callback called yet.
            self.req.shutdown_callback(self.req.ctx);
        }
        self.deinit();
    }
};

// What a transfer collects for its PerformanceResourceTiming entry. Absolute
// boot-clock microseconds, 0 = not (yet) known. Lives on the Transfer, not
// on Response: the redirect fields span hops and reset() must not clear it.
const ResourceTiming = struct {
    // The URL as requested; the entry's name. Redirects rewrite req.url.
    url: [:0]const u8 = "",
    start_time: u64 = 0,
    redirect_start: u64 = 0,
    redirect_end: u64 = 0,
    // Start of the final hop (== start_time without a redirect).
    fetch_start: u64 = 0,
    // When the current hop's conn was handed to the multi.
    hop_start: u64 = 0,
    dns_start: u64 = 0,
    dns_end: u64 = 0,
    connect_start: u64 = 0,
    connect_end: u64 = 0,
    secure_start: u64 = 0,
    request_start: u64 = 0,
    response_start: u64 = 0,
    response_end: u64 = 0,
    // Wire bytes, from libcurl; body bytes handed to the consumer, counted
    // as they're delivered (so a cache hit or a stream is right too).
    encoded_body_size: u64 = 0,
    decoded_body_size: u64 = 0,
    protocol: []const u8 = "",
    cache: CacheState = .none,
    // Cleared by the first redirect response that fails the TAO check.
    timing_allow: bool = true,
    // Set once a redirect hops from one foreign origin to another; from then
    // on only a wildcard Timing-Allow-Origin passes, same-origin included.
    // https://fetch.spec.whatwg.org/#concept-request-tainted-origin
    tainted: bool = false,
    recorded: bool = false,

    const CacheState = enum { none, local, validated };

    fn start(self: *ResourceTiming, url: [:0]const u8) void {
        const now = lp.datetime.microTimestamp(.boot);
        self.url = url;
        self.start_time = now;
        self.fetch_start = now;
    }
};

// Response-state owned by this transfer's currently-in-flight response.
// Reset on every retry (auth retry, redirect) via Transfer.reset — only
// the cross-retry counters (_auth_challenge, _redirect_count) live on
// Transfer itself. Consumers read it through the accessors above
// (status / contentType / responseHeaderIterator / getContentLength).
const Response = struct {
    header: ?http.ResponseHead = null,

    // Full response headers, materialized into the transfer arena at
    // completion (or set directly by cache / synthetic / fulfill).
    headers: []const http.Header = &.{},

    // Body bytes handed to the write callback, which sees the body *after*
    // curl has undone any content-encoding. Compare encoded_body_size below
    // for what the server actually sent.
    bytes_received: usize = 0,

    // What the response head weighed on the wire: status line, headers, and
    // the blank line ending them. Captured where the conn is still ours,
    // since that is also the moment the head is complete.
    header_bytes: u64 = 0,

    // Body bytes as they came off the socket, before curl undid any
    // content-encoding -- Resource Timing's `encodedBodySize`. The callbacks
    // above see the *decoded* body, so for every compressed response this is
    // the smaller of the two numbers, and it is the only one the server can be
    // said to have sent.
    encoded_body_size: u64 = 0,

    // The connection walk behind this response, captured where the conn is
    // still ours. Every consumer files its entry long after that.
    times: http.ResponseTimes = .{},

    skip_body: bool = false,
    first_data_received: bool = false,

    // Set when dataCallback deliberately killed the transfer to satisfy
    // `Request.headers_only`. processOneMessage uses it to tell our own
    // abort apart from a real CURLE_WRITE_ERROR and deliver the response
    // (headers, status, empty body) as a success.
    headers_only_abort: bool = false,

    // Response body. Filled by dataCallback, consumed in processMessages.
    // See Stream.spare to see how this works in streaming mode
    buffer: std.ArrayList(u8) = .empty,

    // Error captured in dataCallback to be reported in processMessages.
    callback_error: ?anyerror = null,

    // State for streaming. Unused in non-streaming
    stream: Stream = .{},

    const Stream = struct {
        // Whether we've queued the start/header events or not
        started: bool = false,

        // We only queue one .stream_data event at a time, it drains whatever
        // has accumulated since the last deliver
        data_queued: bool = false,

        // Along with the main Response.buffer, acts as a double buffer allowing
        // us to accumulate new data while in a delivery callback.
        spare: std.ArrayList(u8) = .empty,
    };
};

// A single buffered response event. The payload of `data` has transfer-arena
// lifetime. `done`, and `err` are terminal — nothing follows them.
const Event = union(enum) {
    start,
    header,
    data: []const u8,
    stream_data, // the payload is carried in res.stream.data_queued
    done,
    err: anyerror,
};

// What the http cache wants from a transfer's response.
const CacheIntent = union(enum) {
    none,

    // Inspect the response at completion and store it if cacheable.
    store,

    // Conditional request in flight; on a 304 the stale entry is renewed
    // and served. Owns the entry (possibly an open file) until resolved.
    revalidate: Cache.CachedResponse,
};

// Non-network URL schemes whose response is synthesized in-process rather than
// fetched, think blob data URLs.
const Synthetic = struct {
    const data_url = @import("../browser/data_url.zig");

    fn isSynthetic(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "blob:");
    }

    // Materialize the synthetic response onto the transfer and buffer it for
    // dispatch — delivered exactly like any other response.
    fn buffer(transfer: *Transfer) !void {
        const arena = transfer.arena;
        const url = transfer.req.url;

        var body: []const u8 = "";
        var content_type: []const u8 = "";

        if (std.mem.startsWith(u8, url, "data:")) {
            const parsed = try data_url.parse(arena.allocator(), url);
            content_type = parsed.content_type;
            body = parsed.body;
        } else {
            // Fetch: a blob: request with any other method is a network error.
            if (transfer.req.method != .GET) {
                return error.BlobMethodNotAllowed;
            }

            const owner = transfer.owner orelse return error.BlobNotFound;
            const key = url[0 .. std.mem.indexOfScalar(u8, url, '#') orelse url.len];
            if (!Owner.Blob.urlBelongsToOrigin(key, owner.origin.*)) {
                return error.BlobNotFound;
            }
            const blob = (owner.blob_urls.get(key) orelse return error.BlobNotFound).blob;
            // blob can be removed by the time we run, dupe it.
            content_type = try arena.dupe(u8, blob._mime);
            body = try arena.dupe(u8, blob._slice);
        }

        const has_content_type = content_type.len > 0;
        transfer.setResponseHead(200, if (has_content_type) content_type else null);
        if (content_type.len > 0) {
            const h = try arena.alloc(http.Header, 1);
            h[0] = .{ .name = "content-type", .value = content_type };
            transfer.res.headers = h;
        }
        transfer._content_length = body.len;
        try transfer.bufferEvents(body);
    }
};

const testing = @import("../testing.zig");

// Only the transfer list, the url and the parent matter to the tests using
// it: they build their transfers by hand and never go through newRequest.
fn testOwner(url: ?*const [:0]const u8, parent: ?*const Owner) Owner {
    return .{
        .blob_urls = undefined,
        .origin = undefined,
        .url = url,
        .parent = parent,
        .frame_id = 0,
        .document_frame_id = 0,
        .loader_id = 0,
        .cookie_jar = undefined,
        .notification = undefined,
        .performance = undefined,
    };
}
const AdBlocker = @import("adblock/AdBlocker.zig");

// The Network every test client points at: only the fields a test actually
// exercises are ever set, by initTestClient or by the test itself.
var test_network: Network = undefined;

// Every row here was read off Chrome on the wire, from a page at
// https://www.127-0-0-1.nip.io:9600 fetching each shape of not-same-origin --
// tools/fingerprint/scratch/b119/fs-chrome-{https,http}.json, the
// `--scenario fetch-site` capture.
test "HttpClient: fetchSite classifies initiator against request URL" {
    try testing.expectEqual(FetchSite.same_origin, fetchSite("https://example.com/a", "https://example.com/b"));
    // A port is not part of a site: another port of one host is same-site.
    try testing.expectEqual(FetchSite.same_site, fetchSite("https://example.com:9600/a", "https://example.com:9602/b"));
    // Neither is a subdomain -- and two SIBLING subdomains are same-site too,
    // which no suffix comparison can see.
    try testing.expectEqual(FetchSite.same_site, fetchSite("https://cdn.example.com/a", "https://example.com/b"));
    try testing.expectEqual(FetchSite.same_site, fetchSite("https://www.example.com/a", "https://cdn.example.com/b"));
    // The scheme is: Chrome's same-site is the schemeful one.
    try testing.expectEqual(FetchSite.cross_site, fetchSite("http://example.com/a", "https://example.com/b"));
    try testing.expectEqual(FetchSite.cross_site, fetchSite("https://example.com/a", "https://other.org/b"));
    // A suffix match without a dot boundary is a different site.
    try testing.expectEqual(FetchSite.cross_site, fetchSite("https://example.com/a", "https://notexample.com/b"));
    // An IP literal has no registrable domain; its site is the address itself.
    // Walking one for an eTLD+1 would leave two unrelated addresses sharing a
    // "0.1", so the two loopback ports below must not drag 10.0.0.1 with them.
    try testing.expectEqual(FetchSite.same_site, fetchSite("http://127.0.0.1:9600/a", "http://127.0.0.1:9601/b"));
    try testing.expectEqual(FetchSite.cross_site, fetchSite("http://127.0.0.1:9600/a", "http://10.0.0.1:9601/b"));
    try testing.expectEqual(FetchSite.cross_site, fetchSite("http://[::1]:9600/a", "http://127.0.0.1:9601/b"));
    // A blob: URL's origin is the origin it was minted from. The live
    // cf-scrapingcourse challenge runs its last two requests out of a
    // `blob:https://challenges.cloudflare.com/<uuid>` document, and Chrome calls
    // the one back at that host `same-origin` (b119, the /pat request in
    // /tmp-captured extraInfo).
    try testing.expectEqual(FetchSite.same_origin, fetchSite("blob:https://challenges.cloudflare.com/6491bd57", "https://challenges.cloudflare.com/x"));
    try testing.expectEqual(FetchSite.same_site, fetchSite("blob:https://challenges.cloudflare.com/6491bd57", "https://brunhild.challenges.cloudflare.com/x"));
    try testing.expectEqual(FetchSite.cross_site, fetchSite("blob:https://challenges.cloudflare.com/6491bd57", "https://example.com/x"));
}

test "HttpClient: sameSiteForStorage compares scheme and registrable domain" {
    try testing.expect(sameSiteForStorage("https://example.com/a", "https://example.com/b"));
    // A port is not part of a site, and neither is a subdomain -- both of which
    // fetchSite's approximation calls cross-site.
    try testing.expect(sameSiteForStorage("http://localhost:9590/top", "http://localhost:9591/sub"));
    try testing.expect(sameSiteForStorage("https://example.com/a", "https://cdn.example.com/b"));
    // The scheme is.
    try testing.expect(!sameSiteForStorage("http://example.com/a", "https://example.com/b"));
    try testing.expect(!sameSiteForStorage("http://localhost:9590/", "http://127.0.0.1:9591/"));
    try testing.expect(!sameSiteForStorage("https://example.com/a", "https://example.org/b"));
    // Nothing is same-site with an opaque origin, including another one.
    try testing.expect(!sameSiteForStorage("about:blank", "about:blank"));
}

// "" when absent, so a test can assert absence as well as a value.
fn seededValue(transfer: *const Transfer, name: []const u8) []const u8 {
    return transfer.findRequestHeader(name) orelse "";
}

test "HttpClient: seedFetchMetadata reports a third-party storage partition" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Never dereferenced: `Sec-Fetch-Storage-Access` asks only whether a jar is
    // attached, which is this engine's spelling of "the request is credentialed".
    var jar: CookieJar = undefined;

    const Case = struct {
        what: []const u8,
        url: [:0]const u8,
        top: []const u8,
        third_party_client: bool,
        credentialed: bool,
        expect: []const u8,
    };

    // Every row measured on Chrome 151, tools/fingerprint/scratch/b117/sa-chrome-p2.json.
    for ([_]Case{
        .{
            .what = "cross-site image from the top-level document",
            .url = "http://127.0.0.1:9591/img",
            .top = "http://localhost:9590/top",
            .third_party_client = false,
            .credentialed = true,
            .expect = "active",
        },
        .{
            // The half `credentials` splits off by itself: same request, no jar.
            .what = "cross-site fetch with credentials omitted",
            .url = "http://127.0.0.1:9591/sub",
            .top = "http://localhost:9590/top",
            .third_party_client = false,
            .credentialed = false,
            .expect = "",
        },
        .{
            // The half the ancestor chain splits off: same-site with the top,
            // yet asked for by a cross-site frame.
            .what = "cross-site frame reaching back at the top-level site",
            .url = "http://localhost:9590/sub",
            .top = "http://localhost:9590/top",
            .third_party_client = true,
            .credentialed = true,
            .expect = "active",
        },
        .{
            .what = "same-origin subresource of the top-level document",
            .url = "http://localhost:9590/sub",
            .top = "http://localhost:9590/top",
            .third_party_client = false,
            .credentialed = true,
            .expect = "",
        },
        .{
            // Another port of the same host is the same site, so a credentialed
            // request there is first-party -- where Sec-Fetch-Site, on its
            // coarser test, says `cross-site`.
            .what = "same-site subresource on another port",
            .url = "http://localhost:9591/sub",
            .top = "http://localhost:9590/top",
            .third_party_client = false,
            .credentialed = true,
            .expect = "",
        },
        .{
            .what = "no partition at all -- an internal request",
            .url = "http://127.0.0.1:9591/sub",
            .top = "",
            .third_party_client = false,
            .credentialed = true,
            .expect = "",
        },
    }) |case| {
        const arena = try pool.acquire(.small, "test");
        defer arena.release();

        var transfer = testTransfer(arena);
        transfer.req.resource_type = .fetch;
        transfer.req.url = case.url;
        transfer.req.cookie_origin = .{ .url = "http://localhost:9590/top" };
        transfer.cookie_jar = if (case.credentialed) &jar else null;
        transfer.req.credentials_mode = if (case.credentialed) .include else .omit;
        transfer.req.partition = if (case.top.len == 0) null else .{
            .top_level_url = case.top,
            .third_party_client = case.third_party_client,
        };
        try transfer.seedFetchMetadata();

        // The description rides along so a red light names the row.
        try testing.expectString(
            case.what,
            if (std.mem.eql(u8, case.expect, seededValue(&transfer, "Sec-Fetch-Storage-Access"))) case.what else "",
        );
    }
}

// What each RequestInit `cache` value puts on the wire, measured on Chrome 151
// across the five values a same-origin GET can carry --
// tools/fingerprint/scratch/b120/blob-chrome.json, the `top-*` rows.
test "HttpClient: cache mode writes the Cache-Control Chrome writes" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const cases = [_]struct { Request.CacheMode, []const u8, []const u8 }{
        .{ .default, "", "" },
        .{ .force_cache, "", "" },
        .{ .only_if_cached, "", "" },
        // `no-cache` revalidates, and says so with a zero freshness lifetime.
        .{ .no_cache, "", "max-age=0" },
        // `reload` and `no-store` both mean "do not use the cache at all", and
        // Chrome spells that with the HTTP/1.0 field alongside.
        .{ .reload, "no-cache", "no-cache" },
        .{ .no_store, "no-cache", "no-cache" },
    };

    for (cases) |case| {
        const arena = try pool.acquire(.small, "test");
        defer arena.release();

        var transfer = testTransfer(arena);
        transfer.req.resource_type = .fetch;
        transfer.req.cache = case.@"0";
        try transfer.seedCacheControl();

        try testing.expectString(case.@"1", seededValue(&transfer, "Pragma"));
        try testing.expectString(case.@"2", seededValue(&transfer, "Cache-Control"));
    }
}

// A dedicated worker's script fetch, measured on the same capture: Chrome calls
// its destination `worker` where this engine called it `script`, and asks for it
// in `same-origin` mode.
// The worker script fetch does not take the subresource shape: Chrome emits it
// from a fixed order with User-Agent behind Referer, not from a renderer map
// block (measured, the `/w/url-worker.js` request of
// tools/fingerprint/scratch/b120/blob-chrome.json).
test "HttpClient: a worker script fetch has its own header order" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);

    // An empty slice rather than `.?` so a missing table reads as a length
    // mismatch on the assertion, not an unwrap panic before it.
    const none: []const []const u8 = &.{};

    transfer.req.resource_type = .worker;
    try testing.expectEqualSlices(
        []const u8,
        &Transfer.chrome_worker_script_order,
        transfer.orderTable() orelse none,
    );

    // The shapes either side of it are untouched: a plain subresource still has
    // no table, and a navigation still has the navigation one.
    transfer.req.resource_type = .fetch;
    try testing.expectEqual(null, transfer.orderTable());
    transfer.req.resource_type = .document;
    try testing.expectEqualSlices(
        []const u8,
        &Transfer.chrome_navigation_order,
        transfer.orderTable() orelse none,
    );
}

test "HttpClient: seedFetchMetadata names a worker script fetch" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.url = "http://example.com/w.js";
    transfer.req.resource_type = .worker;
    transfer.req.cookie_origin = .{ .url = "http://example.com/top" };
    try transfer.seedFetchMetadata();

    try testing.expectString("worker", seededValue(&transfer, "Sec-Fetch-Dest"));
    try testing.expectString("same-origin", seededValue(&transfer, "Sec-Fetch-Mode"));
    try testing.expectString("same-origin", seededValue(&transfer, "Sec-Fetch-Site"));
    try testing.expectString("*/*", seededValue(&transfer, "Accept"));
}

test "HttpClient: seedFetchMetadata sends Chrome's set for a top-level navigation" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.url = "https://example.com/";
    // No initiator document: an address-bar navigation.
    transfer.req.nav = .{ .initiator_origin = null, .subframe = false, .user_activated = true };
    try transfer.seedFetchMetadata();

    try testing.expectString(
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        seededValue(&transfer, "Accept"),
    );
    try testing.expectString("document", seededValue(&transfer, "Sec-Fetch-Dest"));
    try testing.expectString("navigate", seededValue(&transfer, "Sec-Fetch-Mode"));
    try testing.expectString("none", seededValue(&transfer, "Sec-Fetch-Site"));
    try testing.expectString("?1", seededValue(&transfer, "Sec-Fetch-User"));
    try testing.expectString("1", seededValue(&transfer, "Upgrade-Insecure-Requests"));
}

test "HttpClient: seedFetchMetadata labels a subframe navigation" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.url = "https://widget.example.com/frame";
    transfer.req.nav = .{ .initiator_origin = "https://example.com/", .subframe = true, .user_activated = false };
    try transfer.seedFetchMetadata();

    try testing.expectString("iframe", seededValue(&transfer, "Sec-Fetch-Dest"));
    // Same registrable domain, different host: same-site, not same-origin.
    try testing.expectString("same-site", seededValue(&transfer, "Sec-Fetch-Site"));
    // Script-driven, so no user gesture to report.
    try testing.expectString("", seededValue(&transfer, "Sec-Fetch-User"));
}

test "HttpClient: seedFetchMetadata labels a same-origin script" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.resource_type = .script;
    transfer.req.url = "https://example.com/app.js";
    transfer.req.cookie_origin = .{ .url = "https://example.com/" };
    try transfer.seedFetchMetadata();

    try testing.expectString("*/*", seededValue(&transfer, "Accept"));
    try testing.expectString("script", seededValue(&transfer, "Sec-Fetch-Dest"));
    try testing.expectString("no-cors", seededValue(&transfer, "Sec-Fetch-Mode"));
    try testing.expectString("same-origin", seededValue(&transfer, "Sec-Fetch-Site"));
    // Subresources carry neither of the navigation-only headers.
    try testing.expectString("", seededValue(&transfer, "Sec-Fetch-User"));
    try testing.expectString("", seededValue(&transfer, "Upgrade-Insecure-Requests"));
}

test "HttpClient: seedFetchMetadata labels a cross-origin image" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.resource_type = .image;
    transfer.req.url = "https://cdn.example.net/logo.png";
    transfer.req.cookie_origin = .{ .url = "https://example.com/" };
    try transfer.seedFetchMetadata();

    try testing.expectString(
        "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        seededValue(&transfer, "Accept"),
    );
    try testing.expectString("image", seededValue(&transfer, "Sec-Fetch-Dest"));
    // Parser-initiated, so no-cors rather than the cors an XHR would get.
    try testing.expectString("no-cors", seededValue(&transfer, "Sec-Fetch-Mode"));
    try testing.expectString("cross-site", seededValue(&transfer, "Sec-Fetch-Site"));
    try testing.expectString("", seededValue(&transfer, "Sec-Fetch-User"));
    try testing.expectString("", seededValue(&transfer, "Upgrade-Insecure-Requests"));
}

// The wire order emitHeaders produces for a subresource carrying `present`:
// the leading bracket, then the map block the model lays out, then the trailing
// one. `present` is the map-block set in the renderer's insertion order.
// `present` is the map-block names, whose order is derived; the two bracketing
// tables are emitted whole, minus whatever `absent` names this request does not
// carry -- a table entry nothing set simply doesn't match at emission time.
fn subresourceWire(present: []const []const u8, absent: []const []const u8, buf: [][]const u8) []const []const u8 {
    var n: usize = 0;
    // Both tables are orders, not sets: a name nothing set is simply skipped on
    // the wire, which is what `absent` says here.
    before: for (Transfer.chrome_subresource_before_map) |name| {
        for (absent) |skip| {
            if (std.mem.eql(u8, name, skip)) continue :before;
        }
        buf[n] = name;
        n += 1;
    }
    var order: [blink_header_order.max_names]u8 = undefined;
    const count = blink_header_order.bucketOrder(present, &order).?;
    for (order[0..count]) |slot| {
        buf[n] = present[slot];
        n += 1;
    }
    outer: for (Transfer.chrome_subresource_after_map) |name| {
        for (absent) |skip| {
            if (std.mem.eql(u8, name, skip)) continue :outer;
        }
        buf[n] = name;
        n += 1;
    }
    return buf[0..n];
}

test "HttpClient: a POST's three extra headers sit where Chrome puts them" {
    // Two measured POSTs, whole. Chrome does not append the body-and-cors
    // headers after the set it already sends: Content-Length goes third on the
    // wire (Host, Connection, then it), content-type lands inside the hint
    // block, and Origin between Accept and the Sec-Fetch triple.
    //
    // Both were captured long before the map model existed, and neither is a
    // table any more -- the block in the middle of each is derived from the set
    // of names on the request. That they still come out byte for byte is the
    // check that the derivation is Chrome's and not a story that fits one page.
    var buf: [32][]const u8 = undefined;
    // Both captures are same-origin POSTs from a top-level document, so their
    // cookies are first-party and Sec-Fetch-Storage-Access is not on either.
    // Neither POST is in a third-party partition, and neither asked for a cache
    // mode, so three of the ordered names are not on either request.
    const no_storage_access: []const []const u8 = &.{ "Sec-Fetch-Storage-Access", "Pragma", "Cache-Control" };

    // Unhinted, measured: the same-origin `POST /sub/xhr-*` of
    // tools/fingerprint/results/xhr-post-nohints-chrome.json -- the same probe
    // page served with an empty `Accept-CH`, so the origin asks for nothing.
    try testing.expectEqualSlices([]const u8, &.{
        "Content-Length",
        "sec-ch-ua-platform",
        "User-Agent",
        "sec-ch-ua",
        "content-type",
        "sec-ch-ua-mobile",
        "Accept",
        "Origin",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-Dest",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        "Cookie",
        "priority",
    }, subresourceWire(&.{
        "sec-ch-ua",
        "User-Agent",
        "sec-ch-ua-platform",
        "sec-ch-ua-mobile",
        "content-type",
    }, no_storage_access, &buf));

    // Hinted, measured: the same-origin `POST /sub/xhr-*` of
    // tools/fingerprint/results/acceptch-chrome.json. content-type follows
    // User-Agent here rather than sec-ch-ua, and User-Agent itself falls from
    // second to ninth -- six more names in the map, so every bucket moves.
    try testing.expectEqualSlices([]const u8, &.{
        "Content-Length",
        "sec-ch-ua-full-version-list",
        "sec-ch-ua-platform",
        "sec-ch-ua",
        "sec-ch-ua-bitness",
        "sec-ch-ua-model",
        "sec-ch-ua-mobile",
        "sec-ch-ua-arch",
        "sec-ch-ua-full-version",
        "User-Agent",
        "content-type",
        "sec-ch-ua-platform-version",
        "Accept",
        "Origin",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-Dest",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        "Cookie",
        "priority",
    }, subresourceWire(&Transfer.blink_map_insertion, no_storage_access, &buf));
}

test "HttpClient: the body's length is a header of ours, not curl's afterthought" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var config = try Config.init(testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(testing.allocator);
    var network: Network = undefined;
    var client = testHeaderClient(&network, &config);
    defer client.client_hints.deinit(testing.allocator);

    {
        const arena = try pool.acquire(.small, "test");
        defer arena.release();

        var transfer = testTransfer(arena);
        transfer.client = &client;
        transfer.req.resource_type = .xhr;
        transfer.req.method = .POST;
        transfer.req.url = "https://example.com/api";
        transfer.req.cookie_origin = .{ .url = "https://example.com/page" };
        transfer.req.body = "probe";
        try transfer.seedHeaders();

        // Byte length of the body, which is what curl would have written --
        // the point of writing it ourselves is only where it lands.
        try testing.expectString("5", seededValue(&transfer, "Content-Length"));

        // A 301/302/303 turns the request into a GET and drops the body. The
        // length header has to go with it: left behind, it announces five bytes
        // that are never sent.
        transfer.req.method = .GET;
        transfer.req.body = null;
        try transfer.seedContentLength();
        try testing.expectString("", seededValue(&transfer, "Content-Length"));
    }

    {
        const arena = try pool.acquire(.small, "test");
        defer arena.release();

        // No body, no header -- not even a zero. Chrome sends none on a GET.
        var transfer = testTransfer(arena);
        transfer.client = &client;
        transfer.req.resource_type = .xhr;
        transfer.req.url = "https://example.com/api";
        transfer.req.cookie_origin = .{ .url = "https://example.com/page" };
        try transfer.seedHeaders();
        try testing.expectString("", seededValue(&transfer, "Content-Length"));
    }
}

test "HttpClient: an XHR POST carries the Origin header its initiator has" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Fetch's "append a request `Origin` header": a cors-mode request gets one
    // when its response tainting is cors (any cross-origin fetch/XHR) *or* when
    // its method is neither GET nor HEAD -- which is why a same-origin POST
    // carries it and a same-origin GET does not. Measured on the Chrome side in
    // tools/fingerprint/results/acceptch-chrome.json: the same-origin
    // `POST /sub/xhr-*` carries `Origin: http://127.0.0.1:9586` while the
    // same-origin `GET /sub/fetch-*` beside it carries none.
    const cases = [_]struct {
        Request.ResourceType,
        Method,
        [:0]const u8, // request url
        [:0]const u8, // initiator document url
        []const u8, // expected Origin ("" = absent)
    }{
        // The case Cloudflare's challenge is made of: a same-origin POST.
        .{ .xhr, .POST, "https://example.com/api", "https://example.com/page", "https://example.com" },
        .{ .fetch, .POST, "https://example.com/api", "https://example.com/page", "https://example.com" },
        // Not GET nor HEAD is the test, not "is a POST".
        .{ .fetch, .PUT, "https://example.com/api", "https://example.com/page", "https://example.com" },
        // Same-origin GET/HEAD: tainting is basic, so no Origin.
        .{ .fetch, .GET, "https://example.com/api", "https://example.com/page", "" },
        .{ .xhr, .HEAD, "https://example.com/api", "https://example.com/page", "" },
        // Cross-origin, so the response tainting is cors and even a GET carries
        // the header -- that is what the receiving origin's CORS check reads.
        .{ .fetch, .GET, "https://api.other.org/v1", "https://example.com/page", "https://example.com" },
        // The port is part of the serialization; the path never is.
        .{ .xhr, .POST, "http://127.0.0.1:9586/sub/x", "http://127.0.0.1:9586/critical-ch", "http://127.0.0.1:9586" },
        // A no-cors subresource is not a cors request and has a safe method:
        // neither branch applies.
        .{ .script, .GET, "https://cdn.other.org/a.js", "https://example.com/page", "" },
        .{ .image, .GET, "https://cdn.other.org/a.png", "https://example.com/page", "" },
    };

    for (cases) |case| {
        const arena = try pool.acquire(.small, "test");
        defer arena.release();

        var transfer = testTransfer(arena);
        transfer.req.resource_type = case[0];
        transfer.req.method = case[1];
        transfer.req.url = case[2];
        transfer.req.cookie_origin = .{ .url = case[3] };
        try transfer.seedFetchMetadata();

        try testing.expectString(case[4], seededValue(&transfer, "Origin"));
    }
}

test "HttpClient: seedFetchMetadata sends Chrome's priority hint per destination" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Measured against a local http2 echo that keeps the wire header block
    // (tools/fingerprint/h2-arms.mjs): Chrome carries an RFC 9218 hint on every
    // request, u=0 for the render-blocking destinations and u=1 for the rest,
    // incremental everywhere except style and script.
    const cases = [_]struct { Request.ResourceType, []const u8 }{
        .{ .document, "u=0, i" },
        .{ .stylesheet, "u=0" },
        .{ .script, "u=1" },
        .{ .image, "u=1, i" },
        .{ .fetch, "u=1, i" },
        .{ .xhr, "u=1, i" },
        // EventSource was not in the capture; grouped with fetch and XHR, which
        // is how every other per-destination switch here already treats it.
        .{ .eventsource, "u=1, i" },
    };

    for (cases) |case| {
        const arena = try pool.acquire(.small, "test");
        defer arena.release();

        var transfer = testTransfer(arena);
        transfer.req.resource_type = case[0];
        transfer.req.url = "https://example.com/a";
        if (case[0] == .document) {
            transfer.req.nav = .{ .initiator_origin = null, .subframe = false, .user_activated = true };
        } else {
            transfer.req.cookie_origin = .{ .url = "https://example.com/" };
        }
        try transfer.seedFetchMetadata();

        try testing.expectString(case[1], seededValue(&transfer, "priority"));
    }
}

test "HttpClient: a subframe navigation gets the same priority as a top-level one" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.url = "https://widget.example.com/frame";
    transfer.req.nav = .{ .initiator_origin = "https://example.com/", .subframe = true, .user_activated = false };
    try transfer.seedFetchMetadata();

    // Chrome splits Sec-Fetch-Dest into document/iframe but hints both the same.
    try testing.expectString("iframe", seededValue(&transfer, "Sec-Fetch-Dest"));
    try testing.expectString("u=0, i", seededValue(&transfer, "priority"));
}

test "HttpClient: the priority hint goes out last, after Accept-Language" {
    // Position is part of the fingerprint, not just presence, and the wire
    // order comes from these tables rather than from insertion order -- so
    // this asserts the tables, which is the thing emitHeaders actually reads.
    const nav = Transfer.chrome_navigation_order;
    const sub = Transfer.chrome_subresource_after_map;
    try testing.expectString("priority", nav[nav.len - 1]);
    try testing.expectString("Cookie", nav[nav.len - 2]);
    try testing.expectString("Accept-Language", nav[nav.len - 3]);
    try testing.expectString("priority", sub[sub.len - 1]);
    try testing.expectString("Cookie", sub[sub.len - 2]);
    try testing.expectString("Accept-Language", sub[sub.len - 3]);
}

test "HttpClient: Cookie goes out second to last, between Accept-Language and priority" {
    // Measured over h2 against a headless Chrome 151 on all four shapes --
    // navigation, subresource, XHR POST and fetch POST: `cookie` is the last
    // real field, with only `priority` behind it. Every other name matched
    // already, so this one position was the whole difference, and it shows on
    // every cookie-bearing request rather than on some corner.
    //
    // It went unnoticed because the header comparison ran against a page set
    // that never set a cookie, and because the field was not ours to place: it
    // came out of curl's own CURLOPT_COOKIE slot, right behind the pseudo
    // headers. Same story as Content-Length, same fix -- a header we own is a
    // header emitHeaders can place.
    inline for (.{
        Transfer.chrome_navigation_order,
        Transfer.chrome_subresource_after_map,
        Transfer.chrome_restarted_navigation_order,
    }) |table| {
        try testing.expectString("priority", table[table.len - 1]);
        try testing.expectString("Cookie", table[table.len - 2]);
    }
}

test "HttpClient: the negotiated hints sit where Chrome puts them" {
    // Both sequences are read straight off
    // tools/fingerprint/results/acceptch-chrome.json, where a headless Chrome
    // 151 met an origin asking for all nine. Position is fingerprint, and it is
    // not insertion order, so the tables are the thing worth pinning.
    try testing.expectEqualSlices([]const u8, &.{
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-full-version",
        "sec-ch-ua-arch",
        "sec-ch-ua-platform",
        "sec-ch-ua-platform-version",
        "sec-ch-ua-model",
        "sec-ch-ua-bitness",
        "sec-ch-ua-full-version-list",
        "Upgrade-Insecure-Requests",
        "User-Agent",
    }, Transfer.chrome_navigation_order[0..11]);

    // A navigation's order is the one thing the map model does not describe: a
    // top-level navigation is assembled browser side in an ordered vector, and
    // the sequence above is simply the order the hints are declared in. Feed the
    // same names to the map and nothing lines up -- which is why this stays a
    // table while the subresource ones stopped being tables.
    var order: [blink_header_order.max_names]u8 = undefined;
    const count = blink_header_order.bucketOrder(Transfer.chrome_navigation_order[0..11], &order).?;
    try testing.expect(!std.mem.eql(u8, "sec-ch-ua", Transfer.chrome_navigation_order[order[0]]));
    try testing.expectEqual(11, count);

    // Nothing about a subresource's hint block is a table any more; the two
    // measured captures it has to reproduce are asserted whole by "a POST's
    // three extra headers sit where Chrome puts them".

    // And a navigation re-sent for a Critical-CH is a third shape again: the
    // hints follow Accept instead of leading.
    try testing.expectEqualSlices([]const u8, &.{
        "Upgrade-Insecure-Requests",
        "User-Agent",
        "Accept",
        "sec-ch-ua",
    }, Transfer.chrome_restarted_navigation_order[0..4]);
}

test "HttpClient: the three client hints go on the wire lowercase" {
    // Over HTTP/1.1 Chromium spells exactly the three client hints in
    // lowercase and Title-Cases every other field name -- measured, the
    // `steps.localHeaders` step of
    // tools/fingerprint/results/px-hdr-chrome-ua.json, where the same GET /
    // carries `sec-ch-ua`, `sec-ch-ua-mobile` and `sec-ch-ua-platform` beside
    // `Connection`, `User-Agent`, `Accept-Encoding` and `Accept-Language`.
    // Only h1 can see this: HPACK lowercases every name on its way into h2, so
    // the h2 echo is blind to it and the casing there is not ours to pick.
    var config = try Config.init(testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(testing.allocator);

    // baselineHeaders reads the config's resolved header values and the CDP
    // override fields, nothing else -- no curl handle, no event loop -- so a
    // stub with those set is the whole dependency.
    var network: Network = undefined;
    network.config = &config;
    var client: Client = undefined;
    client.network = &network;
    client.user_agent_override = null;
    client.accept_language_override = null;
    client.platform_quoted_override = null;

    const expected = [_][]const u8{
        "Connection",
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-platform",
        "User-Agent",
        "Accept-Encoding",
        "Accept-Language",
    };
    for (client.baselineHeaders(), expected) |hdr, name| {
        try testing.expectString(name, hdr.name);
    }
}

// A Client with just enough set for the header-seeding paths: they read the
// config's resolved header values, the CDP override fields and the hint store,
// and touch no curl handle and no event loop.
fn testHeaderClient(network: *Network, config: *Config) Client {
    network.config = config;
    var client: Client = undefined;
    client.network = network;
    client.allocator = testing.allocator;
    client.user_agent_override = null;
    client.accept_language_override = null;
    client.platform_quoted_override = null;
    client.client_hints = .{};
    return client;
}

test "HttpClient: only an origin that asked gets the six high-entropy hints" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var config = try Config.init(testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(testing.allocator);
    var network: Network = undefined;
    var client = testHeaderClient(&network, &config);
    defer client.client_hints.deinit(testing.allocator);

    // Before the origin asks, it gets the low-entropy three and nothing more.
    var quiet = testTransfer(arena);
    quiet.client = &client;
    quiet.req.url = "https://www.scrapingcourse.com/cloudflare-challenge";
    try quiet.seedHeaders();
    for (comptime std.enums.values(ClientHints.Hint)) |hint| {
        try testing.expectEqual(null, quiet.findRequestHeader(hint.header()));
    }
    try testing.expectString(
        "\"Google Chrome\";v=\"153\", \"Not_A Brand\";v=\"8\", \"Chromium\";v=\"153\"",
        seededValue(&quiet, "sec-ch-ua"),
    );

    try client.client_hints.negotiate(
        testing.allocator,
        "https://www.scrapingcourse.com/cloudflare-challenge",
        "Sec-CH-UA-Bitness, Sec-CH-UA-Arch, Sec-CH-UA-Full-Version, Sec-CH-UA-Mobile, " ++
            "Sec-CH-UA-Model, Sec-CH-UA-Platform-Version, Sec-CH-UA-Full-Version-List, " ++
            "Sec-CH-UA-Platform, Sec-CH-UA",
    );

    var loud = testTransfer(arena);
    loud.client = &client;
    loud.req.url = "https://www.scrapingcourse.com/cloudflare-challenge";
    try loud.seedHeaders();

    // The values are the ones navigator.userAgentData.getHighEntropyValues
    // answers, quoted as the header spells them: a page that reads both must
    // not find two different machines.
    try testing.expectString("\"arm\"", seededValue(&loud, "sec-ch-ua-arch"));
    try testing.expectString("\"64\"", seededValue(&loud, "sec-ch-ua-bitness"));
    try testing.expectString("\"\"", seededValue(&loud, "sec-ch-ua-model"));
    try testing.expectString("\"26.6.2\"", seededValue(&loud, "sec-ch-ua-platform-version"));
    try testing.expectString("\"153.0.8010.48\"", seededValue(&loud, "sec-ch-ua-full-version"));
    try testing.expectString(
        "\"Google Chrome\";v=\"153.0.8010.48\", \"Not_A Brand\";v=\"8.0.0.0\", \"Chromium\";v=\"153.0.8010.48\"",
        seededValue(&loud, "sec-ch-ua-full-version-list"),
    );

    // A different origin is still a stranger, even mid-page.
    var other = testTransfer(arena);
    other.client = &client;
    other.req.url = "https://www.google-analytics.com/g/collect";
    other.req.resource_type = .fetch;
    try other.seedHeaders();
    for (comptime std.enums.values(ClientHints.Hint)) |hint| {
        try testing.expectEqual(null, other.findRequestHeader(hint.header()));
    }
}

test "HttpClient: a page cannot forge a high-entropy hint" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var config = try Config.init(testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(testing.allocator);
    var network: Network = undefined;
    var client = testHeaderClient(&network, &config);
    defer client.client_hints.deinit(testing.allocator);

    try client.client_hints.negotiate(testing.allocator, "https://example.com/", "Sec-CH-UA-Arch");

    var transfer = testTransfer(arena);
    transfer.client = &client;
    transfer.req.url = "https://example.com/";
    try transfer.seedHeaders();

    // Sec-* is a forbidden header name, so these enter at .cdp like the three
    // baseline hints: script cannot rewrite one, a driver still can.
    try transfer.setHeader("sec-ch-ua-arch", "\"x86\"", .{ .source = .author });
    try testing.expectString("\"arm\"", seededValue(&transfer, "sec-ch-ua-arch"));
    try transfer.setHeader("sec-ch-ua-arch", "\"x86\"", .{ .source = .cdp });
    try testing.expectString("\"x86\"", seededValue(&transfer, "sec-ch-ua-arch"));
}

test "HttpClient: Critical-CH asks for the navigation to be restarted, once" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var config = try Config.init(testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(testing.allocator);
    var network: Network = undefined;
    var client = testHeaderClient(&network, &config);
    defer client.client_hints.deinit(testing.allocator);

    const critical = "Sec-CH-UA-Arch, Sec-CH-UA-Bitness, Sec-CH-UA-Platform";
    var transfer = testTransfer(arena);
    transfer.client = &client;
    transfer.req.url = "https://example.com/";
    try transfer.seedHeaders();
    transfer.res.headers = &.{
        .{ .name = "accept-ch", .value = critical },
        .{ .name = "critical-ch", .value = critical },
    };

    // The response arrived without two hints it declares itself to depend on,
    // so it is not the response this client should be reading.
    try transfer.negotiateClientHints();
    try testing.expect(transfer.shouldRestartForCriticalHints());

    // Once restarted the request carries them, so the second response's
    // identical Critical-CH asks for nothing new -- which is what keeps a
    // stubborn origin from looping the navigation forever.
    try transfer.seedClientHints();
    try testing.expectEqual(false, transfer.shouldRestartForCriticalHints());
}

test "HttpClient: Critical-CH restarts nothing it shouldn't" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var config = try Config.init(testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(testing.allocator);
    var network: Network = undefined;
    var client = testHeaderClient(&network, &config);
    defer client.client_hints.deinit(testing.allocator);

    // A Critical-CH naming only hints that already went out.
    var sent = testTransfer(arena);
    sent.client = &client;
    sent.req.url = "https://example.com/";
    try sent.seedHeaders();
    sent.res.headers = &.{
        .{ .name = "accept-ch", .value = "Sec-CH-UA, Sec-CH-UA-Mobile, Sec-CH-UA-Platform" },
        .{ .name = "critical-ch", .value = "Sec-CH-UA, Sec-CH-UA-Mobile, Sec-CH-UA-Platform" },
    };
    try sent.negotiateClientHints();
    try testing.expectEqual(false, sent.shouldRestartForCriticalHints());

    // Critical-CH without an Accept-CH beside it: nothing was accepted, so
    // there is nothing to attach and a restart would fetch the same request.
    var lonely = testTransfer(arena);
    lonely.client = &client;
    lonely.req.url = "https://lonely.example.com/";
    try lonely.seedHeaders();
    lonely.res.headers = &.{
        .{ .name = "critical-ch", .value = "Sec-CH-UA-Arch" },
    };
    try lonely.negotiateClientHints();
    try testing.expectEqual(false, lonely.shouldRestartForCriticalHints());

    // A subresource is never restarted, however loudly it asks.
    var sub = testTransfer(arena);
    sub.client = &client;
    sub.req.url = "https://example.com/logo.png";
    sub.req.resource_type = .image;
    try sub.seedHeaders();
    sub.res.headers = &.{
        .{ .name = "accept-ch", .value = "Sec-CH-UA-Arch" },
        .{ .name = "critical-ch", .value = "Sec-CH-UA-Arch" },
    };
    try sub.negotiateClientHints();
    try testing.expectEqual(false, sub.shouldRestartForCriticalHints());

    // And a navigation that already spent its one restart stops asking, even
    // though the hints it needs are still missing.
    var spent = testTransfer(arena);
    spent.client = &client;
    spent.req.url = "https://spent.example.com/";
    try spent.seedHeaders();
    spent.res.headers = &.{
        .{ .name = "accept-ch", .value = "Sec-CH-UA-Arch" },
        .{ .name = "critical-ch", .value = "Sec-CH-UA-Arch" },
    };
    try spent.negotiateClientHints();
    try testing.expect(spent.shouldRestartForCriticalHints());
    spent._critical_hints_restarted = true;
    try testing.expectEqual(false, spent.shouldRestartForCriticalHints());
}

test "HttpClient: a navigation's Accept-CH is remembered, a subresource's is not" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    // negotiateClientHints reads the response headers, the request's url and
    // resource_type, and the client's hint store -- no conn, no curl.
    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.client_hints = .{};
    defer client.client_hints.deinit(testing.allocator);

    var transfer = testTransfer(arena);
    transfer.client = &client;
    transfer.req.url = "https://www.scrapingcourse.com/cloudflare-challenge";
    transfer.res.headers = &.{
        .{ .name = "cf-mitigated", .value = "challenge" },
        .{ .name = "accept-ch", .value = "Sec-CH-UA-Bitness, Sec-CH-UA-Arch, Sec-CH-UA-Platform" },
    };

    try transfer.negotiateClientHints();
    const negotiated = client.client_hints.acceptedFor("https://www.scrapingcourse.com/anything");
    try testing.expectEqual(2, negotiated.count());
    try testing.expect(negotiated.contains(.bitness));
    try testing.expect(negotiated.contains(.arch));

    // The same header on a subresource response is ignored: Chrome persists
    // hints from a navigation and from nowhere else, so an origin whose only
    // ask rides on an image reaches us and Chrome alike as no ask at all.
    var sub = testTransfer(arena);
    sub.client = &client;
    sub.req.url = "https://cdn.example.com/logo.png";
    sub.req.resource_type = .image;
    sub.res.headers = &.{
        .{ .name = "accept-ch", .value = "Sec-CH-UA-Model" },
    };

    try sub.negotiateClientHints();
    try testing.expectEqual(0, client.client_hints.acceptedFor("https://cdn.example.com/x").count());
}

test "HttpClient: a subframe's Accept-CH is not remembered" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.client_hints = .{};
    defer client.client_hints.deinit(testing.allocator);

    // Cloudflare's Turnstile widget is a cross-site iframe and answers its own
    // document with `Accept-CH` + `Critical-CH` naming all nine hints. Chrome
    // gives that ask nothing: measured on a local two-origin rig
    // (`accept-ch-echo.mjs --scenario frame`), a bare headless Chrome sent the
    // frame origin zero of the six high-entropy hints and did not restart the
    // frame navigation for the Critical-CH either -- and it still sent zero
    // when the very same origin had been visited top-level moments before, with
    // and without the top document delegating `ch-ua-*` by Permissions-Policy.
    //
    // So the ask is worth nothing from a subframe, and an engine that honours it
    // announces itself on every request the widget then makes.
    var frame = testTransfer(arena);
    frame.client = &client;
    frame.req.url = "https://challenges.cloudflare.com/frame";
    frame.req.nav = .{
        .initiator_origin = "https://www.scrapingcourse.com/",
        .subframe = true,
        .user_activated = false,
    };
    frame.res.headers = &.{
        .{ .name = "accept-ch", .value = "Sec-CH-UA-Arch, Sec-CH-UA-Bitness" },
        .{ .name = "critical-ch", .value = "Sec-CH-UA-Arch, Sec-CH-UA-Bitness" },
    };

    try frame.negotiateClientHints();
    try testing.expectEqual(0, client.client_hints.acceptedFor("https://challenges.cloudflare.com/x").count());
    // And with nothing accepted there is nothing to restart for, which is the
    // second half of what Chrome was measured doing.
    try testing.expectEqual(false, frame.shouldRestartForCriticalHints());

    // The top-level navigation of the same origin is still remembered: the gate
    // is which frame did the asking, not which origin.
    var top = testTransfer(arena);
    top.client = &client;
    top.req.url = "https://challenges.cloudflare.com/frame";
    top.req.nav = .{ .initiator_origin = null, .subframe = false, .user_activated = true };
    top.res.headers = &.{
        .{ .name = "accept-ch", .value = "Sec-CH-UA-Arch, Sec-CH-UA-Bitness" },
    };

    try top.negotiateClientHints();
    try testing.expectEqual(2, client.client_hints.acceptedFor("https://challenges.cloudflare.com/x").count());
}

test "HttpClient: ResourceType.image reports Chrome's CDP name" {
    try testing.expectString("Image", Request.ResourceType.image.string());
}

test "HttpClient: seedFetchMetadata does not clobber an author's Accept" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.resource_type = .fetch;
    transfer.req.url = "https://api.other.org/v1";
    transfer.req.cookie_origin = .{ .url = "https://example.com/" };
    try transfer.setHeader("Accept", "application/json", .{ .source = .author });
    try transfer.seedFetchMetadata();

    // fetch() may legitimately set Accept, so ours must not win.
    try testing.expectString("application/json", seededValue(&transfer, "Accept"));
    try testing.expectString("empty", seededValue(&transfer, "Sec-Fetch-Dest"));
    try testing.expectString("cors", seededValue(&transfer, "Sec-Fetch-Mode"));
    try testing.expectString("cross-site", seededValue(&transfer, "Sec-Fetch-Site"));
}

test "HttpClient: an author cannot forge a Sec-Fetch header" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);
    transfer.req.resource_type = .fetch;
    transfer.req.url = "https://api.other.org/v1";
    transfer.req.cookie_origin = .{ .url = "https://example.com/" };
    try transfer.seedFetchMetadata();
    try testing.expectString("cross-site", seededValue(&transfer, "Sec-Fetch-Site"));

    // A Sec-* name is a forbidden header name; the author's value is refused
    // and the engine's own reading stands.
    testing.silenceLog(&.{.http});
    try transfer.setHeader("Sec-Fetch-Site", "same-origin", .{ .source = .author });
    try testing.expectString("cross-site", seededValue(&transfer, "Sec-Fetch-Site"));
}

test "HttpClient: isFetchInterceptionMethod matches the four Fetch methods" {
    try testing.expect(isFetchInterceptionMethod("Fetch.continueRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.failRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.fulfillRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.continueWithAuth"));
}

test "HttpClient: isFetchInterceptionMethod rejects unrelated methods" {
    try testing.expect(!isFetchInterceptionMethod(""));
    try testing.expect(!isFetchInterceptionMethod("Fetch.enable"));
    try testing.expect(!isFetchInterceptionMethod("Fetch.disable"));
    try testing.expect(!isFetchInterceptionMethod("Page.navigate"));
    try testing.expect(!isFetchInterceptionMethod("Runtime.evaluate"));
    // strict-equality check: a prefix of a valid name must not match
    try testing.expect(!isFetchInterceptionMethod("Fetch.continueReq"));
    // trailing space, etc.
    try testing.expect(!isFetchInterceptionMethod("Fetch.continueRequest "));
}

test "HttpClient: allowDuringSyncWait allows ping/close/disconnect" {
    const test_arena = try testing.test_app.arena_pool.acquire(.tiny, "HttpClient test");
    defer test_arena.release();

    var ping_msg = Inbox.Message{
        .arena = test_arena,
        .payload = .{ .ping = "" },
    };
    try testing.expect(allowDuringSyncWait(&ping_msg));

    var close_msg = Inbox.Message{
        .arena = test_arena,
        .payload = .close,
    };
    try testing.expect(allowDuringSyncWait(&close_msg));

    var disconnect_msg = Inbox.Message{
        .arena = test_arena,
        .payload = .{ .disconnect = null },
    };
    try testing.expect(allowDuringSyncWait(&disconnect_msg));

    var disconnect_err_msg = Inbox.Message{
        .arena = test_arena,
        .payload = .{ .disconnect = error.PeerClosed },
    };
    try testing.expect(allowDuringSyncWait(&disconnect_err_msg));
}

test "HttpClient: allowDuringSyncWait allows only Fetch interception CDP methods" {
    const test_arena = try testing.test_app.arena_pool.acquire(.tiny, "HttpClient test");
    defer test_arena.release();

    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Fetch.continueRequest",
        "Fetch.failRequest",
        "Fetch.fulfillRequest",
        "Fetch.continueWithAuth",
    }) |method| {
        var msg = Inbox.Message{
            .arena = test_arena,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(allowDuringSyncWait(&msg));
    }
}

test "HttpClient: allowDuringSyncWait denies non-Fetch CDP methods" {
    const test_arena = try testing.test_app.arena_pool.acquire(.tiny, "HttpClient test");
    defer test_arena.release();

    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Page.navigate",
        "Runtime.evaluate",
        "Target.createTarget",
        "Fetch.enable",
        "Fetch.disable",
        "",
    }) |method| {
        var msg = Inbox.Message{
            .arena = test_arena,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(!allowDuringSyncWait(&msg));
    }
}

test "HttpClient: isSyncWaitInterrupt matches teardown methods, close and disconnect" {
    const test_arena = try testing.test_app.arena_pool.acquire(.tiny, "HttpClient test");
    defer test_arena.release();

    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Target.closeTarget",
        "Target.disposeBrowserContext",
        "Page.close",
    }) |method| {
        var msg = Inbox.Message{
            .arena = test_arena,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(isSyncWaitInterrupt(&msg));
    }

    var close_msg = Inbox.Message{ .arena = test_arena, .payload = .close };
    try testing.expect(isSyncWaitInterrupt(&close_msg));

    var disconnect_msg = Inbox.Message{ .arena = test_arena, .payload = .{ .disconnect = null } };
    try testing.expect(isSyncWaitInterrupt(&disconnect_msg));
}

test "HttpClient: isSyncWaitInterrupt ignores ping and non-teardown CDP methods" {
    const test_arena = try testing.test_app.arena_pool.acquire(.tiny, "HttpClient test");
    defer test_arena.release();

    var ping_msg = Inbox.Message{ .arena = test_arena, .payload = .{ .ping = "" } };
    try testing.expect(!isSyncWaitInterrupt(&ping_msg));

    var raw_buf: [16]u8 = undefined;
    inline for ([_][]const u8{
        "Page.navigate",
        "Runtime.evaluate",
        "Target.createTarget",
        "Fetch.continueRequest",
        "",
    }) |method| {
        var msg = Inbox.Message{
            .arena = test_arena,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(!isSyncWaitInterrupt(&msg));
    }
}

fn initTestClient(client: *Client, pool: *ArenaPool) void {
    client.* = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = pool;
    client.transfers = .empty;
    client.blocking_requests = .empty;
    client.pending_queue = .{};
    client.delayed_queue = .{};
    client.delayed_count = 0;
    client.dispatch_queue = .{};
    client.gated_queue = .{};
    client.ws_dispatch_queue = .{};
    client.ws_dispatch_count = 0;
    client.graveyard = .{};
    client.dispatch_count = 0;
    client.intercepted = 0;
    client.http_active = 0;
    client.ws_active = 0;
    client.cache = &Cache.noop;
    client.serve_mode = false;
    client.obey_robots = false;
    client.http_version = .auto;
    client.robots = .{
        .network = undefined,
        .single_flight = .init(testing.allocator),
    };
    client.url_blocklist = null;
    client.accept_language_override = null;
    client.test_fail_submit = null;
    // isUrlBlocked reaches through here for the adblocker; tests that want
    // one assign it to `client.network` after this returns.
    test_network.adblocker = null;
    client.network = &test_network;
}

test "HttpClient: setBlockedUrls owns, replaces, and clears patterns" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    defer client.clearUrlBlocklist();

    var first = [_]u8{ '*', 'f', 'i', 'r', 's', 't', '*' };
    try client.setBlockedUrls(&.{&first});
    @memset(&first, 'x');

    try testing.expect(client.url_blocklist.?.isBlocked("https://example.test/first.js"));
    try client.setBlockedUrls(&.{"*second*"});
    try testing.expect(!client.url_blocklist.?.isBlocked("https://example.test/first.js"));
    try testing.expect(client.url_blocklist.?.isBlocked("https://example.test/second.js"));

    try client.setBlockedUrls(&.{});
    try testing.expectEqual(null, client.url_blocklist);
}

test "HttpClient: setAcceptLanguageOverride owns, replaces, and clears" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    defer client.clearAcceptLanguageOverride();

    var first = "de-DE,de;q=0.9".*;
    try client.setAcceptLanguageOverride(&first);
    @memset(&first, 'x');
    try std.testing.expectEqualStrings("de-DE,de;q=0.9", client.getAcceptLanguage());
    try testing.expectEqual(2, client.getLanguages().len);

    try client.setAcceptLanguageOverride("fr-FR");
    try std.testing.expectEqualStrings("fr-FR", client.getLanguages()[0]);

    client.clearAcceptLanguageOverride();
    try testing.expectEqual(null, client.accept_language_override);
}

const TestRequest = struct {
    url: [:0]const u8,
    document: [:0]const u8 = "",
    /// The page embedding `document`, when the test wants a deeper chain.
    parent_document: [:0]const u8 = "",
    resource_type: Request.ResourceType = .document,
    internal: bool = false,
};

fn testIsUrlBlocked(client: *const Client, opts: TestRequest) bool {
    // The owner chain a real request carries: [0] the embedding page,
    // [1] the request's document, [2] the frame being navigated — whose url
    // slot already holds the target, so its context is its parent's.
    var chain: [3]Owner = undefined;
    chain[0] = testOwner(
        if (opts.parent_document.len == 0) null else &opts.parent_document,
        null,
    );
    chain[1] = testOwner(
        if (opts.document.len == 0) null else &opts.document,
        if (opts.parent_document.len == 0) null else &chain[0],
    );
    chain[2] = testOwner(&opts.url, if (opts.document.len == 0) null else &chain[1]);

    var transfer: Transfer = .{
        .arena = undefined,
        .owner = if (opts.resource_type == .document)
            &chain[2]
        else if (opts.document.len == 0)
            null
        else
            &chain[1],
        .req = .{
            .method = .GET,
            .url = opts.url,
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = opts.resource_type,
            .internal = opts.internal,
            .shutdown_callback = noopShutdown,
        },
        .client = undefined,
        .start_time = 0,
    };
    return client.isUrlBlocked(&transfer);
}

test "HttpClient: adblock verdicts apply per request" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);

    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();
    var list: std.Io.Reader = .fixed(
        \\||ads.example.com^
        \\@@||good.ads.example.com^
        \\||typed.example.com^$script
        \\||partied.example.com^$third-party
        \\||framed.example.com^$subdocument
        \\/\/[a-z]{4}\.js$/$match-case,script
    );
    try blocker.parse(&list);
    try blocker.build();
    client.network.adblocker = blocker;
    defer client.network.adblocker = null;

    // A regex filter reads the URL as requested: case kept, fragment gone.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://cdn.example.com/abcd.js",
        .resource_type = .script,
    }));
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://cdn.example.com/abcd.js#v2",
        .resource_type = .script,
    }));
    try testing.expect(!testIsUrlBlocked(&client, .{
        .url = "https://cdn.example.com/ABCD.js",
        .resource_type = .script,
    }));

    try testing.expect(testIsUrlBlocked(&client, .{ .url = "https://ads.example.com/pixel.gif" }));
    // Hostnames are matched case-insensitively and without the port.
    try testing.expect(testIsUrlBlocked(&client, .{ .url = "https://SUB.ADS.EXAMPLE.COM:8443/x" }));
    try testing.expect(!testIsUrlBlocked(&client, .{ .url = "https://good.ads.example.com/app.js" }));
    try testing.expect(!testIsUrlBlocked(&client, .{ .url = "https://example.com/" }));
    // Internal transfers (robots.txt, ...) are never adblocked.
    try testing.expect(!testIsUrlBlocked(&client, .{ .url = "https://ads.example.com/", .internal = true }));

    // The request's own type decides, not just its hostname.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://typed.example.com/a.js",
        .resource_type = .script,
    }));
    try testing.expect(!testIsUrlBlocked(&client, .{
        .url = "https://typed.example.com/a.json",
        .resource_type = .xhr,
    }));

    // A `.document` request is $subdocument only inside a nested frame,
    // which its owner chain tells: the navigated frame has a parent.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://framed.example.com/",
        .document = "https://news.com/",
    }));
    try testing.expect(!testIsUrlBlocked(&client, .{ .url = "https://framed.example.com/" }));

    // The document URL decides the party; without one the request is first
    // party to itself.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://partied.example.com/x.js",
        .document = "https://news.com/",
        .resource_type = .script,
    }));
    try testing.expect(!testIsUrlBlocked(&client, .{
        .url = "https://partied.example.com/x.js",
        .document = "https://www.partied.example.com/",
        .resource_type = .script,
    }));

    // A top-level navigation is its own context: the page it was clicked on
    // is not in its owner chain (it only travels as cookie_origin, which the
    // adblocker never reads), so nothing makes it third-party...
    try testing.expect(!testIsUrlBlocked(&client, .{ .url = "https://partied.example.com/" }));
    // ...but a subframe loading the same URL keeps its document's context.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://partied.example.com/",
        .document = "https://news.com/",
    }));

    // The context is the issuing frame's document even under a cross-site
    // ancestor (the canonical ad iframe) — site-for-cookies semantics would
    // collapse this chain to nothing and lose the party.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://partied.example.com/x.js",
        .document = "https://adprovider.com/frame.html",
        .parent_document = "https://news.com/",
        .resource_type = .script,
    }));

    // A document hostname DNS could not carry is nothing a filter list has
    // an opinion about: the request is let through, not matched sourceless.
    try testing.expect(testIsUrlBlocked(&client, .{
        .url = "https://ads.example.com/pixel.gif",
        .document = "https://news.com/",
        .resource_type = .image,
    }));
    try testing.expect(!testIsUrlBlocked(&client, .{
        .url = "https://ads.example.com/pixel.gif",
        .document = "https://" ++ "a" ** 254 ++ ".com/",
        .resource_type = .image,
    }));
    // Same for a URL too long to normalize (uppercase forces the copy).
    try testing.expect(!testIsUrlBlocked(&client, .{
        .url = "https://ads.example.com/" ++ "A" ** (8 * 1024),
        .document = "https://news.com/",
        .resource_type = .image,
    }));
}

test "HttpClient: URL blocking exempts internal transfers" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    defer client.clearUrlBlocklist();

    try client.setBlockedUrls(&.{"*example.test*"});
    try testing.expect(testIsUrlBlocked(&client, .{ .url = "https://example.test/script.js" }));
    try testing.expect(!testIsUrlBlocked(&client, .{
        .url = "https://example.test/robots.txt",
        .internal = true,
    }));
}

fn testTransfer(arena: *lp.Arena) Transfer {
    return .{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "http://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .document,
            .shutdown_callback = noopShutdown,
        },
        .client = undefined,
        .id = 1,
        .start_time = 0,
    };
}

test "HttpClient: Transfer.setHeader replaces by case-insensitive name" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);

    try transfer.setHeader("User-Agent", "Lightpanda/1.0", .{});
    try transfer.setHeader("X-Twice", "a", .{});

    // force a duplicated value manually
    try transfer.req_headers.append(transfer.arena.allocator(), .{
        .name = "x-twice",
        .value = "b",
        .source = .user_agent,
    });

    // replaces in place, collapsing duplicates
    try transfer.setHeader("user-agent", "Custom/1.0", .{});
    try transfer.setHeader("X-TWICE", "c", .{ .source = .author });
    // no match: appends
    try transfer.setHeader("X-New", "yes", .{});

    const headers = transfer.req_headers.items;
    try testing.expectEqual(3, headers.len);
    try testing.expectEqual("User-Agent", headers[0].name);
    try testing.expectEqual("Custom/1.0", headers[0].value);
    try testing.expectEqual("X-Twice", headers[1].name);
    try testing.expectEqual("c", headers[1].value);
    try testing.expectEqual(.author, headers[1].source);
    try testing.expectEqual("X-New", headers[2].name);
    try testing.expectEqual("yes", headers[2].value);
}

test "HttpClient: Transfer.appendHeader combines same-source values" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);

    // no match: appends a new header
    try transfer.appendHeader("Accept-Language", "en-US", .{});
    // a higher layer replaces rather than joins
    try transfer.appendHeader("ACCEPT-LANGUAGE", "fr", .{ .source = .author });
    // a same-source repeat joins onto the existing value
    try transfer.appendHeader("accept-language", "de", .{ .source = .author });

    // Cookie joins with its own separator
    try transfer.appendHeader("Cookie", "a=1", .{ .source = .author });
    try transfer.appendHeader("COOKIE", "b=2", .{ .source = .author });

    const headers = transfer.req_headers.items;
    try testing.expectEqual(2, headers.len);
    try testing.expectEqual("Accept-Language", headers[0].name);
    try testing.expectEqual("fr, de", headers[0].value);
    try testing.expectEqual(.author, headers[0].source);
    try testing.expectEqual("Cookie", headers[1].name);
    try testing.expectEqual("a=1; b=2", headers[1].value);
}

test "HttpClient: Transfer header layering" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = testTransfer(arena);

    try transfer.setHeader("User-Agent", "Lightpanda/1.0", .{});
    try transfer.setHeader("Sec-Ch-Ua", "\"Lightpanda\";v=\"1\"", .{ .source = .cdp });
    try transfer.setHeader("If-None-Match", "\"author-etag\"", .{ .source = .author });

    // a lower layer never takes back a header a higher one owns
    try transfer.setHeader("If-None-Match", "\"cache-etag\"", .{});
    try testing.expectEqual("\"author-etag\"", transfer.findRequestHeader("if-none-match").?);

    // A client hint sits at the .cdp rank in this fork rather than .fixed: an
    // author cannot forge one (a Sec-* name is a forbidden header name), but a
    // driver's own override still lands.
    try transfer.appendHeader("SEC-CH-UA", "\"Chromium\";v=\"140\"", .{ .source = .author });
    try testing.expectEqual("\"Lightpanda\";v=\"1\"", transfer.findRequestHeader("sec-ch-ua").?);
    try transfer.setHeader("sec-ch-ua", "\"Chromium\";v=\"140\"", .{ .source = .cdp });
    try testing.expectEqual("\"Chromium\";v=\"140\"", transfer.findRequestHeader("sec-ch-ua").?);

    // A User-Agent still has to be printable, but "Mozilla" is not reserved
    // here the way it is upstream -- every real browser's UA starts with it.
    testing.expectLog(&.{.http});
    try transfer.setHeader("user-agent", "bad\x01ua", .{ .source = .author });
    try testing.expectEqual("Lightpanda/1.0", transfer.findRequestHeader("user-agent").?);
    try transfer.setHeader("user-agent", "Mozilla/5.0 (X11; Linux x86_64)", .{ .source = .author });
    try testing.expectEqual("Mozilla/5.0 (X11; Linux x86_64)", transfer.findRequestHeader("user-agent").?);

    // a valid author User-Agent replaces the default
    try transfer.setHeader("User-Agent", "MyBot/2.0", .{ .source = .author });
    try testing.expectEqual("MyBot/2.0", transfer.findRequestHeader("user-agent").?);
}

test "HttpClient: Fetch header overrides restore after one hop" {
    const original = [_]Transfer.RequestHeader{
        .{ .name = "User-Agent", .value = "original" },
        .{ .name = "X-Original", .value = "yes" },
    };
    var overridden = [_]Transfer.RequestHeader{
        .{ .name = "User-Agent", .value = "override" },
        .{ .name = "X-Override", .value = "yes" },
    };

    var transfer: Transfer = undefined;
    transfer.req_headers = .{ .items = &overridden, .capacity = overridden.len };
    transfer._intercept_original_headers = &original;
    transfer.restoreInterceptHeaders();

    try testing.expectEqual(2, transfer.req_headers.items.len);
    try testing.expectEqual("User-Agent", transfer.req_headers.items[0].name);
    try testing.expectEqual("original", transfer.req_headers.items[0].value);
    try testing.expectEqual("X-Original", transfer.req_headers.items[1].name);
    try testing.expectEqual("yes", transfer.req_headers.items[1].value);
    try testing.expectEqual(null, transfer._intercept_original_headers);

    // idempotent once restored
    transfer.restoreInterceptHeaders();
    try testing.expectEqual(2, transfer.req_headers.items.len);
}

test "HttpClient: Owner.siteForCookies" {
    var top_url: [:0]const u8 = "http://attacker.example/attacker-nested";
    var top = testOwner(null, null);
    top.url = &top_url;

    var middle_url: [:0]const u8 = "http://victim.example/nested-middle";
    var middle = testOwner(null, null);
    middle.url = &middle_url;
    middle.parent = &top;

    var inner_url: [:0]const u8 = "http://victim.example/inner";
    var inner = testOwner(null, null);
    inner.url = &inner_url;
    inner.parent = &middle;

    // A worker has no site of its own; it takes its creating document's.
    var worker = testOwner(null, null);
    worker.parent = &inner;

    // A top-level document is its own site.
    try testing.expectEqual("http://attacker.example/attacker-nested", top.siteForCookies().url);

    // Cross-site with the top-level document: no site for cookies — for the
    // directly-embedded frame and for the same-site-with-parent frame nested
    // under it alike.
    try testing.expectEqual(true, middle.siteForCookies() == .none);
    try testing.expectEqual(true, inner.siteForCookies() == .none);
    try testing.expectEqual(true, worker.siteForCookies() == .none);

    // A fully same-site chain (subdomains included) keeps its site.
    top_url = "http://victim.example/";
    middle_url = "http://sub.victim.example/nested-middle";
    try testing.expectEqual("http://victim.example/inner", inner.siteForCookies().url);
    try testing.expectEqual("http://sub.victim.example/nested-middle", middle.siteForCookies().url);
    try testing.expectEqual("http://victim.example/inner", worker.siteForCookies().url);

    // about: documents inherit their creator's origin: transparent as an
    // ancestor, and judged through their nearest real ancestor themselves.
    middle_url = "about:blank";
    try testing.expectEqual("http://victim.example/inner", inner.siteForCookies().url);
    try testing.expectEqual("http://victim.example/", middle.siteForCookies().url);

    top_url = "http://attacker.example/";
    try testing.expectEqual(true, inner.siteForCookies() == .none);
    try testing.expectEqual("http://attacker.example/", middle.siteForCookies().url);

    // A worker under an about: document reads through it too.
    worker.parent = &middle;
    try testing.expectEqual("http://attacker.example/", worker.siteForCookies().url);

    // A top-level about:blank has nothing to read through.
    top_url = "about:blank";
    try testing.expectEqual("about:blank", top.siteForCookies().url);
}

test "HttpClient: fulfillIntercepted survives a done_callback that tears down the owner" {
    // Regression: the fulfilled response's done_callback runs JS which
    // navigates / closes the page, re-entrantly killing the transfer
    // (abortOwner -> kill). deliver() holds the transfer in `.delivering`,
    // so the teardown defers and there is exactly one free.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    var owner = testOwner(null, null);

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        done_called: bool = false,

        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
            // Mimics a navigation / page-close kicked off from inside the
            // fulfilled response's done_callback, which kills this transfer.
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "http://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .document,
            .shutdown_callback = noopShutdown,
            .ctx = &ctx,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    // Mirror the interception gate committing the transfer to CDP.
    transfer.park(.intercept_request);
    client.intercepted += 1;

    try client.fulfillIntercepted(transfer, 200, &.{}, "hello");
    // The response is buffered, not delivered from the CDP command.
    try testing.expectEqual(false, ctx.done_called);
    try testing.expectEqual(1, client.dispatch_count);

    _ = client.dispatchCompleted(.all);

    try testing.expect(ctx.done_called);
    // The transfer was freed exactly once: counter back to 0, dropped from the
    // id index and the owner list. A double-free would have underflowed
    // `intercepted` (or tripped the leaveIntercept assert).
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(0, client.dispatch_count);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: kill during done_callback does not also fire shutdown_callback" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    var owner = testOwner(null, null);

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        in_done: bool = false,
        done_called: bool = false,
        shutdown_called: bool = false,
        shutdown_during_done: bool = false,

        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
            self.in_done = true;
            defer self.in_done = false;
            // Navigation / page-close kicked off by JS inside done_callback.
            self.client.abortOwner(self.owner);
        }

        fn shutdownCallback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.shutdown_called = true;
            self.shutdown_during_done = self.in_done;
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "http://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .xhr,
            .shutdown_callback = Ctx.shutdownCallback,
            .ctx = &ctx,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    transfer.park(.intercept_request);
    client.intercepted += 1;
    try client.fulfillIntercepted(transfer, 200, &.{}, "hello");
    _ = client.dispatchCompleted(.all);

    try testing.expect(ctx.done_called);
    try testing.expectEqual(false, ctx.shutdown_during_done);
    try testing.expectEqual(false, ctx.shutdown_called);

    // Freed exactly once regardless.
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: kill during a non-terminal callback defers shutdown_callback" {
    // Same re-entrant kill, but from header_callback: the consumer has had no
    // outcome yet, so it must still get shutdown — once, and only after its
    // callback has returned. done_callback must not run on top of it.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    var owner = testOwner(null, null);

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        in_header: bool = false,
        done_called: bool = false,
        shutdown_calls: u8 = 0,
        shutdown_during_header: bool = false,

        fn headerCallback(transfer: *Transfer) !Transfer.HeaderResult {
            const self: *@This() = @ptrCast(@alignCast(transfer.req.ctx));
            self.in_header = true;
            defer self.in_header = false;
            self.client.abortOwner(self.owner);
            return .proceed;
        }

        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
        }

        fn shutdownCallback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.shutdown_calls += 1;
            self.shutdown_during_header = self.in_header;
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "http://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .xhr,
            .shutdown_callback = Ctx.shutdownCallback,
            .ctx = &ctx,
            .header_callback = Ctx.headerCallback,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    transfer.park(.intercept_request);
    client.intercepted += 1;
    try client.fulfillIntercepted(transfer, 200, &.{}, "hello");
    _ = client.dispatchCompleted(.all);

    try testing.expectEqual(1, ctx.shutdown_calls);
    try testing.expectEqual(false, ctx.shutdown_during_header);
    try testing.expectEqual(false, ctx.done_called);

    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: aborting a robots-parked transfer unlinks it from the gate" {
    // Regression: RobotsGate's single-flight map kept a raw *Transfer with
    // nothing removing it when a parked transfer was aborted out-of-band
    // (xhr.abort(), owner teardown). The robots.txt resolution would then
    // unpark freed memory.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);
    defer client.robots.deinit();

    const robots_url = "http://example.com/robots.txt";

    var transfers: [2]*Transfer = undefined;
    for (0..2) |i| {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .method = .GET,
                .url = "http://example.com/",
                .origin = null,
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .document,
                .shutdown_callback = noopShutdown,
            },
            .client = &client,
            .id = @intCast(i + 1),
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
        transfers[i] = transfer;
    }

    _ = try client.robots.single_flight.enter(robots_url, transfers[0], .robots);
    _ = try client.robots.single_flight.enter(robots_url, transfers[1], .robots);

    const t1 = transfers[0];
    const t2 = transfers[1];

    t1.abort(error.Abort);
    try testing.expectEqual(1, client.robots.single_flight.pending.get(robots_url).?.items.len);
    try testing.expect(client.robots.single_flight.pending.get(robots_url).?.items[0] == t2);
    try testing.expectEqual(1, client.transfers.count());

    t2.abort(error.Abort);
    try testing.expectEqual(0, client.robots.single_flight.pending.get(robots_url).?.items.len);
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: fulfillIntercepted follows a 3xx redirect" {
    // Regression for #2828: a CDP Fetch.fulfillRequest with a 3xx status + a
    // Location header must be followed like a real network redirect (re-issued
    // through the pipeline to the resolved target), not delivered as a final
    // response.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Only network.config (httpMaxRedirects, which ignores its config),
    // network.cache and the (empty) connection pool are read on this path.
    var net: Network = undefined;
    net.cache = Cache.noop;
    net.adblocker = null;
    // An empty pool makes processTransfer queue the re-issued request
    // instead of putting it on the wire — the queue IS the capture.
    net.available = .{};
    net.conn_mutex = .init;

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    client.network = &net;
    defer client.transfers.deinit(testing.allocator);

    // 302 with a relative Location: rewrite to GET, drop body, resolve target.
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .method = .POST,
                .url = "http://example.com/start",
                .origin = null,
                .body = "payload",
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .document,
                .shutdown_callback = noopShutdown,
                .ctx = undefined,
            },
            .client = &client,
            .id = 1,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.intercepted += 1;

        try client.fulfillIntercepted(transfer, 302, &.{
            .{ .name = "Location", .value = "/end" },
        }, null);

        // Re-issued (queued for the network), not delivered.
        try testing.expectEqual(true, transfer.state == .queued);
        try testing.expectEqual("http://example.com/end", transfer.req.url);
        try testing.expectEqual(.GET, transfer.req.method);
        try testing.expectEqual(null, transfer.req.body);
        // Unparked exactly once; transfer is still alive.
        try testing.expectEqual(0, client.intercepted);
        try testing.expectEqual(1, client.transfers.count());
        transfer.deinit();
    }

    // 307 with an absolute Location: keep method and body.
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .method = .POST,
                .url = "http://example.com/start",
                .origin = null,
                .body = "payload",
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .document,
                .shutdown_callback = noopShutdown,
                .ctx = undefined,
            },
            .client = &client,
            .id = 2,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.intercepted += 1;

        try client.fulfillIntercepted(transfer, 307, &.{
            .{ .name = "location", .value = "http://example.com/other" },
        }, null);

        try testing.expectEqual(true, transfer.state == .queued);
        try testing.expectEqual("http://example.com/other", transfer.req.url);
        try testing.expectEqual(.POST, transfer.req.method);
        try testing.expectEqual("payload", transfer.req.body.?);
        try testing.expectEqual(0, client.intercepted);
        transfer.deinit();
    }
}

test "HttpClient: fulfillIntercepted delivers a 3xx without a Location as the response" {
    // A redirect status with no Location header is not a redirect: the body is
    // delivered as the final response (matching the real-network path).
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    const Ctx = struct {
        done_called: bool = false,
        status: ?u16 = null,

        fn headerCallback(transfer: *Transfer) !Transfer.HeaderResult {
            const self: *@This() = @ptrCast(@alignCast(transfer.req.ctx));
            self.status = transfer.responseStatus();
            return .proceed;
        }

        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
        }
    };
    var ctx = Ctx{};

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "http://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .document,
            .shutdown_callback = noopShutdown,
            .ctx = &ctx,
            .header_callback = Ctx.headerCallback,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };
    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

    transfer.park(.intercept_request);
    client.intercepted += 1;

    try client.fulfillIntercepted(transfer, 302, &.{}, "body");
    _ = client.dispatchCompleted(.all);

    // Delivered (done_callback ran) and freed exactly once.
    try testing.expect(ctx.done_called);
    try testing.expectEqual(302, ctx.status.?);
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: abortParked survives an error_callback that tears down the owner" {
    // Same re-entrancy hazard as fulfillRequest, but on the abort path
    // (failRequest / continueWithAuth-cancel / session teardown). abortParked
    // buffers the failure; deliver() fires it while .delivering, so a
    // re-entrant owner teardown defers to the single deinit instead of
    // double-freeing.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    var owner = testOwner(null, null);

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        err_called: bool = false,

        fn errorCallback(ctx: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.err_called = true;
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "http://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .document,
            .shutdown_callback = noopShutdown,
            .ctx = &ctx,
            .error_callback = Ctx.errorCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    transfer.park(.intercept_request);
    client.intercepted += 1;

    transfer.abortParked(error.Abort);

    // The failure is buffered, not delivered from the CDP command itself —
    // error_callback JS must not run on a blocking request's stack.
    try testing.expectEqual(false, ctx.err_called);
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(1, client.dispatch_count);

    _ = client.dispatchCompleted(.all);

    try testing.expect(ctx.err_called);
    try testing.expectEqual(0, client.dispatch_count);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: abort survives an error_callback that tears down the owner" {
    // Regression: abort() fired error_callback before detachOrDeinit, so JS
    // in that callback that killed the transfer again (navigation ->
    // abortRequests -> kill) freed it inline and abort() then ran
    // detachOrDeinit on freed memory. abort holds .delivering across
    // requestFailed so the re-entrant kill defers to the single teardown.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    var owner = testOwner(null, null);

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        err_called: bool = false,

        fn errorCallback(ctx: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.err_called = true;
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    // .created — abort before the transfer was committed anywhere.
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .method = .GET,
                .url = "http://example.com/",
                .origin = null,
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .xhr,
                .shutdown_callback = noopShutdown,
                .ctx = &ctx,
                .error_callback = Ctx.errorCallback,
            },
            .client = &client,
            .id = 1,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
        owner.addTransfer(transfer);
        transfer.owner = &owner;

        transfer.abort(error.Abort);

        try testing.expect(ctx.err_called);
        try testing.expectEqual(0, client.transfers.count());
        try testing.expectEqual(null, owner.transfers.first);
    }

    // .buffered — abort while queued for dispatch; the queue must end up
    // empty and the transfer freed exactly once.
    {
        ctx.err_called = false;
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .method = .GET,
                .url = "http://example.com/",
                .origin = null,
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .xhr,
                .shutdown_callback = noopShutdown,
                .ctx = &ctx,
                .error_callback = Ctx.errorCallback,
            },
            .client = &client,
            .id = 2,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
        owner.addTransfer(transfer);
        transfer.owner = &owner;

        transfer.state = .buffered;
        transfer._dispatch_queued = true;
        client.dispatch_queue.append(&transfer._queue_node);
        client.dispatch_count += 1;

        transfer.abort(error.Abort);

        try testing.expect(ctx.err_called);
        try testing.expectEqual(0, client.dispatch_count);
        try testing.expectEqual(null, client.dispatch_queue.first);
        try testing.expectEqual(0, client.transfers.count());
        try testing.expectEqual(null, owner.transfers.first);
    }
}

test "HttpClient: throttled navigations wait for their per-host slot" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var net: Network = undefined;
    net.cache = Cache.noop;
    net.adblocker = null;
    net.web_bot_auth = null;
    // An empty pool makes processTransfer queue a started transfer instead
    // of putting it on the wire — .queued IS "entered the pipeline".
    net.available = .{};
    net.conn_mutex = .init;
    net.rate_limiter = @import("RateLimiter.zig").init(testing.allocator, 60_000, 1);
    defer net.rate_limiter.?.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    defer client.processGraveyard();
    client.network = &net;
    defer client.transfers.deinit(testing.allocator);

    const Helper = struct {
        fn newTransfer(c: *Client, p: *ArenaPool, id: u32, url: [:0]const u8, throttle: bool) !*Transfer {
            const arena = try p.acquire(.small, "test");
            const transfer = try arena.create(Transfer);
            transfer.* = .{
                .arena = arena,
                .owner = null,
                .req = .{
                    .method = .GET,
                    .url = url,
                    .origin = null,
                    .credentials_mode = .omit,
                    .request_mode = .no_cors,
                    .resource_type = .document,
                    .shutdown_callback = noopShutdown,
                    .ctx = undefined,
                    .throttle = throttle,
                },
                .client = c,
                .id = id,
                .start_time = 0,
            };
            try c.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
            return transfer;
        }
    };

    // First navigation to a host goes straight through.
    const a1 = try Helper.newTransfer(&client, &pool, 1, "http://a.example.com/1", true);
    try a1.submit();
    try testing.expectEqual(true, a1.state == .queued);
    try testing.expectEqual(0, client.delayed_count);

    // Later ones to the same host wait, in reservation order.
    const a2 = try Helper.newTransfer(&client, &pool, 2, "http://a.example.com/2", true);
    try a2.submit();
    try testing.expectEqual(true, a2.state == .delayed);
    const a3 = try Helper.newTransfer(&client, &pool, 3, "http://A.EXAMPLE.COM/3", true);
    try a3.submit();
    try testing.expectEqual(true, a3.state == .delayed);
    try testing.expectEqual(true, a2._run_at < a3._run_at);

    // Other hosts are independent, and non-throttled requests never wait.
    const b1 = try Helper.newTransfer(&client, &pool, 4, "http://b.example.com/1", true);
    try b1.submit();
    try testing.expectEqual(true, b1.state == .queued);
    const b2 = try Helper.newTransfer(&client, &pool, 5, "http://b.example.com/2", true);
    try b2.submit();
    try testing.expectEqual(true, b2.state == .delayed);
    const a4 = try Helper.newTransfer(&client, &pool, 6, "http://a.example.com/sub", false);
    try a4.submit();
    try testing.expectEqual(true, a4.state == .queued);

    // delayed_queue is ordered by _run_at: a2 <= b2 < a3
    try testing.expectEqual(3, client.delayed_count);
    try testing.expectEqual(3, client.activity().http);
    {
        var node = client.delayed_queue.first;
        var order: [3]u32 = undefined;
        for (&order) |*o| {
            const t: *Transfer = @fieldParentPtr("_node", node.?);
            o.* = t.id;
            node = node.?.next;
        }
        try testing.expectEqual(null, node);
        try testing.expectEqual(.{ 2, 5, 3 }, order);
    }

    // The tick's poll never sleeps past the next slot.
    const clamped = client.clampToDelayed(200);
    try testing.expectEqual(true, clamped <= 200);
    // and nothing is due yet
    try client.startPending();
    try testing.expectEqual(3, client.delayed_count);

    // Tearing down a delayed transfer unlinks it.
    b2.deinit();
    try testing.expectEqual(2, client.delayed_count);

    // Once its time comes, a delayed transfer enters the pipeline.
    a2._run_at = 0;
    try client.startPending();
    try testing.expectEqual(true, a2.state == .queued);
    try testing.expectEqual(true, a3.state == .delayed);
    try testing.expectEqual(1, client.delayed_count);
    try testing.expectEqual(a3, @as(*Transfer, @fieldParentPtr("_node", client.delayed_queue.first.?)));

    for ([_]*Transfer{ a1, a2, a3, b1, a4 }) |t| {
        t.deinit();
    }
    try testing.expectEqual(0, client.delayed_count);
    try testing.expectEqual(null, client.delayed_queue.first);
    try testing.expectEqual(null, client.pending_queue.first);
}
