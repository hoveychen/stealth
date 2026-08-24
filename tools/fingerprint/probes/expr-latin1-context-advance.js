// Where the 7.101 in expr-turnstile-mojibake-metrics comes from.
//
// That probe found seven of the widget's ten strings measure exactly the sum
// of their code points' isolated widths, and three do not: 1F600, 1F680 and
// 2600+FE0F each come out 7.101 wider than the sum. The three are also the
// only three whose UTF-8 bytes include 0x80, and 16 - 8.898 is 7.102 -- so the
// candidate rule is that U+0080 measures 8.898 alone and advances 16 in a
// string. This asks the question directly instead of inferring it.
//
//   node tools/fingerprint/run-expr.mjs chrome \
//        tools/fingerprint/probes/expr-latin1-context-advance.js --headed
//
// Headed matters for the same reason it did there: which font lends a glyph to
// a C1 control is the platform's answer, and a headless Chrome resolves it
// somewhere else. Every string is built with fromCharCode rather than written
// out, so no C1 byte ever sits in this file.
(() => {
  const out = {};
  const canvas = new OffscreenCanvas(400, 40);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.font = '16px sans-serif';
  out.font = ctx.font;

  const round = (v) => Math.round(v * 1000) / 1000;
  const w = (s) => round(ctx.measureText(s).width);
  const chr = (c) => String.fromCharCode(c);
  const hex = (c) => c.toString(16).toUpperCase().padStart(2, '0');

  // A neutral neighbour: U+0098 is a C1 with no glyph anywhere, so it cannot
  // kern or form a cluster, and its own advance is a flat 16.
  const NEUTRAL = chr(0x98);
  out.neutral = w(NEUTRAL);

  // Every code point the ten strings can be made of, measured alone and in
  // four contexts. If a code point's contribution never depends on what sits
  // next to it, one table of isolated widths is the whole fix.
  out.contextual = {};
  for (let c = 0x20; c <= 0xff; c++) {
    const s = chr(c);
    out.contextual[hex(c)] = {
      alone: w(s),
      afterNeutral: round(w(NEUTRAL + s) - out.neutral),
      beforeNeutral: round(w(s + NEUTRAL) - out.neutral),
      doubled: round(w(s + s) - w(s)),
      tripledStep: round(w(s + s + s) - w(s + s)),
    };
  }

  // The three that disagree, plus 1F44D as the control: it holds no 0x80 and
  // its whole already equals its sum. Every prefix, so the byte that adds the
  // 7.101 can be named rather than guessed at.
  const latin1 = (...codepoints) =>
    [...new TextEncoder().encode(String.fromCodePoint(...codepoints))]
      .map((b) => chr(b))
      .join('');
  const SUBJECTS = {
    '1F600': latin1(0x1f600),
    '1F680': latin1(0x1f680),
    '2600+FE0F': latin1(0x2600, 0xfe0f),
    '1F44D': latin1(0x1f44d),
  };
  out.ladders = {};
  for (const [label, text] of Object.entries(SUBJECTS)) {
    const steps = [];
    let previous = 0;
    for (let n = 1; n <= text.length; n++) {
      const width = w(text.slice(0, n));
      steps.push({
        bytes: [...text.slice(0, n)].map((ch) => hex(ch.charCodeAt(0))).join(' '),
        width,
        step: round(width - previous),
      });
      previous = width;
    }
    out.ladders[label] = steps;
  }

  // U+0080 against a spread of neighbours, and the other three C1 controls
  // that carry ink (0x81, 0x82, 0x84) beside it -- if the rule is about having
  // a glyph at all rather than about 0x80, they move together. 0x98 is the
  // no-glyph control and 0xF0 the ordinary Latin-1 one.
  //
  // `contribution` is what the subject cost in that context: the pair's width
  // less the neighbour measured alone. Where that equals `alone`, the context
  // did nothing.
  out.battery = {};
  for (const code of [0x80, 0x81, 0x82, 0x84, 0x98, 0xf0]) {
    const s = chr(code);
    const alone = w(s);
    const row = { alone };
    for (const [name, neighbour, before] of [
      ['selfPair', s, false],
      ['afterSpace', ' ', true],
      ['beforeSpace', ' ', false],
      ['afterA', 'a', true],
      ['beforeA', 'a', false],
      ['afterC1', chr(0x98), true],
      ['beforeC1', chr(0x98), false],
      ['afterF0', chr(0xf0), true],
      ['beforeF0', chr(0xf0), false],
      ['afterZwj', '‍', true],
    ]) {
      const whole = w(before ? neighbour + s : s + neighbour);
      row[name] = { whole, contribution: round(whole - w(neighbour)) };
    }
    out.battery[hex(code)] = row;
  }

  // The `battery` rows name five code points whose cost depends on what
  // precedes them -- 0x7F, 0x80, 0x81, 0x82, 0x84, the ones with a glyph in
  // some fallback font rather than in the primary one -- and nothing that
  // depends on what follows. The candidate explanation is Blink's per-run font
  // selection: the stretch of text the primary font cannot draw is one
  // segment, the font for it is chosen for the segment's *first* character,
  // and a character with no glyph anywhere lands on the last resort font,
  // which then covers the rest of the segment at one em apiece.
  //
  // These sequences separate that from "0x80 is special": under the run rule a
  // primary-font character in between breaks the segment and the glyph comes
  // back, and the penalty reaches past the immediate neighbour.
  out.runs = {};
  for (const bytes of [
    [0x98, 0x80],
    [0x98, 0x80, 0x80],
    [0x80, 0x98, 0x80],
    [0x80, 0x80],
    [0x9f, 0x80],
    [0x8d, 0x80],
    [0x98, 0x81, 0x82, 0x84],
    [0x98, 0x61, 0x80],
    [0x98, 0xf0, 0x80],
    [0x98, 0xa0, 0x80],
    [0x61, 0x98, 0x80],
    [0x98, 0x7f],
    [0x7f, 0x80],
    [0x7f, 0x98, 0x80],
    [0xc6, 0x80],
  ]) {
    out.runs[bytes.map(hex).join(' ')] = w(bytes.map(chr).join(''));
  }

  // Ink boundaries are signed, so a string's box is a max over signed values
  // rather than over magnitudes. These pairs pin that down: U+0022's ink is
  // wholly above the baseline (negative descent) and U+005F's wholly below
  // (negative ascent), so each pair has one boundary contributed by the glyph
  // whose own is negative.
  out.ink = {};
  for (const text of ['"', '_', String.fromCharCode(0x84), '",', '_"']) {
    const m = ctx.measureText(text);
    out.ink[[...text].map((ch) => hex(ch.charCodeAt(0))).join(' ')] = {
      ascent: round(m.actualBoundingBoxAscent),
      descent: round(m.actualBoundingBoxDescent),
    };
  }

  return JSON.stringify(out);
})();
