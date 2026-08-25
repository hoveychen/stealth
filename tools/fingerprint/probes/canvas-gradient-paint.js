// What a gradient actually paints. This engine keeps a gradient's stops and
// throws its *geometry* away, so a gradient fill lands as whatever flat colour
// it replaced -- the widget's 48x48 scene builds seven of them, which is the
// largest block of wrong pixels left in that render.
//
// Every reading is one row of a 32x8 bitmap, read as bytes. A row is enough:
// the linear and conic cases are constant down a column by construction, and
// the radial ones are sampled through the centre.
(() => {
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const W = 32, H = 8;
  const row = (build, y) => {
    const ctx = new OffscreenCanvas(W, H).getContext('2d', { willReadFrequently: true });
    build(ctx);
    return hex(ctx.getImageData(0, y === undefined ? 4 : y, W, 1).data);
  };
  const filled = (make, stops, before) => row((ctx) => {
    if (before) before(ctx);
    const g = make(ctx);
    for (const [at, colour] of stops) g.addColorStop(at, colour);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  });

  const two = [[0, '#ff0000'], [1, '#0000ff']];
  const out = {};

  // --- linear -------------------------------------------------------------
  out['linear across'] = filled((c) => c.createLinearGradient(0, 0, 32, 0), two);
  // Half the width, so both ends clamp: the spec extends the end stops.
  out['linear half'] = filled((c) => c.createLinearGradient(8, 0, 24, 0), two);
  // Backwards, which should mirror the row above.
  out['linear reversed'] = filled((c) => c.createLinearGradient(24, 0, 8, 0), two);
  // A degenerate axis. The spec says paint nothing.
  out['linear zero length'] = filled((c) => c.createLinearGradient(8, 0, 8, 0), two);
  // Diagonal, so the row is the projection onto the axis.
  out['linear diagonal'] = filled((c) => c.createLinearGradient(0, 0, 32, 8), two);

  // --- stops --------------------------------------------------------------
  // No stops at all: the spec says transparent black.
  out['no stops'] = filled((c) => c.createLinearGradient(0, 0, 32, 0), []);
  // One stop: that colour everywhere.
  out['one stop'] = filled((c) => c.createLinearGradient(0, 0, 32, 0), [[0.5, '#00ff00']]);
  // Two at the same offset, which is a hard edge — and says which of the two
  // wins on the pixel that lands exactly there.
  out['hard edge'] = filled((c) => c.createLinearGradient(0, 0, 32, 0),
    [[0, '#ff0000'], [0.5, '#ff0000'], [0.5, '#0000ff'], [1, '#0000ff']]);
  // Three stops, uneven, to pin the interpolation is per-segment.
  out['three stops'] = filled((c) => c.createLinearGradient(0, 0, 32, 0),
    [[0, '#ff0000'], [0.25, '#00ff00'], [1, '#0000ff']]);
  // Translucent ends. Premultiplied interpolation and straight interpolation
  // part company in the middle: 0x80 of red to transparent is `bf0000` in one
  // and `ff0000` scaled in the other.
  out['alpha ramp'] = filled((c) => c.createLinearGradient(0, 0, 32, 0),
    [[0, 'rgba(255,0,0,1)'], [1, 'rgba(0,0,255,0)']]);
  out['alpha ramp same hue'] = filled((c) => c.createLinearGradient(0, 0, 32, 0),
    [[0, 'rgba(255,0,0,1)'], [1, 'rgba(255,0,0,0)']]);
  // A wide-gamut stop, which says what space the stops are kept in.
  out['wide stop'] = filled((c) => c.createLinearGradient(0, 0, 32, 0),
    [[0, 'color(display-p3 1 0.25 0.5)'], [1, '#0000ff']]);

  // --- the transform ------------------------------------------------------
  // The spec says a gradient's coordinates are in the space in effect when it
  // is *used*, not when it is made. These two say whether Chrome agrees, and
  // which of the two transforms it takes.
  out['ctm at creation'] = filled((c) => c.createLinearGradient(0, 0, 16, 0), two,
    (c) => c.scale(2, 1));
  out['ctm at paint'] = row((ctx) => {
    const g = ctx.createLinearGradient(0, 0, 16, 0);
    for (const [at, colour] of two) g.addColorStop(at, colour);
    ctx.scale(2, 1);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  });
  // A translate applied only for the fill, which separates "the gradient moves
  // with the shape" from "the gradient is nailed to the bitmap".
  out['ctm translate at paint'] = row((ctx) => {
    const g = ctx.createLinearGradient(0, 0, 32, 0);
    for (const [at, colour] of two) g.addColorStop(at, colour);
    ctx.translate(8, 0);
    ctx.fillStyle = g;
    ctx.fillRect(-8, 0, W, H);
  });

  // --- radial -------------------------------------------------------------
  // Concentric, inner radius zero: the plain disc.
  out['radial disc'] = filled((c) => c.createRadialGradient(16, 4, 0, 16, 4, 16), two);
  // A non-zero inner radius, so the middle is flat.
  out['radial annulus'] = filled((c) => c.createRadialGradient(16, 4, 8, 16, 4, 16), two);
  // Offset centres, which is the cone case.
  out['radial cone'] = filled((c) => c.createRadialGradient(8, 4, 2, 20, 4, 14), two);
  // Equal radii and equal centres: degenerate, paint nothing.
  out['radial degenerate'] = filled((c) => c.createRadialGradient(16, 4, 8, 16, 4, 8), two);
  // The inner circle larger than the outer, which inverts the ramp.
  out['radial inverted'] = filled((c) => c.createRadialGradient(16, 4, 16, 16, 4, 4), two);

  // --- conic --------------------------------------------------------------
  out['conic zero'] = filled((c) => c.createConicGradient(0, 16, 4), two);
  // A quarter turn, which says the angle's sign and where zero points.
  out['conic quarter'] = filled((c) => c.createConicGradient(Math.PI / 2, 16, 4), two);
  // Read a row above the centre so the sweep is visible across it.
  out['conic off centre'] = row((ctx) => {
    const g = ctx.createConicGradient(0, 16, 4);
    for (const [at, colour] of two) g.addColorStop(at, colour);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }, 1);

  // --- the paint state ----------------------------------------------------
  // A gradient assigned and then read back, and what a stroke does with one.
  out['stroke'] = row((ctx) => {
    const g = ctx.createLinearGradient(0, 0, 32, 0);
    for (const [at, colour] of two) g.addColorStop(at, colour);
    ctx.strokeStyle = g;
    ctx.lineWidth = 8;
    ctx.beginPath();
    ctx.moveTo(0, 4);
    ctx.lineTo(32, 4);
    ctx.stroke();
  });
  // A gradient under globalAlpha, which multiplies whatever it evaluated to.
  out['global alpha'] = row((ctx) => {
    const g = ctx.createLinearGradient(0, 0, 32, 0);
    for (const [at, colour] of two) g.addColorStop(at, colour);
    ctx.globalAlpha = 0.5;
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  });
  // And a gradient casting a shadow, whose mask is the shape's alpha and so
  // varies with the gradient rather than being flat.
  out['shadow of a ramp'] = row((ctx) => {
    const g = ctx.createLinearGradient(0, 0, 16, 0);
    g.addColorStop(0, 'rgba(0,0,0,1)');
    g.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.shadowColor = '#ff0000';
    ctx.shadowBlur = 4;
    ctx.shadowOffsetY = 4;
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, 16, 2);
  }, 6);

  return JSON.stringify(out);
})();
