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
//   node tools/fingerprint/dump-graphics.mjs --headed
// then transcribed by the generator described in tools/fingerprint/README.md.
//
// Chrome's own answers for the fonts a fingerprinting script actually asks
// about, measured on macOS. `measureText` is the single most-read canvas
// surface — CreepJS, fingerprintjs and every "canvas font" probe call it —
// and unlike the rendered bitmap it needs no rasteriser to reproduce, only
// the numbers. So these are the numbers.
//
// Two facts from the measurement make one table enough per family:
//
//   * advances are exactly linear in font size ('m' is 8.330078125 at 10px
//     and 83.30078125 at 100px), so a 100px table scales;
//   * a string's width is the plain sum of its glyphs' advances, except
//     across a kerning pair. 'mmmmmmmmmmlli', 'Hello, world!' and
//     'Cwm fjordbank glyphs vext quiz' all sum exactly; 'AV' and 'To' do
//     not, and we do not model kerning, so those come out a little wide.
//
// fontBoundingBox is the exception: CoreText quantises it per size (16px
// sans-serif reports an ascent of 14 where scaling 100px's 92 would say 15),
// so it is stored as a swept table for 1..120px and extrapolated above that.
//
// Only U+0020..U+007E is tabulated. Anything else falls back to the family's
// mean advance, which is a guess and marked as one at the call site.

const std = @import("std");

/// One glyph, at a 100px font size. `left` and `right` are the ink bearings
/// TextMetrics reports as actualBoundingBoxLeft / Right: positive `left`
/// means the ink starts to the *left* of the pen, matching the web API's sign.
pub const Glyph = struct {
    advance: f64,
    left: f64,
    right: f64,
    ascent: f64,
    descent: f64,
};

pub const first_codepoint = 32;
pub const last_codepoint = 126;
/// The size every table below is measured at.
pub const basis = 100.0;

/// 100px sans-serif (also Helvetica).
const glyphs_sans_serif = [_]Glyph{
    .{ .advance = 27.783203125, .left = 0.0, .right = 0.0, .ascent = 0.0, .descent = 0.0 }, // space
    .{ .advance = 27.783203125, .left = -11.572265625, .right = 21.484375, .ascent = 71.728515625, .descent = 0.0 }, // !
    .{ .advance = 35.498046875, .left = -4.00390625, .right = 29.58984375, .ascent = 71.728515625, .descent = -43.017578125 }, // "
    .{ .advance = 55.615234375, .left = 0.0, .right = 55.517578125, .ascent = 71.728515625, .descent = 0.0 }, // #
    .{ .advance = 55.615234375, .left = -3.125, .right = 51.806640625, .ascent = 77.5390625, .descent = 11.572265625 }, // $
    .{ .advance = 88.916015625, .left = -3.22265625, .right = 85.15625, .ascent = 69.62890625, .descent = 1.85546875 }, // %
    .{ .advance = 66.69921875, .left = -4.345703125, .right = 64.453125, .ascent = 71.630859375, .descent = 1.66015625 }, // &
    .{ .advance = 19.091796875, .left = -7.6171875, .right = 16.50390625, .ascent = 71.728515625, .descent = -43.017578125 }, // '
    .{ .advance = 33.30078125, .left = -6.93359375, .right = 29.736328125, .ascent = 72.900390625, .descent = 20.41015625 }, // (
    .{ .advance = 33.30078125, .left = -3.3203125, .right = 26.123046875, .ascent = 72.900390625, .descent = 20.41015625 }, // )
    .{ .advance = 38.916015625, .left = -3.80859375, .right = 34.5703125, .ascent = 71.728515625, .descent = -43.017578125 }, // *
    .{ .advance = 58.3984375, .left = -4.4921875, .right = 55.419921875, .ascent = 51.025390625, .descent = 0.0 }, // +
    .{ .advance = 27.783203125, .left = -8.30078125, .right = 18.75, .ascent = 10.64453125, .descent = 14.84375 }, // ,
    .{ .advance = 33.30078125, .left = -4.150390625, .right = 28.662109375, .ascent = 32.373046875, .descent = -23.33984375 }, // -
    .{ .advance = 27.783203125, .left = -8.544921875, .right = 18.75, .ascent = 10.64453125, .descent = 0.0 }, // .
    .{ .advance = 27.783203125, .left = 0.0, .right = 30.17578125, .ascent = 71.728515625, .descent = 0.0 }, // /
    .{ .advance = 55.615234375, .left = -3.125, .right = 51.3671875, .ascent = 69.921875, .descent = 1.904296875 }, // 0
    .{ .advance = 55.615234375, .left = -9.5703125, .right = 35.400390625, .ascent = 69.62890625, .descent = 0.0 }, // 1
    .{ .advance = 55.615234375, .left = -3.125, .right = 51.46484375, .ascent = 70.166015625, .descent = 0.0 }, // 2
    .{ .advance = 55.615234375, .left = -2.392578125, .right = 51.26953125, .ascent = 70.01953125, .descent = 1.904296875 }, // 3
    .{ .advance = 55.615234375, .left = -2.5390625, .right = 52.294921875, .ascent = 70.1171875, .descent = 0.0 }, // 4
    .{ .advance = 55.615234375, .left = -3.22265625, .right = 51.3671875, .ascent = 68.75, .descent = 1.7578125 }, // 5
    .{ .advance = 55.615234375, .left = -3.759765625, .right = 51.708984375, .ascent = 70.21484375, .descent = 1.806640625 }, // 6
    .{ .advance = 55.615234375, .left = -3.662109375, .right = 52.294921875, .ascent = 68.75, .descent = 0.0 }, // 7
    .{ .advance = 55.615234375, .left = -3.22265625, .right = 51.26953125, .ascent = 70.1171875, .descent = 2.001953125 }, // 8
    .{ .advance = 55.615234375, .left = -3.564453125, .right = 50.830078125, .ascent = 70.01953125, .descent = 1.953125 }, // 9
    .{ .advance = 27.783203125, .left = -11.083984375, .right = 21.2890625, .ascent = 51.611328125, .descent = 0.0 }, // :
    .{ .advance = 27.783203125, .left = -11.083984375, .right = 21.484375, .ascent = 51.611328125, .descent = 14.84375 }, // ;
    .{ .advance = 58.3984375, .left = -1.3671875, .right = 58.447265625, .ascent = 51.953125, .descent = 0.927734375 }, // <
    .{ .advance = 58.3984375, .left = -4.4921875, .right = 55.419921875, .ascent = 40.13671875, .descent = -10.83984375 }, // =
    .{ .advance = 58.3984375, .left = -1.3671875, .right = 58.447265625, .ascent = 51.953125, .descent = 0.927734375 }, // >
    .{ .advance = 55.615234375, .left = -7.6171875, .right = 51.123046875, .ascent = 72.65625, .descent = 0.0 }, // ?
    .{ .advance = 101.513671875, .left = -10.986328125, .right = 90.380859375, .ascent = 73.681640625, .descent = 2.099609375 }, // @
    .{ .advance = 66.69921875, .left = -1.46484375, .right = 65.478515625, .ascent = 71.728515625, .descent = 0.0 }, // A
    .{ .advance = 66.69921875, .left = -7.373046875, .right = 62.6953125, .ascent = 71.728515625, .descent = 0.0 }, // B
    .{ .advance = 72.216796875, .left = -4.39453125, .right = 68.017578125, .ascent = 73.681640625, .descent = 1.85546875 }, // C
    .{ .advance = 72.216796875, .left = -8.056640625, .right = 67.333984375, .ascent = 71.728515625, .descent = 0.0 }, // D
    .{ .advance = 66.69921875, .left = -8.544921875, .right = 61.572265625, .ascent = 71.728515625, .descent = 0.0 }, // E
    .{ .advance = 61.083984375, .left = -8.544921875, .right = 58.30078125, .ascent = 71.728515625, .descent = 0.0 }, // F
    .{ .advance = 77.783203125, .left = -4.833984375, .right = 70.361328125, .ascent = 73.583984375, .descent = 1.904296875 }, // G
    .{ .advance = 72.216796875, .left = -7.861328125, .right = 64.794921875, .ascent = 71.728515625, .descent = 0.0 }, // H
    .{ .advance = 27.783203125, .left = -9.814453125, .right = 19.62890625, .ascent = 71.728515625, .descent = 0.0 }, // I
    .{ .advance = 50.0, .left = -1.708984375, .right = 42.822265625, .ascent = 71.728515625, .descent = 1.904296875 }, // J
    .{ .advance = 66.69921875, .left = -7.6171875, .right = 66.30859375, .ascent = 71.728515625, .descent = 0.0 }, // K
    .{ .advance = 55.615234375, .left = -7.6171875, .right = 53.662109375, .ascent = 71.728515625, .descent = 0.0 }, // L
    .{ .advance = 83.30078125, .left = -7.373046875, .right = 76.123046875, .ascent = 71.728515625, .descent = 0.0 }, // M
    .{ .advance = 72.216796875, .left = -7.6171875, .right = 64.55078125, .ascent = 71.728515625, .descent = 0.0 }, // N
    .{ .advance = 77.783203125, .left = -3.90625, .right = 73.828125, .ascent = 73.681640625, .descent = 2.099609375 }, // O
    .{ .advance = 66.69921875, .left = -8.544921875, .right = 62.109375, .ascent = 71.728515625, .descent = 0.0 }, // P
    .{ .advance = 77.783203125, .left = -3.90625, .right = 73.828125, .ascent = 73.681640625, .descent = 5.712890625 }, // Q
    .{ .advance = 72.216796875, .left = -8.7890625, .right = 68.359375, .ascent = 71.728515625, .descent = 0.0 }, // R
    .{ .advance = 66.69921875, .left = -4.6875, .right = 62.01171875, .ascent = 73.53515625, .descent = 2.099609375 }, // S
    .{ .advance = 61.083984375, .left = -1.611328125, .right = 59.814453125, .ascent = 71.728515625, .descent = 0.0 }, // T
    .{ .advance = 72.216796875, .left = -8.30078125, .right = 64.794921875, .ascent = 71.728515625, .descent = 1.904296875 }, // U
    .{ .advance = 66.69921875, .left = -2.5390625, .right = 65.13671875, .ascent = 71.728515625, .descent = 0.0 }, // V
    .{ .advance = 94.384765625, .left = -1.806640625, .right = 93.017578125, .ascent = 71.728515625, .descent = 0.0 }, // W
    .{ .advance = 66.69921875, .left = -2.05078125, .right = 65.0390625, .ascent = 71.728515625, .descent = 0.0 }, // X
    .{ .advance = 66.69921875, .left = -2.05078125, .right = 65.966796875, .ascent = 71.728515625, .descent = 0.0 }, // Y
    .{ .advance = 61.083984375, .left = -2.294921875, .right = 58.7890625, .ascent = 71.728515625, .descent = 0.0 }, // Z
    .{ .advance = 27.783203125, .left = -6.25, .right = 25.0, .ascent = 72.216796875, .descent = 19.677734375 }, // [
    .{ .advance = 27.783203125, .left = 3.369140625, .right = 32.12890625, .ascent = 71.728515625, .descent = 0.0 }, // \
    .{ .advance = 27.783203125, .left = -2.294921875, .right = 21.044921875, .ascent = 72.216796875, .descent = 19.677734375 }, // ]
    .{ .advance = 46.923828125, .left = -5.859375, .right = 47.75390625, .ascent = 71.728515625, .descent = -29.58984375 }, // ^
    .{ .advance = 55.615234375, .left = 0.0, .right = 55.615234375, .ascent = -7.568359375, .descent = 12.5 }, // _
    .{ .advance = 33.30078125, .left = -1.85546875, .right = 21.630859375, .ascent = 73.33984375, .descent = -59.228515625 }, // `
    .{ .advance = 55.615234375, .left = -4.00390625, .right = 53.466796875, .ascent = 53.564453125, .descent = 1.7578125 }, // a
    .{ .advance = 55.615234375, .left = -5.76171875, .right = 51.806640625, .ascent = 71.97265625, .descent = 1.66015625 }, // b
    .{ .advance = 50.0, .left = -2.880859375, .right = 47.65625, .ascent = 53.80859375, .descent = 1.513671875 }, // c
    .{ .advance = 55.615234375, .left = -2.734375, .right = 49.072265625, .ascent = 71.97265625, .descent = 1.85546875 }, // d
    .{ .advance = 55.615234375, .left = -3.515625, .right = 51.26953125, .ascent = 53.466796875, .descent = 1.85546875 }, // e
    .{ .advance = 27.783203125, .left = -1.3671875, .right = 26.123046875, .ascent = 72.75390625, .descent = 0.0 }, // f
    .{ .advance = 55.615234375, .left = -2.978515625, .right = 48.828125, .ascent = 53.22265625, .descent = 22.119140625 }, // g
    .{ .advance = 55.615234375, .left = -6.4453125, .right = 49.072265625, .ascent = 71.97265625, .descent = 0.0 }, // h
    .{ .advance = 22.216796875, .left = -6.4453125, .right = 15.380859375, .ascent = 71.728515625, .descent = 0.0 }, // i
    .{ .advance = 22.216796875, .left = 1.85546875, .right = 15.234375, .ascent = 71.728515625, .descent = 21.09375 }, // j
    .{ .advance = 50.0, .left = -6.25, .right = 49.609375, .ascent = 71.728515625, .descent = 0.0 }, // k
    .{ .advance = 22.216796875, .left = -6.689453125, .right = 15.478515625, .ascent = 71.728515625, .descent = 0.0 }, // l
    .{ .advance = 83.30078125, .left = -6.4453125, .right = 76.806640625, .ascent = 53.466796875, .descent = 0.0 }, // m
    .{ .advance = 55.615234375, .left = -6.4453125, .right = 49.072265625, .ascent = 53.466796875, .descent = 0.0 }, // n
    .{ .advance = 55.615234375, .left = -2.880859375, .right = 51.611328125, .ascent = 53.80859375, .descent = 1.904296875 }, // o
    .{ .advance = 55.615234375, .left = -5.76171875, .right = 51.806640625, .ascent = 53.564453125, .descent = 20.849609375 }, // p
    .{ .advance = 55.615234375, .left = -2.9296875, .right = 49.072265625, .ascent = 53.466796875, .descent = 20.849609375 }, // q
    .{ .advance = 33.30078125, .left = -6.689453125, .right = 32.12890625, .ascent = 53.466796875, .descent = 0.0 }, // r
    .{ .advance = 50.0, .left = -3.22265625, .right = 46.38671875, .ascent = 53.662109375, .descent = 2.001953125 }, // s
    .{ .advance = 27.783203125, .left = -1.123046875, .right = 25.439453125, .ascent = 66.89453125, .descent = 0.830078125 }, // t
    .{ .advance = 55.615234375, .left = -6.25, .right = 48.33984375, .ascent = 52.294921875, .descent = 1.416015625 }, // u
    .{ .advance = 50.0, .left = -0.537109375, .right = 48.92578125, .ascent = 52.294921875, .descent = 0.0 }, // v
    .{ .advance = 72.216796875, .left = -0.87890625, .right = 70.361328125, .ascent = 52.294921875, .descent = 0.0 }, // w
    .{ .advance = 50.0, .left = -0.537109375, .right = 48.486328125, .ascent = 52.294921875, .descent = 0.0 }, // x
    .{ .advance = 50.0, .left = -1.025390625, .right = 48.828125, .ascent = 52.294921875, .descent = 21.435546875 }, // y
    .{ .advance = 50.0, .left = -2.5390625, .right = 46.2890625, .ascent = 52.294921875, .descent = 0.0 }, // z
    .{ .advance = 33.3984375, .left = 2.099609375, .right = 31.25, .ascent = 72.998046875, .descent = 20.41015625 }, // {
    .{ .advance = 25.9765625, .left = -7.03125, .right = 15.380859375, .ascent = 72.75390625, .descent = 0.0 }, // |
    .{ .advance = 33.3984375, .left = -2.05078125, .right = 35.400390625, .ascent = 72.998046875, .descent = 20.41015625 }, // }
    .{ .advance = 58.3984375, .left = -0.87890625, .right = 58.984375, .ascent = 35.400390625, .descent = -15.625 }, // ~
};

/// 100px serif (also ).
const glyphs_serif = [_]Glyph{
    .{ .advance = 25.0, .left = 0.0, .right = 0.0, .ascent = 0.0, .descent = 0.0 }, // space
    .{ .advance = 33.30078125, .left = -12.939453125, .right = 23.828125, .ascent = 67.578125, .descent = 1.07421875 }, // !
    .{ .advance = 40.8203125, .left = -9.1796875, .right = 31.591796875, .ascent = 67.578125, .descent = -38.76953125 }, // "
    .{ .advance = 50.0, .left = 0.0, .right = 49.853515625, .ascent = 66.064453125, .descent = 0.0 }, // #
    .{ .advance = 50.0, .left = -4.39453125, .right = 45.654296875, .ascent = 72.65625, .descent = 8.837890625 }, // $
    .{ .advance = 83.30078125, .left = -6.103515625, .right = 77.24609375, .ascent = 67.578125, .descent = 1.416015625 }, // %
    .{ .advance = 77.783203125, .left = -4.00390625, .right = 74.951171875, .ascent = 67.578125, .descent = 1.46484375 }, // &
    .{ .advance = 18.017578125, .left = -5.029296875, .right = 12.353515625, .ascent = 67.578125, .descent = -38.76953125 }, // '
    .{ .advance = 33.30078125, .left = -4.58984375, .right = 30.419921875, .ascent = 67.578125, .descent = 17.822265625 }, // (
    .{ .advance = 33.30078125, .left = -2.63671875, .right = 28.466796875, .ascent = 67.578125, .descent = 17.822265625 }, // )
    .{ .advance = 50.0, .left = -6.591796875, .right = 42.919921875, .ascent = 67.578125, .descent = -26.46484375 }, // *
    .{ .advance = 56.396484375, .left = -2.978515625, .right = 53.466796875, .ascent = 50.537109375, .descent = 0.0 }, // +
    .{ .advance = 25.0, .left = -10.498046875, .right = 24.51171875, .ascent = 10.15625, .descent = 14.2578125 }, // ,
    .{ .advance = 33.30078125, .left = -3.90625, .right = 28.466796875, .ascent = 25.68359375, .descent = -19.43359375 }, // -
    .{ .advance = 25.0, .left = -10.7421875, .right = 21.826171875, .ascent = 9.912109375, .descent = 1.171875 }, // .
    .{ .advance = 27.783203125, .left = -0.1953125, .right = 27.294921875, .ascent = 67.578125, .descent = 1.66015625 }, // /
    .{ .advance = 50.0, .left = -0.87890625, .right = 46.142578125, .ascent = 67.1875, .descent = 0.927734375 }, // 0
    .{ .advance = 50.0, .left = -11.083984375, .right = 39.306640625, .ascent = 67.08984375, .descent = 0.0 }, // 1
    .{ .advance = 50.0, .left = -2.978515625, .right = 47.412109375, .ascent = 67.3828125, .descent = 0.0 }, // 2
    .{ .advance = 50.0, .left = -4.345703125, .right = 43.26171875, .ascent = 67.67578125, .descent = 0.732421875 }, // 3
    .{ .advance = 50.0, .left = -1.123046875, .right = 47.216796875, .ascent = 67.08984375, .descent = 0.0 }, // 4
    .{ .advance = 50.0, .left = -3.173828125, .right = 43.701171875, .ascent = 68.701171875, .descent = 1.07421875 }, // 5
    .{ .advance = 50.0, .left = -3.41796875, .right = 46.77734375, .ascent = 68.359375, .descent = 1.07421875 }, // 6
    .{ .advance = 50.0, .left = -1.953125, .right = 44.873046875, .ascent = 66.162109375, .descent = 0.927734375 }, // 7
    .{ .advance = 50.0, .left = -5.322265625, .right = 44.140625, .ascent = 67.333984375, .descent = 1.07421875 }, // 8
    .{ .advance = 50.0, .left = -2.978515625, .right = 46.044921875, .ascent = 67.333984375, .descent = 2.34375 }, // 9
    .{ .advance = 27.783203125, .left = -8.056640625, .right = 19.189453125, .ascent = 45.947265625, .descent = 0.830078125 }, // :
    .{ .advance = 27.783203125, .left = -8.30078125, .right = 22.314453125, .ascent = 45.947265625, .descent = 14.2578125 }, // ;
    .{ .advance = 56.396484375, .left = -2.978515625, .right = 53.466796875, .ascent = 51.3671875, .descent = 0.830078125 }, // <
    .{ .advance = 56.396484375, .left = -2.978515625, .right = 53.466796875, .ascent = 38.76953125, .descent = -11.767578125 }, // =
    .{ .advance = 56.396484375, .left = -0.87890625, .right = 55.322265625, .ascent = 51.3671875, .descent = 0.830078125 }, // >
    .{ .advance = 44.384765625, .left = -6.591796875, .right = 41.455078125, .ascent = 67.529296875, .descent = 0.927734375 }, // ?
    .{ .advance = 92.08984375, .left = -8.984375, .right = 82.275390625, .ascent = 67.578125, .descent = 1.416015625 }, // @
    .{ .advance = 72.216796875, .left = -1.46484375, .right = 70.556640625, .ascent = 67.333984375, .descent = 0.0 }, // A
    .{ .advance = 66.69921875, .left = -1.708984375, .right = 59.228515625, .ascent = 66.162109375, .descent = 0.0 }, // B
    .{ .advance = 66.69921875, .left = -2.490234375, .right = 63.28125, .ascent = 67.333984375, .descent = 1.66015625 }, // C
    .{ .advance = 72.216796875, .left = -1.611328125, .right = 68.603515625, .ascent = 66.162109375, .descent = 0.0 }, // D
    .{ .advance = 61.083984375, .left = -1.123046875, .right = 59.716796875, .ascent = 66.162109375, .descent = 0.0 }, // E
    .{ .advance = 55.615234375, .left = -1.123046875, .right = 54.736328125, .ascent = 66.162109375, .descent = 0.0 }, // F
    .{ .advance = 72.216796875, .left = -2.392578125, .right = 70.361328125, .ascent = 67.333984375, .descent = 1.416015625 }, // G
    .{ .advance = 72.216796875, .left = -1.611328125, .right = 69.873046875, .ascent = 66.162109375, .descent = 0.0 }, // H
    .{ .advance = 33.30078125, .left = -1.611328125, .right = 31.201171875, .ascent = 66.162109375, .descent = 0.0 }, // I
    .{ .advance = 38.916015625, .left = -1.025390625, .right = 37.01171875, .ascent = 66.162109375, .descent = 1.171875 }, // J
    .{ .advance = 72.216796875, .left = -1.806640625, .right = 70.80078125, .ascent = 66.162109375, .descent = 0.0 }, // K
    .{ .advance = 61.083984375, .left = -1.123046875, .right = 59.814453125, .ascent = 66.162109375, .descent = 0.0 }, // L
    .{ .advance = 88.916015625, .left = -1.123046875, .right = 86.328125, .ascent = 66.162109375, .descent = 0.0 }, // M
    .{ .advance = 72.216796875, .left = -1.123046875, .right = 70.703125, .ascent = 66.162109375, .descent = 1.171875 }, // N
    .{ .advance = 72.216796875, .left = -2.978515625, .right = 68.505859375, .ascent = 67.578125, .descent = 1.416015625 }, // O
    .{ .advance = 55.615234375, .left = -1.611328125, .right = 54.150390625, .ascent = 66.162109375, .descent = 0.0 }, // P
    .{ .advance = 72.216796875, .left = -2.978515625, .right = 69.775390625, .ascent = 67.578125, .descent = 17.822265625 }, // Q
    .{ .advance = 66.69921875, .left = -1.123046875, .right = 65.380859375, .ascent = 66.162109375, .descent = 0.0 }, // R
    .{ .advance = 55.615234375, .left = -4.150390625, .right = 49.072265625, .ascent = 67.578125, .descent = 1.318359375 }, // S
    .{ .advance = 61.083984375, .left = -1.3671875, .right = 58.984375, .ascent = 66.162109375, .descent = 0.0 }, // T
    .{ .advance = 72.216796875, .left = -1.3671875, .right = 70.458984375, .ascent = 66.162109375, .descent = 1.416015625 }, // U
    .{ .advance = 72.216796875, .left = -1.611328125, .right = 69.62890625, .ascent = 66.162109375, .descent = 1.171875 }, // V
    .{ .advance = 94.384765625, .left = -0.439453125, .right = 93.1640625, .ascent = 66.162109375, .descent = 1.171875 }, // W
    .{ .advance = 72.216796875, .left = -1.025390625, .right = 70.361328125, .ascent = 66.162109375, .descent = 0.0 }, // X
    .{ .advance = 72.216796875, .left = -2.197265625, .right = 70.21484375, .ascent = 66.162109375, .descent = 0.0 }, // Y
    .{ .advance = 61.083984375, .left = -0.68359375, .right = 59.716796875, .ascent = 66.162109375, .descent = 0.0 }, // Z
    .{ .advance = 33.30078125, .left = -8.7890625, .right = 29.833984375, .ascent = 66.162109375, .descent = 15.771484375 }, // [
    .{ .advance = 27.783203125, .left = 3.125, .right = 30.859375, .ascent = 67.578125, .descent = 0.0 }, // \
    .{ .advance = 33.30078125, .left = -3.3203125, .right = 24.4140625, .ascent = 66.162109375, .descent = 15.771484375 }, // ]
    .{ .advance = 46.923828125, .left = -3.22265625, .right = 43.603515625, .ascent = 67.578125, .descent = -25.341796875 }, // ^
    .{ .advance = 50.0, .left = 0.0, .right = 49.951171875, .ascent = -7.568359375, .descent = 12.5 }, // _
    .{ .advance = 33.30078125, .left = 0.9765625, .right = 21.484375, .ascent = 67.87109375, .descent = -50.68359375 }, // `
    .{ .advance = 44.384765625, .left = -3.662109375, .right = 44.189453125, .ascent = 46.2890625, .descent = 0.732421875 }, // a
    .{ .advance = 50.0, .left = -0.341796875, .right = 46.728515625, .ascent = 68.1640625, .descent = 0.927734375 }, // b
    .{ .advance = 44.384765625, .left = -2.294921875, .right = 41.162109375, .ascent = 46.044921875, .descent = 0.927734375 }, // c
    .{ .advance = 50.0, .left = -2.392578125, .right = 49.072265625, .ascent = 68.26171875, .descent = 0.927734375 }, // d
    .{ .advance = 44.384765625, .left = -1.953125, .right = 42.08984375, .ascent = 45.80078125, .descent = 1.171875 }, // e
    .{ .advance = 33.30078125, .left = -1.953125, .right = 38.28125, .ascent = 68.26171875, .descent = 0.0 }, // f
    .{ .advance = 50.0, .left = -2.63671875, .right = 46.97265625, .ascent = 46.044921875, .descent = 21.77734375 }, // g
    .{ .advance = 50.0, .left = -0.87890625, .right = 48.681640625, .ascent = 68.1640625, .descent = 0.0 }, // h
    .{ .advance = 27.783203125, .left = -1.953125, .right = 25.68359375, .ascent = 68.1640625, .descent = 0.0 }, // i
    .{ .advance = 27.783203125, .left = 5.76171875, .right = 21.142578125, .ascent = 68.1640625, .descent = 21.875 }, // j
    .{ .advance = 50.0, .left = -0.1953125, .right = 49.951171875, .ascent = 68.017578125, .descent = 0.0 }, // k
    .{ .advance = 27.783203125, .left = -1.806640625, .right = 25.68359375, .ascent = 68.5546875, .descent = 0.0 }, // l
    .{ .advance = 77.783203125, .left = -1.611328125, .right = 77.5390625, .ascent = 45.703125, .descent = 0.0 }, // m
    .{ .advance = 50.0, .left = -1.611328125, .right = 48.583984375, .ascent = 45.99609375, .descent = 0.0 }, // n
    .{ .advance = 50.0, .left = -2.5390625, .right = 46.97265625, .ascent = 45.80078125, .descent = 1.513671875 }, // o
    .{ .advance = 50.0, .left = -0.439453125, .right = 46.97265625, .ascent = 46.142578125, .descent = 21.77734375 }, // p
    .{ .advance = 50.0, .left = -2.392578125, .right = 48.828125, .ascent = 46.044921875, .descent = 21.77734375 }, // q
    .{ .advance = 33.30078125, .left = -0.439453125, .right = 33.642578125, .ascent = 46.044921875, .descent = 0.0 }, // r
    .{ .advance = 38.916015625, .left = -5.078125, .right = 34.814453125, .ascent = 46.142578125, .descent = 0.927734375 }, // s
    .{ .advance = 27.783203125, .left = -1.220703125, .right = 27.880859375, .ascent = 57.861328125, .descent = 0.927734375 }, // t
    .{ .advance = 50.0, .left = -0.87890625, .right = 47.900390625, .ascent = 45.21484375, .descent = 0.927734375 }, // u
    .{ .advance = 50.0, .left = -1.806640625, .right = 47.65625, .ascent = 45.361328125, .descent = 0.927734375 }, // v
    .{ .advance = 72.216796875, .left = -2.05078125, .right = 69.43359375, .ascent = 45.361328125, .descent = 0.9765625 }, // w
    .{ .advance = 50.0, .left = -1.708984375, .right = 47.900390625, .ascent = 44.873046875, .descent = 0.0 }, // x
    .{ .advance = 50.0, .left = -1.3671875, .right = 47.412109375, .ascent = 44.873046875, .descent = 21.875 }, // y
    .{ .advance = 44.384765625, .left = -2.5390625, .right = 41.748046875, .ascent = 44.873046875, .descent = 0.0 }, // z
    .{ .advance = 47.998046875, .left = -6.201171875, .right = 41.748046875, .ascent = 67.578125, .descent = 17.822265625 }, // {
    .{ .advance = 20.01953125, .left = -6.591796875, .right = 13.37890625, .ascent = 68.26171875, .descent = 0.0 }, // |
    .{ .advance = 47.998046875, .left = -6.201171875, .right = 41.748046875, .ascent = 67.578125, .descent = 17.822265625 }, // }
    .{ .advance = 54.1015625, .left = -1.3671875, .right = 52.63671875, .ascent = 34.716796875, .descent = -15.966796875 }, // ~
};

/// 100px monospace (also ).
const glyphs_monospace = [_]Glyph{
    .{ .advance = 60.205078125, .left = 0.0, .right = 0.0, .ascent = 0.0, .descent = 0.0 }, // space
    .{ .advance = 60.205078125, .left = -25.1953125, .right = 38.037109375, .ascent = 72.900390625, .descent = 0.0 }, // !
    .{ .advance = 60.205078125, .left = -9.1796875, .right = 46.142578125, .ascent = 75.537109375, .descent = -45.654296875 }, // "
    .{ .advance = 60.205078125, .left = -0.09765625, .right = 60.693359375, .ascent = 71.533203125, .descent = 0.0 }, // #
    .{ .advance = 60.205078125, .left = -9.27734375, .right = 54.39453125, .ascent = 75.9765625, .descent = 14.697265625 }, // $
    .{ .advance = 60.205078125, .left = -1.611328125, .right = 58.7890625, .ascent = 69.921875, .descent = 0.0 }, // %
    .{ .advance = 60.205078125, .left = -2.783203125, .right = 59.619140625, .ascent = 74.21875, .descent = 1.416015625 }, // &
    .{ .advance = 60.205078125, .left = -25.29296875, .right = 36.23046875, .ascent = 76.07421875, .descent = -45.654296875 }, // '
    .{ .advance = 60.205078125, .left = -19.3359375, .right = 41.748046875, .ascent = 80.76171875, .descent = 8.30078125 }, // (
    .{ .advance = 60.205078125, .left = -16.9921875, .right = 39.404296875, .ascent = 80.76171875, .descent = 8.30078125 }, // )
    .{ .advance = 60.205078125, .left = -2.9296875, .right = 57.568359375, .ascent = 59.033203125, .descent = -2.587890625 }, // *
    .{ .advance = 60.205078125, .left = -5.2734375, .right = 56.884765625, .ascent = 57.51953125, .descent = -6.005859375 }, // +
    .{ .advance = 60.205078125, .left = -16.2109375, .right = 36.81640625, .ascent = 17.626953125, .descent = 16.40625 }, // ,
    .{ .advance = 60.205078125, .left = -4.98046875, .right = 56.73828125, .ascent = 35.3515625, .descent = -27.099609375 }, // -
    .{ .advance = 60.205078125, .left = -18.994140625, .right = 36.181640625, .ascent = 19.7265625, .descent = 0.0 }, // .
    .{ .advance = 60.205078125, .left = -4.98046875, .right = 52.685546875, .ascent = 72.900390625, .descent = 9.27734375 }, // /
    .{ .advance = 60.205078125, .left = -6.494140625, .right = 53.7109375, .ascent = 73.974609375, .descent = 1.416015625 }, // 0
    .{ .advance = 60.205078125, .left = -10.15625, .right = 53.41796875, .ascent = 72.65625, .descent = 0.0 }, // 1
    .{ .advance = 60.205078125, .left = -7.421875, .right = 51.708984375, .ascent = 74.21875, .descent = 0.0 }, // 2
    .{ .advance = 60.205078125, .left = -6.689453125, .right = 52.685546875, .ascent = 74.21875, .descent = 1.416015625 }, // 3
    .{ .advance = 60.205078125, .left = -4.98046875, .right = 55.419921875, .ascent = 72.900390625, .descent = 0.0 }, // 4
    .{ .advance = 60.205078125, .left = -6.982421875, .right = 52.197265625, .ascent = 72.900390625, .descent = 1.416015625 }, // 5
    .{ .advance = 60.205078125, .left = -6.494140625, .right = 53.7109375, .ascent = 74.21875, .descent = 1.416015625 }, // 6
    .{ .advance = 60.205078125, .left = -6.787109375, .right = 52.685546875, .ascent = 72.900390625, .descent = 0.0 }, // 7
    .{ .advance = 60.205078125, .left = -6.396484375, .right = 53.80859375, .ascent = 74.21875, .descent = 1.416015625 }, // 8
    .{ .advance = 60.205078125, .left = -6.201171875, .right = 53.41796875, .ascent = 74.21875, .descent = 1.416015625 }, // 9
    .{ .advance = 60.205078125, .left = -20.947265625, .right = 36.181640625, .ascent = 54.638671875, .descent = 0.0 }, // :
    .{ .advance = 60.205078125, .left = -16.748046875, .right = 36.81640625, .ascent = 54.638671875, .descent = 13.96484375 }, // ;
    .{ .advance = 60.205078125, .left = -4.296875, .right = 55.908203125, .ascent = 55.810546875, .descent = -6.884765625 }, // <
    .{ .advance = 60.205078125, .left = -4.296875, .right = 55.908203125, .ascent = 47.412109375, .descent = -16.162109375 }, // =
    .{ .advance = 60.205078125, .left = -4.296875, .right = 55.908203125, .ascent = 55.810546875, .descent = -6.884765625 }, // >
    .{ .advance = 60.205078125, .left = -11.9140625, .right = 50.78125, .ascent = 74.21875, .descent = 0.0 }, // ?
    .{ .advance = 60.205078125, .left = -1.318359375, .right = 57.51953125, .ascent = 68.115234375, .descent = 16.162109375 }, // @
    .{ .advance = 60.205078125, .left = -1.806640625, .right = 58.3984375, .ascent = 72.900390625, .descent = 0.0 }, // A
    .{ .advance = 60.205078125, .left = -8.10546875, .right = 55.517578125, .ascent = 72.900390625, .descent = 0.0 }, // B
    .{ .advance = 60.205078125, .left = -6.787109375, .right = 52.392578125, .ascent = 74.21875, .descent = 1.416015625 }, // C
    .{ .advance = 60.205078125, .left = -6.689453125, .right = 54.00390625, .ascent = 72.900390625, .descent = 0.0 }, // D
    .{ .advance = 60.205078125, .left = -9.619140625, .right = 53.80859375, .ascent = 72.900390625, .descent = 0.0 }, // E
    .{ .advance = 60.205078125, .left = -11.376953125, .right = 54.296875, .ascent = 72.900390625, .descent = 0.0 }, // F
    .{ .advance = 60.205078125, .left = -4.98046875, .right = 53.90625, .ascent = 74.21875, .descent = 1.416015625 }, // G
    .{ .advance = 60.205078125, .left = -6.689453125, .right = 53.515625, .ascent = 72.900390625, .descent = 0.0 }, // H
    .{ .advance = 60.205078125, .left = -9.814453125, .right = 50.29296875, .ascent = 72.900390625, .descent = 0.0 }, // I
    .{ .advance = 60.205078125, .left = -5.322265625, .right = 46.6796875, .ascent = 72.900390625, .descent = 1.416015625 }, // J
    .{ .advance = 60.205078125, .left = -6.689453125, .right = 59.814453125, .ascent = 72.900390625, .descent = 0.0 }, // K
    .{ .advance = 60.205078125, .left = -10.498046875, .right = 55.615234375, .ascent = 72.900390625, .descent = 0.0 }, // L
    .{ .advance = 60.205078125, .left = -1.7578125, .right = 53.466796875, .ascent = 72.65625, .descent = 0.0 }, // M
    .{ .advance = 60.205078125, .left = -0.927734375, .right = 53.41796875, .ascent = 72.65625, .descent = 0.0 }, // N
    .{ .advance = 60.205078125, .left = -5.712890625, .right = 54.4921875, .ascent = 74.21875, .descent = 1.416015625 }, // O
    .{ .advance = 60.205078125, .left = -9.619140625, .right = 55.712890625, .ascent = 72.900390625, .descent = 0.0 }, // P
    .{ .advance = 60.205078125, .left = -5.712890625, .right = 54.4921875, .ascent = 74.21875, .descent = 13.18359375 }, // Q
    .{ .advance = 60.205078125, .left = -6.982421875, .right = 60.205078125, .ascent = 72.900390625, .descent = 0.0 }, // R
    .{ .advance = 60.205078125, .left = -6.787109375, .right = 53.61328125, .ascent = 74.21875, .descent = 1.416015625 }, // S
    .{ .advance = 60.205078125, .left = -2.294921875, .right = 57.91015625, .ascent = 72.900390625, .descent = 0.0 }, // T
    .{ .advance = 60.205078125, .left = -7.177734375, .right = 52.978515625, .ascent = 72.900390625, .descent = 1.416015625 }, // U
    .{ .advance = 60.205078125, .left = -2.783203125, .right = 57.421875, .ascent = 72.900390625, .descent = 0.0 }, // V
    .{ .advance = 60.205078125, .left = 0.0, .right = 60.205078125, .ascent = 72.900390625, .descent = 0.0 }, // W
    .{ .advance = 60.205078125, .left = -0.87890625, .right = 59.27734375, .ascent = 72.900390625, .descent = 0.0 }, // X
    .{ .advance = 60.205078125, .left = -1.806640625, .right = 58.3984375, .ascent = 72.900390625, .descent = 0.0 }, // Y
    .{ .advance = 60.205078125, .left = -7.6171875, .right = 57.080078125, .ascent = 72.900390625, .descent = 0.0 }, // Z
    .{ .advance = 60.205078125, .left = -27.490234375, .right = 48.193359375, .ascent = 80.859375, .descent = 8.30078125 }, // [
    .{ .advance = 60.205078125, .left = -4.98046875, .right = 52.685546875, .ascent = 72.900390625, .descent = 9.27734375 }, // \
    .{ .advance = 60.205078125, .left = -14.453125, .right = 35.15625, .ascent = 80.859375, .descent = 8.30078125 }, // ]
    .{ .advance = 60.205078125, .left = -1.7578125, .right = 58.3984375, .ascent = 72.65625, .descent = -43.5546875 }, // ^
    .{ .advance = 60.205078125, .left = 0.0, .right = 59.765625, .ascent = -9.27734375, .descent = 17.578125 }, // _
    .{ .advance = 60.205078125, .left = -13.623046875, .right = 37.01171875, .ascent = 79.98046875, .descent = -61.62109375 }, // `
    .{ .advance = 60.205078125, .left = -6.494140625, .right = 51.708984375, .ascent = 56.005859375, .descent = 1.416015625 }, // a
    .{ .advance = 60.205078125, .left = -9.423828125, .right = 54.296875, .ascent = 75.9765625, .descent = 1.416015625 }, // b
    .{ .advance = 60.205078125, .left = -9.521484375, .right = 51.806640625, .ascent = 56.005859375, .descent = 1.416015625 }, // c
    .{ .advance = 60.205078125, .left = -6.005859375, .right = 50.87890625, .ascent = 75.9765625, .descent = 1.416015625 }, // d
    .{ .advance = 60.205078125, .left = -6.005859375, .right = 54.6875, .ascent = 56.005859375, .descent = 1.416015625 }, // e
    .{ .advance = 60.205078125, .left = -9.521484375, .right = 51.904296875, .ascent = 75.9765625, .descent = 0.0 }, // f
    .{ .advance = 60.205078125, .left = -6.005859375, .right = 50.87890625, .ascent = 56.005859375, .descent = 21.484375 }, // g
    .{ .advance = 60.205078125, .left = -9.521484375, .right = 51.318359375, .ascent = 75.9765625, .descent = 0.0 }, // h
    .{ .advance = 60.205078125, .left = -11.62109375, .right = 56.25, .ascent = 75.732421875, .descent = 0.0 }, // i
    .{ .advance = 60.205078125, .left = -9.08203125, .right = 38.28125, .ascent = 75.9765625, .descent = 20.80078125 }, // j
    .{ .advance = 60.205078125, .left = -11.5234375, .right = 58.69140625, .ascent = 75.9765625, .descent = 0.0 }, // k
    .{ .advance = 60.205078125, .left = -11.71875, .right = 54.39453125, .ascent = 76.26953125, .descent = 0.0 }, // l
    .{ .advance = 60.205078125, .left = -5.322265625, .right = 55.419921875, .ascent = 56.005859375, .descent = 0.0 }, // m
    .{ .advance = 60.205078125, .left = -9.521484375, .right = 51.318359375, .ascent = 56.005859375, .descent = 0.0 }, // n
    .{ .advance = 60.205078125, .left = -6.689453125, .right = 53.515625, .ascent = 56.005859375, .descent = 1.416015625 }, // o
    .{ .advance = 60.205078125, .left = -9.27734375, .right = 54.1015625, .ascent = 56.005859375, .descent = 20.80078125 }, // p
    .{ .advance = 60.205078125, .left = -6.689453125, .right = 51.513671875, .ascent = 55.810546875, .descent = 20.99609375 }, // q
    .{ .advance = 60.205078125, .left = -17.67578125, .right = 56.396484375, .ascent = 56.005859375, .descent = 0.0 }, // r
    .{ .advance = 60.205078125, .left = -10.400390625, .right = 50.29296875, .ascent = 56.005859375, .descent = 1.416015625 }, // s
    .{ .advance = 60.205078125, .left = -6.396484375, .right = 50.390625, .ascent = 70.21484375, .descent = 0.0 }, // t
    .{ .advance = 60.205078125, .left = -9.521484375, .right = 51.318359375, .ascent = 54.58984375, .descent = 1.416015625 }, // u
    .{ .advance = 60.205078125, .left = -4.8828125, .right = 55.322265625, .ascent = 54.6875, .descent = 0.0 }, // v
    .{ .advance = 60.205078125, .left = 0.0, .right = 60.205078125, .ascent = 54.6875, .descent = 0.0 }, // w
    .{ .advance = 60.205078125, .left = -3.7109375, .right = 56.494140625, .ascent = 54.6875, .descent = 0.0 }, // x
    .{ .advance = 60.205078125, .left = -5.078125, .right = 56.298828125, .ascent = 54.6875, .descent = 20.80078125 }, // y
    .{ .advance = 60.205078125, .left = -9.912109375, .right = 50.78125, .ascent = 54.78515625, .descent = 0.0 }, // z
    .{ .advance = 60.205078125, .left = -8.59375, .right = 50.390625, .ascent = 81.8359375, .descent = 9.521484375 }, // {
    .{ .advance = 60.205078125, .left = -27.83203125, .right = 36.23046875, .ascent = 76.416015625, .descent = 23.583984375 }, // |
    .{ .advance = 60.205078125, .left = -10.693359375, .right = 52.490234375, .ascent = 81.8359375, .descent = 9.521484375 }, // }
    .{ .advance = 60.205078125, .left = -0.634765625, .right = 59.423828125, .ascent = 45.703125, .descent = -17.431640625 }, // ~
};

/// 100px Arial (also ).
const glyphs_arial = [_]Glyph{
    .{ .advance = 27.783203125, .left = 0.0, .right = 0.0, .ascent = 0.0, .descent = 0.0 }, // space
    .{ .advance = 27.783203125, .left = -8.59375, .right = 19.482421875, .ascent = 71.58203125, .descent = 0.0 }, // !
    .{ .advance = 35.498046875, .left = -4.58984375, .right = 30.810546875, .ascent = 71.58203125, .descent = -46.240234375 }, // "
    .{ .advance = 55.615234375, .left = -1.025390625, .right = 54.345703125, .ascent = 72.802734375, .descent = 1.220703125 }, // #
    .{ .advance = 55.615234375, .left = -3.564453125, .right = 50.927734375, .ascent = 78.173828125, .descent = 10.302734375 }, // $
    .{ .advance = 88.916015625, .left = -5.810546875, .right = 82.763671875, .ascent = 72.802734375, .descent = 2.63671875 }, // %
    .{ .advance = 66.69921875, .left = -4.296875, .right = 64.404296875, .ascent = 72.802734375, .descent = 1.66015625 }, // &
    .{ .advance = 19.091796875, .left = -4.39453125, .right = 14.404296875, .ascent = 71.58203125, .descent = -46.240234375 }, // '
    .{ .advance = 33.30078125, .left = -6.0546875, .right = 29.6875, .ascent = 72.802734375, .descent = 21.044921875 }, // (
    .{ .advance = 33.30078125, .left = -6.0546875, .right = 29.6875, .ascent = 72.802734375, .descent = 21.044921875 }, // )
    .{ .advance = 38.916015625, .left = -3.125, .right = 35.400390625, .ascent = 72.802734375, .descent = -42.333984375 }, // *
    .{ .advance = 58.3984375, .left = -5.56640625, .right = 52.83203125, .ascent = 58.88671875, .descent = -11.572265625 }, // +
    .{ .advance = 27.783203125, .left = -8.30078125, .right = 18.896484375, .ascent = 10.009765625, .descent = 14.16015625 }, // ,
    .{ .advance = 33.30078125, .left = -3.173828125, .right = 30.17578125, .ascent = 30.322265625, .descent = -21.484375 }, // -
    .{ .advance = 27.783203125, .left = -9.08203125, .right = 19.091796875, .ascent = 10.009765625, .descent = 0.0 }, // .
    .{ .advance = 27.783203125, .left = 0.0, .right = 27.783203125, .ascent = 72.802734375, .descent = 1.220703125 }, // /
    .{ .advance = 55.615234375, .left = -4.150390625, .right = 50.830078125, .ascent = 71.875, .descent = 1.220703125 }, // 0
    .{ .advance = 55.615234375, .left = -10.888671875, .right = 37.255859375, .ascent = 71.875, .descent = 0.0 }, // 1
    .{ .advance = 55.615234375, .left = -2.9296875, .right = 50.341796875, .ascent = 71.875, .descent = 0.0 }, // 2
    .{ .advance = 55.615234375, .left = -4.19921875, .right = 51.07421875, .ascent = 71.875, .descent = 1.26953125 }, // 3
    .{ .advance = 55.615234375, .left = -1.26953125, .right = 50.78125, .ascent = 71.58203125, .descent = 0.0 }, // 4
    .{ .advance = 55.615234375, .left = -4.150390625, .right = 51.611328125, .ascent = 70.60546875, .descent = 1.220703125 }, // 5
    .{ .advance = 55.615234375, .left = -3.759765625, .right = 51.025390625, .ascent = 71.875, .descent = 1.220703125 }, // 6
    .{ .advance = 55.615234375, .left = -4.736328125, .right = 51.07421875, .ascent = 70.654296875, .descent = 0.0 }, // 7
    .{ .advance = 55.615234375, .left = -4.052734375, .right = 51.220703125, .ascent = 71.875, .descent = 1.220703125 }, // 8
    .{ .advance = 55.615234375, .left = -4.150390625, .right = 51.220703125, .ascent = 71.875, .descent = 1.220703125 }, // 9
    .{ .advance = 27.783203125, .left = -9.033203125, .right = 19.04296875, .ascent = 51.85546875, .descent = 0.0 }, // :
    .{ .advance = 27.783203125, .left = -8.30078125, .right = 18.896484375, .ascent = 51.85546875, .descent = 14.16015625 }, // ;
    .{ .advance = 58.3984375, .left = -5.46875, .right = 52.880859375, .ascent = 59.521484375, .descent = -11.03515625 }, // <
    .{ .advance = 58.3984375, .left = -5.56640625, .right = 52.83203125, .ascent = 50.29296875, .descent = -20.361328125 }, // =
    .{ .advance = 58.3984375, .left = -5.46875, .right = 52.880859375, .ascent = 59.521484375, .descent = -11.03515625 }, // >
    .{ .advance = 55.615234375, .left = -4.39453125, .right = 50.5859375, .ascent = 72.802734375, .descent = 0.0 }, // ?
    .{ .advance = 101.513671875, .left = -5.419921875, .right = 97.900390625, .ascent = 72.900390625, .descent = 21.044921875 }, // @
    .{ .advance = 66.69921875, .left = 0.146484375, .right = 66.845703125, .ascent = 71.58203125, .descent = 0.0 }, // A
    .{ .advance = 66.69921875, .left = -7.32421875, .right = 61.376953125, .ascent = 71.58203125, .descent = 0.0 }, // B
    .{ .advance = 72.216796875, .left = -4.98046875, .right = 68.26171875, .ascent = 72.802734375, .descent = 1.220703125 }, // C
    .{ .advance = 72.216796875, .left = -7.71484375, .right = 66.89453125, .ascent = 71.58203125, .descent = 0.0 }, // D
    .{ .advance = 66.69921875, .left = -7.91015625, .right = 61.328125, .ascent = 71.58203125, .descent = 0.0 }, // E
    .{ .advance = 61.083984375, .left = -8.203125, .right = 56.494140625, .ascent = 71.58203125, .descent = 0.0 }, // F
    .{ .advance = 77.783203125, .left = -5.322265625, .right = 71.533203125, .ascent = 72.802734375, .descent = 1.220703125 }, // G
    .{ .advance = 72.216796875, .left = -8.0078125, .right = 64.16015625, .ascent = 71.58203125, .descent = 0.0 }, // H
    .{ .advance = 27.783203125, .left = -9.326171875, .right = 18.798828125, .ascent = 71.58203125, .descent = 0.0 }, // I
    .{ .advance = 50.0, .left = -2.685546875, .right = 42.236328125, .ascent = 71.58203125, .descent = 1.220703125 }, // J
    .{ .advance = 66.69921875, .left = -7.32421875, .right = 66.50390625, .ascent = 71.58203125, .descent = 0.0 }, // K
    .{ .advance = 55.615234375, .left = -7.32421875, .right = 52.05078125, .ascent = 71.58203125, .descent = 0.0 }, // L
    .{ .advance = 83.30078125, .left = -7.421875, .right = 75.732421875, .ascent = 71.58203125, .descent = 0.0 }, // M
    .{ .advance = 72.216796875, .left = -7.6171875, .right = 64.013671875, .ascent = 71.58203125, .descent = 0.0 }, // N
    .{ .advance = 77.783203125, .left = -4.833984375, .right = 73.291015625, .ascent = 72.8515625, .descent = 1.220703125 }, // O
    .{ .advance = 66.69921875, .left = -7.71484375, .right = 62.353515625, .ascent = 71.58203125, .descent = 0.0 }, // P
    .{ .advance = 77.783203125, .left = -4.296875, .right = 74.12109375, .ascent = 72.8515625, .descent = 5.56640625 }, // Q
    .{ .advance = 72.216796875, .left = -7.861328125, .right = 70.947265625, .ascent = 71.58203125, .descent = 0.0 }, // R
    .{ .advance = 66.69921875, .left = -4.4921875, .right = 61.474609375, .ascent = 72.802734375, .descent = 1.220703125 }, // S
    .{ .advance = 61.083984375, .left = -2.34375, .right = 59.08203125, .ascent = 71.58203125, .descent = 0.0 }, // T
    .{ .advance = 72.216796875, .left = -7.861328125, .right = 64.16015625, .ascent = 71.58203125, .descent = 1.220703125 }, // U
    .{ .advance = 66.69921875, .left = -0.439453125, .right = 65.91796875, .ascent = 71.58203125, .descent = 0.0 }, // V
    .{ .advance = 94.384765625, .left = -1.220703125, .right = 93.26171875, .ascent = 71.58203125, .descent = 0.0 }, // W
    .{ .advance = 66.69921875, .left = -0.439453125, .right = 66.064453125, .ascent = 71.58203125, .descent = 0.0 }, // X
    .{ .advance = 66.69921875, .left = -0.29296875, .right = 65.91796875, .ascent = 71.58203125, .descent = 0.0 }, // Y
    .{ .advance = 61.083984375, .left = -2.001953125, .right = 58.59375, .ascent = 71.58203125, .descent = 0.0 }, // Z
    .{ .advance = 27.783203125, .left = -6.787109375, .right = 26.171875, .ascent = 71.58203125, .descent = 19.873046875 }, // [
    .{ .advance = 27.783203125, .left = 0.0, .right = 27.783203125, .ascent = 72.802734375, .descent = 1.220703125 }, // \
    .{ .advance = 27.783203125, .left = -1.904296875, .right = 21.2890625, .ascent = 71.58203125, .descent = 19.873046875 }, // ]
    .{ .advance = 46.923828125, .left = -2.63671875, .right = 44.287109375, .ascent = 72.802734375, .descent = -33.69140625 }, // ^
    .{ .advance = 55.615234375, .left = 1.513671875, .right = 56.73828125, .ascent = -13.525390625, .descent = 19.873046875 }, // _
    .{ .advance = 33.30078125, .left = -4.345703125, .right = 22.705078125, .ascent = 71.97265625, .descent = -58.30078125 }, // `
    .{ .advance = 55.615234375, .left = -3.61328125, .right = 51.3671875, .ascent = 53.02734375, .descent = 1.171875 }, // a
    .{ .advance = 55.615234375, .left = -6.54296875, .right = 51.513671875, .ascent = 71.58203125, .descent = 1.171875 }, // b
    .{ .advance = 50.0, .left = -3.90625, .right = 49.072265625, .ascent = 53.02734375, .descent = 1.171875 }, // c
    .{ .advance = 55.615234375, .left = -3.41796875, .right = 48.388671875, .ascent = 71.58203125, .descent = 1.171875 }, // d
    .{ .advance = 55.615234375, .left = -3.662109375, .right = 51.46484375, .ascent = 53.02734375, .descent = 1.171875 }, // e
    .{ .advance = 27.783203125, .left = -0.927734375, .right = 31.25, .ascent = 72.802734375, .descent = 0.0 }, // f
    .{ .advance = 55.615234375, .left = -3.22265625, .right = 48.92578125, .ascent = 53.02734375, .descent = 21.044921875 }, // g
    .{ .advance = 55.615234375, .left = -6.591796875, .right = 48.828125, .ascent = 71.58203125, .descent = 0.0 }, // h
    .{ .advance = 22.216796875, .left = -6.640625, .right = 15.4296875, .ascent = 71.58203125, .descent = 0.0 }, // i
    .{ .advance = 22.216796875, .left = 4.58984375, .right = 15.33203125, .ascent = 71.58203125, .descent = 21.044921875 }, // j
    .{ .advance = 50.0, .left = -6.640625, .right = 49.609375, .ascent = 71.58203125, .descent = 0.0 }, // k
    .{ .advance = 22.216796875, .left = -6.396484375, .right = 15.185546875, .ascent = 71.58203125, .descent = 0.0 }, // l
    .{ .advance = 83.30078125, .left = -6.591796875, .right = 76.85546875, .ascent = 53.02734375, .descent = 0.0 }, // m
    .{ .advance = 55.615234375, .left = -6.591796875, .right = 48.73046875, .ascent = 53.02734375, .descent = 0.0 }, // n
    .{ .advance = 55.615234375, .left = -3.3203125, .right = 51.904296875, .ascent = 53.02734375, .descent = 1.171875 }, // o
    .{ .advance = 55.615234375, .left = -6.591796875, .right = 51.611328125, .ascent = 53.02734375, .descent = 19.873046875 }, // p
    .{ .advance = 55.615234375, .left = -3.515625, .right = 48.4375, .ascent = 53.02734375, .descent = 19.873046875 }, // q
    .{ .advance = 33.30078125, .left = -6.494140625, .right = 34.66796875, .ascent = 53.02734375, .descent = 0.0 }, // r
    .{ .advance = 50.0, .left = -3.076171875, .right = 46.142578125, .ascent = 53.02734375, .descent = 1.171875 }, // s
    .{ .advance = 27.783203125, .left = -1.7578125, .right = 27.05078125, .ascent = 69.970703125, .descent = 0.68359375 }, // t
    .{ .advance = 55.615234375, .left = -6.396484375, .right = 48.4375, .ascent = 51.85546875, .descent = 1.171875 }, // u
    .{ .advance = 50.0, .left = -1.26953125, .right = 48.828125, .ascent = 51.85546875, .descent = 0.0 }, // v
    .{ .advance = 72.216796875, .left = -0.29296875, .right = 71.435546875, .ascent = 51.85546875, .descent = 0.0 }, // w
    .{ .advance = 50.0, .left = -0.732421875, .right = 49.267578125, .ascent = 51.85546875, .descent = 0.0 }, // x
    .{ .advance = 50.0, .left = -1.611328125, .right = 49.12109375, .ascent = 51.85546875, .descent = 21.044921875 }, // y
    .{ .advance = 50.0, .left = -1.953125, .right = 47.8515625, .ascent = 51.85546875, .descent = 0.0 }, // z
    .{ .advance = 33.3984375, .left = -2.783203125, .right = 31.0546875, .ascent = 72.802734375, .descent = 21.044921875 }, // {
    .{ .advance = 25.9765625, .left = -9.1796875, .right = 16.845703125, .ascent = 72.802734375, .descent = 21.044921875 }, // |
    .{ .advance = 33.3984375, .left = -2.294921875, .right = 30.56640625, .ascent = 72.802734375, .descent = 21.044921875 }, // }
    .{ .advance = 58.3984375, .left = -4.248046875, .right = 54.19921875, .ascent = 43.212890625, .descent = -27.197265625 }, // ~
};

/// 100px Times New Roman (also ).
const glyphs_times_new_roman = [_]Glyph{
    .{ .advance = 25.0, .left = 0.0, .right = 0.0, .ascent = 0.0, .descent = 0.0 }, // space
    .{ .advance = 33.30078125, .left = -11.1328125, .right = 22.16796875, .ascent = 67.724609375, .descent = 1.3671875 }, // !
    .{ .advance = 40.8203125, .left = -6.494140625, .right = 34.1796875, .ascent = 67.724609375, .descent = -39.208984375 }, // "
    .{ .advance = 50.0, .left = -1.806640625, .right = 48.193359375, .ascent = 67.724609375, .descent = 1.3671875 }, // #
    .{ .advance = 50.0, .left = -5.2734375, .right = 44.970703125, .ascent = 71.77734375, .descent = 7.6171875 }, // $
    .{ .advance = 83.30078125, .left = -3.515625, .right = 79.833984375, .ascent = 67.724609375, .descent = 2.734375 }, // %
    .{ .advance = 77.783203125, .left = -3.662109375, .right = 74.755859375, .ascent = 67.724609375, .descent = 1.513671875 }, // &
    .{ .advance = 18.017578125, .left = -3.955078125, .right = 13.76953125, .ascent = 67.724609375, .descent = -39.208984375 }, // '
    .{ .advance = 33.30078125, .left = -4.1015625, .right = 31.0546875, .ascent = 69.43359375, .descent = 21.38671875 }, // (
    .{ .advance = 33.30078125, .left = -2.24609375, .right = 29.19921875, .ascent = 69.43359375, .descent = 21.38671875 }, // )
    .{ .advance = 50.0, .left = -7.080078125, .right = 42.96875, .ascent = 69.43359375, .descent = -28.90625 }, // *
    .{ .advance = 56.396484375, .left = -1.806640625, .right = 54.443359375, .ascent = 59.521484375, .descent = -6.884765625 }, // +
    .{ .advance = 25.0, .left = -5.37109375, .right = 19.921875, .ascent = 9.765625, .descent = 16.650390625 }, // ,
    .{ .advance = 33.30078125, .left = -4.052734375, .right = 29.296875, .ascent = 26.123046875, .descent = -18.75 }, // -
    .{ .advance = 25.0, .left = -7.080078125, .right = 17.919921875, .ascent = 9.47265625, .descent = 1.3671875 }, // .
    .{ .advance = 27.783203125, .left = -0.146484375, .right = 28.02734375, .ascent = 69.43359375, .descent = 1.3671875 }, // /
    .{ .advance = 50.0, .left = -3.61328125, .right = 46.435546875, .ascent = 67.578125, .descent = 1.171875 }, // 0
    .{ .advance = 50.0, .left = -11.71875, .right = 37.79296875, .ascent = 67.578125, .descent = 0.0 }, // 1
    .{ .advance = 50.0, .left = -2.1484375, .right = 45.849609375, .ascent = 67.578125, .descent = 0.0 }, // 2
    .{ .advance = 50.0, .left = -4.052734375, .right = 41.69921875, .ascent = 67.578125, .descent = 1.171875 }, // 3
    .{ .advance = 50.0, .left = -1.5625, .right = 46.533203125, .ascent = 67.578125, .descent = 0.0 }, // 4
    .{ .advance = 50.0, .left = -4.78515625, .right = 43.408203125, .ascent = 66.2109375, .descent = 1.171875 }, // 5
    .{ .advance = 50.0, .left = -4.296875, .right = 46.142578125, .ascent = 67.578125, .descent = 1.171875 }, // 6
    .{ .advance = 50.0, .left = -3.7109375, .right = 45.556640625, .ascent = 66.2109375, .descent = 1.3671875 }, // 7
    .{ .advance = 50.0, .left = -6.0546875, .right = 44.23828125, .ascent = 67.578125, .descent = 1.171875 }, // 8
    .{ .advance = 50.0, .left = -3.955078125, .right = 45.703125, .ascent = 67.578125, .descent = 1.3671875 }, // 9
    .{ .advance = 27.783203125, .left = -8.59375, .right = 19.53125, .ascent = 46.09375, .descent = 1.3671875 }, // :
    .{ .advance = 27.783203125, .left = -6.93359375, .right = 21.484375, .ascent = 46.142578125, .descent = 16.650390625 }, // ;
    .{ .advance = 56.396484375, .left = -1.806640625, .right = 54.345703125, .ascent = 57.2265625, .descent = -9.130859375 }, // <
    .{ .advance = 56.396484375, .left = -1.806640625, .right = 54.4921875, .ascent = 43.115234375, .descent = -23.193359375 }, // =
    .{ .advance = 56.396484375, .left = -1.806640625, .right = 54.345703125, .ascent = 57.2265625, .descent = -9.130859375 }, // >
    .{ .advance = 44.384765625, .left = -4.4921875, .right = 40.380859375, .ascent = 67.724609375, .descent = 1.318359375 }, // ?
    .{ .advance = 92.08984375, .left = -4.736328125, .right = 89.6484375, .ascent = 69.43359375, .descent = 21.58203125 }, // @
    .{ .advance = 72.216796875, .left = -0.78125, .right = 71.09375, .ascent = 67.724609375, .descent = 0.0 }, // A
    .{ .advance = 66.69921875, .left = -1.66015625, .right = 61.23046875, .ascent = 66.2109375, .descent = 0.0 }, // B
    .{ .advance = 66.69921875, .left = -3.61328125, .right = 63.232421875, .ascent = 67.724609375, .descent = 1.513671875 }, // C
    .{ .advance = 72.216796875, .left = -1.708984375, .right = 68.408203125, .ascent = 66.2109375, .descent = 0.0 }, // D
    .{ .advance = 61.083984375, .left = -2.05078125, .right = 58.7890625, .ascent = 66.2109375, .descent = 0.0 }, // E
    .{ .advance = 55.615234375, .left = -1.611328125, .right = 51.513671875, .ascent = 66.2109375, .descent = 0.0 }, // F
    .{ .advance = 72.216796875, .left = -3.515625, .right = 70.80078125, .ascent = 67.724609375, .descent = 1.513671875 }, // G
    .{ .advance = 72.216796875, .left = -1.708984375, .right = 70.166015625, .ascent = 66.2109375, .descent = 0.0 }, // H
    .{ .advance = 33.30078125, .left = -2.490234375, .right = 30.859375, .ascent = 66.2109375, .descent = 0.0 }, // I
    .{ .advance = 38.916015625, .left = -2.05078125, .right = 38.330078125, .ascent = 66.2109375, .descent = 1.513671875 }, // J
    .{ .advance = 72.216796875, .left = -1.66015625, .right = 73.046875, .ascent = 66.2109375, .descent = 0.0 }, // K
    .{ .advance = 61.083984375, .left = -2.001953125, .right = 58.935546875, .ascent = 66.2109375, .descent = 0.0 }, // L
    .{ .advance = 88.916015625, .left = -1.66015625, .right = 86.81640625, .ascent = 66.2109375, .descent = 0.0 }, // M
    .{ .advance = 72.216796875, .left = 1.318359375, .right = 70.80078125, .ascent = 66.2109375, .descent = 1.07421875 }, // N
    .{ .advance = 72.216796875, .left = -3.515625, .right = 68.359375, .ascent = 67.724609375, .descent = 1.513671875 }, // O
    .{ .advance = 55.615234375, .left = -1.66015625, .right = 52.099609375, .ascent = 66.2109375, .descent = 0.0 }, // P
    .{ .advance = 72.216796875, .left = -3.515625, .right = 68.408203125, .ascent = 67.724609375, .descent = 19.580078125 }, // Q
    .{ .advance = 66.69921875, .left = -1.708984375, .right = 67.578125, .ascent = 66.2109375, .descent = 0.0 }, // R
    .{ .advance = 55.615234375, .left = -6.25, .right = 50.244140625, .ascent = 67.724609375, .descent = 1.513671875 }, // S
    .{ .advance = 61.083984375, .left = -3.02734375, .right = 58.59375, .ascent = 66.2109375, .descent = 0.0 }, // T
    .{ .advance = 72.216796875, .left = -0.537109375, .right = 71.142578125, .ascent = 66.2109375, .descent = 1.5625 }, // U
    .{ .advance = 72.216796875, .left = -0.87890625, .right = 70.99609375, .ascent = 66.2109375, .descent = 1.513671875 }, // V
    .{ .advance = 94.384765625, .left = -1.318359375, .right = 93.603515625, .ascent = 66.2109375, .descent = 1.513671875 }, // W
    .{ .advance = 72.216796875, .left = -0.732421875, .right = 71.044921875, .ascent = 66.2109375, .descent = 0.0 }, // X
    .{ .advance = 72.216796875, .left = -0.927734375, .right = 70.751953125, .ascent = 66.2109375, .descent = 0.0 }, // Y
    .{ .advance = 61.083984375, .left = -1.26953125, .right = 58.30078125, .ascent = 66.2109375, .descent = 0.0 }, // Z
    .{ .advance = 33.30078125, .left = -8.203125, .right = 29.6875, .ascent = 67.724609375, .descent = 19.82421875 }, // [
    .{ .advance = 27.783203125, .left = -0.146484375, .right = 27.978515625, .ascent = 69.43359375, .descent = 1.3671875 }, // \
    .{ .advance = 33.30078125, .left = -3.662109375, .right = 25.146484375, .ascent = 67.724609375, .descent = 19.873046875 }, // ]
    .{ .advance = 46.923828125, .left = -1.806640625, .right = 45.068359375, .ascent = 67.578125, .descent = -32.568359375 }, // ^
    .{ .advance = 50.0, .left = 0.830078125, .right = 50.87890625, .ascent = -17.48046875, .descent = 21.58203125 }, // _
    .{ .advance = 33.30078125, .left = -5.76171875, .right = 21.826171875, .ascent = 67.87109375, .descent = -51.025390625 }, // `
    .{ .advance = 44.384765625, .left = -3.564453125, .right = 44.189453125, .ascent = 46.044921875, .descent = 0.927734375 }, // a
    .{ .advance = 50.0, .left = 0.244140625, .right = 46.533203125, .ascent = 69.43359375, .descent = 1.3671875 }, // b
    .{ .advance = 44.384765625, .left = -3.41796875, .right = 41.11328125, .ascent = 46.044921875, .descent = 1.3671875 }, // c
    .{ .advance = 50.0, .left = -3.3203125, .right = 50.244140625, .ascent = 69.43359375, .descent = 1.3671875 }, // d
    .{ .advance = 44.384765625, .left = -3.7109375, .right = 41.552734375, .ascent = 46.09375, .descent = 1.3671875 }, // e
    .{ .advance = 33.30078125, .left = -3.857421875, .right = 43.45703125, .ascent = 69.3359375, .descent = 0.0 }, // f
    .{ .advance = 50.0, .left = -2.978515625, .right = 48.193359375, .ascent = 46.044921875, .descent = 21.58203125 }, // g
    .{ .advance = 50.0, .left = -0.634765625, .right = 49.365234375, .ascent = 69.43359375, .descent = 0.0 }, // h
    .{ .advance = 27.783203125, .left = -2.9296875, .right = 25.341796875, .ascent = 69.43359375, .descent = 0.0 }, // i
    .{ .advance = 27.783203125, .left = 7.666015625, .right = 19.482421875, .ascent = 69.482421875, .descent = 21.58203125 }, // j
    .{ .advance = 50.0, .left = -0.830078125, .right = 50.5859375, .ascent = 69.43359375, .descent = 0.0 }, // k
    .{ .advance = 27.783203125, .left = -2.978515625, .right = 25.732421875, .ascent = 69.43359375, .descent = 0.0 }, // l
    .{ .advance = 77.783203125, .left = -0.830078125, .right = 77.34375, .ascent = 46.044921875, .descent = 0.0 }, // m
    .{ .advance = 50.0, .left = -0.5859375, .right = 49.560546875, .ascent = 46.044921875, .descent = 0.0 }, // n
    .{ .advance = 50.0, .left = -3.369140625, .right = 46.533203125, .ascent = 46.044921875, .descent = 1.3671875 }, // o
    .{ .advance = 50.0, .left = 0.341796875, .right = 46.58203125, .ascent = 46.044921875, .descent = 21.38671875 }, // p
    .{ .advance = 50.0, .left = -3.3203125, .right = 50.0, .ascent = 46.044921875, .descent = 21.38671875 }, // q
    .{ .advance = 33.30078125, .left = -0.634765625, .right = 33.935546875, .ascent = 46.044921875, .descent = 0.0 }, // r
    .{ .advance = 38.916015625, .left = -4.8828125, .right = 35.400390625, .ascent = 46.044921875, .descent = 1.3671875 }, // s
    .{ .advance = 27.783203125, .left = -0.9765625, .right = 27.9296875, .ascent = 59.423828125, .descent = 0.732421875 }, // t
    .{ .advance = 50.0, .left = -0.09765625, .right = 49.853515625, .ascent = 44.7265625, .descent = 1.3671875 }, // u
    .{ .advance = 50.0, .left = -0.830078125, .right = 49.072265625, .ascent = 44.7265625, .descent = 1.3671875 }, // v
    .{ .advance = 72.216796875, .left = -0.634765625, .right = 71.2890625, .ascent = 44.7265625, .descent = 1.3671875 }, // w
    .{ .advance = 50.0, .left = -1.318359375, .right = 48.779296875, .ascent = 44.7265625, .descent = 0.0 }, // x
    .{ .advance = 50.0, .left = -0.5859375, .right = 49.4140625, .ascent = 44.7265625, .descent = 21.58203125 }, // y
    .{ .advance = 44.384765625, .left = -2.001953125, .right = 42.7734375, .ascent = 44.7265625, .descent = 0.0 }, // z
    .{ .advance = 47.998046875, .left = -13.818359375, .right = 41.064453125, .ascent = 69.43359375, .descent = 21.58203125 }, // {
    .{ .advance = 20.01953125, .left = -7.861328125, .right = 11.9140625, .ascent = 69.43359375, .descent = 21.58203125 }, // |
    .{ .advance = 47.998046875, .left = -8.642578125, .right = 35.888671875, .ascent = 69.43359375, .descent = 21.58203125 }, // }
    .{ .advance = 54.1015625, .left = -0.9765625, .right = 53.076171875, .ascent = 33.10546875, .descent = -19.43359375 }, // ~
};

/// 100px Courier New (also ).
const glyphs_courier_new = [_]Glyph{
    .{ .advance = 60.009765625, .left = 0.0, .right = 0.0, .ascent = 0.0, .descent = 0.0 }, // space
    .{ .advance = 60.009765625, .left = -23.974609375, .right = 36.03515625, .ascent = 62.744140625, .descent = 1.46484375 }, // !
    .{ .advance = 60.009765625, .left = -12.98828125, .right = 46.923828125, .ascent = 60.25390625, .descent = -33.154296875 }, // "
    .{ .advance = 60.009765625, .left = -9.130859375, .right = 50.830078125, .ascent = 65.72265625, .descent = 6.34765625 }, // #
    .{ .advance = 60.009765625, .left = -11.1328125, .right = 48.828125, .ascent = 66.455078125, .descent = 9.326171875 }, // $
    .{ .advance = 60.009765625, .left = -9.130859375, .right = 50.9765625, .ascent = 62.255859375, .descent = 1.171875 }, // %
    .{ .advance = 60.009765625, .left = -12.40234375, .right = 49.90234375, .ascent = 52.63671875, .descent = 1.611328125 }, // &
    .{ .advance = 60.009765625, .left = -23.486328125, .right = 36.474609375, .ascent = 61.279296875, .descent = -31.982421875 }, // '
    .{ .advance = 60.009765625, .left = -29.541015625, .right = 46.044921875, .ascent = 61.279296875, .descent = 12.6953125 }, // (
    .{ .advance = 60.009765625, .left = -14.697265625, .right = 31.201171875, .ascent = 61.279296875, .descent = 12.6953125 }, // )
    .{ .advance = 60.009765625, .left = -11.03515625, .right = 48.583984375, .ascent = 61.279296875, .descent = -25.341796875 }, // *
    .{ .advance = 60.009765625, .left = -7.03125, .right = 52.978515625, .ascent = 53.759765625, .descent = -3.271484375 }, // +
    .{ .advance = 60.009765625, .left = -14.599609375, .right = 35.205078125, .ascent = 14.74609375, .descent = 14.6484375 }, // ,
    .{ .advance = 60.009765625, .left = -9.08203125, .right = 50.927734375, .ascent = 31.201171875, .descent = -25.341796875 }, // -
    .{ .advance = 60.009765625, .left = -22.509765625, .right = 37.548828125, .ascent = 11.767578125, .descent = 1.46484375 }, // .
    .{ .advance = 60.009765625, .left = -11.23046875, .right = 48.92578125, .ascent = 67.822265625, .descent = 8.251953125 }, // /
    .{ .advance = 60.009765625, .left = -11.181640625, .right = 48.828125, .ascent = 62.744140625, .descent = 1.46484375 }, // 0
    .{ .advance = 60.009765625, .left = -11.1328125, .right = 48.828125, .ascent = 62.109375, .descent = 0.0 }, // 1
    .{ .advance = 60.009765625, .left = -8.349609375, .right = 47.998046875, .ascent = 62.744140625, .descent = 0.0 }, // 2
    .{ .advance = 60.009765625, .left = -9.521484375, .right = 50.048828125, .ascent = 62.744140625, .descent = 1.46484375 }, // 3
    .{ .advance = 60.009765625, .left = -10.44921875, .right = 47.998046875, .ascent = 61.279296875, .descent = 0.0 }, // 4
    .{ .advance = 60.009765625, .left = -9.5703125, .right = 50.048828125, .ascent = 61.279296875, .descent = 1.46484375 }, // 5
    .{ .advance = 60.009765625, .left = -13.37890625, .right = 51.26953125, .ascent = 62.744140625, .descent = 1.46484375 }, // 6
    .{ .advance = 60.009765625, .left = -10.302734375, .right = 47.94921875, .ascent = 61.279296875, .descent = 0.09765625 }, // 7
    .{ .advance = 60.009765625, .left = -11.279296875, .right = 48.779296875, .ascent = 62.744140625, .descent = 1.46484375 }, // 8
    .{ .advance = 60.009765625, .left = -13.427734375, .right = 51.123046875, .ascent = 62.744140625, .descent = 1.46484375 }, // 9
    .{ .advance = 60.009765625, .left = -22.509765625, .right = 37.548828125, .ascent = 42.28515625, .descent = 1.46484375 }, // :
    .{ .advance = 60.009765625, .left = -15.234375, .right = 37.5, .ascent = 42.28515625, .descent = 10.44921875 }, // ;
    .{ .advance = 60.009765625, .left = -4.78515625, .right = 52.783203125, .ascent = 53.759765625, .descent = -3.173828125 }, // <
    .{ .advance = 60.009765625, .left = -4.931640625, .right = 55.126953125, .ascent = 38.0859375, .descent = -19.23828125 }, // =
    .{ .advance = 60.009765625, .left = -7.2265625, .right = 55.224609375, .ascent = 53.759765625, .descent = -3.173828125 }, // >
    .{ .advance = 60.009765625, .left = -13.427734375, .right = 48.974609375, .ascent = 58.59375, .descent = 1.46484375 }, // ?
    .{ .advance = 60.009765625, .left = -10.498046875, .right = 47.998046875, .ascent = 63.330078125, .descent = 6.34765625 }, // @
    .{ .advance = 60.009765625, .left = -0.830078125, .right = 59.326171875, .ascent = 57.12890625, .descent = 0.0 }, // A
    .{ .advance = 60.009765625, .left = -4.248046875, .right = 54.345703125, .ascent = 57.12890625, .descent = 0.0 }, // B
    .{ .advance = 60.009765625, .left = -6.201171875, .right = 53.7109375, .ascent = 58.447265625, .descent = 1.611328125 }, // C
    .{ .advance = 60.009765625, .left = -7.71484375, .right = 55.76171875, .ascent = 57.12890625, .descent = 0.0 }, // D
    .{ .advance = 60.009765625, .left = -4.296875, .right = 52.294921875, .ascent = 57.12890625, .descent = 0.0 }, // E
    .{ .advance = 60.009765625, .left = -7.763671875, .right = 55.6640625, .ascent = 57.12890625, .descent = 0.0 }, // F
    .{ .advance = 60.009765625, .left = -6.25, .right = 56.494140625, .ascent = 58.447265625, .descent = 1.611328125 }, // G
    .{ .advance = 60.009765625, .left = -5.224609375, .right = 55.419921875, .ascent = 57.12890625, .descent = 0.0 }, // H
    .{ .advance = 60.009765625, .left = -11.181640625, .right = 48.876953125, .ascent = 57.12890625, .descent = 0.0 }, // I
    .{ .advance = 60.009765625, .left = -8.349609375, .right = 58.544921875, .ascent = 57.12890625, .descent = 1.611328125 }, // J
    .{ .advance = 60.009765625, .left = -4.345703125, .right = 57.470703125, .ascent = 57.12890625, .descent = 0.0 }, // K
    .{ .advance = 60.009765625, .left = -6.25, .right = 54.296875, .ascent = 57.12890625, .descent = 0.0 }, // L
    .{ .advance = 60.009765625, .left = -1.171875, .right = 59.375, .ascent = 57.12890625, .descent = 0.0 }, // M
    .{ .advance = 60.009765625, .left = -2.24609375, .right = 56.298828125, .ascent = 57.12890625, .descent = 0.0 }, // N
    .{ .advance = 60.009765625, .left = -5.078125, .right = 55.078125, .ascent = 58.447265625, .descent = 1.611328125 }, // O
    .{ .advance = 60.009765625, .left = -8.740234375, .right = 54.443359375, .ascent = 57.12890625, .descent = 0.0 }, // P
    .{ .advance = 60.009765625, .left = -5.078125, .right = 55.078125, .ascent = 58.447265625, .descent = 11.669921875 }, // Q
    .{ .advance = 60.009765625, .left = -4.296875, .right = 59.27734375, .ascent = 57.12890625, .descent = 0.0 }, // R
    .{ .advance = 60.009765625, .left = -9.033203125, .right = 50.9765625, .ascent = 58.447265625, .descent = 1.611328125 }, // S
    .{ .advance = 60.009765625, .left = -6.982421875, .right = 52.9296875, .ascent = 57.12890625, .descent = 0.0 }, // T
    .{ .advance = 60.009765625, .left = -4.052734375, .right = 56.0546875, .ascent = 57.12890625, .descent = 1.611328125 }, // U
    .{ .advance = 60.009765625, .left = -0.78125, .right = 59.27734375, .ascent = 57.12890625, .descent = 0.0 }, // V
    .{ .advance = 60.009765625, .left = -1.806640625, .right = 58.0078125, .ascent = 57.12890625, .descent = 0.0 }, // W
    .{ .advance = 60.009765625, .left = -3.90625, .right = 56.25, .ascent = 57.12890625, .descent = 0.0 }, // X
    .{ .advance = 60.009765625, .left = -4.833984375, .right = 55.078125, .ascent = 57.12890625, .descent = 0.0 }, // Y
    .{ .advance = 60.009765625, .left = -10.400390625, .right = 49.90234375, .ascent = 57.12890625, .descent = 0.0 }, // Z
    .{ .advance = 60.009765625, .left = -27.978515625, .right = 44.775390625, .ascent = 61.279296875, .descent = 12.646484375 }, // [
    .{ .advance = 60.009765625, .left = -11.083984375, .right = 48.779296875, .ascent = 67.529296875, .descent = 8.544921875 }, // \
    .{ .advance = 60.009765625, .left = -15.4296875, .right = 32.2265625, .ascent = 61.279296875, .descent = 12.646484375 }, // ]
    .{ .advance = 60.009765625, .left = -11.1328125, .right = 48.876953125, .ascent = 62.451171875, .descent = -35.9375 }, // ^
    .{ .advance = 60.009765625, .left = 0.0, .right = 60.009765625, .ascent = -23.291015625, .descent = 27.392578125 }, // _
    .{ .advance = 60.009765625, .left = -21.6796875, .right = 38.37890625, .ascent = 64.892578125, .descent = -49.853515625 }, // `
    .{ .advance = 60.009765625, .left = -7.03125, .right = 54.19921875, .ascent = 43.75, .descent = 1.611328125 }, // a
    .{ .advance = 60.009765625, .left = -2.197265625, .right = 54.248046875, .ascent = 61.279296875, .descent = 1.611328125 }, // b
    .{ .advance = 60.009765625, .left = -8.349609375, .right = 53.662109375, .ascent = 43.75, .descent = 1.611328125 }, // c
    .{ .advance = 60.009765625, .left = -6.15234375, .right = 58.349609375, .ascent = 61.279296875, .descent = 1.611328125 }, // d
    .{ .advance = 60.009765625, .left = -6.25, .right = 52.294921875, .ascent = 43.75, .descent = 1.611328125 }, // e
    .{ .advance = 60.009765625, .left = -10.498046875, .right = 54.39453125, .ascent = 61.279296875, .descent = 0.0 }, // f
    .{ .advance = 60.009765625, .left = -6.103515625, .right = 56.15234375, .ascent = 43.75, .descent = 18.84765625 }, // g
    .{ .advance = 60.009765625, .left = -4.150390625, .right = 55.322265625, .ascent = 61.279296875, .descent = 0.0 }, // h
    .{ .advance = 60.009765625, .left = -9.228515625, .right = 51.07421875, .ascent = 63.330078125, .descent = 0.0 }, // i
    .{ .advance = 60.009765625, .left = -8.7890625, .right = 40.234375, .ascent = 63.330078125, .descent = 18.84765625 }, // j
    .{ .advance = 60.009765625, .left = -9.326171875, .right = 57.177734375, .ascent = 61.279296875, .descent = 0.0 }, // k
    .{ .advance = 60.009765625, .left = -9.130859375, .right = 50.9765625, .ascent = 61.279296875, .descent = 0.0 }, // l
    .{ .advance = 60.009765625, .left = -1.025390625, .right = 59.326171875, .ascent = 43.75, .descent = 0.0 }, // m
    .{ .advance = 60.009765625, .left = -5.2734375, .right = 54.248046875, .ascent = 43.75, .descent = 0.0 }, // n
    .{ .advance = 60.009765625, .left = -7.080078125, .right = 52.9296875, .ascent = 43.75, .descent = 1.611328125 }, // o
    .{ .advance = 60.009765625, .left = -2.197265625, .right = 54.248046875, .ascent = 43.75, .descent = 18.84765625 }, // p
    .{ .advance = 60.009765625, .left = -6.25, .right = 58.30078125, .ascent = 43.75, .descent = 18.84765625 }, // q
    .{ .advance = 60.009765625, .left = -8.349609375, .right = 54.39453125, .ascent = 43.310546875, .descent = 0.0 }, // r
    .{ .advance = 60.009765625, .left = -10.107421875, .right = 49.90234375, .ascent = 43.75, .descent = 1.611328125 }, // s
    .{ .advance = 60.009765625, .left = -7.12890625, .right = 52.880859375, .ascent = 57.12890625, .descent = 1.611328125 }, // t
    .{ .advance = 60.009765625, .left = -4.443359375, .right = 54.345703125, .ascent = 42.28515625, .descent = 1.611328125 }, // u
    .{ .advance = 60.009765625, .left = -2.880859375, .right = 57.12890625, .ascent = 42.28515625, .descent = 0.0 }, // v
    .{ .advance = 60.009765625, .left = -2.734375, .right = 57.2265625, .ascent = 42.28515625, .descent = 0.048828125 }, // w
    .{ .advance = 60.009765625, .left = -4.931640625, .right = 55.17578125, .ascent = 42.28515625, .descent = 0.0 }, // x
    .{ .advance = 60.009765625, .left = -7.275390625, .right = 57.421875, .ascent = 42.28515625, .descent = 18.84765625 }, // y
    .{ .advance = 60.009765625, .left = -11.572265625, .right = 49.12109375, .ascent = 42.28515625, .descent = 0.0 }, // z
    .{ .advance = 60.009765625, .left = -19.775390625, .right = 40.33203125, .ascent = 61.279296875, .descent = 12.646484375 }, // {
    .{ .advance = 60.009765625, .left = -27.9296875, .right = 32.080078125, .ascent = 61.279296875, .descent = 12.646484375 }, // |
    .{ .advance = 60.009765625, .left = -19.7265625, .right = 40.283203125, .ascent = 61.279296875, .descent = 12.6953125 }, // }
    .{ .advance = 60.009765625, .left = -9.130859375, .right = 50.927734375, .ascent = 35.888671875, .descent = -21.09375 }, // ~
};

/// sans-serif: fontBoundingBoxAscent for 1..120px.
const ascents_sans_serif = [_]f64{
    0.77001953125, 1.5400390625, 2.31005859375, 4.0,   5.0,   6.0,   6.0,   7.0,   8.0,   10.0,
    10.0,          11.0,         12.0,          13.0,  14.0,  14.0,  16.0,  17.0,  18.0,  18.0,
    19.0,          20.0,         21.0,          22.0,  23.0,  24.0,  25.0,  26.0,  26.0,  28.0,
    29.0,          30.0,         30.0,          31.0,  32.0,  33.0,  34.0,  35.0,  36.0,  37.0,
    38.0,          38.0,         39.0,          41.0,  42.0,  42.0,  43.0,  44.0,  45.0,  47.0,
    47.0,          48.0,         49.0,          50.0,  50.0,  51.0,  53.0,  54.0,  54.0,  55.0,
    56.0,          57.0,         58.0,          59.0,  60.0,  61.0,  62.0,  62.0,  63.0,  65.0,
    66.0,          66.0,         67.0,          68.0,  69.0,  70.0,  71.0,  72.0,  73.0,  74.0,
    74.0,          75.0,         76.0,          78.0,  78.0,  79.0,  80.0,  81.0,  82.0,  83.0,
    84.0,          85.0,         86.0,          86.0,  87.0,  88.0,  90.0,  90.0,  91.0,  92.0,
    93.0,          94.0,         94.0,          96.0,  97.0,  98.0,  98.0,  99.0,  100.0, 102.0,
    102.0,         103.0,        104.0,         105.0, 106.0, 106.0, 108.0, 109.0, 110.0, 110.0,
};
/// sans-serif: fontBoundingBoxDescent for 1..120px.
const descents_sans_serif = [_]f64{
    0.22998046875, 0.4599609375, 0.68994140625, 1.0,  1.0,  1.0,  2.0,  2.0,  2.0,  2.0,
    3.0,           3.0,          3.0,           3.0,  3.0,  4.0,  4.0,  4.0,  4.0,  5.0,
    5.0,           5.0,          5.0,           6.0,  6.0,  6.0,  6.0,  6.0,  7.0,  7.0,
    7.0,           7.0,          8.0,           8.0,  8.0,  8.0,  9.0,  9.0,  9.0,  9.0,
    9.0,           10.0,         10.0,          10.0, 10.0, 11.0, 11.0, 11.0, 11.0, 11.0,
    12.0,          12.0,         12.0,          12.0, 13.0, 13.0, 13.0, 13.0, 14.0, 14.0,
    14.0,          14.0,         14.0,          15.0, 15.0, 15.0, 15.0, 16.0, 16.0, 16.0,
    16.0,          17.0,         17.0,          17.0, 17.0, 17.0, 18.0, 18.0, 18.0, 18.0,
    19.0,          19.0,         19.0,          19.0, 20.0, 20.0, 20.0, 20.0, 20.0, 21.0,
    21.0,          21.0,         21.0,          22.0, 22.0, 22.0, 22.0, 23.0, 23.0, 23.0,
    23.0,          23.0,         24.0,          24.0, 24.0, 24.0, 25.0, 25.0, 25.0, 25.0,
    26.0,          26.0,         26.0,          26.0, 26.0, 27.0, 27.0, 27.0, 27.0, 28.0,
};

/// serif: fontBoundingBoxAscent for 1..120px.
const ascents_serif = [_]f64{
    0.75,  1.5,   2.25,  4.0,   5.0,   6.0,   6.0,   7.0,   8.0,   10.0,
    10.0,  11.0,  12.0,  13.0,  13.0,  14.0,  16.0,  17.0,  17.0,  18.0,
    19.0,  20.0,  20.0,  22.0,  23.0,  24.0,  24.0,  25.0,  26.0,  28.0,
    28.0,  29.0,  30.0,  31.0,  31.0,  32.0,  34.0,  35.0,  35.0,  36.0,
    37.0,  38.0,  38.0,  40.0,  41.0,  42.0,  42.0,  43.0,  44.0,  46.0,
    46.0,  47.0,  48.0,  49.0,  49.0,  50.0,  52.0,  53.0,  53.0,  54.0,
    55.0,  56.0,  56.0,  58.0,  59.0,  60.0,  60.0,  61.0,  62.0,  64.0,
    64.0,  65.0,  66.0,  67.0,  67.0,  68.0,  70.0,  71.0,  71.0,  72.0,
    73.0,  74.0,  74.0,  76.0,  77.0,  78.0,  78.0,  79.0,  80.0,  82.0,
    82.0,  83.0,  84.0,  85.0,  85.0,  86.0,  88.0,  89.0,  89.0,  90.0,
    91.0,  92.0,  92.0,  94.0,  95.0,  96.0,  96.0,  97.0,  98.0,  100.0,
    100.0, 101.0, 102.0, 103.0, 103.0, 104.0, 106.0, 107.0, 107.0, 108.0,
};
/// serif: fontBoundingBoxDescent for 1..120px.
const descents_serif = [_]f64{
    0.25, 0.5,  0.75, 1.0,  1.0,  2.0,  2.0,  2.0,  2.0,  3.0,
    3.0,  3.0,  3.0,  4.0,  4.0,  4.0,  4.0,  5.0,  5.0,  5.0,
    5.0,  6.0,  6.0,  6.0,  6.0,  7.0,  7.0,  7.0,  7.0,  8.0,
    8.0,  8.0,  8.0,  9.0,  9.0,  9.0,  9.0,  10.0, 10.0, 10.0,
    10.0, 11.0, 11.0, 11.0, 11.0, 12.0, 12.0, 12.0, 12.0, 13.0,
    13.0, 13.0, 13.0, 14.0, 14.0, 14.0, 14.0, 15.0, 15.0, 15.0,
    15.0, 16.0, 16.0, 16.0, 16.0, 17.0, 17.0, 17.0, 17.0, 18.0,
    18.0, 18.0, 18.0, 19.0, 19.0, 19.0, 19.0, 20.0, 20.0, 20.0,
    20.0, 21.0, 21.0, 21.0, 21.0, 22.0, 22.0, 22.0, 22.0, 23.0,
    23.0, 23.0, 23.0, 24.0, 24.0, 24.0, 24.0, 25.0, 25.0, 25.0,
    25.0, 26.0, 26.0, 26.0, 26.0, 27.0, 27.0, 27.0, 27.0, 28.0,
    28.0, 28.0, 28.0, 29.0, 29.0, 29.0, 29.0, 30.0, 30.0, 30.0,
};

/// monospace: fontBoundingBoxAscent for 1..120px.
const ascents_monospace = [_]f64{
    0.92822265625, 1.8564453125, 2.78466796875, 4.0,   5.0,   6.0,   6.0,   7.0,   8.0,   9.0,
    10.0,          11.0,         12.0,          13.0,  14.0,  15.0,  16.0,  17.0,  18.0,  19.0,
    19.0,          20.0,         21.0,          22.0,  23.0,  24.0,  25.0,  26.0,  27.0,  28.0,
    29.0,          30.0,         31.0,          32.0,  32.0,  33.0,  34.0,  35.0,  36.0,  37.0,
    38.0,          39.0,         40.0,          41.0,  42.0,  43.0,  44.0,  45.0,  45.0,  46.0,
    47.0,          48.0,         49.0,          50.0,  51.0,  52.0,  53.0,  54.0,  55.0,  56.0,
    57.0,          58.0,         58.0,          59.0,  60.0,  61.0,  62.0,  63.0,  64.0,  65.0,
    66.0,          67.0,         68.0,          69.0,  70.0,  71.0,  71.0,  72.0,  73.0,  74.0,
    75.0,          76.0,         77.0,          78.0,  79.0,  80.0,  81.0,  82.0,  83.0,  84.0,
    84.0,          85.0,         86.0,          87.0,  88.0,  89.0,  90.0,  91.0,  92.0,  93.0,
    94.0,          95.0,         96.0,          97.0,  97.0,  98.0,  99.0,  100.0, 101.0, 102.0,
    103.0,         104.0,        105.0,         106.0, 107.0, 108.0, 109.0, 110.0, 110.0, 111.0,
};
/// monospace: fontBoundingBoxDescent for 1..120px.
const descents_monospace = [_]f64{
    0.23583984375, 0.4716796875, 0.70751953125, 1.0,  1.0,  1.0,  2.0,  2.0,  2.0,  2.0,
    3.0,           3.0,          3.0,           3.0,  4.0,  4.0,  4.0,  4.0,  4.0,  5.0,
    5.0,           5.0,          5.0,           6.0,  6.0,  6.0,  6.0,  7.0,  7.0,  7.0,
    7.0,           8.0,          8.0,           8.0,  8.0,  8.0,  9.0,  9.0,  9.0,  9.0,
    10.0,          10.0,         10.0,          10.0, 11.0, 11.0, 11.0, 11.0, 12.0, 12.0,
    12.0,          12.0,         12.0,          13.0, 13.0, 13.0, 13.0, 14.0, 14.0, 14.0,
    14.0,          15.0,         15.0,          15.0, 15.0, 16.0, 16.0, 16.0, 16.0, 17.0,
    17.0,          17.0,         17.0,          17.0, 18.0, 18.0, 18.0, 18.0, 19.0, 19.0,
    19.0,          19.0,         20.0,          20.0, 20.0, 20.0, 21.0, 21.0, 21.0, 21.0,
    21.0,          22.0,         22.0,          22.0, 22.0, 23.0, 23.0, 23.0, 23.0, 24.0,
    24.0,          24.0,         24.0,          25.0, 25.0, 25.0, 25.0, 25.0, 26.0, 26.0,
    26.0,          26.0,         27.0,          27.0, 27.0, 27.0, 28.0, 28.0, 28.0, 28.0,
};

/// Arial: fontBoundingBoxAscent for 1..120px.
const ascents_arial = [_]f64{
    0.9052734375, 1.810546875, 2.7158203125, 4.0,   5.0,   5.0,   6.0,   7.0,   8.0,   9.0,
    10.0,         11.0,        12.0,         13.0,  14.0,  14.0,  15.0,  16.0,  17.0,  18.0,
    19.0,         20.0,        21.0,         22.0,  23.0,  24.0,  24.0,  25.0,  26.0,  27.0,
    28.0,         29.0,        30.0,         31.0,  32.0,  33.0,  33.0,  34.0,  35.0,  36.0,
    37.0,         38.0,        39.0,         40.0,  41.0,  42.0,  43.0,  43.0,  44.0,  45.0,
    46.0,         47.0,        48.0,         49.0,  50.0,  51.0,  52.0,  53.0,  53.0,  54.0,
    55.0,         56.0,        57.0,         58.0,  59.0,  60.0,  61.0,  62.0,  62.0,  63.0,
    64.0,         65.0,        66.0,         67.0,  68.0,  69.0,  70.0,  71.0,  72.0,  72.0,
    73.0,         74.0,        75.0,         76.0,  77.0,  78.0,  79.0,  80.0,  81.0,  81.0,
    82.0,         83.0,        84.0,         85.0,  86.0,  87.0,  88.0,  89.0,  90.0,  91.0,
    91.0,         92.0,        93.0,         94.0,  95.0,  96.0,  97.0,  98.0,  99.0,  100.0,
    100.0,        101.0,       102.0,        103.0, 104.0, 105.0, 106.0, 107.0, 108.0, 109.0,
};
/// Arial: fontBoundingBoxDescent for 1..120px.
const descents_arial = [_]f64{
    0.2119140625, 0.423828125, 0.6357421875, 1.0,  1.0,  1.0,  1.0,  2.0,  2.0,  2.0,
    2.0,          3.0,         3.0,          3.0,  3.0,  3.0,  4.0,  4.0,  4.0,  4.0,
    4.0,          5.0,         5.0,          5.0,  5.0,  6.0,  6.0,  6.0,  6.0,  6.0,
    7.0,          7.0,         7.0,          7.0,  7.0,  8.0,  8.0,  8.0,  8.0,  8.0,
    9.0,          9.0,         9.0,          9.0,  10.0, 10.0, 10.0, 10.0, 10.0, 11.0,
    11.0,         11.0,        11.0,         11.0, 12.0, 12.0, 12.0, 12.0, 13.0, 13.0,
    13.0,         13.0,        13.0,         14.0, 14.0, 14.0, 14.0, 14.0, 15.0, 15.0,
    15.0,         15.0,        15.0,         16.0, 16.0, 16.0, 16.0, 17.0, 17.0, 17.0,
    17.0,         17.0,        18.0,         18.0, 18.0, 18.0, 18.0, 19.0, 19.0, 19.0,
    19.0,         19.0,        20.0,         20.0, 20.0, 20.0, 21.0, 21.0, 21.0, 21.0,
    21.0,         22.0,        22.0,         22.0, 22.0, 22.0, 23.0, 23.0, 23.0, 23.0,
    24.0,         24.0,        24.0,         24.0, 24.0, 25.0, 25.0, 25.0, 25.0, 25.0,
};

/// Helvetica: fontBoundingBoxAscent for 1..120px.
const ascents_helvetica = [_]f64{
    0.77001953125, 1.5400390625, 2.31005859375, 4.0,   5.0,   6.0,   6.0,   7.0,   8.0,   10.0,
    10.0,          11.0,         12.0,          13.0,  14.0,  14.0,  16.0,  17.0,  18.0,  18.0,
    19.0,          20.0,         21.0,          22.0,  23.0,  24.0,  25.0,  26.0,  26.0,  28.0,
    29.0,          30.0,         30.0,          31.0,  32.0,  33.0,  34.0,  35.0,  36.0,  37.0,
    38.0,          38.0,         39.0,          41.0,  42.0,  42.0,  43.0,  44.0,  45.0,  47.0,
    47.0,          48.0,         49.0,          50.0,  50.0,  51.0,  53.0,  54.0,  54.0,  55.0,
    56.0,          57.0,         58.0,          59.0,  60.0,  61.0,  62.0,  62.0,  63.0,  65.0,
    66.0,          66.0,         67.0,          68.0,  69.0,  70.0,  71.0,  72.0,  73.0,  74.0,
    74.0,          75.0,         76.0,          78.0,  78.0,  79.0,  80.0,  81.0,  82.0,  83.0,
    84.0,          85.0,         86.0,          86.0,  87.0,  88.0,  90.0,  90.0,  91.0,  92.0,
    93.0,          94.0,         94.0,          96.0,  97.0,  98.0,  98.0,  99.0,  100.0, 102.0,
    102.0,         103.0,        104.0,         105.0, 106.0, 106.0, 108.0, 109.0, 110.0, 110.0,
};
/// Helvetica: fontBoundingBoxDescent for 1..120px.
const descents_helvetica = [_]f64{
    0.22998046875, 0.4599609375, 0.68994140625, 1.0,  1.0,  1.0,  2.0,  2.0,  2.0,  2.0,
    3.0,           3.0,          3.0,           3.0,  3.0,  4.0,  4.0,  4.0,  4.0,  5.0,
    5.0,           5.0,          5.0,           6.0,  6.0,  6.0,  6.0,  6.0,  7.0,  7.0,
    7.0,           7.0,          8.0,           8.0,  8.0,  8.0,  9.0,  9.0,  9.0,  9.0,
    9.0,           10.0,         10.0,          10.0, 10.0, 11.0, 11.0, 11.0, 11.0, 11.0,
    12.0,          12.0,         12.0,          12.0, 13.0, 13.0, 13.0, 13.0, 14.0, 14.0,
    14.0,          14.0,         14.0,          15.0, 15.0, 15.0, 15.0, 16.0, 16.0, 16.0,
    16.0,          17.0,         17.0,          17.0, 17.0, 17.0, 18.0, 18.0, 18.0, 18.0,
    19.0,          19.0,         19.0,          19.0, 20.0, 20.0, 20.0, 20.0, 20.0, 21.0,
    21.0,          21.0,         21.0,          22.0, 22.0, 22.0, 22.0, 23.0, 23.0, 23.0,
    23.0,          23.0,         24.0,          24.0, 24.0, 24.0, 25.0, 25.0, 25.0, 25.0,
    26.0,          26.0,         26.0,          26.0, 26.0, 27.0, 27.0, 27.0, 27.0, 28.0,
};

/// Times New Roman: fontBoundingBoxAscent for 1..120px.
const ascents_times_new_roman = [_]f64{
    0.89111328125, 1.7822265625, 2.67333984375, 4.0,   4.0,   5.0,   6.0,   7.0,   8.0,   9.0,
    10.0,          11.0,         12.0,          12.0,  13.0,  14.0,  15.0,  16.0,  17.0,  18.0,
    19.0,          20.0,         20.0,          21.0,  22.0,  23.0,  24.0,  25.0,  26.0,  27.0,
    28.0,          29.0,         29.0,          30.0,  31.0,  32.0,  33.0,  34.0,  35.0,  36.0,
    37.0,          37.0,         38.0,          39.0,  40.0,  41.0,  42.0,  43.0,  44.0,  45.0,
    45.0,          46.0,         47.0,          48.0,  49.0,  50.0,  51.0,  52.0,  53.0,  53.0,
    54.0,          55.0,         56.0,          57.0,  58.0,  59.0,  60.0,  61.0,  61.0,  62.0,
    63.0,          64.0,         65.0,          66.0,  67.0,  68.0,  69.0,  70.0,  70.0,  71.0,
    72.0,          73.0,         74.0,          75.0,  76.0,  77.0,  78.0,  78.0,  79.0,  80.0,
    81.0,          82.0,         83.0,          84.0,  85.0,  86.0,  86.0,  87.0,  88.0,  89.0,
    90.0,          91.0,         92.0,          93.0,  94.0,  94.0,  95.0,  96.0,  97.0,  98.0,
    99.0,          100.0,        101.0,         102.0, 102.0, 103.0, 104.0, 105.0, 106.0, 107.0,
};
/// Times New Roman: fontBoundingBoxDescent for 1..120px.
const descents_times_new_roman = [_]f64{
    0.21630859375, 0.4326171875, 0.64892578125, 1.0,  1.0,  1.0,  2.0,  2.0,  2.0,  2.0,
    2.0,           3.0,          3.0,           3.0,  3.0,  3.0,  4.0,  4.0,  4.0,  4.0,
    5.0,           5.0,          5.0,           5.0,  5.0,  6.0,  6.0,  6.0,  6.0,  6.0,
    7.0,           7.0,          7.0,           7.0,  8.0,  8.0,  8.0,  8.0,  8.0,  9.0,
    9.0,           9.0,          9.0,           10.0, 10.0, 10.0, 10.0, 10.0, 11.0, 11.0,
    11.0,          11.0,         11.0,          12.0, 12.0, 12.0, 12.0, 13.0, 13.0, 13.0,
    13.0,          13.0,         14.0,          14.0, 14.0, 14.0, 14.0, 15.0, 15.0, 15.0,
    15.0,          16.0,         16.0,          16.0, 16.0, 16.0, 17.0, 17.0, 17.0, 17.0,
    18.0,          18.0,         18.0,          18.0, 18.0, 19.0, 19.0, 19.0, 19.0, 19.0,
    20.0,          20.0,         20.0,          20.0, 21.0, 21.0, 21.0, 21.0, 21.0, 22.0,
    22.0,          22.0,         22.0,          22.0, 23.0, 23.0, 23.0, 23.0, 24.0, 24.0,
    24.0,          24.0,         24.0,          25.0, 25.0, 25.0, 25.0, 26.0, 26.0, 26.0,
};

/// Courier New: fontBoundingBoxAscent for 1..120px.
const ascents_courier_new = [_]f64{
    0.83251953125, 1.6650390625, 2.49755859375, 3.0,  4.0,  5.0,  6.0,  7.0,  7.0,  8.0,
    9.0,           10.0,         11.0,          12.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0,
    17.0,          18.0,         19.0,          20.0, 21.0, 22.0, 22.0, 23.0, 24.0, 25.0,
    26.0,          27.0,         27.0,          28.0, 29.0, 30.0, 31.0, 32.0, 32.0, 33.0,
    34.0,          35.0,         36.0,          37.0, 37.0, 38.0, 39.0, 40.0, 41.0, 42.0,
    42.0,          43.0,         44.0,          45.0, 46.0, 47.0, 47.0, 48.0, 49.0, 50.0,
    51.0,          52.0,         52.0,          53.0, 54.0, 55.0, 56.0, 57.0, 57.0, 58.0,
    59.0,          60.0,         61.0,          62.0, 62.0, 63.0, 64.0, 65.0, 66.0, 67.0,
    67.0,          68.0,         69.0,          70.0, 71.0, 72.0, 72.0, 73.0, 74.0, 75.0,
    76.0,          77.0,         77.0,          78.0, 79.0, 80.0, 81.0, 82.0, 82.0, 83.0,
    84.0,          85.0,         86.0,          87.0, 87.0, 88.0, 89.0, 90.0, 91.0, 92.0,
    92.0,          93.0,         94.0,          95.0, 96.0, 97.0, 97.0, 98.0, 99.0, 100.0,
};
/// Courier New: fontBoundingBoxDescent for 1..120px.
const descents_courier_new = [_]f64{
    0.30029296875, 0.6005859375, 0.90087890625, 1.0,  2.0,  2.0,  2.0,  2.0,  3.0,  3.0,
    3.0,           4.0,          4.0,           4.0,  5.0,  5.0,  5.0,  5.0,  6.0,  6.0,
    6.0,           7.0,          7.0,           7.0,  8.0,  8.0,  8.0,  8.0,  9.0,  9.0,
    9.0,           10.0,         10.0,          10.0, 11.0, 11.0, 11.0, 11.0, 12.0, 12.0,
    12.0,          13.0,         13.0,          13.0, 14.0, 14.0, 14.0, 14.0, 15.0, 15.0,
    15.0,          16.0,         16.0,          16.0, 17.0, 17.0, 17.0, 17.0, 18.0, 18.0,
    18.0,          19.0,         19.0,          19.0, 20.0, 20.0, 20.0, 20.0, 21.0, 21.0,
    21.0,          22.0,         22.0,          22.0, 23.0, 23.0, 23.0, 23.0, 24.0, 24.0,
    24.0,          25.0,         25.0,          25.0, 26.0, 26.0, 26.0, 26.0, 27.0, 27.0,
    27.0,          28.0,         28.0,          28.0, 29.0, 29.0, 29.0, 29.0, 30.0, 30.0,
    30.0,          31.0,         31.0,          31.0, 32.0, 32.0, 32.0, 32.0, 33.0, 33.0,
    33.0,          34.0,         34.0,          34.0, 35.0, 35.0, 35.0, 35.0, 36.0, 36.0,
};

/// The swept range of `ascents_*` / `descents_*`. Larger sizes scale from
/// the last entry, which is close but not exact — CoreText's quantisation is
/// not a ratio.
pub const swept_sizes = 120;

pub const Family = struct {
    glyphs: []const Glyph,
    ascents: []const f64,
    descents: []const f64,
};

pub const sans_serif: Family = .{ .glyphs = &glyphs_sans_serif, .ascents = &ascents_sans_serif, .descents = &descents_sans_serif };
pub const serif: Family = .{ .glyphs = &glyphs_serif, .ascents = &ascents_serif, .descents = &descents_serif };
pub const monospace: Family = .{ .glyphs = &glyphs_monospace, .ascents = &ascents_monospace, .descents = &descents_monospace };
pub const arial: Family = .{ .glyphs = &glyphs_arial, .ascents = &ascents_arial, .descents = &descents_arial };
pub const helvetica: Family = .{ .glyphs = &glyphs_sans_serif, .ascents = &ascents_helvetica, .descents = &descents_helvetica };
pub const times_new_roman: Family = .{ .glyphs = &glyphs_times_new_roman, .ascents = &ascents_times_new_roman, .descents = &descents_times_new_roman };
pub const courier_new: Family = .{ .glyphs = &glyphs_courier_new, .ascents = &ascents_courier_new, .descents = &descents_courier_new };

/// Chrome falls back to the standard font for a family it cannot resolve:
/// '100px NoSuchFamily12345' measures exactly like '100px serif', and so do
/// 'Times' and every other unmatched name we tried.
pub const fallback = serif;

/// Maps a CSS family name to one of the measured families, ASCII
/// case-insensitively. Null when we have no table for it, which the caller
/// resolves by moving on to the next name in the list.
pub fn find(name: []const u8) ?Family {
    const table = [_]struct { []const u8, Family }{
        .{ "sans-serif", sans_serif },
        .{ "serif", serif },
        .{ "monospace", monospace },
        .{ "Arial", arial },
        .{ "Helvetica", helvetica },
        .{ "Times New Roman", times_new_roman },
        .{ "Courier New", courier_new },
        // Aliases confirmed by measurement: these resolve to the same faces.
        .{ "Times", serif },
        .{ "Courier", courier_new },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) {
            return entry[1];
        }
    }
    return null;
}

/// The glyph for a codepoint at the table's 100px basis. Outside the
/// tabulated ASCII range we have no measurement, so this returns null and the
/// caller decides what to do with an unknown glyph.
pub fn glyph(family: Family, codepoint: u21) ?Glyph {
    if (codepoint < first_codepoint or codepoint > last_codepoint) {
        return null;
    }
    return family.glyphs[codepoint - first_codepoint];
}

/// fontBoundingBoxAscent / Descent at `size`, read from the sweep where we
/// have it and extrapolated linearly above it.
pub fn boundingBox(family: Family, size: f64) struct { ascent: f64, descent: f64 } {
    if (size <= 0 or !std.math.isFinite(size)) {
        return .{ .ascent = 0, .descent = 0 };
    }

    const rounded = @round(size);
    if (rounded >= 1 and rounded <= @as(f64, @floatFromInt(family.ascents.len)) and rounded == size) {
        const index: usize = @intFromFloat(rounded - 1);
        return .{ .ascent = family.ascents[index], .descent = family.descents[index] };
    }

    // Between or beyond the sampled sizes: scale the largest sample.
    const last: f64 = @floatFromInt(family.ascents.len);
    const scale = size / last;
    return .{
        .ascent = family.ascents[family.ascents.len - 1] * scale,
        .descent = family.descents[family.descents.len - 1] * scale,
    };
}
