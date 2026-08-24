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
//   node tools/fingerprint/dump-emoji.mjs --headed --zig
//
// What headed Chrome on macOS advances for the emoji a fingerprinting script
// measures. The set is CreepJS's own list, because that is the one an engine
// is actually asked about: it lays all of them out as SVG <text> at 200px and
// keys its report on how many *distinct* widths come back. Chrome answers
// 39 distinct widths across these 91 clusters; a rule of thumb like
// "an emoji is one em wide" answers 1, which is the tell.
//
// Each entry is one shaped cluster — a ZWJ sequence is a single glyph with a
// single advance, not the sum of its parts — measured at 100px. Scaling that
// to another size is off by at most 0.0078125 px at 200px, because
// Chrome quantises the advance per size; we do not model that.
//
// Measured under `font-family: sans-serif`. A colour-emoji glyph is
// family-independent — it always comes from Apple Color Emoji — but a BMP
// dingbat that some text font also carries is not: Chrome makes ☺ 147.3671875
// under sans-serif and under CreepJS's own family list, and 204.203125 under
// serif. We keep one table, so serif text is charged the sans-serif width for
// those few characters.

/// One shaped cluster and its advance at the 100px basis. `units` is the
/// cluster's length in UTF-16 code units, which is how the DOM counts
/// characters.
pub const Cluster = struct {
    text: []const u8,
    units: u32,
    advance: f64,
};

pub const basis = 100.0;

/// Ordered longest-cluster-first so `match` can return the first hit.
pub const clusters = [_]Cluster{
    .{ .text = "\u{1f469}\u{200d}\u{2764}\u{fe0f}\u{200d}\u{1f48b}\u{200d}\u{1f468}", .units = 11, .advance = 100 }, // 👩‍❤️‍💋‍👨
    .{ .text = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", .units = 11, .advance = 100 }, // 👨‍👩‍👧‍👦
    .{ .text = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f466}", .units = 8, .advance = 100 }, // 👨‍👩‍👦
    .{ .text = "\u{1f9d1}\u{200d}\u{1f91d}\u{200d}\u{1f9d1}", .units = 8, .advance = 100 }, // 🧑‍🤝‍🧑
    .{ .text = "\u{1f441}\u{fe0f}\u{200d}\u{1f5e8}\u{fe0f}", .units = 7, .advance = 100 }, // 👁️‍🗨️
    .{ .text = "\u{1f3f3}\u{fe0f}\u{200d}\u{26a7}\u{fe0f}", .units = 6, .advance = 100 }, // 🏳️‍⚧️
    .{ .text = "\u{1f935}\u{200d}\u{2642}\u{fe0f}", .units = 5, .advance = 100 }, // 🤵‍♂️
    .{ .text = "\u{1f9cf}\u{200d}\u{2642}\u{fe0f}", .units = 5, .advance = 100 }, // 🧏‍♂️
    .{ .text = "\u{1f9d1}\u{200d}\u{1f9b0}", .units = 5, .advance = 100 }, // 🧑‍🦰
    .{ .text = "\u{1f170}", .units = 2, .advance = 100 }, // 🅰
    .{ .text = "\u{1f17f}", .units = 2, .advance = 100 }, // 🅿
    .{ .text = "\u{1f600}", .units = 2, .advance = 100 }, // 😀
    .{ .text = "\u{1f972}", .units = 2, .advance = 100 }, // 🥲
    .{ .text = "\u{2049}", .units = 1, .advance = 83.3984375 }, // ⁉
    .{ .text = "\u{2122}", .units = 1, .advance = 100 }, // ™
    .{ .text = "\u{2139}", .units = 1, .advance = 66.015625 }, // ℹ
    .{ .text = "\u{2197}", .units = 1, .advance = 100 }, // ↗
    .{ .text = "\u{21aa}", .units = 1, .advance = 98.78125 }, // ↪
    .{ .text = "\u{2328}", .units = 1, .advance = 60.2109375 }, // ⌨
    .{ .text = "\u{23cf}", .units = 1, .advance = 85.6953125 }, // ⏏
    .{ .text = "\u{23ed}", .units = 1, .advance = 100.3046875 }, // ⏭
    .{ .text = "\u{23ef}", .units = 1, .advance = 87.1015625 }, // ⏯
    .{ .text = "\u{23f1}", .units = 1, .advance = 78.1015625 }, // ⏱
    .{ .text = "\u{25aa}", .units = 1, .advance = 50.5859375 }, // ▪
    .{ .text = "\u{25b6}", .units = 1, .advance = 87.9921875 }, // ▶
    .{ .text = "\u{25fc}", .units = 1, .advance = 100 }, // ◼
    .{ .text = "\u{2602}", .units = 1, .advance = 100 }, // ☂
    .{ .text = "\u{2603}", .units = 1, .advance = 100 }, // ☃
    .{ .text = "\u{2604}", .units = 1, .advance = 60.2109375 }, // ☄
    .{ .text = "\u{2611}", .units = 1, .advance = 83.0078125 }, // ☑
    .{ .text = "\u{2618}", .units = 1, .advance = 60.2109375 }, // ☘
    .{ .text = "\u{261d}", .units = 1, .advance = 100 }, // ☝
    .{ .text = "\u{2620}", .units = 1, .advance = 60.2109375 }, // ☠
    .{ .text = "\u{2622}", .units = 1, .advance = 60.2109375 }, // ☢
    .{ .text = "\u{2623}", .units = 1, .advance = 60.2109375 }, // ☣
    .{ .text = "\u{2626}", .units = 1, .advance = 60.2109375 }, // ☦
    .{ .text = "\u{262a}", .units = 1, .advance = 60.2109375 }, // ☪
    .{ .text = "\u{262e}", .units = 1, .advance = 60.2109375 }, // ☮
    .{ .text = "\u{262f}", .units = 1, .advance = 86.5 }, // ☯
    .{ .text = "\u{2638}", .units = 1, .advance = 60.2109375 }, // ☸
    .{ .text = "\u{2639}", .units = 1, .advance = 73.6875 }, // ☹
    .{ .text = "\u{263a}", .units = 1, .advance = 73.6875 }, // ☺
    .{ .text = "\u{2640}", .units = 1, .advance = 100 }, // ♀
    .{ .text = "\u{2642}", .units = 1, .advance = 100 }, // ♂
    .{ .text = "\u{265f}", .units = 1, .advance = 60.2109375 }, // ♟
    .{ .text = "\u{2668}", .units = 1, .advance = 100 }, // ♨
    .{ .text = "\u{2692}", .units = 1, .advance = 60.2109375 }, // ⚒
    .{ .text = "\u{2694}", .units = 1, .advance = 60.2109375 }, // ⚔
    .{ .text = "\u{2695}", .units = 1, .advance = 60.2109375 }, // ⚕
    .{ .text = "\u{2696}", .units = 1, .advance = 60.2109375 }, // ⚖
    .{ .text = "\u{2697}", .units = 1, .advance = 60.2109375 }, // ⚗
    .{ .text = "\u{2699}", .units = 1, .advance = 60.2109375 }, // ⚙
    .{ .text = "\u{269b}", .units = 1, .advance = 60.2109375 }, // ⚛
    .{ .text = "\u{269c}", .units = 1, .advance = 60.2109375 }, // ⚜
    .{ .text = "\u{26a0}", .units = 1, .advance = 100 }, // ⚠
    .{ .text = "\u{26a7}", .units = 1, .advance = 92.3359375 }, // ⚧
    .{ .text = "\u{26b0}", .units = 1, .advance = 60.2109375 }, // ⚰
    .{ .text = "\u{26b1}", .units = 1, .advance = 60.2109375 }, // ⚱
    .{ .text = "\u{26c8}", .units = 1, .advance = 78.8046875 }, // ⛈
    .{ .text = "\u{26cf}", .units = 1, .advance = 75.3046875 }, // ⛏
    .{ .text = "\u{26d1}", .units = 1, .advance = 80.3046875 }, // ⛑
    .{ .text = "\u{26d3}", .units = 1, .advance = 74.6015625 }, // ⛓
    .{ .text = "\u{26e9}", .units = 1, .advance = 83.703125 }, // ⛩
    .{ .text = "\u{26f0}", .units = 1, .advance = 92.703125 }, // ⛰
    .{ .text = "\u{26f1}", .units = 1, .advance = 89.90625 }, // ⛱
    .{ .text = "\u{26f4}", .units = 1, .advance = 111.5 }, // ⛴
    .{ .text = "\u{26f7}", .units = 1, .advance = 77.8046875 }, // ⛷
    .{ .text = "\u{26f8}", .units = 1, .advance = 72.90625 }, // ⛸
    .{ .text = "\u{2702}", .units = 1, .advance = 96.09375 }, // ✂
    .{ .text = "\u{2708}", .units = 1, .advance = 60.2109375 }, // ✈
    .{ .text = "\u{2709}", .units = 1, .advance = 60.2109375 }, // ✉
    .{ .text = "\u{270c}", .units = 1, .advance = 100 }, // ✌
    .{ .text = "\u{270d}", .units = 1, .advance = 100 }, // ✍
    .{ .text = "\u{270f}", .units = 1, .advance = 93.3125 }, // ✏
    .{ .text = "\u{2712}", .units = 1, .advance = 97.4140625 }, // ✒
    .{ .text = "\u{2714}", .units = 1, .advance = 84.625 }, // ✔
    .{ .text = "\u{2716}", .units = 1, .advance = 76.125 }, // ✖
    .{ .text = "\u{271d}", .units = 1, .advance = 49.4140625 }, // ✝
    .{ .text = "\u{2721}", .units = 1, .advance = 69.1953125 }, // ✡
    .{ .text = "\u{2733}", .units = 1, .advance = 74.90625 }, // ✳
    .{ .text = "\u{2734}", .units = 1, .advance = 79.0078125 }, // ✴
    .{ .text = "\u{2744}", .units = 1, .advance = 68.703125 }, // ❄
    .{ .text = "\u{2747}", .units = 1, .advance = 78.6171875 }, // ❇
    .{ .text = "\u{2763}", .units = 1, .advance = 54.3984375 }, // ❣
    .{ .text = "\u{2764}", .units = 1, .advance = 91.015625 }, // ❤
    .{ .text = "\u{27a1}", .units = 1, .advance = 82.8125 }, // ➡
    .{ .text = "\u{2b05}", .units = 1, .advance = 100 }, // ⬅
    .{ .text = "\u{2b06}", .units = 1, .advance = 100 }, // ⬆
    .{ .text = "\u{3030}", .units = 1, .advance = 100 }, // 〰
    .{ .text = "\u{a9}", .units = 1, .advance = 73.6875 }, // ©
    .{ .text = "\u{ae}", .units = 1, .advance = 73.6875 }, // ®
};

/// The measured cluster `text` starts with, or null when we have no
/// measurement for it.
///
/// Callers ask this at every character position of every string they measure,
/// so the answer for the overwhelming majority of them -- runs of ordinary
/// text, which no cluster above begins with -- has to cost one array read
/// rather than a walk of the whole table. Charging plain text 91 prefix
/// comparisons per character is what made `document.elementFromPoint` take
/// 50ms a call on a retail page, and a page that calls it in an
/// IntersectionObserver handler never came back.
pub fn match(text: []const u8) ?Cluster {
    if (text.len == 0 or !starts_a_cluster[text[0]]) {
        return null;
    }
    for (clusters) |cluster| {
        if (std.mem.startsWith(u8, text, cluster.text)) {
            return cluster;
        }
    }
    return null;
}

/// Which lead bytes any cluster above starts with. Derived from the table so
/// it cannot drift out of step with it.
const starts_a_cluster = blk: {
    var table = [_]bool{false} ** 256;
    for (clusters) |cluster| {
        table[cluster.text[0]] = true;
    }
    break :blk table;
};

const std = @import("std");
