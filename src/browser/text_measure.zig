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

const std = @import("std");
const lp = @import("lightpanda");

const font_metrics = @import("font_metrics.zig");
const font_kerning = @import("font_kerning.zig");
const font_space_kerning = @import("font_space_kerning.zig");
const text_case = @import("text_case.zig");
const font_variants = @import("font_variants.zig");
const font_optical = @import("font_optical.zig");
const emoji_metrics = @import("emoji_metrics.zig");
const emoji_presentation = @import("emoji_presentation.zig");
const emoji_properties = @import("emoji_properties.zig");

// Two measurement paths live here, both reading tables transcribed from
// Chrome: per-glyph advances in font_metrics.zig, per-cluster emoji advances
// in emoji_metrics.zig, and the two Unicode properties that say which of the
// two a character belongs to in emoji_properties.zig.
//
// `measure` is the canvas one: it reproduces what `measureText` answers,
// exactly, for printable ASCII in the families we measured, and from the
// `emoji_sizes` table below for a colour emoji.
//
// `svgWidth` and friends below are the SVG one. It differs in two ways that
// are Chrome's, not ours: SVG text measures whole shaped clusters, so a ZWJ
// emoji sequence has one advance rather than the sum of its parts, and it
// addresses characters by UTF-16 code unit because that is what the DOM
// counts. Both paths walk clusters now; only the price of one differs.
//
// Neither is linear in the font size where a colour emoji is concerned —
// Chrome hands back the bitmap strike it picked — but only the canvas path
// models that. The SVG table was measured at 100px and 200px, where the
// strike is the em box and scaling is off by under a hundredth of a pixel;
// what it answers at 16px has never been measured, and is the em box rather
// than the 1.25 em `measureText` reports.
//
// Neither path shapes scripts or applies kerning; a real shaping backend can
// replace this module without changing SVGTextContentElement.

/// Everything a `TextMetrics` reports, in CSS pixels.
pub const Metrics = struct {
    width: f64 = 0,
    actualBoundingBoxLeft: f64 = 0,
    actualBoundingBoxRight: f64 = 0,
    fontBoundingBoxAscent: f64 = 0,
    fontBoundingBoxDescent: f64 = 0,
    actualBoundingBoxAscent: f64 = 0,
    actualBoundingBoxDescent: f64 = 0,
    hangingBaseline: f64 = 0,
    alphabeticBaseline: f64 = 0,
    ideographicBaseline: f64 = 0,
};

/// `letter-spacing` and `word-spacing`, resolved to CSS pixels.
///
/// Both are lengths the cascade hands down, not properties of a font, so they
/// ride on `Face` rather than living in it: every caller that measures text
/// already carries a `Face` down to the kernel, and the alternative was a
/// second parameter on `measure` and on the four layout walks between it and
/// the cascade.
///
/// The arithmetic is measured, on Chrome 151 headed at dpr 2
/// (scratch/b100/expr-spacing-table.js, expr-spacing-cluster.js):
///
///   * `letter` is charged after every grapheme CLUSTER, the last one included.
///     Per cluster and not per code point: a regional-indicator pair, an `e`
///     with a combining acute, and a ZWJ sequence are each charged once, though
///     they are two, two and three code points.
///   * `word` is charged at every U+0020 and U+00A0. It is NOT charged for
///     U+3000 or U+200B, which are not word separators.
///
pub const Spacing = struct {
    letter: f64 = 0,
    word: f64 = 0,

    /// Whether either property is set, so the common case can skip the counting.
    pub fn any(self: Spacing) bool {
        return self.letter != 0 or self.word != 0;
    }
};

/// Which of Chrome's two text-measuring surfaces a reading is for.
///
/// Not a detail: Chrome answers them differently, and both answers are Chrome's.
/// Two measured differences so far, and they are what this enum exists to
/// carry rather than a bool each:
///
///   * `word-spacing` is charged for a U+0020 in the FIRST character position
///     through `measureText` and not through layout. `' ab'` under
///     `word-spacing: 5px` is 24.1015625 one way and 19.1015625 the other, same
///     font, same string.
///   * a space next to a capital kerns in LAYOUT and not in the canvas.
///     'AVATAR To Wo' at 16px serif is 105.4140625 through
///     `getBoundingClientRect` and 105.9765625 through `measureText`. See
///     `font_space_kerning.zig`.
///
/// The two happen to point opposite ways, which is exactly why naming the
/// surface beats naming the behaviours: a third difference reads the same enum
/// instead of adding a third flag whose polarity has to be remembered.
pub const Surface = enum { canvas, layout };

/// Measures `text` in `family` at `size`, from Chrome's own numbers.
///
/// Exact for printable ASCII, because advances are linear in size and a
/// string's width is the sum of its glyphs'. Text is walked one shaped
/// cluster at a time so a colour emoji — which is neither a text glyph nor
/// necessarily one codepoint — can be priced from `emoji_sizes` instead.
/// Two known departures, all measured rather than assumed:
///
///   * above U+00FF, outside the colour emoji, we have no table, so each
///     glyph is charged the family's mean ASCII advance and contributes no
///     ink. That is a guess, not a measurement — and a visible one: Chrome
///     makes a bare U+2600 16 at 16px sans-serif, where we say 8.431.
///   * every colour emoji is charged what U+1F600 measures. All ten the
///     Turnstile widget asks about agree with it to the last decimal, but
///     ten is the whole of the evidence.
/// A resolved font: the family, plus which of its four tables the weight and
/// style select. Carried as one value because every measurement wants both and
/// because a `Family` is a value with no room for the answer.
///
/// Built once per string rather than once per glyph -- `tableFor` walks the
/// variant rows, which is the same reason `font_kerning.tableFor` is hoisted
/// out of the loop below it.
pub const Face = struct {
    family: font_metrics.Family,
    variant: font_variants.Variant = .regular,
    /// The resolved `font-weight`, which an OPTICAL face needs beyond the
    /// variant: SF's weight is a continuous axis, so 500 and 600 are their own
    /// instances and not the two tables `variant` chooses between. Every other
    /// family ignores it.
    ///
    /// 400 by default, and so a no-op for the dozen places that build a face by
    /// struct literal -- an unstyled paragraph is what they are all measuring.
    weight: u16 = 400,
    table: font_variants.Table = .{},
    spacing: Spacing = .{},
    /// Defaults to the canvas, because `Face.regular` is the SVG caller and
    /// SVG text measures the way the canvas does -- and because a caller that
    /// has not thought about it gets the surface that adds nothing.
    surface: Surface = .canvas,
    /// The pairs with a space on one side, resolved HERE and not at each use.
    /// `font_space_kerning.tableFor` walks a row per family per face, and the
    /// layout paths ask for a pair at every space they price: resolving it per
    /// space put `document/element_from_point.html` at 2104-2171ms against its
    /// 1500ms budget where the same tree without this read under it, four runs
    /// each, alternating, at load 1.9. Empty on the canvas surface.
    space_kerns: font_kerning.Table = .{},
    /// Whether the font's kern pairs are charged at all. False under
    /// `font-kerning: none` and `font-feature-settings: "kern" 0`, which Chrome
    /// treats as one thing: identical on all 48 rows of six families by eight
    /// pairs (scratch/b100/expr-kern-table.js).
    ///
    /// It turns BOTH tables off, which is a measurement and not a symmetry
    /// argument: 'AVATAR To Wo' at 16px serif is 105.4140625 in layout and
    /// 115.5390625 with kerning off, and the 10.125 between them is 9.5625 of
    /// ordinary pairs plus the 0.5625 of space pairs that layout alone charges.
    /// Leaving `space_kerns` on would land on 114.9765625.
    ///
    /// The other half of Chrome's feature -- ligatures, which
    /// `font-variant-ligatures: none` and `text-rendering: optimizeSpeed` turn
    /// off and which leave kerning alone -- has no bit here on purpose. This
    /// engine forms no ligatures at all: 'Waffle fi' comes out narrower than
    /// Chrome's own no-ligature width, so a switch would be a switch over
    /// nothing, with no reading to hold it to. Those two declarations are
    /// asserted as no-ops in `element/text_kerning_off.html` instead.
    kerning: bool = true,
    /// `text-transform`, applied as the pen walks rather than by rewriting the
    /// string first. Measured: a transformed box is EXACTLY as wide as the
    /// transformed string written out with nothing declared -- 60 of 60 rows in
    /// one probe and 105 of 105 in another (scratch/b102/expr-tt-final.js) --
    /// so there is no width model here, only the character mapping, and the
    /// kern pairs then fall on the transformed characters as they should.
    ///
    /// Carried on the face rather than passed to `measure`, because every
    /// measuring path already threads a face down to the kernel and none of the
    /// forty callers that do not care should have to name it. `capitalize`'s
    /// word-start flag cannot live here -- a face is a value and the flag has to
    /// come back out -- so that one is `measureAt`'s pointer.
    transform: text_case.Transform = .none,

    /// `font-variant-caps`, which Blink renders by shaping the affected
    /// characters UPPERCASED at a reduced size in the same face rather than by
    /// selecting a small-caps face. Measured on headed Chrome 153 across six
    /// families and eighteen sizes (scratch/s73/expr-sc{,2,3}.js):
    ///
    ///   * the reduced size is `round(0.7 * size * 2) / 2` -- seven tenths,
    ///     snapped to half a CSS pixel, which is one device pixel at the
    ///     device pixel ratio this build claims. All eighteen sizes solve to
    ///     it exactly, against a scan of candidate sizes at 0.005 steps;
    ///   * the characters are mapped by the ordinary uppercase mapping --
    ///     `ss`, `fi`, dotless i, final sigma, Cyrillic and accented Greek all
    ///     land on what `toUpperCase` gives, and a character already uppercase
    ///     (or already a small-cap letter) is left at the full size;
    ///   * `small-caps` reduces only what uppercasing CHANGES;
    ///     `all-small-caps` reduces every character.
    ///
    /// Digits and punctuation are untouched by both, which follows from the
    /// mapping rather than being a rule of its own.
    caps: SmallCaps = .none,

    /// The face `weight` and `italic` select. The threshold is measured: at
    /// 16px serif 'M' is 14.2265625 at 500 and 15.1015625 at 600, 700 and 900
    /// alike, so `bold` the keyword is 700 arriving here and not a case of its
    /// own.
    pub fn of(family: font_metrics.Family, weight: u16, italic: bool, spacing: Spacing, surface: Surface, kerning: bool, transform: text_case.Transform, caps: SmallCaps) Face {
        const variant = font_variants.variantFor(weight, italic);
        return .{
            .family = family,
            .variant = variant,
            .weight = weight,
            .table = font_variants.tableFor(family, variant),
            .spacing = spacing,
            .surface = surface,
            .space_kerns = if (surface == .layout and kerning)
                font_space_kerning.tableFor(family, variant)
            else
                .{},
            .kerning = kerning,
            .transform = transform,
            .caps = caps,
        };
    }

    /// The face a caller that has not resolved a weight yet wants. SVG text is
    /// the one left: `font-weight` reaches it as a presentation attribute this
    /// engine does not read into a face, so its measurements are still the
    /// regular ones. That is unchanged behaviour rather than a new gap.
    pub fn regular(family: font_metrics.Family) Face {
        return .{ .family = family };
    }

    pub fn glyph(self: Face, codepoint: u21) ?font_metrics.Glyph {
        if (self.table.get(codepoint)) |g| {
            return g;
        }
        return font_metrics.glyph(self.family, codepoint);
    }
};

/// Which characters `font-variant-caps` shrinks. See `Face.caps` for the
/// measurement.
pub const SmallCaps = enum {
    none,
    /// `small-caps`: the characters uppercasing changes.
    lowercase,
    /// `all-small-caps`: every character.
    all,
};

/// The size the small-caps run shapes at: seven tenths of the font size,
/// snapped to half a CSS pixel. Measured, `Face.caps`.
pub fn smallCapsSize(size: f64) f64 {
    if (!(size > 0) or !std.math.isFinite(size)) return size;
    return effectiveSize(@round(size * 0.7 * 2) / 2);
}

/// One source codepoint as it is SHAPED: `text-transform` first, then
/// `font-variant-caps` on what that produced.
///
/// That order is the spec's -- `text-transform` rewrites the text and the
/// variant is a shaping feature over the rewritten text -- and it is not
/// something we have read off Chrome; the two properties together are not
/// asserted anywhere.
///
/// `small` belongs to the group and not to each character it produced, which
/// costs nothing: the only source that lengthens is U+00DF, and its 'SS' is
/// already uppercase, so the two characters of a pair always agree.
///
/// Composing two `Mapped`s can produce at most two characters in the range
/// `text_case` maps: `map` lengthens only U+00DF, and the 'S' it gives back
/// uppercases to itself.
const Shaped = struct {
    mapped: text_case.Mapped,
    /// Whether the characters shape at `smallCapsSize` rather than at the
    /// font size.
    small: bool,
};

inline fn shapeCodepoint(source: u21, face: Face, at_word_start: *bool) Shaped {
    // The `.none` cases are spelled out rather than left to the general path
    // for the reason `text_case.map` is inline: this runs once per codepoint
    // of every string the engine measures, and almost every one of them
    // declares neither property.
    if (face.transform == .none and face.caps == .none) {
        return .{ .mapped = .{ .first = source }, .small = false };
    }
    const transformed = text_case.map(source, face.transform, at_word_start);
    if (face.caps == .none) return .{ .mapped = transformed, .small = false };
    if (transformed.second != null) {
        // Already two uppercase characters, which uppercasing leaves alone.
        return .{ .mapped = transformed, .small = face.caps == .all };
    }
    const uppercased = text_case.upper(transformed.first);
    const changed = uppercased.second != null or uppercased.first != transformed.first;
    return .{ .mapped = uppercased, .small = face.caps == .all or changed };
}

/// Whether two faces shape as one run, so a kern pair may cross between them.
///
/// Measured: Chrome charges the pair across a space only when the text either
/// side is in the SAME font. `ab <span>To</span> cd` at 16px serif is
/// 54.578125 -- the pair applied -- and the same markup with
/// `font-weight: bold`, `font-style: italic` or `font-size: 32px` on the span
/// is 0.28125 wider than the sum of its parts says, which is exactly the pair
/// NOT applied (scratch/b100/expr-inline-child-bold.js). A font change breaks
/// the shaping run, and a pair cannot straddle the break.
pub fn shapesAsOneRun(a: Face, a_size: f64, b: Face, b_size: f64) bool {
    return a.family.glyphs.ptr == b.family.glyphs.ptr and
        a.variant == b.variant and
        a_size == b_size;
}

/// What the font adjusts across `a` then `b`, in CSS pixels at `size`, for a
/// caller that measures the two sides in SEPARATE calls to `measure` and so
/// cannot get it from there.
///
/// `Element.CollapsedRun` is that caller: it renders a collapsing run by
/// measuring each word and charging one space between them, so the pair either
/// side of that space falls in the gap between two calls. Chrome kerns those --
/// 'ab   To   cd' renders as 'ab To cd' and is 54.578125 at 16px serif, where
/// the words and the space measured apart sum to 54.859375.
///
/// Both tables, so the caller does not have to know there are two. On the
/// canvas surface the second is empty and this is just `font_kerning`.
pub fn kernBetween(face: Face, a: u21, b: u21, size: f64) f64 {
    // Only the space table is consulted, and that is a fact about the data
    // rather than a shortcut: one of `a` and `b` is always a space here, and
    // `font_kerning.zig` has no pair with a space on either side -- zero of its
    // 265 840. So the ordinary table could not answer even if it were asked,
    // and asking it would mean a `tableFor` walk per space.
    //
    // Through the optical table for the same reason `measure` goes through it:
    // the pairs an optical face applies move with the size, and this face's two
    // space pairs have faded to nothing by 17px.
    const optical = font_optical.tableFor(face.family, face.variant);
    return toPixels(optical.spaceKern(face.space_kerns, a, b, size), size);
}

/// Measures `text` in `face` at `size`, starting a `capitalize` at a word.
///
/// The entry point every caller that has not thought about `text-transform`
/// wants, which is all but the handful of layout walks that have to carry the
/// word-start flag from one text node to the next.
pub fn measure(face: Face, text: []const u8, size: f64) Metrics {
    var at_word_start = true;
    return measureAt(face, text, size, &at_word_start);
}

/// The width alone, answered from a memo when the same word has been priced in
/// the same face at the same size before.
///
/// For the two layout walks that chop a run at white space and want nothing but
/// the pen: `CollapsedRun.measure` and `LineFlow.add`. They ask this once per
/// WORD, and a page is overwhelmingly the same few hundred words over and over
/// -- the same word in the same face at the same size, because a paragraph is
/// one face and one size. `measureAt` is a pure function of exactly the
/// arguments below, so the memo needs no invalidation: nothing a mutation can
/// change is an input to it.
///
/// It exists because a layout pass over a real page is this call. One
/// `data-` attribute invalidates the whole position table, and rebuilding it
/// re-measured 670KB of text: 400 paragraphs of filler cost 109ms a pass and 20
/// mutation-then-read pairs cost 2177ms (scratch/s90/relayout-per-mutation.js,
/// ReleaseFast), where `sample`'s self-time table put 3289 of its samples in
/// `measureAt` against 367 in the runner-up.
///
/// Not folded into `measureAt` itself: every other caller wants the whole
/// `Metrics`, and the ink box, the baselines and the two bounding edges are not
/// what this stores. Callers wanting those keep paying for them.
pub fn widthAt(face: Face, text: []const u8, size: f64, at_word_start: *bool) f64 {
    if (text.len == 0 or text.len > word_memo_max_len) {
        return measureAt(face, text, size, at_word_start).width;
    }
    const slot = &word_memo[wordMemoHash(face, text, size, at_word_start.*)];
    if (slot.len == text.len and
        slot.at_word_start_in == at_word_start.* and
        slot.size_bits == @as(u64, @bitCast(size)) and
        std.mem.eql(u8, slot.bytes[0..slot.len], text) and
        faceEql(slot.face, face))
    {
        at_word_start.* = slot.at_word_start_out;
        return slot.width;
    }
    const was = at_word_start.*;
    const width = measureAt(face, text, size, at_word_start).width;
    // Direct-mapped, so a colliding word simply takes the slot. A page whose
    // working set outruns the table pays what it paid before this existed
    // rather than paying for eviction bookkeeping on top.
    slot.* = .{
        .len = @intCast(text.len),
        .at_word_start_in = was,
        .at_word_start_out = at_word_start.*,
        .size_bits = @bitCast(size),
        .face = face,
        .width = width,
        .bytes = undefined,
    };
    @memcpy(slot.bytes[0..text.len], text);
    return width;
}

/// Long enough for a word, which is what this is asked about. 33 bytes is where
/// the German dictionary runs out; past it the memo steps aside rather than
/// growing an allocation, and the caller measures as it always did.
const word_memo_max_len = 40;

/// A power of two so the hash can be masked, and sized for a page rather than
/// for a paragraph: 4096 words is more distinct words than a document holds,
/// and the table is 512KB of BSS that never grows.
const word_memo_slots = 4096;

const WordMemoEntry = struct {
    /// Zero means empty: `widthAt` never stores an empty word.
    len: u8 = 0,
    at_word_start_in: bool = false,
    at_word_start_out: bool = false,
    /// The bits and not the value, so the comparison is exact and total --
    /// a NaN size would never match itself otherwise, and -0 would match 0.
    size_bits: u64 = 0,
    /// Inert: `len` is 0 in every default entry, and no lookup of an empty word
    /// reaches the comparison.
    face: Face = .{ .family = font_metrics.sans_serif },
    width: f64 = 0,
    bytes: [word_memo_max_len]u8 = undefined,
};

/// One table for the process, the way `Element.measure_entries` is one counter.
/// It holds no pointer into any page: the word's bytes are copied in, and the
/// two tables on a `Face` are comptime data. So it outlives a page safely and
/// needs no clearing when one goes away.
var word_memo: [word_memo_slots]WordMemoEntry = @splat(.{});

fn wordMemoHash(face: Face, text: []const u8, size: f64, at_word_start: bool) usize {
    var h = std.hash.Wyhash.init(@bitCast(size));
    h.update(text);
    h.update(&.{
        @intFromBool(at_word_start),
        @intFromEnum(face.variant),
        // The weight and not just the variant, because an optical face reads a
        // continuous axis: 400 and 500 are the same `variant` and different
        // advances, so a key without this answers whichever of the two was
        // measured first. That is not a theoretical collision -- it is what
        // `font-weight: 500 system-ui` did, silently, until a two-arm sweep
        // came back with exactly two distinct widths over seven weights.
        @truncate(face.weight),
        @truncate(face.weight >> 8),
        @intFromEnum(face.surface),
        @intFromEnum(face.transform),
        @intFromEnum(face.caps),
        @intFromBool(face.kerning),
    });
    h.update(std.mem.asBytes(&@as(u64, @bitCast(face.spacing.letter))));
    h.update(std.mem.asBytes(&@as(u64, @bitCast(face.spacing.word))));
    h.update(std.mem.asBytes(&@as(usize, @intFromPtr(face.family.glyphs.ptr))));
    h.update(std.mem.asBytes(&@as(usize, @intFromPtr(face.table.glyphs.ptr))));
    h.update(std.mem.asBytes(&@as(usize, @intFromPtr(face.space_kerns.pairs.ptr))));
    return @intCast(h.final() % word_memo_slots);
}

/// Field by field rather than `std.meta.eql`, because a `Family` and the two
/// variant tables are slices of comptime data: every `Family` in the engine is
/// one of the constants at the foot of font_metrics.zig, each with its own
/// `glyphs` array, so the pointer settles identity and the megabyte behind it
/// is never walked. The two widths are compared as well, so a family assembled
/// some other way could not pass as one of them for free.
fn faceEql(a: Face, b: Face) bool {
    return a.family.glyphs.ptr == b.family.glyphs.ptr and
        a.family.glyphs.len == b.family.glyphs.len and
        a.family.avg_char_width == b.family.avg_char_width and
        a.family.max_char_width == b.family.max_char_width and
        a.family.own_kerns.pairs.ptr == b.family.own_kerns.pairs.ptr and
        a.variant == b.variant and
        a.weight == b.weight and
        a.surface == b.surface and
        a.transform == b.transform and
        a.caps == b.caps and
        a.kerning == b.kerning and
        a.spacing.letter == b.spacing.letter and
        a.spacing.word == b.spacing.word and
        a.table.glyphs.ptr == b.table.glyphs.ptr and
        a.table.glyphs.len == b.table.glyphs.len and
        a.space_kerns.pairs.ptr == b.space_kerns.pairs.ptr and
        a.space_kerns.pairs.len == b.space_kerns.pairs.len and
        std.mem.eql(u64, &a.space_kerns.starts, &b.space_kerns.starts);
}

/// The same, with `capitalize`'s word-start flag carried in and out.
///
/// A word can straddle two text nodes -- `ab` and `cd` are one word, `a ` and
/// ` b` are two -- so the flag belongs to the run and not to the call. Every
/// path that measures a run in pieces owns one; see `Face.transform`.
pub fn measureAt(face: Face, text: []const u8, size: f64, at_word_start: *bool) Metrics {
    const box = font_metrics.boundingBox(face.family, size);
    var metrics = Metrics{
        .fontBoundingBoxAscent = box.ascent,
        .fontBoundingBoxDescent = box.descent,
        // Both derived from the box, exactly as Chrome reports them: the
        // hanging baseline sits at 80% of the ascent and the ideographic one
        // at the descent. Chrome computes the former in single precision —
        // it answers 10.399999618530273, not 10.4, for an ascent of 13 — so
        // the round-trip through f32 is deliberate.
        .hangingBaseline = @as(f32, @floatCast(box.ascent * 0.8)),
        .alphabeticBaseline = 0,
        .ideographicBaseline = -box.descent,
    };
    if (size <= 0 or !std.math.isFinite(size)) {
        return metrics;
    }

    // The pen is carried in two pieces. Tabulated advances stay at the
    // table's 100px basis, where every value is a dyadic rational, so the sum
    // is exact in f64 and `total * size / basis` lands on Chrome's answer bit
    // for bit; scaling each glyph first instead drifts by an ulp or two over
    // a long string. Emoji advances are already in pixels and cannot be moved
    // to the basis and back without picking up that same error — 20px at
    // 15px font-size comes back as 20.000000000000004 — so they are kept
    // apart. A string of printable ASCII never touches the second piece.
    // The optical-size correction for this face, resolved once for the run.
    // Empty for every family but the macOS system one, and free when it is:
    // `Table.advance` on an empty table returns the tabulated advance.
    //
    // Resolved HERE rather than carried on the `Face`, because a face is also
    // built by struct literal in a dozen places and a field would be silently
    // absent in each of them -- the correction is a property of the family and
    // the variant, both of which are already on the face.
    const optical = font_optical.tableFor(face.family, face.variant);
    var pen_basis: f64 = 0;
    // The same, for the characters `font-variant-caps` shrinks. A second
    // accumulator and not a scaled addition into the first, because the two
    // runs quantise SEPARATELY: Blink shapes them at two sizes, so each sum
    // meets `quantise` at its own basis, exactly as two adjacent spans of
    // different sizes would. Zero -- and so free -- for every face that
    // declares no variant.
    var small_basis: f64 = 0;
    const small_size = if (face.caps == .none) size else smallCapsSize(size);
    var pen_pixels: f64 = 0;
    var ink_min: f64 = 0;
    var ink_max: f64 = 0;
    var ascent: f64 = 0;
    var descent: f64 = 0;
    var any_ink = false;

    // Blink chooses one fallback font per run, seeded by the first character
    // the primary font cannot draw, and keeps it for the whole run. Which of
    // the three states we are in decides what a character the primary font
    // cannot draw costs. Measured at 16px sans-serif, not reasoned about:
    //
    //   U+0098 U+0080         32      -- U+0080 alone is 8.898. The glyph-less
    //                                    U+0098 went to the last resort font
    //                                    first, and U+0080 followed it there.
    //   U+0080 U+0098 U+0080  33.797  -- both U+0080 keep their 8.898: the
    //                                    first one seeded a font that draws
    //                                    them, and U+0098 does not reseed.
    //   U+0098 'a' U+0080     40.898  -- still 16 for the U+0080. A character
    //                                    the primary font *does* draw sits in
    //                                    between and changes nothing.
    var fallback: enum { none, own, last_resort } = .none;

    // A string's width is the sum of its glyphs' advances PLUS what the font
    // adjusts across a pair. Chrome makes 'AV' 21.046875 at 16px serif where the
    // two advances sum to 23.109375; without this the engine answered the sum,
    // which one `measureText` sees. The table is looked up once here rather than
    // once per character, and carries a bitmap of the ~40 characters that start
    // a pair so the common character costs a shift and an AND.
    // Empty rather than skipped at the use site: the pair lookup below is per
    // character of every string the engine measures, and an empty table already
    // answers zero from its start bitmap without a branch of its own.
    const kerns = kernsFor(face);
    // The pairs with a space on one side, which Chrome applies in layout and
    // not in the canvas. Resolved once when the face was built, so this costs
    // nothing here; empty on the canvas surface and for the 142 families that
    // kern no space pair either way.
    const space_kerns = face.space_kerns;
    var previous: ?u21 = null;
    // Which of the two sizes `previous` was shaped at. A size change breaks
    // the shaping run -- `shapesAsOneRun` is the same reading, one size
    // against another -- so a kern pair cannot straddle the boundary between a
    // small-cap and a full-size character.
    var previous_small = false;

    var offset: usize = 0;
    while (offset < text.len) {
        // Only the boundary is taken from the cluster; what it costs is a
        // question canvas answers for itself, from a different table than the
        // SVG advance `nextCluster` computes.
        const cluster = nextCluster(face, text[offset..]);
        if (cluster.bytes == 0) break;
        const shaped = text[offset..][0..cluster.bytes];
        offset += cluster.bytes;

        // `letter-spacing` is charged once for this cluster and `word-spacing`
        // once per separator in it, both AFTER the cluster's own advance. The
        // ordering is what keeps the ink boxes right: charging first would push
        // the opening cluster off zero, where Chrome leaves it there and moves
        // only the clusters behind it. The total width is the same either way,
        // so the ink is the only thing that says which.
        //
        // A `defer` and not a line at the bottom of the loop, because the
        // colour-emoji branch below leaves the iteration with `continue` and an
        // emoji is charged like any other cluster.
        const at_start = offset == cluster.bytes;
        defer if (face.spacing.any()) {
            pen_pixels += clusterSpacing(face.spacing, face.surface, shaped, at_start);
        };

        if (isColourEmoji(shaped)) {
            const glyph = emojiBox(size);
            const pen = toPixels(pen_basis, size) + toPixels(small_basis, small_size) + pen_pixels;
            const first = !any_ink;
            foldInk(&ink_min, &ink_max, &any_ink, pen - glyph.left, pen + glyph.right);
            ascent = if (first) glyph.ascent else @max(ascent, glyph.ascent);
            descent = if (first) glyph.descent else @max(descent, glyph.descent);
            pen_pixels += glyph.advance;
            continue;
        }

        var codepoints = std.unicode.Utf8Iterator{ .bytes = shaped, .i = 0 };
        while (codepoints.nextCodepoint()) |source| {
            // `text-transform` maps here, one source codepoint to one or two.
            // Two happens once in the range this maps -- U+00DF uppercases to
            // 'SS' -- and the inner loop is what pays for it: everything below
            // prices the character it is GIVEN, so the pairs and the ink and the
            // fallback state all follow the transformed text, which is what
            // makes a transformed box exactly as wide as the transformed string.
            //
            // `letter-spacing` is charged by the `defer` above, once for the
            // source cluster and not once per character it produced. Whether
            // Chrome charges the transformed count has not been measured, and
            // one character in the whole range can differ.
            // The `.none` case is spelled out inside `shapeCodepoint` rather
            // than left to `map`: this runs once per codepoint of every string
            // the engine measures, and almost every one of them declares no
            // transform. Through `map` and the two-element loop it cost 3.6% of
            // the 60k-measurement budget test in a debug build.
            //
            // `font-variant-caps` rides along in the same call, because what it
            // shrinks is decided on what `text-transform` produced.
            const shaping = shapeCodepoint(source, face, at_word_start);
            const mapped = shaping.mapped;
            // Which of the two accumulators and which of the two sizes this
            // character's group belongs to.
            const small = shaping.small;
            const run_size = if (small) small_size else size;
            const basis = if (small) &small_basis else &pen_basis;
            if (small != previous_small) previous = null;
            previous_small = small;
            // A counted loop rather than a slice of a two-element array: the
            // array wanted a stack write and the slice a bounds check, per
            // codepoint of every string, and this loop runs exactly once unless
            // the transform lengthened the character.
            var emitted: u2 = 0;
            while (emitted < mapped.len()) : (emitted += 1) {
                const codepoint = if (emitted == 0) mapped.first else mapped.second.?;
                if (previous) |prev| {
                    // Through the optical table, because the pairs move with the
                    // font size the way the advances do -- 'AV' is -0.15503 em at
                    // 28px and above and -0.12596 at 17px and below. For every
                    // other family, and for every size from 28px up, this is the
                    // tabulated pair unchanged.
                    basis.* += optical.kern(kerns, prev, codepoint, run_size);
                    // Gated on one of the two being a space rather than looked up
                    // unconditionally: this is per character of every string the
                    // engine measures, and the second table can only ever answer at
                    // a space.
                    if (prev == ' ' or codepoint == ' ') {
                        basis.* += optical.spaceKern(space_kerns, prev, codepoint, run_size);
                    }
                }
                previous = codepoint;

                var glyph = face.glyph(codepoint) orelse {
                    // A joiner, a variation selector or a combining mark rides on
                    // the glyph before it: Chrome makes 'a' and 'a' U+0301 both
                    // 8.898 at 16px sans-serif, and a lone U+FE0F zero.
                    //
                    // Whether an untabulated codepoint would seed the fallback is
                    // not something we have measured, so it leaves the state alone.
                    if (isZeroWidth(codepoint)) continue;
                    // An emoji-capable character asked for its TEXT presentation
                    // -- the colour one never reaches here, `isColourEmoji`
                    // answered it above. Arial draws some of these itself and
                    // falls back for the rest, and each fallback font has its own
                    // advance: the mean-advance guess answers one number for all
                    // eighty-one, which is exactly what Kasada's ten readings
                    // separate. Measured, emoji_presentation.zig.
                    basis.* += if (emoji_presentation.find(codepoint)) |row|
                        row.advance
                    else
                        meanAdvance(face.family);
                    continue;
                };

                if (font_metrics.afterFallback(face.family, codepoint)) |on_last_resort| {
                    // A codepoint the primary font cannot draw but some fallback
                    // font can, so what it costs depends on which font the run
                    // already settled on.
                    switch (fallback) {
                        .last_resort => glyph = on_last_resort,
                        // Only a codepoint that draws something seeds a font.
                        // U+007F draws nothing and does not: Chrome makes U+007F
                        // U+0098 U+0080 32 at 16px sans-serif, so the U+0098 still
                        // got to seed the last resort from behind it, where
                        // U+007F U+0080 is 8.898 and the U+0080 seeded its own.
                        .none => if (!isBlank(glyph)) {
                            fallback = .own;
                        },
                        .own => {},
                    }
                } else if (fallback == .none and font_metrics.seedsLastResort(face.family, codepoint)) {
                    fallback = .last_resort;
                }

                // A blank glyph (the space) has no ink box to fold in.
                if (!isBlank(glyph)) {
                    // Seeded from the first inked glyph rather than from zero: an
                    // ink boundary is signed, and a running max that starts at
                    // zero can never report a negative one. Chrome makes U+0022's
                    // descent -6.883 at 16px sans-serif — its ink is wholly above
                    // the baseline — and U+0084's ascent -1.594.
                    const first = !any_ink;
                    // The other run's contribution to the pen is added in
                    // pixels, while this run's keeps the subtraction at the
                    // basis: the exactness the two-piece pen buys is about the
                    // SUM of one run's advances, and the other run is one
                    // already-converted number here either way. Zero, and so
                    // exactly the old expression, for a face with no variant.
                    const other = if (small) toPixels(pen_basis, size) else toPixels(small_basis, small_size);
                    foldInk(
                        &ink_min,
                        &ink_max,
                        &any_ink,
                        toPixels(basis.* - glyph.left, run_size) + other + pen_pixels,
                        toPixels(basis.* + glyph.right, run_size) + other + pen_pixels,
                    );
                    const glyph_ascent = toPixels(glyph.ascent, run_size);
                    const glyph_descent = toPixels(glyph.descent, run_size);
                    ascent = if (first) glyph_ascent else @max(ascent, glyph_ascent);
                    descent = if (first) glyph_descent else @max(descent, glyph_descent);
                }

                // The optical correction, and the only place a tabulated
                // advance is charged. Empty -- and so exactly `glyph.advance`
                // -- for every face but the macOS system one.
                basis.* += optical.advance(codepoint, glyph.advance, run_size, face.weight);
            }
        }
    }

    metrics.width = toPixels(quantise(face.family, pen_basis), size) +
        toPixels(quantise(face.family, small_basis), small_size) +
        pen_pixels;
    metrics.actualBoundingBoxAscent = ascent;
    metrics.actualBoundingBoxDescent = descent;
    if (any_ink) {
        metrics.actualBoundingBoxLeft = -ink_min;
        metrics.actualBoundingBoxRight = ink_max;
    }
    return metrics;
}

/// What one shaped cluster earns from the two spacing properties, in CSS pixels.
///
/// `letter` once for the cluster, and `word` once for each word separator in
/// it, less the opening U+0020 a layout run does not charge (see
/// `Surface`). A separator is U+0020 or U+00A0 and nothing else: U+3000 and U+200B were
/// measured under `word-spacing: 5px` and moved nothing (the test asserts both
/// as deltas, since this engine prices them from the mean-advance fallback and
/// Chrome does not).
fn clusterSpacing(spacing: Spacing, surface: Surface, shaped: []const u8, at_start: bool) f64 {
    var total = spacing.letter;
    if (spacing.word != 0) {
        var codepoints = std.unicode.Utf8Iterator{ .bytes = shaped, .i = 0 };
        var first = true;
        while (codepoints.nextCodepoint()) |codepoint| {
            const lead = at_start and first;
            first = false;
            if (!isWordSeparator(codepoint)) continue;
            // Only U+0020 is exempt in the opening position. A U+00A0 there is
            // charged: `'\u00a0ab'` gains 5 from `word-spacing: 5px` where
            // `' ab'` gains nothing, and two leading U+00A0 gain 10 where two
            // leading U+0020 gain 5.
            if (lead and codepoint == ' ' and surface == .layout) continue;
            total += spacing.word;
        }
    }
    return total;
}

/// Whether `word-spacing` is charged for this codepoint.
pub fn isWordSeparator(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == 0xA0;
}

/// Whether a glyph draws nothing — the space, a zero-width control, or a
/// character the last resort font stands in for.
fn isBlank(glyph: font_metrics.Glyph) bool {
    return glyph.left == 0 and glyph.right == 0 and glyph.ascent == 0 and glyph.descent == 0;
}

/// Widens the ink box to hold one more glyph's edges, in pixels.
fn foldInk(ink_min: *f64, ink_max: *f64, any_ink: *bool, left_edge: f64, right_edge: f64) void {
    if (!any_ink.*) {
        ink_min.* = left_edge;
        ink_max.* = right_edge;
        any_ink.* = true;
        return;
    }
    ink_min.* = @min(ink_min.*, left_edge);
    ink_max.* = @max(ink_max.*, right_edge);
}

/// One colour emoji's advance and ink box, in CSS pixels at a given size.
const EmojiBox = struct {
    advance: f64,
    left: f64,
    right: f64,
    ascent: f64,
    descent: f64,
};

/// What headed Chrome answers for U+1F600 at sixteen sizes — the `sizes`
/// block of tools/fingerprint/results/probes/expr-emoji-text-metrics.chrome.json,
/// produced by
///
///   node tools/fingerprint/run-expr.mjs chrome \
///        tools/fingerprint/probes/expr-emoji-text-metrics.js --headed
///
/// A colour emoji is not linear in font-size the way a text glyph is. Apple
/// Color Emoji is a set of bitmap strikes rather than outlines, and Chrome
/// reports the strike it picked: below 24px the advance is wider than the em
/// box — 20 at 16px, where the em is 16 — and from 24px up it is the em
/// exactly. Run the probe headed or none of this holds; a headless Chrome
/// resolves the emoji font somewhere else and answers ten different widths
/// for these ten emoji instead of one.
///
/// The ink box is the same shape of measurement and equally unexplained: the
/// left edge sits one pixel before the pen at every size, not a fraction of
/// one, and the box is very nearly square.
const emoji_sizes = [_]struct {
    size: f64,
    advance: f64,
    ascent: f64,
    descent: f64,
    left: f64,
    right: f64,
}{
    .{ .size = 8, .advance = 10, .ascent = 9, .descent = 3, .left = 1, .right = 11 },
    .{ .size = 10, .advance = 13, .ascent = 11, .descent = 4, .left = 1, .right = 14 },
    .{ .size = 11, .advance = 14, .ascent = 12, .descent = 4, .left = 1, .right = 15 },
    .{ .size = 12, .advance = 15, .ascent = 13, .descent = 4, .left = 1, .right = 16 },
    .{ .size = 13, .advance = 16, .ascent = 14, .descent = 5, .left = 1, .right = 18 },
    .{ .size = 14, .advance = 18, .ascent = 15, .descent = 5, .left = 1, .right = 19 },
    .{ .size = 16, .advance = 20, .ascent = 17, .descent = 5, .left = 1, .right = 21 },
    .{ .size = 18, .advance = 21, .ascent = 19, .descent = 5, .left = 1, .right = 22 },
    .{ .size = 20, .advance = 22, .ascent = 20, .descent = 5, .left = 1, .right = 23 },
    .{ .size = 24, .advance = 24, .ascent = 23, .descent = 4, .left = 1, .right = 26 },
    .{ .size = 32, .advance = 32, .ascent = 30, .descent = 5, .left = 1, .right = 34 },
    .{ .size = 40, .advance = 40, .ascent = 37, .descent = 6, .left = 1, .right = 42 },
    .{ .size = 48, .advance = 48, .ascent = 44, .descent = 7, .left = 1, .right = 50 },
    .{ .size = 64, .advance = 64, .ascent = 58, .descent = 9, .left = 1, .right = 66 },
    .{ .size = 96, .advance = 96, .ascent = 86, .descent = 13, .left = 1, .right = 98 },
    .{ .size = 128, .advance = 128, .ascent = 114, .descent = 18, .left = 1, .right = 130 },
};

/// The emoji box at `size`: the measurement itself at a size we measured,
/// a straight line between the two nearest at a size in between, and the
/// nearest end scaled at a size outside the range. Only the first of those
/// three is Chrome's answer; the other two are what a table can offer.
fn emojiBox(size: f64) EmojiBox {
    const first = emoji_sizes[0];
    if (size <= first.size) return scaleBox(first, size / first.size);

    const last = emoji_sizes[emoji_sizes.len - 1];
    if (size >= last.size) return scaleBox(last, size / last.size);

    for (emoji_sizes[1..], 0..) |high, i| {
        if (size > high.size) continue;
        const low = emoji_sizes[i];
        const t = (size - low.size) / (high.size - low.size);
        return .{
            .advance = low.advance + (high.advance - low.advance) * t,
            .left = low.left + (high.left - low.left) * t,
            .right = low.right + (high.right - low.right) * t,
            .ascent = low.ascent + (high.ascent - low.ascent) * t,
            .descent = low.descent + (high.descent - low.descent) * t,
        };
    }
    unreachable;
}

fn scaleBox(row: @TypeOf(emoji_sizes[0]), factor: f64) EmojiBox {
    return .{
        .advance = row.advance * factor,
        .left = row.left * factor,
        .right = row.right * factor,
        .ascent = row.ascent * factor,
        .descent = row.descent * factor,
    };
}

/// Whether the shaped cluster `text` is drawn from a colour emoji font, which
/// is what decides whether it is measured from `emoji_sizes` or from the text
/// font. The rule is UTS #51's: an Emoji character carries its own default,
/// a variation selector overrides that default either way, and a joiner or a
/// skin tone modifier only ever appears in a sequence that is one.
///
/// The base has to be Emoji for any of it to apply, which is what keeps a
/// lone U+FE0F — Chrome measures it zero — from being charged an emoji, and
/// what keeps 'a' U+FE0F from turning into one.
fn isColourEmoji(text: []const u8) bool {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    const base = iterator.nextCodepoint() orelse return false;
    // The measured table wins over the Unicode property where it has a row.
    // Emoji_Presentation is a statement about the character, and what Chrome
    // draws is a statement about the fonts installed: U+261D and U+26AA are
    // both text-presentation characters that Arial cannot draw, so Chrome
    // reaches Apple Color Emoji for them and renders colour where the property
    // says it should not. Measured -- see emoji_presentation.zig.
    const tabulated = emoji_presentation.find(base);
    if (tabulated == null and !emoji_properties.isEmoji(base)) return false;

    var colour = if (tabulated) |row|
        row.bare_is_emoji
    else
        emoji_properties.isDefaultPresentation(base);
    while (iterator.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            VARIATION_SELECTOR_16, ZERO_WIDTH_JOINER => colour = true,
            VARIATION_SELECTOR_15 => colour = false,
            SKIN_TONE_FIRST...SKIN_TONE_LAST => colour = true,
            else => {},
        }
    }
    return colour;
}

/// A line box split at the baseline, in CSS pixels.
pub const LineBox = struct {
    above: f64 = 0,
    below: f64 = 0,
};

/// The line box a run of text forces open because of a glyph the requesting
/// family cannot draw, zero for a run that has none.
///
/// A line box is the FONT's, not the family's: `<div style="font:100px Arial">`
/// holding a U+2B05 is 150 tall in Chrome and not Arial's 115, because Arial has
/// no arrow and the font Chrome reached for has a taller line. Layout asks this
/// and raises the line to it; the strut stays the requesting family's, so the
/// taller of the two wins exactly the way an inline box with its own
/// `line-height` does.
///
/// A variation selector picks which of the two boxes a character opens --
/// U+FE0E the text font's, U+FE0F Apple Color Emoji's -- which is why this
/// cannot be answered a character at a time.
///
/// Called once per text node of a box being laid out, not once per character,
/// and it leaves after one byte comparison for a run of ordinary text.
/// Null -- not a zero box -- for a run that has none: a line box half is signed
/// (a font taller than its declared `line-height` gets a negative one), so a
/// caller that maxed a zero against the strut would clamp that half to zero and
/// make an empty block taller than Chrome does.
pub fn fallbackLineBox(text: []const u8, size: f64) ?LineBox {
    var result: LineBox = .{};
    if (!mayNeedFallbackLine(text)) return null;

    const raise = struct {
        fn one(into: *LineBox, above: f64, below: f64, at: f64) void {
            into.above = @max(into.above, above * at / emoji_presentation.basis);
            into.below = @max(into.below, below * at / emoji_presentation.basis);
        }
    }.one;

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    // The character a selector would apply to, held back until the next
    // character says whether one followed it.
    var pending: ?emoji_presentation.Glyph = null;
    var colour = false;
    var any = false;
    while (iterator.nextCodepoint()) |codepoint| {
        if (pending != null) {
            switch (codepoint) {
                VARIATION_SELECTOR_15 => {
                    colour = false;
                    continue;
                },
                VARIATION_SELECTOR_16 => {
                    colour = true;
                    continue;
                },
                else => {},
            }
        }
        if (pending) |row| {
            if (colour) {
                raise(&result, emoji_presentation.colour_above, emoji_presentation.colour_below, size);
            } else {
                raise(&result, row.above, row.below, size);
            }
            any = true;
        }
        pending = emoji_presentation.find(codepoint);
        colour = if (pending) |row| row.bare_is_emoji else false;
    }
    if (pending) |row| {
        if (colour) {
            raise(&result, emoji_presentation.colour_above, emoji_presentation.colour_below, size);
        } else {
            raise(&result, row.above, row.below, size);
        }
        any = true;
    }
    return if (any) result else null;
}

/// Whether any byte of `text` could begin a tabulated character. Every row of
/// emoji_presentation.zig is non-ASCII, so a run of plain text leaves on the
/// first byte and never decodes anything.
fn mayNeedFallbackLine(text: []const u8) bool {
    for (text) |byte| {
        if (starts_a_presentation_glyph[byte]) return true;
    }
    return false;
}

/// Derived from the table so it cannot drift out of step with it.
const starts_a_presentation_glyph = blk: {
    var table = [_]bool{false} ** 256;
    for (emoji_presentation.glyphs) |row| {
        var encoded: [4]u8 = undefined;
        _ = std.unicode.utf8Encode(row.codepoint, &encoded) catch unreachable;
        table[encoded[0]] = true;
    }
    break :blk table;
};

/// What an unmeasured glyph is charged. Not a Chrome number.
///
/// The mean is over printable ASCII, not over the whole table. The table
/// reaches U+00FF now, and averaging the C1 controls in — each a flat em —
/// would move this number for every codepoint above U+00FF, a surface we have
/// not measured and did not mean to change.
fn meanAdvance(family: font_metrics.Family) f64 {
    const ascii = family.glyphs[0 .. font_metrics.last_ascii_codepoint - font_metrics.first_codepoint + 1];
    var total: f64 = 0;
    for (ascii) |glyph| total += glyph.advance;
    return total / @as(f64, @floatFromInt(ascii.len));
}

// `measure` runs per text-only element that `document.elementFromPoint` walks
// past, and pages call that in scroll and IntersectionObserver handlers. On
// kohls.com 375 such calls spent 18.5s of a 19s run inside text measurement,
// which is what turned a page load into a wedged `Runtime.evaluate`. Almost
// all of it was `emoji_metrics.match` walking its whole 91-cluster table at
// every character position of every string, so a run of plain text paid 91
// prefix comparisons per character to be told what its lead byte already says.
//
// The bound is wall clock, which is the only thing this defect shows up in, so
// it is set well clear of both sides rather than tight against one. Measured
// here (debug build, Apple silicon): 3.9s with the whole-table walk, 0.48s
// without it.
test "text_measure: the word memo answers what measuring answers" {
    // The memo is keyed on every argument `measureAt` varies on, so the risk it
    // carries is an alias: two questions that share a slot and a comparison but
    // not an answer. The faces below differ one field at a time, and the second
    // pass over the whole matrix is the one that reads the memo -- the first
    // only fills it.
    const spaced: Spacing = .{ .letter = 1.5, .word = 3 };
    const faces = [_]Face{
        .regular(font_metrics.serif),
        // Same family, but `of` resolves the variant table `regular` leaves
        // empty: identical on every other field, and not the same face.
        .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .none),
        .of(font_metrics.serif, 700, false, .{}, .layout, true, .none, .none),
        .of(font_metrics.serif, 400, true, .{}, .layout, true, .none, .none),
        .of(font_metrics.serif, 400, false, .{}, .canvas, true, .none, .none),
        .of(font_metrics.serif, 400, false, .{}, .layout, false, .none, .none),
        .of(font_metrics.serif, 400, false, spaced, .layout, true, .none, .none),
        .of(font_metrics.serif, 400, false, .{}, .layout, true, .uppercase, .none),
        .of(font_metrics.serif, 400, false, .{}, .layout, true, .lowercase, .none),
        .of(font_metrics.serif, 400, false, .{}, .layout, true, .capitalize, .none),
        .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .lowercase),
        .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .all),
        .of(font_metrics.sans_serif, 400, false, .{}, .layout, true, .none, .none),
        .of(font_metrics.monospace, 400, false, .{}, .layout, true, .none, .none),
    };
    const words = [_][]const u8{
        "",
        "a",
        "Free",
        "shipping",
        "AVATAR",
        "\u{00df}xy",
        "caf\u{00e9}",
        "\u{1F600}",
        // Past `word_memo_max_len`, where the memo steps aside.
        "Donaudampfschifffahrtsgesellschaftskapitaen",
    };
    const sizes = [_]f64{ 0, 10, 13.3333, 16, 72 };

    for (0..2) |_| {
        for (faces) |face| {
            for (sizes) |size| {
                for (words) |word| {
                    for ([_]bool{ true, false }) |start| {
                        var want_flag = start;
                        const want = measureAt(face, word, size, &want_flag).width;
                        var got_flag = start;
                        const got = widthAt(face, word, size, &got_flag);
                        try std.testing.expectEqual(want, got);
                        try std.testing.expectEqual(want_flag, got_flag);
                    }
                }
            }
        }
    }
}

test "text_measure: plain text is not charged for the emoji table" {
    const iterations = 60_000;
    const line = "Free shipping on orders over 49";

    const started = lp.datetime.microTimestamp(.boot);
    var total: f64 = 0;
    for (0..iterations) |_| {
        total += measure(Face.regular(font_metrics.sans_serif), line, 16).width;
    }
    const elapsed_ms = (lp.datetime.microTimestamp(.boot) - started) / 1000;

    // Read back so the loop cannot be optimised away.
    try std.testing.expectEqual(@as(f64, 226.796875 * iterations), total);
    try std.testing.expect(elapsed_ms < 1200);
}

// The lead-byte gate in front of that table walk is only sound while every
// cluster in the table really does start with a byte the gate admits. The
// table is generated, so this asks the table itself rather than restating it.
test "text_measure: every emoji cluster is still reachable" {
    for (emoji_metrics.clusters) |cluster| {
        const found = emoji_metrics.match(cluster.text) orelse {
            std.debug.print("\nunreachable cluster: {s}\n", .{cluster.text});
            return error.ClusterNotFound;
        };
        // Longest-first ordering means the answer for a cluster's own text is
        // either itself or a longer cluster that starts with it.
        try std.testing.expect(std.mem.startsWith(u8, found.text, cluster.text) or
            std.mem.startsWith(u8, cluster.text, found.text));
        try std.testing.expect(measure(Face.regular(font_metrics.sans_serif), cluster.text, 100).width > 0);
    }

    // A lead byte no cluster uses, and the empty string, are both misses.
    try std.testing.expectEqual(@as(?emoji_metrics.Cluster, null), emoji_metrics.match(""));
    try std.testing.expectEqual(@as(?emoji_metrics.Cluster, null), emoji_metrics.match("a"));
    try std.testing.expectEqual(@as(?emoji_metrics.Cluster, null), emoji_metrics.match("\u{00e9}"));
}

test "text_measure: the space pairs Chrome kerns in layout and not in the canvas" {
    // The generated table's own reason for existing, checked against the two
    // readings in its header. 'AVATAR To Wo' at 16px serif is 105.4140625
    // through getBoundingClientRect and 105.9765625 through measureText -- both
    // of those are Chrome -- and the 0.5625 between them is exactly the two
    // space pairs in the string: U+0020 before 'T' and U+0020 before 'W'.
    const serif = font_space_kerning.tableFor(font_metrics.serif, .regular);
    try std.testing.expectEqual(@as(f64, -225.0 / 128.0), font_kerning.kern(serif, ' ', 'T'));
    try std.testing.expectEqual(@as(f64, -225.0 / 128.0), font_kerning.kern(serif, ' ', 'W'));
    try std.testing.expectEqual(@as(f64, -0.5625), (font_kerning.kern(serif, ' ', 'T') +
        font_kerning.kern(serif, ' ', 'W')) * 16.0 / font_metrics.basis);

    // Both directions for 'A', one direction only for 'L' and 'P': a space
    // before either of those two is not a pair, which is why the table is a
    // list of pairs and not a set of characters.
    try std.testing.expectEqual(@as(f64, -700.0 / 128.0), font_kerning.kern(serif, ' ', 'A'));
    try std.testing.expectEqual(@as(f64, -700.0 / 128.0), font_kerning.kern(serif, 'A', ' '));
    try std.testing.expectEqual(@as(f64, -469.0 / 128.0), font_kerning.kern(serif, 'L', ' '));
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(serif, ' ', 'L'));

    // Per family, and not a constant: sans-serif kerns a space against 'A',
    // 'T' and 'Y' but not against 'V' or 'W', and Verdana kerns none at all --
    // its 'AVATAR To Wo' is the same width through both surfaces.
    const sans = font_space_kerning.tableFor(font_metrics.sans_serif, .regular);
    try std.testing.expectEqual(@as(f64, -225.0 / 128.0), font_kerning.kern(sans, ' ', 'T'));
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(sans, ' ', 'W'));
    const verdana = font_space_kerning.tableFor(font_metrics.verdana, .regular);
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(verdana, ' ', 'A'));
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(verdana, ' ', 'T'));

    // And nothing outside the space pairs leaked in: this table carries only
    // the ones the canvas misses, so 'AV' -- which the canvas does kern -- is
    // not in it.
    try std.testing.expectEqual(@as(f64, 0), font_kerning.kern(serif, 'A', 'V'));
}

test "text_measure: the kerning bit turns off both tables" {
    // `element/text_kerning_off.html` asserts this through the CSS layer; this
    // asserts the kernel on its own, because the bit has to reach two tables and
    // the CSS test cannot say which of them answered.
    const on: Face = .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .none);
    const off: Face = .of(font_metrics.serif, 400, false, .{}, .layout, false, .none, .none);

    // The ordinary pairs. 'AV' at 16px serif is 21.046875 kerned and 23.109375
    // unkerned -- both Chrome's, both this engine's advance table.
    try std.testing.expectEqual(@as(f64, 21.046875), measure(on, "AV", 16).width);
    try std.testing.expectEqual(@as(f64, 23.109375), measure(off, "AV", 16).width);

    // The space pairs, which only the layout surface charges. Empty when the bit
    // is off, so `kernBetween` -- the caller that prices a space between two
    // separate measurements -- answers zero without knowing about the bit.
    try std.testing.expectEqual(@as(f64, -0.28125), kernBetween(on, ' ', 'T', 16));
    try std.testing.expectEqual(@as(f64, 0), kernBetween(off, ' ', 'T', 16));

    // And both at once: 'AVATAR To Wo' is 105.4140625 in layout, and the
    // 10.125 the switch adds is 9.5625 of ordinary pairs plus 0.5625 of space
    // pairs. Leaving the space table on would land on 114.9765625.
    try std.testing.expectEqual(@as(f64, 105.4140625), measure(on, "AVATAR To Wo", 16).width);
    try std.testing.expectEqual(@as(f64, 115.5390625), measure(off, "AVATAR To Wo", 16).width);

    // The canvas surface has no space table either way, so the bit is the only
    // difference there -- and its unkerned width is the same 115.5390625,
    // because with no pairs at all the two surfaces cannot disagree.
    const canvas_on: Face = .of(font_metrics.serif, 400, false, .{}, .canvas, true, .none, .none);
    const canvas_off: Face = .of(font_metrics.serif, 400, false, .{}, .canvas, false, .none, .none);
    try std.testing.expectEqual(@as(f64, 105.9765625), measure(canvas_on, "AVATAR To Wo", 16).width);
    try std.testing.expectEqual(@as(f64, 115.5390625), measure(canvas_off, "AVATAR To Wo", 16).width);
}

test "text_measure: reproduces Chrome's measureText" {
    // Straight from sections.text of the graphics dump.
    const sample = measure(Face.regular(font_metrics.sans_serif), "mmmmmmmmmmlli", 10);
    try std.testing.expectEqual(@as(f64, 89.9658203125), sample.width);
    try std.testing.expectEqual(@as(f64, -0.64453125), sample.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 89.2822265625), sample.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 10), sample.fontBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2), sample.fontBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 7.1728515625), sample.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 0), sample.actualBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 8), sample.hangingBaseline);
    try std.testing.expectEqual(@as(f64, 0), sample.alphabeticBaseline);
    try std.testing.expectEqual(@as(f64, -2), sample.ideographicBaseline);

    const pangram = measure(Face.regular(font_metrics.arial), "Cwm fjordbank glyphs vext quiz", 14);
    try std.testing.expectEqual(@as(f64, 196.861328125), pangram.width);
    try std.testing.expectEqual(@as(f64, -0.697265625), pangram.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 196.560546875), pangram.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 13), pangram.fontBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 3), pangram.fontBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 10.1923828125), pangram.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2.9462890625), pangram.actualBoundingBoxDescent);
    try std.testing.expectEqual(@as(f64, 10.399999618530273), pangram.hangingBaseline);
    try std.testing.expectEqual(@as(f64, -3), pangram.ideographicBaseline);

    const empty = measure(Face.regular(font_metrics.sans_serif), "", 10);
    try std.testing.expectEqual(@as(f64, 0), empty.width);
    try std.testing.expectEqual(@as(f64, 0), empty.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 0), empty.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 10), empty.fontBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 8), empty.hangingBaseline);

    // Exactly linear in size, which is why one table is enough.
    try std.testing.expectEqual(@as(f64, 8.330078125), measure(Face.regular(font_metrics.sans_serif), "m", 10).width);
    try std.testing.expectEqual(@as(f64, 83.30078125), measure(Face.regular(font_metrics.sans_serif), "m", 100).width);
    try std.testing.expectEqual(@as(f64, 899.658203125), measure(Face.regular(font_metrics.sans_serif), "mmmmmmmmmmlli", 100).width);

    // Sums of advances, all of which Chrome agrees with.
    try std.testing.expectEqual(@as(f64, 55.01953125), measure(Face.regular(font_metrics.sans_serif), "Hello, world!", 10).width);
    try std.testing.expectEqual(@as(f64, 140.615234375), measure(Face.regular(font_metrics.sans_serif), "Cwm fjordbank glyphs vext quiz", 10).width);
    try std.testing.expectEqual(@as(f64, 28.3154296875), measure(Face.regular(font_metrics.sans_serif), "WWW", 10).width);
    try std.testing.expectEqual(@as(f64, 6.6650390625), measure(Face.regular(font_metrics.sans_serif), "iii", 10).width);

    // The kerned pairs, where we knowingly differ: Chrome says 12.6025390625
    // and 10.5615234375 because it kerns; we report the plain sums.
    // 12.6025390625 and not 13.33984375, which is the sum of the two advances:
    // 'AV' is a kerning pair and this used to answer the sum. The number on the
    // right is the one this file's own header carried for a long time as
    // Chrome's, beside the note that we did not model kerning.
    try std.testing.expectEqual(@as(f64, 12.6025390625), measure(Face.regular(font_metrics.sans_serif), "AV", 10).width);
    try std.testing.expectEqual(@as(f64, 10.5615234375), measure(Face.regular(font_metrics.sans_serif), "To", 10).width);
}

test "text_measure: the system face's advances are not linear in size" {
    // Chrome's own layout widths, read off a `width: max-content` box at device
    // pixel ratio 2 (scratch/s106/expr-fixtures.js). Sixty-four copies of one
    // glyph: kern-free by construction, so this is the advance model and
    // nothing else, and long enough that the box's 1/256px quantisation is a
    // rounding error rather than the answer.
    //
    // `measureText` is deliberately not the channel here. For this face alone
    // the canvas reports a wrong optical instance for a whole size at a time,
    // at random -- see tools/fingerprint/dump-font-optical.mjs.
    const face = Face.regular(font_metrics.system_ui);
    const run = "x" ** 64;
    // One unit of the 1/256px grid a box width lands on, and not half of it:
    // Chrome does not round the run's total to the nearest unit. Sixty-four
    // copies of 'x' at 8px read 281.671875 where 128 copies read 563.33594,
    // which is 72108 and 144214 units -- the shorter run is a unit above half
    // the longer one, so a sum this close is as close as a reading gets.
    const slack = 1.0 / 256.0;
    const rows = [_]struct { f64, f64 }{
        // Below 6px the tracking has saturated: the same per-em advance.
        .{ 1, 36.125 },
        .{ 6, 216.75 },
        .{ 8, 281.671875 },
        // A scale of the 100px table would answer 16 * 29.96875 = 479.5 here.
        .{ 16, 517 },
        .{ 17, 542.9375 },
        // The crossing band is checked below, at its own slack.
        // From 28px up it is the 100px table plus a tracking that reaches zero
        // at 80: 28 * 29.96875 is 839.125, and the 24.5 between them is it.
        .{ 28, 863.625 },
        .{ 32, 985 },
        .{ 48, 1461 },
        .{ 80, 2397.5 },
        .{ 100, 2996.875 },
        // Between two whole sizes the ladder is interpolated, not the width.
        .{ 16.5, 530.0625 },
    };
    for (rows) |row| {
        try std.testing.expectApproxEqAbs(row[1], measure(face, run, row[0]).width, slack);
    }

    // 18..27px, where neither master is the answer and the model interpolates
    // between them. It is a WORSE fit there and this records how much: the
    // crossing is not exactly a linear blend, so the per-glyph residual is up
    // to 2.7e-4 em, which over sixty-four copies is the third of a pixel below.
    // Every other size in this test is inside the 1/256px a reading resolves.
    //
    // Closing it means storing the ten band sizes as their own tables rather
    // than interpolating -- ten more per face -- and the kerning gap in the
    // same range is an order of magnitude larger, so that comes first.
    const band_slack = 0.35;
    try std.testing.expectApproxEqAbs(@as(f64, 573.1875), measure(face, run, 18).width, band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 679.9375), measure(face, run, 22).width, band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 739.5), measure(face, run, 24).width, band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 832.359375), measure(face, run, 27).width, band_slack);
    // A fractional size inside the band inherits the band's residual.
    try std.testing.expectApproxEqAbs(@as(f64, 695.0390625), measure(face, run, 22.5).width, band_slack);

    // Three more glyphs at one small and one large size, because the
    // correction below the crossing is PER GLYPH and a single glyph could be
    // fitted by a scale.
    try std.testing.expectApproxEqAbs(@as(f64, 875), measure(face, "M" ** 64, 16).width, slack);
    try std.testing.expectApproxEqAbs(@as(f64, 284), measure(face, "." ** 64, 16).width, slack);
    try std.testing.expectApproxEqAbs(@as(f64, 268), measure(face, " " ** 64, 16).width, slack);
    try std.testing.expectApproxEqAbs(@as(f64, 5318.75), measure(face, "M" ** 64, 100).width, slack);
    try std.testing.expectApproxEqAbs(@as(f64, 1375), measure(face, "." ** 64, 100).width, slack);

    // And a family that is not optically sized stays exactly linear, which is
    // what `font_metrics.zig`'s header claims for the other 203 names.
    const sans = Face.regular(font_metrics.sans_serif);
    try std.testing.expectEqual(
        measure(sans, run, 100).width / 100 * 16,
        measure(sans, run, 16).width,
    );
}

test "text_measure: the system face's weight is an axis and not two faces" {
    // Chrome's own layout widths again (scratch/s107/expr-wfixtures.js), same
    // channel and same sixty-four kern-free copies as the test above.
    //
    // SF's `wght` is continuous, so `bold` is the point 700 on an axis rather
    // than a second face. Before this, everything below 600 measured as 400 and
    // everything at or above it measured as 700 -- `font-weight: 500` was as
    // wide as an unstyled paragraph and `600` was as wide as `bold`, which is
    // what the Cloudflare challenge page's h1 asks for and got wrong by 1.24%.
    const at = struct {
        fn f(weight: u16, italic: bool, size: f64, ch: []const u8) f64 {
            const face = Face.of(font_metrics.system_ui, weight, italic, .{}, .canvas, true, .none, .none);
            var buf: [64 * 4]u8 = undefined;
            var n: usize = 0;
            for (0..64) |_| {
                @memcpy(buf[n..][0..ch.len], ch);
                n += ch.len;
            }
            return measure(face, buf[0..n], size).width;
        }
    }.f;
    const slack = 1.0 / 256.0;
    // The three masters and the seven points between them, at a DISPLAY size.
    // Every hundred is its own width: eleven readings, no two the same.
    const display = [_]struct { u16, f64 }{
        .{ 1, 2600 },       .{ 100, 2700 },     .{ 200, 2796.875 }, .{ 300, 2896.875 },
        .{ 400, 2996.875 }, .{ 500, 3125 },     .{ 600, 3250 },     .{ 700, 3378.125 },
        .{ 800, 3503.125 }, .{ 900, 3628.125 }, .{ 1000, 3756.25 },
    };
    // Between the masters the model interpolates, and the residual it carries
    // is the 2.4e-4 em a held-out weight measured at -- 0.024px a glyph at
    // 100px, so 1.6px over sixty-four copies. The masters themselves are exact.
    //
    // Closing that means storing more than three weights, and the kerning gap
    // on the same axis is an order of magnitude larger (13.7px on one line of
    // the challenge page against 1.6px here), so that comes first.
    const weightSlack = struct {
        fn f(size: f64) f64 {
            return 64 * 2.6e-4 * size;
        }
    }.f;
    // Inside 18..27px neither optical master is the answer either, and that
    // band carries its own 2.7e-4 em on top. See the test above.
    const band_slack = 0.35;
    for (display) |row| {
        const master = row[0] == 1 or row[0] == 400 or row[0] == 1000;
        try std.testing.expectApproxEqAbs(row[1], at(row[0], false, 100, "x"), if (master) slack else weightSlack(100));
    }
    // Strictly increasing, which no pair of tables could be.
    for (1..display.len) |i| {
        try std.testing.expect(at(display[i][0], false, 100, "x") > at(display[i - 1][0], false, 100, "x"));
    }

    // The TEXT master moves with the weight too, and by a DIFFERENT amount:
    // 1 -> 1000 is 1.445x at 100px and 1.333x at 16px, so one axis cannot be
    // derived from the other by a scale.
    try std.testing.expectApproxEqAbs(@as(f64, 474), at(1, false, 16, "x"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 517), at(400, false, 16, "x"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 632), at(1000, false, 16, "x"), slack);
    // And inside the crossing band, where both masters and both axes are live.
    try std.testing.expectApproxEqAbs(@as(f64, 649.5), at(1, false, 24, "x"), band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 739.5), at(400, false, 24, "x"), band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 920.25), at(1000, false, 24, "x"), band_slack);

    // Per glyph, not a scale of one: 'W' grows 16.6% from master to master and
    // '.' grows 34.5%.
    try std.testing.expectApproxEqAbs(@as(f64, 4893.75), at(1, false, 100, "M"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 5703.125), at(1000, false, 100, "M"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 3250), at(1, false, 100, "o"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 3934.375), at(1000, false, 100, "o"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 5525), at(1, false, 100, "W"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 6443.75), at(1000, false, 100, "W"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 1268.75), at(1, false, 100, "."), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 1706.25), at(1000, false, 100, "."), slack);

    // The italic is a second roman with its own three masters, and at weight
    // 400 it is NOT the upright -- 2996.875 in both is a coincidence of 'x' at
    // this size, which 16px separates.
    try std.testing.expectApproxEqAbs(@as(f64, 2665.625), at(1, true, 100, "x"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 2996.875), at(400, true, 100, "x"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 3821.875), at(1000, true, 100, "x"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 519.5), at(400, true, 16, "x"), slack);
    try std.testing.expect(at(400, true, 16, "x") != at(400, false, 16, "x"));

    // The memo the measurements go through keys on the weight. Without this the
    // seven weights above came back as exactly TWO distinct widths -- whichever
    // side of 600 was measured first -- and every fixture here still passed,
    // because the test would have measured each one first.
    const one = at(475, false, 100, "x");
    _ = at(476, false, 100, "x");
    try std.testing.expectEqual(one, at(475, false, 100, "x"));
    try std.testing.expect(at(475, false, 100, "x") != at(476, false, 100, "x"));

    // A family with no optical table ignores the weight beyond the variant it
    // already chose: 400 and 500 are one table there, and both are the regular.
    const helvetica = struct {
        fn f(weight: u16) f64 {
            const face = Face.of(font_metrics.sans_serif, weight, false, .{}, .canvas, true, .none, .none);
            return measure(face, "x" ** 64, 100).width;
        }
    }.f;
    try std.testing.expectEqual(helvetica(400), helvetica(500));
}

test "text_measure: the system face's kerning pairs are optical too" {
    // Chrome's own max-content widths again (scratch/s108/expr-k6.js), read
    // through layout for the same reason the advances are.
    //
    // The pairs move with the optical size the way the advances do, and the two
    // masters are not a scaling of each other: 1612 pairs of SF kern at 17px
    // and not at 100, and 1044 the other way round. 'DZ' below is one of the
    // first kind and 'Fo' one of the second, so a model that scaled one table
    // would have to get both of them wrong.
    const at = struct {
        fn f(italic: bool, size: f64, text: []const u8) f64 {
            const face = Face.of(font_metrics.system_ui, 400, italic, .{}, .layout, true, .none, .none);
            return measure(face, text, size).width;
        }
    }.f;
    // Half of the 1/64px grid a box width lands on. These are single strings
    // rather than the sixty-four copies the advance fixtures use, so there is
    // nothing to average the rounding away: 'AV' at 13px reads 16.546875, which
    // is 1059 units, and the model's unrounded 16.54199 is 1058.69 of them.
    const slack = 1.0 / 128.0;
    // On either master, where the model is the reading. 17px and below is TEXT,
    // 28px and up is DISPLAY.
    const rows = [_]struct { f64, []const u8, f64 }{
        .{ 8, "AV", 10.6875 },
        .{ 13, "AV", 16.546875 },
        .{ 17, "AV", 20.96875 },
        .{ 28, "AV", 34.03125 },
        .{ 100, "AV", 118.8046875 },
        // Kerns at TEXT and not at DISPLAY: -0.5px of the 17px reading, and
        // nothing at all of the 100px one.
        .{ 17, "DZ", 22.2421875 },
        .{ 100, "DZ", 129.546875 },
        // And the other way round.
        .{ 17, "Fo", 18.9140625 },
        .{ 100, "Fo", 103.90625 },
        // The challenge page's own h1, which is where this face is measured in
        // anger, and a string whose ", " pair is in the space table -- that one
        // is -4.88 at the basis and gone entirely by 17px.
        .{ 13, "Verify you are human", 127.6640625 },
        .{ 17, "Verify you are human", 160.296875 },
        .{ 100, "Verify you are human", 871.4375 },
        .{ 17, "Hello, world.", 94.1640625 },
        .{ 100, "Hello, world.", 501.90625 },
        .{ 17, "To Wa Ya", 69.4609375 },
        .{ 100, "To Wa Ya", 376.421875 },
    };
    for (rows) |row| {
        try std.testing.expectApproxEqAbs(row[2], at(false, row[0], row[1]), slack);
    }
    // The italic has its own pairs: 4908 of them against the upright's 4501.
    try std.testing.expectApproxEqAbs(@as(f64, 161.4453125), at(true, 17, "Verify you are human"), slack);
    try std.testing.expectApproxEqAbs(@as(f64, 893.0703125), at(true, 100, "Verify you are human"), slack);

    // 18..27px, where the pairs cross between the masters on the same ladder
    // the advances do and the blend is approximate in the same way. 0.09px over
    // a twenty-character line, against the 12.2px the DISPLAY pairs alone were
    // out by at 17px before this.
    const band_slack = 0.1;
    try std.testing.expectApproxEqAbs(@as(f64, 169.0703125), at(false, 18, "Verify you are human"), band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 199.2890625), at(false, 22, "Verify you are human"), band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 215.875), at(false, 24, "Verify you are human"), band_slack);
    try std.testing.expectApproxEqAbs(@as(f64, 242.734375), at(false, 27, "Verify you are human"), band_slack);

    // A family with no optical table kerns the way it always did: exactly
    // linear in the size, pairs included.
    const sans = Face.of(font_metrics.sans_serif, 400, false, .{}, .layout, true, .none, .none);
    try std.testing.expectEqual(
        measure(sans, "AV Wa To", 100).width / 100 * 17,
        measure(sans, "AV Wa To", 17).width,
    );
}

test "text_measure: the ten strings the Turnstile widget actually measures" {
    // Not emoji. The widget hands measureText the UTF-8 bytes of each emoji
    // read back as Latin-1, so U+1F600 arrives as U+00F0 U+009F U+0098 U+0080
    // -- traced live on the challenge page, where both engines record the same
    // four code points, so it is the page's own mojibake and not a decoding
    // bug on either side.
    //
    // Every number is headed Chrome's, from the `strings` block of
    // results/probes/expr-turnstile-mojibake-metrics.chrome.json at
    // 16px sans-serif.
    const sans = font_metrics.sans_serif;
    const cases = [_]struct { text: []const u8, width: f64, ascent: f64, descent: f64 }{
        // All three land on 56.898, by two different routes. U+1F44D is
        // F0 9F 91 8D, where the last three code points have no glyph in any
        // font and cost an em each outright. U+1F600 and U+1F680 end in 0x80,
        // which some fallback font *does* draw at 8.898 -- but by then the run
        // is on the last resort, so it costs an em too.
        .{ .text = "\u{f0}\u{9f}\u{98}\u{80}", .width = 56.8984375, .ascent = 12.6796875, .descent = 0.2890625 },
        .{ .text = "\u{f0}\u{9f}\u{91}\u{8d}", .width = 56.8984375, .ascent = 12.6796875, .descent = 0.2890625 },
        .{ .text = "\u{f0}\u{9f}\u{9a}\u{80}", .width = 56.8984375, .ascent = 12.6796875, .descent = 0.2890625 },
        // A4 and A3 are Latin-1 letters the primary font draws, so they cost
        // their own 8.898 rather than the fallback's em.
        .{ .text = "\u{f0}\u{9f}\u{a4}\u{a3}", .width = 42.6953125, .ascent = 12.6796875, .descent = 0.2890625 },
        .{ .text = "\u{f0}\u{9f}\u{98}\u{b1}", .width = 49.6796875, .ascent = 12.6796875, .descent = 0.2890625 },
        .{ .text = "\u{f0}\u{9f}\u{94}\u{a5}", .width = 49.796875, .ascent = 12.6796875, .descent = 0.2890625 },
        // A7 (section sign) is what drops below the baseline here.
        .{ .text = "\u{f0}\u{9f}\u{a7}\u{a0}", .width = 38.2421875, .ascent = 12.6796875, .descent = 3.375 },
        .{ .text = "\u{f0}\u{9f}\u{90}\u{b6}", .width = 49.4921875, .ascent = 12.6796875, .descent = 2.8359375 },
        .{ .text = "\u{f0}\u{9f}\u{8f}\u{a0}", .width = 45.34375, .ascent = 12.6796875, .descent = 0.2890625 },
        // Six code points, not four: U+2600 U+FE0F is E2 98 80 EF B8 8F. The
        // ink is â's and ¸'s, which is why this one alone reports a different
        // ascent from the other nine.
        .{
            .text = "\u{e2}\u{98}\u{80}\u{ef}\u{b8}\u{8f}",
            .width = 66.671875,
            .ascent = 11.734375,
            .descent = 3.6015625,
        },
    };
    for (cases) |case| {
        const metrics = measure(Face.regular(sans), case.text, 16);
        try std.testing.expectEqual(case.width, metrics.width);
        try std.testing.expectEqual(case.ascent, metrics.actualBoundingBoxAscent);
        try std.testing.expectEqual(case.descent, metrics.actualBoundingBoxDescent);
    }
}

test "text_measure: one fallback font per run, seeded by the first character that needs it" {
    // From the `runs` and `battery` blocks of
    // results/probes/expr-latin1-context-advance.js's headed Chrome reading.
    // U+0080 is the interesting one: the primary font does not draw it, some
    // fallback font does, and whether it gets that font depends on what the
    // run already settled on.
    const width = struct {
        fn f(text: []const u8) f64 {
            return measure(Face.regular(font_metrics.sans_serif), text, 16).width;
        }
    }.f;

    // Alone, and beside characters the primary font draws, it is 8.898.
    try std.testing.expectEqual(@as(f64, 8.8984375), width("\u{80}"));
    try std.testing.expectEqual(@as(f64, 17.796875), width("\u{80}\u{80}"));
    try std.testing.expectEqual(@as(f64, 17.796875), width("a\u{80}"));
    try std.testing.expectEqual(@as(f64, 17.796875), width("\u{80}a"));

    // Behind a character no font draws, it is a flat em instead -- U+0098 went
    // to the last resort font and U+0080 followed it there.
    try std.testing.expectEqual(@as(f64, 32), width("\u{98}\u{80}"));
    try std.testing.expectEqual(@as(f64, 32), width("\u{9f}\u{80}"));
    try std.testing.expectEqual(@as(f64, 48), width("\u{98}\u{80}\u{80}"));
    // Whereas in front of one it keeps its glyph: nothing had reseeded yet.
    try std.testing.expectEqual(@as(f64, 24.8984375), width("\u{80}\u{98}"));

    // The seed is chosen once, for the whole run. A character the primary font
    // *does* draw in between does not give the glyph back...
    try std.testing.expectEqual(@as(f64, 40.8984375), width("\u{98}a\u{80}"));
    try std.testing.expectEqual(@as(f64, 40.8984375), width("\u{98}\u{f0}\u{80}"));
    try std.testing.expectEqual(@as(f64, 36.4453125), width("\u{98}\u{a0}\u{80}"));
    // ... and a glyph-less character *after* the seeding does not take it away.
    try std.testing.expectEqual(@as(f64, 33.796875), width("\u{80}\u{98}\u{80}"));

    // The other three C1 controls with a glyph move the same way, so this is
    // about the fallback font rather than about U+0080.
    try std.testing.expectEqual(@as(f64, 6.4375), width("\u{81}"));
    try std.testing.expectEqual(@as(f64, 7.046875), width("\u{82}"));
    try std.testing.expectEqual(@as(f64, 15.203125), width("\u{84}"));
    try std.testing.expectEqual(@as(f64, 64), width("\u{98}\u{81}\u{82}\u{84}"));

    // U+00C6 is an em wide and is *not* one of them: it has ink, the primary
    // font draws it, and it neither seeds the last resort nor loses anything
    // behind it. That is what keeps "an em wide" from being the test.
    try std.testing.expectEqual(@as(f64, 16), width("\u{c6}"));
    try std.testing.expectEqual(@as(f64, 24.8984375), width("\u{c6}\u{80}"));

    // U+007F draws nothing, and a character that draws nothing does not get to
    // pick the run's font. So it is transparent: U+0080 behind it still seeds
    // its own, and a U+0098 behind it still seeds the last resort.
    try std.testing.expectEqual(@as(f64, 0), width("\u{7f}"));
    try std.testing.expectEqual(@as(f64, 8.8984375), width("\u{7f}\u{80}"));
    try std.testing.expectEqual(@as(f64, 32), width("\u{7f}\u{98}\u{80}"));
    // Behind the last resort it is not zero any more, but half an em.
    try std.testing.expectEqual(@as(f64, 24), width("\u{98}\u{7f}"));
}

test "text_measure: an ink boundary can be negative" {
    // A running max seeded at zero can only ever report a positive boundary,
    // and Chrome reports both signs: a quotation mark's ink is wholly above
    // the baseline, so its descent is negative, and U+0084's is wholly below,
    // so its ascent is. Headed Chrome at 16px sans-serif, from the
    // perCodePoint block of expr-turnstile-mojibake-metrics.chrome.json.
    const sans = font_metrics.sans_serif;
    const quote = measure(Face.regular(sans), "\"", 16);
    try std.testing.expectEqual(@as(f64, 11.4765625), quote.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, -6.8828125), quote.actualBoundingBoxDescent);

    const underscore = measure(Face.regular(sans), "_", 16);
    try std.testing.expectEqual(@as(f64, -1.2109375), underscore.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2), underscore.actualBoundingBoxDescent);

    const c1 = measure(Face.regular(sans), "\u{84}", 16);
    try std.testing.expectEqual(@as(f64, -1.59375), c1.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2), c1.actualBoundingBoxDescent);

    // Still a max once there is more than one glyph: the quotation mark's
    // negative descent loses to the comma's positive one, and the underscore's
    // negative ascent loses to the quotation mark's.
    const both = measure(Face.regular(sans), "\",", 16);
    try std.testing.expectEqual(@as(f64, 11.4765625), both.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2.375), both.actualBoundingBoxDescent);
    const pair = measure(Face.regular(sans), "_\"", 16);
    try std.testing.expectEqual(@as(f64, 11.4765625), pair.actualBoundingBoxAscent);
    try std.testing.expectEqual(@as(f64, 2), pair.actualBoundingBoxDescent);
}

test "text_measure: a colour emoji measures the strike Chrome picked" {
    // Every number here is headed Chrome's, from the `emoji` and `clusters`
    // blocks of results/probes/expr-emoji-text-metrics.chrome.json. The
    // Turnstile widget measures its ten at exactly this font.
    const sans = font_metrics.sans_serif;
    for ([_][]const u8{ "😀", "🤣", "😱", "👍", "🔥", "🚀", "🧠", "🐶", "🏠", "☀️" }) |emoji| {
        const metrics = measure(Face.regular(sans), emoji, 16);
        try std.testing.expectEqual(@as(f64, 20), metrics.width);
        try std.testing.expectEqual(@as(f64, 1), metrics.actualBoundingBoxLeft);
        try std.testing.expectEqual(@as(f64, 21), metrics.actualBoundingBoxRight);
        try std.testing.expectEqual(@as(f64, 17), metrics.actualBoundingBoxAscent);
        try std.testing.expectEqual(@as(f64, 5), metrics.actualBoundingBoxDescent);
        // The font box and the baselines come from the family, not the emoji,
        // and already agreed with Chrome before any of this.
        try std.testing.expectEqual(@as(f64, 14), metrics.fontBoundingBoxAscent);
        try std.testing.expectEqual(@as(f64, 4), metrics.fontBoundingBoxDescent);
    }

    // A whole cluster is one emoji, whatever it is made of: a flag is two
    // regional indicators, a profession is a ZWJ sequence, a thumb is a base
    // and a skin tone. Chrome charges each of them once.
    try std.testing.expectEqual(@as(f64, 20), measure(Face.regular(sans), "🇺🇸", 16).width);
    try std.testing.expectEqual(@as(f64, 20), measure(Face.regular(sans), "👨‍💻", 16).width);
    try std.testing.expectEqual(@as(f64, 20), measure(Face.regular(sans), "👍🏽", 16).width);

    // And a selector on its own is not an emoji, it is nothing: Chrome
    // measures a bare U+FE0F zero, and a combining mark rides on the letter
    // before it rather than being charged again.
    try std.testing.expectEqual(@as(f64, 0), measure(Face.regular(sans), "\u{fe0f}", 16).width);
    try std.testing.expectEqual(
        measure(Face.regular(sans), "a", 16).width,
        measure(Face.regular(sans), "a\u{0301}", 16).width,
    );

    // Two emoji are two advances, and the ink box spans both.
    const pair = measure(Face.regular(sans), "😀😀", 16);
    try std.testing.expectEqual(@as(f64, 40), pair.width);
    try std.testing.expectEqual(@as(f64, 1), pair.actualBoundingBoxLeft);
    try std.testing.expectEqual(@as(f64, 41), pair.actualBoundingBoxRight);

    // Mixed with text, the pen keeps both kinds of advance. 'x' is 8 at 16px
    // in both engines, so the emoji starts there and its ink ends at 29.
    const mixed = measure(Face.regular(sans), "x😀", 16);
    try std.testing.expectEqual(@as(f64, 28), mixed.width);
    try std.testing.expectEqual(@as(f64, 29), mixed.actualBoundingBoxRight);
    try std.testing.expectEqual(@as(f64, 17), mixed.actualBoundingBoxAscent);

    // Printable ASCII is untouched by any of it — same string, same bits.
    try std.testing.expectEqual(@as(f64, 89.9658203125), measure(Face.regular(sans), "mmmmmmmmmmlli", 10).width);
    try std.testing.expectEqual(@as(f64, -0.64453125), measure(Face.regular(sans), "mmmmmmmmmmlli", 10).actualBoundingBoxLeft);
}

test "text_measure: the emoji strike is a table, not a ratio" {
    // Exact at a measured size, both ends of the table included.
    try std.testing.expectEqual(@as(f64, 20), emojiBox(16).advance);
    try std.testing.expectEqual(@as(f64, 17), emojiBox(16).ascent);
    try std.testing.expectEqual(@as(f64, 10), emojiBox(8).advance);
    try std.testing.expectEqual(@as(f64, 128), emojiBox(128).advance);
    try std.testing.expectEqual(@as(f64, 114), emojiBox(128).ascent);

    // The point of the table: 16px is not 1.25 em everywhere and 24px is not
    // 1.25 em at all. Below 24 the strike is wider than the em box, from 24
    // up it is the em exactly.
    try std.testing.expectEqual(@as(f64, 24), emojiBox(24).advance);
    try std.testing.expectEqual(@as(f64, 48), emojiBox(48).advance);

    // Between two measurements, a straight line; outside them, the nearest
    // end scaled. Neither is Chrome's answer, and neither pretends to be.
    try std.testing.expectEqual(@as(f64, 23), emojiBox(22).advance);
    try std.testing.expectEqual(@as(f64, 256), emojiBox(256).advance);
    try std.testing.expectEqual(@as(f64, 5), emojiBox(4).advance);

    // Non-finite and non-positive sizes never reach the table.
    try std.testing.expectEqual(@as(f64, 0), measure(Face.regular(font_metrics.sans_serif), "😀", 0).width);
    try std.testing.expectEqual(@as(f64, 0), measure(Face.regular(font_metrics.sans_serif), "😀", -3).width);
}

test "text_measure: a variation selector decides which font a glyph comes from" {
    // The gap between Emoji and Emoji_Presentation, which is the whole reason
    // emoji_properties.zig carries both tables.
    try std.testing.expect(isColourEmoji("😀"));
    try std.testing.expect(!isColourEmoji("☀")); // Emoji, text presentation
    try std.testing.expect(isColourEmoji("☀\u{fe0f}")); // asked for colour
    try std.testing.expect(!isColourEmoji("😀\u{fe0e}")); // asked for text
    try std.testing.expect(isColourEmoji("🇺🇸"));
    try std.testing.expect(isColourEmoji("👨‍💻"));
    try std.testing.expect(isColourEmoji("👍🏽"));

    // A selector needs an Emoji character in front of it to mean anything.
    try std.testing.expect(!isColourEmoji("\u{fe0f}"));
    try std.testing.expect(!isColourEmoji("a\u{fe0f}"));
    try std.testing.expect(!isColourEmoji("a"));
    try std.testing.expect(!isColourEmoji(""));

    // Chrome makes a bare U+2600 16 at 16px sans-serif — one em, from the
    // text font. We answer the mean-advance guess instead; the selector form
    // above is the one the widget asks about, and that one is right.
    try std.testing.expectEqual(
        measure(Face.regular(font_metrics.sans_serif), "\u{2600}", 16).width,
        meanAdvance(font_metrics.sans_serif) * 16 / font_metrics.basis,
    );
}

// Character counts and indices are UTF-16 code units, to match DOM string
// semantics: an astral codepoint is two addressable characters in browsers.
pub fn utf16Length(text: []const u8) u32 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var result: u32 = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        result += unitLength(codepoint);
    }
    return result;
}

fn unitLength(codepoint: u21) u32 {
    return if (codepoint >= 0x10000) 2 else 1;
}

/// The pair table a face kerns with: its own if it carries one, otherwise the
/// host family's.
///
/// A DOWNLOADED face brings its pairs with it. `font_kerning.tableFor` is
/// keyed by the glyph tables in `font_metrics.zig`, and a webfont is in none
/// of them, so a `@font-face` string used to come out as the bare sum of its
/// advances however much the file kerned it -- 124.8828125 for iphey's
/// `Hello, SVG World!` against Chrome's 124.40625, the 0.484375 being three
/// pairs the file's `GPOS` charges (see font_file.zig).
fn kernsFor(face: Face) font_kerning.Table {
    if (!face.kerning) return .{};
    if (face.family.own_kerns.pairs.len != 0) return face.family.own_kerns;
    return font_kerning.tableFor(face.family, face.variant);
}

/// Total advance of `text` at `font_size`, cluster by cluster, plus what the
/// font adjusts across each pair.
///
/// SVG kerns: measured against a headed Chrome 153 on a local page serving
/// iphey's own RobotoFlex (tools/fingerprint/scratch/s45/kern-page.html), a
/// 16px `<text>` reading `Hello, SVG World!` answers 124.40625 and the same
/// `<text>` under `font-kerning: none` answers 124.890625.
///
/// And it kerns ACROSS A SPACE, which puts it on the LAYOUT surface and not
/// the canvas one this path used to share. Measured on a headed Chrome 153
/// (scratch/s69/expr-svg-vs-span.js): over six families by nine strings, a
/// `<text>`'s `getComputedTextLength` equals the width of a `<span>` holding
/// the same string in the same font on every row, and differs from
/// `measureText` on exactly the rows with a space pair -- `AVATAR To Wo` at
/// 16px sans-serif is 108.5234375 through both layout and SVG against the
/// canvas's 108.8046875, and `A V A V` 53.3984375 against 56.0234375. This
/// engine answered the canvas number, which is the 0.28125 the iphey `SVG
/// Computed Style` axis was over on.
pub fn svgWidth(face: Face, text: []const u8, font_size: f64) f64 {
    const kerns = kernsFor(face);
    const space_kerns = face.space_kerns;
    var offset: usize = 0;
    var total: f64 = 0;
    var previous: ?u21 = null;
    while (offset < text.len) {
        const cluster = nextCluster(face, text[offset..]);
        if (cluster.bytes == 0) break;
        // Per code point rather than per cluster, the same way `measureAt`
        // charges them: a cluster's own characters are adjacent glyphs too.
        var codepoints = std.unicode.Utf8Iterator{ .bytes = text[offset..][0..cluster.bytes], .i = 0 };
        while (codepoints.nextCodepoint()) |codepoint| {
            if (previous) |before| {
                total += font_kerning.kern(kerns, before, codepoint);
                // Gated on a space the same way `measureAt` gates it: the
                // second table can only ever answer at one.
                if (before == ' ' or codepoint == ' ') {
                    total += font_kerning.kern(space_kerns, before, codepoint);
                }
            }
            previous = codepoint;
        }
        total += cluster.advance;
        offset += cluster.bytes;
    }
    return toPixels(quantise(face.family, total), font_size);
}

/// The advance of the `nchars` characters starting at `charnum`, counted in
/// UTF-16 code units like every DOM string index.
pub fn svgSubstringWidth(family: font_metrics.Family, text: []const u8, charnum: u32, nchars: u32, font_size: f64) !f64 {
    const range = try clusterRange(family, text, charnum, nchars);
    return toPixels(range.advance, font_size);
}

/// Where the cluster addressed by `charnum` starts, and how wide it is. Both
/// in user units at `font_size`, and both measured from the start of `text`.
pub fn svgCharExtent(family: font_metrics.Family, text: []const u8, charnum: u32, font_size: f64) !struct { offset: f64, advance: f64 } {
    const range = try clusterRange(family, text, charnum, 1);
    return .{
        .offset = toPixels(range.before, font_size),
        .advance = toPixels(range.advance, font_size),
    };
}

/// A run's total advance, rounded UP to a whole font unit, which is what
/// Chrome answers for a DOWNLOADED face and the one place the quantisation
/// happens: `Hello, SVG World!` in iphey's RobotoFlex at 16px sums to
/// 15923.4731 units and Chrome reads 124.40625px, which is 15924 of them.
/// Ten strings measured against a headed Chrome 153 agree, and four of them
/// separate this from rounding each advance as it is read
/// (tools/fingerprint/scratch/s45/predict.py).
///
/// A family out of `font_metrics.zig` declares no `unitsPerEm` and is left
/// alone: its advances arrive already quantised from Chrome, at whatever
/// grid Chrome applied, and there is nothing left here to round.
fn quantise(family: font_metrics.Family, basis_total: f64) f64 {
    const upem = family.units_per_em;
    if (upem == 0 or basis_total == 0 or !std.math.isFinite(basis_total)) return basis_total;
    return @ceil(basis_total * upem / font_metrics.basis) * font_metrics.basis / upem;
}

/// The grid Blink snaps a font size onto before it builds the font: 1/200 of a
/// CSS pixel. `FontDescription::EffectiveFontSize` exists so a size and the
/// font cache key it produces cannot disagree, and it FLOORS rather than
/// rounds.
const SIZE_GRID_STEPS: f32 = 200;

/// The size the shaper actually runs at, which is not the computed font size.
///
/// A control laid out at the UA's `-webkit-small-control` — computed
/// `13.3333px` — shapes at `13.33`, so every glyph is about 0.0002px narrower
/// than the linear answer and a six-character label comes out 1/128px short of
/// one. That is the whole of the two rows Kasada disagreed with this engine on:
/// `Submit` is 57.4921875 wide in Chrome against 57.5 here, and `Reset`
/// 50.828125 against 50.8359375.
///
/// Measured by recovering the effective size out of 1000 copies of one glyph,
/// which puts the reading on a 1e-5px grid: 65 sizes across 13..14 at 1/64px
/// steps, 41 across 13.32..13.36 at 0.001, and 0.05 steps through 8..9 and
/// 40..41 all land on `floor(size * 200) / 200`
/// (scratch/s61/{size-grid,glyph-precision}.js). The 18 places
/// `line-height: normal` steps between 8px and 16px land on the same grid, so
/// the vertical metrics come through here too.
///
/// The narrowing to `f32` is not decoration. `8.15px` parses to a float a hair
/// UNDER 8.15, so its bucket is 8.145 and not 8.15, and Chrome answers 8.145;
/// `8.4px`, `9.9px` and `40.1px` are the same shape. Those two sizes are the
/// pair `textAdvanceUnit` records as "an advance Chrome does not derive
/// linearly" — they are this, and they are linear once the size is snapped.
pub fn effectiveSize(px: f64) f64 {
    if (!(px > 0) or !std.math.isFinite(px)) return px;
    const narrowed: f32 = @floatCast(px);
    const scaled: f32 = narrowed * SIZE_GRID_STEPS;
    return @as(f64, @floor(scaled)) / SIZE_GRID_STEPS;
}

/// Accumulates at the tables' 100px basis and converts once, so a sum of
/// dyadic rationals stays exact until the last step.
fn toPixels(value: f64, font_size: f64) f64 {
    if (font_size <= 0 or !std.math.isFinite(font_size)) {
        return 0;
    }
    return value * font_size / font_metrics.basis;
}

/// A cluster is measured whenever its unit range intersects the request, so
/// addressing either half of a surrogate pair — or any code unit inside a ZWJ
/// sequence — yields the whole glyph, like Chrome does.
fn clusterRange(family: font_metrics.Family, text: []const u8, charnum: u32, nchars: u32) !struct { before: f64, advance: f64 } {
    const face = Face.regular(family);
    if (charnum >= utf16Length(text)) {
        return error.IndexSizeError;
    }
    const end = charnum +| nchars;

    var offset: usize = 0;
    var unit: u32 = 0;
    var before: f64 = 0;
    var inside: f64 = 0;
    while (offset < text.len) {
        const cluster = nextCluster(face, text[offset..]);
        if (unit >= end) break;
        if (unit + cluster.units > charnum) {
            inside += cluster.advance;
        } else {
            before += cluster.advance;
        }
        unit += cluster.units;
        offset += cluster.bytes;
    }
    return .{ .before = before, .advance = inside };
}

const Cluster = struct {
    /// Bytes of UTF-8 the cluster spans.
    bytes: usize,
    /// UTF-16 code units the cluster spans.
    units: u32,
    /// Advance at the 100px basis.
    advance: f64,
};

/// The shaped cluster at the front of `text`. A measured emoji sequence wins
/// outright; otherwise a base character absorbs the joiners, variation
/// selectors, skin-tone modifiers and combining marks that follow it, which
/// is what makes a ZWJ sequence one glyph wide instead of several.
fn nextCluster(face: Face, text: []const u8) Cluster {
    if (emoji_metrics.match(text)) |measured| {
        return .{
            .bytes = measured.text.len,
            .units = measured.units,
            .advance = measured.advance,
        };
    }

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    const base = iterator.nextCodepoint() orelse return .{ .bytes = text.len, .units = 0, .advance = 0 };
    var cluster = Cluster{
        .bytes = iterator.i,
        .units = unitLength(base),
        .advance = advance(face, base),
    };

    // A flag is a pair of regional indicators and one glyph.
    if (isRegionalIndicator(base)) {
        const save = iterator.i;
        if (iterator.nextCodepoint()) |next| {
            if (isRegionalIndicator(next)) {
                cluster.bytes = iterator.i;
                cluster.units += unitLength(next);
                return cluster;
            }
        }
        iterator.i = save;
    }

    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == ZERO_WIDTH_JOINER) {
            // The joined half is part of the same glyph and carries no
            // advance of its own.
            const joined = iterator.nextCodepoint() orelse break;
            cluster.units += unitLength(codepoint) + unitLength(joined);
            cluster.bytes = iterator.i;
            continue;
        }
        if (!isClusterExtender(codepoint)) {
            break;
        }
        cluster.units += unitLength(codepoint);
        cluster.bytes = iterator.i;
    }
    return cluster;
}

const ZERO_WIDTH_JOINER = 0x200d;
const VARIATION_SELECTOR_15 = 0xfe0e; // asks for the text glyph
const VARIATION_SELECTOR_16 = 0xfe0f; // asks for the colour emoji one
const SKIN_TONE_FIRST = 0x1f3fb;
const SKIN_TONE_LAST = 0x1f3ff;

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

fn isClusterExtender(codepoint: u21) bool {
    return isZeroWidth(codepoint) or
        codepoint == 0x20e3 or // combining enclosing keycap
        (codepoint >= SKIN_TONE_FIRST and codepoint <= SKIN_TONE_LAST);
}

/// One character's advance at the 100px basis. Tabulated for the ASCII we
/// measured; a guess, and marked as one, outside it.
fn advance(face: Face, codepoint: u21) f64 {
    if (face.glyph(codepoint)) |g| {
        return g.advance;
    }
    if (isZeroWidth(codepoint)) return 0;
    if (codepoint == '\n' or codepoint == '\r') return 0;
    if (codepoint == '\t') return font_metrics.basis * 1.32;
    if (std.ascii.isWhitespace(@intCast(@min(codepoint, 0x7f)))) return font_metrics.basis * 0.33;
    if (isWide(codepoint)) return font_metrics.basis;
    return font_metrics.basis * 0.6;
}

fn isZeroWidth(codepoint: u21) bool {
    return codepoint == 0x200c or codepoint == 0x200d or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        codepoint == 0x2329 or codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f000 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

test "svg metrics measure whole clusters, addressed by utf-16 unit" {
    const serif = font_metrics.fallback;
    try std.testing.expectEqual(@as(u32, 3), utf16Length("Aé界"));
    try std.testing.expectEqual(@as(u32, 2), utf16Length("🌍"));

    // 'A' from the table, the combining acute absorbed into it, and an
    // untabulated wide glyph charged one em.
    try std.testing.expectApproxEqAbs(@as(f64, 7.2216796875 + 10), svgWidth(Face.regular(serif), "A\u{0301}界", 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try svgSubstringWidth(serif, "A界", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try svgSubstringWidth(serif, "🌍", 0, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try svgSubstringWidth(serif, "🌍", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try svgSubstringWidth(serif, "A界", 1, 0, 10), 0.0001);
    try std.testing.expectError(error.IndexSizeError, svgSubstringWidth(serif, "A", 2, 1, 10));
    try std.testing.expectError(error.IndexSizeError, svgSubstringWidth(serif, "A", 1, 0, 10));
    try std.testing.expectError(error.IndexSizeError, svgSubstringWidth(serif, "", 0, 0, 10));

    // Straight from the emoji table: Chrome makes these 73.6875 and 60.2109375
    // at 100px, not one em each.
    try std.testing.expectEqual(@as(f64, 73.6875), svgWidth(Face.regular(serif), "☺", 100));
    try std.testing.expectEqual(@as(f64, 60.2109375), svgWidth(Face.regular(serif), "☠", 100));

    // A ZWJ sequence is five code units and a single glyph, so summing its
    // parts (which would charge the ♂ separately) is wrong.
    try std.testing.expectEqual(@as(u32, 5), utf16Length("🤵‍♂️"));
    try std.testing.expectEqual(@as(f64, 100), svgWidth(Face.regular(serif), "🤵‍♂️", 100));
    try std.testing.expectEqual(@as(f64, 100), try svgSubstringWidth(serif, "🤵‍♂️", 3, 1, 100));

    // An unmeasured ZWJ sequence still collapses to one cluster.
    try std.testing.expectEqual(@as(f64, 100), svgWidth(Face.regular(serif), "🧑\u{200d}🚀", 100));
    // As does a flag, which is a pair of regional indicators.
    try std.testing.expectEqual(@as(f64, 100), svgWidth(Face.regular(serif), "🇫🇷", 100));

    // Chrome's own answer for the SVG default font.
    try std.testing.expectEqual(@as(f64, 444.3359375), svgWidth(Face.regular(serif), "Hello", 200));
    const extent = try svgCharExtent(serif, "Hello", 4, 20);
    try std.testing.expectEqual(@as(f64, 34.43359375), extent.offset);
    try std.testing.expectEqual(@as(f64, 10), extent.advance);
}

test "text_measure: a small-caps run shapes at its own size and does not kern across the break" {
    // The size ladder on its own. Half a CSS pixel is the grid, so 100px gives
    // 70 exactly, and the two fractional sizes round rather than truncate.
    try std.testing.expectEqual(@as(f64, 70), smallCapsSize(100));
    try std.testing.expectEqual(@as(f64, 9.5), smallCapsSize(13.33));
    try std.testing.expectEqual(@as(f64, 11), smallCapsSize(16));

    const plain: Face = .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .none);
    const sc: Face = .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .lowercase);
    const all: Face = .of(font_metrics.serif, 400, false, .{}, .layout, true, .none, .all);

    // What the whole thing is: the lowercase run becomes the uppercase one at
    // the reduced size. `all-small-caps` reduces the capitals too.
    try std.testing.expectEqual(measure(plain, "ABCDEFGHIJ", 70).width, measure(sc, "abcdefghij", 100).width);
    try std.testing.expectEqual(measure(plain, "ABCDEFGHIJ", 70).width, measure(all, "ABCDEFGHIJ", 100).width);
    // A character uppercasing leaves alone keeps the full size, which is why
    // the digits are untouched.
    try std.testing.expectEqual(measure(plain, "0123456789", 100).width, measure(sc, "0123456789", 100).width);

    // A size change breaks the shaping run, so the pair 'AV' is charged when
    // both are full size and NOT when the variant put them at two sizes. At
    // 16px serif the pair is worth 2.0625, and a small-caps 'aV' has to be the
    // bare sum of an 'A' at 11 and a 'V' at 16.
    try std.testing.expectEqual(@as(f64, 21.046875), measure(plain, "AV", 16).width);
    try std.testing.expectEqual(
        measure(plain, "A", 11).width + measure(plain, "V", 16).width,
        measure(sc, "aV", 16).width,
    );
    // Both sides small, and the pair IS charged: one run again.
    try std.testing.expectEqual(measure(plain, "AV", 11).width, measure(sc, "av", 16).width);

    // U+00DF uppercases to two characters, and the pair it produces is priced
    // at the reduced size like any other small cap.
    try std.testing.expectEqual(measure(plain, "SS", 11).width, measure(sc, "\u{00df}", 16).width);
}
