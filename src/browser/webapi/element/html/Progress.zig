const std = @import("std");
const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");

const Progress = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Progress) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Progress) *Node {
    return self.asElement().asNode();
}

pub fn getLabels(self: *Progress, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

fn current(self: *Progress) ?f64 {
    const raw = self.asElement().getAttributeSafe(comptime .wrap("value")) orelse return null;
    return reflection.parseDouble(raw);
}

fn maximum(self: *Progress) f64 {
    const raw = self.asElement().getAttributeSafe(comptime .wrap("max")) orelse return 1;
    const parsed = reflection.parseDouble(raw) orelse return 1;
    return if (parsed <= 0) 1 else parsed;
}

pub fn getValue(self: *Progress) f64 {
    return std.math.clamp(self.current() orelse 0, 0, self.maximum());
}

pub fn setValue(self: *Progress, value_: f64, frame: *Frame) !void {
    return reflection.setDouble(self.asElement(), "value", "HTMLProgressElement", value_, frame);
}

/// -1 for an indeterminate progress bar, which is one carrying no `value`
/// attribute at all -- not one whose value happens to be 0. Measured on
/// Chrome 151.
pub fn getPosition(self: *Progress) f64 {
    if (self.current() == null) {
        return -1;
    }
    return self.getValue() / self.maximum();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Progress);

    pub const Meta = struct {
        pub const name = "HTMLProgressElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Progress);

    pub const value = bridge.accessor(Progress.getValue, Progress.setValue, .{ .ce_reactions = true });
    pub const max = reflect.double("max", 1.0, true);
    pub const position = bridge.accessor(Progress.getPosition, null, .{});
    pub const labels = bridge.accessor(Progress.getLabels, null, .{});
};
