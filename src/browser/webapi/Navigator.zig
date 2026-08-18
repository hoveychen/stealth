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

const Allocator = std.mem.Allocator;

const claimed_platform = @import("../../claimed_platform.zig");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

const PluginArray = @import("PluginArray.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const ModelContext = @import("ModelContext.zig");
const NetworkInformation = @import("NetworkInformation.zig");
const DOMException = @import("DOMException.zig");
const MediaDevices = @import("media/MediaDevices.zig");
const eme = @import("media/eme.zig");
const BatteryManager = @import("BatteryManager.zig");
const services = @import("navigator/services.zig");
const credential = @import("navigator/credentials.zig");
const presentation = @import("presentation.zig");
const geo = @import("geolocation.zig");
const devices = @import("navigator/devices.zig");

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_mime_types: PluginArray.MimeTypeArray = .{},
_permissions: Permissions = .{},
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},
// Chrome hands back the same object on every read of these, so each is created
// once and cached. They are allocated rather than embedded on purpose: the JS
// identity map is keyed by Zig address alone, and a struct's first-in-memory
// field shares its owner's address, so an embedded service object can come back
// branded [object Navigator].
_scheduling: ?*services.Scheduling = null,
_user_activation: ?*services.UserActivation = null,
_geolocation: ?*geo.Geolocation = null,
_protected_audience: ?*services.ProtectedAudience = null,
_credentials: ?*credential.CredentialsContainer = null,
_login: ?*services.NavigatorLogin = null,
_media_capabilities: ?*services.MediaCapabilities = null,
_media_session: ?*services.MediaSession = null,
_presentation: ?*presentation.Presentation = null,
_gpu: ?*services.GPU = null,
_keyboard: ?*services.Keyboard = null,
_locks: ?*services.LockManager = null,
_ink: ?*services.Ink = null,
_storage_buckets: ?*services.StorageBucketManager = null,
_temporary_storage: ?*services.DeprecatedStorageQuota = null,
_persistent_storage: ?*services.DeprecatedStorageQuota = null,
_wake_lock: ?*devices.WakeLock = null,
// EventTarget-backed, so these are built through the factory's prototype chain
// rather than created flat.
_window_controls_overlay: ?*devices.WindowControlsOverlay = null,
_bluetooth: ?*devices.Bluetooth = null,
_clipboard: ?*devices.Clipboard = null,
_managed: ?*devices.NavigatorManagedData = null,
_service_worker: ?*devices.ServiceWorkerContainer = null,
_virtual_keyboard: ?*devices.VirtualKeyboard = null,
_device_posture: ?*devices.DevicePosture = null,
_hid: ?*devices.HID = null,
_serial: ?*devices.Serial = null,
_usb: ?*devices.USB = null,
_xr: ?*devices.XRSystem = null,

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

// globalPrivacyControl is deliberately absent. Per
// https://w3c.github.io/gpc/#javascript-property the signal reflects an
// explicit user preference, and none is configured here; Chrome only defines
// the property once one is set, so on a stock Chrome 150 the name isn't on
// Navigator.prototype at all (measured). Absent and false read the same way to
// a GPC-compliant consent manager — no preference, show the consent UI — so
// this keeps the behaviour that made upstream stop returning true, without the
// extra name for a fingerprinter to enumerate.

// Constant, not the build host: this is one of five surfaces naming the
// platform, and the recorded tables the other four come from do not move with
// the machine. See src/claimed_platform.zig.
pub fn getPlatform(_: *const Navigator) []const u8 {
    return claimed_platform.navigator_platform;
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

// Creates the service object on first read and hands back the same one after
// that, the way Chrome does.
fn service(comptime T: type, slot: *?*T, frame: *Frame) !*T {
    if (slot.*) |existing| {
        return existing;
    }
    const created = try frame._factory.create(T{});
    slot.* = created;
    return created;
}

pub fn getScheduling(self: *Navigator, frame: *Frame) !*services.Scheduling {
    return service(services.Scheduling, &self._scheduling, frame);
}

pub fn getUserActivation(self: *Navigator, frame: *Frame) !*services.UserActivation {
    return service(services.UserActivation, &self._user_activation, frame);
}

pub fn getGeolocation(self: *Navigator, frame: *Frame) !*geo.Geolocation {
    return service(geo.Geolocation, &self._geolocation, frame);
}

pub fn getProtectedAudience(self: *Navigator, frame: *Frame) !*services.ProtectedAudience {
    return service(services.ProtectedAudience, &self._protected_audience, frame);
}

pub fn getCredentials(self: *Navigator, frame: *Frame) !*credential.CredentialsContainer {
    return service(credential.CredentialsContainer, &self._credentials, frame);
}

pub fn getLogin(self: *Navigator, frame: *Frame) !*services.NavigatorLogin {
    return service(services.NavigatorLogin, &self._login, frame);
}

pub fn getMediaCapabilities(self: *Navigator, frame: *Frame) !*services.MediaCapabilities {
    return service(services.MediaCapabilities, &self._media_capabilities, frame);
}

pub fn getMediaSession(self: *Navigator, frame: *Frame) !*services.MediaSession {
    return service(services.MediaSession, &self._media_session, frame);
}

pub fn getPresentation(self: *Navigator, frame: *Frame) !*presentation.Presentation {
    return service(presentation.Presentation, &self._presentation, frame);
}

pub fn getGpu(self: *Navigator, frame: *Frame) !*services.GPU {
    return service(services.GPU, &self._gpu, frame);
}

// Same lazy caching as `service`, but through the factory's prototype-chain
// allocator so EventTarget sits under the instance.
fn device(comptime T: type, slot: *?*T, frame: *Frame) !*T {
    if (slot.*) |existing| {
        return existing;
    }
    const created = try frame._factory.eventTarget(T{ ._proto = undefined });
    slot.* = created;
    return created;
}

pub fn getWakeLock(self: *Navigator, frame: *Frame) !*devices.WakeLock {
    return service(devices.WakeLock, &self._wake_lock, frame);
}

pub fn getWindowControlsOverlay(self: *Navigator, frame: *Frame) !*devices.WindowControlsOverlay {
    return device(devices.WindowControlsOverlay, &self._window_controls_overlay, frame);
}

pub fn getBluetooth(self: *Navigator, frame: *Frame) !*devices.Bluetooth {
    return device(devices.Bluetooth, &self._bluetooth, frame);
}

pub fn getClipboard(self: *Navigator, frame: *Frame) !*devices.Clipboard {
    return device(devices.Clipboard, &self._clipboard, frame);
}

pub fn getManaged(self: *Navigator, frame: *Frame) !*devices.NavigatorManagedData {
    return device(devices.NavigatorManagedData, &self._managed, frame);
}

pub fn getServiceWorker(self: *Navigator, frame: *Frame) !*devices.ServiceWorkerContainer {
    return device(devices.ServiceWorkerContainer, &self._service_worker, frame);
}

pub fn getVirtualKeyboard(self: *Navigator, frame: *Frame) !*devices.VirtualKeyboard {
    return device(devices.VirtualKeyboard, &self._virtual_keyboard, frame);
}

pub fn getDevicePosture(self: *Navigator, frame: *Frame) !*devices.DevicePosture {
    return device(devices.DevicePosture, &self._device_posture, frame);
}

pub fn getHid(self: *Navigator, frame: *Frame) !*devices.HID {
    return device(devices.HID, &self._hid, frame);
}

pub fn getSerial(self: *Navigator, frame: *Frame) !*devices.Serial {
    return device(devices.Serial, &self._serial, frame);
}

pub fn getUsb(self: *Navigator, frame: *Frame) !*devices.USB {
    return device(devices.USB, &self._usb, frame);
}

pub fn getXr(self: *Navigator, frame: *Frame) !*devices.XRSystem {
    return device(devices.XRSystem, &self._xr, frame);
}

pub fn getKeyboard(self: *Navigator, frame: *Frame) !*services.Keyboard {
    return service(services.Keyboard, &self._keyboard, frame);
}

pub fn getLocks(self: *Navigator, frame: *Frame) !*services.LockManager {
    return service(services.LockManager, &self._locks, frame);
}

pub fn getInk(self: *Navigator, frame: *Frame) !*services.Ink {
    return service(services.Ink, &self._ink, frame);
}

pub fn getStorageBuckets(self: *Navigator, frame: *Frame) !*services.StorageBucketManager {
    return service(services.StorageBucketManager, &self._storage_buckets, frame);
}

// Two distinct objects, one per quota pool, as on Chrome — but both quoting the
// one pool size, which is what the reference Chrome does: temporary and
// persistent answered the same 10 GiB as navigator.storage.estimate()
// (measured). A pool that disagrees with itself across the three surfaces is
// its own signal, and the temporary figure specifically is what the private-
// window probe reads; see StorageManager.quota_bytes.
pub fn getWebkitTemporaryStorage(self: *Navigator, frame: *Frame) !*services.DeprecatedStorageQuota {
    if (self._temporary_storage) |existing| {
        return existing;
    }
    const created = try frame._factory.create(services.DeprecatedStorageQuota{ ._quota = StorageManager.quota_bytes });
    self._temporary_storage = created;
    return created;
}

pub fn getWebkitPersistentStorage(self: *Navigator, frame: *Frame) !*services.DeprecatedStorageQuota {
    if (self._persistent_storage) |existing| {
        return existing;
    }
    const created = try frame._factory.create(services.DeprecatedStorageQuota{ ._quota = StorageManager.quota_bytes });
    self._persistent_storage = created;
    return created;
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

// == Chrome-only members with no machinery behind them ==
//
// Everything below exists because it is on Chrome 150's Navigator.prototype and
// a missing name is as readable as a wrong value. Each answers with the state a
// real Chrome is in when the feature has nothing to report — measured on a
// headed Chrome 150 over http://localhost, not recalled.

// Four empty slots, exactly as Chrome reported with nothing plugged in.
pub fn getGamepads(_: *const Navigator) [4]?bool {
    return .{ null, null, null, null };
}

// No vibration motor on a desktop, so Chrome answers false.
pub fn vibrate(_: *const Navigator, _: js.Value) bool {
    return false;
}

// canShare is a shape check: something to share is true, an empty dictionary is
// false (both measured).
pub fn canShare(_: *const Navigator, data_: ?ShareData) bool {
    const data = data_ orelse return false;
    return data.title != null or data.text != null or data.url != null or data.files != null;
}

const ShareData = struct {
    title: ?[]const u8 = null,
    text: ?[]const u8 = null,
    url: ?[]const u8 = null,
    files: ?js.Value = null,
};

// Sharing needs a user gesture, and nothing here ever has one.
pub fn share(_: *const Navigator, _: ?ShareData, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
}

// No launcher icon to badge; Chrome resolves with nothing either way.
pub fn setAppBadge(_: *const Navigator, _: ?f64, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn clearAppBadge(_: *const Navigator, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

// The legacy callback spelling of getUserMedia, and its webkit alias. Routed
// through navigator.mediaDevices.getUserMedia's answer so the two can't
// disagree about what devices exist: that rejects NotAllowedError, so the error
// callback gets the same DOMException.
pub fn getUserMedia(
    _: *const Navigator,
    _: js.Value,
    _: js.Function,
    on_error: js.Function,
    exec: *const Execution,
) !void {
    const dom = try exec.arena.create(DOMException);
    dom.* = DOMException.fromError(error.NotAllowedError).?;
    _ = try on_error.call(void, .{dom});
}

// Chrome's permission prompt leaves this pending, and it was still pending four
// seconds later (measured). Resolving it with a MIDI access object we don't
// have would be the invention, and rejecting it claims a decision nobody made.
//
// A MIDIOptions that is not a dictionary never reaches the prompt: it is a
// rejection, not a synchronous throw (measured -- `requestMIDIAccess(1)`
// rejects while `requestMIDIAccess(null)` stays pending like the rest).
pub fn requestMIDIAccess(_: *const Navigator, options_: ?js.Value, exec: *const Execution) js.Promise {
    const local = exec.js.local.?;
    if (options_) |options| {
        if (!options.isNullOrUndefined() and !options.isObject()) {
            return local.rejectPromise(.{
                .type_error = "Failed to execute 'requestMIDIAccess' on 'Navigator': The provided value " ++
                    "is not of type 'MIDIOptions'.",
            });
        }
    }
    const resolver = local.createPromiseResolver();
    const promise = resolver.promise();
    promise.markAsHandled();
    return promise;
}

// A plain desktop Chrome answers for two key systems, Clear Key and Widevine,
// so refusing every one of them was itself the signal. The negotiation lives in
// media/eme.zig next to the objects it hands out.
pub fn requestMediaKeySystemAccess(
    _: *const Navigator,
    key_system_: ?js.Value,
    configurations_: ?js.Value,
    exec: *const Execution,
) js.Promise {
    return eme.requestMediaKeySystemAccess(key_system_, configurations_, exec);
}

// Nothing is installed alongside this browser.
pub fn getInstalledRelatedApps(_: *const Navigator, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
}

// == Protected Audience ==
//
// This engine joins no interest groups and runs no auctions, so every entry
// point answers with Chrome's own "no auction happened" outcome. The k-anonymity
// flag is a data accessor, not a method, and false on Chrome (measured).

pub fn getDeprecatedRunAdAuctionEnforcesKAnonymity(_: *const Navigator) bool {
    return false;
}

// Measured, and true of any frame that was not itself loaded from an auction.
pub fn adAuctionComponents(_: *const Navigator, _: u32) !void {
    return error.InvalidStateError;
}

// No interest groups joined means no bids, and no bids means no winner. Chrome
// resolves null for an auction nobody wins.
pub fn runAdAuction(_: *const Navigator, _: js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(null);
}

pub fn canLoadAdAuctionFencedFrame(_: *const Navigator) bool {
    return true;
}

pub fn joinAdInterestGroup(_: *const Navigator, _: js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn leaveAdInterestGroup(_: *const Navigator, _: ?js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn clearOriginJoinedAdInterestGroups(
    _: *const Navigator,
    _: []const u8,
    _: ?js.Value,
    exec: *const Execution,
) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn updateAdInterestGroups(_: *const Navigator) void {}

// The same generator crypto.randomUUID uses, so the two can't be told apart.
pub fn createAuctionNonce(_: *const Navigator, exec: *const Execution) !js.Promise {
    var hex: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&hex);
    return exec.js.local.?.resolvePromise(try exec.call_arena.dupe(u8, &hex));
}

// An urn that named no auction result maps to the empty string (measured).
pub fn deprecatedURNToURL(_: *const Navigator, _: js.Value, _: ?bool, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(@as([]const u8, ""));
}

pub fn deprecatedReplaceInURN(_: *const Navigator, _: js.Value, _: js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

// Chrome resolves an AdAuctionData here; we have no auction server to build a
// request for, so this reports the same absence the rest of the family does.
// Unlike its siblings the shape of Chrome's success value was not measured —
// the probe origin was http, where Chrome refuses the call outright.
pub fn getInterestGroupAdAuctionData(_: *const Navigator, _: js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(null);
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
        // Deliberately not `empty_with_no_proto`: some of the service objects
        // above carry state (Geolocation's watch counter, MediaSession's
        // playbackState), and an empty binding hands the getters a pointer to a
        // comptime constant, so writing through it faults.
    };

    // Declaration order is Chrome 150's own `Object.getOwnPropertyNames(
    // Navigator.prototype)` order, measured on a secure origin. The order is a
    // surface a fingerprinter can hash, so it is not alphabetical and not
    // grouped by kind — it is Blink's, quirks included.
    //
    // Two things can't be matched exactly. Blink emits `constructor` between
    // vibrate and deprecatedRunAdAuctionEnforcesKAnonymity; V8 gives us ours
    // first and puts it last in the enumeration, and a binding can't choose
    // that. And modelContext is ours and not Chrome's — it is the WebMCP
    // surface this fork exists to expose, so it stays, parked at the end where
    // it perturbs the rest of the order least.
    pub const vendorSub = bridge.accessor(Navigator.getVendorSub, null, .{});
    pub const productSub = bridge.accessor(Navigator.getProductSub, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const scheduling = bridge.accessor(Navigator.getScheduling, null, .{ .exposed = .window });
    pub const userActivation = bridge.accessor(Navigator.getUserActivation, null, .{ .exposed = .window });
    pub const geolocation = bridge.accessor(Navigator.getGeolocation, null, .{ .exposed = .window });
    pub const doNotTrack = bridge.accessor(Navigator.getDoNotTrack, null, .{});
    pub const webkitTemporaryStorage = bridge.accessor(Navigator.getWebkitTemporaryStorage, null, .{ .exposed = .window });
    pub const webkitPersistentStorage = bridge.accessor(Navigator.getWebkitPersistentStorage, null, .{ .exposed = .window });
    pub const windowControlsOverlay = bridge.accessor(Navigator.getWindowControlsOverlay, null, .{ .exposed = .window });
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const cookieEnabled = bridge.accessor(Navigator.getCookieEnabled, null, .{});
    pub const appCodeName = bridge.accessor(Navigator.getAppCodeName, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const language = bridge.accessor(Navigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(Navigator.getOnLine, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{});
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{ .exposed = .window });
    pub const mimeTypes = bridge.accessor(Navigator.getMimeTypes, null, .{ .exposed = .window });
    pub const pdfViewerEnabled = bridge.accessor(Navigator.getPdfViewerEnabled, null, .{});
    pub const connection = bridge.accessor(Navigator.getConnection, null, .{ .exposed = .window });
    pub const getGamepads = bridge.function(Navigator.getGamepads, .{ .exposed = .window });
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{ .exposed = .window, .noop = true });
    pub const vibrate = bridge.function(Navigator.vibrate, .{ .exposed = .window });
    pub const deprecatedRunAdAuctionEnforcesKAnonymity = bridge.accessor(
        Navigator.getDeprecatedRunAdAuctionEnforcesKAnonymity,
        null,
        .{ .exposed = .window },
    );
    pub const protectedAudience = bridge.accessor(Navigator.getProtectedAudience, null, .{ .exposed = .window });
    pub const bluetooth = bridge.accessor(Navigator.getBluetooth, null, .{ .exposed = .window });
    pub const clipboard = bridge.accessor(Navigator.getClipboard, null, .{ .exposed = .window });
    pub const credentials = bridge.accessor(Navigator.getCredentials, null, .{ .exposed = .window });
    pub const keyboard = bridge.accessor(Navigator.getKeyboard, null, .{ .exposed = .window });
    pub const managed = bridge.accessor(Navigator.getManaged, null, .{ .exposed = .window });
    pub const mediaDevices = bridge.accessor(Navigator.getMediaDevices, null, .{ .exposed = .window });
    pub const serviceWorker = bridge.accessor(Navigator.getServiceWorker, null, .{ .exposed = .window });
    pub const virtualKeyboard = bridge.accessor(Navigator.getVirtualKeyboard, null, .{ .exposed = .window });
    pub const wakeLock = bridge.accessor(Navigator.getWakeLock, null, .{ .exposed = .window });
    pub const deviceMemory = bridge.accessor(Navigator.getDeviceMemory, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});
    pub const locks = bridge.accessor(Navigator.getLocks, null, .{ .exposed = .window });
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const gpu = bridge.accessor(Navigator.getGpu, null, .{ .exposed = .window });
    pub const login = bridge.accessor(Navigator.getLogin, null, .{ .exposed = .window });
    pub const ink = bridge.accessor(Navigator.getInk, null, .{ .exposed = .window });
    pub const mediaCapabilities = bridge.accessor(Navigator.getMediaCapabilities, null, .{ .exposed = .window });
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const devicePosture = bridge.accessor(Navigator.getDevicePosture, null, .{ .exposed = .window });
    pub const hid = bridge.accessor(Navigator.getHid, null, .{ .exposed = .window });
    pub const mediaSession = bridge.accessor(Navigator.getMediaSession, null, .{ .exposed = .window });
    pub const presentation = bridge.accessor(Navigator.getPresentation, null, .{ .exposed = .window });
    pub const serial = bridge.accessor(Navigator.getSerial, null, .{ .exposed = .window });
    pub const usb = bridge.accessor(Navigator.getUsb, null, .{ .exposed = .window });
    pub const xr = bridge.accessor(Navigator.getXr, null, .{ .exposed = .window });
    pub const storageBuckets = bridge.accessor(Navigator.getStorageBuckets, null, .{ .exposed = .window });
    pub const adAuctionComponents = bridge.function(Navigator.adAuctionComponents, .{ .exposed = .window });
    pub const runAdAuction = bridge.function(Navigator.runAdAuction, .{ .exposed = .window });
    pub const canLoadAdAuctionFencedFrame = bridge.function(Navigator.canLoadAdAuctionFencedFrame, .{ .exposed = .window });
    pub const canShare = bridge.function(Navigator.canShare, .{ .exposed = .window });
    pub const share = bridge.function(Navigator.share, .{ .exposed = .window });
    pub const clearAppBadge = bridge.function(Navigator.clearAppBadge, .{ .exposed = .window });
    pub const getBattery = bridge.function(Navigator.getBattery, .{ .exposed = .window });
    pub const getUserMedia = bridge.function(Navigator.getUserMedia, .{ .exposed = .window });
    pub const requestMIDIAccess = bridge.function(Navigator.requestMIDIAccess, .{ .exposed = .window });
    pub const requestMediaKeySystemAccess = bridge.function(Navigator.requestMediaKeySystemAccess, .{ .arity = 2, .exposed = .window });
    pub const setAppBadge = bridge.function(Navigator.setAppBadge, .{ .exposed = .window });
    pub const webkitGetUserMedia = bridge.function(Navigator.getUserMedia, .{ .exposed = .window, .js_name = "webkitGetUserMedia" });
    pub const clearOriginJoinedAdInterestGroups = bridge.function(Navigator.clearOriginJoinedAdInterestGroups, .{ .exposed = .window });
    pub const createAuctionNonce = bridge.function(Navigator.createAuctionNonce, .{ .exposed = .window });
    pub const joinAdInterestGroup = bridge.function(Navigator.joinAdInterestGroup, .{ .exposed = .window });
    pub const leaveAdInterestGroup = bridge.function(Navigator.leaveAdInterestGroup, .{ .exposed = .window });
    pub const updateAdInterestGroups = bridge.function(Navigator.updateAdInterestGroups, .{ .exposed = .window });
    pub const deprecatedReplaceInURN = bridge.function(Navigator.deprecatedReplaceInURN, .{ .exposed = .window });
    pub const deprecatedURNToURL = bridge.function(Navigator.deprecatedURNToURL, .{ .exposed = .window });
    pub const getInstalledRelatedApps = bridge.function(Navigator.getInstalledRelatedApps, .{ .exposed = .window });
    pub const getInterestGroupAdAuctionData = bridge.function(Navigator.getInterestGroupAdAuctionData, .{ .exposed = .window });
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .exposed = .window });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .exposed = .window });

    // Not Chrome's; see the note above.
    pub const modelContext = bridge.accessor(Navigator.getModelContext, null, .{ .exposed = .window });
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
