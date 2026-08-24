// What a `shadowBlur` actually puts on the bitmap: how far it spreads and what
// the falloff is. The widget's 48x48 scene sets five of them -- 11, 16, 3, 4
// and 14 -- under a `scale(0.384, 0.384)`, and this engine draws none of them,
// which is the largest single-pixel divergence left in that render.
//
// The shape is offset clear of its own shadow (`shadowOffsetX` of 48 against a
// 4px square at x=4), so every reading below is the shadow alone with nothing
// composited over it. One row through the shadow's centre is the whole curve:
// a box or Gaussian blur of a square is separable, so the row *is* the kernel.
(() => {
  const W = 96, H = 32;
  const profile = (blur, scale) => {
    const ctx = new OffscreenCanvas(W, H).getContext('2d', { willReadFrequently: true });
    if (scale !== 1) ctx.scale(scale, scale);
    ctx.shadowColor = '#ff0000';
    ctx.shadowBlur = blur;
    // Not divided by the scale: the offset is in the output bitmap's space and
    // the transform does not reach it. Measured -- dividing it by 0.384 puts
    // the shadow at device x=129 on a 96-wide bitmap and nothing is drawn.
    ctx.shadowOffsetX = 48;
    ctx.shadowOffsetY = 0;
    ctx.fillStyle = '#000000';
    ctx.fillRect(4 / scale, 14 / scale, 4 / scale, 4 / scale);
    const row = ctx.getImageData(0, 16, W, 1).data;
    const alpha = [];
    for (let x = 0; x < W; x++) alpha.push(row[x * 4 + 3]);
    // Trim the leading run of zeros so the answer is `first index, values`.
    let lo = 0;
    while (lo < W && alpha[lo] === 0) lo++;
    let hi = W - 1;
    while (hi >= 0 && alpha[hi] === 0) hi--;
    if (lo > hi) return 'empty';
    return lo + ':' + alpha.slice(lo, hi + 1).join(',');
  };

  // The same sweep against a bar the full height of the bitmap. A separable
  // blur of a 4x4 square hands back the *product* of the two axes' responses,
  // so a row through it is the kernel squared; against a full-height bar the
  // vertical factor is 1 all the way down the middle and the row is the
  // one-dimensional kernel itself.
  const bar = (blur) => {
    const ctx = new OffscreenCanvas(W, H).getContext('2d', { willReadFrequently: true });
    ctx.shadowColor = '#ff0000';
    ctx.shadowBlur = blur;
    ctx.shadowOffsetX = 48;
    ctx.fillStyle = '#000000';
    ctx.fillRect(4, -32, 4, H + 64);
    const row = ctx.getImageData(0, 16, W, 1).data;
    const alpha = [];
    for (let x = 0; x < W; x++) alpha.push(row[x * 4 + 3]);
    let lo = 0;
    while (lo < W && alpha[lo] === 0) lo++;
    let hi = W - 1;
    while (hi >= 0 && alpha[hi] === 0) hi--;
    return lo > hi ? 'empty' : lo + ':' + alpha.slice(lo, hi + 1).join(',');
  };

  const out = { unscaled: {}, scaled: {}, bar: {} };
  for (const blur of [1, 2, 3, 4, 5, 6, 8, 11, 14, 16, 20, 32]) {
    out.bar[String(blur)] = bar(blur);
  }
  for (const blur of [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 14, 16, 20, 32]) {
    out.unscaled[String(blur)] = profile(blur, 1);
  }
  // The widget's own transform. If the blur is in user space the spread grows
  // with the shape; if it is in device space it does not move at all.
  for (const blur of [3, 4, 11, 14, 16]) {
    out.scaled[String(blur)] = profile(blur, 0.384);
  }

  // The rest of the shadow state, one reading each, all at a fixed radius.
  const one = (build) => {
    const ctx = new OffscreenCanvas(W, H).getContext('2d', { willReadFrequently: true });
    build(ctx);
    const row = ctx.getImageData(0, 16, W, 1).data;
    const px = [];
    for (const x of [6, 40, 48, 54, 60]) {
      px.push([...row.slice(x * 4, x * 4 + 4)].map((b) => b.toString(16).padStart(2, '0')).join(''));
    }
    return px.join(' ');
  };
  out.state = {
    // The reference every row below is read against: an opaque shape, an
    // opaque shadow colour, the same radius and the same offset.
    'reference': one((ctx) => {
      ctx.shadowColor = '#ff0000';
      ctx.shadowBlur = 8;
      ctx.shadowOffsetX = 48;
      ctx.fillStyle = '#000000';
      ctx.fillRect(4, 14, 4, 4);
    }),
    // The shape drawn over its own shadow: no offset, so the two overlap.
    'no offset': one((ctx) => {
      ctx.shadowColor = '#ff0000';
      ctx.shadowBlur = 8;
      ctx.fillStyle = '#000000';
      ctx.fillRect(52, 14, 4, 4);
    }),
    // A translucent shadow colour, which says whether the alpha multiplies
    // the coverage or replaces it.
    'shadowColor alpha': one((ctx) => {
      ctx.shadowColor = 'rgba(255, 0, 0, 0.5)';
      ctx.shadowBlur = 8;
      ctx.shadowOffsetX = 48;
      ctx.fillStyle = '#000000';
      ctx.fillRect(4, 14, 4, 4);
    }),
    // A fully transparent shadow colour, which the spec says draws nothing.
    'shadowColor transparent': one((ctx) => {
      ctx.shadowColor = 'transparent';
      ctx.shadowBlur = 8;
      ctx.shadowOffsetX = 48;
      ctx.fillStyle = '#000000';
      ctx.fillRect(4, 14, 4, 4);
    }),
    // An offset with no blur at all, which is the shape itself moved.
    'offset only': one((ctx) => {
      ctx.shadowColor = '#ff0000';
      ctx.shadowBlur = 0;
      ctx.shadowOffsetX = 48;
      ctx.fillStyle = '#000000';
      ctx.fillRect(4, 14, 4, 4);
    }),
    // A translucent *shape*, which says whether the shadow takes the shape's
    // alpha or only its coverage.
    'translucent shape': one((ctx) => {
      ctx.shadowColor = '#ff0000';
      ctx.shadowBlur = 8;
      ctx.shadowOffsetX = 48;
      ctx.fillStyle = 'rgba(0, 0, 0, 0.5)';
      ctx.fillRect(4, 14, 4, 4);
    }),
    // A stroke rather than a fill, which is what four of the widget's five
    // shadowed ops are.
    'stroke': one((ctx) => {
      ctx.shadowColor = '#ff0000';
      ctx.shadowBlur = 8;
      ctx.shadowOffsetX = 48;
      ctx.strokeStyle = '#000000';
      ctx.lineWidth = 2;
      ctx.strokeRect(4, 14, 4, 4);
    }),
  };
  return JSON.stringify(out);
})();
