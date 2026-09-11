const std = @import("std");
const Frame = @import("../../../Frame.zig");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");

const Marquee = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Marquee) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Marquee) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Marquee);

    pub const Meta = struct {
        pub const name = "HTMLMarqueeElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Marquee);

    pub const behavior = reflect.enumerated("behavior", &.{ "scroll", "slide", "alternate" }, .{ .missing = "scroll" });
    pub const bgColor = reflect.string("bgcolor");
    pub const direction = reflect.enumerated("direction", &.{ "up", "right", "down", "left" }, .{ .missing = "left" });
    pub const height = reflect.string("height");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const loop = bridge.accessor(Marquee.getLoop, Marquee.setLoop, .{ .ce_reactions = true });
    pub const scrollAmount = reflect.unsignedLong("scrollamount", .{ .default = 6 });
    pub const scrollDelay = reflect.unsignedLong("scrolldelay", .{ .default = 85 });
    pub const trueSpeed = reflect.boolean("truespeed");
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const width = reflect.string("width");
    pub const start = bridge.function(Marquee.start, .{});
    pub const stop = bridge.function(Marquee.stop, .{});
};

/// -1 -- "loop forever" -- for a missing or unparseable attribute, and the one
/// value the setter refuses is 0, with a sentence of its own. Measured on
/// Chrome 151 (probes/expr-html-family-semantics.js).
pub fn getLoop(self: *Marquee) i32 {
    const raw = self.asElement().getAttributeSafe(comptime .wrap("loop")) orelse return -1;
    const parsed = reflection.parseInteger(raw) orelse return -1;
    if (parsed <= 0 or parsed > 2147483647) {
        return -1;
    }
    return @intCast(parsed);
}

pub fn setLoop(self: *Marquee, value: i32, frame: *Frame) !void {
    if (value <= 0 and value != -1) {
        return frame.js.fail(error.IndexSizeError, try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to set the 'loop' property on 'HTMLMarqueeElement': " ++
                "The provided value ({d}) is neither positive nor -1.",
            .{value},
        ));
    }
    var buf: [12]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap("loop"), .wrap(str), frame);
}

// A marquee never scrolls here, so starting and stopping it is a pair of
// no-ops -- which is also all Chrome's return value says about them.
pub fn start(_: *Marquee) void {}

pub fn stop(_: *Marquee) void {}

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Marquee" {
    try testing.htmlRunner("element/html/marquee.html", .{});
}
