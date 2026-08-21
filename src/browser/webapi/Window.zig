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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Console = @import("Console.zig");
const History = @import("History.zig");
const Navigation = @import("navigation/Navigation.zig");
const Crypto = @import("Crypto.zig");
const CSS = @import("CSS.zig");
const Navigator = @import("Navigator.zig");
const ModelContext = @import("ModelContext.zig");
const Screen = @import("Screen.zig");
const scheduler = @import("scheduler.zig");
const BarProp = @import("BarProp.zig");
const External = @import("External.zig");
const StyleMedia = @import("StyleMedia.zig");
const trusted_types = @import("trusted_types.zig");
const reporting = @import("reporting.zig");
const DOMException = @import("DOMException.zig");
const launch_queue = @import("launch_queue.zig");
const ImageBitmap = @import("canvas/ImageBitmap.zig");
const cache_storage = @import("storage/cache_storage.zig");
const VisualViewport = @import("VisualViewport.zig");
const Viewport = @import("Viewport.zig");
const NetworkInformation = @import("NetworkInformation.zig");
const MediaDevices = @import("media/MediaDevices.zig");
const BatteryManager = @import("BatteryManager.zig");
const filesystem = @import("filesystem.zig");
const SpeechSynthesis = @import("speech/SpeechSynthesis.zig");
const SpeechSynthesisVoice = @import("speech/SpeechSynthesisVoice.zig");
const Performance = @import("Performance.zig");
const Chrome = @import("Chrome.zig");
const Document = @import("Document.zig");
const Location = @import("Location.zig");
const Fetch = @import("net/Fetch.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const global_event_handlers = @import("global_event_handlers.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const MessagePort = @import("MessagePort.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");
const idb = @import("storage/idb/idb.zig");
const CookieStore = @import("storage/CookieStore.zig");
const Element = @import("Element.zig");
const CSSStyleDeclaration = @import("css/CSSStyleDeclaration.zig");
const HighlightRegistry = @import("css/highlights.zig").HighlightRegistry;
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const Selection = @import("Selection.zig");
const Timers = @import("Timers.zig");
const Notification = @import("../../Notification.zig");

const log = lp.log;

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ Window, CrossOriginWindow };
}

const Window = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_frame: *Frame,
_document: *Document,
_css: CSS = .init,
_crypto: Crypto = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_model_context: ModelContext = .init,
// The six BarProp objects behind window.locationbar & friends. Six separate
// fields rather than one shared object, because Chrome hands back six distinct
// objects (measured: window.locationbar !== window.menubar).
_locationbar: BarProp = .init,
_menubar: BarProp = .init,
_personalbar: BarProp = .init,
_scrollbars: BarProp = .init,
_statusbar: BarProp = .init,
_toolbar: BarProp = .init,
_external: External = .init,
_trusted_types: trusted_types.TrustedTypePolicyFactory = .init,
_launch_queue: launch_queue.LaunchQueue = .init,
_caches: cache_storage.CacheStorage = .init,
_style_media: StyleMedia = .init,
// window.crashReport. One per window, and the same object on every read
// (measured) -- the enumerable getter-only accessor Chrome has.
_crash_report: reporting.CrashReportContext = .init,
// window.viewport. One per window like crashReport, but [Replaceable] where
// that one is not (measured) -- so the accessor has a setter.
_viewport: Viewport = .init,
// window.status. Blink kept the accessor after dropping the status bar it used
// to write to, so it is a plain string cell that remembers whatever is
// assigned. Owned by the frame arena once written.
_status: []const u8 = "",
_screen: *Screen,
_visual_viewport: *VisualViewport,
_connection: *NetworkInformation,

// navigator.mediaDevices and the BatteryManager navigator.getBattery()
// resolves with. Both are built on first use: pages that never ask shouldn't
// pay for them, and getBattery() has to hand back the same object every call.
// RemotePlayback.watchAvailability()'s id counter. One per window rather than
// one per RemotePlayback: a second media element continues the same sequence
// instead of starting over (measured).
_remote_playback_watch_id: u32 = 0,
_media_devices: ?*MediaDevices = null,
_battery: ?*BatteryManager = null,
// CSS.highlights. One registry per window, built on first use, because a page
// that registers a highlight has to find it again on the next read.
_css_highlights: ?*HighlightRegistry = null,
// window.speechSynthesis, and the voice objects getVoices() hands back. Both
// are built on first use and then reused, because scripts compare voices by
// identity across calls.
_speech_synthesis: ?*SpeechSynthesis = null,
_voices: ?[]*SpeechSynthesisVoice = null,
// The two sandboxed filesystems webkitRequestFileSystem hands out, indexed by
// window.TEMPORARY / window.PERSISTENT. Built on first request and then reused:
// a second request for the same quota type returns the same object (measured).
_filesystems: [2]?*@import("filesystem.zig").DOMFileSystem = .{ null, null },
_performance: Performance,
// Epoch milliseconds at which the load event fired, or 0 before that. Only
// chrome.csi() / chrome.loadTimes() read it — both report the load timestamp,
// and the alternative was inventing one.
_load_epoch_ms: i64 = 0,
_cookie_store: ?*CookieStore = null,
_idb_factory: ?*idb.IDBFactory = null,
_reporting_error: bool = false,
_current_event: ?*Event = null,
_location: *Location,
_timers: Timers = .{},
_scheduler: scheduler.Scheduler = .init,
_custom_elements: CustomElementRegistry = .{},
_scroll_pos: struct {
    x: u32,
    y: u32,
    state: enum {
        scroll,
        end,
        done,
    },
} = .{
    .x = 0,
    .y = 0,
    .state = .done,
},
// A cross origin wrapper for this window
_cross_origin_wrapper: CrossOriginWindow,

// The Window that called window.open to create this one. Null for the root
// window, for noopener popups, and cleared if the opener is torn down while
// we're still alive. Only valid if `!_opener.?._closed`.
_opener: ?*Window = null,

// True after window.close. The Frame itself stays alive (parked in
// page.closed_frames until Page.deinit) so cached references to this Window
// don't dangle, but the popup is neutered: dropped from page.popups, its
// transfers aborted, scheduler reset, and unreachable for events / name lookup.
_closed: bool = false,

// Popup name (owned by page.arena)
_name: []const u8 = "",

pub fn getHighlights(self: *Window, frame: *Frame) !*HighlightRegistry {
    if (self._css_highlights) |highlights| {
        return highlights;
    }
    const highlights = try HighlightRegistry.init(frame);
    highlights.acquireRef();
    self._css_highlights = highlights;
    return highlights;
}

pub fn asEventTarget(self: *Window) *EventTarget {
    return self._proto;
}

pub fn getEvent(self: *const Window) ?*Event {
    return self._current_event;
}

pub fn setEvent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "event");
}

pub fn getSelf(self: *Window) *Window {
    return self;
}

pub fn getWindow(self: *Window) *Window {
    return self;
}

pub fn getOpener(self: *Window, frame: *Frame) ?Access {
    const opener = self._opener orelse return null;
    if (opener._closed) return null;
    return Access.init(frame.window, opener);
}

// Per the HTML spec's opener setter: null disowns the opener (the accessor
// stays in place and the getter now returns null); any other value redefines
// the property as an own data property, like [Replaceable].
pub fn setOpener(self: *Window, value: js.Value) void {
    if (value.isNull()) {
        self._opener = null;
        return;
    }
    self.replaceGlobalProperty(value, "opener");
}

pub fn getClosed(self: *const Window) bool {
    return self._closed;
}

pub fn getName(self: *const Window) []const u8 {
    return self._name;
}

pub fn setName(self: *Window, name: []const u8, frame: *Frame) !void {
    // Store in the Page's frame arena so the slice outlives any call_arena.
    self._name = try frame.arena.dupe(u8, name);
}

pub fn getTop(self: *Window, frame: *Frame) Access {
    var p = self._frame;
    while (p.parent) |parent| {
        p = parent;
    }
    return Access.init(frame.window, p.window);
}

pub fn getParent(self: *Window, frame: *Frame) Access {
    if (self._frame.parent) |p| {
        return Access.init(frame.window, p.window);
    }
    return .{ .window = self };
}

pub fn getDocument(self: *Window) *Document {
    return self._document;
}

pub fn getConsole(self: *Window) *Console {
    return &self._console;
}

pub fn setConsole(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "console");
}

pub fn setSelf(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "self");
}

pub fn setFrames(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "frames");
}

pub fn setParent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "parent");
}

pub fn setLength(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "length");
}

pub fn setInnerWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerWidth");
}

pub fn setInnerHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerHeight");
}

pub fn setOuterWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "outerWidth");
}

pub fn setOuterHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "outerHeight");
}

pub fn setScreenX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenX");
}

pub fn setScreenY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenY");
}

pub fn setScreenLeft(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenLeft");
}

pub fn setScreenTop(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenTop");
}

pub fn setScrollX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollX");
}

pub fn setScrollY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollY");
}

pub fn setPageXOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageXOffset");
}

pub fn setPageYOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageYOffset");
}

// Chrome exposes this on Window only (measured: undefined in a worker).
pub fn getSpeechSynthesis(self: *Window, exec: *Execution) !*SpeechSynthesis {
    if (self._speech_synthesis) |synthesis| {
        return synthesis;
    }
    const synthesis = try exec._factory.eventTarget(SpeechSynthesis{ ._proto = undefined });
    self._speech_synthesis = synthesis;
    return synthesis;
}

pub fn getNavigator(self: *Window) *Navigator {
    return &self._navigator;
}

pub fn getScheduler(self: *Window) *scheduler.Scheduler {
    return &self._scheduler;
}

pub fn getModelContext(self: *Window) *ModelContext {
    return &self._model_context;
}

pub fn getScreen(self: *Window) *Screen {
    return self._screen;
}

pub fn setScreen(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screen");
}

pub fn getVisualViewport(self: *const Window) *VisualViewport {
    return self._visual_viewport;
}

pub fn setVisualViewport(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "visualViewport");
}

pub fn getCrypto(self: *Window) *Crypto {
    return &self._crypto;
}

pub fn getCSS(self: *Window) *CSS {
    return &self._css;
}

pub fn getPerformance(self: *Window) *Performance {
    return &self._performance;
}

// window.chrome. Assembled on first read and cached, so it keeps its identity
// across reads the way Chrome's does. Chrome exposes it as a data property
// rather than an accessor; the bridge has no way to install one whose value is
// built at runtime, so the descriptor is the one visible difference.
pub fn getChrome(_: *Window, exec: *const js.Execution) !js.Object {
    return Chrome.build(exec);
}

pub fn setPerformance(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "performance");
}

fn bucketForOrigin(self: *Window) *storage.Bucket {
    return self._frame._session.storage_shed.getOrPut(
        self._frame._session.browser.app.allocator,
        self._frame.js.origin.key,
    ) catch @panic("OOM");
}

pub fn getLocalStorage(self: *Window) *storage.Lookup {
    return &self.bucketForOrigin().local;
}

pub fn getSessionStorage(self: *Window) *storage.Lookup {
    return &self.bucketForOrigin().session;
}

pub fn getCookieStore(self: *Window, exec: *Execution) !*CookieStore {
    if (self._cookie_store) |cs| return cs;
    const cs = try exec._factory.eventTarget(CookieStore{ ._proto = undefined });
    try cs.attach(exec);
    self._cookie_store = cs;
    return cs;
}

pub fn getIndexedDB(self: *Window, exec: *Execution) !*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    const f = try exec._factory.create(idb.IDBFactory{});
    self._idb_factory = f;
    return f;
}

pub fn getOrigin(self: *const Window) []const u8 {
    return self._frame.origin orelse "null";
}

pub fn setOrigin(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "origin");
}

// A potentially-trustworthy origin: https/wss, file, or a loopback host. On a
// headed Chrome 150 over http://localhost this answers true, which is what
// unlocks the secure-context-only APIs the rest of the surface advertises.
// The determination lives on the frame because an about:blank child inherits
// its creator's answer rather than deriving one from its own URL, and because
// the [SecureContext] global gate reads the same bit.
pub fn getIsSecureContext(self: *const Window) bool {
    return self._frame.secure_context;
}

// COOP+COEP cross-origin isolation, which nothing here negotiates, so the
// SharedArrayBuffer/high-resolution-timer gate stays shut. False on the
// reference Chrome for an ordinary page too (measured).
pub fn getCrossOriginIsolated(_: *const Window) bool {
    return false;
}

// True on the reference Chrome 150 (measured) -- Blink defaults a page with no
// Origin-Agent-Cluster header to an origin-keyed agent cluster.
pub fn getOriginAgentCluster(_: *const Window) bool {
    return true;
}

// Only an anonymous iframe (<iframe credentialless>) reports true.
pub fn getCredentialless(_: *const Window) bool {
    return false;
}

pub fn getLocationbar(self: *Window) *BarProp {
    return &self._locationbar;
}

pub fn getMenubar(self: *Window) *BarProp {
    return &self._menubar;
}

pub fn getPersonalbar(self: *Window) *BarProp {
    return &self._personalbar;
}

pub fn getScrollbars(self: *Window) *BarProp {
    return &self._scrollbars;
}

pub fn getStatusbar(self: *Window) *BarProp {
    return &self._statusbar;
}

pub fn getToolbar(self: *Window) *BarProp {
    return &self._toolbar;
}

pub fn getExternal(self: *Window) *External {
    return &self._external;
}

pub fn getTrustedTypes(self: *Window) *trusted_types.TrustedTypePolicyFactory {
    return &self._trusted_types;
}

pub fn getLaunchQueue(self: *Window) *launch_queue.LaunchQueue {
    return &self._launch_queue;
}

pub fn getCaches(self: *Window) *cache_storage.CacheStorage {
    return &self._caches;
}

pub fn setScheduler(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scheduler");
}

pub fn getStyleMedia(self: *Window) *StyleMedia {
    return &self._style_media;
}

pub fn getCrashReport(self: *Window) *reporting.CrashReportContext {
    return &self._crash_report;
}

pub fn getViewport(self: *Window) *Viewport {
    return &self._viewport;
}

// [Replaceable]: assigning shadows the accessor with a data property on the
// global rather than throwing or being ignored.
pub fn setViewport(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "viewport");
}

pub fn getStatus(self: *const Window) []const u8 {
    return self._status;
}

pub fn setStatus(self: *Window, value: []const u8, frame: *Frame) !void {
    self._status = try frame.dupeString(value);
}

// Vestigial: Blink kept the attribute after the double-buffering it described
// stopped being a thing. It reports true and takes a write without effect.
pub fn getOffscreenBuffering(_: *const Window) bool {
    return true;
}

// devicePixelRatio is a fixed part of the device profile the rest of the engine
// is built around -- MediaQuery.zig resolves resolution queries against the
// same 1920x1080-at-1 display, and screen.width/height agree with it. The
// reference machine's Chrome reports 2 because its panel is Retina; the number
// here describes the display we claim, not the one running the build.
pub fn getDevicePixelRatio(_: *const Window) u32 {
    return 1;
}

// [Replaceable]: assigning to any of these shadows the accessor with a plain
// data property on the global, rather than throwing or being ignored.
pub fn setLocationbar(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "locationbar");
}

pub fn setMenubar(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "menubar");
}

pub fn setPersonalbar(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "personalbar");
}

pub fn setScrollbars(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollbars");
}

pub fn setStatusbar(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "statusbar");
}

pub fn setToolbar(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "toolbar");
}

pub fn setExternal(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "external");
}

pub fn setClientInformation(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "clientInformation");
}

pub fn setOffscreenBuffering(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "offscreenBuffering");
}

pub fn setDevicePixelRatio(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "devicePixelRatio");
}

pub fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

pub fn getFrameElement(self: *const Window) ?*Element.Html.IFrame {
    return self._frame.iframe;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn setLocation(self: *Window, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._frame });
}

pub fn getHistory(_: *Window, frame: *Frame) *History {
    return &frame._session.history;
}

pub fn getNavigation(_: *Window, frame: *Frame) *Navigation {
    return frame._session.navigation;
}

pub fn setNavigation(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "navigation");
}

pub fn getCustomElements(self: *Window) *CustomElementRegistry {
    return &self._custom_elements;
}

// Stored in the frame's attribute-listener map (like element and ShadowRoot
// property handlers), which the dispatch propagation path consults for any
// event target.
pub fn getOnClick(self: *Window) ?js.Function.Global {
    return self._frame.getEventHandler(self.asEventTarget(), .onclick);
}

pub fn setOnClick(self: *Window, setter: ?FunctionSetter) !void {
    return self._frame.setEventHandler(self.asEventTarget(), .onclick, getFunctionFromSetter(setter));
}

// The "window-reflecting body element event handler set" (HTML spec): these
// event handlers of body and frameset elements are aliases for the Window's.
// Twenty-two of them, measured on a headed Chrome 150 (probe-g20k) --
// `document.body.onunload = f` makes `window.onunload === f`, and clearing
// either clears both. The two gamepad handlers HTMLBodyElement also carries
// are *not* in the set: they are element-local.
pub const WINDOW_REFLECTING = [_]global_event_handlers.Handler{
    .onblur,               .onerror,      .onfocus,            .onload,
    .onresize,             .onscroll,     .onafterprint,       .onbeforeprint,
    .onbeforeunload,       .onhashchange, .onlanguagechange,   .onmessage,
    .onmessageerror,       .onoffline,    .ononline,           .onpagehide,
    .onpageshow,           .onpopstate,   .onrejectionhandled, .onstorage,
    .onunhandledrejection, .onunload,
};

/// Read the Window slot a body/frameset handler alias points at.
pub fn getReflectedHandler(self: *Window, handler: global_event_handlers.Handler) ?js.Function.Global {
    return self._frame.getEventHandler(self.asEventTarget(), handler);
}

/// Write it. Passing null clears, which is what `window.onX = null` does too.
pub fn setReflectedHandler(self: *Window, handler: global_event_handlers.Handler, callback: ?js.Function.Global) !void {
    return self._frame.setEventHandler(self.asEventTarget(), handler, callback);
}

fn windowReflectingHandler(name: lp.String) ?global_event_handlers.Handler {
    const handler = global_event_handlers.fromEventType(name.str()[2..]) orelse return null;
    for (WINDOW_REFLECTING) |candidate| {
        if (candidate == handler) return handler;
    }
    return null;
}

// Applies a window-reflecting content attribute (set on a body or frameset
// element) to the Window's event handler. A null value clears the handler.
pub fn setWindowReflectingHandlerFromAttribute(self: *Window, name: lp.String, value: ?[]const u8, frame: *Frame) void {
    if (name.len < 3) return;
    const handler = windowReflectingHandler(name) orelse return;
    const func: ?js.Function.Global = blk: {
        const expr = value orelse break :blk null;
        break :blk frame.js.stringToPersistedFunction(expr, &.{"event"}, &.{}) catch |err| {
            log.err(.js, "window reflecting handler", .{ .err = err, .str = expr });
            break :blk null;
        };
    };
    self.setReflectedHandler(handler, func) catch |err| {
        log.err(.js, "window reflecting handler", .{ .err = err, .str = name.str() });
    };
}

pub fn fetch(_: *const Window, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const js.Execution) !js.Promise {
    return Fetch.init(input, options, exec);
}

pub fn setTimeout(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []js.Value.Global, exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .name = "window.setTimeout",
    });
}

pub fn setInterval(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []js.Value.Global, exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .name = "window.setInterval",
    });
}

pub fn setImmediate(self: *Window, cb: js.Function.Global, params: []js.Value.Global, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 0, .{
        .repeat = false,
        .params = params,
        .name = "window.setImmediate",
    });
}

pub fn requestAnimationFrame(self: *Window, cb: js.Function.Global, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "window.requestAnimationFrame",
    });
}

pub fn queueMicrotask(_: *Window, cb: js.Function, frame: *Frame) void {
    frame.js.queueMicrotaskFunc(cb);
}

pub fn clearTimeout(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearInterval(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearImmediate(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn cancelAnimationFrame(self: *Window, id: u32) void {
    self._timers.clear(id);
}

const RequestIdleCallbackOpts = struct {
    timeout: ?u32 = null,
};
pub fn requestIdleCallback(self: *Window, cb: js.Function.Global, opts_: ?RequestIdleCallbackOpts, exec: *js.Execution) !u32 {
    const opts = opts_ orelse RequestIdleCallbackOpts{};
    return self._timers.schedule(exec, cb, opts.timeout orelse 50, .{
        .mode = .idle,
        .repeat = false,
        .params = &.{},
        .blocks_done = false,
        .name = "window.requestIdleCallback",
    });
}

pub fn cancelIdleCallback(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn reportError(self: *Window, err: js.Value, frame: *Frame) !void {
    // Per spec's "in error reporting mode": an exception thrown while an
    // error is being reported (e.g. by an "error" listener) is not reported
    // again, which would otherwise recurse without bound.
    if (self._reporting_error) {
        return;
    }

    frame._page.recordJsError(error.JsException);

    const target = self.asEventTarget();
    // Upstream reads a `_on_error` field here. This fork keeps `onerror` in the
    // event manager's handler store rather than on Window, and
    // hasDirectListeners(null) falls through to the listener list, which is the
    // same question being asked.
    if (!frame._event_manager.hasDirectListeners(target, "error", null)) {
        if (comptime lp.IS_TEST == false) {
            log.warn(.js, "window.reportError", .{
                .message = err.toStringSlice() catch "Unknown error",
            });
        }
        return;
    }

    self._reporting_error = true;
    defer self._reporting_error = false;

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, frame._page);

    const event = error_event.asEvent();
    event.acquireRef();
    defer event.releaseRef(frame._page);

    // `window.onerror` is a listener like any other now, and runs in the place
    // it was set. Its two peculiarities -- five arguments instead of the event,
    // and `return true` cancelling -- are applied by the listener itself, which
    // is the only place that knows an ErrorEvent is reaching a Window's
    // onerror (EventManagerBase.Listener.run).
    try frame._event_manager.dispatchDirect(target, event, null, .{
        .context = "window.reportError",
        .run_microtasks = false,
    });

    if (comptime lp.IS_TEST == false) {
        if (!event._prevent_default) {
            log.warn(.js, "window.reportError", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn matchMedia(_: *const Window, query: []const u8, frame: *Frame) !*MediaQueryList {
    return frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try frame.dupeString(query),
    });
}

pub fn getComputedStyle(_: *const Window, element: *Element, pseudo_element: ?[]const u8, frame: *Frame) !*CSSStyleDeclaration {
    // :before/:after get their own cache entry and no warning: our answer
    // (the element's own computed style) is a reasonable default for the
    // common probes
    const pseudo = Element.PseudoElement.parse(pseudo_element orelse "");
    const gop = try frame._element_computed_styles.getOrPut(frame.arena, .{ .element = element, .pseudo = pseudo });
    if (!gop.found_existing) {
        if (pseudo == .other) {
            log.warn(.not_implemented, "window.GetComputedStyle", .{ .pseudo_element = pseudo_element.? });
        }
        gop.value_ptr.* = try CSSStyleDeclaration.init(element, true, frame);
    }
    return gop.value_ptr.*;
}

// window.open(url?, target?, features?) — v1 scope:
//   * Always creates a new popup Frame on the Page (sibling to the root).
//   * Honors `noopener` / `noreferrer` tokens in `features` (opener=null,
//     return value=null). Geometry (width, height, ...) ignored.
//   * `target` values `_self` / `_parent` / `_top` navigate the current frame.
//     Any other value is treated as a popup name; reusing a live name
//     navigates the existing popup instead of spawning a new one.
//   * `url` empty or missing opens about:blank.
pub fn open(self: *Window, url_: ?[]const u8, target_: ?[]const u8, features_: ?[]const u8, frame: *Frame) !?Access {
    const raw_url = url_ orelse "";
    const target = target_ orelse "";
    const features = features_ orelse "";

    const no_opener = hasFeatureToken(features, "noopener") or hasFeatureToken(features, "noreferrer");

    if (raw_url.len > 0) {
        // Per spec, we should validate the url
        _ = URL.resolve(frame.call_arena, frame.base(), raw_url, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.SyntaxError,
        };
    }

    // _self / _parent / _top navigate the current browsing context.
    if (std.ascii.eqlIgnoreCase(target, "_self") or
        std.ascii.eqlIgnoreCase(target, "_parent") or
        std.ascii.eqlIgnoreCase(target, "_top"))
    {
        const nav_target = frame.resolveTargetFrame(target) orelse frame;
        const nav_url = if (raw_url.len == 0) "about:blank" else raw_url;
        try frame.scheduleNavigation(nav_url, .{
            .reason = .script,
            .kind = .{ .push = null },
        }, .{ .script = nav_target });

        if (no_opener) {
            return null;
        }

        return Access.init(frame.window, nav_target.window);
    }

    const page = frame._page;

    // Name-based reuse: if a popup with this name already exists, reuse it.
    // `_blank` is reserved and never reuses.
    const is_named = target.len > 0 and !std.ascii.eqlIgnoreCase(target, "_blank");
    if (is_named) {
        if (page.findPopupByName(target)) |existing| {
            if (raw_url.len > 0) {
                try existing.scheduleNavigation(raw_url, .{
                    .reason = .script,
                    .kind = .{ .push = null },
                }, .{ .script = existing });
            }
            if (no_opener) {
                return null;
            }
            return Access.init(frame.window, existing.window);
        }
    }

    // Spawn a new popup Frame as a sibling of the root.
    const popup = try frame.openPopup(.{
        .url = raw_url,
        .name = target,
        .opener = if (no_opener) null else self,
    });

    if (no_opener) {
        return null;
    }
    return Access.init(frame.window, popup.window);
}

pub fn close(self: *Window) void {
    if (self._closed) {
        return;
    }

    // Per spec, close() is only honored on script-opened windows. That
    // maps exactly to membership in page.popups.
    const frame = self._frame;
    const page = frame._page;

    var popup_index: usize = 0;
    while (popup_index < page.popups.items.len) : (popup_index += 1) {
        if (page.popups.items[popup_index] == frame) {
            break;
        }
    } else return;

    self._closed = true;

    // Any live Window holding us as its opener must drop the reference —
    // our Frame is about to go away, and a stale _frame deref on their
    // side would crash.
    for (page.popups.items) |popup| {
        if (popup.window._opener == self) {
            popup.window._opener = null;
        }
    }
    if (page.frame.window._opener == self) {
        page.frame.window._opener = null;
    }

    _ = page.popups.swapRemove(popup_index);

    // Drop any pending queued navigation for this frame.
    if (frame._queued_navigation != null) {
        for (page.queued_navigation.items, 0..) |f, i| {
            if (f == frame) {
                _ = page.queued_navigation.swapRemove(i);
                break;
            }
        }
    }

    page.session.idb.detachContext(frame.js);
    frame.js.scheduler.reset();
    frame.abortTransfers();

    // Do not teardown the frame. The Window can still be referenced in JS
    // (window.open(...) returns the window). It would be nice to be able to
    // free this now (just like it would be nice to be more pro-active about
    // freeing workers and iframes), but, for now, we don't have the
    // infrastructure to do this safely so doing it on page tear down is our
    // only option.
    page.closed_frames.append(page.frame_arena, frame) catch @panic("OOM");
}

pub fn focus(_: *Window) void {}
pub fn blur(_: *Window) void {}

// window.find(): Chrome's non-standard "did the browser's find-in-page match
// anything" hook. Nothing here runs a text search, and Chrome itself answers
// false whenever the string isn't on the page, so false it is.
pub fn find(_: *Window, _: ?[]const u8) bool {
    return false;
}

// No printer, no window manager. Each of these is a no-op that Chrome also
// treats as advisory: a page opened by script may resize itself, an ordinary
// tab silently ignores moveTo/resizeTo.
pub fn print(_: *Window) void {}
pub fn stop(_: *Window) void {}
pub fn moveBy(_: *Window, _: f64, _: f64) void {}
pub fn moveTo(_: *Window, _: f64, _: f64) void {}
pub fn resizeBy(_: *Window, _: f64, _: f64) void {}
pub fn resizeTo(_: *Window, _: f64, _: f64) void {}

// Netscape-era event capture. Blink keeps both names as no-ops.
pub fn captureEvents(_: *Window) void {}
pub fn releaseEvents(_: *Window) void {}

// Three APIs that Chrome gates behind a user gesture or a permission prompt.
// A page that just calls them -- which is what a fingerprinting script does --
// gets a rejected promise, so these reproduce the rejections rather than the
// feature. All three messages were measured on a headed Chrome 150.
fn rejectWith(
    comptime name: []const u8,
    error_name: []const u8,
    message: []const u8,
    frame: *Frame,
) js.Promise {
    const resolver = frame.js.local.?.createPromiseResolver();
    resolver.reject("Window." ++ name, DOMException.init(message, error_name));
    return resolver.promise();
}

fn filePicker(comptime name: []const u8, frame: *Frame) js.Promise {
    return rejectWith(
        name,
        "SecurityError",
        "Failed to execute '" ++ name ++ "' on 'Window': " ++
            "Must be handling a user gesture to show a file picker.",
        frame,
    );
}

pub fn showOpenFilePicker(_: *Window, _: ?js.Value, frame: *Frame) js.Promise {
    return filePicker("showOpenFilePicker", frame);
}

pub fn showSaveFilePicker(_: *Window, _: ?js.Value, frame: *Frame) js.Promise {
    return filePicker("showSaveFilePicker", frame);
}

pub fn showDirectoryPicker(_: *Window, _: ?js.Value, frame: *Frame) js.Promise {
    return filePicker("showDirectoryPicker", frame);
}

// Window Management: asking for the permission needs a transient activation,
// so the request never even reaches the prompt.
pub fn getScreenDetails(_: *Window, frame: *Frame) js.Promise {
    return rejectWith(
        "getScreenDetails",
        "NotAllowedError",
        "Transient activation is required to request permission.",
        frame,
    );
}

// Local Font Access, same story with a shorter message.
pub fn queryLocalFonts(_: *Window, _: ?js.Value, frame: *Frame) js.Promise {
    return rejectWith("queryLocalFonts", "SecurityError", "User activation is required.", frame);
}

pub fn postMessage(self: *Window, message: js.Value, target_origin: ?[]const u8, transfer: ?[]const *MessagePort, frame: *Frame) !void {
    // For now, we ignore targetOrigin checking and just dispatch the message
    // In a full implementation, we would validate the origin
    _ = target_origin;

    const target_frame = self._frame;
    const source_window = target_frame.js.getIncumbent().window;

    const arena = try target_frame.getArena(.medium, "Window.postMessage");
    errdefer arena.release();

    // StructuredSerialize runs synchronously (per spec): clone the message into
    // the target window's realm now. The receiver gets a fresh, independent copy
    // minted in its own realm (not the source realm's object), an unserializable
    // value throws a DataCloneError to the caller, and the source-realm temp
    // doesn't leak into the destination context. Mirrors Worker.postMessage.
    const cloned = blk: {
        var ls: js.Local.Scope = undefined;
        target_frame.js.localScope(&ls);
        defer ls.deinit();

        // Contain any V8 exception from a failed serialization so it surfaces as
        // a clean DataCloneError; deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const c = message.structuredCloneTo(&ls.local) catch {
            return error.DataClone;
        };
        break :blk try c.persist();
    };
    errdefer cloned.release();

    // Origin should be the source window's origin (where the message came from)
    const origin = try source_window._location.getOrigin(&frame.js.execution);
    const callback = try arena.create(PostMessageCallback);
    callback.* = .{
        .arena = arena,
        .message = cloned,
        .frame = target_frame,
        .source = source_window,
        .origin = try arena.dupe(u8, origin),
        .ports = if (transfer) |t| try arena.dupe(*MessagePort, t) else &.{},
    };

    try target_frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "postMessage",
        .finalizer = PostMessageCallback.cancelled,
    });
}

const base64 = @import("encoding/base64.zig");
pub fn btoa(_: *const Window, input: base64.BinInput, frame: *Frame) ![]const u8 {
    return base64.encode(frame.local_arena, input);
}

pub fn atob(_: *const Window, input: base64.BinInput, frame: *Frame) !js.String.OneByte {
    const decoded = try base64.decode(frame.local_arena, input);
    return .{ .bytes = decoded };
}

pub fn structuredClone(_: *const Window, value: js.Value) !js.Value {
    // the serializer already threw (e.g. a DataCloneError); keep it
    return value.structuredClone() catch error.TryCatchRethrow;
}

pub fn getFrame(self: *Window, idx: usize) !?*Window {
    const frame = self._frame;
    const frames = frame.child_frames.items;
    if (idx >= frames.len) {
        return null;
    }

    if (frame.child_frames_sorted == false) {
        std.mem.sort(*Frame, frames, {}, struct {
            fn lessThan(_: void, a: *Frame, b: *Frame) bool {
                const iframe_a = a.iframe orelse return false;
                const iframe_b = b.iframe orelse return true;

                const pos = iframe_a.asNode().compareDocumentPosition(iframe_b.asNode());
                // Return true if a precedes b (a should come before b in sorted order)
                return (pos & 0x04) != 0; // FOLLOWING bit: b follows a
            }
        }.lessThan);
        frame.child_frames_sorted = true;
    }
    return frames[idx].window;
}

pub fn getFramesLength(self: *const Window) u32 {
    return @intCast(self._frame.child_frames.items.len);
}

pub fn getScrollX(self: *const Window) u32 {
    return self._scroll_pos.x;
}

pub fn getScrollY(self: *const Window) u32 {
    return self._scroll_pos.y;
}

pub fn getInnerWidth(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().width;
}

// Faux-layout viewport height, used to decide whether an element is already
// within view (e.g. scrollIntoViewIfNeeded).
pub fn getInnerHeight(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().height;
}

// The viewport is the whole screen here, so the window box is the viewport and
// the window sits at the origin. Real browsers always answer these; scripts
// read them bare (`outerWidth`, not `window.outerWidth`), so leaving them out
// turns a fingerprinting probe into a ReferenceError that kills its caller.
pub fn getOuterWidth(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().width;
}

pub fn getOuterHeight(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().height;
}

pub fn getScreenX(_: *const Window) u32 {
    return 0;
}

pub fn getScreenY(_: *const Window) u32 {
    return 0;
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        top: i32,
        left: i32,
        behavior: []const u8 = "",
    };
};
pub fn scrollTo(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const new_x: u32, const new_y: u32 = switch (opts) {
        .x => |x| .{ @intCast(@max(x, 0)), @intCast(@max(0, y orelse 0)) },
        .opts => |o| .{ @intCast(@max(0, o.left)), @intCast(@max(0, o.top)) },
    };

    if (new_x == self._scroll_pos.x and new_y == self._scroll_pos.y) {
        return;
    }

    self._scroll_pos.x = new_x;
    self._scroll_pos.y = new_y;
    self._scroll_pos.state = .scroll;

    // We dispatch scroll event asynchronously after 10ms. So we can throttle
    // them.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // If the state isn't scroll, we can ignore safely to throttle
                // the events.
                if (pos.state != .scroll) {
                    return null;
                }

                const event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .end;

                return null;
            }
        }.dispatch,
        10,
        .{ .blocks_done = false },
    );
    // We dispatch scrollend event asynchronously after 20ms.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // Dispatch only if the state is .end.
                // If a scroll is pending, retry in 10ms.
                // If the state is .end, the event has been dispatched, so
                // ignore safely.
                switch (pos.state) {
                    .scroll => return 10,
                    .end => {},
                    .done => return null,
                }
                const event = try Event.initTrusted(comptime .wrap("scrollend"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .done;

                return null;
            }
        }.dispatch,
        20,
        .{ .blocks_done = false },
    );
}

pub fn scrollBy(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    // The scroll is relative to the current position. So compute to new
    // absolute position.
    var absx: i32 = undefined;
    var absy: i32 = undefined;
    switch (opts) {
        .x => |x| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + x;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + (y orelse 0);
        },
        .opts => |o| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + o.left;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + o.top;
        },
    }
    return self.scrollTo(.{ .x = absx }, absy, frame);
}

// only exposed when the binary is built with the -Dwpt_extensions flag
pub fn getWebDriver(_: *const Window) @import("WebDriver.zig") {
    return .{};
}

pub fn unhandledPromiseRejection(self: *Window, no_handler: bool, rejection: js.PromiseRejection, frame: *Frame) !void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "window",
            .value = rejection.reason(),
            .stack = rejection.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name = if (no_handler) "unhandledrejection" else "rejectionhandled";

    if (no_handler) {
        frame._page.recordJsError(error.JsException);
    }

    const target = self.asEventTarget();
    if (frame._event_manager.hasDirectListeners(target, event_name, null)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (rejection.reason()) |r| try r.persist() else null,
            .promise = try rejection.promise().persist(),
        }, frame._page)).asEvent();
        try frame._event_manager.dispatchDirect(target, event, null, .{ .context = "window.unhandledrejection" });
    }
}

// Some properties are readonly but [Replaceable]. They get assigned as own
// data properties on the underlying v8::object that represents the global (the
// Window)
fn replaceGlobalProperty(self: *Window, value: js.Value, comptime name: []const u8) void {
    const global = self._frame.js.globalObject(value.local);
    _ = global.defineOwnProperty(name, value, 0);
}

pub const Access = union(enum) {
    window: *Window,
    cross_origin: *CrossOriginWindow,

    pub fn init(callee: *Window, accessing: *Window) Access {
        if (callee == accessing) {
            // common enough that it's worth the check
            return .{ .window = accessing };
        }

        if (callee._frame.js.origin == accessing._frame.js.origin) {
            // two different windows, but same origin, return the full window
            return .{ .window = accessing };
        }

        return .{ .cross_origin = &accessing._cross_origin_wrapper };
    }
};

const PostMessageCallback = struct {
    frame: *Frame,
    source: *Window,
    arena: *lp.Arena,
    origin: []const u8,
    message: js.Value.Global,
    ports: []const *MessagePort,

    fn deinit(self: *PostMessageCallback) void {
        self.arena.release();
    }

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const frame = self.frame;
        const window = frame.window;

        const event_target = window.asEventTarget();

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; if there are no listeners, release it here so it doesn't leak.
        if (!frame._event_manager.hasDirectListeners(event_target, "message", null)) {
            self.message.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.message },
            .origin = self.origin,
            .source = .{ .window = self.source },
            .ports = self.ports,
            .bubbles = false,
            .cancelable = false,
        }, frame._page)).asEvent();
        try frame._event_manager.dispatchDirect(event_target, event, null, .{ .context = "window.postMessage" });

        return null;
    }
};

pub const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

// window.onload = {}; doesn't fail, but it doesn't do anything.
// seems like setting to null is ok (though, at least on Firefix, it preserves
// the original value, which we could do, but why?)
pub fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func, // Already a Global from bridge auto-conversion
        .anything => null,
    };
}

// Checks whether a window.open features string contains a token, matched
// case-insensitively on whole-token boundaries (comma or whitespace separated).
// The features syntax is legacy and loose; the only tokens we interpret are
// noopener and noreferrer.
fn hasFeatureToken(features: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, features, " \t\r\n,");
    while (it.next()) |raw| {
        // Trim a trailing =value if present — we only need the key.
        const key = if (std.mem.indexOfScalarPos(u8, raw, 0, '=')) |eq| raw[0..eq] else raw;
        if (std.ascii.eqlIgnoreCase(key, token)) return true;
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Window);

    pub const Meta = struct {
        pub const name = "Window";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Getter/setter pair for an event handler property backed by the frame's
    // attribute-listener store -- the same mechanism Element uses, keyed on
    // the Window's own EventTarget.
    fn handlerAccessor(comptime handler: global_event_handlers.Handler) type {
        return struct {
            // `win`, not `self`: JsApi declares a `self` member (window.self)
            // and a parameter of that name would shadow it.
            pub fn get(win: *Window) ?js.Function.Global {
                return win._frame.getEventHandler(win.asEventTarget(), handler);
            }

            pub fn set(win: *Window, setter: ?FunctionSetter) !void {
                return win._frame.setEventHandler(win.asEventTarget(), handler, getFunctionFromSetter(setter));
            }
        };
    }

    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = .{ .internal = 1 }, .deletable = false });
    pub const console = bridge.accessor(Window.getConsole, Window.setConsole, .{});

    pub const top = bridge.accessor(Window.getTop, null, .{});
    pub const self = bridge.accessor(Window.getWindow, Window.setSelf, .{});
    pub const window = bridge.accessor(Window.getWindow, null, .{});
    pub const parent = bridge.accessor(Window.getParent, Window.setParent, .{});
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const speechSynthesis = bridge.accessor(Window.getSpeechSynthesis, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, Window.setScreen, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, Window.setVisualViewport, .{});
    pub const performance = bridge.accessor(Window.getPerformance, Window.setPerformance, .{});
    pub const chrome = bridge.accessor(Window.getChrome, null, .{ .cache = .{ .internal = 2 } });
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const cookieStore = bridge.accessor(Window.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(Window.getIndexedDB, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, Window.setOrigin, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false });
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, Window.setNavigation, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
    pub const CSS = bridge.accessor(Window.getCSS, null, .{});
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{});
    // Every event handler [Global] Window declares, in the order a headed
    // Chrome 150 lists them under Object.getOwnPropertyNames(window). Blink
    // emits them per IDL interface -- the Window-specific ones first, then
    // GlobalEventHandlers, then the pointer/animation/transition mixins, then
    // WindowEventHandlers -- so this block is deliberately not alphabetical.
    // All of them share the handler store on the event manager, which the
    // propagation path consults for any event target; none has a dedicated
    // field any more.
    pub const onsearch = bridge.accessor(handlerAccessor(.onsearch).get, handlerAccessor(.onsearch).set, .{});
    pub const onappinstalled = bridge.accessor(handlerAccessor(.onappinstalled).get, handlerAccessor(.onappinstalled).set, .{});
    pub const onbeforeinstallprompt = bridge.accessor(handlerAccessor(.onbeforeinstallprompt).get, handlerAccessor(.onbeforeinstallprompt).set, .{});
    pub const onabort = bridge.accessor(handlerAccessor(.onabort).get, handlerAccessor(.onabort).set, .{});
    pub const onbeforeinput = bridge.accessor(handlerAccessor(.onbeforeinput).get, handlerAccessor(.onbeforeinput).set, .{});
    pub const onbeforematch = bridge.accessor(handlerAccessor(.onbeforematch).get, handlerAccessor(.onbeforematch).set, .{});
    pub const onbeforetoggle = bridge.accessor(handlerAccessor(.onbeforetoggle).get, handlerAccessor(.onbeforetoggle).set, .{});
    pub const onblur = bridge.accessor(handlerAccessor(.onblur).get, handlerAccessor(.onblur).set, .{});
    pub const oncancel = bridge.accessor(handlerAccessor(.oncancel).get, handlerAccessor(.oncancel).set, .{});
    pub const oncanplay = bridge.accessor(handlerAccessor(.oncanplay).get, handlerAccessor(.oncanplay).set, .{});
    pub const oncanplaythrough = bridge.accessor(handlerAccessor(.oncanplaythrough).get, handlerAccessor(.oncanplaythrough).set, .{});
    pub const onchange = bridge.accessor(handlerAccessor(.onchange).get, handlerAccessor(.onchange).set, .{});
    pub const onclick = bridge.accessor(Window.getOnClick, Window.setOnClick, .{});
    pub const onclose = bridge.accessor(handlerAccessor(.onclose).get, handlerAccessor(.onclose).set, .{});
    pub const oncommand = bridge.accessor(handlerAccessor(.oncommand).get, handlerAccessor(.oncommand).set, .{});
    pub const oncontentvisibilityautostatechange = bridge.accessor(handlerAccessor(.oncontentvisibilityautostatechange).get, handlerAccessor(.oncontentvisibilityautostatechange).set, .{});
    pub const oncontextlost = bridge.accessor(handlerAccessor(.oncontextlost).get, handlerAccessor(.oncontextlost).set, .{});
    pub const oncontextmenu = bridge.accessor(handlerAccessor(.oncontextmenu).get, handlerAccessor(.oncontextmenu).set, .{});
    pub const oncontextrestored = bridge.accessor(handlerAccessor(.oncontextrestored).get, handlerAccessor(.oncontextrestored).set, .{});
    pub const oncuechange = bridge.accessor(handlerAccessor(.oncuechange).get, handlerAccessor(.oncuechange).set, .{});
    pub const ondblclick = bridge.accessor(handlerAccessor(.ondblclick).get, handlerAccessor(.ondblclick).set, .{});
    pub const ondrag = bridge.accessor(handlerAccessor(.ondrag).get, handlerAccessor(.ondrag).set, .{});
    pub const ondragend = bridge.accessor(handlerAccessor(.ondragend).get, handlerAccessor(.ondragend).set, .{});
    pub const ondragenter = bridge.accessor(handlerAccessor(.ondragenter).get, handlerAccessor(.ondragenter).set, .{});
    pub const ondragleave = bridge.accessor(handlerAccessor(.ondragleave).get, handlerAccessor(.ondragleave).set, .{});
    pub const ondragover = bridge.accessor(handlerAccessor(.ondragover).get, handlerAccessor(.ondragover).set, .{});
    pub const ondragstart = bridge.accessor(handlerAccessor(.ondragstart).get, handlerAccessor(.ondragstart).set, .{});
    pub const ondrop = bridge.accessor(handlerAccessor(.ondrop).get, handlerAccessor(.ondrop).set, .{});
    pub const ondurationchange = bridge.accessor(handlerAccessor(.ondurationchange).get, handlerAccessor(.ondurationchange).set, .{});
    pub const onemptied = bridge.accessor(handlerAccessor(.onemptied).get, handlerAccessor(.onemptied).set, .{});
    pub const onended = bridge.accessor(handlerAccessor(.onended).get, handlerAccessor(.onended).set, .{});
    pub const onerror = bridge.accessor(handlerAccessor(.onerror).get, handlerAccessor(.onerror).set, .{});
    pub const onfocus = bridge.accessor(handlerAccessor(.onfocus).get, handlerAccessor(.onfocus).set, .{});
    pub const onformdata = bridge.accessor(handlerAccessor(.onformdata).get, handlerAccessor(.onformdata).set, .{});
    pub const oninput = bridge.accessor(handlerAccessor(.oninput).get, handlerAccessor(.oninput).set, .{});
    pub const oninvalid = bridge.accessor(handlerAccessor(.oninvalid).get, handlerAccessor(.oninvalid).set, .{});
    pub const onkeydown = bridge.accessor(handlerAccessor(.onkeydown).get, handlerAccessor(.onkeydown).set, .{});
    pub const onkeypress = bridge.accessor(handlerAccessor(.onkeypress).get, handlerAccessor(.onkeypress).set, .{});
    pub const onkeyup = bridge.accessor(handlerAccessor(.onkeyup).get, handlerAccessor(.onkeyup).set, .{});
    pub const onload = bridge.accessor(handlerAccessor(.onload).get, handlerAccessor(.onload).set, .{});
    pub const onloadeddata = bridge.accessor(handlerAccessor(.onloadeddata).get, handlerAccessor(.onloadeddata).set, .{});
    pub const onloadedmetadata = bridge.accessor(handlerAccessor(.onloadedmetadata).get, handlerAccessor(.onloadedmetadata).set, .{});
    pub const onloadstart = bridge.accessor(handlerAccessor(.onloadstart).get, handlerAccessor(.onloadstart).set, .{});
    pub const onmousedown = bridge.accessor(handlerAccessor(.onmousedown).get, handlerAccessor(.onmousedown).set, .{});
    pub const onmouseenter = bridge.accessor(handlerAccessor(.onmouseenter).get, handlerAccessor(.onmouseenter).set, .{});
    pub const onmouseleave = bridge.accessor(handlerAccessor(.onmouseleave).get, handlerAccessor(.onmouseleave).set, .{});
    pub const onmousemove = bridge.accessor(handlerAccessor(.onmousemove).get, handlerAccessor(.onmousemove).set, .{});
    pub const onmouseout = bridge.accessor(handlerAccessor(.onmouseout).get, handlerAccessor(.onmouseout).set, .{});
    pub const onmouseover = bridge.accessor(handlerAccessor(.onmouseover).get, handlerAccessor(.onmouseover).set, .{});
    pub const onmouseup = bridge.accessor(handlerAccessor(.onmouseup).get, handlerAccessor(.onmouseup).set, .{});
    pub const onmousewheel = bridge.accessor(handlerAccessor(.onmousewheel).get, handlerAccessor(.onmousewheel).set, .{});
    pub const onpause = bridge.accessor(handlerAccessor(.onpause).get, handlerAccessor(.onpause).set, .{});
    pub const onplay = bridge.accessor(handlerAccessor(.onplay).get, handlerAccessor(.onplay).set, .{});
    pub const onplaying = bridge.accessor(handlerAccessor(.onplaying).get, handlerAccessor(.onplaying).set, .{});
    pub const onprogress = bridge.accessor(handlerAccessor(.onprogress).get, handlerAccessor(.onprogress).set, .{});
    pub const onratechange = bridge.accessor(handlerAccessor(.onratechange).get, handlerAccessor(.onratechange).set, .{});
    pub const onreset = bridge.accessor(handlerAccessor(.onreset).get, handlerAccessor(.onreset).set, .{});
    pub const onresize = bridge.accessor(handlerAccessor(.onresize).get, handlerAccessor(.onresize).set, .{});
    pub const onscroll = bridge.accessor(handlerAccessor(.onscroll).get, handlerAccessor(.onscroll).set, .{});
    pub const onscrollend = bridge.accessor(handlerAccessor(.onscrollend).get, handlerAccessor(.onscrollend).set, .{});
    pub const onsecuritypolicyviolation = bridge.accessor(handlerAccessor(.onsecuritypolicyviolation).get, handlerAccessor(.onsecuritypolicyviolation).set, .{});
    pub const onseeked = bridge.accessor(handlerAccessor(.onseeked).get, handlerAccessor(.onseeked).set, .{});
    pub const onseeking = bridge.accessor(handlerAccessor(.onseeking).get, handlerAccessor(.onseeking).set, .{});
    pub const onselect = bridge.accessor(handlerAccessor(.onselect).get, handlerAccessor(.onselect).set, .{});
    pub const onslotchange = bridge.accessor(handlerAccessor(.onslotchange).get, handlerAccessor(.onslotchange).set, .{});
    pub const onstalled = bridge.accessor(handlerAccessor(.onstalled).get, handlerAccessor(.onstalled).set, .{});
    pub const onsubmit = bridge.accessor(handlerAccessor(.onsubmit).get, handlerAccessor(.onsubmit).set, .{});
    pub const onsuspend = bridge.accessor(handlerAccessor(.onsuspend).get, handlerAccessor(.onsuspend).set, .{});
    pub const ontimeupdate = bridge.accessor(handlerAccessor(.ontimeupdate).get, handlerAccessor(.ontimeupdate).set, .{});
    pub const ontoggle = bridge.accessor(handlerAccessor(.ontoggle).get, handlerAccessor(.ontoggle).set, .{});
    pub const onvolumechange = bridge.accessor(handlerAccessor(.onvolumechange).get, handlerAccessor(.onvolumechange).set, .{});
    pub const onwaiting = bridge.accessor(handlerAccessor(.onwaiting).get, handlerAccessor(.onwaiting).set, .{});
    pub const onwebkitanimationend = bridge.accessor(handlerAccessor(.onwebkitanimationend).get, handlerAccessor(.onwebkitanimationend).set, .{});
    pub const onwebkitanimationiteration = bridge.accessor(handlerAccessor(.onwebkitanimationiteration).get, handlerAccessor(.onwebkitanimationiteration).set, .{});
    pub const onwebkitanimationstart = bridge.accessor(handlerAccessor(.onwebkitanimationstart).get, handlerAccessor(.onwebkitanimationstart).set, .{});
    pub const onwebkittransitionend = bridge.accessor(handlerAccessor(.onwebkittransitionend).get, handlerAccessor(.onwebkittransitionend).set, .{});
    pub const onwheel = bridge.accessor(handlerAccessor(.onwheel).get, handlerAccessor(.onwheel).set, .{});
    pub const onauxclick = bridge.accessor(handlerAccessor(.onauxclick).get, handlerAccessor(.onauxclick).set, .{});
    pub const ongotpointercapture = bridge.accessor(handlerAccessor(.ongotpointercapture).get, handlerAccessor(.ongotpointercapture).set, .{});
    pub const onlostpointercapture = bridge.accessor(handlerAccessor(.onlostpointercapture).get, handlerAccessor(.onlostpointercapture).set, .{});
    pub const onpointerdown = bridge.accessor(handlerAccessor(.onpointerdown).get, handlerAccessor(.onpointerdown).set, .{});
    pub const onpointermove = bridge.accessor(handlerAccessor(.onpointermove).get, handlerAccessor(.onpointermove).set, .{});
    pub const onpointerup = bridge.accessor(handlerAccessor(.onpointerup).get, handlerAccessor(.onpointerup).set, .{});
    pub const onpointercancel = bridge.accessor(handlerAccessor(.onpointercancel).get, handlerAccessor(.onpointercancel).set, .{});
    pub const onpointerover = bridge.accessor(handlerAccessor(.onpointerover).get, handlerAccessor(.onpointerover).set, .{});
    pub const onpointerout = bridge.accessor(handlerAccessor(.onpointerout).get, handlerAccessor(.onpointerout).set, .{});
    pub const onpointerenter = bridge.accessor(handlerAccessor(.onpointerenter).get, handlerAccessor(.onpointerenter).set, .{});
    pub const onpointerleave = bridge.accessor(handlerAccessor(.onpointerleave).get, handlerAccessor(.onpointerleave).set, .{});
    pub const onselectstart = bridge.accessor(handlerAccessor(.onselectstart).get, handlerAccessor(.onselectstart).set, .{});
    pub const onselectionchange = bridge.accessor(handlerAccessor(.onselectionchange).get, handlerAccessor(.onselectionchange).set, .{});
    pub const onanimationcancel = bridge.accessor(handlerAccessor(.onanimationcancel).get, handlerAccessor(.onanimationcancel).set, .{});
    pub const onanimationend = bridge.accessor(handlerAccessor(.onanimationend).get, handlerAccessor(.onanimationend).set, .{});
    pub const onanimationiteration = bridge.accessor(handlerAccessor(.onanimationiteration).get, handlerAccessor(.onanimationiteration).set, .{});
    pub const onanimationstart = bridge.accessor(handlerAccessor(.onanimationstart).get, handlerAccessor(.onanimationstart).set, .{});
    pub const ontransitionrun = bridge.accessor(handlerAccessor(.ontransitionrun).get, handlerAccessor(.ontransitionrun).set, .{});
    pub const ontransitionstart = bridge.accessor(handlerAccessor(.ontransitionstart).get, handlerAccessor(.ontransitionstart).set, .{});
    pub const ontransitionend = bridge.accessor(handlerAccessor(.ontransitionend).get, handlerAccessor(.ontransitionend).set, .{});
    pub const ontransitioncancel = bridge.accessor(handlerAccessor(.ontransitioncancel).get, handlerAccessor(.ontransitioncancel).set, .{});
    pub const onbeforexrselect = bridge.accessor(handlerAccessor(.onbeforexrselect).get, handlerAccessor(.onbeforexrselect).set, .{});
    pub const onafterprint = bridge.accessor(handlerAccessor(.onafterprint).get, handlerAccessor(.onafterprint).set, .{});
    pub const onbeforeprint = bridge.accessor(handlerAccessor(.onbeforeprint).get, handlerAccessor(.onbeforeprint).set, .{});
    pub const onbeforeunload = bridge.accessor(handlerAccessor(.onbeforeunload).get, handlerAccessor(.onbeforeunload).set, .{});
    pub const onhashchange = bridge.accessor(handlerAccessor(.onhashchange).get, handlerAccessor(.onhashchange).set, .{});
    pub const onlanguagechange = bridge.accessor(handlerAccessor(.onlanguagechange).get, handlerAccessor(.onlanguagechange).set, .{});
    pub const onmessage = bridge.accessor(handlerAccessor(.onmessage).get, handlerAccessor(.onmessage).set, .{});
    pub const onmessageerror = bridge.accessor(handlerAccessor(.onmessageerror).get, handlerAccessor(.onmessageerror).set, .{});
    pub const onoffline = bridge.accessor(handlerAccessor(.onoffline).get, handlerAccessor(.onoffline).set, .{});
    pub const ononline = bridge.accessor(handlerAccessor(.ononline).get, handlerAccessor(.ononline).set, .{});
    pub const onpagehide = bridge.accessor(handlerAccessor(.onpagehide).get, handlerAccessor(.onpagehide).set, .{});
    pub const onpageshow = bridge.accessor(handlerAccessor(.onpageshow).get, handlerAccessor(.onpageshow).set, .{});
    pub const onpopstate = bridge.accessor(handlerAccessor(.onpopstate).get, handlerAccessor(.onpopstate).set, .{});
    pub const onrejectionhandled = bridge.accessor(handlerAccessor(.onrejectionhandled).get, handlerAccessor(.onrejectionhandled).set, .{});
    pub const onstorage = bridge.accessor(handlerAccessor(.onstorage).get, handlerAccessor(.onstorage).set, .{});
    pub const onunhandledrejection = bridge.accessor(handlerAccessor(.onunhandledrejection).get, handlerAccessor(.onunhandledrejection).set, .{});
    pub const onunload = bridge.accessor(handlerAccessor(.onunload).get, handlerAccessor(.onunload).set, .{});
    pub const ondevicemotion = bridge.accessor(handlerAccessor(.ondevicemotion).get, handlerAccessor(.ondevicemotion).set, .{});
    pub const ondeviceorientation = bridge.accessor(handlerAccessor(.ondeviceorientation).get, handlerAccessor(.ondeviceorientation).set, .{});
    pub const ondeviceorientationabsolute = bridge.accessor(handlerAccessor(.ondeviceorientationabsolute).get, handlerAccessor(.ondeviceorientationabsolute).set, .{});
    pub const onpointerrawupdate = bridge.accessor(handlerAccessor(.onpointerrawupdate).get, handlerAccessor(.onpointerrawupdate).set, .{});
    pub const onpageswap = bridge.accessor(handlerAccessor(.onpageswap).get, handlerAccessor(.onpageswap).set, .{});
    pub const onpagereveal = bridge.accessor(handlerAccessor(.onpagereveal).get, handlerAccessor(.onpagereveal).set, .{});
    pub const onscrollsnapchange = bridge.accessor(handlerAccessor(.onscrollsnapchange).get, handlerAccessor(.onscrollsnapchange).set, .{});
    pub const onscrollsnapchanging = bridge.accessor(handlerAccessor(.onscrollsnapchanging).get, handlerAccessor(.onscrollsnapchanging).set, .{});
    pub const ongamepadconnected = bridge.accessor(handlerAccessor(.ongamepadconnected).get, handlerAccessor(.ongamepadconnected).set, .{});
    pub const ongamepaddisconnected = bridge.accessor(handlerAccessor(.ongamepaddisconnected).get, handlerAccessor(.ongamepaddisconnected).set, .{});
    pub const event = bridge.accessor(Window.getEvent, Window.setEvent, .{ .null_as_undefined = true });
    pub const fetch = bridge.function(Window.fetch, .{});
    pub const queueMicrotask = bridge.function(Window.queueMicrotask, .{});
    pub const setTimeout = bridge.function(Window.setTimeout, .{});
    pub const clearTimeout = bridge.function(Window.clearTimeout, .{});
    pub const setInterval = bridge.function(Window.setInterval, .{});
    pub const clearInterval = bridge.function(Window.clearInterval, .{});
    pub const requestAnimationFrame = bridge.function(Window.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(Window.cancelAnimationFrame, .{});
    pub const requestIdleCallback = bridge.function(Window.requestIdleCallback, .{});
    pub const cancelIdleCallback = bridge.function(Window.cancelIdleCallback, .{});
    pub const matchMedia = bridge.function(Window.matchMedia, .{});
    pub const postMessage = bridge.function(Window.postMessage, .{});
    pub const btoa = bridge.function(Window.btoa, .{});
    pub const atob = bridge.function(Window.atob, .{});
    pub const reportError = bridge.function(Window.reportError, .{});
    pub const structuredClone = bridge.function(Window.structuredClone, .{});
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
    pub const getSelection = bridge.function(Window.getSelection, .{});
    pub const frameElement = bridge.accessor(Window.getFrameElement, null, .{});

    pub const frames = bridge.accessor(Window.getWindow, Window.setFrames, .{});
    pub const index = bridge.indexed(Window.getFrame, null, .{ .null_as_undefined = true });
    pub const length = bridge.accessor(Window.getFramesLength, Window.setLength, .{});
    pub const scrollX = bridge.accessor(Window.getScrollX, Window.setScrollX, .{});
    pub const scrollY = bridge.accessor(Window.getScrollY, Window.setScrollY, .{});
    pub const pageXOffset = bridge.accessor(Window.getScrollX, Window.setPageXOffset, .{});
    pub const pageYOffset = bridge.accessor(Window.getScrollY, Window.setPageYOffset, .{});
    pub const scrollTo = bridge.function(Window.scrollTo, .{});
    pub const scroll = bridge.function(Window.scrollTo, .{});
    pub const scrollBy = bridge.function(Window.scrollBy, .{});

    // These four are accessors rather than bridge.property values on purpose:
    // only accessors and functions get mirrored onto the global object by the
    // [Global] flattening pass, and Chrome has all four as own properties of
    // `window`, not inherited from Window.prototype (measured).
    pub const isSecureContext = bridge.accessor(Window.getIsSecureContext, null, .{});
    pub const crossOriginIsolated = bridge.accessor(Window.getCrossOriginIsolated, null, .{});
    pub const originAgentCluster = bridge.accessor(Window.getOriginAgentCluster, null, .{});
    pub const credentialless = bridge.accessor(Window.getCredentialless, null, .{});

    // The six BarProp objects, in Chrome's own order. Each is get+set: the
    // setter is the [Replaceable] one every legacy Window attribute carries.
    pub const locationbar = bridge.accessor(Window.getLocationbar, Window.setLocationbar, .{});
    pub const menubar = bridge.accessor(Window.getMenubar, Window.setMenubar, .{});
    pub const personalbar = bridge.accessor(Window.getPersonalbar, Window.setPersonalbar, .{});
    pub const scrollbars = bridge.accessor(Window.getScrollbars, Window.setScrollbars, .{});
    pub const statusbar = bridge.accessor(Window.getStatusbar, Window.setStatusbar, .{});
    pub const toolbar = bridge.accessor(Window.getToolbar, Window.setToolbar, .{});

    pub const status = bridge.accessor(Window.getStatus, Window.setStatus, .{});
    pub const external = bridge.accessor(Window.getExternal, Window.setExternal, .{});
    // Getter-only, and the one window attribute Blink marks non-enumerable.
    pub const styleMedia = bridge.accessor(Window.getStyleMedia, null, .{});
    pub const trustedTypes = bridge.accessor(Window.getTrustedTypes, null, .{});
    // Enumerable, getter-only, and never replaceable: Chrome has no setter here.
    pub const crashReport = bridge.accessor(Window.getCrashReport, null, .{});
    pub const viewport = bridge.accessor(Window.getViewport, Window.setViewport, .{});
    pub const offscreenBuffering = bridge.accessor(Window.getOffscreenBuffering, Window.setOffscreenBuffering, .{ .enumerable = false });
    // navigator's other name, and the same object.
    pub const clientInformation = bridge.accessor(Window.getNavigator, Window.setClientInformation, .{});

    pub const find = bridge.function(Window.find, .{});
    pub const print = bridge.function(Window.print, .{});
    pub const stop = bridge.function(Window.stop, .{});
    pub const moveBy = bridge.function(Window.moveBy, .{});
    pub const moveTo = bridge.function(Window.moveTo, .{});
    pub const resizeBy = bridge.function(Window.resizeBy, .{});
    pub const resizeTo = bridge.function(Window.resizeTo, .{});
    pub const captureEvents = bridge.function(Window.captureEvents, .{});
    pub const releaseEvents = bridge.function(Window.releaseEvents, .{});
    // Separate function objects from their unprefixed twins, the way Chrome
    // has them (measured: webkitRequestAnimationFrame !== requestAnimationFrame,
    // while webkitURL === URL).
    pub const webkitRequestAnimationFrame = bridge.function(Window.requestAnimationFrame, .{});
    pub const webkitCancelAnimationFrame = bridge.function(Window.cancelAnimationFrame, .{});

    // The sandboxed filesystem entry points. Unlike an interface object these
    // read back enumerable on the global ("ecw"), which is what a plain Window
    // operation looks like -- see filesystem.zig for why they are here at all.
    pub const webkitRequestFileSystem = bridge.function(filesystem.requestFileSystem, .{ .arity = 3 });
    pub const webkitResolveLocalFileSystemURL = bridge.function(filesystem.resolveLocalFileSystemURL, .{ .arity = 2 });
    // Chrome carries the two quota constants on Window.prototype, where they are
    // the only members besides `constructor` (measured). This engine's Window
    // members are own properties of the global instead -- an engine-wide
    // difference, not one introduced here -- so they land there with it.
    pub const TEMPORARY = bridge.property(0, .{ .template = true });
    pub const PERSISTENT = bridge.property(1, .{ .template = true });

    pub const createImageBitmap = bridge.function(struct {
        fn createImageBitmap(
            _: *Window,
            source: ?js.Value,
            sx: ?js.Value,
            sy: ?js.Value,
            sw: ?js.Value,
            sh: ?js.Value,
            exec: *const Execution,
        ) !js.Promise {
            return ImageBitmap.create(source, sx, sy, sw, sh, exec);
        }
    }.createImageBitmap, .{ .arity = 1 });

    // Gated APIs: each one exists and each one rejects. See the functions.
    pub const queryLocalFonts = bridge.function(Window.queryLocalFonts, .{});
    pub const showDirectoryPicker = bridge.function(Window.showDirectoryPicker, .{});
    pub const showOpenFilePicker = bridge.function(Window.showOpenFilePicker, .{});
    pub const showSaveFilePicker = bridge.function(Window.showSaveFilePicker, .{});
    pub const getScreenDetails = bridge.function(Window.getScreenDetails, .{});
    pub const launchQueue = bridge.accessor(Window.getLaunchQueue, null, .{});
    pub const caches = bridge.accessor(Window.getCaches, null, .{});
    // [Replaceable], unlike launchQueue and caches (measured).
    pub const scheduler = bridge.accessor(Window.getScheduler, Window.setScheduler, .{});

    // [Replaceable] (CSSOM-View): the getter reads the page's runtime viewport
    // (overridable via Emulation.setDeviceMetricsOverride); the setter overwrites
    // the attribute rather than throwing.
    pub const innerWidth = bridge.accessor(Window.getInnerWidth, Window.setInnerWidth, .{});
    pub const innerHeight = bridge.accessor(Window.getInnerHeight, Window.setInnerHeight, .{});
    pub const outerWidth = bridge.accessor(Window.getOuterWidth, Window.setOuterWidth, .{});
    pub const outerHeight = bridge.accessor(Window.getOuterHeight, Window.setOuterHeight, .{});
    pub const screenX = bridge.accessor(Window.getScreenX, Window.setScreenX, .{});
    pub const screenY = bridge.accessor(Window.getScreenY, Window.setScreenY, .{});
    // screenLeft/screenTop are the legacy aliases of screenX/screenY.
    pub const screenLeft = bridge.accessor(Window.getScreenX, Window.setScreenLeft, .{});
    pub const screenTop = bridge.accessor(Window.getScreenY, Window.setScreenTop, .{});
    pub const devicePixelRatio = bridge.accessor(Window.getDevicePixelRatio, Window.setDevicePixelRatio, .{});

    pub const opener = bridge.accessor(Window.getOpener, Window.setOpener, .{});
    pub const closed = bridge.accessor(Window.getClosed, null, .{});
    pub const name = bridge.accessor(Window.getName, Window.setName, .{});
    pub const open = bridge.function(Window.open, .{});
    pub const close = bridge.function(Window.close, .{});
    pub const focus = bridge.function(Window.focus, .{});
    pub const blur = bridge.function(Window.blur, .{});

    pub const alert = bridge.function(struct {
        fn alert(_: *const Window, message: ?[]const u8, frame: *Frame) void {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "alert",
                .response = &response,
            });
            // Return value is void; we still pop a pre-armed response so the
            // CDP client's pre-arm doesn't leak across to the next dialog.
        }
    }.alert, .{});
    pub const confirm = bridge.function(struct {
        fn confirm(_: *const Window, message: ?[]const u8, frame: *Frame) bool {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "confirm",
                .response = &response,
            });
            return response.accept;
        }
    }.confirm, .{});
    pub const prompt = bridge.function(struct {
        fn prompt(_: *const Window, message: ?[]const u8, default_text: ?[]const u8, frame: *Frame) ?[]const u8 {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "prompt",
                .response = &response,
            });
            if (!response.accept) return null;
            // Pre-armed promptText wins when present. Otherwise fall back to
            // the dialog's defaultText (second arg to window.prompt) — Chrome's
            // accept-without-typing behavior. If both are absent, return ""
            // per CDP spec
            // (https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-handleJavaScriptDialog).
            return response.prompt_text orelse default_text orelse "";
        }
    }.prompt, .{});

    pub const webdriver = bridge.accessor(Window.getWebDriver, null, .{ .wpt_only = true });
};

const CrossOriginWindow = struct {
    window: *Window,

    pub fn postMessage(self: *CrossOriginWindow, message: js.Value, target_origin: ?[]const u8, transfer: ?[]const *MessagePort, frame: *Frame) !void {
        return self.window.postMessage(message, target_origin, transfer, frame);
    }

    pub fn getTop(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    pub fn getParent(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    pub fn getFramesLength(self: *const CrossOriginWindow) u32 {
        return self.window.getFramesLength();
    }

    pub fn getWindow(self: *CrossOriginWindow, frame: *Frame) Access {
        return Access.init(frame.window, self.window);
    }

    pub fn getOpener(self: *CrossOriginWindow, frame: *Frame) ?Access {
        return self.window.getOpener(frame);
    }

    pub fn getClosed(self: *const CrossOriginWindow) bool {
        return self.window.getClosed();
    }

    pub fn close(self: *CrossOriginWindow) void {
        self.window.close();
    }

    pub fn focus(self: *CrossOriginWindow) void {
        self.window.focus();
    }

    pub fn blur(self: *CrossOriginWindow) void {
        self.window.blur();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginWindow);

        pub const Meta = struct {
            pub const name = "CrossOriginWindow";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const postMessage = bridge.function(CrossOriginWindow.postMessage, .{});
        pub const close = bridge.function(CrossOriginWindow.close, .{});
        pub const focus = bridge.function(CrossOriginWindow.focus, .{});
        pub const blur = bridge.function(CrossOriginWindow.blur, .{});
        pub const window = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const self = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const frames = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const top = bridge.accessor(CrossOriginWindow.getTop, null, .{});
        pub const parent = bridge.accessor(CrossOriginWindow.getParent, null, .{});
        pub const opener = bridge.accessor(CrossOriginWindow.getOpener, null, .{});
        pub const closed = bridge.accessor(CrossOriginWindow.getClosed, null, .{});
        pub const length = bridge.accessor(CrossOriginWindow.getFramesLength, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}

test "WebApi: Window scroll" {
    try testing.htmlRunner("window_scroll.html", .{});
}

test "WebApi: Window.onerror" {
    try testing.htmlRunner("event/report_error.html", .{});
}
