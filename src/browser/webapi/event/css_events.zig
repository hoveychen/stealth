// The four Event subclasses CSS dispatches: transitions, animations, media
// query changes and font-face-set loading. Chrome exposes all four as globals
// and CreepJS counts window own keys, so an engine without them is four names
// short whether or not it ever fires one.
//
// Shapes, member order, defaults and rejection paths were measured on a headed
// Chrome 150 over http://localhost (probes probe-css1.js / probe-css11.js).
//
// Declaration order inside each JsApi is Chrome's own
// Object.getOwnPropertyNames(X.prototype) order, with one known deviation:
// Blink puts `pseudoTarget` AFTER `constructor` on TransitionEvent and
// AnimationEvent, and V8 can only place `constructor` last.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Event = @import("../Event.zig");
const Element = @import("../Element.zig");
const FontFace = @import("../css/FontFace.zig");

const String = lp.String;

pub fn registerTypes() []const type {
    return &.{
        TransitionEvent,
        AnimationEvent,
        MediaQueryListEvent,
        FontFaceSetLoadEvent,
    };
}

pub const TransitionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _property_name: []const u8 = "",
    _elapsed_time: f64 = 0,
    _pseudo_element: []const u8 = "",

    const TransitionEventOptions = struct {
        // Alphabetical: a dictionary's members are read in that order.
        elapsedTime: f64 = 0,
        propertyName: []const u8 = "",
        pseudoElement: []const u8 = "",
    };

    const Options = Event.inheritOptions(TransitionEvent, TransitionEventOptions);

    pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*TransitionEvent {
        const arena = try frame.getArena(.tiny, "TransitionEvent");
        errdefer arena.release();
        const type_string = try String.init(arena.allocator(), typ, .{});
        return build(arena, type_string, opts_, false, frame);
    }

    pub fn initTrusted(typ: String, opts_: ?Options, frame: *Frame) !*TransitionEvent {
        const arena = try frame.getArena(.tiny, "TransitionEvent.trusted");
        errdefer arena.release();
        return build(arena, typ, opts_, true, frame);
    }

    fn build(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, frame: *Frame) !*TransitionEvent {
        const opts = opts_ orelse Options{};
        const event = try frame._factory.event(arena, typ, TransitionEvent{
            ._proto = undefined,
            ._property_name = try arena.dupe(u8, opts.propertyName),
            ._elapsed_time = opts.elapsedTime,
            ._pseudo_element = try arena.dupe(u8, opts.pseudoElement),
        });
        Event.populatePrototypes(event, opts, trusted);
        return event;
    }

    pub fn asEvent(self: *TransitionEvent) *Event {
        return self._proto;
    }

    pub fn getPropertyName(self: *const TransitionEvent) []const u8 {
        return self._property_name;
    }

    pub fn getElapsedTime(self: *const TransitionEvent) f64 {
        return self._elapsed_time;
    }

    pub fn getPseudoElement(self: *const TransitionEvent) []const u8 {
        return self._pseudo_element;
    }

    /// Measured: the legacy alias is always null -- Chrome never populates it,
    /// it only keeps the name on the prototype.
    pub fn getPseudoTarget(_: *const TransitionEvent) ?*Element {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TransitionEvent);

        pub const Meta = struct {
            pub const name = "TransitionEvent";
            // `pseudoTarget` is runtime-flag gated, so Chrome installs it from
            // the per-context batch, behind `constructor` (measured).
            pub const constructor_after = "animation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(TransitionEvent.init, .{});
        pub const propertyName = bridge.accessor(TransitionEvent.getPropertyName, null, .{});
        pub const elapsedTime = bridge.accessor(TransitionEvent.getElapsedTime, null, .{});
        pub const pseudoElement = bridge.accessor(TransitionEvent.getPseudoElement, null, .{});

        /// The Animation this event came from. Always null: nothing here runs
        /// an animation timeline, and Chrome answers null for a synthesised
        /// `new TransitionEvent('x')` too (measured).
        pub const animation = bridge.accessor(_animation, null, .{});
        fn _animation(_: *TransitionEvent) ?*@import("../animation/Animation.zig") {
            return null;
        }

        pub const pseudoTarget = bridge.accessor(TransitionEvent.getPseudoTarget, null, .{});
    };
};

pub const AnimationEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _animation_name: []const u8 = "",
    _elapsed_time: f64 = 0,
    _pseudo_element: []const u8 = "",

    const AnimationEventOptions = struct {
        animationName: []const u8 = "",
        elapsedTime: f64 = 0,
        pseudoElement: []const u8 = "",
    };

    const Options = Event.inheritOptions(AnimationEvent, AnimationEventOptions);

    pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*AnimationEvent {
        const arena = try frame.getArena(.tiny, "AnimationEvent");
        errdefer arena.release();
        const type_string = try String.init(arena.allocator(), typ, .{});
        return build(arena, type_string, opts_, false, frame);
    }

    pub fn initTrusted(typ: String, opts_: ?Options, frame: *Frame) !*AnimationEvent {
        const arena = try frame.getArena(.tiny, "AnimationEvent.trusted");
        errdefer arena.release();
        return build(arena, typ, opts_, true, frame);
    }

    fn build(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, frame: *Frame) !*AnimationEvent {
        const opts = opts_ orelse Options{};
        const event = try frame._factory.event(arena, typ, AnimationEvent{
            ._proto = undefined,
            ._animation_name = try arena.dupe(u8, opts.animationName),
            ._elapsed_time = opts.elapsedTime,
            ._pseudo_element = try arena.dupe(u8, opts.pseudoElement),
        });
        Event.populatePrototypes(event, opts, trusted);
        return event;
    }

    pub fn asEvent(self: *AnimationEvent) *Event {
        return self._proto;
    }

    pub fn getAnimationName(self: *const AnimationEvent) []const u8 {
        return self._animation_name;
    }

    pub fn getElapsedTime(self: *const AnimationEvent) f64 {
        return self._elapsed_time;
    }

    pub fn getPseudoElement(self: *const AnimationEvent) []const u8 {
        return self._pseudo_element;
    }

    pub fn getPseudoTarget(_: *const AnimationEvent) ?*Element {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AnimationEvent);

        pub const Meta = struct {
            pub const name = "AnimationEvent";
            // `pseudoTarget` is runtime-flag gated, so Chrome installs it from
            // the per-context batch, behind `constructor` (measured).
            pub const constructor_after = "animation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(AnimationEvent.init, .{});
        pub const animationName = bridge.accessor(AnimationEvent.getAnimationName, null, .{});
        pub const elapsedTime = bridge.accessor(AnimationEvent.getElapsedTime, null, .{});
        pub const pseudoElement = bridge.accessor(AnimationEvent.getPseudoElement, null, .{});

        /// The Animation this event came from. Always null: nothing here runs
        /// an animation timeline, and Chrome answers null for a synthesised
        /// `new AnimationEvent('x')` too (measured).
        pub const animation = bridge.accessor(_animation, null, .{});
        fn _animation(_: *AnimationEvent) ?*@import("../animation/Animation.zig") {
            return null;
        }

        pub const pseudoTarget = bridge.accessor(AnimationEvent.getPseudoTarget, null, .{});
    };
};

pub const MediaQueryListEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _media: []const u8 = "",
    _matches: bool = false,

    const MediaQueryListEventOptions = struct {
        // Alphabetical: a dictionary's members are read in that order.
        matches: bool = false,
        media: []const u8 = "",
    };

    const Options = Event.inheritOptions(MediaQueryListEvent, MediaQueryListEventOptions);

    pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*MediaQueryListEvent {
        const arena = try frame.getArena(.tiny, "MediaQueryListEvent");
        errdefer arena.release();
        const type_string = try String.init(arena.allocator(), typ, .{});
        return build(arena, type_string, opts_, false, frame);
    }

    pub fn initTrusted(typ: String, opts_: ?Options, frame: *Frame) !*MediaQueryListEvent {
        const arena = try frame.getArena(.tiny, "MediaQueryListEvent.trusted");
        errdefer arena.release();
        return build(arena, typ, opts_, true, frame);
    }

    fn build(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, frame: *Frame) !*MediaQueryListEvent {
        const opts = opts_ orelse Options{};
        const event = try frame._factory.event(arena, typ, MediaQueryListEvent{
            ._proto = undefined,
            ._media = try arena.dupe(u8, opts.media),
            ._matches = opts.matches,
        });
        Event.populatePrototypes(event, opts, trusted);
        return event;
    }

    pub fn asEvent(self: *MediaQueryListEvent) *Event {
        return self._proto;
    }

    pub fn getMedia(self: *const MediaQueryListEvent) []const u8 {
        return self._media;
    }

    pub fn getMatches(self: *const MediaQueryListEvent) bool {
        return self._matches;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaQueryListEvent);

        pub const Meta = struct {
            pub const name = "MediaQueryListEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(MediaQueryListEvent.init, .{});
        pub const media = bridge.accessor(MediaQueryListEvent.getMedia, null, .{});
        pub const matches = bridge.accessor(MediaQueryListEvent.getMatches, null, .{});
    };
};

pub const FontFaceSetLoadEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _fontfaces: []const *FontFace = &.{},

    const FontFaceSetLoadEventOptions = struct {
        fontfaces: []const *FontFace = &.{},
    };

    const Options = Event.inheritOptions(FontFaceSetLoadEvent, FontFaceSetLoadEventOptions);

    pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*FontFaceSetLoadEvent {
        const arena = try frame.getArena(.tiny, "FontFaceSetLoadEvent");
        errdefer arena.release();
        const type_string = try String.init(arena.allocator(), typ, .{});
        return build(arena, type_string, opts_, false, frame);
    }

    pub fn initTrusted(typ: String, opts_: ?Options, frame: *Frame) !*FontFaceSetLoadEvent {
        const arena = try frame.getArena(.tiny, "FontFaceSetLoadEvent.trusted");
        errdefer arena.release();
        return build(arena, typ, opts_, true, frame);
    }

    fn build(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, frame: *Frame) !*FontFaceSetLoadEvent {
        const opts = opts_ orelse Options{};
        const event = try frame._factory.event(arena, typ, FontFaceSetLoadEvent{
            ._proto = undefined,
            ._fontfaces = try arena.dupe(*FontFace, opts.fontfaces),
        });
        Event.populatePrototypes(event, opts, trusted);
        return event;
    }

    pub fn asEvent(self: *FontFaceSetLoadEvent) *Event {
        return self._proto;
    }

    /// A FrozenArray, and measured: every read hands back a fresh frozen array
    /// object (`e.fontfaces === e.fontfaces` is false).
    pub fn getFontfaces(self: *const FontFaceSetLoadEvent) js.FrozenArray(*FontFace) {
        return .{ .items = self._fontfaces };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FontFaceSetLoadEvent);

        pub const Meta = struct {
            pub const name = "FontFaceSetLoadEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(FontFaceSetLoadEvent.init, .{});
        pub const fontfaces = bridge.accessor(FontFaceSetLoadEvent.getFontfaces, null, .{});
    };
};
