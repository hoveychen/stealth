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

// `elementInternals.states`: the setlike of custom states a form-associated
// custom element exposes to the `:state()` selector.
//
// The interface is on every Chrome window and cannot be constructed -- the only
// way to reach an instance is `element.attachInternals().states`, and there is
// no ElementInternals here yet (it is one of the globals tracked in
// tools/fingerprint/results/creep-features-missing.json). So this is the shape
// alone: the constructor, the prototype's eleven members with the arities and
// flags Chrome reports, and the brand. No instance ever exists, so none of the
// operations can run; they exist to be enumerated.
//
// When ElementInternals lands, this is where the set goes -- along with the one
// behaviour worth copying over: Chrome does *not* validate the dashed-ident
// form, so `states.add('nope')` is accepted (measured on Chrome 150,
// probe-win29).

const js = @import("../../js/js.zig");

const CustomStateSet = @This();

// Padding to avoid a zero-size struct, which causes identity_map pointer
// collisions.
_pad: bool = false,

pub const JsApi = struct {
    pub const bridge = js.Bridge(CustomStateSet);

    pub const Meta = struct {
        pub const name = "CustomStateSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    fn unreachableSize(_: *CustomStateSet) u32 {
        return 0;
    }

    fn unreachableMethod(_: *CustomStateSet, _: ?js.Value) void {}

    // Chrome's own prototype order: size, then the setlike operations
    // alphabetically, with values as the default iterator (measured).
    pub const size = bridge.accessor(unreachableSize, null, .{});
    pub const add = bridge.function(unreachableMethod, .{ .noop = true, .arity = 1 });
    pub const clear = bridge.function(unreachableMethod, .{ .noop = true });
    pub const delete = bridge.function(unreachableMethod, .{ .noop = true, .arity = 1 });
    pub const entries = bridge.function(unreachableMethod, .{ .noop = true });
    pub const forEach = bridge.function(unreachableMethod, .{ .noop = true, .arity = 1 });
    pub const has = bridge.function(unreachableMethod, .{ .noop = true, .arity = 1 });
    pub const keys = bridge.function(unreachableMethod, .{ .noop = true });
    pub const values = bridge.function(unreachableMethod, .{ .noop = true });
    pub const symbol_iterator = bridge.iterator(unreachableMethod, .{ .js_name = "values" });
};

const testing = @import("../../../testing.zig");
test "WebApi: CustomStateSet" {
    try testing.htmlRunner("element/custom_state_set.html", .{});
}
