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

// The live half of WebXR. `navigator.xr.requestSession('inline')` RESOLVES on a
// plain desktop Chrome with no headset -- measured on a headed Chrome 150 -- so
// the session, its render state and its frame loop are all reachable from
// ordinary script and are implemented here for real rather than refused.
// Refusing the whole family is itself a fingerprint.
//
// Three measured behaviours drive the shape of this file, and none of them is
// in the spec:
//
//   1. An inline session's requestAnimationFrame does NOT fire until a
//      baseLayer is set. With no layer the callback never arrives, while plain
//      window.requestAnimationFrame keeps ticking in the same page. That is
//      why the frame loop here is gated on the render state rather than
//      scheduled unconditionally.
//   2. updateRenderState is not visible synchronously. Right after the call
//      `session.renderState.baseLayer` is still null; inside the next frame
//      callback it is the layer. So a pending state is held and applied at the
//      top of a frame.
//   3. session.end() flips the session to ended right away -- a second end()
//      says "XRSession has already ended." -- but the promise it returns never
//      settles and no `end` event is ever dispatched. Confirmed with a ten
//      second window and a 100ms ticker running alongside (probe-win55.js).
//
// See stealth-detector-probes/win-batch/win52-findings.md for the rest.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const features = @import("features.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const layers = @import("layers.zig");
const spaces = @import("spaces.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const Page = @import("../../Page.zig");

const XRInputSourceArray = input.XRInputSourceArray;
const XRPose = geometry.XRPose;
const XRRigidTransform = geometry.XRRigidTransform;
const XRView = geometry.XRView;
const XRViewerPose = geometry.XRViewerPose;
const XRLayer = layers.XRLayer;
const XRWebGLLayer = layers.XRWebGLLayer;
const XRDOMOverlayState = layers.XRDOMOverlayState;
const XRReferenceSpace = spaces.XRReferenceSpace;
const XRSpace = spaces.XRSpace;
const Execution = js.Execution;
const String = lp.String;

pub fn registerTypes() []const type {
    return &.{
        XRFrame,
        XRInputSourceEvent,
        XRInputSourcesChangeEvent,
        XRRenderState,
        XRSession,
        XRSessionEvent,
    };
}

/// The three XRSessionMode values, and the only enum in this family a page can
/// hand to two different methods.
pub const Mode = enum {
    inline_,
    immersive_vr,
    immersive_ar,

    pub fn parse(text: []const u8) ?Mode {
        if (std.mem.eql(u8, text, "inline")) return .inline_;
        if (std.mem.eql(u8, text, "immersive-vr")) return .immersive_vr;
        if (std.mem.eql(u8, text, "immersive-ar")) return .immersive_ar;
        return null;
    }
};

fn badMode(comptime method: []const u8, text: []const u8, exec: *const Execution) anyerror {
    return dictionary.throwTypeError(try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '" ++ method ++ "' on 'XRSystem': The provided value '{s}' is not a " ++
            "valid enum value of type XRSessionMode.",
        .{text},
    ), exec);
}

/// `navigator.xr.isSessionSupported`. Inline is supported on any machine;
/// nothing else is without a headset (measured).
pub fn isSessionSupported(mode_: ?[]const u8, exec: *const Execution) !js.Promise {
    const text = mode_ orelse return dictionary.throwTypeError(
        "Failed to execute 'isSessionSupported' on 'XRSystem': 1 argument required, but only 0 present.",
        exec,
    );
    const mode = Mode.parse(text) orelse return badMode("isSessionSupported", text, exec);
    return exec.js.local.?.resolvePromise(mode == .inline_);
}

/// `navigator.xr.requestSession`. Inline hands back a real session; the two
/// immersive modes need a user activation Chrome never grants here, and say so
/// with a SecurityError rather than a NotSupportedError.
pub fn requestSession(mode_: ?[]const u8, _: ?js.Object, exec: *Execution) !js.Promise {
    const text = mode_ orelse return dictionary.throwTypeError(
        "Failed to execute 'requestSession' on 'XRSystem': 1 argument required, but only 0 present.",
        exec,
    );
    const mode = Mode.parse(text) orelse return badMode("requestSession", text, exec);
    if (mode != .inline_) {
        return dictionary.throwDom(
            "SecurityError",
            "Failed to execute 'requestSession' on 'XRSystem': " ++
                "The requested session requires user activation.",
            exec,
        );
    }
    return exec.js.local.?.resolvePromise(try XRSession.create(mode, exec));
}

/// The layer configuration a session draws with. Its identity is stable across
/// reads; the values change at the top of a frame, never mid-call.
pub const XRRenderState = struct {
    _depth_near: f64 = 0.1,
    _depth_far: f64 = 1000,
    _inline_vertical_fov: ?f64 = std.math.pi / 2.0,
    _base_layer: ?*XRWebGLLayer = null,
    _layers: []const *XRLayer = &.{},

    pub fn getDepthNear(self: *const XRRenderState) f64 {
        return self._depth_near;
    }

    pub fn getDepthFar(self: *const XRRenderState) f64 {
        return self._depth_far;
    }

    pub fn getInlineVerticalFieldOfView(self: *const XRRenderState) ?f64 {
        return self._inline_vertical_fov;
    }

    pub fn getBaseLayer(self: *const XRRenderState) ?*XRWebGLLayer {
        return self._base_layer;
    }

    /// Chrome's is a frozen FrozenArray; this engine cannot freeze an array it
    /// builds, so ours is ordinary. Empty either way for an inline session.
    pub fn getLayers(self: *const XRRenderState) []const *XRLayer {
        return self._layers;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRRenderState);

        pub const Meta = struct {
            pub const name = "XRRenderState";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const depthNear = bridge.accessor(XRRenderState.getDepthNear, null, .{});
        pub const depthFar = bridge.accessor(XRRenderState.getDepthFar, null, .{});
        pub const inlineVerticalFieldOfView = bridge.accessor(
            XRRenderState.getInlineVerticalFieldOfView,
            null,
            .{},
        );
        pub const baseLayer = bridge.accessor(XRRenderState.getBaseLayer, null, .{});
        pub const layers = bridge.accessor(XRRenderState.getLayers, null, .{});
    };
};

/// What updateRenderState recorded but no frame has applied yet.
const Pending = struct {
    depth_near: ?f64 = null,
    depth_far: ?f64 = null,
    inline_vertical_fov: ?f64 = null,
    base_layer: ?*XRWebGLLayer = null,
    has_base_layer: bool = false,

    fn any(self: Pending) bool {
        return self.depth_near != null or self.depth_far != null or
            self.inline_vertical_fov != null or self.has_base_layer;
    }
};

const RafEntry = struct {
    handle: u32,
    callback: js.Function.Global,
    cancelled: bool = false,
};

pub const XRSession = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _mode: Mode,
    _ended: bool = false,
    _in_frame: bool = false,
    _frame_seen: bool = false,
    _scheduled: bool = false,
    _next_handle: u32 = 1,
    _render_state: *XRRenderState,
    _pending: Pending = .{},
    _input_sources: *XRInputSourceArray,
    _callbacks: std.ArrayListUnmanaged(RafEntry) = .empty,
    _exec: *Execution,

    _on_end: ?js.Function.Global = null,
    _on_select: ?js.Function.Global = null,
    _on_input_sources_change: ?js.Function.Global = null,
    _on_select_start: ?js.Function.Global = null,
    _on_select_end: ?js.Function.Global = null,
    _on_visibility_change: ?js.Function.Global = null,
    _on_squeeze: ?js.Function.Global = null,
    _on_squeeze_start: ?js.Function.Global = null,
    _on_squeeze_end: ?js.Function.Global = null,
    _on_visibility_mask_change: ?js.Function.Global = null,

    const ENDED_PREFIX = "Failed to execute '";
    const DEPTH_UNSUPPORTED = "Depth sensing feature is not supported by the session.";

    fn ended(comptime method: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwDom(
            "InvalidStateError",
            ENDED_PREFIX ++ method ++ "' on 'XRSession': XRSession has already ended.",
            exec,
        );
    }

    fn depthRefusal(comptime member: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwDom(
            "InvalidStateError",
            "Failed to read the '" ++ member ++ "' property from 'XRSession': " ++ DEPTH_UNSUPPORTED,
            exec,
        );
    }

    pub fn create(mode: Mode, exec: *Execution) !*XRSession {
        const state = try exec._factory.create(XRRenderState{});
        const sources = try XRInputSourceArray.create(exec);
        const session = try exec._factory.eventTarget(XRSession{
            ._proto = undefined,
            ._mode = mode,
            ._render_state = state,
            ._input_sources = sources,
            ._exec = exec,
        });
        return session;
    }

    pub fn asEventTarget(self: *XRSession) *EventTarget {
        return self._proto;
    }

    pub fn getEnvironmentBlendMode(_: *const XRSession) []const u8 {
        return "opaque";
    }

    pub fn getInteractionMode(_: *const XRSession) []const u8 {
        return "screen-space";
    }

    /// Stays "visible" even after end() -- measured, and worth keeping,
    /// because the obvious guess is "hidden".
    pub fn getVisibilityState(_: *const XRSession) []const u8 {
        return "visible";
    }

    pub fn getRenderState(self: *const XRSession) *XRRenderState {
        return self._render_state;
    }

    pub fn getInputSources(self: *const XRSession) *XRInputSourceArray {
        return self._input_sources;
    }

    pub fn getDomOverlayState(_: *const XRSession) ?*XRDOMOverlayState {
        return null;
    }

    pub fn getPreferredReflectionFormat(_: *const XRSession) []const u8 {
        return "rgba16f";
    }

    pub fn getEnabledFeatures(_: *const XRSession) []const []const u8 {
        return &.{"viewer"};
    }

    pub fn getMaxRenderLayers(_: *const XRSession) u32 {
        return 1;
    }

    // The four depth getters all refuse; a page reading any of them learns the
    // feature is off rather than seeing a null.
    pub fn getDepthUsage(_: *const XRSession, exec: *const Execution) ![]const u8 {
        return depthRefusal("depthUsage", exec);
    }

    pub fn getDepthDataFormat(_: *const XRSession, exec: *const Execution) ![]const u8 {
        return depthRefusal("depthDataFormat", exec);
    }

    pub fn getDepthType(_: *const XRSession, exec: *const Execution) ![]const u8 {
        return depthRefusal("depthType", exec);
    }

    pub fn getDepthActive(_: *const XRSession, exec: *const Execution) !bool {
        return depthRefusal("depthActive", exec);
    }

    pub fn requestReferenceSpace(
        self: *XRSession,
        type_: ?[]const u8,
        exec: *const Execution,
    ) !js.Promise {
        if (self._ended) return ended("requestReferenceSpace", exec);
        const text = type_ orelse return dictionary.throwTypeError(
            "Failed to execute 'requestReferenceSpace' on 'XRSession': " ++
                "1 argument required, but only 0 present.",
            exec,
        );
        const known = std.mem.eql(u8, text, "viewer") or std.mem.eql(u8, text, "local") or
            std.mem.eql(u8, text, "local-floor") or std.mem.eql(u8, text, "bounded-floor") or
            std.mem.eql(u8, text, "unbounded");
        if (!known) {
            return dictionary.throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to execute 'requestReferenceSpace' on 'XRSession': The provided value " ++
                    "'{s}' is not a valid enum value of type XRReferenceSpaceType.",
                .{text},
            ), exec);
        }
        if (!std.mem.eql(u8, text, "viewer")) {
            // Only `viewer` on a machine with no tracking, and the refusal
            // blames the device rather than the feature list (measured).
            return dictionary.throwDom(
                "NotSupportedError",
                "Failed to execute 'requestReferenceSpace' on 'XRSession': " ++
                    "This device does not support the requested reference space type.",
                exec,
            );
        }
        return exec.js.local.?.resolvePromise(try XRReferenceSpace.create("viewer", .{}, exec));
    }

    /// Records the change; a frame applies it. Reading `renderState` straight
    /// afterwards still shows the old values (measured).
    pub fn updateRenderState(self: *XRSession, init_: ?js.Value, exec: *Execution) !void {
        if (self._ended) return ended("updateRenderState", exec);
        const Reader = dictionary.MethodReader("XRSession", "updateRenderState", "XRRenderStateInit");
        const reader = try Reader.read(init_, exec);

        if (try reader.present("baseLayer")) |value| {
            if (value.isNull()) {
                self._pending.base_layer = null;
                self._pending.has_base_layer = true;
            } else {
                self._pending.base_layer = value.toZig(*XRWebGLLayer) catch
                    return Reader.convertFailed("baseLayer", "XRWebGLLayer", exec);
                self._pending.has_base_layer = true;
            }
        }
        if (try reader.present("depthNear")) |value| {
            self._pending.depth_near = try value.toF64();
        }
        if (try reader.present("depthFar")) |value| {
            self._pending.depth_far = try value.toF64();
        }
        if (try reader.present("inlineVerticalFieldOfView")) |value| {
            self._pending.inline_vertical_fov = try value.toF64();
        }
        // `layers` is accepted and dropped on an inline session -- measured, no
        // throw and no effect.
        _ = try reader.present("layers");

        try self.maybeSchedule(exec);
    }

    fn applyPending(self: *XRSession) void {
        const pending = self._pending;
        if (pending.depth_near) |v| self._render_state._depth_near = v;
        if (pending.depth_far) |v| self._render_state._depth_far = v;
        if (pending.inline_vertical_fov) |v| {
            // Chrome clamps rather than throwing (measured: a field of view of
            // 4 radians is accepted and the state keeps a legal value).
            self._render_state._inline_vertical_fov = std.math.clamp(v, 0.0, std.math.pi);
        }
        if (pending.has_base_layer) self._render_state._base_layer = pending.base_layer;
        self._pending = .{};
    }

    pub fn requestAnimationFrame(self: *XRSession, callback_: ?js.Function, exec: *Execution) !u32 {
        // After end() the handle is 0 and the callback never runs (measured).
        if (self._ended) return 0;
        const callback = callback_ orelse return dictionary.throwTypeError(
            "Failed to execute 'requestAnimationFrame' on 'XRSession': " ++
                "1 argument required, but only 0 present.",
            exec,
        );
        const handle = self._next_handle;
        self._next_handle = handle + 1;
        try self._callbacks.append(exec.arena, .{
            .handle = handle,
            .callback = try callback.persist(),
        });
        try self.maybeSchedule(exec);
        return handle;
    }

    pub fn cancelAnimationFrame(self: *XRSession, handle_: ?u32) void {
        const handle = handle_ orelse return;
        for (self._callbacks.items) |*entry| {
            if (entry.handle == handle) {
                entry.cancelled = true;
                return;
            }
        }
    }

    /// The gate that makes an inline session's loop behave like Chrome's: no
    /// baseLayer, no frames. Without this the callbacks would run and the
    /// engine would be distinguishable from a real browser in the other
    /// direction.
    fn maybeSchedule(self: *XRSession, exec: *Execution) !void {
        if (self._ended or self._scheduled or self._in_frame) return;
        if (self._callbacks.items.len == 0) return;
        const has_layer = self._render_state._base_layer != null or
            (self._pending.has_base_layer and self._pending.base_layer != null);
        if (!has_layer) return;
        self._scheduled = true;
        errdefer self._scheduled = false;
        try exec._scheduler.add(self, tick, 0, .{ .name = "XRSession.frame" });
    }

    fn tick(ptr: *anyopaque) !?u32 {
        const self: *XRSession = @ptrCast(@alignCast(ptr));
        self._scheduled = false;
        if (self._ended) return null;

        const exec = self._exec;
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        self.applyPending();

        const now = switch (exec.js.global) {
            .frame => |frame| frame.window._performance.now(),
            .worker => |worker| worker._performance.now(),
        };
        const frame = try exec._factory.create(XRFrame{ ._session = self });

        // Taken by value: a callback may queue the next frame, and those
        // belong to the *next* tick, not this one.
        const due = self._callbacks;
        self._callbacks = .empty;

        self._in_frame = true;
        self._frame_seen = true;
        defer self._in_frame = false;
        for (due.items) |entry| {
            if (entry.cancelled) continue;
            ls.toLocal(entry.callback).call(void, .{ now, frame }) catch |err| {
                exec.page.recordJsError(err);
            };
        }
        frame._active = false;

        try self.maybeSchedule(exec);
        return null;
    }

    /// Flips to ended right away, and hands back a promise that never settles.
    /// Both halves are measured; so is the absence of an `end` event.
    ///
    /// A second call does not throw -- it hands back a *rejected* promise
    /// (measured: `session.end()` on an ended session is [object Promise] that
    /// rejects with InvalidStateError, not a synchronous TypeError).
    pub fn end(self: *XRSession, exec: *const Execution) !js.Promise {
        if (self._ended) {
            var resolver = exec.js.local.?.createPromiseResolver();
            resolver.reject("webxr", @import("../DOMException.zig").init(
                "Failed to execute 'end' on 'XRSession': XRSession has already ended.",
                "InvalidStateError",
            ));
            return resolver.promise();
        }
        self._ended = true;
        self._callbacks.clearRetainingCapacity();
        const resolver = exec.js.local.?.createPromiseResolver();
        return resolver.promise();
    }

    fn featureRefusal(
        comptime method: []const u8,
        comptime feature: []const u8,
        exec: *const Execution,
    ) anyerror {
        return dictionary.throwDom(
            "NotSupportedError",
            "Failed to execute '" ++ method ++ "' on 'XRSession': " ++
                "Session does not support feature " ++ feature,
            exec,
        );
    }

    pub fn requestHitTestSource(self: *XRSession, options_: ?js.Value, exec: *const Execution) !js.Promise {
        _ = self;
        _ = options_ orelse return dictionary.throwTypeError(
            "Failed to execute 'requestHitTestSource' on 'XRSession': " ++
                "1 argument required, but only 0 present.",
            exec,
        );
        return featureRefusal("requestHitTestSource", "hit-test", exec);
    }

    pub fn requestHitTestSourceForTransientInput(
        self: *XRSession,
        options_: ?js.Value,
        exec: *const Execution,
    ) !js.Promise {
        _ = self;
        _ = options_ orelse return dictionary.throwTypeError(
            "Failed to execute 'requestHitTestSourceForTransientInput' on 'XRSession': " ++
                "1 argument required, but only 0 present.",
            exec,
        );
        return featureRefusal("requestHitTestSourceForTransientInput", "hit-test", exec);
    }

    pub fn requestLightProbe(_: *XRSession, _: ?js.Value, exec: *const Execution) !js.Promise {
        return featureRefusal("requestLightProbe", "light-estimation", exec);
    }

    /// Before any frame has run Chrome complains about the frame; once one has,
    /// it complains about the feature instead. Both readings are measured
    /// (probe-win53 before a baseLayer existed, probe-win56 after a frame), and
    /// the exact Blink predicate was not isolated -- this reproduces both.
    fn depthSensing(self: *XRSession, comptime method: []const u8, exec: *const Execution) anyerror {
        if (!self._frame_seen) {
            return dictionary.throwDom(
                "InvalidStateError",
                "Failed to execute '" ++ method ++ "' on 'XRSession': " ++
                    "Not called from inside an active animation frame.",
                exec,
            );
        }
        return dictionary.throwDom(
            "NotSupportedError",
            "Failed to execute '" ++ method ++ "' on 'XRSession': " ++ DEPTH_UNSUPPORTED,
            exec,
        );
    }

    pub fn pauseDepthSensing(self: *XRSession, exec: *const Execution) !void {
        return self.depthSensing("pauseDepthSensing", exec);
    }

    pub fn resumeDepthSensing(self: *XRSession, exec: *const Execution) !void {
        return self.depthSensing("resumeDepthSensing", exec);
    }

    /// Chrome hands back a Promise without throwing; what it settles to on a
    /// device-less machine was not observable, so this one stays pending, the
    /// way end()'s does.
    pub fn initiateRoomCapture(_: *XRSession, exec: *const Execution) !js.Promise {
        const resolver = exec.js.local.?.createPromiseResolver();
        return resolver.promise();
    }

    fn Handler(comptime field: []const u8) type {
        return struct {
            fn get(self: *XRSession) ?js.Function.Global {
                return @field(self, field);
            }

            fn set(self: *XRSession, listener: ?js.Function) !void {
                @field(self, field) = if (listener) |l| try l.persistWithThis(self) else null;
            }
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRSession);

        pub const Meta = struct {
            pub const name = "XRSession";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        // Chrome's declaration order, which is not the spec's: the four depth
        // getters sit between the handlers and the methods, and the last four
        // members were appended after everything else.
        pub const environmentBlendMode = bridge.accessor(XRSession.getEnvironmentBlendMode, null, .{});
        pub const interactionMode = bridge.accessor(XRSession.getInteractionMode, null, .{});
        pub const visibilityState = bridge.accessor(XRSession.getVisibilityState, null, .{});
        pub const renderState = bridge.accessor(XRSession.getRenderState, null, .{});
        pub const inputSources = bridge.accessor(XRSession.getInputSources, null, .{});
        pub const domOverlayState = bridge.accessor(XRSession.getDomOverlayState, null, .{});
        pub const preferredReflectionFormat = bridge.accessor(
            XRSession.getPreferredReflectionFormat,
            null,
            .{},
        );
        pub const onend = bridge.accessor(Handler("_on_end").get, Handler("_on_end").set, .{});
        pub const onselect = bridge.accessor(Handler("_on_select").get, Handler("_on_select").set, .{});
        pub const oninputsourceschange = bridge.accessor(
            Handler("_on_input_sources_change").get,
            Handler("_on_input_sources_change").set,
            .{},
        );
        pub const onselectstart = bridge.accessor(
            Handler("_on_select_start").get,
            Handler("_on_select_start").set,
            .{},
        );
        pub const onselectend = bridge.accessor(
            Handler("_on_select_end").get,
            Handler("_on_select_end").set,
            .{},
        );
        pub const onvisibilitychange = bridge.accessor(
            Handler("_on_visibility_change").get,
            Handler("_on_visibility_change").set,
            .{},
        );
        pub const onsqueeze = bridge.accessor(Handler("_on_squeeze").get, Handler("_on_squeeze").set, .{});
        pub const onsqueezestart = bridge.accessor(
            Handler("_on_squeeze_start").get,
            Handler("_on_squeeze_start").set,
            .{},
        );
        pub const onsqueezeend = bridge.accessor(
            Handler("_on_squeeze_end").get,
            Handler("_on_squeeze_end").set,
            .{},
        );
        pub const depthUsage = bridge.accessor(XRSession.getDepthUsage, null, .{});
        pub const depthDataFormat = bridge.accessor(XRSession.getDepthDataFormat, null, .{});
        pub const depthType = bridge.accessor(XRSession.getDepthType, null, .{});
        pub const depthActive = bridge.accessor(XRSession.getDepthActive, null, .{});
        pub const cancelAnimationFrame = bridge.function(XRSession.cancelAnimationFrame, .{ .arity = 1 });
        pub const end = bridge.function(XRSession.end, .{});
        pub const pauseDepthSensing = bridge.function(XRSession.pauseDepthSensing, .{});
        pub const requestAnimationFrame = bridge.function(XRSession.requestAnimationFrame, .{ .arity = 1 });
        pub const requestHitTestSource = bridge.function(XRSession.requestHitTestSource, .{ .arity = 1 });
        pub const requestHitTestSourceForTransientInput = bridge.function(
            XRSession.requestHitTestSourceForTransientInput,
            .{ .arity = 1 },
        );
        pub const requestLightProbe = bridge.function(XRSession.requestLightProbe, .{});
        pub const requestReferenceSpace = bridge.function(
            XRSession.requestReferenceSpace,
            .{ .arity = 1 },
        );
        pub const resumeDepthSensing = bridge.function(XRSession.resumeDepthSensing, .{});
        pub const updateRenderState = bridge.function(XRSession.updateRenderState, .{});
        pub const enabledFeatures = bridge.accessor(XRSession.getEnabledFeatures, null, .{});
        pub const maxRenderLayers = bridge.accessor(XRSession.getMaxRenderLayers, null, .{});
        pub const onvisibilitymaskchange = bridge.accessor(
            Handler("_on_visibility_mask_change").get,
            Handler("_on_visibility_mask_change").set,
            .{},
        );
        pub const initiateRoomCapture = bridge.function(XRSession.initiateRoomCapture, .{});
    };
};

/// One turn of the loop. A new object every frame, and it stays usable after
/// its callback returns (measured -- getViewerPose still answers outside the
/// callback).
pub const XRFrame = struct {
    _session: *XRSession,
    _active: bool = true,

    fn argCount(comptime method: []const u8, comptime want: usize, got: usize, exec: *const Execution) anyerror {
        return dictionary.throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute '" ++ method ++ "' on 'XRFrame': {d} argument{s} required, but only " ++
                "{d} present.",
            .{ want, if (want == 1) "" else "s", got },
        ), exec);
    }

    fn notOfType(comptime method: []const u8, comptime idl: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwTypeError(
            "Failed to execute '" ++ method ++ "' on 'XRFrame': parameter 1 is not of type '" ++
                idl ++ "'.",
            exec,
        );
    }

    pub fn getSession(self: *const XRFrame) *XRSession {
        return self._session;
    }

    pub fn getPose(
        self: *const XRFrame,
        space_: ?js.Value,
        base_: ?js.Value,
        exec: *const Execution,
    ) !?*XRPose {
        _ = space_ orelse return argCount("getPose", 2, 0, exec);
        _ = base_ orelse return argCount("getPose", 2, 1, exec);
        _ = self;
        // Nothing moves: with no tracking every space sits on the session's
        // origin, so any pose between two of them is the identity.
        return XRPose.create(try XRRigidTransform.identity(exec), exec);
    }

    pub fn getViewerPose(self: *const XRFrame, space_: ?js.Value, exec: *const Execution) !?*XRViewerPose {
        _ = space_ orelse return argCount("getViewerPose", 1, 0, exec);

        const state = self._session._render_state;
        const fov = state._inline_vertical_fov orelse std.math.pi / 2.0;
        const near = state._depth_near;
        const far = state._depth_far;
        // The standard perspective matrix, aspect 1. Chrome's inline view
        // reports m[0] == m[5] == 1 for a pi/2 field of view even on a 2:1
        // canvas, so the aspect really is 1 rather than the layer's.
        const f = 1.0 / @tan(fov / 2.0);
        var projection: [16]f64 = .{0} ** 16;
        projection[0] = f;
        projection[5] = f;
        projection[10] = (far + near) / (near - far);
        projection[11] = -1;
        projection[14] = 2 * far * near / (near - far);

        const views = try exec.arena.alloc(*XRView, 1);
        views[0] = try XRView.create("none", 0, projection, try XRRigidTransform.identity(exec), exec);
        return XRViewerPose.create(try XRRigidTransform.identity(exec), views, exec);
    }

    /// A *new* set on every read, which is measured and not what a cached
    /// getter would do.
    pub fn getTrackedAnchors(_: *const XRFrame, exec: *const Execution) !*features.XRAnchorSet {
        return features.XRAnchorSet.create(exec);
    }

    pub fn getDetectedPlanes(_: *const XRFrame, exec: *const Execution) !*features.XRPlaneSet {
        return features.XRPlaneSet.create(exec);
    }

    pub fn createAnchor(
        _: *const XRFrame,
        _: ?js.Value,
        _: ?js.Value,
        exec: *const Execution,
    ) !js.Promise {
        var resolver = exec.js.local.?.createPromiseResolver();
        resolver.reject("webxr", @import("../DOMException.zig").init(
            "Failed to execute 'createAnchor' on 'XRFrame': Anchors feature is not supported by the session.",
            "NotSupportedError",
        ));
        return resolver.promise();
    }

    /// Refuses on a size mismatch before it refuses on the missing feature
    /// (measured: an empty joint list against a one-element radii buffer is
    /// "Buffer sizes must be equal", not a NotSupportedError).
    pub fn fillJointRadii(
        _: *const XRFrame,
        joints_: ?js.Value,
        radii_: ?js.TypedArray(f32),
        exec: *const Execution,
    ) !bool {
        const joints = joints_ orelse return argCount("fillJointRadii", 2, 0, exec);
        const radii = radii_ orelse return argCount("fillJointRadii", 2, 1, exec);
        const count = if (joints.isArray()) joints.toArray().len() else 0;
        if (count != radii.values.len) {
            return dictionary.throwTypeError(
                "Failed to execute 'fillJointRadii' on 'XRFrame': Buffer sizes must be equal",
                exec,
            );
        }
        return true;
    }

    pub fn fillPoses(
        _: *const XRFrame,
        spaces_: ?js.Value,
        base_: ?js.Value,
        transforms_: ?js.TypedArray(f32),
        exec: *const Execution,
    ) !bool {
        const list = spaces_ orelse return argCount("fillPoses", 3, 0, exec);
        _ = base_ orelse return argCount("fillPoses", 3, 1, exec);
        const transforms = transforms_ orelse return argCount("fillPoses", 3, 2, exec);
        const count = if (list.isArray()) list.toArray().len() else 0;
        if (count * 16 > transforms.values.len) {
            return dictionary.throwTypeError(
                "Failed to execute 'fillPoses' on 'XRFrame': Buffer sizes must be equal",
                exec,
            );
        }
        return true;
    }

    pub fn getDepthInformation(_: *const XRFrame, view_: ?js.Value, exec: *const Execution) !?*features.XRCPUDepthInformation {
        _ = view_ orelse return argCount("getDepthInformation", 1, 0, exec);
        return dictionary.throwDom(
            "NotSupportedError",
            "Failed to execute 'getDepthInformation' on 'XRFrame': " ++
                "Depth sensing feature is not supported by the session.",
            exec,
        );
    }

    pub fn getHitTestResults(_: *const XRFrame, source_: ?js.Value, exec: *const Execution) ![]const *features.XRHitTestResult {
        const value = source_ orelse return argCount("getHitTestResults", 1, 0, exec);
        _ = value.toZig(*features.XRHitTestSource) catch
            return notOfType("getHitTestResults", "XRHitTestSource", exec);
        return &.{};
    }

    pub fn getHitTestResultsForTransientInput(
        _: *const XRFrame,
        source_: ?js.Value,
        exec: *const Execution,
    ) ![]const *features.XRTransientInputHitTestResult {
        const value = source_ orelse return argCount("getHitTestResultsForTransientInput", 1, 0, exec);
        _ = value.toZig(*features.XRTransientInputHitTestSource) catch
            return notOfType("getHitTestResultsForTransientInput", "XRTransientInputHitTestSource", exec);
        return &.{};
    }

    pub fn getJointPose(
        _: *const XRFrame,
        joint_: ?js.Value,
        _: ?js.Value,
        exec: *const Execution,
    ) !?*geometry.XRJointPose {
        const value = joint_ orelse return argCount("getJointPose", 2, 0, exec);
        _ = value.toZig(*spaces.XRJointSpace) catch
            return notOfType("getJointPose", "XRJointSpace", exec);
        return null;
    }

    pub fn getLightEstimate(
        _: *const XRFrame,
        probe_: ?js.Value,
        exec: *const Execution,
    ) !?*features.XRLightEstimate {
        const value = probe_ orelse return argCount("getLightEstimate", 1, 0, exec);
        _ = value.toZig(*features.XRLightProbe) catch
            return notOfType("getLightEstimate", "XRLightProbe", exec);
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRFrame);

        pub const Meta = struct {
            pub const name = "XRFrame";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's order: `session`, the two pose methods, then trackedAnchors,
        // then everything else alphabetically, with detectedPlanes last.
        pub const session = bridge.accessor(XRFrame.getSession, null, .{});
        pub const getPose = bridge.function(XRFrame.getPose, .{ .arity = 2 });
        pub const getViewerPose = bridge.function(XRFrame.getViewerPose, .{ .arity = 1 });
        pub const trackedAnchors = bridge.accessor(XRFrame.getTrackedAnchors, null, .{});
        pub const createAnchor = bridge.function(XRFrame.createAnchor, .{ .arity = 2 });
        pub const fillJointRadii = bridge.function(XRFrame.fillJointRadii, .{ .arity = 2 });
        pub const fillPoses = bridge.function(XRFrame.fillPoses, .{ .arity = 3 });
        pub const getDepthInformation = bridge.function(XRFrame.getDepthInformation, .{ .arity = 1 });
        pub const getHitTestResults = bridge.function(XRFrame.getHitTestResults, .{ .arity = 1 });
        pub const getHitTestResultsForTransientInput = bridge.function(
            XRFrame.getHitTestResultsForTransientInput,
            .{ .arity = 1 },
        );
        pub const getJointPose = bridge.function(XRFrame.getJointPose, .{ .arity = 2 });
        pub const getLightEstimate = bridge.function(XRFrame.getLightEstimate, .{ .arity = 1 });
        pub const detectedPlanes = bridge.accessor(XRFrame.getDetectedPlanes, null, .{});
    };
};

/// `end`, `visibilitychange` and the two squeeze/select families all carry
/// this. Nothing here dispatches one -- notably not `end` -- but a page can
/// build one.
pub const XRSessionEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _session: *XRSession,

    const Init = dictionary.Init("XRSessionEvent", "XRSessionEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*XRSessionEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRSessionEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRSessionEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        const session = try init.interfaceMember("session", XRSession, "XRSession", exec);
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "XRSessionEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            XRSessionEvent{ ._proto = undefined, ._session = session },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *XRSessionEvent) *Event {
        return self._proto;
    }

    pub fn getSession(self: *const XRSessionEvent) *XRSession {
        return self._session;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRSessionEvent);

        pub const Meta = struct {
            pub const name = "XRSessionEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(XRSessionEvent.constructor, .{ .arity = 2 });
        pub const session = bridge.accessor(XRSessionEvent.getSession, null, .{});
    };
};

/// `select` / `squeeze` and their start/end pairs. Requires a frame *and* an
/// input source, neither of which a page can get hold of here, so it can only
/// ever be refused -- which is exactly what the refusal wording pins.
pub const XRInputSourceEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _frame: *XRFrame,
    _input_source: *input.XRInputSource,

    const Init = dictionary.Init("XRInputSourceEvent", "XRInputSourceEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*XRInputSourceEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRInputSourceEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRInputSourceEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        // `frame` is read first, so an empty dictionary complains about it
        // rather than about inputSource (measured).
        const frame = try init.interfaceMember("frame", XRFrame, "XRFrame", exec);
        const source = try init.interfaceMember(
            "inputSource",
            input.XRInputSource,
            "XRInputSource",
            exec,
        );
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "XRInputSourceEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            XRInputSourceEvent{ ._proto = undefined, ._frame = frame, ._input_source = source },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *XRInputSourceEvent) *Event {
        return self._proto;
    }

    pub fn getFrame(self: *const XRInputSourceEvent) *XRFrame {
        return self._frame;
    }

    pub fn getInputSource(self: *const XRInputSourceEvent) *input.XRInputSource {
        return self._input_source;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRInputSourceEvent);

        pub const Meta = struct {
            pub const name = "XRInputSourceEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(XRInputSourceEvent.constructor, .{ .arity = 2 });
        pub const frame = bridge.accessor(XRInputSourceEvent.getFrame, null, .{});
        pub const inputSource = bridge.accessor(XRInputSourceEvent.getInputSource, null, .{});
    };
};

/// `inputsourceschange`. Its two sequence members are read before `session`,
/// so an empty dictionary complains about `added` (measured).
pub const XRInputSourcesChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _session: *XRSession,
    _added: []const *input.XRInputSource,
    _removed: []const *input.XRInputSource,

    const Init = dictionary.Init("XRInputSourcesChangeEvent", "XRInputSourcesChangeEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*XRInputSourcesChangeEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRInputSourcesChangeEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRInputSourcesChangeEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        const added = try readSources(Init, init, "added", exec);
        const removed = try readSources(Init, init, "removed", exec);
        const session = try init.interfaceMember("session", XRSession, "XRSession", exec);
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "XRInputSourcesChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            XRInputSourcesChangeEvent{
                ._proto = undefined,
                ._session = session,
                ._added = added,
                ._removed = removed,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    fn readSources(
        comptime Reader: type,
        reader: Reader,
        comptime name: []const u8,
        exec: *const Execution,
    ) ![]const *input.XRInputSource {
        const value = try reader.required(name, exec);
        if (!value.isArray()) {
            return Reader.notASequence(name, exec);
        }
        const array = value.toArray();
        const out = try exec.arena.alloc(*input.XRInputSource, array.len());
        for (out, 0..) |*slot, i| {
            const item = try array.get(@intCast(i));
            slot.* = item.toZig(*input.XRInputSource) catch
                return Reader.convertFailed(name, "XRInputSource", exec);
        }
        return out;
    }

    pub fn asEvent(self: *XRInputSourcesChangeEvent) *Event {
        return self._proto;
    }

    pub fn getSession(self: *const XRInputSourcesChangeEvent) *XRSession {
        return self._session;
    }

    pub fn getAdded(self: *const XRInputSourcesChangeEvent) []const *input.XRInputSource {
        return self._added;
    }

    pub fn getRemoved(self: *const XRInputSourcesChangeEvent) []const *input.XRInputSource {
        return self._removed;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRInputSourcesChangeEvent);

        pub const Meta = struct {
            pub const name = "XRInputSourcesChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(XRInputSourcesChangeEvent.constructor, .{ .arity = 2 });
        pub const session = bridge.accessor(XRInputSourcesChangeEvent.getSession, null, .{});
        pub const added = bridge.accessor(XRInputSourcesChangeEvent.getAdded, null, .{});
        pub const removed = bridge.accessor(XRInputSourcesChangeEvent.getRemoved, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebXR session" {
    try testing.htmlRunner("webxr/session.html", .{});
}
