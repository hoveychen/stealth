// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");
const file_system_access = @import("file_system_access.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{StorageManager};
}

const StorageManager = @This();

_pad: bool = false,

// The size of the origin's storage pool, reported by every surface that
// reports one. Chrome derives it from free disk; the reference headed Linux
// Chrome 151 answered 10 GiB from navigator.storage.estimate(), from
// webkitTemporaryStorage and from webkitPersistentStorage alike (measured).
//
// The number matters beyond looking plausible. The private-window probe every
// detector library ships reads this quota and calls the browser incognito when
// it comes back under twice performance.memory.jsHeapSizeLimit — so a quota
// picked small enough reports the engine as an incognito window. browserscan
// docked us 10% for exactly that.
// f64 rather than u64: past 2^32 a u64 marshals as a BigInt, and Chrome
// reports a plain Number — JSON.stringify() throws on the BigInt, which would
// trade one tell for a louder one.
pub const quota_bytes: f64 = 10 * 1024 * 1024 * 1024;

// Chrome resolves estimate() with a plain dictionary, not an interface object:
// its three keys are own properties, so JSON.stringify() of the result carries
// the values. Handing back a class instance with the values on a prototype
// stringifies to "{}", which is the same tell by another route (measured).
const StorageEstimate = struct {
    quota: f64 = quota_bytes,
    usage: f64 = 0,
    usageDetails: struct {} = .{},
};

pub fn estimate(_: *const StorageManager, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(StorageEstimate{});
}

// The origin private file system's root. This used to be the only member of
// navigator.storage that was missing, and Turnstile's blob worker
// feature-detects it before it posts its OPFS probe -- so its absence removed a
// whole field from the telemetry rather than getting it wrong. See
// file_system_access.zig.
pub fn getDirectory(_: *const StorageManager, exec: *const Execution) !js.Promise {
    return file_system_access.getDirectory(exec);
}

// persist()/persisted() are not here: this engine has never claimed either, and
// nothing measured asks. getDirectory is the one that was asked for.

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageManager);
    pub const Meta = struct {
        pub const name = "StorageManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const estimate = bridge.function(StorageManager.estimate, .{});
    pub const getDirectory = bridge.function(StorageManager.getDirectory, .{});
};
