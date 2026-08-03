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

// The CSS Custom Highlight API: a constructible set of ranges, and the
// name-keyed registry behind `CSS.highlights`. Both do real work here -- a page
// can build a Highlight, put ranges in it, register it and read it all back --
// which is all a page can observe anyway, since nothing here paints.
//
// Measured on a headed Chrome 150 (probe-win28/29/32/33):
//
//   * `new Highlight()` succeeds with size 0, priority 0 and type 'highlight'.
//     The constructor is variadic (`Highlight.length` is 0) and takes ranges:
//     `new Highlight(r1, r2).size` is 2.
//   * `type` is an enum attribute, so an unknown value is *ignored* rather than
//     an error: after `h.type = 'nope'` the old value is still there.
//   * `priority` is a WebIDL long, hence ToInt32: '3' is 3, 2.7 is 2, NaN is 0
//     and 2**32+5 wraps to 5.
//   * `add` returns the Highlight itself; `set` on the registry returns the
//     registry. `clear` and `forEach` return undefined.
//   * A non-range argument is "parameter 1 is not of type 'AbstractRange'." --
//     StaticRange is accepted, a plain object is not.
//   * The registry's default iterator is `entries` (it is maplike); the
//     Highlight's is `values`.
//   * `CSS.highlights` is one object per window (identity holds across calls)
//     and `highlightsFromPoint(x, y)` is an empty array, since nothing paints.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const AbstractRange = @import("../AbstractRange.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;
const GenericIterator = @import("../collections/iterator.zig").Entry;

pub fn registerTypes() []const type {
    return &.{
        Highlight,
        Highlight.KeyIterator,
        Highlight.ValueIterator,
        Highlight.EntryIterator,
        HighlightRegistry,
        HighlightRegistry.KeyIterator,
        HighlightRegistry.ValueIterator,
        HighlightRegistry.EntryIterator,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn requireArgs(
    comptime interface: []const u8,
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
        "Failed to execute '" ++ member ++ "' on '" ++ interface ++ "': {d} argument{s} required, but only {d} present.",
        .{ required, if (required == 1) "" else "s", args.len },
    );
    return throwTypeError(message, exec);
}

pub const Highlight = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _ranges: std.ArrayList(*AbstractRange),
    _priority: i32 = 0,
    _type: Type = .highlight,

    /// https://drafts.csswg.org/css-highlight-api-1/#enumdef-highlighttype
    pub const Type = enum {
        highlight,
        @"spelling-error",
        @"grammar-error",

        fn toString(self: Type) []const u8 {
            return @tagName(self);
        }
    };

    pub fn constructor(ranges: []js.Value, exec: *const Execution) !*Highlight {
        const arena = try exec.getArena(.tiny, "Highlight");
        errdefer arena.release();

        const self = try arena.create(Highlight);
        self.* = .{
            ._arena = arena,
            ._ranges = .empty,
        };

        for (ranges, 0..) |value, i| {
            const range = value.toZig(*AbstractRange) catch {
                const message = try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to construct 'Highlight': parameter {d} is not of type 'AbstractRange'.",
                    .{i + 1},
                );
                return throwTypeError(message, exec);
            };
            try self.insert(range);
        }
        return self;
    }

    pub fn deinit(self: *Highlight, page: *Page) void {
        for (self._ranges.items) |range| {
            range.releaseRef(page);
        }
        // Frees the range list and this Highlight itself.
        self._arena.release();
    }

    pub fn releaseRef(self: *Highlight, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *Highlight) void {
        self._rc.acquire();
    }

    pub fn getSize(self: *const Highlight) u32 {
        return @intCast(self._ranges.items.len);
    }

    pub fn getPriority(self: *const Highlight) i32 {
        return self._priority;
    }

    /// WebIDL long, so ToInt32 rather than a range check.
    pub fn setPriority(self: *Highlight, value: js.Value) void {
        self._priority = value.toI32() catch 0;
    }

    pub fn getType(self: *const Highlight) []const u8 {
        return self._type.toString();
    }

    /// An enum-typed attribute: a value outside the enum leaves the old one in
    /// place instead of throwing.
    pub fn setType(self: *Highlight, value: []const u8) void {
        self._type = std.meta.stringToEnum(Type, value) orelse self._type;
    }

    // Set semantics: adding a range that is already in keeps the size at one.
    fn insert(self: *Highlight, range: *AbstractRange) !void {
        if (self.indexOf(range) != null) {
            return;
        }
        range.acquireRef();
        try self._ranges.append(self._arena.allocator(), range);
    }

    fn indexOf(self: *const Highlight, range: *AbstractRange) ?usize {
        for (self._ranges.items, 0..) |candidate, i| {
            if (candidate == range) {
                return i;
            }
        }
        return null;
    }

    fn argRange(comptime member: []const u8, value: js.Value, exec: *const Execution) !*AbstractRange {
        return value.toZig(*AbstractRange) catch throwTypeError(
            "Failed to execute '" ++ member ++ "' on 'Highlight': parameter 1 is not of type 'AbstractRange'.",
            exec,
        );
    }

    pub fn add(self: *Highlight, args: []js.Value, exec: *const Execution) !*Highlight {
        try requireArgs("Highlight", "add", 1, args, exec);
        try self.insert(try argRange("add", args[0], exec));
        return self;
    }

    pub fn has(self: *Highlight, args: []js.Value, exec: *const Execution) !bool {
        try requireArgs("Highlight", "has", 1, args, exec);
        return self.indexOf(try argRange("has", args[0], exec)) != null;
    }

    pub fn delete(self: *Highlight, args: []js.Value, exec: *const Execution) !bool {
        try requireArgs("Highlight", "delete", 1, args, exec);
        const range = try argRange("delete", args[0], exec);
        const index = self.indexOf(range) orelse return false;
        _ = self._ranges.orderedRemove(index);
        range.releaseRef(exec.page);
        return true;
    }

    pub fn clear(self: *Highlight, page: *Page) void {
        for (self._ranges.items) |range| {
            range.releaseRef(page);
        }
        self._ranges.clearRetainingCapacity();
    }

    pub fn forEach(self: *Highlight, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

        for (self._ranges.items) |range| {
            var caught: js.TryCatch.Caught = undefined;
            // A setlike hands the value twice: (value, key, set).
            cb.tryCall(void, .{ range, range, self }, &caught) catch {
                log.debug(.js, "forEach callback", .{ .caught = caught, .source = "Highlight" });
            };
        }
    }

    pub fn keys(self: *Highlight, frame: *Frame) !*KeyIterator {
        return .init(.{ .highlight = self }, frame);
    }

    pub fn values(self: *Highlight, frame: *Frame) !*ValueIterator {
        return .init(.{ .highlight = self }, frame);
    }

    pub fn entries(self: *Highlight, frame: *Frame) !*EntryIterator {
        return .init(.{ .highlight = self }, frame);
    }

    pub const Iterator = struct {
        index: u32 = 0,
        highlight: *Highlight,

        pub const Entry = struct { *AbstractRange, *AbstractRange };

        pub fn acquireRef(self: *Iterator) void {
            self.highlight.acquireRef();
        }

        pub fn releaseRef(self: *Iterator, page: *Page) void {
            self.highlight.releaseRef(page);
        }

        pub fn next(self: *Iterator, _: *const Frame) ?Iterator.Entry {
            const items = self.highlight._ranges.items;
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

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Highlight);

        pub const Meta = struct {
            pub const name = "Highlight";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Variadic, so `Highlight.length` is 0 rather than 1 (measured).
        pub const constructor = bridge.constructor(Highlight.constructor, .{ .arity = 0 });

        // Chrome's own prototype order: the two attributes, then size, then the
        // setlike operations alphabetically (measured).
        pub const priority = bridge.accessor(Highlight.getPriority, Highlight.setPriority, .{});
        pub const @"type" = bridge.accessor(Highlight.getType, Highlight.setType, .{});
        pub const size = bridge.accessor(Highlight.getSize, null, .{});
        pub const add = bridge.function(Highlight.add, .{ .arity = 1 });
        pub const clear = bridge.function(Highlight.clear, .{});
        pub const delete = bridge.function(Highlight.delete, .{ .arity = 1 });
        pub const entries = bridge.function(Highlight.entries, .{});
        pub const forEach = bridge.function(Highlight.forEach, .{ .arity = 1 });
        pub const has = bridge.function(Highlight.has, .{ .arity = 1 });
        pub const keys = bridge.function(Highlight.keys, .{});
        pub const values = bridge.function(Highlight.values, .{});
        pub const symbol_iterator = bridge.iterator(Highlight.values, .{ .js_name = "values" });
    };
};

/// `CSS.highlights`: a maplike of name -> Highlight. Not constructible.
pub const HighlightRegistry = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _entries: std.ArrayList(Registration),

    const Registration = struct {
        name: String,
        highlight: *Highlight,
    };

    pub fn init(frame: *Frame) !*HighlightRegistry {
        const arena = try frame.getArena(.tiny, "HighlightRegistry");
        errdefer arena.release();

        const self = try arena.create(HighlightRegistry);
        self.* = .{
            ._arena = arena,
            ._entries = .empty,
        };
        return self;
    }

    pub fn deinit(self: *HighlightRegistry, page: *Page) void {
        for (self._entries.items) |entry| {
            entry.highlight.releaseRef(page);
        }
        self._arena.release();
    }

    pub fn releaseRef(self: *HighlightRegistry, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *HighlightRegistry) void {
        self._rc.acquire();
    }

    pub fn getSize(self: *const HighlightRegistry) u32 {
        return @intCast(self._entries.items.len);
    }

    fn indexOf(self: *const HighlightRegistry, name: []const u8) ?usize {
        for (self._entries.items, 0..) |entry, i| {
            if (entry.name.eqlSlice(name)) {
                return i;
            }
        }
        return null;
    }

    pub fn set(self: *HighlightRegistry, args: []js.Value, exec: *const Execution) !*HighlightRegistry {
        try requireArgs("HighlightRegistry", "set", 2, args, exec);
        const name = try args[0].toZig([]const u8);
        const highlight = args[1].toZig(*Highlight) catch return throwTypeError(
            "Failed to execute 'set' on 'HighlightRegistry': parameter 2 is not of type 'Highlight'.",
            exec,
        );

        highlight.acquireRef();
        if (self.indexOf(name)) |index| {
            // Replacing keeps the slot, so the insertion order is unchanged.
            const previous = self._entries.items[index].highlight;
            self._entries.items[index].highlight = highlight;
            previous.releaseRef(exec.page);
            return self;
        }

        try self._entries.append(self._arena.allocator(), .{
            .name = try String.init(self._arena.allocator(), name, .{}),
            .highlight = highlight,
        });
        return self;
    }

    /// Undefined rather than null for a name that was never registered
    /// (measured), which is what a maplike `get` answers.
    pub fn get(self: *HighlightRegistry, args: []js.Value, exec: *const Execution) !?*Highlight {
        try requireArgs("HighlightRegistry", "get", 1, args, exec);
        const index = self.indexOf(try args[0].toZig([]const u8)) orelse return null;
        return self._entries.items[index].highlight;
    }

    pub fn has(self: *HighlightRegistry, args: []js.Value, exec: *const Execution) !bool {
        try requireArgs("HighlightRegistry", "has", 1, args, exec);
        return self.indexOf(try args[0].toZig([]const u8)) != null;
    }

    pub fn delete(self: *HighlightRegistry, args: []js.Value, exec: *const Execution) !bool {
        try requireArgs("HighlightRegistry", "delete", 1, args, exec);
        const index = self.indexOf(try args[0].toZig([]const u8)) orelse return false;
        const removed = self._entries.orderedRemove(index);
        removed.highlight.releaseRef(exec.page);
        return true;
    }

    pub fn clear(self: *HighlightRegistry, page: *Page) void {
        for (self._entries.items) |entry| {
            entry.highlight.releaseRef(page);
        }
        self._entries.clearRetainingCapacity();
    }

    pub fn forEach(self: *HighlightRegistry, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

        for (self._entries.items) |entry| {
            var caught: js.TryCatch.Caught = undefined;
            cb.tryCall(void, .{ entry.highlight, entry.name.str(), self }, &caught) catch {
                log.debug(.js, "forEach callback", .{ .caught = caught, .source = "HighlightRegistry" });
            };
        }
    }

    /// Nothing here paints, so no highlight can cover a point.
    pub fn highlightsFromPoint(_: *HighlightRegistry, args: []js.Value, exec: *const Execution) ![]const *Highlight {
        try requireArgs("HighlightRegistry", "highlightsFromPoint", 2, args, exec);
        return &.{};
    }

    pub fn keys(self: *HighlightRegistry, frame: *Frame) !*KeyIterator {
        return .init(.{ .registry = self }, frame);
    }

    pub fn values(self: *HighlightRegistry, frame: *Frame) !*ValueIterator {
        return .init(.{ .registry = self }, frame);
    }

    pub fn entries(self: *HighlightRegistry, frame: *Frame) !*EntryIterator {
        return .init(.{ .registry = self }, frame);
    }

    pub const Iterator = struct {
        index: u32 = 0,
        registry: *HighlightRegistry,

        pub const Entry = struct { []const u8, *Highlight };

        pub fn acquireRef(self: *Iterator) void {
            self.registry.acquireRef();
        }

        pub fn releaseRef(self: *Iterator, page: *Page) void {
            self.registry.releaseRef(page);
        }

        pub fn next(self: *Iterator, _: *const Frame) ?Iterator.Entry {
            const items = self.registry._entries.items;
            const index = self.index;
            if (index >= items.len) {
                return null;
            }
            self.index = index + 1;
            return .{ items[index].name.str(), items[index].highlight };
        }
    };

    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HighlightRegistry);

        pub const Meta = struct {
            pub const name = "HighlightRegistry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order: size, the maplike operations
        // alphabetically, then highlightsFromPoint (measured).
        pub const size = bridge.accessor(HighlightRegistry.getSize, null, .{});
        pub const clear = bridge.function(HighlightRegistry.clear, .{});
        pub const delete = bridge.function(HighlightRegistry.delete, .{ .arity = 1 });
        pub const entries = bridge.function(HighlightRegistry.entries, .{});
        pub const forEach = bridge.function(HighlightRegistry.forEach, .{ .arity = 1 });
        pub const get = bridge.function(HighlightRegistry.get, .{ .arity = 1, .null_as_undefined = true });
        pub const has = bridge.function(HighlightRegistry.has, .{ .arity = 1 });
        pub const keys = bridge.function(HighlightRegistry.keys, .{});
        pub const set = bridge.function(HighlightRegistry.set, .{ .arity = 2 });
        pub const values = bridge.function(HighlightRegistry.values, .{});
        pub const highlightsFromPoint = bridge.function(HighlightRegistry.highlightsFromPoint, .{ .arity = 2 });
        pub const symbol_iterator = bridge.iterator(HighlightRegistry.entries, .{ .js_name = "entries" });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: Highlight" {
    try testing.htmlRunner("css/highlights.html", .{});
}
