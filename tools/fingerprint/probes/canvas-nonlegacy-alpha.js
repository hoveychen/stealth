// Is a fill's alpha a byte, or a float? CSS Color 4 splits the notations into
// *legacy* ones -- `#hex`, a name, `rgb()`, `rgba()`, `hsl()`, `hsla()` -- and
// the modern ones, `hwb()` included. A float16 bitmap keeps whatever it is
// handed, so reading the alpha channel back off one answers the question
// directly rather than inferring it from a premultiply round trip.
//
// `0.5` and `0.501953125` (half precision's neighbour of 128/255) are distinct
// halves, so a byte alpha is visible on sight.
//
// The notation axis comes out clean: every legacy notation with a *number*
// alpha answers the byte, and every modern one answers the float. The rows
// with a *percentage* alpha are a second axis and are not: `rgb(255 0 0 /
// 50%)`, `hsl(30 60% 40% / 50%)` and `hsla(30, 60%, 40%, 50%)` all keep the
// float, but `rgba(255, 0, 0, 50%)` does not. Nothing here explains that one,
// so it is measured and left alone rather than turned into a rule.
(() => {
  const read = (space, notation) => {
    const ctx = new OffscreenCanvas(1, 1).getContext('2d', {
      colorSpace: space,
      colorType: 'float16',
      willReadFrequently: true,
    });
    ctx.fillStyle = notation;
    ctx.fillRect(0, 0, 1, 1);
    return [...ctx.getImageData(0, 0, 1, 1, { pixelFormat: 'rgba-float16' }).data][3];
  };
  const notations = [
    // Legacy, in every syntax that carries an alpha.
    '#ff000080',
    'rgba(255, 0, 0, 0.5)',
    'rgb(255 0 0 / 0.5)',
    'rgb(255 0 0 / 50%)',
    'hsl(30 60% 40% / 0.5)',
    'hsla(30, 60%, 40%, 0.5)',
    // Modern, which the spec does not call legacy.
    'hwb(200 10% 20% / 0.5)',
    'hwb(45 15% 35% / 0.5)',
    'lab(50 40 30 / 0.5)',
    'oklch(0.7 0.1 200 / 0.5)',
    'color(display-p3 1 0.25 0.5 / 0.5)',
    'color(srgb 1 0 0 / 0.5)',
    // Two more alphas, where a byte and a float part further: 0.3 is 76.5/255
    // and 0.7 is 178.5/255, both of them exactly half a byte.
    'rgba(255, 0, 0, 0.3)',
    'hwb(200 10% 20% / 0.3)',
    'rgba(255, 0, 0, 0.7)',
    'hwb(200 10% 20% / 0.7)',
    // And the alpha written as a percentage rather than a number, in every
    // legacy notation that takes one.
    'rgb(255 0 0 / 30%)',
    'rgba(255, 0, 0, 50%)',
    'hsl(30 60% 40% / 50%)',
    'hsla(30, 60%, 40%, 50%)',
    'hsl(30 60% 40% / 30%)',
    'hwb(200 10% 20% / 50%)',
    'lab(50 40 30 / 50%)',
    // Eight-digit hex, where the alpha has nowhere to be but a byte.
    '#ff00004d',
  ];
  const out = {};
  for (const space of ['srgb', 'display-p3']) {
    out[space] = {};
    for (const notation of notations) out[space][notation] = String(read(space, notation));
  }
  return JSON.stringify(out);
})();
