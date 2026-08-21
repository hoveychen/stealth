// `<usermedia>`: the declarative camera/microphone element, which asks for a
// MediaStream from markup rather than through getUserMedia(). Chrome 151 maps
// the tag and exposes the interface; this engine answered HTMLUnknownElement for
// both.
//
// There is no capture device here, so `stream` and `error` are permanently null
// and setConstraints() only ever validates -- which is the observable half
// anyway. Its dictionary is HTMLMediaStreamConstraints, whose two members are
// each a MediaTrackConstraintSet, so the `{video: true}` spelling every
// getUserMedia() example uses is *refused* (measured with a Proxy: Chrome reads
// `audio` then `video` and nothing else, and a member's own 38 constraint names
// are only read once the member is an object).
//
// The interface re-declares oncancel and onerror even though HTMLElement carries
// both, so they are own properties of this prototype too (measured).

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const dictionary = @import("../../dictionary.zig");
const global_event_handlers = @import("../../global_event_handlers.zig");

const Execution = js.Execution;

const UserMedia = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *UserMedia) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asNode(self: *UserMedia) *Node {
    return self.asElement().asNode();
}

/// `stream` and `error`: a MediaStream and a DOMException, neither of which this
/// element ever receives -- there is no device to open and so nothing to fail.
pub fn getNull(_: *const UserMedia) ?js.Value {
    return null;
}

const Reader = dictionary.MethodReader("HTMLUserMediaElement", "setConstraints", "HTMLMediaStreamConstraints");

/// One optional dictionary, so the arity is 0 and `setConstraints()`,
/// `(undefined)` and `(null)` all succeed. Nothing is stored: the constraints
/// only matter to a device, and the validation is what a page can see.
pub fn setConstraints(_: *UserMedia, constraints_: ?js.Value, exec: *const Execution) !void {
    const init = try Reader.read(constraints_, exec);
    inline for (.{ "audio", "video" }) |member| {
        if (try init.present(member)) |value| {
            // A null member is fine where a non-object is not: the member is a
            // dictionary, and a dictionary takes null as an empty one.
            if (!value.isNull() and !value.isObject()) {
                return Reader.notOfType(member, "MediaTrackConstraintSet", exec);
            }
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(UserMedia);

    pub const Meta = struct {
        pub const name = "HTMLUserMediaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// Getter/setter pair for an event handler property, the same shape
    /// Media.zig uses.
    fn handlerAccessor(comptime handler: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *UserMedia, frame: *Frame) !?js.Function.Global {
                return self.asElement().getAttributeFunction(handler, frame);
            }

            pub fn set(self: *UserMedia, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.asElement().setAttributeListener(handler, callback, frame);
            }
        };
    }

    // Chrome's own prototype order: error, the three handlers, stream, then the
    // one method.
    pub const @"error" = bridge.accessor(UserMedia.getNull, null, .{});
    pub const onstream = bridge.accessor(handlerAccessor(.onstream).get, handlerAccessor(.onstream).set, .{});
    pub const oncancel = bridge.accessor(handlerAccessor(.oncancel).get, handlerAccessor(.oncancel).set, .{});
    pub const onerror = bridge.accessor(handlerAccessor(.onerror).get, handlerAccessor(.onerror).set, .{});
    pub const stream = bridge.accessor(UserMedia.getNull, null, .{});
    pub const setConstraints = bridge.function(UserMedia.setConstraints, .{ .arity = 0 });
};
