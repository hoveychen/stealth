const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const MediaQuery = @import("../../../css/MediaQuery.zig");
const srcset = @import("srcset.zig");

const log = lp.log;
const String = lp.String;

const Image = @This();

pub const Proto = HtmlElement;

/// The intrinsic size the arriving bytes declared, or 0 while nothing has
/// arrived. Written by `Frame.applyIntrinsicSize` before the
/// `load` event fires, so a handler that reads `naturalWidth` sees it.
///
/// A field rather than one of Frame's side tables (`_element_scroll_positions`
/// and friends) because the two readers that need it cannot reach a frame:
/// `width` and `height` are reflected attributes, and reflection hands its
/// `undeclared` hook an element and nothing else.
_natural_width: u32 = 0,
_natural_height: u32 = 0,
_generation: u32 = 0,
// Per spec, false only while a fetch is in flight.
_complete: bool = true,

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
    const src = element.getAttributeInterned("src") orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

/// Chrome reports the candidate it chose, not the `src` it fell back from --
/// so a page that reads `currentSrc` after setting a srcset sees the same URL
/// the request went to. See `selectedSource`.
pub fn getCurrentSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const chosen = @constCast(self).selectedSource(frame) orelse return "";
    if (chosen.len == 0) return "";
    return self.asConstElement().asConstNode().resolveURLReflect(chosen, frame, .{});
}

pub fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeInterned("loading") orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

/// The size the arriving header declared. 0 until something arrives, which is
/// still the answer for an element with no src, for a request that failed, and
/// for bytes that were not a picture -- all three are states a real browser
/// reports 0 for too.
pub fn getNaturalWidth(self: *const Image) u32 {
    return self._natural_width;
}

pub fn getNaturalHeight(self: *const Image) u32 {
    return self._natural_height;
}

/// Records what the sniffed header said. Both numbers or neither: a size with
/// one axis zero is not a size, and `hasIntrinsicSize` keys off the pair.
pub fn setIntrinsicSize(self: *Image, width: u32, height: u32) void {
    if (width == 0 or height == 0) {
        return;
    }
    self._natural_width = width;
    self._natural_height = height;
}

/// Whether this <img> has bytes that became a picture with a size.
pub fn hasIntrinsicSize(self: *const Image) bool {
    return self._natural_width != 0 and self._natural_height != 0;
}

/// What `width` and `height` answer when no attribute declared one. They
/// report the rendered box rather than the attribute: a picture that arrived
/// renders at its intrinsic size, and a broken <img> renders as the
/// broken-image icon -- 16, where an element with no box at all reads 0.
/// Measured on Chrome 151 (probe `expr-broken-image.js`), which also answers 16
/// for `width="invalid"` and `width="-5"`: an attribute that declares nothing
/// usable leaves the box to speak, same as an absent one.
///
/// One function per axis, which the icon did not need: it is square, and the
/// intrinsic size is not.
fn undeclaredWidth(el: *Element) u32 {
    const image = el.as(Image);
    if (image.hasIntrinsicSize()) {
        return image._natural_width;
    }
    return brokenImageIcon(el);
}

fn undeclaredHeight(el: *Element) u32 {
    const image = el.as(Image);
    if (image.hasIntrinsicSize()) {
        return image._natural_height;
    }
    return brokenImageIcon(el);
}

fn brokenImageIcon(el: *Element) u32 {
    if (!el.hasBrokenImageBox()) {
        return 0;
    }
    return @intFromFloat(Element.broken_image_icon_size);
}

pub fn getComplete(self: *const Image) bool {
    // Per spec, false only while a fetch is in flight. Chrome with images off
    // leaves it false and fires nothing; answering an unconditional true beside
    // a naturalWidth of 0 was a shape only this engine produced.
    return self._complete;
}

/// Which URL this image actually asks the server for: the candidate a matching
/// `<source>` of an enclosing `<picture>` offers, else the srcset candidate
/// that fits the device, falling back to `src` when neither names anything
/// usable. See srcset.zig for the candidate arithmetic and `pictureSource` for
/// which `<source>` gets to supply the candidates.
///
/// One function for both readings on purpose: `currentSrc` and the URL that
/// goes out on the wire have to be the same string, or a page can tell the two
/// apart. Measured with tools/fingerprint/wire-census.mjs, which watches the
/// server rather than the page.
fn selectedSource(self: *Image, frame: *Frame) ?[]const u8 {
    if (pictureSource(self, frame)) |chosen| {
        return chosen;
    }
    const element = self.asElement();
    const src = element.getAttributeSafe(comptime .wrap("src"));
    const set = element.getAttributeSafe(comptime .wrap("srcset")) orelse return src;
    const sizes = element.getAttributeSafe(comptime .wrap("sizes")) orelse "";
    return srcset.select(set, sizes, VIEWPORT_WIDTH, DEVICE_PIXEL_RATIO) orelse src;
}

/// What the enclosing `<picture>` says to load, or null when there is no
/// picture or none of its `<source>` children apply -- in which case the img's
/// own `srcset`/`src` decide, which is what the fallback is for.
///
/// The first `<source>` that names candidates, declares a type this engine
/// would decode, and whose media condition holds wins; a later one never gets
/// looked at. All three rules and the accepted type list were read off Chrome
/// 151 with scratch/b94: `image/tiff`, `image/heic`, `image/jxl`, `image/*` and
/// a bare `png` are declined, while an absent or empty `type` is accepted, the
/// comparison ignores case and any `;` parameters, and a source with no
/// `srcset` is skipped rather than selecting nothing.
///
/// Dispatch is by local name, the way frame/markup_resources.zig does it: the
/// two element types would otherwise have to import each other.
fn pictureSource(self: *Image, frame: *Frame) ?[]const u8 {
    const node = self.asElement().asNode();
    const parent = node.parentElement() orelse return null;
    if (!std.mem.eql(u8, parent.getLocalName(), "picture")) return null;

    var child = parent.asNode().firstChild();
    while (child) |candidate| : (child = candidate.nextSibling()) {
        // The img ends the search: a `<source>` after it is never consulted.
        if (candidate == node) return null;
        const element = candidate.is(Element) orelse continue;
        if (!std.mem.eql(u8, element.getLocalName(), "source")) continue;

        const set = element.getAttributeSafe(comptime .wrap("srcset")) orelse continue;
        if (element.getAttributeSafe(comptime .wrap("type"))) |declared| {
            if (!decodableImageType(declared)) continue;
        }
        if (element.getAttributeSafe(comptime .wrap("media"))) |query| {
            if (query.len != 0 and !MediaQuery.matches(query, frame.viewport())) continue;
        }

        const sizes = element.getAttributeSafe(comptime .wrap("sizes")) orelse "";
        if (srcset.select(set, sizes, VIEWPORT_WIDTH, DEVICE_PIXEL_RATIO)) |url| {
            return url;
        }
    }
    return null;
}

/// Whether a `<source type>` names an image format this engine claims to
/// decode. The list is Chrome 151's answer, measured one MIME at a time
/// (scratch/b94/expr-types.js); it is not the set of formats anything here
/// actually decodes, because nothing here decodes any of them -- it is the set
/// a page can tell us apart by.
fn decodableImageType(declared: []const u8) bool {
    // `image/png; charset=utf-8` and `image/png ` are both accepted, so the
    // parameters and the surrounding space come off before the comparison.
    const semicolon = std.mem.indexOfScalar(u8, declared, ';') orelse declared.len;
    const name = std.mem.trim(u8, declared[0..semicolon], &std.ascii.whitespace);
    // An absent type says nothing, and so does an empty one.
    if (name.len == 0) return true;
    for (decodable_image_types) |supported| {
        if (std.ascii.eqlIgnoreCase(name, supported)) return true;
    }
    return false;
}

const decodable_image_types = [_][]const u8{
    "image/png",
    "image/apng",
    "image/jpeg",
    "image/jpg",
    "image/gif",
    "image/webp",
    "image/avif",
    "image/svg+xml",
    "image/bmp",
    "image/x-icon",
    "image/vnd.microsoft.icon",
    "image/x-xbitmap",
};

// Both are fixed parts of the device profile: see Viewport.default and
// Window.getDevicePixelRatio. Named here rather than read off the frame because
// they are the profile, not a window state: the same two numbers answer whether
// or not the element has been laid out.
const VIEWPORT_WIDTH: f64 = @floatFromInt(@import("../../../Viewport.zig").default.width);
const DEVICE_PIXEL_RATIO: f64 = 2;

/// Starts this image's request. Called from the parser's insertion point (see
/// `Frame._insertNodeRelative`) and from `setSrc`.
pub fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger a load event
    // or start fetching a resource.
    if (frame.isGoingAway()) {
        return;
    }

    self._generation +%= 1;
    self._complete = true;

    // The candidate wins over the `src`, and asking for BOTH would be a
    // request-count difference rather than a URL one -- the loudest kind. See
    // srcset.zig.
    const src = self.selectedSource(frame) orelse return;
    if (src.len == 0) return;

    // If image loading is off, the load event still has to fire: a page that
    // never sees one is separable from a browser.
    if (frame._session.load_resources.image == false) {
        return frame.queueLoad(Factory.protoOf(self));
    }

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
    pub const width = reflect.unsignedLong("width", .{ .undeclared = undeclaredWidth });
    pub const height = reflect.unsignedLong("height", .{ .undeclared = undeclaredHeight });
    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
    pub const currentSrc = bridge.accessor(Image.getCurrentSrc, null, .{});
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

// No `Build.created` hook: an `<img>` starts its request from the parser's
// insertion point instead, so that an img inside a `<picture>` can see the
// `<source>` siblings it takes its candidates from. See the `Element.Html.Image`
// branch in `Frame._insertNodeRelative`.
//
// Nothing is lost on the script path, which never reached the hook with a `src`
// to load: `document.createElement("img")` carries no attributes, and the `src`
// set afterwards arrives below.
pub const Build = struct {
    // Every way the attribute can be written -- `img.src = x`,
    // `setAttribute("src", x)`, a reassignment while a fetch is in flight --
    // lands here, which is why the hook is on the attribute and not on the
    // `src` setter.
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }

    // Removing the src leaves no request to make, but any in-flight one still
    // has to be invalidated -- `imageAddedCallback` bumps the generation the
    // response checks itself against.
    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        return element.as(Image).imageAddedCallback(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}

test "WebApi: HTML.Image fetch" {
    try testing.htmlRunner("element/html/image_fetch.html", .{ .load_resources = .{ .image = true } });
}
