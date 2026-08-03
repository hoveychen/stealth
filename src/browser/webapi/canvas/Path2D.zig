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

// The retained-path half of the canvas path API. The context's own path
// methods (beginPath, moveTo, lineTo, rect, fill, stroke, clip) are already
// no-ops here -- this engine rasterises rect fills and nothing else -- so a
// Path2D records nothing either: it is the object identity, the eleven method
// names and their arities that a detector reads. A page that builds a path and
// fills it gets the same blank result it gets from the context's path today,
// which is the existing canvas gap, not a new one.
//
// The prototype's member order is Chrome's own (measured): the interface's two
// members first, then the CanvasPath mixin's nine in alphabetical order.

const js = @import("../../js/js.zig");

const Path2D = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer
// collisions. Deliberately not `empty_with_no_proto`: that flag drops the Zig
// pointer, and then addPath's `toZig(*Path2D)` accepts any object at all --
// Chrome rejects a plain `{}` there.
_pad: bool = false,

fn throwTypeError(message: []const u8, exec: *const js.Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

/// Chrome takes `(Path2D or DOMString)` and reports arity 0, and it does not
/// validate the string: `new Path2D('not a path')` is accepted (measured).
pub fn init(_: ?js.Value) Path2D {
    return .{};
}

pub fn addPath(_: *Path2D, path_: ?js.Value, exec: *const js.Execution) !void {
    const path = path_ orelse return;
    _ = path.toZig(*Path2D) catch return throwTypeError(
        "Failed to execute 'addPath' on 'Path2D': parameter 1 is not of type 'Path2D'.",
        exec,
    );
}

/// The nine CanvasPath methods and roundRect record nothing; only their names
/// and arities are observable. One body serves them all, with the arity given
/// explicitly at the JsApi.
fn noop(_: *Path2D) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Path2D);

    pub const Meta = struct {
        pub const name = "Path2D";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Path2D.init, .{});

    // Path2D's own two members.
    pub const addPath = bridge.function(Path2D.addPath, .{ .arity = 1 });
    pub const roundRect = bridge.function(Path2D.noop, .{ .noop = true, .arity = 4 });

    // The CanvasPath mixin, in the order Chrome lists it.
    pub const arc = bridge.function(Path2D.noop, .{ .noop = true, .arity = 5 });
    pub const arcTo = bridge.function(Path2D.noop, .{ .noop = true, .arity = 5 });
    pub const bezierCurveTo = bridge.function(Path2D.noop, .{ .noop = true, .arity = 6 });
    pub const closePath = bridge.function(Path2D.noop, .{ .noop = true, .arity = 0 });
    pub const ellipse = bridge.function(Path2D.noop, .{ .noop = true, .arity = 7 });
    pub const lineTo = bridge.function(Path2D.noop, .{ .noop = true, .arity = 2 });
    pub const moveTo = bridge.function(Path2D.noop, .{ .noop = true, .arity = 2 });
    pub const quadraticCurveTo = bridge.function(Path2D.noop, .{ .noop = true, .arity = 4 });
    pub const rect = bridge.function(Path2D.noop, .{ .noop = true, .arity = 4 });
};

const testing = @import("../../../testing.zig");
test "WebApi: Path2D" {
    try testing.htmlRunner("canvas/path2d.html", .{});
}
