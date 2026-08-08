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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Chrome's XSLT 1.0 processor, still on every window and still constructible.
// The parameter store and every argument check here are real; the transform
// itself is not -- there is no XSLT engine in this codebase, so
// transformToDocument / transformToFragment answer null and log
// `not_implemented`. Chrome answers null too until a stylesheet is imported,
// which is the state a page that only pokes at the interface ever sees.
//
// Measured on a headed Chrome 150 (probe-win28/29/32):
//
//   * The namespace argument to setParameter / getParameter / removeParameter
//     is *ignored*: `p.setParameter('urn:x', 'a', 'v')` is readable as
//     `p.getParameter(null, 'a')`. Parameters are keyed by local name alone.
//   * Values are stringified on the way in -- `setParameter(null, 'c', 7)`
//     reads back as the string "7".
//   * reset() drops the parameters and the stylesheet; clearParameters() drops
//     only the parameters.
//   * getParameter for a name that was never set is null, not undefined.
//
// Every operation takes its arguments as a variadic `[]js.Value` rather than
// typed parameters. The bridge only counts arguments for constructors, and the
// namespace argument is legitimately null on every real call, so counting has to
// happen here for the "N arguments required" messages to read like Chrome's.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const KeyValueList = @import("KeyValueList.zig");

const log = lp.log;
const Execution = js.Execution;

const XSLTProcessor = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_parameters: KeyValueList,
_stylesheet: ?*Node = null,

pub fn constructor(exec: *const Execution) !*XSLTProcessor {
    const arena = try exec.getArena(.tiny, "XSLTProcessor");
    errdefer arena.release();

    const self = try arena.create(XSLTProcessor);
    self.* = .{
        ._arena = arena,
        ._parameters = .empty,
    };
    return self;
}

pub fn deinit(self: *XSLTProcessor, _: *Page) void {
    // Frees the parameter list and this processor itself.
    self._arena.release();
}

pub fn releaseRef(self: *XSLTProcessor, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *XSLTProcessor) void {
    self._rc.acquire();
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn requireArgs(
    comptime member: []const u8,
    comptime required: usize,
    args: []js.Value,
    exec: *const Execution,
) !void {
    if (args.len >= required) {
        return;
    }
    const message = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ member ++ "' on 'XSLTProcessor': {d} argument{s} required, but only {d} present.",
        .{ required, if (required == 1) "" else "s", args.len },
    );
    return throwTypeError(message, exec);
}

fn requireNode(comptime member: []const u8, value: js.Value, exec: *const Execution) !*Node {
    return value.toZig(*Node) catch throwTypeError(
        "Failed to execute '" ++ member ++ "' on 'XSLTProcessor': parameter 1 is not of type 'Node'.",
        exec,
    );
}

pub fn importStylesheet(self: *XSLTProcessor, args: []js.Value, exec: *const Execution) !void {
    try requireArgs("importStylesheet", 1, args, exec);
    self._stylesheet = try requireNode("importStylesheet", args[0], exec);
}

/// The namespace argument is accepted and dropped: Chrome keys parameters by
/// local name only (measured -- a parameter set under 'urn:x' reads back
/// under null).
pub fn setParameter(self: *XSLTProcessor, args: []js.Value, exec: *const Execution) !void {
    try requireArgs("setParameter", 3, args, exec);
    const local_name = try args[1].toZig([]const u8);
    const value = try args[2].toZig([]const u8);
    return self._parameters.set(self._arena.allocator(), local_name, value);
}

pub fn getParameter(self: *const XSLTProcessor, args: []js.Value, exec: *const Execution) !?[]const u8 {
    try requireArgs("getParameter", 2, args, exec);
    return self._parameters.get(try args[1].toZig([]const u8));
}

pub fn removeParameter(self: *XSLTProcessor, args: []js.Value, exec: *const Execution) !void {
    try requireArgs("removeParameter", 2, args, exec);
    self._parameters.delete(try args[1].toZig([]const u8), null);
}

pub fn clearParameters(self: *XSLTProcessor) void {
    self._parameters = .empty;
}

pub fn reset(self: *XSLTProcessor) void {
    self.clearParameters();
    self._stylesheet = null;
}

pub fn transformToDocument(self: *XSLTProcessor, args: []js.Value, exec: *const Execution) !?*Node {
    try requireArgs("transformToDocument", 1, args, exec);
    _ = try requireNode("transformToDocument", args[0], exec);
    return self.transform();
}

pub fn transformToFragment(self: *XSLTProcessor, args: []js.Value, exec: *const Execution) !?*Node {
    try requireArgs("transformToFragment", 2, args, exec);
    _ = try requireNode("transformToFragment", args[0], exec);
    return self.transform();
}

// Null with no stylesheet is Chrome's answer too. With one, this is where an
// XSLT engine would go.
fn transform(self: *const XSLTProcessor) ?*Node {
    if (self._stylesheet != null) {
        log.warn(.not_implemented, "XSLTProcessor.transform", .{});
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XSLTProcessor);

    pub const Meta = struct {
        pub const name = "XSLTProcessor";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(XSLTProcessor.constructor, .{});

    // Chrome's own prototype order is alphabetical here (measured).
    pub const clearParameters = bridge.function(XSLTProcessor.clearParameters, .{});
    pub const getParameter = bridge.function(XSLTProcessor.getParameter, .{ .arity = 2 });
    pub const importStylesheet = bridge.function(XSLTProcessor.importStylesheet, .{ .arity = 1 });
    pub const removeParameter = bridge.function(XSLTProcessor.removeParameter, .{ .arity = 2 });
    pub const reset = bridge.function(XSLTProcessor.reset, .{});
    pub const setParameter = bridge.function(XSLTProcessor.setParameter, .{ .arity = 3 });
    pub const transformToDocument = bridge.function(XSLTProcessor.transformToDocument, .{ .arity = 1 });
    pub const transformToFragment = bridge.function(XSLTProcessor.transformToFragment, .{ .arity = 2 });
};

const testing = @import("../../testing.zig");
test "WebApi: XSLTProcessor" {
    testing.expectLog(&.{ .not_implemented, .not_implemented });
    try testing.htmlRunner("xslt.html", .{});
}
