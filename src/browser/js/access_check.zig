// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// The Zig half of browser/js/access_check.cpp: V8's access check, which is what
// Blink guards a cross-origin WindowProxy with.
//
// An interceptor is consulted *during* a property lookup, so anything that
// reaches a property without one goes around it -- `JSON.stringify` (V8 looks
// `toJSON` up skipping interceptors), and any own key at all, which is found
// before a [[NonMasking]] interceptor runs. An access check is not skipped on
// either path. The cpp file has the measurements.
//
// Everything here is policy; the ABI is next door.

const std = @import("std");

const js = @import("js.zig");
const v8 = js.v8;
const Context = @import("Context.zig");

/// Turns on the access check for instances of `object_template`, with the two
/// handler configurations answering whatever the refusal lets through. V8 takes
/// both by const reference and copies them, so they need only outlive the call.
///
/// Replaces `SetNamedHandler` rather than joining it: V8 refuses both at once.
pub fn installHandler(
    object_template: ?*const v8.ObjectTemplate,
    named: *const v8.NamedPropertyHandlerConfiguration,
    indexed: *const v8.IndexedPropertyHandlerConfiguration,
) void {
    // Optional to match what the binding hands back from ObjectTemplate::New;
    // a null here is a template that was never created, which is a build-time
    // bug rather than a runtime state.
    lp_access_check__install_handler(object_template.?, named, indexed);
}

/// Once per isolate. Without it a refused operation the handler did not answer
/// comes back as `undefined` instead of throwing, which is a quieter kind of
/// wrong than the one this is here to fix.
pub fn installFailureCallback(isolate: *v8.Isolate) void {
    lp_access_check__install_failure_callback(isolate);
}

extern fn lp_access_check__install_handler(
    object_template: *const v8.ObjectTemplate,
    named: *const v8.NamedPropertyHandlerConfiguration,
    indexed: *const v8.IndexedPropertyHandlerConfiguration,
) void;

extern fn lp_access_check__install_failure_callback(isolate: *v8.Isolate) void;

extern fn lp_access_check__callback_address() *const anyopaque;

/// The access-check callback's own address, for the snapshot's external
/// reference table. V8 serialises an access-checked template as an index into
/// that table, and deserialising without this entry aborts the isolate with
/// "Unknown external reference" before the first line of script runs.
pub fn callbackAddress() *const anyopaque {
    return lp_access_check__callback_address();
}

/// Open while this engine is building an access-checked object, and only then.
///
/// V8 runs the check on `Object::SetPrototype` too, and a cross-origin proxy
/// has to have its prototype cut to null right after `NewInstance` -- so the
/// engine's own construction would be refused by the guard it is installing.
/// Blink does not hit this because it never sets the prototype from outside the
/// object's own context; here there is no such context to be in. Measured
/// failure: `v8::Object::SetPrototype` returns Nothing and V8 aborts the
/// process on the FromJust.
var building: bool = false;

/// Wraps the one call that has to get through. Not a general escape hatch: it
/// is opened and closed around a single V8 call with no script in between, so
/// nothing a page runs can be inside it.
pub fn whileBuilding(comptime call: anytype, args: anytype) @TypeOf(@call(.auto, call, args)) {
    building = true;
    defer building = false;
    return @call(.auto, call, args);
}

/// Called by V8 before every property operation on an access-checked object.
///
/// False for everything a page does, and that is the whole policy: the only
/// template this is installed on is the cross-origin window proxy, and a proxy
/// exists precisely because the access was already found to be cross-origin. A
/// same-origin frame hands out its real Window and never reaches this.
pub export fn lp_access_check__allow(
    _: ?*const v8.Context,
    _: ?*const v8.Object,
) callconv(.c) bool {
    return building;
}

/// Called once per refused operation that the handler did not answer -- a
/// symbol read, an `in`, a delete, a define. Blink's sentence for all of those
/// is the bare one: [[HasProperty]] and [[Delete]] are not reads of any
/// particular property as far as the access check is concerned, and a symbol
/// never reaches a handler that only intercepts strings. Measured on Chrome 151
/// (scratch/b90/expr-xo-messages.js); the named sentences come from the handler
/// itself, in Window.zig.
pub export fn lp_access_check__denied(
    _: ?*const v8.Object,
    _: c_int,
) callconv(.c) void {
    const isolate = v8.v8__Isolate__GetCurrent() orelse return;
    const ctx, _ = Context.fromIsolate(.{ .handle = isolate }) orelse return;
    throwSecurityError(ctx, isolate);
}

fn throwSecurityError(ctx: *Context, isolate: *v8.Isolate) void {
    const DOMException = @import("../webapi/DOMException.zig");
    const Window = @import("../webapi/Window.zig");

    var caller: js.Caller = undefined;
    const v8_context = v8.v8__Isolate__GetCurrentContext(isolate) orelse return;
    caller.initWithContext(ctx, v8_context);
    defer caller.deinit();

    var scope: js.HandleScope = undefined;
    scope.init(caller.local.isolate);
    defer scope.deinit();

    const frame = switch (ctx.global) {
        .frame => |frame| frame,
        else => return,
    };

    var exception = DOMException.fromError(error.SecurityError) orelse return;
    if (Window.CrossOriginWindow.blockedSentence(frame)) |sentence| {
        // Copied onto the context arena, not left on call_arena: a script that
        // catches this reads `.message` after the call that threw has returned,
        // and call_arena is reset at that boundary. Caller.domExceptionToJs
        // learned the same thing.
        exception._custom_message = ctx.arena.dupe(u8, sentence) catch sentence;
    } else |_| {}

    const value = caller.local.zigValueToJs(exception, .{}) catch return;
    _ = v8.v8__Isolate__ThrowException(isolate, value.handle);
}
