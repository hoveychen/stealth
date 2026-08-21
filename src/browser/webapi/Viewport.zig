// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! `window.viewport`: the Viewport Segments API's view of how many pieces the
//! viewport is split into by a fold or a hinge. A phone with one screen -- and
//! this engine -- has exactly one segment, the whole viewport, reported as a
//! DOMRect.
//!
//! One per window and the same object on every read, but `segments` answers a
//! *fresh frozen* array each time (measured: two reads are not the same array).
//! The window accessor is [Replaceable], unlike window.crashReport's, so it has
//! a setter that shadows it with a data property.
//!
//! Measured on a headed Chrome 151 with tools/fingerprint/probes/probe-shapes.js
//! and probe-s7-misc.js, where the single segment was the 1200x818 viewport of
//! the browser window. Here it is whatever the page's viewport is, the same
//! numbers window.innerWidth and innerHeight report.

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const DOMRect = @import("DOMRect.zig");

const Execution = js.Execution;

const Viewport = @This();

_pad: bool = false,

pub const init: Viewport = .{};

/// A frozen one-element FrozenArray. The freeze is the engine-wide FrozenArray
/// gap -- the array this hands back is an ordinary one -- but the contents and
/// the fresh-per-read identity are Chrome's.
pub fn getSegments(_: *const Viewport, frame: *Frame) ![]const *DOMRect {
    const viewport = frame._page.getViewport();
    const rect = try DOMRect.init(
        0,
        0,
        @floatFromInt(viewport.width),
        @floatFromInt(viewport.height),
        &frame.js.execution,
    );
    const segments = try frame.call_arena.alloc(*DOMRect, 1);
    segments[0] = rect;
    return segments;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Viewport);

    pub const Meta = struct {
        pub const name = "Viewport";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const segments = bridge.accessor(Viewport.getSegments, null, .{});
};
