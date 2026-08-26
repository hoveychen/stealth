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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const EventTarget = @import("EventTarget.zig");
const handler_property = @import("handler_property.zig");

const VisualViewport = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

pub fn asEventTarget(self: *VisualViewport) *EventTarget {
    return self._proto;
}

pub fn getPageLeft(_: *const VisualViewport, frame: *Frame) u32 {
    return frame.window.getScrollX();
}

pub fn getPageTop(_: *const VisualViewport, frame: *Frame) u32 {
    return frame.window.getScrollY();
}

// No pinch-zoom and no mobile viewport, so the visual viewport never moves off
// the layout viewport and never scales. These three were data properties, which
// is a difference no value probe can see and one a bot check trips over -- see
// the note in src/browser/tests/descriptor_kind.html. The values are the ones
// that were here.
pub fn getOffsetLeft(_: *const VisualViewport) u32 {
    return 0;
}

pub fn getOffsetTop(_: *const VisualViewport) u32 {
    return 0;
}

pub fn getScale(_: *const VisualViewport) f64 {
    return 1.0;
}

// The frame's own viewport, the same box `window.innerWidth` reports -- a
// browser gives a child frame its `<iframe>` element's box here, not the top
// document's. See Frame.viewport.
pub fn getWidth(_: *const VisualViewport, frame: *Frame) u32 {
    return frame.viewport().width;
}

pub fn getHeight(_: *const VisualViewport, frame: *Frame) u32 {
    return frame.viewport().height;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VisualViewport);

    pub const Meta = struct {
        pub const name = "VisualViewport";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const offsetLeft = bridge.accessor(VisualViewport.getOffsetLeft, null, .{});
    pub const offsetTop = bridge.accessor(VisualViewport.getOffsetTop, null, .{});
    pub const pageLeft = bridge.accessor(VisualViewport.getPageLeft, null, .{});
    pub const pageTop = bridge.accessor(VisualViewport.getPageTop, null, .{});
    pub const width = bridge.accessor(VisualViewport.getWidth, null, .{});
    pub const height = bridge.accessor(VisualViewport.getHeight, null, .{});
    pub const scale = bridge.accessor(VisualViewport.getScale, null, .{});

    // The three events a viewport fires. Nothing resizes or scrolls here, so
    // they never run -- but a page that installs one and reads it back gets
    // its function, which is what the property is for.
    pub const onresize = bridge.accessor(handler(.onresize).get, handler(.onresize).set, .{});
    pub const onscroll = bridge.accessor(handler(.onscroll).get, handler(.onscroll).set, .{});
    pub const onscrollend = bridge.accessor(handler(.onscrollend).get, handler(.onscrollend).set, .{});

    fn handler(comptime which: handler_property.Handler) type {
        return handler_property.accessors(VisualViewport, which);
    }
};
