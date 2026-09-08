//! Metrics read out of a downloaded font file.
//!
//! `@font-face` files are fetched (frame/style_resources.zig) and were then
//! thrown away, so text in a webfont measured as the fallback: a page asking
//! for `font-family: ProbeFont, sans-serif` read 129.53 here against Chrome's
//! 163.23, which is one expression apart from admitting the font never loaded.
//!
//! Only two things are taken from the file, because only two of them are
//! Chrome's numbers rather than an approximation of them. Both were checked
//! against a family `font_metrics.zig` already carries a Chrome-measured table
//! for -- Arial, which the host also ships as a file:
//!
//!   * **Advances are exact.** `hmtx.advanceWidth / head.unitsPerEm * size`
//!     matched `glyphs_arial[].advance` on 190 of 191 codepoints in
//!     U+0020..U+00FF with a delta of zero. The one miss is U+00AD, where the
//!     table says 0 and the font says 33.30 -- Chrome's soft-hyphen layout
//!     rule, not a font metric, so it is special-cased below. Chrome applies
//!     no hinting and no per-size quantisation to an advance; the 120-size
//!     sweep in font_metrics.zig is not there for advances.
//!
//!   * **Canvas ascent and descent are exact**, as
//!     `round(OS/2.usWinAscent / unitsPerEm * size)` and the same for
//!     `usWinDescent`: 117 of 120 sizes, the three misses being sizes 1 to 3
//!     where the measured table keeps the value unrounded.
//!
//! What is NOT derivable, and is approximated here on purpose:
//!
//!   * `layout_ascents` / `layout_descents` / `svg_ascents` / `svg_descents`.
//!     font_metrics.zig says these are measured off an SVG `<text>` and are
//!     not derivable from the canvas pair, and it is right: the best candidate
//!     rule, `halfPixel((usWinAscent + lineGap/2) / upem * size)`, scores 59 of
//!     117, and summing to the line box first does no better. They are taken
//!     as the fallback family's ratio against its own canvas pair.
//!   * Per-glyph ink bearings (`left`, `right`, per-glyph ascent/descent).
//!     Those need `glyf` or `CFF` outlines, which WOFF2 stores *transformed*,
//!     and they only feed canvas `actualBoundingBox*` -- not the width this
//!     defect was found through. Scaled off the fallback glyph by the advance
//!     ratio, so the ink at least stays proportional to the glyph.
//!   * `max_char_width`. Arial declares 90.5 where the measured advances top
//!     out at 101.51 and `hhea.advanceWidthMax` is 200, so Chrome's rule for it
//!     was not derived; the widest ASCII advance is used instead. It feeds only
//!     form-control intrinsic widths (Element.zig), so a webfont-styled
//!     `<input>` stays approximate. `avg_char_width` IS exact: Arial's declared
//!     50.0 is the advance of `x` to the digit, which is how Blink picks it.
//!
//! Nothing here rasterises. `glyf`/`loca` are never looked at, which is why
//! WOFF2 costs so little: its only expensive part is the glyph-outline reverse
//! transform, and skipping outlines skips that entirely. The container formats
//! need Brotli (already linked, see sys/libbrotli.zig) and zlib (already used
//! by webapi/canvas/png.zig).
//!
//! Every failure path returns null rather than an error: a font we cannot read
//! has to leave the fallback in place, exactly as before this file existed.

const std = @import("std");
const lp = @import("lightpanda");

const font_metrics = @import("font_metrics.zig");
const brotli = @import("../sys/libbrotli.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const first = font_metrics.first_codepoint;
const last = font_metrics.last_codepoint;
const glyph_count = last - first + 1;

/// A cap on what we will decompress out of one font. Real webfonts are tens to
/// hundreds of kilobytes; anything claiming more than this is not worth the
/// allocation, and refusing it keeps a hostile `totalSfntSize` from asking for
/// a gigabyte.
const MAX_DECOMPRESSED: usize = 16 * 1024 * 1024;

/// The five tables we read, sliced out of whatever container carried them.
const Tables = struct {
    head: []const u8 = &.{},
    hhea: []const u8 = &.{},
    os2: []const u8 = &.{},
    hmtx: []const u8 = &.{},
    cmap: []const u8 = &.{},
    /// hmtx carried WOFF2 transform 1, which drops the left-side-bearing
    /// arrays and prefixes the advances with a flags byte.
    hmtx_transformed: bool = false,

    fn complete(self: Tables) bool {
        return self.head.len >= 54 and self.hhea.len >= 36 and
            self.os2.len >= 78 and self.hmtx.len >= 4 and self.cmap.len >= 4;
    }
};

fn u16At(b: []const u8, off: usize) ?u16 {
    if (off + 2 > b.len) return null;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn i16At(b: []const u8, off: usize) ?i16 {
    if (off + 2 > b.len) return null;
    return std.mem.readInt(i16, b[off..][0..2], .big);
}

fn u32At(b: []const u8, off: usize) ?u32 {
    if (off + 4 > b.len) return null;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

/// Build a `font_metrics.Family` for a downloaded font, or null if the bytes
/// are not a font we can read. `fallback` supplies everything the file cannot;
/// see the header comment for which fields those are.
///
/// Everything returned is allocated from `allocator` and lives as long as it.
pub fn family(allocator: Allocator, bytes: []const u8, fallback: font_metrics.Family) ?font_metrics.Family {
    var arena_tables = std.heap.ArenaAllocator.init(allocator);
    defer arena_tables.deinit();
    const tables = read(arena_tables.allocator(), bytes) orelse return null;
    if (!tables.complete()) {
        log.debug(.browser, "webfont tables incomplete", .{ .bytes = bytes.len });
        return null;
    }
    return build(allocator, tables, fallback) catch null;
}

// --- containers ----------------------------------------------------------

fn read(allocator: Allocator, bytes: []const u8) ?Tables {
    if (bytes.len < 12) return null;
    const tag = bytes[0..4];
    if (std.mem.eql(u8, tag, "wOF2")) return woff2(allocator, bytes);
    if (std.mem.eql(u8, tag, "wOFF")) return woff(allocator, bytes);
    // A bare sfnt: 0x00010000 for TrueType outlines, `OTTO` for CFF, `true`
    // for the old Apple flavour. A `ttcf` collection points at sfnt headers,
    // so take its first font.
    if (std.mem.eql(u8, tag, "ttcf")) {
        const off = u32At(bytes, 12) orelse return null;
        if (off >= bytes.len) return null;
        return sfnt(bytes, off);
    }
    return sfnt(bytes, 0);
}

/// Walk an sfnt table directory whose header starts at `base`. Offsets inside
/// the directory are from the start of the file, not from `base`.
fn sfnt(bytes: []const u8, base: usize) ?Tables {
    const num = u16At(bytes, base + 4) orelse return null;
    var out: Tables = .{};
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const rec = base + 12 + i * 16;
        if (rec + 16 > bytes.len) return null;
        const name = bytes[rec..][0..4];
        const off = u32At(bytes, rec + 8) orelse return null;
        const len = u32At(bytes, rec + 12) orelse return null;
        if (@as(usize, off) + len > bytes.len) continue;
        const slice = bytes[off..][0..len];
        assign(&out, name, slice);
    }
    return out;
}

fn assign(out: *Tables, name: []const u8, slice: []const u8) void {
    if (std.mem.eql(u8, name, "head")) out.head = slice;
    if (std.mem.eql(u8, name, "hhea")) out.hhea = slice;
    if (std.mem.eql(u8, name, "OS/2")) out.os2 = slice;
    if (std.mem.eql(u8, name, "hmtx")) out.hmtx = slice;
    if (std.mem.eql(u8, name, "cmap")) out.cmap = slice;
}

/// WOFF: an sfnt-shaped directory whose tables are individually zlib'd. Only
/// the five we want are inflated.
fn woff(allocator: Allocator, bytes: []const u8) ?Tables {
    const num = u16At(bytes, 12) orelse return null;
    var out: Tables = .{};
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const rec = 44 + i * 20;
        if (rec + 20 > bytes.len) return null;
        const name = bytes[rec..][0..4];
        const off = u32At(bytes, rec + 4) orelse return null;
        const comp_len = u32At(bytes, rec + 8) orelse return null;
        const orig_len = u32At(bytes, rec + 12) orelse return null;
        if (@as(usize, off) + comp_len > bytes.len) continue;
        if (orig_len > MAX_DECOMPRESSED) continue;
        const raw = bytes[off..][0..comp_len];
        // Equal lengths mean the table was stored, not compressed.
        const slice = if (comp_len == orig_len) raw else inflate(allocator, raw, orig_len) orelse continue;
        assign(&out, name, slice);
    }
    return out;
}

fn inflate(allocator: Allocator, raw: []const u8, orig_len: u32) ?[]const u8 {
    var in: std.Io.Reader = .fixed(raw);
    const out = allocator.alloc(u8, orig_len) catch return null;
    var writer: std.Io.Writer = .fixed(out);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &buf);
    _ = d.reader.streamRemaining(&writer) catch return null;
    if (writer.end != orig_len) return null;
    return out;
}

/// The 63 tags a WOFF2 table directory can name by index, in the order the
/// spec fixes. Index 63 means an explicit 4-byte tag follows the flags.
const woff2_known = [_][]const u8{
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post",
    "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
    "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar",
    "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop",
    "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
};

/// UIntBase128: up to five bytes, seven bits each, high bit continues. A
/// leading 0x80 and any value that would not fit 32 bits are malformed.
fn uintBase128(bytes: []const u8, pos: *usize) ?u32 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (pos.* >= bytes.len) return null;
        const b = bytes[pos.*];
        pos.* += 1;
        if (i == 0 and b == 0x80) return null;
        if (acc > (std.math.maxInt(u32) >> 7)) return null;
        acc = (acc << 7) | (b & 0x7f);
        if (b & 0x80 == 0) return acc;
    }
    return null;
}

fn woff2(allocator: Allocator, bytes: []const u8) ?Tables {
    if (bytes.len < 48) return null;
    const num = u16At(bytes, 12) orelse return null;
    const compressed_len = u32At(bytes, 20) orelse return null;

    // First pass: the directory, which is variable-length, so the table order
    // and each table's length in the decompressed block have to be walked
    // before anything can be sliced out of it.
    const Entry = struct { tag: [4]u8, len: u32 };
    var entries = std.ArrayListUnmanaged(Entry).empty;
    var hmtx_transformed = false;
    var pos: usize = 48;
    var total: usize = 0;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        if (pos >= bytes.len) return null;
        const flags = bytes[pos];
        pos += 1;
        const index = flags & 0x3f;
        const transform = (flags >> 6) & 0x03;
        var tag: [4]u8 = undefined;
        if (index == 63) {
            if (pos + 4 > bytes.len) return null;
            @memcpy(&tag, bytes[pos..][0..4]);
            pos += 4;
        } else {
            if (index >= woff2_known.len) return null;
            @memcpy(&tag, woff2_known[index][0..4]);
        }
        const orig_len = uintBase128(bytes, &pos) orelse return null;
        // A non-zero transform version means the block carries a transformed
        // table, whose length is given separately. We never need `glyf` or
        // `loca`, so their transform is simply skipped over.
        var stored = orig_len;
        if (transform != 0) {
            stored = uintBase128(bytes, &pos) orelse return null;
            if (std.mem.eql(u8, &tag, "hmtx")) hmtx_transformed = true;
        }
        total = std.math.add(usize, total, stored) catch return null;
        if (total > MAX_DECOMPRESSED) return null;
        entries.append(allocator, .{ .tag = tag, .len = stored }) catch return null;
    }
    if (pos + compressed_len > bytes.len) return null;

    const out = allocator.alloc(u8, total) catch return null;
    var written: usize = total;
    const rc = brotli.BrotliDecoderDecompress(
        compressed_len,
        bytes[pos..].ptr,
        &written,
        out.ptr,
    );
    if (rc != brotli.BROTLI_DECODER_RESULT_SUCCESS) {
        log.debug(.browser, "woff2 brotli", .{ .rc = rc, .expected = total });
        return null;
    }

    var tables: Tables = .{ .hmtx_transformed = hmtx_transformed };
    var at: usize = 0;
    for (entries.items) |e| {
        if (at + e.len > written) break;
        assign(&tables, &e.tag, out[at..][0..e.len]);
        at += e.len;
    }
    return tables;
}

// --- metrics -------------------------------------------------------------

/// `cmap` lookup, formats 4 and 12 -- the two a webfont actually ships. Format
/// 4 covers the BMP and is what every Latin webfont uses; 12 turns up on fonts
/// with astral coverage and is cheap to add while we are here.
fn glyphId(cmap: []const u8, cp: u21) ?u16 {
    const num = u16At(cmap, 2) orelse return null;
    var chosen: ?usize = null;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const rec = 4 + i * 8;
        const platform = u16At(cmap, rec) orelse return null;
        const encoding = u16At(cmap, rec + 2) orelse return null;
        const off = u32At(cmap, rec + 4) orelse return null;
        if (off >= cmap.len) continue;
        const unicode = (platform == 3 and (encoding == 1 or encoding == 10)) or platform == 0;
        if (!unicode) continue;
        const fmt = u16At(cmap, off) orelse continue;
        if (fmt == 4 or fmt == 12) {
            // Prefer a format 12 table when both are present: it is the
            // superset, and a font shipping both means the 4 is the fallback.
            if (chosen == null or fmt == 12) chosen = off;
        }
    }
    const off = chosen orelse return null;
    return switch (u16At(cmap, off) orelse return null) {
        4 => segmentMapped(cmap, off, cp),
        12 => segmentedCoverage(cmap, off, cp),
        else => null,
    };
}

fn segmentMapped(cmap: []const u8, off: usize, cp: u21) ?u16 {
    if (cp > 0xffff) return null;
    const seg_x2 = u16At(cmap, off + 6) orelse return null;
    const segs = seg_x2 / 2;
    const ends = off + 14;
    const starts = ends + seg_x2 + 2;
    const deltas = starts + seg_x2;
    const ranges = deltas + seg_x2;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const end = u16At(cmap, ends + i * 2) orelse return null;
        if (cp > end) continue;
        const start = u16At(cmap, starts + i * 2) orelse return null;
        if (cp < start) return null;
        const delta = i16At(cmap, deltas + i * 2) orelse return null;
        const range = u16At(cmap, ranges + i * 2) orelse return null;
        if (range == 0) {
            return @truncate(@as(u32, @intCast(@as(i32, @intCast(cp)) +% delta)) & 0xffff);
        }
        const at = ranges + i * 2 + range + (cp - start) * 2;
        const gid = u16At(cmap, at) orelse return null;
        if (gid == 0) return null;
        return @truncate(@as(u32, @intCast(@as(i32, gid) +% delta)) & 0xffff);
    }
    return null;
}

fn segmentedCoverage(cmap: []const u8, off: usize, cp: u21) ?u16 {
    const groups = u32At(cmap, off + 12) orelse return null;
    var i: usize = 0;
    while (i < groups) : (i += 1) {
        const rec = off + 16 + i * 12;
        const start = u32At(cmap, rec) orelse return null;
        const end = u32At(cmap, rec + 4) orelse return null;
        const gid = u32At(cmap, rec + 8) orelse return null;
        if (cp >= start and cp <= end) {
            const g = gid + (cp - start);
            if (g > std.math.maxInt(u16)) return null;
            return @intCast(g);
        }
    }
    return null;
}

/// Advance in font units. `numberOfHMetrics` entries carry one, and every
/// glyph past that repeats the last -- which is how a monospace tail is
/// stored. A WOFF2 transform-1 hmtx drops the left-side-bearing arrays and
/// puts a flags byte in front, so the advances start one byte later.
fn advanceUnits(t: Tables, num_h_metrics: u16, gid: u16) ?u16 {
    if (num_h_metrics == 0) return null;
    const base: usize = if (t.hmtx_transformed) 1 else 0;
    const stride: usize = if (t.hmtx_transformed) 2 else 4;
    const index = @min(gid, num_h_metrics - 1);
    return u16At(t.hmtx, base + @as(usize, index) * stride);
}

fn build(allocator: Allocator, t: Tables, fallback: font_metrics.Family) !font_metrics.Family {
    const upem = u16At(t.head, 18) orelse return error.NoUnitsPerEm;
    if (upem == 0) return error.NoUnitsPerEm;
    const num_h_metrics = u16At(t.hhea, 34) orelse return error.NoHMetrics;
    const win_ascent = u16At(t.os2, 74) orelse return error.NoWinAscent;
    const win_descent = u16At(t.os2, 76) orelse return error.NoWinDescent;
    const per_unit = font_metrics.basis / @as(f64, @floatFromInt(upem));

    const glyphs = try allocator.alloc(font_metrics.Glyph, glyph_count);
    var max_advance: f64 = 0;
    var x_advance: ?f64 = null;
    var any = false;
    for (glyphs, 0..) |*g, i| {
        const cp: u21 = @intCast(first + i);
        const base = fallback.glyphs[i];
        // U+00AD is zero-advance in Chrome however wide the font draws it --
        // measured against glyphs_arial, which says 0 where Arial says 33.30.
        const units: ?u16 = if (cp == 0x00ad) 0 else blk: {
            const gid = glyphId(t.cmap, cp) orelse break :blk null;
            break :blk advanceUnits(t, num_h_metrics, gid);
        };
        if (units == null) {
            // No glyph in this face: leave the fallback's cost, which is what
            // a real fallback chain would charge for it anyway.
            g.* = base;
            continue;
        }
        any = true;
        const advance = @as(f64, @floatFromInt(units.?)) * per_unit;
        if (advance > max_advance) max_advance = advance;
        if (cp == 'x') x_advance = advance;
        // Ink bearings are the fallback's, scaled by the advance ratio -- see
        // the header comment. They feed canvas actualBoundingBox* only.
        const ratio = if (base.advance > 0) advance / base.advance else 1;
        g.* = .{
            .advance = advance,
            .left = base.left * ratio,
            .right = base.right * ratio,
            .ascent = base.ascent,
            .descent = base.descent,
        };
    }
    if (!any) return error.NoGlyphs;

    const sizes = fallback.ascents.len;
    const ascents = try allocator.alloc(f64, sizes);
    const descents = try allocator.alloc(f64, sizes);
    const layout_ascents = try allocator.alloc(f64, sizes);
    const layout_descents = try allocator.alloc(f64, sizes);
    const svg_ascents = try allocator.alloc(f64, sizes);
    const svg_descents = try allocator.alloc(f64, sizes);
    for (0..sizes) |i| {
        const size: f64 = @floatFromInt(i + 1);
        const a = @as(f64, @floatFromInt(win_ascent)) / @as(f64, @floatFromInt(upem)) * size;
        const d = @as(f64, @floatFromInt(win_descent)) / @as(f64, @floatFromInt(upem)) * size;
        // Sizes 1 to 3 keep the unrounded value; above that Chrome rounds.
        // Measured: 117 of 120 sizes of Arial match with this branch, and the
        // three that do not are exactly those.
        const round_it = size >= 4;
        ascents[i] = if (round_it) @round(a) else a;
        descents[i] = if (round_it) @round(d) else d;
        // The layout and SVG pairs are not derivable from the file, so they
        // keep the fallback's ratio against its own canvas pair. An
        // approximation, and labelled as one.
        const base_a = fallback.ascents[i];
        const base_d = fallback.descents[i];
        const ra = if (base_a > 0) ascents[i] / base_a else 1;
        const rd = if (base_d > 0) descents[i] / base_d else 1;
        layout_ascents[i] = fallback.layout_ascents[i] * ra;
        layout_descents[i] = fallback.layout_descents[i] * rd;
        svg_ascents[i] = fallback.svg_ascents[i] * ra;
        svg_descents[i] = fallback.svg_descents[i] * rd;
    }

    return .{
        .glyphs = glyphs,
        .ascents = ascents,
        .descents = descents,
        .layout_ascents = layout_ascents,
        .layout_descents = layout_descents,
        .svg_ascents = svg_ascents,
        .svg_descents = svg_descents,
        // Blink takes avgCharWidth from the `x` advance, which is how Arial's
        // declared 50.0 is exactly its `x`. No `x` in the face leaves the
        // fallback's number.
        .avg_char_width = x_advance orelse fallback.avg_char_width,
        .max_char_width = if (max_advance > 0) max_advance else fallback.max_char_width,
        // A face carrying its own coverage seeds no last-resort run.
        .seeds_last_resort = &.{},
        .after_fallback = &.{},
    };
}

// --- tests ---------------------------------------------------------------

/// A minimal sfnt with the five tables this file reads, so the parser can be
/// tested without a binary fixture in the tree. `advance` is in font units at
/// `upem`, given to every codepoint in U+0020..U+007E.
pub fn synthesize(allocator: Allocator, upem: u16, advance: u16, win_ascent: u16, win_descent: u16) ![]const u8 {
    const num_glyphs: u16 = 0x60; // 0x20..0x7f, glyph id == codepoint
    var head = [_]u8{0} ** 54;
    std.mem.writeInt(u16, head[18..20], upem, .big);
    var hhea = [_]u8{0} ** 36;
    std.mem.writeInt(u16, hhea[34..36], num_glyphs, .big);
    var os2 = [_]u8{0} ** 78;
    std.mem.writeInt(u16, os2[74..76], win_ascent, .big);
    std.mem.writeInt(u16, os2[76..78], win_descent, .big);
    // Freed here: the bytes are copied into `out` below, so the caller only
    // owns the one allocation it is handed.
    const hmtx = try allocator.alloc(u8, @as(usize, num_glyphs) * 4);
    defer allocator.free(hmtx);
    @memset(hmtx, 0);
    for (0..num_glyphs) |i| std.mem.writeInt(u16, hmtx[i * 4 ..][0..2], advance, .big);

    // cmap: one format 4 subtable, one segment covering 0x20..0x7e with
    // idDelta 0 so glyph id equals codepoint, plus the required 0xffff
    // terminator segment.
    var cmap = [_]u8{0} ** (4 + 8 + 32);
    std.mem.writeInt(u16, cmap[2..4], 1, .big); // numTables
    std.mem.writeInt(u16, cmap[4..6], 3, .big); // platform
    std.mem.writeInt(u16, cmap[6..8], 1, .big); // encoding
    std.mem.writeInt(u32, cmap[8..12], 12, .big); // offset
    const sub = cmap[12..];
    std.mem.writeInt(u16, sub[0..2], 4, .big); // format
    std.mem.writeInt(u16, sub[2..4], 32, .big); // length
    std.mem.writeInt(u16, sub[6..8], 4, .big); // segCountX2
    std.mem.writeInt(u16, sub[14..16], 0x7e, .big); // endCode[0]
    std.mem.writeInt(u16, sub[16..18], 0xffff, .big); // endCode[1]
    // reservedPad at 18
    std.mem.writeInt(u16, sub[20..22], 0x20, .big); // startCode[0]
    std.mem.writeInt(u16, sub[22..24], 0xffff, .big); // startCode[1]
    // idDelta[0] = 0, idDelta[1] = 1 so 0xffff maps to glyph 0
    std.mem.writeInt(i16, sub[26..28], 1, .big);
    // idRangeOffset both zero

    const tables = [_]struct { tag: []const u8, data: []const u8 }{
        .{ .tag = "OS/2", .data = &os2 },
        .{ .tag = "cmap", .data = &cmap },
        .{ .tag = "head", .data = &head },
        .{ .tag = "hhea", .data = &hhea },
        .{ .tag = "hmtx", .data = hmtx },
    };
    var total: usize = 12 + tables.len * 16;
    for (tables) |tab| total += (tab.data.len + 3) & ~@as(usize, 3);
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, out[4..6], tables.len, .big);
    var at: usize = 12 + tables.len * 16;
    for (tables, 0..) |tab, i| {
        const rec = 12 + i * 16;
        @memcpy(out[rec..][0..4], tab.tag[0..4]);
        std.mem.writeInt(u32, out[rec + 8 ..][0..4], @intCast(at), .big);
        std.mem.writeInt(u32, out[rec + 12 ..][0..4], @intCast(tab.data.len), .big);
        @memcpy(out[at..][0..tab.data.len], tab.data);
        at += (tab.data.len + 3) & ~@as(usize, 3);
    }
    return out;
}

test "font_file: a synthesized sfnt gives linear advances" {
    const allocator = std.testing.allocator;
    // 1000 units per em, every glyph 500 units wide: half the em, so 50.0 at
    // the table's 100px basis whatever the fallback charges.
    const bytes = try synthesize(allocator, 1000, 500, 800, 200);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const built = family(arena.allocator(), bytes, font_metrics.sans_serif) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(f64, 50.0), built.glyphs['A' - first].advance);
    try std.testing.expectEqual(@as(f64, 50.0), built.glyphs['m' - first].advance);
    // avgCharWidth is the `x` advance, and maxCharWidth the widest one.
    try std.testing.expectEqual(@as(f64, 50.0), built.avg_char_width);
    try std.testing.expectEqual(@as(f64, 50.0), built.max_char_width);
    // U+00AD is zero however wide the font draws it.
    try std.testing.expectEqual(@as(f64, 0), built.glyphs[0x00ad - first].advance);
}

test "font_file: canvas ascent and descent round above 4px and not below" {
    const allocator = std.testing.allocator;
    // 800/200 per 1000 em: 16px gives 12.8 and 3.2, which round to 13 and 3.
    const bytes = try synthesize(allocator, 1000, 500, 800, 200);
    defer allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const built = family(arena.allocator(), bytes, font_metrics.sans_serif) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(f64, 13), built.ascents[15]);
    try std.testing.expectEqual(@as(f64, 3), built.descents[15]);
    // Size 2 keeps 1.6 and 0.4 unrounded.
    try std.testing.expectEqual(@as(f64, 1.6), built.ascents[1]);
    try std.testing.expectEqual(@as(f64, 0.4), built.descents[1]);
}

test "font_file: bytes that are not a font leave the fallback alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(family(arena.allocator(), "", font_metrics.sans_serif) == null);
    try std.testing.expect(family(arena.allocator(), "<!doctype html>", font_metrics.sans_serif) == null);
    // A well-formed header whose directory points past the end.
    var truncated = [_]u8{ 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(family(arena.allocator(), &truncated, font_metrics.sans_serif) == null);
}
