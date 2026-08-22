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

//! Pure-byte base64 helpers for btoa/atob. The "binary string" semantics
//! (each JS code unit 0..255 = one byte) are handled by `BinInput.bytes` —
//! the coding below just deals in bytes.

const std = @import("std");
const js = @import("../../js/js.zig");

const Allocator = std.mem.Allocator;

/// The sentences Blink answers, which name both the operation and the interface
/// it was called on. `interface` is "Window" on a page and "WorkerGlobalScope"
/// in a worker — measured against Chrome 151: a DedicatedWorkerGlobalScope still
/// says 'WorkerGlobalScope', not its own name. atob words its two failure modes
/// differently, so the "not Latin-1" case is not the "not base64" case.
pub fn Messages(comptime interface: []const u8) type {
    const on = "' on '" ++ interface ++ "': ";
    return struct {
        pub const atob_not_latin1 = "Failed to execute 'atob" ++ on ++
            "The string to be decoded contains characters outside of the Latin1 range.";
        pub const atob_not_encoded = "Failed to execute 'atob" ++ on ++
            "The string to be decoded is not correctly encoded.";
        pub const btoa_not_latin1 = "Failed to execute 'btoa" ++ on ++
            "The string to be encoded contains characters outside of the Latin1 range.";
    };
}

pub const BinInput = union(enum) {
    // order matters
    js_string: js.String,
    raw: []const u8,

    /// The "binary string" read: every JS code unit has to fit in a byte
    /// (0..255). The check is here rather than in the argument conversion (which
    /// is where `js.String.OneByte` would put it) so the exception can carry
    /// Blink's own sentence: the conversion layer has no idea whether it serves
    /// atob or btoa, and those two word this same failure differently.
    pub fn bytes(self: BinInput, allocator: Allocator, ctx: *js.Context, message: []const u8) ![]const u8 {
        const js_str = switch (self) {
            .raw => |v| return v,
            .js_string => |v| v,
        };
        if (!js_str.containsOnlyOneByte()) {
            return ctx.fail(error.InvalidCharacterError, message);
        }
        return js_str.toOneByteSlice(allocator);
    }
};

pub fn encode(alloc: Allocator, input: []const u8) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    return std.base64.standard.Encoder.encode(encoded, input);
}

/// Forgiving base64 decode per WHATWG spec:
/// https://infra.spec.whatwg.org/#forgiving-base64-decode
///
/// std's decoders reject non-canonical trailing bits (e.g. "ab") and only trim
/// padding from the ends, neither of which match forgiving-base64 — so decode by
/// hand: strip *all* ASCII whitespace, validate padding, tolerate trailing bits.
pub fn decode(alloc: Allocator, input: []const u8) ![]const u8 {
    // Step 1: remove all ASCII whitespace (tab, LF, FF, CR, space) from anywhere.
    const buf = try alloc.alloc(u8, input.len);
    var n: usize = 0;
    for (input) |c| switch (c) {
        ' ', '\t', '\n', '\r', std.ascii.control_code.ff => {},
        else => {
            buf[n] = c;
            n += 1;
        },
    };
    var src = buf[0..n];

    // Step 2: only a multiple-of-4 length may carry (and shed) up to two "=".
    if (src.len % 4 == 0) {
        if (std.mem.endsWith(u8, src, "==")) {
            src = src[0 .. src.len - 2];
        } else if (std.mem.endsWith(u8, src, "=")) {
            src = src[0 .. src.len - 1];
        }
    }
    // Step 3: a length % 4 == 1 can't represent valid base64.
    if (src.len % 4 == 1) return error.InvalidCharacterError;
    // Any "=" still present is misplaced padding.
    if (std.mem.indexOfScalar(u8, src, '=') != null) return error.InvalidCharacterError;

    const out_len = src.len / 4 * 3 + switch (src.len % 4) {
        0 => @as(usize, 0),
        2 => 1,
        3 => 2,
        else => unreachable,
    };
    const out = try alloc.alloc(u8, out_len);

    var oi: usize = 0;
    var i: usize = 0;
    while (i + 4 <= src.len) : (i += 4) {
        const a = try b64Val(src[i]);
        const b = try b64Val(src[i + 1]);
        const c = try b64Val(src[i + 2]);
        const d = try b64Val(src[i + 3]);
        out[oi] = (a << 2) | (b >> 4);
        out[oi + 1] = (b << 4) | (c >> 2);
        out[oi + 2] = (c << 6) | d;
        oi += 3;
    }
    switch (src.len - i) {
        0 => {},
        2 => {
            const a = try b64Val(src[i]);
            const b = try b64Val(src[i + 1]);
            out[oi] = (a << 2) | (b >> 4);
        },
        3 => {
            const a = try b64Val(src[i]);
            const b = try b64Val(src[i + 1]);
            const c = try b64Val(src[i + 2]);
            out[oi] = (a << 2) | (b >> 4);
            out[oi + 1] = (b << 4) | (c >> 2);
        },
        else => unreachable,
    }
    return out;
}

fn b64Val(c: u8) !u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => error.InvalidCharacterError,
    };
}
