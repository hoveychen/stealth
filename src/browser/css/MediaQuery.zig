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
//!
//! The interaction features and the display descriptors answer for one fixed
//! device persona, and it has to stay consistent with the rest of the fork:
//! an Apple GPU driving a 1920x1080 display at devicePixelRatio 1 with
//! `screen.colorDepth` 24, driven with a mouse. Every value below was measured
//! on a headed Chrome (tools/fingerprint, media-features probe) except the
//! three that follow from *this* persona rather than from the reference
//! laptop's built-in panel — see COLOR_BITS_PER_CHANNEL.
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
    if (rest.len == 0) return false;

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

fn matchesSingle(query: []const u8, viewport: Viewport) bool {
    var negate = false;
    var type_set: ?MediaType = null;
    var features_match = true;
    var saw_token = false;

    var i: usize = 0;
    while (i < query.len) {
        i = skipWsAndComments(query, i);
        if (i >= query.len) break;

        if (query[i] == '(') {
            const end = findClosingParen(query, i) orelse return false;
            const inner = query[i + 1 .. end];
            if (!evalFeature(inner, viewport)) features_match = false;
            saw_token = true;
            i = end + 1;
            continue;
        }

        const start = i;
        while (i < query.len and isIdentChar(query[i])) {
            i += 1;
        }

        const len = i - start;
        if (len < 2 or len > 16) {
            return false;
        }

        var word_buf: [16]u8 = undefined;
        const word = std.ascii.lowerString(&word_buf, query[start..i]);

        saw_token = true;
        if (std.mem.eql(u8, word, "not")) {
            negate = true;
        } else if (std.mem.eql(u8, word, "only")) {
            // 'only' is a hint to legacy parsers — treat as a no-op qualifier.
        } else if (std.mem.eql(u8, word, "and")) {
            // separator between media-type and feature, or between features.
        } else if (parseMediaType(word)) |t| {
            type_set = t;
        } else {
            // Unknown ident in media-type position: per spec the whole query
            // is treated as a non-matching type.
            return false;
        }
    }

    if (!saw_token) {
        return false;
    }

    const type_matches = if (type_set) |t|
        switch (t) {
            .all, .screen => true,
            .print, .speech, .tv => false,
        }
    else
        true;

    const result = type_matches and features_match;
    return if (negate) !result else result;
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

    if (indexOfScalarSkippingComments(trimmed, ':')) |colon| {
        const name = trimWsAndComments(trimmed[0..colon]);
        const value = trimWsAndComments(trimmed[colon + 1 ..]);
        return evalNameValue(name, value, viewport);
    }

    return evalBoolean(trimmed, viewport);
}

// Bits per colour channel. `screen.colorDepth` is 24 across three channels, so
// Chrome's `color` feature answers 8. The reference laptop reports 10 because
// its built-in panel is HDR; copying that while still reporting colorDepth 24
// would be a self-contradiction, so this persona's display is a plain 8-bit
// one. `color-gamut: srgb` and `dynamic-range: standard` follow from the same
// choice, for the same reason.
const COLOR_BITS_PER_CHANNEL: u32 = 8;

// A colour screen with no indexed palette and no monochrome depth. Both are the
// numbers Chrome reports (measured); they are named because the `min-` / `max-`
// forms only read right next to the value they compare against.
const COLOR_INDEX: u32 = 0;
const MONOCHROME_BITS: u32 = 0;

// devicePixelRatio, mirroring Window's own property. Held as a float because a
// resolution bound is a float: `(min-resolution: 0.625dppx)` has to compare
// against 1 without either side being rounded first.
const DEVICE_PIXEL_RATIO: f64 = 1;

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

    // The window box matches the viewport in this fork (see the screen section
    // of tools/fingerprint/README.md), so the device-* lengths are the same
    // numbers as the viewport ones.
    if (std.mem.eql(u8, lname, "min-device-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width >= px;
    }
    if (std.mem.eql(u8, lname, "max-device-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width <= px;
    }
    if (std.mem.eql(u8, lname, "device-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width == px;
    }
    if (std.mem.eql(u8, lname, "min-device-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height >= px;
    }
    if (std.mem.eql(u8, lname, "max-device-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height <= px;
    }
    if (std.mem.eql(u8, lname, "device-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height == px;
    }

    // `<ratio>` compares as a fraction, so it is done by cross-multiplication
    // rather than by dividing — 1920/1080 and 16/9 are the same ratio and have
    // to compare equal.
    if (std.mem.eql(u8, lname, "aspect-ratio") or std.mem.eql(u8, lname, "device-aspect-ratio")) {
        return compareRatio(value, viewport.width, viewport.height, .eq);
    }
    if (std.mem.eql(u8, lname, "min-aspect-ratio") or std.mem.eql(u8, lname, "min-device-aspect-ratio")) {
        return compareRatio(value, viewport.width, viewport.height, .ge);
    }
    if (std.mem.eql(u8, lname, "max-aspect-ratio") or std.mem.eql(u8, lname, "max-device-aspect-ratio")) {
        return compareRatio(value, viewport.width, viewport.height, .le);
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
    if (std.mem.eql(u8, lname, "color-gamut")) return std.ascii.eqlIgnoreCase(value, "srgb");
    if (std.mem.eql(u8, lname, "dynamic-range")) return std.ascii.eqlIgnoreCase(value, "standard");
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
    if (std.mem.eql(u8, lname, "dynamic-range")) return true;
    if (std.mem.eql(u8, lname, "prefers-color-scheme")) return true;
    if (std.mem.eql(u8, lname, "prefers-reduced-motion") or
        std.mem.eql(u8, lname, "prefers-reduced-transparency") or
        std.mem.eql(u8, lname, "prefers-contrast")) return true;

    return false;
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
    const unit = std.mem.trim(u8, split.rest, &std.ascii.whitespace);

    if (std.ascii.eqlIgnoreCase(unit, "dppx") or std.ascii.eqlIgnoreCase(unit, "x")) return split.value;
    // CSS fixes 1in at 96px, and an inch is 2.54cm.
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return split.value / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return split.value * 2.54 / 96.0;
    return null;
}

const NumberSplit = struct { value: f64, rest: []const u8 };

/// Scan a leading CSS `<number>` and return it with the unconsumed remainder,
/// which for a dimension is the unit. Digits, then an optional `.` fraction;
/// either part may be empty as long as the other is not, so `.625` parses and
/// bare `.` does not. A `.` with no digit after it is left for the unit, which
/// makes `5.dppx` malformed rather than `5` with a `.dppx` unit.
///
/// A leading `-` is rejected outright: `<resolution>` and `<ratio>` are both
/// non-negative in media features, and per MQ4 a negative one is malformed
/// rather than clamped.
fn splitNumber(s: []const u8) ?NumberSplit {
    var i: usize = 0;
    if (i < s.len and s[i] == '+') i += 1;

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
    return .{ .value = value, .rest = s[i..] };
}

/// A bare CSS `<number>` filling the whole of `value`, for `<ratio>` terms.
fn parseNumber(value: []const u8) ?f64 {
    const split = splitNumber(std.mem.trim(u8, value, &std.ascii.whitespace)) orelse return null;
    if (split.rest.len != 0) return null;
    return split.value;
}

/// A bare non-negative integer, for the numeric display descriptors.
fn parseInteger(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    for (trimmed) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

/// Parse `<int>px`, `<int>em` (1em=16px), `<int>rem`, or bare `0`.
/// Negative lengths are rejected per the Media Queries spec (`<length>` in
/// media features may not be negative). Returns null on any other form.
fn parseLengthPx(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '-') return null;

    var i: usize = 0;
    if (i < trimmed.len and trimmed[i] == '+') i += 1;
    const num_start = i;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i == num_start) return null;

    const num = std.fmt.parseInt(u32, trimmed[num_start..i], 10) catch return null;
    const unit = std.mem.trim(u8, trimmed[i..], &std.ascii.whitespace);

    if (unit.len == 0) {
        return if (num == 0) 0 else null;
    }
    if (std.ascii.eqlIgnoreCase(unit, "px")) return num;
    // `em` / `rem`: 1em = 16px. `std.math.mul` returns an error on u32 overflow
    // (e.g. `268435456em` would otherwise wrap or panic in debug); treat that
    // as an unparseable length so the query fails closed per MQ4.
    if (std.ascii.eqlIgnoreCase(unit, "em")) return std.math.mul(u32, num, 16) catch null;
    if (std.ascii.eqlIgnoreCase(unit, "rem")) return std.math.mul(u32, num, 16) catch null;
    return null;
}

const testing = std.testing;

test "MediaQuery: empty query is false" {
    try testing.expect(!matches("", Viewport.default));
    try testing.expect(!matches("   ", Viewport.default));
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
    try testing.expect(matches("(device-width: 1920px) and (device-height: 1080px)", v));

    // These three follow from this fork's persona (colorDepth 24, dpr 1)
    // rather than from the reference laptop's HDR panel — see the header.
    try testing.expect(matches("(color-gamut: srgb)", v));
    try testing.expect(!matches("(color-gamut: p3)", v));
    try testing.expect(matches("(color: 8)", v));
    try testing.expect(!matches("(color: 10)", v));
    try testing.expect(matches("(dynamic-range: standard)", v));
    try testing.expect(!matches("(dynamic-range: high)", v));

    try testing.expect(matches("(prefers-contrast: no-preference)", v));
    try testing.expect(matches("(prefers-reduced-transparency: no-preference)", v));
    try testing.expect(matches("(update: fast)", v));
    try testing.expect(matches("(scripting: enabled)", v));
    try testing.expect(matches("(overflow-block: scroll)", v));
    try testing.expect(matches("(overflow-inline: scroll)", v));
    try testing.expect(matches("(grid: 0)", v));
    try testing.expect(matches("(color-index: 0)", v));
    try testing.expect(matches("(resolution: 1dppx)", v));
    try testing.expect(matches("(resolution: 96dpi)", v));
    try testing.expect(!matches("(resolution: 2dppx)", v));
}

test "MediaQuery: ratio compares as a fraction, not a division" {
    const v = Viewport.default; // 1920x1080
    try testing.expect(matches("(device-aspect-ratio: 16/9)", v));
    try testing.expect(matches("(device-aspect-ratio: 1920/1080)", v));
    try testing.expect(matches("(aspect-ratio: 16/9)", v));
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
    const v = Viewport.default; // devicePixelRatio 1

    // Fractional dppx, in the forms the binary search produces.
    try testing.expect(matches("(min-resolution: 0.625dppx)", v));
    try testing.expect(matches("(min-resolution:0.625dppx)", v));
    try testing.expect(matches("(min-resolution: 0.5x)", v));
    try testing.expect(matches("(min-resolution: 0dppx)", v));
    // A leading dot is a valid CSS number; Chrome serializes it back as 0.625.
    try testing.expect(matches("(min-resolution: .625dppx)", v));
    try testing.expect(!matches("(min-resolution: 1.5dppx)", v));

    // dpi that is not a multiple of 96, and the max- form.
    try testing.expect(matches("(min-resolution: 50dpi)", v));
    try testing.expect(matches("(max-resolution: 256dpi)", v));
    try testing.expect(!matches("(max-resolution: 50dpi)", v));

    // dpcm: 1in is 2.54cm and CSS fixes 1in at 96px, so 1dppx is ~37.8dpcm.
    try testing.expect(matches("(min-resolution: 30dpcm)", v));
    try testing.expect(!matches("(max-resolution: 30dpcm)", v));
    try testing.expect(matches("(max-resolution: 50dpcm)", v));

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
    try testing.expect(!matches("(min-width: -100px)", v));
    try testing.expect(!matches("(min-width: 100xx)", v));
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

test "MediaQuery: range syntax is unsupported (fails closed)" {
    const v = Viewport.default;
    // MQ4 range form is not implemented — should evaluate false rather than
    // accidentally matching via the `width` boolean form.
    try testing.expect(!matches("(width >= 600px)", v));
    try testing.expect(!matches("(width <= 600px)", v));
    try testing.expect(!matches("(width < 100px)", v));
    try testing.expect(!matches("(600px <= width <= 1200px)", v));
}

test "MediaQuery: decimal lengths are rejected" {
    const v = Viewport.default;
    try testing.expect(!matches("(min-width: 600.5px)", v));
    try testing.expect(!matches("(min-width: 0.5em)", v));
    try testing.expect(!matches("(width: 1920.0px)", v));
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
