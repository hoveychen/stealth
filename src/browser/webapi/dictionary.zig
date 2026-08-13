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

// Hand-rolled WebIDL dictionary reading. The bridge's typed dictionaries
// cannot produce the messages Chrome gives ("Required member is undefined.",
// "Failed to convert value to 'X'.", "The provided value is not of type
// 'XInit'."), and those messages are exactly what a detector reads back when it
// feeds a constructor the wrong thing.
//
// Three entry points. `Init` and `Reader` differ only in whether the dictionary
// also inherits EventInit: `Init` for an event dictionary (it fills `.event`),
// `Reader` for every other one. Reading EventInit is not free -- it touches
// `bubbles`, `cancelable` and `composed`, all of which a page can define as
// getters -- so a non-event dictionary must not do it.
//
// `MethodReader` is `Reader` for a dictionary passed to an *operation* rather
// than to a constructor, which Chrome prefixes differently. Measured on a
// headed Chrome 150:
//
//   navigator.gpu.requestAdapter('nope')
//     -> TypeError: Failed to execute 'requestAdapter' on 'GPU': The provided
//        value is not of type 'GPURequestAdapterOptions'.

const std = @import("std");

const js = @import("../js/js.zig");
const Event = @import("Event.zig");
const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

pub fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

/// `throwTypeError` for the refusals that are a bare RangeError: AudioData's
/// plane and frame bounds are all of them (measured -- `allocationSize({
/// planeIndex: 1 })` on interleaved data is a RangeError, not a TypeError).
pub fn throwRangeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createRangeError(message));
    return error.JsException;
}

/// `throwTypeError` for the refusals that are DOMExceptions rather than
/// TypeErrors -- the InvalidStateError a closed VideoFrame answers with, the
/// OperationError an unmapped GPUBuffer does.
pub fn throwDom(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

/// An event dictionary: the members below plus EventInit's own three.
pub fn Init(comptime interface: []const u8, comptime dict: []const u8) type {
    return Dictionary(interface, dict, true);
}

/// A plain dictionary, read the same way but without EventInit.
pub fn Reader(comptime interface: []const u8, comptime dict: []const u8) type {
    return Dictionary(interface, dict, false);
}

/// A plain dictionary handed to an operation, so the messages say
/// "Failed to execute 'method' on 'Interface'" rather than "Failed to
/// construct 'Interface'".
pub fn MethodReader(
    comptime interface: []const u8,
    comptime method: []const u8,
    comptime dict: []const u8,
) type {
    return DictionaryWithPrefix(
        "Failed to execute '" ++ method ++ "' on '" ++ interface ++ "': ",
        dict,
        false,
    );
}

/// A dictionary reached *through* a member of another one. Chrome nests the
/// wording rather than restating the operation. Measured on a headed Chrome
/// 150:
///
///   device.createComputePipeline({layout: 'auto', compute: {}})
///     -> TypeError: Failed to execute 'createComputePipeline' on 'GPUDevice':
///        Failed to read the 'compute' property from
///        'GPUComputePipelineDescriptor': Failed to read the 'module' property
///        from 'GPUProgrammableStage': Required member is undefined.
pub fn Nested(
    comptime Outer: type,
    comptime member: []const u8,
    comptime dict: []const u8,
) type {
    return DictionaryWithPrefix(
        Outer.message_prefix ++ "Failed to read the '" ++ member ++ "' property from '" ++
            Outer.dict_name ++ "': ",
        dict,
        false,
    );
}

/// The same object read as a *different* dictionary: an inherited member names
/// the dictionary it is declared on, not the one that was passed in. Measured:
/// `layout` always says 'GPUPipelineDescriptorBase', and a vertex state's
/// `module` says 'GPUProgrammableStage' while the state itself is a
/// 'GPUVertexState'. Build one over the outer reader's own object.
pub fn Sibling(comptime Outer: type, comptime dict: []const u8) type {
    return DictionaryWithPrefix(Outer.message_prefix, dict, false);
}

/// The dictionary reader. One instance per constructor call, parameterised by
/// the interface and dictionary names so every message it produces is a
/// comptime string.
fn Dictionary(comptime interface: []const u8, comptime dict: []const u8, comptime with_event: bool) type {
    return DictionaryWithPrefix("Failed to construct '" ++ interface ++ "': ", dict, with_event);
}

fn DictionaryWithPrefix(comptime prefix: []const u8, comptime dict: []const u8, comptime with_event: bool) type {
    return struct {
        object: ?js.Object = null,
        event: EventOptions = if (with_event) .{} else {},

        const Self = @This();
        const CTOR = prefix;

        /// Exposed so a caller can build a message this reader has no shape for
        /// (see webgpu/resources.zig's requiredEnum) without re-deriving the
        /// wording.
        pub const message_prefix = prefix;
        pub const dict_name = dict;
        const EventOptions = if (with_event) Event.Options else void;

        pub fn read(value_: ?js.Value, exec: *const Execution) !Self {
            const value = value_ orelse return .{};
            if (value.isNullOrUndefined()) {
                return .{};
            }
            if (!value.isObject()) {
                return throwTypeError(
                    CTOR ++ "The provided value is not of type '" ++ dict ++ "'.",
                    exec,
                );
            }
            return .{
                .object = value.toObject(),
                .event = if (with_event) try Event.optionsFromJs(value) else {},
            };
        }

        /// `read` for an argument that is not optional. A required dictionary
        /// parameter refuses undefined and null outright instead of taking them
        /// as an empty dictionary, so the page never gets as far as hearing
        /// about a missing member (measured on a headed Chrome 150: all eleven
        /// `device.create*` calls with a required descriptor answer "The
        /// provided value is not of type 'X'." for both, while the two with an
        /// optional one -- createSampler and createCommandEncoder -- hand back
        /// an object; see win40d-chrome.json).
        pub fn readRequired(value: js.Value, exec: *const Execution) !Self {
            if (value.isNullOrUndefined()) {
                return throwTypeError(
                    CTOR ++ "The provided value is not of type '" ++ dict ++ "'.",
                    exec,
                );
            }
            return read(value, exec);
        }

        /// The member if the dictionary has it and it is not undefined.
        pub fn present(self: Self, comptime name: []const u8) !?js.Value {
            const object = self.object orelse return null;
            const member = try object.get(name);
            if (member.isUndefined()) {
                return null;
            }
            return member;
        }

        pub fn required(self: Self, comptime name: []const u8, exec: *const Execution) !js.Value {
            return (try self.present(name)) orelse missingMember(name, exec);
        }

        /// `required`'s refusal on its own, for a caller that reads the member
        /// through a typed helper and only needs the message when it is absent.
        pub fn missingMember(comptime name: []const u8, exec: *const Execution) anyerror {
            return throwTypeError(
                CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                    "': Required member is undefined.",
                exec,
            );
        }

        pub fn convertFailed(comptime name: []const u8, comptime idl: []const u8, exec: *const Execution) anyerror {
            return throwTypeError(
                CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                    "': Failed to convert value to '" ++ idl ++ "'.",
                exec,
            );
        }

        /// A *union*-typed member reads back differently from an interface one:
        /// Chrome says the value "is not of type" the union rather than that it
        /// failed to convert. Measured with
        /// `device.importExternalTexture({source: 5})`.
        pub fn notOfType(comptime name: []const u8, comptime idl: []const u8, exec: *const Execution) anyerror {
            return throwTypeError(
                CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                    "': The provided value is not of type '" ++ idl ++ "'.",
                exec,
            );
        }

        /// The "cannot be converted to a sequence" message, which is what a
        /// non-iterable value gives for a sequence-typed member.
        pub fn notASequence(comptime name: []const u8, exec: *const Execution) anyerror {
            return throwTypeError(
                CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                    "': The provided value cannot be converted to a sequence.",
                exec,
            );
        }

        /// A WebIDL enumeration-typed member. Present-and-unrecognised is a
        /// TypeError naming the offending value and the enum; absent takes the
        /// default. Measured on a headed Chrome 150:
        ///
        ///   navigator.gpu.requestAdapter({powerPreference: 'nope'})
        ///     -> TypeError: Failed to execute 'requestAdapter' on 'GPU':
        ///        Failed to read the 'powerPreference' property from
        ///        'GPURequestAdapterOptions': The provided value 'nope' is not a
        ///        valid enum value of type GPUPowerPreference.
        pub fn enumMember(
            self: Self,
            comptime name: []const u8,
            comptime idl: []const u8,
            comptime allowed: []const []const u8,
            default: ?[]const u8,
            exec: *const Execution,
        ) !?[]const u8 {
            const member = (try self.present(name)) orelse return default;
            return matchEnum(name, idl, allowed, member, exec);
        }

        /// A *nullable* enumeration member (`VideoColorPrimaries?`): an explicit
        /// `null` stays null instead of being stringified into an
        /// invalid-enum error. Measured on a headed Chrome 150:
        /// `new VideoColorSpace({primaries: null}).primaries` is null, while
        /// `{primaries: 'nope'}` is the usual TypeError.
        pub fn nullableEnum(
            self: Self,
            comptime name: []const u8,
            comptime idl: []const u8,
            comptime allowed: []const []const u8,
            exec: *const Execution,
        ) !?[]const u8 {
            const member = (try self.present(name)) orelse return null;
            if (member.isNull()) {
                return null;
            }
            return matchEnum(name, idl, allowed, member, exec);
        }

        fn matchEnum(
            comptime name: []const u8,
            comptime idl: []const u8,
            comptime allowed: []const []const u8,
            member: js.Value,
            exec: *const Execution,
        ) !?[]const u8 {
            const text = try member.toStringSlice();
            for (allowed) |candidate| {
                if (std.mem.eql(u8, candidate, text)) {
                    return candidate;
                }
            }
            return throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                    "': The provided value '{s}' is not a valid enum value of type " ++ idl ++ ".",
                .{text},
            ), exec);
        }

        pub fn boolean(self: Self, comptime name: []const u8, default: bool) !bool {
            const member = (try self.present(name)) orelse return default;
            return member.toBool();
        }

        /// WebIDL `boolean?`: null stays null, everything else is ToBoolean
        /// (measured: `{fullRange: 'x'}` reads back true, `{fullRange: 0}`
        /// false, `{fullRange: null}` null).
        pub fn nullableBoolean(self: Self, comptime name: []const u8) !?bool {
            const member = (try self.present(name)) orelse return null;
            if (member.isNull()) {
                return null;
            }
            return member.toBool();
        }

        /// An `[EnforceRange]` integer member. A fractional value truncates,
        /// but a non-finite one and an out-of-range one each get their own
        /// message, and the message names the IDL type rather than deriving it
        /// -- `unsigned long` and `unsigned long long` are both unsigned.
        /// Measured with VideoFrameInit: `{timestamp: {}}` is "Value is not of
        /// type 'long long'.", `{timestamp: 2**63}` and `{displayWidth: -1}`
        /// are "Value is outside the '...' value range.".
        pub fn enforcedInt(
            self: Self,
            comptime name: []const u8,
            comptime T: type,
            comptime idl: []const u8,
            exec: *const Execution,
        ) !?T {
            const member = (try self.present(name)) orelse return null;
            const number = member.toF64() catch return convertFailed(name, idl, exec);
            if (std.math.isFinite(number) == false) {
                return throwTypeError(
                    CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                        "': Value is not of type '" ++ idl ++ "'.",
                    exec,
                );
            }
            const truncated = @trunc(number);
            // Whether the upper bound itself is representable decides which
            // comparison is right: 2^63-1 rounds *up* to 2^63 in a double, so
            // an i64 has to reject anything that reaches the rounded bound,
            // while a u32's bound is exact and has to be accepted.
            const bits = @typeInfo(T).int.bits;
            const lower: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
            const upper: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
            const out_of_range = truncated < lower or
                (if (bits <= 53) truncated > upper else truncated >= upper);
            if (out_of_range) {
                return throwTypeError(
                    CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                        "': Value is outside the '" ++ idl ++ "' value range.",
                    exec,
                );
            }
            return @intFromFloat(truncated);
        }

        /// WebIDL `double`: restricted, so a non-finite value is a TypeError
        /// rather than a stored NaN (measured with `{timecode: NaN}`).
        pub fn double(self: Self, comptime name: []const u8, default: f64, exec: *const Execution) !f64 {
            const member = (try self.present(name)) orelse return default;
            return try finite(name, member, exec);
        }

        /// WebIDL `double?`: null stays null, everything else is restricted.
        pub fn nullableDouble(self: Self, comptime name: []const u8, exec: *const Execution) !?f64 {
            const member = (try self.present(name)) orelse return null;
            if (member.isNull()) {
                return null;
            }
            return try finite(name, member, exec);
        }

        pub fn finite(comptime name: []const u8, member: js.Value, exec: *const Execution) !f64 {
            const number = try member.toF64();
            if (std.math.isFinite(number) == false) {
                return throwTypeError(
                    CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                        "': The provided double value is non-finite.",
                    exec,
                );
            }
            return number;
        }

        /// WebIDL `long`, which is ToInt32: a fractional value truncates and a
        /// non-finite one is 0, neither of them an error (measured:
        /// `{lineNumber: '3.7'}` reads back 3).
        pub fn long(self: Self, comptime name: []const u8, default: i32) !i32 {
            const member = (try self.present(name)) orelse return default;
            return member.toI32() catch 0;
        }

        pub fn string(
            self: Self,
            comptime name: []const u8,
            default: []const u8,
            allocator: std.mem.Allocator,
        ) ![]const u8 {
            const member = (try self.present(name)) orelse return default;
            return member.toStringSliceWithAlloc(allocator);
        }

        /// An interface-typed member: present and convertible, or Chrome's
        /// conversion message. `null` counts as a failed conversion for a
        /// non-nullable member, which is how a page finds out it cannot build
        /// one of these (measured with `{data: null}`).
        pub fn interfaceMember(
            self: Self,
            comptime name: []const u8,
            comptime T: type,
            comptime idl: []const u8,
            exec: *const Execution,
        ) !*T {
            const member = try self.required(name, exec);
            return member.toZig(*T) catch convertFailed(name, idl, exec);
        }

        pub fn nullableInterface(
            self: Self,
            comptime name: []const u8,
            comptime T: type,
            comptime idl: []const u8,
            exec: *const Execution,
        ) !?*T {
            const member = (try self.present(name)) orelse return null;
            if (member.isNull()) {
                return null;
            }
            return member.toZig(*T) catch convertFailed(name, idl, exec);
        }

        /// A union-typed member fails differently: Chrome says the value "is
        /// not of type" the union rather than that it failed to convert to it
        /// (measured with `new TrackEvent('addtrack', {track: 5})`).
        pub fn unionMember(
            self: Self,
            comptime name: []const u8,
            comptime T: type,
            comptime idl: []const u8,
            exec: *const Execution,
        ) !?*T {
            const member = (try self.present(name)) orelse return null;
            if (member.isNull()) {
                return null;
            }
            return member.toZig(*T) catch throwTypeError(
                CTOR ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict ++
                    "': The provided value is not of type '" ++ idl ++ "'.",
                exec,
            );
        }
    };
}
