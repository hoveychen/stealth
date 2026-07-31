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

// window.chrome.
//
// Every Chrome and Chromium build — headless included — puts this object on the
// window, and it is the single cheapest "is this really Chrome" probe there is:
// bot.sannysoft.com's "Chrome (New)" row is a bare `!!window.chrome`. A browser
// that sends a Chrome user-agent and Sec-Ch-Ua brands without it is
// contradicting itself.
//
// Unlike everything else in webapi/, window.chrome is *not* a platform object.
// It is an ordinary JS object: its prototype is Object.prototype, its
// constructor is Object, Object.prototype.toString gives "[object Object]", and
// app/csi/loadTimes are enumerable, configurable, writable own properties whose
// values happen to be native functions. All of that was measured on Chrome 150
// (see the shape recorded in tools/fingerprint/README.md), and a platform
// object cannot reproduce it: the bridge puts members on the prototype, leaving
// getOwnPropertyNames(chrome) empty and leaking the Zig type name through
// chrome.constructor.name.
//
// So the object is assembled by hand: js.Local.newObject() for the two plain
// objects, and js.Local.newCallback() for the functions. newCallback builds a
// bare v8::Function with no FunctionTemplate behind it, which is what makes
// these callable on a plain receiver *and* keeps toString() reporting
// "[native code]" — a function compiled from a source string would print its
// body.

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

// Assembles window.chrome. The caller caches the result, so this runs once per
// context and the object keeps its identity.
//
// Two things still differ from Chrome, neither of them reachable without
// asking for it specifically: window.chrome is an accessor here rather than a
// non-configurable data property (the bridge can't install a data property
// whose value is built at runtime), and the chrome.app functions report
// name === "" where Chrome names them — newCallback creates anonymous
// functions. Chrome's own csi and loadTimes are anonymous too.
pub fn build(exec: *const Execution) !js.Object {
    const local = exec.js.local.?;

    // Property order is Chrome's own: getOwnPropertyNames reports
    // loadTimes, csi, app.
    const chrome = local.newObject();
    try define(chrome, "loadTimes", local.newCallback(loadTimes, &api));
    try define(chrome, "csi", local.newCallback(csi, &api));

    const app = local.newObject();
    try define(app, "isInstalled", false);
    try define(app, "getDetails", local.newCallback(getDetails, &api));
    try define(app, "getIsInstalled", local.newCallback(getIsInstalled, &api));
    try define(app, "installState", local.newCallback(installState, &api));
    try define(app, "runningState", local.newCallback(runningState, &api));
    try define(app, "InstallState", InstallState{});
    try define(app, "RunningState", RunningState{});

    try define(chrome, "app", app);
    return chrome;
}

// Chrome's own properties here are all enumerable, configurable and writable,
// i.e. exactly what an ordinary assignment produces.
fn define(target: js.Object, comptime name: []const u8, value: anytype) !void {
    if (try target.set(name, value, .{}) == false) {
        return error.CreateObjectFailure;
    }
}

// The two enums chrome.app carries. Plain structs, so the bridge turns them
// into plain objects with these keys in this order.
const InstallState = struct {
    DISABLED: []const u8 = "disabled",
    INSTALLED: []const u8 = "installed",
    NOT_INSTALLED: []const u8 = "not_installed",
};

const RunningState = struct {
    CANNOT_RUN: []const u8 = "cannot_run",
    READY_TO_RUN: []const u8 = "ready_to_run",
    RUNNING: []const u8 = "running",
};

// newCallback needs a pointer to embed as the function's receiver. Nothing is
// stored on it — the per-call state all comes from the injected Frame — so one
// process-wide marker is enough.
const Api = struct { _pad: bool = false };
var api: Api = .{};

// chrome.app.getDetails() returns null unless the page *is* a Chrome app; an
// ordinary page always gets null.
fn getDetails(_: *Api) ?js.Object {
    return null;
}

fn getIsInstalled(_: *Api) bool {
    return false;
}

// Takes a callback and reports asynchronously, so the direct return value is
// undefined even in Chrome.
fn installState(_: *Api) void {}

fn runningState(_: *Api) []const u8 {
    return "cannot_run";
}

// chrome.csi(). startE and onloadT are epoch milliseconds, pageT is
// milliseconds since navigation, and tran is the transition type — 15 is what a
// normal navigation reports.
fn csi(_: *Api, frame: *Frame) Csi {
    const start_e: f64 = @floatFromInt(frame.window._performance._epoch_origin_ms);
    return .{
        .startE = start_e,
        .onloadT = if (frame.window._load_epoch_ms == 0) start_e else @floatFromInt(frame.window._load_epoch_ms),
        .pageT = frame.window._performance.now(),
        .tran = 15,
    };
}

// chrome.loadTimes(). Deprecated in Chrome but still present, and still probed.
// The timestamps are epoch *seconds* with millisecond fractions, unlike csi()'s
// milliseconds.
//
// The four connection fields are fixed at the values Chrome reports over
// HTTP/2, which is what it negotiates with any modern host. They are not read
// back from our own transfer: libcurl knows the negotiated version only after
// the response, and that isn't plumbed through to here. A peer that compared
// this claim against the protocol it actually served would see the difference
// on an HTTP/1.1 origin.
fn loadTimes(_: *Api, frame: *Frame) LoadTimes {
    const start = @as(f64, @floatFromInt(frame.window._performance._epoch_origin_ms)) / 1000.0;
    const loaded = if (frame.window._load_epoch_ms == 0)
        start
    else
        @as(f64, @floatFromInt(frame.window._load_epoch_ms)) / 1000.0;

    return .{
        .requestTime = start,
        .startLoadTime = start,
        .commitLoadTime = loaded,
        .finishDocumentLoadTime = loaded,
        .finishLoadTime = loaded,
        .firstPaintTime = loaded,
        .firstPaintAfterLoadTime = 0,
        .navigationType = "Other",
        .wasFetchedViaSpdy = true,
        .wasNpnNegotiated = true,
        .npnNegotiatedProtocol = "h2",
        .wasAlternateProtocolAvailable = false,
        .connectionInfo = "h2",
    };
}

// Field order is the key order Chrome's own objects have.
// startE/onloadT are f64 rather than i64 because the bridge maps a 64-bit
// integer to a JS BigInt, and Chrome reports plain numbers here. Epoch
// milliseconds are exact in an f64 for the next few hundred thousand years.
const Csi = struct {
    startE: f64,
    onloadT: f64,
    pageT: f64,
    tran: u8,
};

const LoadTimes = struct {
    requestTime: f64,
    startLoadTime: f64,
    commitLoadTime: f64,
    finishDocumentLoadTime: f64,
    finishLoadTime: f64,
    firstPaintTime: f64,
    firstPaintAfterLoadTime: f64,
    navigationType: []const u8,
    wasFetchedViaSpdy: bool,
    wasNpnNegotiated: bool,
    npnNegotiatedProtocol: []const u8,
    wasAlternateProtocolAvailable: bool,
    connectionInfo: []const u8,
};

const testing = @import("../../testing.zig");
test "WebApi: Chrome" {
    try testing.htmlRunner("chrome.html", .{});
}
