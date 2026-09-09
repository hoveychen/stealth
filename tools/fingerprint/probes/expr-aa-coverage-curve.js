// The antialiasing coverage transfer function, on both arms.
//
// expr-canvas-48-stroke.js narrowed the guard's 48x48 gap to the fractional
// coverage of non-axis-aligned edges: diagonals and arcs differ in their
// partial-coverage alphas while the fully covered and empty pixel counts match,
// and axis-aligned strokes agree outright. This asks the question that decides
// whether the gap is fixable: is our coverage the same function as Skia's with
// different rounding, or a different function?
//
// Two sweeps:
//   - an axis-aligned edge at 16 sub-pixel positions. Coverage here is just the
//     fractional part, so any engine that antialiases at all should trace the
//     same straight line. A difference is pure rounding.
//   - a slanted edge at 16 slopes. This is where analytic AA earns its name,
//     and where the arcs and diagonals went wrong.
(() => {
  const out = {};
  const ctx48 = () => new OffscreenCanvas(48, 48).getContext('2d');
  const alphaAt = (ctx, x, y) => ctx.getImageData(x, y, 1, 1).data[3];

  // (1) Axis-aligned: the right edge of a rect lands at x = 24 + f/16, so
  // column 24 should carry exactly f/16 coverage.
  const axis = [];
  for (let f = 0; f < 16; f++) {
    const ctx = ctx48();
    ctx.fillStyle = '#000000';
    ctx.fillRect(8, 8, 16 + f / 16, 16);
    axis.push(alphaAt(ctx, 24, 12));
  }
  out.axis_sweep = axis.join(',');
  out.axis_expected = Array.from({ length: 16 }, (_, f) => Math.round(255 * f / 16)).join(',');

  // (2) Slanted: a triangle whose hypotenuse crosses row 24 at a known place,
  // swept through 16 slopes. Read the alpha just left of the crossing.
  const slant = [];
  for (let s = 1; s <= 16; s++) {
    const ctx = ctx48();
    ctx.fillStyle = '#000000';
    ctx.beginPath();
    ctx.moveTo(4, 4);
    ctx.lineTo(4 + s * 2.5, 44);
    ctx.lineTo(4, 44);
    ctx.closePath();
    ctx.fill();
    // Sample a few pixels across the hypotenuse at row 24, where coverage is
    // partial for exactly one or two columns.
    const d = ctx.getImageData(0, 24, 48, 1).data;
    const partial = [];
    for (let x = 0; x < 48; x++) {
      const a = d[x * 4 + 3];
      if (a > 0 && a < 255) partial.push(x + ':' + a);
    }
    slant.push('s' + s + '=' + (partial.join('/') || 'none'));
  }
  out.slant_sweep = slant.join('  ');

  // (3) The same triangle at one slope, but read as a histogram, so a
  // systematic offset is visible without matching pixel positions.
  const ctx = ctx48();
  ctx.fillStyle = '#000000';
  ctx.beginPath();
  ctx.moveTo(4, 4);
  ctx.lineTo(30, 44);
  ctx.lineTo(4, 44);
  ctx.closePath();
  ctx.fill();
  const d = ctx.getImageData(0, 0, 48, 48).data;
  const hist = {};
  for (let i = 3; i < d.length; i += 4) if (d[i] > 0 && d[i] < 255) hist[d[i]] = (hist[d[i]] ?? 0) + 1;
  const keys = Object.keys(hist).map(Number).sort((a, b) => a - b);
  out.tri_partial_count = keys.reduce((n, k) => n + hist[k], 0);
  out.tri_partial_distinct = keys.length;
  out.tri_partial_min_max = keys.length ? keys[0] + '..' + keys[keys.length - 1] : 'none';
  out.tri_partial_values = keys.join(',');
  return out;
})()
