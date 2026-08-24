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

pub fn getLanguages(self: *const WorkerNavigator, exec: *const Execution) ![]const []const u8 {
    return self._navigator.getLanguages(exec);
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(WorkerNavigator);

    pub const Meta = struct {
        pub const name = "WorkerNavigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is Chrome 151's own
    // `Object.getOwnPropertyNames(WorkerNavigator.prototype)` order, measured in
    // a blob worker. The eight it carries that are missing here -- connection,
    // hid, mediaCapabilities, serial, usb, locks, gpu, storageBuckets -- all
    // resolve through a Frame, and `Caller.getGlobalArg` has no Frame to hand a
    // worker realm. They are a separate piece of work, not an oversight.
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
    pub const permissions = bridge.accessor(WorkerNavigator.getPermissions, null, .{});
    pub const deviceMemory = bridge.accessor(WorkerNavigator.getDeviceMemory, null, .{});
    pub const userAgentData = bridge.accessor(WorkerNavigator.getUserAgentData, null, .{});
    pub const storage = bridge.accessor(WorkerNavigator.getStorage, null, .{});
};
