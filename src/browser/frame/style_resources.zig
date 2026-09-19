// The subresources a stylesheet names, fetched.
//
// `Frame.loadImage` covers `<img src>`; this covers everything CSS asks for --
// `@import`, `@font-face src`, `background-image`, `list-style-image`,
// `border-image-source`, `cursor`, `mask-image`. Measured against Chrome with
// tools/fingerprint/wire-census.mjs, a page that names a subresource in every
// way a page can name one: Chrome asked the server for twenty-six paths and
// this engine for eleven, and every one of the seven above was in the gap.
//
// That gap is a different kind of tell from the ones the rest of the harness
// chases. A property reading is only visible to script the guard ships; a
// request is visible in the origin's own access log, which is the one vantage
// point no amount of JS-surface fidelity reaches.
//
// Nothing decodes and nothing applies: the bytes are thrown away the same way
// `loadImage` throws away an image's, because there is no raster pipeline and
// no font engine to hand them to. `@import` in particular is fetched and
// dropped -- its rules still do not join the cascade, which is a separate gap.
//
// **A url() whose rule matches nothing is NOT fetched.** Chrome resolves style
// before it asks for anything, so `.never-used { background-image: url(x) }`
// on a page with no `.never-used` produces no request (measured, same tool).
// Over-fetching is its own tell, so the selector is tested against the
// document before the url is taken -- which is also why this runs at
// DOMContentLoaded rather than at parse time: the document has to exist first.
const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Element = @import("../webapi/Element.zig");
const Selector = @import("../webapi/selector/Selector.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const HttpClient = @import("../../network/HttpClient.zig");
const CSSRule = @import("../webapi/css/CSSRule.zig");
const CSSRuleList = @import("../webapi/css/CSSRuleList.zig");
const CSSStyleRule = @import("../webapi/css/CSSStyleRule.zig");
const CSSStyleDeclaration = @import("../webapi/css/CSSStyleDeclaration.zig");
const FontFace = @import("../webapi/css/FontFace.zig");
const MediaQuery = @import("../css/MediaQuery.zig");
const rules = @import("../webapi/css/rules.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const ResourceType = HttpClient.Request.ResourceType;

// Grouping rules can nest, and a hostile sheet can nest them arbitrarily. Same
// cap and same reason as StyleManager's.
const MAX_NESTING: u8 = 32;

// Declarations whose value can name a resource the renderer would fetch. The
// shorthands are here as well as the longhands because a rule that says
// `background: url(x) no-repeat` never materialises a `background-image`
// declaration of its own in the CSSOM view.
fn namesAResource(property: []const u8) bool {
    const names = [_][]const u8{
        "background",
        "background-image",
        "border-image",
        "border-image-source",
        "cursor",
        "list-style",
        "list-style-image",
        "mask",
        "mask-image",
        "-webkit-mask",
        "-webkit-mask-image",
        "shape-outside",
    };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(property, name)) return true;
    }
    return false;
}

fn namesAFamily(property: []const u8) bool {
    return std.ascii.eqlIgnoreCase(property, "font-family") or
        std.ascii.eqlIgnoreCase(property, "font");
}

// Walks the `url(...)` tokens in a declaration value. `cursor` and
// `background-image` both take lists, so one value can name several.
const UrlIterator = struct {
    rest: []const u8,

    fn next(self: *UrlIterator) ?[]const u8 {
        while (true) {
            const at = std.ascii.indexOfIgnoreCase(self.rest, "url(") orelse return null;
            // `curl(` and friends: the token has to start at a boundary.
            const boundary = at == 0 or !isIdentChar(self.rest[at - 1]);
            const open = at + 4;
            const close = std.mem.indexOfScalarPos(u8, self.rest, open, ')') orelse {
                self.rest = "";
                return null;
            };
            const inner = std.mem.trim(u8, self.rest[open..close], &std.ascii.whitespace);
            self.rest = self.rest[close + 1 ..];
            if (!boundary) continue;
            const url = std.mem.trim(u8, inner, "\"'");
            if (url.len == 0) continue;
            // `url(#gradient)` names an element, `url(data:...)` carries its
            // own bytes: neither reaches a server.
            if (url[0] == '#') continue;
            if (std.ascii.startsWithIgnoreCase(url, "data:")) continue;
            return url;
        }
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
    }
};

// One `name: value` at a time out of a `style=""` attribute. The parsed
// declaration lives behind a private accessor on Element, and the attribute
// text answers the same question for a tenth of the reach.
const InlineDeclarations = struct {
    rest: []const u8,

    const Declaration = struct { name: []const u8, value: []const u8 };

    fn next(self: *InlineDeclarations) ?Declaration {
        while (self.rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
            const chunk = self.rest[0..end];
            self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";
            const colon = std.mem.indexOfScalar(u8, chunk, ':') orelse continue;
            const name = std.mem.trim(u8, chunk[0..colon], &std.ascii.whitespace);
            const value = std.mem.trim(u8, chunk[colon + 1 ..], &std.ascii.whitespace);
            if (name.len == 0 or value.len == 0) continue;
            return .{ .name = name, .value = value };
        }
        return null;
    }
};

// The comma-separated selectors of a rule, one at a time. A comma inside
// `:is(a, b)` or `[title="a,b"]` separates nothing, so the split tracks
// nesting and quoting rather than calling splitScalar.
const SelectorParts = struct {
    rest: []const u8,

    fn next(self: *SelectorParts) ?[]const u8 {
        if (self.rest.len == 0) return null;
        var depth: usize = 0;
        var quote: u8 = 0;
        var i: usize = 0;
        while (i < self.rest.len) : (i += 1) {
            const c = self.rest[i];
            if (quote != 0) {
                if (c == '\\') i += 1 else if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '(', '[' => depth += 1,
                ')', ']' => depth -|= 1,
                ',' => if (depth == 0) {
                    const part = self.rest[0..i];
                    self.rest = self.rest[i + 1 ..];
                    return part;
                },
                else => {},
            }
        }
        const part = self.rest;
        self.rest = "";
        return part;
    }
};

const PseudoElement = struct {
    // Where the token starts in the compound, so the part before it is the
    // selector for the element the box hangs off.
    at: usize,
    name: []const u8,
};

// A pseudo-element has to be last in its compound, so the first one found is
// the one that decides. `::x` always names one; a single colon only does for
// the four that predate the double-colon spelling, which is also the only
// reading that keeps `:hover` and `:nth-child(2)` out of it.
fn findPseudoElement(part: []const u8) ?PseudoElement {
    const legacy = [_][]const u8{ "before", "after", "first-line", "first-letter" };
    var depth: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < part.len) : (i += 1) {
        const c = part[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ':' => {
                if (depth != 0) continue;
                const double = i + 1 < part.len and part[i + 1] == ':';
                var end: usize = if (double) i + 2 else i + 1;
                const name_at = end;
                while (end < part.len and UrlIterator.isIdentChar(part[end])) end += 1;
                const name = part[name_at..end];
                if (double) return .{ .at = i, .name = name };
                for (legacy) |known| {
                    if (std.ascii.eqlIgnoreCase(name, known)) return .{ .at = i, .name = name };
                }
                // Skip the pseudo-class wholesale: its name cannot be
                // mistaken for anything, and its argument is walked as
                // nesting on the next pass.
                i = end - 1;
            },
            else => {},
        }
    }
    return null;
}

/// Whether a rule written for this pseudo-element puts its url on the wire.
///
/// One url per pseudo-element, on a local page, counted in the server's own
/// access log with headless Chrome driving:
///
///   fetched: `::before`/`::after` (conditionally, below), `::first-line`,
///            `::first-letter`, `::placeholder`
///   not:     `::marker` (against a real `li`), `::selection`, `::backdrop`
///
/// `::before` and `::after` turn on whether the rule declares `content` at
/// all, and not on what it says: no `content` declaration and the url is not
/// requested, while `content: none` and `content: normal` -- neither of which
/// makes a box -- are both requested. So what Chrome is gating on there is
/// style being resolved for the pseudo, one step before the box question.
const PseudoFetch = enum { never, always, declares_content };

fn pseudoElementFetches(name: []const u8) PseudoFetch {
    const always = [_][]const u8{ "first-line", "first-letter", "placeholder" };
    if (std.ascii.eqlIgnoreCase(name, "before") or std.ascii.eqlIgnoreCase(name, "after")) {
        return .declares_content;
    }
    for (always) |known| {
        if (std.ascii.eqlIgnoreCase(name, known)) return .always;
    }
    return .never;
}

fn declaresContent(style: *CSSStyleDeclaration, frame: *Frame) bool {
    return style.getPropertyValue("content", frame).len != 0;
}

const Scan = struct {
    frame: *Frame,

    // What relative urls in the sheet being walked resolve against: a sheet's
    // own href, not the document's base. `@import url(a.css)` inside
    // `/deep/path/sheet.css` names `/deep/path/a.css`.
    base: [:0]const u8,

    // Resolved urls already asked for. A page whose every row carries the same
    // sprite names it once on the wire, not once per row.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    // Every `@font-face` seen, in source order. A font is only fetched once
    // something on the page asks for its family, so the rule has to be held
    // until the whole sheet set has been walked.
    faces: std.ArrayList(Face) = .empty,

    // Families named by a declaration in a rule that matched an element.
    // Case-insensitive, so the keys are lowercased on the way in.
    used_families: std.StringHashMapUnmanaged(void) = .empty,

    // Collect `@font-face` and nothing else: no selector matching, no
    // requests. What `declaredFaces` runs for.
    faces_only: bool = false,

    const Face = struct {
        family: []const u8, // lowercased, for the used_families lookup
        // The family as the rule spells it, because `document.fonts` reports
        // that and not the folded form: Chrome answers `AlphaFont`.
        declared: []const u8,
        weight: []const u8,
        style: []const u8,
        stretch: []const u8,
        base: [:0]const u8,
        url: []const u8,
    };

    fn arena(self: *Scan) std.mem.Allocator {
        return self.frame.arena;
    }

    fn ruleList(self: *Scan, list: *CSSRuleList, depth: u8) Allocator.Error!void {
        if (depth >= MAX_NESTING) return;
        var i: usize = 0;
        while (list.item(i)) |css_rule| : (i += 1) {
            try self.rule(css_rule, depth);
        }
    }

    fn rule(self: *Scan, css_rule: *CSSRule, depth: u8) Allocator.Error!void {
        switch (css_rule._type) {
            .style => |style_rule| try self.styleRule(style_rule),
            .import => |import_rule| try self.fetch(import_rule._href, .stylesheet),
            .font_face => |face| try self.fontFace(face),
            .media => |media_rule| {
                const condition = media_rule._proto;
                const text = if (condition._media) |m|
                    m.getMediaText(self.frame) catch ""
                else
                    "";
                // A non-matching query contributes no style, so it names
                // nothing to fetch.
                if (text.len != 0 and !MediaQuery.matches(text, self.frame.viewport())) return;
                try self.ruleList(condition._proto.getCssRules(), depth + 1);
            },
            .supports => |r| try self.ruleList(r._proto._proto.getCssRules(), depth + 1),
            .container => |r| try self.ruleList(r._proto._proto.getCssRules(), depth + 1),
            .layer_block => |r| try self.ruleList(r._proto.getCssRules(), depth + 1),
            else => {},
        }
    }

    fn styleRule(self: *Scan, style_rule: *CSSStyleRule) Allocator.Error!void {
        // In faces-only mode nothing here is wanted: a style rule names
        // resources and families, and the only thing being collected is the
        // `@font-face` list. Skipping it also skips a selector match per rule,
        // which is what makes the lazy `document.fonts` sync cheap enough to
        // run on a property read.
        if (self.faces_only) return;
        const selector = style_rule.getSelectorText();
        if (selector.len == 0) return;
        const style = style_rule.getStyle(self.frame) catch return;

        // Cheapest order: only ask the selector engine about a rule that has
        // something to fetch in the first place.
        if (!declaresAnything(style)) return;

        // A rule written for a pseudo-element's box is asked about the element
        // the box hangs off, because no element *is* that box.
        const to_match = try self.originatingSelector(selector, style) orelse return;

        // `background-image: var(--icon)` names no file until an element
        // supplies the custom property, and a different element supplies a
        // different one -- so which elements matched is the answer, not
        // whether any did. iphey hands each icon its own url through an
        // inline `style="--icon: url(...)"` and consumes them all through one
        // external rule; reading the two halves apart sees neither, and two
        // of its files went unrequested (waterfall.mjs, both arms).
        if (referencesAVariable(self, style)) {
            const list = Selector.querySelectorAll(self.frame.document.asNode(), to_match, self.frame) catch return;
            defer list.deinit(self.frame._page);
            for (list._nodes) |node| {
                const element = node.is(Element) orelse continue;
                try self.declarations(style, element);
            }
            return;
        }

        const match = Selector.querySelector(self.frame.document.asNode(), to_match, self.frame) catch null;
        if (match == null) return;

        try self.declarations(style, null);
    }

    /// The selector to test against the document, or null when this rule's box
    /// cannot exist here at all.
    ///
    /// `#x::before` selects a box no element owns, so the selector engine
    /// answers nothing for it (List.matchesPart) -- right for
    /// `querySelector`, and the reason every url in a `::before` rule went
    /// unrequested. Chrome does ask for them: on a local page
    /// `.p::after { content: ""; background-image: url(a) }` is on the wire.
    ///
    /// Which pseudo-elements count, and when, is `pseudoElementFetches`: not
    /// all of them put their url on the wire, and the ones that do not are
    /// dropped rather than matched, which is the safe direction because
    /// over-fetching is its own tell.
    ///
    /// `content` declared by a *different* rule for the same pseudo-element is
    /// not seen from here, so a `::after` that takes its content from one rule
    /// and its background from another stays unrequested. A miss, and the same
    /// safe direction.
    fn originatingSelector(self: *Scan, selector: []const u8, style: *CSSStyleDeclaration) Allocator.Error!?[]const u8 {
        if (std.mem.indexOfScalar(u8, selector, ':') == null) return selector;

        var has_content: ?bool = null;
        var out: std.ArrayList(u8) = .empty;
        var kept: usize = 0;
        var rewritten = false;

        var parts: SelectorParts = .{ .rest = selector };
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (part.len == 0) continue;

            var keep = part;
            if (findPseudoElement(part)) |cut| {
                rewritten = true;
                switch (pseudoElementFetches(cut.name)) {
                    .never => continue,
                    .always => {},
                    .declares_content => {
                        if (has_content == null) has_content = declaresContent(style, self.frame);
                        if (has_content == false) continue;
                    },
                }
                keep = std.mem.trim(u8, part[0..cut.at], &std.ascii.whitespace);
                // `.x > ::before` leaves a dangling combinator behind, and
                // `::before` alone leaves nothing: both mean "any element".
                if (keep.len == 0) {
                    keep = "*";
                } else if (std.mem.indexOfScalar(u8, ">+~", keep[keep.len - 1]) != null) {
                    keep = try std.fmt.allocPrint(self.arena(), "{s} *", .{keep});
                }
            }

            if (kept != 0) try out.append(self.arena(), ',');
            try out.appendSlice(self.arena(), keep);
            kept += 1;
        }

        if (!rewritten) return selector;
        if (kept == 0) return null;
        return out.items;
    }

    fn declaresAnything(style: *CSSStyleDeclaration) bool {
        var i: u32 = 0;
        const n = style.length();
        while (i < n) : (i += 1) {
            const name = style.item(i);
            if (namesAResource(name) or namesAFamily(name)) return true;
        }
        return false;
    }

    // Does any declaration worth reading here reach for a custom property?
    // Answered before the selector engine is asked for all of the matches
    // rather than one, because that is the only reason to pay for all of them.
    fn referencesAVariable(self: *Scan, style: *CSSStyleDeclaration) bool {
        var i: u32 = 0;
        const n = style.length();
        while (i < n) : (i += 1) {
            const name = style.item(i);
            if (!namesAResource(name) and !namesAFamily(name)) continue;
            const value = style.getPropertyValue(name, self.frame);
            if (std.ascii.indexOfIgnoreCase(value, "var(") != null) return true;
        }
        return false;
    }

    // Take the resources one matched rule names, and remember the families it
    // asks for so the `@font-face` pass can decide what to fetch.
    //
    // `element` is the element the rule matched, when the caller knows which
    // one: a value is only substituted against the element that carries the
    // custom properties it reads.
    fn declarations(self: *Scan, style: *CSSStyleDeclaration, element: ?*Element) Allocator.Error!void {
        var i: u32 = 0;
        const n = style.length();
        while (i < n) : (i += 1) {
            const name = style.item(i);
            try self.declaration(name, style.getPropertyValue(name, self.frame), element);
        }
    }

    fn declaration(self: *Scan, name: []const u8, value: []const u8, element: ?*Element) Allocator.Error!void {
        if (value.len == 0) return;
        const resolved = self.substituted(value, element) orelse return;
        if (resolved.len == 0) return;
        if (namesAResource(name)) {
            var it: UrlIterator = .{ .rest = resolved };
            while (it.next()) |url| try self.fetch(url, .image);
            return;
        }
        if (namesAFamily(name)) try self.rememberFamilies(resolved);
    }

    /// `value` with its `var()` references replaced, or null when the value is
    /// invalid at computed-value time (an undeclared name with no fallback)
    /// and so names nothing at all. Chrome resolves style before it asks for
    /// anything, which is the same reason a rule that matches nothing is not
    /// fetched: what reaches the network is the computed value.
    ///
    /// The relative url inside a substituted value keeps resolving against
    /// the sheet holding the *rule*, not the one holding the custom property.
    /// Chrome resolves it where the `url()` token was written; telling the two
    /// apart needs an origin the cascade does not keep, and every url measured
    /// through this path so far is absolute or root-relative.
    fn substituted(self: *Scan, value: []const u8, element: ?*Element) ?[]const u8 {
        const el = element orelse return value;
        return self.frame._style_manager.substituteVars(el, value);
    }

    fn rememberFamilies(self: *Scan, value: []const u8) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |raw| {
            const family = std.mem.trim(u8, std.mem.trim(u8, raw, &std.ascii.whitespace), "\"'");
            if (family.len == 0) continue;
            const key = try std.ascii.allocLowerString(self.arena(), family);
            try self.used_families.put(self.arena(), key, {});
        }
    }

    fn fontFace(self: *Scan, face: *rules.CSSFontFaceRule) Allocator.Error!void {
        const style = face.getStyle();
        const family_raw = style.getPropertyValue("font-family", self.frame);
        const src = style.getPropertyValue("src", self.frame);
        if (family_raw.len == 0 or src.len == 0) return;
        const family = std.mem.trim(u8, std.mem.trim(u8, family_raw, &std.ascii.whitespace), "\"'");
        if (family.len == 0) return;

        // Chrome asks for one file per face, not one per `format()` in the
        // list: the first source it can use wins and the rest are never
        // requested.
        //
        // A face with no `url()` at all is still a face. iphey declares 312
        // `@font-face` rules of which 310 are `local(...)` only -- a font
        // enumeration probe -- and Chrome lists all 312 in `document.fonts`.
        // Registering only the two with a url read 2 against its 312, which is
        // the same count-shaped tell one layer down.
        var it: UrlIterator = .{ .rest = src };
        const url = it.next() orelse "";
        try self.faces.append(self.arena(), .{
            .family = try std.ascii.allocLowerString(self.arena(), family),
            .declared = try self.arena().dupe(u8, family),
            // A descriptor the rule leaves out is the FontFace default, which
            // is what Chrome reports: `normal` for both.
            .weight = try self.arena().dupe(u8, descriptor(style, "font-weight", self.frame)),
            .style = try self.arena().dupe(u8, descriptor(style, "font-style", self.frame)),
            .stretch = try self.arena().dupe(u8, descriptor(style, "font-stretch", self.frame)),
            .base = self.base,
            .url = url,
        });
    }

    fn fetch(self: *Scan, href: []const u8, resource_type: ResourceType) Allocator.Error!void {
        try self.fetchFrom(self.base, href, resource_type, null);
    }

    /// `font_family` is the `@font-face` family these bytes are for. It is the
    /// only thing that makes a font body worth keeping -- the metrics have to
    /// be filed under the name a `font-family` list will ask for -- so it is
    /// carried here rather than recovered from the url later.
    fn fetchFrom(
        self: *Scan,
        base: [:0]const u8,
        href: []const u8,
        resource_type: ResourceType,
        font_family: ?[]const u8,
    ) Allocator.Error!void {
        if (self.faces_only) return;
        if (href.len == 0) return;
        const resolved = URL.resolve(self.arena(), base, href, .{ .encoding = self.frame.charset }) catch |err| {
            log.warn(.http, "style resource resolve", .{ .err = err, .href = href });
            return;
        };
        const gop = try self.seen.getOrPut(self.arena(), resolved);
        if (gop.found_existing) return;
        self.frame.requestStyleResource(resolved, resource_type, font_family);
    }
};

/// Every `@font-face` the frame's stylesheets declare right now, in source
/// order, with no requests made and no selector matched.
///
/// `document.fonts` reads through here rather than keeping its own walk,
/// because the walk is the part with the corners in it: a face can sit inside
/// `@media`, `@supports`, `@container` or `@layer`, and the rule list has to be
/// followed into each of them (see `Scan.rule`).
pub const DeclaredFace = struct {
    /// As the rule spells it, which is what `document.fonts` reports.
    family: []const u8,
    weight: []const u8,
    style: []const u8,
    stretch: []const u8,
    /// The face's `url()` source, empty when it has none. A `local(...)`-only
    /// face is still a face -- iphey declares 310 of them as a font
    /// enumeration probe -- but there is nothing to fetch for it, so it can
    /// never be `loaded` in this engine.
    url: []const u8,
};

pub fn declaredFaces(frame: *Frame, allocator: Allocator) ![]const DeclaredFace {
    var s: Scan = .{ .frame = frame, .base = frame.base(), .faces_only = true };
    const sheets = try frame.document.cascadeStyleSheets(frame);
    var i: usize = 0;
    while (sheets.item(i)) |sheet| : (i += 1) {
        if (sheet._proto._disabled) continue;
        const list = sheet.getCssRules(frame) catch continue;
        s.ruleList(list, 0) catch continue;
    }

    var out: std.ArrayList(DeclaredFace) = .empty;
    try out.ensureTotalCapacity(allocator, s.faces.items.len);
    for (s.faces.items) |face| {
        out.appendAssumeCapacity(.{
            .family = face.declared,
            .weight = face.weight,
            .style = face.style,
            .stretch = face.stretch,
            .url = face.url,
        });
    }
    return out.items;
}

/// Fetch what the frame's stylesheets name. Called once the document exists,
/// because whether a rule matches anything decides whether Chrome asks.
pub fn requestAll(frame: *Frame) void {
    scan(frame) catch |err| {
        log.warn(.http, "style subresources", .{ .err = err, .url = frame.url });
    };
}

fn scan(frame: *Frame) !void {
    if (frame.isGoingAway()) return;
    if (frame._parse_mode == .fragment) return;

    var s: Scan = .{ .frame = frame, .base = frame.base() };

    const sheets = try frame.document.cascadeStyleSheets(frame);
    var i: usize = 0;
    while (sheets.item(i)) |sheet| : (i += 1) {
        if (sheet._proto._disabled) continue;
        s.base = if (sheet._proto._href) |href| try frame.arena.dupeZ(u8, href) else frame.base();
        const list = sheet.getCssRules(frame) catch continue;
        try s.ruleList(list, 0);
    }
    s.base = frame.base();

    // A `style=""` attribute is a rule that matches exactly its element, so it
    // needs no selector test -- being on an element in the document is the
    // test.
    var tw = TreeWalker.Full.Elements.init(frame.document.asNode(), .{});
    while (tw.next()) |el| {
        const text = el.getAttributeSafe(comptime .wrap("style")) orelse continue;
        var it: InlineDeclarations = .{ .rest = text };
        while (it.next()) |d| try s.declaration(d.name, d.value, el);
    }

    // Two things come out of the same walk, and they have to agree: what to
    // fetch, and what `document.fonts` reports. The set held nothing at all
    // before this -- `size` read 0 against Chrome's 312 on iphey.com -- while
    // `check()` answered true for every name, so the engine knew a rule
    // existed for one question and not for the other.
    //
    // `used` is the same predicate both answers turn on. Chrome requests only
    // the faces something asks for, and leaves the others `unloaded` even when
    // their url is perfectly good, so "used" is exactly what decides the
    // status too (tests/css/font_face_set.html).
    const fonts = frame.document.getFonts(&frame.js.execution) catch null;
    for (s.faces.items, 0..) |face, rule_index| {
        // Only a face with a url has anything to fetch, and only a face
        // something asks for is fetched at all.
        const used = s.used_families.contains(face.family);
        if (used and face.url.len != 0) {
            try s.fetchFrom(face.base, face.url, .font, face.family);
        }
        const set = fonts orelse continue;
        // Mark the face the SET already derived from this same rule, rather
        // than building a second object for it. The set derives its declared
        // half lazily, on the first read of `size`/`check`/the iterator, and a
        // page that touches `document.fonts` before DOMContentLoaded -- which
        // is when this scan runs, and is exactly what a detector's
        // document-start script does -- had already made it do so. Adding here
        // then left two FontFaces for one rule, the derived one `unloaded` in
        // front of the fetched one, and `check()` answers on the first match:
        // it returned false for the rest of the page's life, measured on both
        // iphey and a two-line local page (tools/fingerprint/webfont-timeline.mjs).
        //
        // `used` is what decides `loaded`, which is what Chrome reports: it
        // leaves an unused face `unloaded` whether its source is a url it
        // never fetched or a `local()` name -- iphey's 310 local probes are all
        // `unloaded` there.
        // `loading` rather than `loaded`: the file is on the wire at this
        // point, not in the measurement. What ends the loading is the
        // registration of its bytes, and the set reads that off the frame's
        // webfont table (FontFaceSet.refreshLoading) -- so the two cases below
        // are only the scan catching up with a face whose transfer already
        // finished, which happens on the DOMContentLoaded pass when the early
        // one had already put it on the wire.
        const status: FontFace.Status = if (!(used and face.url.len != 0))
            .unloaded
        else if (frame.hasWebfont(face.family))
            .loaded
        else if (frame.webfontFailed(face.family))
            .failed
        else
            .loading;
        set.markDeclaredAt(rule_index, status, &frame.js.execution);
    }
}

/// One `@font-face` descriptor, or the FontFace default when the rule leaves
/// it out. The defaults are `normal` for both of the two read here, which is
/// what Chrome reports for a rule that declares neither.
fn descriptor(style: *CSSStyleDeclaration, name: []const u8, frame: *Frame) []const u8 {
    const value = std.mem.trim(u8, style.getPropertyValue(name, frame), &std.ascii.whitespace);
    return if (value.len == 0) "normal" else value;
}
