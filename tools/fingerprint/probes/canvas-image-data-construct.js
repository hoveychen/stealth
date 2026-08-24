// The `ImageData` constructor's data-array forms, which are the three of its
// five that hand it pixels rather than a size:
//
//   new ImageData(data, width)
//   new ImageData(data, width, height)
//   new ImageData(data, width, height, settings)
//
// The interesting part is that these can disagree with themselves in ways the
// size forms cannot: the array's length has to divide by the width, the
// height has to agree with what is left, and the array's *type* has to be the
// one the settings' pixelFormat names — which is the whole of what a page sees
// of that setting.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };
  const shape = (d) => `${d.colorSpace} ${d.pixelFormat} ${d.width}x${d.height} ` +
    `${d.data.constructor.name} len=${d.data.length}`;

  // --- which forms exist ----------------------------------------------------
  const forms = {};
  forms['length'] = ImageData.length;
  forms['(data, w)'] = ask(() => shape(new ImageData(new Uint8ClampedArray(8), 1)));
  forms['(data, w, h)'] = ask(() => shape(new ImageData(new Uint8ClampedArray(8), 1, 2)));
  forms['(data, w, h, settings)'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, { colorSpace: 'display-p3' })));
  forms['(data, w, h, undefined)'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, undefined)));
  forms['(data, w, undefined)'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(8), 1, undefined)));
  forms['(data, w, undefined, settings)'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(8), 1, undefined, { colorSpace: 'display-p3' })));
  // The size forms, for contrast: a settings dictionary in the third slot.
  forms['(w, h, settings)'] = ask(() => shape(
    new ImageData(1, 1, { colorSpace: 'display-p3' })));

  // --- the array is taken over, not copied ---------------------------------
  const aliasing = {};
  aliasing['same object'] = ask(() => {
    const array = new Uint8ClampedArray(4);
    return `${new ImageData(array, 1, 1).data === array}`;
  });
  aliasing['writes through'] = ask(() => {
    const array = new Uint8ClampedArray(4);
    const d = new ImageData(array, 1, 1);
    array[0] = 200;
    d.data[1] = 100;
    return `${d.data[0]} ${array[1]}`;
  });
  // A view onto part of a buffer: is the offset kept, or the whole buffer?
  aliasing['subarray'] = ask(() => {
    const buffer = new ArrayBuffer(12);
    const array = new Uint8ClampedArray(buffer, 4, 4);
    const d = new ImageData(array, 1, 1);
    return `${d.data.length} ${d.data.byteOffset} ${d.data.buffer.byteLength}`;
  });

  // --- the array's type against the pixelFormat ----------------------------
  const formats = {};
  formats['Float16Array, no settings'] = ask(() => shape(
    new ImageData(new Float16Array(4), 1, 1)));
  formats['Float16Array, float16'] = ask(() => shape(
    new ImageData(new Float16Array(4), 1, 1, { pixelFormat: 'rgba-float16' })));
  formats['Float16Array, unorm8'] = ask(() => shape(
    new ImageData(new Float16Array(4), 1, 1, { pixelFormat: 'rgba-unorm8' })));
  formats['Uint8ClampedArray, float16'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, { pixelFormat: 'rgba-float16' })));
  formats['Uint8ClampedArray, unorm8'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, { pixelFormat: 'rgba-unorm8' })));
  formats['Uint8Array'] = ask(() => shape(new ImageData(new Uint8Array(4), 1, 1)));
  formats['Float32Array'] = ask(() => shape(new ImageData(new Float32Array(4), 1, 1)));
  formats['Array'] = ask(() => shape(new ImageData([0, 0, 0, 0], 1, 1)));
  formats['ArrayBuffer'] = ask(() => shape(new ImageData(new ArrayBuffer(4), 1, 1)));
  formats['null'] = ask(() => shape(new ImageData(null, 1, 1)));

  // --- the ways the arguments disagree -------------------------------------
  const refusals = {};
  refusals['length not a multiple of 4'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(5), 1, 1)));
  refusals['length does not divide by width'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(8), 3)));
  refusals['height disagrees'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(8), 1, 3)));
  refusals['width 0'] = ask(() => shape(new ImageData(new Uint8ClampedArray(4), 0, 1)));
  refusals['height 0'] = ask(() => shape(new ImageData(new Uint8ClampedArray(4), 1, 0)));
  refusals['empty array'] = ask(() => shape(new ImageData(new Uint8ClampedArray(0), 1)));
  refusals['width negative'] = ask(() => shape(new ImageData(new Uint8ClampedArray(4), -1, 1)));
  refusals['bad colorSpace'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, { colorSpace: 'nope' })));
  refusals['bad pixelFormat'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, { pixelFormat: 'nope' })));
  refusals['non-object settings'] = ask(() => shape(
    new ImageData(new Uint8ClampedArray(4), 1, 1, 'nope')));
  refusals['detached buffer'] = ask(() => {
    const array = new Uint8ClampedArray(4);
    structuredClone(array.buffer, { transfer: [array.buffer] });
    return shape(new ImageData(array, 1, 1));
  });
  refusals['no arguments'] = ask(() => shape(new ImageData()));
  refusals['one argument'] = ask(() => shape(new ImageData(new Uint8ClampedArray(4))));
  refusals['width alone'] = ask(() => shape(new ImageData(1)));

  // --- createImageData's own data form, if it has one ----------------------
  const created = {};
  created['createImageData(data, w, h)'] = ask(() => {
    const c = new OffscreenCanvas(1, 1).getContext('2d');
    return shape(c.createImageData(new Uint8ClampedArray(4), 1, 1));
  });

  // --- the third pixel format ----------------------------------------------
  // `Float32Array must use rgba-float32 pixelFormat.` above says the enum has a
  // member past the two this fork knows. Everything the other two formats do,
  // asked of it: the entry points that hand it out, what a read quantises to,
  // and what a write does with a channel outside 0..1.
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const float32 = {};
  float32['new ImageData(w, h, float32)'] = ask(() => shape(
    new ImageData(1, 1, { pixelFormat: 'rgba-float32' })));
  float32['new ImageData(data, w, h, float32)'] = ask(() => shape(
    new ImageData(new Float32Array(4), 1, 1, { pixelFormat: 'rgba-float32' })));
  float32['createImageData float32'] = ask(() => shape(
    new OffscreenCanvas(1, 1).getContext('2d')
      .createImageData(1, 1, { pixelFormat: 'rgba-float32' })));
  float32['createImageData from float32'] = ask(() => {
    const src = new ImageData(1, 1, { pixelFormat: 'rgba-float32' });
    return shape(new OffscreenCanvas(1, 1).getContext('2d').createImageData(src));
  });
  // A read: the bitmap is eight bits a channel, so these should be the unorm8
  // bytes over 255 — exactly what float16 turned out to be.
  float32['getImageData float32'] = ask(() => {
    const c = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    c.fillStyle = 'rgba(200, 100, 50, 0.3)';
    c.fillRect(0, 0, 1, 1);
    const d = c.getImageData(0, 0, 1, 1, { pixelFormat: 'rgba-float32' });
    return `${[...d.data].join(' ')} ${d.pixelFormat} ${d.data.constructor.name}`;
  });
  float32['getImageData float32 display-p3'] = ask(() => {
    const c = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    const d = c.getImageData(0, 0, 1, 1,
      { pixelFormat: 'rgba-float32', colorSpace: 'display-p3' });
    return `${[...d.data].join(' ')} ${d.colorSpace}`;
  });
  // And a write, through the format's own array.
  float32['putImageData float32'] = ask(() => {
    const c = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    const d = new ImageData(1, 1, { pixelFormat: 'rgba-float32' });
    d.data.set([1, 0.5, 0.2, 1]);
    c.putImageData(d, 0, 0);
    return hex(c.getImageData(0, 0, 1, 1).data);
  });
  float32['putImageData float32 out of range'] = ask(() => {
    const c = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    const d = new ImageData(1, 1, { pixelFormat: 'rgba-float32' });
    d.data.set([2, -1, 0.5, 1]);
    c.putImageData(d, 0, 0);
    return hex(c.getImageData(0, 0, 1, 1).data);
  });
  // A clone has to carry the format, since the bytes alone would not say which
  // array to rebuild.
  float32['structuredClone'] = ask(() => {
    const d = new ImageData(1, 1, { pixelFormat: 'rgba-float32', colorSpace: 'display-p3' });
    d.data.set([0.25, 0.5, 0.75, 1]);
    const back = structuredClone(d);
    return `${shape(back)} ${[...back.data].join(' ')}`;
  });
  return { forms, aliasing, formats, refusals, created, float32 };
})()
