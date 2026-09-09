// Narrowing the 48x48 gap to the stroke rasteriser.
//
// expr-canvas-48-surfaces.js came back with radial gradients, linear
// gradients, the display-p3 fill and the multiply blend all byte-identical
// between the arms, and only two things differing: one corner pixel off by one,
// and the stroked arc -- where the differences are in ALPHA (58 against 32, 255
// against 191, 96 against 48). So the ramp read off the guard's buffer in B130
// was antialiasing coverage from its strokes, not a gradient's alpha channel.
//
// This asks which part of stroking: the paint, the curve, the width, or the
// coverage of a plain straight edge.
(() => {
  const out = {};
  const mk = () => {
    const c = new OffscreenCanvas(48, 48);
    return c.getContext('2d');
  };
  const scan = (ctx, y) => {
    const d = ctx.getImageData(0, y, 48, 1).data;
    const px = [];
    for (let x = 0; x < 48; x += 2) px.push(Array.from(d.slice(x * 4, x * 4 + 4)).join(','));
    return px.join(' ');
  };
  const alphas = (ctx) => {
    const d = ctx.getImageData(0, 0, 48, 48).data;
    const hist = {};
    for (let i = 3; i < d.length; i += 4) hist[d[i]] = (hist[d[i]] ?? 0) + 1;
    return Object.entries(hist).sort((a, b) => b[1] - a[1]).slice(0, 6)
      .map(([a, n]) => a + 'x' + n).join(' ');
  };

  // A solid-colour stroked arc: is the paint involved at all?
  try {
    const ctx = mk();
    ctx.strokeStyle = '#809900';
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.arc(24, 24, 16, 0, Math.PI * 2);
    ctx.stroke();
    out.arc_solid_row16 = scan(ctx, 16);
    out.arc_solid_alphas = alphas(ctx);
  } catch (e) { out.arc_solid_row16 = 'threw ' + e.message; }

  // A straight axis-aligned stroke on a whole-pixel grid: no antialiasing is
  // required at all, so a difference here would be the width or the geometry
  // rather than the coverage.
  try {
    const ctx = mk();
    ctx.strokeStyle = '#809900';
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(0, 24);
    ctx.lineTo(48, 24);
    ctx.stroke();
    out.line_axis_alphas = alphas(ctx);
  } catch (e) { out.line_axis_alphas = 'threw ' + e.message; }

  // The same line off the grid by half a pixel, which forces coverage.
  try {
    const ctx = mk();
    ctx.strokeStyle = '#809900';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, 24);
    ctx.lineTo(48, 24);
    ctx.stroke();
    out.line_halfpx_alphas = alphas(ctx);
  } catch (e) { out.line_halfpx_alphas = 'threw ' + e.message; }

  // A diagonal, where every pixel along it is partial coverage.
  try {
    const ctx = mk();
    ctx.strokeStyle = '#809900';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.lineTo(48, 48);
    ctx.stroke();
    out.diag_alphas = alphas(ctx);
    out.diag_row16 = scan(ctx, 16);
  } catch (e) { out.diag_alphas = 'threw ' + e.message; }

  // A filled circle, to separate "curves are flattened differently" from
  // "strokes are covered differently": a fill takes the same curve through a
  // different part of the rasteriser.
  try {
    const ctx = mk();
    ctx.fillStyle = '#809900';
    ctx.beginPath();
    ctx.arc(24, 24, 16, 0, Math.PI * 2);
    ctx.fill();
    out.arc_filled_alphas = alphas(ctx);
    out.arc_filled_row16 = scan(ctx, 16);
  } catch (e) { out.arc_filled_alphas = 'threw ' + e.message; }

  return out;
})()
