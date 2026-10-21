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

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const io = std.testing.io;
pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expect = std.testing.expect;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;

// sometimes it's super useful to have an arena you don't really care about
// in a test. Like, you need a mutable string, so you just want to dupe a
// string literal. It has nothing to do with the code under test, it's just
// infrastructure for the test itself.
pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.c_allocator);
pub const arena_allocator = arena_instance.allocator();

pub fn reset() void {
    _ = arena_instance.reset(.retain_capacity);
}

const App = @import("App.zig");
const js = @import("browser/js/js.zig");
const Config = @import("Config.zig");
const Frame = @import("browser/Frame.zig");
const font_file = @import("browser/font_file.zig");
const Browser = @import("browser/Browser.zig");
const Session = @import("browser/Session.zig");
const Notification = @import("Notification.zig");

// Merged std.testing.expectEqual and std.testing.expectString
// can be useful when testing fields of an anytype an you don't know
// exactly how to assert equality
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .array => |arr| if (arr.child == u8) {
            return std.testing.expectEqualStrings(expected, &actual);
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (comptime isStringArray(ptr.child)) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (ptr.child == []u8 or ptr.child == []const u8) {
                return expectString(expected, actual);
            }
        },
        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
            return;
        },
        .optional => {
            if (@typeInfo(@TypeOf(expected)) == .null) {
                return std.testing.expectEqual(null, actual);
            }
            if (actual) |_actual| {
                return expectEqual(expected, _actual);
            }
            return std.testing.expectEqual(expected, null);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);
            try expectEqual(expectedTag, actualTag);

            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }
            unreachable;
        },
        else => {},
    }
    return std.testing.expectEqual(expected, actual);
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    if (@typeInfo(@TypeOf(expected)) == .null) {
        return std.testing.expectEqual(null, actual);
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .optional => {
            if (actual) |value| {
                return expectDelta(expected, value, delta);
            }
            return std.testing.expectEqual(null, expected);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(expected))) {
        .optional => {
            if (expected) |value| {
                return expectDelta(value, actual, delta);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    var diff = expected - actual;
    if (diff < 0) {
        diff = -diff;
    }
    if (diff <= delta) {
        return;
    }

    print("Expected {} to be within {} of {}. Actual diff: {}", .{ expected, delta, actual, diff });
    return error.NotWithinDelta;
}

fn isStringArray(comptime T: type) bool {
    if (!is(.array)(T) and !isPtrTo(.array)(T)) {
        return false;
    }
    return std.meta.Elem(T) == u8;
}

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
    if (comptime is(.pointer)(T)) {
        return @typeInfo(T).pointer.size == .one;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}

pub const Random = struct {
    var instance: ?std.Random.DefaultPrng = null;

    pub fn fill(buf: []u8) void {
        var r = random();
        r.bytes(buf);
    }

    pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
        var r = random();
        const l = r.intRangeAtMost(usize, min, buf.len);
        r.bytes(buf[0..l]);
        return buf;
    }

    pub fn intRange(comptime T: type, min: T, max: T) T {
        var r = random();
        return r.intRangeAtMost(T, min, max);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            io.random(std.mem.asBytes(&seed));
            instance = std.Random.DefaultPrng.init(seed);
            // instance = std.Random.DefaultPrng.init(0);
        }
        return instance.?.random();
    }
};

pub fn expectJson(a: anytype, b: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);

    errdefer {
        const a_json = std.json.Stringify.valueAlloc(aa, a_value, .{ .whitespace = .indent_2 }) catch unreachable;
        const b_json = std.json.Stringify.valueAlloc(aa, b_value, .{ .whitespace = .indent_2 }) catch unreachable;
        std.debug.print("== Expected ==\n{s}\n\n== Actual ==\n{s}", .{ a_json, b_json });
    }

    try expectJsonValue(a_value, b_value);
}

pub fn isEqualJson(a: anytype, b: anytype) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();
    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);
    return isJsonValue(a_value, b_value);
}

fn convertToJson(arena: Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) {
        return value;
    }

    var str: []const u8 = undefined;
    if (T == []u8 or T == []const u8 or comptime isStringArray(T)) {
        str = value;
    } else {
        str = try std.json.Stringify.valueAlloc(arena, value, .{});
    }
    return std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});
}

fn expectJsonValue(a: std.json.Value, b: std.json.Value) !void {
    try expectEqual(@tagName(a), @tagName(b));

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return,
        .bool => try expectEqual(a.bool, b.bool),
        .integer => try expectEqual(a.integer, b.integer),
        .float => try expectEqual(a.float, b.float),
        .number_string => try expectEqual(a.number_string, b.number_string),
        .string => try expectEqual(a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            try expectEqual(a_len, b_len);
            for (a.array.items, b.array.items) |a_item, b_item| {
                try expectJsonValue(a_item, b_item);
            }
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    try expectJsonValue(entry.value_ptr.*, b_item);
                } else {
                    return error.MissingKey;
                }
            }
        },
    }
}

fn isJsonValue(a: std.json.Value, b: std.json.Value) bool {
    if (std.mem.eql(u8, @tagName(a), @tagName(b)) == false) {
        return false;
    }

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            if (a_len != b_len) {
                return false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (isJsonValue(a_item, b_item) == false) {
                    return false;
                }
            }
            return true;
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    if (isJsonValue(entry.value_ptr.*, b_item) == false) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

pub var test_app: *App = undefined;
pub var test_browser: Browser = undefined;
pub var test_notification: *Notification = undefined;
pub var test_session: *Session = undefined;

const WEB_API_TEST_ROOT = "src/browser/tests/";
const HtmlRunnerOpts = struct {
    timeout_ms: u32 = 2000,
    inject_script: ?[]const u8 = null,
    load_resources: Config.LoadResources = .{
        .worker = true,
        .iframe = true,
    },
    // Shortens the engine-wide request timeout (normally 5s) for the duration
    // of the run, so a test can reach it without stalling the suite.
    http_timeout_ms: ?u31 = null,
    // Asks for the WebMCP surface, as `lightpanda mcp` and `--webmcp` do. The
    // test config is a `serve` one, so the default here is the gated state.
    webmcp: bool = false,
};

// Turns the WebMCP surface on for the tests that drive it -- the CDP `WebMCP`
// domain ones, which build their pages through `testing.context()` rather than
// through htmlRunner (which has its own opt). Pair every call with a `defer` of
// the false case: the config is process-wide.
pub fn setWebMcp(enabled: bool) void {
    test_config.mode.serve.webmcp = enabled;
}

// Create a fresh page on `test_session` and return its root frame — for tests
// that just need a frame to build a DOM in. The page lives on the session;
// release it with `defer testing.test_session.closeAllPages()`.
pub fn createFrame() !*Frame {
    return (try test_session.createPage()).frame().?;
}

pub fn waitForFrame() !void {
    var runner = test_session.runner(.{});
    const frame_id = test_session.pages.items[0].frame._frame_id;
    return runner.waitForFrame(frame_id, 2000, .{ .until = .done });
}

pub fn htmlRunner(comptime path: []const u8, opts: HtmlRunnerOpts) !void {
    defer reset();

    var inject_scripts: [1][]const u8 = undefined;
    if (opts.inject_script) |script| {
        inject_scripts[0] = script;
        test_session.inject_scripts = inject_scripts[0..1];
    }
    defer test_session.inject_scripts = &.{};

    test_session.load_resources = opts.load_resources;
    defer test_session.load_resources = .{
        // original defaults, tests expect these to be on
        .worker = true,
        .iframe = true,
    };

    const previous_http_timeout = test_config.mode.serve.http_timeout;
    if (opts.http_timeout_ms) |http_timeout_ms| {
        test_config.mode.serve.http_timeout = http_timeout_ms;
    }
    defer test_config.mode.serve.http_timeout = previous_http_timeout;

    test_config.mode.serve.webmcp = opts.webmcp;
    defer test_config.mode.serve.webmcp = false;

    const root = try std.fs.path.joinZ(arena_allocator, &.{ WEB_API_TEST_ROOT, path });
    const stat = std.Io.Dir.cwd().statFile(io, root, .{}) catch |err| {
        std.debug.print("Failed to stat file: '{s}'", .{root});
        return err;
    };

    switch (stat.kind) {
        .file => {
            if (@import("root").shouldRun(std.fs.path.basename(root)) == false) {
                return;
            }
            try @import("root").subtest(root);
            try runWebApiTest(root, opts.timeout_ms);
        },
        .directory => {
            var dir = try std.Io.Dir.cwd().openDir(io, root, .{
                .iterate = true,
                .follow_symlinks = false,
                .access_sub_paths = false,
            });
            defer dir.close(io);

            var it = dir.iterateAssumeFirstIteration();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) {
                    continue;
                }

                if (!std.mem.endsWith(u8, entry.name, ".html")) {
                    continue;
                }

                if (@import("root").shouldRun(entry.name) == false) {
                    continue;
                }

                const full_path = try std.fs.path.joinZ(arena_allocator, &.{ root, entry.name });
                try @import("root").subtest(entry.name);
                try runWebApiTest(full_path, opts.timeout_ms);
            }
        },
        else => |kind| {
            std.debug.print("Unknown file type: {s} for {s}\n", .{ @tagName(kind), root });
            return error.InvalidTestPath;
        },
    }
}

fn runWebApiTest(test_file: [:0]const u8, timeout_ms: u32) !void {
    const page = try test_session.createPage();
    defer page.close();

    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}",
        .{test_file},
        0,
    );

    const frame = page.frame().?;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        try frame.navigate(url, .{});
    }

    var runner = test_session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .load });

    var wait_ms: u32 = timeout_ms;
    var timer: std.Io.Timestamp = .now(lp.io, .boot);
    while (true) {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const js_val = ls.local.exec("testing.assertOk()", "testing.assertOk()") catch |err| {
            const caught = try_catch.caughtOrError(arena_allocator, err);
            std.debug.print("{s}: test failure\nError: {f}\n", .{ test_file, caught });
            return err;
        };
        if (js_val.isTrue()) {
            return;
        }
        const sleep_ms: usize = switch (try runner.tickForFrame(page.frame_id, 20, .{ .until = .done })) {
            .done => 20,
            .ok => |next_ms| @min(next_ms, 20),
        };

        const lap: std.Io.Timestamp = .now(lp.io, .boot);
        const ms_elapsed: u64 = @intCast(timer.durationTo(lap).toMilliseconds());
        timer = lap;
        if (ms_elapsed >= wait_ms) {
            ls.local.eval("testing.printTimeoutState()", "testing.printTimeoutState()") catch {};
            return error.TestTimedOut;
        }
        wait_ms -= @intCast(ms_elapsed);
        lp.io.sleep(.fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
    }
}

const PageTestOpts = struct {
    wait_until_done: bool = true,
};
pub fn pageTest(comptime test_file: []const u8, opts: PageTestOpts) !Session.PageHandle {
    const page = try test_session.createPage();
    errdefer page.close();

    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}{s}",
        .{ WEB_API_TEST_ROOT, test_file },
        0,
    );

    try page.navigate(url, .{});
    if (opts.wait_until_done) {
        var runner = test_session.runner(.{});
        try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    }
    return page;
}

const Server = @import("server/Server.zig");
const TestWSServer = @import("TestWSServer.zig");
const TestHTTPServer = @import("TestHTTPServer.zig");

pub var test_cdp_server: ?*Server = null;
var test_cdp_server_thread: ?std.Thread = null;
var test_http_server: ?TestHTTPServer = null;
var test_http_server_thread: ?std.Thread = null;
var test_ws_server: ?TestWSServer = null;
var test_ws_server_thread: ?std.Thread = null;

// Server-side state for the /sse/* endpoints. sse_flag proves progressive
// delivery (see /sse/streaming); sse_reconnect_hits makes /sse/reconnect
// serve a different stream on the second connection.
var sse_flag = std.atomic.Value(bool).init(false);
var sse_reconnect_hits = std.atomic.Value(usize).init(0);

pub var test_config: Config = undefined;

// The three test servers bind fixed ports (9582 HTTP, 9583 CDP, 9584 WS), so two
// test binaries on one machine are two binaries wanting the same three ports.
// That used to go unnoticed rather than fail: std's `reuse_address` sets
// SO_REUSEPORT as well as SO_REUSEADDR, and SO_REUSEPORT lets a second process
// bind a live port and have the kernel split incoming connections between the
// two listeners. A fixture then comes back out of the *other* checkout's tree,
// which reads as a scatter of unrelated failures — a `testing.js` that 404s, an
// assertion carrying an expectation that does not exist in this branch — and
// says nothing at all about ports.
//
// So the servers bind exclusively now, and the whole run takes an advisory lock
// first: a second run waits its turn instead of interleaving. `flock` is
// released by the kernel when the fd goes away, so a killed run cannot leave the
// lock held behind it.
const test_port_lock_path = "/tmp/lightpanda-test-servers.lock";
var test_port_lock: ?std.Io.File = null;

fn lockTestPorts() void {
    if (@import("builtin").target.os.tag == .windows) {
        return;
    }
    const file = std.Io.Dir.cwd().createFile(lp.io, test_port_lock_path, .{ .truncate = false }) catch |err| {
        std.debug.print("test port lock: cannot open {s}: {}\n", .{ test_port_lock_path, err });
        return;
    };
    if (std.c.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        std.debug.print("another test run holds {s} — waiting for it to finish\n", .{test_port_lock_path});
        while (true) {
            const rc = std.c.flock(file.handle, std.posix.LOCK.EX);
            if (rc == 0) {
                break;
            }
            // A signal is the only failure worth retrying; anything else would
            // spin, so give up and let the bind report the collision instead.
            if (std.posix.errno(rc) != .INTR) {
                std.debug.print("test port lock: flock failed, continuing unlocked\n", .{});
                file.close(lp.io);
                return;
            }
        }
    }
    test_port_lock = file;
}

fn unlockTestPorts() void {
    const file = test_port_lock orelse return;
    test_port_lock = null;
    // Closing the fd drops the lock; the explicit unlock is for clarity.
    _ = std.c.flock(file.handle, std.posix.LOCK.UN);
    file.close(lp.io);
}

test "tests:beforeAll" {
    log.opts.level = .warn;
    log.opts.format = .pretty;

    lockTestPorts();

    const test_allocator = @import("root").tracking_allocator;

    test_config = try Config.init(test_allocator, "test", .{
        .serve = .{
            .insecure_disable_tls_host_verification = true,
            .user_agent_suffix = "internal-tester",
            .ws_max_concurrent = 50,
            .load_resources = .{ .worker = true, .iframe = true },
            .watchdog_ms = 0,
            // V8 puts an isolate's JS stack limit at the thread's stack start
            // minus --stack-size (984 KB), and a Debug build on x86_64 Linux
            // is already deeper than that when beforeAll builds test_browser
            // on the main thread: its first Script::Compile failed with
            // "Maximum call stack size exceeded" and not one test ran (see
            // Snapshot.create for the same trap at startup). No test reads
            // the recursion depth this moves.
            .v8_flags_unsafe = if (@import("builtin").target.os.tag == .linux) "--stack-size=4000" else null,
        },
    });

    test_app = try App.init(test_allocator, &test_config);
    errdefer test_app.deinit();

    try test_browser.init(test_app, .{});
    errdefer test_browser.deinit();

    // Create notification for testing
    test_notification = try Notification.init(test_app.allocator);
    errdefer test_notification.deinit();

    test_session = try test_browser.newSession(test_notification);

    var wg: lp.WaitGroup = .{};
    wg.startMany(3);

    test_cdp_server_thread = try std.Thread.spawn(.{}, serveCDP, .{&wg});

    test_http_server = TestHTTPServer.init(testHTTPHandler);
    test_http_server_thread = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &test_http_server.?, &wg });

    test_ws_server = TestWSServer.init();
    test_ws_server_thread = try std.Thread.spawn(.{}, TestWSServer.run, .{ &test_ws_server.?, &wg });

    // need to wait for the servers to be listening, else tests will fail because
    // they aren't able to connect.
    wg.wait();
}

test "tests:afterAll" {
    if (test_cdp_server) |server| {
        server.shutdown();
    }
    if (test_cdp_server_thread) |thread| {
        thread.join();
    }
    if (test_cdp_server) |server| {
        server.deinit();
    }

    if (test_http_server) |*server| {
        server.stop();
    }
    if (test_http_server_thread) |thread| {
        thread.join();
    }
    if (test_http_server) |*server| {
        server.deinit();
    }

    if (test_ws_server) |*server| {
        server.stop();
    }
    if (test_ws_server_thread) |thread| {
        thread.join();
    }

    // Ports are free again, so the next run may start.
    unlockTestPorts();

    @import("root").v8_peak_memory = test_browser.env.isolate.getHeapStatistics().total_physical_size;

    // Browser must be deinit'd before the notification — Session/Frame
    // teardown may unregister notification listeners (e.g. CookieStore
    // detach), which dereferences `notification.listeners`.
    test_browser.deinit();
    test_notification.deinit();
    test_app.deinit();
    test_config.deinit(@import("root").tracking_allocator);
}

fn serveCDP(wg: *lp.WaitGroup) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 9583);

    test_cdp_server = Server.init(test_app, address) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        // Release beforeAll rather than deadlocking it: the tests that need this
        // server will fail with a clear connection error, which is readable, and
        // a hung `wg.wait()` is not.
        wg.finish();
        return err;
    };
    test_cdp_server.?.protocols = .{ .cdp = true, .webdriver = true };
    wg.finish();

    test_cdp_server.?.run();
}

// /serve-count/ counters; only ever touched from the test HTTP server thread.
var serve_counts = [_]struct { name: []const u8, count: u32 = 0 }{
    .{ .name = "defer" },
    .{ .name = "async" },
    .{ .name = "dynamic" },
    .{ .name = "prescan_blocking" },
    .{ .name = "prescan_defer" },
    .{ .name = "prescan_module" },
};

// Requests the server has seen for `/served/counted.png`; read back over
// `/served/counted-hits`. Atomic because the test server answers on its own
// thread.
var counted_png_hits: std.atomic.Value(u32) = .init(0);

// The same thing for a font, read back over `/served/counted-font-hits`. A
// `@font-face` file is asked for by a scan that runs more than once in one
// parse -- when the parser stops for a script, and again at DOMContentLoaded --
// so "how many requests did one rule cost" is a question only the server can
// answer. The page cannot: `document.fonts` shows one face and the resource
// table filed one entry while the wire carried two (measured on iphey,
// tools/fingerprint/scratch/s48/waterfall.mjs).
var counted_font_hits: std.atomic.Value(u32) = .init(0);

// Smallest valid PNG: a single transparent pixel. Served for any image request
// the tests make; see the image branch at the end of `testHTTPHandler`.
const ONE_PIXEL_PNG = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc, 0xcf, 0xc0, 0x50,
    0x0f, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xa9, 0x8c, 0x21, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

// Two pictures whose intrinsic size is neither square nor one, so an assertion
// about `naturalWidth` cannot pass by accident on a placeholder. They are also
// two different formats on purpose: the geometry comes out of a different
// parser for each, and one fixture would only ever exercise one of them.
//
// PNG, 7 wide by 3 tall.
const PNG_7X3 = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x03,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x5f, 0xc3, 0x15, 0xc5, 0x00, 0x00, 0x00,
    0x32, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x15, 0xc9, 0x31, 0x01, 0x80,
    0x00, 0x08, 0x00, 0x30, 0x42, 0x10, 0x82, 0x10, 0x84, 0xa0, 0x83, 0x84,
    0xa0, 0xbd, 0xce, 0x63, 0xd7, 0x22, 0xe2, 0x79, 0x93, 0xa2, 0x19, 0x96,
    0x23, 0x22, 0x25, 0x45, 0x33, 0x2c, 0x97, 0x7f, 0x96, 0xa4, 0x68, 0x86,
    0xe5, 0xf8, 0x00, 0xb8, 0x19, 0x23, 0x9b, 0x4e, 0x0a, 0x4f, 0x43, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

// GIF, 5 wide by 9 tall: one transparent frame over a two-colour table.
const GIF_5X9 = [_]u8{
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x05, 0x00, 0x09, 0x00, 0xf0, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x09, 0x00,
    0x00, 0x02, 0x02, 0x4c, 0x01, 0x00, 0x3b,
};

// A gzip-encoded script, served at `/served/compressed.js`. A resource entry
// reports two sizes -- what came off the wire and what it became after
// decoding -- and they only differ for a response that was actually compressed,
// so telling them apart needs a body the test server did not encode itself.
//
// Produced once by gzipping GZIPPED_SCRIPT_SOURCE at level 9; the bytes are
// checked in rather than compressed at request time so the two lengths below
// are fixed and a test can name them.
const GZIPPED_SCRIPT = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x13, 0x2b, 0xcf, 0xcc, 0x4b, 0xc9, 0x2f,
    0xd7, 0x8b, 0x8f, 0x4f, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x4e, 0x4d, 0x51, 0xb0, 0x55,
    0x30, 0xb4, 0xe6, 0xd2, 0xd7, 0x57, 0x28, 0x48, 0x4c, 0x49, 0xc9, 0xcc, 0x4b, 0x27, 0x44, 0x8f,
    0x2a, 0x1d, 0x55, 0x3a, 0xaa, 0x74, 0x54, 0xe9, 0xa8, 0xd2, 0x51, 0xa5, 0x03, 0xaf, 0x14, 0x00,
    0x22, 0x79, 0x72, 0xb2, 0xd1, 0x06, 0x00, 0x00,
};

// What GZIPPED_SCRIPT decodes to: `window.__compressed = 1;` followed by forty
// identical comment lines, which is what makes it compress 24-fold.
const GZIPPED_SCRIPT_DECODED_LEN = 1745;

// How many OPTIONS the CORS endpoints below have answered, per counter slot.
// `net/cors_preflight.html` reads a slot either side of a request, so "a
// preflight was / was not sent" is an assertion rather than a guess. Per slot
// rather than one total because the page's script blocks run concurrently:
// a shared counter would pick up every other block's preflights. A request
// names its slot with `&c=N`; `/cors/count?c=N` reads it back.
var cors_preflights_seen: [8]std.atomic.Value(u32) = @splat(.init(0));

// The page origin for the web-api tests. The CORS endpoints answer to it and
// to nothing else, so `localhost:9582` is a genuinely cross-origin API for a
// page served from here -- same server, different origin.
const CORS_PAGE_ORIGIN = "http://127.0.0.1:9582";

// The CORS half of the test server. `/cors/echo` is the interesting one: it
// only permits the request if the preflight announced exactly the method and
// header list named in the query, so `net/cors_preflight.html` asserts the
// *shape* of our Access-Control-Request-* by whether the request goes through,
// with no shared state to race on. The rest are fixed refusals.
fn corsHandler(req: *std.http.Server.Request, path: []const u8) !bool {
    if (!std.mem.startsWith(u8, path, "/cors/")) return false;

    const query = if (std.mem.indexOfScalar(u8, path, '?')) |i| path[i + 1 ..] else "";
    const route = if (std.mem.indexOfScalar(u8, path, '?')) |i| path[0..i] else path;

    if (std.mem.eql(u8, route, "/cors/count")) {
        var buf: [16]u8 = undefined;
        const slot = corsCounterSlot(query) orelse 0;
        const body = std.fmt.bufPrint(&buf, "{d}", .{cors_preflights_seen[slot].load(.monotonic)}) catch unreachable;
        try req.respond(body, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
        });
        return true;
    }

    if (req.head.method == .OPTIONS) {
        if (corsCounterSlot(query)) |slot| {
            _ = cors_preflights_seen[slot].fetchAdd(1, .monotonic);
        }

        const acrm = corsRequestHeader(req, "access-control-request-method");
        const acrh = corsRequestHeader(req, "access-control-request-headers");

        if (std.mem.eql(u8, route, "/cors/echo")) {
            // The query says what the preflight must have announced. A
            // mismatch answers without Allow-Origin, which refuses.
            const want_method = corsQueryParam(query, "m") orelse "";
            const want_headers = corsQueryParam(query, "h");
            const method_ok = std.mem.eql(u8, acrm orelse "", want_method);
            const headers_ok = if (want_headers) |want|
                acrh != null and std.mem.eql(u8, acrh.?, want)
            else
                acrh == null;
            if (!method_ok or !headers_ok) {
                try req.respond("", .{ .status = .bad_request });
                return true;
            }
        }

        if (std.mem.eql(u8, route, "/cors/status-500")) {
            // Allow-* headers on a 5xx: an error status is a refusal on its
            // own, whatever it says.
            try req.respond("", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Access-Control-Allow-Origin", .value = CORS_PAGE_ORIGIN },
                    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, PATCH" },
                    .{ .name = "Access-Control-Allow-Headers", .value = "content-type, x-probe, x-alpha, x-zeta" },
                },
            });
            return true;
        }

        var headers: [5]std.http.Header = undefined;
        var n: usize = 0;
        if (!std.mem.eql(u8, route, "/cors/no-acao")) {
            headers[n] = .{
                .name = "Access-Control-Allow-Origin",
                .value = if (std.mem.eql(u8, route, "/cors/deny-origin"))
                    "https://example.invalid"
                else
                    CORS_PAGE_ORIGIN,
            };
            n += 1;
        }
        headers[n] = .{
            .name = "Access-Control-Allow-Methods",
            .value = if (std.mem.eql(u8, route, "/cors/deny-method")) "GET" else "GET, POST, PUT, DELETE, PATCH",
        };
        n += 1;
        if (!std.mem.eql(u8, route, "/cors/deny-header")) {
            headers[n] = .{ .name = "Access-Control-Allow-Headers", .value = "content-type, x-probe, x-alpha, x-zeta" };
            n += 1;
        }
        headers[n] = .{ .name = "Access-Control-Allow-Credentials", .value = "true" };
        n += 1;
        if (std.mem.eql(u8, route, "/cors/maxage")) {
            headers[n] = .{ .name = "Access-Control-Max-Age", .value = "600" };
            n += 1;
        }
        try req.respond("", .{ .status = .no_content, .extra_headers = headers[0..n] });
        return true;
    }

    // Same idea as /echo_referer, but readable cross-origin: the Allow-Origin
    // below is what lets a page on CORS_PAGE_ORIGIN see the body, so a test can
    // assert what Referer a cross-origin subresource carried.
    const body = if (std.mem.eql(u8, route, "/cors/referer"))
        corsRequestHeader(req, "referer") orelse "NONE"
    else
        "ok";

    // The response half. Every route above answers with an Allow-Origin that
    // permits the page, which is what makes "the request went through" a
    // statement about the preflight. These five answer the *actual* request in
    // ways that must stop the page reading it -- or, for the last two, that
    // decide which response headers it may see.
    var response_headers: [5]std.http.Header = undefined;
    var n: usize = 0;
    response_headers[n] = .{ .name = "Content-Type", .value = "text/plain" };
    n += 1;

    if (std.mem.eql(u8, route, "/cors/bare")) {
        // Nothing at all: no Allow-Origin is a refusal, not a default.
    } else if (std.mem.eql(u8, route, "/cors/wrong-origin")) {
        response_headers[n] = .{ .name = "Access-Control-Allow-Origin", .value = "https://example.invalid" };
        n += 1;
    } else if (std.mem.eql(u8, route, "/cors/wildcard")) {
        // No Allow-Credentials beside it: `*` is valid uncredentialed and
        // invalid credentialed, and sending both would hide the difference.
        response_headers[n] = .{ .name = "Access-Control-Allow-Origin", .value = "*" };
        n += 1;
    } else {
        response_headers[n] = .{ .name = "Access-Control-Allow-Origin", .value = CORS_PAGE_ORIGIN };
        n += 1;
        response_headers[n] = .{ .name = "Access-Control-Allow-Credentials", .value = "true" };
        n += 1;
        // A response header outside the CORS-safelisted seven, so "can the page
        // read it" has a visible answer either way.
        if (std.mem.startsWith(u8, route, "/cors/expose")) {
            response_headers[n] = .{ .name = "X-Custom", .value = "1" };
            n += 1;
            if (std.mem.eql(u8, route, "/cors/expose-named")) {
                response_headers[n] = .{ .name = "Access-Control-Expose-Headers", .value = "x-custom" };
                n += 1;
            }
        }
    }

    try req.respond(body, .{ .extra_headers = response_headers[0..n] });
    return true;
}

fn corsRequestHeader(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn corsCounterSlot(query: []const u8) ?usize {
    const raw = corsQueryParam(query, "c") orelse return null;
    const slot = std.fmt.parseInt(usize, raw, 10) catch return null;
    return if (slot < cors_preflights_seen.len) slot else null;
}

fn corsQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

// The two responses `performance_resource.html` needs to see the cross-origin
// opacity rule from both sides: same body, same Allow-Origin, differing only in
// whether the timing is opted into. Fetched from `localhost:9582` by a page on
// `127.0.0.1:9582`, which is a real cross origin on the same server -- the trick
// `net/cors_preflight.html` already relies on.
//
// The body is a fixed 512 bytes so a leaked size reads as itself rather than as
// a plausible small number.
const TIMING_ALLOW_BODY = "t" ** 512;

// Every corner of the `Server-Timing` grammar this engine claims to handle, in
// one response, so the parse can be asserted against Chrome's answer for the
// same header rather than against the RFC. What Chrome 151 makes of it was
// measured by tools/fingerprint/probes/expr-b111-server-timing.js against
// tools/fingerprint/scratch/b111/st-server.mjs -- see the table on
// `ServerTiming` in timing.zig.
//
// The trailing `;dur=9, gone;dur=1` is the sharp end: an empty member name does
// not drop only itself, it ends the header, so `gone` must not appear.
const SERVER_TIMING_HEADER =
    "cfExtPri, cache;desc=\"a, b\",   spaced ; dur = 1.5 ; desc = plain , " ++
    "esc;desc=\"q\\\"r\", dup;dur=1;dur=2, unk;foo=1;desc=z, up;DUR=3, " ++
    "tok;desc=x y, hex;dur=abc, ;dur=9, gone;dur=1";

fn serverTimingHandler(req: *std.http.Server.Request, raw_path: []const u8) !bool {
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |i| raw_path[0..i] else raw_path;
    if (!std.mem.eql(u8, path, "/server-timing")) {
        return false;
    }
    try req.respond("st", .{ .extra_headers = &.{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Server-Timing", .value = SERVER_TIMING_HEADER },
    } });
    return true;
}

// Two copies of the header on one response. A proxy adds its members rather
// than replacing the origin's, and the page is supposed to see one list.
fn serverTimingTwiceHandler(req: *std.http.Server.Request, raw_path: []const u8) !bool {
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |i| raw_path[0..i] else raw_path;
    if (!std.mem.eql(u8, path, "/server-timing-twice")) {
        return false;
    }
    try req.respond("st", .{ .extra_headers = &.{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Server-Timing", .value = "first;dur=1" },
        .{ .name = "Server-Timing", .value = "second;dur=2" },
    } });
    return true;
}

fn timingAllowHandler(req: *std.http.Server.Request, raw_path: []const u8) !bool {
    // The query is dropped rather than matched on: a test needs two entries
    // whose names differ but whose RESPONSE is identical -- same
    // Timing-Allow-Origin, same bytes -- so that a difference between them is
    // the request's doing and not the response's. `?plain` is that spelling.
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |i| raw_path[0..i] else raw_path;
    // The `frame-` pair is the same two responses as HTML, so the no-cors half
    // of the rule can be asked with an <iframe>. Whether the request went out
    // in CORS mode is a second, independent gate, and a fetch cannot ask about
    // it -- fetch is always CORS mode.
    const PREFIX = "/timing-allow/";
    // Checked before the slice below, not after: this handler is offered every
    // request the server takes, and slicing a shorter path panics the whole
    // run rather than failing one test.
    if (!std.mem.startsWith(u8, path, PREFIX)) {
        return false;
    }
    const framed = std.mem.startsWith(u8, path, PREFIX ++ "frame-");
    // The `script-` pair is the third request mode the rule distinguishes: an
    // element load that IS in CORS mode because it carries `crossorigin`,
    // as against fetch (always CORS) and an <iframe> (never).
    const scripted = std.mem.startsWith(u8, path, PREFIX ++ "script-");
    const tail = path[PREFIX.len..];
    const allowed = if (std.mem.eql(u8, tail, "on") or std.mem.eql(u8, tail, "frame-on") or std.mem.eql(u8, tail, "script-on"))
        true
    else if (std.mem.eql(u8, tail, "off") or std.mem.eql(u8, tail, "frame-off") or std.mem.eql(u8, tail, "script-off"))
        false
    else
        return false;

    var headers: [4]std.http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Content-Type", .value = if (framed) "text/html" else if (scripted) "application/javascript" else "text/plain" };
    n += 1;
    // Allow-Origin so the page may read the BODY; Timing-Allow-Origin is a
    // separate opt-in governing whether it may read the TIMING. Varying only
    // the second is the whole point of the pair.
    headers[n] = .{ .name = "Access-Control-Allow-Origin", .value = "*" };
    n += 1;
    if (allowed) {
        headers[n] = .{ .name = "Timing-Allow-Origin", .value = "*" };
        n += 1;
    }
    // Sent by both halves of the pair, which is the point: `Server-Timing`
    // rides on the same opt-in the sizes do, so the two responses differ in
    // Timing-Allow-Origin alone and the member list is present on one and
    // empty on the other.
    headers[n] = .{ .name = "Server-Timing", .value = "cfExtPri" };
    n += 1;
    try req.respond(if (framed) TIMING_ALLOW_BODY_HTML else if (scripted) TIMING_ALLOW_BODY_JS else TIMING_ALLOW_BODY, .{ .extra_headers = headers[0..n] });
    return true;
}

// 512 bytes either way: the HTML spelling is a comment, so a framed copy
// weighs exactly what the plain one does and one expected number covers both.
const TIMING_ALLOW_BODY_HTML = "<!--" ++ "t" ** 505 ++ "-->";

// 512 bytes again, as a comment so the script parses and runs to nothing.
const TIMING_ALLOW_BODY_JS = "//" ++ "t" ** 510;

// What a subresource request carried, recorded by the server so a test can ask
// about headers it has no other way to see: the body of an <img> or a
// stylesheet never reaches script, and `crossorigin` is precisely a claim about
// the REQUEST. `/xo-record/<slot>` files what arrived; `/xo-read/<slot>` hands
// it back as text, same-origin, so a fetch can read it.
//
// Guarded by a mutex rather than built from atomics like cors_preflights_seen
// above: these are strings, and the server answers on a thread per connection.
var xo_seen_mutex: std.Io.Mutex = .init;
// One slot per distinct name across the WHOLE run, not per test: the server is
// shared and this array is a global, so two test files asking about six and
// three requests need nine between them. Overflowing is silent from the
// server's side and reads back as "(never requested)" -- which looks exactly
// like the request never going out, and cost one confused debugging round. Keep
// it comfortably above the number of slots in use.
var xo_seen: [32]XoRecord = @splat(.{});

const XoRecord = struct {
    slot_len: u8 = 0,
    slot: [32]u8 = undefined,
    value_len: u8 = 0,
    value: [160]u8 = undefined,

    fn name(self: *const XoRecord) []const u8 {
        return self.slot[0..self.slot_len];
    }
};

fn xoHandler(req: *std.http.Server.Request, path: []const u8) !bool {
    const RECORD = "/xo-record/";
    const READ = "/xo-read/";
    const recording = std.mem.startsWith(u8, path, RECORD);
    if (!recording and !std.mem.startsWith(u8, path, READ)) {
        return false;
    }
    // Everything after the prefix, query and extension included: the slot name
    // is what the test asks for it back by, and `/xo-record/script.js` has to
    // read back as `script.js` so the URL can end in something an <img> or a
    // <script> will accept.
    const slot = path[(if (recording) RECORD.len else READ.len)..];

    if (recording) {
        var buf: [160]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "origin={s} mode={s} dest={s}", .{
            corsRequestHeader(req, "origin") orelse "(none)",
            corsRequestHeader(req, "sec-fetch-mode") orelse "(none)",
            corsRequestHeader(req, "sec-fetch-dest") orelse "(none)",
        }) catch buf[0..0];

        xo_seen_mutex.lockUncancelable(lp.io);
        for (&xo_seen) |*rec| {
            if (rec.slot_len != 0 and !std.mem.eql(u8, rec.name(), slot)) continue;
            rec.slot_len = @intCast(@min(slot.len, rec.slot.len));
            @memcpy(rec.slot[0..rec.slot_len], slot[0..rec.slot_len]);
            rec.value_len = @intCast(value.len);
            @memcpy(rec.value[0..value.len], value);
            break;
        }
        xo_seen_mutex.unlock(lp.io);

        // A body each kind will accept, so the load completes and the element
        // fires `load` rather than `error`. The type follows the extension the
        // test asked for.
        const ext = std.fs.path.extension(slot);
        const body: []const u8 = if (std.mem.eql(u8, ext, ".css")) "body{color:#111}" else if (std.mem.eql(u8, ext, ".gif")) &GIF_1PX else "void 0;";
        try req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = if (std.mem.eql(u8, ext, ".css")) "text/css" else if (std.mem.eql(u8, ext, ".gif")) "image/gif" else "application/javascript" },
                // Permissive: a CORS refusal would change which loads complete and
                // muddy a reading about what went out.
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            },
        });
        return true;
    }

    xo_seen_mutex.lockUncancelable(lp.io);
    defer xo_seen_mutex.unlock(lp.io);
    for (&xo_seen) |*rec| {
        if (rec.slot_len != 0 and std.mem.eql(u8, rec.name(), slot)) {
            try req.respond(rec.value[0..rec.value_len], .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
            });
            return true;
        }
    }
    try req.respond("(never requested)", .{
        .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
    });
    return true;
}

const GIF_1PX = [_]u8{
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x00, 0x02, 0x01, 0x44, 0x00, 0x3b,
};

fn testHTTPHandler(req: *std.http.Server.Request) !void {
    const path = req.head.target;

    if (try corsHandler(req, path)) return;
    if (try timingAllowHandler(req, path)) return;
    if (try serverTimingHandler(req, path)) return;
    if (try serverTimingTwiceHandler(req, path)) return;
    if (try xoHandler(req, path)) return;

    if (std.mem.eql(u8, path, "/xhr")) {
        return req.respond("1234567890" ** 10, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    // Deliberately out of alphabetical order and mixed case, so that what
    // getAllResponseHeaders() does to the names is visible.
    if (std.mem.eql(u8, path, "/xhr/headers_order")) {
        return req.respond("hello", .{
            .extra_headers = &.{
                .{ .name = "X-Zed", .value = "last" },
                .{ .name = "Content-Type", .value = "text/plain" },
                .{ .name = "A-First", .value = "yes" },
            },
        });
    }

    // Never answers: the caller is expected to give up first, either from
    // xhr.timeout or from the engine-wide --http-timeout. Used by
    // net/xhr_timeout.html to tell those two apart.
    if (std.mem.eql(u8, path, "/xhr/slow")) {
        lp.io.sleep(.fromMilliseconds(1500), .awake) catch {};
        return;
    }

    if (std.mem.eql(u8, path, "/xhr_empty")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    const xhr_xml_body = "<?xml version=\"1.0\"?><catalog><item id=\"a\"/><item id=\"b\"/><pubDate>2026</pubDate></catalog>";

    if (std.mem.eql(u8, path, "/xhr/xml")) {
        return req.respond(xhr_xml_body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/xml" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/xml_as_text")) {
        return req.respond(xhr_xml_body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/json")) {
        return req.respond("{\"over\":\"9000!!!\",\"updated_at\":1765867200000}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/redirect")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://127.0.0.1:9582/xhr" },
            },
        });
    }

    // Scripts, so a cross-origin (localhost) load doesn't depend on CORS.
    if (std.mem.eql(u8, path, "/resource-timing/tao")) {
        return req.respond("window.__rt_tao = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/javascript" },
                .{ .name = "Timing-Allow-Origin", .value = "https://example.com, *" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/resource-timing/plain")) {
        return req.respond("window.__rt_plain = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/resource-timing/redirect")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/resource-timing/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-no-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-cross-origin-x-hop")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/echo-x-hop" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo-x-hop")) {
        var it = req.iterateHeaders();
        var value: []const u8 = "NONE";
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-hop")) {
                value = header.value;
                break;
            }
        }
        return req.respond(value, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-target")) {
        return req.respond("<!DOCTYPE html><title>landed</title>", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/303-no-location")) {
        // 3xx WITHOUT a Location header: not a redirect, a final response
        // whose body must be delivered (RFC 9110 §15.4).
        return req.respond("<!DOCTYPE html><title>landed</title><p>see other body</p>", .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/300-with-location")) {
        // A non-redirect 3xx (fetch's redirect statuses are only 301, 302,
        // 303, 307 and 308) carrying a Location header: the header is a
        // preference hint, not a redirect — the body must be delivered.
        return req.respond("<!DOCTYPE html><title>choices</title><p>multiple choices body</p>", .{
            .status = .multiple_choice,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Location", .value = "http://127.0.0.1:9582/hi.html" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-with-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target#target_fragment" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/404")) {
        return req.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/401")) {
        return req.respond("No", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/404.js")) {
        // Valid JS body served with a 404 status. Used to assert that
        // ScriptManager does NOT execute the body of a failed script
        // fetch — if it did, window.__404_body_executed would be set.
        return req.respond("window.__404_body_executed = true;", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/defer-marker.js")) {
        // A deferred script body. Used by the regression test for a
        // <script defer> whose completion is deferred by a later
        // <link rel=stylesheet>'s synchronous fetch — it must still execute.
        return req.respond("window.__deferRan = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/chunked.js")) {
        // A script body framed with `Transfer-Encoding: chunked` instead of a
        // Content-Length, which is the h1 shape of what an h2 origin does to
        // every response it streams. Nothing here can be answered by reading
        // the Content-Length header, because there isn't one -- so this is the
        // route that tells a byte count taken off the header apart from one
        // taken off the socket.
        const body = "window.__chunked_ran = true;";
        var send_buffer: [512]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/javascript" },
                    .{ .name = "Cache-Control", .value = "no-store" },
                },
            },
        });
        try res.writer.writeAll(body);
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/gzip.js")) {
        // `window.__gzip_ran = true;` deflated with gzip -9. Embedded rather
        // than compressed here for the same reason /zstd is: Zig's std ships
        // the decompressor, not the compressor. 25 source bytes land as 45 on
        // the wire, so the encoded and decoded sizes cannot be confused, and
        // the gzip header makes the encoded one the larger of the two -- a
        // reading that has to come off the socket, since neither number is the
        // one a naive `body.len` would produce.
        const gzip_body = [_]u8{
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x13, 0x2b, 0xcf,
            0xcc, 0x4b, 0xc9, 0x2f, 0xd7, 0x8b, 0x8f, 0x4f, 0xaf, 0xca, 0x2c, 0x88,
            0x2f, 0x4a, 0xcc, 0x53, 0xb0, 0x55, 0x28, 0x29, 0x2a, 0x4d, 0xb5, 0x06,
            0x00, 0xad, 0xf2, 0x02, 0x28, 0x19, 0x00, 0x00, 0x00,
        };
        return req.respond(&gzip_body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Content-Encoding", .value = "gzip" },
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/serve-count/") and std.mem.endsWith(u8, path, ".js")) {
        // Serves `window.__serve_count_<name> = N;` where N counts how many
        // times this URL has been served. Lets a fixture assert a preloaded
        // script was fetched exactly once: the body the consumer executes
        // carries N == 1, while a duplicate fetch would execute N == 2.
        // no-store so the second fetch can't be satisfied by the HTTP cache.
        const name = path["/serve-count/".len .. path.len - ".js".len];
        const slot: *u32 = blk: {
            for (&serve_counts) |*sc| {
                if (std.mem.eql(u8, sc.name, name)) break :blk &sc.count;
            }
            return req.respond("unknown counter", .{ .status = .not_found });
        };
        slot.* += 1;
        var buf: [64]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "window.__serve_count_{s} = {d};", .{ name, slot.* });
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/500")) {
        return req.respond("Internal Server Error", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/no_content_type")) {
        return req.respond("untyped", .{});
    }

    if (std.mem.eql(u8, path, "/xhr/binary")) {
        return req.respond(&.{ 0, 0, 1, 2, 0, 0, 9 }, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/simple")) {
        // A complete stream: default + custom event types, multi-line data,
        // an id, and a comment. The connection closes right after; the test
        // close()s before the (1s) reconnect fires.
        return req.respond("retry: 1000\ndata: first\n\n: comment\nid: 42\nevent: custom\ndata: a\ndata: b\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/stop_loading/streaming.html")) {
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            },
        });
        try res.writer.writeAll("<html><body><p id=first>first</p>");
        try res.writer.flush();
        try res.flush();
        lp.io.sleep(.fromMilliseconds(1500), .awake) catch {};
        try res.writer.writeAll("<p id=second>second</p></body></html>");
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/partial_body/streaming.html")) {
        // No charset on the header, so the one the document declares only
        // counts once it has arrived. The first chunk stops one byte into the
        // two-byte "é" of the paragraph, and carries everything that writes to
        // the frame or asks the network for something when it is parsed.
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html" },
                },
            },
        });
        try res.writer.writeAll("<html><head><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><base href=\"/elsewhere/\"><title>Partial</title></head>" ++
            "<body><h1>H\xc3\xa9llo</h1><script>window.__partial_ran = true;</script><img src=\"/partial_body/img.gif\"><p>first paragraph <a href=\"next.html\">next</a> caf\xc3");
        try res.writer.flush();
        try res.flush();
        lp.io.sleep(.fromMilliseconds(1000), .awake) catch {};
        try res.writer.writeAll("\xa9</p><p id=second>second</p></body></html>");
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/sse/streaming")) {
        sse_flag.store(false, .release);
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream" },
                },
            },
        });
        try res.writer.writeAll("data: first\n\n");
        try res.writer.flush();
        try res.flush();

        // Proof of progressive delivery: "second" is only sent once the
        // client has reacted to "first" (by fetching /sse/flag), which it
        // can only do if "first" was delivered while this response was
        // still streaming.
        var waited: usize = 0;
        while (!sse_flag.load(.acquire) and waited < 5000) : (waited += 10) {
            lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        if (sse_flag.load(.acquire)) {
            // split mid-line to exercise buffering across chunks
            try res.writer.writeAll("data: sec");
            try res.writer.flush();
            try res.flush();
            lp.io.sleep(.fromMilliseconds(20), .awake) catch {};
            try res.writer.writeAll("ond\n\n");
            try res.writer.flush();
            try res.flush();
        }
        return res.end();
    }

    if (std.mem.eql(u8, path, "/sse/flag")) {
        sse_flag.store(true, .release);
        return req.respond("", .{});
    }

    if (std.mem.eql(u8, path, "/sse/reconnect")) {
        if (sse_reconnect_hits.fetchAdd(1, .monotonic) == 0) {
            return req.respond("retry: 10\ndata: one\n\n", .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream" },
                },
            });
        }
        return req.respond("data: two\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/long_retry")) {
        return req.respond("retry: 60000\ndata: x\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/404")) {
        return req.respond("data: x\n\n", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/badmime")) {
        return req.respond("data: x\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/visibility.css")) {
        // Used by css/external_stylesheet.html — drives the visibility
        // cascade through StyleManager via Frame.loadExternalStylesheet
        // so a `.ext-hide` element is observable to checkVisibility().
        return req.respond(".ext-hide { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/visibility2.css")) {
        // Second visibility sheet used by the href-change regression test:
        // mutating link.href must replace the cached sheet's rules in place,
        // not append a new entry to document.styleSheets.
        return req.respond(".ext-hide-2 { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/404.css")) {
        return req.respond("/* unused */", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/oversize.css")) {
        // Body that exceeds Frame.MAX_STYLESHEET_BYTES (2 MiB) — written as a
        // long sequence of valid declarations so the response itself parses
        // fine and the error path is exercised by the size cap, not by a
        // CSS parse failure.
        const chunk = ".pad { color: #abcdef; } "; // 25 bytes
        const repeats = (2 * 1024 * 1024 / chunk.len) + 1024;
        var body = try std.ArrayList(u8).initCapacity(arena_allocator, chunk.len * repeats);
        for (0..repeats) |_| body.appendSliceAssumeCapacity(chunk);
        return req.respond(body.items, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    // Bodies are non-empty so that libcurl always reaches the write callback,
    // which is where a headers_only request decides whether to drain or abort.
    // ok.png takes the abort branch, small.png the drain branch; both must
    // behave identically as far as the DOM is concerned.
    if (std.mem.eql(u8, path, "/images/ok.png")) {
        // A real PNG header followed by padding: > HEADERS_ONLY_DRAIN_MAX so
        // the transfer takes the abort branch, but still a picture -- this
        // engine decides `load` vs `error` from the bytes, not the status, so
        // a body of 'x' would answer `error` for a 200.
        const body = try arena_allocator.alloc(u8, 16 * 1024 + 1);
        @memset(body, 'x');
        @memcpy(body[0..ONE_PIXEL_PNG.len], &ONE_PIXEL_PNG);
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
            },
        });
    }

    // startsWith, not eql: a caller can append a query string to get distinct
    // URLs (and so distinct transfers) off this one route.
    if (std.mem.startsWith(u8, path, "/images/small.png")) {
        const body = try arena_allocator.alloc(u8, 1024);
        @memset(body, 'x');
        @memcpy(body[0..ONE_PIXEL_PNG.len], &ONE_PIXEL_PNG);
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
            },
        });
    }

    // No Content-Length: whether the body is small enough to drain can only
    // be decided as it arrives.
    if (std.mem.eql(u8, path, "/images/chunked.png")) {
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "image/svg+xml" },
                },
            },
        });
        try res.writer.writeAll("<svg xmlns=\"http://www.w3.org/2000/svg\"/>");
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/images/404.png")) {
        return req.respond("not here", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/images/500.png")) {
        return req.respond("boom", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/images/redirect.png")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/images/ok.png" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_referer")) {
        // Echo the request's Referer header back as HTML so tests can assert
        // what Referer the navigation sent. Used by the cross-page Referer test.
        var it = req.iterateHeaders();
        var referer: []const u8 = "NONE";
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Referer")) {
                referer = h.value;
                break;
            }
        }
        var html_buf: [512]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf, "<html><body>referer={s}</body></html>", .{referer});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                // Readable cross-origin. `/redirect_cross_echo_referer` sends a
                // same-origin fetch here across an origin boundary, and the CORS
                // check applies to whichever hop answers -- measured on Chrome
                // 151, the `redirect-cross-*` pair of
                // tools/fingerprint/results/b60-cors-chrome.json, where the hop
                // without an Allow-Origin is refused and the one with it is not.
                // Navigations to this route are unaffected either way.
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referer_link.html")) {
        // Page with an anchor link to /echo_referer. The test clicks the link
        // via JS and asserts the resulting page reports Referer = this page.
        return req.respond(
            "<html><body><a id=\"link\" href=\"/echo_referer\">go</a></body></html>",
            .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            },
        );
    }

    if (std.mem.eql(u8, path, "/echo_method")) {
        // Echo the request method back as HTML so tests can assert on what
        // method the navigation used. Used by the Page.reload-replays-POST test.
        const method_name = @tagName(req.head.method);
        var html_buf: [128]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf, "<html><body>method={s}</body></html>", .{method_name});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_body")) {
        // Echo the request body back verbatim, so tests can assert on the bytes
        // a request actually sent rather than just on its status.
        var body_buf: [4096]u8 = undefined;
        const body = if (req.head.method.requestHasBody())
            try req.readerExpectNone(&body_buf).allocRemaining(arena_allocator, .limited(body_buf.len))
        else
            "";
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/zstd")) {
        // A zstd frame of the string "zstd works", produced with `zstd -19`.
        // Embedded rather than compressed here because Zig's std has a zstd
        // decompressor and no compressor -- and the point of the endpoint is to
        // prove the *client* decodes what it advertises: we send zstd in
        // Accept-Encoding on every request (Chrome does), so a server taking us
        // up on it must not produce an unreadable body.
        const zstd_body = [_]u8{
            0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x0a, 0x51, 0x00, 0x00, 0x7a, 0x73, 0x74,
            0x64, 0x20, 0x77, 0x6f, 0x72, 0x6b, 0x73, 0xd2, 0x0a, 0x70, 0xde,
        };
        return req.respond(&zstd_body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Content-Encoding", .value = "zstd" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_headers")) {
        // Echo every request header back as "name: value" lines, so tests
        // can assert on the headers a request actually sent.
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;
        var it = req.iterateHeaders();
        while (it.next()) |header| {
            const line = try std.fmt.bufPrint(buf[pos..], "{s}: {s}\n", .{ header.name, header.value });
            pos += line.len;
        }
        return req.respond(buf[0..pos], .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                // Readable cross-origin, so a test can look at the headers a
                // request carried across an origin hop. Without it the CORS
                // response check refuses the body and the only thing the test
                // could assert is that it failed.
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/set_cookie")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "Set-Cookie", .value = "lp_hidden=1; Path=/set_cookie_scope" },
                .{ .name = "X-Visible", .value = "yes" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_same_echo_headers")) {
        // Same-origin 302 to /echo_headers: Authorization must survive the hop.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_headers" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_cross_echo_headers")) {
        // 302 to /echo_headers on the localhost alias — a cross-origin hop, so
        // Authorization must be stripped before the request is re-sent.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/echo_headers" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_same_echo_referer")) {
        // Same-origin 302 to /echo_referer: the full Referer must survive the hop.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_referer" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_cross_echo_referer")) {
        // 302 to /echo_referer on the localhost alias — a cross-origin hop, so
        // the Referer must be recomputed at the redirect (stripped to origin
        // under the default policy) rather than re-sent in full.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/echo_referer" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_cross_bare")) {
        // The same hop with nothing permitting it at the other end. A page that
        // fetches this same-origin URL still has to be refused, because the CORS
        // check belongs to the response that answered, not to the URL asked for.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/cors/bare" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_to_echo")) {
        // 302 to /echo_method. Used by the Page.reload-after-redirect test to
        // confirm a POST→302→GET chain doesn't replay POST on reload.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_method" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_nav_timing")) {
        // 302 to a document, staying on this origin. Navigation Timing exposes
        // a redirect chain only when every hop passes the timing allow check,
        // so this is the hop Chrome reports (redirectCount 1, measured against
        // Chrome 151 on tools/fingerprint/scratch/redirect-server.mjs).
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/src/browser/tests/mcp_nav.html" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_nav_timing_cross")) {
        // The same hop onto the localhost alias, which is a different origin on
        // the same server. Chrome hides this one: redirectCount, redirectStart
        // and redirectEnd all read 0 while fetchStart still moves past it
        // (measured, same sitting).
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/src/browser/tests/mcp_nav.html" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/download/report.csv")) {
        // A file download: Content-Disposition: attachment drives the
        // Browser.setDownloadBehavior path (issue #2701).
        return req.respond("col1,col2\nhello,world\n42,1337\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/csv" },
                .{ .name = "Content-Disposition", .value = "attachment; filename=\"report.csv\"" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/src/browser/tests/")) {
        if (std.mem.indexOf(u8, path, "delay_ms=")) |pos| {
            const digits_start = pos + "delay_ms=".len;
            var end = digits_start;
            while (end < path.len and std.ascii.isDigit(path[end])) : (end += 1) {}
            const delay_ms = std.fmt.parseInt(u64, path[digits_start..end], 10) catch 0;
            lp.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
        }
        // Cross-origin isolation is negotiated in response headers, so a test
        // file cannot declare its own. Any test whose name starts with
        // `cross_origin_isolated` is served with the pair that grants it --
        // which is the pair the Cloudflare interstitial is served with.
        if (std.mem.indexOf(u8, path, "cross_origin_isolated") != null) {
            return TestHTTPServer.sendFileWithHeaders(req, path[1..], &.{
                .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
                .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
            });
        }
        // strip off leading / so that it's relative to CWD
        return TestHTTPServer.sendFile(req, path[1..]);
    }

    // How many times the server was actually asked for `/served/counted.png`.
    // The count is the only way to see the document's memory cache from a
    // page: a reused resource fires `load` and reports a size exactly like a
    // fetched one, and the difference lives on the wire. Measured on Chrome
    // 151 (scratch/b69/img-cache-fixture.mjs), a second <img> for a URL that
    // already loaded costs zero requests -- and Cloudflare's challenge loads
    // its `ci` PNG twice, so this engine asking twice is visible to it.
    if (std.mem.eql(u8, path, "/served/counted.png")) {
        _ = counted_png_hits.fetchAdd(1, .monotonic);
        return req.respond(&ONE_PIXEL_PNG, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
            },
        });
    }
    if (std.mem.eql(u8, path, "/served/counted-font.ttf")) {
        _ = counted_font_hits.fetchAdd(1, .monotonic);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const font = font_file.synthesize(arena.allocator(), 1000, 500, 800, 200) catch
            return req.respond("", .{});
        return req.respond(font, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "font/ttf" }},
        });
    }
    if (std.mem.eql(u8, path, "/served/counted-font-hits")) {
        var buf: [16]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{d}", .{counted_font_hits.load(.monotonic)}) catch unreachable;
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/served/counted-hits")) {
        var buf: [16]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{d}", .{counted_png_hits.load(.monotonic)}) catch unreachable;
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
                // The count has to be read fresh every time, or the second
                // read would answer the first read's number.
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/served/compressed.js")) {
        return req.respond(&GZIPPED_SCRIPT, .{
            .extra_headers = &.{
                // The legacy JavaScript MIME type, which is what Cloudflare
                // serves api.js as. A resource entry reports `text/javascript`
                // for it -- see Mime.isJavaScriptType.
                .{ .name = "Content-Type", .value = "application/javascript; charset=UTF-8" },
                .{ .name = "Content-Encoding", .value = "gzip" },
            },
        });
    }

    // Responses whose bytes, declared type and status deliberately disagree:
    // one per row of the Chrome 151 measurement in
    // `tools/fingerprint/img-sniff.mjs`. What settles an `<img>`'s event is the
    // body, so each of these pins one input that gets no say. Registered ahead
    // of the image catch-all below, which would otherwise win on the extension.
    {
        const SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"></svg>";
        const Fixture = struct {
            path: []const u8,
            body: []const u8,
            status: std.http.Status = .ok,
            // null omits the header entirely, which is a case of its own.
            content_type: ?[]const u8,
        };
        const fixtures = [_]Fixture{
            // A page in an image's clothing, twice over.
            .{ .path = "/served/html-bytes.png", .content_type = "text/html", .body = "<html><body>not a picture</body></html>" },
            .{ .path = "/served/html-as-png.png", .content_type = "image/png", .body = "<html><body>not a picture</body></html>" },
            // Real bytes the header disowns, or never claims.
            .{ .path = "/served/octet-stream.png", .content_type = "application/octet-stream", .body = &ONE_PIXEL_PNG },
            .{ .path = "/served/no-content-type.png", .content_type = null, .body = &ONE_PIXEL_PNG },
            // Real bytes behind a failing status.
            .{ .path = "/served/png-bytes-404.png", .status = .not_found, .content_type = "image/png", .body = &ONE_PIXEL_PNG },
            // Not enough bytes to carry a signature.
            .{ .path = "/served/truncated.png", .content_type = "image/png", .body = ONE_PIXEL_PNG[0..4] },
            // Pictures with an intrinsic size worth naming.
            .{ .path = "/served/intrinsic-7x3.png", .content_type = "image/png", .body = &PNG_7X3 },
            .{ .path = "/served/intrinsic-5x9.gif", .content_type = "image/gif", .body = &GIF_5X9 },
            // SVG, the one image type that is answered from the header.
            .{ .path = "/served/vector.svg", .content_type = "image/svg+xml", .body = SVG },
            // Four shapes of SVG root, one per rule Chrome was measured on
            // (probe `scratch/b90/expr-img-geometry.js`).
            .{ .path = "/served/svg-sized.svg", .content_type = "image/svg+xml", .body = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"6\"></svg>" },
            .{ .path = "/served/svg-bare.svg", .content_type = "image/svg+xml", .body = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>" },
            .{ .path = "/served/svg-one-axis.svg", .content_type = "image/svg+xml", .body = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\"></svg>" },
            .{ .path = "/served/svg-ratio.svg", .content_type = "image/svg+xml", .body = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" viewBox=\"0 0 20 5\"></svg>" },
            .{ .path = "/served/svg-as-text.svg", .content_type = "text/plain", .body = SVG },
        };
        for (fixtures) |f| {
            if (std.mem.eql(u8, path, f.path) == false) {
                continue;
            }
            const content_type = f.content_type orelse {
                return req.respond(f.body, .{ .status = f.status });
            };
            return req.respond(f.body, .{
                .status = f.status,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = content_type },
                },
            });
        }
    }

    // Everything under /wire/ answers 200 with a token body, whatever the
    // path. The subresource-census tests assert that a request HAPPENED --
    // that is the whole gap they cover (tools/fingerprint/wire-census.mjs) --
    // and nothing in the engine decodes a stylesheet's font, an <object>'s
    // data or a <track>'s cues, so a fixture per path would be a fixture per
    // path for bytes nobody reads.
    if (std.mem.startsWith(u8, path, "/wire/")) {
        const without_query = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
        const content_type = if (std.mem.endsWith(u8, without_query, ".css"))
            "text/css"
        else if (std.mem.endsWith(u8, without_query, ".png"))
            "image/png"
        else if (std.mem.endsWith(u8, without_query, ".vtt"))
            "text/vtt"
        else if (std.mem.endsWith(u8, without_query, ".webmanifest"))
            "application/manifest+json"
        else
            "application/octet-stream";
        return req.respond("x", .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = content_type }},
        });
    }

    // `<img src>` is fetched for real now (see `Frame.loadImage`), so any test
    // page carrying an image reaches this handler. Nothing decodes the bytes,
    // so one placeholder answers every image path rather than each test having
    // to register a fixture.
    {
        const without_query = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
        for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".svg" }) |ext| {
            if (std.mem.endsWith(u8, without_query, ext)) {
                return req.respond(&ONE_PIXEL_PNG, .{
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "image/png" },
                    },
                });
            }
        }
    }

    // The same bargain as the image placeholder, for the other kinds of
    // subresource that are now fetched-and-discarded: a media element's
    // source, a `<track>`'s cues, a plugin's data, a `@font-face` file. None
    // of it is decoded (frame/markup_resources.zig, frame/style_resources.zig)
    // so a fixture per path would be a fixture for bytes nobody reads. The
    // `unreachable` below still catches a typo'd document or script path.
    // One route that answers with a real font, so the metrics read out of a
    // downloaded face can be tested without a binary fixture in the tree.
    // 1000 units per em and every glyph 500 units wide, which makes each
    // character exactly half the font size: 20px text is 10px per character.
    // Built by font_file.synthesize, the same function its unit tests use.
    if (std.mem.startsWith(u8, path, "/synth-font.ttf")) {
        // `?delay=<ms>` holds the response back, which is the only way to put a
        // font transfer reliably in flight at the `load` event -- and that is
        // what makes the `document.fonts.ready` assertion discriminating rather
        // than a race it happens to win.
        if (std.mem.indexOf(u8, path, "delay=")) |at| {
            const rest = path[at + 6 ..];
            const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
            const ms = std.fmt.parseInt(u64, rest[0..end], 10) catch 0;
            if (ms > 0 and ms <= 2000) lp.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const font = font_file.synthesize(arena.allocator(), 1000, 500, 800, 200) catch
            return req.respond("", .{});
        return req.respond(font, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "font/ttf" }},
        });
    }

    // The same font with an `opsz` variation axis. Every glyph is still 500
    // units at the axis default (14) but 400 at its maximum (16), so a 16px
    // run says outright whether the axis was pinned to the font size the way
    // `font-optical-sizing: auto` asks for: 6.4px per character if it was,
    // 8px if the file's `hmtx` was taken at face value.
    if (std.mem.startsWith(u8, path, "/synth-var-font.ttf")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const font = font_file.synthesizeVariable(arena.allocator(), 1000, 500, 800, 200, .{
            .tag = "opsz",
            .min = 8,
            .default = 14,
            .max = 16,
            .delta_at_max = -100,
        }) catch return req.respond("", .{});
        return req.respond(font, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "font/ttf" }},
        });
    }

    // A variable font that kerns `mm` out of its own `GPOS`, with the pair's
    // adjustment riding the `opsz` axis through a Device table in variation
    // form. Advances are flat at 500 units so a run says nothing but what the
    // pairs charge: `opsz` 8..40 with the default at the minimum puts a 16px
    // instance a quarter of the way up, where the pair is -20 + 0.25*5 =
    // -18.75 and ten characters sum to 4831.25 units -- a fractional total,
    // which is the only way to see which way the run gets rounded.
    if (std.mem.startsWith(u8, path, "/synth-kern-font.ttf")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const font = font_file.synthesizeVariable(arena.allocator(), 1000, 500, 800, 200, .{
            .tag = "opsz",
            .min = 8,
            .default = 8,
            .max = 40,
            .delta_at_max = 0,
            .kern = .{ .first = 'm', .second = 'm', .x_advance = -20, .delta_at_max = 5 },
        }) catch return req.respond("", .{});
        return req.respond(font, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "font/ttf" }},
        });
    }

    {
        const without_query = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
        for ([_][]const u8{ ".mp3", ".mp4", ".webm", ".ogg", ".wav", ".vtt", ".swf", ".woff2", ".woff", ".ttf", ".otf" }) |ext| {
            if (std.mem.endsWith(u8, without_query, ext)) {
                return req.respond("", .{
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }},
                });
            }
        }
    }

    std.debug.print("TestHTTPServer was asked to serve an unknown file: {s}\n", .{path});

    unreachable;
}

/// Declares the log lines a test expects to emit: one entry per line, so
/// `&.{ .js, .js, .http }` covers two `js` lines and one `http` line.
pub const expectLog = log.expectLog;

/// Suppresses every line from `scopes` for the rest of the test.
pub fn silenceLog(comptime scopes: []const log.Scope) void {
    inline for (scopes) |scope| {
        log.opts.scope_enabled[@intFromEnum(scope)] = false;
    }
}

test "tests:afterEach" {
    defer reset();
    const unmet = log.resetTestState();
    if (@import("root").hasSubfilter()) {
        // only part of the test ran, so expectations about what it logs
        // don't hold.
        return;
    }

    var failed = false;
    for (unmet, 0..) |count, i| {
        if (count == 0) {
            continue;
        }
        failed = true;
        const scope: log.Scope = @enumFromInt(i);
        std.debug.print("expected {d} more {s} log line(s)\n", .{ count, @tagName(scope) });
    }

    if (failed) {
        return error.UnmetLogExpectation;
    }
}
