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

const js = @import("../../js/js.zig");
const AbortSignal = @import("../AbortSignal.zig");
const WritableStream = @import("WritableStream.zig");

const Execution = js.Execution;

const WritableStreamDefaultController = @This();

_stream: *WritableStream,
_signal: ?*AbortSignal = null,

pub fn init(stream: *WritableStream, exec: *const Execution) !*WritableStreamDefaultController {
    return exec._factory.create(WritableStreamDefaultController{
        ._stream = stream,
    });
}

/// The signal a sink's abort() would fire. Nothing aborts here, but it is the
/// same object on every read, as Chrome's is.
pub fn getSignal(self: *WritableStreamDefaultController, exec: *const Execution) !*AbortSignal {
    if (self._signal == null) {
        self._signal = try AbortSignal.init(exec);
    }
    return self._signal.?;
}

pub fn doError(self: *WritableStreamDefaultController, reason: []const u8) void {
    if (self._stream._state != .writable) return;
    self._stream._state = .errored;
    self._stream._stored_error = reason;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WritableStreamDefaultController);

    pub const Meta = struct {
        pub const name = "WritableStreamDefaultController";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const signal = bridge.accessor(WritableStreamDefaultController.getSignal, null, .{});
    pub const @"error" = bridge.function(WritableStreamDefaultController.doError, .{ .arity = 0 });
};
