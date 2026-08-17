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

// The thirteen interfaces behind five optional session features: anchors,
// plane detection, hit testing, light estimation and depth sensing.
//
// An inline session on a device-less desktop enables none of them, and Chrome
// refuses each request by name (measured on a headed Chrome 150):
//
//   session.requestHitTestSource(...)  NotSupportedError
//       "Session does not support feature hit-test"
//   session.requestLightProbe()        NotSupportedError
//       "Session does not support feature light-estimation"
//   frame.getDepthInformation(view)    NotSupportedError
//       "Depth sensing feature is not supported by the session."
//   session.depthUsage (and the other three depth getters)
//       InvalidStateError, same wording
//
// So eleven of these thirteen never have an instance. The two that do are the
// set-likes: `frame.trackedAnchors` and `frame.detectedPlanes` are reachable
// from any frame and answer an empty XRAnchorSet / XRPlaneSet -- and, measured,
// a *new* one on each read rather than a cached one.

const std = @import("std");

const js = @import("../../js/js.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const spaces = @import("spaces.zig");
const DOMPointReadOnly = @import("../DOMPointReadOnly.zig");
const EventTarget = @import("../EventTarget.zig");
const WebGLTexture = @import("../canvas/webgl_objects.zig").WebGLTexture;

const XRPose = geometry.XRPose;
const XRRigidTransform = geometry.XRRigidTransform;
const XRSpace = spaces.XRSpace;
const XRInputSource = input.XRInputSource;
const Execution = js.Execution;
const Float32Array = js.ArrayBufferRef(.float32);
const GenericIterator = @import("../collections/iterator.zig").Entry;
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

pub fn registerTypes() []const type {
    return &.{
        XRAnchor,
        XRAnchorSet,
        XRAnchorSet.KeyIterator,
        XRAnchorSet.ValueIterator,
        XRAnchorSet.EntryIterator,
        XRCPUDepthInformation,
        XRDepthInformation,
        XRHitTestResult,
        XRHitTestSource,
        XRLightEstimate,
        XRLightProbe,
        XRPlane,
        XRPlaneSet,
        XRPlaneSet.KeyIterator,
        XRPlaneSet.ValueIterator,
        XRPlaneSet.EntryIterator,
        XRTransientInputHitTestResult,
        XRTransientInputHitTestSource,
        XRWebGLDepthInformation,
    };
}

/// A readonly setlike over pointers, which XRAnchorSet and XRPlaneSet are
/// character for character apart from the brand. `has` is WebIDL-typed, so a
/// non-member value is a TypeError rather than a false (measured:
/// `trackedAnchors.has({})` says "parameter 1 is not of type 'XRAnchor'.").
fn PointerSet(comptime type_name: []const u8, comptime Item: type) type {
    return struct {
        const Self = @This();

        _items: []const *Item = &.{},

        const NOT_ITEM = "Failed to execute 'has' on '" ++ type_name ++
            "': parameter 1 is not of type '" ++ type_name[0 .. type_name.len - 3] ++ "'.";

        pub fn create(exec: *const Execution) !*Self {
            return exec._factory.create(Self{});
        }

        pub fn getSize(self: *const Self) u32 {
            return @intCast(self._items.len);
        }

        pub fn has(self: *const Self, item_: ?js.Value, exec: *const Execution) !bool {
            const value = item_ orelse return @import("../dictionary.zig").throwTypeError(
                "Failed to execute 'has' on '" ++ type_name ++
                    "': 1 argument required, but only 0 present.",
                exec,
            );
            const item = value.toZig(*Item) catch
                return @import("../dictionary.zig").throwTypeError(NOT_ITEM, exec);
            for (self._items) |candidate| {
                if (candidate == item) return true;
            }
            return false;
        }

        pub fn keys(self: *Self, exec: *const Execution) !*KeyIterator {
            return .init(.{ .set = self }, exec);
        }

        pub fn values(self: *Self, exec: *const Execution) !*ValueIterator {
            return .init(.{ .set = self }, exec);
        }

        pub fn entries(self: *Self, exec: *const Execution) !*EntryIterator {
            return .init(.{ .set = self }, exec);
        }

        /// WebIDL-checked, unlike XRInputSourceArray's, whose no-argument call
        /// is a plain "undefined is not a function" (both measured).
        pub fn forEach(self: *Self, cb_: ?js.Function, js_this_: ?js.Object, exec: *const Execution) !void {
            const given = cb_ orelse return @import("../dictionary.zig").throwTypeError(
                "Failed to execute 'forEach' on '" ++ type_name ++
                    "': 1 argument required, but only 0 present.",
                exec,
            );
            const cb = if (js_this_) |js_this| try given.withThis(js_this) else given;
            for (self._items) |item| {
                var caught: js.TryCatch.Caught = undefined;
                cb.tryCall(void, .{ item, item, self }, &caught) catch {};
            }
        }

        pub const Iterator = struct {
            index: u32 = 0,
            set: *Self,

            pub const Entry = struct { *Item, *Item };

            pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
                const items = self.set._items;
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
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = type_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const size = bridge.accessor(Self.getSize, null, .{});
            pub const entries = bridge.function(Self.entries, .{});
            pub const forEach = bridge.function(Self.forEach, .{ .arity = 1 });
            pub const has = bridge.function(Self.has, .{ .arity = 1 });
            pub const keys = bridge.function(Self.keys, .{});
            pub const values = bridge.function(Self.values, .{});
            pub const symbol_iterator = bridge.iterator(Self.values, .{ .js_name = "values" });
        };
    };
}

/// A point in the world the runtime keeps tracking. Only an `anchors` session
/// creates one.
pub const XRAnchor = struct {
    _anchor_space: *XRSpace,
    _deleted: bool = false,

    pub fn getAnchorSpace(self: *const XRAnchor) *XRSpace {
        return self._anchor_space;
    }

    pub fn delete(self: *XRAnchor) void {
        self._deleted = true;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRAnchor);

        pub const Meta = struct {
            pub const name = "XRAnchor";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const anchorSpace = bridge.accessor(XRAnchor.getAnchorSpace, null, .{});
        pub const delete = bridge.function(XRAnchor.delete, .{});
    };
};

pub const XRAnchorSet = PointerSet("XRAnchorSet", XRAnchor);

/// A flat surface the runtime found. Only a `plane-detection` session has any.
pub const XRPlane = struct {
    _plane_space: *XRSpace,
    _polygon: []const *DOMPointReadOnly = &.{},
    _orientation: []const u8 = "horizontal",
    _last_changed_time: f64 = 0,
    _semantic_label: ?[]const u8 = null,

    pub fn getPlaneSpace(self: *const XRPlane) *XRSpace {
        return self._plane_space;
    }

    pub fn getPolygon(self: *const XRPlane) []const *DOMPointReadOnly {
        return self._polygon;
    }

    pub fn getOrientation(self: *const XRPlane) []const u8 {
        return self._orientation;
    }

    pub fn getLastChangedTime(self: *const XRPlane) f64 {
        return self._last_changed_time;
    }

    pub fn getSemanticLabel(self: *const XRPlane) ?[]const u8 {
        return self._semantic_label;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRPlane);

        pub const Meta = struct {
            pub const name = "XRPlane";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const planeSpace = bridge.accessor(XRPlane.getPlaneSpace, null, .{});
        pub const polygon = bridge.accessor(XRPlane.getPolygon, null, .{});
        pub const orientation = bridge.accessor(XRPlane.getOrientation, null, .{});
        pub const lastChangedTime = bridge.accessor(XRPlane.getLastChangedTime, null, .{});
        pub const semanticLabel = bridge.accessor(XRPlane.getSemanticLabel, null, .{});
    };
};

pub const XRPlaneSet = PointerSet("XRPlaneSet", XRPlane);

/// Where a ray met the world. `hit-test` is not a feature an inline session
/// enables, so nothing here produces one.
pub const XRHitTestResult = struct {
    _pose: *XRPose,

    pub fn getPose(self: *const XRHitTestResult, _: ?*XRSpace) ?*XRPose {
        return self._pose;
    }

    pub fn createAnchor(_: *const XRHitTestResult, exec: *const Execution) !js.Promise {
        var resolver = exec.js.local.?.createPromiseResolver();
        resolver.reject("webxr", @import("../DOMException.zig").init(
            "Failed to execute 'createAnchor' on 'XRHitTestResult': " ++
                "Anchors feature is not supported by the session.",
            "NotSupportedError",
        ));
        return resolver.promise();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRHitTestResult);

        pub const Meta = struct {
            pub const name = "XRHitTestResult";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getPose = bridge.function(XRHitTestResult.getPose, .{ .arity = 1 });
        pub const createAnchor = bridge.function(XRHitTestResult.createAnchor, .{});
    };
};

/// The handle `requestHitTestSource` would return.
pub const XRHitTestSource = struct {
    _cancelled: bool = false,

    pub fn cancel(self: *XRHitTestSource) void {
        self._cancelled = true;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRHitTestSource);

        pub const Meta = struct {
            pub const name = "XRHitTestSource";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const cancel = bridge.function(XRHitTestSource.cancel, .{});
    };
};

/// One transient input source's worth of hit results.
pub const XRTransientInputHitTestResult = struct {
    _input_source: *XRInputSource,
    _results: []const *XRHitTestResult = &.{},

    pub fn getInputSource(self: *const XRTransientInputHitTestResult) *XRInputSource {
        return self._input_source;
    }

    pub fn getResults(self: *const XRTransientInputHitTestResult) []const *XRHitTestResult {
        return self._results;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRTransientInputHitTestResult);

        pub const Meta = struct {
            pub const name = "XRTransientInputHitTestResult";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const inputSource = bridge.accessor(XRTransientInputHitTestResult.getInputSource, null, .{});
        pub const results = bridge.accessor(XRTransientInputHitTestResult.getResults, null, .{});
    };
};

pub const XRTransientInputHitTestSource = struct {
    _cancelled: bool = false,

    pub fn cancel(self: *XRTransientInputHitTestSource) void {
        self._cancelled = true;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRTransientInputHitTestSource);

        pub const Meta = struct {
            pub const name = "XRTransientInputHitTestSource";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const cancel = bridge.function(XRTransientInputHitTestSource.cancel, .{});
    };
};

/// What a `light-estimation` session would report about the room's lighting.
pub const XRLightEstimate = struct {
    _coefficients: Float32Array.Global,
    _primary_light_direction: *DOMPointReadOnly,
    _primary_light_intensity: *DOMPointReadOnly,

    pub fn getSphericalHarmonicsCoefficients(self: *const XRLightEstimate) Float32Array.Global {
        return self._coefficients;
    }

    pub fn getPrimaryLightDirection(self: *const XRLightEstimate) *DOMPointReadOnly {
        return self._primary_light_direction;
    }

    pub fn getPrimaryLightIntensity(self: *const XRLightEstimate) *DOMPointReadOnly {
        return self._primary_light_intensity;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRLightEstimate);

        pub const Meta = struct {
            pub const name = "XRLightEstimate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const sphericalHarmonicsCoefficients = bridge.accessor(
            XRLightEstimate.getSphericalHarmonicsCoefficients,
            null,
            .{},
        );
        pub const primaryLightDirection = bridge.accessor(
            XRLightEstimate.getPrimaryLightDirection,
            null,
            .{},
        );
        pub const primaryLightIntensity = bridge.accessor(
            XRLightEstimate.getPrimaryLightIntensity,
            null,
            .{},
        );
    };
};

/// The handle `requestLightProbe` would return, and the one EventTarget in
/// this file.
pub const XRLightProbe = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _probe_space: *XRSpace,

    pub fn asEventTarget(self: *XRLightProbe) *EventTarget {
        return self._proto;
    }

    pub fn getProbeSpace(self: *const XRLightProbe) *XRSpace {
        return self._probe_space;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRLightProbe);

        pub const Meta = struct {
            pub const name = "XRLightProbe";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        pub const probeSpace = bridge.accessor(XRLightProbe.getProbeSpace, null, .{});
        pub const onreflectionchange = bridge.accessor(handlerProperty(XRLightProbe, .onreflectionchange).get, handlerProperty(XRLightProbe, .onreflectionchange).set, .{});
    };
};

/// The base of the two depth buffers. `depth-sensing` is refused by every
/// session here, so neither it nor its two subclasses is ever produced.
pub const XRDepthInformation = struct {
    _width: u32 = 0,
    _height: u32 = 0,
    _norm_depth_buffer_from_norm_view: *XRRigidTransform,
    _raw_value_to_meters: f64 = 0,
    _projection_matrix: Float32Array.Global,
    _transform: *XRRigidTransform,

    pub fn getWidth(self: *const XRDepthInformation) u32 {
        return self._width;
    }

    pub fn getHeight(self: *const XRDepthInformation) u32 {
        return self._height;
    }

    pub fn getNormDepthBufferFromNormView(self: *const XRDepthInformation) *XRRigidTransform {
        return self._norm_depth_buffer_from_norm_view;
    }

    pub fn getRawValueToMeters(self: *const XRDepthInformation) f64 {
        return self._raw_value_to_meters;
    }

    pub fn getProjectionMatrix(self: *const XRDepthInformation) Float32Array.Global {
        return self._projection_matrix;
    }

    pub fn getTransform(self: *const XRDepthInformation) *XRRigidTransform {
        return self._transform;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRDepthInformation);

        pub const Meta = struct {
            pub const name = "XRDepthInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const width = bridge.accessor(XRDepthInformation.getWidth, null, .{});
        pub const height = bridge.accessor(XRDepthInformation.getHeight, null, .{});
        pub const normDepthBufferFromNormView = bridge.accessor(
            XRDepthInformation.getNormDepthBufferFromNormView,
            null,
            .{},
        );
        pub const rawValueToMeters = bridge.accessor(XRDepthInformation.getRawValueToMeters, null, .{});
        pub const projectionMatrix = bridge.accessor(XRDepthInformation.getProjectionMatrix, null, .{});
        pub const transform = bridge.accessor(XRDepthInformation.getTransform, null, .{});
    };
};

/// The CPU-readable buffer, whose `data` is an ArrayBuffer. Nothing here ever
/// has one, so the getter is null rather than a fabricated buffer.
pub const XRCPUDepthInformation = struct {
    pub const Proto = XRDepthInformation;

    _proto: *XRDepthInformation,

    pub fn asXRDepthInformation(self: *XRCPUDepthInformation) *XRDepthInformation {
        return self._proto;
    }

    pub fn getData(_: *const XRCPUDepthInformation) ?js.Object {
        return null;
    }

    pub fn getDepthInMeters(_: *const XRCPUDepthInformation, _: ?f64, _: ?f64) f64 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCPUDepthInformation);

        pub const Meta = struct {
            pub const name = "XRCPUDepthInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRDepthInformation;

        pub const data = bridge.accessor(XRCPUDepthInformation.getData, null, .{});
        pub const getDepthInMeters = bridge.function(
            XRCPUDepthInformation.getDepthInMeters,
            .{ .arity = 2 },
        );
    };
};

/// The GPU-side buffer, handed to a page as a WebGLTexture.
pub const XRWebGLDepthInformation = struct {
    pub const Proto = XRDepthInformation;

    _proto: *XRDepthInformation,
    _texture: ?*WebGLTexture = null,

    pub fn asXRDepthInformation(self: *XRWebGLDepthInformation) *XRDepthInformation {
        return self._proto;
    }

    pub fn getTexture(self: *const XRWebGLDepthInformation) ?*WebGLTexture {
        return self._texture;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRWebGLDepthInformation);

        pub const Meta = struct {
            pub const name = "XRWebGLDepthInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = XRDepthInformation;

        pub const texture = bridge.accessor(XRWebGLDepthInformation.getTexture, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: WebXR features" {
    try testing.htmlRunner("webxr/features.html", .{});
}
