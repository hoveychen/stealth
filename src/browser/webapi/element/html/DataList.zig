const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const Frame = @import("../../../Frame.zig");

const DataList = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *DataList) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *DataList) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataList);

    pub const Meta = struct {
        pub const name = "HTMLDataListElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// The only member of its own Chrome has here: a live HTMLCollection of the
    /// datalist's <option> descendants (measured, length 2 for two options).
    pub const options = bridge.accessor(_options, null, .{});
    fn _options(self: *DataList, frame: *Frame) !*collections.HTMLCollection {
        const root = self.asNode();
        return collections.identity.get(
            frame,
            .{ .root = root, .kind = .data_list_options, .name = "" },
            collections.NodeLive(.tag).init(root, .option, frame).htmlCollectionValue(),
        );
    }
};
