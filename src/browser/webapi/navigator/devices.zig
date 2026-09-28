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

// The navigator service objects that inherit from EventTarget on Chrome, plus
// WakeLock, which doesn't but hands back a sentinel that does. Measured on a
// headed Chrome 150 over http://localhost; see navigator/services.zig for why
// the origin has to be a secure one.
//
// None of the on* handlers here ever fires. They exist because they're on
// Chrome's prototype, and a page that assigns one gets it back — same as
// BatteryManager.zig, whose values are equally constant.

const std = @import("std");

const js = @import("../../js/js.zig");
const DOMException = @import("../DOMException.zig");
const DOMRect = @import("../DOMRect.zig");
const EventTarget = @import("../EventTarget.zig");
const Frame = @import("../../Frame.zig");
const handler_property = @import("../handler_property.zig");
const permissions_policy = @import("../../permissions_policy.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}
const Execution = js.Execution;

// Chrome will not open a device chooser without a user gesture, and nothing
// here ever has one. It refuses by REJECTING the promise -- throwing out of the
// call instead is itself a fingerprint, because a page that wraps the call in
// try/catch sees the difference. The wording names the interface and the
// operation; all four were measured on a headed Chrome 150 (win13b-chrome.json).
fn noUserGesture(
    comptime iface: []const u8,
    comptime operation: []const u8,
    exec: *const Execution,
) js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject(iface ++ "." ++ operation, DOMException.init(
        "Failed to execute '" ++ operation ++ "' on '" ++ iface ++ "': " ++
            "Must be handling a user gesture to show a permission request.",
        "SecurityError",
    ));
    return resolver.promise();
}

pub fn registerTypes() []const type {
    return &.{
        WindowControlsOverlay,
        Bluetooth,
        Clipboard,
        NavigatorManagedData,
        ServiceWorkerContainer,
        VirtualKeyboard,
        DevicePosture,
        HID,
        Serial,
        USB,
        XRSystem,
        WakeLock,
        WakeLockSentinel,
    };
}

// Every handler on these types is a plain slot: assign a function, read the
// same function back, and nothing ever calls it.
fn handlerAccessors(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn get(self: *T) ?js.Function.Global {
            return @field(self, field);
        }

        fn set(self: *T, listener: ?js.Function) !void {
            @field(self, field) = if (listener) |l| try l.persistWithThis(self) else null;
        }
    };
}

pub const WindowControlsOverlay = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *WindowControlsOverlay) *EventTarget {
        return self._proto;
    }

    // No window controls overlay is displayed, which is the state the reference
    // Chrome was in too: not visible, all-zero titlebar rect.
    pub fn getVisible(_: *const WindowControlsOverlay) bool {
        return false;
    }

    pub fn getTitlebarAreaRect(_: *const WindowControlsOverlay, exec: *const Execution) !*DOMRect {
        return DOMRect.create(.{}, exec._factory);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WindowControlsOverlay);

        pub const Meta = struct {
            pub const name = "WindowControlsOverlay";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const visible = bridge.accessor(WindowControlsOverlay.getVisible, null, .{});
        pub const ongeometrychange = bridge.accessor(handlerProperty(WindowControlsOverlay, .ongeometrychange).get, handlerProperty(WindowControlsOverlay, .ongeometrychange).set, .{});
        pub const getTitlebarAreaRect = bridge.function(WindowControlsOverlay.getTitlebarAreaRect, .{});
    };
};

pub const Bluetooth = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *Bluetooth) *EventTarget {
        return self._proto;
    }

    // True, like the reference Chrome. This is the same persona decision as the
    // fixed hardwareConcurrency of 8 in Navigator.zig: the machine being
    // described is an ordinary desktop, and ordinary desktops have a radio.
    // A frame without the bluetooth feature answers false (measured).
    pub fn getAvailability(_: *const Bluetooth, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(permissions_policy.execAllows(exec, "bluetooth"));
    }

    pub fn requestDevice(_: *const Bluetooth, _: ?js.Object, exec: *const Execution) js.Promise {
        return noUserGesture("Bluetooth", "requestDevice", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Bluetooth);

        pub const Meta = struct {
            pub const name = "Bluetooth";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getAvailability = bridge.function(Bluetooth.getAvailability, .{});
        pub const requestDevice = bridge.function(Bluetooth.requestDevice, .{});
    };
};

pub const Clipboard = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *Clipboard) *EventTarget {
        return self._proto;
    }

    // Measured on Chrome: an unfocused document is refused with NotAllowedError
    // ("Document is not focused."). Nothing here ever holds focus, so the
    // refusal is the honest answer as well as the matching one.
    fn notFocused(exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
    }

    pub fn read(_: *const Clipboard, _: ?js.Object, exec: *const Execution) js.Promise {
        return notFocused(exec);
    }

    pub fn readText(_: *const Clipboard, exec: *const Execution) js.Promise {
        return notFocused(exec);
    }

    // write() with nothing to write resolves even unfocused (measured).
    pub fn write(_: *const Clipboard, _: js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn writeText(_: *const Clipboard, _: []const u8, exec: *const Execution) js.Promise {
        return notFocused(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Clipboard);

        pub const Meta = struct {
            pub const name = "Clipboard";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onclipboardchange = bridge.accessor(handlerProperty(Clipboard, .onclipboardchange).get, handlerProperty(Clipboard, .onclipboardchange).set, .{});
        pub const read = bridge.function(Clipboard.read, .{});
        pub const readText = bridge.function(Clipboard.readText, .{});
        pub const write = bridge.function(Clipboard.write, .{});
        pub const writeText = bridge.function(Clipboard.writeText, .{});
    };
};

pub const NavigatorManagedData = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *NavigatorManagedData) *EventTarget {
        return self._proto;
    }

    // This is not a managed app, which is exactly what Chrome answered
    // ("Service connection error. This API is available only for managed
    // apps.").
    pub fn getManagedConfiguration(_: *const NavigatorManagedData, _: js.Value, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigatorManagedData);

        pub const Meta = struct {
            pub const name = "NavigatorManagedData";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onmanagedconfigurationchange = bridge.accessor(handlerProperty(NavigatorManagedData, .onmanagedconfigurationchange).get, handlerProperty(NavigatorManagedData, .onmanagedconfigurationchange).set, .{});
        pub const getManagedConfiguration = bridge.function(NavigatorManagedData.getManagedConfiguration, .{});
    };
};

pub const ServiceWorkerContainer = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _ready: ?js.Promise.Global = null,

    pub fn asEventTarget(self: *ServiceWorkerContainer) *EventTarget {
        return self._proto;
    }

    pub fn getController(_: *const ServiceWorkerContainer) ?bool {
        return null;
    }

    // Chrome hands back the same promise every time and it never settles while
    // no worker controls the page (measured: still pending after three
    // seconds). Nothing ever registers a worker here, so it stays pending — a
    // promise that resolves with a registration we don't have would be the
    // invention.
    pub fn getReady(self: *ServiceWorkerContainer, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (self._ready) |ready| {
            return ready.local(local);
        }
        const resolver = local.createPromiseResolver();
        const promise = resolver.promise();
        // Nobody will ever reject it; without this v8 reports it at teardown.
        promise.markAsHandled();
        self._ready = try promise.persist();
        return promise;
    }

    pub fn getRegistration(_: *const ServiceWorkerContainer, _: ?[]const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    pub fn getRegistrations(_: *const ServiceWorkerContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
    }

    // No service worker support at all, so the script can never be installed.
    // Chrome's own failure for a script it can't fetch is a TypeError
    // (measured against a 404).
    pub fn register(_: *const ServiceWorkerContainer, _: []const u8, _: ?js.Object, exec: *const Execution) js.Promise {
        return exec.js.local.?.rejectPromise(.{
            .type_error = "Failed to register a ServiceWorker: the script could not be fetched.",
        });
    }

    pub fn startMessages(_: *const ServiceWorkerContainer) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ServiceWorkerContainer);

        pub const Meta = struct {
            pub const name = "ServiceWorkerContainer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const controller = bridge.accessor(ServiceWorkerContainer.getController, null, .{});
        pub const ready = bridge.accessor(ServiceWorkerContainer.getReady, null, .{});
        pub const oncontrollerchange = bridge.accessor(handlerProperty(ServiceWorkerContainer, .oncontrollerchange).get, handlerProperty(ServiceWorkerContainer, .oncontrollerchange).set, .{});
        pub const onmessage = bridge.accessor(handlerProperty(ServiceWorkerContainer, .onmessage).get, handlerProperty(ServiceWorkerContainer, .onmessage).set, .{});
        pub const onmessageerror = bridge.accessor(handlerProperty(ServiceWorkerContainer, .onmessageerror).get, handlerProperty(ServiceWorkerContainer, .onmessageerror).set, .{});
        pub const getRegistration = bridge.function(ServiceWorkerContainer.getRegistration, .{});
        pub const getRegistrations = bridge.function(ServiceWorkerContainer.getRegistrations, .{});
        pub const register = bridge.function(ServiceWorkerContainer.register, .{});
        pub const startMessages = bridge.function(ServiceWorkerContainer.startMessages, .{});
    };
};

pub const VirtualKeyboard = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _overlays_content: bool = false,

    pub fn asEventTarget(self: *VirtualKeyboard) *EventTarget {
        return self._proto;
    }

    // No virtual keyboard is on screen, so the rect is all zeros — the same
    // rect the reference Chrome reported on a desktop.
    pub fn getBoundingRect(_: *const VirtualKeyboard, exec: *const Execution) !*DOMRect {
        return DOMRect.create(.{}, exec._factory);
    }

    pub fn getOverlaysContent(self: *const VirtualKeyboard) bool {
        return self._overlays_content;
    }

    pub fn setOverlaysContent(self: *VirtualKeyboard, value: bool) void {
        self._overlays_content = value;
    }

    pub fn hide(_: *const VirtualKeyboard) void {}

    pub fn show(_: *const VirtualKeyboard) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VirtualKeyboard);

        pub const Meta = struct {
            pub const name = "VirtualKeyboard";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const boundingRect = bridge.accessor(VirtualKeyboard.getBoundingRect, null, .{});
        pub const overlaysContent = bridge.accessor(VirtualKeyboard.getOverlaysContent, VirtualKeyboard.setOverlaysContent, .{});
        pub const ongeometrychange = bridge.accessor(handlerProperty(VirtualKeyboard, .ongeometrychange).get, handlerProperty(VirtualKeyboard, .ongeometrychange).set, .{});
        pub const hide = bridge.function(VirtualKeyboard.hide, .{});
        pub const show = bridge.function(VirtualKeyboard.show, .{});
    };
};

pub const DevicePosture = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *DevicePosture) *EventTarget {
        return self._proto;
    }

    // A desktop screen doesn't fold, so Chrome reports 'continuous' (measured).
    pub fn getType(_: *const DevicePosture) []const u8 {
        return "continuous";
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DevicePosture);

        pub const Meta = struct {
            pub const name = "DevicePosture";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(DevicePosture.getType, null, .{});
        pub const onchange = bridge.accessor(handlerProperty(DevicePosture, .onchange).get, handlerProperty(DevicePosture, .onchange).set, .{});
    };
};

// HID, Serial and USB are the same shape: a connect/disconnect handler pair, a
// list of already-paired devices (empty — nothing is paired) and a chooser that
// Chrome refuses to open outside a user gesture. All three refusals were
// measured, and all three carry the same message.
pub const HID = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *HID) *EventTarget {
        return self._proto;
    }

    pub fn getDevices(_: *const HID, exec: *const Execution) !js.Promise {
        if (policyBlocked("HID", "getDevices", "hid", exec)) |blocked| return blocked;
        return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
    }

    pub fn requestDevice(_: *const HID, _: js.Value, exec: *const Execution) js.Promise {
        return noUserGesture("HID", "requestDevice", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HID);

        pub const Meta = struct {
            pub const name = "HID";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "getDevices";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.accessor(handlerProperty(HID, .onconnect).get, handlerProperty(HID, .onconnect).set, .{});
        pub const ondisconnect = bridge.accessor(handlerProperty(HID, .ondisconnect).get, handlerProperty(HID, .ondisconnect).set, .{});
        pub const getDevices = bridge.function(HID.getDevices, .{});
        // `[Exposed=Window]` on the picker half of the three device APIs:
        // a worker sees `navigator.hid` but not `hid.requestDevice`
        // (measured in a blob worker on Chrome 151).
        pub const requestDevice = bridge.function(HID.requestDevice, .{ .exposed = .window });
    };
};

pub const Serial = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *Serial) *EventTarget {
        return self._proto;
    }

    pub fn getPorts(_: *const Serial, exec: *const Execution) !js.Promise {
        if (policyBlocked("Serial", "getPorts", "serial", exec)) |blocked| return blocked;
        return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
    }

    pub fn requestPort(_: *const Serial, _: ?js.Object, exec: *const Execution) js.Promise {
        return noUserGesture("Serial", "requestPort", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Serial);

        pub const Meta = struct {
            pub const name = "Serial";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "getPorts";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.accessor(handlerProperty(Serial, .onconnect).get, handlerProperty(Serial, .onconnect).set, .{});
        pub const ondisconnect = bridge.accessor(handlerProperty(Serial, .ondisconnect).get, handlerProperty(Serial, .ondisconnect).set, .{});
        pub const getPorts = bridge.function(Serial.getPorts, .{});
        pub const requestPort = bridge.function(Serial.requestPort, .{ .exposed = .window });
    };
};

pub const USB = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *USB) *EventTarget {
        return self._proto;
    }

    pub fn getDevices(_: *const USB, exec: *const Execution) !js.Promise {
        if (policyBlocked("USB", "getDevices", "usb", exec)) |blocked| return blocked;
        return exec.js.local.?.resolvePromise(@as([]const []const u8, &.{}));
    }

    pub fn requestDevice(_: *const USB, _: js.Value, exec: *const Execution) js.Promise {
        return noUserGesture("USB", "requestDevice", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USB);

        pub const Meta = struct {
            pub const name = "USB";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "getDevices";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.accessor(handlerProperty(USB, .onconnect).get, handlerProperty(USB, .onconnect).set, .{});
        pub const ondisconnect = bridge.accessor(handlerProperty(USB, .ondisconnect).get, handlerProperty(USB, .ondisconnect).set, .{});
        pub const getDevices = bridge.function(USB.getDevices, .{});
        pub const requestDevice = bridge.function(USB.requestDevice, .{ .exposed = .window });
    };
};

pub const XRSystem = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *XRSystem) *EventTarget {
        return self._proto;
    }

    // `inline` is supported on any machine, headset or not: a headed Chrome
    // 150 with nothing attached answers true for it and false for the two
    // immersive modes. See webxr/session.zig for the whole entry point.
    pub fn isSessionSupported(_: *const XRSystem, mode: ?[]const u8, exec: *const Execution) !js.Promise {
        if (policyBlocked("XRSystem", "isSessionSupported", "xr", exec)) |blocked| return blocked;
        return @import("../webxr/session.zig").isSessionSupported(mode, exec);
    }

    // And an inline session really is handed out -- the measurement that
    // decided the shape of the WebXR batch. The immersive modes still need a
    // user activation Chrome never grants here.
    pub fn requestSession(_: *const XRSystem, mode: ?[]const u8, options: ?js.Object, exec: *Execution) !js.Promise {
        return @import("../webxr/session.zig").requestSession(mode, options, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRSystem);

        pub const Meta = struct {
            pub const name = "XRSystem";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const ondevicechange = bridge.accessor(handlerProperty(XRSystem, .ondevicechange).get, handlerProperty(XRSystem, .ondevicechange).set, .{});
        pub const isSessionSupported = bridge.function(XRSystem.isSessionSupported, .{ .arity = 1 });
        pub const requestSession = bridge.function(XRSystem.requestSession, .{ .arity = 1 });
    };
};

// The rejection Chrome's device APIs give a frame the feature never reached.
fn policyBlocked(comptime interface: []const u8, comptime method: []const u8, comptime feature: []const u8, exec: *const Execution) ?js.Promise {
    if (permissions_policy.execAllows(exec, feature)) {
        return null;
    }
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject(interface ++ "." ++ method, DOMException.init(
        "Failed to execute '" ++ method ++ "' on '" ++ interface ++ "': Access to the feature \"" ++ feature ++ "\" is disallowed by permissions policy.",
        "SecurityError",
    ));
    return resolver.promise();
}

// WakeLock is not an EventTarget on Chrome; its sentinel is.
pub const WakeLock = struct {
    _pad: bool = false,

    pub fn request(_: *const WakeLock, wake_lock_type: ?[]const u8, exec: *const Execution) !js.Promise {
        if (!permissions_policy.execAllows(exec, "screen-wake-lock")) {
            var resolver = exec.js.local.?.createPromiseResolver();
            resolver.reject("WakeLock.request", DOMException.init(
                "Failed to execute 'request' on 'WakeLock': Access to Screen Wake Lock features is disallowed by permissions policy",
                "NotAllowedError",
            ));
            return resolver.promise();
        }
        const sentinel = try exec._factory.eventTarget(WakeLockSentinel{
            ._proto = undefined,
            ._type = if (std.mem.eql(u8, wake_lock_type orelse "screen", "system")) .system else .screen,
        });
        return exec.js.local.?.resolvePromise(sentinel);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WakeLock);

        pub const Meta = struct {
            pub const name = "WakeLock";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const request = bridge.function(WakeLock.request, .{});
    };
};

pub const WakeLockSentinel = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    _type: Kind,
    _released: bool = false,

    const Kind = enum { screen, system };

    pub fn asEventTarget(self: *WakeLockSentinel) *EventTarget {
        return self._proto;
    }

    pub fn getReleased(self: *const WakeLockSentinel) bool {
        return self._released;
    }

    pub fn getType(self: *const WakeLockSentinel) []const u8 {
        return @tagName(self._type);
    }

    // There is no screen to keep awake, so releasing only flips the flag. The
    // release event isn't dispatched: nothing here listens for one and the
    // handler slot never fires, same as the rest of this file.
    pub fn release(self: *WakeLockSentinel, exec: *const Execution) !js.Promise {
        self._released = true;
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WakeLockSentinel);

        pub const Meta = struct {
            pub const name = "WakeLockSentinel";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onrelease = bridge.accessor(handlerProperty(WakeLockSentinel, .onrelease).get, handlerProperty(WakeLockSentinel, .onrelease).set, .{});
        pub const released = bridge.accessor(WakeLockSentinel.getReleased, null, .{});
        pub const @"type" = bridge.accessor(WakeLockSentinel.getType, null, .{});
        pub const release = bridge.function(WakeLockSentinel.release, .{});
    };
};
