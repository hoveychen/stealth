// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

//! A grid container's track list: what `grid-template-columns` says, and what
//! width each of its tracks ends up with.
//!
//! Split out from CSSStyleDeclaration because it is the one piece of grid that
//! is pure text in and numbers out: the caller resolves each `<length>` against
//! the element's font and containing block, and everything else here -- the
//! `repeat()` expansion, which tracks flex, how the leftover is cut -- needs
//! nothing from the document.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One entry of a track list, before anything has been resolved to px.
///
/// The length variants keep the author's token rather than a number, because
/// resolving `2em` needs the element's computed font size and this file has no
/// element. The caller hands the resolved px back in `sizeTracks`.
pub const TrackSpec = union(enum) {
    /// A `<length-percentage>`: the token, verbatim.
    length: []const u8,
    /// A `<flex>`: the number in front of the `fr`.
    flex: f64,
    /// `auto`, `min-content`, `max-content` and anything else this engine does
    /// not model: a track with no size of its own.
    auto,
    /// `minmax(<min>, <max>)`: two tokens, each of which is one of the above.
    /// The max is what the track grows to and the min is the floor it is never
    /// squeezed under.
    minmax: struct { min: []const u8, max: []const u8 },
};

/// How many tracks one `repeat()` may expand to. A page may write
/// `repeat(1000, 1fr)`, and the tracks are materialised one per entry -- so
/// this is the bound that keeps a typo from asking for a gigabyte.
const MAX_TRACKS = 1000;

/// Parse a `grid-template-columns` / `grid-template-rows` value into its
/// tracks, with every `repeat()` expanded in place.
///
/// `none` -- the initial value -- and anything this cannot make sense of
/// answer an empty list, which is the caller's signal to fall back to the
/// single implicit track an auto-flow grid would make.
pub fn parseTrackList(arena: Allocator, value: []const u8) Allocator.Error![]TrackSpec {
    var specs: std.ArrayListUnmanaged(TrackSpec) = .empty;
    var it = TokenIterator{ .text = value };
    while (it.next()) |token| {
        if (specs.items.len >= MAX_TRACKS) break;
        // A line name -- `[main-start]` -- names the edge between two tracks
        // and is not a track itself.
        if (token.len > 0 and token[0] == '[') continue;
        if (std.ascii.eqlIgnoreCase(token, "none")) continue;
        if (callOf(token, "repeat")) |body| {
            try expandRepeat(arena, &specs, body);
            continue;
        }
        try specs.append(arena, parseTrackToken(token));
    }
    return specs.items;
}

/// One track, which is one token: a length, a flex factor, a keyword, or a
/// `minmax()` of two of those. Public so a caller can parse one bound of a
/// `minmax()` on its own.
pub fn parseTrackToken(token: []const u8) TrackSpec {
    if (callOf(token, "minmax")) |body| {
        const comma = std.mem.indexOfScalar(u8, body, ',') orelse return .auto;
        return .{ .minmax = .{
            .min = std.mem.trim(u8, body[0..comma], &std.ascii.whitespace),
            .max = std.mem.trim(u8, body[comma + 1 ..], &std.ascii.whitespace),
        } };
    }
    if (token.len > 2 and std.ascii.endsWithIgnoreCase(token, "fr")) {
        const number = std.fmt.parseFloat(f64, token[0 .. token.len - 2]) catch return .auto;
        return .{ .flex = @max(0, number) };
    }
    if (std.ascii.eqlIgnoreCase(token, "auto") or
        std.ascii.eqlIgnoreCase(token, "min-content") or
        std.ascii.eqlIgnoreCase(token, "max-content")) return .auto;
    return .{ .length = token };
}

/// `repeat(<count>, <track-list>)`, written out. An `auto-fill` / `auto-fit`
/// count needs the container's width to know how many fit, which this file
/// does not have; both take one repetition, which is what a single track's
/// worth of the list is.
fn expandRepeat(arena: Allocator, specs: *std.ArrayListUnmanaged(TrackSpec), body: []const u8) Allocator.Error!void {
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return;
    const count_text = std.mem.trim(u8, body[0..comma], &std.ascii.whitespace);
    const count: usize = std.fmt.parseUnsigned(usize, count_text, 10) catch 1;

    const inner = try parseTrackList(arena, body[comma + 1 ..]);
    if (inner.len == 0) return;

    var n: usize = 0;
    while (n < count) : (n += 1) {
        for (inner) |spec| {
            if (specs.items.len >= MAX_TRACKS) return;
            try specs.append(arena, spec);
        }
    }
}

/// The body of `name(...)`, or null when this token is not that call.
pub fn callOf(token: []const u8, name: []const u8) ?[]const u8 {
    if (token.len < name.len + 2) return null;
    if (token[token.len - 1] != ')') return null;
    if (token[name.len] != '(') return null;
    if (!std.ascii.eqlIgnoreCase(token[0..name.len], name)) return null;
    return token[name.len + 1 .. token.len - 1];
}

/// Whitespace-separated tokens, with a function call kept whole: `repeat(4,
/// 60px)` holds a space and a comma and is still one track entry.
pub const TokenIterator = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *TokenIterator) ?[]const u8 {
        while (self.at < self.text.len and std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
        if (self.at >= self.text.len) return null;
        const start = self.at;
        var depth: usize = 0;
        while (self.at < self.text.len) : (self.at += 1) {
            const c = self.text[self.at];
            if (c == '(' or c == '[') depth += 1;
            if (c == ')' or c == ']') depth -|= 1;
            if (depth == 0 and std.ascii.isWhitespace(c)) break;
        }
        return self.text[start..self.at];
    }
};

/// A track once it has a number: the px a definite one takes, and the flex
/// factor a `<flex>` one shares the leftover by.
pub const Track = struct {
    /// The px this track takes before anything is shared out. A `<flex>` track
    /// starts at zero, and an `auto` one at whatever its content needs -- which
    /// this engine has not measured, so zero there too.
    base: f64 = 0,
    /// The `fr` factor, zero for every track that is not a `<flex>`.
    flex: f64 = 0,
    /// Whether the track takes a share of the leftover when nothing flexes.
    /// `auto` does; a length does not.
    auto: bool = false,
    /// The floor a `minmax()` puts under the track: it may grow past this and
    /// is never sized below it.
    min: f64 = 0,
};

/// Where one track starts and how wide it is, both on the layout grid.
pub const Placed = struct {
    start: f64,
    size: f64,
};

/// Size the tracks and place them, given the container's content size on that
/// axis and the gap between two of them.
///
/// The leftover goes to the `<flex>` tracks in proportion to their factors, and
/// only to the `auto` ones when nothing flexes: `minmax(50px,100px) auto` in an
/// 800px container is 100 and 700 in Chrome, so an `auto` track stretches --
/// but `100px 1fr 2fr` leaves an `auto` beside them at its content size.
///
/// The edges are what is snapped, not the sizes. Chrome's own tracks come out
/// on the 1/128 grid by their POSITIONS -- `100px 1fr 2fr` with a 10px gap in
/// 800px measures 100 / 226.6640625 / 453.3359375, whose sum is exactly 680 and
/// none of which is a grid step of 680/3. Snapping each running edge and taking
/// the difference reproduces all three; snapping each size independently does
/// not, because then the last track ends 1/128 short of the container.
pub fn sizeTracks(arena: Allocator, tracks: []const Track, available: f64, gap: f64, snap: *const fn (f64) f64) Allocator.Error![]Placed {
    const out = try arena.alloc(Placed, tracks.len);
    if (tracks.len == 0) return out;

    const count: f64 = @floatFromInt(tracks.len);
    const inner = available - gap * (count - 1);

    var taken: f64 = 0;
    var total_flex: f64 = 0;
    var auto_count: f64 = 0;
    for (tracks) |track| {
        taken += track.base;
        total_flex += track.flex;
        if (track.auto) auto_count += 1;
    }
    const free = @max(0, inner - taken);

    // A running edge, unsnapped: every position is the sum of what came before
    // it, and rounding on the way would let the error accumulate.
    var edge: f64 = 0;
    for (tracks, out) |track, *placed| {
        var size = track.base;
        if (total_flex > 0) {
            if (track.flex > 0) size = free * track.flex / total_flex;
        } else if (auto_count > 0 and track.auto) {
            size = free / auto_count;
        }
        size = @max(size, track.min);
        const start = snap(edge);
        placed.* = .{ .start = start, .size = @max(0, snap(edge + size) - start) };
        edge += size + gap;
    }
    return out;
}

const testing = std.testing;

fn testSnap(px: f64) f64 {
    const narrowed: f64 = @as(f32, @floatCast(px));
    return @floor(narrowed * 128) / 128;
}

test "grid: parseTrackList splits lengths, flexes and keywords" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const specs = try parseTrackList(a, "100px 1fr 2fr");
    try testing.expectEqual(@as(usize, 3), specs.len);
    try testing.expectEqualStrings("100px", specs[0].length);
    try testing.expectEqual(@as(f64, 1), specs[1].flex);
    try testing.expectEqual(@as(f64, 2), specs[2].flex);

    const keyword = try parseTrackList(a, "auto max-content 50%");
    try testing.expectEqual(TrackSpec.auto, keyword[0]);
    try testing.expectEqual(TrackSpec.auto, keyword[1]);
    try testing.expectEqualStrings("50%", keyword[2].length);

    try testing.expectEqual(@as(usize, 0), (try parseTrackList(a, "none")).len);
}

test "grid: repeat expands in place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const specs = try parseTrackList(a, "repeat(4, 60px)");
    try testing.expectEqual(@as(usize, 4), specs.len);
    for (specs) |spec| try testing.expectEqualStrings("60px", spec.length);

    const mixed = try parseTrackList(a, "20px repeat(2, 1fr 10px) 30px");
    try testing.expectEqual(@as(usize, 6), mixed.len);
    try testing.expectEqualStrings("20px", mixed[0].length);
    try testing.expectEqual(@as(f64, 1), mixed[1].flex);
    try testing.expectEqualStrings("10px", mixed[2].length);
    try testing.expectEqualStrings("30px", mixed[5].length);
}

test "grid: the leftover lands on the flex tracks, on the grid Chrome uses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Chrome 153 at 800px content, `100px 1fr 2fr` with `gap:10px`
    // (scratch/s74/expr-geom.js, `grid.threeCols`): the three items measure
    // 100 / 226.6641 / 453.3359 wide at x = 0 / 110 / 346.6641.
    const placed = try sizeTracks(a, &.{
        .{ .base = 100 },
        .{ .flex = 1 },
        .{ .flex = 2 },
    }, 800, 10, testSnap);
    try testing.expectEqual(@as(f64, 0), placed[0].start);
    try testing.expectEqual(@as(f64, 100), placed[0].size);
    try testing.expectEqual(@as(f64, 110), placed[1].start);
    try testing.expectEqual(@as(f64, 226.6640625), placed[1].size);
    try testing.expectEqual(@as(f64, 346.6640625), placed[2].start);
    try testing.expectEqual(@as(f64, 453.3359375), placed[2].size);
}

test "grid: an auto track stretches only when nothing flexes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stretched = try sizeTracks(a, &.{
        .{ .base = 100 },
        .{ .auto = true },
    }, 800, 0, testSnap);
    try testing.expectEqual(@as(f64, 700), stretched[1].size);

    const beside_flex = try sizeTracks(a, &.{
        .{ .auto = true },
        .{ .flex = 1 },
    }, 800, 0, testSnap);
    try testing.expectEqual(@as(f64, 0), beside_flex[0].size);
    try testing.expectEqual(@as(f64, 800), beside_flex[1].size);
}

test "grid: fixed tracks keep their own size in a wider container" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placed = try sizeTracks(a, &.{
        .{ .base = 60 },
        .{ .base = 60 },
        .{ .base = 60 },
        .{ .base = 60 },
    }, 800, 0, testSnap);
    for (placed, 0..) |track, i| {
        try testing.expectEqual(@as(f64, 60), track.size);
        try testing.expectEqual(@as(f64, 60) * @as(f64, @floatFromInt(i)), track.start);
    }
}
