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
const MediaQuery = @import("../css/MediaQuery.zig");
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
_local_storage: ?storage.View = null,
_session_storage: ?storage.View = null,
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
_performance: *Performance,
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

pub fn getParent(self: *Window, frame: *Frame) ?Access {
    if (self._frame.parent) |p| {
        // A child frame whose <iframe> left the document has no parent: the
        // navigable was destroyed, and Chrome answers null there (measured,
        // `probes/expr-iframe-detach.js`). A closed popup is not this case --
        // popups have no parent frame to begin with.
        if (self._closed) {
            return null;
        }
        return Access.init(frame.window, p.window);
    }
    // A frame with no parent is its own parent -- but which *object* answers
    // that still depends on who is asking. Handing back the bare window let a
    // cross-origin child hold the top's real Window: reading anything off it
    // then hit V8's own cross-context check ("TypeError: no access"), so
    // `while (w !== w.parent) w = w.parent` -- how a script asks how deep it is
    // -- threw instead of terminating.
    return Access.init(frame.window, self);
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

// window.CSS. Not a bridge accessor: it is a WebIDL namespace object, and
// WebIDL hangs one off the global as a plain data property that does not
// enumerate. Env.zig installs it at realm setup with those attributes; this is
// where the value comes from.
pub fn getCSS(self: *Window) *CSS {
    return &self._css;
}

pub fn getPerformance(self: *Window) *Performance {
    return self._performance;
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

/// Two handles kept on the Window rather than one Lookup handed straight out:
/// the store is per-origin and shared with every same-origin frame, but the
/// `Storage` *object* is per-realm in Chrome, and the identity map keys the JS
/// wrapper on the address it is given. Handing out `&bucket.local` gave every
/// realm the same wrapper, so a patch in an iframe reached its parent.
pub fn getLocalStorage(self: *Window) *storage.View {
    if (self._local_storage == null) {
        self._local_storage = .{ ._lookup = &self.bucketForOrigin().local };
    }
    return &self._local_storage.?;
}

pub fn getSessionStorage(self: *Window) *storage.View {
    if (self._session_storage == null) {
        self._session_storage = .{ ._lookup = &self.bucketForOrigin().session };
    }
    return &self._session_storage.?;
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

// COOP+COEP cross-origin isolation, as negotiated by the response that
// committed this document -- see Frame.commitCrossOriginIsolated. False on the
// reference Chrome for an ordinary page (measured), and true on a Cloudflare
// challenge interstitial, which is served with both headers.
pub fn getCrossOriginIsolated(self: *const Window) bool {
    return self._frame.cross_origin_isolated;
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
// same number, and screen.width/height agree with it.
//
// It is 2, and what that costs is nothing: `screen.*` is reported in CSS
// pixels, so the physical panel is `screen.width * this`, and 1920x1200 at 2
// names a 3840x2400 display -- a 16:10 4K monitor, which macOS drives at
// exactly this 2x scale. Measured, not assumed: the same headless Chrome under
// `--force-device-scale-factor=1` and `=2` moves eleven readings and no others
// (tools/fingerprint/probes/expr-device-pixel-ratio-blast.js), and every one of
// them is either this number, a resolution media query, `screen.*` -- which
// halve there only because that Chrome's physical panel is fixed while ours is
// a claim -- or `img.x`/`img.y`.
//
// Why 2 rather than 1: Kasada reads this eight times on one x-hyatt load and
// then spends 314 media queries binary-searching it to twenty bits, which makes
// it the widest single reading B53 found separating this engine from the headed
// Chrome that clears the station.
pub fn getDevicePixelRatio(_: *const Window) u32 {
    return 2;
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

/// The element embedding this document, or null when the embedder is
/// cross-origin. The element belongs to the *parent's* document, so handing it
/// across the boundary would let a framed document read its embedder's
/// attributes -- and it is the one handle a frame has on the page framing it.
/// Chrome answers null there, without throwing (measured in
/// probes/expr-frame-element-cross-origin.js, and on the Turnstile widget,
/// which is challenges.cloudflare.com inside the site's own origin).
///
/// Not an `Access`-style question: the spec compares the container document to
/// *this* document, not to whoever is asking, so the answer is the same for
/// every caller.
pub fn getFrameElement(self: *const Window) ?*Element.Html.IFrame {
    const iframe = self._frame.iframe orelse return null;
    const parent = self._frame.parent orelse return null;
    if (parent.js.origin != self._frame.js.origin) {
        return null;
    }
    return iframe;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn setLocation(self: *Window, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._frame });
}

// History and Navigation are per-window in Chrome, and the objects behind
// these two live on the frame rather than on the session. One object shared by
// the whole session is also wrapped in one realm, and every frame's call to it
// then resolves against that realm's frame -- which is how a child's
// replaceState used to move its parent's URL.
pub fn getHistory(self: *Window) *History {
    return &self._frame._history;
}

pub fn getNavigation(self: *Window) *Navigation {
    return self._frame._navigation;
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

// `clearTimeout(optional unsigned long handle = 0)`: the handle is optional,
// and handle 0 never names a timer, so a bare call is a no-op rather than a
// refusal (Chrome 151 reports clearTimeout.length === 0).
pub fn clearTimeout(self: *Window, id: ?u32) void {
    self._timers.clear(id orelse return);
}

pub fn clearInterval(self: *Window, id: ?u32) void {
    self._timers.clear(id orelse return);
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

    // "Uncaught " leads every one of these in Chrome (measured on 151): an
    // exception out of a timer, one out of a script, a thrown plain string
    // ("Uncaught a plain string"), and window.reportError's own argument
    // ("Uncaught Error: explicit"). The message is user-agent-defined, so the
    // only ground truth is what Chrome writes.
    const described = err.toStringSlice() catch "Unknown error";
    const message = try std.fmt.allocPrint(frame.call_arena, "Uncaught {s}", .{described});

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = message,
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
    // `media` is the canonical form of the query, not the text handed in — see
    // the serialisation section of css/MediaQuery.zig. `matches` still reads
    // the same query either way, so the stored text is the canonical one.
    return frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try MediaQuery.serialize(frame.arena, query),
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

        const c = message.structuredCloneTo(&ls.local, null) catch {
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
const base64_messages = base64.Messages("Window");

pub fn btoa(_: *const Window, input: base64.BinInput, frame: *Frame) ![]const u8 {
    const bytes = try input.bytes(frame.local_arena, frame.js, base64_messages.btoa_not_latin1);
    return base64.encode(frame.local_arena, bytes);
}

pub fn atob(_: *const Window, input: base64.BinInput, frame: *Frame) !js.String.OneByte {
    const bytes = try input.bytes(frame.local_arena, frame.js, base64_messages.atob_not_latin1);
    const decoded = base64.decode(frame.local_arena, bytes) catch |err| switch (err) {
        error.InvalidCharacterError => return frame.js.fail(err, base64_messages.atob_not_encoded),
        else => return err,
    };
    return .{ .bytes = decoded };
}

pub fn structuredClone(_: *const Window, value: js.Value) !js.Value {
    // the serializer already threw (e.g. a DataCloneError); keep it
    return value.structuredClone("Failed to execute 'structuredClone' on 'Window': ") catch error.TryCatchRethrow;
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

// The frame's own viewport, not the page's: a child frame is laid out in its
// `<iframe>` element's box and a browser answers that box here. See
// Frame.viewport.
pub fn getInnerWidth(_: *const Window, frame: *Frame) u32 {
    return frame.viewport().width;
}

// Faux-layout viewport height, used to decide whether an element is already
// within view (e.g. scrollIntoViewIfNeeded).
pub fn getInnerHeight(_: *const Window, frame: *Frame) u32 {
    return frame.viewport().height;
}

// The window around the page: taller than the viewport by the browser drawn
// above it, and no wider. Real browsers always answer these; scripts read them
// bare (`outerWidth`, not `window.outerWidth`), so leaving them out turns a
// fingerprinting probe into a ReferenceError that kills its caller.
//
// Unlike inner*, these stay the *page's* window in a child frame: outer is the
// browser window, which a frame does not have one of. Measured on Chrome 151 --
// a 300x65 iframe's window reports the top-level window's box.
//
// See Viewport for where the 87 comes from and for the rest of the arrangement
// these have to agree with.
pub fn getOuterWidth(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().outerWidth();
}

pub fn getOuterHeight(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().outerHeight();
}

// Where the window sits on the display. Not (0, 0): a maximised window starts
// at the usable area's origin, and on a platform with a menu bar that is 33
// pixels down. Chrome answers a position no matter how the window got there --
// headless, which places its window nowhere in particular, still said (22, 22).
pub fn getScreenX(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().windowX();
}

pub fn getScreenY(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().windowY();
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        // Alphabetical: a dictionary's members are read in that order and a
        // page handing a Proxy in sees the sequence.
        behavior: []const u8 = "",
        left: i32,
        top: i32,
    };
};
// Both overloads take everything optional -- `scrollTo()` scrolls to where the
// page already is -- so Chrome 151 reports scrollTo.length === 0 and a bare call
// does nothing rather than refusing.
pub fn scrollTo(self: *Window, opts_: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const new_x: u32, const new_y: u32 = switch (opts_ orelse return) {
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

pub fn scrollBy(self: *Window, opts_: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    // The scroll is relative to the current position. So compute to new
    // absolute position.
    var absx: i32 = undefined;
    var absy: i32 = undefined;
    switch (opts_ orelse return) {
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

pub fn unhandledPromiseRejection(self: *Window, no_handler: bool, promise: js.Promise, reason: ?js.Value, frame: *Frame) !void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "window",
            .value = reason,
            .stack = promise.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name = if (no_handler) "unhandledrejection" else "rejectionhandled";

    if (no_handler) {
        frame._page.recordJsError(error.JsException);
    }

    const target = self.asEventTarget();
    if (frame._event_manager.hasDirectListeners(target, event_name, null)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (reason) |r| try r.persist() else null,
            .promise = try promise.persist(),
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
        // Web IDL [Global]: this interface's attributes and operations are own
        // properties of the global object rather than properties of the
        // interface prototype object. The annotation is per-interface -- the
        // inherited ones (WorkerGlobalScope, EventTarget) keep theirs where
        // they are.
        pub const global = true;
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

    // Web IDL [LegacyUnforgeable], same as location and document below: Chrome
    // makes these four non-configurable, so a page cannot redefine the getter
    // to watch what reads it. `self` and `parent` are Replaceable instead and
    // stay configurable.
    pub const top = bridge.accessor(Window.getTop, null, .{ .deletable = false });
    pub const self = bridge.accessor(Window.getWindow, Window.setSelf, .{});
    pub const window = bridge.accessor(Window.getWindow, null, .{ .deletable = false });
    pub const parent = bridge.accessor(Window.getParent, Window.setParent, .{});
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const speechSynthesis = bridge.accessor(Window.getSpeechSynthesis, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, Window.setScreen, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, Window.setVisualViewport, .{});
    pub const performance = bridge.accessor(Window.getPerformance, Window.setPerformance, .{});
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const cookieStore = bridge.accessor(Window.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(Window.getIndexedDB, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, Window.setOrigin, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false });
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, Window.setNavigation, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
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
    pub const index = bridge.indexedFull(Window.getFrame, setAtIndex, deleteAtIndex, queryAtIndex, defineAtIndex, getIndexes, .{ .null_as_undefined = true });

    /// Web IDL: the frame indices are own properties of `window`. Unlike a
    /// collection's *named* entries they are enumerable, so they show up in
    /// `Object.keys(window)` too -- one line of a fingerprint that could not be
    /// read here before (probes/expr-indexed-own-names.js, windowFrames).
    fn getIndexes(w: *Window, exec: *const js.Execution) !js.Array {
        const len = w.getFramesLength();
        var arr = exec.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }

    // Supported indexed properties are enumerable, configurable, read-only.
    fn queryAtIndex(w: *Window, idx: u32) !u32 {
        if (idx < w.getFramesLength()) {
            return js.v8.ReadOnly;
        }
        return error.NotHandled;
    }

    // `window`'s [[DefineOwnProperty]] refuses *every* array index, in range or
    // not, so `window[99] = x` is dropped rather than becoming an expando
    // (measured on Chrome 151; the read stays undefined afterwards).
    fn setAtIndex(_: *Window, _: u32, _: js.Value) bool {
        return false;
    }

    fn defineAtIndex(_: *Window, _: u32) bool {
        return false;
    }

    // A frame index cannot be deleted -- delete answers false, which is a
    // TypeError in strict mode. An index past the end is nothing to begin
    // with, so it follows the ordinary path and answers true.
    fn deleteAtIndex(w: *Window, idx: u32) !bool {
        if (idx < w.getFramesLength()) {
            return false;
        }
        return error.NotHandled;
    }
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

    // Reads right at every depth a two-frame test can reach -- at depth 1 the
    // parent *is* the top -- and wrong from three frames down, where the window
    // behind this proxy has a parent that is not the top.
    pub fn getTop(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getTop(frame);
    }

    pub fn getParent(self: *CrossOriginWindow, frame: *Frame) ?Access {
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

    // Every name off the WebIDL cross-origin safelist has to *throw* on read.
    // Answering undefined instead is what breaks Cloudflare's Turnstile on this
    // engine: the widget reads a denied property and calls a method on the
    // result, which is a SecurityError it is written to catch in a browser and
    // was an unhandled `TypeError: Cannot read properties of undefined (reading
    // 'call')` here -- the message naming 'call' rather than the property is the
    // giveaway that the denial one level up went silent. Measured on a headed
    // Chrome 150 (probe-cross-origin-surface): all 24 names tested throw there.
    //
    // The interceptor is [[NonMasking]], so it only runs for names the normal
    // lookup did not find -- every safelisted member, plus `then`, is an own
    // property of the proxy and resolves before this is reached -- and only for
    // strings, which leaves the three own symbols alone. So nothing a browser
    // answers arrives here, and everything that does is denied.
    //
    // The sentence matters as much as the throw. A script that catches the
    // SecurityError and reads `.message` gets one from Blink that names both
    // the property and the origin that was refused; DOMException's stock text
    // ("The operation is insecure") names neither and is a sentence no browser
    // prints for this. Measured on Chrome 151, expr-xo-proxy-detail.
    fn getDenied(_: *const CrossOriginWindow, name: []const u8, frame: *Frame) !?[]const u8 {
        return frame.js.fail(error.SecurityError, try deniedMessage(frame, "read a named property '{s}' from", name));
    }

    fn setDenied(_: *CrossOriginWindow, name: []const u8, _: js.Value, frame: *Frame) !void {
        return frame.js.fail(error.SecurityError, try deniedMessage(frame, "set a named property '{s}' on", name));
    }

    // `'document' in w` is a denial too, and Blink's sentence for it is the bare
    // one: no "Failed to ..." lead-in, because [[HasProperty]] is not a read of
    // any particular property as far as the access check is concerned. Without
    // this the `in` would fall through to the getter and answer the read
    // sentence -- right kind of exception, wrong sentence.
    fn queryDenied(_: *const CrossOriginWindow, _: []const u8, frame: *Frame) !u32 {
        return frame.js.fail(error.SecurityError, try blockedSentence(frame));
    }

    // ...while `Object.getOwnPropertyDescriptor(w, 'document')` *is* a read of a
    // named property and gets the named sentence. Without its own callback the
    // descriptor lookup would fall through to `queryDenied` above and answer the
    // bare one, which is the sentence Chrome keeps for `in`.
    fn descriptorDenied(_: *const CrossOriginWindow, name: []const u8, frame: *Frame) !?[]const u8 {
        return frame.js.fail(error.SecurityError, try deniedMessage(frame, "read a named property '{s}' from", name));
    }

    // `delete w.document` throws, and gets the bare sentence the same as `in`:
    // a delete is not a read. Measured on both engines -- Chrome and this one
    // now answer the same string, byte for byte.
    //
    // No definer alongside it: V8 runs `Object.defineProperty` through the
    // descriptor lookup first, so the define is already refused there and a
    // definer callback never sees it (measured -- adding one changed nothing).
    //
    // The deleter only sees names the proxy does not own -- it is [[NonMasking]]
    // like the rest -- so `delete w.length` still succeeds where Chrome throws.
    // Closing that needs the access check; see the note in
    // frames/cross_origin_proxy_shape.html.
    fn deleterDenied(_: *CrossOriginWindow, _: []const u8, frame: *Frame) !bool {
        return frame.js.fail(error.SecurityError, try blockedSentence(frame));
    }

    fn deniedMessage(frame: *Frame, comptime verb: []const u8, name: []const u8) ![]const u8 {
        // call_arena, not local_arena: handleError reads the message back after
        // this frame is gone, and local_arena is reset before it gets there.
        // See Document.setDomain, which learned the same thing the hard way.
        return std.fmt.allocPrint(
            frame.call_arena,
            "Failed to " ++ verb ++ " 'Window': {s}",
            .{ name, try blockedSentence(frame) },
        );
    }

    fn blockedSentence(frame: *Frame) ![]const u8 {
        const origin = frame.window._location.getOrigin(&frame.js.execution) catch "null";
        return std.fmt.allocPrint(
            frame.call_arena,
            "Blocked a frame with origin \"{s}\" from accessing a cross-origin frame.",
            .{origin},
        );
    }

    // Chrome answers a CrossOriginLocation object here -- own names `href
    // replace then`, with `href` throwing on read and `replace` callable. This
    // engine has no such object, so the read stays the `undefined` it has
    // always been: wrong, but wrong in the direction it was already wrong in,
    // and now at least the own name and its accessor pair are on the proxy. The
    // real fix is the object -- see the cross-origin section in
    // tools/fingerprint/README.md.
    fn getLocation(_: *const CrossOriginWindow) ?[]const u8 {
        return null;
    }

    // Navigating another origin's window by assigning to its `location` is the
    // one thing a cross-origin caller is allowed to *do* to it -- that is how a
    // popup opener sends its child somewhere -- so the safelist gives `location`
    // a setter where every other cross-origin attribute is getter-only
    // (measured: `Object.getOwnPropertyDescriptor(w, 'location').set` is a
    // function on Chrome 151, and it is the only one of the nine that has one).
    // The navigation belongs to the frame behind the proxy, not to the caller's.
    fn setLocation(self: *CrossOriginWindow, url: [:0]const u8, frame: *Frame) !void {
        const target = self.window._frame;
        return target.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = frame });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginWindow);

        pub const Meta = struct {
            pub const name = "CrossOriginWindow";

            // The cross-origin window proxy is not an interface of its own, so
            // Chrome names nothing on the global for it. That half is measured
            // and settled.
            pub const no_interface_object = true;

            // Everything a cross-origin caller may reach is an own property of
            // the proxy itself, and the proxy has no prototype at all --
            // measured on a headed Chrome 151 (expr-xo-proxy-detail):
            // `Object.getPrototypeOf(w)` is null, `w instanceof Object` is
            // false, and the fourteen names are all own.
            pub const own_properties = true;
            pub const null_prototype = true;

            // The brand is an own Symbol.toStringTag whose *value is undefined*
            // rather than a string, which sends Object.prototype.toString past
            // every branded tag and back to the ordinary "Object" -- Chrome
            // answers '[object Object]'. An earlier reading recorded '[object
            // Window]', but it was taken synchronously right after appendChild,
            // when the frame is still on its same-origin about:blank, so it
            // measured a same-origin window.
            pub const to_string_tag_undefined = true;

            // The tail of HTML's CrossOriginOwnPropertyKeys, in Chrome's order:
            // `then` last among the names, then the two remaining well-known
            // symbols (the brand is the first symbol and is written by
            // `to_string_tag_undefined` above, before the member loop).
            pub const undefined_own_keys = .{ "then", .has_instance, .is_concat_spreadable };

            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"[str]" = bridge.namedIndexedFull(
            CrossOriginWindow.getDenied,
            CrossOriginWindow.setDenied,
            CrossOriginWindow.deleterDenied,
            null,
            CrossOriginWindow.queryDenied,
            null,
            CrossOriginWindow.descriptorDenied,
            .{ .null_as_undefined = true },
        );

        // Declaration order is own-property order, and this is Blink's
        // CrossOriginProperties table read top to bottom: the nine attributes
        // first, then the four operations. Measured on Chrome 151
        // (expr-xo-proxy-detail): `Object.getOwnPropertyNames(w)` is exactly
        // window self location closed frames length top opener parent blur
        // close focus postMessage then.
        //
        // Every one of them is non-enumerable -- `Object.keys(w)` and a for-in
        // over the proxy are both empty on Chrome, which is the reading that
        // makes the whole set invisible to a naive enumeration and visible to
        // getOwnPropertyNames. The four operations are non-writable on top of
        // that; the nine attributes are accessor pairs, for which writability
        // is not a bit at all.
        pub const window = bridge.accessor(CrossOriginWindow.getWindow, null, .{ .enumerable = false });
        pub const self = bridge.accessor(CrossOriginWindow.getWindow, null, .{ .enumerable = false });
        // `null_as_undefined` keeps the read answering `undefined`, which is
        // what the interceptor answered before `location` became an own
        // property. Chrome answers an object; `undefined` and `null` are both
        // wrong, and only one of them is a *new* wrongness.
        pub const location = bridge.accessor(CrossOriginWindow.getLocation, CrossOriginWindow.setLocation, .{ .enumerable = false, .null_as_undefined = true });
        pub const closed = bridge.accessor(CrossOriginWindow.getClosed, null, .{ .enumerable = false });
        pub const frames = bridge.accessor(CrossOriginWindow.getWindow, null, .{ .enumerable = false });
        pub const length = bridge.accessor(CrossOriginWindow.getFramesLength, null, .{ .enumerable = false });
        pub const top = bridge.accessor(CrossOriginWindow.getTop, null, .{ .enumerable = false });
        pub const opener = bridge.accessor(CrossOriginWindow.getOpener, null, .{ .enumerable = false });
        pub const parent = bridge.accessor(CrossOriginWindow.getParent, null, .{ .enumerable = false });
        pub const blur = bridge.function(CrossOriginWindow.blur, .{ .enumerable = false, .writable = false });
        pub const close = bridge.function(CrossOriginWindow.close, .{ .enumerable = false, .writable = false });
        pub const focus = bridge.function(CrossOriginWindow.focus, .{ .enumerable = false, .writable = false });
        pub const postMessage = bridge.function(CrossOriginWindow.postMessage, .{ .enumerable = false, .writable = false });
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
