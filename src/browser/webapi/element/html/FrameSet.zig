const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Window = @import("../../Window.zig");
const global_event_handlers = @import("../../global_event_handlers.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const FrameSet = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *FrameSet) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *FrameSet) *Node {
    return self.asElement().asNode();
}

// Special-case: the "window-reflecting body element event handler set" are
// aliases for the Window's event handlers, on frameset elements just like on
// body elements. Chrome's HTMLFrameSetElement.prototype carries the same 26
// handlers HTMLBodyElement.prototype does, in the same order (measured); the
// two gamepad ones are element-local there too.

// The aliased Window is the one of the element's node document's frame — not
// the caller's frame, which differs when a same-origin script reaches into
// another frame (e.g. the parent setting a handler on a child frameset).
fn reflectedWindow(self: *FrameSet, frame: *Frame) *Window {
    return self.asElement().ownerFrame(frame).window;
}

fn reflected(comptime handler: global_event_handlers.Handler) type {
    return struct {
        fn get(self: *FrameSet, frame: *Frame) ?js.Function.Global {
            return self.reflectedWindow(frame).getReflectedHandler(handler);
        }
        fn set(self: *FrameSet, setter: ?Window.FunctionSetter, frame: *Frame) !void {
            return self.reflectedWindow(frame).setReflectedHandler(handler, Window.getFunctionFromSetter(setter));
        }
    };
}

fn local(comptime handler: global_event_handlers.Handler) type {
    return struct {
        fn get(self: *FrameSet, frame: *Frame) !?js.Function.Global {
            return self.asElement().getAttributeFunction(handler, frame);
        }
        fn set(self: *FrameSet, callback: ?js.Function.Global, frame: *Frame) !void {
            return self.asElement().setAttributeListener(handler, callback, frame);
        }
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FrameSet);

    pub const Meta = struct {
        pub const name = "HTMLFrameSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(FrameSet);

    pub const cols = reflect.string("cols");
    pub const rows = reflect.string("rows");

    pub const onblur = bridge.accessor(reflected(.onblur).get, reflected(.onblur).set, .{ .null_as_undefined = false });
    pub const onerror = bridge.accessor(reflected(.onerror).get, reflected(.onerror).set, .{ .null_as_undefined = false });
    pub const onfocus = bridge.accessor(reflected(.onfocus).get, reflected(.onfocus).set, .{ .null_as_undefined = false });
    pub const onload = bridge.accessor(reflected(.onload).get, reflected(.onload).set, .{ .null_as_undefined = false });
    pub const onresize = bridge.accessor(reflected(.onresize).get, reflected(.onresize).set, .{ .null_as_undefined = false });
    pub const onscroll = bridge.accessor(reflected(.onscroll).get, reflected(.onscroll).set, .{ .null_as_undefined = false });
    pub const onafterprint = bridge.accessor(reflected(.onafterprint).get, reflected(.onafterprint).set, .{ .null_as_undefined = false });
    pub const onbeforeprint = bridge.accessor(reflected(.onbeforeprint).get, reflected(.onbeforeprint).set, .{ .null_as_undefined = false });
    pub const onbeforeunload = bridge.accessor(reflected(.onbeforeunload).get, reflected(.onbeforeunload).set, .{ .null_as_undefined = false });
    pub const onhashchange = bridge.accessor(reflected(.onhashchange).get, reflected(.onhashchange).set, .{ .null_as_undefined = false });
    pub const onlanguagechange = bridge.accessor(reflected(.onlanguagechange).get, reflected(.onlanguagechange).set, .{ .null_as_undefined = false });
    pub const onmessage = bridge.accessor(reflected(.onmessage).get, reflected(.onmessage).set, .{ .null_as_undefined = false });
    pub const onmessageerror = bridge.accessor(reflected(.onmessageerror).get, reflected(.onmessageerror).set, .{ .null_as_undefined = false });
    pub const onoffline = bridge.accessor(reflected(.onoffline).get, reflected(.onoffline).set, .{ .null_as_undefined = false });
    pub const ononline = bridge.accessor(reflected(.ononline).get, reflected(.ononline).set, .{ .null_as_undefined = false });
    pub const onpagehide = bridge.accessor(reflected(.onpagehide).get, reflected(.onpagehide).set, .{ .null_as_undefined = false });
    pub const onpageshow = bridge.accessor(reflected(.onpageshow).get, reflected(.onpageshow).set, .{ .null_as_undefined = false });
    pub const onpopstate = bridge.accessor(reflected(.onpopstate).get, reflected(.onpopstate).set, .{ .null_as_undefined = false });
    pub const onrejectionhandled = bridge.accessor(reflected(.onrejectionhandled).get, reflected(.onrejectionhandled).set, .{ .null_as_undefined = false });
    pub const onstorage = bridge.accessor(reflected(.onstorage).get, reflected(.onstorage).set, .{ .null_as_undefined = false });
    pub const onunhandledrejection = bridge.accessor(reflected(.onunhandledrejection).get, reflected(.onunhandledrejection).set, .{ .null_as_undefined = false });
    pub const onunload = bridge.accessor(reflected(.onunload).get, reflected(.onunload).set, .{ .null_as_undefined = false });
    pub const ongamepadconnected = bridge.accessor(local(.ongamepadconnected).get, local(.ongamepadconnected).set, .{});
    pub const ongamepaddisconnected = bridge.accessor(local(.ongamepaddisconnected).get, local(.ongamepaddisconnected).set, .{});
};

pub const Build = struct {
    pub fn complete(node: *Node, frame: *Frame) !void {
        const el = node.as(Element);
        const owner = node.ownerFrame(frame);
        inline for (Window.WINDOW_REFLECTING) |handler| {
            // Several of these names are past the 12-byte comptime SSO limit,
            // so the wrap runs at runtime over the tag name's static bytes.
            const attr = String.wrap(@as([]const u8, @tagName(handler)));
            if (el.getAttributeSafe(attr)) |value| {
                owner.window.setWindowReflectingHandlerFromAttribute(attr, value, owner);
            }
        }
    }

    pub fn attributeChange(el: *Element, name: String, value: String, frame: *Frame) !void {
        const owner = el.ownerFrame(frame);
        owner.window.setWindowReflectingHandlerFromAttribute(name, value.str(), owner);
    }

    pub fn attributeRemove(el: *Element, name: String, frame: *Frame) !void {
        const owner = el.ownerFrame(frame);
        owner.window.setWindowReflectingHandlerFromAttribute(name, null, owner);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Frameset" {
    try testing.htmlRunner("element/html/frameset.html", .{});
}
