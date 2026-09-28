// Copyright (C) 2023-2025 Lightpanda (Selecy SAS)
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

//! navigator.permissions.
//!
//! query() is a table lookup, not a constant. Answering 'prompt' for any name
//! at all -- which is what this used to do -- means answering 'prompt' for
//! names no browser has ever heard of, and Chrome rejects those. The table, the
//! default states, every message and the odd bits below were measured on a
//! headed Chrome 150 over http://localhost
//! (tools/fingerprint/probes/probe-perm1.js and probe-perm2.js,
//! with perm1-chrome.json). The four entries marked below were added against
//! Chrome 151.0.7922.172 -- the enum grows between releases, and a name the
//! reference answers that we call invalid is a reading a guard gets for free.
//!
//! Two things worth knowing before reading the table:
//!
//!   * PermissionStatus.name is NOT the name that was queried. It is Blink's
//!     own PermissionName enum spelling, which is snake_case and sometimes a
//!     different word entirely: 'camera' answers 'video_capture', all three
//!     motion sensors answer 'sensors', and 'push' answers 'notifications'.
//!   * Every failure is a rejection. Not one of them throws synchronously.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const URL = @import("../URL.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const permissions_policy = @import("../permissions_policy.zig");
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
    return &.{ Permissions, PermissionStatus };
}

pub const State = enum {
    granted,
    prompt,
    denied,
};

const Permissions = @This();

// Padding to avoid zero-size struct pointer collisions
_pad: bool = false,

const PREFIX = "Failed to execute 'query' on 'Permissions': ";
const DESCRIPTOR = PREFIX ++ "Failed to read the 'name' property from 'PermissionDescriptor': ";

// What a valid PermissionName answers with. `plain` resolves; `disabled` is a
// name Chrome knows but whose feature is off, and always rejects with its own
// wording; `gated` needs a dictionary member set before it will answer.
const Answer = union(enum) {
    plain: Resolved,
    disabled: []const u8,
    gated: Gated,
};

const Resolved = struct {
    // Blink's internal enum spelling, which is what PermissionStatus.name reads.
    status_name: []const u8,
    state: State,
};

const Gated = struct {
    // The dictionary member that has to be there, and what happens without it.
    member: []const u8,
    // A URL-valued member (top-level-storage-access) rather than a boolean one.
    origin: bool = false,
    // NotSupportedError rather than TypeError; only 'push' does this.
    not_supported: bool = false,
    message: []const u8,
    ok: Resolved,
};

// Chrome 150's whole PermissionName enum, with the state each one reports on a
// secure top-level context. Anything not in here is not a valid enum value.
const TABLE = std.StaticStringMap(Answer).initComptime(.{
    .{ "geolocation", Answer{ .plain = .{ .status_name = "geolocation", .state = .prompt } } },
    .{ "notifications", Answer{ .plain = .{ .status_name = "notifications", .state = .prompt } } },
    .{ "midi", Answer{ .plain = .{ .status_name = "midi", .state = .prompt } } },
    .{ "camera", Answer{ .plain = .{ .status_name = "video_capture", .state = .prompt } } },
    .{ "microphone", Answer{ .plain = .{ .status_name = "audio_capture", .state = .prompt } } },
    .{ "background-fetch", Answer{ .plain = .{ .status_name = "background_fetch", .state = .granted } } },
    .{ "background-sync", Answer{ .plain = .{ .status_name = "background_sync", .state = .granted } } },
    .{ "persistent-storage", Answer{ .plain = .{ .status_name = "durable_storage", .state = .prompt } } },
    .{ "accelerometer", Answer{ .plain = .{ .status_name = "sensors", .state = .granted } } },
    .{ "gyroscope", Answer{ .plain = .{ .status_name = "sensors", .state = .granted } } },
    .{ "magnetometer", Answer{ .plain = .{ .status_name = "sensors", .state = .granted } } },
    .{ "clipboard-read", Answer{ .plain = .{ .status_name = "clipboard_read", .state = .prompt } } },
    .{ "clipboard-write", Answer{ .plain = .{ .status_name = "clipboard_write", .state = .granted } } },
    .{ "display-capture", Answer{ .plain = .{ .status_name = "display_capture", .state = .prompt } } },
    .{ "screen-wake-lock", Answer{ .plain = .{ .status_name = "screen_wake_lock", .state = .granted } } },
    .{ "payment-handler", Answer{ .plain = .{ .status_name = "payment_handler", .state = .granted } } },
    .{ "periodic-background-sync", Answer{ .plain = .{ .status_name = "periodic_background_sync", .state = .denied } } },
    .{ "storage-access", Answer{ .plain = .{ .status_name = "storage-access", .state = .granted } } },
    .{ "window-management", Answer{ .plain = .{ .status_name = "window-management", .state = .prompt } } },
    .{ "local-fonts", Answer{ .plain = .{ .status_name = "local_fonts", .state = .prompt } } },
    .{ "captured-surface-control", Answer{ .plain = .{ .status_name = "captured-surface-control", .state = .prompt } } },
    .{ "idle-detection", Answer{ .plain = .{ .status_name = "idle_detection", .state = .prompt } } },
    .{ "pointer-lock", Answer{ .plain = .{ .status_name = "pointer-lock", .state = .granted } } },
    .{ "keyboard-lock", Answer{ .plain = .{ .status_name = "keyboard-lock", .state = .granted } } },

    // Chrome 151 additions, measured on 151.0.7922.172. All three echo the
    // queried name back rather than a Blink spelling of it.
    .{ "local-network", Answer{ .plain = .{ .status_name = "local-network", .state = .prompt } } },
    .{ "local-network-access", Answer{ .plain = .{ .status_name = "local-network-access", .state = .prompt } } },
    .{ "loopback-network", Answer{ .plain = .{ .status_name = "loopback-network", .state = .prompt } } },

    // Known to the enum, feature off. Each has its own wording.
    .{ "ambient-light-sensor", Answer{ .disabled = "GenericSensorExtraClasses flag is not enabled." } },
    .{ "nfc", Answer{ .disabled = "Web NFC is not enabled." } },
    .{ "system-wake-lock", Answer{ .disabled = "System Wake Lock is not enabled." } },
    .{ "speaker-selection", Answer{ .disabled = "The Speaker Selection API is not enabled." } },
    .{ "web-app-installation", Answer{ .disabled = "The Web App Install API is not enabled." } },
    .{ "geolocation-approximate", Answer{ .disabled = "Permission API support for approximate geolocation is not enabled." } },

    // Need a member before they answer.
    .{
        "push",
        Answer{
            .gated = .{
                .member = "userVisibleOnly",
                .not_supported = true,
                .message = "Push Permission without userVisibleOnly:true isn't supported yet.",
                // Chrome answers a push query with the notifications permission.
                .ok = .{ .status_name = "notifications", .state = .prompt },
            },
        },
    },
    .{ "fullscreen", Answer{ .gated = .{
        .member = "allowWithoutGesture",
        .message = "Fullscreen Permission only supports allowWithoutGesture:true.",
        .ok = .{ .status_name = "fullscreen", .state = .denied },
    } } },
    .{ "top-level-storage-access", Answer{ .gated = .{
        .member = "requestedOrigin",
        .origin = true,
        .message = "The requested origin is invalid.",
        .ok = .{ .status_name = "top-level-storage-access", .state = .prompt },
    } } },
});

// What a frame that did not inherit a permission's feature reports in place of
// its top-level state (Chrome 153, cross-origin iframe with no allow=,
// scratch/s115/pp). The policy-gated ones go to denied; notifications and push
// are not policy features but Chrome refuses them to any cross-origin frame
// too; background-fetch and storage-access drop from granted to prompt. The
// rest -- the sensors, payment-handler, keyboard-lock, pointer-lock,
// background-sync -- answer as they do at the top.
const Framed = struct {
    // The policy feature `allow=` would delegate, or null for "same-origin
    // with the top, full stop".
    feature: ?[]const u8,
    state: State,
};

const FRAMED = std.StaticStringMap(Framed).initComptime(.{
    .{ "geolocation", Framed{ .feature = "geolocation", .state = .denied } },
    .{ "notifications", Framed{ .feature = null, .state = .denied } },
    .{ "push", Framed{ .feature = null, .state = .denied } },
    .{ "midi", Framed{ .feature = "midi", .state = .denied } },
    .{ "camera", Framed{ .feature = "camera", .state = .denied } },
    .{ "microphone", Framed{ .feature = "microphone", .state = .denied } },
    .{ "background-fetch", Framed{ .feature = null, .state = .prompt } },
    .{ "screen-wake-lock", Framed{ .feature = "screen-wake-lock", .state = .denied } },
    .{ "display-capture", Framed{ .feature = "display-capture", .state = .denied } },
    .{ "clipboard-read", Framed{ .feature = "clipboard-read", .state = .denied } },
    .{ "clipboard-write", Framed{ .feature = "clipboard-write", .state = .denied } },
    .{ "idle-detection", Framed{ .feature = "idle-detection", .state = .denied } },
    .{ "storage-access", Framed{ .feature = null, .state = .prompt } },
    .{ "window-management", Framed{ .feature = "window-management", .state = .denied } },
    .{ "local-fonts", Framed{ .feature = "local-fonts", .state = .denied } },
    .{ "captured-surface-control", Framed{ .feature = "captured-surface-control", .state = .denied } },
    .{ "local-network-access", Framed{ .feature = "local-network-access", .state = .denied } },
});

fn framedState(name: []const u8, exec: *const Execution) ?State {
    const framed = FRAMED.get(name) orelse return null;
    const frame = switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => return null,
    };
    if (permissions_policy.inheritsSelf(frame, framed.feature)) {
        return null;
    }
    return framed.state;
}

// Every way query() can fail. They are all rejections, so they travel as a
// value rather than as a Zig error.
const Failure = union(enum) {
    type_error: []const u8,
    not_supported: []const u8,
};

pub fn query(_: *const Permissions, descriptor_: ?js.Value, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const resolved = try resolve(descriptor_, exec);
    switch (resolved) {
        .failure => |failure| switch (failure) {
            .type_error => |message| return local.rejectPromise(.{ .type_error = message }),
            .not_supported => |message| {
                // NotSupportedError with Chrome's own message, which
                // RejectError's dom_exception variant cannot carry. The message
                // has to be copied off the call arena: a DOMException keeps the
                // slice it is given, and the rejection is read after this call
                // is over.
                const dom = try exec.arena.create(DOMException);
                dom.* = DOMException.init(try exec.dupeString(message), "NotSupportedError");
                const resolver = local.createPromiseResolver();
                resolver.reject("Permissions.query", dom);
                return resolver.promise();
            },
        },
        .status => |answer| {
            const arena = try exec.getArena(.tiny, "PermissionStatus");
            errdefer arena.release();

            // The state a CDP Browser.grantPermissions / setPermission set wins
            // over the default, and is keyed by the name the script asked for.
            // A frame the feature never reached answers for itself, grant or no.
            const state = framedState(answer.queried, exec) orelse
                exec.session.browser.permissions.get(answer.queried) orelse
                answer.resolved.state;
            return local.resolvePromise(try exec._factory.eventTargetWithAllocator(
                arena.allocator(),
                PermissionStatus{
                    ._arena = arena,
                    ._proto = undefined,
                    ._state = state,
                    ._name = answer.resolved.status_name,
                },
            ));
        },
    }
}

const Outcome = union(enum) {
    failure: Failure,
    status: struct { queried: []const u8, resolved: Resolved },
};

fn resolve(descriptor_: ?js.Value, exec: *const Execution) !Outcome {
    const descriptor = descriptor_ orelse return .{ .failure = .{
        .type_error = PREFIX ++ "1 argument required, but only 0 present.",
    } };
    // null and a primitive are both "not an object"; an array is an object, and
    // gets as far as the missing member (measured).
    if (!descriptor.isObject()) {
        return .{ .failure = .{ .type_error = PREFIX ++ "parameter 1 is not of type 'object'." } };
    }
    const object = descriptor.toObject();

    const name_value = try object.get("name");
    if (name_value.isUndefined()) {
        return .{ .failure = .{ .type_error = DESCRIPTOR ++ "Required member is undefined." } };
    }
    // WebIDL stringifies before the enum check, so `{name: null}` complains
    // about 'null' and `{name: 1}` about '1'.
    const name = try name_value.toStringSlice();

    const answer = TABLE.get(name) orelse return .{ .failure = .{
        .type_error = try enumMessage(name, exec),
    } };

    switch (answer) {
        .plain => |resolved| return .{ .status = .{ .queried = name, .resolved = resolved } },
        .disabled => |message| return .{ .failure = .{ .type_error = try prefixed(message, exec) } },
        .gated => |gated| {
            const member = try object.get(gated.member);
            const satisfied = if (gated.origin)
                !member.isUndefined() and URL.canParse(try member.toStringSlice(), null)
            else
                member.isTrue();
            if (!satisfied) {
                const message = try prefixed(gated.message, exec);
                return .{ .failure = if (gated.not_supported)
                    .{ .not_supported = message }
                else
                    .{ .type_error = message } };
            }
            return .{ .status = .{ .queried = name, .resolved = gated.ok } };
        },
    }
}

fn prefixed(message: []const u8, exec: *const Execution) ![]const u8 {
    return std.fmt.allocPrint(exec.call_arena, PREFIX ++ "{s}", .{message});
}

fn enumMessage(name: []const u8, exec: *const Execution) ![]const u8 {
    return std.fmt.allocPrint(
        exec.call_arena,
        DESCRIPTOR ++ "The provided value '{s}' is not a valid enum value of type PermissionName.",
        .{name},
    );
}

/// An EventTarget, because a permission's state can change under a page and
/// `onchange` is where Chrome reports it. Nothing changes it here -- only CDP
/// can move a permission, and it does so between navigations -- so the handler
/// is a slot that reads back what was assigned and never fires.
pub const PermissionStatus = struct {
    pub const Proto = EventTarget;

    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _proto: *EventTarget,
    _name: []const u8,
    _state: State,

    pub fn asEventTarget(self: *PermissionStatus) *EventTarget {
        return self._proto;
    }

    pub fn deinit(self: *PermissionStatus, _: *Page) void {
        self._arena.release();
    }

    pub fn releaseRef(self: *PermissionStatus, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *PermissionStatus) void {
        self._rc.acquire();
    }

    fn getName(self: *const PermissionStatus) []const u8 {
        return self._name;
    }

    fn getState(self: *const PermissionStatus) []const u8 {
        return @tagName(self._state);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PermissionStatus);
        pub const Meta = struct {
            pub const name = "PermissionStatus";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        pub const name = bridge.accessor(getName, null, .{});
        pub const state = bridge.accessor(getState, null, .{});
        pub const onchange = bridge.accessor(handlerProperty(PermissionStatus, .onchange).get, handlerProperty(PermissionStatus, .onchange).set, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Permissions);

    pub const Meta = struct {
        pub const name = "Permissions";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const query = bridge.function(Permissions.query, .{ .arity = 1 });
};
