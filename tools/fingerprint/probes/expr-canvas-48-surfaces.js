// The three surfaces the guard's 48x48 canvas fingerprint is built from, each
// on its own, so the 1876-of-2304 pixel gap can be attributed rather than
// guessed at.
//
// B130 established what this has to reproduce: the guard issues 54 drawing
// calls and both arms receive them byte-identically, in the same order, while
// the 48x48 they produce differs in 1876 of 2304 pixels. Two served Chrome runs
// give byte-identical buffers, so the drawing is deterministic and the gap is
// ours. Everything upstream of rasterisation is ruled out; what is left is
// radial gradients, a display-p3 fill, and a multiply blend.
//
// The parameters here are the guard's own, copied off a served capture
// (scratch/b130/fo-ch-1.json) rather than invented -- a probe that draws
// something else measures something else.
//
// Read as a census rather than 9216 bytes: the row-16 scanline for the
// gradients (where the ramp is), plus the exact quad for the flat cases.
(() => {
  const out = {};
  const mk = () => {
    const c = new OffscreenCanvas(48, 48);
    return [c, c.getContext('2d')];
  };
  const quad = (ctx, x, y) => Array.from(ctx.getImageData(x, y, 1, 1).data);
  // Every 4th pixel of a row, so the ramp is visible without 48 numbers.
  const scan = (ctx, y) => {
    const d = ctx.getImageData(0, y, 48, 1).data;
    const px = [];
    for (let x = 0; x < 48; x += 4) px.push(Array.from(d.slice(x * 4, x * 4 + 4)).join(','));
    return px.join(' | ');
  };

  // A control first: if a flat fill of a plain colour disagrees, nothing below
  // means anything.
  try {
    const [, ctx] = mk();
    ctx.fillStyle = '#809900';
    ctx.fillRect(0, 0, 48, 48);
    out.control_flat = quad(ctx, 24, 24).join(',');
  } catch (e) { out.control_flat = 'threw ' + e.message; }

  // (1) The guard's first radial gradient, filled over the whole surface. Its
  // r1 is 226 against a 48px box, so the visible part is the very start of the
  // ramp -- which is exactly where the alpha climb was measured to be wrong.
  try {
    const [, ctx] = mk();
    const g = ctx.createRadialGradient(33, 18, 8, 42, 10, 226);
    g.addColorStop(0, '#809900');
    g.addColorStop(1, '#404041');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, 48, 48);
    out.radial_row16 = scan(ctx, 16);
    out.radial_centre = quad(ctx, 33, 18).join(',');
    out.radial_corner = quad(ctx, 47, 47).join(',');
  } catch (e) { out.radial_row16 = 'threw ' + e.message; }

  // (2) A second one with a different stop pair, because the first pair is grey
  // to olive and a hue-dependent bug would hide in it.
  try {
    const [, ctx] = mk();
    const g = ctx.createRadialGradient(108, 12, 10, 65, 118, 169);
    g.addColorStop(0, '#1AB399');
    g.addColorStop(1, '#E666B3');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, 48, 48);
    out.radial2_row16 = scan(ctx, 16);
  } catch (e) { out.radial2_row16 = 'threw ' + e.message; }

  // (3) A linear gradient over the same box, to say whether the interpolation
  // itself is wrong or only the radial distance metric feeding it.
  try {
    const [, ctx] = mk();
    const g = ctx.createLinearGradient(0, 0, 48, 0);
    g.addColorStop(0, '#809900');
    g.addColorStop(1, '#404041');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, 48, 48);
    out.linear_row16 = scan(ctx, 16);
  } catch (e) { out.linear_row16 = 'threw ' + e.message; }

  // (4) The display-p3 fill, which is a wide-gamut colour asked of an sRGB
  // surface -- the conversion is the thing being measured.
  try {
    const [, ctx] = mk();
    ctx.fillStyle = 'color(display-p3 1 0.25 0.5)';
    out.p3_style = ctx.fillStyle;
    ctx.fillRect(0, 0, 2, 2);
    out.p3_pixel = quad(ctx, 0, 0).join(',');
  } catch (e) { out.p3_pixel = 'threw ' + e.message; }

  // (5) The multiply blend, on the guard's own colour pair.
  try {
    const [, ctx] = mk();
    ctx.fillStyle = '#ff22ff';
    ctx.fillRect(0, 0, 48, 48);
    ctx.globalCompositeOperation = 'multiply';
    out.multiply_op = ctx.globalCompositeOperation;
    ctx.fillStyle = '#22ffff';
    ctx.fillRect(0, 0, 48, 48);
    out.multiply_pixel = quad(ctx, 24, 24).join(',');
    ctx.fillStyle = '#ffff22';
    ctx.fillRect(0, 0, 48, 48);
    out.multiply_pixel2 = quad(ctx, 24, 24).join(',');
  } catch (e) { out.multiply_pixel = 'threw ' + e.message; }

  // (6) A stroke of a gradient, since the guard strokes each one before it
  // fills it and a stroke takes a different path through the rasteriser.
  try {
    const [, ctx] = mk();
    const g = ctx.createRadialGradient(33, 18, 8, 42, 10, 226);
    g.addColorStop(0, '#809900');
    g.addColorStop(1, '#404041');
    ctx.strokeStyle = g;
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.arc(24, 24, 16, 0, Math.PI * 2);
    ctx.stroke();
    out.stroke_row16 = scan(ctx, 16);
  } catch (e) { out.stroke_row16 = 'threw ' + e.message; }

  return out;
})()
