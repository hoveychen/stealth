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
// custom element exposes to the `:state()` selector. The only way to reach an
// instance is `element.attachInternals().states`.
//
// Chrome does *not* validate the dashed-ident form, so `states.add('nope')` is
// accepted (measured on Chrome 150, probe-win29), and it does not fold that form
// when matching either: after `states.add('--on')`, `el.matches(':state(on)')` is
// false (measured, probe-win64). The `:state()` selector reads this set through
// ElementInternals.hasState, so the matching ident finds the element.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Execution = js.Execution;
const GenericIterator = @import("../collections/iterator.zig").Entry;

const CustomStateSet = @This();

_states: std.ArrayListUnmanaged([]const u8) = .empty,

fn indexOf(self: *const CustomStateSet, state: []const u8) ?usize {
    for (self._states.items, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, state)) {
            return i;
        }
    }
    return null;
}

/// `has` without the JS argument plumbing, for the `:state()` selector.
pub fn contains(self: *const CustomStateSet, state: []const u8) bool {
    return self.indexOf(state) != null;
}

pub fn getSize(self: *const CustomStateSet) u32 {
    return @intCast(self._states.items.len);
}

pub fn add(self: *CustomStateSet, args: []js.Value, exec: *const Execution) !void {
    const state = try argState("add", args, exec);
    if (self.indexOf(state) != null) {
        return;
    }
    try self._states.append(exec.arena, try exec.dupeString(state));
}

pub fn has(self: *CustomStateSet, args: []js.Value, exec: *const Execution) !bool {
    return self.indexOf(try argState("has", args, exec)) != null;
}

pub fn delete(self: *CustomStateSet, args: []js.Value, exec: *const Execution) !bool {
    const index = self.indexOf(try argState("delete", args, exec)) orelse return false;
    _ = self._states.orderedRemove(index);
    return true;
}

pub fn clear(self: *CustomStateSet) void {
    self._states.clearRetainingCapacity();
}

pub fn forEach(self: *CustomStateSet, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._states.items) |state| {
        var caught: js.TryCatch.Caught = .{};
        // A setlike hands the value twice: (value, key, set).
        cb.tryCall(void, .{ state, state, self }, &caught) catch {
            lp.log.debug(.js, "forEach callback", .{ .caught = caught, .source = "CustomStateSet" });
        };
    }
}

pub fn keys(self: *CustomStateSet, exec: *const Execution) !*KeyIterator {
    return .init(.{ .set = self }, exec);
}

pub fn values(self: *CustomStateSet, exec: *const Execution) !*ValueIterator {
    return .init(.{ .set = self }, exec);
}

pub fn entries(self: *CustomStateSet, exec: *const Execution) !*EntryIterator {
    return .init(.{ .set = self }, exec);
}

// The bridge only produces WebIDL's "N argument(s) required" for constructors,
// so a setlike operation has to raise it by hand.
fn argState(comptime member: []const u8, args: []js.Value, exec: *const Execution) ![]const u8 {
    if (args.len == 0) {
        return @import("../dictionary.zig").throwTypeError(
            "Failed to execute '" ++ member ++ "' on 'CustomStateSet': 1 argument required, but only 0 present.",
            exec,
        );
    }
    return args[0].toStringSlice();
}

pub const Iterator = struct {
    index: u32 = 0,
    set: *CustomStateSet,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
        const items = self.set._states.items;
        const index = self.index;
        if (index >= items.len) {
            return null;
        }
        self.index = index + 1;
        return .{ items[index], items[index] };
    }
};

pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub fn registerTypes() []const type {
    return &.{ CustomStateSet, KeyIterator, ValueIterator, EntryIterator };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CustomStateSet);

    pub const Meta = struct {
        pub const name = "CustomStateSet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own prototype order: size, then the setlike operations
    // alphabetically, with values as the default iterator (measured).
    pub const size = bridge.accessor(CustomStateSet.getSize, null, .{});
    pub const add = bridge.function(CustomStateSet.add, .{ .arity = 1 });
    pub const clear = bridge.function(CustomStateSet.clear, .{});
    pub const delete = bridge.function(CustomStateSet.delete, .{ .arity = 1 });
    pub const entries = bridge.function(CustomStateSet.entries, .{});
    pub const forEach = bridge.function(CustomStateSet.forEach, .{ .arity = 1 });
    pub const has = bridge.function(CustomStateSet.has, .{ .arity = 1 });
    pub const keys = bridge.function(CustomStateSet.keys, .{});
    pub const values = bridge.function(CustomStateSet.values, .{});
    pub const symbol_iterator = bridge.iterator(CustomStateSet.values, .{ .js_name = "values" });
};

const testing = @import("../../../testing.zig");
test "WebApi: CustomStateSet" {
    try testing.htmlRunner("element/custom_state_set.html", .{});
}
