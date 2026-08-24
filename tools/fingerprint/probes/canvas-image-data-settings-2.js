// `ImageDataSettings`, second pass: the edges the first probe left unmeasured.
//
// Which of the two refusals a non-object argument gets differs *per entry
// point* — `getContext`'s dictionary takes the defaults, `getImageData`'s
// refuses — so the constructor and createImageData have to be measured rather
// than assumed. The rest is what a detector reads without touching a pixel:
// the arities, where `colorSpace` lives on the object, and which check runs
// first when two of them would both fail.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };
  const ctx2d = () => new OffscreenCanvas(2, 2).getContext('2d');

  // A non-object where a dictionary goes, per entry point.
  const nonObject = {};
  for (const bad of ['nope', 42, true, [], null, undefined]) {
    const label = JSON.stringify(bad) ?? 'undefined';
    nonObject[`new ImageData ${label}`] = ask(() => {
      const d = new ImageData(1, 1, bad);
      return `${d.colorSpace} ${d.pixelFormat}`;
    });
    nonObject[`createImageData ${label}`] = ask(() => {
      const d = ctx2d().createImageData(1, 1, bad);
      return `${d.colorSpace} ${d.pixelFormat}`;
    });
  }

  // Arities: the optional dictionary is not counted.
  const arity = {
    'ImageData': ImageData.length,
    'getImageData': OffscreenCanvasRenderingContext2D.prototype.getImageData.length,
    'createImageData': OffscreenCanvasRenderingContext2D.prototype.createImageData.length,
    'putImageData': OffscreenCanvasRenderingContext2D.prototype.putImageData.length,
  };

  // Where the two read-only members live, and as what.
  const describe = (o, name) => {
    const own = Object.getOwnPropertyDescriptor(o, name);
    const proto = Object.getOwnPropertyDescriptor(ImageData.prototype, name);
    const shape = (d) => (d === undefined ? 'absent' : d.get ? `get enumerable=${d.enumerable}` : `value enumerable=${d.enumerable} writable=${d.writable}`);
    return `own=${shape(own)} proto=${shape(proto)}`;
  };
  const d0 = new ImageData(1, 1);
  const descriptors = {
    colorSpace: describe(d0, 'colorSpace'),
    pixelFormat: describe(d0, 'pixelFormat'),
    data: describe(d0, 'data'),
  };

  // Which check wins when two would fail. A getter records that it ran.
  const order = {};
  order['colorSpace vs pixelFormat'] = ask(() => {
    const seen = [];
    ctx2d().getImageData(0, 0, 1, 1, {
      get colorSpace() { seen.push('colorSpace'); return 'srgb'; },
      get pixelFormat() { seen.push('pixelFormat'); return 'rgba-unorm8'; },
    });
    return seen.join(',');
  });
  // A zero-sized rect *and* a bad member: is the dictionary read first?
  order['zero rect vs bad colorSpace'] = ask(() => {
    ctx2d().getImageData(0, 0, 0, 0, { colorSpace: 'nonesuch' });
    return 'no throw';
  });
  order['zero rect alone'] = ask(() => {
    ctx2d().getImageData(0, 0, 0, 0);
    return 'no throw';
  });
  order['bad colorSpace with good rect'] = ask(() => {
    ctx2d().getImageData(0, 0, 1, 1, { colorSpace: 'nonesuch' });
    return 'no throw';
  });
  // createImageData's own refusals, which name a different method.
  order['createImageData bad colorSpace'] = ask(() => ctx2d().createImageData(1, 1, { colorSpace: 'nonesuch' }));
  order['createImageData gate two'] = ask(() => ctx2d().createImageData(1, 1, { colorSpace: 'rec2020' }));
  order['createImageData from float16'] = ask(() => {
    const src = new ImageData(2, 2, { pixelFormat: 'rgba-float16', colorSpace: 'display-p3' });
    const d = ctx2d().createImageData(src);
    return `${d.colorSpace} ${d.pixelFormat} ${d.data.constructor.name}`;
  });
  // The element's context names itself in its refusals.
  order['HTMLCanvasElement getImageData'] = ask(() => {
    const c = document.createElement('canvas');
    return c.getContext('2d').getImageData(0, 0, 1, 1, { colorSpace: 'nonesuch' });
  });
  order['HTMLCanvasElement createImageData'] = ask(() => {
    const c = document.createElement('canvas');
    return c.getContext('2d').createImageData(1, 1, { colorSpace: 'nonesuch' });
  });

  // The conversion, on a plain srgb canvas: the only axis reachable without the
  // canvas itself being display-p3.
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const converted = {};
  for (const notation of ['#ff0000', '#00ff00', '#0000ff', '#808080', 'rgba(255, 27, 127, 1)', '#ffffff', '#000000']) {
    converted[notation] = ask(() => {
      const ctx = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
      ctx.fillStyle = notation;
      ctx.fillRect(0, 0, 1, 1);
      const srgb = hex(ctx.getImageData(0, 0, 1, 1).data);
      const p3 = hex(ctx.getImageData(0, 0, 1, 1, { colorSpace: 'display-p3' }).data);
      return `${srgb} -> ${p3}`;
    });
  }
  // Alpha rides through the conversion untouched.
  converted['half alpha'] = ask(() => {
    const ctx = new OffscreenCanvas(1, 1).getContext('2d', { alpha: true, willReadFrequently: true });
    ctx.fillStyle = 'rgba(255, 0, 0, 0.5)';
    ctx.fillRect(0, 0, 1, 1);
    return `${hex(ctx.getImageData(0, 0, 1, 1).data)} -> ${hex(ctx.getImageData(0, 0, 1, 1, { colorSpace: 'display-p3' }).data)}`;
  });
  // Untouched pixels: transparent black stays transparent black either way.
  converted['untouched'] = ask(() => {
    const ctx = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    return `${hex(ctx.getImageData(0, 0, 1, 1).data)} -> ${hex(ctx.getImageData(0, 0, 1, 1, { colorSpace: 'display-p3' }).data)}`;
  });
  // Off-canvas, where the window only partly overlaps the bitmap.
  converted['partly off canvas'] = ask(() => {
    const ctx = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    ctx.fillStyle = '#ff0000';
    ctx.fillRect(0, 0, 1, 1);
    return hex(ctx.getImageData(0, 0, 2, 1, { colorSpace: 'display-p3' }).data);
  });

  // The rect's own refusals, which the dictionary is read ahead of: each names
  // the dimension rather than sharing one message.
  const rect = {};
  for (const [sw, sh] of [[0, 1], [1, 0], [0, 0], [-1, 1], [1, -1], [-1, -1]]) {
    rect[`${sw}x${sh}`] = ask(() => {
      const d = ctx2d().getImageData(0, 0, sw, sh);
      return `${d.width}x${d.height} len=${d.data.length}`;
    });
  }

  // Where a negative size puts the window: normalised about the origin (so
  // `sx` moves by `sw`), or merely made positive in place? Painted 2x2 red,
  // read one pixel wide from either side of x=1.
  const rectPixels = {};
  {
    const paint = () => {
      const ctx = new OffscreenCanvas(2, 2).getContext('2d', { willReadFrequently: true });
      ctx.fillStyle = '#ff0000';
      ctx.fillRect(0, 0, 2, 2);
      return ctx;
    };
    for (const [sx, sy, sw, sh] of [[1, 0, -1, 1], [0, 0, -1, 1], [2, 0, -1, 1], [0, 1, 1, -1]]) {
      rectPixels[`${sx},${sy},${sw},${sh}`] = ask(() => {
        const d = paint().getImageData(sx, sy, sw, sh);
        return `${d.width}x${d.height} ${hex(d.data)}`;
      });
    }
  }

  return { nonObject, arity, descriptors, order, converted, rect, rectPixels };
})()
