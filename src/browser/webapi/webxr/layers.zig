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

// What a session draws into: fifteen interfaces, of which exactly one can be
// built on a device-less desktop.
//
// XRWebGLLayer constructs against an inline session and reports the canvas'
// own size (measured on a headed Chrome 150: 300x150 for an untouched canvas,
// antialias true, ignoreDepthValues true, framebuffer null). XRWebGLBinding
// refuses an inline session outright -- "Cannot create an XRWebGLBinding for an
// inline XRSession." -- and every composition layer comes from a binding, so
// XRCompositionLayer and its five subclasses, XRSubImage, XRWebGLSubImage and
// the two events never have an instance here.
//
// The layer viewport an inline session reports is 0,0,0,0 even though the
// framebuffer is 300x150 (measured), because the null framebuffer has no
// allocated viewport to hand out.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const dictionary = @import("../dictionary.zig");
const geometry = @import("geometry.zig");
const session_mod = @import("session.zig");
const spaces = @import("spaces.zig");
const DOMPointReadOnly = @import("../DOMPointReadOnly.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const WebGLRenderingContext = @import("../canvas/WebGLRenderingContext.zig");
const WebGL2RenderingContext = @import("../canvas/WebGL2RenderingContext.zig");
const WebGLTexture = @import("../canvas/webgl_objects.zig").WebGLTexture;

const XRRigidTransform = geometry.XRRigidTransform;
const XRViewport = geometry.XRViewport;
const XRView = geometry.XRView;
const XRSession = session_mod.XRSession;
const XRSpace = spaces.XRSpace;
const Execution = js.Execution;
const String = lp.String;

pub fn registerTypes() []const type {
    return &.{
        XRCompositionLayer,
        XRCubeLayer,
        XRCylinderLayer,
        XRDOMOverlayState,
        XREquirectLayer,
        XRLayer,
        XRLayerEvent,
        XRProjectionLayer,
        XRQuadLayer,
        XRSubImage,
        XRVisibilityMaskChangeEvent,
        XRWebGLBinding,
        XRWebGLLayer,
        XRWebGLSubImage,
    };
}

/// Either flavour of WebGL context, which is what XRWebGLLayer and
/// XRWebGLBinding take as their second argument.
const GlContext = union(enum) {
    v1: *WebGLRenderingContext,
    v2: *WebGL2RenderingContext,

    fn from(value: js.Value) ?GlContext {
        if (value.toZig(*WebGLRenderingContext)) |ctx| {
            return .{ .v1 = ctx };
        } else |_| {}
        if (value.toZig(*WebGL2RenderingContext)) |ctx| {
            return .{ .v2 = ctx };
        } else |_| {}
        return null;
    }

    fn size(self: GlContext) [2]u32 {
        return switch (self) {
            .v1 => |ctx| .{ ctx.getDrawingBufferWidth(), ctx.getDrawingBufferHeight() },
            .v2 => |ctx| .{ ctx.getDrawingBufferWidth(), ctx.getDrawingBufferHeight() },
        };
    }
};

/// Reads the (session, glContext) pair both constructors take, with the
/// wording each of them uses.
fn readSessionAndContext(
    comptime where: []const u8,
    session_: ?js.Value,
    context_: ?js.Value,
    exec: *const Execution,
) !struct { *XRSession, GlContext } {
    const session_value = session_ orelse return dictionary.throwTypeError(
        "Failed to construct '" ++ where ++ "': 2 arguments required, but only 0 present.",
        exec,
    );
    const context_value = context_ orelse return dictionary.throwTypeError(
        "Failed to construct '" ++ where ++ "': 2 arguments required, but only 1 present.",
        exec,
    );
    const session = session_value.toZig(*XRSession) catch return dictionary.throwTypeError(
        "Failed to construct '" ++ where ++ "': parameter 1 is not of type 'XRSession'.",
        exec,
    );
    const context = GlContext.from(context_value) orelse return dictionary.throwTypeError(
        "Failed to construct '" ++ where ++ "': parameter 2 is not of type 'XRWebGLRenderingContext'.",
        exec,
    );
    return .{ session, context };
}

/// The base every layer shares. Nothing of its own on the prototype.
pub const XRLayer = struct {
    pub const Proto = EventTarget;

    pub const Type = union(enum) {
        generic,
        webgl: *XRWebGLLayer,
        composition: *XRCompositionLayer,
    };

    _proto: *EventTarget,
    _type: Type = .generic,

    pub fn asEventTarget(self: *XRLayer) *EventTarget {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRLayer);

        pub const Meta = struct {
            pub const name = "XRLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;
    };
};

/// The one layer a page can build. Its numbers are the canvas', not a
/// device's.
pub const XRWebGLLayer = struct {
    pub const Proto = XRLayer;

    _proto: *XRLayer,
    _width: u32,
    _height: u32,

    const ENDED = "Failed to construct 'XRWebGLLayer': " ++
        "Cannot create an XRWebGLLayer for an XRSession which has already ended.";
    const VIEWPORT_ARITY = "Failed to execute 'getViewport' on 'XRWebGLLayer': " ++
        "1 argument required, but only 0 present.";
    const SCALE_ARITY = "Failed to execute 'getNativeFramebufferScaleFactor' on 'XRWebGLLayer': " ++
        "1 argument required, but only 0 present.";
    const SCALE_TYPE = "Failed to execute 'getNativeFramebufferScaleFactor' on 'XRWebGLLayer': " ++
        "parameter 1 is not of type 'XRSession'.";

    pub fn constructor(
        session_: ?js.Value,
        context_: ?js.Value,
        _: ?js.Value,
        exec: *const Execution,
    ) !*XRWebGLLayer {
        const pair = try readSessionAndContext("XRWebGLLayer", session_, context_, exec);
        if (pair[0]._ended) {
            return dictionary.throwDom("InvalidStateError", ENDED, exec);
        }
        const size = pair[1].size();
        const layer = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            XRLayer{ ._proto = undefined, ._type = undefined },
            XRWebGLLayer{ ._proto = undefined, ._width = size[0], ._height = size[1] },
        });
        layer._proto._type = .{ .webgl = layer };
        layer._proto._proto._type = .{ .xr_layer = layer._proto };
        return layer;
    }

    /// Chrome answers 1 for a live session and refuses anything else by type,
    /// including null (measured).
    pub fn getNativeFramebufferScaleFactor(session_: ?js.Value, exec: *const Execution) !f64 {
        const value = session_ orelse return dictionary.throwTypeError(SCALE_ARITY, exec);
        _ = value.toZig(*XRSession) catch return dictionary.throwTypeError(SCALE_TYPE, exec);
        return 1;
    }

    pub fn asXRLayer(self: *XRWebGLLayer) *XRLayer {
        return self._proto;
    }

    pub fn getAntialias(_: *const XRWebGLLayer) bool {
        return true;
    }

    pub fn getIgnoreDepthValues(_: *const XRWebGLLayer) bool {
        return true;
    }

    pub fn getFramebufferWidth(self: *const XRWebGLLayer) u32 {
        return self._width;
    }

    pub fn getFramebufferHeight(self: *const XRWebGLLayer) u32 {
        return self._height;
    }

    /// The null framebuffer: an inline session draws into the page's own
    /// backbuffer (measured -- `layer.framebuffer` is null, not a
    /// WebGLFramebuffer).
    pub fn getFramebuffer(_: *const XRWebGLLayer) ?*WebGLTexture {
        return null;
    }

    /// All zeroes for an inline session, which is what Chrome reports even
    /// though framebufferWidth/Height are the canvas' size.
    pub fn getViewport(_: *const XRWebGLLayer, view_: ?js.Value, exec: *const Execution) !*XRViewport {
        _ = view_ orelse return dictionary.throwTypeError(VIEWPORT_ARITY, exec);
        return XRViewport.create(0, 0, 0, 0, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRWebGLLayer);

        pub const Meta = struct {
            pub const name = "XRWebGLLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRLayer;

        pub const constructor = bridge.constructor(XRWebGLLayer.constructor, .{ .arity = 2 });
        pub const getNativeFramebufferScaleFactor = bridge.function(
            XRWebGLLayer.getNativeFramebufferScaleFactor,
            .{ .static = true, .arity = 1 },
        );
        pub const antialias = bridge.accessor(XRWebGLLayer.getAntialias, null, .{});
        pub const ignoreDepthValues = bridge.accessor(XRWebGLLayer.getIgnoreDepthValues, null, .{});
        pub const framebufferWidth = bridge.accessor(XRWebGLLayer.getFramebufferWidth, null, .{});
        pub const framebufferHeight = bridge.accessor(XRWebGLLayer.getFramebufferHeight, null, .{});
        pub const framebuffer = bridge.accessor(XRWebGLLayer.getFramebuffer, null, .{});
        pub const getViewport = bridge.function(XRWebGLLayer.getViewport, .{ .arity = 1 });
    };
};

/// The base of the five layers a binding makes. Unreachable here: every path
/// to one goes through XRWebGLBinding, which an inline session refuses.
pub const XRCompositionLayer = struct {
    pub const Proto = XRLayer;

    pub const Type = union(enum) {
        generic,
        cube: *XRCubeLayer,
        cylinder: *XRCylinderLayer,
        equirect: *XREquirectLayer,
        projection: *XRProjectionLayer,
        quad: *XRQuadLayer,
    };

    _proto: *XRLayer,
    _type: Type = .generic,
    _layout: []const u8 = "default",
    _blend_texture_source_alpha: bool = false,
    _force_mono_presentation: bool = false,
    _opacity: f64 = 1,
    _mip_levels: u32 = 1,
    _needs_redraw: bool = true,

    pub fn asXRLayer(self: *XRCompositionLayer) *XRLayer {
        return self._proto;
    }

    pub fn getLayout(self: *const XRCompositionLayer) []const u8 {
        return self._layout;
    }

    pub fn getBlendTextureSourceAlpha(self: *const XRCompositionLayer) bool {
        return self._blend_texture_source_alpha;
    }

    pub fn setBlendTextureSourceAlpha(self: *XRCompositionLayer, value: bool) void {
        self._blend_texture_source_alpha = value;
    }

    pub fn getForceMonoPresentation(self: *const XRCompositionLayer) bool {
        return self._force_mono_presentation;
    }

    pub fn setForceMonoPresentation(self: *XRCompositionLayer, value: bool) void {
        self._force_mono_presentation = value;
    }

    pub fn getOpacity(self: *const XRCompositionLayer) f64 {
        return self._opacity;
    }

    pub fn setOpacity(self: *XRCompositionLayer, value: f64) void {
        self._opacity = value;
    }

    pub fn getMipLevels(self: *const XRCompositionLayer) u32 {
        return self._mip_levels;
    }

    pub fn getNeedsRedraw(self: *const XRCompositionLayer) bool {
        return self._needs_redraw;
    }

    pub fn destroy(self: *XRCompositionLayer) void {
        self._needs_redraw = false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCompositionLayer);

        pub const Meta = struct {
            pub const name = "XRCompositionLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRLayer;

        pub const layout = bridge.accessor(XRCompositionLayer.getLayout, null, .{});
        pub const blendTextureSourceAlpha = bridge.accessor(
            XRCompositionLayer.getBlendTextureSourceAlpha,
            XRCompositionLayer.setBlendTextureSourceAlpha,
            .{},
        );
        pub const forceMonoPresentation = bridge.accessor(
            XRCompositionLayer.getForceMonoPresentation,
            XRCompositionLayer.setForceMonoPresentation,
            .{},
        );
        pub const opacity = bridge.accessor(
            XRCompositionLayer.getOpacity,
            XRCompositionLayer.setOpacity,
            .{},
        );
        pub const mipLevels = bridge.accessor(XRCompositionLayer.getMipLevels, null, .{});
        pub const needsRedraw = bridge.accessor(XRCompositionLayer.getNeedsRedraw, null, .{});
        pub const destroy = bridge.function(XRCompositionLayer.destroy, .{});
    };
};

/// The `space` + `onredraw` pair every composition subclass but the projection
/// one carries, plus whatever else that subclass declares. Written out per
/// type rather than generated, because the member *order* differs between them
/// and that order is what a shape probe reads.
fn LayerState(comptime T: type) type {
    return struct {
        fn getSpace(self: *const T) ?*XRSpace {
            return self._space;
        }

        fn setSpace(self: *T, value: ?*XRSpace) void {
            self._space = value;
        }

        fn getOnredraw(self: *const T) ?js.Function.Global {
            return self._on_redraw;
        }

        fn setOnredraw(self: *T, listener: ?js.Function) !void {
            self._on_redraw = if (listener) |l| try l.persistWithThis(self) else null;
        }
    };
}

pub const XRCubeLayer = struct {
    pub const Proto = XRCompositionLayer;

    _proto: *XRCompositionLayer,
    _space: ?*XRSpace = null,
    _orientation: ?*DOMPointReadOnly = null,
    _on_redraw: ?js.Function.Global = null,

    const state = LayerState(XRCubeLayer);

    pub fn asXRCompositionLayer(self: *XRCubeLayer) *XRCompositionLayer {
        return self._proto;
    }

    pub fn getOrientation(self: *const XRCubeLayer) ?*DOMPointReadOnly {
        return self._orientation;
    }

    pub fn setOrientation(self: *XRCubeLayer, value: ?*DOMPointReadOnly) void {
        self._orientation = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCubeLayer);

        pub const Meta = struct {
            pub const name = "XRCubeLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRCompositionLayer;

        pub const space = bridge.accessor(state.getSpace, state.setSpace, .{});
        pub const orientation = bridge.accessor(
            XRCubeLayer.getOrientation,
            XRCubeLayer.setOrientation,
            .{},
        );
        pub const onredraw = bridge.accessor(state.getOnredraw, state.setOnredraw, .{});
    };
};

pub const XRCylinderLayer = struct {
    pub const Proto = XRCompositionLayer;

    _proto: *XRCompositionLayer,
    _space: ?*XRSpace = null,
    _transform: ?*XRRigidTransform = null,
    _radius: f64 = 2,
    _central_angle: f64 = 0.7853981633974483,
    _aspect_ratio: f64 = 2,
    _on_redraw: ?js.Function.Global = null,

    const state = LayerState(XRCylinderLayer);

    pub fn asXRCompositionLayer(self: *XRCylinderLayer) *XRCompositionLayer {
        return self._proto;
    }

    pub fn getTransform(self: *const XRCylinderLayer) ?*XRRigidTransform {
        return self._transform;
    }

    pub fn setTransform(self: *XRCylinderLayer, value: ?*XRRigidTransform) void {
        self._transform = value;
    }

    pub fn getRadius(self: *const XRCylinderLayer) f64 {
        return self._radius;
    }

    pub fn setRadius(self: *XRCylinderLayer, value: f64) void {
        self._radius = value;
    }

    pub fn getCentralAngle(self: *const XRCylinderLayer) f64 {
        return self._central_angle;
    }

    pub fn setCentralAngle(self: *XRCylinderLayer, value: f64) void {
        self._central_angle = value;
    }

    pub fn getAspectRatio(self: *const XRCylinderLayer) f64 {
        return self._aspect_ratio;
    }

    pub fn setAspectRatio(self: *XRCylinderLayer, value: f64) void {
        self._aspect_ratio = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCylinderLayer);

        pub const Meta = struct {
            pub const name = "XRCylinderLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRCompositionLayer;

        pub const space = bridge.accessor(state.getSpace, state.setSpace, .{});
        pub const transform = bridge.accessor(
            XRCylinderLayer.getTransform,
            XRCylinderLayer.setTransform,
            .{},
        );
        pub const radius = bridge.accessor(XRCylinderLayer.getRadius, XRCylinderLayer.setRadius, .{});
        pub const centralAngle = bridge.accessor(
            XRCylinderLayer.getCentralAngle,
            XRCylinderLayer.setCentralAngle,
            .{},
        );
        pub const aspectRatio = bridge.accessor(
            XRCylinderLayer.getAspectRatio,
            XRCylinderLayer.setAspectRatio,
            .{},
        );
        pub const onredraw = bridge.accessor(state.getOnredraw, state.setOnredraw, .{});
    };
};

pub const XREquirectLayer = struct {
    pub const Proto = XRCompositionLayer;

    _proto: *XRCompositionLayer,
    _space: ?*XRSpace = null,
    _transform: ?*XRRigidTransform = null,
    _radius: f64 = 0,
    _central_horizontal_angle: f64 = 6.283185307179586,
    _upper_vertical_angle: f64 = 1.5707963267948966,
    _lower_vertical_angle: f64 = -1.5707963267948966,
    _on_redraw: ?js.Function.Global = null,

    const state = LayerState(XREquirectLayer);

    pub fn asXRCompositionLayer(self: *XREquirectLayer) *XRCompositionLayer {
        return self._proto;
    }

    pub fn getTransform(self: *const XREquirectLayer) ?*XRRigidTransform {
        return self._transform;
    }

    pub fn setTransform(self: *XREquirectLayer, value: ?*XRRigidTransform) void {
        self._transform = value;
    }

    pub fn getRadius(self: *const XREquirectLayer) f64 {
        return self._radius;
    }

    pub fn setRadius(self: *XREquirectLayer, value: f64) void {
        self._radius = value;
    }

    pub fn getCentralHorizontalAngle(self: *const XREquirectLayer) f64 {
        return self._central_horizontal_angle;
    }

    pub fn setCentralHorizontalAngle(self: *XREquirectLayer, value: f64) void {
        self._central_horizontal_angle = value;
    }

    pub fn getUpperVerticalAngle(self: *const XREquirectLayer) f64 {
        return self._upper_vertical_angle;
    }

    pub fn setUpperVerticalAngle(self: *XREquirectLayer, value: f64) void {
        self._upper_vertical_angle = value;
    }

    pub fn getLowerVerticalAngle(self: *const XREquirectLayer) f64 {
        return self._lower_vertical_angle;
    }

    pub fn setLowerVerticalAngle(self: *XREquirectLayer, value: f64) void {
        self._lower_vertical_angle = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XREquirectLayer);

        pub const Meta = struct {
            pub const name = "XREquirectLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRCompositionLayer;

        pub const space = bridge.accessor(state.getSpace, state.setSpace, .{});
        pub const transform = bridge.accessor(
            XREquirectLayer.getTransform,
            XREquirectLayer.setTransform,
            .{},
        );
        pub const radius = bridge.accessor(XREquirectLayer.getRadius, XREquirectLayer.setRadius, .{});
        pub const centralHorizontalAngle = bridge.accessor(
            XREquirectLayer.getCentralHorizontalAngle,
            XREquirectLayer.setCentralHorizontalAngle,
            .{},
        );
        pub const upperVerticalAngle = bridge.accessor(
            XREquirectLayer.getUpperVerticalAngle,
            XREquirectLayer.setUpperVerticalAngle,
            .{},
        );
        pub const lowerVerticalAngle = bridge.accessor(
            XREquirectLayer.getLowerVerticalAngle,
            XREquirectLayer.setLowerVerticalAngle,
            .{},
        );
        pub const onredraw = bridge.accessor(state.getOnredraw, state.setOnredraw, .{});
    };
};

/// The only composition layer with no `space`: it covers the whole view.
pub const XRProjectionLayer = struct {
    pub const Proto = XRCompositionLayer;

    _proto: *XRCompositionLayer,
    _texture_width: u32 = 0,
    _texture_height: u32 = 0,
    _texture_array_length: u32 = 1,
    _fixed_foveation: ?f64 = null,
    _delta_pose: ?*XRRigidTransform = null,

    pub fn asXRCompositionLayer(self: *XRProjectionLayer) *XRCompositionLayer {
        return self._proto;
    }

    pub fn getTextureWidth(self: *const XRProjectionLayer) u32 {
        return self._texture_width;
    }

    pub fn getTextureHeight(self: *const XRProjectionLayer) u32 {
        return self._texture_height;
    }

    pub fn getTextureArrayLength(self: *const XRProjectionLayer) u32 {
        return self._texture_array_length;
    }

    pub fn getIgnoreDepthValues(_: *const XRProjectionLayer) bool {
        return false;
    }

    pub fn getFixedFoveation(self: *const XRProjectionLayer) ?f64 {
        return self._fixed_foveation;
    }

    pub fn setFixedFoveation(self: *XRProjectionLayer, value: ?f64) void {
        self._fixed_foveation = value;
    }

    pub fn getDeltaPose(self: *const XRProjectionLayer) ?*XRRigidTransform {
        return self._delta_pose;
    }

    pub fn setDeltaPose(self: *XRProjectionLayer, value: ?*XRRigidTransform) void {
        self._delta_pose = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRProjectionLayer);

        pub const Meta = struct {
            pub const name = "XRProjectionLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRCompositionLayer;

        pub const textureWidth = bridge.accessor(XRProjectionLayer.getTextureWidth, null, .{});
        pub const textureHeight = bridge.accessor(XRProjectionLayer.getTextureHeight, null, .{});
        pub const textureArrayLength = bridge.accessor(XRProjectionLayer.getTextureArrayLength, null, .{});
        pub const ignoreDepthValues = bridge.accessor(XRProjectionLayer.getIgnoreDepthValues, null, .{});
        pub const fixedFoveation = bridge.accessor(
            XRProjectionLayer.getFixedFoveation,
            XRProjectionLayer.setFixedFoveation,
            .{},
        );
        pub const deltaPose = bridge.accessor(
            XRProjectionLayer.getDeltaPose,
            XRProjectionLayer.setDeltaPose,
            .{},
        );
    };
};

pub const XRQuadLayer = struct {
    pub const Proto = XRCompositionLayer;

    _proto: *XRCompositionLayer,
    _space: ?*XRSpace = null,
    _transform: ?*XRRigidTransform = null,
    _width: f64 = 1,
    _height: f64 = 1,
    _on_redraw: ?js.Function.Global = null,

    const state = LayerState(XRQuadLayer);

    pub fn asXRCompositionLayer(self: *XRQuadLayer) *XRCompositionLayer {
        return self._proto;
    }

    pub fn getTransform(self: *const XRQuadLayer) ?*XRRigidTransform {
        return self._transform;
    }

    pub fn setTransform(self: *XRQuadLayer, value: ?*XRRigidTransform) void {
        self._transform = value;
    }

    pub fn getWidth(self: *const XRQuadLayer) f64 {
        return self._width;
    }

    pub fn setWidth(self: *XRQuadLayer, value: f64) void {
        self._width = value;
    }

    pub fn getHeight(self: *const XRQuadLayer) f64 {
        return self._height;
    }

    pub fn setHeight(self: *XRQuadLayer, value: f64) void {
        self._height = value;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRQuadLayer);

        pub const Meta = struct {
            pub const name = "XRQuadLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRCompositionLayer;

        pub const space = bridge.accessor(state.getSpace, state.setSpace, .{});
        pub const transform = bridge.accessor(XRQuadLayer.getTransform, XRQuadLayer.setTransform, .{});
        pub const width = bridge.accessor(XRQuadLayer.getWidth, XRQuadLayer.setWidth, .{});
        pub const height = bridge.accessor(XRQuadLayer.getHeight, XRQuadLayer.setHeight, .{});
        pub const onredraw = bridge.accessor(state.getOnredraw, state.setOnredraw, .{});
    };
};

/// The factory for every layer above. An inline session cannot have one at
/// all, so every method below is unreachable.
pub const XRWebGLBinding = struct {
    _session: *XRSession,
    _width: u32,
    _height: u32,

    const INLINE = "Failed to construct 'XRWebGLBinding': " ++
        "Cannot create an XRWebGLBinding for an inline XRSession.";

    pub fn constructor(
        session_: ?js.Value,
        context_: ?js.Value,
        exec: *const Execution,
    ) !*XRWebGLBinding {
        const pair = try readSessionAndContext("XRWebGLBinding", session_, context_, exec);
        // Every session this engine hands out is inline, so this is where the
        // constructor always ends (measured on Chrome too, for an inline one).
        if (pair[0]._mode == .inline_) {
            return dictionary.throwDom("InvalidStateError", INLINE, exec);
        }
        const size = pair[1].size();
        return exec._factory.create(XRWebGLBinding{
            ._session = pair[0],
            ._width = size[0],
            ._height = size[1],
        });
    }

    pub fn getNativeProjectionScaleFactor(_: *const XRWebGLBinding) f64 {
        return 1;
    }

    pub fn getUsesDepthValues(_: *const XRWebGLBinding) bool {
        return false;
    }

    fn unreachableLayer(comptime method: []const u8, exec: *const Execution) anyerror {
        return dictionary.throwDom(
            "InvalidStateError",
            "Failed to execute '" ++ method ++ "' on 'XRWebGLBinding': The session has ended.",
            exec,
        );
    }

    pub fn createCubeLayer(_: *const XRWebGLBinding, _: ?js.Value, exec: *const Execution) !*XRCubeLayer {
        return unreachableLayer("createCubeLayer", exec);
    }

    pub fn createCylinderLayer(_: *const XRWebGLBinding, _: ?js.Value, exec: *const Execution) !*XRCylinderLayer {
        return unreachableLayer("createCylinderLayer", exec);
    }

    pub fn createEquirectLayer(_: *const XRWebGLBinding, _: ?js.Value, exec: *const Execution) !*XREquirectLayer {
        return unreachableLayer("createEquirectLayer", exec);
    }

    pub fn createProjectionLayer(_: *const XRWebGLBinding, _: ?js.Value, exec: *const Execution) !*XRProjectionLayer {
        return unreachableLayer("createProjectionLayer", exec);
    }

    pub fn createQuadLayer(_: *const XRWebGLBinding, _: ?js.Value, exec: *const Execution) !*XRQuadLayer {
        return unreachableLayer("createQuadLayer", exec);
    }

    pub fn getSubImage(_: *const XRWebGLBinding, _: ?js.Value, _: ?js.Value, exec: *const Execution) !*XRWebGLSubImage {
        return unreachableLayer("getSubImage", exec);
    }

    pub fn getViewSubImage(_: *const XRWebGLBinding, _: ?js.Value, _: ?js.Value, exec: *const Execution) !*XRWebGLSubImage {
        return unreachableLayer("getViewSubImage", exec);
    }

    pub fn getCameraImage(_: *const XRWebGLBinding, _: ?js.Value) ?*WebGLTexture {
        return null;
    }

    pub fn getDepthInformation(_: *const XRWebGLBinding, _: ?js.Value) ?*WebGLTexture {
        return null;
    }

    pub fn getReflectionCubeMap(_: *const XRWebGLBinding, _: ?js.Value) ?*WebGLTexture {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRWebGLBinding);

        pub const Meta = struct {
            pub const name = "XRWebGLBinding";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(XRWebGLBinding.constructor, .{ .arity = 2 });
        pub const nativeProjectionScaleFactor = bridge.accessor(
            XRWebGLBinding.getNativeProjectionScaleFactor,
            null,
            .{},
        );
        pub const usesDepthValues = bridge.accessor(XRWebGLBinding.getUsesDepthValues, null, .{});
        pub const createCubeLayer = bridge.function(XRWebGLBinding.createCubeLayer, .{ .arity = 1 });
        pub const createCylinderLayer = bridge.function(XRWebGLBinding.createCylinderLayer, .{ .arity = 1 });
        pub const createEquirectLayer = bridge.function(XRWebGLBinding.createEquirectLayer, .{ .arity = 1 });
        pub const createProjectionLayer = bridge.function(XRWebGLBinding.createProjectionLayer, .{});
        pub const createQuadLayer = bridge.function(XRWebGLBinding.createQuadLayer, .{ .arity = 1 });
        pub const getSubImage = bridge.function(XRWebGLBinding.getSubImage, .{ .arity = 2 });
        pub const getViewSubImage = bridge.function(XRWebGLBinding.getViewSubImage, .{ .arity = 2 });
        pub const getCameraImage = bridge.function(XRWebGLBinding.getCameraImage, .{ .arity = 1 });
        pub const getDepthInformation = bridge.function(XRWebGLBinding.getDepthInformation, .{ .arity = 1 });
        pub const getReflectionCubeMap = bridge.function(XRWebGLBinding.getReflectionCubeMap, .{ .arity = 1 });
    };
};

pub const XRSubImage = struct {
    _viewport: *XRViewport,

    pub fn getViewport(self: *const XRSubImage) *XRViewport {
        return self._viewport;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRSubImage);

        pub const Meta = struct {
            pub const name = "XRSubImage";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const viewport = bridge.accessor(XRSubImage.getViewport, null, .{});
    };
};

pub const XRWebGLSubImage = struct {
    pub const Proto = XRSubImage;

    _proto: *XRSubImage,
    _color_texture: ?*WebGLTexture = null,
    _depth_stencil_texture: ?*WebGLTexture = null,
    _motion_vector_texture: ?*WebGLTexture = null,
    _image_index: ?u32 = null,
    _color_width: u32 = 0,
    _color_height: u32 = 0,
    _depth_width: ?u32 = null,
    _depth_height: ?u32 = null,
    _motion_width: ?u32 = null,
    _motion_height: ?u32 = null,

    pub fn asXRSubImage(self: *XRWebGLSubImage) *XRSubImage {
        return self._proto;
    }

    pub fn getColorTexture(self: *const XRWebGLSubImage) ?*WebGLTexture {
        return self._color_texture;
    }

    pub fn getDepthStencilTexture(self: *const XRWebGLSubImage) ?*WebGLTexture {
        return self._depth_stencil_texture;
    }

    pub fn getMotionVectorTexture(self: *const XRWebGLSubImage) ?*WebGLTexture {
        return self._motion_vector_texture;
    }

    pub fn getImageIndex(self: *const XRWebGLSubImage) ?u32 {
        return self._image_index;
    }

    pub fn getColorTextureWidth(self: *const XRWebGLSubImage) u32 {
        return self._color_width;
    }

    pub fn getColorTextureHeight(self: *const XRWebGLSubImage) u32 {
        return self._color_height;
    }

    pub fn getDepthStencilTextureWidth(self: *const XRWebGLSubImage) ?u32 {
        return self._depth_width;
    }

    pub fn getDepthStencilTextureHeight(self: *const XRWebGLSubImage) ?u32 {
        return self._depth_height;
    }

    pub fn getMotionVectorTextureWidth(self: *const XRWebGLSubImage) ?u32 {
        return self._motion_width;
    }

    pub fn getMotionVectorTextureHeight(self: *const XRWebGLSubImage) ?u32 {
        return self._motion_height;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRWebGLSubImage);

        pub const Meta = struct {
            pub const name = "XRWebGLSubImage";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRSubImage;

        pub const colorTexture = bridge.accessor(XRWebGLSubImage.getColorTexture, null, .{});
        pub const depthStencilTexture = bridge.accessor(XRWebGLSubImage.getDepthStencilTexture, null, .{});
        pub const motionVectorTexture = bridge.accessor(XRWebGLSubImage.getMotionVectorTexture, null, .{});
        pub const imageIndex = bridge.accessor(XRWebGLSubImage.getImageIndex, null, .{});
        pub const colorTextureWidth = bridge.accessor(XRWebGLSubImage.getColorTextureWidth, null, .{});
        pub const colorTextureHeight = bridge.accessor(XRWebGLSubImage.getColorTextureHeight, null, .{});
        pub const depthStencilTextureWidth = bridge.accessor(
            XRWebGLSubImage.getDepthStencilTextureWidth,
            null,
            .{},
        );
        pub const depthStencilTextureHeight = bridge.accessor(
            XRWebGLSubImage.getDepthStencilTextureHeight,
            null,
            .{},
        );
        pub const motionVectorTextureWidth = bridge.accessor(
            XRWebGLSubImage.getMotionVectorTextureWidth,
            null,
            .{},
        );
        pub const motionVectorTextureHeight = bridge.accessor(
            XRWebGLSubImage.getMotionVectorTextureHeight,
            null,
            .{},
        );
    };
};

/// `session.domOverlayState`, which is null unless the session was asked for
/// the dom-overlay feature. Nothing here asks.
pub const XRDOMOverlayState = struct {
    _type: []const u8 = "screen",

    pub fn getType(self: *const XRDOMOverlayState) []const u8 {
        return self._type;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRDOMOverlayState);

        pub const Meta = struct {
            pub const name = "XRDOMOverlayState";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(XRDOMOverlayState.getType, null, .{});
    };
};

/// `onredraw`'s payload. No layer here ever needs redrawing, so nothing fires
/// one; a page can still build one.
pub const XRLayerEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _layer: *XRLayer,

    const Init = dictionary.Init("XRLayerEvent", "XRLayerEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*XRLayerEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRLayerEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRLayerEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        const layer = try init.interfaceMember("layer", XRLayer, "XRLayer", exec);
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "XRLayerEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            XRLayerEvent{ ._proto = undefined, ._layer = layer },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *XRLayerEvent) *Event {
        return self._proto;
    }

    pub fn getLayer(self: *const XRLayerEvent) *XRLayer {
        return self._layer;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRLayerEvent);

        pub const Meta = struct {
            pub const name = "XRLayerEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(XRLayerEvent.constructor, .{ .arity = 2 });
        pub const layer = bridge.accessor(XRLayerEvent.getLayer, null, .{});
    };
};

/// What a headset fires when the mask around the lens changes shape. Never
/// here, and its five getters are all read-only.
pub const XRVisibilityMaskChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _session: *XRSession,
    _eye: []const u8,
    _index: u32,

    const Init = dictionary.Init("XRVisibilityMaskChangeEvent", "XRVisibilityMaskChangeEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*XRVisibilityMaskChangeEvent {
        const type_value = type_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRVisibilityMaskChangeEvent': 2 arguments required, but only 0 present.",
            exec,
        );
        const options = options_ orelse return dictionary.throwTypeError(
            "Failed to construct 'XRVisibilityMaskChangeEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.read(options, exec);
        const session = try init.interfaceMember("session", XRSession, "XRSession", exec);
        const typ = try type_value.toStringSlice();

        const arena = try exec.getArena(.tiny, "XRVisibilityMaskChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            XRVisibilityMaskChangeEvent{
                ._proto = undefined,
                ._session = session,
                ._eye = "none",
                ._index = 0,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *XRVisibilityMaskChangeEvent) *Event {
        return self._proto;
    }

    pub fn getSession(self: *const XRVisibilityMaskChangeEvent) *XRSession {
        return self._session;
    }

    pub fn getEye(self: *const XRVisibilityMaskChangeEvent) []const u8 {
        return self._eye;
    }

    pub fn getIndex(self: *const XRVisibilityMaskChangeEvent) u32 {
        return self._index;
    }

    pub fn getVertices(_: *const XRVisibilityMaskChangeEvent) ?js.Object {
        return null;
    }

    pub fn getIndices(_: *const XRVisibilityMaskChangeEvent) ?js.Object {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRVisibilityMaskChangeEvent);

        pub const Meta = struct {
            pub const name = "XRVisibilityMaskChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(XRVisibilityMaskChangeEvent.constructor, .{ .arity = 2 });
        pub const session = bridge.accessor(XRVisibilityMaskChangeEvent.getSession, null, .{});
        pub const eye = bridge.accessor(XRVisibilityMaskChangeEvent.getEye, null, .{});
        pub const index = bridge.accessor(XRVisibilityMaskChangeEvent.getIndex, null, .{});
        pub const vertices = bridge.accessor(XRVisibilityMaskChangeEvent.getVertices, null, .{});
        pub const indices = bridge.accessor(XRVisibilityMaskChangeEvent.getIndices, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebXR layers" {
    try testing.htmlRunner("webxr/layers.html", .{});
}
