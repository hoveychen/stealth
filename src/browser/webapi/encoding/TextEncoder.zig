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

const std = @import("std");
const js = @import("../../js/js.zig");

const TextEncoder = @This();
_pad: bool = false,

pub fn init() TextEncoder {
    return .{};
}

pub fn encode(_: *const TextEncoder, v_: ?js.Value, exec: *const js.Execution) !js.TypedArray(u8) {
    const v = v_ orelse return .{ .values = "" };

    if (v.isUndefined()) {
        return .{ .values = "" };
    }

    if (v.isNull()) {
        return .{ .values = "null" };
    }

    const str = try v.toStringSlice();
    if (!std.unicode.utf8ValidateSlice(str)) {
        return error.InvalidUtf8;
    }

    // The one place a guard's telemetry is in the clear -- see
    // `Context.encoded_texts`. Off unless the `text_encode` scope is on.
    exec.js.recordTextEncode(str);

    return .{ .values = str };
}

const encode_into_prefix = "Failed to execute 'encodeInto' on 'TextEncoder': ";

/// https://encoding.spec.whatwg.org/#dom-textencoder-encodeinto
///
/// Writes straight into the caller's Uint8Array and reports how much of the
/// source it got through, so a page can encode without allocating. Measured on
/// Chrome 151: the result is a plain object rather than an interface instance,
/// a code point is never split across the end of the destination
/// (`encodeInto('é€', new Uint8Array(3))` reads 1 and writes 2, leaving the
/// third byte at 0), an empty destination writes nothing rather than throwing,
/// and anything that is not a Uint8Array is refused by parameter number.
pub fn encodeInto(_: *const TextEncoder, source: js.Value, destination: js.Object, exec: *const js.Execution) !EncodeIntoResult {
    if (!destination.toValue().isUint8Array()) {
        return exec.js.fail(error.TypeMismatch, encode_into_prefix ++
            "parameter 2 is not of type 'Uint8Array'.");
    }
    const into = try destination.toZig([]u8);
    const text = try source.toStringSlice();

    var read: u32 = 0;
    var written: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        if (written + width > into.len) {
            break;
        }
        @memcpy(into[written..][0..width], text[i..][0..width]);
        written += width;
        i += width;
        // `read` counts UTF-16 code units, which is what the page's own string
        // is indexed in: an astral code point is four UTF-8 bytes and two of
        // these.
        read += if (width == 4) 2 else 1;
    }
    return .{ .read = read, .written = @intCast(written) };
}

const EncodeIntoResult = struct {
    read: u32,
    written: u32,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEncoder);

    pub const Meta = struct {
        pub const name = "TextEncoder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    // Declaration order is own-property order, and this is Chrome 151's own
    // Object.getOwnPropertyNames(TextEncoder.prototype): the attribute first,
    // then the two operations.
    pub const constructor = bridge.constructor(TextEncoder.init, .{});
    pub const encoding = bridge.property("utf-8", .{ .template = false });
    pub const encode = bridge.function(TextEncoder.encode, .{ .as_typed_array = true });
    pub const encodeInto = bridge.function(TextEncoder.encodeInto, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEncoder" {
    try testing.htmlRunner("encoding/text_encoder.html", .{});
}
