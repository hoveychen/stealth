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

const js = @import("../../browser/js/js.zig");
const CDP = @import("../CDP.zig");
const Notification = @import("../../Notification.zig");

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
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .runIfWaitingForDebugger => return cmd.sendResult(null, .{}),
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        else => {
            const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
            bc.main_world_touched = true;
            return sendInspector(cmd, action);
        },
    }
}

fn enable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.runtimeEnable();
    return sendInspector(cmd, .enable);
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.runtimeDisable();
    return sendInspector(cmd, .disable);
}

fn sendInspector(cmd: *CDP.Command, action: anytype) !void {
    // save script in file at debug mode
    if (lp.IS_DEBUG) {
        try logInspector(cmd, action);
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // the result to return is handled directly by the inspector.
    bc.callInspector(cmd.input.json);
}

fn logInspector(cmd: *CDP.Command, action: anytype) !void {
    const script = switch (action) {
        .evaluate => blk: {
            const params = (try cmd.params(struct {
                expression: []const u8,
                // contextId: ?u8 = null,
                // returnByValue: ?bool = null,
                // awaitPromise: ?bool = null,
                // userGesture: ?bool = null,
            })) orelse return error.InvalidParams;

            break :blk params.expression;
        },
        .callFunctionOn => blk: {
            const params = (try cmd.params(struct {
                functionDeclaration: []const u8,
                // objectId: ?[]const u8 = null,
                // executionContextId: ?u8 = null,
                // arguments: ?[]struct {
                //     value: ?[]const u8 = null,
                //     objectId: ?[]const u8 = null,
                // } = null,
                // returnByValue: ?bool = null,
                // awaitPromise: ?bool = null,
                // userGesture: ?bool = null,
            })) orelse return error.InvalidParams;

            break :blk params.functionDeclaration;
        },
        else => return,
    };
    const id = cmd.input.id orelse return error.RequiredId;
    const name = try std.fmt.allocPrint(cmd.arena, "id_{d}.js", .{id});

    try std.Io.Dir.cwd().createDirPath(lp.io, ".zig-cache/tmp");
    var dir = try std.Io.Dir.cwd().openDir(lp.io, ".zig-cache/tmp", .{});
    defer dir.close(lp.io);

    const f = try dir.createFile(lp.io, name, .{});
    defer f.close(lp.io);
    try f.writeStreamingAll(lp.io, script);
}

const RemoteObject = struct {
    type: []const u8,
    subtype: ?[]const u8,
    className: ?[]const u8,
    description: ?[]const u8,
    objectId: ?[]const u8,
    value: js.Value,
};

const ConsoleMessage = struct {
    type: []const u8,
    executionContextId: i32,
    timestamp: u64,
    args: []RemoteObject,
};

pub fn consoleMessage(arena: Allocator, bc: *CDP.BrowserContext, event: *const Notification.ConsoleMessage) !void {
    const session_id = bc.session_id orelse return;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const context_id = bc.inspector_session.inspector.getContextId(&ls.local);

    var args: std.ArrayList(RemoteObject) = .empty;
    for (event.values) |value| {
        const remote_object = try bc.inspector_session.getRemoteObject(
            &ls.local,
            "",
            value,
        );
        defer remote_object.deinit();

        try args.append(arena, .{
            .type = try remote_object.getType(arena),
            .subtype = try remote_object.getSubtype(arena),
            .className = try remote_object.getClassName(arena),
            .description = try remote_object.getDescription(arena),
            .objectId = try remote_object.getObjectId(arena),
            .value = value,
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
