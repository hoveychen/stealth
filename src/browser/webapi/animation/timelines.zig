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

// The scroll-driven-animation family a Chrome window carries and this engine did
// not: AnimationTrigger as a prototype root with TimelineTrigger under it, the
// TimelineTriggerRange a trigger hands out and the list it comes in, and
// ScrollTimeline / ViewTimeline on the AnimationTimeline chain (which is why
// that base grew a polymorphic duration -- see document/services.zig).
//
// Three of the six have Illegal constructors, and that is not the same as being
// unreachable. `new TimelineTrigger([5])` is refused as "not of type
// 'TimelineTriggerOptions'" while `([null])` and `([document.timeline])` both
// succeed, so the argument is a sequence of *dictionaries*: a page builds a
// TimelineTriggerRange by handing one over and reads it back off `ranges`. Only
// TimelineTriggerRangeList is never built from script.
//
// Two things here are layout and cannot be reproduced:
//
//   * `currentTime` is a percentage once the source can really scroll. Nothing
//     scrolls here -- and Chrome answers null for a source that does not scroll
//     either, so a ScrollTimeline agrees with Chrome for the same reason. A
//     ViewTimeline with a subject is the gap: Chrome reports its progress
//     whatever the source does, and this reports 0%.
//   * `startOffset` / `endOffset` are the scroll offsets at which the subject
//     enters and leaves the scrollport (-818px / 100px for a 100px box in an
//     818px viewport, measured). With no boxes to measure they are 0px, the same
//     zero this engine reports for offsetTop and clientHeight.
//
// Every member list, arity, default, coercion and refusal below is Chrome's own,
// measured on a headed Chrome 151 on http://localhost:8777 with
// tools/fingerprint/probes/probe-shapes.js and probe-s5-timelines.js (readings
// in results/probes/probe-shapes.chrome.json and
// probe-s5-timelines.chrome.json). Which members each dictionary declares was
// read off a Proxy rather than taken from a spec draft: Chrome's binding touches
// exactly the declared members, in its own order.
//
// All six are window-only -- a Chrome DedicatedWorkerGlobalScope has none of
// them -- and none is [SecureContext] (both measured).

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const Animation = @import("Animation.zig");
const dictionary = @import("../dictionary.zig");
const typed_om = @import("../css/typed_om.zig");
const services = @import("../document/services.zig");

const Execution = js.Execution;
const CSSNumericValue = typed_om.CSSNumericValue;
const CSSUnitValue = typed_om.CSSUnitValue;

pub fn registerTypes() []const type {
    return &.{
        AnimationTrigger,
        TimelineTrigger,
        TimelineTriggerRange,
        TimelineTriggerRangeList,
        TimelineTriggerRangeList.KeyIterator,
        TimelineTriggerRangeList.ValueIterator,
        TimelineTriggerRangeList.EntryIterator,
        ScrollTimeline,
        ViewTimeline,
    };
}

/// WebIDL `ScrollAxis`, shared by both timelines. Chrome takes these four names
/// and nothing else -- not the `horizontal` / `vertical` a page might guess --
/// and an absent member takes 'block' while an explicit null is stringified to
/// "null" and refused like any other unknown name.
const scroll_axes = [_][]const u8{ "block", "inline", "x", "y" };

/// A function may take Execution or Frame but not both, and everything here
/// needs the thrower helpers that want an Execution -- so the Frame comes out of
/// it. All six interfaces are window-only, so the worker arm is unreachable.
fn frameOf(exec: *const Execution) !*Frame {
    return switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => error.NotSupportedError,
    };
}

/// The zero this engine has instead of layout. Chrome's numbers here come from
/// box geometry; every box is zero-sized, so every offset is 0px.
fn zeroPx(frame: *Frame) !*CSSUnitValue {
    return CSSUnitValue.create(0, .px, frame);
}

// ---------------------------------------------------------------------------
// ScrollTimeline

/// `new ScrollTimeline({source, axis})`: progress through a scroll container's
/// scroll range. The source defaults to the document element, and a page gets
/// back the very element it handed in.
pub const ScrollTimeline = struct {
    pub const Proto = services.AnimationTimeline;

    _proto: *services.AnimationTimeline,
    _source: ?*Element,
    _axis: []const u8,

    const Reader = dictionary.Reader("ScrollTimeline", "ScrollTimelineOptions");

    /// `source` is nullable, so `{source: null}` really is a null source --
    /// unlike `new ScrollTimeline(null)`, where the whole dictionary is absent
    /// and the default applies (measured: the two differ).
    fn readSource(init: Reader, exec: *const Execution) !?*Element {
        const frame = try frameOf(exec);
        if (try init.present("source")) |member| {
            if (member.isNull()) {
                return null;
            }
            return member.toZig(*Element) catch
                Reader.convertFailed("source", "Element", exec);
        }
        return frame.window.getDocument().getDocumentElement();
    }

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*ScrollTimeline {
        const init = try Reader.read(options_, exec);
        const axis = try init.enumMember("axis", "ScrollAxis", &scroll_axes, "block", exec);
        const source = try readSource(init, exec);
        return create(source, axis.?, try frameOf(exec));
    }

    fn create(source: ?*Element, axis: []const u8, frame: *Frame) !*ScrollTimeline {
        return frame._factory.chained(.{
            services.AnimationTimeline{ ._kind = .scroll },
            ScrollTimeline{ ._proto = undefined, ._source = source, ._axis = axis },
        });
    }

    pub fn getSource(self: *const ScrollTimeline) ?*Element {
        return self._source;
    }

    pub fn getAxis(self: *const ScrollTimeline) []const u8 {
        return self._axis;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ScrollTimeline);

        pub const Meta = struct {
            pub const name = "ScrollTimeline";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // One optional argument, so Chrome reports ScrollTimeline.length === 0.
        pub const constructor = bridge.constructor(ScrollTimeline.constructor, .{ .arity = 0 });
        pub const source = bridge.accessor(ScrollTimeline.getSource, null, .{});
        pub const axis = bridge.accessor(ScrollTimeline.getAxis, null, .{});
    };
};

// ---------------------------------------------------------------------------
// ViewTimeline

/// `new ViewTimeline({subject, axis, inset})`: progress of one element through
/// the scrollport. Its dictionary has no `source` member at all -- the source is
/// derived from the subject, so one passed in is ignored (measured with a Proxy:
/// Chrome reads axis, inset and subject and nothing else).
///
/// `subject` is where it differs from ScrollTimeline's `source`: it is optional
/// but *not* nullable, so an explicit null is a failed conversion rather than a
/// null subject.
pub const ViewTimeline = struct {
    pub const Proto = ScrollTimeline;

    _proto: *ScrollTimeline,
    _subject: ?*Element,

    const Reader = dictionary.Reader("ViewTimeline", "ViewTimelineOptions");

    /// The one refusal in the family that carries no dictionary prefix: just
    /// "Failed to construct 'ViewTimeline': Invalid inset".
    const INVALID_INSET = "Failed to construct 'ViewTimeline': Invalid inset";
    const NOT_NUMERIC = "Failed to construct 'ViewTimeline': inset must be CSSNumericValue or auto";

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*ViewTimeline {
        const frame = try frameOf(exec);
        const init = try Reader.read(options_, exec);
        const axis = try init.enumMember("axis", "ScrollAxis", &scroll_axes, "block", exec);
        try readInset(init, exec);

        const subject = blk: {
            const member = (try init.present("subject")) orelse break :blk null;
            break :blk member.toZig(*Element) catch
                return Reader.convertFailed("subject", "Element", exec);
        };

        // With no subject there is nothing to derive a source from, and Chrome
        // reports null for both. With one, the source is the scroll container,
        // which here is always the document element.
        const source = if (subject == null) null else frame.window.getDocument().getDocumentElement();
        return frame._factory.chained(.{
            services.AnimationTimeline{ ._kind = if (subject == null) .scroll else .view },
            ScrollTimeline{ ._proto = undefined, ._source = source, ._axis = axis.? },
            ViewTimeline{ ._proto = undefined, ._subject = subject },
        });
    }

    /// `inset` is a union of a string and a sequence, which `inset: []` proves:
    /// an empty array is accepted where the empty *string* is not. Both branches
    /// take one or two components, each either `auto` or a <length-percentage>,
    /// and the two branches refuse a bad component differently. Nothing is
    /// stored: the value only shifts the offsets, and those are layout.
    fn readInset(init: Reader, exec: *const Execution) !void {
        const member = (try init.present("inset")) orelse return;
        if (member.isArray()) {
            const array = member.toArray();
            if (array.len() > 2) {
                return dictionary.throwTypeError(INVALID_INSET, exec);
            }
            for (0..array.len()) |i| {
                const item = try array.get(@intCast(i));
                if (item.toZig(*CSSNumericValue)) |_| {
                    continue;
                } else |_| {}
                // A string is allowed, but only the keyword: a sequence item
                // does not get the string branch's parser, so '10px' in a
                // sequence is refused where '10px' as the whole inset is fine.
                if (item.isString() == null) {
                    return dictionary.throwTypeError(NOT_NUMERIC, exec);
                }
                const text = try item.toStringSlice();
                if (!std.mem.eql(u8, text, "auto")) {
                    return dictionary.throwTypeError(NOT_NUMERIC, exec);
                }
            }
            return;
        }
        // Everything else is taken as a string, so a number and a null are
        // stringified and then refused by the parser below.
        const text = member.toStringSlice() catch
            return dictionary.throwTypeError(INVALID_INSET, exec);
        var components = std.mem.tokenizeAny(u8, text, " \t\r\n");
        var count: usize = 0;
        while (components.next()) |component| {
            count += 1;
            if (count > 2 or !isInsetComponent(component)) {
                return dictionary.throwTypeError(INVALID_INSET, exec);
            }
        }
        if (count == 0) {
            return dictionary.throwTypeError(INVALID_INSET, exec);
        }
    }

    fn isInsetComponent(text: []const u8) bool {
        return std.mem.eql(u8, text, "auto") or isLengthPercentage(text);
    }

    pub fn getSubject(self: *const ViewTimeline) ?*Element {
        return self._subject;
    }

    /// Null until there is a subject, and 0px after that. Chrome's numbers are
    /// the scrollport-relative offsets of the subject's box.
    pub fn getOffset(self: *const ViewTimeline, frame: *Frame) !?*CSSUnitValue {
        if (self._subject == null) {
            return null;
        }
        return try zeroPx(frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ViewTimeline);

        pub const Meta = struct {
            pub const name = "ViewTimeline";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(ViewTimeline.constructor, .{ .arity = 0 });
        pub const subject = bridge.accessor(ViewTimeline.getSubject, null, .{});
        pub const startOffset = bridge.accessor(ViewTimeline.getOffset, null, .{});
        pub const endOffset = bridge.accessor(ViewTimeline.getOffset, null, .{});
    };
};

/// A CSS `<length-percentage>`: a dimension whose unit is a length or a percent,
/// or a calc() that this engine does not evaluate. Measured: `10px`, `-10px`,
/// `10em`, `50%` and `calc(10px + 5%)` are all accepted while the unitless `50`
/// and `var(--x)` are not.
fn isLengthPercentage(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "calc(") and std.mem.endsWith(u8, text, ")")) {
        return true;
    }
    const dimension = CSSNumericValue.parseDimension(text) orelse return false;
    const base = dimension.unit.baseType() orelse return false;
    return base == .length or base == .percent;
}

// ---------------------------------------------------------------------------
// AnimationTrigger

/// The prototype root of the trigger hierarchy: the list of animations a trigger
/// drives, plus the three methods that manage it. Abstract in WebIDL, so it has
/// no constructor of its own, but it does carry the state -- a TimelineTrigger
/// chains onto it and its methods report themselves as AnimationTrigger's.
pub const AnimationTrigger = struct {
    _animations: std.ArrayList(Entry) = .empty,
    _arena: std.mem.Allocator,

    /// The Animation, plus a persistent handle to its wrapper. The handle is
    /// what keeps the Zig instance alive for as long as the trigger holds it,
    /// and returning the pointer hands the page back the very object it added
    /// (measured: getAnimations()[0] === the animation).
    const Entry = struct {
        animation: *Animation,
        handle: js.Object.Global,
    };

    /// WebIDL `AnimationTriggerBehavior`. Three names, and not the once /
    /// repeat / alternate / state a reader of the spec drafts would guess
    /// (measured: all four of those are refused).
    const behaviours = [_][]const u8{ "play", "pause", "none" };

    const PREFIX = "Failed to execute '";

    /// This engine counts a constructor's arguments but not a method's, so the
    /// count Chrome reports is produced here. Both messages are Chrome's,
    /// singular and plural.
    fn tooFewArguments(
        comptime method: []const u8,
        comptime required: usize,
        present: usize,
        exec: *const Execution,
    ) anyerror {
        const plural = if (required == 1) "argument" else "arguments";
        return dictionary.throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            PREFIX ++ method ++ "' on 'AnimationTrigger': " ++
                std.fmt.comptimePrint("{d}", .{required}) ++ " " ++ plural ++
                " required, but only {d} present.",
            .{present},
        ), exec);
    }

    /// A method parameter typed as an interface, which Chrome refuses by
    /// position rather than by name -- "parameter 1 is not of type 'Animation'."
    /// -- unlike a dictionary member's "Failed to convert value to 'X'.".
    fn animationArgument(
        comptime method: []const u8,
        value: js.Value,
        exec: *const Execution,
    ) !*Animation {
        return value.toZig(*Animation) catch dictionary.throwTypeError(
            PREFIX ++ method ++ "' on 'AnimationTrigger': parameter 1 is not of type 'Animation'.",
            exec,
        );
    }

    fn find(self: *const AnimationTrigger, animation: *Animation) ?usize {
        for (self._animations.items, 0..) |entry, i| {
            if (entry.animation == animation) {
                return i;
            }
        }
        return null;
    }

    /// Both arguments are required, and the order of the three checks is
    /// Chrome's: the count first, then the animation's type, then the
    /// behaviour's enum. Adding the same animation twice leaves one entry.
    pub fn addAnimation(
        self: *AnimationTrigger,
        animation_: ?js.Value,
        behaviour_: ?js.Value,
        exec: *const Execution,
    ) !void {
        const animation_value = animation_ orelse return tooFewArguments("addAnimation", 2, 0, exec);
        const behaviour = behaviour_ orelse return tooFewArguments("addAnimation", 2, 1, exec);
        const animation = try animationArgument("addAnimation", animation_value, exec);
        _ = try matchBehaviour(behaviour, exec);

        if (self.find(animation) != null) {
            return;
        }
        const local = exec.js.local.?;
        try self._animations.append(self._arena, .{
            .animation = animation,
            .handle = try (try local.zigValueToJs(animation, .{})).toObject().persist(),
        });
    }

    /// A bare parameter enum, so the message names neither a dictionary nor a
    /// member -- and an explicit undefined is stringified and refused rather
    /// than taken as absent (measured).
    fn matchBehaviour(value: js.Value, exec: *const Execution) ![]const u8 {
        const text = if (value.isUndefined()) "undefined" else try value.toStringSlice();
        for (behaviours) |candidate| {
            if (std.mem.eql(u8, candidate, text)) {
                return candidate;
            }
        }
        return dictionary.throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            PREFIX ++ "addAnimation' on 'AnimationTrigger': The provided value '{s}' is not a " ++
                "valid enum value of type AnimationTriggerBehavior.",
            .{text},
        ), exec);
    }

    /// Removing one that was never added is a silent no-op (measured).
    pub fn removeAnimation(
        self: *AnimationTrigger,
        animation_: ?js.Value,
        exec: *const Execution,
    ) !void {
        const value = animation_ orelse return tooFewArguments("removeAnimation", 1, 0, exec);
        const animation = try animationArgument("removeAnimation", value, exec);
        const index = self.find(animation) orelse return;
        _ = self._animations.orderedRemove(index);
    }

    /// A fresh array on every call, holding the wrappers the page handed in
    /// (measured: two calls are not the same array, and the entries are
    /// identical to the animations added).
    pub fn getAnimations(self: *const AnimationTrigger, exec: *const Execution) !js.Array {
        const local = exec.js.local.?;
        const array = local.newArray(@intCast(self._animations.items.len));
        for (self._animations.items, 0..) |entry, i| {
            _ = try array.set(@intCast(i), entry.handle.local(local), .{});
        }
        return array;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AnimationTrigger);

        pub const Meta = struct {
            pub const name = "AnimationTrigger";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const T = AnimationTrigger;

        pub const addAnimation = bridge.function(T.addAnimation, .{ .arity = 2 });
        pub const getAnimations = bridge.function(T.getAnimations, .{});
        pub const removeAnimation = bridge.function(T.removeAnimation, .{ .arity = 1 });
    };
};

// ---------------------------------------------------------------------------
// TimelineTrigger

/// `new TimelineTrigger([{...}])`: the one concrete AnimationTrigger. The
/// argument is a sequence of dictionaries rather than of ranges, so this is
/// where a page gets a TimelineTriggerRange from -- and at most one, because
/// Chrome refuses a second with "Configuring multiple timelines is not
/// supported.".
pub const TimelineTrigger = struct {
    pub const Proto = AnimationTrigger;

    _proto: *AnimationTrigger,
    _ranges: *TimelineTriggerRangeList,

    const CTOR = "Failed to construct 'TimelineTrigger': ";
    const Reader = dictionary.Reader("TimelineTrigger", "TimelineTriggerOptions");

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*TimelineTrigger {
        const frame = try frameOf(exec);
        const ranges = try readRanges(options_, exec, frame);
        const list = try frame._factory.create(TimelineTriggerRangeList{ ._items = ranges });
        return frame._factory.chained(.{
            AnimationTrigger{ ._arena = frame.arena },
            TimelineTrigger{ ._proto = undefined, ._ranges = list },
        });
    }

    /// Which refusal a wrong argument gets turns on whether it is an object at
    /// all: a primitive cannot be a sequence, and an object without an iterator
    /// is told what it is missing. A string is a primitive, so it takes the
    /// first even though strings are iterable in JS (measured).
    fn readRanges(
        options_: ?js.Value,
        exec: *const Execution,
        frame: *Frame,
    ) ![]const *TimelineTriggerRange {
        const value = options_ orelse return &.{};
        if (value.isUndefined()) {
            return &.{};
        }
        if (!value.isObject()) {
            return dictionary.throwTypeError(
                CTOR ++ "The provided value cannot be converted to a sequence.",
                exec,
            );
        }
        // Any iterable is a sequence -- an array, a Set, a generator object --
        // but only an array can be read item by item here, so a non-array
        // iterable is taken as the empty sequence it almost always is (a page
        // has no TimelineTriggerRange to put in one anyway, and the dictionaries
        // it could put there are what the array branch below is for). An object
        // with no iterator at all is refused.
        if (!value.isArray()) {
            if (value.toObject().hasIterator()) {
                return &.{};
            }
            return dictionary.throwTypeError(
                CTOR ++ "The object must have a callable @@iterator property.",
                exec,
            );
        }

        const array = value.toArray();
        // Every item is converted before the one-timeline limit is applied, so
        // two bad items still answer the dictionary refusal (measured).
        const items = try frame.arena.alloc(*TimelineTriggerRange, @intCast(array.len()));
        for (items, 0..) |*item, i| {
            item.* = try TimelineTriggerRange.fromOptions(try array.get(@intCast(i)), exec, frame);
        }
        if (items.len > 1) {
            return dictionary.throwTypeError(
                CTOR ++ "Configuring multiple timelines is not supported.",
                exec,
            );
        }
        return items;
    }

    /// The same list object on every read (measured).
    pub fn getRanges(self: *const TimelineTrigger) *TimelineTriggerRangeList {
        return self._ranges;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TimelineTrigger);

        pub const Meta = struct {
            pub const name = "TimelineTrigger";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(TimelineTrigger.constructor, .{ .arity = 0 });
        pub const ranges = bridge.accessor(TimelineTrigger.getRanges, null, .{});
    };
};

// ---------------------------------------------------------------------------
// TimelineTriggerRange

/// One entry of a trigger's `ranges`: the timeline it watches plus the two pairs
/// of boundaries. Illegal to construct directly, but a page reaches one through
/// TimelineTrigger's sequence of dictionaries.
pub const TimelineTriggerRange = struct {
    /// A persistent handle rather than a typed pointer, because the member
    /// accepts any AnimationTimeline and a page must get back the very object it
    /// passed -- a DocumentTimeline or a ScrollTimeline, brand and all.
    _timeline: js.Object.Global,
    _activation_start: Boundary,
    _activation_end: Boundary,
    _active_start: Boundary,
    _active_end: Boundary,

    const Reader = dictionary.Reader("TimelineTrigger", "TimelineTriggerOptions");

    const INVALID_RANGE = "Failed to construct 'TimelineTrigger': TimelineTrigger range must be " ++
        "a name <length-percent> pair";

    /// The four boundary members are not DOMStrings but a union of one with a
    /// TimelineRangeOffset dictionary: an object handed in reads back as an
    /// object carrying only the members it was given, and a string reads back
    /// verbatim -- case and inner spacing and all, since nothing is normalised.
    const Boundary = union(enum) {
        text: []const u8,
        offset: Offset,

        /// Chrome reads `offset` before `rangeName` (measured with a Proxy), and
        /// a dictionary is echoed back in that same declaration order.
        const Offset = struct {
            offset: ?*CSSNumericValue = null,
            range_name: ?[]const u8 = null,
        };
    };

    /// The default boundaries, which differ between the two pairs: activation
    /// defaults to 'normal' and active to 'auto' -- and 'auto' is not even a
    /// legal *value* for the activation pair, while 'normal' is legal for both
    /// (measured).
    const Defaults = struct {
        const activation: Boundary = .{ .text = "normal" };
        const active: Boundary = .{ .text = "auto" };
    };

    fn fromOptions(value: js.Value, exec: *const Execution, frame: *Frame) !*TimelineTriggerRange {
        // A non-object item is refused as a dictionary; null is a legal empty
        // one, which is why `new TimelineTrigger([null])` succeeds.
        if (!value.isNullOrUndefined() and !value.isObject()) {
            return dictionary.throwTypeError(
                TimelineTrigger.CTOR ++ "The provided value is not of type 'TimelineTriggerOptions'.",
                exec,
            );
        }
        const init = try Reader.read(value, exec);
        return frame._factory.create(TimelineTriggerRange{
            ._timeline = try readTimeline(init, exec, frame),
            ._activation_start = try readBoundary(init, "activationRangeStart", false, exec, frame),
            ._activation_end = try readBoundary(init, "activationRangeEnd", false, exec, frame),
            ._active_start = try readBoundary(init, "activeRangeStart", true, exec, frame),
            ._active_end = try readBoundary(init, "activeRangeEnd", true, exec, frame),
        });
    }

    /// Absent and explicit null both take the document's own timeline, so
    /// `range.timeline === document.timeline` (measured for both).
    fn readTimeline(init: Reader, exec: *const Execution, frame: *Frame) !js.Object.Global {
        const local = exec.js.local.?;
        if (try init.present("timeline")) |member| {
            if (!member.isNull()) {
                _ = member.toZig(*services.AnimationTimeline) catch
                    return Reader.convertFailed("timeline", "AnimationTimeline", exec);
                return member.toObject().persist();
            }
        }
        const timeline = try frame.window.getDocument().getTimeline(frame);
        return (try local.zigValueToJs(timeline, .{})).toObject().persist();
    }

    fn readBoundary(
        init: Reader,
        comptime name: []const u8,
        comptime allow_auto: bool,
        exec: *const Execution,
        frame: *Frame,
    ) !Boundary {
        const member = (try init.present(name)) orelse
            return if (allow_auto) Defaults.active else Defaults.activation;
        if (member.isObject() or member.isNull()) {
            const Nested = dictionary.Nested(Reader, name, "TimelineRangeOffset");
            const object = if (member.isNull()) null else member.toObject();
            var offset: Boundary.Offset = .{};
            if (object) |o| {
                const offset_member = try o.get("offset");
                if (!offset_member.isNullOrUndefined()) {
                    offset.offset = offset_member.toZig(*CSSNumericValue) catch
                        return Nested.convertFailed("offset", "CSSNumericValue", exec);
                }
                const name_member = try o.get("rangeName");
                if (!name_member.isNullOrUndefined()) {
                    offset.range_name = try name_member.toStringSliceWithAlloc(frame.arena);
                }
            }
            return .{ .offset = offset };
        }
        // Everything else is a string, so a number is stringified and then
        // refused by the grammar below.
        const text = try member.toStringSliceWithAlloc(frame.arena);
        if (!isRangeText(text, allow_auto)) {
            return dictionary.throwTypeError(INVALID_RANGE, exec);
        }
        return .{ .text = text };
    }

    /// `normal`, `auto` for the active pair only, a timeline range name, a
    /// <length-percentage>, or a name followed by one. Nothing else: not two
    /// names, not a name after an offset, not a keyword paired with an offset,
    /// and not a value with outer whitespace -- ' cover 50% ' is refused where
    /// 'cover  50%' is fine, so the string is not trimmed (all measured).
    fn isRangeText(text: []const u8, comptime allow_auto: bool) bool {
        const WHITESPACE = " \t\r\n";
        if (text.len == 0 or std.mem.indexOfScalar(u8, WHITESPACE, text[0]) != null or
            std.mem.indexOfScalar(u8, WHITESPACE, text[text.len - 1]) != null)
        {
            return false;
        }
        if (std.ascii.eqlIgnoreCase(text, "normal")) {
            return true;
        }
        if (allow_auto and std.ascii.eqlIgnoreCase(text, "auto")) {
            return true;
        }
        // Tested whole before it is split, because a calc() carries spaces of
        // its own: 'calc(10px + 5%)' is one component, not three.
        if (isRangeName(text) or isLengthPercentage(text)) {
            return true;
        }
        const space = std.mem.indexOfAny(u8, text, WHITESPACE) orelse return false;
        const offset = std.mem.trimStart(u8, text[space..], WHITESPACE);
        return isRangeName(text[0..space]) and isLengthPercentage(offset);
    }

    /// A `<timeline-range-name>`, matched case-insensitively: 'COVER' is
    /// accepted and echoed back in the case it came in.
    fn isRangeName(text: []const u8) bool {
        const names = [_][]const u8{ "cover", "contain", "entry", "exit", "entry-crossing", "exit-crossing" };
        for (names) |name| {
            if (std.ascii.eqlIgnoreCase(name, text)) {
                return true;
            }
        }
        return false;
    }

    pub fn getTimeline(self: *const TimelineTriggerRange) js.Object.Global {
        return self._timeline;
    }

    fn boundary(value: Boundary, exec: *const Execution) !js.Value {
        const local = exec.js.local.?;
        switch (value) {
            .text => |text| return local.zigValueToJs(text, .{}),
            .offset => |offset| {
                const object = local.newObject();
                if (offset.offset) |numeric| {
                    _ = try object.set("offset", numeric, .{});
                }
                if (offset.range_name) |name| {
                    _ = try object.set("rangeName", name, .{});
                }
                return object.toValue();
            },
        }
    }

    pub fn getActivationRangeStart(self: *const TimelineTriggerRange, exec: *const Execution) !js.Value {
        return boundary(self._activation_start, exec);
    }

    pub fn getActivationRangeEnd(self: *const TimelineTriggerRange, exec: *const Execution) !js.Value {
        return boundary(self._activation_end, exec);
    }

    pub fn getActiveRangeStart(self: *const TimelineTriggerRange, exec: *const Execution) !js.Value {
        return boundary(self._active_start, exec);
    }

    pub fn getActiveRangeEnd(self: *const TimelineTriggerRange, exec: *const Execution) !js.Value {
        return boundary(self._active_end, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TimelineTriggerRange);

        pub const Meta = struct {
            pub const name = "TimelineTriggerRange";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const R = TimelineTriggerRange;

        pub const timeline = bridge.accessor(R.getTimeline, null, .{});
        pub const activationRangeStart = bridge.accessor(R.getActivationRangeStart, null, .{});
        pub const activationRangeEnd = bridge.accessor(R.getActivationRangeEnd, null, .{});
        pub const activeRangeStart = bridge.accessor(R.getActiveRangeStart, null, .{});
        pub const activeRangeEnd = bridge.accessor(R.getActiveRangeEnd, null, .{});
    };
};

// ---------------------------------------------------------------------------
// TimelineTriggerRangeList

/// `trigger.ranges`: the only interface of the family a page never builds, since
/// nothing but a TimelineTrigger's constructor makes one. Indexed and iterable,
/// with `item()` beside the indexed getter -- and the two disagree past the end,
/// where `item(1)` is null and `[1]` is undefined (measured).
pub const TimelineTriggerRangeList = struct {
    _items: []const *TimelineTriggerRange,

    pub fn getLength(self: *const TimelineTriggerRangeList) u32 {
        return @intCast(self._items.len);
    }

    /// One required argument, which this engine has to count itself.
    pub fn item(
        self: *const TimelineTriggerRangeList,
        index_: ?js.Value,
        exec: *const Execution,
    ) !?*TimelineTriggerRange {
        const value = index_ orelse return dictionary.throwTypeError(
            "Failed to execute 'item' on 'TimelineTriggerRangeList': 1 argument required, " ++
                "but only 0 present.",
            exec,
        );
        const index = value.toI32() catch 0;
        if (index < 0 or index >= self._items.len) {
            return null;
        }
        return self._items[@intCast(index)];
    }

    fn at(self: *const TimelineTriggerRangeList, index: usize) ?*TimelineTriggerRange {
        if (index >= self._items.len) {
            return null;
        }
        return self._items[index];
    }

    fn indexes(self: *TimelineTriggerRangeList, exec: *const Execution) !js.Array {
        const array = exec.js.local.?.newArray(@intCast(self._items.len));
        for (0..self._items.len) |i| {
            _ = try array.set(@intCast(i), i, .{});
        }
        return array;
    }

    pub fn keys(self: *TimelineTriggerRangeList, exec: *const Execution) !*KeyIterator {
        return .init(.{ .list = self }, exec);
    }

    pub fn values(self: *TimelineTriggerRangeList, exec: *const Execution) !*ValueIterator {
        return .init(.{ .list = self }, exec);
    }

    pub fn entries(self: *TimelineTriggerRangeList, exec: *const Execution) !*EntryIterator {
        return .init(.{ .list = self }, exec);
    }

    pub fn forEach(self: *TimelineTriggerRangeList, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._items, 0..) |range, index| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ range, index, self }, &caught) catch {};
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        list: *TimelineTriggerRangeList,

        pub const Entry = struct { u32, *TimelineTriggerRange };

        pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
            const index = self.index;
            const range = self.list.at(index) orelse return null;
            self.index = index + 1;
            return .{ index, range };
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TimelineTriggerRangeList);

        pub const Meta = struct {
            pub const name = "TimelineTriggerRangeList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const L = TimelineTriggerRangeList;

        pub const entries = bridge.function(L.entries, .{});
        pub const keys = bridge.function(L.keys, .{});
        pub const values = bridge.function(L.values, .{});
        pub const forEach = bridge.function(L.forEach, .{});
        pub const length = bridge.accessor(L.getLength, null, .{});
        pub const item = bridge.function(L.item, .{ .arity = 1 });
        pub const @"[]" = bridge.indexed(L.at, L.indexes, .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(L.values, .{ .js_name = "values" });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: Timelines" {
    try testing.htmlRunner("animation/timelines.html", .{});
}
