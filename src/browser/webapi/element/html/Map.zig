const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const Frame = @import("../../../Frame.zig");

const Map = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Map) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Map) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Map);

    pub const Meta = struct {
        pub const name = "HTMLMapElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Map);
    pub const name = reflect.string("name");

    /// A live HTMLCollection of the map's <area> descendants (measured: a map
    /// with two areas answers an HTMLCollection of length 2).
    pub const areas = bridge.accessor(_areas, null, .{});
    fn _areas(self: *Map, frame: *Frame) !*collections.HTMLCollection {
        const root = self.asNode();
        return collections.identity.get(
            frame,
            .{ .root = root, .kind = .area_map, .name = "" },
            collections.NodeLive(.tag).init(root, .area, frame).htmlCollectionValue(),
        );
    }
};
