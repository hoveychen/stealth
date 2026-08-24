// `ImageDataSettings`: the dictionary the ImageData constructor,
// createImageData and getImageData all share, and the pixels that come back
// through it.
//
// Two axes ride in one dictionary and have to be kept apart. `colorSpace`
// decides the space the bytes are *converted to* on the way out; `pixelFormat`
// decides how many bytes there are per pixel at all. The Turnstile widget uses
// both — four canvases over {srgb, display-p3} x {unorm8, float16}, each read
// back in its own space (results/ibt2-oracle.json).
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');

  // A canvas in `canvasSpace`, filled with `notation`, read back through
  // `settings`. Reports the bytes, the space the ImageData claims, its
  // pixelFormat, and how many array entries one pixel took.
  const read = (canvasSpace, notation, settings) => ask(() => {
    const c = new OffscreenCanvas(1, 1);
    const ctx = c.getContext('2d', { colorSpace: canvasSpace, willReadFrequently: true });
    ctx.fillStyle = notation;
    ctx.fillRect(0, 0, 1, 1);
    const d = settings === undefined
      ? ctx.getImageData(0, 0, 1, 1)
      : ctx.getImageData(0, 0, 1, 1, settings);
    const bytes = d.data.length <= 8 ? hex(d.data) : `${d.data.length}B`;
    return `${bytes} ${d.colorSpace} ${d.pixelFormat} len=${d.data.length} ${d.data.constructor.name}`;
  });

  const pixels = {};
  for (const canvasSpace of ['srgb', 'display-p3']) {
    for (const notation of ['#ff0000', 'color(display-p3 1 0.25 0.5)']) {
      // Default settings, then each colour space named explicitly.
      pixels[`${canvasSpace} | ${notation} | default`] = read(canvasSpace, notation, undefined);
      for (const cs of ['srgb', 'display-p3']) {
        pixels[`${canvasSpace} | ${notation} | ${cs}`] =
          read(canvasSpace, notation, { colorSpace: cs });
      }
      pixels[`${canvasSpace} | ${notation} | float16`] =
        read(canvasSpace, notation, { pixelFormat: 'rgba-float16' });
    }
  }

  // The refusals, and which gate each comes from.
  const settingsErrors = {};
  for (const cs of ['srgb', 'display-p3', 'rec2020', 'display-p3-linear', 'nonesuch', null, undefined]) {
    settingsErrors[`getImageData colorSpace ${cs}`] = read('srgb', '#ff0000', { colorSpace: cs });
  }
  for (const pf of ['rgba-unorm8', 'rgba-float16', 'rgba-uint8', 'nonesuch', null, undefined]) {
    settingsErrors[`getImageData pixelFormat ${pf}`] = read('srgb', '#ff0000', { pixelFormat: pf });
  }
  for (const bad of ['nope', 42, true, [], null]) {
    settingsErrors[`getImageData non-object ${JSON.stringify(bad)}`] =
      read('srgb', '#ff0000', bad);
  }

  // The constructor and createImageData take the same dictionary.
  const constructed = {};
  for (const cs of ['srgb', 'display-p3', 'rec2020', 'nonesuch']) {
    constructed[`new ImageData cs=${cs}`] = ask(() => {
      const d = new ImageData(1, 1, { colorSpace: cs });
      return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length}`;
    });
  }
  for (const pf of ['rgba-unorm8', 'rgba-float16', 'nonesuch']) {
    constructed[`new ImageData pf=${pf}`] = ask(() => {
      const d = new ImageData(1, 1, { pixelFormat: pf });
      return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length} ${d.data.constructor.name}`;
    });
  }
  constructed['new ImageData default'] = ask(() => {
    const d = new ImageData(1, 1);
    return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length} ${d.data.constructor.name}`;
  });
  constructed['createImageData cs=display-p3'] = ask(() => {
    const d = new OffscreenCanvas(1, 1).getContext('2d')
      .createImageData(1, 1, { colorSpace: 'display-p3' });
    return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length}`;
  });
  constructed['createImageData pf=rgba-float16'] = ask(() => {
    const d = new OffscreenCanvas(1, 1).getContext('2d')
      .createImageData(1, 1, { pixelFormat: 'rgba-float16' });
    return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length} ${d.data.constructor.name}`;
  });
  // From an existing ImageData, whose settings are inherited rather than given.
  constructed['createImageData from ImageData'] = ask(() => {
    const src = new ImageData(2, 2, { colorSpace: 'display-p3' });
    const d = new OffscreenCanvas(1, 1).getContext('2d').createImageData(src);
    return `${d.colorSpace} ${d.pixelFormat} ${d.width}x${d.height}`;
  });
  // A data-array constructor, which is the form that can disagree with itself.
  constructed['new ImageData(data, w, h, settings)'] = ask(() => {
    const d = new ImageData(new Uint8ClampedArray(4), 1, 1, { colorSpace: 'display-p3' });
    return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length}`;
  });

  // `putImageData` is the way back in: does the space of the ImageData matter?
  const roundTrip = ask(() => {
    const c = new OffscreenCanvas(1, 1);
    const ctx = c.getContext('2d', { colorSpace: 'display-p3', willReadFrequently: true });
    const d = new ImageData(1, 1, { colorSpace: 'srgb' });
    d.data[0] = 255; d.data[3] = 255;
    ctx.putImageData(d, 0, 0);
    const back = ctx.getImageData(0, 0, 1, 1, { colorSpace: 'display-p3' });
    return `${hex(back.data)} ${back.colorSpace}`;
  });

  return { pixels, settingsErrors, constructed, roundTrip };
})()
