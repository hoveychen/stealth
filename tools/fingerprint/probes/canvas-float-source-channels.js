// Which legacy colour notations reach a canvas as *floats* rather than as the
// bytes they answer back, and which do not.
//
// `hsl(30 60% 40%)` answers `#a36629` but its sRGB channels are (163.2, 102,
// 40.8). A display-p3 canvas converts before it quantises, so the two arms part
// there: converting the float stores 9b6935, converting the byte 9a6935. Legacy
// `rgb()` is the counter-example -- its parser rounds the percentages first --
// and the knife-edge rows are the ones where the f32 narrowing alone decides
// the byte, with no conversion involved at all.
(async () => {
  const notations = [
    // sRGB channels that are not byte-valued, on both sides of a rounding
    // boundary: 163.2 rounds down, 40.8 up, 178.5 is the tie.
    'hsl(30 60% 40%)', 'hwb(120 20% 30%)', 'hsl(280 70% 30%)',
    // The green here is 144.49999999999997 in double and 144.5 in float, so it
    // is the row that says which width the channel is carried at.
    'hwb(200 10% 20%)',
    'hwb(200 10% 21%)', 'hsl(90 33% 57%)', 'hsl(210 25% 61%)',
    'hwb(45 15% 35%)', 'hsl(150 40% 45%)', 'hwb(300 5% 5%)',
    // Byte-valued, so both widths agree and nothing should move.
    'hsl(0 100% 50%)', 'hwb(0 0% 0%)', 'hwb(120 50% 60%)', 'hsl(0 0% 50%)',
    // Legacy rgb(), whose channels are bytes by the time anything sees them.
    'rgb(50% 0% 0%)', 'rgb(10% 20% 30%)', 'rgb(2.5 3.5 4.5)',
    'rgb(255 0 0)', 'rgba(255, 0, 0, 0.5)',
    // The widget's own fill, and the one notation that needs no conversion at
    // all on a display-p3 bitmap.
    'color(display-p3 1 0.25 0.5)', 'color(display-p3 1 0.25 0.5 / 0.5)',
  ];

  const hex = (data) =>
    [...data].map((b) => b.toString(16).padStart(2, '0')).join('');

  const paint = (canvasSpace, readSpace, notation) => {
    try {
      const c = new OffscreenCanvas(1, 1);
      const ctx = c.getContext('2d', { colorSpace: canvasSpace, willReadFrequently: true });
      ctx.fillStyle = notation;
      ctx.fillRect(0, 0, 1, 1);
      const settings = readSpace ? { colorSpace: readSpace } : undefined;
      return hex(ctx.getImageData(0, 0, 1, 1, settings).data);
    } catch (e) {
      return `throw:${e.name}`;
    }
  };

  // A float16 read of the same paint, which answers the channel itself rather
  // than a byte -- so a row that lands on a rounding boundary says which side
  // of it the *unquantised* colour was on.
  const float16 = (canvasSpace, notation) => {
    try {
      const c = new OffscreenCanvas(1, 1);
      const ctx = c.getContext('2d', {
        colorSpace: canvasSpace,
        colorType: 'float16',
        willReadFrequently: true,
      });
      ctx.fillStyle = notation;
      ctx.fillRect(0, 0, 1, 1);
      const data = ctx.getImageData(0, 0, 1, 1, { pixelFormat: 'rgba-float16' }).data;
      return [...data].join(' ');
    } catch (e) {
      return `throw:${e.name}`;
    }
  };

  const out = { bytes: {}, float16: {} };
  for (const axis of ['srgb->srgb', 'srgb->display-p3', 'display-p3->display-p3', 'display-p3->srgb']) {
    const [canvasSpace, readSpace] = axis.split('->');
    out.bytes[axis] = {};
    for (const n of notations) {
      out.bytes[axis][n] = paint(canvasSpace, readSpace === canvasSpace ? undefined : readSpace, n);
    }
  }
  for (const space of ['srgb', 'display-p3']) {
    out.float16[space] = {};
    for (const n of notations) out.float16[space][n] = float16(space, n);
  }
  return JSON.stringify(out);
})();
