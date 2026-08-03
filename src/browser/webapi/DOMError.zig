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

// The pre-DOMException error object, removed from the spec years ago and still
// on every Chrome window. It is deliberately *not* an Error subclass: measured
// on a headed Chrome 150, `new DOMError('X') instanceof Error` is false,
// `String(e)` is "[object DOMError]" and there is no `stack`. It carries a name
// and a message and nothing else.

const js = @import("../js/js.zig");

const DOMError = @This();

_name: []const u8,
_message: []const u8,

// `new DOMError(name, message)`. Arity 1 -- Chrome refuses the bare call with
// "1 argument required, but only 0 present.", which the bridge produces from the
// required parameter. Both strings come off a per-call scratch buffer, so they
// are copied for the same reason DOMException copies its own.
pub fn constructor(name: []const u8, message_: ?[]const u8, exec: *const js.Execution) !DOMError {
    return .{
        ._name = try exec.dupeString(name),
        ._message = if (message_) |m| try exec.dupeString(m) else "",
    };
}

pub fn getName(self: *const DOMError) []const u8 {
    return self._name;
}

pub fn getMessage(self: *const DOMError) []const u8 {
    return self._message;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMError);

    pub const Meta = struct {
        pub const name = "DOMError";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMError.constructor, .{});
    pub const name = bridge.accessor(DOMError.getName, null, .{});
    pub const message = bridge.accessor(DOMError.getMessage, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMError" {
    try testing.htmlRunner("dom_error.html", .{});
}
