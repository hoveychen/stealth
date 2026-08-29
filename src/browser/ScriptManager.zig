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

const HttpClient = @import("../network/HttpClient.zig");

const js = @import("js/js.zig");
const URL = @import("URL.zig");
const Frame = @import("Frame.zig");
const ScriptManagerBase = @import("ScriptManagerBase.zig");

const Factory = @import("Factory.zig");
const Element = @import("webapi/Element.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const ScriptManager = @This();

// Re-exports so Frame / Context callers don't need to import Base directly.
pub const Script = ScriptManagerBase.Script;
pub const ModuleSource = ScriptManagerBase.ModuleSource;

base: ScriptManagerBase,
frame: *Frame,

// have we notified the frame that all scripts are loaded (used to fire the
// "load" event).
frame_notified_of_completion: bool,

// Scripts loaded based on a <link rel=preload as=script href=...> found during
// parsing, keyed by resolved URL.
preloaded_scripts: std.StringHashMapUnmanaged(PreloadedScript),

pub fn init(allocator: Allocator, http_client: *HttpClient, frame: *Frame) ScriptManager {
    var base = ScriptManagerBase.init(allocator, http_client, .{ .frame = frame });
    base.tail_hook = tailHook;
    return .{
        .base = base,
        .frame = frame,
        .preloaded_scripts = .empty,
        .frame_notified_of_completion = false,
    };
}

pub fn deinit(self: *ScriptManager) void {
    self.freePreloads();
    self.base.deinit();
    self.preloaded_scripts.deinit(self.base.allocator);
}

pub fn reset(self: *ScriptManager) void {
    self.freePreloads();
    self.preloaded_scripts.clearRetainingCapacity();
    self.base.reset();
    self.frame_notified_of_completion = false;
}

// Frees every preloaded Script
fn freePreloads(self: *ScriptManager) void {
    var it = self.preloaded_scripts.valueIterator();
    while (it.next()) |preload_script| {
        preload_script.deinit();
    }
}

// Frame wrapper uses this to fire documentIsLoaded and scriptsCompletedLoading
// once Base has finished processing its ready / defer queues.
pub fn tailHook(base: *ScriptManagerBase) void {
    const self: *ScriptManager = @fieldParentPtr("base", base);
    const frame = self.frame;

    // When all scripts (normal and deferred) are done loading, the document
    // state changes (this ultimately triggers the DOMContentLoaded event).
    // Page makes this safe to call multiple times.
    frame.documentIsLoaded();

    if (base.async_scripts.first == null and self.frame_notified_of_completion == false) {
        self.frame_notified_of_completion = true;
        frame.scriptsCompletedLoading();
    }
}

// Returns true when this link now owns a fetch: its load/error event fires
// when that fetch settles. That covers a fetch started here and one already in
// flight that had no link behind it (the prescan's), which this element
// adopts. false = no event will fire, so the caller queues a synthetic load.
// element is null when the hint came from the prescan rather than a <link>.
pub fn preloadScript(self: *ScriptManager, element: ?*Element.Html, url: []const u8, cors: bool) !bool {
    if (self.preloaded_scripts.getPtr(url)) |existing| {
        // The prescan reads the raw HTML before parsing, so a <script src>
        // anywhere in the document registers this URL ahead of the <link
        // rel=preload as=script> in the head that declared it. The link is
        // still what asked for the bytes as far as the page is concerned: it
        // is what fires load/error, and what names the resource entry ("link"
        // rather than "script" — Chrome 151, measured by
        // tools/fingerprint/resource-timing-initiators.mjs, which files one
        // entry for a preloaded script no matter how many elements consume
        // the response).
        //
        // Only while the fetch is still in flight. Once it has landed, its
        // doneCallback has already fired the (element-less, so silent) hint
        // event and filed the entry, and answering true here would promise a
        // load event that nothing is left to send.
        switch (existing.state) {
            .loading => |script| if (element != null and script.hint_element == null) {
                script.hint_element = element;
                return true;
            },
            .done => {},
        }
        return false;
    }

    const frame = self.frame;
    const arena = try frame.getArena(.small, "SM.preloadScript");
    errdefer arena.release();

    const owned_url = try arena.dupeZ(u8, url);

    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = owned_url,
        .node = .{},
        .manager = &self.base,
        .complete = false,
        .source = .{ .remote = .empty },
        .extra = .preload,
        .hint_element = element,
        .perf_fetch_start = self.base.perfNow(),
    };

    try self.preloaded_scripts.putNoClobber(self.base.allocator, owned_url, .{ .state = .{ .loading = script } });
    errdefer _ = self.preloaded_scripts.remove(owned_url);

    if (comptime lp.IS_DEBUG) {
        log.debug(.http, "script queue", .{ .url = owned_url, .ctx = "preload" });
    }

    try frame.makeRequest(.{
        .ctx = script,
        .url = owned_url,
        .method = .GET,
        .frame_id = frame._frame_id,
        .loader_id = frame._loader_id,
        .cookie_jar = &frame._session.cookie_jar,
        .cookie_origin = frame.url,
        .resource_type = .script,
        .cors = cors,
        .notification = frame._session.notification,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = PreloadedScript.doneCallback,
        .error_callback = PreloadedScript.errorCallback,
        .shutdown_callback = PreloadedScript.shutdownCallback,
    });
    return true;
}

fn waitForPreload(self: *ScriptManager, url: [:0]const u8) ?*Script {
    if (self.preloaded_scripts.getPtr(url) == null) {
        return null;
    }

    const was_evaluating = self.base.is_evaluating;
    self.base.is_evaluating = true;
    defer self.base.endEvaluationWindow(was_evaluating);

    var client = self.base.client;
    while (true) {
        const entry = self.preloaded_scripts.getPtr(url) orelse return null;
        switch (entry.state) {
            .loading => {
                _ = client.tickSync(200) catch return null;
                continue;
            },
            .done => |script| {
                // Preload scripts are single-use. We return it and it becomes
                // the caller's responsibility to free.
                _ = self.preloaded_scripts.remove(url);
                return script;
            },
        }
    }
}

pub fn addFromElement(self: *ScriptManager, comptime from_parser: bool, script_element: *Element.Html.Script, comptime ctx: []const u8) !void {
    if (script_element._executed) {
        // If a script tag gets dynamically created and added to the dom:
        //    document.getElementsByTagName('head')[0].appendChild(script)
        // that script tag will immediately get executed by our scriptAddedCallback.
        // However, if the location where the script tag is inserted happens to be
        // below where processHTMLDoc currently is, then we'll re-run that same script
        // again in processHTMLDoc. This flag is used to let us know if a specific
        // <script> has already been processed.
        return;
    }

    const element = script_element.asElement();
    if (element.getAttributeSafe(comptime .wrap("nomodule")) != null) {
        // these scripts should only be loaded if we don't support modules
        // but since we do support modules, we can just skip them.
        return;
    }

    const kind: Script.Extra.FrameExtra.Kind = blk: {
        const script_type = element.getAttributeSafe(comptime .wrap("type")) orelse break :blk .javascript;
        if (script_type.len == 0) {
            break :blk .javascript;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "application/javascript")) {
            break :blk .javascript;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "text/javascript")) {
            break :blk .javascript;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "module")) {
            break :blk .module;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "importmap")) {
            break :blk .importmap;
        }

        // "type" could be anything, but only the above are ones we need to process.
        // Common other ones are application/json, application/ld+json, text/template

        return;
    };

    const frame = self.frame;
    const base_url = frame.base();

    const src = element.getAttributeSafe(comptime .wrap("src")) orelse {
        return self.addInlineScript(script_element, kind);
    };

    // The script is remote (even data: and blob: are synthesized via HttpClient)

    // Set once arena ownership is resolved — transferred to `script`, or
    // released early on the adoption path — so the errdefer can't double-free.
    var handover = false;

    const arena = try frame.getArena(.small, "SM.addFromElement");
    errdefer if (handover == false) {
        arena.release();
    };

    const remote_url = try URL.resolve(arena.allocator(), base_url, src, .{ .encoding = frame.charset });
    script_element._executed = true;

    // Content-Security-Policy. Ignoring the page's policy is not a missing
    // feature but a detectable behaviour: rebrowser's bypassCsp test appends a
    // <script src> to a host its own policy does not list and reports whichever
    // of onload/onerror fires. A real browser fires error and never fetches.
    // The element's nonce is part of the question: a policy naming a matching
    // 'nonce-…' admits this load whatever its URL. Cloudflare's challenge
    // interstitial is exactly that shape -- no 'self', and the loader carries
    // the nonce -- so reading only the URL leaves us on the interstitial.
    // The slot, not the attribute: `s.nonce = '…'` leaves the markup untouched
    // in Chrome (measured -- see Element.getNonce), and the interstitial's
    // loader is set exactly that way, so reading the attribute here would miss
    // the very case this check exists for.
    const nonce_value = element.getNonce(frame);
    const nonce: ?[]const u8 = if (nonce_value.len == 0) null else nonce_value;
    if (frame.csp().allowsScript(remote_url, frame.url, nonce) == false) {
        log.info(.http, "script blocked by csp", .{ .url = remote_url, .ctx = ctx });
        // Queued rather than dispatched inline: this runs inside appendChild, so
        // firing user JS here would be a novel re-entrancy point (same reasoning
        // as the <link> hint events).
        try frame.queueElementEvent(Factory.protoOf(script_element), .@"error");
        arena.release();
        return;
    }

    const mode: Script.Extra.FrameExtra.Mode = blk: {
        if (element.getAttributeSafe(comptime .wrap("async")) != null) {
            break :blk .async;
        }

        // Check for defer or module (before checking dynamic script default)
        if (kind == .module or element.getAttributeSafe(comptime .wrap("defer")) != null) {
            break :blk .@"defer";
        }

        // For dynamically-inserted scripts (not from parser), default to async
        // unless async was explicitly set to false (which removes the attribute)
        // and defer was set to true (checked above)
        if (comptime !from_parser) {
            // Script has src and no explicit async/defer attributes
            // Per HTML spec, dynamically created scripts default to async
            break :blk .async;
        }

        break :blk .normal;
    };

    if (comptime lp.IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        log.debug(.http, "script queue", .{
            .ctx = ctx,
            .url = remote_url,
            .element = element,
            .stack = ls.local.stackTrace() catch "???",
        });
    }

    const frame_extra: Script.Extra = .{ .frame = .{
        .kind = kind,
        .mode = mode,
        .script_element = script_element,
        .frame = frame,
    } };

    if (mode != .normal) {
        var preloaded = self.takePreload(remote_url);
        if (preloaded == null and kind == .module) {
            preloaded = self.base.takeModuleHint(remote_url);
        }
        if (preloaded) |pre| {
            if (comptime lp.IS_DEBUG) {
                log.debug(.http, "script adopt", .{ .url = remote_url, .ctx = ctx, .state = if (pre.complete) "done" else "loading" });
            }
            pre.extra = frame_extra;

            // The adopted Script has its own arena; ours held only the URL
            // resolution, which nothing below needs.
            handover = true;
            arena.release();

            if (pre.complete and mode == .async) {
                // The fetch already finished, so no doneCallback will move it
                // to ready_scripts; queue it there directly.
                self.base.ready_scripts.append(&pre.node);
            } else {
                self.base.scriptList(pre).append(&pre.node);
            }
            if (pre.complete and !(from_parser and mode == .async)) {
                // ...and no doneCallback will trigger evaluation.
                //
                // Except for a parser-inserted async script: its execution is a
                // task, and evaluating here runs it inside the parser, ahead of
                // a parser-blocking script whose tag has not been reached yet.
                // Akamai's interstitial is built out of that difference -- the
                // loader is async and sits ahead of the blocking sensor -- so
                // running it early hands the sensor a page whose hidden frames
                // and patched globals already exist. Leaving it on
                // ready_scripts costs nothing: the next blocking script's
                // evaluation window drains it, and failing that, so does the
                // end of the parse.
                self.base.evaluate();
            }
            return;
        }
    }

    // A module script fetches in CORS mode whether or not the element says
    // `crossorigin`; a classic one only when it does. Measured on Chrome:
    // probes/b87-crossorigin-request-fixture.mjs.
    const element_cors = kind == .module or Frame.elementRequestsCors(element);

    const script = try arena.create(Script);
    script.* = .{
        .node = .{},
        .arena = arena,
        .manager = &self.base,
        .source = .{ .remote = .empty },
        .complete = false,
        .url = remote_url,
        .extra = frame_extra,
        .perf_fetch_start = self.base.perfNow(),
    };

    if (mode == .normal) {
        // Blocking: fetch synchronously and evaluate before the parser resumes.

        // A consumed preload (waitForPreload below) is owned by us: its buffer
        // is borrowed by `script`, so it must outlive eval.
        var consumed_preload: ?*Script = null;
        defer if (consumed_preload) |p| {
            p.deinit();
        };

        {
            const was_evaluating = self.base.is_evaluating;
            self.base.is_evaluating = true;
            defer self.base.endEvaluationWindow(was_evaluating);

            if (self.waitForPreload(remote_url)) |pre| {
                // There was a preloaded script, we borrow it's source and status
                consumed_preload = pre;
                script.source = pre.source;
                script.status = pre.status;
                script.complete = true;

                // The preload filed the entry, so this <script> does not. But
                // when the prescan started that fetch there was no element yet
                // to say whether it blocks the parser, and this one does: it
                // carries neither async nor defer. Correct the entry in place.
                //
                // A real <link rel=preload as=script> is left alone: Chrome
                // 151 reports one of those non-blocking even when a plain
                // <script src> consumes it
                // (tools/fingerprint/resource-timing-initiators.mjs).
                if (pre.hint_element == null) {
                    if (pre.perf_timing) |t| {
                        t.render_blocking_status = "blocking";
                    }
                }
            } else {
                const transfer = try self.base.client.newRequest(.{
                    .url = remote_url,
                    .method = .GET,
                    .frame_id = frame._frame_id,
                    .loader_id = frame._loader_id,
                    .cookie_jar = &frame._session.cookie_jar,
                    .cookie_origin = frame.url,
                    .resource_type = .script,
                    .cors = element_cors,
                    .notification = frame._session.notification,
                    .shutdown_callback = HttpClient.noopShutdown, // syncRequest installs its own
                }, &frame._http_owner);
                {
                    errdefer transfer.deinit();
                    try frame.headersForRequest(transfer);
                }
                // A blocking load that never gets a status -- connection
                // refused, DNS failure, a timeout -- is an error event on the
                // element just as much as a 404 is. Chrome fires one for both
                // (measured on 151 with a <script src> pointing at a closed
                // port); this used to hand the transport error back up to
                // Frame.scriptAddedCallback, which logged it and dispatched
                // nothing. The async path already fires it, through
                // Script.errorCallback.
                const response = self.base.client.syncRequest(transfer) catch |err| {
                    log.info(.http, "script fetch failed", .{ .url = remote_url, .err = err, .ctx = ctx });
                    handover = true;
                    script.executeCallback(comptime .wrap("error"));
                    script.deinit();
                    return;
                };

                // Take the body's arena rather than releasing it: `source`
                // has to outlive this call, up to script.deinit().
                script.source_arena = response.arena;
                script.source = .{ .remote = response.body };
                script.status = response.status;
                script.complete = true;
                script.perf_next_hop_protocol = response.next_hop_protocol;
                script.perf_encoded_body_size = response.encoded_body_size;
                script.perf_labels = response.labels;
                script.perf_times = response.times;

                // The blocking path never reaches a doneCallback, so the entry
                // is filed here -- as blocking, which is the whole reason this
                // fetch is synchronous. A consumed preload deliberately files
                // nothing here: the fetch that landed already did, and one
                // network load is one entry.
                script.recordResourceTiming("script", true);
            }
            handover = true;
        }

        if (script.status < 200 or script.status > 299) {
            log.info(.http, "script load error", .{ .status = script.status });
            script.executeCallback(comptime .wrap("error"));
            script.deinit();
            return;
        }

        return self.evalNow(script);
    }

    // async/defer: queue the script and fetch in the background; doneCallback
    // routes it through the ready_scripts / defer_scripts draining.
    self.base.scriptList(script).append(&script.node);

    const was_evaluating = self.base.is_evaluating;
    self.base.is_evaluating = true;
    defer self.base.endEvaluationWindow(was_evaluating);

    errdefer self.base.scriptList(script).remove(&script.node);
    try frame.makeRequest(.{
        .ctx = script,
        .url = remote_url,
        .method = .GET,
        .frame_id = frame._frame_id,
        .loader_id = frame._loader_id,
        .cookie_jar = &frame._session.cookie_jar,
        .cookie_origin = frame.url,
        .resource_type = .script,
        .cors = element_cors,
        .notification = frame._session.notification,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = Script.doneCallback,
        .error_callback = Script.errorCallback,
        // Nothing holds the transfer; teardown cleanup runs through
        // the manager's script lists.
        .shutdown_callback = HttpClient.noopShutdown,
    });
    handover = true;
}

// A <script> with no src. Runs synchronously right now, except an inline
// module during parsing, which waits its turn in defer_scripts.
fn addInlineScript(self: *ScriptManager, script_element: *Element.Html.Script, kind: Script.Extra.FrameExtra.Kind) !void {
    const node = script_element.asElement().asNode();

    const source_len = node.childTextContentLen();
    if (source_len == 0) {
        // if content is appended later, we'll execute it then since
        // script_element._executed is still false
        return;
    }

    const frame = self.frame;
    const arena = try frame.getArena(source_len + @sizeOf(Script) + 1, "SM.addInlineScript");
    errdefer arena.release();

    const source = blk: {
        const buf = try arena.alloc(u8, source_len + 1);
        var writer: std.Io.Writer = .fixed(buf);
        try node.getChildTextContent(&writer);
        buf[source_len] = 0;
        break :blk buf[0..source_len :0];
    };

    script_element._executed = true;

    const mode: Script.Extra.FrameExtra.Mode = if (kind == .module) .@"defer" else .normal;
    const script = try arena.create(Script);
    script.* = .{
        .node = .{},
        .arena = arena,
        .manager = &self.base,
        .source = .{ .@"inline" = source },
        .complete = true,
        .status = 200,
        .url = frame.base(),
        .extra = .{ .frame = .{
            .kind = kind,
            .mode = mode,
            .script_element = script_element,
            .frame = frame,
        } },
    };

    // An inline module found during parsing waits its turn in document order.
    // Once parsing is done, the deferred batch has already drained and won't
    // run again, so run it immediately instead.
    if (mode == .@"defer" and self.base.static_scripts_done == false) {
        self.base.scriptList(script).append(&script.node);
        return;
    }

    self.evalNow(script);
}

fn evalNow(self: *ScriptManager, script: *Script) void {
    // could have already been evaluating if this is dynamically added
    const was_evaluating = self.base.is_evaluating;
    self.base.is_evaluating = true;
    defer {
        script.deinit();
        self.base.endEvaluationWindow(was_evaluating);
    }

    script.eval();
}

pub fn staticScriptsDone(self: *ScriptManager) void {
    self.base.staticScriptsDone();
}

// Removes and returns the preload entry for `url` in whatever state it's in.
fn takePreload(self: *ScriptManager, url: [:0]const u8) ?*Script {
    const kv = self.preloaded_scripts.fetchRemove(url) orelse return null;
    return switch (kv.value.state) {
        inline else => |script| script,
    };
}

const PreloadedScript = struct {
    state: State,

    const State = union(enum) {
        loading: *Script,
        done: *Script,
    };

    pub fn deinit(self: PreloadedScript) void {
        switch (self.state) {
            inline else => |script| script.deinit(),
        }
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const script: *Script = @ptrCast(@alignCast(ctx));
        // Claimed here rather than after the adoption check, so the element
        // that asked for the bytes names the entry whether or not a <script>
        // has taken the response over by now. Script.doneCallback's own call
        // is a no-op once this one has run.
        //
        // Only a real <link rel=preload as=script> is "link". A `hint_element`
        // of null means the *prescan* started this fetch after finding a
        // <script src> ahead of the parser -- an internal head start, which
        // Chrome files under the script element it belongs to, not under a
        // link that the page never wrote.
        script.recordResourceTiming(if (script.hint_element == null) "script" else "link", false);
        if (script.extra != .preload) {
            // Adopted by a real <script> element (addFromElement) while the
            // fetch was in flight; complete it as a normal frame script.
            return Script.doneCallback(ctx);
        }
        script.complete = true;
        if (comptime lp.IS_DEBUG) {
            log.debug(.http, "script fetch complete", .{ .req = script.url });
        }

        const self: *ScriptManager = @fieldParentPtr("base", script.manager);
        self.preloaded_scripts.getPtr(script.url).?.state = .{ .done = script };
        script.queueHintEvent(.load);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const script: *Script = @ptrCast(@alignCast(ctx));
        if (script.extra != .preload) {
            // Adopted mid-flight; fail it as a normal frame script (list
            // unlink, error event on the element and the hint link).
            return Script.errorCallback(ctx, err);
        }
        if (script.status == 404) {
            log.info(.http, "script 404", .{ .req = script.url, .extra = "preload" });
        } else {
            log.warn(.http, "script fetch error", .{ .err = err, .req = script.url, .extra = "preload", .status = script.status });
        }

        const self: *ScriptManager = @fieldParentPtr("base", script.manager);
        _ = self.preloaded_scripts.remove(script.url);
        script.queueHintEvent(.@"error");
        script.deinit();
    }

    // Owner-driven teardown killed this preload fetch via Transfer.kill, which
    // fires shutdown_callback — not error_callback. Drop the entry (so a
    // synchronous waitForPreload's getPtr returns null and it falls back to a
    // normal fetch) and free the Script. No JS / hint events here, unlike
    // errorCallback, since the owner is being torn down.
    fn shutdownCallback(ctx: *anyopaque) void {
        const script: *Script = @ptrCast(@alignCast(ctx));
        if (script.extra != .preload) {
            // Adopted: the Script lives in the manager's script lists and is
            // reaped by reset(), same as any async script (noopShutdown).
            return;
        }
        const self: *ScriptManager = @fieldParentPtr("base", script.manager);
        _ = self.preloaded_scripts.remove(script.url);
        script.deinit();
    }
};

const testing = @import("../testing.zig");

test "WebApi: script async order" {
    try testing.htmlRunner("script_async_order.html", .{});
}

test "ScriptManager: PreloadedScript.shutdownCallback drops a .loading preload" {
    const page = try testing.pageTest("mcp_nav.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const sm = &frame._script_manager;
    const url: [:0]const u8 = "http://127.0.0.1:9582/killed-preload.js";

    // Build a `.loading` preload entry directly (mirroring preloadScript) so the
    // test doesn't depend on the network. shutdownCallback frees the Script.
    const arena = try frame.getArena(.large, "test.shutdown");
    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = url,
        .node = .{},
        .manager = &sm.base,
        .complete = false,
        .source = .{ .remote = .empty },
        .extra = .preload,
        .hint_element = null,
    };
    try sm.preloaded_scripts.put(sm.base.allocator, url, .{ .state = .{ .loading = script } });

    // Transfer.kill fires this on owner teardown. The entry must be dropped so a
    // synchronous waitForPreload's getPtr returns null and it falls back.
    PreloadedScript.shutdownCallback(script);

    try testing.expect(sm.preloaded_scripts.getPtr(url) == null);
}

test "ScriptManager: waitForPreload stops when teardown is pending" {
    const page = try testing.pageTest("mcp_nav.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const sm = &frame._script_manager;
    const client = sm.base.client;
    const url: [:0]const u8 = "http://127.0.0.1:9582/pending-preload.js";

    const arena = try frame.getArena(.large, "test.pending_teardown");
    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = url,
        .node = .{},
        .manager = &sm.base,
        .complete = false,
        .source = .{ .remote = .empty },
        .extra = .preload,
        .hint_element = null,
    };
    try sm.preloaded_scripts.put(sm.base.allocator, url, .{ .state = .{ .loading = script } });
    defer sm.takePreload(url).?.deinit();

    const message_arena = try client.arena_pool.acquire(.tiny, "test teardown message");
    client.inbox.push(message_arena, .{ .cdp = .{
        .raw = try message_arena.dupe(u8, "{}"),
        .input = .{ .method = "Target.closeTarget" },
    } });
    defer client.inbox.pop().?.deinit();

    try testing.expect(sm.waitForPreload(url) == null);
}
