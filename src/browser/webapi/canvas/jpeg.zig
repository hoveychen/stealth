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

// A baseline JFIF JPEG writer, for `canvas.toDataURL('image/jpeg')`.
//
// Chrome encodes exactly three of the IANA image types and falls back to PNG
// for the rest; JPEG is one of them, so a canvas that answers `data:image/png`
// to `toDataURL('image/jpeg')` names its engine in one expression. Kasada walks
// the whole registry on x-hyatt and counts which handful come back as
// themselves (tools/fingerprint/probes/kasada-argument-answers.js).
//
// What is matched, and what is not. The container is Chrome's byte for byte
// through the JFIF APP0 -- same marker, same 1.1 version, same 1x1 aspect
// density -- because that header is fixed, and the quantisation and Huffman
// tables are the ones in the standard's Annex K, which is where libjpeg-turbo
// takes its own from. The entropy-coded scan is not: libjpeg-turbo's forward
// DCT, its rounding and its progressive-vs-baseline choices are artefacts of
// that library, and reproducing them would mean vendoring it. The same
// reasoning as png.zig -- the type is the reading, the bytes are not.
//
// Sampled 4:2:0 with two quantisation tables, which is what Skia asks
// libjpeg-turbo for.
//
// Transparency: JPEG has no alpha channel, and Chrome composites the canvas
// onto black rather than white before encoding. Measured with
// probes/canvas-encode-types.js: a straight rgba(255,0,0,0.5) pixel comes back
// as (118,0,7) -- 255x0.5 with the encoder's own loss on top -- and a fully
// transparent one as black. So the premultiplied bitmap *is* the image, and
// compositing is a multiply by alpha.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Chrome's default when `toDataURL` is handed no quality, or one that is not a
/// number in [0, 1] (measured: -1, 2, NaN, 'x', null and true all land here).
pub const default_quality = 0.92;

/// Encodes `width` x `height` straight-alpha RGBA8 pixels. A null `pixels`
/// means the canvas was never drawn into: every pixel is transparent black,
/// which composites onto black as a black image.
///
/// `quality` is the IDL argument, in [0, 1]; the caller has already replaced
/// anything out of range with `default_quality`.
pub fn encode(allocator: Allocator, width: u32, height: u32, pixels: ?[]const u8, quality: f64) ![]u8 {
    std.debug.assert(width > 0 and height > 0);
    if (pixels) |p| {
        std.debug.assert(p.len == @as(usize, width) * height * 4);
    }

    const tables: Tables = .forQuality(quality);

    // A rough guess at the compressed size; the writer grows past it as needed.
    var out: Writer.Allocating = try .initCapacity(allocator, 1024 + @as(usize, width) * height);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(&.{ 0xFF, 0xD8 }); // SOI
    try writeApp0(w);
    try writeQuantTables(w, &tables);
    try writeFrameHeader(w, width, height);
    try writeHuffmanTables(w);
    try writeScanHeader(w);
    try writeScan(w, width, height, pixels, &tables);
    try w.writeAll(&.{ 0xFF, 0xD9 }); // EOI

    return out.toOwnedSlice();
}

// -- Header segments ---------------------------------------------------------

/// The JFIF APP0 Chrome writes: version 1.1, no density unit, a 1x1 pixel
/// aspect ratio and no thumbnail. Byte for byte what libjpeg-turbo emits, which
/// is why a Chrome JPEG and ours share the first 18 bytes.
fn writeApp0(w: *Writer) !void {
    try w.writeAll(&.{
        0xFF, 0xE0, // APP0
        0x00, 0x10, // length: 16
        'J',  'F',
        'I',  'F',
        0x00, // identifier
        0x01, 0x01, // version 1.1
        0x00, // density units: none
        0x00, 0x01, // x density
        0x00, 0x01, // y density
        0x00, // thumbnail width
        0x00, // thumbnail height
    });
}

fn writeQuantTables(w: *Writer, tables: *const Tables) !void {
    // libjpeg emits each table in its own DQT segment.
    for ([_]u8{ 0, 1 }) |id| {
        const table = if (id == 0) &tables.luma else &tables.chroma;
        try w.writeAll(&.{ 0xFF, 0xDB, 0x00, 0x43 });
        try w.writeByte(id); // 8-bit precision in the high nibble, id in the low
        // A DQT carries its table in zig-zag order.
        for (zigzag) |natural| {
            try w.writeByte(table[natural]);
        }
    }
}

/// SOF0: baseline sequential, three components, 4:2:0.
fn writeFrameHeader(w: *Writer, width: u32, height: u32) !void {
    try w.writeAll(&.{ 0xFF, 0xC0, 0x00, 0x11, 0x08 });
    try w.writeInt(u16, @intCast(height), .big);
    try w.writeInt(u16, @intCast(width), .big);
    try w.writeByte(3); // components
    try w.writeAll(&.{
        1, 0x22, 0, // Y:  2x2 sampling, quantisation table 0
        2, 0x11, 1, // Cb: 1x1 sampling, quantisation table 1
        3, 0x11, 1, // Cr: 1x1 sampling, quantisation table 1
    });
}

fn writeHuffmanTables(w: *Writer) !void {
    const all = [_]struct { class_and_id: u8, spec: *const Spec }{
        .{ .class_and_id = 0x00, .spec = &dc_luma },
        .{ .class_and_id = 0x10, .spec = &ac_luma },
        .{ .class_and_id = 0x01, .spec = &dc_chroma },
        .{ .class_and_id = 0x11, .spec = &ac_chroma },
    };
    for (all) |table| {
        try w.writeAll(&.{ 0xFF, 0xC4 });
        try w.writeInt(u16, @intCast(2 + 1 + 16 + table.spec.values.len), .big);
        try w.writeByte(table.class_and_id);
        try w.writeAll(&table.spec.counts);
        try w.writeAll(table.spec.values);
    }
}

/// SOS: all three components in one baseline scan.
fn writeScanHeader(w: *Writer) !void {
    try w.writeAll(&.{
        0xFF, 0xDA,
        0x00, 0x0C,
        3, // components in the scan
        1, 0x00, // Y:  DC table 0, AC table 0
        2, 0x11, // Cb: DC table 1, AC table 1
        3, 0x11, // Cr: DC table 1, AC table 1
        0x00, 0x3F, 0x00, // spectral selection 0..63, no successive approximation
    });
}

// -- Quantisation ------------------------------------------------------------

const Tables = struct {
    luma: [64]u8,
    chroma: [64]u8,

    /// libjpeg's `jpeg_quality_scaling` followed by `jpeg_add_quant_table`: the
    /// quality maps to a percentage scale, every base value is scaled by it and
    /// then clamped into what a baseline decoder accepts.
    fn forQuality(quality: f64) Tables {
        const percent = std.math.clamp(@round(quality * 100), 1, 100);
        const scale: f64 = if (percent < 50) 5000 / percent else 200 - percent * 2;

        var tables: Tables = undefined;
        for (base_luma, base_chroma, 0..) |luma_step, chroma_step, i| {
            tables.luma[i] = scaled(luma_step, scale);
            tables.chroma[i] = scaled(chroma_step, scale);
        }
        return tables;
    }

    fn scaled(value: u8, scale: f64) u8 {
        const wide = @divTrunc(@as(f64, @floatFromInt(value)) * scale + 50, 100);
        return @intFromFloat(std.math.clamp(wide, 1, 255));
    }
};

/// Annex K.1, in natural order.
const base_luma = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

/// Annex K.2, in natural order.
const base_chroma = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

/// Natural index of each zig-zag position.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// -- The scan ----------------------------------------------------------------

/// One 8x8 block of samples, centred on zero as the DCT wants them.
const Block = [64]f32;

/// Walks the image in 16x16 MCUs -- four luma blocks, one of each chroma -- and
/// writes each one's coefficients out through the Huffman tables.
fn writeScan(w: *Writer, width: u32, height: u32, pixels: ?[]const u8, tables: *const Tables) !void {
    var bits: BitWriter = .{ .out = w };
    var previous_dc: [3]i32 = .{ 0, 0, 0 };

    const mcus_across = (width + 15) / 16;
    const mcus_down = (height + 15) / 16;

    var mcu_y: u32 = 0;
    while (mcu_y < mcus_down) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcus_across) : (mcu_x += 1) {
            const origin_x = mcu_x * 16;
            const origin_y = mcu_y * 16;

            // The four luma blocks, in raster order within the MCU.
            for ([_][2]u32{ .{ 0, 0 }, .{ 8, 0 }, .{ 0, 8 }, .{ 8, 8 } }) |offset| {
                const block = lumaBlock(width, height, pixels, origin_x + offset[0], origin_y + offset[1]);
                try encodeBlock(&bits, &block, &tables.luma, &dc_luma, &ac_luma, &previous_dc[0]);
            }

            // Cb and Cr, each a 2x2 average over the whole MCU.
            const chroma = chromaBlocks(width, height, pixels, origin_x, origin_y);
            try encodeBlock(&bits, &chroma[0], &tables.chroma, &dc_chroma, &ac_chroma, &previous_dc[1]);
            try encodeBlock(&bits, &chroma[1], &tables.chroma, &dc_chroma, &ac_chroma, &previous_dc[2]);
        }
    }

    try bits.flush();
}

/// The pixel at (x, y) with its alpha already multiplied in, clamped to the
/// image -- libjpeg extends the last row and column into the MCU padding, and
/// so do we, because an edge that falls off to black would ring back into the
/// visible pixels.
fn sample(width: u32, height: u32, pixels: ?[]const u8, x: u32, y: u32) [3]f32 {
    const p = pixels orelse return .{ 0, 0, 0 };
    const clamped_x = @min(x, width - 1);
    const clamped_y = @min(y, height - 1);
    const at = (@as(usize, clamped_y) * width + clamped_x) * 4;
    const alpha = @as(f32, @floatFromInt(p[at + 3])) / 255;
    return .{
        @as(f32, @floatFromInt(p[at + 0])) * alpha,
        @as(f32, @floatFromInt(p[at + 1])) * alpha,
        @as(f32, @floatFromInt(p[at + 2])) * alpha,
    };
}

/// JFIF's colour transform is full-range BT.601.
fn luma(rgb: [3]f32) f32 {
    return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
}

fn blueChroma(rgb: [3]f32) f32 {
    return -0.168736 * rgb[0] - 0.331264 * rgb[1] + 0.5 * rgb[2] + 128;
}

fn redChroma(rgb: [3]f32) f32 {
    return 0.5 * rgb[0] - 0.418688 * rgb[1] - 0.081312 * rgb[2] + 128;
}

fn lumaBlock(width: u32, height: u32, pixels: ?[]const u8, at_x: u32, at_y: u32) Block {
    var block: Block = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const rgb = sample(width, height, pixels, at_x + @as(u32, @intCast(col)), at_y + @as(u32, @intCast(row)));
            block[row * 8 + col] = luma(rgb) - 128;
        }
    }
    return block;
}

/// Cb and Cr for one MCU: each output sample is the mean of a 2x2 patch, which
/// is the box filter 4:2:0 subsampling asks for.
fn chromaBlocks(width: u32, height: u32, pixels: ?[]const u8, at_x: u32, at_y: u32) [2]Block {
    var blocks: [2]Block = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            var sum: [3]f32 = .{ 0, 0, 0 };
            for (0..2) |dy| {
                for (0..2) |dx| {
                    const x = at_x + @as(u32, @intCast(col * 2 + dx));
                    const y = at_y + @as(u32, @intCast(row * 2 + dy));
                    const rgb = sample(width, height, pixels, x, y);
                    for (&sum, rgb) |*channel, value| channel.* += value;
                }
            }
            for (&sum) |*channel| channel.* /= 4;
            blocks[0][row * 8 + col] = blueChroma(sum) - 128;
            blocks[1][row * 8 + col] = redChroma(sum) - 128;
        }
    }
    return blocks;
}

/// Forward DCT, quantise, then emit the DC difference and the AC run-lengths.
fn encodeBlock(
    bits: *BitWriter,
    block: *const Block,
    quant: *const [64]u8,
    dc_spec: *const Spec,
    ac_spec: *const Spec,
    previous_dc: *i32,
) !void {
    var coefficients: [64]f32 = undefined;
    forwardDct(block, &coefficients);

    var quantised: [64]i32 = undefined;
    for (0..64) |i| {
        const step: f32 = @floatFromInt(quant[i]);
        quantised[i] = @intFromFloat(@round(coefficients[i] / step));
    }

    // DC is coded as the difference from the last block of the same component.
    const difference = quantised[0] - previous_dc.*;
    previous_dc.* = quantised[0];
    const dc_size = magnitude(difference);
    try bits.writeSymbol(dc_spec, dc_size);
    if (dc_size > 0) {
        try bits.writeAmplitude(difference, dc_size);
    }

    // AC coefficients in zig-zag order, run-length coded against the zeroes.
    var run: u8 = 0;
    for (zigzag[1..]) |natural| {
        const value = quantised[natural];
        if (value == 0) {
            run += 1;
            continue;
        }
        // A run longer than 15 is spelled out in ZRL blocks of 16.
        while (run > 15) {
            try bits.writeSymbol(ac_spec, 0xF0);
            run -= 16;
        }
        const size = magnitude(value);
        try bits.writeSymbol(ac_spec, (run << 4) | size);
        try bits.writeAmplitude(value, size);
        run = 0;
    }
    if (run > 0) {
        try bits.writeSymbol(ac_spec, 0x00); // EOB
    }
}

/// How many bits the amplitude needs -- the "category" the standard indexes its
/// Huffman tables by.
fn magnitude(value: i32) u8 {
    const absolute: u32 = @intCast(@abs(value));
    if (absolute == 0) {
        return 0;
    }
    return @intCast(32 - @clz(absolute));
}

/// The separable 8x8 DCT-II, scaled the way the standard defines it. A real
/// encoder uses a factored transform; at canvas sizes the plain one is not
/// where the time goes, and it keeps the rounding easy to reason about.
fn forwardDct(input: *const Block, output: *[64]f32) void {
    var rows: [64]f32 = undefined;
    for (0..8) |row| {
        for (0..8) |u| {
            var sum: f32 = 0;
            for (0..8) |col| {
                sum += input[row * 8 + col] * cosine[col][u];
            }
            rows[row * 8 + u] = sum * normalise[u];
        }
    }
    for (0..8) |col| {
        for (0..8) |v| {
            var sum: f32 = 0;
            for (0..8) |row| {
                sum += rows[row * 8 + col] * cosine[row][v];
            }
            output[v * 8 + col] = sum * normalise[v];
        }
    }
}

const cosine = blk: {
    @setEvalBranchQuota(10000);
    var table: [8][8]f32 = undefined;
    for (0..8) |x| {
        for (0..8) |u| {
            const angle = (2.0 * @as(f64, @floatFromInt(x)) + 1.0) * @as(f64, @floatFromInt(u)) * std.math.pi / 16.0;
            table[x][u] = @floatCast(@cos(angle));
        }
    }
    break :blk table;
};

const normalise = blk: {
    var table: [8]f32 = undefined;
    for (0..8) |u| {
        table[u] = if (u == 0) @floatCast(0.5 / @sqrt(2.0)) else 0.5;
    }
    break :blk table;
};

// -- Huffman -----------------------------------------------------------------

/// A canonical Huffman table in the form a DHT segment carries it: how many
/// codes there are of each length 1..16, then the symbols in code order.
const Spec = struct {
    counts: [16]u8,
    values: []const u8,
    /// The code and its length for each symbol, indexed by the symbol itself.
    codes: [256]Code,

    const Code = struct { bits: u16 = 0, length: u5 = 0 };

    fn init(counts: [16]u8, values: []const u8) Spec {
        var spec: Spec = .{ .counts = counts, .values = values, .codes = @splat(.{}) };
        var code: u16 = 0;
        var at: usize = 0;
        for (counts, 1..) |count, length| {
            for (0..count) |_| {
                spec.codes[values[at]] = .{ .bits = code, .length = @intCast(length) };
                code += 1;
                at += 1;
            }
            code <<= 1;
        }
        return spec;
    }
};

/// Annex K.3.
const dc_luma = Spec.init(
    .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
    &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
);

/// Annex K.4.
const dc_chroma = Spec.init(
    .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
    &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
);

/// Annex K.5.
const ac_luma = Spec.init(
    .{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D },
    &.{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
        0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
        0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
        0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    },
);

/// Annex K.6.
const ac_chroma = Spec.init(
    .{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 },
    &.{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
        0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
        0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
        0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
        0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
        0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
        0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
        0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    },
);

/// Most-significant-bit-first, with the byte stuffing an entropy-coded segment
/// needs: a literal 0xFF is followed by a zero so a decoder scanning for the
/// next marker does not stop inside the scan.
const BitWriter = struct {
    out: *Writer,
    buffer: u32 = 0,
    held: u5 = 0,

    fn writeBits(self: *BitWriter, bits: u16, length: u5) !void {
        if (length == 0) {
            return;
        }
        self.buffer = (self.buffer << length) | (bits & (@as(u32, 1) << length) - 1);
        self.held += length;
        while (self.held >= 8) {
            self.held -= 8;
            const byte: u8 = @truncate(self.buffer >> self.held);
            try self.out.writeByte(byte);
            if (byte == 0xFF) {
                try self.out.writeByte(0x00);
            }
        }
    }

    fn writeSymbol(self: *BitWriter, spec: *const Spec, symbol: u8) !void {
        const code = spec.codes[symbol];
        std.debug.assert(code.length > 0);
        try self.writeBits(code.bits, code.length);
    }

    /// The signed amplitude in the standard's representation: a positive value
    /// as itself, a negative one as its complement in `size` bits.
    fn writeAmplitude(self: *BitWriter, value: i32, size: u8) !void {
        const encoded: i32 = if (value < 0) value + (@as(i32, 1) << @intCast(size)) - 1 else value;
        try self.writeBits(@truncate(@as(u32, @bitCast(encoded))), @intCast(size));
    }

    /// Pads the last partial byte with ones, which is what a decoder expects to
    /// find between the final coefficient and the EOI marker.
    fn flush(self: *BitWriter) !void {
        if (self.held > 0) {
            try self.writeBits(0xFFFF, 8 - self.held);
        }
    }
};

const testing = std.testing;
const images = @import("../webcodecs/images.zig");

test "jpeg: opens with the same bytes Chrome does" {
    const allocator = testing.allocator;

    const bytes = try encode(allocator, 20, 20, null, default_quality);
    defer allocator.free(bytes);

    // SOI, then the JFIF APP0 -- measured against Chrome 141, whose data URL
    // starts 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQAB'.
    try testing.expectEqualSlices(u8, &.{
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J',  'F',  'I', 'F',
        0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01,
    }, bytes[0..18]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, bytes[bytes.len - 2 ..]);
}

test "jpeg: the frame header carries the real geometry" {
    const allocator = testing.allocator;

    // Sizes that are not a whole number of MCUs, so the padding path runs.
    for ([_][2]u32{ .{ 1, 1 }, .{ 20, 20 }, .{ 17, 3 }, .{ 64, 48 } }) |size| {
        const pixels = try allocator.alloc(u8, @as(usize, size[0]) * size[1] * 4);
        defer allocator.free(pixels);
        for (pixels, 0..) |*byte, i| byte.* = @truncate(i * 7);

        const bytes = try encode(allocator, size[0], size[1], pixels, default_quality);
        defer allocator.free(bytes);

        // Parsed by the same reader ImageDecoder uses, so the segment lengths
        // have to be walkable to reach the SOF at all.
        const image = images.read(.jpeg, bytes, allocator) orelse return error.Unreadable;
        try testing.expectEqual(size[0], image.width);
        try testing.expectEqual(size[1], image.height);
    }
}

test "jpeg: no marker is forged inside the scan" {
    const allocator = testing.allocator;

    // Noise compresses badly, which is what makes long runs of set bits -- and
    // so stray 0xFF bytes -- likely in the entropy-coded segment.
    var pixels: [32 * 32 * 4]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0x5EED);
    random.random().bytes(&pixels);

    const bytes = try encode(allocator, 32, 32, &pixels, 1);
    defer allocator.free(bytes);

    // Walk from the SOS to the end: every 0xFF in there must be stuffed, and
    // the only real marker is the closing EOI.
    const start = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xDA }) orelse return error.NoScan;
    var at = start + 2 + std.mem.readInt(u16, bytes[start + 2 ..][0..2], .big);
    while (at < bytes.len - 2) : (at += 1) {
        if (bytes[at] == 0xFF) {
            try testing.expectEqual(@as(u8, 0x00), bytes[at + 1]);
            at += 1;
        }
    }
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, bytes[bytes.len - 2 ..]);
}

test "jpeg: quality moves the quantisation tables and the size" {
    const allocator = testing.allocator;

    var pixels: [16 * 16 * 4]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(1);
    random.random().bytes(&pixels);

    var previous: usize = 0;
    for ([_]f64{ 0, 0.5, default_quality, 1 }) |quality| {
        const bytes = try encode(allocator, 16, 16, &pixels, quality);
        defer allocator.free(bytes);
        try testing.expect(bytes.len > previous);
        previous = bytes.len;
    }

    // The extremes of libjpeg's scaling: quality 1 leaves every step at 1, and
    // quality 0 clamps up to the same 1-percent scale as quality 0.01.
    const finest: Tables = .forQuality(1);
    try testing.expectEqual(@as(u8, 1), finest.luma[0]);
    try testing.expectEqual(@as(u8, 1), finest.chroma[63]);

    const coarsest: Tables = .forQuality(0);
    try testing.expectEqual(@as(u8, 255), coarsest.luma[0]);
}

test "jpeg: an undrawn canvas is a black image" {
    const allocator = testing.allocator;

    const blank = try encode(allocator, 20, 20, null, default_quality);
    defer allocator.free(blank);

    // Spelling the transparent pixels out has to give the same bytes: alpha
    // multiplies the colour away either route.
    const explicit = [_]u8{0} ** (20 * 20 * 4);
    const same = try encode(allocator, 20, 20, &explicit, default_quality);
    defer allocator.free(same);
    try testing.expectEqualSlices(u8, blank, same);

    // Opaque white is a different image, and a bigger one than flat black.
    const white = [_]u8{255} ** (20 * 20 * 4);
    const lit = try encode(allocator, 20, 20, &white, default_quality);
    defer allocator.free(lit);
    try testing.expect(!std.mem.eql(u8, blank, lit));
}
