// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const js = @import("../../../browser/js/js.zig");
const Notification = @import("../../../Notification.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        runIfWaitingForDebugger,
        evaluate,
        addBinding,
        callFunctionOn,
        releaseObject,
        getProperties,
        releaseObjectGroup,
        awaitPromise,
        compileScript,
        runScript,
        queryObjects,
        globalLexicalScopeNames,
        removeBinding,
        terminateExecution,
        getExceptionDetails,
        discardConsoleEntries,
        getHeapUsage,
        getIsolateId,
        setCustomObjectFormatterEnabled,
        setMaxCallStackSizeToCapture,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .runIfWaitingForDebugger => return cmd.sendResult(null, .{}),
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        // Bookkeeping that can neither observe nor change the page's global.
        .releaseObjectGroup, .discardConsoleEntries, .getHeapUsage, .getIsolateId, .setCustomObjectFormatterEnabled, .setMaxCallStackSizeToCapture => return sendInspector(cmd),
        else => {
            const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
            bc.main_world_touched = true;
            return sendInspector(cmd);
        },
    }
}

fn enable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.runtimeEnable();
    return sendInspector(cmd);
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.runtimeDisable();
    return sendInspector(cmd);
}

fn sendInspector(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // the result to return is handled directly by the inspector.
    bc.callInspector(cmd.input.json);
}

const RemoteObject = struct {
    type: []const u8,
    subtype: ?[]const u8,
    className: ?[]const u8,
    description: ?[]const u8,
    objectId: ?[]const u8,
    value: ?js.Value,
};

const ConsoleMessage = struct {
    type: []const u8,
    executionContextId: i32,
    timestamp: u64,
    args: []RemoteObject,
};

pub fn consoleMessage(arena: Allocator, bc: *CDP.BrowserContext, event: *const Notification.ConsoleMessage) !void {
    const session_id = bc.session_id orelse return;

    // The realm that logged, not the main frame. A client reads
    // executionContextId to decide which frame a line came from, and the
    // arguments' RemoteObjects have to be minted in the realm that owns them.
    var ls: js.Local.Scope = undefined;
    event.js_context.localScope(&ls);
    defer ls.deinit();

    const context_id = bc.inspector_session.inspector.getContextId(&ls.local);

    var args: std.ArrayList(RemoteObject) = .empty;
    for (event.values) |value| {
        // A realm the inspector was never told about cannot describe its own
        // values, and the only realms it is told about are frames'
        // (`contextCreated` in page.zig and target.zig). A dedicated worker's
        // console call lands here with a context V8 does not know, and this
        // used to unwrap the resulting null and take the engine down --
        // `iphey` and `deviceinfo` are two pages whose workers log, and the
        // sweep reported both as `timeout: Runtime.evaluate` because the
        // process was gone by then.
        //
        // Dropping the message is the same thing a client sees from Chrome: a
        // dedicated worker is its own target, and a page session without
        // auto-attach is shown nothing of its console.
        const remote_object = bc.inspector_session.getRemoteObject(
            &ls.local,
            "",
            value,
        ) catch |err| switch (err) {
            // Exhaustive today, deliberately without an `else`: a new failure
            // mode out of getRemoteObject should stop compiling here rather
            // than be silently folded into "drop the message".
            error.ObjectNotWrappable => {
                lp.log.debug(.cdp, "console message dropped", .{
                    .reason = "argument belongs to a realm the inspector does not know",
                    .context_id = context_id,
                });
                return;
            },
        };
        defer remote_object.deinit();

        const @"type" = try remote_object.getType(arena);
        const subtype = try remote_object.getSubtype(arena);

        // Chrome hands the client an objectId and lets it ask for the
        // properties; it never serialises the argument into the event, and its
        // preview reports an accessor as `{"name":"g","type":"accessor"}`
        // without calling it (tools/fingerprint/console-args.mjs). Serialising
        // here means running V8's JSON::Stringify over the page's own value,
        // which invokes getters, toJSON and the Proxy traps -- so a page can
        // hand console.log an object that reports on itself and learn a
        // debugger is attached, noiselessly (tools/fingerprint/rt-tell.mjs).
        // Primitives have no user code behind them and are sent by value, which
        // is also what Chrome does.
        const by_value = std.mem.eql(u8, @"type", "string") or
            std.mem.eql(u8, @"type", "number") or
            std.mem.eql(u8, @"type", "boolean") or
            (subtype != null and std.mem.eql(u8, subtype.?, "null"));

        try args.append(arena, .{
            .type = @"type",
            .subtype = subtype,
            .className = try remote_object.getClassName(arena),
            .description = try remote_object.getDescription(arena),
            .objectId = try remote_object.getObjectId(arena),
            .value = if (by_value) value else null,
        });
    }

    return bc.cdp.sendEvent("Runtime.consoleAPICalled", ConsoleMessage{
        .type = @tagName(event.type),
        .timestamp = event.timestamp,
        .executionContextId = context_id,
        .args = args.items,
    }, .{ .session_id = session_id });
}

const testing = @import("../testing.zig");

test "cdp.runtime: inspector-handled methods pass through" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-RT", .url = "hi.html", .target_id = "FID-0000000RTP".* });
    try ctx.processMessage(.{ .id = 50, .method = "Runtime.enable" });

    try ctx.processMessage(.{ .id = 51, .method = "Runtime.releaseObjectGroup", .params = .{ .objectGroup = "handles" } });
    try ctx.expectSentResult(null, .{ .id = 51 });

    try ctx.processMessage(.{ .id = 52, .method = "Runtime.discardConsoleEntries" });
    try ctx.expectSentResult(null, .{ .id = 52 });
}

test "cdp.runtime: consoleAPICalled type matches the console method" {
    testing.silenceLog(&.{.js});

    // Wire types per the CDP protocol: console.log -> "log",
    // console.warn -> "warning" (not "warn"), console.info -> "info",
    // console.error -> "error", console.debug -> "debug".
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-CONS", .url = "hi.html", .target_id = "FID-0000000CON".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });

    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec("console.log('l'); console.warn('w'); console.info('i'); console.error('e'); console.debug('d');", null);

    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "warning" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "info" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "error" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "debug" }, .{});
}

// A host tells realms apart by executionContextId: every consoleAPICalled
// carries the id of the context that called console, which is how a log line is
// attributed to a frame without trusting the page to tag itself. Chrome 151 on a
// page with two same-origin iframes answers three distinct ids -- one per realm,
// each announced by its own Runtime.executionContextCreated naming its frame
// (tools/fingerprint/realm-context-ids.mjs). Here every realm reports the main
// frame's, because the ConsoleMessage notification does not carry the frame that
// logged and the handler reaches for bc.mainFrame().
test "cdp.runtime: consoleAPICalled names the realm that logged" {
    testing.silenceLog(&.{.js});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-CTXID", .url = "cdp/empty_iframe.html", .target_id = "FID-0000000CTX".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });

    const root = bc.mainFrame() orelse unreachable;
    try testing.expectEqual(1, root.child_frames.items.len);
    const child = root.child_frames.items[0];

    for ([_]*@TypeOf(root.*){ root, child }, [_][]const u8{ "console.log('root')", "console.log('child')" }) |frame, script| {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(script, null);
    }

    // Collect the id off every consoleAPICalled, in order.
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(std.testing.allocator);
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "Runtime.consoleAPICalled") == false) continue;
        const params = msg.object.get("params").?.object;
        try ids.append(std.testing.allocator, params.get("executionContextId").?.integer);
    }

    try testing.expectEqual(2, ids.items.len);
    if (ids.items[0] == ids.items[1]) {
        std.debug.print(
            "both realms reported executionContextId {d}; the root and the child are different realms\n",
            .{ids.items[0]},
        );
        return error.RealmsShareOneContextId;
    }
}

// Describing a console argument must never run the page's own code. Chrome
// answers an accessor with `{"name":"g","type":"accessor"}` and never calls it
// (tools/fingerprint/console-args.mjs), so a page cannot tell a debugger is
// attached by handing console.log an object that reports on itself. Serialising
// the argument instead -- JSON.stringify does invoke getters, toJSON and the
// Proxy traps -- turns every console.log into a noiseless attach oracle, which
// is exactly what Kasada reads: with Runtime enabled the guard refuses the
// telemetry POST for Chrome too.
test "cdp.runtime: consoleAPICalled describes an argument without running page code" {
    testing.silenceLog(&.{.js});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-CONSP", .url = "hi.html", .target_id = "FID-000000CONP".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });

    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.exec(
        \\globalThis.hits = 0;
        \\const getter = {};
        \\Object.defineProperty(getter, 'g', { get() { globalThis.hits++; return 1; }, enumerable: true });
        \\console.log(getter);
        \\console.log({ toJSON() { globalThis.hits++; return 'J'; } });
        \\console.log(new Proxy({ a: 1 }, {
        \\    get(t, k) { globalThis.hits++; return Reflect.get(t, k); },
        \\    ownKeys(t) { globalThis.hits++; return Reflect.ownKeys(t); },
        \\}));
    , null);

    const hits = try (try ls.local.exec("globalThis.hits", null)).toU32();
    if (hits != 0) {
        std.debug.print("describing the arguments ran page code {d} time(s)\n", .{hits});
        return error.ConsoleArgumentRanPageCode;
    }

    // The shape that lets a client see the object without the engine touching
    // it: an objectId to expand on demand, and no serialised `value`.
    var seen: usize = 0;
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "Runtime.consoleAPICalled") == false) continue;
        const args = msg.object.get("params").?.object.get("args").?.array;
        for (args.items) |a| {
            seen += 1;
            try testing.expectEqual("object", a.object.get("type").?.string);
            try testing.expectEqual(true, a.object.get("objectId") != null);
            if (a.object.get("value")) |v| {
                std.debug.print("argument carried a serialised value: {f}\n", .{std.json.fmt(v, .{})});
                return error.ConsoleArgumentSerialised;
            }
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

// A promise is an ordinary thing to log -- `console.log(fetch(url))` is a line
// people write -- and puppeteer enables Runtime the moment it attaches, so this
// path is on for any real crawler. Describing one overflowed the stack and took
// the process with it; DOM nodes, Proxies, WeakMaps and self-referential
// objects all describe fine (tools/fingerprint/console-args.mjs).
test "cdp.runtime: consoleAPICalled describes a promise argument" {
    testing.silenceLog(&.{.js});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-CONSPR", .url = "hi.html", .target_id = "FID-00000CONPR".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });

    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.exec(
        \\console.log(Promise.resolve(1));
        \\console.log(new Promise(() => {}));
        \\console.log((async () => 1)());
    , null);

    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log" }, .{});
}

// A dedicated worker's console.log crashed the engine. Its realm is never
// registered with the inspector -- `contextCreated` is called for frames only
// (page.zig, target.zig) -- so `Session::wrapObject` hands back an empty
// handle for a value from it, and Inspector.wrapObject unwrapped that with
// `.?`. Reproduced from a page whose whole content is
// `new Worker(URL.createObjectURL(new Blob(['console.log({a:1})'])))` with
// Runtime enabled: 4/4, and it predates the flex work (it crashes on either
// side of it). It cost the two detectors `iphey` and `deviceinfo`, which the
// sweep reported as `timeout: Runtime.evaluate` because by then the process
// was gone.
//
// Dropping the message is also what Chrome does with these sessions: a
// dedicated worker is its own target, and without auto-attach a page session
// sees nothing of its console at all. So this asserts silence, not a translated
// event -- and above all that the engine is still answering afterwards.
test "cdp.runtime: a worker's console.log does not take the engine with it" {
    testing.silenceLog(&.{.js});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-WC", .target_id = "TID-WC-0000000".* });
    bc.session_id = "SID-WC";
    try ctx.processMessage(.{ .id = 1, .method = "Runtime.enable" });

    const page = try bc.session.createPage();
    try page.navigate("http://127.0.0.1:9582/src/browser/tests/cdp/worker_console.html", .{});
    try testing.waitForPage(bc);

    // Nothing from the worker's realm, and nothing crashed on the way here.
    var i: usize = 0;
    var console_events: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "Runtime.consoleAPICalled")) console_events += 1;
    }
    try testing.expectEqual(0, console_events);

    // And the page realm still logs, so the drop above is about the worker's
    // realm rather than console reporting having been switched off.
    const root = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    root.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec("console.log('from the page')", null);
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log" }, .{ .session_id = "SID-WC" });
}
