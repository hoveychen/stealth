const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Image = @This();

pub const Proto = HtmlElement;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try Frame.node_factory.createElementNS(frame, .html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Image) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
    // No need to check if `Image` is connected to DOM; this is a special case.
    return self.imageAddedCallback(frame);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loading")) orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

pub fn getNaturalWidth(_: *const Image) u32 {
    // this is a valid response under a number of normal conditions, but could
    // be used to detect the nature of Browser.
    return 0;
}

pub fn getNaturalHeight(_: *const Image) u32 {
    // this is a valid response under a number of normal conditions, but could
    // be used to detect the nature of Browser.
    return 0;
}

/// What `width` and `height` answer when no attribute declared one. They
/// report the rendered box rather than the attribute, and a broken <img> is
/// rendered as the broken-image icon -- 16, where an element with no box at
/// all reads 0. Measured on Chrome 151 (probe `expr-broken-image.js`), which
/// also answers 16 for `width="invalid"` and `width="-5"`: an attribute that
/// declares nothing usable leaves the box to speak, same as an absent one.
fn brokenImageIcon(el: *Element) u32 {
    if (!el.hasBrokenImageBox()) {
        return 0;
    }
    return @intFromFloat(Element.broken_image_icon_size);
}

pub fn getComplete(_: *const Image) bool {
    // Per spec, complete is true when: no src/srcset, src is empty,
    // image is fully available, or image is broken (with no pending request).
    // We fetch the bytes but never decode them (see `Frame.loadImage`), so
    // images stay in the "broken" state, which has complete=true. This is
    // consistent with naturalWidth/naturalHeight=0.
    return true;
}

/// Used in `Page.nodeIsReady`.
pub fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();
    // Exit if src not set.
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return;
    if (src.len == 0) return;

    // Request the bytes without decoding them. Never fetching images at all is
    // a server-visible tell; see `Frame.loadImage`.
    //
    // The load/error event comes from the transfer, not from here: queueing
    // `load` the moment a src was set -- what this used to do -- reported
    // success for images that 404'd, which no browser does.
    try frame.loadImage(Factory.protoOf(self), src);
}

/// Where the image sits, which is the only position this engine has: the same
/// number `offsetLeft` and `offsetTop` answer. Chrome's is a different
/// quantity -- on a headed Chrome 151 its `x` came back at exactly twice its
/// `offsetLeft` (1602 against 801), so Blink is reporting an absolute box in
/// device pixels rather than the CSS-pixel offset. Answering the layout
/// position keeps the two members consistent with each other, which is what a
/// page reading all four compares.
pub fn getX(self: *Image, frame: *Frame) i32 {
    return @intFromFloat(self.asElement().getOffsetLeft(frame));
}

pub fn getY(self: *Image, frame: *Frame) i32 {
    return @intFromFloat(self.asElement().getOffsetTop(frame));
}

/// Nothing is decoded here, so the promise is already resolved -- which is
/// what a page awaiting it before drawing needs.
pub fn decode(_: *Image, frame: *Frame) !js.Promise {
    return frame.js.local.?.resolvePromise(js.Undefined{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        // browsingTopics, attributionSrc and sharedStorageWritable are
        // installed per context, after V8 appends `constructor`.
        pub const constructor_after = "decode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Image);

    pub const constructor = bridge.constructor(Image.constructor, .{});

    // Chrome's own-property order, which is IDL order with the last three --
    // the privacy-sandbox members Blink installs per context -- landing after
    // `constructor`; see Meta.constructor_after above.
    pub const alt = reflect.string("alt");
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{ .ce_reactions = true });
    pub const srcset = reflect.string("srcset");
    pub const sizes = reflect.string("sizes");
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const useMap = reflect.string("usemap");
    pub const isMap = reflect.boolean("ismap");
    pub const width = reflect.unsignedLong("width", .{ .undeclared = brokenImageIcon });
    pub const height = reflect.unsignedLong("height", .{ .undeclared = brokenImageIcon });
    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
    pub const currentSrc = bridge.accessor(Image.getSrc, null, .{});
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const decoding = reflect.enumerated("decoding", &.{ "async", "sync", "auto" }, .{ .missing = "auto" });
    pub const fetchPriority = reflect.enumerated("fetchpriority", &.{ "high", "low", "auto" }, .{ .missing = "auto" });
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{ .ce_reactions = true });

    // Obsolete
    pub const name = reflect.string("name");
    pub const lowsrc = reflect.url("lowsrc");
    pub const @"align" = reflect.string("align");
    pub const hspace = reflect.unsignedLong("hspace", .{});
    pub const vspace = reflect.unsignedLong("vspace", .{});
    pub const longDesc = reflect.url("longdesc");
    pub const border = reflect.stringNullToEmpty("border");

    pub const x = bridge.accessor(Image.getX, null, .{});
    pub const y = bridge.accessor(Image.getY, null, .{});
    pub const decode = bridge.function(Image.decode, .{});

    // After `constructor`.
    pub const browsingTopics = reflect.boolean("browsingtopics");
    pub const attributionSrc = reflect.string("attributionsrc");
    pub const sharedStorageWritable = reflect.boolean("sharedstoragewritable");
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}
