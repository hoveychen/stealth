// Which `<img loading=lazy>` is asked for, and which is not.
//
// `loading=lazy` is a request Chrome may never make: an image far enough below
// the fold is left alone until it scrolls near, and a run that never scrolls
// never asks. This engine asked for all of them, which is the same kind of tell
// as not asking at all -- visible in the origin's own access log, and in one
// direction only, so it separates cleanly. On iphey.com the FAQ's
// `chevron-up...svg` was the one path this engine requested and Chrome did not
// (tools/fingerprint/scratch/s48/waterfall.mjs, both arms).
//
// The distance is measured, not read off a spec: a local page with a lazy image
// at each of fifteen depths, counted in the server's access log with headless
// Chrome driving, drew the line between an image whose top sat 2018px down and
// one at 2418px, against an 800px viewport -- 1250px past the fold, which is
// Blink's root margin for a fast connection.
//
// The pass runs from `_documentIsLoaded` for the same reason
// frame/style_resources.zig does: an image's position is not known while the
// document is still being parsed, so the decision cannot be made at the
// insertion point where the eager ones are requested. `Image.imageAddedCallback`
// defers a lazy image to here instead of asking for it.
const std = @import("std");

const Frame = @import("../Frame.zig");
const Element = @import("../webapi/Element.zig");
const Image = @import("../webapi/element/html/Image.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");

/// How far past the bottom of the viewport a lazy image is still requested.
/// Blink's `LazyLoadImageObserver` margin for a 4G connection, and what the
/// local depth ladder measured.
pub const ROOT_MARGIN_PX: f64 = 1250;

/// Is this image's box near enough that Chrome would ask for it now?
///
/// Only meaningful once the document has been laid out, which is why nothing
/// calls it from the parse.
pub fn withinRange(element: *Element, frame: *Frame) bool {
    const rect = element.boundingClientRectValues(frame);
    // A box with no position at all -- an image in a `display:none` subtree --
    // measures at the origin, which reads as in-range. That is the same answer
    // as before this existed, and the safe one: the miss is a request Chrome
    // also makes.
    return rect.y < @as(f64, @floatFromInt(frame.viewport().height)) + ROOT_MARGIN_PX;
}

/// Ask for the lazy images the parse deferred and the fold did not hide.
pub fn requestAll(frame: *Frame) void {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) return;

    var tw = TreeWalker.Full.Elements.init(frame.document.asNode(), .{});
    while (tw.next()) |el| {
        if (!std.mem.eql(u8, el.getLocalName(), "img")) continue;
        const image = el.asNode().is(Image) orelse continue;
        if (!Image.isLazy(image)) continue;
        if (!withinRange(el, frame)) continue;
        // Straight back through the normal path, which by now sees a document
        // that is no longer `loading` and so asks rather than defers again.
        image.imageAddedCallback(frame) catch {};
    }
}
