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

// The screen-capture side objects: the controller a page hands to
// getDisplayMedia, the crop handle it can mint from any element, and the track
// subclass a captured tab produces. Chrome exposes all three on a plain desktop
// window whether or not anything is capturing, and the first two do real work
// before capture starts -- which is why they behave here rather than just
// existing:
//
//   * `new CaptureController()` succeeds; zoomLevel is null and
//     getSupportedZoomLevels() is an InvalidStateError until capture begins.
//   * `CropTarget.fromElement(el)` resolves with a fresh CropTarget for any
//     element, and two calls on the same element give two different objects.
//
// All of it measured on a headed Chrome 150 with no capture in flight; see
// tools/fingerprint/scratch/win-batch/probe-win31.js.

const std = @import("std");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");
const MediaStreamTrack = @import("streams.zig").MediaStreamTrack;
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
        CaptureController,
        CropTarget,
        BrowserCaptureMediaStreamTrack,
    };
}

fn throwTypeError(message: []const u8, exec: *const js.Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn throwDom(comptime name: []const u8, message: []const u8, exec: *const js.Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

fn rejectDom(comptime name: []const u8, message: []const u8, exec: *const js.Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("capture", DOMException.init(message, name));
    return resolver.promise();
}

pub const CaptureController = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    /// The focus behaviour a later getDisplayMedia would use. Chrome keeps it
    /// write-only (there is no getter) and validates the enum.
    pub const FocusBehavior = enum {
        @"focus-capturing-application",
        @"focus-captured-surface",
        @"no-focus-change",
    };

    pub fn constructor(page: *Page) !*CaptureController {
        const self = try page.factory.eventTarget(CaptureController{ ._proto = undefined });
        self._proto._type = .{ .capture_controller = self };
        return self;
    }

    pub fn asEventTarget(self: *CaptureController) *EventTarget {
        return self._proto;
    }

    /// Null until a capture is running (measured on a fresh controller).
    pub fn getZoomLevel(_: *const CaptureController) ?f64 {
        return null;
    }

    pub fn setFocusBehavior(_: *CaptureController, behavior_: ?[]const u8, exec: *const js.Execution) !void {
        const behavior = behavior_ orelse return throwTypeError(
            "Failed to execute 'setFocusBehavior' on 'CaptureController': 1 argument required, but only 0 present.",
            exec,
        );
        if (std.meta.stringToEnum(FocusBehavior, behavior) == null) {
            const message = try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to execute 'setFocusBehavior' on 'CaptureController': The provided value '{s}' is not a valid enum value of type CaptureStartFocusBehavior.",
                .{behavior},
            );
            return throwTypeError(message, exec);
        }
    }

    pub fn getSupportedZoomLevels(_: *CaptureController, exec: *const js.Execution) !void {
        return throwDom(
            "InvalidStateError",
            "Failed to execute 'getSupportedZoomLevels' on 'CaptureController': Not actively capturing.",
            exec,
        );
    }

    // The four zoom operations return a promise even with no capture in flight
    // (measured: `String(c.increaseZoomLevel())` is "[object Promise]"). They
    // reject for the same reason getSupportedZoomLevels throws.
    pub fn increaseZoomLevel(_: *CaptureController, exec: *const js.Execution) js.Promise {
        return notCapturing("increaseZoomLevel", exec);
    }

    pub fn decreaseZoomLevel(_: *CaptureController, exec: *const js.Execution) js.Promise {
        return notCapturing("decreaseZoomLevel", exec);
    }

    pub fn resetZoomLevel(_: *CaptureController, exec: *const js.Execution) js.Promise {
        return notCapturing("resetZoomLevel", exec);
    }

    pub fn forwardWheel(_: *CaptureController, _: ?js.Value, exec: *const js.Execution) js.Promise {
        return notCapturing("forwardWheel", exec);
    }

    fn notCapturing(comptime member: []const u8, exec: *const js.Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute '" ++ member ++ "' on 'CaptureController': Not actively capturing.",
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CaptureController);

        pub const Meta = struct {
            pub const name = "CaptureController";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(CaptureController.constructor, .{});

        // Chrome's own prototype order: setFocusBehavior and zoomLevel first,
        // then the zoom operations alphabetically (measured).
        pub const setFocusBehavior = bridge.function(CaptureController.setFocusBehavior, .{ .arity = 1 });
        pub const zoomLevel = bridge.accessor(CaptureController.getZoomLevel, null, .{});
        pub const onzoomlevelchange = bridge.accessor(handlerProperty(CaptureController, .onzoomlevelchange).get, handlerProperty(CaptureController, .onzoomlevelchange).set, .{});
        pub const decreaseZoomLevel = bridge.function(CaptureController.decreaseZoomLevel, .{});
        pub const forwardWheel = bridge.function(CaptureController.forwardWheel, .{ .arity = 1 });
        pub const getSupportedZoomLevels = bridge.function(CaptureController.getSupportedZoomLevels, .{});
        pub const increaseZoomLevel = bridge.function(CaptureController.increaseZoomLevel, .{});
        pub const resetZoomLevel = bridge.function(CaptureController.resetZoomLevel, .{});
    };
};

/// An opaque handle to a region of an element. It carries nothing a page can
/// read -- its prototype is empty apart from @@toStringTag -- so this is the
/// object identity and the one static that mints it.
pub const CropTarget = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer
    // collisions.
    _pad: bool = false,

    /// Measured: any element is accepted, a non-element is a TypeError, and two
    /// calls on the same element resolve to two different objects.
    pub fn fromElement(element_: ?js.Value, exec: *const js.Execution) !js.Promise {
        const value = element_ orelse return throwTypeError(
            "Failed to execute 'fromElement' on 'CropTarget': 1 argument required, but only 0 present.",
            exec,
        );
        _ = value.toZig(*Element) catch return throwTypeError(
            "Failed to execute 'fromElement' on 'CropTarget': parameter 1 is not of type 'Element'.",
            exec,
        );

        var resolver = exec.js.local.?.createPromiseResolver();
        resolver.resolve("CropTarget.fromElement", try exec.page.factory.create(CropTarget{}));
        return resolver.promise();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CropTarget);

        pub const Meta = struct {
            pub const name = "CropTarget";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const fromElement = bridge.function(CropTarget.fromElement, .{ .static = true, .arity = 1 });
    };
};

/// The track a captured tab or window produces. Nothing here captures, so no
/// instance is ever made; Chrome still exposes the interface, and a window with
/// CropTarget but without it is not a shape any Chrome has.
pub const BrowserCaptureMediaStreamTrack = struct {
    pub const Proto = MediaStreamTrack;

    _proto: *MediaStreamTrack,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BrowserCaptureMediaStreamTrack);

        pub const Meta = struct {
            pub const name = "BrowserCaptureMediaStreamTrack";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        fn unreachableMethod(_: *BrowserCaptureMediaStreamTrack, _: ?js.Value) void {}

        pub const cropTo = bridge.function(unreachableMethod, .{ .noop = true, .arity = 1 });
        pub const restrictTo = bridge.function(unreachableMethod, .{ .noop = true, .arity = 1 });
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: CaptureController" {
    try testing.htmlRunner("capture.html", .{});
}
