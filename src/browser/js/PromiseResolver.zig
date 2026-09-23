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

const lp = @import("lightpanda");

const js = @import("js.zig");

const DOMException = @import("../webapi/DOMException.zig");

const v8 = js.v8;
const log = lp.log;

const PromiseResolver = @This();

local: *const js.Local,
handle: *const v8.PromiseResolver,

pub fn init(local: *const js.Local) PromiseResolver {
    return .{
        .local = local,
        .handle = v8.v8__Promise__Resolver__New(local.handle).?,
    };
}

pub fn promise(self: PromiseResolver) js.Promise {
    return .{
        .local = self.local,
        .handle = v8.v8__Promise__Resolver__GetPromise(self.handle).?,
    };
}

pub fn resolve(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._resolve(value) catch |err| {
        log.err(.bug, "resolve", .{ .source = source, .err = err, .persistent = false });
    };
}

fn _resolve(self: PromiseResolver, value: anytype) !void {
    const local = self.local;
    const js_val = try local.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Resolve(self.handle, self.local.handle, js_val.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToResolvePromise;
    }
    checkpoint(local);
}

// HTML's microtask checkpoint only happens once the JS stack is empty, and a
// non-zero call_depth says it is not: some script called into us and is waiting
// for this function to return. Draining there runs reactions in the middle of
// that script, which is visible -- a promise settled by a synchronous API and
// caught on the very next line gets reported as unhandled, because the
// checkpoint that decides "unhandled" has already been and gone by the time the
// catch is attached. Chrome reports none of those; measured against headless
// Chrome 151, the Akamai sensor's nine permissions.query calls produced six
// unhandledrejection events here and zero there.
//
// At call_depth 0 the settle comes from the outside -- a timer, an event, a
// finished request -- and every one of those entry points runs a checkpoint of
// its own once it is done, so the queue is not left sitting.
fn checkpoint(local: *const js.Local) void {
    if (local.ctx.call_depth > 0) {
        return;
    }
    local.runMicrotasks();
}

pub fn reject(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._reject(value) catch |err| {
        log.err(.bug, "reject", .{ .source = source, .err = err, .persistent = false });
    };
}

pub const RejectError = union(enum) {
    /// Not to be confused with `DOMException`; this is bare `Error`.
    generic_error: []const u8,
    range_error: []const u8,
    reference_error: []const u8,
    syntax_error: []const u8,
    type_error: []const u8,
    /// DOM exceptions are unknown to V8, belongs to web standards. A non-null
    /// `message` overrides the code's stock text, the way `Context.fail` does
    /// for a synchronous throw -- some of Blink's rejections carry a sentence
    /// of their own ("screen.orientation.lock() is not available on this
    /// device."). It has to outlive the call, so a literal or something on the
    /// context arena.
    dom_exception: struct { err: anyerror, message: ?[]const u8 = null },
};

/// Rejects the promise w/ an error object.
pub fn rejectError(
    self: PromiseResolver,
    comptime source: []const u8,
    err: RejectError,
) void {
    const handle = switch (err) {
        .generic_error => |msg| self.local.isolate.createError(msg),
        .range_error => |msg| self.local.isolate.createRangeError(msg),
        .reference_error => |msg| self.local.isolate.createReferenceError(msg),
        .syntax_error => |msg| self.local.isolate.createSyntaxError(msg),
        .type_error => |msg| self.local.isolate.createTypeError(msg),
        // "Exceptional".
        .dom_exception => |exception| {
            // An error name the table does not carry is a bug in the caller,
            // and it used to be a fatal one: `orelse unreachable` took the
            // whole process down from inside a promise rejection, which is a
            // place any page can reach. `requestPointerLock` spelled its error
            // `WrongDocumentError` against a table that has `WrongDocument`,
            // so one call crashed the engine. Rejecting with the generic
            // DOMException instead loses the name and keeps the browser, and
            // the log line names the caller to fix.
            var dom_exception = DOMException.fromError(exception.err) orelse blk: {
                log.err(.bug, "rejectDomException unmapped", .{ .source = source, .err = exception.err });
                break :blk DOMException{ ._code = .invalid_state_error };
            };
            dom_exception._custom_message = exception.message;
            self._reject(dom_exception) catch |reject_err| {
                log.err(.bug, "rejectDomException", .{ .source = source, .err = reject_err, .persistent = false });
            };
            return;
        },
    };

    self._reject(js.Value{ .handle = handle, .local = self.local }) catch |reject_err| {
        log.err(.bug, "rejectError", .{ .source = source, .err = reject_err, .persistent = false });
    };
}

fn _reject(self: PromiseResolver, value: anytype) !void {
    const local = self.local;
    const js_val = try local.zigValueToJs(value, .{});
    try self.rejectValue(js_val);
    checkpoint(local);
}

/// Rejects with an already-built JS value, never running a microtask
/// checkpoint. `reject` and `rejectError` skip the checkpoint too whenever the
/// calling script is still on the stack; this one skips it unconditionally.
pub fn rejectValue(self: PromiseResolver, value: js.Value) !void {
    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Reject(self.handle, self.local.handle, value.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToRejectPromise;
    }
}

pub fn persist(self: PromiseResolver) !Global {
    return .{ .slot = try js.newTrackedSlot(self.local.ctx, self.handle) };
}

pub const Global = struct {
    slot: *js.GlobalSlot,

    pub fn deinit(self: Global) void {
        self.slot.release();
    }

    pub const release = deinit;

    pub fn local(self: Global, l: *const js.Local) PromiseResolver {
        return .{
            .local = l,
            .handle = @ptrCast(v8.v8__Global__Get(&self.slot.handle, l.isolate.handle)),
        };
    }
};
