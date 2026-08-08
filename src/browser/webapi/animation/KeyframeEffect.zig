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

// https://developer.mozilla.org/en-US/docs/Web/API/KeyframeEffect
//
// The effect behind `element.animate()` and the only AnimationEffect a page can
// build. Nothing here runs an animation -- there is no timeline and no
// compositor -- but the effect is a data structure a page can read back in
// full, and `animation.effect` used to be null even after `animate()`, which
// Chrome never is.
//
// The two things worth spelling out, both measured on a headed Chrome 150
// (probe-win29):
//
//   * A keyframe read back from getKeyframes() is not the object that went in.
//     It always carries offset / easing / composite first, the properties in
//     the middle with every value stringified, and computedOffset last. A
//     single keyframe computes to offset 1, not 0.
//   * getTiming() reports what was asked for ("auto" fill, "auto" duration)
//     while getComputedTiming() reports what it resolved to ("none" fill, a
//     numeric duration) plus activeDuration / endTime.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const dictionary = @import("../dictionary.zig");

const AnimationEffect = @import("effects.zig").AnimationEffect;

const Execution = js.Execution;

const KeyframeEffect = @This();

pub const Proto = AnimationEffect;

const Reader = dictionary.Reader("KeyframeEffect", "KeyframeEffectOptions");

_proto: *AnimationEffect,
_rc: lp.RC = .{},
_arena: *lp.Arena,
_target: ?*Element = null,
_pseudo_element: ?[]const u8 = null,
_composite: []const u8 = "replace",
_keyframes: []const Keyframe = &.{},

/// One computed keyframe. The property list keeps the order the page wrote it
/// in, which is the order getKeyframes() hands it back in.
const Keyframe = struct {
    offset: ?f64,
    easing: []const u8,
    composite: []const u8,
    computed_offset: f64,
    properties: []const Property,
};

const Property = struct {
    name: []const u8,
    value: []const u8,
};

/// `offset`, `easing` and `composite` are the keyframe's own members; every
/// other key on a keyframe object is an animated property.
const reserved = std.StaticStringMap(void).initComptime(.{
    .{"offset"}, .{"easing"}, .{"composite"},
});

pub fn constructor(
    source: ?js.Value,
    keyframes_: ?js.Value,
    options_: ?js.Value,
    exec: *const Execution,
) !*KeyframeEffect {
    // The copy constructor: `new KeyframeEffect(otherEffect)`.
    if (source) |value| {
        if (value.isObject()) {
            if (value.toZig(*KeyframeEffect)) |other| {
                return copy(other, exec);
            } else |_| {}
        }
    }

    const target: ?*Element = blk: {
        const value = source orelse break :blk null;
        if (value.isNullOrUndefined()) {
            break :blk null;
        }
        break :blk value.toZig(*Element) catch return dictionary.throwTypeError(
            "Failed to construct 'KeyframeEffect': parameter 1 is not of type 'Element'.",
            exec,
        );
    };

    const arena = try exec.getArena(.small, "KeyframeEffect");
    errdefer arena.release();

    const self = try exec._factory.animationEffect(arena.allocator(), KeyframeEffect{
        ._proto = undefined,
        ._arena = arena,
        ._target = target,
    });
    self._keyframes = try readKeyframes(keyframes_, arena.allocator(), exec);
    try readOptions(self, options_, arena.allocator(), exec);
    return self;
}

fn copy(other: *KeyframeEffect, exec: *const Execution) !*KeyframeEffect {
    const arena = try exec.getArena(.small, "KeyframeEffect");
    errdefer arena.release();

    const self = try exec._factory.animationEffect(arena.allocator(), KeyframeEffect{
        ._proto = undefined,
        ._arena = arena,
        ._target = other._target,
        ._pseudo_element = other._pseudo_element,
        ._composite = other._composite,
        ._keyframes = other._keyframes,
    });
    self._proto.* = other._proto.*;
    return self;
}

/// `element.animate(keyframes, options)` builds one of these with the element
/// as its target.
pub fn initForTarget(
    target: *Element,
    keyframes_: ?js.Value,
    options_: ?js.Value,
    exec: *const Execution,
) !*KeyframeEffect {
    const arena = try exec.getArena(.small, "KeyframeEffect");
    errdefer arena.release();

    const self = try exec._factory.animationEffect(arena.allocator(), KeyframeEffect{
        ._proto = undefined,
        ._arena = arena,
        ._target = target,
    });
    self._keyframes = try readKeyframes(keyframes_, arena.allocator(), exec);
    try readOptions(self, options_, arena.allocator(), exec);
    return self;
}

pub fn deinit(self: *KeyframeEffect, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *KeyframeEffect) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *KeyframeEffect, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getTarget(self: *const KeyframeEffect) ?*Element {
    return self._target;
}

pub fn setTarget(self: *KeyframeEffect, target: ?*Element) void {
    self._target = target;
}

pub fn getPseudoElement(self: *const KeyframeEffect) ?[]const u8 {
    return self._pseudo_element;
}

pub fn setPseudoElement(self: *KeyframeEffect, pseudo: ?[]const u8) !void {
    if (pseudo) |value| {
        self._pseudo_element = try self._arena.allocator().dupe(u8, value);
        return;
    }
    self._pseudo_element = null;
}

pub fn getComposite(self: *const KeyframeEffect) []const u8 {
    return self._composite;
}

/// An enumerated attribute: an unrecognised value is ignored, not an error.
pub fn setComposite(self: *KeyframeEffect, composite: []const u8) void {
    self._composite = compositeOperation(composite) orelse self._composite;
}

pub fn getKeyframes(self: *const KeyframeEffect, exec: *const Execution) !js.Array {
    const local = exec.js.local.?;
    const array = local.newArray(@intCast(self._keyframes.len));
    for (self._keyframes, 0..) |keyframe, i| {
        const object = local.newObject();
        if (keyframe.offset) |offset| {
            _ = try object.set("offset", offset, .{});
        } else {
            _ = try object.set("offset", null, .{});
        }
        _ = try object.set("easing", keyframe.easing, .{});
        _ = try object.set("composite", keyframe.composite, .{});
        for (keyframe.properties) |property| {
            _ = try object.set(property.name, property.value, .{});
        }
        _ = try object.set("computedOffset", keyframe.computed_offset, .{});
        _ = try array.set(@intCast(i), object, .{});
    }
    return array;
}

pub fn setKeyframes(self: *KeyframeEffect, keyframes_: ?js.Value, exec: *const Execution) !void {
    self._keyframes = try readKeyframes(keyframes_, self._arena.allocator(), exec);
}

// ---------------------------------------------------------------------------
// Reading the two arguments

/// Both keyframe forms: the array of keyframe objects, and the object form
/// whose values are per-keyframe lists (`{opacity: [0, 1]}`), which is what
/// most `element.animate()` calls use.
fn readKeyframes(
    keyframes_: ?js.Value,
    allocator: std.mem.Allocator,
    exec: *const Execution,
) ![]const Keyframe {
    const value = keyframes_ orelse return &.{};
    if (value.isNullOrUndefined() or !value.isObject()) {
        return &.{};
    }

    const frames = if (value.isArray())
        try readKeyframeList(value.toArray(), allocator)
    else
        try readKeyframeObject(value.toObject(), allocator);

    computeOffsets(frames);
    _ = exec;
    return frames;
}

fn readKeyframeList(array: js.Array, allocator: std.mem.Allocator) ![]Keyframe {
    const frames = try allocator.alloc(Keyframe, array.len());
    for (frames, 0..) |*frame, i| {
        const entry = try array.get(@intCast(i));
        frame.* = .{
            .offset = null,
            .easing = "linear",
            .composite = "auto",
            .computed_offset = 0,
            .properties = &.{},
        };
        if (!entry.isObject()) {
            continue;
        }
        const object = entry.toObject();

        var properties: std.ArrayList(Property) = .empty;
        var names = try object.getOwnPropertyNames();
        for (0..names.len()) |n| {
            const name = try (try names.get(@intCast(n))).toStringSliceWithAlloc(allocator);
            const member = try object.get(name);
            if (member.isUndefined()) {
                continue;
            }
            if (!reserved.has(name)) {
                try properties.append(allocator, .{
                    .name = name,
                    .value = try member.toStringSliceWithAlloc(allocator),
                });
                continue;
            }
            if (std.mem.eql(u8, name, "offset")) {
                frame.offset = if (member.isNull()) null else member.toF64() catch null;
            } else if (std.mem.eql(u8, name, "easing")) {
                frame.easing = try member.toStringSliceWithAlloc(allocator);
            } else {
                frame.composite = compositeOperation(
                    try member.toStringSliceWithAlloc(allocator),
                ) orelse "auto";
            }
        }
        frame.properties = properties.items;
    }
    return frames;
}

/// `{opacity: [0, 1], easing: 'ease'}`: every property is a list of per-frame
/// values, and the longest list decides how many keyframes there are. A bare
/// value counts as a one-element list.
fn readKeyframeObject(object: js.Object, allocator: std.mem.Allocator) ![]Keyframe {
    const Column = struct {
        name: []const u8,
        values: []const []const u8,
    };

    var columns: std.ArrayList(Column) = .empty;
    var easing: []const u8 = "linear";
    var composite: []const u8 = "auto";
    var count: usize = 0;

    var names = try object.getOwnPropertyNames();
    for (0..names.len()) |n| {
        const name = try (try names.get(@intCast(n))).toStringSliceWithAlloc(allocator);
        const member = try object.get(name);
        if (member.isUndefined()) {
            continue;
        }
        if (reserved.has(name)) {
            if (std.mem.eql(u8, name, "easing")) {
                easing = try member.toStringSliceWithAlloc(allocator);
            } else if (std.mem.eql(u8, name, "composite")) {
                composite = compositeOperation(
                    try member.toStringSliceWithAlloc(allocator),
                ) orelse "auto";
            }
            continue;
        }

        const values = try readValueList(member, allocator);
        count = @max(count, values.len);
        try columns.append(allocator, .{ .name = name, .values = values });
    }

    const frames = try allocator.alloc(Keyframe, count);
    for (frames, 0..) |*frame, i| {
        var properties: std.ArrayList(Property) = .empty;
        for (columns.items) |column| {
            if (i < column.values.len) {
                try properties.append(allocator, .{ .name = column.name, .value = column.values[i] });
            }
        }
        frame.* = .{
            .offset = null,
            .easing = easing,
            .composite = composite,
            .computed_offset = 0,
            .properties = properties.items,
        };
    }
    return frames;
}

fn readValueList(member: js.Value, allocator: std.mem.Allocator) ![]const []const u8 {
    if (!member.isArray()) {
        const single = try allocator.alloc([]const u8, 1);
        single[0] = try member.toStringSliceWithAlloc(allocator);
        return single;
    }
    const array = member.toArray();
    const values = try allocator.alloc([]const u8, array.len());
    for (values, 0..) |*value, i| {
        value.* = try (try array.get(@intCast(i))).toStringSliceWithAlloc(allocator);
    }
    return values;
}

/// Spread the keyframes evenly over [0, 1], honouring any offset the page
/// supplied. A lone keyframe computes to 1 (measured), not 0.
fn computeOffsets(frames: []Keyframe) void {
    if (frames.len == 0) {
        return;
    }
    if (frames.len == 1) {
        frames[0].computed_offset = frames[0].offset orelse 1;
        return;
    }
    const last: f64 = @floatFromInt(frames.len - 1);
    for (frames, 0..) |*frame, i| {
        const even: f64 = @as(f64, @floatFromInt(i)) / last;
        frame.computed_offset = frame.offset orelse even;
    }
}

/// The options argument is either a plain duration in milliseconds or the
/// KeyframeEffectOptions dictionary.
fn readOptions(
    self: *KeyframeEffect,
    options_: ?js.Value,
    allocator: std.mem.Allocator,
    exec: *const Execution,
) !void {
    const value = options_ orelse return;
    if (value.isNullOrUndefined()) {
        return;
    }

    const effect = self._proto;
    if (!value.isObject()) {
        effect._duration = value.toF64() catch return;
        return;
    }

    const init = try Reader.read(value, exec);
    effect._delay = try init.double("delay", 0, exec);
    effect._end_delay = try init.double("endDelay", 0, exec);
    effect._fill = try init.string("fill", "auto", allocator);
    effect._iteration_start = try init.double("iterationStart", 0, exec);
    effect._iterations = try init.double("iterations", 1, exec);
    effect._direction = try init.string("direction", "normal", allocator);
    effect._easing = try init.string("easing", "linear", allocator);

    if (try init.present("duration")) |duration| {
        if (duration.isNumber()) {
            effect._duration = try duration.toF64();
        }
    }

    if (try init.present("composite")) |composite| {
        const name = try composite.toStringSliceWithAlloc(allocator);
        self._composite = compositeOperation(name) orelse self._composite;
    }
    if (try init.present("pseudoElement")) |pseudo| {
        if (!pseudo.isNull()) {
            self._pseudo_element = try pseudo.toStringSliceWithAlloc(allocator);
        }
    }
}

fn compositeOperation(name: []const u8) ?[]const u8 {
    inline for (.{ "replace", "add", "accumulate", "auto" }) |known| {
        if (std.mem.eql(u8, name, known)) {
            return known;
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(KeyframeEffect);

    pub const Meta = struct {
        pub const name = "KeyframeEffect";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(KeyframeEffect.constructor, .{ .arity = 1 });

    pub const target = bridge.accessor(KeyframeEffect.getTarget, KeyframeEffect.setTarget, .{});
    pub const pseudoElement = bridge.accessor(
        KeyframeEffect.getPseudoElement,
        KeyframeEffect.setPseudoElement,
        .{},
    );
    pub const composite = bridge.accessor(KeyframeEffect.getComposite, KeyframeEffect.setComposite, .{});
    pub const getKeyframes = bridge.function(KeyframeEffect.getKeyframes, .{});
    pub const setKeyframes = bridge.function(KeyframeEffect.setKeyframes, .{ .arity = 1 });
};

const testing = @import("../../../testing.zig");
test "WebApi: KeyframeEffect" {
    try testing.htmlRunner("animation/keyframe_effect.html", .{});
}
