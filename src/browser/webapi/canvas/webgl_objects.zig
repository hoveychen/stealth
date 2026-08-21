// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! The opaque handles WebGL's `create*` calls hand back. We keep no GPU state,
//! so these carry no data — but they have to be distinct types, because
//! `Object.prototype.toString.call(gl.createTexture())` is a value a
//! fingerprinting script reads, and because a consumer that stores them in a
//! Map keyed by identity needs each call to produce a fresh object.
//!
//! Eleven of them hang off a `WebGLObject` base interface, the way Chrome's do:
//! `Object.getPrototypeOf(WebGLBuffer.prototype) === WebGLObject.prototype` and
//! `gl.createBuffer() instanceof WebGLObject`. The three that do not are the
//! ones that are not GPU objects at all -- a uniform location, an active-info
//! record and a precision-format record -- and Chrome roots those on Object too
//! (all measured, probe-s7-misc). The base costs one empty struct per handle in
//! the chained allocation, which buys the prototype link a detector walks.

const js = @import("../../js/js.zig");
const Precision = @import("gpu.zig").Precision;

pub fn registerTypes() []const type {
    return &.{
        WebGLObject,
        WebGLBuffer,
        WebGLFramebuffer,
        WebGLProgram,
        WebGLQuery,
        WebGLRenderbuffer,
        WebGLSampler,
        WebGLShader,
        WebGLSync,
        WebGLTexture,
        WebGLTransformFeedback,
        WebGLVertexArrayObject,
        WebGLUniformLocation,
        WebGLActiveInfo,
        WebGLShaderPrecisionFormat,
    };
}

/// The prototype root the GPU handles share. Abstract in WebIDL and abstract
/// here: no members at all, an illegal constructor, and never instantiated on
/// its own.
pub const WebGLObject = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLObject);

        pub const Meta = struct {
            pub const name = "WebGLObject";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
    };
};

/// Builds one of the GPU handle types: a member-less struct on WebGLObject. The
/// `_` field is what gives each instance its own allocation, and therefore its
/// own JS identity.
fn Handle(comptime js_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = WebGLObject;

        _proto: *WebGLObject,
        _: u8 = 0,

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = js_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };
        };
    };
}

/// The same, for a handle Chrome roots on Object rather than on WebGLObject.
fn PlainHandle(comptime js_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        _: u8 = 0,

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = js_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };
        };
    };
}

/// Allocates a handle with its WebGLObject base, since a `create*` call site
/// cannot use the plain factory once the type has a prototype.
pub fn handle(comptime T: type, exec: *const js.Execution) !*T {
    return exec._factory.chained(.{ WebGLObject{}, T{ ._proto = undefined } });
}

pub const WebGLBuffer = Handle("WebGLBuffer");
pub const WebGLFramebuffer = Handle("WebGLFramebuffer");
pub const WebGLProgram = Handle("WebGLProgram");
pub const WebGLQuery = Handle("WebGLQuery");
pub const WebGLRenderbuffer = Handle("WebGLRenderbuffer");
pub const WebGLSampler = Handle("WebGLSampler");
pub const WebGLShader = Handle("WebGLShader");
pub const WebGLSync = Handle("WebGLSync");
pub const WebGLTexture = Handle("WebGLTexture");
pub const WebGLTransformFeedback = Handle("WebGLTransformFeedback");
pub const WebGLVertexArrayObject = Handle("WebGLVertexArrayObject");
pub const WebGLUniformLocation = PlainHandle("WebGLUniformLocation");

/// Describes one active attribute or uniform of a linked program. We never link
/// anything, so `getActiveAttrib`/`getActiveUniform` answer null and this type
/// only exists so the interface is present on `window`.
pub const WebGLActiveInfo = struct {
    _size: i32 = 0,
    _type: u32 = 0,
    _name: []const u8 = "",

    pub fn getSize(self: *const WebGLActiveInfo) i32 {
        return self._size;
    }

    pub fn getType(self: *const WebGLActiveInfo) u32 {
        return self._type;
    }

    pub fn getName(self: *const WebGLActiveInfo) []const u8 {
        return self._name;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLActiveInfo);

        pub const Meta = struct {
            pub const name = "WebGLActiveInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const size = bridge.accessor(WebGLActiveInfo.getSize, null, .{});
        pub const @"type" = bridge.accessor(WebGLActiveInfo.getType, null, .{});
        pub const name = bridge.accessor(WebGLActiveInfo.getName, null, .{});
    };
};

/// The numeric range and precision of a shader's float/int types. The same in
/// both shader stages on every driver measured, and different between lowp,
/// mediump and highp on some of them — so the six triples come from the
/// per-platform table rather than from here.
pub const WebGLShaderPrecisionFormat = struct {
    _range_min: i32,
    _range_max: i32,
    _precision: i32,

    /// What a precision is worth belongs to the driver, not to this object:
    /// Metal answers the highp triple for lowp and mediump too, SwiftShader does
    /// not. The table is `canvas/gpu.zig`.
    pub fn from(p: Precision) WebGLShaderPrecisionFormat {
        return .{ ._range_min = p.range_min, ._range_max = p.range_max, ._precision = p.precision };
    }

    pub fn getRangeMin(self: *const WebGLShaderPrecisionFormat) i32 {
        return self._range_min;
    }

    pub fn getRangeMax(self: *const WebGLShaderPrecisionFormat) i32 {
        return self._range_max;
    }

    pub fn getPrecision(self: *const WebGLShaderPrecisionFormat) i32 {
        return self._precision;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLShaderPrecisionFormat);

        pub const Meta = struct {
            pub const name = "WebGLShaderPrecisionFormat";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const rangeMin = bridge.accessor(WebGLShaderPrecisionFormat.getRangeMin, null, .{});
        pub const rangeMax = bridge.accessor(WebGLShaderPrecisionFormat.getRangeMax, null, .{});
        pub const precision = bridge.accessor(WebGLShaderPrecisionFormat.getPrecision, null, .{});
    };
};
