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
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Media-query evaluator for inline `<style>` @media rules and
//! `window.matchMedia()`. Deliberately narrow scope: external
//! `<link rel="stylesheet">` fetch is not implemented and not in scope here.
//!
//! Spec subset (Media Queries Level 4 §3) sufficient for the responsive
//! patterns observed in agentic-AI / scraping targets:
//!   - Media types: `all`, `screen`, `print`, `speech`, `tv`
//!   - Features: `width` / `height` (with `min-` / `max-`),
//!               `device-width` / `device-height` (with `min-` / `max-`),
//!               `orientation`, `aspect-ratio` / `device-aspect-ratio`,
//!               `resolution`, `color`, `color-index`, `monochrome`, `grid`,
//!               `update`, `scripting`, `overflow-block` / `overflow-inline`,
//!               `hover` / `any-hover`, `pointer` / `any-pointer`,
//!               `display-mode`, `device-posture`, `color-gamut`,
//!               `dynamic-range`, `forced-colors`, `prefers-color-scheme`,
//!               `prefers-reduced-motion`, `prefers-contrast`,
//!               `prefers-reduced-transparency`.
//!   - Length values: `<int>px`, `<int>em` (1em = 16px), `<int>rem`,
//!     and bare `0`.
//!   - Number values: `<resolution>` in `dppx` / `x` / `dpi` / `dpcm` and both
//!     `<ratio>` terms take a fractional CSS `<number>`.
//!   - Operators: `,` (OR), `and`, `not`, `only`.
//!   - Range form (MQ4 §2.4) on the range-type features: `(width > 600px)`,
//!     the reversed `(600px < width)`, and the two-sided
//!     `(600px <= width <= 1200px)`, with `<`, `<=`, `>`, `>=` and `=`.
//!     Discrete features and already-prefixed ones take no operator.
//!
//! The interaction features and the display descriptors answer for one fixed
//! device persona, and it has to stay consistent with the rest of the fork:
//! an Apple GPU driving a 1920x1200 display at devicePixelRatio 2 -- so a
//! 3840x2400 panel, since `screen.*` is CSS pixels -- with
//! `screen.colorDepth` 30 — a wide-gamut, HDR-capable panel, which is the only
//! kind the Apple M4 named by this fork's WebGL renderer ever drives — driven
//! with a mouse, showing a 1920x1080 page in a maximised window (Viewport
//! derives the one from the other). Note that the `width`/`height` features
//! read the page and the `device-*` ones read the display, so the two are no
//! longer the same pair of numbers. Every value below was measured
//! on a headed Chrome (tools/fingerprint, media-features probe); the three that
//! describe the panel follow from *this* persona's colour depth rather than
//! from any one reference display — see COLOR_BITS_PER_CHANNEL.
//!
//! `inverted-colors` and `video-dynamic-range` are deliberately absent: Chrome
//! does not implement them (measured — neither the boolean nor any value form
//! matches), so recognising them here would be the anomaly.
//!
//! Per spec, any unrecognized media type, unsupported feature, or malformed
//! value evaluates the containing query to `false`. The remaining
//! comma-separated branches are still evaluated independently.
//!
//! See lightpanda-io/browser#2363 sibling and the surrounding discussion
//! around C10 (inline-only narrow scope, no external CSS fetch).

const std = @import("std");

const Viewport = @import("../Viewport.zig");
const units = @import("units.zig");

/// Returns true if `query` matches the given viewport. Comma-separated
/// queries are evaluated independently and combined with OR.
pub fn matches(query: []const u8, viewport: Viewport) bool {
    // Reject any input with an unbalanced `/* ...` before parsing. Every
    // downstream scanner is comment-aware but only on the assumption that
    // each comment is closed; an unterminated one would otherwise silently
    // swallow the rest of the input and could flip a partially-parsed query
    // to `true`.
    if (hasUnterminatedComment(query)) return false;

    var rest = trimWsAndComments(query);
    // An empty query is `all`, which matches. Chrome answers true to
    // `matchMedia('')` and to a query of nothing but whitespace.
    if (rest.len == 0) return true;

    while (rest.len > 0) {
        const cut = nextTopLevelComma(rest);
        const piece = trimWsAndComments(rest[0..cut]);
        if (piece.len > 0 and matchesSingle(piece, viewport)) return true;
        if (cut == rest.len) break;
        rest = rest[cut + 1 ..];
    }
    return false;
}

/// Returns true if `s` contains an opening `/*` without a matching `*/`.
/// Called once at the top of `matches`; lets every other scanner trust that
/// comments are balanced.
fn hasUnterminatedComment(s: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < s.len) {
        if (s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return true;
            i = close + 2;
            continue;
        }
        i += 1;
    }
    return false;
}

/// Advance `i` past any whitespace and `/* ... */` comments. Assumes
/// comments are balanced (see `hasUnterminatedComment`); an unterminated
/// comment encountered defensively returns `s.len` so the caller breaks out.
fn skipWsAndComments(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        if (std.ascii.isWhitespace(s[i])) {
            i += 1;
        } else if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return s.len;
            i = close + 2;
        } else break;
    }
    return i;
}

/// Strip leading and trailing whitespace and `/* ... */` comments from `s`.
/// Interior trivia is preserved; token-by-token scanners skip it as they go.
fn trimWsAndComments(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        if (std.ascii.isWhitespace(s[start])) {
            start += 1;
        } else if (start + 1 < end and s[start] == '/' and s[start + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, start + 2, "*/") orelse return s[start..end];
            start = close + 2;
        } else break;
    }
    while (end > start) {
        if (std.ascii.isWhitespace(s[end - 1])) {
            end -= 1;
        } else if (end >= start + 2 and s[end - 1] == '/' and s[end - 2] == '*') {
            const open_rel = std.mem.lastIndexOf(u8, s[start .. end - 2], "/*") orelse return s[start..end];
            end = start + open_rel;
        } else break;
    }
    return s[start..end];
}

/// First occurrence of `needle` in `s` that is not inside a `/* ... */`
/// comment. Comments are assumed balanced (see `hasUnterminatedComment`).
fn indexOfScalarSkippingComments(s: []const u8, needle: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return null;
            i = close + 2;
            continue;
        }
        if (s[i] == needle) return i;
        i += 1;
    }
    return null;
}

fn nextTopLevelComma(s: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return s.len;
            i = close + 2;
            continue;
        }
        switch (s[i]) {
            '(' => depth += 1,
            ')' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) return i,
            else => {},
        }
        i += 1;
    }
    return s.len;
}

const MediaType = enum { all, screen, print, speech, tv };

fn parseMediaType(word: []const u8) ?MediaType {
    if (std.mem.eql(u8, word, "all")) return .all;
    if (std.mem.eql(u8, word, "screen")) return .screen;
    if (std.mem.eql(u8, word, "print")) return .print;
    if (std.mem.eql(u8, word, "speech")) return .speech;
    if (std.mem.eql(u8, word, "tv")) return .tv;
    return null;
}

/// One comma-separated query, walked over the same token grammar the
/// serialiser uses — `tokenize` splits the parens from the identifiers, and
/// what is not a media type followed by `and`-joined conditions, or a chain of
/// conditions on its own, has no valid reading and answers false.
fn matchesSingle(query: []const u8, viewport: Viewport) bool {
    const tokens = tokenize(query) catch return false;
    const items = tokens.slice();

    var i: usize = 0;
    var negate = false;
    var only = false;
    if (!items[0].block) {
        if (std.ascii.eqlIgnoreCase(items[0].text, "not")) {
            negate = true;
            i = 1;
        } else if (std.ascii.eqlIgnoreCase(items[0].text, "only")) {
            // 'only' is a hint to parsers that predate media features; it
            // qualifies a media type and nothing else.
            only = true;
            i = 1;
        }
    }
    // A bare `not` or `only` names nothing.
    if (i == items.len) return false;

    if (items[i].block) {
        if (only) return false;
        const result = conditionChainMatches(items[i..], viewport) orelse return false;
        return if (negate) !result else result;
    }

    var word_buf: [max_feature_name]u8 = undefined;
    const media_type = lowerBounded(&word_buf, items[i].text) orelse return false;
    // A logical keyword where the media type goes.
    if (isJoiner(media_type)) return false;
    i += 1;

    // Everything after a media type is `and <condition>`; `or` may not follow
    // one, and two conditions may not sit side by side.
    var features_match = true;
    while (i < items.len) {
        if (items[i].block or !std.ascii.eqlIgnoreCase(items[i].text, "and")) return false;
        i += 1;
        if (i == items.len or !items[i].block) return false;
        if (!conditionMatches(items[i].text, viewport)) features_match = false;
        i += 1;
    }

    // An unknown media type is not this browser, so it answers false — but it
    // is still a well-formed query, and negating it answers true. `not bogus`
    // and `not tv` both match (measured); the earlier reading returned false
    // out of the parse and lost the negation with it.
    const type_matches = if (parseMediaType(media_type)) |t| switch (t) {
        .all, .screen => true,
        .print, .speech, .tv => false,
    } else false;

    const result = type_matches and features_match;
    return if (negate) !result else result;
}

/// Conditions joined by one repeated keyword, or null when that is not what
/// the tokens are. Mixing `and` with `or` at one level is malformed in MQ4 —
/// the parens are what disambiguate — so it has no reading rather than a
/// guessed precedence.
fn conditionChainMatches(items: []const Token, viewport: Viewport) ?bool {
    var i: usize = 0;
    var result: ?bool = null;
    var joiner: ?Joiner = null;
    while (true) {
        if (!items[i].block) return null;
        const value = conditionMatches(items[i].text, viewport);
        result = if (result) |carried| switch (joiner.?) {
            .@"and" => carried and value,
            .@"or" => carried or value,
        } else value;
        i += 1;
        if (i == items.len) return result;

        if (items[i].block) return null;
        const next: Joiner = if (std.ascii.eqlIgnoreCase(items[i].text, "and"))
            .@"and"
        else if (std.ascii.eqlIgnoreCase(items[i].text, "or"))
            .@"or"
        else
            return null;
        if (joiner) |set| {
            if (set != next) return null;
        } else {
            joiner = next;
        }
        i += 1;
        // A trailing joiner with nothing after it.
        if (i == items.len) return null;
    }
}

/// What is inside one pair of parens: a feature, or another condition — MQ4
/// lets a media condition nest, and `((min-width: 100px))` and
/// `(not (min-width: 100px))` are both queries Chrome answers.
fn conditionMatches(inner: []const u8, viewport: Viewport) bool {
    const text = trimWsAndComments(inner);
    if (text.len == 0) return false;

    if (text[0] == '(' or startsWithNot(text)) {
        const tokens = tokenize(text) catch return false;
        const items = tokens.slice();
        var negate = false;
        var start: usize = 0;
        if (!items[0].block and std.ascii.eqlIgnoreCase(items[0].text, "not")) {
            negate = true;
            start = 1;
        }
        if (start == items.len) return false;
        const result = conditionChainMatches(items[start..], viewport) orelse return false;
        return if (negate) !result else result;
    }

    return evalFeature(text, viewport);
}

/// A leading `not` keyword rather than a feature name that happens to begin
/// with those three letters.
fn startsWithNot(text: []const u8) bool {
    if (text.len <= 3) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..3], "not")) return false;
    return !isIdentChar(text[3]);
}

fn findClosingParen(s: []const u8, open: usize) ?usize {
    std.debug.assert(s[open] == '(');
    var depth: usize = 1;
    var i = open + 1;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return null;
            i = close + 2;
            continue;
        }
        if (s[i] == '(') {
            depth += 1;
        } else if (s[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn evalFeature(text: []const u8, viewport: Viewport) bool {
    const trimmed = trimWsAndComments(text);
    if (trimmed.len == 0) return false;

    // The MQ4 range form is tried first: what distinguishes it from the legacy
    // `name: value` one is the operator, and no well-formed query has both.
    // `evalRange` hands back null when there is no operator at all, so a plain
    // feature falls through untouched.
    if (evalRange(trimmed, viewport)) |result| return result;

    if (indexOfScalarSkippingComments(trimmed, ':')) |colon| {
        const name = trimWsAndComments(trimmed[0..colon]);
        const value = trimWsAndComments(trimmed[colon + 1 ..]);
        return evalNameValue(name, value, viewport);
    }

    return evalBoolean(trimmed, viewport);
}

// Bits per colour channel. `screen.colorDepth` is 30 across three channels, so
// Chrome's `color` feature answers 10, and `color-gamut: p3` and
// `dynamic-range: high` follow from the same panel. The four move together or
// not at all: an 8-bit sRGB SDR display and a 10-bit one are both perfectly
// ordinary, but half of each is a display that does not exist.
//
// Which half this fork picks is settled by a claim it already makes elsewhere.
// Its WebGL renderer answers `ANGLE (Apple, ANGLE Metal Renderer: Apple M4,
// Unspecified Version)`, and every Mac an M4 ships in has a P3, 10-bit,
// HDR-capable panel. The previous 8-bit sRGB persona contradicted that, and the
// contradiction sat on the one axis B53 measured both remaining DataDome and
// Kasada stations reading: dd-saks asks eleven media queries and this engine
// answered `color-gamut: p3` and `dynamic-range: high` the other way from the
// headed Chrome that clears the station.
const COLOR_BITS_PER_CHANNEL: u32 = 10;

// A colour screen with no indexed palette and no monochrome depth. Both are the
// numbers Chrome reports (measured); they are named because the `min-` / `max-`
// forms only read right next to the value they compare against.
const COLOR_INDEX: u32 = 0;
const MONOCHROME_BITS: u32 = 0;

// devicePixelRatio, mirroring Window's own property -- change one and the other
// has to move, because a page can read both and Kasada does. Held as a float
// because a resolution bound is a float: `(min-resolution: 0.625dppx)` has to
// compare against it without either side being rounded first.
const DEVICE_PIXEL_RATIO: f64 = 2;

fn evalNameValue(name: []const u8, value: []const u8, viewport: Viewport) bool {
    if (name.len > 32) {
        return false;
    }

    var buf: [32]u8 = undefined;
    const lname = std.ascii.lowerString(&buf, name);
    if (std.mem.eql(u8, lname, "min-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width >= px;
    }
    if (std.mem.eql(u8, lname, "max-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width <= px;
    }
    if (std.mem.eql(u8, lname, "width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width == px;
    }
    if (std.mem.eql(u8, lname, "min-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height >= px;
    }
    if (std.mem.eql(u8, lname, "max-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height <= px;
    }
    if (std.mem.eql(u8, lname, "height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height == px;
    }
    if (std.mem.eql(u8, lname, "orientation")) {
        if (std.ascii.eqlIgnoreCase(value, "landscape")) return viewport.width >= viewport.height;
        if (std.ascii.eqlIgnoreCase(value, "portrait")) return viewport.height > viewport.width;
        return false;
    }

    // The device-* lengths are the *display's*, not the page's — MQ4 §5 says
    // so, and `screen.width`/`screen.height` report the same two numbers, which
    // is a cross-check a script can make in one expression. They stopped being
    // the viewport's when the window grew a browser around it (see Viewport).
    const device_width = viewport.screenWidth();
    const device_height = viewport.screenHeight();
    if (std.mem.eql(u8, lname, "min-device-width")) {
        const px = parseLengthPx(value) orelse return false;
        return device_width >= px;
    }
    if (std.mem.eql(u8, lname, "max-device-width")) {
        const px = parseLengthPx(value) orelse return false;
        return device_width <= px;
    }
    if (std.mem.eql(u8, lname, "device-width")) {
        const px = parseLengthPx(value) orelse return false;
        return device_width == px;
    }
    if (std.mem.eql(u8, lname, "min-device-height")) {
        const px = parseLengthPx(value) orelse return false;
        return device_height >= px;
    }
    if (std.mem.eql(u8, lname, "max-device-height")) {
        const px = parseLengthPx(value) orelse return false;
        return device_height <= px;
    }
    if (std.mem.eql(u8, lname, "device-height")) {
        const px = parseLengthPx(value) orelse return false;
        return device_height == px;
    }

    // `<ratio>` compares as a fraction, so it is done by cross-multiplication
    // rather than by dividing — 1920/1080 and 16/9 are the same ratio and have
    // to compare equal.
    if (std.mem.eql(u8, lname, "aspect-ratio")) {
        return compareRatio(value, viewport.width, viewport.height, .eq);
    }
    if (std.mem.eql(u8, lname, "min-aspect-ratio")) {
        return compareRatio(value, viewport.width, viewport.height, .ge);
    }
    if (std.mem.eql(u8, lname, "max-aspect-ratio")) {
        return compareRatio(value, viewport.width, viewport.height, .le);
    }
    if (std.mem.eql(u8, lname, "device-aspect-ratio")) {
        return compareRatio(value, device_width, device_height, .eq);
    }
    if (std.mem.eql(u8, lname, "min-device-aspect-ratio")) {
        return compareRatio(value, device_width, device_height, .ge);
    }
    if (std.mem.eql(u8, lname, "max-device-aspect-ratio")) {
        return compareRatio(value, device_width, device_height, .le);
    }

    if (std.mem.eql(u8, lname, "resolution")) {
        const dppx = parseResolutionDppx(value) orelse return false;
        return dppx == DEVICE_PIXEL_RATIO;
    }
    if (std.mem.eql(u8, lname, "min-resolution")) {
        const dppx = parseResolutionDppx(value) orelse return false;
        return DEVICE_PIXEL_RATIO >= dppx;
    }
    if (std.mem.eql(u8, lname, "max-resolution")) {
        const dppx = parseResolutionDppx(value) orelse return false;
        return DEVICE_PIXEL_RATIO <= dppx;
    }

    // Numeric display descriptors. `monochrome: 0` and `color-index: 0` are the
    // answers a colour screen with no indexed palette gives.
    if (std.mem.eql(u8, lname, "color")) return parseInteger(value) == COLOR_BITS_PER_CHANNEL;
    if (std.mem.eql(u8, lname, "min-color")) {
        const n = parseInteger(value) orelse return false;
        return COLOR_BITS_PER_CHANNEL >= n;
    }
    if (std.mem.eql(u8, lname, "max-color")) {
        const n = parseInteger(value) orelse return false;
        return COLOR_BITS_PER_CHANNEL <= n;
    }
    // Both are 0 here, which is exactly the value that makes the `max-` form
    // match every bound and the `min-` form match only a 0 one. Sharing one
    // `== 0` between the bare feature and its `max-` form answers the `max-`
    // form backwards, so each of the three prefixes compares on its own.
    if (std.mem.eql(u8, lname, "color-index")) return parseInteger(value) == COLOR_INDEX;
    if (std.mem.eql(u8, lname, "min-color-index")) {
        const n = parseInteger(value) orelse return false;
        return COLOR_INDEX >= n;
    }
    if (std.mem.eql(u8, lname, "max-color-index")) {
        const n = parseInteger(value) orelse return false;
        return COLOR_INDEX <= n;
    }
    if (std.mem.eql(u8, lname, "monochrome")) return parseInteger(value) == MONOCHROME_BITS;
    if (std.mem.eql(u8, lname, "min-monochrome")) {
        const n = parseInteger(value) orelse return false;
        return MONOCHROME_BITS >= n;
    }
    if (std.mem.eql(u8, lname, "max-monochrome")) {
        const n = parseInteger(value) orelse return false;
        return MONOCHROME_BITS <= n;
    }
    // `grid` is discrete, not a range feature: Chrome answers false to both
    // `min-grid` and `max-grid` (measured), so only the bare form is here.
    if (std.mem.eql(u8, lname, "grid")) return parseInteger(value) == 0;

    // Keyword descriptors, all measured on a headed Chrome.
    if (std.mem.eql(u8, lname, "hover") or std.mem.eql(u8, lname, "any-hover")) {
        return std.ascii.eqlIgnoreCase(value, "hover");
    }
    if (std.mem.eql(u8, lname, "pointer") or std.mem.eql(u8, lname, "any-pointer")) {
        return std.ascii.eqlIgnoreCase(value, "fine");
    }
    if (std.mem.eql(u8, lname, "update")) return std.ascii.eqlIgnoreCase(value, "fast");
    if (std.mem.eql(u8, lname, "scripting")) return std.ascii.eqlIgnoreCase(value, "enabled");
    if (std.mem.eql(u8, lname, "overflow-block") or std.mem.eql(u8, lname, "overflow-inline")) {
        return std.ascii.eqlIgnoreCase(value, "scroll");
    }
    if (std.mem.eql(u8, lname, "display-mode")) return std.ascii.eqlIgnoreCase(value, "browser");
    // A desktop display does not fold, and `navigator.devicePosture.type`
    // already answers `continuous` — the two have to agree.
    if (std.mem.eql(u8, lname, "device-posture")) return std.ascii.eqlIgnoreCase(value, "continuous");
    // Both are cumulative, not a single answer: a P3 panel matches `srgb` as
    // well as `p3`, an HDR one matches `standard` as well as `high`. Chrome on
    // such a display answers exactly this way (measured), and a page that only
    // asks the narrower value would otherwise read a display that is wide-gamut
    // but somehow not sRGB.
    if (std.mem.eql(u8, lname, "color-gamut")) {
        return std.ascii.eqlIgnoreCase(value, "srgb") or std.ascii.eqlIgnoreCase(value, "p3");
    }
    if (std.mem.eql(u8, lname, "dynamic-range")) {
        return std.ascii.eqlIgnoreCase(value, "standard") or std.ascii.eqlIgnoreCase(value, "high");
    }
    if (std.mem.eql(u8, lname, "forced-colors")) return std.ascii.eqlIgnoreCase(value, "none");
    if (std.mem.eql(u8, lname, "prefers-color-scheme")) return std.ascii.eqlIgnoreCase(value, "light");
    if (std.mem.eql(u8, lname, "prefers-reduced-motion") or
        std.mem.eql(u8, lname, "prefers-reduced-transparency") or
        std.mem.eql(u8, lname, "prefers-contrast"))
    {
        return std.ascii.eqlIgnoreCase(value, "no-preference");
    }

    return false;
}

// The boolean form asks "is this feature's value something other than zero or
// none". A colour screen answers false for `monochrome` and `grid` (both are 0)
// and true for everything it does have.
fn evalBoolean(name: []const u8, viewport: Viewport) bool {
    if (name.len > 32) {
        return false;
    }
    var buf: [32]u8 = undefined;
    const lname = std.ascii.lowerString(&buf, name);

    if (std.mem.eql(u8, lname, "width")) return viewport.width > 0;
    if (std.mem.eql(u8, lname, "height")) return viewport.height > 0;
    if (std.mem.eql(u8, lname, "device-width")) return viewport.width > 0;
    if (std.mem.eql(u8, lname, "device-height")) return viewport.height > 0;
    if (std.mem.eql(u8, lname, "orientation")) return true;
    if (std.mem.eql(u8, lname, "aspect-ratio") or std.mem.eql(u8, lname, "device-aspect-ratio")) return true;
    if (std.mem.eql(u8, lname, "resolution")) return true;
    if (std.mem.eql(u8, lname, "color")) return COLOR_BITS_PER_CHANNEL > 0;

    // Zero-valued, so false in the boolean form.
    if (std.mem.eql(u8, lname, "monochrome")) return false;
    if (std.mem.eql(u8, lname, "color-index")) return false;
    if (std.mem.eql(u8, lname, "grid")) return false;

    // `none`-valued features are false in the boolean form; the rest are true.
    if (std.mem.eql(u8, lname, "forced-colors")) return false;
    if (std.mem.eql(u8, lname, "hover") or std.mem.eql(u8, lname, "any-hover")) return true;
    if (std.mem.eql(u8, lname, "pointer") or std.mem.eql(u8, lname, "any-pointer")) return true;
    if (std.mem.eql(u8, lname, "update")) return true;
    if (std.mem.eql(u8, lname, "scripting")) return true;
    if (std.mem.eql(u8, lname, "overflow-block") or std.mem.eql(u8, lname, "overflow-inline")) return true;
    if (std.mem.eql(u8, lname, "display-mode")) return true;
    if (std.mem.eql(u8, lname, "device-posture")) return true;
    if (std.mem.eql(u8, lname, "color-gamut")) return true;
    // `(dynamic-range)` with no value is false in Chrome even on a display
    // where `(dynamic-range: high)` matches — measured, so it is not the
    // panel's answer, it is that Chrome does not implement the feature in
    // boolean context at all. `(color-gamut)` above it does.
    if (std.mem.eql(u8, lname, "dynamic-range")) return false;
    if (std.mem.eql(u8, lname, "prefers-color-scheme")) return true;
    if (std.mem.eql(u8, lname, "prefers-reduced-motion") or
        std.mem.eql(u8, lname, "prefers-reduced-transparency") or
        std.mem.eql(u8, lname, "prefers-contrast")) return true;

    return false;
}

const RangeOp = enum { lt, le, gt, ge, eq };

/// The range-type media features — the ones whose value is a number, a length,
/// a resolution or a ratio, and so can be ordered. MQ4 gives only these the
/// range form: a discrete feature like `orientation` or `hover` has no ordering
/// to compare against, and a feature that already carries a `min-` / `max-`
/// prefix may not take an operator as well. Chrome answers false to both
/// (measured), so the whitelist is the point rather than an optimisation.
const RangeFeature = enum {
    width,
    height,
    device_width,
    device_height,
    resolution,
    color,
    color_index,
    monochrome,
    aspect_ratio,
    device_aspect_ratio,
};

fn parseRangeFeature(name: []const u8) ?RangeFeature {
    if (name.len > 32) return null;
    var buf: [32]u8 = undefined;
    const lname = std.ascii.lowerString(&buf, name);

    // The device- lengths read the display rather than the page — the same
    // split evalNameValue makes.
    if (std.mem.eql(u8, lname, "width")) return .width;
    if (std.mem.eql(u8, lname, "height")) return .height;
    if (std.mem.eql(u8, lname, "device-width")) return .device_width;
    if (std.mem.eql(u8, lname, "device-height")) return .device_height;
    if (std.mem.eql(u8, lname, "resolution")) return .resolution;
    if (std.mem.eql(u8, lname, "color")) return .color;
    if (std.mem.eql(u8, lname, "color-index")) return .color_index;
    if (std.mem.eql(u8, lname, "monochrome")) return .monochrome;
    if (std.mem.eql(u8, lname, "aspect-ratio")) return .aspect_ratio;
    if (std.mem.eql(u8, lname, "device-aspect-ratio")) return .device_aspect_ratio;
    return null;
}

fn rangeFeatureValue(feature: RangeFeature, viewport: Viewport) f64 {
    return switch (feature) {
        .width => @floatFromInt(viewport.width),
        .height => @floatFromInt(viewport.height),
        .device_width => @floatFromInt(viewport.screenWidth()),
        .device_height => @floatFromInt(viewport.screenHeight()),
        .resolution => DEVICE_PIXEL_RATIO,
        .color => @floatFromInt(COLOR_BITS_PER_CHANNEL),
        .color_index => @floatFromInt(COLOR_INDEX),
        .monochrome => @floatFromInt(MONOCHROME_BITS),
        .aspect_ratio => @as(f64, @floatFromInt(viewport.width)) / @as(f64, @floatFromInt(viewport.height)),
        .device_aspect_ratio => @as(f64, @floatFromInt(viewport.screenWidth())) / @as(f64, @floatFromInt(viewport.screenHeight())),
    };
}

/// The bound in whatever value space the feature reads in, so both sides of the
/// comparison are the same scalar.
fn parseRangeBound(feature: RangeFeature, text: []const u8) ?f64 {
    return switch (feature) {
        .width, .height, .device_width, .device_height => parseLengthPx(text),
        .resolution => parseResolutionDppx(text),
        .color, .color_index, .monochrome => @floatFromInt(parseInteger(text) orelse return null),
        .aspect_ratio, .device_aspect_ratio => parseRatio(text),
    };
}

/// A `<ratio>` as a single scalar, for the range form. IEEE division is
/// correctly rounded and 1920/1080 is exactly the real number 16/9, so both
/// spellings land on the same double and still compare equal — the property
/// `compareRatio` gets from cross-multiplying.
fn parseRatio(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return parseNumber(trimmed);
    const num = parseNumber(trimmed[0..slash]) orelse return null;
    const den = parseNumber(trimmed[slash + 1 ..]) orelse return null;
    if (den == 0) return null;
    return num / den;
}

fn compareOp(lhs: f64, op: RangeOp, rhs: f64) bool {
    return switch (op) {
        .lt => lhs < rhs,
        .le => lhs <= rhs,
        .gt => lhs > rhs,
        .ge => lhs >= rhs,
        .eq => lhs == rhs,
    };
}

/// Reading `a < b` as a statement about `b` instead of `a` reverses it, which
/// is what lets the feature sit on either side of the operator.
fn flipOp(op: RangeOp) RangeOp {
    return switch (op) {
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
        .eq => .eq,
    };
}

const OpMatch = struct { op: RangeOp, len: usize };

fn matchRangeOp(s: []const u8, i: usize) ?OpMatch {
    const eq_next = i + 1 < s.len and s[i + 1] == '=';
    return switch (s[i]) {
        '<' => if (eq_next) .{ .op = .le, .len = 2 } else .{ .op = .lt, .len = 1 },
        '>' => if (eq_next) .{ .op = .ge, .len = 2 } else .{ .op = .gt, .len = 1 },
        '=' => .{ .op = .eq, .len = 1 },
        else => null,
    };
}

/// A range-form feature split into its operands and operators. `too_many_ops`
/// carries the malformed-but-still-a-range case, which answers false rather
/// than falling through to the legacy `name: value` form.
const RangeSplit = struct {
    parts: [3][]const u8,
    ops: [2]RangeOp,
    n_ops: usize,
    too_many_ops: bool,
};

/// Scan `text` for the MQ4 range operators. Returns null when there is no
/// operator at all — or when a comment in it is unterminated, which is not a
/// range query either.
fn splitRange(text: []const u8) ?RangeSplit {
    var parts: [3][]const u8 = undefined;
    var ops: [2]RangeOp = undefined;
    var n_ops: usize = 0;

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return null;
            i = close + 2;
            continue;
        }
        if (matchRangeOp(text, i)) |m| {
            if (n_ops == 2) {
                return .{ .parts = parts, .ops = ops, .n_ops = n_ops, .too_many_ops = true };
            }
            parts[n_ops] = text[start..i];
            ops[n_ops] = m.op;
            n_ops += 1;
            i += m.len;
            start = i;
            continue;
        }
        i += 1;
    }
    if (n_ops == 0) return null;
    parts[n_ops] = text[start..];
    return .{ .parts = parts, .ops = ops, .n_ops = n_ops, .too_many_ops = false };
}

/// MQ4 range form: `(width > 600px)`, the reversed `(600px < width)`, or the
/// two-sided `(600px <= width <= 1200px)`. Returns null — not false — when
/// `text` holds no operator, so `evalFeature` can fall through to the legacy
/// `name: value` form; anything with an operator is answered here, malformed
/// or not.
fn evalRange(text: []const u8, viewport: Viewport) ?bool {
    const split = splitRange(text) orelse return null;
    if (split.too_many_ops) return false;
    const parts = split.parts;
    const ops = split.ops;
    const n_ops = split.n_ops;

    if (n_ops == 1) {
        const lhs = trimWsAndComments(parts[0]);
        const rhs = trimWsAndComments(parts[1]);
        if (parseRangeFeature(lhs)) |feature| {
            const bound = parseRangeBound(feature, rhs) orelse return false;
            return compareOp(rangeFeatureValue(feature, viewport), ops[0], bound);
        }
        if (parseRangeFeature(rhs)) |feature| {
            const bound = parseRangeBound(feature, lhs) orelse return false;
            return compareOp(rangeFeatureValue(feature, viewport), flipOp(ops[0]), bound);
        }
        return false;
    }

    // Two-sided: the feature is in the middle, and per MQ4 both operators have
    // to point the same way. `(600px < width > 1200px)` is malformed and so is
    // an `=` on either side — both measured false in Chrome.
    if (!sameDirection(ops[0], ops[1])) return false;
    const feature = parseRangeFeature(trimWsAndComments(parts[1])) orelse return false;
    const low = parseRangeBound(feature, trimWsAndComments(parts[0])) orelse return false;
    const high = parseRangeBound(feature, trimWsAndComments(parts[2])) orelse return false;
    const value = rangeFeatureValue(feature, viewport);
    return compareOp(value, flipOp(ops[0]), low) and compareOp(value, ops[1], high);
}

fn sameDirection(a: RangeOp, b: RangeOp) bool {
    const descending = struct {
        fn f(op: RangeOp) ?bool {
            return switch (op) {
                .lt, .le => false,
                .gt, .ge => true,
                .eq => null,
            };
        }
    }.f;
    const a_dir = descending(a) orelse return false;
    const b_dir = descending(b) orelse return false;
    return a_dir == b_dir;
}

const RatioCompare = enum { eq, ge, le };

/// `<ratio>` is `<number> / <number>`, or a single number meaning `n / 1`.
/// Both terms are numbers rather than integers — MQ4 widened them, and Chrome
/// takes `(max-aspect-ratio: 2.125)` and `(min-aspect-ratio: 1.5/2.5)`.
/// Compared by cross-multiplication so 16/9 and 1920/1080 come out equal.
fn compareRatio(value: []const u8, width: u32, height: u32, op: RatioCompare) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    var num: f64 = undefined;
    var den: f64 = undefined;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        num = parseNumber(trimmed[0..slash]) orelse return false;
        den = parseNumber(trimmed[slash + 1 ..]) orelse return false;
    } else {
        num = parseNumber(trimmed) orelse return false;
        den = 1;
    }
    if (den == 0) return false;

    // width/height vs num/den  ->  width*den vs num*height
    const lhs = @as(f64, @floatFromInt(width)) * den;
    const rhs = num * @as(f64, @floatFromInt(height));
    return switch (op) {
        .eq => lhs == rhs,
        .ge => lhs >= rhs,
        .le => lhs <= rhs,
    };
}

/// `<resolution>` as a fractional dppx, in any of the three units Chrome
/// accepts. Kasada binary-searches devicePixelRatio by halving a
/// `min-resolution` bound two dozen times and then walking the same ladder
/// again in `dpi` and a third time in `dpcm`, so rounding a resolution — or
/// rejecting a unit — gets every rung of a ladder wrong rather than one query.
fn parseResolutionDppx(value: []const u8) ?f64 {
    const split = splitNumber(std.mem.trim(u8, value, &std.ascii.whitespace)) orelse return null;
    // Non-negative per MQ4, and malformed rather than clamped below zero. `-0`
    // is zero and so allowed, which is what Chrome answers to
    // `(min-resolution: -0dppx)`.
    if (split.value < 0) return null;
    const unit = std.mem.trim(u8, split.rest, &std.ascii.whitespace);

    if (std.ascii.eqlIgnoreCase(unit, "dppx") or std.ascii.eqlIgnoreCase(unit, "x")) return split.value;
    // CSS fixes 1in at 96px, and an inch is 2.54cm.
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return split.value / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return split.value * 2.54 / 96.0;
    return null;
}

const NumberSplit = struct { value: f64, rest: []const u8 };

/// Scan a leading CSS `<number>` and return it with the unconsumed remainder,
/// which for a dimension is the unit. An optional sign, digits, an optional
/// `.` fraction, an optional exponent; the integer and fraction parts may not
/// both be empty, so `.625` parses and bare `.` does not. A `.` with no digit
/// after it is left for the unit, which makes `5.dppx` malformed rather than
/// `5` with a `.dppx` unit.
///
/// The sign and the exponent are both here because a CSS `<number>` has them
/// and Chrome reads them: `(min-width: 1e2px)` matches at 100px and serialises
/// as `100px`, and `(min-width: -1px)` is a well-formed bound that everything
/// is above. Which *features* accept a negative is the caller's business —
/// `<resolution>` and `<ratio>` are non-negative, and per MQ4 a negative one is
/// malformed rather than clamped, so those two reject `value < 0` themselves.
/// `-0` passes that test, which is what Chrome does with it too.
fn splitNumber(s: []const u8) ?NumberSplit {
    var i: usize = 0;
    var negative = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        negative = s[i] == '-';
        i += 1;
    }

    var value: f64 = 0;
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        value = value * 10 + @as(f64, @floatFromInt(s[i] - '0'));
    }
    const int_digits = i - int_start;

    var frac_digits: usize = 0;
    if (i + 1 < s.len and s[i] == '.' and std.ascii.isDigit(s[i + 1])) {
        i += 1;
        var num: u64 = 0;
        var den: f64 = 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            frac_digits += 1;
            // A double holds 17 significant digits; past that the numerator
            // would overflow without moving the value. Keep scanning so the
            // rest of the token is still consumed, just stop accumulating.
            if (frac_digits <= 17) {
                num = num * 10 + (s[i] - '0');
                den *= 10;
            }
        }
        // Dividing two exact values keeps the result correctly rounded, where
        // accumulating tenths would drift: 0.625 has to stay 0.625.
        value += @as(f64, @floatFromInt(num)) / den;
    }

    if (int_digits == 0 and frac_digits == 0) return null;

    // The exponent only counts when a digit follows it: `1e2px` is 100px, while
    // `1epx` is the number 1 with the unit `epx`, which is no unit at all.
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        var exp_negative = false;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) {
            exp_negative = s[j] == '-';
            j += 1;
        }
        const exp_start = j;
        var exponent: i32 = 0;
        while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {
            // Past the range of a double the extra digits cannot move the
            // result, and they would overflow the accumulator; keep consuming.
            if (exponent < 1000) exponent = exponent * 10 + @as(i32, s[j] - '0');
        }
        if (j > exp_start) {
            const signed: f64 = if (exp_negative) -@as(f64, @floatFromInt(exponent)) else @floatFromInt(exponent);
            value *= std.math.pow(f64, 10, signed);
            i = j;
        }
    }

    if (negative) value = -value;
    return .{ .value = value, .rest = s[i..] };
}

/// A bare non-negative CSS `<number>` filling the whole of `value`, for
/// `<ratio>` terms. `-0` is zero and so allowed; anything below it is not.
fn parseNumber(value: []const u8) ?f64 {
    const split = splitNumber(std.mem.trim(u8, value, &std.ascii.whitespace)) orelse return null;
    if (split.rest.len != 0) return null;
    if (split.value < 0) return null;
    return split.value;
}

/// A bare non-negative integer, for the numeric display descriptors. An
/// `<integer>` has no fraction and no exponent — Chrome quotes `(color: 8.0)`
/// and `(color: 1e1)` back rather than reading either — but it does take a
/// sign, and `-0` is 0.
fn parseInteger(value: []const u8) ?u32 {
    var digits = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (digits.len == 0) return null;
    var negative = false;
    if (digits[0] == '+' or digits[0] == '-') {
        negative = digits[0] == '-';
        digits = digits[1..];
    }
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (negative and n != 0) return null;
    return n;
}

/// Parse `<number>px`, `<number>em` (1em=16px), `<number>rem`, or a bare zero,
/// into px. Returns null on any other form — the units this engine does not
/// claim (cm, pt, vw) stay unreadable on purpose, and a unit-less non-zero is
/// not a length at all.
///
/// A `<length>` is a fraction and it may be negative: `(min-width: 1919.5px)`
/// matches a 1920-wide viewport where `(min-width: 1920.5px)` does not, and
/// `(min-width: -1px)` is a bound everything clears. Both measured on Chrome
/// 150 — the earlier integer-only, non-negative reading answered false to all
/// three.
fn parseLengthPx(value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    const split = splitNumber(trimmed) orelse return null;
    const unit = std.mem.trim(u8, split.rest, &std.ascii.whitespace);

    const px = if (unit.len == 0)
        // Only zero may go without a unit. `(min-width: 100)` is quoted back by
        // Chrome, not read as 100px.
        if (split.value == 0) split.value else return null
    else if (std.ascii.eqlIgnoreCase(unit, "px"))
        split.value
    else if (std.ascii.eqlIgnoreCase(unit, "em") or std.ascii.eqlIgnoreCase(unit, "rem"))
        split.value * 16
    else
        return null;

    return toFloat32(px);
}

/// A CSS length is a float32 in Chrome, which is visible at both ends: an
/// exponent past its range clamps to `3.40282e+38` rather than becoming
/// infinite (`(min-width: 1e400px)` serialises as that and matches false), and
/// one below it collapses to zero.
fn toFloat32(value: f64) f64 {
    const limit = std.math.floatMax(f32);
    const clamped = std.math.clamp(value, -limit, limit);
    return @as(f32, @floatCast(clamped));
}

// ---------------------------------------------------------------------------
// Serialisation
//
// `MediaQueryList.media` is not the text handed to `matchMedia`: Chrome parses
// the query and writes the parse back out, so `(min-width:100px)` answers
// `(min-width: 100px)` and `(max-aspect-ratio: 2.125)` answers
// `(max-aspect-ratio: 2.125 / 1)`. Every deviation from the input is therefore
// a rule, all of them measured on a headed Chrome 150 and recorded in
// tools/fingerprint/results/media-query-serialization.json.
//
// The rule that organises the rest: what parses is rewritten in canonical
// form, and what does not parse is echoed back byte for byte —
// `(  min-bogus  :  1px  )` keeps its spacing. That makes the parser the
// authority on serialisation too, so a form this engine cannot read is quoted
// rather than guessed at.
// ---------------------------------------------------------------------------

const Allocator = std.mem.Allocator;

/// How a query component failed to parse, and so how it is written instead.
/// `EchoRaw` quotes the component's own text; `NotAll` is the whole-query
/// refusal Chrome writes when there is no valid reading at all.
const Unwritable = error{ EchoRaw, NotAll };

/// The three ways a write can end: the component was unwritable, the writer
/// failed, or its allocator did. Spelled out rather than inferred because the
/// condition writers recurse through each other for nested conditions.
const WriteError = Unwritable || units.NumberError || error{OutOfMemory};

/// The canonical text of `query`, in the arena. Comma-separated queries are
/// serialised independently and joined with `, `.
pub fn serialize(arena: Allocator, query: []const u8) ![]const u8 {
    const trimmed = trimWsAndComments(query);
    // An all-whitespace query is the empty one, and its serialisation is empty
    // too — `matchMedia('')` answers `''`, not `not all`.
    if (trimmed.len == 0) return "";

    var out = std.Io.Writer.Allocating.init(arena);
    var rest = trimmed;
    var first = true;
    while (true) {
        const cut = nextTopLevelComma(rest);
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try writeSingle(arena, &out.writer, rest[0..cut]);
        if (cut == rest.len) break;
        rest = rest[cut + 1 ..];
    }
    return out.written();
}

/// One comma-separated query, written whole or replaced by its fallback. The
/// canonical form goes to a scratch buffer first so a component that fails
/// half way through cannot leave a partial query behind.
fn writeSingle(arena: Allocator, w: *std.Io.Writer, segment: []const u8) !void {
    const trimmed = trimWsAndComments(segment);
    // An empty branch of a comma list is a query with nothing in it, which
    // Chrome writes as `not all` — the one case where empty is not empty.
    if (trimmed.len == 0) return w.writeAll("not all");

    var scratch = std.Io.Writer.Allocating.init(arena);
    writeQuery(arena, &scratch.writer, trimmed) catch |err| switch (err) {
        error.NotAll => return w.writeAll("not all"),
        error.EchoRaw => return w.writeAll(trimmed),
        else => |e| return e,
    };
    return w.writeAll(scratch.written());
}

const Token = struct {
    /// A parenthesised condition, in which case `text` is what is inside the
    /// parens. Otherwise an identifier: a media type or a logical keyword.
    block: bool,
    text: []const u8,
};

/// Enough for `screen and (a) and (b) and …` far past any real query; one past
/// it is echoed rather than mangled.
const max_tokens = 32;

const Tokens = struct {
    items: [max_tokens]Token,
    len: usize,

    fn slice(self: *const Tokens) []const Token {
        return self.items[0..self.len];
    }
};

fn tokenize(text: []const u8) Unwritable!Tokens {
    var tokens: Tokens = .{ .items = undefined, .len = 0 };
    var i: usize = 0;
    while (i < text.len) {
        i = skipWsAndComments(text, i);
        if (i >= text.len) break;
        if (tokens.len == max_tokens) return error.EchoRaw;

        if (text[i] == '(') {
            // An unterminated block is quoted, not refused: Chrome answers `(`
            // to `(`, where a stray `)` gets `not all`.
            const end = findClosingParen(text, i) orelse return error.EchoRaw;
            tokens.items[tokens.len] = .{ .block = true, .text = text[i + 1 .. end] };
            tokens.len += 1;
            i = end + 1;
            continue;
        }

        if (!isIdentChar(text[i])) return error.NotAll;
        const start = i;
        while (i < text.len and isIdentChar(text[i])) i += 1;
        tokens.items[tokens.len] = .{ .block = false, .text = text[start..i] };
        tokens.len += 1;
    }
    if (tokens.len == 0) return error.NotAll;
    return tokens;
}

const Qualifier = enum { none, not, only };
const Joiner = enum { @"and", @"or" };

fn writeQuery(arena: Allocator, w: *std.Io.Writer, text: []const u8) WriteError!void {
    const tokens = try tokenize(text);
    const items = tokens.slice();

    var i: usize = 0;
    var qualifier: Qualifier = .none;
    if (!items[0].block) {
        if (std.ascii.eqlIgnoreCase(items[0].text, "not")) {
            qualifier = .not;
            i = 1;
        } else if (std.ascii.eqlIgnoreCase(items[0].text, "only")) {
            qualifier = .only;
            i = 1;
        }
    }
    // A bare `not` or `only` names no media type, so there is nothing to write.
    if (i == items.len) return error.NotAll;

    if (items[i].block) {
        // A condition where a media type would go: `not (a)`, `(a) and (b)`.
        // `only` may not qualify a condition — it exists to hide a query from
        // parsers that predate media features.
        switch (qualifier) {
            .none => {},
            .not => try w.writeAll("not "),
            .only => return error.NotAll,
        }
        return writeConditionChain(arena, w, items[i..]);
    }

    var name_buf: [max_feature_name]u8 = undefined;
    const media_type = lowerBounded(&name_buf, items[i].text) orelse return error.EchoRaw;
    // A logical keyword in the media-type slot: `and (a)`, `or (a)`.
    if (isJoiner(media_type)) return error.NotAll;
    i += 1;

    // Everything after the media type has to be `and <condition>`.
    const conditions = i;
    while (i < items.len) {
        if (items[i].block or !std.ascii.eqlIgnoreCase(items[i].text, "and")) return error.NotAll;
        i += 1;
        if (i == items.len or !items[i].block) return error.NotAll;
        i += 1;
    }

    // `all and (min-width: 1px)` serialises without the `all`: an unqualified
    // `all` adds nothing to a condition. A qualified one changes the answer, so
    // `not all and (…)` keeps it.
    const drop_type = qualifier == .none and
        std.mem.eql(u8, media_type, "all") and
        conditions < items.len;
    if (!drop_type) {
        switch (qualifier) {
            .none => {},
            .not => try w.writeAll("not "),
            .only => try w.writeAll("only "),
        }
        try w.writeAll(media_type);
    }

    var j = conditions + 1;
    var wrote_something = !drop_type;
    while (j < items.len) : (j += 2) {
        if (wrote_something) try w.writeAll(" and ");
        wrote_something = true;
        try writeCondition(arena, w, items[j].text);
    }
}

/// Conditions joined by one repeated keyword. Mixing `and` with `or` at the
/// same level is malformed in MQ4 — the parens are what disambiguate — so it
/// answers `not all` rather than picking a precedence.
fn writeConditionChain(arena: Allocator, w: *std.Io.Writer, items: []const Token) WriteError!void {
    var joiner: ?Joiner = null;
    var i: usize = 0;
    while (true) {
        if (!items[i].block) return error.NotAll;
        try writeCondition(arena, w, items[i].text);
        i += 1;
        if (i == items.len) return;

        if (items[i].block) return error.NotAll;
        const next: Joiner = if (std.ascii.eqlIgnoreCase(items[i].text, "and"))
            .@"and"
        else if (std.ascii.eqlIgnoreCase(items[i].text, "or"))
            .@"or"
        else
            return error.NotAll;
        if (joiner) |set| {
            if (set != next) return error.NotAll;
        } else {
            joiner = next;
        }
        try w.print(" {s} ", .{@tagName(next)});
        i += 1;
        // A trailing `and` with nothing after it.
        if (i == items.len) return error.NotAll;
    }
}

/// One parenthesised condition. A condition this engine cannot read keeps its
/// own text — the surrounding query is still canonicalised, which is what
/// Chrome does with `screen and (min-width:1px) and (bogus)`.
fn writeCondition(arena: Allocator, w: *std.Io.Writer, inner: []const u8) WriteError!void {
    var scratch = std.Io.Writer.Allocating.init(arena);
    writeConditionInner(arena, &scratch.writer, trimWsAndComments(inner)) catch |err| switch (err) {
        error.EchoRaw, error.NotAll => {
            try w.writeByte('(');
            try w.writeAll(inner);
            return w.writeByte(')');
        },
        else => |e| return e,
    };
    try w.writeByte('(');
    try w.writeAll(scratch.written());
    return w.writeByte(')');
}

fn writeConditionInner(arena: Allocator, w: *std.Io.Writer, text: []const u8) WriteError!void {
    if (text.len == 0) return error.EchoRaw;

    // A nested condition: `((min-width: 1px))`, `((a) and (b))`.
    if (text[0] == '(') {
        const tokens = try tokenize(text);
        return writeConditionChain(arena, w, tokens.slice());
    }

    // The range form is recognised by its operator, the same way `evalFeature`
    // tells the two forms apart.
    if (splitRange(text)) |split| return writeRange(w, split);

    if (indexOfScalarSkippingComments(text, ':')) |colon| {
        const name = trimWsAndComments(text[0..colon]);
        const value = trimWsAndComments(text[colon + 1 ..]);
        return writeNameValue(w, name, value);
    }

    // The boolean form. Only an unprefixed feature has one: `(min-width)`
    // names a bound without giving it.
    var buf: [max_feature_name]u8 = undefined;
    const lname = lowerBounded(&buf, text) orelse return error.EchoRaw;
    const found = findFeature(lname) orelse return error.EchoRaw;
    if (found.prefixed) return error.EchoRaw;
    return w.writeAll(lname);
}

fn writeNameValue(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    var buf: [max_feature_name]u8 = undefined;
    const lname = lowerBounded(&buf, name) orelse return error.EchoRaw;
    const found = findFeature(lname) orelse return error.EchoRaw;

    // The value is written before the name so a value this engine cannot read
    // aborts the whole condition rather than half-writing it — `writeCondition`
    // catches the error and quotes the original.
    var scratch: [max_value_text]u8 = undefined;
    var value_out = std.Io.Writer.fixed(&scratch);
    writeValue(&value_out, found.feature, value) catch return error.EchoRaw;

    try w.writeAll(lname);
    try w.writeAll(": ");
    return w.writeAll(value_out.buffered());
}

fn writeValue(w: *std.Io.Writer, feature: Feature, value: []const u8) !void {
    return switch (feature.kind) {
        .length => writeDimension(w, value, .length),
        .resolution => writeDimension(w, value, .resolution),
        .integer => writeInteger(w, value, null),
        // `grid` is 0 or 1 and nothing else: Chrome quotes `(grid: 2)` back.
        .grid => writeInteger(w, value, 1),
        .ratio => writeRatio(w, value),
        .keyword => writeKeyword(w, value, feature.keywords),
    };
}

const length_units = [_][]const u8{ "px", "em", "rem" };
const resolution_units = [_][]const u8{ "dppx", "x", "dpi", "dpcm" };

/// A `<dimension>`: the number in CSS canonical form, the unit lowercased.
/// `bare_zero_ok` covers `<length>`, where a unitless 0 is legal.
fn writeDimension(w: *std.Io.Writer, value: []const u8, kind: DimensionKind) !void {
    const split = splitNumber(value) orelse return error.EchoRaw;
    // Only a `<length>` may be negative.
    if (kind == .resolution and split.value < 0) return error.EchoRaw;

    // The unit is kept as written rather than converted — `6.25em` stays em —
    // and the number is rounded through the float32 a length is stored in, so
    // `119.9375em` writes as `119.938em` and `1e400px` as `3.40282e+38px`.
    // Whether a resolution is stored the same way was not measured, so it keeps
    // its double.
    const number = switch (kind) {
        .length => toFloat32(split.value),
        .resolution => split.value,
    };

    const unit = std.mem.trim(u8, split.rest, &std.ascii.whitespace);
    if (unit.len == 0) {
        // Only a length may go unitless, and only at zero.
        if (kind != .length or number != 0) return error.EchoRaw;
        return w.writeAll("0");
    }

    var buf: [8]u8 = undefined;
    const lunit = lowerBounded(&buf, unit) orelse return error.EchoRaw;
    const allowed: []const []const u8 = switch (kind) {
        .length => &length_units,
        .resolution => &resolution_units,
    };
    for (allowed) |known| {
        if (std.mem.eql(u8, known, lunit)) {
            try units.writeNumber(w, number);
            return w.writeAll(lunit);
        }
    }
    return error.EchoRaw;
}

const DimensionKind = enum { length, resolution };

fn writeInteger(w: *std.Io.Writer, value: []const u8, max: ?u32) !void {
    const n = parseInteger(value) orelse return error.EchoRaw;
    if (max) |limit| {
        if (n > limit) return error.EchoRaw;
    }
    return w.print("{d}", .{n});
}

/// `<ratio>` is always written as two numbers around ` / `, so a bare number
/// grows the `/ 1` the spec says it means. Its terms do not go through the `%g`
/// a dimension does: `(aspect-ratio:1000000/1)` answers `1000000 / 1` where
/// `(min-width:1000000px)` answers `1e+06px` (both measured), so they are
/// written as they read. A zero denominator is malformed but
/// still writeable — Chrome answers `(aspect-ratio: 1 / 0)` and false.
fn writeRatio(w: *std.Io.Writer, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '/')) |slash| {
        const num = parseNumber(value[0..slash]) orelse return error.EchoRaw;
        const den = parseNumber(value[slash + 1 ..]) orelse return error.EchoRaw;
        try units.writeRatioNumber(w, unsign(num));
        try w.writeAll(" / ");
        return units.writeRatioNumber(w, unsign(den));
    }
    const num = parseNumber(value) orelse return error.EchoRaw;
    try units.writeRatioNumber(w, unsign(num));
    return w.writeAll(" / 1");
}

/// A discrete feature's value has to be one of that feature's own keywords:
/// `(pointer: coarse)` is canonicalised while `(orientation: bogus)` is quoted,
/// even though both answer false.
/// `-0` is zero, and zero has no sign in a serialisation: Chrome answers
/// `(aspect-ratio: 0 / 1)` to `(aspect-ratio:-0/1)`.
fn unsign(v: f64) f64 {
    return if (v == 0) 0 else v;
}

fn writeKeyword(w: *std.Io.Writer, value: []const u8, keywords: []const []const u8) !void {
    var buf: [max_value_text]u8 = undefined;
    const lvalue = lowerBounded(&buf, value) orelse return error.EchoRaw;
    for (keywords) |known| {
        if (std.mem.eql(u8, known, lvalue)) return w.writeAll(lvalue);
    }
    return error.EchoRaw;
}

fn writeRange(w: *std.Io.Writer, split: RangeSplit) !void {
    if (split.too_many_ops) return error.EchoRaw;

    if (split.n_ops == 1) {
        const lhs = trimWsAndComments(split.parts[0]);
        const rhs = trimWsAndComments(split.parts[1]);
        if (parseRangeFeature(lhs)) |feature| {
            try writeLowered(w, lhs);
            try w.print(" {s} ", .{opText(split.ops[0])});
            return writeBound(w, feature, rhs);
        }
        if (parseRangeFeature(rhs)) |feature| {
            try writeBound(w, feature, lhs);
            try w.print(" {s} ", .{opText(split.ops[0])});
            return writeLowered(w, rhs);
        }
        return error.EchoRaw;
    }

    const middle = trimWsAndComments(split.parts[1]);
    const feature = parseRangeFeature(middle) orelse return error.EchoRaw;
    if (!sameDirection(split.ops[0], split.ops[1])) return error.EchoRaw;
    try writeBound(w, feature, trimWsAndComments(split.parts[0]));
    try w.print(" {s} ", .{opText(split.ops[0])});
    try writeLowered(w, middle);
    try w.print(" {s} ", .{opText(split.ops[1])});
    return writeBound(w, feature, trimWsAndComments(split.parts[2]));
}

/// The bound in the value space its feature reads in — the serialisation
/// counterpart of `parseRangeBound`.
fn writeBound(w: *std.Io.Writer, feature: RangeFeature, text: []const u8) !void {
    return switch (feature) {
        .width, .height, .device_width, .device_height => writeDimension(w, text, .length),
        .resolution => writeDimension(w, text, .resolution),
        .color, .color_index, .monochrome => writeInteger(w, text, null),
        .aspect_ratio, .device_aspect_ratio => writeRatio(w, text),
    };
}

fn opText(op: RangeOp) []const u8 {
    return switch (op) {
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .eq => "=",
    };
}

const ValueKind = enum { length, resolution, integer, grid, ratio, keyword };

const Feature = struct {
    kind: ValueKind,
    /// The values a discrete feature accepts. A value outside the list is
    /// quoted rather than canonicalised, which is how Chrome distinguishes
    /// "false" from "not a value of this feature".
    keywords: []const []const u8 = &.{},
    /// Whether `min-` and `max-` spellings of this feature exist. Only the
    /// ordered features have them: `(max-orientation: landscape)` is not a
    /// query, and neither is `(max-grid: 0)`.
    ranged: bool = false,
};

/// The features this engine can read, with the shape of each one's value. The
/// names mirror `evalNameValue` and `evalBoolean` above: a name here that the
/// evaluator does not know would serialise canonically and then answer false,
/// and a name the evaluator knows that is missing here is quoted instead of
/// canonicalised. Both are visible in a two-arm run, which is how the two
/// lists stay together.
const features = std.StaticStringMap(Feature).initComptime(.{
    .{ "width", Feature{ .kind = .length, .ranged = true } },
    .{ "height", Feature{ .kind = .length, .ranged = true } },
    .{ "device-width", Feature{ .kind = .length, .ranged = true } },
    .{ "device-height", Feature{ .kind = .length, .ranged = true } },
    .{ "resolution", Feature{ .kind = .resolution, .ranged = true } },
    .{ "aspect-ratio", Feature{ .kind = .ratio, .ranged = true } },
    .{ "device-aspect-ratio", Feature{ .kind = .ratio, .ranged = true } },
    .{ "color", Feature{ .kind = .integer, .ranged = true } },
    .{ "color-index", Feature{ .kind = .integer, .ranged = true } },
    .{ "monochrome", Feature{ .kind = .integer, .ranged = true } },
    .{ "grid", Feature{ .kind = .grid } },
    .{ "orientation", Feature{ .kind = .keyword, .keywords = &.{ "portrait", "landscape" } } },
    .{ "hover", Feature{ .kind = .keyword, .keywords = &.{ "none", "hover" } } },
    .{ "any-hover", Feature{ .kind = .keyword, .keywords = &.{ "none", "hover" } } },
    .{ "pointer", Feature{ .kind = .keyword, .keywords = &.{ "none", "coarse", "fine" } } },
    .{ "any-pointer", Feature{ .kind = .keyword, .keywords = &.{ "none", "coarse", "fine" } } },
    .{ "scan", Feature{ .kind = .keyword, .keywords = &.{ "interlace", "progressive" } } },
    .{ "update", Feature{ .kind = .keyword, .keywords = &.{ "none", "slow", "fast" } } },
    .{ "scripting", Feature{ .kind = .keyword, .keywords = &.{ "none", "initial-only", "enabled" } } },
    .{ "overflow-block", Feature{ .kind = .keyword, .keywords = &.{ "none", "scroll", "paged", "optional-paged" } } },
    .{ "overflow-inline", Feature{ .kind = .keyword, .keywords = &.{ "none", "scroll" } } },
    .{ "display-mode", Feature{ .kind = .keyword, .keywords = &.{
        "fullscreen",
        "standalone",
        "minimal-ui",
        "browser",
        "window-controls-overlay",
        "picture-in-picture",
    } } },
    .{ "device-posture", Feature{ .kind = .keyword, .keywords = &.{ "continuous", "folded" } } },
    .{ "color-gamut", Feature{ .kind = .keyword, .keywords = &.{ "srgb", "p3", "rec2020" } } },
    .{ "dynamic-range", Feature{ .kind = .keyword, .keywords = &.{ "standard", "high" } } },
    .{ "forced-colors", Feature{ .kind = .keyword, .keywords = &.{ "none", "active" } } },
    .{ "prefers-color-scheme", Feature{ .kind = .keyword, .keywords = &.{ "light", "dark" } } },
    .{ "prefers-reduced-motion", Feature{ .kind = .keyword, .keywords = &.{ "no-preference", "reduce" } } },
    .{ "prefers-reduced-transparency", Feature{ .kind = .keyword, .keywords = &.{ "no-preference", "reduce" } } },
    .{ "prefers-contrast", Feature{ .kind = .keyword, .keywords = &.{ "no-preference", "more", "less", "custom" } } },
});

const FoundFeature = struct { feature: Feature, prefixed: bool };

/// `min-` and `max-` are part of the name, not modifiers on the value, so a
/// prefixed spelling resolves to the same value shape as the bare one.
fn findFeature(lname: []const u8) ?FoundFeature {
    if (std.mem.startsWith(u8, lname, "min-") or std.mem.startsWith(u8, lname, "max-")) {
        const base = features.get(lname[4..]) orelse return null;
        if (!base.ranged) return null;
        return .{ .feature = base, .prefixed = true };
    }
    return .{ .feature = features.get(lname) orelse return null, .prefixed = false };
}

/// Long enough for `prefers-reduced-transparency` and `window-controls-overlay`
/// with room to spare; a longer name is not a feature this engine knows.
const max_feature_name = 48;
const max_value_text = 64;

fn lowerBounded(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    return std.ascii.lowerString(buf, s);
}

fn writeLowered(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| try w.writeByte(std.ascii.toLower(c));
}

fn isJoiner(lname: []const u8) bool {
    return std.mem.eql(u8, lname, "and") or std.mem.eql(u8, lname, "or");
}

const testing = std.testing;

// An empty media query list is `all` per MQ4, and `all` matches. Measured:
// `matchMedia('').matches` is true on Chrome 150, and so is a query of nothing
// but whitespace. An empty *branch* of a comma list is the other way round —
// there it is `not all` — which is why the two are handled apart.
test "MediaQuery: empty query is all" {
    try testing.expect(matches("", Viewport.default));
    try testing.expect(matches("   ", Viewport.default));
    try testing.expect(matches("/* just a comment */", Viewport.default));
    try testing.expect(!matches("(min-width: 3000px),", Viewport.default));
}

test "MediaQuery: bare media types" {
    const v = Viewport.default;
    try testing.expect(matches("all", v));
    try testing.expect(matches("screen", v));
    try testing.expect(matches("ALL", v));
    try testing.expect(matches("Screen", v));
    try testing.expect(!matches("print", v));
    try testing.expect(!matches("speech", v));
    try testing.expect(!matches("tv", v));
}

test "MediaQuery: unknown ident is false" {
    try testing.expect(!matches("foo", Viewport.default));
    try testing.expect(!matches("braille", Viewport.default));
}

test "MediaQuery: min-width on 1920x1080 viewport" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 1px)", v));
    try testing.expect(matches("(min-width: 600px)", v));
    try testing.expect(matches("(min-width: 1920px)", v));
    try testing.expect(!matches("(min-width: 1921px)", v));
    try testing.expect(!matches("(min-width: 3000px)", v));
}

test "MediaQuery: max-width" {
    const v = Viewport.default;
    try testing.expect(matches("(max-width: 1920px)", v));
    try testing.expect(matches("(max-width: 2000px)", v));
    try testing.expect(!matches("(max-width: 1919px)", v));
    try testing.expect(!matches("(max-width: 0)", v));
}

test "MediaQuery: width (exact)" {
    const v = Viewport.default;
    try testing.expect(matches("(width: 1920px)", v));
    try testing.expect(!matches("(width: 1921px)", v));
    try testing.expect(!matches("(width: 1919px)", v));
}

test "MediaQuery: min-height / max-height / height" {
    const v = Viewport.default;
    try testing.expect(matches("(min-height: 1080px)", v));
    try testing.expect(!matches("(min-height: 1081px)", v));
    try testing.expect(matches("(max-height: 1080px)", v));
    try testing.expect(!matches("(max-height: 1079px)", v));
    try testing.expect(matches("(height: 1080px)", v));
    try testing.expect(!matches("(height: 1081px)", v));
}

test "MediaQuery: orientation" {
    const v = Viewport.default;
    try testing.expect(matches("(orientation: landscape)", v));
    try testing.expect(!matches("(orientation: portrait)", v));

    const portrait: Viewport = .{ .width = 600, .height = 800 };
    try testing.expect(!matches("(orientation: landscape)", portrait));
    try testing.expect(matches("(orientation: portrait)", portrait));

    const square: Viewport = .{ .width = 500, .height = 500 };
    try testing.expect(matches("(orientation: landscape)", square));
    try testing.expect(!matches("(orientation: portrait)", square));
}

test "MediaQuery: combined with `and`" {
    const v = Viewport.default;
    try testing.expect(matches("screen and (min-width: 600px)", v));
    try testing.expect(!matches("print and (min-width: 600px)", v));
    try testing.expect(matches("(min-width: 600px) and (max-width: 2000px)", v));
    try testing.expect(!matches("(min-width: 600px) and (max-width: 1000px)", v));
    try testing.expect(matches("all and (orientation: landscape)", v));
}

test "MediaQuery: `not` negates" {
    const v = Viewport.default;
    try testing.expect(matches("not print", v));
    try testing.expect(!matches("not screen", v));
    try testing.expect(!matches("not (min-width: 600px)", v));
    try testing.expect(matches("not (min-width: 3000px)", v));
}

test "MediaQuery: comma is OR" {
    const v = Viewport.default;
    try testing.expect(matches("print, screen", v));
    try testing.expect(matches("(max-width: 100px), (min-width: 600px)", v));
    try testing.expect(!matches("(max-width: 100px), (min-width: 3000px)", v));
    try testing.expect(matches("foo, screen", v));
}

test "MediaQuery: `only` is no-op" {
    const v = Viewport.default;
    try testing.expect(matches("only screen", v));
    try testing.expect(matches("only screen and (min-width: 600px)", v));
    try testing.expect(!matches("only print", v));
}

test "MediaQuery: em units (1em=16px)" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 30em)", v)); // 480px <= 1920px
    try testing.expect(matches("(min-width: 120em)", v)); // 1920px == 1920
    try testing.expect(!matches("(min-width: 121em)", v)); // 1936px > 1920
}

test "MediaQuery: rem treated as em" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 30rem)", v));
    try testing.expect(!matches("(min-width: 121rem)", v));
}

test "MediaQuery: bare 0 is valid" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 0)", v));
    try testing.expect(!matches("(max-width: 0)", v));
}

test "MediaQuery: unknown feature is false" {
    const v = Viewport.default;
    try testing.expect(!matches("(nonsense)", v));
    try testing.expect(!matches("(nonsense: 1)", v));
    // Chrome implements neither of these — measured, no value form and no
    // boolean form matches — so recognising them here would be the anomaly.
    try testing.expect(!matches("(inverted-colors)", v));
    try testing.expect(!matches("(inverted-colors: none)", v));
    try testing.expect(!matches("(video-dynamic-range: standard)", v));
    // Recognised features still answer false for a value this device is not.
    try testing.expect(!matches("(prefers-color-scheme: dark)", v));
    try testing.expect(!matches("(prefers-reduced-motion: reduce)", v));
    try testing.expect(!matches("(hover: none)", v));
    try testing.expect(!matches("(pointer: coarse)", v));
}

test "MediaQuery: the device persona, as measured on a headed Chrome" {
    const v = Viewport.default;
    // CreepJS's getCSSMedia probes, in its own order.
    try testing.expect(matches("(prefers-reduced-motion: no-preference)", v));
    try testing.expect(matches("(prefers-color-scheme: light)", v));
    try testing.expect(matches("(monochrome: 0)", v));
    try testing.expect(matches("(forced-colors: none)", v));
    try testing.expect(matches("(any-hover: hover)", v));
    try testing.expect(matches("(hover: hover)", v));
    try testing.expect(matches("(any-pointer: fine)", v));
    try testing.expect(matches("(pointer: fine)", v));
    try testing.expect(matches("(display-mode: browser)", v));
    // The device-* lengths read the display, which is taller than the page by
    // the browser window around it plus the menu bar above that (see Viewport).
    // `screen.width`/`screen.height` answer the same two numbers.
    try testing.expect(matches("(device-width: 1920px) and (device-height: 1200px)", v));
    try testing.expect(!matches("(device-height: 1080px)", v));
    try testing.expect(matches("(width: 1920px) and (height: 1080px)", v));

    // These three follow from this fork's persona (colorDepth 30 across three
    // channels, a wide-gamut HDR panel) — see the header. Both are cumulative:
    // a P3 display matches srgb as well, an HDR one matches standard as well.
    try testing.expect(matches("(color-gamut: srgb)", v));
    try testing.expect(matches("(color-gamut: p3)", v));
    try testing.expect(!matches("(color-gamut: rec2020)", v));
    try testing.expect(matches("(color: 10)", v));
    try testing.expect(!matches("(color: 8)", v));
    try testing.expect(matches("(dynamic-range: standard)", v));
    try testing.expect(matches("(dynamic-range: high)", v));
    // Chrome answers the boolean form of dynamic-range false even where
    // `(dynamic-range: high)` matches, so it does not implement the feature in
    // boolean context. color-gamut it does.
    try testing.expect(!matches("(dynamic-range)", v));
    try testing.expect(matches("(color-gamut)", v));

    try testing.expect(matches("(prefers-contrast: no-preference)", v));
    try testing.expect(matches("(prefers-reduced-transparency: no-preference)", v));
    try testing.expect(matches("(update: fast)", v));
    try testing.expect(matches("(scripting: enabled)", v));
    try testing.expect(matches("(overflow-block: scroll)", v));
    try testing.expect(matches("(overflow-inline: scroll)", v));
    try testing.expect(matches("(grid: 0)", v));
    try testing.expect(matches("(color-index: 0)", v));
    try testing.expect(matches("(resolution: 2dppx)", v));
    try testing.expect(matches("(resolution: 192dpi)", v));
    try testing.expect(!matches("(resolution: 1dppx)", v));
    try testing.expect(!matches("(resolution: 96dpi)", v));
}

test "MediaQuery: ratio compares as a fraction, not a division" {
    const v = Viewport.default; // 1920x1080 page on a 1920x1200 display
    try testing.expect(matches("(device-aspect-ratio: 8/5)", v));
    try testing.expect(matches("(device-aspect-ratio: 1920/1200)", v));
    try testing.expect(matches("(aspect-ratio: 16/9)", v));
    try testing.expect(matches("(aspect-ratio: 1920/1080)", v));
    // The page's ratio and the display's are no longer the same ratio: the
    // browser around the page takes 87 pixels of the display's height.
    try testing.expect(!matches("(device-aspect-ratio: 16/9)", v));
    try testing.expect(!matches("(device-aspect-ratio: 4/3)", v));
    try testing.expect(matches("(min-aspect-ratio: 4/3)", v));
    try testing.expect(matches("(max-aspect-ratio: 2/1)", v));
    // A bare number is `n / 1`, and a zero denominator is malformed.
    try testing.expect(!matches("(aspect-ratio: 1)", v));
    try testing.expect(!matches("(aspect-ratio: 16/0)", v));

    const square = Viewport{ .width = 800, .height = 800 };
    try testing.expect(matches("(aspect-ratio: 1)", square));
    try testing.expect(matches("(aspect-ratio: 1/1)", square));
}

// Kasada binary-searches devicePixelRatio on x-hyatt: it halves a
// `min-resolution` bound 24 times, then walks the same ladder again in `dpi`
// and a third time in `dpcm` — 64 of the 227 distinct matchMedia queries it
// asked for. Answering only whole `dppx` gets every rung of all three ladders
// wrong. Every expectation below was measured on a headed Chrome via
// tools/fingerprint/probes/media-feature-forms.js.
test "MediaQuery: resolution accepts fractions, dpi and dpcm" {
    const v = Viewport.default; // devicePixelRatio 2

    // Fractional dppx, in the forms the binary search produces.
    try testing.expect(matches("(min-resolution: 0.625dppx)", v));
    try testing.expect(matches("(min-resolution:0.625dppx)", v));
    try testing.expect(matches("(min-resolution: 0.5x)", v));
    try testing.expect(matches("(min-resolution: 0dppx)", v));
    // A leading dot is a valid CSS number; Chrome serializes it back as 0.625.
    try testing.expect(matches("(min-resolution: .625dppx)", v));
    try testing.expect(matches("(min-resolution: 1.5dppx)", v));
    try testing.expect(!matches("(min-resolution: 2.5dppx)", v));

    // dpi that is not a multiple of 96, and the max- form.
    try testing.expect(matches("(min-resolution: 50dpi)", v));
    try testing.expect(matches("(max-resolution: 256dpi)", v));
    try testing.expect(!matches("(max-resolution: 50dpi)", v));

    // dpcm: 1in is 2.54cm and CSS fixes 1in at 96px, so 1dppx is ~37.8dpcm and
    // this persona's 2dppx is ~75.6.
    try testing.expect(matches("(min-resolution: 30dpcm)", v));
    try testing.expect(!matches("(max-resolution: 30dpcm)", v));
    try testing.expect(!matches("(max-resolution: 50dpcm)", v));
    try testing.expect(matches("(max-resolution: 80dpcm)", v));

    // Still fails closed on a malformed value: a bare number is not a
    // resolution, `5.` is not a CSS number, and negatives are rejected.
    try testing.expect(!matches("(min-resolution: 1)", v));
    try testing.expect(!matches("(min-resolution: 5.dppx)", v));
    try testing.expect(!matches("(min-resolution: -1dppx)", v));
    try testing.expect(!matches("(min-resolution: dppx)", v));
}

// `color-index` and `monochrome` are both 0 on this persona, so every `max-`
// bound is satisfied and only a 0 `min-` bound is. Sharing one `== 0` between
// the bare feature and its `max-` form answers the `max-` form backwards.
test "MediaQuery: max-color-index and max-monochrome compare, not equate" {
    const v = Viewport.default;
    try testing.expect(matches("(max-color-index: 4)", v));
    try testing.expect(matches("(max-color-index: 0)", v));
    try testing.expect(matches("(max-monochrome: 4)", v));
    try testing.expect(matches("(max-monochrome: 0)", v));

    // The min- forms only match a 0 bound, and the bare forms only the value.
    try testing.expect(matches("(min-color-index: 0)", v));
    try testing.expect(!matches("(min-color-index: 4)", v));
    try testing.expect(matches("(min-monochrome: 0)", v));
    try testing.expect(!matches("(min-monochrome: 4)", v));
    try testing.expect(!matches("(color-index: 4)", v));
    try testing.expect(!matches("(monochrome: 4)", v));

    // `grid` is a discrete feature with no range prefix — measured false in
    // Chrome for both, so recognising them here would be the anomaly.
    try testing.expect(!matches("(max-grid: 0)", v));
    try testing.expect(!matches("(min-grid: 0)", v));
}

test "MediaQuery: ratio terms may be decimals" {
    const v = Viewport.default; // 1920x1080 = 1.777...
    try testing.expect(matches("(max-aspect-ratio: 2.125)", v));
    try testing.expect(matches("(max-device-aspect-ratio: 2.125)", v));
    try testing.expect(matches("(min-aspect-ratio: 1.5/2.5)", v));
    // 1.7 is below 1920/1080, so these stay false — the decimal has to be
    // parsed, not just accepted.
    try testing.expect(!matches("(max-aspect-ratio: 1.7)", v));
    try testing.expect(!matches("(aspect-ratio: 1.5)", v));
    try testing.expect(matches("(min-aspect-ratio: 1.7)", v));
}

// device-posture ships in Chrome and answers `continuous` on a desktop. It is
// one expression, and not recognising the feature name at all answers false to
// both values — which no real browser does.
test "MediaQuery: device-posture is continuous" {
    const v = Viewport.default;
    try testing.expect(matches("(device-posture: continuous)", v));
    try testing.expect(!matches("(device-posture: folded)", v));
    try testing.expect(!matches("(device-posture: none)", v));
    try testing.expect(matches("(device-posture)", v));
}

test "MediaQuery: malformed value is false" {
    const v = Viewport.default;
    try testing.expect(!matches("(min-width: foo)", v));
    try testing.expect(!matches("(min-width:)", v));
    try testing.expect(!matches("(min-width: 100xx)", v));
    // A unitless non-zero is not a length; a unitless zero is.
    try testing.expect(!matches("(min-width: 100)", v));
    try testing.expect(matches("(min-width: 0)", v));
    // A negative `<length>` is well-formed — useless as a bound, but every
    // viewport is above it. Measured; `<resolution>` and `<ratio>` are the two
    // that reject a negative outright.
    try testing.expect(matches("(min-width: -100px)", v));
    try testing.expect(!matches("(max-width: -100px)", v));
}

test "MediaQuery: boolean form (feature presence)" {
    const v = Viewport.default;
    try testing.expect(matches("(width)", v));
    try testing.expect(matches("(height)", v));
    try testing.expect(matches("(orientation)", v));
    // Zero-valued features are false in the boolean form; a colour screen has
    // monochrome 0, color-index 0 and grid 0, but a non-zero `color`.
    try testing.expect(!matches("(monochrome)", v));
    try testing.expect(!matches("(color-index)", v));
    try testing.expect(!matches("(grid)", v));
    try testing.expect(matches("(color)", v));
    // `none`-valued ones are false too; the rest are true.
    try testing.expect(!matches("(forced-colors)", v));
    try testing.expect(matches("(hover)", v));
    try testing.expect(matches("(pointer)", v));
    try testing.expect(matches("(prefers-color-scheme)", v));
}

test "MediaQuery: viewport-default values" {
    const v = Viewport.default;
    try testing.expectEqual(@as(u32, 1920), v.width);
    try testing.expectEqual(@as(u32, 1080), v.height);
}

test "MediaQuery: leading whitespace and case" {
    const v = Viewport.default;
    try testing.expect(matches("  (MIN-WIDTH: 600PX)  ", v));
    try testing.expect(matches("SCREEN AND (Min-Width: 600px)", v));
}

test "MediaQuery: malformed query is false" {
    const v = Viewport.default;
    try testing.expect(!matches("(", v));
    try testing.expect(!matches("(min-width: 600px", v));
    try testing.expect(!matches("@@@", v));
}

test "MediaQuery: not print is true on screen viewport" {
    // Common pattern: `<style media="not print">`
    const v = Viewport.default;
    try testing.expect(matches("not print", v));
}

test "MediaQuery: common responsive breakpoint" {
    // Pattern: hide one of mobile/desktop CTA duplicates above a breakpoint.
    const v = Viewport.default; // 1920×1080 — desktop side.
    try testing.expect(matches("(min-width: 768px)", v));
    try testing.expect(!matches("(max-width: 767px)", v));
}

test "MediaQuery: comments are stripped" {
    const v = Viewport.default;
    // Comment between tokens.
    try testing.expect(matches("screen and /*hidden*/ (min-width: 1px)", v));
    // Comment at the start.
    try testing.expect(matches("/* leading */ screen", v));
    // Comment that would otherwise change parens depth.
    try testing.expect(matches("(min-width: /* hi */ 600px)", v));
    // Comment containing a comma — must not split the query.
    try testing.expect(matches("screen /*, print*/", v));
    // Unclosed comment falls through to the parser, which fails closed.
    try testing.expect(!matches("/* unterminated", v));
}

test "MediaQuery: em / rem overflow fails closed" {
    const v = Viewport.default;
    // 268435456 × 16 overflows u32 (would wrap to 0); the evaluator must
    // treat the length as unparseable and the query as non-matching.
    try testing.expect(!matches("(min-width: 268435456em)", v));
    try testing.expect(!matches("(min-width: 268435456rem)", v));
    // Just below the overflow threshold still parses (but doesn't match
    // because 268435455 × 16 > viewport width).
    try testing.expect(!matches("(min-width: 268435455em)", v));
}

test "MediaQuery: unimplemented units fail closed" {
    const v = Viewport.default;
    try testing.expect(!matches("(min-width: 5cm)", v));
    try testing.expect(!matches("(min-width: 50mm)", v));
    try testing.expect(!matches("(min-width: 10pt)", v));
    try testing.expect(!matches("(min-width: 1in)", v));
    try testing.expect(!matches("(min-width: 50vw)", v));
}

// MQ4's range form, which Kasada uses on x-hyatt alongside the legacy one.
// Every structural expectation here was measured on a headed Chrome through
// tools/fingerprint/probes/media-feature-forms.js — including which shapes are
// malformed, which is the half a "does it evaluate at all" probe cannot see.
test "MediaQuery: range syntax, one-sided" {
    const v = Viewport.default; // 1920x1080
    try testing.expect(matches("(width >= 600px)", v));
    try testing.expect(matches("(width >= 1920px)", v));
    try testing.expect(matches("(width <= 1920px)", v));
    try testing.expect(matches("(width = 1920px)", v));
    try testing.expect(matches("(width > 100px)", v));
    try testing.expect(matches("(width < 5000px)", v));
    try testing.expect(!matches("(width > 1920px)", v));
    try testing.expect(!matches("(width <= 600px)", v));
    try testing.expect(!matches("(width < 100px)", v));

    // The operator needs no surrounding whitespace; Chrome normalizes it back
    // in with a space either side.
    try testing.expect(matches("(width>100px)", v));
    try testing.expect(matches("(width>=1920px)", v));
    try testing.expect(!matches("(width>1920px)", v));

    try testing.expect(matches("(height > 100px)", v));
    try testing.expect(matches("(height >= 1080px)", v));
    try testing.expect(matches("(device-width > 100px)", v));
}

// `(100px < width)` is the same query as `(width > 100px)`: the value may sit
// on either side, and which side it is on flips the comparison.
test "MediaQuery: range syntax, feature on the right" {
    const v = Viewport.default;
    try testing.expect(matches("(100px < width)", v));
    try testing.expect(matches("(1920px = width)", v));
    try testing.expect(matches("(1920px <= width)", v));
    try testing.expect(!matches("(100px > width)", v));
    try testing.expect(!matches("(5000px < width)", v));
}

test "MediaQuery: range syntax, two-sided" {
    const v = Viewport.default;
    try testing.expect(matches("(600px <= width <= 5000px)", v));
    try testing.expect(matches("(600px < width < 5000px)", v));
    try testing.expect(matches("(5000px >= width >= 600px)", v));
    try testing.expect(!matches("(600px <= width <= 1200px)", v));

    // Both operators have to point the same way, and neither may be `=`.
    try testing.expect(!matches("(600px < width > 1200px)", v));
    try testing.expect(!matches("(600px <= width = 1200px)", v));
    try testing.expect(!matches("(600px = width = 1200px)", v));
}

test "MediaQuery: range syntax on the numeric descriptors" {
    const v = Viewport.default;
    try testing.expect(matches("(resolution = 2dppx)", v));
    try testing.expect(matches("(resolution >= 2dppx)", v));
    try testing.expect(matches("(resolution <= 2dppx)", v));
    try testing.expect(matches("(resolution > 50dpi)", v));
    try testing.expect(!matches("(resolution < 50dpi)", v));
    try testing.expect(!matches("(resolution > 2dppx)", v));
    try testing.expect(matches("(resolution > 1dppx)", v));

    try testing.expect(matches("(color = 10)", v));
    try testing.expect(matches("(color > 4)", v));
    try testing.expect(matches("(color <= 10)", v));
    try testing.expect(!matches("(color > 10)", v));
    try testing.expect(matches("(color > 8)", v));
    try testing.expect(matches("(color-index = 0)", v));
    try testing.expect(matches("(color-index >= 0)", v));
    try testing.expect(matches("(monochrome = 0)", v));
    try testing.expect(!matches("(monochrome > 0)", v));

    // A ratio still compares as a fraction: 16/9 and 1920/1080 are one value.
    try testing.expect(matches("(aspect-ratio = 16/9)", v));
    try testing.expect(matches("(aspect-ratio = 1920/1080)", v));
    try testing.expect(matches("(device-aspect-ratio = 8/5)", v));
    try testing.expect(matches("(aspect-ratio > 1.5)", v));
    try testing.expect(!matches("(aspect-ratio = 1.7)", v));
}

// Only range-type features take the range form. A discrete feature does not,
// and neither does an already-prefixed one — all measured false in Chrome, so
// evaluating them here would be the anomaly.
test "MediaQuery: range syntax is rejected where Chrome rejects it" {
    const v = Viewport.default;
    try testing.expect(!matches("(orientation = landscape)", v));
    try testing.expect(!matches("(hover = hover)", v));
    try testing.expect(!matches("(grid = 0)", v));
    try testing.expect(!matches("(device-posture = continuous)", v));
    try testing.expect(!matches("(min-width >= 600px)", v));
    try testing.expect(!matches("(max-width <= 5000px)", v));

    // Still fails closed on a malformed bound or a missing side.
    try testing.expect(!matches("(width >= 600)", v));
    try testing.expect(!matches("(width >= foo)", v));
    try testing.expect(!matches("(width >=)", v));
    try testing.expect(!matches("(>= 600px)", v));
    try testing.expect(!matches("(nonsense > 4)", v));
}

// A `<length>` is a fraction, and the comparison is against the fraction rather
// than a rounded one: 1920 clears 1919.5 and not 1920.5. All measured on Chrome
// 150 at a 1920-wide viewport, where the earlier integer-only reading answered
// false to every row here.
test "MediaQuery: decimal lengths compare as fractions" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 600.5px)", v));
    try testing.expect(matches("(min-width: 0.5em)", v));
    try testing.expect(matches("(width: 1920.0px)", v));
    try testing.expect(matches("(min-width: 1919.5px)", v));
    try testing.expect(!matches("(min-width: 1920.5px)", v));
    // 1em is 16px, so the boundary is at 120em.
    try testing.expect(matches("(min-width: 119.9375em)", v));
    try testing.expect(!matches("(min-width: 120.0625em)", v));
    // An exponent counts, and past the float32 range it clamps rather than
    // going infinite.
    try testing.expect(matches("(min-width: 1e2px)", v));
    try testing.expect(matches("(min-width: 1e-400px)", v));
    try testing.expect(!matches("(min-width: 1e400px)", v));
}

test "MediaQuery: whitespace-tight and -loose features" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width:600px)", v));
    try testing.expect(matches("( min-width : 600px )", v));
    try testing.expect(matches("(  min-width  :  600px  )", v));
}

test "MediaQuery: additional comment placements" {
    const v = Viewport.default;
    // Two adjacent comments between tokens.
    try testing.expect(matches("screen /*a*/ /*b*/ and (min-width: 1px)", v));
    // Comments on both sides of the feature content.
    try testing.expect(matches("(/*a*/ min-width: 600px /*b*/)", v));
    // Comment that contains a colon — must not be confused with the
    // feature's `:` separator.
    try testing.expect(matches("(/* foo:bar */ min-width: 600px)", v));
    // Comment that contains parens — must not derail paren matching.
    try testing.expect(matches("(min-width: 600px /* ) ( */ )", v));
}

test "MediaQuery: u32 boundaries on length" {
    const v = Viewport.default;
    // u32 max parses; the viewport (1920) doesn't reach it.
    try testing.expect(!matches("(min-width: 4294967295px)", v));
    // Beyond u32 max overflows parseInt and fails closed.
    try testing.expect(!matches("(min-width: 4294967296px)", v));
    try testing.expect(!matches("(min-width: 9999999999px)", v));
}

test "MediaQuery: empty parens" {
    const v = Viewport.default;
    try testing.expect(!matches("()", v));
    try testing.expect(!matches("(   )", v));
    try testing.expect(!matches("screen and ()", v));
}

test "MediaQuery: long AND chains" {
    const v = Viewport.default;
    try testing.expect(matches(
        "screen and (min-width: 600px) and (max-width: 2000px) and (orientation: landscape)",
        v,
    ));
    try testing.expect(!matches(
        "screen and (min-width: 600px) and (max-width: 1000px) and (orientation: landscape)",
        v,
    ));
}

test "MediaQuery: not all is always false" {
    try testing.expect(!matches("not all", Viewport.default));
}

test "MediaQuery: not applies to the whole query" {
    const v = Viewport.default;
    // For 1920×1080: (min-width:3000px)=false, (orientation:landscape)=true.
    // Combined feature match is false; `not` flips it to true.
    try testing.expect(matches("not (min-width: 3000px) and (orientation: landscape)", v));
    // Both branches true → combined true → `not` flips to false.
    try testing.expect(!matches("not (min-width: 1px) and (orientation: landscape)", v));
}

test "MediaQuery: multibyte UTF-8 tokens fail closed" {
    const v = Viewport.default;
    // Unsupported feature name with a multi-byte character.
    try testing.expect(!matches("(café-width: 600px)", v));
    // Multi-byte identifier in media-type position.
    try testing.expect(!matches("café", v));
}

test "MediaQuery: trailing unterminated comment fails closed" {
    const v = Viewport.default;
    // A valid prefix followed by an unbalanced `/* ...` must still evaluate
    // to false. Without an explicit guard, the inline comment-skipper would
    // silently consume the rest of the input and return whatever the prefix
    // already parsed to.
    try testing.expect(!matches("screen /* unterminated", v));
    try testing.expect(!matches("(min-width: 600px) /* unterminated", v));
    // Terminated then unterminated.
    try testing.expect(!matches("screen /* a */ /* b", v));
}
