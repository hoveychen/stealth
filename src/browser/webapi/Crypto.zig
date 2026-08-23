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
const js = @import("../js/js.zig");

const SubtleCrypto = @import("SubtleCrypto.zig");
const QuotaExceededError = @import("QuotaExceededError.zig");

const Crypto = @This();
/// Keeps `_subtle` off offset zero. The identity map that gives a Zig instance
/// its one JS wrapper is keyed on the address alone, so an embedded struct
/// sitting at its parent's address collides with it: `&self._subtle` would be
/// `&self`, the map would find the Crypto entry, and `crypto.subtle` would come
/// back as a second reference to `crypto` — measured, `[object Crypto]` with no
/// `digest` on it. A field ahead of it separates the two addresses.
_pad: bool = false,
_subtle: SubtleCrypto = .{},

pub const init: Crypto = .{};

// We take a js.Value, because we want to return the same instance, not a new
// TypedArray
pub fn getRandomValues(_: *const Crypto, js_obj: js.Object, exec: *const js.Execution) !js.Object {
    const value = js_obj.toValue();
    if (value.isFloat16Array() or value.isFloat32Array() or value.isFloat64Array() or (value.isArrayBufferView() and !value.isTypedArray())) {
        // only integer TypedArrays are supported
        return error.TypeMismatch;
    }

    var into = try js_obj.toZig(RandomValues);
    const buf = into.asBuffer();
    if (buf.len > 65_536) {
        return QuotaExceededError.throw(js_obj.local, exec);
    }
    lp.io.random(buf);
    return js_obj;
}

pub fn randomUUID(_: *const Crypto) ![36]u8 {
    var hex: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&hex);
    return hex;
}

pub fn getSubtle(self: *Crypto) *SubtleCrypto {
    return &self._subtle;
}

const RandomValues = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
    int64: []i64,
    uint64: []u64,

    fn asBuffer(self: RandomValues) []u8 {
        return switch (self) {
            .int8 => |b| (@as([]u8, @ptrCast(b)))[0..b.len],
            .uint8 => |b| (@as([]u8, @ptrCast(b)))[0..b.len],
            .int16 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 2],
            .uint16 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 2],
            .int32 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 4],
            .uint32 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 4],
            .int64 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 8],
            .uint64 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 8],
        };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Crypto);

    pub const Meta = struct {
        pub const name = "Crypto";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // No `empty_with_no_proto`, on purpose. A type carrying that marker is
        // never given an internal field, so recovering the Zig receiver from a
        // JS object hands back a pointer to one comptime instance shared by the
        // whole process (TaggedOpaque.fromJS). Crypto is not stateless: it owns
        // `_subtle`, and `&self._subtle` off that one shared instance is one
        // address, so the identity map handed every realm the same
        // SubtleCrypto. Chrome gives each realm its own, and the Cloudflare
        // widget's recorder found the difference by wrapping digest ten times
        // over (README, "Reading the same two files record by record").
    };

    pub const getRandomValues = bridge.function(Crypto.getRandomValues, .{});
    pub const randomUUID = bridge.function(Crypto.randomUUID, .{});
    pub const subtle = bridge.accessor(Crypto.getSubtle, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Crypto" {
    try testing.htmlRunner("crypto.html", .{});
}
