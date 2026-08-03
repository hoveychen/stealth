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

// The wavetable an OscillatorNode can be pointed at. Chrome exposes nothing on
// it — its prototype holds `constructor` and nothing else (measured) — so the
// only observable behaviour is which arguments it accepts, and the one refusal
// it has: a real and an imag array of different lengths.
//
// The coefficients are kept because setPeriodicWave() has to be handed
// something, not because anything reads them: there is no oscillator running.

const std = @import("std");

const js = @import("../../js/js.zig");

const idl = @import("idl.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const Execution = js.Execution;

const PeriodicWave = @This();

_real: []const f32,
_imag: []const f32,

pub fn constructor(context: ?js.Value, options: ?js.Value, exec: *Execution) !*PeriodicWave {
    _ = try idl.context("PeriodicWave", 1, &.{ context, options }, exec);
    const dict = try idl.options("PeriodicWave", "PeriodicWaveOptions", options, exec);

    const real = try idl.optionalFloatSequence(dict, "real", exec) orelse &.{};
    const imag = try idl.optionalFloatSequence(dict, "imag", exec) orelse &.{};
    return create("PeriodicWave", real, imag, exec);
}

// Shared with BaseAudioContext.createPeriodicWave, which blames itself.
pub fn create(comptime where: []const u8, real: []const f32, imag: []const f32, exec: *Execution) !*PeriodicWave {
    if (real.len != 0 and imag.len != 0 and real.len != imag.len) {
        return idl.domError("IndexSizeError", try std.fmt.allocPrint(
            exec.call_arena,
            where ++ ": length of real array ({d}) and length of imaginary array ({d}) must match.",
            .{ real.len, imag.len },
        ), exec);
    }
    return exec._factory.create(PeriodicWave{ ._real = real, ._imag = imag });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PeriodicWave);

    pub const Meta = struct {
        pub const name = "PeriodicWave";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PeriodicWave.constructor, .{ .arity = 1 });
};
