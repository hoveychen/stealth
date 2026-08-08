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

// The colour picker. Constructible on any window, and `open()` is gated on a
// user gesture -- which is exactly the state a script that probes the interface
// sees, so the rejection here is Chrome's own (measured on a headed Chrome 150,
// probe-win28/29): NotAllowedError, "EyeDropper::open() requires user gesture."
// Nothing here can open a picker, so that gate is also the whole behaviour.

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

const EyeDropper = @This();

// Padding to avoid a zero-size struct, which causes identity_map pointer
// collisions.
_pad: bool = false,

pub fn constructor(page: *Page) !*EyeDropper {
    return page.factory.create(EyeDropper{});
}

pub fn open(_: *EyeDropper, _: ?js.Value, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("EyeDropper.open", DOMException.init(
        "Failed to execute 'open' on 'EyeDropper': EyeDropper::open() requires user gesture.",
        "NotAllowedError",
    ));
    return resolver.promise();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EyeDropper);

    pub const Meta = struct {
        pub const name = "EyeDropper";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(EyeDropper.constructor, .{});
    pub const open = bridge.function(EyeDropper.open, .{ .arity = 0 });
};

const testing = @import("../../testing.zig");
test "WebApi: EyeDropper" {
    try testing.htmlRunner("eye_dropper.html", .{});
}
