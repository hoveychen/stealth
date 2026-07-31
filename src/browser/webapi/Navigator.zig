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
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

const PluginArray = @import("PluginArray.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const ModelContext = @import("ModelContext.zig");
const NetworkInformation = @import("NetworkInformation.zig");
const MediaDevices = @import("media/MediaDevices.zig");
const BatteryManager = @import("BatteryManager.zig");

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_mime_types: PluginArray.MimeTypeArray = .{},
_permissions: Permissions = .{},
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, exec: *const Execution) []const u8 {
    return exec.session.browser.http_client.getUserAgent();
}

// navigator.languages is the Accept-Language header, parsed. Hardcoding
// en-US here while the wire carried whatever --accept-language said made the
// two contradict each other, and a page can read both: a request advertising
// de-DE from a navigator claiming en-US is a louder signal than either value
// on its own.
//
// Read through http_client rather than off the config so a CDP
// acceptLanguage override is reflected too.
pub fn getLanguages(_: *const Navigator, exec: *const Execution) ![]const []const u8 {
    return parseLanguages(exec.call_arena, exec.session.browser.http_client.getLanguages());
}

pub fn getLanguage(_: *const Navigator, exec: *const Execution) ![]const u8 {
    const tags = try parseLanguages(exec.call_arena, exec.session.browser.http_client.getLanguages());
    // navigator.language is the first entry of navigator.languages.
    return if (tags.len == 0) "" else tags[0];
}

// Splits an Accept-Language value into its bare tags, dropping the q-weights:
// "de-DE,de;q=0.9,en;q=0.8" -> { "de-DE", "de", "en" }. Chrome exposes the
// tags in the header's own order and never shows the weights.
fn parseLanguages(allocator: Allocator, header: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |part| {
        // Everything from the first ';' on is parameters (q-weight).
        const bare = part[0 .. std.mem.indexOfScalar(u8, part, ';') orelse part.len];
        const tag = std.mem.trim(u8, bare, " \t");
        if (tag.len == 0) continue;
        try tags.append(allocator, tag);
    }
    return tags.items;
}

pub fn getDoNotTrack(_: *const Navigator) ?[]const u8 {
    return null;
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return "Netscape";
}

pub fn getAppCodeName(_: *const Navigator) []const u8 {
    return "Mozilla";
}

// Chrome's appVersion is its user-agent with the leading "Mozilla/" removed —
// not an independent version number. Returning "1.0" next to a Chrome
// user-agent was a direct contradiction, and it is one a page reads in a single
// expression.
pub fn getAppVersion(_: *const Navigator, exec: *const Execution) []const u8 {
    const ua = exec.session.browser.http_client.getUserAgent();
    const prefix = "Mozilla/";
    return if (std.mem.startsWith(u8, ua, prefix)) ua[prefix.len..] else ua;
}

pub fn getOnLine(_: *const Navigator) bool {
    return true;
}

pub fn getCookieEnabled(_: *const Navigator) bool {
    return true;
}

// Fixed rather than read off the host. Reporting the real core count and RAM
// would look more like a specific real Chrome, but it makes the same build
// fingerprint differently on every machine; a fixed pair is stable across a
// fleet at the cost of being shared by it. 8 cores is an unremarkable desktop
// in a way 4 no longer is.
//
// deviceMemory is already coarse by design: Chrome rounds it to a power of two,
// so 8 is a value a real Chrome reports rather than an invented one.
pub fn getHardwareConcurrency(_: *const Navigator) u32 {
    return 8;
}

pub fn getDeviceMemory(_: *const Navigator) f64 {
    return 8.0;
}

pub fn getMaxTouchPoints(_: *const Navigator) u32 {
    return 0;
}

// The next three are fixed strings in every Chromium build — they don't vary
// by platform or version. Values taken from the Chrome 150 capture in
// tools/fingerprint/results/reference-chrome-headed.json, not from memory.
// An empty vendor next to a Chrome user-agent is a direct contradiction, and
// a missing productSub is what several bot checks probe for.
pub fn getVendor(_: *const Navigator) []const u8 {
    return "Google Inc.";
}

pub fn getProductSub(_: *const Navigator) []const u8 {
    return "20030107";
}

pub fn getVendorSub(_: *const Navigator) []const u8 {
    return "";
}

// Chrome ships the PDF viewer, so this is true on every desktop build. It
// pairs with navigator.plugins / navigator.mimeTypes, which describe that same
// viewer — see PluginArray.zig.
pub fn getPdfViewerEnabled(_: *const Navigator) bool {
    return true;
}

pub fn getProduct(_: *const Navigator) []const u8 {
    return "Gecko";
}

pub fn getWebdriver(_: *const Navigator) bool {
    return false;
}

// Default to false: per https://w3c.github.io/gpc/#javascript-property the
// signal reflects an explicit user preference, and none is configured here.
// Firefox defaults to false; Chrome doesn't expose the property. Returning
// true made GPC-compliant consent managers treat every page load as "reject
// tracking" and skip their consent UI entirely.
pub fn getGlobalPrivacyControl(_: *const Navigator) bool {
    return false;
}

pub fn getPlatform(_: *const Navigator) []const u8 {
    return switch (builtin.os.tag) {
        .macos => "MacIntel",
        .windows => "Win32",
        .linux => "Linux x86_64",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

/// Returns whether Java is enabled (always false)
pub fn javaEnabled(_: *const Navigator) bool {
    return false;
}

/// Noop, signal that the data was successfully queued
pub fn sendBeacon(_: *const Navigator, url: js.Value, data: ?js.Value) bool {
    _ = url;
    _ = data;
    return true;
}

pub fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

pub fn getMimeTypes(self: *Navigator) *PluginArray.MimeTypeArray {
    return &self._mime_types;
}

pub fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

pub fn getStorage(self: *Navigator) *StorageManager {
    return &self._storage;
}

pub fn getUserAgentData(self: *Navigator) *NavigatorUAData {
    return &self._ua_data;
}

pub fn getModelContext(_: *const Navigator, frame: *Frame) *ModelContext {
    return &frame.window._model_context;
}

pub fn getConnection(_: *const Navigator, frame: *Frame) *NetworkInformation {
    return frame.window._connection;
}

pub fn getMediaDevices(_: *const Navigator, frame: *Frame) !*MediaDevices {
    if (frame.window._media_devices) |media_devices| {
        return media_devices;
    }
    const media_devices = try frame._factory.eventTarget(MediaDevices{
        ._proto = undefined,
    });
    frame.window._media_devices = media_devices;
    return media_devices;
}

// Chrome hands back the same BatteryManager on every call, so it's cached.
pub fn getBattery(_: *const Navigator, exec: *const Execution) !js.Promise {
    // Window-only, so the global is always a Frame.
    const frame = exec.js.global.frame;
    const battery = frame.window._battery orelse blk: {
        const created = try frame._factory.eventTarget(BatteryManager{
            ._proto = undefined,
        });
        frame.window._battery = created;
        break :blk created;
    };
    return exec.js.local.?.resolvePromise(battery);
}

pub fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}
pub fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}

fn validateProtocolHandlerScheme(scheme: []const u8) !void {
    const allowed = std.StaticStringMap(void).initComptime(.{
        .{ "bitcoin", {} },
        .{ "cabal", {} },
        .{ "dat", {} },
        .{ "did", {} },
        .{ "dweb", {} },
        .{ "ethereum", .{} },
        .{ "ftp", {} },
        .{ "ftps", {} },
        .{ "geo", {} },
        .{ "im", {} },
        .{ "ipfs", {} },
        .{ "ipns", .{} },
        .{ "irc", {} },
        .{ "ircs", {} },
        .{ "hyper", {} },
        .{ "magnet", {} },
        .{ "mailto", {} },
        .{ "matrix", {} },
        .{ "mms", {} },
        .{ "news", {} },
        .{ "nntp", {} },
        .{ "openpgp4fpr", {} },
        .{ "sftp", {} },
        .{ "sip", {} },
        .{ "sms", {} },
        .{ "smsto", {} },
        .{ "ssb", {} },
        .{ "ssh", {} },
        .{ "tel", {} },
        .{ "urn", {} },
        .{ "webcal", {} },
        .{ "wtai", {} },
        .{ "xmpp", {} },
    });
    if (allowed.has(scheme)) {
        return;
    }

    if (scheme.len < 5 or !std.mem.startsWith(u8, scheme, "web+")) {
        return error.SecurityError;
    }
    for (scheme[4..]) |b| {
        if (std.ascii.isLower(b) == false) {
            return error.SecurityError;
        }
    }
}

fn validateProtocolHandlerURL(url: [:0]const u8, frame: *const Frame) !void {
    if (std.mem.indexOf(u8, url, "%s") == null) {
        return error.SyntaxError;
    }
    if (frame.isSameOrigin(url) == false) {
        return error.SyntaxError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigator);

    pub const Meta = struct {
        pub const name = "Navigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appCodeName = bridge.accessor(Navigator.getAppCodeName, null, .{});
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const language = bridge.accessor(Navigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(Navigator.getOnLine, null, .{});
    pub const cookieEnabled = bridge.accessor(Navigator.getCookieEnabled, null, .{});
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const deviceMemory = bridge.accessor(Navigator.getDeviceMemory, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{});
    pub const vendorSub = bridge.accessor(Navigator.getVendorSub, null, .{});
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const productSub = bridge.accessor(Navigator.getProductSub, null, .{});
    pub const pdfViewerEnabled = bridge.accessor(Navigator.getPdfViewerEnabled, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{});
    pub const doNotTrack = bridge.accessor(Navigator.getDoNotTrack, null, .{});
    pub const globalPrivacyControl = bridge.accessor(Navigator.getGlobalPrivacyControl, null, .{});

    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{ .exposed = .window, .noop = true });
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});

    // window only
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{ .exposed = .window });
    pub const mimeTypes = bridge.accessor(Navigator.getMimeTypes, null, .{ .exposed = .window });
    pub const modelContext = bridge.accessor(Navigator.getModelContext, null, .{ .exposed = .window });
    pub const connection = bridge.accessor(Navigator.getConnection, null, .{ .exposed = .window });
    pub const mediaDevices = bridge.accessor(Navigator.getMediaDevices, null, .{ .exposed = .window });
    pub const getBattery = bridge.function(Navigator.getBattery, .{ .exposed = .window });
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .exposed = .window });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .exposed = .window });
};

const testing = @import("../../testing.zig");
test "WebApi: Navigator" {
    try testing.htmlRunner("navigator", .{});
}

test "Navigator: parseLanguages drops q-weights and keeps header order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expectTags = struct {
        fn f(expected: []const []const u8, actual: []const []const u8) !void {
            try testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |e, got| {
                try testing.expectString(e, got);
            }
        }
    }.f;

    // The default, which is also what Chrome reports out of the box.
    try expectTags(&.{ "en-US", "en" }, try parseLanguages(a, "en-US,en;q=0.9"));

    try expectTags(&.{ "de-DE", "de", "en" }, try parseLanguages(a, "de-DE,de;q=0.9,en;q=0.8"));

    // Whitespace after the commas is legal in the header and must not survive
    // into the tag.
    try expectTags(&.{ "fr-FR", "fr" }, try parseLanguages(a, "fr-FR, fr;q=0.5"));

    // Degenerate values shouldn't produce empty tags.
    try testing.expectEqual(@as(usize, 0), (try parseLanguages(a, "")).len);
    try testing.expectEqual(@as(usize, 0), (try parseLanguages(a, " , ")).len);
}
