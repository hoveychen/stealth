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

// `navigator` inside a worker. Web IDL gives the two realms two separate
// interfaces -- Navigator and WorkerNavigator -- sharing only the NavigatorID,
// NavigatorLanguage, NavigatorOnLine, NavigatorConcurrentHardware and
// NavigatorStorage mixins, so a worker that answers `[object Navigator]` has
// said something no browser says.
//
// The brand is the small half. The large half is what a Navigator drags in with
// it: `webdriver`, `vendor`, `vendorSub`, `productSub`, `doNotTrack`,
// `cookieEnabled`, `pdfViewerEnabled`, `javaEnabled` and `maxTouchPoints` are
// all Window-only, and `navigator.webdriver` answering `false` in a worker is
// answering a question that is never asked there. Measured on a headless
// Chrome 151 blob worker (probes/expr-worker-surface.js): none of the nine
// exists.
//
// The state stays in the Navigator this wraps, so the two realms keep sharing
// one implementation of "what is the user agent" while presenting the two
// surfaces Web IDL describes.

const js = @import("../js/js.zig");

const Navigator = @import("Navigator.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const NetworkInformation = @import("NetworkInformation.zig");
const services = @import("navigator/services.zig");
const devices = @import("navigator/devices.zig");

const Execution = js.Execution;

const WorkerNavigator = @This();

_navigator: Navigator = .init,

pub fn getHardwareConcurrency(self: *const WorkerNavigator) u32 {
    return self._navigator.getHardwareConcurrency();
}

pub fn getAppCodeName(self: *const WorkerNavigator) []const u8 {
    return self._navigator.getAppCodeName();
}

pub fn getAppName(self: *const WorkerNavigator) []const u8 {
    return self._navigator.getAppName();
}

pub fn getAppVersion(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._navigator.getAppVersion(exec);
}

pub fn getPlatform(self: *const WorkerNavigator) []const u8 {
    return self._navigator.getPlatform();
}

pub fn getProduct(self: *const WorkerNavigator) []const u8 {
    return self._navigator.getProduct();
}

pub fn getUserAgent(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._navigator.getUserAgent(exec);
}

pub fn getLanguage(self: *const WorkerNavigator, exec: *const Execution) ![]const u8 {
    return self._navigator.getLanguage(exec);
}

// A fresh array per read, unlike the window's: the same-object cache there
// hangs off the frame, and a worker has none. Not a measured divergence --
// nothing here has looked at a worker's `navigator.languages`.
pub fn getLanguages(_: *const WorkerNavigator, exec: *const Execution) !js.FrozenArray([]const u8) {
    return .{ .items = try Navigator.parseLanguages(exec.call_arena, exec.session.browser.http_client.getLanguages()) };
}

pub fn getOnLine(self: *const WorkerNavigator) bool {
    return self._navigator.getOnLine();
}

pub fn getPermissions(self: *WorkerNavigator) *Permissions {
    return self._navigator.getPermissions();
}

pub fn getDeviceMemory(self: *const WorkerNavigator) f64 {
    return self._navigator.getDeviceMemory();
}

pub fn getUserAgentData(self: *WorkerNavigator) *NavigatorUAData {
    return self._navigator.getUserAgentData();
}

pub fn getStorage(self: *WorkerNavigator) *StorageManager {
    return self._navigator.getStorage();
}

// The Navigator this wraps is a field of it, not the page's -- so the service
// object cached in its slot is this realm's, created through this realm's
// Execution.
pub fn getGpu(self: *WorkerNavigator, exec: *Execution) !*services.GPU {
    return self._navigator.getGpu(exec);
}

pub fn getStorageBuckets(self: *WorkerNavigator, exec: *Execution) !*services.StorageBucketManager {
    return self._navigator.getStorageBuckets(exec);
}

// The four EventTarget-backed services a Chrome worker's navigator carries.
// They used to be missing here because the Window path builds them from a
// Frame's factory; `Navigator.deviceInRealm` builds them from the Execution's,
// which a worker realm has. The Akamai collector on macys.com reads
// `connection` inside each of its two SharedWorkers -- twice each -- so the
// absence was measurable from inside the guard, through the engine's own
// unknown_prop log.
pub fn getConnection(self: *WorkerNavigator, exec: *Execution) !*NetworkInformation {
    return self._navigator.getConnectionInRealm(exec);
}

pub fn getHid(self: *WorkerNavigator, exec: *Execution) !*devices.HID {
    return self._navigator.getHidInRealm(exec);
}

pub fn getSerial(self: *WorkerNavigator, exec: *Execution) !*devices.Serial {
    return self._navigator.getSerialInRealm(exec);
}

pub fn getUsb(self: *WorkerNavigator, exec: *Execution) !*devices.USB {
    return self._navigator.getUsbInRealm(exec);
}

// These two were already Execution-shaped on the Navigator; they only needed
// declaring here.
pub fn getMediaCapabilities(self: *WorkerNavigator, exec: *Execution) !*services.MediaCapabilities {
    return self._navigator.getMediaCapabilities(exec);
}

pub fn getLocks(self: *WorkerNavigator, exec: *Execution) !*services.LockManager {
    return self._navigator.getLocks(exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WorkerNavigator);

    pub const Meta = struct {
        pub const name = "WorkerNavigator";
        // Chrome's `constructor` sits after `connection`; everything below it
        // is installed per context. Measured in a blob worker on Chrome 151
        // (probes/expr-worker-proto-table.js) -- and read for real: the Akamai
        // interstitial on macys reads nine of these members from inside a
        // SharedWorker (results/b50-prop-reads-replay.json).
        pub const constructor_after = "connection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is Chrome 151's own
    // `Object.getOwnPropertyNames(WorkerNavigator.prototype)` order, measured in
    // a blob worker -- `constructor` is the bridge's, and Chrome puts it after
    // `connection`, which is why the list below is not alphabetical.
    pub const hardwareConcurrency = bridge.accessor(WorkerNavigator.getHardwareConcurrency, null, .{});
    pub const appCodeName = bridge.accessor(WorkerNavigator.getAppCodeName, null, .{});
    pub const appName = bridge.accessor(WorkerNavigator.getAppName, null, .{});
    pub const appVersion = bridge.accessor(WorkerNavigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(WorkerNavigator.getPlatform, null, .{});
    pub const product = bridge.accessor(WorkerNavigator.getProduct, null, .{});
    pub const userAgent = bridge.accessor(WorkerNavigator.getUserAgent, null, .{});
    pub const language = bridge.accessor(WorkerNavigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(WorkerNavigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(WorkerNavigator.getOnLine, null, .{});
    pub const connection = bridge.accessor(WorkerNavigator.getConnection, null, .{});
    // [Exposed=DedicatedWorker] for these three: a shared worker's navigator
    // has none of them (measured on Chrome 151,
    // probes/expr-shared-worker-proto-table.js), which matters because the
    // Akamai interstitial on macys reads its WorkerNavigator from a
    // SharedWorker.
    pub const hid = bridge.accessor(WorkerNavigator.getHid, null, .{ .exposed = .dedicated_worker });
    pub const mediaCapabilities = bridge.accessor(WorkerNavigator.getMediaCapabilities, null, .{});
    pub const permissions = bridge.accessor(WorkerNavigator.getPermissions, null, .{});
    pub const serial = bridge.accessor(WorkerNavigator.getSerial, null, .{ .exposed = .dedicated_worker });
    pub const usb = bridge.accessor(WorkerNavigator.getUsb, null, .{ .exposed = .dedicated_worker });
    pub const deviceMemory = bridge.accessor(WorkerNavigator.getDeviceMemory, null, .{});
    pub const userAgentData = bridge.accessor(WorkerNavigator.getUserAgentData, null, .{});
    pub const locks = bridge.accessor(WorkerNavigator.getLocks, null, .{});
    pub const storage = bridge.accessor(WorkerNavigator.getStorage, null, .{});
    pub const gpu = bridge.accessor(WorkerNavigator.getGpu, null, .{});
    pub const storageBuckets = bridge.accessor(WorkerNavigator.getStorageBuckets, null, .{});
};
