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

// `text-transform`, as one implementation for both the readers of it.
//
// There are two: `innerText`, which returns the transformed characters, and the
// measurement, which has to charge the transformed characters' advances. They
// were one and a half -- `innerText` had a byte-wise ASCII version and the
// measurement had nothing at all, so a `text-transform: uppercase` element read
// as uppercase and measured as though it did not. This file exists so the two
// cannot drift again.
//
// Everything below is Chrome 151, measured character by character over
// U+0000..U+00FF (scratch/b102/expr-tt-detail.js for the ASCII half,
// scratch/b102/expr-tt-latin1-boundary.js for the Latin-1 half). Above U+00FF
// nothing is mapped, and that is a decision with a reading behind it rather
// than a shrug: this engine has no advance for a character above U+00FF and
// charges the family's mean, so the strings there measure wrong BEFORE any
// transform -- 'U+01F3 U+01C6 U+01C9' spaced out is 46.8203125 in Chrome and
// 32.484375 here. Mapping them would swap one wrong width for another.

const std = @import("std");

/// The four values Chrome 151 accepts that do anything, plus `none`.
///
/// `math-auto` is accepted and left out on purpose: it italicises single-letter
/// MathML identifiers and does nothing to the Latin text this measures.
/// `full-width` and `full-size-kana` are not here because Chrome REFUSES them --
/// the declaration is dropped and the previous value survives, measured in
/// `element/text_transform_layout.html`'s keyword block.
pub const Transform = enum {
    none,
    uppercase,
    lowercase,
    capitalize,

    /// One declaration's value, or `.none` for anything unrecognised. Case
    /// insensitive: Chrome takes `UPPERCASE`.
    pub fn of(value: ?[]const u8) Transform {
        const raw = value orelse return .none;
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "uppercase")) return .uppercase;
        if (std.ascii.eqlIgnoreCase(trimmed, "lowercase")) return .lowercase;
        if (std.ascii.eqlIgnoreCase(trimmed, "capitalize")) return .capitalize;
        return .none;
    }
};

/// What a character does to `capitalize`'s idea of where a word starts.
///
/// Three classes and not two, which is the finding this file is built on. The
/// obvious model -- "white space separates words" -- gets thirty ASCII
/// characters wrong, and the next obvious one -- "anything that is not a letter
/// or a digit separates words" -- gets `'` and U+00AD and U+00B7 wrong in the
/// opposite direction.
pub const Class = enum {
    /// Resets the flag, so the next word character is titlecased.
    /// `x-y` capitalises to `X-Y`.
    separator,
    /// Neither resets the flag nor consumes it. `x'y` stays `X'y` -- the
    /// apostrophe joins the word, so `y` is not a word start -- and `'xy`
    /// becomes `'Xy` -- at the front it joins nothing, so `x` still is one.
    joiner,
    /// Consumes the flag, and is titlecased if it has a titlecase. `_xy` stays
    /// `_xy` and `1xy` stays `1xy`: both consumed the word start and neither has
    /// a case.
    word,
};

/// `codepoint`'s class. Measured for every value in U+0000..U+00FF; above that
/// everything is a word character, which is right for the letters and
/// ideographs that make up almost all of it and wrong for the punctuation --
/// and, either way, unmeasurable here for want of an advance.
pub fn classify(codepoint: u21) Class {
    return switch (codepoint) {
        // Digits, letters and the low line, which UAX#29 joins into words.
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => .word,
        // The apostrophe is UAX#29's MidLetter.
        '\'' => .joiner,
        // Every other ASCII character separates, including the whole control
        // range and every other punctuation mark. Measured one at a time: the
        // thirty printable ones all give 'X<c>Y'.
        0x00...0x26, 0x28...0x2f, 0x3a...0x40, 0x5b...0x5e, 0x60, 0x7b...0x7f => .separator,
        // Latin-1. The letter runs are U+00C0..U+00D6, U+00D8..U+00F6 and
        // U+00F8..U+00FF, with the two signs that sit inside them -- U+00D7
        // MULTIPLICATION and U+00F7 DIVISION -- separating instead. The four
        // strays are the feminine and masculine ordinals, the micro sign and
        // the cedilla, all of which consume the word start.
        0x00aa, 0x00b5, 0x00b8, 0x00ba, 0x00c0...0x00d6, 0x00d8...0x00f6, 0x00f8...0x00ff => .word,
        // The soft hyphen and the middle dot join, exactly as the apostrophe
        // does: 'x<c>y' keeps its lower-case 'y' and '<c>xy' still capitalises.
        0x00ad, 0x00b7 => .joiner,
        // The rest of Latin-1's punctuation and symbols separate -- including
        // the two signs inside the letter runs, which is the pair a range-based
        // reading of this table gets wrong: the first version of this switch
        // left U+00D7 and U+00F7 to fall through to `.word` below, and
        // 'x U+00D7 y' capitalised to 'X U+00D7 y' where Chrome says
        // 'X U+00D7 Y'.
        0x00a0...0x00a9, 0x00ab, 0x00ac, 0x00ae...0x00b4, 0x00b6, 0x00b9, 0x00bb...0x00bf, 0x00d7, 0x00f7 => .separator,
        else => .word,
    };
}

/// One codepoint's mapping: one character, or two for the single case in
/// U+0000..U+00FF that lengthens -- U+00DF uppercases to 'SS'.
pub const Mapped = struct {
    first: u21,
    second: ?u21 = null,

    pub fn len(self: Mapped) u2 {
        return if (self.second == null) 1 else 2;
    }
};

/// `codepoint` uppercased.
///
/// Two of the targets leave Latin-1: U+00FF goes to U+0178 and U+00B5 to
/// U+039C. They are mapped anyway, because `innerText` returning the right
/// characters costs nothing and is itself the surface a page reads -- but their
/// WIDTH cannot be right, since neither target has an advance here (U+0178 is
/// 11.5546875 in Chrome and 8.1640625 here, the family mean). That is a swap of
/// one wrong width for another, and the right characters, so it is worth it. No
/// width is asserted for either.
pub fn upper(codepoint: u21) Mapped {
    return switch (codepoint) {
        'a'...'z' => .{ .first = codepoint - 0x20 },
        // Two characters out of one, and the only such case in range.
        0x00df => .{ .first = 'S', .second = 'S' },
        0x00b5 => .{ .first = 0x039c },
        0x00ff => .{ .first = 0x0178 },
        // The two letter runs, skipping U+00F7 DIVISION SIGN, which is not a
        // letter and whose 'uppercase' under a bare -0x20 rule would be U+00D7
        // MULTIPLICATION SIGN -- a different character entirely.
        0x00e0...0x00f6, 0x00f8...0x00fe => .{ .first = codepoint - 0x20 },
        else => .{ .first = codepoint },
    };
}

/// `codepoint` lowercased. No case in range lengthens, and U+00D7 is skipped
/// for the same reason U+00F7 is above.
pub fn lower(codepoint: u21) Mapped {
    return switch (codepoint) {
        'A'...'Z' => .{ .first = codepoint + 0x20 },
        0x00c0...0x00d6, 0x00d8...0x00de => .{ .first = codepoint + 0x20 },
        else => .{ .first = codepoint },
    };
}

/// `codepoint` titlecased, which is what `capitalize` applies at a word start.
///
/// It is NOT the uppercase, and exactly one character in range says so: U+00DF
/// uppercases to 'SS' and titlecases to itself. Chrome capitalises
/// 'U+00DF xy' to 'U+00DF Xy', measured -- the first version of this file used
/// `upper` here and produced 'SSxy'. Everything else in range shares its
/// uppercase, including the two whose target leaves Latin-1.
pub fn title(codepoint: u21) Mapped {
    if (codepoint == 0x00df) return .{ .first = codepoint };
    return upper(codepoint);
}

/// One codepoint under `transform`, with `at_word_start` carried across the
/// call so `capitalize` survives a word split over two text nodes.
pub fn map(codepoint: u21, transform: Transform, at_word_start: *bool) Mapped {
    switch (transform) {
        .none => return .{ .first = codepoint },
        .uppercase => return upper(codepoint),
        .lowercase => return lower(codepoint),
        .capitalize => {
            switch (classify(codepoint)) {
                .separator => {
                    at_word_start.* = true;
                    return .{ .first = codepoint };
                },
                .joiner => return .{ .first = codepoint },
                .word => {
                    if (!at_word_start.*) return .{ .first = codepoint };
                    at_word_start.* = false;
                    return title(codepoint);
                },
            }
        },
    }
}

/// The same mapping, without touching the caller's word-start flag.
///
/// For a caller that wants one character as it will RENDER and is not walking a
/// run: the codepoints on either side of a space, which the layout paths charge
/// a kern pair for and which have to be the transformed ones.
pub fn mapAt(codepoint: u21, transform: Transform, at_word_start: bool) Mapped {
    var flag = at_word_start;
    return map(codepoint, transform, &flag);
}

/// The first and last codepoints of `src` as `transform` renders them.
///
/// The layout paths chop text at white space and charge the space themselves,
/// which means they hold the characters either side of the chop and ask the
/// space-pair table about them (see font_space_kerning.zig). Those characters
/// have to be the transformed ones: 'hello world' under `uppercase` kerns
/// ' W' and not ' w', and the two differ by 0.28125 at 16px serif -- exactly
/// the residual every box row of element/text_transform_layout.html showed
/// while this walked the source text instead.
///
/// The whole slice is walked rather than just its ends, because the LAST
/// character's mapping depends on the flag as it stood when the walk reached it:
/// under `capitalize`, 'a' alone is 'A' and the 'a' of 'ab' is not.
pub fn edges(src: []const u8, transform: Transform, at_word_start: bool) struct { first: ?u21, last: ?u21 } {
    var flag = at_word_start;
    var first: ?u21 = null;
    var last: ?u21 = null;
    var it = std.unicode.Utf8Iterator{ .bytes = src, .i = 0 };
    while (it.nextCodepoint()) |codepoint| {
        const mapped = map(codepoint, transform, &flag);
        if (first == null) first = mapped.first;
        last = mapped.second orelse mapped.first;
    }
    return .{ .first = first, .last = last };
}

/// `src` transformed, written into `dest`, which must be at least `src.len`
/// long. Returns the written slice.
///
/// Every mapping in range keeps the UTF-8 length: the ASCII pairs are one byte
/// each, the Latin-1 pairs two each, U+00DF's two bytes become 'S' 'S', and the
/// two targets outside Latin-1 are still two bytes. So `dest.len == src.len`
/// suffices and the result is exactly as long as the input -- which is what lets
/// the callers that only ask predicates of the text (does it hold a newline, is
/// it all collapsible white space) skip the transform entirely: no mapping in
/// range turns white space into anything else or anything else into white space.
/// `text_case: the transform keeps every byte length` asserts both.
pub fn write(dest: []u8, src: []const u8, transform: Transform, at_word_start: *bool) []const u8 {
    if (transform == .none) return src;
    std.debug.assert(dest.len >= src.len);

    var out: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = src, .i = 0 };
    while (it.i < src.len) {
        const before = it.i;
        const codepoint = it.nextCodepoint() orelse break;
        const mapped = map(codepoint, transform, at_word_start);
        var wrote: usize = 0;
        wrote += std.unicode.utf8Encode(mapped.first, dest[out..]) catch {
            // Cannot happen for anything `map` returns, and if it ever did the
            // honest answer is the bytes as written rather than a truncation.
            @memcpy(dest[out..][0 .. it.i - before], src[before..it.i]);
            out += it.i - before;
            continue;
        };
        if (mapped.second) |second| {
            wrote += std.unicode.utf8Encode(second, dest[out + wrote ..]) catch 0;
        }
        out += wrote;
    }
    return dest[0..out];
}

const testing = std.testing;

test "text_case: the transform keeps every byte length" {
    // The property the callers lean on, over the whole range that is mapped.
    var buf: [8]u8 = undefined;
    var src: [4]u8 = undefined;
    for (0..0x100) |c| {
        const codepoint: u21 = @intCast(c);
        // Surrogates and the like are not in this range, so every value encodes.
        const src_len = std.unicode.utf8Encode(codepoint, &src) catch unreachable;
        for ([_]Transform{ .uppercase, .lowercase, .capitalize }) |transform| {
            var at_word_start = true;
            const out = write(&buf, src[0..src_len], transform, &at_word_start);
            try testing.expectEqual(src_len, out.len);
        }
    }
}

test "text_case: no mapping creates or destroys white space" {
    // The other property the predicate-only callers lean on: `isCollapsibleWhitespace`
    // and the newline scan read the text as written, and they may.
    var buf: [8]u8 = undefined;
    var src: [4]u8 = undefined;
    const collapsible = " \t\n\r\x0c";
    for (0..0x100) |c| {
        const codepoint: u21 = @intCast(c);
        const src_len = std.unicode.utf8Encode(codepoint, &src) catch unreachable;
        const was_space = c < 0x80 and std.mem.indexOfScalar(u8, collapsible, @intCast(c)) != null;
        for ([_]Transform{ .uppercase, .lowercase, .capitalize }) |transform| {
            var at_word_start = true;
            const out = write(&buf, src[0..src_len], transform, &at_word_start);
            const is_space = out.len == 1 and std.mem.indexOfScalar(u8, collapsible, out[0]) != null;
            try testing.expectEqual(was_space, is_space);
        }
    }
}

test "text_case: the three classes Chrome's capitalize uses" {
    // A sample of each, from the two sweeps. The full sweep is asserted in
    // element/text_transform_layout.html, where it can be read off Chrome; this
    // pins the boundaries of the ranges above.
    try testing.expectEqual(Class.separator, classify(' '));
    try testing.expectEqual(Class.separator, classify('-'));
    try testing.expectEqual(Class.separator, classify('('));
    try testing.expectEqual(Class.separator, classify(0x00a0));
    try testing.expectEqual(Class.separator, classify(0x00d7));
    try testing.expectEqual(Class.separator, classify(0x00f7));
    try testing.expectEqual(Class.joiner, classify('\''));
    try testing.expectEqual(Class.joiner, classify(0x00ad));
    try testing.expectEqual(Class.joiner, classify(0x00b7));
    try testing.expectEqual(Class.word, classify('_'));
    try testing.expectEqual(Class.word, classify('7'));
    try testing.expectEqual(Class.word, classify(0x00aa));
    try testing.expectEqual(Class.word, classify(0x00b5));
    try testing.expectEqual(Class.word, classify(0x00b8));
    try testing.expectEqual(Class.word, classify(0x00ba));
    try testing.expectEqual(Class.word, classify(0x00e9));
}

test "text_case: capitalize carries its word start across a call" {
    // The reason `at_word_start` is a pointer: 'ab' and 'cd' in two text nodes
    // are one word, and 'a ' and ' b' are two.
    var buf: [16]u8 = undefined;
    var at_word_start = true;
    try testing.expectEqualStrings("Ab", write(&buf, "ab", .capitalize, &at_word_start));
    var second: [16]u8 = undefined;
    try testing.expectEqualStrings("cd", write(&second, "cd", .capitalize, &at_word_start));

    at_word_start = true;
    try testing.expectEqualStrings("A ", write(&buf, "a ", .capitalize, &at_word_start));
    try testing.expectEqualStrings("B", write(&second, "b", .capitalize, &at_word_start));
}

test "text_case: the mappings that a plus-or-minus 0x20 rule gets wrong" {
    var buf: [16]u8 = undefined;
    var at_word_start = true;
    // U+00DF -> 'SS', two characters and the same two bytes.
    try testing.expectEqualStrings("SS", write(&buf, "\u{00df}", .uppercase, &at_word_start));
    // U+00D7 and U+00F7 are not letters, so neither moves either way.
    at_word_start = true;
    try testing.expectEqualStrings("\u{00d7}", write(&buf, "\u{00d7}", .lowercase, &at_word_start));
    at_word_start = true;
    try testing.expectEqualStrings("\u{00f7}", write(&buf, "\u{00f7}", .uppercase, &at_word_start));
    // The two targets outside Latin-1.
    at_word_start = true;
    try testing.expectEqualStrings("\u{0178}", write(&buf, "\u{00ff}", .uppercase, &at_word_start));
    at_word_start = true;
    try testing.expectEqualStrings("\u{039c}", write(&buf, "\u{00b5}", .uppercase, &at_word_start));
    // And nothing above U+00FF is touched.
    at_word_start = true;
    try testing.expectEqualStrings("\u{01f3}", write(&buf, "\u{01f3}", .uppercase, &at_word_start));
}

test "text_case: titlecase is not uppercase for U+00DF" {
    // The one character in range whose two mappings differ. `capitalize` has to
    // take the titlecase, which is itself -- Chrome capitalises
    // 'U+00DF xy' to 'U+00DF Xy' and not to 'SSxy'.
    var buf: [16]u8 = undefined;
    var at_word_start = true;
    try testing.expectEqualStrings("\u{00df}xy", write(&buf, "\u{00df}xy", .capitalize, &at_word_start));
    at_word_start = true;
    // ...where `uppercase` takes the 'x' and the 'y' with it, since it maps
    // every character and not only the one at a word start.
    try testing.expectEqualStrings("SSXY", write(&buf, "\u{00df}xy", .uppercase, &at_word_start));
    // ...and the word after it still capitalises.
    at_word_start = true;
    try testing.expectEqualStrings("\u{00df} Stra\u{00df}e", write(&buf, "\u{00df} stra\u{00df}e", .capitalize, &at_word_start));
}

test "text_case: edges reports the characters a kern pair would see" {
    // 'hello world' uppercased kerns ' W', not ' w'.
    const upper_word = edges("world", .uppercase, true);
    try testing.expectEqual(@as(?u21, 'W'), upper_word.first);
    try testing.expectEqual(@as(?u21, 'D'), upper_word.last);

    // Under capitalize the last character of a multi-character word is NOT at a
    // word start, so it stays as written -- and a one-character word is.
    const cap_word = edges("world", .capitalize, true);
    try testing.expectEqual(@as(?u21, 'W'), cap_word.first);
    try testing.expectEqual(@as(?u21, 'd'), cap_word.last);
    const cap_one = edges("a", .capitalize, true);
    try testing.expectEqual(@as(?u21, 'A'), cap_one.first);
    try testing.expectEqual(@as(?u21, 'A'), cap_one.last);
    // ...and a word reached mid-word keeps its first character too.
    const cap_mid = edges("world", .capitalize, false);
    try testing.expectEqual(@as(?u21, 'w'), cap_mid.first);

    // The two-character mapping reports the SECOND character as the last one,
    // because that is what the next pair sees.
    const two = edges("stra\u{00df}", .uppercase, true);
    try testing.expectEqual(@as(?u21, 'S'), two.first);
    try testing.expectEqual(@as(?u21, 'S'), two.last);

    // Nothing declared is the characters as written.
    const plain = edges("world", .none, true);
    try testing.expectEqual(@as(?u21, 'w'), plain.first);
    try testing.expectEqual(@as(?u21, 'd'), plain.last);
    // And an empty slice has no ends.
    const empty = edges("", .uppercase, true);
    try testing.expectEqual(@as(?u21, null), empty.first);
    try testing.expectEqual(@as(?u21, null), empty.last);
}
