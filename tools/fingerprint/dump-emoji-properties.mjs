// Prints the two Unicode emoji properties that src/browser/emoji_properties.zig
// is transcribed from.
//
//   node tools/fingerprint/dump-emoji-properties.mjs        # ranges as JSON
//   node tools/fingerprint/dump-emoji-properties.mjs --zig > src/browser/emoji_properties.zig
//
// Both are read out of the ICU tables the JS engine already carries, by asking
// `\p{Emoji}` and `\p{Emoji_Presentation}` about every codepoint, rather than
// transcribing a Unicode data file by hand. They are what decides which font a
// run of text is shaped with (UTS #51): U+1F600 reaches for a colour emoji
// font on its own, U+2600 only when U+FE0F follows it, and measureText answers
// 20, 16 and 20 for the three cases at 16px sans-serif.

const MAX = 0x10ffff;

const PROPERTIES = [
  { name: 'emoji', pattern: /\p{Emoji}/u },
  { name: 'presentation', pattern: /\p{Emoji_Presentation}/u },
];

const tables = PROPERTIES.map(({ name, pattern }) => ({ name, ranges: scan(pattern) }));

if (!process.argv.includes('--zig')) {
  const json = Object.fromEntries(
    tables.map(({ name, ranges }) => [name, ranges.map(([a, b]) => [hex(a), hex(b)])]),
  );
  console.log(JSON.stringify(json, null, 1));
} else {
  process.stdout.write(toZig(tables));
}

function scan(pattern) {
  const ranges = [];
  let start = -1;
  for (let code = 0; code <= MAX; code++) {
    const on = pattern.test(String.fromCodePoint(code));
    if (on && start < 0) start = code;
    if (!on && start >= 0) {
      ranges.push([start, code - 1]);
      start = -1;
    }
  }
  if (start >= 0) ranges.push([start, MAX]);
  return ranges;
}

function hex(code) {
  return code.toString(16).toUpperCase().padStart(4, '0');
}

function count(ranges) {
  return ranges.reduce((n, [a, b]) => n + b - a + 1, 0);
}

function body(ranges) {
  return ranges
    .map(([a, b]) => {
      const label = a === b ? String.fromCodePoint(a) : `${String.fromCodePoint(a)}..${String.fromCodePoint(b)}`;
      return `    .{ .first = 0x${hex(a)}, .last = 0x${hex(b)} }, // ${label}`;
    })
    .join('\n');
}

function toZig(data) {
  const emoji = data.find((t) => t.name === 'emoji').ranges;
  const presentation = data.find((t) => t.name === 'presentation').ranges;

  return `// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// GENERATED — do not hand-edit. Produced by
//   node tools/fingerprint/dump-emoji-properties.mjs --zig
//
// The two Unicode properties that say whether a character is drawn from a
// colour emoji font, and so which advance measureText reports for it.
//
//   Emoji               ${String(count(emoji)).padStart(4)} codepoints — may be drawn as an emoji.
//   Emoji_Presentation  ${String(count(presentation)).padStart(4)} codepoints — is, unless told otherwise.
//
// The second is a subset of the first, and the gap between them is what a
// variation selector is for (UTS #51, ED-8): U+2600 is Emoji but not
// Emoji_Presentation, so Chrome measures it in the text font at 16px
// sans-serif and answers 16 — and answers 20, a colour emoji's advance, for
// U+2600 U+FE0F. U+1F600 needs no selector and answers 20 on its own.
//
// Read out of ICU rather than a Unicode data file, so the table is whatever
// the JS engine that generated it believed; a newer Unicode adds codepoints
// here but does not move the ones already present.

const Range = struct {
    first: u21,
    last: u21,
};

/// Ascending and disjoint, so \`contains\` can bisect.
const emoji = [_]Range{
${body(emoji)}
};

/// Ascending and disjoint, and a subset of \`emoji\`.
const presentation = [_]Range{
${body(presentation)}
};

/// Whether \`codepoint\` can be drawn as an emoji at all, with or without a
/// variation selector asking for it.
pub fn isEmoji(codepoint: u21) bool {
    return contains(&emoji, codepoint);
}

/// Whether \`codepoint\` is drawn as a colour emoji when nothing says otherwise.
pub fn isDefaultPresentation(codepoint: u21) bool {
    return contains(&presentation, codepoint);
}

fn contains(ranges: []const Range, codepoint: u21) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (codepoint < range.first) {
            high = mid;
        } else if (codepoint > range.last) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

const std = @import("std");

test "emoji_properties: spot-checked against the ICU tables they came from" {
    // Default emoji presentation, so measureText charges a colour emoji.
    try std.testing.expect(isDefaultPresentation(0x1f600)); // 😀
    try std.testing.expect(isDefaultPresentation(0x1f3e0)); // 🏠
    try std.testing.expect(isDefaultPresentation(0x231a)); // ⌚, the lowest one

    // Emoji, but text presentation until a selector says otherwise.
    try std.testing.expect(isEmoji(0x2600) and !isDefaultPresentation(0x2600)); // ☀
    try std.testing.expect(isEmoji(0x2764) and !isDefaultPresentation(0x2764)); // ❤
    try std.testing.expect(isEmoji(0xa9) and !isDefaultPresentation(0xa9)); // ©
    try std.testing.expect(isEmoji('#') and !isDefaultPresentation('#')); // a keycap base

    // Not emoji at all, so a selector after them changes nothing.
    try std.testing.expect(!isEmoji('a'));
    try std.testing.expect(!isEmoji(0xfe0f)); // the selector itself
    try std.testing.expect(!isEmoji(0x4e00));
    try std.testing.expect(!isEmoji(0x10ffff));

    // Every range is ascending, disjoint from its neighbour, and presentation
    // is a subset of emoji — all three are what \`contains\` bisects on.
    for (&[_][]const Range{ &emoji, &presentation }) |table| {
        for (table, 0..) |range, i| {
            try std.testing.expect(range.first <= range.last);
            if (i > 0) try std.testing.expect(table[i - 1].last + 1 < range.first);
        }
    }
    for (presentation) |range| {
        var codepoint = range.first;
        while (codepoint <= range.last) : (codepoint += 1) {
            try std.testing.expect(isEmoji(codepoint));
        }
    }
}
`;
}
