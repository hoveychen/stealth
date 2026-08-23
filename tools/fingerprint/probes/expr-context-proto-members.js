// Own members of the four canvas context prototypes, side by side.
//
// canvas-draw-trace wraps every method and accessor it finds on each context
// prototype and records how many it wrapped. Those counts agree on three of
// the four and differ by one on `OffscreenCanvasRenderingContext2D`: 71 in
// Chrome, 72 here. One extra member is exactly the kind of thing a widget
// enumerating a prototype would see, so this names it rather than leaving it
// as a count.
(() => {
  const out = {};
  const own = (name) => {
    const C = globalThis[name];
    if (typeof C !== 'function') return 'absent';
    const p = C.prototype;
    if (!p) return 'no prototype';
    return Object.getOwnPropertyNames(p).sort();
  };
  for (const name of [
    'CanvasRenderingContext2D',
    'OffscreenCanvasRenderingContext2D',
    'WebGLRenderingContext',
    'WebGL2RenderingContext',
    'ImageBitmap',
    'ImageBitmapRenderingContext',
  ]) out[name] = own(name);
  return JSON.stringify(out);
})()
