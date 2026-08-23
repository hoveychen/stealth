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

// GENERATED — do not hand-edit. Produced by
//   node tools/fingerprint/dump-emoji-properties.mjs --zig
//
// The two Unicode properties that say whether a character is drawn from a
// colour emoji font, and so which advance measureText reports for it.
//
//   Emoji               1438 codepoints — may be drawn as an emoji.
//   Emoji_Presentation  1219 codepoints — is, unless told otherwise.
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

/// Ascending and disjoint, so `contains` can bisect.
const emoji = [_]Range{
    .{ .first = 0x0023, .last = 0x0023 }, // #
    .{ .first = 0x002A, .last = 0x002A }, // *
    .{ .first = 0x0030, .last = 0x0039 }, // 0..9
    .{ .first = 0x00A9, .last = 0x00A9 }, // ©
    .{ .first = 0x00AE, .last = 0x00AE }, // ®
    .{ .first = 0x203C, .last = 0x203C }, // ‼
    .{ .first = 0x2049, .last = 0x2049 }, // ⁉
    .{ .first = 0x2122, .last = 0x2122 }, // ™
    .{ .first = 0x2139, .last = 0x2139 }, // ℹ
    .{ .first = 0x2194, .last = 0x2199 }, // ↔..↙
    .{ .first = 0x21A9, .last = 0x21AA }, // ↩..↪
    .{ .first = 0x231A, .last = 0x231B }, // ⌚..⌛
    .{ .first = 0x2328, .last = 0x2328 }, // ⌨
    .{ .first = 0x23CF, .last = 0x23CF }, // ⏏
    .{ .first = 0x23E9, .last = 0x23F3 }, // ⏩..⏳
    .{ .first = 0x23F8, .last = 0x23FA }, // ⏸..⏺
    .{ .first = 0x24C2, .last = 0x24C2 }, // Ⓜ
    .{ .first = 0x25AA, .last = 0x25AB }, // ▪..▫
    .{ .first = 0x25B6, .last = 0x25B6 }, // ▶
    .{ .first = 0x25C0, .last = 0x25C0 }, // ◀
    .{ .first = 0x25FB, .last = 0x25FE }, // ◻..◾
    .{ .first = 0x2600, .last = 0x2604 }, // ☀..☄
    .{ .first = 0x260E, .last = 0x260E }, // ☎
    .{ .first = 0x2611, .last = 0x2611 }, // ☑
    .{ .first = 0x2614, .last = 0x2615 }, // ☔..☕
    .{ .first = 0x2618, .last = 0x2618 }, // ☘
    .{ .first = 0x261D, .last = 0x261D }, // ☝
    .{ .first = 0x2620, .last = 0x2620 }, // ☠
    .{ .first = 0x2622, .last = 0x2623 }, // ☢..☣
    .{ .first = 0x2626, .last = 0x2626 }, // ☦
    .{ .first = 0x262A, .last = 0x262A }, // ☪
    .{ .first = 0x262E, .last = 0x262F }, // ☮..☯
    .{ .first = 0x2638, .last = 0x263A }, // ☸..☺
    .{ .first = 0x2640, .last = 0x2640 }, // ♀
    .{ .first = 0x2642, .last = 0x2642 }, // ♂
    .{ .first = 0x2648, .last = 0x2653 }, // ♈..♓
    .{ .first = 0x265F, .last = 0x2660 }, // ♟..♠
    .{ .first = 0x2663, .last = 0x2663 }, // ♣
    .{ .first = 0x2665, .last = 0x2666 }, // ♥..♦
    .{ .first = 0x2668, .last = 0x2668 }, // ♨
    .{ .first = 0x267B, .last = 0x267B }, // ♻
    .{ .first = 0x267E, .last = 0x267F }, // ♾..♿
    .{ .first = 0x2692, .last = 0x2697 }, // ⚒..⚗
    .{ .first = 0x2699, .last = 0x2699 }, // ⚙
    .{ .first = 0x269B, .last = 0x269C }, // ⚛..⚜
    .{ .first = 0x26A0, .last = 0x26A1 }, // ⚠..⚡
    .{ .first = 0x26A7, .last = 0x26A7 }, // ⚧
    .{ .first = 0x26AA, .last = 0x26AB }, // ⚪..⚫
    .{ .first = 0x26B0, .last = 0x26B1 }, // ⚰..⚱
    .{ .first = 0x26BD, .last = 0x26BE }, // ⚽..⚾
    .{ .first = 0x26C4, .last = 0x26C5 }, // ⛄..⛅
    .{ .first = 0x26C8, .last = 0x26C8 }, // ⛈
    .{ .first = 0x26CE, .last = 0x26CF }, // ⛎..⛏
    .{ .first = 0x26D1, .last = 0x26D1 }, // ⛑
    .{ .first = 0x26D3, .last = 0x26D4 }, // ⛓..⛔
    .{ .first = 0x26E9, .last = 0x26EA }, // ⛩..⛪
    .{ .first = 0x26F0, .last = 0x26F5 }, // ⛰..⛵
    .{ .first = 0x26F7, .last = 0x26FA }, // ⛷..⛺
    .{ .first = 0x26FD, .last = 0x26FD }, // ⛽
    .{ .first = 0x2702, .last = 0x2702 }, // ✂
    .{ .first = 0x2705, .last = 0x2705 }, // ✅
    .{ .first = 0x2708, .last = 0x270D }, // ✈..✍
    .{ .first = 0x270F, .last = 0x270F }, // ✏
    .{ .first = 0x2712, .last = 0x2712 }, // ✒
    .{ .first = 0x2714, .last = 0x2714 }, // ✔
    .{ .first = 0x2716, .last = 0x2716 }, // ✖
    .{ .first = 0x271D, .last = 0x271D }, // ✝
    .{ .first = 0x2721, .last = 0x2721 }, // ✡
    .{ .first = 0x2728, .last = 0x2728 }, // ✨
    .{ .first = 0x2733, .last = 0x2734 }, // ✳..✴
    .{ .first = 0x2744, .last = 0x2744 }, // ❄
    .{ .first = 0x2747, .last = 0x2747 }, // ❇
    .{ .first = 0x274C, .last = 0x274C }, // ❌
    .{ .first = 0x274E, .last = 0x274E }, // ❎
    .{ .first = 0x2753, .last = 0x2755 }, // ❓..❕
    .{ .first = 0x2757, .last = 0x2757 }, // ❗
    .{ .first = 0x2763, .last = 0x2764 }, // ❣..❤
    .{ .first = 0x2795, .last = 0x2797 }, // ➕..➗
    .{ .first = 0x27A1, .last = 0x27A1 }, // ➡
    .{ .first = 0x27B0, .last = 0x27B0 }, // ➰
    .{ .first = 0x27BF, .last = 0x27BF }, // ➿
    .{ .first = 0x2934, .last = 0x2935 }, // ⤴..⤵
    .{ .first = 0x2B05, .last = 0x2B07 }, // ⬅..⬇
    .{ .first = 0x2B1B, .last = 0x2B1C }, // ⬛..⬜
    .{ .first = 0x2B50, .last = 0x2B50 }, // ⭐
    .{ .first = 0x2B55, .last = 0x2B55 }, // ⭕
    .{ .first = 0x3030, .last = 0x3030 }, // 〰
    .{ .first = 0x303D, .last = 0x303D }, // 〽
    .{ .first = 0x3297, .last = 0x3297 }, // ㊗
    .{ .first = 0x3299, .last = 0x3299 }, // ㊙
    .{ .first = 0x1F004, .last = 0x1F004 }, // 🀄
    .{ .first = 0x1F0CF, .last = 0x1F0CF }, // 🃏
    .{ .first = 0x1F170, .last = 0x1F171 }, // 🅰..🅱
    .{ .first = 0x1F17E, .last = 0x1F17F }, // 🅾..🅿
    .{ .first = 0x1F18E, .last = 0x1F18E }, // 🆎
    .{ .first = 0x1F191, .last = 0x1F19A }, // 🆑..🆚
    .{ .first = 0x1F1E6, .last = 0x1F1FF }, // 🇦..🇿
    .{ .first = 0x1F201, .last = 0x1F202 }, // 🈁..🈂
    .{ .first = 0x1F21A, .last = 0x1F21A }, // 🈚
    .{ .first = 0x1F22F, .last = 0x1F22F }, // 🈯
    .{ .first = 0x1F232, .last = 0x1F23A }, // 🈲..🈺
    .{ .first = 0x1F250, .last = 0x1F251 }, // 🉐..🉑
    .{ .first = 0x1F300, .last = 0x1F321 }, // 🌀..🌡
    .{ .first = 0x1F324, .last = 0x1F393 }, // 🌤..🎓
    .{ .first = 0x1F396, .last = 0x1F397 }, // 🎖..🎗
    .{ .first = 0x1F399, .last = 0x1F39B }, // 🎙..🎛
    .{ .first = 0x1F39E, .last = 0x1F3F0 }, // 🎞..🏰
    .{ .first = 0x1F3F3, .last = 0x1F3F5 }, // 🏳..🏵
    .{ .first = 0x1F3F7, .last = 0x1F4FD }, // 🏷..📽
    .{ .first = 0x1F4FF, .last = 0x1F53D }, // 📿..🔽
    .{ .first = 0x1F549, .last = 0x1F54E }, // 🕉..🕎
    .{ .first = 0x1F550, .last = 0x1F567 }, // 🕐..🕧
    .{ .first = 0x1F56F, .last = 0x1F570 }, // 🕯..🕰
    .{ .first = 0x1F573, .last = 0x1F57A }, // 🕳..🕺
    .{ .first = 0x1F587, .last = 0x1F587 }, // 🖇
    .{ .first = 0x1F58A, .last = 0x1F58D }, // 🖊..🖍
    .{ .first = 0x1F590, .last = 0x1F590 }, // 🖐
    .{ .first = 0x1F595, .last = 0x1F596 }, // 🖕..🖖
    .{ .first = 0x1F5A4, .last = 0x1F5A5 }, // 🖤..🖥
    .{ .first = 0x1F5A8, .last = 0x1F5A8 }, // 🖨
    .{ .first = 0x1F5B1, .last = 0x1F5B2 }, // 🖱..🖲
    .{ .first = 0x1F5BC, .last = 0x1F5BC }, // 🖼
    .{ .first = 0x1F5C2, .last = 0x1F5C4 }, // 🗂..🗄
    .{ .first = 0x1F5D1, .last = 0x1F5D3 }, // 🗑..🗓
    .{ .first = 0x1F5DC, .last = 0x1F5DE }, // 🗜..🗞
    .{ .first = 0x1F5E1, .last = 0x1F5E1 }, // 🗡
    .{ .first = 0x1F5E3, .last = 0x1F5E3 }, // 🗣
    .{ .first = 0x1F5E8, .last = 0x1F5E8 }, // 🗨
    .{ .first = 0x1F5EF, .last = 0x1F5EF }, // 🗯
    .{ .first = 0x1F5F3, .last = 0x1F5F3 }, // 🗳
    .{ .first = 0x1F5FA, .last = 0x1F64F }, // 🗺..🙏
    .{ .first = 0x1F680, .last = 0x1F6C5 }, // 🚀..🛅
    .{ .first = 0x1F6CB, .last = 0x1F6D2 }, // 🛋..🛒
    .{ .first = 0x1F6D5, .last = 0x1F6D8 }, // 🛕..🛘
    .{ .first = 0x1F6DC, .last = 0x1F6E5 }, // 🛜..🛥
    .{ .first = 0x1F6E9, .last = 0x1F6E9 }, // 🛩
    .{ .first = 0x1F6EB, .last = 0x1F6EC }, // 🛫..🛬
    .{ .first = 0x1F6F0, .last = 0x1F6F0 }, // 🛰
    .{ .first = 0x1F6F3, .last = 0x1F6FC }, // 🛳..🛼
    .{ .first = 0x1F7E0, .last = 0x1F7EB }, // 🟠..🟫
    .{ .first = 0x1F7F0, .last = 0x1F7F0 }, // 🟰
    .{ .first = 0x1F90C, .last = 0x1F93A }, // 🤌..🤺
    .{ .first = 0x1F93C, .last = 0x1F945 }, // 🤼..🥅
    .{ .first = 0x1F947, .last = 0x1F9FF }, // 🥇..🧿
    .{ .first = 0x1FA70, .last = 0x1FA7C }, // 🩰..🩼
    .{ .first = 0x1FA80, .last = 0x1FA8A }, // 🪀..🪊
    .{ .first = 0x1FA8E, .last = 0x1FAC6 }, // 🪎..🫆
    .{ .first = 0x1FAC8, .last = 0x1FAC8 }, // 🫈
    .{ .first = 0x1FACD, .last = 0x1FADC }, // 🫍..🫜
    .{ .first = 0x1FADF, .last = 0x1FAEA }, // 🫟..🫪
    .{ .first = 0x1FAEF, .last = 0x1FAF8 }, // 🫯..🫸
};

/// Ascending and disjoint, and a subset of `emoji`.
const presentation = [_]Range{
    .{ .first = 0x231A, .last = 0x231B }, // ⌚..⌛
    .{ .first = 0x23E9, .last = 0x23EC }, // ⏩..⏬
    .{ .first = 0x23F0, .last = 0x23F0 }, // ⏰
    .{ .first = 0x23F3, .last = 0x23F3 }, // ⏳
    .{ .first = 0x25FD, .last = 0x25FE }, // ◽..◾
    .{ .first = 0x2614, .last = 0x2615 }, // ☔..☕
    .{ .first = 0x2648, .last = 0x2653 }, // ♈..♓
    .{ .first = 0x267F, .last = 0x267F }, // ♿
    .{ .first = 0x2693, .last = 0x2693 }, // ⚓
    .{ .first = 0x26A1, .last = 0x26A1 }, // ⚡
    .{ .first = 0x26AA, .last = 0x26AB }, // ⚪..⚫
    .{ .first = 0x26BD, .last = 0x26BE }, // ⚽..⚾
    .{ .first = 0x26C4, .last = 0x26C5 }, // ⛄..⛅
    .{ .first = 0x26CE, .last = 0x26CE }, // ⛎
    .{ .first = 0x26D4, .last = 0x26D4 }, // ⛔
    .{ .first = 0x26EA, .last = 0x26EA }, // ⛪
    .{ .first = 0x26F2, .last = 0x26F3 }, // ⛲..⛳
    .{ .first = 0x26F5, .last = 0x26F5 }, // ⛵
    .{ .first = 0x26FA, .last = 0x26FA }, // ⛺
    .{ .first = 0x26FD, .last = 0x26FD }, // ⛽
    .{ .first = 0x2705, .last = 0x2705 }, // ✅
    .{ .first = 0x270A, .last = 0x270B }, // ✊..✋
    .{ .first = 0x2728, .last = 0x2728 }, // ✨
    .{ .first = 0x274C, .last = 0x274C }, // ❌
    .{ .first = 0x274E, .last = 0x274E }, // ❎
    .{ .first = 0x2753, .last = 0x2755 }, // ❓..❕
    .{ .first = 0x2757, .last = 0x2757 }, // ❗
    .{ .first = 0x2795, .last = 0x2797 }, // ➕..➗
    .{ .first = 0x27B0, .last = 0x27B0 }, // ➰
    .{ .first = 0x27BF, .last = 0x27BF }, // ➿
    .{ .first = 0x2B1B, .last = 0x2B1C }, // ⬛..⬜
    .{ .first = 0x2B50, .last = 0x2B50 }, // ⭐
    .{ .first = 0x2B55, .last = 0x2B55 }, // ⭕
    .{ .first = 0x1F004, .last = 0x1F004 }, // 🀄
    .{ .first = 0x1F0CF, .last = 0x1F0CF }, // 🃏
    .{ .first = 0x1F18E, .last = 0x1F18E }, // 🆎
    .{ .first = 0x1F191, .last = 0x1F19A }, // 🆑..🆚
    .{ .first = 0x1F1E6, .last = 0x1F1FF }, // 🇦..🇿
    .{ .first = 0x1F201, .last = 0x1F201 }, // 🈁
    .{ .first = 0x1F21A, .last = 0x1F21A }, // 🈚
    .{ .first = 0x1F22F, .last = 0x1F22F }, // 🈯
    .{ .first = 0x1F232, .last = 0x1F236 }, // 🈲..🈶
    .{ .first = 0x1F238, .last = 0x1F23A }, // 🈸..🈺
    .{ .first = 0x1F250, .last = 0x1F251 }, // 🉐..🉑
    .{ .first = 0x1F300, .last = 0x1F320 }, // 🌀..🌠
    .{ .first = 0x1F32D, .last = 0x1F335 }, // 🌭..🌵
    .{ .first = 0x1F337, .last = 0x1F37C }, // 🌷..🍼
    .{ .first = 0x1F37E, .last = 0x1F393 }, // 🍾..🎓
    .{ .first = 0x1F3A0, .last = 0x1F3CA }, // 🎠..🏊
    .{ .first = 0x1F3CF, .last = 0x1F3D3 }, // 🏏..🏓
    .{ .first = 0x1F3E0, .last = 0x1F3F0 }, // 🏠..🏰
    .{ .first = 0x1F3F4, .last = 0x1F3F4 }, // 🏴
    .{ .first = 0x1F3F8, .last = 0x1F43E }, // 🏸..🐾
    .{ .first = 0x1F440, .last = 0x1F440 }, // 👀
    .{ .first = 0x1F442, .last = 0x1F4FC }, // 👂..📼
    .{ .first = 0x1F4FF, .last = 0x1F53D }, // 📿..🔽
    .{ .first = 0x1F54B, .last = 0x1F54E }, // 🕋..🕎
    .{ .first = 0x1F550, .last = 0x1F567 }, // 🕐..🕧
    .{ .first = 0x1F57A, .last = 0x1F57A }, // 🕺
    .{ .first = 0x1F595, .last = 0x1F596 }, // 🖕..🖖
    .{ .first = 0x1F5A4, .last = 0x1F5A4 }, // 🖤
    .{ .first = 0x1F5FB, .last = 0x1F64F }, // 🗻..🙏
    .{ .first = 0x1F680, .last = 0x1F6C5 }, // 🚀..🛅
    .{ .first = 0x1F6CC, .last = 0x1F6CC }, // 🛌
    .{ .first = 0x1F6D0, .last = 0x1F6D2 }, // 🛐..🛒
    .{ .first = 0x1F6D5, .last = 0x1F6D8 }, // 🛕..🛘
    .{ .first = 0x1F6DC, .last = 0x1F6DF }, // 🛜..🛟
    .{ .first = 0x1F6EB, .last = 0x1F6EC }, // 🛫..🛬
    .{ .first = 0x1F6F4, .last = 0x1F6FC }, // 🛴..🛼
    .{ .first = 0x1F7E0, .last = 0x1F7EB }, // 🟠..🟫
    .{ .first = 0x1F7F0, .last = 0x1F7F0 }, // 🟰
    .{ .first = 0x1F90C, .last = 0x1F93A }, // 🤌..🤺
    .{ .first = 0x1F93C, .last = 0x1F945 }, // 🤼..🥅
    .{ .first = 0x1F947, .last = 0x1F9FF }, // 🥇..🧿
    .{ .first = 0x1FA70, .last = 0x1FA7C }, // 🩰..🩼
    .{ .first = 0x1FA80, .last = 0x1FA8A }, // 🪀..🪊
    .{ .first = 0x1FA8E, .last = 0x1FAC6 }, // 🪎..🫆
    .{ .first = 0x1FAC8, .last = 0x1FAC8 }, // 🫈
    .{ .first = 0x1FACD, .last = 0x1FADC }, // 🫍..🫜
    .{ .first = 0x1FADF, .last = 0x1FAEA }, // 🫟..🫪
    .{ .first = 0x1FAEF, .last = 0x1FAF8 }, // 🫯..🫸
};

/// Whether `codepoint` can be drawn as an emoji at all, with or without a
/// variation selector asking for it.
pub fn isEmoji(codepoint: u21) bool {
    return contains(&emoji, codepoint);
}

/// Whether `codepoint` is drawn as a colour emoji when nothing says otherwise.
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
    // is a subset of emoji — all three are what `contains` bisects on.
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
