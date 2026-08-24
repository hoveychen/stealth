// What a canvas 2D context does with every colour notation: the string
// `fillStyle` answers, and the bytes the paint actually leaves behind in each
// of the two context colour spaces the Turnstile widget builds.
//
// The widget (results/ibt2-oracle.json) makes four 2x2 offscreen canvases --
// {srgb,display-p3} x {unorm8,float16} -- fills each with
// `color(display-p3 1 0.25 0.5)` and reads 1x1 back in the *matching* space.
// So its display-p3 row is a display-p3 *canvas*, not an srgb canvas converted
// on readback. This probe measures both, and the cross readings too, so the
// two axes stay apart.
(async () => {
  const notations = [
    '#ff0000', '#ff000080', 'red', 'transparent', 'currentColor', 'notacolour',
    'rgb(255,0,0)', 'rgb(255 0 0)', 'rgba(255,0,0,0.5)', 'rgb(255 0 0 / 0.5)',
    'rgb(50% 0% 0%)', 'rgb(none 0 0)',
    'hsl(0,100%,50%)', 'hsl(0 100% 50%)', 'hsla(0,100%,50%,0.5)',
    'hsl(30 60% 40%)',
    'hwb(0 0% 0%)', 'hwb(120 20% 30%)', 'hwb(120 50% 60%)',
    'lab(50% 40 30)', 'lab(50 40 30)', 'lch(50% 40 30)',
    'oklab(0.7 0.1 0.05)', 'oklch(0.7 0.1 20)',
    'color(display-p3 1 0 0)', 'color(display-p3 1 0.25 0.5)',
    'color(srgb 1 0.25 0.5)', 'color(srgb-linear 1 0.25 0.5)',
    'color(a98-rgb 1 0.25 0.5)', 'color(prophoto-rgb 1 0.25 0.5)',
    'color(rec2020 1 0.25 0.5)', 'color(xyz 0.5 0.25 0.1)',
    'color(xyz-d50 0.5 0.25 0.1)', 'color(display-p3 1 0.25 0.5 / 0.5)',
    'color(display-p3 50% 25% 50%)',
    // The grammar's edges, so the serialiser is measured rather than guessed.
    'LAB(50 40 30)', 'lab(50 40 30 / 0.5)', 'lab(50 40 30 / 50%)',
    'lab(none 40 30)', 'lab(50% 50% 50%)', 'lab(50)', 'lab(50 40 30 40)',
    'lch(50 40 30deg)', 'lch(50 40 0.5turn)', 'lch(50 100% 30)',
    'oklch(70% 0.1 20)', 'oklch(0.7 25% 20)', 'oklab(0.7 25% 5%)',
    'COLOR(DISPLAY-P3 1 0 0)', 'color(display-p3 none 0.25 0.5)',
    'color(display-p3 1 0.25 0.5 / none)', 'color(display-p3 1 0.25)',
    'color(display-p3 1 0.25 0.5 0.5)', 'color(nonesuch 1 0 0)',
    'color(xyz-d65 0.5 0.25 0.1)', 'color(rec2020 -0.5 0.25 1.5)',
    'oklch(1.5 0.1 20)', 'lab(150 40 30)', 'lab(-50 40 30)',
    'color(srgb 1.5 -0.5 0.5)', 'rgb(1,2,3,)', 'hsl(0 100% 50% / 200%)',
    'lch(50 -40 30)', 'oklch(0.7 -0.1 20)', 'lab(50 40 30 / 1)',
    'color(display-p3 1 0 0 / 1)', 'lch(50 40 400)', 'lch(50 40 -30)',
    'lab(50 40 30 / 1.5)', 'color(display-p3 1 0 0 / -1)',
    'oklab(none none none)', 'color(display-p3 none none none)',
    'lab( 50  40  30 )', 'lab(50, 40, 30)', 'color(display-p3, 1, 0, 0)',
    'oklch(0.70 0.10 20.0)', 'lab(5e1 40 30)', 'lab(+50 40 30)',
    // Whitespace and case around a whole notation, which the `<input
    // type=color>` sanitiser treats asymmetrically -- canvas need not.
    ' red ', ' #ff0000 ', ' rgb(1,2,3) ', 'RED', '  lab(50 40 30)  ',
    '\tred\n', 'red x', '',
  ];

  const hex = (data) =>
    [...data].map((b) => b.toString(16).padStart(2, '0')).join('');

  const ctxFor = (colorSpace) => {
    const c = new OffscreenCanvas(2, 2);
    return c.getContext('2d', { colorSpace, colorType: 'unorm8', willReadFrequently: true });
  };

  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}`; } };

  // The `fillStyle` string, on a plain srgb canvas. The previous colour is blue
  // so a notation the engine drops is visible as blue rather than as silence.
  const strings = {};
  {
    const ctx = ctxFor('srgb');
    for (const n of notations) {
      ctx.fillStyle = '#0000ff';
      strings[n] = ask(() => { ctx.fillStyle = n; return String(ctx.fillStyle); });
    }
  }

  // The bytes. Four combinations of canvas space x readback space, so a
  // conversion on the paint side and one on the readback side stay separable.
  const pixels = {};
  for (const canvasSpace of ['srgb', 'display-p3']) {
    for (const readSpace of ['srgb', 'display-p3']) {
      const key = `${canvasSpace}->${readSpace}`;
      pixels[key] = {};
      for (const n of notations) {
        pixels[key][n] = ask(() => {
          const ctx = ctxFor(canvasSpace);
          ctx.fillStyle = '#0000ff';
          ctx.fillStyle = n;
          ctx.fillRect(0, 0, 2, 2);
          const d = ctx.getImageData(0, 0, 1, 1, { colorSpace: readSpace, pixelFormat: 'rgba-unorm8' });
          return `${hex(d.data)} ${d.colorSpace} ${d.data.length}`;
        });
      }
    }
  }

  // What the context reports about itself, since the widget's four canvases
  // differ only in these two fields.
  const attributes = {};
  for (const colorSpace of ['srgb', 'display-p3']) {
    attributes[colorSpace] = ask(() => JSON.stringify(ctxFor(colorSpace).getContextAttributes()));
  }

  return { strings, pixels, attributes };
})()
