// `<geolocation>`: the declarative geolocation element, which asks for a
// position from markup rather than from script. Chrome 151 maps the tag and
// exposes the interface; this engine answered HTMLUnknownElement for both.
//
// Three of its thirteen members reflect a content attribute and do so for real,
// because that half is plain DOM: `accuracymode` is a bare string with no
// keyword validation (measured: an unknown value reads straight back) and
// `autolocate` and `watch` are presence flags.
//
// The rest report what a Chrome tab reports before anything happens, which is
// also all this engine can ever report: no position, no error, not valid, and a
// permission status of "prompt" both now and initially. Nothing here can grant
// or deny geolocation, so nothing moves those off their defaults -- the same
// stance navigator.geolocation takes in geolocation.zig.
//
// Member order, arities, descriptors and defaults are Chrome's own, measured on
// a headed Chrome 151 with tools/fingerprint/probes/probe-shapes.js and
// probe-s6-elements.js.

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const global_event_handlers = @import("../../global_event_handlers.zig");

const Geolocation = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Geolocation) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asNode(self: *Geolocation) *Node {
    return self.asElement().asNode();
}

/// `position` and `error`: a GeolocationPosition and a GeolocationPositionError,
/// neither of which this element ever receives.
pub fn getNull(_: *const Geolocation) ?js.Value {
    return null;
}

/// Whether the element's own attributes make a valid request. Chrome answers
/// false on a fresh element and stays there until it has a permission decision,
/// which is a state this engine never reaches.
pub fn getIsValid(_: *const Geolocation) bool {
    return false;
}

pub fn getInvalidReason(_: *const Geolocation) []const u8 {
    return "";
}

/// Both permission members read "prompt": nothing has been asked, and nothing
/// here can ask.
pub fn getPermissionStatus(_: *const Geolocation) []const u8 {
    return "prompt";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Geolocation);

    pub const Meta = struct {
        pub const name = "HTMLGeolocationElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// Getter/setter pair for an event handler property, through the element the
    /// geolocation element is -- the same shape Media.zig uses.
    fn handlerAccessor(comptime handler: global_event_handlers.Handler) type {
        return struct {
            pub fn get(self: *Geolocation, frame: *Frame) !?js.Function.Global {
                return self.asElement().getAttributeFunction(handler, frame);
            }

            pub fn set(self: *Geolocation, callback: ?js.Function.Global, frame: *Frame) !void {
                return self.asElement().setAttributeListener(handler, callback, frame);
            }
        };
    }

    const reflect = Element.Reflect(Geolocation);

    // Chrome's own prototype order, which interleaves the handlers with the
    // rest rather than grouping them.
    pub const onlocation = bridge.accessor(handlerAccessor(.onlocation).get, handlerAccessor(.onlocation).set, .{});
    pub const position = bridge.accessor(Geolocation.getNull, null, .{});
    pub const @"error" = bridge.accessor(Geolocation.getNull, null, .{});
    pub const accuracymode = reflect.string("accuracymode");
    pub const autolocate = reflect.boolean("autolocate");
    pub const watch = reflect.boolean("watch");
    pub const isValid = bridge.accessor(Geolocation.getIsValid, null, .{});
    pub const invalidReason = bridge.accessor(Geolocation.getInvalidReason, null, .{});
    pub const initialPermissionStatus = bridge.accessor(Geolocation.getPermissionStatus, null, .{});
    pub const permissionStatus = bridge.accessor(Geolocation.getPermissionStatus, null, .{});
    pub const onpromptaction = bridge.accessor(handlerAccessor(.onpromptaction).get, handlerAccessor(.onpromptaction).set, .{});
    pub const onpromptdismiss = bridge.accessor(handlerAccessor(.onpromptdismiss).get, handlerAccessor(.onpromptdismiss).set, .{});
    pub const onvalidationstatuschange = bridge.accessor(handlerAccessor(.onvalidationstatuschange).get, handlerAccessor(.onvalidationstatuschange).set, .{});
};
