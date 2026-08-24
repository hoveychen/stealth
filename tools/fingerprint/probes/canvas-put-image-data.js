// `putImageData`, the one way pixels go back *into* a canvas.
//
// Everything else that paints goes through the drawing state — the transform,
// globalAlpha, the composite operator. This one is specified to ignore all of
// it and overwrite the bytes, so what it does is only observable by reading the
// bitmap back: how the straight-alpha bytes it takes land in a premultiplied
// store, what an ImageData in the other colour space converts to, what the
// dirty rectangle clips to, and how a float16 ImageData's channels quantise.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const ctx = (w, h, settings) =>
    new OffscreenCanvas(w, h).getContext('2d', { willReadFrequently: true, ...settings });
  const read = (c, w, h, space) =>
    hex(c.getImageData(0, 0, w, h, space ? { colorSpace: space } : undefined).data);
  // A `w` x `h` ImageData whose pixels are distinguishable from each other.
  const ramp = (w, h, settings) => {
    const d = new ImageData(w, h, settings);
    for (let i = 0; i < w * h; i++) {
      d.data.set([255, i * 16, 0, 255], i * 4);
    }
    return d;
  };

  const stored = {};
  // The store is premultiplied, so a translucent pixel does not read back as
  // the bytes that went in — the same divergence a translucent fill has.
  stored['translucent'] = ask(() => {
    const c = ctx(1, 1);
    const d = new ImageData(1, 1);
    d.data.set([200, 100, 50, 77]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });
  // An opaque canvas has nowhere to put an alpha below 255. Two alphas, to
  // tell "the alpha is forced to 255" from "the colour is stored without being
  // premultiplied and divided back out on the way to a page anyway".
  stored['translucent onto opaque canvas'] = ask(() => {
    const c = ctx(1, 1, { alpha: false });
    const d = new ImageData(1, 1);
    d.data.set([200, 100, 50, 77]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });
  stored['half-alpha onto opaque canvas'] = ask(() => {
    const c = ctx(1, 1, { alpha: false });
    const d = new ImageData(1, 1);
    d.data.set([100, 50, 25, 128]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });
  stored['opaque onto opaque canvas'] = ask(() => {
    const c = ctx(1, 1, { alpha: false });
    const d = new ImageData(1, 1);
    d.data.set([200, 100, 50, 255]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });
  // Transparent black over a painted pixel: a replace erases it, a composite
  // would leave the green alone.
  stored['transparent over painted'] = ask(() => {
    const c = ctx(1, 1);
    c.fillStyle = '#00ff00';
    c.fillRect(0, 0, 1, 1);
    c.putImageData(new ImageData(1, 1), 0, 0);
    return read(c, 1, 1);
  });
  // All the drawing state it is supposed to ignore, at once.
  stored['ignores drawing state'] = ask(() => {
    const c = ctx(1, 1);
    c.globalAlpha = 0.5;
    c.globalCompositeOperation = 'destination-atop';
    c.translate(5, 5);
    c.scale(2, 2);
    const d = new ImageData(1, 1);
    d.data.set([255, 0, 0, 255]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });

  // --- where the pixels land ------------------------------------------------
  const placed = {};
  placed['whole 2x1'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(2, 1), 0, 0);
    return read(c, 2, 1);
  });
  // A non-integer destination: `long` truncates toward zero rather than
  // rounding, if it is a `long` at all.
  placed['dx 0.9'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(1, 1), 0.9, 0);
    return read(c, 2, 1);
  });
  placed['dx -0.9'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(1, 1), -0.9, 0);
    return read(c, 2, 1);
  });
  placed['dx NaN'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(1, 1), NaN, 0);
    return read(c, 2, 1);
  });
  placed['dx 1e10'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(1, 1), 1e10, 0);
    return read(c, 2, 1);
  });
  // Partly off the left edge: the second source column is the one that lands.
  placed['dx -1'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(2, 1), -1, 0);
    return read(c, 2, 1);
  });
  placed['dx 1'] = ask(() => {
    const c = ctx(2, 1);
    c.putImageData(ramp(2, 1), 1, 0);
    return read(c, 2, 1);
  });

  // --- the dirty rectangle --------------------------------------------------
  const dirty = {};
  dirty['top-left pixel only'] = ask(() => {
    const c = ctx(2, 2);
    c.putImageData(ramp(2, 2), 0, 0, 0, 0, 1, 1);
    return read(c, 2, 2);
  });
  dirty['bottom-right pixel only'] = ask(() => {
    const c = ctx(2, 2);
    c.putImageData(ramp(2, 2), 0, 0, 1, 1, 1, 1);
    return read(c, 2, 2);
  });
  // A negative extent flips the rectangle about its origin rather than being
  // refused, the way getImageData's window does.
  dirty['negative extents'] = ask(() => {
    const c = ctx(2, 2);
    c.putImageData(ramp(2, 2), 0, 0, 1, 1, -1, -1);
    return read(c, 2, 2);
  });
  dirty['oversized'] = ask(() => {
    const c = ctx(2, 2);
    c.putImageData(ramp(2, 2), 0, 0, -5, -5, 20, 20);
    return read(c, 2, 2);
  });
  dirty['zero width'] = ask(() => {
    const c = ctx(2, 2);
    c.putImageData(ramp(2, 2), 0, 0, 0, 0, 0, 2);
    return read(c, 2, 2);
  });
  // The dirty rectangle is in the ImageData's own coordinates; the destination
  // offset moves where that piece of it lands.
  dirty['offset destination'] = ask(() => {
    const c = ctx(2, 2);
    c.putImageData(ramp(2, 2), 1, 1, 0, 0, 1, 1);
    return read(c, 2, 2);
  });

  // --- colour space and pixel format ---------------------------------------
  const formats = {};
  formats['srgb data onto display-p3 canvas'] = ask(() => {
    const c = ctx(1, 1, { colorSpace: 'display-p3' });
    const d = new ImageData(1, 1, { colorSpace: 'srgb' });
    d.data.set([255, 0, 0, 255]);
    c.putImageData(d, 0, 0);
    return `${read(c, 1, 1, 'display-p3')} / ${read(c, 1, 1, 'srgb')}`;
  });
  formats['display-p3 data onto srgb canvas'] = ask(() => {
    const c = ctx(1, 1, { colorSpace: 'srgb' });
    const d = new ImageData(1, 1, { colorSpace: 'display-p3' });
    d.data.set([255, 0, 0, 255]);
    c.putImageData(d, 0, 0);
    return `${read(c, 1, 1, 'srgb')} / ${read(c, 1, 1, 'display-p3')}`;
  });
  formats['display-p3 data onto display-p3 canvas'] = ask(() => {
    const c = ctx(1, 1, { colorSpace: 'display-p3' });
    const d = new ImageData(1, 1, { colorSpace: 'display-p3' });
    d.data.set([255, 0, 0, 255]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1, 'display-p3');
  });
  // A float16 ImageData's channels are 0..1 floats, and the bitmap underneath
  // is still eight bits a channel.
  formats['float16 data'] = ask(() => {
    const c = ctx(1, 1);
    const d = new ImageData(1, 1, { pixelFormat: 'rgba-float16' });
    d.data.set([1, 0.5, 0.2, 1]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });
  formats['float16 data out of range'] = ask(() => {
    const c = ctx(1, 1);
    const d = new ImageData(1, 1, { pixelFormat: 'rgba-float16' });
    d.data.set([2, -1, 0.5, 1]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });
  formats['float16 translucent'] = ask(() => {
    const c = ctx(1, 1);
    const d = new ImageData(1, 1, { pixelFormat: 'rgba-float16' });
    d.data.set([200 / 255, 100 / 255, 50 / 255, 77 / 255]);
    c.putImageData(d, 0, 0);
    return read(c, 1, 1);
  });

  // --- the call itself ------------------------------------------------------
  const call = {};
  call['length'] = OffscreenCanvasRenderingContext2D.prototype.putImageData.length;
  call['returns'] = ask(() => `${ctx(1, 1).putImageData(new ImageData(1, 1), 0, 0)}`);
  call['four arguments'] = ask(() => {
    ctx(1, 1).putImageData(new ImageData(1, 1), 0, 0, 0);
    return 'ok';
  });
  call['non-ImageData'] = ask(() => {
    ctx(1, 1).putImageData({ width: 1, height: 1, data: new Uint8ClampedArray(4) }, 0, 0);
    return 'ok';
  });
  call['no arguments'] = ask(() => {
    ctx(1, 1).putImageData();
    return 'ok';
  });

  return { stored, placed, dirty, formats, call };
})()
