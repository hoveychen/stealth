const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Frame = @import("../../../Frame.zig");
const std = @import("std");

const Title = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Title) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Title) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Title);

    pub const Meta = struct {
        pub const name = "HTMLTitleElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// The only member of its own Chrome has here: the child text content,
    /// read and written (measured -- `<title>T1</title>` answers "T1", and the
    /// setter's arity is 1).
    pub const text = bridge.accessor(_text, _setText, .{ .ce_reactions = true });
    fn _text(self: *Title, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.asNode().getChildTextContent(&buf.writer);
        return buf.written();
    }
    fn _setText(self: *Title, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] DOMString`: a JS null becomes "", not "null".
        return self.asNode().setTextContent(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }
};
