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
//!   * `max_char_width`. Chrome's exact rule for it was not derived, but it is
//!     not a free choice either. Across the ten families that have both a
//!     measured table here and a file on the host,
//!     `halfPixel(OS/2.usWinAscent / unitsPerEm * 100)` is exact for three
//!     (Arial, Georgia, Impact) and off by 0.40 on average, 2.00 at worst --
//!     against a mean of 10.59 and a worst of 23.99 for the widest ASCII
//!     advance, and 8.08 for `head.yMax`. `hhea.advanceWidthMax` is 2 to 5
//!     times too big and the glyph-box width 70 too big. So the ascent-derived
//!     estimator is used, and it stays an estimator: this field feeds only
//!     form-control intrinsic widths (Element.zig), which is why a
//!     webfont-styled `<input>` is approximate rather than wrong.
//!     `avg_char_width` IS exact: Arial's declared 50.0 is the advance of `x`
//!     to the digit, which is how Blink picks it.
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
const font_kerning = @import("font_kerning.zig");
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
    /// The three variation tables. A face without them is a static font and
    /// every path below falls through to `hmtx` unchanged.
    fvar: []const u8 = &.{},
    avar: []const u8 = &.{},
    hvar: []const u8 = &.{},
    /// The two tables a pair adjustment needs: `GPOS` holds the `kern`
    /// feature and `GDEF` the variation store its Device tables index into.
    gpos: []const u8 = &.{},
    gdef: []const u8 = &.{},
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
/// `optical_size` is the font size the text will be laid out at, which is what
/// `font-optical-sizing: auto` pins a variable face's `opsz` axis to. Null
/// leaves the axis alone -- that is `font-optical-sizing: none`, a face with no
/// such axis, and every static font.
///
/// Everything returned is allocated from `allocator` and lives as long as it.
pub fn family(
    allocator: Allocator,
    bytes: []const u8,
    fallback: font_metrics.Family,
    optical_size: ?f64,
) ?font_metrics.Family {
    var arena_tables = std.heap.ArenaAllocator.init(allocator);
    defer arena_tables.deinit();
    const tables = read(arena_tables.allocator(), bytes) orelse return null;
    if (!tables.complete()) {
        log.debug(.browser, "webfont tables incomplete", .{ .bytes = bytes.len });
        return null;
    }
    const coords = if (optical_size) |size| coordsFor(tables, "opsz", size) else null;
    return build(allocator, tables, fallback, coords) catch null;
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
    if (std.mem.eql(u8, name, "fvar")) out.fvar = slice;
    if (std.mem.eql(u8, name, "avar")) out.avar = slice;
    if (std.mem.eql(u8, name, "HVAR")) out.hvar = slice;
    if (std.mem.eql(u8, name, "GPOS")) out.gpos = slice;
    if (std.mem.eql(u8, name, "GDEF")) out.gdef = slice;
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

// --- variations ----------------------------------------------------------
//
// A variable font's `hmtx` holds the DEFAULT instance's advances, and every
// other instance is that plus an `HVAR` delta. The one axis that matters here
// is `opsz`: `font-optical-sizing`'s initial `auto` pins it to the font size,
// so a 16px run of RobotoFlex -- whose `opsz` defaults to 14 -- is charged the
// opsz=16 instance's advances, not the file's. Reading `hmtx` and stopping
// made every character a little too wide by a different amount, which is how
// iphey's `SVG Computed Style` axis read 126.04 against Chrome's 124.41.
//
// Nothing else is instanced. `wght` is already modelled as the family's four
// weight tables, and the rest of RobotoFlex's eleven axes only move if a page
// writes `font-variation-settings`, which is not what this defect was.

/// More axes than this and the face is left at its default instance. The
/// widest real face measured is RobotoFlex at thirteen.
const max_axes = 32;

const Coords = struct {
    values: [max_axes]f64 = @splat(0),
    count: usize = 0,
};

fn f2dot14At(b: []const u8, off: usize) ?f64 {
    const raw = i16At(b, off) orelse return null;
    return @as(f64, @floatFromInt(raw)) / 16384.0;
}

fn fixedAt(b: []const u8, off: usize) ?f64 {
    if (off + 4 > b.len) return null;
    const raw = std.mem.readInt(i32, b[off..][0..4], .big);
    return @as(f64, @floatFromInt(raw)) / 65536.0;
}

/// Every axis at its default (a normalised zero) except `tag`, which is put at
/// `user` in the axis's own units. Null when the face is not variable or does
/// not carry that axis, which is every static font and is not an error.
fn coordsFor(t: Tables, tag: *const [4]u8, user: f64) ?Coords {
    if (t.fvar.len < 16) return null;
    const axes_at = u16At(t.fvar, 4) orelse return null;
    const count = u16At(t.fvar, 8) orelse return null;
    const size = u16At(t.fvar, 10) orelse return null;
    if (count == 0 or count > max_axes or size < 20) return null;

    var out: Coords = .{ .count = count };
    var found = false;
    for (0..count) |i| {
        const rec = @as(usize, axes_at) + i * @as(usize, size);
        if (rec + 20 > t.fvar.len) return null;
        if (!std.mem.eql(u8, t.fvar[rec..][0..4], tag)) continue;
        const min = fixedAt(t.fvar, rec + 4) orelse return null;
        const def = fixedAt(t.fvar, rec + 8) orelse return null;
        const max = fixedAt(t.fvar, rec + 12) orelse return null;
        if (!(min <= def and def <= max)) return null;
        const v = std.math.clamp(user, min, max);
        // The spec's normalisation: the two halves of the axis are scaled
        // separately, so the default always lands on zero however lopsided
        // the range is.
        const n = if (v < def)
            (if (def > min) (v - def) / (def - min) else 0)
        else if (v > def)
            (if (max > def) (v - def) / (max - def) else 0)
        else
            0;
        out.values[i] = avarMap(t.avar, count, i, n);
        found = true;
    }
    if (!found) return null;
    return out;
}

/// `avar`'s piecewise-linear remap of one axis's normalised coordinate. A face
/// with no `avar`, or an axis with no segment map, is the identity -- and
/// RobotoFlex does carry one, so skipping this misses Chrome by more than the
/// defect being fixed.
fn avarMap(avar: []const u8, axis_count: u16, axis: usize, coord: f64) f64 {
    if (avar.len < 8) return coord;
    if ((u16At(avar, 6) orelse 0) != axis_count) return coord;
    // The segment maps are variable-length and consecutive, so the ones ahead
    // of this axis have to be walked past.
    var at: usize = 8;
    for (0..axis) |_| {
        const n = u16At(avar, at) orelse return coord;
        at += 2 + @as(usize, n) * 4;
    }
    const pairs = u16At(avar, at) orelse return coord;
    if (pairs < 2) return coord;
    at += 2;
    if (at + @as(usize, pairs) * 4 > avar.len) return coord;

    var prev_from: f64 = -1;
    var prev_to: f64 = -1;
    for (0..pairs) |i| {
        const from = f2dot14At(avar, at + i * 4) orelse return coord;
        const to = f2dot14At(avar, at + i * 4 + 2) orelse return coord;
        if (coord == from) return to;
        if (coord < from) {
            if (i == 0 or from == prev_from) return to;
            return prev_to + (to - prev_to) * (coord - prev_from) / (from - prev_from);
        }
        prev_from = from;
        prev_to = to;
    }
    return prev_to;
}

/// How much a region contributes at these coordinates: the product of each
/// axis's own triangular weight, and zero the moment one axis is outside its
/// region. `regions` is the flat `VariationRegionList` axis-record array.
fn regionScalar(regions: []const u8, base: usize, axis_count: u16, coords: Coords) f64 {
    var scalar: f64 = 1;
    for (0..axis_count) |a| {
        const rec = base + a * 6;
        const start = f2dot14At(regions, rec) orelse return 0;
        const peak = f2dot14At(regions, rec + 2) orelse return 0;
        const end = f2dot14At(regions, rec + 4) orelse return 0;
        // A zero peak means this axis does not take part, which is how a
        // region names a subset of the axes.
        if (peak == 0) continue;
        const c = if (a < coords.count) coords.values[a] else 0;
        if (c == peak) continue;
        if (c <= start or c >= end) return 0;
        scalar *= if (c < peak)
            (c - start) / (peak - start)
        else
            (end - c) / (end - peak);
    }
    return scalar;
}

/// The `HVAR` advance delta for one glyph, in font units. Null whenever the
/// table is absent or shaped in a way we do not read, which leaves the default
/// instance's advance in place.
fn advanceDelta(t: Tables, gid: u16, coords: Coords) ?f64 {
    const hvar = t.hvar;
    if (hvar.len < 20) return null;
    const ivs_at = u32At(hvar, 4) orelse return null;
    const map_at = u32At(hvar, 8) orelse return null;
    if (ivs_at == 0 or ivs_at >= hvar.len) return null;
    const ivs = hvar[ivs_at..];

    // With no advance mapping the glyph id IS the delta-set index, with an
    // implicit outer of zero -- the spec's shortcut for a font whose deltas
    // are already in glyph order.
    var outer: u32 = 0;
    var inner: u32 = gid;
    if (map_at != 0) {
        if (map_at >= hvar.len) return null;
        const pair = deltaSetIndex(hvar[map_at..], gid) orelse return null;
        outer = pair[0];
        inner = pair[1];
    }

    return ivsDelta(ivs, outer, inner, coords);
}

/// One delta out of an `ItemVariationStore`, in font units: the sum over the
/// store's regions of each region's scalar times the delta it holds for this
/// item. `HVAR` reaches it through a glyph's advance mapping, and a `GPOS`
/// ValueRecord through a Device table whose format says `0x8000` -- the two
/// callers differ only in where the (outer, inner) pair comes from.
fn ivsDelta(ivs: []const u8, outer: u32, inner: u32, coords: Coords) ?f64 {
    if ((u16At(ivs, 0) orelse return null) != 1) return null;
    const regions_at = u32At(ivs, 2) orelse return null;
    const data_count = u16At(ivs, 6) orelse return null;
    if (outer >= data_count) return null;
    const data_at = u32At(ivs, 8 + outer * 4) orelse return null;
    if (regions_at >= ivs.len or data_at >= ivs.len) return null;

    const regions = ivs[regions_at..];
    const region_axes = u16At(regions, 0) orelse return null;
    const region_count = u16At(regions, 2) orelse return null;
    if (region_axes == 0 or region_axes > max_axes) return null;

    const data = ivs[data_at..];
    const item_count = u16At(data, 0) orelse return null;
    const word_field = u16At(data, 2) orelse return null;
    const index_count = u16At(data, 4) orelse return null;
    if (inner >= item_count or index_count > region_count) return null;
    // The high bit widens both sizes: 32/16 bit deltas instead of 16/8.
    const long = word_field & 0x8000 != 0;
    const word_count = word_field & 0x7fff;
    if (word_count > index_count) return null;
    const word_size: usize = if (long) 4 else 2;
    const short_size: usize = if (long) 2 else 1;
    const row = @as(usize, word_count) * word_size +
        (@as(usize, index_count) - word_count) * short_size;
    const rows_at = 6 + @as(usize, index_count) * 2;
    const at = rows_at + @as(usize, inner) * row;
    if (at + row > data.len) return null;

    var total: f64 = 0;
    var off = at;
    for (0..index_count) |i| {
        const region = u16At(data, 6 + i * 2) orelse return null;
        if (region >= region_count) return null;
        const delta: f64 = blk: {
            if (i < word_count) {
                if (long) break :blk @floatFromInt(std.mem.readInt(i32, data[off..][0..4], .big));
                break :blk @floatFromInt(std.mem.readInt(i16, data[off..][0..2], .big));
            }
            if (long) break :blk @floatFromInt(std.mem.readInt(i16, data[off..][0..2], .big));
            break :blk @floatFromInt(@as(i8, @bitCast(data[off])));
        };
        off += if (i < word_count) word_size else short_size;
        if (delta == 0) continue;
        const base = 4 + @as(usize, region) * @as(usize, region_axes) * 6;
        total += regionScalar(regions, base, region_axes, coords) * delta;
    }
    return total;
}

/// `DeltaSetIndexMap`, formats 0 and 1, which differ only in the width of
/// `mapCount`. A glyph past the end repeats the last entry.
fn deltaSetIndex(map: []const u8, gid: u16) ?[2]u32 {
    if (map.len < 2) return null;
    const format = map[0];
    const entry_format = map[1];
    const inner_bits: u5 = @intCast((entry_format & 0x0f) + 1);
    const entry_size: usize = ((entry_format & 0x30) >> 4) + 1;
    const count: u32, const data_at: usize = switch (format) {
        0 => .{ u16At(map, 2) orelse return null, 4 },
        1 => .{ u32At(map, 2) orelse return null, 6 },
        else => return null,
    };
    if (count == 0) return null;
    const index = @min(@as(u32, gid), count - 1);
    const at = data_at + @as(usize, index) * entry_size;
    if (at + entry_size > map.len) return null;
    var entry: u32 = 0;
    for (map[at..][0..entry_size]) |b| entry = (entry << 8) | b;
    const mask: u32 = (@as(u32, 1) << inner_bits) - 1;
    return .{ entry >> inner_bits, entry & mask };
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

// --- GPOS kerning ---------------------------------------------------------
//
// A string's width is the sum of its glyphs' advances PLUS what the font
// adjusts across a pair, and for a downloaded face that adjustment lives in
// `GPOS`'s `kern` feature. `font_kerning.zig` holds the pairs Chrome applies
// for every family on the host, keyed by that family's glyph table -- a
// webfont has no entry there, so this reads the pairs out of the file.
//
// Measured on iphey's RobotoFlex: `Hello, SVG World!` at 16px charges three
// pairs (`o,` -20, `VG` -13, `Wo` -31 font units), which is the 0.48px that
// separated this engine's 124.88 from Chrome's 124.41 once the optical size
// was right. Every one of those three carries a Device table in variation
// form, so the `opsz` instance moves the kern as well as the advance -- which
// is why the table is built per instance rather than once per file.
//
// Latin-1 only, because `font_kerning.Pair` is: the advance tables it sits
// beside cover the same range.

/// `GDEF`'s `ItemVariationStore`, which is what a `GPOS` Device table in
/// variation form indexes into. Empty unless the table declares version 1.3,
/// where the offset was added.
fn gdefVarStore(gdef: []const u8) []const u8 {
    if (gdef.len < 18) return &.{};
    if ((u16At(gdef, 2) orelse 0) < 3) return &.{};
    const off = u32At(gdef, 14) orelse return &.{};
    if (off == 0 or off >= gdef.len) return &.{};
    return gdef[off..];
}

/// The index `gid` has in a Coverage table, or null when it is not covered.
fn coverageIndex(cov: []const u8, gid: u16) ?u16 {
    switch (u16At(cov, 0) orelse return null) {
        1 => {
            const count = u16At(cov, 2) orelse return null;
            // Sorted by glyph id, which is what makes the bisection legal.
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const at = u16At(cov, 4 + mid * 2) orelse return null;
                if (at == gid) return @intCast(mid);
                if (at < gid) lo = mid + 1 else hi = mid;
            }
            return null;
        },
        2 => {
            const count = u16At(cov, 2) orelse return null;
            for (0..count) |i| {
                const rec = 4 + i * 6;
                const start = u16At(cov, rec) orelse return null;
                const end = u16At(cov, rec + 2) orelse return null;
                if (gid < start) return null;
                if (gid > end) continue;
                const base = u16At(cov, rec + 4) orelse return null;
                return base + (gid - start);
            }
            return null;
        },
        else => return null,
    }
}

/// The class `gid` belongs to. Class 0 is both "declared as zero" and "not
/// listed", which the spec makes the same thing.
fn classOf(def: []const u8, gid: u16) u16 {
    switch (u16At(def, 0) orelse return 0) {
        1 => {
            const start = u16At(def, 2) orelse return 0;
            const count = u16At(def, 4) orelse return 0;
            if (gid < start or gid - start >= count) return 0;
            return u16At(def, 6 + @as(usize, gid - start) * 2) orelse 0;
        },
        2 => {
            const count = u16At(def, 2) orelse return 0;
            for (0..count) |i| {
                const rec = 4 + i * 6;
                const start = u16At(def, rec) orelse return 0;
                const end = u16At(def, rec + 2) orelse return 0;
                if (gid < start) return 0;
                if (gid > end) continue;
                return u16At(def, rec + 4) orelse 0;
            }
            return 0;
        },
        else => return 0,
    }
}

/// How many bytes a ValueRecord of this format occupies: one 16-bit field per
/// bit set.
fn valueSize(format: u16) usize {
    return @as(usize, @popCount(format)) * 2;
}

/// The horizontal advance adjustment one ValueRecord charges, in font units,
/// with its variation applied. `at` is the record's offset from the start of
/// `sub`, which is also what a Device offset inside it is measured from.
fn valueXAdvance(
    sub: []const u8,
    at: usize,
    format: u16,
    /// What a Device offset inside the record is measured from. NOT `sub`:
    /// in a format-1 PairPos the offsets in a PairValueRecord are from the
    /// start of the PairSet that holds it, and reading them from the
    /// subtable instead landed on a deltaFormat of 0x0019 where the real
    /// table says 0x8000 -- so every pair in a PairSet silently kept its
    /// unvaried value, which for iphey's `VG` is -13 against the -12.4188
    /// the `opsz` instance charges.
    dev_base: []const u8,
    ivs: []const u8,
    coords: ?Coords,
) f64 {
    var total: f64 = 0;
    if (format & 0x0004 != 0) {
        const off = at + @as(usize, @popCount(format & 0x0003)) * 2;
        const raw = i16At(sub, off) orelse return 0;
        total = @floatFromInt(raw);
    }
    if (format & 0x0040 != 0) {
        const off = at + @as(usize, @popCount(format & 0x003f)) * 2;
        const dev_at = u16At(sub, off) orelse return total;
        const c = coords orelse return total;
        if (dev_at == 0 or ivs.len == 0) return total;
        // Only the variation form says anything about a pair at a design
        // coordinate. The three older formats are per-ppem pixel adjustments
        // for hinted rendering, which is not what is being measured here.
        if ((u16At(dev_base, dev_at + 4) orelse 0) != 0x8000) return total;
        const outer = u16At(dev_base, dev_at) orelse return total;
        const inner = u16At(dev_base, dev_at + 2) orelse return total;
        if (ivsDelta(ivs, outer, inner, c)) |d| total += d;
    }
    return total;
}

/// What one PairPos subtable charges across `first`/`second`, in font units.
fn pairPosAdjust(sub: []const u8, left: u16, right: u16, ivs: []const u8, coords: ?Coords) f64 {
    const format = u16At(sub, 0) orelse return 0;
    const cov_at = u16At(sub, 2) orelse return 0;
    if (cov_at >= sub.len) return 0;
    const index = coverageIndex(sub[cov_at..], left) orelse return 0;
    const fmt1 = u16At(sub, 4) orelse return 0;
    const fmt2 = u16At(sub, 6) orelse return 0;
    switch (format) {
        1 => {
            const set_count = u16At(sub, 8) orelse return 0;
            if (index >= set_count) return 0;
            const set_at = u16At(sub, 10 + @as(usize, index) * 2) orelse return 0;
            if (set_at >= sub.len) return 0;
            const count = u16At(sub, set_at) orelse return 0;
            const stride = 2 + valueSize(fmt1) + valueSize(fmt2);
            for (0..count) |i| {
                const rec = set_at + 2 + i * stride;
                const glyph = u16At(sub, rec) orelse return 0;
                if (glyph != right) continue;
                return valueXAdvance(sub, rec + 2, fmt1, sub[set_at..], ivs, coords);
            }
            return 0;
        },
        2 => {
            const def1_at = u16At(sub, 8) orelse return 0;
            const def2_at = u16At(sub, 10) orelse return 0;
            const class1_count = u16At(sub, 12) orelse return 0;
            const class2_count = u16At(sub, 14) orelse return 0;
            if (def1_at >= sub.len or def2_at >= sub.len) return 0;
            const c1 = classOf(sub[def1_at..], left);
            const c2 = classOf(sub[def2_at..], right);
            if (c1 >= class1_count or c2 >= class2_count) return 0;
            const cell = valueSize(fmt1) + valueSize(fmt2);
            const at = 16 + (@as(usize, c1) * @as(usize, class2_count) + c2) * cell;
            // A Class2Record sits in the subtable itself, so its Device
            // offsets are measured from there.
            return valueXAdvance(sub, at, fmt1, sub, ivs, coords);
        },
        else => return 0,
    }
}

/// The subtable a Lookup's `i`th entry points at, unwrapping the Extension
/// indirection a large font uses to reach past 64KB. Null when the entry is
/// not a pair adjustment.
fn pairPosSubtable(gpos: []const u8, lookup_at: usize, i: usize) ?[]const u8 {
    const kind = u16At(gpos, lookup_at) orelse return null;
    const off = u16At(gpos, lookup_at + 6 + i * 2) orelse return null;
    const at = lookup_at + off;
    if (at >= gpos.len) return null;
    const sub = gpos[at..];
    if (kind == 2) return sub;
    // Type 9 is `ExtensionPos`, whose only job is to carry a 32-bit offset to
    // a subtable of the type it names.
    if (kind != 9) return null;
    if ((u16At(sub, 0) orelse 0) != 1) return null;
    if ((u16At(sub, 2) orelse 0) != 2) return null;
    const far = u32At(sub, 4) orelse return null;
    if (far == 0 or far >= sub.len) return null;
    return sub[far..];
}

/// Every PairPos subtable the `kern` feature reaches, in lookup order.
fn kernSubtables(allocator: Allocator, gpos: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (gpos.len < 10) return out.items;
    const feature_at = u16At(gpos, 6) orelse return out.items;
    const lookup_at = u16At(gpos, 8) orelse return out.items;
    if (feature_at >= gpos.len or lookup_at >= gpos.len) return out.items;
    const lookup_count = u16At(gpos, lookup_at + 0) orelse return out.items;

    // The feature list rather than a script/language walk: `kern` is declared
    // once per script here and the lookups it names are the same set, so the
    // union over the list is what any script's chain would reach. Every
    // feature record with the tag is taken, which is what a page that mixes
    // scripts would get anyway.
    const feature_count = u16At(gpos, feature_at) orelse return out.items;
    var seen: std.AutoHashMapUnmanaged(u16, void) = .empty;
    for (0..feature_count) |i| {
        const rec = feature_at + 2 + i * 6;
        if (rec + 6 > gpos.len) break;
        if (!std.mem.eql(u8, gpos[rec..][0..4], "kern")) continue;
        const off = u16At(gpos, rec + 4) orelse continue;
        const feature = feature_at + off;
        const indices = u16At(gpos, feature + 2) orelse continue;
        for (0..indices) |j| {
            const index = u16At(gpos, feature + 4 + j * 2) orelse break;
            if (index >= lookup_count) continue;
            if ((try seen.getOrPut(allocator, index)).found_existing) continue;
            const lk_off = u16At(gpos, lookup_at + 2 + @as(usize, index) * 2) orelse continue;
            const lk = lookup_at + lk_off;
            const sub_count = u16At(gpos, lk + 4) orelse continue;
            for (0..sub_count) |k| {
                if (pairPosSubtable(gpos, lk, k)) |sub| try out.append(allocator, sub);
            }
        }
    }
    return out.items;
}

/// The face's own kern pairs over Latin-1, at the 100px basis every advance in
/// `font_metrics.zig` is stored at. Empty whenever the face has no `GPOS`
/// `kern` feature, which leaves the engine summing bare advances as before.
fn kernTable(
    allocator: Allocator,
    t: Tables,
    coords: ?Coords,
    per_unit: f64,
) !font_kerning.Table {
    if (t.gpos.len == 0) return .{};

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const subtables = try kernSubtables(scratch.allocator(), t.gpos);
    if (subtables.len == 0) return .{};
    const ivs = gdefVarStore(t.gdef);

    // The glyph each Latin-1 code point maps to, once: the pair loop below
    // would otherwise walk `cmap` 65 536 times.
    var gids: [256]?u16 = @splat(null);
    for (0..256) |cp| gids[cp] = glyphId(t.cmap, @intCast(cp));

    var pairs: std.ArrayList(font_kerning.Pair) = .empty;
    var starts: [4]u64 = .{ 0, 0, 0, 0 };
    for (0..256) |a| {
        const left = gids[a] orelse continue;
        // Most characters start no pair at all, and a Coverage miss is one
        // bisection against 256 subtable walks.
        var covered = false;
        for (subtables) |sub| {
            const cov_at = u16At(sub, 2) orelse continue;
            if (cov_at >= sub.len) continue;
            if (coverageIndex(sub[cov_at..], left) != null) covered = true;
        }
        if (!covered) continue;
        for (0..256) |b| {
            const right = gids[b] orelse continue;
            var units: f64 = 0;
            for (subtables) |sub| {
                const one = pairPosAdjust(sub, left, right, ivs, coords);
                units += one;
            }
            // Unrounded, for the same reason the advances above are: the
            // quantisation Chrome applies is one `@ceil` over the whole run.
            if (units == 0) continue;
            try pairs.append(allocator, .{
                .first = @intCast(a),
                .second = @intCast(b),
                .kern = units * per_unit,
            });
            starts[a >> 6] |= @as(u64, 1) << @intCast(a & 63);
        }
    }
    // Already in (first, second) order, which is what the bisection in
    // `font_kerning.kern` needs -- the loops above walk both in ascending
    // code point order.
    return .{ .pairs = try pairs.toOwnedSlice(allocator), .starts = starts };
}

fn build(
    allocator: Allocator,
    t: Tables,
    fallback: font_metrics.Family,
    coords: ?Coords,
) !font_metrics.Family {
    const upem = u16At(t.head, 18) orelse return error.NoUnitsPerEm;
    if (upem == 0) return error.NoUnitsPerEm;
    const num_h_metrics = u16At(t.hhea, 34) orelse return error.NoHMetrics;
    const win_ascent = u16At(t.os2, 74) orelse return error.NoWinAscent;
    const win_descent = u16At(t.os2, 76) orelse return error.NoWinDescent;
    const per_unit = font_metrics.basis / @as(f64, @floatFromInt(upem));

    const glyphs = try allocator.alloc(font_metrics.Glyph, glyph_count);
    var x_advance: ?f64 = null;
    var any = false;
    for (glyphs, 0..) |*g, i| {
        const cp: u21 = @intCast(first + i);
        const base = fallback.glyphs[i];
        // U+00AD is zero-advance in Chrome however wide the font draws it --
        // measured against glyphs_arial, which says 0 where Arial says 33.30.
        const units: ?f64 = if (cp == 0x00ad) 0 else blk: {
            const gid = glyphId(t.cmap, cp) orelse break :blk null;
            const base_units = advanceUnits(t, num_h_metrics, gid) orelse break :blk null;
            var v: f64 = @floatFromInt(base_units);
            // UNROUNDED, unlike the `hmtx` entry it comes from: Chrome
            // quantises the measured run rather than the glyph, so the
            // fraction has to survive to the sum. See
            // `font_metrics.Family.units_per_em`.
            if (coords) |c| {
                if (advanceDelta(t, gid, c)) |d| v = @max(0, v + d);
            }
            break :blk v;
        };
        if (units == null) {
            // No glyph in this face: leave the fallback's cost, which is what
            // a real fallback chain would charge for it anyway.
            g.* = base;
            continue;
        }
        any = true;
        const advance = units.? * per_unit;
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
        // See the header: the closest estimator measured, not Chrome's rule.
        .max_char_width = @round(@as(f64, @floatFromInt(win_ascent)) * per_unit * 2) / 2,
        // Between the swept sizes the box comes off the file's own metrics
        // rather than the fallback's, which is where Chrome gets it: the two
        // agree at the integer sizes above only up to the ratio applied there,
        // and the `hhea` pair is the thing Blink actually rounds onto the
        // device grid. No line gap and no Safari-compat hack -- that one is
        // keyed on three installed face names, which a downloaded face is not.
        .ladder = .{
            .asc = @as(f64, @floatFromInt(win_ascent)) / @as(f64, @floatFromInt(upem)),
            .desc = @as(f64, @floatFromInt(win_descent)) / @as(f64, @floatFromInt(upem)),
            .gap = 0,
            .hack = false,
        },
        // A face carrying its own coverage seeds no last-resort run.
        .seeds_last_resort = &.{},
        .after_fallback = &.{},
        // The pairs the file's own `GPOS` kerns with, at this instance.
        .own_kerns = kernTable(allocator, t, coords, per_unit) catch .{},
        // Which makes the advances above quantisable at the point of
        // measurement rather than here.
        .units_per_em = @floatFromInt(upem),
    };
}

// --- tests ---------------------------------------------------------------

/// A minimal sfnt with the five tables this file reads, so the parser can be
/// tested without a binary fixture in the tree. `advance` is in font units at
/// `upem`, given to every codepoint in U+0020..U+007E.
pub fn synthesize(allocator: Allocator, upem: u16, advance: u16, win_ascent: u16, win_descent: u16) ![]const u8 {
    return synthesizeInner(allocator, upem, advance, win_ascent, win_descent, null);
}

/// One variation axis and the advance delta it carries, for the synthesized
/// variable font below. `delta_at_max` is added to every advance when the axis
/// sits at `max`, interpolated linearly down to zero at `default` -- one region
/// with its peak at the maximum, which is the simplest shape a real HVAR has.
pub const VarSpec = struct {
    tag: *const [4]u8,
    min: f64,
    default: f64,
    max: f64,
    delta_at_max: i8,
    /// When set, the font also carries a `GPOS` `kern` feature charging this
    /// one pair, and the `GDEF` `ItemVariationStore` the pair's Device table
    /// indexes into.
    kern: ?KernSpec = null,
};

/// The single kern pair the synthesized font charges, in font units.
/// `delta_at_max` rides the same axis and region as the advance delta above,
/// so the adjustment is `x_advance` at the axis default and
/// `x_advance + delta_at_max` at its maximum.
pub const KernSpec = struct {
    first: u8,
    second: u8,
    x_advance: i16,
    delta_at_max: i8,
};

/// The same minimal sfnt plus `fvar` and `HVAR`, so optical sizing can be
/// tested without shipping a real variable font. RobotoFlex -- the face iphey
/// measures its `SVG Computed Style` axis with -- is variable with an `opsz`
/// axis defaulting to 14, and Chrome's `font-optical-sizing: auto` pins that
/// axis to the font size: the advances it charges at 16px are the opsz=16
/// instance's, not the file's `hmtx`.
pub fn synthesizeVariable(
    allocator: Allocator,
    upem: u16,
    advance: u16,
    win_ascent: u16,
    win_descent: u16,
    spec: VarSpec,
) ![]const u8 {
    return synthesizeInner(allocator, upem, advance, win_ascent, win_descent, spec);
}

fn synthesizeInner(
    allocator: Allocator,
    upem: u16,
    advance: u16,
    win_ascent: u16,
    win_descent: u16,
    spec: ?VarSpec,
) ![]const u8 {
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

    const s = spec orelse return packSfnt(allocator, &.{
        .{ .tag = "OS/2", .data = &os2 },
        .{ .tag = "cmap", .data = &cmap },
        .{ .tag = "head", .data = &head },
        .{ .tag = "hhea", .data = &hhea },
        .{ .tag = "hmtx", .data = hmtx },
    });

    // fvar: one axis, no named instances. A 16-byte header then one 20-byte
    // VariationAxisRecord of 16.16 fixed-point bounds.
    var fvar = [_]u8{0} ** 36;
    std.mem.writeInt(u16, fvar[0..2], 1, .big); // majorVersion
    std.mem.writeInt(u16, fvar[4..6], 16, .big); // axesArrayOffset
    std.mem.writeInt(u16, fvar[6..8], 2, .big); // reserved, always 2
    std.mem.writeInt(u16, fvar[8..10], 1, .big); // axisCount
    std.mem.writeInt(u16, fvar[10..12], 20, .big); // axisSize
    std.mem.writeInt(u16, fvar[14..16], 8, .big); // instanceSize: axisCount*4+4
    @memcpy(fvar[16..20], s.tag);
    std.mem.writeInt(i32, fvar[20..24], fixed16_16(s.min), .big);
    std.mem.writeInt(i32, fvar[24..28], fixed16_16(s.default), .big);
    std.mem.writeInt(i32, fvar[28..32], fixed16_16(s.max), .big);
    std.mem.writeInt(u16, fvar[34..36], 256, .big); // axisNameID

    // HVAR: a 20-byte header, then an ItemVariationStore. Every mapping
    // offset is zero, which is the spec's "glyph id IS the delta-set index"
    // shortcut, so `item_count` has to cover the largest glyph id.
    const item_count: u16 = 128;
    const hvar = try allocator.alloc(u8, 20 + ivsLen(item_count));
    defer allocator.free(hvar);
    @memset(hvar, 0);
    std.mem.writeInt(u16, hvar[0..2], 1, .big); // majorVersion
    std.mem.writeInt(u32, hvar[4..8], 20, .big); // itemVariationStoreOffset
    writeIvs(hvar[20..], item_count, s.delta_at_max);

    const k = s.kern orelse return packSfnt(allocator, &.{
        .{ .tag = "HVAR", .data = hvar },
        .{ .tag = "OS/2", .data = &os2 },
        .{ .tag = "cmap", .data = &cmap },
        .{ .tag = "fvar", .data = &fvar },
        .{ .tag = "head", .data = &head },
        .{ .tag = "hhea", .data = &hhea },
        .{ .tag = "hmtx", .data = hmtx },
    });

    // GDEF 1.3, which is the version that added the item variation store a
    // `GPOS` Device table in variation form indexes into. One delta, at
    // (outer 0, inner 0).
    const gdef = try allocator.alloc(u8, 18 + ivsLen(1));
    defer allocator.free(gdef);
    @memset(gdef, 0);
    std.mem.writeInt(u16, gdef[0..2], 1, .big); // majorVersion
    std.mem.writeInt(u16, gdef[2..4], 3, .big); // minorVersion
    std.mem.writeInt(u32, gdef[14..18], 18, .big); // itemVarStoreOffset
    writeIvs(gdef[18..], 1, k.delta_at_max);

    // GPOS: a 10-byte header, an empty ScriptList, a FeatureList naming
    // `kern` once, a LookupList of one type-2 lookup, and one PairPos format
    // 1 subtable charging the single pair.
    var gpos = [_]u8{0} ** 70;
    std.mem.writeInt(u16, gpos[0..2], 1, .big); // majorVersion
    std.mem.writeInt(u16, gpos[4..6], 10, .big); // scriptListOffset
    std.mem.writeInt(u16, gpos[6..8], 12, .big); // featureListOffset
    std.mem.writeInt(u16, gpos[8..10], 26, .big); // lookupListOffset
    // ScriptList at 10: no scripts. The kern lookups are found through the
    // feature list, which is the union any script's chain would reach.
    std.mem.writeInt(u16, gpos[10..12], 0, .big); // scriptCount
    // FeatureList at 12: one record, whose feature table sits at 20.
    std.mem.writeInt(u16, gpos[12..14], 1, .big); // featureCount
    @memcpy(gpos[14..18], "kern");
    std.mem.writeInt(u16, gpos[18..20], 8, .big); // featureOffset, from 12
    // Feature at 20: lookup 0.
    std.mem.writeInt(u16, gpos[22..24], 1, .big); // lookupIndexCount
    std.mem.writeInt(u16, gpos[24..26], 0, .big); // lookupListIndices[0]
    // LookupList at 26: one lookup, at 30.
    std.mem.writeInt(u16, gpos[26..28], 1, .big); // lookupCount
    std.mem.writeInt(u16, gpos[28..30], 4, .big); // lookupOffsets[0], from 26
    // Lookup at 30: type 2 (pair adjustment), one subtable at 38.
    std.mem.writeInt(u16, gpos[30..32], 2, .big); // lookupType
    std.mem.writeInt(u16, gpos[34..36], 1, .big); // subTableCount
    std.mem.writeInt(u16, gpos[36..38], 8, .big); // subtableOffsets[0], from 30
    // PairPos format 1 at 38. Offsets below are from there.
    const pp = gpos[38..];
    std.mem.writeInt(u16, pp[0..2], 1, .big); // posFormat
    std.mem.writeInt(u16, pp[2..4], 12, .big); // coverageOffset
    // XAdvance plus XAdvDevice: the pair's adjustment varies with the axis.
    std.mem.writeInt(u16, pp[4..6], 0x0044, .big); // valueFormat1
    std.mem.writeInt(u16, pp[6..8], 0, .big); // valueFormat2
    std.mem.writeInt(u16, pp[8..10], 1, .big); // pairSetCount
    std.mem.writeInt(u16, pp[10..12], 18, .big); // pairSetOffsets[0]
    // Coverage format 1 at 12: the pair's first glyph. Glyph id is the code
    // point, which is what the cmap above declares.
    std.mem.writeInt(u16, pp[12..14], 1, .big); // coverageFormat
    std.mem.writeInt(u16, pp[14..16], 1, .big); // glyphCount
    std.mem.writeInt(u16, pp[16..18], k.first, .big); // glyphArray[0]
    // PairSet at 18: one PairValueRecord.
    std.mem.writeInt(u16, pp[18..20], 1, .big); // pairValueCount
    std.mem.writeInt(u16, pp[20..22], k.second, .big); // secondGlyph
    std.mem.writeInt(i16, pp[22..24], k.x_advance, .big); // xAdvance
    // The Device offset a PairValueRecord carries is measured from the start
    // of the PairSet, not of the subtable -- and this font is laid out so the
    // two disagree: 8 from the PairSet reaches the VariationIndex at 26,
    // while 8 from the subtable reaches `pairSetCount` and reads a
    // deltaFormat of 1 rather than 0x8000, which silently drops the pair's
    // variation. That is the bug this fixture exists to catch.
    std.mem.writeInt(u16, pp[24..26], 8, .big); // xAdvDeviceOffset, from 18
    // VariationIndex at 26: (outer 0, inner 0) into GDEF's store.
    std.mem.writeInt(u16, pp[30..32], 0x8000, .big); // deltaFormat

    return packSfnt(allocator, &.{
        .{ .tag = "GDEF", .data = gdef },
        .{ .tag = "GPOS", .data = &gpos },
        .{ .tag = "HVAR", .data = hvar },
        .{ .tag = "OS/2", .data = &os2 },
        .{ .tag = "cmap", .data = &cmap },
        .{ .tag = "fvar", .data = &fvar },
        .{ .tag = "head", .data = &head },
        .{ .tag = "hhea", .data = &hhea },
        .{ .tag = "hmtx", .data = hmtx },
    });
}

/// How long `writeIvs` needs its destination to be.
fn ivsLen(item_count: u16) usize {
    return 22 + 8 + @as(usize, item_count);
}

/// An `ItemVariationStore` holding one byte-sized `delta` per item, over a
/// single region of a single axis peaking at the axis maximum -- so the
/// region's scalar is the normalised coordinate itself.
fn writeIvs(ivs: []u8, item_count: u16, delta: i8) void {
    std.mem.writeInt(u16, ivs[0..2], 1, .big); // format
    std.mem.writeInt(u32, ivs[2..6], 12, .big); // variationRegionListOffset
    std.mem.writeInt(u16, ivs[6..8], 1, .big); // itemVariationDataCount
    std.mem.writeInt(u32, ivs[8..12], 22, .big); // itemVariationDataOffsets[0]
    std.mem.writeInt(u16, ivs[12..14], 1, .big); // axisCount
    std.mem.writeInt(u16, ivs[14..16], 1, .big); // regionCount
    std.mem.writeInt(i16, ivs[16..18], 0, .big); // startCoord 0.0
    std.mem.writeInt(i16, ivs[18..20], 0x4000, .big); // peakCoord 1.0
    std.mem.writeInt(i16, ivs[20..22], 0x4000, .big); // endCoord 1.0
    // ItemVariationData: one byte-sized delta per item, one region.
    const ivd = ivs[22..];
    std.mem.writeInt(u16, ivd[0..2], item_count, .big);
    std.mem.writeInt(u16, ivd[2..4], 0, .big); // wordDeltaCount: all bytes
    std.mem.writeInt(u16, ivd[4..6], 1, .big); // regionIndexCount
    std.mem.writeInt(u16, ivd[6..8], 0, .big); // regionIndexes[0]
    for (0..item_count) |i| ivd[8 + i] = @bitCast(delta);
}

fn fixed16_16(v: f64) i32 {
    return @intFromFloat(@round(v * 65536.0));
}

const SynthTable = struct { tag: []const u8, data: []const u8 };

/// Lay tables out as an sfnt. The directory has to be sorted by tag, which is
/// the caller's job -- every caller here writes them in order.
fn packSfnt(allocator: Allocator, tables: []const SynthTable) ![]const u8 {
    var total: usize = 12 + tables.len * 16;
    for (tables) |tab| total += (tab.data.len + 3) & ~@as(usize, 3);
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, out[4..6], @intCast(tables.len), .big);
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
    const built = family(arena.allocator(), bytes, font_metrics.sans_serif, null) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(f64, 50.0), built.glyphs['A' - first].advance);
    try std.testing.expectEqual(@as(f64, 50.0), built.glyphs['m' - first].advance);
    // avgCharWidth is the `x` advance. maxCharWidth is the ascent-derived
    // estimator, so 800/1000 of the 100px basis rather than any advance.
    try std.testing.expectEqual(@as(f64, 50.0), built.avg_char_width);
    try std.testing.expectEqual(@as(f64, 80.0), built.max_char_width);
    // U+00AD is zero however wide the font draws it.
    try std.testing.expectEqual(@as(f64, 0), built.glyphs[0x00ad - first].advance);
}

test "font_file: a synthesized variable font parses, and reads as its default instance" {
    const allocator = std.testing.allocator;
    // The same 1000/500 font with an `opsz` axis and an HVAR that takes 100
    // units off at the maximum. Nothing here applies a variation yet, so the
    // advance is still the file's own -- what this asserts is that the two
    // extra tables do not break the parse, which is the only way the HTML
    // test next door can be read as "the axis was ignored" rather than "the
    // fixture is malformed".
    const bytes = try synthesizeVariable(allocator, 1000, 500, 800, 200, .{
        .tag = "opsz",
        .min = 8,
        .default = 14,
        .max = 16,
        .delta_at_max = -100,
    });
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const built = family(arena.allocator(), bytes, font_metrics.sans_serif, null) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(f64, 50.0), built.glyphs['A' - first].advance);
    try std.testing.expectEqual(@as(f64, 50.0), built.glyphs['m' - first].advance);
}

test "font_file: a GPOS kern pair varies with the instance" {
    const allocator = std.testing.allocator;
    // `opsz` 8..40 with the default at the minimum, so a 16px instance
    // normalises to (16-8)/(40-8) = 0.25 and the pair's variation applies at
    // a quarter strength. Advances are flat -- the whole reading is the pair.
    const bytes = try synthesizeVariable(allocator, 1000, 500, 800, 200, .{
        .tag = "opsz",
        .min = 8,
        .default = 8,
        .max = 40,
        .delta_at_max = 0,
        .kern = .{ .first = 'm', .second = 'm', .x_advance = -20, .delta_at_max = 5 },
    });
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const at_default = family(arena.allocator(), bytes, font_metrics.sans_serif, null) orelse
        return error.TestUnexpectedResult;
    const at16 = family(arena.allocator(), bytes, font_metrics.sans_serif, 16) orelse
        return error.TestUnexpectedResult;

    const per_unit = font_metrics.basis / 1000.0;
    // The default instance charges the bare ValueRecord: no coordinates, so
    // no Device table to evaluate.
    try std.testing.expectEqual(
        -20.0 * per_unit,
        font_kerning.kern(at_default.own_kerns, 'm', 'm'),
    );
    // At 16px the VariationIndex adds 0.25 * 5. Reading its offset from the
    // subtable rather than from the PairSet lands on a deltaFormat of 1, and
    // this pair would silently stay at -20 -- which is exactly what the two
    // readings being equal would mean.
    try std.testing.expectEqual(
        -18.75 * per_unit,
        font_kerning.kern(at16.own_kerns, 'm', 'm'),
    );
    // Only the one pair, and only in the one direction the font declares.
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(at16.own_kerns, 'n', 'm'));
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(at16.own_kerns, 'm', 'n'));
    // Declared, so `text_measure.quantise` has a grid to round the run onto.
    try std.testing.expectEqual(@as(f64, 1000), at16.units_per_em);
}

test "font_file: canvas ascent and descent round above 4px and not below" {
    const allocator = std.testing.allocator;
    // 800/200 per 1000 em: 16px gives 12.8 and 3.2, which round to 13 and 3.
    const bytes = try synthesize(allocator, 1000, 500, 800, 200);
    defer allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const built = family(arena.allocator(), bytes, font_metrics.sans_serif, null) orelse
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
    try std.testing.expect(family(arena.allocator(), "", font_metrics.sans_serif, null) == null);
    try std.testing.expect(family(arena.allocator(), "<!doctype html>", font_metrics.sans_serif, null) == null);
    // A well-formed header whose directory points past the end.
    var truncated = [_]u8{ 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(family(arena.allocator(), &truncated, font_metrics.sans_serif, null) == null);
}
