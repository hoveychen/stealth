// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// The Sanitizer API's configuration object. It carries no sanitization: the
// interface has no `sanitize` operation at all (Chrome's prototype is the eleven
// members below), because the actual filtering is driven from
// `Element.setHTML`. So a Sanitizer *is* its config, and this file is that
// config with Chrome's own normalisation rules.
//
// Everything below was read off a headed Chrome 150
// (probe-win28/29/32/34/35). The rules the measurements pin down:
//
//   * `new Sanitizer()`, `new Sanitizer(undefined)` and `new Sanitizer('default')`
//     all give the built-in baseline: 121 elements, 58 global attributes,
//     comments false, dataAttributes false. Any other non-object argument is
//     "not a valid enum value of type SanitizerPresets"; `null` is an empty
//     dictionary, not a preset.
//   * A config is in *allow* mode or *remove* mode, separately for elements and
//     for attributes, and `get()` emits only the members that apply. Supplying
//     both sides ({elements, removeElements}), duplicate entries, or
//     dataAttributes without an attributes allow-list is
//     "Invalid Sanitizer configuration."
//   * A supplied dictionary defaults comments to *true*; the baseline has it
//     false. `dataAttributes` is emitted only when it has been set -- which the
//     baseline does (false), and an `attributes` allow-list does (true).
//   * Every list is kept sorted by (namespace URI, name), which is why the
//     baseline reads MathML, then HTML, then SVG: those URIs sort 1998 < 1999 <
//     2000. `replaceWithChildrenElements` is emitted only when non-empty.
//   * The mutators answer a boolean saying whether they changed the list they
//     apply to -- so `allowAttribute('title')` on a remove-mode config is false,
//     since 'title' was not on the remove list to begin with. setComments,
//     setDataAttributes and removeUnsafe answer undefined.
//   * `removeUnsafe()` drops (or, in remove mode, adds) five HTML and two SVG
//     elements and the 140 event-handler attributes. On the baseline nothing
//     changes: it already excludes all of them.
//   * allowProcessingInstruction / removeProcessingInstruction have no effect a
//     page can read; they answer false and true respectively.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Execution = js.Execution;

const Sanitizer = @This();

const Namespace = enum {
    /// An attribute with no namespace, which serialises as null.
    none,
    mathml,
    html,
    svg,

    fn uri(self: Namespace) ?[]const u8 {
        return switch (self) {
            .none => null,
            .mathml => "http://www.w3.org/1998/Math/MathML",
            .html => "http://www.w3.org/1999/xhtml",
            .svg => "http://www.w3.org/2000/svg",
        };
    }

    // The enum is declared in URI order, so the tag itself is the sort key.
    fn order(self: Namespace) u8 {
        return @intFromEnum(self);
    }
};

const Name = struct {
    name: []const u8,
    namespace: Namespace,

    fn eql(self: Name, other: Name) bool {
        return self.namespace == other.namespace and std.mem.eql(u8, self.name, other.name);
    }

    fn before(self: Name, other: Name) bool {
        if (self.namespace != other.namespace) {
            return self.namespace.order() < other.namespace.order();
        }
        return std.mem.order(u8, self.name, other.name) == .lt;
    }
};

const ElementEntry = struct {
    name: []const u8,
    namespace: Namespace,
    /// Exactly one of these is non-null: whichever key the config used for this
    /// element. An element added later gets an empty remove list, which is what
    /// a dictionary entry without either key normalises to.
    attributes: ?[]const Name = null,
    remove_attributes: ?[]const Name = &.{},

    fn asName(self: ElementEntry) Name {
        return .{ .name = self.name, .namespace = self.namespace };
    }
};

const baseline_elements = [_]ElementEntry{
    .{ .name = "math", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "merror", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mfrac", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mi", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mmultiscripts", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mn", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mo", .namespace = .mathml, .attributes = &.{ .{ .name = "fence", .namespace = .none }, .{ .name = "form", .namespace = .none }, .{ .name = "largeop", .namespace = .none }, .{ .name = "lspace", .namespace = .none }, .{ .name = "maxsize", .namespace = .none }, .{ .name = "minsize", .namespace = .none }, .{ .name = "movablelimits", .namespace = .none }, .{ .name = "rspace", .namespace = .none }, .{ .name = "separator", .namespace = .none }, .{ .name = "stretchy", .namespace = .none }, .{ .name = "symmetric", .namespace = .none } } },
    .{ .name = "mover", .namespace = .mathml, .attributes = &.{.{ .name = "accent", .namespace = .none }} },
    .{ .name = "mpadded", .namespace = .mathml, .attributes = &.{ .{ .name = "depth", .namespace = .none }, .{ .name = "height", .namespace = .none }, .{ .name = "lspace", .namespace = .none }, .{ .name = "voffset", .namespace = .none }, .{ .name = "width", .namespace = .none } } },
    .{ .name = "mphantom", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mprescripts", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mroot", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mrow", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "ms", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mspace", .namespace = .mathml, .attributes = &.{ .{ .name = "depth", .namespace = .none }, .{ .name = "height", .namespace = .none }, .{ .name = "width", .namespace = .none } } },
    .{ .name = "msqrt", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mstyle", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "msub", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "msubsup", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "msup", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mtable", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mtd", .namespace = .mathml, .attributes = &.{ .{ .name = "columnspan", .namespace = .none }, .{ .name = "rowspan", .namespace = .none } } },
    .{ .name = "mtext", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "mtr", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "munder", .namespace = .mathml, .attributes = &.{.{ .name = "accentunder", .namespace = .none }} },
    .{ .name = "munderover", .namespace = .mathml, .attributes = &.{ .{ .name = "accent", .namespace = .none }, .{ .name = "accentunder", .namespace = .none } } },
    .{ .name = "semantics", .namespace = .mathml, .attributes = &.{} },
    .{ .name = "a", .namespace = .html, .attributes = &.{ .{ .name = "href", .namespace = .none }, .{ .name = "hreflang", .namespace = .none }, .{ .name = "type", .namespace = .none } } },
    .{ .name = "abbr", .namespace = .html, .attributes = &.{} },
    .{ .name = "address", .namespace = .html, .attributes = &.{} },
    .{ .name = "article", .namespace = .html, .attributes = &.{} },
    .{ .name = "aside", .namespace = .html, .attributes = &.{} },
    .{ .name = "b", .namespace = .html, .attributes = &.{} },
    .{ .name = "bdi", .namespace = .html, .attributes = &.{} },
    .{ .name = "bdo", .namespace = .html, .attributes = &.{} },
    .{ .name = "blockquote", .namespace = .html, .attributes = &.{.{ .name = "cite", .namespace = .none }} },
    .{ .name = "body", .namespace = .html, .attributes = &.{} },
    .{ .name = "br", .namespace = .html, .attributes = &.{} },
    .{ .name = "caption", .namespace = .html, .attributes = &.{} },
    .{ .name = "cite", .namespace = .html, .attributes = &.{} },
    .{ .name = "code", .namespace = .html, .attributes = &.{} },
    .{ .name = "col", .namespace = .html, .attributes = &.{.{ .name = "span", .namespace = .none }} },
    .{ .name = "colgroup", .namespace = .html, .attributes = &.{.{ .name = "span", .namespace = .none }} },
    .{ .name = "data", .namespace = .html, .attributes = &.{.{ .name = "value", .namespace = .none }} },
    .{ .name = "dd", .namespace = .html, .attributes = &.{} },
    .{ .name = "del", .namespace = .html, .attributes = &.{ .{ .name = "cite", .namespace = .none }, .{ .name = "datetime", .namespace = .none } } },
    .{ .name = "dfn", .namespace = .html, .attributes = &.{} },
    .{ .name = "div", .namespace = .html, .attributes = &.{} },
    .{ .name = "dl", .namespace = .html, .attributes = &.{} },
    .{ .name = "dt", .namespace = .html, .attributes = &.{} },
    .{ .name = "em", .namespace = .html, .attributes = &.{} },
    .{ .name = "figcaption", .namespace = .html, .attributes = &.{} },
    .{ .name = "figure", .namespace = .html, .attributes = &.{} },
    .{ .name = "footer", .namespace = .html, .attributes = &.{} },
    .{ .name = "h1", .namespace = .html, .attributes = &.{} },
    .{ .name = "h2", .namespace = .html, .attributes = &.{} },
    .{ .name = "h3", .namespace = .html, .attributes = &.{} },
    .{ .name = "h4", .namespace = .html, .attributes = &.{} },
    .{ .name = "h5", .namespace = .html, .attributes = &.{} },
    .{ .name = "h6", .namespace = .html, .attributes = &.{} },
    .{ .name = "head", .namespace = .html, .attributes = &.{} },
    .{ .name = "header", .namespace = .html, .attributes = &.{} },
    .{ .name = "hgroup", .namespace = .html, .attributes = &.{} },
    .{ .name = "hr", .namespace = .html, .attributes = &.{} },
    .{ .name = "html", .namespace = .html, .attributes = &.{} },
    .{ .name = "i", .namespace = .html, .attributes = &.{} },
    .{ .name = "ins", .namespace = .html, .attributes = &.{ .{ .name = "cite", .namespace = .none }, .{ .name = "datetime", .namespace = .none } } },
    .{ .name = "kbd", .namespace = .html, .attributes = &.{} },
    .{ .name = "li", .namespace = .html, .attributes = &.{.{ .name = "value", .namespace = .none }} },
    .{ .name = "main", .namespace = .html, .attributes = &.{} },
    .{ .name = "mark", .namespace = .html, .attributes = &.{} },
    .{ .name = "menu", .namespace = .html, .attributes = &.{} },
    .{ .name = "nav", .namespace = .html, .attributes = &.{} },
    .{ .name = "ol", .namespace = .html, .attributes = &.{ .{ .name = "reversed", .namespace = .none }, .{ .name = "start", .namespace = .none }, .{ .name = "type", .namespace = .none } } },
    .{ .name = "p", .namespace = .html, .attributes = &.{} },
    .{ .name = "pre", .namespace = .html, .attributes = &.{} },
    .{ .name = "q", .namespace = .html, .attributes = &.{} },
    .{ .name = "rp", .namespace = .html, .attributes = &.{} },
    .{ .name = "rt", .namespace = .html, .attributes = &.{} },
    .{ .name = "ruby", .namespace = .html, .attributes = &.{} },
    .{ .name = "s", .namespace = .html, .attributes = &.{} },
    .{ .name = "samp", .namespace = .html, .attributes = &.{} },
    .{ .name = "search", .namespace = .html, .attributes = &.{} },
    .{ .name = "section", .namespace = .html, .attributes = &.{} },
    .{ .name = "small", .namespace = .html, .attributes = &.{} },
    .{ .name = "span", .namespace = .html, .attributes = &.{} },
    .{ .name = "strong", .namespace = .html, .attributes = &.{} },
    .{ .name = "sub", .namespace = .html, .attributes = &.{} },
    .{ .name = "sup", .namespace = .html, .attributes = &.{} },
    .{ .name = "table", .namespace = .html, .attributes = &.{} },
    .{ .name = "tbody", .namespace = .html, .attributes = &.{} },
    .{ .name = "td", .namespace = .html, .attributes = &.{ .{ .name = "colspan", .namespace = .none }, .{ .name = "headers", .namespace = .none }, .{ .name = "rowspan", .namespace = .none } } },
    .{ .name = "tfoot", .namespace = .html, .attributes = &.{} },
    .{ .name = "th", .namespace = .html, .attributes = &.{ .{ .name = "abbr", .namespace = .none }, .{ .name = "colspan", .namespace = .none }, .{ .name = "headers", .namespace = .none }, .{ .name = "rowspan", .namespace = .none }, .{ .name = "scope", .namespace = .none } } },
    .{ .name = "thead", .namespace = .html, .attributes = &.{} },
    .{ .name = "time", .namespace = .html, .attributes = &.{.{ .name = "datetime", .namespace = .none }} },
    .{ .name = "title", .namespace = .html, .attributes = &.{} },
    .{ .name = "tr", .namespace = .html, .attributes = &.{} },
    .{ .name = "u", .namespace = .html, .attributes = &.{} },
    .{ .name = "ul", .namespace = .html, .attributes = &.{} },
    .{ .name = "var", .namespace = .html, .attributes = &.{} },
    .{ .name = "wbr", .namespace = .html, .attributes = &.{} },
    .{ .name = "a", .namespace = .svg, .attributes = &.{ .{ .name = "href", .namespace = .none }, .{ .name = "hreflang", .namespace = .none }, .{ .name = "type", .namespace = .none } } },
    .{ .name = "circle", .namespace = .svg, .attributes = &.{ .{ .name = "cx", .namespace = .none }, .{ .name = "cy", .namespace = .none }, .{ .name = "pathLength", .namespace = .none }, .{ .name = "r", .namespace = .none } } },
    .{ .name = "defs", .namespace = .svg, .attributes = &.{} },
    .{ .name = "desc", .namespace = .svg, .attributes = &.{} },
    .{ .name = "ellipse", .namespace = .svg, .attributes = &.{ .{ .name = "cx", .namespace = .none }, .{ .name = "cy", .namespace = .none }, .{ .name = "pathLength", .namespace = .none }, .{ .name = "rx", .namespace = .none }, .{ .name = "ry", .namespace = .none } } },
    .{ .name = "foreignObject", .namespace = .svg, .attributes = &.{ .{ .name = "height", .namespace = .none }, .{ .name = "width", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "g", .namespace = .svg, .attributes = &.{} },
    .{ .name = "line", .namespace = .svg, .attributes = &.{ .{ .name = "pathLength", .namespace = .none }, .{ .name = "x1", .namespace = .none }, .{ .name = "x2", .namespace = .none }, .{ .name = "y1", .namespace = .none }, .{ .name = "y2", .namespace = .none } } },
    .{ .name = "marker", .namespace = .svg, .attributes = &.{ .{ .name = "markerHeight", .namespace = .none }, .{ .name = "markerUnits", .namespace = .none }, .{ .name = "markerWidth", .namespace = .none }, .{ .name = "orient", .namespace = .none }, .{ .name = "preserveAspectRatio", .namespace = .none }, .{ .name = "refX", .namespace = .none }, .{ .name = "refY", .namespace = .none }, .{ .name = "viewBox", .namespace = .none } } },
    .{ .name = "metadata", .namespace = .svg, .attributes = &.{} },
    .{ .name = "path", .namespace = .svg, .attributes = &.{ .{ .name = "d", .namespace = .none }, .{ .name = "pathLength", .namespace = .none } } },
    .{ .name = "polygon", .namespace = .svg, .attributes = &.{ .{ .name = "pathLength", .namespace = .none }, .{ .name = "points", .namespace = .none } } },
    .{ .name = "polyline", .namespace = .svg, .attributes = &.{ .{ .name = "pathLength", .namespace = .none }, .{ .name = "points", .namespace = .none } } },
    .{ .name = "rect", .namespace = .svg, .attributes = &.{ .{ .name = "height", .namespace = .none }, .{ .name = "pathLength", .namespace = .none }, .{ .name = "rx", .namespace = .none }, .{ .name = "ry", .namespace = .none }, .{ .name = "width", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "svg", .namespace = .svg, .attributes = &.{ .{ .name = "height", .namespace = .none }, .{ .name = "preserveAspectRatio", .namespace = .none }, .{ .name = "viewBox", .namespace = .none }, .{ .name = "width", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "text", .namespace = .svg, .attributes = &.{ .{ .name = "dx", .namespace = .none }, .{ .name = "dy", .namespace = .none }, .{ .name = "lengthAdjust", .namespace = .none }, .{ .name = "rotate", .namespace = .none }, .{ .name = "textLength", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
    .{ .name = "textPath", .namespace = .svg, .attributes = &.{ .{ .name = "lengthAdjust", .namespace = .none }, .{ .name = "method", .namespace = .none }, .{ .name = "path", .namespace = .none }, .{ .name = "side", .namespace = .none }, .{ .name = "spacing", .namespace = .none }, .{ .name = "startOffset", .namespace = .none }, .{ .name = "textLength", .namespace = .none } } },
    .{ .name = "title", .namespace = .svg, .attributes = &.{} },
    .{ .name = "tspan", .namespace = .svg, .attributes = &.{ .{ .name = "dx", .namespace = .none }, .{ .name = "dy", .namespace = .none }, .{ .name = "lengthAdjust", .namespace = .none }, .{ .name = "rotate", .namespace = .none }, .{ .name = "textLength", .namespace = .none }, .{ .name = "x", .namespace = .none }, .{ .name = "y", .namespace = .none } } },
};

const baseline_attributes = [_]Name{
    .{ .name = "alignment-baseline", .namespace = .none },
    .{ .name = "baseline-shift", .namespace = .none },
    .{ .name = "clip-path", .namespace = .none },
    .{ .name = "clip-rule", .namespace = .none },
    .{ .name = "color", .namespace = .none },
    .{ .name = "color-interpolation", .namespace = .none },
    .{ .name = "cursor", .namespace = .none },
    .{ .name = "dir", .namespace = .none },
    .{ .name = "direction", .namespace = .none },
    .{ .name = "display", .namespace = .none },
    .{ .name = "displaystyle", .namespace = .none },
    .{ .name = "dominant-baseline", .namespace = .none },
    .{ .name = "fill", .namespace = .none },
    .{ .name = "fill-opacity", .namespace = .none },
    .{ .name = "fill-rule", .namespace = .none },
    .{ .name = "font-family", .namespace = .none },
    .{ .name = "font-size", .namespace = .none },
    .{ .name = "font-size-adjust", .namespace = .none },
    .{ .name = "font-stretch", .namespace = .none },
    .{ .name = "font-style", .namespace = .none },
    .{ .name = "font-variant", .namespace = .none },
    .{ .name = "font-weight", .namespace = .none },
    .{ .name = "lang", .namespace = .none },
    .{ .name = "letter-spacing", .namespace = .none },
    .{ .name = "marker-end", .namespace = .none },
    .{ .name = "marker-mid", .namespace = .none },
    .{ .name = "marker-start", .namespace = .none },
    .{ .name = "mathbackground", .namespace = .none },
    .{ .name = "mathcolor", .namespace = .none },
    .{ .name = "mathsize", .namespace = .none },
    .{ .name = "opacity", .namespace = .none },
    .{ .name = "paint-order", .namespace = .none },
    .{ .name = "pointer-events", .namespace = .none },
    .{ .name = "scriptlevel", .namespace = .none },
    .{ .name = "shape-rendering", .namespace = .none },
    .{ .name = "stop-color", .namespace = .none },
    .{ .name = "stop-opacity", .namespace = .none },
    .{ .name = "stroke", .namespace = .none },
    .{ .name = "stroke-dasharray", .namespace = .none },
    .{ .name = "stroke-dashoffset", .namespace = .none },
    .{ .name = "stroke-linecap", .namespace = .none },
    .{ .name = "stroke-linejoin", .namespace = .none },
    .{ .name = "stroke-miterlimit", .namespace = .none },
    .{ .name = "stroke-opacity", .namespace = .none },
    .{ .name = "stroke-width", .namespace = .none },
    .{ .name = "text-anchor", .namespace = .none },
    .{ .name = "text-decoration", .namespace = .none },
    .{ .name = "text-overflow", .namespace = .none },
    .{ .name = "text-rendering", .namespace = .none },
    .{ .name = "title", .namespace = .none },
    .{ .name = "transform", .namespace = .none },
    .{ .name = "transform-origin", .namespace = .none },
    .{ .name = "unicode-bidi", .namespace = .none },
    .{ .name = "vector-effect", .namespace = .none },
    .{ .name = "visibility", .namespace = .none },
    .{ .name = "white-space", .namespace = .none },
    .{ .name = "word-spacing", .namespace = .none },
    .{ .name = "writing-mode", .namespace = .none },
};

const unsafe_attributes = [_]Name{
    .{ .name = "onabort", .namespace = .none },                            .{ .name = "onactivate", .namespace = .none },
    .{ .name = "onafterprint", .namespace = .none },                       .{ .name = "onanimationcancel", .namespace = .none },
    .{ .name = "onanimationend", .namespace = .none },                     .{ .name = "onanimationiteration", .namespace = .none },
    .{ .name = "onanimationstart", .namespace = .none },                   .{ .name = "onautofill", .namespace = .none },
    .{ .name = "onauxclick", .namespace = .none },                         .{ .name = "onbeforecopy", .namespace = .none },
    .{ .name = "onbeforecut", .namespace = .none },                        .{ .name = "onbeforefilter", .namespace = .none },
    .{ .name = "onbeforeinput", .namespace = .none },                      .{ .name = "onbeforepaste", .namespace = .none },
    .{ .name = "onbeforeprint", .namespace = .none },                      .{ .name = "onbeforetoggle", .namespace = .none },
    .{ .name = "onbeforeunload", .namespace = .none },                     .{ .name = "onbegin", .namespace = .none },
    .{ .name = "onblur", .namespace = .none },                             .{ .name = "oncancel", .namespace = .none },
    .{ .name = "oncanplay", .namespace = .none },                          .{ .name = "oncanplaythrough", .namespace = .none },
    .{ .name = "onchange", .namespace = .none },                           .{ .name = "onclick", .namespace = .none },
    .{ .name = "onclose", .namespace = .none },                            .{ .name = "oncommand", .namespace = .none },
    .{ .name = "oncontentvisibilityautostatechange", .namespace = .none }, .{ .name = "oncontextlost", .namespace = .none },
    .{ .name = "oncontextmenu", .namespace = .none },                      .{ .name = "oncontextrestored", .namespace = .none },
    .{ .name = "oncopy", .namespace = .none },                             .{ .name = "oncuechange", .namespace = .none },
    .{ .name = "oncut", .namespace = .none },                              .{ .name = "ondblclick", .namespace = .none },
    .{ .name = "ondismiss", .namespace = .none },                          .{ .name = "ondrag", .namespace = .none },
    .{ .name = "ondragend", .namespace = .none },                          .{ .name = "ondragenter", .namespace = .none },
    .{ .name = "ondragleave", .namespace = .none },                        .{ .name = "ondragover", .namespace = .none },
    .{ .name = "ondragstart", .namespace = .none },                        .{ .name = "ondrop", .namespace = .none },
    .{ .name = "ondurationchange", .namespace = .none },                   .{ .name = "onemptied", .namespace = .none },
    .{ .name = "onend", .namespace = .none },                              .{ .name = "onended", .namespace = .none },
    .{ .name = "onerror", .namespace = .none },                            .{ .name = "onfocus", .namespace = .none },
    .{ .name = "onfocusin", .namespace = .none },                          .{ .name = "onfocusout", .namespace = .none },
    .{ .name = "onformdata", .namespace = .none },                         .{ .name = "ongotpointercapture", .namespace = .none },
    .{ .name = "onhashchange", .namespace = .none },                       .{ .name = "oninput", .namespace = .none },
    .{ .name = "oninvalid", .namespace = .none },                          .{ .name = "onkeydown", .namespace = .none },
    .{ .name = "onkeypress", .namespace = .none },                         .{ .name = "onkeyup", .namespace = .none },
    .{ .name = "onlanguagechange", .namespace = .none },                   .{ .name = "onload", .namespace = .none },
    .{ .name = "onloadeddata", .namespace = .none },                       .{ .name = "onloadedmetadata", .namespace = .none },
    .{ .name = "onloadstart", .namespace = .none },                        .{ .name = "onlocation", .namespace = .none },
    .{ .name = "onlostpointercapture", .namespace = .none },               .{ .name = "onmessage", .namespace = .none },
    .{ .name = "onmessageerror", .namespace = .none },                     .{ .name = "onmousedown", .namespace = .none },
    .{ .name = "onmouseenter", .namespace = .none },                       .{ .name = "onmouseleave", .namespace = .none },
    .{ .name = "onmousemove", .namespace = .none },                        .{ .name = "onmouseout", .namespace = .none },
    .{ .name = "onmouseover", .namespace = .none },                        .{ .name = "onmouseup", .namespace = .none },
    .{ .name = "onmousewheel", .namespace = .none },                       .{ .name = "onmove", .namespace = .none },
    .{ .name = "onoffline", .namespace = .none },                          .{ .name = "ononline", .namespace = .none },
    .{ .name = "onorientationchange", .namespace = .none },                .{ .name = "onpagehide", .namespace = .none },
    .{ .name = "onpageshow", .namespace = .none },                         .{ .name = "onpaste", .namespace = .none },
    .{ .name = "onpause", .namespace = .none },                            .{ .name = "onplay", .namespace = .none },
    .{ .name = "onplaying", .namespace = .none },                          .{ .name = "onpointercancel", .namespace = .none },
    .{ .name = "onpointerdown", .namespace = .none },                      .{ .name = "onpointerenter", .namespace = .none },
    .{ .name = "onpointerleave", .namespace = .none },                     .{ .name = "onpointermove", .namespace = .none },
    .{ .name = "onpointerout", .namespace = .none },                       .{ .name = "onpointerover", .namespace = .none },
    .{ .name = "onpointerrawupdate", .namespace = .none },                 .{ .name = "onpointerup", .namespace = .none },
    .{ .name = "onpopstate", .namespace = .none },                         .{ .name = "onprogress", .namespace = .none },
    .{ .name = "onpromptaction", .namespace = .none },                     .{ .name = "onpromptdismiss", .namespace = .none },
    .{ .name = "onratechange", .namespace = .none },                       .{ .name = "onrepeat", .namespace = .none },
    .{ .name = "onreset", .namespace = .none },                            .{ .name = "onresize", .namespace = .none },
    .{ .name = "onresolve", .namespace = .none },                          .{ .name = "onscroll", .namespace = .none },
    .{ .name = "onscrollend", .namespace = .none },                        .{ .name = "onscrollsnapchange", .namespace = .none },
    .{ .name = "onscrollsnapchanging", .namespace = .none },               .{ .name = "onsearch", .namespace = .none },
    .{ .name = "onsecuritypolicyviolation", .namespace = .none },          .{ .name = "onseeked", .namespace = .none },
    .{ .name = "onseeking", .namespace = .none },                          .{ .name = "onselect", .namespace = .none },
    .{ .name = "onselectionchange", .namespace = .none },                  .{ .name = "onselectstart", .namespace = .none },
    .{ .name = "onshow", .namespace = .none },                             .{ .name = "onslotchange", .namespace = .none },
    .{ .name = "onstalled", .namespace = .none },                          .{ .name = "onstorage", .namespace = .none },
    .{ .name = "onstream", .namespace = .none },                           .{ .name = "onsubmit", .namespace = .none },
    .{ .name = "onsuspend", .namespace = .none },                          .{ .name = "ontimeupdate", .namespace = .none },
    .{ .name = "ontimezonechange", .namespace = .none },                   .{ .name = "ontoggle", .namespace = .none },
    .{ .name = "ontouchcancel", .namespace = .none },                      .{ .name = "ontouchend", .namespace = .none },
    .{ .name = "ontouchmove", .namespace = .none },                        .{ .name = "ontouchstart", .namespace = .none },
    .{ .name = "ontransitionend", .namespace = .none },                    .{ .name = "onunload", .namespace = .none },
    .{ .name = "onvalidationstatuschange", .namespace = .none },           .{ .name = "onvolumechange", .namespace = .none },
    .{ .name = "onwaiting", .namespace = .none },                          .{ .name = "onwebkitanimationend", .namespace = .none },
    .{ .name = "onwebkitanimationiteration", .namespace = .none },         .{ .name = "onwebkitanimationstart", .namespace = .none },
    .{ .name = "onwebkitfullscreenchange", .namespace = .none },           .{ .name = "onwebkitfullscreenerror", .namespace = .none },
    .{ .name = "onwebkittransitionend", .namespace = .none },              .{ .name = "onwheel", .namespace = .none },
};

const unsafe_elements = [_]Name{
    .{ .name = "embed", .namespace = .html },
    .{ .name = "frame", .namespace = .html },
    .{ .name = "iframe", .namespace = .html },
    .{ .name = "object", .namespace = .html },
    .{ .name = "script", .namespace = .html },
    .{ .name = "script", .namespace = .svg },
    .{ .name = "use", .namespace = .svg },
};

_rc: lp.RC = .{},
_arena: *lp.Arena,
_comments: bool,
_data_attributes: ?bool,
/// Element mode: exactly one of these is non-null.
_elements: ?std.ArrayList(ElementEntry),
_remove_elements: ?std.ArrayList(Name),
/// Attribute mode: exactly one of these is non-null.
_attributes: ?std.ArrayList(Name),
_remove_attributes: ?std.ArrayList(Name),
_replace_with_children: std.ArrayList(Name),

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn invalidConfiguration(exec: *const Execution) anyerror {
    return throwTypeError("Failed to construct 'Sanitizer': Invalid Sanitizer configuration.", exec);
}

pub fn constructor(config_: ?js.Value, exec: *const Execution) !*Sanitizer {
    const arena = try exec.getArena(.small, "Sanitizer");
    errdefer arena.release();

    const allocator = arena.allocator();
    const self = try arena.create(Sanitizer);

    const config = config_ orelse {
        try self.initBaseline(arena);
        return self;
    };
    if (config.isUndefined()) {
        try self.initBaseline(arena);
        return self;
    }
    if (!config.isNull() and !config.isObject()) {
        const preset = try config.toStringSlice();
        if (std.mem.eql(u8, preset, "default")) {
            try self.initBaseline(arena);
            return self;
        }
        const message = try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to construct 'Sanitizer': The provided value '{s}' is not a valid enum value of type SanitizerPresets.",
            .{preset},
        );
        return throwTypeError(message, exec);
    }

    // A dictionary -- `null` reads as an empty one.
    const object: ?js.Object = if (config.isNull()) null else config.toObject();

    const elements = try readElements(object, "elements", allocator, exec);
    const remove_elements = try readNames(object, "removeElements", .html, allocator, exec);
    const attributes = try readNames(object, "attributes", .none, allocator, exec);
    const remove_attributes = try readNames(object, "removeAttributes", .none, allocator, exec);
    const replace = try readNames(object, "replaceWithChildrenElements", .html, allocator, exec);
    const data_attributes = try readBool(object, "dataAttributes");

    if (elements != null and remove_elements != null) {
        return invalidConfiguration(exec);
    }
    if (attributes != null and remove_attributes != null) {
        return invalidConfiguration(exec);
    }
    // dataAttributes only means something alongside an attribute allow-list.
    if (data_attributes != null and attributes == null) {
        return invalidConfiguration(exec);
    }

    self.* = .{
        ._arena = arena,
        ._comments = (try readBool(object, "comments")) orelse true,
        ._data_attributes = if (attributes != null) (data_attributes orelse true) else null,
        ._elements = elements,
        ._remove_elements = if (elements == null) (remove_elements orelse .empty) else null,
        ._attributes = attributes,
        ._remove_attributes = if (attributes == null) (remove_attributes orelse .empty) else null,
        ._replace_with_children = replace orelse .empty,
    };

    if (self._elements) |*list| {
        sortElements(list);
        if (hasDuplicateElements(list.items)) {
            return invalidConfiguration(exec);
        }
    }
    inline for (.{ &self._remove_elements, &self._attributes, &self._remove_attributes }) |maybe| {
        if (maybe.*) |*list| {
            sortNames(list);
            if (hasDuplicateNames(list.items)) {
                return invalidConfiguration(exec);
            }
        }
    }
    sortNames(&self._replace_with_children);
    if (hasDuplicateNames(self._replace_with_children.items)) {
        return invalidConfiguration(exec);
    }
    return self;
}

fn initBaseline(self: *Sanitizer, arena: *lp.Arena) !void {
    var elements: std.ArrayList(ElementEntry) = .empty;
    try elements.appendSlice(arena.allocator(), &baseline_elements);

    var attributes: std.ArrayList(Name) = .empty;
    try attributes.appendSlice(arena.allocator(), &baseline_attributes);

    self.* = .{
        ._arena = arena,
        ._comments = false,
        ._data_attributes = false,
        ._elements = elements,
        ._remove_elements = null,
        ._attributes = attributes,
        ._remove_attributes = null,
        ._replace_with_children = .empty,
    };
}

pub fn deinit(self: *Sanitizer, _: *Page) void {
    // Frees every list and this Sanitizer itself.
    self._arena.release();
}

pub fn releaseRef(self: *Sanitizer, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Sanitizer) void {
    self._rc.acquire();
}

// -- reading the dictionary --------------------------------------------------

fn readBool(object_: ?js.Object, comptime name: []const u8) !?bool {
    const object = object_ orelse return null;
    const member = try object.get(name);
    if (member.isUndefined()) {
        return null;
    }
    return member.toBool();
}

fn sequenceOf(
    object_: ?js.Object,
    comptime name: []const u8,
    exec: *const Execution,
) !?js.Array {
    const object = object_ orelse return null;
    const member = try object.get(name);
    if (member.isUndefined()) {
        return null;
    }
    if (!member.isArray()) {
        return throwTypeError(
            "Failed to construct 'Sanitizer': Failed to read the '" ++ name ++
                "' property from 'SanitizerConfig': The provided value cannot be converted to a sequence.",
            exec,
        );
    }
    return member.toArray();
}

/// A `sequence<SanitizerAttribute>` or `sequence<SanitizerElement>` reduced to
/// names only. A bare string takes `fallback` as its namespace.
fn readNames(
    object_: ?js.Object,
    comptime name: []const u8,
    comptime fallback: Namespace,
    allocator: std.mem.Allocator,
    exec: *const Execution,
) !?std.ArrayList(Name) {
    const array = (try sequenceOf(object_, name, exec)) orelse return null;

    var list: std.ArrayList(Name) = .empty;
    for (0..array.len()) |i| {
        const item = try array.get(@intCast(i));
        try list.append(allocator, try readName(item, fallback, "Failed to construct 'Sanitizer'", allocator, exec));
    }
    return list;
}

fn readElements(
    object_: ?js.Object,
    comptime name: []const u8,
    allocator: std.mem.Allocator,
    exec: *const Execution,
) !?std.ArrayList(ElementEntry) {
    const array = (try sequenceOf(object_, name, exec)) orelse return null;

    var list: std.ArrayList(ElementEntry) = .empty;
    for (0..array.len()) |i| {
        const item = try array.get(@intCast(i));
        const element = try readName(item, .html, "Failed to construct 'Sanitizer'", allocator, exec);

        var entry: ElementEntry = .{ .name = element.name, .namespace = element.namespace };
        if (item.isObject()) {
            const object = item.toObject();
            if (try readNames(object, "attributes", .none, allocator, exec)) |attributes| {
                entry.attributes = attributes.items;
                entry.remove_attributes = null;
            } else if (try readNames(object, "removeAttributes", .none, allocator, exec)) |remove| {
                entry.remove_attributes = remove.items;
            }
        }
        try list.append(allocator, entry);
    }
    return list;
}

/// A SanitizerElement / SanitizerAttribute: either a bare name, or a dictionary
/// whose `name` member is required.
fn readName(
    value: js.Value,
    comptime fallback: Namespace,
    comptime where: []const u8,
    allocator: std.mem.Allocator,
    exec: *const Execution,
) !Name {
    if (!value.isObject()) {
        return .{
            .name = try value.toStringSliceWithAlloc(allocator),
            .namespace = fallback,
        };
    }

    const object = value.toObject();
    const member = try object.get("name");
    if (member.isUndefined()) {
        return throwTypeError(
            where ++ ": Failed to read the 'name' property from 'SanitizerElementNamespace': Required member is undefined.",
            exec,
        );
    }

    const namespace = try object.get("namespace");
    return .{
        .name = try member.toStringSliceWithAlloc(allocator),
        .namespace = if (namespace.isNullOrUndefined())
            fallback
        else
            namespaceFromUri(try namespace.toStringSlice()) orelse fallback,
    };
}

fn namespaceFromUri(uri: []const u8) ?Namespace {
    inline for (.{ Namespace.mathml, Namespace.html, Namespace.svg }) |candidate| {
        if (std.mem.eql(u8, uri, candidate.uri().?)) {
            return candidate;
        }
    }
    return null;
}

// -- list maintenance -------------------------------------------------------

fn lessThanName(_: void, a: Name, b: Name) bool {
    return a.before(b);
}

fn lessThanElement(_: void, a: ElementEntry, b: ElementEntry) bool {
    return a.asName().before(b.asName());
}

fn sortNames(list: *std.ArrayList(Name)) void {
    std.mem.sort(Name, list.items, {}, lessThanName);
}

fn sortElements(list: *std.ArrayList(ElementEntry)) void {
    std.mem.sort(ElementEntry, list.items, {}, lessThanElement);
}

fn hasDuplicateNames(items: []const Name) bool {
    if (items.len < 2) return false;
    for (items[1..], 0..) |item, i| {
        if (item.eql(items[i])) return true;
    }
    return false;
}

fn hasDuplicateElements(items: []const ElementEntry) bool {
    if (items.len < 2) return false;
    for (items[1..], 0..) |item, i| {
        if (item.asName().eql(items[i].asName())) return true;
    }
    return false;
}

fn insertName(list: *std.ArrayList(Name), allocator: std.mem.Allocator, name: Name) !bool {
    for (list.items) |item| {
        if (item.eql(name)) return false;
    }
    try list.append(allocator, name);
    sortNames(list);
    return true;
}

fn deleteName(list: *std.ArrayList(Name), name: Name) bool {
    for (list.items, 0..) |item, i| {
        if (item.eql(name)) {
            _ = list.orderedRemove(i);
            return true;
        }
    }
    return false;
}

fn insertElement(list: *std.ArrayList(ElementEntry), allocator: std.mem.Allocator, name: Name) !bool {
    for (list.items) |item| {
        if (item.asName().eql(name)) return false;
    }
    try list.append(allocator, .{ .name = name.name, .namespace = name.namespace });
    sortElements(list);
    return true;
}

fn deleteElement(list: *std.ArrayList(ElementEntry), name: Name) bool {
    for (list.items, 0..) |item, i| {
        if (item.asName().eql(name)) {
            _ = list.orderedRemove(i);
            return true;
        }
    }
    return false;
}

// -- operations -------------------------------------------------------------

fn requireArg(
    comptime member: []const u8,
    args: []js.Value,
    exec: *const Execution,
) !js.Value {
    if (args.len == 0) {
        return throwTypeError(
            "Failed to execute '" ++ member ++ "' on 'Sanitizer': 1 argument required, but only 0 present.",
            exec,
        );
    }
    return args[0];
}

fn argName(
    comptime member: []const u8,
    comptime fallback: Namespace,
    args: []js.Value,
    self: *Sanitizer,
    exec: *const Execution,
) !Name {
    const value = try requireArg(member, args, exec);
    return readName(value, fallback, "Failed to execute '" ++ member ++ "' on 'Sanitizer'", self._arena.allocator(), exec);
}

pub fn allowElement(self: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    const name = try argName("allowElement", .html, args, self, exec);
    _ = deleteName(&self._replace_with_children, name);
    if (self._elements) |*list| {
        return insertElement(list, self._arena.allocator(), name);
    }
    return deleteName(&self._remove_elements.?, name);
}

pub fn removeElement(self: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    const name = try argName("removeElement", .html, args, self, exec);
    _ = deleteName(&self._replace_with_children, name);
    if (self._elements) |*list| {
        _ = deleteElement(list, name);
        return true;
    }
    return insertName(&self._remove_elements.?, self._arena.allocator(), name);
}

pub fn replaceElementWithChildren(self: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    const name = try argName("replaceElementWithChildren", .html, args, self, exec);
    if (self._elements) |*list| {
        _ = deleteElement(list, name);
    } else {
        _ = deleteName(&self._remove_elements.?, name);
    }
    return insertName(&self._replace_with_children, self._arena.allocator(), name);
}

pub fn allowAttribute(self: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    const name = try argName("allowAttribute", .none, args, self, exec);
    if (self._attributes) |*list| {
        return insertName(list, self._arena.allocator(), name);
    }
    return deleteName(&self._remove_attributes.?, name);
}

pub fn removeAttribute(self: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    const name = try argName("removeAttribute", .none, args, self, exec);
    if (self._attributes) |*list| {
        _ = deleteName(list, name);
        return true;
    }
    return insertName(&self._remove_attributes.?, self._arena.allocator(), name);
}

pub fn setComments(self: *Sanitizer, args: []js.Value, exec: *const Execution) !void {
    const value = try requireArg("setComments", args, exec);
    self._comments = value.toBool();
}

pub fn setDataAttributes(self: *Sanitizer, args: []js.Value, exec: *const Execution) !void {
    const value = try requireArg("setDataAttributes", args, exec);
    self._data_attributes = value.toBool();
}

/// The two processing-instruction operations change nothing a page can read
/// (measured: get() is byte-identical before and after). Their return values are
/// the ones Chrome gives.
pub fn allowProcessingInstruction(_: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    _ = try requireArg("allowProcessingInstruction", args, exec);
    return false;
}

pub fn removeProcessingInstruction(_: *Sanitizer, args: []js.Value, exec: *const Execution) !bool {
    _ = try requireArg("removeProcessingInstruction", args, exec);
    return true;
}

pub fn removeUnsafe(self: *Sanitizer) !void {
    const allocator = self._arena.allocator();

    if (self._elements) |*list| {
        for (&unsafe_elements) |name| {
            _ = deleteElement(list, name);
        }
    } else {
        for (&unsafe_elements) |name| {
            _ = try insertName(&self._remove_elements.?, allocator, name);
        }
    }

    if (self._attributes) |*list| {
        for (&unsafe_attributes) |name| {
            _ = deleteName(list, name);
        }
    } else {
        for (&unsafe_attributes) |name| {
            _ = try insertName(&self._remove_attributes.?, allocator, name);
        }
    }
}

/// A fresh object every call, built by hand so the members Chrome omits are
/// actually absent and the key order is its own (alphabetical).
pub fn get(self: *Sanitizer, exec: *const Execution) !js.Object {
    const local = exec.js.local.?;
    const config = local.newObject();

    if (self._attributes) |list| {
        _ = try config.set("attributes", try buildNames(local, list.items), .{});
    }
    _ = try config.set("comments", self._comments, .{});
    if (self._data_attributes) |data_attributes| {
        _ = try config.set("dataAttributes", data_attributes, .{});
    }
    if (self._elements) |list| {
        const array = local.newArray(@intCast(list.items.len));
        for (list.items, 0..) |entry, i| {
            const object = local.newObject();
            _ = try object.set("name", entry.name, .{});
            _ = try object.set("namespace", entry.namespace.uri(), .{});
            if (entry.attributes) |attributes| {
                _ = try object.set("attributes", try buildNames(local, attributes), .{});
            } else if (entry.remove_attributes) |remove| {
                _ = try object.set("removeAttributes", try buildNames(local, remove), .{});
            }
            _ = try array.set(@intCast(i), object, .{});
        }
        _ = try config.set("elements", array, .{});
    }
    if (self._remove_attributes) |list| {
        _ = try config.set("removeAttributes", try buildNames(local, list.items), .{});
    }
    if (self._remove_elements) |list| {
        _ = try config.set("removeElements", try buildNames(local, list.items), .{});
    }
    if (self._replace_with_children.items.len > 0) {
        _ = try config.set("replaceWithChildrenElements", try buildNames(local, self._replace_with_children.items), .{});
    }
    return config;
}

fn buildNames(local: *const js.Local, names: []const Name) !js.Array {
    const array = local.newArray(@intCast(names.len));
    for (names, 0..) |name, i| {
        const object = local.newObject();
        _ = try object.set("name", name.name, .{});
        _ = try object.set("namespace", name.namespace.uri(), .{});
        _ = try array.set(@intCast(i), object, .{});
    }
    return array;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Sanitizer);

    pub const Meta = struct {
        pub const name = "Sanitizer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Sanitizer.constructor, .{});

    // Chrome's own prototype order: the nine original members alphabetically,
    // then the two processing-instruction ones appended (measured).
    pub const allowAttribute = bridge.function(Sanitizer.allowAttribute, .{ .arity = 1 });
    pub const allowElement = bridge.function(Sanitizer.allowElement, .{ .arity = 1 });
    pub const get = bridge.function(Sanitizer.get, .{});
    pub const removeAttribute = bridge.function(Sanitizer.removeAttribute, .{ .arity = 1 });
    pub const removeElement = bridge.function(Sanitizer.removeElement, .{ .arity = 1 });
    pub const removeUnsafe = bridge.function(Sanitizer.removeUnsafe, .{});
    pub const replaceElementWithChildren = bridge.function(Sanitizer.replaceElementWithChildren, .{ .arity = 1 });
    pub const setComments = bridge.function(Sanitizer.setComments, .{ .arity = 1 });
    pub const setDataAttributes = bridge.function(Sanitizer.setDataAttributes, .{ .arity = 1 });
    pub const allowProcessingInstruction = bridge.function(Sanitizer.allowProcessingInstruction, .{ .arity = 1 });
    pub const removeProcessingInstruction = bridge.function(Sanitizer.removeProcessingInstruction, .{ .arity = 1 });
};

const testing = @import("../../testing.zig");
test "WebApi: Sanitizer" {
    try testing.htmlRunner("sanitizer.html", .{});
}
