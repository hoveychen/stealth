// Which colour space a gradient's stops interpolate in, by notation.
//
// `probes/canvas-gradient-paint.js` found one row that no per-channel sRGB ramp
// reproduces -- a `color(display-p3 ...)` stop -- and Oklab reproduces it to the
// byte. Oklab is CSS Color 4's default interpolation space, which applies to any
// pair that is not *both* legacy sRGB. That rule is an inference from a single
// reading; these rows are what would confirm or kill it.
//
// Every pair below is the same red-to-blue ramp written differently, so a row
// that matches `legacy` interpolated in sRGB and a row that does not tells the
// two spaces apart without any colour arithmetic: red to blue is exactly where
// the two ramps part company hardest.
(() => {
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const W = 32, H = 8;
  const filled = (stops) => {
    const ctx = new OffscreenCanvas(W, H).getContext('2d', { willReadFrequently: true });
    const g = ctx.createLinearGradient(0, 0, W, 0);
    for (const [at, colour] of stops) g.addColorStop(at, colour);
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    return hex(ctx.getImageData(0, 4, W, 1).data);
  };

  const blue = '#0000ff';
  const out = {};

  // The baseline: two legacy notations, which the existing probe already shows
  // is a per-channel sRGB ramp. Every row below is "same colours, is it this?".
  out['hex to hex'] = filled([[0, '#ff0000'], [1, blue]]);
  // Legacy `rgb()` in modern space-separated syntax -- still legacy per the spec.
  out['rgb modern'] = filled([[0, 'rgb(255 0 0)'], [1, blue]]);
  out['rgb legacy commas'] = filled([[0, 'rgb(255, 0, 0)'], [1, blue]]);
  // `hsl()` is legacy too; `hwb()` is not, though both are sRGB.
  out['hsl'] = filled([[0, 'hsl(0 100% 50%)'], [1, blue]]);
  out['hwb'] = filled([[0, 'hwb(0 0% 0%)'], [1, blue]]);
  // `color(srgb ...)` is the same colour as `#ff0000` in the same gamut and is
  // *not* legacy. If notation alone decides, this row differs from the first.
  out['color srgb'] = filled([[0, 'color(srgb 1 0 0)'], [1, blue]]);
  // The Lab family, which is non-legacy and out of sRGB's gamut at the red end.
  out['oklch'] = filled([[0, 'oklch(0.62796 0.25768 29.234)'], [1, blue]]);
  out['lab'] = filled([[0, 'lab(54.29 80.8 69.89)'], [1, blue]]);
  // Wide gamut on one end (the reading that started this) and on both.
  out['p3 to hex'] = filled([[0, 'color(display-p3 1 0.25 0.5)'], [1, blue]]);
  out['p3 to p3'] = filled([[0, 'color(display-p3 1 0.25 0.5)'], [1, 'color(display-p3 0 0 1)']]);
  // Three stops with the non-legacy one in the middle: does one such stop take
  // the whole ramp to Oklab, or only the segments it is an end of? The first
  // half and the second half answer separately.
  out['legacy wide legacy'] = filled([
    [0, '#ff0000'], [0.5, 'color(display-p3 0 1 0)'], [1, blue],
  ]);
  // The same shape with every stop legacy, to read the row above against.
  out['legacy legacy legacy'] = filled([
    [0, '#ff0000'], [0.5, '#00ff00'], [1, blue],
  ]);
  // The discriminator for "does one non-legacy stop take the whole ramp, or
  // only the segments it ends?": the first half is legacy on both ends and the
  // second half is not. If the first sixteen pixels match `legacy legacy
  // legacy`'s first sixteen, the choice is per segment.
  out['legacy legacy wide'] = filled([
    [0, '#ff0000'], [0.5, '#00ff00'], [1, 'color(srgb 0 0 1)'],
  ]);
  // And the mirror, so the answer does not rest on one end.
  out['wide legacy legacy'] = filled([
    [0, 'color(srgb 1 0 0)'], [0.5, '#00ff00'], [1, blue],
  ]);
  // Alpha across the two spaces: a non-legacy pair that also ramps alpha, since
  // Oklab interpolation is specified on unpremultiplied colours and this engine
  // interpolates alpha separately either way.
  out['hwb alpha ramp'] = filled([[0, 'hwb(0 0% 0% / 1)'], [1, 'hwb(240 0% 0% / 0)']]);
  out['legacy alpha ramp'] = filled([[0, 'rgba(255,0,0,1)'], [1, 'rgba(0,0,255,0)']]);

  return JSON.stringify(out);
})();
