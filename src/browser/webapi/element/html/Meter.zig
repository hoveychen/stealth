const std = @import("std");
const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");

const Meter = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Meter) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Meter) *Node {
    return self.asElement().asNode();
}

pub fn getLabels(self: *Meter, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

/// The six numbers a `<meter>` reports are not six independent reflections:
/// each is clamped by the ones before it, so a bare `<meter>` reads
/// 0/0/1/0/1/0.5 and one written `value=5 min=10 max=4 low=1 high=99
/// optimum=-2` reads 10 for all six. Measured on Chrome 151
/// (probes/expr-html-family-semantics.js), which is the HTML spec's own
/// "actual value" chain.
fn attribute(self: *Meter, comptime name: []const u8) ?f64 {
    const raw = self.asElement().getAttributeSafe(comptime .wrap(name)) orelse return null;
    return reflection.parseDouble(raw);
}

fn minimum(self: *Meter) f64 {
    return self.attribute("min") orelse 0;
}

fn maximum(self: *Meter) f64 {
    const min = self.minimum();
    return @max(self.attribute("max") orelse 1, min);
}

pub fn getMin(self: *Meter) f64 {
    return self.minimum();
}

pub fn getMax(self: *Meter) f64 {
    return self.maximum();
}

pub fn getValue(self: *Meter) f64 {
    return std.math.clamp(self.attribute("value") orelse 0, self.minimum(), self.maximum());
}

pub fn getLow(self: *Meter) f64 {
    return std.math.clamp(self.attribute("low") orelse self.minimum(), self.minimum(), self.maximum());
}

/// The one that is not clamped to `min`: `high` is floored by `low`, so a
/// `high` below `low` reports `low`.
pub fn getHigh(self: *Meter) f64 {
    return std.math.clamp(self.attribute("high") orelse self.maximum(), self.getLow(), self.maximum());
}

pub fn getOptimum(self: *Meter) f64 {
    const default = (self.minimum() + self.maximum()) / 2;
    return std.math.clamp(self.attribute("optimum") orelse default, self.minimum(), self.maximum());
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Meter);

    pub const Meta = struct {
        pub const name = "HTMLMeterElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // The setters write the number they are given; only the getters clamp,
    // which is why `meter.value = 5` on a max of 1 reads back 1 while the
    // attribute still says 5.
    pub const value = bridge.accessor(Meter.getValue, Setter("value").set, .{ .ce_reactions = true });
    pub const min = bridge.accessor(Meter.getMin, Setter("min").set, .{ .ce_reactions = true });
    pub const max = bridge.accessor(Meter.getMax, Setter("max").set, .{ .ce_reactions = true });
    pub const low = bridge.accessor(Meter.getLow, Setter("low").set, .{ .ce_reactions = true });
    pub const high = bridge.accessor(Meter.getHigh, Setter("high").set, .{ .ce_reactions = true });
    pub const optimum = bridge.accessor(Meter.getOptimum, Setter("optimum").set, .{ .ce_reactions = true });

    pub const labels = bridge.accessor(Meter.getLabels, null, .{});

    fn Setter(comptime attr: []const u8) type {
        return struct {
            fn set(self: *Meter, value_: f64, frame: *Frame) !void {
                return reflection.setDouble(self.asElement(), attr, "HTMLMeterElement", value_, frame);
            }
        };
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Meter" {
    try testing.htmlRunner("element/html/meter_progress.html", .{});
}
