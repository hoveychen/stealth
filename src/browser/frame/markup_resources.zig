// The subresources the markup names, beyond `<img src>`.
//
// `Frame.loadImage` covers images and frame/style_resources.zig covers what a
// stylesheet names. This is the third of the three: `<object data>`, `<embed
// src>`, `<input type=image src>`, `<svg><image href>`, a media element's
// poster and source, and `<track src>`. Measured with
// tools/fingerprint/wire-census.mjs -- one page naming a subresource in every
// way a page can -- these were seven of the fifteen paths Chrome asked the
// server for and this engine did not. (`<link rel=manifest>` and `<link
// rel=prefetch>`, the other two, belong with the rest of the rel handling in
// element/html/Link.zig.)
//
// Dispatch is by local name rather than by element type. `<image>` in an SVG
// is `SVGGraphicsElement` here, not a type of its own, and the rest read one
// attribute each: a switch on the name says what this does in one screen,
// where six `Build.created` hooks across six files would not.
//
// One walk of the finished document, from `_documentIsLoaded`, rather than a
// `Build.created` hook per element the way `<img>` does it. Two of these need
// something a per-element hook cannot give: a media element has to read its
// `<source>` children, which do not exist when it is created, and neither an
// SVG element nor a media element reaches `Build.created` at all -- only
// `createHtmlElementT` calls it, and both are built by their own factory path.
// The cost is that these requests go out after DOMContentLoaded instead of
// during the parse, so they trail the images rather than interleaving with
// them.
const std = @import("std");

const Frame = @import("../Frame.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const Element = @import("../webapi/Element.zig");

// What Chrome asks for, and what it does not:
//
//   * A `<video poster>` is fetched whatever `preload` says -- the poster is
//     the frame it shows before anything plays.
//   * The media itself is NOT fetched under `preload=none`; under the default
//     (`metadata`) it is. Over-fetching here is its own tell, so the
//     `preload=none` case is a control in markup_subresources.html.
//   * A `<source>` child stands in for a missing `src` attribute. Chrome picks
//     by `type`; nothing here decodes anything, so the first one wins.
pub fn requestAll(frame: *Frame) void {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) return;

    var tw = TreeWalker.Full.Elements.init(frame.document.asNode(), .{});
    while (tw.next()) |el| one(frame, el);
}

fn one(frame: *Frame, element: *Element) void {
    const name = element.getLocalName();

    if (std.mem.eql(u8, name, "object")) {
        return frame.requestElementResource(
            element.getAttributeSafe(comptime .wrap("data")) orelse return,
            .image,
            "object",
        );
    }
    if (std.mem.eql(u8, name, "embed")) {
        return frame.requestElementResource(
            element.getAttributeSafe(comptime .wrap("src")) orelse return,
            .image,
            "embed",
        );
    }
    if (std.mem.eql(u8, name, "image")) {
        // SVG's, which names its source with `href` (or the legacy
        // `xlink:href`). HTML's `<image>` is parsed as an `<img>` and never
        // reaches here under this name.
        const href = element.getAttributeSafe(comptime .wrap("href")) orelse
            element.getAttributeSafe(comptime .wrap("xlink:href")) orelse return;
        return frame.requestElementResource(href, .image, "image");
    }
    if (std.mem.eql(u8, name, "track")) {
        return frame.requestElementResource(
            element.getAttributeSafe(comptime .wrap("src")) orelse return,
            .fetch,
            "track",
        );
    }
    if (std.mem.eql(u8, name, "input")) {
        const kind = element.getAttributeSafe(comptime .wrap("type")) orelse return;
        if (!std.ascii.eqlIgnoreCase(kind, "image")) return;
        return frame.requestElementResource(
            element.getAttributeSafe(comptime .wrap("src")) orelse return,
            .image,
            "input",
        );
    }
    if (std.mem.eql(u8, name, "video") or std.mem.eql(u8, name, "audio")) {
        return media(frame, element, name);
    }
}

fn media(frame: *Frame, element: *Element, name: []const u8) void {
    if (std.mem.eql(u8, name, "video")) {
        if (element.getAttributeSafe(comptime .wrap("poster"))) |poster| {
            frame.requestElementResource(poster, .image, "video");
        }
    }

    const preload = element.getAttributeSafe(comptime .wrap("preload")) orelse "";
    if (std.ascii.eqlIgnoreCase(preload, "none")) return;

    if (element.getAttributeSafe(comptime .wrap("src"))) |src| {
        return frame.requestElementResource(src, .fetch, name);
    }

    var child = element.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        const el = node.is(Element) orelse continue;
        if (!std.mem.eql(u8, el.getLocalName(), "source")) continue;
        const src = el.getAttributeSafe(comptime .wrap("src")) orelse continue;
        return frame.requestElementResource(src, .fetch, "source");
    }
}
