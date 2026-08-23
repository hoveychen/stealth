// What measureText answers for ten emoji at 16px sans-serif.
//
// CORRECTION. This probe was written believing the ten strings were what the
// Turnstile widget measures. They are not: the widget hands measureText the
// UTF-8 *bytes* of each emoji as Latin-1 code points, so it never asks about an
// emoji at all. See probes/expr-turnstile-mojibake-metrics.js, which measures
// the strings the widget really passes, and the correction note it carries.
//
// What this probe measures is still real, and the engine is still built to
// match it -- an emoji is 20 at 16px, not one em -- but it is no longer
// evidence about the challenge page. Two claims that were recorded here and in
// TASKS.md on the strength of it were wrong, and both are withdrawn:
//
//   * that a headless Chrome answers ten *different* widths for these ten
//     emoji. It does not; headed and headless agree on 20. The ten different
//     widths in results/ibt2-{oracle,lp}.json are headed Chrome measuring the
//     mojibake, and the mojibake probe reproduces them exactly.
//   * that the ten calls are ten of the twenty-two values the two arms
//     disagree on. The calls are, the emoji are not.
//
// Run headed. Which family `sans-serif` resolves to, and which font supplies a
// glyph the family has none for, are answered by the platform's font stack, and
// a headless Chrome is not obliged to answer them the same way:
//
//   node tools/fingerprint/run-expr.mjs chrome \
//        tools/fingerprint/probes/expr-emoji-text-metrics.js --headed
//
// Every field of TextMetrics is taken, not just the three the widget reads: an
// advance width can be reproduced from a table, but the bounding box needs the
// glyph's ink extents, and knowing which of the eight extents Chrome fills in
// says how much of that is actually required.
(() => {
  const out = {};

  // The widget's ten, in its own order. Written as escapes so the file survives
  // any transport that is not UTF-8 clean -- the trace recorded them mojibaked.
  const STRINGS = [
    '\u{1F600}', // grinning face
    '\u{1F923}', // rolling on the floor laughing
    '\u{1F631}', // face screaming in fear
    '\u{1F44D}', // thumbs up
    '\u{1F525}', // fire
    '\u{1F680}', // rocket
    '\u{1F9E0}', // brain
    '\u{1F436}', // dog face
    '\u{1F3E0}', // house
    '☀️', // sun with variation selector
  ];

  // Plain text at the same size, as a control: if these disagree too, the gap
  // is the font metrics generally rather than emoji specifically.
  const CONTROLS = ['x', 'M', 'Hwmqxli', 'VnYi2', ' ', 'á'];

  const round = (v) => (typeof v === 'number' ? Math.round(v * 1000) / 1000 : v);
  const metrics = (ctx, s) => {
    const m = ctx.measureText(s);
    return {
      width: round(m.width),
      actualLeft: round(m.actualBoundingBoxLeft),
      actualRight: round(m.actualBoundingBoxRight),
      actualAscent: round(m.actualBoundingBoxAscent),
      actualDescent: round(m.actualBoundingBoxDescent),
      fontAscent: round(m.fontBoundingBoxAscent),
      fontDescent: round(m.fontBoundingBoxDescent),
      emAscent: round(m.emHeightAscent),
      emDescent: round(m.emHeightDescent),
      alphabetic: round(m.alphabeticBaseline),
      hanging: round(m.hangingBaseline),
      ideographic: round(m.ideographicBaseline),
    };
  };

  // The widget measures on an OffscreenCanvas; an element canvas is taken too,
  // in case the two context interfaces do not share a text stack here.
  const oc = new OffscreenCanvas(220, 40);
  const octx = oc.getContext('2d');
  octx.font = '16px sans-serif';

  const el = document.createElement('canvas');
  el.width = 220; el.height = 40;
  const ectx = el.getContext('2d');
  ectx.font = '16px sans-serif';

  out.fontEcho = { offscreen: octx.font, element: ectx.font };
  out.emoji = {};
  out.emojiOnElement = {};
  for (const s of STRINGS) {
    const key = Array.from(s).map((c) => c.codePointAt(0).toString(16).toUpperCase()).join('+');
    out.emoji[key] = metrics(octx, s);
    out.emojiOnElement[key] = metrics(ectx, s);
  }

  out.controls = {};
  for (const s of CONTROLS) out.controls[JSON.stringify(s)] = metrics(octx, s);

  // The same emoji at a second size and a second family, so a fix can be
  // checked for scaling with the font rather than being pinned to one case.
  out.scaled = {};
  for (const font of ['32px sans-serif', '16px serif', '16px monospace', '16px Arial']) {
    octx.font = font;
    out.scaled[font] = { echo: octx.font, grin: metrics(octx, '\u{1F600}'), x: metrics(octx, 'x') };
  }
  octx.font = '16px sans-serif';

  // The advance is not a fixed fraction of the size -- 16px gives 20 and 32px
  // gives 32 -- so an implementation needs the curve, not one ratio. A colour
  // emoji font is a set of bitmap strikes, and this is where the steps show.
  out.sizes = {};
  for (const px of [8, 10, 11, 12, 13, 14, 16, 18, 20, 24, 32, 40, 48, 64, 96, 128]) {
    octx.font = `${px}px sans-serif`;
    const g = octx.measureText('\u{1F600}');
    const x = octx.measureText('x');
    out.sizes[px] = {
      grin: round(g.width),
      grinAscent: round(g.actualBoundingBoxAscent),
      grinDescent: round(g.actualBoundingBoxDescent),
      grinLeft: round(g.actualBoundingBoxLeft),
      grinRight: round(g.actualBoundingBoxRight),
      x: round(x.width),
    };
  }
  octx.font = '16px sans-serif';

  // A variation selector on its own, and a couple of sequences, since ☀️ is one
  // advance in Chrome and two here -- which says the clustering is the gap
  // rather than the per-glyph advance.
  out.clusters = {};
  for (const s of ['️', '☀', '☀️', '\u{1F1FA}\u{1F1F8}',
                   '\u{1F468}‍\u{1F4BB}', '\u{1F44D}\u{1F3FD}', 'á', 'á']) {
    const key = Array.from(s).map((c) => c.codePointAt(0).toString(16).toUpperCase()).join('+');
    out.clusters[key] = { width: round(octx.measureText(s).width), units: s.length, points: Array.from(s).length };
  }

  // Whether the emoji font is one the page could have named itself.
  out.fontCheck = {};
  for (const f of ['16px "Apple Color Emoji"', '16px "Noto Color Emoji"', '16px "Segoe UI Emoji"']) {
    try { out.fontCheck[f] = document.fonts.check(f); } catch (e) { out.fontCheck[f] = String(e); }
  }

  return JSON.stringify(out);
})()
