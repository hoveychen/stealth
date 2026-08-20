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

//! One entry of the Local Font Access API's font list.
//!
//! Nothing here ever runs: `window.queryLocalFonts()` rejects with
//! `SecurityError: User activation is required.` on a page that just calls it,
//! measured on a headed Chrome 150, so no FontData is ever handed out. Like
//! CSSAnimation, what a detector reads is the global and its prototype.

const js = @import("../js/js.zig");
const Blob = @import("Blob.zig");

const Execution = js.Execution;

const FontData = @This();

_postscript_name: []const u8 = "",
_full_name: []const u8 = "",
_family: []const u8 = "",
_style: []const u8 = "",

pub fn getPostscriptName(self: *const FontData) []const u8 {
    return self._postscript_name;
}

pub fn getFullName(self: *const FontData) []const u8 {
    return self._full_name;
}

pub fn getFamily(self: *const FontData) []const u8 {
    return self._family;
}

pub fn getStyle(self: *const FontData) []const u8 {
    return self._style;
}

pub fn blob(_: *const FontData, exec: *const Execution) !js.Promise {
    const empty = try Blob.initFromBytes("", "application/octet-stream", exec);
    return exec.js.local.?.resolvePromise(empty);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontData);

    pub const Meta = struct {
        pub const name = "FontData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const postscriptName = bridge.accessor(FontData.getPostscriptName, null, .{});
    pub const fullName = bridge.accessor(FontData.getFullName, null, .{});
    pub const family = bridge.accessor(FontData.getFamily, null, .{});
    pub const style = bridge.accessor(FontData.getStyle, null, .{});
    pub const blob = bridge.function(FontData.blob, .{});
};
