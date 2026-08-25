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

// A VP8L (lossless WebP) writer, for `canvas.toDataURL('image/webp')`.
//
// The third of the three types Chrome encodes, and the other half of the
// reading Kasada takes when it walks the IANA image registry -- see jpeg.zig
// for the same argument at length.
//
// Lossless where Chrome is lossy. Chrome hands the bitmap to libwebp, which
// below quality 1.0 writes a VP8 keyframe with a separate alpha plane and at
// exactly 1.0 switches to VP8L (measured: quality 1 comes back *smaller* than
// quality 0.92, which is the lossless mode winning on a flat drawing). Matching
// the lossy path would mean a VP8 intra encoder -- a bool coder, four intra
// prediction modes and its own token tree -- to produce bytes that still would
// not be libwebp's, for the same reason png.zig does not chase libpng's
// filters. What a page can read here is the type, the geometry and the pixels,
// and VP8L answers all three; it just answers the pixels exactly.
//
// So the quality argument does not reach this encoder. It has nothing to spend
// it on.
//
// The format: a RIFF container around a bitstream that is LSB-first, unlike
// every other one in this directory. No transforms and no colour cache -- just
// the five prefix codes VP8L always carries, with green, red, blue and alpha
// coded per pixel and the distance code present but never used, because
// nothing here emits a backward reference.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Literals plus the 24 length prefixes that would introduce a backward
/// reference. We emit no references, but the alphabet is still this wide.
const green_symbols = 280;
const distance_symbols = 40;

/// The longest code VP8L lets a prefix code have.
const max_code_length = 15;

/// Encodes `width` x `height` straight-alpha RGBA8 pixels. A null `pixels`
/// means the canvas was never drawn into: every pixel is transparent black.
pub fn encode(allocator: Allocator, width: u32, height: u32, pixels: ?[]const u8) ![]u8 {
    std.debug.assert(width > 0 and height > 0);
    if (pixels) |p| {
        std.debug.assert(p.len == @as(usize, width) * height * 4);
    }
    // The 14-bit fields in the VP8L header. Nothing upstream builds a canvas
    // this large -- `raster.max_bytes` caps the bitmap long before -- but the
    // format cannot say it, so refuse rather than write a wrong size.
    if (width > 1 << 14 or height > 1 << 14) {
        return error.ImageTooLarge;
    }

    const payload = try lossless(allocator, width, height, pixels);
    defer allocator.free(payload);

    // A RIFF chunk is padded to an even length.
    const padding = payload.len & 1;

    var out: Writer.Allocating = try .initCapacity(allocator, payload.len + 20);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("RIFF");
    try w.writeInt(u32, @intCast(4 + 8 + payload.len + padding), .little);
    try w.writeAll("WEBP");
    try w.writeAll("VP8L");
    try w.writeInt(u32, @intCast(payload.len), .little);
    try w.writeAll(payload);
    if (padding == 1) {
        try w.writeByte(0);
    }

    return out.toOwnedSlice();
}

/// The VP8L chunk: the signature byte, the header, then one entropy-coded
/// image with a single prefix code group.
fn lossless(allocator: Allocator, width: u32, height: u32, pixels: ?[]const u8) ![]u8 {
    var histograms: Histograms = .empty;
    histograms.count(width, height, pixels);

    const green: Code = try .build(allocator, histograms.green[0..], green_symbols);
    defer green.deinit(allocator);
    const red: Code = try .build(allocator, histograms.red[0..], 256);
    defer red.deinit(allocator);
    const blue: Code = try .build(allocator, histograms.blue[0..], 256);
    defer blue.deinit(allocator);
    const alpha: Code = try .build(allocator, histograms.alpha[0..], 256);
    defer alpha.deinit(allocator);

    // Nothing emits a distance, but the group has five codes whether or not
    // the fifth is ever read. The cheapest legal one names a single symbol,
    // which costs no bits at all to read back.
    const distance: Code = try .single(allocator, 0, distance_symbols);
    defer distance.deinit(allocator);

    var out: Writer.Allocating = try .initCapacity(allocator, 64 + @as(usize, width) * height);
    errdefer out.deinit();
    try out.writer.writeByte(0x2F); // VP8L signature

    var bits: BitWriter = .{ .out = &out.writer };
    try bits.write(width - 1, 14);
    try bits.write(height - 1, 14);
    try bits.write(@intFromBool(histograms.has_transparency), 1);
    try bits.write(0, 3); // version

    try bits.write(0, 1); // no transform
    try bits.write(0, 1); // no colour cache
    try bits.write(0, 1); // no meta prefix codes: one group for the whole image

    for ([_]*const Code{ &green, &red, &blue, &alpha, &distance }) |code| {
        try code.writeDefinition(&bits);
    }

    // Every pixel as a literal, in the order the decoder reads them back.
    const total = @as(usize, width) * height;
    for (0..total) |i| {
        const pixel: [4]u8 = if (pixels) |p| p[i * 4 ..][0..4].* else .{ 0, 0, 0, 0 };
        try green.writeSymbol(&bits, pixel[1]);
        try red.writeSymbol(&bits, pixel[0]);
        try blue.writeSymbol(&bits, pixel[2]);
        try alpha.writeSymbol(&bits, pixel[3]);
    }

    try bits.flush();
    return out.toOwnedSlice();
}

const Histograms = struct {
    green: [green_symbols]u32,
    red: [256]u32,
    blue: [256]u32,
    alpha: [256]u32,
    has_transparency: bool,

    const empty: Histograms = .{
        .green = @splat(0),
        .red = @splat(0),
        .blue = @splat(0),
        .alpha = @splat(0),
        .has_transparency = false,
    };

    fn count(self: *Histograms, width: u32, height: u32, pixels: ?[]const u8) void {
        const total = @as(usize, width) * height;
        const p = pixels orelse {
            // Transparent black, every pixel.
            self.green[0] = @intCast(total);
            self.red[0] = @intCast(total);
            self.blue[0] = @intCast(total);
            self.alpha[0] = @intCast(total);
            self.has_transparency = true;
            return;
        };
        for (0..total) |i| {
            const pixel = p[i * 4 ..][0..4];
            self.red[pixel[0]] += 1;
            self.green[pixel[1]] += 1;
            self.blue[pixel[2]] += 1;
            self.alpha[pixel[3]] += 1;
            if (pixel[3] != 255) {
                self.has_transparency = true;
            }
        }
    }
};

// -- Prefix codes ------------------------------------------------------------

/// One of the five prefix codes in a group: the length of every symbol's code,
/// and the code itself already reversed for an LSB-first stream.
const Code = struct {
    lengths: []u8,
    words: []u16,
    /// Set when the whole alphabet collapses to one symbol, which VP8L spells
    /// as a "simple" code and reads back without consuming a bit.
    only: ?u16,

    fn deinit(self: Code, allocator: Allocator) void {
        allocator.free(self.lengths);
        allocator.free(self.words);
    }

    /// A code for an alphabet where exactly one symbol ever occurs.
    fn single(allocator: Allocator, symbol: u16, alphabet: usize) !Code {
        return .{
            .lengths = try allocator.alloc(u8, alphabet),
            .words = try allocator.alloc(u16, alphabet),
            .only = symbol,
        };
    }

    fn build(allocator: Allocator, counts: []u32, alphabet: usize) !Code {
        std.debug.assert(counts.len == alphabet);

        var distinct: usize = 0;
        var last: u16 = 0;
        for (counts, 0..) |c, symbol| {
            if (c > 0) {
                distinct += 1;
                last = @intCast(symbol);
            }
        }
        // A one-symbol alphabet has no information in it; so does an empty one,
        // and naming symbol 0 is the cheapest way to say so.
        if (distinct <= 1 and last < 256) {
            return single(allocator, last, alphabet);
        }

        const lengths = try allocator.alloc(u8, alphabet);
        errdefer allocator.free(lengths);
        lengthsFor(counts, lengths, max_code_length);

        const words = try allocator.alloc(u16, alphabet);
        errdefer allocator.free(words);
        canonical(lengths, words);

        return .{ .lengths = lengths, .words = words, .only = null };
    }

    fn writeSymbol(self: *const Code, bits: *BitWriter, symbol: u16) !void {
        if (self.only != null) {
            return;
        }
        try bits.write(self.words[symbol], @intCast(self.lengths[symbol]));
    }

    /// How the decoder is told what this code is.
    fn writeDefinition(self: *const Code, bits: *BitWriter) !void {
        if (self.only) |symbol| {
            try bits.write(1, 1); // simple code
            try bits.write(0, 1); // one symbol
            // A symbol above 1 does not fit the one-bit form.
            if (symbol <= 1) {
                try bits.write(0, 1);
                try bits.write(symbol, 1);
            } else {
                try bits.write(1, 1);
                try bits.write(symbol, 8);
            }
            return;
        }
        try bits.write(0, 1); // normal code, spelled out as code lengths
        try self.writeLengths(bits);
    }

    /// The code lengths, themselves prefix-coded. The run-length symbols matter
    /// here: a 280-symbol alphabet is mostly zeroes when a canvas uses a handful
    /// of colours, and symbol 18 collapses up to 138 of them into ten bits.
    fn writeLengths(self: *const Code, bits: *BitWriter) !void {
        var runs: Runs = .{};
        packRuns(self.lengths, &runs);

        var counts: [19]u32 = @splat(0);
        for (runs.items()) |run| {
            counts[run.symbol] += 1;
        }

        var lengths: [19]u8 = undefined;
        // The lengths of the code-length code are themselves sent as three-bit
        // fields, so this one cannot go past seven.
        lengthsFor(counts[0..], lengths[0..], 7);
        var words: [19]u16 = undefined;
        canonical(lengths[0..], words[0..]);

        // Only the used tail of the order needs sending.
        var sent: usize = order.len;
        while (sent > 4 and lengths[order[sent - 1]] == 0) {
            sent -= 1;
        }
        try bits.write(@intCast(sent - 4), 4);
        for (order[0..sent]) |symbol| {
            try bits.write(lengths[symbol], 3);
        }
        try bits.write(0, 1); // no max_symbol: lengths for the whole alphabet follow

        for (runs.items()) |run| {
            try bits.write(words[run.symbol], @intCast(lengths[run.symbol]));
            try bits.write(run.extra, run.extra_bits);
        }
    }

    /// The order the code-length code's own lengths are sent in, which puts the
    /// run-length symbols first because they are the ones most likely used.
    const order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
};

/// One entry of the code-length stream: a length, or one of the three repeats.
const Run = struct {
    symbol: u8,
    extra: u32 = 0,
    extra_bits: u5 = 0,
};

/// Every entry either stands for one symbol or folds several together, so the
/// widest alphabet is also the most entries this can hold.
const Runs = struct {
    buffer: [green_symbols]Run = undefined,
    len: usize = 0,

    fn append(self: *Runs, run: Run) void {
        self.buffer[self.len] = run;
        self.len += 1;
    }

    fn items(self: *const Runs) []const Run {
        return self.buffer[0..self.len];
    }
};

fn packRuns(lengths: []const u8, out: *Runs) void {
    var at: usize = 0;
    while (at < lengths.len) {
        const length = lengths[at];
        var run: usize = 1;
        while (at + run < lengths.len and lengths[at + run] == length) {
            run += 1;
        }
        at += run;

        if (length == 0) {
            // Symbol 18 takes up to 138 zeroes and symbol 17 up to 10; a run
            // shorter than three has no repeat code and is spelled out.
            while (run >= 11) {
                const take = @min(run, 138);
                out.append(.{ .symbol = 18, .extra = @intCast(take - 11), .extra_bits = 7 });
                run -= take;
            }
            while (run >= 3) {
                const take = @min(run, 10);
                out.append(.{ .symbol = 17, .extra = @intCast(take - 3), .extra_bits = 3 });
                run -= take;
            }
            for (0..run) |_| {
                out.append(.{ .symbol = 0 });
            }
            continue;
        }

        // Symbol 16 repeats the length before it, so the first of a run is
        // always written out in full.
        out.append(.{ .symbol = length });
        run -= 1;
        while (run >= 3) {
            const take = @min(run, 6);
            out.append(.{ .symbol = 16, .extra = @intCast(take - 3), .extra_bits = 2 });
            run -= take;
        }
        for (0..run) |_| {
            out.append(.{ .symbol = length });
        }
    }
}

/// Huffman code lengths for `counts`, no longer than `limit`. When the optimal
/// tree is deeper than that, the counts are halved and it is rebuilt -- the
/// flattening libwebp itself uses, and it terminates because halving always
/// pulls the distribution towards uniform.
fn lengthsFor(counts: []u32, lengths: []u8, limit: u5) void {
    while (true) {
        huffman(counts, lengths);
        var deepest: u8 = 0;
        for (lengths) |length| {
            deepest = @max(deepest, length);
        }
        if (deepest <= limit) {
            break;
        }
        for (counts) |*c| {
            if (c.* > 1) {
                c.* = (c.* + 1) / 2;
            }
        }
    }

    // One live symbol is not a tree: its depth comes out zero, which would say
    // "no code at all". Pair it with an unused symbol so the two lengths add up
    // to a complete code the decoder can build, and never emit the second.
    var live: usize = 0;
    var only: usize = 0;
    for (lengths, 0..) |length, symbol| {
        if (length > 0) {
            live += 1;
            only = symbol;
        }
    }
    if (live == 1) {
        lengths[only] = 1;
        lengths[if (only == 0) 1 else 0] = 1;
    }
}

/// Textbook Huffman: repeatedly merge the two lightest live nodes, then read
/// each leaf's depth off the parent chain. The alphabets here top out at 280
/// symbols, so the quadratic search for the minimum is not worth replacing with
/// a heap.
fn huffman(counts: []const u32, lengths: []u8) void {
    const capacity = 2 * green_symbols;
    var weight: [capacity]u64 = undefined;
    // Node 0 is always a leaf, so it can never be anything's parent: zero
    // doubles as "no parent yet", which is what the root keeps.
    var parent: [capacity]usize = @splat(0);
    var live: [capacity]bool = @splat(false);

    var nodes = counts.len;
    for (counts, 0..) |c, i| {
        weight[i] = c;
        live[i] = c > 0;
        lengths[i] = 0;
    }

    while (true) {
        var first: ?usize = null;
        var second: ?usize = null;
        for (0..nodes) |i| {
            if (!live[i]) {
                continue;
            }
            if (first == null or weight[i] < weight[first.?]) {
                second = first;
                first = i;
            } else if (second == null or weight[i] < weight[second.?]) {
                second = i;
            }
        }
        const a = first orelse break;
        const b = second orelse break;

        weight[nodes] = weight[a] + weight[b];
        live[nodes] = true;
        live[a] = false;
        live[b] = false;
        parent[a] = nodes;
        parent[b] = nodes;
        nodes += 1;
    }

    for (counts, 0..) |c, symbol| {
        if (c == 0) {
            continue;
        }
        var depth: u8 = 0;
        var at = symbol;
        while (parent[at] != 0) : (depth += 1) {
            at = parent[at];
        }
        lengths[symbol] = depth;
    }
}

/// The canonical codes for a set of lengths, each reversed: VP8L reads its bits
/// least-significant first, so a code is written out back to front.
fn canonical(lengths: []const u8, words: []u16) void {
    var counts: [max_code_length + 2]u32 = @splat(0);
    for (lengths) |length| {
        counts[length] += 1;
    }
    counts[0] = 0;

    var next: [max_code_length + 2]u32 = @splat(0);
    var code: u32 = 0;
    for (1..max_code_length + 1) |length| {
        code = (code + counts[length - 1]) << 1;
        next[length] = code;
    }

    for (lengths, 0..) |length, symbol| {
        words[symbol] = 0;
        if (length == 0) {
            continue;
        }
        const forward: u16 = @intCast(next[length]);
        words[symbol] = @bitReverse(forward) >> @intCast(16 - length);
        next[length] += 1;
    }
}

/// Least-significant-bit-first, which is the order VP8L is read in and the
/// opposite of the JPEG scan's.
const BitWriter = struct {
    out: *Writer,
    buffer: u64 = 0,
    held: u7 = 0,

    fn write(self: *BitWriter, value: u32, count: u5) !void {
        if (count == 0) {
            return;
        }
        const wide: u64 = value;
        std.debug.assert(wide >> count == 0);
        self.buffer |= wide << @intCast(self.held);
        self.held += count;
        while (self.held >= 8) {
            try self.out.writeByte(@truncate(self.buffer));
            self.buffer >>= 8;
            self.held -= 8;
        }
    }

    fn flush(self: *BitWriter) !void {
        while (self.held > 0) {
            try self.out.writeByte(@truncate(self.buffer));
            self.buffer >>= 8;
            self.held -= @min(self.held, 8);
        }
    }
};

const testing = std.testing;
const images = @import("../webcodecs/images.zig");

test "webp: the container names VP8L and carries the geometry" {
    const allocator = testing.allocator;

    for ([_][2]u32{ .{ 1, 1 }, .{ 20, 20 }, .{ 17, 3 }, .{ 300, 150 } }) |size| {
        const pixels = try allocator.alloc(u8, @as(usize, size[0]) * size[1] * 4);
        defer allocator.free(pixels);
        for (pixels, 0..) |*byte, i| byte.* = @truncate(i * 13);

        const bytes = try encode(allocator, size[0], size[1], pixels);
        defer allocator.free(bytes);

        try testing.expectEqualSlices(u8, "RIFF", bytes[0..4]);
        try testing.expectEqualSlices(u8, "WEBP", bytes[8..12]);
        try testing.expectEqualSlices(u8, "VP8L", bytes[12..16]);
        // The RIFF size counts everything after it, and the chunk is padded to
        // an even length.
        try testing.expectEqual(bytes.len - 8, std.mem.readInt(u32, bytes[4..8], .little));

        // Read back by the same parser ImageDecoder uses.
        const image = images.read(.webp, bytes, allocator) orelse return error.Unreadable;
        try testing.expectEqual(size[0], image.width);
        try testing.expectEqual(size[1], image.height);
    }
}

test "webp: a flat image collapses to simple codes" {
    const allocator = testing.allocator;

    // Every pixel identical: each of the four channel codes names one symbol
    // and costs nothing per pixel, so the whole 64x64 fits in a few dozen bytes.
    const flat = [_]u8{ 66, 133, 244, 255 } ** (64 * 64);
    const bytes = try encode(allocator, 64, 64, &flat);
    defer allocator.free(bytes);
    try testing.expect(bytes.len < 64);

    // An undrawn canvas is the same image as one spelled out as transparent
    // black, and takes the same bytes.
    const blank = try encode(allocator, 64, 64, null);
    defer allocator.free(blank);
    const explicit = [_]u8{0} ** (64 * 64 * 4);
    const same = try encode(allocator, 64, 64, &explicit);
    defer allocator.free(same);
    try testing.expectEqualSlices(u8, blank, same);
}

test "webp: the prefix codes survive a noisy image" {
    const allocator = testing.allocator;

    // Noise puts every symbol in every alphabet to work, which is what makes
    // the depth limit and the code-length runs earn their keep.
    var pixels: [64 * 64 * 4]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0xC0FFEE);
    random.random().bytes(&pixels);

    const bytes = try encode(allocator, 64, 64, &pixels);
    defer allocator.free(bytes);

    const image = images.read(.webp, bytes, allocator) orelse return error.Unreadable;
    try testing.expectEqual(@as(u32, 64), image.width);
    try testing.expectEqual(@as(u32, 64), image.height);

    // Four random bytes a pixel cannot be compressed, so this is the floor a
    // correct encoder lands just above -- and a cap that catches a code that
    // has quietly grown to its 15-bit limit for every symbol.
    try testing.expect(bytes.len > 64 * 64 * 4 * 7 / 8);
    try testing.expect(bytes.len < 64 * 64 * 4 * 5 / 4);
}

/// No code may be a prefix of another. The words are bit-reversed for the
/// LSB-first stream, so the part two codes share is the *low* end.
fn expectPrefixFree(lengths: []const u8, words: []const u16) !void {
    for (lengths, 0..) |a_length, a| {
        if (a_length == 0) continue;
        for (lengths, 0..) |b_length, b| {
            if (b_length == 0 or a == b) continue;
            const shared: u5 = @intCast(@min(a_length, b_length));
            const mask = (@as(u32, 1) << shared) - 1;
            try testing.expect(words[a] & mask != words[b] & mask);
        }
    }
}

test "webp: canonical codes are prefix-free once reversed" {
    // A complete set of lengths -- one half, two eighths, four sixteenths.
    const lengths = [_]u8{ 1, 3, 3, 4, 4, 4, 4, 0 };
    var words: [lengths.len]u16 = undefined;
    canonical(lengths[0..], words[0..]);
    try expectPrefixFree(lengths[0..], words[0..]);

    // And the same for a set the builder produced itself, which is the one
    // that actually reaches the stream.
    var counts: [64]u32 = undefined;
    for (&counts, 0..) |*c, i| c.* = @intCast((i * i) % 97);
    var built: [64]u8 = undefined;
    lengthsFor(counts[0..], built[0..], max_code_length);
    var built_words: [64]u16 = undefined;
    canonical(built[0..], built_words[0..]);
    try expectPrefixFree(built[0..], built_words[0..]);
}

test "webp: the depth limit flattens a skewed alphabet" {
    // Fibonacci counts are the worst case: the optimal tree is a comb, one
    // level deeper per symbol, so this asks for codes far past 15 bits.
    var counts: [40]u32 = undefined;
    counts[0] = 1;
    counts[1] = 1;
    for (2..counts.len) |i| {
        counts[i] = counts[i - 1] + counts[i - 2];
    }

    var lengths: [40]u8 = undefined;
    lengthsFor(counts[0..], lengths[0..], max_code_length);

    var deepest: u8 = 0;
    for (lengths) |length| {
        deepest = @max(deepest, length);
        // Every symbol occurs, so every symbol needs a code.
        try testing.expect(length > 0);
    }
    try testing.expect(deepest <= max_code_length);

    // Still a complete code: the Kraft sum over the lengths is exactly one.
    var kraft: f64 = 0;
    for (lengths) |length| {
        kraft += std.math.ldexp(@as(f64, 1), -@as(i32, length));
    }
    try testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-9);
}
