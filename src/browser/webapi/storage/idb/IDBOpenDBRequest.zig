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

// https://developer.mozilla.org/en-US/docs/Web/API/IDBOpenDBRequest
//
// What `indexedDB.open()` and `indexedDB.deleteDatabase()` return -- an
// IDBRequest with two more event-handler attributes on it. Everything else
// (result, error, source, transaction, readyState, onsuccess, onerror) comes
// from the parent, which is where `onupgradeneeded` used to live here too: the
// engine put it on IDBRequest, so every store `get()` carried an attribute
// Chrome only gives to an open. Measured on a headed Chrome 150 (probe-win36):
// IDBOpenDBRequest.prototype owns exactly `onblocked` and `onupgradeneeded`.
//
// `blocked` itself never fires here. It needs a second live connection holding
// the database at an older version while an upgrade waits on it, and the
// engine serialises opens through one connection gate, so there is never
// anything to block on.

const js = @import("../../../js/js.zig");

const idb = @import("idb.zig");
const IDBRequest = @import("IDBRequest.zig");

const FunctionSetter = idb.FunctionSetter;

const Execution = js.Execution;

const IDBOpenDBRequest = @This();

pub const Proto = IDBRequest;

_proto: *IDBRequest,
_on_blocked: ?js.Function.Global = null,

pub fn init(exec: *Execution) !*IDBOpenDBRequest {
    return exec._factory.idbOpenRequest(IDBOpenDBRequest{ ._proto = undefined });
}

pub fn asRequest(self: *IDBOpenDBRequest) *IDBRequest {
    return self._proto;
}

pub fn asEventTarget(self: *IDBOpenDBRequest) *@import("../../EventTarget.zig") {
    return self._proto.asEventTarget();
}

/// The wrapper pins forward to the request, which forwards them to its
/// transaction when it has one. An open request never does.
pub fn acquireRef(self: *IDBOpenDBRequest) void {
    self._proto.acquireRef();
}

pub fn releaseRef(self: *IDBOpenDBRequest, page: *@import("../../../Page.zig")) void {
    self._proto.releaseRef(page);
}

pub fn getOnBlocked(self: *const IDBOpenDBRequest) ?js.Function.Global {
    return self._on_blocked;
}

pub fn setOnBlocked(self: *IDBOpenDBRequest, setter: ?FunctionSetter) void {
    self._on_blocked = idb.functionFromSetter(setter);
}

pub fn getOnUpgradeNeeded(self: *const IDBOpenDBRequest) ?js.Function.Global {
    return self._proto.getOnUpgradeNeeded();
}

pub fn setOnUpgradeNeeded(self: *IDBOpenDBRequest, setter: ?FunctionSetter) void {
    self._proto.setOnUpgradeNeeded(setter);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBOpenDBRequest);

    pub const Meta = struct {
        pub const name = "IDBOpenDBRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onblocked = bridge.accessor(IDBOpenDBRequest.getOnBlocked, IDBOpenDBRequest.setOnBlocked, .{});
    pub const onupgradeneeded = bridge.accessor(
        IDBOpenDBRequest.getOnUpgradeNeeded,
        IDBOpenDBRequest.setOnUpgradeNeeded,
        .{},
    );
};
