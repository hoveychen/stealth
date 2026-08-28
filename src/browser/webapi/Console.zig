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
const js = @import("../js/js.zig");

const Notification = @import("../../Notification.zig");
const Performance = @import("Performance.zig");

const logger = lp.log;

const Console = @This();

_timers: std.StringHashMapUnmanaged(u64) = .{},
_counts: std.StringHashMapUnmanaged(u64) = .{},

pub const init: Console = .{};

/// Chrome's console formatter, run for its SIDE EFFECTS.
///
/// `console.log('%d', obj)` prints somewhere a page cannot read, but `%d` has to
/// turn its argument into a number, and that conversion calls the object's own
/// `Symbol.toPrimitive` and `toString`. So an object with recording accessors
/// learns whether the conversion happened -- which makes this a fingerprint the
/// page collects without devtools ever being open, and Cloudflare's
/// cf-scrapingcourse challenge collects exactly it: a sweep of `%c%d` across
/// every console method, twice each.
///
/// This engine coerced nothing, so the sweep came back untouched 30 times over
/// (six methods x five specifiers, probes/expr-b85-console-probe.js).
///
/// Every rule below is measured against Chrome 151, not taken from the Console
/// Standard, and four of them are things a from-the-spec version gets wrong
/// (probes/expr-b85-console-format-edges.js, 17 cases):
///
///   * `%s` `%d` `%i` `%f` convert their argument. The footprint is
///     `Symbol.toPrimitive` then `toString` -- a STRING hint, so `%d` does not
///     reach `valueOf` the way `Number(x)` would.
///   * `%o` `%O` consume an argument and convert nothing.
///   * **`%c` consumes its style argument and does NOT convert it.** The obvious
///     implementation stringifies a style, and Chrome does not.
///   * `%%` is a literal and consumes nothing, and a specifier after it still
///     converts -- so the scan cannot stop at the first `%`.
///   * an unknown specifier (`%q`, `%j`, `%S`) consumes nothing, and neither
///     does a specifier with no argument left.
///   * a first argument that is not a string means no formatting at all, so
///     nothing is converted -- including that argument.
///
/// And which methods format at all is measured rather than assumed: `group` and
/// `assert` do, and **`dir` and `table` do not**.
///
/// A `toString` that throws PROPAGATES, and only out of the specifiers that
/// convert -- measured, and the opposite of the intuitive choice. The `catch`
/// below takes the Zig error and leaves v8's pending exception scheduled, which
/// is what carries it out to the caller; `%o` and a plain argument never convert
/// and so never raise. Chrome: `console.log('%d', {toString(){throw}})` throws,
/// `console.log('%o', same)` does not, and a throwing `valueOf` is never reached
/// at all (probes/expr-b85-console-throwing-arg.js).
/// Returns true when a conversion raised, in which case v8 has an exception
/// scheduled and the caller must return at once. That matters for `error` and
/// `trace` specifically: both capture a stack trace, and capturing one CLEARS
/// the pending exception -- which swallowed the throw that Chrome propagates.
fn applyFormat(values: []js.Value) bool {
    if (values.len < 2) return false;
    const first = values[0].isString() orelse return false;
    const fmt = first.toSlice() catch return false;

    var arg: usize = 1;
    var i: usize = 0;
    while (i + 1 < fmt.len) {
        if (fmt[i] != '%') {
            i += 1;
            continue;
        }
        const specifier = fmt[i + 1];
        i += 2;
        switch (specifier) {
            // A literal percent. Consumes nothing, and the scan continues --
            // `100%% %d` still converts the `%d` argument.
            '%' => {},
            // Converted, which is the whole point of this function.
            's', 'd', 'i', 'f' => {
                if (arg == values.len) return false;
                _ = values[arg].toString() catch return true;
                arg += 1;
            },
            // Consumed, not converted. `%c` is here because Chrome measurably
            // leaves the style argument alone.
            'o', 'O', 'c' => {
                if (arg == values.len) return false;
                arg += 1;
            },
            // Not a specifier: consumes nothing.
            else => {},
        }
    }
    return false;
}

fn dispatchConsoleMessage(values: []js.Value, console_type: Notification.ConsoleMessageType, exec: *js.Execution) void {
    const notification = exec.session.notification;
    const ts = lp.datetime.timestamp(.boot);

    notification.dispatch(.console_message, &.{
        .source = .javascript,
        .type = console_type,
        .values = values,
        .timestamp = ts,
        .js_context = exec.js,
    });

    notification.dispatch(.runtime_console_message, &.{
        .source = .javascript,
        .type = console_type,
        .values = values,
        .timestamp = ts,
        .js_context = exec.js,
    });
}

pub fn trace(values: []js.Value, exec: *js.Execution) !void {
    if (applyFormat(values)) return;
    logger.debug(.js, "console.trace", .{
        .stack = exec.js.local.?.stackTrace() catch "???",
        .args = ValueWriter{ .values = values },
    });
    dispatchConsoleMessage(values, .trace, exec);
}

pub fn debug(values: []js.Value, exec: *js.Execution) void {
    if (applyFormat(values)) return;
    logger.debug(.js, "console.debug", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .debug, exec);
}

pub fn info(values: []js.Value, exec: *js.Execution) void {
    if (applyFormat(values)) return;
    logger.info(.js, "console.info", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .info, exec);
}

pub fn log(values: []js.Value, exec: *js.Execution) void {
    if (applyFormat(values)) return;
    logger.info(.js, "console.log", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .log, exec);
}

pub fn warn(values: []js.Value, exec: *js.Execution) void {
    if (applyFormat(values)) return;
    logger.warn(.js, "console.warn", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .warning, exec);
}

pub fn clear() void {}

pub fn assert(assertion_: ?js.Value, values: []js.Value, exec: *js.Execution) void {
    if (assertion_) |assertion| {
        if (assertion.toBool()) {
            return;
        }
    }
    // `assert`'s format string is its SECOND argument, so `values` -- which
    // already excludes the assertion -- is exactly what the formatter takes.
    if (applyFormat(values)) return;
    logger.warn(.js, "console.assert", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .warning, exec);
}

pub fn @"error"(values: []js.Value, exec: *js.Execution) void {
    if (applyFormat(values)) return;
    logger.warn(.js, "console.error", .{ValueWriter{ .values = values, .stack = exec.js.local.?.stackTrace() catch |err| @errorName(err) orelse "???" }});
    dispatchConsoleMessage(values, .@"error", exec);
}

pub fn table(data: ?js.Value, columns: ?js.Value) void {
    logger.info(.js, "console.table", .{ .data = data, .columns = columns });
}

/// console.profile / console.profileEnd / console.timeStamp drive the devtools
/// CPU profiler and performance timeline. Chrome returns undefined from all
/// three with or without arguments (measured); there is nothing to drive here.
pub fn profile(_: ?[]const u8) void {}

pub fn profileEnd(_: ?[]const u8) void {}

pub fn timeStamp(_: ?[]const u8) void {}

/// console.dir / console.dirxml. Chrome logs the value like console.log does
/// and returns undefined; the interactive object/DOM tree they draw in devtools
/// has no headless equivalent. `dir` takes only `(item, options)`, so anything
/// past the first argument is dropped the way Chrome drops it.
pub fn dir(item_: ?js.Value, _: ?js.Value, exec: *js.Execution) void {
    var buf: [1]js.Value = undefined;
    const values: []js.Value = if (item_) |item| blk: {
        buf[0] = item;
        break :blk buf[0..1];
    } else buf[0..0];
    logger.info(.js, "console.dir", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .dir, exec);
}

pub fn dirxml(values: []js.Value, exec: *js.Execution) void {
    logger.info(.js, "console.dirxml", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .dirxml, exec);
}

pub fn count(label_: ?[]const u8, exec: *js.Execution) !void {
    const self = exec.console();
    const label = label_ orelse "default";
    const gop = try self._counts.getOrPut(exec.arena, label);

    var current: u64 = 0;
    if (gop.found_existing) {
        current = gop.value_ptr.*;
    } else {
        gop.key_ptr.* = try exec.arena.dupe(u8, label);
    }

    const c = current + 1;
    gop.value_ptr.* = c;

    logger.info(.js, "console.count", .{ .label = label, .count = c });
}

pub fn countReset(label_: ?[]const u8, exec: *js.Execution) !void {
    const self = exec.console();
    const label = label_ orelse "default";
    const kv = self._counts.fetchRemove(label) orelse {
        logger.info(.js, "console.countReset", .{ .label = label, .err = "invalid label" });
        return;
    };
    logger.info(.js, "console.countReset", .{ .label = label, .count = kv.value });
}

pub fn time(label_: ?[]const u8, exec: *js.Execution) !void {
    const self = exec.console();
    const label = label_ orelse "default";
    const gop = try self._timers.getOrPut(exec.arena, label);

    if (gop.found_existing) {
        logger.info(.js, "console.time", .{ .label = label, .err = "duplicate timer" });
        return;
    }
    gop.key_ptr.* = try exec.arena.dupe(u8, label);
    gop.value_ptr.* = lp.datetime.timestamp(.boot);
}

pub fn timeLog(label_: ?[]const u8, exec: *js.Execution) void {
    const self = exec.console();
    const elapsed = lp.datetime.timestamp(.boot);
    const label = label_ orelse "default";
    const start = self._timers.get(label) orelse {
        logger.info(.js, "console.timeLog", .{ .label = label, .err = "invalid timer" });
        return;
    };
    logger.info(.js, "console.timeLog", .{ .label = label, .elapsed = elapsed - start });
}

pub fn timeEnd(label_: ?[]const u8, exec: *js.Execution) void {
    const self = exec.console();
    const elapsed = lp.datetime.timestamp(.boot);
    const label = label_ orelse "default";
    const kv = self._timers.fetchRemove(label) orelse {
        logger.info(.js, "console.timeEnd", .{ .label = label, .err = "invalid timer" });
        return;
    };

    logger.info(.js, "console.timeEnd", .{ .label = label, .elapsed = elapsed - kv.value });
}

pub fn group(values: []js.Value) void {
    if (applyFormat(values)) return;
    logger.info(.js, "console.group", .{ValueWriter{ .values = values }});
}

pub fn groupCollapsed(values: []js.Value) void {
    // Measured for `group`; `groupCollapsed` is assumed to match it rather than
    // measured on its own, which is the one rule here that is not read off
    // Chrome.
    if (applyFormat(values)) return;
    logger.info(.js, "console.groupCollapsed", .{ValueWriter{ .values = values }});
}

pub fn groupEnd() void {}

/// The members of the object `console.context(name)` hands back, in the order
/// Chrome lists them. Note `dirXml`: the same operation is spelled with a
/// capital X here and lower case on `console` itself (measured).
const CONTEXT_MEMBERS = [_][:0]const u8{
    "dir",        "dirXml",  "table",      "groupEnd",  "clear",          "count",
    "countReset", "profile", "profileEnd", "debug",     "error",          "info",
    "log",        "warn",    "trace",      "group",     "groupCollapsed", "assert",
    "time",       "timeLog", "timeEnd",    "timeStamp",
};

/// console.context(name) is a devtools affordance: a fresh, plain object -- no
/// brand, Object.prototype as its proto -- carrying its own copy of the 22
/// logging operations, each an own writable/enumerable/configurable function of
/// length 1 (all measured on Chrome 150). The copies log but do not feed the
/// CDP console stream: a named context is not the page's console.
pub fn context(_: ?[]const u8, exec: *js.Execution) !js.Object {
    const local = exec.js.local.?;
    const object = local.newObject();
    inline for (CONTEXT_MEMBERS) |name| {
        const func = try local.newNamedCallback(name, 1, contextMember(name), exec.js);
        _ = try object.set(name, func, .{});
    }
    return object;
}

fn contextMember(comptime name: [:0]const u8) fn (*js.Context, []js.Value) void {
    return struct {
        fn call(_: *js.Context, values: []js.Value) void {
            logger.info(.js, "console.context." ++ name, .{ValueWriter{ .values = values }});
        }
    }.call;
}

/// console.createTask(name) returns an async-stack-tagging token: a plain
/// object whose single own `run` method invokes its callback and hands back the
/// result. Both argument checks are a plain Error in Chrome, not a TypeError.
///
/// The name is taken strictly: Chrome runs no ToString on it, so a number, a
/// `new String('t')` wrapper and an object with a `toString` are all rejected
/// exactly like a missing or empty one (measured, probe-g8f). iphey's devtools
/// probes call console members with an object argument, so coercing here would
/// hand back a task where Chrome throws.
pub fn createTask(name_: ?js.Value, exec: *js.Execution) !js.Object {
    const local = exec.js.local.?;
    const too_short = if (name_) |name| blk: {
        const str = name.isString() orelse break :blk true;
        break :blk str.len() == 0;
    } else true;
    if (too_short) {
        return throwError("First argument must be a non-empty string.", local);
    }

    const task = local.newObject();
    _ = try task.set("run", try local.newNamedCallback("run", 0, taskRun, exec.js), .{});
    return task;
}

fn taskRun(ctx: *js.Context, callback_: ?js.Function) !js.Value {
    const local = ctx.local.?;
    const callback = callback_ orelse {
        return throwError("First argument must be a function.", local);
    };
    return callback.call(js.Value, .{});
}

pub fn getMemory(exec: *const js.Execution) !*Performance.MemoryInfo {
    return Performance.memoryInfo(exec);
}

pub fn setMemory(_: js.Value) void {}

fn throwError(message: []const u8, local: *const js.Local) anyerror {
    const isolate = local.isolate;
    _ = isolate.throwException(isolate.createError(message));
    return error.JsException;
}

const ValueWriter = struct {
    values: []js.Value,
    stack: ?[]const u8 = null,

    pub fn format(self: ValueWriter, writer: *std.Io.Writer) !void {
        for (self.valuesToLog(), 1..) |value, i| {
            try writer.print("\n  arg({d}): {f}", .{ i, value });
        }
        if (self.stack) |s| {
            try writer.print("\n stack: {s}", .{s});
        }
    }

    pub fn logFmt(self: ValueWriter, _: []const u8, writer: anytype) !void {
        var buf: [32]u8 = undefined;
        for (self.valuesToLog(), 0..) |value, i| {
            const name = try std.fmt.bufPrint(&buf, "param.{d}", .{i});
            try writer.write(name, value);
        }
    }

    pub fn jsonStringify(self: ValueWriter, writer: *std.json.Stringify) !void {
        try writer.beginArray();
        for (self.valuesToLog()) |value| {
            try writer.write(value);
        }
        return writer.endArray();
    }

    fn valuesToLog(self: ValueWriter) []js.Value {
        if (lp.build_config.wpt_extensions) {
            // A few WPT tests print HUGE arrays, it's at best, annoying when
            // running it locally
            return self.values[0..@min(self.values.len, 100)];
        }
        return self.values;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Console);

    pub const Meta = struct {
        pub const name = "Console";

        // A namespace is branded with its own identifier, which for console is
        // lower case. Measured on Chrome 150:
        //   Object.prototype.toString.call(console) -> '[object console]'
        pub const to_string_tag = "console";

        // Per the console spec, members are own properties of the namespace
        // object, so Object.entries(console) returns them.
        pub const own_properties = true;

        // A namespace has no interface object: Chrome exposes `console` and no
        // `Console` (measured -- globalThis.Console is undefined there, while
        // we were handing detectors an extra global nothing else has).
        pub const no_interface_object = true;

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is property order. This is Chrome 150's, measured with
    // Object.getOwnPropertyNames(console) -- it is neither alphabetical nor the
    // Console Standard's IDL order, so it can only be copied.
    //
    // Every member is `.static`, because console is a namespace, not an
    // interface, and Chrome's members do no brand check on `this`:
    // `console.log.call(undefined, x)`, `const f = console.log; f(x)` and
    // `Object(console.log)(x)` all log (measured on a headed Chrome 150,
    // probe-g8a). iphey's `dep-reg-to-string` devtools probe takes the last of
    // those shapes, and answering it `Illegal invocation` was tripping the
    // detector. `.static` means no receiver to unwrap and no v8 Signature to
    // fail; the two stateful tables are reached through `exec.console()`
    // instead of through `self`.
    //
    // Upstream also exposes `exception` as an alias of `error`; Chrome has no
    // such member, so it is deliberately not re-added here (see the
    // `no_exception_member` block of tests/console/console.html).
    //
    // Every member also reports length 0, because a variadic
    // argument contributes nothing to a function's length and every console
    // operation but `context` is variadic (measured: even console.assert, whose
    // IDL declares a required `condition`, is 0).
    pub const debug = bridge.function(Console.debug, .{ .static = true, .arity = 0 });
    pub const @"error" = bridge.function(Console.@"error", .{ .static = true, .arity = 0 });
    pub const info = bridge.function(Console.info, .{ .static = true, .arity = 0 });
    pub const log = bridge.function(Console.log, .{ .static = true, .arity = 0 });
    pub const warn = bridge.function(Console.warn, .{ .static = true, .arity = 0 });
    pub const dir = bridge.function(Console.dir, .{ .static = true, .arity = 0 });
    pub const dirxml = bridge.function(Console.dirxml, .{ .static = true, .arity = 0 });
    pub const table = bridge.function(Console.table, .{ .static = true, .arity = 0 });
    pub const trace = bridge.function(Console.trace, .{ .static = true, .arity = 0 });
    pub const group = bridge.function(Console.group, .{ .static = true, .arity = 0 });
    pub const groupCollapsed = bridge.function(Console.groupCollapsed, .{ .static = true, .arity = 0 });
    pub const groupEnd = bridge.function(Console.groupEnd, .{ .static = true, .arity = 0 });
    pub const clear = bridge.function(Console.clear, .{ .static = true, .arity = 0, .noop = true });
    pub const count = bridge.function(Console.count, .{ .static = true, .arity = 0 });
    pub const countReset = bridge.function(Console.countReset, .{ .static = true, .arity = 0 });
    pub const assert = bridge.function(Console.assert, .{ .static = true, .arity = 0 });
    pub const profile = bridge.function(Console.profile, .{ .static = true, .arity = 0, .noop = true });
    pub const profileEnd = bridge.function(Console.profileEnd, .{ .static = true, .arity = 0, .noop = true });
    pub const time = bridge.function(Console.time, .{ .static = true, .arity = 0 });
    pub const timeLog = bridge.function(Console.timeLog, .{ .static = true, .arity = 0 });
    pub const timeEnd = bridge.function(Console.timeEnd, .{ .static = true, .arity = 0 });
    pub const timeStamp = bridge.function(Console.timeStamp, .{ .static = true, .arity = 0, .noop = true });
    pub const context = bridge.function(Console.context, .{ .static = true, .arity = 1 });
    pub const createTask = bridge.function(Console.createTask, .{ .static = true, .arity = 0 });

    // console.memory is the same MemoryInfo performance.memory hands out (the
    // two share a prototype, measured), and like it a fresh object per read.
    // It is one of the few console members that is an accessor, and it has a
    // setter, which Chrome silently ignores.
    pub const memory = bridge.accessor(Console.getMemory, Console.setMemory, .{ .static = true, .anonymous = true });
};

const testing = @import("../../testing.zig");
test "WebApi: Console" {
    testing.expectLog(&.{ .js, .js, .js });
    try testing.htmlRunner("console", .{});
}
