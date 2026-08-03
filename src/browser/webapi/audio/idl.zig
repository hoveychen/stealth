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

//! The refusals every Web Audio constructor shares.
//!
//! Twenty-odd node classes take the same `(BaseAudioContext, optional
//! dictionary)` pair, and Chrome refuses a bad one in a fixed order that a
//! script can tell apart: too few arguments first, then a first parameter that
//! is not a context, then a second one that is not a dictionary, then a member
//! inside that dictionary. Every message here was read off a headed Chrome 150
//! (win15-chrome.json) rather than derived from the spec.
//!
//! One measured subtlety worth keeping: a *dictionary* member with a bad enum
//! value throws, but the same enum assigned to an attribute afterwards is
//! silently ignored. `new OscillatorNode(ctx, {type: 'nope'})` is a TypeError;
//! `osc.type = 'nope'` leaves it at "sine". WebIDL says so and Chrome does it.

const std = @import("std");

const js = @import("../../js/js.zig");
const DOMException = @import("../DOMException.zig");

const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

pub fn typeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

pub fn rangeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createRangeError(message));
    return error.JsException;
}

// A DOMException with a message Chrome chose, rather than the generic one the
// bridge produces from a bare `error.IndexSizeError`.
pub fn domError(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

// How many arguments actually arrived. A JS call cannot leave a hole, so the
// first Zig null marks the end — an explicit `null` is a js.Value that is null,
// not an absent argument, and Chrome counts it as present.
pub fn present(args: []const ?js.Value) usize {
    for (args, 0..) |arg, i| {
        if (arg == null) return i;
    }
    return args.len;
}

pub fn argCount(comptime interface: []const u8, comptime required: usize, got: usize, exec: *const Execution) anyerror {
    const plural = if (required == 1) " argument required, but only " else " arguments required, but only ";
    return typeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to construct '" ++ interface ++ "': {d}" ++ plural ++ "{d} present.",
        .{ required, got },
    ), exec);
}

// `new XNode(context, ...)`: the first parameter of every node constructor.
pub fn context(
    comptime interface: []const u8,
    comptime required: usize,
    args: []const ?js.Value,
    exec: *const Execution,
) !*BaseAudioContext {
    const got = present(args);
    if (got < required) return argCount(interface, required, got, exec);
    const value = args[0].?;
    return value.toZig(*BaseAudioContext) catch typeError(
        "Failed to construct '" ++ interface ++ "': parameter 1 is not of type 'BaseAudioContext'.",
        exec,
    );
}

// The same, for the three nodes whose IDL takes an `AudioContext` rather than a
// `BaseAudioContext`. Chrome names the narrower type in the refusal, so an
// OfflineAudioContext handed to one of these reads "parameter 1 is not of type
// 'AudioContext'" (measured).
pub fn realtimeContext(
    comptime interface: []const u8,
    comptime required: usize,
    args: []const ?js.Value,
    exec: *const Execution,
) !*@import("AudioContext.zig") {
    const got = present(args);
    if (got < required) return argCount(interface, required, got, exec);
    const value = args[0].?;
    return value.toZig(*@import("AudioContext.zig")) catch typeError(
        "Failed to construct '" ++ interface ++ "': parameter 1 is not of type 'AudioContext'.",
        exec,
    );
}

// The optional dictionary. Absent, null and undefined all mean "defaults";
// anything that is not an object is refused by the dictionary's own name.
pub fn options(
    comptime interface: []const u8,
    comptime dictionary: []const u8,
    value: ?js.Value,
    exec: *const Execution,
) !?js.Object {
    const given = value orelse return null;
    if (given.isNullOrUndefined()) return null;
    if (!given.isObject()) return typeError(
        "Failed to construct '" ++ interface ++ "': The provided value is not of type '" ++ dictionary ++ "'.",
        exec,
    );
    return given.toZig(js.Object) catch typeError(
        "Failed to construct '" ++ interface ++ "': The provided value is not of type '" ++ dictionary ++ "'.",
        exec,
    );
}

fn member(dict: ?js.Object, key: []const u8) !?js.Value {
    const obj = dict orelse return null;
    const value = try obj.get(key);
    if (value.isUndefined()) return null;
    return value;
}

pub fn optionalF64(dict: ?js.Object, key: []const u8) !?f64 {
    const value = try member(dict, key) orelse return null;
    return try value.toF64();
}

pub fn optionalU32(dict: ?js.Object, key: []const u8) !?u32 {
    const value = try member(dict, key) orelse return null;
    return try value.toU32();
}

pub fn optionalBool(dict: ?js.Object, key: []const u8) !?bool {
    const value = try member(dict, key) orelse return null;
    return value.toBool();
}

// A dictionary member declared as a WebIDL enum: a value outside the enum is a
// TypeError that names the property, the dictionary and the enum type.
pub fn optionalEnum(
    comptime E: type,
    comptime interface: []const u8,
    comptime dictionary: []const u8,
    comptime enum_name: []const u8,
    dict: ?js.Object,
    comptime key: []const u8,
    exec: *const Execution,
) !?E {
    const value = try member(dict, key) orelse return null;
    const text = try value.toStringSlice();
    return std.meta.stringToEnum(E, text) orelse typeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to construct '" ++ interface ++ "': Failed to read the '" ++ key ++
            "' property from '" ++ dictionary ++ "': The provided value '{s}' is not a valid enum " ++
            "value of type " ++ enum_name ++ ".",
        .{text},
    ), exec);
}

// A required dictionary member: Chrome names it before it names its type.
pub fn requiredMember(
    comptime interface: []const u8,
    comptime dictionary: []const u8,
    comptime key: []const u8,
    dict: ?js.Object,
    exec: *const Execution,
) !js.Value {
    return try member(dict, key) orelse typeError(
        "Failed to construct '" ++ interface ++ "': Failed to read the '" ++ key ++
            "' property from '" ++ dictionary ++ "': Required member is undefined.",
        exec,
    );
}

// A `sequence<float>` member (feedforward, feedback, curve, real, imag). The
// values are copied into the page arena because the node keeps them.
//
// A Float32Array is the form every one of these is handed in practice, and it
// does not survive a `[]const f64` conversion here, so it gets its own branch.
pub fn floatSequence(value: js.Value, exec: *const Execution) ![]f32 {
    if (value.isFloat32Array()) {
        const array = try value.toZig(js.TypedArray(f32));
        return exec.arena.dupe(f32, array.values);
    }
    const numbers = try value.toZig([]const f64);
    const out = try exec.arena.alloc(f32, numbers.len);
    for (out, numbers) |*slot, number| {
        slot.* = @floatCast(number);
    }
    return out;
}

pub fn optionalFloatSequence(dict: ?js.Object, key: []const u8, exec: *const Execution) !?[]f32 {
    const value = try member(dict, key) orelse return null;
    if (value.isNull()) return null;
    return try floatSequence(value, exec);
}

// A WebIDL enum *attribute* setter. Out-of-range values are dropped on the
// floor rather than thrown (measured: `gain.channelCountMode = 'nope'` leaves
// it at "max"), which is what WebIDL prescribes for an enumerated attribute.
pub fn assignEnum(comptime E: type, slot: *E, text: []const u8) void {
    if (std.meta.stringToEnum(E, text)) |parsed| {
        slot.* = parsed;
    }
}
