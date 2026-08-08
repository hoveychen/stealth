// AnimationEffect, plus the two Animation subclasses CSS drives. Chrome exposes
// all three as globals and CreepJS counts window own keys, so they have to be
// here even though this engine never runs a CSS animation or transition and so
// never instantiates the two subclasses -- `getAnimations()` stays empty.
//
// Shapes, member order, arities and the "Illegal constructor" behaviour were
// measured on a headed Chrome 150 (probes probe-css1.js / probe-css11.js).

const std = @import("std");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Animation = @import("Animation.zig");
const KeyframeEffect = @import("KeyframeEffect.zig");

pub fn registerTypes() []const type {
    return &.{
        AnimationEffect,
        KeyframeEffect,
        CSSAnimation,
        CSSTransition,
    };
}

/// The base of the effect hierarchy, and where the timing lives. Chrome hands
/// one out from `animation.effect`, which is a KeyframeEffect whenever
/// `element.animate()` made the animation; the three accessors below read the
/// timing that effect was built with.
///
/// `getTiming` and `getComputedTiming` emit their members alphabetically, which
/// is Chrome's own order, and the computed set resolves `fill: auto` to `none`
/// and adds the five read-only members. Measured on a headed Chrome 150
/// (probe-win29: duration 500 with iterations 2 gives activeDuration 1000 and
/// endTime 1000).
pub const AnimationEffect = struct {
    _delay: f64 = 0,
    _end_delay: f64 = 0,
    _fill: []const u8 = "auto",
    _iteration_start: f64 = 0,
    _iterations: f64 = 1,
    _direction: []const u8 = "normal",
    _easing: []const u8 = "linear",
    /// `double or "auto"`, and "auto" is the default.
    _duration: ?f64 = null,

    pub fn getTiming(self: *const AnimationEffect, exec: *const js.Execution) !js.Object {
        const object = exec.js.local.?.newObject();
        _ = try object.set("delay", self._delay, .{});
        _ = try object.set("direction", self._direction, .{});
        if (self._duration) |duration| {
            _ = try object.set("duration", duration, .{});
        } else {
            _ = try object.set("duration", "auto", .{});
        }
        _ = try object.set("easing", self._easing, .{});
        _ = try object.set("endDelay", self._end_delay, .{});
        _ = try object.set("fill", self._fill, .{});
        _ = try object.set("iterationStart", self._iteration_start, .{});
        _ = try object.set("iterations", self._iterations, .{});
        return object;
    }

    pub fn getComputedTiming(self: *const AnimationEffect, exec: *const js.Execution) !js.Object {
        const object = exec.js.local.?.newObject();
        _ = try object.set("delay", self._delay, .{});
        _ = try object.set("direction", self._direction, .{});
        _ = try object.set("duration", self._duration orelse 0, .{});
        _ = try object.set("easing", self._easing, .{});
        _ = try object.set("endDelay", self._end_delay, .{});
        // The resolved fill: `auto` means `none` for a keyframe effect.
        const fill = if (std.mem.eql(u8, self._fill, "auto")) "none" else self._fill;
        _ = try object.set("fill", fill, .{});
        _ = try object.set("iterationStart", self._iteration_start, .{});
        _ = try object.set("iterations", self._iterations, .{});

        const active_duration = (self._duration orelse 0) * self._iterations;
        _ = try object.set("activeDuration", active_duration, .{});
        _ = try object.set("currentIteration", null, .{});
        _ = try object.set("endTime", self._delay + active_duration + self._end_delay, .{});
        _ = try object.set("localTime", null, .{});
        _ = try object.set("progress", null, .{});
        return object;
    }

    /// Nothing here drives a timeline, so there is no phase to recompute; the
    /// method still has to exist and take the dictionary.
    pub fn updateTiming(_: *AnimationEffect, _: ?js.Object) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AnimationEffect);

        pub const Meta = struct {
            pub const name = "AnimationEffect";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getComputedTiming = bridge.function(AnimationEffect.getComputedTiming, .{});
        pub const getTiming = bridge.function(AnimationEffect.getTiming, .{});
        // Measured: arity 0 even though the dictionary argument is accepted.
        pub const updateTiming = bridge.function(AnimationEffect.updateTiming, .{ .arity = 0 });
    };
};

/// The animation a `@keyframes` rule drives. This engine does not run CSS
/// animations, so no instance is ever created; the global and its prototype are
/// what a detector reads.
pub const CSSAnimation = struct {
    pub const Proto = Animation;

    _proto: *Animation,
    _animation_name: []const u8 = "",

    pub fn getAnimationName(self: *const CSSAnimation) []const u8 {
        return self._animation_name;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSAnimation);

        pub const Meta = struct {
            pub const name = "CSSAnimation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const animationName = bridge.accessor(CSSAnimation.getAnimationName, null, .{});
    };
};

/// The animation a `transition` drives. Same story as CSSAnimation.
pub const CSSTransition = struct {
    pub const Proto = Animation;

    _proto: *Animation,
    _transition_property: []const u8 = "",

    pub fn getTransitionProperty(self: *const CSSTransition) []const u8 {
        return self._transition_property;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSTransition);

        pub const Meta = struct {
            pub const name = "CSSTransition";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const transitionProperty = bridge.accessor(CSSTransition.getTransitionProperty, null, .{});
    };
};
