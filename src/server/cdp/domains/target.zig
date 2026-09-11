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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const URL = @import("../../../browser/URL.zig");
const js = @import("../../../browser/js/js.zig");

const log = lp.log;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        getTargets,
        attachToTarget,
        attachToBrowserTarget,
        closeTarget,
        createBrowserContext,
        createTarget,
        detachFromTarget,
        disposeBrowserContext,
        getBrowserContexts,
        getTargetInfo,
        sendMessageToTarget,
        setAutoAttach,
        setDiscoverTargets,
        activateTarget,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getTargets => return getTargets(cmd),
        .attachToTarget => return attachToTarget(cmd),
        .attachToBrowserTarget => return attachToBrowserTarget(cmd),
        .closeTarget => return closeTarget(cmd),
        .createBrowserContext => return createBrowserContext(cmd),
        .createTarget => return createTarget(cmd),
        .detachFromTarget => return detachFromTarget(cmd),
        .disposeBrowserContext => return disposeBrowserContext(cmd),
        .getBrowserContexts => return getBrowserContexts(cmd),
        .getTargetInfo => return getTargetInfo(cmd),
        .sendMessageToTarget => return sendMessageToTarget(cmd),
        .setAutoAttach => return setAutoAttach(cmd),
        .setDiscoverTargets => return setDiscoverTargets(cmd),
        .activateTarget => return cmd.sendResult(null, .{}),
    }
}

fn getTargets(cmd: *CDP.Command) !void {
    // If no context available, return an empty array.
    const bc = cmd.browser_context orelse {
        return cmd.sendResult(.{
            .targetInfos = [_]TargetInfo{},
        }, .{ .include_session_id = false });
    };

    const target_id = &(bc.target_id orelse {
        return cmd.sendResult(.{
            .targetInfos = [_]TargetInfo{},
        }, .{ .include_session_id = false });
    });

    return cmd.sendResult(.{
        .targetInfos = [_]TargetInfo{.{
            .targetId = target_id,
            .type = "page",
            .title = bc.getTitle() orelse "",
            .url = bc.getURL() orelse "about:blank",
            .attached = true,
            .canAccessOpener = false,
        }},
    }, .{ .include_session_id = false });
}

fn getBrowserContexts(cmd: *CDP.Command) !void {
    var browser_context_ids: []const []const u8 = undefined;
    if (cmd.browser_context) |bc| {
        browser_context_ids = &.{bc.id};
    } else {
        browser_context_ids = &.{};
    }

    return cmd.sendResult(.{
        .browserContextIds = browser_context_ids,
    }, .{ .include_session_id = false });
}

fn createBrowserContext(cmd: *CDP.Command) !void {
    const params = try cmd.params(struct {
        disposeOnDetach: bool = false,
        proxyServer: ?[:0]const u8 = null,
        proxyBypassList: ?[]const u8 = null,
        originsWithUniversalNetworkAccess: ?[]const []const u8 = null,
    });
    if (params) |p| {
        if (p.disposeOnDetach or p.proxyBypassList != null or p.originsWithUniversalNetworkAccess != null) {
            log.warn(.not_implemented, "Target.createBrowserContext", .{ .disposeOnDetach = p.disposeOnDetach, .has_proxyBypassList = p.proxyBypassList != null, .has_originsWithUniversalNetworkAccess = p.originsWithUniversalNetworkAccess != null });
        }
    }

    const bc = cmd.createBrowserContext() catch |err| switch (err) {
        // The only context around may be the placeholder setAutoAttach opened
        // so that the driver had something to attach to. A driver asking for a
        // context of its own expects a fresh, empty one; handing the
        // placeholder back leaves it holding two handles on a single context
        // whose page is already spoken for. Retract the placeholder instead.
        error.AlreadyExists => blk: {
            const existing = cmd.browser_context.?;
            if (existing.provisional == false) {
                return cmd.sendError(-32000, "Cannot have more than one browser context at a time", .{});
            }
            try retractProvisionalContext(cmd, existing);
            break :blk cmd.createBrowserContext() catch |e| switch (e) {
                error.AlreadyExists => unreachable,
                else => return e,
            };
        },
        else => return err,
    };

    if (params) |p| {
        if (p.proxyServer) |proxy| {
            // For now the http client is not in the browser context so we assume there is just 1.
            try cmd.cdp.browser.http_client.changeProxy(proxy);
            bc.http_proxy_changed = true;
        }
    }

    return cmd.sendResult(.{
        .browserContextId = bc.id,
    }, .{});
}

// Withdraws the placeholder context setAutoAttach opened, telling the driver
// its target and session are gone before the context goes away. Both ids are
// slices into the id generators' reused buffers, so the events have to go out
// before anything generates a replacement id.
fn retractProvisionalContext(cmd: *CDP.Command, bc: *CDP.BrowserContext) !void {
    if (bc.target_id) |*target_id| {
        // Auxiliary sessions first, the same way closeTarget unwinds them: a
        // driver that attached explicitly after the auto-attach announcement
        // holds one of these, and disposing the context without detaching it
        // leaves that driver waiting on a session that no longer exists.
        for (bc.attached_sessions.items) |session| {
            bc.fetchDisableForSession(session.id);
            try cmd.sendEvent("Target.detachedFromTarget", .{
                .targetId = target_id,
                .sessionId = session.id,
            }, .{ .session_id = session.parent_id });
        }
        bc.attached_sessions.clearRetainingCapacity();

        if (bc.session_id) |session_id| {
            try cmd.sendEvent("Target.detachedFromTarget", .{
                .sessionId = session_id,
                .targetId = target_id,
            }, .{});
        }
        try cmd.sendEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{});
    }

    _ = cmd.cdp.disposeBrowserContext(bc.id);
    cmd.browser_context = null;
}

fn disposeBrowserContext(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        browserContextId: []const u8,
    })) orelse return error.InvalidParams;

    if (cmd.cdp.disposeBrowserContext(params.browserContextId) == false) {
        return cmd.sendError(-32602, "No browser context with the given id found", .{});
    }
    try cmd.sendResult(null, .{});
}

// Gives a page-less browser context its root page: the page itself, the
// target id taken from the root frame, the inspector context and the CDP-side
// origin state. Returns the root frame. Shared by Target.createTarget and by
// the lazy STARTUP materialization below, which need the same page but
// announce it to the driver differently.
fn openRootPage(cmd: *CDP.Command, bc: *CDP.BrowserContext) !*lp.Frame {
    // if target_id is null, we should never have a blank frame
    lp.assert(!bc.session.hasPage(), "CDP.target.openRootPage not null page", .{});

    // if target_id is null, we should never have a session_id
    lp.assert(bc.session_id == null, "CDP.target.openRootPage not null session_id", .{});

    const page = try bc.session.createPage();
    const frame = page.frame().?;

    // the target_id == the frame_id of the "root" frame
    bc.target_id = id.toFrameId(page.frame_id);
    const target_id = &bc.target_id.?;
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const aux_data = try std.fmt.allocPrint(cmd.arena, "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}", .{target_id});
        bc.inspector_session.inspector.contextCreated(
            &ls.local,
            "",
            "", // @ZIGDOM
            // try frame.origin(arena),
            aux_data,
            true,
        );
    }

    // change CDP state
    bc.security_origin = "://";
    bc.secure_context_type = "InsecureScheme";

    return frame;
}

// Puppeteer answers the synthetic STARTUP target by creating a real
// BrowserContext of its own, which is what that hack was written for.
// Playwright does not: it attaches to the target we announced and drives that
// session straight away, so its Page.navigate arrives with sessionId=STARTUP
// and used to be answered with an empty result -- nothing navigated and goto
// hung until it timed out. Back the session with a real page the first time a
// command actually needs one.
pub fn materializeStartupSession(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse cmd.createBrowserContext() catch |err| switch (err) {
        error.AlreadyExists => unreachable,
        else => return err,
    };

    if (bc.session_id) |session_id| {
        // The driver already attached a real session, so the STARTUP
        // announcement it was handed at connect time is stale. Adopting it
        // here would hand a second name to a session that already has one.
        if (!std.mem.eql(u8, session_id, CDP.STARTUP_SESSION_ID)) {
            return error.UnknownSessionId;
        }
        return;
    }

    if (bc.target_id == null) {
        _ = try openRootPage(cmd, bc);
    }
    bc.session_id = CDP.STARTUP_SESSION_ID;
}

fn createTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        url: [:0]const u8 = "about:blank",
        // width: ?u64 = null,
        // height: ?u64 = null,
        browserContextId: ?[]const u8 = null,
        // enableBeginFrameControl: bool = false,
        // newWindow: bool = false,
        // background: bool = false,
        // forTab: ?bool = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse cmd.createBrowserContext() catch |err| switch (err) {
        error.AlreadyExists => unreachable,
        else => return err,
    };

    // A provisional page is the one setAutoAttach opened before the driver
    // asked for anything; the driver asking for a target now is it claiming
    // that page, so hand it over instead of reporting the slot as taken.
    const adopting = bc.target_id != null and bc.provisional;
    if (bc.target_id != null and adopting == false) {
        return error.TargetAlreadyLoaded;
    }
    if (params.browserContextId) |param_browser_context_id| {
        if (std.mem.eql(u8, param_browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    const frame = if (adopting)
        (bc.mainFrame() orelse return error.FrameNotLoaded)
    else
        try openRootPage(cmd, bc);
    bc.provisional = false;
    const target_id = &bc.target_id.?;

    // send targetCreated event
    // TODO: should this only be sent when Target.setDiscoverTargets
    // has been enabled?
    try cmd.sendEvent("Target.targetCreated", .{
        .targetInfo = TargetInfo{
            .attached = false,
            .targetId = target_id,
            .title = "",
            .browserContextId = bc.id,
            .url = "about:blank",
        },
    }, .{});

    // attach to the target only if auto attach is set. An adopted page was
    // already attached when setAutoAttach announced it, and the driver is
    // holding that session id -- announcing a second attach for it would hand
    // the same session out twice.
    if (cmd.cdp.target_auto_attach and bc.session_id == null) {
        try doAttachtoTarget(cmd, target_id);
    }

    if (!std.mem.eql(u8, "about:blank", params.url)) {
        const encoded_url = try URL.resolveNavigation(frame.call_arena, params.url, .{});
        try frame.navigate(
            encoded_url,
            .{ .reason = .address_bar, .kind = .{ .push = null } },
        );
    }

    try cmd.sendResult(.{
        .targetId = target_id,
    }, .{});
}

fn attachToTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
        flatten: bool = true,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = &(bc.target_id orelse return error.TargetNotLoaded);
    if (std.mem.eql(u8, target_id, params.targetId) == false) {
        return error.UnknownTargetId;
    }

    // The first attach becomes the page's primary session, which all
    // Page/Network/... events are emitted to. Later attaches — e.g.
    // Playwright's browserContext.newCDPSession(page), sent through its
    // browser session while the page session is live — get a distinct
    // auxiliary session so they don't collide with the primary one.
    if (bc.session_id == null) {
        try doAttachtoTarget(cmd, target_id);
        return cmd.sendResult(.{ .sessionId = bc.session_id }, .{});
    }

    const parent_id = if (cmd.input.session_id) |session_id|
        cmd.cdp.resolveSessionId(session_id) orelse return error.UnknownSessionId
    else
        null;
    const session_id = try bc.arena.dupe(u8, cmd.cdp.session_id_gen.next());
    try bc.attached_sessions.append(bc.arena, .{
        .id = session_id,
        .parent_id = parent_id,
    });

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = target_id,
            .title = bc.getTitle() orelse "",
            .url = bc.getURL() orelse "about:blank",
            .browserContextId = bc.id,
        },
    }, .{ .session_id = parent_id });

    return cmd.sendResult(.{ .sessionId = session_id }, .{});
}

fn attachToBrowserTarget(cmd: *CDP.Command) !void {
    const cdp = cmd.cdp;
    // Browser-target sessions are independent from page-target sessions and
    // can be created before a browser context exists.
    const session_id = cdp.browser_session_id orelse cdp.browser_session_id_gen.next();

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = "browser",
            .title = "",
            .url = "",
            .type = "browser",
            // Chrome doesn't send a browserContextId in this case.
            .browserContextId = null,
        },
    }, .{});

    cdp.browser_session_id = session_id;

    return cmd.sendResult(.{ .sessionId = session_id }, .{});
}

fn closeTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = &(bc.target_id orelse return error.TargetNotLoaded);
    if (std.mem.eql(u8, target_id, params.targetId) == false) {
        return error.UnknownTargetId;
    }

    // can't be null if we have a target_id
    lp.assert(bc.session.hasPage(), "CDP.target.closeTarget null frame", .{});

    try cmd.sendResult(.{ .success = true }, .{ .include_session_id = false });

    for (bc.attached_sessions.items) |session| {
        bc.fetchDisableForSession(session.id);
        try cmd.sendEvent("Inspector.detached", .{
            .reason = "Render process gone.",
        }, .{ .session_id = session.id });
        try cmd.sendEvent("Target.detachedFromTarget", .{
            .targetId = target_id,
            .sessionId = session.id,
            .reason = "Render process gone.",
        }, .{ .session_id = session.parent_id });
    }
    bc.attached_sessions.clearRetainingCapacity();

    // could be null, created but never attached
    if (bc.session_id) |session_id| {
        bc.fetchDisableForSession(session_id);
        // Inspector.detached event
        try cmd.sendEvent("Inspector.detached", .{
            .reason = "Render process gone.",
        }, .{ .session_id = session_id });

        // detachedFromTarget event
        try cmd.sendEvent("Target.detachedFromTarget", .{
            .targetId = target_id,
            .sessionId = session_id,
            .reason = "Render process gone.",
        }, .{});

        bc.session_id = null;
    }

    if (bc.page_handle) |handle| {
        handle.close();
        bc.page_handle = null;
    }
    for (bc.isolated_worlds.items) |world| {
        world.deinit();
    }
    bc.isolated_worlds.clearRetainingCapacity();
    bc.target_id = null;
}

fn getTargetInfo(cmd: *CDP.Command) !void {
    const Params = struct {
        targetId: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    if (params.targetId) |param_target_id| {
        const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
        const target_id = &(bc.target_id orelse return error.TargetNotLoaded);
        if (std.mem.eql(u8, target_id, param_target_id) == false) {
            return error.UnknownTargetId;
        }

        return cmd.sendResult(.{
            .targetInfo = TargetInfo{
                .targetId = target_id,
                .type = "page",
                .title = bc.getTitle() orelse "",
                .url = bc.getURL() orelse "about:blank",
                .attached = true,
                .canAccessOpener = false,
            },
        }, .{ .include_session_id = false });
    }

    return cmd.sendResult(.{
        .targetInfo = TargetInfo{
            .targetId = "TID-STARTUP",
            .type = "browser",
            .title = "",
            .url = "about:blank",
            .attached = true,
            .canAccessOpener = false,
        },
    }, .{ .include_session_id = false });
}

fn sendMessageToTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        message: []const u8,
        sessionId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    if (bc.target_id == null) {
        return error.TargetNotLoaded;
    }

    const session_id = bc.session_id orelse return error.UnknownSessionId;
    if (std.mem.eql(u8, session_id, params.sessionId) == false) {
        // Is this right? Is the params.sessionId meant to be the active
        // sessionId? What else could it be? We have no other session_id.
        return error.UnknownSessionId;
    }

    var aw = std.Io.Writer.Allocating.init(cmd.arena);
    cmd.cdp.dispatch(cmd.arena, .{ .capture = &aw.writer }, params.message) catch |err| {
        log.err(.cdp, "internal dispatch error", .{ .err = err, .id = cmd.input.id, .message = params.message });
        return err;
    };

    try cmd.sendEvent("Target.receivedMessageFromTarget", .{
        .message = aw.written(),
        .sessionId = params.sessionId,
    }, .{});
}

fn detachFromTarget(cmd: *CDP.Command) !void {
    const Params = struct {
        sessionId: ?[]const u8 = null,
        targetId: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    if (cmd.browser_context) |bc| {
        if (params.sessionId) |requested_session_id| {
            for (bc.attached_sessions.items, 0..) |session, index| {
                if (!std.mem.eql(u8, session.id, requested_session_id)) continue;

                _ = bc.attached_sessions.orderedRemove(index);
                bc.fetchDisableForSession(session.id);
                try cmd.sendEvent("Target.detachedFromTarget", .{
                    .sessionId = session.id,
                }, .{ .session_id = session.parent_id });
                return cmd.sendResult(null, .{});
            }

            const session_id = bc.session_id orelse return error.UnknownSessionId;
            if (!std.mem.eql(u8, session_id, requested_session_id)) {
                return error.UnknownSessionId;
            }
        }

        if (bc.session_id) |session_id| {
            bc.fetchDisableForSession(session_id);
            try cmd.sendEvent("Target.detachedFromTarget", .{
                .sessionId = session_id,
            }, .{});
        }
        bc.session_id = null;
    }

    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setDiscoverTargets(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

fn setAutoAttach(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        autoAttach: bool,
        waitForDebuggerOnStart: bool,
        flatten: bool = true,
        // filter: ?[]TargetFilter = null,
    })) orelse return error.InvalidParams;

    // set a flag to send Target.attachedToTarget events
    cmd.cdp.target_auto_attach = params.autoAttach;

    if (cmd.cdp.target_auto_attach == false) {
        // detach from all currently attached targets.
        if (cmd.browser_context) |bc| {
            if (bc.session_id) |session_id| {
                bc.fetchDisableForSession(session_id);
                try cmd.sendEvent("Target.detachedFromTarget", .{
                    .sessionId = session_id,
                }, .{});
            }
            bc.session_id = null;
        }
        try cmd.sendResult(null, .{});
        return;
    }

    // autoAttach is set to true, we must attach to all existing targets.
    if (cmd.browser_context) |bc| {
        if (bc.target_id == null) {
            if (bc.mainFrame()) |frame| {
                // the target_id == the frame_id of the "root" frame
                bc.target_id = id.toFrameId(frame._frame_id);
                try doAttachtoTarget(cmd, &bc.target_id.?);
            }
        }
        try cmd.sendResult(null, .{});
        return;
    }

    // Puppeteer, and probably others, expect the Browser to have started
    // creating targets on its own - an empty tab, a blank frame - and block
    // until one shows up. This used to answer with a placeholder target id that
    // had no page behind it, on the assumption that the driver would create a
    // real BrowserContext before doing anything else. Neither Puppeteer 25 nor
    // Playwright does: they drive the target they were handed, so its id has to
    // name a page that can actually navigate. Open one and announce that.
    //
    // It is marked provisional because the driver never asked for it. If it
    // goes on to create a context and a target of its own, those calls adopt
    // this one rather than running into the single-context limit.
    const bc = try cmd.createBrowserContext();
    bc.provisional = true;
    _ = try openRootPage(cmd, bc);
    try doAttachtoTarget(cmd, &bc.target_id.?);

    try cmd.sendResult(null, .{});
}

fn doAttachtoTarget(cmd: *CDP.Command, target_id: []const u8) !void {
    const bc = cmd.browser_context.?;
    const session_id = bc.session_id orelse blk: {
        break :blk try bc.arena.dupe(u8, cmd.cdp.session_id_gen.next());
    };

    if (bc.session_id == null) {
        // extra_headers should not be kept on a new frame or tab,
        // currently we have only 1 frame, we clear it just in case
        bc.extra_headers.clearRetainingCapacity();
    }

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = target_id,
            .title = bc.getTitle() orelse "",
            .url = bc.getURL() orelse "about:blank",
            .browserContextId = bc.id,
        },
    }, .{ .session_id = bc.session_id });

    bc.session_id = session_id;
}

const AttachToTarget = struct {
    sessionId: []const u8,
    targetInfo: TargetInfo,
    waitingForDebugger: bool = false,
};

const TargetInfo = struct {
    url: []const u8,
    title: []const u8,
    targetId: []const u8,
    attached: bool = true,
    type: []const u8 = "page",
    canAccessOpener: bool = false,
    browserContextId: ?[]const u8 = null,
};

const testing = @import("../testing.zig");
test "cdp.target: getBrowserContexts" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // {
    //     // no browser context
    //     try ctx.processMessage(.{.id = 4, .method = "Target.getBrowserContexts"});

    //     try ctx.expectSentResult(.{
    //         .browserContextIds = &.{},
    //     }, .{ .id = 4, .session_id = null });
    // }

    {
        // with a browser context
        _ = try ctx.loadBrowserContext(.{ .id = "BID-X" });
        try ctx.processMessage(.{ .id = 5, .method = "Target.getBrowserContexts" });

        try ctx.expectSentResult(.{
            .browserContextIds = &.{"BID-X"},
        }, .{ .id = 5, .session_id = null });
    }
}

test "cdp.target: createBrowserContext" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 4, .method = "Target.createBrowserContext" });
        try ctx.expectSentResult(.{
            .browserContextId = ctx.cdp().browser_context.?.id,
        }, .{ .id = 4, .session_id = null });
    }

    {
        // we already have one now
        try ctx.processMessage(.{ .id = 5, .method = "Target.createBrowserContext" });
        try ctx.expectSentError(-32000, "Cannot have more than one browser context at a time", .{ .id = 5 });
    }
}

test "cdp.target: disposeBrowserContext" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 7, .method = "Target.disposeBrowserContext" });
        try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 7 });
    }

    {
        try ctx.processMessage(.{
            .id = 8,
            .method = "Target.disposeBrowserContext",
            .params = .{ .browserContextId = "BID-10" },
        });
        try ctx.expectSentError(-32602, "No browser context with the given id found", .{ .id = 8 });
    }

    {
        _ = try ctx.loadBrowserContext(.{ .id = "BID-20" });
        try ctx.processMessage(.{
            .id = 9,
            .method = "Target.disposeBrowserContext",
            .params = .{ .browserContextId = "BID-20" },
        });
        try ctx.expectSentResult(null, .{ .id = 9 });
        try testing.expectEqual(null, ctx.cdp().browser_context);
    }
}

// Issue #2472: CDP target IDs (`FID-{d:0>10}`) must stay unique for the
// lifetime of a CDP connection. Before the fix, `Session.frame_id_gen`
// reset to 0 on `tearDownActivePage` AND fresh sessions also started
// from 0, so the second `Target.createTarget` after a dispose re-issued
// the same `FID-0000000001` and Playwright clients tripped on
// `Duplicate target FID-...`. The counter now lives on `Browser` and is
// monotonic across BrowserContexts.
test "cdp.target: createTarget assigns unique IDs across BrowserContexts (issue #2472)" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // Cycle 1: create context + target, capture the assigned target_id.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Target.createTarget",
        .params = .{ .url = "about:blank" },
    });
    const target_id_1 = ctx.cdp().browser_context.?.target_id.?;
    const bc_id_1 = ctx.cdp().browser_context.?.id;

    // Dispose the first context.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Target.disposeBrowserContext",
        .params = .{ .browserContextId = bc_id_1 },
    });
    try testing.expectEqual(null, ctx.cdp().browser_context);

    // Cycle 2: create another context + target. The new target_id must
    // differ from cycle 1's -- duplicates here are exactly what Playwright
    // asserts on with `Duplicate target FID-...`.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Target.createTarget",
        .params = .{ .url = "about:blank" },
    });
    const target_id_2 = ctx.cdp().browser_context.?.target_id.?;

    try testing.expect(!std.mem.eql(u8, &target_id_1, &target_id_2));
}

test "cdp.target: createTarget" {
    {
        var ctx = try testing.context();
        defer ctx.deinit();
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });

        // should create a browser context
        const bc = ctx.cdp().browser_context.?;
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{});
    }

    {
        var ctx = try testing.context();
        defer ctx.deinit();
        // active auto attach to get the Target.attachedToTarget event.
        try ctx.processMessage(.{ .id = 9, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });

        // should create a browser context
        const bc = ctx.cdp().browser_context.?;
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{});
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = bc.session_id.?, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{});
    }

    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-8" } });
        try ctx.expectSentError(-31998, "UnknownBrowserContextId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.target_id.? } }, .{});
    }
}

// A browser-target session (Target.attachToBrowserTarget) is distinct from
// the page-target session. It used to be stored in bc.session_id, which broke
// the "no target => no session_id" invariant asserted in createTarget.
test "cdp.target: attachToBrowserTarget then createTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "BSID-1", .targetInfo = .{ .targetId = "browser", .title = "", .url = "", .attached = true, .type = "browser", .canAccessOpener = false } }, .{});
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1 });
    try testing.expectEqual(null, ctx.cdp().browser_context);

    try ctx.processMessage(.{ .id = 2, .method = "Target.createBrowserContext" });
    const bc = &ctx.cdp().browser_context.?;
    try ctx.expectSentResult(.{ .browserContextId = bc.id }, .{ .id = 2 });
    try testing.expectEqual(null, bc.session_id);

    {
        try ctx.processMessage(.{ .id = 3, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 3 });
    }

    {
        // the browser session id is valid on subsequent commands
        try ctx.processMessage(.{ .id = 4, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = true } });
        try ctx.expectSentResult(null, .{ .id = 4, .session_id = "BSID-1" });
    }

    {
        // unknown session ids are still rejected
        try ctx.processMessage(.{ .id = 5, .method = "Target.setDiscoverTargets", .sessionId = "SID-NOPE", .params = .{ .discover = true } });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{ .id = 5 });
    }
}

test "cdp.target: closeTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "X" } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.target_id = "TID-000000000A".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.closeTarget", .params = .{ .targetId = "TID-000000000A" } });
        try ctx.expectSentResult(.{ .success = true }, .{ .id = 11 });
        try testing.expectEqual(false, bc.session.hasPage());
        try testing.expectEqual(null, bc.target_id);
    }
}

test "cdp.target: attachToTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "X" } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.target_id = "TID-000000000B".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        // the first attach becomes the primary session
        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-000000000B" } });
        const session_id = bc.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = session_id, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.target_id.? } }, .{});
        try testing.expectEqual(0, bc.attached_sessions.items.len);
    }
}

test "cdp.target: a target's events reach every session attached to it" {
    // A driver that receives the auto-attach announcement and then attaches
    // explicitly (Playwright does) ends up holding an auxiliary session, while
    // the page's events are addressed to the primary one. Measured against the
    // real binary before this was routed: Page.frameNavigated, loadEventFired
    // and the rest all arrived on the primary session id only, so the driver
    // saw nothing and its goto() sat until timeout.
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-FANOUT",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-00000000FA".*,
    });

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Target.attachToTarget",
        .sessionId = "BSID-1",
        .params = .{ .targetId = "TID-00000000FA" },
    });
    const auxiliary = bc.attached_sessions.items[0].id;

    try bc.cdp.sendEvent("Page.loadEventFired", .{ .timestamp = 1 }, .{ .session_id = bc.session_id.? });

    // The two commands above account for indices 0..3 (two results and two
    // attachedToTarget announcements); the event then lands once for the
    // primary session and once for the auxiliary one.
    try ctx.expectSentCount(6);
    try ctx.expectSentEvent("Page.loadEventFired", .{ .timestamp = 1 }, .{ .index = 4, .session_id = "SID-PRIMARY" });
    try ctx.expectSentEvent("Page.loadEventFired", .{ .timestamp = 1 }, .{ .index = 5, .session_id = auxiliary });
}

test "cdp.target: auxiliary session is unique and routed through its parent" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Target.attachToTarget",
        .sessionId = "BSID-1",
        .params = .{ .targetId = "TID-000000000B" },
    });

    const session_id = bc.attached_sessions.items[0].id;
    try testing.expect(!std.mem.eql(u8, session_id, bc.session_id.?));
    try ctx.expectSentEvent("Target.attachedToTarget", .{
        .sessionId = session_id,
        .targetInfo = .{
            .url = "about:blank",
            .title = "",
            .attached = true,
            .type = "page",
            .canAccessOpener = false,
            .browserContextId = "BID-9",
            .targetId = "TID-000000000B",
        },
    }, .{ .index = 2, .session_id = "BSID-1" });
    try ctx.expectSentResult(.{ .sessionId = session_id }, .{
        .id = 2,
        .session_id = "BSID-1",
    });
}

test "cdp.target: getTargetInfo" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 9, .method = "Target.getTargetInfo" });
        try ctx.expectSentResult(.{
            .targetInfo = .{
                .type = "browser",
                .title = "",
                .url = "about:blank",
                .attached = true,
                .canAccessOpener = false,
            },
        }, .{ .id = 9 });
    }

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.getTargetInfo", .params = .{ .targetId = "X" } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.getTargetInfo", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.target_id = "TID-000000000C".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.getTargetInfo", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.getTargetInfo", .params = .{ .targetId = "TID-000000000C" } });
        try ctx.expectSentResult(.{
            .targetInfo = .{
                .targetId = "TID-000000000C",
                .type = "page",
                .title = "",
                .url = "about:blank",
                .attached = true,
                .canAccessOpener = false,
            },
        }, .{ .id = 11 });
    }
}

test "cdp.target: issue#474: attach to just created target" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });

        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
        const session_id = bc.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
    }
}

test "cdp.target: detachFromTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
    try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
    const session_id = bc.session_id.?;

    try ctx.processMessage(.{ .id = 12, .method = "Target.detachFromTarget", .params = .{ .sessionId = session_id } });

    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
    try testing.expectEqual(null, bc.session_id);
    try ctx.expectSentResult(null, .{ .id = 12 });

    try ctx.processMessage(.{ .id = 13, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
    try testing.expect(!std.mem.eql(u8, session_id, bc.session_id.?));
    try ctx.expectSentResult(.{ .sessionId = bc.session_id.? }, .{ .id = 13 });
}

test "cdp.target: detachFromTarget auxiliary session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });

    try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-000000000B" } });
    const session_id = bc.attached_sessions.items[0].id;
    try testing.expect(!std.mem.eql(u8, session_id, bc.session_id.?));

    try ctx.processMessage(.{ .id = 11, .method = "Target.detachFromTarget", .params = .{ .sessionId = session_id } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
    try testing.expectEqual(0, bc.attached_sessions.items.len);
    try testing.expectEqual(true, bc.session_id != null);
    try ctx.expectSentResult(null, .{ .id = 11 });
}

test "cdp.target: detachFromTarget without session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        // detach when no session is attached should not send event
        try ctx.processMessage(.{ .id = 10, .method = "Target.detachFromTarget" });
        try ctx.expectSentResult(null, .{ .id = 10 });
        try ctx.expectSentCount(1);
    }
}

test "cdp.target: setAutoAttach false sends detachedFromTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    try ctx.processMessage(.{ .id = 10, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 11, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
    const session_id = bc.session_id.?;

    try ctx.processMessage(.{ .id = 12, .method = "Target.setAutoAttach", .params = .{ .autoAttach = false, .waitForDebuggerOnStart = false } });

    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
    try testing.expectEqual(null, bc.session_id);
    try ctx.expectSentResult(null, .{ .id = 12 });
}
