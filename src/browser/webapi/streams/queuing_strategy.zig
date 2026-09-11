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

//! The two built-in queuing strategies.
//!
//! The interesting part is `size`. It is not a per-instance closure: every
//! ByteLengthQueuingStrategy in a realm hands out the *same* function object,
//! and so does every CountQueuingStrategy, while the two families differ
//! (measured on a headed Chrome 150, win26-chrome.json). Each one also reports
//! `name` "size", `length` 1 and 0 respectively, prints as `[native code]`, has
//! exactly `length` and `name` as own properties and is not a constructor --
//! which is what a FunctionTemplate produces, and is why they are not compiled
//! from JS source (that would print the source and carry a `prototype`).
//!
//! `highWaterMark` is an unrestricted double read straight through: NaN, 'abc'
//! (NaN), Infinity and -3 all round-trip, and only a missing member is an
//! error.

const js = @import("../../js/js.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        ByteLengthQueuingStrategy,
        CountQueuingStrategy,
    };
}

const Family = enum(u1) {
    byte_length = 0,
    count = 1,
};

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

/// QueuingStrategyInit. Chrome refuses null as well as a primitive -- both say
/// "The provided value is not of type 'QueuingStrategyInit'." -- and a missing
/// highWaterMark is its own message (measured).
fn readHighWaterMark(comptime name: []const u8, init: js.Value, exec: *const Execution) !f64 {
    if (!init.isObject()) {
        return throwTypeError(
            "Failed to construct '" ++ name ++ "': The provided value is not of type 'QueuingStrategyInit'.",
            exec,
        );
    }

    const raw = try init.toObject().get("highWaterMark");
    if (raw.isUndefined()) {
        return throwTypeError(
            "Failed to construct '" ++ name ++ "': Failed to read the 'highWaterMark' property " ++
                "from 'QueuingStrategyInit': Required member is undefined.",
            exec,
        );
    }
    return raw.toF64();
}

/// The realm's `size` function for one of the two families, created once.
fn sizeFunction(comptime family: Family, exec: *const Execution) !js.Function {
    const local = exec.js.local.?;
    const ctx = exec.js;

    const slot = &ctx.queuing_strategy_size[@intFromEnum(family)];
    if (slot.*) |cached| {
        return local.toLocal(cached);
    }

    const func = switch (family) {
        .byte_length => try local.newNamedCallback("size", 1, byteLengthSize, ctx),
        .count => try local.newNamedCallback("size", 0, countSize, ctx),
    };

    slot.* = try func.persist();
    return func;
}

/// `chunk.byteLength`, with ToObject's own wording for a missing chunk: Chrome
/// reports "Cannot convert undefined or null to object" rather than a property
/// read failure (measured), and hands back the raw member -- `size({})` is
/// undefined, not 0.
fn byteLengthSize(ctx: *js.Context, chunk_: ?js.Value) !js.Value {
    const local = ctx.local.?;
    const chunk = chunk_ orelse js.Value{ .local = local, .handle = undefined };
    if (chunk_ == null or chunk.isNullOrUndefined()) {
        const isolate = local.isolate;
        _ = isolate.throwException(isolate.createTypeError("Cannot convert undefined or null to object"));
        return error.JsException;
    }
    // ToObject on a primitive gives a wrapper, and a Number wrapper has no
    // `byteLength` -- so `size(7)` is undefined, the same answer `size({})`
    // gives. Only null and undefined throw, which the branch above handles.
    if (!chunk.isObject()) {
        return .{ .local = local, .handle = local.isolate.initUndefined() };
    }
    return chunk.toObject().get("byteLength");
}

/// One chunk is one, whatever it is -- including no chunk at all.
fn countSize(_: *js.Context, _: ?js.Value) u32 {
    return 1;
}

pub const ByteLengthQueuingStrategy = struct {
    _high_water_mark: f64,

    pub fn init(init_: js.Value, exec: *Execution) !ByteLengthQueuingStrategy {
        return .{ ._high_water_mark = try readHighWaterMark("ByteLengthQueuingStrategy", init_, exec) };
    }

    pub fn getHighWaterMark(self: *const ByteLengthQueuingStrategy) f64 {
        return self._high_water_mark;
    }

    pub fn getSize(_: *const ByteLengthQueuingStrategy, exec: *const Execution) !js.Function {
        return sizeFunction(.byte_length, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ByteLengthQueuingStrategy);

        pub const Meta = struct {
            pub const name = "ByteLengthQueuingStrategy";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = ByteLengthQueuingStrategy;

        pub const constructor = bridge.constructor(T.init, .{});
        pub const highWaterMark = bridge.accessor(T.getHighWaterMark, null, .{});
        pub const size = bridge.accessor(T.getSize, null, .{});
    };
};

pub const CountQueuingStrategy = struct {
    _high_water_mark: f64,

    pub fn init(init_: js.Value, exec: *Execution) !CountQueuingStrategy {
        return .{ ._high_water_mark = try readHighWaterMark("CountQueuingStrategy", init_, exec) };
    }

    pub fn getHighWaterMark(self: *const CountQueuingStrategy) f64 {
        return self._high_water_mark;
    }

    pub fn getSize(_: *const CountQueuingStrategy, exec: *const Execution) !js.Function {
        return sizeFunction(.count, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CountQueuingStrategy);

        pub const Meta = struct {
            pub const name = "CountQueuingStrategy";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = CountQueuingStrategy;

        pub const constructor = bridge.constructor(T.init, .{});
        pub const highWaterMark = bridge.accessor(T.getHighWaterMark, null, .{});
        pub const size = bridge.accessor(T.getSize, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: QueuingStrategy" {
    try testing.htmlRunner("streams/queuing_strategy.html", .{});
}
