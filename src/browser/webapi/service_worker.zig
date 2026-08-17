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

//! Everything that hangs off a ServiceWorkerRegistration: the worker itself, the
//! registration, and the six managers reached through it (push, background
//! fetch, background sync, periodic sync, navigation preload, cookie change).
//!
//! Not one of these is reachable from script here. `navigator.serviceWorker` is
//! already implemented (webapi/navigator/devices.zig) and answers the way Chrome
//! answers when nothing is registered: `register()` rejects, `getRegistration()`
//! resolves undefined, and `ready` is a promise that never settles — which is
//! what Chrome's own `ready` does while no worker controls the page (measured).
//! So no registration object ever exists to walk, and shape is the entire
//! observable surface: twelve constructors CreepJS counts as missing globals, and
//! twelve prototypes browserleaks walks.
//!
//! Shapes measured on a headed Chrome 150 over http://localhost
//! (win20-chrome.json); `PushManager.supportedContentEncodings` is the one live
//! value in the file (measured: a frozen ["aes128gcm", "aesgcm"]).
//!
//! Two known deviations, both the V8 `constructor`-position limitation from
//! earlier batches: Blink puts `onerror` after `constructor` on ServiceWorker,
//! and six runtime-enabled members after it on ServiceWorkerRegistration
//! (backgroundFetch, periodicSync, sync, cookies, pushManager,
//! getNotifications/showNotification). V8 can only append `constructor` last.

const js = @import("../js/js.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const handler_property = @import("handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        ServiceWorker,
        ServiceWorkerRegistration,
        PushManager,
        PushSubscription,
        PushSubscriptionOptions,
        BackgroundFetchManager,
        BackgroundFetchRecord,
        BackgroundFetchRegistration,
        SyncManager,
        PeriodicSyncManager,
        NavigationPreloadManager,
        CookieStoreManager,
    };
}

// Every operation on these objects would need a registration behind it. Chrome's
// own answer for an operation against a registration that is gone is an
// InvalidStateError, which is the state this engine is permanently in.
fn noRegistration(exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("service_worker", DOMException.init(
        "Failed to execute operation: no active registration",
        "InvalidStateError",
    ));
    return resolver.promise();
}

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

pub const ServiceWorker = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *ServiceWorker) *EventTarget {
        return self._proto;
    }

    fn scriptURL(_: *const ServiceWorker) []const u8 {
        return "";
    }

    fn state(_: *const ServiceWorker) []const u8 {
        return "redundant";
    }

    fn postMessage(_: *ServiceWorker, _: ?js.Value, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ServiceWorker);

        pub const Meta = struct {
            pub const name = "ServiceWorker";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const W = ServiceWorker;

        pub const scriptURL = bridge.accessor(W.scriptURL, null, .{});
        pub const state = bridge.accessor(W.state, null, .{});
        pub const onstatechange = bridge.accessor(handlerProperty(ServiceWorker, .onstatechange).get, handlerProperty(ServiceWorker, .onstatechange).set, .{});
        pub const postMessage = bridge.function(W.postMessage, .{ .arity = 1 });
        pub const onerror = bridge.accessor(handlerProperty(ServiceWorker, .onerror).get, handlerProperty(ServiceWorker, .onerror).set, .{});
    };
};

pub const ServiceWorkerRegistration = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *ServiceWorkerRegistration) *EventTarget {
        return self._proto;
    }

    fn worker(_: *const ServiceWorkerRegistration) ?*ServiceWorker {
        return null;
    }

    fn scope(_: *const ServiceWorkerRegistration) []const u8 {
        return "";
    }

    fn updateViaCache(_: *const ServiceWorkerRegistration) []const u8 {
        return "imports";
    }

    fn refuse(_: *ServiceWorkerRegistration, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn refuse1(_: *ServiceWorkerRegistration, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn navigationPreload(_: *const ServiceWorkerRegistration) ?*NavigationPreloadManager {
        return null;
    }

    fn paymentManager(_: *const ServiceWorkerRegistration) ?*@import("payment.zig").PaymentManager {
        return null;
    }

    fn backgroundFetch(_: *const ServiceWorkerRegistration) ?*BackgroundFetchManager {
        return null;
    }

    fn periodicSync(_: *const ServiceWorkerRegistration) ?*PeriodicSyncManager {
        return null;
    }

    fn sync(_: *const ServiceWorkerRegistration) ?*SyncManager {
        return null;
    }

    fn cookies(_: *const ServiceWorkerRegistration) ?*CookieStoreManager {
        return null;
    }

    fn pushManager(_: *const ServiceWorkerRegistration) ?*PushManager {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ServiceWorkerRegistration);

        pub const Meta = struct {
            pub const name = "ServiceWorkerRegistration";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const R = ServiceWorkerRegistration;

        pub const installing = bridge.accessor(R.worker, null, .{});
        pub const waiting = bridge.accessor(R.worker, null, .{});
        pub const active = bridge.accessor(R.worker, null, .{});
        pub const navigationPreload = bridge.accessor(R.navigationPreload, null, .{});
        pub const scope = bridge.accessor(R.scope, null, .{});
        pub const updateViaCache = bridge.accessor(R.updateViaCache, null, .{});
        pub const onupdatefound = bridge.accessor(handlerProperty(ServiceWorkerRegistration, .onupdatefound).get, handlerProperty(ServiceWorkerRegistration, .onupdatefound).set, .{});
        pub const unregister = bridge.function(R.refuse, .{});
        pub const update = bridge.function(R.refuse, .{});
        pub const paymentManager = bridge.accessor(R.paymentManager, null, .{});
        pub const backgroundFetch = bridge.accessor(R.backgroundFetch, null, .{});
        pub const periodicSync = bridge.accessor(R.periodicSync, null, .{});
        pub const sync = bridge.accessor(R.sync, null, .{});
        pub const cookies = bridge.accessor(R.cookies, null, .{});
        pub const pushManager = bridge.accessor(R.pushManager, null, .{});
        pub const getNotifications = bridge.function(R.refuse1, .{ .arity = 0 });
        pub const showNotification = bridge.function(R.refuse1, .{ .arity = 1 });
    };
};

pub const PushManager = struct {
    _pad: bool = false,

    fn refuse(_: *PushManager, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn refuse1(_: *PushManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    // A frozen two-element list, in Chrome's own order (measured).
    fn supportedContentEncodings(_: *const Execution) []const []const u8 {
        return &.{ "aes128gcm", "aesgcm" };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PushManager);

        pub const Meta = struct {
            pub const name = "PushManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const M = PushManager;

        pub const getSubscription = bridge.function(M.refuse, .{});
        pub const permissionState = bridge.function(M.refuse1, .{ .arity = 0 });
        pub const subscribe = bridge.function(M.refuse1, .{ .arity = 0 });
        pub const supportedContentEncodings = bridge.accessor(M.supportedContentEncodings, null, .{ .static = true });
    };
};

pub const PushSubscription = struct {
    _pad: bool = false,

    fn endpoint(_: *const PushSubscription) []const u8 {
        return "";
    }

    fn expirationTime(_: *const PushSubscription) ?f64 {
        return null;
    }

    fn options(_: *const PushSubscription) ?*PushSubscriptionOptions {
        return null;
    }

    fn getKey(_: *const PushSubscription, _: ?js.Value) ?[]const u8 {
        return null;
    }

    fn toJSON(_: *const PushSubscription) struct {} {
        return .{};
    }

    fn unsubscribe(_: *PushSubscription, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PushSubscription);

        pub const Meta = struct {
            pub const name = "PushSubscription";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const S = PushSubscription;

        pub const endpoint = bridge.accessor(S.endpoint, null, .{});
        pub const expirationTime = bridge.accessor(S.expirationTime, null, .{});
        pub const options = bridge.accessor(S.options, null, .{});
        pub const getKey = bridge.function(S.getKey, .{ .arity = 1 });
        pub const toJSON = bridge.function(S.toJSON, .{});
        pub const unsubscribe = bridge.function(S.unsubscribe, .{});
    };
};

pub const PushSubscriptionOptions = struct {
    _pad: bool = false,

    fn userVisibleOnly(_: *const PushSubscriptionOptions) bool {
        return false;
    }

    fn applicationServerKey(_: *const PushSubscriptionOptions) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PushSubscriptionOptions);

        pub const Meta = struct {
            pub const name = "PushSubscriptionOptions";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const userVisibleOnly = bridge.accessor(PushSubscriptionOptions.userVisibleOnly, null, .{});
        pub const applicationServerKey = bridge.accessor(PushSubscriptionOptions.applicationServerKey, null, .{});
    };
};

pub const BackgroundFetchManager = struct {
    _pad: bool = false,

    fn fetch(_: *BackgroundFetchManager, _: ?js.Value, _: ?js.Value, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn get(_: *BackgroundFetchManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn getIds(_: *BackgroundFetchManager, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BackgroundFetchManager);

        pub const Meta = struct {
            pub const name = "BackgroundFetchManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const M = BackgroundFetchManager;

        pub const fetch = bridge.function(M.fetch, .{ .arity = 2 });
        pub const get = bridge.function(M.get, .{ .arity = 1 });
        pub const getIds = bridge.function(M.getIds, .{});
    };
};

pub const BackgroundFetchRecord = struct {
    _pad: bool = false,

    fn request(_: *const BackgroundFetchRecord) ?[]const u8 {
        return null;
    }

    fn responseReady(_: *BackgroundFetchRecord, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BackgroundFetchRecord);

        pub const Meta = struct {
            pub const name = "BackgroundFetchRecord";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const request = bridge.accessor(BackgroundFetchRecord.request, null, .{});
        pub const responseReady = bridge.accessor(BackgroundFetchRecord.responseReady, null, .{});
    };
};

pub const BackgroundFetchRegistration = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *BackgroundFetchRegistration) *EventTarget {
        return self._proto;
    }

    fn id(_: *const BackgroundFetchRegistration) []const u8 {
        return "";
    }

    fn zero(_: *const BackgroundFetchRegistration) u64 {
        return 0;
    }

    fn result(_: *const BackgroundFetchRegistration) []const u8 {
        return "";
    }

    fn failureReason(_: *const BackgroundFetchRegistration) []const u8 {
        return "";
    }

    fn recordsAvailable(_: *const BackgroundFetchRegistration) bool {
        return false;
    }

    fn abort(_: *BackgroundFetchRegistration, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn match(_: *BackgroundFetchRegistration, _: ?js.Value, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BackgroundFetchRegistration);

        pub const Meta = struct {
            pub const name = "BackgroundFetchRegistration";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const R = BackgroundFetchRegistration;

        pub const id = bridge.accessor(R.id, null, .{});
        pub const uploadTotal = bridge.accessor(R.zero, null, .{});
        pub const uploaded = bridge.accessor(R.zero, null, .{});
        pub const downloadTotal = bridge.accessor(R.zero, null, .{});
        pub const downloaded = bridge.accessor(R.zero, null, .{});
        pub const result = bridge.accessor(R.result, null, .{});
        pub const failureReason = bridge.accessor(R.failureReason, null, .{});
        pub const recordsAvailable = bridge.accessor(R.recordsAvailable, null, .{});
        pub const onprogress = bridge.accessor(handlerProperty(BackgroundFetchRegistration, .onprogress).get, handlerProperty(BackgroundFetchRegistration, .onprogress).set, .{});
        pub const abort = bridge.function(R.abort, .{});
        pub const match = bridge.function(R.match, .{ .arity = 1 });
        pub const matchAll = bridge.function(R.match, .{ .arity = 0 });
    };
};

pub const SyncManager = struct {
    _pad: bool = false,

    fn getTags(_: *SyncManager, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn register(_: *SyncManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SyncManager);

        pub const Meta = struct {
            pub const name = "SyncManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const getTags = bridge.function(SyncManager.getTags, .{});
        pub const register = bridge.function(SyncManager.register, .{ .arity = 1 });
    };
};

pub const PeriodicSyncManager = struct {
    _pad: bool = false,

    fn getTags(_: *PeriodicSyncManager, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn register(_: *PeriodicSyncManager, _: ?js.Value, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn unregister(_: *PeriodicSyncManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PeriodicSyncManager);

        pub const Meta = struct {
            pub const name = "PeriodicSyncManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const M = PeriodicSyncManager;

        pub const getTags = bridge.function(M.getTags, .{});
        pub const register = bridge.function(M.register, .{ .arity = 1 });
        pub const unregister = bridge.function(M.unregister, .{ .arity = 1 });
    };
};

pub const NavigationPreloadManager = struct {
    _pad: bool = false,

    fn refuse(_: *NavigationPreloadManager, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn refuse1(_: *NavigationPreloadManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigationPreloadManager);

        pub const Meta = struct {
            pub const name = "NavigationPreloadManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const M = NavigationPreloadManager;

        pub const disable = bridge.function(M.refuse, .{});
        pub const enable = bridge.function(M.refuse, .{});
        pub const getState = bridge.function(M.refuse, .{});
        pub const setHeaderValue = bridge.function(M.refuse1, .{ .arity = 1 });
    };
};

pub const CookieStoreManager = struct {
    _pad: bool = false,

    fn getSubscriptions(_: *CookieStoreManager, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    fn subscribe(_: *CookieStoreManager, _: ?js.Value, exec: *const Execution) js.Promise {
        return noRegistration(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CookieStoreManager);

        pub const Meta = struct {
            pub const name = "CookieStoreManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const M = CookieStoreManager;

        pub const getSubscriptions = bridge.function(M.getSubscriptions, .{});
        pub const subscribe = bridge.function(M.subscribe, .{ .arity = 1 });
        pub const unsubscribe = bridge.function(M.subscribe, .{ .arity = 1 });
    };
};

const testing = @import("../../testing.zig");
test "WebApi: ServiceWorkerRegistration family" {
    try testing.htmlRunner("service_worker.html", .{});
}
