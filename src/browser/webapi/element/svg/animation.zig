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

//! The SMIL animation elements — <animate>, <animateMotion>,
//! <animateTransform>, <set> — plus <mpath>, which is a plain SVGElement.
//!
//! This engine runs no SMIL timeline, so nothing here animates. What it does
//! provide is the interface surface a detector reads: the four classes and
//! their shared SVGAnimationElement base, the target resolution, the
//! conditional-processing lists, the begin/end/repeat handlers and the three
//! timing queries.
//!
//! The timing answers are derived from the attributes and the document clock
//! rather than from a running animation, which is enough to reproduce what
//! Chrome 150 reports for a document that just loaded:
//!
//!   * getSimpleDuration() parses `dur` and throws NotSupportedError when it
//!     is absent, indefinite, media-bound or malformed (measured: a negative
//!     clock value throws too).
//!   * getStartTime() answers 0 while the element is in a document and its
//!     active period has not elapsed, and throws InvalidStateError otherwise.
//!     Chrome answers 0 for every `begin` spelling we measured — including
//!     "5s" and "indefinite" — because the element has already begun by the
//!     time the script asks.
//!   * getCurrentTime() is the document timeline, in seconds.

const std = @import("std");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const StringList = @import("../../svg/StringList.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");

const Svg = @import("../Svg.zig");

pub fn registerTypes() []const type {
    return &.{
        Animation,
        Animate,
        AnimateMotion,
        AnimateTransform,
        Set,
        MPath,
    };
}

pub const Animation = struct {
    pub const Proto = Svg;
    _proto: *Svg,
    _type: Type,

    pub const Type = union(enum) {
        animate: *Animate,
        animate_motion: *AnimateMotion,
        animate_transform: *AnimateTransform,
        set: *Set,
    };

    pub fn is(self: *Animation, comptime T: type) ?*T {
        inline for (@typeInfo(Type).@"union".fields) |field| {
            if (@field(Type, field.name) == self._type) {
                if (field.type == *T) {
                    return @field(self._type, field.name);
                }
            }
        }
        return null;
    }

    pub fn asElement(self: *Animation) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *Animation) *Node {
        return self.asElement().asNode();
    }

    /// `href` (which is where the parser also files `xlink:href`) names the
    /// target; without one the animation applies to its parent element.
    /// Chrome hands back null for a target that is not an SVG element, which
    /// is what the SVGElement? return type says.
    pub fn getTargetElement(self: *Animation, frame: *Frame) ?*Element {
        const element = self.asElement();
        const href = element.getAttributeSafe(comptime .wrap("href")) orelse "";
        const trimmed = std.mem.trim(u8, href, " \t\r\n");
        if (trimmed.len == 0) {
            const parent = self.asNode().parentNode() orelse return null;
            return svgElement(parent.is(Element));
        }
        if (trimmed[0] != '#') {
            return null;
        }
        const document = self.asNode().ownerDocument(frame) orelse frame.document;
        return svgElement(document.getElementById(trimmed[1..], frame));
    }

    fn svgElement(candidate: ?*Element) ?*Element {
        const element = candidate orelse return null;
        return if (element._namespace == .svg) element else null;
    }

    pub fn getRequiredExtensions(self: *Animation, frame: *Frame) !*StringList {
        return StringList.getOrCreate(self.asElement(), .required_extensions, frame);
    }

    pub fn getSystemLanguage(self: *Animation, frame: *Frame) !*StringList {
        return StringList.getOrCreate(self.asElement(), .system_language, frame);
    }

    /// The document timeline, in seconds.
    pub fn getCurrentTime(_: *Animation, frame: *Frame) f64 {
        return frame.window.getPerformance().now() / std.time.ms_per_s;
    }

    pub fn getSimpleDuration(self: *Animation) !f64 {
        const raw = self.asElement().getAttributeSafe(comptime .wrap("dur")) orelse
            return error.NotSupported;
        return parseClockValue(raw) orelse error.NotSupported;
    }

    pub fn getStartTime(self: *Animation, frame: *Frame) !f64 {
        if (!self.asNode().isConnected()) {
            return error.InvalidStateError;
        }
        // Without a timeline the animation begins at 0. Once its simple
        // duration has elapsed there is no active interval left to report,
        // which is the state Chrome signals with InvalidStateError.
        if (self.getSimpleDuration() catch null) |duration| {
            if (self.getCurrentTime(frame) >= duration) {
                return error.InvalidStateError;
            }
        }
        return 0;
    }

    pub fn beginElement(_: *Animation) void {}
    pub fn beginElementAt(_: *Animation, _: f64) void {}
    pub fn endElement(_: *Animation) void {}
    pub fn endElementAt(_: *Animation, _: f64) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Animation);

        pub const Meta = struct {
            pub const name = "SVGAnimationElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const targetElement = bridge.accessor(Animation.getTargetElement, null, .{});
        pub const onbegin = bridge.accessor(handler(.onbegin).get, handler(.onbegin).set, .{});
        pub const onend = bridge.accessor(handler(.onend).get, handler(.onend).set, .{});
        pub const onrepeat = bridge.accessor(handler(.onrepeat).get, handler(.onrepeat).set, .{});
        pub const requiredExtensions = bridge.accessor(Animation.getRequiredExtensions, null, .{});
        pub const systemLanguage = bridge.accessor(Animation.getSystemLanguage, null, .{});
        pub const beginElement = bridge.function(Animation.beginElement, .{});
        pub const beginElementAt = bridge.function(Animation.beginElementAt, .{});
        pub const endElement = bridge.function(Animation.endElement, .{});
        pub const endElementAt = bridge.function(Animation.endElementAt, .{});
        pub const getCurrentTime = bridge.function(Animation.getCurrentTime, .{});
        pub const getSimpleDuration = bridge.function(Animation.getSimpleDuration, .{});
        pub const getStartTime = bridge.function(Animation.getStartTime, .{});

        // The three handlers have no dedicated storage; they ride the same
        // attribute-listener store every other element handler uses.
        fn handler(comptime which: global_event_handlers.Handler) type {
            return struct {
                pub fn get(self: *Animation, frame: *Frame) !?js.Function.Global {
                    return self.asElement().getAttributeFunction(which, frame);
                }
                pub fn set(self: *Animation, callback: ?js.Function.Global, frame: *Frame) !void {
                    return self.asElement().setAttributeListener(which, callback, frame);
                }
            };
        }
    };
};

const global_event_handlers = @import("../../global_event_handlers.zig");

/// A SMIL clock value: `hh:mm:ss.f`, `mm:ss.f`, or a number with an optional
/// h / min / s / ms unit. Returns null for everything Chrome refuses,
/// including negative values and the "indefinite" / "media" keywords.
fn parseClockValue(raw: []const u8) ?f64 {
    const input = std.mem.trim(u8, raw, " \t\r\n");
    if (input.len == 0) {
        return null;
    }

    var colons: usize = 0;
    for (input) |c| {
        if (c == ':') colons += 1;
    }
    if (colons != 0) {
        if (colons > 2) {
            return null;
        }
        var it = std.mem.splitScalar(u8, input, ':');
        var total: f64 = 0;
        var count: usize = 0;
        while (it.next()) |part| : (count += 1) {
            // Only the seconds field may carry a fraction, and no field may
            // carry a sign.
            if (part.len == 0 or part[0] == '+' or part[0] == '-') {
                return null;
            }
            const value = std.fmt.parseFloat(f64, part) catch return null;
            if (!std.math.isFinite(value) or value < 0) {
                return null;
            }
            if (count + 1 < colons + 1 and std.mem.indexOfScalar(u8, part, '.') != null) {
                return null;
            }
            total = total * 60 + value;
        }
        return total;
    }

    const split = for (input, 0..) |c, i| {
        if (!std.ascii.isDigit(c) and c != '.' and c != '+' and c != '-') break i;
    } else input.len;
    const number = std.fmt.parseFloat(f64, input[0..split]) catch return null;
    if (!std.math.isFinite(number) or number < 0) {
        return null;
    }
    const unit = input[split..];
    if (unit.len == 0 or std.mem.eql(u8, unit, "s")) {
        return number;
    }
    if (std.mem.eql(u8, unit, "ms")) {
        return number / std.time.ms_per_s;
    }
    if (std.mem.eql(u8, unit, "min")) {
        return number * std.time.s_per_min;
    }
    if (std.mem.eql(u8, unit, "h")) {
        return number * std.time.s_per_hour;
    }
    return null;
}

/// The four timed elements. Chrome gives each its own class with nothing on
/// its prototype but `constructor`, so the class name is the whole point.
fn Timed(comptime class_name: []const u8) type {
    return struct {
        const Self = @This();

        pub const Proto = Animation;
        _proto: *Animation,

        pub fn asElement(self: *Self) *Element {
            return self._proto.asElement();
        }
        pub fn asNode(self: *Self) *Node {
            return self.asElement().asNode();
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = class_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };
        };
    };
}

pub const Animate = Timed("SVGAnimateElement");
pub const AnimateMotion = Timed("SVGAnimateMotionElement");
pub const AnimateTransform = Timed("SVGAnimateTransformElement");
pub const Set = Timed("SVGSetElement");

/// <mpath> derives straight from SVGElement and carries a single member.
pub const MPath = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    pub fn asElement(self: *MPath) *Element {
        return self._proto.asElement();
    }
    pub fn asNode(self: *MPath) *Node {
        return self.asElement().asNode();
    }

    pub fn getHref(self: *MPath, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .href, frame);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MPath);

        pub const Meta = struct {
            pub const name = "SVGMPathElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const href = bridge.accessor(MPath.getHref, null, .{});
    };
};

const testing = @import("../../../../testing.zig");
test "WebApi: Svg.clockValue" {
    try testing.expectEqual(1000, parseClockValue("1000s"));
    try testing.expectEqual(90.5, parseClockValue("00:01:30.5"));
    try testing.expectEqual(90, parseClockValue("01:30"));
    try testing.expectEqual(0.25, parseClockValue("250ms"));
    try testing.expectEqual(120, parseClockValue("2min"));
    try testing.expectEqual(3600, parseClockValue("1h"));
    try testing.expectEqual(90, parseClockValue("90"));
    try testing.expectEqual(1, parseClockValue("1s "));
    try testing.expectEqual(2, parseClockValue(" 2s"));
    try testing.expectEqual(null, parseClockValue("indefinite"));
    try testing.expectEqual(null, parseClockValue("media"));
    try testing.expectEqual(null, parseClockValue(""));
    try testing.expectEqual(null, parseClockValue("bogus"));
    try testing.expectEqual(null, parseClockValue("-1s"));
}
