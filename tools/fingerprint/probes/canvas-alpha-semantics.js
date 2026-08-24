// Two things a canvas does with alpha, both of them observable through
// `getImageData` and neither of them what a straight RGBA8 buffer does.
//
//   1. `{alpha: false}` is not a hint. The bitmap starts as opaque *black*
//      rather than transparent black, every paint composites against it, and
//      `clearRect` returns to opaque black — so a script can tell an opaque
//      canvas from a transparent one without drawing anything.
//   2. The bytes are stored premultiplied and unpremultiplied again on the way
//      out, at 8 bits. A translucent pixel therefore does not read back as the
//      colour that was painted: the two roundings do not cancel.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const ctx = (settings) => {
    const c = new OffscreenCanvas(1, 1);
    return c.getContext('2d', { willReadFrequently: true, ...settings });
  };
  const read = (c, space) => hex(c.getImageData(0, 0, 1, 1, space ? { colorSpace: space } : undefined).data);

  // --- 1. the opaque canvas -------------------------------------------------
  const opaque = {};
  opaque['initial'] = ask(() => read(ctx({ alpha: false })));
  opaque['initial, alpha true'] = ask(() => read(ctx({ alpha: true })));
  opaque['attributes'] = ask(() => `${ctx({ alpha: false }).getContextAttributes().alpha}`);
  for (const notation of ['#ff0000', 'rgba(255, 0, 0, 0.5)', 'rgba(0, 0, 255, 0.25)', 'transparent']) {
    opaque[`fill ${notation}`] = ask(() => {
      const c = ctx({ alpha: false });
      c.fillStyle = notation;
      c.fillRect(0, 0, 1, 1);
      return read(c);
    });
    opaque[`fill ${notation}, alpha true`] = ask(() => {
      const c = ctx({ alpha: true });
      c.fillStyle = notation;
      c.fillRect(0, 0, 1, 1);
      return read(c);
    });
  }
  opaque['globalAlpha 0.5 then red'] = ask(() => {
    const c = ctx({ alpha: false });
    c.globalAlpha = 0.5;
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    return read(c);
  });
  opaque['clearRect'] = ask(() => {
    const c = ctx({ alpha: false });
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    c.clearRect(0, 0, 1, 1);
    return read(c);
  });
  opaque['clearRect, alpha true'] = ask(() => {
    const c = ctx({ alpha: true });
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    c.clearRect(0, 0, 1, 1);
    return read(c);
  });
  // Two translucent fills in a row: the second composites over the first.
  opaque['two half reds'] = ask(() => {
    const c = ctx({ alpha: false });
    c.fillStyle = 'rgba(255, 0, 0, 0.5)';
    c.fillRect(0, 0, 1, 1);
    c.fillRect(0, 0, 1, 1);
    return read(c);
  });
  opaque['two half reds, alpha true'] = ask(() => {
    const c = ctx({ alpha: true });
    c.fillStyle = 'rgba(255, 0, 0, 0.5)';
    c.fillRect(0, 0, 1, 1);
    c.fillRect(0, 0, 1, 1);
    return read(c);
  });
  // Resizing an opaque canvas: back to opaque black, not transparent.
  opaque['resize'] = ask(() => {
    const canvas = new OffscreenCanvas(1, 1);
    const c = canvas.getContext('2d', { alpha: false, willReadFrequently: true });
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    canvas.width = 2;
    return read(c);
  });
  // An opaque display-p3 canvas: the initial black is black in either space.
  opaque['p3 initial'] = ask(() => read(ctx({ alpha: false, colorSpace: 'display-p3' })));
  opaque['p3 half red'] = ask(() => {
    const c = ctx({ alpha: false, colorSpace: 'display-p3' });
    c.fillStyle = 'rgba(255, 0, 0, 0.5)';
    c.fillRect(0, 0, 1, 1);
    return read(c);
  });
  // The PNG of an opaque canvas, whose alpha channel is the question.
  opaque['convertToBlob size'] = ask(() => 'async, see below');

  // --- 2. premultiplied storage --------------------------------------------
  // Painted once on a transparent canvas and read straight back: whatever
  // comes out is the storage rounding, since nothing composited.
  const premultiplied = {};
  const translucent = [
    'rgba(255, 0, 0, 0.5)',
    'rgba(200, 100, 50, 0.3)',
    'rgba(1, 2, 3, 0.004)',
    'rgba(255, 255, 255, 0.1)',
    'rgba(128, 128, 128, 0.5)',
    'rgba(255, 0, 0, 0.996)',
    'rgba(37, 213, 91, 0.62)',
  ];
  for (const notation of translucent) {
    premultiplied[notation] = ask(() => {
      const c = ctx({});
      c.fillStyle = notation;
      c.fillRect(0, 0, 1, 1);
      return read(c);
    });
  }
  // Through globalAlpha instead of the colour's own alpha.
  premultiplied['globalAlpha 0.3 over solid'] = ask(() => {
    const c = ctx({});
    c.globalAlpha = 0.3;
    c.fillStyle = 'rgb(200, 100, 50)';
    c.fillRect(0, 0, 1, 1);
    return read(c);
  });
  // And what putImageData does with the same bytes, which skips compositing.
  premultiplied['putImageData'] = ask(() => {
    const c = ctx({});
    const d = new ImageData(1, 1);
    d.data[0] = 200; d.data[1] = 100; d.data[2] = 50; d.data[3] = 77;
    c.putImageData(d, 0, 0);
    return read(c);
  });

  return { opaque, premultiplied };
})()
