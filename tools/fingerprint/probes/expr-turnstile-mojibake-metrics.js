// What the Turnstile widget's ten measureText calls actually ask about.
//
// probes/expr-emoji-text-metrics.js assumed they were emoji, because the ten
// strings read as emoji in the widget's source. They are not. Traced live on
// the cloudflare-challenge page, both arms record the first argument as four
// code points -- U+00F0 U+009F U+0098 U+0080 -- which is the UTF-8 encoding of
// U+1F600 read back as Latin-1. Both engines see the same thing, so this is
// the page's own mojibake and not a decoding bug on either side.
//
// The arithmetic confirms it without needing the trace: this engine answered
// 33.725 for nine of the ten and 50.588 for the tenth, which is 4 and 6 times
// its 8.43125 per-code-point fallback -- and U+1F600 is four UTF-8 bytes while
// U+2600 U+FE0F is six.
//
// So the surface being fingerprinted is Latin-1 and C1 text metrics, not
// colour emoji. Run headed anyway; which font lends a glyph for a C1 control
// is the platform's answer to give:
//
//   node tools/fingerprint/run-expr.mjs chrome \
//        tools/fingerprint/probes/expr-turnstile-mojibake-metrics.js --headed
(() => {
  const out = {};

  // The ten, encoded exactly as the widget hands them over: the UTF-8 bytes of
  // each emoji, one Latin-1 code point per byte.
  const asLatin1 = (codepoint) =>
    [...new TextEncoder().encode(String.fromCodePoint(codepoint))]
      .map((b) => String.fromCharCode(b))
      .join('');

  const TEN = [
    0x1f600, 0x1f923, 0x1f631, 0x1f44d, 0x1f525,
    0x1f680, 0x1f9e0, 0x1f436, 0x1f3e0,
  ].map((c) => ({ label: c.toString(16).toUpperCase(), text: asLatin1(c) }));
  TEN.push({ label: '2600+FE0F', text: asLatin1(0x2600) + asLatin1(0xfe0f) });

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
    };
  };

  // The widget's own context: an OffscreenCanvas 2D at the size the trace
  // recorded, with the default font left alone until proven otherwise.
  const canvas = new OffscreenCanvas(220, 40);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  out.fontDefault = ctx.font;

  out.atDefault = {};
  for (const { label, text } of TEN) out.atDefault[label] = metrics(ctx, text);

  ctx.font = '16px sans-serif';
  out.font = ctx.font;
  out.strings = {};
  for (const { label, text } of TEN) out.strings[label] = metrics(ctx, text);

  // Each code point on its own, so a table can be built rather than guessed.
  // 0x80..0xFF is the whole of what these ten strings are made of, plus the
  // handful of ASCII bytes a UTF-8 lead byte never produces.
  out.perCodePoint = {};
  for (let code = 0x20; code <= 0xff; code++) {
    const m = ctx.measureText(String.fromCharCode(code));
    out.perCodePoint[code.toString(16).toUpperCase().padStart(2, '0')] = {
      width: round(m.width),
      ascent: round(m.actualBoundingBoxAscent),
      descent: round(m.actualBoundingBoxDescent),
    };
  }

  // Is the total the sum of the parts? If it is, one per-code-point table is
  // the whole fix; if it is not, the run is being shaped and it is not.
  out.additive = {};
  for (const { label, text } of TEN) {
    let sum = 0;
    for (const ch of text) sum += ctx.measureText(ch).width;
    out.additive[label] = { sum: round(sum), whole: round(ctx.measureText(text).width) };
  }

  return JSON.stringify(out);
})();
