// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const IdleDeadline = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

pub fn init() IdleDeadline {
    return .{};
}

// The callback always runs because the engine went idle, never because the
// timeout expired -- the value that was already here. Chrome exposes it as a
// getter, and the kind is what a bot check reads (see
// src/browser/tests/descriptor_kind.html).
pub fn getDidTimeout(_: *const IdleDeadline) bool {
    return false;
}

pub fn timeRemaining(_: *const IdleDeadline) f64 {
    // Return a fixed 50ms.
    // This allows idle callbacks to perform work without complex
    // timing infrastructure.
    return 50.0;
}

pub const JsApi = struct {
    const js = @import("../js/js.zig");
    pub const bridge = js.Bridge(IdleDeadline);

    pub const Meta = struct {
        pub const name = "IdleDeadline";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const didTimeout = bridge.accessor(IdleDeadline.getDidTimeout, null, .{});
    pub const timeRemaining = bridge.function(IdleDeadline.timeRemaining, .{});
};
