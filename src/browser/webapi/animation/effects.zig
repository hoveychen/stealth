// AnimationEffect, plus the two Animation subclasses CSS drives. Chrome exposes
// all three as globals and CreepJS counts window own keys, so they have to be
// here even though this engine never runs a CSS animation or transition and so
// never instantiates the two subclasses -- `getAnimations()` stays empty.
//
// Shapes, member order, arities and the "Illegal constructor" behaviour were
// measured on a headed Chrome 150 (probes probe-css1.js / probe-css11.js).

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Animation = @import("Animation.zig");

pub fn registerTypes() []const type {
    return &.{
        AnimationEffect,
        CSSAnimation,
        CSSTransition,
    };
}

/// The base of the effect hierarchy. Chrome hands one out from
/// `animation.effect`, which is always null here, so this is the interface and
/// its three timing accessors and nothing behind them.
pub const AnimationEffect = struct {
    _pad: bool = false,

    /// Measured: an effect with no keyframes still answers a full timing
    /// dictionary. Ours is the WebIDL default set, which is what Chrome
    /// reports for a KeyframeEffect built with no options.
    pub fn getTiming(_: *const AnimationEffect, exec: *const js.Execution) !js.Object {
        const object = exec.js.local.?.newObject();
        _ = try object.set("delay", @as(f64, 0), .{});
        _ = try object.set("endDelay", @as(f64, 0), .{});
        _ = try object.set("fill", "auto", .{});
        _ = try object.set("iterationStart", @as(f64, 0), .{});
        _ = try object.set("iterations", @as(f64, 1), .{});
        _ = try object.set("direction", "normal", .{});
        _ = try object.set("easing", "linear", .{});
        _ = try object.set("duration", "auto", .{});
        return object;
    }

    pub fn getComputedTiming(self: *const AnimationEffect, exec: *const js.Execution) !js.Object {
        const object = try self.getTiming(exec);
        _ = try object.set("activeDuration", @as(f64, 0), .{});
        _ = try object.set("endTime", @as(f64, 0), .{});
        _ = try object.set("localTime", null, .{});
        _ = try object.set("progress", null, .{});
        _ = try object.set("currentIteration", null, .{});
        return object;
    }

    /// Nothing to update while there is no effect behind the interface, but the
    /// method has to exist and accept the dictionary.
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
